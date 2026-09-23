/// Social Brain MCP Server
///
/// Implements the Model Context Protocol (JSON-RPC 2.0 over stdio) so that
/// Claude can query the local analytics SQLite database directly.
///
/// Exposed tools:
///   • list_platforms      — which platform instances have data
///   • get_latest_snapshot — latest metrics for one instance
///   • get_all_snapshots   — latest metrics for every instance with data
///   • get_history         — snapshots for one instance within a date range
///   • generate_prompt     — run PromptAssembler and return the text
///
/// The tools that take a platform also take an optional `instance`, for an
/// account or newsletter that is not the only one of its platform. Asked
/// without it where there are several, they say which exist rather than
/// answering for whichever row won (#174).
///
/// Usage (add to Claude's MCP config at ~/Library/Application Support/Claude/claude_desktop_config.json):
///   {
///     "mcpServers": {
///       "social-brain": {
///         "command": "/path/to/SocialBrainMCP"
///       }
///     }
///   }
///
/// Build the binary:
///   xcodebuild build -scheme SocialBrainMCP -configuration Release \
///     -derivedDataPath build
///   # Binary at: build/Build/Products/Release/SocialBrainMCP
///
/// The server reads from the same SQLite database that the Social Brain app
/// writes to. The app is sandboxed, so that is inside its container:
///   ~/Library/Containers/com.catehuston.SocialBrain/Data/Library/Application Support/SocialBrain/analytics.sqlite
/// `DatabaseProxy` falls back to the unsandboxed location if the app is ever
/// shipped without the sandbox.
///
/// Instance labels come from the app's preferences, which are a plist in the
/// same container. `AppPreferences` reads that file: `UserDefaults` here is
/// this tool's own domain, and `UserDefaults(suiteName:)` resolves outside the
/// container, so neither can see what the app wrote (#183). Preferences are
/// flushed by `cfprefsd` rather than written immediately, so a label set in
/// the app can take a little while to appear here.
/// Run a collection in the app before querying via MCP — and if you have not,
/// the tools say so rather than the server failing to start.

import Foundation

// MARK: - Entry point

// Run the server on the main thread; async entry point keeps the run loop alive.
//
// The database is opened on the first question, not here. It often does not
// exist yet — the app creates it on its first collection — and exiting at
// startup showed up in Claude as "server disconnected", with the explanation
// buried in ~/Library/Logs/Claude/mcp-server-*.log (#174). Asked lazily, the
// same explanation arrives as the answer, and the server starts working once
// the app writes the file without needing a restart.
let server = MCPServer(store: { try DatabaseProxy() },
                       labels: InstanceLabels(defaults: AppPreferences.shared))
await server.run()
