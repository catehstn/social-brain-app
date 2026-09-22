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
/// Metrics returned — each only when the response carries its field, since a
/// plausible zero reads as real data and an absence does not:
/// - `followers_blog`    – total blog subscriber count
/// - `followers_comment` – comment subscriber count
/// - `total_views`       – total page views in the collection period
/// - `total_visitors`    – sum of each day's unique visitors in the period
///   (a visitor who returns on two days counts twice)
/// - `total_likes`       – post likes in the collection period, summed from the
///   `likes` column of `stats/visits`
/// - `total_comments`    – total comments (all-time count from site stats)
///
/// Response shapes were checked against the live API on 2026-09-22 (#75).
/// `stats` has no `likes_today` field at all — the collector used to require
/// it, so every run failed to decode — and `stats/visits` returns the columns
/// `period, views, visitors, likes, reblogs, comments, posts`.
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

    func collect(since: Date, credentials: Credentials) async throws -> PlatformData {
        guard let token = credentials.accessToken else {
            throw CollectorError.missingCredential("access_token")
        }
        guard let siteID = credentials.siteCode else {
            throw CollectorError.missingCredential("site_code")
        }

        let end   = Date()
        // No clamp here: fetchVisits already caps `quantity` at maximumDays and
        // records views_window saying what it covered, which is the behaviour
        // the rest of the collectors still lack. Date.distantPast simply lands
        // on that cap.
        //
        // Note daysRequested keeps the *user's* calendar rather than UTC, on
        // purpose — see its own doc comment. #96 normalises the boundary dates
        // sent to APIs, which is a different thing from how many days the user
        // asked for.
        let start = since

        // Fetch summary stats and visit history concurrently.
        async let summary = fetchSummary(siteID: siteID, token: token)
        async let visits  = fetchVisits(siteID: siteID, token: token, since: start, to: end)

        let (sum, visitResult) = try await (summary, visits)
        let vis = visitResult.totals

        var metrics: [String: MetricValue] = [:]
        if let v = sum.followersBlog     { metrics["followers_blog"]    = .int(v) }
        if let v = sum.followersComments { metrics["followers_comment"] = .int(v) }
        if let v = sum.comments          { metrics["total_comments"]    = .int(v) }
        if let v = vis.views             { metrics["total_views"]       = .int(v) }
        if let v = vis.visitors          { metrics["total_visitors"]    = .int(v) }
        if let v = vis.likes             { metrics["total_likes"]       = .int(v) }

        // The views, visitors and likes above cover what was asked of the API, which is
        // not what the caller asked for whenever the cap bites. Silently capping
        // a year-long request at 90 days makes a busy year look like a quiet
        // quarter.
        if visitResult.daysCovered < visitResult.daysRequested {
            // The whole clause branches, not just the noun: `.distantPast`
            // makes daysRequested about 739,879, and "not the 739879 requested"
            // is nonsense to read in a prompt (#96).
            //
            // Tested with the same sentinel the rest of the codebase uses
            // rather than a day threshold. A threshold would be a second,
            // fuzzier encoding of "all time" for no gain.
            let note = CollectionWindow.lowerBound(since) == nil
                ? "views, visitors and likes cover the last \(visitResult.daysCovered) days, not all time as requested"
                : "views, visitors and likes cover the last \(visitResult.daysCovered) days, not the \(visitResult.daysRequested) requested"
            metrics["views_window"] = .string(note)
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
    /// This is a choice made here, **not the API's limit**. The v1.1 reference
    /// page does not exist, and the v1 one documents `unit`, `quantity`
    /// ("number of units to return, Default: 30") and `date` with no stated
    /// maximum. Live requests on 2026-09-22 (#75) with `quantity` of 365, 1000,
    /// 3650 and 10000 each returned exactly that many daily rows, so the API
    /// accepts at least 10,000.
    ///
    /// The cap is unchanged by that finding; what matters is that it is not
    /// silent: a request for a longer period says the numbers cover 90 days
    /// rather than presenting them as the whole window. Raising it is a
    /// separate decision.
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
    ///
    /// A column missing from `fields` gives `nil`, not `0`: it used to give 0
    /// for views and visitors, which reads as a site nobody visited.
    private func parseVisits(data: Data, response: URLResponse) throws -> VisitTotals {
        let envelope = try decodeJSON(VisitsEnvelope.self, from: data, response: response)
        func total(_ field: String) -> Int? {
            guard let idx = envelope.fields.firstIndex(of: field) else { return nil }
            return envelope.data.reduce(0) { $0 + ($1[safe: idx] ?? 0) }
        }
        return VisitTotals(views: total("views"), visitors: total("visitors"), likes: total("likes"))
    }
}

// MARK: - Response models

private struct StatsEnvelope: Decodable {
    let stats: SiteStats
}

/// Every field optional: one missing field used to fail the whole decode,
/// which is how a `likes_today` the API does not send took down every metric.
private struct SiteStats: Decodable {
    let followersBlog: Int?
    let followersComments: Int?
    let comments: Int?

    enum CodingKeys: String, CodingKey {
        case followersBlog     = "followers_blog"
        case followersComments = "followers_comments"
        case comments
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
    let views: Int?
    let visitors: Int?
    let likes: Int?
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
