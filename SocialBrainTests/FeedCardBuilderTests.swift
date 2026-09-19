import Testing
import Foundation
@testable import SocialBrain

@Suite("FeedCardBuilder")
struct FeedCardBuilderTests {

    /// Nothing hidden, and backed by memory rather than UserDefaults.standard.
    /// Without this the suite reads the developer's own hidden-platform
    /// settings, so hiding LinkedIn in the real app would fail these tests
    /// (#80) — the same non-hermeticity #127 fixed for the Keychain.
    private let noneHidden = ScratchVisibility.make()

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

    @Test("build with empty snapshots produces 3 stale reminder cards")
    func buildEmptySnapshotsProducesStaleReminders() {
        let cards = FeedCardBuilder.build(snapshots: [:], now: Date(), visibility: noneHidden)
        // One per file-export platform: LinkedIn, Substack, O'Reilly. Was
        // four until Amazon KDP was retired.
        #expect(cards.filter { $0.cardType == .staleReminder }.count == 3)
    }

    @Test("build is non-throwing — compiles without try")
    func buildIsNonThrowing() {
        // If this compiles, the function signature is correct.
        let _: [FeedCard] = FeedCardBuilder.build(snapshots: [:], visibility: noneHidden)
    }

    @Test("build produces stale reminder for LinkedIn beyond 3-day threshold")
    func buildStaleReminderForLinkedInBeyondThreshold() throws {
        let staleDate = fixedNow.addingTimeInterval(-(4 * 24 * 3600))
        let payload = try JSONEncoder().encode(LinkedInData(latestPostText: "old", totalImpressions: 0))
        let snapshots: [PlatformInstance: PlatformSnapshot] = [
            PlatformInstance(platform: .linkedin): PlatformSnapshot(runID: 1, platform: "linkedin",
                                        collectedAt: staleDate, metricsJSON: payload)
        ]
        let cards = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow, visibility: noneHidden)
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
        let cards = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow, visibility: noneHidden)
        #expect(!cards.contains { $0.platform == .linkedin && $0.cardType == .staleReminder })
    }

    @Test("build produces stale reminder beyond the 30-day threshold")
    func buildOReillyStaleAfter30Days() throws {
        // O'Reilly, not Amazon KDP — the 30-day threshold outlived that
        // platform's retirement and still needs a case exercising it.
        let staleDate = fixedNow.addingTimeInterval(-(31 * 24 * 3600))
        let payload = try JSONEncoder().encode(["total_page_views": MetricValue.int(10)])
        let snapshots: [PlatformInstance: PlatformSnapshot] = [
            PlatformInstance(platform: .oreilly): PlatformSnapshot(runID: 1, platform: "oreilly",
                                      collectedAt: staleDate, metricsJSON: payload)
        ]
        let cards = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow, visibility: noneHidden)
        #expect(cards.contains { $0.platform == .oreilly && $0.cardType == .staleReminder })
    }

    // MARK: - Hidden platforms (#80)

    @Test("A hidden platform produces no stale reminder")
    func hiddenPlatformIsNotNagged() {
        // Hiding used to change only the Platforms grid, so the one affordance
        // for "I don't use this" left the feed still telling the user to go and
        // re-export it. Stale reminders are the worst case: the whole message
        // is an instruction to act on a platform they have opted out of.
        let hidden = ScratchVisibility.make()
        hidden.hide(.linkedin)

        let cards = FeedCardBuilder.build(snapshots: [:], now: fixedNow, visibility: hidden)

        #expect(!cards.contains { $0.platform == .linkedin })
        // The other two file-export platforms are untouched, so this is a
        // filter and not an accidental "no reminders at all".
        #expect(cards.contains { $0.platform == .substack && $0.cardType == .staleReminder })
        #expect(cards.contains { $0.platform == .oreilly && $0.cardType == .staleReminder })
    }

    @Test("Hiding every file-export platform leaves no reminders rather than an error")
    func hidingAllLeavesNoCards() {
        let hidden = ScratchVisibility.make()
        [.linkedin, .substack, .oreilly].forEach { hidden.hide($0) }

        let cards = FeedCardBuilder.build(snapshots: [:], now: fixedNow, visibility: hidden)

        #expect(cards.filter { $0.cardType == .staleReminder }.isEmpty)
    }

    @Test("A hidden platform produces no card of any type, not just reminders")
    func hiddenPlatformProducesNoCardsAtAll() throws {
        // The filter is applied once at the exit rather than inside each
        // card-producing block, so this holds for card types added later too.
        // A recent-post card for a platform the user has hidden is the same
        // bug wearing a different hat.
        let payload = try JSONEncoder().encode(
            LinkedInData(latestPostText: "a post that should not surface", totalImpressions: 500)
        )
        let snapshots: [PlatformInstance: PlatformSnapshot] = [
            PlatformInstance(platform: .linkedin):
                PlatformSnapshot(runID: 1, platform: "linkedin",
                                 collectedAt: fixedNow, metricsJSON: payload)
        ]
        let hidden = ScratchVisibility.make()
        hidden.hide(.linkedin)

        let visible = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow,
                                            visibility: noneHidden)
        let filtered = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow,
                                             visibility: hidden)

        // Something was there to suppress, so this is not vacuous.
        #expect(visible.contains { $0.platform == .linkedin })
        #expect(!filtered.contains { $0.platform == .linkedin })
    }

    @Test("Hiding the strongest platform promotes the next one, not nothing")
    func hidingBestEngagementPromotesNextVisible() throws {
        // The metric highlight picks ONE winner across all platforms with max(),
        // so filtering only the finished cards let a hidden platform win and
        // then get dropped — deleting "your best this period" from the feed
        // rather than awarding it to the best visible platform. That is why the
        // filter is applied to the inputs as well as the output.
        let mastodon = try JSONEncoder().encode(
            MastodonData(latestPostText: nil, followersCount: 100, engagementRate: 0.9)
        )
        let bluesky = try JSONEncoder().encode(
            BlueskyData(latestPostText: nil, followersCount: 100, engagementRate: 0.5)
        )
        let snapshots: [PlatformInstance: PlatformSnapshot] = [
            PlatformInstance(platform: .mastodon):
                PlatformSnapshot(runID: 1, platform: "mastodon",
                                 collectedAt: fixedNow, metricsJSON: mastodon),
            PlatformInstance(platform: .bluesky):
                PlatformSnapshot(runID: 1, platform: "bluesky",
                                 collectedAt: fixedNow, metricsJSON: bluesky)
        ]

        // Mastodon wins on 0.9 when nothing is hidden.
        let all = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow,
                                        visibility: noneHidden)
        #expect(all.contains { $0.cardType == .metricHighlight && $0.platform == .mastodon })

        let hidden = ScratchVisibility.make()
        hidden.hide(.mastodon)
        let filtered = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow,
                                             visibility: hidden)

        // Bluesky inherits the highlight. The card must still exist.
        #expect(filtered.contains { $0.cardType == .metricHighlight && $0.platform == .bluesky })
        #expect(!filtered.contains { $0.platform == .mastodon })
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
        let cards = FeedCardBuilder.build(snapshots: snapshots, now: fixedNow, visibility: noneHidden)
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
            now: fixedNow,
            visibility: noneHidden)
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
        let cards = FeedCardBuilder.build(snapshots: [nonDefaultInstance: snap], now: fixedNow, visibility: noneHidden)
        // Because the default key is missing, a stale reminder is produced for the default slot.
        // Stale reminders are emitted for the default instance → instanceName == "default".
        let staleCard = cards.first { $0.platform == .linkedin && $0.cardType == .staleReminder }
        #expect(staleCard != nil)
        #expect(staleCard?.instanceName == "default")
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
