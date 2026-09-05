import Testing
import Foundation
@testable import SocialBrain

@Suite("Prompt Assembler Tests")
struct PromptAssemblerTests {

    private let assembler = PromptAssembler()

    private func makeInput(snapshots: [PlatformInstance: PlatformSnapshot]) -> PromptAssembler.Input {
        // Fixed date for deterministic output
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 26
        let date = Calendar.current.date(from: comps)!
        return PromptAssembler.Input(
            periodLabel: "Last 30 days",
            reportDate: date,
            snapshots: snapshots
        )
    }

    /// Helper: create a PlatformSnapshot from a PlatformData.
    private func makeSnap(_ data: PlatformData) throws -> PlatformSnapshot {
        try PlatformSnapshot(runID: 1, data: data)
    }

    /// Helper: build a single-entry snapshots dict from a PlatformData.
    private func snaps(_ data: PlatformData) throws -> [PlatformInstance: PlatformSnapshot] {
        let inst = PlatformInstance(platform: data.platform, instanceName: data.instanceName)
        return [inst: try makeSnap(data)]
    }

    @Test("Output contains header and date")
    func headerPresent() throws {
        let prompt = assembler.assemble(makeInput(snapshots: [:]))
        #expect(prompt.contains("Social Media & Publishing Analytics Report"))
        #expect(prompt.contains("March 26, 2026"))
        #expect(prompt.contains("Last 30 days"))
    }

    @Test("Output contains analysis request section")
    func analysisRequestPresent() throws {
        let prompt = assembler.assemble(makeInput(snapshots: [:]))
        #expect(prompt.contains("Key trends"))
        #expect(prompt.contains("Actionable recommendations"))
    }

    @Test("Mastodon section formats correctly")
    func mastodonSection() throws {
        let data = PlatformData(
            platform: .mastodon,
            metrics: [
                "followers_count": .int(2500),
                "following_count": .int(300),
                "statuses_count":  .int(4100),
                "recent_posts":    .int(12),
                "avg_reblogs":     .double(10.0),
                "avg_favourites":  .double(37.5),
                "avg_replies":     .double(4.0)
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("## Mastodon"))
        #expect(prompt.contains("Followers: 2,500"))
        #expect(prompt.contains("Posts this period: 12"))
        #expect(prompt.contains("37.5 favourites"))
    }

    @Test("Buttondown section formats open rate as percentage")
    func buttondownSection() throws {
        let data = PlatformData(
            platform: .buttondown,
            metrics: [
                "subscriber_count": .int(1500),
                "new_subscribers":  .int(42),
                "emails_sent":      .int(3),
                "avg_open_rate":    .double(0.475),
                "avg_click_rate":   .double(0.11)
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("## Buttondown"))
        #expect(prompt.contains("Subscribers: 1,500 (+42 new)"))
        #expect(prompt.contains("47.5%"))
        #expect(prompt.contains("11.0%"))
    }

    @Test("GoatCounter section lists top pages")
    func goatCounterSection() throws {
        let data = PlatformData(
            platform: .goatCounter,
            metrics: [
                "total_pageviews": .int(8421),
                "unique_visitors": .int(3102),
                "top_page_1":      .string("/blog/swift-tips"),
                "top_page_2":      .string("/blog/grdb-guide")
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("## GoatCounter"))
        #expect(prompt.contains("Pageviews: 8,421"))
        #expect(prompt.contains("/blog/swift-tips"))
    }

    @Test("Bluesky section formats engagement per post")
    func blueskySection() throws {
        let data = PlatformData(
            platform: .bluesky,
            metrics: [
                "followers_count": .int(3800),
                "follows_count":   .int(420),
                "posts_count":     .int(910),
                "recent_posts":    .int(8),
                "avg_likes":       .double(42.5),
                "avg_reposts":     .double(8.5)
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("## Bluesky"))
        #expect(prompt.contains("Followers: 3,800"))
        #expect(prompt.contains("42.5 likes"))
    }

    @Test("Multiple platforms are sorted alphabetically")
    func alphabeticalOrder() throws {
        let mastodon = PlatformData(platform: .mastodon, metrics: ["followers_count": .int(100)])
        let bluesky  = PlatformData(platform: .bluesky,  metrics: ["followers_count": .int(200)])
        var dict: [PlatformInstance: PlatformSnapshot] = try snaps(mastodon)
        dict.merge(try snaps(bluesky)) { a, _ in a }
        let prompt = assembler.assemble(makeInput(snapshots: dict))
        let blueskyRange  = prompt.range(of: "## Bluesky")!
        let mastodonRange = prompt.range(of: "## Mastodon")!
        // Bluesky (B) comes before Mastodon (M) alphabetically
        #expect(blueskyRange.lowerBound < mastodonRange.lowerBound)
    }

    @Test("Platform with no known metrics produces no section")
    func emptySectionOmitted() throws {
        // A snapshot with metrics that don't match any known key for amazon
        let data = PlatformData(
            platform: .amazon,
            metrics: [:]  // no metrics at all
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(!prompt.contains("## Amazon KDP"))
    }

    @Test("Amazon KDP section formats units and royalties")
    func amazonSection() throws {
        let data = PlatformData(
            platform: .amazon,
            metrics: [
                "units_sold":        .int(47),
                "titles_with_sales": .int(3),
                "royalties_usd":     .double(82.50),
                "kenp_pages_read":   .int(12400)
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("## Amazon KDP"))
        #expect(prompt.contains("Units sold: 47 across 3 titles"))
        #expect(prompt.contains("Royalties: $82.50"))
        #expect(prompt.contains("KENP pages read: 12,400"))
    }

    @Test("Substack section formats posts and open rate")
    func substackSection() throws {
        let data = PlatformData(
            platform: .substack,
            metrics: [
                "posts_published": .int(4),
                "avg_open_rate":   .double(0.47)
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("## Substack"))
        #expect(prompt.contains("Posts published: 4"))
        #expect(prompt.contains("47.0%"))
    }

    @Test("Calendly section formats events and invitees")
    func calendlySection() throws {
        let data = PlatformData(
            platform: .calendly,
            metrics: [
                "events_count":    .int(18),
                "cancelled_count": .int(2),
                "unique_invitees": .int(15),
                "top_event_type_1": .string("30-Minute Meeting"),
                "top_event_type_2": .string("Coffee Chat")
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("## Calendly"))
        #expect(prompt.contains("Scheduled events: 18 (2 cancelled)"))
        #expect(prompt.contains("Unique invitees: 15"))
        #expect(prompt.contains("30-Minute Meeting"))
    }

    @Test("Jetpack section formats followers, views and visitors")
    func jetpackSection() throws {
        let data = PlatformData(
            platform: .jetpack,
            metrics: [
                "followers_blog":    .int(1240),
                "followers_comment": .int(85),
                "total_views":       .int(500),
                "total_visitors":    .int(135),
                "total_likes":       .int(12),
                "total_comments":    .int(342)
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("## Jetpack Stats"))
        #expect(prompt.contains("Followers: 1,240 (85 comment subscribers)"))
        #expect(prompt.contains("Views: 500"))
        #expect(prompt.contains("Visitors: 135"))
    }

    @Test("LinkedIn section formats impressions and engagement")
    func linkedinSection() throws {
        let data = PlatformData(
            platform: .linkedin,
            metrics: [
                "posts_published":  .int(5),
                "total_impressions": .int(4200),
                "total_likes":      .int(310),
                "total_comments":   .int(42),
                "total_shares":     .int(18),
                "avg_ctr":          .double(0.028)
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("## LinkedIn"))
        #expect(prompt.contains("Posts: 5, 4,200 impressions"))
        #expect(prompt.contains("310 likes"))
        #expect(prompt.contains("2.8%"))
    }

    @Test("O'Reilly section formats page views and unique users")
    func oreillySection() throws {
        let data = PlatformData(
            platform: .oreilly,
            metrics: [
                "titles_count":      .int(2),
                "total_page_views":  .int(9432),
                "total_unique_users": .int(3210),
                "total_completions": .int(87)
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("## O'Reilly"))
        #expect(prompt.contains("Titles: 2"))
        #expect(prompt.contains("Page views: 9,432"))
        #expect(prompt.contains("Unique users: 3,210"))
        #expect(prompt.contains("Course completions: 87"))
    }

    // MARK: - Multi-instance tests (Suite 8)

    @Test("Single instance uses platform display name as header")
    func singleInstanceUsesplatformDisplayName() throws {
        let data = PlatformData(platform: .mastodon, metrics: ["followers_count": .int(100)])
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("## Mastodon"))
        #expect(!prompt.contains("## Mastodon —"))
    }

    @Test("Two instances for same platform use instance display name as header")
    func twoInstancesSamePlatformUsesInstanceDisplayName() throws {
        let personal = PlatformData(platform: .mastodon, instanceName: "personal",
                                    metrics: ["followers_count": .int(100)])
        let work = PlatformData(platform: .mastodon, instanceName: "work",
                                metrics: ["followers_count": .int(200)])
        var dict: [PlatformInstance: PlatformSnapshot] = try snaps(personal)
        dict.merge(try snaps(work)) { a, _ in a }
        let prompt = assembler.assemble(makeInput(snapshots: dict))
        #expect(prompt.contains("## Mastodon — personal"))
        #expect(prompt.contains("## Mastodon — work"))
    }

    @Test("Default instance header unchanged for default instance name")
    func existingPromptFormatUnchangedForDefaultInstance() throws {
        let mastodon = PlatformData(platform: .mastodon, instanceName: "default",
                                    metrics: ["followers_count": .int(100)])
        let bluesky  = PlatformData(platform: .bluesky, instanceName: "default",
                                    metrics: ["followers_count": .int(200)])
        var dict: [PlatformInstance: PlatformSnapshot] = try snaps(mastodon)
        dict.merge(try snaps(bluesky)) { a, _ in a }
        let prompt = assembler.assemble(makeInput(snapshots: dict))
        #expect(prompt.contains("## Mastodon"))
        #expect(prompt.contains("## Bluesky"))
        #expect(!prompt.contains("— default"))
    }
}
