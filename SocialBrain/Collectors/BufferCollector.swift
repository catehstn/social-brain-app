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
    private let session: any URLSessionProtocol

    static let apiBase = URL(string: "https://api.bufferapp.com/1")!

    init(session: any URLSessionProtocol = URLSession.shared) {
        self.session = session
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

        return PlatformData(platform: platform, metrics: metrics)
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
        return updates.filter { $0.sentAt >= since }
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

    private func authorizedRequest(url: URL, token: String) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "access_token", value: token))
        components.queryItems = items
        return URLRequest(url: components.url!)
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
    let sentAt: Date
    let statistics: UpdateStats?

    enum CodingKeys: String, CodingKey {
        case id
        case sentAt     = "sent_at"
        case statistics
    }

    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(String.self, forKey: .id)
        // Buffer returns sent_at as a Unix timestamp integer.
        let ts   = try c.decode(Double.self, forKey: .sentAt)
        sentAt   = Date(timeIntervalSince1970: ts)
        statistics = try? c.decode(UpdateStats.self, forKey: .statistics)
    }
}

private struct UpdateStats: Decodable {
    let clicks:  Int?
    let reach:   Int?
    let likes:   Int?
    let comments: Int?
    let shares:  Int?
}
