import Foundation

/// A metric that changed significantly between two consecutive collection runs.
struct SpikeAlert: Sendable {
    /// The platform the metric belongs to.
    let platform: Platform
    /// Which instance of that platform. Two Mastodon accounts both spiking
    /// otherwise produce two identical-looking notification lines, and the
    /// notification is the one surface where the user has no other context.
    let instanceName: String
    /// Human-readable metric name (e.g. "Followers").
    let metricLabel: String
    /// The raw metric key used in `[String: MetricValue]` dictionaries.
    let metricKey: String
    /// Previous value (from the older snapshot).
    let previousValue: Double
    /// Current value (from the newer snapshot).
    let currentValue: Double

    /// Percentage change, positive = increase, negative = decrease.
    var percentChange: Double {
        guard previousValue != 0 else { return currentValue > 0 ? 100 : 0 }
        return ((currentValue - previousValue) / abs(previousValue)) * 100
    }

    var isIncrease: Bool { currentValue >= previousValue }

    /// A short human-readable description, e.g. "+23.4% Followers on Mastodon".
    var summary: String {
        let sign = isIncrease ? "+" : ""
        let source = instanceName == "default"
            ? platform.displayName
            : "\(platform.displayName) (\(instanceName))"
        return "\(sign)\(String(format: "%.1f", percentChange))% \(metricLabel) on \(source)"
    }
}

/// Compares the two most recent snapshots for each platform and surfaces
/// metrics that changed by at least `threshold` percent.
struct SpikeDetector: Sendable {

    /// The minimum absolute percentage change required to surface a spike (default 20%).
    let threshold: Double

    init(threshold: Double = 20.0) {
        self.threshold = threshold
    }

    /// One metric worth watching, and how large it has to be before a
    /// percentage change in it means anything.
    private struct Monitored {
        let key: String
        let label: String
        /// The floor, in the metric's own units. Zero means no floor.
        ///
        /// A percentage gate alone is meaningless on small numbers: an average
        /// favourites count moving 0.5 → 0.7 is a "40% spike". That was
        /// tolerable while spikes only appeared seconds after the user pressed
        /// Run and was looking at the screen; since #109 the background refresh
        /// fires them too, with sound, at a moment the system picks. The cost
        /// is not the noise but what it teaches — someone who learns to dismiss
        /// these stops reading the real ones, which is the whole value of the
        /// feature.
        ///
        /// The floor is per metric because the metrics are not on one scale,
        /// and a single global floor gets most of them wrong. Three families:
        ///
        /// - **Averages** (`avg_favourites` and friends) carry the floor. They
        ///   are derived from a handful of posts, so movement below a few
        ///   favourites per post is arithmetic, not audience.
        /// - **Rates** are 0–1 fractions, so any count-sized floor would mute
        ///   every one of them. One percentage point is the equivalent scale.
        /// - **Raw counts of discrete events** get no floor. Each unit is a
        ///   real thing that happened: selling 1 book then 4 is news, and so is
        ///   three Hacker News mentions dropping to none. This is the case an
        ///   earlier version of this change got wrong, muting both.
        var floor: Double = 0
    }

    /// Returns spike alerts for all numeric metrics that changed significantly
    /// between `previous` and `current`.
    ///
    /// - Parameters:
    ///   - current: The newer snapshot.
    ///   - previous: The older snapshot.
    /// - Returns: An array of `SpikeAlert` values, one per significant metric change.
    func detect(current: PlatformSnapshot, previous: PlatformSnapshot) -> [SpikeAlert] {
        guard let platformEnum = current.platformEnum else { return [] }

        let currentMetrics = (try? current.decodedMetrics()) ?? [:]
        let previousMetrics = (try? previous.decodedMetrics()) ?? [:]

        var alerts: [SpikeAlert] = []

        for metric in Self.monitored(for: platformEnum) {
            guard let currentVal = currentMetrics[metric.key]?.numberValue,
                  let previousVal = previousMetrics[metric.key]?.numberValue,
                  previousVal != 0
            else { continue }

            // Both gates, not either: a large relative change between tiny
            // numbers is not news, and a small relative change between large
            // ones is not either. Whichever side is bigger decides, so a
            // collapse to zero still reports.
            guard max(abs(currentVal), abs(previousVal)) >= metric.floor else { continue }

            let pctChange = abs(((currentVal - previousVal) / abs(previousVal)) * 100)
            guard pctChange >= threshold else { continue }

            alerts.append(SpikeAlert(
                platform: platformEnum,
                instanceName: current.instanceName,
                metricLabel: metric.label,
                metricKey: metric.key,
                previousValue: previousVal,
                currentValue: currentVal
            ))
        }

        // Sort by magnitude (largest change first).
        return alerts.sorted { abs($0.percentChange) > abs($1.percentChange) }
    }

    // MARK: - Private

    /// How small an average engagement number can get before a percentage
    /// change in it stops meaning anything. A judgement call, not a measurement
    /// — but below three favourites per post, one extra favourite is a 30%
    /// "spike", and that is the noise this exists to stop.
    ///
    /// Deliberately not shared with `HighReachDetector`'s 5.0, which answers a
    /// different question: that is the bar for engagement being *good*, this is
    /// the bar for it being *readable*.
    private static let averageFloor = 3.0

    /// Rates are stored as 0–1 fractions. One percentage point: a click rate
    /// wobbling between 0.5% and 0.7% is noise, a search CTR moving 2% → 3.5%
    /// is not. The two bracket this value, which is the only reason it is 0.01
    /// and not something rounder.
    private static let rateFloor = 0.01

    /// The metrics to watch per platform. Intentionally only the primary
    /// "health" metrics, to avoid noise.
    private static func monitored(for platform: Platform) -> [Monitored] {
        switch platform {
        case .mastodon:
            return [Monitored(key: "followers_count", label: "Followers"),
                    Monitored(key: "avg_favourites", label: "Avg Favourites", floor: averageFloor),
                    Monitored(key: "avg_reblogs", label: "Avg Reblogs", floor: averageFloor)]
        case .bluesky:
            return [Monitored(key: "followers_count", label: "Followers"),
                    Monitored(key: "avg_likes", label: "Avg Likes", floor: averageFloor),
                    Monitored(key: "avg_reposts", label: "Avg Reposts", floor: averageFloor)]
        case .buttondown:
            return [Monitored(key: "subscriber_count", label: "Subscribers"),
                    Monitored(key: "avg_open_rate", label: "Open Rate", floor: rateFloor),
                    Monitored(key: "avg_click_rate", label: "Click Rate", floor: rateFloor)]
        case .goatCounter:
            return [Monitored(key: "total_pageviews", label: "Pageviews"),
                    Monitored(key: "unique_visitors", label: "Visitors")]
        case .calendly:
            return [Monitored(key: "events_count", label: "Events"),
                    Monitored(key: "unique_invitees", label: "Invitees")]
        case .jetpack:
            return [Monitored(key: "followers_blog", label: "Followers"),
                    Monitored(key: "total_views", label: "Views"),
                    Monitored(key: "total_visitors", label: "Visitors")]
        case .amazon:
            return [Monitored(key: "units_sold", label: "Units Sold"),
                    Monitored(key: "royalties_usd", label: "Royalties"),
                    Monitored(key: "kenp_pages_read", label: "KENP Pages Read")]
        case .linkedin:
            return [Monitored(key: "total_impressions", label: "Impressions"),
                    Monitored(key: "total_likes", label: "Likes")]
        case .oreilly:
            return [Monitored(key: "total_page_views", label: "Page Views"),
                    Monitored(key: "total_unique_users", label: "Unique Users")]
        case .substack:
            return [Monitored(key: "posts_published", label: "Posts Published"),
                    Monitored(key: "avg_open_rate", label: "Avg Open Rate", floor: rateFloor)]
        case .googleSearchConsole:
            // avg_position is a rank, so it gets no floor: small is the *best*
            // state, and a floor would mute exactly the good news (4 → 3) while
            // letting 60 → 45 through.
            return [Monitored(key: "clicks", label: "Clicks"),
                    Monitored(key: "impressions", label: "Impressions"),
                    Monitored(key: "ctr", label: "CTR", floor: rateFloor),
                    Monitored(key: "avg_position", label: "Avg Position")]
        case .buffer:
            return [Monitored(key: "sent_updates", label: "Sent Updates"),
                    Monitored(key: "total_clicks", label: "Clicks"),
                    Monitored(key: "total_reach", label: "Reach")]
        case .hackerNews:
            return [Monitored(key: "mention_count", label: "Mentions"),
                    Monitored(key: "total_points", label: "Points")]
        }
    }
}
