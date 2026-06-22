import Foundation

package struct WorkspaceSessionControllerConstructionKey {
    fileprivate init() {}
}

package struct RepoPromptCoreSessionHandleConstructionKey {
    fileprivate init() {}
}

package struct RepoPromptCoreSessionDependencies: @unchecked Sendable {
    package let load: @Sendable () async throws -> WorkspaceSessionHydrationInput
    package let lifecycleOwner: WorkspaceSessionLifecycleOwner
    package let workspaceURL: @Sendable (WorkspaceModel) -> URL?
    package let indexURL: @Sendable () -> URL?

    package init(
        load: @escaping @Sendable () async throws -> WorkspaceSessionHydrationInput,
        lifecycleOwner: WorkspaceSessionLifecycleOwner,
        workspaceURL: @escaping @Sendable (WorkspaceModel) -> URL? = { _ in nil },
        indexURL: @escaping @Sendable () -> URL? = { nil }
    ) {
        self.load = load
        self.lifecycleOwner = lifecycleOwner
        self.workspaceURL = workspaceURL
        self.indexURL = indexURL
    }
}

package actor RepoPromptCoreSession {
    private let ownershipLease: RepoPromptCoreSessionOwnershipLease
    private let releaseOwnership: @Sendable (RepoPromptCoreSessionOwnershipLease) async -> Void
    private let sessionID: WorkspaceSessionID
    private let controller: WorkspaceSessionController
    private let persistence: WorkspaceSessionPersistenceCoordinator
    private let dependencies: RepoPromptCoreSessionDependencies
    private let resultCacheLimit = 256

    private var hydrationTask: Task<WorkspaceSessionHydrationResult, Never>?
    private var teardownTask: Task<Void, Never>?
    private var inFlightCommands: [UUID: Task<WorkspaceSessionCommandResult, Never>] = [:]
    private var resultCache: [UUID: WorkspaceSessionCommandResult] = [:]
    private var resultOrder: [UUID] = []
    private var nextLifecycleGeneration: UInt64 = 1
    private var activeLifecycleGeneration: UInt64?
    private var isShuttingDown = false

    package init(
        constructionKey _: RepoPromptCoreSessionConstructionKey,
        ownershipLease: RepoPromptCoreSessionOwnershipLease,
        releaseOwnership: @escaping @Sendable (RepoPromptCoreSessionOwnershipLease) async -> Void,
        sessionID: WorkspaceSessionID,
        revisionAllocator: any WorkspaceSelectionRevisionAllocating,
        persistence: WorkspaceSessionPersistenceCoordinator,
        dependencies: RepoPromptCoreSessionDependencies
    ) {
        self.ownershipLease = ownershipLease
        self.releaseOwnership = releaseOwnership
        self.sessionID = sessionID
        controller = WorkspaceSessionController(
            constructionKey: WorkspaceSessionControllerConstructionKey(),
            sessionID: sessionID,
            revisionAllocator: revisionAllocator
        )
        self.persistence = persistence
        self.dependencies = dependencies
    }

    package nonisolated func makeHandle() -> RepoPromptCoreSessionHandle {
        RepoPromptCoreSessionHandle(
            constructionKey: RepoPromptCoreSessionHandleConstructionKey(),
            sessionID: sessionID,
            query: dependencies.lifecycleOwner.makeQueryCapability(),
            currentSnapshot: { [controller] in await controller.currentSnapshot() },
            observations: { [controller] sequence in await controller.observations(after: sequence) },
            admit: { [controller] in await controller.admit() },
            execute: { [weak self] command in
                guard let self else { return .notReady(.closed) }
                return await execute(command)
            },
            capturePrompt: { [weak self] admission, request in
                guard let self else { return .unavailable(.closedSession) }
                return await capturePromptFactualContext(admission: admission, request: request)
            },
            shutdown: { [weak self] in await self?.shutdown() }
        )
    }

    package func capturePromptFactualContext(
        admission: WorkspaceSessionAdmissionToken,
        request: PromptFactualCaptureRequest
    ) async -> PromptFactualCaptureOutcome {
        guard !isShuttingDown else { return .unavailable(.closedSession) }
        guard await validatesPromptAdmission(admission) else { return .unavailable(.staleGeneration) }
        var outcome = await dependencies.lifecycleOwner.capturePromptFactualContext(request)
        if case .unavailable(.staleGeneration) = outcome,
           await validatesPromptAdmission(admission)
        {
            outcome = await dependencies.lifecycleOwner.capturePromptFactualContext(request)
        }
        guard !Task.isCancelled else { return .cancelled }
        guard await validatesPromptAdmission(admission) else { return .unavailable(.staleGeneration) }
        return outcome
    }

    private func validatesPromptAdmission(_ admission: WorkspaceSessionAdmissionToken) async -> Bool {
        guard case let .admitted(current) = await controller.admit() else { return false }
        return current.sessionID == admission.sessionID
            && current.activationID == admission.activationID
            && current.admittedGeneration == admission.admittedGeneration
            && current.snapshotSequence >= admission.snapshotSequence
    }

    package func hydrate() async -> WorkspaceSessionHydrationResult {
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
        guard await controller.beginHydration() else {
            return await WorkspaceSessionHydrationResult.alreadyHydrated(controller.currentSnapshot())
        }
        var generation: UInt64?
        do {
            let input = try await dependencies.load()
            let activeWorkspace = selectedActiveWorkspace(from: input)
            let allocated = allocateLifecycleGeneration()
            generation = allocated
            let lifecycleReadiness = try await dependencies.lifecycleOwner.hydrate(
                workspace: activeWorkspace,
                generation: allocated
            )
            try validate(
                lifecycleReadiness,
                expectedWorkspaceID: activeWorkspace?.id,
                expectedGeneration: allocated
            )
            guard !isShuttingDown, !Task.isCancelled else {
                try? await dependencies.lifecycleOwner.unload(generation: allocated)
                return .failed(WorkspaceSessionFailure("session hydration was cancelled"))
            }
            activeLifecycleGeneration = allocated
            return await controller.completeHydration(input, lifecycleReadiness: lifecycleReadiness)
        } catch {
            if let generation {
                try? await dependencies.lifecycleOwner.unload(generation: generation)
            }
            return await controller.failHydration(failure(from: error))
        }
    }

    package func acknowledgeFirstSnapshotApplied(
        sequence: UInt64
    ) async -> WorkspaceSessionActivationResult {
        await controller.activate(appliedSnapshotSequence: sequence)
    }

    package func execute(
        _ envelope: WorkspaceSessionCommandEnvelope
    ) async -> WorkspaceSessionCommandResult {
        if let cached = resultCache[envelope.commandID] { return cached }
        if let task = inFlightCommands[envelope.commandID] { return await task.value }
        let task = Task<WorkspaceSessionCommandResult, Never> { [weak self] in
            guard let self else { return .notReady(.closed) }
            return await executeUncached(envelope)
        }
        inFlightCommands[envelope.commandID] = task
        let result = await task.value
        inFlightCommands.removeValue(forKey: envelope.commandID)
        cache(result, for: envelope.commandID)
        return result
    }

    private func executeUncached(
        _ envelope: WorkspaceSessionCommandEnvelope
    ) async -> WorkspaceSessionCommandResult {
        guard !isShuttingDown else { return .notReady(.closing) }
        switch envelope.command {
        case .persistence(.saveIndex):
            return await executeIndexPersistence(envelope)
        case let .persistence(.saveWorkspace(workspaceID)),
             let .persistence(.flushWorkspace(workspaceID)):
            return await executePersistence(envelope, workspaceID: workspaceID)
        case let .persistence(.reloadWorkspace(workspaceID)):
            return await executeWorkspaceReload(envelope, workspaceID: workspaceID)
        case .persistence(.reloadIndex):
            return await executeIndexReload(envelope)
        case let .switchWorkspace(command):
            return await executeSwitch(command, envelope: envelope)
        case let .refresh(command):
            return await executeRefresh(command, envelope: envelope)
        case let .workspace(.replaceOrderedRoots(workspaceID, roots)):
            return await executeRootReplacement(
                workspaceID: workspaceID,
                roots: roots,
                envelope: envelope
            )
        default:
            return await controller.execute(envelope)
        }
    }

    private func executeSwitch(
        _ command: WorkspaceSwitchCommand,
        envelope: WorkspaceSessionCommandEnvelope
    ) async -> WorkspaceSessionCommandResult {
        let targetGeneration = allocateLifecycleGeneration()
        let preparation = await controller.prepareSwitch(
            command,
            envelope: envelope,
            lifecycleGeneration: targetGeneration
        )
        guard case let .ready(context) = preparation else {
            if case let .result(result) = preparation { return result }
            return .failed(WorkspaceSessionFailure("invalid switch preparation"))
        }
        if Task.isCancelled {
            return await controller.cancelSwitchBeforeDestructiveBoundary(
                context,
                message: "workspace switch was cancelled before root unload"
            )
        }

        if command.shouldSaveCurrentState, let source = context.sourceWorkspace {
            _ = await controller.updateSwitch(operationID: context.operationID, phase: .flushing)
            let persistenceResult = await persistWorkspaceSnapshot(source.id)
            if let persistenceFailure = await controller.reconcilePersistenceBeforeSwitch(
                operationID: context.operationID,
                workspaceID: source.id,
                result: persistenceResult
            ) {
                return await controller.cancelSwitchBeforeDestructiveBoundary(
                    context,
                    message: persistenceFailure.message
                )
            }
        }
        if Task.isCancelled {
            return await controller.cancelSwitchBeforeDestructiveBoundary(
                context,
                message: "workspace switch was cancelled before root unload"
            )
        }

        _ = await controller.updateSwitch(operationID: context.operationID, phase: .unloadingRoots)
        do {
            if let sourceGeneration = activeLifecycleGeneration {
                try await dependencies.lifecycleOwner.unload(generation: sourceGeneration)
            }
            activeLifecycleGeneration = nil
            _ = await controller.updateSwitch(
                operationID: context.operationID,
                phase: .hydratingRoots,
                destructiveBoundaryCrossed: true
            )
            if Task.isCancelled {
                return await recoverSwitch(
                    context,
                    targetGeneration: targetGeneration,
                    failure: WorkspaceSessionFailure("workspace switch was cancelled after root unload")
                )
            }
            let readiness = try await dependencies.lifecycleOwner.hydrate(
                workspace: context.targetWorkspace,
                generation: targetGeneration
            )
            try validate(
                readiness,
                expectedWorkspaceID: context.targetWorkspace.id,
                expectedGeneration: targetGeneration
            )
            guard !Task.isCancelled, !isShuttingDown else {
                return await recoverSwitch(
                    context,
                    targetGeneration: targetGeneration,
                    failure: WorkspaceSessionFailure("workspace switch was cancelled after target hydration")
                )
            }
            activeLifecycleGeneration = targetGeneration
            return await controller.commitSwitch(
                context,
                envelope: envelope,
                lifecycleReadiness: readiness
            )
        } catch {
            return await recoverSwitch(
                context,
                targetGeneration: targetGeneration,
                failure: failure(from: error)
            )
        }
    }

    private func recoverSwitch(
        _ context: WorkspaceSessionSwitchContext,
        targetGeneration: UInt64,
        failure: WorkspaceSessionFailure
    ) async -> WorkspaceSessionCommandResult {
        try? await dependencies.lifecycleOwner.unload(generation: targetGeneration)
        guard let source = context.sourceWorkspace else {
            return await controller.failSwitchRecovery(context, failure: failure)
        }
        _ = await controller.updateSwitch(
            operationID: context.operationID,
            phase: .recovering,
            destructiveBoundaryCrossed: true
        )
        let recoveryGeneration = allocateLifecycleGeneration()
        do {
            let readiness = try await dependencies.lifecycleOwner.hydrate(
                workspace: source,
                generation: recoveryGeneration
            )
            try validate(
                readiness,
                expectedWorkspaceID: source.id,
                expectedGeneration: recoveryGeneration
            )
            activeLifecycleGeneration = recoveryGeneration
            return await controller.completeSwitchRecovery(
                context,
                lifecycleReadiness: readiness,
                failure: failure
            )
        } catch {
            try? await dependencies.lifecycleOwner.unload(generation: recoveryGeneration)
            return await controller.failSwitchRecovery(
                context,
                failure: WorkspaceSessionFailure(
                    "switch failed (\(failure.message)); recovery failed (\(error.localizedDescription))"
                )
            )
        }
    }

    private func executeRefresh(
        _ command: WorkspaceRefreshCommand,
        envelope: WorkspaceSessionCommandEnvelope
    ) async -> WorkspaceSessionCommandResult {
        let generation = allocateLifecycleGeneration()
        let preparation = await controller.prepareRefresh(
            command,
            envelope: envelope,
            lifecycleGeneration: generation
        )
        guard case let .ready(context) = preparation else {
            if case let .result(result) = preparation { return result }
            return .failed(WorkspaceSessionFailure("invalid refresh preparation"))
        }
        do {
            if let activeLifecycleGeneration {
                try await dependencies.lifecycleOwner.unload(generation: activeLifecycleGeneration)
            }
            activeLifecycleGeneration = nil
            let readiness = try await dependencies.lifecycleOwner.hydrate(
                workspace: context.workspace,
                generation: generation
            )
            try validate(
                readiness,
                expectedWorkspaceID: context.workspace.id,
                expectedGeneration: generation
            )
            activeLifecycleGeneration = generation
            return await controller.finishRefresh(
                context,
                envelope: envelope,
                lifecycleReadiness: readiness
            )
        } catch {
            try? await dependencies.lifecycleOwner.unload(generation: generation)
            let failure = failure(from: error)
            let recoveryGeneration = allocateLifecycleGeneration()
            do {
                let readiness = try await dependencies.lifecycleOwner.hydrate(
                    workspace: context.workspace,
                    generation: recoveryGeneration
                )
                try validate(
                    readiness,
                    expectedWorkspaceID: context.workspace.id,
                    expectedGeneration: recoveryGeneration
                )
                activeLifecycleGeneration = recoveryGeneration
                return await controller.completeRefreshRecovery(
                    context,
                    lifecycleReadiness: readiness,
                    failure: failure
                )
            } catch {
                try? await dependencies.lifecycleOwner.unload(generation: recoveryGeneration)
                return await controller.failRefresh(
                    context,
                    failure: WorkspaceSessionFailure(
                        "refresh failed (\(failure.message)); recovery failed (\(error.localizedDescription))"
                    )
                )
            }
        }
    }

    private func executeRootReplacement(
        workspaceID: UUID,
        roots: [String],
        envelope: WorkspaceSessionCommandEnvelope
    ) async -> WorkspaceSessionCommandResult {
        guard let snapshot = await controller.currentSnapshot(),
              let workspace = snapshot.workspaces.first(where: { $0.id == workspaceID })
        else { return .rejected(.workspaceNotFound(workspaceID)) }
        guard workspace.repoPaths != roots else {
            return await controller.execute(envelope)
        }
        guard snapshot.activeWorkspaceID == workspaceID else {
            return await controller.execute(envelope)
        }

        let generation = allocateLifecycleGeneration()
        let refreshCommand = WorkspaceRefreshCommand(
            workspaceID: workspaceID,
            expectedReadinessGeneration: snapshot.readiness.generation
        )
        let preparation = await controller.prepareRefresh(
            refreshCommand,
            envelope: envelope,
            lifecycleGeneration: generation
        )
        guard case let .ready(context) = preparation else {
            if case let .result(result) = preparation { return result }
            return .failed(WorkspaceSessionFailure("invalid root replacement preparation"))
        }
        var updatedWorkspace = workspace
        updatedWorkspace.repoPaths = roots
        updatedWorkspace.dateModified = Date()
        do {
            if let activeLifecycleGeneration {
                try await dependencies.lifecycleOwner.unload(generation: activeLifecycleGeneration)
            }
            activeLifecycleGeneration = nil
            let readiness = try await dependencies.lifecycleOwner.hydrate(
                workspace: updatedWorkspace,
                generation: generation
            )
            try validate(
                readiness,
                expectedWorkspaceID: workspaceID,
                expectedGeneration: generation
            )
            let mutation = await controller.commitActiveRootReplacement(
                envelope,
                updatedWorkspace: updatedWorkspace,
                lifecycleReadiness: readiness
            )
            if case .committed = mutation {
                activeLifecycleGeneration = generation
                return mutation
            }
            try? await dependencies.lifecycleOwner.unload(generation: generation)
            return mutation
        } catch {
            try? await dependencies.lifecycleOwner.unload(generation: generation)
            let failure = failure(from: error)
            let recoveryGeneration = allocateLifecycleGeneration()
            do {
                let readiness = try await dependencies.lifecycleOwner.hydrate(
                    workspace: context.workspace,
                    generation: recoveryGeneration
                )
                try validate(
                    readiness,
                    expectedWorkspaceID: workspaceID,
                    expectedGeneration: recoveryGeneration
                )
                activeLifecycleGeneration = recoveryGeneration
                return await controller.completeRefreshRecovery(
                    context,
                    lifecycleReadiness: readiness,
                    failure: failure
                )
            } catch {
                try? await dependencies.lifecycleOwner.unload(generation: recoveryGeneration)
                return await controller.failRefresh(
                    context,
                    failure: WorkspaceSessionFailure(
                        "root replacement failed (\(failure.message)); recovery failed (\(error.localizedDescription))"
                    )
                )
            }
        }
    }

    private func executeIndexPersistence(
        _ envelope: WorkspaceSessionCommandEnvelope
    ) async -> WorkspaceSessionCommandResult {
        let preparation = await controller.prepareIndexPersistence(envelope)
        switch preparation {
        case let .result(result):
            return result
        case let .ready(workspaces):
            guard let url = dependencies.indexURL() else {
                return .failed(WorkspaceSessionFailure("workspace index URL is unavailable"))
            }
            let persistenceResult = await persistence.persistIndex(workspaces: workspaces, url: url)
            return await controller.finishIndexPersistence(envelope, result: persistenceResult)
        }
    }

    private func executePersistence(
        _ envelope: WorkspaceSessionCommandEnvelope,
        workspaceID: UUID
    ) async -> WorkspaceSessionCommandResult {
        let preparation = await controller.preparePersistence(envelope, workspaceID: workspaceID)
        switch preparation {
        case let .result(result):
            return result
        case let .ready(workspace, dirtyGeneration, selectionMetadata):
            guard let url = dependencies.workspaceURL(workspace) else {
                return .failed(WorkspaceSessionFailure("workspace storage URL is unavailable"))
            }
            let persistenceResult = await persistence.persist(
                WorkspaceSessionPersistenceRequest(
                    url: url,
                    workspace: workspace,
                    dirtyGeneration: dirtyGeneration,
                    selectionMetadata: selectionMetadata
                )
            )
            return await controller.finishPersistence(
                envelope,
                workspaceID: workspaceID,
                dirtyGeneration: dirtyGeneration,
                result: persistenceResult
            )
        }
    }

    private func executeWorkspaceReload(
        _ envelope: WorkspaceSessionCommandEnvelope,
        workspaceID: UUID
    ) async -> WorkspaceSessionCommandResult {
        if let invalid = await controller.validateReload(envelope, workspaceID: workspaceID) { return invalid }
        guard let snapshot = await controller.currentSnapshot(),
              let workspace = snapshot.workspaces.first(where: { $0.id == workspaceID }),
              let url = dependencies.workspaceURL(workspace)
        else { return .failed(WorkspaceSessionFailure("workspace storage URL is unavailable")) }
        do {
            let reloaded = try await persistence.loadWorkspace(url: url)
            if snapshot.activeWorkspaceID == workspaceID, reloaded != workspace {
                return await executeActiveWorkspaceReload(
                    reloaded,
                    original: workspace,
                    snapshot: snapshot,
                    envelope: envelope
                )
            }
            return await controller.finishWorkspaceReload(
                envelope,
                workspaceID: workspaceID,
                reloadedWorkspace: reloaded
            )
        } catch {
            return .failed(failure(from: error))
        }
    }

    private func executeActiveWorkspaceReload(
        _ reloaded: WorkspaceModel,
        original: WorkspaceModel,
        snapshot: WorkspaceSessionSnapshot,
        envelope: WorkspaceSessionCommandEnvelope
    ) async -> WorkspaceSessionCommandResult {
        let generation = allocateLifecycleGeneration()
        let refreshCommand = WorkspaceRefreshCommand(
            workspaceID: original.id,
            expectedReadinessGeneration: snapshot.readiness.generation
        )
        let preparation = await controller.prepareRefresh(
            refreshCommand,
            envelope: envelope,
            lifecycleGeneration: generation
        )
        guard case let .ready(context) = preparation else {
            if case let .result(result) = preparation { return result }
            return .failed(WorkspaceSessionFailure("invalid workspace reload preparation"))
        }
        do {
            if let activeLifecycleGeneration {
                try await dependencies.lifecycleOwner.unload(generation: activeLifecycleGeneration)
            }
            activeLifecycleGeneration = nil
            let readiness = try await dependencies.lifecycleOwner.hydrate(
                workspace: reloaded,
                generation: generation
            )
            try validate(
                readiness,
                expectedWorkspaceID: reloaded.id,
                expectedGeneration: generation
            )
            let result = await controller.commitActiveWorkspaceReload(
                envelope,
                reloadedWorkspace: reloaded,
                lifecycleReadiness: readiness
            )
            if case .committed = result { activeLifecycleGeneration = generation }
            return result
        } catch {
            try? await dependencies.lifecycleOwner.unload(generation: generation)
            let reloadFailure = failure(from: error)
            let recoveryGeneration = allocateLifecycleGeneration()
            do {
                let readiness = try await dependencies.lifecycleOwner.hydrate(
                    workspace: original,
                    generation: recoveryGeneration
                )
                try validate(
                    readiness,
                    expectedWorkspaceID: original.id,
                    expectedGeneration: recoveryGeneration
                )
                activeLifecycleGeneration = recoveryGeneration
                return await controller.completeRefreshRecovery(
                    context,
                    lifecycleReadiness: readiness,
                    failure: reloadFailure
                )
            } catch {
                try? await dependencies.lifecycleOwner.unload(generation: recoveryGeneration)
                return await controller.failRefresh(
                    context,
                    failure: WorkspaceSessionFailure(
                        "workspace reload failed (\(reloadFailure.message)); recovery failed (\(error.localizedDescription))"
                    )
                )
            }
        }
    }

    private func executeIndexReload(
        _ envelope: WorkspaceSessionCommandEnvelope
    ) async -> WorkspaceSessionCommandResult {
        if let invalid = await controller.validateReload(envelope) { return invalid }
        do {
            let input = try await dependencies.load()
            return await controller.finishIndexReload(envelope, input: input)
        } catch {
            return .failed(failure(from: error))
        }
    }

    private func persistWorkspaceSnapshot(_ workspaceID: UUID) async -> WorkspacePersistenceWriteResult {
        guard let snapshot = await controller.currentSnapshot(),
              let workspace = snapshot.workspaces.first(where: { $0.id == workspaceID }),
              let url = dependencies.workspaceURL(workspace)
        else { return .failed("workspace storage URL is unavailable") }
        let tabID = workspace.activeComposeTabID ?? workspace.composeTabs.first?.id
        let selectionMetadata = tabID.flatMap { tabID -> WorkspacePersistenceSelectionMetadata? in
            guard let selection = workspace.composeTabs.first(where: { $0.id == tabID })?.selection else { return nil }
            let key = WorkspaceTabSelectionKey(workspaceID: workspaceID, tabID: tabID)
            let revision = snapshot.selectionRevisions[key, default: 0]
            guard revision > 0 else { return nil }
            return WorkspacePersistenceSelectionMetadata(key: key, revision: revision, selection: selection)
        }
        return await persistence.persist(
            WorkspaceSessionPersistenceRequest(
                url: url,
                workspace: workspace,
                dirtyGeneration: snapshot.dirtyGenerations[workspaceID, default: 0],
                selectionMetadata: selectionMetadata
            )
        )
    }

    package func shutdown() async {
        if let teardownTask {
            await teardownTask.value
            return
        }
        isShuttingDown = true
        let hydrationTask = hydrationTask
        let commandTasks = Array(inFlightCommands.values)
        let ownershipLease = ownershipLease
        let releaseOwnership = releaseOwnership
        let task = Task { [weak self, controller, lifecycleOwner = dependencies.lifecycleOwner] in
            await controller.shutdown()
            hydrationTask?.cancel()
            _ = await hydrationTask?.value
            commandTasks.forEach { $0.cancel() }
            for commandTask in commandTasks {
                _ = await commandTask.value
            }
            guard let self else {
                await lifecycleOwner.close()
                await releaseOwnership(ownershipLease)
                return
            }
            let generation = await activeLifecycleGeneration
            if let generation {
                try? await lifecycleOwner.unload(generation: generation)
            }
            await lifecycleOwner.close()
            await releaseOwnership(ownershipLease)
        }
        teardownTask = task
        await task.value
    }

    private func selectedActiveWorkspace(from input: WorkspaceSessionHydrationInput) -> WorkspaceModel? {
        if let activeID = input.activeWorkspaceID,
           let requested = input.workspaces.first(where: { $0.id == activeID })
        {
            return requested
        }
        return input.workspaces.first
    }

    private func allocateLifecycleGeneration() -> UInt64 {
        let generation = nextLifecycleGeneration
        nextLifecycleGeneration &+= 1
        if nextLifecycleGeneration == 0 { nextLifecycleGeneration = 1 }
        return generation
    }

    private func failure(from error: Error) -> WorkspaceSessionFailure {
        if let failure = error as? WorkspaceSessionFailure { return failure }
        return WorkspaceSessionFailure(error.localizedDescription)
    }

    private func validate(
        _ readiness: WorkspaceSessionLifecycleReadiness,
        expectedWorkspaceID: UUID?,
        expectedGeneration: UInt64
    ) throws {
        guard readiness.generation == expectedGeneration else {
            throw WorkspaceSessionFailure(
                "stale lifecycle generation: expected \(expectedGeneration), got \(readiness.generation)"
            )
        }
        guard readiness.workspaceID == expectedWorkspaceID else {
            throw WorkspaceSessionFailure("lifecycle readiness returned the wrong workspace")
        }
    }

    private func cache(_ result: WorkspaceSessionCommandResult, for commandID: UUID) {
        resultCache[commandID] = result
        resultOrder.append(commandID)
        if resultOrder.count > resultCacheLimit {
            let removed = resultOrder.removeFirst()
            resultCache.removeValue(forKey: removed)
        }
    }
}
