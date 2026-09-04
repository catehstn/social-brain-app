import Foundation

/// UserDefaults-backed store for platform visibility (hidden/visible) state.
///
/// Platforms are visible by default. A platform is hidden when its key is
/// set to `true`. Removing the key (via `show`) restores the default visible state.
/// `defaults` is a stored property rather than a mutable global. The previous
/// `nonisolated(unsafe) static var` was repointed by whichever test suite ran
/// first and stayed repointed for the process, and backing tests with
/// `UserDefaults(suiteName:)` stranded a plist per run in the app container.
struct PlatformVisibilityStore: @unchecked Sendable {

    /// The production store. The only place `UserDefaults.standard` is used.
    static let shared = PlatformVisibilityStore(defaults: UserDefaults.standard)

    let defaults: any KeyValueStore

    init(defaults: any KeyValueStore) {
        self.defaults = defaults
    }

    func isHidden(_ platform: Platform) -> Bool {
        defaults.bool(forKey: key(for: platform))
    }

    func hide(_ platform: Platform) {
        defaults.set(true, forKey: key(for: platform))
    }

    func show(_ platform: Platform) {
        defaults.removeObject(forKey: key(for: platform))
    }

    /// Removes all hidden-platform keys. Used in tests and for a "reset" action.
    func resetAll() {
        Platform.allCases.forEach { defaults.removeObject(forKey: key(for: $0)) }
    }

    private func key(for platform: Platform) -> String {
        "hiddenPlatform_\(platform.rawValue)"
    }
}
