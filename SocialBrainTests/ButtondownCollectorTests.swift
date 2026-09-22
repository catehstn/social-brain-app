import Testing
import Foundation
@testable import SocialBrain

@Suite("Buttondown Collector Tests")
struct ButtondownCollectorTests {

    // MARK: - Fixtures

    // Shapes captured from the live API on 2026-09-22: field names, nesting and
    // types are Buttondown's. Every string is invented (allowlist redaction —
    // see CLAUDE.md), and rows are trimmed to a representative subset of their
    // fields; the collector reads only the envelope's `count` and `next`, and
    // each email's `analytics`.

    /// The envelope keys are in Buttondown's order. A real `results` row carries
    /// ~50 fields of subscriber data; the collector reads none of them.
    private static let subscribersJSON = """
    {
      "results": [
        {
          "id": "00000000-0000-4000-8000-000000000001",
          "creation_date": "2026-01-02T10:00:00.000000Z",
          "email_address": "reader@example.com",
          "type": "regular",
          "source": "form",
          "tags": [],
          "metadata": {},
          "open_rate": null,
          "click_rate": null,
          "delivered_count": 3,
          "open_count": 2,
          "clicked_count": 1
        }
      ],
      "next": "https://api.buttondown.email/v1/subscribers?page=2",
      "previous": null,
      "count": 91
    }
    """

    /// One email's `analytics` object, every field the live response carries.
    private static func analytics(
        recipients: Int, deliveries: Int, opens: Int, clicks: Int
    ) -> String {
        """
        {
          "recipients": \(recipients), "deliveries": \(deliveries),
          "opens": \(opens), "clicks": \(clicks),
          "temporary_failures": \(recipients - deliveries), "permanent_failures": 0,
          "unsubscriptions": 0, "complaints": 0, "survey_responses": 0,
          "webmentions": 0, "page_views_lifetime": 0, "page_views_30": 0,
          "page_views_7": 0, "subscriptions": 1, "paid_subscriptions": 0,
          "replies": 0, "comments": 0, "social_mentions": 0,
          "temporary_failure_breakdown": [], "permanent_failure_breakdown": []
        }
        """
    }

    private static func email(id: Int, analytics: String) -> String {
        """
        {
          "id": "00000000-0000-4000-8000-00000000010\(id)",
          "creation_date": "2026-0\(id)-01T09:00:00.000000Z",
          "absolute_url": "https://example.com/archive/issue-\(id)/",
          "analytics": \(analytics),
          "body": "Body \(id)",
          "canonical_url": "",
          "commenting_mode": "enabled",
          "description": "",
          "email_type": "public",
          "featured": false,
          "filters": { "filters": [], "groups": [], "predicate": "and" },
          "metadata": {},
          "publish_date": "2026-0\(id)-02T10:30:00Z",
          "secondary_id": \(id),
          "slug": "issue-\(id)",
          "source": "app",
          "status": "sent",
          "subject": "Issue \(id)",
          "suppression_reason": null,
          "template": null
        }
        """
    }

    /// Three sent emails. Rates are opens and clicks over **deliveries**:
    ///
    /// - 1: 60/100 opened, 20/100 clicked — and 103 recipients, so an
    ///   opens-over-recipients rate would read 0.583, not 0.6
    /// - 2: 20/50 opened, 5/50 clicked
    /// - 3: 0 opens against 2 clicks — open tracking was off (a click without
    ///   an open cannot happen when it is on), so no open rate, but a click rate
    ///   of 2/40. The live archive has one of these.
    ///
    /// avg_open_rate = (0.6 + 0.4) / 2 = 0.5
    /// avg_click_rate = (0.2 + 0.1 + 0.05) / 3 ≈ 0.11667
    private static let emailsJSON = """
    {
      "results": [
        \(email(id: 3, analytics: analytics(recipients: 40, deliveries: 40, opens: 0, clicks: 2))),
        \(email(id: 2, analytics: analytics(recipients: 50, deliveries: 50, opens: 20, clicks: 5))),
        \(email(id: 1, analytics: analytics(recipients: 103, deliveries: 100, opens: 60, clicks: 20)))
      ],
      "next": null,
      "previous": null,
      "count": 3
    }
    """

    /// `/v1/newsletters` — every newsletter on the account, each with its own
    /// `api_key`. A real row carries ~60 fields of settings and templates.
    private static let newslettersJSON = """
    {
      "results": [
        {
          "id": "00000000-0000-4000-8000-000000000201",
          "creation_date": "2025-01-01T00:00:00.000000Z",
          "api_key": "other-newsletter-key",
          "description": "",
          "domain": "",
          "email_address": "",
          "enabled_features": [],
          "from_name": "",
          "metadata": {},
          "name": "Other Newsletter",
          "test_mode": false,
          "username": "other"
        },
        {
          "id": "00000000-0000-4000-8000-000000000202",
          "creation_date": "2025-01-01T00:00:00.000000Z",
          "api_key": "test-key",
          "description": "",
          "domain": "",
          "email_address": "",
          "enabled_features": [],
          "from_name": "",
          "metadata": {},
          "name": "Example Letters",
          "test_mode": false,
          "username": "exampleletters"
        }
      ],
      "next": null,
      "previous": null,
      "count": 2
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
        _ = try await collector.collect(since: .distantPast, credentials: Credentials(["api_key": "test-key"]))

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
        let data = try await collector.collect(since: .distantPast, credentials: credentials)

        #expect(data.platform == .buttondown)
        #expect(data.intMetric("subscriber_count") == 91)
        #expect(data.intMetric("emails_sent") == 3)

        // Per-email stats live in `analytics` as counts. The collector used to
        // decode an `email_stats` object with `open_rate` / `click_rate`, which
        // the live API does not send, so neither rate ever appeared — across
        // nine real sent emails. See `emailsJSON` for the arithmetic.
        let avgOpen = try #require(data.doubleMetric("avg_open_rate"))
        #expect(abs(avgOpen - 0.5) < 0.0001)
        let avgClick = try #require(data.doubleMetric("avg_click_rate"))
        #expect(abs(avgClick - 0.35 / 3) < 0.0001)
    }

    @Test("An email with no opens has no open rate, rather than a rate of zero")
    func zeroOpensIsNotAnOpenRate() async throws {
        // Live: one sent email reports 0 opens against 48 deliveries and 1
        // click. A click without an open means open tracking was not recording,
        // so 0% is a plausible-looking number that describes nothing — and
        // averaged in, it drags every all-time open rate down.
        let emails = """
            {"results": [\(Self.email(id: 1, analytics: Self.analytics(
                recipients: 48, deliveries: 48, opens: 0, clicks: 1)))],
             "next": null, "previous": null, "count": 1}
            """
        let session = MockURLSession([
            "/v1/subscribers": (Self.subscribersJSON, 200),
            "/v1/emails":      (emails, 200)
        ])
        let data = try await ButtondownCollector(session: session)
            .collect(since: .distantPast, credentials: Credentials(["api_key": "k"]))

        #expect(data.metrics["avg_open_rate"] == nil)
        let click = try #require(data.doubleMetric("avg_click_rate"))
        #expect(abs(click - 1.0 / 48) < 0.0001)
    }

    @Test("An email with no deliveries contributes no rates")
    func noDeliveriesContributesNothing() async throws {
        // `analytics` is documented as null until an email is sent, and a sent
        // email can still have zero deliveries. Neither has a rate; both still
        // count towards emails_sent.
        let emails = """
            {"results": [
               \(Self.email(id: 1, analytics: "null")),
               \(Self.email(id: 2, analytics: Self.analytics(
                   recipients: 3, deliveries: 0, opens: 0, clicks: 0)))
             ],
             "next": null, "previous": null, "count": 2}
            """
        let session = MockURLSession([
            "/v1/subscribers": (Self.subscribersJSON, 200),
            "/v1/emails":      (emails, 200)
        ])
        let data = try await ButtondownCollector(session: session)
            .collect(since: .distantPast, credentials: Credentials(["api_key": "k"]))

        #expect(data.intMetric("emails_sent") == 2)
        #expect(data.metrics["avg_open_rate"] == nil)
        #expect(data.metrics["avg_click_rate"] == nil)
    }

    @Test("Subscriber counts cover active subscribers, not every record")
    func subscriberCountsAreFilteredToActiveTypes() async throws {
        // Unfiltered, /v1/subscribers counts unconfirmed and unsubscribed
        // records too: live, 112 against 91 regular (15 unactivated, 6
        // unsubscribed). The doc comment always said "active"; the request
        // never did.
        let session = MockURLSession([
            "/v1/subscribers": (Self.subscribersJSON, 200),
            "/v1/emails":      (Self.emailsJSON, 200)
        ])
        _ = try await ButtondownCollector(session: session).collect(
            since: Date(timeIntervalSince1970: 1_767_225_600),
            credentials: Credentials(["api_key": "k"])
        )

        let requests = session.requests(path: "/v1/subscribers")
        #expect(requests.count == 2)
        // Both requests — the total and the new count — so `new_subscribers`
        // can never exceed `subscriber_count` by counting people who have since
        // left.
        for request in requests {
            let url = try #require(request.url)
            let types = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.filter { $0.name == "type" }.compactMap(\.value) ?? []
            #expect(Set(types) == ["regular", "premium", "churning", "gifted", "trialed", "past_due"],
                    "\(url)")
        }
    }

    @Test("Only sent emails are counted")
    func onlySentEmailsAreRequested() async throws {
        // `/v1/emails` returns drafts and scheduled emails too unless filtered,
        // and an all-time run sends no date filter to exclude them.
        let session = MockURLSession([
            "/v1/subscribers": (Self.subscribersJSON, 200),
            "/v1/emails":      (Self.emailsJSON, 200)
        ])
        _ = try await ButtondownCollector(session: session)
            .collect(since: .distantPast, credentials: Credentials(["api_key": "k"]))

        #expect(session.queryValues("status", path: "/v1/emails") == ["sent"])
    }

    // MARK: - Label

    @Test("The label is the name of the newsletter this key belongs to")
    func labelIsTheKeysNewsletterName() async throws {
        // It used to read `username` off /v1/metadata, which is a 404 on the
        // live API — so every Buttondown instance went unlabelled. The key is
        // per newsletter and /v1/newsletters lists every newsletter on the
        // account, so the one whose `api_key` matches is this one.
        let session = MockURLSession(["/v1/newsletters": (Self.newslettersJSON, 200)])
        let label = await ButtondownCollector(session: session)
            .fetchLabel(credentials: Credentials(["api_key": "test-key"]))

        #expect(label == "Example Letters")
        #expect(session.headerValues("Authorization", path: "/v1/newsletters") == ["Token test-key"])
    }

    @Test("No label when no newsletter matches the key")
    func noLabelWithoutAMatch() async throws {
        // Not the first newsletter: on a multi-newsletter account that would
        // label every instance with the same, usually wrong, name.
        let session = MockURLSession(["/v1/newsletters": (Self.newslettersJSON, 200)])
        let label = await ButtondownCollector(session: session)
            .fetchLabel(credentials: Credentials(["api_key": "unknown-key"]))

        #expect(label == nil)
    }

    @Test("No label on an error response")
    func noLabelOnError() async throws {
        let session = MockURLSession(["/v1/newsletters": ("{\"detail\": \"Invalid token\"}", 401)])
        let label = await ButtondownCollector(session: session)
            .fetchLabel(credentials: Credentials(["api_key": "test-key"]))

        #expect(label == nil)
    }

    @Test("Throws missingCredential when api_key is absent")
    func missingAPIKey() async throws {
        let collector = ButtondownCollector()
        let credentials = Credentials([:])
        await #expect(throws: CollectorError.self) {
            try await collector.collect(since: .distantPast, credentials: credentials)
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
            try await collector.collect(since: .distantPast, credentials: credentials)
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

    @Test("All time means no date filter is sent, rather than the year 1")
    func allTimeMeansNoFilter() async throws {
        // `since` is required now, so this used to be `nil` and is
        // `.distantPast` (#96). For an API whose date filter can simply be
        // omitted, omitting it *is* the encoding of "no lower bound" — and it
        // keeps 0001-01-01 off the wire, which is the untested extreme that
        // made GoatCounter fail outright in #154.
        let session = MockURLSession([
            "/v1/subscribers": (ButtondownCollectorTests.subscribersJSON, 200),
            "/v1/emails":      (ButtondownCollectorTests.emailsJSON, 200)
        ])
        let collector = ButtondownCollector(
            session: session,
            baseURL: URL(string: "https://api.buttondown.email/v1")!
        )

        _ = try await collector.collect(since: .distantPast, credentials: Credentials(["api_key": "k"]))

        #expect(session.queryValues("date__start", path: "/v1/subscribers").isEmpty)
        #expect(session.queryValues("publish_date__start", path: "/v1/emails").isEmpty)
    }

    // MARK: - Email pagination

    private static func emailPage(
        count: Int, rows: Int, next: String?, openRate: Double
    ) -> String {
        // Over 100 deliveries, so `openRate` is exactly opens / deliveries.
        let results = (0..<rows).map { _ in
            email(id: 1, analytics: analytics(
                recipients: 100, deliveries: 100, opens: Int((openRate * 100).rounded()), clicks: 10))
        }
        let nextField = next.map { "\"\($0)\"" } ?? "null"
        return """
        {"count":\(count),"next":\(nextField),"previous":null,
         "results":[\(results.joined(separator: ","))]}
        """
    }

    private func paginatingSession(_ pages: [MockURLSession.Response]) -> MockURLSession {
        MockURLSession([
            "/v1/subscribers": [.init(Self.subscribersJSON)],
            "/v1/emails": pages
        ])
    }

    private func makePaginatingCollector(_ session: MockURLSession) -> ButtondownCollector {
        ButtondownCollector(session: session, baseURL: URL(string: "https://api.buttondown.email/v1")!)
    }

    @Test("Follows next to every page of emails")
    func walksEveryEmailPage() async throws {
        // One page was read and its length reported, so a busy window came back
        // as exactly one page size — the shape #73 removed from five other
        // collectors, still here because this one reads a count off an envelope
        // rather than counting rows itself.
        let session = paginatingSession([
            .init(Self.emailPage(count: 5, rows: 2, next: "…?page=2", openRate: 0.4)),
            .init(Self.emailPage(count: 5, rows: 2, next: "…?page=3", openRate: 0.6)),
            .init(Self.emailPage(count: 5, rows: 1, next: nil, openRate: 0.5))
        ])
        let data = try await makePaginatingCollector(session)
            .collect(since: .distantPast, credentials: Credentials(["api_key": "k"]))

        #expect(session.requests(path: "/v1/emails").count == 3)
        #expect(data.intMetric("emails_sent") == 5)
        // Averaged across all five, not the two on page one.
        let open = try #require(data.doubleMetric("avg_open_rate"))
        #expect(abs(open - 0.5) < 0.0001)
        #expect(data.metrics["emails_sampled"] == nil)
    }

    @Test("Asks for each page in turn, newest first")
    func sendsPageAndOrdering() async throws {
        let session = paginatingSession([
            .init(Self.emailPage(count: 3, rows: 2, next: "…?page=2", openRate: 0.4)),
            .init(Self.emailPage(count: 3, rows: 1, next: nil, openRate: 0.4))
        ])
        _ = try await makePaginatingCollector(session)
            .collect(since: .distantPast, credentials: Credentials(["api_key": "k"]))

        #expect(session.queryValues("page", path: "/v1/emails") == ["1", "2"])
        // Newest first. The API default is creation_date ascending, so a
        // truncated read would otherwise describe the oldest newsletters.
        #expect(session.queryValues("ordering", path: "/v1/emails") == ["-publish_date", "-publish_date"])
    }

    @Test("An absent next ends the walk even when the count says otherwise")
    func nextIsTheEndSignal() async throws {
        // count is the API's total across all pages and is not a reliable
        // continuation signal on its own — a filtered query can report a total
        // larger than what it will serve. `next` is what Buttondown documents
        // as "the URL to the next page of results, if any".
        let session = paginatingSession([
            .init(Self.emailPage(count: 99, rows: 2, next: nil, openRate: 0.4))
        ])
        let data = try await makePaginatingCollector(session)
            .collect(since: .distantPast, credentials: Credentials(["api_key": "k"]))

        #expect(session.requests(path: "/v1/emails").count == 1)
        #expect(data.intMetric("emails_sent") == 99)
    }

    @Test("The date filter is sent on every page, not just the first")
    func filterIsSentOnEveryPage() async throws {
        // #142 was a filter silently dropped, so a filter dropped on pages 2+
        // is the same bug wearing a smaller hat — and every existing `since`
        // test uses a single-page fixture, so nothing caught it. Probed:
        // `if let since, page == 1` left the whole suite green.
        let session = paginatingSession([
            .init(Self.emailPage(count: 3, rows: 2, next: "…?page=2", openRate: 0.4)),
            .init(Self.emailPage(count: 3, rows: 1, next: nil, openRate: 0.4))
        ])
        _ = try await makePaginatingCollector(session).collect(
            since: Date(timeIntervalSince1970: 1_767_225_600),
            credentials: Credentials(["api_key": "k"])
        )

        #expect(session.requests(path: "/v1/emails").count == 2)
        #expect(session.queryValues("publish_date__start", path: "/v1/emails")
                == ["2026-01-01", "2026-01-01"])
    }

    @Test("An empty page ends the walk whatever next says")
    func emptyPageEndsTheWalk() async throws {
        // A server offering a next page while returning nothing would otherwise
        // burn every remaining request and then report a truncation note over
        // no emails at all.
        let session = paginatingSession([
            .init(Self.emailPage(count: 9, rows: 2, next: "…?page=2", openRate: 0.4)),
            .init(Self.emailPage(count: 9, rows: 0, next: "…?page=3", openRate: 0.4))
        ])
        let data = try await makePaginatingCollector(session)
            .collect(since: .distantPast, credentials: Credentials(["api_key": "k"]))

        #expect(session.requests(path: "/v1/emails").count == 2)
        #expect(data.metrics["emails_sampled"] == nil)
    }

    @Test("Hitting the page cap is reported, not hidden")
    func emailTruncationIsReported() async throws {
        let session = paginatingSession([
            .init(Self.emailPage(count: 500, rows: 2, next: "…?page=n", openRate: 0.4))
        ])
        let data = try await makePaginatingCollector(session)
            .collect(since: .distantPast, credentials: Credentials(["api_key": "k"]))

        #expect(session.requests(path: "/v1/emails").count == ButtondownCollector.maximumEmailPages)
        let note = try #require(data.stringMetric("emails_sampled"))
        #expect(note.contains("500"))
        // Emails, not pages. "the most recent 20 pages" is uninterpretable
        // without knowing the page size, and /emails documents no page-size
        // parameter at all — so the reader could not work it out.
        #expect(note.contains("40"), "should name emails covered, not pages: \(note)")
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
            "/v1/subscribers": ["date__start", "page", "type"],
            "/v1/emails":      ["publish_date__start", "page", "ordering", "status"]
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

    /// The one asymmetric shape the live API produces: clicks measured, opens
    /// not (open tracking off), so the two averages have different divisors.
    private static let clickWithoutOpenJSON = """
        {"results": [\(email(id: 1, analytics: analytics(
            recipients: 48, deliveries: 48, opens: 0, clicks: 1)))],
         "next": null, "previous": null, "count": 1}
        """

    @Test("An email with a click rate but no open rate does not produce NaN")
    func clickRateWithoutOpenRateIsNotNaN() async throws {
        // The shape that once aborted every collection run: one guard covered
        // both averages while each divided by its own count, so 0/0 = NaN, and
        // JSONEncoder refuses NaN when the snapshot is persisted. The fixture
        // was open-without-click under the old `email_stats` shape; against
        // the real `analytics` counts the one-sided case is the reverse.
        let session = MockURLSession([
            "/v1/subscribers": (ButtondownCollectorTests.subscribersJSON, 200),
            "/v1/emails":      (Self.clickWithoutOpenJSON, 200)
        ])
        let collector = ButtondownCollector(
            session: session,
            baseURL: URL(string: "https://api.buttondown.email/v1")!
        )

        let data = try await collector.collect(since: .distantPast, credentials: Credentials(["api_key": "k"]))

        for (key, value) in data.metrics {
            if case .double(let d) = value {
                #expect(!d.isNaN, "\(key) is NaN")
                #expect(d.isFinite, "\(key) is not finite")
            }
        }
        // Omitted rather than reported as zero: no opens were measured, which
        // is not the same as a zero open rate.
        #expect(data.metrics["avg_open_rate"] == nil)
        #expect(data.doubleMetric("avg_click_rate") != nil)
    }

    @Test("Metrics survive JSON encoding, which is what a NaN breaks")
    func metricsAreEncodable() async throws {
        let session = MockURLSession([
            "/v1/subscribers": (ButtondownCollectorTests.subscribersJSON, 200),
            "/v1/emails":      (Self.clickWithoutOpenJSON, 200)
        ])
        let collector = ButtondownCollector(
            session: session,
            baseURL: URL(string: "https://api.buttondown.email/v1")!
        )

        let data = try await collector.collect(since: .distantPast, credentials: Credentials(["api_key": "k"]))

        // Asserting !isNaN alone would not catch a different unencodable value;
        // this is the operation that actually failed in production.
        #expect(throws: Never.self) {
            _ = try JSONEncoder().encode(data.metrics)
        }
    }

}
