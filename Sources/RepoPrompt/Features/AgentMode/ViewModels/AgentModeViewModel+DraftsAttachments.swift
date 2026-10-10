import CryptoKit
import Foundation

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
        // Compose against the session-owned draft now. The per-tab ledger retains
        // fragments until that tab's composer applies them or loads this snapshot.
        let eventID = UUID()
        let restoredText: String
        let restoredStrategy: AgentModeRunService.DraftRestorationStrategy
        let baseOperation: AgentComposerDraftRestorationOperation?
        if case .prependAlways = strategy, operation == nil {
            let existingDraft = retrieveDraftText(for: tabID)
            restoredText = AgentComposerDraftRestorationReducer.compose(restoredText: text, above: existingDraft)
            restoredStrategy = .replaceAlways
            baseOperation = AgentComposerDraftRestorationOperation(
                rejectedDraftText: text,
                draftTextBeforeRestoration: existingDraft,
                composedDraftText: restoredText,
                fragments: []
            )
        } else {
            restoredText = text
            restoredStrategy = strategy
            baseOperation = operation
        }
        let restoredOperation = baseOperation.map { operation in
            AgentComposerDraftRestorationOperation(
                rejectedDraftText: operation.rejectedDraftText,
                draftTextBeforeRestoration: operation.draftTextBeforeRestoration,
                composedDraftText: operation.composedDraftText,
                fragments: draftRestorationLedger.append(tabID: tabID, text: operation.rejectedDraftText)
            )
        }
        writeDraftText(for: tabID, restoredText)
        draftRestorationEvent = DraftRestorationEvent(
            id: eventID,
            tabID: tabID,
            text: restoredText,
            message: message,
            strategy: restoredStrategy,
            operation: restoredOperation
        )
        syncComposerUIState()
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
        tabID: UUID,
        session: TabSession,
        draftText: String,
        images: [AgentImageAttachment],
        taggedFiles: [AgentTaggedFileAttachment],
        selectedWorkflow workflow: AgentWorkflowDefinition?,
        selectedWorkflowMutationGeneration: UInt64?,
        message: String
    ) {
        var sessionChanged = false
        if !images.isEmpty {
            let existingImageIDs = Set(session.pendingImageAttachments.map(\.id))
            let restoredImages = images.filter { !existingImageIDs.contains($0.id) }
            if !restoredImages.isEmpty {
                session.pendingImageAttachments = restoredImages + session.pendingImageAttachments
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
            scheduleSave(for: tabID)
        }
        let existingDraft = retrieveDraftText(for: tabID)
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
    }

    /// Store an editor draft. Only the caller's applied sequence is acknowledged;
    /// still-pending fragments are composed into storage so a tab switch cannot
    /// overwrite a recovery that has not reached the editor yet.
    func storeDraftText(for tabID: UUID, _ text: String, acknowledgingThrough sequence: UInt64 = 0) {
        draftRestorationLedger.acknowledge(tabID: tabID, through: sequence)
        let pending = draftRestorationLedger.tabs[tabID]?.pendingFragments ?? []
        let storedText = pending.reduce(text) { result, fragment in
            AgentComposerDraftRestorationReducer.compose(restoredText: fragment.text, above: result)
        }
        let storedSequence = pending.last?.sequence ?? sequence
        draftRestorationLedger.markStoredDraft(tabID: tabID, through: storedSequence)
        writeDraftText(for: tabID, storedText)
    }

    /// Loading the stored text acknowledges exactly the fragments included in it.
    func loadDraftSnapshotForComposer(for tabID: UUID) -> AgentComposerDraftSnapshot {
        let snapshot = AgentComposerDraftSnapshot(
            text: retrieveDraftText(for: tabID),
            restorationSequence: draftRestorationLedger.tabs[tabID]?.storedDraftSequence ?? 0
        )
        draftRestorationLedger.acknowledge(tabID: tabID, through: snapshot.restorationSequence)
        return snapshot
    }

    private func writeDraftText(for tabID: UUID, _ text: String) {
        let previousStagedSlashCommand = stagedSlashCommandProps(tabID: tabID)
        if let session = session(for: tabID, createIfNeeded: false) {
            guard session.draftText != text else { return }
            session.draftText = text
        } else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                tabDraftText.removeValue(forKey: tabID)
            } else {
                tabDraftText[tabID] = text
            }
        }
        let nextStagedSlashCommand = stagedSlashCommandProps(tabID: tabID)
        if tabID == currentTabID, previousStagedSlashCommand != nextStagedSlashCommand {
            syncComposerUIState(tabID: tabID)
            syncStatusPillsUIState()
        }
    }

    /// Retrieve draft text for a tab
    func retrieveDraftText(for tabID: UUID) -> String {
        if let session = session(for: tabID, createIfNeeded: false) {
            return session.draftText
        }
        return tabDraftText[tabID] ?? ""
    }

    func stagedSlashCommandProps(
        tabID: UUID?,
        draftTextOverride: String? = nil
    ) -> AgentStagedSlashCommandProps? {
        guard let tabID,
              CodexGoalSupport.isEnabled
        else { return nil }
        let session = session(for: tabID, createIfNeeded: false)
        let targetAgent = session?.selectedAgent ?? (tabID == currentTabID ? selectedAgent : nil)
        guard targetAgent == .codexExec else { return nil }
        let draftText = draftTextOverride ?? session?.draftText ?? tabDraftText[tabID] ?? ""
        guard let token = Self.extractSlashSkillTokens(from: draftText).first else { return nil }
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

    func attachImages(tabID: UUID, urls: [URL]) {
        guard !urls.isEmpty else { return }
        let session = session(for: tabID)
        guard let workspaceDirectory = attachmentWorkspaceDirectoryURL() else {
            let errorItem = AgentChatItem.error("Images require an active workspace.", sequenceIndex: session.nextSequenceIndex)
            session.appendItem(errorItem)
            updateBindingsFromSession(session)
            scheduleSave(for: tabID)
            return
        }

        var seenSourcePaths: Set<String> = []
        var seenFingerprints: Set<ImageAttachmentFingerprint> = []
        for attachment in session.pendingImageAttachments {
            guard case let .localFile(path) = attachment.source else { continue }
            let fileURL = URL(fileURLWithPath: path).standardizedFileURL
            if !fileURL.path.isEmpty {
                seenSourcePaths.insert(fileURL.path)
            }
            if let fingerprint = imageAttachmentFingerprint(for: fileURL) {
                seenFingerprints.insert(fingerprint)
            }
        }

        var importedAttachments: [AgentImageAttachment] = []

        for sourceURL in urls {
            let standardizedSourceURL = sourceURL.standardizedFileURL
            if !standardizedSourceURL.path.isEmpty,
               seenSourcePaths.contains(standardizedSourceURL.path)
            {
                continue
            }

            let sourceFingerprint = imageAttachmentFingerprint(for: standardizedSourceURL)
            if let sourceFingerprint,
               seenFingerprints.contains(sourceFingerprint)
            {
                continue
            }

            do {
                let result = try attachmentStore.importImageFile(sourceURL: standardizedSourceURL, workspaceDirectory: workspaceDirectory)
                if !standardizedSourceURL.path.isEmpty {
                    seenSourcePaths.insert(standardizedSourceURL.path)
                }

                let importedFingerprint = sourceFingerprint ?? imageAttachmentFingerprint(for: result.fileURL)
                if let importedFingerprint {
                    if seenFingerprints.contains(importedFingerprint) {
                        try? FileManager.default.removeItem(at: result.fileURL)
                        continue
                    }
                    seenFingerprints.insert(importedFingerprint)
                }

                importedAttachments.append(result.attachment)
            } catch {
                let fileName = standardizedSourceURL.lastPathComponent.isEmpty ? "image" : standardizedSourceURL.lastPathComponent
                let errorItem = AgentChatItem.error("Failed to attach \(fileName): \(error.localizedDescription)", sequenceIndex: session.nextSequenceIndex)
                session.appendItem(errorItem)
            }
        }

        guard !importedAttachments.isEmpty else {
            updateBindingsFromSession(session)
            scheduleSave(for: tabID)
            return
        }

        session.pendingImageAttachments.append(contentsOf: importedAttachments)
        session.isDirty = true
        updateBindingsFromSession(session)
        scheduleSave(for: tabID)
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

    /// Paste and drop entry point: attaches when the guard allows it, otherwise explains why not.
    @discardableResult
    func attachImagesIfAllowed(tabID: UUID, urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        if let reason = imageAttachmentBlockReason(tabID: tabID) {
            reportImageAttachmentBlocked(reason, tabID: tabID)
            return false
        }
        attachImages(tabID: tabID, urls: urls)
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
        scheduleSave(for: tabID)
    }

    func removePendingImage(tabID: UUID, attachmentID: UUID) {
        let session = session(for: tabID)
        let beforeCount = session.pendingImageAttachments.count
        session.pendingImageAttachments.removeAll { $0.id == attachmentID }
        guard session.pendingImageAttachments.count != beforeCount else {
            return
        }
        session.isDirty = true
        updateBindingsFromSession(session)
        scheduleSave(for: tabID)
    }

    func clearPendingImages(tabID: UUID) {
        let session = session(for: tabID)
        guard !session.pendingImageAttachments.isEmpty else {
            return
        }
        session.pendingImageAttachments.removeAll()
        session.isDirty = true
        updateBindingsFromSession(session)
        scheduleSave(for: tabID)
    }

    func addPendingTaggedFile(tabID: UUID, relativePath: String, displayName: String? = nil) {
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }
        let normalizedPath = Self.unescapeTaggedPath(trimmedPath)
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
        scheduleSave(for: tabID)
    }

    @MainActor
    func commitPendingTaggedFile(tabID: UUID, relativePath: String, displayName: String? = nil) {
        let normalizedPath = Self.unescapeTaggedPath(relativePath)
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
        scheduleSave(for: tabID)
    }

    func syncPendingTaggedFilesFromDraft(tabID: UUID, text: String) {
        let session = session(for: tabID)
        guard !session.pendingTaggedFileAttachments.isEmpty else { return }
        let tokens = Set(Self.extractTaggedPaths(from: text).map(Self.unescapeTaggedPath(_:)))
        let beforeCount = session.pendingTaggedFileAttachments.count
        session.pendingTaggedFileAttachments.removeAll { attachment in
            let normalizedPath = Self.unescapeTaggedPath(attachment.relativePath)
            let normalizedDisplayName = Self.unescapeTaggedPath(attachment.displayName)
            return !tokens.contains(normalizedPath) && !tokens.contains(normalizedDisplayName)
        }
        guard session.pendingTaggedFileAttachments.count != beforeCount else { return }
        session.isDirty = true
        updateBindingsFromSession(session)
        scheduleSave(for: tabID)
    }

    private func imageAttachmentFingerprint(for fileURL: URL) -> ImageAttachmentFingerprint? {
        let standardizedURL = fileURL.standardizedFileURL
        guard standardizedURL.isFileURL else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: standardizedURL.path) else {
            return nil
        }
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard let data = try? Data(contentsOf: standardizedURL, options: [.mappedIfSafe]) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        let digestHex = digest.map { String(format: "%02x", $0) }.joined()
        return ImageAttachmentFingerprint(byteCount: byteCount, digestHex: digestHex)
    }

    private func attachmentWorkspaceDirectoryURL() -> URL? {
        attachmentWorkspaceDirectoryProvider()?.standardizedFileURL
    }

    // MARK: - Session Attachment Retention

    /// `<workspace>/AgentSessions/attachments` for `workspace` (the active workspace when `nil`), or
    /// `nil` when sessions are not persisted.
    func sessionAttachmentsRootURL(for workspace: WorkspaceModel? = nil) -> URL? {
        if let sessionAttachmentsRootOverride {
            return sessionAttachmentsRootOverride()?.standardizedFileURL
        }
        guard !AppLaunchConfiguration.current.suppressesAgentSessionPersistence,
              let workspace = workspace ?? workspaceManager?.activeWorkspace
        else { return nil }
        let agentSessionsFolder = WorkspaceSessionSidecarMigration
            .workspaceDirectory(for: workspace, root: AgentSessionDataService.defaultWorkspaceRootURL())
            .appendingPathComponent("AgentSessions", isDirectory: true)
        return AgentSessionAttachmentStore.rootURL(forAgentSessionsFolder: agentSessionsFolder)
    }

    /// Finished turns keep their images for the life of the session: the temporary copies are
    /// moved into `AgentSessions/attachments/<sessionID>/` off the main thread, then the user row is
    /// rewritten to the kept copy. Providers already consumed the temporary path, so their
    /// behaviour is unchanged.
    ///
    /// The destination is the root captured when the turn reserved its images, never the window's
    /// current workspace. A session that is not persisted, has no captured root, or is no longer the
    /// live owner of its tab (for example torn down by a workspace switch) deletes the copies as
    /// before. A session that stops being live mid-move keeps its files; the user row's dead
    /// temporary path is repaired from the kept copy the next time the session hydrates.
    private func retainConsumedAttachmentFiles(_ attachments: [AgentImageAttachment], session: TabSession) {
        guard clearConsumedAttachmentsAfterProviderConsumption else { return }
        guard !attachments.isEmpty else { return }
        guard let workspaceDirectory = attachmentWorkspaceDirectoryURL() else { return }
        guard let sessionID = session.activeAgentSessionID,
              let root = session.attachmentRetentionRoot,
              sessions[session.tabID] === session
        else {
            attachmentStore.clearConsumedLocalFiles(attachments, workspaceDirectory: workspaceDirectory)
            invalidateAttachmentPreviews(paths: attachments.compactMap(AgentImageAttachmentAvailabilityResolver.path(for:)))
            return
        }
        let store = AgentSessionAttachmentStore(rootURL: root, limits: sessionAttachmentLimits)
        let temporaryRoot = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
        let move = Task.detached(priority: .utility) {
            store.retain(attachments, sessionID: sessionID, temporaryRoot: temporaryRoot)
        }
        let token = UUID()
        attachmentRetentionTasks[token] = Task { @MainActor [weak self, weak session] in
            let result = await move.value
            guard let self else { return }
            attachmentRetentionTasks[token] = nil
            let movedPaths = attachments
                .filter { result.retained[$0.id] != nil }
                .compactMap(AgentImageAttachmentAvailabilityResolver.path(for:))
            invalidateAttachmentPreviews(paths: movedPaths + result.evictedPaths)
            guard let session else { return }
            applyRetainedAttachments(result.retained, to: session, sessionID: sessionID)
        }
    }

    /// Paths whose file just moved or was evicted render as missing instead of a stale cached image.
    private func invalidateAttachmentPreviews(paths: [String]) {
        guard !paths.isEmpty else { return }
        AgentAttachmentThumbnailCache.shared.invalidate(paths: paths)
    }

    /// Repairs user rows whose image path no longer exists by locating the session's kept copy
    /// (`attachments/<sessionID>/<attachmentID>.*`) in the current workspace's storage. Covers a
    /// rewrite lost because the session stopped being live mid-move, and storage that moved.
    func repairRetainedAttachmentPathsAfterHydration(_ session: TabSession, sessionID: UUID) {
        guard clearConsumedAttachmentsAfterProviderConsumption,
              let root = sessionAttachmentsRootURL()
        else { return }
        let attachments = session.items.filter { $0.kind == .user }.flatMap(\.attachments)
        guard attachments.contains(where: { if case .localFile = $0.source { true } else { false } }) else { return }
        let store = AgentSessionAttachmentStore(rootURL: root, limits: sessionAttachmentLimits)
        let token = UUID()
        attachmentRetentionTasks[token] = Task { @MainActor [weak self, weak session] in
            let repaired = await Task.detached(priority: .utility) {
                store.repairMissingPaths(attachments, sessionID: sessionID)
            }.value
            guard let self else { return }
            attachmentRetentionTasks[token] = nil
            guard let session, !repaired.isEmpty else { return }
            applyRetainedAttachments(repaired, to: session, sessionID: sessionID)
        }
    }

    /// Points every user row that carried a retained attachment at its kept copy and saves.
    func applyRetainedAttachments(_ retained: [UUID: AgentImageAttachment], to session: TabSession, sessionID: UUID) {
        guard !retained.isEmpty, session.activeAgentSessionID == sessionID else { return }
        let indices = session.items.indices.filter { index in
            session.items[index].kind == .user
                && session.items[index].attachments.contains { retained[$0.id] != nil }
        }
        guard !indices.isEmpty else { return }
        for index in indices {
            session.mutateItem(at: index) { item in
                item.attachments = item.attachments.map { retained[$0.id] ?? $0 }
            }
        }
        session.isDirty = true
        scheduleSave(for: session)
    }

    /// Awaits in-flight turn-end moves (tests and orderly teardown).
    func waitForAttachmentRetention() async {
        while let task = attachmentRetentionTasks.values.first {
            await task.value
        }
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
            let protection = liveAttachmentSweepProtection()
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

    /// Live sessions and every attachment still pending, reserved, or in flight across windows.
    func liveAttachmentSweepProtection() -> (sessionIDs: Set<UUID>, temporaryPaths: Set<String>) {
        var viewModels = WindowStatesManager.shared.allWindows.map(\.agentModeViewModel)
        if !viewModels.contains(where: { $0 === self }) {
            viewModels.append(self)
        }
        var sessionIDs: Set<UUID> = []
        var paths: Set<String> = []
        for viewModel in viewModels {
            for session in viewModel.sessions.values {
                if let sessionID = session.activeAgentSessionID {
                    sessionIDs.insert(sessionID)
                }
                var attachments = session.pendingImageAttachments + session.attachmentsPendingProviderConsumptionCleanup
                switch session.attachmentTurnState {
                case .idle:
                    break
                case let .reserved(_, turnAttachments), let .consumed(_, turnAttachments):
                    attachments.append(contentsOf: turnAttachments)
                }
                for attachment in attachments {
                    if let path = AgentImageAttachmentAvailabilityResolver.path(for: attachment) {
                        paths.insert(path)
                    }
                }
            }
        }
        return (sessionIDs, paths)
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

        var candidates: [AgentImageAttachment] = []
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

    @discardableResult
    func reserveAttachmentsForTurn(_ attachments: [AgentImageAttachment], session: TabSession) -> UUID? {
        guard !attachments.isEmpty else {
            session.attachmentTurnState = .idle
            return nil
        }
        let reservationID = UUID()
        session.attachmentTurnState = .reserved(reservationID: reservationID, attachments: attachments)
        session.attachmentRetentionRoot = sessionAttachmentsRootURL()
        return reservationID
    }

    func markAttachmentsConsumed(for session: TabSession, reservationID: UUID?) {
        switch session.attachmentTurnState {
        case .idle:
            return
        case let .reserved(storedID, attachments):
            if let reservationID, reservationID != storedID { return }
            session.attachmentTurnState = .consumed(reservationID: storedID, attachments: attachments)
        case let .consumed(storedID, _):
            if let reservationID, reservationID != storedID { return }
            return
        }
    }

    func stageConsumedAttachmentFilesForDeferredCleanup(_ attachments: [AgentImageAttachment], session: TabSession) {
        guard clearConsumedAttachmentsAfterProviderConsumption else { return }
        guard !attachments.isEmpty else { return }
        if session.attachmentsPendingProviderConsumptionCleanup.isEmpty {
            session.attachmentsPendingProviderConsumptionCleanup = attachments
            return
        }
        let existingIDs = Set(session.attachmentsPendingProviderConsumptionCleanup.map(\.id))
        let uniqueNewAttachments = attachments.filter { !existingIDs.contains($0.id) }
        session.attachmentsPendingProviderConsumptionCleanup.append(contentsOf: uniqueNewAttachments)
    }

    func consumeDeferredAttachmentCleanup(for session: TabSession, shouldDeleteFiles: Bool) {
        let attachments = session.attachmentsPendingProviderConsumptionCleanup
        session.attachmentsPendingProviderConsumptionCleanup.removeAll()
        guard shouldDeleteFiles else { return }
        retainConsumedAttachmentFiles(attachments, session: session)
    }

    func finalizeAttachmentsForTurn(
        for session: TabSession,
        reservationID: UUID? = nil,
        disposition: AttachmentTurnDisposition
    ) {
        let attachments: [AgentImageAttachment]
        switch session.attachmentTurnState {
        case .idle:
            if disposition == .deleteFiles {
                consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: true)
            } else {
                consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: false)
            }
            session.attachmentRetentionRoot = nil
            return
        case let .reserved(storedID, storedAttachments),
             let .consumed(storedID, storedAttachments):
            if let reservationID, reservationID != storedID { return }
            attachments = storedAttachments
        }

        switch disposition {
        case .restoreToPending:
            let existingIDs = Set(session.pendingImageAttachments.map(\.id))
            let unique = attachments.filter { !existingIDs.contains($0.id) }
            if !unique.isEmpty {
                session.pendingImageAttachments = unique + session.pendingImageAttachments
                session.isDirty = true
            }
            consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: false)
        case .deleteFiles:
            let hadDeferred = !session.attachmentsPendingProviderConsumptionCleanup.isEmpty
            consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: true)
            if !hadDeferred {
                retainConsumedAttachmentFiles(attachments, session: session)
            }
        case .keepFiles:
            consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: false)
        }

        session.attachmentTurnState = .idle
        session.attachmentRetentionRoot = nil
        session.isDirty = true
        scheduleSave(for: session.tabID)
    }
}
