import Testing
import Foundation
@testable import SocialBrain

@Suite("Prompt Assembler Tests")
struct PromptAssemblerTests {

    private let assembler = PromptAssembler()

    private func makeInput(snapshots: [PlatformData]) -> PromptAssembler.Input {
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

    @Test("Output contains header and date")
    func headerPresent() {
        let prompt = assembler.assemble(makeInput(snapshots: []))
        #expect(prompt.contains("Social Media & Publishing Analytics Report"))
        #expect(prompt.contains("March 26, 2026"))
        #expect(prompt.contains("Last 30 days"))
    }

    @Test("Output contains analysis request section")
    func analysisRequestPresent() {
        let prompt = assembler.assemble(makeInput(snapshots: []))
        #expect(prompt.contains("Key trends"))
        #expect(prompt.contains("Actionable recommendations"))
    }

    @Test("Mastodon section formats correctly")
    func mastodonSection() {
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
        let prompt = assembler.assemble(makeInput(snapshots: [data]))
        #expect(prompt.contains("## Mastodon"))
        #expect(prompt.contains("Followers: 2,500"))
        #expect(prompt.contains("Posts this period: 12"))
        #expect(prompt.contains("37.5 favourites"))
    }

    @Test("Buttondown section formats open rate as percentage")
    func buttondownSection() {
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
        let prompt = assembler.assemble(makeInput(snapshots: [data]))
        #expect(prompt.contains("## Buttondown"))
        #expect(prompt.contains("Subscribers: 1,500 (+42 new)"))
        #expect(prompt.contains("47.5%"))
        #expect(prompt.contains("11.0%"))
    }

    @Test("GoatCounter section lists top pages")
    func goatCounterSection() {
        let data = PlatformData(
            platform: .goatCounter,
            metrics: [
                "total_pageviews": .int(8421),
                "unique_visitors": .int(3102),
                "top_page_1":      .string("/blog/swift-tips"),
                "top_page_2":      .string("/blog/grdb-guide")
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: [data]))
        #expect(prompt.contains("## GoatCounter"))
        #expect(prompt.contains("Pageviews: 8,421"))
        #expect(prompt.contains("/blog/swift-tips"))
    }

    @Test("Bluesky section formats engagement per post")
    func blueskySection() {
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
        let prompt = assembler.assemble(makeInput(snapshots: [data]))
        #expect(prompt.contains("## Bluesky"))
        #expect(prompt.contains("Followers: 3,800"))
        #expect(prompt.contains("42.5 likes"))
    }

    @Test("Multiple platforms are sorted alphabetically")
    func alphabeticalOrder() {
        let mastodon = PlatformData(platform: .mastodon, metrics: ["followers_count": .int(100)])
        let bluesky  = PlatformData(platform: .bluesky,  metrics: ["followers_count": .int(200)])
        let prompt = assembler.assemble(makeInput(snapshots: [mastodon, bluesky]))
        let blueskyRange  = prompt.range(of: "## Bluesky")!
        let mastodonRange = prompt.range(of: "## Mastodon")!
        // Bluesky (B) comes before Mastodon (M) alphabetically
        #expect(blueskyRange.lowerBound < mastodonRange.lowerBound)
    }

    @Test("Platform with no known metrics produces no section")
    func emptySectionOmitted() {
        // A snapshot with metrics that don't match any known key for amazon
        let data = PlatformData(
            platform: .amazon,
            metrics: [:]  // no metrics at all
        )
        let prompt = assembler.assemble(makeInput(snapshots: [data]))
        #expect(!prompt.contains("## Amazon KDP"))
    }

    @Test("Vercel section formats deployment counts")
    func vercelSection() {
        let data = PlatformData(
            platform: .vercel,
            metrics: [
                "deployments":            .int(12),
                "production_deployments": .int(4),
                "error_deployments":      .int(1)
            ]
        )
        let prompt = assembler.assemble(makeInput(snapshots: [data]))
        #expect(prompt.contains("## Vercel"))
        #expect(prompt.contains("Deployments: 12 (4 production)"))
        #expect(prompt.contains("Failed deployments: 1"))
    }
}
