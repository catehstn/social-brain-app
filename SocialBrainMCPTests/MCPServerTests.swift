import Testing
import Foundation

// Shared sources are compiled into SocialBrainMCP, not a separate framework,
// so we test by importing the types directly (same compilation unit via target).

// MARK: - Stub store

/// In-memory SnapshotStore for testing — seeded with canned snapshots.
struct StubStore: SnapshotStore, Sendable {

    let snapshots: [Platform: PlatformSnapshot]

    init(_ snapshots: [Platform: PlatformSnapshot] = [:]) {
        self.snapshots = snapshots
    }

    func latestSnapshot(for platform: Platform) throws -> PlatformSnapshot? {
        snapshots[platform]
    }

    func snapshots(for platform: Platform, from: Date, to: Date) throws -> [PlatformSnapshot] {
        guard let snap = snapshots[platform], snap.collectedAt >= from, snap.collectedAt <= to else {
            return []
        }
        return [snap]
    }

    func latestSnapshots() throws -> [Platform: PlatformSnapshot] {
        snapshots
    }
}

// MARK: - Helpers

private func makeSnapshot(
    platform: Platform,
    metrics: [String: MetricValue],
    collectedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
) throws -> PlatformSnapshot {
    let data = PlatformData(platform: platform, collectedAt: collectedAt, metrics: metrics)
    return try PlatformSnapshot(runID: 1, data: data)
}

private func json(_ bytes: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:]
}

// Run a single JSON-RPC call through MCPServer and decode the response.
private func call(
    method: String,
    id: Int = 1,
    params: [String: Any],
    store: any SnapshotStore
) async throws -> [String: Any] {
    let server = MCPServer(store: store, labels: InstanceLabels(defaults: MemoryStore()))
    var body: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "method": method
    ]
    if !params.isEmpty {
        body["params"] = params
    }
    let data = try JSONSerialization.data(withJSONObject: body)
    guard let response = await server.handle(data) else {
        return [:]
    }
    return json(response)
}

// Extract the "text" content from a tools/call response.
private func toolText(from response: [String: Any]) -> String? {
    guard let result = response["result"] as? [String: Any],
          let content = result["content"] as? [[String: Any]],
          let first = content.first,
          let text = first["text"] as? String else { return nil }
    return text
}

// MARK: - Tests

@Suite("MCP Server Tests")
struct MCPServerTests {

    // MARK: Protocol lifecycle

    @Test("initialize returns correct protocol version")
    func initializeHandshake() async throws {
        let response = try await call(
            method: "initialize",
            params: ["protocolVersion": "2024-11-05", "clientInfo": ["name": "test"] as [String: Any]],
            store: StubStore()
        )
        let result = response["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == "2024-11-05")
        let serverInfo = result?["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "social-brain")
    }

    @Test("notifications/initialized returns nil (no response)")
    func initializedNotification() async throws {
        let server = MCPServer(store: StubStore(), labels: InstanceLabels(defaults: MemoryStore()))
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ] as [String: Any])
        let response = await server.handle(body)
        #expect(response == nil)
    }

    @Test("unknown method returns -32601 error")
    func unknownMethod() async throws {
        let response = try await call(method: "nonexistent", params: [:], store: StubStore())
        let error = response["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32601)
    }

    @Test("malformed JSON returns -32700 parse error")
    func parseError() async throws {
        let server = MCPServer(store: StubStore(), labels: InstanceLabels(defaults: MemoryStore()))
        let garbage = Data("not-json".utf8)
        // #require, not #expect plus `!`: #expect does not halt, so a nil
        // response would walk into the force unwrap and kill the runner
        // instead of failing the test. This file only started running with
        // #47, so #169's sweep never reached it.
        let decoded = json(try #require(await server.handle(garbage)))
        let error = decoded["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32700)
    }

    @Test("ping returns empty result")
    func ping() async throws {
        let response = try await call(method: "ping", params: [:], store: StubStore())
        #expect(response["result"] != nil)
        #expect(response["error"] == nil)
    }

    // MARK: tools/list

    @Test("tools/list returns five tools")
    func toolsList() async throws {
        let response = try await call(method: "tools/list", params: [:], store: StubStore())
        let result = response["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        #expect(tools?.count == 5)
        let names = tools?.compactMap { $0["name"] as? String } ?? []
        #expect(names.contains("list_platforms"))
        #expect(names.contains("get_latest_snapshot"))
        #expect(names.contains("get_all_snapshots"))
        #expect(names.contains("get_history"))
        #expect(names.contains("generate_prompt"))
    }

    // MARK: list_platforms tool

    @Test("list_platforms with no data returns helpful message")
    func listPlatformsEmpty() async throws {
        let response = try await call(
            method: "tools/call",
            params: ["name": "list_platforms", "arguments": [:] as [String: Any]],
            store: StubStore()
        )
        let text = toolText(from: response)
        #expect(text?.contains("No platforms have data") == true)
    }

    @Test("list_platforms lists seeded platforms")
    func listPlatformsWithData() async throws {
        let snap = try makeSnapshot(platform: .mastodon, metrics: ["followers": .int(500)])
        let response = try await call(
            method: "tools/call",
            params: ["name": "list_platforms", "arguments": [:] as [String: Any]],
            store: StubStore([.mastodon: snap])
        )
        let text = toolText(from: response)
        #expect(text?.contains("Mastodon") == true)
        #expect(text?.contains("mastodon") == true)
    }

    // MARK: get_latest_snapshot tool

    @Test("get_latest_snapshot returns metrics for known platform")
    func getLatestSnapshotKnown() async throws {
        let snap = try makeSnapshot(
            platform: .bluesky,
            metrics: ["followers": .int(1234), "posts": .int(56)]
        )
        let response = try await call(
            method: "tools/call",
            params: ["name": "get_latest_snapshot", "arguments": ["platform": "bluesky"]],
            store: StubStore([.bluesky: snap])
        )
        let text = toolText(from: response)
        #expect(text?.contains("Bluesky") == true)
        #expect(text?.contains("followers: 1234") == true)
    }

    @Test("get_latest_snapshot with unknown platform returns error message")
    func getLatestSnapshotUnknown() async throws {
        let response = try await call(
            method: "tools/call",
            params: ["name": "get_latest_snapshot", "arguments": ["platform": "tiktok"]],
            store: StubStore()
        )
        let text = toolText(from: response)
        #expect(text?.contains("Unknown platform") == true)
    }

    @Test("get_latest_snapshot with no data for platform returns helpful message")
    func getLatestSnapshotNoData() async throws {
        let response = try await call(
            method: "tools/call",
            params: ["name": "get_latest_snapshot", "arguments": ["platform": "mastodon"]],
            store: StubStore()  // empty — no mastodon snapshot
        )
        let text = toolText(from: response)
        #expect(text?.contains("No data for") == true)
    }

    @Test("get_latest_snapshot missing platform arg returns RPC error")
    func getLatestSnapshotMissingArg() async throws {
        let response = try await call(
            method: "tools/call",
            params: ["name": "get_latest_snapshot", "arguments": [:] as [String: Any]],
            store: StubStore()
        )
        let error = response["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32602)
    }

    // MARK: get_all_snapshots tool

    @Test("get_all_snapshots returns all seeded platforms")
    func getAllSnapshots() async throws {
        let mastodonSnap = try makeSnapshot(
            platform: .mastodon,
            metrics: ["followers": .int(200)]
        )
        let blueskySnap = try makeSnapshot(
            platform: .bluesky,
            metrics: ["followers": .int(100)]
        )
        let response = try await call(
            method: "tools/call",
            params: ["name": "get_all_snapshots", "arguments": [:] as [String: Any]],
            store: StubStore([.mastodon: mastodonSnap, .bluesky: blueskySnap])
        )
        let text = toolText(from: response)
        #expect(text?.contains("Mastodon") == true)
        #expect(text?.contains("Bluesky") == true)
    }

    // MARK: get_history tool

    @Test("get_history returns snapshot within date window")
    func getHistoryWithinWindow() async throws {
        // Snapshot collected "now" — well within any reasonable window.
        let snap = try makeSnapshot(
            platform: .buttondown,
            metrics: ["subscribers": .int(999)],
            collectedAt: .now
        )
        let response = try await call(
            method: "tools/call",
            params: ["name": "get_history", "arguments": ["platform": "buttondown", "days": 7]],
            store: StubStore([.buttondown: snap])
        )
        let text = toolText(from: response)
        #expect(text?.contains("Buttondown") == true)
        #expect(text?.contains("subscribers=999") == true)
    }

    @Test("get_history returns no-history message when empty")
    func getHistoryEmpty() async throws {
        let response = try await call(
            method: "tools/call",
            params: ["name": "get_history", "arguments": ["platform": "buttondown", "days": 7]],
            store: StubStore()
        )
        let text = toolText(from: response)
        #expect(text?.contains("No history") == true)
    }

    // MARK: generate_prompt tool

    @Test("generate_prompt returns assembled prompt")
    func generatePrompt() async throws {
        // Use the metric keys that PromptAssembler.mastodonLines() recognises.
        let snap = try makeSnapshot(
            platform: .mastodon,
            metrics: ["followers_count": .int(1500), "statuses_count": .int(200)],
            collectedAt: .now
        )
        let response = try await call(
            method: "tools/call",
            params: ["name": "generate_prompt", "arguments": ["period_label": "Last 30 days"]],
            store: StubStore([.mastodon: snap])
        )
        let text = toolText(from: response)
        #expect(text?.contains("Social Media & Publishing Analytics Report") == true)
        #expect(text?.contains("Last 30 days") == true)
        #expect(text?.contains("Mastodon") == true)
    }

    // There is deliberately no test here that a label reaches a prompt.
    // `PromptAssembler` consults labels only for a platform with more than one
    // instance, and `SnapshotStore.latestSnapshots()` is keyed by `Platform`,
    // so this server can never present two instances of one platform (#174).
    // Until that is fixed, the injected store is unobservable through the MCP
    // surface, and a test asserting otherwise would be asserting the bug.
    // `AppPreferencesTests` below covers the store itself.

    @Test("generate_prompt with no data returns helpful message")
    func generatePromptEmpty() async throws {
        let response = try await call(
            method: "tools/call",
            params: ["name": "generate_prompt", "arguments": [:] as [String: Any]],
            store: StubStore()
        )
        let text = toolText(from: response)
        #expect(text?.contains("No platforms have data") == true)
    }
}

// MARK: - Where the database is looked for (#47)

@Suite("Database location")
struct DatabaseLocationTests {

    private let home = URL(fileURLWithPath: "/Users/someone")
    private var appSupport: URL { home.appendingPathComponent("Library/Application Support") }

    @Test("The sandboxed container is searched first")
    func containerPathComesFirst() throws {
        // The app sets com.apple.security.app-sandbox, so its
        // .applicationSupportDirectory resolves inside its container. This
        // server is an unsandboxed command-line tool, where the identical call
        // returns ~/Library/Application Support — a directory the app never
        // writes to. DatabaseProxy used to say it "mirrors the path logic in
        // AppDatabase.makeDefault()", and that mirroring was the bug: matching
        // code, different paths, so the database could never be found.
        let candidates = DatabaseProxy.databaseCandidates(home: home, appSupport: appSupport)

        let first = try #require(candidates.first).path
        #expect(first == "/Users/someone/Library/Containers/com.catehuston.SocialBrain"
                       + "/Data/Library/Application Support/SocialBrain/analytics.sqlite")
    }

    @Test("The unsandboxed location is still searched, second")
    func plainPathIsTheFallback() throws {
        // So this keeps working if the app is ever shipped without the sandbox.
        let candidates = DatabaseProxy.databaseCandidates(home: home, appSupport: appSupport)

        #expect(candidates.count == 2)
        let second = try #require(candidates.dropFirst().first).path
        #expect(second == "/Users/someone/Library/Application Support/SocialBrain/analytics.sqlite")
    }

    @Test("The container path is built from the bundle identifier constant")
    func containerUsesTheBundleIdentifier() throws {
        // Structural only, deliberately. Asserting the constant equals a copy
        // of its own literal proves nothing, and nothing here can reach the app
        // target's PRODUCT_BUNDLE_IDENTIFIER — this tool is a separate binary
        // and cannot read the app's Info.plist. So renaming the app would leave
        // these green and the server unable to find the database; the failure
        // would be loud at runtime (the error names both searched paths) rather
        // than caught here. #174 tracks the wider gap.
        let candidates = DatabaseProxy.databaseCandidates(home: home, appSupport: appSupport)
        let first = try #require(candidates.first).path

        #expect(first.contains("/Containers/" + DatabaseProxy.bundleIdentifier + "/"))
        #expect(!first.contains("/Containers//"), "the identifier must not be empty")
    }
}


// MARK: - Where the app's preferences are looked for (#183)

@Suite("App preferences")
struct AppPreferencesTests {

    private let home = URL(fileURLWithPath: "/Users/someone")
    private var preferences: URL { home.appendingPathComponent("Library/Preferences") }

    @Test("The sandboxed container is searched first")
    func containerPathComesFirst() throws {
        // Measured on 2026-09-22: an unsandboxed process reading
        // UserDefaults(suiteName: "com.catehuston.SocialBrain") saw none of the
        // keys the app had written, because the app is sandboxed and its plist
        // lives in its container. #183 proposed that suite as the fix; it is
        // not one. This is the preferences half of #47.
        let candidates = AppPreferences.preferenceCandidates(home: home, preferences: preferences)

        let first = try #require(candidates.first).path
        #expect(first == "/Users/someone/Library/Containers/com.catehuston.SocialBrain"
                       + "/Data/Library/Preferences/com.catehuston.SocialBrain.plist")
    }

    @Test("The unsandboxed location is still searched, second")
    func plainPathComesSecond() throws {
        let candidates = AppPreferences.preferenceCandidates(home: home, preferences: preferences)
        let second = try #require(candidates.dropFirst().first).path
        #expect(second == "/Users/someone/Library/Preferences/com.catehuston.SocialBrain.plist")
    }

    /// A container plist in a temporary directory, and the store that reads it.
    private func makeStore(_ contents: [String: Any]) throws -> (AppPreferences, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app-prefs-\(UUID().uuidString)", isDirectory: true)
        let dir = root
            .appendingPathComponent("Library/Containers/com.catehuston.SocialBrain", isDirectory: true)
            .appendingPathComponent("Data/Library/Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plist = dir.appendingPathComponent("com.catehuston.SocialBrain.plist")
        try PropertyListSerialization
            .data(fromPropertyList: contents, format: .binary, options: 0)
            .write(to: plist)
        return (AppPreferences(home: root, preferences: root.appendingPathComponent("none")), plist)
    }

    @Test("Reads values the app wrote into its container")
    func readsContainerPlist() throws {
        let (store, _) = try makeStore([
            "instanceLabel_mastodon:default": "The Work Account",
            "instanceNames_mastodon": ["default", "work"],
            "hasCompletedOnboarding": true
        ])

        #expect(store.string(forKey: "instanceLabel_mastodon:default") == "The Work Account")
        #expect(store.stringArray(forKey: "instanceNames_mastodon") == ["default", "work"])
        #expect(store.bool(forKey: "hasCompletedOnboarding"))
        #expect(store.string(forKey: "absent") == nil)
        #expect(store.bool(forKey: "absent") == false)
    }

    @Test("A label set while the server is running is picked up")
    func rereadsWhenTheFileChanges() throws {
        // The server is long-lived, so reading once at startup would pin
        // whatever labels existed when Claude launched it.
        let (store, plist) = try makeStore(["instanceLabel_mastodon:default": "Before"])
        #expect(store.string(forKey: "instanceLabel_mastodon:default") == "Before")

        // A second apart, because the cache compares modification dates and
        // HFS+ timestamps have one-second resolution.
        try PropertyListSerialization
            .data(fromPropertyList: ["instanceLabel_mastodon:default": "After"], format: .binary, options: 0)
            .write(to: plist)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: plist.path)

        #expect(store.string(forKey: "instanceLabel_mastodon:default") == "After")
    }

    @Test("Writes do not touch the app's preferences")
    func writesAreRefused() throws {
        // The server is a read-only view of the app's data. KeyValueStore
        // requires setters; these must not write a file the app owns.
        let (store, plist) = try makeStore(["instanceLabel_mastodon:default": "Untouched"])
        let before = try Data(contentsOf: plist)

        store.set("Overwritten", forKey: "instanceLabel_mastodon:default")
        store.set(["a"], forKey: "instanceNames_mastodon")
        store.set(true, forKey: "hasCompletedOnboarding")
        store.removeObject(forKey: "instanceLabel_mastodon:default")

        #expect(try Data(contentsOf: plist) == before)
        #expect(store.string(forKey: "instanceLabel_mastodon:default") == "Untouched")
    }

    @Test("No plist at all reads as no values, not a crash")
    func missingFileIsEmpty() {
        let nowhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app-prefs-missing-\(UUID().uuidString)", isDirectory: true)
        let store = AppPreferences(home: nowhere, preferences: nowhere)

        #expect(store.string(forKey: "instanceLabel_mastodon:default") == nil)
        #expect(store.stringArray(forKey: "instanceNames_mastodon") == nil)
    }
}


/// A throwaway `KeyValueStore`, so no test reaches a real preferences domain.
///
/// The app's suite has one in `SocialBrainTests/TestSupport`, which is not a
/// member of this target; a copy is cheaper than sharing a file whose other
/// contents this target does not need.
final class MemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func stringArray(forKey key: String) -> [String]? { lock.withLock { values[key] as? [String] } }
    func string(forKey key: String) -> String? { lock.withLock { values[key] as? String } }
    func bool(forKey key: String) -> Bool { lock.withLock { values[key] as? Bool ?? false } }
    func set(_ value: [String], forKey key: String) { lock.withLock { values[key] = value } }
    func set(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func set(_ value: Bool, forKey key: String) { lock.withLock { values[key] = value } }
    func removeObject(forKey key: String) { lock.withLock { values[key] = nil } }
}
