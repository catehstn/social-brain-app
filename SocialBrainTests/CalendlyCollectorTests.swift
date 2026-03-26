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

    @Test("Throws missingCredential when api_key is absent")
    func missingAPIKey() async throws {
        let collector = CalendlyCollector()
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: nil, credentials: Credentials([:]))
        }
    }
}
