import Foundation

/// Collects profile and feed statistics from Bluesky (AT Protocol).
///
/// Required credentials keys:
/// - `"username"` – Bluesky handle (e.g. `"alice.bsky.social"`)
/// - `"password"` – App password (not the account password)
///
/// Metrics returned:
/// - `followers_count`  – current followers
/// - `follows_count`    – accounts being followed
/// - `posts_count`      – all-time post count
/// - `recent_posts`     – posts since `since`
/// - `avg_likes`        – average likes per recent post
/// - `avg_reposts`      – average reposts per recent post
/// - `avg_replies`      – average replies per recent post
struct BlueskyCollector: Collector {
    let platform: Platform = .bluesky

    private let session: any URLSessionProtocol
    private let baseURL: URL

    init(
        session: any URLSessionProtocol = URLSession.shared,
        baseURL: URL = URL(string: "https://bsky.social")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
        guard let handle = credentials.username else {
            throw CollectorError.missingCredential("username")
        }
        guard let appPassword = credentials.password else {
            throw CollectorError.missingCredential("password")
        }

        let session = try await createSession(handle: handle, appPassword: appPassword)
        let profile = try await fetchProfile(did: session.did, token: session.accessJwt)
        let feed    = try await fetchFeed(did: session.did, token: session.accessJwt, since: since)

        var metrics: [String: MetricValue] = [
            "followers_count": .int(profile.followersCount),
            "follows_count":   .int(profile.followsCount),
            "posts_count":     .int(profile.postsCount),
            "recent_posts":    .int(feed.count)
        ]

        if !feed.isEmpty {
            let n           = Double(feed.count)
            let avgLikes    = feed.map(\.likeCount).reduce(0, +)
            let avgReposts  = feed.map(\.repostCount).reduce(0, +)
            let avgReplies  = feed.map(\.replyCount).reduce(0, +)
            metrics["avg_likes"]   = .double(Double(avgLikes) / n)
            metrics["avg_reposts"] = .double(Double(avgReposts) / n)
            metrics["avg_replies"] = .double(Double(avgReplies) / n)
        }

        return PlatformData(platform: platform, metrics: metrics)
    }

    // MARK: - Private

    private func createSession(handle: String, appPassword: String) async throws -> ATSession {
        let url = baseURL.appendingPathComponent("xrpc/com.atproto.server.createSession")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": handle,
            "password":   appPassword
        ])
        let (data, response) = try await session.data(for: req)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decodeJSON(ATSession.self, from: data, response: response, decoder: decoder)
    }

    private func fetchProfile(did: String, token: String) async throws -> ProfileView {
        var url = baseURL.appendingPathComponent("xrpc/app.bsky.actor.getProfile")
        url.append(queryItems: [URLQueryItem(name: "actor", value: did)])
        var req = URLRequest(url: url)
        req.setBearerToken(token)
        let (data, response) = try await session.data(for: req)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decodeJSON(ProfileView.self, from: data, response: response, decoder: decoder)
    }

    private func fetchFeed(did: String, token: String, since: Date?) async throws -> [PostMetrics] {
        var url = baseURL.appendingPathComponent("xrpc/app.bsky.feed.getAuthorFeed")
        url.append(queryItems: [
            URLQueryItem(name: "actor",  value: did),
            URLQueryItem(name: "limit",  value: "50"),
            URLQueryItem(name: "filter", value: "posts_no_replies")
        ])
        var req = URLRequest(url: url)
        req.setBearerToken(token)
        let (data, response) = try await session.data(for: req)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let feed = try decodeJSON(FeedResponse.self, from: data, response: response, decoder: decoder)

        let posts = feed.feed.compactMap { item -> PostMetrics? in
            guard item.reason == nil else { return nil }  // skip reposts
            return PostMetrics(
                indexedAt:   item.post.indexedAt,
                likeCount:   item.post.likeCount ?? 0,
                repostCount: item.post.repostCount ?? 0,
                replyCount:  item.post.replyCount ?? 0
            )
        }

        guard let since else { return posts }
        return posts.filter { $0.indexedAt >= since }
    }
}

// MARK: - Response models

private struct ATSession: Decodable {
    let did: String
    let accessJwt: String
}

private struct ProfileView: Decodable {
    let followersCount: Int
    let followsCount: Int
    let postsCount: Int
}

private struct FeedResponse: Decodable {
    let feed: [FeedItem]
}

private struct FeedItem: Decodable {
    let post: Post
    let reason: AnyCodable?  // non-nil means it's a repost/quote

    struct Post: Decodable {
        let indexedAt: Date
        let likeCount: Int?
        let repostCount: Int?
        let replyCount: Int?
    }
}

/// A minimal Decodable wrapper that absorbs any JSON value.
private struct AnyCodable: Decodable {
    init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer()
    }
}

private struct PostMetrics {
    let indexedAt: Date
    let likeCount: Int
    let repostCount: Int
    let replyCount: Int
}
