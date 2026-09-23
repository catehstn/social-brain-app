import Foundation

/// Collects scheduled and sent post analytics from Buffer's GraphQL API.
///
/// This replaced the v1 REST collector, which Buffer retires on **1 February
/// 2027** with brownouts on 11 November and 9 December 2026 (#117). The v1
/// API also rejects the keys Buffer now issues — *"Public API tokens are not
/// accepted for REST API access"* — so a user who creates a key today could
/// not have used the old collector at all.
///
/// Everything below was checked against the live API on 2026-09-21, because
/// Buffer's migration guide disagrees with it in two places (and is silent on
/// the page-size cap, documented at `pageSize`):
///
/// - The guide says analytics are dashboard-only. The schema has
///   `Post.metrics` and `aggregatedPostMetrics`; they need an **`insights:read`
///   scope** that the authentication docs never list, and that a key without
///   it is refused per field.
/// - The guide maps endpoints, not fields, and says nothing about errors.
///   GraphQL reports a bad query, a missing scope or an unknown field with
///   **HTTP 200** and an `errors` array beside partial `data`. Treating a 200
///   as success would reproduce the silent zeros #115 and #133 fixed, so any
///   error fails the collection — with one exception, below.
///
/// **Engagement is optional.** A key without `insights:read` still yields
/// counts; the only tolerated errors are `INSUFFICIENT_SCOPE` on a post's
/// `metrics`, and then the totals are left out and `engagement_unavailable`
/// says why. Omitting them rather than writing zero is the point: zero is a
/// plausible quiet month.
///
/// The engagement mapping is **unverified against live data** — the key this
/// was built with lacks the scope. What is known comes from the schema:
/// `likes` is Facebook's Like-reaction subcount, and the cross-network
/// equivalent of the old `likes`/`favorites` is `reactions`. And a metric's
/// `value` "defaults to 0 when the network did not report the metric", so a
/// network that does not report reach may read as zero reach. See
/// `engagementTotals`.
///
/// Required credentials key:
/// - `"api_key"` – a Buffer API key, from publish.buffer.com/settings/api.
///   Give it insights access to collect clicks, reach and likes.
///
/// Metrics returned:
/// - `profiles_count`         – number of connected channels
/// - `sent_updates`           – posts sent in the period
/// - `scheduled_updates`      – posts currently in the queue
/// - `total_clicks`           – sum of clicks across sent posts   } only with
/// - `total_reach`            – sum of reach across sent posts    } insights
/// - `total_likes`            – sum of reactions across sent posts} access
/// - `engagement_unavailable` – why the three above are missing, when they are
/// - `posts_sampled`          – set when a page cap cut a walk short
/// - `top_profile_1..3`       – top channels by sent count (as `"Service (name) (N posts)"`)
struct BufferCollector: Collector {
    let platform: Platform = .buffer
    var instanceName: String = "default"
    private let session: any URLSessionProtocol

    static let endpoint = URL(string: "https://api.buffer.com")!

    /// Buffer's maximum for `first`; 101 is refused with "Pagination limit
    /// exceeded. Maximum 100 items per request."
    static let pageSize = 100

    /// A bound on any one walk, so an account with an enormous history cannot
    /// hold a collection open indefinitely. 5,000 posts; the account this was
    /// built against has 1,062 sent in total since 2015.
    static let maxPages = 50

    /// How far before `since` the server-side `dueAt` filter starts.
    ///
    /// The filter the API offers is on `dueAt` (or `createdAt`), not
    /// `sentAt`, so the server narrows by schedule and `sentAt` decides
    /// membership here. A post goes out slightly after it is due — at most 252
    /// seconds across all 1,062 posts checked — and one sent *before* its
    /// `dueAt` is still caught by the `sentAt` check. The slack covers a post
    /// that went out late, such as one held in a paused queue.
    ///
    /// `dueAt` is nullable in the schema, and the filter excludes a post
    /// without one, so a windowed run would miss it while "All time" counted
    /// it. None of those 1,062 sent posts lacked a `dueAt` — share-now posts
    /// included — so this is a known edge, not an observed one.
    static let dueAtSlack: TimeInterval = 7 * 24 * 60 * 60

    init(session: any URLSessionProtocol = URLSession.shared) {
        self.session = session
    }

    func fetchLabel(credentials: Credentials) async -> String? {
        guard let token = credentials.apiKey else { return nil }
        let account = try? await query(AccountData.self, Queries.account, variables: [:], token: token)
        return account?.data.account.name
    }

    func collect(since: Date, credentials: Credentials) async throws -> PlatformData {
        guard let token = credentials.apiKey else {
            throw CollectorError.missingCredential("api_key")
        }

        let organizations = try await query(AccountData.self, Queries.account, variables: [:], token: token)
            .data.account.organizations

        let lowerBound = CollectionWindow.lowerBound(since)
        var channels: [Channel] = []
        var sent: [SentPost] = []
        var scheduled = 0
        var truncated = false
        var engagementUnavailable = false

        // Sequential, not concurrent: every query goes to the same URL, and
        // Buffer rate-limits per key (3,000 at the time of writing).
        for org in organizations {
            channels += try await query(ChannelsData.self, Queries.channels,
                                        variables: ["organizationId": org.id], token: token)
                .data.channels

            var dueAt: Any = NSNull()
            if let lowerBound {
                dueAt = ["start": Self.dateTime(lowerBound.addingTimeInterval(-Self.dueAtSlack))]
            }
            let sentWalk = try await walk(SentPost.self, Queries.sentPosts,
                                          variables: ["organizationId": org.id, "dueAt": dueAt],
                                          token: token)
            sent += sentWalk.nodes
            truncated = truncated || sentWalk.truncated
            engagementUnavailable = engagementUnavailable || sentWalk.metricsRefused

            let queueWalk = try await walk(ScheduledPost.self, Queries.scheduledPosts,
                                           variables: ["organizationId": org.id], token: token)
            scheduled += queueWalk.nodes.count
            truncated = truncated || queueWalk.truncated
        }

        // A sent post without a sentAt cannot be placed in a window, so it is
        // excluded once there is one — and counted when there is not, as the
        // v1 collector did.
        let inWindow = sent.filter { post in
            guard let lowerBound else { return true }
            guard let sentAt = post.sentAt else { return false }
            return sentAt >= lowerBound
        }

        var metrics: [String: MetricValue] = [
            MetricKey.profilesCount:    .int(channels.count),
            MetricKey.sentUpdates:      .int(inWindow.count),
            MetricKey.scheduledUpdates: .int(scheduled)
        ]

        if engagementUnavailable {
            // "Some or all": the schema scopes insights access per channel, so
            // one refused post drops every total — omitting is safe, but the
            // note must not claim the whole key lacks access.
            metrics[MetricKey.engagementUnavailable] = .string(
                "the Buffer API key lacks insights access for some or all channels, so clicks, reach and likes were not collected")
        } else {
            metrics.merge(Self.engagementTotals(inWindow)) { _, new in new }
        }

        if truncated {
            metrics[MetricKey.postsSampled] = .string(
                "stopped reading after \(Self.maxPages * Self.pageSize) posts — the sent or queued counts may be higher")
        }

        let names = Dictionary(channels.map { ($0.id, $0.formatted) }, uniquingKeysWith: { first, _ in first })
        let counts = Dictionary(grouping: inWindow, by: \.channelId).mapValues(\.count)
        for (i, (channelID, count)) in counts
                .sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key })
                .prefix(3)
                .enumerated() {
            // A post can outlive its channel: the account this was built on has
            // sent posts back to 2015, from channels long since disconnected.
            let name = names[channelID]
                ?? inWindow.first { $0.channelId == channelID }.map { Channel.capitalised($0.channelService) }
                ?? "Unknown channel"
            metrics[MetricKey.topProfile(i + 1)] = .string("\(name) (\(count) posts)")
        }

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

    /// Sums clicks, reach and reactions across `posts`.
    ///
    /// A total is left out when posts exist and **none** of them carried that
    /// metric, rather than reported as zero — a network that does not report
    /// reach is not a network with no reach. With no posts at all, every
    /// total is a true zero.
    ///
    /// This cannot catch the case the schema warns of, where a metric is
    /// present with a defaulted 0 because the network did not report it.
    /// Telling those apart needs live data from a key with insights access.
    static func engagementTotals(_ posts: [SentPost]) -> [String: MetricValue] {
        // Our key on the left, Buffer's `PostMetricType` on the right. The
        // right-hand side is their vocabulary and stays literal, even where it
        // coincides with one of ours.
        let mapping: [(key: String, type: String)] = [
            (MetricKey.totalClicks, "clicks"),
            (MetricKey.totalReach,  "reach"),
            (MetricKey.totalLikes,  "reactions")
        ]
        var totals: [String: MetricValue] = [:]
        for (key, type) in mapping {
            let values = posts.compactMap { $0.metrics?.first { $0.type == type }?.value }
            guard posts.isEmpty || !values.isEmpty else { continue }
            totals[key] = .int(Int(values.reduce(0, +).rounded()))
        }
        return totals
    }

    // MARK: - Transport

    /// Walks a `posts` connection to the end, or to `maxPages`.
    private func walk<Node: Decodable>(
        _ node: Node.Type,
        _ document: Query,
        variables: [String: Any],
        token: String
    ) async throws -> (nodes: [Node], truncated: Bool, metricsRefused: Bool) {
        var nodes: [Node] = []
        var after: Any = NSNull()
        var metricsRefused = false
        for _ in 0..<Self.maxPages {
            var vars = variables
            vars["first"] = Self.pageSize
            vars["after"] = after
            let result = try await query(PostsData<Node>.self, document, variables: vars, token: token)
            metricsRefused = metricsRefused || result.metricsRefused
            let page = result.data.posts
            nodes += (page.edges ?? []).map(\.node)
            guard page.pageInfo.hasNextPage, let cursor = page.pageInfo.endCursor else {
                return (nodes, false, metricsRefused)
            }
            after = cursor
        }
        return (nodes, true, metricsRefused)
    }

    /// Runs one query, and fails on any GraphQL error except a refused
    /// `metrics` field — which it reports rather than hides.
    private func query<T: Decodable>(
        _ type: T.Type,
        _ document: Query,
        variables: [String: Any],
        token: String
    ) async throws -> (data: T, metricsRefused: Bool) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setBearerToken(token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "operationName": document.name,
            "query": document.text,
            "variables": variables
        ])

        let (body, response) = try await session.data(for: request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Flexible
        let envelope = try decodeJSON(GraphQLResponse<T>.self, from: body, response: response, decoder: decoder)

        let errors = envelope.errors ?? []
        let refused = errors.filter(\.isRefusedMetrics)
        if let fatal = errors.first(where: { !$0.isRefusedMetrics }) {
            collectorLog.error("""
                Buffer \(document.name, privacy: .public) failed: \
                \(fatal.extensions?.code ?? "no code", privacy: .public) \
                \(fatal.message ?? "", privacy: .private)
                """)
            throw CollectorError.serviceError(code: fatal.extensions?.code ?? "unknown")
        }
        guard let data = envelope.data else {
            throw CollectorError.decodingError("response carried neither data nor errors")
        }
        return (data, !refused.isEmpty)
    }

    private static func dateTime(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - Queries

/// Named so a request says what it is, in logs and in tests: every query goes
/// to the same URL, so the path cannot tell them apart.
private struct Query {
    let name: String
    let text: String
}

private enum Queries {
    static let account = Query(name: "Account", text: """
        query Account { account { name organizations { id } } }
        """)

    static let channels = Query(name: "Channels", text: """
        query Channels($organizationId: OrganizationId!) {
          channels(input: { organizationId: $organizationId }) { id name service }
        }
        """)

    /// Sorted by `dueAt`, the field the filter is on; `sentAt` is not
    /// sortable.
    static let sentPosts = Query(name: "SentPosts", text: """
        query SentPosts($organizationId: OrganizationId!, $first: Int!, $after: String, $dueAt: DateTimeComparator) {
          posts(first: $first, after: $after, input: {
            organizationId: $organizationId,
            filter: { status: [sent], dueAt: $dueAt },
            sort: [{ field: dueAt, direction: desc }]
          }) {
            edges { node { channelId channelService sentAt metrics { type value } } }
            pageInfo { hasNextPage endCursor }
          }
        }
        """)

    static let scheduledPosts = Query(name: "ScheduledPosts", text: """
        query ScheduledPosts($organizationId: OrganizationId!, $first: Int!, $after: String) {
          posts(first: $first, after: $after, input: {
            organizationId: $organizationId,
            filter: { status: [scheduled] }
          }) {
            edges { node { id } }
            pageInfo { hasNextPage endCursor }
          }
        }
        """)
}

// MARK: - Response models

/// No dictionaries anywhere in here: `DecodingError.fieldPath` renders coding
/// keys as safe schema names, which stops being true for a `[String: T]`.
private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    let message: String?
    let path: [PathElement]?
    let extensions: Extensions?

    struct Extensions: Decodable { let code: String? }

    enum PathElement: Decodable, Equatable {
        case key(String)
        case index(Int)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .index(i) } else { self = .key(try c.decode(String.self)) }
        }
    }

    /// The one tolerated error: a key without `insights:read`, refused a
    /// post's `metrics`. Live, it arrives once per post at
    /// `posts.edges[i].node.metrics`, with `metrics: null` and everything
    /// else in the node intact.
    var isRefusedMetrics: Bool {
        extensions?.code == "INSUFFICIENT_SCOPE" && path?.last == .key("metrics")
    }
}

private struct AccountData: Decodable {
    struct Account: Decodable {
        let name: String?
        let organizations: [Organization]
    }
    struct Organization: Decodable { let id: String }
    let account: Account
}

private struct ChannelsData: Decodable {
    let channels: [Channel]
}

private struct Channel: Decodable {
    let id: String
    let name: String
    let service: String

    var formatted: String {
        name.isEmpty ? Self.capitalised(service) : "\(Self.capitalised(service)) (\(name))"
    }

    static func capitalised(_ service: String) -> String {
        service.prefix(1).uppercased() + service.dropFirst()
    }
}

private struct PostsData<Node: Decodable>: Decodable {
    struct Posts: Decodable {
        struct Edge: Decodable { let node: Node }
        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }
        let edges: [Edge]?
        let pageInfo: PageInfo
    }
    let posts: Posts
}

extension BufferCollector {
    struct SentPost: Decodable {
        let channelId: String
        let channelService: String
        let sentAt: Date?
        /// `nil` when the key lacks insights access, and for a post not yet sent.
        let metrics: [Metric]?

        struct Metric: Decodable {
            let type: String
            let value: Double
        }
    }
}

private struct ScheduledPost: Decodable {
    let id: String
}
