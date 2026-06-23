import Foundation
import RepoPromptCore

/// Next-launch rollback backend. It is constructed only when the immutable app-container
/// selection is `legacy`; Core mode never allocates this actor or its revision allocator.
actor LegacyWorkspaceSessionBackend: WorkspaceSessionCommandIngress {
    private let revisionAllocator = LegacyWorkspaceSelectionRevisionAllocator()

    nonisolated let sessionID: WorkspaceSessionID
    private let load: @Sendable () async throws -> WorkspaceSessionHydrationInput
    private let lifecycleOwner: WorkspaceSessionLifecycleOwner
    private let workspaceURL: @Sendable (WorkspaceModel) -> URL?
    private let indexURL: @Sendable () -> URL?
    private let close: @Sendable () async -> Void
    private let persistence = WorkspaceSessionPersistenceCoordinator()

    private var snapshot: WorkspaceSessionSnapshot?
    private var activationID: UUID?
    private var revisedSelections: [WorkspaceTabSelectionKey: StoredSelection] = [:]
    private var didHydrate = false
    private var didClose = false
    private var isShuttingDown = false
    private var observers: [UUID: AsyncStream<WorkspaceSessionSnapshot>.Continuation] = [:]
    private var cachedResults: [UUID: WorkspaceSessionCommandResult] = [:]
    private var cachedResultOrder: [UUID] = []
    private var hydrationTask: Task<WorkspaceSessionHydrationResult, Never>?
    private var inFlightCommands: [UUID: Task<WorkspaceSessionCommandResult, Never>] = [:]
    private var teardownTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0

    init(
        sessionID: WorkspaceSessionID = WorkspaceSessionID(),
        load: @escaping @Sendable () async throws -> WorkspaceSessionHydrationInput,
        lifecycleOwner: WorkspaceSessionLifecycleOwner,
        workspaceURL: @escaping @Sendable (WorkspaceModel) -> URL? = { _ in nil },
        indexURL: @escaping @Sendable () -> URL? = { nil },
        close: @escaping @Sendable () async -> Void = {}
    ) {
        self.sessionID = sessionID
        self.load = load
        self.lifecycleOwner = lifecycleOwner
        self.workspaceURL = workspaceURL
        self.indexURL = indexURL
        self.close = close
    }

    func hydrate() async -> WorkspaceSessionHydrationResult {
        if let hydrationTask { return await hydrationTask.value }
        guard !isShuttingDown else {
            return .failed(WorkspaceSessionFailure("session is closing"))
        }
        let task = Task<WorkspaceSessionHydrationResult, Never> { [weak self] in
            guard let self else { return .failed(WorkspaceSessionFailure("session was released")) }
            return await performHydration()
        }
        hydrationTask = task
        return await task.value
    }

    private func performHydration() async -> WorkspaceSessionHydrationResult {
        guard !didHydrate else { return .alreadyHydrated(snapshot) }
        didHydrate = true
        snapshot = WorkspaceSessionSnapshot(
            sessionID: sessionID,
            snapshotSequence: 1,
            stateGeneration: 0,
            workspaces: [],
            activeWorkspaceID: nil,
            selectionRevisions: [:],
            dirtyGenerations: [:],
            savedGenerations: [:],
            switchState: .idle,
            readiness: WorkspaceSessionReadiness(),
            availability: .hydrating
        )
        publish()
        do {
            let input = try await load()
            let activeID = input.activeWorkspaceID.flatMap { requested in
                input.workspaces.contains(where: { $0.id == requested }) ? requested : nil
            } ?? input.workspaces.first?.id
            lifecycleGeneration = 1
            let activeWorkspace = activeID.flatMap { id in input.workspaces.first(where: { $0.id == id }) }
            let lifecycleReadiness = try await lifecycleOwner.hydrate(
                workspace: activeWorkspace,
                generation: lifecycleGeneration
            )
            guard lifecycleReadiness.workspaceID == activeWorkspace?.id,
                  lifecycleReadiness.generation == lifecycleGeneration
            else { throw WorkspaceSessionFailure("legacy lifecycle returned stale readiness") }
            guard !isShuttingDown, !Task.isCancelled else {
                try? await lifecycleOwner.unload(generation: lifecycleGeneration)
                return .failed(WorkspaceSessionFailure("session hydration was cancelled"))
            }
            snapshot = WorkspaceSessionSnapshot(
                sessionID: sessionID,
                snapshotSequence: 2,
                stateGeneration: 1,
                workspaces: input.workspaces,
                activeWorkspaceID: activeID,
                selectionRevisions: [:],
                dirtyGenerations: Dictionary(uniqueKeysWithValues: input.workspaces.map { ($0.id, 0) }),
                savedGenerations: Dictionary(uniqueKeysWithValues: input.workspaces.map { ($0.id, 0) }),
                switchState: .idle,
                readiness: WorkspaceSessionReadiness(
                    generation: lifecycleReadiness.generation,
                    isReady: true,
                    catalogGeneration: lifecycleReadiness.catalogGeneration
                ),
                availability: .awaitingActivation
            )
            publish()
            return .awaitingFirstSnapshotApplication(snapshot!)
        } catch {
            if lifecycleGeneration > 0 {
                try? await lifecycleOwner.unload(generation: lifecycleGeneration)
            }
            snapshot = WorkspaceSessionSnapshot(
                sessionID: sessionID,
                snapshotSequence: 2,
                stateGeneration: 0,
                workspaces: [],
                activeWorkspaceID: nil,
                selectionRevisions: [:],
                dirtyGenerations: [:],
                savedGenerations: [:],
                switchState: .idle,
                readiness: WorkspaceSessionReadiness(unavailableReason: error.localizedDescription),
                availability: .failed(error.localizedDescription)
            )
            publish()
            return .failed(WorkspaceSessionFailure(error.localizedDescription))
        }
    }

    func activate(appliedSnapshotSequence: UInt64) -> WorkspaceSessionActivationResult {
        guard var snapshot, snapshot.availability == .awaitingActivation, snapshot.readiness.isReady else {
            return .notReady(snapshot?.availability ?? .created)
        }
        guard snapshot.snapshotSequence == appliedSnapshotSequence else {
            return .wrongSnapshot(expected: snapshot.snapshotSequence, actual: appliedSnapshotSequence)
        }
        let activationID = UUID()
        self.activationID = activationID
        snapshot = replacing(
            snapshot,
            snapshotSequence: snapshot.snapshotSequence &+ 1,
            availability: .active,
            readiness: WorkspaceSessionReadiness(
                generation: snapshot.readiness.generation,
                isReady: true,
                catalogGeneration: snapshot.readiness.catalogGeneration
            )
        )
        self.snapshot = snapshot
        publish()
        return .activated(
            WorkspaceSessionActivationToken(
                sessionID: sessionID,
                activationID: activationID,
                firstAuthoritativeGeneration: snapshot.stateGeneration
            )
        )
    }

    func currentSnapshot() -> WorkspaceSessionSnapshot? {
        snapshot
    }

    func observations(after sequence: UInt64?) -> AsyncStream<WorkspaceSessionSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: WorkspaceSessionSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        observers[id] = continuation
        if let snapshot, sequence.map({ snapshot.snapshotSequence > $0 }) ?? true {
            continuation.yield(snapshot)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    func admit() -> WorkspaceSessionAdmissionResult {
        guard let snapshot, snapshot.availability == .active, let activationID else {
            return .notReady(snapshot?.availability ?? .created)
        }
        return .admitted(
            WorkspaceSessionAdmissionToken(
                sessionID: sessionID,
                activationID: activationID,
                admittedGeneration: snapshot.stateGeneration,
                snapshotSequence: snapshot.snapshotSequence
            )
        )
    }

    func capturePromptFactualContext(
        admission: WorkspaceSessionAdmissionToken,
        request: PromptFactualCaptureRequest
    ) async -> PromptFactualCaptureOutcome {
        guard !isShuttingDown else { return .unavailable(.closedSession) }
        guard validatesPromptAdmission(admission) else { return .unavailable(.staleGeneration) }
        var outcome = await lifecycleOwner.capturePromptFactualContext(request)
        if case .unavailable(.staleGeneration) = outcome,
           validatesPromptAdmission(admission)
        {
            outcome = await lifecycleOwner.capturePromptFactualContext(request)
        }
        guard !Task.isCancelled else { return .cancelled }
        guard validatesPromptAdmission(admission) else { return .unavailable(.staleGeneration) }
        return outcome
    }

    private func validatesPromptAdmission(_ admission: WorkspaceSessionAdmissionToken) -> Bool {
        guard let snapshot,
              snapshot.availability == .active,
              snapshot.readiness.isReady,
              admission.sessionID == sessionID,
              admission.activationID == activationID
        else { return false }
        return admission.admittedGeneration == snapshot.stateGeneration
            && snapshot.snapshotSequence >= admission.snapshotSequence
    }

    func execute(_ envelope: WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult {
        if let cached = cachedResults[envelope.commandID] { return cached }
        if let task = inFlightCommands[envelope.commandID] { return await task.value }
        let task = Task<WorkspaceSessionCommandResult, Never> { [weak self] in
            guard let self else { return .notReady(.closed) }
            return await executeUncached(envelope)
        }
        inFlightCommands[envelope.commandID] = task
        let result = await task.value
        inFlightCommands.removeValue(forKey: envelope.commandID)
        return remember(result, id: envelope.commandID)
    }

    private func executeUncached(_ envelope: WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult {
        guard !isShuttingDown else { return .notReady(.closing) }
        guard var snapshot, snapshot.availability == .active else {
            return .notReady(snapshot?.availability ?? .created)
        }
        guard envelope.admissionToken.sessionID == sessionID else {
            return .rejected(.foreignSession)
        }
        guard envelope.admissionToken.activationID == activationID else {
            return .rejected(.expiredActivation)
        }
        guard envelope.expectedGeneration == snapshot.stateGeneration else {
            return .stale(
                latestSnapshot: snapshot,
                conflict: WorkspaceSessionConflict(
                    kind: .generation(expected: envelope.expectedGeneration, actual: snapshot.stateGeneration)
                )
            )
        }

        if case let .persistence(command) = envelope.command {
            return await executePersistence(command, envelope: envelope, snapshot: snapshot)
        }
        if case let .refresh(command) = envelope.command {
            return await executeRefresh(command, envelope: envelope, snapshot: snapshot)
        }
        if case let .switchWorkspace(command) = envelope.command {
            return await executeSwitch(command, envelope: envelope, snapshot: snapshot)
        }
        if case let .workspace(.replaceOrderedRoots(workspaceID, roots)) = envelope.command,
           snapshot.activeWorkspaceID == workspaceID
        {
            return await executeActiveRootReplacement(
                workspaceID: workspaceID,
                roots: roots,
                envelope: envelope,
                snapshot: snapshot
            )
        }

        let mutation = await mutate(snapshot: snapshot, command: envelope.command, envelope: envelope)
        switch mutation {
        case let .result(result):
            return result
        case let .changed(workspaces, activeID, selectionRevisions, selectionRevision, dirtyWorkspaceID):
            var dirty = snapshot.dirtyGenerations
            var saved = snapshot.savedGenerations
            if let dirtyWorkspaceID { dirty[dirtyWorkspaceID, default: 0] &+= 1 }
            if case let .workspace(.delete(workspaceID)) = envelope.command {
                dirty.removeValue(forKey: workspaceID)
                saved.removeValue(forKey: workspaceID)
            }
            snapshot = WorkspaceSessionSnapshot(
                sessionID: sessionID,
                snapshotSequence: snapshot.snapshotSequence &+ 1,
                stateGeneration: snapshot.stateGeneration &+ 1,
                workspaces: workspaces,
                activeWorkspaceID: activeID,
                selectionRevisions: selectionRevisions,
                dirtyGenerations: dirty,
                savedGenerations: saved,
                switchState: snapshot.switchState,
                readiness: snapshot.readiness,
                availability: .active
            )
            self.snapshot = snapshot
            publish()
            return .committed(
                WorkspaceSessionCommandReceipt(
                    commandID: envelope.commandID,
                    sessionID: sessionID,
                    activationID: activationID!,
                    resultingGeneration: snapshot.stateGeneration,
                    selectionRevision: selectionRevision,
                    dirtyGeneration: dirtyWorkspaceID.map { dirty[$0, default: 0] },
                    snapshotSequence: snapshot.snapshotSequence
                )
            )
        }
    }

    func shutdown() async {
        if let teardownTask {
            await teardownTask.value
            return
        }
        guard !didClose else { return }
        isShuttingDown = true
        activationID = nil
        if let snapshot {
            self.snapshot = replacing(
                snapshot,
                snapshotSequence: snapshot.snapshotSequence &+ 1,
                availability: .closing
            )
            publish()
        }
        let commandTasks = Array(inFlightCommands.values)
        let hydrationTask = hydrationTask
        let generation = lifecycleGeneration
        let lifecycleOwner = lifecycleOwner
        let close = close
        let task = Task {
            hydrationTask?.cancel()
            _ = await hydrationTask?.value
            commandTasks.forEach { $0.cancel() }
            for commandTask in commandTasks {
                _ = await commandTask.value
            }
            try? await lifecycleOwner.unload(generation: generation)
            await lifecycleOwner.close()
            await close()
        }
        teardownTask = task
        await task.value
        didClose = true
        if let snapshot {
            self.snapshot = replacing(
                snapshot,
                snapshotSequence: snapshot.snapshotSequence &+ 1,
                availability: .closed
            )
            publish()
        }
        let continuations = observers.values
        observers.removeAll()
        continuations.forEach { $0.finish() }
    }

    private enum MutationResult {
        case result(WorkspaceSessionCommandResult)
        case changed([WorkspaceModel], UUID?, [WorkspaceTabSelectionKey: UInt64], UInt64?, UUID?)
    }

    private func executeSwitch(
        _ command: WorkspaceSwitchCommand,
        envelope: WorkspaceSessionCommandEnvelope,
        snapshot: WorkspaceSessionSnapshot
    ) async -> WorkspaceSessionCommandResult {
        lifecycleGeneration &+= 1
        let targetGeneration = lifecycleGeneration
        guard let target = snapshot.workspaces.first(where: { $0.id == command.targetWorkspaceID }) else {
            return .rejected(.workspaceNotFound(command.targetWorkspaceID))
        }
        guard snapshot.activeWorkspaceID != target.id else {
            return unchanged(snapshot: snapshot, commandID: envelope.commandID)
        }
        let operationID = WorkspaceSwitchOperationID()
        let source = snapshot.activeWorkspaceID.flatMap { activeID in
            snapshot.workspaces.first(where: { $0.id == activeID })
        }
        let previousReadiness = snapshot.readiness
        var switching = WorkspaceSessionSnapshot(
            sessionID: snapshot.sessionID,
            snapshotSequence: snapshot.snapshotSequence &+ 1,
            stateGeneration: snapshot.stateGeneration,
            workspaces: snapshot.workspaces,
            activeWorkspaceID: snapshot.activeWorkspaceID,
            selectionRevisions: snapshot.selectionRevisions,
            dirtyGenerations: snapshot.dirtyGenerations,
            savedGenerations: snapshot.savedGenerations,
            switchState: WorkspaceSwitchState(
                operationID: operationID,
                phase: .preparing,
                sourceWorkspaceID: snapshot.activeWorkspaceID,
                targetWorkspaceID: target.id,
                reason: command.reason
            ),
            readiness: WorkspaceSessionReadiness(generation: targetGeneration, isReady: false),
            availability: .switching
        )
        self.snapshot = switching
        publish()
        if Task.isCancelled {
            return cancelSwitchBeforeUnload(
                snapshot: snapshot,
                previousReadiness: previousReadiness,
                message: "workspace switch was cancelled before root unload"
            )
        }
        if command.shouldSaveCurrentState,
           let current = source
        {
            switching = replacingSwitchPhase(switching, phase: .flushing)
            self.snapshot = switching
            publish()
            guard let url = workspaceURL(current) else {
                return cancelSwitchBeforeUnload(
                    snapshot: snapshot,
                    previousReadiness: previousReadiness,
                    message: "workspace storage URL is unavailable"
                )
            }
            let selectionMetadata = persistenceSelectionMetadata(
                workspace: current,
                snapshot: snapshot
            )
            let write = await persistence.persist(
                WorkspaceSessionPersistenceRequest(
                    url: url,
                    workspace: current,
                    dirtyGeneration: snapshot.dirtyGenerations[current.id, default: 0],
                    selectionMetadata: selectionMetadata
                )
            )
            switch write {
            case let .written(writtenGeneration, _):
                var saved = switching.savedGenerations
                saved[current.id] = max(saved[current.id, default: 0], writtenGeneration)
                switching = replacing(switching, savedGenerations: saved)
                self.snapshot = switching
                publish()
            case let .failed(message):
                return cancelSwitchBeforeUnload(
                    snapshot: snapshot,
                    previousReadiness: previousReadiness,
                    message: message
                )
            case .suppressedByNewerDisk, .normalizationCompareAndSwapFailed, .skippedEphemeral:
                break
            }
        }
        if Task.isCancelled {
            return cancelSwitchBeforeUnload(
                snapshot: snapshot,
                previousReadiness: previousReadiness,
                message: "workspace switch was cancelled before root unload"
            )
        }

        switching = replacingSwitchPhase(switching, phase: .unloadingRoots)
        self.snapshot = switching
        publish()
        let previousGeneration = previousReadiness.generation
        do {
            try await lifecycleOwner.unload(generation: previousGeneration)
            switching = replacingSwitchPhase(
                switching,
                phase: .hydratingRoots,
                destructiveBoundaryCrossed: true
            )
            self.snapshot = switching
            publish()
            guard !Task.isCancelled, !isShuttingDown else {
                throw WorkspaceSessionFailure("workspace switch was cancelled after root unload")
            }
            let ready = try await lifecycleOwner.hydrate(
                workspace: target,
                generation: targetGeneration
            )
            guard ready.workspaceID == target.id, ready.generation == targetGeneration else {
                throw WorkspaceSessionFailure("legacy target readiness was stale")
            }
            guard !Task.isCancelled, !isShuttingDown else {
                throw WorkspaceSessionFailure("workspace switch was cancelled after target hydration")
            }
            var committedState = switching.switchState
            committedState.phase = .committed
            committedState.destructiveBoundaryCrossed = true
            committedState.commitBoundaryCrossed = true
            let updated = WorkspaceSessionSnapshot(
                sessionID: snapshot.sessionID,
                snapshotSequence: switching.snapshotSequence &+ 1,
                stateGeneration: snapshot.stateGeneration &+ 1,
                workspaces: snapshot.workspaces,
                activeWorkspaceID: target.id,
                selectionRevisions: snapshot.selectionRevisions,
                dirtyGenerations: snapshot.dirtyGenerations,
                savedGenerations: switching.savedGenerations,
                switchState: committedState,
                readiness: WorkspaceSessionReadiness(
                    generation: ready.generation,
                    isReady: true,
                    catalogGeneration: ready.catalogGeneration
                ),
                availability: .active
            )
            self.snapshot = updated
            publish()
            return .committed(
                WorkspaceSessionCommandReceipt(
                    commandID: envelope.commandID,
                    sessionID: sessionID,
                    activationID: activationID!,
                    resultingGeneration: updated.stateGeneration,
                    snapshotSequence: updated.snapshotSequence
                )
            )
        } catch {
            try? await lifecycleOwner.unload(generation: targetGeneration)
            return await recoverSwitch(
                original: snapshot,
                switching: switching,
                source: source,
                failure: sessionFailure(error)
            )
        }
    }

    private func executeActiveRootReplacement(
        workspaceID: UUID,
        roots: [String],
        envelope: WorkspaceSessionCommandEnvelope,
        snapshot: WorkspaceSessionSnapshot
    ) async -> WorkspaceSessionCommandResult {
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return .rejected(.workspaceNotFound(workspaceID))
        }
        guard snapshot.workspaces[index].repoPaths != roots else {
            return unchanged(snapshot: snapshot, commandID: envelope.commandID)
        }
        var updatedWorkspace = snapshot.workspaces[index]
        updatedWorkspace.repoPaths = roots
        updatedWorkspace.dateModified = Date()
        lifecycleGeneration &+= 1
        let targetGeneration = lifecycleGeneration
        let switching = WorkspaceSessionSnapshot(
            sessionID: snapshot.sessionID,
            snapshotSequence: snapshot.snapshotSequence &+ 1,
            stateGeneration: snapshot.stateGeneration,
            workspaces: snapshot.workspaces,
            activeWorkspaceID: snapshot.activeWorkspaceID,
            selectionRevisions: snapshot.selectionRevisions,
            dirtyGenerations: snapshot.dirtyGenerations,
            savedGenerations: snapshot.savedGenerations,
            switchState: snapshot.switchState,
            readiness: WorkspaceSessionReadiness(generation: targetGeneration, isReady: false),
            availability: .switching
        )
        self.snapshot = switching
        publish()
        do {
            try await lifecycleOwner.unload(generation: snapshot.readiness.generation)
            let ready = try await lifecycleOwner.hydrate(
                workspace: updatedWorkspace,
                generation: targetGeneration
            )
            guard ready.workspaceID == workspaceID, ready.generation == targetGeneration else {
                throw WorkspaceSessionFailure("legacy root readiness was stale")
            }
            var workspaces = snapshot.workspaces
            workspaces[index] = updatedWorkspace
            var dirty = snapshot.dirtyGenerations
            dirty[workspaceID, default: 0] &+= 1
            let updated = WorkspaceSessionSnapshot(
                sessionID: snapshot.sessionID,
                snapshotSequence: switching.snapshotSequence &+ 1,
                stateGeneration: snapshot.stateGeneration &+ 1,
                workspaces: workspaces,
                activeWorkspaceID: snapshot.activeWorkspaceID,
                selectionRevisions: snapshot.selectionRevisions,
                dirtyGenerations: dirty,
                savedGenerations: snapshot.savedGenerations,
                switchState: snapshot.switchState,
                readiness: WorkspaceSessionReadiness(
                    generation: ready.generation,
                    isReady: true,
                    catalogGeneration: ready.catalogGeneration
                ),
                availability: .active
            )
            self.snapshot = updated
            publish()
            return .committed(
                WorkspaceSessionCommandReceipt(
                    commandID: envelope.commandID,
                    sessionID: sessionID,
                    activationID: activationID!,
                    resultingGeneration: updated.stateGeneration,
                    dirtyGeneration: dirty[workspaceID],
                    snapshotSequence: updated.snapshotSequence
                )
            )
        } catch {
            try? await lifecycleOwner.unload(generation: targetGeneration)
            return await recoverRefresh(
                original: snapshot,
                switching: switching,
                workspace: snapshot.workspaces[index],
                operationLabel: "root replacement",
                failure: sessionFailure(error)
            )
        }
    }

    private func cancelSwitchBeforeUnload(
        snapshot: WorkspaceSessionSnapshot,
        previousReadiness: WorkspaceSessionReadiness,
        message: String
    ) -> WorkspaceSessionCommandResult {
        let restored = WorkspaceSessionSnapshot(
            sessionID: snapshot.sessionID,
            snapshotSequence: (self.snapshot?.snapshotSequence ?? snapshot.snapshotSequence) &+ 1,
            stateGeneration: snapshot.stateGeneration,
            workspaces: snapshot.workspaces,
            activeWorkspaceID: snapshot.activeWorkspaceID,
            selectionRevisions: snapshot.selectionRevisions,
            dirtyGenerations: snapshot.dirtyGenerations,
            savedGenerations: self.snapshot?.savedGenerations ?? snapshot.savedGenerations,
            switchState: .idle,
            readiness: previousReadiness,
            availability: .active
        )
        self.snapshot = restored
        publish()
        return .failed(WorkspaceSessionFailure(message))
    }

    private func recoverSwitch(
        original: WorkspaceSessionSnapshot,
        switching: WorkspaceSessionSnapshot,
        source: WorkspaceModel?,
        failure: WorkspaceSessionFailure
    ) async -> WorkspaceSessionCommandResult {
        guard let source else {
            activationID = nil
            var failedState = switching.switchState
            failedState.phase = .failed
            failedState.message = failure.message
            let failed = WorkspaceSessionSnapshot(
                sessionID: original.sessionID,
                snapshotSequence: switching.snapshotSequence &+ 1,
                stateGeneration: original.stateGeneration,
                workspaces: original.workspaces,
                activeWorkspaceID: original.activeWorkspaceID,
                selectionRevisions: original.selectionRevisions,
                dirtyGenerations: original.dirtyGenerations,
                savedGenerations: switching.savedGenerations,
                switchState: failedState,
                readiness: WorkspaceSessionReadiness(
                    generation: switching.readiness.generation,
                    isReady: false,
                    unavailableReason: failure.message
                ),
                availability: .failed(failure.message)
            )
            snapshot = failed
            publish()
            return .failed(failure)
        }
        var recoveringState = switching.switchState
        recoveringState.phase = .recovering
        recoveringState.destructiveBoundaryCrossed = true
        recoveringState.message = failure.message
        var recovering = WorkspaceSessionSnapshot(
            sessionID: original.sessionID,
            snapshotSequence: (snapshot?.snapshotSequence ?? switching.snapshotSequence) &+ 1,
            stateGeneration: original.stateGeneration,
            workspaces: original.workspaces,
            activeWorkspaceID: original.activeWorkspaceID,
            selectionRevisions: original.selectionRevisions,
            dirtyGenerations: original.dirtyGenerations,
            savedGenerations: switching.savedGenerations,
            switchState: recoveringState,
            readiness: switching.readiness,
            availability: .switching
        )
        snapshot = recovering
        publish()
        lifecycleGeneration &+= 1
        let recoveryGeneration = lifecycleGeneration
        do {
            let ready = try await lifecycleOwner.hydrate(workspace: source, generation: recoveryGeneration)
            guard ready.workspaceID == source.id, ready.generation == recoveryGeneration else {
                throw WorkspaceSessionFailure("switch recovery returned the wrong workspace")
            }
            recovering = WorkspaceSessionSnapshot(
                sessionID: original.sessionID,
                snapshotSequence: recovering.snapshotSequence &+ 1,
                stateGeneration: original.stateGeneration,
                workspaces: original.workspaces,
                activeWorkspaceID: source.id,
                selectionRevisions: original.selectionRevisions,
                dirtyGenerations: original.dirtyGenerations,
                savedGenerations: switching.savedGenerations,
                switchState: recoveringState,
                readiness: WorkspaceSessionReadiness(
                    generation: ready.generation,
                    isReady: true,
                    catalogGeneration: ready.catalogGeneration
                ),
                availability: .active
            )
            snapshot = recovering
            publish()
            return .failed(failure)
        } catch {
            try? await lifecycleOwner.unload(generation: recoveryGeneration)
            activationID = nil
            let combined = WorkspaceSessionFailure(
                "switch failed (\(failure.message)); recovery failed (\(error.localizedDescription))"
            )
            var failedState = recoveringState
            failedState.phase = .failed
            failedState.message = combined.message
            let failed = WorkspaceSessionSnapshot(
                sessionID: original.sessionID,
                snapshotSequence: recovering.snapshotSequence &+ 1,
                stateGeneration: original.stateGeneration,
                workspaces: original.workspaces,
                activeWorkspaceID: original.activeWorkspaceID,
                selectionRevisions: original.selectionRevisions,
                dirtyGenerations: original.dirtyGenerations,
                savedGenerations: switching.savedGenerations,
                switchState: failedState,
                readiness: WorkspaceSessionReadiness(
                    generation: recoveryGeneration,
                    isReady: false,
                    unavailableReason: combined.message
                ),
                availability: .failed(combined.message)
            )
            snapshot = failed
            publish()
            return .failed(combined)
        }
    }

    private func executeRefresh(
        _ command: WorkspaceRefreshCommand,
        envelope: WorkspaceSessionCommandEnvelope,
        snapshot: WorkspaceSessionSnapshot
    ) async -> WorkspaceSessionCommandResult {
        lifecycleGeneration &+= 1
        let targetGeneration = lifecycleGeneration
        guard snapshot.activeWorkspaceID == command.workspaceID else {
            return .rejected(.workspaceNotFound(command.workspaceID))
        }
        guard snapshot.readiness.generation == command.expectedReadinessGeneration else {
            return .stale(
                latestSnapshot: snapshot,
                conflict: WorkspaceSessionConflict(
                    kind: .readinessGeneration(
                        expected: command.expectedReadinessGeneration,
                        actual: snapshot.readiness.generation
                    )
                )
            )
        }
        guard let workspace = snapshot.workspaces.first(where: { $0.id == command.workspaceID }) else {
            return .rejected(.workspaceNotFound(command.workspaceID))
        }
        let switching = WorkspaceSessionSnapshot(
            sessionID: snapshot.sessionID,
            snapshotSequence: snapshot.snapshotSequence &+ 1,
            stateGeneration: snapshot.stateGeneration,
            workspaces: snapshot.workspaces,
            activeWorkspaceID: snapshot.activeWorkspaceID,
            selectionRevisions: snapshot.selectionRevisions,
            dirtyGenerations: snapshot.dirtyGenerations,
            savedGenerations: snapshot.savedGenerations,
            switchState: snapshot.switchState,
            readiness: WorkspaceSessionReadiness(generation: targetGeneration, isReady: false),
            availability: .switching
        )
        self.snapshot = switching
        publish()
        do {
            try await lifecycleOwner.unload(generation: snapshot.readiness.generation)
            let ready = try await lifecycleOwner.hydrate(workspace: workspace, generation: targetGeneration)
            guard ready.workspaceID == workspace.id, ready.generation == targetGeneration else {
                throw WorkspaceSessionFailure("legacy refresh readiness was stale")
            }
            let updated = WorkspaceSessionSnapshot(
                sessionID: snapshot.sessionID,
                snapshotSequence: switching.snapshotSequence &+ 1,
                stateGeneration: snapshot.stateGeneration,
                workspaces: snapshot.workspaces,
                activeWorkspaceID: snapshot.activeWorkspaceID,
                selectionRevisions: snapshot.selectionRevisions,
                dirtyGenerations: snapshot.dirtyGenerations,
                savedGenerations: snapshot.savedGenerations,
                switchState: snapshot.switchState,
                readiness: WorkspaceSessionReadiness(
                    generation: ready.generation,
                    isReady: true,
                    catalogGeneration: ready.catalogGeneration
                ),
                availability: .active
            )
            self.snapshot = updated
            publish()
            return .committed(
                WorkspaceSessionCommandReceipt(
                    commandID: envelope.commandID,
                    sessionID: sessionID,
                    activationID: activationID!,
                    resultingGeneration: updated.stateGeneration,
                    snapshotSequence: updated.snapshotSequence
                )
            )
        } catch {
            try? await lifecycleOwner.unload(generation: targetGeneration)
            return await recoverRefresh(
                original: snapshot,
                switching: switching,
                workspace: workspace,
                operationLabel: "refresh",
                failure: sessionFailure(error)
            )
        }
    }

    private func executePersistence(
        _ command: WorkspacePersistenceCommand,
        envelope: WorkspaceSessionCommandEnvelope,
        snapshot: WorkspaceSessionSnapshot
    ) async -> WorkspaceSessionCommandResult {
        switch command {
        case .saveIndex:
            guard let url = indexURL() else {
                return .failed(WorkspaceSessionFailure("workspace index URL is unavailable"))
            }
            let result = await persistence.persistIndex(workspaces: snapshot.workspaces, url: url)
            if let invalid = validateAfterSuspension(envelope) { return invalid }
            switch persistenceDisposition(result, dirtyGeneration: nil) {
            case let .success(disposition):
                return .committed(
                    receipt(
                        snapshot: snapshot,
                        commandID: envelope.commandID,
                        persistence: disposition
                    )
                )
            case let .failure(failure):
                return .failed(failure)
            }
        case let .saveWorkspace(workspaceID), let .flushWorkspace(workspaceID):
            guard let workspace = snapshot.workspaces.first(where: { $0.id == workspaceID }) else {
                return .rejected(.workspaceNotFound(workspaceID))
            }
            let dirtyGeneration = snapshot.dirtyGenerations[workspaceID, default: 0]
            if snapshot.savedGenerations[workspaceID, default: 0] == dirtyGeneration {
                return .unchanged(
                    receipt(
                        snapshot: snapshot,
                        commandID: envelope.commandID,
                        dirtyWorkspaceID: workspaceID,
                        persistence: .written
                    )
                )
            }
            guard let url = workspaceURL(workspace) else {
                return .failed(WorkspaceSessionFailure("workspace storage URL is unavailable"))
            }
            let result = await persistence.persist(
                WorkspaceSessionPersistenceRequest(
                    url: url,
                    workspace: workspace,
                    dirtyGeneration: dirtyGeneration,
                    selectionMetadata: persistenceSelectionMetadata(workspace: workspace, snapshot: snapshot)
                )
            )
            if let invalid = validateAfterSuspension(envelope) { return invalid }
            let disposition: WorkspaceSessionPersistenceDisposition
            switch persistenceDisposition(result, dirtyGeneration: dirtyGeneration) {
            case let .success(value):
                disposition = value
            case let .failure(failure):
                return .failed(failure)
            }
            var savedGenerations = snapshot.savedGenerations
            if disposition == .written {
                savedGenerations[workspaceID] = max(savedGenerations[workspaceID, default: 0], dirtyGeneration)
            }
            let updated = replacing(snapshot, savedGenerations: savedGenerations)
            self.snapshot = updated
            publish()
            return .committed(
                receipt(
                    snapshot: updated,
                    commandID: envelope.commandID,
                    dirtyWorkspaceID: workspaceID,
                    persistence: disposition
                )
            )
        case let .reloadWorkspace(workspaceID):
            return await executeWorkspaceReload(
                workspaceID: workspaceID,
                envelope: envelope,
                snapshot: snapshot
            )
        case .reloadIndex:
            return await executeIndexReload(envelope: envelope, snapshot: snapshot)
        }
    }

    private func executeWorkspaceReload(
        workspaceID: UUID,
        envelope: WorkspaceSessionCommandEnvelope,
        snapshot: WorkspaceSessionSnapshot
    ) async -> WorkspaceSessionCommandResult {
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return .rejected(.workspaceNotFound(workspaceID))
        }
        let original = snapshot.workspaces[index]
        guard let url = workspaceURL(original) else {
            return .failed(WorkspaceSessionFailure("workspace storage URL is unavailable"))
        }
        do {
            let reloaded = try await persistence.loadWorkspace(url: url)
            if let invalid = validateAfterSuspension(envelope) { return invalid }
            guard reloaded.id == workspaceID else {
                return .rejected(.invalidCommand("reloaded workspace identity changed"))
            }
            guard reloaded != original else {
                return unchanged(snapshot: snapshot, commandID: envelope.commandID)
            }
            if snapshot.activeWorkspaceID == workspaceID {
                return await executeActiveWorkspaceReload(
                    reloaded,
                    original: original,
                    index: index,
                    envelope: envelope,
                    snapshot: snapshot
                )
            }
            var workspaces = snapshot.workspaces
            workspaces[index] = reloaded
            let updated = reloadedSnapshot(
                from: snapshot,
                workspaces: workspaces,
                resetWorkspaceID: workspaceID
            )
            self.snapshot = updated
            publish()
            return .committed(receipt(snapshot: updated, commandID: envelope.commandID))
        } catch {
            return .failed(sessionFailure(error))
        }
    }

    private func executeActiveWorkspaceReload(
        _ reloaded: WorkspaceModel,
        original: WorkspaceModel,
        index: Int,
        envelope: WorkspaceSessionCommandEnvelope,
        snapshot: WorkspaceSessionSnapshot
    ) async -> WorkspaceSessionCommandResult {
        lifecycleGeneration &+= 1
        let targetGeneration = lifecycleGeneration
        let switching = WorkspaceSessionSnapshot(
            sessionID: snapshot.sessionID,
            snapshotSequence: snapshot.snapshotSequence &+ 1,
            stateGeneration: snapshot.stateGeneration,
            workspaces: snapshot.workspaces,
            activeWorkspaceID: snapshot.activeWorkspaceID,
            selectionRevisions: snapshot.selectionRevisions,
            dirtyGenerations: snapshot.dirtyGenerations,
            savedGenerations: snapshot.savedGenerations,
            switchState: snapshot.switchState,
            readiness: WorkspaceSessionReadiness(generation: targetGeneration, isReady: false),
            availability: .switching
        )
        self.snapshot = switching
        publish()
        do {
            try await lifecycleOwner.unload(generation: snapshot.readiness.generation)
            let ready = try await lifecycleOwner.hydrate(workspace: reloaded, generation: targetGeneration)
            guard ready.workspaceID == reloaded.id, ready.generation == targetGeneration else {
                throw WorkspaceSessionFailure("legacy workspace reload readiness was stale")
            }
            var workspaces = snapshot.workspaces
            workspaces[index] = reloaded
            var updated = reloadedSnapshot(
                from: switching,
                workspaces: workspaces,
                resetWorkspaceID: reloaded.id,
                readiness: ready
            )
            updated = WorkspaceSessionSnapshot(
                sessionID: updated.sessionID,
                snapshotSequence: switching.snapshotSequence &+ 1,
                stateGeneration: snapshot.stateGeneration &+ 1,
                workspaces: updated.workspaces,
                activeWorkspaceID: updated.activeWorkspaceID,
                selectionRevisions: updated.selectionRevisions,
                dirtyGenerations: updated.dirtyGenerations,
                savedGenerations: updated.savedGenerations,
                switchState: updated.switchState,
                readiness: updated.readiness,
                availability: .active
            )
            self.snapshot = updated
            publish()
            return .committed(receipt(snapshot: updated, commandID: envelope.commandID))
        } catch {
            try? await lifecycleOwner.unload(generation: targetGeneration)
            return await recoverRefresh(
                original: snapshot,
                switching: switching,
                workspace: original,
                operationLabel: "workspace reload",
                failure: sessionFailure(error)
            )
        }
    }

    private func executeIndexReload(
        envelope: WorkspaceSessionCommandEnvelope,
        snapshot: WorkspaceSessionSnapshot
    ) async -> WorkspaceSessionCommandResult {
        do {
            let input = try await load()
            if let invalid = validateAfterSuspension(envelope) { return invalid }
            guard let activeWorkspaceID = snapshot.activeWorkspaceID,
                  input.workspaces.contains(where: { $0.id == activeWorkspaceID })
            else {
                return .rejected(.invalidCommand("index reload cannot remove the active workspace"))
            }
            guard snapshot.workspaces != input.workspaces else {
                return unchanged(snapshot: snapshot, commandID: envelope.commandID)
            }
            let workspaceIDs = Set(input.workspaces.map(\.id))
            let revisions = snapshot.selectionRevisions.filter { workspaceIDs.contains($0.key.workspaceID) }
            revisedSelections = revisedSelections.filter { workspaceIDs.contains($0.key.workspaceID) }
            let dirty = Dictionary(uniqueKeysWithValues: input.workspaces.map {
                ($0.id, snapshot.dirtyGenerations[$0.id, default: 0])
            })
            let saved = Dictionary(uniqueKeysWithValues: input.workspaces.map {
                ($0.id, snapshot.savedGenerations[$0.id, default: 0])
            })
            let updated = WorkspaceSessionSnapshot(
                sessionID: snapshot.sessionID,
                snapshotSequence: snapshot.snapshotSequence &+ 1,
                stateGeneration: snapshot.stateGeneration &+ 1,
                workspaces: input.workspaces,
                activeWorkspaceID: activeWorkspaceID,
                selectionRevisions: revisions,
                dirtyGenerations: dirty,
                savedGenerations: saved,
                switchState: snapshot.switchState,
                readiness: snapshot.readiness,
                availability: snapshot.availability
            )
            self.snapshot = updated
            publish()
            return .committed(receipt(snapshot: updated, commandID: envelope.commandID))
        } catch {
            return .failed(sessionFailure(error))
        }
    }

    private func mutate(
        snapshot: WorkspaceSessionSnapshot,
        command: WorkspaceSessionCommand,
        envelope: WorkspaceSessionCommandEnvelope
    ) async -> MutationResult {
        let commandID = envelope.commandID
        var workspaces = snapshot.workspaces
        var activeID = snapshot.activeWorkspaceID
        var revisions = snapshot.selectionRevisions
        switch command {
        case let .workspace(.create(workspace, makeActive)):
            guard !makeActive || activeID == nil else {
                return .result(.rejected(.invalidCommand("workspace activation requires a lifecycle switch command")))
            }
            guard !workspaces.contains(where: { $0.id == workspace.id }) else {
                return .result(.rejected(.duplicateWorkspace(workspace.id)))
            }
            workspaces.append(workspace)
            if makeActive || activeID == nil { activeID = workspace.id }
            return .changed(workspaces, activeID, revisions, nil, workspace.id)
        case let .workspace(.delete(workspaceID)):
            guard workspaces.contains(where: { $0.id == workspaceID }) else {
                return .result(.rejected(.workspaceNotFound(workspaceID)))
            }
            guard workspaces.count > 1 else { return .result(.rejected(.cannotDeleteLastWorkspace)) }
            guard activeID != workspaceID else {
                return .result(.rejected(.invalidCommand("active workspace deletion requires a lifecycle switch first")))
            }
            workspaces.removeAll { $0.id == workspaceID }
            revisions = revisions.filter { $0.key.workspaceID != workspaceID }
            revisedSelections = revisedSelections.filter { $0.key.workspaceID != workspaceID }
            return .changed(workspaces, activeID, revisions, nil, nil)
        case let .workspace(.replace(workspace)):
            guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else {
                return .result(.rejected(.workspaceNotFound(workspace.id)))
            }
            guard workspaces[index].composeTabs == workspace.composeTabs,
                  workspaces[index].activeComposeTabID == workspace.activeComposeTabID,
                  workspaces[index].stashedTabs == workspace.stashedTabs,
                  workspaces[index].repoPaths == workspace.repoPaths
            else {
                return .result(.rejected(.invalidCommand(
                    "workspace replacement cannot bypass compose-tab, selection, or root lifecycle commands"
                )))
            }
            guard workspaces[index] != workspace else { return .result(unchanged(snapshot: snapshot, commandID: commandID)) }
            workspaces[index] = workspace
            return .changed(workspaces, activeID, revisions, nil, workspace.id)
        case let .workspace(.replaceOrderedRoots(workspaceID, roots)):
            guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                return .result(.rejected(.workspaceNotFound(workspaceID)))
            }
            guard workspaces[index].repoPaths != roots else { return .result(unchanged(snapshot: snapshot, commandID: commandID)) }
            workspaces[index].repoPaths = roots
            workspaces[index].dateModified = Date()
            return .changed(workspaces, activeID, revisions, nil, workspaceID)
        case let .workspace(.setActive(workspaceID)):
            guard workspaces.contains(where: { $0.id == workspaceID }) else {
                return .result(.rejected(.workspaceNotFound(workspaceID)))
            }
            guard activeID != workspaceID else { return .result(unchanged(snapshot: snapshot, commandID: commandID)) }
            return .result(.rejected(.invalidCommand("workspace activation requires a lifecycle switch command")))
        case let .selection(selection):
            let key = WorkspaceTabSelectionKey(workspaceID: selection.workspaceID, tabID: selection.tabID)
            let currentRevision = revisions[key, default: 0]
            guard currentRevision == selection.expectedRevision else {
                return .result(
                    .stale(
                        latestSnapshot: snapshot,
                        conflict: WorkspaceSessionConflict(
                            kind: .selectionRevision(key: key, expected: selection.expectedRevision, actual: currentRevision)
                        )
                    )
                )
            }
            guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == selection.workspaceID }) else {
                return .result(.rejected(.workspaceNotFound(selection.workspaceID)))
            }
            guard let tabIndex = workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == selection.tabID }) else {
                return .result(.rejected(.tabNotFound(workspaceID: selection.workspaceID, tabID: selection.tabID)))
            }
            guard workspaces[workspaceIndex].composeTabs[tabIndex].selection != selection.selection else {
                return .result(unchanged(snapshot: snapshot, commandID: commandID, selectionRevision: currentRevision))
            }
            let revision = await revisionAllocator.allocate()
            if let invalid = validateAfterSuspension(envelope) { return .result(invalid) }
            workspaces[workspaceIndex].composeTabs[tabIndex].selection = selection.selection
            workspaces[workspaceIndex].composeTabs[tabIndex].lastModified = Date()
            revisions[key] = revision
            revisedSelections[key] = selection.selection
            return .changed(workspaces, activeID, revisions, revision, selection.workspaceID)
        case let .selectionAndPatch(compound):
            let selection = compound.selection
            let key = WorkspaceTabSelectionKey(workspaceID: selection.workspaceID, tabID: selection.tabID)
            let currentRevision = revisions[key, default: 0]
            guard currentRevision == selection.expectedRevision else {
                return .result(
                    .stale(
                        latestSnapshot: snapshot,
                        conflict: WorkspaceSessionConflict(
                            kind: .selectionRevision(
                                key: key,
                                expected: selection.expectedRevision,
                                actual: currentRevision
                            )
                        )
                    )
                )
            }
            guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == selection.workspaceID }) else {
                return .result(.rejected(.workspaceNotFound(selection.workspaceID)))
            }
            guard let tabIndex = workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == selection.tabID }) else {
                return .result(.rejected(.tabNotFound(workspaceID: selection.workspaceID, tabID: selection.tabID)))
            }
            let currentTab = workspaces[workspaceIndex].composeTabs[tabIndex]
            var updatedTab = compound.patch.applying(to: currentTab)
            updatedTab.selection = selection.selection
            guard updatedTab != currentTab else {
                return .result(unchanged(snapshot: snapshot, commandID: commandID, selectionRevision: currentRevision))
            }
            var revision = currentRevision
            if currentTab.selection != selection.selection {
                revision = await revisionAllocator.allocate()
                if let invalid = validateAfterSuspension(envelope) { return .result(invalid) }
                revisions[key] = revision
                revisedSelections[key] = selection.selection
            }
            workspaces[workspaceIndex].composeTabs[tabIndex] = updatedTab
            workspaces[workspaceIndex].dateModified = max(
                workspaces[workspaceIndex].dateModified,
                updatedTab.lastModified
            )
            return .changed(workspaces, activeID, revisions, revision, selection.workspaceID)
        case let .composeTab(command):
            let workspaceID: UUID = switch command {
            case let .create(id, _, _), let .patchTitle(id, _, _, _), let .patch(id, _, _),
                 let .patchStashed(id, _, _), let .remove(id, _),
                 let .activate(id, _), let .reorder(id, _), let .stash(id, _, _, _), let .restore(id, _),
                 let .deleteStashed(id, _):
                id
            }
            guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                return .result(.rejected(.workspaceNotFound(workspaceID)))
            }
            var workspace = workspaces[workspaceIndex]
            switch command {
            case let .create(_, tab, makeActive):
                guard !workspace.composeTabs.contains(where: { $0.id == tab.id }) else {
                    return .result(.rejected(.duplicateTab(workspaceID: workspaceID, tabID: tab.id)))
                }
                workspace.composeTabs.append(tab)
                if makeActive { workspace.activeComposeTabID = tab.id }
            case let .patchTitle(_, tabID, name, lastModified):
                guard let tabIndex = workspace.composeTabs.firstIndex(where: { $0.id == tabID }) else {
                    return .result(.rejected(.tabNotFound(workspaceID: workspaceID, tabID: tabID)))
                }
                guard workspace.composeTabs[tabIndex].name != name else {
                    return .result(unchanged(snapshot: snapshot, commandID: commandID))
                }
                workspace.composeTabs[tabIndex].name = name
                workspace.composeTabs[tabIndex].lastModified = lastModified
            case let .patch(_, tabID, patch):
                guard let tabIndex = workspace.composeTabs.firstIndex(where: { $0.id == tabID }) else {
                    return .result(.rejected(.tabNotFound(workspaceID: workspaceID, tabID: tabID)))
                }
                let updated = patch.applying(to: workspace.composeTabs[tabIndex])
                guard workspace.composeTabs[tabIndex] != updated else {
                    return .result(unchanged(snapshot: snapshot, commandID: commandID))
                }
                workspace.composeTabs[tabIndex] = updated
            case let .patchStashed(_, stashedTabID, patch):
                guard let stashIndex = workspace.stashedTabs.firstIndex(where: { $0.id == stashedTabID }) else {
                    return .result(.rejected(.invalidCommand("stashed tab not found")))
                }
                let updated = patch.applying(to: workspace.stashedTabs[stashIndex].tab)
                guard workspace.stashedTabs[stashIndex].tab != updated else {
                    return .result(unchanged(snapshot: snapshot, commandID: commandID))
                }
                workspace.stashedTabs[stashIndex].tab = updated
            case let .remove(_, tabID):
                guard workspace.composeTabs.contains(where: { $0.id == tabID }) else {
                    return .result(.rejected(.tabNotFound(workspaceID: workspaceID, tabID: tabID)))
                }
                workspace.composeTabs.removeAll { $0.id == tabID }
                revisions.removeValue(forKey: WorkspaceTabSelectionKey(workspaceID: workspaceID, tabID: tabID))
                revisedSelections.removeValue(forKey: WorkspaceTabSelectionKey(workspaceID: workspaceID, tabID: tabID))
                _ = workspace.normalizeComposeTabInvariants()
            case let .activate(_, tabID):
                guard workspace.composeTabs.contains(where: { $0.id == tabID }) else {
                    return .result(.rejected(.tabNotFound(workspaceID: workspaceID, tabID: tabID)))
                }
                guard workspace.activeComposeTabID != tabID else { return .result(unchanged(snapshot: snapshot, commandID: commandID)) }
                workspace.activeComposeTabID = tabID
            case let .reorder(_, orderedTabIDs):
                guard orderedTabIDs.count == workspace.composeTabs.count,
                      Set(orderedTabIDs) == Set(workspace.composeTabs.map(\.id))
                else { return .result(.rejected(.invalidCommand("reorder must contain every tab exactly once"))) }
                let byID = Dictionary(uniqueKeysWithValues: workspace.composeTabs.map { ($0.id, $0) })
                let reordered = orderedTabIDs.compactMap { byID[$0] }
                guard reordered != workspace.composeTabs else { return .result(unchanged(snapshot: snapshot, commandID: commandID)) }
                workspace.composeTabs = reordered
            case let .stash(_, tabID, stashedTabID, stashedAt):
                guard let tabIndex = workspace.composeTabs.firstIndex(where: { $0.id == tabID }) else {
                    return .result(.rejected(.tabNotFound(workspaceID: workspaceID, tabID: tabID)))
                }
                let tab = workspace.composeTabs.remove(at: tabIndex)
                workspace.stashedTabs.append(StashedTab(id: stashedTabID, tab: tab, stashedAt: stashedAt))
                _ = workspace.normalizeComposeTabInvariants()
            case let .restore(_, stashedTabID):
                guard let stashIndex = workspace.stashedTabs.firstIndex(where: { $0.id == stashedTabID }) else {
                    return .result(.rejected(.invalidCommand("stashed tab not found")))
                }
                let stashed = workspace.stashedTabs.remove(at: stashIndex)
                guard !workspace.composeTabs.contains(where: { $0.id == stashed.tab.id }) else {
                    return .result(.rejected(.duplicateTab(workspaceID: workspaceID, tabID: stashed.tab.id)))
                }
                workspace.composeTabs.append(stashed.tab)
                workspace.activeComposeTabID = stashed.tab.id
            case let .deleteStashed(_, stashedTabIDs):
                let originalCount = workspace.stashedTabs.count
                workspace.stashedTabs.removeAll { stashedTabIDs.contains($0.id) }
                guard workspace.stashedTabs.count != originalCount else {
                    return .result(unchanged(snapshot: snapshot, commandID: commandID))
                }
            }
            workspace.dateModified = Date()
            workspaces[workspaceIndex] = workspace
            return .changed(workspaces, activeID, revisions, nil, workspaceID)
        case let .switchWorkspace(command):
            guard workspaces.contains(where: { $0.id == command.targetWorkspaceID }) else {
                return .result(.rejected(.workspaceNotFound(command.targetWorkspaceID)))
            }
            guard activeID != command.targetWorkspaceID else { return .result(unchanged(snapshot: snapshot, commandID: commandID)) }
            activeID = command.targetWorkspaceID
            return .changed(workspaces, activeID, revisions, nil, nil)
        default:
            return .result(.rejected(.invalidCommand("command bypassed legacy orchestration dispatch")))
        }
    }

    private func unchanged(
        snapshot: WorkspaceSessionSnapshot,
        commandID: UUID,
        selectionRevision: UInt64? = nil
    ) -> WorkspaceSessionCommandResult {
        .unchanged(receipt(snapshot: snapshot, commandID: commandID, selectionRevision: selectionRevision))
    }

    private func receipt(
        snapshot: WorkspaceSessionSnapshot,
        commandID: UUID,
        selectionRevision: UInt64? = nil,
        dirtyWorkspaceID: UUID? = nil,
        persistence: WorkspaceSessionPersistenceDisposition = .notRequested
    ) -> WorkspaceSessionCommandReceipt {
        WorkspaceSessionCommandReceipt(
            commandID: commandID,
            sessionID: sessionID,
            activationID: activationID!,
            resultingGeneration: snapshot.stateGeneration,
            selectionRevision: selectionRevision,
            dirtyGeneration: dirtyWorkspaceID.map { snapshot.dirtyGenerations[$0, default: 0] },
            persistenceDisposition: persistence,
            snapshotSequence: snapshot.snapshotSequence
        )
    }

    private func replacing(
        _ snapshot: WorkspaceSessionSnapshot,
        snapshotSequence: UInt64,
        availability: WorkspaceSessionAvailability,
        readiness: WorkspaceSessionReadiness? = nil
    ) -> WorkspaceSessionSnapshot {
        WorkspaceSessionSnapshot(
            sessionID: snapshot.sessionID,
            snapshotSequence: snapshotSequence,
            stateGeneration: snapshot.stateGeneration,
            workspaces: snapshot.workspaces,
            activeWorkspaceID: snapshot.activeWorkspaceID,
            selectionRevisions: snapshot.selectionRevisions,
            dirtyGenerations: snapshot.dirtyGenerations,
            savedGenerations: snapshot.savedGenerations,
            switchState: snapshot.switchState,
            readiness: readiness ?? snapshot.readiness,
            availability: availability
        )
    }

    private func replacing(
        _ snapshot: WorkspaceSessionSnapshot,
        savedGenerations: [UUID: UInt64]
    ) -> WorkspaceSessionSnapshot {
        WorkspaceSessionSnapshot(
            sessionID: snapshot.sessionID,
            snapshotSequence: snapshot.snapshotSequence &+ 1,
            stateGeneration: snapshot.stateGeneration,
            workspaces: snapshot.workspaces,
            activeWorkspaceID: snapshot.activeWorkspaceID,
            selectionRevisions: snapshot.selectionRevisions,
            dirtyGenerations: snapshot.dirtyGenerations,
            savedGenerations: savedGenerations,
            switchState: snapshot.switchState,
            readiness: snapshot.readiness,
            availability: snapshot.availability
        )
    }

    private func replacingSwitchPhase(
        _ snapshot: WorkspaceSessionSnapshot,
        phase: RepoPromptCore.WorkspaceSwitchPhase,
        destructiveBoundaryCrossed: Bool? = nil
    ) -> WorkspaceSessionSnapshot {
        var state = snapshot.switchState
        state.phase = phase
        if let destructiveBoundaryCrossed {
            state.destructiveBoundaryCrossed = destructiveBoundaryCrossed
        }
        return WorkspaceSessionSnapshot(
            sessionID: snapshot.sessionID,
            snapshotSequence: snapshot.snapshotSequence &+ 1,
            stateGeneration: snapshot.stateGeneration,
            workspaces: snapshot.workspaces,
            activeWorkspaceID: snapshot.activeWorkspaceID,
            selectionRevisions: snapshot.selectionRevisions,
            dirtyGenerations: snapshot.dirtyGenerations,
            savedGenerations: snapshot.savedGenerations,
            switchState: state,
            readiness: snapshot.readiness,
            availability: snapshot.availability
        )
    }

    private func reloadedSnapshot(
        from snapshot: WorkspaceSessionSnapshot,
        workspaces: [WorkspaceModel],
        resetWorkspaceID: UUID,
        readiness: WorkspaceSessionLifecycleReadiness? = nil
    ) -> WorkspaceSessionSnapshot {
        revisedSelections = revisedSelections.filter { $0.key.workspaceID != resetWorkspaceID }
        var dirty = snapshot.dirtyGenerations
        var saved = snapshot.savedGenerations
        dirty[resetWorkspaceID] = 0
        saved[resetWorkspaceID] = 0
        return WorkspaceSessionSnapshot(
            sessionID: snapshot.sessionID,
            snapshotSequence: snapshot.snapshotSequence &+ 1,
            stateGeneration: snapshot.stateGeneration &+ 1,
            workspaces: workspaces,
            activeWorkspaceID: snapshot.activeWorkspaceID,
            selectionRevisions: snapshot.selectionRevisions.filter { $0.key.workspaceID != resetWorkspaceID },
            dirtyGenerations: dirty,
            savedGenerations: saved,
            switchState: snapshot.switchState,
            readiness: readiness.map {
                WorkspaceSessionReadiness(
                    generation: $0.generation,
                    isReady: true,
                    catalogGeneration: $0.catalogGeneration
                )
            } ?? snapshot.readiness,
            availability: readiness == nil ? snapshot.availability : .active
        )
    }

    private func recoverRefresh(
        original: WorkspaceSessionSnapshot,
        switching: WorkspaceSessionSnapshot,
        workspace: WorkspaceModel,
        operationLabel: String,
        failure: WorkspaceSessionFailure
    ) async -> WorkspaceSessionCommandResult {
        lifecycleGeneration &+= 1
        let recoveryGeneration = lifecycleGeneration
        do {
            let ready = try await lifecycleOwner.hydrate(workspace: workspace, generation: recoveryGeneration)
            guard ready.workspaceID == workspace.id, ready.generation == recoveryGeneration else {
                throw WorkspaceSessionFailure("refresh recovery returned the wrong workspace")
            }
            let recovered = WorkspaceSessionSnapshot(
                sessionID: original.sessionID,
                snapshotSequence: switching.snapshotSequence &+ 1,
                stateGeneration: original.stateGeneration,
                workspaces: original.workspaces,
                activeWorkspaceID: original.activeWorkspaceID,
                selectionRevisions: original.selectionRevisions,
                dirtyGenerations: original.dirtyGenerations,
                savedGenerations: original.savedGenerations,
                switchState: original.switchState,
                readiness: WorkspaceSessionReadiness(
                    generation: ready.generation,
                    isReady: true,
                    catalogGeneration: ready.catalogGeneration,
                    unavailableReason: failure.message
                ),
                availability: .active
            )
            snapshot = recovered
            publish()
            return .failed(failure)
        } catch {
            try? await lifecycleOwner.unload(generation: recoveryGeneration)
            activationID = nil
            let combined = WorkspaceSessionFailure(
                "\(operationLabel) failed (\(failure.message)); recovery failed (\(error.localizedDescription))"
            )
            let failed = WorkspaceSessionSnapshot(
                sessionID: original.sessionID,
                snapshotSequence: switching.snapshotSequence &+ 1,
                stateGeneration: original.stateGeneration,
                workspaces: original.workspaces,
                activeWorkspaceID: original.activeWorkspaceID,
                selectionRevisions: original.selectionRevisions,
                dirtyGenerations: original.dirtyGenerations,
                savedGenerations: original.savedGenerations,
                switchState: original.switchState,
                readiness: WorkspaceSessionReadiness(
                    generation: switching.readiness.generation,
                    isReady: false,
                    unavailableReason: combined.message
                ),
                availability: .failed(combined.message)
            )
            snapshot = failed
            publish()
            return .failed(combined)
        }
    }

    private func persistenceSelectionMetadata(
        workspace: WorkspaceModel,
        snapshot: WorkspaceSessionSnapshot
    ) -> WorkspacePersistenceSelectionMetadata? {
        guard let tabID = workspace.activeComposeTabID ?? workspace.composeTabs.first?.id,
              let selection = workspace.composeTabs.first(where: { $0.id == tabID })?.selection
        else { return nil }
        let key = WorkspaceTabSelectionKey(workspaceID: workspace.id, tabID: tabID)
        let revision = snapshot.selectionRevisions[key, default: 0]
        guard revision > 0, revisedSelections[key] == selection else { return nil }
        return WorkspacePersistenceSelectionMetadata(key: key, revision: revision, selection: selection)
    }

    private func persistenceDisposition(
        _ result: WorkspacePersistenceWriteResult,
        dirtyGeneration: UInt64?
    ) -> Result<WorkspaceSessionPersistenceDisposition, WorkspaceSessionFailure> {
        switch result {
        case let .written(writtenGeneration, _):
            if let dirtyGeneration, writtenGeneration < dirtyGeneration {
                return .success(.suppressedByNewerState)
            }
            return .success(.written)
        case .suppressedByNewerDisk, .normalizationCompareAndSwapFailed:
            return .success(.suppressedByNewerState)
        case .skippedEphemeral:
            return .success(.notRequested)
        case let .failed(message):
            return .failure(WorkspaceSessionFailure(message))
        }
    }

    private func sessionFailure(_ error: Error) -> WorkspaceSessionFailure {
        if let failure = error as? WorkspaceSessionFailure { return failure }
        return WorkspaceSessionFailure(error.localizedDescription)
    }

    private func validateAfterSuspension(
        _ envelope: WorkspaceSessionCommandEnvelope
    ) -> WorkspaceSessionCommandResult? {
        guard let snapshot, snapshot.availability == .active else {
            return .notReady(snapshot?.availability ?? .closed)
        }
        guard envelope.admissionToken.sessionID == sessionID else { return .rejected(.foreignSession) }
        guard envelope.admissionToken.activationID == activationID else { return .rejected(.expiredActivation) }
        guard envelope.expectedGeneration == snapshot.stateGeneration else {
            return .stale(
                latestSnapshot: snapshot,
                conflict: WorkspaceSessionConflict(
                    kind: .generation(
                        expected: envelope.expectedGeneration,
                        actual: snapshot.stateGeneration
                    )
                )
            )
        }
        return nil
    }

    private func remember(_ result: WorkspaceSessionCommandResult, id: UUID) -> WorkspaceSessionCommandResult {
        cachedResults[id] = result
        cachedResultOrder.append(id)
        if cachedResultOrder.count > 256 {
            cachedResults.removeValue(forKey: cachedResultOrder.removeFirst())
        }
        return result
    }

    private func publish() {
        guard let snapshot else { return }
        observers.values.forEach { $0.yield(snapshot) }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

private actor LegacyWorkspaceSelectionRevisionAllocator {
    private var nextRevision: UInt64 = 1

    func allocate() -> UInt64 {
        defer { nextRevision &+= 1 }
        return nextRevision
    }
}
