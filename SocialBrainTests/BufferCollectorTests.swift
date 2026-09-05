import Testing
import Foundation
@testable import SocialBrain

/// Buffer had no test suite beyond a setup-URL check (#48).
///
/// Notably this also pins where the access token travels. Buffer's API takes it
/// as a query parameter, which puts a live credential into every server log and
/// proxy along the way — #85 tracks moving it to a header, and these assertions
/// are what will show that change actually happened.
@Suite("Buffer Collector Tests")
struct BufferCollectorTests {

    private static let profilesJSON = """
        [
          {"id":"p1","service":"mastodon","service_username":"cate"},
          {"id":"p2","service":"bluesky","service_username":"cate.bsky"}
        ]
        """

    private static let sentJSON = """
        {"updates":[
          {"id":"u1","sent_at":1767225600,"statistics":{"clicks":10,"reach":100,"likes":5}},
          {"id":"u2","sent_at":1767312000,"statistics":{"clicks":3,"reach":40,"likes":1}}
        ]}
        """

    private static let pendingJSON = """
        {"updates":[{"id":"u3"},{"id":"u4"},{"id":"u5"}]}
        """

    private func makeSession() -> MockURLSession {
        MockURLSession([
            "/1/profiles.json": (Self.profilesJSON, 200),
            "/1/profiles/p1/updates/sent.json": (Self.sentJSON, 200),
            "/1/profiles/p2/updates/sent.json": (Self.sentJSON, 200),
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
        // Two profiles, two sent posts each.
        #expect(data.metrics["sent_updates"] == .int(4))
        #expect(data.metrics["total_clicks"] == .int(26))
        #expect(data.metrics["total_reach"] == .int(280))
        #expect(data.metrics["total_likes"] == .int(12))
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

    @Test("Names the top profiles by sent count")
    func namesTopProfiles() async throws {
        let data = try await BufferCollector(session: makeSession())
            .collect(since: nil, credentials: credentials)

        // Both profiles sent two; whichever ordering, both should be present and
        // the third slot empty.
        let top = [data.metrics["top_profile_1"], data.metrics["top_profile_2"]]
        #expect(top.allSatisfy { $0 != nil })
        #expect(data.metrics["top_profile_3"] == nil)
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

        let tokens = session.requestedURLs.compactMap { url -> String? in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "access_token" }?.value
        }
        #expect(tokens.count == session.requestedURLs.count)
        #expect(tokens.allSatisfy { $0 == "tok-123" })
    }

    @Test("The token currently travels in the query string, which #85 tracks")
    func tokenIsInTheQueryString() async throws {
        let session = makeSession()
        _ = try await BufferCollector(session: session).collect(since: nil, credentials: credentials)

        // Deliberately asserting the *current* behaviour so that #85's move to a
        // header is a visible, deliberate change rather than a silent one. When
        // that lands, this assertion flips to checking the Authorization header.
        #expect(session.requestedURLs.allSatisfy { $0.absoluteString.contains("access_token=") })
        #expect(session.headerValues("Authorization", path: "/1/profiles.json").isEmpty)
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
