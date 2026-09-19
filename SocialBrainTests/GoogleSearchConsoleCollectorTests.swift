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

        _ = try await collector.collect(since: .distantPast, credentials: credentials)

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

        _ = try await collector.collect(since: .distantPast, credentials: credentials)

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

        let data = try await collector.collect(since: .distantPast, credentials: credentials)

        #expect(data.metrics["clicks"] == .int(420))
        #expect(data.metrics["impressions"] == .int(9001))
    }

    @Test("Missing credentials are reported by name")
    func missingCredentialsAreNamed() async throws {
        let collector = GoogleSearchConsoleCollector(session: makeSession())

        let error = await #expect(throws: CollectorError.self) {
            _ = try await collector.collect(since: .distantPast, credentials: Credentials(["client_id": "cid"]))
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

    @Test("All time is clamped to the 16 months Search Console actually serves")
    func allTimeIsClampedToSixteenMonths() async throws {
        // Search Console keeps about 16 months and returns nothing older, so an
        // unclamped request covers less than it looks like it does — silently.
        // Before #96 this path could not arise at all: nil meant 28 days here
        // and something different in every other collector.
        let session = makeSession()
        _ = try await GoogleSearchConsoleCollector(session: session)
            .collect(since: .distantPast, credentials: credentials)

        let path = "/webmasters/v3/sites/https%3A%2F%2Fexample.com%2F/searchAnalytics/query"
        let bodies = session.requests(path: path)
            .compactMap(\.httpBody)
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let starts = Set(bodies.compactMap { $0["startDate"] as? String })
        #expect(starts.count == 1)

        let start = try #require(starts.first)
        // Not the year 1, which is what .distantPast would send unclamped.
        #expect(!start.hasPrefix("0001"))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let startDate = try #require(formatter.date(from: start))
        let daysBack = CollectionWindow.days(from: startDate, to: Date())
        #expect(daysBack == GoogleSearchConsoleCollector.maximumDays)
    }

    @Test("The window is formatted in UTC, not the machine's time zone")
    func windowIsFormattedInUTC() async throws {
        // This formatter carried no time zone, so it used the machine's. A run
        // near midnight therefore asked Search Console for a different day than
        // it asked GoatCounter and Jetpack for, and the prompt presented the
        // two side by side (#96).
        //
        // Four cases, and all four are needed. Both ends of a UTC day, because
        // one alone is vacuous in half the world: 00:30Z falls on the previous
        // local day only at a negative offset, 23:30Z on the next local day
        // only at a positive one. And both halves of the year, because a
        // formatter converts each instant using the zone's offset *at that
        // instant* — Europe/Dublin is +01:00 today but +00:00 in January, so a
        // winter-only case cannot drift here no matter what the zone is now.
        // The first version of this test had exactly that hole and passed with
        // the fix removed.
        //
        // CI runs in UTC, where neither can differ, so this test cannot fail
        // there — it earns its keep on a developer machine. That is the nature
        // of the bug: it is invisible in the zone CI happens to use.
        let cases: [(stamp: TimeInterval, expected: String)] = [
            (1_767_227_400, "2026-01-01"),  // 2026-01-01 00:30 UTC — winter
            (1_767_310_200, "2026-01-01"),  // 2026-01-01 23:30 UTC — winter
            (1_782_865_800, "2026-07-01"),  // 2026-07-01 00:30 UTC — summer
            (1_782_948_600, "2026-07-01")   // 2026-07-01 23:30 UTC — summer
        ]

        for (stamp, expected) in cases {
            let session = makeSession()
            _ = try await GoogleSearchConsoleCollector(session: session)
                .collect(since: Date(timeIntervalSince1970: stamp), credentials: credentials)

            let path = "/webmasters/v3/sites/https%3A%2F%2Fexample.com%2F/searchAnalytics/query"
            let bodies = session.requests(path: path)
                .compactMap(\.httpBody)
                .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            #expect(Set(bodies.compactMap { $0["startDate"] as? String }) == [expected],
                    "startDate drifted for \(expected) — formatter is not in UTC")
        }
    }

    @Test("Propagates an HTTP error from the token endpoint")
    func propagatesTokenError() async throws {
        let session = MockURLSession(["/token": ("{\"error\":\"invalid_grant\"}", 400)])
        let collector = GoogleSearchConsoleCollector(session: session)

        await #expect(throws: CollectorError.self) {
            _ = try await collector.collect(since: .distantPast, credentials: credentials)
        }
    }
}
