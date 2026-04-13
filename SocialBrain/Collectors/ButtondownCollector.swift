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
        if !stats.openRates.isEmpty {
            let avgOpen  = stats.openRates.reduce(0, +) / Double(stats.openRates.count)
            let avgClick = stats.clickRates.reduce(0, +) / Double(stats.clickRates.count)
            metrics["avg_open_rate"]  = .double(avgOpen)
            metrics["avg_click_rate"] = .double(avgClick)
        }

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

    // MARK: - Private

    private func fetchSubscriberCount(apiKey: String) async throws -> Int {
        var url = baseURL.appendingPathComponent("subscribers")
        url.append(queryItems: [URLQueryItem(name: "count", value: "1")])
        var req = URLRequest(url: url)
        req.setTokenAuth(apiKey)
        let (data, response) = try await session.data(for: req)
        let decoded: PagedResponse<EmptyObject> = try decodeJSON(PagedResponse.self, from: data, response: response)
        return decoded.count
    }

    private func fetchNewSubscriberCount(apiKey: String, since: Date?) async throws -> Int {
        var items: [URLQueryItem] = [URLQueryItem(name: "count", value: "1")]
        if let since {
            items.append(URLQueryItem(name: "creation_date__gte", value: iso8601Date(since)))
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
        var count: Int = 0
        var openRates: [Double] = []
        var clickRates: [Double] = []
    }

    private func fetchEmailStats(apiKey: String, since: Date?) async throws -> EmailStatsAccumulator {
        var items: [URLQueryItem] = []
        if let since {
            items.append(URLQueryItem(name: "publish_date__gte", value: iso8601Date(since)))
        }
        var url = baseURL.appendingPathComponent("emails")
        if !items.isEmpty { url.append(queryItems: items) }
        var req = URLRequest(url: url)
        req.setTokenAuth(apiKey)
        let (data, response) = try await session.data(for: req)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded: PagedResponse<ButtondownEmail> = try decodeJSON(
            PagedResponse.self, from: data, response: response, decoder: decoder
        )

        var acc = EmailStatsAccumulator()
        acc.count = decoded.results.count
        for email in decoded.results {
            if let stats = email.emailStats {
                if let openRate = stats.openRate {
                    acc.openRates.append(openRate)
                }
                if let clickRate = stats.clickRate {
                    acc.clickRates.append(clickRate)
                }
            }
        }
        return acc
    }
}

// MARK: - Response models

private struct PagedResponse<T: Decodable>: Decodable {
    let count: Int
    let results: [T]
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
