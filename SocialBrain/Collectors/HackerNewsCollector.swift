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
        let hits = try await fetchMentions(domain: domain, since: cutoff)

        let totalPoints   = hits.compactMap(\.points).reduce(0, +)
        let totalComments = hits.compactMap(\.numComments).reduce(0, +)

        var metrics: [String: MetricValue] = [
            "mention_count":  .int(hits.count),
            "total_points":   .int(totalPoints),
            "total_comments": .int(totalComments)
        ]

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

    private func fetchMentions(domain: String, since: Date) async throws -> [HNHit] {
        let sinceTimestamp = Int(since.timeIntervalSince1970)
        var url = Self.apiBase.appendingPathComponent("search")
        url.append(queryItems: [
            URLQueryItem(name: "query",                        value: domain),
            URLQueryItem(name: "restrictSearchableAttributes", value: "url,story_url"),
            URLQueryItem(name: "numericFilters",               value: "created_at_i>\(sinceTimestamp)"),
            URLQueryItem(name: "hitsPerPage",                  value: "100")
        ])
        let (data, response) = try await session.data(for: URLRequest(url: url))
        let envelope = try decodeJSON(HNSearchResponse.self, from: data, response: response)
        return envelope.hits
    }
}

// MARK: - Response models

private struct HNSearchResponse: Decodable {
    let hits: [HNHit]
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
