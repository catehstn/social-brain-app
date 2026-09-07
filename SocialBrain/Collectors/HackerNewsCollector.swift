import Foundation

/// Tracks Hacker News mentions of a domain using the Algolia HN Search API.
///
/// No authentication required. The user provides their domain to monitor.
///
/// Required credentials key:
/// - `"site_code"` – domain to search for (e.g. `"example.com"`)
///
/// Metrics returned:
/// - `mention_count`      – stories/comments linking to the domain in the period
/// - `total_points`       – sum of points across matched stories
/// - `total_comments`     – sum of comment counts across matched stories
/// - `top_story_1..3`     – top stories by points (as `"title (N pts)"` strings)
struct HackerNewsCollector: Collector {
    let platform: Platform = .hackerNews
    var instanceName: String = "default"
    private let session: any URLSessionProtocol

    static let apiBase = URL(string: "https://hn.algolia.com/api/v1")!

    init(session: any URLSessionProtocol = URLSession.shared) {
        self.session = session
    }

    func fetchLabel(credentials: Credentials) async -> String? {
        credentials.siteCode
    }

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
        guard let domain = credentials.siteCode, !domain.isEmpty else {
            throw CollectorError.missingCredential("site_code")
        }

        let cutoff = since ?? Calendar.current.date(byAdding: .day, value: -28, to: Date())!
        let (hits, total) = try await fetchMentions(domain: domain, since: cutoff)

        let totalPoints   = hits.compactMap(\.points).reduce(0, +)
        let totalComments = hits.compactMap(\.numComments).reduce(0, +)

        var metrics: [String: MetricValue] = [
            // The API's own total, not what was fetched. This used to report
            // exactly 100 for any busy period.
            "mention_count":  .int(total),
            "total_points":   .int(totalPoints),
            "total_comments": .int(totalComments)
        ]

        // The count above is exact; these sums are not, when the matches exceed
        // what the API will page through.
        if hits.count < total {
            metrics["mentions_sampled"] = .string(
                "points and comments cover \(hits.count) of \(total) mentions — the API pages no further")
        }

        let topStories = hits
            .filter { ($0.points ?? 0) > 0 }
            .sorted { ($0.points ?? 0) > ($1.points ?? 0) }
            .prefix(3)

        for (i, story) in topStories.enumerated() {
            let title = story.title ?? story.storyTitle ?? "(untitled)"
            let pts   = story.points ?? 0
            metrics["top_story_\(i + 1)"] = .string("\(title) (\(pts) pts)")
        }

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

    // MARK: - API

    /// Algolia's own ceiling: with `hitsPerPage=100` it reports at most ten
    /// pages regardless of how many hits exist, so 1,000 is all any client can
    /// page through. Verified live — a one-year window reports
    /// `nbHits: 369830` and `nbPages: 10`.
    private static let maximumPages = 10
    private static let hitsPerPage = 100

    /// Fetches every page of mentions the API will give, up to its own ceiling.
    ///
    /// This used to fetch one page of 100 and report `hits.count`, so a busy
    /// period was silently reported as exactly 100 mentions.
    ///
    /// Unlike Mastodon and Bluesky, the fix here can be **exact**: Algolia
    /// returns `nbHits`, the true number of matches, and it honours the date
    /// filter — a one-week window reports 696 where the unfiltered query
    /// reports 2,136,129. So the headline count is right even when the hits
    /// behind it cannot all be fetched. Only the sums over those hits are
    /// bounded, and `mentions_sampled` says so when they are.
    private func fetchMentions(
        domain: String, since: Date
    ) async throws -> (hits: [HNHit], total: Int) {
        var collected: [HNHit] = []
        var total = 0

        for page in 0 ..< Self.maximumPages {
            let envelope = try await fetchPage(domain: domain, since: since, page: page)
            total = envelope.nbHits
            collected.append(contentsOf: envelope.hits)
            // `nbPages` already accounts for the ceiling, so this is the end of
            // what the API will serve rather than the end of the matches.
            if page + 1 >= envelope.nbPages { break }
        }
        return (collected, total)
    }

    private func fetchPage(
        domain: String, since: Date, page: Int
    ) async throws -> HNSearchResponse {
        let sinceTimestamp = Int(since.timeIntervalSince1970)
        var url = Self.apiBase.appendingPathComponent("search")
        url.append(queryItems: [
            URLQueryItem(name: "query",                        value: domain),
            // `url` only. Adding `story_url` returns HTTP 400 — it is not in the
            // index's searchableAttributes — so every collection failed outright.
            // Verified against the live API:
            //   ?restrictSearchableAttributes=url,story_url → 400
            //     "attribute story_url is not in searchableAttributes setting"
            //   ?restrictSearchableAttributes=url            → 200, real hits
            // The restriction still matters: without it the query matches the
            // domain appearing in comment text, which is not a mention of it.
            URLQueryItem(name: "restrictSearchableAttributes", value: "url"),
            URLQueryItem(name: "numericFilters",               value: "created_at_i>\(sinceTimestamp)"),
            URLQueryItem(name: "hitsPerPage",                  value: "\(Self.hitsPerPage)"),
            URLQueryItem(name: "page",                         value: "\(page)")
        ])
        let (data, response) = try await session.data(for: URLRequest(url: url))
        return try decodeJSON(HNSearchResponse.self, from: data, response: response)
    }
}

// MARK: - Response models

private struct HNSearchResponse: Decodable {
    let hits: [HNHit]
    /// The true number of matches, honouring the date filter — so the mention
    /// count is right even when the hits behind it exceed what can be paged.
    let nbHits: Int
    /// Already capped by Algolia's result-window limit, so reaching it means
    /// the end of what the API serves, not the end of the matches.
    let nbPages: Int
}

private struct HNHit: Decodable {
    let objectID:   String
    let title:      String?
    let storyTitle: String?
    let url:        String?
    let points:     Int?
    let numComments: Int?

    enum CodingKeys: String, CodingKey {
        case objectID    = "objectID"
        case title
        case storyTitle  = "story_title"
        case url
        case points
        case numComments = "num_comments"
    }
}
