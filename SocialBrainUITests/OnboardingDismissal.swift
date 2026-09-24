import XCTest

/// Clicking past the onboarding wizard, shared by both UI suites.
///
/// Both reset `-hasCompletedOnboarding`, so both meet the wizard covering the
/// sidebar, and both used to carry their own copy of the four clicks. A copy
/// is how the button sequence drifts from `OnboardingView.Step` in one file
/// and not the other.
extension XCTestCase {

    /// Clicks through the wizard when it is up, and does nothing when it is not.
    ///
    /// Four steps, matching `OnboardingView.Step` — welcome, goal, connect,
    /// ready. Keep in step with it.
    ///
    /// Spelled out rather than importing the app module: that drags GRDB into
    /// a target which does not link it.
    ///
    /// `@MainActor` because `XCUIApplication`'s members are: both suites are
    /// `@MainActor` classes, so inline copies got that for free and a free
    /// function does not. Xcode 26.6 compiled it without; the 16.4 CI SDK is
    /// stricter and refused, which is the gap CLAUDE.md describes.
    @MainActor
    func completeOnboardingIfPresent(in app: XCUIApplication) {
        guard app.staticTexts["Welcome to Social Brain"].waitForExistence(timeout: 3) else { return }
        app.buttons["Next"].click()
        app.buttons["Next"].click()
        app.buttons["Next"].click()
        app.buttons["Get Started"].click()
    }
}
