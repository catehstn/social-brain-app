# Social Brain

A native macOS app that collects analytics from the social and publishing platforms
I use, stores them in a local SQLite database, and assembles a prompt for analysis
in Claude.

Single user, single machine, offline-first. SQLite is the source of truth. The app
does **not** call the Claude API — it prepares the prompt and hands off to claude.ai.

It's a ground-up Swift rewrite of an earlier Python CLI tool.

## Requirements

| | |
|---|---|
| macOS | 14.0 (Sonoma) or later |
| Xcode | 16.3 or later |
| Swift | language mode 6.0 |
| Dependencies | [GRDB.swift](https://github.com/groue/GRDB.swift) 7.x, via Swift Package Manager |

No CocoaPods, no Carthage, no Python runtime. SPM resolves GRDB on first build.

## Getting started

```sh
git clone https://github.com/catehstn/social-brain-app.git
cd social-brain-app
open SocialBrain.xcodeproj
```

Then ⌘R to run, or from the command line:

```sh
xcodebuild build -scheme SocialBrain -destination 'platform=macOS'
```

The project file is **checked in directly**. There is no generation step — don't
install XcodeGen, and don't regenerate `SocialBrain.xcodeproj`. `Info.plist` and
`SocialBrain.entitlements` are tracked in git and edited by hand.

### Signing

`DEVELOPMENT_TEAM` is deliberately empty, so a fresh clone builds without an Apple
Developer account. Xcode will sign to run locally. To run on another machine or to
distribute, set your team in the target's Signing & Capabilities tab (tracked as
issue #36).

## Running the tests

Unit tests — run these before and after every change:

```sh
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
  -only-testing:SocialBrainTests
```

One suite is opt-in: `SetupURLTests` checks the platform setup links against
the live web, so it's skipped by default to keep the suite hermetic. Run it
deliberately when you change a setup URL:

```sh
RUN_NETWORK_TESTS=1 xcodebuild test -scheme SocialBrain \
  -destination 'platform=macOS' -only-testing:SocialBrainTests/SetupURLTests
```

**Don't run `SocialBrainUITests` locally.** They launch the full app and take over
your screen. CI runs them on every push and pull request.

## Where things live

```
SocialBrain/
  App/          App entry point, background refresh, notifications
  Collectors/   One file per platform, all conforming to `Collector`
  Database/     GRDB schema, migrations, query helpers
  Models/       Shared types, feed-card building, spike/reach detection
  OAuth/        ASWebAuthenticationSession flows (Mastodon, WordPress)
  Keychain/     Credential storage via the Security framework
  Prompt/       Prompt assembly
  Views/        SwiftUI, one directory per screen, each `View` + `ViewModel`
SocialBrainTests/     Unit tests
SocialBrainUITests/   UI tests (CI only)
SocialBrainMCP/       MCP server — NOT currently part of any build target
docs/                 Design brief, platform setup guide, plans
```

### Architecture notes

- **Pure Swift.** All collectors use `URLSession` directly. No Python subprocess.
- **Views never touch GRDB.** Each screen takes an `AppDatabase` and pairs with an
  `@Observable` ViewModel; the domain logic lives in `Models/` as pure functions.
  This is what makes the view layer replaceable.
- **Credentials live in the Keychain only** — never in `UserDefaults` or on disk.
- **Background refresh uses `NSBackgroundActivityScheduler`**, not `BGTaskScheduler`
  (which is iOS-only).

## The data

The SQLite store lives at:

```
~/Library/Application Support/SocialBrain/analytics.sqlite
```

### Platforms

Grouped by how much work they are to connect:

- **API key** — Buttondown, GoatCounter, Calendly, Amazon KDP, Google Search Console, Buffer
- **OAuth / token** — Mastodon, Bluesky, Jetpack (WordPress.com)
- **File export** — LinkedIn (XLSX), O'Reilly (email), Substack (CSV)
- **No auth** — Hacker News

Per-platform setup instructions are in `docs/index.html`.

## Contributing

See [CLAUDE.md](CLAUDE.md) for the working conventions: branch per change, tests for
every collector and every migration, one PR per logical change.

Current state of the repo and the prioritised backlog:
[docs/repo-cleanup-plan.md](docs/repo-cleanup-plan.md).

## Known gaps

- `SocialBrainMCP/` is not in any build target and has never compiled.
- No tests for the Google Search Console, Hacker News, or Buffer collectors, the
  LinkedIn XLSX parser, the ZIP reader, or either OAuth flow.
- The app is unsigned and not distributable.
