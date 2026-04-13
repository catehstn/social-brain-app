import SwiftUI
import WebKit

/// A sheet that renders the bundled setup-guide.html inside the app.
///
/// All `https://` links in the HTML are intercepted and opened in the user's
/// default browser via NSWorkspace — file:// navigation continues normally so
/// the page itself loads correctly.
struct SetupGuideSheet: View {
    let anchor: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Platform Setup Guide")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            WebGuideView(anchor: anchor)
        }
        .frame(width: 720, height: 580)
    }
}

// MARK: - WKWebView wrapper

private struct WebGuideView: NSViewRepresentable {
    let anchor: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        if let url = guideURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    private var guideURL: URL? {
        guard let base = Bundle.main.url(forResource: "setup-guide", withExtension: "html") else { return nil }
        guard !anchor.isEmpty else { return base }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.fragment = anchor
        return comps.url
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }
            if url.scheme == "https" || url.scheme == "http" {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}
