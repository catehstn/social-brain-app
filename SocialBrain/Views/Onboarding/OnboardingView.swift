import SwiftUI

/// A multi-step onboarding wizard shown on the first launch.
///
/// Steps:
/// 1. Welcome — what Social Brain does
/// 2. Goal — what the user is trying to achieve
/// 3. Connect — overview of platform groups
/// 4. Ready — confirmation and next steps
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var step: Step = .welcome
    @State private var selectedGoal: AnalyticsGoal = AnalyticsGoal.current
    @State private var customGoalText: String = AnalyticsGoal.customText
    @State private var showGuide = false
    @State private var guideAnchor = ""

    enum Step { case welcome, goal, connect, ready }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
        .sheet(isPresented: $showGuide) {
            SetupGuideSheet(anchor: guideAnchor)
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomePage
        case .goal:    goalPage
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

    private var goalPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("What's Your Goal?")
                .font(.title2.bold())

            Text("This helps Claude focus its analysis on what matters most to you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(AnalyticsGoal.allCases, id: \.self) { goal in
                    Button {
                        selectedGoal = goal
                    } label: {
                        HStack {
                            Image(systemName: selectedGoal == goal
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedGoal == goal ? Color.accentColor : Color.secondary)
                            Text(goal.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedGoal == goal
                                      ? Color.accentColor.opacity(0.1)
                                      : Color.secondary.opacity(0.07))
                        )
                    }
                    .buttonStyle(.plain)
                }

                if selectedGoal == .other {
                    TextField("Describe your goal…", text: $customGoalText)
                        .textFieldStyle(.roundedBorder)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
    }

    private var connectPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Your Platforms")
                .font(.title2.bold())
                .padding(.bottom, 2)

            platformGroup(
                icon: "key",
                title: "API Key",
                color: .blue,
                platforms: "Buttondown, GoatCounter, Vercel, Calendly",
                detail: "Paste an API key from each platform's settings page.",
                docsAnchor: "api-key"
            )

            platformGroup(
                icon: "person.badge.key",
                title: "Access Token / App Password / OAuth",
                color: .purple,
                platforms: "Mastodon, Bluesky, Jetpack, Google Search Console",
                detail: "Create a token or app password in each platform's developer settings.",
                docsAnchor: "access-token"
            )

            platformGroup(
                icon: "doc.badge.arrow.up",
                title: "File Export",
                color: .orange,
                platforms: "Substack, Amazon KDP, LinkedIn, O'Reilly",
                detail: "Download a CSV or TSV export from each platform and import it here.",
                docsAnchor: "file-export"
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
        detail: String,
        docsAnchor: String
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
                HStack(spacing: 6) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Setup guide ↗") {
                        openSetupGuide(anchor: docsAnchor)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
                }
            }
        }
    }

    private func openSetupGuide(anchor: String) {
        guideAnchor = anchor
        showGuide = true
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
            if step != .welcome {
                Button("Back") { stepBack() }
            }

            Spacer()
            HStack(spacing: 6) {
                ForEach([Step.welcome, .goal, .connect, .ready], id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()

            Button(step == .ready ? "Get Started" : "Next") {
                if step == .ready {
                    saveGoal()
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
            case .welcome: step = .goal
            case .goal:    step = .connect
            case .connect: step = .ready
            case .ready:   saveGoal(); onComplete()
            }
        }
    }

    private func stepBack() {
        withAnimation {
            switch step {
            case .welcome: break
            case .goal:    step = .welcome
            case .connect: step = .goal
            case .ready:   step = .connect
            }
        }
    }

    private func saveGoal() {
        AnalyticsGoal.current = selectedGoal
        AnalyticsGoal.customText = customGoalText
    }
}

// MARK: - Step: RawRepresentable for dot indicators

extension OnboardingView.Step: RawRepresentable {
    var rawValue: Int {
        switch self { case .welcome: 0; case .goal: 1; case .connect: 2; case .ready: 3 }
    }
    init?(rawValue: Int) {
        switch rawValue {
        case 0: self = .welcome
        case 1: self = .goal
        case 2: self = .connect
        case 3: self = .ready
        default: return nil
        }
    }
}

#Preview {
    OnboardingView(onComplete: {})
}
