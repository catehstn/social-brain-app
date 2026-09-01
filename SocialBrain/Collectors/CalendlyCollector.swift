import Foundation

/// Collects scheduled meeting statistics from Calendly.
///
/// Required credentials key: `"api_key"` – Calendly personal access token.
///
/// Metrics returned:
/// - `events_count`       – scheduled events in the period
/// - `cancelled_count`    – cancelled events
/// - `unique_invitees`    – distinct invitee email count
/// - `top_event_type_1` … `top_event_type_3` – names of most-used event types
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

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
        guard let apiKey = credentials.apiKey else {
            throw CollectorError.missingCredential("api_key")
        }

        let userURI = try await fetchUserURI(apiKey: apiKey)
        let events  = try await fetchEvents(apiKey: apiKey, userURI: userURI, since: since)

        let total     = events.count
        let cancelled = events.filter { $0.status == "canceled" }.count
        let invitees  = Set(events.compactMap(\.inviteesEmailHint)).count

        // Tally event types
        var typeCounts: [String: Int] = [:]
        for event in events {
            let name = event.eventTypeName ?? "Unknown"
            typeCounts[name, default: 0] += 1
        }
        let topTypes = typeCounts.sorted { $0.value > $1.value }.prefix(3).map(\.key)

        var metrics: [String: MetricValue] = [
            "events_count":    .int(total),
            "cancelled_count": .int(cancelled),
            "unique_invitees": .int(invitees)
        ]
        for (index, name) in topTypes.enumerated() {
            metrics["top_event_type_\(index + 1)"] = .string(name)
        }

        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

    // MARK: - Private

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

    private func fetchEvents(apiKey: String, userURI: String, since: Date?) async throws -> [CalendlyEvent] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "user",  value: userURI),
            URLQueryItem(name: "count", value: "100"),
            URLQueryItem(name: "sort",  value: "start_time:desc")
        ]
        if let since {
            items.append(URLQueryItem(name: "min_start_time", value: iso8601DateTime(since)))
        }
        var url = baseURL.appendingPathComponent("scheduled_events")
        url.append(queryItems: items)
        var req = URLRequest(url: url)
        req.setBearerToken(apiKey)

        let (data, response) = try await session.data(for: req)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601Flexible
        let decoded = try decodeJSON(EventsResponse.self, from: data, response: response, decoder: decoder)
        return decoded.collection
    }
}

// MARK: - Response models

private struct UserResponse: Decodable {
    struct Resource: Decodable { let uri: String }
    let resource: Resource
}

private struct EventsResponse: Decodable {
    let collection: [CalendlyEvent]
}

private struct CalendlyEvent: Decodable {
    let uri: String
    let status: String                   // "active" | "canceled"
    let eventTypeName: String?
    let inviteesEmailHint: String?       // populated in some API tiers
}

// MARK: - Helpers

private func iso8601DateTime(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}
