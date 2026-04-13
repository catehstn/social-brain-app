# Test Plan — Issue #29: Multiple Platform Instances

## Overview

The implementation plan introduces a layered set of changes across models, database,
keychain, collectors, and UI. The test plan is organised by risk and dependency layer,
with the highest-risk pieces (database migration, collector dispatch, keychain isolation)
tested first. Each test suite is independent, runs in-process, and uses in-memory
databases or injected fakes — no network, no real Keychain, no live app.

The existing 40+ tests must remain green throughout; every task below ends with a
full `xcodebuild test -scheme SocialBrain -destination 'platform=macOS' -only-testing:SocialBrainTests` run.

---

## Suite 1 — `PlatformInstanceTests.swift` (new)

**File:** `SocialBrainTests/PlatformInstanceTests.swift`
**Covers:** Task 1 (`PlatformInstance` model)

All tests are synchronous (no async/await needed).

| # | Test name | Assertion |
|---|-----------|-----------|
| 1.1 | `idFormat` | `PlatformInstance(platform: .buttondown, instanceName: "newsletter-1").id == "buttondown:newsletter-1"` |
| 1.2 | `displayNameDefault` | Default instance (`instanceName == "default"`) uses `platform.displayName` only — `"Mastodon"` |
| 1.3 | `displayNameNonDefault` | Non-default shows `"GoatCounter — my-blog"` |
| 1.4 | `hashableEquality` | Two `PlatformInstance` values with same platform+name are `==` and share `hashValue` |
| 1.5 | `hashableInequality` | Same platform, different name → not equal |
| 1.6 | `codableRoundTrip` | Encode then decode a `PlatformInstance` via `JSONEncoder/Decoder`; all fields preserved |
| 1.7 | `defaultInstanceName` | `PlatformInstance(platform: .bluesky)` has `instanceName == "default"` (tests default parameter) |

---

## Suite 2 — `InstanceRegistryTests.swift` (new)

**File:** `SocialBrainTests/InstanceRegistryTests.swift`
**Covers:** Task 2 (`InstanceRegistry`)
**Setup:** Inject a test-specific `UserDefaults(suiteName:)` via `InstanceRegistry.defaults`; call `InstanceRegistry.resetAll()` in `init()`.

| # | Test name | Assertion |
|---|-----------|-----------|
| 2.1 | `autoSeedsDefault` | Fresh call to `instances(for: .buttondown)` returns `["default"]` |
| 2.2 | `addInstance` | After `add(instanceName: "newsletter-2", to: .buttondown)`, list is `["default", "newsletter-2"]` |
| 2.3 | `addDuplicateIsIdempotent` | Adding the same name twice does not produce a duplicate entry |
| 2.4 | `removeInstance` | After add+remove, removed name is absent; list has 1 entry |
| 2.5 | `cannotRemoveLastInstance` | Removing the only instance ("default") leaves the list unchanged — still `["default"]` |
| 2.6 | `allInstances` | After adding a second buttondown instance, `allInstances()` contains exactly 2 entries with `platform == .buttondown` and one entry per default for every other platform |
| 2.7 | `roundTrip` | Add "persisted" to `.vercel`; re-read via `instances(for: .vercel)` returns it — UserDefaults persistence works |
| 2.8 | `resetAll` | After `resetAll()`, every platform returns `["default"]` on next access (auto-seed) |

---

## Suite 3 — `MultiInstanceKeychainTests.swift` (new)

**File:** `SocialBrainTests/MultiInstanceKeychainTests.swift`
**Covers:** Task 3 (`KeychainStore` instance-keyed overloads)
**Setup:** `init()` deletes Keychain items for all test instances via `try? KeychainStore.delete(for:)` before each test.

| # | Test name | Assertion |
|---|-----------|-----------|
| 3.1 | `twoInstancesSameplatformStoredIndependently` | Save `"key-a"` for `buttondown:newsletter-a`, `"key-b"` for `buttondown:newsletter-b`; load each separately — values do not cross-contaminate |
| 3.2 | `hasCredentialsFalseBeforeSave` | `hasCredentials(for: PlatformInstance(platform: .mastodon, instanceName: "test"))` returns `false` before any save |
| 3.3 | `hasCredentialsTrueAfterSave` | Returns `true` after saving |
| 3.4 | `platformOnlyAPIDelegatesToDefault` | `save(credentials, for: .mastodon)` stores under account `"mastodon:default"`; `load(for: PlatformInstance(platform: .mastodon))` retrieves it |
| 3.5 | `deleteOneInstanceLeavesOtherIntact` | Delete `buttondown:newsletter-a`; `buttondown:newsletter-b` still has credentials |
| 3.6 | `loadReturnsNilAfterDelete` | After `delete(for:)`, `load(for:)` returns nil |
| 3.7 | `accountKeyFormat` | Verify (indirectly via save+load round-trip) that the account string is `"platform_raw:instanceName"` — saving with `PlatformInstance.id` as key and loading with the same key succeeds |

---

## Suite 4 — `MultiInstanceDatabaseTests.swift` (new)

**File:** `SocialBrainTests/MultiInstanceDatabaseTests.swift`
**Covers:** Tasks 5–7 (`PlatformSnapshot.instanceName`, v2 migration, updated queries)
**Setup:** Each test creates a fresh `AppDatabase.makeInMemory()`.

| # | Test name | Assertion |
|---|-----------|-----------|
| 4.1 | `v2MigrationAddsInstanceNameColumn` | `PRAGMA table_info(platformSnapshot)` includes a column named `"instanceName"` |
| 4.2 | `defaultInstanceNameOnOldRows` | Rows inserted without explicit `instanceName` (simulated by inserting raw SQL without the column) have `instanceName == "default"` after migration (column has `DEFAULT 'default'`) |
| 4.3 | `latestSnapshotScopedToInstanceName` | Two snapshots for same platform but different instanceNames; `latestSnapshot(for: .buttondown, instanceName: "newsletter-a")` returns only the "newsletter-a" snapshot |
| 4.4 | `latestSnapshotDefaultInstance` | No-argument form `latestSnapshot(for: .buttondown)` (which defaults `instanceName: "default"`) still works |
| 4.5 | `snapshotsForInstanceNameScoped` | `snapshots(for:instanceName:from:to:)` returns only rows matching both platform and instanceName within date range |
| 4.6 | `twoLatestSnapshotsScopedToInstance` | Two instances each with 3 snapshots; `twoLatestSnapshots(for: .mastodon, instanceName: "personal")` returns exactly 2 entries all from "personal" |
| 4.7 | `latestSnapshotsReturnsPlatformInstanceKeys` | Two mastodon instances "personal"+"work"; `latestSnapshots()` returns a `[PlatformInstance: PlatformSnapshot]` with both as distinct keys |
| 4.8 | `latestSnapshotsTwoInstancesDistinctMetrics` | Two buttondown instances each with different subscriber counts; dictionary entries hold the correct metric values |
| 4.9 | `previousSnapshotsReturnsPlatformInstanceKeys` | Two snapshots per instance for two instances; `previousSnapshots()` returns `[PlatformInstance: PlatformSnapshot]` with the second-most-recent row per instance |
| 4.10 | `deleteSnapshotsRemovesOnlyTargetInstance` | Delete snapshots for `goatCounter:site-a`; `goatCounter:site-b` snapshots remain in `latestSnapshots()` |
| 4.11 | `deleteSnapshotsIsNoOpForUnknownInstance` | Calling `deleteSnapshots(for:)` for a non-existent instance does not throw |
| 4.12 | `indexRecreatedWithThreeColumns` | After v2 migration the index `index_platformSnapshot_on_platform_instanceName_collectedAt` exists (query `sqlite_master WHERE type='index'`) |

---

## Suite 5 — `MultiInstanceCollectorRegistryTests.swift` (new)

**File:** `SocialBrainTests/MultiInstanceCollectorRegistryTests.swift`
**Covers:** Tasks 8–9 (`Collector.instanceName`, `CollectorRegistry`, `CollectionEngine` updates)

| # | Test name | Assertion |
|---|-----------|-----------|
| 5.1 | `configuredReturnsTwoCollectorsForTwoButtondownInstances` | Inject `mockInstances` returning `["nl-a", "nl-b"]` for `.buttondown` and `mockHasCredentials` returning true for those two; result has exactly 2 collectors with `platform == .buttondown` and `instanceNames == {"nl-a", "nl-b"}` |
| 5.2 | `configuredExcludesUncredentialedInstances` | All `mockHasCredentials` return false → empty collector list |
| 5.3 | `fileExportPlatformsNeverInApiCollectorList` | Even when all platforms are credentialed, amazon/linkedin/oreilly/substack do not appear in `configured()` result |
| 5.4 | `collectorForInstanceCarriesInstanceName` | `CollectorRegistry.collector(for: PlatformInstance(platform: .buttondown, instanceName: "nl-x"))` returns a collector with `instanceName == "nl-x"` |
| 5.5 | `collectionEngineUsesInstanceKeyedCredentials` | Run engine with two StubCollectors having different instanceNames; `credentials` closure receives a `PlatformInstance` (not just `Platform`); each call carries the correct `instanceName` — verified by inspecting captured closure arguments |
| 5.6 | `collectionResultFailureCarriesInstanceName` | A failing collector produces a `CollectionResult.failure` that exposes both `platform` and `instanceName` via the `.instance` computed property |
| 5.7 | `collectionResultInstanceComputedProperty` | `.success(PlatformData(platform: .mastodon, instanceName: "work", ...)).instance` returns `PlatformInstance(platform: .mastodon, instanceName: "work")` |
| 5.8 | `platformDataPassedThroughWithInstanceName` | Collector with `instanceName = "site-b"` returns `PlatformData.instanceName == "site-b"` in the summary results |
| 5.9 | `snapshotSavedWithInstanceNameFromCollector` | After engine run with a two-instance buttondown collector, the saved snapshot rows in the DB each have the correct `instanceName` |

---

## Suite 6 — Updates to existing `DatabaseMigrationTests.swift`

**File:** `SocialBrainTests/DatabaseMigrationTests.swift` (modify existing)

Existing tests must continue to pass without modification (they use `PlatformData` without `instanceName`, which defaults to `"default"`). Add the following regression tests:

| # | Test name | Assertion |
|---|-----------|-----------|
| 6.1 | `existingTestsPassUnchanged` | All 7 existing database tests pass — this is a "no regression" checkpoint verified by running the suite |
| 6.2 | `snapshotInitFromPlatformDataDefaultsInstanceName` | `PlatformSnapshot(runID:data:)` with old-style `PlatformData(platform: .mastodon, metrics: [...])` (no instanceName arg) produces a snapshot with `instanceName == "default"` |
| 6.3 | `latestSnapshotDefaultOverloadUnchanged` | `latestSnapshot(for: .bluesky)` (1-arg form, no instanceName) still returns the most recent snapshot — existing callers with no instanceName argument still compile and work |

---

## Suite 7 — Updates to existing `CollectionEngineTests.swift`

**File:** `SocialBrainTests/CollectionEngineTests.swift` (modify existing)

Existing 5 tests must compile and pass. The `StubCollector` gains `var instanceName: String = "default"` (required by updated protocol). No logic changes to existing assertions; the credentials closure type changes from `(Platform)` to `(PlatformInstance)`. Update helper:

```swift
private func makeCredentials() -> @Sendable (PlatformInstance) throws -> Credentials? {
    return { _ in Credentials(["api_key": "test"]) }
}
```

Add one new test:

| # | Test name | Assertion |
|---|-----------|-----------|
| 7.1 | `multiInstanceCollectorsRunAndSave` | Two StubCollectors, both `.mastodon` but `instanceName = "personal"` and `instanceName = "work"`; after engine run, two snapshots are saved each with correct instanceName |

---

## Suite 8 — PromptAssembler multi-instance test

**File:** `SocialBrainTests/PromptAssemblerTests.swift` (modify existing)

The existing tests pass `[PlatformData]` via `PromptAssembler.Input`. After the change, `Input.snapshots` becomes `[PlatformInstance: PlatformSnapshot]`. The existing tests must be updated to use the new type, but the output assertions remain unchanged (single-instance behaviour is unchanged). Add:

| # | Test name | Assertion |
|---|-----------|-----------|
| 8.1 | `singleInstanceUsesplatformDisplayName` | When `snapshots` has one entry for `PlatformInstance(platform: .mastodon)`, the section header is `"## Mastodon"` |
| 8.2 | `twoInstancesSamePlatformUsesInstanceDisplayName` | When `snapshots` has two entries for mastodon ("personal" and "work"), section headers are `"## Mastodon — personal"` and `"## Mastodon — work"` |
| 8.3 | `existingPromptFormatUnchangedForDefaultInstance` | Assemble a prompt with all platforms as default instances; the output contains the same platform headers as before (regression check) |

---

## Suite 9 — FeedCardBuilder / HighReachDetector / SpikeDetector updates

**Files:** `SocialBrainTests/FeedCardBuilderTests.swift`, `SocialBrainTests/HighReachDetectorTests.swift`, `SocialBrainTests/SpikeDetectorTests.swift` (modify existing)

After the change, `FeedCardBuilder.build(snapshots:previousSnapshots:now:)` takes `[PlatformInstance: PlatformSnapshot]`. Update all call sites in tests (most can continue to use `PlatformInstance(platform: .xxx)` as the default-instance key).

| # | Test name | Assertion |
|---|-----------|-----------|
| 9.1 | `existingFeedCardBuilderTestsPassWithDefaultKeys` | All existing FeedCardBuilderTests compile and pass after updating dictionary keys to `PlatformInstance` type |
| 9.2 | `spikeAlertForNonDefaultInstance` | `FeedCardBuilder.build` with a non-default instance (`mastodon:work`) still generates a spike alert card; `card.instanceName == "work"` |
| 9.3 | `staleReminderForNonDefaultInstance` | File-export platform with a non-default instanceName generates a stale-reminder card with the correct `instanceName` |
| 9.4 | `feedCardHasInstanceName` | `FeedCard` has `instanceName: String`; default-instance cards have `instanceName == "default"` |
| 9.5 | `highReachDetectorAcceptsInstanceKeys` | `HighReachDetector.detect(snapshots:previousSnapshots:)` with `[PlatformInstance: PlatformSnapshot]` input produces same results as before for default instances |

---

## Suite 10 — FeedViewModel / DashboardViewModel (compile-only + smoke tests)

**Files:** `SocialBrainTests/FeedViewModelTests.swift`, `SocialBrainTests/FeedDatabaseTests.swift` (modify existing)

After changes, `database.latestSnapshots()` and `database.previousSnapshots()` return `[PlatformInstance: PlatformSnapshot]`. `FeedViewModel.load()` passes these to `FeedCardBuilder`. All existing tests must continue to pass.

| # | Test name | Assertion |
|---|-----------|-----------|
| 10.1 | `feedViewModelLoadsDefaultInstances` | FeedViewModel.load() with a DB containing only default-instance snapshots produces non-empty card list — same behaviour as before |
| 10.2 | `feedViewModelLoadsMultipleInstancesForSamePlatform` | Two mastodon instances in DB; both produce feed cards |
| 10.3 | `dashboardViewModelUsesInstanceName` | `DashboardViewModel.load()` calls `database.snapshots(for:instanceName:from:to:)` — verified by checking `series` is non-empty when DB has the matching (platform, instanceName) data |

---

## Pre-flight and regression gate

Before and after all implementation work, run:

```bash
xcodebuild test \
  -scheme SocialBrain \
  -destination 'platform=macOS' \
  -only-testing:SocialBrainTests \
  2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`

The full test count after all suites are added should be ≥ 100 tests (40 pre-existing + ~60 new).

---

## Mapping to implementation plan tasks

| Implementation task | Test suite(s) |
|--------------------|---------------|
| Task 1 — PlatformInstance model | Suite 1 |
| Task 2 — InstanceRegistry | Suite 2 |
| Task 3 — KeychainStore overloads | Suite 3 |
| Task 4 — PlatformData.instanceName | Covered by Suites 4, 5, 6 (init default) |
| Task 5 — PlatformSnapshot.instanceName | Suite 4 (tests 4.1–4.2) |
| Task 6 — v2 migration | Suite 4 (tests 4.1, 4.2, 4.12) |
| Task 7 — AppDatabase query updates | Suite 4 (tests 4.3–4.11) |
| Task 8 — Collector protocol + all collectors | Suite 5 (5.4, 5.8) + Suite 7 |
| Task 9 — CollectorRegistry + CollectionEngine | Suite 5 |
| Task 10 — RunViewModel | Suite 5 (5.9) + end-to-end build |
| Task 11 — PromptAssembler | Suite 8 |
| Task 12 — Feed/Spike/HighReach models | Suite 9 |
| Task 13 — Dashboard | Suite 10 |
| Task 14 — PlatformsViewModel | Suite 3 (via KeychainStore), compile |
| Task 15 — PlatformsView + CredentialSheet | Build (no unit tests; UI-layer only) |
| Task 16 — xcodegen + final build | All suites green |
| Task 17 — Write new tests | Suites 1–5 as written above |
