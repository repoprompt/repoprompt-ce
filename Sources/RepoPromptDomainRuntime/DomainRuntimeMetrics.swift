import Foundation

package enum DomainRuntimeMetricPhase: String, Codable, Sendable {
    case runtime
    case backend
    case catalog
    case commit
    case projection
}

package struct DomainRuntimeMetric: Codable, Equatable, Sendable {
    package let phase: DomainRuntimeMetricPhase
    package let name: String
    package let timestamp: Date
    package let dimensions: [String: String]

    package init(
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

package struct DomainRuntimeMetricsSink: Sendable {
    private let recordBlock: @Sendable (DomainRuntimeMetric) -> Void

    package init(record: @escaping @Sendable (DomainRuntimeMetric) -> Void) {
        recordBlock = record
    }

    package func record(_ metric: DomainRuntimeMetric) {
        recordBlock(metric)
    }

    package static let disabled = DomainRuntimeMetricsSink { _ in }
}
