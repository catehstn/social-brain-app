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

        let payload = try JSONEncoder().encode(MastodonData(
            latestPostText: "hello", followersCount: 100, engagementRate: 0.05))

        var snap1 = PlatformSnapshot(runID: runID, platform: "mastodon",
                                     collectedAt: older, metricsJSON: payload)
        var snap2 = PlatformSnapshot(runID: runID, platform: "mastodon",
                                     collectedAt: newer, metricsJSON: payload)
        try await db.saveSnapshot(&snap1)
        try await db.saveSnapshot(&snap2)

        let result = try await db.latestSnapshots()
        #expect(result[.mastodon]?.collectedAt == newer)
        #expect(result.count == 1)
    }

    @Test("latestSnapshots returns nil for platform with no rows")
    func latestSnapshotsMissingPlatform() async throws {
        let db = try makeDB()
        let result = try await db.latestSnapshots()
        #expect(result[.mastodon] == nil)
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

        let mastodonPayload = try JSONEncoder().encode(MastodonData(
            latestPostText: "hello", followersCount: 100, engagementRate: 0.05))
        let blueskyPayload = try JSONEncoder().encode(BlueskyData(
            latestPostText: "hi", followersCount: 200, engagementRate: 0.03))
        let buttondownPayload = try JSONEncoder().encode(ButtondownData(
            latestSubjectLine: "Newsletter", subscriberCount: 500, openRate: 0.4))

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
        #expect(result[.mastodon] != nil)
        #expect(result[.bluesky] != nil)
        #expect(result[.buttondown] != nil)
        #expect(result[.mastodon]?.collectedAt == now)
        #expect(result[.bluesky]?.collectedAt == oneHourAgo)
        #expect(result[.buttondown]?.collectedAt == twoHoursAgo)
    }

    @Test("content round-trips through database")
    func contentFieldPresentAfterRoundTrip() async throws {
        let db = try makeDB()
        let runID = try await makeRun(in: db)

        let original = BlueskyData(latestPostText: "test", followersCount: 50, engagementRate: 0.07)
        let encoded = try JSONEncoder().encode(original)

        var snap = PlatformSnapshot(runID: runID, platform: "bluesky",
                                    collectedAt: Date(), metricsJSON: encoded)
        try await db.saveSnapshot(&snap)

        let result = try await db.latestSnapshots()
        let data = try #require(result[.bluesky]?.metricsJSON)
        #expect(!data.isEmpty)

        let decoded = try JSONDecoder().decode(BlueskyData.self, from: data)
        #expect(decoded.latestPostText == "test")
    }
}
