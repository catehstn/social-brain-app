import SwiftUI
import UniformTypeIdentifiers

struct PlatformsView: View {
    @State private var viewModel: PlatformsViewModel
    @State private var editingInstance: PlatformInstance?
    @State private var addingInstanceFor: Platform?
    @State private var newInstanceLabel: String = ""
    @State private var dropTargeted = false
    @State private var dropErrorMessage: String?

    // Platforms with live API collectors
    private let apiKeyPlatforms: [Platform]    = [.buttondown, .goatCounter, .vercel, .calendly]
    private let tokenPlatforms: [Platform]     = [.mastodon, .bluesky, .jetpack]
    // File-export platforms that can be imported from a local file
    private let importPlatforms: [Platform]    = [.amazon, .linkedin, .oreilly, .substack]
    // Platforms with no support yet
    private let comingSoonPlatforms: [Platform] = []

    init(database: AppDatabase) {
        _viewModel = State(wrappedValue: PlatformsViewModel(database: database))
    }

    var body: some View {
        List {
            Section("API Key") {
                ForEach(apiKeyPlatforms) { platform in
                    platformSection(platform)
                }
            }
            Section("Token / App Password") {
                ForEach(tokenPlatforms) { platform in
                    platformSection(platform)
                }
            }
            Section("File Export") {
                ForEach(importPlatforms) { platform in
                    platformSection(platform)
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
        .sheet(item: $editingInstance) { inst in
            PlatformCredentialSheet(instance: inst, viewModel: viewModel)
        }
        .sheet(item: $addingInstanceFor) { platform in
            addInstanceSheet(for: platform)
        }
        .alert("Import Error", isPresented: Binding(
            get: { dropErrorMessage != nil },
            set: { if !$0 { dropErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { dropErrorMessage = nil }
        } message: {
            if let msg = dropErrorMessage { Text(msg) }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 10)))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.largeTitle)
                            Text("Drop to import")
                                .font(.headline)
                        }
                        .foregroundStyle(Color.accentColor)
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    do {
                        try await viewModel.handleDroppedFile(at: url)
                    } catch ImportError.cancelled {
                        // no-op
                    } catch {
                        dropErrorMessage = error.localizedDescription
                    }
                }
            }
            return true
        }
        .navigationTitle("Platforms")
    }

    // MARK: - Platform section (one or more instances)

    @ViewBuilder
    private func platformSection(_ platform: Platform) -> some View {
        let instances = viewModel.configuredInstances[platform] ?? []
        if instances.isEmpty {
            // Not configured yet — show a single Set Up row
            HStack {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                Text(platform.displayName)
                Spacer()
                Button("Set Up") {
                    editingInstance = PlatformInstance(platform: platform)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            // Show each configured instance
            ForEach(instances.map { PlatformInstance(platform: platform, instanceName: $0) }) { inst in
                instanceRow(inst)
            }
            // "Add another" button (not shown for file-export platforms)
            if platform.authType != .fileExport {
                Button("+ Add another \(platform.displayName)") {
                    newInstanceLabel = ""
                    addingInstanceFor = platform
                }
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
            }
        }
    }

    private func instanceRow(_ instance: PlatformInstance) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(instance.platform.displayName)
                if let label = InstanceLabels.label(for: instance) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if instance.instanceName != "default" {
                    Text(instance.instanceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Edit") {
                editingInstance = instance
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Add-instance sheet

    @ViewBuilder
    private func addInstanceSheet(for platform: Platform) -> some View {
        VStack(spacing: 20) {
            Text("Add another \(platform.displayName)")
                .font(.headline)
            TextField("Name this connection (e.g. my-blog)", text: $newInstanceLabel)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Button("Cancel") { addingInstanceFor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let label = newInstanceLabel.trimmingCharacters(in: .whitespaces)
                    guard !label.isEmpty else { return }
                    viewModel.addInstance(label: label, to: platform)
                    let inst = PlatformInstance(platform: platform, instanceName: label)
                    addingInstanceFor = nil
                    editingInstance = inst
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(newInstanceLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(30)
        .frame(width: 380)
    }
}

#Preview {
    PlatformsView(database: try! AppDatabase.makeInMemory())
}
