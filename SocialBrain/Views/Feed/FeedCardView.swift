import SwiftUI

struct FeedCardView: View {
    // Binding writes back into FeedViewModel.cards — avoids stale local copy.
    @Binding var card: FeedCard
    @State private var vm: FeedCardViewModel

    init(card: Binding<FeedCard>) {
        self._card = card
        _vm = State(wrappedValue: FeedCardViewModel(card: card))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(vm.card.platform.displayName,
                      systemImage: platformIcon(vm.card.platform))
                    .font(.headline)
                Spacer()
                Text(vm.card.cardType.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(vm.displaySnippet)
                .font(.body)
                .lineLimit(vm.card.isExpanded ? nil : 3)

            if vm.isTruncated {
                Button(vm.card.isExpanded ? "Show less" : "Show more") {
                    vm.toggleExpand()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .accessibilityIdentifier("expandToggle_\(vm.card.id)")
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private func platformIcon(_ platform: Platform) -> String {
        switch platform {
        case .mastodon:    return "bubble.left"
        case .bluesky:     return "cloud"
        case .buttondown:  return "envelope"
        case .goatCounter: return "chart.line.uptrend.xyaxis"
        case .vercel:      return "server.rack"
        case .calendly:    return "calendar"
        case .amazon:      return "shippingbox"
        case .jetpack:     return "bolt"
        case .linkedin:    return "person.crop.square"
        case .oreilly:     return "book"
        case .substack:            return "newspaper"
        case .googleSearchConsole: return "magnifyingglass"
        }
    }
}
