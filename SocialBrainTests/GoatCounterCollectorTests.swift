import Testing
import Foundation
@testable import SocialBrain

@Suite("GoatCounter Collector Tests")
struct GoatCounterCollectorTests {

    private static let totalsJSON = """
    {
      "total": 8421,
      "total_unique": 3102
    }
    """

    private static let hitsJSON = """
    {
      "hits": [
        { "path": "/blog/swift-tips",   "count": 1200 },
        { "path": "/blog/grdb-guide",   "count":  900 },
        { "path": "/",                  "count":  700 },
        { "path": "/about",             "count":  450 },
        { "path": "/blog/swiftui-tips", "count":  300 }
      ]
    }
    """

    // MARK: - What goes on the wire

    @Test("Every request carries the token as a Bearer header")
    func requestsAreAuthenticated() async throws {
        // Both endpoints need it. A collector that authenticated one and not the
        // other would pass a first-request check, and the unauthenticated half
        // would surface as an error the user reads as a broken key.
        let session = MockURLSession([
            "/api/v0/stats/total": (Self.totalsJSON, 200),
            "/api/v0/stats/hits":  (Self.hitsJSON,   200)
        ])
        _ = try await GoatCounterCollector(session: session).collect(
            since: nil,
            credentials: Credentials(["api_key": "test-token", "site_code": "mysite"])
        )

        let paths = Set(session.requestedURLs.map(\.path))
        #expect(paths == ["/api/v0/stats/total", "/api/v0/stats/hits"])
        for path in paths {
            #expect(session.headerValues("Authorization", path: path) == ["Bearer test-token"],
                    "missing or wrong Authorization on \(path)")
        }
        // #68: a percent sign means something was encoded twice.
        for url in session.requestedURLs {
            #expect(!url.absoluteString.contains("%25"), "double-encoded: \(url)")
        }
    }

    @Test("Parses total pageviews, unique visitors, and top pages")
    func collectMetrics() async throws {
        let session = MockURLSession([
            "/api/v0/stats/total": (GoatCounterCollectorTests.totalsJSON, 200),
            "/api/v0/stats/hits":  (GoatCounterCollectorTests.hitsJSON,   200)
        ])
        let collector = GoatCounterCollector(session: session)
        let credentials = Credentials([
            "api_key":   "test-token",
            "site_code": "mysite"
        ])
        let data = try await collector.collect(since: nil, credentials: credentials)

        #expect(data.platform == .goatCounter)
        #expect(data.intMetric("total_pageviews") == 8421)
        #expect(data.intMetric("unique_visitors")  == 3102)
        #expect(data.stringMetric("top_page_1")   == "/blog/swift-tips")
        #expect(data.stringMetric("top_page_5")   == "/blog/swiftui-tips")
    }

    @Test("Throws missingCredential when api_key is absent")
    func missingAPIKey() async throws {
        let collector = GoatCounterCollector()
        let credentials = Credentials(["site_code": "mysite"])
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: nil, credentials: credentials)
        }
    }

    @Test("Throws missingCredential when site_code is absent")
    func missingSiteCode() async throws {
        let collector = GoatCounterCollector()
        let credentials = Credentials(["api_key": "token"])
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: nil, credentials: credentials)
        }
    }
    @Test("since is sent as the start of the requested window")
    func sinceIsSentAsStart() async throws {
        let session = MockURLSession([
            "/api/v0/stats/total": (GoatCounterCollectorTests.totalsJSON, 200),
            "/api/v0/stats/hits":  (GoatCounterCollectorTests.hitsJSON,   200)
        ])
        let collector = GoatCounterCollector(session: session)
        let since = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01

        _ = try await collector.collect(
            since: since,
            credentials: Credentials(["api_key": "k", "site_code": "example"])
        )

        // Both endpoints take the window; asserting only one let a wrong
        // parameter name on /stats/hits pass unnoticed.
        for path in ["/api/v0/stats/total", "/api/v0/stats/hits"] {
            // `.withFullDate` emits exactly YYYY-MM-DD, so equality is available
            // and hasPrefix would be strictly weaker.
            #expect(session.queryValue("start", path: path) == "2026-01-01",
                    "start missing or wrong on \(path)")
            // `end` is "now", so pin the shape rather than the value.
            let end = session.queryValue("end", path: path)
            #expect(end?.count == 10, "end missing or not a full date on \(path)")
            #expect(end?.allSatisfy { $0.isNumber || $0 == "-" } == true,
                    "end is not a YYYY-MM-DD date on \(path)")
        }
    }

    /// GoatCounter's documented query parameters, from
    /// `https://www.goatcounter.com/api.json`, checked 2026-09-18.
    private static let documentedParameters: [String: Set<String>] = [
        "/api/v0/stats/total": ["start", "end", "path_by_name", "include_paths"],
        "/api/v0/stats/hits":  ["start", "end", "limit", "group",
                                "path_by_name", "daily", "include_paths", "exclude_paths"]
    ]

    @Test("Sends no parameter GoatCounter does not document")
    func sendsOnlyDocumentedParameters() async throws {
        // An allowlist, not a check for the one bad parameter: GoatCounter
        // rejects unknown query parameters rather than ignoring them, so any
        // invented parameter 400s the request and — because collect() awaits
        // both endpoints together — fails the entire collection. That is what
        // `order=-count` did (#154); a denylist would have caught that one and
        // waved the next one through.
        //
        // MockURLSession answers any query, so this is the only place the
        // request's shape is checked at all. #143 is the same gap in the other
        // collectors.
        let session = MockURLSession([
            "/api/v0/stats/total": (Self.totalsJSON, 200),
            "/api/v0/stats/hits":  (Self.hitsJSON,   200)
        ])
        _ = try await GoatCounterCollector(session: session).collect(
            since: nil,
            credentials: Credentials(["api_key": "k", "site_code": "example"])
        )

        for (path, allowed) in Self.documentedParameters {
            for request in session.requests(path: path) {
                let sent = Set(
                    URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                        .queryItems?.map(\.name) ?? []
                )
                #expect(sent.subtracting(allowed).isEmpty,
                        "\(path) sends undocumented \(sent.subtracting(allowed).sorted())")
            }
        }
    }

    @Test("Asks for five top pages and relies on the server's own ordering")
    func topPagesRequestIsLimitedNotOrdered() async throws {
        // limit=5 is what makes top_page_1...5 the *top* five rather than an
        // arbitrary five: GoatCounter's default page size is 20. Deleting it
        // left every test green, which is the #143 class of gap.
        //
        // The ordering is the server's — `stats/hits` sorts by count descending
        // (db/query/hit_list.List.sql, `order by total desc`), so limit alone is
        // enough and there is nothing to ask for. See sendsOnlyDocumentedParameters
        // for why asking anyway was fatal.
        let session = MockURLSession([
            "/api/v0/stats/total": (Self.totalsJSON, 200),
            "/api/v0/stats/hits":  (Self.hitsJSON,   200)
        ])
        _ = try await GoatCounterCollector(session: session).collect(
            since: nil,
            credentials: Credentials(["api_key": "k", "site_code": "example"])
        )

        #expect(session.queryValue("limit", path: "/api/v0/stats/hits") == "5")
        #expect(session.queryValues("order", path: "/api/v0/stats/hits").isEmpty)
    }

}
