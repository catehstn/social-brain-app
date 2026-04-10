# Feed View — Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use trycycle-executing to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three open feed-related issues: human-readable card type badges (#20), @Observable migration (#21), and show stale reminders instead of "Nothing yet" empty state (#22).

**Architecture:** All three changes are narrow and independent. They are sequenced so tests stay green at every commit: display-name first (no behavioural change), observable migration second (refactor only, tests stay green), empty-state fix third (behaviour change, test update required).

**Tech Stack:** Swift 6, SwiftUI/macOS 14+, Swift Testing framework (`@Suite`, `@Test`, `#expect`), `@Observable` macro (Observation framework, Swift 5.9+).

---

## Pre-flight gate

Before touching anything, run the full unit test suite to confirm baseline is green:

```bash
cd /Users/cate/git/social-brain-app/.worktrees/feed-card-display-name
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' -only-testing:SocialBrainTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`

---

## Task 1: Add `displayName` to `FeedCardType` (Issue #20)

`FeedCardView` renders `Text(vm.card.cardType.rawValue)` which exposes programmer-style camelCase strings ("recentPost", "staleReminder") as visible UI badges. This is a pure additive change: add a computed property and update the view.

**Files:**
- Modify: `SocialBrain/Models/FeedCardType.swift`
- Modify: `SocialBrain/Views/Feed/FeedCardView.swift`
- Test: `SocialBrainTests/FeedCardBuilderTests.swift` (add 4 new assertions, no deletions)

- [ ] **Step 1: Write failing test**

Add to `SocialBrainTests/FeedCardBuilderTests.swift` inside the `FeedCardBuilder` suite:

```swift
@Test("FeedCardType displayName returns human-readable strings")
func feedCardTypeDisplayName() {
    #expect(FeedCardType.recentPost.displayName    == "Recent Post")
    #expect(FeedCardType.metricHighlight.displayName == "Metric Highlight")
    #expect(FeedCardType.upcomingEvent.displayName  == "Upcoming Event")
    #expect(FeedCardType.staleReminder.displayName  == "Stale Reminder")
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
  -only-testing:SocialBrainTests/FeedCardBuilderTests 2>&1 | grep -E "error:|feedCardTypeDisplayName"
```

Expected: compile error — `value of type 'FeedCardType' has no member 'displayName'`

- [ ] **Step 3: Implement `displayName` on `FeedCardType`**

Edit `SocialBrain/Models/FeedCardType.swift`:

```swift
import Foundation

enum FeedCardType: String, Codable, Sendable {
    case recentPost
    case metricHighlight
    case upcomingEvent
    case staleReminder

    var displayName: String {
        switch self {
        case .recentPost:      return "Recent Post"
        case .metricHighlight: return "Metric Highlight"
        case .upcomingEvent:   return "Upcoming Event"
        case .staleReminder:   return "Stale Reminder"
        }
    }
}
```

- [ ] **Step 4: Update `FeedCardView` to use `displayName`**

Edit `SocialBrain/Views/Feed/FeedCardView.swift`, change line 20 from:

```swift
Text(vm.card.cardType.rawValue)
```

to:

```swift
Text(vm.card.cardType.displayName)
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
  -only-testing:SocialBrainTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git -C /Users/cate/git/social-brain-app/.worktrees/feed-card-display-name \
  add SocialBrain/Models/FeedCardType.swift \
      SocialBrain/Views/Feed/FeedCardView.swift \
      SocialBrainTests/FeedCardBuilderTests.swift
git -C /Users/cate/git/social-brain-app/.worktrees/feed-card-display-name \
  commit -m "Add FeedCardType.displayName for human-readable badge labels (#20)"
```

---

## Task 2: Migrate `FeedViewModel` and `FeedCardViewModel` to `@Observable` (Issue #21)

All other ViewModels in the codebase (`DashboardViewModel`, `RunViewModel`, `PlatformsViewModel`, `HistoryViewModel`) use the `@Observable` macro with `@State` at call sites. `FeedViewModel` and `FeedCardViewModel` use the older `ObservableObject`/`@Published`/`@StateObject` pattern. This is a pure refactor — no behaviour changes.

**Why `@Observable` over `ObservableObject`:**
- Consistent with every other ViewModel in the project.
- `@Observable` tracks per-property access rather than publishing everything; SwiftUI re-renders only the views that actually read a changed property.
- Removes `@Published` annotations; `@StateObject` at call sites becomes `@State`.
- `objectWillChange.send()` in `FeedCardViewModel.toggleExpand()` is unnecessary with `@Observable` (the macro synthesises observation automatically) and must be removed.

**Key invariants to preserve:**
- `FeedViewModel.cards` must remain `var` (not `private(set)`) so `FeedCardView` can receive a `Binding<FeedCard>` via `$vm.cards[index]`.
- `FeedCardViewModel` holds a `Binding<FeedCard>` to write expand state back through `FeedViewModel.cards`. This mechanism is unchanged; only the class declaration changes.
- All existing tests must continue to pass without modification. Test access patterns (`vm.cards`, `vm.isLoading`, `vm.error`) work identically with `@Observable`.

**Files:**
- Modify: `SocialBrain/Views/Feed/FeedViewModel.swift`
- Modify: `SocialBrain/Views/Feed/FeedCardViewModel.swift`
- Modify: `SocialBrain/Views/Feed/FeedView.swift`
- Modify: `SocialBrain/Views/Feed/FeedCardView.swift`

No test file changes required — existing tests are already compatible with `@Observable`.

- [ ] **Step 1: Confirm existing tests pass (baseline)**

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
  -only-testing:SocialBrainTests/FeedViewModelTests \
  -only-testing:SocialBrainTests/FeedCardViewModelTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 2: Migrate `FeedViewModel`**

Replace the full contents of `SocialBrain/Views/Feed/FeedViewModel.swift`:

```swift
import SwiftUI
import Observation

@Observable
@MainActor
final class FeedViewModel {

    // cards must be var (not private(set)) so FeedCardView can receive a
    // Binding<FeedCard> via $vm.cards[index] for expand/collapse write-back.
    var cards: [FeedCard] = []
    private(set) var isLoading: Bool = false
    private(set) var error: String?

    private let database: AppDatabase
    private let now: () -> Date

    init(database: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            let snapshots = try await database.latestSnapshots()
            cards = FeedCardBuilder.build(snapshots: snapshots, now: now())
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
```

- [ ] **Step 3: Migrate `FeedCardViewModel`**

Replace the full contents of `SocialBrain/Views/Feed/FeedCardViewModel.swift`:

```swift
import SwiftUI
import Observation

@Observable
@MainActor
final class FeedCardViewModel {

    // Binding into FeedViewModel.cards so expand state is shared.
    private var cardBinding: Binding<FeedCard>

    init(card: Binding<FeedCard>) {
        self.cardBinding = card
    }

    var card: FeedCard { cardBinding.wrappedValue }

    var displaySnippet: String {
        card.isExpanded ? card.snippet : FeedCardBuilder.truncate(card.snippet, limit: 100)
    }

    var isTruncated: Bool {
        card.snippet.count > 100
    }

    func toggleExpand() {
        cardBinding.wrappedValue.isExpanded.toggle()
        // @Observable synthesises change notification automatically;
        // no objectWillChange.send() needed.
    }
}
```

- [ ] **Step 4: Update `FeedView` call site (`@StateObject` → `@State`)**

Replace the full contents of `SocialBrain/Views/Feed/FeedView.swift`:

```swift
import SwiftUI

struct FeedView: View {
    @State private var vm: FeedViewModel
    var onNavigate: (SidebarItem, Platform?) -> Void

    init(database: AppDatabase, onNavigate: @escaping (SidebarItem, Platform?) -> Void) {
        _vm = State(wrappedValue: FeedViewModel(database: database))
        self.onNavigate = onNavigate
    }

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView("Loading feed…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.cards.filter({ $0.cardType != .staleReminder }).isEmpty {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "rectangle.stack",
                    description: Text("Run a collection to populate your feed.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(vm.cards.indices, id: \.self) { index in
                            FeedCardView(card: $vm.cards[index])
                                .onTapGesture {
                                    onNavigate(.dashboard, vm.cards[index].navigationTarget)
                                }
                                .accessibilityIdentifier("feedCard_\(vm.cards[index].id)")
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle("Feed")
        .task { await vm.load() }
        .refreshable { await vm.load() }
    }
}
```

Note: `$vm.cards[index]` — the `$` prefix binds to the `@State` wrapper's projected value (`Binding<FeedViewModel>`), and subscripting `.cards[index]` produces `Binding<FeedCard>`. This is the same mechanism that worked with `@StateObject`; it continues to work with `@State` + `@Observable`.

- [ ] **Step 5: Update `FeedCardView` call site (`@StateObject` → `@State`)**

Replace the full contents of `SocialBrain/Views/Feed/FeedCardView.swift`:

```swift
import SwiftUI

struct FeedCardView: View {
    // Binding writes back into FeedViewModel.cards — avoids stale local copy.
    @Binding var card: FeedCard
    @State private var vm: FeedCardViewModel

    init(card: Binding<FeedCard>) {
        self._card = card
        _vm = State(wrappedValue: FeedCardViewModel(card: card))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(vm.card.platform.displayName,
                      systemImage: platformIcon(vm.card.platform))
                    .font(.headline)
                Spacer()
                Text(vm.card.cardType.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(vm.displaySnippet)
                .font(.body)
                .lineLimit(vm.card.isExpanded ? nil : 3)

            if vm.isTruncated {
                Button(vm.card.isExpanded ? "Show less" : "Show more") {
                    vm.toggleExpand()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .accessibilityIdentifier("expandToggle_\(vm.card.id)")
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private func platformIcon(_ platform: Platform) -> String {
        switch platform {
        case .mastodon:    return "bubble.left"
        case .bluesky:     return "cloud"
        case .buttondown:  return "envelope"
        case .goatCounter: return "chart.line.uptrend.xyaxis"
        case .vercel:      return "server.rack"
        case .calendly:    return "calendar"
        case .amazon:      return "shippingbox"
        case .jetpack:     return "bolt"
        case .linkedin:    return "person.crop.square"
        case .oreilly:     return "book"
        case .substack:    return "newspaper"
        }
    }
}
```

- [ ] **Step 6: Run full test suite to verify refactor is clean**

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
  -only-testing:SocialBrainTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` — all 114+ tests must pass.

- [ ] **Step 7: Commit**

```bash
git -C /Users/cate/git/social-brain-app/.worktrees/feed-card-display-name \
  add SocialBrain/Views/Feed/FeedViewModel.swift \
      SocialBrain/Views/Feed/FeedCardViewModel.swift \
      SocialBrain/Views/Feed/FeedView.swift \
      SocialBrain/Views/Feed/FeedCardView.swift
git -C /Users/cate/git/social-brain-app/.worktrees/feed-card-display-name \
  commit -m "Migrate FeedViewModel and FeedCardViewModel to @Observable (#21)"
```

---

## Task 3: Show stale reminders instead of "Nothing yet" empty state (Issue #22)

**Problem:** `FeedView` shows `ContentUnavailableView("Nothing yet")` when `cards.filter({ $0.cardType != .staleReminder }).isEmpty`. This is triggered when the only cards are stale reminders (e.g., user has file-export platforms configured but no collections yet). The result is that actionable "re-export your data" reminders are hidden behind an unhelpful empty state.

**Fix:** Change the empty-state condition so it shows "Nothing yet" only when `cards` is completely empty (including stale reminders). When the only cards are stale reminders, show them — they are actionable.

**Justification:** `FeedCardBuilder.build` always generates stale-reminder cards for the 4 file-export platforms (linkedin, substack, amazon, oreilly) when no snapshot exists. Hiding these on first launch leaves the user with no guidance. Showing them is the correct behaviour: "No LinkedIn data yet — export a file to get started."

**Files:**
- Modify: `SocialBrain/Views/Feed/FeedView.swift`
- Test: `SocialBrainTests/FeedViewModelTests.swift` (update 1 existing test + add 1 new test)

- [ ] **Step 1: Identify the test that documents the old wrong behaviour**

The test `emptyDatabaseProducesStaleReminders` in `FeedViewModelTests.swift` asserts that `vm.cards` contains 4 stale reminder cards for an empty database. This is correct and should stay. However, `FeedView` was filtering these out of the visible list.

The new assertion needed: when the database is empty, `vm.cards` is non-empty (contains stale reminders) and `.cards.isEmpty` is `false`.

- [ ] **Step 2: Write a failing test that exercises the new empty-state condition**

Add to `SocialBrainTests/FeedViewModelTests.swift`:

```swift
@Test("empty database cards array is non-empty (stale reminders present)")
func emptyDatabaseHasNonEmptyCards() async throws {
    let db = try makeDB()
    let vm = FeedViewModel(database: db)
    await vm.load()
    // FeedView should NOT show "Nothing yet" — stale reminders are present
    #expect(!vm.cards.isEmpty)
}
```

This test already passes with the current code (the ViewModel populates stale reminder cards); it documents the contract for the view.

- [ ] **Step 3: Fix `FeedView` empty-state condition**

In `SocialBrain/Views/Feed/FeedView.swift`, change the empty-state condition from:

```swift
} else if vm.cards.filter({ $0.cardType != .staleReminder }).isEmpty {
```

to:

```swift
} else if vm.cards.isEmpty {
```

The full updated body section:

```swift
var body: some View {
    Group {
        if vm.isLoading {
            ProgressView("Loading feed…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.cards.isEmpty {
            ContentUnavailableView(
                "Nothing yet",
                systemImage: "rectangle.stack",
                description: Text("Run a collection to populate your feed.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(vm.cards.indices, id: \.self) { index in
                        FeedCardView(card: $vm.cards[index])
                            .onTapGesture {
                                onNavigate(.dashboard, vm.cards[index].navigationTarget)
                            }
                            .accessibilityIdentifier("feedCard_\(vm.cards[index].id)")
                    }
                }
                .padding(.vertical)
            }
        }
    }
    .navigationTitle("Feed")
    .task { await vm.load() }
    .refreshable { await vm.load() }
}
```

Note: `FeedCardBuilder.build` will only ever return an empty array if there are zero platforms configured and all snapshot collections return nothing — which in practice never happens because the 4 file-export platforms always generate stale reminders when no snapshot exists. The `"Nothing yet"` state is still reachable if `FeedCardBuilder.build` is called with a non-nil snapshot dictionary that is completely empty AND no file-export platforms have stale thresholds — but this cannot happen with the current builder logic. The condition `vm.cards.isEmpty` is therefore correct and sufficient.

- [ ] **Step 4: Run tests**

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
  -only-testing:SocialBrainTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git -C /Users/cate/git/social-brain-app/.worktrees/feed-card-display-name \
  add SocialBrain/Views/Feed/FeedView.swift \
      SocialBrainTests/FeedViewModelTests.swift
git -C /Users/cate/git/social-brain-app/.worktrees/feed-card-display-name \
  commit -m "Show stale reminders instead of empty state when no API data yet (#22)"
```

---

## Final gate

Run the full unit test suite one last time to confirm all issues are resolved cleanly:

```bash
xcodebuild test -scheme SocialBrain -destination 'platform=macOS' \
  -only-testing:SocialBrainTests 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` with the same count as baseline or higher (due to new tests added in Tasks 1 and 3).

---

## Ordering justification

1. **Task 1 (displayName)** first — purely additive, no risk of breaking anything, makes Task 2's view update cleaner since `FeedCardView` already uses `displayName` in the updated code.
2. **Task 2 (@Observable migration)** second — pure refactor. All existing tests pass without modification. Tasks 1 and 2 share a commit boundary.
3. **Task 3 (empty state fix)** last — the only behaviour-changing task, requiring a test update. Keeping it last minimises the chance of confusing a refactor failure with a behaviour failure.
