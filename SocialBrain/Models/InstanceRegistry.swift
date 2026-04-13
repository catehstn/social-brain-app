import Foundation

/// Persists which named instances exist per platform in `UserDefaults`.
///
/// Key format: `"instanceNames_<platform.rawValue>"` → JSON-encoded `[String]`.
/// Every platform auto-seeds `["default"]` on first access.
enum InstanceRegistry {
    /// Exposed for test injection; defaults to `UserDefaults.standard`.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    // MARK: - Read

    /// Returns the list of instance names for the given platform.
    /// Auto-seeds `["default"]` if the key has never been set.
    static func instances(for platform: Platform) -> [String] {
        let k = key(for: platform)
        if let stored = defaults.array(forKey: k) as? [String], !stored.isEmpty {
            return stored
        }
        // Auto-seed with "default".
        let seeded = ["default"]
        defaults.set(seeded, forKey: k)
        return seeded
    }

    /// Returns a `PlatformInstance` for every `(platform, instanceName)` pair.
    static func allInstances() -> [PlatformInstance] {
        Platform.allCases.flatMap { platform in
            instances(for: platform).map { PlatformInstance(platform: platform, instanceName: $0) }
        }
    }

    // MARK: - Mutate

    /// Appends `instanceName` to the list for `platform`, if not already present.
    static func add(instanceName: String, to platform: Platform) {
        var current = instances(for: platform)
        guard !current.contains(instanceName) else { return }
        current.append(instanceName)
        defaults.set(current, forKey: key(for: platform))
    }

    /// Removes `instanceName` from the list for `platform`.
    /// Does nothing if removal would leave the list empty.
    static func remove(instanceName: String, from platform: Platform) {
        var current = instances(for: platform)
        guard current.count > 1 else { return }  // never empty the list
        current.removeAll { $0 == instanceName }
        defaults.set(current, forKey: key(for: platform))
    }

    // MARK: - Test support

    /// Removes all stored instance lists. For test teardown only.
    static func resetAll() {
        for platform in Platform.allCases {
            defaults.removeObject(forKey: key(for: platform))
        }
    }

    // MARK: - Private

    private static func key(for platform: Platform) -> String {
        "instanceNames_\(platform.rawValue)"
    }
}
