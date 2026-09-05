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

    /// How large a count or average has to get before a percentage change in it
    /// is worth reporting.
    ///
    /// A percentage gate alone is meaningless on small numbers: an average
    /// favourites count moving 0.5 → 0.7 is a "40% spike". That was tolerable
    /// while spikes only appeared seconds after the user pressed Run and was
    /// looking at the screen; since #109 the background refresh fires them too,
    /// with sound, at a moment the system picks. The cost is not the noise but
    /// what it teaches — someone who learns to dismiss these stops reading the
    /// real ones, which is the whole value of the feature.
    ///
    /// Deliberately a floor on the *values* rather than on the change. A floor
    /// on the change would suppress an average moving 4 → 5, which is a real
    /// shift in engagement; what needs suppressing is 0.5 → 0.7, where the
    /// numbers are too small for any movement to mean much.
    let minimumCountMagnitude: Double

    /// The same, for rates.
    ///
    /// Rates are stored as 0–1 fractions, so the count floor would suppress all
    /// of them. Five percentage points is the equivalent scale: a click rate
    /// wobbling between 0.5% and 0.7% is noise, one moving 40% → 50% is not.
    let minimumRateMagnitude: Double

    init(threshold: Double = 20.0,
         minimumCountMagnitude: Double = 5.0,
         minimumRateMagnitude: Double = 0.05) {
        self.threshold = threshold
        self.minimumCountMagnitude = minimumCountMagnitude
        self.minimumRateMagnitude = minimumRateMagnitude
    }

    /// Whether a metric holds a 0–1 rate rather than a count.
    ///
    /// Keyed off the name because the metric vocabulary is stringly-typed
    /// (#63). A shared vocabulary carrying the unit would make this unnecessary.
    static func isRate(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return lowered.contains("rate") || lowered.contains("ctr")
    }

    /// The magnitude this metric has to reach before a change in it counts.
    func minimumMagnitude(forKey key: String) -> Double {
        Self.isRate(key) ? minimumRateMagnitude : minimumCountMagnitude
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

        let labels = metricLabels(for: platformEnum)
        var alerts: [SpikeAlert] = []

        for (key, label) in labels {
            guard let currentVal = currentMetrics[key]?.numberValue,
                  let previousVal = previousMetrics[key]?.numberValue,
                  previousVal != 0
            else { continue }

            // Both gates, not either: a large relative change between tiny
            // numbers is not news, and a small relative change between large
            // ones is not either.
            guard max(abs(currentVal), abs(previousVal)) >= minimumMagnitude(forKey: key)
            else { continue }

            let pctChange = abs(((currentVal - previousVal) / abs(previousVal)) * 100)
            guard pctChange >= threshold else { continue }

            alerts.append(SpikeAlert(
                platform: platformEnum,
                instanceName: current.instanceName,
                metricLabel: label,
                metricKey: key,
                previousValue: previousVal,
                currentValue: currentVal
            ))
        }

        // Sort by magnitude (largest change first).
        return alerts.sorted { abs($0.percentChange) > abs($1.percentChange) }
    }

    // MARK: - Private

    /// Returns the (key, display label) pairs to monitor for spikes per platform.
    /// Intentionally tracks only the primary "health" metrics to avoid noise.
    private func metricLabels(for platform: Platform) -> [(key: String, label: String)] {
        switch platform {
        case .mastodon:
            return [("followers_count", "Followers"),
                    ("avg_favourites", "Avg Favourites"),
                    ("avg_reblogs", "Avg Reblogs")]
        case .bluesky:
            return [("followers_count", "Followers"),
                    ("avg_likes", "Avg Likes"),
                    ("avg_reposts", "Avg Reposts")]
        case .buttondown:
            return [("subscriber_count", "Subscribers"),
                    ("avg_open_rate", "Open Rate"),
                    ("avg_click_rate", "Click Rate")]
        case .goatCounter:
            return [("total_pageviews", "Pageviews"),
                    ("unique_visitors", "Visitors")]
        case .calendly:
            return [("events_count", "Events"),
                    ("unique_invitees", "Invitees")]
        case .jetpack:
            return [("followers_blog", "Followers"),
                    ("total_views", "Views"),
                    ("total_visitors", "Visitors")]
        case .amazon:
            return [("units_sold", "Units Sold"),
                    ("royalties_usd", "Royalties"),
                    ("kenp_pages_read", "KENP Pages Read")]
        case .linkedin:
            return [("total_impressions", "Impressions"),
                    ("total_likes", "Likes")]
        case .oreilly:
            return [("total_page_views", "Page Views"),
                    ("total_unique_users", "Unique Users")]
        case .substack:
            return [("posts_published", "Posts Published"),
                    ("avg_open_rate", "Avg Open Rate")]
        case .googleSearchConsole:
            return [("clicks", "Clicks"),
                    ("impressions", "Impressions"),
                    ("ctr", "CTR"),
                    ("avg_position", "Avg Position")]
        case .buffer:
            return [("sent_updates", "Sent Updates"),
                    ("total_clicks", "Clicks"),
                    ("total_reach", "Reach")]
        case .hackerNews:
            return [("mention_count", "Mentions"),
                    ("total_points", "Points")]
        }
    }
}

