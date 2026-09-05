import Foundation

/// Collects scheduled and sent post analytics from Buffer.
///
/// Required credentials key:
/// - `"api_key"` – Buffer access token
///   (create at https://buffer.com/developers/apps or via the Buffer Developer dashboard)
///
/// Metrics returned:
/// - `profiles_count`      – number of connected social profiles
/// - `sent_updates`        – posts sent in the period
/// - `scheduled_updates`   – posts currently in the queue
/// - `total_clicks`        – sum of clicks across sent posts
/// - `total_reach`         – sum of reach across sent posts
/// - `total_likes`         – sum of likes/favourites across sent posts
/// - `top_profile_1..3`    – top profiles by sent count (as `"network (N posts)"` strings)
struct BufferCollector: Collector {
    let platform: Platform = .buffer
    var instanceName: String = "default"
    private let session: any URLSessionProtocol

    static let apiBase = URL(string: "https://api.bufferapp.com/1")!

    init(session: any URLSessionProtocol = URLSession.shared) {
        self.session = session
    }

    func fetchLabel(credentials: Credentials) async -> String? {
        guard let token = credentials.apiKey else { return nil }
        // Header, not query string — same reason as authorizedRequest.
        let request = authorizedRequest(
            url: Self.apiBase.appendingPathComponent("user.json"), token: token
        )
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        struct User: Decodable { let name: String? }
        return try? JSONDecoder().decode(User.self, from: data).name
    }

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
        guard let token = credentials.apiKey else {
            throw CollectorError.missingCredential("api_key")
        }

        let profiles = try await fetchProfiles(token: token)

        // Fetch sent updates for each profile concurrently.
        let sentPerProfile = try await withThrowingTaskGroup(
            of: (profile: ProfileInfo, updates: [Update]).self
        ) { group in
            for profile in profiles {
                group.addTask {
                    let updates = try await self.fetchSentUpdates(
                        profileID: profile.id,
                        token: token,
                        since: since
                    )
                    return (profile, updates)
                }
            }
            var results: [(ProfileInfo, [Update])] = []
            for try await pair in group { results.append((pair.profile, pair.updates)) }
            return results
        }

        // Aggregate totals.
        var totalSent      = 0
        var totalClicks    = 0
        var totalReach     = 0
        var totalLikes     = 0
        var profileCounts: [(name: String, count: Int)] = []

        for (profile, updates) in sentPerProfile {
            totalSent   += updates.count
            totalClicks += updates.compactMap(\.statistics?.clicks).reduce(0, +)
            totalReach  += updates.compactMap(\.statistics?.reach).reduce(0, +)
            totalLikes  += updates.compactMap(\.statistics?.likes).reduce(0, +)
            if !updates.isEmpty {
                profileCounts.append((profile.formattedService, updates.count))
            }
        }

        let scheduledCounts = try await fetchScheduledCounts(profiles: profiles, token: token)

        var metrics: [String: MetricValue] = [
            "profiles_count":    .int(profiles.count),
            "sent_updates":      .int(totalSent),
            "scheduled_updates": .int(scheduledCounts),
            "total_clicks":      .int(totalClicks),
            "total_reach":       .int(totalReach),
            "total_likes":       .int(totalLikes)
        ]

        for (i, (name, count)) in profileCounts
                .sorted(by: { $0.count > $1.count })
                .prefix(3)
                .enumerated() {
            metrics["top_profile_\(i + 1)"] = .string("\(name) (\(count) posts)")
        }

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

    // MARK: - Endpoints

    private func fetchProfiles(token: String) async throws -> [ProfileInfo] {
        let url = Self.apiBase.appendingPathComponent("profiles.json")
        let req = authorizedRequest(url: url, token: token)
        let (data, response) = try await session.data(for: req)
        return try decodeJSON([ProfileInfo].self, from: data, response: response)
    }

    private func fetchSentUpdates(
        profileID: String,
        token: String,
        since: Date?
    ) async throws -> [Update] {
        var url = Self.apiBase
            .appendingPathComponent("profiles/\(profileID)/updates/sent.json")
        url.append(queryItems: [URLQueryItem(name: "count", value: "100")])
        let req = authorizedRequest(url: url, token: token)
        let (data, response) = try await session.data(for: req)
        let envelope = try decodeJSON(UpdatesEnvelope.self, from: data, response: response)
        let updates = envelope.updates

        guard let since else { return updates }
        // A sent post without a sent_at cannot be placed in the window, so it is
        // excluded rather than silently counted as in-period.
        return updates.filter { update in
            guard let sentAt = update.sentAt else { return false }
            return sentAt >= since
        }
    }

    private func fetchScheduledCounts(profiles: [ProfileInfo], token: String) async throws -> Int {
        var total = 0
        for profile in profiles {
            let url = Self.apiBase
                .appendingPathComponent("profiles/\(profile.id)/updates/pending.json")
            let req = authorizedRequest(url: url, token: token)
            if let (data, response) = try? await session.data(for: req),
               let envelope = try? decodeJSON(UpdatesEnvelope.self, from: data, response: response) {
                total += envelope.total ?? envelope.updates.count
            }
        }
        return total
    }

    /// Builds a request carrying the token in the Authorization header.
    ///
    /// It used to go in the query string. Buffer accepts either — its auth
    /// documentation lists "the HTTP Authorization header, request body or
    /// query string" — so this was a choice, not a constraint, and it was the
    /// wrong one: a query string is recorded verbatim in server access logs,
    /// proxy logs and browser history, so every request wrote a live credential
    /// somewhere it did not need to be.
    private func authorizedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

// MARK: - Response models

private struct ProfileInfo: Decodable {
    let id: String
    let service: String
    let serviceUsername: String?

    var formattedService: String {
        let name = service.prefix(1).uppercased() + service.dropFirst()
        if let username = serviceUsername, !username.isEmpty {
            return "\(name) (\(username))"
        }
        return name
    }

    enum CodingKeys: String, CodingKey {
        case id
        case service
        case serviceUsername = "service_username"
    }
}

private struct UpdatesEnvelope: Decodable {
    let updates: [Update]
    let total: Int?
}

private struct Update: Decodable {
    let id: String
    /// Optional because a *pending* post has not been sent and carries no
    /// `sent_at`. It was required, so decoding `pending.json` threw, the `try?`
    /// in `fetchScheduledCounts` swallowed it, and `scheduled_updates` was
    /// always 0 — a metric that has never reported anything but zero.
    let sentAt: Date?
    let statistics: UpdateStats?

    enum CodingKeys: String, CodingKey {
        case id
        case sentAt     = "sent_at"
        case statistics
    }

    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(String.self, forKey: .id)
        // Buffer returns sent_at as a Unix timestamp integer, when it is present.
        sentAt = (try? c.decode(Double.self, forKey: .sentAt))
            .map(Date.init(timeIntervalSince1970:))
        statistics = try? c.decode(UpdateStats.self, forKey: .statistics)
    }
}

private struct UpdateStats: Decodable {
    let clicks:  Int?
    let reach:   Int?
    /// Buffer's v1 documentation shows `favorites`, not `likes`, and says so
    /// explicitly: *"'favorites' is equivalent to 'likes'. We have left this as
    /// 'favorites' for now for backward compatibility."* Only `likes` was
    /// decoded, so on any service that sends the documented name the count was
    /// silently zero. Both are read; whichever arrives wins.
    private let likesField: Int?
    private let favoritesField: Int?
    var likes: Int? { likesField ?? favoritesField }
    let comments: Int?
    let shares:  Int?

    enum CodingKeys: String, CodingKey {
        case clicks, reach, comments, shares
        case likesField = "likes"
        case favoritesField = "favorites"
    }
}
