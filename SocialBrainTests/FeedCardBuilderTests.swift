import Testing
import Foundation
@testable import SocialBrain

@Suite("FeedCardBuilder")
struct FeedCardBuilderTests {

    // Fixed reference point for deterministic staleness tests
    private let fixedNow = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    @Test("truncate returns full text when under limit")
    func truncateShortText() {
        let text = "Hello world"
        #expect(FeedCardBuilder.truncate(text, limit: 280) == text)
    }

    @Test("truncate breaks at a word boundary, not mid-word")
    func truncateAtWordBoundary() {
        // 10 repetitions of "hello " = 60 chars; limit 25 should cut after a space
        let text = String(repeating: "hello ", count: 10)
        let result = FeedCardBuilder.truncate(text, limit: 25)
        // Must end with "…" and the character before "…" must not be a space
        #expect(result.hasSuffix("…"))
        let withoutEllipsis = result.dropLast() // remove "…"
        #expect(!withoutEllipsis.hasSuffix(" "))
        #expect(result.count <= 26) // 25 chars + "…"
    }

    @Test("truncate falls back to hard cut when no space found")
    func truncateHardCutFallbackWhenNoSpace() {
        let text = String(repeating: "a", count: 300)
        let result = FeedCardBuilder.truncate(text, limit: 280)
        #expect(result.hasSuffix("…"))
        #expect(result.count == 281) // 280 chars + "…"
    }

    @Test("build with empty snapshots produces 4 stale reminder cards")
    func buildEmptySnapshotsProducesFourStaleReminders() {
        let cards = FeedCardBuilder.build(snapshots: [:], now: Date())
        #expect(cards.filter { $0.cardType == .staleReminder }.count == 4)
    }

    @Test("build is non-throwing — compiles without try")
    func buildIsNonThrowing() {
        // If this compiles, the function signature is correct.
        let _: [FeedCard] = FeedCardBuilder.build(snapshots: [:])
    }

    @Test("build produces stale reminder for LinkedIn beyond 3-day threshold")
    func buildStaleReminderForLinkedInBeyondThreshold() throws {
        let staleDate = fixedNow.addingTimeInterval(-(4 * 24 * 3600))
        let payload = try JSONEncoder().encode(LinkedInData(latestPostText: "old", totalImpressions: 0))
        let snapshots: [PlatformInstance: PlatformSnapshot] = [
            PlatformInstance(platform: .linkedin): PlatformSnapshot(runID: 1, platform: "linkedin",
                                        collectedAt: staleDate, metricsJSON: payload)
        ]
        let cards = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow)
        #expect(cards.contains { $0.platform == .linkedin && $0.cardType == .staleReminder })
    }

    @Test("build does not produce stale reminder for LinkedIn within 3-day threshold")
    func buildNoStaleReminderForLinkedInWithinThreshold() throws {
        let freshDate = fixedNow.addingTimeInterval(-(1 * 24 * 3600))
        let payload = try JSONEncoder().encode(LinkedInData(latestPostText: "fresh", totalImpressions: 10))
        let snapshots: [PlatformInstance: PlatformSnapshot] = [
            PlatformInstance(platform: .linkedin): PlatformSnapshot(runID: 1, platform: "linkedin",
                                        collectedAt: freshDate, metricsJSON: payload)
        ]
        let cards = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow)
        #expect(!cards.contains { $0.platform == .linkedin && $0.cardType == .staleReminder })
    }

    @Test("build produces stale reminder for Amazon beyond 30-day threshold")
    func buildAmazonStaleAfter30Days() throws {
        let staleDate = fixedNow.addingTimeInterval(-(31 * 24 * 3600))
        let payload = try JSONEncoder().encode(AmazonData(latestTitle: "Book", totalRoyalties: 10))
        let snapshots: [PlatformInstance: PlatformSnapshot] = [
            PlatformInstance(platform: .amazon): PlatformSnapshot(runID: 1, platform: "amazon",
                                      collectedAt: staleDate, metricsJSON: payload)
        ]
        let cards = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow)
        #expect(cards.contains { $0.platform == .amazon && $0.cardType == .staleReminder })
    }

    @Test("FeedCardType displayName returns human-readable strings")
    func feedCardTypeDisplayName() {
        #expect(FeedCardType.recentPost.displayName == "Recent Post")
        #expect(FeedCardType.metricHighlight.displayName == "Metric Highlight")
        #expect(FeedCardType.upcomingEvent.displayName == "Upcoming Event")
        #expect(FeedCardType.staleReminder.displayName == "Stale Reminder")
    }

    @Test("build does not produce stale reminder for non-file-export platform even if old")
    func buildNoStaleReminderForNonFileExportPlatform() throws {
        let payload = try JSONEncoder().encode(MastodonData(
            latestPostText: "old", followersCount: 1, engagementRate: 0.01))
        let oldDate = fixedNow.addingTimeInterval(-(365 * 24 * 3600))
        let snapshots: [PlatformInstance: PlatformSnapshot] = [
            PlatformInstance(platform: .mastodon): PlatformSnapshot(runID: 1, platform: "mastodon",
                                        collectedAt: oldDate, metricsJSON: payload)
        ]
        let cards = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow)
        #expect(!cards.contains { $0.platform == .mastodon && $0.cardType == .staleReminder })
    }

    @Test("spike alert card for non-default instance carries correct instanceName")
    func spikeAlertForNonDefaultInstance() throws {
        let workInstance = PlatformInstance(platform: .mastodon, instanceName: "work")
        // Use [String: MetricValue] encoding so SpikeDetector can decode via decodedMetrics()
        let prevMetrics: [String: MetricValue] = ["followers_count": .int(1000)]
        let currMetrics: [String: MetricValue] = ["followers_count": .int(1500)] // +50% spike
        let prevPayload = try JSONEncoder().encode(prevMetrics)
        let currPayload = try JSONEncoder().encode(currMetrics)
        let prev = PlatformSnapshot(runID: 1, platform: "mastodon",
                                    instanceName: "work", collectedAt: fixedNow.addingTimeInterval(-3600),
                                    metricsJSON: prevPayload)
        let curr = PlatformSnapshot(runID: 2, platform: "mastodon",
                                    instanceName: "work", collectedAt: fixedNow,
                                    metricsJSON: currPayload)
        let cards = FeedCardBuilder.build(
            snapshots: [workInstance: curr],
            previousSnapshots: [workInstance: prev],
            now: fixedNow
        )
        let spikeCard = cards.first { $0.cardType == .spikeAlert && $0.platform == .mastodon }
        #expect(spikeCard != nil)
        #expect(spikeCard?.instanceName == "work")
    }

    @Test("stale reminder for file-export platform with non-default instanceName uses default lookup")
    func staleReminderForNonDefaultInstance() throws {
        // FeedCardBuilder stale reminders use the default instance key for file-export platforms.
        // A non-default instance in the DB does not satisfy the stale check for the default key,
        // so the default-instance stale reminder fires.
        let nonDefaultInstance = PlatformInstance(platform: .linkedin, instanceName: "company")
        let freshDate = fixedNow.addingTimeInterval(-(1 * 24 * 3600))
        let payload = try JSONEncoder().encode(LinkedInData(latestPostText: "post", totalImpressions: 10))
        let snap = PlatformSnapshot(runID: 1, platform: "linkedin",
                                    instanceName: "company", collectedAt: freshDate,
                                    metricsJSON: payload)
        // Only the non-default instance is in snapshots — default key is absent
        let cards = FeedCardBuilder.build(snapshots: [nonDefaultInstance: snap], now: fixedNow)
        // Because the default key is missing, a stale reminder is still produced
        #expect(cards.contains { $0.platform == .linkedin && $0.cardType == .staleReminder })
    }

    @Test("FeedCard has instanceName property defaulting to 'default'")
    func feedCardHasInstanceName() {
        let card = FeedCard(
            platform: .mastodon,
            cardType: .recentPost,
            snippet: "Hello",
            navigationTarget: .mastodon
        )
        #expect(card.instanceName == "default")
        let namedCard = FeedCard(
            platform: .mastodon,
            instanceName: "personal",
            cardType: .recentPost,
            snippet: "Hello",
            navigationTarget: .mastodon
        )
        #expect(namedCard.instanceName == "personal")
    }

    @Test("HighReachDetector accepts PlatformInstance keys and produces same results for default instances")
    func highReachDetectorAcceptsInstanceKeys() throws {
        let snap = try {
            let data = PlatformData(platform: .buttondown,
                                    metrics: ["avg_open_rate": .double(0.55)])
            return try PlatformSnapshot(runID: 1, data: data)
        }()
        let defaultInstance = PlatformInstance(platform: .buttondown)
        let items = HighReachDetector().detect(snapshots: [defaultInstance: snap])
        #expect(items.count == 1)
        #expect(items[0].platform == .buttondown)
    }
}
