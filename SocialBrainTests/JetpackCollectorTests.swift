import Testing
import Foundation
@testable import SocialBrain

@Suite("Jetpack Collector Tests")
struct JetpackCollectorTests {

    private static let siteID = "12345678"

    // Both fixtures follow the shape of a live response captured on 2026-09-22
    // (#75): same field names, nesting and types. Every value is invented.
    //
    // Note what `stats` does *not* have: `likes_today`. The collector used to
    // require it, and the API does not send it, so every live run failed.
    private static let statsJSON = """
    {
      "date": "2026-03-26",
      "stats": {
        "visitors_today": 7,
        "visitors_yesterday": 31,
        "visitors": 90210,
        "views_today": 9,
        "views_yesterday": 40,
        "views_best_day": "2025-01-15",
        "views_best_day_total": 2048,
        "views": 123456,
        "comments": 342,
        "posts": 250,
        "followers_blog": 1240,
        "followers_comments": 85,
        "comments_per_month": 0,
        "comments_most_active_recent_day": "2020-01-01 00:00:00",
        "comments_most_active_time": "N/A",
        "comments_spam": 0,
        "categories": 12,
        "tags": 300,
        "shares": 0,
        "shares_twitter": 0,
        "shares_linkedin": 0,
        "shares_facebook": 0
      },
      "visits": {
        "date": "2026-03-26",
        "unit": "day",
        "fields": ["period", "views", "visitors"],
        "data": [
          ["2026-03-25", 1, 1]
        ],
        "utc_offset": "+00:00"
      },
      "utc_offset": "+00:00"
    }
    """

    private static let visitsJSON = """
    {
      "date": "2026-03-26",
      "unit": "day",
      "fields": ["period", "views", "visitors", "likes", "reblogs", "comments", "posts"],
      "data": [
        ["2026-03-23", 201, 55, 5, 0, 1, 1],
        ["2026-03-24", 143, 38, 0, 0, 0, 0],
        ["2026-03-25", 156, 42, 7, 0, 2, 0]
      ],
      "utc_offset": "+00:00"
    }
    """

    private var session: MockURLSession {
        MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats":        (Self.statsJSON, 200),
            "/rest/v1.1/sites/\(Self.siteID)/stats/visits": (Self.visitsJSON, 200)
        ])
    }

    private var credentials: Credentials {
        Credentials(["access_token": "test-token", "site_code": Self.siteID])
    }

    // MARK: - Metric parsing

    @Test("Parses follower count and comment subscribers")
    func parsesFollowers() async throws {
        let data = try await JetpackCollector(session: session).collect(since: .distantPast, credentials: credentials)
        #expect(data.platform == .jetpack)
        #expect(data.intMetric("followers_blog") == 1240)
        #expect(data.intMetric("followers_comment") == 85)
    }

    @Test("Parses total comments")
    func parsesTotalComments() async throws {
        let data = try await JetpackCollector(session: session).collect(since: .distantPast, credentials: credentials)
        #expect(data.intMetric("total_comments") == 342)
    }

    @Test("Likes are summed over the window from the visits likes column")
    func parsesLikes() async throws {
        // 5 + 0 + 7. The summary's `likes_today` does not exist on the live API.
        let data = try await JetpackCollector(session: session).collect(since: .distantPast, credentials: credentials)
        #expect(data.intMetric("total_likes") == 12)
    }

    @Test("A stats response without likes_today still decodes (#75)")
    func statsWithoutLikesTodayDecodes() async throws {
        // Regression: the live API sends no `likes_today`, and requiring it
        // failed the whole decode ("'stats.likes_today' missing"), so Jetpack
        // produced nothing at all.
        let minimal = """
        { "stats": { "followers_blog": 3, "followers_comments": 1, "comments": 2 } }
        """
        let sess = MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats":        (minimal, 200),
            "/rest/v1.1/sites/\(Self.siteID)/stats/visits": (Self.visitsJSON, 200)
        ])
        let data = try await JetpackCollector(session: sess).collect(since: .distantPast, credentials: credentials)
        #expect(data.intMetric("followers_blog") == 3)
        #expect(data.intMetric("total_views") == 500)
    }

    @Test("A missing summary field fails loudly and names the field")
    func missingSummaryFieldFails() async throws {
        // Deliberately not tolerated: a follower count that silently vanishes
        // is worse than a decode error naming it.
        let sess = MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats":        ("{ \"stats\": {\"followers_comments\": 1, \"comments\": 2} }", 200),
            "/rest/v1.1/sites/\(Self.siteID)/stats/visits": (Self.visitsJSON, 200)
        ])
        await #expect {
            try await JetpackCollector(session: sess).collect(since: .distantPast, credentials: self.credentials)
        } throws: { error in
            error.localizedDescription.contains("followers_blog")
        }
    }

    @Test("Likes are omitted when the visits response has no likes column")
    func missingLikesColumnIsOmitted() async throws {
        let noLikes = """
        { "date": "2026-03-26", "unit": "day", "fields": ["period", "views", "visitors"],
          "data": [["2026-03-25", 4, 3]] }
        """
        let sess = MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats":        (Self.statsJSON, 200),
            "/rest/v1.1/sites/\(Self.siteID)/stats/visits": (noLikes, 200)
        ])
        let data = try await JetpackCollector(session: sess).collect(since: .distantPast, credentials: credentials)
        #expect(data.metrics["total_likes"] == nil)
        #expect(data.intMetric("total_views") == 4)
    }

    @Test("A likes column of zeros is a real zero and is reported")
    func zeroLikesAreReported() async throws {
        // The API sent the column and it summed to nothing: that is data, unlike
        // a missing column. The old code dropped any zero.
        let zeroLikes = """
        { "date": "2026-03-26", "unit": "day", "fields": ["period", "views", "visitors", "likes"],
          "data": [["2026-03-25", 4, 3, 0]] }
        """
        let sess = MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats":        (Self.statsJSON, 200),
            "/rest/v1.1/sites/\(Self.siteID)/stats/visits": (zeroLikes, 200)
        ])
        let data = try await JetpackCollector(session: sess).collect(since: .distantPast, credentials: credentials)
        #expect(data.intMetric("total_likes") == 0)
    }

    @Test("Sums visit data across all rows")
    func sumsVisits() async throws {
        let data = try await JetpackCollector(session: session).collect(since: .distantPast, credentials: credentials)
        // views: 156 + 143 + 201 = 500
        // visitors: 42 + 38 + 55 = 135
        #expect(data.intMetric("total_views") == 500)
        #expect(data.intMetric("total_visitors") == 135)
    }

    @Test("Views and visitors are omitted when their columns are missing")
    func handlesEmptyVisits() async throws {
        let emptyVisits = """
        { "date": "2026-03-26", "unit": "day", "fields": ["period"], "data": [] }
        """
        let sess = MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats":        (Self.statsJSON, 200),
            "/rest/v1.1/sites/\(Self.siteID)/stats/visits": (emptyVisits, 200)
        ])
        let data = try await JetpackCollector(session: sess).collect(since: .distantPast, credentials: credentials)
        // Not 0: a response with no views column is not a site nobody visited.
        #expect(data.metrics["total_views"] == nil)
        #expect(data.metrics["total_visitors"] == nil)
        #expect(data.metrics["total_likes"] == nil)
    }

    @Test("A window with no rows is a real zero")
    func noRowsIsZero() async throws {
        let noRows = """
        { "date": "2026-03-26", "unit": "day", "fields": ["period", "views", "visitors", "likes"], "data": [] }
        """
        let sess = MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats":        (Self.statsJSON, 200),
            "/rest/v1.1/sites/\(Self.siteID)/stats/visits": (noRows, 200)
        ])
        let data = try await JetpackCollector(session: sess).collect(since: .distantPast, credentials: credentials)
        #expect(data.intMetric("total_views") == 0)
        #expect(data.intMetric("total_visitors") == 0)
        #expect(data.intMetric("total_likes") == 0)
    }

    // MARK: - Error cases

    private static let visitsPath = "/rest/v1.1/sites/\(siteID)/stats/visits"

    // MARK: - What goes on the wire

    @Test("Every request carries the token as a Bearer header")
    func requestsAreAuthenticated() async throws {
        // Both endpoints need it. A collector that authenticated one and not the
        // other would pass a first-request check, and the unauthenticated half
        // would come back as an error the user reads as a broken token.
        let mock = session
        _ = try await JetpackCollector(session: mock).collect(since: .distantPast, credentials: credentials)

        let paths = Set(mock.requestedURLs.map(\.path))
        #expect(paths.count == 2)
        for path in paths {
            #expect(mock.headerValues("Authorization", path: path) == ["Bearer test-token"],
                    "missing or wrong Authorization on \(path)")
        }
    }

    @Test("A site ID needing escapes reaches the path encoded exactly once")
    func siteIDIsEncodedOnce() async throws {
        // A WordPress.com site can be addressed by domain as well as numeric ID,
        // and a domain needs no escaping — so a `%25` check against `12345678`
        // guards nothing at all, which is what the first version of this test
        // did. Give it something to encode.
        //
        // #68 is the shape: Google Search Console encoded its site URL twice, so
        // every request asked for `sites/https%253A%2F%2F…` — a property that
        // cannot exist — while the result-level tests stayed green.
        let siteID = "my site.example.com"
        let mock = MockURLSession([
            "/rest/v1.1/sites/my%20site.example.com/stats":        (Self.statsJSON, 200),
            "/rest/v1.1/sites/my%20site.example.com/stats/visits": (Self.visitsJSON, 200)
        ])
        _ = try await JetpackCollector(session: mock).collect(
            since: .distantPast,
            credentials: Credentials(["access_token": "test-token", "site_code": siteID])
        )

        // Reaching the fixtures at all is half the assertion — MockURLSession
        // matches on percentEncodedPath, so a double-encoded request throws
        // noFixture rather than matching.
        #expect(mock.requestedURLs.count == 2)
        for url in mock.requestedURLs {
            #expect(url.absoluteString.contains("my%20site.example.com"))
            #expect(!url.absoluteString.contains("%2520"), "double-encoded: \(url)")
        }
    }

    @Test("The window is requested in days, so quantity means days")
    func visitsAreRequestedInDays() async throws {
        // unit and quantity are read together: quantity=90 is ninety days,
        // weeks or months depending on unit, and the rest of this suite — and
        // views_window's wording — assumes days.
        //
        // #143 says deleting `unit` silently changes the scale. It does not:
        // the v1 reference documents `unit` as "One of: day, week or month
        // Default: 'day'", so dropping it leaves the behaviour unchanged. (The
        // v1.1 page 404s; JetpackCollector.maximumDays records the same.) What
        // this pins is someone *changing* day to week, which would rescale the
        // window with an identical response shape and no other test noticing.
        let mock = session
        _ = try await JetpackCollector(session: mock)
            .collect(since: Date().addingTimeInterval(-14 * 86_400), credentials: credentials)

        #expect(mock.queryValue("unit", path: Self.visitsPath) == "day")
    }

    @Test("An all-time request says so, rather than quoting 739,879 days")
    func allTimeWindowNoteReadsAsAllTime() async throws {
        // `.distantPast` measures about 739,879 days, and the note is rendered
        // into the prompt verbatim — "not the 739879 requested" is nonsense to
        // read. Before #96 this could not arise: All time arrived as nil and
        // took a 30-day default, so the cap never bit and no note was emitted.
        let mock = session
        let data = try await JetpackCollector(session: mock)
            .collect(since: .distantPast, credentials: credentials)

        #expect(mock.queryValue("quantity", path: Self.visitsPath) == "90")
        let note = try #require(data.stringMetric("views_window"))
        #expect(note.contains("all time"))
        #expect(!note.contains("739879"))
        #expect(note.contains("90"))
    }

    // MARK: - The 90-day cap

    @Test("A window longer than the cap says so instead of looking complete")
    func longWindowReportsTheCap() async throws {
        // quantity is capped at 90 days. Whether that is the API's limit or a
        // choice made here is unverified — stats/visits needs authentication, so
        // it cannot be probed without a real site token — but the silence is
        // wrong either way: capping a year-long request at 90 days makes a busy
        // year look like a quiet quarter.
        let mock = session
        let since = Date().addingTimeInterval(-365 * 86_400)
        let data = try await JetpackCollector(session: mock)
            .collect(since: since, credentials: credentials)

        #expect(mock.queryValue("quantity", path: Self.visitsPath) == "90")
        let note = try #require(data.stringMetric("views_window"))
        #expect(note.contains("90"))
        #expect(note.contains("365"))
        // Likes come from the same capped request, so the note must cover them.
        #expect(note.contains("likes"))
    }

    @Test("A window spanning a clock change is still a whole number of days",
          arguments: [("Europe/Berlin", 2026, 3, 29), ("America/New_York", 2026, 3, 8)])
    func daylightSavingDoesNotShortenTheWindow(
        zone: String, year: Int, month: Int, day: Int
    ) throws {
        // Elapsed seconds over 86,400 truncates: a spring-forward inside the
        // window makes the interval genuinely an hour short, so a 14-day request
        // becomes 13. It happens twice a year, in one hemisphere at a time, and
        // GitHub's runners are UTC — so it would have been wrong on Cate's
        // machine every spring and never in CI.
        //
        // Each pair is that zone's real 2026 transition date.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day + 2
        let to = try #require(calendar.date(from: c))
        let since = try #require(calendar.date(byAdding: .day, value: -14, to: to))

        // The premise: measured in that user's own zone, this window really is
        // short of 14 x 86,400 seconds.
        #expect(to.timeIntervalSince(since) < 14 * 86_400)
        // And the answer is still 14.
        #expect(JetpackCollector.daysRequested(from: since, to: to, calendar: calendar) == 14)
    }

    @Test("A window of no length still asks for a day")
    func degenerateWindows() {
        let now = Date()
        #expect(JetpackCollector.daysRequested(from: now, to: now) == 1)
        // A `since` in the future is nonsense but must not produce a negative
        // quantity or a crash.
        #expect(JetpackCollector.daysRequested(from: now.addingTimeInterval(86_400), to: now) == 1)
    }

    @Test("A window inside the cap is not annotated")
    func shortWindowIsNotAnnotated() async throws {
        // The other half: a note on every run would pass just as green.
        let mock = session
        // A fixed interval, not a calendar offset: a calendar -14 days across a
        // spring-forward is 14*86400-3600 seconds, which truncates to 13.
        let since = Date().addingTimeInterval(-14 * 86_400)
        let data = try await JetpackCollector(session: mock)
            .collect(since: since, credentials: credentials)

        #expect(mock.queryValue("quantity", path: Self.visitsPath) == "14")
        #expect(data.metrics["views_window"] == nil)
    }

    @Test("Throws missingCredential when access_token is absent")
    func missingToken() async throws {
        let creds = Credentials(["site_code": Self.siteID])
        await #expect(throws: CollectorError.self) {
            try await JetpackCollector(session: session).collect(since: .distantPast, credentials: creds)
        }
    }

    @Test("Throws missingCredential when site_code is absent")
    func missingSiteID() async throws {
        let creds = Credentials(["access_token": "tok"])
        await #expect(throws: CollectorError.self) {
            try await JetpackCollector(session: session).collect(since: .distantPast, credentials: creds)
        }
    }

    @Test("Throws on HTTP error")
    func httpError() async throws {
        let sess = MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats": ("{\"error\":\"unauthorized\"}", 401)
        ])
        await #expect(throws: CollectorError.self) {
            try await JetpackCollector(session: sess).collect(since: .distantPast, credentials: credentials)
        }
    }
}
