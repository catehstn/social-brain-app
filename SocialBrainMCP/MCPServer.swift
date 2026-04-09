import Foundation

// MARK: - SnapshotStore protocol (injectable for tests)

/// The subset of database operations the MCP server needs.
protocol SnapshotStore: Sendable {
    func latestSnapshot(for platform: Platform) throws -> PlatformSnapshot?
    func snapshots(for platform: Platform, from: Date, to: Date) throws -> [PlatformSnapshot]
    func latestSnapshots() throws -> [Platform: PlatformSnapshot]
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

    private let store: any SnapshotStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(store: any SnapshotStore = DatabaseProxy()) {
        self.store = store
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
                content = try toolGetLatestSnapshot(platform: platform)
            case "get_all_snapshots":
                content = try toolGetAllSnapshots()
            case "get_history":
                guard let platform = args["platform"] as? String else {
                    return JSONRPCResponse(id: id, error: JSONRPCError(code: -32602, message: "Missing 'platform' argument"))
                }
                let days = args["days"] as? Int ?? 30
                content = try toolGetHistory(platform: platform, days: days)
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
        let snapshots = try store.latestSnapshots()
        if snapshots.isEmpty {
            return "No platforms have data yet. Run a collection in the Social Brain app first."
        }
        let lines = snapshots.map { (platform, snapshot) in
            "\(platform.displayName) (\(platform.rawValue)) — last collected \(isoDate(snapshot.collectedAt))"
        }.sorted()
        return lines.joined(separator: "\n")
    }

    private func toolGetLatestSnapshot(platform platformRaw: String) throws -> Any {
        guard let platform = Platform(rawValue: platformRaw) else {
            return "Unknown platform '\(platformRaw)'. Use list_platforms to see available platforms."
        }
        guard let snapshot = try store.latestSnapshot(for: platform) else {
            return "No data for \(platform.displayName). Run a collection in the Social Brain app first."
        }
        let metrics = try snapshot.decodedMetrics()
        return formatSnapshot(platform: platform, collectedAt: snapshot.collectedAt, metrics: metrics)
    }

    private func toolGetAllSnapshots() throws -> Any {
        let snapshots = try store.latestSnapshots()
        if snapshots.isEmpty {
            return "No platforms have data yet. Run a collection in the Social Brain app first."
        }
        var lines: [String] = []
        for platform in Platform.allCases {
            guard let snapshot = snapshots[platform] else { continue }
            let metrics = try snapshot.decodedMetrics()
            lines.append(formatSnapshot(platform: platform, collectedAt: snapshot.collectedAt, metrics: metrics))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func toolGetHistory(platform platformRaw: String, days: Int) throws -> Any {
        guard let platform = Platform(rawValue: platformRaw) else {
            return "Unknown platform '\(platformRaw)'. Use list_platforms to see available platforms."
        }
        let from = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        let history = try store.snapshots(for: platform, from: from, to: .now)
        if history.isEmpty {
            return "No history for \(platform.displayName) in the last \(days) days."
        }
        var lines: [String] = ["\(platform.displayName) — \(days)-day history (\(history.count) snapshots)"]
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
        let allSnapshots = try store.latestSnapshots()
        if allSnapshots.isEmpty {
            return "No platforms have data yet. Run a collection in the Social Brain app first."
        }

        let cutoff: Date? = days.map { d in
            Calendar.current.date(byAdding: .day, value: -d, to: .now) ?? .distantPast
        }

        var platformData: [PlatformData] = []
        for (platform, snapshot) in allSnapshots {
            if let cutoff, snapshot.collectedAt < cutoff { continue }
            let metrics = try snapshot.decodedMetrics()
            platformData.append(PlatformData(
                platform: platform,
                collectedAt: snapshot.collectedAt,
                metrics: metrics
            ))
        }

        if platformData.isEmpty {
            return "No platforms have data within the requested period."
        }

        let assembler = PromptAssembler()
        let input = PromptAssembler.Input(
            periodLabel: periodLabel,
            reportDate: .now,
            snapshots: platformData
        )
        return assembler.assemble(input)
    }

    // MARK: - Formatting helpers

    private func formatSnapshot(
        platform: Platform,
        collectedAt: Date,
        metrics: [String: MetricValue]
    ) -> String {
        var lines = ["## \(platform.displayName) — \(isoDate(collectedAt))"]
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
