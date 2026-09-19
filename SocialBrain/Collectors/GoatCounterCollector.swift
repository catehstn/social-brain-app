import Foundation

/// Collects web analytics from a GoatCounter site.
///
/// Required credentials keys:
/// - `"api_key"`   – GoatCounter API token
/// - `"site_code"` – subdomain (e.g. `"mysite"` for `mysite.goatcounter.com`)
///
/// Metrics returned:
/// - `total_visits`      – visits in the period (session-first views per path)
/// - `top_page_1` … `top_page_5` – paths of the top-5 pages by hits
struct GoatCounterCollector: Collector {
    let platform: Platform = .goatCounter
    var instanceName: String = "default"
    private let session: any URLSessionProtocol

    init(session: any URLSessionProtocol = URLSession.shared) {
        self.session = session
    }

    func fetchLabel(credentials: Credentials) async -> String? {
        credentials.siteCode
    }

    func collect(since: Date, credentials: Credentials) async throws -> PlatformData {
        guard let apiKey = credentials.apiKey else {
            throw CollectorError.missingCredential("api_key")
        }
        guard let siteCode = credentials.siteCode else {
            throw CollectorError.missingCredential("site_code")
        }
        guard let baseURL = URL(string: "https://\(siteCode).goatcounter.com/api/v0") else {
            throw CollectorError.missingCredential("site_code (produced an invalid URL)")
        }

        let end   = Date()
        // GoatCounter documents no maximum range on stats/total or stats/hits,
        // but "all time" arrives here as Date.distantPast and sending the year
        // 1 to a live API is an untested extreme — the class of thing that made
        // #154 fail outright. So the cap is ours, not theirs, and #75 covers
        // checking whether a longer window works.
        let window = CollectionWindow.resolve(since: since, end: end,
                                              maximumDays: Self.maximumDays)
        let start = window.start

        async let totals   = fetchTotals(baseURL: baseURL, apiKey: apiKey, start: start, end: end)
        async let topPages = fetchTopPages(baseURL: baseURL, apiKey: apiKey, start: start, end: end)

        let (total, pages) = try await (totals, topPages)

        // `total_visits`, not pageviews, and not site-wide unique visitors.
        //
        // The number is a sum of `hit_counts.total`, and that column is only
        // incremented when `FirstVisit` is set (`cron/hit_count.go`), which
        // `memstore.go` sets on the first time a *session* views a given path.
        // So it counts (session, path) first-views — one visitor reading three
        // posts counts three. GoatCounter calls this "visits"; its 2.4.0
        // changelog says it stopped storing pageviews at all.
        //
        // `GetTotalCount`'s doc comment still says "pageviews" and predates
        // that change; the struct beside it and the OpenAPI description both
        // say visitors. Believe the increment, not the prose.
        var metrics: [String: MetricValue] = [
            "total_visits": .int(total.total)
        ]
        for (index, page) in pages.prefix(5).enumerated() {
            metrics["top_page_\(index + 1)"] = .string(page.path)
        }

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

    /// The longest window this collector will request, in days.
    ///
    /// Five years is a choice made here, not a documented GoatCounter limit —
    /// see the note in `collect`. #75 covers verifying it against a live site.
    static let maximumDays = 5 * 365

    // MARK: - Private

    private func fetchTotals(
        baseURL: URL, apiKey: String, start: Date, end: Date
    ) async throws -> TotalsResponse {
        var url = baseURL.appendingPathComponent("stats/total")
        url.append(queryItems: [
            URLQueryItem(name: "start", value: iso8601Date(start)),
            URLQueryItem(name: "end",   value: iso8601Date(end))
        ])
        var req = URLRequest(url: url)
        req.setBearerToken(apiKey)
        let (data, response) = try await session.data(for: req)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decodeJSON(TotalsResponse.self, from: data, response: response, decoder: decoder)
    }

    private func fetchTopPages(
        baseURL: URL, apiKey: String, start: Date, end: Date
    ) async throws -> [PageHit] {
        var url = baseURL.appendingPathComponent("stats/hits")
        // No `order` here, however much the call wants one: GoatCounter's API
        // has no such parameter, and it rejects unknown query parameters rather
        // than ignoring them, so sending it 400s the request and fails the whole
        // collection (#154). The ordering is not lost — `stats/hits` is already
        // sorted by count descending server-side, so `limit` alone returns the
        // top pages. `GoatCounterCollectorTests` pins the allowed set.
        url.append(queryItems: [
            URLQueryItem(name: "start",  value: iso8601Date(start)),
            URLQueryItem(name: "end",    value: iso8601Date(end)),
            URLQueryItem(name: "limit",  value: "5")
        ])
        var req = URLRequest(url: url)
        req.setBearerToken(apiKey)
        let (data, response) = try await session.data(for: req)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decodeJSON(HitsResponse.self, from: data, response: response, decoder: decoder)
        return decoded.hits
    }
}

// MARK: - Response models

/// `/api/v0/stats/total`.
///
/// `total` only. The collector also required `total_unique`, which appears
/// nowhere in GoatCounter's API — the full path list offers no unique-visitor
/// figure at all — so the strict decoder threw `keyNotFound` on every real
/// response and GoatCounter never collected (#156).
///
/// `total_events`, `total_utc` and `stats` are also returned and are not
/// decoded, which is fine: the decoder rejects missing keys, not extra ones.
private struct TotalsResponse: Decodable {
    let total: Int
}

private struct HitsResponse: Decodable {
    let hits: [PageHit]
}

private struct PageHit: Decodable {
    let path: String
    let count: Int
}

// MARK: - Helpers

private func iso8601Date(_ date: Date) -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withFullDate]
    return fmt.string(from: date)
}
