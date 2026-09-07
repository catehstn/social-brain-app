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

    // MARK: - Pagination

    private static let feedPath = "/xrpc/app.bsky.feed.getAuthorFeed"

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    /// A feed page: `posts` real posts then `reposts` reposts, newest first,
    /// one day apart from `newest`. `cursor` nil means "no more feed".
    private static func feedPage(
        posts: Int, reposts: Int = 0, newest: Date, cursor: String?
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let items = (0 ..< (posts + reposts)).map { offset -> String in
            let date = newest.addingTimeInterval(-Double(offset) * 86_400)
            let reason = offset < posts ? "null" : "{\"by\":\"someone\"}"
            return """
            {"post":{"indexed_at":"\(formatter.string(from: date))",\
            "like_count":1,"repost_count":1,"reply_count":1},"reason":\(reason)}
            """
        }
        let cursorField = cursor.map { ",\"cursor\":\"\($0)\"" } ?? ""
        return "{\"feed\":[\(items.joined(separator: ","))]\(cursorField)}"
    }

    private func makeCollector(_ feed: [MockURLSession.Response]) -> (BlueskyCollector, MockURLSession) {
        let session = MockURLSession([
            "/xrpc/com.atproto.server.createSession": [.init(Self.sessionJSON)],
            "/xrpc/app.bsky.actor.getProfile":        [.init(Self.profileJSON)],
            Self.feedPath: feed
        ])
        return (BlueskyCollector(session: session, baseURL: URL(string: "https://bsky.social")!), session)
    }

    private let paginationCredentials = Credentials([
        "username": "alice.bsky.social", "password": "app-pass"
    ])

    @Test("Follows the cursor past the first page")
    func followsTheCursor() async throws {
        // One page of 50 was fetched and filtered, so any window holding more
        // than 50 posts came back undercounted — and quietly, which is the harm.
        let (collector, session) = makeCollector([
            .init(Self.feedPage(posts: 50, newest: Self.day(2026, 3, 28), cursor: "c1")),
            .init(Self.feedPage(posts: 50, newest: Self.day(2026, 2, 6), cursor: "c2")),
            .init(Self.feedPage(posts: 10, newest: Self.day(2026, 1, 10), cursor: nil))
        ])
        // Wide enough that no page crosses it — the walk ends because the
        // cursor runs out, which is the property under test.
        let data = try await collector.collect(
            since: Self.day(2025, 1, 1), credentials: paginationCredentials
        )
        #expect(data.intMetric("recent_posts") == 110)
        #expect(session.requests(path: Self.feedPath).count == 3)
        #expect(data.metrics["posts_truncated"] == nil)
    }

    @Test("A full page of reposts is not mistaken for the end of the feed")
    func repostOnlyPageDoesNotStopTheWalk() async throws {
        // The difference that matters versus Mastodon. Reposts are filtered
        // *client-side*, so a full page can yield no posts at all — a page that
        // looks short, or even empty, is routine rather than final. Only the
        // absent cursor means the feed is exhausted.
        // Deliberately a *short* page of pure reposts. atproto does not promise
        // a full page while more exists, so page length says nothing — and with
        // reposts dropped client-side this page yields zero posts while the feed
        // continues. Only the absent cursor ends the walk.
        let (collector, session) = makeCollector([
            .init(Self.feedPage(posts: 0, reposts: 20, newest: Self.day(2026, 3, 28), cursor: "c1")),
            .init(Self.feedPage(posts: 7, newest: Self.day(2026, 3, 5), cursor: nil))
        ])
        let data = try await collector.collect(
            since: Self.day(2026, 1, 1), credentials: paginationCredentials
        )
        #expect(session.requests(path: Self.feedPath).count == 2)
        #expect(data.intMetric("recent_posts") == 7)
    }

    @Test("Sends the cursor it was given, not the same page again")
    func sendsTheCursor() async throws {
        let (collector, session) = makeCollector([
            .init(Self.feedPage(posts: 50, newest: Self.day(2026, 3, 28), cursor: "cursor-one")),
            .init(Self.feedPage(posts: 3, newest: Self.day(2026, 2, 6), cursor: nil))
        ])
        _ = try await collector.collect(
            since: Self.day(2026, 1, 1), credentials: paginationCredentials
        )
        #expect(session.queryValues("cursor", path: Self.feedPath) == ["cursor-one"])
    }

    @Test("Stops once a page reaches past the window")
    func stopsAtTheBoundary() async throws {
        // The boundary reads the *raw* feed item, not the filtered result, and
        // this fixture is built so the two disagree: ten posts (Mar 28 back to
        // Mar 19) followed by forty reposts (Mar 18 back to Feb 7). The newest
        // surviving post is Mar 19, but the page actually reached Feb 7.
        //
        // Against a Mar 1 boundary the raw date says "already past it, stop";
        // the filtered date says "still inside, keep going" and costs a request
        // for a page that cannot contain anything in the window.
        // Ten posts (Mar 28 back to Mar 19) then forty reposts (Mar 18 back to
        // Feb 7). The oldest surviving *post* is Mar 19, which is still inside
        // a Mar 1 window — so the walk continues, and the second page is what
        // decides.
        let (collector, session) = makeCollector([
            .init(Self.feedPage(posts: 10, reposts: 40, newest: Self.day(2026, 3, 28), cursor: "c1")),
            .init(Self.feedPage(posts: 50, newest: Self.day(2026, 2, 6), cursor: "c2"))
        ])
        let data = try await collector.collect(
            since: Self.day(2026, 3, 1), credentials: paginationCredentials
        )
        #expect(session.requests(path: Self.feedPath).count == 2)
        #expect(data.intMetric("recent_posts") == 10)
    }

    @Test("A repost of an old post does not end the walk early")
    func repostOfAnOldPostDoesNotStopTheWalk() async throws {
        // The feed is ordered by each item's sort key, which for a repost is the
        // *repost* time — not `post.indexedAt`. Verified against
        // public.api.bsky.app: 5 of 100 items were out of descending
        // post.indexedAt order and every one was a repost, while the same items
        // filtered to non-reposts were strictly descending, 73 of 73.
        //
        // So a single repost of an ancient post in the last slot makes the page
        // look as though it reached 2024. Reading the raw last item stops the
        // walk there and reports 49 posts where the truth is 79 — silently, with
        // no truncation note, which is the exact undercount this exists to fix.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ancient = formatter.string(from: Self.day(2024, 1, 5))

        // 49 in-window posts, then one repost pointing at a 2024 post.
        var page1 = Self.feedPage(posts: 49, newest: Self.day(2026, 3, 28), cursor: "c1")
        page1 = page1.replacingOccurrences(
            of: "],\"cursor\"",
            with: """
            ,{"post":{"indexed_at":"\(ancient)","like_count":1,"repost_count":1,"reply_count":1},\
            "reason":{"by":"someone"}}],"cursor"
            """)

        let (collector, session) = makeCollector([
            .init(page1),
            .init(Self.feedPage(posts: 30, newest: Self.day(2026, 2, 7), cursor: nil))
        ])
        // Wide enough that every real post is inside it. The 2024 repost is the
        // only thing that looks out of window, and it is the thing that must
        // not decide.
        let data = try await collector.collect(
            since: Self.day(2026, 1, 1), credentials: paginationCredentials
        )
        #expect(session.requests(path: Self.feedPath).count == 2)
        #expect(data.intMetric("recent_posts") == 79)
    }

    @Test("An empty page with a cursor does not end the walk")
    func emptyPageWithCursorContinues() async throws {
        let (collector, session) = makeCollector([
            .init(Self.feedPage(posts: 0, newest: Self.day(2026, 3, 28), cursor: "c1")),
            .init(Self.feedPage(posts: 5, newest: Self.day(2026, 3, 20), cursor: nil))
        ])
        let data = try await collector.collect(
            since: Self.day(2026, 1, 1), credentials: paginationCredentials
        )
        #expect(session.requests(path: Self.feedPath).count == 2)
        #expect(data.intMetric("recent_posts") == 5)
    }

    @Test("Hitting the page cap is reported, not hidden")
    func truncationIsReported() async throws {
        let (collector, session) = makeCollector([
            .init(Self.feedPage(posts: 50, newest: Self.day(2026, 3, 28), cursor: "endless"))
        ])
        let data = try await collector.collect(
            since: Self.day(2020, 1, 1), credentials: paginationCredentials
        )
        #expect(session.requests(path: Self.feedPath).count == BlueskyCollector.maximumPages)
        let note = try #require(data.metrics["posts_truncated"]?.stringValue)
        #expect(note.contains("1000"))
    }

    @Test("An All time run walks the pages too")
    func noSinceStillWalks() async throws {
        // `since == nil` is the All time button, not "no window asked for".
        let (collector, session) = makeCollector([
            .init(Self.feedPage(posts: 50, newest: Self.day(2026, 3, 28), cursor: "c1")),
            .init(Self.feedPage(posts: 4, newest: Self.day(2026, 2, 6), cursor: nil))
        ])
        let data = try await collector.collect(since: nil, credentials: paginationCredentials)
        #expect(session.requests(path: Self.feedPath).count == 2)
        #expect(data.intMetric("recent_posts") == 54)
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
