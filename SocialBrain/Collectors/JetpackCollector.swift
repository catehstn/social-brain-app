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

        let (sum, visitResult) = try await (summary, visits)
        let vis = visitResult.totals

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

        // The views and visitors above cover what was asked of the API, which is
        // not what the caller asked for whenever the cap bites. Silently capping
        // a year-long request at 90 days makes a busy year look like a quiet
        // quarter.
        if visitResult.daysCovered < visitResult.daysRequested {
            metrics["views_window"] = .string(
                "views and visitors cover the last \(visitResult.daysCovered) days, not the \(visitResult.daysRequested) requested")
        }

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

    /// The largest `quantity` this collector asks for, in days.
    ///
    /// Whether this is the API's limit or a choice made here is **unverified**.
    /// `stats/visits` requires authentication, so it cannot be probed without a
    /// real site token; the v1.1 reference page does not exist, and the v1 one
    /// documents `unit`, `quantity` ("number of units to return, Default: 30")
    /// and `date` with **no stated maximum**. It has been in the code since the
    /// collector was written with no note saying which.
    ///
    /// So the cap stays, and the *silence* goes: a request for a longer period
    /// now says the numbers cover 90 days rather than presenting them as the
    /// whole window. That is right either way, which is why it does not wait on
    /// the answer. #75 covers checking collectors against live APIs; if 90 turns
    /// out to be ours rather than theirs, this becomes a page walk over `date`
    /// offsets.
    static let maximumDays = 90

    /// How many days a window covers.
    ///
    /// Calendar days, not elapsed seconds divided by 86,400. A spring-forward
    /// inside the window makes the interval an hour short, and integer division
    /// then turns a 30-day request into 29 — an off-by-one that appears twice a
    /// year, in one hemisphere at a time, and lands in the note's own wording.
    ///
    /// Extracted, and taking its calendar, so it can be tested at all: the
    /// caller reads `Date()` for the end of the window, and the transition that
    /// matters is the *user's* — a test cannot drive either from outside
    /// otherwise. CI runs in UTC, which has no transitions at all.
    static func daysRequested(
        from since: Date, to: Date, calendar: Calendar = .current
    ) -> Int {
        let days = calendar.dateComponents([.day], from: since, to: to).day ?? 0
        return max(1, days)
    }

    private func fetchVisits(
        siteID: String, token: String, since: Date, to: Date
    ) async throws -> (totals: VisitTotals, daysCovered: Int, daysRequested: Int) {
        let requested = Self.daysRequested(from: since, to: to)
        let covered = min(requested, Self.maximumDays)
        var url = Self.apiBase
            .appendingPathComponent("rest/v1.1/sites/\(siteID)/stats/visits")
        url.append(queryItems: [
            URLQueryItem(name: "unit",     value: "day"),
            URLQueryItem(name: "quantity", value: "\(covered)")
        ])
        var req = URLRequest(url: url)
        req.setBearerToken(token)
        let (data, response) = try await session.data(for: req)
        return (try parseVisits(data: data, response: response), covered, requested)
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
