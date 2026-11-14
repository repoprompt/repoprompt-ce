import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptSettingsCore

/// Presentation selection, not a writer or an activation request.
enum AgentComposerSubject: Equatable {
    case currentTab
    case tab(UUID)
    case draft(UUID)
    var isCurrent: Bool {
        self == .currentTab
    }

    /// CC's editor belongs to its explicit subject, not whichever tab its owner window shows.
    func ownsEditor(tabID: UUID, ownerCurrentTabID: UUID?) -> Bool {
        switch self {
        case .currentTab: tabID == ownerCurrentTabID
        case let .tab(id), let .draft(id): tabID == id
        }
    }

    var isDraft: Bool {
        if case .draft = self { true } else { false }
    }
}

struct AgentComposerDraftState {
    var id = UUID()
    var text = ""
    var agent: AgentProviderKind = .claudeCode
    var model = AgentModel.defaultModel.rawValue
    var effort: String?
    var parameters: [ACPModelParameterSelection] = []
    var attachments: [AgentFileAttachment] = []
    var autoEdit = ApplyEditsApprovalStore.globalDefaultAutoEditEnabled()
    var workflow: AgentWorkflowDefinition?
}

/// One projection for the workspace, exact inactive sessions and unbound human drafts. Catalog
/// donors supply global options only; they never become a draft's destination or runtime owner.
@MainActor
enum AgentComposerProjection {
    static let providerBindings = AgentModeProviderBindingService()

    static func merging(_ updates: [ACPModelParameterSelection], into held: [ACPModelParameterSelection]) -> [ACPModelParameterSelection] {
        var selections = held
        for update in updates {
            selections.removeAll { $0.identity == update.identity }
            selections.append(update)
        }
        return selections
    }

    static func props(
        vm: AgentModeViewModel?,
        subject: AgentComposerSubject,
        tabID explicitID: UUID? = nil,
        draft: AgentComposerDraftState? = nil,
        allowsWorkspaceScopedDiscovery: Bool = true
    ) -> AgentComposerProps {
        let current = subject.isCurrent
        let tabID: UUID? = switch subject {
        case .currentTab: explicitID ?? vm?.currentTabID
        case let .tab(id), let .draft(id): id
        }
        let session: AgentTabSession? = if case .draft = subject { nil } else { tabID.flatMap { vm?.sessions[$0] } }
        let agent = current ? (vm?.selectedAgent ?? .claudeCode) : (session?.selectedAgent ?? draft?.agent ?? .claudeCode)
        let model = current ? (vm?.selectedModelRaw ?? AgentModel.defaultModel.rawValue) : (session?.selectedModelRaw ?? draft?.model ?? AgentModel.defaultModel.rawValue)
        let effort = current ? vm?.selectedReasoningEffortRaw : (session != nil ? session?.selectedReasoningEffortRaw : draft?.effort)
        let state = current ? (vm?.runState ?? .idle) : (session?.runState ?? .idle)
        let controlled = session.map { $0.isMCPOriginated || $0.mcpControlContext != nil } ?? false
        let availability = vm?.agentAvailabilityContext ?? .current
        let available = AgentModelCatalog.isAgentAvailable(agent, availability: availability)
        let router = session.map { vm?.isGlobalModelRouterControllingFreshTask($0) == true } ?? false
        let settings = vm?.modelRouterSettingsStore ?? .shared
        let routerID = router ? settings.modelRouterConfiguration().selectedBackendID : nil
        let autoEffort = settings.autoEffortConfiguration()
        let controls = vm?.providerBindingService ?? providerBindings
        // OpenCode observations are keyed to a workspace. A catalog donor from another
        // project may supply global models, never that project's discovered parameters.
        let acp = agent == .openCode && !allowsWorkspaceScopedDiscovery ? [] : (vm?.acpModelParameterControls(session: session, agent: agent, model: model, parameterSelections: draft?.parameters) ?? [])
        return AgentComposerProps(
            computerUse: session.flatMap { vm?.computerUseComposerProps(session: $0) } ?? .hidden,
            imageAttachmentNotice: vm?.imageAttachmentNotice.flatMap { notice in current || notice.tabID == tabID ? notice : nil },
            currentTabID: tabID,
            submitTarget: current ? vm?.makeComposerSubmitTarget(tabID: tabID, session: session) : session.flatMap { vm?.makeComposerSubmitTarget(tabID: tabID, session: $0) },
            attachments: .init(
                scopeTabID: tabID,
                attachments: current ? (vm?.pendingFileAttachments ?? []) : (session?.pendingFileAttachments ?? draft?.attachments ?? []),
                taggedFileAttachments: current ? (vm?.pendingTaggedFileAttachments ?? []) : (session?.pendingTaggedFileAttachments ?? [])
            ),
            runState: state,
            cancelTarget: vm?.composerRunCancelTarget(tabID: tabID),
            backgroundCancelTarget: vm?.composerOracleBackgroundCancelTarget(tabID: tabID),
            isAgentBusy: current ? (vm?.isAgentBusy ?? false) : state.isActive,
            isWaitingForInstruction: current ? (vm?.isWaitingForInstruction ?? false) : state == .waitingForUser,
            canUseLinkedAgentSession: vm?.hasLinkedAgentSession(for: tabID) ?? false,
            isCurrentTabMCPControlled: current ? (vm?.isMCPControlled(tabID: tabID) ?? false) : controlled,
            areModelControlsDisabled: (current ? (vm?.isMCPControlled(tabID: tabID) ?? false) : controlled) || (session?.runState.isActive == true && (agent == .cursor || !acp.isEmpty)) || router || (!current && state.isActive),
            providerControls: current ? vm?.activeProviderControlsBinding : controls.controlsBinding(
                selectedAgent: agent, selectedModelRaw: model,
                claudeEffortLevel: session.flatMap { vm?.claudeCoordinator.currentClaudeEffortLevel(for: $0) } ?? ClaudeCodeEffortLevel.parse(draft?.effort),
                permissionProfile: session?.permissionProfile ?? .userConfigured, isSubagent: session?.parentSessionID != nil,
                externallyManagedReason: controlled ? "This session's permissions are managed." : nil
            ),
            isCodexRunActive: agent == .codexExec && (tabID.map { vm?.isTabRunning($0) == true } ?? false),
            hasAvailableAgentProviders: vm?.hasAvailableAgentProviders ?? true,
            canSendWithCurrentProvider: current ? (vm?.canSendWithCurrentProvider ?? false) : available && !(agent == .codexExec && CodexManagedSessionFence.shared.isFenced),
            isRoutingFreshTask: tabID.map { vm?.freshTaskRoutingByTabID[$0] != nil } ?? false,
            isGlobalModelRouterControllingFreshTask: router,
            automaticRouterServiceName: routerID.flatMap { vm?.modelRouterRuntime?.serviceDisplayNamesByID[$0] },
            autoEffortServiceName: autoEffort.enabled ? autoEffort.selectedBackendID.flatMap { vm?.modelRouterRuntime?.serviceDisplayNamesByID[$0] } ?? "Unavailable service" : nil,
            unavailableSelectedAgentMessage: current ? vm?.unavailableSelectedAgentMessage : (available ? nil : "Connect \(agent.displayName) in Settings before sending."),
            selectedAgent: agent, selectedModelRaw: model,
            selectedModelDisplayName: current ? (vm?.selectedModelDisplayName ?? model) : (vm?.inputBarModelDisplayName(rawModel: model, agentKind: agent) ?? model),
            selectedReasoningEffortRaw: effort,
            selectedReasoningEffortDisplayName: current ? (vm?.selectedReasoningEffortDisplayName ?? "") : (vm?.codexCoordinator.selectedReasoningEffortDisplayName(raw: effort) ?? effort ?? ""),
            acpModelParameterControls: acp,
            availableAgents: vm?.availableAgents ?? AgentProviderKind.allCases.filter { AgentModelCatalog.isAgentAvailable($0, availability: availability) },
            isProviderPickerLockedForCurrentTab: vm?.isProviderPickerLocked(tabID: tabID) ?? false,
            lockedAgentSelectionMessage: !current && state.isActive ? "Wait for this run to settle before changing model settings." : vm?.lockedAgentSelectionMessage(tabID: tabID),
            autoEditEnabled: current ? (vm?.autoEditEnabled ?? false) : (session?.autoEditEnabled ?? draft?.autoEdit ?? false),
            stagedSlashCommand: vm?.stagedSlashCommandProps(tabID: tabID),
            draftRestorationEvent: vm?.draftRestorationEvent.flatMap { event in
                current || event.tabID == tabID ? AgentDraftRestorationProps(event) : nil
            },
            fileTagLookupContextIdentity: vm?.agentWorkspaceLookupContextIdentity(tabID: tabID, session: session) ?? AgentWorkspaceLookupContextSource(activeAgentSessionID: nil, worktreeBindings: []).identity,
            // Exact-session editors also observe canonical text. A single window-wide
            // restoration event can be overwritten by another tab before CC's throttled refresh.
            draftText: draft?.text ?? (current ? nil : session?.draftText)
        )
    }
}
