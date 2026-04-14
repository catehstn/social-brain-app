import SwiftUI

/// Detail view pushed when a platform card is tapped.
/// Lists configured instances and provides Set Up / Edit / Add Another / Hide actions.
struct PlatformDetailView: View {
    let platform: Platform
    let viewModel: PlatformsViewModel

    @State private var editingInstance: PlatformInstance?
    @State private var addingInstance = false
    @State private var newInstanceLabel = ""

    var body: some View {
        List {
            Section {
                let instances = viewModel.configuredInstances[platform] ?? []
                if instances.isEmpty {
                    Button("Set Up") {
                        editingInstance = PlatformInstance(platform: platform)
                    }
                    .buttonStyle(.bordered)
                } else {
                    ForEach(instances, id: \.self) { instanceName in
                        let inst = PlatformInstance(platform: platform, instanceName: instanceName)
                        instanceRow(inst)
                    }
                    if platform.authType != .fileExport {
                        Button("+ Add another \(platform.displayName)") {
                            newInstanceLabel = ""
                            addingInstance = true
                        }
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Image(systemName: platform.sfSymbol)
                        .foregroundStyle(Color.accentColor)
                    Text("Accounts")
                }
            }

            Section {
                Button("Hide \(platform.displayName)") {
                    viewModel.hidePlatform(platform)
                }
                .foregroundStyle(.secondary)
            } footer: {
                Text("Hides this platform from the grid. Reveal it again with the eye button in the toolbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(platform.displayName)
        .navigationSubtitle(platform.authType.displayName)
        .sheet(item: $editingInstance) { inst in
            PlatformCredentialSheet(instance: inst, viewModel: viewModel)
        }
        .sheet(isPresented: $addingInstance) {
            addInstanceSheet
        }
    }

    private func instanceRow(_ inst: PlatformInstance) -> some View {
        let label = InstanceLabels.label(for: inst)
        let subtitle = label ?? (inst.instanceName != "default" ? inst.instanceName : nil)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle ?? "Default account")
                    .font(.body)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Button("Edit") { editingInstance = inst }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var addInstanceSheet: some View {
        VStack(spacing: 20) {
            Text("Add another \(platform.displayName)").font(.headline)
            TextField("Name this connection (e.g. my-blog)", text: $newInstanceLabel)
                .textFieldStyle(.roundedBorder).frame(width: 300)
            HStack {
                Button("Cancel") { addingInstance = false }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let label = newInstanceLabel.trimmingCharacters(in: .whitespaces)
                    guard !label.isEmpty else { return }
                    viewModel.addInstance(label: label, to: platform)
                    let inst = PlatformInstance(platform: platform, instanceName: label)
                    addingInstance = false
                    editingInstance = inst
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(newInstanceLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(30).frame(width: 380)
    }
}
