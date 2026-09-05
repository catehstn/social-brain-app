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
        // Pinned to catch an addition that misses the sfSymbol switch. 13 since
        // Vercel was retired in #43.
        #expect(Platform.allCases.count == 13)
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
