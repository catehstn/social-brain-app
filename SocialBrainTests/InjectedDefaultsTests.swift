import Testing
import Foundation
@testable import SocialBrain

/// `InstanceLabels` and `AnalyticsGoalStore` were the last two types reading
/// `UserDefaults.standard` directly, with no seam for a test (#58, #90).
///
/// Nothing tested either of them, so nothing was writing the developer's real
/// preferences — but that was luck rather than design: the first test written
/// for goal selection or instance labelling would have done exactly that. It is
/// the class #98 fixed for the Keychain, #127 fixed again for concurrent runs,
/// and #80 fixed for platform visibility.
@Suite("Injected defaults")
struct InjectedDefaultsTests {

    // MARK: - InstanceLabels

    @Test("A label round-trips, and is scoped to its instance")
    func labelRoundTrips() {
        let labels = InstanceLabels(defaults: InMemoryKeyValueStore())
        let work = PlatformInstance(platform: .mastodon, instanceName: "work")
        let personal = PlatformInstance(platform: .mastodon, instanceName: "personal")

        labels.setLabel("@cate@hachyderm.io", for: work)

        #expect(labels.label(for: work) == "@cate@hachyderm.io")
        // Same platform, different instance — the whole reason labels are keyed
        // by instance rather than platform.
        #expect(labels.label(for: personal) == nil)
    }

    @Test("Removing a label leaves no trace")
    func labelRemoval() {
        let labels = InstanceLabels(defaults: InMemoryKeyValueStore())
        let instance = PlatformInstance(platform: .buttondown)

        labels.setLabel("Weekly", for: instance)
        labels.removeLabel(for: instance)

        #expect(labels.label(for: instance) == nil)
    }

    @Test("Two stores do not see each other's labels")
    func labelsAreScopedToTheirStore() {
        // What the injection buys: a test store and the real one cannot collide.
        let a = InstanceLabels(defaults: InMemoryKeyValueStore())
        let b = InstanceLabels(defaults: InMemoryKeyValueStore())
        let instance = PlatformInstance(platform: .bluesky)

        a.setLabel("only in a", for: instance)

        #expect(a.label(for: instance) == "only in a")
        #expect(b.label(for: instance) == nil)
    }


    // MARK: - AnalyticsGoalStore

    @Test("An unset goal defaults to growReach rather than failing")
    func goalDefaults() {
        let goals = AnalyticsGoalStore(defaults: InMemoryKeyValueStore())

        #expect(goals.current == .growReach)
        #expect(goals.customText.isEmpty)
    }

    @Test("A goal round-trips")
    func goalRoundTrips() {
        let goals = AnalyticsGoalStore(defaults: InMemoryKeyValueStore())

        goals.current = .improveConversion

        #expect(goals.current == .improveConversion)
    }

    @Test("An unrecognised stored value falls back rather than crashing")
    func unknownGoalFallsBack() {
        // A raw value written by a future version, or a corrupted preference.
        let store = InMemoryKeyValueStore()
        store.set("worldDomination", forKey: "analyticsGoal")
        let goals = AnalyticsGoalStore(defaults: store)

        #expect(goals.current == .growReach)
    }

    @Test("The label uses custom text only for the other case, and only when set")
    func currentLabelUsesCustomText() {
        let goals = AnalyticsGoalStore(defaults: InMemoryKeyValueStore())

        goals.current = .other
        goals.customText = "Land three speaking slots"
        #expect(goals.currentLabel == "Land three speaking slots")

        // Empty custom text falls back to the display name rather than showing
        // an empty label.
        goals.customText = ""
        #expect(goals.currentLabel == AnalyticsGoal.other.displayName)

        // And custom text is ignored for any other goal.
        goals.current = .traffic
        goals.customText = "ignored"
        #expect(goals.currentLabel == AnalyticsGoal.traffic.displayName)
    }

    // MARK: - The four-line claim

    /// `CLAUDE.md` and `docs/repo-cleanup-plan.md` both say `UserDefaults.standard`
    /// appears in exactly four lines of the app, one per store. That claim was
    /// previously "enforced" by two tests asserting
    /// `InstanceLabels.shared.defaults is UserDefaults` — which passes for a
    /// `UserDefaults(suiteName:)` store too, and says nothing about the other
    /// files. This reads the source instead, so adding a fifth use fails here
    /// rather than quietly making the docs wrong.
    @Test("UserDefaults.standard appears only in the four shared stores")
    func standardDefaultsConfinedToSharedStores() {
        // Both the app and the MCP tool: the tool builds its own copy of
        // `InstanceLabels` and friends, and its `UserDefaults.standard` is a
        // different domain again, so a new use there is worth catching too.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SocialBrainTests
            .deletingLastPathComponent()   // repo root
        let roots = [repo.appendingPathComponent("SocialBrain"),
                     repo.appendingPathComponent("SocialBrainMCP")]

        let expected: Set<String> = [
            "SocialBrain/Models/InstanceRegistry.swift",
            "SocialBrain/Models/InstanceLabels.swift",
            "SocialBrain/Models/AnalyticsGoal.swift",
            "SocialBrain/Models/PlatformVisibilityStore.swift",
        ]

        var found: [String: [String]] = [:]
        for root in roots {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            let paths = (files?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            #expect(!paths.isEmpty, "No Swift sources under \(root.lastPathComponent) — this would pass vacuously")

            for file in paths {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let relative = root.lastPathComponent + "/"
                    + file.path.replacingOccurrences(of: root.path + "/", with: "")
                var inBlockComment = false
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if inBlockComment {
                        if trimmed.contains("*/") { inBlockComment = false }
                        continue
                    }
                    // Multi-line only: a one-line `/* … */` is still counted,
                    // which fails loudly rather than silently, so it is the
                    // safe direction to be wrong in.
                    if trimmed.hasPrefix("/*") && !trimmed.contains("*/") {
                        inBlockComment = true
                        continue
                    }
                    guard !trimmed.hasPrefix("//") else { continue }
                    if trimmed.contains("UserDefaults.standard") {
                        found[relative, default: []].append(trimmed)
                    }
                }
            }
        }

        for (file, lines) in found.sorted(by: { $0.key < $1.key }) {
            #expect(lines.count == 1, "\(file) names UserDefaults.standard \(lines.count) times: \(lines)")
            #expect(lines.first?.hasPrefix("static let shared") == true,
                    "\(file) names UserDefaults.standard outside a `static let shared`: \(lines)")
        }

        #expect(Set(found.keys) == expected,
                "Files naming UserDefaults.standard: \(found.keys.sorted()); expected: \(expected.sorted())")
    }

    /// `@AppStorage` reads `UserDefaults.standard` without naming it, so the
    /// detector above cannot see it. Two keys still reach preferences that way:
    /// the analytics goal, which has an `AnalyticsGoalStore` it bypasses, and
    /// `hasCompletedOnboarding`, which has no injected store at all (#58, #90).
    /// Pinned as key/file pairs so the gap is recorded rather than implied to be
    /// closed, and so a new one has to be added here deliberately.
    @Test("Known gap: @AppStorage reaches preferences without an injected store")
    func appStorageGapIsKnown() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SocialBrain")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let paths = (files?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        #expect(!paths.isEmpty, "Found no Swift sources — this detector would pass vacuously")

        var uses: Set<String> = []
        for file in paths {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("@AppStorage(") {
                guard let key = line.split(separator: "\"").dropFirst().first else { continue }
                uses.insert("\(file.lastPathComponent):\(key)")
            }
        }

        #expect(uses == [
            "ContentView.swift:hasCompletedOnboarding",
            "SettingsView.swift:hasCompletedOnboarding",
            "SettingsView.swift:analyticsGoal",
            "SettingsView.swift:analyticsGoalCustomText",
            "GoalBadgeView.swift:analyticsGoal",
            "GoalBadgeView.swift:analyticsGoalCustomText",
        ], "The @AppStorage users changed — update this test and CLAUDE.md together")
    }
}
