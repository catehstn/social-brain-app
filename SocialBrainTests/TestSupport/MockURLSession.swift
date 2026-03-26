import Foundation
@testable import SocialBrain

/// A URLSessionProtocol implementation that returns pre-loaded fixture responses.
///
/// Matches requests by URL path (ignoring query parameters) to keep fixtures simple.
struct MockURLSession: URLSessionProtocol, Sendable {
    let fixtures: [String: (Data, Int)]  // path → (body, status code)

    init(_ fixtures: [String: (Data, Int)]) {
        self.fixtures = fixtures
    }

    /// Convenience init that accepts string bodies.
    init(_ fixtures: [String: (String, Int)]) {
        self.fixtures = fixtures.mapValues { (body, status) in
            (Data(body.utf8), status)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }

        // Match by path only so collectors can include query params freely.
        let path = url.path
        guard let (data, status) = fixtures[path] else {
            throw URLError(.unsupportedURL)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}
