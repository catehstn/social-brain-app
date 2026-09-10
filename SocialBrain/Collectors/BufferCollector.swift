import Foundation

/// Collects scheduled and sent post analytics from Buffer.
///
/// **This talks to Buffer's v1 REST API, which is retired on 1 February 2027 —
/// with brownouts on 11 November and 9 December 2026**, short scheduled
/// interruptions where legacy requests error out. Those are the dates this file
/// breaks first, and they are much nearer than the sunset.
/// The API says so itself, in a `sunset:` header and in the body:
/// *"The Buffer legacy REST API is deprecated and will be retired on 1 February
/// 2027. Please migrate to the GraphQL API before then."*
///
/// Only on a request that carries a token, though — a bare unauthenticated call
/// is answered by OAuth middleware with a plain 401 and none of those headers.
/// Anyone re-checking this with a plain `curl` will conclude the note is wrong.
///
/// Migration is tracked in #117. The migration guide maps *endpoints*, not
/// fields: it never mentions `sent_at` or `due_at`, and its GraphQL examples
/// simply use `sentAt` and `dueAt`. The correspondence is the obvious inference
/// and not something the guide states — worth knowing before planning against
/// it. Worth knowing before investing in this file at all.
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
        var comps = URLComponents(url: Self.apiBase.appendingPathComponent("user.json"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = comps.url else { return nil }
        guard let (data, response) = try? await session.data(for: URLRequest(url: url)),
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
            of: (profile: ProfileInfo, updates: [Update], pageWasFull: Bool).self
        ) { group in
            for profile in profiles {
                group.addTask {
                    let page = try await self.fetchSentUpdates(
                        profileID: profile.id,
                        token: token,
                        since: since
                    )
                    return (profile, page.updates, page.pageWasFull)
                }
            }
            var results: [(ProfileInfo, [Update], Bool)] = []
            for try await item in group { results.append((item.profile, item.updates, item.pageWasFull)) }
            return results
        }

        // Aggregate totals.
        var totalSent      = 0
        var totalClicks    = 0
        var totalReach     = 0
        var totalLikes     = 0
        var profileCounts: [(name: String, count: Int)] = []

        // If any profile filled its page, the numbers below cover a page rather
        // than a period — and saying so is the whole point: a count that is
        // really a page size looks exactly like a quiet month.
        var anyPageWasFull = false

        for (profile, updates, pageWasFull) in sentPerProfile {
            if pageWasFull { anyPageWasFull = true }
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

        if anyPageWasFull {
            metrics["posts_sampled"] = .string(
                "at least one profile returned a full page of \(Self.pageSize) sent posts — the period may hold more")
        }

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

    /// Buffer's own maximum for `count` on this endpoint.
    private static let pageSize = 100

    /// Fetches one page of sent updates, and reports whether the page was full.
    ///
    /// Deliberately **not** paginated, unlike Mastodon, Bluesky and Hacker News
    /// in #73 — a choice, not a limitation. Buffer documents a `page` parameter
    /// on this endpoint and #138 already landed a page-number walk for Hacker
    /// News, so the pattern exists. The reason to skip it is that this file is
    /// dying: the legacy REST API is retired on **1 February 2027**, with
    /// **brownouts on 11 November and 9 December 2026** when legacy requests
    /// error out outright, and the replacement is a different protocol. A page
    /// walk written here gets written twice.
    ///
    /// What the undercount actually needs is to stop being *silent*, and that
    /// survives the migration as a requirement even though this code will not.
    ///
    /// A full page is the signal, not the envelope's `total`. Buffer's own
    /// reference shows `total` in an example response and never defines it —
    /// there is no response-parameters table on that page — so what it counts is
    /// a guess. A page that comes back at exactly `count` might have more behind
    /// it; a short one certainly does not, and that needs no documentation to
    /// be true.
    ///
    /// (`fetchScheduledCounts` does use `total`, for pending posts. That is not
    /// a contradiction so much as a different bet: there, being wrong means a
    /// queue count is off; here it would mean silently mislabelling every narrow
    /// window.)
    private func fetchSentUpdates(
        profileID: String,
        token: String,
        since: Date?
    ) async throws -> (updates: [Update], pageWasFull: Bool) {
        var url = Self.apiBase
            .appendingPathComponent("profiles/\(profileID)/updates/sent.json")
        url.append(queryItems: [URLQueryItem(name: "count", value: "\(Self.pageSize)")])
        let req = authorizedRequest(url: url, token: token)
        let (data, response) = try await session.data(for: req)
        let envelope = try decodeJSON(UpdatesEnvelope.self, from: data, response: response)
        let updates = envelope.updates

        let pageWasFull = updates.count >= Self.pageSize
        guard let since else { return (updates, pageWasFull) }
        // A sent post without a sent_at cannot be placed in the window, so it is
        // excluded rather than silently counted as in-period.
        let filtered = updates.filter { update in
            guard let sentAt = update.sentAt else { return false }
            return sentAt >= since
        }
        return (filtered, pageWasFull)
    }

    /// Counts pending posts across every profile.
    ///
    /// Errors propagate, matching `fetchSentUpdates` — the two used to disagree,
    /// and this was the one that lied. Both the request and the decode were
    /// wrapped in `try?`, so any failure produced 0.
    ///
    /// Zero is the problem. It is not an obviously-wrong value the user will
    /// question; it is a plausible answer that means "nothing queued", so the
    /// metric read as working while reporting nothing. #115 found it had been
    /// doing exactly that for every collection ever run: `Update.sentAt` was
    /// required and pending posts carry no `sent_at`, so the decode threw every
    /// time. Fixing that field left the swallow in place, ready to do the same
    /// for the next field Buffer stops sending.
    ///
    /// One unreachable profile now fails the whole Buffer collection. That is
    /// the same bargain `fetchSentUpdates` already makes, and a loud failure the
    /// user can act on beats a silent number they cannot.
    private func fetchScheduledCounts(profiles: [ProfileInfo], token: String) async throws -> Int {
        var total = 0
        for profile in profiles {
            let url = Self.apiBase
                .appendingPathComponent("profiles/\(profile.id)/updates/pending.json")
            let req = authorizedRequest(url: url, token: token)
            let (data, response) = try await session.data(for: req)
            let envelope = try decodeJSON(UpdatesEnvelope.self, from: data, response: response)
            total += envelope.total ?? envelope.updates.count
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
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)

        // `decodeIfPresent`, not `try?`. Both yield nil for an absent key, which
        // is the case that matters — a pending post carries no `sent_at`. They
        // differ on a key that is present but the *wrong type*: `try?` swallows
        // that too, so if Buffer ever sent `sent_at` as a string, every post
        // would silently fall outside the `since` window and `sent_updates`
        // would report 0. Zero is a plausible answer for a quiet month, which is
        // why nobody would notice (#133).
        //
        // Buffer returns it as a Unix timestamp, when present.
        sentAt = try c.decodeIfPresent(Double.self, forKey: .sentAt)
            .map(Date.init(timeIntervalSince1970:))

        // Same reasoning, wider blast radius: one malformed field used to nil
        // the whole block, and the sums downstream then contributed nothing —
        // so clicks, reach and likes all read zero while `sent_updates` looked
        // healthy.
        statistics = try c.decodeIfPresent(UpdateStats.self, forKey: .statistics)
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
