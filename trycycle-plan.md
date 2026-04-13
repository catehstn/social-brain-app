# Multiple Platform Instances Implementation Plan (Issue #29)

> **For agentic workers:** REQUIRED SUB-SKILL: Use trycycle-executing to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support multiple named instances per platform so a user with two newsletters, two websites, or two social accounts can collect and display data for all of them.

**Architecture summary:**
- New `PlatformInstance` type identifies one configured account on one platform
- New `InstanceRegistry` (UserDefaults-backed) tracks which instances exist per platform
- `KeychainStore` keys credentials by `"\(platform.rawValue):\(instanceName)"` instead of just `platform.rawValue`
- `PlatformData` and `PlatformSnapshot` gain an `instanceName: String` field
- A v2 database migration adds `instance_name` column to `platformSnapshot`
- All database queries are updated to scope by `(platform, instanceName)`
- `CollectorRegistry` and `CollectionEngine` iterate `PlatformInstance` instead of `Platform`
- The Platforms UI shows per-instance rows with an "Add another X" button

**Tech Stack:** Swift 6, SwiftUI/macOS 14+, GRDB.swift 7.x, Swift Testing framework.

---

## Pre-flight gate

Before touching anything, confirm the baseline is green:

```bash
xcodebuild test \
  -scheme SocialBrain \
  -destination 'platform=macOS' \
  -only-testing:SocialBrainTests \
  2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`

---

## Task 1: `PlatformInstance` model

**File:** `SocialBrain/Models/PlatformInstance.swift` (new)

```swift
import Foundation

/// Identifies one configured account on one platform.
///
/// Every platform always has at least one instance named `"default"`.
/// Additional instances have a user-supplied label (e.g. `"my-blog"`, `"client-site"`).
public struct PlatformInstance: Hashable, Sendable, Identifiable, Codable {
    public let platform: Platform
    /// `"default"` for the first instance; user-defined for extras.
    public let instanceName: String

    public var id: String { "\(platform.rawValue):\(instanceName)" }

    /// Shows just the platform name for the default instance; includes the
    /// label for additional instances (e.g. "GoatCounter — my-blog").
    public var displayName: String {
        instanceName == "default"
            ? platform.displayName
            : "\(platform.displayName) — \(instanceName)"
    }

    public init(platform: Platform, instanceName: String = "default") {
        self.platform = platform
        self.instanceName = instanceName
    }
}
```

- [ ] Create `SocialBrain/Models/PlatformInstance.swift` with the struct above
- [ ] Run `xcodegen generate` to include the new file in the project
- [ ] Build: `xcodebuild build-for-testing -scheme SocialBrain -destination 'platform=macOS'`

---

## Task 2: `InstanceRegistry`

**File:** `SocialBrain/Models/InstanceRegistry.swift` (new)

Tracks which instance names exist per platform in `UserDefaults`.

Key format: `"instanceNames_<platform.rawValue>"` → `[String]` (JSON-encoded array).

```swift
enum InstanceRegistry {
    // Exposed for test injection; defaults to UserDefaults.standard
    static var defaults: UserDefaults = .standard

    static func instances(for platform: Platform) -> [String] {
        // Returns stored list; auto-seeds ["default"] on first access.
    }

    static func add(instanceName: String, to platform: Platform) {
        // Appends if not already present
    }

    static func remove(instanceName: String, from platform: Platform) {
        // Does nothing if it would leave the list empty (prevents removing "default" if it's the only one)
    }

    static func allInstances() -> [PlatformInstance] {
        // Returns PlatformInstance for every (platform, instanceName) pair
    }

    /// Removes all stored instance lists — for test teardown only.
    static func resetAll() {
        for platform in Platform.allCases {
            defaults.removeObject(forKey: key(for: platform))
        }
    }

    private static func key(for platform: Platform) -> String {
        "instanceNames_\(platform.rawValue)"
    }
}
```

- [ ] Create `SocialBrain/Models/InstanceRegistry.swift`
- [ ] `defaults` is a `static var` so tests can inject a custom suite via `UserDefaults(suiteName:)`
- [ ] `remove` guards against emptying the list (always leaves at least one instance)
- [ ] Run `xcodegen generate`; build succeeds

---

## Task 3: `KeychainStore` — instance-keyed overloads

**File:** `SocialBrain/Keychain/KeychainStore.swift` (modify)

Add overloads accepting `PlatformInstance`.  The account key changes from
`platform.rawValue` to `"\(platform.rawValue):\(instanceName)"`.

Add these methods:

```swift
// New instance-keyed API
static func save(_ credentials: Credentials, for instance: PlatformInstance) throws
static func load(for instance: PlatformInstance) throws -> Credentials?
static func delete(for instance: PlatformInstance) throws
static func hasCredentials(for instance: PlatformInstance) -> Bool
```

Keep the existing `Platform`-only API intact; they simply delegate to the `"default"` instance:

```swift
static func save(_ credentials: Credentials, for platform: Platform) throws {
    try save(credentials, for: PlatformInstance(platform: platform))
}
// same for load, delete, hasCredentials
```

The internal `account` string for the new overloads is `instance.id` (`"platform_raw:instanceName"`).

- [ ] Modify `KeychainStore.swift`
- [ ] Implement new overloads
- [ ] Ensure existing `Platform`-only overloads delegate to new overloads (no code duplication)
- [ ] Build succeeds

---

## Task 4: `PlatformData` — add `instanceName`

**File:** `SocialBrain/Models/PlatformData.swift` (modify)

Add `instanceName: String` with a default of `"default"`:

```swift
public struct PlatformData: Sendable, Codable {
    public let platform: Platform
    public let instanceName: String   // NEW
    public let collectedAt: Date
    public let metrics: [String: MetricValue]

    public init(
        platform: Platform,
        instanceName: String = "default",   // NEW parameter
        collectedAt: Date = .now,
        metrics: [String: MetricValue]
    ) { ... }
}
```

- [ ] Modify `PlatformData.swift`
- [ ] All existing callers pass no `instanceName` argument and get `"default"` — no call site changes required
- [ ] Build succeeds

---

## Task 5: `PlatformSnapshot` — add `instanceName`

**File:** `SocialBrain/Database/PlatformSnapshot.swift` (modify)

```swift
struct PlatformSnapshot: ... {
    var id: Int64?
    var runID: Int64
    var platform: String
    var instanceName: String   // NEW
    var collectedAt: Date
    var metricsJSON: Data

    // ...

    var instanceEnum: PlatformInstance? {   // NEW computed
        guard let p = platformEnum else { return nil }
        return PlatformInstance(platform: p, instanceName: instanceName)
    }

    init(runID: Int64, data: PlatformData) throws {
        self.instanceName = data.instanceName   // NEW line
        // existing assignments...
    }
}
```

- [ ] Modify `PlatformSnapshot.swift`
- [ ] Add `instanceName: String` stored property
- [ ] Add `instanceEnum` computed property
- [ ] Update `init(runID:data:)` to copy `data.instanceName`
- [ ] Build succeeds

---

## Task 6: Database migration `v2_instance_names`

**File:** `SocialBrain/Database/AppDatabase.swift` (modify)

Register a new migration after `v1_initial`:

```swift
migrator.registerMigration("v2_instance_names") { db in
    try db.alter(table: "platformSnapshot") { t in
        t.add(column: "instanceName", .text).notNull().defaults(to: "default")
    }
    // Drop the old two-column index and re-create it with three columns
    try db.execute(sql: "DROP INDEX IF EXISTS \"index_platformSnapshot_on_platform_collectedAt\"")
    try db.create(
        indexOn: "platformSnapshot",
        columns: ["platform", "instanceName", "collectedAt"]
    )
}
```

Note: `eraseDatabaseOnSchemaChange = true` is guarded by `#if DEBUG` and only affects
the migration runner's behaviour when the schema hash changes — it will drop and
recreate the database in debug builds.  For unit tests this is fine because
`makeInMemory()` always starts fresh.  In production (non-DEBUG) the migration runs
incrementally and no data is lost.

- [ ] Register `"v2_instance_names"` migration in `AppDatabase.migrator`
- [ ] Build succeeds
- [ ] Run unit test suite — existing migration tests still pass

---

## Task 7: `AppDatabase` query updates

**File:** `SocialBrain/Database/AppDatabase.swift` (modify)

Update all query helpers:

```swift
// Updated: add instanceName parameter
func latestSnapshot(
    for platform: Platform,
    instanceName: String = "default"
) throws -> PlatformSnapshot?

func snapshots(
    for platform: Platform,
    instanceName: String = "default",
    from: Date,
    to: Date = .now
) throws -> [PlatformSnapshot]

func twoLatestSnapshots(
    for platform: Platform,
    instanceName: String = "default"
) throws -> [PlatformSnapshot]

// Return type changed from [Platform: PlatformSnapshot]
func latestSnapshots() throws -> [PlatformInstance: PlatformSnapshot]
func previousSnapshots() throws -> [PlatformInstance: PlatformSnapshot]

// New: delete all snapshots for a specific instance
func deleteSnapshots(for instance: PlatformInstance) throws
```

SQL changes:
- Queries now filter on both `platform` and `instanceName` columns
- `latestSnapshots()` groups by `(platform, instanceName)` and returns `PlatformInstance` keys
- `previousSnapshots()` iterates `(platform, instanceName)` pairs

Implementation notes for `latestSnapshots()`:

```swift
func latestSnapshots() throws -> [PlatformInstance: PlatformSnapshot] {
    try dbWriter.read { db in
        let rows = try PlatformSnapshot
            .filter(sql: """
                (platform, instanceName, collectedAt) IN (
                    SELECT platform, instanceName, MAX(collectedAt)
                    FROM platformSnapshot
                    GROUP BY platform, instanceName
                )
                """)
            .fetchAll(db)
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let p = row.instanceEnum else { return nil }
            return (p, row)
        })
    }
}
```

- [ ] Update `latestSnapshot(for:)` to filter on `instanceName`
- [ ] Update `snapshots(for:from:to:)` to filter on `instanceName`
- [ ] Update `twoLatestSnapshots(for:)` to filter on `instanceName`
- [ ] Update `latestSnapshots()` — new return type and GROUP BY
- [ ] Update `previousSnapshots()` — new return type
- [ ] Add `deleteSnapshots(for instance:)`
- [ ] Build; fix any call-site compile errors from the return type changes

---

## Task 8: `Collector` protocol + all collectors

**File:** `SocialBrain/Collectors/Collector.swift` (modify)

Add `instanceName` to the protocol:

```swift
protocol Collector: Sendable {
    var platform: Platform { get }
    var instanceName: String { get }   // NEW
    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData
}

// Default implementation so existing collectors need no changes:
extension Collector {
    var instanceName: String { "default" }
}
```

**All 10 collector files** — no changes required because the default extension provides
`instanceName = "default"`.  When a collector is instantiated for a specific instance
it will be given the `instanceName` as a stored property.  Add a stored property to
each collector:

```swift
struct ButtondownCollector: Collector {
    var instanceName: String = "default"   // NEW stored property
    let platform: Platform = .buttondown
    // ...
    func collect(since:credentials:) async throws -> PlatformData {
        // Return data tagged with instanceName
        return PlatformData(
            platform: .buttondown,
            instanceName: instanceName,   // NEW
            collectedAt: .now,
            metrics: [...]
        )
    }
}
```

Apply this same change to all 10 non-file-export collectors.

- [ ] Modify `Collector.swift` to add `instanceName` with default extension
- [ ] Add `var instanceName: String = "default"` to each of the 10 collector structs
- [ ] Update each collector's `collect(...)` to pass `instanceName` to `PlatformData(...)` init
- [ ] Build succeeds

---

## Task 9: `CollectorRegistry` + `CollectionEngine`

**File:** `SocialBrain/Collectors/CollectionEngine.swift` (modify)

### `CollectorRegistry`

```swift
enum CollectorRegistry {
    /// Returns all collectors for all instances with stored credentials.
    static func configured(
        instances: (Platform) -> [String] = InstanceRegistry.instances,
        hasCredentials: (PlatformInstance) -> Bool = KeychainStore.hasCredentials
    ) -> [any Collector] {
        Platform.allCases.flatMap { platform in
            instances(platform).compactMap { instanceName in
                let instance = PlatformInstance(platform: platform, instanceName: instanceName)
                guard hasCredentials(instance) else { return nil }
                return collector(for: instance)
            }
        }
    }

    /// Returns the collector for a specific instance, or nil for file-export platforms.
    static func collector(for instance: PlatformInstance) -> (any Collector)? {
        switch instance.platform {
        case .buttondown:
            var c = ButtondownCollector(); c.instanceName = instance.instanceName; return c
        case .goatCounter:
            var c = GoatCounterCollector(); c.instanceName = instance.instanceName; return c
        // ... same pattern for all API/token platforms
        case .amazon, .linkedin, .oreilly, .substack:
            return nil  // file-export platforms
        }
    }
}
```

### `CollectionEngine`

Change the `credentials` closure to accept `PlatformInstance`:

```swift
func run(
    collectors: [any Collector],
    credentials: @escaping @Sendable (PlatformInstance) throws -> Credentials?,
    since: Date? = nil,
    progress: (@Sendable (CollectionResult) async -> Void)? = nil
) async throws -> CollectionSummary
```

Inside `run`, build the instance for each collector and use it to fetch credentials:

```swift
group.addTask {
    let instance = PlatformInstance(platform: collector.platform, instanceName: collector.instanceName)
    do {
        guard let creds = try credentials(instance) else { ... }
        let data = try await collector.collect(since: since, credentials: creds)
        return .success(data)
    } catch {
        return .failure(platform: collector.platform, instanceName: collector.instanceName, error: error)
    }
}
```

### `CollectionResult` update

```swift
enum CollectionResult: Sendable {
    case success(PlatformData)
    case failure(platform: Platform, instanceName: String, error: Error)

    var instance: PlatformInstance {
        switch self {
        case .success(let d):
            return PlatformInstance(platform: d.platform, instanceName: d.instanceName)
        case .failure(let p, let i, _):
            return PlatformInstance(platform: p, instanceName: i)
        }
    }
    // Keep .platform property for backwards compatibility
    var platform: Platform { instance.platform }
}
```

- [ ] Update `CollectorRegistry.configured()` to iterate `InstanceRegistry.allInstances()`
- [ ] Update `CollectorRegistry.collector(for:)` to accept `PlatformInstance`
- [ ] Update `CollectionResult.failure` to carry `instanceName`
- [ ] Add `instance` computed property to `CollectionResult`
- [ ] Update `CollectionEngine.run(credentials:)` closure type
- [ ] Build; fix any call-site errors in `RunViewModel`

---

## Task 10: `RunViewModel` — update credentials closure

**File:** `SocialBrain/Views/Run/RunViewModel.swift` (modify)

Change the credentials closure from `(Platform) -> Credentials?` to
`(PlatformInstance) -> Credentials?`:

```swift
let summary = try await engine.run(
    collectors: CollectorRegistry.configured(),
    credentials: { instance in
        try KeychainStore.load(for: instance)
    },
    since: since,
    progress: { result in ... }
)
```

- [ ] Update `RunViewModel` credentials closure
- [ ] Build succeeds

---

## Task 11: `PromptAssembler`

**File:** `SocialBrain/Prompt/PromptAssembler.swift` (modify)

Change `Input.snapshots` from `[Platform: PlatformSnapshot]` to
`[PlatformInstance: PlatformSnapshot]`:

```swift
struct Input {
    let periodLabel: String
    let reportDate: Date
    let snapshots: [PlatformInstance: PlatformSnapshot]   // changed
    let goal: AnalyticsGoal
    let goalCustomText: String
}
```

Update section header logic: when a platform has exactly one instance, use the
platform `displayName`; when it has two or more, use the instance `displayName`
(which includes the label):

```swift
// Group snapshots by platform
let byPlatform = Dictionary(grouping: snapshots.keys, by: \.platform)

for platform in sortedPlatforms {
    let instances = byPlatform[platform] ?? []
    let multiInstance = instances.count > 1
    for instance in instances.sorted(by: { $0.instanceName < $1.instanceName }) {
        guard let snap = snapshots[instance] else { continue }
        let header = multiInstance ? instance.displayName : platform.displayName
        sections.append(format(snap, header: header))
    }
}
```

- [ ] Update `Input` struct
- [ ] Update section header logic
- [ ] Update `RunViewModel` to pass `[PlatformInstance: PlatformSnapshot]` to `PromptAssembler.Input`
- [ ] Build succeeds

---

## Task 12: Feed / Spike / HighReach model updates

**Files:**
- `SocialBrain/Models/FeedCardBuilder.swift` (modify)
- `SocialBrain/Models/SpikeDetector.swift` (modify)
- `SocialBrain/Models/HighReachDetector.swift` (modify)
- `SocialBrain/Models/FeedCard.swift` (modify)
- `SocialBrain/Views/Feed/FeedViewModel.swift` (modify)

The primary change: all functions that accept `[Platform: PlatformSnapshot]` now
accept `[PlatformInstance: PlatformSnapshot]`.  `FeedCard` gains `instanceName`
and its `displayTitle` shows the label when `instanceName != "default"`.

- [ ] Update `FeedCardBuilder.build(snapshots:now:)` parameter type
- [ ] Update `SpikeDetector` input type
- [ ] Update `HighReachDetector` input type
- [ ] Update `FeedCard` — add `instanceName: String`, update `displayTitle`
- [ ] Update `FeedViewModel.load()` to call `database.latestSnapshots()` (which now returns `[PlatformInstance: PlatformSnapshot]`) and pass it through
- [ ] Build succeeds

---

## Task 13: Dashboard updates

**File:** `SocialBrain/Views/Dashboard/DashboardViewModel.swift` (modify)

`DashboardViewModel` currently uses `Platform` as the picker and chart key.  With
multiple instances the picker must show `PlatformInstance` values.  The `selectedPlatform`
property becomes `selectedInstance: PlatformInstance`.

Changes:
- Add `allInstances: [PlatformInstance]` computed from `latestSnapshots()` keys
- Replace `selectedPlatform: Platform` with `selectedInstance: PlatformInstance?`
- Pass `instanceName` when calling `database.snapshots(for:instanceName:from:to:)`
- Use `instance.displayName` in chart titles

`DashboardView` picker and chart labels update accordingly.

- [ ] Update `DashboardViewModel` to use `PlatformInstance` keys
- [ ] Update `DashboardView` picker to use `allInstances`
- [ ] Build succeeds

---

## Task 14: `PlatformsViewModel` — multi-instance management

**File:** `SocialBrain/Views/Platforms/PlatformsViewModel.swift` (modify)

Replace `configured: Set<Platform>` with `configuredInstances: [Platform: [String]]`
(instance names grouped by platform):

```swift
@Observable
@MainActor
final class PlatformsViewModel {
    private(set) var configuredInstances: [Platform: [String]] = [:]

    func reload() {
        configuredInstances = [:]
        for platform in Platform.allCases {
            let names = InstanceRegistry.instances(for: platform)
            let configured = names.filter { name in
                KeychainStore.hasCredentials(for: PlatformInstance(platform: platform, instanceName: name))
            }
            if !configured.isEmpty {
                configuredInstances[platform] = configured
            }
        }
    }

    func loadValues(for instance: PlatformInstance) -> [String: String] { ... }
    func save(_ values: [String: String], for instance: PlatformInstance) throws { ... }
    func delete(for instance: PlatformInstance) async throws {
        try KeychainStore.delete(for: instance)
        try await database.deleteSnapshots(for: instance)
        InstanceRegistry.remove(instanceName: instance.instanceName, from: instance.platform)
        reload()
    }
    func importFile(for instance: PlatformInstance, allowedExtensions: [String]) async throws { ... }

    func addInstance(label: String, to platform: Platform) {
        InstanceRegistry.add(instanceName: label, to: platform)
    }
}
```

- [ ] Update `PlatformsViewModel` — replace `configured: Set<Platform>` with `configuredInstances: [Platform: [String]]`
- [ ] Add `addInstance(label:to:)` and update `delete(for:)` to remove DB snapshots
- [ ] Update `reload()`, `save`, `loadValues`, `importFile` to use `PlatformInstance`
- [ ] Build succeeds

---

## Task 15: `PlatformsView` + `PlatformCredentialSheet` UI

**File:** `SocialBrain/Views/Platforms/PlatformsView.swift` (modify)

Replace single row per platform with a grouped disclosure or list section per platform.
Show existing instances with Edit/Delete buttons; add "+ Add another [platform]" button.

```swift
ForEach(sectionPlatforms, id: \.self) { platform in
    let instances = viewModel.configuredInstances[platform] ?? []
    Section(platform.displayName) {
        if instances.isEmpty {
            Button("Set Up") { ... }
        } else {
            ForEach(instances, id: \.self) { instanceName in
                let inst = PlatformInstance(platform: platform, instanceName: instanceName)
                instanceRow(inst)
            }
            Button("+ Add another \(platform.displayName)") {
                addingInstanceFor = platform
            }
        }
    }
}
```

Add state: `@State private var addingInstanceFor: Platform?`
Add sheet for adding new instances with a "Name this connection" text field.

**File:** `SocialBrain/Views/Platforms/PlatformCredentialSheet.swift` (modify)

Add `instanceName: String` parameter (non-optional; defaults to `"default"`).
When the sheet is invoked from the "Add another" flow, a text field "Name this
connection" pre-populates with the user-entered label.  On save, register the
instance in `InstanceRegistry` then save to Keychain.

- [ ] Update `PlatformsView` — grouped sections with instance rows
- [ ] Update `PlatformCredentialSheet` — accept `PlatformInstance` parameter
- [ ] Wire "Add another" flow
- [ ] Build succeeds

---

## Task 16: `xcodegen generate` + final build + run tests

```bash
cd /Users/cate/git/social-brain-app/.worktrees/multi-instance-platforms
xcodegen generate
xcodebuild build-for-testing -scheme SocialBrain -destination 'platform=macOS'
xcodebuild test \
  -scheme SocialBrain \
  -destination 'platform=macOS' \
  -only-testing:SocialBrainTests \
  2>&1 | tail -20
```

- [ ] All new test files included in project
- [ ] Build succeeds (no errors, no warnings that weren't pre-existing)
- [ ] All tests pass

---

## Task 17: Write new tests

### `SocialBrainTests/PlatformInstanceTests.swift` (new)

```swift
@Suite("PlatformInstance Tests")
struct PlatformInstanceTests {
    @Test("id is platform:instanceName")
    func idFormat() {
        let inst = PlatformInstance(platform: .buttondown, instanceName: "newsletter-1")
        #expect(inst.id == "buttondown:newsletter-1")
    }

    @Test("displayName omits label for default instance")
    func displayNameDefault() {
        let inst = PlatformInstance(platform: .mastodon)
        #expect(inst.displayName == "Mastodon")
    }

    @Test("displayName includes label for non-default instance")
    func displayNameNonDefault() {
        let inst = PlatformInstance(platform: .goatCounter, instanceName: "my-blog")
        #expect(inst.displayName == "GoatCounter — my-blog")
    }

    @Test("Two instances with same platform+name are equal")
    func hashableEquality() {
        let a = PlatformInstance(platform: .bluesky, instanceName: "work")
        let b = PlatformInstance(platform: .bluesky, instanceName: "work")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Two instances with different names are not equal")
    func hashableInequality() {
        let a = PlatformInstance(platform: .bluesky, instanceName: "work")
        let b = PlatformInstance(platform: .bluesky, instanceName: "personal")
        #expect(a != b)
    }
}
```

### `SocialBrainTests/InstanceRegistryTests.swift` (new)

Uses a test-specific `UserDefaults` suite to avoid polluting real defaults:

```swift
@Suite("InstanceRegistry Tests")
struct InstanceRegistryTests {
    private let suiteName = "com.test.InstanceRegistryTests"

    init() {
        // Inject test defaults and clear them
        InstanceRegistry.defaults = UserDefaults(suiteName: suiteName)!
        InstanceRegistry.resetAll()
    }

    @Test("Fresh platform auto-seeds default instance")
    func autoSeeds() {
        let names = InstanceRegistry.instances(for: .buttondown)
        #expect(names == ["default"])
    }

    @Test("Adding an instance appends to the list")
    func addInstance() {
        InstanceRegistry.add(instanceName: "newsletter-2", to: .buttondown)
        let names = InstanceRegistry.instances(for: .buttondown)
        #expect(names.contains("newsletter-2"))
        #expect(names.count == 2)
    }

    @Test("Removing an instance removes it")
    func removeInstance() {
        InstanceRegistry.add(instanceName: "extra", to: .mastodon)
        InstanceRegistry.remove(instanceName: "extra", from: .mastodon)
        let names = InstanceRegistry.instances(for: .mastodon)
        #expect(!names.contains("extra"))
    }

    @Test("Cannot remove the last instance")
    func cannotRemoveLast() {
        InstanceRegistry.remove(instanceName: "default", from: .bluesky)
        let names = InstanceRegistry.instances(for: .bluesky)
        #expect(names == ["default"])  // still present
    }

    @Test("allInstances returns one entry per configured (platform, name) pair")
    func allInstances() {
        InstanceRegistry.add(instanceName: "second", to: .buttondown)
        let all = InstanceRegistry.allInstances()
        // buttondown should have 2 entries; every other platform should have 1
        let buttondownInstances = all.filter { $0.platform == .buttondown }
        #expect(buttondownInstances.count == 2)
    }

    @Test("Registry survives UserDefaults round-trip")
    func roundTrip() {
        InstanceRegistry.add(instanceName: "persisted", to: .vercel)
        // Simulate restart by re-reading from the same defaults
        let names = InstanceRegistry.instances(for: .vercel)
        #expect(names.contains("persisted"))
    }
}
```

### `SocialBrainTests/MultiInstanceKeychainTests.swift` (new)

```swift
@Suite("Multi-Instance Keychain Tests")
struct MultiInstanceKeychainTests {
    private let inst1 = PlatformInstance(platform: .buttondown, instanceName: "newsletter-a")
    private let inst2 = PlatformInstance(platform: .buttondown, instanceName: "newsletter-b")

    // Clean up test keys before and after
    init() throws {
        try? KeychainStore.delete(for: inst1)
        try? KeychainStore.delete(for: inst2)
    }

    @Test("Two instances of same platform stored independently")
    func twoInstances() throws {
        try KeychainStore.save(Credentials(["api_key": "key-a"]), for: inst1)
        try KeychainStore.save(Credentials(["api_key": "key-b"]), for: inst2)
        let creds1 = try KeychainStore.load(for: inst1)
        let creds2 = try KeychainStore.load(for: inst2)
        #expect(creds1?.apiKey == "key-a")
        #expect(creds2?.apiKey == "key-b")
    }

    @Test("hasCredentials returns false before saving")
    func missingCredentials() {
        #expect(KeychainStore.hasCredentials(for: inst1) == false)
    }

    @Test("Platform-only API delegates to default instance")
    func platformAPIDelegate() throws {
        let defaultInst = PlatformInstance(platform: .mastodon)
        try? KeychainStore.delete(for: defaultInst)
        try KeychainStore.save(Credentials(["access_token": "tok"]), for: .mastodon)
        let loaded = try KeychainStore.load(for: defaultInst)
        #expect(loaded?.accessToken == "tok")
    }

    @Test("Deleting one instance leaves the other intact")
    func deleteOneInstance() throws {
        try KeychainStore.save(Credentials(["api_key": "a"]), for: inst1)
        try KeychainStore.save(Credentials(["api_key": "b"]), for: inst2)
        try KeychainStore.delete(for: inst1)
        #expect(KeychainStore.hasCredentials(for: inst1) == false)
        #expect(KeychainStore.hasCredentials(for: inst2) == true)
    }
}
```

### `SocialBrainTests/MultiInstanceDatabaseTests.swift` (new)

```swift
@Suite("Multi-Instance Database Tests")
struct MultiInstanceDatabaseTests {

    @Test("v2 migration adds instanceName column with default value")
    func migrationAddsColumn() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbWriter.read { conn in
            let columns = try Row.fetchAll(conn, sql: "PRAGMA table_info(platformSnapshot)")
            let names = columns.map { $0["name"] as String }
            #expect(names.contains("instanceName"))
        }
    }

    @Test("latestSnapshot scopes to instanceName")
    func latestSnapshotScoped() async throws {
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), completedAt: nil, platformCount: 2, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let dataA = PlatformData(platform: .buttondown, instanceName: "newsletter-a", collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), metrics: ["subscriber_count": .int(100)])
        let dataB = PlatformData(platform: .buttondown, instanceName: "newsletter-b", collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), metrics: ["subscriber_count": .int(200)])
        var snapA = try PlatformSnapshot(runID: runID, data: dataA)
        var snapB = try PlatformSnapshot(runID: runID, data: dataB)
        try await db.saveSnapshot(&snapA)
        try await db.saveSnapshot(&snapB)

        let latest = try await db.latestSnapshot(for: .buttondown, instanceName: "newsletter-a")
        let metrics = try latest?.decodedMetrics()
        #expect(metrics?["subscriber_count"] == .int(100))
    }

    @Test("latestSnapshots returns PlatformInstance keys")
    func latestSnapshotsKeys() async throws {
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), completedAt: nil, platformCount: 2, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let dataA = PlatformData(platform: .mastodon, instanceName: "personal", collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), metrics: [:])
        let dataB = PlatformData(platform: .mastodon, instanceName: "work", collectedAt: Date(timeIntervalSinceReferenceDate: 700_010_000), metrics: [:])
        var sA = try PlatformSnapshot(runID: runID, data: dataA)
        var sB = try PlatformSnapshot(runID: runID, data: dataB)
        try await db.saveSnapshot(&sA)
        try await db.saveSnapshot(&sB)

        let latest = try await db.latestSnapshots()
        let instPersonal = PlatformInstance(platform: .mastodon, instanceName: "personal")
        let instWork = PlatformInstance(platform: .mastodon, instanceName: "work")
        #expect(latest[instPersonal] != nil)
        #expect(latest[instWork] != nil)
        #expect(latest.count == 2)
    }

    @Test("deleteSnapshots removes only the target instance")
    func deleteSnapshotsScoped() async throws {
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), completedAt: nil, platformCount: 2, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let dataA = PlatformData(platform: .goatCounter, instanceName: "site-a", collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), metrics: [:])
        let dataB = PlatformData(platform: .goatCounter, instanceName: "site-b", collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), metrics: [:])
        var sA = try PlatformSnapshot(runID: runID, data: dataA)
        var sB = try PlatformSnapshot(runID: runID, data: dataB)
        try await db.saveSnapshot(&sA)
        try await db.saveSnapshot(&sB)

        try await db.deleteSnapshots(for: PlatformInstance(platform: .goatCounter, instanceName: "site-a"))

        let remaining = try await db.latestSnapshots()
        #expect(remaining[PlatformInstance(platform: .goatCounter, instanceName: "site-a")] == nil)
        #expect(remaining[PlatformInstance(platform: .goatCounter, instanceName: "site-b")] != nil)
    }

    @Test("Two instances of same platform produce two distinct dictionary entries")
    func twoInstancesDistinct() async throws {
        let db = try AppDatabase.makeInMemory()
        var run = CollectionRun(id: nil, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), completedAt: nil, platformCount: 2, errorCount: 0)
        try await db.saveRun(&run)
        let runID = try #require(run.id)

        let d1 = PlatformData(platform: .buttondown, instanceName: "nl-1", collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), metrics: ["subscriber_count": .int(10)])
        let d2 = PlatformData(platform: .buttondown, instanceName: "nl-2", collectedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), metrics: ["subscriber_count": .int(20)])
        var s1 = try PlatformSnapshot(runID: runID, data: d1)
        var s2 = try PlatformSnapshot(runID: runID, data: d2)
        try await db.saveSnapshot(&s1)
        try await db.saveSnapshot(&s2)

        let latest = try await db.latestSnapshots()
        let inst1 = PlatformInstance(platform: .buttondown, instanceName: "nl-1")
        let inst2 = PlatformInstance(platform: .buttondown, instanceName: "nl-2")
        let m1 = try latest[inst1]?.decodedMetrics()
        let m2 = try latest[inst2]?.decodedMetrics()
        #expect(m1?["subscriber_count"] == .int(10))
        #expect(m2?["subscriber_count"] == .int(20))
    }
}
```

### `SocialBrainTests/MultiInstanceCollectorRegistryTests.swift` (new)

```swift
@Suite("Multi-Instance CollectorRegistry Tests")
struct MultiInstanceCollectorRegistryTests {

    @Test("configured() returns one collector per credentialed instance")
    func configuredCollectors() {
        let inst1 = PlatformInstance(platform: .buttondown, instanceName: "nl-a")
        let inst2 = PlatformInstance(platform: .buttondown, instanceName: "nl-b")
        let credentialed: Set<String> = [inst1.id, inst2.id]

        let mockInstances: (Platform) -> [String] = { platform in
            platform == .buttondown ? ["nl-a", "nl-b"] : ["default"]
        }
        let mockHasCredentials: (PlatformInstance) -> Bool = { credentialed.contains($0.id) }

        let collectors = CollectorRegistry.configured(
            instances: mockInstances,
            hasCredentials: mockHasCredentials
        )
        let buttondownCollectors = collectors.filter { $0.platform == .buttondown }
        #expect(buttondownCollectors.count == 2)
        let names = Set(buttondownCollectors.map(\.instanceName))
        #expect(names == ["nl-a", "nl-b"])
    }

    @Test("Instance without credentials is excluded")
    func excludesUncredentialed() {
        let mockInstances: (Platform) -> [String] = { _ in ["default"] }
        let mockHasCredentials: (PlatformInstance) -> Bool = { _ in false }

        let collectors = CollectorRegistry.configured(
            instances: mockInstances,
            hasCredentials: mockHasCredentials
        )
        #expect(collectors.isEmpty)
    }

    @Test("File-export platforms never appear in API collector list")
    func fileExportExcluded() {
        let mockInstances: (Platform) -> [String] = { _ in ["default"] }
        let mockHasCredentials: (PlatformInstance) -> Bool = { _ in true }

        let collectors = CollectorRegistry.configured(
            instances: mockInstances,
            hasCredentials: mockHasCredentials
        )
        let fileExportPlatforms: Set<Platform> = [.amazon, .linkedin, .oreilly, .substack]
        let collectorPlatforms = Set(collectors.map(\.platform))
        #expect(collectorPlatforms.isDisjoint(with: fileExportPlatforms))
    }
}
```

- [ ] Create all 5 new test files
- [ ] Run `xcodegen generate`
- [ ] Run full test suite: `xcodebuild test -scheme SocialBrain -destination 'platform=macOS' -only-testing:SocialBrainTests`
- [ ] All tests pass

---

## Task 18: Commit

```bash
git add -A
git commit -m "Add multi-instance platform support (issue #29)

- PlatformInstance type identifies one configured account per platform
- InstanceRegistry (UserDefaults) tracks instance names per platform
- KeychainStore keyed by platform:instanceName; old Platform API delegates to default
- PlatformData and PlatformSnapshot gain instanceName field
- v2_instance_names DB migration adds column to platformSnapshot
- All DB queries scope to (platform, instanceName)
- CollectorRegistry iterates PlatformInstance; CollectionEngine credentials closure takes PlatformInstance
- PlatformsView shows grouped instances with + Add another button
- Dashboard, Feed, PromptAssembler all updated to PlatformInstance keys
- 5 new test suites; all 144+ tests pass"
```

---

## Files summary

### New files
- `SocialBrain/Models/PlatformInstance.swift`
- `SocialBrain/Models/InstanceRegistry.swift`
- `SocialBrainTests/PlatformInstanceTests.swift`
- `SocialBrainTests/InstanceRegistryTests.swift`
- `SocialBrainTests/MultiInstanceKeychainTests.swift`
- `SocialBrainTests/MultiInstanceDatabaseTests.swift`
- `SocialBrainTests/MultiInstanceCollectorRegistryTests.swift`

### Modified files
- `SocialBrain/Keychain/KeychainStore.swift`
- `SocialBrain/Models/PlatformData.swift`
- `SocialBrain/Database/PlatformSnapshot.swift`
- `SocialBrain/Database/AppDatabase.swift`
- `SocialBrain/Collectors/Collector.swift`
- `SocialBrain/Collectors/CollectionEngine.swift`
- All 10 collector files (add `var instanceName: String = "default"` + pass to `PlatformData`)
- `SocialBrain/Prompt/PromptAssembler.swift`
- `SocialBrain/Models/FeedCardBuilder.swift`
- `SocialBrain/Models/SpikeDetector.swift`
- `SocialBrain/Models/HighReachDetector.swift`
- `SocialBrain/Models/FeedCard.swift`
- `SocialBrain/Views/Platforms/PlatformsViewModel.swift`
- `SocialBrain/Views/Platforms/PlatformsView.swift`
- `SocialBrain/Views/Platforms/PlatformCredentialSheet.swift`
- `SocialBrain/Views/Run/RunViewModel.swift`
- `SocialBrain/Views/Dashboard/DashboardViewModel.swift`
- `SocialBrain/Views/Feed/FeedViewModel.swift`
- `SocialBrain/Views/Feed/FeedCardView.swift`
- `SocialBrain/Views/Feed/FeedView.swift`
- `SocialBrain.xcodeproj/project.pbxproj` (regenerated by xcodegen)
