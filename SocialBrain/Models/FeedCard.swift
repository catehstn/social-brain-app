import Foundation

struct FeedCard: Identifiable, Sendable {
    let id: UUID
    let platform: Platform
    let cardType: FeedCardType
    let snippet: String          // max ~280 chars, word-boundary truncated
    var isExpanded: Bool         // toggled by user; defaults false
    let navigationTarget: Platform

    init(
        id: UUID = UUID(),
        platform: Platform,
        cardType: FeedCardType,
        snippet: String,
        isExpanded: Bool = false,
        navigationTarget: Platform
    ) {
        self.id = id
        self.platform = platform
        self.cardType = cardType
        self.snippet = snippet
        self.isExpanded = isExpanded
        self.navigationTarget = navigationTarget
    }
}
