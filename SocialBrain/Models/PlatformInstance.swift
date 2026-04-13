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

    /// Shows just the platform name for the default instance; includes the
    /// label for additional instances (e.g. "GoatCounter — my-blog").
    public var displayName: String {
        instanceName == "default"
            ? platform.displayName
            : "\(platform.displayName) — \(instanceName)"
    }

    public init(platform: Platform, instanceName: String = "default") {
        self.platform = platform
        self.instanceName = instanceName
    }
}
