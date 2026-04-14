# Platforms Page Redesign — Test Plan
**Date:** 2026-04-14
**Feature:** Platforms grid/card layout with push navigation, SF Symbol icons, and hide/show

---

## Harness requirements

No new harnesses need to be built. Existing infrastructure is sufficient:

- **Swift Testing framework** (`@Suite`, `@Test`, `#expect`) — already in use in `SocialBrainTests/`.
- **`UserDefaults` injection** — `PlatformVisibilityStore` exposes a `nonisolated(unsafe) static var defaults: UserDefaults`, matching the `InstanceRegistry` pattern already tested in `InstanceRegistryTests.swift`. Tests inject a `UserDefaults(suiteName: UUID().uuidString)!` and call `resetAll()` in `init()`.
- **XCUITest harness** — `SocialBrainUITests` is already in place with app launch and sidebar navigation patterns. New platform UI tests extend this class with a helper that skips onboarding.
- **Dependency:** All XCUITests listed below require the Platforms sidebar item to be visible and navigable. This is true on any post-onboarding launch (which the existing `testOnboardingWizardCompletesAndDismisses` already verifies).

---

## Test plan

### 1. XCUITest: Platforms navigation smoke
**Type:** Integration (UI)
**File:** `SocialBrainUITests/SocialBrainUITests.swift`
**Source of truth:** Implementation plan — PlatformsView is the detail pane for the `.platforms` sidebar item.

**Steps:**
1. Launch app, skip onboarding.
2. Click "Platforms" in the sidebar outline.
3. Wait up to 5 s for the Platforms navigation title to appear.

**Pass criteria:**
- `app.staticTexts["Platforms"].waitForExistence(timeout: 5)` returns true.
- For at least one known platform name (e.g. "Buttondown"), `app.staticTexts["Buttondown"].waitForExistence(timeout: 3)` returns true.
- The image element with identifier `envelope.fill` (SF Symbol used for Buttondown) exists: `app.images["envelope.fill"].waitForExistence(timeout: 3)`.

**Fail criteria:** Any assertion above fails — indicates Platforms view did not load, or the grid is not rendering platform names and icons.

---

### 2. XCUITest: Card tap pushes to detail view
**Type:** Integration (UI)
**File:** `SocialBrainUITests/SocialBrainUITests.swift`
**Source of truth:** Implementation plan — `NavigationLink(value: platform)` pushes `PlatformDetailView` with `navigationTitle(platform.displayName)`.

**Steps:**
1. Launch app, skip onboarding, navigate to Platforms.
2. Click the "Buttondown" card.
3. Wait up to 3 s.

**Pass criteria:**
- `app.navigationBars["Buttondown"].waitForExistence(timeout: 3)` returns true (the pushed view's navigation title).
- A back button exists: `app.buttons["Platforms"].exists` is true (macOS back button uses the parent nav title as its label).
- The Platforms grid is no longer the foremost content (cards grid is no longer directly visible — `app.staticTexts["GoatCounter"].exists` returns false or is not hittable).

**Fail criteria:** Navigation title does not change, back button absent, or grid remains visible without a detail view appearing.

---

### 3. XCUITest: Back button returns to grid
**Type:** Integration (UI)
**File:** `SocialBrainUITests/SocialBrainUITests.swift`
**Source of truth:** `NavigationStack` push/pop contract.

**Steps:**
1. Launch app, skip onboarding, navigate to Platforms.
2. Click the "Buttondown" card (push to detail).
3. Wait for navigation title "Buttondown".
4. Click the back button (labeled "Platforms").
5. Wait up to 3 s.

**Pass criteria:**
- `app.staticTexts["Buttondown"].waitForExistence(timeout: 3)` returns true again (card is back in the grid).
- `app.staticTexts["GoatCounter"].exists` is true (grid is restored).

---

### 4. XCUITest: Hide platform removes card from grid
**Type:** Integration (UI)
**File:** `SocialBrainUITests/SocialBrainUITests.swift`
**Source of truth:** Implementation plan — `PlatformDetailView` has a "Hide <platform>" button; hidden platforms are removed from `visiblePlatforms`.

**Steps:**
1. Launch app, skip onboarding, navigate to Platforms. Record whether "Buttondown" card exists (it should).
2. Click "Buttondown" card to push detail.
3. Click "Hide Buttondown" button.
4. Navigate back (back button).
5. Wait up to 2 s.

**Pass criteria:**
- After hiding and returning, `app.staticTexts["Buttondown"].exists` is false (card gone from active grid).
- The toolbar show-dismissed button (identifier `eye.slash` or `eye.slash.fill`) exists, confirming the affordance appears when hidden platforms are present.

**Cleanup:** The test must reset `UserDefaults.standard` key `hiddenPlatform_buttondown` after the test run, or launch with a fresh suite name via launch arguments. (Use `app.launchArguments += ["-resetHiddenPlatforms", "1"]` and handle it in `AppDelegate`; or rely on test isolation by running this test with a separate suite UserDefaults — acceptable given existing pattern.)

---

### 5. XCUITest: Show hidden platform restores card
**Type:** Integration (UI)
**File:** `SocialBrainUITests/SocialBrainUITests.swift`
**Source of truth:** Implementation plan — "Show" button on dimmed hidden card calls `viewModel.showPlatform(platform)`.

**Steps:**
1. (Following test 4, or re-hide Buttondown at start of test.)
2. Click the toolbar button with system image `eye.slash` or `eye.slash.fill` to toggle show-hidden mode.
3. Wait up to 2 s for dimmed Buttondown card to appear.
4. Click "Show" button overlaid on the dimmed Buttondown card.
5. Toggle show-hidden mode off (click toolbar button again).
6. Wait up to 2 s.

**Pass criteria:**
- After clicking "Show", `app.staticTexts["Buttondown"].waitForExistence(timeout: 3)` returns true in the active grid (card restored, no longer dimmed).
- Show-dismissed toolbar button is no longer visible (`.opacity(hiddenPlatforms.isEmpty ? 0 : 1)` hides it when none are hidden).

---

### 6. Unit test: PlatformVisibilityStore — default is visible
**Type:** Unit
**File:** `SocialBrainTests/PlatformVisibilityStoreTests.swift` (new)
**Source of truth:** Implementation plan — `isHidden` returns `defaults.bool(forKey:)` which returns `false` when key is absent.

**Setup:** Inject `UserDefaults(suiteName: "test-visibility-\(UUID().uuidString)")` into `PlatformVisibilityStore.defaults`.

```
Given: fresh UserDefaults suite (no keys set)
When:  PlatformVisibilityStore.isHidden(.buttondown)
Then:  returns false
```

---

### 7. Unit test: PlatformVisibilityStore — hide persists
**Type:** Unit
**File:** `SocialBrainTests/PlatformVisibilityStoreTests.swift`
**Source of truth:** Implementation plan — `hide()` calls `defaults.set(true, forKey:)`.

```
Given: fresh defaults
When:  PlatformVisibilityStore.hide(.mastodon)
Then:  PlatformVisibilityStore.isHidden(.mastodon) == true
```

---

### 8. Unit test: PlatformVisibilityStore — show clears hidden state
**Type:** Unit
**File:** `SocialBrainTests/PlatformVisibilityStoreTests.swift`
**Source of truth:** Implementation plan — `show()` calls `defaults.removeObject(forKey:)`.

```
Given: .bluesky is hidden
When:  PlatformVisibilityStore.show(.bluesky)
Then:  PlatformVisibilityStore.isHidden(.bluesky) == false
```

---

### 9. Unit test: PlatformVisibilityStore — resetAll clears all
**Type:** Unit
**File:** `SocialBrainTests/PlatformVisibilityStoreTests.swift`
**Source of truth:** Implementation plan — `resetAll()` iterates `Platform.allCases` and removes each key.

```
Given: .buttondown, .mastodon, .bluesky all hidden
When:  PlatformVisibilityStore.resetAll()
Then:  isHidden returns false for all three
```

---

### 10. Unit test: PlatformVisibilityStore — isolation between suites
**Type:** Unit
**File:** `SocialBrainTests/PlatformVisibilityStoreTests.swift`
**Source of truth:** Regression guard — tests must not bleed state into `UserDefaults.standard`.

```
Given: PlatformVisibilityStore.defaults = custom suite
When:  PlatformVisibilityStore.hide(.vercel)
Then:  UserDefaults.standard.bool(forKey: "hiddenPlatform_vercel") == false
```

---

### 11. Unit test: PlatformsViewModel.hidePlatform / isHidden reactive update
**Type:** Unit
**File:** `SocialBrainTests/PlatformsViewModelHiddenTests.swift` (new) or extend `PlatformVisibilityStoreTests.swift`
**Source of truth:** Implementation plan — `hiddenPlatforms` property on `PlatformsViewModel`; `hidePlatform` updates it synchronously.

**Setup:** Inject test `UserDefaults` into `PlatformVisibilityStore.defaults`; create `PlatformsViewModel(database: AppDatabase.makeInMemory())`.

```
Given: viewModel created with fresh test defaults
When:  viewModel.hidePlatform(.calendly)
Then:  viewModel.isHidden(.calendly) == true
       viewModel.hiddenPlatforms.contains(.calendly) == true
```

---

### 12. Unit test: PlatformsViewModel.showPlatform reactive update
**Type:** Unit
**File:** Same as test 11.
**Source of truth:** Implementation plan — `showPlatform` removes from `hiddenPlatforms`.

```
Given: .calendly has been hidden via viewModel.hidePlatform
When:  viewModel.showPlatform(.calendly)
Then:  viewModel.isHidden(.calendly) == false
       viewModel.hiddenPlatforms.contains(.calendly) == false
```

---

### 13. Unit test: PlatformsViewModel.reload() restores hidden state from UserDefaults
**Type:** Unit
**File:** Same as test 11.
**Source of truth:** Implementation plan — `reload()` sets `hiddenPlatforms = Set(Platform.allCases.filter { PlatformVisibilityStore.isHidden($0) })`.

```
Given: PlatformVisibilityStore has .mastodon marked hidden (via store directly)
When:  viewModel.reload() is called
Then:  viewModel.isHidden(.mastodon) == true
```

This verifies persistence round-trip — that the ViewModel correctly reads state written directly to the store (simulating an app restart).

---

### 14. Unit test: Hidden configured platform auto-shows on save
**Type:** Unit
**File:** Same as test 11.
**Source of truth:** Implementation plan — `save(_:for:)` calls `PlatformVisibilityStore.show(instance.platform)` and `hiddenPlatforms.remove(instance.platform)` after `reload()`.

**Setup:** Inject test `UserDefaults`; create in-memory `AppDatabase`; inject test Keychain (or mock).

```
Given: .buttondown is hidden (via viewModel.hidePlatform)
When:  viewModel.save(credentials, for: PlatformInstance(platform: .buttondown)) is called
Then:  viewModel.isHidden(.buttondown) == false
       PlatformVisibilityStore.isHidden(.buttondown) == false
```

Note: This test verifies the auto-show rule from sources of truth (the plan) without reading the implementation to determine expected output.

---

### 15. Unit test: Platform.sfSymbol — all 14 cases have non-empty symbol
**Type:** Unit
**File:** `SocialBrainTests/PlatformSFSymbolTests.swift` (new)
**Source of truth:** Implementation plan SF Symbol map; `Platform.allCases` has 14 cases.

```
For each platform in Platform.allCases (14 total):
    platform.sfSymbol must be a non-empty String
```

This is an exhaustiveness smoke test: if a case is added without a symbol entry, it will fail with an empty string or a compiler error on the exhaustive switch.

---

### 16. Unit test: Platform.sfSymbol — specific symbol assignments match spec
**Type:** Unit
**File:** `SocialBrainTests/PlatformSFSymbolTests.swift`
**Source of truth:** Implementation plan SF Symbol map (the authoritative spec).

```
Platform.buttondown.sfSymbol == "envelope.fill"
Platform.goatCounter.sfSymbol == "chart.bar.fill"
Platform.mastodon.sfSymbol == "bubble.left.and.bubble.right.fill"
Platform.hackerNews.sfSymbol == "flame.fill"
```

(Spot-check a representative sample of four; covering all 14 is acceptable but not required — exhaustiveness is already confirmed by test 15.)

---

### 17. Unit test: AuthType.displayName — all four cases have non-empty display names
**Type:** Unit
**File:** `SocialBrainTests/PlatformSFSymbolTests.swift` or a new `AuthTypeTests.swift`
**Source of truth:** Implementation plan — `AuthType` has four cases: `.apiKey`, `.oauthToken`, `.fileExport`, `.noAuth`. Extension adds `displayName`.

```
For each case in [AuthType.apiKey, .oauthToken, .fileExport, .noAuth]:
    case.displayName must be a non-empty String
```

---

### 18. Regression: all existing unit tests remain green
**Type:** Regression
**Command:** `xcodebuild test -scheme SocialBrain -only-testing SocialBrainTests -destination 'platform=macOS'`
**Source of truth:** All existing passing tests in `SocialBrainTests/`.

Run before and after implementing the feature. If any test that was green before becomes red, it is a regression introduced by the platforms redesign and must be fixed before the PR is opened.

Specific areas most at risk of accidental breakage:
- `InstanceRegistryTests` — shares `UserDefaults` injection pattern with new `PlatformVisibilityStore`.
- `PlatformInstanceTests` — touches `Platform` model; `sfSymbol` addition must not break existing conformances.
- `MultiInstanceKeychainTests` — may be affected if `PlatformsViewModel.save` signature changes.

---

### 19. Compilation gate
**Type:** Build
**Command:** `xcodebuild build-for-testing -scheme SocialBrain -destination 'platform=macOS'`
**Source of truth:** Swift compiler.

Run after every significant change. Catches:
- Non-exhaustive `switch` over `Platform` (14 cases) in `sfSymbol`.
- Non-exhaustive `switch` over `AuthType` (4 cases) in `displayName`.
- Unresolved `NavigationLink(value:)` type — `Platform` must conform to `Hashable` for the `navigationDestination(for: Platform.self)` pattern.
- Missing `PlatformVisibilityStore`, `PlatformCard`, `PlatformDetailView` symbols.

---

## Coverage summary

### Covered

| Area | How covered |
|---|---|
| Platform grid renders in Platforms pane | Test 1 |
| Card tap pushes to detail (sheet→push migration) | Test 2 |
| Back button returns to grid | Test 3 |
| Hide platform removes card | Test 4 |
| Show hidden platform restores card | Test 5 |
| `PlatformVisibilityStore` persistence correctness | Tests 6–10 |
| `PlatformsViewModel` reactive hidden state | Tests 11–12 |
| `reload()` restores hidden state after restart | Test 13 |
| Auto-show on credential save | Test 14 |
| SF Symbol exhaustiveness (all 14 platforms) | Tests 15–16 |
| `AuthType.displayName` exhaustiveness (all 4 cases) | Test 17 |
| No regressions in existing unit tests | Test 18 |
| Compilation with all new types and switches | Test 19 |

### Explicitly excluded

| Area | Reason |
|---|---|
| Visual card proportions (colors, spacing, corner radii) | Agreed strategy uses screenshot artifact for layout quality, not brittle coordinate or color assertions. XCUITest screenshot of test 1 provides the artifact. |
| Auto-show on file import | `importFile(for:allowedExtensions:)` requires `NSOpenPanel` interaction. Verified indirectly via test 14 (same auto-show code path) and tested by calling `showPlatform` directly. |
| `PlatformCredentialSheet` internals | Unchanged per implementation plan. Existing credential and Keychain tests cover it. |
| OAuth flow from detail view | Out of scope — no change to OAuth flow; covered by `MastodonCollectorTests` etc. |
| `BGTaskScheduler` / `UserNotifications` | Not part of this change. |

### Residual risks

- **XCUITest reliability on CI**: macOS UI tests can be flaky with timing. Tests 1–5 use generous `waitForExistence` timeouts (3–5 s) to mitigate this.
- **Hidden state test isolation in UI tests**: Tests 4–5 mutate `UserDefaults.standard` at the app process level. If run in sequence without cleanup, test 5 may not see a hidden platform if test 4's cleanup runs first. Mitigation: tests 4 and 5 should re-establish their own precondition at the start, or run with a dedicated `launchArguments` flag that resets hidden state on launch.
- **`Platform.sfSymbol` compiler exhaustiveness vs runtime**: The unit test in test 15 catches cases where a `default:` branch silently returns an empty string. If the switch uses a `default: ""` fallback, the compiler won't warn but the unit test will fail — which is the intended detection mechanism.
