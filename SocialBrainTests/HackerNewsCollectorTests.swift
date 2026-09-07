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
          {"objectID":"3","title":"Third story","url":"https://example.com/c",
           "points":75,"num_comments":12},
          {"objectID":"4","title":"No points yet","url":"https://example.com/d",
           "points":0,"num_comments":0}
        ],"nbHits":4,"nbPages":1}
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
        #expect(data.metrics["top_story_2"] == .string("Third story (75 pts)"))
        #expect(data.metrics["top_story_3"] == .string("Another one (40 pts)"))
    }

    @Test("A hit with no points is excluded from the top stories")
    func excludesZeroPointHits() async throws {
        // Two hits, one with zero points. With the previous four-hit fixture
        // prefix(3) dropped the zero-point hit anyway, so removing the filter
        // left the test passing — it tested the prefix, not the filter.
        let json = """
            {"hits":[
              {"objectID":"1","title":"Real","url":"https://example.com/a","points":10,"num_comments":1},
              {"objectID":"2","title":"Nothing yet","url":"https://example.com/b","points":0,"num_comments":0}
            ],"nbHits":2,"nbPages":1}
            """
        let data = try await HackerNewsCollector(session: makeSession(json))
            .collect(since: nil, credentials: credentials)

        #expect(data.metrics["top_story_1"] == .string("Real (10 pts)"))
        #expect(data.metrics["top_story_2"] == nil)
    }

    @Test("A hit with no title at all is labelled rather than dropped")
    func handlesMissingTitle() async throws {
        // The story_title fallback exists for comment hits, but comments carry
        // no `url` and so can never match under restrictSearchableAttributes=url.
        // Verified against the live API: 32 of 32 hits were stories with a url
        // and no story_title. This covers the reachable case instead.
        let json = #"{"hits":[{"objectID":"9","url":"https://example.com/x","points":5,"num_comments":0}],"nbHits":1,"nbPages":1}"#
        let data = try await HackerNewsCollector(session: makeSession(json))
            .collect(since: nil, credentials: credentials)

        #expect(data.metrics["top_story_1"] == .string("(untitled) (5 pts)"))
    }

    @Test("An empty result set yields zeros rather than absent metrics")
    func handlesNoMentions() async throws {
        // Verified live: a zero-hit query answers {"hits":[],"nbHits":0,"nbPages":0}.
        let session = makeSession(#"{"hits":[],"nbHits":0,"nbPages":0}"#)
        let collector = HackerNewsCollector(session: session)
        let data = try await collector.collect(since: nil, credentials: credentials)

        #expect(data.metrics["mention_count"] == .int(0))
        #expect(data.metrics["total_points"] == .int(0))
        #expect(data.metrics["top_story_1"] == nil)
        // nbPages of 0 has to terminate the loop, not run it to the cap. The
        // metrics above are the same either way, so without this nothing pins it.
        #expect(session.requests(path: "/api/v1/search").count == 1)
    }

    // MARK: - The request

    // MARK: - Pagination

    private static func hnPage(hits: Int, nbHits: Int, nbPages: Int, idBase: Int) -> String {
        let items = (0..<hits).map { i in
            """
            {"objectID":"\(idBase + i)","title":"Story \(idBase + i)",\
            "url":"https://example.com/\(idBase + i)","points":2,"num_comments":1}
            """
        }
        return "{\"hits\":[\(items.joined(separator: ","))],\"nbHits\":\(nbHits),\"nbPages\":\(nbPages)}"
    }

    @Test("Walks every page the API will serve")
    func walksEveryPage() async throws {
        // One page of 100 was fetched and hits.count reported, so any busy
        // period came back as exactly 100 mentions.
        let session = MockURLSession([
            "/api/v1/search": [
                .init(Self.hnPage(hits: 100, nbHits: 250, nbPages: 3, idBase: 0)),
                .init(Self.hnPage(hits: 100, nbHits: 250, nbPages: 3, idBase: 100)),
                .init(Self.hnPage(hits: 50, nbHits: 250, nbPages: 3, idBase: 200))
            ]
        ])
        let data = try await HackerNewsCollector(session: session)
            .collect(since: nil, credentials: credentials)

        #expect(session.requests(path: "/api/v1/search").count == 3)
        #expect(data.intMetric("mention_count") == 250)
        #expect(data.intMetric("total_points") == 500)   // 250 hits x 2
        #expect(data.metrics["mentions_sampled"] == nil)
    }

    @Test("Asks for each page in turn")
    func sendsThePageNumber() async throws {
        let session = MockURLSession([
            "/api/v1/search": [
                .init(Self.hnPage(hits: 100, nbHits: 150, nbPages: 2, idBase: 0)),
                .init(Self.hnPage(hits: 50, nbHits: 150, nbPages: 2, idBase: 100))
            ]
        ])
        _ = try await HackerNewsCollector(session: session)
            .collect(since: nil, credentials: credentials)
        #expect(session.queryValues("page", path: "/api/v1/search") == ["0", "1"])
    }

    @Test("The mention count is the API's total, not what was fetched")
    func countIsExactEvenWhenCapped() async throws {
        // The part that makes this better than the other collectors. Algolia
        // returns nbHits — the true number of matches, honouring the date
        // filter — so the headline count is right even when the hits behind it
        // cannot all be paged. Verified live: a one-year window reports
        // nbHits 369,830 with nbPages capped at 10.
        let session = MockURLSession([
            "/api/v1/search": [
                .init(Self.hnPage(hits: 100, nbHits: 369_830, nbPages: 10, idBase: 0))
            ]
        ])
        let data = try await HackerNewsCollector(session: session)
            .collect(since: nil, credentials: credentials)

        #expect(session.requests(path: "/api/v1/search").count == 10)
        #expect(data.intMetric("mention_count") == 369_830)
        // The sums cannot be exact, and say so rather than looking complete.
        let note = try #require(data.stringMetric("mentions_sampled"))
        #expect(note.contains("1000"))
        #expect(note.contains("369830"))
    }

    @Test("Stops at the last page rather than asking for one that isn't there")
    func stopsAtLastPage() async throws {
        let session = MockURLSession([
            "/api/v1/search": [.init(Self.hnPage(hits: 4, nbHits: 4, nbPages: 1, idBase: 0))]
        ])
        _ = try await HackerNewsCollector(session: session)
            .collect(since: nil, credentials: credentials)
        #expect(session.requests(path: "/api/v1/search").count == 1)
    }

    @Test("Searches for the configured domain, restricted to URL attributes")
    func requestsTheRightSearch() async throws {
        let session = makeSession()
        _ = try await HackerNewsCollector(session: session).collect(since: nil, credentials: credentials)

        #expect(session.queryValue("query", path: "/api/v1/search") == "example.com")
        // Without the restriction the search matches the domain appearing in
        // comment text, which is not a mention of the site.
        // `url` alone. This test first asserted "url,story_url" — pinning a
        // value the live API rejects with HTTP 400.
        #expect(session.queryValue("restrictSearchableAttributes", path: "/api/v1/search") == "url")
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
