import Foundation

/// Read-only access to the **app's** preferences, for the MCP server.
///
/// `UserDefaults.standard` is the wrong domain here, and so is
/// `UserDefaults(suiteName: "com.catehuston.SocialBrain")` — which is what
/// #183 proposed before this was measured. The app sets
/// `com.apple.security.app-sandbox`, so its preferences are written inside its
/// container:
///
///     ~/Library/Containers/com.catehuston.SocialBrain/Data/Library/Preferences/com.catehuston.SocialBrain.plist
///
/// An unsandboxed process asking for that suite reads
/// `~/Library/Preferences/com.catehuston.SocialBrain.plist`, a file the
/// sandboxed app never writes. Checked on 2026-09-22: a CLI reading the suite
/// returned `nil` for `instanceNames_mastodon` while the container plist held
/// fourteen `instanceNames_` keys.
///
/// So the plist is read as a file, by the same two-candidate rule
/// `DatabaseProxy` uses for the database — the sandboxed path first, the plain
/// one second, in case the app is ever shipped without the sandbox.
///
/// **Reads only.** The MCP server is a read-only view of the app's data: it
/// renders prompts and never sets a label. `KeyValueStore` requires the
/// setters, so they log and do nothing rather than writing a file the app owns
/// behind its back.
struct AppPreferences: KeyValueStore {

    /// The app's preferences, or an empty store when neither file exists —
    /// which is the same answer as "no labels set".
    static let shared = AppPreferences()

    private let source: PlistSource

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         preferences: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)) {
        self.source = PlistSource(
            candidates: Self.preferenceCandidates(home: home, preferences: preferences))
    }

    /// Where to look for the app's preferences, in order.
    ///
    /// A pure function taking both directories, for the same reason
    /// `DatabaseProxy.databaseCandidates` is one: the bug it encodes is a path
    /// that nothing could run and therefore nothing could test.
    static func preferenceCandidates(home: URL, preferences: URL) -> [URL] {
        [
            home
                .appendingPathComponent("Library/Containers", isDirectory: true)
                .appendingPathComponent(DatabaseProxy.bundleIdentifier, isDirectory: true)
                .appendingPathComponent("Data/Library/Preferences", isDirectory: true)
                .appendingPathComponent("\(DatabaseProxy.bundleIdentifier).plist"),
            preferences
                .appendingPathComponent("\(DatabaseProxy.bundleIdentifier).plist")
        ]
    }

    // MARK: - KeyValueStore

    func string(forKey key: String) -> String? { source.value(forKey: key) as? String }

    func stringArray(forKey key: String) -> [String]? { source.value(forKey: key) as? [String] }

    func bool(forKey key: String) -> Bool { source.value(forKey: key) as? Bool ?? false }

    func set(_ value: [String], forKey key: String) { refuseWrite(key) }
    func set(_ value: Bool, forKey key: String) { refuseWrite(key) }
    func set(_ value: String, forKey key: String) { refuseWrite(key) }
    func removeObject(forKey key: String) { refuseWrite(key) }

    private func refuseWrite(_ key: String) {
        FileHandle.standardError.write(Data(
            "SocialBrainMCP: ignoring a write to the app's preferences (\(key)); this server is read-only\n".utf8))
    }
}

/// The plist behind `AppPreferences`, re-read when the file changes.
///
/// The server is long-lived — Claude keeps it running — so reading once at
/// startup would pin whatever labels existed then, and a label set in the app
/// afterwards would never appear. Re-reading on every lookup would parse the
/// file once per metric, so the modification date decides.
private final class PlistSource: @unchecked Sendable {
    private let candidates: [URL]
    private let lock = NSLock()
    private var cached: [String: Any] = [:]
    private var cachedFrom: Date?
    private var loaded = false

    init(candidates: [URL]) {
        self.candidates = candidates
    }

    func value(forKey key: String) -> Any? {
        lock.withLock {
            guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else { return nil }

            let modified = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            if !loaded || modified != cachedFrom {
                cached = (try? Data(contentsOf: url))
                    .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
                    as? [String: Any] ?? [:]
                cachedFrom = modified ?? nil
                loaded = true
            }
            return cached[key]
        }
    }
}
