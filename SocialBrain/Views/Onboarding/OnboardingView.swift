import SwiftUI

/// A multi-step onboarding wizard shown on the first launch.
///
/// The wizard walks the user through:
/// 1. Welcome — what Social Brain does
/// 2. Connect — an overview of the available platform groups with quick-setup hints
/// 3. Ready — confirmation and next steps
///
/// Shown as a sheet from `ContentView` when `hasCompletedOnboarding` is false.
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var step: Step = .welcome

    enum Step { case welcome, connect, ready }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 460)
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomePage
        case .connect: connectPage
        case .ready:   readyPage
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Welcome to Social Brain")
                .font(.largeTitle.bold())

            Text("""
                Social Brain collects analytics from all your publishing \
                platforms — newsletters, blogs, social media, and more — \
                and assembles them into a single prompt you can paste into \
                Claude for AI-powered analysis.
                """)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var connectPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Your Platforms")
                .font(.title2.bold())
                .padding(.bottom, 4)

            platformGroup(
                icon: "key",
                title: "API Key",
                color: .blue,
                platforms: "Buttondown, GoatCounter, Vercel, Calendly",
                detail: "Paste an API key from each platform's settings page."
            )

            platformGroup(
                icon: "person.badge.key",
                title: "Access Token / App Password",
                color: .purple,
                platforms: "Mastodon, Bluesky, Jetpack",
                detail: "Create a token or app password in each platform's developer settings."
            )

            platformGroup(
                icon: "doc.badge.arrow.up",
                title: "File Export",
                color: .orange,
                platforms: "Substack, Amazon KDP, LinkedIn, O'Reilly",
                detail: "Download a CSV or TSV export from each platform and import it here."
            )

            Text("You can set up any platform at any time from the Platforms sidebar.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
    }

    private var readyPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("You're Ready!")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 10) {
                step3Hint(icon: "square.grid.2x2",
                          text: "Open **Platforms** in the sidebar to add your first platform.")
                step3Hint(icon: "play.circle",
                          text: "Press **Run** to collect analytics from all configured platforms.")
                step3Hint(icon: "chart.line.uptrend.xyaxis",
                          text: "View trends over time in **Dashboard**.")
                step3Hint(icon: "doc.text",
                          text: "Copy the generated prompt and paste it into **Claude** for analysis.")
            }
            .frame(maxWidth: 380, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Sub-views

    private func platformGroup(
        icon: String,
        title: String,
        color: Color,
        platforms: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(platforms)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func step3Hint(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // Back button (not shown on first page)
            if step != .welcome {
                Button("Back") { stepBack() }
            }

            // Step indicator
            Spacer()
            HStack(spacing: 6) {
                ForEach([Step.welcome, .connect, .ready], id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()

            // Primary action
            Button(step == .ready ? "Get Started" : "Next") {
                if step == .ready {
                    onComplete()
                } else {
                    stepForward()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func stepForward() {
        withAnimation {
            switch step {
            case .welcome: step = .connect
            case .connect: step = .ready
            case .ready:   onComplete()
            }
        }
    }

    private func stepBack() {
        withAnimation {
            switch step {
            case .welcome: break
            case .connect: step = .welcome
            case .ready:   step = .connect
            }
        }
    }
}

// MARK: - Step: RawRepresentable for dot indicators

extension OnboardingView.Step: RawRepresentable {
    var rawValue: Int {
        switch self { case .welcome: 0; case .connect: 1; case .ready: 2 }
    }
    init?(rawValue: Int) {
        switch rawValue {
        case 0: self = .welcome
        case 1: self = .connect
        case 2: self = .ready
        default: return nil
        }
    }
}

#Preview {
    OnboardingView(onComplete: {})
}
