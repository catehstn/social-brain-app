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
    public var displayName: String {
        if let label = InstanceLabels.label(for: self) { return label }
        return instanceName == "default"
            ? platform.displayName
            : "\(platform.displayName) — \(instanceName)"
    }

    public init(platform: Platform, instanceName: String = "default") {
        self.platform = platform
        self.instanceName = instanceName
    }
}
