import Foundation

/// Collects blog statistics from a WordPress.com / Jetpack-connected site.
///
/// Required credentials keys:
/// - `"access_token"` – WordPress.com OAuth Bearer token
///   (create at developer.wordpress.com/apps/ or via the WordPress mobile app's
///   connection flow; the token is valid for the authenticated user's sites)
/// - `"site_code"`   – WordPress.com site ID (numeric) or site domain
///   (e.g. `"12345678"` or `"myblog.wordpress.com"`)
///
/// Metrics returned:
/// - `followers_blog`    – total blog subscriber count
/// - `followers_comment` – comment subscriber count
/// - `total_views`       – total page views in the collection period
/// - `total_visitors`    – total unique visitors in the period
/// - `total_likes`       – total post likes recorded today
/// - `total_comments`    – total comments (all-time count from site stats)
struct JetpackCollector: Collector {
    let platform: Platform = .jetpack
    var instanceName: String = "default"
    private let session: any URLSessionProtocol

    static let apiBase = URL(string: "https://public-api.wordpress.com")!

    init(session: any URLSessionProtocol = URLSession.shared) {
        self.session = session
    }

    func fetchLabel(credentials: Credentials) async -> String? {
        credentials.siteCode
    }

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
        guard let token = credentials.accessToken else {
            throw CollectorError.missingCredential("access_token")
        }
        guard let siteID = credentials.siteCode else {
            throw CollectorError.missingCredential("site_code")
        }

        let end   = Date()
        let start = since ?? Calendar.current.date(byAdding: .day, value: -30, to: end)!

        // Fetch summary stats and visit history concurrently.
        async let summary = fetchSummary(siteID: siteID, token: token)
        async let visits  = fetchVisits(siteID: siteID, token: token, since: start, to: end)

        let (sum, vis) = try await (summary, visits)

        var metrics: [String: MetricValue] = [
            "followers_blog":    .int(sum.followersBlog),
            "followers_comment": .int(sum.followersComments),
            "total_comments":    .int(sum.comments)
        ]
        if sum.likesToday > 0 {
            metrics["total_likes"] = .int(sum.likesToday)
        }
        metrics["total_views"]    = .int(vis.views)
        metrics["total_visitors"] = .int(vis.visitors)

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

    // MARK: - Endpoints

    private func fetchSummary(siteID: String, token: String) async throws -> SiteStats {
        let url = Self.apiBase
            .appendingPathComponent("rest/v1.1/sites/\(siteID)/stats")
        var req = URLRequest(url: url)
        req.setBearerToken(token)
        let (data, response) = try await session.data(for: req)
        let decoded = try decodeJSON(StatsEnvelope.self, from: data, response: response)
        return decoded.stats
    }

    private func fetchVisits(siteID: String, token: String, since: Date, to: Date) async throws -> VisitTotals {
        let days = max(1, Int(to.timeIntervalSince(since) / 86400))
        var url = Self.apiBase
            .appendingPathComponent("rest/v1.1/sites/\(siteID)/stats/visits")
        url.append(queryItems: [
            URLQueryItem(name: "unit",     value: "day"),
            URLQueryItem(name: "quantity", value: "\(min(days, 90))")
        ])
        var req = URLRequest(url: url)
        req.setBearerToken(token)
        let (data, response) = try await session.data(for: req)
        return try parseVisits(data: data, response: response)
    }

    /// Parses the visits response which uses a tabular `{ fields: [...], data: [[...]] }` shape.
    private func parseVisits(data: Data, response: URLResponse) throws -> VisitTotals {
        let envelope = try decodeJSON(VisitsEnvelope.self, from: data, response: response)
        let fields = envelope.fields
        guard let viewsIdx   = fields.firstIndex(of: "views"),
              let visitorsIdx = fields.firstIndex(of: "visitors") else {
            return VisitTotals(views: 0, visitors: 0)
        }
        var totalViews    = 0
        var totalVisitors = 0
        for row in envelope.data {
            totalViews    += row[safe: viewsIdx]    ?? 0
            totalVisitors += row[safe: visitorsIdx] ?? 0
        }
        return VisitTotals(views: totalViews, visitors: totalVisitors)
    }
}

// MARK: - Response models

private struct StatsEnvelope: Decodable {
    let stats: SiteStats
}

private struct SiteStats: Decodable {
    let followersBlog: Int
    let followersComments: Int
    let comments: Int
    let likesToday: Int

    enum CodingKeys: String, CodingKey {
        case followersBlog     = "followers_blog"
        case followersComments = "followers_comments"
        case comments
        case likesToday        = "likes_today"
    }
}

private struct VisitsEnvelope: Decodable {
    let fields: [String]
    let data: [[Int]]

    enum CodingKeys: String, CodingKey { case fields, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fields = try c.decode([String].self, forKey: .fields)
        // WordPress.com encodes data rows as [[Any]] where the first element is a
        // date string and the rest are ints.  Map non-int values to 0 so that
        // original field indices (from `fields`) stay aligned with row positions.
        let raw = try c.decode([[JSONValue]].self, forKey: .data)
        data = raw.map { row in
            row.map { element in
                if case .int(let v) = element { return v }
                return 0
            }
        }
    }
}

private struct VisitTotals {
    let views: Int
    let visitors: Int
}

// MARK: - JSONValue (for heterogeneous array decoding)

private enum JSONValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                { self = .null }
        else if let v = try? c.decode(Bool.self)        { self = .bool(v) }
        else if let v = try? c.decode(Int.self)         { self = .int(v) }
        else if let v = try? c.decode(Double.self)      { self = .double(v) }
        else if let v = try? c.decode(String.self)      { self = .string(v) }
        else                                            { self = .null }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
