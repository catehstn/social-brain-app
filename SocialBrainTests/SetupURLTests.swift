import Testing
import Foundation

/// Verifies that every setup URL used in the credential sheet and setup guide
/// is reachable (returns HTTP 2xx or 3xx).
///
/// Run this manually when adding or changing setup URLs:
///   xcodebuild test -scheme SocialBrain -only-testing SocialBrainTests/SetupURLTests
///
/// These tests are tagged `.network` so they can be excluded from offline CI:
///   xcodebuild test -scheme SocialBrain -skip-testing SocialBrainTests/SetupURLTests
@Suite("Setup URL reachability")
struct SetupURLTests {

    /// Every setup URL that can be verified with a HEAD request.
    ///
    /// Excluded from this list:
    /// - `bsky.app/settings/app-passwords` — SPA route; 404 to HEAD, works in browser
    /// - `kdp.amazon.com` — requires auth; all paths redirect or 404 to HEAD
    static let setupURLs: [(label: String, url: String)] = [
        // API Key platforms
        ("Buttondown keys",            "https://buttondown.com/keys"),
        ("Vercel tokens",              "https://vercel.com/account/tokens"),
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
