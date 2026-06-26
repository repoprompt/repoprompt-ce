import CryptoKit
import Foundation

@MainActor
extension AgentModeViewModel {
    // MARK: - Draft Text Management

    func restoreComposerDraft(
        tabID: UUID,
        text: String,
        message: String,
        strategy: AgentModeRunService.DraftRestorationStrategy
    ) {
        // Also update session draft so it persists across tab switches
        storeDraftText(for: tabID, text)
        draftRestorationEvent = DraftRestorationEvent(
            id: UUID(),
            tabID: tabID,
            text: text,
            message: message,
            strategy: strategy
        )
        syncComposerUIState()
    }

    /// Store draft text for a tab
    func storeDraftText(for tabID: UUID, _ text: String) {
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

    private func clearConsumedAttachmentFilesIfNeeded(_ attachments: [AgentImageAttachment]) {
        guard clearConsumedAttachmentsAfterProviderConsumption else { return }
        guard !attachments.isEmpty else { return }
        guard let workspaceDirectory = attachmentWorkspaceDirectoryURL() else { return }
        attachmentStore.clearConsumedLocalFiles(attachments, workspaceDirectory: workspaceDirectory)
    }

    @discardableResult
    func reserveAttachmentsForTurn(_ attachments: [AgentImageAttachment], session: TabSession) -> UUID? {
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
        clearConsumedAttachmentFilesIfNeeded(attachments)
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
