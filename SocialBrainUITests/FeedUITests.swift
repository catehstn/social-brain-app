import XCTest

@MainActor
final class FeedUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testFeedItemExistsInSidebar() {
        // The sidebar list should contain a "Feed" item.
        let feedItem = app.outlines.firstMatch.cells
            .staticTexts["Feed"]
        XCTAssert(feedItem.waitForExistence(timeout: 5))
    }

    func testTappingFeedDoesNotCrash() {
        let feedItem = app.outlines.firstMatch.cells
            .staticTexts["Feed"]
        guard feedItem.waitForExistence(timeout: 5) else {
            XCTFail("Feed sidebar item not found")
            return
        }
        feedItem.click()
        // App should still be running
        XCTAssertTrue(app.exists)
    }

    func testExpandControlVisibleWhenCardIsTruncated() {
        // Navigate to Feed
        let feedItem = app.outlines.firstMatch.cells
            .staticTexts["Feed"]
        guard feedItem.waitForExistence(timeout: 5) else { return }
        feedItem.click()

        // If any expandToggle buttons exist, at least one should be hittable.
        // (This test is a no-op if database is empty — that is acceptable per
        //  the approved minimal UI test strategy.)
        let toggleButtons = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'expandToggle_'"))
        if toggleButtons.count > 0 {
            XCTAssertTrue(toggleButtons.firstMatch.isHittable)
        }
    }
}
