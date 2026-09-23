import Foundation

/// Staleness thresholds per platform.
enum StalenessThreshold {
    static let threeDays: TimeInterval   = 3  * 24 * 3600
    static let thirtyDays: TimeInterval  = 30 * 24 * 3600

    static func threshold(for platform: Platform) -> TimeInterval? {
        switch platform {
        case .linkedin, .substack:  return threeDays
        case .oreilly:              return thirtyDays
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
    /// - Parameter visibility: consulted at the point of use. Hiding a platform
    ///   used to change only the Platforms grid, so the feed went on nagging
    ///   about a platform the user had said they don't use — worst of all for
    ///   the stale-export reminders, whose whole message is "go and do
    ///   something about this" (#80). No default: it was `.shared`, which
    ///   made every test that omitted it depend on the developer's own hidden
    ///   platforms (#184).
    static func build(
        snapshots: [PlatformInstance: PlatformSnapshot],
        previousSnapshots: [PlatformInstance: PlatformSnapshot] = [:],
        now: Date = Date(),
        visibility: PlatformVisibilityStore
    ) -> [FeedCard] {
        // Filtered on the way in *and* on the way out, and both are needed.
        //
        // On the way in, because two blocks below aggregate across platforms
        // rather than emitting one card each: the metric highlight picks a
        // single winner with `max`, and the high-reach block de-duplicates
        // against the spike cards already built. Filtering only at the exit
        // lets a hidden platform win the highlight and then be dropped, so
        // "your best this period" disappears altogether instead of going to the
        // best *visible* platform.
        //
        // On the way out, because the stale-reminder block iterates a fixed
        // list of file-export platforms rather than the snapshots, so a hidden
        // platform with no snapshot at all still reaches it.
        // Only the current snapshots need filtering. Every use of
        // `previousSnapshots` is a lookup keyed by an instance that came from
        // `snapshots`, so a hidden platform cannot reach a card through it.
        let snapshots = visibility.visible(snapshots)

        var cards: [FeedCard] = []

        // 0. Spike alerts (highest priority after stale — notable changes need attention)
        let detector = SpikeDetector()
        for (instance, current) in snapshots {
            guard let previous = previousSnapshots[instance] else { continue }
            let alerts = detector.detect(current: current, previous: previous)
            // Show the top spike (highest magnitude) per instance to avoid noise.
            if let top = alerts.first {
                cards.append(FeedCard(
                    platform: instance.platform,
                    instanceName: instance.instanceName,
                    cardType: .spikeAlert,
                    snippet: top.summary,
                    navigationTarget: instance.platform
                ))
            }
        }

        // 1. Stale reminders (highest priority — user needs to act)
        // Check default instance for each file-export platform.
        for platform in [Platform.linkedin, .substack, .oreilly] {
            guard let threshold = StalenessThreshold.threshold(for: platform) else { continue }
            let defaultInstance = PlatformInstance(platform: platform)
            if let snapshot = snapshots[defaultInstance] {
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

        // 2. Upcoming events from Calendly (default instance only)
        let calendlyInstance = PlatformInstance(platform: .calendly)
        if let snapshot = snapshots[calendlyInstance],
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
        for (instance, snapshot) in snapshots {
            guard postPlatforms.contains(instance.platform) else { continue }
            if let text = latestPostText(platform: instance.platform, data: snapshot.metricsJSON) {
                cards.append(FeedCard(
                    platform: instance.platform,
                    instanceName: instance.instanceName,
                    cardType: .recentPost,
                    snippet: truncate(text),
                    navigationTarget: instance.platform
                ))
            }
        }

        // 4. Metric highlights — the best rate of each kind
        //
        // Grouped by what the rate *is*, because ranking them together was
        // nonsense: Buttondown contributes an open rate (0.4–0.7 on a healthy
        // newsletter) and everyone else an engagement rate (0.01–0.03 on a
        // healthy account), so `max` picked Buttondown whenever it had data and
        // the card said nothing (#81). `MetricMeaning` is what makes the two
        // distinguishable rather than both being "a Double".
        let rateEntries: [(instance: PlatformInstance, concept: MetricMeaning.Concept, rate: Double)] =
            snapshots.compactMap { (instance, snapshot) in
                guard let rate = engagementRate(platform: instance.platform, data: snapshot.metricsJSON),
                      let concept = rateConcept(for: instance.platform)
                else { return nil }
                return (instance, concept, rate)
            }
        // One card per kind of rate, so a newsletter's open rate no longer
        // buries a social account's engagement, and both are described as what
        // they are. Only the rate concepts, in a fixed order: iterating every
        // concept would ask for a "best audience rate", and `rateName` would
        // cheerfully render it.
        for concept in Self.rateConcepts {
            let ofThisKind = rateEntries.filter { $0.concept == concept }
            guard let best = ofThisKind.max(by: { $0.rate < $1.rate }),
                  let name = Self.rateName(concept) else { continue }
            let pct = String(format: "%.1f%%", best.rate * 100)
            cards.append(FeedCard(
                platform: best.instance.platform,
                instanceName: best.instance.instanceName,
                cardType: .metricHighlight,
                snippet: "\(best.instance.platform.rawValue.capitalized) \(name) at \(pct) — your best this period.",
                navigationTarget: best.instance.platform
            ))
        }

        // 5. High-reach items — instances with above-threshold or notably lifted engagement
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

        // Catches the blocks that work from a fixed platform list rather than
        // from `snapshots` — the stale reminders — and anything added later
        // that does the same.
        return cards.filter { !visibility.isHidden($0.platform) }
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
            return metricString(MetricKey.latestPostText, from: data)
        case .bluesky:
            if let d = try? JSONDecoder().decode(BlueskyData.self, from: data) {
                return d.latestPostText
            }
            return metricString(MetricKey.latestPostText, from: data)
        case .buttondown:
            if let d = try? JSONDecoder().decode(ButtondownData.self, from: data) {
                return d.latestSubjectLine
            }
            return metricString(MetricKey.latestSubjectLine, from: data)
        case .jetpack:
            if let d = try? JSONDecoder().decode(JetpackData.self, from: data) {
                return d.latestPostTitle
            }
            return metricString(MetricKey.latestPostTitle, from: data)
        case .linkedin:
            if let d = try? JSONDecoder().decode(LinkedInData.self, from: data) {
                return d.latestPostText
            }
            return metricString(MetricKey.latestPostText, from: data)
        case .substack:
            if let d = try? JSONDecoder().decode(SubstackData.self, from: data) {
                return d.latestSubjectLine
            }
            return metricString(MetricKey.latestSubjectLine, from: data)
        default:
            return nil
        }
    }

    /// The rates a highlight card can be about, in the order they appear.
    static let rateConcepts: [MetricMeaning.Concept] = [.engagementRate, .openRate]

    /// Which rate `engagementRate(platform:data:)` returns for a platform.
    ///
    /// It returns Buttondown's *open* rate, which is the whole point: the
    /// function name has always been a lie about one of its branches.
    static func rateConcept(for platform: Platform) -> MetricMeaning.Concept? {
        switch platform {
        case .mastodon, .bluesky, .jetpack: .engagementRate
        case .buttondown:                   .openRate
        default:                            nil
        }
    }

    /// How a rate reads in a sentence.
    ///
    /// Total, over `rateConcepts` rather than every concept, so adding a rate
    /// without a name is a compile error rather than a card reading
    /// "Mastodon audience at 3.0%".
    static func rateName(_ concept: MetricMeaning.Concept) -> String? {
        switch concept {
        case .engagementRate: "engagement"
        case .openRate:       "open rate"
        default:              nil
        }
    }

    static func engagementRate(platform: Platform, data: Data) -> Double? {
        switch platform {
        case .mastodon:
            if let d = try? JSONDecoder().decode(MastodonData.self, from: data) {
                return d.engagementRate
            }
            return metricDouble(MetricKey.engagementRate, from: data)
        case .bluesky:
            if let d = try? JSONDecoder().decode(BlueskyData.self, from: data) {
                return d.engagementRate
            }
            return metricDouble(MetricKey.engagementRate, from: data)
        case .buttondown:
            if let d = try? JSONDecoder().decode(ButtondownData.self, from: data) {
                return d.openRate
            }
            return metricDouble(MetricKey.avgOpenRate, from: data)
        case .jetpack:
            if let d = try? JSONDecoder().decode(JetpackData.self, from: data) {
                return d.engagementRate
            }
            return metricDouble(MetricKey.engagementRate, from: data)
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
