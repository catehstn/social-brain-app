import Foundation

/// Collects scheduled meeting statistics from Calendly.
///
/// Required credentials key: `"api_key"` – Calendly personal access token.
///
/// Metrics returned:
/// - `events_count`       – scheduled events in the period, cancelled included
/// - `cancelled_count`    – of those, events whose `status` is `"canceled"`
/// - `unique_invitees`    – distinct invitee emails across the period's
///   non-cancelled events. **Omitted** when the period holds more than
///   `maximumInviteeLookups` of them — see that constant — or when any
///   invitee lookup fails. "All time" has no upper bound, so upcoming events
///   and their invitees count too, as they do in `events_count`.
/// - `top_event_type_1` … `top_event_type_3` – names of the most-booked event
///   types, cancelled events included
///
/// Checked against the live API on 2026-09-22. Until then this decoded
/// `event_type_name` and `invitees_email_hint`, neither of which a scheduled
/// event has, and read one page of 100: every type came back `"Unknown"`,
/// `unique_invitees` was always 0, and all time reported exactly 100 events
/// for an account holding 118 (#75).
struct CalendlyCollector: Collector {
    let platform: Platform = .calendly
    var instanceName: String = "default"
    private let session: any URLSessionProtocol
    private let baseURL: URL

    init(session: any URLSessionProtocol = URLSession.shared,
         baseURL: URL = URL(string: "https://api.calendly.com")!) {
        self.session = session
        self.baseURL = baseURL
    }

    /// The most per-event invitee lookups `collect` will make.
    ///
    /// A scheduled event carries only `invitees_counter` — how many invitees,
    /// not who — so counting distinct people costs one
    /// `/scheduled_events/{uuid}/invitees` request per event (more for a group
    /// event whose invitees span pages).
    ///
    /// The bound is time, not the rate limit. Lookups run one after another,
    /// and 103 of them took about 30 seconds live on 2026-09-22 — some 3.5 a
    /// second — so 400 is roughly two minutes on the Run screen, and a
    /// sequential walk cannot reach the `x-ratelimit-limit: 500` per minute
    /// the API reported. Should lookups become concurrent, the rate limit
    /// becomes the binding constraint and this needs revisiting.
    ///
    /// Past it the metric is left out rather than counted from a sample: a
    /// partial count would read as a real one, and an absent metric does not.
    static let maximumInviteeLookups = 400

    func fetchLabel(credentials: Credentials) async -> String? {
        guard let apiKey = credentials.apiKey else { return nil }
        let url = baseURL.appendingPathComponent("users/me")
        var req = URLRequest(url: url)
        req.setBearerToken(apiKey)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        struct Response: Decodable {
            struct Resource: Decodable { let name: String }
            let resource: Resource
        }
        return try? JSONDecoder().decode(Response.self, from: data).resource.name
    }

    func collect(since: Date, credentials: Credentials) async throws -> PlatformData {
        guard let apiKey = credentials.apiKey else {
            throw CollectorError.missingCredential("api_key")
        }

        let userURI = try await fetchUserURI(apiKey: apiKey)
        let events  = try await fetchEvents(apiKey: apiKey, userURI: userURI, since: since)

        let cancelled = events.filter { $0.status == "canceled" }
        var metrics: [String: MetricValue] = [
            "events_count":    .int(events.count),
            "cancelled_count": .int(cancelled.count)
        ]

        let held = events.filter { $0.status != "canceled" }
        if held.count <= Self.maximumInviteeLookups {
            // A failed lookup costs this one metric, not the whole platform:
            // the event counts above are already complete, and one 429 or
            // dropped connection among hundreds of requests should not discard
            // them. Omitted rather than partial, for the same reason as the cap.
            do {
                var emails = Set<String>()
                for event in held {
                    for invitee in try await fetchInvitees(apiKey: apiKey, eventURI: event.uri)
                    where invitee.status == "active" {
                        emails.insert(invitee.email.lowercased())
                    }
                }
                metrics["unique_invitees"] = .int(emails.count)
            } catch {
                collectorLog.error(
                    "Calendly invitee lookup failed; unique_invitees omitted: \(error.localizedDescription, privacy: .public)")
            }
        }

        for (index, name) in topEventTypes(events).enumerated() {
            metrics["top_event_type_\(index + 1)"] = .string(name)
        }

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

    // MARK: - Private

    /// The three most-booked event types, by name.
    ///
    /// Tallied by the `event_type` URI, not by `name`. An event's `name` is the
    /// type's name *when it was booked*, so a renamed type shows up under two
    /// names — one of the account's five types did, live — and tallying by name
    /// would split it. The label is the name on the latest-starting event of
    /// that type, since events arrive sorted by `start_time` descending —
    /// which, for "All time", can be an upcoming booking.
    private func topEventTypes(_ events: [CalendlyEvent]) -> [String] {
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        for event in events {
            counts[event.eventType, default: 0] += 1
            if names[event.eventType] == nil { names[event.eventType] = event.name }
        }
        // Ties broken by name so the order does not depend on dictionary order.
        return counts
            .map { (name: names[$0.key] ?? $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(3)
            .map(\.name)
    }

    private func fetchUserURI(apiKey: String) async throws -> String {
        let url = baseURL.appendingPathComponent("users/me")
        var req = URLRequest(url: url)
        req.setBearerToken(apiKey)
        let (data, response) = try await session.data(for: req)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decodeJSON(UserResponse.self, from: data, response: response, decoder: decoder)
        return decoded.resource.uri
    }

    /// Every scheduled event in the window, walking `next_page_token` to the end.
    private func fetchEvents(apiKey: String, userURI: String, since: Date) async throws -> [CalendlyEvent] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "user",  value: userURI),
            URLQueryItem(name: "count", value: "100"),
            URLQueryItem(name: "sort",  value: "start_time:desc")
        ]
        if let lowerBound = CollectionWindow.lowerBound(since) {
            items.append(URLQueryItem(name: "min_start_time", value: iso8601DateTime(lowerBound)))
        }
        return try await fetchAllPages(
            CalendlyEvent.self, apiKey: apiKey,
            path: "scheduled_events", items: items
        )
    }

    private func fetchInvitees(apiKey: String, eventURI: String) async throws -> [CalendlyInvitee] {
        // Built on `baseURL` from the event's UUID rather than requested at the
        // URI the API handed back, so the token only ever goes to `baseURL`.
        let uuid = URL(string: eventURI)?.lastPathComponent ?? eventURI
        return try await fetchAllPages(
            CalendlyInvitee.self, apiKey: apiKey,
            path: "scheduled_events/\(uuid)/invitees",
            items: [URLQueryItem(name: "count", value: "100")]
        )
    }

    /// Follows `pagination.next_page_token` until the API stops returning one.
    ///
    /// The token is sent back as `page_token` alongside the original
    /// parameters. Calendly's own `next_page` URL carries the same token (the
    /// two matched, live), but following it would send the token to whatever
    /// host that URL names.
    private func fetchAllPages<Item: Decodable>(
        _ type: Item.Type, apiKey: String, path: String, items: [URLQueryItem]
    ) async throws -> [Item] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var collected: [Item] = []
        var pageToken: String?
        var seenTokens = Set<String>()
        repeat {
            var url = baseURL.appendingPathComponent(path)
            var query = items
            if let pageToken { query.append(URLQueryItem(name: "page_token", value: pageToken)) }
            url.append(queryItems: query)
            var req = URLRequest(url: url)
            req.setBearerToken(apiKey)

            let (data, response) = try await session.data(for: req)
            let page = try decodeJSON(Page<Item>.self, from: data, response: response, decoder: decoder)
            collected.append(contentsOf: page.collection)
            pageToken = page.pagination.nextPageToken
            // A token handed back twice would loop forever, re-counting the
            // same page each time.
            if let pageToken, !seenTokens.insert(pageToken).inserted {
                throw CollectorError.decodingError("pagination repeated a page token")
            }
        } while pageToken != nil
        return collected
    }
}

// MARK: - Response models

private struct UserResponse: Decodable {
    struct Resource: Decodable { let uri: String }
    let resource: Resource
}

private struct Page<Item: Decodable>: Decodable {
    struct Pagination: Decodable {
        /// `null` on the last page.
        let nextPageToken: String?
    }
    let collection: [Item]
    let pagination: Pagination
}

private struct CalendlyEvent: Decodable {
    let uri: String
    let status: String          // "active" | "canceled"
    /// The event type's name as it was when this event was booked.
    let name: String
    /// The event type's URI — stable across renames, unlike `name`.
    let eventType: String
}

private struct CalendlyInvitee: Decodable {
    let email: String
    let status: String          // "active" | "canceled"
}

// MARK: - Helpers

private func iso8601DateTime(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}
