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

    private init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try Self.migrator.migrate(dbWriter)
    }

    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

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
