import Foundation

/// Identifies one configured account on one platform.
///
/// Every platform always has at least one instance named `"default"`.
/// Additional instances have a user-supplied label (e.g. `"my-blog"`, `"client-site"`).
public struct PlatformInstance: Hashable, Sendable, Identifiable, Codable {
    public let platform: Platform
    /// `"default"` for the first instance; user-defined for extras.
    public let instanceName: String

    public var id: String { "\(platform.rawValue):\(instanceName)" }

    /// Shows a human-readable name for this instance.
    ///
    /// Priority: stored label (auto-fetched from the platform API) →
    /// platform name for the default instance → "Platform — instanceName"
    /// for additional instances.
    public var displayName: String { displayName(using: .shared) }

    /// The same, against a given label store.
    ///
    /// The property above reads the production one, which means anything using
    /// it depends on real preferences — `PromptAssembler`'s headers did, so a
    /// stored label silently changed the prompt under test. That is not
    /// hypothetical: a mutation experiment on 2026-09-19 wrote three labels
    /// into the real defaults and broke a PromptAssembler test that had been
    /// passing by luck (#58, #90).
    func displayName(using labels: InstanceLabels) -> String {
        if let label = labels.label(for: self) { return label }
        return instanceName == "default"
            ? platform.displayName
            : "\(platform.displayName) — \(instanceName)"
    }

    public init(platform: Platform, instanceName: String = "default") {
        self.platform = platform
        self.instanceName = instanceName
    }
}
