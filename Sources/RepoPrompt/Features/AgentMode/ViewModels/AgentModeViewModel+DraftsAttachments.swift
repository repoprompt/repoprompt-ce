import Foundation
import RepoPromptAIContracts

@MainActor
extension AgentModeViewModel {
    // MARK: - Draft Text Management

    func restoreComposerDraft(
        tabID: UUID,
        text: String,
        message: String,
        strategy: AgentModeRunService.DraftRestorationStrategy,
        operation: AgentComposerDraftRestorationOperation? = nil
    ) {
        let hadRuntime = sessions[tabID] != nil
        let previousText = draftRuntime.text(for: tabID)
        let event = draftRuntime.restore(tabID: tabID, text: text, message: message, strategy: strategy, operation: operation)
        if !hadRuntime {
            publishDraftTextChange(tabID: tabID, previousText: previousText, session: nil)
            publishDraftRestoration(event)
        }
    }

    /// Restores the full composer state for a manual submission that was
    /// rejected before provider dispatch: draft text, image attachments,
    /// tagged-file attachments, and the selected workflow.
    ///
    /// Restores never displace newer user choices: attachments and tagged
    /// files are prepended only when not already pending, and the workflow is
    /// restored only when the user has not selected another one since the
    /// rejected submission. The rejected draft text is composed above any
    /// newer typing here (with `.replaceAlways` delivery) so back-to-back
    /// rejections each restore exactly once even when restoration events
    /// coalesce in the UI.
    func restoreRejectedManualSubmissionComposerState(
        repromptedText: String? = nil,
        tabID: UUID,
        session: TabSession,
        draftText: String,
        attachments: [AgentFileAttachment],
        taggedFiles: [AgentTaggedFileAttachment],
        selectedWorkflow workflow: AgentWorkflowDefinition?,
        selectedWorkflowMutationGeneration: UInt64?,
        message: String
    ) {
        var sessionChanged = false
        if !attachments.isEmpty {
            let existingImageIDs = Set(session.pendingFileAttachments.map(\.id))
            let restoredImages = attachments.filter { !existingImageIDs.contains($0.id) }
            if !restoredImages.isEmpty {
                session.pendingFileAttachments = restoredImages + session.pendingFileAttachments
                sessionChanged = true
            }
        }
        if !taggedFiles.isEmpty {
            let existingTaggedPaths = Set(session.pendingTaggedFileAttachments.map(\.relativePath))
            let restoredTaggedFiles = taggedFiles.filter { !existingTaggedPaths.contains($0.relativePath) }
            if !restoredTaggedFiles.isEmpty {
                session.pendingTaggedFileAttachments = restoredTaggedFiles + session.pendingTaggedFileAttachments
                sessionChanged = true
            }
        }
        if let workflow,
           let selectedWorkflowMutationGeneration,
           session.userWorkflowSelectionMutationGeneration == selectedWorkflowMutationGeneration,
           session.selectedWorkflow == nil
        {
            session.selectedWorkflow = workflow
            if tabID == currentTabID {
                selectedWorkflow = workflow
            }
            sessionChanged = true
        }
        if sessionChanged {
            session.isDirty = true
            updateBindingsFromSession(session)
            persistenceRuntime.scheduleSave(for: tabID)
        }
        let existingDraft = draftRuntime.text(for: tabID)
        let composedDraft = AgentComposerDraftRestorationReducer.compose(
            restoredText: draftText,
            above: existingDraft
        )
        let operation = AgentComposerDraftRestorationOperation(
            rejectedDraftText: draftText,
            draftTextBeforeRestoration: existingDraft,
            composedDraftText: composedDraft,
            fragments: []
        )
        restoreComposerDraft(
            tabID: tabID,
            text: composedDraft,
            message: message,
            strategy: .replaceAlways,
            operation: operation
        )
        if let repromptedText {
            repromptUIStore.recoveries[tabID] = .init(
                text: repromptedText, originalDraft: draftText, reason: message,
                draftAtInvalidation: draftRuntime.text(for: tabID)
            )
        }
    }

    /// Withdraws a run's initial user turn that a route-verification refusal kept from ever reaching
    /// the provider, and puts its text back into an empty composer, so a resend leaves no duplicate
    /// user row. The Claude-native counterpart of Codex's pre-dispatch rejection rollback.
    ///
    /// Narrowed to what it can restore losslessly: a plain-text row (no images, tagged files,
    /// workflow, or cross-session attribution) followed only by error rows, and an empty composer.
    /// Anything else keeps the row in the transcript for retry, as before.
    @discardableResult
    func restoreRouteRefusedUnsentTurn(
        session: TabSession,
        userItemID: UUID,
        message: String
    ) -> Bool {
        _ = persistenceRuntime
        return draftRuntime.restoreRouteRefusedUnsentTurn(session: session, userItemID: userItemID, message: message)
    }

    /// Store an editor draft. Only the caller's applied sequence is acknowledged;
    /// still-pending fragments are composed into storage so a tab switch cannot
    /// overwrite a recovery that has not reached the editor yet.
    func storeDraftText(for tabID: UUID, _ text: String, acknowledgingThrough sequence: UInt64 = 0) {
        let hadRuntime = sessions[tabID] != nil
        let previousText = draftRuntime.text(for: tabID)
        draftRuntime.store(tabID: tabID, text: text, acknowledgingThrough: sequence)
        if !hadRuntime {
            publishDraftTextChange(tabID: tabID, previousText: previousText, session: nil)
        }
    }

    func publishDraftRestoration(_ event: AgentComposerDraftRestorationEvent) {
        draftRestorationEvent = event
        syncComposerUIState()
    }

    func publishDraftTextChange(tabID: UUID, previousText: String, session: TabSession?) {
        let text = draftRuntime.text(for: tabID)
        let previousStagedSlashCommand = stagedSlashCommandProps(tabID: tabID, draftTextOverride: previousText)
        if !repromptUIStore.hasCancelledDraft(tabID: tabID, text: text) {
            repromptUIStore.clearCancelledDraft(tabID: tabID)
        }
        if let session {
            guard previousText != text else { return }
            if let operation = repromptOperations[tabID] {
                operation.noteUserMutation(text: text, generation: session.draftMutationGeneration)
            } else if var recovery = repromptUIStore.recoveries[tabID], recovery.bypassesPreparation,
                      !recovery.draftAtInvalidation.utf8.elementsEqual(text.utf8)
            {
                // Editing ends exact-draft authority. Preserve the old alternative without
                // re-stamping its original/classification onto an unrelated new message.
                recovery.bypassesPreparation = false
                recovery.requiresDecision = false
                repromptUIStore.recoveries[tabID] = recovery
            }
        }
        invalidateRepromptIfNeeded()
        let nextStagedSlashCommand = stagedSlashCommandProps(tabID: tabID)
        if tabID == currentTabID, previousStagedSlashCommand != nextStagedSlashCommand {
            syncComposerUIState(tabID: tabID)
            ui.statusPills.update(makeStatusPillsSnapshot())
        }
    }

    func stagedSlashCommandProps(
        tabID: UUID?,
        draftTextOverride: String? = nil
    ) -> AgentStagedSlashCommandProps? {
        guard let tabID,
              CodexGoalSupport.isEnabled
        else { return nil }
        // Presentation reads must not recreate a runtime while its saved carrier is retiring.
        let session = sessions[tabID]
        let targetAgent = session?.selectedAgent ?? (tabID == currentTabID ? selectedAgent : nil)
        guard targetAgent == .codexExec else { return nil }
        let draftText = draftTextOverride ?? session?.draftText ?? tabDraftText[tabID] ?? ""
        guard let token = AgentSessionProviderInputRuntime.extractSlashSkillTokens(from: draftText).first else { return nil }
        let normalizedName = token.name.lowercased()
        guard normalizedName == CodexAgentModeCoordinator.NativeSlashCommand.goal.rawValue else { return nil }
        let argumentsText = (draftText as NSString)
            .substring(with: token.argumentsRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let action = CodexAgentModeCoordinator.goalSlashAction(from: argumentsText)
        let selectedWorkflow = session?.selectedWorkflow ?? (tabID == currentTabID ? selectedWorkflow : nil)
        let goalAction: AgentStagedSlashCommandProps.GoalAction = switch action {
        case .show:
            .show
        case .clear:
            .clear
        case .pause:
            .pause
        case .resume:
            .resume
        case .setObjective:
            .setObjective
        }
        return AgentStagedSlashCommandProps(
            kind: .codexGoal,
            displayText: "/goal",
            action: goalAction,
            selectedWorkflowName: selectedWorkflow?.displayName,
            appliesSelectedWorkflowContext: selectedWorkflow != nil && goalAction == .setObjective
        )
    }

    private static var attachmentIntakeTail: Task<Void, Never>?

    #if DEBUG
        static var attachmentIntakeDidImportForTesting: (@MainActor (UUID) async -> Void)?
    #endif

    /// Imports `urls` as pending attachments. File admission, copy, content probe and identity hash run off
    /// the main actor, and intakes run one at a time so a second drop dedups against the first. The
    /// returned task finishes once every file has been attached or refused; callers that delete
    /// temporary sources must wait for it. UI callers supply a live admission check so a queued or
    /// completed import cannot publish after the composer changes ownership.
    @discardableResult
    func attachFiles(
        tabID: UUID,
        urls: [URL],
        completion: (@MainActor (Bool) -> Void)? = nil,
        admission: @escaping @MainActor () -> Bool = { true }
    ) -> Task<Void, Never> {
        guard !urls.isEmpty, admission() else { completion?(false)
            return Task {}
        }
        guard let workspaceDirectory = attachmentWorkspaceDirectoryURL() else {
            reportAttachmentFailures(
                tabID: tabID,
                messages: ["Attachments require an active workspace."]
            )
            completion?(false)
            return Task {}
        }

        let previousIntake = Self.attachmentIntakeTail
        let store = attachmentStore
        let session = session(for: tabID)
        let binding = session.persistentSessionBindingIdentity
        let bindingGeneration = session.bindingTransitionGeneration
        let intake = Task { @MainActor [weak self, weak session] in
            var succeeded = false
            defer { completion?(succeeded) }
            await previousIntake?.value
            guard let self, let session, admission(), sessions[tabID] === session,
                  session.persistentSessionBindingIdentity == binding,
                  session.bindingTransitionGeneration == bindingGeneration,
                  attachmentWorkspaceDirectoryURL() == workspaceDirectory else { return }
            let pending = session.pendingFileAttachments
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.importAttachments(urls: urls, pending: pending, store: store, workspaceDirectory: workspaceDirectory)
            }.value
            #if DEBUG
                await Self.attachmentIntakeDidImportForTesting?(tabID)
            #endif
            guard admission(), sessions[tabID] === session,
                  session.persistentSessionBindingIdentity == binding,
                  session.bindingTransitionGeneration == bindingGeneration,
                  attachmentWorkspaceDirectoryURL() == workspaceDirectory
            else {
                store.clearConsumedLocalFiles(outcome.imported, workspaceDirectory: workspaceDirectory)
                return
            }
            commitAttachmentIntake(outcome, to: session)
            succeeded = outcome.failures.isEmpty
        }
        Self.attachmentIntakeTail = intake
        return intake
    }

    func reportAttachmentFailures(tabID: UUID, _ failures: [AgentAttachmentFailure]) {
        reportAttachmentFailures(
            tabID: tabID,
            messages: failures.map(Self.attachmentFailureMessage)
        )
    }

    private static func attachmentFailureMessage(_ failure: AgentAttachmentFailure) -> String {
        "Failed to attach \(failure.fileName): \(failure.reason)"
    }

    private func reportAttachmentFailures(tabID: UUID, messages: [String]) {
        guard !messages.isEmpty else { return }
        appendAttachmentFailures(messages, to: session(for: tabID))
    }

    private func appendAttachmentFailures(_ messages: [String], to session: TabSession) {
        guard !messages.isEmpty else { return }
        for message in messages {
            session.appendItem(AgentChatItem.error(message, sequenceIndex: session.nextSequenceIndex))
        }
        updateBindingsFromSession(session)
        persistenceRuntime.scheduleSave(for: session)
    }

    /// Publishes into the exact session the admission fence just revalidated; it never looks the tab up
    /// again, so it cannot create or reach a replacement runtime.
    private func commitAttachmentIntake(_ outcome: AgentAttachmentIntakeOutcome, to session: TabSession) {
        appendAttachmentFailures(outcome.failures.map(Self.attachmentFailureMessage), to: session)
        guard !outcome.imported.isEmpty else { return }
        session.pendingFileAttachments.append(contentsOf: outcome.imported)
        session.isDirty = true
        updateBindingsFromSession(session)
        persistenceRuntime.scheduleSave(for: session)
    }

    private nonisolated static func importAttachments(
        urls: [URL],
        pending: [AgentFileAttachment],
        store: AgentAttachmentStore,
        workspaceDirectory: URL
    ) -> AgentAttachmentIntakeOutcome {
        var seenSourcePaths: Set<String> = []
        var seenIdentities: Set<AgentAttachmentStore.Identity> = []
        for attachment in pending {
            guard case let .localFile(path) = attachment.source else { continue }
            let fileURL = URL(fileURLWithPath: path).standardizedFileURL
            seenSourcePaths.insert(fileURL.path)
            if let identity = store.identity(of: fileURL, fileName: attachment.facts.fileName) {
                seenIdentities.insert(identity)
            }
        }

        var outcome = AgentAttachmentIntakeOutcome(imported: [], failures: [])
        for sourceURL in urls {
            let standardizedSourceURL = sourceURL.standardizedFileURL
            let displayName = standardizedSourceURL.lastPathComponent.isEmpty ? "file" : standardizedSourceURL.lastPathComponent
            if seenSourcePaths.contains(standardizedSourceURL.path) {
                outcome.failures.append(AgentAttachmentFailure(fileName: displayName, reason: "it is already attached."))
                continue
            }
            do {
                let admitted = try store.admit(sourceURL: standardizedSourceURL)
                let identity = store.identity(of: admitted.url, fileName: admitted.url.lastPathComponent)
                if let identity, seenIdentities.contains(identity) {
                    outcome.failures.append(AgentAttachmentFailure(fileName: displayName, reason: "it is already attached."))
                    continue
                }
                let result = try store.importFile(sourceURL: admitted.url, workspaceDirectory: workspaceDirectory)
                seenSourcePaths.insert(standardizedSourceURL.path)
                if let identity {
                    seenIdentities.insert(identity)
                }
                outcome.imported.append(result.attachment)
            } catch {
                outcome.failures.append(AgentAttachmentFailure(fileName: displayName, reason: error.localizedDescription))
            }
        }
        return outcome
    }

    // MARK: - Attach Guard

    /// Grok Build advertises no ACP image capability; its provider rejects attachments.
    static func providerSupportsImageAttachments(_ agent: AgentProviderKind) -> Bool {
        agent != .grokBuild
    }

    /// The rule shared by the attach button, paste, and drop for `tabID`'s session.
    func imageAttachmentBlockReason(tabID: UUID?) -> AgentImageAttachmentBlockReason? {
        var agent: AgentProviderKind = selectedAgent
        var isBusy = false
        if let tabID, let tabSession = session(for: tabID, createIfNeeded: false) {
            agent = tabSession.selectedAgent
            isBusy = tabSession.runState == AgentSessionRunState.running
        } else if let tabID, tabID == currentTabID {
            isBusy = isAgentBusy
        }
        return AgentImageAttachmentGuard.blockReason(
            hasTab: tabID != nil,
            isAgentBusy: isBusy,
            providerSupportsImages: Self.providerSupportsImageAttachments(agent),
            providerName: agent.displayName
        )
    }

    /// Capture the drop's live owner before asynchronous item providers load. Switching tabs is
    /// allowed; replacing its session, rebinding it, or switching workspaces invalidates the intake.
    func prepareAttachmentIntake(tabID: UUID) -> ([URL], [AgentAttachmentFailure]) async -> Void {
        guard let session = session(for: tabID, createIfNeeded: false) else { return { _, _ in } }
        let workspaceID = workspaceManager?.activeWorkspaceID
        let sessionID = session.activeAgentSessionID
        return { [weak self, weak session] urls, failures in
            guard let self, let session,
                  sessions[tabID] === session,
                  workspaceManager?.activeWorkspaceID == workspaceID,
                  session.activeAgentSessionID == sessionID,
                  !session.bindingTransitionInProgress,
                  repromptUIStore.allowsAttachmentMutation(tabID: tabID, currentTabID: tabID)
            else { return }
            // Even a failure-only drop must respect the live turn's last-row streaming owner.
            if let reason = imageAttachmentBlockReason(tabID: tabID) {
                reportImageAttachmentBlocked(reason, tabID: tabID)
                return
            }
            reportAttachmentFailures(tabID: tabID, failures)
            await attachImagesIfAllowed(tabID: tabID, urls: urls)
        }
    }

    /// Paste and drop entry point: attaches when the guard allows it, otherwise explains why not.
    @discardableResult
    func attachImagesIfAllowed(tabID: UUID, urls: [URL]) async -> Bool {
        guard !urls.isEmpty,
              // A delayed paste/drop must not recreate a tab removed while its providers loaded.
              let session = session(for: tabID, createIfNeeded: false),
              !session.bindingTransitionInProgress,
              // Pane drops retain their drag-start tab even after a tab switch, but must not
              // mutate a draft while that tab's reprompt operation owns it.
              repromptUIStore.allowsAttachmentMutation(tabID: tabID, currentTabID: tabID)
        else { return false }
        if let reason = imageAttachmentBlockReason(tabID: tabID) {
            reportImageAttachmentBlocked(reason, tabID: tabID)
            return false
        }
        await attachFiles(tabID: tabID, urls: urls, admission: { [weak self, weak session] in
            guard let self, let session else { return false }
            return sessions[tabID] === session
                && !session.bindingTransitionInProgress
                && repromptUIStore.allowsAttachmentMutation(tabID: tabID, currentTabID: tabID)
                && imageAttachmentBlockReason(tabID: tabID) == nil
        }).value
        return true
    }

    /// A running turn streams into the last transcript row, so a busy block is reported as a
    /// composer notice; other block reasons append a short error row.
    func reportImageAttachmentBlocked(_ reason: AgentImageAttachmentBlockReason, tabID: UUID) {
        if reason == .agentBusy {
            imageAttachmentNotice = AgentImageAttachmentNoticeProps(id: UUID(), tabID: tabID, message: reason.message)
            if tabID == currentTabID {
                syncComposerUIState(tabID: tabID)
            }
            return
        }
        let session = session(for: tabID)
        session.appendItem(AgentChatItem.error(reason.message, sequenceIndex: session.nextSequenceIndex))
        updateBindingsFromSession(session)
        persistenceRuntime.scheduleSave(for: tabID)
    }

    func removePendingFileAttachment(tabID: UUID, attachmentID: UUID) {
        let session = session(for: tabID)
        let beforeCount = session.pendingFileAttachments.count
        session.pendingFileAttachments.removeAll { $0.id == attachmentID }
        guard session.pendingFileAttachments.count != beforeCount else {
            return
        }
        session.isDirty = true
        updateBindingsFromSession(session)
        persistenceRuntime.scheduleSave(for: tabID)
    }

    func clearPendingFileAttachments(tabID: UUID) {
        let session = session(for: tabID)
        guard !session.pendingFileAttachments.isEmpty else {
            return
        }
        session.pendingFileAttachments.removeAll()
        session.isDirty = true
        updateBindingsFromSession(session)
        persistenceRuntime.scheduleSave(for: tabID)
    }

    func addPendingTaggedFile(tabID: UUID, relativePath: String, displayName: String? = nil) {
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }
        let normalizedPath = AgentSessionProviderInputRuntime.unescapeTaggedPath(trimmedPath)
        let session = session(for: tabID)
        if session.pendingTaggedFileAttachments.contains(where: { $0.relativePath == normalizedPath }) {
            return
        }
        let name = (displayName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? normalizedPath
        session.pendingTaggedFileAttachments.append(
            AgentTaggedFileAttachment(relativePath: normalizedPath, displayName: name)
        )
        session.isDirty = true
        updateBindingsFromSession(session)
        persistenceRuntime.scheduleSave(for: tabID)
    }

    @MainActor
    func commitPendingTaggedFile(tabID: UUID, relativePath: String, displayName: String? = nil) {
        let normalizedPath = AgentSessionProviderInputRuntime.unescapeTaggedPath(relativePath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return }
        addPendingTaggedFile(tabID: tabID, relativePath: normalizedPath, displayName: displayName)
        Task { @MainActor [weak self] in
            await self?.promoteSelectionPathsToFullContext(tabID: tabID, rawPaths: [normalizedPath])
        }
    }

    func removePendingTaggedFile(tabID: UUID, attachmentID: UUID) {
        let session = session(for: tabID)
        let beforeCount = session.pendingTaggedFileAttachments.count
        session.pendingTaggedFileAttachments.removeAll { $0.id == attachmentID }
        guard session.pendingTaggedFileAttachments.count != beforeCount else {
            return
        }
        session.isDirty = true
        updateBindingsFromSession(session)
        persistenceRuntime.scheduleSave(for: tabID)
    }

    func syncPendingTaggedFilesFromDraft(tabID: UUID, text: String) {
        let session = session(for: tabID)
        guard !session.pendingTaggedFileAttachments.isEmpty else { return }
        let tokens = Set(AgentSessionProviderInputRuntime.extractTaggedPaths(from: text).map(AgentSessionProviderInputRuntime.unescapeTaggedPath(_:)))
        let beforeCount = session.pendingTaggedFileAttachments.count
        session.pendingTaggedFileAttachments.removeAll { attachment in
            let normalizedPath = AgentSessionProviderInputRuntime.unescapeTaggedPath(attachment.relativePath)
            let normalizedDisplayName = AgentSessionProviderInputRuntime.unescapeTaggedPath(attachment.displayName)
            return !tokens.contains(normalizedPath) && !tokens.contains(normalizedDisplayName)
        }
        guard session.pendingTaggedFileAttachments.count != beforeCount else { return }
        session.isDirty = true
        updateBindingsFromSession(session)
        persistenceRuntime.scheduleSave(for: tabID)
    }

    private func attachmentWorkspaceDirectoryURL() -> URL? {
        attachmentWorkspaceDirectoryProvider()?.standardizedFileURL
    }

    func attachmentLocation(for session: TabSession) -> AgentSessionAttachmentLocation? {
        guard let directory = attachmentWorkspaceDirectoryURL() else { return nil }
        if let sessionAttachmentsRootOverride {
            return .init(workspaceDirectory: directory, retainedRoot: sessionAttachmentsRootOverride()?.standardizedFileURL)
        }
        let workspace: WorkspaceModel?
        if let workspaceID = session.persistentSessionBindingIdentity?.workspaceID {
            guard let bound = workspaceManager?.workspace(withID: workspaceID) else {
                return .init(workspaceDirectory: directory, retainedRoot: nil)
            }
            workspace = bound
        } else {
            workspace = workspaceManager?.activeWorkspace
        }
        return .init(workspaceDirectory: directory, retainedRoot: sessionAttachmentsRootURL(for: workspace))
    }

    // MARK: - Session Attachment Retention

    /// `<workspace>/AgentSessions/attachments` for `workspace` (the active workspace when `nil`), or
    /// `nil` when sessions are not persisted.
    func sessionAttachmentsRootURL(for workspace: WorkspaceModel? = nil) -> URL? {
        if let sessionAttachmentsRootOverride {
            return sessionAttachmentsRootOverride()?.standardizedFileURL
        }
        return AgentSessionStorageInputs.retainedAttachmentsRoot(
            workspace: workspace ?? workspaceManager?.activeWorkspace,
            isSuppressed: attachmentPersistenceIsSuppressed()
        )
    }

    /// Low-priority, once-per-process sweep of a workspace's attachment storage: session folders
    /// whose transcript is gone, and temporary copies older than seven days not pending anywhere.
    /// Called from the live workspace-switch path once the activation owns the session index.
    func scheduleSessionAttachmentSweepIfNeeded(for workspace: WorkspaceModel?) {
        guard clearConsumedAttachmentsAfterProviderConsumption,
              let root = sessionAttachmentsRootURL(for: workspace),
              Self.sweptSessionAttachmentRoots.insert(root.path).inserted
        else { return }
        let agentSessionsFolder = root.deletingLastPathComponent()
        let temporaryRoot = attachmentWorkspaceDirectoryURL().map { AgentAttachmentStore.managedStorageRootURL(for: $0) }
        let delayNanoseconds = sessionAttachmentSweepDelayNanoseconds
        sessionAttachmentSweepTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let self else { return nil }
            let protection = withExtendedLifetime(self) {
                AgentSessionRuntimeStore.shared.attachmentSweepProtection()
            }
            return await Task.detached(priority: .background) {
                AgentSessionAttachmentStore.sweep(
                    agentSessionsFolder: agentSessionsFolder,
                    temporaryRoot: temporaryRoot,
                    protectedSessionIDs: protection.sessionIDs,
                    protectedTemporaryPaths: protection.temporaryPaths
                )
            }.value
        }
    }

    /// Local image files this tab's Agent session attached itself — the in-flight turn plus any
    /// earlier user turns whose copies still exist — restricted to the app-managed attachment
    /// store. Used as exact-file Oracle image authority; returns nothing unless the tab is still
    /// bound to `agentSessionID`, so another session's attachments are never authorized.
    func oracleAuthorizedAttachmentPaths(tabID: UUID, agentSessionID: UUID?) -> [String] {
        guard let agentSessionID,
              let session = session(for: tabID, createIfNeeded: false),
              session.activeAgentSessionID == agentSessionID,
              let workspaceDirectory = attachmentWorkspaceDirectoryURL()
        else { return [] }
        let storagePrefix = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory).path + "/"
        // Earlier turns' images now live in this session's own retained folder.
        let retainedStore = sessionAttachmentsRootURL().map { AgentSessionAttachmentStore(rootURL: $0) }

        var candidates: [AgentFileAttachment] = []
        switch session.attachmentTurnState {
        case .idle:
            break
        case let .reserved(_, attachments), let .consumed(_, attachments):
            candidates.append(contentsOf: attachments)
        }
        candidates.append(contentsOf: session.attachmentsPendingProviderConsumptionCleanup)
        for item in session.items where item.kind == .user {
            candidates.append(contentsOf: item.attachments)
        }

        var seen: Set<String> = []
        var paths: [String] = []
        for attachment in candidates {
            guard case let .localFile(path) = attachment.source else { continue }
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            let isManagedTemporaryFile = standardized.hasPrefix(storagePrefix)
                && !standardized.dropFirst(storagePrefix.count).contains("/")
            let isRetainedSessionFile = retainedStore?.isRetainedPath(standardized, sessionID: agentSessionID) == true
            guard isManagedTemporaryFile || isRetainedSessionFile,
                  seen.insert(standardized).inserted
            else { continue }
            paths.append(standardized)
        }
        return paths
    }
}

struct AgentAttachmentFailure: Equatable {
    let fileName: String
    let reason: String
}

struct AgentAttachmentIntakeOutcome {
    var imported: [AgentFileAttachment]
    var failures: [AgentAttachmentFailure]
}
