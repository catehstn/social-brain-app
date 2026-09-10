import SwiftUI

/// The app's Preferences window (⌘,).
struct SettingsView: View {
    @State private var configured: [Platform] = []
    @State private var orphaned: [OrphanedCredential] = []
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
            if !orphaned.isEmpty {
                Divider()
                orphanedSection
            }
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

    /// Shown only when there is something to show.
    ///
    /// Retiring a platform leaves its credential in the Keychain under a key
    /// nothing can name any more, so the app could neither display nor remove
    /// it (#118). Surfaced rather than deleted on the user's behalf: the
    /// Keychain item is the lesser half, and quietly removing it would hide the
    /// half that matters — the token is still live at the provider until it is
    /// revoked there.
    private var orphanedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leftover Credentials")
                .font(.headline)
            Text("These belong to platforms Social Brain no longer supports. "
                 + "Removing one here deletes it from your Keychain — it does not "
                 + "revoke the token, which you do at the provider.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(orphaned) { credential in
                HStack {
                    Text(credential.displayName)
                    if let url = credential.revocationURL {
                        Link("Revoke", destination: url)
                            .font(.caption)
                    }
                    Spacer()
                    Button("Remove") { remove(credential) }
                        .controlSize(.small)
                }
            }
        }
        .padding()
    }

    private func remove(_ credential: OrphanedCredential) {
        try? KeychainStore.shared.deleteAccount(credential.id)
        reload()
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
        orphaned = OrphanedCredentials.find(in: (try? KeychainStore.shared.storedAccounts()) ?? [])
    }
}

#Preview {
    SettingsView()
}
