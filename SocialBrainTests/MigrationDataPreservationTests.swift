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
@Suite(
    "Migration data preservation",
    // Skipped under the erase opt-in for two reasons: the migrator wipes the
    // seeded v1 data before the preservation tests can assert anything, and
    // AppDatabase.init bypasses drift detection entirely when the flag is set,
    // so the two drift tests cannot hold either.
    .enabled(
        if: !AppDatabase.erasesOnSchemaChange,
        "skipped while SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE=1 — the migrator erases the seed"
    )
)
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
            // A rebuild can preserve every other value while rewriting this one.
            #expect(snapshot?["runID"] as Int? == 1)
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
        // Seed at v1 and migrate, so the data is present *before* any migration
        // runs. The first version of this test seeded after migrating to head,
        // which meant a destructive migration had already run against an empty
        // table — it passed against a `DROP TABLE` and could never have failed.
        let dbQueue = try makeV1Database()
        try seedV1Data(dbQueue)
        try AppDatabase.migrator.migrate(dbQueue)

        try AppDatabase.migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let remaining = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM platformSnapshot")
            #expect(remaining == 2)
        }
    }
    @Test("Schema drift is detected and refused rather than silently migrated")
    func driftIsRefused() throws {
        // The real regression guard, replacing a version of this test that
        // compared ProcessInfo against ProcessInfo and so could not fail.
        //
        // GRDB skips migrations it has already applied *by name*, so a database
        // carrying an unknown migration is exactly the shape produced by editing
        // or renaming one. Opening it must raise, not quietly run against a
        // stale schema.
        let dbQueue = try makeV1Database()
        try seedV1Data(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99_from_a_future_build')")
        }

        #expect(throws: AppDatabaseError.self) {
            _ = try AppDatabase(dbQueue)
        }
    }

    @Test("An edited migration is detected, not silently skipped")
    func editedMigrationIsRefused() throws {
        // This is issue #66's real scenario, and it takes a different branch of
        // hasSchemaChanges than driftIsRefused: the identifiers all match, so
        // detection depends on the sqlite_master comparison rather than on an
        // unknown-migration check. Build a database that claims both migrations
        // are applied but whose tables were created with different DDL.
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v1_initial'), ('v2_instance_names')")
            try db.execute(sql: """
                CREATE TABLE "collectionRun" (
                    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
                    "startedAt" DATETIME NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE "platformSnapshot" (
                    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
                    "platform" TEXT NOT NULL
                )
                """)
        }

        #expect(throws: AppDatabaseError.self) {
            _ = try AppDatabase(dbQueue)
        }
    }

    @Test("Foreign-key links from snapshots to their run survive")
    func referentialIntegritySurvives() throws {
        // A create-new / INSERT-SELECT / drop / rename rebuild is the most common
        // real migration mistake in SQLite, and it can preserve every row and
        // every column value while silently rewriting foreign keys. Checking row
        // counts and column values does not catch it; this does.
        let dbQueue = try makeV1Database()
        try seedV1Data(dbQueue)
        try AppDatabase.migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let runIDs = try Int.fetchAll(db, sql: "SELECT runID FROM platformSnapshot ORDER BY id")
            #expect(runIDs == [1, 1])

            // Without the count, "no orphans" is also true of an empty table —
            // the join half passed against a probe that deleted every row.
            #expect(runIDs.count == 2)
            let orphans = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM platformSnapshot s
                LEFT JOIN collectionRun r ON s.runID = r.id
                WHERE r.id IS NULL
                """)
            #expect(orphans == 0)
        }
    }

    @Test("Cascade delete still removes snapshots with their run")
    func cascadeSurvives() throws {
        // deleteRun depends on ON DELETE CASCADE. A rebuild that drops the
        // constraint leaves the data looking correct until something deletes.
        let dbQueue = try makeV1Database()
        try seedV1Data(dbQueue)
        try AppDatabase.migrator.migrate(dbQueue)

        // Precondition: without this the assertion below is also satisfied by a
        // migration that already destroyed the table, which is how the first
        // version of this test passed against a DROP TABLE probe.
        try dbQueue.read { db in
            let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM platformSnapshot")
            #expect(before == 2)
        }

        // Foreign keys are enabled by GRDB's default configuration. Setting the
        // pragma inside a transaction would be a no-op, so don't imply otherwise.
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM collectionRun WHERE id = 1")
        }

        try dbQueue.read { db in
            let remaining = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM platformSnapshot")
            #expect(remaining == 0)
        }
    }

    @Test("The snapshot lookup index exists after migrating")
    func indexSurvives() throws {
        // v2 itself drops and recreates an index, so this is a live risk rather
        // than a hypothetical one.
        let dbQueue = try makeV1Database()
        try seedV1Data(dbQueue)
        try AppDatabase.migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let indexed = try db.indexes(on: "platformSnapshot")
                .contains { Set($0.columns) == ["platform", "instanceName", "collectedAt"] }
            #expect(indexed)
        }
    }

    @Test("NULLs and awkward values round-trip through migration")
    func nullsAndAwkwardValuesSurvive() throws {
        // The main seed always populates completedAt and uses short ASCII, so a
        // migration that coerced NULL to a default or truncated text would be
        // invisible to it.
        let dbQueue = try makeV1Database()
        let unicode = #"{"note":"emoji 🧠 and quotes \" and a long tail: "# + String(repeating: "x", count: 4000) + #""}"#
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO collectionRun (id, startedAt, completedAt, platformCount, errorCount)
                    VALUES (7, ?, NULL, 0, 0)
                    """,
                arguments: [started]
            )
            try db.execute(
                sql: """
                    INSERT INTO platformSnapshot (id, runID, platform, collectedAt, metricsJSON)
                    VALUES (7, 7, 'mastodon', ?, ?)
                    """,
                arguments: [collected, Data(unicode.utf8)]
            )
        }

        try AppDatabase.migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM collectionRun WHERE id = 7")
            #expect(row?["completedAt"] == nil)

            let blob = try Data.fetchOne(db, sql: "SELECT metricsJSON FROM platformSnapshot WHERE id = 7")
            #expect(blob.map { String(decoding: $0, as: UTF8.self) } == unicode)
        }
    }

}

/// Separate suite because these assert configuration, not data, and so must not
/// inherit the erase-flag skip above — under that skip the opt-in case was never
/// exercised at all, which is the tautology `eraseFlagRequiresExactValue` was
/// written to replace.
@Suite("Migration configuration")
struct MigrationConfigurationTests {
    @Test("Only an exact \"1\" opts in to erasing",
          arguments: [(nil as String?, false), ("", false), ("0", false), ("false", false),
                      ("true", false), ("YES", false), ("1", true), (" 1", false)])
    func eraseFlagRequiresExactValue(raw: String?, expected: Bool) {
        // Table-driven against the parsing function rather than the live
        // environment: comparing ProcessInfo to ProcessInfo could not fail under
        // either configuration CI runs, so a presence check would have survived.
        // "0" and "false" are the cases that matter — under a presence check
        // they would erase the database.
        #expect(AppDatabase.erases(from: raw) == expected)
    }

    @Test("The migrator's erase setting follows the parsed flag")
    func migratorFollowsTheFlag() {
        #expect(AppDatabase.migrator.eraseDatabaseOnSchemaChange == AppDatabase.erasesOnSchemaChange)
    }

    @Test("The migration list is exactly what is expected, in order")
    func migrationListIsPinned() {
        // GRDB keys migrations by identifier, so renaming or reordering one is a
        // launch-time failure rather than a compile error. Pinning the list turns
        // that into a test failure — and makes adding a v3 a deliberate act that
        // forces this suite to be updated alongside it.
        #expect(AppDatabase.migrator.migrations == ["v1_initial", "v2_instance_names"])
    }
}
