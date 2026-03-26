import SwiftUI

struct PlatformCredentialSheet: View {
    let platform: Platform
    let viewModel: PlatformsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            ScrollView {
                formContent
                    .padding(20)
            }
            Divider()
            sheetFooter
        }
        .frame(width: 480)
        .onAppear {
            values = viewModel.loadValues(for: platform)
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack {
            Text(platform.displayName)
                .font(.headline)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    // MARK: - Form

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            platformFields
        }
    }

    @ViewBuilder
    private var platformFields: some View {
        switch platform {
        case .buttondown:
            field("API Key", key: "api_key", secure: true,
                  help: "Find it at buttondown.com/settings/api")

        case .goatCounter:
            field("API Key", key: "api_key", secure: true,
                  help: "Find it in your GoatCounter account settings")
            field("Site Code", key: "site_code",
                  help: "Your GoatCounter subdomain — e.g. \"mysite\" from mysite.goatcounter.com")

        case .vercel:
            field("Personal Access Token", key: "api_key", secure: true,
                  help: "Create one at vercel.com/account/tokens")
            field("Project ID or Name", key: "site_code",
                  help: "The Vercel project to track deployments for")
            field("Team ID (optional)", key: "team_id",
                  help: "Required only if the project belongs to a team")

        case .calendly:
            field("Personal Access Token", key: "api_key", secure: true,
                  help: "Create one at calendly.com/integrations/api_webhooks")

        case .mastodon:
            field("Instance URL", key: "instance_url",
                  help: "The base URL of your instance — e.g. https://mastodon.social")
            field("Access Token", key: "access_token", secure: true,
                  help: "Create one in your instance's Settings → Development → New application")

        case .bluesky:
            field("Handle", key: "username",
                  help: "Your Bluesky handle — e.g. alice.bsky.social")
            field("App Password", key: "password", secure: true,
                  help: "Create one in Settings → Privacy and Security → App Passwords")

        case .substack:
            importSection(
                instructions: """
                    1. Go to your Substack dashboard → Settings → Exports
                    2. Under "Email analytics", download the CSV export
                    3. Click Import CSV below to load it
                    """,
                extensions: ["csv"]
            )

        default:
            Text("This platform is not yet supported.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func importSection(instructions: String, extensions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                Task {
                    do {
                        try await viewModel.importFile(for: platform, allowedExtensions: extensions)
                        dismiss()
                    } catch ImportError.cancelled {
                        // User dismissed the panel — no-op
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Label("Import CSV", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func field(
        _ label: String,
        key: String,
        secure: Bool = false,
        help: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
            Group {
                if secure {
                    SecureField(label, text: binding(for: key))
                } else {
                    TextField(label, text: binding(for: key))
                }
            }
            .textFieldStyle(.roundedBorder)
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        HStack {
            if viewModel.configured.contains(platform) {
                Button("Remove Credentials", role: .destructive) {
                    do {
                        try viewModel.delete(for: platform)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Spacer()
            // File-import platforms complete via the Import button in the form body.
            if !isFileImportPlatform {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding()
    }

    private var isFileImportPlatform: Bool {
        switch platform {
        case .substack: true
        default:        false
        }
    }

    private var canSave: Bool {
        requiredKeys.allSatisfy { !(values[$0] ?? "").isEmpty }
    }

    /// Keys that must be non-empty for the Save button to enable.
    private var requiredKeys: [String] {
        switch platform {
        case .buttondown:  ["api_key"]
        case .goatCounter: ["api_key", "site_code"]
        case .vercel:      ["api_key", "site_code"]
        case .calendly:    ["api_key"]
        case .mastodon:    ["access_token", "instance_url"]
        case .bluesky:     ["username", "password"]
        default:           []
        }
    }

    // MARK: - Save

    private func save() {
        // Strip empty optional fields so they're not stored as empty strings.
        let filtered = values.filter { !$0.value.isEmpty }
        do {
            try viewModel.save(filtered, for: platform)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
