import Foundation

// MARK: - URLSession abstraction (for testability)

/// Mirrors the async `URLSession.data(for:)` API so tests can inject a mock.
protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

// MARK: - Collector protocol

/// A platform-specific analytics collector.
protocol Collector: Sendable {
    var platform: Platform { get }
    /// The instance name for this collector. Defaults to `"default"`.
    var instanceName: String { get }
    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData
    /// Returns a human-readable label for this instance (e.g. newsletter name,
    /// site name, handle). Called once after credentials are saved.
    /// Returns `nil` if no label can be determined.
    func fetchLabel(credentials: Credentials) async -> String?
}

extension Collector {
    var instanceName: String { "default" }
    func fetchLabel(credentials: Credentials) async -> String? { nil }
}

// MARK: - Errors

enum CollectorError: LocalizedError, Sendable {

    /// Turns a status code into something actionable, which is what the echoed
    /// response body was standing in for.
    static func hint(forStatus code: Int) -> String {
        switch code {
        case 401, 403: " — the credentials were rejected. Check the token hasn't expired or been revoked."
        case 404:      " — the endpoint or property wasn't found. Check the account or site identifier."
        case 429:      " — rate limited. Try again later."
        case 500...599: " — the service is having problems. This is usually temporary."
        default:       ""
        }
    }

    case missingCredential(String)
    /// A credential is present but cannot be used — e.g. a site URL in a form
    /// Search Console does not accept. Distinct from `missingCredential`,
    /// because "you didn't enter it" and "what you entered won't work" need
    /// different things from the user.
    case invalidCredential(key: String, reason: String)
    /// Collected successfully, then could not be written to the database.
    /// Distinct from a collector failure: the data existed and was lost, and
    /// there is nothing the user can re-enter to fix it.
    case persistenceFailed(underlying: any Error)
    case httpError(statusCode: Int, body: String)
    case decodingError(String)
    case networkError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let key):
            "Missing credential '\(key)'"
        case .invalidCredential(let key, let reason):
            "Credential '\(key)' is not usable: \(reason)"
        case .persistenceFailed(let underlying):
            "Collected, but could not be saved: \(underlying.localizedDescription)"
        case .httpError(let code, _):
            // The body is deliberately not shown. An error response from an
            // authenticated API can carry account details, and this string is
            // rendered on the Run screen — the screen most likely to end up in
            // a screenshot. The body is still carried on the case for logging.
            "HTTP \(code)\(Self.hint(forStatus: code))"
        case .decodingError(let msg):
            "Failed to decode response: \(msg)"
        case .networkError(let err):
            "Network error: \(err.localizedDescription)"
        }
    }
}

// MARK: - Shared HTTP helpers

extension URLRequest {
    /// Adds a `Bearer` Authorization header.
    mutating func setBearerToken(_ token: String) {
        setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// Adds a `Token` Authorization header (used by Buttondown).
    mutating func setTokenAuth(_ token: String) {
        setValue("Token \(token)", forHTTPHeaderField: "Authorization")
    }
}

/// Decodes a JSON response, throwing `CollectorError` on HTTP errors or decode failures.
func decodeJSON<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    response: URLResponse,
    decoder: JSONDecoder = JSONDecoder()
) throws -> T {
    guard let http = response as? HTTPURLResponse else {
        throw CollectorError.decodingError("Non-HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(decoding: data, as: UTF8.self)
        throw CollectorError.httpError(statusCode: http.statusCode, body: body)
    }
    do {
        return try decoder.decode(type, from: data)
    } catch {
        throw CollectorError.decodingError(error.localizedDescription)
    }
}
