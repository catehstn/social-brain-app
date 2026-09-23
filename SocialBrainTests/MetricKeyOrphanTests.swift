import Testing
import Foundation
@testable import SocialBrain

/// Every metric a collector emits should be read by something, for the platform
/// that emitted it.
///
/// Metric keys are plain strings duplicated across five consumers with nothing
/// tying them to the collectors (#63), so a platform can be renamed into
/// invisibility: the import reports success and contributes nothing to the
/// prompt, the charts, the Feed or spike detection. That has happened three
/// times: `LinkedInXLSXParser` wrote four metrics nothing read (#114),
/// `LinkedInImporter` still writes `total_clicks`, which only *Buffer's*
/// consumers read (#163), and this test found two more on its first run (#170).
///
/// #163 is the reason this checks per platform rather than globally. Grepping
/// for `total_clicks` finds two consumers and looks reassuring; both are in the
/// `.buffer` branch. "Is this key read anywhere?" is the wrong question.
///
/// One direction only. A consumer reading a key no collector emits is the
/// mirror image, is not caught here, and has also happened — #171.
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
    /// is the same shape as the bug. #173 covers deriving it from the
    /// collectors instead. It still catches the case that has actually
    /// occurred — a key that is emitted and read by nobody — which it did on
    /// its first run, finding #170.
    private static let emitted: [Platform: Set<String>] = [
        .bluesky: ["avg_likes", "avg_replies", "avg_reposts", "followers_count",
                   "follows_count", "posts_count", "posts_truncated", "recent_posts"],
        .buffer: ["engagement_unavailable", "posts_sampled", "profiles_count", "scheduled_updates",
                  "sent_updates", "total_clicks", "total_likes", "total_reach", "top_profile_1"],
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
    func emittedKeysAreRead(platform: Platform) {
        guard let emitted = Self.emitted[platform] else { return }

        let read = Self.keysRead(for: platform)
        let orphans = emitted
            .filter { !Self.isRead($0, by: read) }
            .subtracting(Self.knownOrphans[platform] ?? [])

        let message: Comment = "\(platform.rawValue) emits \(orphans.sorted()) and nothing reads them"
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

    @Test("Every known orphan is a key that is still emitted",
          arguments: Platform.allCases)
    func knownOrphansAreStillEmitted(platform: Platform) {
        // Otherwise an entry — and the issue pointer that justifies it — rots
        // silently once the collector stops writing the key.
        let listed = Self.knownOrphans[platform] ?? []
        let stale = listed.subtracting(Self.emitted[platform] ?? [])

        let message: Comment = "\(platform.rawValue): \(stale.sorted()) is no longer emitted — drop it from knownOrphans"
        #expect(stale.isEmpty, message)
    }

    @Test("Every platform with a collector has an entry in the emitted table")
    func everyCollectedPlatformIsCovered() {
        // A new platform must not slip past the detector by simply being absent
        // from the table.
        // Every platform, including the file-export ones. Exempting those was
        // the first version of this guard and it exempted exactly the platforms
        // that produced #114, #163 and half of #170 — deleting Substack's whole
        // entry then left the suite green, silently dropping the platform, its
        // keys and its known orphan from the detector.
        let uncovered = Platform.allCases.filter { Self.emitted[$0] == nil }
        let message: Comment = "no emitted-key entry for \(uncovered.map(\.rawValue).sorted())"
        #expect(uncovered.isEmpty, message)
    }

    // MARK: - What each consumer reads

    /// The union of every consumer's reads for a platform.
    private static func keysRead(for platform: Platform) -> Set<String> {
        var keys = Set<String>()
        keys.formUnion(SpikeDetector.monitored(for: platform).map(\.key))
        keys.formUnion(DashboardViewModel.metricKeys(for: platform).map(\.key))
        keys.formUnion(promptKeys(for: platform))
        keys.formUnion(highReachKeys(for: platform))
        keys.formUnion(feedCardKeys(for: platform))
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

    /// The same probe for the Feed. Its metric reads are a fifth consumer, and
    /// leaving it out would report a key read *only* by the Feed as an orphan.
    private static func feedCardKeys(for platform: Platform) -> Set<String> {
        let all = emitted[platform] ?? []
        let full = feedCards(platform: platform, keys: all)
        return all.filter { feedCards(platform: platform, keys: all.subtracting([$0])) != full }
    }

    // MARK: - Probe helpers

    /// A value large enough to clear every floor and threshold in every
    /// consumer.
    ///
    /// 9.0 rather than a plausible rate, because `avg_*` keys are read two
    /// ways: as rates (thresholds above 0.40) and as counts —
    /// `HighReachDetector` wants `avg_favourites >= 5.0` for Mastodon and
    /// `avg_likes >= 5.0` for Bluesky. A rate-shaped 0.87 cleared the first and
    /// failed the second, so the high-reach probe returned nil for the full key
    /// set and reported *every* Mastodon and Bluesky key as unread. That is a
    /// false orphan, and the cure for a false orphan is an allowlist entry —
    /// which is how a real reader gets written off permanently. It renders as
    /// 900% in the prompt; the probe only cares whether the output changes.
    private static func sample(for key: String) -> MetricValue {
        if key.hasPrefix("avg_") || key == "ctr" { return .double(9.0) }
        if numberedFamilies.contains(where: { key.hasPrefix($0) }) { return .string("/sample") }
        if key.hasSuffix("_truncated") || key.hasSuffix("_sampled") || key.hasSuffix("_window")
            || key.hasSuffix("_unavailable") {
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
        // A throwaway label store, not `.shared`: the assembler's headers call
        // `PlatformInstance.displayName(using:)`, so the default would read the
        // real preferences and a stored label would change the prompt text this
        // detector probes.
        return PromptAssembler(labels: InstanceLabels(defaults: InMemoryKeyValueStore())).assemble(
            PromptAssembler.Input(
                periodLabel: "Last 30 days",
                reportDate: Date(timeIntervalSince1970: 1_767_225_600),
                snapshots: [PlatformInstance(platform: platform): snapshot],
                goal: .growReach,
                goalCustomText: ""
            )
        )
    }

    private static func feedCards(platform: Platform, keys: Set<String>) -> String {
        guard let snapshot = try? PlatformSnapshot(runID: 1, data: data(platform: platform, keys: keys))
        else { return "" }
        return FeedCardBuilder.build(
            snapshots: [PlatformInstance(platform: platform): snapshot],
            visibility: ScratchVisibility.make()
        ).map(\.snippet).sorted().joined(separator: "|")
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

// MARK: - Metric keys are spelled once (#63)

/// Stops the keys drifting back into literals.
///
/// `MetricKey` is only worth having while both ends use it. One consumer
/// written as `intMetric("total_clicks")` is enough to restore the old hazard:
/// renaming the constant then moves the collector and leaves that reader
/// asking for a key nobody writes, which is #114, #163 and #170.
///
/// **Tests keep their literals on purpose.** `emitted` above, and the
/// assertions in the collector suites, are the independent end: written
/// through the same constants they would agree with a changed value rather
/// than catch it. A sweep that "fixes" them removes the check.
///
/// Source-grepped rather than type-enforced. Making the dictionary key a type
/// would carry into the JSON blob in `platformSnapshot.metrics` and every row
/// already stored; that is a migration, not a rename. So the keys stay
/// `String` and this test is what keeps them spelled once.
@Suite("Metric key literals")
struct MetricKeyLiteralTests {

    /// Where a metric key can be passed: the accessors, the dictionary, and
    /// the two types that carry one.
    ///
    /// Deliberately not a bare `key:` — credentials are keyed by string too
    /// (`invalidCredential(key: "site_url")`, `field(key: "api_key")`), and a
    /// detector that cries about those gets switched off.
    private static let patterns = [
        #"intMetric\(\s*""#,
        #"doubleMetric\(\s*""#,
        #"stringMetric\(\s*""#,
        #"metricDouble\(\s*""#,
        #"metricString\(\s*""#,
        // Any dictionary, not one called `metrics`: collectors accumulate into
        // `totals` and friends too.
        #"\w*\[\s*"[a-z][a-z_0-9]+"\s*\]\s*=\s*\.(int|double|string)\("#,
        // A collector usually builds a dictionary literal rather than
        // assigning into one, so the key sits against a `MetricValue` case.
        #""[a-z][a-z_0-9]+"\s*:\s*\.(int|double|string)\("#,
        #"Monitored\(key:\s*""#
    ]

    /// Patterns that only make sense in one file.
    ///
    /// `DashboardViewModel.metricKeys` returns bare `(key, label)` tuples —
    /// the largest consumer, and a shape the patterns above cannot see: all 24
    /// of its sites could have been reverted to literals with the suite still
    /// green.
    ///
    /// Scoped by file rather than matched everywhere, because a bare pair of
    /// strings is far too common to flag globally — OAuth form fields are
    /// written `("client_name", "Social Brain")`, and a detector that shouts
    /// about those is one somebody turns off. A consumer that adopts the tuple
    /// shape needs adding here.
    private static let perFilePatterns = [
        "DashboardViewModel.swift": [#"\(\s*"[a-z][a-z_0-9]+"\s*,\s*""#]
    ]

    @Test("No metric key is written as a literal outside MetricKey.swift")
    func metricKeysAreNotLiterals() throws {
        let roots = ["SocialBrain", "SocialBrainMCP"].map {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent($0)
        }

        var offenders: [String] = []
        var scanned = 0
        for root in roots {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            let swift = (files?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            #expect(!swift.isEmpty, "No Swift sources under \(root.lastPathComponent) — this would pass vacuously")

            for file in swift where file.lastPathComponent != "MetricKey.swift" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                scanned += 1
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { continue }
                    let patterns = Self.patterns
                        + (Self.perFilePatterns[file.lastPathComponent] ?? [])
                    for pattern in patterns where trimmed.range(of: pattern, options: .regularExpression) != nil {
                        offenders.append("\(file.lastPathComponent):\(number + 1): \(trimmed)")
                    }
                }
            }
        }

        #expect(scanned > 0)
        let message: Comment = """
            \(offenders.sorted().joined(separator: "\n")) \
            — pass a `MetricKey` constant instead of a literal.
            """
        #expect(offenders.isEmpty, message)
    }

    @Test("No two metric keys share a value")
    func metricKeyValuesAreUnique() throws {
        // A duplicated value is one metric wearing two names: both consumers
        // read the same column and one of them is wrong about what it means.
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SocialBrain/Models/MetricKey.swift")
        let text = try String(contentsOf: file, encoding: .utf8)

        let declarations = text
            .split(separator: "\n")
            .compactMap { line -> (name: String, value: String)? in
                guard let match = line.range(of: #"static let (\w+)\s*=\s*"([^"]+)""#,
                                             options: .regularExpression) else { return nil }
                let parts = line[match].split(separator: "\"")
                guard parts.count >= 2 else { return nil }
                let name = parts[0].replacingOccurrences(of: "static let ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ="))
                return (name, String(parts[1]))
            }
        #expect(declarations.count > 40, "Found \(declarations.count) constants — the parser has drifted")

        let duplicates = Dictionary(grouping: declarations, by: \.value).filter { $0.value.count > 1 }
        let message: Comment = "\(duplicates.map { "\($0.key): \($0.value.map(\.name))" }.sorted())"
        #expect(duplicates.isEmpty, message)
    }
}
