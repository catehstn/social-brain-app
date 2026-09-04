import Testing
import Foundation
import GRDB
@testable import SocialBrain

/// Migrations must not lose data.
///
/// `CLAUDE.md` has required this since the beginning ("add tests for every
/// database migration — verify schema upgrades don't lose data") and nothing
/// implemented it: every other database test starts from a fully-migrated
/// in-memory store, so they prove migrations *run*, never that anything
/// survives them.
///
/// That gap mattered more than it looked. `eraseDatabaseOnSchemaChange` was on
/// in DEBUG — the only build this app has — so a migration that would have lost
/// data was indistinguishable from one that wiped the store deliberately. With
/// the flag now opt-in, a bad migration fails loudly instead, and these tests
/// are what say whether it is bad.
///
/// The SQLite store is the only copy of this data, and most of it cannot be
/// re-fetched: platform APIs return current values, not history.
@Suite("Migration data preservation")
struct MigrationDataPreservationTests {

    /// A database migrated only as far as v1, with no v2 columns.
    private func makeV1Database() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v1_initial")
        return dbQueue
    }

    private let started = Date(timeIntervalSince1970: 1_700_000_000)
    private let collected = Date(timeIntervalSince1970: 1_700_003_600)

    /// Inserts one run and two snapshots using the v1 schema — no `instanceName`.
    private func seedV1Data(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO collectionRun (id, startedAt, completedAt, platformCount, errorCount)
                    VALUES (1, ?, ?, 2, 0)
                    """,
                arguments: [started, collected]
            )
            try db.execute(
                sql: """
                    INSERT INTO platformSnapshot (id, runID, platform, collectedAt, metricsJSON)
                    VALUES (1, 1, 'mastodon', ?, ?)
                    """,
                arguments: [collected, Data(#"{"followers_count":1234}"#.utf8)]
            )
            try db.execute(
                sql: """
                    INSERT INTO platformSnapshot (id, runID, platform, collectedAt, metricsJSON)
                    VALUES (2, 1, 'buttondown', ?, ?)
                    """,
                arguments: [collected, Data(#"{"subscriber_count":42}"#.utf8)]
            )
        }
    }

    @Test("v1 data survives migration to the current schema")
    func v1DataSurvives() throws {
        let dbQueue = try makeV1Database()
        try seedV1Data(dbQueue)

        try AppDatabase.migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let runs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collectionRun")
            let snapshots = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM platformSnapshot")
            #expect(runs == 1)
            #expect(snapshots == 2)
        }
    }

    @Test("Column values are unchanged, not merely present")
    func valuesAreUnchanged() throws {
        let dbQueue = try makeV1Database()
        try seedV1Data(dbQueue)

        try AppDatabase.migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM collectionRun WHERE id = 1")
            #expect(row?["startedAt"] as Date? == started)
            #expect(row?["platformCount"] as Int? == 2)
            #expect(row?["errorCount"] as Int? == 0)

            let snapshot = try Row.fetchOne(
                db, sql: "SELECT * FROM platformSnapshot WHERE id = 1"
            )
            #expect(snapshot?["platform"] as String? == "mastodon")
            #expect(snapshot?["collectedAt"] as Date? == collected)
            // The metrics blob is the actual collected data — a migration that
            // preserved rows but corrupted this would lose everything that matters.
            let metrics = snapshot?["metricsJSON"] as Data?
            #expect(metrics.map { String(decoding: $0, as: UTF8.self) } == #"{"followers_count":1234}"#)
        }
    }

    @Test("v2 backfills instanceName as 'default' for pre-existing rows")
    func v2BackfillsInstanceName() throws {
        let dbQueue = try makeV1Database()
        try seedV1Data(dbQueue)

        try AppDatabase.migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let names = try String.fetchAll(
                db, sql: "SELECT instanceName FROM platformSnapshot ORDER BY id"
            )
            #expect(names == ["default", "default"])
        }
    }

    @Test("Rows remain readable through the app's own query layer after migrating")
    func rowsReadableThroughAppQueries() async throws {
        let dbQueue = try makeV1Database()
        try seedV1Data(dbQueue)
        try AppDatabase.migrator.migrate(dbQueue)

        // Reaching the data through the real accessor, not just raw SQL, is the
        // difference between "the rows are there" and "the app can still see them".
        let database = try AppDatabase(dbQueue)
        let snapshots = try await database.latestSnapshots()
        #expect(snapshots.count == 2)
        #expect(snapshots.keys.allSatisfy { $0.instanceName == "default" })
    }

    @Test("Migrating an already-current database is a no-op")
    func migratingTwiceIsSafe() throws {
        let dbQueue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(dbQueue)
        try seedV1Data(dbQueue)

        try AppDatabase.migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let remaining = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM platformSnapshot")
            #expect(remaining == 2)
        }
    }
    @Test("The database is never erased on schema change unless opted in")
    func eraseIsOptIn() {
        // Guards the regression this suite exists alongside: the flag used to be
        // set under `#if DEBUG`, and DEBUG is the only build this app has, so
        // editing any migration silently destroyed every snapshot ever collected.
        // It is now opt-in via SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE.
        let optedIn = ProcessInfo.processInfo.environment["SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE"] != nil
        #expect(AppDatabase.migrator.eraseDatabaseOnSchemaChange == optedIn)
    }

}
