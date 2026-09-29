import Testing
import Foundation
import GRDB
@testable import SocialBrain

@Suite("FeedDatabase")
struct FeedDatabaseTests {

    private func makeDB() throws -> AppDatabase {
        try AppDatabase.makeInMemory()
    }

    // Helper: create a run and return its ID
    private func makeRun(in db: AppDatabase) async throws -> Int64 {
        var run = CollectionRun(
            id: nil, startedAt: Date(), completedAt: nil,
            platformCount: 1, errorCount: 0
        )
        try await db.saveRun(&run)
        return try #require(run.id)
    }

    @Test("v1 migration creates snapshots table")
    func migrationCreatesTable() async throws {
        let db = try makeDB()
        let tableExists = try await db.dbWriter.read { conn in
            try conn.tableExists("platformSnapshot")
        }
        #expect(tableExists)
    }

    @Test("latestSnapshots returns most recent row per platform")
    func latestSnapshotsReturnsNewest() async throws {
        let db = try makeDB()
        // Use whole-second dates to avoid sub-second precision loss in SQLite storage
        let older = Date(timeIntervalSinceReferenceDate: floor(Date(timeIntervalSinceNow: -7200).timeIntervalSinceReferenceDate))
        let newer = Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate))

        let runID = try await makeRun(in: db)

        let payload = try metricsPayload(["latest_post_text": .string("hello"), "followers_count": .int(100), "engagement_rate": .double(0.05)])

        var snap1 = PlatformSnapshot(runID: runID, platform: "mastodon",
                                     collectedAt: older, metricsJSON: payload)
        var snap2 = PlatformSnapshot(runID: runID, platform: "mastodon",
                                     collectedAt: newer, metricsJSON: payload)
        try await db.saveSnapshot(&snap1)
        try await db.saveSnapshot(&snap2)

        let result = try await db.latestSnapshots()
        #expect(result[PlatformInstance(platform: .mastodon)]?.collectedAt == newer)
        #expect(result.count == 1)
    }

    @Test("latestSnapshots returns nil for platform with no rows")
    func latestSnapshotsMissingPlatform() async throws {
        let db = try makeDB()
        let result = try await db.latestSnapshots()
        #expect(result[PlatformInstance(platform: .mastodon)] == nil)
    }

    @Test("latestSnapshots returns one row per platform")
    func oneRowPerPlatformOrdered() async throws {
        let db = try makeDB()
        // Use whole-second dates to avoid sub-second precision loss in SQLite storage
        let base = Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate))
        let now = base
        let oneHourAgo = base.addingTimeInterval(-3600)
        let twoHoursAgo = base.addingTimeInterval(-7200)
        let runID = try await makeRun(in: db)

        let mastodonPayload = try metricsPayload(["latest_post_text": .string("hello"), "followers_count": .int(100), "engagement_rate": .double(0.05)])
        let blueskyPayload = try metricsPayload(["latest_post_text": .string("hi"), "followers_count": .int(200), "engagement_rate": .double(0.03)])
        let buttondownPayload = try metricsPayload(["latest_subject_line": .string("Newsletter"), "subscriber_count": .int(500), "avg_open_rate": .double(0.4)])

        var s1 = PlatformSnapshot(runID: runID, platform: "mastodon",
                                   collectedAt: now, metricsJSON: mastodonPayload)
        var s2 = PlatformSnapshot(runID: runID, platform: "bluesky",
                                   collectedAt: oneHourAgo, metricsJSON: blueskyPayload)
        var s3 = PlatformSnapshot(runID: runID, platform: "buttondown",
                                   collectedAt: twoHoursAgo, metricsJSON: buttondownPayload)
        try await db.saveSnapshot(&s1)
        try await db.saveSnapshot(&s2)
        try await db.saveSnapshot(&s3)

        let result = try await db.latestSnapshots()
        #expect(result.count == 3)
        #expect(result[PlatformInstance(platform: .mastodon)] != nil)
        #expect(result[PlatformInstance(platform: .bluesky)] != nil)
        #expect(result[PlatformInstance(platform: .buttondown)] != nil)
        #expect(result[PlatformInstance(platform: .mastodon)]?.collectedAt == now)
        #expect(result[PlatformInstance(platform: .bluesky)]?.collectedAt == oneHourAgo)
        #expect(result[PlatformInstance(platform: .buttondown)]?.collectedAt == twoHoursAgo)
    }

    @Test("content round-trips through database")
    func contentFieldPresentAfterRoundTrip() async throws {
        let db = try makeDB()
        let runID = try await makeRun(in: db)

        let encoded = try metricsPayload([
            "latest_post_text": .string("test"),
            "followers_count": .int(50),
            "engagement_rate": .double(0.07)
        ])

        var snap = PlatformSnapshot(runID: runID, platform: "bluesky",
                                    collectedAt: Date(), metricsJSON: encoded)
        try await db.saveSnapshot(&snap)

        let result = try await db.latestSnapshots()
        let data = try #require(result[PlatformInstance(platform: .bluesky)]?.metricsJSON)
        #expect(!data.isEmpty)

        // Decoded as the dictionary the collectors write, which is the only
        // shape the database ever holds.
        let decoded = try JSONDecoder().decode([String: MetricValue].self, from: data)
        #expect(decoded["latest_post_text"] == .string("test"))
        #expect(decoded["followers_count"] == .int(50))
    }

    // MARK: - Suite 10.3 — DashboardViewModel uses instanceName

    @Test("DashboardViewModel.load() produces non-empty series from matching (platform, instanceName) data")
    @MainActor
    func dashboardViewModelUsesInstanceName() async throws {
        let db = try makeDB()
        let runID = try await makeRun(in: db)

        let metrics: [String: MetricValue] = ["followers_count": .int(1500)]
        let data = PlatformData(platform: .mastodon, instanceName: "work", metrics: metrics)
        var snap = try PlatformSnapshot(runID: runID, data: data)
        try await db.saveSnapshot(&snap)

        let instance = PlatformInstance(platform: .mastodon, instanceName: "work")
        let vm = DashboardViewModel(database: db, labels: InstanceLabels(defaults: InMemoryKeyValueStore()),
                                    initialInstance: instance)
        vm.timeRange = .all
        await vm.load()

        #expect(!vm.series.isEmpty)
    }

    @Test("The Dashboard orders instances by the labels it was given, not the real ones")
    @MainActor
    func dashboardSortsByInjectedLabels() async throws {
        // It sorted by the bare `displayName`, which reads
        // `InstanceLabels.shared` — the developer's own labels (#184). Labels
        // chosen to invert the order the instance names alone would give.
        let db = try makeDB()
        let runID = try await makeRun(in: db)
        for name in ["alpha", "beta"] {
            var snap = try PlatformSnapshot(
                runID: runID,
                data: PlatformData(platform: .mastodon, instanceName: name, metrics: ["followers_count": .int(1)]))
            try await db.saveSnapshot(&snap)
        }
        let labels = InstanceLabels(defaults: InMemoryKeyValueStore())
        labels.setLabel("Zebra", for: PlatformInstance(platform: .mastodon, instanceName: "alpha"))
        labels.setLabel("Aardvark", for: PlatformInstance(platform: .mastodon, instanceName: "beta"))

        let vm = DashboardViewModel(database: db, labels: labels)
        await vm.load()

        #expect(vm.allInstances.map(\.instanceName) == ["beta", "alpha"])
    }

    @Test("The Dashboard charts GoatCounter visits, and nothing called Visitors")
    @MainActor
    func dashboardChartsGoatCounterVisits() async throws {
        // unique_visitors was charted as "Visitors" and GoatCounter has no
        // endpoint for it, so the series could never have had points (#156).
        // The fixture supplies it anyway: asserting against a snapshot that
        // omits the key would pass whether or not the series was removed.
        let db = try makeDB()
        let runID = try await makeRun(in: db)

        let data = PlatformData(
            platform: .goatCounter,
            metrics: ["total_visits": .int(8421), "unique_visitors": .int(3102)]
        )
        var snap = try PlatformSnapshot(runID: runID, data: data)
        try await db.saveSnapshot(&snap)

        let vm = DashboardViewModel(database: db, labels: InstanceLabels(defaults: InMemoryKeyValueStore()),
                                    initialInstance: PlatformInstance(platform: .goatCounter))
        vm.timeRange = .all
        await vm.load()

        #expect(vm.series.contains { $0.label == "Visits" })
        #expect(!vm.series.contains { $0.label == "Visitors" })
    }

    @Test("The Dashboard charts LinkedIn follower growth from an XLSX import")
    @MainActor
    func dashboardChartsLinkedInFollowers() async throws {
        // total_followers was collected by the XLSX importer and read by
        // nothing, so follower growth — the one thing the XLSX export offers
        // that the CSV path cannot — was invisible everywhere (#114).
        let db = try makeDB()
        let runID = try await makeRun(in: db)

        let data = PlatformData(
            platform: .linkedin,
            metrics: ["total_followers": .int(8420), "new_followers": .int(137),
                      "total_impressions": .int(4200)]
        )
        var snap = try PlatformSnapshot(runID: runID, data: data)
        try await db.saveSnapshot(&snap)

        let vm = DashboardViewModel(database: db, labels: InstanceLabels(defaults: InMemoryKeyValueStore()),
                                    initialInstance: PlatformInstance(platform: .linkedin))
        vm.timeRange = .all
        await vm.load()

        #expect(vm.series.contains { $0.label == "Followers" })
        // The growth line as well as the cumulative one — a cumulative series
        // only steps when an export lands, so it is the less informative half.
        #expect(vm.series.contains { $0.label == "New Followers" })
        // Not vacuous: an already-charted metric is still there beside it.
        #expect(vm.series.contains { $0.label == "Impressions" })
    }
}
