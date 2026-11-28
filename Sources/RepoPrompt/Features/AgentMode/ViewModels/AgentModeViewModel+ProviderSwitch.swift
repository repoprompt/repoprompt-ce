import CryptoKit
import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

extension AgentModeViewModel {
    /// Summary provenance excludes host-owned one-shot delivery content, not stable instructions
    /// or monitor authority. Full actual instructions still own every preview currency/fit check.
    private func providerSwitchInstructionProvenance(_ session: TabSession, destination: AgentProviderKind) -> [String] {
        linkExecutionRuntime.providerSwitchInstructionStrings(session, destination: destination, includeOwedContent: false)
    }

    typealias ProviderSwitchAdmission = AgentSessionHandoffRuntime.ProviderSwitchAdmission

    func providerSwitchTransitionAdmission(
        _ session: TabSession, ownsComposerClaim: Bool = false, resolvingHandoff: PendingHandoffState? = nil
    ) -> ProviderSwitchAdmission {
        _ = runService
        return handoffRuntime.providerSwitchTransitionAdmission(
            session, ownsComposerClaim: ownsComposerClaim, resolvingHandoff: resolvingHandoff
        )
    }

    func providerSwitchTransitionBlocker(
        _ session: TabSession, ownsComposerClaim: Bool = false, resolvingHandoff: PendingHandoffState? = nil
    ) -> String? {
        switch providerSwitchTransitionAdmission(
            session, ownsComposerClaim: ownsComposerClaim, resolvingHandoff: resolvingHandoff
        ) {
        case .clear: nil
        case let .hard(message): message
        case let .forceable(cause): cause.message(provider: session.selectedAgent.displayName)
        }
    }

    /// Forced switch: decline pending interactions once, cancel an active self-compact, and stop
    /// the run through the ordinary local-Stop path. The wait is bounded by the managed-stop
    /// deadline; the stop itself keeps running in the background on timeout. Returns false when
    /// the source has not settled afterwards — a carrier rendered from it would repeat the stale
    /// in-flight-turn defect this path exists to prevent. A settled terminal state (.cancelled
    /// with publication finished, teardown still running detached) is safe to project.
    private func providerSwitchQuiesceSourceForForcedSwitch(_ claim: AgentComposerSubmitClaim) async -> Bool {
        guard interactionRuntime.declinePendingInteractionsForProviderSwitch(claim: claim) else { return false }
        let session = claim.sourceSession
        agentSelfCompactCancelForAcceptedLocalInput(session)
        guard providerSwitchSourceRunIsLive(session) else {
            // Queued work with no live run gets the same claim-time withdrawal an explicit Stop
            // runs — without manufacturing a cancelled attempt the way cancelRun would on idle.
            prepareAgentRunCancellation(session: session, intent: .userStop, origin: .explicitStop)
            linkExecutionRuntime.withdrawQueuedWorkForManagedStop(session: session)
            retireTimedOutManagedStopIfEligible(session)
            return providerSwitchSourceIsSettled(session)
        }
        // The switch destroys provider infrastructure next, so the stop awaits teardown.
        #if DEBUG
            let forceStopHook = test_providerSwitchForceStop
        #endif
        _ = await providerSwitchAwaitManagedStopDeadline {
            #if DEBUG
                if let hook = forceStopHook {
                    await hook(session)
                    return
                }
            #endif
            await self.cancelAgentRun(tabID: session.tabID, completion: .terminalTeardownCompleted)
        }
        return providerSwitchSourceIsSettled(session)
    }

    private func providerSwitchSourceRunIsLive(_ session: TabSession) -> Bool {
        session.runState.isActive || session.agentTask != nil || session.runState.isTerminalForCommit
    }

    /// Whether the source transcript is safe to project: no live run, no agent task, and no
    /// terminal commit still publishing. `isTerminalForCommit` alone is not unsettled — a fully
    /// committed .cancelled run must not count as live forever.
    private func providerSwitchSourceIsSettled(_ session: TabSession) -> Bool {
        !session.runState.isActive && session.agentTask == nil && !session.terminalCommitInProgress && session.activeRunOwnership == nil
    }

    enum ProviderSwitchDeadline: Hashable {
        case forcedStop, retirementTail, idleProbe, previewAugmentation
    }

    /// Returns the work's result, or nil when its bounded wait expires. The worker is not
    /// cancelled: captured-runtime cleanup can finish detached, while callers fence late writes.
    /// Only the cancellable stream read and deadline sleep belong to the racing task group.
    private func providerSwitchAwaitDeadline<Value: Sendable>(
        _ kind: ProviderSwitchDeadline, work: @escaping @MainActor () async -> Value
    ) async -> Value? {
        let (stream, continuation) = AsyncStream<Value>.makeStream()
        Task { @MainActor in
            await continuation.yield(work())
            continuation.finish()
        }
        var seconds = AgentRunStopState.managedStopDeadlineSeconds
        #if DEBUG
            if kind == .forcedStop || kind == .retirementTail {
                seconds = test_providerSwitchStopDeadlineSeconds
            }
            let gate = test_providerSwitchDeadlineGates[kind]
        #endif
        let deadlineSeconds = seconds
        let result = await withTaskGroup(of: Value?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                #if DEBUG
                    if let gate {
                        await gate()
                        return nil
                    }
                #endif
                try? await Task.sleep(nanoseconds: UInt64(deadlineSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        continuation.finish()
        return result
    }

    private func providerSwitchAwaitManagedStopDeadline(_ work: @escaping @MainActor () async -> Void) async -> Bool {
        await providerSwitchAwaitDeadline(.forcedStop) { await work()
            return true
        } ?? false
    }

    private func providerSwitchRequireIdle(_ session: TabSession) async -> String? {
        let result: String?? = await providerSwitchAwaitDeadline(.idleProbe) {
            do {
                #if DEBUG
                    if let hook = self.test_providerSwitchIdleProbe {
                        try await hook(session)
                        return nil as String?
                    }
                #endif
                try await AgentSessionWorktreeRuntime.requireIdleProvider(session)
                return nil as String?
            } catch { return error.localizedDescription }
        }
        switch result {
        case let .some(reason): return reason
        case .none: return AgentSessionLinkSendFailure.targetNotIdle.message
        }
    }
}

extension AgentModeViewModel {
    struct ProviderSwitchChoice {
        let mode: AgentProviderHandover.Mode
        var carrier: AgentProviderHandover.Carrier?
        var retainedPayload: String?
        var retainedOmissions: String?
        var unavailable: String?
        var hidden = false
        var bytes: Int {
            retainedPayload?.utf8.count ?? carrier?.utf8Bytes ?? 0
        }

        var label: String {
            switch mode { case .history: "Full history"
            case .newestTurns: "Recent turns"
            case .summary: "Summary" }
        }

        var omissions: String? {
            if retainedPayload != nil { return retainedOmissions }
            guard let carrier else { return nil }
            var parts: [String] = []
            if let range = carrier.omittedOlderTurns { parts.append("\(range.count) older turns") }
            if carrier.hasToolOutputOmission { parts.append("tool outputs") }
            if carrier.hasImageOmission { parts.append("images") }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    /// UI-only captured evidence. Neither its lifetime nor a completed projection authorizes a send.
    enum ProviderSwitchCursorParameterIntent {
        case select(ACPModelParameterSelection)
        case clear(ACPModelParameterIdentity)

        func applying(to selections: [ACPModelParameterSelection], model: String) -> [ACPModelParameterSelection]? {
            guard let parameters = ACPModelParameterResolver.parameterSet(providerID: .cursor, selectedModelRaw: model) else { return nil }
            switch self {
            case let .select(selection):
                guard selection.providerID == .cursor,
                      selection.identity.canonicalBaseModelRaw == ACPModelParameterIdentity.canonicalBaseModelRaw(model, providerID: .cursor),
                      let definition = parameters.definition(configID: selection.configID), definition.kind == selection.kind,
                      definition.choice(matching: selection.valueRaw) != nil else { return nil }
                return ACPModelParameterSelection.normalized(selections + [selection])
            case let .clear(identity):
                guard identity.providerID == .cursor,
                      identity.canonicalBaseModelRaw == ACPModelParameterIdentity.canonicalBaseModelRaw(model, providerID: .cursor),
                      parameters.definition(kind: identity.kind) != nil else { return nil }
                return selections.filter { $0.identity != identity }
            }
        }
    }

    struct ProviderSwitchComposition: Equatable {
        let draft: String
        let workflow: AgentWorkflowDefinition?
        let workflowRevision: UInt64
        let computerUseArmed: Bool
        let includesInterview: Bool
        let interviewPreference: Bool
        let includeCleanupGuidance: Bool
        let images: [AgentFileAttachment]
        let taggedFiles: [AgentTaggedFileAttachment]
    }

    private func providerSwitchComposition(_ session: TabSession, destination: AgentProviderKind) -> ProviderSwitchComposition {
        .init(
            draft: session.draftText.trimmingCharacters(in: .whitespacesAndNewlines),
            workflow: session.selectedWorkflow, workflowRevision: session.userWorkflowSelectionMutationGeneration,
            computerUseArmed: destination == .codexExec && session.isCodexComputerUseArmed,
            includesInterview: interviewFirst && (session.items.isEmpty || !session.items.contains(where: { $0.kind == .assistant })),
            interviewPreference: interviewFirst,
            includeCleanupGuidance: GlobalSettingsStore.shared.showBuiltInWorkflowCleanupGuidance(),
            images: session.pendingFileAttachments, taggedFiles: session.pendingTaggedFileAttachments
        )
    }

    struct ProviderSwitchGeneratedSummary {
        let text: String
        let sourceRevision: Int
        let cutoff: UUID?
        let sourceProvider: String
        let sourceModel: String
    }

    struct ProviderSwitchPreview: Identifiable {
        let id: UUID
        let tabID: UUID
        let sessionObjectID: ObjectIdentifier
        let binding: AgentSessionRestorationBindingToken?
        let workspaceID: UUID?
        let stopFence: AgentRunStartStopFence
        let sourceAgent: AgentProviderKind
        let sourceModel: String
        let sourceReasoningEffort: String?
        let sourceClaudeEffort: String?
        let source: AgentProviderHandover.Source?
        let originalHandoff: PendingHandoffState
        fileprivate let originalDescriptor: ProviderSwitchCarrierDescriptor?
        let destination: AgentProviderKind
        let model: String
        let cursorParameterIntent: ProviderSwitchCursorParameterIntent?
        let sourceParameters: [ACPModelParameterSelection]
        let composition: ProviderSwitchComposition
        var sourceRevision: Int
        var draftRevision: UInt64
        var instructions: [String]
        let instructionProvenance: [String]
        var cutoff: UUID?
        var projection: AgentProviderHandover.Projection?
        var budget: AgentProviderHandover.Budget?
        var historyReference: AgentProviderHandover.HistoryReference?
        var generatedSummary: ProviderSwitchGeneratedSummary?
        var choices: [ProviderSwitchChoice] = []
        var selected: AgentProviderHandover.Mode?
        var explicitSelection: AgentProviderHandover.Mode?
        var wordLimit: Int?
        var building = true
        var updated = false
        var failure: String?
        var generationItemID: UUID?
        var generationFinished = false
        @MainActor
        func matches(_ session: TabSession) -> Bool {
            session.tabID == tabID && ObjectIdentifier(session) == sessionObjectID
                && session.currentRestorationBindingToken == binding
        }

        var isReview: Bool {
            originalHandoff.providerSwitchDelivery != nil
        }

        var chosen: ProviderSwitchChoice? {
            choices.first { $0.mode == selected }
        }
    }

    struct ProviderSwitchBackgroundOutcome {
        let tabID: UUID
        let sessionObjectID: ObjectIdentifier
        let binding: AgentSessionRestorationBindingToken?

        @MainActor
        func matches(_ session: TabSession) -> Bool {
            session.tabID == tabID && ObjectIdentifier(session) == sessionObjectID
                && session.currentRestorationBindingToken == binding
        }
    }

    func providerSwitchIsCompletingInBackground(_ session: TabSession) -> Bool {
        guard let mutation = providerSwitchMutation, mutation.tabID == session.tabID,
              mutation.phase != .preparing,
              session.currentRestorationBindingToken == mutation.writer.restoration else { return false }
        return providerSwitchPreview?.id != mutation.previewID
    }

    /// UI-only interception. The shared picker/MCP selection predicate deliberately stays locked.
    func providerSwitchPickerRequiresPreview(_ agent: AgentProviderKind, session: TabSession) -> Bool {
        session.pendingHandoff.providerSwitchDelivery != nil || !canSelectAgentInCurrentChat(agent)
    }

    @discardableResult
    func requestProviderSwitchSelection(agent: AgentProviderKind, model: String, tabID: UUID?, cursorParameterIntent: ProviderSwitchCursorParameterIntent? = nil) -> Bool {
        guard let tabID, let session = sessions[tabID], currentTabID == tabID else { return false }
        guard providerSwitchPickerRequiresPreview(agent, session: session) else { return false }
        let binding = session.currentRestorationBindingToken
        let workspaceID = workspaceManager?.activeWorkspaceID
        Task { @MainActor [weak self] in
            guard let self, sessions[tabID] === session, session.currentRestorationBindingToken == binding,
                  workspaceManager?.activeWorkspaceID == workspaceID else { return }
            await openProviderSwitchPreview(agent: agent, model: model, tabID: tabID, cursorParameterIntent: cursorParameterIntent)
        }
        return true
    }

    /// Capture banner intent before its task hop; a later binding or slot is not the clicked chat.
    @discardableResult
    func requestProviderSwitchBannerAction(for session: TabSession, discard: Bool) -> Task<Bool, Never>? {
        guard sessions[session.tabID] === session, providerSwitchMutation == nil,
              session.pendingHandoff.providerSwitchDelivery != nil else { return nil }
        let binding = session.currentRestorationBindingToken
        let workspaceID = workspaceManager?.activeWorkspaceID
        let handoff = session.pendingHandoff
        let agent = session.selectedAgent
        let model = session.selectedModelRaw
        return Task { @MainActor [weak self] in
            guard let self, sessions[session.tabID] === session,
                  session.currentRestorationBindingToken == binding,
                  workspaceManager?.activeWorkspaceID == workspaceID,
                  session.pendingHandoff == handoff else { return false }
            if discard { return await discardProviderSwitchHandover(tabID: session.tabID) }
            return await openProviderSwitchPreview(agent: agent, model: model, tabID: session.tabID) != nil
        }
    }

    @discardableResult
    func openProviderSwitchPreview(agent: AgentProviderKind, model: String, tabID: UUID, updated: Bool = false, cursorParameterIntent: ProviderSwitchCursorParameterIntent? = nil, retainingSummary: ProviderSwitchGeneratedSummary? = nil, explicitSelection: AgentProviderHandover.Mode? = nil) async -> UUID? {
        guard providerSwitchMutation == nil, let session = sessions[tabID] else { return nil }
        providerSwitchBackgroundOutcome = nil
        let descriptor = session.pendingHandoff.providerSwitchDelivery != nil
            ? session.pendingHandoff.payload.flatMap(ProviderSwitchCarrierDescriptor.init) : nil
        // Corrupt retained source data must not acquire today's selected provider as its author.
        // A source-less Review remains available for the same claimed Discard mutation only.
        let source: AgentProviderHandover.Source? = if session.pendingHandoff.providerSwitchDelivery != nil {
            descriptor.flatMap { try? AgentProviderHandover.Source(provider: $0.sourceProvider, model: $0.sourceModel) }
        } else {
            try? AgentProviderHandover.Source(provider: session.selectedAgent.displayName, model: inputBarModelDisplayName(rawModel: session.selectedModelRaw, agentKind: session.selectedAgent))
        }
        var preview = captureProviderSwitchPreview(session, agent: agent, model: model, source: source, descriptor: descriptor, updated: updated, cursorParameterIntent: cursorParameterIntent, retainingSummary: retainingSummary)
        preview.explicitSelection = explicitSelection
        providerSwitchPreview = preview
        await buildProviderSwitchPreview(preview.id)
        // A caller may act only on the preview this request opened, never a later rebuild/owner.
        return preview.id
    }

    private func captureProviderSwitchPreview(_ session: TabSession, agent: AgentProviderKind, model: String, source: AgentProviderHandover.Source?, descriptor: ProviderSwitchCarrierDescriptor?, updated: Bool = false, cursorParameterIntent: ProviderSwitchCursorParameterIntent? = nil, retainingSummary: ProviderSwitchGeneratedSummary? = nil) -> ProviderSwitchPreview {
        let destinationModel = model.isEmpty ? defaultModelRaw(for: agent) : model
        return ProviderSwitchPreview(
            id: UUID(), tabID: session.tabID, sessionObjectID: ObjectIdentifier(session), binding: session.currentRestorationBindingToken,
            workspaceID: workspaceManager?.activeWorkspaceID,
            stopFence: AgentRunStartStopFence(session: session), sourceAgent: session.selectedAgent,
            sourceModel: session.selectedModelRaw, sourceReasoningEffort: session.selectedReasoningEffortRaw,
            sourceClaudeEffort: session.selectedClaudeEffortRaw, source: source, originalHandoff: session.pendingHandoff, originalDescriptor: descriptor,
            destination: agent, model: destinationModel, cursorParameterIntent: cursorParameterIntent,
            sourceParameters: session.acpModelParameterSelections,
            composition: providerSwitchComposition(session, destination: agent), sourceRevision: session.sourceItemsRevision,
            draftRevision: session.draftMutationGeneration,
            instructions: linkExecutionRuntime.providerSwitchInstructionStrings(session, destination: agent),
            instructionProvenance: providerSwitchInstructionProvenance(session, destination: agent),
            generatedSummary: retainingSummary, updated: updated
        )
    }

    private func providerSwitchSession(for preview: ProviderSwitchPreview) -> TabSession? {
        guard workspaceManager?.activeWorkspaceID == preview.workspaceID,
              let session = sessions[preview.tabID], preview.matches(session) else { return nil }
        return session
    }

    private func providerSwitchPreviewIdentityIsCurrent(_ preview: ProviderSwitchPreview) -> Bool {
        providerSwitchSession(for: preview) != nil
    }

    private func providerSwitchPreviewIsCurrent(_ preview: ProviderSwitchPreview, content: Bool = true) -> Bool {
        guard let session = providerSwitchSession(for: preview) else { return false }
        return session.selectedAgent == preview.sourceAgent && session.selectedModelRaw == preview.sourceModel
            && session.selectedReasoningEffortRaw == preview.sourceReasoningEffort
            && session.selectedClaudeEffortRaw == preview.sourceClaudeEffort
            && session.pendingHandoff == preview.originalHandoff
            // Fence identity, not permission: an in-progress managed stop is live state the
            // admission layer classifies, not preview drift. Run-start denial stays in the
            // start path (permitsStart), which admission still consults.
            && preview.stopFence.binding == session.persistentSessionBindingIdentity
            && preview.stopFence.cancellationGeneration == session.stopState.cancellationGeneration
            && session.acpModelParameterSelections == preview.sourceParameters
            && (!content || (
                session.sourceItemsRevision == preview.sourceRevision
                    && session.draftMutationGeneration == preview.draftRevision
                    && providerSwitchComposition(session, destination: preview.destination) == preview.composition
                    && linkExecutionRuntime.providerSwitchInstructionStrings(session, destination: preview.destination) == preview.instructions
            ))
    }

    private func providerSwitchGenerationSourceIsCurrent(_ preview: ProviderSwitchPreview) -> Bool {
        guard providerSwitchPreviewIsCurrent(preview, content: false), let session = providerSwitchSession(for: preview) else { return false }
        let composition = providerSwitchComposition(session, destination: preview.destination)
        // Draft/workflow and owed one-shot content may refit the result. includesInterview is
        // derived from history: Generate's first assistant does not change the preference.
        return composition.computerUseArmed == preview.composition.computerUseArmed
            && composition.interviewPreference == preview.composition.interviewPreference
            && composition.includeCleanupGuidance == preview.composition.includeCleanupGuidance
            && composition.images == preview.composition.images
            && composition.taggedFiles == preview.composition.taggedFiles
            && providerSwitchInstructionProvenance(session, destination: preview.destination) == preview.instructionProvenance
    }

    func providerSwitchDiscardBlocker(_ session: TabSession) -> String? {
        let preview = captureProviderSwitchPreview(session, agent: session.selectedAgent, model: session.selectedModelRaw, source: nil, descriptor: nil)
        return providerSwitchDiscardBlocker(preview)
    }

    /// Discard clears only the exact local slot. Content/budget drift is irrelevant, but
    /// binding, lifecycle, relocation and all live-work admission gates remain mandatory.
    func providerSwitchDiscardBlocker(_ preview: ProviderSwitchPreview, owningMutationID: UUID? = nil) -> String? {
        guard providerSwitchPreviewIsCurrent(preview, content: false),
              preview.isReview, let session = providerSwitchSession(for: preview), providerSwitchHasExactOwner(session)
        else { return AgentSessionLinkSendFailure.providerHandoverNeedsReview.message }
        if let mutation = providerSwitchMutation, mutation.id != owningMutationID {
            return AgentSessionLinkSendFailure.targetBusy.message
        }
        return providerSwitchTransitionBlocker(session, ownsComposerClaim: owningMutationID != nil, resolvingHandoff: preview.originalHandoff)
    }

    func providerSwitchPreviewBlocker(_ preview: ProviderSwitchPreview) -> String? {
        providerSwitchPreviewAdmission(preview).message(provider: preview.sourceAgent.displayName)
    }

    /// The sheet's one admission read: identity/intent/failure are hard, live state classifies.
    func providerSwitchPreviewAdmission(_ preview: ProviderSwitchPreview) -> ProviderSwitchAdmission {
        let needsReview = ProviderSwitchAdmission.hard(AgentSessionLinkSendFailure.providerHandoverNeedsReview.message)
        guard providerSwitchPreviewIsCurrent(preview), let session = providerSwitchSession(for: preview) else { return needsReview }
        if providerSwitchMutation != nil { return .hard(AgentSessionLinkSendFailure.targetBusy.message) }
        if let intent = preview.cursorParameterIntent,
           preview.destination != .cursor || intent.applying(to: preview.sourceParameters, model: preview.model) == nil
        {
            return needsReview
        }
        if preview.source == nil || (preview.isReview && preview.originalDescriptor == nil) {
            return needsReview
        }
        if let failure = preview.failure { return .hard(failure) }
        return providerSwitchTransitionAdmission(session, resolvingHandoff: preview.originalHandoff)
    }

    /// UI preference only; never persisted and never used as delivery evidence.
    func selectProviderSwitchChoice(_ mode: AgentProviderHandover.Mode, previewID: UUID) {
        guard let preview = providerSwitchPreview, preview.id == previewID,
              preview.generationItemID == nil,
              Self.providerSwitchSelection(choices: preview.choices, explicit: mode, retained: nil) == mode
        else { return }
        providerSwitchPreview?.explicitSelection = mode
        providerSwitchPreview?.selected = mode
    }

    static func providerSwitchSelection(
        choices: [ProviderSwitchChoice], explicit: AgentProviderHandover.Mode?, retained: AgentProviderHandover.Mode?
    ) -> AgentProviderHandover.Mode? {
        [explicit, retained, .history, .newestTurns].compactMap(\.self).first { mode in
            choices.contains { $0.mode == mode && !$0.hidden && $0.unavailable == nil && $0.bytes > 0 }
        }
    }

    private func buildProviderSwitchPreview(_ id: UUID) async {
        guard var preview = providerSwitchPreview, preview.id == id else { return }
        guard let session = providerSwitchSession(for: preview) else { return }
        guard let source = preview.source else {
            providerSwitchPreview?.building = false
            providerSwitchPreview?.failure = AgentSessionLinkSendFailure.providerHandoverNeedsReview.message
            return
        }
        let transcript = session.transcript
        let items = session.items
        let nextSequence = session.nextSequenceIndex
        let state = session.runState
        let originalSlot = preview.originalHandoff
        let stale = AgentSessionLinkExecutionRuntime.providerSwitchNeedsReview(session)
        let composition = preview.composition
        let wrapped = composeProviderSwitchPreviewDraft(composition, destination: preview.destination, session: session)
        let live: @MainActor () -> Bool = { [weak self] in
            self?.providerSwitchPreview?.id == id && self?.providerSwitchPreview?.building == true
                && self?.providerSwitchPreview?.failure == nil
        }
        let stage: String?? = await providerSwitchAwaitDeadline(.previewAugmentation) {
            let initial = await self.augmentUserMessageForProviderSend(
                wrapped, attachments: composition.images,
                taggedFileAttachments: composition.taggedFiles, agent: preview.destination,
                session: session, ignoresPendingHandoff: true, shouldPublishCatalog: live
            )
            guard live() else { return nil as String? }
            return await self.buildInitialThreadMessageIfNeeded(tabID: session.tabID, session: session, initialMessage: initial, assumeFreshProvider: preview.destination == .codexExec)
        }
        guard live() else { return }
        guard let composed = stage ?? nil else {
            providerSwitchPreview?.building = false
            providerSwitchPreview?.failure = AgentSessionLinkSendFailure.targetNotIdle.message
            return
        }
        guard providerSwitchPreviewIsCurrent(preview) else {
            refreshProviderSwitchPreviewAfterDrift(preview)
            return
        }
        let budget = AgentProviderHandover.Budget(
            catalogWindow: linkExecutionRuntime.providerSwitchCatalogWindow(agent: preview.destination, model: preview.model),
            instructions: preview.instructions, composedInput: "\n\n" + composed, isPreview: true,
            codexCarrierScalars: preview.destination == .codexExec
                ? AgentProviderHandover.codexCarrierAllowance(composedInput: composed, parkedNote: session.selfCompactState.parkedNote?.frame) : nil
        )
        let server = preview.destination == .grokBuild ? RepoPromptMCPServerConfiguration.grokBuildRuntimeServerName : MCPIntegrationHelper.repoPromptMCPServerName
        let reference = try? session.activeAgentSessionID.flatMap {
            try AgentProviderHandover.HistoryReference(
                server: server,
                sessionID: $0,
                historyAllowed: linkExecutionRuntime.providerSwitchHistoryToolAllowed(session, destination: preview.destination),
                indicesMatch: true
            )
        }
        do {
            let result = try await providerSwitchProjectedCarriers(
                transcript: transcript, items: items, nextSequence: nextSequence, state: state,
                originalSlot: originalSlot, stale: stale, source: source, reference: reference,
                budget: budget
            )
            guard providerSwitchPreview?.id == id else { return }
            guard providerSwitchPreviewIsCurrent(preview) else {
                refreshProviderSwitchPreviewAfterDrift(preview)
                return
            }
            preview.projection = result.projection
            preview.budget = budget
            preview.historyReference = reference
            preview.cutoff = result.cutoff
            preview.wordLimit = preview.isReview ? nil : result.wordLimit
            // A newest-turns suffix that covers every projected turn carries the same body as full
            // history; two identical rows are noise, so drop it whenever full history also fits.
            let recentDuplicatesFull = result.recent.map {
                $0.turnIndices == result.full.turnIndices
                    && $0.omittedOlderTurns == nil
                    && $0.hasToolOutputOmission == result.full.hasToolOutputOmission
                    && $0.hasImageOmission == result.full.hasImageOmission
            } ?? false
            preview.choices = [
                .init(mode: .history, carrier: result.full, unavailable: budget.fits(result.full) ? nil : "Full history doesn't fit."),
                .init(mode: .newestTurns, carrier: result.recent, unavailable: result.recent == nil ? "the last turn alone doesn't fit" : nil, hidden: recentDuplicatesFull && budget.fits(result.full)),
                .init(mode: .summary, unavailable: preview.isReview ? AgentSessionLinkSendFailure.providerHandoverNeedsReview.message : (result.wordLimit == nil ? "no room for a summary" : nil), hidden: !preview.isReview)
            ]
            if !stale, let payload = originalSlot.payload, let descriptor = preview.originalDescriptor,
               linkExecutionRuntime.providerSwitchReadReferenceIsCurrent(descriptor, session: session, destination: preview.destination),
               let mode = AgentProviderHandover.Mode(rawValue: descriptor.mode),
               budget.fits(payload: payload, mode: mode)
            {
                var index = preview.choices.firstIndex(where: { $0.mode == mode && !$0.hidden })
                if index == nil, mode == .newestTurns,
                   let hiddenIndex = preview.choices.firstIndex(where: { $0.mode == .newestTurns })
                {
                    // The saved carrier may predate a budget that now fits full history; when it
                    // differs from the fresh suffix it is real approved content, so un-hide the
                    // row rather than retaining it under the Full history label.
                    if let carrier = preview.choices[hiddenIndex].carrier,
                       payload != AgentProviderHandover.render(carrier)
                    {
                        preview.choices[hiddenIndex].hidden = false
                        index = hiddenIndex
                    }
                }
                if index == nil, mode == .newestTurns {
                    index = preview.choices.firstIndex(where: { $0.mode == .history })
                }
                if let index {
                    preview.choices[index].retainedPayload = payload
                    preview.choices[index].retainedOmissions = descriptor.omissions.isEmpty ? nil : descriptor.omissions.joined(separator: ", ")
                    preview.choices[index].unavailable = nil
                    preview.selected = preview.choices[index].mode
                }
            }
            if let summary = preview.generatedSummary {
                fitProviderSwitchSummary(summary, into: &preview)
            } else if !preview.isReview, let summary = handoffRuntime.providerSwitchSummary(for: session),
                      summary.destination == preview.destination, summary.model == preview.model,
                      case let .generated(text, revision)? = summary.outcome, revision == preview.sourceRevision
            {
                fitProviderSwitchSummary(.init(
                    text: text, sourceRevision: revision, cutoff: preview.cutoff,
                    sourceProvider: source.provider, sourceModel: source.model
                ), into: &preview)
            }
            let retainedSelection = preview.selected
            // Read the live pick after the last suspension, not the build's stale value copy.
            preview.explicitSelection = providerSwitchPreview?.explicitSelection
            preview.selected = Self.providerSwitchSelection(
                choices: preview.choices, explicit: preview.explicitSelection, retained: retainedSelection
            )
            preview.building = false
            providerSwitchPreview = preview
        } catch {
            guard providerSwitchPreview?.id == id else { return }
            providerSwitchPreview?.building = false
            providerSwitchPreview?.failure = error.localizedDescription
        }
    }

    /// Canonical retained-turn projection into the switch carriers. Preview building and the
    /// forced-apply post-stop re-render share this so both measure identical cutoff and fit
    /// semantics; only the transcript snapshot differs.
    private func providerSwitchProjectedCarriers(
        transcript: AgentTranscript, items: [AgentChatItem], nextSequence: Int,
        state: AgentSessionRunState?, originalSlot: PendingHandoffState, stale: Bool,
        source: AgentProviderHandover.Source, reference: AgentProviderHandover.HistoryReference?,
        budget: AgentProviderHandover.Budget
    ) async throws -> (projection: AgentProviderHandover.Projection, full: AgentProviderHandover.Carrier, recent: AgentProviderHandover.Carrier?, wordLimit: Int?, cutoff: UUID?) {
        try await Task.detached(priority: .userInitiated) {
            var canonical = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: transcript, workingItems: items, terminalState: state,
                nextSequenceIndex: nextSequence, policy: .canonical
            )
            // Only canonical retained anchors survive normalization/save/restore. A raw tail
            // can be one of import's three filtered meta tools and is not a durable cutoff.
            var anchors: [(id: UUID, sequence: Int, reason: String?)] = []
            var appliedNotices: [Int] = []
            for turn in canonical.turns {
                if let request = turn.request { anchors.append((request.id, request.sequenceIndex, nil)) }
                for activity in turn.allActivities {
                    anchors.append((activity.id, activity.sequenceIndex, activity.recoveryDiagnostic?.reason))
                    if activity.recoveryDiagnostic?.reason == "providerSwitch", activity.recoveryDiagnostic?.outcome == "applied" { appliedNotices.append(activity.sequenceIndex) }
                }
                for diagnostic in turn.summary?.recoveryDiagnostics ?? [] {
                    anchors.append((diagnostic.id, diagnostic.sequenceIndex, diagnostic.reason))
                    if diagnostic.reason == "providerSwitch", diagnostic.outcome == "applied" { appliedNotices.append(diagnostic.sequenceIndex) }
                }
            }
            let originalSequence = originalSlot.sourceItemID.flatMap { oldID in anchors.first(where: { $0.id == oldID })?.sequence }
            let ownAppliedSequence = appliedNotices.filter { sequence in originalSequence.map { sequence > $0 } ?? true }.max()
            func isOwnPendingNotice(_ sequence: Int, reason: String?) -> Bool {
                guard originalSlot.providerSwitchDelivery != nil, reason == "providerSwitch" else { return false }
                if let originalSequence { return sequence > originalSequence }
                // Nil/missing old cutoff must not erase older completed switches. The latest
                // applied notice identifies this still-pending transition without a new field.
                return ownAppliedSequence.map { sequence >= $0 } ?? false
            }
            let cutoff = (!stale && originalSlot.providerSwitchDelivery != nil) ? originalSlot.sourceItemID
                : anchors.filter { !isOwnPendingNotice($0.sequence, reason: $0.reason) }.max(by: { $0.sequence < $1.sequence })?.id
            let cutoffSequence = cutoff.flatMap { id in anchors.first(where: { $0.id == id })?.sequence }
            if let cutoffSequence {
                canonical.turns = canonical.turns.filter { turn in
                    (turn.request?.sequenceIndex ?? turn.allActivities.first?.sequenceIndex ?? turn.summary?.recoveryDiagnostics?.first?.sequenceIndex ?? 0) <= cutoffSequence
                }
            }
            // Keep original ordinals, including retained compacted diagnostic anchors. Strip
            // this pending transition's own notices even when its original history was empty.
            for t in canonical.turns.indices {
                for s in canonical.turns[t].responseSpans.indices {
                    canonical.turns[t].responseSpans[s].activities.removeAll { activity in
                        (cutoffSequence.map { activity.sequenceIndex > $0 } ?? false)
                            || isOwnPendingNotice(activity.sequenceIndex, reason: activity.recoveryDiagnostic?.reason)
                    }
                }
                canonical.turns[t].summary?.recoveryDiagnostics?.removeAll { diagnostic in
                    (cutoffSequence.map { diagnostic.sequenceIndex > $0 } ?? false)
                        || isOwnPendingNotice(diagnostic.sequenceIndex, reason: diagnostic.reason)
                }
            }
            let projection = try AgentProviderHandover.project(canonical)
            let full = AgentProviderHandover.history(projection, source: source, historyReference: reference)
            let recent = AgentProviderHandover.newestCompleteTurns(projection, source: source, historyReference: reference, budget: budget)
            let words = AgentProviderHandover.summaryWordLimit(for: projection, source: source, historyReference: reference, budget: budget)
            return (projection, full, recent, words, cutoff)
        }.value
    }

    private func refreshProviderSwitchPreviewAfterDrift(_ preview: ProviderSwitchPreview) {
        guard providerSwitchPreview?.id == preview.id else { return }
        providerSwitchPreview?.building = false
        providerSwitchPreview?.failure = AgentSessionLinkSendFailure.providerHandoverNeedsReview.message
        guard providerSwitchPreviewIdentityIsCurrent(preview) else { return }
        queueProviderSwitchPreviewRefresh(preview)
    }

    private func queueProviderSwitchPreviewRefresh(_ preview: ProviderSwitchPreview) {
        guard let session = providerSwitchSession(for: preview) else { return }
        providerSwitchPreview?.building = true
        Task { @MainActor [weak self] in
            guard let self, providerSwitchPreview?.id == preview.id else { return }
            #if DEBUG
                await test_beforeProviderSwitchPreviewRefresh?(session)
            #endif
            guard providerSwitchPreview?.id == preview.id else { return }
            guard providerSwitchPreviewIdentityIsCurrent(preview) else {
                providerSwitchPreview?.building = false
                providerSwitchPreview?.failure = AgentSessionLinkSendFailure.providerHandoverNeedsReview.message
                return
            }
            let composition = providerSwitchComposition(session, destination: preview.destination)
            let canRetain = session.sourceItemsRevision == preview.sourceRevision
                && session.selectedAgent == preview.sourceAgent
                && session.selectedModelRaw == preview.sourceModel
                && session.selectedReasoningEffortRaw == preview.sourceReasoningEffort
                && session.selectedClaudeEffortRaw == preview.sourceClaudeEffort
                && session.acpModelParameterSelections == preview.sourceParameters
                && composition.computerUseArmed == preview.composition.computerUseArmed
                && composition.includesInterview == preview.composition.includesInterview
                && composition.interviewPreference == preview.composition.interviewPreference
                && composition.includeCleanupGuidance == preview.composition.includeCleanupGuidance
                && composition.images == preview.composition.images && composition.taggedFiles == preview.composition.taggedFiles
                && providerSwitchInstructionProvenance(session, destination: preview.destination) == preview.instructionProvenance
            await openProviderSwitchPreview(agent: preview.destination, model: preview.model, tabID: preview.tabID, updated: true, cursorParameterIntent: preview.cursorParameterIntent, retainingSummary: canRetain ? preview.generatedSummary : nil, explicitSelection: providerSwitchPreview?.explicitSelection)
        }
    }

    func providerSwitchPreviewDidChange(_ session: TabSession) {
        guard let preview = providerSwitchPreview, preview.matches(session),
              !preview.building, preview.generationItemID == nil, providerSwitchMutation == nil,
              !providerSwitchPreviewIsCurrent(preview) else { return }
        // Identity loss is not refreshable configuration drift. Keep the original intent blocked.
        guard providerSwitchPreviewIdentityIsCurrent(preview) else {
            providerSwitchPreview?.failure = AgentSessionLinkSendFailure.providerHandoverNeedsReview.message
            return
        }
        queueProviderSwitchPreviewRefresh(preview)
    }

    func cancelProviderSwitchPreview() {
        if let mutation = providerSwitchMutation, mutation.phase == .preparing {
            handoffRuntime.endProviderSwitchMutation(mutation.id)
        }
        providerSwitchPreview = nil
    }

    func providerSwitchPayload(_ id: UUID, mode: AgentProviderHandover.Mode) async -> String? {
        guard let preview = providerSwitchPreview, preview.id == id,
              let choice = preview.choices.first(where: { $0.mode == mode }) else { return nil }
        if let payload = choice.retainedPayload { return payload }
        guard let carrier = choice.carrier else { return nil }
        let payload = await Task.detached(priority: .userInitiated) { AgentProviderHandover.render(carrier) }.value
        guard providerSwitchPreview?.id == id, providerSwitchPreviewIsCurrent(preview) else { return nil }
        return payload
    }

    /// Forced apply only: project the post-stop source transcript and rebuild the selected
    /// carrier under the preview's budget. A generated summary refits onto the fresh projection;
    /// a retained payload is never consulted — trajectory modes rebuild fresh, and a summary
    /// selection without generated text refuses rather than staging pre-stop bytes. The returned
    /// revision is the `sourceItemsRevision` observed with the snapshot, so callers can detect
    /// rows that landed during the detached projection. Nil means do not proceed.
    private func providerSwitchForcedHandoverPayload(
        _ preview: ProviderSwitchPreview, session: TabSession
    ) async -> (payload: String, cutoff: UUID?, revision: Int)? {
        guard let source = preview.source, let budget = preview.budget else { return nil }
        let revision = session.sourceItemsRevision
        do {
            let result = try await providerSwitchProjectedCarriers(
                transcript: session.transcript, items: session.items,
                nextSequence: session.nextSequenceIndex, state: session.runState,
                originalSlot: preview.originalHandoff,
                stale: AgentSessionLinkExecutionRuntime.providerSwitchNeedsReview(session), source: source,
                reference: preview.historyReference, budget: budget
            )
            let carrier: AgentProviderHandover.Carrier? = switch preview.selected ?? .history {
            case .history: result.full
            case .newestTurns: result.recent
            case .summary:
                try preview.generatedSummary.map {
                    try AgentProviderHandover.summary($0.text, of: result.projection, source: source, historyReference: preview.historyReference)
                }
            }
            guard let carrier, budget.fits(carrier) else { return nil }
            let rendered = await Task.detached(priority: .userInitiated) { AgentProviderHandover.render(carrier) }.value
            return (rendered, result.cutoff, revision)
        } catch {
            return nil
        }
    }

    private func providerSwitchHasExactOwner(_ session: TabSession) -> Bool {
        providerSwitchExactOwnerProbe?(session) ?? false
    }

    private func providerSwitchClaim(_ preview: ProviderSwitchPreview, discard: Bool = false, allowsPendingStartWithdrawal: Bool = true) -> AgentComposerSubmitClaim? {
        guard providerSwitchPreviewIsCurrent(preview, content: !discard), let session = providerSwitchSession(for: preview), providerSwitchHasExactOwner(session),
              let target = makeComposerSubmitTarget(tabID: preview.tabID, session: session) else { return nil }
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 0,
            noticeRevision: 0,
            rawDraftSnapshot: session.draftText
        )
        guard case let .claimed(claim) = claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false, allowsPendingStartWithdrawal: allowsPendingStartWithdrawal) else { return nil }
        return claim
    }

    /// Explicit Generate is one ordinary source run. It never consumes the composer's workflow or
    /// attachments, never claims local authorship, and never applies or queues a provider switch.
    func generateProviderSwitchHandover(_ id: UUID) async {
        guard let preview = providerSwitchPreview, preview.id == id, !preview.isReview,
              let words = preview.wordLimit, let request = AgentProviderHandover.summaryRequest(wordLimit: words),
              providerSwitchPreviewBlocker(preview) == nil, let claim = providerSwitchClaim(preview) else { return }
        defer { releaseComposerSubmitClaim(claim) }
        guard let session = providerSwitchSession(for: preview) else { return }
        if let failure = await providerSwitchRequireIdle(session) {
            if providerSwitchPreview?.id == id {
                providerSwitchPreview?.failure = failure
            }
            return
        }
        guard providerSwitchPreview?.id == id, providerSwitchPreviewIsCurrent(preview), composerSubmitRuntime.isCurrent(claim),
              providerSwitchTransitionBlocker(session, ownsComposerClaim: true) == nil,
              let command = claim.command, let links = claim.scope.linkExecution else { return }
        let handoff = claim.scope.handoff
        // Register on the exact writer before appending the provider-facing request.
        let row = AgentChatItem.user(request, sequenceIndex: session.nextSequenceIndex)
        guard handoff.registerProviderSwitchSummary(command: command, rowID: row.id, destination: preview.destination, model: preview.model)
        else { return }
        providerSwitchPreview?.generationItemID = row.id
        providerSwitchPreview?.selected = .summary
        session.appendItem(row)
        session.isDirty = true
        guard case .success = await claim.scope.persistence.flushSaveRequired(writer: command.writer),
              command.isCurrent, preview.stopFence.permitsStart(of: session),
              handoff.providerSwitchSummary(for: session)?.requestRowID == row.id
        else {
            let message = AgentSessionLinkSendFailure.persistenceIndeterminate.message
            handoff.failProviderSwitchSummary(session, rowID: row.id, message: message)
            if providerSwitchPreview?.id == id {
                providerSwitchPreview?.generationItemID = nil
                if let index = providerSwitchPreview?.choices.firstIndex(where: { $0.mode == .summary }) {
                    providerSwitchPreview?.choices[index].unavailable = message
                }
            }
            return
        }
        #if DEBUG
            if let test_providerSwitchGeneration {
                await test_providerSwitchGeneration(session, row.id, request)
                handoff.settleProviderSwitchSummary(session)
                return
            }
        #endif
        let outcome = AgentRunStartOutcomeRecorder()
        #if DEBUG
            if let test_providerSwitchGenerationStart {
                await test_providerSwitchGenerationStart(session, request, outcome)
            } else {
                _ = await links.startAgentRun(command: command, initialMessage: request, directStartOptions: .init(ignoresPendingHandoff: true, stopFence: preview.stopFence, initialUserItemID: row.id), startOutcome: outcome, providerSwitchPreparation: nil)
            }
        #else
            _ = await links.startAgentRun(command: command, initialMessage: request, directStartOptions: .init(ignoresPendingHandoff: true, stopFence: preview.stopFence, initialUserItemID: row.id), startOutcome: outcome, providerSwitchPreparation: nil)
        #endif
        if !outcome.outcome.didStart {
            handoff.failProviderSwitchSummary(session, rowID: row.id, message: AgentSessionLinkSendFailure.targetNotIdle.message)
            guard providerSwitchPreview?.id == id, providerSwitchPreview?.generationItemID == row.id else { return }
            providerSwitchPreview?.generationItemID = nil
            if let index = providerSwitchPreview?.choices.firstIndex(where: { $0.mode == .summary }) {
                providerSwitchPreview?.choices[index].unavailable = AgentSessionLinkSendFailure.targetNotIdle.message
            }
        } else { session.clearAgentSessionLinkWaitingOnAfterAcceptedTurn() }
    }

    func providerSwitchGenerationSettled(_ session: TabSession) {
        guard let preview = providerSwitchPreview, preview.matches(session),
              sessions[session.tabID] === session, session.currentRestorationBindingToken == preview.binding,
              workspaceManager?.activeWorkspaceID == preview.workspaceID,
              session.pendingHandoff == preview.originalHandoff,
              let rowID = preview.generationItemID, !preview.generationFinished else { return }
        guard let result = handoffRuntime.providerSwitchSummary(for: session),
              result.requestRowID == rowID, let outcome = result.outcome else { return }
        providerSwitchPreview?.generationFinished = true
        guard providerSwitchGenerationSourceIsCurrent(preview) else {
            refreshProviderSwitchPreviewAfterDrift(preview)
            return
        }
        let settledRevision = session.sourceItemsRevision
        Task { @MainActor [weak self] in
            #if DEBUG
                defer { self?.test_providerSwitchGenerationRebuildDidFinish?() }
            #endif
            guard let self, providerSwitchPreview?.id == preview.id,
                  sessions[session.tabID] === session, session.currentRestorationBindingToken == preview.binding,
                  workspaceManager?.activeWorkspaceID == preview.workspaceID,
                  session.pendingHandoff == preview.originalHandoff else { return }
            guard providerSwitchGenerationSourceIsCurrent(preview) else {
                refreshProviderSwitchPreviewAfterDrift(preview)
                return
            }
            let openedID = await openProviderSwitchPreview(agent: preview.destination, model: preview.model, tabID: session.tabID, updated: true, cursorParameterIntent: preview.cursorParameterIntent)
            guard let openedID, var current = providerSwitchPreview, current.id == openedID, current.matches(session),
                  current.originalHandoff == preview.originalHandoff, !current.isReview,
                  session.sourceItemsRevision == settledRevision, current.binding == preview.binding,
                  current.projection != nil, current.budget != nil else { return }
            guard providerSwitchGenerationSourceIsCurrent(preview) else {
                refreshProviderSwitchPreviewAfterDrift(current)
                return
            }
            guard let index = current.choices.firstIndex(where: { $0.mode == .summary }) else { return }
            switch outcome {
            case let .generated(text, sourceRevision):
                if sourceRevision == settledRevision, let source = current.source {
                    fitProviderSwitchSummary(.init(
                        text: text, sourceRevision: sourceRevision, cutoff: current.cutoff,
                        sourceProvider: source.provider, sourceModel: source.model
                    ), into: &current)
                }
            case let .unavailable(reason):
                current.choices[index].unavailable = reason
            }
            providerSwitchPreview = current
        }
    }

    private func fitProviderSwitchSummary(_ summary: ProviderSwitchGeneratedSummary, into preview: inout ProviderSwitchPreview) {
        guard !preview.isReview, preview.sourceRevision == summary.sourceRevision, preview.cutoff == summary.cutoff,
              let source = preview.source, source.provider == summary.sourceProvider, source.model == summary.sourceModel,
              let projection = preview.projection, let budget = preview.budget,
              let index = preview.choices.firstIndex(where: { $0.mode == .summary }),
              let carrier = try? AgentProviderHandover.summary(summary.text, of: projection, source: source, historyReference: preview.historyReference)
        else {
            preview.generatedSummary = nil
            return
        }
        preview.generatedSummary = summary
        preview.choices[index].carrier = budget.fits(carrier) ? carrier : nil
        preview.choices[index].unavailable = budget.fits(carrier) ? nil : "the summary is too large"
        if budget.fits(carrier), !preview.choices[index].hidden { preview.selected = .summary }
    }

    /// One claimed, same-identity mutation for Switch/Replace and Discard. Native retirement is
    /// irreversible; rollback restores resumable references, never resurrects shutdown controllers.
    @discardableResult
    func applyProviderSwitch(_ id: UUID, discard: Bool = false, force: Bool = false) async -> Bool {
        guard let preview = providerSwitchPreview, preview.id == id else { return false }
        return await applyProviderSwitch(preview, discard: discard, force: force, requiresPresentedPreview: true)
    }

    @discardableResult
    func discardProviderSwitchHandover(tabID: UUID) async -> Bool {
        guard providerSwitchMutation == nil, let session = sessions[tabID], session.pendingHandoff.providerSwitchDelivery != nil else { return false }
        // Discard needs exact local ownership, not a valid source descriptor or a rendered sheet.
        var preview = captureProviderSwitchPreview(session, agent: session.selectedAgent, model: session.selectedModelRaw, source: nil, descriptor: nil)
        preview.building = false
        return await applyProviderSwitch(preview, discard: true, requiresPresentedPreview: false)
    }

    private func applyProviderSwitch(_ preview: ProviderSwitchPreview, discard: Bool, force: Bool = false, requiresPresentedPreview: Bool) async -> Bool {
        let id = preview.id
        // Force only bypasses the source's own liveness; every hard blocker still refuses.
        let forcing = force && !discard && !preview.isReview
        guard !preview.building,
              preview.generationItemID == nil,
              discard
              ? providerSwitchDiscardBlocker(preview) == nil
              : providerSwitchPreviewAdmission(preview).isAdmissible(forcing: forcing),
              discard ? preview.isReview : (preview.chosen != nil && preview.chosen?.unavailable == nil),
              // This claim owns a lifecycle mutation, not an input waiting to start. Forced
              // quiescence withdraws queued input through Stop without cancelling its own claim.
              let claim = providerSwitchClaim(preview, discard: discard, allowsPendingStartWithdrawal: false), let command = claim.command else { return false }
        defer { releaseComposerSubmitClaim(claim) }
        let session = command.writer.session
        var rollback = AgentSessionHandoffRuntime.ProviderSwitchRollback(session)
        let handoff = claim.scope.handoff
        guard let mutation = handoff.beginProviderSwitchMutation(command: command, previewID: preview.id) else { return false }
        providerSwitchBackgroundOutcome = nil
        objectWillChange.send()
        defer {
            handoff.endProviderSwitchMutation(mutation.id)
            objectWillChange.send()
        }
        func current() -> Bool {
            // Forcing deliberately mutates the source's live state (declines interactions, stops
            // the run); the content-revision currency check would abort on that intended drift.
            // Identity (session, binding, workspace) still has to hold in either mode.
            let previewCurrent = forcing
                ? providerSwitchPreviewIdentityIsCurrent(preview)
                : providerSwitchPreviewIsCurrent(preview, content: !discard)
            return claim.scope.submissions.isCurrent(claim) && command.isCurrent && handoff.providerSwitchMutation?.id == mutation.id
                && (!requiresPresentedPreview || providerSwitchPreview?.id == id) && previewCurrent
                && providerSwitchHasExactOwner(session)
                && (
                    discard ? providerSwitchDiscardBlocker(preview, owningMutationID: mutation.id) == nil
                        : providerSwitchTransitionAdmission(
                            session, ownsComposerClaim: true, resolvingHandoff: preview.originalHandoff
                        ).isAdmissible(forcing: forcing)
                )
        }
        func transactionCurrent() -> Bool {
            let sourceCurrent = forcing ? providerSwitchPreviewIdentityIsCurrent(preview)
                : (
                    providerSwitchPreviewIsCurrent(preview, content: false)
                        && session.sourceItemsRevision == preview.sourceRevision
                        && linkExecutionRuntime.providerSwitchInstructionStrings(session, destination: preview.destination) == preview.instructions
                )
            return claim.scope.submissions.isCurrent(claim) && command.isCurrent && handoff.providerSwitchMutation?.id == mutation.id
                && sourceCurrent
                && providerSwitchHasExactOwner(session)
                && providerSwitchTransitionAdmission(session, ownsComposerClaim: true, resolvingHandoff: preview.originalHandoff).isAdmissible(forcing: forcing)
        }
        func presentFailure(_ message: String) {
            guard requiresPresentedPreview else { return }
            if providerSwitchPreview?.id == id {
                providerSwitchPreview?.failure = message
            } else if providerSwitchMutation?.id == mutation.id, providerSwitchPreviewIdentityIsCurrent(preview) {
                providerSwitchBackgroundOutcome = .init(tabID: session.tabID, sessionObjectID: ObjectIdentifier(session), binding: preview.binding)
            }
        }
        func surfaceReviewFailure() {
            presentFailure(AgentSessionLinkSendFailure.providerHandoverNeedsReview.message)
        }
        do {
            guard current() else { return false }
            // A forced switch renders its carrier after the managed stop below: the preview's
            // carriers were projected before the quiesce and would stage a live in-flight turn
            // with no record of the stop.
            var payload = (discard || forcing) ? nil : await providerSwitchPayload(id, mode: preview.selected ?? .history)
            guard discard || payload != nil || forcing, current() else { return false }
            var cutoff = preview.cutoff
            let change: AgentSessionHandoffRuntime.ProviderSwitchCommit
            let message: String
            if !discard {
                var stagedRevision: Int?
                if forcing {
                    guard await providerSwitchQuiesceSourceForForcedSwitch(claim), current() else {
                        // The quiesce already ran; a late refusal must surface, not fail silently.
                        surfaceReviewFailure()
                        return false
                    }
                    // Build and fit the selected carrier here, before irreversible retirement:
                    // the predictable no-longer-fits refusal must not tear the provider down
                    // first, and the pre-stop bytes must never stage.
                    guard let refreshed = await providerSwitchForcedHandoverPayload(preview, session: session),
                          session.sourceItemsRevision == refreshed.revision,
                          providerSwitchSourceIsSettled(session), current()
                    else {
                        surfaceReviewFailure()
                        return false
                    }
                    payload = refreshed.payload
                    cutoff = refreshed.cutoff
                    stagedRevision = refreshed.revision
                } else {
                    if let failure = await providerSwitchRequireIdle(session) {
                        presentFailure(failure)
                        return false
                    }
                    guard current() else { return false }
                }
                if forcing {
                    // The transcript now reflects the stop; any later refusal restores this
                    // stopped source, never the pre-stop snapshot.
                    rollback = AgentSessionHandoffRuntime.ProviderSwitchRollback(session)
                }
                // Detached shutdown can hang on a wedged provider; bound the wait on the shared
                // managed-stop deadline, never the mutation. The work itself is never cancelled —
                // a slow provider still finishes retiring detached.
                let retirementOverride: (@MainActor (TabSession) async -> Void)?
                #if DEBUG
                    retirementOverride = test_providerSwitchRetirement
                #else
                    retirementOverride = nil
                #endif
                guard let retire = handoff.detachProviderForSwitch(
                    claim: claim, mutationID: mutation.id, retirementOverride: retirementOverride
                ) else { return false }
                objectWillChange.send()
                _ = await providerSwitchAwaitDeadline(.retirementTail) { await retire()
                    return true
                }
                guard transactionCurrent(), !forcing || providerSwitchSourceIsSettled(session) else {
                    surfaceReviewFailure()
                    return false
                }
                if forcing, session.sourceItemsRevision != stagedRevision {
                    // Retirement is not expected to write transcript rows, so drift came from
                    // the detached stop/provider tail: rebuild once against the now-final
                    // transcript and refuse like the late path on any residual staleness.
                    guard let refreshed = await providerSwitchForcedHandoverPayload(preview, session: session),
                          session.sourceItemsRevision == refreshed.revision,
                          providerSwitchSourceIsSettled(session), transactionCurrent()
                    else {
                        surfaceReviewFailure()
                        return false
                    }
                    payload = refreshed.payload
                    cutoff = refreshed.cutoff
                }
                guard let payload, let source = preview.source else { return false }
                let parameters: AgentSessionHandoffRuntime.ProviderSwitchDestination.ParameterChange?
                if let intent = preview.cursorParameterIntent,
                   let selections = intent.applying(to: preview.sourceParameters, model: preview.model)
                {
                    let writes: [ACPModelParameterSelection] = switch intent {
                    case let .select(selection): [selection]
                    case let .clear(identity): preview.sourceParameters.filter { $0.identity == identity }
                    }
                    parameters = .init(writes: writes, selections: selections)
                } else {
                    parameters = nil
                }
                change = .replace(.init(
                    agent: preview.destination, model: preview.model,
                    payload: payload, cutoff: cutoff, parameters: parameters
                ))
                let destination = inputBarModelDisplayName(rawModel: preview.model, agentKind: preview.destination)
                message = "Provider changed from \(source.provider) / \(source.model) to \(preview.destination.displayName) / \(destination); handover: \(preview.chosen?.label ?? "Full history")."
            } else {
                change = .discard
                message = "Pending handover discarded; chat history unchanged."
            }
            let beforeSave: (@MainActor (TabSession) -> Void)?
            #if DEBUG
                beforeSave = test_providerSwitchBeforeSave
            #else
                beforeSave = nil
            #endif
            let result = await handoff.commitProviderSwitch(
                change, claim: claim, mutationID: mutation.id,
                rollback: rollback, message: message, reportFailureInTranscript: !requiresPresentedPreview, beforeSave: beforeSave
            )
            switch result {
            case .applied:
                if providerSwitchPreview?.matches(session) == true, providerSwitchPreview?.binding == preview.binding { providerSwitchPreview = nil }
                return true
            case .refused:
                return false
            case let .failed(message):
                presentFailure(message)
                return false
            }
        }
    }
}
