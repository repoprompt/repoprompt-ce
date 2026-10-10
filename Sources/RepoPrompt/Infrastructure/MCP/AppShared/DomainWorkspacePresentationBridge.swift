#if DEBUG
    import Combine
#endif
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
    private var projectedModels: [UUID: WorkspaceModel] = [:]
    /// Manager reconciliation generation the caches above were committed against; nil until this
    /// run's first accepted full reconciliation. A mismatch (manager-owned reload or cleanup) forces
    /// a complete decode/reconcile before the caches are trusted again.
    private var acceptedReconciliationGeneration: UInt64?
    /// The sole explicit catalog refresh (Retry or import fence); its ID coalesces repeated requests.
    private var catalogRefreshTask: Task<Void, Never>?
    private var catalogRefreshID: UUID?

    init(workspaceManager: WorkspaceManagerViewModel, client: DomainWorkspaceAuthorityClient) {
        self.workspaceManager = workspaceManager
        self.client = client
    }

    deinit {
        subscriptionTask?.cancel()
        catalogRefreshTask?.cancel()
    }

    func stop() {
        #if DEBUG
            let stoppedRunID = subscriptionRunID
        #endif
        subscriptionRunID = nil
        cancelCatalogRefresh()
        subscriptionTask?.cancel()
        #if DEBUG
            // Cancellation alone is not a join; keep stopped incarnations joinable.
            if let subscriptionTask {
                retiredSubscriptionTasks.append(subscriptionTask)
            }
        #endif
        subscriptionTask = nil
        acceptedReconciliationGeneration = nil
        projectedDigests.removeAll(keepingCapacity: false)
        projectedModels.removeAll(keepingCapacity: false)
        #if DEBUG
            projectionCheckpoint = nil
            catalogProjectionCheckpoint = nil
            if let stoppedRunID {
                projectionObservationSubject.send(.stopped(runID: stoppedRunID))
            }
        #endif
    }

    private func isCurrentRun(_ runID: UUID) -> Bool {
        subscriptionRunID == runID && !Task.isCancelled
            && workspaceManager?.isPreparingForWindowClose == false
    }

    /// Explicit Retry (or import-fence refresh): one owned task runs the authority's existing
    /// `reloadExternalChanges()` recovery, then the normal projection with its own one-refetch budget.
    /// Requests while it runs coalesce onto its ID. No polling, delay or automatic retry.
    func requestCatalogRefresh(isRetry: Bool) {
        guard let runID = subscriptionRunID, let manager = workspaceManager,
              !manager.isPreparingForWindowClose
        else { return }
        if let activeID = catalogRefreshID {
            if isRetry { manager.beginWorkspaceChooserRetry(activeID) }
            return
        }
        let refreshID = UUID()
        if isRetry, !manager.beginWorkspaceChooserRetry(refreshID) { return }
        let attempt = manager.beginDomainCatalogAttempt()
        catalogRefreshID = refreshID
        #if DEBUG
            let afterCatalogReload = afterCatalogReloadForTesting
        #endif
        catalogRefreshTask = Task { [weak self, client] in
            let snapshot = await client.reloadExternalChanges()
            #if DEBUG
                await afterCatalogReload?()
            #endif
            guard let self else { return }
            if isCurrentRun(runID) {
                await projectResolvingStaleness(snapshot, attempt: attempt, runID: runID)
            }
            if catalogRefreshID == refreshID {
                catalogRefreshID = nil
                catalogRefreshTask = nil
            }
            workspaceManager?.finishWorkspaceChooserRetry(refreshID)
        }
    }

    /// Close/stop cancellation: never publishes an error. A task already inside runtime I/O may finish
    /// there; its result is discarded by the run/cancellation checks.
    func cancelCatalogRefresh() {
        catalogRefreshTask?.cancel()
        #if DEBUG
            if let catalogRefreshTask { retiredSubscriptionTasks.append(catalogRefreshTask) }
        #endif
        catalogRefreshTask = nil
        if let catalogRefreshID {
            workspaceManager?.finishWorkspaceChooserRetry(catalogRefreshID)
        }
        catalogRefreshID = nil
    }

    /// What an accepted manager operation established (recorded by DEBUG checkpoints).
    enum ProjectionApplication: Equatable {
        /// Accepted catalog reconciliation; the receipt carries kind and completeness.
        case catalog(DomainCatalogApplicationReceipt)
        /// One-record baseline refresh; never a catalog certification.
        case selfEchoBaseline
    }

    #if DEBUG
        /// Captured by each refresh before scheduling; never substitutes the authority result.
        var afterCatalogReloadForTesting: (@MainActor () async -> Void)?

        private var initialDefaultCreateOverride: (outcome: DomainCommandOutcome, observeCandidate: (WorkspaceModel) -> Void)?

        /// Only unsuccessful initial Default outcomes may bypass the command; never simulates a mutation.
        @discardableResult
        func setInitialDefaultCreateOutcomeForTesting(
            _ outcome: DomainCommandOutcome?,
            observeCandidate: @escaping (WorkspaceModel) -> Void = { _ in }
        ) -> Bool {
            guard let outcome else {
                initialDefaultCreateOverride = nil
                return true
            }
            guard !outcome.isSuccessfulDomainMutation else { return false }
            initialDefaultCreateOverride = (outcome, observeCandidate)
            return true
        }

        /// A completed manager application by one subscription incarnation.
        struct ProjectionCheckpoint: Equatable {
            typealias Application = ProjectionApplication

            let runID: UUID
            /// Monotonic across stop/start; zero means no application has completed.
            let generation: UInt64
            let publicationSequence: UInt64
            let application: Application

            var catalogReceipt: DomainCatalogApplicationReceipt? {
                if case let .catalog(receipt) = application { receipt } else { nil }
            }
        }

        struct ProjectionObservationState: Equatable {
            let runID: UUID?
            let generation: UInt64
            let checkpoint: ProjectionCheckpoint?
            /// Latest accepted catalog application in this run; a later self-echo does not hide it.
            let catalogCheckpoint: ProjectionCheckpoint?
        }

        enum ProjectionObservationEvent: Equatable {
            case applied(ProjectionCheckpoint)
            /// A resolved attempt the manager did not accept; caches and checkpoints did not advance.
            case rejected(runID: UUID, publicationSequence: UInt64, reason: DomainCatalogRejection)
            case stopped(runID: UUID)
        }

        private var projectionCheckpoint: ProjectionCheckpoint?
        private var catalogProjectionCheckpoint: ProjectionCheckpoint?
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

        func awaitCatalogRefreshForTesting() async {
            await catalogRefreshTask?.value
        }

        var hasActiveSubscriptionForTesting: Bool {
            subscriptionTask != nil
        }

        var projectionObservationStateForTesting: ProjectionObservationState {
            ProjectionObservationState(
                runID: subscriptionRunID,
                generation: projectionGeneration,
                checkpoint: projectionCheckpoint,
                catalogCheckpoint: catalogProjectionCheckpoint
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
    private func didApplyProjection(
        runID: UUID?,
        publicationSequence: UInt64,
        application: @autoclosure () -> ProjectionApplication
    ) {
        #if DEBUG
            guard let runID, subscriptionRunID == runID, let manager = workspaceManager,
                  !manager.isPreparingForWindowClose
            else { return }
            projectionGeneration += 1
            let checkpoint = ProjectionCheckpoint(
                runID: runID,
                generation: projectionGeneration,
                publicationSequence: publicationSequence,
                application: application()
            )
            projectionCheckpoint = checkpoint
            if checkpoint.catalogReceipt != nil { catalogProjectionCheckpoint = checkpoint }
            projectionObservationSubject.send(.applied(checkpoint))
        #endif
    }

    func start() {
        guard subscriptionTask == nil, let manager = workspaceManager, !manager.isPreparingForWindowClose else { return }
        let initialAttempt = manager.beginDomainCatalogAttempt()
        let runID = UUID()
        subscriptionRunID = runID
        subscriptionTask = Task { [weak self, client] in
            let subscription = await client.store.subscribe()
            if let self, isCurrentRun(runID) {
                await projectInitial(subscription.snapshot, attempt: initialAttempt, runID: runID)
            }
            for await event in subscription.events {
                guard !Task.isCancelled, let self, isCurrentRun(runID) else { return }
                await self.consume(event, runID: runID)
            }
            // The authority never finishes subscriber streams; intentional stop is cancellation. A
            // still-current end is reported as an ordinary refresh failure (explicit Retry still
            // reloads); no restart or repeated Default creation.
            guard let self, isCurrentRun(runID), let manager = workspaceManager else { return }
            manager.reportDomainCatalogFailure(
                .modelProjection("subscription_ended"), snapshot: nil, attempt: manager.beginDomainCatalogAttempt()
            )
        }
    }

    private func projectInitial(
        _ snapshot: DomainWorkspaceCatalogSnapshot,
        attempt: DomainCatalogAttempt,
        runID: UUID
    ) async {
        let projectionSpan = StartupPhaseLog.begin(.bridgeInitialProjection, window: client.windowID)
        defer { projectionSpan.end() }
        var initial = snapshot
        if initial.isBootstrapped, initial.workspaces.isEmpty,
           let candidate = workspaceManager?.runtimeOwnedDefaultWorkspaceCandidate()
        {
            let fileURL = workspaceManager?.workspaceFileURL(for: candidate)
            if let fileURL {
                do {
                    let outcome: DomainCommandOutcome
                    #if DEBUG
                        if let override = initialDefaultCreateOverride {
                            override.observeCandidate(candidate)
                            outcome = override.outcome
                        } else {
                            outcome = try await client.create(candidate, fileURL: fileURL)
                        }
                    #else
                        outcome = try await client.create(candidate, fileURL: fileURL)
                    #endif
                    guard isCurrentRun(runID) else { return }
                    if !outcome.isSuccessfulDomainMutation {
                        workspaceManager?.reportDomainAuthorityIssue(outcome, operation: "create_default")
                    }
                } catch {
                    guard isCurrentRun(runID) else { return }
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
        await projectResolvingStaleness(initial, attempt: attempt, runID: runID)
    }

    private func consume(_ event: DomainWorkspaceEvent, runID: UUID) async {
        guard event.sequence > lastPublicationSequence, let manager = workspaceManager else { return }
        let attempt = manager.beginDomainCatalogAttempt()
        let gap = lastPublicationSequence != 0 && event.sequence != lastPublicationSequence &+ 1
        if !gap, await suppressSelfEcho(for: event, runID: runID) { return }
        guard isCurrentRun(runID) else { return }
        let snapshot = await client.snapshot()
        guard isCurrentRun(runID) else { return }
        await projectResolvingStaleness(snapshot, attempt: attempt, runID: runID)
    }

    /// A floor raised between read and apply (or a competing transaction) gets exactly one
    /// current-snapshot refetch per triggering operation; no loop, timer or delay.
    private func projectResolvingStaleness(
        _ snapshot: DomainWorkspaceCatalogSnapshot,
        attempt: DomainCatalogAttempt,
        runID: UUID
    ) async {
        /// A covering accepted reconciliation (e.g. a newer retry/event/reload) needs nothing further.
        func isUncoveredFreshnessRejection(
            _ rejection: DomainCatalogRejection?, _ snapshot: DomainWorkspaceCatalogSnapshot
        ) -> Bool {
            guard let rejection, [.stalePublication, .staleCatalogRevision, .reentrant, .superseded].contains(rejection)
            else { return false }
            return workspaceManager?.coversDomainCatalog(snapshot) == false
        }
        var rejection = project(snapshot, attempt: attempt, runID: runID)
        var resolved = snapshot
        if isUncoveredFreshnessRejection(rejection, snapshot), let refetchAttempt = workspaceManager?.beginDomainCatalogAttempt() {
            let refetched = await client.snapshot()
            guard isCurrentRun(runID) else { return }
            rejection = project(refetched, attempt: refetchAttempt, runID: runID)
            resolved = refetched
            // Budget exhausted: a visible, retryable failure rather than permanent loading.
            if isUncoveredFreshnessRejection(rejection, refetched) {
                workspaceManager?.reportDomainCatalogFailure(
                    .catalogChangedDuringRefresh, snapshot: refetched, attempt: refetchAttempt
                )
            }
        }
        if let rejection {
            didRejectProjection(runID: runID, publicationSequence: resolved.publicationSequence, reason: rejection)
        }
    }

    /// The originating window already applied its command outcome (revisions + digest) via
    /// `applyDomainAuthorityOutcome`, so echoing its own commit back through a full catalog
    /// snapshot plus a MainActor document decode would only amplify every capture by W windows.
    /// Bookkeeping is refreshed from a single-workspace snapshot instead.
    private func suppressSelfEcho(for event: DomainWorkspaceEvent, runID: UUID?) async -> Bool {
        let ownerRunID = runID ?? subscriptionRunID
        let suppressibleKinds: Set<DomainWorkspaceEventKind> = [
            .workingStateCommitted, .savedDocumentCommitted, .operationDeduplicated
        ]
        guard case let .appPresentation(originWindowID) = event.origin,
              originWindowID == client.windowID,
              suppressibleKinds.contains(event.kind),
              let workspaceID = event.workspaceID,
              projectedModels[workspaceID] != nil,
              let baselineGeneration = acceptedReconciliationGeneration,
              workspaceManager?.admitsDomainSelfEcho(baselineGeneration: baselineGeneration) == true
        else { return false }
        guard let workspace = await client.canonicalWorkspaceSnapshot(workspaceID),
              workspace.health.acceptsMutations,
              let model = workspaceManager?.workspace(withID: workspaceID)
        else { return false }
        if let runID, !isCurrentRun(runID) { return false }
        // Only an accepted one-record baseline may advance caches; otherwise take the full path.
        guard workspaceManager?.acceptDomainAuthoritySelfEchoBaseline(
            workspaceID: workspaceID,
            revisions: workspace.revisions,
            digest: workspace.document.contentDigest,
            health: workspace.health,
            catalogRevision: event.catalogRevision,
            publicationSequence: event.sequence,
            baselineGeneration: baselineGeneration
        ) == true else { return false }
        guard subscriptionRunID == ownerRunID, !Task.isCancelled,
              workspaceManager?.isPreparingForWindowClose == false
        else { return false }
        // A same-window commit can be accepted just before a newer local edit is captured. Keep the
        // local model in both the manager and bridge cache: advancing the baseline below lets the
        // newer edit commit from the accepted revision, and explicit failed-save reconciliation
        // remains responsible for authoritative replacement when a two-phase cleanup save does not
        // complete. The outcome does not depend on re-encoding the model to compare digests.
        projectedModels[workspaceID] = model
        projectedDigests[workspaceID] = workspace.document.contentDigest
        lastPublicationSequence = event.sequence
        didApplyProjection(runID: runID, publicationSequence: event.sequence, application: .selfEchoBaseline)
        return true
    }

    /// Applies one complete snapshot through the manager's accepted-catalog boundary. Candidate
    /// caches are committed only for an accepted reconciliation receipt (complete or incomplete), so
    /// the caches always describe reconciled manager state; chooser completeness is the manager's.
    private func project(
        _ snapshot: DomainWorkspaceCatalogSnapshot,
        attempt: DomainCatalogAttempt,
        runID: UUID
    ) -> DomainCatalogRejection? {
        guard isCurrentRun(runID), let manager = workspaceManager else { return nil }
        if let rejection = manager.catalogReadRejection(snapshot, attempt: attempt) { return rejection }
        guard snapshot.isBootstrapped else {
            manager.reportDomainCatalogFailure(.notBootstrapped, snapshot: snapshot, attempt: attempt)
            return .invalidCatalog("not_bootstrapped")
        }
        guard snapshot.publicationSequence >= lastPublicationSequence else { return .stalePublication }
        let records = snapshot.workspaces
        guard Set(records.map(\.document.workspaceID)).count == records.count else {
            manager.reportDomainCatalogFailure(
                .modelProjection("duplicate_record_id"), error: DomainProjectionError.duplicateRecords,
                snapshot: snapshot, attempt: attempt
            )
            return .invalidCatalog("duplicate_record_id")
        }
        let nextDigests = Dictionary(uniqueKeysWithValues: records.map {
            ($0.document.workspaceID, $0.document.contentDigest)
        })
        let baselineGeneration = acceptedReconciliationGeneration
            .flatMap { $0 == manager.domainCatalogReconciliationGeneration ? $0 : nil }
        var cacheIsTrusted = baselineGeneration != nil && !manager.requiresFullCatalogReconciliation
        if let baselineGeneration, Set(projectedModels.keys) == Set(nextDigests.keys), projectedDigests == nextDigests {
            switch manager.applyDomainWorkspaceCatalog(
                snapshot,
                projection: .metadata(baselineGeneration: baselineGeneration),
                preferredActiveWorkspaceID: nil,
                rootMapPolicy: .snapshotMetadata,
                attempt: attempt
            ) {
            case let .accepted(receipt):
                commitAccepted(receipt, digests: nextDigests, runID: runID)
                return nil
            case .rejected(.fullProjectionRequired):
                cacheIsTrusted = false
            case let .rejected(reason):
                return reason
            }
        }

        // Decode failures degrade only their authoritative member. Keep all-record digests below:
        // missing model keys force the next snapshot to retry even an unchanged failed document.
        var nextModels: [UUID: WorkspaceModel] = [:]
        var failedIDs: Set<UUID> = []
        for record in records {
            let workspaceID = record.document.workspaceID
            if cacheIsTrusted, projectedDigests[workspaceID] == record.document.contentDigest,
               let cached = projectedModels[workspaceID]
            {
                nextModels[workspaceID] = cached
            } else {
                do {
                    nextModels[workspaceID] = try manager.decodeDomainWorkspaceCatalogRecord(record)
                } catch {
                    failedIDs.insert(workspaceID)
                }
            }
        }
        // Presentation-only availability, never a write to authoritative membership. The existing
        // incomplete-catalog warning carries the failed IDs and keeps valid rows usable. The manager
        // retains last-known models for unavailable members; do not cache failed decodes here,
        // otherwise an unchanged failed digest could incorrectly take the metadata fast path.
        let available = DomainWorkspaceCatalogSnapshot(
            runtimeIdentity: snapshot.runtimeIdentity, isBootstrapped: snapshot.isBootstrapped,
            publicationSequence: snapshot.publicationSequence, catalogRevision: snapshot.catalogRevision,
            health: snapshot.health, workspaces: records.filter { !failedIDs.contains($0.document.workspaceID) },
            unavailableWorkspaceIDs: snapshot.unavailableWorkspaceIDs.union(failedIDs)
        )
        let result = manager.applyDomainWorkspaceCatalog(
            available,
            projection: .full(records.compactMap { nextModels[$0.document.workspaceID] }),
            preferredActiveWorkspaceID: manager.activeWorkspaceID,
            rootMapPolicy: .snapshotMetadata,
            attempt: attempt
        )
        guard case let .accepted(receipt) = result else { return result.rejection }
        guard isCurrentRun(runID) else { return nil }
        projectedModels = nextModels
        commitAccepted(receipt, digests: nextDigests, runID: runID)
        return nil
    }

    private func commitAccepted(
        _ receipt: DomainCatalogApplicationReceipt,
        digests: [UUID: String],
        runID: UUID
    ) {
        guard isCurrentRun(runID) else { return }
        projectedDigests = digests
        lastPublicationSequence = receipt.publicationSequence
        acceptedReconciliationGeneration = receipt.reconciliationGeneration
        didApplyProjection(runID: runID, publicationSequence: receipt.publicationSequence, application: .catalog(receipt))
    }

    /// Records a resolved attempt the manager did not accept (DEBUG only); nothing advanced.
    private func didRejectProjection(runID: UUID, publicationSequence: UInt64, reason: DomainCatalogRejection) {
        #if DEBUG
            guard subscriptionRunID == runID else { return }
            projectionObservationSubject.send(.rejected(
                runID: runID, publicationSequence: publicationSequence, reason: reason
            ))
        #endif
    }
}

private enum DomainProjectionError: LocalizedError {
    case duplicateRecords

    var errorDescription: String? {
        "Runtime workspace projection contained duplicate records; the previous accepted catalog was retained."
    }
}
