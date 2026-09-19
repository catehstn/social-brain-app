import Testing
import Foundation
@testable import SocialBrain

/// Every metric a collector emits should be read by something, for the platform
/// that emitted it.
///
/// Metric keys are plain strings duplicated across four consumers with nothing
/// tying them to the collectors (#63), so a platform can be renamed into
/// invisibility: the import reports success and contributes nothing to the
/// prompt, the charts or spike detection. That has happened twice —
/// `LinkedInXLSXParser` wrote four metrics nothing read (#114), and
/// `LinkedInImporter` still writes `total_clicks`, which only *Buffer's*
/// consumers read (#163).
///
/// #163 is the reason this checks per platform rather than globally. Grepping
/// for `total_clicks` finds two consumers and looks reassuring; both are in the
/// `.buffer` branch. "Is this key read anywhere?" is the wrong question.
@Suite("Metric key orphans")
struct MetricKeyOrphanTests {

    // MARK: - What each collector emits

    /// Keys whose names carry a trailing index — `top_page_1`, `top_page_2`, …
    /// A consumer reading any member counts as reading the family.
    private static let numberedFamilies: Set<String> = [
        "top_page", "top_query", "top_story", "top_profile", "top_event_type"
    ]

    /// The keys each platform's collector or importer writes.
    ///
    /// Hand-maintained, and that is this test's weak point: a key added to a
    /// collector without being added here is invisible to the detector, which
    /// is the same shape as the bug. #170 covers deriving it from the
    /// collectors instead. It still catches the case that has actually
    /// occurred — a key that is emitted and read by nobody — which it did on
    /// its first run, finding #170.
    private static let emitted: [Platform: Set<String>] = [
        .bluesky: ["avg_likes", "avg_replies", "avg_reposts", "followers_count",
                   "follows_count", "posts_count", "posts_truncated", "recent_posts"],
        .buffer: ["posts_sampled", "profiles_count", "scheduled_updates", "sent_updates",
                  "total_clicks", "total_likes", "total_reach", "top_profile_1"],
        .buttondown: ["avg_click_rate", "avg_open_rate", "emails_sampled", "emails_sent",
                      "new_subscribers", "subscriber_count"],
        .calendly: ["cancelled_count", "events_count", "unique_invitees", "top_event_type_1"],
        .goatCounter: ["total_visits", "top_page_1"],
        .googleSearchConsole: ["avg_position", "clicks", "ctr", "impressions",
                               "top_query_1", "top_page_1"],
        .hackerNews: ["mention_count", "mentions_sampled", "total_comments",
                      "total_points", "top_story_1"],
        .jetpack: ["followers_blog", "followers_comment", "total_comments", "total_likes",
                   "total_views", "total_visitors", "views_window"],
        .mastodon: ["avg_favourites", "avg_reblogs", "avg_replies", "followers_count",
                    "following_count", "posts_truncated", "recent_posts", "statuses_count"],
        // Both import paths, because a LinkedIn snapshot is one shape or the
        // other and each must be readable.
        .linkedin: ["avg_ctr", "posts_published", "total_clicks", "total_comments",
                    "total_impressions", "total_likes", "total_shares",
                    "members_reached", "new_followers", "total_engagements", "total_followers"],
        .oreilly: ["titles_count", "total_completions", "total_page_views", "total_unique_users"],
        .substack: ["avg_click_rate", "avg_open_rate", "posts_published"]
    ]

    /// Emitted keys that nothing reads, each with the issue that owns it.
    ///
    /// Deliberately an allowlist: an orphan has to be written down, with a
    /// reason, rather than quietly tolerated.
    private static let knownOrphans: [Platform: Set<String>] = [
        // #163 — written by LinkedInImporter; only Buffer's consumers read it.
        .linkedin: ["total_clicks"],
        // #170, both found by this test on its first run.
        // Substack computes a click rate at two sites and shows it nowhere;
        // the three consumers that read the key are all in the .buttondown
        // branch, which is the #163 shape again.
        .substack: ["avg_click_rate"],
        // Describes the account setup rather than the period, so "stop
        // collecting it" may be the better answer for this one.
        .buffer: ["profiles_count"]
    ]

    // MARK: - The detector

    @Test("Every metric a platform emits is read by something",
          arguments: Platform.allCases)
    func emittedKeysAreRead(platform: Platform) throws {
        guard let emitted = Self.emitted[platform] else { return }

        let read = Self.keysRead(for: platform)
        let orphans = emitted
            .filter { !Self.isRead($0, by: read) }
            .subtracting(Self.knownOrphans[platform] ?? [])

        let message: Comment = """
            \(platform.rawValue) emits \(orphans.sorted()) and nothing reads them.             Surface them, stop collecting them, or add them to knownOrphans with an issue.
            """
        #expect(orphans.isEmpty, message)
    }

    @Test("Known orphans are still orphans, so the list shrinks as they are fixed",
          arguments: Platform.allCases)
    func knownOrphansAreStillOrphaned(platform: Platform) {
        guard let orphans = Self.knownOrphans[platform], !orphans.isEmpty else { return }

        let read = Self.keysRead(for: platform)
        let nowRead = orphans.filter { Self.isRead($0, by: read) }

        let message: Comment = "\(platform.rawValue): \(nowRead.sorted()) is read now — remove it from knownOrphans"
        #expect(nowRead.isEmpty, message)
    }

    @Test("Every platform with a collector has an entry in the emitted table")
    func everyCollectedPlatformIsCovered() {
        // A new platform must not slip past the detector by simply being absent
        // from the table.
        let uncovered = Platform.allCases.filter { platform in
            platform.authType != .fileExport
                && Self.emitted[platform] == nil
                && !Self.platformsWithoutMetrics.contains(platform)
        }
        let message: Comment = "no emitted-key entry for \(uncovered.map(\.rawValue).sorted())"
        #expect(uncovered.isEmpty, message)
    }

    /// Platforms that legitimately emit nothing yet.
    private static let platformsWithoutMetrics: Set<Platform> = []

    // MARK: - What each consumer reads

    /// The union of every consumer's reads for a platform.
    private static func keysRead(for platform: Platform) -> Set<String> {
        var keys = Set<String>()
        keys.formUnion(SpikeDetector.monitored(for: platform).map(\.key))
        keys.formUnion(DashboardViewModel.metricKeys(for: platform).map(\.key))
        keys.formUnion(promptKeys(for: platform))
        keys.formUnion(highReachKeys(for: platform))
        return keys
    }

    /// Which keys the prompt actually renders, found by removing one at a time.
    ///
    /// Probed rather than declared: a declared list is another copy that can
    /// drift, which is the problem this test exists for. Assembling with every
    /// key and then without one says exactly whether that key reaches the page.
    private static func promptKeys(for platform: Platform) -> Set<String> {
        let all = emitted[platform] ?? []
        let full = assemble(platform: platform, keys: all)
        return all.filter { assemble(platform: platform, keys: all.subtracting([$0])) != full }
    }

    /// The same probe for high-reach detection, which reads a handful of keys
    /// per platform and produces a card only above a threshold — hence values
    /// far above any of them.
    private static func highReachKeys(for platform: Platform) -> Set<String> {
        let all = emitted[platform] ?? []
        guard let full = highReachMessage(platform: platform, keys: all) else { return [] }
        return all.filter { highReachMessage(platform: platform, keys: all.subtracting([$0])) != full }
    }

    // MARK: - Probe helpers

    /// A value large enough to clear every floor and threshold, as both an int
    /// and a rate — rates are read as fractions, so 0.87 is a high one.
    private static func sample(for key: String) -> MetricValue {
        if key.hasPrefix("avg_") || key == "ctr" { return .double(0.87) }
        if key == "avg_position" { return .double(3.5) }
        if numberedFamilies.contains(where: { key.hasPrefix($0) }) { return .string("/sample") }
        if key.hasSuffix("_truncated") || key.hasSuffix("_sampled") || key.hasSuffix("_window") {
            return .string("a note")
        }
        return .int(9_000)
    }

    private static func data(platform: Platform, keys: Set<String>) -> PlatformData {
        PlatformData(platform: platform,
                     metrics: Dictionary(uniqueKeysWithValues: keys.map { ($0, sample(for: $0)) }))
    }

    private static func assemble(platform: Platform, keys: Set<String>) -> String {
        let snapshot = try? PlatformSnapshot(runID: 1, data: data(platform: platform, keys: keys))
        guard let snapshot else { return "" }
        return PromptAssembler().assemble(
            PromptAssembler.Input(
                periodLabel: "Last 30 days",
                reportDate: Date(timeIntervalSince1970: 1_767_225_600),
                snapshots: [PlatformInstance(platform: platform): snapshot],
                goal: .growReach,
                goalCustomText: ""
            )
        )
    }

    private static func highReachMessage(platform: Platform, keys: Set<String>) -> String? {
        let snapshot = try? PlatformSnapshot(runID: 1, data: data(platform: platform, keys: keys))
        guard let snapshot else { return nil }
        let items = HighReachDetector().detect(
            snapshots: [PlatformInstance(platform: platform): snapshot]
        )
        return items.first(where: { $0.platform == platform })?.message
    }

    /// `top_page_1` is read if a consumer reads any member of `top_page_*`.
    private static func isRead(_ key: String, by read: Set<String>) -> Bool {
        if read.contains(key) { return true }
        guard let family = numberedFamilies.first(where: { key.hasPrefix($0) }) else { return false }
        return read.contains { $0.hasPrefix(family) }
    }
}
