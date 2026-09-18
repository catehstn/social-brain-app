import Foundation
@testable import SocialBrain

/// Throwaway `KeychainStore` and `InstanceRegistry` instances, so tests never
/// touch the developer's real login Keychain or the app's real preferences.
///
/// Before these existed the suite overwrote live credentials on every
/// `xcodebuild test` run, and auto-seeded instance names for all 14 platforms
/// into the app's own preferences.
///
/// **Names are deterministic, not random.** A UUID per call makes an orphaned
/// item unfindable — `security find-generic-password` needs the exact service
/// name, and a crash between the write and its cleanup strands it forever. The
/// same UUID-per-run idiom used for `UserDefaults(suiteName:)` elsewhere in this
/// suite has already stranded 246 plists in the app container. Deriving the name
/// from `#function` keeps it unique per test, reproducible across runs, and
/// sweepable afterwards.
///
/// **But the name alone is not unique per *run*, and that flaked.** Naming the
/// service only after the test meant two test hosts running at once — one per
/// git worktree — used the same service, and `KeychainStore.save` is not atomic
/// across processes: it tries `SecItemUpdate`, and on `errSecItemNotFound` falls
/// back to `SecItemAdd`. The other process can add the item in between, so the
/// add returns `errSecDuplicateItem` (-25299) and the test fails with a scary
/// error that passes on a re-run (#127).
///
/// The process ID closes that, and is chosen over a UUID precisely to keep the
/// objection above answered: PIDs are unique among *concurrently running*
/// processes, which is the whole collision, while being bounded and recycled, so
/// strandings cannot accumulate the way 246 plists did. Everything is still
/// reachable under one greppable prefix:
///
///     security dump-keychain | grep com.catehuston.SocialBrain.tests
enum ScratchKeychain {

    private static let servicePrefix = "com.catehuston.SocialBrain.tests"

    /// Distinct for every test host alive at the same time. See the note above
    /// for why this is the PID rather than a UUID.
    private static let runID = String(ProcessInfo.processInfo.processIdentifier)

    /// A store scoped to a service named for the calling test and this test run.
    ///
    /// Emptied on the way out, so a recycled PID that inherited an item from a
    /// crashed earlier run starts clean rather than failing the first save.
    static func make(_ label: String = #function) -> KeychainStore {
        let store = KeychainStore(service: "\(servicePrefix).\(runID).\(sanitised(label))")
        try? store.deleteAll()
        return store
    }

    /// A store scoped to the caller, emptied before and after `body` runs.
    static func withStore(
        _ label: String = #function,
        _ body: (KeychainStore) throws -> Void
    ) rethrows {
        let store = make(label)
        try? store.deleteAll()
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
