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
let server = MCPServer()
await server.run()
