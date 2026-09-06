import Foundation

/// Collects profile and post statistics from a Mastodon instance.
///
/// Required credentials keys:
/// - `"access_token"`  – OAuth access token
/// - `"instance_url"`  – base URL of the instance (e.g. `"https://mastodon.social"`)
///
/// Metrics returned:
/// - `followers_count`    – current followers
/// - `following_count`    – accounts being followed
/// - `statuses_count`     – all-time post count
/// - `recent_posts`       – posts published since `since`
/// - `avg_reblogs`        – average reblogs per recent post
/// - `avg_favourites`     – average favourites per recent post
/// - `avg_replies`        – average replies per recent post
struct MastodonCollector: Collector {
    let platform: Platform = .mastodon
    var instanceName: String = "default"
    private let session: any URLSessionProtocol

    init(session: any URLSessionProtocol = URLSession.shared) {
        self.session = session
    }

    func fetchLabel(credentials: Credentials) async -> String? {
        guard let token = credentials.accessToken,
              let instanceURL = credentials.instanceURL else { return nil }
        let url = instanceURL.appendingPathComponent("/api/v1/accounts/verify_credentials")
        var req = URLRequest(url: url)
        req.setBearerToken(token)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        struct Account: Decodable { let username: String }
        guard let acct = try? JSONDecoder().decode(Account.self, from: data) else { return nil }
        let host = instanceURL.host ?? instanceURL.absoluteString
        return "@\(acct.username)@\(host)"
    }

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
        guard let token = credentials.accessToken else {
            throw CollectorError.missingCredential("access_token")
        }
        guard let instanceURL = credentials.instanceURL else {
            throw CollectorError.missingCredential("instance_url")
        }

        let account = try await verifyCredentials(instanceURL: instanceURL, token: token)
        let (statuses, truncated) = try await fetchRecentStatuses(
            instanceURL: instanceURL,
            accountID: account.id,
            token: token,
            since: since
        )

        var metrics: [String: MetricValue] = [
            "followers_count": .int(account.followersCount),
            "following_count": .int(account.followingCount),
            "statuses_count":  .int(account.statusesCount),
            "recent_posts":    .int(statuses.count)
        ]

        // Says so rather than presenting a truncated count as complete. The
        // undercount is only dangerous while it is silent: a smaller number
        // reads as a quieter week, which is the judgement this app exists to
        // support.
        if truncated {
            // A string, not a flag: MetricValue has no bool, and adding one
            // would ripple through the database encoding, the prompt and the
            // detectors for a single call site. The prompt is the consumer, and
            // a sentence is what it wants — `top_profile_1` sets the same
            // precedent.
            metrics["posts_truncated"] =
                .string("stopped after \(Self.maximumPages * Self.pageSize) posts; the period holds more")
        }

        if !statuses.isEmpty {
            let totalReblogs    = statuses.map(\.reblogsCount).reduce(0, +)
            let totalFavourites = statuses.map(\.favouritesCount).reduce(0, +)
            let totalReplies    = statuses.map(\.repliesCount).reduce(0, +)
            let n = Double(statuses.count)
            metrics["avg_reblogs"]    = .double(Double(totalReblogs) / n)
            metrics["avg_favourites"] = .double(Double(totalFavourites) / n)
            metrics["avg_replies"]    = .double(Double(totalReplies) / n)
        }

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

    // MARK: - Private

    private func verifyCredentials(instanceURL: URL, token: String) async throws -> AccountInfo {
        let url = instanceURL.appendingPathComponent("api/v1/accounts/verify_credentials")
        var req = URLRequest(url: url)
        req.setBearerToken(token)
        let (data, response) = try await session.data(for: req)
        let decoder = makeDecoder()
        return try decodeJSON(AccountInfo.self, from: data, response: response, decoder: decoder)
    }

    /// The most statuses a single request may return. Mastodon's own cap for
    /// this endpoint; asking for more is silently reduced to it.
    private static let pageSize = 40

    /// How many pages `collect` will walk before stopping.
    ///
    /// Bounds an "all time" run on a prolific account, and bounds a server that
    /// keeps handing back pages. Reaching it is reported rather than hidden —
    /// see `posts_truncated`.
    static let maximumPages = 25

    /// Fetches statuses newer than `since`, walking pages until it passes that
    /// boundary.
    ///
    /// This used to fetch one page of 40 and filter it, while its own doc
    /// comment claimed 200. For any window containing more than 40 posts the
    /// result was an undercount — and an undercount is the worst shape of wrong
    /// here, because a smaller number is indistinguishable from a quieter week,
    /// which is exactly the judgement the app exists to support.
    ///
    /// Mastodon pages backwards by `max_id`, which is exclusive, so each request
    /// asks for statuses older than the oldest one already seen. Statuses come
    /// back newest-first, so the walk stops as soon as a page ends older than
    /// `since` — everything beyond it is older still.
    ///
    /// Returns whether the walk stopped early, so the caller can say so rather
    /// than presenting a truncated count as complete.
    private func fetchRecentStatuses(
        instanceURL: URL,
        accountID: String,
        token: String,
        since: Date?
    ) async throws -> (statuses: [Status], truncated: Bool) {
        let decoder = makeDecoder()
        var collected: [Status] = []
        var maxID: String?

        for _ in 0 ..< Self.maximumPages {
            var url = instanceURL.appendingPathComponent("api/v1/accounts/\(accountID)/statuses")
            var items = [
                URLQueryItem(name: "limit",           value: "\(Self.pageSize)"),
                URLQueryItem(name: "exclude_reblogs", value: "true")
            ]
            if let maxID { items.append(URLQueryItem(name: "max_id", value: maxID)) }
            url.append(queryItems: items)

            var req = URLRequest(url: url)
            req.setBearerToken(token)
            let (data, response) = try await session.data(for: req)
            let page = try decodeJSON([Status].self, from: data, response: response, decoder: decoder)

            collected.append(contentsOf: page)

            // A short page is the last page.
            guard page.count == Self.pageSize, let oldest = page.last else {
                return (filter(collected, since: since), false)
            }
            // With no `since` there is no boundary to walk to, so one page is
            // the whole request — matching what "recent posts" means when the
            // caller did not ask for a window.
            guard let since else { return (collected, false) }
            // The page already reaches past the window; nothing older can help.
            if oldest.createdAt < since { return (filter(collected, since: since), false) }

            maxID = oldest.id
        }
        return (filter(collected, since: since), true)
    }

    private func filter(_ statuses: [Status], since: Date?) -> [Status] {
        guard let since else { return statuses }
        return statuses.filter { $0.createdAt >= since }
    }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601Flexible
        return d
    }
}

// MARK: - Response models

private struct AccountInfo: Decodable {
    let id: String
    let followersCount: Int
    let followingCount: Int
    let statusesCount: Int
}

private struct Status: Decodable {
    let id: String
    let createdAt: Date
    let reblogsCount: Int
    let favouritesCount: Int
    let repliesCount: Int
}
