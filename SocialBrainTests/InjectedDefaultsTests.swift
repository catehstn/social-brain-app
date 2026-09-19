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

    @Test("The shared label store is the only thing naming UserDefaults.standard")
    func sharedLabelsUseStandardDefaults() {
        #expect(InstanceLabels.shared.defaults is UserDefaults)
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

    @Test("The shared goal store is the only thing naming UserDefaults.standard")
    func sharedGoalsUseStandardDefaults() {
        #expect(AnalyticsGoalStore.shared.defaults is UserDefaults)
    }
}
