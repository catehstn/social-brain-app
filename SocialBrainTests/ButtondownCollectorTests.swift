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

    // MARK: - What goes on the wire

    @Test("Every request carries the key as a Token header")
    func requestsAreAuthenticated() async throws {
        // Buttondown uses `Token`, not `Bearer` — a distinction no result-level
        // test can see, and one that a shared helper could silently change for
        // every collector at once.
        //
        // headerValues, not headerValue: /v1/subscribers is requested twice
        // concurrently under `async let`, so "the first" is nondeterministic.
        let session = MockURLSession([
            "/v1/subscribers": (Self.subscribersJSON, 200),
            "/v1/emails":      (Self.emailsJSON, 200)
        ])
        let collector = ButtondownCollector(
            session: session,
            baseURL: URL(string: "https://api.buttondown.email/v1")!
        )
        _ = try await collector.collect(since: nil, credentials: Credentials(["api_key": "test-key"]))

        let paths = Set(session.requestedURLs.map(\.path))
        #expect(paths == ["/v1/subscribers", "/v1/emails"])
        for path in paths {
            let values = session.headerValues("Authorization", path: path)
            #expect(!values.isEmpty, "no Authorization on \(path)")
            #expect(values.allSatisfy { $0 == "Token test-key" },
                    "wrong Authorization on \(path): \(values)")
        }
        // Both /v1/subscribers requests, not just whichever `async let` won.
        // allSatisfy over a one-element array is true, so authenticating one of
        // the two and dropping the other passed everything above — the exact
        // partial-auth gap this suite pins for Mastodon and Bluesky, missed on
        // the one collector that actually requests a path twice.
        #expect(session.headerValues("Authorization", path: "/v1/subscribers").count == 2)
        for url in session.requestedURLs {
            #expect(!url.absoluteString.contains("%25"), "double-encoded: \(url)")
        }
    }

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
    @Test("since is sent as a documented date filter on both endpoints")
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
        // Assert the value, not just the parameter's presence: sending the right
        // parameter name with a wrong or misformatted date is the more likely bug,
        // and a presence check passes straight through it.
        #expect(session.requests(path: "/v1/subscribers").count == 2)
        // The names Buttondown actually documents. These assertions used to pin
        // creation_date__gte and publish_date__gte, which appear nowhere in its
        // OpenAPI document — so the suite was holding a bug in place rather than
        // catching it (#142).
        #expect(session.queryValues("date__start", path: "/v1/subscribers") == ["2026-01-01"])
        #expect(session.queryValues("publish_date__start", path: "/v1/emails") == ["2026-01-01"])

        // And the old names are gone, not merely joined by the new ones.
        #expect(session.queryValues("creation_date__gte", path: "/v1/subscribers").isEmpty)
        #expect(session.queryValues("publish_date__gte", path: "/v1/emails").isEmpty)
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

        #expect(session.queryValues("date__start", path: "/v1/subscribers").isEmpty)
        #expect(session.queryValues("publish_date__start", path: "/v1/emails").isEmpty)
    }

    @Test("Only documented query parameters are sent")
    func onlyDocumentedParametersAreSent() async throws {
        // The generalisation of #142. Buttondown's reference lists `page` and no
        // page-size parameter, so the `count=1` this collector used to send on
        // both subscriber requests was never a parameter — it was ignored, and
        // the total was read off the response envelope regardless.
        //
        // An unrecognised parameter is not harmless when it is a *filter*: it is
        // silently dropped, and the request comes back unfiltered while looking
        // like it was filtered. That is the whole of #142.
        let session = MockURLSession([
            "/v1/subscribers": (Self.subscribersJSON, 200),
            "/v1/emails":      (Self.emailsJSON, 200)
        ])
        let collector = ButtondownCollector(
            session: session,
            baseURL: URL(string: "https://api.buttondown.email/v1")!
        )
        _ = try await collector.collect(
            since: Date(timeIntervalSince1970: 1_767_225_600),
            credentials: Credentials(["api_key": "k"])
        )

        // Per path, not one global set. `date__start` is documented on
        // /subscribers and *not* on /emails, and vice versa for
        // publish_date__start — so a single allowlist would accept either
        // parameter on either endpoint. Probed: sending date__start to /emails
        // passed a global check.
        let documented: [String: Set<String>] = [
            "/v1/subscribers": ["date__start", "page"],
            "/v1/emails":      ["publish_date__start", "page"]
        ]
        // Guards the loop: an empty requestedURLs would satisfy every assertion
        // inside it.
        #expect(session.requestedURLs.count == 3)
        for url in session.requestedURLs {
            let allowed = try #require(documented[url.path], "unexpected path \(url.path)")
            let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.map(\.name) ?? []
            #expect(Set(names).isSubset(of: allowed), "undocumented parameter in \(url)")
        }
    }

    @Test("An email with an open rate but no click rate does not produce NaN")
    func openRateWithoutClickRateIsNotNaN() async throws {
        // The exact shape that aborted every collection run: the guard checked
        // openRates while the divisor was clickRates.count, so 0/0 = NaN, and
        // JSONEncoder refuses NaN when the snapshot is persisted.
        // open_rate present, click_rate absent — Buttondown omits click_rate for
        // an email containing no links.
        let emails = """
            {
              "count": 1,
              "next": null,
              "previous": null,
              "results": [
                { "id": "e1", "subject": "No links", "email_stats": { "open_rate": 0.45 } }
              ]
            }
            """
        let session = MockURLSession([
            "/v1/subscribers": (ButtondownCollectorTests.subscribersJSON, 200),
            "/v1/emails":      (emails, 200)
        ])
        let collector = ButtondownCollector(
            session: session,
            baseURL: URL(string: "https://api.buttondown.email/v1")!
        )

        let data = try await collector.collect(since: nil, credentials: Credentials(["api_key": "k"]))

        for (key, value) in data.metrics {
            if case .double(let d) = value {
                #expect(!d.isNaN, "\(key) is NaN")
                #expect(d.isFinite, "\(key) is not finite")
            }
        }
        // The metric is omitted rather than reported as zero: no clicks were
        // measured, which is not the same as a zero click rate.
        #expect(data.metrics["avg_click_rate"] == nil)
    }

    @Test("Metrics survive JSON encoding, which is what a NaN breaks")
    func metricsAreEncodable() async throws {
        // open_rate present, click_rate absent — Buttondown omits click_rate for
        // an email containing no links.
        let emails = """
            {
              "count": 1,
              "next": null,
              "previous": null,
              "results": [
                { "id": "e1", "subject": "No links", "email_stats": { "open_rate": 0.45 } }
              ]
            }
            """
        let session = MockURLSession([
            "/v1/subscribers": (ButtondownCollectorTests.subscribersJSON, 200),
            "/v1/emails":      (emails, 200)
        ])
        let collector = ButtondownCollector(
            session: session,
            baseURL: URL(string: "https://api.buttondown.email/v1")!
        )

        let data = try await collector.collect(since: nil, credentials: Credentials(["api_key": "k"]))

        // Asserting !isNaN alone would not catch a different unencodable value;
        // this is the operation that actually failed in production.
        #expect(throws: Never.self) {
            _ = try JSONEncoder().encode(data.metrics)
        }
    }

}
