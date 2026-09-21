import Foundation

/// The user's primary analytics goal, used to focus the Claude prompt.
enum AnalyticsGoal: String, CaseIterable, Codable, Sendable {
    case traffic         = "traffic"
    case growReach       = "growReach"
    case improveConversion = "improveConversion"
    case other           = "other"

    var displayName: String {
        switch self {
        case .traffic:            return "Drive Traffic"
        case .growReach:          return "Grow Reach"
        case .improveConversion:  return "Improve Conversion"
        case .other:              return "Other"
        }
    }

    var promptPhrase: String {
        switch self {
        case .traffic:            return "drive more traffic to my content"
        case .growReach:          return "grow my audience reach and follower counts"
        case .improveConversion:  return "improve conversion rates (signups, clicks, purchases)"
        case .other:              return "achieve my publishing goals"
        }
    }
}

// MARK: - Persistence

/// Where the chosen goal is stored.
///
/// A type with an injected store rather than statics over
/// `UserDefaults.standard`, so a test can use a throwaway one — the same
/// treatment `PlatformVisibilityStore` and `InstanceRegistry` already had, and
/// `InstanceLabels` gains here (#58, #90). Nothing tested goal selection
/// before, so nothing was polluting real preferences yet; that was luck.
struct AnalyticsGoalStore: @unchecked Sendable {

    /// The production store. The only place `UserDefaults.standard` is used.
    static let shared = AnalyticsGoalStore(defaults: UserDefaults.standard)

    let defaults: any KeyValueStore

    init(defaults: any KeyValueStore) {
        self.defaults = defaults
    }

    private static let goalKey       = "analyticsGoal"
    private static let customTextKey = "analyticsGoalCustomText"

    /// The currently saved goal. Defaults to `.growReach` if unset.
    var current: AnalyticsGoal {
        get {
            guard let raw = defaults.string(forKey: Self.goalKey),
                  let goal = AnalyticsGoal(rawValue: raw) else { return .growReach }
            return goal
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.goalKey) }
    }

    /// Free-text clarification for the `.other` case.
    var customText: String {
        get { defaults.string(forKey: Self.customTextKey) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Self.customTextKey) }
    }

    /// Human-readable label including custom text when applicable.
    var currentLabel: String {
        let goal = current
        if goal == .other, !customText.isEmpty {
            return customText
        }
        return goal.displayName
    }
}
