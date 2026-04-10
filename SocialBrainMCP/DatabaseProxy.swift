import Foundation
import GRDB

/// Thin synchronous wrapper around the production SQLite database for use
/// inside the MCP server process.  Conforms to `SnapshotStore` so that
/// `MCPServer` can be tested with an in-memory stub.
final class DatabaseProxy: SnapshotStore, @unchecked Sendable {

    private let dbWriter: any DatabaseWriter

    init() {
        // Mirror the path logic in AppDatabase.makeDefault().
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            fatalError("Cannot locate Application Support directory")
        }
        let dbURL = appSupport
            .appendingPathComponent("SocialBrain", isDirectory: true)
            .appendingPathComponent("analytics.sqlite")

        var config = Configuration()
        // Read-only PRAGMA to avoid accidentally writing anything.
        config.readonly = true

        do {
            self.dbWriter = try DatabasePool(path: dbURL.path, configuration: config)
        } catch {
            fatalError("Cannot open database at \(dbURL.path): \(error)")
        }
    }

    // MARK: - Read operations (mirror AppDatabase)

    func latestSnapshot(for platform: Platform) throws -> PlatformSnapshot? {
        try dbWriter.read { db in
            try PlatformSnapshot
                .filter(Column("platform") == platform.rawValue)
                .order(Column("collectedAt").desc)
                .fetchOne(db)
        }
    }

    func snapshots(for platform: Platform, from: Date, to: Date = .now) throws -> [PlatformSnapshot] {
        try dbWriter.read { db in
            try PlatformSnapshot
                .filter(Column("platform") == platform.rawValue)
                .filter(Column("collectedAt") >= from)
                .filter(Column("collectedAt") <= to)
                .order(Column("collectedAt").asc)
                .fetchAll(db)
        }
    }

    func latestSnapshots() throws -> [Platform: PlatformSnapshot] {
        try dbWriter.read { db in
            let rows = try PlatformSnapshot
                .filter(sql: """
                    (platform, collectedAt) IN (
                        SELECT platform, MAX(collectedAt)
                        FROM platformSnapshot
                        GROUP BY platform
                    )
                    """)
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let p = Platform(rawValue: row.platform) else { return nil }
                return (p, row)
            })
        }
    }
}
