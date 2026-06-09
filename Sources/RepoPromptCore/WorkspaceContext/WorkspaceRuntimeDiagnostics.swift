import Foundation

package struct WorkspaceRuntimeDiagnosticEvent: Equatable {
    package enum Kind: String {
        case intervalBegan
        case intervalEnded
        case lifecycle
        case counter
    }

    package let subsystem: String
    package let name: String
    package let kind: Kind
    package let correlationID: UUID?
    package let intervalID: UUID?
    package let fields: [String: String]

    package init(
        subsystem: String,
        name: String,
        kind: Kind,
        correlationID: UUID? = nil,
        intervalID: UUID? = nil,
        fields: [String: String] = [:]
    ) {
        self.subsystem = subsystem
        self.name = name
        self.kind = kind
        self.correlationID = correlationID
        self.intervalID = intervalID
        self.fields = fields
    }
}

package protocol WorkspaceRuntimeDiagnosticsSink: Sendable {
    func record(_ event: WorkspaceRuntimeDiagnosticEvent)
}

package struct NoopWorkspaceRuntimeDiagnosticsSink: WorkspaceRuntimeDiagnosticsSink {
    package init() {}
    package func record(_: WorkspaceRuntimeDiagnosticEvent) {}
}
