import Foundation

/// User work belongs to the runtime, not the lifetime of its composer. The existing
/// fragment ledger remains the one acknowledgement authority; presentation only observes.
@MainActor
final class AgentSessionDraftRuntime {
    private weak var scope: AgentSessionRuntimeStore.Scope?
    var pendingTabDrafts: [UUID: String] = [:]
    var ledger = AgentComposerDraftRestorationLedger()

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
    }

    func makeRunHooks() -> AgentModeRunService.QueuedWorkRecoveryHooks {
        .init(
            restoreDraftText: { [self] session, text, message, strategy in
                guard let scope, !scope.hasReleasedWriterClaims else { return }
                // Compose-tab removal detaches the live object before joining cancellation.
                // Preserve its unsent work in the existing per-tab pending storage, but never
                // redirect that recovery into a different live object reusing the tab ID.
                if let current = scope.sessions[session.tabID], current !== session { return }
                _ = restore(tabID: session.tabID, text: text, message: message, strategy: strategy)
            },
            isCurrentSessionBinding: { [self] session, fence in
                scope?.sessions[session.tabID] === session
                    && session.persistentSessionBindingIdentity == fence.binding
            },
            restoreRouteRefusedUnsentTurn: { [self] session, userItemID, message in
                _ = restoreRouteRefusedUnsentTurn(session: session, userItemID: userItemID, message: message)
            }
        )
    }

    /// Recovery belongs to the original runtime, even with no attached composer. A recycled tab
    /// object must never receive the rejected input's draft, attachments, or workflow.
    @discardableResult
    func restoreRejectedSubmission(
        session: AgentTabSession, draftText: String,
        attachments: [AgentFileAttachment], taggedFiles: [AgentTaggedFileAttachment],
        workflow: AgentWorkflowDefinition?, workflowMutationGeneration: UInt64?, message: String
    ) -> Bool {
        guard let scope, let membership = scope.membership(of: session) else { return false }
        let originalWorkflowGeneration = session.userWorkflowSelectionMutationGeneration
        var changed = false
        let existingImages = Set(session.pendingFileAttachments.map(\.id))
        let restoredImages = attachments.filter { !existingImages.contains($0.id) }
        if !restoredImages.isEmpty {
            session.pendingFileAttachments = restoredImages + session.pendingFileAttachments
            changed = true
        }
        let existingPaths = Set(session.pendingTaggedFileAttachments.map(\.relativePath))
        let restoredFiles = taggedFiles.filter { !existingPaths.contains($0.relativePath) }
        if !restoredFiles.isEmpty {
            session.pendingTaggedFileAttachments = restoredFiles + session.pendingTaggedFileAttachments
            changed = true
        }
        if let workflow, let workflowMutationGeneration,
           session.userWorkflowSelectionMutationGeneration == workflowMutationGeneration,
           session.selectedWorkflow == nil
        {
            session.selectedWorkflow = workflow
            changed = true
        }
        if changed {
            session.isDirty = true
            scope.presentation.bindingChanged(session)
            scope.persistence.scheduleSave(for: session)
        }
        guard scope.membership(of: session)?.identity == membership.identity else { return false }
        let existingDraft = text(for: session.tabID)
        let composed = AgentComposerDraftRestorationReducer.compose(restoredText: draftText, above: existingDraft)
        let restoredGeneration = session.draftMutationGeneration &+ (composed == existingDraft ? 0 : 1)
        restore(
            tabID: session.tabID,
            text: composed,
            message: message,
            strategy: .replaceAlways,
            operation: .init(
                rejectedDraftText: draftText,
                draftTextBeforeRestoration: existingDraft,
                composedDraftText: composed,
                fragments: []
            )
        )
        return scope.membership(of: session)?.identity == membership.identity
            && session.draftMutationGeneration == restoredGeneration && session.draftText == composed
            && session.userWorkflowSelectionMutationGeneration == originalWorkflowGeneration
    }

    func text(for tabID: UUID) -> String {
        scope?.sessions[tabID]?.draftText ?? pendingTabDrafts[tabID] ?? ""
    }

    func write(tabID: UUID, text: String) {
        if let scope, let session = scope.sessions[tabID] {
            let previous = session.draftText
            if previous != text { session.draftText = text }
            scope.presentation.draftChanged(session, previousText: previous)
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingTabDrafts.removeValue(forKey: tabID)
        } else {
            pendingTabDrafts[tabID] = text
        }
    }

    @discardableResult
    func restore(
        tabID: UUID,
        text: String,
        message: String,
        strategy: AgentModeRunService.DraftRestorationStrategy,
        operation: AgentComposerDraftRestorationOperation? = nil
    ) -> AgentComposerDraftRestorationEvent {
        let receivingSession = scope?.sessions[tabID]
        let restoredText: String
        let restoredStrategy: AgentModeRunService.DraftRestorationStrategy
        let baseOperation: AgentComposerDraftRestorationOperation?
        if case .prependAlways = strategy, operation == nil {
            let existingDraft = self.text(for: tabID)
            restoredText = AgentComposerDraftRestorationReducer.compose(restoredText: text, above: existingDraft)
            restoredStrategy = .replaceAlways
            baseOperation = .init(
                rejectedDraftText: text, draftTextBeforeRestoration: existingDraft,
                composedDraftText: restoredText, fragments: []
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
                fragments: ledger.append(tabID: tabID, text: operation.rejectedDraftText)
            )
        }
        write(tabID: tabID, text: restoredText)
        let event = AgentComposerDraftRestorationEvent(
            id: UUID(), tabID: tabID, text: restoredText, message: message,
            strategy: restoredStrategy, operation: restoredOperation
        )
        // A synchronous presentation observer may replace the tab while handling draftChanged.
        // Never deliver this originating restoration event to that replacement.
        if let scope, let receivingSession, scope.sessions[tabID] === receivingSession {
            scope.presentation.draftRestored(receivingSession, event: event)
        }
        return event
    }

    func store(tabID: UUID, text: String, acknowledgingThrough sequence: UInt64 = 0) {
        ledger.acknowledge(tabID: tabID, through: sequence)
        let pending = ledger.tabs[tabID]?.pendingFragments ?? []
        let storedText = pending.reduce(text) { result, fragment in
            AgentComposerDraftRestorationReducer.compose(restoredText: fragment.text, above: result)
        }
        ledger.markStoredDraft(tabID: tabID, through: pending.last?.sequence ?? sequence)
        write(tabID: tabID, text: storedText)
    }

    func loadSnapshot(tabID: UUID) -> AgentComposerDraftSnapshot {
        let snapshot = AgentComposerDraftSnapshot(
            text: text(for: tabID), restorationSequence: ledger.tabs[tabID]?.storedDraftSequence ?? 0
        )
        ledger.acknowledge(tabID: tabID, through: snapshot.restorationSequence)
        return snapshot
    }

    /// A recycled tab ID cannot redirect the originating runner's refusal into a successor.
    @discardableResult
    func restoreRouteRefusedUnsentTurn(session: AgentTabSession, userItemID: UUID, message: String) -> Bool {
        guard let scope, scope.sessions[session.tabID] === session,
              let index = session.items.firstIndex(where: { $0.id == userItemID })
        else { return false }
        let item = session.items[index]
        guard item.kind == .user,
              session.items[(index + 1)...].allSatisfy({ $0.kind == .error }),
              !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              item.attachments.isEmpty, item.taggedFileAttachments.isEmpty,
              item.workflow == nil, item.crossSessionAttribution == nil,
              session.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        guard session.removeItem(at: index) != nil else { return false }
        session.pendingTurnRuntimeAnchors.removeAll { $0.userItemID == userItemID }
        session.isDirty = true
        restore(tabID: session.tabID, text: item.text, message: message, strategy: .prependAlways)
        scope.presentation.requestUIRefresh(for: session, urgent: true)
        scope.persistence.scheduleSave(for: session)
        return true
    }
}

struct AgentComposerDraftRestorationEvent: Equatable, Identifiable {
    let id: UUID
    let tabID: UUID
    let text: String
    let message: String
    let strategy: AgentModeRunService.DraftRestorationStrategy
    let operation: AgentComposerDraftRestorationOperation?
}
