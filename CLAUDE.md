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
- **The `.xcodeproj` is checked in and hand-edited.** There is no XcodeGen step;
  `Info.plist` and `SocialBrain.entitlements` are tracked in git.
- **SQLite via GRDB.swift** for the local analytics store (replaces analytics.xlsx).
- **Keychain** (via the Security framework) for all credential storage. No plaintext
  config files.
- **Swift Charts** for the dashboard (week / month / 3 month / all time views).
- **ASWebAuthenticationSession** for OAuth flows (Mastodon, Jetpack).
- **UserNotifications** for stale-export reminders.
- **NSBackgroundActivityScheduler** for the morning auto-refresh. (`BGTaskScheduler`
  is iOS-only and unavailable on native macOS.)

## Project structure

```
SocialBrain/
  App/                  # Entry point, background refresh, notifications
  Collectors/           # One file per platform (MastodonCollector.swift, …)
  Database/             # GRDB schema, migrations, query helpers
  Keychain/             # Credential storage via the Security framework
  Models/               # Shared types, feed cards, spike/reach detection
  OAuth/                # ASWebAuthenticationSession flows
  Prompt/               # Prompt assembly logic
  Resources/            # Bundled setup guide
  Views/                # SwiftUI — one directory per screen, View + ViewModel
    Onboarding/ Dashboard/ Feed/ History/ Platforms/ Run/ Settings/ Sidebar/
SocialBrainTests/       # Unit tests (Swift Testing)
SocialBrainUITests/     # UI tests — CI only, they take over the screen
SocialBrainMCP/         # MCP server — NOT in any build target, see #47
docs/                   # Design brief, setup guide, plans
```

## Git workflow

- **Always create a new branch** before making any commits. Never commit to `main`.
- Branch names: short and descriptive (`sqlite-schema`, `mastodon-collector`, `onboarding-ui`).
- One PR per logical change.
- Push branch and open a PR when the work is ready.

## Testing

- Run unit tests locally before and after every change:
  `xcodebuild test -scheme SocialBrain -destination 'platform=macOS' -only-testing:SocialBrainTests`
- **Do NOT run `SocialBrainUITests` locally** — UI tests launch the full macOS app and
  are disruptive during development. They run automatically on CI (GitHub Actions) on
  every push and PR.
- All unit tests must pass before opening a PR.
- **Add tests for every collector** — mock URLSession responses, assert the parsed
  model matches expected values.
- **Add tests for every database migration** — verify schema upgrades don't lose data.
- UI tests for the onboarding wizard and main run flow live in `SocialBrainUITests/`
  and are maintained for CI.

## Collectors

Each collector lives in `Collectors/<Platform>.swift` and conforms to a shared
`Collector` protocol:

```swift
protocol Collector: Sendable {
    var platform: Platform { get }
    /// The instance name for this collector. Defaults to `"default"`.
    var instanceName: String { get }
    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData
    /// Human-readable label for this instance (newsletter name, handle, …).
    /// Called once after credentials are saved. `nil` if none can be determined.
    func fetchLabel(credentials: Credentials) async -> String?
}
```

Platforms are grouped by integration difficulty for the onboarding UI:
- **Easy (API key):** Buttondown, GoatCounter, Calendly, Buffer, Vercel
- **Medium (OAuth / token):** Mastodon, Jetpack, Bluesky, Google Search Console
- **Hard (file export):** Amazon KDP, LinkedIn, O'Reilly, Substack
- **No auth:** Hacker News

`Platform.authType` is the source of truth — update it and this list together.

## App Store considerations

- All file access via `NSOpenPanel` or drag-and-drop. **Security-scoped bookmarks
  are not implemented yet** — imports read the file once during the drop. Needed
  before any feature re-reads a file across launches.
- No network calls outside of declared domains (add to entitlements as needed).
- Credentials stored in Keychain only — never in UserDefaults or on disk unencrypted.
- Background refresh via NSBackgroundActivityScheduler (no Info.plist key needed).
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
