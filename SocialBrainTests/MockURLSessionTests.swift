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

    @Test("Matching uses the encoded path, so encoding bugs are visible")
    func matchingUsesEncodedPath() async throws {
        // url.path would decode this to /sites/https://example.com/ and match a
        // fixture keyed on the decoded form — which is exactly how an
        // encoding bug hides from a path-matching mock (#68).
        let session = MockURLSession(["/sites/https%3A%2F%2Fexample.com%2F": ("{}", 200)])
        let url = URL(string: "https://api.example.com/sites/https%3A%2F%2Fexample.com%2F")!

        let (_, response) = try await session.data(for: URLRequest(url: url))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        // The decoded spelling must NOT match.
        let decoded = MockURLSession(["/sites/https://example.com/": ("{}", 200)])
        await #expect(throws: MockURLSessionError.self) {
            _ = try await decoded.data(for: URLRequest(url: url))
        }
    }

    // MARK: - Sequencing and headers

    @Test("A path can return a different response per call")
    func responsesAreSequencedPerPath() async throws {
        // Pagination was untestable without this: one response per path forever
        // meant a collector that fetches page 1 and stops looked identical to
        // one that walks every page (#73, #103).
        let session = MockURLSession([
            "/pages": [.init("one"), .init("two"), .init("three")]
        ])
        let url = try #require(URL(string: "https://example.com/pages"))

        var bodies: [String] = []
        for _ in 0..<3 {
            let (data, _) = try await session.data(for: URLRequest(url: url))
            bodies.append(String(decoding: data, as: UTF8.self))
        }
        #expect(bodies == ["one", "two", "three"])
    }

    @Test("An exhausted queue repeats its last response")
    func exhaustedQueueRepeatsTheLast() async throws {
        // What a real paginated API does at the end, and what keeps every
        // single-response fixture in this suite behaving as it always did.
        let session = MockURLSession(["/pages": [.init("one"), .init("last")]])
        let url = try #require(URL(string: "https://example.com/pages"))

        var bodies: [String] = []
        for _ in 0..<4 {
            let (data, _) = try await session.data(for: URLRequest(url: url))
            bodies.append(String(decoding: data, as: UTF8.self))
        }
        #expect(bodies == ["one", "last", "last", "last"])
    }

    @Test("Each path has its own cursor")
    func cursorsAreIndependentPerPath() async throws {
        // Deliberately not one global queue. Collectors fetch different
        // endpoints concurrently under `async let`, so a global cursor would
        // hand out responses in whatever order the tasks happened to start.
        let session = MockURLSession([
            "/a": [.init("a1"), .init("a2")],
            "/b": [.init("b1"), .init("b2")]
        ])
        func get(_ path: String) async throws -> String {
            let url = try #require(URL(string: "https://example.com\(path)"))
            let (data, _) = try await session.data(for: URLRequest(url: url))
            return String(decoding: data, as: UTF8.self)
        }

        // Interleaved on purpose: /b's first call must not consume /a's cursor.
        #expect(try await get("/a") == "a1")
        #expect(try await get("/b") == "b1")
        #expect(try await get("/a") == "a2")
        #expect(try await get("/b") == "b2")
    }

    @Test("A copy of the session shares the cursor")
    func cursorIsSharedAcrossCopies() async throws {
        // MockURLSession is a struct and collectors hold their own copy, so
        // without a shared reference every copy would start again at page one —
        // the same reason recording lives behind the Recorder.
        let session = MockURLSession(["/pages": [.init("one"), .init("two")]])
        let copy = session
        let url = try #require(URL(string: "https://example.com/pages"))

        let (first, _) = try await session.data(for: URLRequest(url: url))
        let (second, _) = try await copy.data(for: URLRequest(url: url))
        #expect(String(decoding: first, as: UTF8.self) == "one")
        #expect(String(decoding: second, as: UTF8.self) == "two")
    }

    @Test("A response can carry its own headers")
    func responsesCarryHeaders() async throws {
        // Mastodon paginates by Link header, so its pagination was untestable
        // even in principle while Content-Type was hard-coded as the only one.
        let link = "<https://example.com/pages?max_id=7>; rel=\"next\""
        let session = MockURLSession(["/pages": [.init("[]", headers: ["Link": link])]])
        let url = try #require(URL(string: "https://example.com/pages"))

        let (_, response) = try await session.data(for: URLRequest(url: url))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.value(forHTTPHeaderField: "Link") == link)
        // The default is still there for every fixture that does not set one.
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("A per-response status still applies")
    func perResponseStatus() async throws {
        let session = MockURLSession([
            "/pages": [.init("ok"), .init("gone", status: 500)]
        ])
        let url = try #require(URL(string: "https://example.com/pages"))

        let (_, first) = try await session.data(for: URLRequest(url: url))
        let (_, second) = try await session.data(for: URLRequest(url: url))
        #expect((first as? HTTPURLResponse)?.statusCode == 200)
        #expect((second as? HTTPURLResponse)?.statusCode == 500)
    }

    @Test("An HTTP error does not put the response body in its message")
    func httpErrorDoesNotEchoTheBody() {
        // The message is rendered on the Run screen, which is the screen most
        // likely to be screenshotted. An error body from an authenticated API
        // can carry account details, and 200 characters of it used to be shown
        // verbatim.
        let secret = "user_email=cate@example.com&internal_id=abc123"
        let error = CollectorError.httpError(statusCode: 403, body: secret)

        let message = error.localizedDescription
        #expect(!message.contains("cate@example.com"))
        #expect(!message.contains("abc123"))
        #expect(message.contains("403"))
        // Still actionable — the status is turned into advice, which is what
        // the echoed body was standing in for.
        #expect(message.lowercased().contains("credentials"))
    }

    @Test("Status codes are turned into something actionable",
          arguments: [(401, "credentials"), (404, "wasn't found"), (429, "rate limited"),
                      (503, "temporary"),
                      // 400 is where the body used to be doing the work: it is
                      // the status that says *which* field was wrong, and it
                      // matched none of the specific hints, so suppressing the
                      // body left a bare "HTTP 400" and nothing to act on.
                      (400, "rejected the request"), (422, "rejected the request")])
    func statusHintsAreUseful(code: Int, expected: String) {
        let message = CollectorError.httpError(statusCode: code, body: "").localizedDescription
        #expect(message.lowercased().contains(expected.lowercased()))
    }

    @Test("No HTTP error is left as a bare status number",
          arguments: [100, 302, 400, 401, 402, 403, 404, 409, 410, 422, 429, 451, 500, 503])
    func noStatusIsLeftBare(code: Int) {
        // The generic hint exists so that suppressing the body cannot silently
        // remove the last diagnosable thing about a failure.
        //
        // 1xx and 3xx are in here because decodeJSON throws for anything
        // outside 200..<300, so they are reachable — an earlier version of the
        // catch-all covered only 4xx and left those two bare.
        let message = CollectorError.httpError(statusCode: code, body: "").localizedDescription
        #expect(message != "HTTP \(code)")
    }

}
