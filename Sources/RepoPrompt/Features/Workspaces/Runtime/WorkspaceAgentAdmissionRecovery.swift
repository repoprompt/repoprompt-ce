import Foundation
import RepoPromptDomainRuntime

/// Runs the canonical part of an existing provisional Agent admission rollback.
/// The caller owns its projection (if any) and retains exact working-write evidence
/// between attempts. No callback may replace the canonical revision or digest fence.
@MainActor
enum WorkspaceAgentAdmissionRecovery {
    struct ProjectionWrite {
        var register: (WorkspaceModel, UUID) -> () -> Void = { _, _ in {} }
        var didReadCanonical: (DomainWorkspaceSnapshot, UUID) -> Void = { _, _ in }
    }

    struct Hooks {
        #if DEBUG
            var allowWorkingSave: ((AgentAdmissionRecoveryWorkingCommit) async -> Bool)?
            var observeSaveResponse: ((DomainCommandOutcome) async -> Bool)?
            var allowReplacementPreparation: (() -> Bool)?
            var interceptReplacement: ((UInt64) async -> DomainCommandOutcome?)?
            var observeReplacementResponse: ((DomainCommandOutcome) async -> Bool)?
            var allowCanonicalRead: (() async -> Bool)?
        #endif
    }

    struct Projection<Removal> {
        let drainWrites: () async -> Void
        let remove: () -> Removal?
        let prepareWrite: (DomainWorkspaceSnapshot) -> ProjectionWrite
        let observeOutcome: (DomainCommandOutcome) -> Void
        let reconcile: (Removal?, DomainWorkspaceSnapshot) -> Void
        let resolveConflict: (Removal?, WorkspaceModel, DomainWorkspaceSnapshot) -> AgentAdmissionRecoveryOutcome
        var canContinue: @MainActor () -> Bool = { true }
    }

    static var independentProjection: Projection<Void> {
        .init(
            drainWrites: {}, remove: { () }, prepareWrite: { _ in .init() },
            observeOutcome: { _ in }, reconcile: { _, _ in },
            resolveConflict: { _, _, _ in .ownershipChanged }
        )
    }

    struct WorkingCommit {
        let read: () -> AgentAdmissionRecoveryWorkingCommit?
        let record: (AgentAdmissionRecoveryWorkingCommit) -> Void
        let forget: () -> Void
    }

    static func recover<Removal>(
        identity: AgentProvisionalAdmissionIdentity,
        mutation: WorkspaceAgentAdmissionDocument.RecoveryMutation,
        store: DomainWorkspaceStore,
        origin: DomainCommandOrigin,
        decode: (DomainWorkspaceDocument) throws -> WorkspaceModel,
        workingCommit: WorkingCommit,
        projection: Projection<Removal>,
        hooks: Hooks = .init()
    ) async -> AgentAdmissionRecoveryOutcome {
        await projection.drainWrites()
        var removal: Removal?
        for _ in 0 ..< 3 {
            guard projection.canContinue() else { return .ownershipChanged }
            guard let snapshot = await store.canonicalWorkspaceSnapshot(identity.workspaceID) else {
                if let owned = workingCommit.read() {
                    return .retryablePartial(owned)
                }
                return .failed(.durabilityUncertain)
            }
            guard projection.canContinue() else { return .ownershipChanged }
            guard snapshot.health.acceptsMutations else {
                return .failed(.authorityReadOnly)
            }
            guard let canonical = try? decode(snapshot.document) else {
                return .failed(.unrecoverableDocument)
            }
            let canonicalProjection = WorkspaceAgentAdmissionDocument.recoveryProjection(
                in: canonical,
                identity: identity,
                mutation: mutation,
                modificationDate: canonical.dateModified
            )
            if let owned = workingCommit.read() {
                let stillOwned = switch canonicalProjection {
                case .absent:
                    owned.revision == snapshot.revisions.workingRevision
                        && owned.digest == snapshot.document.contentDigest
                case .removed:
                    snapshot.revisions.workingRevision &+ 1 == owned.revision
                case .conflict:
                    false
                }
                guard stillOwned else {
                    workingCommit.forget()
                    if case .conflict = canonicalProjection {
                        return projection.resolveConflict(removal, canonical, snapshot)
                    }
                    return .ownershipChanged
                }
            }
            switch canonicalProjection {
            case .conflict:
                return projection.resolveConflict(removal, canonical, snapshot)
            case .absent:
                if removal == nil,
                   workingCommit.read() == nil
                {
                    guard let applied = projection.remove() else {
                        return .ownershipChanged
                    }
                    removal = applied
                    await projection.drainWrites()
                }
                if snapshot.revisions.dirtyRevision == nil {
                    projection.reconcile(removal, snapshot)
                    workingCommit.forget()
                    return .alreadyRecovered(
                        revision: snapshot.revisions.savedRevision,
                        digest: snapshot.document.contentDigest
                    )
                }
                guard let owned = workingCommit.read(),
                      owned.revision == snapshot.revisions.workingRevision,
                      owned.digest == snapshot.document.contentDigest
                else { return .ownershipChanged }
                #if DEBUG
                    if await hooks.allowWorkingSave?(owned) == false {
                        return .retryablePartial(owned)
                    }
                #endif
                guard projection.canContinue() else { return .ownershipChanged }
                let saveOutcome = await WorkspaceAgentAdmissionDocument.execute(
                    .saveWorkspaceDocument(workspaceID: identity.workspaceID),
                    store: store,
                    origin: origin,
                    expectedRevision: owned.revision
                )
                #if DEBUG
                    let responseArrived = await hooks.observeSaveResponse?(saveOutcome) ?? true
                #else
                    let responseArrived = true
                #endif
                if responseArrived {
                    projection.observeOutcome(saveOutcome)
                }
                guard let final = await store.canonicalWorkspaceSnapshot(identity.workspaceID)
                else { return .retryablePartial(owned) }
                if final.revisions.dirtyRevision == nil,
                   final.document.contentDigest == owned.digest
                {
                    projection.reconcile(removal, final)
                    workingCommit.forget()
                    return .recovered(
                        revision: final.revisions.savedRevision,
                        digest: final.document.contentDigest
                    )
                }
                if final.revisions.workingRevision == owned.revision,
                   final.document.contentDigest == owned.digest
                {
                    return .retryablePartial(owned)
                }
                continue
            case let .removed(recovered):
                let projectionWrite = projection.prepareWrite(snapshot)
                #if DEBUG
                    guard hooks.allowReplacementPreparation?() != false else {
                        return .failed(.persistenceFailure)
                    }
                #endif
                let replacementDocument: DomainWorkspaceDocument
                do {
                    replacementDocument = try WorkspaceAgentAdmissionDocument.encode(
                        recovered,
                        fileURL: snapshot.document.fileURL
                    )
                } catch {
                    return .failed(.persistenceFailure)
                }
                if removal == nil {
                    guard let applied = projection.remove() else {
                        return .ownershipChanged
                    }
                    removal = applied
                    await projection.drainWrites()
                }
                let anticipated = AgentAdmissionRecoveryWorkingCommit(
                    revision: snapshot.revisions.workingRevision &+ 1,
                    digest: replacementDocument.contentDigest
                )
                if let retained = workingCommit.read(),
                   retained != anticipated
                {
                    workingCommit.forget()
                    return .ownershipChanged
                }
                workingCommit.record(anticipated)
                let replacementOperationID = UUID()
                let cleanup = projectionWrite.register(recovered, replacementOperationID)
                defer { cleanup() }
                #if DEBUG
                    let injectedReplacementOutcome = await hooks.interceptReplacement?(snapshot.revisions.workingRevision)
                #else
                    let injectedReplacementOutcome: DomainCommandOutcome? = nil
                #endif
                guard projection.canContinue() else { return .ownershipChanged }
                let replacementOutcome = if let injectedReplacementOutcome {
                    injectedReplacementOutcome
                } else {
                    await WorkspaceAgentAdmissionDocument.execute(
                        .replaceWorkingDocument(replacementDocument),
                        store: store,
                        origin: origin,
                        expectedRevision: snapshot.revisions.workingRevision,
                        operationID: replacementOperationID
                    )
                }
                #if DEBUG
                    let replacementResponseArrived = await hooks.observeReplacementResponse?(replacementOutcome) ?? true
                #else
                    let replacementResponseArrived = true
                #endif
                if replacementResponseArrived {
                    projection.observeOutcome(replacementOutcome)
                }

                #if DEBUG
                    let shouldReadCanonical = await hooks.allowCanonicalRead?() ?? true
                #else
                    let shouldReadCanonical = true
                #endif
                guard shouldReadCanonical,
                      let working = await store.canonicalWorkspaceSnapshot(identity.workspaceID),
                      let workingModel = try? decode(working.document)
                else { return .retryablePartial(anticipated) }
                switch WorkspaceAgentAdmissionDocument.recoveryProjection(
                    in: workingModel,
                    identity: identity,
                    mutation: mutation,
                    modificationDate: workingModel.dateModified
                ) {
                case .conflict:
                    return projection.resolveConflict(removal, workingModel, working)
                case .removed:
                    guard working.revisions == snapshot.revisions,
                          working.document.contentDigest == snapshot.document.contentDigest
                    else { return .ownershipChanged }
                    return .retryablePartial(anticipated)
                case .absent:
                    guard working.document.contentDigest == anticipated.digest,
                          working.revisions.workingRevision == anticipated.revision
                    else { return .ownershipChanged }
                }

                projectionWrite.didReadCanonical(working, replacementOperationID)
                if working.revisions.dirtyRevision == nil {
                    projection.reconcile(removal, working)
                    workingCommit.forget()
                    return .recovered(
                        revision: working.revisions.savedRevision,
                        digest: working.document.contentDigest
                    )
                }
                let owned = anticipated
                #if DEBUG
                    if await hooks.allowWorkingSave?(owned) == false {
                        return .retryablePartial(owned)
                    }
                #endif

                guard projection.canContinue() else { return .ownershipChanged }
                let saveOutcome = await WorkspaceAgentAdmissionDocument.execute(
                    .saveWorkspaceDocument(workspaceID: identity.workspaceID),
                    store: store,
                    origin: origin,
                    expectedRevision: owned.revision
                )
                #if DEBUG
                    let responseArrived = await hooks.observeSaveResponse?(saveOutcome) ?? true
                #else
                    let responseArrived = true
                #endif
                if responseArrived {
                    projection.observeOutcome(saveOutcome)
                }
                guard let final = await store.canonicalWorkspaceSnapshot(identity.workspaceID)
                else { return .retryablePartial(owned) }
                if final.revisions.dirtyRevision == nil,
                   final.document.contentDigest == owned.digest
                {
                    projection.reconcile(removal, final)
                    workingCommit.forget()
                    return .recovered(
                        revision: final.revisions.savedRevision,
                        digest: final.document.contentDigest
                    )
                }
                if final.revisions.workingRevision == owned.revision,
                   final.document.contentDigest == owned.digest
                {
                    return .retryablePartial(owned)
                }
            }
        }
        return .failed(.authorityRevisionConflict)
    }
}
