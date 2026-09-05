import Testing
import Foundation
@testable import SocialBrain

/// Guards the parity fixed in #67.
///
/// Spike detection lived privately inside `RunViewModel`, so the background
/// refresh — the only run that happens when the user isn't already watching —
/// never produced a notification. The design brief's "a spike wakes me up
/// mid-week" flow was unreachable: alerts only ever fired while the user was
/// looking at the Run screen having just pressed the button.
@Suite("Spike notifier")
struct SpikeNotifierTests {

    private func makeDB() throws -> AppDatabase { try AppDatabase.makeInMemory() }

    /// Saves two snapshots for one platform so a comparison is possible.
    private func seed(
        _ db: AppDatabase,
        platform: Platform = .mastodon,
        previous: Int,
        current: Int
    ) async throws {
        let base = Date(timeIntervalSince1970: 1_767_225_600)
        for (offset, value) in [previous, current].enumerated() {
            // Explicit, an hour apart. Two writes in a tight loop can land in the
            // same millisecond, and ORDER BY collectedAt DESC is unspecified on a
            // tie — which would silently swap current and previous.
            let collectedAt = base.addingTimeInterval(Double(offset) * 3600)
            var run = CollectionRun(startedAt: collectedAt, platformCount: 1, errorCount: 0)
            try await db.saveRun(&run)
            var snapshot = try PlatformSnapshot(
                runID: run.id!,
                data: PlatformData(platform: platform,
                                   collectedAt: collectedAt,
                                   metrics: ["followers_count": .int(value)])
            )
            try await db.saveSnapshot(&snapshot)
        }
    }

    /// Saves a single snapshot, for cases where the run under test writes the
    /// second one itself.
    private func seedOne(_ db: AppDatabase, platform: Platform = .mastodon, value: Int) async throws {
        let collectedAt = Date(timeIntervalSince1970: 1_767_225_600)
        var run = CollectionRun(startedAt: collectedAt, platformCount: 1, errorCount: 0)
        try await db.saveRun(&run)
        var snapshot = try PlatformSnapshot(
            runID: run.id!,
            data: PlatformData(platform: platform,
                               collectedAt: collectedAt,
                               metrics: ["followers_count": .int(value)])
        )
        try await db.saveSnapshot(&snapshot)
    }

    private func summary(for platform: Platform = .mastodon) -> CollectionSummary {
        CollectionSummary(
            runID: 1,
            startedAt: Date(),
            completedAt: Date(),
            results: [.success(PlatformData(platform: platform, metrics: [:]))]
        )
    }

    @Test("A large jump produces an alert and sends one notification")
    func detectsAndSends() async throws {
        let db = try makeDB()
        try await seed(db, previous: 1000, current: 1500)  // +50%

        let sent = Sent()
        let notifier = SpikeNotifier(database: db, send: { await sent.record($0) })
        let alerts = await notifier.notifySpikes(for: summary())

        #expect(!alerts.isEmpty)
        #expect(await sent.callCount == 1)
        #expect(await sent.alerts.count == alerts.count)
    }

    @Test("No notification is sent when nothing spiked")
    func staysQuietWhenFlat() async throws {
        let db = try makeDB()
        try await seed(db, previous: 1000, current: 1001)

        let sent = Sent()
        let notifier = SpikeNotifier(database: db, send: { await sent.record($0) })
        let alerts = await notifier.notifySpikes(for: summary())

        #expect(alerts.isEmpty)
        // An empty notification would be worse than none: it trains the user to
        // ignore them.
        #expect(await sent.callCount == 0)
    }

    @Test("A platform with only one snapshot is skipped rather than compared to nothing")
    func skipsWithoutAPair() async throws {
        let db = try makeDB()
        var run = CollectionRun(startedAt: Date(), platformCount: 1, errorCount: 0)
        try await db.saveRun(&run)
        var snapshot = try PlatformSnapshot(
            runID: run.id!,
            data: PlatformData(platform: .mastodon, metrics: ["followers_count": .int(1000)])
        )
        try await db.saveSnapshot(&snapshot)

        let sent = Sent()
        let notifier = SpikeNotifier(database: db, send: { await sent.record($0) })
        let alerts = await notifier.notifySpikes(for: summary())

        #expect(alerts.isEmpty)
        #expect(await sent.callCount == 0)
    }

    @Test("Failed platforms are not compared")
    func ignoresFailedPlatforms() async throws {
        let db = try makeDB()
        try await seed(db, previous: 1000, current: 1500)

        let failedSummary = CollectionSummary(
            runID: 1, startedAt: Date(), completedAt: Date(),
            results: [.failure(platform: .mastodon, instanceName: "default",
                               error: CollectorError.missingCredential("api_key"))]
        )

        let sent = Sent()
        let notifier = SpikeNotifier(database: db, send: { await sent.record($0) })
        let alerts = await notifier.notifySpikes(for: failedSummary)

        // The snapshots exist and would spike, but this run didn't collect them.
        #expect(alerts.isEmpty)
        #expect(await sent.callCount == 0)
    }

    @Test("Alerts from a named instance say which one")
    func namedInstanceIsAttributed() async throws {
        // Two Mastodon accounts both spiking otherwise produce two
        // identical-looking lines in one notification.
        let db = try makeDB()
        let base = Date(timeIntervalSince1970: 1_767_225_600)
        for (offset, value) in [1000, 1500].enumerated() {
            let at = base.addingTimeInterval(Double(offset) * 3600)
            var run = CollectionRun(startedAt: at, platformCount: 1, errorCount: 0)
            try await db.saveRun(&run)
            var snapshot = try PlatformSnapshot(
                runID: run.id!,
                data: PlatformData(platform: .mastodon,
                                   instanceName: "work",
                                   collectedAt: at,
                                   metrics: ["followers_count": .int(value)])
            )
            try await db.saveSnapshot(&snapshot)
        }

        let summary = CollectionSummary(
            runID: 1, startedAt: base, completedAt: base,
            results: [.success(PlatformData(platform: .mastodon,
                                            instanceName: "work",
                                            metrics: [:]))]
        )

        let alerts = await SpikeNotifier(database: db, send: { _ in }).notifySpikes(for: summary)
        #expect(alerts.count == 1)
        #expect(alerts.first?.instanceName == "work")
        #expect(alerts.first?.summary.contains("(work)") == true)
    }

    // MARK: - The background path

    @Test("The background refresh notifies spikes")
    func backgroundRefreshNotifies() async throws {
        // Deleting the notifySpikes call in runBackgroundRefresh left all the
        // tests above passing: they exercise SpikeNotifier in isolation and say
        // nothing about whether the scheduled run calls it. This one does.
        let db = try makeDB()
        // Only the earlier snapshot is seeded: the run itself writes the second
        // one. Seeding both made the comparison flat, because the collector's
        // value then matched the newest seeded value.
        try await seedOne(db, value: 1000)

        let sent = Sent()
        await AppDelegate.runBackgroundRefresh(
            database: db,
            collectors: [StubSpikeCollector(platform: .mastodon)],
            credentials: { _ in Credentials(["api_key": "k"]) },
            notifier: SpikeNotifier(database: db, send: { await sent.record($0) })
        )

        #expect(await sent.callCount == 1)
        #expect(await sent.alerts.isEmpty == false)
    }

    @Test("The background refresh does nothing when no platforms are configured")
    func backgroundRefreshWithNoCollectors() async throws {
        let db = try makeDB()
        let sent = Sent()

        await AppDelegate.runBackgroundRefresh(
            database: db,
            collectors: [],
            credentials: { _ in nil },
            notifier: SpikeNotifier(database: db, send: { await sent.record($0) })
        )

        #expect(await sent.callCount == 0)
    }


    /// Records what would have been notified.
    private actor Sent {
        private(set) var alerts: [SpikeAlert] = []
        private(set) var callCount = 0

        func record(_ newAlerts: [SpikeAlert]) {
            alerts.append(contentsOf: newAlerts)
            callCount += 1
        }
    }
}

/// Returns a fixed snapshot so the background run has something to compare.
private struct StubSpikeCollector: Collector {
    let platform: Platform
    var instanceName: String = "default"

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
        PlatformData(platform: platform,
                     instanceName: instanceName,
                     metrics: ["followers_count": .int(1500)])
    }

    func fetchLabel(credentials: Credentials) async -> String? { nil }
}
