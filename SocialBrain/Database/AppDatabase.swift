import Foundation
import GRDB

/// The application's single GRDB database, wrapped in an actor for safe concurrent access.
actor AppDatabase {
    /// Directly accessible without hopping through the actor because `DatabaseWriter`
    /// inherits `Sendable` from `DatabaseReader`, and this is an immutable `let` binding.
    nonisolated let dbWriter: any DatabaseWriter

    // MARK: - Lifecycle

    /// Creates or opens the database at the default location and runs all
    /// migrations.
    ///
    /// Under a test host this opens a **throwaway** database instead. Unit tests
    /// are injected into the app, so launching them runs `SocialBrainApp`, which
    /// opens this — meaning every `xcodebuild test` run previously opened and
    /// migrated the user's real store. That is not theoretical: an experimental
    /// migration run in an isolated git worktree was applied to the real
    /// database, twice, because the file is shared by every checkout. Had it
    /// held data rather than being empty, the history would have been destroyed
    /// and could not have been re-fetched.
    static func makeDefault() throws -> AppDatabase {
        let config = AppDatabase.makeConfiguration()
        let dbPool = try DatabasePool(path: try defaultDatabaseURL().path, configuration: config)
        return try AppDatabase(dbPool)
    }

    /// `true` when this process must not touch the user's real data.
    ///
    /// Two signals, because there are two ways the app runs under test:
    ///
    /// - **Unit tests** are injected into the app host, which therefore has
    ///   `XCTestConfigurationFilePath` set. `AppDelegate` already keys off this
    ///   to close windows at launch.
    /// - **UI tests** launch the app as a *separate process*, which does **not**
    ///   inherit that variable — that is precisely why the windows stay open for
    ///   them. So the UI test targets set their own environment variable.
    ///   Without this second signal a UI-test run still opened and migrated the
    ///   real store, which the first version of this change missed.
    ///
    /// Deliberately an environment variable rather than a launch argument:
    /// `NSUserDefaults` parses the argument domain as `-key value` pairs, so a
    /// bare `-useThrowawayDatabase` swallows whichever flag follows it as its
    /// value. That silently broke `-hasCompletedOnboarding 0` and with it every
    /// onboarding UI test.
    static var isRunningUnderTest: Bool {
        let info = ProcessInfo.processInfo
        return info.environment["XCTestConfigurationFilePath"] != nil
            || info.environment[throwawayDatabaseEnvironmentKey] == "1"
    }

    /// Set by `SocialBrainUITests` so the launched app keeps off the real data.
    static let throwawayDatabaseEnvironmentKey = "SOCIALBRAIN_USE_THROWAWAY_DATABASE"

    /// Where the database lives — the real Application Support location
    /// normally, a per-process temporary directory under a test host.
    static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let container: URL
        if isRunningUnderTest {
            // Per-process, so concurrent test runs cannot collide. A directory
            // is also removed on first use in this process: pids are recycled,
            // so without that a run assigned a leftover pid would inherit the
            // previous run's database rather than starting clean.
            prepareTestContainerOnce()
            container = fm.temporaryDirectory
                .appendingPathComponent(testContainerPrefix + "\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        } else {
            container = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let dir = container.appendingPathComponent("SocialBrain", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("analytics.sqlite")
    }

    private static let testContainerPrefix = "SocialBrainTests-"

    /// Deletes throwaway databases left by earlier test processes.
    ///
    /// A per-process directory with no cleanup is how 266 orphaned plists
    /// accumulated elsewhere in this app; one file per test run adds up the same
    /// way. Only directories belonging to processes that are no longer running
    /// are removed, so concurrent runs are safe.
    /// Runs the cleanup exactly once per process, however often the path is
    /// resolved. `Bool` rather than a closure so the value is `Sendable`; the
    /// work happens in the initialiser, which Swift runs lazily and exactly once.
    private static let didPrepareTestContainer: Bool = {
        removeStaleTestDatabases()
        return true
    }()

    private static func prepareTestContainerOnce() {
        _ = didPrepareTestContainer
    }

    private static func removeStaleTestDatabases() {
        let fm = FileManager.default
        let current = ProcessInfo.processInfo.processIdentifier
        guard let entries = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory, includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix(testContainerPrefix) {
            let suffix = entry.lastPathComponent.dropFirst(testContainerPrefix.count)
            // pid > 0: kill(0, …) and kill(-1, …) address a process group and
            // every process respectively, which is not what is meant here.
            guard let pid = Int32(suffix), pid > 0 else { continue }

            if pid == current {
                // Ours, inherited from a dead process that had this pid. Start clean.
                try? fm.removeItem(at: entry)
                continue
            }
            // kill(pid, 0) succeeds only if the process exists and is signalable.
            // ESRCH means it is gone; EPERM means it exists, so leave it alone.
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? fm.removeItem(at: entry)
            }
        }
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
    ///     open --env SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE=1 SocialBrain.app  # app
    ///     TEST_RUNNER_SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE=1 xcodebuild test  # tests
    ///
    /// A bare `SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE=1 open …` does not work:
    /// `open` goes through LaunchServices and does not forward the shell
    /// environment.
    static var erasesOnSchemaChange: Bool {
        erases(from: ProcessInfo.processInfo.environment["SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE"])
    }

    /// Split out so the contract can be table-tested. Reading the environment
    /// inside the assertion made the test compare `ProcessInfo` against
    /// `ProcessInfo`, which no configuration CI runs could falsify.
    static func erases(from raw: String?) -> Bool {
        raw == "1"
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
        // Opt in explicitly while doing schema work — see `erasesOnSchemaChange`
        // for the exact invocations; the bare `VAR=1 xcodebuild` form does not
        // reach a test host.
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

        migrator.registerMigration("v3_period_end") { db in
            // The period an imported export describes, distinct from when it was
            // collected. Overloading collectedAt with both roles broke
            // uniqueness, the staleness clock and the spike comparison at once.
            try db.alter(table: "platformSnapshot") { t in
                t.add(column: "periodEnd", .datetime)
            }
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
                // COALESCE, not collectedAt: the chart plots periodEnd where it
                // exists, so filtering on the import clock made the range
                // selector lie in both directions — a backfill imported today
                // was drawn a year to the left inside a "7 days" window, and a
                // recent period imported two months ago was excluded from it.
                .filter(sql: "COALESCE(periodEnd, collectedAt) >= ?", arguments: [from])
                .filter(sql: "COALESCE(periodEnd, collectedAt) <= ?", arguments: [to])
                .order(sql: "COALESCE(periodEnd, collectedAt) ASC")
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
            // `uniqueKeysWithValues` is a precondition, not an error — two rows
            // sharing a MAX(collectedAt) for one instance would trap, and no
            // caller's do/catch can absorb that. Keep the higher rowid instead.
            return Dictionary(rows.compactMap { row -> (PlatformInstance, PlatformSnapshot)? in
                guard let inst = row.instanceEnum else { return nil }
                return (inst, row)
            }, uniquingKeysWith: { first, second in
                (second.id ?? 0) > (first.id ?? 0) ? second : first
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

            Your data has NOT been changed. The database lives in \
            ~/Library/Containers/com.catehuston.SocialBrain/Data/Library/Application Support/SocialBrain/

            To start fresh, move the whole folder aside — analytics.sqlite has -wal and \
            -shm companions, and moving only the .sqlite leaves a stale write-ahead log \
            behind. Otherwise, run a build whose migrations match it.

            To let Social Brain erase and rebuild the database instead — which permanently \
            deletes all collected history — quit using the button below, then run:

              open -n --env SOCIALBRAIN_ERASE_ON_SCHEMA_CHANGE=1 -b com.catehuston.SocialBrain

            (-b finds the app wherever it is installed; -n forces a new instance, since \
            `open` on an already-running app just activates it and drops the variable.)
            """
        }
    }
}
