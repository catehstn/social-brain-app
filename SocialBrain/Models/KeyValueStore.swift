import Foundation

/// The operations the injected stores need from `UserDefaults`.
///
/// Declared as a protocol so tests can supply an in-memory store. Backing tests
/// with `UserDefaults(suiteName:)` writes a plist into the app container that
/// nothing ever deletes — 266 such files had accumulated here before this was
/// introduced.
///
/// This lives in its own file because `InstanceLabels` and `AnalyticsGoal`
/// compile into the MCP targets as well as the app, and the protocol used to
/// sit in `InstanceRegistry.swift`, which does not (#58, #90).
protocol KeyValueStore: Sendable {
    func stringArray(forKey key: String) -> [String]?
    func set(_ value: [String], forKey key: String)
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
    /// Added for `InstanceLabels` and `AnalyticsGoal`, which wrote
    /// `UserDefaults.standard` directly until #58.
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
    func removeObject(forKey key: String)
}

/// `@unchecked Sendable`: `UserDefaults` is documented thread-safe but not
/// annotated.
extension UserDefaults: @unchecked @retroactive Sendable {}

extension UserDefaults: KeyValueStore {
    public func set(_ value: [String], forKey key: String) {
        set(value as Any?, forKey: key)
    }

    public func set(_ value: String, forKey key: String) {
        set(value as Any?, forKey: key)
    }
}
