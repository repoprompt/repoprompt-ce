import Foundation

/// Settles a provisional background tab using the same lifecycle authority for any
/// publisher. A cancellation does not erase working-commit or recovery evidence.
@MainActor
enum WorkspaceAgentFreshAdmission {
    enum Result: Equatable {
        case created(ComposeTabState, AgentAdmissionPersistenceReceipt, AgentProvisionalAdmissionClaim)
        case rejected(AgentAdmissionPersistenceReceipt, AgentSessionLifecycleAuthority.RejectionReason)
        case recoveryRequired(
            AgentProvisionalAdmissionIdentity,
            AgentAdmissionPersistenceReceipt,
            AgentSessionLifecycleAuthority.RejectionReason,
            AgentAdmissionRecoveryOutcome
        )
    }

    enum Preparation {
        case ready(ComposeTabState, AgentProvisionalAdmissionClaim)
        case rejected(Result)
    }

    /// A composed or stashed carrier owns its IDs even when it is not presented. Check
    /// both namespaces before handing a new tab to the blocked-writer preparation step.
    static func prepare(
        workspace: WorkspaceModel,
        sessionID: UUID,
        bindingEmptyTabID: UUID? = nil,
        makeTab: () -> ComposeTabState?
    ) -> Preparation {
        let existing = workspace.composeTabs + workspace.stashedTabs.map(\.tab)
        guard !existing.contains(where: { $0.activeAgentSessionID == sessionID }) else {
            return .rejected(rejected("session_already_bound", reason: .sessionIdentityChanged))
        }
        let tab: ComposeTabState
        if let bindingEmptyTabID {
            let matching = existing.filter { $0.id == bindingEmptyTabID }
            guard matching.count == 1, var empty = workspace.composeTabs.first(where: { $0.id == bindingEmptyTabID }),
                  empty.activeAgentSessionID == nil
            else { return .rejected(rejected("target_tab_binding_changed", reason: .sessionIdentityChanged)) }
            empty.activeAgentSessionID = sessionID
            empty.lastModified = Date()
            tab = empty
        } else {
            guard let fresh = makeTab() else {
                return .rejected(rejected("workspace_changed", reason: .workspaceChanged))
            }
            guard fresh.activeAgentSessionID == sessionID,
                  !existing.contains(where: { $0.id == fresh.id })
            else {
                return .rejected(rejected("tab_identity_collision", reason: .sessionIdentityChanged))
            }
            tab = fresh
        }
        let claim = AgentProvisionalAdmissionClaim(identity: .init(
            recoveryID: UUID(), workspaceID: workspace.id, tabID: tab.id,
            sessionID: sessionID, replacementTabID: UUID()
        ))
        return .ready(tab, claim)
    }

    static func rejected(_ code: String, reason: AgentSessionLifecycleAuthority.RejectionReason) -> Result {
        .rejected(.init(outcome: .rejected(reason: code), commitEvidence: .none), reason)
    }

    static func settle(
        tab: ComposeTabState,
        claim: AgentProvisionalAdmissionClaim,
        receipt: AgentAdmissionPersistenceReceipt,
        bindingStillCurrent: Bool,
        isCancelled: Bool,
        lifecycleAuthority: AgentSessionLifecycleAuthority,
        rollbackProjection: () async -> Void,
        recover: () async -> AgentAdmissionRecoveryOutcome,
        didRecover: (AgentAdmissionRecoveryOutcome) async -> Void = { _ in }
    ) async throws -> Result {
        let identity = claim.identity
        let decision = lifecycleAuthority.decideDurableAdmission(
            receipt: receipt,
            targetWorkspaceID: identity.workspaceID,
            bindingStillCurrent: bindingStillCurrent,
            isCancelled: isCancelled
        )
        switch decision {
        case .commit:
            return .created(tab, receipt, claim)
        case let .localRollback(reason):
            await rollbackProjection()
            claim.markComplete()
            if isCancelled { throw CancellationError() }
            return .rejected(receipt, reason)
        case let .recoverWorkspace(reason):
            guard claim.beginWorkspaceRecovery() else {
                // A displaced claim does not prove that the carrier was removed.
                return .recoveryRequired(identity, receipt, reason, .ownershipChanged)
            }
            let outcome = await recover()
            let shouldRollbackProjection: Bool
            let requiresRecoveryEvidence: Bool
            switch outcome {
            case .recovered, .alreadyRecovered, .localOnly:
                claim.markWorkspaceRecovered()
                claim.markComplete()
                shouldRollbackProjection = true
                requiresRecoveryEvidence = false
            case .ownershipChanged:
                claim.markComplete()
                shouldRollbackProjection = true
                requiresRecoveryEvidence = true
            case .retryablePartial:
                shouldRollbackProjection = true
                requiresRecoveryEvidence = true
            case .failed, .blockedManual:
                shouldRollbackProjection = false
                requiresRecoveryEvidence = true
            }
            await didRecover(outcome)
            if shouldRollbackProjection { await rollbackProjection() }
            if requiresRecoveryEvidence { return .recoveryRequired(identity, receipt, reason, outcome) }
            if isCancelled { throw CancellationError() }
            return .rejected(receipt, reason)
        }
    }
}
