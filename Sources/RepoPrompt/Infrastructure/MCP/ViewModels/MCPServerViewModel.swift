//
//  MCPServerViewModel.swift
//  RepoPrompt
//
//  Created by Repo Prompt – MCP integration
//

import AppKit
import Combine
import Foundation
import JSONSchema
import Logging
import MCP
import Ontology
import RepoPromptShared

// MARK: - Selection Debug Logging

#if DEBUG
    fileprivate var selectionDebugLoggingEnabled = false

    func setSelectionDebugLogging(enabled: Bool) {
        selectionDebugLoggingEnabled = enabled
    }

    func selectionLog(_ message: @autoclosure () -> String) {
        if selectionDebugLoggingEnabled {
            print("[Selection] \(message())")
        }
    }

    fileprivate var mcpServerViewModelDebugLoggingEnabled = false
    fileprivate func mcpServerViewModelDebugLog(_ message: @autoclosure () -> String) {
        guard mcpServerViewModelDebugLoggingEnabled else { return }
        print("[MCPServerVM] \(message())")
    }
#else
    func selectionLog(_ message: @autoclosure () -> String) {}
    fileprivate func mcpServerViewModelDebugLog(_ message: @autoclosure () -> String) {}
#endif

struct WindowMCPCloseSafetyState: Equatable {
    let toolsEnabled: Bool
    let liveConnectionCount: Int
    let activeExecutionCount: Int
    let hasIdleLiveConnections: Bool
    let activeToolName: String?

    static let inactive = WindowMCPCloseSafetyState(
        toolsEnabled: false,
        liveConnectionCount: 0,
        activeExecutionCount: 0,
        hasIdleLiveConnections: false,
        activeToolName: nil
    )
}

/// Manages the lifetime of the embedded MCP server and bridges
/// the app’s state (file tree, selections, code-map, prompts …)
/// to external Model-Context-Protocol clients.
///
/// This is **not** a simplified stub — all original features have
/// been preserved and adapted to the latest MCP SDK.
@MainActor // Runs on the main actor (UI thread)
final class MCPServerViewModel: ObservableObject {
    typealias WorkspaceSearchHandler = (
        _ pattern: String,
        _ mode: SearchMode,
        _ isRegex: Bool,
        _ caseInsensitive: Bool,
        _ maxPaths: Int,
        _ maxMatches: Int,
        _ paths: [String]?,
        _ includeExtensions: [String],
        _ excludePatterns: [String],
        _ contextLines: Int,
        _ wholeWord: Bool,
        _ countOnly: Bool,
        _ fuzzySpaceMatching: Bool,
        _ rootScope: WorkspaceLookupRootScope
    ) async throws -> SearchResults

    struct MCPSelectionSlicesMutationResult: Equatable {
        let invalidPaths: [String]
        let resolvedMap: [String: String]
        let snapshot: [UUID: [LineRange]]
    }

    enum MCPSelectionSliceError: LocalizedError {
        case workspaceUnavailable
        case noWorkspaceLoaded

        var errorDescription: String? {
            switch self {
            case .workspaceUnavailable: "No active workspace is available."
            case .noWorkspaceLoaded: "No workspace is currently loaded in this window."
            }
        }
    }

    private static let enableSteeringDebugLogging = false

    private func steeringDebugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard Self.enableSteeringDebugLogging else { return }
            print(message())
        #endif
    }

    // -----------------------------------------------------------------
    // MARK: Configuration constants

    // -----------------------------------------------------------------
    private nonisolated static let defaultCodeStructureMaxResults = 10
    private nonisolated static let codeStructureTokenBudget = 6000
    private nonisolated static let codeStructureSeparatorTokenCost = TokenCalculationService.estimateTokens(for: "\n\n")

    struct CodeStructureBudgetCandidate: Equatable {
        let key: String
        let estimatedTokens: Int
    }

    struct CodeStructureBudgetSelection: Equatable {
        let includedKeys: [String]
        let omittedByMaxResults: Int
        let omittedByTokenBudget: Int

        var omittedTotal: Int {
            omittedByMaxResults + omittedByTokenBudget
        }
    }

    // ---------------------------------------------------------------------
    // MARK: External dependencies (weak/unowned to avoid retain cycles)

    // ---------------------------------------------------------------------
    let promptVM: PromptViewModel
    private let oracleVM: OracleViewModel
    let workspaceManager: WorkspaceManagerViewModel?
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    var agentWorktreeBindingsProvider: (@MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding])?

    func registerAgentWorktreeBindingsProvider(_ provider: @escaping @MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding]) {
        agentWorktreeBindingsProvider = provider
    }

    private let workspaceSearch: WorkspaceSearchHandler
    private let ensureGitDataRootLoaded: (WorkspaceModel?, WorkspaceManagerViewModel?) async -> Void

    // ---------------------------------------------------------------------
    // MARK: Networking delegation

    // ---------------------------------------------------------------------
    let windowID: Int
    private(set) var service: MCPService
    private let logger = Logger(label: "com.repoprompt.mcp")

    private var oracleToolService: MCPOracleToolService {
        MCPOracleToolService(
            askOracleToolName: MCPWindowToolName.askOracle,
            oracleSendToolName: MCPWindowToolName.oracleSend,
            oracleChatLogToolName: MCPWindowToolName.oracleChatLog,
            promptVM: promptVM,
            oracleVM: oracleVM,
            captureRequestMetadata: { [self] in await captureRequestMetadata() },
            resolveTabContextSnapshot: { [self] metadata in
                try resolveTabContextSnapshot(
                    from: metadata,
                    toolName: MCPWindowToolName.oracleSend,
                    policy: .allowLegacyImplicitRouting
                )
            },
            requireCurrentTabContext: { [self] toolName in try await requireCurrentTabContext(toolName: toolName) },
            rebindChatSessionIfNeeded: { [self] metadata, chatIDString in
                try rebindOracleChatSessionIfNeeded(metadata: metadata, chatIDString: chatIDString)
            },
            resolveTabIDForAgentMode: { [self] args, connectionID in
                try await resolveTabIDForAgentMode(args: args, connectionID: connectionID)
            },
            requireTargetWindow: { [self] in try requireTargetWindow() },
            rawExplicitTabID: { [self] args in rawExplicitTabID(args: args) },
            sendStageProgress: { [self] connectionID, tool, stage, message in
                await sendStageProgress(connectionID: connectionID, tool: tool, stage: stage, message: message)
            },
            withHeartbeat: { [self] connectionID, tool, stage, message, operation in
                try await withHeartbeat(
                    connectionID: connectionID,
                    tool: tool,
                    stage: stage,
                    message: message,
                    operation: operation
                )
            },
            exportOracleResponse: { [self] request in
                try await exportOracleResponse(request)
            }
        )
    }

    private var agentRunToolService: AgentRunMCPToolService {
        AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: { [self] in await captureRequestMetadata() },
            requireTargetWindow: { [self] in try requireTargetWindow() },
            resolveRequestedTabID: { [self] args in
                try resolveRequestedTabIDForAgentControl(args: args)
            },
            resolveSpawnSourceTabID: { [self] metadata in
                await resolveSpawnSourceTabIDForAgentSessionCreation(metadata: metadata)
            },
            validateSpawnRouting: { [self] metadata, sourceTabID in
                try await validateAgentRunStartRouting(metadata: metadata, resolvedSourceTabID: sourceTabID)
            },
            resolveSpawnParentSessionID: { [self] metadata, targetWindow in
                await resolveSpawnParentSessionID(metadata: metadata, targetWindow: targetWindow)
            },
            resolveSpawnParentSessionIDFromSourceTabID: { sourceTabID, targetWindow in
                targetWindow.agentModeViewModel.mcpSpawnParentSessionID(sourceTabID: sourceTabID)
            },
            bindCurrentRequestToTab: { [self] tabID, metadata in
                try await bindCurrentRequestToTabIfPossible(tabID: tabID, metadata: metadata)
            },
            withHeartbeat: { [self] connectionID, tool, stage, message, operation in
                try await withHeartbeat(
                    connectionID: connectionID,
                    tool: tool,
                    stage: stage,
                    message: message,
                    operation: operation
                )
            },
            beginAgentRunWait: { [self] metadata, sessionIDs, timeoutSeconds in
                await beginAgentRunWaitScope(metadata: metadata, sessionIDs: sessionIDs, timeoutSeconds: timeoutSeconds)
            },
            endAgentRunWait: { [self] token, completion in
                endAgentRunWaitScope(token, completion: completion)
            },
            startRun: { target, message, metadata, bindCurrentRequestToTab, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, taskLabelKind, workflow in
                try await AgentExternalMCPRunStarter.start(
                    target: target,
                    message: message,
                    metadata: metadata,
                    bindCurrentRequestToTab: bindCurrentRequestToTab,
                    agentModeVM: agentModeVM,
                    agentRaw: agentRaw,
                    modelRaw: modelRaw,
                    reasoningEffortRaw: reasoningEffortRaw,
                    taskLabelKind: taskLabelKind,
                    workflow: workflow
                )
            }
        )
    }

    private var agentExploreToolService: AgentExploreMCPToolService {
        AgentExploreMCPToolService(
            toolName: MCPWindowToolName.agentExplore,
            captureRequestMetadata: { [self] in await captureRequestMetadata() },
            requireTargetWindow: { [self] in try requireTargetWindow() },
            resolveSpawnSourceTabID: { [self] metadata in
                await resolveSpawnSourceTabIDForAgentSessionCreation(metadata: metadata)
            },
            resolveSpawnParentSessionID: { [self] metadata, targetWindow in
                await resolveSpawnParentSessionID(metadata: metadata, targetWindow: targetWindow)
            },
            bindCurrentRequestToTab: { [self] tabID, metadata in
                try await bindCurrentRequestToTabIfPossible(tabID: tabID, metadata: metadata)
            },
            withHeartbeat: { [self] connectionID, tool, stage, message, operation in
                try await withHeartbeat(
                    connectionID: connectionID,
                    tool: tool,
                    stage: stage,
                    message: message,
                    operation: operation
                )
            },
            beginAgentRunWait: { [self] metadata, sessionIDs, timeoutSeconds in
                await beginAgentRunWaitScope(metadata: metadata, sessionIDs: sessionIDs, timeoutSeconds: timeoutSeconds)
            },
            endAgentRunWait: { [self] token, completion in
                endAgentRunWaitScope(token, completion: completion)
            },
            startRun: { target, message, metadata, bindCurrentRequestToTab, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, taskLabelKind, workflow in
                try await AgentExternalMCPRunStarter.start(
                    target: target,
                    message: message,
                    metadata: metadata,
                    bindCurrentRequestToTab: bindCurrentRequestToTab,
                    agentModeVM: agentModeVM,
                    agentRaw: agentRaw,
                    modelRaw: modelRaw,
                    reasoningEffortRaw: reasoningEffortRaw,
                    taskLabelKind: taskLabelKind,
                    workflow: workflow
                )
            }
        )
    }

    private var agentManageToolService: AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: { [self] in await captureRequestMetadata() },
            requireTargetWindow: { [self] in try requireTargetWindow() },
            resolveSpawnSourceTabID: { [self] metadata in
                await resolveSpawnSourceTabIDForAgentSessionCreation(metadata: metadata)
            },
            resolveSpawnParentSessionID: { [self] metadata, targetWindow in
                await resolveSpawnParentSessionID(metadata: metadata, targetWindow: targetWindow)
            },
            bindCurrentRequestToTab: { [self] tabID, metadata in
                try await bindCurrentRequestToTabIfPossible(tabID: tabID, metadata: metadata)
            }
        )
    }

    @Published private(set) var isRunning = false // overall status
    @Published private(set) var pendingClientID: String? // approval state
    @Published private(set) var diagnostics: MCPDiagnostics = .init(
        issue: .none,
        lastEventAt: nil,
        listenerStateDescription: "Idle"
    )
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastExternalClientEvent: MCPExternalClientEvent?
    @Published private(set) var externalClientErrorCount: Int = 0

    static func applyCodeStructureOutputBudget(
        _ candidates: [CodeStructureBudgetCandidate],
        maxResults: Int,
        tokenBudget: Int = codeStructureTokenBudget,
        separatorTokens: Int = codeStructureSeparatorTokenCost
    ) -> CodeStructureBudgetSelection {
        let effectiveMaxResults = max(0, maxResults)
        let effectiveTokenBudget = max(0, tokenBudget)
        let countCapped = Array(candidates.prefix(effectiveMaxResults))
        let omittedByMaxResults = max(0, candidates.count - countCapped.count)

        var includedKeys: [String] = []
        var usedTokens = 0

        for candidate in countCapped {
            let isFirstEntry = includedKeys.isEmpty
            let entryCost = isFirstEntry ? candidate.estimatedTokens : candidate.estimatedTokens + max(0, separatorTokens)
            if !isFirstEntry, usedTokens + entryCost > effectiveTokenBudget {
                break
            }
            includedKeys.append(candidate.key)
            usedTokens += entryCost
        }

        return CodeStructureBudgetSelection(
            includedKeys: includedKeys,
            omittedByMaxResults: omittedByMaxResults,
            omittedByTokenBudget: max(0, countCapped.count - includedKeys.count)
        )
    }

    // MARK: - Dashboard State

    /// Current dashboard snapshot (updated via event-driven notifications)
    @Published private(set) var dashboard: MCPService.DashboardSnapshot? {
        didSet {
            recomputeCloseSafetyState()
        }
    }

    @Published private(set) var closeSafetyState: WindowMCPCloseSafetyState = .inactive

    /// Task that listens for dashboard updates
    @MainActor
    private var dashboardTask: Task<Void, Never>?
    @MainActor
    private var dashboardTaskID: UUID?

    /// Subscription ID for dashboard updates (for cleanup)
    @MainActor
    private var dashboardSubscriptionID: UUID?

    enum DashboardConsumer: Hashable {
        case toolbarPopover
        case statusView
    }

    @MainActor
    private var dashboardConsumers: Set<DashboardConsumer> = []

    /// Returns the external client event only if it's recent (within 5 minutes)
    var recentExternalClientEvent: MCPExternalClientEvent? {
        guard let event = lastExternalClientEvent else { return nil }
        let ageInSeconds = Date().timeIntervalSince(event.timestamp)
        let maxAge: TimeInterval = 5 * 60 // 5 minutes
        return ageInSeconds < maxAge ? event : nil
    }

    /// Returns a smarter description that correlates the external error with server state
    var contextualErrorDescription: String? {
        guard let event = recentExternalClientEvent else { return nil }

        // Get the resolved client name - use event's name, or fall back to last connected client
        let clientName = resolvedClientName(for: event)

        // Check if there's a server-side issue that explains the client error
        switch (event.code, diagnostics.issue) {
        case (.localNetworkPolicyDenied, .localNetworkPermissionDenied):
            return "\(clientName) and RepoPrompt both need Local Network permission."
        case (.timeoutNoServices, _) where !isRunning:
            return "MCP server is not running. \(clientName) couldn't find any services."
        case (.connectionFailed, .listenerRestarting):
            return "\(clientName) tried to connect while the listener was restarting."
        case (.connectionFailed, .portInUse):
            return "\(clientName) couldn't connect - server port conflict detected."
        default:
            return resolvedUserFacingDescription(for: event)
        }
    }

    /// Resolves the client name for an event, using the last connected client as fallback
    private func resolvedClientName(for event: MCPExternalClientEvent) -> String {
        if let name = event.clientName, !name.isEmpty {
            return name
        }
        // Fall back to the last connected client's friendly name
        let monitor = MCPExternalEventsMonitor.shared
        return monitor.friendlyClientName(forProtocol: monitor.lastConnectedClientProtocolName)
    }

    /// Returns the user-facing description with resolved client name and full details
    private func resolvedUserFacingDescription(for event: MCPExternalClientEvent) -> String {
        let clientName = resolvedClientName(for: event)
        // Use the event's detailed description with our resolved client name
        return event.descriptionWithClientName(clientName)
    }

    /// Name of the tool that is currently executing (nil when idle)
    @Published private(set) var activeToolName: String? = nil {
        didSet {
            recomputeCloseSafetyState()
        }
    }

    /// Returns the active tool name for this window, based on dashboard ownership when available.
    @MainActor
    var windowActiveToolName: String? {
        if let dashboard {
            let allowNilWindow = !isMultiWindowModeEffectivelyActive
            for connection in dashboard.connections {
                if connection.windowID == windowID || (allowNilWindow && connection.windowID == nil) {
                    if let toolName = connection.activeToolName {
                        return toolName
                    }
                }
            }
        }
        return activeToolName
    }

    /// True when any tool is actively running for this window.
    @MainActor
    var windowHasActiveTool: Bool {
        windowActiveToolName != nil
    }

    /// Internal tracking token to prevent race conditions when overlapping tool calls occur
    @MainActor
    private var activeToolToken: UUID? = nil
    /// Connection that owns the legacy single active-tool slot.
    /// This keeps disconnect cleanup from cancelling a newer same-name tool owned by another connection.
    @MainActor
    private var activeToolConnectionID: UUID? = nil
    /// Whether this window's tools are enabled
    @Published var windowToolsEnabled: Bool = false {
        didSet {
            updateDashboardSubscriptionIfNeeded()
            recomputeCloseSafetyState()
            #if DEBUG || EDIT_FLOW_PERF
                Task {
                    let registrationUpdateWindowToolsEnabledDidSetState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.registrationUpdateWindowToolsEnabledDidSet)
                    defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.registrationUpdateWindowToolsEnabledDidSet, registrationUpdateWindowToolsEnabledDidSetState) }
                    await updateToolRegistration()
                }
            #else
                Task { await updateToolRegistration() }
            #endif
        }
    }

    /// Controls whether the approval overlay is visible
    @Published var isApprovalOverlayVisible: Bool = false

    @MainActor
    private lazy var windowToolRuntime = MCPWindowToolRuntime(windowID: windowID) { [weak self] name, flushFS, timeoutSeconds, args, implementation in
        guard let self else {
            throw MCPError.internalError("Window deallocated while executing \(name)")
        }
        return try await runTool(name, flushFS: flushFS, timeoutSeconds: timeoutSeconds) { [weak self] in
            guard let self else {
                throw MCPError.internalError("Window deallocated during \(name)")
            }
            return try await implementation(MCPWindowToolContext(toolName: name, windowID: windowID), args)
        }
    }

    @MainActor
    private lazy var windowToolDependencies = MCPWindowToolDependencies(
        executeOracleUtils: { [weak self] args in
            guard let self else { throw MCPError.internalError("Window deallocated while executing oracle_utils") }
            return try await oracleToolService.executeOracleUtils(args: args)
        },
        executeAskOracle: { [weak self] args in
            guard let self else { throw MCPError.internalError("Window deallocated while executing ask_oracle") }
            return try await oracleToolService.executeAskOracle(args: args)
        },
        executeOracleSend: { [weak self] args in
            guard let self else { throw MCPError.internalError("Window deallocated while executing oracle_send") }
            return try await oracleToolService.executeOracleSend(args: args)
        },
        executeOracleChatLog: { [weak self] args in
            guard let self else { throw MCPError.internalError("Window deallocated while executing oracle_chat_log") }
            return try await oracleToolService.executeOracleChatLog(args: args)
        },
        executeAgentExplore: { [weak self] args in
            guard let self else { throw MCPError.internalError("Window deallocated while executing agent_explore") }
            return try await agentExploreToolService.execute(args: args)
        },
        executeAgentRun: { [weak self] args in
            guard let self else { throw MCPError.internalError("Window deallocated while executing agent_run") }
            return try await agentRunToolService.execute(args: args)
        },
        executeAgentManage: { [weak self] args in
            guard let self else { throw MCPError.internalError("Window deallocated while executing agent_manage") }
            return try await agentManageToolService.execute(args: args)
        },
        requireTargetWindow: { [weak self] in
            guard let self else { throw MCPError.internalError("Window deallocated while resolving target window") }
            return try requireTargetWindow()
        },
        requireCurrentTabContext: { [weak self] toolName in
            guard let self else { throw MCPError.internalError("Window deallocated while resolving tab context") }
            return try await requireCurrentTabContext(toolName: toolName)
        },
        requireAgentModeConnection: { toolName in
            guard let connectionID = ServerNetworkManager.currentConnectionID else {
                throw MCPError.invalidParams("\(toolName) requires an active MCP connection")
            }
            let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
            guard purpose == .agentModeRun else {
                throw MCPError.invalidParams("\(toolName) is only available during agent mode runs")
            }
            return connectionID
        },
        resolveAgentModeTabID: { [weak self] args, connectionID in
            guard let self else { throw MCPError.internalError("Window deallocated while resolving agent mode tab") }
            return try await resolveTabIDForAgentMode(args: args, connectionID: connectionID)
        },
        resolveContextBuilderTab: { [weak self] args, targetWindow, connectionID in
            guard let self else { throw MCPError.internalError("Window deallocated while resolving context_builder tab") }
            let resolution = try await resolveContextBuilderTab(
                args: args,
                targetWindow: targetWindow,
                connectionID: connectionID
            )
            return MCPWindowToolDependencies.ContextBuilderTabResolution(
                tabID: resolution.tabID,
                workspaceID: resolution.workspaceID,
                bindCaller: resolution.bindCaller
            )
        },
        bindTabForConnection: { [weak self] connectionID, clientName, tabID, workspaceID, windowID in
            guard let self else { throw MCPError.internalError("Window deallocated while binding tab context") }
            try bindTabForConnection(
                connectionID: connectionID,
                clientName: clientName,
                tabID: tabID,
                workspaceID: workspaceID,
                windowID: windowID
            )
        },
        buildTabSelectionReply: { [weak self] selection, includeBlocks, display, codeMapUsageOverride in
            guard let self else { throw MCPError.internalError("Window deallocated while building context_builder selection reply") }
            return await buildTabSelectionReply(
                from: selection,
                includeBlocks: includeBlocks,
                display: display,
                codeMapUsageOverride: codeMapUsageOverride
            )
        },
        sendStageProgress: { [weak self] connectionID, tool, stage, message in
            guard let self else { return }
            await sendStageProgress(connectionID: connectionID, tool: tool, stage: stage, message: message)
        },
        makeOracleExportDestination: { workspace, windowID, tabID in
            try MCPServerViewModel.makeOracleExportDestination(
                workspace: workspace,
                windowID: windowID,
                tabID: tabID
            )
        },
        resolveDefaultOracleExportPath: { [weak self] mode, chatID, destination in
            guard let self else { throw MCPError.internalError("Window deallocated while resolving Oracle export path") }
            return try resolvedDefaultOracleExportPath(mode: mode, chatID: chatID, destination: destination)
        },
        writeGeneratedOracleExportFile: { [weak self] path, content, destination in
            guard let self else { throw MCPError.internalError("Window deallocated while writing Oracle export") }
            return try await writeGeneratedOracleExportFile(path: path, content: content, destination: destination)
        },
        runMCPPlanOrQuestion: { [weak self] contextBuilderVM, tabID, mode, prompt, selection in
            guard let self else { throw MCPError.internalError("Window deallocated while generating context_builder response") }
            return try await contextBuilderVM.runMCPPlanOrQuestion(
                for: tabID,
                oracleViewModel: oracleVM,
                mode: mode,
                prompt: prompt,
                selection: selection
            )
        },
        windowID: windowID,
        promptVM: promptVM,
        workspaceManager: workspaceManager,
        selectionCoordinator: selectionCoordinator,
        applyEditsApprovalStore: applyEditsApprovalStore,
        captureRequestMetadata: { [weak self] in
            guard let self else { return MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: nil, windowID: nil) }
            return await captureRequestMetadata()
        },
        resolveTabContextSnapshot: { [weak self] metadata, toolName, policy in
            guard let self else { throw MCPError.internalError("Window deallocated while resolving tab context") }
            return try resolveTabContextSnapshot(
                from: metadata,
                toolName: toolName,
                policy: policy
            )
        },
        updateCurrentTabContext: { [weak self] toolName, mutation in
            guard let self else { throw MCPError.internalError("Window deallocated while updating tab context") }
            try await updateCurrentTabContext(toolName: toolName, mutation: mutation)
        },
        selectedRecordsForCurrentTabContext: { [weak self] in
            guard let self else { throw MCPError.internalError("Window deallocated while resolving selected files") }
            return try await selectedRecordsForCurrentTabContext()
        },
        boundTabID: { [weak self] connectionID in
            guard let self, let connectionID else { return nil }
            return boundTabID(forConnection: connectionID)
        },
        mapFileManagerErrorToMCP: { [weak self] error, action, path in
            guard let self else { return MCPError.internalError("Window deallocated while mapping file manager error") }
            return await mapFileManagerErrorToMCP(error, action: action, path: path)
        },
        ensureGitDataRootLoaded: { [weak self] workspace, workspaceManager in
            guard let self else { return }
            await ensureGitDataRootLoaded(workspace, workspaceManager)
        },
        logDebug: { message in
            mcpServerViewModelDebugLog(message)
        },
        addPrimaryGitDiffArtifactsToSelection: { [weak self] existing, paths in
            guard let self else { return (existing, []) }
            return await addPrimaryGitDiffArtifactsToSelection(existing: existing, paths: paths)
        },
        workspaceSearch: workspaceSearch,
        parseManageSelectionInputs: { [weak self] rawPaths, slicesValue in
            guard let self else {
                return MCPServerViewModel.ManageSelectionInputs(paths: [], sliceInputs: [], sliceErrors: [], hadExplicitSliceSpec: false)
            }
            return parseManageSelectionInputs(rawPaths: rawPaths, slicesValue: slicesValue)
        },
        resolveFileToolLookupContext: { [weak self] metadata in
            guard let self else { return .visibleWorkspace }
            return await resolveFileToolLookupContext(from: metadata)
        },
        stabilizedVirtualSelection: { [weak self] context in
            guard let self else { return context.selection }
            return await stabilizedVirtualSelection(for: context)
        },
        buildCurrentSelectionReply: { [weak self] includeBlocks, display, extraInvalid, viewMode, resolvedContext in
            guard let self else { throw MCPError.internalError("Window deallocated while building selection reply") }
            return await buildCurrentSelectionReply(
                includeBlocks: includeBlocks,
                display: display,
                extraInvalid: extraInvalid,
                viewMode: viewMode,
                resolvedContext: resolvedContext
            )
        },
        buildSelectionPreviewReply: { [weak self] selection, includeBlocks, display, extraInvalid, viewMode, codeMapUsageOverride, lookupContext in
            guard let self else { throw MCPError.internalError("Window deallocated while building selection preview") }
            return await buildSelectionPreviewReply(
                selection: selection,
                includeBlocks: includeBlocks,
                display: display,
                extraInvalid: extraInvalid,
                viewMode: viewMode,
                codeMapUsageOverride: codeMapUsageOverride,
                lookupContext: lookupContext
            )
        },
        buildSelectionMutationReply: { [weak self] selection, includeBlocks, display, extraInvalid, viewMode, codeMapUsageOverride, virtualContext in
            guard let self else { throw MCPError.internalError("Window deallocated while building selection mutation reply") }
            return await buildTabSelectionReply(
                from: selection,
                includeBlocks: includeBlocks,
                display: display,
                extraInvalid: extraInvalid,
                viewMode: viewMode,
                codeMapUsageOverride: codeMapUsageOverride,
                virtualContext: virtualContext
            )
        },
        buildManageSelectionSetSelection: { [weak self] inputs, mode, existing, lookupRootScope in
            guard let self else { return MCPServerViewModel.BuildStoredSelectionResult(selection: existing, invalidPaths: [], codemapUnavailable: []) }
            return await buildManageSelectionSetSelection(from: inputs, mode: mode, existing: existing, lookupRootScope: lookupRootScope)
        },
        addStoredSelectionPaths: { [weak self] existing, paths, rawPaths, mode, lookupRootScope in
            guard let self else { return MCPServerViewModel.AddStoredSelectionResult(selection: existing, invalidPaths: [], resolvedMap: [:], mutated: false, codemapUnavailable: []) }
            return await addStoredSelectionPaths(existing: existing, paths: paths, rawPaths: rawPaths, mode: mode, lookupRootScope: lookupRootScope)
        },
        removeStoredSelectionPaths: { [weak self] existing, paths, rawPaths, mode, lookupRootScope in
            guard let self else { return (existing, [], [:], false) }
            return await removeStoredSelectionPaths(existing: existing, paths: paths, rawPaths: rawPaths, mode: mode, lookupRootScope: lookupRootScope)
        },
        promoteStoredSelectionPaths: { [weak self] existing, paths, rawPaths, strict, lookupRootScope in
            guard let self else { return (existing, [], false) }
            return await promoteStoredSelectionPaths(existing: existing, paths: paths, rawPaths: rawPaths, strict: strict, lookupRootScope: lookupRootScope)
        },
        demoteStoredSelectionPaths: { [weak self] existing, paths, rawPaths, strict, lookupRootScope in
            guard let self else { return MCPServerViewModel.DemoteStoredSelectionResult(selection: existing, invalidPaths: [], codemapUnavailable: [], mutated: false) }
            return await demoteStoredSelectionPaths(existing: existing, paths: paths, rawPaths: rawPaths, strict: strict, lookupRootScope: lookupRootScope)
        },
        computeSelectionSlicesVirtual: { [weak self] base, entries, mode, lookupRootScope in
            guard let self else {
                return (base, MCPServerViewModel.MCPSelectionSlicesMutationResult(invalidPaths: [], resolvedMap: [:], snapshot: [:]), false)
            }
            return await computeSelectionSlicesVirtual(base: base, entries: entries, mode: mode, lookupRootScope: lookupRootScope)
        },
        persistResolvedTabContextSnapshot: { [weak self] resolvedContext, metadata, mutated in
            guard let self else { return }
            await persistResolvedTabContextSnapshot(resolvedContext, metadata: metadata, mutated: mutated)
        },
        makeSelectionHintError: { [weak self] paths, operation, lookupRootScope in
            guard let self else { return "Window deallocated while resolving selection inputs." }
            return await makeSelectionHintError(paths: paths, operation: operation, lookupRootScope: lookupRootScope)
        },
        performFileAction: { [weak self] action, path, content, newPath, ifExists in
            guard let self else { throw MCPError.internalError("Window deallocated while performing file action") }
            try await performFileAction(action: action, path: path, content: content, newPath: newPath, ifExists: ifExists)
        },
        buildCodeStructureDTO: { [weak self] files, maxResults, includeUnmappedPaths, projection in
            guard let self else { throw MCPError.internalError("Window deallocated while building code structure") }
            return await buildCodeStructureDTO(fromRecords: files, maxResults: maxResults, includeUnmappedPaths: includeUnmappedPaths, projection: projection)
        },
        resolveFilesForCodeStructure: { [weak self] paths, lookupRootScope in
            guard let self else { return [] }
            return await resolveFilesForCodeStructure(paths: paths, lookupRootScope: lookupRootScope)
        },
        buildStoreBackedFileTreeResult: { [weak self] mode, maxDepth, startPath, lookupContext in
            guard let self else { throw MCPError.internalError("Window deallocated while building file tree") }
            return try await buildStoreBackedFileTreeResult(mode: mode, maxDepth: maxDepth, startPath: startPath, lookupContext: lookupContext)
        },
        readFile: { [weak self] path, startLine1Based, lineCount, lookupRootScope in
            guard let self else { throw MCPError.internalError("Window deallocated while reading file") }
            return try await readFile(path: path, startLine1Based: startLine1Based, lineCount: lineCount, lookupRootScope: lookupRootScope)
        },
        maybeAutoSelectReadFileSelection: { [weak self] reply, requestedPath in
            guard let self else { return }
            await maybeAutoSelectReadFileSelection(reply: reply, requestedPath: requestedPath)
        },
        maybeAutoSelectFileSearchSlices: { [weak self] mode, contextLines, reply in
            guard let self else { return }
            await maybeAutoSelectFileSearchSlices(mode: mode, contextLines: contextLines, reply: reply)
        },
        workspaceContextMessage: { [weak self] operation, path in
            guard let self else { return "Window deallocated while resolving workspace context." }
            return await workspaceContextMessage(forOperation: operation, path: path)
        },
        parseCopyPresetSelector: { [weak self] value in
            guard let self else { return nil }
            return parseCopyPresetSelector(from: value)
        },
        resolveCopyPreset: { [weak self] selector in
            guard let self else { return nil }
            return resolveCopyPreset(from: selector)
        },
        buildTabWorkspaceContext: { [weak self] context, include, display, copyPresetOverride, activeTabCompatibility in
            guard let self else { throw MCPError.internalError("Window deallocated while building workspace context") }
            return await buildTabWorkspaceContext(
                context: context,
                include: include,
                display: display,
                copyPresetOverride: copyPresetOverride,
                activeTabCompatibility: activeTabCompatibility
            )
        },
        selectedFilesWithStats: { [weak self] resolvedContext in
            guard let self else { throw MCPError.internalError("Window deallocated while resolving selected files") }
            return await selectedFilesWithStats(resolvedContext: resolvedContext)
        },
        selectionCollectionsForCurrentTabContext: { [weak self] in
            guard let self else { throw MCPError.internalError("Window deallocated while resolving selection collections") }
            return try await selectionCollectionsForCurrentTabContext()
        },
        buildCopyPresetContextDTO: { [weak self] active, effective in
            guard let self else {
                return ToolResultDTOs.CopyPresetContextDTO(active: ToolResultDTOs.CopyPresetDescriptorDTO(id: active.id.uuidString, name: active.name, kind: active.builtInKind?.rawValue, isBuiltIn: active.isBuiltIn), effective: ToolResultDTOs.CopyPresetDescriptorDTO(id: effective.id.uuidString, name: effective.name, kind: effective.builtInKind?.rawValue, isBuiltIn: effective.isBuiltIn), isOverridden: active.id != effective.id)
            }
            return buildCopyPresetContextDTO(active: active, effective: effective)
        },
        buildCopyPresetsListDTO: { [weak self] in
            guard let self else { return [] }
            return buildCopyPresetsListDTO()
        },
        copyPresetDescriptorDTO: { [weak self] preset in
            guard let self else { return ToolResultDTOs.CopyPresetDescriptorDTO(id: preset.id.uuidString, name: preset.name, kind: preset.builtInKind?.rawValue, isBuiltIn: preset.isBuiltIn) }
            return toDescriptorDTO(preset)
        },
        buildExportSelectedFileInfos: { [weak self] resolvedContext, cfg, selectionOverride, display in
            guard let self else { throw MCPError.internalError("Window deallocated while building export file info") }
            return try await buildExportSelectedFileInfos(resolvedContext: resolvedContext, cfg: cfg, selectionOverride: selectionOverride, display: display)
        },
        buildTabClipboardContent: { [weak self] cfg, context in
            guard let self else { return "" }
            return await buildTabClipboardContent(cfg: cfg, context: context)
        },
        writePromptExportFile: { [weak self] path, content in
            guard let self else { throw MCPError.internalError("Window deallocated while exporting prompt") }
            return try await writePromptExportFile(path: path, content: content)
        },
        latestTokenBreakdown: { [weak self] in
            guard let self else { return TokenCountingViewModel.TokenBreakdown(total: 0, files: 0, prompt: 0, meta: 0, fileTree: 0, git: 0, other: 0) }
            return latestTokenBreakdown()
        }
    )

    /// Single window-scoped service registered with ServiceRegistry for this window's MCP tool catalog.
    @MainActor
    private lazy var windowToolCatalogService = MCPWindowToolCatalogService(
        windowID: windowID,
        providers: [
            MCPSelectionToolProvider(runtime: windowToolRuntime, dependencies: windowToolDependencies),
            MCPFileToolProvider(runtime: windowToolRuntime, dependencies: windowToolDependencies),
            MCPPromptContextToolProvider(runtime: windowToolRuntime, dependencies: windowToolDependencies),
            MCPApplyEditsToolProvider(runtime: windowToolRuntime, dependencies: windowToolDependencies),
            MCPOracleToolProvider(runtime: windowToolRuntime, dependencies: windowToolDependencies),
            MCPGitToolProvider(runtime: windowToolRuntime, dependencies: windowToolDependencies),
            MCPWorktreeToolProvider(runtime: windowToolRuntime, dependencies: windowToolDependencies),
            MCPContextBuilderToolProvider(runtime: windowToolRuntime, dependencies: windowToolDependencies),
            MCPAskUserToolProvider(runtime: windowToolRuntime, dependencies: windowToolDependencies),
            MCPAgentControlToolProvider(runtime: windowToolRuntime, dependencies: windowToolDependencies),
            MCPAgentSessionControlToolProvider(runtime: windowToolRuntime, dependencies: windowToolDependencies)
        ]
    )
    private var cancellables: Set<AnyCancellable> = []
    @MainActor
    var tabContextByConnectionID: [UUID: TabScopedContext] = [:]
    @MainActor
    var pendingRunScopedTabContexts = PendingRunScopedContextStore()
    @MainActor
    var connectionIDByRunID: [UUID: UUID] = [:]
    @MainActor
    var connectionIDToRunID: [UUID: UUID] = [:]
    @MainActor
    var windowIDByConnection: [UUID: Int] = [:]
    @MainActor
    var tabContextCancellablesByConnectionID: [UUID: Set<AnyCancellable>] = [:]
    @MainActor
    var lastContextByClientAndWindow: [String: [Int: TabScopedContext]] = [:]
    /// Temporary legacy routing switch. Diagnostics/tests can disable active-tab
    /// compatibility to verify clients bind explicitly with `bind_context`.
    @MainActor
    var activeTabCompatibilityFallbackEnabled = true
    @MainActor
    var activeTabCompatibilityFallbackDiagnostics: [ActiveTabCompatibilityFallbackDiagnostic] = []

    var isMultiWindowModeEffectivelyActive: Bool {
        WindowStatesManager.shared.isMultiWindowModeEffectivelyActive
    }

    @MainActor
    private func dashboardConnectionsForThisWindow() -> [MCPService.DashboardConnection] {
        guard let dashboard else { return [] }
        let allowNilWindow = !isMultiWindowModeEffectivelyActive
        return dashboard.connections.filter { connection in
            connection.windowID == windowID || (allowNilWindow && connection.windowID == nil)
        }
    }

    @MainActor
    private func recomputeCloseSafetyState() {
        guard windowToolsEnabled else {
            closeSafetyState = .inactive
            return
        }

        let connections = dashboardConnectionsForThisWindow()
        let liveConnections = connections.filter { connection in
            switch connection.state {
            case .ready, .waiting:
                true
            case .setup, .failed, .cancelled, .unknown:
                false
            }
        }
        let liveConnectionCount = liveConnections.count
        var activeExecutionCount = liveConnections.reduce(into: 0) { partialResult, connection in
            if connection.hasInFlightCalls {
                partialResult += 1
            }
        }
        let activeTool = windowActiveToolName
        if activeExecutionCount == 0, activeTool != nil {
            activeExecutionCount = 1
        }

        closeSafetyState = WindowMCPCloseSafetyState(
            toolsEnabled: windowToolsEnabled,
            liveConnectionCount: liveConnectionCount,
            activeExecutionCount: activeExecutionCount,
            hasIdleLiveConnections: liveConnectionCount > 0 && activeExecutionCount == 0,
            activeToolName: activeTool
        )
    }

    // MARK: - - Cancellation support

    /// Per-run active tool execution tracking — supports multiple concurrent tool calls per run.
    @MainActor
    private struct ActiveToolExecution {
        let executionID: UUID
        let runID: UUID
        let connectionID: UUID
        let toolName: String
        let startedAt: Date
        let cancel: () -> Void
    }

    @MainActor
    private var activeToolExecutionsByRunID: [UUID: [UUID: ActiveToolExecution]] = [:]
    @MainActor
    private var runIDByToolExecutionID: [UUID: UUID] = [:]

    @MainActor
    private struct AgentRunWaitScope {
        let token: UUID
        let parentRunID: UUID
        let childSessionIDs: Set<UUID>
        let startedAt: Date
        let timeoutSeconds: TimeInterval?
        let metadata: RequestMetadata
    }

    @MainActor
    private var agentRunWaitScopesByToken: [UUID: AgentRunWaitScope] = [:]
    @MainActor
    private var childAgentRunWaitCountsByParentRunID: [UUID: [UUID: Int]] = [:]
    private let agentRunWaitScopeStaleGraceSeconds: TimeInterval = 60

    /// Cumulative count of tool executions that have ended (success/error/cancel) per run.
    /// Used by the Claude steering interrupt safety gate to verify that the provider stream
    /// has acknowledged all locally-completed tool results before sending an interrupt.
    @MainActor
    private var toolEndedCountByRunID: [UUID: Int] = [:]

    /// Continuations parked by `awaitNoActiveToolExecutions` waiting for a runID to have zero
    /// in-flight tool executions. Keyed by runID → waiterID → continuation.
    @MainActor
    private var toolIdleWaitersByRunID: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]

    @MainActor
    private func debugActiveTools(for runID: UUID) -> String {
        let executions = activeToolExecutionsByRunID[runID] ?? [:]
        guard !executions.isEmpty else { return "none" }
        return executions.values
            .map { "\($0.toolName)#\(String($0.executionID.uuidString.prefix(8)))" }
            .sorted()
            .joined(separator: ",")
    }

    @MainActor
    private var cancelCurrentTool: (() -> Void)?
    private let applyEditsApprovalStore: ApplyEditsApprovalStore

    @MainActor
    func cancelActiveTool() {
        // Prefer cancellation via the per-run registry if the active token is tracked
        if let token = activeToolToken,
           let runID = runIDByToolExecutionID[token],
           activeToolExecutionsByRunID[runID]?[token] != nil
        {
            cancelToolExecution(executionID: token, reason: "cancelActiveTool")
        } else {
            cancelCurrentTool?()
        }

        // Immediately update user-facing state so the active-tool indicator and Cancel button don't stay stuck
        clearActiveToolSlot()
    }

    @MainActor
    private func clearActiveToolSlot() {
        activeToolName = nil
        cancelCurrentTool = nil
        activeToolToken = nil
        activeToolConnectionID = nil
    }

    /// Cancel all active tool executions for a given runID.
    /// Returns the number of executions cancelled.
    @MainActor
    @discardableResult
    func cancelActiveToolsForRun(runID: UUID, reason: String? = nil) -> Int {
        guard let executions = activeToolExecutionsByRunID.removeValue(forKey: runID) else {
            // Even if there are no active tools, resume any waiters so
            // steering flush tasks unblock and can observe cancellation.
            resumeAllToolIdleWaiters(forRunID: runID)
            toolEndedCountByRunID.removeValue(forKey: runID)
            return 0
        }
        var cancelledCount = 0
        for (executionID, execution) in executions {
            execution.cancel()
            runIDByToolExecutionID.removeValue(forKey: executionID)
            cancelledCount += 1
        }
        // Clear single-slot UI state if it was pointing at one of the cancelled executions
        if let token = activeToolToken, executions[token] != nil {
            clearActiveToolSlot()
        }
        // Resume any steering idle-waiters since the run's tools are now gone
        resumeAllToolIdleWaiters(forRunID: runID)
        // Clean up the ended-count tracker for this run since it's being torn down.
        toolEndedCountByRunID.removeValue(forKey: runID)
        return cancelledCount
    }

    /// Cancel active tool executions owned by a specific connection.
    /// Disconnect cleanup must use this identity-bound API instead of comparing tool names,
    /// because a newer connection can legitimately start the same tool name before stale cleanup runs.
    @MainActor
    @discardableResult
    func cancelActiveToolsForConnection(connectionID: UUID, reason: String? = nil) -> Int {
        let matchingExecutionIDs = activeToolExecutionsByRunID.values.flatMap { executions in
            executions.values.compactMap { execution in
                execution.connectionID == connectionID ? execution.executionID : nil
            }
        }
        let matchingExecutionIDSet = Set(matchingExecutionIDs)
        let activeTokenBeforeCancellation = activeToolToken

        var cancelledCount = 0
        for executionID in matchingExecutionIDs {
            if cancelToolExecution(executionID: executionID, reason: reason) {
                cancelledCount += 1
            }
        }

        guard activeToolConnectionID == connectionID else {
            return cancelledCount
        }

        if let activeTokenBeforeCancellation,
           matchingExecutionIDSet.contains(activeTokenBeforeCancellation)
        {
            clearActiveToolSlot()
            return cancelledCount
        }

        // Legacy single-slot fallback for work that predates or bypasses the per-run registry.
        // Only the recorded owning connection may cancel this slot.
        if activeToolName != nil || cancelCurrentTool != nil || activeToolToken != nil {
            let legacyCancel = cancelCurrentTool
            legacyCancel?()
            clearActiveToolSlot()
            if legacyCancel != nil {
                cancelledCount += 1
            }
        }

        return cancelledCount
    }

    @MainActor
    private func registerToolExecution(
        executionID: UUID,
        runID: UUID,
        connectionID: UUID,
        toolName: String,
        cancel: @escaping () -> Void
    ) {
        let execution = ActiveToolExecution(
            executionID: executionID,
            runID: runID,
            connectionID: connectionID,
            toolName: toolName,
            startedAt: Date(),
            cancel: cancel
        )
        activeToolExecutionsByRunID[runID, default: [:]][executionID] = execution
        runIDByToolExecutionID[executionID] = runID
        steeringDebugLog("[AgentRunSteeringWake] MCP tool register runID=\(runID) executionID=\(executionID) tool=\(toolName) active=\(debugActiveTools(for: runID))")
    }

    @MainActor
    private func unregisterToolExecution(executionID: UUID) {
        guard let runID = runIDByToolExecutionID.removeValue(forKey: executionID) else {
            steeringDebugLog("[AgentRunSteeringWake] MCP tool unregister ignored missing runID executionID=\(executionID)")
            return
        }
        let toolName = activeToolExecutionsByRunID[runID]?[executionID]?.toolName ?? "unknown"
        activeToolExecutionsByRunID[runID]?.removeValue(forKey: executionID)
        // Track cumulative tool completions for steering interrupt safety gate.
        toolEndedCountByRunID[runID, default: 0] += 1
        if activeToolExecutionsByRunID[runID]?.isEmpty == true {
            activeToolExecutionsByRunID.removeValue(forKey: runID)
            steeringDebugLog("[AgentRunSteeringWake] MCP tool unregister drained runID=\(runID) executionID=\(executionID) tool=\(toolName) endedCount=\(toolEndedCountByRunID[runID] ?? 0)")
            resumeAllToolIdleWaiters(forRunID: runID)
        } else {
            steeringDebugLog("[AgentRunSteeringWake] MCP tool unregister runID=\(runID) executionID=\(executionID) tool=\(toolName) remaining=\(debugActiveTools(for: runID)) endedCount=\(toolEndedCountByRunID[runID] ?? 0)")
        }
    }

    /// Returns the cumulative number of tool executions that have completed for the given runID.
    /// Used by the Claude steering interrupt safety gate.
    @MainActor
    func toolEndedCount(runID: UUID) -> Int {
        toolEndedCountByRunID[runID] ?? 0
    }

    /// Returns whether the given run currently has any active RepoPrompt MCP tool executions.
    @MainActor
    func hasActiveToolExecutions(runID: UUID) -> Bool {
        guard let executions = activeToolExecutionsByRunID[runID] else {
            return false
        }
        return !executions.isEmpty
    }

    /// Returns whether the given parent run is currently blocked in an `agent_run` wait.
    /// Agent control-plane tools stay out of active tool tracking to avoid steering deadlocks,
    /// so watchdog/liveness checks must consult this wait-scope state separately.
    @MainActor
    func hasActiveChildAgentRunWaits(runID: UUID) -> Bool {
        purgeStaleAgentRunWaitScopes(source: "liveness-query")
        let active = !(childAgentRunWaitCountsByParentRunID[runID]?.isEmpty ?? true)
        if active {
            let scopes = agentRunWaitScopesByToken.values.filter { $0.parentRunID == runID }
            let oldestAge = scopes.map { Date().timeIntervalSince($0.startedAt) }.max() ?? 0
            steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope liveness parentRunID=\(runID) scopes=\(scopes.count) oldestAge=\(oldestAge) counts=\(debugChildAgentRunWaits(for: runID))")
        }
        return active
    }

    // MARK: - Tool Idle Waiting (Steering Safety)

    /// Waits until the given runID has zero active MCP tool executions.
    /// Returns immediately if already idle. Supports cooperative cancellation
    /// via structured concurrency — if the calling Task is cancelled the
    /// continuation is cleaned up and a `CancellationError` is thrown.
    @MainActor
    func awaitNoActiveToolExecutions(runID: UUID) async throws {
        // Fast path: already idle
        let executions = activeToolExecutionsByRunID[runID]
        if executions == nil || executions!.isEmpty {
            steeringDebugLog("[AgentRunSteeringWake] MCP idle wait fast-idle runID=\(runID)")
            return
        }
        steeringDebugLog("[AgentRunSteeringWake] MCP idle wait blocking runID=\(runID) active=\(debugActiveTools(for: runID))")

        let waiterID = UUID()

        // Use withTaskCancellationHandler so that Task.cancel() from the
        // outside (e.g., user cancels the run) will promptly resume us.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Double-check under the same MainActor turn — tools may have
                // drained between the fast-path check and here.
                let stillActive = activeToolExecutionsByRunID[runID]
                if stillActive == nil || stillActive!.isEmpty {
                    steeringDebugLog("[AgentRunSteeringWake] MCP idle wait drained before parking runID=\(runID) waiterID=\(waiterID)")
                    continuation.resume()
                    return
                }
                toolIdleWaitersByRunID[runID, default: [:]][waiterID] = continuation
                steeringDebugLog("[AgentRunSteeringWake] MCP idle wait parked runID=\(runID) waiterID=\(waiterID) active=\(debugActiveTools(for: runID)) waiters=\(toolIdleWaitersByRunID[runID]?.count ?? 0)")
            }
        } onCancel: {
            // Must hop to MainActor to safely remove the waiter.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let continuation = toolIdleWaitersByRunID[runID]?
                    .removeValue(forKey: waiterID)
                {
                    continuation.resume() // unblock so CancellationError propagates
                }
                if toolIdleWaitersByRunID[runID]?.isEmpty == true {
                    toolIdleWaitersByRunID.removeValue(forKey: runID)
                }
            }
        }

        // After resuming, respect cooperative cancellation
        try Task.checkCancellation()
        steeringDebugLog("[AgentRunSteeringWake] MCP idle wait completed runID=\(runID) waiterID=\(waiterID)")
    }

    /// Resumes all parked idle-waiters for a runID (called when tools drain to zero).
    @MainActor
    private func resumeAllToolIdleWaiters(forRunID runID: UUID) {
        guard let waiters = toolIdleWaitersByRunID.removeValue(forKey: runID) else {
            steeringDebugLog("[AgentRunSteeringWake] MCP idle wait resume skipped no waiters runID=\(runID)")
            return
        }
        steeringDebugLog("[AgentRunSteeringWake] MCP idle wait resuming runID=\(runID) waiters=\(waiters.count)")
        for (_, continuation) in waiters {
            continuation.resume()
        }
    }

    @MainActor
    @discardableResult
    private func cancelToolExecution(executionID: UUID, reason: String?) -> Bool {
        guard let runID = runIDByToolExecutionID[executionID],
              let execution = activeToolExecutionsByRunID[runID]?[executionID]
        else {
            return false
        }
        execution.cancel()
        unregisterToolExecution(executionID: executionID)
        return true
    }

    @MainActor
    private func managerRunIDFallbackIsCompatibleWithThisWindow(
        connectionID: UUID,
        metadata: RequestMetadata,
        managerWindowID: Int?
    ) -> Bool {
        let candidateWindowIDs = [
            managerWindowID,
            metadata.windowID,
            windowIDByConnection[connectionID]
        ].compactMap(\.self)

        for candidateWindowID in candidateWindowIDs where candidateWindowID != windowID {
            mcpServerViewModelDebugLog("manager runID fallback rejected for connection=\(connectionID): candidateWindow=\(candidateWindowID) currentWindow=\(windowID)")
            return false
        }

        return true
    }

    @MainActor
    private func beginAgentRunWaitScope(metadata: RequestMetadata, sessionIDs: Set<UUID>, timeoutSeconds: TimeInterval?) async -> UUID? {
        guard !sessionIDs.isEmpty else { return nil }
        purgeStaleAgentRunWaitScopes(source: "begin")
        let resolvedContext = try? resolveTabContextSnapshot(
            from: metadata,
            toolName: "agent_run_wait_scope",
            policy: .allowLegacyImplicitRouting
        )
        guard let parentRunID = await resolveRunIDForExecution(metadata: metadata, resolvedContext: resolvedContext) else {
            steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope skipped: no parent runID childSessions=\(sessionIDs.map(\.uuidString).sorted().joined(separator: ","))")
            return nil
        }
        let token = UUID()
        let scope = AgentRunWaitScope(
            token: token,
            parentRunID: parentRunID,
            childSessionIDs: sessionIDs,
            startedAt: Date(),
            timeoutSeconds: timeoutSeconds,
            metadata: metadata
        )
        agentRunWaitScopesByToken[token] = scope
        for sessionID in sessionIDs {
            childAgentRunWaitCountsByParentRunID[parentRunID, default: [:]][sessionID, default: 0] += 1
        }
        steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope begin parentRunID=\(parentRunID) token=\(token) timeout=\(timeoutSeconds.map { String($0) } ?? "none") childSessions=\(sessionIDs.map(\.uuidString).sorted().joined(separator: ",")) counts=\(debugChildAgentRunWaits(for: parentRunID))")
        return token
    }

    @MainActor
    private func endAgentRunWaitScope(_ token: UUID, completion: AgentRunWaitScopeCompletion) {
        guard let scope = agentRunWaitScopesByToken.removeValue(forKey: token) else {
            steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope end ignored missing token=\(token) reason=\(completion.reason.rawValue)")
            return
        }
        decrementAgentRunWaitScope(scope)
        let elapsed = Date().timeIntervalSince(scope.startedAt)
        steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope end parentRunID=\(scope.parentRunID) token=\(token) elapsed=\(elapsed) reason=\(completion.reason.rawValue) result=\(completion.result ?? "none") winner=\(completion.winnerSessionID?.uuidString ?? "none") pending=\(completion.pendingSessionIDs.map(\.uuidString).sorted().joined(separator: ",")) childSessions=\(scope.childSessionIDs.map(\.uuidString).sorted().joined(separator: ",")) remaining=\(debugChildAgentRunWaits(for: scope.parentRunID))")
    }

    @MainActor
    private func decrementAgentRunWaitScope(_ scope: AgentRunWaitScope) {
        for sessionID in scope.childSessionIDs {
            let existing = childAgentRunWaitCountsByParentRunID[scope.parentRunID]?[sessionID] ?? 0
            if existing <= 1 {
                childAgentRunWaitCountsByParentRunID[scope.parentRunID]?.removeValue(forKey: sessionID)
            } else {
                childAgentRunWaitCountsByParentRunID[scope.parentRunID]?[sessionID] = existing - 1
            }
        }
        if childAgentRunWaitCountsByParentRunID[scope.parentRunID]?.isEmpty == true {
            childAgentRunWaitCountsByParentRunID.removeValue(forKey: scope.parentRunID)
        }
    }

    @MainActor
    private func purgeStaleAgentRunWaitScopes(now: Date = Date(), source: String) {
        let staleTokens = agentRunWaitScopesByToken.compactMap { token, scope -> UUID? in
            let timeout = scope.timeoutSeconds ?? AgentRunMCPToolService.defaultWaitTimeoutSeconds
            let maxAge = timeout + agentRunWaitScopeStaleGraceSeconds
            return now.timeIntervalSince(scope.startedAt) > maxAge ? token : nil
        }
        for token in staleTokens {
            guard let scope = agentRunWaitScopesByToken.removeValue(forKey: token) else { continue }
            decrementAgentRunWaitScope(scope)
            let elapsed = now.timeIntervalSince(scope.startedAt)
            steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope stale purge source=\(source) parentRunID=\(scope.parentRunID) token=\(token) elapsed=\(elapsed) timeout=\(scope.timeoutSeconds.map { String($0) } ?? "default") childSessions=\(scope.childSessionIDs.map(\.uuidString).sorted().joined(separator: ","))")
        }
    }

    @MainActor
    private func debugChildAgentRunWaits(for parentRunID: UUID) -> String {
        let counts = childAgentRunWaitCountsByParentRunID[parentRunID] ?? [:]
        guard !counts.isEmpty else { return "none" }
        return counts
            .map { "\($0.key.uuidString.prefix(8)):\($0.value)" }
            .sorted()
            .joined(separator: ",")
    }

    @MainActor
    func wakeAgentRunWaitersOwnedByActiveRun(
        runID: UUID,
        source: String,
        snapshotForSessionID: (UUID) -> AgentRunMCPSnapshot?
    ) async {
        let sessionIDs = Set(childAgentRunWaitCountsByParentRunID[runID]?.keys.map(\.self) ?? [])
        guard !sessionIDs.isEmpty else {
            steeringDebugLog("[AgentRunSteeringWake] parent wake found no child agent_run waiters source=\(source) parentRunID=\(runID) active=\(debugActiveTools(for: runID))")
            return
        }
        steeringDebugLog("[AgentRunSteeringWake] parent wake child agent_run waiters source=\(source) parentRunID=\(runID) childSessions=\(sessionIDs.map(\.uuidString).sorted().joined(separator: ",")) active=\(debugActiveTools(for: runID))")
        for sessionID in sessionIDs {
            guard let snapshot = snapshotForSessionID(sessionID) else {
                steeringDebugLog("[AgentRunSteeringWake] parent wake skipped missing child snapshot source=\(source) parentRunID=\(runID) childSessionID=\(sessionID)")
                continue
            }
            await AgentRunSessionStore.wakeCurrentWaiters(snapshot, reason: .steeringRequested)
        }
        await Task.yield()
        steeringDebugLog("[AgentRunSteeringWake] parent wake yielded source=\(source) parentRunID=\(runID)")
    }

    @MainActor
    func wakeAndDrainAgentRunWaitersOwnedByActiveRun(
        runID: UUID,
        source: String,
        timeoutSeconds: TimeInterval,
        snapshotForSessionID: (UUID) -> AgentRunMCPSnapshot?
    ) async -> Bool {
        guard hasActiveChildAgentRunWaits(runID: runID) else {
            steeringDebugLog("[AgentRunSteeringWake] parent drain fast-idle source=\(source) parentRunID=\(runID)")
            return true
        }

        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        while true {
            await wakeAgentRunWaitersOwnedByActiveRun(
                runID: runID,
                source: source,
                snapshotForSessionID: snapshotForSessionID
            )

            guard hasActiveChildAgentRunWaits(runID: runID) else {
                steeringDebugLog("[AgentRunSteeringWake] parent drain completed source=\(source) parentRunID=\(runID)")
                return true
            }
            guard timeoutSeconds > 0, Date() < deadline else {
                steeringDebugLog("[AgentRunSteeringWake] parent drain timed out source=\(source) parentRunID=\(runID) timeout=\(timeoutSeconds) remaining=\(debugChildAgentRunWaits(for: runID))")
                return false
            }

            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                steeringDebugLog("[AgentRunSteeringWake] parent drain cancelled source=\(source) parentRunID=\(runID)")
                return false
            }
        }
    }

    @MainActor
    private func resolveRunIDForExecution(
        metadata: RequestMetadata,
        resolvedContext: ResolvedTabContextSnapshot?
    ) async -> UUID? {
        if let connectionID = metadata.connectionID,
           let runID = connectionIDToRunID[connectionID]
        {
            return runID
        }

        if let resolvedContext,
           !resolvedContext.usesActiveTabCompatibility,
           let runID = resolvedContext.snapshot.runID
        {
            let context = resolvedContext.snapshot
            if let connectionID = metadata.connectionID {
                _ = registerRunIDMapping(
                    connectionID: connectionID,
                    runID: runID,
                    windowID: context.windowID
                )
            }
            return runID
        }

        guard let connectionID = metadata.connectionID else {
            return nil
        }

        let manager = ServerNetworkManager.shared
        let managerWindowID = await manager.selectedWindow(for: connectionID)
        guard managerRunIDFallbackIsCompatibleWithThisWindow(
            connectionID: connectionID,
            metadata: metadata,
            managerWindowID: managerWindowID
        ) else {
            return nil
        }

        guard let managerRunID = await manager.runIDForConnection(connectionID) else {
            return nil
        }

        let resolvedManagerWindowID = await manager.selectedWindow(for: connectionID)
        guard managerRunIDFallbackIsCompatibleWithThisWindow(
            connectionID: connectionID,
            metadata: metadata,
            managerWindowID: resolvedManagerWindowID
        ) else {
            return nil
        }

        return managerRunID
    }

    #if DEBUG
        @MainActor
        func test_beginResolvedToolExecution(
            metadata: RequestMetadata,
            resolvedContext: ResolvedTabContextSnapshot?,
            toolName: String = "test_tool",
            cancel: @escaping () -> Void = {}
        ) async -> (executionID: UUID, runID: UUID)? {
            guard let connectionID = metadata.connectionID,
                  let runID = await resolveRunIDForExecution(metadata: metadata, resolvedContext: resolvedContext),
                  shouldRegisterRunToolExecution(toolName: toolName)
            else {
                return nil
            }

            let executionID = UUID()
            registerToolExecution(
                executionID: executionID,
                runID: runID,
                connectionID: connectionID,
                toolName: toolName,
                cancel: cancel
            )
            return (executionID, runID)
        }

        @MainActor
        func test_endToolExecution(executionID: UUID) {
            unregisterToolExecution(executionID: executionID)
        }

        @MainActor
        @discardableResult
        func test_setActiveToolSlot(
            toolName: String,
            connectionID: UUID?,
            cancel: @escaping () -> Void = {}
        ) -> UUID {
            let token = UUID()
            activeToolToken = token
            activeToolConnectionID = connectionID
            activeToolName = toolName
            cancelCurrentTool = cancel
            return token
        }

        @MainActor
        func test_activeToolConnectionID() -> UUID? {
            activeToolConnectionID
        }

        @MainActor
        func test_clearActiveToolSlot() {
            clearActiveToolSlot()
        }
    #endif

    // ---------------------------------------------------------------------
    // MARK: Initialisation

    /// ---------------------------------------------------------------------
    init(
        service: MCPService,
        promptVM: PromptViewModel,
        oracleVM: OracleViewModel,
        workspaceManager: WorkspaceManagerViewModel,
        selectionCoordinator: WorkspaceSelectionCoordinator? = nil,
        windowID: Int,
        workspaceSearch: @escaping WorkspaceSearchHandler,
        ensureGitDataRootLoaded: @escaping (WorkspaceModel?, WorkspaceManagerViewModel?) async -> Void,
        applyEditsApprovalStore: ApplyEditsApprovalStore = .shared
    ) {
        self.service = service
        self.windowID = windowID
        self.promptVM = promptVM
        self.oracleVM = oracleVM
        self.workspaceManager = workspaceManager
        self.selectionCoordinator = selectionCoordinator
        self.workspaceSearch = workspaceSearch
        self.ensureGitDataRootLoaded = ensureGitDataRootLoaded
        self.applyEditsApprovalStore = applyEditsApprovalStore

        // Observe service state updates
        observeService()

        // Observe external client events from disk
        observeExternalEvents()

        // ⬇️ NEW: Initialise local published properties with current service snapshot
        Task { [weak self] in
            guard let self else { return }
            let snap = await self.service.currentState()
            await apply(snap) // @MainActor method
        }

        ToolAvailabilityStore.shared.$toolSummaries
            .dropFirst()
            .sink { [weak self] _ in
                #if DEBUG || EDIT_FLOW_PERF
                    let invalidationToolSummariesChangeState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.invalidationToolSummariesChange)
                #endif
                self?.invalidateToolsCache()
                #if DEBUG || EDIT_FLOW_PERF
                    EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.invalidationToolSummariesChange, invalidationToolSummariesChangeState)
                #endif
            }
            .store(in: &cancellables)

        // Enable tools based on auto-start setting. CE builds do not license-gate MCP.
        windowToolsEnabled = GlobalSettingsStore.shared.mcpAutoStart()
    }

    // MARK: – Private helpers

    /// Listens to `service.stateStream` and updates UI state.
    /// Runs once during init, so no cancellation handling needed.
    private func observeService() {
        Task { [weak self] in
            guard let self else { return }

            for await snapshot in service.stateStream {
                // Hop back to the main actor for all UI/state mutations
                await apply(snapshot)
            }
        }
    }

    /// Observes external client error events written to disk by the CLI
    private func observeExternalEvents() {
        let monitor = MCPExternalEventsMonitor.shared
        monitor.start()

        // Subscribe to event updates
        monitor.$latestEvent
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.lastExternalClientEvent = event
            }
            .store(in: &cancellables)

        // Subscribe to error count updates
        monitor.$recentErrorCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.externalClientErrorCount = count
            }
            .store(in: &cancellables)

        // Cleanup old events periodically (once per app launch is enough)
        monitor.cleanupOldEvents()
    }

    /// Updates published properties and sets the overlay visibility.
    /// Must run on the main actor because the view-model is `@MainActor`.
    @MainActor
    private func apply(_ snap: MCPService.Snapshot) async {
        let hadPendingApproval = pendingClientID != nil

        isRunning = snap.isRunning
        pendingClientID = snap.pendingClientID
        diagnostics = snap.diagnostics
        lastErrorMessage = humanReadableError(from: snap.diagnostics.issue)

        // Show the approval overlay when a client is waiting
        isApprovalOverlayVisible = (snap.pendingClientID != nil)

        // When a new approval request arrives, bring the appropriate window to front
        if snap.pendingClientID != nil, !hadPendingApproval, windowToolsEnabled {
            bringWindowToFront()
        }

        // Request user attention if app is not active
        if snap.pendingClientID != nil, !NSApp.isActive {
            NSApp.requestUserAttention(.criticalRequest)
        }

        if shouldObserveDashboardUpdates {
            let latestDashboard = await service.dashboardSnapshot()
            dashboard = latestDashboard
        } else if !windowToolsEnabled {
            dashboard = nil
        }
    }

    /// Brings this window to front to show the approval overlay
    @MainActor
    private func bringWindowToFront() {
        guard let windowState = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID }),
              let nsWindow = windowState.nsWindow
        else {
            return
        }

        // Activate the app if not active
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        // Bring window to front and make it key
        nsWindow.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private func humanReadableError(from issue: MCPServerIssue) -> String? {
        switch issue {
        case .none:
            nil
        case .localNetworkPermissionDenied:
            "Local Network permission appears to be disabled. RepoPrompt cannot advertise the MCP server."
        case let .bonjourRegistrationFailed(message):
            "The MCP listener failed to advertise via Bonjour: \(message)"
        case .listenerRestarting:
            "The MCP listener is restarting after a network error."
        case .portInUse:
            "Another process is using the MCP port. The listener is retrying on a different port."
        case let .discoveryDegraded(message):
            "Bonjour discovery is degraded: \(message)"
        case let .lastClientApprovalDenied(clientID):
            "The last MCP client (\(clientID)) was denied."
        case let .lastClientApprovalTimedOut(clientID):
            "The MCP client (\(clientID)) was auto-denied after approval timeout."
        case let .lastClientDisconnectedUnexpectedly(clientID):
            "Client \(clientID ?? "unknown") disconnected unexpectedly."
        case let .identityRecoveryDegraded(message):
            "Identity recovery failed repeatedly: \(message). Switched to filesystem-only transport."
        }
    }

    // -----------------------------------------------------------------
    // MARK: Public control API

    /// -----------------------------------------------------------------
    /// Enables tools for this window and awaits MCP readiness for agent bootstrap.
    func startServer() async {
        await ensureServerReadyForAgentBootstrap()
    }

    /// Ensures tools are enabled and the window is joined before agent bootstrap continues.
    func ensureServerReadyForAgentBootstrap() async {
        let invalidateCatalogBeforeUpdate = !windowToolsEnabled
            || !ServiceRegistry.services.contains { service in
                (service as AnyObject) === (windowToolCatalogService as AnyObject)
            }
        if !windowToolsEnabled {
            windowToolsEnabled = true
        }
        #if DEBUG || EDIT_FLOW_PERF
            let registrationUpdateAgentBootstrapState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.registrationUpdateAgentBootstrap)
        #endif
        await updateToolRegistration(invalidateCatalogBeforeUpdate: invalidateCatalogBeforeUpdate)
        #if DEBUG || EDIT_FLOW_PERF
            EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.registrationUpdateAgentBootstrap, registrationUpdateAgentBootstrapState)
        #endif
    }

    /// Disables tools for this window.
    func stopServer() async {
        windowToolsEnabled = false
    }

    /// Convenience UI toggle.
    func toggle() async {
        if windowToolsEnabled {
            windowToolsEnabled = false
        } else {
            windowToolsEnabled = true
        }
    }

    /// Force a state refresh from the service
    func refreshState() async {
        // This will trigger a new state emission which will update isRunning
        await service.refreshState()
    }

    /// Updates tool registration based on windowToolsEnabled state
    @MainActor
    private func updateToolRegistration(invalidateCatalogBeforeUpdate: Bool = true) async {
        if invalidateCatalogBeforeUpdate {
            #if DEBUG || EDIT_FLOW_PERF
                let invalidationToolRegistrationUpdateState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.invalidationToolRegistrationUpdate)
            #endif
            invalidateToolsCache()
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.invalidationToolRegistrationUpdate, invalidationToolRegistrationUpdateState)
            #endif
        }

        if windowToolsEnabled {
            ServiceRegistry.register(windowToolCatalogService) // idempotent
            do {
                try await service.join(windowID: windowID)
                await service.refreshState()
            } catch {
                logger.error("Failed to join MCP: \(error)")
            }
        } else {
            ServiceRegistry.unregister(windowToolCatalogService)
            await service.leave(windowID: windowID)
            await service.refreshState()
        }
    }

    @MainActor
    private func handleLicenseStatusChanged() {
        // RepoPrompt CE has no license gating; MCP tools remain available.
    }

    @MainActor
    private func promptForLicenseActivation() {}

    /// Hard kill (Settings > Force Stop)
    func shutdownListener() async {
        await service.fullShutdown()
    }

    /// Called by UI after the alert sheet closes
    func resolveApproval(allow: Bool, alwaysAllow: Bool = false) async {
        await service.continuePendingApproval(
            allow: allow,
            alwaysAllow: alwaysAllow
        )
    }

    // MARK: - Dashboard Methods

    private var shouldObserveDashboardUpdates: Bool {
        if windowToolsEnabled {
            return true
        }
        return !dashboardConsumers.isEmpty
    }

    @MainActor
    func setDashboardUpdatesVisible(_ visible: Bool, consumer: DashboardConsumer) {
        if visible {
            dashboardConsumers.insert(consumer)
        } else {
            dashboardConsumers.remove(consumer)
        }
        updateDashboardSubscriptionIfNeeded()
    }

    /// Start listening for dashboard updates for the status view.
    @MainActor
    func startDashboardUpdates() {
        setDashboardUpdatesVisible(true, consumer: .statusView)
    }

    /// Stop listening for dashboard updates for the status view.
    @MainActor
    func stopDashboardUpdates() {
        setDashboardUpdatesVisible(false, consumer: .statusView)
    }

    @MainActor
    private func updateDashboardSubscriptionIfNeeded() {
        if shouldObserveDashboardUpdates {
            startDashboardUpdatesIfNeeded()
        } else {
            stopDashboardUpdatesSubscription(clearSnapshot: true)
        }
    }

    @MainActor
    private func startDashboardUpdatesIfNeeded() {
        guard shouldObserveDashboardUpdates, dashboardTask == nil else { return }

        let taskID = UUID()
        dashboardTaskID = taskID
        dashboardTask = Task { [weak self] in
            guard let self else { return }

            let (subscriptionID, stream) = await service.subscribeToDashboardUpdates()
            defer {
                Task { [service = self.service, subscriptionID] in
                    await service.unsubscribeFromDashboardUpdates(id: subscriptionID)
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.dashboardSubscriptionID == subscriptionID {
                        self.dashboardSubscriptionID = nil
                    }
                    guard self.dashboardTaskID == taskID else { return }
                    self.dashboardTask = nil
                    self.dashboardTaskID = nil
                    if self.shouldObserveDashboardUpdates {
                        self.startDashboardUpdatesIfNeeded()
                    }
                }
            }

            await MainActor.run {
                guard !Task.isCancelled, self.dashboardTaskID == taskID else { return }
                self.dashboardSubscriptionID = subscriptionID
            }
            guard !Task.isCancelled else { return }
            guard await MainActor.run(body: { self.dashboardTaskID == taskID && self.shouldObserveDashboardUpdates }) else { return }

            let initialSnap = await service.dashboardSnapshot()
            await MainActor.run {
                guard self.shouldObserveDashboardUpdates else { return }
                self.dashboard = initialSnap
            }

            for await _ in stream {
                guard !Task.isCancelled else { break }
                mcpServerViewModelDebugLog("Dashboard update notification received, fetching snapshot...")
                let snap = await service.dashboardSnapshot()
                mcpServerViewModelDebugLog("Dashboard snapshot fetched with \(snap.connections.count) connection(s)")
                await MainActor.run {
                    guard self.shouldObserveDashboardUpdates else { return }
                    self.dashboard = snap
                }
            }
        }
    }

    @MainActor
    private func stopDashboardUpdatesSubscription(clearSnapshot: Bool) {
        dashboardTask?.cancel()
        dashboardTask = nil
        dashboardTaskID = nil

        if let id = dashboardSubscriptionID {
            Task { [service, id] in
                await service.unsubscribeFromDashboardUpdates(id: id)
            }
            dashboardSubscriptionID = nil
        }

        if clearSnapshot {
            dashboard = nil
        }
    }

    /// Forcefully disconnect a specific connection (legacy - calls terminateConnection)
    @MainActor
    func bootConnection(_ id: UUID) {
        terminateConnection(id, reason: .userBootFromDashboard)
    }

    /// Terminates a connection with explicit kill semantics.
    /// CLI will exit without retrying.
    @MainActor
    func terminateConnection(_ id: UUID, reason: TerminationReason, message: String? = nil) {
        mcpServerViewModelDebugLog("Terminating connection \(id) from dashboard (reason: \(reason.rawValue))")
        Task { [service] in
            await service.terminateConnection(id: id, reason: reason, message: message)
        }
    }

    /// Add or remove a client from the persistent allow-list
    @MainActor
    func setAlwaysAllowed(clientID: String, allowed: Bool) {
        Task { [service] in
            await service.setAlwaysAllowed(clientID: clientID, allowed: allowed)
        }
    }

    /// Set the global auto-approve flag
    @MainActor
    func setAutoApproveAllClients(_ enabled: Bool) {
        Task { [service] in
            await service.setAutoApproveAllClients(enabled)
        }
    }

    @MainActor
    private func invalidateToolsCache() {
        windowToolCatalogService.invalidateToolsCache()
    }

    // =====================================================================
    // MARK: TOOL capability

    // =====================================================================

    enum ContextBuilderTabPlan: Equatable {
        case explicitTab(UUID)
        case invokingTabContextOrFallback
    }

    static func planContextBuilderTab(
        explicitTabID: UUID?
    ) -> ContextBuilderTabPlan {
        if let explicitTabID {
            return .explicitTab(explicitTabID)
        }
        return .invokingTabContextOrFallback
    }

    static func resolveExplicitTabIDForAgentMode(
        rawTabID: String?,
        availableTabIDs: Set<UUID>
    ) throws -> UUID? {
        let trimmed = rawTabID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let tabID = UUID(uuidString: trimmed) else {
            throw MCPError.invalidParams("Invalid _tabID '\(trimmed)'. Expected a UUID.")
        }
        guard availableTabIDs.contains(tabID) else {
            throw MCPError.invalidParams("Tab not found for _tabID '\(tabID.uuidString)'.")
        }
        return tabID
    }

    // ────────────────────────────────────────────────────────────────
    //  MARK: - Shared wrappers for every MCP tool        🆕 NEW

    // ────────────────────────────────────────────────────────────────

    @MainActor
    private func shouldTrackActiveTool(for metadata: RequestMetadata) async -> Bool {
        guard let connectionID = metadata.connectionID else { return true }
        let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
        return purpose != .agentModeRun
    }

    private func shouldRegisterRunToolExecution(toolName: String) -> Bool {
        // The per-run idle waiter should observe tools executed *by* the active run.
        // External control-plane calls (agent_run/agent_manage) may intentionally
        // steer that same run from outside it; tracking them as run-owned tools can
        // deadlock steering behind its own MCP request. Agent-run wait ownership is
        // tracked separately by beginAgentRunWaitScope/endAgentRunWaitScope.
        let capabilities = MCPToolCapabilities.capabilities(for: toolName)
        return !capabilities.contains(.agentExternalControl)
            && !capabilities.contains(.agentExploreControl)
    }

    /// Executes `body` with a standardised life‑cycle around every tool call:
    ///   1. Flush pending file‑system deltas (optional)
    ///   2. Set `activeToolName` on the MainActor
    ///   3. Run the tool implementation
    ///   4. Clear `activeToolName`
    ///
    /// - Parameters:
    ///   - name:      Identifier of the tool (used for UI state)
    ///   - flushFS:   When `true` (default) we flush pending workspace store events before execution.
    ///   - body:      The actual implementation provided by the caller.
    /// - Returns:     Whatever `body` returns.
    /// - Throws:      Rethrows any error from `body`.
    @inline(__always)
    private func runTool<T>(
        _ name: String,
        flushFS flush: Bool = true,
        timeoutSeconds: Int = 10000, // Default ~2.7 hour timeout (matches Codex tool_timeout_sec)
        body: @escaping @Sendable () async throws -> T // ← @escaping added
    ) async throws -> T {
        if flush {
            let flushState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.preToolFilesystemFlush)
            let flushSamples = await promptVM.workspaceFileContextStore.flushPendingServiceEventsForAllRoots()
            EditFlowPerf.end(
                EditFlowPerf.Stage.MCPToolCall.preToolFilesystemFlush,
                flushState,
                EditFlowPerf.Dimensions(
                    rootCount: flushSamples.count,
                    pendingRootCount: flushSamples.count(where: { $0.pendingRawEventCountBeforeFlush > 0 }),
                    pendingRawEventCount: flushSamples.reduce(0) { $0 + $1.pendingRawEventCountBeforeFlush }
                )
            )
        }

        let runToolSetupState = EditFlowPerf.begin(
            EditFlowPerf.Stage.MCPToolCall.runToolSetup,
            EditFlowPerf.Dimensions(toolName: name)
        )

        // Eagerly attempt to bind any queued tab context for this connection
        // This ensures non-tab-scoped tools (like get_file_tree, file_search) can
        // trigger context binding, preventing "live mode" drift in parallel runs
        let metadata = await captureRequestMetadata()
        let resolvedContext = try? resolveTabContextSnapshot(
            from: metadata,
            toolName: name,
            policy: .allowLegacyImplicitRouting
        )
        if let resolvedContext, !resolvedContext.usesActiveTabCompatibility {
            let context = resolvedContext.snapshot
            mcpServerViewModelDebugLog("runTool '\(name)' bound context for tab=\(context.tabID) runID=\(context.runID?.uuidString ?? "nil")")
        }

        let shouldTrackActiveTool = await shouldTrackActiveTool(for: metadata)
        let executionRunID = await resolveRunIDForExecution(metadata: metadata, resolvedContext: resolvedContext)

        // Generate a unique token for this tool execution to prevent cleanup races
        let toolToken = UUID()
        let capturedConnectionID = metadata.connectionID
        EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.runToolSetup, runToolSetupState)

        let runToolRegistrationState = EditFlowPerf.begin(
            EditFlowPerf.Stage.MCPToolCall.runToolRegistration,
            EditFlowPerf.Dimensions(toolName: name)
        )
        if shouldTrackActiveTool {
            await MainActor.run {
                self.activeToolToken = toolToken
                self.activeToolConnectionID = capturedConnectionID
                self.activeToolName = name
                self.cancelCurrentTool = nil
            }
        }

        // 🔑 run work completely off the UI thread
        // Propagate TaskLocal connectionID so tools can resolve tab context
        let task = Task {
            try await ServerNetworkManager.withConnectionID(capturedConnectionID) {
                try await EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.providerExecution,
                    EditFlowPerf.Dimensions(toolName: name)
                ) {
                    try await body()
                }
            }
        }

        // Register in per-run tracking and store a single-slot canceller for legacy UI
        await MainActor.run {
            if shouldTrackActiveTool {
                self.cancelCurrentTool = { task.cancel() }
            }
            if shouldRegisterRunToolExecution(toolName: name),
               let connectionID = capturedConnectionID,
               let runID = executionRunID
            {
                self.registerToolExecution(
                    executionID: toolToken,
                    runID: runID,
                    connectionID: connectionID,
                    toolName: name,
                    cancel: { task.cancel() }
                )
            }
        }
        EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.runToolRegistration, runToolRegistrationState)

        do {
            // Timeout wrapper to prevent stuck tools
            let timeoutEnvelopeState = EditFlowPerf.begin(
                EditFlowPerf.Stage.MCPToolCall.runToolTimeoutEnvelope,
                EditFlowPerf.Dimensions(toolName: name)
            )
            let result: T
            do {
                result = try await withThrowingTaskGroup(of: T.self) { group in
                    group.addTask { try await task.value }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * UInt64(1_000_000_000))
                        throw MCPError.internalError("tool '\(name)' timed out after \(timeoutSeconds)s")
                    }
                    let value = try await group.next()!
                    group.cancelAll()
                    return value
                }
                EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.runToolTimeoutEnvelope, timeoutEnvelopeState)
            } catch {
                EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.runToolTimeoutEnvelope, timeoutEnvelopeState)
                throw error
            }
            // Clean up after successful completion (only if this tool execution is still current)
            let cleanupState = EditFlowPerf.begin(
                EditFlowPerf.Stage.MCPToolCall.runToolCompletionCleanup,
                EditFlowPerf.Dimensions(toolName: name)
            )
            await MainActor.run {
                self.unregisterToolExecution(executionID: toolToken)
                if shouldTrackActiveTool, self.activeToolToken == toolToken {
                    self.clearActiveToolSlot()
                }
            }
            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.runToolCompletionCleanup, cleanupState)
            return result
        } catch let err {
            task.cancel() // ensure no leak
            // Clean up after error (only if this tool execution is still current)
            let cleanupState = EditFlowPerf.begin(
                EditFlowPerf.Stage.MCPToolCall.runToolCompletionCleanup,
                EditFlowPerf.Dimensions(toolName: name)
            )
            await MainActor.run {
                self.unregisterToolExecution(executionID: toolToken)
                if shouldTrackActiveTool, self.activeToolToken == toolToken {
                    self.clearActiveToolSlot()
                }
            }
            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.runToolCompletionCleanup, cleanupState)
            if err is CancellationError {
                throw MCPError.internalError("tool cancelled by user")
            }
            throw err
        }
    }

    // -----------------------------------------------------------------
    // MARK: Window tool catalog access

    /// -----------------------------------------------------------------
    var windowMCPTools: [Tool] {
        get async {
            await windowToolCatalogService.tools
        }
    }

    @MainActor
    var windowMCPToolCatalogService: MCPWindowToolCatalogService {
        windowToolCatalogService
    }

    private func rebindOracleChatSessionIfNeeded(
        metadata: RequestMetadata,
        chatIDString: String
    ) throws {
        guard let connectionID = metadata.connectionID,
              let windowID = metadata.windowID,
              let session = oracleVM.resolveSession(id: chatIDString),
              let sessionTabID = session.composeTabID,
              let sessionWorkspaceID = session.workspaceID
        else {
            return
        }
        try rebindToTabIfNeeded(
            connectionID: connectionID,
            clientName: metadata.clientName,
            windowID: windowID,
            targetTabID: sessionTabID,
            targetWorkspaceID: sessionWorkspaceID
        )
    }

    /// Resolve the tab ID for agent mode MCP tool calls.
    /// Uses explicit _tabID arg, then MCP tab context binding, then falls back to active compose tab.
    private func resolveTabIDForAgentMode(
        args: [String: Value],
        connectionID: UUID?
    ) async throws -> UUID {
        // 1) Explicit _tabID override (hidden param), validated against real tabs.
        let explicitRaw = rawExplicitTabID(args: args)
        let workspaceTabIDs = Set(workspaceManager?.activeWorkspace?.composeTabs.map(\.id) ?? [])
        let availableTabIDs = workspaceTabIDs.isEmpty
            ? Set(promptVM.currentComposeTabs.map(\.id))
            : workspaceTabIDs
        if let explicitUUID = try Self.resolveExplicitTabIDForAgentMode(
            rawTabID: explicitRaw,
            availableTabIDs: availableTabIDs
        ) {
            return explicitUUID
        }

        // 2) Try to get tab from MCP connection context (bound tab)
        let resolvedConnectionID: UUID? = if let connectionID {
            connectionID
        } else {
            await service.currentRequestConnectionID()
        }
        if let resolvedConnectionID,
           let boundTab = boundTabID(forConnection: resolvedConnectionID),
           composeTabExists(boundTab)
        {
            return boundTab
        }

        // 3) Fallback to active compose tab in the window
        if let activeTab = promptVM.activeComposeTabID,
           composeTabExists(activeTab)
        {
            return activeTab
        }

        // 4) Create a blank tab as a last resort
        if let newTab = await promptVM.ensureActiveComposeTab(
            nil,
            creationStrategy: .blank,
            name: nil
        ) {
            return newTab.id
        }

        throw MCPError.invalidParams("No active compose tab available; open or create a tab first.")
    }

    /// Resolves an explicit `_tabID` from the args, returning nil when not provided.
    /// Unlike `resolveExistingTabIDForAgentControl`, this does NOT fall back to the
    /// connection-bound tab or active tab. This ensures run-starting operations
    /// (agent_run.start) creates a fresh session by default.
    private func resolveRequestedTabIDForAgentControl(
        args: [String: Value]
    ) throws -> UUID? {
        let workspaceTabIDs = Set(workspaceManager?.activeWorkspace?.composeTabs.map(\.id) ?? [])
        let availableTabIDs = workspaceTabIDs.isEmpty
            ? Set(promptVM.currentComposeTabs.map(\.id))
            : workspaceTabIDs
        return try Self.resolveExplicitTabIDForAgentMode(
            rawTabID: rawExplicitTabID(args: args),
            availableTabIDs: availableTabIDs
        )
    }

    private func resolveExistingTabIDForAgentControl(
        args: [String: Value],
        metadata: RequestMetadata
    ) async throws -> UUID? {
        let workspaceTabIDs = Set(workspaceManager?.activeWorkspace?.composeTabs.map(\.id) ?? [])
        let availableTabIDs = workspaceTabIDs.isEmpty
            ? Set(promptVM.currentComposeTabs.map(\.id))
            : workspaceTabIDs
        if let explicitUUID = try Self.resolveExplicitTabIDForAgentMode(
            rawTabID: rawExplicitTabID(args: args),
            availableTabIDs: availableTabIDs
        ) {
            return explicitUUID
        }
        if let connectionID = metadata.connectionID,
           let boundTabID = boundTabID(forConnection: connectionID),
           composeTabExists(boundTabID)
        {
            return boundTabID
        }
        if let activeTabID = promptVM.activeComposeTabID,
           composeTabExists(activeTabID)
        {
            return activeTabID
        }
        return nil
    }

    func bindCurrentRequestToTabIfPossible(
        tabID: UUID,
        metadata: RequestMetadata
    ) async throws {
        guard let connectionID = metadata.connectionID,
              let workspaceID = workspaceManager?.activeWorkspace?.id
        else {
            return
        }
        if await shouldPreserveAgentRunSourceBinding(connectionID: connectionID, metadata: metadata) {
            mcpServerViewModelDebugLog("bindCurrentRequestToTabIfPossible preserved agent-run source binding connectionID=\(connectionID) targetTab=\(tabID)")
            return
        }
        try bindTabForConnection(
            connectionID: connectionID,
            clientName: metadata.clientName,
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: windowID
        )
    }

    private func shouldPreserveAgentRunSourceBinding(
        connectionID: UUID,
        metadata: RequestMetadata
    ) async -> Bool {
        guard await ServerNetworkManager.shared.runPurpose(for: connectionID) == .agentModeRun else {
            return false
        }
        if let resolvedContext = try? resolveTabContextSnapshot(
            from: metadata,
            toolName: "agent_run_source_binding",
            policy: .allowLegacyImplicitRouting
        ) {
            return !resolvedContext.usesActiveTabCompatibility
        }
        return false
    }

    private func requireTargetWindow() throws -> WindowState {
        guard let targetWindow = WindowStatesManager.shared.window(withID: windowID) else {
            throw MCPError.invalidParams("No valid target window found")
        }
        return targetWindow
    }

    private func rawExplicitTabID(args: [String: Value]) -> String? {
        guard let rawValue = args["_tabID"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            return nil
        }
        return rawValue
    }

    private func rawExplicitContextID(args: [String: Value]) -> String? {
        guard let rawValue = args["context_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            return nil
        }
        return rawValue
    }

    private func parseExplicitTabID(args: [String: Value]) -> UUID? {
        guard let rawValue = rawExplicitTabID(args: args) else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }

    private func parseExplicitContextID(args: [String: Value]) -> UUID? {
        guard let rawValue = rawExplicitContextID(args: args) else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }

    private func explicitContextBuilderHint(args: [String: Value], targetWindow: WindowState) throws -> TabContextHint? {
        let rawTabID = rawExplicitTabID(args: args)
        let rawContextID = rawExplicitContextID(args: args)
        let tabID = parseExplicitTabID(args: args)
        let contextID = parseExplicitContextID(args: args)

        if let rawTabID, tabID == nil {
            throw MCPError.invalidParams("Invalid _tabID '\(rawTabID)'. Expected a UUID. Prefer context_id from bind_context op=list for tab-context routing.")
        }
        if let rawContextID, contextID == nil {
            throw MCPError.invalidParams("Invalid context_id '\(rawContextID)'. Expected a UUID from bind_context op=list.")
        }
        if let tabID, let contextID, tabID != contextID {
            throw MCPError.invalidParams("Conflicting context_builder tab hints: context_id '\(contextID.uuidString)' does not match legacy _tabID '\(tabID.uuidString)'. Pass only one, or make them match.")
        }

        guard let resolvedTabID = contextID ?? tabID else {
            return nil
        }
        return TabContextHint(tabID: resolvedTabID, workspaceID: nil, windowID: targetWindow.windowID)
    }

    private func composeTabExists(_ tabID: UUID, in targetWindow: WindowState) -> Bool {
        targetWindow.workspaceManager.composeTab(with: tabID) != nil
    }

    private func composeTabExists(_ tabID: UUID) -> Bool {
        workspaceManager?.composeTab(with: tabID) != nil
    }

    private func existingTabContextBindingAcrossWindows(for connectionID: UUID) -> ConnectionBindingSnapshot? {
        let snapshots = WindowStatesManager.shared.allWindows.map {
            $0.mcpServer.connectionBindingSnapshot(forConnection: connectionID)
        }
        if let explicit = snapshots.first(where: { $0.bindingKind == .tabContext && $0.explicitlyBound && $0.runID == nil }) {
            return explicit
        }
        if let runScoped = snapshots.first(where: { $0.bindingKind == .tabContext && $0.runID != nil }) {
            return runScoped
        }
        return snapshots.first(where: { $0.bindingKind == .tabContext })
    }

    private func resolveContextBuilderTab(
        args: [String: Value],
        targetWindow: WindowState,
        connectionID: UUID?
    ) async throws -> (tabID: UUID, workspaceID: UUID?, bindCaller: Bool) {
        let purpose: MCPRunPurpose = if let connectionID {
            await ServerNetworkManager.shared.runPurpose(for: connectionID)
        } else {
            .unknown
        }

        let explicitHint = try explicitContextBuilderHint(args: args, targetWindow: targetWindow)
        let existingBinding = connectionID.flatMap { existingTabContextBindingAcrossWindows(for: $0) }
        if let existingBinding,
           existingBinding.windowID != targetWindow.windowID
        {
            throw MCPError.invalidParams("context_builder is already bound to tab context \(existingBinding.tabID?.uuidString ?? "unknown") in window \(existingBinding.windowID.map(String.init) ?? "unknown"). Clear or intentionally rebind the connection before targeting a different window.")
        }
        if let existingBinding,
           let explicitHint,
           existingBinding.tabID != explicitHint.tabID
        {
            throw MCPError.invalidParams("Explicit tab context hint for context_builder targets tab \(explicitHint.tabID), but this connection is already bound to tab \(existingBinding.tabID?.uuidString ?? "unknown"). Clear or intentionally rebind the connection before targeting a different tab context.")
        }

        let clientName: String? = if let connectionID {
            await ServerNetworkManager.shared.clientIdentifier(forConnection: connectionID)
        } else {
            await service.currentRequestClientName()
        }

        do {
            let resolution = try targetWindow.mcpServer.resolveTabContext(
                connectionID: connectionID,
                clientName: clientName,
                providedWindowID: targetWindow.windowID,
                explicitHint: explicitHint,
                toolName: MCPWindowToolName.contextBuilder,
                policy: .requireExplicitOrRunScoped,
                runPurpose: purpose
            )
            guard case let .tabContextSnapshot(context, source) = resolution else {
                throw MCPError.invalidParams("context_builder requires a tab context snapshot.")
            }
            guard composeTabExists(context.tabID, in: targetWindow) else {
                throw MCPError.invalidParams("Tab context '\(context.tabID.uuidString)' is not available in window \(targetWindow.windowID).")
            }
            let shouldBindCaller = source == .explicitHint && purpose != .agentModeRun && connectionID != nil
            return (context.tabID, context.workspaceID, shouldBindCaller)
        } catch {
            if explicitHint != nil || existingBinding != nil {
                throw error
            }
            if purpose == .agentModeRun {
                throw MCPError.invalidParams(
                    "context_builder could not resolve the invoking agent-mode tab context. Retry after routing settles, or pass context_id explicitly."
                )
            }
        }

        // Context Builder fresh-tab fallback: non-Agent MCP calls with no explicit,
        // bound, or exact run-scoped invoking tab context get an isolated background tab.
        guard let createdTab = await targetWindow.promptManager.createBackgroundComposeTab(
            strategy: .blank,
            name: nil
        ) else {
            throw MCPError.internalError("Failed to create compose tab.")
        }
        return (createdTab.id, targetWindow.workspaceManager.activeWorkspace?.id, true)
    }

    /// Runs an async operation with periodic heartbeat emissions to prevent agent timeouts.
    private func withHeartbeat<T: Sendable>(
        connectionID: UUID?,
        tool: String,
        stage: String,
        message: String,
        interval: Duration = .seconds(30),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let connectionID else {
            return try await operation()
        }
        let shouldSendProgress = await ServerNetworkManager.shared.supportsControlNotifications(connectionID: connectionID)
        guard shouldSendProgress else {
            return try await operation()
        }

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    await ServerNetworkManager.shared.sendProgress(
                        for: connectionID,
                        tool: tool,
                        kind: .heartbeat,
                        stage: stage,
                        message: message
                    )
                }
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Sends a stage progress notification for the current connection.
    private func sendStageProgress(connectionID: UUID?, tool: String, stage: String, message: String) async {
        guard let connectionID else { return }
        await ServerNetworkManager.shared.sendProgress(
            for: connectionID,
            tool: tool,
            kind: .stage,
            stage: stage,
            message: message
        )
    }

    // ----------  Helper routines used by the above tool handlers ----------

    /// Implementation of chat_list tool - delegated to OracleViewModel
    @MainActor
    private func tool_chatList(args: [String: Value]) async throws -> [String: Value] {
        try await oracleVM.tool_chatList(args: args)
    }

    @MainActor
    func refreshSelectionMetrics() async {
        await promptVM.tokenCountingViewModel.forceImmediateRecount()
    }

    private func resolveSelectionPathsForChatSend(_ rawPaths: [String]) async -> (paths: [String], invalid: [String]) {
        let store = promptVM.workspaceFileContextStore
        var resolved: [String] = []
        var invalid: [String] = []
        var seen = Set<String>()

        for raw in rawPaths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let file = await store.lookupFiles(atPaths: [trimmed], profile: .mcpSelection, rootScope: .visibleWorkspace)[trimmed] {
                if seen.insert(file.standardizedFullPath).inserted { resolved.append(file.standardizedFullPath) }
                continue
            }
            let folderResolution = await store.expandFolderInputToFiles(trimmed, rootScope: .visibleWorkspace, profile: .mcpSelection)
            if folderResolution.handled {
                for file in folderResolution.files where seen.insert(file.standardizedFullPath).inserted {
                    resolved.append(file.standardizedFullPath)
                }
            } else {
                invalid.append(raw)
            }
        }

        return (resolved, invalid)
    }

    private func shouldAutoSelectAgentSlices() async -> Bool {
        let metadata = await captureRequestMetadata()
        guard let connectionID = metadata.connectionID else {
            return false
        }

        let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
        let resolvedContext = try? resolveTabContextSnapshot(
            from: metadata,
            toolName: "autoSelectAgentSlices",
            policy: .allowLegacyImplicitRouting
        )
        let hasTabContext = resolvedContext?.usesActiveTabCompatibility == false

        return AutoSliceSelection.shouldApply(purpose: purpose, hasVirtualContext: hasTabContext)
    }

    private func applyAutoSelectedSlices(_ entries: [AutoSliceSelection.SliceEntry]) async {
        guard !entries.isEmpty else { return }
        #if DEBUG || EDIT_FLOW_PERF
            let sliceFlowTotal = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.sliceFlowTotal)
            var sliceFlowOutcome = "error"
            defer {
                EditFlowPerf.end(
                    EditFlowPerf.Stage.ReadFile.AutoSelect.sliceFlowTotal,
                    sliceFlowTotal,
                    EditFlowPerf.Dimensions(outcome: sliceFlowOutcome)
                )
            }
        #endif
        let sliceInputs = entries.map { entry in
            WorkspaceSelectionSliceInput(path: entry.path, ranges: entry.ranges)
        }

        do {
            _ = try await applySelectionSlices(entries: sliceInputs, mode: .add)
            #if DEBUG || EDIT_FLOW_PERF
                sliceFlowOutcome = "attempted"
            #endif
        } catch {
            mcpServerViewModelDebugLog("Auto slice selection skipped due to slice apply error: \(error.localizedDescription)")
        }
    }

    private func applyAutoSelectedFullFiles(_ paths: [String]) async {
        let normalizedPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedPaths.isEmpty else { return }
        #if DEBUG || EDIT_FLOW_PERF
            let fullFlowTotal = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.fullFlowTotal)
            var fullFlowOutcome = "error"
            defer {
                EditFlowPerf.end(
                    EditFlowPerf.Stage.ReadFile.AutoSelect.fullFlowTotal,
                    fullFlowTotal,
                    EditFlowPerf.Dimensions(outcome: fullFlowOutcome)
                )
            }
        #endif

        do {
            let metadata = await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.AutoSelect.fullRequestMetadata) {
                await captureRequestMetadata()
            }
            let lookupContext = await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.AutoSelect.fullLookupContext) {
                await resolveFileToolLookupContext(from: metadata)
            }
            let lookupRootScope = lookupContext.rootScope
            var resolvedContext = try EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.AutoSelect.fullSnapshotResolution) {
                try resolveTabContextSnapshot(
                    from: metadata,
                    toolName: "autoSelectReadFile",
                    policy: .allowLegacyImplicitRouting
                )
            }
            let ctx = resolvedContext.snapshot
            let addResult = await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.AutoSelect.structuralAddTotal) {
                await addStoredSelectionPaths(
                    existing: ctx.selection,
                    paths: normalizedPaths,
                    rawPaths: normalizedPaths,
                    mode: "full",
                    lookupRootScope: lookupRootScope
                )
            }
            let sliceRemovalInputs = normalizedPaths.map {
                WorkspaceSelectionSliceInput(path: $0, ranges: [])
            }
            let clearedSelection: StoredSelection = await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.AutoSelect.fullSliceClearing) {
                if sliceRemovalInputs.isEmpty {
                    addResult.selection
                } else {
                    await computeSelectionSlicesVirtual(
                        base: addResult.selection,
                        entries: sliceRemovalInputs,
                        mode: .remove,
                        lookupRootScope: lookupRootScope
                    ).selection
                }
            }
            let finalSelectionEquality = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.finalSelectionEquality)
            let shouldPersist = clearedSelection != ctx.selection
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.AutoSelect.finalSelectionEquality,
                finalSelectionEquality,
                EditFlowPerf.Dimensions(outcome: shouldPersist ? "changed" : "unchanged")
            )
            guard shouldPersist else {
                #if DEBUG || EDIT_FLOW_PERF
                    EditFlowPerf.measure(
                        EditFlowPerf.Stage.ReadFile.AutoSelect.persistence,
                        EditFlowPerf.Dimensions(outcome: "skipped")
                    ) {}
                    fullFlowOutcome = "unchanged"
                #endif
                return
            }
            resolvedContext.snapshot.selection = clearedSelection
            await EditFlowPerf.measure(
                EditFlowPerf.Stage.ReadFile.AutoSelect.persistence,
                EditFlowPerf.Dimensions(outcome: "attempted")
            ) {
                await persistResolvedTabContextSnapshot(resolvedContext, metadata: metadata, mutated: true)
            }
            #if DEBUG || EDIT_FLOW_PERF
                fullFlowOutcome = "changed"
            #endif
        } catch {
            mcpServerViewModelDebugLog("Auto full-file selection skipped due to selection apply error: \(error.localizedDescription)")
        }
    }

    private func maybeAutoSelectReadFileSelection(
        reply: ToolResultDTOs.ReadFileReply,
        requestedPath: String
    ) async {
        #if DEBUG || EDIT_FLOW_PERF
            let autoSelectTotal = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.total)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.total, autoSelectTotal) }
        #endif
        let eligibilityResolution = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.eligibilityResolution)
        let shouldApply = await shouldAutoSelectAgentSlices()
        EditFlowPerf.end(
            EditFlowPerf.Stage.ReadFile.AutoSelect.eligibilityResolution,
            eligibilityResolution,
            EditFlowPerf.Dimensions(outcome: shouldApply ? "eligible" : "ineligible")
        )
        guard shouldApply else { return }
        let selectionProjection = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.selectionProjection)
        guard let baseSelection = AutoSliceSelection.readFileSelection(from: reply, fallbackPath: requestedPath) else {
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.AutoSelect.selectionProjection,
                selectionProjection,
                EditFlowPerf.Dimensions(outcome: "missing")
            )
            return
        }
        let selection: AutoSliceSelection.ReadFileSelection
        switch baseSelection {
        case .full:
            selection = baseSelection
        case .slice:
            let existingFullPaths = await autoSelectedFullFilePaths()
            selection = AutoSliceSelection.preserveExistingFullFileSelection(
                baseSelection,
                existingFullPaths: existingFullPaths
            )
        }
        EditFlowPerf.end(
            EditFlowPerf.Stage.ReadFile.AutoSelect.selectionProjection,
            selectionProjection,
            EditFlowPerf.Dimensions(outcome: {
                switch selection {
                case .full: "full"
                case .slice: "slice"
                }
            }())
        )
        switch selection {
        case let .full(path):
            await applyAutoSelectedFullFiles([path])
        case let .slice(entry):
            await applyAutoSelectedSlices([entry])
        }
    }

    private func autoSelectedFullFilePaths() async -> [String] {
        let metadata = await captureRequestMetadata()
        let lookupRootScope = await resolveFileToolLookupContext(from: metadata).rootScope
        guard let resolvedContext = try? resolveTabContextSnapshot(
            from: metadata,
            toolName: "autoSelectedFullFilePaths",
            policy: .allowLegacyImplicitRouting
        ) else { return [] }
        let selection = resolvedContext.snapshot.selection
        let selectedPaths = StoredSelectionPathNormalization.standardizedPaths(selection.selectedPaths)
        let slicedPaths = Set(StoredSelectionPathNormalization.standardizedSlices(selection.slices).keys)
        let resolved = await selectionFindFiles(atPaths: selectedPaths, lookupRootScope: lookupRootScope)
        var fullPaths: [String] = []
        for path in selectedPaths {
            guard !slicedPaths.contains(path), let file = resolved[path] else { continue }
            await fullPaths.append(prefixedRelativePath(for: file))
        }
        return fullPaths
    }

    private func maybeAutoSelectFileSearchSlices(
        mode: SearchMode,
        contextLines: Int,
        reply: ToolResultDTOs.SearchResultDTO
    ) async {
        guard await shouldAutoSelectAgentSlices() else { return }
        guard AutoSliceSelection.shouldSliceFileSearch(mode: mode, contextLines: contextLines) else { return }
        guard !reply.contentMatchGroups.isEmpty else { return }
        let entries = AutoSliceSelection.searchEntries(from: reply.contentMatchGroups)
        await applyAutoSelectedSlices(entries)
    }

    private func applySelectionSlices(
        entries: [WorkspaceSelectionSliceInput],
        mode: SliceMutationMode
    ) async throws -> MCPSelectionSlicesMutationResult {
        do {
            let metadata = await captureRequestMetadata()
            let lookupContext = await resolveFileToolLookupContext(from: metadata)
            let lookupRootScope = lookupContext.rootScope
            let resolvedContext = try resolveTabContextSnapshot(
                from: metadata,
                toolName: "applySelectionSlices",
                policy: .allowLegacyImplicitRouting
            )
            return try await applySelectionSlicesVirtual(
                resolvedContext: resolvedContext,
                metadata: metadata,
                entries: entries,
                mode: mode,
                lookupRootScope: lookupRootScope
            )
        } catch let sliceError as MCPSelectionSliceError {
            switch sliceError {
            case .workspaceUnavailable:
                throw MCPError.internalError(sliceError.localizedDescription)
            case .noWorkspaceLoaded:
                throw MCPError.invalidParams(sliceError.localizedDescription)
            }
        } catch let mcpError as MCPError {
            throw mcpError
        } catch {
            throw MCPError.internalError("Failed to update selection slices: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func computeSelectionSlicesVirtual(
        base: StoredSelection,
        entries: [WorkspaceSelectionSliceInput],
        mode: SliceMutationMode,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> (selection: StoredSelection, result: MCPSelectionSlicesMutationResult, mutated: Bool) {
        await mutateStoredSelectionSlices(
            base: base,
            entries: entries,
            mode: mode,
            lookupRootScope: lookupRootScope
        )
    }

    private func applySelectionSlicesVirtual(
        resolvedContext: ResolvedTabContextSnapshot,
        metadata: RequestMetadata,
        entries: [WorkspaceSelectionSliceInput],
        mode: SliceMutationMode,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async throws -> MCPSelectionSlicesMutationResult {
        var resolvedContext = resolvedContext
        let computed = await computeSelectionSlicesVirtual(
            base: resolvedContext.snapshot.selection,
            entries: entries,
            mode: mode,
            lookupRootScope: lookupRootScope
        )
        if computed.mutated {
            resolvedContext.snapshot.selection = computed.selection
            await persistResolvedTabContextSnapshot(resolvedContext, metadata: metadata, mutated: true)
        }
        return computed.result
    }

    /// Root-aware path helpers (useful for multi-root disambiguation)
    func prefixedRelativePath(for file: WorkspaceFileRecord) async -> String {
        let roots = await promptVM.workspaceFileContextStore.rootRefs(scope: .allLoaded)
        guard let root = roots.first(where: { $0.id == file.rootID }) else { return file.standardizedFullPath }
        return ClientPathFormatter.displayPath(root: root, relativePath: file.standardizedRelativePath, visibleRoots: roots)
    }

    nonisolated static func prefixedRelativePath(forPath path: String, rootRefs: [WorkspaceRootRef]) -> String {
        ClientPathFormatter.displayAbsolutePath(fullPath: path, visibleRoots: rootRefs)
    }

    nonisolated static func mcpDisplayPath(
        forPath path: String,
        visibleRoots: [WorkspaceRootRef],
        allRoots: [WorkspaceRootRef]
    ) -> String {
        let visible = ClientPathFormatter.displayAbsolutePath(fullPath: path, visibleRoots: visibleRoots)
        if visible != StandardizedPath.absolute(path) { return visible }
        return ClientPathFormatter.displayAbsolutePath(fullPath: path, visibleRoots: allRoots)
    }

    nonisolated static func makeCachedMCPDisplayPathResolver(
        visibleRoots: [WorkspaceRootRef],
        allRoots: [WorkspaceRootRef]
    ) -> (String) -> String {
        var cache: [String: String] = [:]
        return { rawPath in
            // Search results already carry full paths, so the raw full path is a
            // root-safe cache identity without adding an extra standardization pass.
            if let cached = cache[rawPath] {
                return cached
            }
            let result = mcpDisplayPath(forPath: rawPath, visibleRoots: visibleRoots, allRoots: allRoots)
            cache[rawPath] = result
            return result
        }
    }

    /// Builds a helpful error message for selection failures, including loaded roots and path hints.
    private func makeSelectionHintError(
        paths: [String],
        operation: String,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> String {
        let trimmed = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let roots = await promptVM.workspaceFileContextStore.rootRefs(scope: lookupRootScope)
        if roots.isEmpty {
            return "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
        }

        let rootSummaries = roots.map { "\($0.name) → \($0.fullPath)" }.joined(separator: "; ")

        var outside: [String] = []
        for p in trimmed where p.hasPrefix("/") {
            let standardized = StandardizedPath.absolute(p)
            let under = roots.contains { StandardizedPath.isDescendant(standardized, of: $0.standardizedFullPath) || standardized == $0.standardizedFullPath }
            if !under { outside.append(p) }
        }

        var lines: [String] = []
        lines.append("No provided paths matched any files or folders for '\(operation)'.")
        lines.append("Loaded roots: \(rootSummaries)")
        lines.append("Provide either: (a) Root-name + relative path (e.g., 'Root/Sub/Path.swift'), or (b) a full absolute path under a loaded root.")
        if !outside.isEmpty {
            let sample = outside.prefix(2).joined(separator: ", ")
            lines.append("Not under any loaded root: \(sample)")
        }
        return lines.joined(separator: " ")
    }

    private func resolveFilesForCodeStructure(
        paths: [String],
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> [WorkspaceFileRecord] {
        let directFiles = await promptVM.workspaceFileContextStore.lookupFiles(
            atPaths: paths,
            profile: .mcpRead,
            rootScope: lookupRootScope
        )
        let matchedFileInputs = Set(directFiles.keys)
        var resolved: [WorkspaceFileRecord] = []
        var seenPaths = Set<String>()

        for path in paths {
            if let file = directFiles[path], seenPaths.insert(file.standardizedFullPath).inserted {
                resolved.append(file)
            }
        }

        let dirCandidates = paths.filter { !matchedFileInputs.contains($0) }
        for raw in dirCandidates {
            let folderResolution = await promptVM.workspaceFileContextStore.expandFolderInputToFiles(raw, rootScope: lookupRootScope, profile: .mcpSelection)
            guard folderResolution.handled else { continue }
            for file in folderResolution.files where seenPaths.insert(file.standardizedFullPath).inserted {
                resolved.append(file)
            }
        }

        return resolved
    }

    func buildCodeStructureDTO(
        fromRecords files: [WorkspaceFileRecord],
        maxResults: Int,
        includeUnmappedPaths: Bool,
        projection: WorkspaceRootBindingProjection? = nil
    ) async -> ToolResultDTOs.SelectedCodeStructureDTO {
        struct RenderableCodeStructure {
            let key: String
            let displayPath: String
            let api: FileAPI
            let estimatedTokens: Int
        }

        let store = promptVM.workspaceFileContextStore
        let snapshots = await store.codemapSnapshotDictionary()
        let roots = await store.rootRefs(scope: .allLoaded)
        var renderable: [RenderableCodeStructure] = []
        var unmappedPaths: [String] = []
        var seenPaths = Set<String>()

        for file in files {
            let fullPath = file.standardizedFullPath
            guard seenPaths.insert(fullPath).inserted else { continue }
            let displayPath: String = if let projection,
                                         let projected = projection.projectedLogicalDisplayPath(forPhysicalPath: fullPath, display: .relative)
            {
                projected
            } else if let root = roots.first(where: { $0.id == file.rootID }) {
                ClientPathFormatter.displayPath(root: root, relativePath: file.standardizedRelativePath, visibleRoots: roots)
            } else {
                file.relativePath
            }
            if let api = snapshots[file.id]?.fileAPI {
                renderable.append(
                    RenderableCodeStructure(
                        key: fullPath,
                        displayPath: displayPath,
                        api: api,
                        estimatedTokens: api.estimatedFullAPIDescriptionTokens(displayPath: displayPath)
                    )
                )
            } else if includeUnmappedPaths {
                unmappedPaths.append(displayPath)
            }
        }

        renderable.sort { lhs, rhs in
            if lhs.displayPath == rhs.displayPath { return lhs.key < rhs.key }
            return lhs.displayPath < rhs.displayPath
        }

        let budgetSelection = Self.applyCodeStructureOutputBudget(
            renderable.map { CodeStructureBudgetCandidate(key: $0.key, estimatedTokens: $0.estimatedTokens) },
            maxResults: maxResults,
            tokenBudget: Self.codeStructureTokenBudget,
            separatorTokens: Self.codeStructureSeparatorTokenCost
        )
        let renderableByKey = Dictionary(uniqueKeysWithValues: renderable.map { ($0.key, $0) })
        let content = budgetSelection.includedKeys
            .compactMap { renderableByKey[$0] }
            .map { $0.api.getFullAPIDescription(displayPath: $0.displayPath) }
            .joined(separator: "\n\n")
        let sortedUnmapped = includeUnmappedPaths && !unmappedPaths.isEmpty ? unmappedPaths.sorted() : nil
        return ToolResultDTOs.SelectedCodeStructureDTO(
            fileCount: budgetSelection.includedKeys.count,
            content: content,
            unmappedPaths: sortedUnmapped,
            omittedCount: budgetSelection.omittedByMaxResults > 0 ? budgetSelection.omittedByMaxResults : nil,
            omittedTotal: budgetSelection.omittedTotal > 0 ? budgetSelection.omittedTotal : nil,
            tokenBudgetOmittedCount: budgetSelection.omittedByTokenBudget > 0 ? budgetSelection.omittedByTokenBudget : nil,
            tokenBudgetHit: budgetSelection.omittedByTokenBudget > 0 ? true : nil
        )
    }

    /// Collect codemaps with a hard cap; also report how many were omitted.
    private func getCodeMaps(
        for paths: [String],
        maxResults: Int = 25,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> (maps: [String: FileAPI], omitted: Int) {
        let store = promptVM.workspaceFileContextStore
        let snapshots = await store.codemapSnapshotDictionary()
        let directFiles = await store.lookupFiles(atPaths: paths, profile: .mcpRead, rootScope: lookupRootScope)
        var results: [String: FileAPI] = [:]
        var seenFileIDs = Set<UUID>()
        var collected = 0
        let cap = max(0, maxResults)
        var omitted = 0

        func consider(_ file: WorkspaceFileRecord) {
            guard seenFileIDs.insert(file.id).inserted, let api = snapshots[file.id]?.fileAPI else { return }
            if collected < cap {
                results[file.standardizedFullPath] = api
                collected += 1
            } else {
                omitted += 1
            }
        }

        for path in paths {
            if let file = directFiles[path] { consider(file) }
        }
        guard collected < cap else { return (results, omitted) }

        let matchedFileInputs = Set(directFiles.keys)
        for raw in paths where !matchedFileInputs.contains(raw) {
            let folderResolution = await promptVM.workspaceFileContextStore.expandFolderInputToFiles(raw, rootScope: lookupRootScope, profile: .mcpSelection)
            guard folderResolution.handled else { continue }
            for file in folderResolution.files {
                consider(file)
            }
        }

        return (results, omitted)
    }

    /// Reads a file with optional slicing. Supports 1-based indices and a negative sentinel
    /// for bottom-origin reads (start_line = -N reads the last N lines).
    /// Returns both the content slice and metadata about the shown range.
    private func readFile(
        path: String,
        startLine1Based: Int? = nil,
        lineCount: Int? = nil,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async throws -> (reply: ToolResultDTOs.ReadFileReply, shouldAutoSelect: Bool) {
        let store = promptVM.workspaceFileContextStore
        let readableService = WorkspaceReadableFileService(store: store)
        let (roots, readableFile): ([WorkspaceRootRef], WorkspaceReadableFileHandle?) = try await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.resolveReadableFile) {
            let exactPathIssueDetection = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.exactPathIssueDetection)
            let exactPathIssue = await store.exactPathResolutionIssue(for: path, kind: .either, rootScope: lookupRootScope)
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.exactPathIssueDetection,
                exactPathIssueDetection,
                EditFlowPerf.Dimensions(outcome: exactPathIssue == nil ? "noIssue" : "issue")
            )
            if let issue = exactPathIssue {
                throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
            }

            let rootRefsLookup = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.rootRefsLookup)
            let roots = await store.rootRefs(scope: lookupRootScope)
            EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.rootRefsLookup, rootRefsLookup)

            if let exactAbsoluteCatalogHit = await readableService.resolveExactAbsoluteWorkspaceCatalogHit(path, rootScope: lookupRootScope) {
                return (roots, WorkspaceReadableFileHandle.workspace(exactAbsoluteCatalogHit))
            }

            let folderResolutionStage = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.folderResolution)
            let folderResolution = await store.resolveFolderInput(path, rootScope: lookupRootScope, profile: .mcpRead)
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.folderResolution,
                folderResolutionStage,
                EditFlowPerf.Dimensions(outcome: folderResolution.folder == nil ? "noFolder" : "folder")
            )
            if let folder = folderResolution.folder {
                let displayPath = folderResolution.displayPath ?? ClientPathFormatter.displayAbsolutePath(fullPath: folder.standardizedFullPath, visibleRoots: roots)
                throw MCPError.invalidParams("'\(displayPath)' is a folder; read_file requires a file path. Use get_file_tree or file_search to find specific files.")
            }

            let externalFolderGuard = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.externalFolderGuard)
            let externalFolderPath = readableService.resolveAlwaysReadableExternalFolderDisplayPath(path)
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.externalFolderGuard,
                externalFolderGuard,
                EditFlowPerf.Dimensions(outcome: externalFolderPath == nil ? "noFolder" : "folder")
            )
            if let externalFolderPath {
                throw MCPError.invalidParams("'\(externalFolderPath)' is a folder; read_file requires a file path. Use get_file_tree or file_search to find specific files.")
            }

            let readableServiceResolution = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.readableServiceResolution)
            let readableFile = await readableService.resolveReadableFile(path, profile: .mcpRead, rootScope: lookupRootScope)
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.readableServiceResolution,
                readableServiceResolution,
                EditFlowPerf.Dimensions(outcome: {
                    switch readableFile {
                    case .some(.workspace):
                        "workspace"
                    case .some(.external):
                        "external"
                    case .none:
                        "noCandidate"
                    }
                }())
            )
            return (roots, readableFile)
        }
        let full: String
        let displayPath: String
        let shouldAutoSelect: Bool
        switch readableFile {
        case let .workspace(file):
            guard let workspaceContent = try await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.workspaceContentLoad, operation: {
                try await store.readContent(rootID: file.rootID, relativePath: file.standardizedRelativePath)
            }) else {
                throw MCPError.internalError("content unavailable")
            }
            full = workspaceContent
            displayPath = ClientPathFormatter.displayAbsolutePath(fullPath: file.standardizedFullPath, visibleRoots: roots)
            shouldAutoSelect = true
        case let .external(externalFile):
            do {
                full = try await readableService.readAlwaysReadableExternalFile(externalFile)
            } catch {
                throw MCPError.invalidParams("Cannot read '\(externalFile.displayPath)': \(error.localizedDescription)")
            }
            displayPath = externalFile.displayPath
            shouldAutoSelect = false
        case nil:
            if readableService.isAlwaysReadableExternalPath(path) {
                throw MCPError.invalidParams("File not found: '\(readableService.displayPath(forExternalPath: path))'.")
            }
            let msg = await workspaceContextMessage(forOperation: "read file", path: path)
            throw MCPError.invalidParams("Cannot read '\(path)'. \(msg)")
        }

        // Preserve original line endings and total line count
        let pairs = EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.splitPreservingLineEndings) {
            String.splitContentPreservingAllLineEndings(full)
        }
        let total = pairs.count

        // Validate parameter combinations
        if let s1 = startLine1Based {
            // Check for invalid parameter combinations
            if s1 < 0, lineCount != nil {
                throw MCPError.invalidParams("limit parameter is not allowed with negative start_line. Use start_line=-N to read the last N lines.")
            }
            if s1 == 0 {
                throw MCPError.invalidParams("start_line must be positive (1-based) or negative (tail-like behavior)")
            }
        }

        // Determine slice range
        let (first, lastExclusive): (Int, Int) = {
            // Handle negative start_line (tail-like behavior)
            if let s1 = startLine1Based, s1 < 0 {
                // Negative start_line means "last N lines" (like tail -n)
                let linesToRead = abs(s1)
                let start = max(0, total - linesToRead)
                return (start, total)
            }

            // Handle positive 1-based start line (default to 1 if only limit provided)
            let s1 = startLine1Based ?? 1
            let start0 = max(0, s1 - 1)
            let end = (lineCount != nil && lineCount! >= 0)
                ? min(total, start0 + lineCount!)
                : total
            return (start0, end)
        }()

        // If start is beyond file end, return empty content with a helpful message
        if !(first < total || total == 0) {
            return (
                ToolResultDTOs.ReadFileReply(
                    content: "",
                    totalLines: total,
                    firstLine: max(1, first + 1),
                    lastLine: total,
                    message: "Requested start_line exceeds file length.",
                    displayPath: displayPath
                ),
                shouldAutoSelect
            )
        }

        let contentSlice = EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.buildSlice) {
            if total == 0 { return "" }
            let slice = pairs[first ..< lastExclusive]
            return slice.map { $0.line + $0.ending }.joined()
        }

        // Prepare metadata for the displayed slice
        let shownFirst = total == 0 ? 0 : (first + 1)
        let shownLast = total == 0 ? 0 : lastExclusive

        return (
            ToolResultDTOs.ReadFileReply(
                content: contentSlice,
                totalLines: total,
                firstLine: shownFirst,
                lastLine: shownLast,
                message: nil,
                displayPath: displayPath
            ),
            shouldAutoSelect
        )
    }

    /// Performs a file action (create, delete, or move/rename)
    private func performFileAction(
        action: String,
        path: String,
        content: String? = nil,
        newPath: String? = nil,
        ifExists: String? = nil
    ) async throws {
        // Enforce workspace presence in multi-window mode
        try await requireWorkspaceForTool(MCPWindowToolName.fileActions)
        let metadata = await captureRequestMetadata()
        var resolvedContext = try resolveTabContextSnapshot(
            from: metadata,
            toolName: MCPWindowToolName.fileActions,
            policy: .allowLegacyImplicitRouting
        )
        let lookupContext = await resolveFileToolLookupContext(from: metadata)
        let effectivePath = lookupContext.translateInputPath(path)
        let effectiveNewPath = newPath.map { lookupContext.translateInputPath($0) }
        let shouldSelectCreatedFileInActiveUI = resolvedContext.usesActiveTabCompatibility

        do {
            switch action.lowercased() {
            case "create":
                guard let content else {
                    throw MCPError.invalidParams("content is required for create action")
                }
                let policy = (ifExists ?? "error").lowercased()
                try await writeFile(
                    path: effectivePath,
                    content: content,
                    overwrite: policy == "overwrite",
                    addToSelection: shouldSelectCreatedFileInActiveUI,
                    lookupRootScope: lookupContext.rootScope
                )

            case "delete":
                // Validate that the path is absolute for safety. Destructive delete intentionally
                // does not accept relative/display aliases even when other MCP tools can read them.
                guard effectivePath.hasPrefix("/") else {
                    throw MCPError.invalidParams("delete requires an absolute path. Received: \(path)")
                }
                try await moveItemToTrash(path: effectivePath, lookupRootScope: lookupContext.rootScope)

            case "move", "rename":
                guard let newPath else {
                    throw MCPError.invalidParams("new_path is required for move/rename action")
                }
                try await renameFile(oldPath: effectivePath, newPath: effectiveNewPath ?? newPath, lookupRootScope: lookupContext.rootScope)

            default:
                throw MCPError.invalidParams("invalid action: \(action). Must be 'create', 'delete', or 'move'")
            }
        } catch let fmErr as FileManagerError {
            // Convert internal file-manager errors to friendly, contextual MCP errors
            throw await mapFileManagerErrorToMCP(fmErr, action: action, path: path)
        } catch let mcpErr as MCPError {
            throw mcpErr
        } catch {
            // Generic fallback
            throw MCPError.invalidParams("File action '\(action)' failed: \(error.localizedDescription)")
        }

        // Ensure any resulting file system deltas are flushed and applied
        _ = await promptVM.workspaceFileContextStore.flushPendingServiceEventsForAllRoots()
        if action.lowercased() == "create", !resolvedContext.usesActiveTabCompatibility {
            let addResult = await addStoredSelectionPaths(
                existing: resolvedContext.snapshot.selection,
                paths: [effectivePath],
                rawPaths: [path],
                mode: "full",
                lookupRootScope: lookupContext.rootScope
            )
            guard addResult.selection != resolvedContext.snapshot.selection else { return }
            resolvedContext.snapshot.selection = addResult.selection
            await persistResolvedTabContextSnapshot(resolvedContext, metadata: metadata, mutated: true)
        }
    }

    /// Creates a **new** file, with optional overwrite behavior.
    /// - Parameter overwrite: when true and a file already exists, its content will be replaced.
    private func writeFile(
        path: String,
        content: String,
        overwrite: Bool = false,
        addToSelection: Bool = true,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async throws {
        do {
            let store = promptVM.workspaceFileContextStore
            let host = WorkspaceFileEditHost(
                store: store,
                selectionCoordinator: selectionCoordinator,
                lookupRootScope: lookupRootScope,
                createPathResolutionPolicy: .literalPreferredIfStronger,
                selectCreatedFiles: addToSelection
            )
            try await host.writeText(path: path, content: content, overwrite: overwrite)
        } catch let fmErr as FileManagerError {
            throw await mapFileManagerErrorToMCP(fmErr, action: "create", path: path)
        } catch let mcpErr as MCPError {
            throw mcpErr
        } catch {
            throw MCPError.invalidParams("File creation failed for '\(path)': \(error.localizedDescription)")
        }
    }

    private func exportOracleResponse(_ request: OracleExportRequest) async throws -> OracleExportFile {
        guard let destination = request.destination else {
            throw MCPError.internalError("Missing Oracle export destination metadata for generated export.")
        }
        let path = try resolvedDefaultOracleExportPath(
            mode: request.mode,
            chatID: request.chatID,
            destination: destination
        )
        let markdown = AgentOracleExport.oracleMarkdown(request: request)
        let resolvedPath = try await writeGeneratedOracleExportFile(
            path: path,
            content: markdown,
            destination: destination
        )
        return OracleExportFile(
            path: resolvedPath,
            instruction: AgentOracleExport.instruction(path: resolvedPath)
        )
    }

    private func defaultOracleExportPath(mode: String, chatID: String?) -> String {
        let timestamp = Self.oracleExportTimestampFormatter.string(from: Date())
        let normalizedMode = slugForOracleExport(mode, fallback: "response")
        let chatSlug = slugForOracleExport(chatID ?? "", fallback: "chat")
        let nonce = UUID().uuidString.prefix(4).lowercased()
        return "prompt-exports/oracle-\(normalizedMode)-\(timestamp)-\(chatSlug)-\(nonce).md"
    }

    private func resolvedDefaultOracleExportPath(
        mode: String,
        chatID: String?,
        destination: OracleExportDestination
    ) throws -> String {
        let relativePath = defaultOracleExportPath(mode: mode, chatID: chatID)
        return try Self.resolveGeneratedOracleExportPath(
            relativePath: relativePath,
            destination: destination
        )
    }

    static func makeOracleExportDestination(
        workspace: WorkspaceModel?,
        windowID: Int,
        tabID: UUID?
    ) throws -> OracleExportDestination {
        guard let workspace else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: no active workspace is available.")
        }
        guard let rawPrimaryRoot = workspace.repoPaths.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPrimaryRoot.isEmpty
        else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: active workspace has no primary root (workspace.repoPaths.first is missing).")
        }
        let expandedRoot = (rawPrimaryRoot as NSString).expandingTildeInPath
        guard expandedRoot.hasPrefix("/") else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: workspace primary root must be an absolute path, got '\(rawPrimaryRoot)'.")
        }
        let standardizedRoot = (expandedRoot as NSString).standardizingPath
        try validateOracleExportPrimaryRoot(standardizedRoot)

        return OracleExportDestination(
            workspaceID: workspace.id,
            windowID: windowID,
            tabID: tabID,
            primaryRootPath: standardizedRoot
        )
    }

    static func resolveGeneratedOracleExportPath(
        relativePath rawRelativePath: String,
        destination: OracleExportDestination
    ) throws -> String {
        try validateOracleExportPrimaryRoot(destination.primaryRootPath)

        let trimmed = rawRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: export path is empty.")
        }
        guard !trimmed.hasPrefix("/") else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: generated export path must be relative, got '\(trimmed)'.")
        }

        let rootPath = (destination.primaryRootPath as NSString).standardizingPath
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let resolvedPath = rootURL.appendingPathComponent(trimmed).standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolvedPath.hasPrefix(rootPrefix) else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: generated path escapes the workspace primary root.")
        }
        return resolvedPath
    }

    private static func validateOracleExportPrimaryRoot(_ rawRootPath: String) throws {
        let rootPath = (rawRootPath as NSString).standardizingPath
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: workspace primary root is unavailable: \(rootPath).")
        }
    }

    private func slugForOracleExport(_ raw: String, fallback: String) -> String {
        let maxLength = 20
        let lower = raw.lowercased()
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(min(lower.unicodeScalars.count, maxLength))
        var lastWasSeparator = false

        for scalar in lower.unicodeScalars {
            let isASCIIAlphanumeric = (48 ... 57).contains(Int(scalar.value))
                || (97 ... 122).contains(Int(scalar.value))
            if isASCIIAlphanumeric {
                if scalars.count >= maxLength { break }
                scalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator, !scalars.isEmpty {
                if scalars.count >= maxLength { break }
                scalars.append("-")
                lastWasSeparator = true
            }
        }

        var slug = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty {
            slug = fallback
        }
        return slug
    }

    private static let oracleExportTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private func writeGeneratedOracleExportFile(
        path rawPath: String,
        content: String,
        destination: OracleExportDestination
    ) async throws -> String {
        try await GeneratedOracleExportFileWriter(store: promptVM.workspaceFileContextStore).write(
            path: rawPath,
            content: content,
            destination: destination
        )
    }

    /// Writes prompt export content, allowing absolute paths outside the workspace.
    private func writePromptExportFile(path rawPath: String, content: String) async throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedPath = (trimmed as NSString).expandingTildeInPath
        let standardizedPath = (expandedPath as NSString).standardizingPath
        let resolvedPath = expandedPath.hasPrefix("/") ? standardizedPath : trimmed

        // Relative paths should continue to be resolved inside the workspace.
        guard resolvedPath.hasPrefix("/") else {
            try await writeFile(path: resolvedPath, content: content, overwrite: false, addToSelection: false)
            return resolvedPath
        }

        let roots = await promptVM.workspaceFileContextStore.rootRefs(scope: .allLoaded)
        let isUnderRoot = roots.contains { root in
            resolvedPath == root.standardizedFullPath || StandardizedPath.isDescendant(resolvedPath, of: root.standardizedFullPath)
        }

        if isUnderRoot {
            try await writeFile(path: resolvedPath, content: content, overwrite: false, addToSelection: false)
            return resolvedPath
        }

        let url = URL(fileURLWithPath: resolvedPath)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            throw MCPError.invalidParams("path already exists: \(resolvedPath).")
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw MCPError.invalidParams("File creation failed for '\(resolvedPath)': \(error.localizedDescription)")
        }

        return resolvedPath
    }

    private func renameFile(oldPath: String, newPath: String, lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace) async throws {
        let store = promptVM.workspaceFileContextStore
        let mutationService = WorkspaceFileMutationService(store: store)
        let source = try await mutationService.resolveExactExistingFileForMutation(oldPath, rootScope: lookupRootScope)
        guard let sourceRoot = await store.rootRefs(scope: .allLoaded).first(where: { $0.id == source.rootID }) else {
            throw MCPError.invalidParams("Cannot resolve source root for '\(oldPath)'.")
        }
        let visibleRoots = await store.rootRefs(scope: lookupRootScope)
        let newRelativePath: String
        do {
            newRelativePath = try MovePathResolver.resolveRelativePathInRoot(
                userPath: newPath,
                sourceRoot: sourceRoot,
                visibleRoots: visibleRoots
            )
        } catch let error as MovePathResolver.Error {
            switch error {
            case .emptyDestination:
                throw MCPError.invalidParams("new_path cannot be empty")
            case let .destinationOutsideRoot(root):
                throw MCPError.invalidParams("new_path must stay inside source root '\(root.name)'.")
            case let .ambiguousAlias(alias, roots):
                let rendered = roots.map(\.renderedLabel).joined(separator: "; ")
                throw MCPError.invalidParams("Ambiguous root alias '\(alias)': \(rendered)")
            case let .crossRootAlias(alias, resolvedRoot):
                throw MCPError.invalidParams("new_path alias '\(alias)' resolves to root '\(resolvedRoot.name)', but moves across roots are not supported.")
            }
        }
        if await store.file(rootID: source.rootID, relativePath: newRelativePath) != nil {
            throw MCPError.invalidParams("path already exists: \(newPath)")
        }
        try await store.moveFile(rootID: source.rootID, from: source.standardizedRelativePath, to: newRelativePath)
    }

    private func moveItemToTrash(path: String, lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace) async throws {
        let store = promptVM.workspaceFileContextStore
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let issue = await store.exactPathResolutionIssue(for: trimmed, kind: .either, rootScope: lookupRootScope) {
            throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
        }
        let mutationService = WorkspaceFileMutationService(store: store)
        if let file = await mutationService.exactExistingFile(trimmed, rootScope: lookupRootScope) {
            try await store.moveItemToTrash(rootID: file.rootID, relativePath: file.standardizedRelativePath)
            return
        }
        guard let lookup = await store.lookupPath(WorkspacePathLookupRequest(userPath: trimmed, profile: .moveSourceExact, rootScope: lookupRootScope)) else {
            throw MCPError.invalidParams("Unknown or unloaded path: \(path).")
        }
        if let folder = lookup.folder {
            try await store.moveItemToTrash(rootID: folder.rootID, relativePath: folder.standardizedRelativePath)
        } else {
            throw MCPError.invalidParams("Unknown or unloaded path: \(path).")
        }
    }

    // MARK: - File-tree builder for get_file_tree

    /// Uses the headless store snapshot for get_file_tree requests.
    private func buildStoreBackedFileTreeResult(
        mode: String,
        maxDepth: Int?,
        startPath: String?,
        lookupContext: WorkspaceLookupContext = .visibleWorkspace
    ) async throws -> (result: FileTreeResult, rootCount: Int) {
        let snapshotMode: WorkspaceFileTreeSnapshotMode
        switch mode.lowercased() {
        case "selected": snapshotMode = .selected
        case "full": snapshotMode = .full
        case "folders": snapshotMode = .folders
        case "auto": snapshotMode = .auto
        default: throw MCPError.invalidParams("invalid mode: \(mode)")
        }

        let filePathDisplay = await MainActor.run { promptVM.filePathDisplayOption }
        let showCodeMapMarkers = await MainActor.run { !promptVM.codeMapsGloballyDisabled }
        let selection = try await lookupContext.physicalizeSelection(storedSelectionForCurrentTabContext(includeCodemapPathsWhenSelectedUsage: true))
        let rawSnapshot = await promptVM.workspaceFileContextStore.makeFileTreeSelectionSnapshot(
            selection: selection,
            request: WorkspaceFileTreeSnapshotRequest(
                mode: snapshotMode,
                filePathDisplay: filePathDisplay,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: showCodeMapMarkers,
                rootScope: lookupContext.rootScope,
                startPath: startPath.map { lookupContext.translateInputPath($0) },
                maxDepth: maxDepth
            ),
            profile: .mcpRead
        )
        let snapshot = lookupContext.bindingProjection?.logicalizeFileTreeSnapshot(rawSnapshot) ?? rawSnapshot
        if snapshot.roots.isEmpty {
            let hasStartPath = startPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let msg = await workspaceContextMessage(forOperation: MCPWindowToolName.getFileTree, path: hasStartPath ? startPath : nil)
            return (FileTreeResult(
                tree: msg,
                usedSelectedMarker: false,
                usedCodeMapMarker: false,
                wasTruncated: false,
                note: hasStartPath ? "Requested path is outside the loaded roots" : "No workspace loaded"
            ), 0)
        }

        let tree = await Task.detached(priority: .userInitiated) {
            CodeMapExtractor.generateFileTree(using: snapshot)
        }.value
        return (FileTreeResult(
            tree: tree,
            usedSelectedMarker: tree.contains(" *"),
            usedCodeMapMarker: showCodeMapMarkers && tree.contains(" +"),
            wasTruncated: false,
            note: nil
        ), snapshot.roots.count)
    }

    @MainActor
    func storedSelection(
        for context: TabContextSnapshot,
        includeCodemapPathsWhenSelectedUsage: Bool
    ) -> StoredSelection {
        let base = context.selection
        guard includeCodemapPathsWhenSelectedUsage,
              effectiveMCPCodeMapUsage(promptVM.codeMapUsage) == .selected,
              !base.autoCodemapPaths.isEmpty
        else { return base }

        var selectedPaths = StoredSelectionPathNormalization.standardizedPaths(base.selectedPaths)
        var existingSelected = Set(selectedPaths)
        for path in StoredSelectionPathNormalization.standardizedPaths(base.autoCodemapPaths) where existingSelected.insert(path).inserted {
            selectedPaths.append(path)
        }
        return StoredSelection(
            selectedPaths: selectedPaths,
            autoCodemapPaths: base.autoCodemapPaths,
            slices: base.slices,
            codemapAutoEnabled: base.codemapAutoEnabled
        )
    }

    @MainActor
    private func storedSelectionForCurrentTabContext(includeCodemapPathsWhenSelectedUsage: Bool) async throws -> StoredSelection {
        let metadata = await captureRequestMetadata()
        let resolved = try resolveTabContextSnapshot(
            from: metadata,
            toolName: MCPWindowToolName.getFileTree,
            policy: .allowLegacyImplicitRouting
        )
        return storedSelection(
            for: resolved.snapshot,
            includeCodemapPathsWhenSelectedUsage: includeCodemapPathsWhenSelectedUsage
        )
    }

    // MARK: - Error handling helpers

    nonisolated static func friendlySearchErrorParts(for pattern: String, isRegex: Bool, error: SearchPatternError) -> (issue: String, suggestion: String?) {
        SearchPatternErrorFormatter.parts(for: pattern, isRegex: isRegex, error: error)
    }

    private static func friendlySearchError(for pattern: String, isRegex: Bool, error: SearchPatternError) -> String {
        let base = error.localizedDescription
        switch error {
        case .unmatchedParentheses, .unmatchedBrackets, .invalidEscape, .invalidQuantifier:
            if isRegex {
                return base + " Tip: If you intended a literal search, set interpretation=\"literal\" (or regex=false). For regex, escape special characters: \"(\" as \"\\(\", \")\" as \"\\)\". Remember JSON doubles backslashes, so \"\\(\" in regex is written as \"\\\\(\" in JSON."
            } else {
                return base + " Tip: You're in literal mode. Backslashes are matched as normal characters. If you meant a regex, set interpretation=\"regex\" (or regex=true) and escape special characters (e.g., \"\\(\")."
            }
        default:
            return base
        }
    }

    nonisolated static func sanitizeSearchScopeInputs(_ inputs: [String]) -> [String] {
        var seen = Set<String>()
        var sanitized: [String] = []
        sanitized.reserveCapacity(inputs.count)
        for input in inputs {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                sanitized.append(trimmed)
            }
        }
        return sanitized
    }

    nonisolated static func pathFilterSuggestion(
        hadPathFilter: Bool,
        scopedFileCount: Int?
    ) -> String? {
        guard hadPathFilter, (scopedFileCount ?? 0) == 0 else { return nil }
        return "The specified path filter resolved to no files in the current workspace. Use get_file_tree to inspect the project structure and confirm the path."
    }

    private nonisolated static func parseContextAlias(_ args: [String: Value]) -> Int? {
        // Direct key "-C"
        if let alias = args["-C"] {
            if let value = alias.intValue { return value }
            if let string = alias.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = Int(string)
            {
                return parsed
            }
        }

        // Support variants like "-C: 2" or "-C=3"
        for (key, value) in args {
            let lower = key.lowercased()
            guard lower.hasPrefix("-c") else { continue }

            if lower == "-c" {
                if let intValue = value.intValue { return intValue }
                if let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let parsed = Int(string)
                {
                    return parsed
                }
                continue
            }

            var suffix = key.dropFirst(2)
            while let first = suffix.first, first == ":" || first == "=" || first == " " {
                suffix = suffix.dropFirst()
            }
            let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Int(trimmed) {
                return parsed
            }
        }

        return nil
    }

    @MainActor
    func workspaceContextMessage(forOperation op: String? = nil, path: String? = nil) async -> String {
        let roots = await promptVM.workspaceFileContextStore.rootRefs(scope: .visibleWorkspace)
        if roots.isEmpty {
            return "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
        }

        if let p = path, !p.isEmpty {
            let standardized = StandardizedPath.absolute((p as NSString).expandingTildeInPath)
            let underRoot = roots.contains { standardized == $0.standardizedFullPath || StandardizedPath.isDescendant(standardized, of: $0.standardizedFullPath) }
            if p.hasPrefix("/"), !underRoot {
                let rootsList = roots.map { "\($0.name) → \($0.fullPath)" }.joined(separator: "; ")
                return "The requested path '\(p)' is not inside any loaded folder in this window. Loaded roots: \(rootsList). Use the 'manage_workspaces' tool to switch to a workspace containing this path, or add the folder to the current workspace."
            }
        }

        let rootsList = roots.map { "\($0.name) → \($0.fullPath)" }.joined(separator: "; ")
        return "Loaded roots: \(rootsList)"
    }

    private func requireWorkspaceForTool(_ toolName: String) async throws {
        if await promptVM.workspaceFileContextStore.rootRefs(scope: .visibleWorkspace).isEmpty {
            let msg = await workspaceContextMessage(forOperation: toolName, path: nil)
            throw MCPError.invalidParams(msg)
        }
    }

    @MainActor
    private func mapFileManagerErrorToMCP(_ error: FileManagerError, action: String, path: String?) async -> MCPError {
        switch error {
        case let .fileSystemServiceNotFoundWithContext(context):
            return MCPError.invalidParams(context)
        default:
            let ctx = await workspaceContextMessage(forOperation: action, path: path)
            return MCPError.invalidParams(ctx)
        }
    }

    // MARK: - Tab workspace helpers

    func tabCodeMaps(for paths: [String], maxResults: Int = 25) async -> (maps: [String: FileAPI], omitted: Int) {
        await getCodeMaps(for: paths, maxResults: maxResults)
    }

    @MainActor
    func tabWorkspaceContextMessage(forOperation op: String? = nil, path: String? = nil) async -> String {
        await workspaceContextMessage(forOperation: op, path: path)
    }

    var tabFileTreeToolName: String {
        MCPWindowToolName.getFileTree
    }

    // MARK: - Selection helpers

    func selectionFindFiles(
        atPaths paths: [String],
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> [String: WorkspaceFileRecord] {
        await promptVM.workspaceFileContextStore.lookupFiles(
            atPaths: paths,
            profile: .mcpSelection,
            rootScope: lookupRootScope
        )
    }

    var selectionCodemapAutoEnabled: Bool {
        get async {
            let selection = try? await storedSelectionForCurrentTabContext(includeCodemapPathsWhenSelectedUsage: false)
            return selection?.codemapAutoEnabled ?? false
        }
    }

    func selectedFiles() async throws -> [WorkspaceFileRecord] {
        let selection = try await storedSelectionForCurrentTabContext(includeCodemapPathsWhenSelectedUsage: false)
        let paths = StoredSelectionPathNormalization.standardizedPaths(selection.selectedPaths)
        let resolved = await promptVM.workspaceFileContextStore.lookupFiles(atPaths: paths, profile: .mcpSelection, rootScope: .allLoaded)
        return paths.compactMap { resolved[$0] }
    }

    func selectionSnapshot() async throws -> (selected: [WorkspaceFileRecord], codemap: [WorkspaceFileRecord], slices: [UUID: [LineRange]], autoEnabled: Bool) {
        let selection = try await storedSelectionForCurrentTabContext(includeCodemapPathsWhenSelectedUsage: false)
        let selectedPaths = StoredSelectionPathNormalization.standardizedPaths(selection.selectedPaths)
        let codemapPaths = StoredSelectionPathNormalization.standardizedPaths(selection.autoCodemapPaths)
        let allPaths = selectedPaths + codemapPaths
        let resolved = await promptVM.workspaceFileContextStore.lookupFiles(atPaths: allPaths, profile: .mcpSelection, rootScope: .allLoaded)
        var sliceSnapshot: [UUID: [LineRange]] = [:]
        for (path, ranges) in StoredSelectionPathNormalization.standardizedSlices(selection.slices) {
            if let file = resolved[path] { sliceSnapshot[file.id] = ranges }
        }
        return (
            selected: selectedPaths.compactMap { resolved[$0] },
            codemap: codemapPaths.compactMap { resolved[$0] },
            slices: sliceSnapshot,
            autoEnabled: selection.codemapAutoEnabled
        )
    }
}
