import Testing
import Foundation
@testable import SocialBrain

@Suite("Spike Detector Tests")
struct SpikeDetectorTests {

    /// Nothing hidden, and backed by memory rather than UserDefaults.standard.
    /// Without this the suite reads the developer's own hidden-platform
    /// settings, so hiding LinkedIn in the real app would fail these tests
    /// (#80) — the same non-hermeticity #127 fixed for the Keychain.
    private let noneHidden = ScratchVisibility.make()

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

    // MARK: - Search rank reads in rank units (#126)

    @Test("A worsening search rank is not reported with a plus sign")
    func worseningRankHasNoPlusSign() throws {
        // Sliding from position 5 to 7 rendered as "+40.0% Avg Position on
        // Google Search Console". A plus sign and a rising number both read as
        // good news, so the user was congratulated for getting worse — and the
        // same inversion would have reached any colour or icon built on
        // isIncrease.
        let previous = try makeSnapshot(platform: .googleSearchConsole,
                                        metrics: ["avg_position": .double(5)])
        let current  = try makeSnapshot(platform: .googleSearchConsole,
                                        metrics: ["avg_position": .double(7)])

        let alert = try #require(
            SpikeDetector().detect(current: current, previous: previous)
                .first { $0.metricKey == "avg_position" }
        )

        #expect(!alert.summary.contains("+"))
        #expect(!alert.summary.contains("%"))
        #expect(alert.summary == "Avg Position 5.0 → 7.0 on Google Search Console")
    }

    @Test("An improving search rank reads the same way, in rank units")
    func improvingRankIsAlsoInRankUnits() throws {
        // The other direction, because "don't show a plus" could be satisfied
        // by simply dropping the sign and leaving a percentage that still means
        // very little for a rank.
        let previous = try makeSnapshot(platform: .googleSearchConsole,
                                        metrics: ["avg_position": .double(10)])
        let current  = try makeSnapshot(platform: .googleSearchConsole,
                                        metrics: ["avg_position": .double(6)])

        let alert = try #require(
            SpikeDetector().detect(current: current, previous: previous)
                .first { $0.metricKey == "avg_position" }
        )

        #expect(alert.summary == "Avg Position 10.0 → 6.0 on Google Search Console")
    }

    @Test("Every other Search Console metric still reads as a percentage")
    func otherMetricsKeepPercentages() throws {
        // The rank rendering is per metric, not per platform: clicks on the
        // same platform must be unaffected.
        let previous = try makeSnapshot(platform: .googleSearchConsole,
                                        metrics: ["clicks": .double(100)])
        let current  = try makeSnapshot(platform: .googleSearchConsole,
                                        metrics: ["clicks": .double(150)])

        let alert = try #require(
            SpikeDetector().detect(current: current, previous: previous)
                .first { $0.metricKey == "clicks" }
        )

        #expect(alert.summary == "+50.0% Clicks on Google Search Console")
    }

    @Test("LinkedIn follower growth is detected, as it is for every other platform")
    func linkedinFollowerSpike() throws {
        // Spike alerts are the only route by which a LinkedIn metric becomes a
        // Feed card. Mastodon and Bluesky are monitored on followers_count and
        // Jetpack on followers_blog, but LinkedIn was monitored only on
        // impressions and likes — and an XLSX snapshot contains neither likes
        // nor posts, so follower growth produced no card at all (#114).
        //
        // +30%, comfortably past the 20% threshold — the point here is whether
        // the metric is watched at all, not where the boundary sits.
        let previous = try makeSnapshot(platform: .linkedin,
                                        metrics: ["total_followers": .int(8000)])
        let current  = try makeSnapshot(platform: .linkedin,
                                        metrics: ["total_followers": .int(10_400)])

        let alerts = SpikeDetector().detect(current: current, previous: previous)

        #expect(alerts.contains { $0.summary.contains("Followers") })
    }

    @Test("No platform watches the same metric twice",
          arguments: Platform.allCases)
    func monitoredKeysAreUnique(platform: Platform) {
        // The GoatCounter duplicate below is the instance that happened; this
        // is the class. A duplicated entry produces two identical alerts, and
        // SpikeNotifier sends every one of them, so the same line arrives twice
        // in a notification (#156). Cheap to guard for every platform at once.
        let keys = SpikeDetector.monitored(for: platform).map(\.key)

        let duplicates = keys.filter { key in keys.filter { $0 == key }.count > 1 }
        #expect(keys.count == Set(keys).count,
                "\(platform.rawValue) watches a metric twice: \(Set(duplicates).sorted())")
    }

    @Test("A GoatCounter visits spike produces exactly one alert")
    func goatCounterVisitsSpikeIsNotDuplicated() throws {
        // There was no GoatCounter spike test at all, which is how a duplicated
        // Monitored entry survived a search-and-replace: FeedCardBuilder shows
        // only the first alert, but SpikeNotifier sends them all, so the user's
        // notification carried the same line twice (#156).
        let previous = try makeSnapshot(platform: .goatCounter,
                                        metrics: ["total_visits": .int(1000)])
        let current  = try makeSnapshot(platform: .goatCounter,
                                        metrics: ["total_visits": .int(1500)])

        let alerts = SpikeDetector().detect(current: current, previous: previous)

        #expect(alerts.count == 1)
        #expect(alerts.first?.metricKey == "total_visits")
    }

    @Test("spike detected on 25% increase")
    func spikeDetectedOnIncrease() throws {
        let previous = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(1000)])
        let current  = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(1250)])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        #expect(alerts.count == 1)
        #expect(alerts.first?.metricKey == "followers_count")
        #expect(alerts.first?.isIncrease == true)
        #expect(abs(try #require(alerts.first).percentChange - 25.0) < 0.01)
    }

    @Test("spike detected on 30% decrease")
    func spikeDetectedOnDecrease() throws {
        let previous = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(1000)])
        let current  = try makeSnapshot(platform: .mastodon,
                                        metrics: ["followers_count": .int(700)])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        #expect(alerts.count == 1)
        #expect(alerts.first?.isIncrease == false)
        #expect(abs(try #require(alerts.first).percentChange - (-30.0)) < 0.01)
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
        #expect(alerts.first?.metricKey == "followers_count")  // +50% first
        #expect(alerts.dropFirst().first?.metricKey == "avg_favourites")   // +25% second
    }

    @Test("summary string is well-formed for increase")
    func summaryStringForIncrease() throws {
        let previous = try makeSnapshot(platform: .bluesky,
                                        metrics: ["followers_count": .int(1000)])
        let current  = try makeSnapshot(platform: .bluesky,
                                        metrics: ["followers_count": .int(1250)])

        let alerts = SpikeDetector(threshold: 20).detect(current: current, previous: previous)
        #expect(alerts.count == 1)
        let summary = try #require(alerts.first).summary
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
        let summary = try #require(alerts.first).summary
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
            snapshots: [PlatformInstance(platform: .mastodon): newer],
            previousSnapshots: [PlatformInstance(platform: .mastodon): older],
            visibility: noneHidden)
        let spikes = cards.filter { $0.cardType == .spikeAlert }
        #expect(spikes.count == 1)
        #expect(spikes.first?.platform == .mastodon)
    }

    @Test("no spike cards when change is below threshold")
    func noSpikeCardsWhenBelowThreshold() throws {
        let older = try makeSnapshot(platform: .mastodon,
                                     metrics: ["followers_count": .int(1000)])
        let newer = try makeSnapshot(platform: .mastodon,
                                     metrics: ["followers_count": .int(1050)])

        let cards = FeedCardBuilder.build(
            snapshots: [PlatformInstance(platform: .mastodon): newer],
            previousSnapshots: [PlatformInstance(platform: .mastodon): older],
            visibility: noneHidden)
        let spikes = cards.filter { $0.cardType == .spikeAlert }
        #expect(spikes.isEmpty)
    }

    @Test("no spike cards when previousSnapshots is empty")
    func noSpikeCardsWhenNoPrevious() throws {
        let newer = try makeSnapshot(platform: .mastodon,
                                     metrics: ["followers_count": .int(1500)])

        let cards = FeedCardBuilder.build(
            snapshots: [PlatformInstance(platform: .mastodon): newer],
            previousSnapshots: [:],
            visibility: noneHidden)
        let spikes = cards.filter { $0.cardType == .spikeAlert }
        #expect(spikes.isEmpty)
    }
    // MARK: - The magnitude floor

    @Test("A big percentage swing between tiny numbers is not a spike")
    func tinyNumbersAreNotSpikes() throws {
        // The case that made this necessary: 0.5 → 0.7 average favourites is a
        // 40% change and means nothing. Since #109 the background refresh fires
        // these with sound at a moment the system picks, so the cost is
        // teaching the user to dismiss notifications.
        let previous = try makeSnapshot(platform: .mastodon, metrics: ["avg_favourites": .double(0.5)])
        let current  = try makeSnapshot(platform: .mastodon, metrics: ["avg_favourites": .double(0.7)])

        #expect(SpikeDetector().detect(current: current, previous: previous).isEmpty)

        // The other side of the bracket. 2.0 → 2.6 is +30% and still under the
        // floor, so lowering the floor to catch it fails here.
        let justUnder = try makeSnapshot(platform: .mastodon, metrics: ["avg_favourites": .double(2.6)])
        let below     = try makeSnapshot(platform: .mastodon, metrics: ["avg_favourites": .double(2.0)])

        #expect(SpikeDetector().detect(current: justUnder, previous: below).isEmpty)
    }

    @Test("A real shift in a small-but-meaningful average still surfaces")
    func meaningfulAveragesStillSurface() throws {
        // The floor is on the values, not the change, precisely so this
        // survives: 3.5 → 4.4 average favourites is a genuine 26% shift.
        //
        // Together with tinyNumbersAreNotSpikes below, this brackets the floor
        // rather than merely clearing it: 2.6 must stay silent and 4.4 must
        // fire, so the constant is pinned into (2.6, 4.4]. An earlier version
        // used 4 → 5, which passes at a floor of 5 as well as 3 — the value the
        // PR argues for was not held by anything.
        let previous = try makeSnapshot(platform: .mastodon, metrics: ["avg_favourites": .double(3.5)])
        let current  = try makeSnapshot(platform: .mastodon, metrics: ["avg_favourites": .double(4.4)])

        #expect(SpikeDetector().detect(current: current, previous: previous).count == 1)
    }

    @Test("Rates are judged on a rate-sized scale, not a count-sized one")
    func ratesUseTheirOwnFloor() throws {
        // Rates are 0–1 fractions, so a count-sized floor would suppress every
        // one of them.
        let previous = try makeSnapshot(platform: .buttondown, metrics: ["avg_open_rate": .double(0.40)])
        let current  = try makeSnapshot(platform: .buttondown, metrics: ["avg_open_rate": .double(0.55)])

        #expect(SpikeDetector().detect(current: current, previous: previous).count == 1)
    }

    @Test("A tiny rate wobbling is still suppressed")
    func tinyRatesAreSuppressed() throws {
        // 0.5% → 0.7% click rate is +40% and is noise.
        let previous = try makeSnapshot(platform: .buttondown, metrics: ["avg_click_rate": .double(0.005)])
        let current  = try makeSnapshot(platform: .buttondown, metrics: ["avg_click_rate": .double(0.007)])

        #expect(SpikeDetector().detect(current: current, previous: previous).isEmpty)
    }

    @Test("A small search CTR moving is not filtered out as a tiny rate")
    func searchCTRIsNotMutedByTheRateFloor() throws {
        // Site-wide search CTR for a personal blog lives around 1–5%, an order
        // of magnitude below an email open rate. A floor set for open rates
        // mutes this metric permanently — 2% → 3.5% is a real shift in how
        // often a search result gets clicked, and the user would never see it.
        let previous = try makeSnapshot(platform: .googleSearchConsole, metrics: ["ctr": .double(0.02)])
        let current  = try makeSnapshot(platform: .googleSearchConsole, metrics: ["ctr": .double(0.035)])

        let alerts = SpikeDetector().detect(current: current, previous: previous)
        #expect(alerts.map(\.metricKey) == ["ctr"])
    }

    // MARK: - Raw event counts are not averages

    @Test("One booking then two is news, however small the numbers")
    func smallCountsOfDiscreteEventsStillSurface() throws {
        // An average can move without anything happening. A count cannot: two
        // bookings are two real bookings. An earlier version of the floor
        // applied one count-sized number to every metric and muted exactly
        // this, so a doubled month produced complete silence.
        //
        // Was Amazon units_sold until that platform was retired; the argument
        // is about raw event counts, not about books.
        //
        // Deliberately below averageFloor on both sides. Fixtures that clear it
        // still pass if someone "consistently" applies the average floor here,
        // which is the regression actually worth catching.
        let previous = try makeSnapshot(platform: .calendly, metrics: ["events_count": .double(1)])
        let current  = try makeSnapshot(platform: .calendly, metrics: ["events_count": .double(2)])

        let alerts = SpikeDetector().detect(current: current, previous: previous)
        #expect(alerts.map(\.metricKey) == ["events_count"])
    }

    @Test("Dropping off Hacker News altogether is reported")
    func collapseToZeroIsReported() throws {
        let previous = try makeSnapshot(platform: .hackerNews, metrics: ["mention_count": .double(2)])
        let current  = try makeSnapshot(platform: .hackerNews, metrics: ["mention_count": .double(0)])

        let alerts = SpikeDetector().detect(current: current, previous: previous)
        #expect(alerts.map(\.metricKey) == ["mention_count"])
        #expect(alerts.first?.percentChange == -100)
    }

    @Test("Climbing the search rankings is not muted for being a small number")
    func averagePositionHasNoFloor() throws {
        // Rank is the one metric where small is the *best* state, so a floor
        // would suppress precisely the good news. Named avg_position, so it is
        // the likeliest metric to get the average floor applied by mistake —
        // the fixture sits below that floor so the mistake fails here.
        let previous = try makeSnapshot(platform: .googleSearchConsole, metrics: ["avg_position": .double(2.5)])
        let current  = try makeSnapshot(platform: .googleSearchConsole, metrics: ["avg_position": .double(1.8)])

        let alerts = SpikeDetector().detect(current: current, previous: previous)
        #expect(alerts.map(\.metricKey) == ["avg_position"])
    }
}
