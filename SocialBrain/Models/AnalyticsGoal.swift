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

extension AnalyticsGoal {
    private static let goalKey       = "analyticsGoal"
    private static let customTextKey = "analyticsGoalCustomText"

    /// The currently saved goal. Defaults to `.growReach` if unset.
    static var current: AnalyticsGoal {
        get {
            guard let raw = UserDefaults.standard.string(forKey: goalKey),
                  let goal = AnalyticsGoal(rawValue: raw) else { return .growReach }
            return goal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: goalKey) }
    }

    /// Free-text clarification for the `.other` case.
    static var customText: String {
        get { UserDefaults.standard.string(forKey: customTextKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: customTextKey) }
    }

    /// Human-readable label including custom text when applicable.
    static var currentLabel: String {
        let goal = current
        if goal == .other, !customText.isEmpty {
            return customText
        }
        return goal.displayName
    }
}
