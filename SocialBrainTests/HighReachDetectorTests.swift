import Testing
import Foundation
@testable import SocialBrain

@Suite("High Reach Detector Tests")
struct HighReachDetectorTests {

    /// Nothing hidden, and backed by memory rather than UserDefaults.standard.
    /// Without this the suite reads the developer's own hidden-platform
    /// settings, so hiding LinkedIn in the real app would fail these tests
    /// (#80) — the same non-hermeticity #127 fixed for the Keychain.
    private let noneHidden = ScratchVisibility.make()

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
        let items = HighReachDetector().detect(snapshots: [PlatformInstance(platform: .buttondown): snap])
        #expect(items.count == 1)
        #expect(items.first?.platform == .buttondown)
        #expect(items.first?.message.contains("55%") == true)
    }

    @Test("Buttondown open rate <= 40% does not trigger high reach without relative lift")
    func buttondownBelowThreshold() throws {
        let snap = try makeSnapshot(platform: .buttondown,
                                    metrics: ["avg_open_rate": .double(0.30)])
        let items = HighReachDetector().detect(snapshots: [PlatformInstance(platform: .buttondown): snap])
        #expect(items.isEmpty)
    }

    @Test("Mastodon avg_favourites >= 5 triggers high reach")
    func mastodonAboveThreshold() throws {
        let snap = try makeSnapshot(platform: .mastodon,
                                    metrics: ["avg_favourites": .double(8.0)])
        let items = HighReachDetector().detect(snapshots: [PlatformInstance(platform: .mastodon): snap])
        #expect(items.count == 1)
        #expect(items.first?.platform == .mastodon)
    }

    @Test("Mastodon avg_favourites < 5 does not trigger high reach without relative lift")
    func mastodonBelowThreshold() throws {
        let snap = try makeSnapshot(platform: .mastodon,
                                    metrics: ["avg_favourites": .double(2.0)])
        let items = HighReachDetector().detect(snapshots: [PlatformInstance(platform: .mastodon): snap])
        #expect(items.isEmpty)
    }

    @Test("Bluesky avg_likes >= 5 triggers high reach")
    func blueskyAboveThreshold() throws {
        let snap = try makeSnapshot(platform: .bluesky,
                                    metrics: ["avg_likes": .double(10.0)])
        let items = HighReachDetector().detect(snapshots: [PlatformInstance(platform: .bluesky): snap])
        #expect(items.count == 1)
        #expect(items.first?.platform == .bluesky)
    }

    @Test("Jetpack total_views >= 1000 triggers high reach")
    func jetpackAboveThreshold() throws {
        let snap = try makeSnapshot(platform: .jetpack,
                                    metrics: ["total_views": .int(1500)])
        let items = HighReachDetector().detect(snapshots: [PlatformInstance(platform: .jetpack): snap])
        #expect(items.count == 1)
        #expect(items.first?.platform == .jetpack)
    }

    @Test("LinkedIn impressions >= 500 triggers high reach")
    func linkedInAboveThreshold() throws {
        let snap = try makeSnapshot(platform: .linkedin,
                                    metrics: ["total_impressions": .int(600)])
        let items = HighReachDetector().detect(snapshots: [PlatformInstance(platform: .linkedin): snap])
        #expect(items.count == 1)
        #expect(items.first?.platform == .linkedin)
    }

    @Test("GoatCounter visits >= 500 triggers high reach")
    func goatCounterAboveThreshold() throws {
        // Was unique_visitors, which GoatCounter has no endpoint for — so this
        // branch could never have run against real data (#156). The figure is
        // visits: session-first views per path.
        let snap = try makeSnapshot(platform: .goatCounter,
                                    metrics: ["total_visits": .int(750)])
        let items = HighReachDetector().detect(snapshots: [PlatformInstance(platform: .goatCounter): snap])
        #expect(items.count == 1)
        #expect(items.first?.platform == .goatCounter)
    }

    // MARK: - Relative lift tests

    @Test("Relative lift alone (>30% above previous) triggers high reach")
    func relativeLiftAloneTriggersHighReach() throws {
        let prev = try makeSnapshot(platform: .mastodon,
                                    metrics: ["avg_favourites": .double(2.0)])
        let curr = try makeSnapshot(platform: .mastodon,
                                    metrics: ["avg_favourites": .double(2.8)])  // +40%

        let items = HighReachDetector(relativeLiftThreshold: 0.30)
            .detect(snapshots: [PlatformInstance(platform: .mastodon): curr], previousSnapshots: [PlatformInstance(platform: .mastodon): prev])
        #expect(items.count == 1)
    }

    @Test("Relative lift below threshold does not trigger high reach")
    func relativeLiftBelowThresholdDoesNotTrigger() throws {
        let prev = try makeSnapshot(platform: .mastodon,
                                    metrics: ["avg_favourites": .double(2.0)])
        let curr = try makeSnapshot(platform: .mastodon,
                                    metrics: ["avg_favourites": .double(2.2)])  // +10%

        let items = HighReachDetector(relativeLiftThreshold: 0.30)
            .detect(snapshots: [PlatformInstance(platform: .mastodon): curr], previousSnapshots: [PlatformInstance(platform: .mastodon): prev])
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
            PlatformInstance(platform: .mastodon): mastodon,
            PlatformInstance(platform: .buttondown): buttondown
        ])

        // Both should be present; buttondown first (higher score)
        #expect(items.count == 2)
        #expect(items.first?.platform == .buttondown)
        #expect(items.dropFirst().first?.platform == .mastodon)
    }

    @Test("No items when snapshot is missing the tracked metric key")
    func noItemWhenMetricMissing() throws {
        let snap = try makeSnapshot(platform: .buttondown,
                                    metrics: ["subscriber_count": .int(500)])
        let items = HighReachDetector().detect(snapshots: [PlatformInstance(platform: .buttondown): snap])
        #expect(items.isEmpty)
    }

    // MARK: - FeedCardBuilder integration

    @Test("High-reach card appears in feed when threshold met")
    func highReachCardInFeed() throws {
        let snap = try makeSnapshot(platform: .buttondown,
                                    metrics: ["avg_open_rate": .double(0.55)])
        let cards = FeedCardBuilder.build(snapshots: [PlatformInstance(platform: .buttondown): snap], visibility: noneHidden)
        let highReachCards = cards.filter { $0.cardType == .highReach }
        #expect(highReachCards.count == 1)
        #expect(highReachCards.first?.platform == .buttondown)
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
            snapshots: [PlatformInstance(platform: .buttondown): curr],
            previousSnapshots: [PlatformInstance(platform: .buttondown): prev],
            visibility: noneHidden)
        // Both spike and high-reach are valid, but they should not both appear for the same platform
        let spikeCards = cards.filter { $0.cardType == .spikeAlert && $0.platform == .buttondown }
        let hrCards = cards.filter { $0.cardType == .highReach && $0.platform == .buttondown }
        // Either spike or highReach for buttondown, not both
        #expect(spikeCards.count + hrCards.count == 1)
    }
}
