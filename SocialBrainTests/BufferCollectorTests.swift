import Testing
import Foundation
@testable import SocialBrain

/// Buffer had no test suite beyond a setup-URL check (#48).
///
/// It also pins where the access token travels. It used to go in the query
/// string, which writes a live credential into server access logs, proxy logs
/// and browser history on every request. Buffer accepts the Authorization
/// header too, so that was a choice rather than a constraint; #85 changed it,
/// and the assertions below are what stop it drifting back.
@Suite("Buffer Collector Tests")
struct BufferCollectorTests {

    private static let profilesJSON = """
        [
          {"id":"p1","service":"mastodon","service_username":"cate"},
          {"id":"p2","service":"bluesky","service_username":"cate.bsky"}
        ]
        """

    private static let sentP1JSON = """
        {"updates":[
          {"id":"u1","sent_at":1767225600,"statistics":{"clicks":10,"reach":100,"likes":5}},
          {"id":"u2","sent_at":1767312000,"statistics":{"clicks":3,"reach":40,"likes":1}}
        ]}
        """

    /// One post, and its like count arrives as `favorites` — the name Buffer's
    /// own v1 documentation uses. Only `likes` was decoded, so this contributed
    /// zero.
    private static let sentP2JSON = """
        {"updates":[
          {"id":"u3","sent_at":1767225600,"statistics":{"clicks":7,"reach":60,"favorites":4}}
        ]}
        """

    private static let pendingJSON = """
        {"updates":[{"id":"u3"},{"id":"u4"},{"id":"u5"}]}
        """

    private func makeSession() -> MockURLSession {
        MockURLSession([
            "/1/profiles.json": (Self.profilesJSON, 200),
            "/1/profiles/p1/updates/sent.json": (Self.sentP1JSON, 200),
            "/1/profiles/p2/updates/sent.json": (Self.sentP2JSON, 200),
            "/1/profiles/p1/updates/pending.json": (Self.pendingJSON, 200),
            "/1/profiles/p2/updates/pending.json": (Self.pendingJSON, 200)
        ])
    }

    private let credentials = Credentials(["api_key": "tok-123"])

    // MARK: - Parsing

    @Test("Counts profiles and aggregates sent-post statistics across them")
    func aggregatesAcrossProfiles() async throws {
        let data = try await BufferCollector(session: makeSession())
            .collect(since: nil, credentials: credentials)

        #expect(data.metrics["profiles_count"] == .int(2))
        #expect(data.metrics["sent_updates"] == .int(3))
        #expect(data.metrics["total_clicks"] == .int(20))
        #expect(data.metrics["total_reach"] == .int(200))
        // 5 + 1 from `likes`, 4 from `favorites`. Reading only `likes` gives 6.
        #expect(data.metrics["total_likes"] == .int(10))
    }

    @Test("Counts everything still queued")
    func countsScheduled() async throws {
        // Pending posts carry no sent_at. When Update required it, decoding
        // pending.json threw and the surrounding try? swallowed it, so this
        // metric reported 0 for every user who has ever run a collection.
        let data = try await BufferCollector(session: makeSession())
            .collect(since: nil, credentials: credentials)

        #expect(data.metrics["scheduled_updates"] == .int(6))
    }

    @Test("Names the top profiles by sent count, most first")
    func namesTopProfiles() async throws {
        // The profiles send different counts on purpose. With both on two the
        // ordering was nondeterministic, so this could only assert non-nil —
        // and replacing the whole label with a constant left it passing.
        let data = try await BufferCollector(session: makeSession())
            .collect(since: nil, credentials: credentials)

        // Exact strings, not "contains": replacing the whole label with a
        // constant left a contains-check passing, so the service name and
        // username formatting were entirely unverified.
        #expect(data.metrics["top_profile_1"] == .string("Mastodon (cate) (2 posts)"))
        #expect(data.metrics["top_profile_2"] == .string("Bluesky (cate.bsky) (1 posts)"))
        #expect(data.metrics["top_profile_3"] == nil)
    }

    @Test("since filters sent posts to the window")
    func sinceFiltersSentPosts() async throws {
        // Every other test collects with since: nil, so the whole filtering
        // branch was dead in the suite — replacing it with `return updates`
        // left them all green.
        let sent = """
            {"updates":[
              {"id":"old","sent_at":1735689600,"statistics":{"clicks":1}},
              {"id":"new","sent_at":1767312000,"statistics":{"clicks":2}},
              {"id":"undated","statistics":{"clicks":99}}
            ]}
            """
        let session = MockURLSession([
            "/1/profiles.json": ("[{\"id\":\"p1\",\"service\":\"mastodon\"}]", 200),
            "/1/profiles/p1/updates/sent.json": (sent, 200),
            "/1/profiles/p1/updates/pending.json": (Self.pendingJSON, 200)
        ])
        let since = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01

        let data = try await BufferCollector(session: session)
            .collect(since: since, credentials: credentials)

        // Only "new" is in the window. "undated" has no sent_at and so cannot be
        // placed in it — counting it would inflate the period.
        #expect(data.metrics["sent_updates"] == .int(1))
        #expect(data.metrics["total_clicks"] == .int(2))
    }

    @Test("No connected profiles yields zeros rather than a failure")
    func handlesNoProfiles() async throws {
        let session = MockURLSession(["/1/profiles.json": ("[]", 200)])
        let data = try await BufferCollector(session: session)
            .collect(since: nil, credentials: credentials)

        #expect(data.metrics["profiles_count"] == .int(0))
        #expect(data.metrics["sent_updates"] == .int(0))
    }

    // MARK: - The request

    @Test("Every request carries the access token")
    func everyRequestIsAuthorised() async throws {
        let session = makeSession()
        _ = try await BufferCollector(session: session).collect(since: nil, credentials: credentials)

        let paths = Set(session.requestedURLs.map(\.path))
        #expect(!paths.isEmpty)
        for path in paths {
            #expect(session.headerValues("Authorization", path: path).allSatisfy { $0 == "Bearer tok-123" },
                    "missing or wrong Authorization on \(path)")
            #expect(!session.headerValues("Authorization", path: path).isEmpty,
                    "no Authorization header on \(path)")
        }
    }

    @Test("The token travels in a header, never in the URL")
    func tokenIsSentAsAHeader() async throws {
        let session = makeSession()
        _ = try await BufferCollector(session: session).collect(since: nil, credentials: credentials)

        // A query string is recorded verbatim in access logs, so a credential
        // there is written somewhere it does not need to be — on every request.
        #expect(session.requestedURLs.allSatisfy { !$0.absoluteString.contains("access_token") })
        #expect(session.headerValues("Authorization", path: "/1/profiles.json") == ["Bearer tok-123"])
    }

    @Test("Each connected profile is queried for both sent and pending posts")
    func queriesEachProfile() async throws {
        let session = makeSession()
        _ = try await BufferCollector(session: session).collect(since: nil, credentials: credentials)

        let paths = Set(session.requestedURLs.map(\.path))
        #expect(paths.contains("/1/profiles/p1/updates/sent.json"))
        #expect(paths.contains("/1/profiles/p2/updates/sent.json"))
        #expect(paths.contains("/1/profiles/p1/updates/pending.json"))
        #expect(paths.contains("/1/profiles/p2/updates/pending.json"))
    }

    // MARK: - Failures

    @Test("A missing token is reported by name")
    func missingTokenIsNamed() async throws {
        let collector = BufferCollector(session: makeSession())

        let error = await #expect(throws: CollectorError.self) {
            _ = try await collector.collect(since: nil, credentials: Credentials([:]))
        }
        #expect(error?.localizedDescription.contains("api_key") == true)
    }

    @Test("An unauthorised response propagates")
    func propagatesUnauthorised() async throws {
        let session = MockURLSession(["/1/profiles.json": (#"{"error":"bad token"}"#, 401)])
        let collector = BufferCollector(session: session)

        await #expect(throws: CollectorError.self) {
            _ = try await collector.collect(since: nil, credentials: credentials)
        }
    }
}
