import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptRemoteProtocol

// MARK: - Typed remote service boundary

/// A sanitized, immutable workspace record used by remote projections. The
/// adapter deliberately exposes only a repository-root summary, never a raw
/// filesystem path.
struct RemoteWorkspaceRecord: Equatable {
    let workspaceID: UUID
    let name: String
    let repositoryRootSummary: String?
    let isOpen: Bool
    let activeSessionIDs: [UUID]
    let lastActivityAt: Date?
}

struct RemoteSessionRecord: Equatable {
    let sessionID: UUID
    let workspaceID: UUID
    let composeTabID: UUID?
    let parentSessionID: UUID?
    let sessionName: String?
    let workflow: String?
    let workflowID: String?
    let runStartedAt: Date?
    let transcriptRevision: UInt64?
    let agent: String?
    let model: String?
    let reasoningEffort: String?
    let configurationControls: RemoteSessionConfigurationControls?
    let runState: RemoteRunState
    let lifecycleStage: String?
    let latestMeaningfulActivity: String?
    let pendingInteraction: RemoteInteractionSummary?
    let worktreeSummary: String?
    let mergeAttention: String?
    let failureSummary: String?
    let lastUpdatedAt: Date
    let isLive: Bool

    init(
        sessionID: UUID,
        workspaceID: UUID,
        composeTabID: UUID?,
        parentSessionID: UUID?,
        sessionName: String?,
        workflow: String?,
        agent: String?,
        model: String?,
        reasoningEffort: String?,
        runState: RemoteRunState,
        lifecycleStage: String?,
        latestMeaningfulActivity: String?,
        pendingInteraction: RemoteInteractionSummary?,
        worktreeSummary: String?,
        mergeAttention: String?,
        failureSummary: String?,
        lastUpdatedAt: Date,
        isLive: Bool,
        workflowID: String? = nil,
        runStartedAt: Date? = nil,
        transcriptRevision: UInt64? = nil,
        configurationControls: RemoteSessionConfigurationControls? = nil
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.composeTabID = composeTabID
        self.parentSessionID = parentSessionID
        self.sessionName = sessionName
        self.workflow = workflow
        self.workflowID = workflowID
        self.runStartedAt = runStartedAt
        self.transcriptRevision = transcriptRevision
        self.agent = agent
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.configurationControls = configurationControls
        self.runState = runState
        self.lifecycleStage = lifecycleStage
        self.latestMeaningfulActivity = latestMeaningfulActivity
        self.pendingInteraction = pendingInteraction
        self.worktreeSummary = worktreeSummary
        self.mergeAttention = mergeAttention
        self.failureSummary = failureSummary
        self.lastUpdatedAt = lastUpdatedAt
        self.isLive = isLive
    }
}

struct RemoteCatalogRecord: Equatable {
    let workflows: [RemoteWorkflowDescriptor]
    let agents: [RemoteAgentDescriptor]
    let metadata: RemoteCatalogMetadata?

    init(
        workflows: [RemoteWorkflowDescriptor],
        agents: [RemoteAgentDescriptor],
        metadata: RemoteCatalogMetadata? = nil
    ) {
        self.workflows = workflows
        self.agents = agents
        self.metadata = metadata
    }

    static let empty = Self(workflows: [], agents: [])
}

@MainActor
protocol WorkspaceCatalogService: AnyObject {
    func allSavedWorkspaces() async -> [RemoteWorkspaceRecord]
}

@MainActor
protocol WorkspaceActivationService: AnyObject {
    func activate(workspaceID: UUID) async -> Result<RemoteWorkspaceActivationResult, RemoteWorkspaceActivationError>
}

struct RemoteWorkspaceActivationResult: Equatable {
    let workspaceID: UUID
    let composeTabID: UUID?
    let windowID: Int?
    let reusedExistingWindow: Bool
}

enum RemoteWorkspaceActivationError: Error, Equatable {
    case invalidWorkspaceID
    case workspaceNotFound
    case activationBlocked(String)
}

@MainActor
protocol SessionQueryService: AnyObject {
    func remoteSessions() async -> [RemoteSessionRecord]
}

@MainActor
protocol WorkflowCatalogService: AnyObject {
    func remoteCatalog() async -> RemoteCatalogRecord
}

@MainActor
protocol RemoteStateProjectionService: AnyObject {
    func snapshot() async -> RemoteSnapshot
}

/// The only production-facing composition point needed by the gateway. It
/// projects authoritative desktop services into the shared wire DTOs and keeps
/// all path/window/provider implementation details out of the protocol layer.
@MainActor
final class RemoteSnapshotBuilder {
    private let workspaceCatalog: any WorkspaceCatalogService
    private let sessionQuery: any SessionQueryService
    private let workflowCatalog: any WorkflowCatalogService

    init(
        workspaceCatalog: any WorkspaceCatalogService,
        sessionQuery: any SessionQueryService,
        workflowCatalog: any WorkflowCatalogService
    ) {
        self.workspaceCatalog = workspaceCatalog
        self.sessionQuery = sessionQuery
        self.workflowCatalog = workflowCatalog
    }

    func build(
        desktop: RemoteDesktopSummary,
        connection: RemoteConnectionSummary,
        authorization: RemoteAuthorizationState,
        eventCursor: UInt64 = 0,
        transcriptRevisionEpoch: UUID? = nil
    ) async -> RemoteSnapshot {
        let workspaces = await workspaceCatalog.allSavedWorkspaces()
            .map {
                RemoteWorkspaceSummary(
                    workspaceID: $0.workspaceID.uuidString,
                    name: $0.name,
                    repositoryRootSummary: $0.repositoryRootSummary,
                    isOpen: $0.isOpen,
                    activeSessionIDs: $0.activeSessionIDs,
                    lastActivityAt: $0.lastActivityAt
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let records = await sessionQuery.remoteSessions()
        let childIDsByParent = records.reduce(into: [UUID: [UUID]]()) { result, record in
            guard let parent = record.parentSessionID else { return }
            result[parent, default: []].append(record.sessionID)
        }
        let sessions = records.map {
            RemoteSessionSummary(
                sessionID: $0.sessionID,
                workspaceID: $0.workspaceID.uuidString,
                composeTabID: $0.composeTabID,
                parentSessionID: $0.parentSessionID,
                sessionName: $0.sessionName,
                workflow: $0.workflow,
                workflowID: $0.workflowID,
                runStartedAt: $0.runStartedAt,
                transcriptRevision: $0.transcriptRevision,
                agent: $0.agent,
                model: $0.model,
                reasoningEffort: $0.reasoningEffort,
                configurationControls: $0.configurationControls,
                runState: $0.runState,
                lifecycleStage: $0.lifecycleStage,
                latestMeaningfulActivity: $0.latestMeaningfulActivity,
                pendingInteraction: $0.pendingInteraction,
                childSessionIDs: childIDsByParent[$0.sessionID, default: []].sorted { $0.uuidString < $1.uuidString },
                worktreeSummary: $0.worktreeSummary,
                mergeAttention: $0.mergeAttention,
                failureSummary: $0.failureSummary,
                lastUpdatedAt: $0.lastUpdatedAt,
                isLive: $0.isLive
            )
        }
        .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }

        let attentionItems = sessions.compactMap { session -> RemoteAttentionItem? in
            guard let interaction = session.pendingInteraction else {
                switch session.runState {
                case .failed:
                    return RemoteAttentionItem(id: session.sessionID, kind: .failed, sessionID: session.sessionID, title: "Agent failed", sanitizedPreview: session.failureSummary)
                case .completed:
                    return RemoteAttentionItem(id: session.sessionID, kind: .completed, sessionID: session.sessionID, title: "Agent completed")
                default:
                    return nil
                }
            }
            let kind: RemoteAttentionKind = interaction.kind == .approval ? .approvalRequired : .agentNeedsInput
            return RemoteAttentionItem(
                id: UUID(uuidString: interaction.id) ?? session.sessionID,
                kind: kind,
                sessionID: session.sessionID,
                title: interaction.title ?? (kind == .approvalRequired ? "Approval required" : "Agent needs you"),
                sanitizedPreview: interaction.prompt
            )
        }

        let catalog = await workflowCatalog.remoteCatalog()
        return RemoteSnapshot(
            desktop: desktop,
            connection: connection,
            authorization: authorization,
            workspaces: workspaces,
            sessions: sessions,
            attentionItems: attentionItems,
            workflowCatalog: catalog.workflows,
            agentCatalog: catalog.agents,
            agentCatalogMetadata: catalog.metadata,
            eventCursor: eventCursor,
            transcriptRevisionEpoch: transcriptRevisionEpoch
        )
    }
}

// MARK: - Existing desktop state adapters

@MainActor
final class WorkspaceManagerRemoteCatalogService: WorkspaceCatalogService {
    private let managers: [WorkspaceManagerViewModel]

    init(manager: WorkspaceManagerViewModel) {
        managers = [manager]
    }

    init(managers: [WorkspaceManagerViewModel]) {
        self.managers = managers
    }

    func allSavedWorkspaces() async -> [RemoteWorkspaceRecord] {
        var records: [UUID: RemoteWorkspaceRecord] = [:]
        for manager in managers {
            for workspace in manager.workspaces where !workspace.isEphemeral {
                let current = RemoteWorkspaceRecord(
                    workspaceID: workspace.id,
                    name: workspace.name,
                    repositoryRootSummary: workspace.repoPaths.first
                        .map { URL(fileURLWithPath: $0).lastPathComponent },
                    isOpen: WindowStatesManager.shared.countWindowsShowing(workspaceId: workspace.id) > 0,
                    activeSessionIDs: workspace.composeTabs.compactMap(\.activeAgentSessionID),
                    lastActivityAt: workspace.lastUsed
                )
                if let existing = records[workspace.id] {
                    records[workspace.id] = RemoteWorkspaceRecord(
                        workspaceID: existing.workspaceID,
                        name: existing.name,
                        repositoryRootSummary: existing.repositoryRootSummary ?? current.repositoryRootSummary,
                        isOpen: existing.isOpen || current.isOpen,
                        activeSessionIDs: Array(Set(existing.activeSessionIDs + current.activeSessionIDs))
                            .sorted { $0.uuidString < $1.uuidString },
                        lastActivityAt: max(existing.lastActivityAt ?? .distantPast, current.lastActivityAt ?? .distantPast)
                    )
                } else {
                    records[workspace.id] = current
                }
            }
        }
        return Array(records.values)
    }
}

@MainActor
final class WorkspaceManagerRemoteActivationService: WorkspaceActivationService {
    private weak var manager: WorkspaceManagerViewModel?

    init(manager: WorkspaceManagerViewModel) {
        self.manager = manager
    }

    func activate(workspaceID: UUID) async -> Result<RemoteWorkspaceActivationResult, RemoteWorkspaceActivationError> {
        guard let manager else { return .failure(.workspaceNotFound) }
        guard let workspace = manager.workspace(withID: workspaceID) else {
            return .failure(.workspaceNotFound)
        }

        let existingWindow = WindowStatesManager.shared.findWindowState(showing: workspaceID)
        let result = await manager.switchWorkspace(to: workspace, saveState: true, reason: "remote")
        guard result.didSwitch || manager.activeWorkspaceID == workspaceID else {
            return .failure(.activationBlocked(result.message ?? "Workspace activation was blocked."))
        }

        return .success(
            RemoteWorkspaceActivationResult(
                workspaceID: workspaceID,
                composeTabID: workspace.activeComposeTabID ?? workspace.composeTabs.first?.id,
                windowID: existingWindow?.windowID,
                reusedExistingWindow: existingWindow != nil
            )
        )
    }
}

@MainActor
final class AgentModeRemoteSessionQueryService: SessionQueryService {
    private let contexts: [(agentMode: AgentModeViewModel, workspaceManager: WorkspaceManagerViewModel)]
    private let revisionTracker: RemoteTranscriptRevisionTracker?

    init(
        agentMode: AgentModeViewModel,
        workspaceManager: WorkspaceManagerViewModel,
        revisionTracker: RemoteTranscriptRevisionTracker? = nil
    ) {
        contexts = [(agentMode, workspaceManager)]
        self.revisionTracker = revisionTracker
    }

    init(
        contexts: [(agentMode: AgentModeViewModel, workspaceManager: WorkspaceManagerViewModel)],
        revisionTracker: RemoteTranscriptRevisionTracker? = nil
    ) {
        self.contexts = contexts
        self.revisionTracker = revisionTracker
    }

    func remoteSessions() async -> [RemoteSessionRecord] {
        var records: [UUID: RemoteSessionRecord] = [:]
        for context in contexts {
            let workspaceID = context.agentMode.sessionIndexOwner?.workspaceID
                ?? context.workspaceManager.activeWorkspaceID
            guard let workspaceID else { continue }
            let liveByTabID = context.agentMode.sessions
            let discoveryAgents = context.agentMode.remoteDiscoveryAgents()
            for entry in context.agentMode.sessionIndex.values {
                let live = Self.matchingLiveSession(
                    entryID: entry.id,
                    tabID: entry.tabID,
                    liveByTabID: liveByTabID
                )
                let runState = live.map { Self.mapRunState($0.runState) }
                    ?? Self.mapPersistedRunState(entry.lastRunStateRaw)
                let transcriptRevision: UInt64? = if let live {
                    revisionTracker?.observeLive(
                        sessionID: entry.id,
                        transcript: live.transcript,
                        mutationRevision: live.remoteTranscriptMutationRevision,
                        ownerID: ObjectIdentifier(live)
                    )
                } else if let cached = revisionTracker?.cachedPersistedRevision(sessionID: entry.id, savedAt: entry.savedAt) {
                    cached
                } else if revisionTracker?.revision(for: entry.id) != nil,
                          let workspace = context.workspaceManager.workspace(withID: workspaceID),
                          let persisted = try? await AgentSessionDataService.shared.loadAgentSession(id: entry.id, for: workspace)
                {
                    // Only refresh saved transcripts that Remote has already seen.
                    revisionTracker?.observePersisted(
                        sessionID: entry.id, savedAt: entry.savedAt,
                        fingerprint: .persisted(transcript: persisted.transcript ?? .empty)
                    )
                } else {
                    nil
                }
                let selectionCapabilities: AgentSessionSelectionCapabilities? = if let live {
                    context.agentMode.mcpSessionSelectionCapabilities(
                        tabID: live.tabID,
                        sessionID: entry.id,
                        discoveryAgents: discoveryAgents
                    )
                } else {
                    context.agentMode.mcpPersistedSessionSelectionCapabilities(
                        agentRaw: entry.agentKindRaw,
                        modelRaw: entry.agentModelRaw,
                        reasoningEffortRaw: entry.agentReasoningEffortRaw,
                        isMutable: Self.isConfigurationMutable(runState: runState),
                        discoveryAgents: discoveryAgents
                    )
                }
                let activity: String? = switch runState {
                case .opening, .working: live?.runningStatusText
                case .waitingForInput: live?.waitingPrompt
                default: nil
                }
                let record = RemoteSessionRecord(
                    sessionID: entry.id,
                    workspaceID: workspaceID,
                    composeTabID: entry.tabID,
                    parentSessionID: entry.parentSessionID,
                    sessionName: entry.name,
                    workflow: live?.originWorkflowDisplayName ?? entry.originWorkflowDisplayName,
                    agent: live?.selectedAgent.rawValue ?? entry.agentKindRaw,
                    model: selectionCapabilities?.resolvedModelRaw ?? entry.agentModelRaw,
                    reasoningEffort: selectionCapabilities?.resolvedReasoningEffortRaw ?? entry.agentReasoningEffortRaw,
                    runState: runState,
                    lifecycleStage: live?.runState.rawValue,
                    latestMeaningfulActivity: activity,
                    pendingInteraction: Self.pendingInteraction(for: live, agentMode: context.agentMode),
                    worktreeSummary: entry.worktreeBindingSummaries.isEmpty ? nil : "Worktree configured",
                    mergeAttention: entry.activeWorktreeMergeSummaries.isEmpty ? nil : "Merge review available",
                    failureSummary: runState == .failed ? "Agent run failed" : nil,
                    lastUpdatedAt: max(entry.savedAt, live?.activeAgentRunStartedAt ?? .distantPast),
                    isLive: live != nil,
                    workflowID: live?.originWorkflowID ?? entry.originWorkflowID,
                    runStartedAt: live?.lastRunStartedAt ?? entry.lastRunStartedAt,
                    transcriptRevision: transcriptRevision,
                    configurationControls: selectionCapabilities.map(Self.remoteConfigurationControls)
                )
                if let existing = records[record.sessionID], existing.lastUpdatedAt >= record.lastUpdatedAt {
                    continue
                }
                records[record.sessionID] = record
            }
        }
        return Array(records.values)
    }

    static func matchingLiveSession(
        entryID: UUID,
        tabID: UUID,
        liveByTabID: [UUID: AgentModeViewModel.TabSession]
    ) -> AgentModeViewModel.TabSession? {
        guard let live = liveByTabID[tabID], live.activeAgentSessionID == entryID else {
            return nil
        }
        return live
    }

    private static func mapRunState(_ state: AgentSessionRunState) -> RemoteRunState {
        switch state {
        case .idle: .idle
        case .running: .working
        case .waitingForUser, .waitingForQuestion, .waitingForApproval: .waitingForInput
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }

    static func isConfigurationMutable(runState: RemoteRunState) -> Bool {
        switch runState {
        case .opening, .working, .waitingForInput:
            false
        case .idle, .blocked, .completed, .failed, .cancelled:
            true
        }
    }

    static func mapPersistedRunState(_ rawValue: String?) -> RemoteRunState {
        mapRunState(rawValue.flatMap(AgentSessionRunState.init(rawValue:)) ?? .idle)
    }

    static func remoteConfigurationControls(
        _ capabilities: AgentSessionSelectionCapabilities
    ) -> RemoteSessionConfigurationControls {
        RemoteSessionConfigurationControls(
            agent: RemoteSelectionControl(
                isMutable: capabilities.isMutable && capabilities.allowedAgentRawValues.count > 1,
                allowedValueIDs: capabilities.allowedAgentRawValues,
                unavailableReason: capabilities.agentUnavailableReason
            ),
            model: RemoteSelectionControl(
                isMutable: capabilities.isMutable && !capabilities.allowedModelRawValues.isEmpty,
                allowedValueIDs: capabilities.allowedModelRawValues,
                unavailableReason: capabilities.selectionUnavailableReason
            ),
            reasoningEffort: RemoteSelectionControl(
                isMutable: capabilities.isMutable && !capabilities.allowedReasoningEffortRawValues.isEmpty,
                allowedValueIDs: capabilities.allowedReasoningEffortRawValues,
                unavailableReason: capabilities.selectionUnavailableReason
            )
        )
    }

    private static func pendingInteraction(
        for session: AgentModeViewModel.TabSession?,
        agentMode: AgentModeViewModel
    ) -> RemoteInteractionSummary? {
        guard let session else { return nil }
        return projectInteraction(
            agentMode.mcpRuntime.mcpPendingInteraction(for: session),
            createdAt: session.lastActivityAt,
            supportsPlainApproval: session.pendingApproval?.supportsPlainApprove ?? true
        )
    }

    static func projectInteraction(
        _ interaction: AgentRunMCPSnapshot.Interaction?,
        createdAt: Date,
        supportsPlainApproval: Bool = true
    ) -> RemoteInteractionSummary? {
        guard let interaction, interaction.kind != .instruction else { return nil }
        let isApproval = interaction.kind == .approval || interaction.kind == .hookApproval
        let isSecret = interaction.fields.contains { $0.isSecret == true }
        let unavailableReason: String? = if interaction.kind == .hookApproval {
            "Review hook trust and discovery on your Mac."
        } else if interaction.kind == .mcpElicitation {
            "Review the MCP request on your Mac."
        } else if isApproval, !supportsPlainApproval {
            "This request needs a specific approval option. Review it on your Mac."
        } else if interaction.fields.count > 1 {
            "Answer this multi-part request on your Mac."
        } else {
            nil
        }
        let details = interaction.details.map { "\($0.label): \($0.value)" }
        let prompt = ([interaction.prompt ?? interaction.fields.first?.prompt].compactMap(\.self) + details)
            .joined(separator: "\n\n")
        return RemoteInteractionSummary(
            id: interaction.id.uuidString,
            kind: isApproval ? .approval : (isSecret ? .secretInput : .question),
            title: interaction.title,
            prompt: prompt.isEmpty ? nil : prompt,
            requiresSecureEntry: isSecret,
            responseUnavailableReason: unavailableReason,
            createdAt: createdAt
        )
    }
}

@MainActor
final class StaticRemoteCatalogService: WorkflowCatalogService {
    var catalog: RemoteCatalogRecord

    init(catalog: RemoteCatalogRecord = .empty) {
        self.catalog = catalog
    }

    func remoteCatalog() async -> RemoteCatalogRecord {
        catalog
    }
}

/// Projects the desktop's live workflow and provider stores into the compact
/// catalog used by mobile. The catalog contains identifiers and display
/// metadata only; templates, credentials, and provider configuration remain
/// on the Mac.
@MainActor
final class DesktopRemoteCatalogService: WorkflowCatalogService {
    private let agentModes: [AgentModeViewModel]

    init(agentModes: [AgentModeViewModel] = []) {
        self.agentModes = agentModes
    }

    static func workflowDescriptors(
        workflows: [AgentWorkflowDefinition],
        featuredWorkflowIDs: [String]
    ) -> [RemoteWorkflowDescriptor] {
        let featuredRankByID = featuredWorkflowIDs.enumerated().reduce(into: [String: Int]()) { ranks, entry in
            if ranks[entry.element] == nil {
                ranks[entry.element] = entry.offset
            }
        }
        return workflows.map {
            RemoteWorkflowDescriptor(
                id: $0.id,
                displayName: $0.displayName,
                isBuiltIn: $0.isBuiltIn,
                requiredAuthority: .control,
                iconName: $0.iconName,
                accentColorHex: $0.accentColorHex,
                descriptionText: $0.descriptionText,
                featuredRank: featuredRankByID[$0.id]
            )
        }
    }

    func remoteCatalog() async -> RemoteCatalogRecord {
        let store = AgentWorkflowStore.shared
        let workflows = Self.workflowDescriptors(
            workflows: store.allWorkflows,
            featuredWorkflowIDs: store.featuredWorkflowIDs
        )

        guard let source = agentModes.first else {
            return RemoteCatalogRecord(workflows: workflows, agents: [])
        }
        let persistedDefault = source.remoteDefaultSelection()
        let preferredDefault = RemoteAgentSelection(
            agentID: persistedDefault.agentRaw,
            modelID: persistedDefault.modelRaw,
            reasoningEffort: persistedDefault.reasoningEffortRaw
        )
        let agents = source.availableAgents.compactMap { agent -> RemoteAgentDescriptor? in
            guard let discovery = source.remoteSelectableDiscoveryAgent(for: agent) else { return nil }
            let models = discovery.models.map { model in
                RemoteModelDescriptor(
                    id: model.id,
                    displayName: model.name,
                    isAvailable: model.available,
                    reasoningEfforts: model.remoteReasoningEfforts(for: agent),
                    defaultReasoningEffortID: model.remoteDefaultReasoningEffort(for: agent)
                )
            }
            guard !models.isEmpty else { return nil }
            let defaultModelID = discovery.models.first { model in
                model.id.caseInsensitiveCompare(discovery.defaults.modelRaw ?? "") == .orderedSame
                    || model.startTargets.contains(where: \.isDefault)
            }?.id ?? models.first(where: \.isAvailable)?.id
            return RemoteAgentDescriptor(
                id: agent.rawValue,
                displayName: agent.displayName,
                models: models.map(\.id),
                isAvailable: true,
                modelDescriptors: models,
                defaultModelID: defaultModelID
            )
        }
        let resolvedDefault = Self.resolvedDefaultSelection(
            preferredDefault,
            agents: agents
        )
        let toolState = source.remoteCodexToolBinding()
        let toolsAreMutable = agentModes.allSatisfy { $0.remoteCodexToolBinding().isMutable }
        let toolCatalog = Self.toolCatalog(
            binding: toolState.binding,
            isMutable: toolsAreMutable
        )
        let metadata = RemoteCatalogMetadata(
            defaultAgentID: resolvedDefault?.agentID,
            defaultSelection: resolvedDefault,
            toolCatalog: toolCatalog,
            supportsStartSelection: true,
            supportsSessionConfiguration: true,
            supportsAttachments: true,
            supportsImageAttachments: true
        )

        return RemoteCatalogRecord(workflows: workflows, agents: agents, metadata: metadata)
    }

    static func resolvedDefaultSelection(
        _ preferred: RemoteAgentSelection,
        agents: [RemoteAgentDescriptor]
    ) -> RemoteAgentSelection? {
        guard let agent = agents.first(where: {
            $0.id.caseInsensitiveCompare(preferred.agentID) == .orderedSame && $0.isAvailable
        }) ?? agents.first(where: \.isAvailable) else { return nil }
        let modelIDs = agent.modelDescriptors?.map(\.id) ?? agent.models
        let isPreferredAgent = agent.id.caseInsensitiveCompare(preferred.agentID) == .orderedSame
        let requestedModel = isPreferredAgent ? modelIDs.first {
            $0.caseInsensitiveCompare(preferred.modelID) == .orderedSame
        } : nil
        let resolvedModelID = requestedModel ?? agent.defaultModelID.flatMap { fallback in
            modelIDs.first(where: { $0.caseInsensitiveCompare(fallback) == .orderedSame })
        }
        guard let resolvedModelID else { return nil }
        let model = agent.modelDescriptors?.first { $0.id == resolvedModelID }
        let preferredEffort = requestedModel.flatMap { _ in
            model?.reasoningEfforts.first { $0.id == preferred.reasoningEffort }?.id
        }
        return RemoteAgentSelection(
            agentID: agent.id,
            modelID: resolvedModelID,
            reasoningEffort: preferredEffort ?? model?.defaultReasoningEffortID
        )
    }

    static func toolCatalog(
        binding: AgentProviderControlsBinding,
        isMutable: Bool
    ) -> RemoteToolCatalog? {
        binding.codexTools.map { tools in
            var settings = [
                RemoteToolSettingDescriptor(id: "bash", displayName: "Bash", category: "tools", isEnabled: tools.bashToolEnabled),
                RemoteToolSettingDescriptor(id: "search", displayName: "Search", category: "tools", isEnabled: tools.searchToolEnabled),
                RemoteToolSettingDescriptor(id: "goals", displayName: "Goals", category: "tools", isEnabled: tools.goalSupportEnabled),
                RemoteToolSettingDescriptor(id: "reasoning_summaries", displayName: "Reasoning Summaries", category: "tools", isEnabled: tools.reasoningSummariesEnabled)
            ]
            settings += tools.mcpServerEntries.map { entry in
                let required = entry.normalizedName.caseInsensitiveCompare(MCPIntegrationHelper.repoPromptMCPServerName) == .orderedSame
                let key = entry.normalizedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return RemoteToolSettingDescriptor(
                    id: "mcp:\(entry.normalizedName)",
                    displayName: entry.normalizedName,
                    category: "mcp_servers",
                    isEnabled: required || (tools.mcpServerStatesByNormalizedName[key] ?? false),
                    isMutable: isMutable && !required,
                    isRequired: required
                )
            }
            return RemoteToolCatalog(
                providerID: AgentProviderKind.codexExec.rawValue,
                revision: binding.revision,
                settings: settings,
                isMutable: isMutable,
                unavailableReason: isMutable ? nil : "Tool controls are locked during an active Codex run."
            )
        }
    }
}

@MainActor
final class AppRemoteStateProjectionService: RemoteStateProjectionService {
    private let builder: RemoteSnapshotBuilder
    private let desktop: RemoteDesktopSummary
    private let connection: RemoteConnectionSummary
    private let authorization: RemoteAuthorizationState

    init(
        builder: RemoteSnapshotBuilder,
        desktop: RemoteDesktopSummary,
        connection: RemoteConnectionSummary = .init(state: .connected),
        authorization: RemoteAuthorizationState = .init()
    ) {
        self.builder = builder
        self.desktop = desktop
        self.connection = connection
        self.authorization = authorization
    }

    func snapshot() async -> RemoteSnapshot {
        await builder.build(
            desktop: desktop,
            connection: connection,
            authorization: authorization
        )
    }
}

extension AgentModelCatalog.DiscoveryModel {
    func remoteReasoningEfforts(for agent: AgentProviderKind) -> [RemoteReasoningEffortDescriptor] {
        if agent == .codexExec {
            return supportedReasoningEfforts.map { .init(id: $0.rawValue, displayName: $0.displayName) }
        }
        if agent.usesClaudeNativeRuntime {
            return AgentModelCatalog.supportedClaudeEfforts(forSelectedModelRaw: id, agentKind: agent)
                .map { .init(id: $0.rawValue, displayName: $0.displayName) }
        }
        return []
    }

    func remoteDefaultReasoningEffort(for agent: AgentProviderKind) -> String? {
        guard agent == .codexExec else { return nil }
        let allowed = supportedReasoningEfforts
        if let defaultReasoningEffort, allowed.contains(defaultReasoningEffort) {
            return defaultReasoningEffort.rawValue
        }
        return (allowed.contains(.medium) ? .medium : allowed.first)?.rawValue
    }
}
