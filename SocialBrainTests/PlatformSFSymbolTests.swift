import Testing
@testable import SocialBrain

@Suite("Platform SF Symbol Tests")
struct PlatformSFSymbolTests {

    // Test 15: All 14 platforms have non-empty SF Symbol
    @Test("All platforms have non-empty sfSymbol")
    func testAllPlatformsHaveSFSymbol() {
        for platform in Platform.allCases {
            #expect(!platform.sfSymbol.isEmpty, "Platform \(platform.rawValue) has empty sfSymbol")
        }
        // Verify the count to catch additions that are missing from sfSymbol switch
        #expect(Platform.allCases.count == 14)
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
