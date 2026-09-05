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
        for value in [previous, current] {
            var run = CollectionRun(startedAt: Date(), platformCount: 1, errorCount: 0)
            try await db.saveRun(&run)
            var snapshot = try PlatformSnapshot(
                runID: run.id!,
                data: PlatformData(platform: platform, metrics: ["followers_count": .int(value)])
            )
            try await db.saveSnapshot(&snapshot)
        }
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
