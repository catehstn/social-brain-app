import Foundation

/// Collects search performance data from Google Search Console.
///
/// Required credentials keys:
/// - `"access_token"`   – OAuth 2.0 access token (expires ~1 hour; refreshed automatically)
/// - `"refresh_token"`  – OAuth 2.0 refresh token (long-lived)
/// - `"client_id"`      – Google Cloud OAuth client ID
/// - `"client_secret"`  – Google Cloud OAuth client secret
/// - `"site_url"`       – Search Console property URL (e.g. `"https://example.com/"`)
///                        or domain property (e.g. `"sc-domain:example.com"`)
///
/// Metrics returned:
/// - `clicks`            – total organic search clicks in the period
/// - `impressions`       – total search impressions
/// - `ctr`               – average click-through rate (0.0–1.0)
/// - `avg_position`      – average ranking position (lower is better)
/// - `top_query_1..5`    – top queries by clicks (as `"query (N clicks)"` strings)
/// - `top_page_1..5`     – top pages by clicks (as `"path (N clicks)"` strings)
struct GoogleSearchConsoleCollector: Collector {
    let platform: Platform = .googleSearchConsole
    var instanceName: String = "default"
    private let session: any URLSessionProtocol

    static let apiBase = URL(string: "https://searchconsole.googleapis.com")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    init(session: any URLSessionProtocol = URLSession.shared) {
        self.session = session
    }

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
        guard let refreshToken = credentials["refresh_token"] else {
            throw CollectorError.missingCredential("refresh_token")
        }
        guard let clientID = credentials["client_id"] else {
            throw CollectorError.missingCredential("client_id")
        }
        guard let clientSecret = credentials["client_secret"] else {
            throw CollectorError.missingCredential("client_secret")
        }
        guard let siteURL = credentials["site_url"] else {
            throw CollectorError.missingCredential("site_url")
        }

        // Always refresh the token before collecting; GSC access tokens expire
        // after ~1 hour and we can't persist updated tokens back to Keychain here.
        let accessToken = try await refreshAccessToken(
            refreshToken: refreshToken,
            clientID: clientID,
            clientSecret: clientSecret
        )

        let end   = Date()
        let start = since ?? Calendar.current.date(byAdding: .day, value: -28, to: end)!

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let startStr = dateFormatter.string(from: start)
        let endStr   = dateFormatter.string(from: end)

        // Fetch overall totals and top queries/pages concurrently.
        async let totals  = fetchSearchAnalytics(
            siteURL: siteURL, token: accessToken,
            startDate: startStr, endDate: endStr,
            dimensions: [], rowLimit: 1
        )
        async let queries = fetchSearchAnalytics(
            siteURL: siteURL, token: accessToken,
            startDate: startStr, endDate: endStr,
            dimensions: ["query"], rowLimit: 5
        )
        async let pages = fetchSearchAnalytics(
            siteURL: siteURL, token: accessToken,
            startDate: startStr, endDate: endStr,
            dimensions: ["page"], rowLimit: 5
        )

        let (totalsResp, queriesResp, pagesResp) = try await (totals, queries, pages)

        var metrics: [String: MetricValue] = [:]

        if let row = totalsResp.rows?.first {
            metrics["clicks"]       = .int(Int(row.clicks))
            metrics["impressions"]  = .int(Int(row.impressions))
            metrics["ctr"]          = .double(row.ctr)
            metrics["avg_position"] = .double(row.position)
        } else {
            metrics["clicks"]       = .int(0)
            metrics["impressions"]  = .int(0)
        }

        for (i, row) in (queriesResp.rows ?? []).prefix(5).enumerated() {
            let query = row.keys.first ?? "(unknown)"
            metrics["top_query_\(i + 1)"] = .string("\(query) (\(Int(row.clicks)) clicks)")
        }

        for (i, row) in (pagesResp.rows ?? []).prefix(5).enumerated() {
            let page = row.keys.first.flatMap { URL(string: $0)?.path } ?? row.keys.first ?? "(unknown)"
            metrics["top_page_\(i + 1)"] = .string("\(page) (\(Int(row.clicks)) clicks)")
        }

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

    // MARK: - Token refresh

    private func refreshAccessToken(
        refreshToken: String,
        clientID: String,
        clientSecret: String
    ) async throws -> String {
        var req = URLRequest(url: Self.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken.urlEncoded)",
            "client_id=\(clientID.urlEncoded)",
            "client_secret=\(clientSecret.urlEncoded)"
        ].joined(separator: "&")
        req.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: req)
        let tokenResp = try decodeJSON(TokenResponse.self, from: data, response: response)
        return tokenResp.accessToken
    }

    // MARK: - Search Analytics

    private func fetchSearchAnalytics(
        siteURL: String,
        token: String,
        startDate: String,
        endDate: String,
        dimensions: [String],
        rowLimit: Int
    ) async throws -> SearchAnalyticsResponse {
        let encodedSite = siteURL.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? siteURL
        let url = Self.apiBase
            .appendingPathComponent("webmasters/v3/sites/\(encodedSite)/searchAnalytics/query")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setBearerToken(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "startDate": startDate,
            "endDate":   endDate,
            "rowLimit":  rowLimit
        ]
        if !dimensions.isEmpty {
            body["dimensions"] = dimensions
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        return try decodeJSON(SearchAnalyticsResponse.self, from: data, response: response)
    }
}

// MARK: - Response models

private struct TokenResponse: Decodable {
    let accessToken: String
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private struct SearchAnalyticsResponse: Decodable {
    let rows: [SearchAnalyticsRow]?
}

private struct SearchAnalyticsRow: Decodable {
    let keys: [String]
    let clicks: Double
    let impressions: Double
    let ctr: Double
    let position: Double

    // `keys` is absent in aggregate (no-dimension) responses.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keys        = (try? c.decode([String].self, forKey: .keys)) ?? []
        clicks      = try c.decode(Double.self, forKey: .clicks)
        impressions = try c.decode(Double.self, forKey: .impressions)
        ctr         = try c.decode(Double.self, forKey: .ctr)
        position    = try c.decode(Double.self, forKey: .position)
    }

    enum CodingKeys: String, CodingKey {
        case keys, clicks, impressions, ctr, position
    }
}

// MARK: - Helpers

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
