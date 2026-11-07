import Foundation
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

/// Resource selection and physical acquisition share the canonical domain catalog.
/// The caller retains the lease through provider settlement and response publication.
package enum MCPServerResourceAdmission {
    package enum Outcome {
        case admitted(MCPDomainToolResourceAdmissionController.Lease?)
        case rejected(code: String, message: String, deadlineExpired: Bool)
    }

    package static func acquire(
        host: MCPDomainHost,
        toolName: String,
        admissionClass: MCPToolAdmissionClass,
        windowID: Int?,
        deadline: MCPDomainAdmissionDeadline?,
        evidenceClass: MCPToolConcurrencyEvidenceClass,
        operationIdentity: MCPDomainToolOperationIdentity
    ) async -> Outcome {
        let resource: MCPDomainToolResourceAdmissionController.Resource
        let waitingDescription: String
        switch admissionClass {
        case .exclusive:
            if MCPGlobalToolName.orderedToolNames.contains(toolName) {
                resource = .appWide
            } else if let windowID {
                resource = .window(windowID)
            } else {
                return .rejected(code: "tool_execution_mutation_resource_unresolved", message: "The exclusive tool '\(toolName)' has no resolved window resource.", deadlineExpired: false)
            }
            waitingDescription = "exclusive resource"
        case .smallRead, .fileRead:
            guard let windowID else {
                let kind = admissionClass == .smallRead ? "small-read" : "file-read"
                return .rejected(code: "tool_execution_read_resource_unresolved", message: "The \(kind) tool '\(toolName)' has no resolved window/store resource.", deadlineExpired: false)
            }
            resource = .window(windowID)
            waitingDescription = admissionClass == .smallRead ? "window/store read" : "file-read"
        case .control, .gitRead, .fileSearch:
            return .admitted(nil)
        }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            let lease: MCPDomainToolResourceAdmissionController.Lease
            switch admissionClass {
            case .exclusive:
                lease = try await host.acquireMutationResourceAdmission(resource, admissionDeadline: deadline)
            case .smallRead:
                guard case let .window(windowID) = resource else { preconditionFailure("Window resource required") }
                lease = try await host.acquireSmallReadResourceAdmission(windowID: windowID, admissionDeadline: deadline)
            case .fileRead:
                guard case let .window(windowID) = resource else { preconditionFailure("Window resource required") }
                lease = try await host.acquireFileReadResourceAdmission(windowID: windowID, admissionDeadline: deadline)
            case .control, .gitRead, .fileSearch:
                preconditionFailure("Non-resource lanes return before acquisition")
            }
            MCPToolConcurrencyEvidenceRecorder.shared.recordLeaseWait(classKey: evidenceClass, operationIdentity: operationIdentity, milliseconds: start.duration(to: clock.now).mcpMilliseconds)
            return .admitted(lease)
        } catch {
            MCPToolConcurrencyEvidenceRecorder.shared.recordRejection(classKey: evidenceClass, operationIdentity: operationIdentity, reason: .leaseWaitTermination(for: error))
            return .rejected(code: "tool_execution_connection_terminal", message: "The MCP connection closed while waiting for \(waitingDescription) admission.", deadlineExpired: error is MCPDomainAdmissionDeadline.Expired)
        }
    }
}
