import Foundation

/// Every metric key the app writes or reads, in one place.
///
/// A metric key is a string in a `[String: MetricValue]` dictionary: one
/// collector writes it, and up to five consumers read it — `PromptAssembler`,
/// `DashboardViewModel`, `SpikeDetector`, `HighReachDetector` and
/// `FeedCardBuilder`. Spelled as literals at both ends, a rename moved one end
/// and left the other reading a key nobody writes. The import still succeeded
/// and the platform silently contributed nothing: #114, #163 and #170 are three
/// separate times that happened, and #171 is the mirror image.
///
/// Written through these constants, a rename is one edit that both ends
/// follow, and a typo does not compile. `MetricKeyLiteralTests` is what keeps
/// it that way: it fails on a metric-shaped literal anywhere in the app or MCP
/// sources outside this file.
///
/// **The values are a wire format.** They are the keys inside the JSON blob in
/// `platformSnapshot.metrics`, so every row ever collected holds the old
/// spelling. Renaming a value here makes stored history unreadable for that
/// metric, which no test can catch — the charts just stop before today. Add a
/// constant rather than rename one unless you mean to abandon the history.
///
/// **These are names, not meanings.** `total_clicks` is LinkedIn's and
/// Buffer's; `followers_count`, `total_followers`, `followers_blog` and
/// `subscriber_count` are four spellings of one idea, which is why nothing can
/// compare across platforms and why "best engagement" compares an open rate
/// with an engagement rate (#81). Giving each key a meaning and a unit is the
/// second half of #63 and is not attempted here.
enum MetricKey {

    // MARK: - Audience

    static let followersCount   = "followers_count"     // Mastodon, Bluesky
    static let followingCount   = "following_count"     // Mastodon
    static let followsCount     = "follows_count"       // Bluesky
    static let totalFollowers   = "total_followers"     // LinkedIn (XLSX)
    static let newFollowers     = "new_followers"       // LinkedIn (XLSX)
    static let followersBlog    = "followers_blog"      // Jetpack
    static let followersComment = "followers_comment"   // Jetpack
    static let subscriberCount  = "subscriber_count"    // Buttondown
    static let newSubscribers   = "new_subscribers"     // Buttondown
    static let membersReached   = "members_reached"     // LinkedIn (XLSX)

    // MARK: - Volume

    static let postsCount        = "posts_count"        // Bluesky
    static let statusesCount     = "statuses_count"     // Mastodon
    static let postsPublished    = "posts_published"    // LinkedIn, Substack
    static let recentPosts       = "recent_posts"       // Mastodon, Bluesky
    static let sentUpdates       = "sent_updates"       // Buffer
    static let scheduledUpdates  = "scheduled_updates"  // Buffer
    static let emailsSent        = "emails_sent"        // Buttondown
    static let eventsCount       = "events_count"       // Calendly
    static let cancelledCount    = "cancelled_count"    // Calendly
    static let uniqueInvitees    = "unique_invitees"    // Calendly
    static let profilesCount     = "profiles_count"     // Buffer
    static let titlesCount       = "titles_count"       // O'Reilly
    static let mentionCount      = "mention_count"      // Hacker News

    // MARK: - Reach

    static let totalViews      = "total_views"        // Jetpack
    static let totalVisitors   = "total_visitors"     // Jetpack
    static let totalVisits     = "total_visits"       // GoatCounter
    static let totalPageViews   = "total_page_views"  // O'Reilly
    static let totalUniqueUsers = "total_unique_users" // O'Reilly
    static let totalImpressions = "total_impressions" // LinkedIn
    static let impressions      = "impressions"       // Google Search Console
    static let totalReach       = "total_reach"       // Buffer

    // MARK: - Engagement

    static let totalLikes       = "total_likes"        // Jetpack, LinkedIn, Buffer
    static let totalComments    = "total_comments"     // Jetpack, LinkedIn, Hacker News
    static let totalShares      = "total_shares"       // LinkedIn
    static let totalClicks      = "total_clicks"       // LinkedIn, Buffer
    static let clicks           = "clicks"             // Google Search Console
    static let totalEngagements = "total_engagements"  // LinkedIn (XLSX)
    static let totalPoints      = "total_points"       // Hacker News
    static let totalCompletions = "total_completions"  // O'Reilly

    // MARK: - Rates and averages

    static let avgOpenRate   = "avg_open_rate"   // Buttondown, Substack
    static let avgClickRate  = "avg_click_rate"  // Buttondown, Substack
    static let avgCTR        = "avg_ctr"         // LinkedIn
    static let ctr           = "ctr"             // Google Search Console
    static let avgPosition   = "avg_position"    // Google Search Console
    static let avgLikes      = "avg_likes"       // Bluesky
    static let avgReplies    = "avg_replies"     // Mastodon, Bluesky
    static let avgReposts    = "avg_reposts"     // Bluesky
    static let avgFavourites = "avg_favourites"  // Mastodon
    static let avgReblogs    = "avg_reblogs"     // Mastodon

    // MARK: - Notes
    //
    // Strings rather than numbers, rendered as "Note:" lines in the prompt.
    // They exist because a silently clamped or truncated read looks exactly
    // like a quiet period (#96, #114).

    static let postsTruncated        = "posts_truncated"        // Mastodon, Bluesky
    static let postsSampled          = "posts_sampled"          // Buffer
    static let emailsSampled         = "emails_sampled"         // Buttondown
    static let mentionsSampled       = "mentions_sampled"       // Hacker News
    static let viewsWindow           = "views_window"           // Jetpack
    static let engagementUnavailable = "engagement_unavailable" // Buffer

    // MARK: - Read, but emitted by nothing (#171)
    //
    // Consumers that ask for keys no collector writes. Listed here so they are
    // visible rather than buried as literals: a reader with no writer is dead
    // code that reads as a feature. #171 decides, per key, whether to emit it
    // or delete the reader; this file only stops them being invisible.

    static let latestPostText    = "latest_post_text"    // FeedCardBuilder fallback
    static let latestPostTitle   = "latest_post_title"   // FeedCardBuilder fallback
    static let latestSubjectLine = "latest_subject_line" // FeedCardBuilder fallback
    static let engagementRate    = "engagement_rate"     // FeedCardBuilder fallback
    static let paidSubscribers   = "paid_subscribers"    // PromptAssembler, Substack section

    // MARK: - Numbered families
    //
    // `top_page_1`, `top_page_2`, … Collectors emit as many as they have;
    // consumers read a fixed few. The number is part of the key, so these are
    // functions rather than constants — and `MetricKeyOrphanTests` treats one
    // member as standing for the family.

    static func topPage(_ rank: Int) -> String      { "top_page_\(rank)" }
    static func topQuery(_ rank: Int) -> String     { "top_query_\(rank)" }
    static func topStory(_ rank: Int) -> String     { "top_story_\(rank)" }
    static func topProfile(_ rank: Int) -> String   { "top_profile_\(rank)" }
    static func topEventType(_ rank: Int) -> String { "top_event_type_\(rank)" }
}
