import Testing
import Foundation
@testable import SocialBrain

@Suite("High Reach Detector Tests")
struct HighReachDetectorTests {

    // MARK: - Helpers

    private func makeSnapshot(
        platform: Platform,
        metrics: [String: MetricValue],
        collectedAt: Date = Date()
    ) throws -> PlatformSnapshot {
        let data = PlatformData(platform: platform, collectedAt: collectedAt, metrics: metrics)
        return try PlatformSnapshot(runID: 1, data: data)
    }

    // MARK: - Absolute threshold tests

    @Test("Buttondown open rate > 40% triggers high reach")
    func buttondownAboveThreshold() throws {
        let snap = try makeSnapshot(platform: .buttondown,
                                    metrics: ["avg_open_rate": .double(0.55)])
        let items = HighReachDetector().detect(snapshots: [.buttondown: snap])
        #expect(items.count == 1)
        #expect(items[0].platform == .buttondown)
        #expect(items[0].message.contains("55%"))
    }

    @Test("Buttondown open rate <= 40% does not trigger high reach without relative lift")
    func buttondownBelowThreshold() throws {
        let snap = try makeSnapshot(platform: .buttondown,
                                    metrics: ["avg_open_rate": .double(0.30)])
        let items = HighReachDetector().detect(snapshots: [.buttondown: snap])
        #expect(items.isEmpty)
    }

    @Test("Mastodon avg_favourites >= 5 triggers high reach")
    func mastodonAboveThreshold() throws {
        let snap = try makeSnapshot(platform: .mastodon,
                                    metrics: ["avg_favourites": .double(8.0)])
        let items = HighReachDetector().detect(snapshots: [.mastodon: snap])
        #expect(items.count == 1)
        #expect(items[0].platform == .mastodon)
    }

    @Test("Mastodon avg_favourites < 5 does not trigger high reach without relative lift")
    func mastodonBelowThreshold() throws {
        let snap = try makeSnapshot(platform: .mastodon,
                                    metrics: ["avg_favourites": .double(2.0)])
        let items = HighReachDetector().detect(snapshots: [.mastodon: snap])
        #expect(items.isEmpty)
    }

    @Test("Bluesky avg_likes >= 5 triggers high reach")
    func blueskyAboveThreshold() throws {
        let snap = try makeSnapshot(platform: .bluesky,
                                    metrics: ["avg_likes": .double(10.0)])
        let items = HighReachDetector().detect(snapshots: [.bluesky: snap])
        #expect(items.count == 1)
        #expect(items[0].platform == .bluesky)
    }

    @Test("Jetpack total_views >= 1000 triggers high reach")
    func jetpackAboveThreshold() throws {
        let snap = try makeSnapshot(platform: .jetpack,
                                    metrics: ["total_views": .int(1500)])
        let items = HighReachDetector().detect(snapshots: [.jetpack: snap])
        #expect(items.count == 1)
        #expect(items[0].platform == .jetpack)
    }

    @Test("LinkedIn impressions >= 500 triggers high reach")
    func linkedInAboveThreshold() throws {
        let snap = try makeSnapshot(platform: .linkedin,
                                    metrics: ["total_impressions": .int(600)])
        let items = HighReachDetector().detect(snapshots: [.linkedin: snap])
        #expect(items.count == 1)
        #expect(items[0].platform == .linkedin)
    }

    @Test("GoatCounter visitors >= 500 triggers high reach")
    func goatCounterAboveThreshold() throws {
        let snap = try makeSnapshot(platform: .goatCounter,
                                    metrics: ["unique_visitors": .int(750)])
        let items = HighReachDetector().detect(snapshots: [.goatCounter: snap])
        #expect(items.count == 1)
        #expect(items[0].platform == .goatCounter)
    }

    // MARK: - Relative lift tests

    @Test("Relative lift alone (>30% above previous) triggers high reach")
    func relativeLiftAloneTriggersHighReach() throws {
        let prev = try makeSnapshot(platform: .mastodon,
                                    metrics: ["avg_favourites": .double(2.0)])
        let curr = try makeSnapshot(platform: .mastodon,
                                    metrics: ["avg_favourites": .double(2.8)])  // +40%

        let items = HighReachDetector(relativeLiftThreshold: 0.30)
            .detect(snapshots: [.mastodon: curr], previousSnapshots: [.mastodon: prev])
        #expect(items.count == 1)
    }

    @Test("Relative lift below threshold does not trigger high reach")
    func relativeLiftBelowThresholdDoesNotTrigger() throws {
        let prev = try makeSnapshot(platform: .mastodon,
                                    metrics: ["avg_favourites": .double(2.0)])
        let curr = try makeSnapshot(platform: .mastodon,
                                    metrics: ["avg_favourites": .double(2.2)])  // +10%

        let items = HighReachDetector(relativeLiftThreshold: 0.30)
            .detect(snapshots: [.mastodon: curr], previousSnapshots: [.mastodon: prev])
        #expect(items.isEmpty)
    }

    // MARK: - Sorting and multi-platform tests

    @Test("Results sorted by score descending")
    func resultsSortedByScore() throws {
        let mastodon = try makeSnapshot(platform: .mastodon,
                                        metrics: ["avg_favourites": .double(10.0)])  // score ~0.2
        let buttondown = try makeSnapshot(platform: .buttondown,
                                          metrics: ["avg_open_rate": .double(0.80)])  // score ~0.8

        let items = HighReachDetector().detect(snapshots: [
            .mastodon: mastodon,
            .buttondown: buttondown
        ])

        // Both should be present; buttondown first (higher score)
        #expect(items.count == 2)
        #expect(items[0].platform == .buttondown)
        #expect(items[1].platform == .mastodon)
    }

    @Test("No items when snapshot is missing the tracked metric key")
    func noItemWhenMetricMissing() throws {
        let snap = try makeSnapshot(platform: .buttondown,
                                    metrics: ["subscriber_count": .int(500)])
        let items = HighReachDetector().detect(snapshots: [.buttondown: snap])
        #expect(items.isEmpty)
    }

    // MARK: - FeedCardBuilder integration

    @Test("High-reach card appears in feed when threshold met")
    func highReachCardInFeed() throws {
        let snap = try makeSnapshot(platform: .buttondown,
                                    metrics: ["avg_open_rate": .double(0.55)])
        let cards = FeedCardBuilder.build(snapshots: [.buttondown: snap])
        let highReachCards = cards.filter { $0.cardType == .highReach }
        #expect(highReachCards.count == 1)
        #expect(highReachCards[0].platform == .buttondown)
    }

    @Test("No high-reach card when platform has a spike card")
    func noHighReachCardWhenSpikeCardPresent() throws {
        // Set up a spike (followers +50%) AND high open rate
        let prev = try makeSnapshot(platform: .buttondown, metrics: [
            "avg_open_rate": .double(0.30),
            "subscriber_count": .int(1000)
        ])
        let curr = try makeSnapshot(platform: .buttondown, metrics: [
            "avg_open_rate": .double(0.55),   // high-reach threshold
            "subscriber_count": .int(1500)    // +50% spike
        ])
        let cards = FeedCardBuilder.build(
            snapshots: [.buttondown: curr],
            previousSnapshots: [.buttondown: prev]
        )
        // Both spike and high-reach are valid, but they should not both appear for the same platform
        let spikeCards = cards.filter { $0.cardType == .spikeAlert && $0.platform == .buttondown }
        let hrCards = cards.filter { $0.cardType == .highReach && $0.platform == .buttondown }
        // Either spike or highReach for buttondown, not both
        #expect(spikeCards.count + hrCards.count == 1)
    }
}
