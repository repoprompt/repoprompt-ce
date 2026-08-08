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

/// Revisioned app-process client for the runtime-owned workspace/context authority.
/// It is the only production persistence dependency injected into a workspace manager.
struct DomainWorkspaceAuthorityClient {
    let store: DomainWorkspaceStore
    let windowID: Int

    func snapshot() async -> DomainWorkspaceCatalogSnapshot {
        await store.snapshot()
    }

    func canonicalWorkspaceSnapshot(_ workspaceID: UUID) async -> DomainWorkspaceSnapshot? {
        await store.canonicalWorkspaceSnapshot(workspaceID)
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
        operationID: UUID = UUID()
    ) async throws -> DomainCommandOutcome {
        let document = try document(for: workspace, fileURL: fileURL)
        let envelope = DomainWorkspaceCommandEnvelope(
            operationID: operationID,
            expectedCatalogRevision: nil,
            expectedWorkspaceRevision: 0,
            origin: .appPresentation(windowID: windowID),
            command: .createWorkspace(document)
        )
        let first = await executeStable(envelope)
        guard first.disposition == .conflict,
              first.errorCode == .stateConflict,
              first.diagnostic == "durable_create_conflict"
              || first.diagnostic == "catalog_revision_mismatch",
              !Task.isCancelled
        else { return first }
        // The authority refreshes its durable catalog before returning a catalog-only conflict.
        // Retry the identical envelope once so the operation ID remains idempotent while work is bounded.
        return await executeStable(envelope)
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
        let document = try document(for: workspace, fileURL: fileURL)
        var saveRevision = expectedWorkspaceRevision
        if document.contentDigest != expectedContentDigest {
            let working = await executeStable(.init(
                operationID: operationIDs.working,
                expectedWorkspaceRevision: expectedWorkspaceRevision,
                origin: .appPresentation(windowID: windowID),
                command: .replaceWorkingDocument(document)
            ))
            guard working.isSuccessfulDomainMutation else { return working }
            saveRevision = working.after?.workingRevision
                ?? working.workspace?.revisions.workingRevision
        }
        return await executeStable(.init(
            operationID: operationIDs.saved,
            expectedWorkspaceRevision: saveRevision,
            origin: .appPresentation(windowID: windowID),
            command: .saveWorkspaceDocument(workspaceID: workspace.id)
        ))
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
        let bytes = try JSONEncoder().encode(workspace)
        return try DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL)
    }

    /// Retries only the exact same envelope. A changed CAS expectation or payload is a new
    /// logical operation and must receive a new operation ID from the caller.
    private func executeStable(
        _ envelope: DomainWorkspaceCommandEnvelope
    ) async -> DomainCommandOutcome {
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
        subscriptionTask?.cancel()
        subscriptionTask = nil
        projectedDigests.removeAll(keepingCapacity: false)
        projectedHealth.removeAll(keepingCapacity: false)
        projectedModels.removeAll(keepingCapacity: false)
    }

    #if DEBUG
        var hasActiveSubscriptionForTesting: Bool {
            subscriptionTask != nil
        }

        func waitUntilProjected(
            through publicationSequence: UInt64,
            timeout: Duration = .seconds(5)
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            repeat {
                if lastPublicationSequence >= publicationSequence { return true }
                do {
                    try await Task.sleep(nanoseconds: 10_000_000)
                } catch {
                    return false
                }
            } while clock.now < deadline
            return lastPublicationSequence >= publicationSequence
        }
    #endif

    func start() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { [weak self, client] in
            let subscription = await client.store.subscribe()
            guard subscription.snapshot.isBootstrapped else { return }
            if let self {
                await projectInitial(subscription.snapshot)
            }
            for await event in subscription.events {
                guard !Task.isCancelled, let self else { return }
                await self.consume(event)
            }
        }
    }

    private func projectInitial(_ snapshot: DomainWorkspaceCatalogSnapshot) async {
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
        project(initial, force: true)
    }

    private func consume(_ event: DomainWorkspaceEvent) async {
        guard event.sequence > lastPublicationSequence else { return }
        let gap = lastPublicationSequence != 0 && event.sequence != lastPublicationSequence &+ 1
        if !gap, await suppressSelfEcho(for: event) { return }
        let snapshot = await client.snapshot()
        project(
            snapshot,
            force: gap || event.kind == .externalReloaded
        )
    }

    /// The originating window already applied its command outcome (revisions + digest) via
    /// `applyDomainAuthorityOutcome`, so echoing its own commit back through a full catalog
    /// snapshot plus a MainActor document decode would only amplify every capture by W windows.
    /// Bookkeeping is refreshed from a single-workspace snapshot instead.
    private func suppressSelfEcho(for event: DomainWorkspaceEvent) async -> Bool {
        let suppressibleKinds: Set<DomainWorkspaceEventKind> = [
            .workingStateCommitted, .savedDocumentCommitted, .operationDeduplicated
        ]
        guard case let .appPresentation(originWindowID) = event.origin,
              originWindowID == client.windowID,
              suppressibleKinds.contains(event.kind),
              let workspaceID = event.workspaceID,
              projectedModels[workspaceID] != nil
        else { return false }
        guard let workspace = await client.store.workspaceSnapshot(workspaceID),
              workspace.health.acceptsMutations,
              let model = workspaceManager?.workspace(withID: workspaceID)
        else { return false }
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
        return true
    }

    private func project(_ snapshot: DomainWorkspaceCatalogSnapshot, force: Bool) {
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
                publicationSequence: snapshot.publicationSequence
            )
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
    }
}

private enum DomainProjectionError: LocalizedError {
    case incompleteSnapshot

    var errorDescription: String? {
        "Runtime workspace projection was incomplete; the previous complete snapshot was retained."
    }
}
