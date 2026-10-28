import Foundation
import RepoPromptShared

/// Closed lifecycle evidence. Only canonical tool/operation labels and correlation IDs cross
/// this boundary; arguments, paths, prompt text, and result bodies cannot be represented.
package struct MCPToolExecutionDiagnosticEvent: Sendable {
    package enum ContractKind: String, Sendable {
        case bounded
        case longSynchronousCancellable = "long_synchronous_cancellable"
        case lifecycleManagedCancellable = "lifecycle_managed_cancellable"
        case interactiveCancellable = "interactive_cancellable"
        case workspaceLifecycleCancellable = "workspace_lifecycle_cancellable"
    }

    package enum CleanupDisposition: String, Sendable {
        case forceDisconnect = "force_disconnect"
        case detachAndSettle = "detach_and_settle"
    }

    package enum CancellationOrigin: String, Sendable {
        case watchdogDeadline = "watchdog_deadline"
        case requestCancellation = "request_cancellation"
        case clientDeadline = "client_deadline"
        case serverExportEnvelope = "server_export_envelope"
    }

    package enum Outcome: String, Sendable {
        case success, cancellation, error
    }

    package enum Settlement: String, Sendable { case detached }

    package enum GraceOutcome: String, Sendable {
        case expired, settled, lateCompletion = "late_completion", capped
    }

    package enum EscalationReason: String, Sendable {
        case outerEnvelopeCleanupCap = "outer_envelope_cleanup_cap"
        case handlerIgnoredCancellation = "handler_ignored_cancellation"
        case detachDispositionHandlerIgnoredCancellation = "detach_disposition_handler_ignored_cancellation"
    }

    package enum Phase: String, Sendable {
        case contractSelected = "execution_contract_selected"
        case started = "execution_started"
        case handlerCompleted = "execution_handler_completed"
        case handlerPhaseTransition = "execution_handler_phase_transition"
        case deadlineExpired = "execution_deadline_expired"
        case cancellationRequested = "execution_cancellation_requested"
        case settledDuringGrace = "execution_settled_during_grace"
        case cleanupGraceExpired = "execution_cleanup_grace_expired"
        case detachedForSettlement = "execution_detached_for_settlement"
        case detachedSettled = "execution_detached_settled"
        case connectionForceDisconnectRequested = "connection_force_disconnect_requested"

        package var isAlwaysEmitted: Bool {
            switch self {
            case .deadlineExpired, .cancellationRequested, .settledDuringGrace,
                 .cleanupGraceExpired, .detachedForSettlement, .detachedSettled,
                 .connectionForceDisconnectRequested:
                true
            case .contractSelected, .started, .handlerCompleted, .handlerPhaseTransition:
                false
            }
        }
    }

    package let toolName: String
    package let canonicalTool: String
    package let normalizedOperation: String
    package let connectionID: UUID
    package let invocationID: UUID
    package let runID: UUID?
    package let requestIdentity: MCPRequestTimelineIdentity?
    package let contractKind: ContractKind
    package let executionDeadlineSeconds: Double?
    package let cleanupGraceSeconds: Double?
    package let cleanupDisposition: CleanupDisposition?
    package let phase: Phase
    package let elapsedMilliseconds: Double
    package let cancellationRequested: Bool?
    package let cancellationOutcome: Outcome?
    package let cancellationOrigin: CancellationOrigin?
    package let settlement: Settlement?
    package let graceOutcome: GraceOutcome?
    package let escalationReason: EscalationReason?
    package let handlerPhase: MCPToolExecutionHandlerPhaseSnapshot?
    package let handlerPhaseAgeMilliseconds: Double?

    package init(
        toolName: String,
        canonicalTool: String,
        normalizedOperation: String,
        connectionID: UUID,
        invocationID: UUID,
        runID: UUID?,
        requestIdentity: MCPRequestTimelineIdentity?,
        contractKind: ContractKind,
        executionDeadlineSeconds: Double?,
        cleanupGraceSeconds: Double?,
        cleanupDisposition: CleanupDisposition?,
        phase: Phase,
        elapsedMilliseconds: Double,
        cancellationRequested: Bool?,
        cancellationOutcome: Outcome?,
        cancellationOrigin: CancellationOrigin?,
        settlement: Settlement?,
        graceOutcome: GraceOutcome?,
        escalationReason: EscalationReason?,
        handlerPhase: MCPToolExecutionHandlerPhaseSnapshot?,
        handlerPhaseAgeMilliseconds: Double?
    ) {
        self.toolName = toolName
        self.canonicalTool = canonicalTool
        self.normalizedOperation = normalizedOperation
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
}

package protocol MCPToolExecutionEventSink: Sendable {
    func record(_ event: MCPToolExecutionDiagnosticEvent)
}

package struct NoopMCPToolExecutionEventSink: MCPToolExecutionEventSink {
    package init() {}
    package func record(_: MCPToolExecutionDiagnosticEvent) {}
}
