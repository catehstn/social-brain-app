import XCTest

@MainActor
final class SocialBrainUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        // Reset onboarding state so the wizard always appears on launch.
        app.launchArguments += ["-hasCompletedOnboarding", "0"]
        // Reset hidden-platform state so grid tests always start with all platforms visible.
        app.launchArguments += ["-resetHiddenPlatforms"]
        app.launch()
    }

    // MARK: - Onboarding wizard

    func testOnboardingWizardAppearsOnFirstLaunch() throws {
        // Welcome page should be visible.
        XCTAssert(app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 5))
    }

    func testOnboardingWizardAdvancesToGoalPage() throws {
        XCTAssert(app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssert(app.staticTexts["What's Your Goal?"].waitForExistence(timeout: 3))
    }

    func testOnboardingWizardAdvancesToConnectPage() throws {
        XCTAssert(app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssert(app.staticTexts["What's Your Goal?"].waitForExistence(timeout: 3))
        app.buttons["Next"].click()
        XCTAssert(app.staticTexts["Connect Your Platforms"].waitForExistence(timeout: 3))
    }

    func testOnboardingWizardBackButtonReturnsToWelcome() throws {
        XCTAssert(app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssert(app.staticTexts["What's Your Goal?"].waitForExistence(timeout: 3))
        app.buttons["Back"].click()
        XCTAssert(app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 3))
    }

    func testOnboardingWizardCompletesAndDismisses() throws {
        XCTAssert(app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssert(app.staticTexts["What's Your Goal?"].waitForExistence(timeout: 3))
        app.buttons["Next"].click()
        XCTAssert(app.staticTexts["Connect Your Platforms"].waitForExistence(timeout: 3))
        app.buttons["Next"].click()
        XCTAssert(app.staticTexts["You're Ready!"].waitForExistence(timeout: 3))
        app.buttons["Get Started"].click()
        // After dismissal, the main window's sidebar should be visible.
        XCTAssert(app.staticTexts["Run"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Welcome to Social Brain"].exists)
    }

    // MARK: - Helpers

    /// Clicks through the wizard when it appears. The wizard has four steps —
    /// welcome, goal, connect, ready — so this is three Nexts, then Get Started.
    /// Keep in step with `OnboardingView.Step`.
    private func completeOnboardingIfPresent() {
        guard app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 3) else { return }
        app.buttons["Next"].click()
        app.buttons["Next"].click()
        app.buttons["Next"].click()
        app.buttons["Get Started"].click()
    }

    // MARK: - Main run flow

    func testMainWindowShowsRunView() throws {
        completeOnboardingIfPresent()
        XCTAssert(app.staticTexts["Run"].waitForExistence(timeout: 5))
    }

    // MARK: - Platforms navigation helpers

    /// Skips onboarding and navigates to the Platforms pane.
    private func navigateToPlatforms() {
        completeOnboardingIfPresent()
        // Click Platforms in the sidebar
        let platformsItem = app.outlines.cells["Platforms"]
        if platformsItem.waitForExistence(timeout: 5) {
            platformsItem.click()
        } else {
            // Fallback: try static text in sidebar
            app.staticTexts["Platforms"].click()
        }
    }

    // MARK: - Platforms grid tests

    // Test 1: Platforms navigation smoke
    func testPlatformsGridLoads() throws {
        throw XCTSkip("Platforms grid UI tests assert iOS-style navigationBars, which macOS SwiftUI does not produce. They have never passed — CI reported success without building when they were written. To be rewritten with the Platforms redesign, issue #40.")
        navigateToPlatforms()
        XCTAssert(app.staticTexts["Platforms"].waitForExistence(timeout: 5))
        XCTAssert(app.staticTexts["Buttondown"].waitForExistence(timeout: 3))
        XCTAssert(app.images["envelope.fill"].waitForExistence(timeout: 3))
    }

    // Test 2: Card tap pushes to detail view
    func testCardTapPushesToDetailView() throws {
        throw XCTSkip("Platforms grid UI tests assert iOS-style navigationBars, which macOS SwiftUI does not produce. They have never passed — CI reported success without building when they were written. To be rewritten with the Platforms redesign, issue #40.")
        navigateToPlatforms()
        XCTAssert(app.staticTexts["Buttondown"].waitForExistence(timeout: 5))
        app.staticTexts["Buttondown"].click()
        XCTAssert(app.navigationBars["Buttondown"].waitForExistence(timeout: 3))
        // Back button labeled "Platforms" should exist
        XCTAssert(app.buttons["Platforms"].exists)
    }

    // Test 3: Back button returns to grid
    func testBackButtonReturnsToGrid() throws {
        throw XCTSkip("Platforms grid UI tests assert iOS-style navigationBars, which macOS SwiftUI does not produce. They have never passed — CI reported success without building when they were written. To be rewritten with the Platforms redesign, issue #40.")
        navigateToPlatforms()
        XCTAssert(app.staticTexts["Buttondown"].waitForExistence(timeout: 5))
        app.staticTexts["Buttondown"].click()
        XCTAssert(app.navigationBars["Buttondown"].waitForExistence(timeout: 3))
        app.buttons["Platforms"].click()
        XCTAssert(app.staticTexts["Buttondown"].waitForExistence(timeout: 3))
        XCTAssert(app.staticTexts["GoatCounter"].exists)
    }

    // Test 4: Hide platform removes card from grid
    func testHidePlatformRemovesCardFromGrid() throws {
        throw XCTSkip("Platforms grid UI tests assert iOS-style navigationBars, which macOS SwiftUI does not produce. They have never passed — CI reported success without building when they were written. To be rewritten with the Platforms redesign, issue #40.")
        navigateToPlatforms()
        XCTAssert(app.staticTexts["Buttondown"].waitForExistence(timeout: 5))
        app.staticTexts["Buttondown"].click()
        XCTAssert(app.navigationBars["Buttondown"].waitForExistence(timeout: 3))
        app.buttons["Hide Buttondown"].click()
        app.buttons["Platforms"].click()
        // Card should be gone from active grid
        XCTAssertFalse(app.staticTexts["Buttondown"].waitForExistence(timeout: 2))
        // Toolbar show-dismissed button should be visible (dimmed, but present)
        XCTAssert(
            app.buttons["Show dismissed"].exists ||
            app.toolbars.buttons.matching(NSPredicate(format: "title CONTAINS 'dismissed'")).firstMatch.exists
        )
    }

    // Test 5: Show hidden platform restores card
    func testShowHiddenPlatformRestoresCard() throws {
        throw XCTSkip("Platforms grid UI tests assert iOS-style navigationBars, which macOS SwiftUI does not produce. They have never passed — CI reported success without building when they were written. To be rewritten with the Platforms redesign, issue #40.")
        navigateToPlatforms()
        // Hide Buttondown first
        if app.staticTexts["Buttondown"].waitForExistence(timeout: 5) {
            app.staticTexts["Buttondown"].click()
            if app.navigationBars["Buttondown"].waitForExistence(timeout: 3) {
                app.buttons["Hide Buttondown"].click()
                app.buttons["Platforms"].click()
            }
        }
        // Toggle show-hidden toolbar button
        let showDismissedButton = app.toolbars.buttons["Show dismissed"]
        if showDismissedButton.waitForExistence(timeout: 2) {
            showDismissedButton.click()
        } else {
            // Try by image identifier
            app.toolbars.buttons.matching(NSPredicate(format: "title CONTAINS 'dismissed'")).firstMatch.click()
        }
        // Wait for dimmed card and click Show
        XCTAssert(app.buttons["Show"].waitForExistence(timeout: 3))
        app.buttons["Show"].firstMatch.click()
        // Card should be restored
        XCTAssert(app.staticTexts["Buttondown"].waitForExistence(timeout: 3))
    }
}
