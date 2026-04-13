import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Manages the configured-platform state, Keychain reads/writes, and file-import
/// for the Platforms view.
@Observable
@MainActor
final class PlatformsViewModel {

    /// Instance names grouped by platform for configured instances only.
    private(set) var configuredInstances: [Platform: [String]] = [:]

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - API credential actions

    /// Refreshes `configuredInstances` by checking the Keychain for each (platform, instance).
    func reload() {
        configuredInstances = [:]
        for platform in Platform.allCases {
            let names = InstanceRegistry.instances(for: platform)
            let configured = names.filter { name in
                KeychainStore.hasCredentials(for: PlatformInstance(platform: platform, instanceName: name))
            }
            if !configured.isEmpty {
                configuredInstances[platform] = configured
            }
        }
    }

    /// Returns the currently stored credential values for an instance (empty dict if none).
    func loadValues(for instance: PlatformInstance) -> [String: String] {
        (try? KeychainStore.load(for: instance))?.values ?? [:]
    }

    /// Saves the given values to the Keychain for the specified instance,
    /// then asynchronously fetches a display label from the platform API.
    func save(_ values: [String: String], for instance: PlatformInstance) throws {
        let credentials = Credentials(values)
        try KeychainStore.save(credentials, for: instance)
        InstanceRegistry.add(instanceName: instance.instanceName, to: instance.platform)
        reload()
        Task {
            guard let collector = CollectorRegistry.collector(for: instance) else { return }
            if let label = await collector.fetchLabel(credentials: credentials) {
                InstanceLabels.setLabel(label, for: instance)
            }
        }
    }

    /// Removes credentials for an instance from the Keychain and its snapshot data.
    func delete(for instance: PlatformInstance) async throws {
        try KeychainStore.delete(for: instance)
        try await database.deleteSnapshots(for: instance)
        InstanceRegistry.remove(instanceName: instance.instanceName, from: instance.platform)
        InstanceLabels.removeLabel(for: instance)
        reload()
    }

    /// Adds a new named instance for a platform (without credentials).
    func addInstance(label: String, to platform: Platform) {
        InstanceRegistry.add(instanceName: label, to: platform)
    }

    // MARK: - File import

    /// Presents an NSOpenPanel, parses the selected file, and saves it as a
    /// snapshot in the database.  Marks the instance as configured in the Keychain.
    ///
    /// Throws `ImportError.cancelled` if the user dismisses the panel (callers
    /// should treat this as a no-op rather than an error to display).
    func importFile(for instance: PlatformInstance, allowedExtensions: [String]) async throws {
        let url = try await selectFile(allowedExtensions: allowedExtensions)

        let rawData = try Data(contentsOf: url)
        let platformData: PlatformData

        switch instance.platform {
        case .amazon:
            platformData = try AmazonKDPImporter().parse(data: rawData)
        case .linkedin:
            platformData = try LinkedInImporter().parse(data: rawData)
        case .oreilly:
            platformData = try OReillyImporter().parse(data: rawData)
        case .substack:
            platformData = try SubstackImporter().parse(data: rawData)
        default:
            throw ImportError.unsupportedPlatform(instance.platform)
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

        // Mark the instance as configured so the list row shows a green badge.
        try KeychainStore.save(Credentials(["imported": "true"]), for: instance)
        InstanceRegistry.add(instanceName: instance.instanceName, to: instance.platform)
        reload()

        // Reset the stale-export reminder clock.
        let notificationManager = NotificationManager.shared
        await notificationManager.cancelStaleExportReminder(for: instance.platform)
        await notificationManager.scheduleStaleExportReminder(for: instance.platform, lastImportDate: .now)
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
