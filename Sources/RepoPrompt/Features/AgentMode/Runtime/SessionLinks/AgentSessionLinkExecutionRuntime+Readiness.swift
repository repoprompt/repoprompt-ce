import Foundation
import RepoPromptDomainRuntime

extension AgentSessionLinkExecutionRuntime {
    static func providerSwitchHasOwnedCarryingAttempt(_ session: TabSession) -> Bool {
        guard let delivery = session.pendingHandoff.providerSwitchDelivery,
              let proof = session.pendingHandoff.providerSwitchDispatch,
              proof.binding == session.currentRestorationBindingToken,
              proof.stopFence.permitsStart(of: session),
              delivery == .ready || session.pendingHandoff.isStagedForSend else { return false }
        if let ownership = proof.runOwnership {
            return session.isCurrentRunAttempt(ownership, expectedRunID: proof.runID)
        }
        if let wakeID = proof.autoWakeID, let attempt = session.oversight.pendingAutoWake,
           attempt.wakeID == wakeID, !attempt.isPeriodic, attempt.phase == .preparingDispatch,
           attempt.physicalOutcome == .notAttempted
        { return true }
        if let claimID = proof.composerAttemptID, session.activeComposerSubmitAttempt?.id == claimID { return true }
        if let inputID = proof.acceptedInputID {
            if session.hasLocalComposerCandidate(itemID: inputID, fence: proof.stopFence) { return true }
            // Non-local producers (session-link send, MCP resident, auto/periodic wakes) leave no
            // composer candidate, and their claim can be released before the spawned run registers
            // ownership. The durably accepted row itself is the carrying attempt until then.
            return session.items.contains { $0.id == inputID }
        }
        return false
    }

    static func providerSwitchUnconfirmed(_ session: TabSession) -> Bool {
        session.pendingHandoff.providerSwitchDelivery == .sending && !providerSwitchHasOwnedCarryingAttempt(session)
    }

    static func providerSwitchNeedsReview(_ session: TabSession, excluding inputID: UUID? = nil) -> Bool {
        guard session.pendingHandoff.providerSwitchDelivery != nil else { return false }
        // Once the carrying dispatch is physically bound, the handover is already en route to the
        // destination; input accepted after it is ordinary traffic on that run, never staleness.
        if session.pendingHandoff.providerSwitchDispatch?.dispatchID != nil { return false }
        let ownedInputID = inputID ?? (providerSwitchHasOwnedCarryingAttempt(session) ? session.pendingHandoff.providerSwitchDispatch?.acceptedInputID : nil)
        var positions: [UUID: Int] = [:]
        var inputs: [UUID: Int] = [:]
        func record(_ id: UUID, _ sequence: Int, input: Bool) {
            positions[id] = sequence
            if input, id != ownedInputID { inputs[id] = sequence }
        }
        for turn in session.transcript.turns {
            if let request = turn.request { record(request.id, request.sequenceIndex, input: true) }
            for activity in turn.allActivities {
                record(
                    activity.id,
                    activity.sequenceIndex,
                    input: activity.itemKind == .user
                        || activity.text == AgentLaneUpdateDisplayAttribution.canonicalSystemText
                        || activity.text == AgentChatItem.overseerCompactionRequestText
                )
            }
            for diagnostic in turn.summary?.recoveryDiagnostics ?? [] {
                record(diagnostic.id, diagnostic.sequenceIndex, input: false)
            }
        }
        for item in session.items {
            record(
                item.id,
                item.sequenceIndex,
                input: item.kind == .user
                    || item.text == AgentLaneUpdateDisplayAttribution.canonicalSystemText
                    || item.text == AgentChatItem.overseerCompactionRequestText
            )
        }
        guard let cutoffID = session.pendingHandoff.sourceItemID else { return !inputs.isEmpty }
        guard let cutoff = positions[cutoffID] else { return true }
        return inputs.values.contains { $0 > cutoff }
    }

    static func providerSwitchIsInFlightOnActiveRun(_ session: TabSession) -> Bool {
        session.pendingHandoff.providerSwitchDelivery == .sending
            && session.runState.isActive && providerSwitchHasOwnedCarryingAttempt(session)
            && session.pendingHandoff.providerSwitchDispatch?.dispatchID != nil
    }

    static func agentSessionLinkDeliveryReadinessSnapshot(
        session: TabSession,
        endpointMatchesGrant: Bool,
        isClosing: Bool,
        ignoresComposerSubmissionInFlight: Bool = false,
        ignoresSelfCompactRequestID: UUID? = nil,
        ignoresProviderSwitchStalenessAfterAcceptance: Bool = false
    ) -> AgentSessionLinkDeliveryReadiness.Snapshot {
        AgentSessionLinkDeliveryReadiness.Snapshot(
            hasLoadedPersistedState: session.hasLoadedPersistedState,
            restorationReadiness: session.qualifiedRestorationReadiness,
            bindingTransitionInProgress: session.bindingTransitionInProgress,
            isClosing: isClosing,
            endpointMatchesGrant: endpointMatchesGrant,
            runStateIsActive: session.runState.isActive
                || (!ignoresComposerSubmissionInFlight && providerSwitchHasOwnedCarryingAttempt(session)),
            terminalCommitInProgress: session.terminalCommitInProgress,
            mcpFollowUpRunPending: session.mcpFollowUpRunPending,
            isComposerSubmissionInFlight: ignoresComposerSubmissionInFlight
                ? false
                : session.isComposerSubmissionInFlight,
            isPreparingInitialWorktree: session.isPreparingInitialWorktree,
            isChangingExecutionLocation: session.isChangingExecutionLocation,
            pendingInstructionCount: session.pendingInstructions.count,
            pendingACPSteeringCount: session.pendingACPSteeringInstructions.count,
            pendingClaudeSteeringCount: session.pendingClaudeSteeringInstructions.count,
            pendingOversightAutoWake: session.oversight.pendingAutoWake != nil,
            pendingSelfCompact: session.selfCompactState.blocksOverseerDelivery
                && session.selfCompactState.active?.id != ignoresSelfCompactRequestID,
            selfCompactBlocksManagedStop: session.selfCompactState.blocksManagedStop
                && session.selfCompactState.active?.id != ignoresSelfCompactRequestID,
            stopInProgress: session.stopState.isStopping(binding: session.persistentSessionBindingIdentity),
            backgroundCompactionSettling: session.isSettlingACPBackgroundCompaction,
            providerSwitchUnconfirmed: providerSwitchUnconfirmed(session),
            providerHandoverNeedsReview: !ignoresProviderSwitchStalenessAfterAcceptance && providerSwitchNeedsReview(session),
            hasWaitingPrompt: session.waitingPrompt != nil,
            hasPendingAskUser: session.pendingAskUser != nil,
            hasPendingUserInputRequest: session.pendingUserInputRequest != nil,
            hasPendingApproval: session.pendingApproval != nil,
            hasPendingPermissionsRequest: session.pendingPermissionsRequest != nil,
            hasPendingMCPElicitationRequest: session.pendingMCPElicitationRequest != nil,
            hasPendingApplyEditsReview: session.pendingApplyEditsReview != nil,
            hasPendingWorktreeMergeReview: session.pendingWorktreeMergeReview != nil
        )
    }
}
