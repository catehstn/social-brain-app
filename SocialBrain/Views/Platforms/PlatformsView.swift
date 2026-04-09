import SwiftUI

struct PlatformsView: View {
    @State private var viewModel: PlatformsViewModel
    @State private var editingPlatform: Platform?

    // Platforms with live API collectors
    private let apiKeyPlatforms: [Platform]    = [.buttondown, .goatCounter, .vercel, .calendly]
    private let tokenPlatforms: [Platform]     = [.mastodon, .bluesky]
    // File-export platforms that can be imported from a local file
    private let importPlatforms: [Platform]    = [.amazon, .linkedin, .oreilly, .substack]
    // Platforms with no support yet
    private let comingSoonPlatforms: [Platform] = [.jetpack]

    init(database: AppDatabase) {
        _viewModel = State(wrappedValue: PlatformsViewModel(database: database))
    }

    var body: some View {
        List {
            Section("API Key") {
                ForEach(apiKeyPlatforms) { platform in
                    platformRow(platform)
                }
            }
            Section("Token / App Password") {
                ForEach(tokenPlatforms) { platform in
                    platformRow(platform)
                }
            }
            Section("File Export") {
                ForEach(importPlatforms) { platform in
                    platformRow(platform)
                }
            }
            Section("Coming Soon") {
                ForEach(comingSoonPlatforms) { platform in
                    HStack {
                        Image(systemName: "circle")
                            .foregroundStyle(.tertiary)
                        Text(platform.displayName)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Not yet supported")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.inset)
        .onAppear { viewModel.reload() }
        .sheet(item: $editingPlatform) { platform in
            PlatformCredentialSheet(platform: platform, viewModel: viewModel)
        }
        .navigationTitle("Platforms")
    }

    private func platformRow(_ platform: Platform) -> some View {
        let isConfigured = viewModel.configured.contains(platform)
        return HStack {
            Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isConfigured ? Color.green : Color.secondary)
            Text(platform.displayName)
            Spacer()
            Button(isConfigured ? "Edit" : "Set Up") {
                editingPlatform = platform
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

#Preview {
    PlatformsView(database: try! AppDatabase.makeInMemory())
}
