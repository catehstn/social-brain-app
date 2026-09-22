import Foundation

/// Collects subscriber and newsletter statistics from Buttondown.
///
/// Required credentials key: `"api_key"`
///
/// Metrics returned:
/// - `subscriber_count`     – active subscribers (see `activeSubscriberTypes`)
/// - `new_subscribers`      – active subscribers created since the `since` date
/// - `emails_sent`          – newsletters sent since `since`
/// - `avg_open_rate`        – mean per-email unique opens / deliveries (0–1),
///                            over emails with any opens recorded
/// - `avg_click_rate`       – mean per-email unique clicks / deliveries (0–1)
/// - `emails_sampled`       – a note, only when the email walk hit its page cap
///
/// Response shapes were checked against the live API on 2026-09-22 (#75).
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

    /// The name of the newsletter this key belongs to.
    ///
    /// Buttondown API keys are per newsletter, and `/v1/newsletters` lists
    /// every newsletter on the account with its own `api_key` — so the row
    /// whose key matches is this instance. This used to read `username` off
    /// `/v1/metadata`, which is a 404 on the live API, so the label was always
    /// nil. Only the first page is read; the live account has three
    /// newsletters, well inside one page.
    func fetchLabel(credentials: Credentials) async -> String? {
        guard let apiKey = credentials.apiKey else { return nil }
        var req = URLRequest(url: baseURL.appendingPathComponent("newsletters"))
        req.setTokenAuth(apiKey)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        struct Newsletter: Decodable {
            let name: String?
            let username: String?
            let apiKey: String?
            enum CodingKeys: String, CodingKey {
                case name, username
                case apiKey = "api_key"
            }
        }
        guard let page = try? JSONDecoder().decode(PagedResponse<Newsletter>.self, from: data),
              let mine = page.results.first(where: { $0.apiKey == apiKey })
        else { return nil }
        return [mine.name, mine.username].compactMap { $0 }.first { !$0.isEmpty }
    }

    func collect(since: Date, credentials: Credentials) async throws -> PlatformData {
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

    /// The subscriber types counted as active: those receiving the newsletter.
    ///
    /// Unfiltered, `/v1/subscribers` counts every record, including
    /// `unactivated` (never confirmed) and `unsubscribed`. Live on 2026-09-22
    /// that was 112 records against 91 `regular`, so `subscriber_count` — whose
    /// doc always said "active" — overstated the list by 23%. Repeated `type`
    /// parameters are OR'd (checked live: `type=regular&type=unactivated`
    /// returned their sum). Which of the rarer types receive email is inferred
    /// from their names; only `regular` has been seen on a real account.
    static let activeSubscriberTypes = ["regular", "premium", "churning", "gifted", "trialed", "past_due"]

    private var activeTypeItems: [URLQueryItem] {
        Self.activeSubscriberTypes.map { URLQueryItem(name: "type", value: $0) }
    }

    private func fetchSubscriberCount(apiKey: String) async throws -> Int {
        // No page-size parameter: Buttondown's reference lists `page` and no
        // `count`, so the `count=1` this used to send was never a request
        // parameter at all. The total is read off the envelope, which carries it
        // regardless of how many rows come back — and is the *filtered* total
        // (live: `date__start=2099-01-01` gives `count: 0`).
        var url = baseURL.appendingPathComponent("subscribers")
        url.append(queryItems: activeTypeItems)
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
    /// ever run (#142). `date__start` is honoured: live on 2026-09-22 it
    /// returned 4 for a 30-day window against 112 unfiltered, while an unknown
    /// parameter returned the unfiltered 112.
    ///
    /// Filtered to the same active types as `subscriber_count`, so this can
    /// never exceed it by counting people who joined and then left. On an
    /// all-time run there is no date filter, so the two are equal by
    /// definition — every active subscriber joined at some point.
    private func fetchNewSubscriberCount(apiKey: String, since: Date) async throws -> Int {
        var items = activeTypeItems
        if let lowerBound = CollectionWindow.lowerBound(since) {
            items.append(URLQueryItem(name: "date__start", value: iso8601Date(lowerBound)))
        }
        var url = baseURL.appendingPathComponent("subscribers")
        url.append(queryItems: items)
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
    ///
    /// Per-email stats are the `analytics` object on each list row: unique
    /// `opens` and `clicks` as counts, plus `deliveries`. This used to decode
    /// `email_stats.open_rate` / `click_rate`, which the live API does not
    /// send, so neither average ever appeared. Rates are over deliveries,
    /// which is Buttondown's own denominator: its server-side
    /// `open_rate__start=0.66` filter matched an email at 56 opens / 84
    /// deliveries (0.667), where 56 / 87 recipients would be 0.644.
    private func fetchEmailStats(apiKey: String, since: Date) async throws -> EmailStatsAccumulator {
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
                URLQueryItem(name: "ordering", value: "-publish_date"),
                // `/emails` documents a `status` filter, so drafts and
                // scheduled emails are presumably listed without it — and an
                // all-time run sends no date filter to exclude them.
                URLQueryItem(name: "status", value: "sent")
            ]
            if let lowerBound = CollectionWindow.lowerBound(since) {
                items.append(URLQueryItem(name: "publish_date__start", value: iso8601Date(lowerBound)))
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
                // Null until sent, and a sent email can have no deliveries;
                // neither has a rate.
                guard let stats = email.analytics, stats.deliveries > 0 else { continue }
                let deliveries = Double(stats.deliveries)
                // Zero opens means open tracking was not recording, not that
                // nobody opened it: live, one email reports 0 opens against 48
                // deliveries and 1 click, which cannot happen with tracking on.
                // Buttondown itself calls that a 0% open rate; averaged in, it
                // drags every all-time figure down, so it is left out instead.
                if stats.opens > 0 { acc.openRates.append(Double(stats.opens) / deliveries) }
                acc.clickRates.append(Double(stats.clicks) / deliveries)
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
    /// Null until the email has been sent, per Buttondown's schema.
    let analytics: Analytics?

    /// A subset of the live object, which also carries recipients, failures,
    /// unsubscriptions, page views and more. Buttondown documents `opens` and
    /// `clicks` as unique counts.
    struct Analytics: Decodable {
        let deliveries: Int
        let opens: Int
        let clicks: Int
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
