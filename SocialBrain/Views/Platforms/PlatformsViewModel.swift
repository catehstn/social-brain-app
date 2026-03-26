import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Manages the configured-platform state, Keychain reads/writes, and file-import
/// for the Platforms view.
@Observable
@MainActor
final class PlatformsViewModel {

    /// Set of platforms that currently have credentials stored in the Keychain.
    private(set) var configured: Set<Platform> = []

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - API credential actions

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

    // MARK: - File import

    /// Presents an NSOpenPanel, parses the selected file, and saves it as a
    /// snapshot in the database.  Marks the platform as configured in the Keychain.
    ///
    /// Throws `ImportError.cancelled` if the user dismisses the panel (callers
    /// should treat this as a no-op rather than an error to display).
    func importFile(for platform: Platform, allowedExtensions: [String]) async throws {
        let url = try await selectFile(allowedExtensions: allowedExtensions)

        let rawData = try Data(contentsOf: url)
        let platformData: PlatformData

        switch platform {
        case .amazon:
            platformData = try AmazonKDPImporter().parse(data: rawData)
        case .linkedin:
            platformData = try LinkedInImporter().parse(data: rawData)
        case .substack:
            platformData = try SubstackImporter().parse(data: rawData)
        default:
            throw ImportError.unsupportedPlatform(platform)
        }

        // Persist as a one-platform collection run + snapshot.
        var run = CollectionRun(
            id: nil,
            startedAt: .now,
            completedAt: nil,
            platformCount: 1,
            errorCount: 0
        )
        try await database.saveRun(&run)
        let runID = run.id!
        var snapshot = try PlatformSnapshot(runID: runID, data: platformData)
        try await database.saveSnapshot(&snapshot)
        try await database.completeRun(id: runID, errorCount: 0)

        // Mark the platform as configured so the list row shows a green badge.
        try KeychainStore.save(Credentials(["imported": "true"]), for: platform)
        configured.insert(platform)

        // Reset the stale-export reminder clock: cancel the old reminder and
        // schedule a new one 30 days from now.
        let notificationManager = NotificationManager.shared
        await notificationManager.cancelStaleExportReminder(for: platform)
        await notificationManager.scheduleStaleExportReminder(for: platform, lastImportDate: .now)
    }

    // MARK: - Private

    private func selectFile(allowedExtensions: [String]) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.allowedContentTypes = allowedExtensions.compactMap {
                UTType(filenameExtension: $0)
            }
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: ImportError.cancelled)
                }
            }
        }
    }
}

// MARK: - Import errors

enum ImportError: LocalizedError {
    case cancelled
    case unsupportedPlatform(Platform)

    var errorDescription: String? {
        switch self {
        case .cancelled:                return nil
        case .unsupportedPlatform(let p): return "File import is not yet supported for \(p.displayName)."
        }
    }
}
