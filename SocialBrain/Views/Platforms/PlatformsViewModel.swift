import SwiftUI

/// Manages the configured-platform state and Keychain reads/writes for the
/// Platforms view.
@Observable
@MainActor
final class PlatformsViewModel {

    /// Set of platforms that currently have credentials stored in the Keychain.
    private(set) var configured: Set<Platform> = []

    // MARK: - Actions

    /// Refreshes `configured` by checking the Keychain for each platform.
    func reload() {
        configured = Set(Platform.allCases.filter { KeychainStore.hasCredentials(for: $0) })
    }

    /// Returns the currently stored credential values for a platform (empty dict if none).
    func loadValues(for platform: Platform) -> [String: String] {
        (try? KeychainStore.load(for: platform))?.values ?? [:]
    }

    /// Saves the given values to the Keychain and marks the platform as configured.
    func save(_ values: [String: String], for platform: Platform) throws {
        try KeychainStore.save(Credentials(values), for: platform)
        configured.insert(platform)
    }

    /// Removes credentials for the platform from the Keychain.
    func delete(for platform: Platform) throws {
        try KeychainStore.delete(for: platform)
        configured.remove(platform)
    }
}
