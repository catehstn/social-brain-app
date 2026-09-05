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

    func fetchLabel(credentials: Credentials) async -> String? {
        guard let siteURL = credentials["site_url"] else { return nil }
        // Strip scheme and trailing slash for a compact label.
        return URL(string: siteURL)?.host ?? siteURL
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
        guard let rawSiteURL = credentials["site_url"] else {
            throw CollectorError.missingCredential("site_url")
        }
        let siteURL = try Self.validatedSiteURL(rawSiteURL)

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
        // en_US_POSIX or the user's calendar leaks in: th_TH renders 2026 as the
        // Buddhist year 2569, ar_SA uses Arabic-Indic digits. Search Console
        // rejects both, so the collector was broken outright for those users.
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
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

    /// Builds the `searchAnalytics/query` URL for a site.
    ///
    /// The site URL is one path *segment*, so every reserved character in it has
    /// to be percent-encoded — including `:` and `/`. Two things made this go
    /// wrong before:
    ///
    /// - `.urlPathAllowed` encodes `:` (to `%3A`) but leaves `/` alone, because
    ///   both are legal *within* a path. So `https://example.com/` came out as
    ///   `https%3A//example.com/` — colon escaped once, slashes still live.
    ///   (`CharacterSet.urlPathAllowed.contains(":")` returns `true`, which is
    ///   misleading: it is not what the encoder honours.)
    /// - `appendingPathComponent` then escaped that result's `%`, turning `%3A`
    ///   into `%253A`, while the surviving slashes split the site URL across
    ///   several path segments.
    ///
    /// The result was `sites/https%253A//example.com//searchAnalytics/query` —
    /// a property that cannot exist, so every request 404'd and Google Search
    /// Console has never returned real data.
    ///
    /// Build the string directly instead: `appendingPathComponent` cannot be
    /// used here, because re-encoding an already-encoded segment is the bug.
    static func searchAnalyticsURL(siteURL: String) -> URL {
        let encoded = percentEncodedSiteSegment(siteURL)
        let string = "\(apiBase.absoluteString)/webmasters/v3/sites/\(encoded)/searchAnalytics/query"
        // Not optional-handled: after the strict encoding above the string is
        // pure ASCII from the unreserved set plus `%`, so this cannot fail. A
        // `guard ... else { throw }` here would read as a reachable case and
        // send the next reader looking for it.
        return URL(string: string)!
    }

    /// Checks a site URL is one of the two forms Search Console accepts, and
    /// returns it trimmed.
    ///
    /// Encoding cannot fail — after the strict pass the segment is pure ASCII,
    /// so `URL(string:)` always succeeds. The failure users actually hit is
    /// entering the property in a form Search Console does not recognise, so
    /// that is what is checked.
    static func validatedSiteURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CollectorError.invalidCredential(key: "site_url", reason: "it is empty")
        }
        // A URL-prefix property, or a domain property.
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
                || trimmed.hasPrefix("sc-domain:") else {
            throw CollectorError.invalidCredential(
                key: "site_url",
                reason: """
                    "\(trimmed)" is neither a URL-prefix property (starting https://) \
                    nor a domain property (starting sc-domain:). Copy it exactly as \
                    Search Console shows it.
                    """
            )
        }
        return trimmed
    }

    /// Percent-encodes a site identifier for use as a single path segment.
    ///
    /// Deliberately strict — only the RFC 3986 unreserved set survives — so that
    /// both property forms Search Console accepts round-trip correctly:
    /// `https://example.com/` and `sc-domain:example.com`.
    static func percentEncodedSiteSegment(_ siteURL: String) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return siteURL.addingPercentEncoding(withAllowedCharacters: unreserved) ?? siteURL
    }

    private func fetchSearchAnalytics(
        siteURL: String,
        token: String,
        startDate: String,
        endDate: String,
        dimensions: [String],
        rowLimit: Int
    ) async throws -> SearchAnalyticsResponse {
        let url = Self.searchAnalyticsURL(siteURL: siteURL)

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
