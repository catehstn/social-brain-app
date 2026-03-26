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
