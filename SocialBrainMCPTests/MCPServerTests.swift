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
    let server = MCPServer(store: store)
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
        let server = MCPServer(store: StubStore())
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
        let server = MCPServer(store: StubStore())
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
