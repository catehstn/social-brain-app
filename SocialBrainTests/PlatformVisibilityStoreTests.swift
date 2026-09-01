import Testing
import Foundation
@testable import SocialBrain

/// Both suites below reassign `PlatformVisibilityStore.defaults`, a static var.
/// `.serialized` only orders tests *within* a suite, so as separate top-level
/// suites they ran concurrently and replaced each other's UserDefaults mid-test —
/// which made `reload() reads hidden state` fail intermittently on CI and pass
/// locally. Nesting them under one serialized parent applies serialisation to
/// every descendant, so only one of them touches the global at a time.
@Suite("Platform visibility", .serialized)
struct PlatformVisibilitySuite {
    @Suite("PlatformVisibilityStore Tests")
    struct PlatformVisibilityStoreTests {

        init() {
            // Inject a fresh isolated UserDefaults suite to avoid polluting standard
            PlatformVisibilityStore.defaults = UserDefaults(suiteName: "com.test.PlatformVisibilityStore.\(UUID().uuidString)")!
            PlatformVisibilityStore.resetAll()
        }

        // Test 6: Default is visible
        @Test("Fresh store returns isHidden == false")
        func testDefaultIsVisible() {
            #expect(PlatformVisibilityStore.isHidden(.buttondown) == false)
        }

        // Test 7: Hide persists
        @Test("Hide platform makes isHidden return true")
        func testHidePlatform() {
            PlatformVisibilityStore.hide(.mastodon)
            #expect(PlatformVisibilityStore.isHidden(.mastodon) == true)
        }

        // Test 8: Show clears hidden state
        @Test("Show platform makes isHidden return false")
        func testShowPlatform() {
            PlatformVisibilityStore.hide(.bluesky)
            PlatformVisibilityStore.show(.bluesky)
            #expect(PlatformVisibilityStore.isHidden(.bluesky) == false)
        }

        // Test 9: resetAll clears all
        @Test("resetAll clears hidden state for all platforms")
        func testResetAll() {
            PlatformVisibilityStore.hide(.buttondown)
            PlatformVisibilityStore.hide(.mastodon)
            PlatformVisibilityStore.hide(.bluesky)
            PlatformVisibilityStore.resetAll()
            #expect(PlatformVisibilityStore.isHidden(.buttondown) == false)
            #expect(PlatformVisibilityStore.isHidden(.mastodon) == false)
            #expect(PlatformVisibilityStore.isHidden(.bluesky) == false)
        }

        // Test 10: Isolation between suites — does not bleed into UserDefaults.standard
        @Test("Injected suite does not write to UserDefaults.standard")
        func testIsolationFromStandard() {
            PlatformVisibilityStore.hide(.vercel)
            #expect(UserDefaults.standard.bool(forKey: "hiddenPlatform_vercel") == false)
        }
    }

    @Suite("PlatformsViewModel Hidden State Tests")
    struct PlatformsViewModelHiddenTests {

        init() {
            PlatformVisibilityStore.defaults = UserDefaults(suiteName: "com.test.PlatformsViewModelHidden.\(UUID().uuidString)")!
            PlatformVisibilityStore.resetAll()
        }

        // Test 11: hidePlatform / isHidden reactive update
        @MainActor
        @Test("hidePlatform updates isHidden and hiddenPlatforms")
        func testHidePlatformReactive() throws {
            let db = try AppDatabase.makeInMemory()
            let viewModel = PlatformsViewModel(database: db)
            viewModel.hidePlatform(.calendly)
            #expect(viewModel.isHidden(.calendly) == true)
            #expect(viewModel.hiddenPlatforms.contains(.calendly) == true)
        }

        // Test 12: showPlatform reactive update
        @MainActor
        @Test("showPlatform updates isHidden and hiddenPlatforms")
        func testShowPlatformReactive() throws {
            let db = try AppDatabase.makeInMemory()
            let viewModel = PlatformsViewModel(database: db)
            viewModel.hidePlatform(.calendly)
            viewModel.showPlatform(.calendly)
            #expect(viewModel.isHidden(.calendly) == false)
            #expect(viewModel.hiddenPlatforms.contains(.calendly) == false)
        }

        // Test 13: reload() restores hidden state from UserDefaults
        @MainActor
        @Test("reload() reads hidden state from PlatformVisibilityStore")
        func testReloadRestoresHiddenState() throws {
            // Own isolated suite set up inside the test body to avoid racing with
            // PlatformVisibilityStoreTests.init() resetting the same static.
            let suite = UserDefaults(suiteName: "com.test.reloadHidden.\(UUID().uuidString)")!
            PlatformVisibilityStore.defaults = suite
            PlatformVisibilityStore.resetAll()

            let db = try AppDatabase.makeInMemory()
            let viewModel = PlatformsViewModel(database: db)
            // Write directly to store (simulating prior app session)
            PlatformVisibilityStore.hide(.mastodon)
            viewModel.reload()
            #expect(viewModel.isHidden(.mastodon) == true)
        }

        // Test 14: Auto-show on save
        @MainActor
        @Test("save() auto-shows a previously hidden platform")
        func testAutoShowOnSave() throws {
            let db = try AppDatabase.makeInMemory()
            let viewModel = PlatformsViewModel(database: db)
            viewModel.hidePlatform(.buttondown)
            #expect(viewModel.isHidden(.buttondown) == true)

            let instance = PlatformInstance(platform: .buttondown)
            try viewModel.save(["apiKey": "test-key"], for: instance)

            #expect(viewModel.isHidden(.buttondown) == false)
            #expect(PlatformVisibilityStore.isHidden(.buttondown) == false)
        }
    }
}
