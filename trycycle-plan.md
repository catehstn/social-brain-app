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

### PlatformDetailView replaces PlatformCredentialSheet

`PlatformCredentialSheet` is currently a modal `sheet`. In the redesigned flow, its content becomes a pushed `PlatformDetailView`. All existing form content (label field, platform fields, import section, OAuth section, footer with Save/Delete) moves into `PlatformDetailView`. The sheet is removed; no caller opens a sheet for the primary credential flow.

**Exception:** The "Add another instance" sub-flow still uses a small sheet because it's a transient name-entry step, not a full credential form. This sheet remains unchanged.

### Adaptive grid

Use `LazyVGrid` with `GridItem(.adaptive(minimum: 180, maximum: 240))` for the card grid. Cards are `PlatformCard` views, approximately 180×140pt.

Cards show:
- SF Symbol icon (large, accent-coloured, see icon map below)
- Platform display name
- Status indicator: configured instances count, or "Not set up" in secondary colour
- A "hidden" badge (eye.slash) if it ever needs to be shown in the "show hidden" list

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

**Show hidden affordance:** A toolbar button (eye icon) toggles a `@State var showingHidden: Bool` in `PlatformsView`. When true, the grid shows hidden platforms with a dimmed card and "Show" button overlaid. Hidden + configured platforms are always visible (they cannot be hidden while actively in use — or if they somehow get into that state, the auto-show rule above fires on next configure).

### PlatformsViewModel changes

`PlatformsViewModel` gains:
```swift
func hideplatform(_ platform: Platform)
func showPlatform(_ platform: Platform)
func isHidden(_ platform: Platform) -> Bool
```

These delegate to `PlatformVisibilityStore`. They are called from the view; no async work needed.

`reload()` is unchanged.

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

Add `var sfSymbol: String` computed property to `Platform`.

### Remove Credentials vs Remove Data

File-import platforms already use "Remove Data" in the detail sheet footer. This remains unchanged. API platforms use "Remove Credentials". No change to copy.

---

## Files to create

| File | Purpose |
|---|---|
| `SocialBrain/Models/PlatformVisibilityStore.swift` | UserDefaults-backed hidden state |
| `SocialBrain/Views/Platforms/PlatformCard.swift` | Card component for grid |
| `SocialBrain/Views/Platforms/PlatformDetailView.swift` | Pushed detail page (replaces sheet) |

## Files to modify

| File | Change |
|---|---|
| `SocialBrain/Models/Platform.swift` | Add `var sfSymbol: String` |
| `SocialBrain/Views/Platforms/PlatformsView.swift` | Replace list with NavigationStack + LazyVGrid; add show-hidden toggle toolbar button |
| `SocialBrain/Views/Platforms/PlatformsViewModel.swift` | Add hide/show/isHidden methods; auto-show on configure |
| `SocialBrain/Views/Platforms/PlatformCredentialSheet.swift` | Keep for "Add another instance" sub-flow only; remove primary credential entry (moved to PlatformDetailView) |

## Files to delete

None. `PlatformCredentialSheet` is retained for the add-another-instance sheet.

---

## Detailed component specs

### `PlatformsView`

```swift
struct PlatformsView: View {
    let database: AppDatabase
    @State private var viewModel: PlatformsViewModel
    @State private var showingHidden = false
    @State private var addingInstanceFor: Platform?
    @State private var newInstanceLabel: String = ""

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
                        Label(showingHidden ? "Hide dismissed" : "Show dismissed", systemImage: showingHidden ? "eye.slash.fill" : "eye.slash")
                    }
                    .opacity(hiddenPlatforms.isEmpty ? 0 : 1)  // only visible when there are hidden platforms
                }
            }
            .navigationDestination(for: Platform.self) { platform in
                PlatformDetailView(platform: platform, viewModel: viewModel)
            }
            .sheet(item: $addingInstanceFor) { platform in
                addInstanceSheet(for: platform)
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
- `NavigationLink(value: platform)` uses the type-safe destination pattern with `navigationDestination(for: Platform.self)`.
- The "add another instance" sheet is still presented from `PlatformDetailView` (the push page), not the grid. The `$addingInstanceFor` state in `PlatformsView` is removed since all instance management moves into `PlatformDetailView`. (See below.)

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

This view is the full credential-management page. It replaces the modal sheet for all primary credential entry.

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
                    // Not set up — show a Set Up button
                    Button("Set Up") {
                        editingInstance = PlatformInstance(platform: platform)
                    }
                    .buttonStyle(.bordered)
                } else {
                    ForEach(instances, id: { "\(platform.rawValue):\($0)" }) { instanceName in
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

Note: `PlatformDetailView` pushes a `PlatformCredentialSheet` as a **sheet** (not a push) because credential entry is a focused modal task. This is intentional — keeping sheet semantics for credential forms while using push navigation for platform overview.

`AuthType.displayName`:
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

### `PlatformsViewModel` additions

```swift
func hidePlatform(_ platform: Platform) {
    PlatformVisibilityStore.hide(platform)
}

func showPlatform(_ platform: Platform) {
    PlatformVisibilityStore.show(platform)
}

func isHidden(_ platform: Platform) -> Bool {
    PlatformVisibilityStore.isHidden(platform)
}
```

In `save(_:for:)`, after `reload()`:
```swift
// Auto-show when a platform receives credentials.
PlatformVisibilityStore.show(instance.platform)
```

In `importFile(for:allowedExtensions:)`, after `reload()`:
```swift
PlatformVisibilityStore.show(instance.platform)
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

## PlatformCredentialSheet: retained scope

`PlatformCredentialSheet` remains the sheet used inside `PlatformDetailView` for editing a specific `PlatformInstance`'s credentials. It is invoked as `sheet(item: $editingInstance)`.

No structural changes to `PlatformCredentialSheet`. It already has all the credential fields, label, OAuth buttons, import buttons, and footer with Save/Delete.

---

## project.yml

`project.yml` uses directory-level source globs (`sources: - SocialBrain`). New files under `SocialBrain/` and `SocialBrain/Views/Platforms/` and `SocialBrain/Models/` are automatically picked up. Run `xcodegen generate` after adding new files.

---

## Testing plan

### Unit tests — `PlatformVisibilityStoreTests.swift`

Location: `SocialBrainTests/PlatformVisibilityStoreTests.swift`

Tests:
1. `testDefaultIsVisible` — freshly-created store returns `false` for `isHidden`
2. `testHidePlatform` — hide then check `isHidden == true`
3. `testShowPlatform` — hide then show, then `isHidden == false`
4. `testShowAll` — hide multiple, `resetAll` removes all
5. `testHiddenPlatformAutoShownOnSave` — inject `PlatformVisibilityStore.defaults = testDefaults`, hide a platform, call `viewModel.save(...)`, assert `isHidden == false`
6. `testHiddenPlatformAutoShownOnImport` — same but via `viewModel.importFile(...)`

All tests inject a temporary `UserDefaults(suiteName: UUID().uuidString)!` to avoid touching `UserDefaults.standard`.

### Unit tests — `PlatformSFSymbolTests.swift`

1. `testAllPlatformsHaveSFSymbol` — iterate `Platform.allCases`, assert `sfSymbol` is a non-empty string (smoke test that the switch is exhaustive)

### Unit tests — `SidebarTests.swift` (existing, no changes needed)

The existing `SidebarTests` already checks that `.platforms` is in `SidebarItem.allCases`. No changes.

### Compilation gate

```
xcodebuild build-for-testing -scheme SocialBrain -destination 'platform=macOS'
```

This catches exhaustiveness failures in `sfSymbol` switch and any unresolved `NavigationLink` type errors.

### Full test suite

```
xcodebuild test -scheme SocialBrain -only-testing SocialBrainTests -destination 'platform=macOS'
```

All 201+ existing unit tests must remain green.

---

## Implementation order

1. Add `PlatformVisibilityStore.swift` (new model)
2. Add `sfSymbol` and `AuthType.displayName` to `Platform.swift` / `AuthType` (no breaking changes)
3. Add `hidePlatform`, `showPlatform`, `isHidden` to `PlatformsViewModel`; add auto-show calls in `save` and `importFile`
4. Create `PlatformCard.swift`
5. Create `PlatformDetailView.swift`
6. Rewrite `PlatformsView.swift` (NavigationStack + LazyVGrid)
7. Run `xcodegen generate`
8. Compilation gate + full unit test suite

---

## Tricky boundaries and invariants

**Hidden + configured auto-show:** A user could theoretically hide a platform, then use the CLI or another path to configure it without going through `PlatformsViewModel.save`. In that edge case the platform stays hidden even though it's configured. Acceptable — the user deliberately hid it, and the grid always shows the "Show all" affordance.

**NavigationDestination scope:** `navigationDestination(for: Platform.self)` must be inside the `NavigationStack`, not in a `List`. If the `LazyVGrid` is inside a `List`, the NavigationLink won't push — it must be inside a plain `ScrollView` wrapped by `NavigationStack`. The plan uses `ScrollView` + `LazyVGrid`, not `List`, for this reason.

**macOS NavigationLink with value:** On macOS 14+, `NavigationLink(value:)` inside a `NavigationStack` in the detail column of a `NavigationSplitView` works correctly and produces a push (breadcrumb navigation). This is confirmed macOS 14 SwiftUI behaviour.

**Sheet vs push for PlatformCredentialSheet:** The credential sheet keeps its `@Environment(\.dismiss)` and `frame(width: 480)` presentation — these are correct for a sheet. Embedding it as a push destination would require converting it to a full-page view without sheet constraints, which would require more changes and potentially break the OAuth flows that call `dismiss()` to close the sheet on success. Keeping it as a sheet presented from `PlatformDetailView` is the correct minimal-change approach.

**ForEach identity:** The existing `ForEach(instances, id: { "\(platform.rawValue):\($0)" })` pattern (introduced in the multi-instance PR to fix SwiftUI identity collisions) is preserved in `PlatformDetailView`.

**`@Observable` consistency:** `PlatformsViewModel` already uses `@Observable`. The new methods (`hidePlatform`, `showPlatform`, `isHidden`) are plain synchronous methods — no `@Published` needed since `PlatformVisibilityStore` is not observed. The grid re-renders reactively because `PlatformsView` re-renders on `viewModel.configuredInstances` changes. Hide/show triggers a view reload via `@State private var showingHidden` — an explicit toggle is needed since `PlatformVisibilityStore` is not observable. The hide button calls `viewModel.hidePlatform(platform)` and then relies on the `NavigationStack` popping back to the grid; the grid is then correctly repopulated from `PlatformVisibilityStore.isHidden`.

**Reactive hidden state:** `PlatformVisibilityStore` is not `@Observable`. To make `PlatformsView` re-render after hiding/showing, `PlatformsViewModel` should maintain a `@Published`-equivalent `hiddenPlatforms: Set<Platform>` property (since `@Observable` tracks property access). Add:
```swift
private(set) var hiddenPlatforms: Set<Platform> = []
```
and refresh it in `reloadHidden()` called from `hidePlatform`, `showPlatform`, and `reload`. Views read `viewModel.hiddenPlatforms` to compute visible vs hidden. This is clean because `@Observable` will correctly track reads of `hiddenPlatforms`.

Updated `PlatformsViewModel`:
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

func reload() {
    // existing instance reload...
    hiddenPlatforms = Set(Platform.allCases.filter { PlatformVisibilityStore.isHidden($0) })
}
```

`PlatformsView` then uses `viewModel.hiddenPlatforms.contains(platform)` to filter; re-renders automatically when `hiddenPlatforms` changes.
