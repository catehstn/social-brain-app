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

// MARK: - Read helpers

extension AppDatabase {
    /// Returns the most recent snapshot for the given platform, or nil if none exists.
    func latestSnapshot(for platform: Platform) throws -> PlatformSnapshot? {
        try dbWriter.read { db in
            try PlatformSnapshot
                .filter(Column("platform") == platform.rawValue)
                .order(Column("collectedAt").desc)
                .fetchOne(db)
        }
    }

    /// Returns all snapshots for a platform within `[from, to]`.
    func snapshots(
        for platform: Platform,
        from: Date,
        to: Date = .now
    ) throws -> [PlatformSnapshot] {
        try dbWriter.read { db in
            try PlatformSnapshot
                .filter(Column("platform") == platform.rawValue)
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
}
