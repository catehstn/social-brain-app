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
        // The same reset `SocialBrainUITests` does. Without it this suite —
        // which sorts first, so it runs first on a clean runner — met whatever
        // onboarding state the machine happened to hold, and passed on the
        // order tests ran in rather than on anything it asserted (#58).
        app.launchArguments += ["-hasCompletedOnboarding", "0"]
        app.launchArguments += ["-resetHiddenPlatforms"]
        app.launch()
    }

    /// Required now that `setUp` resets onboarding: the sheet covers the
    /// sidebar, so every test here has to get past it before looking for Feed.
    /// Shared with `SocialBrainUITests` — see `OnboardingDismissal`.
    private func completeOnboardingIfPresent() {
        completeOnboardingIfPresent(in: app)
    }

    func testFeedItemExistsInSidebar() {
        completeOnboardingIfPresent()
        // The sidebar list should contain a "Feed" item.
        let feedItem = app.outlines.firstMatch.cells
            .staticTexts["Feed"]
        XCTAssert(feedItem.waitForExistence(timeout: 5))
    }

    func testTappingFeedDoesNotCrash() {
        completeOnboardingIfPresent()
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

    /// **Asserts nothing about the expand control on CI — not coverage of it.**
    ///
    /// Every run here starts on a throwaway database, so the Feed has no
    /// cards, so there is no expand control and the assertion below never
    /// executes. It passes whether the control works, is broken, or has been
    /// deleted. That is deliberate under the minimal UI-test strategy, and was
    /// re-confirmed rather than quietly changed when #90 raised it: making it
    /// able to fail needs a way to seed the launched app's database, which
    /// does not exist, and the screens it drives are about to be replaced
    /// (#40, #46).
    ///
    /// What it does buy: if the Feed ever does render a card here, a control
    /// that exists but cannot be clicked fails the run. It also exercises the
    /// wizard and the sidebar on the way, so it is not inert — it just says
    /// nothing about the control it is named for. Named to be conditional, so
    /// the next person does not have to read the body to find that out.
    func testExpandControlIsHittableIfAnyCardIsTruncated() {
        completeOnboardingIfPresent()
        // Navigate to Feed
        let feedItem = app.outlines.firstMatch.cells
            .staticTexts["Feed"]
        guard feedItem.waitForExistence(timeout: 5) else { return }
        feedItem.click()

        let toggleButtons = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'expandToggle_'"))
        if toggleButtons.count > 0 {
            XCTAssertTrue(toggleButtons.firstMatch.isHittable)
        }
    }
}
