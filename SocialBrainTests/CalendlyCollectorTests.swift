import Testing
import Foundation
@testable import SocialBrain

@Suite("Calendly Collector Tests")
struct CalendlyCollectorTests {

    // MARK: - Fixtures
    //
    // Shaped on responses captured from the live API on 2026-09-22: every field
    // name, the nesting and the value types are as Calendly returned them.
    // Values are redacted by allowlist (CLAUDE.md): every identifier, URI,
    // name and email is invented. What survives is `status`, which the
    // collector reads; dates, in the live format; and enum-like values that
    // identify no one (`"google"`, `"pushed"`, `"google_conference"`,
    // `"User"`, `"en"`, `"12h"`).
    //
    // The fixtures these replace mirrored the code instead — `event_type_name`
    // and `invitees_email_hint`, neither of which exists — so the suite passed
    // while every live run reported "Unknown" and zero invitees (#75).

    private static let userJSON = """
    {
      "resource": {
        "avatar_url": null,
        "created_at": "2020-01-01T00:00:00.000000Z",
        "current_organization": "https://api.calendly.com/organizations/TESTORG",
        "email": "host@example.com",
        "locale": "en",
        "name": "Test Host",
        "resource_type": "User",
        "scheduling_url": "https://calendly.com/test-host",
        "slug": "test-host",
        "time_notation": "12h",
        "timezone": "Etc/UTC",
        "updated_at": "2020-01-01T00:00:00.000000Z",
        "uri": "https://api.calendly.com/users/TESTUSER"
      }
    }
    """

    private static let coffeeType   = "https://api.calendly.com/event_types/TYPE-COFFEE"
    private static let strategyType = "https://api.calendly.com/event_types/TYPE-STRATEGY"

    /// One scheduled event, in the live shape.
    private static func event(
        _ id: String, name: String, type: String, status: String = "active"
    ) -> String {
        """
        {
          "calendar_event": { "external_id": "cal-\(id)", "kind": "google" },
          "created_at": "2026-01-01T09:00:00.000000Z",
          "end_time": "2026-01-02T10:00:00.000000Z",
          "event_guests": [],
          "event_memberships": [
            {
              "buffered_end_time": "2026-01-02T10:00:00.000000Z",
              "buffered_start_time": "2026-01-02T09:30:00.000000Z",
              "user": "https://api.calendly.com/users/TESTUSER",
              "user_email": "host@example.com",
              "user_name": "Test Host"
            }
          ],
          "event_type": "\(type)",
          "invitees_counter": { "active": \(status == "active" ? 1 : 0), "limit": 1, "total": 1 },
          "location": { "join_url": "https://meet.example.com/\(id)", "status": "pushed", "type": "google_conference" },
          "meeting_notes_html": null,
          "meeting_notes_plain": null,
          "name": "\(name)",
          "start_time": "2026-01-02T09:30:00.000000Z",
          "status": "\(status)",
          "updated_at": "2026-01-01T09:00:05.000000Z",
          "uri": "https://api.calendly.com/scheduled_events/\(id)"
        }
        """
    }

    /// A `collection` + `pagination` page, as both endpoints return it.
    private static func page(_ items: [String], next: String? = nil) -> String {
        let token = next.map { "\"\($0)\"" } ?? "null"
        let nextPage = next.map { "\"https://api.calendly.com/scheduled_events?page_token=\($0)\"" } ?? "null"
        return """
        {
          "collection": [\(items.joined(separator: ",\n"))],
          "pagination": {
            "count": \(items.count),
            "next_page": \(nextPage),
            "next_page_token": \(token),
            "previous_page": null,
            "previous_page_token": null
          }
        }
        """
    }

    /// One invitee, in the live shape.
    private static func invitee(_ email: String, event: String, status: String = "active") -> String {
        """
        {
          "cancel_url": "https://calendly.com/cancellations/INV-\(event)",
          "created_at": "2026-01-01T09:00:00.000000Z",
          "email": "\(email)",
          "event": "https://api.calendly.com/scheduled_events/\(event)",
          "first_name": null,
          "invitee_scheduled_by": null,
          "last_name": null,
          "name": "Invented Person",
          "new_invitee": null,
          "no_show": null,
          "old_invitee": null,
          "payment": null,
          "questions_and_answers": [],
          "reconfirmation": null,
          "reschedule_url": "https://calendly.com/reschedulings/INV-\(event)",
          "rescheduled": false,
          "routing_form_submission": null,
          "scheduling_method": null,
          "status": "\(status)",
          "text_reminder_number": null,
          "timezone": "Etc/UTC",
          "tracking": {
            "utm_campaign": null, "utm_source": null, "utm_medium": null,
            "utm_content": null, "utm_term": null, "salesforce_uuid": null
          },
          "updated_at": "2026-01-01T09:00:00.000000Z",
          "uri": "https://api.calendly.com/scheduled_events/\(event)/invitees/INV-\(event)"
        }
        """
    }

    private static func inviteesPath(_ event: String) -> String {
        "/scheduled_events/\(event)/invitees"
    }

    /// Two held Coffee Chats with different people, and one cancelled Strategy
    /// Session.
    private static let eventsJSON = page([
        event("EVT-1", name: "Coffee Chat", type: coffeeType),
        event("EVT-2", name: "Coffee Chat", type: coffeeType),
        event("EVT-3", name: "Strategy Session", type: strategyType, status: "canceled")
    ])

    private static var baseFixtures: [String: (String, Int)] {
        [
            "/users/me":            (userJSON, 200),
            "/scheduled_events":    (eventsJSON, 200),
            inviteesPath("EVT-1"):  (page([invitee("alice@example.com", event: "EVT-1")]), 200),
            inviteesPath("EVT-2"):  (page([invitee("bob@example.com", event: "EVT-2")]), 200),
            inviteesPath("EVT-3"):  (page([invitee("carol@example.com", event: "EVT-3", status: "canceled")]), 200)
        ]
    }

    private func makeSession() -> MockURLSession {
        MockURLSession(Self.baseFixtures)
    }

    private func makeCollector(_ session: MockURLSession) -> CalendlyCollector {
        CalendlyCollector(session: session, baseURL: URL(string: "https://api.calendly.com")!)
    }

    private let apiCredentials = Credentials(["api_key": "test-token"])

    // MARK: - What comes back

    @Test("Parses event counts, cancellations, invitees and top event types")
    func collectMetrics() async throws {
        let data = try await makeCollector(makeSession())
            .collect(since: .distantPast, credentials: apiCredentials)

        #expect(data.platform == .calendly)
        #expect(data.intMetric("events_count")    == 3)
        #expect(data.intMetric("cancelled_count") == 1)
        // Alice and Bob. Carol's event was cancelled.
        #expect(data.intMetric("unique_invitees") == 2)
        #expect(data.stringMetric("top_event_type_1") == "Coffee Chat")
        #expect(data.stringMetric("top_event_type_2") == "Strategy Session")
        #expect(data.stringMetric("top_event_type_3") == nil)
    }

    @Test("The event type name comes from the event's name, never 'Unknown'")
    func eventTypeNameIsRead() async throws {
        // Regression: the collector decoded `event_type_name`, which a
        // scheduled event does not have, so every type fell back to "Unknown"
        // on the live API.
        let data = try await makeCollector(makeSession())
            .collect(since: .distantPast, credentials: apiCredentials)

        for i in 1...3 {
            #expect(data.stringMetric("top_event_type_\(i)") != "Unknown")
        }
    }

    @Test("A renamed event type is tallied once, under its newest name")
    func renamedTypeIsNotSplit() async throws {
        // An event's `name` is its type's name when booked. Live, one of five
        // types carried two names; tallying by name would split it and could
        // push a smaller type above it.
        let events = Self.page([
            Self.event("EVT-1", name: "Coffee Chat", type: Self.coffeeType),
            Self.event("EVT-2", name: "Strategy Session", type: Self.strategyType),
            Self.event("EVT-3", name: "Strategy Session", type: Self.strategyType),
            Self.event("EVT-4", name: "Intro Call", type: Self.coffeeType),
            Self.event("EVT-5", name: "Intro Call", type: Self.coffeeType)
        ])
        var fixtures = Self.baseFixtures
        fixtures["/scheduled_events"] = (events, 200)
        for id in ["EVT-4", "EVT-5"] {
            fixtures[Self.inviteesPath(id)] = (Self.page([Self.invitee("dan@example.com", event: id)]), 200)
        }
        let data = try await makeCollector(MockURLSession(fixtures))
            .collect(since: .distantPast, credentials: apiCredentials)

        // Three of TYPE-COFFEE against two of TYPE-STRATEGY, labelled with the
        // name on the newest (first-listed) event of that type.
        #expect(data.stringMetric("top_event_type_1") == "Coffee Chat")
        #expect(data.stringMetric("top_event_type_2") == "Strategy Session")
        #expect(data.stringMetric("top_event_type_3") == nil)
    }

    @Test("Unique invitees counts people, not bookings")
    func repeatInviteesCountOnce() async throws {
        var fixtures = Self.baseFixtures
        // Bob books twice, the second time with different capitalisation.
        fixtures[Self.inviteesPath("EVT-1")] = (Self.page([Self.invitee("bob@example.com", event: "EVT-1")]), 200)
        fixtures[Self.inviteesPath("EVT-2")] = (Self.page([Self.invitee("Bob@Example.com", event: "EVT-2")]), 200)
        let data = try await makeCollector(MockURLSession(fixtures))
            .collect(since: .distantPast, credentials: apiCredentials)

        #expect(data.intMetric("unique_invitees") == 1)
    }

    @Test("Cancelled events are not looked up, and cancelled invitees are not counted")
    func cancelledInviteesAreExcluded() async throws {
        var fixtures = Self.baseFixtures
        // A group event where one of two invitees cancelled.
        fixtures[Self.inviteesPath("EVT-2")] = (Self.page([
            Self.invitee("bob@example.com", event: "EVT-2"),
            Self.invitee("erin@example.com", event: "EVT-2", status: "canceled")
        ]), 200)
        let session = MockURLSession(fixtures)
        let data = try await makeCollector(session).collect(since: .distantPast, credentials: apiCredentials)

        #expect(data.intMetric("unique_invitees") == 2)  // alice, bob
        #expect(session.requests(path: Self.inviteesPath("EVT-3")).isEmpty,
                "looked up the invitees of a cancelled event")
    }

    @Test("Every page of events is read, not just the first")
    func eventsArePaginated() async throws {
        // Regression: the collector read one page of 100 and stopped, so the
        // live all-time run reported exactly 100 events for an account holding
        // 118 — the page size, presented as a total.
        let page1 = Self.page([
            Self.event("EVT-1", name: "Coffee Chat", type: Self.coffeeType),
            Self.event("EVT-2", name: "Coffee Chat", type: Self.coffeeType)
        ], next: "PAGE-TWO")
        let page2 = Self.page([
            Self.event("EVT-3", name: "Strategy Session", type: Self.strategyType, status: "canceled"),
            Self.event("EVT-4", name: "Strategy Session", type: Self.strategyType)
        ])
        var fixtures: [String: [MockURLSession.Response]] = Self.baseFixtures
            .mapValues { [MockURLSession.Response($0.0, status: $0.1)] }
        fixtures["/scheduled_events"] = [.init(page1), .init(page2)]
        fixtures[Self.inviteesPath("EVT-4")] = [.init(Self.page([Self.invitee("dan@example.com", event: "EVT-4")]))]
        let session = MockURLSession(fixtures)

        let data = try await makeCollector(session).collect(since: .distantPast, credentials: apiCredentials)

        #expect(data.intMetric("events_count")    == 4)
        #expect(data.intMetric("cancelled_count") == 1)
        #expect(data.intMetric("unique_invitees") == 3)

        // Two requests, the second carrying the token and the original query.
        let requests = session.requests(path: "/scheduled_events")
        #expect(requests.count == 2)
        #expect(session.queryValues("page_token", path: "/scheduled_events") == ["PAGE-TWO"])
        #expect(session.queryValues("user", path: "/scheduled_events").count == 2)
        #expect(session.queryValues("sort", path: "/scheduled_events") == ["start_time:desc", "start_time:desc"])
    }

    @Test("Invitee pages are followed too")
    func inviteesArePaginated() async throws {
        var fixtures: [String: [MockURLSession.Response]] = Self.baseFixtures
            .mapValues { [MockURLSession.Response($0.0, status: $0.1)] }
        fixtures[Self.inviteesPath("EVT-2")] = [
            .init(Self.page([Self.invitee("bob@example.com", event: "EVT-2")], next: "INV-TWO")),
            .init(Self.page([Self.invitee("frank@example.com", event: "EVT-2")]))
        ]
        let session = MockURLSession(fixtures)
        let data = try await makeCollector(session).collect(since: .distantPast, credentials: apiCredentials)

        #expect(data.intMetric("unique_invitees") == 3)  // alice, bob, frank
        #expect(session.queryValues("page_token", path: Self.inviteesPath("EVT-2")) == ["INV-TWO"])
    }

    @Test("Past the lookup cap, unique_invitees is omitted rather than undercounted")
    func tooManyEventsOmitsInvitees() async throws {
        // Regression for the shape of the old bug: a plausible zero. Counting
        // people costs a request per event, and past the cap the metric is
        // absent — never a partial count, and never 0.
        let n = CalendlyCollector.maximumInviteeLookups + 1
        let events = Self.page((1...n).map {
            Self.event("EVT-\($0)", name: "Coffee Chat", type: Self.coffeeType)
        })
        let session = MockURLSession([
            "/users/me":         (Self.userJSON, 200),
            "/scheduled_events": (events, 200)
        ])
        let data = try await makeCollector(session).collect(since: .distantPast, credentials: apiCredentials)

        #expect(data.intMetric("events_count") == n)
        #expect(data.intMetric("unique_invitees") == nil)
        #expect(session.requestedURLs.allSatisfy { !$0.path.hasSuffix("/invitees") })
    }

    @Test("At exactly the lookup cap, unique_invitees is still counted")
    func atTheCapInviteesAreCounted() async throws {
        // Pins the boundary: `<=`, not `<`.
        let n = CalendlyCollector.maximumInviteeLookups
        let ids = (1...n).map { "EVT-\($0)" }
        var fixtures: [String: (String, Int)] = [
            "/users/me":         (Self.userJSON, 200),
            "/scheduled_events": (Self.page(ids.map { Self.event($0, name: "Coffee Chat", type: Self.coffeeType) }), 200)
        ]
        for id in ids {
            fixtures[Self.inviteesPath(id)] = (Self.page([Self.invitee("\(id)@example.com", event: id)]), 200)
        }
        let data = try await makeCollector(MockURLSession(fixtures)).collect(since: .distantPast, credentials: apiCredentials)
        #expect(data.intMetric("unique_invitees") == n)
    }

    @Test("A failed invitee lookup omits unique_invitees and keeps the event counts")
    func failedLookupOmitsOnlyInvitees() async throws {
        var fixtures = Self.baseFixtures
        fixtures[Self.inviteesPath("EVT-2")] = ("{}", 429)
        let data = try await makeCollector(MockURLSession(fixtures)).collect(since: .distantPast, credentials: apiCredentials)

        #expect(data.intMetric("events_count") == 3)
        #expect(data.intMetric("cancelled_count") == 1)
        #expect(data.intMetric("unique_invitees") == nil)
        #expect(data.stringMetric("top_event_type_1") == "Coffee Chat")
    }

    @Test("A page token handed back twice is an error, not an endless walk")
    func repeatedPageTokenThrows() async throws {
        let first = Self.page([Self.event("EVT-1", name: "Coffee Chat", type: Self.coffeeType)], next: "TOKEN-A")
        let session = MockURLSession([
            "/users/me":         [MockURLSession.Response(Self.userJSON)],
            // The last entry repeats, so every later page names TOKEN-A again.
            "/scheduled_events": [MockURLSession.Response(first)],
            Self.inviteesPath("EVT-1"): [MockURLSession.Response(Self.page([Self.invitee("a@example.com", event: "EVT-1")]))]
        ])
        await #expect(throws: CollectorError.self) {
            try await makeCollector(session).collect(since: .distantPast, credentials: apiCredentials)
        }
        #expect(session.requests(path: "/scheduled_events").count == 2)
    }

    // MARK: - What goes on the wire
    //
    // This suite had no request assertions at all (#102). Every test above
    // checks what came back, which passes just as happily when the collector
    // asks the wrong question — a window that is never sent, a token that is
    // never attached, a user URI that is dropped. #68 is the standing example:
    // Google Search Console double-encoded its site URL so every request hit a
    // property that could not exist, and the result-level tests were green.

    @Test("Every request carries the token as a Bearer header")
    func requestsAreAuthenticated() async throws {
        // Not "the first request": every endpoint needs it, and a collector that
        // authenticated one and not the other would pass a first-request check.
        let session = makeSession()
        _ = try await makeCollector(session).collect(since: .distantPast, credentials: apiCredentials)

        let paths = Set(session.requestedURLs.map(\.path))
        #expect(paths == ["/users/me", "/scheduled_events",
                          Self.inviteesPath("EVT-1"), Self.inviteesPath("EVT-2")])
        for path in paths {
            #expect(session.headerValues("Authorization", path: path) == ["Bearer test-token"],
                    "missing or wrong Authorization on \(path)")
        }
    }

    @Test("Invitee lookups go to baseURL, not to the URI in the response")
    func inviteeRequestsStayOnBaseURL() async throws {
        // The event URI names a host. Following it would send the token
        // wherever a response says; only the UUID is taken from it.
        let session = MockURLSession(Self.baseFixtures)
        let collector = CalendlyCollector(session: session, baseURL: URL(string: "https://calendly.test")!)
        _ = try await collector.collect(since: .distantPast, credentials: apiCredentials)

        #expect(session.requestedURLs.allSatisfy { $0.host == "calendly.test" })
    }

    @Test("The events request carries the user URI it just looked up")
    func eventsRequestScopesToTheUser() async throws {
        // The whole point of the /users/me round trip. Dropping the parameter
        // asks Calendly for every event it will show us, and the metrics would
        // look plausible.
        let session = makeSession()
        _ = try await makeCollector(session).collect(since: .distantPast, credentials: apiCredentials)

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

        // And the exact instant. The checks above all hold for a value shifted
        // twelve hours inside the same day, which is a different window.
        // Parsed back rather than compared as text, so this pins *when* without
        // pinning *how it is written*.
        let parsed = try #require(ISO8601DateFormatter().date(from: sent))
        #expect(parsed == since)

        // Deliberately the prefix and shape rather than the whole string.
        // Calendly's reference is JavaScript-rendered and could not be read
        // here, so the exact serialisation it wants is unverified — pinning it
        // character for character would cement a guess, which is how the
        // fictional `CTR (%)` header in #107 survived. What is asserted is what
        // can be justified: the right instant, as a UTC date-time.
    }

    @Test("All time means no min_start_time at all, rather than the year 1")
    func noSinceSendsNoWindow() async throws {
        // The negative half. Without it, a collector that always sent some
        // default window would pass the test above.
        let session = makeSession()
        _ = try await makeCollector(session).collect(since: .distantPast, credentials: apiCredentials)

        #expect(session.queryValue("min_start_time", path: "/scheduled_events") == nil)
    }

    @Test("The events URL is built as Calendly expects, escapes and all")
    func eventsURLIsWellFormed() async throws {
        // On absoluteString, which preserves percent-encoding. url.path and
        // queryItems both decode, so an encoding bug is invisible through them —
        // which is exactly how #68 stayed hidden.
        let session = makeSession()
        _ = try await makeCollector(session).collect(since: .distantPast, credentials: apiCredentials)

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
            try await collector.collect(since: .distantPast, credentials: Credentials([:]))
        }
    }
}
