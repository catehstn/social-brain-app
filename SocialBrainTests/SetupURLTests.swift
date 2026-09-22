import Testing
import Foundation

/// Verifies that every setup URL used in the credential sheet and setup guide
/// is reachable (returns HTTP 2xx or 3xx).
///
/// This suite makes live network calls, so it is **opt-in**. Every other test in
/// the target is hermetic, and CI must stay that way — a link-rot check that
/// fails because a vendor added bot protection is not a signal about this code.
/// It passes: all seven URLs answered 2xx/3xx on a normal network on
/// 2026-09-22, developer.wordpress.com included. #60 recorded it as failing,
/// and part of that was an environment — a sandboxed shell produced timeouts
/// and `-1004`s that were not link rot. The 403 that issue reports from
/// developer.wordpress.com did not reproduce.
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
        // File-export platforms
        ("O'Reilly",                   "https://www.oreilly.com"),
    ]

    /// Help URLs the sheet offers that this suite deliberately does not fetch.
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

// MARK: - Drift between the sheet and the list above

/// Not network-gated, deliberately: this reads source, and it is the half of
/// #60 that can run on every PR.
///
/// The reachability suite above only checks the URLs it already knows. A help
/// URL added to `PlatformCredentialSheet` and not added there is simply never
/// checked, which is how the list came to include a platform that had been
/// retired while missing a URL that had changed.
@Suite("Setup URL coverage")
struct SetupURLCoverageTests {

    /// Every `helpURL:` literal in the credential sheet.
    private static func sheetURLs() -> [String] {
        let sheet = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SocialBrainTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("SocialBrain/Views/Platforms/PlatformCredentialSheet.swift")
        guard let text = try? String(contentsOf: sheet, encoding: .utf8) else { return [] }

        var found: [String] = []
        for line in text.split(separator: "\n") where line.contains("helpURL: URL(string:") {
            // The literal between the quotes after `URL(string:`.
            guard let afterQuote = line.range(of: "URL(string: \"") else { continue }
            let rest = line[afterQuote.upperBound...]
            guard let closing = rest.firstIndex(of: "\"") else { continue }
            found.append(String(rest[..<closing]))
        }
        return found
    }

    @Test("Every help URL the sheet offers is either checked or excluded with a reason")
    func credentialSheetURLsAreAllAccountedFor() {
        let sheet = Set(Self.sheetURLs())
        #expect(!sheet.isEmpty, "Found no helpURL literals — this detector would pass vacuously")

        let checked = Set(SetupURLTests.setupURLs.map(\.url))
        let excluded = Set(SetupURLTests.notCheckedOverTheNetwork.keys)
        let unaccounted = sheet.subtracting(checked).subtracting(excluded)

        let message: Comment = """
            \(unaccounted.sorted()) appear in PlatformCredentialSheet and in neither \
            SetupURLTests.setupURLs nor notCheckedOverTheNetwork. Add to one or the other; \
            an exclusion needs a reason.
            """
        #expect(unaccounted.isEmpty, message)
    }

    @Test("Nothing is checked that the sheet no longer offers")
    func checkedURLsAreStillOffered() {
        // The mirror image, and the one that actually happened: the list kept
        // a platform after it was retired (#43 removed Vercel), so the suite
        // was spending a request proving a dead link was alive.
        let sheet = Set(Self.sheetURLs())
        guard !sheet.isEmpty else { return }

        // The setup guide offers O'Reilly, which has no credential sheet entry:
        // it is a file-export platform whose URL is where the export lives.
        let notInTheSheet: Set<String> = ["https://www.oreilly.com"]
        let stale = Set(SetupURLTests.setupURLs.map(\.url))
            .subtracting(sheet)
            .subtracting(notInTheSheet)

        let message: Comment = "\(stale.sorted()) are checked but no longer offered by the sheet"
        #expect(stale.isEmpty, message)
    }

    @Test("Every exclusion names a URL the sheet actually offers")
    func exclusionsAreStillReal() {
        // So the exclusion list shrinks as links are fixed, rather than
        // accumulating reasons for URLs nobody offers any more.
        let sheet = Set(Self.sheetURLs())
        guard !sheet.isEmpty else { return }

        let orphaned = Set(SetupURLTests.notCheckedOverTheNetwork.keys).subtracting(sheet)
        let message: Comment = "\(orphaned.sorted()) are excluded from the network check but not offered anywhere"
        #expect(orphaned.isEmpty, message)
    }
}
