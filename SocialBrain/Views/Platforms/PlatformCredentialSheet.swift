import SwiftUI

struct PlatformCredentialSheet: View {
    let instance: PlatformInstance
    let viewModel: PlatformsViewModel

    private var platform: Platform { instance.platform }

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
            values = viewModel.loadValues(for: instance)
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack {
            Text(instance.displayName)
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

        case .jetpack:
            field("WordPress.com Access Token", key: "access_token", secure: true,
                  help: "Create one at developer.wordpress.com/apps/ — use the 'Test Application' flow to get a token for your own site")
            field("Site ID or Domain", key: "site_code",
                  help: "Your WordPress.com site ID (numeric) or domain — e.g. 12345678 or myblog.wordpress.com")

        case .amazon:
            importSection(
                instructions: """
                    1. Sign in to KDP (kdp.amazon.com) → Reports → Prior Months' Royalties
                    2. Select the month range and click Download
                    3. Click Import TSV below to load the file
                    """,
                extensions: ["tsv", "txt", "csv"],
                buttonLabel: "Import TSV"
            )

        case .linkedin:
            importSection(
                instructions: """
                    1. Go to LinkedIn Settings → Data Privacy → Get a copy of your data
                    2. Request an archive and wait for the download email (usually minutes)
                    3. Extract the ZIP — find "Share Statistics.csv" inside
                    4. Click Import CSV below to load it
                    """,
                extensions: ["csv"],
                buttonLabel: "Import CSV"
            )

        case .oreilly:
            importSection(
                instructions: """
                    1. Save your monthly O'Reilly author report email as a plain-text .txt file
                       (in Mail.app: File → Save As → Plain Text, or copy the email body to a text file)
                    2. Click Import TXT below to load it
                    """,
                extensions: ["txt", "text", "eml"],
                buttonLabel: "Import TXT"
            )

        case .substack:
            importSection(
                instructions: """
                    1. Go to your Substack dashboard → Settings → Exports
                    2. Under "Email analytics", download the CSV export
                    3. Click Import CSV below to load it
                    """,
                extensions: ["csv"],
                buttonLabel: "Import CSV"
            )

        default:
            Text("This platform is not yet supported.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func importSection(
        instructions: String,
        extensions: [String],
        buttonLabel: String = "Import File"
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                Task {
                    do {
                        try await viewModel.importFile(for: instance, allowedExtensions: extensions)
                        dismiss()
                    } catch ImportError.cancelled {
                        // User dismissed the panel — no-op
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Label(buttonLabel, systemImage: "doc.badge.plus")
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
            let isConfigured = (viewModel.configuredInstances[platform] ?? []).contains(instance.instanceName)
            if isConfigured {
                Button("Remove Credentials", role: .destructive) {
                    Task {
                        do {
                            try await viewModel.delete(for: instance)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
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
        case .amazon, .linkedin, .oreilly, .substack: true
        default:                                      false
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
        case .jetpack:     ["access_token", "site_code"]
        default:           []
        }
    }

    // MARK: - Save

    private func save() {
        // Strip empty optional fields so they're not stored as empty strings.
        let filtered = values.filter { !$0.value.isEmpty }
        do {
            try viewModel.save(filtered, for: instance)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
