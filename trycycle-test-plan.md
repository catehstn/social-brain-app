# Feed View — Test Plan

## Compilation Gate

Run this before and after every batch of changes, and as the final pre-PR check:

```
xcodebuild build-for-testing \
    -scheme SocialBrain \
    -destination 'platform=macOS'
```

Must produce zero errors. Run `xcodegen generate` from the worktree root before
invoking xcodebuild whenever new `.swift` files have been added (the project uses
directory-level source globs, so no manual `project.yml` edits are required).

---

## Clock Seam for Staleness Tests

`FeedViewModel` and `FeedCardBuilder.build(snapshots:now:)` both accept an injectable
clock as a `() -> Date` closure (defaulting to `Date.init`). Tests that exercise
staleness logic must pass a fixed `Date` so thresholds are deterministic:

```swift
// Example: "now" is pinned to a known instant
let fixedNow = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
let vm = FeedViewModel(database: db, now: { fixedNow })
```

For `FeedCardBuilder` tests, pass the same value directly:

```swift
let cards = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow)
```

**Staleness thresholds** (from `StalenessThreshold` in `FeedCardBuilder.swift`):

| Platform          | Threshold   |
|-------------------|-------------|
| `.linkedin`       | 3 days      |
| `.substack`       | 3 days      |
| `.amazon`         | 30 days     |
| `.oreilly`        | 30 days     |
| All others        | Never stale |

A snapshot is considered stale when `now.timeIntervalSince(snapshot.collectedAt) > threshold`.

---

## Test Files

### 1. `SocialBrainTests/FeedDatabaseTests.swift`

Framework: Swift Testing (`import Testing`)
Target: `SocialBrainTests`
Purpose: In-memory GRDB integration — schema migration, row insertion, `latestSnapshots()` query.

**Helper:**
```swift
private func makeDB() throws -> AppDatabase {
    try AppDatabase(DatabaseQueue())   // in-memory; discarded after each test
}
```

---

#### `func migrationCreatesTable() throws`

Seeds: nothing (just initialises the database).

Asserts:
- `conn.tableExists("snapshots")` is `true` — confirms the v1 migration ran.

---

#### `func latestSnapshotsReturnsNewest() throws`

Seeds:
- Two `PlatformSnapshot` rows for platform `"mastodon"` with distinct `collectedAt` dates:
  - `older = Date(timeIntervalSinceNow: -7200)`
  - `newer = Date()`
- Both rows carry identical JSON-encoded `MastodonData(latestPostText: "hello", followersCount: 100, engagementRate: 0.05)`.

Asserts:
- `result[.mastodon]?.collectedAt == newer` — only the most-recent row is returned.
- `result.count == 1` — only one platform key is present.

---

#### `func latestSnapshotsMissingPlatform() throws`

Seeds: nothing (empty database).

Asserts:
- `result[.mastodon] == nil` — querying an absent platform returns nil.

---

#### `func oneRowPerPlatformOrdered() throws`

Seeds:
- One `PlatformSnapshot` for each of `.mastodon`, `.bluesky`, `.buttondown`, using
  distinct `collectedAt` values (`now`, `now - 1h`, `now - 2h`) and minimal valid
  JSON payloads for each platform.

Asserts:
- `result.count == 3`
- `result[.mastodon] != nil`
- `result[.bluesky] != nil`
- `result[.buttondown] != nil`
- Each returned snapshot's `collectedAt` matches the most recent insertion for that platform.

---

#### `func contentFieldPresentAfterRoundTrip() throws`

Seeds:
- One `PlatformSnapshot` for `.bluesky` with a non-empty `data` blob
  (`JSONEncoder().encode(BlueskyData(latestPostText: "test", followersCount: 50, engagementRate: 0.07))`).

Asserts:
- The retrieved snapshot's `data` is non-empty.
- `JSONDecoder().decode(BlueskyData.self, from: data).latestPostText == "test"` — the
  content round-trips correctly through the database.

---

### 2. `SocialBrainTests/FeedViewModelTests.swift`

Framework: Swift Testing (`import Testing`)
Target: `SocialBrainTests`
Isolation: `@MainActor` on suite (all tests run on main actor; `FeedViewModel` is `@MainActor`).

**Helper:**
```swift
private func makeDB() throws -> AppDatabase {
    try AppDatabase(DatabaseQueue())
}
```

---

#### `func loadsCards() async throws`

Seeds:
- One `PlatformSnapshot` for `.mastodon` with
  `MastodonData(latestPostText: "Test post", followersCount: 200, engagementRate: 0.1)`,
  `collectedAt: Date()`.

Setup:
```swift
let vm = FeedViewModel(database: db)
await vm.load()
```

Asserts:
- `vm.cards.isEmpty == false`
- `vm.isLoading == false`
- `vm.error == nil`

---

#### `func emptyDatabaseProducesStaleReminders() async throws`

Seeds: nothing (empty database).

Setup:
```swift
let vm = FeedViewModel(database: db)
await vm.load()
```

Asserts:
- `vm.cards.filter { $0.cardType == .staleReminder }.count == 4`
  — platforms `.linkedin`, `.substack`, `.amazon`, `.oreilly` each produce one stale
  reminder because they have no snapshots at all.

---

#### `func staleReminderCard() async throws`

Seeds:
- One `PlatformSnapshot` for `.linkedin` with
  `LinkedInData(latestPostText: "old post", totalImpressions: 50)`,
  `collectedAt: fixedNow - (4 * 24 * 3600)` (4 days ago — beyond the 3-day threshold).

Setup:
```swift
let fixedNow = Date()
let vm = FeedViewModel(database: db, now: { fixedNow })
await vm.load()
```

Asserts:
- `vm.cards.first { $0.platform == .linkedin && $0.cardType == .staleReminder } != nil`

---

#### `func freshSnapshotNoStaleReminder() async throws`

Seeds:
- One `PlatformSnapshot` for `.linkedin` with
  `LinkedInData(latestPostText: "fresh", totalImpressions: 10)`,
  `collectedAt: fixedNow - (1 * 24 * 3600)` (1 day ago — within the 3-day threshold).

Setup:
```swift
let fixedNow = Date()
let vm = FeedViewModel(database: db, now: { fixedNow })
await vm.load()
```

Asserts:
- `vm.cards.filter { $0.platform == .linkedin && $0.cardType == .staleReminder }.isEmpty == true`

---

#### `func navigationTarget() async throws`

Seeds:
- One `PlatformSnapshot` for `.mastodon` with
  `MastodonData(latestPostText: "nav test", followersCount: 10, engagementRate: 0.02)`,
  `collectedAt: Date()`.

Setup:
```swift
let vm = FeedViewModel(database: db)
await vm.load()
```

Asserts:
- `vm.cards.first { $0.platform == .mastodon }?.navigationTarget == .mastodon`

---

### 3. `SocialBrainTests/FeedCardViewModelTests.swift`

Framework: Swift Testing (`import Testing`)
Target: `SocialBrainTests`
Isolation: `@MainActor` on suite.

**Binding helper** — wraps a `FeedCard` in a reference-type box so mutations via
the binding are observable in tests without a live SwiftUI environment:

```swift
final class Box {
    var card: FeedCard
    init(_ card: FeedCard) { self.card = card }
}

private func makeBinding(snippet: String, expanded: Bool = false) -> Binding<FeedCard> {
    let box = Box(FeedCard(
        platform: .mastodon,
        cardType: .recentPost,
        snippet: snippet,
        isExpanded: expanded,
        navigationTarget: .mastodon
    ))
    return Binding(get: { box.card }, set: { box.card = $0 })
}
```

---

#### `func displaySnippetExpanded()`

Setup:
```swift
let long = String(repeating: "a", count: 200)
let vm = FeedCardViewModel(card: makeBinding(snippet: long, expanded: true))
```

Asserts:
- `vm.displaySnippet == long` — full text returned when `isExpanded` is `true`.

---

#### `func displaySnippetCollapsed()`

Setup:
```swift
let long = String(repeating: "a ", count: 100)  // 200 chars with spaces
let vm = FeedCardViewModel(card: makeBinding(snippet: long))
```

Asserts:
- `vm.displaySnippet.count <= 105` — truncated to ≤ 100 chars + "…" (1 char).

---

#### `func isTruncatedFalseForShortSnippet()`

Setup:
```swift
let vm = FeedCardViewModel(card: makeBinding(snippet: "Short text."))
```

Asserts:
- `vm.isTruncated == false`

---

#### `func isTruncatedTrueForLongSnippet()`

Setup:
```swift
let long = String(repeating: "word ", count: 30)   // 150 chars — exceeds 100-char limit
let vm = FeedCardViewModel(card: makeBinding(snippet: long))
```

Asserts:
- `vm.isTruncated == true`

---

#### `func toggleExpandFlipsIsExpandedAndWritesBackToBinding()`

Setup:
```swift
let binding = makeBinding(snippet: "Test")
let vm = FeedCardViewModel(card: binding)
```

Asserts (in sequence — each assertion before the next call):
1. `binding.wrappedValue.isExpanded == false` — initial state.
2. Call `vm.toggleExpand()`.
3. `binding.wrappedValue.isExpanded == true` — write-back propagated to the binding source.
4. Call `vm.toggleExpand()`.
5. `binding.wrappedValue.isExpanded == false` — toggled back.

---

### 4. `SocialBrainTests/FeedCardBuilderTests.swift`

Framework: Swift Testing (`import Testing`)
Target: `SocialBrainTests`
Purpose: Pure-logic tests; no database or SwiftUI dependencies.

---

#### `func truncateShortText()`

Input: `text = "Hello world"`, `limit: 280`

Asserts:
- `FeedCardBuilder.truncate(text, limit: 280) == text` — unchanged when under limit.

---

#### `func truncateAtWordBoundary()`

Input: `text = String(repeating: "hello ", count: 10)` (60 chars), `limit: 25`

Asserts:
- `result.hasSuffix("…")` — ellipsis appended.
- `result.dropLast()` does not end with `" "` — no trailing space before ellipsis.
- `result.count <= 26` — at most 25 content chars + "…".

---

#### `func truncateHardCutFallbackWhenNoSpace()`

Input: `text = String(repeating: "a", count: 300)` (no spaces), `limit: 280`

Asserts:
- `result.hasSuffix("…")`
- `result.count == 281` — exactly 280 chars + "…".

---

#### `func buildEmptySnapshotsProducesFourStaleReminders()`

Input: `FeedCardBuilder.build(snapshots: [:], now: Date())`

Asserts:
- `cards.filter { $0.cardType == .staleReminder }.count == 4`
  — `.linkedin`, `.substack`, `.amazon`, `.oreilly` each produce one card when never collected.

---

#### `func buildIsNonThrowing()`

Asserts (compile-time gate — no runtime assertion needed):
```swift
let _: [FeedCard] = FeedCardBuilder.build(snapshots: [:])
```
If this line compiles without `try`, the function's non-throwing signature is confirmed.

---

#### `func buildStaleReminderForLinkedInBeyondThreshold()`

Seeds:
```swift
let fixedNow = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
let staleDate = fixedNow.addingTimeInterval(-(4 * 24 * 3600))  // 4 days before fixedNow
let payload = try JSONEncoder().encode(LinkedInData(latestPostText: "old", totalImpressions: 0))
let snapshots: [Platform: PlatformSnapshot] = [
    .linkedin: PlatformSnapshot(id: nil, platform: "linkedin", collectedAt: staleDate, data: payload)
]
```

Asserts:
- `FeedCardBuilder.build(snapshots: snapshots, now: fixedNow)` contains a card where
  `.platform == .linkedin && .cardType == .staleReminder`.

---

#### `func buildNoStaleReminderForLinkedInWithinThreshold()`

Seeds same as above but `collectedAt = fixedNow.addingTimeInterval(-(1 * 24 * 3600))` (1 day).

Asserts:
- The resulting cards contain no `.staleReminder` for `.linkedin`.

---

#### `func buildAmazonStaleAfter30Days()`

Seeds:
```swift
let staleDate = fixedNow.addingTimeInterval(-(31 * 24 * 3600))
let payload = try JSONEncoder().encode(AmazonData(latestTitle: "Book", totalRoyalties: 10))
let snapshots: [Platform: PlatformSnapshot] = [
    .amazon: PlatformSnapshot(id: nil, platform: "amazon", collectedAt: staleDate, data: payload)
]
```

Asserts:
- Card with `.platform == .amazon && .cardType == .staleReminder` is present.

---

#### `func buildNoStaleReminderForNonFileExportPlatform()`

Seeds:
```swift
// Mastodon snapshot that is 365 days old
let payload = try JSONEncoder().encode(MastodonData(latestPostText: "old", followersCount: 1, engagementRate: 0.01))
let oldDate = fixedNow.addingTimeInterval(-(365 * 24 * 3600))
let snapshots: [Platform: PlatformSnapshot] = [
    .mastodon: PlatformSnapshot(id: nil, platform: "mastodon", collectedAt: oldDate, data: payload)
]
```

Asserts:
- No card with `.platform == .mastodon && .cardType == .staleReminder`.

---

### 5. `SocialBrainTests/SidebarTests.swift`

Framework: Swift Testing (`import Testing`)
Target: `SocialBrainTests`

---

#### `func feedCaseExistsInAllCases()`

Asserts:
- `SidebarItem.allCases.contains(.feed) == true`

---

#### `func feedPositionedBetweenRunAndDashboard()`

Setup:
```swift
let cases = SidebarItem.allCases
let runIdx  = cases.firstIndex(of: .run)!
let feedIdx = cases.firstIndex(of: .feed)!
let dashIdx = cases.firstIndex(of: .dashboard)!
```

Asserts:
- `runIdx < feedIdx`
- `feedIdx < dashIdx`

---

### 6. `SocialBrainUITests/FeedUITests.swift`

Framework: XCTest (`import XCTest`)
Target: `SocialBrainUITests`
Setup (shared `setUpWithError`): `continueAfterFailure = false; app.launch()`

---

#### `func testFeedItemExistsInSidebar()`

Action: Waits up to 5 seconds for a static text cell labelled `"Feed"` in the
first outline (the sidebar list).

Asserts:
- `feedItem.waitForExistence(timeout: 5) == true`

---

#### `func testTappingFeedDoesNotCrash()`

Action:
1. Wait for `"Feed"` sidebar item (up to 5 s); fail with `XCTFail` if absent.
2. Call `feedItem.click()`.

Asserts:
- `app.exists == true` — app is still running after the tap.

---

#### `func testExpandControlVisibleWhenCardIsTruncated()`

Action:
1. Navigate to Feed by clicking the `"Feed"` sidebar item.
2. Query all buttons whose `accessibilityIdentifier` begins with `"expandToggle_"`.

Asserts:
- If `toggleButtons.count > 0`: `toggleButtons.firstMatch.isHittable == true`.
- If `toggleButtons.count == 0`: test is a no-op (acceptable when the database is empty).

---

## Summary Table

| Test file | Suite / class | Test function | What it seeds | Key assertion |
|-----------|--------------|---------------|---------------|---------------|
| `FeedDatabaseTests` | `FeedDatabase` | `migrationCreatesTable` | — | `tableExists("snapshots")` |
| `FeedDatabaseTests` | `FeedDatabase` | `latestSnapshotsReturnsNewest` | 2 mastodon rows | returns newer row only |
| `FeedDatabaseTests` | `FeedDatabase` | `latestSnapshotsMissingPlatform` | — | nil for absent platform |
| `FeedDatabaseTests` | `FeedDatabase` | `oneRowPerPlatformOrdered` | 3 platforms × 1 row | count == 3, correct recency |
| `FeedDatabaseTests` | `FeedDatabase` | `contentFieldPresentAfterRoundTrip` | bluesky row | data round-trips via JSON |
| `FeedViewModelTests` | `FeedViewModel` | `loadsCards` | mastodon snapshot | cards non-empty, no error |
| `FeedViewModelTests` | `FeedViewModel` | `emptyDatabaseProducesStaleReminders` | — | 4 stale-reminder cards |
| `FeedViewModelTests` | `FeedViewModel` | `staleReminderCard` | linkedin 4 days old | stale card present |
| `FeedViewModelTests` | `FeedViewModel` | `freshSnapshotNoStaleReminder` | linkedin 1 day old | no stale card for linkedin |
| `FeedViewModelTests` | `FeedViewModel` | `navigationTarget` | mastodon snapshot | navigationTarget == .mastodon |
| `FeedCardViewModelTests` | `FeedCardViewModel` | `displaySnippetExpanded` | 200-char snippet (expanded) | full text returned |
| `FeedCardViewModelTests` | `FeedCardViewModel` | `displaySnippetCollapsed` | 200-char snippet (collapsed) | ≤ 105 chars |
| `FeedCardViewModelTests` | `FeedCardViewModel` | `isTruncatedFalseForShortSnippet` | 11-char snippet | isTruncated == false |
| `FeedCardViewModelTests` | `FeedCardViewModel` | `isTruncatedTrueForLongSnippet` | 150-char snippet | isTruncated == true |
| `FeedCardViewModelTests` | `FeedCardViewModel` | `toggleExpandFlipsIsExpandedAndWritesBackToBinding` | any snippet | binding source toggled |
| `FeedCardBuilderTests` | `FeedCardBuilder` | `truncateShortText` | 11-char text | unchanged |
| `FeedCardBuilderTests` | `FeedCardBuilder` | `truncateAtWordBoundary` | 60-char text, limit 25 | word boundary, ends "…" |
| `FeedCardBuilderTests` | `FeedCardBuilder` | `truncateHardCutFallbackWhenNoSpace` | 300-char no-space text | 280 + "…" |
| `FeedCardBuilderTests` | `FeedCardBuilder` | `buildEmptySnapshotsProducesFourStaleReminders` | empty map | 4 stale cards |
| `FeedCardBuilderTests` | `FeedCardBuilder` | `buildIsNonThrowing` | empty map | compiles without `try` |
| `FeedCardBuilderTests` | `FeedCardBuilder` | `buildStaleReminderForLinkedInBeyondThreshold` | linkedin 4 days old | stale card present |
| `FeedCardBuilderTests` | `FeedCardBuilder` | `buildNoStaleReminderForLinkedInWithinThreshold` | linkedin 1 day old | no stale card |
| `FeedCardBuilderTests` | `FeedCardBuilder` | `buildAmazonStaleAfter30Days` | amazon 31 days old | stale card present |
| `FeedCardBuilderTests` | `FeedCardBuilder` | `buildNoStaleReminderForNonFileExportPlatform` | mastodon 365 days old | no stale card |
| `SidebarTests` | `Sidebar` | `feedCaseExistsInAllCases` | — | .feed in allCases |
| `SidebarTests` | `Sidebar` | `feedPositionedBetweenRunAndDashboard` | — | run < feed < dashboard |
| `FeedUITests` | `FeedUITests` | `testFeedItemExistsInSidebar` | — | "Feed" label exists |
| `FeedUITests` | `FeedUITests` | `testTappingFeedDoesNotCrash` | — | app still running |
| `FeedUITests` | `FeedUITests` | `testExpandControlVisibleWhenCardIsTruncated` | live DB | toggle button hittable |
