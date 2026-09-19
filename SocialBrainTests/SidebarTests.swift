import Testing
@testable import SocialBrain

@Suite("Sidebar")
struct SidebarTests {

    @Test(".feed case exists in allCases")
    func feedCaseExistsInAllCases() {
        #expect(SidebarItem.allCases.contains(.feed))
    }

    @Test(".feed is positioned between .run and .dashboard")
    func feedPositionedBetweenRunAndDashboard() throws {
        let cases = SidebarItem.allCases
        let runIdx  = try #require(cases.firstIndex(of: .run))
        let feedIdx = try #require(cases.firstIndex(of: .feed))
        let dashIdx = try #require(cases.firstIndex(of: .dashboard))
        #expect(runIdx < feedIdx)
        #expect(feedIdx < dashIdx)
    }
}
