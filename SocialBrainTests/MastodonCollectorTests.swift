import Testing
import Foundation
@testable import SocialBrain

@Suite("Mastodon Collector Tests")
struct MastodonCollectorTests {

    private static let credentialsJSON = """
    {
      "id": "109876543",
      "username": "alice",
      "followers_count": 2500,
      "following_count": 300,
      "statuses_count": 4100
    }
    """

    private static let statusesJSON = """
    [
      {
        "id": "1",
        "created_at": "2026-03-20T10:00:00.000Z",
        "reblogs_count": 12,
        "favourites_count": 45,
        "replies_count": 3
      },
      {
        "id": "2",
        "created_at": "2026-03-22T14:30:00.000Z",
        "reblogs_count": 8,
        "favourites_count": 30,
        "replies_count": 5
      }
    ]
    """

    @Test("Parses account info and post engagement metrics")
    func collectMetrics() async throws {
        let session = MockURLSession([
            "/api/v1/accounts/verify_credentials":       (MastodonCollectorTests.credentialsJSON, 200),
            "/api/v1/accounts/109876543/statuses": (MastodonCollectorTests.statusesJSON,    200)
        ])
        let collector = MastodonCollector(session: session)
        let credentials = Credentials([
            "access_token": "test-token",
            "instance_url": "https://mastodon.social"
        ])
        let data = try await collector.collect(since: nil, credentials: credentials)

        #expect(data.platform == .mastodon)
        #expect(data.intMetric("followers_count") == 2500)
        #expect(data.intMetric("following_count") == 300)
        #expect(data.intMetric("statuses_count")  == 4100)
        #expect(data.intMetric("recent_posts")    == 2)

        // avg_reblogs = (12 + 8) / 2 = 10.0
        if let avgRe = data.doubleMetric("avg_reblogs") {
            #expect(abs(avgRe - 10.0) < 0.01)
        } else {
            Issue.record("avg_reblogs metric is missing")
        }

        // avg_favourites = (45 + 30) / 2 = 37.5
        if let avgFav = data.doubleMetric("avg_favourites") {
            #expect(abs(avgFav - 37.5) < 0.01)
        } else {
            Issue.record("avg_favourites metric is missing")
        }
    }

    @Test("Filters posts older than since date")
    func sinceFilter() async throws {
        let session = MockURLSession([
            "/api/v1/accounts/verify_credentials":       (MastodonCollectorTests.credentialsJSON, 200),
            "/api/v1/accounts/109876543/statuses": (MastodonCollectorTests.statusesJSON,    200)
        ])
        let collector = MastodonCollector(session: session)
        let credentials = Credentials([
            "access_token": "test-token",
            "instance_url": "https://mastodon.social"
        ])

        // Both posts are before 2026-03-25, only newer one (2026-03-22) > since cutoff of 2026-03-21
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 21
        let since = Calendar.current.date(from: components)!

        let data = try await collector.collect(since: since, credentials: credentials)
        #expect(data.intMetric("recent_posts") == 1)
    }

    // MARK: - Pagination

    /// `count` statuses, newest first, one day apart working back from
    /// `newest`. Dates are computed rather than formatted by hand so a page
    /// longer than a month does not produce "2026-03--11".
    private static func statusPage(count: Int, newest: Date, idBase: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let items = (0..<count).map { offset -> String in
            let date = newest.addingTimeInterval(-Double(offset) * 86_400)
            return """
            {"id":"\(idBase - offset)","created_at":"\(formatter.string(from: date))",\
            "reblogs_count":1,"favourites_count":1,"replies_count":1}
            """
        }
        return "[\(items.joined(separator: ","))]"
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test("Walks past the first page to reach the since boundary")
    func paginatesUntilSince() async throws {
        // The bug: one page of 40 was fetched and filtered, while the doc
        // comment claimed 200. Any window holding more than 40 posts came back
        // undercounted — and quietly, which is the harm: a smaller number is
        // indistinguishable from a quieter week.
        //
        // Two full pages then a short one. All 90 posts fall inside the window,
        // so all 90 must be counted.
        let session = MockURLSession([
            "/api/v1/accounts/verify_credentials": [.init(Self.credentialsJSON)],
            "/api/v1/accounts/109876543/statuses": [
                .init(Self.statusPage(count: 40, newest: Self.day(2026, 3, 28), idBase: 1000)),
                .init(Self.statusPage(count: 40, newest: Self.day(2026, 2, 16), idBase: 900)),
                .init(Self.statusPage(count: 10, newest: Self.day(2026, 1, 10), idBase: 800))
            ]
        ])
        let collector = MastodonCollector(session: session)
        let credentials = Credentials([
            "access_token": "t", "instance_url": "https://mastodon.social"
        ])
        var components = DateComponents()
        components.year = 2026; components.month = 1; components.day = 1
        let since = Calendar.current.date(from: components)!

        let data = try await collector.collect(since: since, credentials: credentials)
        #expect(data.intMetric("recent_posts") == 90)
        #expect(session.requests(path: "/api/v1/accounts/109876543/statuses").count == 3)
    }

    @Test("Pages back with max_id, not by asking for the same page again")
    func paginatesByMaxID() async throws {
        let session = MockURLSession([
            "/api/v1/accounts/verify_credentials": [.init(Self.credentialsJSON)],
            "/api/v1/accounts/109876543/statuses": [
                .init(Self.statusPage(count: 40, newest: Self.day(2026, 3, 28), idBase: 1000)),
                .init(Self.statusPage(count: 5, newest: Self.day(2026, 2, 16), idBase: 900))
            ]
        ])
        let collector = MastodonCollector(session: session)
        var components = DateComponents()
        components.year = 2026; components.month = 1; components.day = 1
        _ = try await collector.collect(
            since: Calendar.current.date(from: components)!,
            credentials: Credentials(["access_token": "t", "instance_url": "https://mastodon.social"])
        )

        // The first request carries no cursor; the second asks for statuses
        // older than the oldest of page one (1000 - 39 = 961).
        let maxIDs = session.queryValues("max_id", path: "/api/v1/accounts/109876543/statuses")
        #expect(maxIDs == ["961"])
    }

    @Test("Stops as soon as a page reaches past the window")
    func stopsAtTheBoundary() async throws {
        // Statuses come back newest-first, so once a page ends older than
        // `since` there is nothing older worth asking for. Fetching anyway
        // would be correct but wasteful, and on a long-lived account it is the
        // difference between two requests and twenty-five.
        let session = MockURLSession([
            "/api/v1/accounts/verify_credentials": [.init(Self.credentialsJSON)],
            "/api/v1/accounts/109876543/statuses": [
                .init(Self.statusPage(count: 40, newest: Self.day(2026, 3, 28), idBase: 1000)),
                .init(Self.statusPage(count: 40, newest: Self.day(2026, 2, 16), idBase: 900))
            ]
        ])
        let collector = MastodonCollector(session: session)
        // Page one spans 2026-03-28 back to 2026-02-17, so it already crosses
        // this boundary.
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 20
        let since = Calendar.current.date(from: components)!

        let data = try await collector.collect(
            since: since,
            credentials: Credentials(["access_token": "t", "instance_url": "https://mastodon.social"])
        )
        #expect(session.requests(path: "/api/v1/accounts/109876543/statuses").count == 1)
        #expect(data.intMetric("recent_posts") == 9)
    }

    @Test("Hitting the page cap is reported, not hidden")
    func truncationIsReported() async throws {
        // The cap has to exist — an all-time run on a prolific account would
        // otherwise walk forever. What must not happen is presenting the capped
        // count as if it were the whole period.
        let session = MockURLSession([
            "/api/v1/accounts/verify_credentials": [.init(Self.credentialsJSON)],
            // Always a full page, so the walk never finds an end.
            "/api/v1/accounts/109876543/statuses": [
                .init(Self.statusPage(count: 40, newest: Self.day(2026, 3, 28), idBase: 1000))
            ]
        ])
        let collector = MastodonCollector(session: session)
        var components = DateComponents()
        components.year = 2020; components.month = 1; components.day = 1
        let data = try await collector.collect(
            since: Calendar.current.date(from: components)!,
            credentials: Credentials(["access_token": "t", "instance_url": "https://mastodon.social"])
        )

        #expect(session.requests(path: "/api/v1/accounts/109876543/statuses").count
                == MastodonCollector.maximumPages)
        let note = try #require(data.metrics["posts_truncated"]?.stringValue)
        #expect(note.contains("1000"))
    }

    @Test("With no since, one page is the whole request")
    func noSinceFetchesOnePage() async throws {
        // "Recent posts" with no window asked for means the most recent page,
        // which is what this always did. Walking every page for an unbounded
        // request would turn a routine refresh into 25 round trips.
        let session = MockURLSession([
            "/api/v1/accounts/verify_credentials": [.init(Self.credentialsJSON)],
            "/api/v1/accounts/109876543/statuses": [
                .init(Self.statusPage(count: 40, newest: Self.day(2026, 3, 28), idBase: 1000))
            ]
        ])
        let collector = MastodonCollector(session: session)
        let data = try await collector.collect(
            since: nil,
            credentials: Credentials(["access_token": "t", "instance_url": "https://mastodon.social"])
        )
        #expect(session.requests(path: "/api/v1/accounts/109876543/statuses").count == 1)
        #expect(data.intMetric("recent_posts") == 40)
    }

    @Test("Throws missingCredential when access_token is absent")
    func missingToken() async throws {
        let collector = MastodonCollector()
        let credentials = Credentials(["instance_url": "https://mastodon.social"])
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: nil, credentials: credentials)
        }
    }

    @Test("Throws missingCredential when instance_url is absent")
    func missingInstanceURL() async throws {
        let collector = MastodonCollector()
        let credentials = Credentials(["access_token": "tok"])
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: nil, credentials: credentials)
        }
    }
}
