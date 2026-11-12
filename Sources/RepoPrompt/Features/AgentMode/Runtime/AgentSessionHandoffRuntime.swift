import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Owns resume-recovery staging and ordinary handoff consumption. Workspace context is supplied
/// as a value by the host; neither a presentation nor its lifetime is delivery authority.
@MainActor
final class AgentSessionHandoffRuntime {
    enum RecoveryResult {
        case unchanged, staged(AgentPendingHandoffState), refused

        var permitsFreshSession: Bool {
            if case .refused = self { return false }
            return true
        }
    }

    @MainActor
    struct RecoveryPreparation {
        fileprivate let scope: AgentSessionRuntimeStore.Scope
        fileprivate let session: AgentTabSession
        fileprivate let binding: AgentPersistentSessionBindingIdentity?
        fileprivate let transitionGeneration: UInt64
        fileprivate let stopFence: AgentRunStartStopFence
        fileprivate let runID: UUID?
        fileprivate let ownership: AgentRunOwnership?
        fileprivate let agent: AgentProviderKind
        fileprivate let handoffRevision: UInt64
        fileprivate let sourceTabName: String
        fileprivate let sourceItemID: UUID?
        fileprivate let transcriptXML: String
    }

    private weak var scope: AgentSessionRuntimeStore.Scope?

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
    }

    /// Capture before the host awaits context IO. The preparation retains the originating scope,
    /// not a window, and may only commit back to this exact object and unchanged incarnation.
    func prepareRecovery(
        for session: AgentTabSession,
        sourceTabName: String,
        transcriptXML: @autoclosure () -> String
    ) -> RecoveryPreparation? {
        guard let scope, !Task.isCancelled, !scope.isRetiring,
              scope.sessions[session.tabID] === session, !session.bindingTransitionInProgress,
              session.pendingHandoff.providerSwitchDelivery == nil,
              session.oversight.pendingAutoWake?.isPeriodic != true,
              session.pendingHandoff.payload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        else { return nil }
        return RecoveryPreparation(
            scope: scope, session: session,
            binding: session.persistentSessionBindingIdentity,
            transitionGeneration: session.bindingTransitionGeneration,
            stopFence: .init(session: session), runID: session.runID,
            ownership: session.activeRunOwnership, agent: session.selectedAgent,
            handoffRevision: session.pendingHandoffRevision,
            sourceTabName: sourceTabName,
            sourceItemID: session.items.last(where: { $0.kind != .thinking })?.id,
            transcriptXML: transcriptXML()
        )
    }

    /// The only staging commit. A cancelled preparation, Stop, retirement, rebind, new run,
    /// intervening handoff (including change-and-restore) cannot be overwritten. Transcript context
    /// is a frozen cutoff snapshot: later rows or model-only changes do not invalidate that snapshot.
    func stageRecovery(
        _ preparation: RecoveryPreparation,
        initialThreadContextBlock: String?
    ) -> AgentPendingHandoffState? {
        let session = preparation.session
        guard let scope, scope === preparation.scope, !Task.isCancelled, !scope.isRetiring,
              scope.sessions[session.tabID] === session, !session.bindingTransitionInProgress,
              session.persistentSessionBindingIdentity == preparation.binding,
              session.bindingTransitionGeneration == preparation.transitionGeneration,
              preparation.stopFence.permitsStart(of: session),
              session.runID == preparation.runID, session.activeRunOwnership == preparation.ownership,
              session.selectedAgent == preparation.agent,
              session.pendingHandoffRevision == preparation.handoffRevision,
              session.oversight.pendingAutoWake?.isPeriodic != true
        else { return nil }
        let escapedSourceTabName = preparation.sourceTabName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let payload = Self.composeResumeRecoveryPayload(
            sourceTabName: escapedSourceTabName, sourceAgentName: preparation.agent.displayName,
            transcriptXML: preparation.transcriptXML, initialThreadContextBlock: initialThreadContextBlock,
            deliveryID: UUID().uuidString
        )
        let staged = AgentPendingHandoffState(
            payload: payload, createdAt: Date(), sourceItemID: preparation.sourceItemID,
            defersProviderLockUntilSend: false, isStagedForSend: false,
            executionLocationFailure: session.pendingHandoff.executionLocationFailure
        )
        session.pendingHandoff = staged
        session.isDirty = true
        return staged
    }

    func canReuseRecovery(for session: AgentTabSession) -> Bool {
        guard let scope, !Task.isCancelled, !scope.isRetiring,
              scope.sessions[session.tabID] === session, !session.bindingTransitionInProgress,
              session.oversight.pendingAutoWake?.isPeriodic != true
        else { return false }
        return session.pendingHandoff.providerSwitchDelivery != nil
            || session.pendingHandoff.payload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func prependPendingHandoffIfNeeded(_ text: String, session: AgentTabSession) -> String {
        // Send admission/Stop fences stay with the originating runner. Retirement must not
        // silently strip an already-owned turn's handoff from its provider-facing text.
        guard let scope, scope.sessions[session.tabID] === session,
              session.pendingHandoff.providerSwitchDelivery == nil,
              session.oversight.pendingAutoWake?.isPeriodic != true,
              let payload = session.pendingHandoff.payload,
              !session.pendingHandoff.isStagedForSend
        else { return text }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        session.pendingHandoff.isStagedForSend = true
        return trimmed + "\n\n" + text
    }

    func recordSendOutcome(for session: AgentTabSession, didSend: Bool) {
        // Provider-switch confirmation keeps its own exact physical-dispatch authority.
        guard let scope, scope.sessions[session.tabID] === session,
              session.pendingHandoff.providerSwitchDelivery == nil,
              session.oversight.pendingAutoWake?.isPeriodic != true,
              session.pendingHandoff.isStagedForSend
        else { return }
        if didSend {
            session.pendingHandoff.clearAfterSend()
            session.isDirty = true
            scope.persistence.scheduleSave(for: session)
        } else {
            session.pendingHandoff.isStagedForSend = false
        }
    }

    nonisolated static func composeResumeRecoveryPayload(
        sourceTabName: String,
        sourceAgentName: String,
        transcriptXML: String,
        initialThreadContextBlock: String?,
        deliveryID: String
    ) -> String {
        let trimmedTranscriptXML = transcriptXML.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInitialThreadContextBlock = initialThreadContextBlock?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var payloadSections: [String] = []
        if let trimmedInitialThreadContextBlock,
           !trimmedInitialThreadContextBlock.isEmpty
        {
            payloadSections.append(
                """
                <original_thread_context>
                \(trimmedInitialThreadContextBlock)
                </original_thread_context>
                """
            )
        }
        return Self.forkedSessionEnvelope(
            sourceTabName: sourceTabName, deliveryID: deliveryID,
            introduction: "You are continuing a session that was restarted after a native resume failed for \(sourceAgentName). Use the recovered transcript below, plus any preserved thread context, to continue seamlessly.",
            sections: payloadSections, transcriptXML: trimmedTranscriptXML
        )
    }

    nonisolated static func forkedSessionEnvelope(
        sourceTabName: String, deliveryID: String, introduction: String,
        sections: [String], transcriptXML: String
    ) -> String {
        var sections = sections
        if !transcriptXML.isEmpty { sections.append(transcriptXML) }
        let payloadBody = sections.joined(separator: "\n\n")
        return """
        <forked_session source="\(sourceTabName)" delivery_id="\(deliveryID)">
        \(introduction)

        \(payloadBody)
        </forked_session>
        """
    }
}
