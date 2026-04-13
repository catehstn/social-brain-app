import Foundation

/// A metric that changed significantly between two consecutive collection runs.
struct SpikeAlert: Sendable {
    /// The platform the metric belongs to.
    let platform: Platform
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
        return "\(sign)\(String(format: "%.1f", percentChange))% \(metricLabel) on \(platform.displayName)"
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

            let pctChange = abs(((currentVal - previousVal) / abs(previousVal)) * 100)
            guard pctChange >= threshold else { continue }

            alerts.append(SpikeAlert(
                platform: platformEnum,
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
        case .vercel:
            return [("deployments", "Deployments"),
                    ("error_deployments", "Errors")]
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
        }
    }
}

