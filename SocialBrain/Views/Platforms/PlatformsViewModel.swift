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

    /// Platforms currently hidden from the main grid.
    private(set) var hiddenPlatforms: Set<Platform> = []

    /// Fetches a display label from the platform's API after credentials are
    /// saved. Injectable so tests don't make live network calls — the default
    /// implementation really does hit the platform.
    typealias LabelFetcher = @Sendable (PlatformInstance, Credentials) async -> String?

    static let liveLabelFetcher: LabelFetcher = { instance, credentials in
        guard let collector = CollectorRegistry.collector(for: instance) else { return nil }
        return await collector.fetchLabel(credentials: credentials)
    }

    private let database: AppDatabase
    private let keychain: KeychainStore
    private let labelFetcher: LabelFetcher

    /// - Parameters:
    ///   - keychain: defaults to the production store. Tests must pass one
    ///     scoped to a throwaway service.
    ///   - labelFetcher: defaults to a live API call. Tests must override it.
    init(database: AppDatabase,
         keychain: KeychainStore = .shared,
         labelFetcher: @escaping LabelFetcher = PlatformsViewModel.liveLabelFetcher) {
        self.database = database
        self.keychain = keychain
        self.labelFetcher = labelFetcher
    }

    // MARK: - API credential actions

    /// Refreshes `configuredInstances` and `hiddenPlatforms` from Keychain and UserDefaults.
    func reload() {
        configuredInstances = [:]
        for platform in Platform.allCases {
            let names = InstanceRegistry.instances(for: platform)
            let configured = names.filter { name in
                keychain.hasCredentials(for: PlatformInstance(platform: platform, instanceName: name))
            }
            if !configured.isEmpty {
                configuredInstances[platform] = configured
            }
        }
        hiddenPlatforms = Set(Platform.allCases.filter { PlatformVisibilityStore.isHidden($0) })
    }

    // MARK: - Visibility

    /// Hides a platform from the main grid and persists the state.
    func hidePlatform(_ platform: Platform) {
        PlatformVisibilityStore.hide(platform)
        hiddenPlatforms.insert(platform)
    }

    /// Shows a previously hidden platform and persists the state.
    func showPlatform(_ platform: Platform) {
        PlatformVisibilityStore.show(platform)
        hiddenPlatforms.remove(platform)
    }

    /// Returns `true` if the platform is currently hidden from the grid.
    func isHidden(_ platform: Platform) -> Bool {
        hiddenPlatforms.contains(platform)
    }

    /// Returns the currently stored credential values for an instance (empty dict if none).
    func loadValues(for instance: PlatformInstance) -> [String: String] {
        (try? keychain.load(for: instance))?.values ?? [:]
    }

    /// Saves the given values to the Keychain for the specified instance,
    /// then asynchronously fetches a display label from the platform API.
    func save(_ values: [String: String], for instance: PlatformInstance) throws {
        let credentials = Credentials(values)
        try keychain.save(credentials, for: instance)
        InstanceRegistry.add(instanceName: instance.instanceName, to: instance.platform)
        reload()
        // Auto-show the platform if it was previously hidden.
        PlatformVisibilityStore.show(instance.platform)
        hiddenPlatforms.remove(instance.platform)
        let fetch = labelFetcher
        Task {
            if let label = await fetch(instance, credentials) {
                InstanceLabels.setLabel(label, for: instance)
            }
        }
    }

    /// Removes credentials for an instance from the Keychain and its snapshot data.
    func delete(for instance: PlatformInstance) async throws {
        try keychain.delete(for: instance)
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
        try await importFile(at: url, for: instance)
    }

    /// Imports a file at a known URL for a known platform instance.
    func importFile(at url: URL, for instance: PlatformInstance) async throws {
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

        try await saveImport(platformData, for: instance)
    }

    /// Tries to auto-detect the platform from a dropped file and import it.
    /// Tries each compatible importer and uses the first that succeeds.
    func handleDroppedFile(at url: URL) async throws {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()

        let candidates: [(Platform, () throws -> PlatformData)]
        switch ext {
        case "csv":
            candidates = [
                (.linkedin, { try LinkedInImporter().parse(data: data) }),
                (.substack, { try SubstackImporter().parse(data: data) }),
            ]
        case "tsv", "txt", "text":
            candidates = [
                (.amazon,  { try AmazonKDPImporter().parse(data: data) }),
                (.oreilly, { try OReillyImporter().parse(data: data) }),
            ]
        case "eml":
            candidates = [(.oreilly, { try OReillyImporter().parse(data: data) })]
        case "xlsx":
            candidates = [(.linkedin, { try LinkedInXLSXParser().parse(data: data) })]
        default:
            throw ImportError.unsupportedExtension
        }

        for (platform, parse) in candidates {
            if let platformData = try? parse() {
                let instance = PlatformInstance(platform: platform)
                try await saveImport(platformData, for: instance)
                return
            }
        }
        throw ImportError.unrecognisedFormat
    }

    // MARK: - Private import helpers

    private func saveImport(_ platformData: PlatformData, for instance: PlatformInstance) async throws {
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
        try keychain.save(Credentials(["imported": "true"]), for: instance)
        InstanceRegistry.add(instanceName: instance.instanceName, to: instance.platform)
        reload()
        // Auto-show the platform if it was previously hidden.
        PlatformVisibilityStore.show(instance.platform)
        hiddenPlatforms.remove(instance.platform)

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
    case unsupportedExtension
    case unrecognisedFormat

    var errorDescription: String? {
        switch self {
        case .cancelled:                  return nil
        case .unsupportedPlatform(let p): return "File import is not yet supported for \(p.displayName)."
        case .unsupportedExtension:       return "Drop a CSV, TSV, TXT, or XLSX file to import."
        case .unrecognisedFormat:         return "The file format wasn't recognised. Make sure you're dropping a LinkedIn, Substack, Amazon KDP, or O'Reilly export."
        }
    }
}
