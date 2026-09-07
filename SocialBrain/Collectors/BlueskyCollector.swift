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
    var instanceName: String = "default"

    private let session: any URLSessionProtocol
    private let baseURL: URL

    init(
        session: any URLSessionProtocol = URLSession.shared,
        baseURL: URL = URL(string: "https://bsky.social")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func fetchLabel(credentials: Credentials) async -> String? {
        credentials.username
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
        let (feed, truncated) = try await fetchFeed(
            did: session.did, token: session.accessJwt, since: since
        )

        var metrics: [String: MetricValue] = [
            "followers_count": .int(profile.followersCount),
            "follows_count":   .int(profile.followsCount),
            "posts_count":     .int(profile.postsCount),
            "recent_posts":    .int(feed.count)
        ]

        if truncated {
            metrics["posts_truncated"] =
                .string("stopped after \(Self.maximumPages * Self.pageSize) posts — the period holds more")
        }

        if !feed.isEmpty {
            let n           = Double(feed.count)
            let avgLikes    = feed.map(\.likeCount).reduce(0, +)
            let avgReposts  = feed.map(\.repostCount).reduce(0, +)
            let avgReplies  = feed.map(\.replyCount).reduce(0, +)
            metrics["avg_likes"]   = .double(Double(avgLikes) / n)
            metrics["avg_reposts"] = .double(Double(avgReposts) / n)
            metrics["avg_replies"] = .double(Double(avgReplies) / n)
        }

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
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

    private static let pageSize = 50

    /// How many pages `collect` will walk before stopping.
    static let maximumPages = 20

    /// Fetches the author feed, following the cursor until it passes `since`.
    ///
    /// This used to fetch one page of 50 and filter it, so any window holding
    /// more than 50 posts came back undercounted — quietly, which is the harm:
    /// a smaller number reads as a quieter week.
    ///
    /// **Continuation is the cursor, not the page length**, and that difference
    /// is load-bearing here. Reposts are filtered out *client-side* below, so a
    /// full page of 50 can yield far fewer posts — a page that looks short is
    /// routine rather than final. Bluesky omits `cursor` when there is nothing
    /// further, which is the only reliable end signal.
    ///
    /// The boundary check reads the oldest **non-repost** item, because the feed
    /// is not ordered by `post.indexedAt` at all — it is ordered by each item's
    /// sort key, which for a repost is the *repost* time. Measured against
    /// `public.api.bsky.app`: of 100 items from one account, 5 were out of
    /// descending `post.indexedAt` order, and every one of those was a repost
    /// carrying a `reason.indexedAt` weeks later than the post it points at.
    /// The same 100 items filtered to non-reposts were strictly descending, 73
    /// of 73.
    ///
    /// So a single repost of an old post landing in the last slot would stop the
    /// walk early — the exact undercount this exists to fix, and silently, with
    /// no truncation note. An earlier version of this read the raw last item on
    /// the reasoning that it showed how far back the page reached. It does not.
    ///
    /// The failure modes invert the right way: a page with no surviving post
    /// yields `nil` and the walk *continues*, costing at most one extra request,
    /// rather than stopping short.
    private func fetchFeed(
        did: String, token: String, since: Date?
    ) async throws -> (posts: [PostMetrics], truncated: Bool) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601Flexible

        var collected: [PostMetrics] = []
        var cursor: String?

        for _ in 0 ..< Self.maximumPages {
            var url = baseURL.appendingPathComponent("xrpc/app.bsky.feed.getAuthorFeed")
            var items = [
                URLQueryItem(name: "actor",  value: did),
                URLQueryItem(name: "limit",  value: "\(Self.pageSize)"),
                URLQueryItem(name: "filter", value: "posts_no_replies")
            ]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            url.append(queryItems: items)

            var req = URLRequest(url: url)
            req.setBearerToken(token)
            let (data, response) = try await session.data(for: req)
            let page = try decodeJSON(FeedResponse.self, from: data, response: response, decoder: decoder)

            collected.append(contentsOf: page.feed.compactMap { item -> PostMetrics? in
                guard item.reason == nil else { return nil }  // skip reposts
                return PostMetrics(
                    indexedAt:   item.post.indexedAt,
                    likeCount:   item.post.likeCount ?? 0,
                    repostCount: item.post.repostCount ?? 0,
                    replyCount:  item.post.replyCount ?? 0
                )
            })

            // No cursor means no more feed, whatever the page length was.
            guard let next = page.cursor, !next.isEmpty else {
                return (filter(collected, since: since), false)
            }
            // Reached past the window; nothing older can be in it.
            if let since,
               let oldest = page.feed.last(where: { $0.reason == nil })?.post.indexedAt,
               oldest < since {
                return (filter(collected, since: since), false)
            }
            cursor = next
        }
        return (filter(collected, since: since), true)
    }

    private func filter(_ posts: [PostMetrics], since: Date?) -> [PostMetrics] {
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
    /// Absent when there is nothing further. The only reliable end signal here,
    /// since reposts are filtered client-side and a full page can yield few
    /// posts.
    let cursor: String?
}

private struct FeedItem: Decodable {
    let post: Post
    /// Non-nil for a repost or a pinned post. A *quote* post has no `reason` —
    /// it is an ordinary post that embeds another.
    let reason: AnyCodable?

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
