import Testing
@testable import SocialBrain

@Suite("Platform SF Symbol Tests")
struct PlatformSFSymbolTests {

    // All platforms have a non-empty SF Symbol
    @Test("All platforms have non-empty sfSymbol")
    func testAllPlatformsHaveSFSymbol() {
        for platform in Platform.allCases {
            #expect(!platform.sfSymbol.isEmpty, "Platform \(platform.rawValue) has empty sfSymbol")
        }
        // The list itself is pinned in RetiredPlatformDataTests, which subsumes
        // a bare count — two pins would just be two things to update.
        #expect(!Platform.allCases.isEmpty)
    }

    // Test 16: Specific symbol assignments match spec
    @Test("Specific platforms have correct SF Symbol assignments")
    func testSpecificSymbolAssignments() {
        #expect(Platform.buttondown.sfSymbol == "envelope.fill")
        #expect(Platform.goatCounter.sfSymbol == "chart.bar.fill")
        #expect(Platform.mastodon.sfSymbol == "bubble.left.and.bubble.right.fill")
        #expect(Platform.hackerNews.sfSymbol == "flame.fill")
    }

    // Test 17: AuthType.displayName — all four cases have non-empty display names
    @Test("All AuthType cases have non-empty displayName")
    func testAuthTypeDisplayNames() {
        let allCases: [AuthType] = [.apiKey, .oauthToken, .fileExport, .noAuth]
        for authType in allCases {
            #expect(!authType.displayName.isEmpty, "AuthType has empty displayName")
        }
    }
}
