import Foundation

extension AgentSavedSessionTargetLoader {
    /// Read-only catalog inputs, not a second catalog or a window census. The owner supplies live
    /// point reads and a carrier/provenance fence; metadata is never permission to install a writer.
    struct Catalog {
        let workspaces: () -> [WorkspaceModel]
        let currentWorkspace: (UUID) -> WorkspaceModel?
        let currentMetadata: (UUID, UUID) -> LiveMetadata?
        let isCurrent: (Target) -> Bool
    }

    struct RuntimeLoad {
        enum Source: Equatable { case existingWriter, savedPayload }
        let writer: AgentSessionRuntimeStore.Writer
        let source: Source
        /// Hydration may normalize old data. This is a dirty obligation, not a durability receipt.
        let requiresSave: Bool
    }

    struct RuntimeLoadFailure: Error {
        enum Reason: Equatable {
            case lookup(Failure)
            case writerUnavailable(AgentSessionRuntimeStore.Unavailable)
            case commandRejected(AgentSessionRuntimeStore.CommandRejection)
            case occupiedTab
            case suppressed
            case compositionUnavailable
        }

        enum Effects: Equatable {
            case none
            case loadingClaimReleased
            /// Another actor changed our exact object while IO was suspended. Never discard it
            /// or its effects merely to make a failed load look atomic.
            case loadingClaimRetained
            case loadingClaimDisplaced
            case hydratedClaimRetained
        }

        let reason: Reason
        let effects: Effects
    }

    /// Loads exactly one saved payload into the existing runtime authority. No provider starts,
    /// workspace CAS, new lifecycle manager, window construction or presentation publication.
    /// The caller retains the returned writer's scope. An existing writer may belong to a different
    /// scope: reuse that owner, never install a second execution service on the supplied cold scope.
    /// `requiresSave` must be settled by the existing persistence runtime before claiming durability.
    static func loadRuntime(
        sessionID: UUID,
        scope: AgentSessionRuntimeStore.Scope,
        catalog: Catalog,
        storage: AgentSessionStorageInputs,
        selection: (AgentSessionHydrationPayload) -> AgentSessionHydrationRuntime.Selection,
        codexPolicy: (AgentSessionHydrationRuntime.Selection) -> AgentCodexSelectionPolicy,
        isStillAuthorized: () -> Bool,
        readRecord: (UUID, WorkspaceModel) async throws -> AgentSessionMetadataRecord? = {
            try await AgentSessionDataService.shared.metadataRecordForSessionID($0, for: $1)
        },
        readPayload: (AgentSessionHydrationRequest) async throws -> AgentSessionHydrationPayload? = {
            try await AgentSessionDataService.shared.preparePersistedHydration($0)
        }
    ) async -> Result<RuntimeLoad, RuntimeLoadFailure> {
        func failed(_ reason: RuntimeLoadFailure.Reason) -> Result<RuntimeLoad, RuntimeLoadFailure> {
            .failure(.init(reason: reason, effects: .none))
        }
        func available() -> Bool {
            !AgentSessionDeletionRegistry.shared.blocksNewOversight(sessionID: sessionID)
        }
        func existing() -> Result<RuntimeLoad, RuntimeLoadFailure>? {
            switch scope.resolveWriter(sessionID: sessionID, expectedWorkspaceID: storage.workspaceID) {
            case .unavailable(.absent): nil
            case let .unavailable(reason): failed(.writerUnavailable(reason))
            case .conflicting: failed(.lookup(.ambiguous))
            case let .unique(writer):
                switch writer.admitCommand() {
                case let .failure(reason): failed(.commandRejected(reason))
                case .success:
                    .success(.init(writer: writer, source: .existingWriter, requiresSave: writer.session.isDirty))
                }
            }
        }
        guard !Task.isCancelled, isStillAuthorized() else { return failed(.lookup(.changed)) }
        guard available() else { return failed(.lookup(.missing)) }
        if let existing = existing() { return existing }
        guard !storage.isSuppressed() else { return failed(.suppressed) }
        let resolution = await load(
            sessionID: sessionID, workspaces: catalog.workspaces(), readRecord: readRecord,
            currentMetadata: { catalog.currentMetadata(sessionID, $0) },
            currentWorkspace: catalog.currentWorkspace,
            isAvailable: available,
            isCurrent: { isStillAuthorized() && catalog.isCurrent($0) }
        )
        guard !Task.isCancelled, isStillAuthorized() else { return failed(.lookup(.changed)) }
        let target: Target
        switch resolution {
        case let .failure(reason): return failed(.lookup(reason))
        case let .success(value): target = value
        }
        guard target.workspace.id == storage.workspaceID, catalog.isCurrent(target),
              let workspace = storage.workspace, sameStorage(workspace, target.workspace), available()
        else { return failed(.lookup(.changed)) }
        if let existing = existing() { return existing }
        guard !scope.isRetiring, !scope.hasReleasedWriterClaims else { return failed(.commandRejected(.retiring)) }
        guard scope.sessions[target.tab.id] == nil else { return failed(.occupiedTab) }
        guard let composedWorkspace = scope.persistence.composition?.workspace(),
              sameStorage(composedWorkspace, workspace), scope.attachments.configuration != nil
        else {
            return failed(.compositionUnavailable)
        }
        let session = scope.makeSession(tabID: target.tab.id)
        guard scope.permitsBinding(sessionID, on: session) else { return failed(.lookup(.ambiguous)) }
        session.installPersistentSessionBinding(.init(tabID: target.tab.id, sessionID: sessionID, workspaceID: workspace.id))
        var sessions = scope.sessions
        sessions[session.tabID] = session
        scope.replaceSessions(sessions)
        let transition = session.persistentBindingTransitionToken()
        guard let hydration = AgentSessionHydrationRuntime.Attempt.capture(session, in: scope, transition: transition) else {
            // No suspension or external callback separates installation from this refusal.
            var remaining = scope.sessions
            remaining.removeValue(forKey: session.tabID)
            scope.replaceSessions(remaining)
            return .failure(.init(reason: .lookup(.changed), effects: .loadingClaimReleased))
        }
        let writer = hydration.writer

        func failLoading(_ reason: RuntimeLoadFailure.Reason) -> Result<RuntimeLoad, RuntimeLoadFailure> {
            // Release only the clean loading claim we installed. Never evict a successor, a
            // rebound object, a locally modified payload or an independently admitted effect.
            // Raw conflicting claims also prevent cleanup: repairing that corruption must not
            // grant this failed read authority to remove a writer while uniqueness is absent.
            guard scope.sessions[session.tabID] === session else {
                return .failure(.init(reason: reason, effects: .loadingClaimDisplaced))
            }
            guard writer.ownsPersistentClaim, transition.matches(session),
                  !session.isDirty, session.activeRunOwnership == nil, !session.runState.isActive,
                  session.activeComposerSubmitAttempt == nil, !session.terminalCommitInProgress
            else { return .failure(.init(reason: reason, effects: .loadingClaimRetained)) }
            var remaining = scope.sessions
            remaining.removeValue(forKey: session.tabID)
            scope.replaceSessions(remaining)
            return .failure(.init(reason: reason, effects: .loadingClaimReleased))
        }
        let payload: AgentSessionHydrationPayload?
        do {
            payload = try await readPayload(.init(
                workspace: workspace, tabID: session.tabID, sessionID: sessionID,
                resolvedDisplayName: target.entry.name, hasPendingQuestionUI: false,
                transcriptViewportState: .liveBottom, isCompressedHistoryRevealed: false,
                initialPerformanceSnapshot: session.transcriptPerformanceSnapshot
            ))
        } catch {
            return failLoading(.lookup(error is CancellationError || Task.isCancelled ? .changed : .unreadable))
        }
        guard !Task.isCancelled, isStillAuthorized(), available(), !storage.isSuppressed(),
              catalog.isCurrent(target), let current = storage.workspace, sameStorage(current, workspace),
              scope.sessions[session.tabID] === session, transition.matches(session)
        else { return failLoading(.lookup(.changed)) }
        guard hydration.isCurrent else {
            // Diagnose only. Never adopt a freshly resolved writer after the read.
            switch scope.resolveWriter(sessionID: sessionID, expectedWorkspaceID: workspace.id) {
            case .conflicting: return failLoading(.lookup(.ambiguous))
            case let .unavailable(reason): return failLoading(.writerUnavailable(reason))
            case .unique: return failLoading(.lookup(.changed))
            }
        }
        guard let payload else { return failLoading(.lookup(.missing)) }
        // The earlier disk metadata is not a newer placement authority than this payload. Only
        // freshly sampled catalog metadata may override payload placement at this commit point.
        let currentMetadata = catalog.currentMetadata(sessionID, workspace.id)?.entry
        if let currentMetadata, currentMetadata.id != sessionID || currentMetadata.tabID != session.tabID {
            return failLoading(.lookup(.ambiguous))
        }
        let resolvedSelection = selection(payload)
        guard let applied = AgentSessionHydrationRuntime.apply(
            payload, attempt: hydration, selection: resolvedSelection,
            codexPolicy: codexPolicy(resolvedSelection), indexedPlacement: currentMetadata, usage: scope.usage
        ) else { return failLoading(.lookup(.changed)) }
        guard applied.commitReadiness() else {
            return .failure(.init(reason: .lookup(.changed), effects: .hydratedClaimRetained))
        }
        scope.attachments.repairRetainedAttachmentPathsAfterHydration(session, sessionID: sessionID)
        switch writer.admitCommand() {
        case let .failure(reason): return .failure(.init(reason: .commandRejected(reason), effects: .loadingClaimRetained))
        case .success:
            return .success(.init(writer: writer, source: .savedPayload, requiresSave: session.isDirty))
        }
    }

    private static func sameStorage(_ lhs: WorkspaceModel, _ rhs: WorkspaceModel) -> Bool {
        lhs.id == rhs.id && WorkspaceSessionSidecarMigration.workspaceDirectory(
            for: lhs, root: AgentSessionDataService.defaultWorkspaceRootURL()
        ).standardizedFileURL == WorkspaceSessionSidecarMigration.workspaceDirectory(
            for: rhs, root: AgentSessionDataService.defaultWorkspaceRootURL()
        ).standardizedFileURL
    }
}
