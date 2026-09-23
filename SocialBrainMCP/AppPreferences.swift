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

    /// `preferences` defaults to `home`'s own `Library/Preferences`, so a test
    /// passing only `home:` cannot leave the real one as the second candidate.
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         preferences: URL? = nil) {
        self.source = PlistSource(
            candidates: Self.preferenceCandidates(
                home: home,
                preferences: preferences
                    ?? home.appendingPathComponent("Library/Preferences", isDirectory: true)))
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
///
/// "When the file changes" is the limit of the promise: the app writes
/// preferences through `cfprefsd`, which flushes them lazily, so a label set
/// in the app reaches this file — and therefore this server — some time later
/// rather than at once.
///
/// A file that cannot be read or parsed reads as no values, and says so on
/// stderr. Empty is the right answer for the server (no labels, so plain
/// platform names), but a silent empty would look identical to a user who has
/// set none.
private final class PlistSource: @unchecked Sendable {
    private let candidates: [URL]
    private let lock = NSLock()
    private var cached: [String: Any] = [:]
    private var cachedFrom: Date?
    private var loaded = false

    /// The plist as a dictionary, or empty — with a line on stderr — when it
    /// cannot be read, is not a property list, or is not a dictionary at its
    /// root. A truncated or half-written file lands here.
    private static func read(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else {
            complain("could not read \(url.lastPathComponent)")
            return [:]
        }
        guard let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            complain("could not parse \(url.lastPathComponent)")
            return [:]
        }
        guard let dictionary = parsed as? [String: Any] else {
            complain("\(url.lastPathComponent) is not a dictionary")
            return [:]
        }
        return dictionary
    }

    private static func complain(_ message: String) {
        FileHandle.standardError.write(Data(
            "SocialBrainMCP: \(message); continuing without the app's preferences\n".utf8))
    }

    init(candidates: [URL]) {
        self.candidates = candidates
    }

    func value(forKey key: String) -> Any? {
        lock.withLock {
            guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else { return nil }

            // The modification date alone: it carries sub-second precision, so
            // two writes cannot share one. (Round-tripping such a date through
            // `setAttributes` does lose precision — which is why a test trying
            // to pin a same-timestamp rewrite passed without testing anything,
            // and was removed rather than kept.)
            let modified = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            if !loaded || modified != cachedFrom {
                cached = Self.read(url)
                cachedFrom = modified
                loaded = true
            }
            return cached[key]
        }
    }
}
