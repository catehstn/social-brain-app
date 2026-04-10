# Claude Code Guidelines for social-brain (desktop app)

## Critical rules for subagents

**Planning subagents:** Your ONLY job is to write a `trycycle-plan.md` file in the worktree and commit it. Do NOT implement code, open PRs, merge branches, or do anything else. Stop after writing the plan.

**Never merge to main without explicit user approval.** No subagent may run `gh pr merge`, `git merge`, or `git push` to main unless the user has explicitly said to do so in the current conversation turn.

## Overview

Social Brain is a native macOS app that collects analytics from social/publishing
platforms, stores them in a local SQLite database, and generates prompts for
analysis in Claude. It is a ground-up Swift rewrite of the original Python CLI tool.

## Architecture

- **Pure Swift — no Python.** All platform collectors are written in Swift using
  URLSession. There is no Python subprocess or bundled runtime.
- **SwiftUI** for all UI. macOS 14+ target.
- **Swift Package Manager** for all dependencies. No CocoaPods or Carthage.
- **SQLite via GRDB.swift** for the local analytics store (replaces analytics.xlsx).
- **Keychain** (via the Security framework) for all credential storage. No plaintext
  config files.
- **Swift Charts** for the dashboard (week / month / 3 month / all time views).
- **ASWebAuthenticationSession** for OAuth flows (Mastodon, Jetpack).
- **UserNotifications** for stale-export reminders.
- **BGTaskScheduler** for the morning auto-refresh.

## Project structure

```
SocialBrain/
  App/                  # App entry point, AppDelegate if needed
  Collectors/           # One file per platform (Mastodon.swift, Bluesky.swift, …)
  Database/             # GRDB schema, migrations, query helpers
  Models/               # Shared data types
  Views/                # SwiftUI views
    Onboarding/
    Dashboard/
    Settings/
    Run/
  Prompt/               # Prompt assembly logic
  MCP/                  # MCP server (later phase)
SocialBrainTests/
SocialBrainUITests/
```

## Git workflow

- **Always create a new branch** before making any commits. Never commit to `main`.
- Branch names: short and descriptive (`sqlite-schema`, `mastodon-collector`, `onboarding-ui`).
- One PR per logical change.
- Push branch and open a PR when the work is ready.

## Testing

- Run the full test suite before and after every change: Cmd+U in Xcode, or
  `xcodebuild test -scheme SocialBrain` from the command line.
- All tests must pass before opening a PR.
- **Add tests for every collector** — mock URLSession responses, assert the parsed
  model matches expected values.
- **Add tests for every database migration** — verify schema upgrades don't lose data.
- UI tests for the onboarding wizard and main run flow.

## Collectors

Each collector lives in `Collectors/<Platform>.swift` and conforms to a shared
`Collector` protocol:

```swift
protocol Collector {
    var platform: Platform { get }
    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData
}
```

Platforms are grouped by integration difficulty for the onboarding UI:
- **Easy (API key):** Buttondown, GoatCounter, Vercel, Calendly, Amazon
- **Medium (OAuth / token):** Mastodon, Jetpack, Bluesky
- **Hard (file export):** LinkedIn, O'Reilly, Substack

## App Store considerations

- All file access via `NSOpenPanel` or drag-and-drop with security-scoped bookmarks.
- No network calls outside of declared domains (add to entitlements as needed).
- Credentials stored in Keychain only — never in UserDefaults or on disk unencrypted.
- Background refresh via BGTaskScheduler (registered in Info.plist).
- Sandbox entitlements: outgoing network connections, read/write to user-selected files.

## Prompt size and cost

- The prompt assembly logic (Prompt/) should mirror the trimming behaviour of the
  original analyse.py — counts and summaries, not full lists.
- Measure generated prompt size after significant changes.

## PR description

Include in every PR:
- What changed and why
- Whether tests pass
- Any validation done (e.g. tested against live API, or with mock data)
