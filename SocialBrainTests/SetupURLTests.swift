import Testing
import Foundation

/// Verifies that every setup URL used in the credential sheet and setup guide
/// is reachable (returns HTTP 2xx or 3xx).
///
/// This suite makes live network calls, so it is **opt-in**. Every other test in
/// the target is hermetic, and CI must stay that way — a link-rot check that
/// fails because a vendor added bot protection is not a signal about this code.
/// (developer.wordpress.com now returns 403 to a HEAD request even with a
/// browser User-Agent, which is what surfaced this.)
///
/// Run it deliberately when adding or changing setup URLs. The `TEST_RUNNER_`
/// prefix is required: xcodebuild strips it and forwards the rest into the test
/// host. A bare `RUN_NETWORK_TESTS=1` does NOT reach the test process — the
/// suite skips and the run exits 0, which looks like a pass.
///   TEST_RUNNER_RUN_NETWORK_TESTS=1 xcodebuild test -scheme SocialBrain \
///     -destination 'platform=macOS' -only-testing:SocialBrainTests/SetupURLTests
@Suite(
    "Setup URL reachability",
    .enabled(
        if: ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] != nil,
        "set TEST_RUNNER_RUN_NETWORK_TESTS=1 to check setup URLs against the live web"
    )
)
struct SetupURLTests {

    /// Every setup URL that can be verified with a HEAD request.
    ///
    /// Excluded from this list:
    /// - `bsky.app/settings/app-passwords` — SPA route; 404 to HEAD, works in browser
    /// - `kdp.amazon.com` — requires auth; all paths redirect or 404 to HEAD
    static let setupURLs: [(label: String, url: String)] = [
        // API Key platforms
        ("Buttondown keys",            "https://buttondown.com/keys"),
        ("Calendly API webhooks",      "https://calendly.com/integrations/api_webhooks"),
        // Token / OAuth platforms
        ("WordPress.com apps",         "https://developer.wordpress.com/apps/"),
        ("Google Cloud Console",       "https://console.cloud.google.com/apis/credentials"),
        ("Google OAuth Playground",    "https://developers.google.com/oauthplayground/"),
        ("Buffer developer API",       "https://buffer.com/developers/api"),
        // File-export platforms
        ("O'Reilly",                   "https://www.oreilly.com"),
    ]

    @Test("All setup URLs are reachable", arguments: setupURLs)
    func urlIsReachable(entry: (label: String, url: String)) async throws {
        guard let url = URL(string: entry.url) else {
            Issue.record("Invalid URL string: \(entry.url)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        // Identify as a browser so servers don't reject the HEAD request.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            Issue.record("\(entry.label): response was not HTTP")
            return
        }
        #expect(
            (200...399).contains(http.statusCode),
            "\(entry.label) returned HTTP \(http.statusCode) — URL may need updating"
        )
    }
}
