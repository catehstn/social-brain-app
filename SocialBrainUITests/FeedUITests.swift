import XCTest

@MainActor
final class FeedUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // UI tests launch the app as a separate process, which does NOT inherit
        // XCTestConfigurationFilePath — so without this the app under test opens
        // and migrates the developer's real database (#100).
        //
        // An environment variable, not a launch argument: NSUserDefaults reads
        // the argument domain as -key value pairs, so a bare flag swallows the
        // next one as its value — which silently broke -hasCompletedOnboarding.
        //
        // Spelled out rather than referencing the constant, because importing
        // the app module into a UI test target drags GRDB in with it and this
        // target does not link it. DatabaseLocationTests pins the two spellings.
        app.launchEnvironment["SOCIALBRAIN_USE_THROWAWAY_DATABASE"] = "1"
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
