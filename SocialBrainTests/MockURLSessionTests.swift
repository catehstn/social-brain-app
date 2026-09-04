import Testing
import Foundation
@testable import SocialBrain

/// Tests for the test double itself.
///
/// Worth having because the mock's blind spots become the suite's blind spots:
/// it matched on path only and recorded nothing, so a collector could build an
/// entirely wrong URL — wrong host, wrong query, missing `since`, credentials in
/// the wrong place — and still pass. #68 is exactly that: Google Search Console
/// double-encodes its site URL and no test could see it.
@Suite("MockURLSession")
struct MockURLSessionTests {

    private let fixtures = ["/api/thing": ("{\"ok\":true}", 200)]

    @Test("Records every request in order")
    func recordsRequests() async throws {
        let session = MockURLSession(fixtures)
        _ = try await session.data(for: URLRequest(url: URL(string: "https://example.com/api/thing?page=1")!))
        _ = try await session.data(for: URLRequest(url: URL(string: "https://example.com/api/thing?page=2")!))

        #expect(session.requests.count == 2)
        #expect(session.requestedURLs.map(\.absoluteString) == [
            "https://example.com/api/thing?page=1",
            "https://example.com/api/thing?page=2"
        ])
    }

    /// Documentation more than guard: a non-mutating `data(for:)` on a struct
    /// could not append to value-typed storage, so the regression this describes
    /// would not compile. Kept because the sharing is load-bearing and non-obvious.
    @Test("Recording survives being copied, since collectors hold their own copy")
    func recordingSurvivesCopy() async throws {
        let session = MockURLSession(fixtures)
        let copy = session
        _ = try await copy.data(for: URLRequest(url: URL(string: "https://example.com/api/thing")!))

        // The struct is a value type; if the recorder were also a value the
        // test would see nothing and every assertion built on it would be vacuous.
        #expect(session.requests.count == 1)
    }

    @Test("Exposes query values, which path matching cannot see")
    func exposesQueryValues() async throws {
        let session = MockURLSession(fixtures)
        _ = try await session.data(
            for: URLRequest(url: URL(string: "https://example.com/api/thing?start=2026-01-01&count=50")!)
        )

        #expect(session.queryValue("start", path: "/api/thing") == "2026-01-01")
        #expect(session.queryValue("count", path: "/api/thing") == "50")
        #expect(session.queryValue("absent", path: "/api/thing") == nil)
    }

    @Test("Exposes headers, so credential placement is testable")
    func exposesHeaders() async throws {
        let session = MockURLSession(fixtures)
        var request = URLRequest(url: URL(string: "https://example.com/api/thing")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: request)

        #expect(session.headerValue("Authorization", path: "/api/thing") == "Bearer secret")
    }

    @Test("An unmatched path names the path, the URL and the known fixtures")
    func unmatchedPathIsDiagnosable() async throws {
        let session = MockURLSession(fixtures)
        // The old behaviour threw URLError.unsupportedURL, which says nothing
        // about which path missed or what was available.
        let error = await #expect(throws: MockURLSessionError.self) {
            _ = try await session.data(for: URLRequest(url: URL(string: "https://example.com/api/other")!))
        }

        let message = error?.localizedDescription ?? ""
        // Match the phrase, not the bare path: the path also appears inside the
        // full-URL line, so `contains("/api/other")` alone proves nothing about
        // whether the path is called out on its own.
        #expect(message.contains(#"No fixture for path "/api/other""#))
        #expect(message.contains("https://example.com/api/other"))
        #expect(message.contains("/api/thing"))
    }

    @Test("A request that throws is still recorded")
    func failedRequestsAreRecorded() async throws {
        let session = MockURLSession(fixtures)
        _ = try? await session.data(for: URLRequest(url: URL(string: "https://example.com/api/other")!))

        // Otherwise a collector that requested the wrong URL would leave no trace.
        #expect(session.requestedURLs.map(\.path) == ["/api/other"])
    }
    @Test("queryValue skips requests that lack the item, rather than taking the first request's")
    func queryValueSkipsRequestsWithoutTheItem() async throws {
        // Pins the contract this suite previously mis-stated. The first request
        // carries no `start`, so a genuinely first-request-based implementation
        // would return nil here.
        let session = MockURLSession(fixtures)
        _ = try await session.data(for: URLRequest(url: URL(string: "https://example.com/api/thing")!))
        _ = try await session.data(for: URLRequest(url: URL(string: "https://example.com/api/thing?start=2026-01-01")!))

        #expect(session.queryValue("start", path: "/api/thing") == "2026-01-01")
        #expect(session.queryValues("start", path: "/api/thing") == ["2026-01-01"])
    }

    @Test("headerValues collects across requests and skips those without the header")
    func headerValuesAcrossRequests() async throws {
        let session = MockURLSession(fixtures)
        let url = URL(string: "https://example.com/api/thing")!

        _ = try await session.data(for: URLRequest(url: url))          // no header
        var authorised = URLRequest(url: url)
        authorised.setValue("Bearer one", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: authorised)
        var second = URLRequest(url: url)
        second.setValue("Bearer two", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: second)

        #expect(session.headerValues("Authorization", path: "/api/thing") == ["Bearer one", "Bearer two"])
        #expect(session.headerValue("Authorization", path: "/api/thing") == "Bearer one")
        #expect(session.headerValues("X-Absent", path: "/api/thing").isEmpty)
    }

}
