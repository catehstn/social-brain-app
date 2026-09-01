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
        let statuses = try await fetchRecentStatuses(
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

    /// Fetches statuses in pages (up to 200 most recent) and filters by `since`.
    private func fetchRecentStatuses(
        instanceURL: URL,
        accountID: String,
        token: String,
        since: Date?
    ) async throws -> [Status] {
        var url = instanceURL.appendingPathComponent("api/v1/accounts/\(accountID)/statuses")
        url.append(queryItems: [
            URLQueryItem(name: "limit",           value: "40"),
            URLQueryItem(name: "exclude_reblogs", value: "true")
        ])
        var req = URLRequest(url: url)
        req.setBearerToken(token)

        let (data, response) = try await session.data(for: req)
        let decoder = makeDecoder()
        let statuses = try decodeJSON([Status].self, from: data, response: response, decoder: decoder)

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
