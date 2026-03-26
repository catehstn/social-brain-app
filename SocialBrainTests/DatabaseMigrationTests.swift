import Testing
import Foundation
@testable import SocialBrain

@Suite("Database Migration Tests")
struct DatabaseMigrationTests {

    @Test("Schema is created on first launch")
    func schemaCreated() async throws {
        let db = try AppDatabase.makeInMemory()

        try await db.dbWriter.read { conn in
            let tables = try String.fetchAll(
                conn,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            #expect(tables.contains("collectionRun"))
            #expect(tables.contains("platformSnapshot"))
        }
    }

    @Test("Save and fetch a CollectionRun")
    func saveCollectionRun() async throws {
        let db = try AppDatabase.makeInMemory()

        var run = CollectionRun(
            id: nil,
            startedAt: Date(),
            completedAt: nil,
            platformCount: 3,
            errorCount: 0
        )
        try await db.saveRun(&run)

        #expect(run.id != nil)

        let fetched = try await db.allRuns()
        #expect(fetched.count == 1)
        #expect(fetched[0].platformCount == 3)
    }

    @Test("Complete a run sets completedAt and errorCount")
    func completeRun() async throws {
        let db = try AppDatabase.makeInMemory()

        var run = CollectionRun(
            id: nil,
            startedAt: Date(),
            completedAt: nil,
            platformCount: 2,
            errorCount: 0
        )
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        try await db.completeRun(id: runID, errorCount: 1)

        let fetched = try await db.allRuns()
        #expect(fetched[0].completedAt != nil)
        #expect(fetched[0].errorCount == 1)
    }

    @Test("Save and fetch a PlatformSnapshot round-trips metrics")
    func saveAndFetchSnapshot() async throws {
        let db = try AppDatabase.makeInMemory()

        var run = CollectionRun(
            id: nil, startedAt: Date(), completedAt: nil,
            platformCount: 1, errorCount: 0
        )
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let data = PlatformData(
            platform: .mastodon,
            collectedAt: Date(),
            metrics: [
                "followers_count": .int(1234),
                "avg_favourites":  .double(3.5),
                "top_post":        .string("Hello world")
            ]
        )

        var snapshot = try PlatformSnapshot(runID: runID, data: data)
        try await db.saveSnapshot(&snapshot)

        let fetched = try await db.snapshots(forRunID: runID)
        #expect(fetched.count == 1)
        #expect(fetched[0].platformEnum == .mastodon)

        let metrics = try fetched[0].decodedMetrics()
        #expect(metrics["followers_count"] == .int(1234))
        #expect(metrics["avg_favourites"]  == .double(3.5))
        #expect(metrics["top_post"]        == .string("Hello world"))
    }

    @Test("latestSnapshot returns most recent entry")
    func latestSnapshot() async throws {
        let db = try AppDatabase.makeInMemory()

        var run = CollectionRun(
            id: nil, startedAt: Date(), completedAt: nil,
            platformCount: 1, errorCount: 0
        )
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let older = PlatformData(
            platform: .bluesky,
            collectedAt: Date().addingTimeInterval(-86400),
            metrics: ["followers_count": .int(100)]
        )
        let newer = PlatformData(
            platform: .bluesky,
            collectedAt: Date(),
            metrics: ["followers_count": .int(200)]
        )

        var s1 = try PlatformSnapshot(runID: runID, data: older)
        var s2 = try PlatformSnapshot(runID: runID, data: newer)
        try await db.saveSnapshot(&s1)
        try await db.saveSnapshot(&s2)

        let latest = try await db.latestSnapshot(for: .bluesky)
        let metrics = try latest?.decodedMetrics()
        #expect(metrics?["followers_count"] == .int(200))
    }

    @Test("snapshots(for:from:to:) filters by date range")
    func snapshotDateRange() async throws {
        let db = try AppDatabase.makeInMemory()

        var run = CollectionRun(
            id: nil, startedAt: Date(), completedAt: nil,
            platformCount: 1, errorCount: 0
        )
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let now = Date()
        let dates: [Date] = [
            now.addingTimeInterval(-7 * 86400),   // 7 days ago  ← in range
            now.addingTimeInterval(-3 * 86400),   // 3 days ago  ← in range
            now.addingTimeInterval(-30 * 86400)   // 30 days ago ← out of range
        ]
        for date in dates {
            let data = PlatformData(
                platform: .buttondown, collectedAt: date,
                metrics: ["subscriber_count": .int(500)]
            )
            var snap = try PlatformSnapshot(runID: runID, data: data)
            try await db.saveSnapshot(&snap)
        }

        let week = try await db.snapshots(
            for: .buttondown,
            from: now.addingTimeInterval(-8 * 86400),
            to: now
        )
        #expect(week.count == 2)
    }

    @Test("Cascade delete removes snapshots when run is deleted")
    func cascadeDelete() async throws {
        let db = try AppDatabase.makeInMemory()

        var run = CollectionRun(
            id: nil, startedAt: Date(), completedAt: nil,
            platformCount: 1, errorCount: 0
        )
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let data = PlatformData(
            platform: .goatCounter, collectedAt: Date(),
            metrics: ["total_pageviews": .int(999)]
        )
        var snap = try PlatformSnapshot(runID: runID, data: data)
        try await db.saveSnapshot(&snap)

        // Delete the run — cascade should remove the snapshot.
        try await db.deleteRun(id: runID)

        let remaining = try await db.snapshots(forRunID: runID)
        #expect(remaining.isEmpty)
    }
}
