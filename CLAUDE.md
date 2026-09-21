# Claude Code Guidelines for social-brain (desktop app)

## Critical rules for subagents

**Planning subagents:** Your ONLY job is to write the plan and commit it. On a first round you choose the filename, following the trycycle convention — `docs/plans/YYYY-MM-DD-<feature-name>.md`, or `-test-plan.md` for a test plan — and report it back as `## Plan path`; the skill populates `IMPLEMENTATION_PLAN_PATH` from what you report. On an edit or reconsider round you are given that path and must use it. Do NOT implement code, open PRs, merge branches, or do anything else. Stop after writing the plan.

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
  config files. **Two services, and the split is load-bearing:**
  `com.catehuston.SocialBrain` holds platform credentials keyed
  `"<platform.rawValue>:<instanceName>"`, and `OrphanedCredentials.find` depends
  on that being the only shape in there — it reports any account it cannot parse
  as a platform as a stranded API token, with a Remove button in Settings.
  Mastodon's OAuth app registrations are keyed by server host, so they live in
  `com.catehuston.SocialBrain.mastodon-apps` (`MastodonAppRegistrations`).
  Anything else needing the Keychain under a different key shape gets its own
  service too, rather than an exception in the scanner.
- **Swift Charts** for the dashboard (week / month / 3 month / all time views).
- **ASWebAuthenticationSession** for OAuth flows (Mastodon, Jetpack).
- **UserNotifications** for stale-export reminders.
- **NSBackgroundActivityScheduler** for the morning auto-refresh. (`BGTaskScheduler`
  is iOS-only and unavailable on native macOS.)

## Project structure

```
SocialBrain/
  App/                  # Entry point, background refresh, notifications
  Collectors/           # One file per platform (MastodonCollector.swift, …),
                        # plus the shared pieces they use: Collector (the
                        # protocol), CollectionEngine, ExportDates,
                        # ISO8601Decoding, RateParsing, MiniZIPReader,
                        # LinkedInXLSXParser
  Database/             # GRDB schema, migrations, query helpers
  Keychain/             # Credential storage via the Security framework
  Models/               # Shared types, feed cards, spike/reach detection
  OAuth/                # ASWebAuthenticationSession flows
  Prompt/               # Prompt assembly logic
  Resources/            # Bundled setup guide
  Views/                # SwiftUI — one directory per screen; most pair a View
                        # with a ViewModel (Onboarding, Settings and Sidebar don't)
    Onboarding/ Dashboard/ Feed/ History/ Platforms/ Run/ Settings/ Sidebar/
SocialBrainTests/       # Unit tests (Swift Testing)
SocialBrainUITests/     # UI tests — CI only, they take over the screen
SocialBrainMCP/         # MCP server — its own tool target and scheme (#47)
SocialBrainMCPTests/    # Its tests; the SocialBrainMCP scheme runs them
docs/                   # Design brief, setup guide, plans
```

## Git workflow

- **Always create a new branch** before making any commits. Never commit to `main`,
  and never force-push to it.
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
- The MCP server is a separate target with its own suite, not covered by the
  above: `xcodebuild test -scheme SocialBrainMCP -destination 'platform=macOS'`
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
- **Persistent state is injected.** Four types store things
  outside the database — `InstanceRegistry`, `PlatformVisibilityStore`,
  `InstanceLabels`, `AnalyticsGoalStore` — and each takes a `KeyValueStore`
  through its initialiser with a `static let shared` for production. The
  protocol lives in its own `Models/KeyValueStore.swift` because two of those
  types compile into the MCP targets as well as the app, and it used to sit in
  `InstanceRegistry.swift`, which does not.
  `UserDefaults.standard` appears in exactly four lines of the app, one per
  store; `KeychainStore` is the same shape with `service`. **A new store follows
  that pattern**, because a `static var` global is repointed by whichever suite
  runs first and stays repointed (#58), and a type reaching for the global
  directly means the first test to touch it writes the developer's own
  settings (#90).

  That four-line claim is enforced, not just asserted: `InjectedDefaultsTests`
  greps `SocialBrain/` and `SocialBrainMCP/`, so a fifth use fails the suite and
  names the file. An `is UserDefaults` check on the shared store is not the same
  thing — it passes for a suite-named store, and says nothing about any other
  file.

  **That describes the stores, not every caller.** These still read one of the
  four `UserDefaults`-backed globals directly (`KeychainStore.shared` has its
  own direct readers, not listed here): `PlatformCredentialSheet` and `PlatformDetailView`
  (`InstanceLabels.shared`), `OnboardingView` (`AnalyticsGoalStore.shared`),
  `SocialBrainApp` (`PlatformVisibilityStore.shared.resetAll()`),
  `PlatformInstance.displayName` (`displayName(using: .shared)`) and
  `MCPServer` (`PromptAssembler(labels: .shared)` — #183). Views are not under
  test, so most of this is tolerated rather than wrong; `PlatformInstance` is
  not a view, which is why `displayName` has a `using:` form and tests must
  call it.

  **Do not restate that as a count.** Three attempts in one PR gave three wrong
  numbers, because `grep "InstanceLabels.shared"` cannot see `displayName(using:
  .shared)` — the type is inferred, so the store's name never appears. Both
  forms need grepping, and `: \.shared` also matches the *approved* pattern of
  passing a store explicitly (`PlatformsView`, `RunView`), so the two cannot be
  told apart mechanically. Hence a list, not a total.

  **`PlatformsViewModel`, `RunViewModel` and `PromptAssembler` take no
  production default**, and their call sites pass `.shared` explicitly. The
  first says so in a comment recording the run where the suite destroyed real
  credentials — and then grew `labels: InstanceLabels = .shared` anyway,
  directly under that comment, in the branch that added the injection. Four
  tests silently held real preferences, and nothing exercised the parameter
  because the stub fetcher returned `nil`. It happened twice more in the same
  branch: `RunViewModel` gained a defaulted `goals:` and hardcoded
  `PromptAssembler(labels: .shared)`. **Adding an injectable store and giving
  it a production default is the failure mode to watch for** — it looks like
  the fix and leaves the hazard.

  **Three declarations still default to production** and are not yet
  converted — only one of them is an initialiser, which is why "check the
  inits" misses two: `FeedViewModel.init` and the static `FeedCardBuilder.build`
  (`visibility:`), and the static `CollectorRegistry.configured`
  (`instances:`, `hasCredentials:`). That last one is *not* on
  `CollectionEngine`, whose *initialiser* takes only a database — they share a
  file. The actor is not clean at call time, though: it formats a
  missing-credential error with the bare `displayName`, so running it reads
  real labels. #184.

  **`@AppStorage` is the hole the grep cannot see**, since it never names
  `UserDefaults.standard`. Six uses remain, pinned key-by-key in the same test:
  the analytics goal in two views (bypassing `AnalyticsGoalStore`) and
  `hasCompletedOnboarding`, which has no store at all — and whose two
  declarations disagree on the default (#182).

  Watch for the indirect path: `PlatformInstance.displayName` consults the
  label store, so `PromptAssembler` had to take one too — its prompt headers
  were reading real preferences, and a test had been passing by luck. A test
  that wants the plain string calls `displayName(using:)` with a throwaway
  store; the bare property reads `.shared`, so a stored label breaks it.

  **Mutation-testing one of these seams aims the whole suite at real storage.**
  Snapshot first (`defaults read com.catehuston.SocialBrain`), or mutate a call
  site rather than the seam.
- **Never let a test trap.** A trapping test does not fail: it kills the test
  host, and the test host **is `SocialBrain.app`** (`TEST_HOST` in the project
  file), so it shows "SocialBrain quit unexpectedly" and writes an `.ips` instead
  of a red test, and the runner restarts and may crash again. `#expect` does not
  halt on failure, so a count assertion above a subscript records its issue and
  execution walks straight into the trap.

  In practice: no `xs[0]` — use `xs.first?`, `xs.dropFirst().first?` or
  `try #require(xs.first)`; and no `!` on anything a *different* change could
  make nil, such as `prompt.range(of:)!` or `cases.firstIndex(of:)!`. Force
  unwrapping a genuinely infallible literal (`"…".data(using: .utf8)!`,
  `TimeZone(identifier: "Europe/Berlin")!`) is fine and left alone.

  This bit on 2026-09-19: a metric rename emptied one detector's result and
  `items[0]` crashed the app in front of the user. #167 converted the rest.
- **Prefer mutations that fail rather than trap** when checking a test is not
  vacuous, for the same reason — a mutation that empties a collection crashes the
  run instead of failing it. That is also why this class survived so long: a bare
  subscript reads as normal, and only bites when something else empties the array.

### What needs a test

| Change | Expected test |
|---|---|
| New collector | Mock `URLSession` (see `SocialBrainTests/TestSupport/MockURLSession.swift`, or `GraphQLMockSession.swift` beside it for a GraphQL API, where every query shares one URL): happy path, `since` filter, error propagation. **Also add its metric keys to `MetricKeyOrphanTests.emitted`** — see below |
| New metric key on an existing collector | Add it to `MetricKeyOrphanTests.emitted`, and make some consumer read it |
| New database migration | Schema upgrade preserves existing rows |
| New parser or file importer | Real fixture, plus malformed and empty input — these read untrusted files |
| New model logic (detectors, prompt assembly, feed cards) | Unit test on the pure function |
| Bug fix | A regression test that **fails before the fix and passes after**. Write it first and watch it fail. |
| Intentional behaviour change | Update the assertions to the new contract; delete the old ones rather than weakening them |
| Refactor with no behaviour change | None required |
| UI / view-layer change | UI test in `SocialBrainUITests/` if it changes a flow, not just appearance |

**A metric nothing reads is a bug, and `MetricKeyOrphanTests` fails the build
for it.** Keys are plain strings spread across five consumers, so a platform can
be renamed into invisibility: the import succeeds and contributes nothing to the
prompt, the charts, the Feed or spike detection. That has happened three times —
#114, #163 and #170.

It checks **one direction only**. A consumer reading a key that no collector
emits is the mirror image, is not caught, and has also happened — #171.

The check is **per platform**, which is the whole point: grepping for
`total_clicks` finds two consumers and looks fine, and both are Buffer's while
LinkedIn is what emits it. "Is this key read anywhere?" is the wrong question.

Its `emitted` table is hand-maintained, so **adding a key without adding it
there makes it invisible to the detector** — the same shape as the bug. Hence
the table rows above; #173 is about removing the need for them. An orphan you mean to keep goes in `knownOrphans` with an
issue number; two further tests assert each listed orphan is still emitted and
still unread, so the list shrinks rather than rots.

"Add tests for every collector" was both **under-enforced and under-scoped**.
Under-enforced: three collectors shipped with no tests at all
(`GoogleSearchConsoleCollector`, `HackerNewsCollector`, `BufferCollector` — #48).
Under-scoped: the parsers and OAuth flows (`MiniZIPReader`,
`LinkedInXLSXParser`, both OAuth types — #49, #50) fell outside the rule
entirely, being neither a collector nor a migration. The table above widens the
scope; enforcement is on whoever reviews the PR.

**Carve-out for UI tests.** The five Platforms UI tests are `XCTSkip`-ed pending
the redesign (#40, #46), and UI tests are not run locally. So for a PR that
changes a Platforms flow before #40 lands, don't write a UI test you can't run
against a screen that's about to be replaced — say so in the PR description
instead. Everywhere else the table applies.

## CI

- **Treat a single green check as provisional.** Before reporting a PR as passing
  — or merging it — confirm all four jobs (**Unit Tests**, **UI Tests**,
  **MCP Server**, **Release Build**) have *concluded* green, not just started,
  and that they ran against the current head commit.
- **CI minutes are free *while this repo is public*.** Standard GitHub-hosted
  runners are unmetered on public repos: every run reports
  `billable.MACOS.total_ms = 0`. Verify with
  `gh api repos/catehstn/social-brain-app/actions/runs/<id>/timing`.

  **If the repo ever goes private this bullet becomes wrong**, and so do two
  comments in `ci.yml` (the concurrency group and `release-build`). Re-check
  with that endpoint before trusting any of the three.

  This has now caused the same mistake twice. The audit and #91 were written
  while the repo was private and the allowance was genuinely exhausted; that
  changed on 2026-09-04 and is recorded in #91's comments, not its body. A
  later pass read only the body, rebuilt the whole cost case, and proposed
  trading PR coverage to save a bill of zero. **Read the comments.** Wall-clock
  time is still worth arguing about; billed minutes are not.
- **A green check is only worth what the pipeline can actually fail on.** This
  repo reported success for months while not building at all: `xcodebuild |
  xcpretty` without `pipefail` returns the *formatter's* exit code, so the failing
  build was masked. Every step that pipes `xcodebuild` must run under
  `shell: bash --noprofile --norc -eo pipefail {0}`. Don't remove the `pipefail`.
  (The `--noprofile --norc` half is GitHub's own default, which a custom `shell:`
  silently drops; it changes nothing for non-interactive bash but keeps the
  steps from reading the runner's profile.)
- **When you add a way to run something, verify it actually runs.** A command that
  skips everything and exits 0 looks identical to a pass. `RUN_NETWORK_TESTS=1
  xcodebuild test` did exactly that — environment variables need the
  `TEST_RUNNER_` prefix to reach the test host. Run it and confirm the test count
  is non-zero.
- **Run the tests locally before pushing.** Not for the bill — see above — but
  because a macOS runner takes minutes to tell you what `xcodebuild` tells you
  in seconds, and a red PR is noise for whoever looks next. The
  workflow triggers on pushes to `main` and on pull requests, so a feature-branch
  push runs nothing until a PR exists — after that, every job fires on every
  push to it.
- **Every job needs `timeout-minutes`.** GitHub's default is 360, so one stuck
  step holds a runner for six hours and blocks the queue behind it.
- **The CI/local Xcode gap is deliberate** (#51). CI floats on the runner's
  default — Xcode 16.4 (16F6) at the time of writing — while local development
  is on 26.6. Newer swift-foundation is more lenient, so CI is the stricter
  check, and it has already caught a real bug: `JSONDecoder`'s `.iso8601`
  strategy rejects fractional seconds, so the Mastodon and Bluesky collectors
  passed locally and failed on CI, which is how we learned they would fail
  against their **live APIs**. `ISO8601Decoding.swift` names Mastodon, Bluesky
  and Calendly.

  The cost is a round-trip when a failure doesn't reproduce locally — suspect
  the toolchain before suspecting the change.

  A matrix over both versions is **not** ruled out on cost — there is none. It
  is not being done because eight macOS jobs would queue against the free
  tier's concurrency cap, so the wall-clock cost is real even though the bill is
  not. That is a judgement made here, not measured: #51 rejected the matrix on
  the billed-minutes grounds that turned out to be false, so if anyone wants the
  matrix, the wall-clock claim is the one to test.

  **The README's stated minimum must match what CI actually verifies.** It said
  16.3 while CI ran 16.4; if the runner image moves, update both.

## Issue tracking

Filing an issue is not finished until it carries these:

| Field | Rule |
|---|---|
| Priority | **Always.** `P0` (blocks other work) / `P1` (next) / `P2` (someday). Guess if you must — a wrong priority gets corrected, a missing one gets skipped. |
| Area | **Always.** At least one of `area:build` `area:ci` `area:design` `area:collectors` `area:docs`. Prefer one; use two only when the work genuinely lands in both, as #46 (a UI test rewrite: `ci` + `design`) and #60 (a test that is also a docs decision: `ci` + `docs`) do. |
| Milestone | **Always**, unless genuinely un-schedulable. `M1 — Runnable again`, `M2 — Design pass`, `M3 — Ship`. |
| `blocked` | **Only if** waiting on something outside this repo. Then it gets no milestone. |

## Test fixtures from real data

**Redact by allowlist, never by denylist.** A string in a checked-in fixture
survives only if a parser reads it, or is a date or a number. Everything else is
replaced.

This is not a style preference. A "redacted" LinkedIn export in this repo was
built the other way — replace digits, replace dates, replace the one name I
thought of — and shipped to a public repo carrying 49 post URLs, two demographics
tables naming employers, job titles, seniority and locations, and the account
name in `docProps/core.xml`, a file the redaction never opened. Checking it meant
grepping for the name, which the denylist *had* removed: it verified the rule
had run, not that the file was safe.

`FixtureRedactionTests` enforces this on every `.xlsx` in `SocialBrainTests/
Fixtures/`, across every XML part rather than just `sharedStrings`. Adding a
string to its allowlist is a deliberate act; that is the point.

## Living docs

**Doc updates go in the same PR as the code change, never a follow-up.**

`docs/design-brief.md` and `docs/repo-cleanup-plan.md` are living docs referenced
from here and from the README. When a change makes one of them wrong, fix it in
the same PR. They go stale fast, and a stale doc is worse than no doc because it
gets trusted: #61 exists because the design brief promised a mentions synthesis
the code has never had, and the design pass was about to be planned from it.
(The line was cut in #123, so #61 is now about whether to build one at all.)

## README

Update it whenever **user-facing** behaviour changes: new platform, changed setup
steps, new build or test command, changed data location. Internal refactors don't
need a README change.

The "Getting started" and "Running the tests" sections must stay executable — if a
command in there doesn't work as written, that's a bug.

## Collectors

Each collector lives in `Collectors/` — `<Platform>Collector.swift` for API-backed
sources, `<Platform>Importer.swift` for file-export ones — and conforms to a
shared `Collector` protocol:

```swift
protocol Collector: Sendable {
    var platform: Platform { get }
    /// The instance name for this collector. Defaults to `"default"`.
    var instanceName: String { get }
    /// `since` is required, and `.distantPast` means "as far back as this
    /// platform allows" — each collector clamps to its own stated limit.
    /// An optional here meant five different windows depending on the
    /// collector, so "All time" was not comparable across platforms (#96).
    func collect(since: Date, credentials: Credentials) async throws -> PlatformData
    /// Human-readable label for this instance (newsletter name, handle, …).
    /// Called once after credentials are saved. `nil` if none can be determined.
    func fetchLabel(credentials: Credentials) async -> String?
}
```

Platforms are grouped by integration difficulty for the onboarding UI:
- **Easy (API key):** Buttondown, GoatCounter, Calendly, Buffer
- **Medium (OAuth / token):** Mastodon, Jetpack, Bluesky, Google Search Console
- **Hard (file export):** LinkedIn, O'Reilly, Substack
- **No auth:** Hacker News

`Platform.authType` is the source of truth — update it and this list together.

## App Store considerations

- All file access via `NSOpenPanel` or drag-and-drop. **Security-scoped bookmarks
  are not implemented yet** — imports read the file once during the drop. Needed
  before any feature re-reads a file across launches.
- The outgoing-network entitlement is all-or-nothing on macOS. There is no
  per-domain declaration to add, so "only call declared domains" cannot be
  enforced by entitlements — it is a code review question. (This line used to
  say otherwise.)
- Credentials stored in Keychain only — never in UserDefaults or on disk unencrypted.
- Background refresh via NSBackgroundActivityScheduler (no Info.plist key needed).
- Sandbox entitlements: outgoing network connections, read/write to user-selected files.

## Prompt size and cost

- The prompt assembly logic (Prompt/) should mirror the trimming behaviour of the
  original analyse.py — counts and summaries, not full lists.
- Measure generated prompt size after significant changes.

## Code quality

- Don't add features, refactors or abstractions beyond what was asked. If you
  spot something worth doing, file an issue rather than widening the diff.
- Don't add error handling for scenarios that cannot happen. It reads as though
  the case is reachable and sends the next person hunting for it.
- **Keep this file true.** When a process changes, update `CLAUDE.md` in the same
  PR. Every factual claim in here is load-bearing: a future agent acts on it
  without re-verifying, so a wrong line causes wrong work later. Two rounds of
  review on #44 and #52 each found false statements in these docs.

## PR description

Include in every PR:
- What changed and why
- Whether tests pass, and the count — "218 tests in 32 suites pass" beats
  "tests pass", which is what a broken build also says
- Any validation done (tested against a live API, with mock data, on real
  exported files)
- Anything you could **not** verify, and why

**A squash merge composes its commit body from *every* commit on the branch**,
so a `Closes #N` in a commit you later reverted still fires. #91 was closed this
way and had to be reopened: the first commit on a branch said `Closes #91`, the
second withdrew that change and dropped the line, and the squash carried the
stale one anyway.
Before merging, check `git log origin/main..HEAD --format=%B | grep Closes`
against the issues you actually mean to close.
