import SwiftUI

@MainActor
final class FeedCardViewModel: ObservableObject {

    // Binding into FeedViewModel.cards so expand state is shared.
    private var cardBinding: Binding<FeedCard>

    init(card: Binding<FeedCard>) {
        self.cardBinding = card
    }

    var card: FeedCard { cardBinding.wrappedValue }

    var displaySnippet: String {
        card.isExpanded ? card.snippet : FeedCardBuilder.truncate(card.snippet, limit: 100)
    }

    var isTruncated: Bool {
        card.snippet.count > 100
    }

    func toggleExpand() {
        cardBinding.wrappedValue.isExpanded.toggle()
        objectWillChange.send()
    }
}
