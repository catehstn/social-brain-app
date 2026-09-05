import Testing
import Foundation
@testable import SocialBrain

/// Both suites hold their own in-memory `PlatformVisibilityStore`, so there is
/// no shared global for them to race on. `.serialized` is kept because the two
/// suites still exercise overlapping platform state through `PlatformsViewModel`
/// and serialising them costs nothing.
@Suite("Platform visibility", .serialized)
struct PlatformVisibilitySuite {
    @Suite("PlatformVisibilityStore Tests")
    struct PlatformVisibilityStoreTests {

        private let store = ScratchVisibility.make()

        // Test 6: Default is visible
        @Test("Fresh store returns isHidden == false")
        func testDefaultIsVisible() {
            #expect(store.isHidden(.buttondown) == false)
        }

        // Test 7: Hide persists
        @Test("Hide platform makes isHidden return true")
        func testHidePlatform() {
            store.hide(.mastodon)
            #expect(store.isHidden(.mastodon) == true)
        }

        // Test 8: Show clears hidden state
        @Test("Show platform makes isHidden return false")
        func testShowPlatform() {
            store.hide(.bluesky)
            store.show(.bluesky)
            #expect(store.isHidden(.bluesky) == false)
        }

        // Test 9: resetAll clears all
        @Test("resetAll clears hidden state for all platforms")
        func testResetAll() {
            store.hide(.buttondown)
            store.hide(.mastodon)
            store.hide(.bluesky)
            store.resetAll()
            #expect(store.isHidden(.buttondown) == false)
            #expect(store.isHidden(.mastodon) == false)
            #expect(store.isHidden(.bluesky) == false)
        }

        // Test 10: Isolation between suites — does not bleed into UserDefaults.standard
        @Test("Injected suite does not write to UserDefaults.standard")
        func testIsolationFromStandard() {
            store.hide(.buffer)
            #expect(UserDefaults.standard.bool(forKey: "hiddenPlatform_buffer") == false)
        }
    }

    @Suite("PlatformsViewModel Hidden State Tests")
    struct PlatformsViewModelHiddenTests {

        private let store = ScratchVisibility.make()

        // Test 11: hidePlatform / isHidden reactive update
        @MainActor
        @Test("hidePlatform updates isHidden and hiddenPlatforms")
        func testHidePlatformReactive() throws {
            let db = try AppDatabase.makeInMemory()
            // Scratch store: reload() reads the Keychain, so with the production
            // default this would see whatever the developer has configured.
            let viewModel = PlatformsViewModel(database: db,
                                               keychain: ScratchKeychain.make(),
                                               registry: ScratchRegistry.make(),
                                               visibility: store,
                                               labelFetcher: { _, _ in nil })
            viewModel.hidePlatform(.calendly)
            #expect(viewModel.isHidden(.calendly) == true)
            #expect(viewModel.hiddenPlatforms.contains(.calendly) == true)
        }

        // Test 12: showPlatform reactive update
        @MainActor
        @Test("showPlatform updates isHidden and hiddenPlatforms")
        func testShowPlatformReactive() throws {
            let db = try AppDatabase.makeInMemory()
            // Scratch store: reload() reads the Keychain, so with the production
            // default this would see whatever the developer has configured.
            let viewModel = PlatformsViewModel(database: db,
                                               keychain: ScratchKeychain.make(),
                                               registry: ScratchRegistry.make(),
                                               visibility: store,
                                               labelFetcher: { _, _ in nil })
            viewModel.hidePlatform(.calendly)
            viewModel.showPlatform(.calendly)
            #expect(viewModel.isHidden(.calendly) == false)
            #expect(viewModel.hiddenPlatforms.contains(.calendly) == false)
        }

        // Test 13: reload() restores hidden state from UserDefaults
        @MainActor
        @Test("reload() reads hidden state from PlatformVisibilityStore")
        func testReloadRestoresHiddenState() throws {
            // The belt-and-braces isolated suite this used to build is gone:
            // the store is injected now, so there is no shared static to race on.

            let db = try AppDatabase.makeInMemory()
            // Scratch store: reload() reads the Keychain, so with the production
            // default this would see whatever the developer has configured.
            let viewModel = PlatformsViewModel(database: db,
                                               keychain: ScratchKeychain.make(),
                                               registry: ScratchRegistry.make(),
                                               visibility: store,
                                               labelFetcher: { _, _ in nil })
            // Write directly to store (simulating prior app session)
            store.hide(.mastodon)
            viewModel.reload()
            #expect(viewModel.isHidden(.mastodon) == true)
        }

        // Test 14: Auto-show on save
        @MainActor
        @Test("save() auto-shows a previously hidden platform")
        func testAutoShowOnSave() throws {
            let db = try AppDatabase.makeInMemory()
            let instance = PlatformInstance(platform: .buttondown)
            let keychain = ScratchKeychain.make()
            defer { try? keychain.deleteAll() }

            // A scratch Keychain and a stubbed label fetcher. With the real
            // defaults this test wrote buttondown:default into the developer's
            // login Keychain and fired a live HTTPS request to buttondown.com
            // with the string "test-key", on every test run.
            let viewModel = PlatformsViewModel(database: db,
                                               keychain: keychain,
                                               registry: ScratchRegistry.make(),
                                               visibility: store,
                                               labelFetcher: { _, _ in nil })
            viewModel.hidePlatform(.buttondown)
            #expect(viewModel.isHidden(.buttondown) == true)

            try viewModel.save(["apiKey": "test-key"], for: instance)

            #expect(viewModel.isHidden(.buttondown) == false)
            #expect(store.isHidden(.buttondown) == false)
        }
    }
}
