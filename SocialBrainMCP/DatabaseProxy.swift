import Foundation
import GRDB

/// Thin synchronous wrapper around the production SQLite database for use
/// inside the MCP server process.  Conforms to `SnapshotStore` so that
/// `MCPServer` can be tested with an in-memory stub.
final class DatabaseProxy: SnapshotStore, @unchecked Sendable {

    private let dbWriter: any DatabaseWriter

    /// Fails rather than traps when the database is not there.
    ///
    /// It very often is not: the app creates it on its first collection, so
    /// every user hits this before they have run one. A `fatalError` here
    /// reaches Claude as a process that died with no message — the server is
    /// spoken to over stdio, so a crash is all the client sees (#47).
    init() throws {
        // Mirror the path logic in AppDatabase.makeDefault().
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ProxyError.noApplicationSupportDirectory
        }
        // NOT the same path the app resolves, despite identical code.
        //
        // The app is sandboxed (`com.apple.security.app-sandbox`), so
        // `.applicationSupportDirectory` resolves inside its container. This
        // server is a plain command-line tool with no sandbox, so the same call
        // returns ~/Library/Application Support — a directory the app never
        // writes to. DatabaseProxy's comment used to say it "mirrors the path
        // logic in AppDatabase.makeDefault()", and that mirroring was the bug:
        // the code matched and the paths did not, so the server could never
        // find the database. Invisible until #47 made this target build.
        // The sandboxed location first, since that is where the shipping app
        // actually writes; the plain one second, so this keeps working if the
        // app is ever unsandboxed.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home
                .appendingPathComponent("Library/Containers/com.catehuston.SocialBrain/Data/Library/Application Support", isDirectory: true)
                .appendingPathComponent("SocialBrain", isDirectory: true)
                .appendingPathComponent("analytics.sqlite"),
            appSupport
                .appendingPathComponent("SocialBrain", isDirectory: true)
                .appendingPathComponent("analytics.sqlite")
        ]

        var config = Configuration()
        // Read-only PRAGMA to avoid accidentally writing anything.
        config.readonly = true

        guard let dbURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ProxyError.noDatabase(searched: candidates.map(\.path))
        }
        do {
            self.dbWriter = try DatabasePool(path: dbURL.path, configuration: config)
        } catch {
            throw ProxyError.cannotOpenDatabase(path: dbURL.path, underlying: error)
        }
    }

    enum ProxyError: LocalizedError {
        case noApplicationSupportDirectory
        case noDatabase(searched: [String])
        case cannotOpenDatabase(path: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .noApplicationSupportDirectory:
                return "Cannot locate the Application Support directory."
            case let .noDatabase(searched):
                return """
                    No Social Brain database found. Looked in:
                    \(searched.map { "  " + $0 }.joined(separator: "\n"))

                    The app creates it on its first collection. Open Social Brain \
                    and run one, then restart this server.
                    """
            case let .cannotOpenDatabase(path, underlying):
                return """
                    Cannot open the Social Brain database at \(path): \(underlying)

                    The app creates it on its first collection. Open Social Brain \
                    and run one, then restart this server.
                    """
            }
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
