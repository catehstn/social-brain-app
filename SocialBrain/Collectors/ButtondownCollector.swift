import Foundation

/// Collects subscriber and newsletter statistics from Buttondown.
///
/// Required credentials key: `"api_key"`
///
/// Metrics returned:
/// - `subscriber_count`     – total active subscribers
/// - `new_subscribers`      – subscribers added since the `since` date
/// - `emails_sent`          – newsletters sent since `since`
/// - `avg_open_rate`        – mean open rate across those newsletters (0–1)
/// - `avg_click_rate`       – mean click rate across those newsletters (0–1)
struct ButtondownCollector: Collector {
    let platform: Platform = .buttondown
    var instanceName: String = "default"
    private let session: any URLSessionProtocol
    private let baseURL: URL

    init(session: any URLSessionProtocol = URLSession.shared,
         baseURL: URL = URL(string: "https://api.buttondown.email/v1")!) {
        self.session = session
        self.baseURL = baseURL
    }

    func fetchLabel(credentials: Credentials) async -> String? {
        guard let apiKey = credentials.apiKey else { return nil }
        // The /v1/metadata endpoint returns newsletter-level info including the username.
        let url = baseURL.appendingPathComponent("metadata")
        var req = URLRequest(url: url)
        req.setTokenAuth(apiKey)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        struct Metadata: Decodable { let username: String? }
        return try? JSONDecoder().decode(Metadata.self, from: data).username
    }

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
        guard let apiKey = credentials.apiKey else {
            throw CollectorError.missingCredential("api_key")
        }

        async let totalCount = fetchSubscriberCount(apiKey: apiKey)
        async let newCount   = fetchNewSubscriberCount(apiKey: apiKey, since: since)
        async let emailStats = fetchEmailStats(apiKey: apiKey, since: since)

        let (total, new, stats) = try await (totalCount, newCount, emailStats)

        var metrics: [String: MetricValue] = [
            "subscriber_count": .int(total),
            "new_subscribers":  .int(new),
            "emails_sent":      .int(stats.count)
        ]

        // The count above is the API's total; these rates are not, when the
        // window holds more emails than the walk fetched.
        if stats.truncated {
            metrics["emails_sampled"] = .string(
                "open and click rates cover the most recent \(stats.fetched) of \(stats.count) emails")
        }
        // Each average guards its own divisor. Previously both were gated on
        // openRates while avgClick divided by clickRates.count, so an email with
        // an open rate and no click rate produced 0/0 = NaN — which JSONEncoder
        // then refuses, aborting the entire collection run.
        if let avgOpen = stats.openRates.mean {
            metrics["avg_open_rate"] = .double(avgOpen)
        }
        if let avgClick = stats.clickRates.mean {
            metrics["avg_click_rate"] = .double(avgClick)
        }

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

    // MARK: - Private

    private func fetchSubscriberCount(apiKey: String) async throws -> Int {
        // No page-size parameter: Buttondown's reference lists `page` and no
        // `count`, so the `count=1` this used to send was never a request
        // parameter at all. The total is read off the envelope, which carries it
        // regardless of how many rows come back.
        let url = baseURL.appendingPathComponent("subscribers")
        var req = URLRequest(url: url)
        req.setTokenAuth(apiKey)
        let (data, response) = try await session.data(for: req)
        let decoded: PagedResponse<EmptyObject> = try decodeJSON(PagedResponse.self, from: data, response: response)
        return decoded.count
    }

    /// Counts subscribers added since `since`.
    ///
    /// The filter is `date__start`, which Buttondown documents as *"only return
    /// subscribers created on or after the given date"*.
    ///
    /// It used to send `creation_date__gte`, which **does not exist** — the
    /// name appears nowhere in Buttondown's OpenAPI document, and `/subscribers`
    /// has no `creation_date__*` family at all. An unrecognised query parameter
    /// is ignored rather than rejected by default in Django REST Framework, so
    /// the filtered request was very likely the same request as the unfiltered
    /// one, and this returned the *total* subscriber count for every collection
    /// ever run. See #142 — the consequence is unconfirmed without a live key,
    /// but the parameter name is wrong either way.
    private func fetchNewSubscriberCount(apiKey: String, since: Date?) async throws -> Int {
        var items: [URLQueryItem] = []
        if let since {
            items.append(URLQueryItem(name: "date__start", value: iso8601Date(since)))
        }
        var url = baseURL.appendingPathComponent("subscribers")
        if !items.isEmpty { url.append(queryItems: items) }
        var req = URLRequest(url: url)
        req.setTokenAuth(apiKey)
        let (data, response) = try await session.data(for: req)
        let decoded: PagedResponse<EmptyObject> = try decodeJSON(PagedResponse.self, from: data, response: response)
        return decoded.count
    }

    private struct EmailStatsAccumulator {
        /// The API's total, not the number fetched.
        var count: Int = 0
        var openRates: [Double] = []
        var clickRates: [Double] = []
        /// Whether the rates below cover fewer emails than `count`.
        var truncated: Bool = false
        /// How many emails the rates actually cover. Only meaningful when
        /// `truncated`.
        var fetched: Int = 0
    }

    /// How many pages of emails `collect` will walk.
    ///
    /// A window is a handful of newsletters for most people, so this is reached
    /// only on an all-time run against a long archive.
    static let maximumEmailPages = 20

    /// Reads open and click rates over emails published since `since`.
    ///
    /// `publish_date__start` — *"only return emails published after the given
    /// date"*. Note "after", where the subscriber filter says "on or after";
    /// that asymmetry is Buttondown's, not a mistake here.
    ///
    /// It used to send `publish_date__gte`, which does not exist (#142). With
    /// the filter dropped these averages did **not** cover every email ever
    /// sent, which an earlier version of this comment claimed — they covered
    /// the *oldest page*. `/emails` defaults to `ordering=creation_date`,
    /// ascending, and this method reads page one only. So the newsletter
    /// analytics described the beginning of the archive rather than the
    /// requested window, which is a stranger failure than averaging everything
    /// and worth naming precisely.
    private func fetchEmailStats(apiKey: String, since: Date?) async throws -> EmailStatsAccumulator {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var acc = EmailStatsAccumulator()
        var fetched = 0

        for page in 1 ... Self.maximumEmailPages {
            var items = [
                URLQueryItem(name: "page", value: "\(page)"),
                // Newest first. The default is `creation_date` **ascending**, so
                // a read that stops early used to describe the beginning of the
                // archive — the opposite of what a reader wants. With this, a
                // truncated read still covers the most recent newsletters.
                URLQueryItem(name: "ordering", value: "-publish_date")
            ]
            if let since {
                items.append(URLQueryItem(name: "publish_date__start", value: iso8601Date(since)))
            }
            var url = baseURL.appendingPathComponent("emails")
            url.append(queryItems: items)
            var req = URLRequest(url: url)
            req.setTokenAuth(apiKey)

            let (data, response) = try await session.data(for: req)
            let decoded: PagedResponse<ButtondownEmail> = try decodeJSON(
                PagedResponse.self, from: data, response: response, decoder: decoder
            )

            // The envelope's own total, which Buttondown documents as "the total
            // number of results across all pages". This used to report
            // `results.count` — the page — so a busy window came back as exactly
            // one page size, the shape #73 removed from five other collectors.
            acc.count = decoded.count
            fetched += decoded.results.count

            for email in decoded.results {
                if let stats = email.emailStats {
                    if let openRate = stats.openRate { acc.openRates.append(openRate) }
                    if let clickRate = stats.clickRate { acc.clickRates.append(clickRate) }
                }
            }

            // An empty page ends the walk whatever `next` says. Without this a
            // server that keeps offering a next page while returning nothing
            // burns every remaining request and then reports a truncation note
            // over zero emails.
            guard !decoded.results.isEmpty else { return acc }

            // `next` is the URL of the following page — null or absent on the
            // last one; the schema models it as nullable rather than omitted,
            // and `String?` handles both. Used as a signal rather than
            // followed, so the walk never fetches a URL the response supplied.
            guard decoded.next != nil else { return acc }
        }

        // Reaching here means page 20 still offered a next page, so more emails
        // exist by definition. Deliberately not `fetched < acc.count`: that
        // re-derives the answer from a total this suite elsewhere asserts is not
        // trustworthy (see `nextIsTheEndSignal`), and if the total can be wrong
        // in one direction it can be wrong in the other — leaving a genuinely
        // truncated read reporting nothing.
        acc.truncated = true
        acc.fetched = fetched
        return acc
    }
}

// MARK: - Response models

private struct PagedResponse<T: Decodable>: Decodable {
    /// The total across all pages, not the size of this one.
    let count: Int
    let results: [T]
    /// The URL of the next page, absent on the last. Decoded as the end signal;
    /// never requested directly.
    let next: String?
}

private struct EmptyObject: Decodable {}

private struct ButtondownEmail: Decodable {
    let id: String
    let subject: String
    let emailStats: EmailStats?

    struct EmailStats: Decodable {
        let openRate: Double?
        let clickRate: Double?
    }
}

// MARK: - Helpers

private func iso8601Date(_ date: Date) -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withFullDate]
    return fmt.string(from: date)
}

private extension Collection where Element == Double {
    /// The arithmetic mean, or `nil` when empty — so an empty collection can
    /// never yield NaN by dividing by zero.
    var mean: Double? {
        isEmpty ? nil : reduce(0, +) / Double(count)
    }
}
