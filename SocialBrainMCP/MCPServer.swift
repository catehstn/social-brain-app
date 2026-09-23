import Foundation

// MARK: - SnapshotStore protocol (injectable for tests)

/// The subset of database operations the MCP server needs.
/// Keyed by `PlatformInstance`, not `Platform`.
///
/// Two Mastodon accounts or two Buttondown newsletters are ordinary here
/// (#29), and keying by platform collapsed them to whichever row won — so
/// `list_platforms` showed one, `get_all_snapshots` reported one, and
/// `generate_prompt` could never render an instance label because a label is
/// only shown when a platform has more than one instance (#174, #183).
protocol SnapshotStore: Sendable {
    func latestSnapshot(for instance: PlatformInstance) throws -> PlatformSnapshot?
    func snapshots(for instance: PlatformInstance, from: Date, to: Date) throws -> [PlatformSnapshot]
    func latestSnapshots() throws -> [PlatformInstance: PlatformSnapshot]
}

// MARK: - JSON-RPC types

struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: JSONRPCId?
    let method: String
    let params: JSONRPCParams?
}

enum JSONRPCId: Codable, Equatable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let i = try? c.decode(Int.self)    { self = .int(i);    return }
        throw DecodingError.typeMismatch(JSONRPCId.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected string or int"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i):    try c.encode(i)
        }
    }
}

struct JSONRPCParams: Codable {
    let object: [String: AnyCodable]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        object = try c.decode([String: AnyCodable].self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(object)
    }

    subscript(_ key: String) -> AnyCodable? { object[key] }
}

struct JSONRPCResponse: Encodable {
    let jsonrpc: String = "2.0"
    let id: JSONRPCId?
    let result: AnyCodable?
    let error: JSONRPCError?

    init(id: JSONRPCId?, result: AnyCodable) {
        self.id = id; self.result = result; self.error = nil
    }

    init(id: JSONRPCId?, error: JSONRPCError) {
        self.id = id; self.result = nil; self.error = error
    }
}

struct JSONRPCError: Encodable {
    let code: Int
    let message: String
}

// MARK: - AnyCodable shim

/// Minimal Codable wrapper for arbitrary JSON values.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self)               { value = b;  return }
        if let i = try? c.decode(Int.self)                { value = i;  return }
        if let d = try? c.decode(Double.self)             { value = d;  return }
        if let s = try? c.decode(String.self)             { value = s;  return }
        if let a = try? c.decode([AnyCodable].self)       { value = a.map(\.value); return }
        if let o = try? c.decode([String: AnyCodable].self) {
            value = o.mapValues(\.value); return
        }
        if c.decodeNil() { value = NSNull(); return }
        throw DecodingError.typeMismatch(AnyCodable.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let b as Bool:              try c.encode(b)
        case let i as Int:               try c.encode(i)
        case let d as Double:            try c.encode(d)
        case let s as String:            try c.encode(s)
        case let a as [Any]:
            try c.encode(a.map { AnyCodable($0) })
        case let o as [String: Any]:
            try c.encode(o.mapValues { AnyCodable($0) })
        case is NSNull:                  try c.encodeNil()
        default:
            throw EncodingError.invalidValue(value,
                .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
}

// MARK: - MCP Server

/// Reads JSON-RPC 2.0 messages from stdin (newline-delimited) and writes
/// responses to stdout.  Each line must be a complete JSON object.
actor MCPServer {

    private let openStore: @Sendable () throws -> any SnapshotStore
    private var opened: (any SnapshotStore)?
    private let labels: InstanceLabels
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// The store is opened on first use, not at startup.
    ///
    /// Opening it can fail — the app creates the database on its first
    /// collection, so anyone who sets this server up from the README hits that
    /// before they have run one. Failing at startup meant the process exited,
    /// which Claude shows as "server disconnected", with the explanation only
    /// in `~/Library/Logs/Claude/mcp-server-*.log` where nobody looks (#174).
    /// Opened lazily, the same failure comes back as the answer to whatever
    /// was asked — and the server starts working the moment the app writes the
    /// file, with no restart.
    ///
    /// `labels` has no default either. It used to be `InstanceLabels.shared`,
    /// which reads `UserDefaults.standard` — this tool's own domain, not the
    /// app's, so prompts never carried a label the user had set (#183).
    /// `main.swift` passes the app's preferences.
    ///
    init(store: @escaping @Sendable () throws -> any SnapshotStore, labels: InstanceLabels) {
        self.openStore = store
        self.labels = labels
    }

    /// The store, opened once and kept.
    ///
    /// A failure is not cached: the usual cause is a database that does not
    /// exist yet, and it may exist by the next question.
    private func store() throws -> any SnapshotStore {
        if let opened { return opened }
        let store = try openStore()
        opened = store
        return store
    }

    func run() async {
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput

        // Buffer partial lines.
        var buffer = Data()

        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty {
                // EOF — client disconnected.
                break
            }
            buffer.append(chunk)

            // Process all complete lines in the buffer.
            while let newlineRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
                buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                if lineData.isEmpty { continue }

                if let responseData = await handle(lineData) {
                    stdout.write(responseData)
                    stdout.write(Data([0x0A]))
                }
            }
        }
    }

    // MARK: - Dispatch

    /// Processes a single newline-delimited JSON-RPC message and returns the
    /// serialised response, or `nil` for notifications that require no reply.
    func handle(_ data: Data) async -> Data? {
        let request: JSONRPCRequest
        do {
            request = try decoder.decode(JSONRPCRequest.self, from: data)
        } catch {
            return encode(JSONRPCResponse(
                id: nil,
                error: JSONRPCError(code: -32700, message: "Parse error: \(error)")))
        }

        let response: JSONRPCResponse
        switch request.method {
        case "initialize":
            response = handleInitialize(id: request.id)
        case "notifications/initialized":
            return nil  // Fire-and-forget notification; no response needed.
        case "tools/list":
            response = handleToolsList(id: request.id)
        case "tools/call":
            response = await handleToolCall(id: request.id, params: request.params)
        case "ping":
            response = JSONRPCResponse(id: request.id, result: AnyCodable([:] as [String: Any]))
        default:
            response = JSONRPCResponse(
                id: request.id,
                error: JSONRPCError(code: -32601, message: "Method not found: \(request.method)"))
        }
        return encode(response)
    }

    // MARK: - MCP Lifecycle

    private func handleInitialize(id: JSONRPCId?) -> JSONRPCResponse {
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": [
                "name": "social-brain",
                "version": "1.0.0"
            ] as [String: Any]
        ]
        return JSONRPCResponse(id: id, result: AnyCodable(result))
    }

    // MARK: - tools/list

    private func handleToolsList(id: JSONRPCId?) -> JSONRPCResponse {
        let tools: [[String: Any]] = [
            [
                "name": "list_platforms",
                "description": "Returns the list of platforms that have analytics data stored in the local database.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String]
                ] as [String: Any]
            ],
            [
                "name": "get_latest_snapshot",
                "description": "Returns the most recent analytics metrics for a single platform.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "platform": [
                            "type": "string",
                            "description": "Platform identifier (e.g. 'mastodon', 'bluesky', 'buttondown'). Use list_platforms to discover available platforms."
                        ] as [String: Any],
                        "instance": [
                            "type": "string",
                            "description": "Which instance of that platform, when there is more than one (e.g. a second Mastodon account). Omit when the platform has only one; list_platforms names them."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["platform"]
                ] as [String: Any]
            ],
            [
                "name": "get_all_snapshots",
                "description": "Returns the most recent analytics metrics for every platform that has data.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String]
                ] as [String: Any]
            ],
            [
                "name": "get_history",
                "description": "Returns historical analytics snapshots for a platform within a date range.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "platform": [
                            "type": "string",
                            "description": "Platform identifier."
                        ] as [String: Any],
                        "instance": [
                            "type": "string",
                            "description": "Which instance of that platform, when there is more than one. Omit when the platform has only one."
                        ] as [String: Any],
                        "days": [
                            "type": "integer",
                            "description": "Number of days of history to return (default: 30)."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["platform"]
                ] as [String: Any]
            ],
            [
                "name": "generate_prompt",
                "description": "Assembles and returns a structured analytics prompt using the most recent snapshot for every platform. Pass the result to Claude for analysis.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "period_label": [
                            "type": "string",
                            "description": "Human-readable period label (e.g. 'Last 30 days', 'All time'). Defaults to 'Latest'."
                        ] as [String: Any],
                        "days": [
                            "type": "integer",
                            "description": "Restrict snapshots to those collected within the last N days. Omit to include all time."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": [] as [String]
                ] as [String: Any]
            ]
        ]
        return JSONRPCResponse(id: id, result: AnyCodable(["tools": tools]))
    }

    // MARK: - tools/call

    private func handleToolCall(id: JSONRPCId?, params: JSONRPCParams?) async -> JSONRPCResponse {
        guard let toolName = params?["name"]?.value as? String else {
            return JSONRPCResponse(id: id, error: JSONRPCError(code: -32602, message: "Missing 'name' parameter"))
        }
        let args = (params?["arguments"]?.value as? [String: Any]) ?? [:]

        do {
            let content: Any
            switch toolName {
            case "list_platforms":
                content = try toolListPlatforms()
            case "get_latest_snapshot":
                guard let platform = args["platform"] as? String else {
                    return JSONRPCResponse(id: id, error: JSONRPCError(code: -32602, message: "Missing 'platform' argument"))
                }
                content = try toolGetLatestSnapshot(platform: platform,
                                                    instance: args["instance"] as? String)
            case "get_all_snapshots":
                content = try toolGetAllSnapshots()
            case "get_history":
                guard let platform = args["platform"] as? String else {
                    return JSONRPCResponse(id: id, error: JSONRPCError(code: -32602, message: "Missing 'platform' argument"))
                }
                let days = args["days"] as? Int ?? 30
                content = try toolGetHistory(platform: platform,
                                             instance: args["instance"] as? String,
                                             days: days)
            case "generate_prompt":
                let periodLabel = args["period_label"] as? String ?? "Latest"
                let days = args["days"] as? Int
                content = try toolGeneratePrompt(periodLabel: periodLabel, days: days)
            default:
                return JSONRPCResponse(id: id, error: JSONRPCError(code: -32602, message: "Unknown tool: \(toolName)"))
            }

            let result: [String: Any] = [
                "content": [
                    ["type": "text", "text": textFrom(content)] as [String: Any]
                ]
            ]
            return JSONRPCResponse(id: id, result: AnyCodable(result))
        } catch {
            let result: [String: Any] = [
                "content": [
                    ["type": "text", "text": "Error: \(error.localizedDescription)"] as [String: Any]
                ],
                "isError": true
            ]
            return JSONRPCResponse(id: id, result: AnyCodable(result))
        }
    }

    // MARK: - Tool implementations

    private func toolListPlatforms() throws -> Any {
        let snapshots = try store().latestSnapshots()
        if snapshots.isEmpty {
            return "No platforms have data yet. Run a collection in the Social Brain app first."
        }
        // One line per instance, named by the label the app stored for it.
        // Keyed by platform, two Mastodon accounts appeared as one (#174).
        let lines = snapshots.map { (instance, snapshot) in
            var line = "\(instance.displayName(using: labels)) (\(instance.platform.rawValue)"
            if instance.instanceName != "default" {
                line += ", instance: \(instance.instanceName)"
            }
            return line + ") — last collected \(isoDate(snapshot.collectedAt))"
        }.sorted()
        return lines.joined(separator: "\n")
    }

    /// Which instance a platform-level request means.
    ///
    /// Asking for "mastodon" is unambiguous until a second account exists, and
    /// then silently answering for one of them is the bug this issue is about.
    /// So: name it if you know it, and otherwise be told what the choices are.
    /// The outcome of naming an instance: the instance, or what to tell the
    /// caller. `Result` needs an `Error`, and "you have two Mastodon accounts"
    /// is an answer rather than a failure.
    private enum InstanceLookup {
        case found(PlatformInstance)
        case explain(String)
    }

    private func resolveInstance(
        platform: Platform, requested: String?, among known: [PlatformInstance]
    ) -> InstanceLookup {
        let instances = known.filter { $0.platform == platform }
        if let requested {
            let match = instances.first { $0.instanceName == requested }
            guard let match else {
                let names = instances.map(\.instanceName).sorted()
                return .explain(names.isEmpty
                    ? "No data for \(platform.displayName). Run a collection in the Social Brain app first."
                    : "No instance '\(requested)' for \(platform.displayName). Known: \(names.joined(separator: ", ")).")
            }
            return .found(match)
        }
        switch instances.count {
        case 0:
            return .explain("No data for \(platform.displayName). Run a collection in the Social Brain app first.")
        case 1:
            // `first`, not `[0]`: a subscript here would trap rather than fail.
            guard let only = instances.first else {
                return .explain("No data for \(platform.displayName).")
            }
            return .found(only)
        default:
            let names = instances.map(\.instanceName).sorted()
            return .explain("""
                \(platform.displayName) has \(instances.count) instances: \(names.joined(separator: ", ")). \
                Pass `instance` to choose one.
                """)
        }
    }

    private func toolGetLatestSnapshot(platform platformRaw: String, instance instanceRaw: String?) throws -> Any {
        guard let platform = Platform(rawValue: platformRaw) else {
            return "Unknown platform '\(platformRaw)'. Use list_platforms to see available platforms."
        }
        let known = Array(try store().latestSnapshots().keys)
        switch resolveInstance(platform: platform, requested: instanceRaw, among: known) {
        case .explain(let message):
            return message
        case .found(let instance):
            guard let snapshot = try store().latestSnapshot(for: instance) else {
                return "No data for \(instance.displayName(using: labels)). Run a collection in the Social Brain app first."
            }
            let metrics = try snapshot.decodedMetrics()
            return formatSnapshot(instance: instance, collectedAt: snapshot.collectedAt, metrics: metrics)
        }
    }

    private func toolGetAllSnapshots() throws -> Any {
        let snapshots = try store().latestSnapshots()
        if snapshots.isEmpty {
            return "No platforms have data yet. Run a collection in the Social Brain app first."
        }
        var lines: [String] = []
        // Every instance, ordered by what the user calls it. This iterated
        // `Platform.allCases` and showed one snapshot per platform (#174).
        for instance in snapshots.keys.sorted(by: {
            $0.displayName(using: labels) < $1.displayName(using: labels)
        }) {
            guard let snapshot = snapshots[instance] else { continue }
            let metrics = try snapshot.decodedMetrics()
            lines.append(formatSnapshot(instance: instance, collectedAt: snapshot.collectedAt, metrics: metrics))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func toolGetHistory(platform platformRaw: String, instance instanceRaw: String?, days: Int) throws -> Any {
        guard let platform = Platform(rawValue: platformRaw) else {
            return "Unknown platform '\(platformRaw)'. Use list_platforms to see available platforms."
        }
        let known = Array(try store().latestSnapshots().keys)
        let instance: PlatformInstance
        switch resolveInstance(platform: platform, requested: instanceRaw, among: known) {
        case .explain(let message): return message
        case .found(let resolved): instance = resolved
        }
        let name = instance.displayName(using: labels)
        let from = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        let history = try store().snapshots(for: instance, from: from, to: .now)
        if history.isEmpty {
            return "No history for \(name) in the last \(days) days."
        }
        var lines: [String] = ["\(name) — \(days)-day history (\(history.count) snapshots)"]
        for snapshot in history {
            let metrics = try snapshot.decodedMetrics()
            let row = metrics.sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\(metricString($0.value))" }
                .joined(separator: ", ")
            lines.append("  \(isoDate(snapshot.collectedAt)): \(row)")
        }
        return lines.joined(separator: "\n")
    }

    private func toolGeneratePrompt(periodLabel: String, days: Int?) throws -> Any {
        let allSnapshots = try store().latestSnapshots()
        if allSnapshots.isEmpty {
            return "No platforms have data yet. Run a collection in the Social Brain app first."
        }

        let cutoff: Date? = days.map { d in
            Calendar.current.date(byAdding: .day, value: -d, to: .now) ?? .distantPast
        }

        // Keyed by instance, which is what PromptAssembler takes. This built a
        // [PlatformData] until #47: the target had never compiled, so the app
        // changed the signature underneath it and nothing said so.
        var snapshotsByInstance: [PlatformInstance: PlatformSnapshot] = [:]
        for (instance, snapshot) in allSnapshots {
            if let cutoff, snapshot.collectedAt < cutoff { continue }
            snapshotsByInstance[instance] = snapshot
        }

        if snapshotsByInstance.isEmpty {
            return "No platforms have data within the requested period."
        }

        let assembler = PromptAssembler(labels: labels)
        let input = PromptAssembler.Input(
            periodLabel: periodLabel,
            reportDate: .now,
            snapshots: snapshotsByInstance
        )
        return assembler.assemble(input)
    }

    // MARK: - Formatting helpers

    private func formatSnapshot(
        instance: PlatformInstance,
        collectedAt: Date,
        metrics: [String: MetricValue]
    ) -> String {
        var lines = ["## \(instance.displayName(using: labels)) — \(isoDate(collectedAt))"]
        for (key, value) in metrics.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(key): \(metricString(value))")
        }
        return lines.joined(separator: "\n")
    }

    private func metricString(_ value: MetricValue) -> String {
        switch value {
        case .int(let v):    return String(v)
        case .double(let v): return String(format: "%.4f", v)
        case .string(let v): return v
        }
    }

    private func isoDate(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        return fmt.string(from: date)
    }

    private func textFrom(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted),
           let s = String(data: data, encoding: .utf8) { return s }
        return String(describing: value)
    }

    // MARK: - Encoding

    private func encode(_ response: JSONRPCResponse) -> Data? {
        try? encoder.encode(response)
    }
}
