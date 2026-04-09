import Foundation

enum FeedCardType: String, Codable, Sendable {
    case recentPost
    case metricHighlight
    case upcomingEvent
    case staleReminder
}
