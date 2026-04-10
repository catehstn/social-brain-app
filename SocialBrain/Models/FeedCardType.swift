import Foundation

enum FeedCardType: String, Codable, Sendable {
    case recentPost
    case metricHighlight
    case upcomingEvent
    case staleReminder
    case spikeAlert

    var displayName: String {
        switch self {
        case .recentPost: return "Recent Post"
        case .metricHighlight: return "Metric Highlight"
        case .upcomingEvent: return "Upcoming Event"
        case .staleReminder: return "Stale Reminder"
        case .spikeAlert: return "Spike Alert"
        }
    }
}
