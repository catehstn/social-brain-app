import Foundation
import GRDB

/// The application's single GRDB database, wrapped in an actor for safe concurrent access.
actor AppDatabase {
    /// Directly accessible without hopping through the actor because `DatabaseWriter`
    /// inherits `Sendable` from `DatabaseReader`, and this is an immutable `let` binding.
    nonisolated let dbWriter: any DatabaseWriter

    // MARK: - Lifecycle

    /// Creates or opens the database at the given path and runs all migrations.
    static func makeDefault() throws -> AppDatabase {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("SocialBrain", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("analytics.sqlite")
        let config = AppDatabase.makeConfiguration()
        let dbPool = try DatabasePool(path: dbURL.path, configuration: config)
        return try AppDatabase(dbPool)
    }

    /// Creates an in-memory database; used in tests.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: makeConfiguration()))
    }

    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace(options: .profile) { event in
                #if DEBUG
                print("[SQL] \(event)")
                #endif
            }
        }
        return config
    }

    /// Internal rather than private so migration tests can wrap a database they
    /// have migrated to a specific version and then read it back through the
    /// app's own query layer. Production code should use `makeDefault()` or
    /// `makeInMemory()`.
    init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        let migrator = Self.migrator

        // `eraseDatabaseOnSchemaChange` was doing two jobs: detecting that the
        // stored schema no longer matches the migrations, and destroying the
        // database in response. Only the second was unwanted — dropping the flag
        // without replacing the detection would be worse, not better, because
        // GRDB identifies migrations by name and silently skips any already
        // applied. An edited migration would therefore not error at all: the app
        // would open a stale schema and fail lazily at query time, and those
        // failures are swallowed into empty states, so the user would see an
        // empty dashboard with their data intact on disk and nothing saying so.
        //
        // Detect the drift up front and refuse to continue instead.
        if !Self.erasesOnSchemaChange {
            let drifted = try dbWriter.read { try migrator.hasSchemaChanges($0) }
            if drifted {
                throw AppDatabaseError.schemaChanged
            }
        }

        try migrator.migrate(dbWriter)
    }

    // MARK: - Migrations

    /// Whether the destructive erase-on-schema-change behaviour is opted in.
    ///
    /// Requires the exact value `"1"`. A presence check would mean
    /// `SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE=0` also erased the database, which is
    /// the wrong default for a flag whose only effect is deleting unrecoverable
    /// data.
    ///
    /// Note the `TEST_RUNNER_` prefix when setting it for a test run — xcodebuild
    /// strips that prefix and forwards the rest to the test host; without it the
    /// variable never arrives:
    ///
    ///     SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE=1 open SocialBrain.app        # app
    ///     TEST_RUNNER_SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE=1 xcodebuild test # tests
    static var erasesOnSchemaChange: Bool {
        ProcessInfo.processInfo.environment["SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE"] == "1"
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Deliberately NOT gated on DEBUG. This app is unsigned and self-built,
        // so the DEBUG build is the only build there is — "#if DEBUG" meant
        // "always on" for the one real user, and any edit to an existing
        // migration silently deleted every snapshot and run ever collected.
        // Most of that data cannot be re-fetched: platform APIs expose current
        // values, not history.
        //
        // Opt in explicitly while doing schema work:
        //   SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE=1 xcodebuild ...
        // Without it, an incompatible schema now fails loudly at launch instead
        // of destroying the store.
        migrator.eraseDatabaseOnSchemaChange = Self.erasesOnSchemaChange

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "collectionRun") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull()
                t.column("completedAt", .datetime)
                t.column("platformCount", .integer).notNull().defaults(to: 0)
                t.column("errorCount", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "platformSnapshot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("runID", .integer).notNull()
                    .references("collectionRun", onDelete: .cascade)
                t.column("platform", .text).notNull()
                t.column("collectedAt", .datetime).notNull()
                t.column("metricsJSON", .blob).notNull()
            }

            try db.create(
                indexOn: "platformSnapshot",
                columns: ["platform", "collectedAt"]
            )
        }

        migrator.registerMigration("v2_instance_names") { db in
            try db.alter(table: "platformSnapshot") { t in
                t.add(column: "instanceName", .text).notNull().defaults(to: "default")
            }
            // Drop old two-column index and recreate with three columns.
            try db.execute(sql: "DROP INDEX IF EXISTS \"index_platformSnapshot_on_platform_collectedAt\"")
            try db.create(
                indexOn: "platformSnapshot",
                columns: ["platform", "instanceName", "collectedAt"]
            )
        }

        return migrator
    }
}

// MARK: - Write helpers

extension AppDatabase {
    /// Saves a new collection run and returns it with its assigned ID.
    func saveRun(_ run: inout CollectionRun) throws {
        try dbWriter.write { db in
            try run.save(db)
        }
    }

    /// Marks a run as completed.
    func completeRun(id: Int64, errorCount: Int) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE collectionRun
                    SET completedAt = ?, errorCount = ?
                    WHERE id = ?
                    """,
                arguments: [Date(), errorCount, id]
            )
        }
    }

    /// Inserts a platform snapshot.
    func saveSnapshot(_ snapshot: inout PlatformSnapshot) throws {
        try dbWriter.write { db in
            try snapshot.save(db)
        }
    }

    /// Deletes a collection run (and its snapshots via cascade).
    func deleteRun(id: Int64) throws {
        try dbWriter.write { db in
            _ = try CollectionRun.deleteOne(db, id: id)
        }
    }
}

// MARK: - Write helpers (additional)

extension AppDatabase {
    /// Deletes all snapshots for a specific platform instance.
    func deleteSnapshots(for instance: PlatformInstance) throws {
        try dbWriter.write { db in
            try PlatformSnapshot
                .filter(Column("platform") == instance.platform.rawValue)
                .filter(Column("instanceName") == instance.instanceName)
                .deleteAll(db)
        }
    }
}

// MARK: - Read helpers

extension AppDatabase {
    /// Returns the most recent snapshot for the given platform and instance, or nil if none exists.
    func latestSnapshot(
        for platform: Platform,
        instanceName: String = "default"
    ) throws -> PlatformSnapshot? {
        try dbWriter.read { db in
            try PlatformSnapshot
                .filter(Column("platform") == platform.rawValue)
                .filter(Column("instanceName") == instanceName)
                .order(Column("collectedAt").desc)
                .fetchOne(db)
        }
    }

    /// Returns all snapshots for a platform+instance within `[from, to]`.
    func snapshots(
        for platform: Platform,
        instanceName: String = "default",
        from: Date,
        to: Date = .now
    ) throws -> [PlatformSnapshot] {
        try dbWriter.read { db in
            try PlatformSnapshot
                .filter(Column("platform") == platform.rawValue)
                .filter(Column("instanceName") == instanceName)
                .filter(Column("collectedAt") >= from)
                .filter(Column("collectedAt") <= to)
                .order(Column("collectedAt").asc)
                .fetchAll(db)
        }
    }

    /// Returns all collection runs, most recent first.
    func allRuns(limit: Int = 50) throws -> [CollectionRun] {
        try dbWriter.read { db in
            try CollectionRun
                .order(Column("startedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Returns all snapshots for a given run.
    func snapshots(forRunID runID: Int64) throws -> [PlatformSnapshot] {
        try dbWriter.read { db in
            try PlatformSnapshot
                .filter(Column("runID") == runID)
                .fetchAll(db)
        }
    }

    /// Returns the two most recent snapshots for a platform+instance, newest first.
    /// Used by spike detection to compare the last run against the one before it.
    func twoLatestSnapshots(
        for platform: Platform,
        instanceName: String = "default"
    ) throws -> [PlatformSnapshot] {
        try dbWriter.read { db in
            try PlatformSnapshot
                .filter(Column("platform") == platform.rawValue)
                .filter(Column("instanceName") == instanceName)
                .order(Column("collectedAt").desc)
                .limit(2)
                .fetchAll(db)
        }
    }

    /// Returns the second-most-recent snapshot per (platform, instanceName) pair.
    /// Used to compute spike alerts in the feed. Instances with only one snapshot are excluded.
    func previousSnapshots() throws -> [PlatformInstance: PlatformSnapshot] {
        try dbWriter.read { db in
            // Fetch distinct (platform, instanceName) pairs.
            struct PlatformInstanceKey: FetchableRecord, Decodable {
                var platform: String
                var instanceName: String
            }
            let pairs = try PlatformInstanceKey.fetchAll(
                db,
                sql: "SELECT DISTINCT platform, instanceName FROM platformSnapshot"
            )

            var result: [PlatformInstance: PlatformSnapshot] = [:]
            for pair in pairs {
                guard let platformEnum = Platform(rawValue: pair.platform) else { continue }
                let snapshots = try PlatformSnapshot
                    .filter(Column("platform") == pair.platform)
                    .filter(Column("instanceName") == pair.instanceName)
                    .order(Column("collectedAt").desc)
                    .limit(2)
                    .fetchAll(db)
                // snapshots[0] = newest, snapshots[1] = second-newest
                if snapshots.count == 2 {
                    let key = PlatformInstance(platform: platformEnum, instanceName: pair.instanceName)
                    result[key] = snapshots[1]
                }
            }
            return result
        }
    }

    /// Returns the latest snapshot for every (platform, instanceName) pair that has at least one row.
    /// Returns a dictionary keyed by `PlatformInstance`.
    func latestSnapshots() throws -> [PlatformInstance: PlatformSnapshot] {
        try dbWriter.read { db in
            let rows = try PlatformSnapshot
                .filter(sql: """
                    (platform, instanceName, collectedAt) IN (
                        SELECT platform, instanceName, MAX(collectedAt)
                        FROM platformSnapshot
                        GROUP BY platform, instanceName
                    )
                    """)
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let inst = row.instanceEnum else { return nil }
                return (inst, row)
            })
        }
    }
}

// MARK: - Errors

enum AppDatabaseError: LocalizedError {
    /// The stored schema no longer matches the migrations.
    ///
    /// Raised instead of migrating, because GRDB skips migrations it has already
    /// applied by name — so an edited migration would otherwise leave the app
    /// running against a stale schema with no error at all.
    case schemaChanged

    var errorDescription: String? {
        switch self {
        case .schemaChanged:
            """
            The analytics database was created by a different version of Social Brain \
            and its structure no longer matches this build.

            Your data has NOT been changed. The database is at \
            ~/Library/Containers/com.catehuston.SocialBrain/Data/Library/Application Support/SocialBrain/analytics.sqlite

            Move that file aside to start fresh, or run a build whose migrations match it. \
            To let Social Brain erase and rebuild it — which permanently deletes all \
            collected history — relaunch with SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE=1.
            """
        }
    }
}
