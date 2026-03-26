import SwiftUI

/// The app's Preferences window (⌘,).
///
/// Credential management lives in the main window's Platforms tab.
/// This Settings window surfaces a quick status overview and links
/// to that tab for editing.
struct SettingsView: View {
    @State private var configured: [Platform] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            platformList
        }
        .frame(width: 480, height: 320)
        .onAppear { reload() }
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
    }

    private func reload() {
        configured = Platform.allCases.filter { KeychainStore.hasCredentials(for: $0) }
    }
}

#Preview {
    SettingsView()
}
