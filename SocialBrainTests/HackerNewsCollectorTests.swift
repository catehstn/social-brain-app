import Testing
import Foundation
@testable import SocialBrain

/// Hacker News had no test suite (#48). Assertions are written against the
/// **request** as well as the parsed result, because a collector can build an
/// entirely wrong URL and still pass a result-level test — which is how #68's
/// Google Search Console bug survived.
@Suite("Hacker News Collector Tests")
struct HackerNewsCollectorTests {

    private static let searchJSON = """
        {"hits":[
          {"objectID":"1","title":"A post about widgets","url":"https://example.com/a",
           "points":120,"num_comments":45},
          {"objectID":"2","title":"Another one","url":"https://example.com/b",
           "points":40,"num_comments":8},
          {"objectID":"3","story_title":"Comment thread","url":"https://example.com/c",
           "points":75,"num_comments":12},
          {"objectID":"4","title":"No points yet","url":"https://example.com/d",
           "points":0,"num_comments":0}
        ]}
        """

    private func makeSession(_ body: String = searchJSON, status: Int = 200) -> MockURLSession {
        MockURLSession(["/api/v1/search": (body, status)])
    }

    private let credentials = Credentials(["site_code": "example.com"])

    // MARK: - Parsing

    @Test("Counts mentions and sums points and comments")
    func parsesTotals() async throws {
        let collector = HackerNewsCollector(session: makeSession())
        let data = try await collector.collect(since: nil, credentials: credentials)

        #expect(data.metrics["mention_count"] == .int(4))
        #expect(data.metrics["total_points"] == .int(235))
        #expect(data.metrics["total_comments"] == .int(65))
    }

    @Test("Top stories are ranked by points, highest first")
    func ranksTopStories() async throws {
        let collector = HackerNewsCollector(session: makeSession())
        let data = try await collector.collect(since: nil, credentials: credentials)

        #expect(data.metrics["top_story_1"] == .string("A post about widgets (120 pts)"))
        #expect(data.metrics["top_story_2"] == .string("Comment thread (75 pts)"))
        #expect(data.metrics["top_story_3"] == .string("Another one (40 pts)"))
    }

    @Test("A hit with no points is excluded from the top stories")
    func excludesZeroPointHits() async throws {
        let collector = HackerNewsCollector(session: makeSession())
        let data = try await collector.collect(since: nil, credentials: credentials)

        // Four hits, but only three have points — there is no fourth slot, and
        // the zero-point one must not occupy one.
        #expect(data.metrics["top_story_4"] == nil)
        #expect(data.metrics.values.contains(.string("No points yet (0 pts)")) == false)
    }

    @Test("A comment hit falls back to story_title")
    func usesStoryTitleForComments() async throws {
        let collector = HackerNewsCollector(session: makeSession())
        let data = try await collector.collect(since: nil, credentials: credentials)

        // objectID 3 has no `title`, only `story_title`.
        #expect(data.metrics["top_story_2"] == .string("Comment thread (75 pts)"))
    }

    @Test("An empty result set yields zeros rather than absent metrics")
    func handlesNoMentions() async throws {
        let collector = HackerNewsCollector(session: makeSession(#"{"hits":[]}"#))
        let data = try await collector.collect(since: nil, credentials: credentials)

        #expect(data.metrics["mention_count"] == .int(0))
        #expect(data.metrics["total_points"] == .int(0))
        #expect(data.metrics["top_story_1"] == nil)
    }

    // MARK: - The request

    @Test("Searches for the configured domain, restricted to URL attributes")
    func requestsTheRightSearch() async throws {
        let session = makeSession()
        _ = try await HackerNewsCollector(session: session).collect(since: nil, credentials: credentials)

        #expect(session.queryValue("query", path: "/api/v1/search") == "example.com")
        // Without this the search matches the domain appearing in body text,
        // which is not a mention of the site.
        #expect(session.queryValue("restrictSearchableAttributes", path: "/api/v1/search")
                == "url,story_url")
    }

    @Test("since is sent as a numeric created_at filter")
    func sendsSinceAsNumericFilter() async throws {
        let session = makeSession()
        let since = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01 UTC

        _ = try await HackerNewsCollector(session: session).collect(since: since, credentials: credentials)

        #expect(session.queryValue("numericFilters", path: "/api/v1/search")
                == "created_at_i>1767225600")
    }

    @Test("No since defaults to a 28-day window rather than all time")
    func defaultsToRecentWindow() async throws {
        let session = makeSession()
        _ = try await HackerNewsCollector(session: session).collect(since: nil, credentials: credentials)

        let filter = try #require(session.queryValue("numericFilters", path: "/api/v1/search"))
        let timestamp = try #require(Int(filter.replacingOccurrences(of: "created_at_i>", with: "")))
        let daysAgo = Date().timeIntervalSince1970 - Double(timestamp)

        #expect(daysAgo > 27 * 86_400)
        #expect(daysAgo < 29 * 86_400)
    }

    // MARK: - Failures

    @Test("A missing domain is reported by name")
    func missingDomainIsNamed() async throws {
        let collector = HackerNewsCollector(session: makeSession())

        let error = await #expect(throws: CollectorError.self) {
            _ = try await collector.collect(since: nil, credentials: Credentials([:]))
        }
        #expect(error?.localizedDescription.contains("site_code") == true)
    }

    @Test("An empty domain is rejected rather than searched for")
    func emptyDomainIsRejected() async throws {
        let collector = HackerNewsCollector(session: makeSession())

        await #expect(throws: CollectorError.self) {
            _ = try await collector.collect(since: nil, credentials: Credentials(["site_code": ""]))
        }
    }

    @Test("An HTTP error propagates")
    func propagatesHTTPError() async throws {
        let collector = HackerNewsCollector(session: makeSession(#"{"error":"nope"}"#, status: 503))

        await #expect(throws: CollectorError.self) {
            _ = try await collector.collect(since: nil, credentials: credentials)
        }
    }

    @Test("The label is the configured domain")
    func labelIsTheDomain() async throws {
        let label = await HackerNewsCollector(session: makeSession()).fetchLabel(credentials: credentials)
        #expect(label == "example.com")
    }
}
