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

}
