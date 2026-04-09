import Testing
import Foundation
@testable import SocialBrain

@Suite("Bluesky Collector Tests")
struct BlueskyCollectorTests {

    private static let sessionJSON = """
    {
      "did": "did:plc:abc123",
      "access_jwt": "eyJtest"
    }
    """

    private static let profileJSON = """
    {
      "did": "did:plc:abc123",
      "handle": "alice.bsky.social",
      "followers_count": 3800,
      "follows_count": 420,
      "posts_count": 910
    }
    """

    private static let feedJSON = """
    {
      "feed": [
        {
          "post": {
            "indexed_at": "2026-03-24T08:00:00.000Z",
            "like_count": 55,
            "repost_count": 12,
            "reply_count": 4
          },
          "reason": null
        },
        {
          "post": {
            "indexed_at": "2026-03-22T12:00:00.000Z",
            "like_count": 30,
            "repost_count": 5,
            "reply_count": 2
          },
          "reason": null
        },
        {
          "post": {
            "indexed_at": "2026-03-21T09:00:00.000Z",
            "like_count": 10,
            "repost_count": 1,
            "reply_count": 0
          },
          "reason": { "type": "repost" }
        }
      ]
    }
    """

    @Test("Parses profile metrics and feed engagement")
    func collectMetrics() async throws {
        let session = MockURLSession([
            "/xrpc/com.atproto.server.createSession": (BlueskyCollectorTests.sessionJSON,  200),
            "/xrpc/app.bsky.actor.getProfile":        (BlueskyCollectorTests.profileJSON,  200),
            "/xrpc/app.bsky.feed.getAuthorFeed":      (BlueskyCollectorTests.feedJSON,     200)
        ])
        let collector = BlueskyCollector(
            session: session,
            baseURL: URL(string: "https://bsky.social")!
        )
        let credentials = Credentials([
            "username": "alice.bsky.social",
            "password": "app-password-here"
        ])
        let data = try await collector.collect(since: nil, credentials: credentials)

        #expect(data.platform == .bluesky)
        #expect(data.intMetric("followers_count") == 3800)
        #expect(data.intMetric("follows_count")   == 420)
        #expect(data.intMetric("posts_count")     == 910)
        // 3 items in feed but the third has a `reason` so only 2 should count
        #expect(data.intMetric("recent_posts")    == 2)

        // avg_likes = (55 + 30) / 2 = 42.5
        if let avgLikes = data.doubleMetric("avg_likes") {
            #expect(abs(avgLikes - 42.5) < 0.01)
        } else {
            Issue.record("avg_likes metric is missing")
        }
    }

    @Test("Filters posts older than since date")
    func sinceFilter() async throws {
        let session = MockURLSession([
            "/xrpc/com.atproto.server.createSession": (BlueskyCollectorTests.sessionJSON, 200),
            "/xrpc/app.bsky.actor.getProfile":        (BlueskyCollectorTests.profileJSON, 200),
            "/xrpc/app.bsky.feed.getAuthorFeed":      (BlueskyCollectorTests.feedJSON,    200)
        ])
        let collector = BlueskyCollector(
            session: session,
            baseURL: URL(string: "https://bsky.social")!
        )
        let credentials = Credentials([
            "username": "alice.bsky.social",
            "password": "app-password-here"
        ])

        // Only posts on/after 2026-03-23 — that's only the post on 2026-03-24
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 23
        let since = Calendar.current.date(from: comps)!

        let data = try await collector.collect(since: since, credentials: credentials)
        #expect(data.intMetric("recent_posts") == 1)
    }

    @Test("Throws missingCredential when username is absent")
    func missingUsername() async throws {
        let collector = BlueskyCollector()
        let credentials = Credentials(["password": "pw"])
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: nil, credentials: credentials)
        }
    }

    @Test("Throws missingCredential when password is absent")
    func missingPassword() async throws {
        let collector = BlueskyCollector()
        let credentials = Credentials(["username": "alice.bsky.social"])
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: nil, credentials: credentials)
        }
    }
}
