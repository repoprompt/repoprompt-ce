import Foundation
import RepoPromptCodexProvider

/// Single storage owner for a session's Codex turn routing and fallback work.
/// The session retains this owner across coordinator calls and controller replacement;
/// it is not a second session registry, run lifecycle, or durable store. Existing
/// coordinator paths still decide when to reset, cancel, drain, or restore drafts.
///
/// MainActor isolation matches the existing coordinator/session mutation order. No
/// task is launched here and no provider, view model, or presentation is retained.
@MainActor
final class CodexTurnRuntimeState {
    struct PendingAuthRetryTurn: Equatable {
        /// Undecorated provider text, exactly as every other Codex buffer stores it.
        var text: String
        var attachments: [AgentFileAttachment]
        var model: String?
        var reasoningEffort: String?
        var serviceTier: String?
        var attachmentReservationID: UUID?
        var expectedTurnID: String?
        var auditTurnID: UUID?
        var autoEffortApplied = false
        var retryAttempted: Bool = false
        /// Final monitoring identity composed for the original physical dispatch, if any.
        var monitoringDispatchID: AgentSessionLinkPromptDispatchID?
        var monitoringDispatchContext: AgentSessionLinkDispatchContext?
        /// Accepted oversight claim from the original dispatch, retained so managed-auth replay can
        /// attach the byte-equivalent supplement without acknowledging it twice.
        var monitoringClaim: AgentSessionLinkOutboundPromptClaim?
    }

    enum TurnKind: String {
        case user
        case compact
        case review
        case unknown
    }

    struct HookGateBindingIdentity: Equatable {
        let controllerInstanceID: ObjectIdentifier
        let controllerGeneration: UUID
    }

    struct AuthoritativeTurnIdentity: Equatable {
        let threadID: String
        let turnID: String
        let turnKind: TurnKind
        let controllerInstanceID: ObjectIdentifier
        let controllerGeneration: UUID
        let runID: UUID?
        let runAttemptID: UUID
    }

    struct AnonymousTurnLiveness: Equatable {
        let threadID: String
        let turnKind: TurnKind
        let controllerInstanceID: ObjectIdentifier
        let controllerGeneration: UUID
        let runID: UUID?
        let runAttemptID: UUID
    }

    enum FallbackOrigin: Equatable {
        case manual
        case mcp(attemptID: UUID)

        var isMCP: Bool {
            switch self {
            case .mcp:
                true
            case .manual:
                false
            }
        }
    }

    @MainActor
    final class DispatchSerialGate {
        private var nextTicket: UInt64 = 0
        private var servingTicket: UInt64 = 0
        private var cancelledTickets: Set<UInt64> = []
        private var waiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]

        func issueTicket() -> UInt64 {
            defer { nextTicket &+= 1 }
            return nextTicket
        }

        func awaitTurn(_ ticket: UInt64) async -> Bool {
            if cancelledTickets.remove(ticket) != nil {
                advancePastCancelledTickets()
                return false
            }
            if ticket == servingTicket {
                return true
            }
            return await withCheckedContinuation { continuation in
                waiters[ticket] = continuation
            }
        }

        func finish(_ ticket: UInt64) {
            guard ticket == servingTicket else { return }
            servingTicket &+= 1
            advancePastCancelledTickets()
            waiters.removeValue(forKey: servingTicket)?.resume(returning: true)
        }

        func cancel(_ ticket: UInt64) {
            if let waiter = waiters.removeValue(forKey: ticket) {
                waiter.resume(returning: false)
            }
            cancelledTickets.insert(ticket)
            guard ticket == servingTicket else { return }
            advancePastCancelledTickets()
            waiters.removeValue(forKey: servingTicket)?.resume(returning: true)
        }

        private func advancePastCancelledTickets() {
            while cancelledTickets.remove(servingTicket) != nil {
                servingTicket &+= 1
            }
        }
    }

    enum FallbackReason: Equatable {
        case activeWithoutAuthoritativeIdentity
        case staleAuthoritativeIdentity
        case nonSteerableTurn(kind: TurnKind)
        case noActiveTurn(failure: CodexAppServerClient.RequestFailure)
        case expectedTurnMismatch(
            expectedTurnID: String,
            actualTurnID: String?,
            failure: CodexAppServerClient.RequestFailure
        )
        case activeTurnNotSteerable(
            turnKind: String?,
            failure: CodexAppServerClient.RequestFailure
        )
    }

    struct FallbackSubmissionContext: Equatable {
        let queueID: UUID
        let providerText: String
        let attachments: [AgentFileAttachment]
        let taggedFileAttachments: [AgentTaggedFileAttachment]
        let draftText: String
        let optimisticUserItemID: UUID?
        let origin: FallbackOrigin
        let dispatchTicket: UInt64?
        var stopFence: AgentRunStartStopFence?
        /// Explicit composer provenance; absent/internal contexts never inherit companion access.
        var isLocalUserInput: Bool = false
    }

    struct FallbackBlockingTurn: Equatable {
        let threadID: String
        let turnID: String
        let controllerInstanceID: ObjectIdentifier
        let controllerGeneration: UUID
        let runID: UUID?
        let runAttemptID: UUID
    }

    struct PendingSteerLifecycleReconciliation: Equatable {
        let priorIdentity: AuthoritativeTurnIdentity
        let acceptedDispatchTurnID: String
    }

    enum FallbackQueueState: Equatable {
        case queued
        case eligibleForSuccessor(completedTurnID: String)
        case dispatching
        case awaitingLifecycleStart
        case lifecycleStarted
    }

    struct FallbackQueueEntry: Equatable, Identifiable {
        let id: UUID
        let providerText: String
        let attachments: [AgentFileAttachment]
        let taggedFileAttachments: [AgentTaggedFileAttachment]
        let model: String?
        let reasoningEffort: String?
        let serviceTier: String?
        var autoEffortApplied = false
        let attachmentReservationID: UUID?
        let optimisticUserItemID: UUID?
        let draftText: String
        let origin: FallbackOrigin
        let fallbackReason: FallbackReason
        let originThreadID: String
        let originControllerInstanceID: ObjectIdentifier
        let originControllerGeneration: UUID
        let originRunID: UUID
        let originRunAttemptID: UUID
        var blockingTurn: FallbackBlockingTurn?
        var state: FallbackQueueState
        var monitoringDispatchContext: AgentSessionLinkDispatchContext?
        var stopFence: AgentRunStartStopFence?
    }

    var pendingTurnKind: TurnKind?
    var pendingAuthRetryTurn: PendingAuthRetryTurn?
    var authoritativeActiveTurn: AuthoritativeTurnIdentity?
    var anonymousActiveTurn: AnonymousTurnLiveness?
    var routingObservedTurnID: String?
    var pendingSteerLifecycleReconciliation: PendingSteerLifecycleReconciliation?
    var fallbackQueue: [FallbackQueueEntry] = [] {
        didSet { onMonitorObservationInputsChanged?() }
    }

    var fallbackDispatchInFlight: FallbackQueueEntry? {
        didSet { onMonitorObservationInputsChanged?() }
    }

    /// Bridges queued follow-ups to a hook-gate owner's turn for as long as that turn has no
    /// settled identity of its own. Whichever of the accepted `turn/start` receipt or the
    /// lifecycle start arrives first supplies the value — they race, and the queue has to be
    /// bound by then either way. It is transient by design: the turn's terminal event either
    /// upgrades it to the identity-derived blocker or resolves the queue outright.
    var fallbackHookGateOwnerBlocker: FallbackBlockingTurn?
    var fallbackPumpTask: Task<Void, Never>? {
        didSet { onMonitorObservationInputsChanged?() }
    }

    var fallbackSuccessorRetryTask: Task<Void, Never>?
    let dispatchSerialGate = DispatchSerialGate()

    /// Weakly bridged by the session to its existing oversight observation channel.
    /// Fires with the same write semantics as the retired session stored properties.
    var onMonitorObservationInputsChanged: (() -> Void)?
}
