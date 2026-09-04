import Foundation

/// Persists which named instances exist per platform in `UserDefaults`.
///
/// Key format: `"instanceNames_<platform.rawValue>"` → JSON-encoded `[String]`.
/// Every platform auto-seeds `["default"]` on first access.
/// `defaults` is a stored property rather than a mutable global, so a test can
/// hold a registry pointed at a throwaway suite. The previous
/// `nonisolated(unsafe) static var` was reassigned by one test suite for the
/// rest of the process, which made where these writes landed depend on suite
/// ordering — and in practice `reload()` auto-seeded all 14 platforms into the
/// real app's preferences on every test run.
/// The three operations this needs from `UserDefaults`.
///
/// Declared as a protocol so tests can supply an in-memory store. Backing tests
/// with `UserDefaults(suiteName:)` writes a plist into the app container that
/// nothing ever deletes — 266 such files had accumulated here before this was
/// introduced.
protocol KeyValueStore: Sendable {
    func stringArray(forKey key: String) -> [String]?
    func set(_ value: [String], forKey key: String)
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
    func removeObject(forKey key: String)
}

/// `@unchecked Sendable`: `UserDefaults` is documented thread-safe but not
/// annotated.
extension UserDefaults: @unchecked @retroactive Sendable {}

extension UserDefaults: KeyValueStore {
    public func set(_ value: [String], forKey key: String) {
        set(value as Any?, forKey: key)
    }
}

/// `@unchecked Sendable` because the store is a protocol existential whose
/// conformances vouch for their own thread-safety; the only stored property is
/// a `let`.
struct InstanceRegistry: @unchecked Sendable {

    /// The production registry. The only place `UserDefaults.standard` is used.
    static let shared = InstanceRegistry(defaults: UserDefaults.standard)

    let defaults: any KeyValueStore

    init(defaults: any KeyValueStore) {
        self.defaults = defaults
    }

    // MARK: - Read

    /// Returns the list of instance names for the given platform.
    /// Auto-seeds `["default"]` if the key has never been set.
    func instances(for platform: Platform) -> [String] {
        let k = key(for: platform)
        if let stored = defaults.stringArray(forKey: k), !stored.isEmpty {
            return stored
        }
        // Auto-seed with "default".
        let seeded = ["default"]
        defaults.set(seeded, forKey: k)
        return seeded
    }

    /// Returns a `PlatformInstance` for every `(platform, instanceName)` pair.
    func allInstances() -> [PlatformInstance] {
        Platform.allCases.flatMap { platform in
            instances(for: platform).map { PlatformInstance(platform: platform, instanceName: $0) }
        }
    }

    // MARK: - Mutate

    /// Appends `instanceName` to the list for `platform`, if not already present.
    func add(instanceName: String, to platform: Platform) {
        var current = instances(for: platform)
        guard !current.contains(instanceName) else { return }
        current.append(instanceName)
        defaults.set(current, forKey: key(for: platform))
    }

    /// Removes `instanceName` from the list for `platform`.
    /// Does nothing if removal would leave the list empty.
    func remove(instanceName: String, from platform: Platform) {
        var current = instances(for: platform)
        guard current.count > 1 else { return }  // never empty the list
        current.removeAll { $0 == instanceName }
        defaults.set(current, forKey: key(for: platform))
    }

    // MARK: - Test support

    /// Removes all stored instance lists. For test teardown only.
    func resetAll() {
        for platform in Platform.allCases {
            defaults.removeObject(forKey: key(for: platform))
        }
    }

    // MARK: - Private

    private func key(for platform: Platform) -> String {
        "instanceNames_\(platform.rawValue)"
    }
}
