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
///
/// The store itself is `KeyValueStore`, in its own file.
///
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
            // Repair, not just read: a build before the guard below could
            // remove `"default"`, and this only re-seeded when the key was
            // *absent*, so the deletion stuck. Every platform-level API
            // resolves to the default instance, so a list without it leaves
            // them addressing a name nothing enumerates. Restoring it makes
            // the guard total rather than only stopping new cases (#90).
            guard !stored.contains("default") else { return stored }
            let repaired = stored + ["default"]
            defaults.set(repaired, forKey: k)
            return repaired
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
    ///
    /// `"default"` cannot be removed, and neither can the last remaining
    /// instance.
    ///
    /// The `"default"` rule is not a tidiness preference. Every
    /// platform-level convenience API — `KeychainStore.save(for: Platform)`,
    /// `hasCredentials(for: Platform)`, `AppDatabase.latestSnapshot(for:)` —
    /// resolves to `PlatformInstance(platform:)`, which *is* the default
    /// instance. Removing it left those writing to and reading from an
    /// instance the registry no longer listed: credentials stored under a name
    /// nothing enumerates, and `instances(for:)` re-seeding `["default"]` only
    /// when the key is absent, so a deliberate delete stayed deleted and the
    /// phantom persisted (#90).
    ///
    /// Renaming is what the user actually wants here, and labels already do
    /// it: `InstanceLabels` changes the display name while `instanceName`
    /// stays the key that the Keychain and the database are organised by.
    func remove(instanceName: String, from platform: Platform) {
        guard instanceName != "default" else { return }
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
