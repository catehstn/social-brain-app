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
enum ScratchKeychain {

    private static let servicePrefix = "com.catehuston.SocialBrain.tests"

    /// A store scoped to a service named for the calling test.
    static func make(_ label: String = #function) -> KeychainStore {
        KeychainStore(service: "\(servicePrefix).\(sanitised(label))")
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
