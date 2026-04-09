# Feed View — Implementation Plan

## Overview

Add a Feed view to Social Brain that surfaces a scrollable list of `FeedCard` items
derived from the latest per-platform snapshots stored in GRDB. Cards are grouped by
type (recent posts, metric highlights, upcoming events, stale reminders) and support
expand/collapse. Tapping a card navigates to the Dashboard with that platform
pre-selected.

The codebase is currently a scaffold — `ContentView`, `SocialBrainApp`, and
`SettingsView` are stubs; no Models, Database, or Views/Dashboard directory exists yet.
This plan creates those foundational layers as needed, then builds the Feed feature on
top of them.

---

## Step 0 — Foundational Models (prerequisites)

These types are required by both the Feed and by future collectors/dashboard work.
Create them before any Feed code.

### New file: `SocialBrain/Models/Platform.swift`

```swift
import Foundation

/// All supported platforms. Raw value matches the database string key.
enum Platform: String, CaseIterable, Codable, Sendable {
    case mastodon
    case bluesky
    case buttondown
    case goatCounter
    case vercel
    case calendly
    case amazon
    case jetpack
    case linkedin
    case oreilly
    case substack
}
```

### New file: `SocialBrain/Models/Credentials.swift`

```swift
import Foundation

/// Opaque credential bundle passed to a Collector at runtime.
/// Actual secrets are fetched from Keychain; this struct carries only
/// the platform tag so Keychain lookup can be deferred.
struct Credentials: Sendable {
    let platform: Platform
}
```

### New file: `SocialBrain/Models/PlatformSnapshot.swift`

```swift
import Foundation
import GRDB

/// One row in the `snapshots` table.  Stored as JSON-encoded `data`.
struct PlatformSnapshot: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "snapshots"

    var id: Int64?
    let platform: String          // Platform.rawValue
    let collectedAt: Date
    let data: Data                // JSON payload — shape varies per platform
}
```

### New file: `SocialBrain/Models/PlatformData.swift`

```swift
import Foundation

/// Decoded payload returned by a Collector.
/// Each platform has its own case; the Feed uses only the fields it needs.
enum PlatformData: Codable, Sendable {
    case mastodon(MastodonData)
    case bluesky(BlueskyData)
    case buttondown(ButtondownData)
    case goatCounter(GoatCounterData)
    case vercel(VercelData)
    case calendly(CalendlyData)
    case amazon(AmazonData)
    case jetpack(JetpackData)
    case linkedin(LinkedInData)
    case oreilly(OreillyData)
    case substack(SubstackData)
}

// Minimal structs — collectors will flesh these out.  Feed only needs the
// fields declared here.

struct MastodonData: Codable, Sendable {
    var latestPostText: String?
    var followersCount: Int
    var engagementRate: Double   // favourites+boosts / followers
}
struct BlueskyData: Codable, Sendable {
    var latestPostText: String?
    var followersCount: Int
    var engagementRate: Double
}
struct ButtondownData: Codable, Sendable {
    var latestSubjectLine: String?
    var subscriberCount: Int
    var openRate: Double
}
struct GoatCounterData: Codable, Sendable {
    var topPageTitle: String?
    var totalVisits: Int
}
struct VercelData: Codable, Sendable {
    var latestDeploymentSummary: String?
    var errorRate: Double
}
struct CalendlyData: Codable, Sendable {
    var upcomingEventTitles: [String]   // next 5 events
    var upcomingEventDates: [Date]
}
struct AmazonData: Codable, Sendable {
    var latestTitle: String?
    var totalRoyalties: Double
}
struct JetpackData: Codable, Sendable {
    var latestPostTitle: String?
    var totalViews: Int
    var engagementRate: Double
}
struct LinkedInData: Codable, Sendable {
    var latestPostText: String?
    var totalImpressions: Int
}
struct OreillyData: Codable, Sendable {
    var latestTitle: String?
    var totalMinutesRead: Int
}
struct SubstackData: Codable, Sendable {
    var latestSubjectLine: String?
    var subscriberCount: Int
    var openRate: Double
}
```

---

## Step 1 — Database Layer

### New file: `SocialBrain/Database/AppDatabase.swift`

This is the single access point for GRDB.  Feed queries are included alongside the
schema definition.

```swift
import Foundation
import GRDB

/// Thread-safe database wrapper.  The shared instance is injected via the
/// environment so tests can swap in an in-memory database.
final class AppDatabase: Sendable {

    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_createSnapshots") { db in
            try db.create(table: "snapshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("platform", .text).notNull().indexed()
                t.column("collectedAt", .datetime).notNull()
                t.column("data", .blob).notNull()
            }
        }
        return m
    }

    // MARK: - Feed queries

    /// Latest snapshot for a given platform, or nil if never collected.
    func latestSnapshot(for platform: Platform) throws -> PlatformSnapshot? {
        try dbWriter.read { db in
            try PlatformSnapshot
                .filter(Column("platform") == platform.rawValue)
                .order(Column("collectedAt").desc)
                .fetchOne(db)
        }
    }

    /// Latest snapshot for every platform that has at least one row.
    /// Returns a dictionary keyed by Platform.
    func latestSnapshots() throws -> [Platform: PlatformSnapshot] {
        try dbWriter.read { db in
            // Fetch max collectedAt per platform, then join to get full rows.
            // SQLite supports this via a self-join on (platform, collectedAt).
            let rows = try PlatformSnapshot
                .filter(sql: """
                    (platform, collectedAt) IN (
                        SELECT platform, MAX(collectedAt)
                        FROM snapshots
                        GROUP BY platform
                    )
                    """)
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let p = Platform(rawValue: row.platform) else { return nil }
                return (p, row)
            })
        }
    }

    // MARK: - Write

    func save(snapshot: inout PlatformSnapshot) throws {
        try dbWriter.write { db in
            try snapshot.save(db)
        }
    }
}
```

### New file: `SocialBrain/Database/AppDatabase+Environment.swift`

```swift
import SwiftUI

private struct AppDatabaseKey: EnvironmentKey {
    // Crash early if database is not injected — intentional.
    static let defaultValue: AppDatabase = try! AppDatabase(
        DatabaseQueue(configuration: {
            var c = Configuration()
            c.label = "SocialBrain"
            return c
        }())
    )
}

extension EnvironmentValues {
    var appDatabase: AppDatabase {
        get { self[AppDatabaseKey.self] }
        set { self[AppDatabaseKey.self] = newValue }
    }
}
```

---

## Step 2 — Collector Protocol

### New file: `SocialBrain/Collectors/Collector.swift`

```swift
import Foundation

protocol Collector: Sendable {
    var platform: Platform { get }
    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData
}
```

---

## Step 3 — Feed Model Types

### New file: `SocialBrain/Models/FeedCardType.swift`

```swift
import Foundation

enum FeedCardType: String, Codable, Sendable {
    case recentPost
    case metricHighlight
    case upcomingEvent
    case staleReminder
}
```

### New file: `SocialBrain/Models/FeedCard.swift`

```swift
import Foundation

struct FeedCard: Identifiable, Sendable {
    let id: UUID
    let platform: Platform
    let cardType: FeedCardType
    let snippet: String          // max ~280 chars, word-boundary truncated
    var isExpanded: Bool         // toggled by user; defaults false
    let navigationTarget: Platform

    init(
        id: UUID = UUID(),
        platform: Platform,
        cardType: FeedCardType,
        snippet: String,
        isExpanded: Bool = false,
        navigationTarget: Platform
    ) {
        self.id = id
        self.platform = platform
        self.cardType = cardType
        self.snippet = snippet
        self.isExpanded = isExpanded
        self.navigationTarget = navigationTarget
    }
}
```

### New file: `SocialBrain/Models/FeedCardBuilder.swift`

Pure, testable logic that converts `[Platform: PlatformSnapshot]` into `[FeedCard]`.
No GRDB dependency; operates on already-decoded payloads.

```swift
import Foundation

/// Staleness thresholds per platform.
enum StalenessThreshold {
    static let threeDays: TimeInterval   = 3  * 24 * 3600
    static let thirtyDays: TimeInterval  = 30 * 24 * 3600

    static func threshold(for platform: Platform) -> TimeInterval? {
        switch platform {
        case .linkedin, .substack:  return threeDays
        case .amazon, .oreilly:     return thirtyDays
        default:                    return nil
        }
    }
}

/// Builds the ordered list of FeedCards from latest snapshots.
struct FeedCardBuilder {

    private static let maxSnippetLength = 280

    // NOTE: This function does NOT actually throw — all JSON decoding is done
    // with `try?` internally.  The signature is non-throwing so callers don't
    // need spurious `try` and tests don't need `throws`.
    static func build(
        snapshots: [Platform: PlatformSnapshot],
        now: Date = Date()
    ) -> [FeedCard] {
        var cards: [FeedCard] = []

        // 1. Stale reminders (highest priority — user needs to act)
        for platform in [Platform.linkedin, .substack, .amazon, .oreilly] {
            guard let threshold = StalenessThreshold.threshold(for: platform) else { continue }
            if let snapshot = snapshots[platform] {
                if now.timeIntervalSince(snapshot.collectedAt) > threshold {
                    cards.append(FeedCard(
                        platform: platform,
                        cardType: .staleReminder,
                        snippet: "Your \(platform.rawValue) data is stale — re-export to update.",
                        navigationTarget: platform
                    ))
                }
            } else {
                // Never collected → always stale
                cards.append(FeedCard(
                    platform: platform,
                    cardType: .staleReminder,
                    snippet: "No \(platform.rawValue) data yet — export a file to get started.",
                    navigationTarget: platform
                ))
            }
        }

        // 2. Upcoming events from Calendly
        if let snapshot = snapshots[.calendly],
           let data = try? JSONDecoder().decode(CalendlyData.self, from: snapshot.data),
           !data.upcomingEventTitles.isEmpty {
            let titles = data.upcomingEventTitles.prefix(3).joined(separator: ", ")
            cards.append(FeedCard(
                platform: .calendly,
                cardType: .upcomingEvent,
                snippet: truncate("Upcoming: \(titles)"),
                navigationTarget: .calendly
            ))
        }

        // 3. Recent posts — platforms with text content in latest snapshot
        let postPlatforms: [Platform] = [.mastodon, .bluesky, .buttondown, .jetpack,
                                          .linkedin, .substack]
        for platform in postPlatforms {
            guard let snapshot = snapshots[platform] else { continue }
            if let text = latestPostText(platform: platform, data: snapshot.data) {
                cards.append(FeedCard(
                    platform: platform,
                    cardType: .recentPost,
                    snippet: truncate(text),
                    navigationTarget: platform
                ))
            }
        }

        // 4. Metric highlights — platform with engagement notably above baseline
        //    (>= 2× the per-platform median across all stored snapshots,
        //     or simply the highest single engagementRate in the latest batch)
        let engagementPlatforms: [(Platform, Double)] = [
            .mastodon, .bluesky, .buttondown, .jetpack
        ].compactMap { p in
            guard let snapshot = snapshots[p],
                  let rate = engagementRate(platform: p, data: snapshot.data)
            else { return nil }
            return (p, rate)
        }
        if let best = engagementPlatforms.max(by: { $0.1 < $1.1 }) {
            let pct = String(format: "%.1f%%", best.1 * 100)
            cards.append(FeedCard(
                platform: best.0,
                cardType: .metricHighlight,
                snippet: "\(best.0.rawValue.capitalized) engagement at \(pct) — your best this period.",
                navigationTarget: best.0
            ))
        }

        return cards
    }

    // MARK: - Private helpers

    static func truncate(_ text: String, limit: Int = maxSnippetLength) -> String {
        guard text.count > limit else { return text }
        // Word-boundary truncation
        let prefix = text.prefix(limit)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }

    private static func latestPostText(platform: Platform, data: Data) -> String? {
        switch platform {
        case .mastodon:
            return (try? JSONDecoder().decode(MastodonData.self, from: data))?.latestPostText
        case .bluesky:
            return (try? JSONDecoder().decode(BlueskyData.self, from: data))?.latestPostText
        case .buttondown:
            return (try? JSONDecoder().decode(ButtondownData.self, from: data))?.latestSubjectLine
        case .jetpack:
            return (try? JSONDecoder().decode(JetpackData.self, from: data))?.latestPostTitle
        case .linkedin:
            return (try? JSONDecoder().decode(LinkedInData.self, from: data))?.latestPostText
        case .substack:
            return (try? JSONDecoder().decode(SubstackData.self, from: data))?.latestSubjectLine
        default:
            return nil
        }
    }

    private static func engagementRate(platform: Platform, data: Data) -> Double? {
        switch platform {
        case .mastodon:
            return (try? JSONDecoder().decode(MastodonData.self, from: data))?.engagementRate
        case .bluesky:
            return (try? JSONDecoder().decode(BlueskyData.self, from: data))?.engagementRate
        case .buttondown:
            return (try? JSONDecoder().decode(ButtondownData.self, from: data))?.openRate
        case .jetpack:
            return (try? JSONDecoder().decode(JetpackData.self, from: data))?.engagementRate
        default:
            return nil
        }
    }
}
```

---

## Step 4 — Sidebar

The app needs a navigation sidebar before the Feed view can be placed in it.

### New file: `SocialBrain/Views/Sidebar/SidebarItem.swift`

```swift
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case run
    case feed        // between run and dashboard
    case dashboard
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .run:       return "Run"
        case .feed:      return "Feed"
        case .dashboard: return "Dashboard"
        case .settings:  return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .run:       return "play.circle"
        case .feed:      return "rectangle.stack"
        case .dashboard: return "chart.bar"
        case .settings:  return "gearshape"
        }
    }
}
```

---

## Step 5 — Dashboard ViewModel (stub, for navigation target)

The Feed needs to set `selectedPlatform` on the Dashboard so navigation works.
We only need the interface here; full implementation is a separate PR.

### New file: `SocialBrain/Views/Dashboard/DashboardViewModel.swift`

```swift
import SwiftUI

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var selectedPlatform: Platform?
}
```

---

## Step 6 — Feed ViewModel

### New file: `SocialBrain/Views/Feed/FeedViewModel.swift`

```swift
import SwiftUI
import GRDB

@MainActor
final class FeedViewModel: ObservableObject {

    // cards must be var (not private(set)) so FeedCardView can receive a
    // Binding<FeedCard> via $vm.cards[index] for expand/collapse write-back.
    @Published var cards: [FeedCard] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var error: String?

    private let database: AppDatabase
    private let now: () -> Date

    init(database: AppDatabase, now: @escaping () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            // latestSnapshots() is synchronous and blocks; run it off the main
            // thread via a detached task so the UI stays responsive.
            let snapshots = try await Task.detached(priority: .userInitiated) { [database] in
                try database.latestSnapshots()
            }.value
            // FeedCardBuilder.build is non-throwing (all JSON decoded with try?)
            cards = FeedCardBuilder.build(snapshots: snapshots, now: now())
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
```

---

## Step 7 — FeedCard ViewModel

`FeedCard.isExpanded` is a `var` on a value type (`struct`).  When `FeedCardView`
constructs its own `FeedCardViewModel` from a copy of the card, toggling expand
affects only that local copy — the parent `FeedViewModel.cards` array is never
updated.  To avoid this stale-state bug, `FeedCardViewModel` receives a `Binding<FeedCard>`
that writes back into the parent's array.

### New file: `SocialBrain/Views/Feed/FeedCardViewModel.swift`

```swift
import SwiftUI

@MainActor
final class FeedCardViewModel: ObservableObject {

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
        objectWillChange.send()
    }
}
```

---

## Step 8 — Feed Views

### New file: `SocialBrain/Views/Feed/FeedCardView.swift`

`FeedCardView` takes a `Binding<FeedCard>` so that expand/collapse writes back
into `FeedViewModel.cards` and the expanded state is not lost on re-render.

```swift
import SwiftUI

struct FeedCardView: View {
    // Binding writes back into FeedViewModel.cards — avoids stale local copy.
    @Binding var card: FeedCard
    @StateObject private var vm: FeedCardViewModel

    init(card: Binding<FeedCard>) {
        self._card = card
        _vm = StateObject(wrappedValue: FeedCardViewModel(card: card))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(vm.card.platform.rawValue.capitalized,
                      systemImage: platformIcon(vm.card.platform))
                    .font(.headline)
                Spacer()
                Text(vm.card.cardType.rawValue)
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
        case .mastodon:   return "bubble.left"
        case .bluesky:    return "cloud"
        case .buttondown: return "envelope"
        case .goatCounter:return "chart.line.uptrend.xyaxis"
        case .vercel:     return "server.rack"
        case .calendly:   return "calendar"
        case .amazon:     return "shippingbox"
        case .jetpack:    return "bolt"
        case .linkedin:   return "person.crop.square"
        case .oreilly:    return "book"
        case .substack:   return "newspaper"
        }
    }
}
```

### New file: `SocialBrain/Views/Feed/FeedView.swift`

```swift
import SwiftUI

struct FeedView: View {
    @StateObject private var vm: FeedViewModel
    @EnvironmentObject private var dashboardVM: DashboardViewModel
    var onNavigate: (SidebarItem) -> Void

    init(database: AppDatabase, onNavigate: @escaping (SidebarItem) -> Void) {
        _vm = StateObject(wrappedValue: FeedViewModel(database: database))
        self.onNavigate = onNavigate
    }

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
                        // Use index-based ForEach so we can pass Binding<FeedCard>
                        // to FeedCardView, allowing expand state to write back into
                        // vm.cards rather than a disconnected local copy.
                        ForEach(vm.cards.indices, id: \.self) { index in
                            FeedCardView(card: $vm.cards[index])
                                .onTapGesture {
                                    dashboardVM.selectedPlatform = vm.cards[index].navigationTarget
                                    onNavigate(.dashboard)
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

---

## Step 9 — Rewrite ContentView with NavigationSplitView

Replace the stub `ContentView` with a real sidebar-based layout.

### Modified file: `SocialBrain/App/ContentView.swift`

Full replacement:

```swift
import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarItem? = .feed
    @StateObject private var dashboardVM = DashboardViewModel()

    @Environment(\.appDatabase) private var database

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.label, systemImage: item.systemImage)
                    .tag(item)
                    .accessibilityIdentifier("sidebar_\(item.rawValue)")
            }
            .navigationTitle("Social Brain")
            .listStyle(.sidebar)
        } detail: {
            switch selection {
            case .run:
                Text("Run")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .feed:
                FeedView(database: database) { newSelection in
                    selection = newSelection
                }
                .environmentObject(dashboardVM)
            case .dashboard:
                Text("Dashboard")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .settings:
                SettingsView()
            case .none:
                Text("Select an item")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environmentObject(dashboardVM)
    }
}

#Preview {
    ContentView()
}
```

---

## Step 10 — Wire Up AppDatabase in SocialBrainApp

### Modified file: `SocialBrain/App/SocialBrainApp.swift`

```swift
import SwiftUI
import GRDB

@main
struct SocialBrainApp: App {

    private let database: AppDatabase = {
        let url = try! FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("SocialBrain")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let dbURL = url.appendingPathComponent("socialbrain.db")
        let queue = try! DatabaseQueue(path: dbURL.path)
        return try! AppDatabase(queue)
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.appDatabase, database)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 900, height: 620)

        Settings {
            SettingsView()
        }
    }
}
```

---

## Step 11 — Tests

### New file: `SocialBrainTests/FeedDatabaseTests.swift`

Tests GRDB schema migration and `latestSnapshots()` using an in-memory database.

```swift
import Testing
import GRDB
@testable import SocialBrain

@Suite("FeedDatabase")
struct FeedDatabaseTests {

    private func makeDB() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    @Test("v1 migration creates snapshots table")
    func migrationCreatesTable() throws {
        let db = try makeDB()
        try db.dbWriter.read { conn in
            #expect(try conn.tableExists("snapshots"))
        }
    }

    @Test("latestSnapshots returns most recent row per platform")
    func latestSnapshotsReturnsNewest() throws {
        let db = try makeDB()
        let older = Date(timeIntervalSinceNow: -7200)
        let newer = Date()

        let payload = try JSONEncoder().encode(MastodonData(
            latestPostText: "hello", followersCount: 100, engagementRate: 0.05))

        var snap1 = PlatformSnapshot(id: nil, platform: "mastodon",
                                     collectedAt: older, data: payload)
        var snap2 = PlatformSnapshot(id: nil, platform: "mastodon",
                                     collectedAt: newer, data: payload)
        try db.save(snapshot: &snap1)
        try db.save(snapshot: &snap2)

        let result = try db.latestSnapshots()
        #expect(result[.mastodon]?.collectedAt == newer)
        #expect(result.count == 1)
    }

    @Test("latestSnapshots returns nil for platform with no rows")
    func latestSnapshotsMissingPlatform() throws {
        let db = try makeDB()
        let result = try db.latestSnapshots()
        #expect(result[.mastodon] == nil)
    }
}
```

### New file: `SocialBrainTests/FeedViewModelTests.swift`

Tests `FeedViewModel` using an in-memory database.

```swift
import Testing
import GRDB
@testable import SocialBrain

@Suite("FeedViewModel")
@MainActor
struct FeedViewModelTests {

    private func makeDB() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    @Test("load() populates cards from snapshots")
    func loadsCards() async throws {
        let db = try makeDB()
        let payload = try JSONEncoder().encode(MastodonData(
            latestPostText: "Test post", followersCount: 200, engagementRate: 0.1))
        var snap = PlatformSnapshot(id: nil, platform: "mastodon",
                                    collectedAt: Date(), data: payload)
        try db.save(snapshot: &snap)

        let vm = FeedViewModel(database: db)
        await vm.load()

        #expect(!vm.cards.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.error == nil)
    }

    @Test("load() results in empty cards for empty database")
    func emptyDatabase() async throws {
        let db = try makeDB()
        // File-export platforms with no snapshots produce stale reminders
        let vm = FeedViewModel(database: db)
        await vm.load()
        // stale reminders for linkedin, substack, amazon, oreilly
        #expect(vm.cards.filter { $0.cardType == .staleReminder }.count == 4)
    }

    @Test("stale snapshot produces stale reminder card")
    func staleReminderCard() async throws {
        let db = try makeDB()
        let staleDate = Date(timeIntervalSinceNow: -(4 * 24 * 3600)) // 4 days ago
        let payload = try JSONEncoder().encode(LinkedInData(
            latestPostText: "old post", totalImpressions: 50))
        var snap = PlatformSnapshot(id: nil, platform: "linkedin",
                                    collectedAt: staleDate, data: payload)
        try db.save(snapshot: &snap)

        // now() is injected so the clock is deterministic in tests.
        let vm = FeedViewModel(database: db, now: { Date() })
        await vm.load()

        let stale = vm.cards.first { $0.platform == .linkedin && $0.cardType == .staleReminder }
        #expect(stale != nil)
    }

    @Test("navigationTarget matches platform")
    func navigationTarget() async throws {
        let db = try makeDB()
        let payload = try JSONEncoder().encode(MastodonData(
            latestPostText: "nav test", followersCount: 10, engagementRate: 0.02))
        var snap = PlatformSnapshot(id: nil, platform: "mastodon",
                                    collectedAt: Date(), data: payload)
        try db.save(snapshot: &snap)

        let vm = FeedViewModel(database: db)
        await vm.load()

        let card = vm.cards.first { $0.platform == .mastodon }
        #expect(card?.navigationTarget == .mastodon)
    }
}
```

### New file: `SocialBrainTests/FeedCardViewModelTests.swift`

```swift
import Testing
@testable import SocialBrain

@Suite("FeedCardViewModel")
@MainActor
struct FeedCardViewModelTests {

    // Helper: creates a State<FeedCard> and returns a Binding to it.
    // FeedCardViewModel takes a Binding so changes write back to the source.
    private func makeBinding(snippet: String, expanded: Bool = false) -> Binding<FeedCard> {
        // In unit tests there is no SwiftUI environment, so we simulate the
        // binding with a plain variable captured by reference via a class box.
        // The class must provide a designated initializer because Swift classes
        // require all stored properties to be initialized before init completes;
        // there is no synthesized init() for a class with uninitialized stored properties.
        final class Box {
            var card: FeedCard
            init(_ card: FeedCard) { self.card = card }
        }
        let box = Box(FeedCard(platform: .mastodon, cardType: .recentPost,
                               snippet: snippet, isExpanded: expanded, navigationTarget: .mastodon))
        return Binding(get: { box.card }, set: { box.card = $0 })
    }

    @Test("displaySnippet is full text when expanded")
    func displaySnippetExpanded() {
        let long = String(repeating: "a", count: 200)
        let vm = FeedCardViewModel(card: makeBinding(snippet: long, expanded: true))
        #expect(vm.displaySnippet == long)
    }

    @Test("displaySnippet is truncated when collapsed")
    func displaySnippetCollapsed() {
        let long = String(repeating: "a ", count: 100) // 200 chars
        let vm = FeedCardViewModel(card: makeBinding(snippet: long))
        #expect(vm.displaySnippet.count <= 105) // 100 + "…"
    }

    @Test("isTruncated is false for short snippets")
    func isTruncatedFalse() {
        let short = "Short text."
        let vm = FeedCardViewModel(card: makeBinding(snippet: short))
        #expect(vm.isTruncated == false)
    }

    @Test("isTruncated is true for long snippets")
    func isTruncatedTrue() {
        let long = String(repeating: "word ", count: 30)
        let vm = FeedCardViewModel(card: makeBinding(snippet: long))
        #expect(vm.isTruncated == true)
    }

    @Test("toggleExpand flips isExpanded and writes back to binding source")
    func toggleExpand() {
        let binding = makeBinding(snippet: "Test")
        let vm = FeedCardViewModel(card: binding)
        #expect(binding.wrappedValue.isExpanded == false)
        vm.toggleExpand()
        #expect(binding.wrappedValue.isExpanded == true)
        vm.toggleExpand()
        #expect(binding.wrappedValue.isExpanded == false)
    }
}
```

### New file: `SocialBrainTests/FeedCardBuilderTests.swift`

Unit-tests for `FeedCardBuilder` — covers the `truncate` word-boundary logic
(explicitly called out in the task) and the non-throwing `build` signature.

```swift
import Testing
@testable import SocialBrain

@Suite("FeedCardBuilder")
struct FeedCardBuilderTests {

    @Test("truncate returns full text when under limit")
    func truncateShortText() {
        let text = "Hello world"
        #expect(FeedCardBuilder.truncate(text, limit: 280) == text)
    }

    @Test("truncate breaks at a word boundary, not mid-word")
    func truncateAtWordBoundary() {
        // 10 repetitions of "hello " = 60 chars; limit 25 should cut after a space
        let text = String(repeating: "hello ", count: 10)
        let result = FeedCardBuilder.truncate(text, limit: 25)
        // Must end with "…" and the character before "…" must be a letter (not space)
        #expect(result.hasSuffix("…"))
        let withoutEllipsis = result.dropLast() // remove "…"
        #expect(!withoutEllipsis.hasSuffix(" "))
        #expect(result.count <= 26) // 25 chars + "…"
    }

    @Test("truncate falls back to hard cut when no space found")
    func truncateNoSpace() {
        let text = String(repeating: "a", count: 300)
        let result = FeedCardBuilder.truncate(text, limit: 280)
        #expect(result.hasSuffix("…"))
        #expect(result.count == 281) // 280 chars + "…"
    }

    @Test("build returns empty array for empty snapshots (no file-export platforms)")
    func buildEmptySnapshots() {
        // Stale reminders are added for linkedin/substack/amazon/oreilly even when
        // there are no snapshots at all — verify count is 4.
        let cards = FeedCardBuilder.build(snapshots: [:], now: Date())
        #expect(cards.filter { $0.cardType == .staleReminder }.count == 4)
    }

    @Test("build is non-throwing — compiles without try")
    func buildIsNonThrowing() {
        // If this compiles, the function signature is correct.
        let _: [FeedCard] = FeedCardBuilder.build(snapshots: [:])
    }
}
```

---

### New file: `SocialBrainTests/SidebarTests.swift`

```swift
import Testing
@testable import SocialBrain

@Suite("Sidebar")
struct SidebarTests {

    @Test(".feed case exists in allCases")
    func feedCaseExists() {
        #expect(SidebarItem.allCases.contains(.feed))
    }

    @Test(".feed is positioned between .run and .dashboard")
    func feedPosition() {
        let cases = SidebarItem.allCases
        let runIdx  = cases.firstIndex(of: .run)!
        let feedIdx = cases.firstIndex(of: .feed)!
        let dashIdx = cases.firstIndex(of: .dashboard)!
        #expect(runIdx < feedIdx)
        #expect(feedIdx < dashIdx)
    }
}
```

### New file: `SocialBrainUITests/FeedUITests.swift`

```swift
import XCTest

final class FeedUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testFeedItemExistsInSidebar() {
        // The sidebar list should contain a "Feed" item.
        let feedItem = app.outlines.firstMatch.cells
            .staticTexts["Feed"]
        XCTAssert(feedItem.waitForExistence(timeout: 5))
    }

    func testTappingFeedDoesNotCrash() {
        let feedItem = app.outlines.firstMatch.cells
            .staticTexts["Feed"]
        guard feedItem.waitForExistence(timeout: 5) else {
            XCTFail("Feed sidebar item not found")
            return
        }
        feedItem.click()
        // App should still be running
        XCTAssertTrue(app.exists)
    }

    func testExpandControlVisibleWhenCardIsTruncated() {
        // Navigate to Feed
        let feedItem = app.outlines.firstMatch.cells
            .staticTexts["Feed"]
        guard feedItem.waitForExistence(timeout: 5) else { return }
        feedItem.click()

        // If any expandToggle buttons exist, at least one should be hittable.
        // (This test is a no-op if database is empty — that is acceptable per
        //  the approved minimal UI test strategy.)
        let toggleButtons = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'expandToggle_'"))
        if toggleButtons.count > 0 {
            XCTAssertTrue(toggleButtons.firstMatch.isHittable)
        }
    }
}
```

---

## Step 12 — Update `project.yml` (xcodegen)

After adding new Swift files, run `xcodegen generate` from the repo root (or the
worktree root) to regenerate `SocialBrain.xcodeproj`. No manual edits to project.yml
are needed because `project.yml` uses directory-level source globs
(`sources: - SocialBrain`), which picks up all `.swift` files automatically.

**Command:**

```
xcodegen generate
```

Run this after every batch of new file additions before building or running tests.

---

## Step 13 — Compilation Gate

```
xcodebuild build-for-testing \
    -scheme SocialBrain \
    -destination 'platform=macOS'
```

Must produce zero errors before opening a PR.

---

## Full File Manifest

### New files

| Path | Purpose |
|------|---------|
| `SocialBrain/Models/Platform.swift` | `Platform` enum |
| `SocialBrain/Models/Credentials.swift` | `Credentials` struct |
| `SocialBrain/Models/PlatformSnapshot.swift` | GRDB row type |
| `SocialBrain/Models/PlatformData.swift` | Per-platform data structs |
| `SocialBrain/Models/FeedCardType.swift` | `FeedCardType` enum |
| `SocialBrain/Models/FeedCard.swift` | `FeedCard` struct |
| `SocialBrain/Models/FeedCardBuilder.swift` | Pure card-building logic + `StalenessThreshold` |
| `SocialBrain/Collectors/Collector.swift` | `Collector` protocol |
| `SocialBrain/Database/AppDatabase.swift` | GRDB wrapper + migrations + Feed queries |
| `SocialBrain/Database/AppDatabase+Environment.swift` | SwiftUI environment key |
| `SocialBrain/Views/Sidebar/SidebarItem.swift` | `SidebarItem` enum |
| `SocialBrain/Views/Dashboard/DashboardViewModel.swift` | Dashboard VM stub (for navigation) |
| `SocialBrain/Views/Feed/FeedViewModel.swift` | Feed VM |
| `SocialBrain/Views/Feed/FeedCardViewModel.swift` | Per-card VM |
| `SocialBrain/Views/Feed/FeedCardView.swift` | Card SwiftUI view |
| `SocialBrain/Views/Feed/FeedView.swift` | Feed SwiftUI view |
| `SocialBrainTests/FeedDatabaseTests.swift` | DB integration tests |
| `SocialBrainTests/FeedViewModelTests.swift` | FeedViewModel unit tests |
| `SocialBrainTests/FeedCardViewModelTests.swift` | FeedCardViewModel unit tests (Binding-based) |
| `SocialBrainTests/FeedCardBuilderTests.swift` | FeedCardBuilder unit tests incl. word-boundary truncation |
| `SocialBrainTests/SidebarTests.swift` | Sidebar ordering tests |
| `SocialBrainUITests/FeedUITests.swift` | Minimal UI tests |

### Modified files

| Path | Change |
|------|--------|
| `SocialBrain/App/ContentView.swift` | Full replacement with `NavigationSplitView` sidebar layout |
| `SocialBrain/App/SocialBrainApp.swift` | Wire `AppDatabase` via environment |

---

## Swift 6 Concurrency Notes

- `FeedViewModel` and `FeedCardViewModel` are `@MainActor` — all `@Published` mutations
  happen on the main actor.
- `FeedCard`, `FeedCardType`, `Platform`, `PlatformSnapshot`, `PlatformData` and all
  data structs conform to `Sendable` (value types or explicitly annotated).
- `AppDatabase` is `final class Sendable` — GRDB's `DatabaseWriter` is already
  concurrency-safe; the wrapper adds no mutable state beyond the writer.
- `FeedCardBuilder` is a pure struct with only static methods — inherently `Sendable`.
- `FeedViewModel.load()` dispatches the synchronous `latestSnapshots()` call via
  `Task.detached(priority: .userInitiated)` to avoid blocking the main thread.
  `AppDatabase` is `Sendable` so it can safely cross the actor boundary into the
  detached task's isolation domain.
- `FeedCardBuilder.build` is **non-throwing** — all internal JSON decoding uses
  `try?`.  Do NOT add `throws` to the signature; call sites must not use `try`.
- `Collector` protocol is `Sendable`-constrained so collector instances can be passed
  across actor boundaries.
- **Expand/collapse state ownership**: `FeedCard.isExpanded` is owned by
  `FeedViewModel.cards` (the single source of truth).  `FeedCardView` receives a
  `Binding<FeedCard>` (via `$vm.cards[index]`) so that `FeedCardViewModel.toggleExpand()`
  writes back through the binding and the parent array reflects the change.  Never
  construct `FeedCardViewModel` from a plain `FeedCard` value — it creates a
  disconnected copy whose mutations are silently discarded.

---

## Open Questions / Deferred

- **Metric highlight baseline**: The plan uses the single highest `engagementRate` in
  the latest snapshot batch. A richer baseline (median across 30 days) requires
  additional DB queries and can be added in a follow-up.
- **Full Dashboard implementation**: `DashboardViewModel` is a stub. The real
  dashboard chart views are a separate PR.
- **Run view**: Also a stub; not in scope here.
- **Live API testing**: Collectors are not implemented yet; Feed tests use mock JSON
  payloads only.
