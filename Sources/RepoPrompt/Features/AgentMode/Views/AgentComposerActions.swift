import Foundation
import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptWorkspaceContext

@MainActor
extension AgentComposerActions {
    static func make(
        vm agentModeVM: AgentModeViewModel,
        subject: AgentComposerSubject,
        composerUI: AgentComposerUIStore,
        windowID: Int,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        openInWorkspace: @escaping () -> Void = {},
        reportFailure: @escaping (String) -> Void = { _ in }
    ) -> AgentComposerActions {
        let currentTabID: UUID? = if case let .tab(id) = subject { id } else { agentModeVM.currentTabID }
        let exactSession = currentTabID.flatMap { agentModeVM.sessions[$0] }
        let active = subject.isCurrent
        func configure(agent: String? = nil, model: String? = nil, effort: String? = nil, parameters: [ACPModelParameterSelection] = []) {
            guard isCurrent(), !composerUI.isConfiguring, let session = exactSession else { return }
            guard !session.runState.isActive else { reportFailure("Wait for this run to settle before changing its model settings.")
                return
            }
            let selections = AgentComposerProjection.merging(parameters, into: session.acpModelParameterSelections)
            let token = session.persistentBindingTransitionToken()
            composerUI.isConfiguring = true
            Task { @MainActor in
                defer { composerUI.isConfiguring = false }
                guard isCurrent() else { return }
                do { try await agentModeVM.mcpConfigureSession(
                    tabID: session.tabID,
                    agentRaw: agent,
                    modelRaw: model,
                    reasoningEffortRaw: effort,
                    modelParameterSelections: selections,
                    requireInactiveRunState: true,
                    expectedTarget: token
                ) } catch { if isCurrent() { reportFailure("Configuration refused: \(error.localizedDescription)") } }
            }
        }
        // Composer props carry the source session identity in submitTarget, so replacing
        // an idle session also invalidates the equatable view's retained actions.
        let cursorSession = active ? agentModeVM.activeSession : exactSession
        let attachmentAdmission: @MainActor (UUID) -> Bool = { [weak agentModeVM, weak composerUI] tabID in
            guard let agentModeVM, let composerUI, isCurrent() else { return false }
            return !composerUI.hasPendingSubmission(tabID: tabID)
                && agentModeVM.repromptUIStore.allowsAttachmentMutation(tabID: tabID, currentTabID: active ? agentModeVM.currentTabID : currentTabID)
        }
        return AgentComposerActions(
            prepareReprompt: { target, text in
                guard isCurrent() else { return false }
                if !active { return false }
                return agentModeVM.prepareRepromptForComposerSend(target: target, text: text)
            },
            toggleComputerUse: { tabID, identity in guard isCurrent() else { return }
                if !active, agentModeVM.currentTabID != tabID { openInWorkspace()
                    return
                }
                await agentModeVM.toggleComputerUse(tabID: tabID, expectedSessionIdentity: identity)
            },
            storeDraft: { tabID, text, sequence in
                guard isCurrent() else { return }
                agentModeVM.storeDraftText(for: tabID, text, acknowledgingThrough: sequence)
            },
            loadDraft: { tabID in guard isCurrent() else { return .init(text: "", restorationSequence: 0) }
                return agentModeVM.draftRuntime.loadSnapshot(tabID: tabID)
            },
            claimSubmit: { attempt in
                guard isCurrent() else { return .rejected(.missingSession) }
                return agentModeVM.claimComposerSubmitForImmediatePresentation(attempt, requireActiveTabOwnership: active, presentationStore: composerUI)
            },
            executeSubmit: { claim, text in
                defer { if composerUI !== agentModeVM.ui.composer { composerUI.pendingSubmissions[claim.attempt.id] = nil } }
                // A successful claim is already canonical authority. Always let its executor
                // settle/release it, even after UI navigation/close; do not leak an unentered claim.
                if active { return await agentModeVM.executePresentedComposerSubmitAttempt(text: text, claim: claim) }
                let result = await agentModeVM.executeComposerSubmitAttempt(text: text, claim: claim, createAndActivateSessionTab: { nil })
                agentModeVM.finishPresentedComposerSubmitAttempt(claim, result: result)
                guard isCurrent() else { return .blocked(message: "Delivery uncertain: the session owner changed. Open the session to confirm before resending.") }
                return result
            },
            cancelRun: { target in guard isCurrent() else { return }
                _ = await agentModeVM.cancelAgentRun(target: target)
            },
            cancelBackground: { target in guard isCurrent() else { return }
                _ = await agentModeVM.cancelOracleBackground(target: target)
            },
            cancelRouting: { tabID in guard isCurrent() else { return }
                await agentModeVM.cancelFreshTaskRouting(tabID: tabID)
            },
            attachFiles: { tabID, urls in
                guard attachmentAdmission(tabID) else { return }
                if let reason = agentModeVM.imageAttachmentBlockReason(tabID: tabID) {
                    agentModeVM.reportImageAttachmentBlocked(reason, tabID: tabID)
                    return
                }
                await agentModeVM.attachFiles(tabID: tabID, urls: urls, admission: {
                    attachmentAdmission(tabID) && agentModeVM.imageAttachmentBlockReason(tabID: tabID) == nil
                }).value
            },
            reportAttachmentFailures: { tabID, failures in
                guard attachmentAdmission(tabID) else { return }
                agentModeVM.reportAttachmentFailures(tabID: tabID, failures)
            },
            removePendingAttachment: { tabID, attachmentID in guard isCurrent() else { return }
                agentModeVM.removePendingFileAttachment(tabID: tabID, attachmentID: attachmentID)
            },
            commitTaggedFile: { tabID, suggestion, displayName in guard isCurrent() else { return }
                agentModeVM.commitPendingTaggedFile(
                    tabID: tabID,
                    relativePath: suggestion.relativePath,
                    displayName: displayName
                )
            },
            removeTaggedFile: { tabID, attachmentID in guard isCurrent() else { return }
                agentModeVM.removePendingTaggedFile(tabID: tabID, attachmentID: attachmentID)
            },
            agentWorkspaceLookupContext: { tabID in
                guard isCurrent() else { return .init(rootScope: .sessionBoundWorkspace(canonicalRootPaths: [], physicalRootPaths: []), bindingProjection: nil) }
                guard let tabID else { return .visibleWorkspace }
                return await agentModeVM.agentWorkspaceLookupContext(tabID: tabID)
            },
            slashSkillSuggestions: { query in guard isCurrent() else { return [] }
                return await agentModeVM.slashSkillSuggestions(for: query, tabID: active ? nil : currentTabID)
            },
            modelOptions: { agent, includeClaudeEffortVariants in
                agentModeVM.modelOptions(for: agent, includeClaudeEffortVariants: includeClaudeEffortVariants)
            },
            canSelectAgentInCurrentChat: { agent in active ? agentModeVM.canSelectAgentInCurrentChat(agent) : !agentModeVM.isProviderPickerLocked(tabID: currentTabID) || agent == exactSession?.selectedAgent },
            selectAgentModel: { agent, rawModel in
                guard isCurrent() else { return }
                if !active {
                    if agentModeVM.requestProviderSwitchSelection(agent: agent, model: rawModel, tabID: currentTabID) { return }
                    guard agent == exactSession?.selectedAgent else { openInWorkspace()
                        return
                    }
                    configure(model: rawModel)
                    return
                }
                if agentModeVM.requestProviderSwitchSelection(agent: agent, model: rawModel, tabID: currentTabID) { return }
                guard !composerUI.props.areModelControlsDisabled,
                      agentModeVM.canSelectAgentInCurrentChat(agent) else { return }
                AgentModelCatalog.updateLastUsedEffortIfEncoded(agentKind: agent, rawModel: rawModel)
                agentModeVM.selectedAgent = agent
                agentModeVM.selectModel(rawModel: rawModel)
            },
            reviewAgentModel: { agent, model, intent in
                guard isCurrent() else { return false }
                return agentModeVM.requestProviderSwitchSelection(agent: agent, model: model, tabID: currentTabID, cursorParameterIntent: intent)
            },
            reasoningEffortOptionsForCurrentSelection: {
                active ? agentModeVM.reasoningEffortOptionsForCurrentSelection() : agentModeVM.codexCoordinator.reasoningEffortOptions(forModelRaw: exactSession?.selectedModelRaw ?? "", agentKind: exactSession?.selectedAgent ?? .codexExec)
            },
            selectReasoningEffort: { effort in guard isCurrent() else { return }
                if active { agentModeVM.selectReasoningEffort(effort) } else { configure(effort: effort?.rawValue) }
            },
            selectACPModelParameter: { target, openCodeDiscoveryKey in
                if active { agentModeVM.selectACPModelParameter(target, openCodeDiscoveryKey: openCodeDiscoveryKey) } else if isCurrent() { configure(parameters: [target]) }
            },
            clearCursorModelParameter: { if active { agentModeVM.clearCursorModelParameter($0) } else { openInWorkspace() } },
            canMutateCursorModel: { tabID in
                isCurrent() && agentModeVM.canMutateCursorComposerModel(expectedSession: cursorSession, expectedTabID: tabID)
            },
            setAutoEditEnabled: { enabled in guard isCurrent() else { return }
                if active { agentModeVM.setAutoEditEnabled(enabled) } else if let session = exactSession { _ = agentModeVM.runtimeSessionStore.interactions(routeID: windowID, approvalStore: agentModeVM.applyEditsApprovalStore).setAutoEditEnabled(enabled, for: session) }
            },
            setProviderPermissionLevel: { id in guard isCurrent() else { return }
                agentModeVM.setProviderPermissionLevel(id)
            },
            applyCodexToolSettingMutation: { mutation in guard isCurrent() else { return }
                agentModeVM.applyCodexToolSettingMutation(mutation)
            },
            applyClaudeToolSettingMutation: { mutation in guard isCurrent() else { return }
                agentModeVM.applyClaudeToolSettingMutation(mutation)
            },
            setClaudeEffortLevel: { level in guard isCurrent() else { return }
                if active { agentModeVM.setClaudeEffortLevel(level) } else { configure(effort: level.rawValue) }
            },
            openCLIProvidersSettings: {
                NotificationCenter.default.post(
                    name: .showCLIProvidersTab,
                    object: nil,
                    userInfo: ["windowID": windowID]
                )
            }
        )
    }
}

@MainActor
extension AgentComposerActions {
    /// An unbound human draft has no claimable session yet. Only its explicit Submit callback may
    /// allocate a writer; editor/options/attachments otherwise remain local or provider-global.
    static func draft(
        props: AgentComposerProps, donor: AgentModeViewModel?, isCurrent: @escaping () -> Bool,
        store: @escaping (String) -> Void, load: @escaping () -> String,
        configure: @escaping (String?, String?, String?, [ACPModelParameterSelection]) -> Void,
        autoEdit: @escaping (Bool) -> Void, attach: @escaping ([URL]) -> Void, remove: @escaping (UUID) -> Void,
        notify: @escaping (String) -> Void, open: @escaping () -> Void,
        send: @escaping (String) async -> AgentModeViewModel.UserTurnSubmissionResult,
        sendTitle: String, presentationIdentity: AnyHashable? = nil
    ) -> AgentComposerActions {
        let bindings = AgentComposerProjection.providerBindings
        return AgentComposerActions(
            submitDraft: send, sendTitle: sendTitle, presentationIdentity: presentationIdentity,
            storeDraft: { _, text, _ in if isCurrent() { store(text) } },
            loadDraft: { _ in .init(text: load(), restorationSequence: 0) },
            claimSubmit: { _ in .rejected(.missingSession) },
            executeSubmit: { _, _ in .blocked(message: "Choose a project and use Open & Send to create this human session.") },
            cancelRun: { _ in notify("No session is running for this draft.") },
            cancelBackground: { _ in notify("No background work belongs to this unbound draft.") },
            cancelRouting: { _ in notify("No routing operation belongs to this draft.") },
            attachFiles: { _, urls in if isCurrent() { attach(urls) } },
            reportAttachmentFailures: { _, failures in notify(failures.map(\.reason).joined(separator: "\n")) },
            removePendingAttachment: { _, id in if isCurrent() { remove(id) } },
            commitTaggedFile: { _, _, _ in open() }, removeTaggedFile: { _, _ in open() },
            agentWorkspaceLookupContext: { _ in .visibleWorkspace },
            slashSkillSuggestions: { _ in [] }, // Never queried by the unbound draft's plain editor.
            modelOptions: { agent, variants in donor?.modelOptions(for: agent, includeClaudeEffortVariants: variants) ?? AgentModelCatalog.options(for: agent, includeClaudeEffortVariants: variants) },
            canSelectAgentInCurrentChat: { _ in true },
            selectAgentModel: { agent, raw in if isCurrent() { configure(agent.rawValue, raw, nil, []) } },
            reasoningEffortOptionsForCurrentSelection: {
                donor?.codexCoordinator.reasoningEffortOptions(forModelRaw: props.selectedModelRaw, agentKind: props.selectedAgent)
                    ?? AgentModelCatalog.options(for: props.selectedAgent).first(where: { $0.rawValue == props.selectedModelRaw })?.supportedReasoningEfforts ?? []
            },
            selectReasoningEffort: { effort in if isCurrent() { configure(nil, nil, effort?.rawValue, []) } },
            selectACPModelParameter: { parameter, _ in if isCurrent() { configure(nil, nil, nil, [parameter]) } },
            setAutoEditEnabled: { if isCurrent() { autoEdit($0) } },
            setProviderPermissionLevel: { id in if isCurrent() { if let donor { donor.setProviderPermissionLevel(id) } else { _ = bindings.setPermissionLevel(id) } } },
            applyCodexToolSettingMutation: { mutation in if isCurrent() { if let donor { donor.applyCodexToolSettingMutation(mutation) } else { bindings.applyCodexToolSettingMutation(mutation) } } },
            applyClaudeToolSettingMutation: { mutation in if isCurrent() { if let donor { donor.applyClaudeToolSettingMutation(mutation) } else { bindings.applyClaudeToolSettingMutation(mutation) } } },
            setClaudeEffortLevel: { if isCurrent() { configure(nil, nil, $0.rawValue, []) } },
            openCLIProvidersSettings: { NotificationCenter.default.post(name: .showCLIProvidersTab, object: nil) }
        )
    }
}
