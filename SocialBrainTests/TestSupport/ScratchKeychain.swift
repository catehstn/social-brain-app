import Foundation
@testable import SocialBrain

/// Throwaway `KeychainStore` and `InstanceRegistry` instances, so tests never
/// touch the developer's real login Keychain or the app's real preferences.
///
/// Before these existed the suite overwrote live credentials on every
/// `xcodebuild test` run, and auto-seeded instance names for all 14 platforms
/// into the app's own preferences.
///
/// **Names are recurring, not random**, and every one sits under a single
/// greppable prefix:
///
///     security dump-keychain | grep com.catehuston.SocialBrain.tests
///
/// A UUID per call strands an orphan forever: a crash between a write and its
/// cleanup leaves an item whose name will never be generated again, so nothing
/// later can clean it up. The same UUID-per-run idiom used for
/// `UserDefaults(suiteName:)` elsewhere in this suite stranded a few hundred
/// plists in the app container before it was replaced.
///
/// **The test's name alone is not enough, and that flaked.** Naming the service
/// only after `#function` meant two test hosts running at once — one per git
/// worktree — shared a service, and `KeychainStore.save` is not atomic across
/// processes: it tries `SecItemUpdate`, and on `errSecItemNotFound` falls back
/// to `SecItemAdd`. The other process can add the item in between, so the add
/// returns `errSecDuplicateItem` (-25299) and a test fails with an alarming
/// error that passes on a re-run (#127). The underlying non-atomicity is #158.
///
/// So the name carries the process ID as well. Not because a PID is more
/// findable than a UUID — it isn't, and #98's original argument that
/// `security find-generic-password` needs the exact name no longer holds either
/// way — but because **PIDs recur and UUIDs don't**. That is what lets `make`
/// self-heal: when the OS hands this PID out again, the store for that
/// PID-and-label is emptied on creation, sweeping whatever a crashed run left
/// behind. A UUID would leave it there forever. Uniqueness among *concurrently
/// running* processes, which is the entire collision, comes for free.
enum ScratchKeychain {

    private static let servicePrefix = "com.catehuston.SocialBrain.tests"

    /// Distinct for every test host alive at the same time. See the note above
    /// for why this is the PID rather than a UUID.
    private static let runID = String(ProcessInfo.processInfo.processIdentifier)

    /// A store scoped to a service named for the calling test and this test run.
    ///
    /// Emptied on the way *in*, not on the way out: that is what sweeps an item
    /// stranded by an earlier run that crashed between a write and its cleanup,
    /// once the OS hands this PID out again. Best-effort — a locked Keychain
    /// returns a store that is not actually empty.
    static func make(_ label: String = #function) -> KeychainStore {
        let store = KeychainStore(service: "\(servicePrefix).\(runID).\(sanitised(label))")
        try? store.deleteAll()
        return store
    }

    /// A store scoped to the caller, emptied before and after `body` runs.
    ///
    /// `make` has already emptied it; the `defer` is the half that matters here,
    /// and it runs even when `body` throws.
    static func withStore(
        _ label: String = #function,
        _ body: (KeychainStore) throws -> Void
    ) rethrows {
        let store = make(label)
        defer { try? store.deleteAll() }
        try body(store)
    }

    private static func sanitised(_ label: String) -> String {
        label.replacingOccurrences(of: "(", with: "")
             .replacingOccurrences(of: ")", with: "")
    }
}

/// In-memory `KeyValueStore`, so registry tests touch neither the app's real
/// preferences nor the filesystem.
///
/// `UserDefaults(suiteName:)` was the obvious choice and the wrong one: it
/// writes a plist into the app container that nothing deletes, and 266 of them
/// had already accumulated from that idiom before this replaced it.
final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    func stringArray(forKey key: String) -> [String]? {
        lock.withLock { storage[key] as? [String] }
    }

    func set(_ value: [String], forKey key: String) {
        lock.withLock { storage[key] = value }
    }

    func bool(forKey key: String) -> Bool {
        lock.withLock { storage[key] as? Bool ?? false }
    }

    func set(_ value: Bool, forKey key: String) {
        lock.withLock { storage[key] = value }
    }

    func string(forKey key: String) -> String? {
        lock.withLock { storage[key] as? String }
    }

    func set(_ value: String, forKey key: String) {
        lock.withLock { storage[key] = value }
    }

    func removeObject(forKey key: String) {
        _ = lock.withLock { storage.removeValue(forKey: key) }
    }
}

/// Throwaway `InstanceRegistry`. Leaves nothing behind on disk.
enum ScratchRegistry {
    static func make(_ label: String = #function) -> InstanceRegistry {
        InstanceRegistry(defaults: InMemoryKeyValueStore())
    }
}

/// Throwaway `PlatformVisibilityStore`. Leaves nothing behind on disk.
enum ScratchVisibility {
    static func make(_ label: String = #function) -> PlatformVisibilityStore {
        PlatformVisibilityStore(defaults: InMemoryKeyValueStore())
    }
}
