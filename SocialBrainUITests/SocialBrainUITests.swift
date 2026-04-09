import XCTest

@MainActor
final class SocialBrainUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Reset onboarding state so the wizard always appears on launch.
        app.launchArguments += ["-hasCompletedOnboarding", "0"]
        app.launch()
    }

    // MARK: - Onboarding wizard

    func testOnboardingWizardAppearsOnFirstLaunch() throws {
        // Welcome page should be visible.
        XCTAssert(app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 5))
    }

    func testOnboardingWizardAdvancesToConnectPage() throws {
        XCTAssert(app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssert(app.staticTexts["Connect Your Platforms"].waitForExistence(timeout: 3))
    }

    func testOnboardingWizardBackButtonReturnsToWelcome() throws {
        XCTAssert(app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssert(app.staticTexts["Connect Your Platforms"].waitForExistence(timeout: 3))
        app.buttons["Back"].click()
        XCTAssert(app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 3))
    }

    func testOnboardingWizardCompletesAndDismisses() throws {
        XCTAssert(app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssert(app.staticTexts["Connect Your Platforms"].waitForExistence(timeout: 3))
        app.buttons["Next"].click()
        XCTAssert(app.staticTexts["You're Ready!"].waitForExistence(timeout: 3))
        app.buttons["Get Started"].click()
        // After dismissal, the main window's sidebar should be visible.
        XCTAssert(app.staticTexts["Run"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Welcome to Social Brain"].exists)
    }

    // MARK: - Main run flow

    func testMainWindowShowsRunView() throws {
        // Skip onboarding if it appears.
        if app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 3) {
            app.buttons["Next"].click()
            app.buttons["Next"].click()
            app.buttons["Get Started"].click()
        }
        XCTAssert(app.staticTexts["Run"].waitForExistence(timeout: 5))
    }
}
