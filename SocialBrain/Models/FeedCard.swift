import Foundation

struct FeedCard: Identifiable, Sendable {
    let id: UUID
    let platform: Platform
    /// The instance name associated with this card; `"default"` for single-instance setups.
    let instanceName: String
    let cardType: FeedCardType
    let snippet: String          // max ~280 chars, word-boundary truncated
    var isExpanded: Bool         // toggled by user; defaults false
    let navigationTarget: Platform

    init(
        id: UUID = UUID(),
        platform: Platform,
        instanceName: String = "default",
        cardType: FeedCardType,
        snippet: String,
        isExpanded: Bool = false,
        navigationTarget: Platform
    ) {
        self.id = id
        self.platform = platform
        self.instanceName = instanceName
        self.cardType = cardType
        self.snippet = snippet
        self.isExpanded = isExpanded
        self.navigationTarget = navigationTarget
    }
}
