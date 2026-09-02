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
- **Branch from `origin/main`, not local `main`:**
  `git fetch origin && git checkout -b <name> origin/main`. Local `main` can be
  ahead of origin when a push was rejected, and branching from it silently drags
  unrelated commits onto the new branch.
- Branch names: short and descriptive (`sqlite-schema`, `mastodon-collector`, `onboarding-ui`).
- One PR per logical change.
- Before committing to an existing branch, check whether its PR is already merged
  (`gh pr view`). Commits pushed after a merge are never included.
- Push branch and open a PR when the work is ready.

## Before opening a PR

Dispatch a fresh reviewer subagent to critique the diff. It should have no
context from the conversation that produced the change — just the diff against
`main`, the draft PR description, and the files it needs to verify claims
against. Ask it for correctness problems, missing tests, stale docs, and
scope creep, and to check assertions against the code rather than trusting the
description.

Address anything blocking before asking a human to look. This has already paid
for itself: the review of #44 caught documentation that contradicted the shipped
app, and a documented test command that silently skipped and exited 0.

## Testing

- Run unit tests locally before and after every change:
  `xcodebuild test -scheme SocialBrain -destination 'platform=macOS' -only-testing:SocialBrainTests`
- **Do NOT run `SocialBrainUITests` locally** — they launch the full macOS app and
  take over the screen. They are kept out of the default `SocialBrain` scheme for
  this reason, so ⌘U and a bare `xcodebuild test -scheme SocialBrain` are safe.
  CI runs them via the separate `SocialBrain-UITests` scheme on every push and PR.
  If you add a UI test target, add it to that scheme — not the default one.
- All unit tests must pass before opening a PR.
- **Tests ship in the same PR as the code.** Never a follow-up PR.
- **If a change makes existing tests fail, fix the tests to match the new correct
  behaviour** — don't revert the change to make them pass. If the old assertion
  was right, the change is wrong; decide which, don't split the difference.

### What needs a test

| Change | Expected test |
|---|---|
| New collector | Mock `URLSession` (see `SocialBrainTests/TestSupport/MockURLSession.swift`): happy path, `since` filter, error propagation |
| New database migration | Schema upgrade preserves existing rows |
| New parser or file importer | Real fixture, plus malformed and empty input — these read untrusted files |
| New model logic (detectors, prompt assembly, feed cards) | Unit test on the pure function |
| Bug fix | A regression test that **fails before the fix and passes after**. Write it first and watch it fail. |
| Intentional behaviour change | Update the assertions to the new contract; delete the old ones rather than weakening them |
| Refactor with no behaviour change | None required |
| UI / view-layer change | UI test in `SocialBrainUITests/` if it changes a flow, not just appearance |

"Add tests for every collector" is the floor, not the ceiling. The gaps that
accumulated here — `MiniZIPReader`, `LinkedInXLSXParser`, both OAuth flows —
were all things that were neither a collector nor a migration.
- UI tests for the onboarding wizard and main run flow live in `SocialBrainUITests/`
  and are maintained for CI.

## CI

- **Treat a single green check as provisional.** Before reporting a PR as passing
  — or merging it — confirm all three jobs (**Unit Tests**, **UI Tests**,
  **Release Build**) have *concluded* green, not just started, and that they ran
  against the current head commit.
- **A green check is only worth what the pipeline can actually fail on.** This
  repo reported success for months while not building at all: `xcodebuild |
  xcpretty` without `pipefail` returns the *formatter's* exit code, so the failing
  build was masked. Every step that pipes `xcodebuild` must run under
  `shell: bash -eo pipefail {0}`. Don't remove it.
- **When you add a way to run something, verify it actually runs.** A command that
  skips everything and exits 0 looks identical to a pass. `RUN_NETWORK_TESTS=1
  xcodebuild test` did exactly that — environment variables need the
  `TEST_RUNNER_` prefix to reach the test host. Run it and confirm the test count
  is non-zero.
- **Run the tests locally before pushing.** macOS runners bill at a **10x** minute
  multiplier, so the ~2,000 free minutes/month are really ~200 macOS-minutes. Three
  jobs fire on every push. Pushing to find out is not free.
- CI floats on the runner's default Xcode; local development is on a newer one.
  That gap has already caught a real bug (see `ISO8601Decoding.swift`) and also
  costs a round-trip when a failure doesn't reproduce locally. Policy is being
  decided in #51.

## Issue tracking

Filing an issue is not finished until it has all three:

| Field | Rule |
|---|---|
| Priority | **Always.** `P0` (blocks other work) / `P1` (next) / `P2` (someday). Guess if you must — a wrong priority gets corrected, a missing one gets skipped. |
| Area | **Always.** Exactly one of `area:build` `area:ci` `area:design` `area:collectors` `area:docs`. |
| Milestone | **Always**, unless genuinely un-schedulable. `M1 — Runnable again`, `M2 — Design pass`, `M3 — Ship`. |
| `blocked` | **Only if** waiting on something outside this repo. Then it gets no milestone. |

## README

Update it whenever **user-facing** behaviour changes: new platform, changed setup
steps, new build or test command, changed data location. Internal refactors don't
need a README change.

The "Getting started" and "Running the tests" sections must stay executable — if a
command in there doesn't work as written, that's a bug.

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
- Whether tests pass, and the count — "218 tests in 32 suites pass" beats
  "tests pass", which is what a broken build also says
- Any validation done (tested against a live API, with mock data, on real
  exported files)
- Anything you could **not** verify, and why
