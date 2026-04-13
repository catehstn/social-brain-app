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
}

extension Collector {
    var instanceName: String { "default" }
}

// MARK: - Errors

enum CollectorError: LocalizedError, Sendable {
    case missingCredential(String)
    case httpError(statusCode: Int, body: String)
    case decodingError(String)
    case networkError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let key):
            "Missing credential '\(key)'"
        case .httpError(let code, let body):
            "HTTP \(code): \(body.prefix(200))"
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
