import Foundation

package enum DomainExternalReloadActivity: Equatable {
    case changed
    case unchanged
    case recoveryPending
}

package struct DomainWorkspaceStore {
    private let authority: DomainWorkspaceContextAuthority

    init(authority: DomainWorkspaceContextAuthority) {
        self.authority = authority
    }

    package func snapshot() async -> DomainWorkspaceCatalogSnapshot {
        await authority.readySnapshot()
    }

    package func subscribe() async -> DomainWorkspaceSnapshotSubscription {
        await authority.readySubscription()
    }

    package func execute(_ command: DomainWorkspaceCommandEnvelope) async -> DomainCommandOutcome {
        await authority.execute(command)
    }

    @discardableResult
    package func reloadExternalChanges() async -> DomainExternalReloadActivity {
        await authority.reloadExternalChanges()
    }

    #if DEBUG
        package func testSetBeforeExternalReconciliation(
            _ hook: (@Sendable (UUID) async -> Void)?
        ) async {
            await authority.testSetBeforeExternalReconciliation(hook)
        }
    #endif

    /// Registers the app's current in-memory document as an awaited read authority.
    ///
    /// This compatibility seam is intentionally transient: it makes newly created and ephemeral
    /// workspaces immediately routable without waiting for debounced durable publication, while
    /// leaving the normal command/persistence path authoritative for mutations.
    package func registerReadDocument(_ document: DomainWorkspaceDocument) async -> DomainWorkspaceSnapshot {
        await authority.registerReadDocument(document)
    }

    package func workspaceSnapshot(_ workspaceID: UUID) async -> DomainWorkspaceSnapshot? {
        await authority.workspaceSnapshot(workspaceID)
    }

    /// Returns only persisted command-authority state. Read registrations are routing overlays and
    /// must not influence mutation admission, recovery CAS baselines, or authority health.
    package func canonicalWorkspaceSnapshot(_ workspaceID: UUID) async -> DomainWorkspaceSnapshot? {
        await authority.canonicalWorkspaceSnapshot(workspaceID)
    }
}

package struct DomainContextStore {
    private let authority: DomainWorkspaceContextAuthority

    init(authority: DomainWorkspaceContextAuthority) {
        self.authority = authority
    }

    package func snapshot(_ identity: DomainContextIdentity) async -> DomainContextSnapshot? {
        await authority.contextSnapshot(identity)
    }

    package func workspaceSnapshot(_ workspaceID: UUID) async -> DomainWorkspaceSnapshot? {
        await authority.workspaceSnapshot(workspaceID)
    }
}

struct BoundedDomainOperationIndex {
    private let capacity: Int
    private var values: [UUID: DomainRecordedOperation] = [:]
    private var order: [UUID] = []
    private var head = 0

    init(capacity: Int, operations: [DomainRecordedOperation] = []) {
        self.capacity = max(1, capacity)
        replace(with: operations)
    }

    subscript(operationID: UUID) -> DomainRecordedOperation? {
        values[operationID]
    }

    var count: Int {
        values.count
    }

    mutating func replace(with operations: [DomainRecordedOperation]) {
        values.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        head = 0
        let retained = operations.sorted {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            return $0.operationID.uuidString < $1.operationID.uuidString
        }.suffix(capacity)
        for operation in retained {
            values[operation.operationID] = operation
            order.append(operation.operationID)
        }
    }

    mutating func insert(_ operation: DomainRecordedOperation) {
        if values.updateValue(operation, forKey: operation.operationID) != nil { return }
        order.append(operation.operationID)
        while values.count > capacity, head < order.count {
            values.removeValue(forKey: order[head])
            head += 1
        }
        if head >= capacity, head * 2 >= order.count {
            order.removeFirst(head)
            head = 0
        }
    }
}

actor DomainWorkspaceContextAuthority {
    private static let maximumGlobalOperations = 4096
    private static let maximumWorkspaceOperations = 256
    private static let maximumCASRecoveryAttempts = 2

    #if DEBUG
        private var testBeforeExternalReconciliation: (@Sendable (UUID) async -> Void)?
    #endif

    private enum DirtyExternalRebaseResult {
        case applied
        case recoveryPending
        case failed
    }

    private struct WorkspaceRecord {
        var document: DomainWorkspaceDocument
        var savedDigest: String
        var revisions: DomainRevisionState
        var contextRevisions: [UUID: DomainRevisionState]
        var contextTombstones: [UUID: UInt64]
        var operations: [DomainRecordedOperation]
        var operationIndex: BoundedDomainOperationIndex
        var health: DomainAuthorityHealth
        var externalDocument: DomainWorkspaceDocument?
        var fileMetadata: DomainFileMetadata
    }

    private let identity: DomainRuntimeIdentity
    private let persistence: DomainPersistenceCoordinator
    private let metrics: DomainRuntimeMetricsSink
    private var records: [UUID: WorkspaceRecord] = [:]
    /// Awaited in-memory registrations used only by read routing. They are not catalog entries and
    /// never persist ephemeral/test workspaces. A later command invalidates the overlay.
    private var readRegistrations: [UUID: DomainWorkspaceSnapshot] = [:]
    private var unavailableWorkspaces: [UUID: DomainPersistenceBootstrap.UnavailableWorkspace] = [:]
    private var globalOperations = BoundedDomainOperationIndex(capacity: maximumGlobalOperations)
    private var health: DomainAuthorityHealth = .writable
    private var catalogRevision: UInt64 = 0
    private var publicationSequence: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<DomainWorkspaceEvent>.Continuation] = [:]
    private var bootstrapTask: Task<DomainPersistenceBootstrap, Never>?
    private var catalogMutationInProgress = false
    private var catalogMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var didBootstrap = false

    init(
        identity: DomainRuntimeIdentity,
        persistence: DomainPersistenceCoordinator,
        metrics: DomainRuntimeMetricsSink
    ) {
        self.identity = identity
        self.persistence = persistence
        self.metrics = metrics
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        let task: Task<DomainPersistenceBootstrap, Never>
        if let bootstrapTask {
            task = bootstrapTask
        } else {
            let persistence = persistence
            let created = Task { await persistence.bootstrap() }
            bootstrapTask = created
            task = created
        }
        let loaded = await task.value
        guard !didBootstrap else { return }
        health = loaded.health
        catalogRevision = loaded.catalogRevision
        let durableOperations = loaded.deletedOperations
            + loaded.workspaces.flatMap(\.operations)
        globalOperations.replace(with: durableOperations)
        unavailableWorkspaces = Dictionary(uniqueKeysWithValues: loaded.unavailableWorkspaces.map {
            ($0.workspaceID, $0)
        })
        records = Dictionary(uniqueKeysWithValues: loaded.workspaces.map { workspace in
            let record = WorkspaceRecord(
                document: workspace.document,
                savedDigest: workspace.savedDigest,
                revisions: workspace.revisions,
                contextRevisions: workspace.contextRevisions,
                contextTombstones: workspace.contextTombstones,
                operations: workspace.operations,
                operationIndex: BoundedDomainOperationIndex(
                    capacity: Self.maximumWorkspaceOperations,
                    operations: workspace.operations
                ),
                health: workspace.health,
                externalDocument: nil,
                fileMetadata: workspace.fileMetadata
            )
            return (workspace.document.workspaceID, record)
        })
        didBootstrap = true
        bootstrapTask = nil
        publish(
            kind: health.acceptsMutations ? .bootstrapped : .degraded,
            workspaceID: nil,
            contextID: nil,
            operationID: nil,
            revisions: nil,
            diagnostic: health.acceptsMutations ? nil : "runtime_bootstrap_degraded"
        )
    }

    func snapshot() -> DomainWorkspaceCatalogSnapshot {
        DomainWorkspaceCatalogSnapshot(
            runtimeIdentity: identity,
            isBootstrapped: didBootstrap,
            publicationSequence: publicationSequence,
            catalogRevision: catalogRevision,
            health: health,
            workspaces: records.values.map(makeSnapshot).sorted {
                let lhs = $0.document.metadata.name.localizedCaseInsensitiveCompare($1.document.metadata.name)
                if lhs != .orderedSame { return lhs == .orderedAscending }
                return $0.document.workspaceID.uuidString < $1.document.workspaceID.uuidString
            }
        )
    }

    func workspaceSnapshot(_ workspaceID: UUID) -> DomainWorkspaceSnapshot? {
        readRegistrations[workspaceID] ?? records[workspaceID].map(makeSnapshot)
    }

    /// Command outcomes and mutation admission must report canonical record state; the read
    /// overlay is routing-only and must never leak into recovery health or revision baselines.
    func canonicalWorkspaceSnapshot(_ workspaceID: UUID) -> DomainWorkspaceSnapshot? {
        records[workspaceID].map(makeSnapshot)
    }

    func contextSnapshot(_ identity: DomainContextIdentity) -> DomainContextSnapshot? {
        workspaceSnapshot(identity.workspaceID)?.contexts.first {
            $0.metadata.identity.contextID == identity.contextID
        }
    }

    func registerReadDocument(_ document: DomainWorkspaceDocument) async -> DomainWorkspaceSnapshot {
        await bootstrap()
        let previous = readRegistrations[document.workspaceID]
            ?? records[document.workspaceID].map(makeSnapshot)
        if let previous, previous.document.contentDigest == document.contentDigest {
            return previous
        }

        let before = previous?.revisions ?? .initial
        let nextWorking = before.workingRevision &+ 1
        let revisions = DomainRevisionState(
            workingRevision: nextWorking,
            savedRevision: before.savedRevision,
            dirtyRevision: nextWorking
        )
        let contextRevisions: [UUID: DomainRevisionState] = if let previous {
            Self.updatedContextRevisions(
                previousDocument: previous.document,
                nextDocument: document,
                previousRevisions: Dictionary(uniqueKeysWithValues: previous.contexts.map {
                    ($0.metadata.identity.contextID, $0.revisions)
                }),
                workspaceRevision: revisions
            ).revisions
        } else {
            Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                ($0.identity.contextID, revisions)
            })
        }
        let registration = DomainWorkspaceSnapshot(
            document: document,
            revisions: revisions,
            health: .writable,
            contexts: document.metadata.contexts.map { metadata in
                DomainContextSnapshot(
                    metadata: metadata,
                    revisions: contextRevisions[metadata.identity.contextID] ?? revisions,
                    health: .writable
                )
            }
        )
        readRegistrations[document.workspaceID] = registration
        return registration
    }

    func readySnapshot() async -> DomainWorkspaceCatalogSnapshot {
        await bootstrap()
        return snapshot()
    }

    func readySubscription() async -> DomainWorkspaceSnapshotSubscription {
        await bootstrap()
        return subscribe()
    }

    private func subscribe() -> DomainWorkspaceSnapshotSubscription {
        let token = UUID()
        let stream = AsyncStream<DomainWorkspaceEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            subscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(token) }
            }
        }
        return DomainWorkspaceSnapshotSubscription(snapshot: snapshot(), events: stream)
    }

    func execute(_ envelope: DomainWorkspaceCommandEnvelope) async -> DomainCommandOutcome {
        await bootstrap()
        let fingerprint = envelope.fingerprint
        let workspaceID = envelope.workspaceID
        if let recorded = await recordedOutcome(
            for: envelope,
            fingerprint: fingerprint
        ) {
            return recorded
        }
        if let document = commandDocument(envelope.command),
           let diagnostic = invalidDocumentDiagnostic(document)
        {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .invalid,
                errorCode: .invalidDocument,
                diagnostic: diagnostic
            )
        }
        if let workspaceID, unavailableWorkspaces[workspaceID] != nil {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_document_unavailable"
            )
        }
        guard health.acceptsMutations else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "runtime_authority_not_writable"
            )
        }
        if let expected = envelope.expectedCatalogRevision, expected != catalogRevision {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "catalog_revision_mismatch"
            )
        }

        let outcome: DomainCommandOutcome = switch envelope.command {
        case let .createWorkspace(document):
            await createWorkspace(document, envelope: envelope, fingerprint: fingerprint)
        case let .replaceWorkingDocument(document):
            await replaceWorkingDocument(document, envelope: envelope, fingerprint: fingerprint)
        case let .saveWorkspaceDocument(workspaceID):
            await saveWorkspace(workspaceID, envelope: envelope, fingerprint: fingerprint)
        case let .resolveExternalConflict(workspaceID, acceptExternal, protectedAgentIdentities):
            await resolveExternalConflict(
                workspaceID,
                acceptExternal: acceptExternal,
                protectedAgentIdentities: protectedAgentIdentities,
                envelope: envelope,
                fingerprint: fingerprint
            )
        case let .deleteWorkspace(workspaceID):
            await deleteWorkspace(workspaceID, envelope: envelope, fingerprint: fingerprint)
        }
        invalidateReadRegistrationIfSuperseded(
            workspaceID: workspaceID,
            disposition: outcome.disposition,
            resultingDigest: outcome.resultingDigest
        )
        return outcome
    }

    /// Keep the read overlay while persistence is suspended/re-entrant. Any completed canonical
    /// transition supersedes it, including a different newer document and a deduplicated replay
    /// of a completed command. A failed command must not reopen the publication race, so replayed
    /// transients key on the original recorded disposition, never on the replay's `.deduplicated`.
    private func invalidateReadRegistrationIfSuperseded(
        workspaceID: UUID?,
        disposition: DomainCommandDisposition,
        resultingDigest: String?
    ) {
        guard let workspaceID,
              let registration = readRegistrations[workspaceID]
        else { return }
        switch disposition {
        case .applied, .deduplicated:
            readRegistrations.removeValue(forKey: workspaceID)
        case .unchanged where resultingDigest == nil
            || resultingDigest == registration.document.contentDigest:
            readRegistrations.removeValue(forKey: workspaceID)
        default:
            break
        }
    }

    private func commandDocument(_ command: DomainWorkspaceCommand) -> DomainWorkspaceDocument? {
        switch command {
        case let .createWorkspace(document), let .replaceWorkingDocument(document):
            document
        case .saveWorkspaceDocument, .deleteWorkspace, .resolveExternalConflict:
            nil
        }
    }

    private func invalidDocumentDiagnostic(_ document: DomainWorkspaceDocument) -> String? {
        guard document.metadata.workspaceID == document.workspaceID else {
            return "workspace_document_id_mismatch"
        }
        var contextIDs = Set<UUID>()
        for context in document.metadata.contexts {
            guard context.identity.workspaceID == document.workspaceID else {
                return "context_workspace_id_mismatch"
            }
            guard contextIDs.insert(context.identity.contextID).inserted else {
                return "duplicate_context_id"
            }
        }
        return nil
    }

    private func recordedOutcome(
        for envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String
    ) async -> DomainCommandOutcome? {
        let workspaceID = envelope.workspaceID
        if let record = workspaceID.flatMap({ records[$0] }),
           let prior = record.operationIndex[envelope.operationID]
        {
            guard prior.fingerprint == fingerprint else {
                return collisionOutcome(envelope.operationID, workspace: makeSnapshot(record))
            }
            if case let .createWorkspace(document) = envelope.command {
                do {
                    catalogRevision = try await max(
                        catalogRevision,
                        persistence.repairRecoveredCreate(document: document, now: Date())
                    )
                } catch {
                    return persistenceFailureOutcome(envelope, record: record, error: error)
                }
            }
            publish(
                kind: .operationDeduplicated,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: envelope.operationID,
                origin: envelope.origin,
                revisions: record.revisions,
                diagnostic: nil
            )
            invalidateReadRegistrationIfSuperseded(
                workspaceID: workspaceID,
                disposition: prior.disposition,
                resultingDigest: prior.resultingDigest
            )
            return prior.outcome(workspace: makeSnapshot(record))
        }
        if let prior = globalOperations[envelope.operationID] {
            guard prior.fingerprint == fingerprint else {
                return collisionOutcome(envelope.operationID, workspace: nil)
            }
            if case let .createWorkspace(document) = envelope.command {
                do {
                    catalogRevision = try await max(
                        catalogRevision,
                        persistence.repairRecoveredCreate(document: document, now: Date())
                    )
                } catch {
                    return persistenceFailureOutcome(
                        envelope,
                        record: records[document.workspaceID],
                        error: error
                    )
                }
            }
            invalidateReadRegistrationIfSuperseded(
                workspaceID: workspaceID,
                disposition: prior.disposition,
                resultingDigest: prior.resultingDigest
            )
            return prior.outcome(workspace: workspaceID.flatMap(canonicalWorkspaceSnapshot))
        }
        return nil
    }

    func reloadExternalChanges() async -> DomainExternalReloadActivity {
        await bootstrap()
        guard !Task.isCancelled else { return .recoveryPending }
        var changed = false
        var recoveryPending = false

        let observedCatalogRevision: UInt64?
        do {
            observedCatalogRevision = try await persistence.currentCatalogRevision()
        } catch DomainPersistenceError.cancelled {
            return .recoveryPending
        } catch is CancellationError {
            return .recoveryPending
        } catch {
            let degraded = DomainAuthorityHealth.degradedReadOnly(
                reason: "workspace_catalog_probe_failed"
            )
            if health != degraded {
                health = degraded
                publish(
                    kind: .degraded,
                    workspaceID: nil,
                    contextID: nil,
                    operationID: nil,
                    revisions: nil,
                    diagnostic: "workspace_catalog_probe_failed"
                )
            }
            return .recoveryPending
        }

        let catalogChanged = observedCatalogRevision.map { $0 != catalogRevision }
            ?? (catalogRevision != 0)
        if catalogChanged || !health.acceptsMutations {
            let durableCatalog = await persistence.bootstrap()
            guard !Task.isCancelled else { return .recoveryPending }
            let previousHealth = health
            health = durableCatalog.health
            catalogRevision = max(catalogRevision, durableCatalog.catalogRevision)
            for operation in durableCatalog.deletedOperations
                + durableCatalog.workspaces.flatMap(\.operations)
            {
                globalOperations.insert(operation)
            }
            for workspaceID in durableCatalog.deletedWorkspaceIDs.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                unavailableWorkspaces.removeValue(forKey: workspaceID)
                if records.removeValue(forKey: workspaceID) != nil {
                    readRegistrations.removeValue(forKey: workspaceID)
                    changed = true
                    publish(
                        kind: .workspaceDeleted,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: nil,
                        diagnostic: "external_catalog_deletion"
                    )
                }
            }
            for unavailable in durableCatalog.unavailableWorkspaces {
                guard records[unavailable.workspaceID] == nil else { continue }
                unavailableWorkspaces[unavailable.workspaceID] = unavailable
                recoveryPending = true
            }
            for workspace in durableCatalog.workspaces
                where records[workspace.document.workspaceID] == nil
            {
                let workspaceID = workspace.document.workspaceID
                records[workspaceID] = makeRecord(from: workspace)
                readRegistrations.removeValue(forKey: workspaceID)
                unavailableWorkspaces.removeValue(forKey: workspaceID)
                changed = true
                publish(
                    kind: .externalReloaded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: workspace.revisions,
                    diagnostic: "external_catalog_addition"
                )
            }
            if previousHealth != health {
                changed = true
                publish(
                    kind: health.acceptsMutations ? .externalReloaded : .degraded,
                    workspaceID: nil,
                    contextID: nil,
                    operationID: nil,
                    revisions: nil,
                    diagnostic: health.acceptsMutations
                        ? "workspace_catalog_recovered"
                        : "workspace_catalog_degraded"
                )
            }
            recoveryPending = recoveryPending || !health.acceptsMutations
        }

        for workspaceID in unavailableWorkspaces.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            guard let unavailable = unavailableWorkspaces[workspaceID] else { continue }
            let recovered = await persistence.reloadWorkspace(
                workspaceID: workspaceID,
                fileURL: unavailable.fileURL
            )
            guard unavailableWorkspaces[workspaceID]?.fileMetadata == unavailable.fileMetadata,
                  let recovered,
                  recovered.health.acceptsMutations
            else {
                recoveryPending = true
                continue
            }
            records[workspaceID] = makeRecord(from: recovered)
            readRegistrations.removeValue(forKey: workspaceID)
            unavailableWorkspaces.removeValue(forKey: workspaceID)
            changed = true
            publish(
                kind: .externalReloaded,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: nil,
                revisions: recovered.revisions,
                diagnostic: "workspace_document_recovered"
            )
        }

        for workspaceID in records.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var current = records[workspaceID] else { continue }
            if case .externalConflict = current.health { continue }
            if case let .degradedReadOnly(reason) = current.health, !reason.hasPrefix("external_") {
                // Journal/persistence-scoped degradation heals through a full reload once the
                // sidecar state is repaired. Saved-file-scoped ("external_*") degradation is
                // recovered by the metadata probe below instead, so a journal-backed reload
                // cannot flip health back to writable while the saved document is still bad.
                let recovered = await persistence.reloadWorkspace(
                    workspaceID: workspaceID,
                    fileURL: current.document.fileURL
                )
                guard records[workspaceID]?.revisions == current.revisions else { continue }
                if let recovered, recovered.health.acceptsMutations {
                    current = makeRecord(from: recovered)
                    records[workspaceID] = current
                    readRegistrations.removeValue(forKey: workspaceID)
                    changed = true
                    publish(
                        kind: .externalReloaded,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: current.revisions,
                        diagnostic: "workspace_persistence_recovered"
                    )
                } else {
                    recoveryPending = true
                    continue
                }
            }

            let observedRevision = current.revisions
            let observedSavedDigest = current.savedDigest
            let observedMetadata = current.fileMetadata
            let external = await persistence.externalDocument(
                for: makeSnapshot(current),
                savedDigest: observedSavedDigest,
                knownMetadata: observedMetadata
            )
            guard !Task.isCancelled else { return .recoveryPending }
            guard var record = records[workspaceID],
                  record.revisions == observedRevision,
                  record.savedDigest == observedSavedDigest,
                  record.fileMetadata == observedMetadata
            else { continue }

            switch external {
            case .cancelled:
                return .recoveryPending
            case let .unchanged(metadata):
                let recoveredExternalDegradation: Bool
                if case let .degradedReadOnly(reason) = record.health,
                   reason.hasPrefix("external_"),
                   record.fileMetadata != metadata
                {
                    record.health = .writable
                    record.externalDocument = nil
                    recoveredExternalDegradation = true
                    changed = true
                } else {
                    recoveredExternalDegradation = false
                }
                if record.fileMetadata != metadata || recoveredExternalDegradation {
                    record.fileMetadata = metadata
                    records[workspaceID] = record
                }
                if recoveredExternalDegradation {
                    publish(
                        kind: .externalReloaded,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: record.revisions,
                        diagnostic: "external_workspace_recovered"
                    )
                } else if !record.health.acceptsMutations {
                    recoveryPending = true
                }
            case let .missing(metadata):
                // A vanished saved document (unplugged volume, external cleanup) must not
                // brick the journal-backed workspace: an explicit save rewrites it and a
                // returning file is detected by the next metadata change.
                if record.fileMetadata != metadata {
                    record.fileMetadata = metadata
                    records[workspaceID] = record
                }
                if !record.health.acceptsMutations {
                    recoveryPending = true
                }
            case let .invalid(metadata):
                let degraded = DomainAuthorityHealth.degradedReadOnly(
                    reason: "external_workspace_decode_failed"
                )
                let shouldPublish = record.health != degraded
                record.health = degraded
                record.fileMetadata = metadata
                records[workspaceID] = record
                recoveryPending = true
                if shouldPublish {
                    publish(
                        kind: .degraded,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: record.revisions,
                        diagnostic: "external_workspace_decode_failed"
                    )
                }
            case let .changed(document, metadata):
                #if DEBUG
                    if let testBeforeExternalReconciliation {
                        await testBeforeExternalReconciliation(workspaceID)
                    }
                #endif
                switch await reconcileExternalDocument(
                    workspaceID: workspaceID,
                    externalDocument: document,
                    fileMetadata: metadata
                ) {
                case .applied:
                    changed = true
                case .recoveryPending, .failed:
                    recoveryPending = true
                }
            }
        }

        if changed { return .changed }
        return recoveryPending ? .recoveryPending : .unchanged
    }

    #if DEBUG
        func testSetBeforeExternalReconciliation(
            _ hook: (@Sendable (UUID) async -> Void)?
        ) {
            testBeforeExternalReconciliation = hook
        }
    #endif

    private func makeRecord(
        from workspace: DomainPersistenceBootstrap.Workspace
    ) -> WorkspaceRecord {
        WorkspaceRecord(
            document: workspace.document,
            savedDigest: workspace.savedDigest,
            revisions: workspace.revisions,
            contextRevisions: workspace.contextRevisions,
            contextTombstones: workspace.contextTombstones,
            operations: workspace.operations,
            operationIndex: BoundedDomainOperationIndex(
                capacity: Self.maximumWorkspaceOperations,
                operations: workspace.operations
            ),
            health: workspace.health,
            externalDocument: nil,
            fileMetadata: workspace.fileMetadata
        )
    }

    private func rebaseDirtyWorkingDocument(
        workspaceID: UUID,
        localDocument: DomainWorkspaceDocument,
        externalDocument: DomainWorkspaceDocument,
        fileMetadata: DomainFileMetadata
    ) async -> DirtyExternalRebaseResult {
        guard localDocument.workspaceID == workspaceID,
              externalDocument.workspaceID == workspaceID
        else { return .failed }

        // Recovery intentionally replays the captured local document as a whole-document winner.
        // A refresh updates only its durable CAS baseline; substituting refreshed bytes here would
        // silently discard this runtime's unsaved user state. The bounded loop prevents livelock.
        for attempt in 0 ..< Self.maximumCASRecoveryAttempts {
            guard var record = records[workspaceID], record.health.acceptsMutations else {
                return .failed
            }
            let before = record.revisions
            let restoresCapturedDocument = record.document.contentDigest != localDocument.contentDigest
            let revisions: DomainRevisionState
            let contextRevisions: [UUID: DomainRevisionState]
            let contextTombstones: [UUID: UInt64]
            if restoresCapturedDocument {
                let nextWorking = before.workingRevision &+ 1
                revisions = DomainRevisionState(
                    workingRevision: nextWorking,
                    savedRevision: before.savedRevision,
                    dirtyRevision: nextWorking
                )
                let contextUpdate = Self.updatedContextRevisions(
                    previousDocument: record.document,
                    nextDocument: localDocument,
                    previousRevisions: record.contextRevisions,
                    workspaceRevision: revisions
                )
                contextRevisions = contextUpdate.revisions
                contextTombstones = record.contextTombstones.merging(
                    contextUpdate.tombstones
                ) { _, new in new }
            } else {
                revisions = before
                contextRevisions = record.contextRevisions
                contextTombstones = record.contextTombstones
            }

            do {
                let persisted = try await persistence.persistConflictRebase(
                    document: localDocument,
                    externalSavedDigest: externalDocument.contentDigest,
                    expectedRevisions: before,
                    newRevisions: revisions,
                    contextRevisions: contextRevisions,
                    contextTombstones: contextTombstones,
                    operations: record.operations,
                    now: Date()
                )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
                record.document = localDocument
                record.savedDigest = persisted.journal.savedDigest
                record.revisions = persisted.journal.revisions
                record.contextRevisions = persisted.journal.contextRevisions
                record.contextTombstones = persisted.journal.contextTombstones
                record.operations = persisted.journal.operations
                record.operationIndex.replace(with: persisted.journal.operations)
                record.health = .writable
                record.externalDocument = nil
                record.fileMetadata = fileMetadata
                records[workspaceID] = record
                readRegistrations.removeValue(forKey: workspaceID)
                publish(
                    kind: .workingStateCommitted,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: record.revisions,
                    diagnostic: restoresCapturedDocument
                        ? "external_document_rebased_after_revision_replay"
                        : "external_document_rebased_keeping_local"
                )
                return .applied
            } catch let error as DomainPersistenceError {
                switch error {
                case .stateConflict:
                    await refreshAfterCASConflict(
                        workspaceID: workspaceID,
                        fileURL: localDocument.fileURL
                    )
                    if Task.isCancelled { return .recoveryPending }
                    if attempt + 1 < Self.maximumCASRecoveryAttempts { continue }
                    return .recoveryPending
                case .externalDocumentConflict, .cancelled:
                    return .recoveryPending
                default:
                    if var current = records[workspaceID] {
                        current.health = .degradedReadOnly(
                            reason: "workspace_persistence_rebase_failed"
                        )
                        records[workspaceID] = current
                        publish(
                            kind: .degraded,
                            workspaceID: workspaceID,
                            contextID: nil,
                            operationID: nil,
                            revisions: current.revisions,
                            diagnostic: "workspace_persistence_rebase_failed"
                        )
                    }
                    return .failed
                }
            } catch is CancellationError {
                return .recoveryPending
            } catch {
                if var current = records[workspaceID] {
                    current.health = .degradedReadOnly(
                        reason: "workspace_persistence_rebase_failed"
                    )
                    records[workspaceID] = current
                    publish(
                        kind: .degraded,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: current.revisions,
                        diagnostic: "workspace_persistence_rebase_failed"
                    )
                }
                return .failed
            }
        }
        return .recoveryPending
    }

    private func replayCapturedWorkingDocument(
        workspaceID: UUID,
        localDocument: DomainWorkspaceDocument
    ) async -> DirtyExternalRebaseResult {
        guard localDocument.workspaceID == workspaceID,
              var record = records[workspaceID],
              record.health.acceptsMutations
        else { return .failed }
        guard record.document.contentDigest != localDocument.contentDigest else {
            return .applied
        }

        let before = record.revisions
        let nextWorking = before.workingRevision &+ 1
        let revisions = DomainRevisionState(
            workingRevision: nextWorking,
            savedRevision: before.savedRevision,
            dirtyRevision: nextWorking
        )
        let contextUpdate = Self.updatedContextRevisions(
            previousDocument: record.document,
            nextDocument: localDocument,
            previousRevisions: record.contextRevisions,
            workspaceRevision: revisions
        )
        do {
            let persisted = try await persistence.persistWorking(
                document: localDocument,
                expectedRevision: before.workingRevision,
                newRevision: revisions,
                contextRevisions: contextUpdate.revisions,
                contextTombstones: record.contextTombstones.merging(
                    contextUpdate.tombstones
                ) { _, new in new },
                operations: record.operations,
                now: Date()
            )
            catalogRevision = max(catalogRevision, persisted.catalogRevision)
            record.document = localDocument
            record.revisions = persisted.journal.revisions
            record.contextRevisions = persisted.journal.contextRevisions
            record.contextTombstones = persisted.journal.contextTombstones
            record.operations = persisted.journal.operations
            record.operationIndex.replace(with: persisted.journal.operations)
            record.health = .writable
            record.externalDocument = nil
            records[workspaceID] = record
            readRegistrations.removeValue(forKey: workspaceID)
            publish(
                kind: .workingStateCommitted,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: nil,
                revisions: record.revisions,
                diagnostic: "working_document_replayed_after_save_revision_race"
            )
            return .applied
        } catch let error as DomainPersistenceError {
            if case .stateConflict = error {
                await refreshAfterCASConflict(
                    workspaceID: workspaceID,
                    fileURL: localDocument.fileURL
                )
                return .recoveryPending
            }
            if case .cancelled = error { return .recoveryPending }
            if var current = records[workspaceID] {
                current.health = .degradedReadOnly(
                    reason: "workspace_persistence_replay_failed"
                )
                records[workspaceID] = current
                publish(
                    kind: .degraded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: current.revisions,
                    diagnostic: "workspace_persistence_replay_failed"
                )
            }
            return .failed
        } catch is CancellationError {
            return .recoveryPending
        } catch {
            if var current = records[workspaceID] {
                current.health = .degradedReadOnly(
                    reason: "workspace_persistence_replay_failed"
                )
                records[workspaceID] = current
                publish(
                    kind: .degraded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: current.revisions,
                    diagnostic: "workspace_persistence_replay_failed"
                )
            }
            return .failed
        }
    }

    private func reconcileExternalDocument(
        workspaceID: UUID,
        externalDocument: DomainWorkspaceDocument,
        fileMetadata: DomainFileMetadata
    ) async -> DirtyExternalRebaseResult {
        for attempt in 0 ..< Self.maximumCASRecoveryAttempts {
            guard var record = records[workspaceID], record.health.acceptsMutations else {
                return .failed
            }
            if record.revisions.dirtyRevision != nil {
                return await rebaseDirtyWorkingDocument(
                    workspaceID: workspaceID,
                    localDocument: record.document,
                    externalDocument: externalDocument,
                    fileMetadata: fileMetadata
                )
            }

            let before = record.revisions
            let next = before.workingRevision &+ 1
            let revisions = DomainRevisionState(
                workingRevision: next,
                savedRevision: next,
                dirtyRevision: nil
            )
            let contextUpdate = Self.updatedContextRevisions(
                previousDocument: record.document,
                nextDocument: externalDocument,
                previousRevisions: record.contextRevisions,
                workspaceRevision: revisions
            )
            do {
                let persisted = try await persistence.persistExternalReload(
                    document: externalDocument,
                    expectedRevision: before.workingRevision,
                    newRevision: next,
                    contextRevisions: contextUpdate.revisions,
                    contextTombstones: record.contextTombstones.merging(
                        contextUpdate.tombstones
                    ) { _, new in new },
                    operations: record.operations,
                    now: Date()
                )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
                record.document = externalDocument
                record.savedDigest = persisted.journal.savedDigest
                record.revisions = persisted.journal.revisions
                record.contextRevisions = persisted.journal.contextRevisions
                record.contextTombstones = persisted.journal.contextTombstones
                record.operations = persisted.journal.operations
                record.operationIndex.replace(with: persisted.journal.operations)
                record.health = .writable
                record.externalDocument = nil
                record.fileMetadata = fileMetadata
                records[workspaceID] = record
                readRegistrations.removeValue(forKey: workspaceID)
                publish(
                    kind: .externalReloaded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: record.revisions,
                    diagnostic: attempt == 0 ? nil : "external_reload_revision_replayed"
                )
                return .applied
            } catch let error as DomainPersistenceError {
                switch error {
                case .stateConflict:
                    await refreshAfterCASConflict(
                        workspaceID: workspaceID,
                        fileURL: externalDocument.fileURL
                    )
                    if Task.isCancelled { return .recoveryPending }
                    if attempt + 1 < Self.maximumCASRecoveryAttempts { continue }
                    return .recoveryPending
                case .cancelled:
                    return .recoveryPending
                default:
                    if var current = records[workspaceID] {
                        current.health = .degradedReadOnly(
                            reason: "workspace_external_reload_persistence_failed"
                        )
                        records[workspaceID] = current
                        publish(
                            kind: .degraded,
                            workspaceID: workspaceID,
                            contextID: nil,
                            operationID: nil,
                            revisions: current.revisions,
                            diagnostic: "workspace_external_reload_persistence_failed"
                        )
                    }
                    return .failed
                }
            } catch is CancellationError {
                return .recoveryPending
            } catch {
                if var current = records[workspaceID] {
                    current.health = .degradedReadOnly(
                        reason: "workspace_external_reload_persistence_failed"
                    )
                    records[workspaceID] = current
                    publish(
                        kind: .degraded,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: current.revisions,
                        diagnostic: "workspace_external_reload_persistence_failed"
                    )
                }
                return .failed
            }
        }
        return .recoveryPending
    }

    private func createWorkspace(
        _ document: DomainWorkspaceDocument,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String
    ) async -> DomainCommandOutcome {
        await acquireCatalogMutation()
        defer { releaseCatalogMutation() }
        if let recorded = await recordedOutcome(for: envelope, fingerprint: fingerprint) {
            return recorded
        }
        if let expected = envelope.expectedCatalogRevision, expected != catalogRevision {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "catalog_revision_mismatch"
            )
        }
        if let existing = records[document.workspaceID] {
            if existing.document.contentDigest == document.contentDigest {
                return await unchangedOutcome(envelope, record: existing)
            }
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "workspace_already_exists"
            )
        }
        guard envelope.expectedWorkspaceRevision == nil || envelope.expectedWorkspaceRevision == 0 else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "workspace_does_not_exist_at_expected_revision"
            )
        }
        let revisions = DomainRevisionState(
            workingRevision: 1,
            savedRevision: 1,
            dirtyRevision: nil
        )
        let contextRevisions = Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
            ($0.identity.contextID, revisions)
        })
        let provisional = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: nil,
            after: revisions,
            catalogRevision: catalogRevision &+ 1,
            resultingDigest: document.contentDigest
        )
        let recorded = DomainRecordedOperation(
            fingerprint: fingerprint,
            recordedAt: Date(),
            outcome: provisional
        )
        do {
            let persisted = try await persistence.persistCreated(
                document: document,
                expectedCatalogRevision: envelope.expectedCatalogRevision ?? catalogRevision,
                operationID: envelope.operationID,
                contextRevisions: contextRevisions,
                operation: recorded,
                now: recorded.recordedAt
            )
            catalogRevision = persisted.catalogRevision
            let record = WorkspaceRecord(
                document: document,
                savedDigest: persisted.journal.savedDigest,
                revisions: persisted.journal.revisions,
                contextRevisions: persisted.journal.contextRevisions,
                contextTombstones: persisted.journal.contextTombstones,
                operations: persisted.journal.operations,
                operationIndex: BoundedDomainOperationIndex(
                    capacity: Self.maximumWorkspaceOperations,
                    operations: persisted.journal.operations
                ),
                health: .writable,
                externalDocument: nil,
                fileMetadata: .missing
            )
            records[document.workspaceID] = record
            globalOperations.insert(recorded)
            let outcome = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .applied,
                before: nil,
                after: record.revisions,
                catalogRevision: catalogRevision,
                resultingDigest: document.contentDigest,
                workspace: makeSnapshot(record)
            )
            publish(
                kind: .workspaceCreated,
                workspaceID: document.workspaceID,
                contextID: nil,
                operationID: envelope.operationID,
                origin: envelope.origin,
                revisions: record.revisions,
                diagnostic: nil
            )
            recordMetric(envelope: envelope, outcome: outcome, byteCount: document.documentBytes.count)
            return outcome
        } catch let error as DomainPersistenceError {
            if case .stateConflict = error {
                await refreshAfterCASConflict(
                    workspaceID: document.workspaceID,
                    fileURL: document.fileURL
                )
                return DomainCommandOutcome(
                    operationID: envelope.operationID,
                    disposition: .conflict,
                    before: nil,
                    after: records[document.workspaceID]?.revisions,
                    catalogRevision: catalogRevision,
                    resultingDigest: records[document.workspaceID]?.document.contentDigest,
                    errorCode: .stateConflict,
                    diagnostic: "durable_create_conflict",
                    workspace: records[document.workspaceID].map(makeSnapshot)
                )
            }
            return persistenceFailureOutcome(envelope, record: nil, error: error)
        } catch {
            return persistenceFailureOutcome(envelope, record: nil, error: error)
        }
    }

    private func deleteWorkspace(
        _ workspaceID: UUID,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String
    ) async -> DomainCommandOutcome {
        await acquireCatalogMutation()
        defer { releaseCatalogMutation() }
        if let recorded = await recordedOutcome(for: envelope, fingerprint: fingerprint) {
            return recorded
        }
        if let expected = envelope.expectedCatalogRevision, expected != catalogRevision {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "catalog_revision_mismatch"
            )
        }
        guard let record = records[workspaceID] else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .invalid,
                errorCode: .workspaceUnavailable,
                diagnostic: "workspace_not_found"
            )
        }
        guard record.health.acceptsMutations else {
            return healthRejectionOutcome(envelope, record: record)
        }
        if let expected = envelope.expectedWorkspaceRevision,
           expected != record.revisions.workingRevision
        {
            return conflictOutcome(envelope, record: record, diagnostic: "workspace_revision_mismatch")
        }
        let provisional = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: record.revisions,
            after: nil,
            catalogRevision: catalogRevision &+ 1,
            resultingDigest: nil
        )
        let operation = DomainRecordedOperation(
            fingerprint: fingerprint,
            recordedAt: Date(),
            outcome: provisional
        )
        do {
            let deleted = try await persistence.persistDeleted(
                document: record.document,
                expectedWorkspaceRevision: record.revisions.workingRevision,
                expectedCatalogRevision: envelope.expectedCatalogRevision ?? catalogRevision,
                operation: operation,
                now: operation.recordedAt
            )
            records.removeValue(forKey: workspaceID)
            globalOperations.insert(operation)
            catalogRevision = deleted.catalogRevision
            let outcome = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .applied,
                before: record.revisions,
                after: nil,
                catalogRevision: catalogRevision,
                resultingDigest: nil
            )
            publish(
                kind: .workspaceDeleted,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: envelope.operationID,
                origin: envelope.origin,
                revisions: nil,
                diagnostic: nil
            )
            recordMetric(envelope: envelope, outcome: outcome, byteCount: 0)
            return outcome
        } catch let error as DomainPersistenceError {
            if case .stateConflict = error {
                await refreshAfterCASConflict(
                    workspaceID: workspaceID,
                    fileURL: record.document.fileURL
                )
                return DomainCommandOutcome(
                    operationID: envelope.operationID,
                    disposition: .conflict,
                    before: record.revisions,
                    after: records[workspaceID]?.revisions,
                    catalogRevision: catalogRevision,
                    resultingDigest: records[workspaceID]?.document.contentDigest,
                    errorCode: .stateConflict,
                    diagnostic: "durable_delete_conflict",
                    workspace: records[workspaceID].map(makeSnapshot)
                )
            }
            return persistenceFailureOutcome(envelope, record: record, error: error)
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
    }

    private func replaceWorkingDocument(
        _ document: DomainWorkspaceDocument,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String
    ) async -> DomainCommandOutcome {
        guard document.workspaceID == envelope.workspaceID else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .invalid,
                errorCode: .invalidDocument,
                diagnostic: "workspace_identity_mismatch"
            )
        }

        var isDurableReplay = false
        while let current = records[document.workspaceID] {
            var record = current
            guard record.health.acceptsMutations else {
                return healthRejectionOutcome(envelope, record: record)
            }
            if !isDurableReplay,
               let expected = envelope.expectedWorkspaceRevision,
               expected != record.revisions.workingRevision
            {
                return conflictOutcome(envelope, record: record, diagnostic: "workspace_revision_mismatch")
            }
            let changedContextIDs = Self.changedContextIDs(from: record.document, to: document)
            if let expectedContext = envelope.expectedContextRevision {
                guard changedContextIDs.count == 1,
                      let changedContextID = changedContextIDs.first
                else {
                    return conflictOutcome(
                        envelope,
                        record: record,
                        diagnostic: isDurableReplay
                            ? "context_revision_scope_mismatch_after_refresh"
                            : "context_revision_scope_mismatch"
                    )
                }
                if !isDurableReplay,
                   expectedContext != record.contextRevisions[changedContextID]?.workingRevision
                {
                    return conflictOutcome(envelope, record: record, diagnostic: "context_revision_mismatch")
                }
            }
            guard record.document.contentDigest != document.contentDigest else {
                return await unchangedOutcome(envelope, record: record)
            }

            let changedContextID = changedContextIDs.count == 1 ? changedContextIDs.first : nil
            let before = record.revisions
            let nextWorking = before.workingRevision &+ 1
            let revisions = DomainRevisionState(
                workingRevision: nextWorking,
                savedRevision: before.savedRevision,
                dirtyRevision: nextWorking
            )
            let contextUpdate = Self.updatedContextRevisions(
                previousDocument: record.document,
                nextDocument: document,
                previousRevisions: record.contextRevisions,
                workspaceRevision: revisions
            )
            let provisional = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .applied,
                before: before,
                after: revisions,
                catalogRevision: catalogRevision,
                resultingDigest: document.contentDigest,
                workspace: nil
            )
            let recorded = DomainRecordedOperation(fingerprint: fingerprint, recordedAt: Date(), outcome: provisional)
            let operations = record.operations + [recorded]
            let persisted: DomainPersistenceWorkingCommit
            do {
                persisted = try await persistence.persistWorking(
                    document: document,
                    expectedRevision: before.workingRevision,
                    newRevision: revisions,
                    contextRevisions: contextUpdate.revisions,
                    contextTombstones: record.contextTombstones.merging(contextUpdate.tombstones) { _, new in new },
                    operations: operations,
                    now: recorded.recordedAt
                )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
            } catch let error as DomainPersistenceError {
                if case .stateConflict = error {
                    await refreshAfterCASConflict(
                        workspaceID: document.workspaceID,
                        fileURL: document.fileURL
                    )
                    if let replayed = await recordedOutcome(
                        for: envelope,
                        fingerprint: fingerprint
                    ) {
                        return replayed
                    }
                    guard !Task.isCancelled else {
                        return persistenceFailureOutcome(
                            envelope,
                            record: records[document.workspaceID] ?? record,
                            error: DomainPersistenceError.cancelled
                        )
                    }
                    if !isDurableReplay {
                        isDurableReplay = true
                        continue
                    }
                    let refreshed = records[document.workspaceID]
                    return DomainCommandOutcome(
                        operationID: envelope.operationID,
                        disposition: .conflict,
                        before: before,
                        after: refreshed?.revisions,
                        catalogRevision: catalogRevision,
                        resultingDigest: refreshed?.document.contentDigest,
                        errorCode: .stateConflict,
                        diagnostic: "durable_workspace_revision_mismatch_after_replay",
                        workspace: refreshed.map(makeSnapshot)
                    )
                }
                return persistenceFailureOutcome(envelope, record: record, error: error)
            } catch {
                return persistenceFailureOutcome(envelope, record: record, error: error)
            }
            record.document = document
            record.revisions = persisted.journal.revisions
            record.contextRevisions = persisted.journal.contextRevisions
            record.contextTombstones = persisted.journal.contextTombstones
            record.operations = persisted.journal.operations
            record.operationIndex.replace(with: persisted.journal.operations)
            records[document.workspaceID] = record
            globalOperations.insert(recorded)
            let applied = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .applied,
                before: before,
                after: record.revisions,
                catalogRevision: catalogRevision,
                resultingDigest: document.contentDigest,
                workspace: makeSnapshot(record)
            )
            publish(
                kind: .workingStateCommitted,
                workspaceID: document.workspaceID,
                contextID: changedContextID,
                operationID: envelope.operationID,
                origin: envelope.origin,
                revisions: record.revisions,
                diagnostic: isDurableReplay ? "durable_workspace_revision_replayed" : nil
            )
            recordMetric(envelope: envelope, outcome: applied, byteCount: document.documentBytes.count)
            return applied
        }

        return recordTransientOutcome(
            envelope: envelope,
            disposition: .invalid,
            errorCode: .workspaceUnavailable,
            diagnostic: "workspace_requires_explicit_create_command"
        )
    }

    private func saveWorkspace(
        _ workspaceID: UUID,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        validateExpectedRevision: Bool = true,
        allowsCASRecovery: Bool = true,
        allowsExternalRecovery: Bool = true
    ) async -> DomainCommandOutcome {
        guard var record = records[workspaceID] else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .invalid,
                errorCode: .workspaceUnavailable,
                diagnostic: "workspace_not_found"
            )
        }
        guard record.health.acceptsMutations else {
            return healthRejectionOutcome(envelope, record: record)
        }
        if validateExpectedRevision,
           let expected = envelope.expectedWorkspaceRevision,
           expected != record.revisions.workingRevision
        {
            return conflictOutcome(envelope, record: record, diagnostic: "workspace_revision_mismatch")
        }
        guard record.revisions.dirtyRevision != nil else {
            return await unchangedOutcome(envelope, record: record)
        }
        let before = record.revisions
        let after = DomainRevisionState(
            workingRevision: before.workingRevision,
            savedRevision: before.workingRevision,
            dirtyRevision: nil
        )
        let provisional = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: after,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest
        )
        let recorded = DomainRecordedOperation(fingerprint: fingerprint, recordedAt: Date(), outcome: provisional)
        let operations = record.operations + [recorded]
        do {
            let saved = try await persistence.persistSaved(
                document: record.document,
                expectedWorkingRevision: before.workingRevision,
                operationID: envelope.operationID,
                contextRevisions: record.contextRevisions,
                contextTombstones: record.contextTombstones,
                operations: operations,
                now: recorded.recordedAt
            )
            catalogRevision = max(catalogRevision, saved.catalogRevision)
            record.savedDigest = saved.journal.savedDigest
            record.revisions = saved.journal.revisions
            record.contextRevisions = saved.journal.contextRevisions
            record.operations = saved.journal.operations
            record.operationIndex.replace(with: saved.journal.operations)
            records[workspaceID] = record
            globalOperations.insert(recorded)
        } catch let error as DomainPersistenceError {
            if case .stateConflict = error {
                await refreshAfterCASConflict(
                    workspaceID: workspaceID,
                    fileURL: record.document.fileURL
                )
                guard allowsCASRecovery else {
                    return conflictOutcome(
                        envelope,
                        record: records[workspaceID] ?? record,
                        diagnostic: "durable_save_revision_mismatch_after_replay"
                    )
                }
                switch await replayCapturedWorkingDocument(
                    workspaceID: workspaceID,
                    localDocument: record.document
                ) {
                case .applied:
                    return await saveWorkspace(
                        workspaceID,
                        envelope: envelope,
                        fingerprint: fingerprint,
                        validateExpectedRevision: false,
                        allowsCASRecovery: false,
                        allowsExternalRecovery: allowsExternalRecovery
                    )
                case .recoveryPending:
                    return conflictOutcome(
                        envelope,
                        record: records[workspaceID] ?? record,
                        diagnostic: "durable_save_revision_replay_pending"
                    )
                case .failed:
                    return healthRejectionOutcome(
                        envelope,
                        record: records[workspaceID] ?? record
                    )
                }
            }
            guard case .externalDocumentConflict = error else {
                return persistenceFailureOutcome(envelope, record: record, error: error)
            }
            guard allowsExternalRecovery else {
                return conflictOutcome(
                    envelope,
                    record: record,
                    diagnostic: "external_document_changed_during_recovered_save"
                )
            }

            let observedRevisions = record.revisions
            let observedSavedDigest = record.savedDigest
            let observedMetadata = record.fileMetadata
            let external = await persistence.externalDocument(
                for: makeSnapshot(record),
                savedDigest: observedSavedDigest,
                knownMetadata: observedMetadata
            )
            guard var current = records[workspaceID],
                  current.revisions == observedRevisions,
                  current.savedDigest == observedSavedDigest,
                  current.fileMetadata == observedMetadata
            else {
                return conflictOutcome(
                    envelope,
                    record: records[workspaceID] ?? record,
                    diagnostic: "external_document_changed_during_save_recovery"
                )
            }

            switch external {
            case let .changed(document, metadata):
                switch await rebaseDirtyWorkingDocument(
                    workspaceID: workspaceID,
                    localDocument: record.document,
                    externalDocument: document,
                    fileMetadata: metadata
                ) {
                case .applied:
                    return await saveWorkspace(
                        workspaceID,
                        envelope: envelope,
                        fingerprint: fingerprint,
                        validateExpectedRevision: false,
                        allowsCASRecovery: allowsCASRecovery,
                        allowsExternalRecovery: false
                    )
                case .recoveryPending:
                    return conflictOutcome(
                        envelope,
                        record: records[workspaceID] ?? record,
                        diagnostic: "external_document_rebase_pending"
                    )
                case .failed:
                    return healthRejectionOutcome(
                        envelope,
                        record: records[workspaceID] ?? record
                    )
                }
            case let .invalid(metadata):
                current.health = .degradedReadOnly(reason: "external_workspace_decode_failed")
                current.externalDocument = nil
                current.fileMetadata = metadata
                records[workspaceID] = current
                publish(
                    kind: .degraded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: envelope.operationID,
                    origin: envelope.origin,
                    revisions: current.revisions,
                    diagnostic: "external_workspace_decode_failed"
                )
                return healthRejectionOutcome(envelope, record: current)
            case let .unchanged(metadata), let .missing(metadata):
                current.fileMetadata = metadata
                records[workspaceID] = current
                return conflictOutcome(
                    envelope,
                    record: current,
                    diagnostic: "external_document_changed_during_save_recovery"
                )
            case .cancelled:
                return persistenceFailureOutcome(
                    envelope,
                    record: current,
                    error: DomainPersistenceError.cancelled
                )
            }
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
        let applied = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            workspace: makeSnapshot(record)
        )
        publish(
            kind: .savedDocumentCommitted,
            workspaceID: workspaceID,
            contextID: nil,
            operationID: envelope.operationID,
            origin: envelope.origin,
            revisions: record.revisions,
            diagnostic: allowsExternalRecovery ? nil : "external_document_rebased_and_saved"
        )
        recordMetric(envelope: envelope, outcome: applied, byteCount: record.document.documentBytes.count)
        return applied
    }

    private func resolveExternalConflict(
        _ workspaceID: UUID,
        acceptExternal: Bool,
        protectedAgentIdentities: [DomainProtectedAgentIdentity],
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String
    ) async -> DomainCommandOutcome {
        guard var record = records[workspaceID],
              case .externalConflict = record.health,
              let external = record.externalDocument
        else {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .invalid,
                errorCode: .workspaceUnavailable,
                diagnostic: "workspace_has_no_external_conflict"
            )
        }
        let before = record.revisions
        if let expected = envelope.expectedWorkspaceRevision,
           expected != before.workingRevision
        {
            return conflictOutcome(envelope, record: record, diagnostic: "workspace_revision_mismatch")
        }
        if acceptExternal,
           let diagnostic = Self.protectedAgentIdentityConflict(
               local: record.document,
               external: external,
               callerClaims: protectedAgentIdentities
           )
        {
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .conflict,
                errorCode: .protectedAgentIdentityConflict,
                diagnostic: diagnostic
            )
        }
        let now = Date()
        let after = acceptExternal
            ? DomainRevisionState(
                workingRevision: before.workingRevision &+ 1,
                savedRevision: before.workingRevision &+ 1,
                dirtyRevision: nil
            )
            : before
        let resultingDocument = acceptExternal ? external : record.document
        let provisional = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: after,
            catalogRevision: catalogRevision,
            resultingDigest: resultingDocument.contentDigest
        )
        let operation = DomainRecordedOperation(fingerprint: fingerprint, recordedAt: now, outcome: provisional)
        let operations = record.operations + [operation]
        do {
            if acceptExternal {
                let contextRevisions = Dictionary(uniqueKeysWithValues: external.metadata.contexts.map {
                    ($0.identity.contextID, after)
                })
                let persisted = try await persistence.persistExternalReload(
                    document: external,
                    expectedRevision: before.workingRevision,
                    newRevision: after.workingRevision,
                    contextRevisions: contextRevisions,
                    contextTombstones: record.contextTombstones,
                    operations: operations,
                    now: now
                )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
                record.document = external
                record.savedDigest = persisted.journal.savedDigest
                record.revisions = persisted.journal.revisions
                record.contextRevisions = persisted.journal.contextRevisions
                record.operations = persisted.journal.operations
                record.operationIndex.replace(with: persisted.journal.operations)
            } else {
                let persisted = try await persistence.persistConflictRebase(
                    document: record.document,
                    externalSavedDigest: external.contentDigest,
                    expectedRevisions: before,
                    newRevisions: after,
                    contextRevisions: record.contextRevisions,
                    contextTombstones: record.contextTombstones,
                    operations: operations,
                    now: now
                )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
                record.savedDigest = persisted.journal.savedDigest
                record.revisions = persisted.journal.revisions
                record.operations = persisted.journal.operations
                record.operationIndex.replace(with: persisted.journal.operations)
            }
        } catch let error as DomainPersistenceError {
            if case .stateConflict = error {
                await refreshAfterCASConflict(
                    workspaceID: workspaceID,
                    fileURL: record.document.fileURL
                )
                let refreshed = records[workspaceID]
                return DomainCommandOutcome(
                    operationID: envelope.operationID,
                    disposition: .conflict,
                    before: before,
                    after: refreshed?.revisions,
                    catalogRevision: catalogRevision,
                    resultingDigest: refreshed?.document.contentDigest,
                    errorCode: .stateConflict,
                    diagnostic: "durable_workspace_revision_mismatch",
                    workspace: refreshed.map(makeSnapshot)
                )
            }
            return persistenceFailureOutcome(envelope, record: record, error: error)
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
        globalOperations.insert(operation)
        record.health = .writable
        record.externalDocument = nil
        records[workspaceID] = record
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            workspace: makeSnapshot(record)
        )
        publish(
            kind: acceptExternal ? .externalReloaded : .workingStateCommitted,
            workspaceID: workspaceID,
            contextID: nil,
            operationID: envelope.operationID,
            origin: envelope.origin,
            revisions: record.revisions,
            diagnostic: acceptExternal ? "external_conflict_accepted" : "local_conflict_rebased"
        )
        return outcome
    }

    private func makeSnapshot(_ record: WorkspaceRecord) -> DomainWorkspaceSnapshot {
        DomainWorkspaceSnapshot(
            document: record.document,
            revisions: record.revisions,
            health: record.health,
            contexts: record.document.metadata.contexts.map { metadata in
                DomainContextSnapshot(
                    metadata: metadata,
                    revisions: record.contextRevisions[metadata.identity.contextID] ?? record.revisions,
                    health: record.health
                )
            }
        )
    }

    private func publish(
        kind: DomainWorkspaceEventKind,
        workspaceID: UUID?,
        contextID: UUID?,
        operationID: UUID?,
        origin: DomainCommandOrigin? = nil,
        revisions: DomainRevisionState?,
        diagnostic: String?
    ) {
        publicationSequence &+= 1
        let event = DomainWorkspaceEvent(
            runtimeID: identity.runtimeID,
            sequence: publicationSequence,
            catalogRevision: catalogRevision,
            kind: kind,
            workspaceID: workspaceID,
            contextID: contextID,
            operationID: operationID,
            origin: origin,
            revisions: revisions,
            timestamp: Date(),
            diagnostic: diagnostic
        )
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    private func acquireCatalogMutation() async {
        guard catalogMutationInProgress else {
            catalogMutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            catalogMutationWaiters.append(continuation)
        }
    }

    private func releaseCatalogMutation() {
        guard !catalogMutationWaiters.isEmpty else {
            catalogMutationInProgress = false
            return
        }
        catalogMutationWaiters.removeFirst().resume()
    }

    private func refreshAfterCASConflict(workspaceID: UUID, fileURL: URL) async {
        let previous = records[workspaceID]
        guard let refreshed = await persistence.refreshWorkspace(
            workspaceID: workspaceID,
            fallbackFileURL: fileURL
        ) else { return }
        health = refreshed.health
        catalogRevision = max(catalogRevision, refreshed.catalogRevision)
        if refreshed.workspaceIsDeleted {
            records.removeValue(forKey: workspaceID)
            unavailableWorkspaces.removeValue(forKey: workspaceID)
            return
        }
        guard let workspace = refreshed.workspace else {
            if var previous {
                previous.health = .degradedReadOnly(reason: "workspace_document_unavailable")
                records[workspaceID] = previous
            }
            return
        }
        for operation in workspace.operations {
            globalOperations.insert(operation)
        }
        let canPreserveConflict = previous?.document.contentDigest == workspace.document.contentDigest
            && previous?.revisions == workspace.revisions
        let priorConflictDocument: DomainWorkspaceDocument? = if canPreserveConflict,
                                                                 case .externalConflict = previous?.health
        {
            previous?.externalDocument
        } else {
            nil
        }
        records[workspaceID] = WorkspaceRecord(
            document: workspace.document,
            savedDigest: workspace.savedDigest,
            revisions: workspace.revisions,
            contextRevisions: workspace.contextRevisions,
            contextTombstones: workspace.contextTombstones,
            operations: workspace.operations,
            operationIndex: BoundedDomainOperationIndex(
                capacity: Self.maximumWorkspaceOperations,
                operations: workspace.operations
            ),
            health: priorConflictDocument == nil ? workspace.health : previous?.health ?? workspace.health,
            externalDocument: priorConflictDocument,
            fileMetadata: workspace.fileMetadata
        )
        unavailableWorkspaces.removeValue(forKey: workspaceID)
    }

    private func healthRejectionOutcome(
        _ envelope: DomainWorkspaceCommandEnvelope,
        record: WorkspaceRecord
    ) -> DomainCommandOutcome {
        let disposition: DomainCommandDisposition
        let errorCode: DomainCommandErrorCode
        let diagnostic: String
        switch record.health {
        case .writable:
            return recordTransientOutcome(
                envelope: envelope,
                disposition: .failed,
                errorCode: .persistenceFailure,
                diagnostic: "unexpected_writable_health_rejection"
            )
        case let .externalConflict(reason):
            disposition = .conflict
            errorCode = .workspaceExternalConflict
            diagnostic = reason
        case let .degradedReadOnly(reason):
            disposition = .readOnly
            errorCode = .workspaceReadOnlyDegraded
            diagnostic = reason
        case .removed:
            disposition = .invalid
            errorCode = .workspaceUnavailable
            diagnostic = "workspace_removed"
        }
        return recordTransientOutcome(
            envelope: envelope,
            disposition: disposition,
            errorCode: errorCode,
            diagnostic: diagnostic
        )
    }

    private static func protectedAgentIdentityConflict(
        local: DomainWorkspaceDocument,
        external: DomainWorkspaceDocument,
        callerClaims: [DomainProtectedAgentIdentity]
    ) -> String? {
        var protectedByTabID = Dictionary(
            uniqueKeysWithValues: local.metadata.agentIdentityClaims
                .filter(\.requiresProtection)
                .map { ($0.tabID, $0) }
        )
        for callerClaim in callerClaims where callerClaim.requiresProtection {
            if let existing = protectedByTabID[callerClaim.tabID] {
                guard existing.location == callerClaim.location else {
                    return "protected_agent_identity_precondition_mismatch"
                }
                if let existingSessionID = existing.activeAgentSessionID,
                   let callerSessionID = callerClaim.activeAgentSessionID,
                   existingSessionID != callerSessionID
                {
                    return "protected_agent_identity_precondition_mismatch"
                }
                protectedByTabID[callerClaim.tabID] = DomainProtectedAgentIdentity(
                    tabID: callerClaim.tabID,
                    location: existing.location,
                    activeAgentSessionID: callerClaim.activeAgentSessionID ?? existing.activeAgentSessionID,
                    isPinned: existing.isPinned || callerClaim.isPinned
                )
            } else {
                protectedByTabID[callerClaim.tabID] = callerClaim
            }
        }

        let externalByTabID = Dictionary(
            uniqueKeysWithValues: external.metadata.agentIdentityClaims.map { ($0.tabID, $0) }
        )
        let sessionCounts = Dictionary(
            grouping: external.metadata.agentIdentityClaims.compactMap(\.activeAgentSessionID),
            by: { $0 }
        ).mapValues(\.count)
        for claim in protectedByTabID.values {
            guard let candidate = externalByTabID[claim.tabID] else {
                return "protected_agent_identity_missing"
            }
            guard candidate.location == claim.location else {
                return "protected_agent_identity_location_changed"
            }
            guard candidate.activeAgentSessionID == claim.activeAgentSessionID else {
                return "protected_agent_identity_rebound"
            }
            guard !claim.isPinned || candidate.isPinned else {
                return "protected_agent_identity_unpinned"
            }
            if let sessionID = claim.activeAgentSessionID,
               sessionCounts[sessionID] != 1
            {
                return "protected_agent_identity_duplicated"
            }
        }
        return nil
    }

    private func conflictOutcome(
        _ envelope: DomainWorkspaceCommandEnvelope,
        record: WorkspaceRecord,
        diagnostic: String
    ) -> DomainCommandOutcome {
        DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .conflict,
            before: record.revisions,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            errorCode: .stateConflict,
            diagnostic: diagnostic,
            workspace: makeSnapshot(record)
        )
    }

    private func unchangedOutcome(
        _ envelope: DomainWorkspaceCommandEnvelope,
        record original: WorkspaceRecord
    ) async -> DomainCommandOutcome {
        var record = original
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .unchanged,
            before: record.revisions,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            workspace: makeSnapshot(record)
        )
        let operation = DomainRecordedOperation(
            fingerprint: envelope.fingerprint,
            recordedAt: Date(),
            outcome: outcome
        )
        do {
            let persisted = try await persistence.persistUnchanged(
                document: record.document,
                expectedRevision: record.revisions.workingRevision,
                operation: operation,
                now: operation.recordedAt
            )
            catalogRevision = max(catalogRevision, persisted.catalogRevision)
            record.operations = persisted.journal.operations
            record.operationIndex.replace(with: persisted.journal.operations)
            records[record.document.workspaceID] = record
            globalOperations.insert(operation)
            return outcome
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
    }

    private func collisionOutcome(
        _ operationID: UUID,
        workspace: DomainWorkspaceSnapshot?
    ) -> DomainCommandOutcome {
        DomainCommandOutcome(
            operationID: operationID,
            disposition: .invalid,
            before: workspace?.revisions,
            after: workspace?.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: workspace?.document.contentDigest,
            errorCode: .operationIDCollision,
            diagnostic: "operation_id_reused_with_different_command",
            workspace: workspace
        )
    }

    private func persistenceFailureOutcome(
        _ envelope: DomainWorkspaceCommandEnvelope,
        record: WorkspaceRecord?,
        error: Error
    ) -> DomainCommandOutcome {
        let code: DomainCommandErrorCode = switch error {
        case DomainPersistenceError.lockTimedOut: .lockTimedOut
        case DomainPersistenceError.cancelled: .cancelled
        default: .persistenceFailure
        }
        return DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .failed,
            before: record?.revisions,
            after: record?.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record?.document.contentDigest,
            errorCode: code,
            diagnostic: String(describing: error),
            workspace: record.map(makeSnapshot)
        )
    }

    private func recordTransientOutcome(
        envelope: DomainWorkspaceCommandEnvelope,
        disposition: DomainCommandDisposition,
        errorCode: DomainCommandErrorCode,
        diagnostic: String
    ) -> DomainCommandOutcome {
        let workspace = envelope.workspaceID.flatMap(canonicalWorkspaceSnapshot)
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: disposition,
            before: workspace?.revisions,
            after: workspace?.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: workspace?.document.contentDigest,
            errorCode: errorCode,
            diagnostic: diagnostic,
            workspace: workspace
        )
        globalOperations.insert(DomainRecordedOperation(
            fingerprint: envelope.fingerprint,
            recordedAt: Date(),
            outcome: outcome
        ))
        return outcome
    }

    private func recordMetric(
        envelope: DomainWorkspaceCommandEnvelope,
        outcome: DomainCommandOutcome,
        byteCount: Int
    ) {
        metrics.record(DomainRuntimeMetric(
            phase: .commit,
            name: "EditFlow.DomainRuntime.Commit",
            dimensions: [
                "runtime_id": identity.runtimeID.uuidString,
                "runtime_generation": "\(identity.lifecycleGeneration)",
                "runtime_mode": identity.mode.rawValue,
                "operation_id": envelope.operationID.uuidString,
                "workspace_id": envelope.workspaceID?.uuidString ?? "none",
                "context_revision": envelope.expectedContextRevision.map(String.init) ?? "none",
                "catalog_revision": "\(outcome.catalogRevision)",
                "working_revision": outcome.after.map { "\($0.workingRevision)" } ?? "none",
                "saved_revision": outcome.after.map { "\($0.savedRevision)" } ?? "none",
                "dirty_revision": outcome.after?.dirtyRevision.map(String.init) ?? "none",
                "disposition": outcome.disposition.rawValue,
                "byte_count": "\(byteCount)"
            ]
        ))
    }

    private static func changedContextIDs(
        from previous: DomainWorkspaceDocument?,
        to next: DomainWorkspaceDocument
    ) -> Set<UUID> {
        guard let previous else { return [] }
        let old = Dictionary(uniqueKeysWithValues: previous.metadata.contexts.map {
            ($0.identity.contextID, $0.contentDigest)
        })
        let new = Dictionary(uniqueKeysWithValues: next.metadata.contexts.map {
            ($0.identity.contextID, $0.contentDigest)
        })
        return Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
    }

    private static func updatedContextRevisions(
        previousDocument: DomainWorkspaceDocument,
        nextDocument: DomainWorkspaceDocument,
        previousRevisions: [UUID: DomainRevisionState],
        workspaceRevision: DomainRevisionState
    ) -> (revisions: [UUID: DomainRevisionState], tombstones: [UUID: UInt64]) {
        let old = Dictionary(uniqueKeysWithValues: previousDocument.metadata.contexts.map {
            ($0.identity.contextID, $0.contentDigest)
        })
        let new = Dictionary(uniqueKeysWithValues: nextDocument.metadata.contexts.map {
            ($0.identity.contextID, $0.contentDigest)
        })
        var revisions: [UUID: DomainRevisionState] = [:]
        for (contextID, digest) in new {
            if old[contextID] == digest, let existing = previousRevisions[contextID] {
                revisions[contextID] = existing
            } else {
                let previous = previousRevisions[contextID] ?? .initial
                let nextWorking = previous.workingRevision &+ 1
                revisions[contextID] = DomainRevisionState(
                    workingRevision: nextWorking,
                    savedRevision: previous.savedRevision,
                    dirtyRevision: nextWorking
                )
            }
        }
        let tombstones = Dictionary(uniqueKeysWithValues: old.keys.filter { new[$0] == nil }.map {
            ($0, workspaceRevision.workingRevision)
        })
        return (revisions, tombstones)
    }
}

private extension DomainWorkspaceCommandEnvelope {
    var workspaceID: UUID? {
        switch command {
        case let .createWorkspace(document): document.workspaceID
        case let .replaceWorkingDocument(document): document.workspaceID
        case let .saveWorkspaceDocument(workspaceID): workspaceID
        case let .deleteWorkspace(workspaceID): workspaceID
            case let .resolveExternalConflict(workspaceID, _, _): workspaceID
        }
    }
}
