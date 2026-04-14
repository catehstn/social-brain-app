import Foundation

/// Stores human-readable display labels for platform instances.
///
/// Labels are fetched automatically from each platform's API after credentials
/// are saved, and persist across launches in UserDefaults.
///
/// The label is independent of `instanceName` (the internal identifier stored
/// in Keychain and the database). `instanceName` stays stable; the label is
/// just for display.
enum InstanceLabels {
    private static let prefix = "instanceLabel_"

    static func label(for instance: PlatformInstance) -> String? {
        UserDefaults.standard.string(forKey: prefix + instance.id)
    }

    static func setLabel(_ label: String, for instance: PlatformInstance) {
        UserDefaults.standard.set(label, forKey: prefix + instance.id)
    }

    static func removeLabel(for instance: PlatformInstance) {
        UserDefaults.standard.removeObject(forKey: prefix + instance.id)
    }
}
