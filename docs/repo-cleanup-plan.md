# Repo cleanup plan — proposal

Written 2026-09-01.

**Status:** sections 1–4 are done, in PR #44 — the repo builds again and all three
CI jobs are green on both Xcode 16.4 (CI) and 26.6 (local). PR #34 was closed as
superseded, with its collector work salvaged into PR #45. The Platforms UI tests
are skipped pending #40, tracked in #46.

**Still to do:** the GitHub mutations in section 5 — labels, milestones, relabelling
the existing issues, and filing the new ones.

Getting the build honest turned up three bugs that no amount of reading would have
found, including one that breaks the Mastodon, Bluesky and Calendly collectors
against their live APIs. See PR #44 for the detail.

---

## 1. The restart decision

**Recommendation: rebuild the SwiftUI view structs only. Keep everything else.**

### Evidence

The codebase is cleanly layered, and the seam falls exactly where the design brief needs it to.

| Layer | LOC | Verdict |
|---|---|---|
| Collectors | 2,741 | **Keep.** 14 platforms, hard-won API quirks, mostly tested. |
| Views — SwiftUI structs | 1,827 | **Rebuild.** This is what the design pass replaces. |
| Models (detectors, feed cards) | 1,188 | **Keep.** Pure logic, well tested. |
| OAuth / Keychain / Prompt / App | 1,076 | **Keep.** |
| Views — ViewModels | 635 | **Keep, mostly.** Thin and reusable. |
| Database (GRDB + migrations) | 354 | **Keep.** Migrations are tested. |

Three specific things make the view layer genuinely swappable:

1. **No view imports GRDB.** Verified across every file in `Views/` and `App/` — zero hits. Persistence never leaked upward.
2. **Every screen is `View(database:)` + a `@Observable` ViewModel.** `ContentView.swift` is a plain `NavigationSplitView` switch over `SidebarItem`. Replacing a screen means replacing one struct.
3. **The logic already lives outside the views.** `FeedViewModel.load()` is 20 lines that call `database.latestSnapshots()` and hand off to `FeedCardBuilder.build(...)` — a pure, separately-tested function. The spike/high-reach detection the brief describes as the Feed's reason to exist is in `Models/`, not in a view.

### Why not the other two options

- **Pure re-skin** underestimates it. The brief rethinks *topology*, not just colour — the Feed becomes an editorial surface, Run gets a live progress model, Platforms is a grid with an inspector. Those are new view structs regardless.
- **Full ground-up restart** throws away the expensive part. The collectors encode real integration knowledge (LinkedIn XLSX parsing, a hand-rolled ZIP reader, two OAuth flows, Jetpack's API shape). Rewriting them buys nothing the design brief asked for.

### What this implies for scope

The five "Design pass" issues (#38–#42) are the real work, and they are view-struct-sized, not app-sized. `ViewModels` may need new outputs (e.g. Run's per-platform progress stream), but that's additive.

---

## 2. Blockers to fix before any design work

### P0 — Two sources of truth for the Xcode project ✅ RESOLVED

`project.yml` (XcodeGen) and a checked-in `SocialBrain.xcodeproj` both exist and **disagree**:

- `project.yml`: `xcodeVersion: "26.0"`, `swiftVersion: "6.3"`
- `.github/workflows/ci.yml`: `xcode-select -s /Applications/Xcode_16.3.app`
- XcodeGen is not installed locally.

`Info.plist` and `SocialBrain.entitlements` are **gitignored as generated artifacts** — so a fresh clone is missing files the checked-in `.xcodeproj` expects. CI passes only because... it doesn't exercise that path.

**Pick one.** Recommendation: **delete `project.yml`, keep the `.xcodeproj`**, un-gitignore `Info.plist` and the entitlements file, and add a shared scheme. Rationale: it's a single-developer app with three targets and no need for generated project files; XcodeGen adds a required tool install for zero benefit here. (If you'd rather keep XcodeGen, the inverse works — but then `.xcodeproj` must leave the repo, and CI must install XcodeGen.)

### P0 — PR #34 has been open since April

441 additions / 231 deletions across 7 files (inspector drawer, run labels, right-click hide, Calendly fix). PR #33 merged *after* it and touched overlapping ground. It needs a decision: rebase and merge, or close as superseded by the design pass. **I have not touched it.**

### P1 — `SocialBrainMCP` has never been built

`SocialBrainMCP/` (3 files) and `SocialBrainMCPTests/` (1 file) appear in **neither** `project.pbxproj` **nor** `project.yml`. `main.swift` documents building with `-scheme SocialBrainMCP`, a scheme that does not exist. `MCPServerTests.swift` has never run.

Either wire it up as a real target or move it out. Leaving unbuildable code that documents its own fake build command is the worst of both.

### P1 — Test gaps against the project's own rule

CLAUDE.md: *"Add tests for every collector."* Currently missing:

- `GoogleSearchConsoleCollector` (210 LOC) — none
- `BufferCollector` (206 LOC) — setup-URL test only
- `HackerNewsCollector` — none
- `LinkedInXLSXParser` (149 LOC) — none
- `MiniZIPReader` (168 LOC) — none
- `MastodonOAuth` / `WordPressOAuth` — none

These are the three most recent collectors plus the two hairiest parsers. The discipline lapsed right before work stopped.

---

## 3. CI — it was green, and the build was broken

**CI is set up and has run 5 times, all reported "success". At least the two most
recent runs did not build at all.**

Actual output from the last run on `main` (c52ddd7, 2026-08-31):

```
❌  error: Build input file cannot be found:
    '.../SocialBrain/SocialBrain.entitlements'
** TEST FAILED **
The following build commands failed:
	ProcessProductPackaging .../SocialBrain.entitlements
	Testing project SocialBrain with scheme SocialBrain
(2 failures)
```

The job still reported success. Cause: the step ran

```
xcodebuild test ... | xcpretty || xcodebuild test ...
```

`xcpretty` **is** preinstalled on the GitHub macOS runner, so it ran (the `❌`
prefix is xcpretty's own formatting) and exited 0. Without `set -o pipefail`,
a pipeline's exit code is the *last* command's — so the failing xcodebuild was
masked, the `||` fallback never fired, and the step passed. Exactly one
xcodebuild invocation appears in the log.

Not a cost problem — 5 runs total on a personal account is negligible. It's a
trust problem: the green checkmark meant nothing, and it hid the fact that
`main` has not compiled from a clean checkout since the entitlements file was
gitignored.

Other gaps, now fixed: no SPM caching, no shared scheme (CI relied on Xcode
auto-creating one), no release-configuration build, no concurrency cancellation,
and `CODE_SIGN_STYLE = Automatic` with an empty `DEVELOPMENT_TEAM` (which cannot
succeed on a runner with no Apple account).

## 4. Repo hygiene (low risk, I can do these immediately)

- `SocialBrain.xcodeproj/.../xcuserdata/UserInterfaceState.xcuserstate` is **tracked in git** despite `.gitignore` — needs `git rm --cached` (gitignore doesn't apply retroactively).
- `trycycle-plan.md` (23KB) sits at the repo root; it planned the platforms redesign already shipped in #31. Move to `docs/plans/` or delete.
- **15 merged branches** never deleted on origin. `delete_branch_on_merge` is **off** — turn it on.
- Repo has **no description and no homepage** set.
- `docs/index.html` exists (the platform setup guide, 174 lines) but **GitHub Pages is not enabled** — which is exactly what issue #28 asks for. It's one settings toggle away from being done.

---

## 5. Proposed issue restructuring

### Labels to add

Currently only GitHub's nine defaults are in use, with no priority signal at all.

**Priority:** `P0` (blocks other work) · `P1` (next) · `P2` (someday)
**Area:** `area:build` · `area:ci` · `area:design` · `area:collectors` · `area:docs`
**State:** `blocked`

### Milestones to add

- **M1 — Runnable again** — anyone can clone, build, test, and ship a change with confidence.
- **M2 — Design pass** — the five screens rebuilt from the brief's mockups.
- **M3 — Ship** — signing, distribution, the setup guide hosted.

### Existing issues

| # | Title | Proposed |
|---|---|---|
| #17 | LinkedIn API: Partners Program | `blocked`, `P2`, no milestone. Genuinely waiting on a third party. |
| #28 | Host platform setup guide on the web | `P1`, `area:docs`, **M3**. Nearly done — enable Pages on `docs/`. |
| #32 | Manual testing checklist | `P2`, `area:docs`, **M2**. Rewrite after the design pass, not before. |
| #35 | How to create a social-media-as-[name] skill | `P2`, `area:docs`. Unrelated to the app — consider moving to another repo. |
| #36 | Development Team + data-protection keychain | `P1`, `area:build`, **M3**. Needed to ship; not needed to develop. |
| #38–#42 | Design pass ×5 | `P1`, `area:design`, **M2**. Keep as-is; they're correctly scoped once #1 is settled. |
| #43 | Retire Vercel collector | `P2`, `area:collectors`, **M1**. Touches 10 files — small but not trivial. |

### New issues to file

| Proposed title | Labels | Milestone |
|---|---|---|
| Resolve project.yml vs checked-in .xcodeproj | `P0` `area:build` | M1 |
| Decide fate of PR #34 (rebase or close as superseded) | `P0` `area:build` | M1 |
| Wire up SocialBrainMCP as a real target, or remove it | `P1` `area:build` | M1 |
| Add tests for GoogleSearchConsole, HackerNews, Buffer collectors | `P1` `area:collectors` | M1 |
| Add tests for LinkedInXLSXParser and MiniZIPReader | `P1` `area:collectors` | M1 |
| Add tests for the Mastodon and WordPress OAuth flows | `P2` `area:collectors` | M2 |
| CI: drop the double test run, cache SPM, commit a shared scheme | `P1` `area:ci` | M1 |
| CI: add a Release-configuration build job | `P2` `area:ci` | M2 |
| Repo hygiene: untrack xcuserstate, prune merged branches, set description | `P2` `area:build` | M1 |

### Suggested order

1. Resolve the project-file conflict (#new) — everything else compiles through it.
2. Decide PR #34 — it rots further every week.
3. CI fixes — so the test additions actually gate anything.
4. Backfill collector tests — restores the CLAUDE.md guarantee before the UI churns.
5. MCP decision, Vercel retirement — clears dead weight.
6. *Then* the design pass (#38–#42).

---

## 6. What I'd do next, pending your go-ahead

**Already safe to do (local files only):** write the README, fix the CI workflow, untrack the xcuserstate file, relocate `trycycle-plan.md`.

**Needs your approval (mutates GitHub):** create labels and milestones, relabel the 11 existing issues, file the 9 new ones, enable `delete_branch_on_merge`, prune the 15 merged branches, enable Pages.

**Needs your decision, not just approval:** the project.yml-vs-.xcodeproj call, and PR #34.
