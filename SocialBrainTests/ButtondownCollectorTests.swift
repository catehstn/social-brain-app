import Testing
import Foundation
@testable import SocialBrain

@Suite("Buttondown Collector Tests")
struct ButtondownCollectorTests {

    // MARK: - Fixtures

    private static let subscribersJSON = """
    {
      "count": 1500,
      "next": null,
      "previous": null,
      "results": []
    }
    """

    private static let newSubscribersJSON = """
    {
      "count": 42,
      "next": null,
      "previous": null,
      "results": []
    }
    """

    private static let emailsJSON = """
    {
      "count": 3,
      "next": null,
      "previous": null,
      "results": [
        {
          "id": "abc123",
          "subject": "Issue 10",
          "email_stats": { "open_rate": 0.45, "click_rate": 0.12 }
        },
        {
          "id": "abc124",
          "subject": "Issue 11",
          "email_stats": { "open_rate": 0.50, "click_rate": 0.10 }
        },
        {
          "id": "abc125",
          "subject": "Issue 12",
          "email_stats": null
        }
      ]
    }
    """

    // MARK: - Tests

    @Test("Parses subscriber count and email stats correctly")
    func collectBasicMetrics() async throws {
        let session = MockURLSession([
            "/v1/subscribers": (ButtondownCollectorTests.subscribersJSON, 200),
            "/v1/emails":      (ButtondownCollectorTests.emailsJSON, 200)
        ])
        // Both /subscribers calls return the same response for this test.
        let collector = ButtondownCollector(
            session: session,
            baseURL: URL(string: "https://api.buttondown.email/v1")!
        )
        let credentials = Credentials(["api_key": "test-key"])
        let data = try await collector.collect(since: nil, credentials: credentials)

        #expect(data.platform == .buttondown)
        #expect(data.intMetric("subscriber_count") == 1500)
        #expect(data.intMetric("emails_sent") == 3)

        // avg_open_rate should be (0.45 + 0.50) / 2 = 0.475
        if let avgOpen = data.doubleMetric("avg_open_rate") {
            #expect(abs(avgOpen - 0.475) < 0.001)
        } else {
            Issue.record("avg_open_rate metric is missing")
        }

        // avg_click_rate should be (0.12 + 0.10) / 2 = 0.11
        if let avgClick = data.doubleMetric("avg_click_rate") {
            #expect(abs(avgClick - 0.11) < 0.001)
        } else {
            Issue.record("avg_click_rate metric is missing")
        }
    }

    @Test("Throws missingCredential when api_key is absent")
    func missingAPIKey() async throws {
        let collector = ButtondownCollector()
        let credentials = Credentials([:])
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: nil, credentials: credentials)
        }
    }

    @Test("Propagates HTTP 401 as a CollectorError")
    func unauthorizedResponse() async throws {
        let session = MockURLSession([
            "/v1/subscribers": ("{\"detail\": \"Invalid token\"}", 401)
        ])
        let collector = ButtondownCollector(
            session: session,
            baseURL: URL(string: "https://api.buttondown.email/v1")!
        )
        let credentials = Credentials(["api_key": "bad-key"])
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: nil, credentials: credentials)
        }
    }
    @Test("since is sent as a __gte filter on both endpoints")
    func sinceIsSentInTheQuery() async throws {
        // Path matching alone cannot see this: the collector could omit `since`
        // entirely, or send it on the wrong parameter, and every existing
        // assertion would still pass.
        let session = MockURLSession([
            "/v1/subscribers": (ButtondownCollectorTests.subscribersJSON, 200),
            "/v1/emails":      (ButtondownCollectorTests.emailsJSON, 200)
        ])
        let collector = ButtondownCollector(
            session: session,
            baseURL: URL(string: "https://api.buttondown.email/v1")!
        )
        let since = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01

        _ = try await collector.collect(since: since, credentials: Credentials(["api_key": "k"]))

        // /v1/subscribers is requested twice — total count with no filter, and
        // new-subscriber count with one — so assert across all of them.
        #expect(session.requests(path: "/v1/subscribers").count == 2)
        #expect(!session.queryValues("creation_date__gte", path: "/v1/subscribers").isEmpty)
        #expect(!session.queryValues("publish_date__gte", path: "/v1/emails").isEmpty)
    }

    @Test("No since means no date filter is sent")
    func noSinceMeansNoFilter() async throws {
        let session = MockURLSession([
            "/v1/subscribers": (ButtondownCollectorTests.subscribersJSON, 200),
            "/v1/emails":      (ButtondownCollectorTests.emailsJSON, 200)
        ])
        let collector = ButtondownCollector(
            session: session,
            baseURL: URL(string: "https://api.buttondown.email/v1")!
        )

        _ = try await collector.collect(since: nil, credentials: Credentials(["api_key": "k"]))

        #expect(session.queryValues("creation_date__gte", path: "/v1/subscribers").isEmpty)
        #expect(session.queryValues("publish_date__gte", path: "/v1/emails").isEmpty)
    }

}
