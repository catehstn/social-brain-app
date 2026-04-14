# Platforms Page Redesign — Implementation Plan

## Goal

Replace the current flat-checklist `PlatformsView` with a polished grid/card layout:

1. **Platform icons** — each card shows a distinctive SF Symbol icon.
2. **Sub-pages via NavigationStack push** — clicking a card pushes to a dedicated platform detail page instead of opening a modal sheet.
3. **Dismissible platforms** — users can hide platforms they don't use, with a way to restore hidden ones. Hidden state is persisted in `UserDefaults`.
4. **Card/grid layout** — replace the sectioned list with an adaptive grid of cards.

All existing functionality is preserved: Set Up, Edit, Add Another Instance, file import, OAuth flows, auto-labelling.

---

## Architecture decisions and justifications

### NavigationStack in the detail pane

`ContentView` uses `NavigationSplitView`. The detail column for `.platforms` is currently just `PlatformsView(database: database)`. The detail column in a `NavigationSplitView` can itself contain a `NavigationStack`, which is the standard macOS pattern for column-internal push navigation.

**Decision:** Wrap `PlatformsView` in a `NavigationStack`. Tapping a platform card uses a `NavigationLink` with a `PlatformDetailView` destination. The navigation stack is contained entirely within the platforms detail column — no changes to `ContentView` or `NavigationSplitView` structure.

This is the idiomatic pattern: `NavigationSplitView { sidebar } detail: { NavigationStack { … } }`.

### PlatformDetailView replaces PlatformCredentialSheet as primary entry point

`PlatformCredentialSheet` is currently a modal `sheet` opened directly from `PlatformsView`. In the redesigned flow, clicking a card pushes `PlatformDetailView` (a full-page pushed view) that lists configured instances and provides a "Set Up" / "Edit" path. The actual credential form (`PlatformCredentialSheet`) remains a modal sheet but is now opened from `PlatformDetailView` instead of from `PlatformsView`.

**Exception:** The "Add another instance" sub-flow still uses a small sheet because it's a transient name-entry step. This sheet is now in `PlatformDetailView`.

### Adaptive grid

Use `LazyVGrid` with `GridItem(.adaptive(minimum: 180, maximum: 240))` for the card grid. Cards are `PlatformCard` views, approximately 180×140pt.

Cards show:
- SF Symbol icon (large, accent-coloured, see icon map below)
- Platform display name
- Status indicator: configured instances count, or "Not set up" in secondary colour
- A "hidden" badge (eye.slash) if shown in the "show hidden" list

### Hidden state — `PlatformVisibilityStore`

A new pure-value namespace enum `PlatformVisibilityStore` (same pattern as `InstanceRegistry`), backed by `UserDefaults`, with keys `"hiddenPlatform_<platform.rawValue>"` → `Bool`.

API:
```swift
enum PlatformVisibilityStore {
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    static func isHidden(_ platform: Platform) -> Bool
    static func hide(_ platform: Platform)
    static func show(_ platform: Platform)
    static func resetAll()  // test teardown
}
```

**Auto-show rule:** When a platform is hidden but then receives credentials (via Save or import), it is automatically made visible again. This is implemented in `PlatformsViewModel.save(_:for:)` and `PlatformsViewModel.importFile(for:allowedExtensions:)`.

**Show hidden affordance:** A toolbar button (eye icon) toggles a `@State var showingHidden: Bool` in `PlatformsView`. When true, the grid shows hidden platforms with a dimmed card and "Show" button overlaid.

### PlatformsViewModel changes

`PlatformsViewModel` gains a reactive `hiddenPlatforms: Set<Platform>` property (tracked by `@Observable`) and three methods:

```swift
private(set) var hiddenPlatforms: Set<Platform> = []

func hidePlatform(_ platform: Platform) {
    PlatformVisibilityStore.hide(platform)
    hiddenPlatforms.insert(platform)
}

func showPlatform(_ platform: Platform) {
    PlatformVisibilityStore.show(platform)
    hiddenPlatforms.remove(platform)
}

func isHidden(_ platform: Platform) -> Bool {
    hiddenPlatforms.contains(platform)
}
```

`reload()` also refreshes `hiddenPlatforms`:
```swift
hiddenPlatforms = Set(Platform.allCases.filter { PlatformVisibilityStore.isHidden($0) })
```

These are plain synchronous methods — no `@Published` needed since `@Observable` tracks property access automatically.

Auto-show is added in `save(_:for:)` and `importFile(for:allowedExtensions:)` after `reload()`:
```swift
PlatformVisibilityStore.show(instance.platform)
hiddenPlatforms.remove(instance.platform)
```

### SF Symbol icon map

| Platform | SF Symbol |
|---|---|
| Buttondown | `envelope.fill` |
| GoatCounter | `chart.bar.fill` |
| Vercel | `triangle.fill` |
| Calendly | `calendar` |
| Amazon KDP | `books.vertical.fill` |
| Mastodon | `bubble.left.and.bubble.right.fill` |
| Jetpack Stats | `bolt.fill` |
| Bluesky | `cloud.fill` |
| LinkedIn | `briefcase.fill` |
| O'Reilly | `text.book.closed.fill` |
| Substack | `doc.richtext.fill` |
| Google Search Console | `magnifyingglass` |
| Buffer | `tray.and.arrow.up.fill` |
| Hacker News | `flame.fill` |

Add `var sfSymbol: String` computed property to `Platform`. The switch must cover all 14 platform cases exhaustively.

---

## Files to create

| File | Purpose |
|---|---|
| `SocialBrain/Models/PlatformVisibilityStore.swift` | UserDefaults-backed hidden state |
| `SocialBrain/Views/Platforms/PlatformCard.swift` | Card component for grid |
| `SocialBrain/Views/Platforms/PlatformDetailView.swift` | Pushed detail page (replaces PlatformsView's direct sheet) |

## Files to modify

| File | Change |
|---|---|
| `SocialBrain/Models/Platform.swift` | Add `var sfSymbol: String` (exhaustive over all 14 cases) |
| `SocialBrain/Views/Platforms/PlatformsView.swift` | Replace list with NavigationStack + LazyVGrid; remove `addingInstanceFor`/`newInstanceLabel` state; add show-hidden toggle toolbar button |
| `SocialBrain/Views/Platforms/PlatformsViewModel.swift` | Add `hiddenPlatforms` property; add `hidePlatform`, `showPlatform`, `isHidden` methods; update `reload()`; auto-show on configure |

## Files to delete

None. `PlatformCredentialSheet` is retained unchanged — it is now opened as a sheet from `PlatformDetailView`.

---

## Detailed component specs

### `PlatformsView`

```swift
struct PlatformsView: View {
    let database: AppDatabase
    @State private var viewModel: PlatformsViewModel
    @State private var showingHidden = false

    init(database: AppDatabase) {
        self.database = database
        _viewModel = State(wrappedValue: PlatformsViewModel(database: database))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)], spacing: 16) {
                    ForEach(visiblePlatforms) { platform in
                        NavigationLink(value: platform) {
                            PlatformCard(platform: platform, viewModel: viewModel)
                        }
                        .buttonStyle(.plain)
                    }
                    if showingHidden {
                        ForEach(hiddenPlatforms) { platform in
                            PlatformCard(platform: platform, viewModel: viewModel, isHiddenCard: true)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Platforms")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingHidden.toggle()
                    } label: {
                        Label(showingHidden ? "Hide dismissed" : "Show dismissed",
                              systemImage: showingHidden ? "eye.slash.fill" : "eye.slash")
                    }
                    .opacity(hiddenPlatforms.isEmpty ? 0 : 1)
                }
            }
            .navigationDestination(for: Platform.self) { platform in
                PlatformDetailView(platform: platform, viewModel: viewModel)
            }
        }
        .onAppear { viewModel.reload() }
    }

    private var visiblePlatforms: [Platform] {
        Platform.allCases.filter { !viewModel.isHidden($0) }
    }

    private var hiddenPlatforms: [Platform] {
        Platform.allCases.filter { viewModel.isHidden($0) }
    }
}
```

Key points:
- `addingInstanceFor`, `editingInstance`, and `newInstanceLabel` state vars are **removed** from `PlatformsView`; all instance management moves to `PlatformDetailView`.
- `NavigationLink(value: platform)` uses the type-safe destination pattern with `navigationDestination(for: Platform.self)`.
- `Platform` already conforms to `Identifiable` via `id: String { rawValue }` — `ForEach` works correctly.

### `PlatformCard`

```swift
struct PlatformCard: View {
    let platform: Platform
    let viewModel: PlatformsViewModel
    var isHiddenCard: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: platform.sfSymbol)
                .font(.system(size: 32))
                .foregroundStyle(isHiddenCard ? .secondary : Color.accentColor)
            Text(platform.displayName)
                .font(.headline)
                .multilineTextAlignment(.center)
            statusView
            if isHiddenCard {
                Button("Show") { viewModel.showPlatform(platform) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
        .opacity(isHiddenCard ? 0.5 : 1)
    }

    @ViewBuilder
    private var statusView: some View {
        let instances = viewModel.configuredInstances[platform] ?? []
        if instances.isEmpty {
            Text("Not set up")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(instances.count == 1 ? "1 account" : "\(instances.count) accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

### `PlatformDetailView`

This view is the platform overview page shown when a card is tapped. It lists configured instances and opens `PlatformCredentialSheet` as a sheet for editing.

```swift
struct PlatformDetailView: View {
    let platform: Platform
    let viewModel: PlatformsViewModel

    @State private var editingInstance: PlatformInstance?
    @State private var addingInstance = false
    @State private var newInstanceLabel = ""

    var body: some View {
        List {
            Section {
                let instances = viewModel.configuredInstances[platform] ?? []
                if instances.isEmpty {
                    Button("Set Up") {
                        editingInstance = PlatformInstance(platform: platform)
                    }
                    .buttonStyle(.bordered)
                } else {
                    ForEach(instances, id: \.self) { instanceName in
                        let inst = PlatformInstance(platform: platform, instanceName: instanceName)
                        instanceRow(inst)
                    }
                    if platform.authType != .fileExport {
                        Button("+ Add another \(platform.displayName)") {
                            newInstanceLabel = ""
                            addingInstance = true
                        }
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Image(systemName: platform.sfSymbol)
                        .foregroundStyle(Color.accentColor)
                    Text("Accounts")
                }
            }

            Section {
                Button("Hide \(platform.displayName)") {
                    viewModel.hidePlatform(platform)
                }
                .foregroundStyle(.secondary)
            } footer: {
                Text("Hides this platform from the grid. Reveal it again with the eye button in the toolbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(platform.displayName)
        .navigationSubtitle(platform.authType.displayName)
        .sheet(item: $editingInstance) { inst in
            PlatformCredentialSheet(instance: inst, viewModel: viewModel)
        }
        .sheet(isPresented: $addingInstance) {
            addInstanceSheet
        }
    }

    private func instanceRow(_ inst: PlatformInstance) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(inst.platform.displayName)
                if let label = InstanceLabels.label(for: inst) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                } else if inst.instanceName != "default" {
                    Text(inst.instanceName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Button("Edit") { editingInstance = inst }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var addInstanceSheet: some View {
        VStack(spacing: 20) {
            Text("Add another \(platform.displayName)").font(.headline)
            TextField("Name this connection (e.g. my-blog)", text: $newInstanceLabel)
                .textFieldStyle(.roundedBorder).frame(width: 300)
            HStack {
                Button("Cancel") { addingInstance = false }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let label = newInstanceLabel.trimmingCharacters(in: .whitespaces)
                    guard !label.isEmpty else { return }
                    viewModel.addInstance(label: label, to: platform)
                    let inst = PlatformInstance(platform: platform, instanceName: label)
                    addingInstance = false
                    editingInstance = inst
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(newInstanceLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(30).frame(width: 380)
    }
}
```

Notes:
- `ForEach(instances, id: \.self)` — `instances` is `[String]`, so using `\.self` as the key path is correct. (Do **not** use a closure for `id:` — `ForEach.init(_:id:content:)` takes a `KeyPath`, not a closure.)
- `PlatformCredentialSheet` is presented as a **sheet** (not a push destination) to preserve its `@Environment(\.dismiss)` and `frame(width: 480)` presentation semantics, and to avoid breaking OAuth flows that call `dismiss()` on completion.

`AuthType.displayName` (add as extension in `Platform.swift` or a new file):
```swift
extension AuthType {
    var displayName: String {
        switch self {
        case .apiKey:     "API Key"
        case .oauthToken: "Token / OAuth"
        case .fileExport: "File Export"
        case .noAuth:     "No Authentication"
        }
    }
}
```

Note: `AuthType` has **four** cases in the current codebase (`.apiKey`, `.oauthToken`, `.fileExport`, `.noAuth`). The switch must cover all four or it will not compile.

### `PlatformsViewModel` additions

Add `hiddenPlatforms` property and hide/show/isHidden methods. Update `reload()` to populate it. Auto-show in `save` and `importFile`:

```swift
// New property (add alongside configuredInstances):
private(set) var hiddenPlatforms: Set<Platform> = []

// New methods:
func hidePlatform(_ platform: Platform) {
    PlatformVisibilityStore.hide(platform)
    hiddenPlatforms.insert(platform)
}

func showPlatform(_ platform: Platform) {
    PlatformVisibilityStore.show(platform)
    hiddenPlatforms.remove(platform)
}

func isHidden(_ platform: Platform) -> Bool {
    hiddenPlatforms.contains(platform)
}
```

In `reload()`, after populating `configuredInstances`, add:
```swift
hiddenPlatforms = Set(Platform.allCases.filter { PlatformVisibilityStore.isHidden($0) })
```

In `save(_:for:)`, after `reload()`:
```swift
PlatformVisibilityStore.show(instance.platform)
hiddenPlatforms.remove(instance.platform)
```

In `importFile(for:allowedExtensions:)`, after the `reload()` call at the end:
```swift
PlatformVisibilityStore.show(instance.platform)
hiddenPlatforms.remove(instance.platform)
```

### `PlatformVisibilityStore`

```swift
enum PlatformVisibilityStore {
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    static func isHidden(_ platform: Platform) -> Bool {
        defaults.bool(forKey: key(for: platform))
    }

    static func hide(_ platform: Platform) {
        defaults.set(true, forKey: key(for: platform))
    }

    static func show(_ platform: Platform) {
        defaults.removeObject(forKey: key(for: platform))
    }

    static func resetAll() {
        Platform.allCases.forEach { defaults.removeObject(forKey: key(for: $0)) }
    }

    private static func key(for platform: Platform) -> String {
        "hiddenPlatform_\(platform.rawValue)"
    }
}
```

`isHidden` returns `false` by default (when key absent) — correct: new platforms are visible.

---

## PlatformCredentialSheet: no changes

`PlatformCredentialSheet` is unchanged. It is now opened as a sheet from `PlatformDetailView` rather than from `PlatformsView`. Its existing `@Environment(\.dismiss)`, form fields, and footer (with "Remove Credentials" button) all remain identical.

---

## project.yml

`project.yml` uses directory-level source globs (`sources: - SocialBrain`). New files under `SocialBrain/Models/` and `SocialBrain/Views/Platforms/` are automatically picked up. Run `xcodegen generate` after adding new files.

---

## Testing plan

### Unit tests — `PlatformVisibilityStoreTests.swift`

Location: `SocialBrainTests/PlatformVisibilityStoreTests.swift`

All tests inject a temporary `UserDefaults(suiteName: UUID().uuidString)!` into `PlatformVisibilityStore.defaults` to avoid touching `UserDefaults.standard`.

Tests:
1. `testDefaultIsVisible` — freshly-created store returns `false` for `isHidden`
2. `testHidePlatform` — hide then check `isHidden == true`
3. `testShowPlatform` — hide then show, then `isHidden == false`
4. `testResetAll` — hide multiple, `resetAll()` removes all
5. `testHiddenPlatformAutoShownOnSave` — inject temporary defaults; hide a platform; call `viewModel.save(...)` with an in-memory `AppDatabase`; assert `viewModel.isHidden(...) == false`
6. `testHiddenPlatformAutoShownOnImport` — not easily unit-testable (requires NSOpenPanel); verify via the `PlatformVisibilityStore.show(...)` call path by calling `showPlatform` directly in a ViewModel test

### Unit tests — `PlatformSFSymbolTests.swift`

Location: `SocialBrainTests/PlatformSFSymbolTests.swift`

1. `testAllPlatformsHaveSFSymbol` — iterate `Platform.allCases` (all 14), assert `sfSymbol` is a non-empty string (exhaustiveness smoke test)

### Unit tests — `SidebarTests.swift` (existing, no changes needed)

The existing `SidebarTests` already checks `.feed` in `SidebarItem.allCases`. No changes.

### Compilation gate

```
xcodebuild build-for-testing -scheme SocialBrain -destination 'platform=macOS'
```

This catches exhaustiveness failures in `sfSymbol` and `AuthType.displayName` switches, and any unresolved `NavigationLink` type errors.

### Full test suite

```
xcodebuild test -scheme SocialBrain -only-testing SocialBrainTests -destination 'platform=macOS'
```

All existing unit tests must remain green.

---

## Implementation order

1. Add `PlatformVisibilityStore.swift` (new model)
2. Add `sfSymbol` and `AuthType.displayName` extension to `Platform.swift` / `AuthType` (no breaking changes; all 14 cases covered)
3. Add `hiddenPlatforms` property and `hidePlatform`, `showPlatform`, `isHidden` to `PlatformsViewModel`; update `reload()`; add auto-show calls in `save` and `importFile`
4. Create `PlatformCard.swift`
5. Create `PlatformDetailView.swift`
6. Rewrite `PlatformsView.swift` (NavigationStack + LazyVGrid; remove `addingInstanceFor`/`editingInstance`/`newInstanceLabel` state vars)
7. Run `xcodegen generate`
8. Compilation gate + full unit test suite

---

## Tricky boundaries and invariants

**ForEach identity for String arrays:** `ForEach(instances, id: \.self)` is correct for `[String]`. Do not use a closure `id: { ... }` — `ForEach.init(_:id:content:)` requires a `KeyPath`, not a closure. Using a closure compiles to `ForEach.init(_:content:)` without stable identity and will cause SwiftUI diffing bugs or a type error.

**AuthType.noAuth:** The current `AuthType` enum has four cases. Any `switch` over `AuthType` must include `.noAuth` (used by `.hackerNews`) or the compiler will reject it.

**Platform case count:** `Platform.allCases` has 14 cases in the current codebase: `.buttondown`, `.goatCounter`, `.vercel`, `.calendly`, `.amazon`, `.mastodon`, `.jetpack`, `.bluesky`, `.linkedin`, `.oreilly`, `.substack`, `.googleSearchConsole`, `.buffer`, `.hackerNews`. Any exhaustive switch over `Platform` must cover all 14.

**NavigationDestination scope:** `navigationDestination(for: Platform.self)` must be inside the `NavigationStack`. Using a plain `ScrollView` + `LazyVGrid` (not a `List`) is intentional — `NavigationLink(value:)` inside a `List` in a `NavigationSplitView` detail column uses sidebar-style selection rather than push navigation. The `ScrollView` + `LazyVGrid` path uses push navigation correctly on macOS 14+.

**Hidden + configured auto-show:** A user could theoretically hide a platform, then configure it via a path that bypasses `PlatformsViewModel.save` (e.g. directly via `KeychainStore`). In that edge case the platform stays hidden. Acceptable — the toolbar always exposes the "show hidden" affordance.

**`@Observable` reactivity for `hiddenPlatforms`:** Because `PlatformsViewModel` uses `@Observable`, the `hiddenPlatforms: Set<Platform>` property is automatically tracked. Views that read `viewModel.isHidden(platform)` (which reads `hiddenPlatforms`) will re-render when `hiddenPlatforms` changes. No explicit `objectWillChange.send()` is needed.

**Sheet vs push for PlatformCredentialSheet:** The credential sheet keeps its `@Environment(\.dismiss)` and `frame(width: 480)` presentation — these are correct for a sheet. Embedding it as a push destination would require converting it to a full-page view without sheet constraints, which would potentially break the OAuth flows that call `dismiss()` to close on success.
