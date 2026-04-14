import Foundation

/// UserDefaults-backed store for platform visibility (hidden/visible) state.
///
/// Platforms are visible by default. A platform is hidden when its key is
/// set to `true`. Removing the key (via `show`) restores the default visible state.
enum PlatformVisibilityStore {
    // swiftlint:disable:next nonisolated_unsafe
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    static func isHidden(_ platform: Platform) -> Bool {
        defaults.bool(forKey: key(for: platform))
    }

    static func hide(_ platform: Platform) {
        defaults.set(true, forKey: key(for: platform))
    }

    static func show(_ platform: Platform) {
        defaults.removeObject(forKey: key(for: platform))
    }

    /// Removes all hidden-platform keys. Used in tests and for a "reset" action.
    static func resetAll() {
        Platform.allCases.forEach { defaults.removeObject(forKey: key(for: $0)) }
    }

    private static func key(for platform: Platform) -> String {
        "hiddenPlatform_\(platform.rawValue)"
    }
}
