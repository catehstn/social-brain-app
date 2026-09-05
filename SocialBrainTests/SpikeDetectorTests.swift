import Testing
import Foundation
@testable import SocialBrain

@Suite("Spike Detector Tests")
struct SpikeDetectorTests {

    // MARK: - Helpers

    /// Creates a PlatformSnapshot with the given metrics for test purposes.
    private func makeSnapshot(
        platform: Platform,
        metrics: [String: MetricValue],
        collectedAt: Date = Date()
    ) throws -> PlatformSnapshot {
        let data = PlatformData(
            platform: platform,
            collectedAt: collectedAt,
            metrics: metrics
        )
        return try PlatformSnapshot(runID: 1, data: data)
    }

    // MARK: - detect() tests

    @Test("no spikes when metrics unchanged")
    func noSpikesWhenMetricsUnchanged() throws {
        let metrics: [String: MetricValue] = ["followers_count": .int(1000)]
        let current  = try makeSnapshot(platform: .mastodon, metrics: metrics)
        let previous = try makeSnapshot(platform: .mastodon, metrics: metrics)

        let detector = SpikeDetector(threshold: 20)
        let alerts = detector.detect(current: current, previous: previous)
        #expect(alerts.isEmpty)
    }

    @Test("spike detected on 25% increase")
    func spikeDetectedOnIncrease() throws {
        let previous = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(1000)])
        let current  = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(1250)])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        #expect(alerts.count == 1)
        #expect(alerts[0].metricKey == "followers_count")
        #expect(alerts[0].isIncrease)
        #expect(abs(alerts[0].percentChange - 25.0) < 0.01)
    }

    @Test("spike detected on 30% decrease")
    func spikeDetectedOnDecrease() throws {
        let previous = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(1000)])
        let current  = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(700)])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        #expect(alerts.count == 1)
        #expect(!alerts[0].isIncrease)
        #expect(abs(alerts[0].percentChange - (-30.0)) < 0.01)
    }

    @Test("no spike when change is below threshold")
    func noSpikeBelow20Percent() throws {
        let previous = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(1000)])
        let current  = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(1100)])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        #expect(alerts.isEmpty)
    }

    @Test("exactly at threshold is included")
    func exactlyAtThresholdIsIncluded() throws {
        let previous = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(1000)])
        let current  = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(1200)])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        #expect(alerts.count == 1)
    }

    @Test("string metrics are ignored")
    func stringMetricsIgnored() throws {
        let previous = try makeSnapshot(platform: .mastodon,
                                        metrics: ["latest_post_text": .string("old post")])
        let current  = try makeSnapshot(platform: .mastodon,
                                        metrics: ["latest_post_text": .string("new post")])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        #expect(alerts.isEmpty)
    }

    @Test("metric missing from previous is skipped")
    func metricMissingFromPreviousSkipped() throws {
        let previous = try makeSnapshot(platform: .mastodon, metrics: [:])
        let current  = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(500)])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        #expect(alerts.isEmpty)
    }

    @Test("previous value zero is skipped")
    func previousValueZeroIsSkipped() throws {
        let previous = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(0)])
        let current  = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(500)])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        #expect(alerts.isEmpty)
    }

    @Test("results sorted by magnitude descending")
    func resultsSortedByMagnitude() throws {
        // followers +50%, avg_favourites +25%
        let previous = try makeSnapshot(platform: .mastodon, metrics: [
            "followers_count": .int(1000),
            "avg_favourites":  .double(4.0)
        ])
        let current  = try makeSnapshot(platform: .mastodon, metrics: [
            "followers_count": .int(1500),  // +50%
            "avg_favourites":  .double(5.0)  // +25%
        ])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        #expect(alerts.count == 2)
        #expect(alerts[0].metricKey == "followers_count")  // +50% first
        #expect(alerts[1].metricKey == "avg_favourites")   // +25% second
    }

    @Test("summary string is well-formed for increase")
    func summaryStringForIncrease() throws {
        let previous = try makeSnapshot(platform: .bluesky,
                                        metrics: ["followers_count": .int(1000)])
        let current  = try makeSnapshot(platform: .bluesky,
                                        metrics: ["followers_count": .int(1250)])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        #expect(alerts.count == 1)
        let summary = alerts[0].summary
        #expect(summary.contains("+"))
        #expect(summary.contains("Followers"))
        #expect(summary.contains("Bluesky"))
    }

    @Test("summary string is well-formed for decrease")
    func summaryStringForDecrease() throws {
        let previous = try makeSnapshot(platform: .bluesky,
                                        metrics: ["followers_count": .int(1000)])
        let current  = try makeSnapshot(platform: .bluesky,
                                        metrics: ["followers_count": .int(700)])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        let summary = alerts[0].summary
        #expect(summary.contains("-"))
        #expect(summary.contains("Followers"))
    }

    // MARK: - FeedCardBuilder integration

    @Test("spike cards appear in feed when change exceeds threshold")
    func spikeCardsInFeed() throws {
        let older = try makeSnapshot(platform: .mastodon,
                                     metrics: ["followers_count": .int(1000)])
        let newer = try makeSnapshot(platform: .mastodon,
                                     metrics: ["followers_count": .int(1400)])

        let cards = FeedCardBuilder.build(
            snapshots: [PlatformInstance(platform: .mastodon): newer],
            previousSnapshots: [PlatformInstance(platform: .mastodon): older]
        )
        let spikes = cards.filter { $0.cardType == .spikeAlert }
        #expect(spikes.count == 1)
        #expect(spikes[0].platform == .mastodon)
    }

    @Test("no spike cards when change is below threshold")
    func noSpikeCardsWhenBelowThreshold() throws {
        let older = try makeSnapshot(platform: .mastodon,
                                     metrics: ["followers_count": .int(1000)])
        let newer = try makeSnapshot(platform: .mastodon,
                                     metrics: ["followers_count": .int(1050)])

        let cards = FeedCardBuilder.build(
            snapshots: [PlatformInstance(platform: .mastodon): newer],
            previousSnapshots: [PlatformInstance(platform: .mastodon): older]
        )
        let spikes = cards.filter { $0.cardType == .spikeAlert }
        #expect(spikes.isEmpty)
    }

    @Test("no spike cards when previousSnapshots is empty")
    func noSpikeCardsWhenNoPrevious() throws {
        let newer = try makeSnapshot(platform: .mastodon,
                                     metrics: ["followers_count": .int(1500)])

        let cards = FeedCardBuilder.build(
            snapshots: [PlatformInstance(platform: .mastodon): newer],
            previousSnapshots: [:]
        )
        let spikes = cards.filter { $0.cardType == .spikeAlert }
        #expect(spikes.isEmpty)
    }
    // MARK: - The magnitude floor

    @Test("A big percentage swing between tiny numbers is not a spike")
    func tinyNumbersAreNotSpikes() throws {
        // The case that made this necessary: 0.5 → 0.7 average favourites is a
        // 40% change and means nothing. Since #109 the background refresh fires
        // these with sound at a system-chosen moment, so the cost is teaching
        // the user to dismiss notifications.
        let previous = try makeSnapshot(platform: .mastodon, metrics: ["avg_favourites": .double(0.5)])
        let current  = try makeSnapshot(platform: .mastodon, metrics: ["avg_favourites": .double(0.7)])

        #expect(SpikeDetector().detect(current: current, previous: previous).isEmpty)
    }

    @Test("A real shift in a small-but-meaningful average still surfaces")
    func meaningfulAveragesStillSurface() throws {
        // The floor is on the values, not the change, precisely so this survives:
        // 4 → 5 average favourites is a genuine 25% engagement shift.
        let previous = try makeSnapshot(platform: .mastodon, metrics: ["avg_favourites": .double(4.0)])
        let current  = try makeSnapshot(platform: .mastodon, metrics: ["avg_favourites": .double(5.0)])

        #expect(SpikeDetector().detect(current: current, previous: previous).count == 1)
    }

    @Test("Rates are judged on a rate-sized scale, not the count floor")
    func ratesUseTheirOwnFloor() throws {
        // Rates are 0–1 fractions, so the count floor of 5 would suppress every
        // one of them.
        let previous = try makeSnapshot(platform: .buttondown, metrics: ["avg_open_rate": .double(0.40)])
        let current  = try makeSnapshot(platform: .buttondown, metrics: ["avg_open_rate": .double(0.55)])

        #expect(SpikeDetector().detect(current: current, previous: previous).count == 1)
    }

    @Test("A tiny rate wobbling is still suppressed")
    func tinyRatesAreSuppressed() throws {
        // 0.5% → 0.7% click rate is +40% and is noise.
        let previous = try makeSnapshot(platform: .buttondown, metrics: ["avg_click_rate": .double(0.005)])
        let current  = try makeSnapshot(platform: .buttondown, metrics: ["avg_click_rate": .double(0.007)])

        #expect(SpikeDetector().detect(current: current, previous: previous).isEmpty)
    }

    @Test("Metric kind is recognised from the key",
          arguments: [("avg_open_rate", true), ("avg_click_rate", true), ("avg_ctr", true),
                      ("followers_count", false), ("total_impressions", false),
                      ("avg_favourites", false)])
    func recognisesRates(key: String, isRate: Bool) {
        // Keyed off the name because the metric vocabulary is stringly-typed
        // (#63) — a shared vocabulary carrying units would remove the guesswork.
        #expect(SpikeDetector.isRate(key) == isRate)
    }

    @Test("The floors are injectable, so a caller can tune them")
    func floorsAreInjectable() throws {
        let previous = try makeSnapshot(platform: .mastodon, metrics: ["avg_favourites": .double(0.5)])
        let current  = try makeSnapshot(platform: .mastodon, metrics: ["avg_favourites": .double(0.7)])

        let permissive = SpikeDetector(minimumCountMagnitude: 0)
        #expect(permissive.detect(current: current, previous: previous).count == 1)
    }

}
