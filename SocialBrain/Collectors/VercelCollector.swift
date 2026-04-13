import Foundation

/// Collects deployment and usage analytics from Vercel.
///
/// Required credentials keys:
/// - `"api_key"`    – Vercel personal access token
/// - `"site_code"`  – Vercel project ID or project name
///
/// Optional:
/// - `"team_id"`    – Vercel team ID (if the project lives in a team)
///
/// Metrics returned:
/// - `deployments`          – deployments in the period
/// - `production_deployments` – production deployments in the period
/// - `error_deployments`    – deployments that errored
struct VercelCollector: Collector {
    let platform: Platform = .vercel
    var instanceName: String = "default"
    private let session: any URLSessionProtocol
    private let baseURL: URL

    init(session: any URLSessionProtocol = URLSession.shared,
         baseURL: URL = URL(string: "https://api.vercel.com")!) {
        self.session = session
        self.baseURL = baseURL
    }

    func fetchLabel(credentials: Credentials) async -> String? {
        credentials.siteCode
    }

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
        guard let apiKey = credentials.apiKey else {
            throw CollectorError.missingCredential("api_key")
        }
        guard let projectID = credentials.siteCode else {
            throw CollectorError.missingCredential("site_code")
        }

        let deployments = try await fetchDeployments(
            apiKey: apiKey,
            projectID: projectID,
            teamID: credentials["team_id"],
            since: since
        )

        let total      = deployments.count
        let production = deployments.filter { $0.target == "production" }.count
        let errors     = deployments.filter { $0.state == "ERROR" }.count

        let metrics: [String: MetricValue] = [
            "deployments":            .int(total),
            "production_deployments": .int(production),
            "error_deployments":      .int(errors)
        ]
        return PlatformData(platform: platform, instanceName: instanceName, metrics: metrics)
    }

    // MARK: - Private

    private func fetchDeployments(
        apiKey: String,
        projectID: String,
        teamID: String?,
        since: Date?
    ) async throws -> [VercelDeployment] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "projectId", value: projectID),
            URLQueryItem(name: "limit", value: "100")
        ]
        if let since {
            // Vercel uses milliseconds since epoch
            items.append(URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970 * 1000))))
        }
        if let teamID {
            items.append(URLQueryItem(name: "teamId", value: teamID))
        }

        var url = baseURL.appendingPathComponent("v6/deployments")
        url.append(queryItems: items)
        var req = URLRequest(url: url)
        req.setBearerToken(apiKey)

        let (data, response) = try await session.data(for: req)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decodeJSON(DeploymentsResponse.self, from: data, response: response, decoder: decoder)
        return decoded.deployments
    }
}

// MARK: - Response models

private struct DeploymentsResponse: Decodable {
    let deployments: [VercelDeployment]
}

private struct VercelDeployment: Decodable {
    let uid: String
    let target: String?   // "production" | "preview" | nil
    let state: String?    // "BUILDING" | "READY" | "ERROR" | "CANCELED"
}
