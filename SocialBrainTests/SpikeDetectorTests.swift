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
            snapshots: [.mastodon: newer],
            previousSnapshots: [.mastodon: older]
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
            snapshots: [.mastodon: newer],
            previousSnapshots: [.mastodon: older]
        )
        let spikes = cards.filter { $0.cardType == .spikeAlert }
        #expect(spikes.isEmpty)
    }

    @Test("no spike cards when previousSnapshots is empty")
    func noSpikeCardsWhenNoPrevious() throws {
        let newer = try makeSnapshot(platform: .mastodon,
                                     metrics: ["followers_count": .int(1500)])

        let cards = FeedCardBuilder.build(
            snapshots: [.mastodon: newer],
            previousSnapshots: [:]
        )
        let spikes = cards.filter { $0.cardType == .spikeAlert }
        #expect(spikes.isEmpty)
    }
}
