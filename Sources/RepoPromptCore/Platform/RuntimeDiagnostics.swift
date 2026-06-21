import Foundation

package struct RuntimeDiagnosticEvent: Equatable {
    package enum Kind: Equatable {
        case intervalBegan
        case intervalEnded
        case lifecycle
        case counter
    }

    package let kind: Kind
    package let subsystem: String
    package let name: String
    package let correlationID: UUID?
    package let fields: [String: String]

    package init(
        kind: Kind,
        subsystem: String,
        name: String,
        correlationID: UUID? = nil,
        fields: [String: String] = [:]
    ) {
        self.kind = kind
        self.subsystem = subsystem
        self.name = name
        self.correlationID = correlationID
        self.fields = fields
    }
}

package protocol RuntimeDiagnosticsSink: Sendable {
    func record(_ event: RuntimeDiagnosticEvent)
}

package struct NoOpRuntimeDiagnosticsSink: RuntimeDiagnosticsSink {
    package init() {}
    package func record(_ event: RuntimeDiagnosticEvent) {}
}
