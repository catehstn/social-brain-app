import Testing
import Foundation
@testable import SocialBrain

/// Google Search Console had no test suite at all (#48), which is how #68
/// survived: the collector percent-encoded the site URL and then let
/// `appendingPathComponent` encode it a second time, so every request targeted
/// `sites/https%253A//example.com//searchAnalytics/query` — a property that
/// cannot exist. GSC has never returned real data.
///
/// The assertions below are written against the **request URL**, not just the
/// parsed result, because a result-level assertion cannot see this class of bug.
@Suite("Google Search Console Collector Tests")
struct GoogleSearchConsoleCollectorTests {

    private static let tokenJSON = #"{"access_token":"ya29.test","expires_in":3599}"#

    private static let totalsJSON = """
        {"rows":[{"keys":[],"clicks":420,"impressions":9001,"ctr":0.0466,"position":12.5}]}
        """

    /// All three analytics calls share one path, so one fixture serves them.
    private func makeSession() -> MockURLSession {
        MockURLSession([
            "/token": (Self.tokenJSON, 200),
            "/webmasters/v3/sites/https%3A%2F%2Fexample.com%2F/searchAnalytics/query":
                (Self.totalsJSON, 200)
        ])
    }

    private let credentials = Credentials([
        "refresh_token": "refresh",
        "client_id": "cid",
        "client_secret": "secret",
        "site_url": "https://example.com/"
    ])

    // MARK: - URL construction

    @Test("The site URL is one fully-encoded path segment")
    func siteURLIsASinglePathSegment() throws {
        let url = try GoogleSearchConsoleCollector.searchAnalyticsURL(siteURL: "https://example.com/")

        // absoluteString, not url.path — path decodes percent-escapes and would
        // report this as correct even when it is not.
        #expect(url.absoluteString ==
                "https://searchconsole.googleapis.com/webmasters/v3/sites/https%3A%2F%2Fexample.com%2F/searchAnalytics/query")
    }

    @Test("The colon is encoded once, not twice")
    func colonIsNotDoubleEncoded() throws {
        let url = try GoogleSearchConsoleCollector.searchAnalyticsURL(siteURL: "https://example.com/")

        // The exact signature of the old bug.
        #expect(!url.absoluteString.contains("%253A"))
        #expect(url.absoluteString.contains("https%3A%2F%2F"))
    }

    @Test("Slashes in the site URL do not become extra path segments")
    func slashesDoNotSplitTheSegment() throws {
        let url = try GoogleSearchConsoleCollector.searchAnalyticsURL(siteURL: "https://example.com/")

        // Previously the site's own slashes split it across several segments,
        // producing an empty one and a doubled separator.
        #expect(!url.absoluteString.contains("//example.com"))
        #expect(!url.absoluteString.contains("com//"))
    }

    @Test("Domain properties encode their colon too")
    func domainPropertyIsEncoded() throws {
        // sc-domain:example.com is the other property form Search Console accepts.
        let url = try GoogleSearchConsoleCollector.searchAnalyticsURL(siteURL: "sc-domain:example.com")

        #expect(url.absoluteString.contains("sites/sc-domain%3Aexample.com/"))
    }

    @Test("Encoding covers the reserved characters a site URL can contain",
          arguments: [
            ("https://example.com/", "https%3A%2F%2Fexample.com%2F"),
            ("sc-domain:example.com", "sc-domain%3Aexample.com"),
            ("https://example.com/blog/", "https%3A%2F%2Fexample.com%2Fblog%2F"),
            ("https://sub.example.co.uk/", "https%3A%2F%2Fsub.example.co.uk%2F")
          ])
    func encodingIsStrict(site: String, expected: String) {
        #expect(GoogleSearchConsoleCollector.percentEncodedSiteSegment(site) == expected)
    }

    // MARK: - Requests actually issued

    @Test("The collector requests the correctly encoded property")
    func collectRequestsTheEncodedProperty() async throws {
        let session = makeSession()
        let collector = GoogleSearchConsoleCollector(session: session)

        _ = try await collector.collect(since: nil, credentials: credentials)

        let analytics = session.requestedURLs
            .map(\.absoluteString)
            .filter { $0.contains("searchAnalytics") }
        #expect(analytics.count == 3)  // totals, queries, pages
        #expect(analytics.allSatisfy {
            $0 == "https://searchconsole.googleapis.com/webmasters/v3/sites/https%3A%2F%2Fexample.com%2F/searchAnalytics/query"
        })
    }

    @Test("The access token is sent as a bearer header, not in the query")
    func tokenIsSentAsAHeader() async throws {
        let session = makeSession()
        let collector = GoogleSearchConsoleCollector(session: session)

        _ = try await collector.collect(since: nil, credentials: credentials)

        let path = "/webmasters/v3/sites/https%3A%2F%2Fexample.com%2F/searchAnalytics/query"
        // allSatisfy is true of an empty array, so pin the count as well.
        #expect(session.headerValues("Authorization", path: path).count == 3)
        #expect(session.headerValues("Authorization", path: path).allSatisfy { $0 == "Bearer ya29.test" })
        #expect(!session.requestedURLs.map(\.absoluteString).contains { $0.contains("access_token=") })
    }

    // MARK: - Parsing

    @Test("Parses totals into metrics")
    func parsesTotals() async throws {
        let session = makeSession()
        let collector = GoogleSearchConsoleCollector(session: session)

        let data = try await collector.collect(since: nil, credentials: credentials)

        #expect(data.metrics["clicks"] == .int(420))
        #expect(data.metrics["impressions"] == .int(9001))
    }

    @Test("Missing credentials are reported by name")
    func missingCredentialsAreNamed() async throws {
        let collector = GoogleSearchConsoleCollector(session: makeSession())

        let error = await #expect(throws: CollectorError.self) {
            _ = try await collector.collect(since: nil, credentials: Credentials(["client_id": "cid"]))
        }
        // Asserting only the error type would pass for any case and would not
        // test what the test's name claims.
        #expect(error?.localizedDescription.contains("refresh_token") == true)
    }

    @Test("A site URL in neither accepted form is rejected with an explanation",
          arguments: ["", "   ", "example.com", "www.example.com", "ftp://example.com"])
    func rejectsUnusableSiteURL(raw: String) {
        #expect(throws: CollectorError.self) {
            _ = try GoogleSearchConsoleCollector.validatedSiteURL(raw)
        }
    }

    @Test("Both accepted property forms pass validation",
          arguments: ["https://example.com/", "http://example.com/", "sc-domain:example.com",
                      "  https://example.com/  "])
    func acceptsValidSiteURL(raw: String) throws {
        let validated = try GoogleSearchConsoleCollector.validatedSiteURL(raw)
        #expect(validated == raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("The three analytics calls request different dimensions and the same window")
    func requestBodiesDifferByDimension() async throws {
        // Every call goes to one URL, so asserting only the URL cannot tell them
        // apart: a collector sending dimensions: ["query"] three times would pass.
        let session = makeSession()
        let collector = GoogleSearchConsoleCollector(session: session)
        let since = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01 UTC

        _ = try await collector.collect(since: since, credentials: credentials)

        let path = "/webmasters/v3/sites/https%3A%2F%2Fexample.com%2F/searchAnalytics/query"
        let bodies = session.requests(path: path)
            .compactMap(\.httpBody)
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(bodies.count == 3)

        let dimensionSets = Set(bodies.map { ($0["dimensions"] as? [String] ?? []).joined(separator: ",") })
        #expect(dimensionSets == ["", "query", "page"])

        // The window is the same for all three, and formatted the way the API
        // wants regardless of the machine's locale.
        #expect(Set(bodies.compactMap { $0["startDate"] as? String }) == ["2026-01-01"])
        #expect(bodies.allSatisfy { ($0["endDate"] as? String)?.count == 10 })
    }

    @Test("Propagates an HTTP error from the token endpoint")
    func propagatesTokenError() async throws {
        let session = MockURLSession(["/token": ("{\"error\":\"invalid_grant\"}", 400)])
        let collector = GoogleSearchConsoleCollector(session: session)

        await #expect(throws: CollectorError.self) {
            _ = try await collector.collect(since: nil, credentials: credentials)
        }
    }
}
