# social-brain-app audit — 2026-09-03

Read-only review of `main` @ 6348566. Baseline: 218 unit tests in 32 suites pass locally, zero compiler warnings, working tree clean, no tracked junk, all three CI jobs green on the last five `main` runs. Open issues #17–#63 were read first; anything already tracked is referenced by number rather than repeated.

Four focused reviews fed this list (collectors; database/models/OAuth/app; views/viewmodels; tests/CI/docs). Each item says whether it was **confirmed** by reading or running the code, or **suspected**. Items marked ★ were re-verified by hand.

Four per-area reports (collectors; core; views; tests/CI/docs) backed this
summary. They lived in a session scratch directory and were not preserved — this
file is the durable record. Every item below carries enough file/line detail to
re-derive the finding.

**Item numbers here are cited by the GitHub issues raised from this audit.**
Numbering is stable: don't renumber.

---

## P0 — destroys real data today

1. ★ **Unit tests write to the developer's real Keychain.** `MultiInstanceKeychainTests.platformAPIDelegate` deletes and overwrites `calendly:default` under the production service `com.catehuston.SocialBrain`. `PlatformVisibilityStoreTests.testAutoShowOnSave` overwrites `buttondown:default`, writes `InstanceRegistry.defaults` (normally `UserDefaults.standard`), and fires a live HTTPS call to buttondown.com with `test-key`. Every `xcodebuild test` run does this. `KeychainStore.swift:9` has no test override. Confirmed.
2. **`eraseDatabaseOnSchemaChange = true` in every DEBUG build** (`AppDatabase.swift:56-58`). The debug build is the only user's production build, so any migration edit silently wipes all collected history. Confirmed.
3. **Background refresh never runs spike detection** (`SocialBrainApp.swift:53-73` vs `RunViewModel.swift:73`). The scheduled run — the one that fires when nobody is looking — is the only path that never produces notifications. It also opens a second `DatabasePool` on the same file and re-runs the migrator (hits item 2). Confirmed.

## P1 — collectors provably wrong against live APIs

4. ★ **Google Search Console double-encodes the site URL** (`GoogleSearchConsoleCollector.swift:145-147`). `addingPercentEncoding` then `appendingPathComponent` yields `sites/https%253A//example.com//…`; every request targets a nonexistent property. Confirmed by probe.
5. ★ **Buttondown NaN aborts the whole run** (`ButtondownCollector.swift:53-57` → `CollectionEngine.swift:120`). Guard checks `openRates` but divides by `clickRates.count`; an email with an open rate and no click rate gives 0/0 → NaN → `JSONEncoder` throws inside the persist loop → later snapshots unsaved and `completeRun` never called. Two bugs: the NaN, and persistence failures aborting the run instead of becoming `.failure`. Confirmed by probe.
6. **LinkedIn CSV CTR is off by 100× for CTR ≤ 1%** (`LinkedInImporter.swift:98-103`). Column is literally `CTR (%)`; heuristic `v > 1 ? v/100 : v` maps `0.72%` to 72%. Test only uses values > 1. Same shape in `SubstackImporter.swift:99-105`. Confirmed by probe.
7. **`MiniZIPReader` allocates from the untrusted size header** (`:119-122`) — up to 4 GiB on drop of a crafted `.xlsx`; also returns untrimmed buffers and accepts `Z_OK` after `Z_FINISH`, so truncated streams pass as complete. Confirmed. (#49 tests would catch the first.)
8. **`LinkedInXLSXParser` shared-string table skips rich-text runs** (`:80-86`, XPath `si/t` misses `si/r/t`), shifting every later index; header detection then silently falls back to column C. Distinct from #55. Also sheets addressed by hard-coded `sheet1.xml…sheet4.xml` rather than workbook rels. Confirmed.
9. **No pagination where `since` is applied client-side**: Mastodon (`:88`, doc says 200, fetches 40), Bluesky (`:96`, filters on `indexedAt`), Buffer (`:112`), Hacker News (`:63`, counts comments as mentions). Jetpack silently caps at 90 days (`:83`). All undercount. Confirmed.
10. **Amazon KDP importer** trims leading tabs, shifting every column when Title is empty (`:36-38`); royalties with thousands separators or non-`$` currency are dropped (`:89`); assumes TSV while current KDP downloads are XLSX. Confirmed / format suspected.
11. **Suspected API-shape mismatches** (fixtures mirror the code, not the API): Calendly decodes `event_type_name`/`invitees_email_hint`, which don't appear to be scheduled-event fields (`CalendlyCollector.swift:117-122`); Buttondown uses `__gte` filters and expects `email_stats` embedded in the list payload (`:78,98,140`); Jetpack `likes_today` is non-optional (`:119`); Buffer targets the legacy REST API that Buffer now lists under "migration". One live run each would settle these — which is what #60's network suite was for and it has never passed.
12. **Decode errors lose the key name** (`Collector.swift:84` flattens `DecodingError` to `localizedDescription`), so every item in 11 would surface only as "The data couldn't be read." Confirmed.

## P1 — app logic in the ViewModels (kept through the redesign)

13. **Every screen's state is destroyed on sidebar switch** (`ContentView.swift:25-41`). VMs live in per-branch `@State`; leave Run mid-collection and come back → "Ready to collect", prompt gone (never persisted), engine still running in an orphaned task, and a second run can start. Dashboard/Feed/Platforms selection resets likewise. Confirmed.
14. **`RunViewModel`** has no re-entrancy guard (`:36`), no cancellation, sets `.finished` before the prompt exists (`:73` vs `:112`), and `RunView.swift:161` keys results by `platform`, so two Mastodon instances produce duplicate IDs. Confirmed.
15. **DB errors are rendered as empty states**: Dashboard (`DashboardViewModel.swift:67`), History (`HistoryViewModel.swift:37-39`, deliberate comment), Feed (`FeedViewModel.swift:35` sets `error`, view never reads it). A corrupt DB shows "run a collection first". Confirmed.
16. **Dashboard can never chart GSC, Buffer or Hacker News** (`DashboardViewModel.swift:102-147`, `default: []`); default selection is Mastodon even if not configured → blank picker (`:21,59`); overlapping loads race (`DashboardView.swift:17-23`); any value < 1 renders as a percentage (`DashboardView.swift:141`, so `units_sold = 0` → "0.0%"). Confirmed.
17. **Feed → Dashboard tap-through is wired to nothing** (`ContentView.swift:8,29-36` writes a platform `DashboardView` never receives). Confirmed.
18. **Hidden platforms still nag**: `FeedCardBuilder.swift:51-72` emits stale-reminder cards for all four file-export platforms regardless of `PlatformVisibilityStore`; `RunViewModel.swift:91-101` puts hidden platforms in the prompt. Confirmed.
19. **"Best engagement" compares Buttondown open rate (~0.4) to engagement rates (~0.01)** (`FeedCardBuilder.swift:104-121,197-221`); Buttondown wins whenever it has data. Confirmed.
20. **Label edits silently dropped for 10 of 14 platforms** (`PlatformCredentialSheet.swift:55-64,325,417`): only `save()` persists the label; OAuth and file-import paths bypass it. Confirmed.
21. **Dropped-file failures are partly silent** (`PlatformsView.swift:84-85`, `PlatformsViewModel.swift:155-162`): no URL → no alert; parser errors flattened to generic "unrecognised" via `try?`. Related to #57 but a distinct cause. Confirmed.
22. **Settings shows named-instance-only platforms as unconfigured** (`SettingsView.swift:94` checks the default instance only). Onboarding platform list is a literal that omits Buffer and Hacker News (`OnboardingView.swift:124`). Confirmed.
23. **`FeedView.swift:29`** uses index-keyed `ForEach` with bindings; a refresh that shrinks `cards` can trap. Suspected.

## P2 — security and robustness

24. **OAuth has no `state` and no PKCE** (`MastodonOAuth.swift:64-69`, `WordPressOAuth.swift:44-49`); Mastodon registers a brand-new OAuth app on every sign-in and never persists the secret, so tokens can't be revoked (`:47-59`); `socialbrain://` isn't declared in `CFBundleURLTypes`. Confirmed.
25. **`XMLDocument(data:)` on untrusted `.xlsx` with default options** (`LinkedInXLSXParser.swift:52,59,68,82`); pass `.nodeLoadExternalEntitiesNever`. Suspected.
26. **Buffer sends the token as `?access_token=`** on every request (`BufferCollector.swift:143-152`); `httpError` echoes 200 bytes of response body into the Run screen. Confirmed.
27. **DB open failure is `fatalError`** (`SocialBrainApp.swift:8-15`); no index on `platformSnapshot.runID` while History does one query per run (N+1, `HistoryViewModel.swift:25-36`); `deleteRun`, `BackgroundRefreshScheduler.stop()`, `dashboardInitialPlatform` are dead. Confirmed.
28. **Stale-export reminders fire once and are never re-armed** (`NotificationManager.swift:42-74`); notification permission is requested on first launch before onboarding explains anything (`SocialBrainApp.swift:51`). Confirmed.
29. **`SpikeDetector` has no absolute floor** (`:59-66`): 0.5 → 0.7 average favourites is a "40% spike" and a system notification. Design choice, but it will fatigue. Confirmed.

## P2 — tests

30. **No test migrates a populated v1 database** — `CLAUDE.md:101` and `repo-cleanup-plan.md:34` say the rule is enforced; every DB test starts from a fresh in-memory migrator. Confirmed.
31. **`MockURLSession` matches path only and records nothing** (`:24-28`), so no collector test can assert the request URL, headers or `since` parameter. 5 of 7 collector suites have no `since` test despite `CLAUDE.md:100`. Item 4 is exactly what a request-URL assertion would have caught. Confirmed.
32. **`InstanceRegistry.defaults` has the same cross-suite race `PlatformVisibilityStore` was fixed for** (`InstanceRegistryTests.swift:5-14` reassigns a global while other suites read it). Beyond #58's general statement. Suspected intermittent.
33. **`FeedUITests.swift:32-47` cannot fail** (assertion inside `if count > 0`, CI DB is empty); `:7-11` depends on `SocialBrainUITests` having persisted onboarding state into the host's real defaults. Confirmed.
34. **Zero tests and not tracked anywhere**: `RunViewModel`, `HistoryViewModel`, `NotificationManager`, `BackgroundRefreshScheduler`, `AnalyticsGoal`, `InstanceLabels` (the last two write `UserDefaults.standard` directly). `SocialBrainTests.swift` is an empty placeholder. `FeedPlatformData` typed structs exist only for fixtures; production always takes the dictionary path, so those tests exercise code production never runs (`FeedCardBuilder.swift:159-221`). Confirmed.
35. `SetupURLTests.swift:33-45` hand-maintains the URL list instead of reading `PlatformCredentialSheet`'s literals. (#60.)

## P2 — CI

36. **Three jobs each build the app from scratch**: ~8.5 wall-minutes ≈ 85 billed macOS-minutes per run; four runs on 2026-09-02 ≈ 340 minutes, ~17% of the monthly allowance in one day. Unit and UI jobs compile the identical Debug app. `build-for-testing` once, `test-without-building` twice. Confirmed from run timings.
37. `*.xcresult` not gitignored though the README test command and CI both write `TestResults-*.xcresult` into the checkout root; `.claude/scratch/` not ignored; redundant "Resolve packages" steps. Nits.

## P2 — living docs contradicted by the code

38. **`docs/design-brief.md`**: says "14 platforms" and lists 13 (Vercel missing); puts Amazon KDP and GSC under "API key" (`Platform.swift:42-47` disagrees); cites `BGTaskScheduler` twice, once under "constraints already fixed in code"; references `MetricChartView` (doesn't exist) and root `trycycle-plan.md` (deleted); wrong sandbox data path. Promises with no code beyond #61: History detail/retry/snapshot JSON/view prompt (`:86`), per-platform retry (`:121`), Open-claude.ai button (`:63`), last-run summary on idle Run (`:62`), test-connection (`:99`), drop zone in the credential sheet (`:99`), all six Settings controls (`:108-114`), instance label on feed cards (`:68`). Confirmed. This is the doc M2 is about to be planned from.
39. **`CLAUDE.md`**: `:5` tells planning subagents to write root `trycycle-plan.md`, which the cleanup deleted; `:213` "declared domains" entitlement doesn't exist on macOS (network.client is all-or-nothing); `:155-161` "exactly one area" is violated by #46 and #60; `:100-101` migration and `since` test rules are stated as enforced but unmet (items 30, 31); `:37` "one file per platform" while the directory holds five non-platform files. Confirmed.
40. **`README.md:134` points at `docs/index.html`, a stale fork of the bundled `setup-guide.html`** (4 hunks differ; the app shows the bundled one via `SetupGuideSheet.swift:49`; nobody sees `docs/index.html` because Pages is off). `docs/index.html:170` says "open source" on a private repo. Keep one file. Confirmed.
41. **`docs/repo-cleanup-plan.md`**: lists six remaining branches, four exist; §2 and §4 still read as open; issue lists omit #62/#63. **`docs/plans/*`** describe work shipped in #31 with no status line, and one tells the reader to run `xcodegen` against the deleted `project.yml`. Confirmed.
42. **`SocialBrainMCP/`** (input to #47): would not compile — `PromptAssembler.Input` and `latestSnapshots()` changed shape in #29; `DatabaseProxy` duplicates pre-#29 queries and ignores `instanceName`; `main.swift:28` documents the wrong DB path for a sandboxed app; would need ~8 shared source files plus GRDB. Evidence leans "delete". Confirmed.

## P3 — consistency and duplication

43. **Copy-pasted helpers that claim to be shared**: `subscript(safe:)` private in five files (one says "reused across importer files"); `parseCSV` verbatim in LinkedIn and Substack importers; three private `iso8601Date` helpers each building a formatter per call; two `formEncode`; two platform-icon tables (`FeedCardView.swift:43-60` vs `Platform.sfSymbol`, with different symbols); goal label computed three times; period label computed twice with different boundaries; `isFileImportPlatform` duplicating `authType`.
44. **Metric-key divergence for #63**, concrete list: `followers_count` / `total_followers` / `followers_blog` / `subscriber_count`; `statuses_count` / `posts_count` / `posts_published` / `sent_updates`; `avg_reblogs` / `avg_reposts`; `total_pageviews` / `total_views` / `total_page_views` / `impressions` / `total_impressions`; top-N strings in three formats.
45. **Importers stamp `collectedAt = .now`** and ignore the export's own dates (LinkedIn rows, KDP `Royalty Date`, Substack `post_date`); a last-quarter export imported today becomes today's snapshot.
46. **Keychain used as a boolean flag** (`PlatformsViewModel.swift:189` stores `["imported": "true"]`), which `RunViewModel`, `SettingsView` and `CollectorRegistry.configured()` then depend on; `hasCredentials` also returns false on any ACL denial, turning a dismissed Keychain prompt into "not configured".
47. **`nonisolated(unsafe) static var defaults`** test hooks in `InstanceRegistry` and `PlatformVisibilityStore`, while `InstanceLabels` and `AnalyticsGoal` hit `UserDefaults.standard` directly; `InstanceRegistry.remove` will happily remove `"default"`, which several call sites assume exists.
48. **`since == nil` means five different things** (30 days, 28 days, first page, all time…) and GSC formats dates in local time while Buttondown/GoatCounter use UTC.
49. **`PlatformCredentialSheet.swift`** hard-codes per-platform field keys, help URLs, permission notes and required keys that the collectors are the real consumers of; a `Platform.credentialSpec` would let the redesign render forms generically and let `SetupURLTests` read the source of truth. GSC Client ID is marked `secure` (it isn't a secret). Buttondown help URL `buttondown.com/keys` suspected stale.
50. `print` for error reporting in three places; SQL trace prints every statement including `latest_post_text` in DEBUG; `NSUserNotificationAlertStyle` is a dead Info.plist key; no `LSApplicationCategoryType`; hard-coded `0.1.0` version.

---

## Suggested order

1. Item 1 (one-afternoon fix: injectable Keychain service, and stop `testAutoShowOnSave` calling the real `save`). Nothing else should run before this.
2. Items 2 and 3 (data safety in the daily build; background run gets the same post-run hook as manual).
3. Items 4, 5, 6 with request-URL-asserting tests (fixes item 31 on the way). These are the "fix the build" of the collectors.
4. Item 11 via one honest network run (#60) before investing further in any of those four collectors.
5. Items 13–15 before M2 starts, since the redesign will build on those VMs.
6. Item 38 before M2 planning; item 39/40 alongside.
7. #47 with item 42 as the evidence.
