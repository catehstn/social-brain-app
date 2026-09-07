import Testing
import Foundation
@testable import SocialBrain

@Suite("Jetpack Collector Tests")
struct JetpackCollectorTests {

    private static let siteID = "12345678"

    private static let statsJSON = """
    {
      "stats": {
        "followers_blog": 1240,
        "followers_comments": 85,
        "comments": 342,
        "likes_today": 12
      }
    }
    """

    private static let visitsJSON = """
    {
      "date": "2026-03-26",
      "unit": "day",
      "fields": ["period", "views", "visitors"],
      "data": [
        ["2026-03-25", 156, 42],
        ["2026-03-24", 143, 38],
        ["2026-03-23", 201, 55]
      ]
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
        let data = try await JetpackCollector(session: session).collect(since: nil, credentials: credentials)
        #expect(data.platform == .jetpack)
        #expect(data.intMetric("followers_blog") == 1240)
        #expect(data.intMetric("followers_comment") == 85)
    }

    @Test("Parses total comments")
    func parsesTotalComments() async throws {
        let data = try await JetpackCollector(session: session).collect(since: nil, credentials: credentials)
        #expect(data.intMetric("total_comments") == 342)
    }

    @Test("Parses likes_today")
    func parsesLikes() async throws {
        let data = try await JetpackCollector(session: session).collect(since: nil, credentials: credentials)
        #expect(data.intMetric("total_likes") == 12)
    }

    @Test("Sums visit data across all rows")
    func sumsVisits() async throws {
        let data = try await JetpackCollector(session: session).collect(since: nil, credentials: credentials)
        // views: 156 + 143 + 201 = 500
        // visitors: 42 + 38 + 55 = 135
        #expect(data.intMetric("total_views") == 500)
        #expect(data.intMetric("total_visitors") == 135)
    }

    @Test("Handles visits response with missing fields gracefully")
    func handlesEmptyVisits() async throws {
        let emptyVisits = """
        { "date": "2026-03-26", "unit": "day", "fields": ["period"], "data": [] }
        """
        let sess = MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats":        (Self.statsJSON, 200),
            "/rest/v1.1/sites/\(Self.siteID)/stats/visits": (emptyVisits, 200)
        ])
        let data = try await JetpackCollector(session: sess).collect(since: nil, credentials: credentials)
        #expect(data.intMetric("total_views") == 0)
        #expect(data.intMetric("total_visitors") == 0)
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
        _ = try await JetpackCollector(session: mock).collect(since: nil, credentials: credentials)

        let paths = Set(mock.requestedURLs.map(\.path))
        #expect(paths.count == 2)
        for path in paths {
            #expect(mock.headerValues("Authorization", path: path) == ["Bearer test-token"],
                    "missing or wrong Authorization on \(path)")
        }
    }

    @Test("No request is double-encoded")
    func urlsAreNotDoubleEncoded() async throws {
        // The site ID goes into the path. #68 is what this guards: Google Search
        // Console encoded its site URL twice and every request hit a property
        // that could not exist, while the result-level tests stayed green.
        let mock = session
        _ = try await JetpackCollector(session: mock).collect(since: nil, credentials: credentials)

        for url in mock.requestedURLs {
            #expect(!url.absoluteString.contains("%25"), "double-encoded: \(url)")
        }
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
            try await JetpackCollector(session: session).collect(since: nil, credentials: creds)
        }
    }

    @Test("Throws missingCredential when site_code is absent")
    func missingSiteID() async throws {
        let creds = Credentials(["access_token": "tok"])
        await #expect(throws: CollectorError.self) {
            try await JetpackCollector(session: session).collect(since: nil, credentials: creds)
        }
    }

    @Test("Throws on HTTP error")
    func httpError() async throws {
        let sess = MockURLSession([
            "/rest/v1.1/sites/\(Self.siteID)/stats": ("{\"error\":\"unauthorized\"}", 401)
        ])
        await #expect(throws: CollectorError.self) {
            try await JetpackCollector(session: sess).collect(since: nil, credentials: credentials)
        }
    }
}
