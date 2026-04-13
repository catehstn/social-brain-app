import Foundation

/// Collects web analytics from a GoatCounter site.
///
/// Required credentials keys:
/// - `"api_key"`   – GoatCounter API token
/// - `"site_code"` – subdomain (e.g. `"mysite"` for `mysite.goatcounter.com`)
///
/// Metrics returned:
/// - `total_pageviews`   – total hits in the period
/// - `unique_visitors`   – unique visitor count
/// - `top_page_1` … `top_page_5` – paths of the top-5 pages by hits
struct GoatCounterCollector: Collector {
    let platform: Platform = .goatCounter
    var instanceName: String = "default"
    private let session: any URLSessionProtocol

    init(session: any URLSessionProtocol = URLSession.shared) {
        self.session = session
    }

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
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
        let start = since ?? Calendar.current.date(byAdding: .day, value: -30, to: end)!

        async let totals   = fetchTotals(baseURL: baseURL, apiKey: apiKey, start: start, end: end)
        async let topPages = fetchTopPages(baseURL: baseURL, apiKey: apiKey, start: start, end: end)

        let (total, pages) = try await (totals, topPages)

        var metrics: [String: MetricValue] = [
            "total_pageviews": .int(total.total),
            "unique_visitors": .int(total.totalUnique)
        ]
        for (index, page) in pages.prefix(5).enumerated() {
            metrics["top_page_\(index + 1)"] = .string(page.path)
        }

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

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
        url.append(queryItems: [
            URLQueryItem(name: "start",  value: iso8601Date(start)),
            URLQueryItem(name: "end",    value: iso8601Date(end)),
            URLQueryItem(name: "limit",  value: "5"),
            URLQueryItem(name: "order",  value: "-count")
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

private struct TotalsResponse: Decodable {
    let total: Int
    let totalUnique: Int
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
