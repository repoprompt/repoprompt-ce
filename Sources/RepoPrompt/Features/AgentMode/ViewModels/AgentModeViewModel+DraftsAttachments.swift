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
        if let repromptedText {
            repromptUIStore.recoveries[tabID] = .init(
                text: repromptedText, originalDraft: draftText, reason: message,
                draftAtInvalidation: retrieveDraftText(for: tabID)
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
        let tabID = session.tabID
        guard sessions[tabID] === session,
              let index = session.items.firstIndex(where: { $0.id == userItemID })
        else { return false }
        let item = session.items[index]
        guard item.kind == .user,
              session.items[(index + 1)...].allSatisfy({ $0.kind == .error }),
              !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              item.attachments.isEmpty,
              item.taggedFileAttachments.isEmpty,
              item.workflow == nil,
              item.crossSessionAttribution == nil,
              retrieveDraftText(for: tabID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        guard session.removeItem(at: index) != nil else { return false }
        session.pendingTurnRuntimeAnchors.removeAll { $0.userItemID == userItemID }
        session.isDirty = true
        restoreComposerDraft(tabID: tabID, text: item.text, message: message, strategy: .prependAlways)
        requestUIRefresh(tabID: tabID, urgent: true)
        scheduleSave(for: tabID)
        return true
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
        if !repromptUIStore.hasCancelledDraft(tabID: tabID, text: text) {
            repromptUIStore.clearCancelledDraft(tabID: tabID)
        }
        if let session = session(for: tabID, createIfNeeded: false) {
            guard session.draftText != text else { return }
            session.draftText = text
            if repromptOperation?.sourceTabID == tabID {
                repromptOperation?.noteUserMutation(text: text, generation: session.draftMutationGeneration)
            } else if var recovery = repromptUIStore.recoveries[tabID], recovery.bypassesPreparation,
                      !recovery.draftAtInvalidation.utf8.elementsEqual(text.utf8)
            {
                // Editing ends exact-draft authority. Preserve the old alternative without
                // re-stamping its original/classification onto an unrelated new message.
                recovery.bypassesPreparation = false
                recovery.requiresDecision = false
                repromptUIStore.recoveries[tabID] = recovery
            }
        } else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                tabDraftText.removeValue(forKey: tabID)
            } else {
                tabDraftText[tabID] = text
            }
        }
        invalidateRepromptIfNeeded()
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
        // Presentation reads must not recreate a runtime while its saved carrier is retiring.
        let session = sessions[tabID]
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
        admission: @escaping @MainActor () -> Bool = { true }
    ) -> Task<Void, Never> {
        guard !urls.isEmpty, admission() else { return Task {} }
        guard let workspaceDirectory = attachmentWorkspaceDirectoryURL() else {
            reportAttachmentFailures(
                tabID: tabID,
                messages: ["Attachments require an active workspace."]
            )
            return Task {}
        }

        let previousIntake = Self.attachmentIntakeTail
        let store = attachmentStore
        let session = session(for: tabID)
        let binding = session.persistentSessionBindingIdentity
        let bindingGeneration = session.bindingTransitionGeneration
        let intake = Task { @MainActor [weak self, weak session] in
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
        scheduleSave(for: session)
    }

    /// Publishes into the exact session the admission fence just revalidated; it never looks the tab up
    /// again, so it cannot create or reach a replacement runtime.
    private func commitAttachmentIntake(_ outcome: AgentAttachmentIntakeOutcome, to session: TabSession) {
        appendAttachmentFailures(outcome.failures.map(Self.attachmentFailureMessage), to: session)
        guard !outcome.imported.isEmpty else { return }
        session.pendingFileAttachments.append(contentsOf: outcome.imported)
        session.isDirty = true
        updateBindingsFromSession(session)
        scheduleSave(for: session)
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

    func removePendingFileAttachment(tabID: UUID, attachmentID: UUID) {
        let session = session(for: tabID)
        let beforeCount = session.pendingFileAttachments.count
        session.pendingFileAttachments.removeAll { $0.id == attachmentID }
        guard session.pendingFileAttachments.count != beforeCount else {
            return
        }
        session.isDirty = true
        updateBindingsFromSession(session)
        scheduleSave(for: tabID)
    }

    func clearPendingFileAttachments(tabID: UUID) {
        let session = session(for: tabID)
        guard !session.pendingFileAttachments.isEmpty else {
            return
        }
        session.pendingFileAttachments.removeAll()
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

    private func attachmentWorkspaceDirectoryURL() -> URL? {
        attachmentWorkspaceDirectoryProvider()?.standardizedFileURL
    }

    private func clearConsumedAttachmentFilesIfNeeded(_ attachments: [AgentFileAttachment]) {
        guard clearConsumedAttachmentsAfterProviderConsumption else { return }
        guard !attachments.isEmpty else { return }
        guard let workspaceDirectory = attachmentWorkspaceDirectoryURL() else { return }
        attachmentStore.clearConsumedLocalFiles(attachments, workspaceDirectory: workspaceDirectory)
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
            guard standardized.hasPrefix(storagePrefix),
                  !standardized.dropFirst(storagePrefix.count).contains("/"),
                  seen.insert(standardized).inserted
            else { continue }
            paths.append(standardized)
        }
        return paths
    }

    @discardableResult
    func reserveAttachmentsForTurn(_ attachments: [AgentFileAttachment], session: TabSession) -> UUID? {
        guard !attachments.isEmpty else {
            session.attachmentTurnState = .idle
            return nil
        }
        let reservationID = UUID()
        session.attachmentTurnState = .reserved(reservationID: reservationID, attachments: attachments)
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

    func stageConsumedAttachmentFilesForDeferredCleanup(_ attachments: [AgentFileAttachment], session: TabSession) {
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
        clearConsumedAttachmentFilesIfNeeded(attachments)
    }

    func finalizeAttachmentsForTurn(
        for session: TabSession,
        reservationID: UUID? = nil,
        disposition: AttachmentTurnDisposition
    ) {
        let attachments: [AgentFileAttachment]
        switch session.attachmentTurnState {
        case .idle:
            if disposition == .deleteFiles {
                consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: true)
            } else {
                consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: false)
            }
            return
        case let .reserved(storedID, storedAttachments),
             let .consumed(storedID, storedAttachments):
            if let reservationID, reservationID != storedID { return }
            attachments = storedAttachments
        }

        switch disposition {
        case .restoreToPending:
            let existingIDs = Set(session.pendingFileAttachments.map(\.id))
            let unique = attachments.filter { !existingIDs.contains($0.id) }
            if !unique.isEmpty {
                session.pendingFileAttachments = unique + session.pendingFileAttachments
                session.isDirty = true
            }
            consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: false)
        case .deleteFiles:
            let hadDeferred = !session.attachmentsPendingProviderConsumptionCleanup.isEmpty
            consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: true)
            if !hadDeferred {
                clearConsumedAttachmentFilesIfNeeded(attachments)
            }
        case .keepFiles:
            consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: false)
        }

        session.attachmentTurnState = .idle
        session.isDirty = true
        scheduleSave(for: session.tabID)
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
