import Foundation

// Feed-specific platform data structs used for snippet extraction.
// These are encoded as JSON (via JSONEncoder) into PlatformSnapshot.metricsJSON
// when seeding test data, and decoded by FeedCardBuilder when building cards.
//
// NOTE: The production collectors store metrics as [String: MetricValue].
// FeedCardBuilder reads both formats: it first tries these typed structs
// (try? JSONDecoder().decode) and falls back to the MetricValue dictionary
// so that it works with both test fixtures and live collector output.

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
