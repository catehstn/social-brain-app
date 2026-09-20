import Foundation

/// Stores human-readable display labels for platform instances.
///
/// Labels are fetched automatically from each platform's API after credentials
/// are saved, and persist across launches in UserDefaults.
///
/// The label is independent of `instanceName` (the internal identifier stored
/// in Keychain and the database). `instanceName` stays stable; the label is
/// just for display.
/// `defaults` is injected rather than read from a global, so a test can use a
/// throwaway store. It used to write `UserDefaults.standard` directly, which
/// meant the first test to touch labelling would have written the developer's
/// own preferences — the class #98 fixed for the Keychain and #80 for platform
/// visibility (#58, #90).
struct InstanceLabels: @unchecked Sendable {

    /// The production store. The only place `UserDefaults.standard` is used.
    static let shared = InstanceLabels(defaults: UserDefaults.standard)

    let defaults: any KeyValueStore

    init(defaults: any KeyValueStore) {
        self.defaults = defaults
    }

    private static let prefix = "instanceLabel_"

    func label(for instance: PlatformInstance) -> String? {
        defaults.string(forKey: Self.prefix + instance.id)
    }

    func setLabel(_ label: String, for instance: PlatformInstance) {
        defaults.set(label, forKey: Self.prefix + instance.id)
    }

    func removeLabel(for instance: PlatformInstance) {
        defaults.removeObject(forKey: Self.prefix + instance.id)
    }
}
