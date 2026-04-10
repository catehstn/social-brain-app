import Foundation

/// Staleness thresholds per platform.
enum StalenessThreshold {
    static let threeDays: TimeInterval   = 3  * 24 * 3600
    static let thirtyDays: TimeInterval  = 30 * 24 * 3600

    static func threshold(for platform: Platform) -> TimeInterval? {
        switch platform {
        case .linkedin, .substack:  return threeDays
        case .amazon, .oreilly:     return thirtyDays
        default:                    return nil
        }
    }
}

/// Builds the ordered list of FeedCards from latest snapshots.
struct FeedCardBuilder {

    private static let maxSnippetLength = 280

    // NOTE: This function does NOT throw — all JSON decoding is done
    // with `try?` internally.  The signature is non-throwing so callers don't
    // need spurious `try` and tests don't need `throws`.
    static func build(
        snapshots: [Platform: PlatformSnapshot],
        previousSnapshots: [Platform: PlatformSnapshot] = [:],
        now: Date = Date()
    ) -> [FeedCard] {
        var cards: [FeedCard] = []

        // 0. Spike alerts (highest priority after stale — notable changes need attention)
        let detector = SpikeDetector()
        for platform in Platform.allCases {
            guard let current = snapshots[platform],
                  let previous = previousSnapshots[platform]
            else { continue }
            let alerts = detector.detect(current: current, previous: previous)
            // Show the top spike (highest magnitude) per platform to avoid noise.
            if let top = alerts.first {
                cards.append(FeedCard(
                    platform: platform,
                    cardType: .spikeAlert,
                    snippet: top.summary,
                    navigationTarget: platform
                ))
            }
        }

        // 1. Stale reminders (highest priority — user needs to act)
        for platform in [Platform.linkedin, .substack, .amazon, .oreilly] {
            guard let threshold = StalenessThreshold.threshold(for: platform) else { continue }
            if let snapshot = snapshots[platform] {
                if now.timeIntervalSince(snapshot.collectedAt) > threshold {
                    cards.append(FeedCard(
                        platform: platform,
                        cardType: .staleReminder,
                        snippet: "Your \(platform.rawValue) data is stale — re-export to update.",
                        navigationTarget: platform
                    ))
                }
            } else {
                // Never collected → always stale
                cards.append(FeedCard(
                    platform: platform,
                    cardType: .staleReminder,
                    snippet: "No \(platform.rawValue) data yet — export a file to get started.",
                    navigationTarget: platform
                ))
            }
        }

        // 2. Upcoming events from Calendly
        if let snapshot = snapshots[.calendly],
           let data = try? JSONDecoder().decode(CalendlyData.self, from: snapshot.metricsJSON),
           !data.upcomingEventTitles.isEmpty {
            let titles = data.upcomingEventTitles.prefix(3).joined(separator: ", ")
            cards.append(FeedCard(
                platform: .calendly,
                cardType: .upcomingEvent,
                snippet: truncate("Upcoming: \(titles)"),
                navigationTarget: .calendly
            ))
        }

        // 3. Recent posts — platforms with text content in latest snapshot
        let postPlatforms: [Platform] = [.mastodon, .bluesky, .buttondown, .jetpack,
                                          .linkedin, .substack]
        for platform in postPlatforms {
            guard let snapshot = snapshots[platform] else { continue }
            if let text = latestPostText(platform: platform, data: snapshot.metricsJSON) {
                cards.append(FeedCard(
                    platform: platform,
                    cardType: .recentPost,
                    snippet: truncate(text),
                    navigationTarget: platform
                ))
            }
        }

        // 4. Metric highlights — platform with engagement notably above baseline
        let engagementCandidates: [Platform] = [.mastodon, .bluesky, .buttondown, .jetpack]
        let engagementPlatforms: [(Platform, Double)] = engagementCandidates.compactMap { p in
            guard let snapshot = snapshots[p],
                  let rate = engagementRate(platform: p, data: snapshot.metricsJSON)
            else { return nil }
            return (p, rate)
        }
        if let best = engagementPlatforms.max(by: { $0.1 < $1.1 }) {
            let pct = String(format: "%.1f%%", best.1 * 100)
            cards.append(FeedCard(
                platform: best.0,
                cardType: .metricHighlight,
                snippet: "\(best.0.rawValue.capitalized) engagement at \(pct) — your best this period.",
                navigationTarget: best.0
            ))
        }

        // 5. High-reach items — platforms with above-threshold or notably lifted engagement
        //    ranked by reach score; de-duplicated with spikeAlert cards (don't show both).
        let spikeAlertPlatforms = Set(cards.filter { $0.cardType == .spikeAlert }.map(\.platform))
        let highReachItems = HighReachDetector().detect(
            snapshots: snapshots,
            previousSnapshots: previousSnapshots
        )
        for item in highReachItems {
            // Skip if we already have a spike card for this platform (avoids duplicate messaging).
            guard !spikeAlertPlatforms.contains(item.platform) else { continue }
            cards.append(FeedCard(
                platform: item.platform,
                cardType: .highReach,
                snippet: item.message,
                navigationTarget: item.platform
            ))
        }

        return cards
    }

    // MARK: - Private helpers

    static func truncate(_ text: String, limit: Int = maxSnippetLength) -> String {
        guard text.count > limit else { return text }
        // Word-boundary truncation
        let prefix = text.prefix(limit)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }

    // Extracts a human-readable post/subject snippet from the raw metrics JSON.
    // Supports both the typed FeedPlatformData structs (used in tests) and the
    // production [String: MetricValue] format used by the real collectors.
    private static func latestPostText(platform: Platform, data: Data) -> String? {
        switch platform {
        case .mastodon:
            // Try typed struct first (test fixtures), then production metric key
            if let d = try? JSONDecoder().decode(MastodonData.self, from: data) {
                return d.latestPostText
            }
            return metricString("latest_post_text", from: data)
        case .bluesky:
            if let d = try? JSONDecoder().decode(BlueskyData.self, from: data) {
                return d.latestPostText
            }
            return metricString("latest_post_text", from: data)
        case .buttondown:
            if let d = try? JSONDecoder().decode(ButtondownData.self, from: data) {
                return d.latestSubjectLine
            }
            return metricString("latest_subject_line", from: data)
        case .jetpack:
            if let d = try? JSONDecoder().decode(JetpackData.self, from: data) {
                return d.latestPostTitle
            }
            return metricString("latest_post_title", from: data)
        case .linkedin:
            if let d = try? JSONDecoder().decode(LinkedInData.self, from: data) {
                return d.latestPostText
            }
            return metricString("latest_post_text", from: data)
        case .substack:
            if let d = try? JSONDecoder().decode(SubstackData.self, from: data) {
                return d.latestSubjectLine
            }
            return metricString("latest_subject_line", from: data)
        default:
            return nil
        }
    }

    private static func engagementRate(platform: Platform, data: Data) -> Double? {
        switch platform {
        case .mastodon:
            if let d = try? JSONDecoder().decode(MastodonData.self, from: data) {
                return d.engagementRate
            }
            return metricDouble("engagement_rate", from: data)
        case .bluesky:
            if let d = try? JSONDecoder().decode(BlueskyData.self, from: data) {
                return d.engagementRate
            }
            return metricDouble("engagement_rate", from: data)
        case .buttondown:
            if let d = try? JSONDecoder().decode(ButtondownData.self, from: data) {
                return d.openRate
            }
            return metricDouble("avg_open_rate", from: data)
        case .jetpack:
            if let d = try? JSONDecoder().decode(JetpackData.self, from: data) {
                return d.engagementRate
            }
            return metricDouble("engagement_rate", from: data)
        default:
            return nil
        }
    }

    // MARK: - MetricValue dictionary helpers

    private static func metricString(_ key: String, from data: Data) -> String? {
        guard let dict = try? JSONDecoder().decode([String: MetricValue].self, from: data) else {
            return nil
        }
        return dict[key]?.stringValue
    }

    private static func metricDouble(_ key: String, from data: Data) -> Double? {
        guard let dict = try? JSONDecoder().decode([String: MetricValue].self, from: data) else {
            return nil
        }
        return dict[key]?.numberValue
    }
}
