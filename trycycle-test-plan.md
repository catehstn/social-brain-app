# Feed View Bug Fixes — Test Plan

> Covers issues #20 (FeedCardType displayName), #21 (@Observable migration),
> and #22 (show stale reminders instead of empty state).

---

## Compilation Gate

Run before and after every batch of changes, and as the final pre-PR check:

```
xcodebuild build-for-testing \
    -scheme SocialBrain \
    -destination 'platform=macOS'
```

Must produce zero errors and zero warnings that would block a build. Run
`xcodegen generate` from the worktree root after adding new `.swift` files.

---

## Baseline Gate

Before touching any code, confirm the full existing unit test suite is green:

```bash
xcodebuild test -scheme SocialBrain \
    -destination 'platform=macOS' \
    -only-testing:SocialBrainTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`

**All 3 tasks must start from a green baseline.** Do not proceed if any test is
failing before changes begin.

---

## Task 1: `FeedCardType.displayName` (Issue #20)

### Red test (must be written first)

**File:** `SocialBrainTests/FeedCardBuilderTests.swift`
**Suite:** `FeedCardBuilder`

Add inside the existing `FeedCardBuilderTests` struct:

```swift
@Test("FeedCardType displayName returns human-readable strings")
func feedCardTypeDisplayName() {
    #expect(FeedCardType.recentPost.displayName    == "Recent Post")
    #expect(FeedCardType.metricHighlight.displayName == "Metric Highlight")
    #expect(FeedCardType.upcomingEvent.displayName  == "Upcoming Event")
    #expect(FeedCardType.staleReminder.displayName  == "Stale Reminder")
}
```

**Verify it fails before implementation:**

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
    -only-testing:SocialBrainTests/FeedCardBuilderTests 2>&1 \
    | grep -E "error:|feedCardTypeDisplayName"
```

Expected: compile error — `value of type 'FeedCardType' has no member 'displayName'`

### Green check

After adding `displayName` to `FeedCardType` and updating `FeedCardView` to use it:

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
    -only-testing:SocialBrainTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`

### What is NOT tested here

`FeedCardView` renders `Text(vm.card.cardType.displayName)` — confirming the
displayed string is human-readable is a UI concern only. The unit test above is
sufficient to assert the correct string values; no UI test is added for this change.

---

## Task 2: `@Observable` migration (Issue #21)

### No new tests required

This is a pure refactor: `ObservableObject`/`@Published`/`@StateObject` →
`@Observable`/`@State`. The existing tests in `FeedViewModelTests.swift` and
`FeedCardViewModelTests.swift` access `vm.cards`, `vm.isLoading`, `vm.error`,
`vm.isTruncated`, `vm.displaySnippet`, and `vm.card` — all of which work
identically with `@Observable`. No test file changes are required.

### Regression check

After migrating both ViewModels and their call sites in the View files:

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
    -only-testing:SocialBrainTests/FeedViewModelTests \
    -only-testing:SocialBrainTests/FeedCardViewModelTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`

### Full suite check

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
    -only-testing:SocialBrainTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` with equal-or-higher test count vs baseline.

### Specific invariants to verify

These are implicit in the existing tests but call them out explicitly:

| Invariant | Verified by |
|---|---|
| `vm.cards` is mutable (Binding write-back works) | `toggleExpandFlipsIsExpandedAndWritesBackToBinding` |
| `objectWillChange.send()` in `FeedCardViewModel.toggleExpand()` is removed | Compile success (no `objectWillChange` on `@Observable` class) |
| `@StateObject` replaced with `@State` at call sites | Compile success |

---

## Task 3: Show stale reminders instead of empty state (Issue #22)

### Documenting test (already passing — contract assertion)

**File:** `SocialBrainTests/FeedViewModelTests.swift`
**Suite:** `FeedViewModel`

Add inside the existing `FeedViewModelTests` struct:

```swift
@Test("empty database cards array is non-empty — stale reminders are present")
func emptyDatabaseHasNonEmptyCards() async throws {
    let db = try makeDB()
    let vm = FeedViewModel(database: db)
    await vm.load()
    // FeedView must NOT show "Nothing yet" — stale reminders are actionable
    #expect(!vm.cards.isEmpty)
}
```

This test passes immediately against the current `FeedViewModel` (the ViewModel
already populates stale reminders). It documents the contract the view is
supposed to honour but currently violates.

**Run the test before fixing the view:**

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
    -only-testing:SocialBrainTests/FeedViewModelTests/emptyDatabaseHasNonEmptyCards \
    2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` — this test is a ViewModel contract test, not
a view-layer test. The bug is in `FeedView`, not `FeedViewModel`.

### Relationship to the existing `emptyDatabaseProducesStaleReminders` test

The existing test asserts `vm.cards.filter { $0.cardType == .staleReminder }.count == 4`.
The new test asserts `!vm.cards.isEmpty`. They are complementary:

- `emptyDatabaseProducesStaleReminders` — verifies the ViewModel produces exactly
  4 stale reminder cards for an empty database.
- `emptyDatabaseHasNonEmptyCards` — documents the contract that drives the view-
  layer fix: because cards is non-empty, `FeedView` must not show `"Nothing yet"`.

Neither test is modified or deleted.

### Green check after view fix

After changing `FeedView`'s empty-state condition from:

```swift
} else if vm.cards.filter({ $0.cardType != .staleReminder }).isEmpty {
```

to:

```swift
} else if vm.cards.isEmpty {
```

Run the full suite:

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
    -only-testing:SocialBrainTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` with equal-or-higher test count vs baseline +
Task 1's new test.

---

## Final Gate

After all three tasks are committed, run the full unit test suite one last time:

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
    -only-testing:SocialBrainTests 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` with a count ≥ (baseline + 2) — the two new tests
added in Tasks 1 and 3.

---

## Summary Table

| Task | File | Test function | Red→Green | Key assertion |
|---|---|---|---|---|
| #20 displayName | `FeedCardBuilderTests.swift` | `feedCardTypeDisplayName` | Yes | All 4 `displayName` values match human-readable strings |
| #21 @Observable | — | (no new test) | No (regression only) | All existing `FeedViewModelTests` + `FeedCardViewModelTests` still pass |
| #22 empty state | `FeedViewModelTests.swift` | `emptyDatabaseHasNonEmptyCards` | Passes before fix (ViewModel contract); view-layer fix must not break it | `!vm.cards.isEmpty` for empty DB |

### Existing tests that must remain green throughout

| File | Suite | Test |
|---|---|---|
| `FeedViewModelTests.swift` | `FeedViewModel` | `loadsCards` |
| `FeedViewModelTests.swift` | `FeedViewModel` | `emptyDatabaseProducesStaleReminders` |
| `FeedViewModelTests.swift` | `FeedViewModel` | `staleReminderCard` |
| `FeedViewModelTests.swift` | `FeedViewModel` | `freshSnapshotNoStaleReminder` |
| `FeedViewModelTests.swift` | `FeedViewModel` | `navigationTarget` |
| `FeedCardViewModelTests.swift` | `FeedCardViewModel` | `displaySnippetExpanded` |
| `FeedCardViewModelTests.swift` | `FeedCardViewModel` | `displaySnippetCollapsed` |
| `FeedCardViewModelTests.swift` | `FeedCardViewModel` | `isTruncatedFalseForShortSnippet` |
| `FeedCardViewModelTests.swift` | `FeedCardViewModel` | `isTruncatedTrueForLongSnippet` |
| `FeedCardViewModelTests.swift` | `FeedCardViewModel` | `toggleExpandFlipsIsExpandedAndWritesBackToBinding` |
| `FeedCardBuilderTests.swift` | `FeedCardBuilder` | `truncateShortText` |
| `FeedCardBuilderTests.swift` | `FeedCardBuilder` | `truncateAtWordBoundary` |
| `FeedCardBuilderTests.swift` | `FeedCardBuilder` | `truncateHardCutFallbackWhenNoSpace` |
| `FeedCardBuilderTests.swift` | `FeedCardBuilder` | `buildEmptySnapshotsProducesFourStaleReminders` |
| `FeedCardBuilderTests.swift` | `FeedCardBuilder` | `buildIsNonThrowing` |
| `FeedCardBuilderTests.swift` | `FeedCardBuilder` | `buildStaleReminderForLinkedInBeyondThreshold` |
| `FeedCardBuilderTests.swift` | `FeedCardBuilder` | `buildNoStaleReminderForLinkedInWithinThreshold` |
| `FeedCardBuilderTests.swift` | `FeedCardBuilder` | `buildAmazonStaleAfter30Days` |
| `FeedCardBuilderTests.swift` | `FeedCardBuilder` | `buildNoStaleReminderForNonFileExportPlatform` |
| `SidebarTests.swift` | `Sidebar` | `feedCaseExistsInAllCases` |
| `SidebarTests.swift` | `Sidebar` | `feedPositionedBetweenRunAndDashboard` |

---

## What is explicitly out of scope

- **UI tests** — no UI tests are added or modified. The three issues are all
  testable at the unit layer:
  - #20: string values on `FeedCardType` — unit test.
  - #21: pure refactor — compilation + existing unit tests.
  - #22: ViewModel contract + FeedView condition — unit test for the contract;
    the view-layer change is a one-line fix whose correctness is implicit in
    the ViewModel contract.
- **`FeedDatabaseTests`** — schema and query tests from the original Feed build.
  These are not modified; they must remain green but are not the focus.
- **All non-Feed tests** — the full baseline (`DatabaseMigrationTests`,
  `CollectionEngineTests`, all collector tests, etc.) must remain green but are
  not addressed here.
