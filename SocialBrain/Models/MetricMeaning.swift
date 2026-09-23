import Foundation

/// What a metric key *means*, as opposed to what it is spelled.
///
/// `MetricKey` made the spelling single-source (#63's first half). This is the
/// second half: two keys can be spelled differently and mean the same thing
/// (`followers_count`, `total_followers`, `followers_blog` and
/// `subscriber_count` are four spellings of an audience size), and two keys can
/// look alike and mean different things — which is the bug.
///
/// `FeedCardBuilder` picked a "best engagement" winner with `max` across
/// Buttondown's **open rate** (0.4–0.7 on a healthy newsletter) and everyone
/// else's **engagement rate** (0.01–0.03 on a healthy account). Buttondown won
/// whenever it had data, so the card was decoration (#81). Nothing in the code
/// said the two numbers were incomparable, because nothing said what either
/// one was.
///
/// This is names-and-units only. It deliberately does **not** try to make
/// platforms comparable — an "audience" is a follower on Mastodon and a
/// subscriber on Buttondown, and those are not the same thing. Knowing they
/// are both audiences is enough to stop the app adding them up.
struct MetricMeaning: Sendable, Equatable {

    /// The quantity a key reports.
    ///
    /// Two keys with the same concept measure the same idea on different
    /// platforms; two with different concepts must not be compared, ranked
    /// against each other, or summed.
    enum Concept: String, Sendable, CaseIterable {
        case audience          // followers, subscribers, connected channels
        case audienceChange    // new followers or subscribers in the period
        case published         // posts, emails, updates sent
        case scheduled         // queued, not yet sent
        case views             // page views, impressions, visits
        case uniquePeople      // visitors, unique users, unique invitees
        case reactions         // likes, favourites, points
        case comments
        case shares            // reposts, boosts, shares
        case clicks
        case engagementRate    // interactions per follower or per delivery
        case openRate          // emails opened per delivery — not engagement
        case clickRate         // clicks per delivery or per impression
        case searchPosition    // where a page ranks; lower is better
        case meetings          // scheduled or cancelled events
        case completions
        case note              // prose, not a number
    }

    /// How to read the number.
    enum Unit: String, Sendable {
        /// A whole thing counted.
        case count
        /// A proportion in 0...1. Rendered as a percentage; never summed.
        case fraction
        /// A position, where **lower is better** — so a rise is bad news, and
        /// a percentage change reads backwards (`SpikeDetector.Rendering.rank`
        /// exists for this).
        case rank
        /// Text.
        case text
    }

    let concept: Concept
    let unit: Unit

    /// Whether two keys may be compared or ranked against each other.
    ///
    /// Same concept **and** same unit: a fraction and a count of the same
    /// concept are not comparable either.
    func isComparable(with other: MetricMeaning) -> Bool {
        concept == other.concept && unit == other.unit
    }
}

extension MetricKey {

    /// What each key means. Hand-maintained, and `MetricMeaningTests` fails
    /// when a key declared above is missing from here.
    static let meanings: [String: MetricMeaning] = [
        // Audience
        followersCount:   .init(concept: .audience, unit: .count),
        followingCount:   .init(concept: .audience, unit: .count),
        followsCount:     .init(concept: .audience, unit: .count),
        totalFollowers:   .init(concept: .audience, unit: .count),
        followersBlog:    .init(concept: .audience, unit: .count),
        followersComment: .init(concept: .audience, unit: .count),
        subscriberCount:  .init(concept: .audience, unit: .count),
        profilesCount:    .init(concept: .audience, unit: .count),
        newFollowers:     .init(concept: .audienceChange, unit: .count),
        newSubscribers:   .init(concept: .audienceChange, unit: .count),
        membersReached:   .init(concept: .uniquePeople, unit: .count),

        // Volume
        postsCount:       .init(concept: .published, unit: .count),
        statusesCount:    .init(concept: .published, unit: .count),
        postsPublished:   .init(concept: .published, unit: .count),
        recentPosts:      .init(concept: .published, unit: .count),
        sentUpdates:      .init(concept: .published, unit: .count),
        emailsSent:       .init(concept: .published, unit: .count),
        titlesCount:      .init(concept: .published, unit: .count),
        mentionCount:     .init(concept: .published, unit: .count),
        scheduledUpdates: .init(concept: .scheduled, unit: .count),

        // Reach
        totalViews:       .init(concept: .views, unit: .count),
        totalVisits:      .init(concept: .views, unit: .count),
        totalPageViews:   .init(concept: .views, unit: .count),
        totalImpressions: .init(concept: .views, unit: .count),
        impressions:      .init(concept: .views, unit: .count),
        totalReach:       .init(concept: .uniquePeople, unit: .count),
        totalVisitors:    .init(concept: .uniquePeople, unit: .count),
        totalUniqueUsers: .init(concept: .uniquePeople, unit: .count),

        // Engagement
        totalLikes:       .init(concept: .reactions, unit: .count),
        totalPoints:      .init(concept: .reactions, unit: .count),
        totalComments:    .init(concept: .comments, unit: .count),
        totalShares:      .init(concept: .shares, unit: .count),
        totalClicks:      .init(concept: .clicks, unit: .count),
        clicks:           .init(concept: .clicks, unit: .count),
        totalCompletions: .init(concept: .completions, unit: .count),
        // Interactions per post rather than per follower, but the same idea
        // and the same scale as the rates below would not be — they are
        // counts, and stay counts.
        avgLikes:         .init(concept: .reactions, unit: .count),
        avgFavourites:    .init(concept: .reactions, unit: .count),
        avgReplies:       .init(concept: .comments, unit: .count),
        avgReposts:       .init(concept: .shares, unit: .count),
        avgReblogs:       .init(concept: .shares, unit: .count),
        // LinkedIn's own engagement figure, a count of interactions.
        totalEngagements: .init(concept: .reactions, unit: .count),

        // Rates. The distinction this whole type exists for: an open rate is
        // not an engagement rate, and #81 is what happens when they are ranked
        // against each other.
        avgOpenRate:      .init(concept: .openRate, unit: .fraction),
        avgClickRate:     .init(concept: .clickRate, unit: .fraction),
        avgCTR:           .init(concept: .clickRate, unit: .fraction),
        ctr:              .init(concept: .clickRate, unit: .fraction),
        engagementRate:   .init(concept: .engagementRate, unit: .fraction),
        avgPosition:      .init(concept: .searchPosition, unit: .rank),

        // Meetings
        eventsCount:      .init(concept: .meetings, unit: .count),
        cancelledCount:   .init(concept: .meetings, unit: .count),
        uniqueInvitees:   .init(concept: .uniquePeople, unit: .count),

        // Notes and prose
        postsTruncated:        .init(concept: .note, unit: .text),
        postsSampled:          .init(concept: .note, unit: .text),
        emailsSampled:         .init(concept: .note, unit: .text),
        mentionsSampled:       .init(concept: .note, unit: .text),
        viewsWindow:           .init(concept: .note, unit: .text),
        engagementUnavailable: .init(concept: .note, unit: .text),
        latestPostText:        .init(concept: .note, unit: .text),
        latestPostTitle:       .init(concept: .note, unit: .text),
        latestSubjectLine:     .init(concept: .note, unit: .text),

        // Paid subscribers are an audience, not a rate, despite sitting beside
        // the rates in the Substack section of the prompt.
        paidSubscribers:  .init(concept: .audience, unit: .count)
    ]

    /// What `key` means, or `nil` for a numbered family member or an unknown
    /// key — a stored snapshot can hold a key this build no longer declares.
    static func meaning(of key: String) -> MetricMeaning? {
        if let known = meanings[key] { return known }
        // `top_page_1` and friends: prose, whatever the rank.
        if key.hasPrefix("top_") { return MetricMeaning(concept: .note, unit: .text) }
        return nil
    }
}
