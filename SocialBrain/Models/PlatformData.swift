import Foundation

/// A single analytics value; supports integer, floating-point, and string types.
public enum MetricValue: Sendable, Equatable {
    case int(Int)
    case double(Double)
    case string(String)

    /// Convenience accessor for numeric values (casts int → double if needed).
    public var numberValue: Double? {
        switch self {
        case .int(let v):    return Double(v)
        case .double(let v): return v
        case .string:        return nil
        }
    }

    public var intValue: Int? {
        guard case .int(let v) = self else { return nil }
        return v
    }

    public var stringValue: String? {
        guard case .string(let v) = self else { return nil }
        return v
    }
}

extension MetricValue: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "int":
            self = .int(try c.decode(Int.self, forKey: .value))
        case "double":
            self = .double(try c.decode(Double.self, forKey: .value))
        case "string":
            self = .string(try c.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unknown metric type '\(type)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .int(let v):
            try c.encode("int", forKey: .type)
            try c.encode(v, forKey: .value)
        case .double(let v):
            try c.encode("double", forKey: .type)
            try c.encode(v, forKey: .value)
        case .string(let v):
            try c.encode("string", forKey: .type)
            try c.encode(v, forKey: .value)
        }
    }
}

/// Analytics snapshot returned by a collector for one platform at one point in time.
public struct PlatformData: Sendable, Codable {
    public let platform: Platform
    public let collectedAt: Date
    /// Named metrics; keys are platform-specific (e.g. "subscriber_count", "followers").
    public let metrics: [String: MetricValue]

    public init(
        platform: Platform,
        collectedAt: Date = .now,
        metrics: [String: MetricValue]
    ) {
        self.platform = platform
        self.collectedAt = collectedAt
        self.metrics = metrics
    }

    public func intMetric(_ key: String) -> Int? {
        metrics[key]?.intValue
    }

    public func doubleMetric(_ key: String) -> Double? {
        metrics[key]?.numberValue
    }

    public func stringMetric(_ key: String) -> String? {
        metrics[key]?.stringValue
    }
}
