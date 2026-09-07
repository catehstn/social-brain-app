import Testing
import Foundation
@testable import SocialBrain

@Suite("Calendly Collector Tests")
struct CalendlyCollectorTests {

    private static let userJSON = """
    {
      "resource": {
        "uri": "https://api.calendly.com/users/TESTUSER"
      }
    }
    """

    private static let eventsJSON = """
    {
      "collection": [
        {
          "uri": "https://api.calendly.com/scheduled_events/ev1",
          "status": "active",
          "event_type_name": "30 Minute Chat",
          "invitees_email_hint": "alice@example.com"
        },
        {
          "uri": "https://api.calendly.com/scheduled_events/ev2",
          "status": "active",
          "event_type_name": "30 Minute Chat",
          "invitees_email_hint": "bob@example.com"
        },
        {
          "uri": "https://api.calendly.com/scheduled_events/ev3",
          "status": "canceled",
          "event_type_name": "1 Hour Strategy",
          "invitees_email_hint": "carol@example.com"
        }
      ]
    }
    """

    @Test("Parses event counts, cancellations, and top event types")
    func collectMetrics() async throws {
        let session = MockURLSession([
            "/users/me":          (CalendlyCollectorTests.userJSON,   200),
            "/scheduled_events":  (CalendlyCollectorTests.eventsJSON, 200)
        ])
        let collector = CalendlyCollector(
            session: session,
            baseURL: URL(string: "https://api.calendly.com")!
        )
        let credentials = Credentials(["api_key": "test-token"])
        let data = try await collector.collect(since: nil, credentials: credentials)

        #expect(data.platform == .calendly)
        #expect(data.intMetric("events_count")    == 3)
        #expect(data.intMetric("cancelled_count") == 1)
        #expect(data.intMetric("unique_invitees") == 3)
        #expect(data.stringMetric("top_event_type_1") == "30 Minute Chat")
    }

    // MARK: - What goes on the wire
    //
    // This suite had no request assertions at all (#102). Every test above
    // checks what came back, which passes just as happily when the collector
    // asks the wrong question — a window that is never sent, a token that is
    // never attached, a user URI that is dropped. #68 is the standing example:
    // Google Search Console double-encoded its site URL so every request hit a
    // property that could not exist, and the result-level tests were green.

    private func makeSession() -> MockURLSession {
        MockURLSession([
            "/users/me":         (Self.userJSON,   200),
            "/scheduled_events": (Self.eventsJSON, 200)
        ])
    }

    private func makeCollector(_ session: MockURLSession) -> CalendlyCollector {
        CalendlyCollector(session: session, baseURL: URL(string: "https://api.calendly.com")!)
    }

    private let apiCredentials = Credentials(["api_key": "test-token"])

    @Test("Every request carries the token as a Bearer header")
    func requestsAreAuthenticated() async throws {
        // Not "the first request": both endpoints need it, and a collector that
        // authenticated one and not the other would pass a first-request check.
        let session = makeSession()
        _ = try await makeCollector(session).collect(since: nil, credentials: apiCredentials)

        let paths = Set(session.requestedURLs.map(\.path))
        #expect(paths == ["/users/me", "/scheduled_events"])
        for path in paths {
            #expect(session.headerValues("Authorization", path: path) == ["Bearer test-token"],
                    "missing or wrong Authorization on \(path)")
        }
    }

    @Test("The events request carries the user URI it just looked up")
    func eventsRequestScopesToTheUser() async throws {
        // The whole point of the /users/me round trip. Dropping the parameter
        // asks Calendly for every event it will show us, and the metrics would
        // look plausible.
        let session = makeSession()
        _ = try await makeCollector(session).collect(since: nil, credentials: apiCredentials)

        #expect(session.queryValue("user", path: "/scheduled_events")
                == "https://api.calendly.com/users/TESTUSER")
    }

    @Test("A since date is sent as min_start_time, not filtered locally")
    func sinceIsSentToTheAPI() async throws {
        let session = makeSession()
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 14
        c.timeZone = TimeZone(secondsFromGMT: 0)
        let since = Calendar(identifier: .gregorian).date(from: c)!

        _ = try await makeCollector(session).collect(since: since, credentials: apiCredentials)

        let sent = try #require(session.queryValue("min_start_time", path: "/scheduled_events"))
        #expect(sent.hasPrefix("2026-03-14"))
        // A date-time, not a date: the parameter is min_start_*time*, and
        // sending a bare day would be a different request.
        #expect(sent.contains("T"))
        #expect(sent.hasSuffix("Z"), "not UTC: \(sent)")

        // Deliberately the prefix and shape rather than the whole string.
        // Calendly's reference is JavaScript-rendered and could not be read
        // here, so the exact serialisation it wants is unverified — pinning it
        // character for character would cement a guess, which is how the
        // fictional `CTR (%)` header in #107 survived. What is asserted is what
        // can be justified: the right instant, as a UTC date-time.
    }

    @Test("No since means no min_start_time at all")
    func noSinceSendsNoWindow() async throws {
        // The negative half. Without it, a collector that always sent some
        // default window would pass the test above.
        let session = makeSession()
        _ = try await makeCollector(session).collect(since: nil, credentials: apiCredentials)

        #expect(session.queryValue("min_start_time", path: "/scheduled_events") == nil)
    }

    @Test("The events URL is built as Calendly expects, escapes and all")
    func eventsURLIsWellFormed() async throws {
        // On absoluteString, which preserves percent-encoding. url.path and
        // queryItems both decode, so an encoding bug is invisible through them —
        // which is exactly how #68 stayed hidden.
        let session = makeSession()
        _ = try await makeCollector(session).collect(since: nil, credentials: apiCredentials)

        let url = try #require(session.requestedURLs.first { $0.path == "/scheduled_events" })
        let text = url.absoluteString

        #expect(text.hasPrefix("https://api.calendly.com/scheduled_events?"))
        // `:` and `/` are legal in a query component, so `append(queryItems:)`
        // leaves them alone and the URI arrives verbatim. Asserted as it is
        // rather than as it might look — the first version of this test expected
        // escaping that neither happens nor is required, which is guessing from
        // the shape of the code.
        #expect(text.contains("user=https://api.calendly.com/users/TESTUSER"))
        #expect(text.contains("count=100"))
        #expect(text.contains("sort=start_time:desc"))

        // The assertion that would have caught #68. A percent sign in the URL
        // means something was encoded twice: `%3A` re-encoded is `%253A`, and
        // Google Search Console shipped for months asking for
        // `sites/https%253A//example.com//searchAnalytics/query` — a property
        // that cannot exist — with every result-level test green.
        #expect(!text.contains("%25"), "double-encoded: \(text)")
    }

    @Test("Throws missingCredential when api_key is absent")
    func missingAPIKey() async throws {
        let collector = CalendlyCollector()
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: nil, credentials: Credentials([:]))
        }
    }
}
