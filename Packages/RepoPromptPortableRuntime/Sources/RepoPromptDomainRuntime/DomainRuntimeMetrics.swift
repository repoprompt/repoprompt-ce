import Foundation

public enum DomainRuntimeMetricPhase: String, Codable, Sendable {
    case runtime
    case backend
    case catalog
    case commit
    case projection
}

public struct DomainRuntimeMetric: Codable, Equatable, Sendable {
    public let phase: DomainRuntimeMetricPhase
    public let name: String
    public let timestamp: Date
    public let dimensions: [String: String]

    public init(
        phase: DomainRuntimeMetricPhase,
        name: String,
        timestamp: Date = Date(),
        dimensions: [String: String]
    ) {
        self.phase = phase
        self.name = name
        self.timestamp = timestamp
        self.dimensions = dimensions
    }
}

public struct DomainRuntimeMetricsSink: Sendable {
    private let recordBlock: @Sendable (DomainRuntimeMetric) -> Void

    public init(record: @escaping @Sendable (DomainRuntimeMetric) -> Void) {
        recordBlock = record
    }

    public func record(_ metric: DomainRuntimeMetric) {
        recordBlock(metric)
    }

    public static let disabled = DomainRuntimeMetricsSink { _ in }
}
