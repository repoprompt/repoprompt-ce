import Foundation
import RepoPromptDomainRuntime

/// Canonical persistence adapter for the same provisional background-tab transaction used
/// by the presenter. It has no projection to flush, select, or restore. The caller supplies
/// a blocked writer and keeps it until first configured persistence or exact compensation.
@MainActor
final class WorkspaceAgentCanonicalFreshAdmission {
    @MainActor
    struct Adapters {
        let makeTab: (WorkspaceModel) -> ComposeTabState?
        let prepareWriter: (ComposeTabState) -> Bool
        let ownsWriter: () -> Bool
        let validateSource: () async -> Bool
        let sourceIsCurrent: () -> Bool
    }

    private let authority: DomainWorkspaceAuthorityClient
    private let origin: DomainCommandOrigin
    private let coordinator: WorkspaceAgentAdmissionCoordinator
    private let lifecycleAuthority = AgentSessionLifecycleAuthority()
    private var claim: AgentProvisionalAdmissionClaim?
    private var workingRecoveryCommit: AgentAdmissionRecoveryWorkingCommit?

    init(
        authority: DomainWorkspaceAuthorityClient,
        connectionID: UUID,
        coordinator: WorkspaceAgentAdmissionCoordinator = .shared
    ) {
        self.authority = authority
        origin = .appMCP(connectionID: connectionID)
        self.coordinator = coordinator
    }

    func publish(
        workspaceID: UUID, sessionID: UUID, adapters: Adapters
    ) async throws -> WorkspaceAgentFreshAdmission.Result {
        let timing = WorkspaceAgentAdmissionTiming()
        return try await coordinator.withAdmission(
            workspaceID: workspaceID, admissionID: UUID(), kind: .freshTab,
            classifyOutcome: { (result: WorkspaceAgentFreshAdmission.Result) in
                if case .created = result { return .committed }
                return .rejected
            }, classifyError: { _ in .threw }, timing: timing
        ) {
            guard await adapters.validateSource(), claim == nil,
                  let baseline = await authority.canonicalWorkspaceSnapshot(workspaceID),
                  baseline.health.acceptsMutations, baseline.revisions.dirtyRevision == nil,
                  let workspace = try? Self.decode(baseline.document), workspace.id == workspaceID, !workspace.isEphemeral,
                  !Task.isCancelled, adapters.sourceIsCurrent()
            else { return WorkspaceAgentFreshAdmission.rejected("workspace_changed", reason: .workspaceChanged) }
            let preparation = WorkspaceAgentFreshAdmission.prepare(
                workspace: workspace, sessionID: sessionID, makeTab: { adapters.makeTab(workspace) }
            )
            switch preparation {
            case let .rejected(result): return result
            case let .ready(tab, claim):
                return try await publishPrepared(
                    tab: tab, claim: claim, workspace: workspace, baseline: baseline, adapters: adapters, timing: timing
                )
            }
        }
    }

    /// Only the caller that acknowledged the complete initial session payload may accept.
    @discardableResult
    func acceptConfiguredCreation(_ expected: AgentProvisionalAdmissionClaim) -> Bool {
        guard claim === expected, expected.markAccepted() else { return false }
        releaseReservation(expected.identity)
        return true
    }

    /// Compensation may outlive requester cancellation, but may never acquire a new writer.
    func discard(_ expected: AgentProvisionalAdmissionClaim, ownsWriter: @escaping @MainActor () -> Bool) async -> AgentAdmissionRecoveryOutcome {
        guard claim === expected, expected.state == .provisional else { return .ownershipChanged }
        guard ownsWriter() else {
            expected.markComplete()
            releaseReservation(expected.identity)
            return .ownershipChanged
        }
        guard expected.beginWorkspaceRecovery() else { return .ownershipChanged }
        return await Task { @MainActor in
            do {
                let outcome = try await self.withRecoveryLease(expected.identity) {
                    await self.settleRecovery(expected, ownsWriter: ownsWriter)
                }
                switch outcome {
                case .recovered, .alreadyRecovered, .localOnly:
                    expected.markWorkspaceRecovered()
                    expected.markComplete()
                case .ownershipChanged:
                    expected.markComplete()
                default: break
                }
                self.releaseReservationUnlessRetained(expected.identity)
                return outcome
            } catch {
                let outcome = await self.settleRecovery(expected, ownsWriter: ownsWriter, initialOutcome: .failed(.durabilityUncertain))
                self.releaseReservationUnlessRetained(expected.identity)
                return outcome
            }
        }.value
    }

    private func publishPrepared(
        tab: ComposeTabState, claim: AgentProvisionalAdmissionClaim, workspace: WorkspaceModel,
        baseline: DomainWorkspaceSnapshot, adapters: Adapters, timing: WorkspaceAgentAdmissionTiming
    ) async throws -> WorkspaceAgentFreshAdmission.Result {
        let identity = claim.identity
        var proposed = workspace
        proposed.composeTabs.append(tab)
        proposed.dateModified = tab.lastModified
        let document = try await WorkspaceFileDecodeCache.shared.documentPreparation.document(for: proposed, fileURL: baseline.document.fileURL)
        guard await adapters.validateSource(), !Task.isCancelled, adapters.sourceIsCurrent(), self.claim == nil,
              coordinator.reserveProvisionalSession(workspaceID: identity.workspaceID, sessionID: identity.sessionID, ownerID: identity.recoveryID)
        else { return WorkspaceAgentFreshAdmission.rejected("creation_preparation_changed", reason: .sessionIdentityChanged) }
        self.claim = claim
        var committed = false
        defer { if !committed { releaseReservationUnlessRetained(identity) } }
        guard adapters.prepareWriter(tab), adapters.ownsWriter(), adapters.sourceIsCurrent() else {
            claim.markComplete()
            return WorkspaceAgentFreshAdmission.rejected("creation_preparation_changed", reason: .sessionIdentityChanged)
        }
        timing.begin(.save)
        timing.recordSaveAttempt()
        let write = try? await authority.saveFailClosed(
            document, expectedWorkspaceRevision: baseline.revisions.workingRevision,
            expectedContentDigest: baseline.document.contentDigest, origin: origin
        )
        timing.end()
        let sourceUnchanged = await adapters.validateSource()
        let after = await authority.canonicalWorkspaceSnapshot(identity.workspaceID)
        let isCancelled = Task.isCancelled
        let containsCarrier = after.flatMap { try? Self.decode($0.document) }.map {
            WorkspaceAgentAdmissionDocument.recoveryProjection(in: $0, identity: identity).containsIdentity
        } == true
        let receipt = Self.receipt(write: write, snapshot: containsCarrier ? after : nil, proposed: document)
        let result = try await WorkspaceAgentFreshAdmission.settle(
            tab: tab, claim: claim, receipt: receipt,
            bindingStillCurrent: sourceUnchanged && adapters.sourceIsCurrent() && adapters.ownsWriter() && containsCarrier,
            isCancelled: isCancelled, lifecycleAuthority: lifecycleAuthority, rollbackProjection: {}, recover: {
                // Cancellation of the publication waiter does not cancel compensation.
                await Task { @MainActor in await self.settleRecovery(claim, ownsWriter: adapters.ownsWriter) }.value
            }
        )
        if case .created = result { committed = true }
        return result
    }

    private static func receipt(
        write: DomainWorkspaceFailClosedSaveOutcome?, snapshot: DomainWorkspaceSnapshot?,
        proposed: DomainWorkspaceDocument
    ) -> AgentAdmissionPersistenceReceipt {
        func acceptedRevision(_ result: DomainCommandOutcome?) -> DomainRevisionState? {
            guard let result, result.errorCode == nil, [.applied, .unchanged, .deduplicated].contains(result.disposition),
                  (result.resultingDigest ?? result.workspace?.document.contentDigest) == proposed.contentDigest
            else { return nil }
            return result.after ?? result.workspace?.revisions
        }
        let saved = acceptedRevision(write?.saved).flatMap { $0.dirtyRevision == nil ? $0 : nil }
        let evidence: AgentAdmissionPersistenceCommitEvidence = if let snapshot {
            if snapshot.revisions.dirtyRevision == nil {
                .saved(revision: snapshot.revisions.savedRevision, digest: snapshot.document.contentDigest)
            } else {
                .canonicalWorking(revision: snapshot.revisions.workingRevision, digest: snapshot.document.contentDigest)
            }
        } else if let saved {
            // A missing or superseded read does not erase an accepted command. The caller
            // must still prove the current carrier before this receipt can authorize launch.
            .saved(revision: saved.savedRevision, digest: proposed.contentDigest)
        } else if let working = acceptedRevision(write?.working) {
            .canonicalWorking(revision: working.workingRevision, digest: proposed.contentDigest)
        } else { .none }
        let outcome: WorkspacePersistenceOutcome
        if let saved {
            outcome = .persisted(workspaceID: proposed.workspaceID, stateVersion: Int(clamping: saved.savedRevision))
        } else {
            let final = write?.finalOutcome
            let category = WorkspacePersistenceFailureCategory.classify(domainErrorCode: final?.errorCode)
            outcome = .rejected(
                reason: category.rawValue,
                category: category,
                domainDiagnostic: final?.diagnostic,
                domainErrorCode: final?.errorCode,
                workingCommitted: write?.workingCommitted == true
            )
        }
        return .init(outcome: outcome, commitEvidence: evidence)
    }

    private func settleRecovery(
        _ claim: AgentProvisionalAdmissionClaim, ownsWriter: @escaping @MainActor () -> Bool,
        initialOutcome: AgentAdmissionRecoveryOutcome? = nil
    ) async -> AgentAdmissionRecoveryOutcome {
        let identity = claim.identity
        return await WorkspaceAgentAdmissionRecoveryRetention.settle(claim: claim, adapters: .init(
            attempt: {
                if let initialOutcome { return initialOutcome }
                return await self.recover(identity, ownsWriter: ownsWriter)
            },
            retryUnderLease: {
                try await self.withRecoveryLease(identity) { await self.recover(identity, ownsWriter: ownsWriter) }
            }, retain: { start, operation in
                self.coordinator.retainRecovery(
                    recoveryID: identity.recoveryID, workspaceID: identity.workspaceID, sessionID: identity.sessionID,
                    reservationOwnerID: identity.recoveryID, start: start, operation: operation
                )
            }
        ))
    }

    private func withRecoveryLease(
        _ identity: AgentProvisionalAdmissionIdentity, operation: () async -> AgentAdmissionRecoveryOutcome
    ) async throws -> AgentAdmissionRecoveryOutcome {
        try await coordinator.withAdmission(
            workspaceID: identity.workspaceID, admissionID: UUID(), kind: .recovery,
            classifyOutcome: { (result: AgentAdmissionRecoveryOutcome) in
                switch result {
                case .recovered, .alreadyRecovered, .localOnly: .committed
                default: .rejected
                }
            }, classifyError: { _ in .threw }, timing: WorkspaceAgentAdmissionTiming(),
            operation: operation
        )
    }

    private func recover(
        _ identity: AgentProvisionalAdmissionIdentity, ownsWriter: @escaping @MainActor () -> Bool
    ) async -> AgentAdmissionRecoveryOutcome {
        guard ownsWriter() else { return .ownershipChanged }
        return await WorkspaceAgentAdmissionRecovery.recover(
            identity: identity, mutation: .removeTab, store: authority.store, origin: origin, decode: Self.decode,
            workingCommit: .init(
                read: { self.workingRecoveryCommit },
                record: { self.workingRecoveryCommit = $0 },
                forget: { self.workingRecoveryCommit = nil }
            ),
            projection: .init(
                drainWrites: {}, remove: { ownsWriter() ? () : nil }, prepareWrite: { _ in .init() },
                observeOutcome: { _ in }, reconcile: { _, _ in }, resolveConflict: { _, _, _ in .ownershipChanged },
                canContinue: ownsWriter
            )
        )
    }

    private func releaseReservationUnlessRetained(_ identity: AgentProvisionalAdmissionIdentity) {
        if coordinator.retainedRecoveryState(recoveryID: identity.recoveryID) == nil { releaseReservation(identity) }
    }

    private func releaseReservation(_ identity: AgentProvisionalAdmissionIdentity) {
        coordinator.releaseProvisionalSession(workspaceID: identity.workspaceID, sessionID: identity.sessionID, ownerID: identity.recoveryID)
    }

    private static func decode(_ document: DomainWorkspaceDocument) throws -> WorkspaceModel {
        let workspace = try WorkspaceFileDecodeCache.decodeWorkspace(documentBytes: document.documentBytes).workspace
        guard !workspace.composeTabsDecodeWasLossy else { throw WorkspaceAgentCanonicalAdmissionFailure.lossyWorkspace }
        return workspace
    }
}

private enum WorkspaceAgentCanonicalAdmissionFailure: Error { case lossyWorkspace }
