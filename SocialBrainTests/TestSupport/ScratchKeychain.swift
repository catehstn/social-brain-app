import Foundation
@testable import SocialBrain

/// A `KeychainStore` scoped to a throwaway service name, so tests never touch
/// the developer's real login Keychain.
///
/// Before this existed, `KeychainStore` hard-coded the production service and
/// the suite overwrote live credentials on every `xcodebuild test` run — a
/// configured Buttondown or Calendly account was destroyed by running the tests.
///
/// Always construct one per test. Never name the production service.
enum ScratchKeychain {

    /// Creates a store on a service name unique to this call.
    static func make(_ label: String = #function) -> KeychainStore {
        KeychainStore(service: "com.catehuston.SocialBrain.tests.\(label).\(UUID().uuidString)")
    }

    /// Runs `body` with a scratch store, deleting anything it left behind.
    ///
    /// Keychain items outlive the process, so a test that saves without cleaning
    /// up leaks an item into the login keychain — junk rather than damage, but
    /// it accumulates one entry per test run.
    static func withStore(
        _ label: String = #function,
        instances: [PlatformInstance],
        _ body: (KeychainStore) throws -> Void
    ) rethrows {
        let store = make(label)
        defer { for instance in instances { try? store.delete(for: instance) } }
        try body(store)
    }
}
