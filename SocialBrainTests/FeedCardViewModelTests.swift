import Testing
import SwiftUI
@testable import SocialBrain

@Suite("FeedCardViewModel")
@MainActor
struct FeedCardViewModelTests {

    // Helper: creates a Binding<FeedCard> using a reference-type box.
    // FeedCardViewModel takes a Binding so changes write back to the source.
    private func makeBinding(snippet: String, expanded: Bool = false) -> Binding<FeedCard> {
        // In unit tests there is no SwiftUI environment, so we simulate the
        // binding with a plain variable captured by reference via a class box.
        final class Box: @unchecked Sendable {
            var card: FeedCard
            init(_ card: FeedCard) { self.card = card }
        }
        let box = Box(FeedCard(platform: .mastodon, cardType: .recentPost,
                               snippet: snippet, isExpanded: expanded, navigationTarget: .mastodon))
        return Binding(get: { box.card }, set: { box.card = $0 })
    }

    @Test("displaySnippet is full text when expanded")
    func displaySnippetExpanded() {
        let long = String(repeating: "a", count: 200)
        let vm = FeedCardViewModel(card: makeBinding(snippet: long, expanded: true))
        #expect(vm.displaySnippet == long)
    }

    @Test("displaySnippet is truncated when collapsed")
    func displaySnippetCollapsed() {
        let long = String(repeating: "a ", count: 100) // 200 chars
        let vm = FeedCardViewModel(card: makeBinding(snippet: long))
        #expect(vm.displaySnippet.count <= 105) // 100 + "…"
    }

    @Test("isTruncated is false for short snippets")
    func isTruncatedFalseForShortSnippet() {
        let short = "Short text."
        let vm = FeedCardViewModel(card: makeBinding(snippet: short))
        #expect(vm.isTruncated == false)
    }

    @Test("isTruncated is true for long snippets")
    func isTruncatedTrueForLongSnippet() {
        let long = String(repeating: "word ", count: 30)
        let vm = FeedCardViewModel(card: makeBinding(snippet: long))
        #expect(vm.isTruncated == true)
    }

    @Test("toggleExpand flips isExpanded and writes back to binding source")
    func toggleExpandFlipsIsExpandedAndWritesBackToBinding() {
        let binding = makeBinding(snippet: "Test")
        let vm = FeedCardViewModel(card: binding)
        #expect(binding.wrappedValue.isExpanded == false)
        vm.toggleExpand()
        #expect(binding.wrappedValue.isExpanded == true)
        vm.toggleExpand()
        #expect(binding.wrappedValue.isExpanded == false)
    }
}
