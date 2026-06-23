import Foundation

package struct RuntimeDiagnosticEvent: Equatable {
    package enum Kind: String, Equatable {
        case intervalBegan
        case intervalEnded
        case lifecycle
        case counter
    }

    package let kind: Kind
    package let subsystem: String
    package let name: String
    package let correlationID: UUID?
    package let intervalID: UUID?
    package let fields: [String: String]
    package let context: [String: String]

    package init(
        subsystem: String,
        name: String,
        kind: Kind,
        correlationID: UUID? = nil,
        intervalID: UUID? = nil,
        fields: [String: String] = [:],
        context: [String: String] = [:]
    ) {
        self.kind = kind
        self.subsystem = subsystem
        self.name = name
        self.correlationID = correlationID
        self.intervalID = intervalID
        self.fields = fields
        self.context = context
    }
}

package protocol RuntimeDiagnosticsSink: Sendable {
    var isEnabled: Bool { get }
    var installationPriority: Int { get }
    func captureContext() -> [String: String]
    func record(_ event: RuntimeDiagnosticEvent)
}

package extension RuntimeDiagnosticsSink {
    var isEnabled: Bool {
        true
    }

    var installationPriority: Int {
        1
    }

    func captureContext() -> [String: String] {
        [:]
    }
}

package struct NoOpRuntimeDiagnosticsSink: RuntimeDiagnosticsSink {
    package init() {}
    package var isEnabled: Bool {
        false
    }

    package var installationPriority: Int {
        0
    }

    package func record(_ event: RuntimeDiagnosticEvent) {}
}
