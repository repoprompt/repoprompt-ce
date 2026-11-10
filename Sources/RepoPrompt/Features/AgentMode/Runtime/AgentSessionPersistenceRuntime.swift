import Foundation
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

struct AgentSessionPersistenceFailure: Error, Equatable {
    enum Operation: String, Equatable { case save, delete }
    let operation: Operation
    let tabID: UUID
    let message: String
}

enum AgentSessionSaveResult {
    case saved, notRequired
    case deferred(String)
    case failed(AgentSessionPersistenceFailure)
}

enum AgentSessionSaveCoreResult {
    case durablySaved(AgentSessionRestorationBindingToken)
    case notRequired
    case deferred(String)
    case failed(AgentSessionPersistenceFailure)
}

/// Owns the save transaction and scheduling independently of optional presentation.
/// Composition supplies existing carrier/catalog admission, never a callback that saves via a VM.
/// The prepared-host cutover replaces its UI catalog adapter with the domain catalog adapter.
@MainActor
final class AgentSessionPersistenceRuntime {
    typealias TabSession = AgentTabSession
    typealias SessionSaveCommitToken = AgentSessionSaveCommitToken
    typealias RequiredSavePhase = AgentSessionRequiredSavePhase
    typealias Saver = @MainActor (AgentSession, WorkspaceModel, Int) async throws -> URL

    /// Existing owner saves resolve their writer normally. A command's required write can only
    /// narrow that authority to the claim captured before any queue or preparation suspension.
    enum WriterExpectation {
        case currentOwner
        case exact(AgentSessionRuntimeStore.Writer)
    }

    private func permits(_ expectation: WriterExpectation, tabID: UUID) -> Bool {
        switch expectation {
        case .currentOwner: true
        case let .exact(writer):
            writer.scope === scope && sessions[tabID] === writer.session
                && writer.session.tabID == tabID && writer.isCurrent
        }
    }

    struct Admission {
        let sessionID: UUID
        let creation: AgentSessionCreationHandle?
    }

    struct Composition {
        let workspace: () -> WorkspaceModel?
        let workspaceWithID: (UUID) -> WorkspaceModel?
        let displayName: (UUID) -> String
        let isSuppressed: () -> Bool
        let bypassesSuppression: () -> Bool
        let isPreparedSavedHost: () -> Bool
        let saveAdmission: (AgentTabSession) -> String?
        let creationIsCurrent: (AgentSessionCreationHandle) -> Bool
        let admitBinding: (AgentTabSession) -> Admission?
        var isRestoringConfiguration: () -> Bool = { false }
    }

    struct Presentation {
        let currentTabID: () -> UUID?
        let isActivelyPresenting: (AgentTabSession) -> Bool
        let didRefreshDerivedState: (AgentTabSession) -> Void
        let requestRefresh: (AgentTabSession) -> Void
        let didCommit: (AgentTabSession, AgentSessionSaveRuntime.Receipt, Int) -> Void
    }

    private weak var scope: AgentSessionRuntimeStore.Scope?
    let queue = AgentSessionSaveQueue()
    var composition: Composition?
    var presentation: Presentation?
    var perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    var saver: Saver = { payload, workspace, count in
        try await AgentSessionDataService.shared.saveAgentSession(
            payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count
        )
    }

    var debounce: () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }
    private var sessions: [UUID: AgentTabSession] {
        scope?.sessions ?? [:]
    }

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
    }

    func makeRunHooks() -> AgentModeRunService.RunPersistenceHooks {
        .init(scheduleSave: { [self] session in scheduleSave(for: session) })
    }

    private func currentOwner(for sessionID: UUID) -> AgentTabSession? {
        guard let workspace = composition?.workspace(),
              case let .unique(writer) = scope?.resolveWriter(workspaceID: workspace.id, sessionID: sessionID),
              writer.scope === scope else { return nil }
        return writer.session
    }

    func makeSaveCommitToken(
        for session: TabSession,
        workspace: WorkspaceModel
    ) -> SessionSaveCommitToken? {
        guard let binding = session.persistentSessionBindingIdentity,
              binding.sessionID == session.activeAgentSessionID,
              !session.bindingTransitionInProgress
        else {
            return nil
        }
        return SessionSaveCommitToken(
            tabID: session.tabID,
            sessionIdentity: ObjectIdentifier(session),
            workspaceID: workspace.id,
            workspaceDirectoryPath: sessionSaveWorkspaceDirectoryPath(for: workspace),
            binding: binding,
            bindingTransitionGeneration: session.bindingTransitionGeneration,
            sourceItemsRevision: session.sourceItemsRevision,
            persistenceMutationGeneration: session.persistenceMutationGeneration,
            saveRequestGeneration: session.saveRequestGeneration
        )
    }

    private func sessionSaveWorkspaceDirectoryPath(for workspace: WorkspaceModel) -> String {
        WorkspaceSessionSidecarMigration.workspaceDirectory(
            for: workspace, root: AgentSessionDataService.defaultWorkspaceRootURL()
        ).standardizedFileURL.path
    }

    func isSaveCommitTokenCurrent(
        _ token: SessionSaveCommitToken,
        requireWorkspaceMatch: Bool = true,
        creationHandle: AgentSessionCreationHandle? = nil
    ) -> Bool {
        if requireWorkspaceMatch {
            // A storage move can preserve every session/binding identity. The completed write
            // only acknowledges the placement captured from the workspace passed to its saver.
            guard let workspace = composition?.workspace(),
                  workspace.id == token.workspaceID,
                  sessionSaveWorkspaceDirectoryPath(for: workspace) == token.workspaceDirectoryPath
            else { return false }
        }
        guard let session = sessions[token.tabID] else { return false }
        return token.matches(session, creationHandle: creationHandle)
    }

    private func requestFreshSaveForCurrentOwner(
        sessionID: UUID,
        fallbackSession: TabSession
    ) {
        let currentOwner = currentOwner(for: sessionID)
        if let currentOwner {
            currentOwner.isDirty = true
            queue.requestFollowUp(sessionID: sessionID)
        } else if fallbackSession.activeAgentSessionID == sessionID {
            fallbackSession.isDirty = true
            queue.requestFollowUp(sessionID: sessionID)
        }
    }

    func scheduleSave(for tabID: UUID) {
        guard composition?.isSuppressed() == false else { return }
        guard let session = sessions[tabID], session.creationState == nil else { return }
        session.saveRequestGeneration &+= 1
        guard !session.isInstallingHandoffWorktreeBindings else {
            // Handoff saves the destination explicitly once its inherited bindings are installed.
            session.saveDebounceTask?.cancel()
            session.saveDebounceTask = nil
            return
        }
        #if DEBUG
            let replacedPendingSave = session.saveDebounceTask != nil
            perfRecorder.increment("save.schedule", tabID: tabID)
            if replacedPendingSave {
                perfRecorder.increment("save.schedule.replaced", tabID: tabID)
            }
            perfRecorder.event("save.schedule", tabID: tabID, fields: ["replaced": String(replacedPendingSave), "dirty": String(session.isDirty)])
        #endif
        session.saveDebounceTask?.cancel()
        let capturedScope = scope
        let binding = session.persistentSessionBindingIdentity
        let transition = session.bindingTransitionGeneration
        let requestID = UUID()
        session.saveDebounceRequestID = requestID
        session.saveDebounceTask = Task { [self, session, capturedScope] in
            defer {
                if session.saveDebounceRequestID == requestID {
                    session.saveDebounceRequestID = nil
                    session.saveDebounceTask = nil
                }
            }
            do { try await debounce() } catch { return }
            guard !Task.isCancelled, capturedScope?.sessions[tabID] === session,
                  !session.isInstallingHandoffWorktreeBindings else { return }
            guard session.persistentSessionBindingIdentity == binding,
                  session.bindingTransitionGeneration == transition
            else {
                // Requalification of the same live object must not lose a coalesced save.
                // The new timer captures the new incarnation, but a recycled tab's different
                // object never inherits this predecessor's request. Admission still applies.
                if session.isDirty { scheduleSave(for: session) }
                return
            }
            _ = await saveSession(for: tabID)
        }
    }

    /// Schedules persistence only while the supplied object is still the live
    /// owner of its tab identifier. Stale predecessors must not save successors.
    func scheduleSave(for session: TabSession) {
        guard sessions[session.tabID] === session else { return }
        scheduleSave(for: session.tabID)
    }

    func scheduleSaveForCommandOutput(session: TabSession, minInterval: TimeInterval = 5.0) {
        guard sessions[session.tabID] === session else { return }
        scheduleSaveForCommandOutput(tabID: session.tabID, minInterval: minInterval)
    }

    func scheduleSaveForCommandOutput(tabID: UUID, minInterval: TimeInterval = 5.0) {
        guard let session = sessions[tabID] else { return }
        let now = Date()
        if let lastSaveAt = session.lastCommandOutputSaveAt,
           now.timeIntervalSince(lastSaveAt) < minInterval
        {
            #if DEBUG
                perfRecorder.increment("save.commandOutput.skipped", tabID: tabID)
                perfRecorder.event(
                    "save.commandOutput.skipped",
                    tabID: tabID,
                    fields: [
                        "elapsed": String(format: "%.2fs", now.timeIntervalSince(lastSaveAt)),
                        "minInterval": String(format: "%.2fs", minInterval)
                    ]
                )
            #endif
            return
        }
        session.lastCommandOutputSaveAt = now
        #if DEBUG
            perfRecorder.increment("save.commandOutput.scheduled", tabID: tabID)
            perfRecorder.event("save.commandOutput.scheduled", tabID: tabID, fields: ["minInterval": String(format: "%.2fs", minInterval)])
        #endif
        scheduleSave(for: tabID)
    }

    @discardableResult
    func saveSession(for tabID: UUID, writer expectation: WriterExpectation = .currentOwner, observingPhase: ((RequiredSavePhase) -> Void)? = nil) async -> AgentSessionSaveResult {
        switch await saveSessionCore(for: tabID, writer: expectation, observingPhase: observingPhase) {
        case .durablySaved:
            .saved
        case .notRequired:
            .notRequired
        case let .deferred(message):
            .deferred(message)
        case let .failed(failure):
            .failed(failure)
        }
    }

    typealias SessionCreationSave = AgentSessionCreationSave

    func saveSessionCore(
        for tabID: UUID, creationSave: SessionCreationSave? = nil,
        writer expectation: WriterExpectation = .currentOwner,
        observingPhase: ((RequiredSavePhase) -> Void)? = nil
    ) async -> AgentSessionSaveCoreResult {
        #if DEBUG
            let diagnosticsStartMS = perfRecorder.timestampMSIfEnabled()
            perfRecorder.increment("save.session.invoked", tabID: tabID)
        #endif
        guard permits(expectation, tabID: tabID) else {
            return .deferred("The originating writer changed before persistence.")
        }
        guard composition != nil else { return .deferred("The runtime persistence composition is unavailable.") }
        guard composition?.isSuppressed() == false || composition?.bypassesSuppression() == true
        else {
            #if DEBUG
                perfRecorder.event("save.session.skipped", tabID: tabID, fields: ["reason": "suppressed"])
            #endif
            return .notRequired
        }
        guard let session = sessions[tabID] else {
            #if DEBUG
                perfRecorder.event("save.session.skipped", tabID: tabID, fields: ["reason": "missing"])
            #endif
            return .notRequired
        }
        if composition?.isPreparedSavedHost() == true,
           let id = session.activeAgentSessionID, AgentSessionDeletionRegistry.shared.blocksNewOversight(sessionID: id)
        {
            return .deferred("The saved target is being deleted or has been deleted; its retired runtime cannot write it back.")
        }
        if let refusal = composition?.saveAdmission(session) { return .deferred(refusal) }
        var effectiveCreationSave = creationSave
        if let handle = creationSave?.handle {
            guard handle.session === session, composition?.creationIsCurrent(handle) == true,
                  session.creationHandleIsCurrent(handle)
            else {
                return .deferred("The session creation owner changed before persistence.")
            }
        } else if let message = session.restorationAdmissionFailureMessage {
            return .failed(.init(operation: .save, tabID: tabID, message: message))
        }
        guard !session.isInstallingHandoffWorktreeBindings else {
            // Any save path (debounce, flush, required flush) would persist the provisional,
            // unbound Handoff destination; Handoff saves it explicitly once installation settles.
            return .deferred("Handoff is still preparing this chat's worktree execution location.")
        }
        guard session.isDirty || session.activeAgentSessionID == nil else {
            #if DEBUG
                perfRecorder.event("save.session.skipped", tabID: tabID, fields: ["reason": "clean"])
            #endif
            return .notRequired
        }
        guard let workspace = composition?.workspace() else {
            return .failed(.init(operation: .save, tabID: tabID, message: "Active workspace is unavailable."))
        }

        let hasConversationContent = !session.items.isEmpty || !session.transcript.turns.isEmpty || session.runState.isActive || session.hasPendingQuestionUI || session.pendingApproval != nil || session.hasPendingCodexHookReviewWait || session.pendingPermissionsRequest != nil || session.pendingApplyEditsReview != nil || session.pendingWorktreeMergeReview != nil || session.worktreeMergeOperations.contains { $0.status.isActive }
        if session.activeAgentSessionID == nil, !hasConversationContent {
            return .notRequired
        }
        guard let admission = composition?.admitBinding(session) else {
            return .failed(.init(operation: .save, tabID: tabID, message: "A required session binding could not be established."))
        }
        let sessionID = admission.sessionID
        if let creation = admission.creation { effectiveCreationSave = .configured(creation) }
        session.saveRequestGeneration &+= 1
        let saveQueue = queue
        guard saveQueue.begin(sessionID: sessionID) else {
            return .deferred("A save for this session is already in flight.")
        }
        defer {
            if saveQueue.finish(sessionID: sessionID) {
                if let currentOwner = currentOwner(for: sessionID) {
                    scheduleSave(for: currentOwner.tabID)
                } else if sessions[tabID] === session,
                          session.activeAgentSessionID == sessionID
                {
                    scheduleSave(for: tabID)
                }
            }
        }
        let isActiveOwnedForSave = presentation?.isActivelyPresenting(session) == true
        let preparation = AgentSessionTranscriptRefreshRuntime.prepareSave(
            for: session, isActiveOwnedForSave: isActiveOwnedForSave,
            perfRecorder: perfRecorder, diagnosticPresentationID: perfRecorder.shortID(presentation?.currentTabID()),
            didRefreshDerivedState: { [weak self] session in self?.presentation?.didRefreshDerivedState(session) }
        )
        let persistableSnapshot = preparation.snapshot
        let shouldRefreshAfterPreparation = preparation.shouldRefreshPresentation
        if shouldRefreshAfterPreparation {
            // Only refresh sessions that can publish active bindings now. Inactive
            // persistence-only saves must not feed back into UI projection work.
            if isActiveOwnedForSave {
                #if DEBUG
                    perfRecorder.increment("save.session.innerRefresh", tabID: tabID)
                    perfRecorder.event("save.session.innerRefresh", tabID: tabID)
                #endif
                presentation?.requestRefresh(session)
            } else {
                #if DEBUG
                    perfRecorder.increment("save.session.innerRefreshSkippedInactive", tabID: tabID)
                    perfRecorder.event(
                        "save.session.innerRefreshSkipped",
                        tabID: tabID,
                        fields: [
                            "reason": "inactiveTab",
                            "currentTabID": perfRecorder.shortID(presentation?.currentTabID())
                        ]
                    )
                #endif
            }
        }

        // Build the persisted session only for the binding generation captured below.
        let canonicalItemCount = persistableSnapshot.canonicalVisibleRowCount
        let sessionName = composition?.displayName(tabID) ?? AgentSessionRestoreSupport.normalizedSessionTitle(nil)
        let agentSession = AgentSessionPayloadBuilder.makePayload(
            session: session, sessionID: sessionID, workspaceID: workspace.id,
            name: sessionName, snapshot: persistableSnapshot
        )
        guard let saveToken = makeSaveCommitToken(for: session, workspace: workspace),
              isSaveCommitTokenCurrent(saveToken, creationHandle: effectiveCreationSave?.handle)
        else {
            if permits(expectation, tabID: tabID) {
                requestFreshSaveForCurrentOwner(sessionID: sessionID, fallbackSession: session)
            }
            return .deferred("The session or its storage location changed before persistence could commit.")
        }

        guard case let .unique(writer) = scope?.resolveWriter(
            workspaceID: workspace.id, sessionID: sessionID
        ), writer.session === session else {
            // Unknown placement and conflicting identities are not transient save retries.
            // Keep dirty state and fail required flushes honestly; do not guess a workspace,
            // bypass writer admission, or spin a debounce loop while the conflict remains.
            return .deferred("The session does not have a unique runtime writer for this workspace.")
        }
        if case let .exact(expected) = expectation {
            guard expected.identity == writer.identity, expected.session === writer.session,
                  permits(expectation, tabID: tabID)
            else {
                return .deferred("The originating writer changed before persistence could commit.")
            }
        }
        let preparedWrite: AgentSessionSaveRuntime.PreparedWrite
        do {
            preparedWrite = try AgentSessionSaveRuntime.prepare(
                payload: agentSession, session: session, creation: effectiveCreationSave
            )
        } catch {
            return .failed(.init(operation: .save, tabID: tabID, message: error.localizedDescription))
        }
        do {
            let outcome = try await AgentSessionSaveRuntime.commit(
                preparedWrite,
                workspace: workspace,
                canonicalItemCount: canonicalItemCount,
                writer: writer,
                token: saveToken,
                storageIsCurrent: { [self] in
                    guard isSaveCommitTokenCurrent(saveToken, creationHandle: effectiveCreationSave?.handle),
                          let current = composition?.workspaceWithID(workspace.id) else { return false }
                    return WorkspaceSessionSidecarMigration.workspaceDirectory(
                        for: current, root: AgentSessionDataService.defaultWorkspaceRootURL()
                    ).standardizedFileURL.path == saveToken.workspaceDirectoryPath
                },
                currentName: { [self] in composition?.displayName(tabID) ?? AgentSessionRestoreSupport.normalizedSessionTitle(nil) },
                observingPhase: observingPhase,
                saver: saver
            )
            let receipt: AgentSessionSaveRuntime.Receipt
            switch outcome {
            case let .deferred(message, requestFreshSave):
                // A stale exact operation cannot dirty or request a retry through its successor.
                // Independently queued owner saves still drain through the existing queue defer.
                if requestFreshSave, permits(expectation, tabID: tabID) {
                    requestFreshSaveForCurrentOwner(sessionID: sessionID, fallbackSession: session)
                }
                return .deferred(message)
            case let .committed(committed):
                receipt = committed
            }
            guard permits(expectation, tabID: tabID) else {
                return .deferred("The originating writer changed after persistence committed.")
            }
            presentation?.didCommit(session, receipt, canonicalItemCount)
            #if DEBUG
                if let diagnosticsStartMS {
                    perfRecorder.event(
                        "save.session.complete",
                        tabID: tabID,
                        fields: [
                            "duration": perfRecorder.formatElapsedMS(since: diagnosticsStartMS),
                            "itemCount": String(canonicalItemCount)
                        ]
                    )
                }
            #endif
            let durableBindingToken = receipt.binding
            guard permits(expectation, tabID: tabID), session.currentRestorationBindingToken == durableBindingToken else {
                if permits(expectation, tabID: tabID) {
                    requestFreshSaveForCurrentOwner(sessionID: sessionID, fallbackSession: session)
                }
                return .deferred("The session binding changed after persistence committed.")
            }
            observingPhase?(.durablySaved(durableBindingToken))
            return .durablySaved(durableBindingToken)
        } catch {
            #if DEBUG
                perfRecorder.event("save.session.error", tabID: tabID, fields: ["error": String(describing: error)])
            #endif
            let failure = AgentSessionPersistenceFailure(
                operation: .save,
                tabID: tabID,
                message: String(describing: error)
            )
            print("[AgentSessionPersistenceRuntime] Failed to save session: \(failure.message)")
            return .failed(failure)
        }
    }

    func waitForInFlightSave(sessionID: UUID) async {
        await queue.waitForInFlightSave(sessionID: sessionID)
    }

    func flushSave(for tabID: UUID) async {
        guard let session = sessions[tabID] else { return }
        session.saveDebounceTask?.cancel()
        _ = await saveSession(for: tabID)
    }

    /// Internal rather than private because the cross-session send transaction uses required
    /// persistence as its delivery linearization point: the attributed row must be durable before a
    /// provider turn starts, and a debounced `scheduleSave` cannot provide that guarantee.
    func flushSaveRequired(
        writer: AgentSessionRuntimeStore.Writer,
        observingSavePhase: ((RequiredSavePhase) -> Void)? = nil
    ) async -> Result<Void, AgentSessionPersistenceFailure> {
        await flushSaveRequired(
            for: writer.binding.tabID, workspaceID: writer.identity.workspaceID,
            writer: .exact(writer), observingSavePhase: observingSavePhase
        )
    }

    func flushSaveRequired(
        for tabID: UUID,
        workspaceID: UUID,
        writer expectation: WriterExpectation = .currentOwner,
        observingSavePhase: ((RequiredSavePhase) -> Void)? = nil
    ) async -> Result<Void, AgentSessionPersistenceFailure> {
        observingSavePhase?(.beforeWrite)
        guard let retainedScope = scope, composition != nil else {
            return .failure(.init(operation: .save, tabID: tabID, message: "The runtime persistence owner is unavailable."))
        }
        defer { withExtendedLifetime(retainedScope) {} }
        guard permits(expectation, tabID: tabID) else {
            return .failure(.init(operation: .save, tabID: tabID, message: "The originating writer changed before required persistence."))
        }
        guard let capturedSession = sessions[tabID] else { return .success(()) }
        let capturedBinding = capturedSession.persistentSessionBindingIdentity
        let capturedRestorationToken = capturedSession.currentRestorationBindingToken
        if let message = capturedSession.restorationAdmissionFailureMessage {
            return .failure(.init(operation: .save, tabID: tabID, message: message))
        }
        if case .currentOwner = expectation { capturedSession.saveDebounceTask?.cancel() }

        if let sessionID = capturedSession.activeAgentSessionID {
            while queue.inFlightSessionIDs.contains(sessionID) {
                await waitForInFlightSave(sessionID: sessionID)
            }
        }

        guard composition?.workspace()?.id == workspaceID else {
            return .failure(.init(
                operation: .save,
                tabID: tabID,
                message: "The owning workspace changed during required persistence."
            ))
        }
        guard permits(expectation, tabID: tabID), sessions[tabID] === capturedSession,
              capturedSession.persistentSessionBindingIdentity == capturedBinding,
              capturedSession.currentRestorationBindingToken == capturedRestorationToken,
              capturedSession.restorationAdmissionFailureMessage == nil
        else {
            return .failure(.init(
                operation: .save,
                tabID: tabID,
                message: "The live session owner changed during required persistence."
            ))
        }

        if case .exact = expectation {
            // Do not cancel an owner's ordinary request while this exact operation is queued.
            // Once admitted to write, remember that request separately from our acknowledgment.
            let hadPendingDebounce = capturedSession.saveDebounceRequestID != nil
                && capturedSession.saveDebounceTask?.isCancelled == false
            capturedSession.saveDebounceTask?.cancel()
            capturedSession.saveDebounceTask = nil
            capturedSession.saveDebounceRequestID = nil
            defer {
                if hadPendingDebounce, !permits(expectation, tabID: tabID),
                   sessions[tabID] === capturedSession,
                   capturedSession.persistentSessionBindingIdentity == capturedBinding,
                   capturedSession.isDirty, capturedSession.saveDebounceRequestID == nil
                {
                    // Preserve only the pre-existing same-record owner's request, not a retry
                    // invented by this failed exact operation or a write to a recycled tab.
                    scheduleSave(for: capturedSession)
                }
            }
            return await finishRequiredSave(for: tabID, session: capturedSession, writer: expectation, observingSavePhase: observingSavePhase)
        }
        return await finishRequiredSave(for: tabID, session: capturedSession, writer: expectation, observingSavePhase: observingSavePhase)
    }

    private func finishRequiredSave(
        for tabID: UUID, session capturedSession: TabSession, writer expectation: WriterExpectation,
        observingSavePhase: ((RequiredSavePhase) -> Void)?
    ) async -> Result<Void, AgentSessionPersistenceFailure> {
        let result = await saveSession(for: tabID, writer: expectation, observingPhase: observingSavePhase)
        guard permits(expectation, tabID: tabID) else {
            return .failure(.init(operation: .save, tabID: tabID, message: "The originating writer changed during required persistence."))
        }
        switch result {
        case .saved:
            guard !capturedSession.isDirty else {
                return .failure(.init(
                    operation: .save,
                    tabID: tabID,
                    message: "The session changed while required persistence was committing."
                ))
            }
            return .success(())
        case .notRequired:
            return .success(())
        case let .deferred(message):
            return .failure(.init(operation: .save, tabID: tabID, message: message))
        case let .failed(failure):
            return .failure(failure)
        }
    }
}
