import Foundation
@testable import SocialBrain

/// A `URLSessionProtocol` for GraphQL APIs, which `MockURLSession` cannot
/// model: every query goes to one URL, so matching by path gives every query
/// the same queue, and a test would depend on the order the collector happens
/// to issue them in.
///
/// Routes on the request body's `operationName` instead. Otherwise it behaves
/// like `MockURLSession`: a queue per operation, the last entry repeating once
/// exhausted, and every request recorded.
struct GraphQLMockSession: URLSessionProtocol, Sendable {

    let fixtures: [String: [MockURLSession.Response]]
    private let recorder = Recorder()

    init(_ fixtures: [String: [MockURLSession.Response]]) {
        self.fixtures = fixtures
    }

    /// One response per operation.
    init(_ fixtures: [String: String]) {
        self.fixtures = fixtures.mapValues { [MockURLSession.Response($0)] }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let operation = Self.body(of: request)?["operationName"] as? String ?? "<none>"
        guard let url = request.url,
              let queue = fixtures[operation], !queue.isEmpty else {
            throw MockURLSessionError.noFixture(
                path: operation, url: request.url?.absoluteString ?? "", known: fixtures.keys.sorted())
        }
        let canned = queue[recorder.record(request, operation: operation, count: queue.count)]
        let response = HTTPURLResponse(
            url: url, statusCode: canned.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"].merging(canned.headers) { _, new in new })!
        return (canned.data, response)
    }

    // MARK: - Recorded requests

    var requests: [URLRequest] { recorder.requests }

    /// The operation names received, in order.
    var operations: [String] {
        requests.map { Self.body(of: $0)?["operationName"] as? String ?? "<none>" }
    }

    /// The `variables` of every request for `operation`, in order.
    func variables(_ operation: String) -> [[String: Any]] {
        requests.compactMap { request in
            guard let body = Self.body(of: request),
                  body["operationName"] as? String == operation else { return nil }
            return body["variables"] as? [String: Any] ?? [:]
        }
    }

    private static func body(of request: URLRequest) -> [String: Any]? {
        guard let data = request.httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URLRequest] = []
        private var cursors: [String: Int] = [:]

        var requests: [URLRequest] { lock.withLock { storage } }

        /// Records the request and returns the index of the response to give it.
        func record(_ request: URLRequest, operation: String, count: Int) -> Int {
            lock.withLock {
                storage.append(request)
                let index = min(cursors[operation, default: 0], count - 1)
                cursors[operation, default: 0] += 1
                return index
            }
        }
    }
}
