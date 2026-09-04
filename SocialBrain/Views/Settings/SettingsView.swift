import SwiftUI

/// The app's Preferences window (⌘,).
struct SettingsView: View {
    @State private var configured: [Platform] = []
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true
    @AppStorage("analyticsGoal") private var goalRaw: String = AnalyticsGoal.growReach.rawValue
    @AppStorage("analyticsGoalCustomText") private var goalCustomText: String = ""

    private var goalLabel: String {
        guard let goal = AnalyticsGoal(rawValue: goalRaw) else { return "—" }
        if goal == .other, !goalCustomText.isEmpty { return goalCustomText }
        return goal.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            goalSection
            Divider()
            header
            Divider()
            platformList
            Divider()
            wizardSection
        }
        .frame(width: 480, height: 400)
        .onAppear { reload() }
    }

    private var goalSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Current Goal")
                    .font(.headline)
                Text(goalLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Change") { hasCompletedOnboarding = false }
                .controlSize(.small)
        }
        .padding()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Configured Platforms")
                .font(.headline)
            Text("To add or edit credentials, open Platforms in the main window sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var platformList: some View {
        List {
            if configured.isEmpty {
                Text("No platforms configured yet.")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(configured) { platform in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(platform.displayName)
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: 160)
    }

    private var wizardSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Setup Wizard")
                    .font(.headline)
                Text("Re-run the setup wizard to update your goal or review platform instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Re-run Wizard") { hasCompletedOnboarding = false }
                .controlSize(.small)
        }
        .padding()
    }

    private func reload() {
        configured = Platform.allCases.filter { KeychainStore.shared.hasCredentials(for: $0) }
    }
}

#Preview {
    SettingsView()
}
