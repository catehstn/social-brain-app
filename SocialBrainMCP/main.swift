/// Social Brain MCP Server
///
/// Implements the Model Context Protocol (JSON-RPC 2.0 over stdio) so that
/// Claude can query the local analytics SQLite database directly.
///
/// Exposed tools:
///   • list_platforms      — which platforms have data
///   • get_latest_snapshot — latest metrics for one platform
///   • get_all_snapshots   — latest metrics for every platform with data
///   • get_history         — snapshots for a platform within a date range
///   • generate_prompt     — run PromptAssembler and return the text
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
/// The server reads from the same SQLite database that the Social Brain app writes to:
///   ~/Library/Application Support/SocialBrain/analytics.sqlite
/// Run a collection in the app before querying via MCP.

import Foundation

// MARK: - Entry point

// Run the server on the main thread; async entry point keeps the run loop alive.
//
// The database is opened here rather than in a default argument so that a
// missing one is reported instead of trapping. stdout is the JSON-RPC channel,
// so the message goes to stderr, which Claude surfaces as server output.
do {
    let server = MCPServer(store: try DatabaseProxy())
    await server.run()
} catch {
    FileHandle.standardError.write(Data("SocialBrainMCP: \(error.localizedDescription)\n".utf8))
    exit(1)
}
