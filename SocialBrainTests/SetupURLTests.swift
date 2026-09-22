import Testing
import Foundation

/// Verifies that every setup URL used in the credential sheet and setup guide
/// is reachable (returns HTTP 2xx or 3xx).
///
/// This suite makes live network calls, so it is **opt-in**. Every other test in
/// the target is hermetic, and CI must stay that way — a link-rot check that
/// fails because a vendor added bot protection is not a signal about this code.
/// Being opt-in is what makes it safe to keep: a vendor adding bot protection
/// can never redden CI, so a failure here is a prompt to open the link by hand,
/// not a verdict that it is dead. That is the answer to #60's first question —
/// the suite cannot tell bot-blocking from link rot, and does not have to.
///
/// Last verified green on 2026-09-22: every URL answered 2xx/3xx on a normal
/// network, developer.wordpress.com included. #60 recorded it as failing,
/// partly from an environment — a sandboxed shell produced timeouts and
/// `-1004`s that were not link rot — and the 403 it reports did not reproduce.
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
    /// Hand-written, and `credentialSheetURLsAreAllAccountedFor` below is what
    /// stops that being a drift hazard: this list is a second copy of the URLs
    /// in `PlatformCredentialSheet`, and copies rot independently — Calendly
    /// was wrong three different ways across the sheet, this list and a PR
    /// (#62). Deriving them from one source is #97.
    ///
    /// Excluded from this list — see `notCheckedOverTheNetwork`.
    static let setupURLs: [(label: String, url: String)] = [
        // API Key platforms
        ("Buttondown keys",            "https://buttondown.com/keys"),
        ("Calendly API webhooks",      "https://calendly.com/integrations/api_webhooks"),
        // Token / OAuth platforms
        ("WordPress.com apps",         "https://developer.wordpress.com/apps/"),
        ("Google Cloud Console",       "https://console.cloud.google.com/apis/credentials"),
        ("Google OAuth Playground",    "https://developers.google.com/oauthplayground/"),
        ("Buffer API settings",        "https://publish.buffer.com/settings/api"),
        // The setup guide's own steps, which the sheet does not offer: the
        // Console root is where the guide says to create a project, a
        // different page from the sheet's credentials link.
        ("Google Cloud Console root",  "https://console.cloud.google.com/"),
        ("Project repository",         "https://github.com/catehstn/social-brain-app"),
        // File-export platforms
        ("O'Reilly",                   "https://www.oreilly.com"),
    ]

    /// Setup URLs this suite deliberately does not fetch.
    ///
    /// Each needs a reason, so the list cannot quietly become a place to hide
    /// a broken link.
    static let notCheckedOverTheNetwork: [String: String] = [
        // Single-page app: the route is client-side, so a HEAD gets 404 while
        // the link works in a browser.
        "https://bsky.app/settings/app-passwords": "SPA route, 404 to HEAD",
        // Requires a signed-in session; unauthenticated it redirects to a
        // login page, so a 2xx says nothing about the analytics route.
        "https://www.linkedin.com/analytics/creator/content/?metricType=IMPRESSIONS&timeRange=past_90_days":
            "redirects to login when signed out"
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

// MARK: - Drift between the list above and where URLs are declared

/// Not network-gated, deliberately: this reads source, and it is the half of
/// #60 that can run on every PR.
///
/// The reachability suite above only checks the URLs it already knows. A URL
/// added to the credential sheet or the setup guide and not added there is
/// simply never checked, which is how the list came to include a platform that
/// had been retired while missing a URL that had changed (#62, #43).
///
/// Two sources, because there are two: the sheet's `helpURL:` arguments and
/// the setup guide's links. The guide is the one users follow step by step,
/// and it drifts on its own — `SetupGuideCopyTests` exists because
/// `docs/index.html` had already forked from it.
///
/// Deriving all of this from one declaration is #97; until then this turns
/// silent drift into a failing test.
@Suite("Setup URL coverage")
struct SetupURLCoverageTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SocialBrainTests
            .deletingLastPathComponent()   // repo root
    }

    /// Every `helpURL:` literal in the credential sheet.
    ///
    /// A regex over the whole file rather than a line-by-line match: the
    /// sheet already wraps one argument list across lines, and a detector that
    /// misses a wrapped declaration fails in the shape of the bug it guards.
    static func sheetURLs() -> [String] {
        matches(in: "SocialBrain/Views/Platforms/PlatformCredentialSheet.swift",
                pattern: #"helpURL:\s*URL\(\s*string:\s*"([^"]+)""#)
    }

    /// Every external link in the bundled setup guide.
    static func guideURLs() -> [String] {
        matches(in: "SocialBrain/Resources/setup-guide.html",
                pattern: #"href="(https://[^"]+)""#)
            // The guide is HTML, so a query string arrives escaped.
            .map { $0.replacingOccurrences(of: "&amp;", with: "&") }
    }

    private static func matches(in path: String, pattern: String) -> [String] {
        guard let text = try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: pattern)
        else { return [] }

        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
    }

    @Test("Every setup URL the app shows is either checked or excluded with a reason")
    func declaredURLsAreAllAccountedFor() {
        let sheet = Set(Self.sheetURLs())
        let guide = Set(Self.guideURLs())
        #expect(!sheet.isEmpty, "Found no helpURL literals — this detector would pass vacuously")
        #expect(!guide.isEmpty, "Found no links in the setup guide — this detector would pass vacuously")

        let checked = Set(SetupURLTests.setupURLs.map(\.url))
        let excluded = Set(SetupURLTests.notCheckedOverTheNetwork.keys)
        let unaccounted = sheet.union(guide).subtracting(checked).subtracting(excluded)

        let message: Comment = """
            \(unaccounted.sorted()) appear in the credential sheet or the setup guide and in \
            neither SetupURLTests.setupURLs nor notCheckedOverTheNetwork. Add to one or the \
            other; an exclusion needs a reason.
            """
        #expect(unaccounted.isEmpty, message)
    }

    @Test("Nothing is checked that the app no longer shows")
    func checkedURLsAreStillOffered() {
        // The mirror image, and the one that actually happened: the list kept
        // a platform after it was retired (#43 removed Vercel), so the suite
        // was spending a request proving a dead link was alive.
        let declared = Set(Self.sheetURLs()).union(Self.guideURLs())
        guard !declared.isEmpty else { return }

        let stale = Set(SetupURLTests.setupURLs.map(\.url)).subtracting(declared)
        let message: Comment = "\(stale.sorted()) are checked but appear in neither the sheet nor the guide"
        #expect(stale.isEmpty, message)
    }

    @Test("Every exclusion names a URL the app actually shows")
    func exclusionsAreStillReal() {
        // So the exclusion list shrinks as links are fixed, rather than
        // accumulating reasons for URLs nobody shows any more.
        let declared = Set(Self.sheetURLs()).union(Self.guideURLs())
        guard !declared.isEmpty else { return }

        let orphaned = Set(SetupURLTests.notCheckedOverTheNetwork.keys).subtracting(declared)
        let message: Comment = "\(orphaned.sorted()) are excluded from the network check but shown nowhere"
        #expect(orphaned.isEmpty, message)
    }
}
