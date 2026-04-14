import SwiftUI

/// A card representing a single platform in the platforms grid.
struct PlatformCard: View {
    let platform: Platform
    let viewModel: PlatformsViewModel
    var isHiddenCard: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: platform.sfSymbol)
                .font(.system(size: 32))
                .foregroundStyle(isHiddenCard ? .secondary : Color.accentColor)
            Text(platform.displayName)
                .font(.headline)
                .multilineTextAlignment(.center)
            statusView
            if isHiddenCard {
                Button("Show") { viewModel.showPlatform(platform) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
        .opacity(isHiddenCard ? 0.5 : 1)
    }

    @ViewBuilder
    private var statusView: some View {
        let instances = viewModel.configuredInstances[platform] ?? []
        if instances.isEmpty {
            Text("Not set up")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(instances.count == 1 ? "1 account" : "\(instances.count) accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
