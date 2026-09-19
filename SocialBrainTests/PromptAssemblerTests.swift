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
        // No note when the walk completed.
        #expect(!prompt.contains("Note:"))
    }

    @Test("Every collection cap reaches the prompt",
          arguments: [(Platform.bluesky,    "posts_truncated"),
                      (Platform.buffer,     "posts_sampled"),
                      (Platform.jetpack,    "views_window"),
                      (Platform.hackerNews, "mentions_sampled"),
                      (Platform.buttondown, "emails_sampled")])
    func collectionCapsAreRendered(platform: Platform, key: String) throws {
        // A metric written to the database and read by nothing is exactly what
        // the #136 review caught, and three more of these shipped afterwards
        // with no test pinning the rendering — deleting both prompt lines left
        // the whole suite green.
        //
        // The number these qualify looks like a period total and is really a
        // page size or a truncated window. If the note does not reach the
        // prompt, recording it achieves nothing at all.
        let note = "SENTINEL-cap-note"
        let data = PlatformData(platform: platform, metrics: [key: .string(note)])
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains(note), "\(platform) did not render \(key)")
    }

    @Test("A truncated post count says so in the prompt")
    func mastodonTruncationIsRendered() throws {
        // The whole point of recording posts_truncated is that the prompt says
        // it. Without this line the count sits next to an all-time total many
        // times larger and reads as the complete period — which is the
        // contradiction the metric exists to prevent, and which a metric
        // written to the database and read by nothing does not prevent at all.
        let data = PlatformData(
            platform: .mastodon,
            metrics: [
                "statuses_count":   .int(4100),
                "recent_posts":     .int(1000),
                "posts_truncated":  .string("stopped after 1000 posts — the period holds more")
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("Posts this period: 1000"))
        #expect(prompt.contains("Note: stopped after 1000 posts"))
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
                "total_visits": .int(8421),
                // Supplied on purpose. A negative assertion against a fixture
                // that omits the key proves nothing — the line could still be
                // there, reading a metric nothing happens to provide.
                "unique_visitors": .int(3102),
                "top_page_1":   .string("/blog/swift-tips"),
                "top_page_2":   .string("/blog/grdb-guide")
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(prompt.contains("## GoatCounter"))
        #expect(prompt.contains("Visits: 8,421"))
        #expect(prompt.contains("/blog/swift-tips"))
        // GoatCounter has no unique-visitor endpoint, so even a snapshot
        // carrying the invented key must not render one (#156).
        #expect(!prompt.contains("Unique visitors"))
        #expect(!prompt.contains("3,102"))
        #expect(!prompt.contains("Pageviews"))
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
        let blueskyRange  = try #require(prompt.range(of: "## Bluesky"))
        let mastodonRange = try #require(prompt.range(of: "## Mastodon"))
        // Bluesky (B) comes before Mastodon (M) alphabetically
        #expect(blueskyRange.lowerBound < mastodonRange.lowerBound)
    }

    @Test("Platform with no known metrics produces no section")
    func emptySectionOmitted() throws {
        // A snapshot with no metrics at all produces no section.
        let data = PlatformData(
            platform: .oreilly,
            metrics: [:]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))
        #expect(!prompt.contains("## O'Reilly"))
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

    @Test("LinkedIn section surfaces the metrics only the XLSX export carries")
    func linkedinXLSXOnlyMetrics() throws {
        // These four were written by LinkedInXLSXParser and read by nothing —
        // not the prompt, not the dashboard, not the spike detector — so an
        // XLSX import produced nothing a CSV import would not have (#114).
        let data = PlatformData(
            platform: .linkedin,
            // Exactly what LinkedInXLSXParser writes — no posts_published,
            // which is what hid the missing impressions line: it used to render
            // only inside a posts_published guard this shape never satisfies.
            metrics: [
                "total_impressions": .int(107),
                "total_followers":   .int(8420),
                "new_followers":     .int(137),
                "total_engagements": .int(512),
                "members_reached":   .int(19_300)
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))

        #expect(prompt.contains("Followers: 8,420 total, 137 new this period"))
        #expect(prompt.contains("Total engagements: 512"))
        #expect(prompt.contains("Unique members reached: 19,300"))
        // The headline metric, which an XLSX import was dropping entirely.
        // Labelled, because this shape has no posts count to hang it off.
        #expect(prompt.contains("Impressions: 107"))
    }

    /// The "## LinkedIn" section of an assembled prompt, up to the next header.
    private func linkedinSection(of prompt: String) -> String? {
        guard let start = prompt.range(of: "## LinkedIn") else { return nil }
        let rest = prompt[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test("A CSV-only LinkedIn import gains no empty lines from the XLSX metrics")
    func linkedinCSVImportHasNoFollowerLines() throws {
        // The CSV path cannot produce any of the four, so their section must
        // disappear entirely rather than render as "Followers: " with nothing
        // after it.
        let data = PlatformData(
            platform: .linkedin,
            metrics: ["posts_published": .int(5), "total_impressions": .int(4200)]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))

        #expect(prompt.contains("Posts: 5, 4,200 impressions"))

        // Scoped to this platform's own section rather than the whole prompt.
        // Asserting on the whole prompt has to be either loose — "Followers:"
        // is emitted by Mastodon and Jetpack too, so it would false-fail the
        // first time this test gained a second snapshot — or so narrow it stops
        // checking the thing it is named for. A bare "- Followers: " with
        // nothing after it passed both earlier versions.
        let section = try #require(linkedinSection(of: prompt))
        #expect(!section.contains("Followers"))
        #expect(!section.contains("Total engagements"))
        #expect(!section.contains("Unique members reached"))
    }

    @Test("One follower metric without the other still reads correctly")
    func linkedinPartialFollowerData() throws {
        // FOLLOWERS sheet present but new_followers absent — the parser only
        // writes it when the sum is above zero, so this is a real shape.
        let data = PlatformData(
            platform: .linkedin,
            metrics: ["total_followers": .int(8420)]
        )
        let prompt = assembler.assemble(makeInput(snapshots: try snaps(data)))

        #expect(prompt.contains("Followers: 8,420 total"))
        #expect(!prompt.contains("new this period"))
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
