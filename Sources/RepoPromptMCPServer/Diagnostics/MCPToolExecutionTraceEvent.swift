import Foundation
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptShared

package struct MCPToolExecutionTraceEvent: Equatable, CustomStringConvertible {
    package typealias Phase = MCPToolExecutionDiagnosticEvent.Phase

    package let toolName: String
    package let operationIdentity: MCPDomainToolOperationIdentity
    package let connectionID: UUID
    package let invocationID: UUID
    package let runID: UUID?
    package let requestIdentity: MCPRequestTimelineIdentity?
    package let contractKind: MCPToolExecutionContract.Kind
    package let executionDeadlineSeconds: Double?
    package let cleanupGraceSeconds: Double?
    package let cleanupDisposition: MCPToolExecutionCleanupDisposition?
    package let phase: Phase
    package let elapsedMilliseconds: Double
    package let cancellationRequested: Bool?
    package let cancellationOutcome: String?
    package let cancellationOrigin: MCPToolExecutionCancellationOrigin?
    package let settlement: String?
    package let graceOutcome: String?
    package let escalationReason: String?
    package let handlerPhase: MCPToolExecutionHandlerPhaseSnapshot?
    package let handlerPhaseAgeMilliseconds: Double?

    package init(
        toolName: String,
        operationIdentity: MCPDomainToolOperationIdentity,
        connectionID: UUID,
        invocationID: UUID,
        runID: UUID?,
        requestIdentity: MCPRequestTimelineIdentity? = nil,
        contractKind: MCPToolExecutionContract.Kind,
        executionDeadlineSeconds: Double?,
        cleanupGraceSeconds: Double?,
        cleanupDisposition: MCPToolExecutionCleanupDisposition?,
        phase: Phase,
        elapsedMilliseconds: Double,
        cancellationRequested: Bool?,
        cancellationOutcome: String?,
        cancellationOrigin: MCPToolExecutionCancellationOrigin?,
        settlement: String?,
        graceOutcome: String?,
        escalationReason: String?,
        handlerPhase: MCPToolExecutionHandlerPhaseSnapshot?,
        handlerPhaseAgeMilliseconds: Double?
    ) {
        self.toolName = toolName
        self.operationIdentity = operationIdentity
        self.connectionID = connectionID
        self.invocationID = invocationID
        self.runID = runID
        self.requestIdentity = requestIdentity
        self.contractKind = contractKind
        self.executionDeadlineSeconds = executionDeadlineSeconds
        self.cleanupGraceSeconds = cleanupGraceSeconds
        self.cleanupDisposition = cleanupDisposition
        self.phase = phase
        self.elapsedMilliseconds = elapsedMilliseconds
        self.cancellationRequested = cancellationRequested
        self.cancellationOutcome = cancellationOutcome
        self.cancellationOrigin = cancellationOrigin
        self.settlement = settlement
        self.graceOutcome = graceOutcome
        self.escalationReason = escalationReason
        self.handlerPhase = handlerPhase
        self.handlerPhaseAgeMilliseconds = handlerPhaseAgeMilliseconds
    }

    package var isAlwaysEmitted: Bool {
        phase.isAlwaysEmitted
    }

    package var description: String {
        var fields = [
            "phase=\(phase.rawValue)",
            "tool=\(toolName)",
            "operation=\(operationIdentity.normalizedOperation)",
            "connection_id=\(connectionID.uuidString)",
            "invocation_id=\(invocationID.uuidString)",
            "contract=\(contractKind.rawValue)",
            "elapsed_ms=\(String(format: "%.3f", elapsedMilliseconds))"
        ]
        if let runID { fields.append("run_id=\(runID.uuidString)") }
        if let requestIdentity {
            if let requestID = requestIdentity.jsonRPCRequestID {
                fields.append("request_id=\(requestID)")
            }
            if let requestConnectionID = requestIdentity.connectionID {
                fields.append("request_connection_id=\(requestConnectionID)")
            }
            if let requestGeneration = requestIdentity.connectionGeneration {
                fields.append("request_generation=\(requestGeneration)")
            }
            if let requestOrdinal = requestIdentity.requestOrdinal {
                fields.append("request_ordinal=\(requestOrdinal)")
            }
        }
        if let executionDeadlineSeconds { fields.append("deadline_s=\(executionDeadlineSeconds)") }
        if let cleanupGraceSeconds { fields.append("grace_s=\(cleanupGraceSeconds)") }
        if let cleanupDisposition { fields.append("cleanup_disposition=\(cleanupDisposition.rawValue)") }
        if let cancellationRequested { fields.append("cancellation_requested=\(cancellationRequested)") }
        if let cancellationOutcome { fields.append("cancellation_outcome=\(cancellationOutcome)") }
        if let cancellationOrigin { fields.append("cancellation_origin=\(cancellationOrigin.rawValue)") }
        if let settlement { fields.append("settlement=\(settlement)") }
        if let graceOutcome { fields.append("grace_outcome=\(graceOutcome)") }
        if let escalationReason { fields.append("escalation_reason=\(escalationReason)") }
        if let handlerPhase {
            fields.append("handler_phase=\(handlerPhase.phase.rawValue)")
            fields.append("handler_phase_transition=\(handlerPhase.transition.rawValue)")
            fields.append("handler_phase_elapsed_ms=\(String(format: "%.3f", handlerPhase.elapsedMilliseconds))")
        }
        if let handlerPhaseAgeMilliseconds {
            fields.append("handler_phase_age_ms=\(String(format: "%.3f", handlerPhaseAgeMilliseconds))")
        }
        return fields.joined(separator: " ")
    }
}
