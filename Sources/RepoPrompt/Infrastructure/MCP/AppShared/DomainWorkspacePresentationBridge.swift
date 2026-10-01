import Combine
import Foundation
import RepoPromptDomainRuntime

struct DomainWorkspaceSaveOperationIDs {
    let working: UUID
    let saved: UUID

    init(working: UUID = UUID(), saved: UUID = UUID()) {
        self.working = working
        self.saved = saved
    }
}

/// Both phases of an ordinary save. `working` is nil when the document already matched the
/// expected digest and only the save command ran; `final` is the last command executed.
struct DomainWorkspacePhasedSaveOutcome {
    let working: DomainCommandOutcome?
    let final: DomainCommandOutcome
}

struct DomainWorkspaceFailClosedSaveOutcome {
    let working: DomainCommandOutcome?
    let saved: DomainCommandOutcome?

    var finalOutcome: DomainCommandOutcome? {
        saved ?? working
    }

    var workingCommitted: Bool {
        working?.isSuccessfulDomainMutation == true
    }
}

private enum DomainWorkspaceModelEncoder {
    static func encode(_ workspace: WorkspaceModel) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(workspace)
    }
}

/// Revisioned app-process client for the runtime-owned workspace/context authority.
/// It is the only production persistence dependency injected into a workspace manager.
struct DomainWorkspaceAuthorityClient {
    let store: DomainWorkspaceStore
    let windowID: Int

    #if DEBUG
        /// Per-client suspension only: the real envelope and authority execution remain unchanged.
        var commandWillExecuteForTesting: (@Sendable (DomainWorkspaceCommandEnvelope) async -> Void)?
    #endif

    func snapshot() async -> DomainWorkspaceCatalogSnapshot {
        await store.snapshot()
    }

    func activationSnapshot(workspaceID: UUID, fileURL: URL) async -> DomainWorkspaceActivationSnapshot {
        await store.activationSnapshot(workspaceID: workspaceID, fileURL: fileURL)
    }

    func exactRootSelection(canonicalRootPath: String) async throws -> DomainExactRootSelection {
        try await store.exactRootSelection(canonicalRootPath: canonicalRootPath)
    }

    func workspaceSnapshot(_ workspaceID: UUID) async -> DomainWorkspaceSnapshot? {
        await store.workspaceSnapshot(workspaceID)
    }

    func canonicalWorkspaceSnapshot(_ workspaceID: UUID) async -> DomainWorkspaceSnapshot? {
        await store.canonicalWorkspaceSnapshot(workspaceID)
    }

    func agentAdmissionSnapshot(_ workspaceID: UUID) async -> DomainWorkspaceAdmissionSnapshot {
        await store.agentAdmissionSnapshot(workspaceID)
    }

    /// Awaited read-registration seam for current app state. Unlike create/replace/save, this is
    /// transient and therefore also supports ephemeral and focused-test workspaces.
    func registerForRead(
        _ workspace: WorkspaceModel,
        fileURL: URL
    ) async throws -> DomainWorkspaceSnapshot {
        try await store.registerReadDocument(document(for: workspace, fileURL: fileURL))
    }

    func create(
        _ workspace: WorkspaceModel,
        fileURL: URL,
        expectedCatalogRevision: UInt64? = nil,
        operationID: UUID = UUID()
    ) async throws -> DomainCommandOutcome {
        let document = try document(for: workspace, fileURL: fileURL)
        let envelope = DomainWorkspaceCommandEnvelope(
            operationID: operationID,
            expectedCatalogRevision: expectedCatalogRevision,
            expectedWorkspaceRevision: 0,
            origin: .appPresentation(windowID: windowID),
            command: .createWorkspace(document)
        )
        let first = await executeStable(envelope)
        guard expectedCatalogRevision == nil,
              first.disposition == .conflict,
              first.errorCode == .stateConflict,
              first.diagnostic == "durable_create_conflict"
              || first.diagnostic == "catalog_revision_mismatch",
              !Task.isCancelled
        else { return first }
        // The authority refreshes its durable catalog before returning a catalog-only conflict.
        // Retry the identical envelope once so the operation ID remains idempotent while work is bounded.
        return await executeStable(envelope)
    }

    func resolveOrCreatePersistentWorkspace(
        _ workspace: WorkspaceModel,
        fileURL: URL,
        canonicalRootPath: String,
        operationID: UUID = UUID()
    ) async throws -> DomainCommandOutcome {
        let document = try document(for: workspace, fileURL: fileURL)
        return await executeStable(.init(
            operationID: operationID,
            expectedWorkspaceRevision: 0,
            origin: .appPresentation(windowID: windowID),
            command: .resolveOrCreateWorkspaceForExactRoot(
                document: document,
                canonicalRootPath: canonicalRootPath
            )
        ))
    }

    func replaceWorking(
        _ workspace: WorkspaceModel,
        fileURL: URL,
        expectedWorkspaceRevision: UInt64?,
        operationID: UUID = UUID()
    ) async throws -> DomainCommandOutcome {
        let document = try document(for: workspace, fileURL: fileURL)
        return await executeStable(.init(
            operationID: operationID,
            expectedWorkspaceRevision: expectedWorkspaceRevision,
            origin: .appPresentation(windowID: windowID),
            command: .replaceWorkingDocument(document)
        ))
    }

    func save(
        _ workspace: WorkspaceModel,
        fileURL: URL,
        expectedWorkspaceRevision: UInt64?,
        expectedContentDigest: String?,
        operationIDs: DomainWorkspaceSaveOperationIDs = .init()
    ) async throws -> DomainCommandOutcome {
        try await savePhased(
            workspace,
            fileURL: fileURL,
            expectedWorkspaceRevision: expectedWorkspaceRevision,
            expectedContentDigest: expectedContentDigest,
            operationIDs: operationIDs
        ).final
    }

    /// Ordinary save that also reports the working-phase outcome, so the caller can record which
    /// canonical working revision its own bytes produced even when the save phase does not finish.
    func savePhased(
        _ workspace: WorkspaceModel,
        fileURL: URL,
        expectedWorkspaceRevision: UInt64?,
        expectedContentDigest: String?,
        operationIDs: DomainWorkspaceSaveOperationIDs = .init()
    ) async throws -> DomainWorkspacePhasedSaveOutcome {
        let document = try document(for: workspace, fileURL: fileURL)
        var saveRevision = expectedWorkspaceRevision
        var workingOutcome: DomainCommandOutcome?
        if document.contentDigest != expectedContentDigest {
            let working = await executeStable(.init(
                operationID: operationIDs.working,
                expectedWorkspaceRevision: expectedWorkspaceRevision,
                origin: .appPresentation(windowID: windowID),
                command: .replaceWorkingDocument(document)
            ))
            guard working.isSuccessfulDomainMutation else {
                return DomainWorkspacePhasedSaveOutcome(working: working, final: working)
            }
            workingOutcome = working
            saveRevision = working.after?.workingRevision
                ?? working.workspace?.revisions.workingRevision
        }
        let saved = await executeStable(.init(
            operationID: operationIDs.saved,
            expectedWorkspaceRevision: saveRevision,
            origin: .appPresentation(windowID: windowID),
            command: .saveWorkspaceDocument(workspaceID: workspace.id)
        ))
        return DomainWorkspacePhasedSaveOutcome(working: workingOutcome, final: saved)
    }

    /// Persists the authority's current working document without submitting new bytes, and only
    /// while it is still exactly `expectedWorkspaceRevision`. Fail-closed: any interleaved writer
    /// turns this into a conflict instead of a CAS replay, so it can never overwrite a newer
    /// revision. Used to finish an interrupted save of bytes this presentation already committed.
    func saveCommittedWorkingRevision(
        workspaceID: UUID,
        expectedWorkspaceRevision: UInt64,
        operationID: UUID = UUID()
    ) async -> DomainCommandOutcome {
        await executeStable(.init(
            operationID: operationID,
            expectedWorkspaceRevision: expectedWorkspaceRevision,
            conflictRecoveryPolicy: .failClosed,
            origin: .appPresentation(windowID: windowID),
            command: .saveWorkspaceDocument(workspaceID: workspaceID)
        ))
    }

    /// Saves one exact captured document without replaying or rebasing it after any durable or
    /// external conflict. Used by operations whose preflight authority must remain their authority.
    func saveFailClosed(
        _ workspace: WorkspaceModel,
        fileURL: URL,
        expectedWorkspaceRevision: UInt64,
        expectedContentDigest: String,
        operationIDs: DomainWorkspaceSaveOperationIDs = .init()
    ) async throws -> DomainWorkspaceFailClosedSaveOutcome {
        let document = try document(for: workspace, fileURL: fileURL)
        var saveRevision = expectedWorkspaceRevision
        var workingOutcome: DomainCommandOutcome?
        if document.contentDigest != expectedContentDigest {
            let working = await executeStable(.init(
                operationID: operationIDs.working,
                expectedWorkspaceRevision: expectedWorkspaceRevision,
                conflictRecoveryPolicy: .failClosed,
                origin: .appPresentation(windowID: windowID),
                command: .replaceWorkingDocument(document)
            ))
            workingOutcome = working
            guard working.isSuccessfulDomainMutation else {
                return DomainWorkspaceFailClosedSaveOutcome(
                    working: working,
                    saved: nil
                )
            }
            saveRevision = working.after?.workingRevision
                ?? working.workspace?.revisions.workingRevision
                ?? saveRevision
        }
        let saved = await executeStable(.init(
            operationID: operationIDs.saved,
            expectedWorkspaceRevision: saveRevision,
            conflictRecoveryPolicy: .failClosed,
            origin: .appPresentation(windowID: windowID),
            command: .saveWorkspaceDocument(workspaceID: workspace.id)
        ))
        return DomainWorkspaceFailClosedSaveOutcome(
            working: workingOutcome,
            saved: saved
        )
    }

    func delete(
        workspaceID: UUID,
        expectedCatalogRevision: UInt64?,
        expectedWorkspaceRevision: UInt64?,
        operationID: UUID = UUID()
    ) async -> DomainCommandOutcome {
        await executeStable(.init(
            operationID: operationID,
            expectedCatalogRevision: expectedCatalogRevision,
            expectedWorkspaceRevision: expectedWorkspaceRevision,
            origin: .appPresentation(windowID: windowID),
            command: .deleteWorkspace(workspaceID: workspaceID)
        ))
    }

    func reloadExternalChanges() async -> DomainWorkspaceCatalogSnapshot {
        await store.reloadExternalChanges()
        return await store.snapshot()
    }

    private func document(for workspace: WorkspaceModel, fileURL: URL) throws -> DomainWorkspaceDocument {
        let bytes = try DomainWorkspaceModelEncoder.encode(workspace)
        return try DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL)
    }

    /// Retries only the exact same envelope. A changed CAS expectation or payload is a new
    /// logical operation and must receive a new operation ID from the caller.
    private func executeStable(
        _ envelope: DomainWorkspaceCommandEnvelope
    ) async -> DomainCommandOutcome {
        #if DEBUG
            await commandWillExecuteForTesting?(envelope)
        #endif
        let first = await store.execute(envelope)
        guard first.disposition == .failed,
              first.errorCode == .lockTimedOut || first.errorCode == .cancelled
        else { return first }
        guard !Task.isCancelled else { return first }
        await Task.yield()
        return await store.execute(envelope)
    }
}

private extension DomainCommandOutcome {
    var isSuccessfulDomainMutation: Bool {
        disposition == .applied || disposition == .unchanged || disposition == .deduplicated
    }
}

/// MainActor-only projection of immutable runtime snapshots into the existing app view model graph.
/// Active-window choice is deliberately resolved here; it is never persisted as domain routing truth.
@MainActor
final class DomainWorkspacePresentationBridge {
    private weak var workspaceManager: WorkspaceManagerViewModel?
    private let client: DomainWorkspaceAuthorityClient
    private var subscriptionTask: Task<Void, Never>?
    /// Subscription incarnation created by `start()` and invalidated by `stop()`. An authority read
    /// that returns after stop must neither apply a stale snapshot nor credit a newer run.
    private var subscriptionRunID: UUID?
    private var lastPublicationSequence: UInt64 = 0
    private var projectedDigests: [UUID: String] = [:]
    private var projectedHealth: [UUID: DomainAuthorityHealth] = [:]
    private var projectedModels: [UUID: WorkspaceModel] = [:]

    init(workspaceManager: WorkspaceManagerViewModel, client: DomainWorkspaceAuthorityClient) {
        self.workspaceManager = workspaceManager
        self.client = client
    }

    deinit {
        subscriptionTask?.cancel()
    }

    func stop() {
        #if DEBUG
            let stoppedRunID = subscriptionRunID
        #endif
        subscriptionRunID = nil
        subscriptionTask?.cancel()
        #if DEBUG
            // Cancellation alone is not a join; keep stopped incarnations joinable.
            if let subscriptionTask {
                retiredSubscriptionTasks.append(subscriptionTask)
            }
        #endif
        subscriptionTask = nil
        projectedDigests.removeAll(keepingCapacity: false)
        projectedHealth.removeAll(keepingCapacity: false)
        projectedModels.removeAll(keepingCapacity: false)
        #if DEBUG
            projectionCheckpoint = nil
            if let stoppedRunID {
                projectionObservationSubject.send(.stopped(runID: stoppedRunID))
            }
        #endif
    }

    private func isCurrentRun(_ runID: UUID) -> Bool {
        subscriptionRunID == runID && !Task.isCancelled
    }

    #if DEBUG
        /// A completed manager application by one subscription incarnation.
        struct ProjectionCheckpoint: Equatable {
            let runID: UUID
            /// Monotonic across stop/start; zero means no application has completed.
            let generation: UInt64
            let publicationSequence: UInt64
        }

        struct ProjectionObservationState: Equatable {
            let runID: UUID?
            let generation: UInt64
            let checkpoint: ProjectionCheckpoint?
        }

        enum ProjectionObservationEvent: Equatable {
            case applied(ProjectionCheckpoint)
            case stopped(runID: UUID)
        }

        private var projectionCheckpoint: ProjectionCheckpoint?
        private var projectionGeneration: UInt64 = 0
        private let projectionObservationSubject = PassthroughSubject<ProjectionObservationEvent, Never>()
        private var retiredSubscriptionTasks: [Task<Void, Never>] = []

        /// Cancellation alone does not join a suspended projection into a fixture-owned manager.
        /// Joins the current and every previously stopped subscription incarnation.
        func stopAndJoinForTesting() async {
            stop()
            let retired = retiredSubscriptionTasks
            retiredSubscriptionTasks.removeAll()
            for task in retired {
                await task.value
            }
        }

        var hasActiveSubscriptionForTesting: Bool {
            subscriptionTask != nil
        }

        var projectionObservationStateForTesting: ProjectionObservationState {
            ProjectionObservationState(
                runID: subscriptionRunID,
                generation: projectionGeneration,
                checkpoint: projectionCheckpoint
            )
        }

        var projectionObservationPublisherForTesting: AnyPublisher<ProjectionObservationEvent, Never> {
            projectionObservationSubject.eraseToAnyPublisher()
        }

        func suppressSelfEchoForTesting(_ event: DomainWorkspaceEvent) async -> Bool {
            await suppressSelfEcho(for: event, runID: nil)
        }
    #endif

    /// Records a completed manager application for the still-current incarnation (DEBUG only).
    private func didApplyProjection(runID: UUID?, publicationSequence: UInt64) {
        #if DEBUG
            guard let runID, subscriptionRunID == runID, workspaceManager != nil else { return }
            projectionGeneration += 1
            let checkpoint = ProjectionCheckpoint(
                runID: runID,
                generation: projectionGeneration,
                publicationSequence: publicationSequence
            )
            projectionCheckpoint = checkpoint
            projectionObservationSubject.send(.applied(checkpoint))
        #endif
    }

    func start() {
        guard subscriptionTask == nil else { return }
        let runID = UUID()
        subscriptionRunID = runID
        subscriptionTask = Task { [weak self, client] in
            let subscription = await client.store.subscribe()
            guard subscription.snapshot.isBootstrapped else { return }
            if let self, isCurrentRun(runID) {
                await projectInitial(subscription.snapshot, runID: runID)
            }
            for await event in subscription.events {
                guard !Task.isCancelled, let self, isCurrentRun(runID) else { return }
                await self.consume(event, runID: runID)
            }
        }
    }

    private func projectInitial(_ snapshot: DomainWorkspaceCatalogSnapshot, runID: UUID) async {
        var initial = snapshot
        if initial.workspaces.isEmpty,
           let candidate = workspaceManager?.runtimeOwnedDefaultWorkspaceCandidate()
        {
            let fileURL = workspaceManager?.workspaceFileURL(for: candidate)
            if let fileURL {
                do {
                    let outcome = try await client.create(candidate, fileURL: fileURL)
                    if !outcome.isSuccessfulDomainMutation {
                        workspaceManager?.reportDomainAuthorityIssue(outcome, operation: "create_default")
                    }
                } catch {
                    workspaceManager?.reportDomainAuthorityFailure(
                        error,
                        workspaceID: candidate.id,
                        operation: "create_default"
                    )
                }
                initial = await client.snapshot()
            }
        }
        guard isCurrentRun(runID) else { return }
        project(initial, force: true, runID: runID)
    }

    private func consume(_ event: DomainWorkspaceEvent, runID: UUID) async {
        guard event.sequence > lastPublicationSequence else { return }
        let gap = lastPublicationSequence != 0 && event.sequence != lastPublicationSequence &+ 1
        if !gap, await suppressSelfEcho(for: event, runID: runID) { return }
        let snapshot = await client.snapshot()
        guard isCurrentRun(runID) else { return }
        project(
            snapshot,
            force: gap || event.kind == .externalReloaded,
            runID: runID
        )
    }

    /// The originating window already applied its command outcome (revisions + digest) via
    /// `applyDomainAuthorityOutcome`, so echoing its own commit back through a full catalog
    /// snapshot plus a MainActor document decode would only amplify every capture by W windows.
    /// Bookkeeping is refreshed from a single-workspace snapshot instead.
    private func suppressSelfEcho(for event: DomainWorkspaceEvent, runID: UUID?) async -> Bool {
        let suppressibleKinds: Set<DomainWorkspaceEventKind> = [
            .workingStateCommitted, .savedDocumentCommitted, .operationDeduplicated
        ]
        guard case let .appPresentation(originWindowID) = event.origin,
              originWindowID == client.windowID,
              suppressibleKinds.contains(event.kind),
              let workspaceID = event.workspaceID,
              projectedModels[workspaceID] != nil
        else { return false }
        guard let workspace = await client.canonicalWorkspaceSnapshot(workspaceID),
              workspace.health.acceptsMutations,
              let model = workspaceManager?.workspace(withID: workspaceID)
        else { return false }
        if let runID, !isCurrentRun(runID) { return false }
        // A same-window commit can be accepted just before a newer local edit is captured. Keep the
        // local model in both the manager and bridge cache: advancing the baseline below lets the
        // newer edit commit from the accepted revision, and explicit failed-save reconciliation
        // remains responsible for authoritative replacement when a two-phase cleanup save does not
        // complete. The outcome does not depend on re-encoding the model to compare digests.
        projectedModels[workspaceID] = model
        projectedDigests[workspaceID] = workspace.document.contentDigest
        projectedHealth[workspaceID] = workspace.health
        workspaceManager?.applyDomainAuthorityBaseline(
            workspaceID: workspaceID,
            revisions: workspace.revisions,
            digest: workspace.document.contentDigest,
            health: workspace.health,
            catalogRevision: event.catalogRevision
        )
        lastPublicationSequence = event.sequence
        didApplyProjection(runID: runID, publicationSequence: event.sequence)
        return true
    }

    private func project(_ snapshot: DomainWorkspaceCatalogSnapshot, force: Bool, runID: UUID) {
        guard snapshot.isBootstrapped,
              snapshot.publicationSequence >= lastPublicationSequence
        else { return }
        let nextDigests = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
            ($0.document.workspaceID, $0.document.contentDigest)
        })
        let nextHealth = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
            ($0.document.workspaceID, $0.health)
        })
        let revisions = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
            ($0.document.workspaceID, $0.revisions)
        })
        let changedIDs = Set(snapshot.workspaces.compactMap { workspace -> UUID? in
            projectedDigests[workspace.document.workspaceID] == workspace.document.contentDigest
                ? nil
                : workspace.document.workspaceID
        })
        let removedIDs = Set(projectedModels.keys).subtracting(nextDigests.keys)
        let requiresModelProjection = !changedIDs.isEmpty
            || !removedIDs.isEmpty
            || (force && projectedModels.isEmpty && !snapshot.workspaces.isEmpty)
        guard requiresModelProjection else {
            projectedDigests = nextDigests
            projectedHealth = nextHealth
            lastPublicationSequence = snapshot.publicationSequence
            workspaceManager?.applyDomainAuthorityMetadataProjection(
                revisionsByWorkspaceID: revisions,
                digestsByWorkspaceID: nextDigests,
                healthByWorkspaceID: nextHealth,
                catalogRevision: snapshot.catalogRevision,
                publicationSequence: snapshot.publicationSequence,
                canonicalSystemWorkspaceIDs: Set(snapshot.workspaces.compactMap { workspace in
                    workspace.document.metadata.isSystemWorkspace && !workspace.document.metadata.isEphemeral
                        ? workspace.document.workspaceID
                        : nil
                })
            )
            didApplyProjection(runID: runID, publicationSequence: snapshot.publicationSequence)
            return
        }

        var nextModels = projectedModels
        for workspaceID in removedIDs {
            nextModels.removeValue(forKey: workspaceID)
        }
        do {
            for workspace in snapshot.workspaces where changedIDs.contains(workspace.document.workspaceID) {
                nextModels[workspace.document.workspaceID] = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: workspace.document.documentBytes,
                    fileURL: workspace.document.fileURL
                )
            }
        } catch {
            workspaceManager?.reportDomainProjectionFailure(error)
            return
        }

        let decoded = snapshot.workspaces.compactMap {
            nextModels[$0.document.workspaceID]
        }
        guard decoded.count == snapshot.workspaces.count else {
            workspaceManager?.reportDomainProjectionFailure(DomainProjectionError.incompleteSnapshot)
            return
        }
        projectedModels = nextModels
        projectedDigests = nextDigests
        projectedHealth = nextHealth
        lastPublicationSequence = snapshot.publicationSequence
        workspaceManager?.applyDomainWorkspaceProjection(
            decoded,
            canonicalRepoPathsByWorkspaceID: Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
                ($0.document.workspaceID, $0.document.metadata.repoPaths)
            }),
            fileURLsByWorkspaceID: Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
                ($0.document.workspaceID, $0.document.fileURL)
            }),
            revisionsByWorkspaceID: revisions,
            digestsByWorkspaceID: nextDigests,
            healthByWorkspaceID: nextHealth,
            catalogRevision: snapshot.catalogRevision,
            preferredActiveWorkspaceID: workspaceManager?.activeWorkspaceID,
            publicationSequence: snapshot.publicationSequence
        )
        didApplyProjection(runID: runID, publicationSequence: snapshot.publicationSequence)
    }
}

private enum DomainProjectionError: LocalizedError {
    case incompleteSnapshot

    var errorDescription: String? {
        "Runtime workspace projection was incomplete; the previous complete snapshot was retained."
    }
}
