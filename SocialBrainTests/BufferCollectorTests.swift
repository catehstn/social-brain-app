import Testing
import Foundation
@testable import SocialBrain

/// Buffer's collector talks to its GraphQL API (#117).
///
/// The fixtures follow response shapes observed live on 2026-09-21 — field
/// names, fractional-second timestamps, and the `INSUFFICIENT_SCOPE` error
/// that a key without insights access gets once per post. Identifiers are
/// invented. The `metrics` values are **not** from a live response: the key
/// used had no insights access, so their shape comes from the schema.
@Suite("Buffer Collector Tests")
struct BufferCollectorTests {

    // MARK: - Fixtures

    private static let account = """
        {"data":{"account":{"name":"cate","organizations":[{"id":"org1"}]}}}
        """

    private static let channels = """
        {"data":{"channels":[
          {"id":"c1","name":"cate","service":"mastodon"},
          {"id":"c2","name":"cate.bsky","service":"bluesky"}
        ]}}
        """

    /// Three posts, with metrics. `likes` on c2 is Buffer's Facebook-only
    /// subcount and must not be summed; `reactions` is the cross-network one.
    private static let sentWithMetrics = """
        {"data":{"posts":{"edges":[
          {"node":{"channelId":"c1","channelService":"mastodon","sentAt":"2026-01-02T00:00:00.000Z",
                   "metrics":[{"type":"clicks","value":10},{"type":"reach","value":100},{"type":"reactions","value":5}]}},
          {"node":{"channelId":"c1","channelService":"mastodon","sentAt":"2026-01-01T00:00:00.000Z",
                   "metrics":[{"type":"clicks","value":3},{"type":"reach","value":40},{"type":"reactions","value":1}]}},
          {"node":{"channelId":"c2","channelService":"bluesky","sentAt":"2026-01-01T12:00:00.000Z",
                   "metrics":[{"type":"clicks","value":7},{"type":"reactions","value":4},{"type":"likes","value":99}]}}
        ],"pageInfo":{"hasNextPage":false,"endCursor":"end"}}}}
        """

    /// What a key without `insights:read` gets: `metrics: null` on every node
    /// and one error per post, everything else intact.
    private static let sentScopeRefused = """
        {"errors":[
          {"message":"Insufficient scope. Required: insights:read.","path":["posts","edges",0,"node","metrics"],
           "extensions":{"code":"INSUFFICIENT_SCOPE","requiredScopes":["insights:read"]}},
          {"message":"Insufficient scope. Required: insights:read.","path":["posts","edges",1,"node","metrics"],
           "extensions":{"code":"INSUFFICIENT_SCOPE","requiredScopes":["insights:read"]}}
        ],"data":{"posts":{"edges":[
          {"node":{"channelId":"c1","channelService":"mastodon","sentAt":"2026-01-02T00:00:00.000Z","metrics":null}},
          {"node":{"channelId":"c2","channelService":"bluesky","sentAt":"2026-01-01T00:00:00.000Z","metrics":null}}
        ],"pageInfo":{"hasNextPage":false,"endCursor":"end"}}}}
        """

    private static let scheduled = """
        {"data":{"posts":{"edges":[{"node":{"id":"s1"}},{"node":{"id":"s2"}},{"node":{"id":"s3"}}],
          "pageInfo":{"hasNextPage":false,"endCursor":"end"}}}}
        """

    private static func sentPage(_ posts: [(channel: String, sentAt: String?)], next: String?) -> String {
        let edges = posts.map { post in
            let sentAt = post.sentAt.map { "\"\($0)\"" } ?? "null"
            return #"{"node":{"channelId":"\#(post.channel)","channelService":"mastodon","sentAt":\#(sentAt),"metrics":[]}}"#
        }
        let cursor = next.map { "\"\($0)\"" } ?? "null"
        return #"{"data":{"posts":{"edges":[\#(edges.joined(separator: ","))],"pageInfo":{"hasNextPage":\#(next != nil),"endCursor":\#(cursor)}}}}"#
    }

    private func session(
        sent: [MockURLSession.Response] = [.init(sentWithMetrics)],
        scheduled: [MockURLSession.Response] = [.init(scheduled)],
        account: String = account,
        channels: String = channels
    ) -> GraphQLMockSession {
        GraphQLMockSession([
            "Account": [.init(account)],
            "Channels": [.init(channels)],
            "SentPosts": sent,
            "ScheduledPosts": scheduled
        ])
    }

    private let credentials = Credentials(["api_key": "tok-123"])

    private func collect(_ session: GraphQLMockSession, since: Date = .distantPast) async throws -> PlatformData {
        try await BufferCollector(session: session).collect(since: since, credentials: credentials)
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: - Counts and engagement

    @Test("Counts channels, sent and queued posts, and sums engagement across channels")
    func aggregates() async throws {
        let data = try await collect(session())

        #expect(data.metrics["profiles_count"] == .int(2))
        #expect(data.metrics["sent_updates"] == .int(3))
        #expect(data.metrics["scheduled_updates"] == .int(3))
        #expect(data.metrics["total_clicks"] == .int(20))
        // c2 reports no reach; the other two do.
        #expect(data.metrics["total_reach"] == .int(140))
        #expect(data.metrics["engagement_unavailable"] == nil)
    }

    @Test("Likes come from reactions, not Buffer's Facebook-only likes subcount")
    func likesAreReactions() async throws {
        let data = try await collect(session())
        // 5 + 1 + 4. Summing the `likes` type instead gives 99.
        #expect(data.metrics["total_likes"] == .int(10))
    }

    @Test("A metric no post carries is left out, not reported as zero")
    func absentMetricIsOmitted() {
        let posts = [BufferCollector.SentPost(channelId: "c1", channelService: "mastodon", sentAt: nil,
                                              metrics: [.init(type: "reactions", value: 3)])]
        let totals = BufferCollector.engagementTotals(posts)
        #expect(totals["total_likes"] == .int(3))
        #expect(totals["total_reach"] == nil)
        #expect(totals["total_clicks"] == nil)
    }

    @Test("With no posts, every engagement total is a true zero")
    func noPostsIsZero() {
        let totals = BufferCollector.engagementTotals([])
        #expect(totals == ["total_clicks": .int(0), "total_reach": .int(0), "total_likes": .int(0)])
    }

    @Test("A key without insights access still yields counts, and says why engagement is missing")
    func scopeRefusedKeepsCounts() async throws {
        let data = try await collect(session(sent: [.init(Self.sentScopeRefused)]))

        #expect(data.metrics["sent_updates"] == .int(2))
        #expect(data.metrics["scheduled_updates"] == .int(3))
        #expect(data.metrics["total_clicks"] == nil)
        #expect(data.metrics["total_reach"] == nil)
        #expect(data.metrics["total_likes"] == nil)
        let note = try #require(data.metrics["engagement_unavailable"]?.stringValue)
        #expect(note.contains("insights"))
    }

    @Test("Names the top channels by sent count, most first")
    func topProfiles() async throws {
        let data = try await collect(session())
        #expect(data.metrics["top_profile_1"] == .string("Mastodon (cate) (2 posts)"))
        #expect(data.metrics["top_profile_2"] == .string("Bluesky (cate.bsky) (1 posts)"))
        #expect(data.metrics["top_profile_3"] == nil)
    }

    @Test("A post from a channel no longer connected is named by its service")
    func unknownChannel() async throws {
        let sent = Self.sentPage([("gone", "2026-01-01T00:00:00.000Z")], next: nil)
        let data = try await collect(session(sent: [.init(sent)]))
        #expect(data.metrics["top_profile_1"] == .string("Mastodon (1 posts)"))
    }

    @Test("Sums across every organisation on the account")
    func multipleOrganisations() async throws {
        let account = #"{"data":{"account":{"name":"cate","organizations":[{"id":"org1"},{"id":"org2"}]}}}"#
        let mock = session(account: account)
        let data = try await collect(mock)

        #expect(data.metrics["sent_updates"] == .int(6))
        #expect(data.metrics["scheduled_updates"] == .int(6))
        #expect(mock.variables("SentPosts").compactMap { $0["organizationId"] as? String } == ["org1", "org2"])
    }

    // MARK: - Pagination

    @Test("Walks every page of sent posts, passing each cursor on")
    func paginatesSent() async throws {
        let mock = session(sent: [
            .init(Self.sentPage([("c1", "2026-01-03T00:00:00.000Z")], next: "p2")),
            .init(Self.sentPage([("c1", "2026-01-02T00:00:00.000Z")], next: "p3")),
            .init(Self.sentPage([("c2", "2026-01-01T00:00:00.000Z")], next: nil))
        ])
        let data = try await collect(mock)

        #expect(data.metrics["sent_updates"] == .int(3))
        #expect(data.metrics["posts_sampled"] == nil)
        let variables = mock.variables("SentPosts")
        #expect(variables.map { $0["after"] as? String } == [nil, "p2", "p3"])
        #expect(variables.allSatisfy { $0["first"] as? Int == BufferCollector.pageSize })
    }

    @Test("Walks every page of the queue")
    func paginatesScheduled() async throws {
        let page1 = #"{"data":{"posts":{"edges":[{"node":{"id":"s1"}}],"pageInfo":{"hasNextPage":true,"endCursor":"q2"}}}}"#
        let mock = session(scheduled: [.init(page1), .init(Self.scheduled)])
        let data = try await collect(mock)

        #expect(data.metrics["scheduled_updates"] == .int(4))
        #expect(mock.variables("ScheduledPosts").map { $0["after"] as? String } == [nil, "q2"])
    }

    @Test("A walk that hits the page cap says so rather than reporting a page count as a total")
    func capIsReported() async throws {
        // The last entry repeats, so this never ends on its own.
        let mock = session(sent: [.init(Self.sentPage([("c1", "2026-01-01T00:00:00.000Z")], next: "more"))])
        let data = try await collect(mock)

        #expect(mock.variables("SentPosts").count == BufferCollector.maxPages)
        #expect(data.metrics["sent_updates"] == .int(BufferCollector.maxPages))
        #expect(data.metrics["posts_sampled"] != nil)
    }

    // MARK: - The window

    @Test("since narrows on the server by dueAt, with slack, and decides membership by sentAt")
    func sinceFilters() async throws {
        let since = Self.date("2026-01-02T00:00:00Z")
        let sent = Self.sentPage([
            ("c1", "2026-01-03T00:00:00.000Z"),
            ("c1", "2026-01-02T00:00:00.000Z"),   // exactly on the bound: in
            ("c1", "2026-01-01T23:59:59.000Z")    // inside the slack, before since: out
        ], next: nil)
        let mock = session(sent: [.init(sent)])
        let data = try await collect(mock, since: since)

        #expect(data.metrics["sent_updates"] == .int(2))
        let dueAt = try #require(mock.variables("SentPosts").first?["dueAt"] as? [String: Any])
        #expect(dueAt["start"] as? String == "2025-12-26T00:00:00Z")
        #expect(dueAt["end"] == nil)
    }

    @Test("All time sends no dueAt filter rather than a date in year 1")
    func allTimeSendsNoFilter() async throws {
        let mock = session()
        _ = try await collect(mock)
        let variables = try #require(mock.variables("SentPosts").first)
        #expect(variables["dueAt"] is NSNull)
    }

    @Test("A sent post with no sentAt counts with no window, and is excluded once there is one")
    func missingSentAt() async throws {
        let sent = [MockURLSession.Response(Self.sentPage([("c1", nil)], next: nil))]
        #expect(try await collect(session(sent: sent)).metrics["sent_updates"] == .int(1))
        #expect(try await collect(session(sent: sent), since: Self.date("2026-01-01T00:00:00Z"))
            .metrics["sent_updates"] == .int(0))
    }

    @Test("Timestamps without fractional seconds decode too")
    func plainTimestamps() async throws {
        let sent = Self.sentPage([("c1", "2026-01-03T00:00:00Z")], next: nil)
        let data = try await collect(session(sent: [.init(sent)]), since: Self.date("2026-01-01T00:00:00Z"))
        #expect(data.metrics["sent_updates"] == .int(1))
    }

    // MARK: - Errors

    @Test("An error inside an HTTP 200 fails the collection instead of reading as empty")
    func graphQLErrorThrows() async throws {
        let body = #"{"errors":[{"message":"Cannot query field","extensions":{"code":"GRAPHQL_VALIDATION_FAILED"}}],"data":null}"#
        await #expect {
            try await collect(session(scheduled: [.init(body)]))
        } throws: { error in
            guard case CollectorError.serviceError(let code) = error else { return false }
            return code == "GRAPHQL_VALIDATION_FAILED"
        }
    }

    @Test("A scope refusal on anything but metrics is still an error")
    func scopeRefusalElsewhereThrows() async throws {
        let body = #"{"errors":[{"message":"Insufficient scope","path":["channels"],"extensions":{"code":"INSUFFICIENT_SCOPE"}}],"data":null}"#
        await #expect {
            try await collect(session(channels: body))
        } throws: { error in
            guard case CollectorError.serviceError(let code) = error else { return false }
            return code == "INSUFFICIENT_SCOPE"
        }
    }

    @Test("A non-scope error on metrics is still an error, not a missing scope")
    func otherErrorOnMetricsThrows() async throws {
        let body = #"""
            {"errors":[{"message":"boom","path":["posts","edges",0,"node","metrics"],"extensions":{"code":"INTERNAL_SERVER_ERROR"}}],
             "data":{"posts":{"edges":[{"node":{"channelId":"c1","channelService":"mastodon","sentAt":null,"metrics":null}}],
             "pageInfo":{"hasNextPage":false,"endCursor":null}}}}
            """#
        await #expect {
            try await collect(session(sent: [.init(body)]))
        } throws: { error in
            guard case CollectorError.serviceError(let code) = error else { return false }
            return code == "INTERNAL_SERVER_ERROR"
        }
    }

    @Test("A response with neither data nor errors is an error")
    func emptyEnvelopeThrows() async throws {
        await #expect(throws: CollectorError.self) {
            try await collect(session(account: "{}"))
        }
    }

    @Test("A rejected key propagates as HTTP 401")
    func unauthorised() async throws {
        let body = #"{"errors":[{"message":"Access token is not valid","extensions":{"code":"UNAUTHENTICATED"}}]}"#
        let mock = GraphQLMockSession(["Account": [.init(body, status: 401)]])
        await #expect {
            try await collect(mock)
        } throws: { error in
            guard case CollectorError.httpError(let status, _) = error else { return false }
            return status == 401
        }
    }

    @Test("A missing key is reported by name")
    func missingKey() async throws {
        await #expect {
            try await BufferCollector(session: session()).collect(since: .distantPast, credentials: Credentials([:]))
        } throws: { error in
            guard case CollectorError.missingCredential(let key) = error else { return false }
            return key == "api_key"
        }
    }

    @Test("A malformed metric is an error, not a zero")
    func malformedMetricThrows() async throws {
        let sent = #"{"data":{"posts":{"edges":[{"node":{"channelId":"c1","channelService":"mastodon","sentAt":null,"metrics":[{"type":"clicks","value":"ten"}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#
        await #expect(throws: CollectorError.self) {
            try await collect(session(sent: [.init(sent)]))
        }
    }

    // MARK: - The wire

    @Test("Every request is a POST to the GraphQL endpoint, with the key in a Bearer header and not the URL")
    func requestShape() async throws {
        let mock = session()
        _ = try await collect(mock)

        #expect(!mock.requests.isEmpty)
        for request in mock.requests {
            #expect(request.httpMethod == "POST")
            #expect(request.url == BufferCollector.endpoint)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
            #expect(request.url?.absoluteString.contains("tok-123") == false)
        }
        #expect(mock.operations == ["Account", "Channels", "SentPosts", "ScheduledPosts"])
    }

    @Test("The label is the account name")
    func label() async {
        let label = await BufferCollector(session: session()).fetchLabel(credentials: credentials)
        #expect(label == "cate")
    }
}
