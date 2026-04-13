import Testing
import Foundation
import GRDB
@testable import SocialBrain

@Suite("Multi-Instance Database Tests")
struct MultiInstanceDatabaseTests {

    @Test("v2 migration adds instanceName column")
    func v2MigrationAddsInstanceNameColumn() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbWriter.read { conn in
            let columns = try Row.fetchAll(conn, sql: "PRAGMA table_info(platformSnapshot)")
            let names = columns.map { $0["name"] as String }
            #expect(names.contains("instanceName"))
        }
    }

    @Test("Old rows get default instanceName 'default' from SQL DEFAULT constraint")
    func defaultInstanceNameOnOldRows() async throws {
        // Exercise the column DEFAULT constraint directly: insert a row via raw SQL that
        // omits the instanceName column, simulating a pre-v2 row being read back after
        // the migration added DEFAULT 'default'.
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                completedAt: nil, platformCount: 1, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        // Insert via raw SQL without the instanceName column — the DEFAULT 'default' fills it in.
        let metricsJSON = try JSONEncoder().encode([:] as [String: MetricValue])
        let metricsBase64 = metricsJSON.base64EncodedString()
        try await db.dbWriter.write { conn in
            try conn.execute(
                sql: """
                INSERT INTO platformSnapshot (runID, platform, collectedAt, metricsJSON)
                VALUES (?, 'mastodon', '2022-03-01T00:00:00.000', ?)
                """,
                arguments: [runID, metricsJSON]
            )
        }

        let snapshots = try await db.snapshots(forRunID: runID)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].instanceName == "default")
        _ = metricsBase64  // suppress unused warning
    }

    @Test("latestSnapshot scopes to instanceName")
    func latestSnapshotScopedToInstanceName() async throws {
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                completedAt: nil, platformCount: 2, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let dataA = PlatformData(platform: .buttondown, instanceName: "newsletter-a",
                                 collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                 metrics: ["subscriber_count": .int(100)])
        let dataB = PlatformData(platform: .buttondown, instanceName: "newsletter-b",
                                 collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                 metrics: ["subscriber_count": .int(200)])
        var snapA = try PlatformSnapshot(runID: runID, data: dataA)
        var snapB = try PlatformSnapshot(runID: runID, data: dataB)
        try await db.saveSnapshot(&snapA)
        try await db.saveSnapshot(&snapB)

        let latest = try await db.latestSnapshot(for: .buttondown, instanceName: "newsletter-a")
        let metrics = try latest?.decodedMetrics()
        #expect(metrics?["subscriber_count"] == .int(100))
    }

    @Test("latestSnapshot default instance (no-arg) form works")
    func latestSnapshotDefaultInstance() async throws {
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                completedAt: nil, platformCount: 1, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let data = PlatformData(platform: .buttondown, instanceName: "default",
                                collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                metrics: ["subscriber_count": .int(42)])
        var snap = try PlatformSnapshot(runID: runID, data: data)
        try await db.saveSnapshot(&snap)

        let latest = try await db.latestSnapshot(for: .buttondown)
        #expect(latest != nil)
    }

    @Test("snapshots(for:instanceName:from:to:) scopes to instanceName")
    func snapshotsForInstanceNameScoped() async throws {
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                completedAt: nil, platformCount: 2, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        for i in 0..<3 {
            let date = base.addingTimeInterval(Double(i) * 3600)
            let dataA = PlatformData(platform: .mastodon, instanceName: "personal",
                                     collectedAt: date, metrics: [:])
            let dataB = PlatformData(platform: .mastodon, instanceName: "work",
                                     collectedAt: date, metrics: [:])
            var sA = try PlatformSnapshot(runID: runID, data: dataA)
            var sB = try PlatformSnapshot(runID: runID, data: dataB)
            try await db.saveSnapshot(&sA)
            try await db.saveSnapshot(&sB)
        }

        let personal = try await db.snapshots(for: .mastodon, instanceName: "personal",
                                              from: base.addingTimeInterval(-3600))
        #expect(personal.count == 3)
        #expect(personal.allSatisfy { $0.instanceName == "personal" })
    }

    @Test("twoLatestSnapshots scopes to instanceName")
    func twoLatestSnapshotsScopedToInstance() async throws {
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                completedAt: nil, platformCount: 2, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        // Insert 3 snapshots for "personal" and 3 for "work"
        for i in 0..<3 {
            let date = base.addingTimeInterval(Double(i) * 3600)
            for name in ["personal", "work"] {
                let d = PlatformData(platform: .mastodon, instanceName: name, collectedAt: date, metrics: [:])
                var s = try PlatformSnapshot(runID: runID, data: d)
                try await db.saveSnapshot(&s)
            }
        }

        let pair = try await db.twoLatestSnapshots(for: .mastodon, instanceName: "personal")
        #expect(pair.count == 2)
        #expect(pair.allSatisfy { $0.instanceName == "personal" })
    }

    @Test("latestSnapshots returns PlatformInstance keys")
    func latestSnapshotsReturnsPlatformInstanceKeys() async throws {
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                completedAt: nil, platformCount: 2, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let dataA = PlatformData(platform: .mastodon, instanceName: "personal",
                                 collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                 metrics: [:])
        let dataB = PlatformData(platform: .mastodon, instanceName: "work",
                                 collectedAt: Date(timeIntervalSinceReferenceDate: 700_010_000),
                                 metrics: [:])
        var sA = try PlatformSnapshot(runID: runID, data: dataA)
        var sB = try PlatformSnapshot(runID: runID, data: dataB)
        try await db.saveSnapshot(&sA)
        try await db.saveSnapshot(&sB)

        let latest = try await db.latestSnapshots()
        let instPersonal = PlatformInstance(platform: .mastodon, instanceName: "personal")
        let instWork = PlatformInstance(platform: .mastodon, instanceName: "work")
        #expect(latest[instPersonal] != nil)
        #expect(latest[instWork] != nil)
        #expect(latest.count == 2)
    }

    @Test("Two instances with same platform produce distinct dictionary entries with correct metrics")
    func latestSnapshotsTwoInstancesDistinctMetrics() async throws {
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                completedAt: nil, platformCount: 2, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let d1 = PlatformData(platform: .buttondown, instanceName: "nl-1",
                               collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                               metrics: ["subscriber_count": .int(10)])
        let d2 = PlatformData(platform: .buttondown, instanceName: "nl-2",
                               collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                               metrics: ["subscriber_count": .int(20)])
        var s1 = try PlatformSnapshot(runID: runID, data: d1)
        var s2 = try PlatformSnapshot(runID: runID, data: d2)
        try await db.saveSnapshot(&s1)
        try await db.saveSnapshot(&s2)

        let latest = try await db.latestSnapshots()
        let inst1 = PlatformInstance(platform: .buttondown, instanceName: "nl-1")
        let inst2 = PlatformInstance(platform: .buttondown, instanceName: "nl-2")
        let m1 = try latest[inst1]?.decodedMetrics()
        let m2 = try latest[inst2]?.decodedMetrics()
        #expect(m1?["subscriber_count"] == .int(10))
        #expect(m2?["subscriber_count"] == .int(20))
    }

    @Test("previousSnapshots returns PlatformInstance keys")
    func previousSnapshotsReturnsPlatformInstanceKeys() async throws {
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                completedAt: nil, platformCount: 2, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        for name in ["personal", "work"] {
            for i in 0..<2 {
                let d = PlatformData(platform: .mastodon, instanceName: name,
                                     collectedAt: base.addingTimeInterval(Double(i) * 3600),
                                     metrics: [:])
                var s = try PlatformSnapshot(runID: runID, data: d)
                try await db.saveSnapshot(&s)
            }
        }

        let prev = try await db.previousSnapshots()
        let personal = PlatformInstance(platform: .mastodon, instanceName: "personal")
        let work = PlatformInstance(platform: .mastodon, instanceName: "work")
        #expect(prev[personal] != nil)
        #expect(prev[work] != nil)
    }

    @Test("deleteSnapshots removes only the target instance")
    func deleteSnapshotsRemovesOnlyTargetInstance() async throws {
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                completedAt: nil, platformCount: 2, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let dataA = PlatformData(platform: .goatCounter, instanceName: "site-a",
                                 collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                 metrics: [:])
        let dataB = PlatformData(platform: .goatCounter, instanceName: "site-b",
                                 collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                 metrics: [:])
        var sA = try PlatformSnapshot(runID: runID, data: dataA)
        var sB = try PlatformSnapshot(runID: runID, data: dataB)
        try await db.saveSnapshot(&sA)
        try await db.saveSnapshot(&sB)

        try await db.deleteSnapshots(for: PlatformInstance(platform: .goatCounter, instanceName: "site-a"))

        let remaining = try await db.latestSnapshots()
        #expect(remaining[PlatformInstance(platform: .goatCounter, instanceName: "site-a")] == nil)
        #expect(remaining[PlatformInstance(platform: .goatCounter, instanceName: "site-b")] != nil)
    }

    @Test("deleteSnapshots is a no-op for unknown instance")
    func deleteSnapshotsIsNoOpForUnknownInstance() async throws {
        let db = try AppDatabase.makeInMemory()
        // Should not throw even if no rows match
        try await db.deleteSnapshots(for: PlatformInstance(platform: .mastodon, instanceName: "nonexistent"))
    }

    @Test("v2 migration creates three-column index")
    func indexRecreatedWithThreeColumns() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbWriter.read { conn in
            let indexes = try String.fetchAll(
                conn,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='platformSnapshot'"
            )
            let hasThreeColumnIndex = indexes.contains {
                $0.contains("platform") && $0.contains("instanceName") && $0.contains("collectedAt")
            }
            #expect(hasThreeColumnIndex)
        }
    }
}
