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

## 5. Issue restructuring — done

Labels created: `P0` `P1` `P2`, `area:build` `area:ci` `area:design`
`area:collectors` `area:docs`, and `blocked`. All 11 existing issues relabelled.

Milestones created and populated:

**M1 — Runnable again** *(clone, build, test, ship a change with confidence)*
- #47 P1 — Wire up SocialBrainMCP as a real target, or remove it
- #48 P1 — Tests for the Google Search Console, Hacker News and Buffer collectors
- #49 P1 — Tests for LinkedInXLSXParser and MiniZIPReader
- #43 P2 — Retire the Vercel collector
- #51 P2 — Decide the CI vs local Xcode version policy

**M2 — Design pass** *(the five screens, rebuilt from the brief)*
- #38–#42 P1 — Design pass: Feed, Run, Platforms, Dashboard, Onboarding
- #46 P2 — Rewrite the Platforms grid UI tests
- #50 P2 — Tests for the Mastodon and WordPress OAuth flows
- #32 P2 — Manual testing checklist *(rewrite after the redesign, not before)*

**M3 — Ship**
- #28 P1 — Host the platform setup guide on the web
- #36 P1 — Development Team and data-protection keychain

**No milestone**
- #17 P2 `blocked` — LinkedIn Partners Program *(genuinely waiting on a third party)*
- #35 P2 — social-media-as-[name] skill docs *(unrelated to the app; consider
  moving to another repo)*

Several issues from the original proposal were never filed because PR #44
resolved them directly: the project-file conflict, the PR #34 decision, the CI
rewrite, the Release build job, and repo hygiene.

Also applied: repo description set, and `delete_branch_on_merge` enabled so
merged branches stop accumulating.

### Suggested order

1. **#47** — decide the MCP question. It's the last piece of the repo that
   claims to be buildable and isn't.
2. **#48, #49** — backfill collector and parser tests, restoring the guarantee
   CLAUDE.md already states. #49 first: `MiniZIPReader` parses untrusted binary
   input with no tests at all.
3. **#43, #51** — clear dead weight and settle the toolchain question.
4. *Then* M2. The design pass is the interesting work, and it lands on a repo
   that can actually verify itself.

## 6. Deliberately not done

Two items from the original plan need a decision rather than an action:

- **Pruning the 15 merged branches.** `delete_branch_on_merge` is now on, so
  this stops getting worse, but deleting the existing ones is irreversible.
  Worth keeping `platforms-inspector-run-labels` regardless — it holds the
  inspector-drawer UI work from the closed PR #34, which is useful reference
  during #40.
- **Enabling GitHub Pages for `docs/`** (issue #28). This repo is private;
  Pages would publish `docs/index.html` to the public web. That's the intent
  of #28, but it's an exposure decision, not a settings tidy-up — so it should
  be made explicitly rather than folded into a cleanup.
