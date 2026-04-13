import Foundation

/// A platform/metric combination that has unusually strong reach and may be
/// worth a follow-up response or promotion.
struct HighReachItem: Sendable {
    let platform: Platform
    /// Human-readable description, e.g. "Open rate 58% (good engagement – worth replying to comments)".
    let message: String
    /// A 0–1 reach score used to rank items; higher = more noteworthy.
    let score: Double
}

/// Identifies platforms with above-average or above-threshold engagement in
/// the current snapshot. Items are ranked by `score` (descending).
///
/// Uses two signals:
/// 1. **Absolute threshold**: well-known "good" benchmarks per platform/metric.
/// 2. **Relative lift**: current value beats previous run average by ≥30%.
struct HighReachDetector: Sendable {

    /// Relative lift (above previous snapshot) required to count as high reach.
    let relativeLiftThreshold: Double

    init(relativeLiftThreshold: Double = 0.30) {
        self.relativeLiftThreshold = relativeLiftThreshold
    }

    /// Returns high-reach items for the given current and optional previous snapshots.
    ///
    /// - Parameters:
    ///   - snapshots: The most recent snapshot per `PlatformInstance`.
    ///   - previousSnapshots: The second-most-recent snapshot per `PlatformInstance` (may be empty).
    /// - Returns: High-reach items sorted by score descending.
    func detect(
        snapshots: [PlatformInstance: PlatformSnapshot],
        previousSnapshots: [PlatformInstance: PlatformSnapshot] = [:]
    ) -> [HighReachItem] {
        var items: [HighReachItem] = []

        for (instance, current) in snapshots {
            let currentMetrics = (try? current.decodedMetrics()) ?? [:]
            let previousMetrics: [String: MetricValue]
            if let prev = previousSnapshots[instance] {
                previousMetrics = (try? prev.decodedMetrics()) ?? [:]
            } else {
                previousMetrics = [:]
            }

            if let item = evaluate(platform: instance.platform,
                                   currentMetrics: currentMetrics,
                                   previousMetrics: previousMetrics) {
                items.append(item)
            }
        }

        return items.sorted { $0.score > $1.score }
    }

    // MARK: - Private

    private func evaluate(
        platform: Platform,
        currentMetrics: [String: MetricValue],
        previousMetrics: [String: MetricValue]
    ) -> HighReachItem? {
        switch platform {
        case .buttondown:
            return evaluateButtondown(currentMetrics: currentMetrics,
                                      previousMetrics: previousMetrics)
        case .mastodon:
            return evaluateMastodon(currentMetrics: currentMetrics,
                                    previousMetrics: previousMetrics)
        case .bluesky:
            return evaluateBluesky(currentMetrics: currentMetrics,
                                   previousMetrics: previousMetrics)
        case .jetpack:
            return evaluateJetpack(currentMetrics: currentMetrics,
                                   previousMetrics: previousMetrics)
        case .linkedin:
            return evaluateLinkedIn(currentMetrics: currentMetrics,
                                    previousMetrics: previousMetrics)
        case .substack:
            return evaluateSubstack(currentMetrics: currentMetrics,
                                    previousMetrics: previousMetrics)
        case .goatCounter:
            return evaluateGoatCounter(currentMetrics: currentMetrics,
                                       previousMetrics: previousMetrics)
        default:
            return nil
        }
    }

    // MARK: - Per-platform evaluators

    /// Buttondown: open rate > 40% is good; click rate > 5% is excellent.
    private func evaluateButtondown(
        currentMetrics: [String: MetricValue],
        previousMetrics: [String: MetricValue]
    ) -> HighReachItem? {
        guard let openRate = currentMetrics["avg_open_rate"]?.numberValue else { return nil }
        let prevOpenRate = previousMetrics["avg_open_rate"]?.numberValue

        // Absolute threshold: >40% open rate
        let absoluteHit = openRate > 0.40
        // Relative: beats previous by ≥30%
        let relativeHit = prevOpenRate.map { openRate > $0 * (1 + relativeLiftThreshold) } ?? false

        guard absoluteHit || relativeHit else { return nil }

        let pct = String(format: "%.0f%%", openRate * 100)
        let score = min(openRate, 1.0)
        return HighReachItem(
            platform: .buttondown,
            message: "Email open rate \(pct) — strong engagement, consider replying to replies.",
            score: score
        )
    }

    /// Mastodon: avg_favourites >5 or notably above previous is high-reach.
    private func evaluateMastodon(
        currentMetrics: [String: MetricValue],
        previousMetrics: [String: MetricValue]
    ) -> HighReachItem? {
        guard let avgFavs = currentMetrics["avg_favourites"]?.numberValue else { return nil }
        let prevAvgFavs = previousMetrics["avg_favourites"]?.numberValue

        let absoluteHit = avgFavs >= 5.0
        let relativeHit = prevAvgFavs.map { avgFavs > $0 * (1 + relativeLiftThreshold) } ?? false

        guard absoluteHit || relativeHit else { return nil }

        let score = min(avgFavs / 50.0, 1.0)  // normalise: 50 favs = max score
        return HighReachItem(
            platform: .mastodon,
            message: "Avg \(String(format: "%.1f", avgFavs)) favourites per post — your audience is responding.",
            score: score
        )
    }

    /// Bluesky: avg_likes >5 or notably above previous.
    private func evaluateBluesky(
        currentMetrics: [String: MetricValue],
        previousMetrics: [String: MetricValue]
    ) -> HighReachItem? {
        guard let avgLikes = currentMetrics["avg_likes"]?.numberValue else { return nil }
        let prevAvgLikes = previousMetrics["avg_likes"]?.numberValue

        let absoluteHit = avgLikes >= 5.0
        let relativeHit = prevAvgLikes.map { avgLikes > $0 * (1 + relativeLiftThreshold) } ?? false

        guard absoluteHit || relativeHit else { return nil }

        let score = min(avgLikes / 50.0, 1.0)
        return HighReachItem(
            platform: .bluesky,
            message: "Avg \(String(format: "%.1f", avgLikes)) likes per post — worth boosting or following up.",
            score: score
        )
    }

    /// Jetpack: total_views >1000 or notably above previous.
    private func evaluateJetpack(
        currentMetrics: [String: MetricValue],
        previousMetrics: [String: MetricValue]
    ) -> HighReachItem? {
        guard let views = currentMetrics["total_views"]?.numberValue else { return nil }
        let prevViews = previousMetrics["total_views"]?.numberValue

        let absoluteHit = views >= 1000.0
        let relativeHit = prevViews.map { views > $0 * (1 + relativeLiftThreshold) } ?? false

        guard absoluteHit || relativeHit else { return nil }

        let score = min(views / 10000.0, 1.0)
        let formatted = views >= 1000 ? String(format: "%.1fK", views / 1000) : String(Int(views))
        return HighReachItem(
            platform: .jetpack,
            message: "\(formatted) blog views — strong traffic, consider promoting top posts.",
            score: score
        )
    }

    /// LinkedIn: total_impressions >500 or notably above previous.
    private func evaluateLinkedIn(
        currentMetrics: [String: MetricValue],
        previousMetrics: [String: MetricValue]
    ) -> HighReachItem? {
        guard let impressions = currentMetrics["total_impressions"]?.numberValue else { return nil }
        let prevImpressions = previousMetrics["total_impressions"]?.numberValue

        let absoluteHit = impressions >= 500.0
        let relativeHit = prevImpressions.map { impressions > $0 * (1 + relativeLiftThreshold) } ?? false

        guard absoluteHit || relativeHit else { return nil }

        let score = min(impressions / 5000.0, 1.0)
        let formatted = impressions >= 1000 ? String(format: "%.1fK", impressions / 1000) : String(Int(impressions))
        return HighReachItem(
            platform: .linkedin,
            message: "\(formatted) LinkedIn impressions — high visibility, worth engaging with comments.",
            score: score
        )
    }

    /// Substack: avg_open_rate >40% is good.
    private func evaluateSubstack(
        currentMetrics: [String: MetricValue],
        previousMetrics: [String: MetricValue]
    ) -> HighReachItem? {
        guard let openRate = currentMetrics["avg_open_rate"]?.numberValue else { return nil }
        let prevOpenRate = previousMetrics["avg_open_rate"]?.numberValue

        let absoluteHit = openRate > 0.40
        let relativeHit = prevOpenRate.map { openRate > $0 * (1 + relativeLiftThreshold) } ?? false

        guard absoluteHit || relativeHit else { return nil }

        let pct = String(format: "%.0f%%", openRate * 100)
        let score = min(openRate, 1.0)
        return HighReachItem(
            platform: .substack,
            message: "Substack open rate \(pct) — subscribers are engaged, consider a reply.",
            score: score
        )
    }

    /// GoatCounter: unique_visitors >500 or notably above previous.
    private func evaluateGoatCounter(
        currentMetrics: [String: MetricValue],
        previousMetrics: [String: MetricValue]
    ) -> HighReachItem? {
        guard let visitors = currentMetrics["unique_visitors"]?.numberValue else { return nil }
        let prevVisitors = previousMetrics["unique_visitors"]?.numberValue

        let absoluteHit = visitors >= 500.0
        let relativeHit = prevVisitors.map { visitors > $0 * (1 + relativeLiftThreshold) } ?? false

        guard absoluteHit || relativeHit else { return nil }

        let score = min(visitors / 5000.0, 1.0)
        let formatted = visitors >= 1000 ? String(format: "%.1fK", visitors / 1000) : String(Int(visitors))
        return HighReachItem(
            platform: .goatCounter,
            message: "\(formatted) unique visitors — good traffic, check which pages are driving it.",
            score: score
        )
    }
}
