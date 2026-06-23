import Foundation

package enum WorkspaceSessionPersistencePreparation: @unchecked Sendable {
    case ready(
        workspace: WorkspaceModel,
        dirtyGeneration: UInt64,
        selectionMetadata: WorkspacePersistenceSelectionMetadata?
    )
    case result(WorkspaceSessionCommandResult)
}

package enum WorkspaceSessionIndexPersistencePreparation: @unchecked Sendable {
    case ready(workspaces: [WorkspaceModel])
    case result(WorkspaceSessionCommandResult)
}

package struct WorkspaceSessionSwitchContext: @unchecked Sendable {
    package let operationID: WorkspaceSwitchOperationID
    package let sourceWorkspace: WorkspaceModel?
    package let targetWorkspace: WorkspaceModel
    package let lifecycleGeneration: UInt64
    package let previousReadiness: WorkspaceSessionReadiness
}

package enum WorkspaceSessionSwitchPreparation: @unchecked Sendable {
    case ready(WorkspaceSessionSwitchContext)
    case result(WorkspaceSessionCommandResult)
}

package struct WorkspaceSessionRefreshContext: @unchecked Sendable {
    package let workspace: WorkspaceModel
    package let lifecycleGeneration: UInt64
    package let previousReadiness: WorkspaceSessionReadiness
}

package enum WorkspaceSessionRefreshPreparation: @unchecked Sendable {
    case ready(WorkspaceSessionRefreshContext)
    case result(WorkspaceSessionCommandResult)
}

package actor WorkspaceSessionController {
    private let sessionID: WorkspaceSessionID
    private let revisionAllocator: any WorkspaceSelectionRevisionAllocating
    private let receiptCacheLimit: Int

    private var workspaces: [WorkspaceModel] = []
    private var activeWorkspaceID: UUID?
    private var stateGeneration: UInt64 = 0
    private var snapshotSequence: UInt64 = 0
    private var selectionRevisions: [WorkspaceTabSelectionKey: UInt64] = [:]
    private var revisedSelections: [WorkspaceTabSelectionKey: StoredSelection] = [:]
    private var dirtyGenerations: [UUID: UInt64] = [:]
    private var savedGenerations: [UUID: UInt64] = [:]
    private var switchState: WorkspaceSwitchState = .idle
    private var readiness = WorkspaceSessionReadiness()
    private var availability: WorkspaceSessionAvailability = .created
    private var activationToken: WorkspaceSessionActivationToken?
    private var firstAuthoritativeSnapshotSequence: UInt64?
    private var hasHydrated = false
    private var latestSnapshot: WorkspaceSessionSnapshot?

    private var receiptCache: [UUID: WorkspaceSessionCommandResult] = [:]
    private var receiptOrder: [UUID] = []
    private var observers: [UUID: AsyncStream<WorkspaceSessionSnapshot>.Continuation] = [:]

    package init(
        constructionKey _: WorkspaceSessionControllerConstructionKey,
        sessionID: WorkspaceSessionID,
        revisionAllocator: any WorkspaceSelectionRevisionAllocating,
        receiptCacheLimit: Int = 256
    ) {
        self.sessionID = sessionID
        self.revisionAllocator = revisionAllocator
        self.receiptCacheLimit = max(1, receiptCacheLimit)
    }

    package func beginHydration() -> Bool {
        guard availability == .created, !hasHydrated else { return false }
        hasHydrated = true
        availability = .hydrating
        publishSnapshot()
        return true
    }

    package func completeHydration(
        _ input: WorkspaceSessionHydrationInput,
        lifecycleReadiness: WorkspaceSessionLifecycleReadiness
    ) -> WorkspaceSessionHydrationResult {
        guard availability == .hydrating else {
            return .alreadyHydrated(latestSnapshot)
        }

        workspaces = input.workspaces
        let requestedActiveID = input.activeWorkspaceID
        if let requestedActiveID, workspaces.contains(where: { $0.id == requestedActiveID }) {
            activeWorkspaceID = requestedActiveID
        } else {
            activeWorkspaceID = workspaces.first?.id
        }
        dirtyGenerations = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, 0) })
        savedGenerations = dirtyGenerations
        stateGeneration = 1
        readiness = WorkspaceSessionReadiness(
            generation: lifecycleReadiness.generation,
            isReady: true,
            catalogGeneration: lifecycleReadiness.catalogGeneration
        )
        availability = .awaitingActivation
        let snapshot = publishSnapshot()
        firstAuthoritativeSnapshotSequence = snapshot.snapshotSequence
        return .awaitingFirstSnapshotApplication(snapshot)
    }

    package func failHydration(_ error: WorkspaceSessionFailure) -> WorkspaceSessionHydrationResult {
        guard availability == .hydrating else {
            return .alreadyHydrated(latestSnapshot)
        }
        availability = .failed(error.message)
        publishSnapshot()
        return .failed(error)
    }

    package func activate(appliedSnapshotSequence: UInt64) -> WorkspaceSessionActivationResult {
        guard availability == .awaitingActivation,
              readiness.isReady,
              let expectedSequence = firstAuthoritativeSnapshotSequence
        else {
            return .notReady(availability)
        }
        guard appliedSnapshotSequence == expectedSequence else {
            return .wrongSnapshot(expected: expectedSequence, actual: appliedSnapshotSequence)
        }

        let token = WorkspaceSessionActivationToken(
            sessionID: sessionID,
            activationID: UUID(),
            firstAuthoritativeGeneration: stateGeneration
        )
        activationToken = token
        availability = .active
        publishSnapshot()
        return .activated(token)
    }

    package func currentSnapshot() -> WorkspaceSessionSnapshot? {
        latestSnapshot
    }

    package func observations(after sequence: UInt64?) -> AsyncStream<WorkspaceSessionSnapshot> {
        let observerID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: WorkspaceSessionSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        observers[observerID] = continuation
        if let latestSnapshot, sequence.map({ latestSnapshot.snapshotSequence > $0 }) ?? true {
            continuation.yield(latestSnapshot)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(observerID) }
        }
        return stream
    }

    package func admit() -> WorkspaceSessionAdmissionResult {
        guard availability == .active, let activationToken else {
            return .notReady(availability)
        }
        return .admitted(
            WorkspaceSessionAdmissionToken(
                sessionID: sessionID,
                activationID: activationToken.activationID,
                admittedGeneration: stateGeneration,
                snapshotSequence: snapshotSequence
            )
        )
    }

    package func execute(_ envelope: WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult {
        if let cached = receiptCache[envelope.commandID] {
            return cached
        }
        guard availability == .active else {
            return cache(.notReady(availability), for: envelope.commandID)
        }
        guard envelope.admissionToken.sessionID == sessionID else {
            return cache(.rejected(.foreignSession), for: envelope.commandID)
        }
        guard let activationToken,
              envelope.admissionToken.activationID == activationToken.activationID
        else {
            return cache(.rejected(.expiredActivation), for: envelope.commandID)
        }
        guard envelope.expectedGeneration == stateGeneration else {
            return cache(
                .stale(
                    latestSnapshot: authoritativeSnapshot(),
                    conflict: WorkspaceSessionConflict(
                        kind: .generation(expected: envelope.expectedGeneration, actual: stateGeneration)
                    )
                ),
                for: envelope.commandID
            )
        }

        let result: WorkspaceSessionCommandResult = switch envelope.command {
        case let .selection(command):
            await executeSelection(command, envelope: envelope)
        case let .selectionAndPatch(command):
            await executeSelectionAndPatch(command, envelope: envelope)
        case let .workspace(command):
            executeWorkspace(command, envelope: envelope)
        case let .composeTab(command):
            executeComposeTab(command, envelope: envelope)
        case let .persistence(command):
            executePersistence(command, envelope: envelope)
        case .switchWorkspace:
            .rejected(.invalidCommand("workspace switching must be orchestrated by the owning session"))
        case .refresh:
            .rejected(.invalidCommand("workspace refresh must be orchestrated by the owning session"))
        }
        return cache(result, for: envelope.commandID)
    }

    package func preparePersistence(
        _ envelope: WorkspaceSessionCommandEnvelope,
        workspaceID: UUID
    ) -> WorkspaceSessionPersistencePreparation {
        if let cached = receiptCache[envelope.commandID] {
            return .result(cached)
        }
        guard availability == .active else {
            return .result(.notReady(availability))
        }
        guard envelope.admissionToken.sessionID == sessionID else {
            return .result(.rejected(.foreignSession))
        }
        guard let activationToken,
              envelope.admissionToken.activationID == activationToken.activationID
        else {
            return .result(.rejected(.expiredActivation))
        }
        guard envelope.expectedGeneration == stateGeneration else {
            return .result(
                .stale(
                    latestSnapshot: authoritativeSnapshot(),
                    conflict: WorkspaceSessionConflict(
                        kind: .generation(expected: envelope.expectedGeneration, actual: stateGeneration)
                    )
                )
            )
        }
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return .result(.rejected(.workspaceNotFound(workspaceID)))
        }
        let dirtyGeneration = dirtyGenerations[workspaceID, default: 0]
        if savedGenerations[workspaceID, default: 0] == dirtyGeneration {
            return .result(
                cache(
                    .unchanged(
                        receipt(
                            for: envelope.commandID,
                            dirtyWorkspaceID: workspaceID,
                            persistence: .written
                        )
                    ),
                    for: envelope.commandID
                )
            )
        }

        var metadata: WorkspacePersistenceSelectionMetadata?
        if let tabID = workspace.activeComposeTabID ?? workspace.composeTabs.first?.id,
           let tab = workspace.composeTabs.first(where: { $0.id == tabID })
        {
            let key = WorkspaceTabSelectionKey(workspaceID: workspaceID, tabID: tabID)
            let revision = selectionRevisions[key, default: 0]
            if revision > 0, revisedSelections[key] == tab.selection {
                metadata = WorkspacePersistenceSelectionMetadata(
                    key: key,
                    revision: revision,
                    selection: tab.selection
                )
            }
        }
        return .ready(
            workspace: workspace,
            dirtyGeneration: dirtyGeneration,
            selectionMetadata: metadata
        )
    }

    package func finishPersistence(
        _ envelope: WorkspaceSessionCommandEnvelope,
        workspaceID: UUID,
        dirtyGeneration: UInt64,
        result: WorkspacePersistenceWriteResult
    ) -> WorkspaceSessionCommandResult {
        if let cached = receiptCache[envelope.commandID] { return cached }
        if let invalid = validateOrReject(envelope) {
            return cache(invalid, for: envelope.commandID)
        }
        let disposition: WorkspaceSessionPersistenceDisposition
        switch result {
        case let .written(writtenGeneration, _):
            if writtenGeneration >= dirtyGeneration {
                savedGenerations[workspaceID] = max(
                    savedGenerations[workspaceID, default: 0],
                    dirtyGeneration
                )
                disposition = .written
            } else {
                disposition = .suppressedByNewerState
            }
        case .suppressedByNewerDisk:
            disposition = .suppressedByNewerState
        case .skippedEphemeral:
            disposition = .notRequested
        case .normalizationCompareAndSwapFailed:
            disposition = .suppressedByNewerState
        case let .failed(message):
            return cache(.failed(WorkspaceSessionFailure(message)), for: envelope.commandID)
        }
        let snapshot = publishSnapshot()
        return cache(
            .committed(
                receipt(
                    for: envelope.commandID,
                    dirtyWorkspaceID: workspaceID,
                    persistence: disposition,
                    snapshotSequence: snapshot.snapshotSequence
                )
            ),
            for: envelope.commandID
        )
    }

    package func prepareIndexPersistence(
        _ envelope: WorkspaceSessionCommandEnvelope
    ) -> WorkspaceSessionIndexPersistencePreparation {
        if let cached = receiptCache[envelope.commandID] { return .result(cached) }
        guard availability == .active else { return .result(.notReady(availability)) }
        guard envelope.admissionToken.sessionID == sessionID else { return .result(.rejected(.foreignSession)) }
        guard let activationToken,
              envelope.admissionToken.activationID == activationToken.activationID
        else { return .result(.rejected(.expiredActivation)) }
        guard envelope.expectedGeneration == stateGeneration else {
            return .result(
                .stale(
                    latestSnapshot: authoritativeSnapshot(),
                    conflict: WorkspaceSessionConflict(
                        kind: .generation(expected: envelope.expectedGeneration, actual: stateGeneration)
                    )
                )
            )
        }
        return .ready(workspaces: workspaces)
    }

    package func finishIndexPersistence(
        _ envelope: WorkspaceSessionCommandEnvelope,
        result: WorkspacePersistenceWriteResult
    ) -> WorkspaceSessionCommandResult {
        if let cached = receiptCache[envelope.commandID] { return cached }
        if let invalid = validateOrReject(envelope) {
            return cache(invalid, for: envelope.commandID)
        }
        let disposition: WorkspaceSessionPersistenceDisposition
        switch result {
        case .written: disposition = .written
        case .suppressedByNewerDisk, .normalizationCompareAndSwapFailed: disposition = .suppressedByNewerState
        case .skippedEphemeral: disposition = .notRequested
        case let .failed(message): return cache(.failed(WorkspaceSessionFailure(message)), for: envelope.commandID)
        }
        return cache(
            .committed(receipt(for: envelope.commandID, persistence: disposition)),
            for: envelope.commandID
        )
    }

    package func validateReload(
        _ envelope: WorkspaceSessionCommandEnvelope,
        workspaceID: UUID? = nil
    ) -> WorkspaceSessionCommandResult? {
        if let invalid = validateOrReject(envelope) { return invalid }
        if let workspaceID, !workspaces.contains(where: { $0.id == workspaceID }) {
            return .rejected(.workspaceNotFound(workspaceID))
        }
        return nil
    }

    package func finishWorkspaceReload(
        _ envelope: WorkspaceSessionCommandEnvelope,
        workspaceID: UUID,
        reloadedWorkspace: WorkspaceModel
    ) -> WorkspaceSessionCommandResult {
        if let invalid = validateOrReject(envelope) { return invalid }
        guard reloadedWorkspace.id == workspaceID else {
            return .rejected(.invalidCommand("reloaded workspace identity changed"))
        }
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return .rejected(.workspaceNotFound(workspaceID))
        }
        guard workspaces[index] != reloadedWorkspace else {
            return .unchanged(receipt(for: envelope.commandID))
        }
        workspaces[index] = reloadedWorkspace
        selectionRevisions = selectionRevisions.filter { $0.key.workspaceID != workspaceID }
        revisedSelections = revisedSelections.filter { $0.key.workspaceID != workspaceID }
        dirtyGenerations[workspaceID] = 0
        savedGenerations[workspaceID] = 0
        advanceCanonicalState(dirtyWorkspaceID: nil)
        let snapshot = publishSnapshot()
        return .committed(receipt(for: envelope.commandID, snapshotSequence: snapshot.snapshotSequence))
    }

    package func finishIndexReload(
        _ envelope: WorkspaceSessionCommandEnvelope,
        input: WorkspaceSessionHydrationInput
    ) -> WorkspaceSessionCommandResult {
        if let invalid = validateOrReject(envelope) { return invalid }
        guard let currentActiveID = activeWorkspaceID,
              input.workspaces.contains(where: { $0.id == currentActiveID })
        else {
            return .rejected(.invalidCommand("index reload cannot remove the active workspace"))
        }
        guard workspaces != input.workspaces else {
            return .unchanged(receipt(for: envelope.commandID))
        }
        workspaces = input.workspaces
        activeWorkspaceID = currentActiveID
        selectionRevisions = selectionRevisions.filter { key, _ in
            input.workspaces.contains(where: { $0.id == key.workspaceID })
        }
        revisedSelections = revisedSelections.filter { key, _ in
            input.workspaces.contains(where: { $0.id == key.workspaceID })
        }
        let workspaceIDs = Set(input.workspaces.map(\.id))
        dirtyGenerations = dirtyGenerations.filter { workspaceIDs.contains($0.key) }
        savedGenerations = savedGenerations.filter { workspaceIDs.contains($0.key) }
        for workspaceID in workspaceIDs {
            if dirtyGenerations[workspaceID] == nil { dirtyGenerations[workspaceID] = 0 }
            if savedGenerations[workspaceID] == nil { savedGenerations[workspaceID] = 0 }
        }
        advanceCanonicalState(dirtyWorkspaceID: nil)
        let snapshot = publishSnapshot()
        return .committed(receipt(for: envelope.commandID, snapshotSequence: snapshot.snapshotSequence))
    }

    package func shutdown() {
        guard availability != .closed, availability != .closing else { return }
        availability = .closing
        activationToken = nil
        publishSnapshot()
        availability = .closed
        publishSnapshot()
        let currentObservers = observers.values
        observers.removeAll()
        for continuation in currentObservers {
            continuation.finish()
        }
    }

    private func executeSelection(
        _ command: WorkspaceSelectionCommand,
        envelope: WorkspaceSessionCommandEnvelope
    ) async -> WorkspaceSessionCommandResult {
        let key = WorkspaceTabSelectionKey(workspaceID: command.workspaceID, tabID: command.tabID)
        let currentRevision = selectionRevisions[key, default: 0]
        guard command.expectedRevision == currentRevision else {
            return .stale(
                latestSnapshot: authoritativeSnapshot(),
                conflict: WorkspaceSessionConflict(
                    kind: .selectionRevision(
                        key: key,
                        expected: command.expectedRevision,
                        actual: currentRevision
                    )
                )
            )
        }
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == command.workspaceID }) else {
            return .rejected(.workspaceNotFound(command.workspaceID))
        }
        guard let tabIndex = workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == command.tabID }) else {
            return .rejected(.tabNotFound(workspaceID: command.workspaceID, tabID: command.tabID))
        }
        let oldSelection = workspaces[workspaceIndex].composeTabs[tabIndex].selection
        guard oldSelection != command.selection else {
            return .unchanged(receipt(for: envelope.commandID, selectionRevision: currentRevision))
        }

        let allocatedRevision = await revisionAllocator.allocate()

        guard availability == .active else {
            return .notReady(availability)
        }
        guard envelope.expectedGeneration == stateGeneration else {
            return .stale(
                latestSnapshot: authoritativeSnapshot(),
                conflict: WorkspaceSessionConflict(
                    kind: .generation(expected: envelope.expectedGeneration, actual: stateGeneration)
                )
            )
        }
        guard command.expectedRevision == selectionRevisions[key, default: 0] else {
            return .stale(
                latestSnapshot: authoritativeSnapshot(),
                conflict: WorkspaceSessionConflict(
                    kind: .selectionRevision(
                        key: key,
                        expected: command.expectedRevision,
                        actual: selectionRevisions[key, default: 0]
                    )
                )
            )
        }
        guard let refreshedWorkspaceIndex = workspaces.firstIndex(where: { $0.id == command.workspaceID }),
              let refreshedTabIndex = workspaces[refreshedWorkspaceIndex].composeTabs.firstIndex(where: { $0.id == command.tabID })
        else {
            return .rejected(.tabNotFound(workspaceID: command.workspaceID, tabID: command.tabID))
        }

        workspaces[refreshedWorkspaceIndex].composeTabs[refreshedTabIndex].selection = command.selection
        workspaces[refreshedWorkspaceIndex].composeTabs[refreshedTabIndex].lastModified = Date()
        selectionRevisions[key] = allocatedRevision
        revisedSelections[key] = command.selection
        advanceCanonicalState(dirtyWorkspaceID: command.workspaceID)
        let snapshot = publishSnapshot()
        return .committed(
            receipt(
                for: envelope.commandID,
                selectionRevision: allocatedRevision,
                dirtyWorkspaceID: command.workspaceID,
                snapshotSequence: snapshot.snapshotSequence
            )
        )
    }

    private func executeSelectionAndPatch(
        _ command: WorkspaceSelectionAndTabPatchCommand,
        envelope: WorkspaceSessionCommandEnvelope
    ) async -> WorkspaceSessionCommandResult {
        let selection = command.selection
        let key = WorkspaceTabSelectionKey(workspaceID: selection.workspaceID, tabID: selection.tabID)
        let currentRevision = selectionRevisions[key, default: 0]
        guard selection.expectedRevision == currentRevision else {
            return .stale(
                latestSnapshot: authoritativeSnapshot(),
                conflict: WorkspaceSessionConflict(
                    kind: .selectionRevision(key: key, expected: selection.expectedRevision, actual: currentRevision)
                )
            )
        }
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == selection.workspaceID }),
              let tabIndex = workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == selection.tabID })
        else {
            return .rejected(.tabNotFound(workspaceID: selection.workspaceID, tabID: selection.tabID))
        }
        let currentTab = workspaces[workspaceIndex].composeTabs[tabIndex]
        var proposedTab = command.patch.applying(to: currentTab)
        proposedTab.selection = selection.selection
        guard proposedTab != currentTab else {
            return .unchanged(receipt(for: envelope.commandID, selectionRevision: currentRevision))
        }

        let selectionChanged = proposedTab.selection != currentTab.selection
        let allocatedRevision = selectionChanged ? await revisionAllocator.allocate() : currentRevision
        guard availability == .active,
              envelope.expectedGeneration == stateGeneration,
              selection.expectedRevision == selectionRevisions[key, default: 0],
              let refreshedWorkspaceIndex = workspaces.firstIndex(where: { $0.id == selection.workspaceID }),
              let refreshedTabIndex = workspaces[refreshedWorkspaceIndex].composeTabs.firstIndex(where: { $0.id == selection.tabID })
        else {
            return .stale(
                latestSnapshot: authoritativeSnapshot(),
                conflict: WorkspaceSessionConflict(
                    kind: .selectionRevision(
                        key: key,
                        expected: selection.expectedRevision,
                        actual: selectionRevisions[key, default: 0]
                    )
                )
            )
        }

        let refreshedTab = workspaces[refreshedWorkspaceIndex].composeTabs[refreshedTabIndex]
        proposedTab = command.patch.applying(to: refreshedTab)
        proposedTab.selection = selection.selection
        workspaces[refreshedWorkspaceIndex].composeTabs[refreshedTabIndex] = proposedTab
        if selectionChanged {
            selectionRevisions[key] = allocatedRevision
            revisedSelections[key] = selection.selection
        }
        workspaces[refreshedWorkspaceIndex].dateModified = max(
            workspaces[refreshedWorkspaceIndex].dateModified,
            proposedTab.lastModified
        )
        advanceCanonicalState(dirtyWorkspaceID: selection.workspaceID)
        let snapshot = publishSnapshot()
        return .committed(
            receipt(
                for: envelope.commandID,
                selectionRevision: allocatedRevision,
                dirtyWorkspaceID: selection.workspaceID,
                snapshotSequence: snapshot.snapshotSequence
            )
        )
    }

    private func executeWorkspace(
        _ command: WorkspaceCommand,
        envelope: WorkspaceSessionCommandEnvelope
    ) -> WorkspaceSessionCommandResult {
        var nextWorkspaces = workspaces
        var nextActiveID = activeWorkspaceID
        var dirtyWorkspaceID: UUID?

        switch command {
        case let .create(workspace, makeActive):
            guard !makeActive || nextActiveID == nil else {
                return .rejected(.invalidCommand("workspace activation requires a lifecycle switch command"))
            }
            guard !nextWorkspaces.contains(where: { $0.id == workspace.id }) else {
                return .rejected(.duplicateWorkspace(workspace.id))
            }
            nextWorkspaces.append(workspace)
            if makeActive || nextActiveID == nil { nextActiveID = workspace.id }
            dirtyWorkspaceID = workspace.id
        case let .delete(workspaceID):
            guard nextWorkspaces.contains(where: { $0.id == workspaceID }) else {
                return .rejected(.workspaceNotFound(workspaceID))
            }
            guard nextWorkspaces.count > 1 else { return .rejected(.cannotDeleteLastWorkspace) }
            guard nextActiveID != workspaceID else {
                return .rejected(.invalidCommand("active workspace deletion requires a lifecycle switch first"))
            }
            nextWorkspaces.removeAll { $0.id == workspaceID }
        case let .replace(workspace):
            guard let index = nextWorkspaces.firstIndex(where: { $0.id == workspace.id }) else {
                return .rejected(.workspaceNotFound(workspace.id))
            }
            guard nextWorkspaces[index].composeTabs == workspace.composeTabs,
                  nextWorkspaces[index].activeComposeTabID == workspace.activeComposeTabID,
                  nextWorkspaces[index].stashedTabs == workspace.stashedTabs,
                  nextWorkspaces[index].repoPaths == workspace.repoPaths
            else {
                return .rejected(.invalidCommand(
                    "workspace replacement cannot bypass compose-tab, selection, or root lifecycle commands"
                ))
            }
            guard nextWorkspaces[index] != workspace else {
                return .unchanged(receipt(for: envelope.commandID))
            }
            nextWorkspaces[index] = workspace
            dirtyWorkspaceID = workspace.id
        case let .replaceOrderedRoots(workspaceID, roots):
            guard let index = nextWorkspaces.firstIndex(where: { $0.id == workspaceID }) else {
                return .rejected(.workspaceNotFound(workspaceID))
            }
            guard nextWorkspaces[index].repoPaths != roots else {
                return .unchanged(receipt(for: envelope.commandID))
            }
            nextWorkspaces[index].repoPaths = roots
            nextWorkspaces[index].dateModified = Date()
            dirtyWorkspaceID = workspaceID
        case let .setActive(workspaceID):
            guard nextWorkspaces.contains(where: { $0.id == workspaceID }) else {
                return .rejected(.workspaceNotFound(workspaceID))
            }
            guard nextActiveID != workspaceID else { return .unchanged(receipt(for: envelope.commandID)) }
            return .rejected(.invalidCommand("workspace activation requires a lifecycle switch command"))
        }

        workspaces = nextWorkspaces
        activeWorkspaceID = nextActiveID
        if case let .delete(workspaceID) = command {
            dirtyGenerations.removeValue(forKey: workspaceID)
            savedGenerations.removeValue(forKey: workspaceID)
            selectionRevisions = selectionRevisions.filter { $0.key.workspaceID != workspaceID }
            revisedSelections = revisedSelections.filter { $0.key.workspaceID != workspaceID }
        }
        advanceCanonicalState(dirtyWorkspaceID: dirtyWorkspaceID)
        let snapshot = publishSnapshot()
        return .committed(
            receipt(
                for: envelope.commandID,
                dirtyWorkspaceID: dirtyWorkspaceID,
                snapshotSequence: snapshot.snapshotSequence
            )
        )
    }

    private func executeComposeTab(
        _ command: ComposeTabCommand,
        envelope: WorkspaceSessionCommandEnvelope
    ) -> WorkspaceSessionCommandResult {
        let workspaceID: UUID = switch command {
        case let .create(id, _, _), let .patchTitle(id, _, _, _), let .patch(id, _, _),
             let .patchStashed(id, _, _), let .remove(id, _),
             let .activate(id, _), let .reorder(id, _), let .stash(id, _, _, _), let .restore(id, _),
             let .deleteStashed(id, _):
            id
        }
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return .rejected(.workspaceNotFound(workspaceID))
        }
        var workspace = workspaces[workspaceIndex]

        switch command {
        case let .create(_, tab, makeActive):
            guard !workspace.composeTabs.contains(where: { $0.id == tab.id }) else {
                return .rejected(.duplicateTab(workspaceID: workspaceID, tabID: tab.id))
            }
            workspace.composeTabs.append(tab)
            if makeActive { workspace.activeComposeTabID = tab.id }
        case let .patchTitle(_, tabID, name, lastModified):
            guard let tabIndex = workspace.composeTabs.firstIndex(where: { $0.id == tabID }) else {
                return .rejected(.tabNotFound(workspaceID: workspaceID, tabID: tabID))
            }
            guard workspace.composeTabs[tabIndex].name != name else {
                return .unchanged(receipt(for: envelope.commandID))
            }
            workspace.composeTabs[tabIndex].name = name
            workspace.composeTabs[tabIndex].lastModified = lastModified
        case let .patch(_, tabID, patch):
            guard let tabIndex = workspace.composeTabs.firstIndex(where: { $0.id == tabID }) else {
                return .rejected(.tabNotFound(workspaceID: workspaceID, tabID: tabID))
            }
            let updated = patch.applying(to: workspace.composeTabs[tabIndex])
            guard workspace.composeTabs[tabIndex] != updated else {
                return .unchanged(receipt(for: envelope.commandID))
            }
            workspace.composeTabs[tabIndex] = updated
        case let .patchStashed(_, stashedTabID, patch):
            guard let stashIndex = workspace.stashedTabs.firstIndex(where: { $0.id == stashedTabID }) else {
                return .rejected(.invalidCommand("stashed tab not found"))
            }
            let updated = patch.applying(to: workspace.stashedTabs[stashIndex].tab)
            guard workspace.stashedTabs[stashIndex].tab != updated else {
                return .unchanged(receipt(for: envelope.commandID))
            }
            workspace.stashedTabs[stashIndex].tab = updated
        case let .remove(_, tabID):
            guard workspace.composeTabs.contains(where: { $0.id == tabID }) else {
                return .rejected(.tabNotFound(workspaceID: workspaceID, tabID: tabID))
            }
            workspace.composeTabs.removeAll { $0.id == tabID }
            _ = workspace.normalizeComposeTabInvariants()
        case let .activate(_, tabID):
            guard workspace.composeTabs.contains(where: { $0.id == tabID }) else {
                return .rejected(.tabNotFound(workspaceID: workspaceID, tabID: tabID))
            }
            guard workspace.activeComposeTabID != tabID else {
                return .unchanged(receipt(for: envelope.commandID))
            }
            workspace.activeComposeTabID = tabID
        case let .reorder(_, orderedTabIDs):
            guard Set(orderedTabIDs) == Set(workspace.composeTabs.map(\.id)),
                  orderedTabIDs.count == workspace.composeTabs.count
            else {
                return .rejected(.invalidCommand("reorder must contain every tab exactly once"))
            }
            let byID = Dictionary(uniqueKeysWithValues: workspace.composeTabs.map { ($0.id, $0) })
            let reordered = orderedTabIDs.compactMap { byID[$0] }
            guard reordered != workspace.composeTabs else {
                return .unchanged(receipt(for: envelope.commandID))
            }
            workspace.composeTabs = reordered
        case let .stash(_, tabID, stashedTabID, stashedAt):
            guard let tabIndex = workspace.composeTabs.firstIndex(where: { $0.id == tabID }) else {
                return .rejected(.tabNotFound(workspaceID: workspaceID, tabID: tabID))
            }
            let tab = workspace.composeTabs.remove(at: tabIndex)
            workspace.stashedTabs.append(StashedTab(id: stashedTabID, tab: tab, stashedAt: stashedAt))
            _ = workspace.normalizeComposeTabInvariants()
        case let .restore(_, stashedTabID):
            guard let stashIndex = workspace.stashedTabs.firstIndex(where: { $0.id == stashedTabID }) else {
                return .rejected(.invalidCommand("stashed tab not found"))
            }
            let stashed = workspace.stashedTabs.remove(at: stashIndex)
            guard !workspace.composeTabs.contains(where: { $0.id == stashed.tab.id }) else {
                return .rejected(.duplicateTab(workspaceID: workspaceID, tabID: stashed.tab.id))
            }
            workspace.composeTabs.append(stashed.tab)
            workspace.activeComposeTabID = stashed.tab.id
        case let .deleteStashed(_, stashedTabIDs):
            let originalCount = workspace.stashedTabs.count
            workspace.stashedTabs.removeAll { stashedTabIDs.contains($0.id) }
            guard workspace.stashedTabs.count != originalCount else {
                return .unchanged(receipt(for: envelope.commandID))
            }
        }

        workspace.dateModified = Date()
        workspaces[workspaceIndex] = workspace
        if case let .remove(_, tabID) = command {
            let key = WorkspaceTabSelectionKey(workspaceID: workspaceID, tabID: tabID)
            selectionRevisions.removeValue(forKey: key)
            revisedSelections.removeValue(forKey: key)
        }
        advanceCanonicalState(dirtyWorkspaceID: workspaceID)
        let snapshot = publishSnapshot()
        return .committed(
            receipt(
                for: envelope.commandID,
                dirtyWorkspaceID: workspaceID,
                snapshotSequence: snapshot.snapshotSequence
            )
        )
    }

    private func executePersistence(
        _ command: WorkspacePersistenceCommand,
        envelope: WorkspaceSessionCommandEnvelope
    ) -> WorkspaceSessionCommandResult {
        switch command {
        case .saveIndex:
            return .rejected(.invalidCommand("index persistence must be orchestrated by the owning session"))
        case let .saveWorkspace(workspaceID), let .flushWorkspace(workspaceID):
            guard workspaces.contains(where: { $0.id == workspaceID }) else {
                return .rejected(.workspaceNotFound(workspaceID))
            }
            let dirty = dirtyGenerations[workspaceID, default: 0]
            guard savedGenerations[workspaceID, default: 0] != dirty else {
                return .unchanged(
                    receipt(
                        for: envelope.commandID,
                        dirtyWorkspaceID: workspaceID,
                        persistence: .written
                    )
                )
            }
            savedGenerations[workspaceID] = dirty
            let snapshot = publishSnapshot()
            return .committed(
                receipt(
                    for: envelope.commandID,
                    dirtyWorkspaceID: workspaceID,
                    persistence: .written,
                    snapshotSequence: snapshot.snapshotSequence
                )
            )
        case .reloadWorkspace, .reloadIndex:
            return .rejected(.invalidCommand("reload must be orchestrated by the owning session"))
        }
    }

    package func prepareSwitch(
        _ command: WorkspaceSwitchCommand,
        envelope: WorkspaceSessionCommandEnvelope,
        lifecycleGeneration: UInt64
    ) -> WorkspaceSessionSwitchPreparation {
        if let invalid = validateOrReject(envelope) { return .result(invalid) }
        guard let target = workspaces.first(where: { $0.id == command.targetWorkspaceID }) else {
            return .result(.rejected(.workspaceNotFound(command.targetWorkspaceID)))
        }
        guard activeWorkspaceID != command.targetWorkspaceID else {
            return .result(.unchanged(receipt(for: envelope.commandID)))
        }
        let operationID = WorkspaceSwitchOperationID()
        let context = WorkspaceSessionSwitchContext(
            operationID: operationID,
            sourceWorkspace: workspaces.first(where: { $0.id == activeWorkspaceID }),
            targetWorkspace: target,
            lifecycleGeneration: lifecycleGeneration,
            previousReadiness: readiness
        )
        availability = .switching
        readiness = WorkspaceSessionReadiness(generation: lifecycleGeneration, isReady: false)
        switchState = WorkspaceSwitchState(
            operationID: operationID,
            phase: .preparing,
            sourceWorkspaceID: activeWorkspaceID,
            targetWorkspaceID: command.targetWorkspaceID,
            reason: command.reason
        )
        publishSnapshot()
        return .ready(context)
    }

    package func updateSwitch(
        operationID: WorkspaceSwitchOperationID,
        phase: WorkspaceSwitchPhase,
        destructiveBoundaryCrossed: Bool? = nil
    ) -> Bool {
        guard availability == .switching, switchState.operationID == operationID else { return false }
        switchState.phase = phase
        if let destructiveBoundaryCrossed {
            switchState.destructiveBoundaryCrossed = destructiveBoundaryCrossed
        }
        publishSnapshot()
        return true
    }

    package func reconcilePersistenceBeforeSwitch(
        operationID: WorkspaceSwitchOperationID,
        workspaceID: UUID,
        result: WorkspacePersistenceWriteResult
    ) -> WorkspaceSessionFailure? {
        guard availability == .switching, switchState.operationID == operationID else {
            return WorkspaceSessionFailure("workspace switch persistence lost ownership")
        }
        switch result {
        case let .written(dirtyGeneration, _):
            savedGenerations[workspaceID] = max(
                savedGenerations[workspaceID, default: 0],
                dirtyGeneration
            )
            publishSnapshot()
            return nil
        case .suppressedByNewerDisk, .normalizationCompareAndSwapFailed, .skippedEphemeral:
            return nil
        case let .failed(message):
            return WorkspaceSessionFailure(message)
        }
    }

    package func commitSwitch(
        _ context: WorkspaceSessionSwitchContext,
        envelope: WorkspaceSessionCommandEnvelope,
        lifecycleReadiness: WorkspaceSessionLifecycleReadiness
    ) -> WorkspaceSessionCommandResult {
        guard availability == .switching, switchState.operationID == context.operationID else {
            return .notReady(availability)
        }
        guard lifecycleReadiness.generation == context.lifecycleGeneration,
              lifecycleReadiness.workspaceID == context.targetWorkspace.id
        else {
            return .stale(
                latestSnapshot: authoritativeSnapshot(),
                conflict: WorkspaceSessionConflict(
                    kind: .readinessGeneration(
                        expected: context.lifecycleGeneration,
                        actual: lifecycleReadiness.generation
                    )
                )
            )
        }
        activeWorkspaceID = context.targetWorkspace.id
        readiness = WorkspaceSessionReadiness(
            generation: lifecycleReadiness.generation,
            isReady: true,
            catalogGeneration: lifecycleReadiness.catalogGeneration
        )
        availability = .active
        switchState.phase = .committed
        switchState.destructiveBoundaryCrossed = true
        switchState.commitBoundaryCrossed = true
        advanceCanonicalState(dirtyWorkspaceID: nil)
        let snapshot = publishSnapshot()
        return .committed(receipt(for: envelope.commandID, snapshotSequence: snapshot.snapshotSequence))
    }

    package func cancelSwitchBeforeDestructiveBoundary(
        _ context: WorkspaceSessionSwitchContext,
        message: String
    ) -> WorkspaceSessionCommandResult {
        guard switchState.operationID == context.operationID,
              !switchState.destructiveBoundaryCrossed
        else { return .notReady(availability) }
        readiness = context.previousReadiness
        availability = .active
        switchState = .idle
        publishSnapshot()
        return .failed(WorkspaceSessionFailure(message))
    }

    package func completeSwitchRecovery(
        _ context: WorkspaceSessionSwitchContext,
        lifecycleReadiness: WorkspaceSessionLifecycleReadiness,
        failure: WorkspaceSessionFailure
    ) -> WorkspaceSessionCommandResult {
        guard switchState.operationID == context.operationID else { return .notReady(availability) }
        guard lifecycleReadiness.workspaceID == context.sourceWorkspace?.id else {
            return failSwitchRecovery(context, failure: WorkspaceSessionFailure(
                "switch failed (\(failure.message)); recovery returned the wrong workspace"
            ))
        }
        activeWorkspaceID = context.sourceWorkspace?.id
        readiness = WorkspaceSessionReadiness(
            generation: lifecycleReadiness.generation,
            isReady: true,
            catalogGeneration: lifecycleReadiness.catalogGeneration
        )
        availability = .active
        switchState.phase = .recovering
        switchState.message = failure.message
        publishSnapshot()
        return .failed(failure)
    }

    package func failSwitchRecovery(
        _ context: WorkspaceSessionSwitchContext,
        failure: WorkspaceSessionFailure
    ) -> WorkspaceSessionCommandResult {
        guard switchState.operationID == context.operationID else { return .notReady(availability) }
        readiness.isReady = false
        readiness.unavailableReason = failure.message
        availability = .failed(failure.message)
        activationToken = nil
        switchState.phase = .failed
        switchState.message = failure.message
        publishSnapshot()
        return .failed(failure)
    }

    package func prepareRefresh(
        _ command: WorkspaceRefreshCommand,
        envelope: WorkspaceSessionCommandEnvelope,
        lifecycleGeneration: UInt64
    ) -> WorkspaceSessionRefreshPreparation {
        if let invalid = validateOrReject(envelope) { return .result(invalid) }
        guard activeWorkspaceID == command.workspaceID,
              let workspace = workspaces.first(where: { $0.id == command.workspaceID })
        else { return .result(.rejected(.workspaceNotFound(command.workspaceID))) }
        guard readiness.generation == command.expectedReadinessGeneration else {
            return .result(.stale(
                latestSnapshot: authoritativeSnapshot(),
                conflict: WorkspaceSessionConflict(
                    kind: .readinessGeneration(
                        expected: command.expectedReadinessGeneration,
                        actual: readiness.generation
                    )
                )
            ))
        }
        let context = WorkspaceSessionRefreshContext(
            workspace: workspace,
            lifecycleGeneration: lifecycleGeneration,
            previousReadiness: readiness
        )
        availability = .switching
        readiness = WorkspaceSessionReadiness(generation: lifecycleGeneration, isReady: false)
        publishSnapshot()
        return .ready(context)
    }

    package func finishRefresh(
        _ context: WorkspaceSessionRefreshContext,
        envelope: WorkspaceSessionCommandEnvelope,
        lifecycleReadiness: WorkspaceSessionLifecycleReadiness
    ) -> WorkspaceSessionCommandResult {
        guard lifecycleReadiness.workspaceID == context.workspace.id,
              lifecycleReadiness.generation == context.lifecycleGeneration
        else {
            return .stale(
                latestSnapshot: authoritativeSnapshot(),
                conflict: WorkspaceSessionConflict(
                    kind: .readinessGeneration(
                        expected: context.lifecycleGeneration,
                        actual: lifecycleReadiness.generation
                    )
                )
            )
        }
        readiness = WorkspaceSessionReadiness(
            generation: lifecycleReadiness.generation,
            isReady: true,
            catalogGeneration: lifecycleReadiness.catalogGeneration
        )
        availability = .active
        let snapshot = publishSnapshot()
        return .committed(receipt(for: envelope.commandID, snapshotSequence: snapshot.snapshotSequence))
    }

    package func completeRefreshRecovery(
        _ context: WorkspaceSessionRefreshContext,
        lifecycleReadiness: WorkspaceSessionLifecycleReadiness,
        failure: WorkspaceSessionFailure
    ) -> WorkspaceSessionCommandResult {
        guard lifecycleReadiness.workspaceID == context.workspace.id else {
            return failRefresh(
                context,
                failure: WorkspaceSessionFailure("refresh recovery returned the wrong workspace")
            )
        }
        readiness = WorkspaceSessionReadiness(
            generation: lifecycleReadiness.generation,
            isReady: true,
            catalogGeneration: lifecycleReadiness.catalogGeneration,
            unavailableReason: failure.message
        )
        availability = .active
        publishSnapshot()
        return .failed(failure)
    }

    package func commitActiveRootReplacement(
        _ envelope: WorkspaceSessionCommandEnvelope,
        updatedWorkspace: WorkspaceModel,
        lifecycleReadiness: WorkspaceSessionLifecycleReadiness
    ) -> WorkspaceSessionCommandResult {
        guard availability == .switching else { return .notReady(availability) }
        guard activeWorkspaceID == updatedWorkspace.id,
              let index = workspaces.firstIndex(where: { $0.id == updatedWorkspace.id })
        else { return .rejected(.workspaceNotFound(updatedWorkspace.id)) }
        guard readiness.generation == lifecycleReadiness.generation,
              lifecycleReadiness.workspaceID == updatedWorkspace.id
        else {
            return .stale(
                latestSnapshot: authoritativeSnapshot(),
                conflict: WorkspaceSessionConflict(
                    kind: .readinessGeneration(
                        expected: readiness.generation,
                        actual: lifecycleReadiness.generation
                    )
                )
            )
        }
        workspaces[index] = updatedWorkspace
        readiness = WorkspaceSessionReadiness(
            generation: lifecycleReadiness.generation,
            isReady: true,
            catalogGeneration: lifecycleReadiness.catalogGeneration
        )
        availability = .active
        advanceCanonicalState(dirtyWorkspaceID: updatedWorkspace.id)
        let snapshot = publishSnapshot()
        return .committed(
            receipt(
                for: envelope.commandID,
                dirtyWorkspaceID: updatedWorkspace.id,
                snapshotSequence: snapshot.snapshotSequence
            )
        )
    }

    package func commitActiveWorkspaceReload(
        _ envelope: WorkspaceSessionCommandEnvelope,
        reloadedWorkspace: WorkspaceModel,
        lifecycleReadiness: WorkspaceSessionLifecycleReadiness
    ) -> WorkspaceSessionCommandResult {
        guard availability == .switching else { return .notReady(availability) }
        guard activeWorkspaceID == reloadedWorkspace.id,
              let index = workspaces.firstIndex(where: { $0.id == reloadedWorkspace.id })
        else { return .rejected(.workspaceNotFound(reloadedWorkspace.id)) }
        guard readiness.generation == lifecycleReadiness.generation,
              lifecycleReadiness.workspaceID == reloadedWorkspace.id
        else {
            return .stale(
                latestSnapshot: authoritativeSnapshot(),
                conflict: WorkspaceSessionConflict(
                    kind: .readinessGeneration(
                        expected: readiness.generation,
                        actual: lifecycleReadiness.generation
                    )
                )
            )
        }
        workspaces[index] = reloadedWorkspace
        selectionRevisions = selectionRevisions.filter { $0.key.workspaceID != reloadedWorkspace.id }
        revisedSelections = revisedSelections.filter { $0.key.workspaceID != reloadedWorkspace.id }
        dirtyGenerations[reloadedWorkspace.id] = 0
        savedGenerations[reloadedWorkspace.id] = 0
        readiness = WorkspaceSessionReadiness(
            generation: lifecycleReadiness.generation,
            isReady: true,
            catalogGeneration: lifecycleReadiness.catalogGeneration
        )
        availability = .active
        advanceCanonicalState(dirtyWorkspaceID: nil)
        let snapshot = publishSnapshot()
        return .committed(receipt(for: envelope.commandID, snapshotSequence: snapshot.snapshotSequence))
    }

    package func failRefresh(
        _ context: WorkspaceSessionRefreshContext,
        failure: WorkspaceSessionFailure
    ) -> WorkspaceSessionCommandResult {
        readiness = WorkspaceSessionReadiness(
            generation: context.lifecycleGeneration,
            isReady: false,
            unavailableReason: failure.message
        )
        availability = .failed(failure.message)
        activationToken = nil
        publishSnapshot()
        return .failed(failure)
    }

    private func advanceCanonicalState(dirtyWorkspaceID: UUID?) {
        stateGeneration &+= 1
        if let dirtyWorkspaceID {
            dirtyGenerations[dirtyWorkspaceID, default: 0] &+= 1
        }
    }

    @discardableResult
    private func publishSnapshot() -> WorkspaceSessionSnapshot {
        snapshotSequence &+= 1
        let snapshot = authoritativeSnapshot()
        latestSnapshot = snapshot
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
        return snapshot
    }

    private func authoritativeSnapshot() -> WorkspaceSessionSnapshot {
        WorkspaceSessionSnapshot(
            sessionID: sessionID,
            snapshotSequence: snapshotSequence,
            stateGeneration: stateGeneration,
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID,
            selectionRevisions: selectionRevisions,
            dirtyGenerations: dirtyGenerations,
            savedGenerations: savedGenerations,
            switchState: switchState,
            readiness: readiness,
            availability: availability
        )
    }

    private func validateOrReject(
        _ envelope: WorkspaceSessionCommandEnvelope
    ) -> WorkspaceSessionCommandResult? {
        guard availability == .active else { return .notReady(availability) }
        guard envelope.admissionToken.sessionID == sessionID else {
            return .rejected(.foreignSession)
        }
        guard let activationToken,
              envelope.admissionToken.activationID == activationToken.activationID
        else { return .rejected(.expiredActivation) }
        guard envelope.expectedGeneration == stateGeneration else {
            return .stale(
                latestSnapshot: authoritativeSnapshot(),
                conflict: WorkspaceSessionConflict(
                    kind: .generation(expected: envelope.expectedGeneration, actual: stateGeneration)
                )
            )
        }
        return nil
    }

    private func receipt(
        for commandID: UUID,
        selectionRevision: UInt64? = nil,
        dirtyWorkspaceID: UUID? = nil,
        persistence: WorkspaceSessionPersistenceDisposition = .notRequested,
        snapshotSequence: UInt64? = nil
    ) -> WorkspaceSessionCommandReceipt {
        guard let activationToken else {
            preconditionFailure("command receipts require an active session activation")
        }
        return WorkspaceSessionCommandReceipt(
            commandID: commandID,
            sessionID: sessionID,
            activationID: activationToken.activationID,
            resultingGeneration: stateGeneration,
            selectionRevision: selectionRevision,
            dirtyGeneration: dirtyWorkspaceID.map { dirtyGenerations[$0, default: 0] },
            persistenceDisposition: persistence,
            snapshotSequence: snapshotSequence ?? self.snapshotSequence
        )
    }

    private func cache(
        _ result: WorkspaceSessionCommandResult,
        for commandID: UUID
    ) -> WorkspaceSessionCommandResult {
        receiptCache[commandID] = result
        receiptOrder.append(commandID)
        if receiptOrder.count > receiptCacheLimit {
            let removed = receiptOrder.removeFirst()
            receiptCache.removeValue(forKey: removed)
        }
        return result
    }

    private func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }
}
