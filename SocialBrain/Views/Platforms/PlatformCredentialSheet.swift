import SwiftUI

struct PlatformCredentialSheet: View {
    let instance: PlatformInstance
    let viewModel: PlatformsViewModel

    private var platform: Platform { instance.platform }

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var labelText: String = ""
    @State private var errorMessage: String?
    @State private var isConnecting = false

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
            labelText = InstanceLabels.label(for: instance) ?? ""
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Label")
                    .font(.subheadline)
                    .fontWeight(.medium)
                TextField("Auto-detected from API", text: $labelText)
                    .textFieldStyle(.roundedBorder)
                Text("Shown in the sidebar and prompt. Leave blank to use the auto-detected name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            platformFields
        }
    }

    @ViewBuilder
    private var platformFields: some View {
        switch platform {
        case .buttondown:
            permissionsNote("Permissions needed: read-only — we only read subscriber counts and email stats, never send")
            field("API Key", key: "api_key", secure: true,
                  help: "Find it at buttondown.com/keys",
                  helpURL: URL(string: "https://buttondown.com/keys"))

        case .goatCounter:
            permissionsNote("Permissions needed: Read access")
            field("API Key", key: "api_key", secure: true,
                  help: "Click your username in the top menu → API")
            field("Site Code", key: "site_code",
                  help: "The subdomain of your GoatCounter URL — e.g. \"mysite\" from mysite.goatcounter.com")

        case .vercel:
            permissionsNote("Permissions needed: full account access (tokens have no scope restrictions)")
            field("Personal Access Token", key: "api_key", secure: true,
                  help: "Create one at vercel.com/account/tokens",
                  helpURL: URL(string: "https://vercel.com/account/tokens"))
            field("Project ID or Name", key: "site_code",
                  help: "The Vercel project to track deployments for")
            field("Team ID (optional)", key: "team_id",
                  help: "Required only if the project belongs to a team")

        case .calendly:
            permissionsNote("Permissions needed: user_info_read (for profile) and scheduling_read (for events)")
            field("Personal Access Token", key: "api_key", secure: true,
                  help: "Create one at app.calendly.com/integrations/api_webhooks",
                  helpURL: URL(string: "https://app.calendly.com/integrations/api_webhooks"))

        case .mastodon:
            permissionsNote("Permissions needed: read (grants access to profile and posts)")
            field("Instance URL", key: "instance_url",
                  help: "The base URL of your instance — e.g. https://mastodon.social")
            if let token = values["access_token"], !token.isEmpty {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            Button {
                connectMastodon()
            } label: {
                if isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Sign in with Mastodon", systemImage: "arrow.up.right.square")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting || (values["instance_url"] ?? "").isEmpty)

        case .bluesky:
            permissionsNote("Permissions needed: full access (app passwords have no scope restrictions)")
            field("Handle", key: "username",
                  help: "Your Bluesky handle — e.g. alice.bsky.social")
            field("App Password", key: "password", secure: true,
                  help: "Create one at bsky.app in Settings → Privacy and Security → App Passwords",
                  helpURL: URL(string: "https://bsky.app/settings/app-passwords"))

        case .jetpack:
            permissionsNote("Permissions needed: global scope (required to read stats)")
            field("Client ID", key: "client_id",
                  help: "Create an app at developer.wordpress.com/apps and copy the Client ID",
                  helpURL: URL(string: "https://developer.wordpress.com/apps/"))
            field("Client Secret", key: "client_secret", secure: true)
            field("Site ID or Domain", key: "site_code",
                  help: "Your WordPress.com site ID (numeric) or domain — e.g. 12345678 or myblog.wordpress.com")
            if let token = values["access_token"], !token.isEmpty {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            Button {
                connectWordPress()
            } label: {
                if isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Sign in with WordPress.com", systemImage: "arrow.up.right.square")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting || (values["client_id"] ?? "").isEmpty || (values["client_secret"] ?? "").isEmpty || (values["site_code"] ?? "").isEmpty)

        case .googleSearchConsole:
            permissionsNote("Permissions needed: https://www.googleapis.com/auth/webmasters.readonly")
            field("Client ID", key: "client_id", secure: true,
                  help: "Create OAuth credentials at console.cloud.google.com → APIs & Services → Credentials",
                  helpURL: URL(string: "https://console.cloud.google.com/apis/credentials"))
            field("Client Secret", key: "client_secret", secure: true)
            field("Refresh Token", key: "refresh_token", secure: true,
                  help: "Get one via OAuth 2.0 Playground — select the webmasters.readonly scope",
                  helpURL: URL(string: "https://developers.google.com/oauthplayground/"))
            field("Site URL", key: "site_url",
                  help: "Exactly as shown in Search Console — e.g. https://example.com/ or sc-domain:example.com")

        case .buffer:
            permissionsNote("Permissions needed: read access to profiles and sent updates")
            field("Access Token", key: "api_key", secure: true,
                  help: "Create one at buffer.com/developers/api",
                  helpURL: URL(string: "https://buffer.com/developers/api"))

        case .hackerNews:
            permissionsNote("No authentication required — uses the public Algolia HN Search API")
            field("Domain to Track", key: "site_code",
                  help: "Your domain — e.g. example.com")

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
                    1. Go to linkedin.com/analytics/creator/content (link below)
                    2. Click Export in the top right — the file downloads instantly
                    3. Click Import below to load it (CSV or XLSX accepted)
                    """,
                helpURL: URL(string: "https://www.linkedin.com/analytics/creator/content/?metricType=IMPRESSIONS&timeRange=past_90_days"),
                extensions: ["csv", "xlsx"],
                buttonLabel: "Import File"
            )

        case .oreilly:
            importSection(
                instructions: """
                    1. Find the "Payment Remittance Advice" email from payables@oreilly.com
                    2. In Mail.app: File → Save As → select "Raw Message Source" (.eml)
                    3. Click Import EML below to load it
                    """,
                extensions: ["eml", "txt"],
                buttonLabel: "Import EML"
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

        }
    }

    @ViewBuilder
    private func importSection(
        instructions: String,
        helpURL: URL? = nil,
        extensions: [String],
        buttonLabel: String = "Import File"
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let helpURL {
                Link("Open export page ↗", destination: helpURL)
                    .font(.callout)
            }
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

    private func permissionsNote(_ text: String) -> some View {
        Label(text, systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }

    private func field(
        _ label: String,
        key: String,
        secure: Bool = false,
        help: String? = nil,
        helpURL: URL? = nil
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
                if let helpURL {
                    Link(help, destination: helpURL)
                        .font(.caption)
                } else {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                Button(isFileImportPlatform ? "Remove Data" : "Remove Credentials", role: .destructive) {
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
            // File-import and OAuth platforms complete via buttons in the form body.
            if !isFileImportPlatform && !isOAuthPlatform {
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

    private var isOAuthPlatform: Bool {
        platform == .mastodon || platform == .jetpack
    }

    private var canSave: Bool {
        requiredKeys.allSatisfy { !(values[$0] ?? "").isEmpty }
    }

    /// Keys that must be non-empty for the Save button to enable.
    private var requiredKeys: [String] {
        switch platform {
        case .buttondown:          ["api_key"]
        case .goatCounter:         ["api_key", "site_code"]
        case .vercel:              ["api_key", "site_code"]
        case .calendly:            ["api_key"]
        case .mastodon:            ["access_token", "instance_url"]
        case .bluesky:             ["username", "password"]
        case .jetpack:             ["client_id", "client_secret", "site_code"]
        case .googleSearchConsole: ["client_id", "client_secret", "refresh_token", "site_url"]
        case .buffer:              ["api_key"]
        case .hackerNews:          ["site_code"]
        default:                   []
        }
    }

    // MARK: - OAuth

    @MainActor
    private func connectMastodon() {
        let rawURL = (values["instance_url"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !rawURL.isEmpty else { errorMessage = "Enter your instance URL first."; return }
        let urlString = rawURL.hasPrefix("http") ? rawURL : "https://\(rawURL)"
        guard let instanceURL = URL(string: urlString) else {
            errorMessage = "The instance URL is not valid."
            return
        }
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                let token = try await MastodonOAuth.authenticate(instanceURL: instanceURL)
                values["access_token"] = token
                save()
            } catch OAuthError.cancelled {
                // user dismissed the browser — no-op
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func connectWordPress() {
        guard let clientID = values["client_id"], !clientID.isEmpty,
              let clientSecret = values["client_secret"], !clientSecret.isEmpty else {
            errorMessage = "Enter your Client ID and Client Secret first."
            return
        }
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                let token = try await WordPressOAuth.authenticate(clientID: clientID, clientSecret: clientSecret)
                values["access_token"] = token
                save()
            } catch OAuthError.cancelled {
                // user dismissed the browser — no-op
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Save

    private func save() {
        // Strip empty optional fields so they're not stored as empty strings.
        let filtered = values.filter { !$0.value.isEmpty }
        do {
            try viewModel.save(filtered, for: instance)
            // Persist manual label, or clear so auto-fetch can run.
            let trimmed = labelText.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                InstanceLabels.removeLabel(for: instance)
            } else {
                InstanceLabels.setLabel(trimmed, for: instance)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
