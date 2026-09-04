import Foundation
@testable import SocialBrain

/// A `URLSessionProtocol` implementation that returns pre-loaded fixture
/// responses and **records every request it was given**.
///
/// Matching is by URL path, ignoring query parameters, so fixtures stay simple.
/// Recording is what makes the query string testable: without it a collector
/// could build a completely wrong URL and still pass, because the path matched.
/// That is not hypothetical — `GoogleSearchConsoleCollector` double-encodes its
/// site URL and targets a property that cannot exist (#68), and no test could
/// see it.
struct MockURLSession: URLSessionProtocol, Sendable {

    let fixtures: [String: (Data, Int)]

    /// Shared by every copy of the struct, so a collector holding its own copy
    /// still records into the instance the test is holding.
    private let recorder = Recorder()

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
        recorder.record(request)

        guard let url = request.url else { throw URLError(.badURL) }

        let path = url.path
        guard let (data, status) = fixtures[path] else {
            // Naming the path and the known fixtures turns "unsupportedURL" —
            // which tells you nothing — into an actionable failure.
            throw MockURLSessionError.noFixture(
                path: path,
                url: url.absoluteString,
                known: fixtures.keys.sorted()
            )
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    // MARK: - Recorded requests

    /// Every request received, in order.
    var requests: [URLRequest] { recorder.requests }

    /// Every requested URL, in order.
    var requestedURLs: [URL] { requests.compactMap(\.url) }

    /// Every request whose path matches, in order.
    ///
    /// Collectors hit the same endpoint more than once with different queries —
    /// Buttondown requests `/v1/subscribers` twice concurrently, once with a
    /// date filter and once without — so "the first request to this path" is
    /// both ambiguous and order-dependent.
    func requests(path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }

    /// The first request whose path matches, or `nil`.
    func request(path: String) -> URLRequest? {
        requests(path: path).first
    }

    /// The values of a query item across every request matching `path`.
    ///
    /// Use this rather than `queryValue` when an endpoint is requested more than
    /// once; with concurrent requests the ordering is not deterministic.
    func queryValues(_ name: String, path: String) -> [String] {
        requests(path: path).compactMap { request -> String? in
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            return components.queryItems?.first { $0.name == name }?.value
        }
    }

    /// The first **non-nil** value of a query item across every request matching
    /// `path` — not "the value on the first request", because `queryValues`
    /// skips requests that lack the item.
    ///
    /// In practice that makes this safe when only one of several requests to a
    /// path carries the item, which is Buttondown's shape. It is *not* safe when
    /// two requests to the same path carry the same item with different values:
    /// under `async let` the winner is nondeterministic. Use `queryValues` there.
    ///
    /// Returns `nil` both when the request was never made and when no request
    /// carried the item — assert on `requestedURLs` too if that matters.
    func queryValue(_ name: String, path: String) -> String? {
        queryValues(name, path: path).first
    }

    /// The values of a header across every request matching `path`.
    ///
    /// Prefer this over `headerValue` when a path is requested more than once:
    /// "first" is nondeterministic under `async let`.
    func headerValues(_ name: String, path: String) -> [String] {
        requests(path: path).compactMap { $0.value(forHTTPHeaderField: name) }
    }

    /// The value of a header on the first request matching `path`.
    ///
    /// Carries the same ordering caveat as `queryValue`.
    func headerValue(_ name: String, path: String) -> String? {
        headerValues(name, path: path).first
    }

    /// Thread-safe because collectors may issue requests concurrently.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URLRequest] = []

        var requests: [URLRequest] { lock.withLock { storage } }

        func record(_ request: URLRequest) {
            lock.withLock { storage.append(request) }
        }
    }
}

enum MockURLSessionError: LocalizedError {
    case noFixture(path: String, url: String, known: [String])

    var errorDescription: String? {
        switch self {
        case let .noFixture(path, url, known):
            """
            No fixture for path "\(path)".
            Full URL requested: \(url)
            Known fixture paths: \(known.isEmpty ? "(none)" : known.joined(separator: ", "))
            """
        }
    }
}
