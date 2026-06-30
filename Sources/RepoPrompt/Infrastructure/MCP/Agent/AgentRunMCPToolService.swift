import Foundation
import MCP
import RepoPromptShared

struct OracleExportFile: Equatable {
    let path: String
    let instruction: String
}

struct OracleExportDestination: Equatable {
    let workspaceID: UUID
    let windowID: Int
    let tabID: UUID?
    /// Logical/canonical primary root returned to the bound child.
    let primaryRootPath: String
    /// Frozen logical-to-physical scope used for disk I/O and read-back verification.
    let lookupContext: WorkspaceLookupContext

    init(
        workspaceID: UUID,
        windowID: Int,
        tabID: UUID?,
        primaryRootPath: String,
        lookupContext: WorkspaceLookupContext = .visibleWorkspace
    ) {
        self.workspaceID = workspaceID
        self.windowID = windowID
        self.tabID = tabID
        self.primaryRootPath = primaryRootPath
        self.lookupContext = lookupContext
    }
}

struct OracleExportRequest {
    let sourceTool: String
    let mode: String
    let message: String
    let chatID: String?
    let response: String?
    let destination: OracleExportDestination?

    init(
        sourceTool: String,
        mode: String,
        message: String,
        chatID: String?,
        response: String?,
        destination: OracleExportDestination? = nil
    ) {
        self.sourceTool = sourceTool
        self.mode = mode
        self.message = message
        self.chatID = chatID
        self.response = response
        self.destination = destination
    }
}

enum AgentOracleExport {
    static func instruction(path: String) -> String {
        let pathLiteral = jsonStringLiteral(path)
        return """
        Read the Oracle export with `read_file` using `{"path": \(pathLiteral)}`. Use this exact absolute `path` value verbatim without shortening or rewriting it, and use the file as planning context for this task.
        """
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else {
            return "\"\(value)\""
        }
        return literal
    }

    static func oracleMarkdown(request: OracleExportRequest, exportedAt _: Date = Date()) -> String {
        let title = switch request.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "plan":
            "# Oracle Plan"
        case "review":
            "# Oracle Review"
        default:
            "# Oracle Response"
        }
        let response: String = if let responseText = request.response,
                                  !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            responseText
        } else {
            "_No response text was returned._"
        }
        return "\(title)\n\n\(response)"
    }
}

struct AgentRunWaitScopeCompletion: Equatable {
    enum Reason: String, Equatable {
        case snapshotReady = "snapshot_ready"
        case timedOut = "timed_out"
        case expired
        case superseded
        case cancelled
        case error
    }

    let reason: Reason
    let result: String?
    let winnerSessionID: UUID?
    let pendingSessionIDs: Set<UUID>
    let errorDescription: String?
}

private enum MultiWaitDisposition {
    case actionable(AgentRunMCPSnapshot)
    case steeringInterrupted(AgentRunMCPSnapshot)
    case superseded(AgentRunMCPSnapshot)
    case terminalPublicationRejected(String)
    case timedOut
    case expired
    case cancelled
}

private struct WaitAnyResult {
    let sessionID: UUID
    let disposition: MultiWaitDisposition
}

private struct TimestampedWaitAnyResult {
    let result: WaitAnyResult
    let completedAt: ContinuousClock.Instant
}

private struct CancelledSingleWaitResolution {
    let rawValue: Value
    let completion: AgentRunWaitScopeCompletion
}

private final class WaitScopeCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCompletion: AgentRunWaitScopeCompletion?

    func set(_ completion: AgentRunWaitScopeCompletion) {
        lock.lock()
        storedCompletion = completion
        lock.unlock()
    }

    func get() -> AgentRunWaitScopeCompletion? {
        lock.lock()
        let completion = storedCompletion
        lock.unlock()
        return completion
    }
}

private let agentRunSteeringWakeNote = "Steering interrupted this wait; the agent run has not completed. After responding to the user, call agent_run.wait for this session again to resume waiting."

@MainActor
struct AgentRunMCPToolService {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata
    typealias HeartbeatOperation = @Sendable () async throws -> Value
    typealias StartRun = @MainActor (
        _ target: AgentModeViewModel.MCPSessionTarget,
        _ message: String,
        _ metadata: RequestMetadata,
        _ bindCurrentRequestToTab: @escaping AgentExternalMCPRunStarter.BindCurrentRequestToTab,
        _ agentModeVM: AgentModeViewModel,
        _ agentRaw: String?,
        _ modelRaw: String?,
        _ reasoningEffortRaw: String?,
        _ taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        _ workflow: AgentWorkflowDefinition?,
        _ expectedParentSessionID: UUID?,
        _ oracleReviewSource: AgentRunOracleReviewSource?
    ) async throws -> AgentExternalMCPRunStarter.StartOutcome
    typealias ResolveOracleReviewLaunchSource = @MainActor (
        _ metadata: RequestMetadata,
        _ targetWindow: WindowState
    ) async throws -> ResolvedAgentRunOracleReviewLaunchSource

    static let defaultWaitTimeoutSeconds = MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
    static let defaultStartTaskLabelKind: AgentModelCatalog.TaskLabelKind = .pair

    static func resolvedStartTimeoutSeconds(_ value: Value?) throws -> TimeInterval {
        try resolvedLifecycleWaitTimeoutSeconds(value)
    }

    static func resolvedWaitTimeoutSeconds(_ value: Value?) throws -> TimeInterval {
        try resolvedLifecycleWaitTimeoutSeconds(value)
    }

    static func resolvedSteerTimeoutSeconds(_ value: Value?) throws -> TimeInterval {
        try resolvedLifecycleWaitTimeoutSeconds(value)
    }

    private static func resolvedLifecycleWaitTimeoutSeconds(_ value: Value?) throws -> TimeInterval {
        try AgentMCPToolHelpers.parseTimeoutSeconds(value) ?? defaultWaitTimeoutSeconds
    }

    static func defaultTaskLabelForStart(
        resolvedTabID: UUID?,
        workflow _: AgentWorkflowDefinition? = nil
    ) -> AgentModelCatalog.TaskLabelKind? {
        // `agent_run.start` creates a new session by default; when callers omit
        // `model_id`, resolve through the global Pair role default. Workflows do
        // not override that default. If a caller explicitly targets an existing
        // tab, leave that tab's current selection alone.
        resolvedTabID == nil ? defaultStartTaskLabelKind : nil
    }

    let toolName: String
    let captureRequestMetadata: () async -> RequestMetadata
    let requireTargetWindow: () throws -> WindowState
    let resolveRequestedTabID: (_ args: [String: Value]) throws -> UUID?
    let resolveSpawnParentSourceTabID: (_ metadata: RequestMetadata) async -> UUID?
    var resolveOracleReviewLaunchSource: ResolveOracleReviewLaunchSource = { _, _ in
        throw MCPError.internalError("agent_run.start Oracle launch-source resolution is not configured.")
    }

    var validateSpawnRouting: (_ metadata: RequestMetadata, _ sourceTabID: UUID?) async throws -> Void = { _, _ in }
    let resolveSpawnParentSessionID: (_ metadata: RequestMetadata, _ targetWindow: WindowState) async -> UUID?
    var resolveSpawnParentSessionIDFromSourceTabID: ((_ sourceTabID: UUID, _ targetWindow: WindowState) async -> UUID?)?
    let bindCurrentRequestToTab: (_ tabID: UUID, _ metadata: RequestMetadata) async throws -> Void
    let withHeartbeat: (_ connectionID: UUID?, _ tool: String, _ stage: String, _ message: String, _ operation: @escaping HeartbeatOperation) async throws -> Value
    var beginAgentRunWait: (_ metadata: RequestMetadata, _ sessionIDs: Set<UUID>, _ timeoutSeconds: TimeInterval?) async -> UUID? = { _, _, _ in nil }
    var endAgentRunWait: (_ token: UUID, _ completion: AgentRunWaitScopeCompletion) async -> Void = { _, _ in }
    let startRun: StartRun
    var currentSnapshotProvider: (@Sendable (_ sessionID: UUID, _ agentModeVM: AgentModeViewModel) async -> AgentRunMCPSnapshot?)?
    #if DEBUG
        var testAgentModeViewModel: AgentModeViewModel?
        var testBeforeExplicitTabWorktreeValidation: (() -> Void)?
        var testBeforeProviderDispatch: (() async -> Void)?
        var testAfterProviderStartBeforeBookkeeping: (() async -> Void)?
    #endif
    var vcsService: VCSService = .shared
    var gitTargetResolver: GitRepoTargetResolver = .init()

    private var startWorktreeCoordinator: AgentMCPStartWorktreeCoordinator {
        AgentMCPStartWorktreeCoordinator(
            operationName: "agent_run.start",
            vcsService: vcsService,
            gitTargetResolver: gitTargetResolver
        )
    }

    func execute(args: [String: Value]) async throws -> Value {
        let op = normalizedString(args["op"])?.lowercased() ?? "wait"
        #if DEBUG
            if op != "start", args["_worktree_startup_benchmark_token"] != nil {
                throw MCPError.invalidParams("The worktree startup benchmark token is only supported with agent_run op=start.")
            }
        #endif
        if op != "start", startWorktreeCoordinator.containsArguments(args) {
            throw MCPError.invalidParams("agent_run worktree arguments are only supported with op=start.")
        }
        switch op {
        case "start":
            return try await executeStart(args: args)
        case "poll":
            return try await executeWait(args: args, forcePoll: true)
        case "wait":
            return try await executeWait(args: args)
        case "cancel":
            return try await executeCancel(args: args)
        case "steer":
            return try await executeSteer(args: args)
        case "respond":
            return try await executeRespond(args: args)
        default:
            throw MCPError.invalidParams("Unsupported agent_run op '\(op)'. Use start, poll, wait, cancel, steer, or respond.")
        }
    }

    private func executeStart(args: [String: Value]) async throws -> Value {
        let message = try resolveMessage(args["message"], name: "message")
        let workflow = try resolveWorkflow(args: args)
        let worktreeStartRequest = try startWorktreeCoordinator.parseRequest(args: args)
        var worktreeStartupCorrelationID = UUID()
        var worktreeStartupFlags = WorktreeStartupFeatureFlags.current()
        var worktreeStartupServingControl = WorktreeStartupServingControl.automatic
        #if DEBUG
            var worktreeStartupBenchmarkToken: UUID?
        #endif
        // start always creates a new session — reject explicit session_id
        if normalizedString(args["session_id"]) != nil {
            throw MCPError.invalidParams("agent_run.start always creates a new session. Use agent_run op=steer with session_id to continue an existing session.")
        }
        let detach = parseBool(args["detach"]) ?? false
        let timeoutSeconds = try Self.resolvedStartTimeoutSeconds(args["timeout"])

        let metadata = await captureRequestMetadata()
        let targetWindow = try requireTargetWindow()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available for agent_run.start.")
        }
        guard workspace.isSystemWorkspace == false else {
            throw MCPError.invalidParams("Cannot start an agent run from the default system workspace. Open or select a project workspace and try again.")
        }

        let agentModeVM = targetWindow.agentModeViewModel
        let parentSourceTabID = await resolveSpawnParentSourceTabID(metadata)
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.agentRunStartResolvedSource", tabID: parentSourceTabID, fields: [
                "connectionID": metadata.connectionID?.uuidString ?? "nil",
                "clientName": metadata.clientName ?? "nil",
                "windowID": metadata.windowID.map(String.init) ?? "nil",
                "parentSourceTabID": parentSourceTabID?.uuidString ?? "nil",
                "inheritWorktreeBindings": String(worktreeStartRequest.inheritParentWorktreeBindings),
                "workflowID": workflow?.id ?? "nil",
                "workflowName": workflow?.displayName ?? "nil"
            ])
        #endif
        try await validateSpawnRouting(metadata, parentSourceTabID)
        try agentModeVM.mcpValidateAgentRunSpawnAllowed(sourceTabID: parentSourceTabID)
        let spawnParentSessionID: UUID? = if let parentSourceTabID,
                                             let resolveSpawnParentSessionIDFromSourceTabID
        {
            await resolveSpawnParentSessionIDFromSourceTabID(parentSourceTabID, targetWindow)
        } else {
            await resolveSpawnParentSessionID(metadata, targetWindow)
        }
        let resolvedTabID = try resolveRequestedTabID(args)
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.agentRunStartParentResolved", tabID: parentSourceTabID, fields: [
                "connectionID": metadata.connectionID?.uuidString ?? "nil",
                "windowID": metadata.windowID.map(String.init) ?? "nil",
                "parentSourceTabID": parentSourceTabID?.uuidString ?? "nil",
                "parentSessionID": spawnParentSessionID?.uuidString ?? "nil",
                "inheritWorktreeBindings": String(worktreeStartRequest.inheritParentWorktreeBindings),
                "requestedTabID": resolvedTabID?.uuidString ?? "nil"
            ])
        #endif
        // A non-nil spawn source is only returned for a routed Agent Mode invocation.
        // Never degrade such a nested start into an orphan when its validated
        // parent Agent session has disappeared or cannot be recovered.
        if parentSourceTabID != nil, spawnParentSessionID == nil {
            throw MCPError.invalidParams("agent_run.start was routed from an Agent Mode run, but RepoPrompt could not resolve its parent Agent session. Refusing to create an unparented run; reconnect the agent MCP client or retry after the source session is active.")
        }

        // Freeze the source before model validation or target creation. Later selection/worktree
        // mutations must not alter the child run's delegated review packaging.
        let oracleLaunchSource = try await resolveOracleReviewLaunchSource(metadata, targetWindow)
        if let parentSourceTabID {
            guard oracleLaunchSource.snapshot.tabID == parentSourceTabID,
                  oracleLaunchSource.source.sourceAgentSessionID == spawnParentSessionID
            else {
                throw MCPError.invalidParams(
                    "agent_run.start conversation-parent routing does not match its immutable Oracle packaging source. Refusing to create the child run."
                )
            }
        }

        // Compute the default task label before target creation. Omitted `model_id`
        // for agent_run.start resolves through the global Pair role default.
        let defaultTaskLabel = Self.defaultTaskLabelForStart(resolvedTabID: resolvedTabID, workflow: workflow)

        // Validate model selection before creating a target. Role labels resolve through global role defaults.
        let selection = try AgentMCPSelectionResolver.resolve(
            modelID: normalizedString(args["model_id"]),
            defaultTaskLabel: defaultTaskLabel,
            availability: targetWindow.apiSettingsViewModel.agentModeAvailabilityContext
        )

        #if DEBUG
            if let rawToken = normalizedString(args["_worktree_startup_benchmark_token"]) {
                guard let token = UUID(uuidString: rawToken) else {
                    throw MCPError.invalidParams("Invalid worktree startup benchmark token.")
                }
                do {
                    guard case .create = worktreeStartRequest.mode,
                          worktreeStartRequest.path == nil,
                          !worktreeStartRequest.allowExternalPath
                    else {
                        throw DebugWorktreeStartupBenchmarkError.startIdentityMismatch
                    }
                    let preflight = try WorktreeStartupBenchmarkDiagnostics.shared.preflight(token: token)
                    let scope = preflight.expectedStart.rootIdentity.scope
                    let actualContextID = metadata.tabContextHint?.tabID
                        ?? targetWindow.promptManager.activeComposeTabID
                    guard scope.windowID == targetWindow.windowID,
                          scope.workspaceID == workspace.id,
                          scope.contextID == actualContextID
                    else { throw DebugWorktreeStartupBenchmarkError.invalidScope }
                    worktreeStartupBenchmarkToken = token
                    worktreeStartupCorrelationID = preflight.correlationID
                    worktreeStartupFlags = preflight.flags
                    worktreeStartupServingControl = preflight.servingControl
                } catch let error as DebugWorktreeStartupBenchmarkError {
                    throw MCPError.invalidParams("Worktree startup benchmark token rejected (\(error.code)).")
                }
            }
        #endif

        let sessionName = normalizedString(args["session_name"])
        let effectiveParentWorktreeInheritance = worktreeStartRequest.inheritParentWorktreeBindings
            && !worktreeStartRequest.hasExplicitWorktreeArgs
        let usesRoutedParentSource = parentSourceTabID != nil
        let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
            tabID: resolvedTabID,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: sessionName,
            parentSessionID: spawnParentSessionID,
            inheritWorktreeBindings: usesRoutedParentSource
                ? false
                : effectiveParentWorktreeInheritance
        )
        guard let targetSessionID = target.sessionID else {
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw MCPError.internalError("agent_run.start target did not resolve a session ID.")
        }
        #if DEBUG
            if worktreeStartupBenchmarkToken != nil {
                do {
                    let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
                    try diagnostics.registerRecoverableStartTarget(
                        correlationID: worktreeStartupCorrelationID,
                        agentSessionID: targetSessionID,
                        targetTabID: target.tabID,
                        targetOrigin: target.origin
                    )
                    try diagnostics.requireRecoverableStartNotAborted(
                        correlationID: worktreeStartupCorrelationID
                    )
                } catch {
                    try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                        correlationID: worktreeStartupCorrelationID,
                        phase: .discardRequested,
                        errorCategory: "target_registration"
                    )
                    await agentModeVM.mcpDiscardSessionTarget(target)
                    try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                        correlationID: worktreeStartupCorrelationID,
                        phase: .discardCompleted,
                        providerRunActive: false
                    )
                    throw error
                }
            }
        #endif
        let worktreeStartupContext = WorktreeStartupContext(
            agentSessionID: targetSessionID,
            correlationID: worktreeStartupCorrelationID,
            flags: worktreeStartupFlags,
            servingControl: worktreeStartupServingControl
        )
        WorktreeStartupInstrumentation.record(.agentRunStarted, context: worktreeStartupContext)
        var expectedRoutedWorktreeBindings: [AgentSessionWorktreeBinding]?
        var expectedExplicitTabWorktreeSource: (
            tabID: UUID,
            sessionID: UUID,
            bindings: [AgentSessionWorktreeBinding]
        )?
        do {
            if effectiveParentWorktreeInheritance,
               let parentSourceTabID,
               let spawnParentSessionID
            {
                expectedRoutedWorktreeBindings = try agentModeVM.mcpReconcileRoutedSpawnWorktreeBindings(
                    sourceTabID: parentSourceTabID,
                    expectedParentSessionID: spawnParentSessionID,
                    target: target
                )
            } else if effectiveParentWorktreeInheritance,
                      parentSourceTabID == nil,
                      spawnParentSessionID == nil,
                      oracleLaunchSource.snapshot.route == .explicitTabContext,
                      let sourceAgentSessionID = oracleLaunchSource.snapshot.sourceAgentSessionID
            {
                guard case let .captured(capturedSource) = oracleLaunchSource.source else {
                    throw MCPError.invalidParams(
                        "agent_run.start cannot inherit the explicit-tab worktree because its frozen launch source is unavailable."
                    )
                }
                guard capturedSource.sourceTabID == oracleLaunchSource.snapshot.tabID,
                      capturedSource.sourceAgentSessionID == sourceAgentSessionID
                else {
                    throw MCPError.invalidParams(
                        "agent_run.start cannot inherit the explicit-tab worktree because its frozen launch source identity does not match the launch snapshot."
                    )
                }
                let capturedBindings = capturedSource.sourceWorktreeBindings
                try agentModeVM.mcpReconcileExplicitTabSpawnWorktreeBindings(
                    sourceTabID: oracleLaunchSource.snapshot.tabID,
                    expectedSourceSessionID: sourceAgentSessionID,
                    expectedBindings: capturedBindings,
                    target: target
                )
                expectedExplicitTabWorktreeSource = (
                    oracleLaunchSource.snapshot.tabID,
                    sourceAgentSessionID,
                    capturedBindings
                )
            }
            #if DEBUG
                if let worktreeStartupBenchmarkToken {
                    try await WorktreeStartupBenchmarkDiagnostics.$currentPendingStart.withValue(
                        DebugWorktreeStartupBenchmarkPendingStart(
                            token: worktreeStartupBenchmarkToken,
                            startAttemptID: UUID()
                        )
                    ) {
                        try await startWorktreeCoordinator.prepare(
                            request: worktreeStartRequest,
                            target: target,
                            targetWindow: targetWindow,
                            startupContext: worktreeStartupContext
                        )
                    }
                } else {
                    try await startWorktreeCoordinator.prepare(
                        request: worktreeStartRequest,
                        target: target,
                        targetWindow: targetWindow,
                        startupContext: worktreeStartupContext
                    )
                }
            #else
                try await startWorktreeCoordinator.prepare(
                    request: worktreeStartRequest,
                    target: target,
                    targetWindow: targetWindow,
                    startupContext: worktreeStartupContext
                )
            #endif
            if let expectedRoutedWorktreeBindings,
               let spawnParentSessionID
            {
                try agentModeVM.mcpRequireRoutedSpawnWorktreeBindings(
                    expectedRoutedWorktreeBindings,
                    expectedParentSessionID: spawnParentSessionID,
                    target: target
                )
            }
            #if DEBUG
                if expectedExplicitTabWorktreeSource != nil {
                    testBeforeExplicitTabWorktreeValidation?()
                }
            #endif
            if let expectedExplicitTabWorktreeSource {
                try agentModeVM.mcpRequireExplicitTabSpawnWorktreeBindings(
                    sourceTabID: expectedExplicitTabWorktreeSource.tabID,
                    expectedSourceSessionID: expectedExplicitTabWorktreeSource.sessionID,
                    expectedBindings: expectedExplicitTabWorktreeSource.bindings,
                    target: target
                )
            }
        } catch {
            WorktreeStartupInstrumentation.record(
                .failed,
                context: worktreeStartupContext,
                fallback: error is CancellationError ? .cancellation : nil
            )
            #if DEBUG
                if worktreeStartupBenchmarkToken != nil {
                    let category = error is CancellationError
                        ? "cancellation"
                        : (error as? DebugWorktreeStartupBenchmarkError) == .startAborted
                        ? "abort_requested"
                        : "worktree_preparation"
                    try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                        correlationID: worktreeStartupCorrelationID,
                        phase: .failed,
                        providerRunActive: false,
                        errorCategory: category
                    )
                    try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                        correlationID: worktreeStartupCorrelationID,
                        phase: .discardRequested
                    )
                }
            #endif
            await agentModeVM.mcpDiscardSessionTarget(target)
            #if DEBUG
                if worktreeStartupBenchmarkToken != nil {
                    try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                        correlationID: worktreeStartupCorrelationID,
                        phase: .discardCompleted,
                        providerRunActive: false
                    )
                }
            #endif
            throw error
        }
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.agentRunStartTargetResolved", tabID: target.tabID, fields: [
                "connectionID": metadata.connectionID?.uuidString ?? "nil",
                "targetSessionID": target.sessionID?.uuidString ?? "nil",
                "parentSessionID": spawnParentSessionID?.uuidString ?? "nil",
                "inheritWorktreeBindings": String(worktreeStartRequest.inheritParentWorktreeBindings),
                "taskLabel": selection.taskLabelKind?.rawValue ?? "nil",
                "agent": selection.agentRaw ?? "nil",
                "model": selection.modelRaw ?? "nil",
                "targetOrigin": String(describing: target.origin)
            ])
        #endif
        let outcome: AgentExternalMCPRunStarter.StartOutcome
        do {
            WorktreeStartupInstrumentation.record(.providerStart, context: worktreeStartupContext)
            #if DEBUG
                if worktreeStartupBenchmarkToken != nil {
                    await testBeforeProviderDispatch?()
                    try WorktreeStartupBenchmarkDiagnostics.shared.beginRecoverableProviderDispatch(
                        correlationID: worktreeStartupCorrelationID
                    )
                }
            #endif
            outcome = try await startRun(
                target,
                message,
                metadata,
                bindCurrentRequestToTab,
                agentModeVM,
                selection.agentRaw,
                selection.modelRaw,
                nil,
                selection.taskLabelKind,
                workflow,
                spawnParentSessionID,
                oracleLaunchSource.source
            )
            #if DEBUG
                if worktreeStartupBenchmarkToken != nil {
                    await testAfterProviderStartBeforeBookkeeping?()
                    if WorktreeStartupBenchmarkDiagnostics.shared.recoverableStartAbortRequested(
                        correlationID: worktreeStartupCorrelationID
                    ) == true {
                        await agentModeVM.cancelAgentRun(
                            tabID: target.tabID,
                            completion: .terminalPublished
                        )
                        throw DebugWorktreeStartupBenchmarkError.startAborted
                    }
                }
            #endif
        } catch {
            let decoratedError = startWorktreeCoordinator.providerStartError(
                error,
                targetSessionID: target.sessionID,
                agentModeVM: agentModeVM
            )
            #if DEBUG
                if worktreeStartupBenchmarkToken != nil {
                    try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                        correlationID: worktreeStartupCorrelationID,
                        phase: .failed,
                        providerRunActive: false,
                        errorCategory: error is CancellationError ? "cancellation" : "provider_start"
                    )
                    try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                        correlationID: worktreeStartupCorrelationID,
                        phase: .discardRequested
                    )
                }
            #endif
            await agentModeVM.mcpDiscardSessionTarget(target)
            #if DEBUG
                if worktreeStartupBenchmarkToken != nil {
                    try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                        correlationID: worktreeStartupCorrelationID,
                        phase: .discardCompleted,
                        providerRunActive: false
                    )
                }
            #endif
            throw decoratedError
        }
        #if DEBUG
            if worktreeStartupBenchmarkToken != nil {
                try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                    correlationID: worktreeStartupCorrelationID,
                    phase: .responsePrepared,
                    providerRunActive: outcome.snapshot.status == .running
                )
            }
        #endif
        if detach || outcome.snapshot.status != .running || timeoutSeconds <= 0 {
            return decoratedRunValue(snapshot: outcome.snapshot, workflow: workflow, delivery: outcome.delivery)
        }
        return try await waitForInterestingState(
            sessionID: outcome.snapshot.sessionID,
            agentModeVM: agentModeVM,
            metadata: metadata,
            timeoutSeconds: timeoutSeconds,
            stage: "starting",
            message: "Waiting for the started run to finish or request input...",
            workflow: workflow,
            initialDelivery: outcome.delivery
        )
    }

    private func executeWait(args: [String: Value], forcePoll: Bool = false) async throws -> Value {
        if args["session_ids"] != nil {
            if forcePoll {
                return try await executePollMany(args: args)
            }
            return try await executeWaitAny(args: args)
        }

        let targetWindow = try requireTargetWindow()
        let agentModeVM = resolvedAgentModeViewModel(targetWindow)
        let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let timeoutSeconds = try forcePoll ? 0 : Self.resolvedWaitTimeoutSeconds(args["timeout"])
        let metadata = await captureRequestMetadata()
        let initialSnapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        if initialSnapshot.isActionableForMCPWait || timeoutSeconds <= 0 {
            return decoratedRunValue(snapshot: initialSnapshot)
        }
        return try await waitForInterestingState(
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            metadata: metadata,
            timeoutSeconds: timeoutSeconds,
            stage: "waiting",
            message: "Waiting for the agent run to finish or request input...",
            liveSnapshot: initialSnapshot
        )
    }

    private func executeWaitAny(args: [String: Value]) async throws -> Value {
        let references = try parseSessionIDArray(args)
        let targetWindow = try requireTargetWindow()
        let agentModeVM = resolvedAgentModeViewModel(targetWindow)
        let sessionIDs = try await resolveControlSessionIDs(references, targetWindow: targetWindow, agentModeVM: agentModeVM)

        // Single-element waits should preserve the existing single-session response shape.
        if sessionIDs.count == 1 {
            var singleArgs = args
            singleArgs.removeValue(forKey: "session_ids")
            singleArgs["session_id"] = .string(sessionIDs[0].uuidString)
            return try await executeWait(args: singleArgs)
        }

        let timeoutSeconds = try Self.resolvedWaitTimeoutSeconds(args["timeout"])
        let metadata = await captureRequestMetadata()
        let initialSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)

        if let ready = initialSnapshots.first(where: { isInterestingSnapshot($0) }) {
            return decoratedMultiWaitValue(
                snapshot: ready,
                sessionIDs: sessionIDs,
                result: ready.status == .expired ? "expired" : "snapshot_ready",
                pendingSessionIDs: pendingSessionIDs(from: initialSnapshots)
            )
        }

        if timeoutSeconds <= 0 {
            return decoratedMultiWaitValue(
                snapshot: initialSnapshots[0],
                sessionIDs: sessionIDs,
                result: "timed_out",
                snapshots: initialSnapshots,
                pendingSessionIDs: pendingSessionIDs(from: initialSnapshots)
            )
        }

        let waitScopeToken = await beginAgentRunWait(metadata, Set(sessionIDs), timeoutSeconds)
        do {
            let value = try await withHeartbeat(
                metadata.connectionID,
                toolName,
                "waiting",
                "Waiting for the first agent run to finish or request input..."
            ) {
                try await waitForAnyInterestingState(
                    sessionIDs: sessionIDs,
                    agentModeVM: agentModeVM,
                    timeoutSeconds: timeoutSeconds,
                    initialSnapshots: initialSnapshots
                )
            }
            let completion = waitScopeCompletion(from: value, fallbackSessionIDs: sessionIDs)
            if let waitScopeToken {
                await endAgentRunWait(waitScopeToken, completion)
            }
            return value
        } catch is CancellationError {
            if let value = await waitAnyCancellationValueIfActionable(
                sessionIDs: sessionIDs,
                agentModeVM: agentModeVM,
                fallbackSnapshots: initialSnapshots
            ) {
                let completion = waitScopeCompletion(from: value, fallbackSessionIDs: sessionIDs)
                if let waitScopeToken {
                    await endAgentRunWait(waitScopeToken, completion)
                }
                return value
            }
            let completion = AgentRunWaitScopeCompletion(reason: .cancelled, result: "cancelled", winnerSessionID: nil, pendingSessionIDs: Set(sessionIDs), errorDescription: nil)
            if let waitScopeToken {
                await endAgentRunWait(waitScopeToken, completion)
            }
            throw CancellationError()
        } catch {
            let completion = AgentRunWaitScopeCompletion(reason: .error, result: "error", winnerSessionID: nil, pendingSessionIDs: Set(sessionIDs), errorDescription: String(describing: error))
            if let waitScopeToken {
                await endAgentRunWait(waitScopeToken, completion)
            }
            throw error
        }
    }

    private func resolvedAgentModeViewModel(_ targetWindow: WindowState) -> AgentModeViewModel {
        #if DEBUG
            if let testAgentModeViewModel {
                return testAgentModeViewModel
            }
        #endif
        return targetWindow.agentModeViewModel
    }

    private func executePollMany(args: [String: Value]) async throws -> Value {
        let references = try parseSessionIDArray(args)
        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let sessionIDs = try await resolveControlSessionIDs(references, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let snapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        return decoratedMultiPollValue(sessionIDs: sessionIDs, snapshots: snapshots)
    }

    private func executeCancel(args: [String: Value]) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let initialSnapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        if initialSnapshot.status == .expired {
            throw MCPError.invalidParams("This session control handle is no longer active.")
        }
        if initialSnapshot.status.isTerminal {
            throw MCPError.invalidParams("The run is not currently active (status: \(initialSnapshot.status.rawValue)) and cannot be cancelled.")
        }
        guard let session = agentModeVM.mcpControlledSession(sessionID: sessionID), session.runState.isActive else {
            throw MCPError.invalidParams("The run is not currently active and cannot be cancelled.")
        }
        let metadata = await captureRequestMetadata()
        let cancelResult = try await withHeartbeat(
            metadata.connectionID,
            toolName,
            "cancelling",
            "Cancelling the agent run..."
        ) {
            await agentModeVM.cancelAgentRun(tabID: session.tabID, completion: .terminalPublished)
            await Task.yield()
            return await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM).toValue()
        }
        if let parsed = cancelResult.objectValue.flatMap(snapshot(from:)) {
            return decoratedRunValue(snapshot: parsed)
        }
        return cancelResult
    }

    private func executeSteer(args: [String: Value]) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let text = try resolveMessage(args["message"], name: "message")
        let workflow = try resolveWorkflow(args: args)
        let delivery: AgentModeViewModel.MCPInstructionDispatch
        let snapshot: AgentRunMCPSnapshot
        if let controlledSession = agentModeVM.mcpControlledSession(sessionID: sessionID),
           controlledSession.runState.isActive
        {
            delivery = try await agentModeVM.mcpDispatchInstruction(
                sessionID: sessionID,
                text: text,
                allowStartingRun: true,
                workflow: workflow
            )
            await Task.yield()
            snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        } else {
            // Inactive steering starts a new epoch without replacing the session activation.
            agentModeVM.setMCPFollowUpRunPending(sessionID: sessionID, true)
            do {
                delivery = try await agentModeVM.withMCPRunEpochTransition(
                    sessionID: sessionID,
                    kind: .steering
                ) {
                    try await agentModeVM.mcpDispatchInstruction(
                        sessionID: sessionID,
                        text: text,
                        allowStartingRun: true,
                        workflow: workflow
                    )
                }
            } catch {
                agentModeVM.setMCPFollowUpRunPending(sessionID: sessionID, false)
                throw error
            }
            await Task.yield()
            snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        }
        await Task.yield()

        // Steer-and-wait: optionally block until the agent reaches an interesting state
        let shouldWait: Bool = {
            if let explicit = parseBool(args["wait"]) { return explicit }
            if args["timeout_seconds"] != nil { return true }
            return false
        }()
        let rawSteerTimeoutSeconds = args["timeout_seconds"]
        let ignoredTimeoutWarning: String?
        let steerTimeoutSeconds: TimeInterval?
        if shouldWait {
            ignoredTimeoutWarning = nil
            steerTimeoutSeconds = try Self.resolvedSteerTimeoutSeconds(rawSteerTimeoutSeconds)
        } else if rawSteerTimeoutSeconds != nil {
            ignoredTimeoutWarning = "Ignoring timeout_seconds because wait=false; the steering instruction was accepted without waiting."
            steerTimeoutSeconds = nil
        } else {
            ignoredTimeoutWarning = nil
            steerTimeoutSeconds = nil
        }
        let shouldBlockForSteeredOutput = delivery.isActiveRunDispatch
            ? snapshot.interaction == nil
            : (!snapshot.status.isTerminal && snapshot.interaction == nil)
        if shouldWait, shouldBlockForSteeredOutput {
            let metadata = await captureRequestMetadata()
            let timeout = steerTimeoutSeconds ?? Self.defaultWaitTimeoutSeconds
            if timeout > 0 {
                return try await waitForInterestingState(
                    sessionID: sessionID,
                    agentModeVM: agentModeVM,
                    metadata: metadata,
                    timeoutSeconds: timeout,
                    stage: "steering",
                    message: "Waiting for the steered run to finish or request input...",
                    workflow: workflow,
                    initialDelivery: delivery,
                    liveSnapshot: snapshot.status == .running ? snapshot : nil
                )
            }
        }
        return decoratedRunValue(
            snapshot: snapshot,
            workflow: workflow,
            delivery: delivery,
            warning: ignoredTimeoutWarning
        )
    }

    private func executeRespond(args: [String: Value]) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let interactionID = try requireUUID(args["interaction_id"], name: "interaction_id")
        let workflow = try resolveWorkflow(args: args)
        let payload = try parseResponsePayload(args: args)
        let dispatch = try await agentModeVM.mcpResolvePendingInteraction(
            sessionID: sessionID,
            interactionID: interactionID,
            payload: payload,
            workflow: workflow
        )
        await Task.yield()
        return await decoratedRunValue(
            snapshot: currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM),
            workflow: workflow,
            delivery: dispatch
        )
    }

    private func waitForInterestingState(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        metadata: RequestMetadata,
        timeoutSeconds: TimeInterval,
        stage: String,
        message: String,
        workflow: AgentWorkflowDefinition? = nil,
        initialDelivery: AgentModeViewModel.MCPInstructionDispatch? = nil,
        liveSnapshot _: AgentRunMCPSnapshot? = nil
    ) async throws -> Value {
        guard let initialCursor = agentModeVM.mcpWaitCursor(sessionID: sessionID) else {
            throw MCPError.invalidParams("This session control handle is no longer active.")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        let waitScopeToken = await beginAgentRunWait(metadata, [sessionID], timeoutSeconds)
        let completionBox = WaitScopeCompletionBox()
        let snapshot: Value
        do {
            snapshot = try await withHeartbeat(
                metadata.connectionID,
                toolName,
                stage,
                message
            ) {
                var cursor = initialCursor
                while true {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    let remaining = Self.timeInterval(from: clock.now.duration(to: deadline))
                    guard remaining > 0 else {
                        completionBox.set(AgentRunWaitScopeCompletion(
                            reason: .timedOut,
                            result: "timed_out",
                            winnerSessionID: nil,
                            pendingSessionIDs: [sessionID],
                            errorDescription: nil
                        ))
                        return await timedOutWaitValue(sessionID: sessionID, agentModeVM: agentModeVM)
                    }
                    let disposition = await AgentRunSessionStore.waitUntilInteresting(
                        cursor: cursor,
                        timeoutSeconds: remaining
                    )
                    switch disposition {
                    case let .snapshotReady(triggeringSnapshot):
                        completionBox.set(AgentRunWaitScopeCompletion(
                            reason: triggeringSnapshot.status == .expired ? .expired : .snapshotReady,
                            result: triggeringSnapshot.status == .expired ? "expired" : "snapshot_ready",
                            winnerSessionID: triggeringSnapshot.status == .expired ? nil : sessionID,
                            pendingSessionIDs: triggeringSnapshot.status == .expired ? [sessionID] : [],
                            errorDescription: nil
                        ))
                        return triggeringSnapshot.toValue()
                    case let .noteworthySnapshot(triggeringSnapshot, reason):
                        if triggeringSnapshot.isActionableForMCPWait {
                            completionBox.set(AgentRunWaitScopeCompletion(
                                reason: .snapshotReady,
                                result: "snapshot_ready",
                                winnerSessionID: sessionID,
                                pendingSessionIDs: [],
                                errorDescription: nil
                            ))
                            return triggeringSnapshot.toValue()
                        }
                        if reason == .steeringRequested {
                            completionBox.set(AgentRunWaitScopeCompletion(
                                reason: .cancelled,
                                result: "interrupted_by_steering",
                                winnerSessionID: nil,
                                pendingSessionIDs: [sessionID],
                                errorDescription: nil
                            ))
                            return Self.steeringInterruptedSingleWaitValue(triggeringSnapshot)
                        }
                        continue
                    case let .epochAdvanced(epoch, transitionKind):
                        if transitionKind == .unrelated {
                            completionBox.set(AgentRunWaitScopeCompletion(
                                reason: .superseded,
                                result: "superseded",
                                winnerSessionID: nil,
                                pendingSessionIDs: [sessionID],
                                errorDescription: nil
                            ))
                            return await supersededWaitValue(sessionID: sessionID, agentModeVM: agentModeVM)
                        }
                        cursor = .init(registration: cursor.registration, epoch: epoch)
                    case let .terminalPublicationRejected(_, reason):
                        throw MCPError.internalError("The agent run terminal state could not be published: \(reason)")
                    case .timedOut:
                        completionBox.set(AgentRunWaitScopeCompletion(
                            reason: .timedOut,
                            result: "timed_out",
                            winnerSessionID: nil,
                            pendingSessionIDs: [sessionID],
                            errorDescription: nil
                        ))
                        return await timedOutWaitValue(sessionID: sessionID, agentModeVM: agentModeVM)
                    case .expired:
                        completionBox.set(AgentRunWaitScopeCompletion(
                            reason: .expired,
                            result: "expired",
                            winnerSessionID: nil,
                            pendingSessionIDs: [sessionID],
                            errorDescription: nil
                        ))
                        return Self.expiredWaitValue(sessionID: sessionID)
                    case .cancelled:
                        throw CancellationError()
                    }
                }
            }
        } catch {
            if error is CancellationError,
               let resolution = await cancelledSingleWaitResolutionIfActionable(
                   sessionID: sessionID,
                   agentModeVM: agentModeVM
               )
            {
                if let waitScopeToken {
                    await endAgentRunWait(waitScopeToken, resolution.completion)
                }
                return await finalDecoratedSingleWaitValue(
                    from: resolution.rawValue,
                    sessionID: sessionID,
                    agentModeVM: agentModeVM,
                    workflow: workflow,
                    initialDelivery: initialDelivery
                )
            }
            if let waitScopeToken {
                let completion = AgentRunWaitScopeCompletion(
                    reason: error is CancellationError ? .cancelled : .error,
                    result: error is CancellationError ? "cancelled" : "error",
                    winnerSessionID: nil,
                    pendingSessionIDs: [sessionID],
                    errorDescription: String(describing: error)
                )
                await endAgentRunWait(waitScopeToken, completion)
            }
            throw error
        }
        if let waitScopeToken {
            let completion = completionBox.get() ?? singleWaitScopeCompletion(from: snapshot, sessionID: sessionID)
            await endAgentRunWait(waitScopeToken, completion)
        }
        return await finalDecoratedSingleWaitValue(
            from: snapshot,
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            workflow: workflow,
            initialDelivery: initialDelivery
        )
    }

    private func timedOutWaitValue(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) async -> Value {
        let snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        var object = snapshot.asObject()
        object["_meta"] = .object(["wait_result": .string("timed_out")])
        return .object(object)
    }

    private func supersededWaitValue(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) async -> Value {
        let snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        var object = snapshot.asObject()
        object["_meta"] = .object([
            "wake_reason": .string("superseded_turn"),
            "wait_result": .string("superseded")
        ])
        return .object(object)
    }

    private nonisolated static func expiredWaitValue(sessionID: UUID) -> Value {
        var object = AgentRunMCPSnapshot.expired(sessionID: sessionID).asObject()
        object["_meta"] = .object(["wait_result": .string("expired")])
        return .object(object)
    }

    private nonisolated static func steeringInterruptedSingleWaitValue(
        _ snapshot: AgentRunMCPSnapshot
    ) -> Value {
        var object = snapshot.asObject()
        object["_meta"] = .object([
            "wake_reason": .string(AgentRunSessionStore.WakeReason.steeringRequested.rawValue)
        ])
        return .object(object)
    }

    private func cancelledSingleWaitResolutionIfActionable(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) async -> CancelledSingleWaitResolution? {
        let snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        guard snapshot.status != .expired, snapshot.isActionableForMCPWait else { return nil }
        let value = snapshot.toValue()
        return CancelledSingleWaitResolution(
            rawValue: value,
            completion: singleWaitScopeCompletion(from: value, sessionID: sessionID)
        )
    }

    private func finalDecoratedSingleWaitValue(
        from rawValue: Value,
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        workflow: AgentWorkflowDefinition?,
        initialDelivery: AgentModeViewModel.MCPInstructionDispatch?
    ) async -> Value {
        let resolvedSnapshot: AgentRunMCPSnapshot
        let wakeReason = rawValue.objectValue.flatMap(wakeReason(from:))
        if let parsedSnapshot = rawValue.objectValue.flatMap(snapshot(from:)) {
            resolvedSnapshot = parsedSnapshot
        } else {
            resolvedSnapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        }
        let decorated = decoratedRunValue(
            snapshot: resolvedSnapshot,
            workflow: workflow,
            delivery: initialDelivery,
            wakeReason: wakeReason
        )
        guard var object = decorated.objectValue,
              let rawMeta = rawValue.objectValue?["_meta"]?.objectValue
        else {
            return decorated
        }
        var meta = object["_meta"]?.objectValue ?? [:]
        for (key, value) in rawMeta {
            meta[key] = value
        }
        object["_meta"] = .object(meta)
        return .object(object)
    }

    private func waitAnyCancellationValueIfActionable(
        sessionIDs: [UUID],
        agentModeVM: AgentModeViewModel,
        fallbackSnapshots: [AgentRunMCPSnapshot]
    ) async -> Value? {
        let freshSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        let snapshots = freshSnapshots.isEmpty ? fallbackSnapshots : freshSnapshots
        guard !snapshots.isEmpty else { return nil }

        if let ready = snapshots.first(where: { isInterestingSnapshot($0) && $0.status != .expired }) {
            return decoratedMultiWaitValue(
                snapshot: ready,
                sessionIDs: sessionIDs,
                result: "snapshot_ready",
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs(from: snapshots).filter { $0 != ready.sessionID }
            )
        }

        return nil
    }

    private func waitAnySteeringInterruptValue(
        sessionIDs: [UUID],
        agentModeVM: AgentModeViewModel,
        triggeringSnapshot: AgentRunMCPSnapshot,
        latestSnapshots: [AgentRunMCPSnapshot]
    ) async -> Value {
        let freshSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        var snapshots = freshSnapshots.isEmpty ? latestSnapshots : freshSnapshots
        if snapshots.isEmpty {
            snapshots = [triggeringSnapshot]
        } else if snapshots.contains(where: { $0.sessionID == triggeringSnapshot.sessionID }) == false {
            snapshots.append(triggeringSnapshot)
        }
        let pendingIDs = pendingSessionIDs(from: snapshots)
        let runningIDs = snapshots.filter { $0.status == .running }.map(\.sessionID)
        return Self.decoratedMultiWaitInterruptValue(
            sessionIDs: sessionIDs,
            representativeSnapshot: triggeringSnapshot,
            snapshots: snapshots,
            pendingSessionIDs: pendingIDs.isEmpty && !runningIDs.isEmpty ? runningIDs : pendingIDs,
            interruptedSessionID: triggeringSnapshot.sessionID
        )
    }

    private nonisolated static func decoratedMultiWaitInterruptValue(
        sessionIDs: [UUID],
        representativeSnapshot: AgentRunMCPSnapshot,
        snapshots: [AgentRunMCPSnapshot],
        pendingSessionIDs: [UUID],
        interruptedSessionID: UUID
    ) -> Value {
        var object = representativeSnapshot.asObject()
        object.removeValue(forKey: "assistant_text")
        object["status_text"] = .string("Wait interrupted by a new steering instruction; the agent run is still running.")
        object["_meta"] = .object([
            "wake_reason": .string(AgentRunSessionStore.WakeReason.steeringRequested.rawValue),
            "note": .string(agentRunSteeringWakeNote)
        ])
        object["wait"] = .object([
            "mode": .string("any"),
            "result": .string("interrupted_by_steering"),
            "winner_session_id": .null,
            "interrupted_session_id": .string(interruptedSessionID.uuidString),
            "session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
            "waited_count": .int(sessionIDs.count),
            "pending_session_ids": .array(pendingSessionIDs.map { .string($0.uuidString) }),
            "instruction": .string(agentRunSteeringWakeNote)
        ])
        object["snapshots"] = .array(snapshots.map { snapshot in
            var snapshotObject = snapshot.asObject()
            if !snapshot.status.isTerminal {
                snapshotObject.removeValue(forKey: "assistant_text")
            }
            return .object(snapshotObject)
        })
        return .object(object)
    }

    private nonisolated func waitForAnyInterestingState(
        sessionIDs: [UUID],
        agentModeVM: AgentModeViewModel,
        timeoutSeconds: TimeInterval,
        initialSnapshots: [AgentRunMCPSnapshot]
    ) async throws -> Value {
        let cursors = await MainActor.run {
            sessionIDs.compactMap { agentModeVM.mcpWaitCursor(sessionID: $0) }
        }
        guard !cursors.isEmpty else {
            return decoratedMultiWaitValue(
                snapshot: AgentRunMCPSnapshot.expired(sessionID: sessionIDs[0]),
                sessionIDs: sessionIDs,
                result: "expired",
                pendingSessionIDs: sessionIDs
            )
        }
        let result = await Self.waitUntilFirstActionable(
            cursors: cursors,
            fallbackSessionID: sessionIDs[0],
            timeoutSeconds: timeoutSeconds
        )
        let snapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        switch result.disposition {
        case let .actionable(snapshot):
            return decoratedMultiWaitValue(
                snapshot: snapshot,
                sessionIDs: sessionIDs,
                result: snapshot.status == .expired ? "expired" : "snapshot_ready",
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs(from: snapshots).filter { $0 != snapshot.sessionID }
            )
        case let .steeringInterrupted(snapshot):
            return await waitAnySteeringInterruptValue(
                sessionIDs: sessionIDs,
                agentModeVM: agentModeVM,
                triggeringSnapshot: snapshot,
                latestSnapshots: snapshots
            )
        case let .superseded(snapshot):
            return decoratedMultiWaitSupersededValue(
                snapshot: snapshot,
                sessionIDs: sessionIDs,
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs(from: snapshots)
            )
        case let .terminalPublicationRejected(reason):
            throw MCPError.internalError("An agent run terminal state could not be published: \(reason)")
        case .timedOut:
            return decoratedMultiWaitValue(
                snapshot: snapshots.first ?? initialSnapshots[0],
                sessionIDs: sessionIDs,
                result: "timed_out",
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs(from: snapshots)
            )
        case .expired:
            return decoratedMultiWaitValue(
                snapshot: AgentRunMCPSnapshot.expired(sessionID: result.sessionID),
                sessionIDs: sessionIDs,
                result: "expired",
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs(from: snapshots)
            )
        case .cancelled:
            if let value = await waitAnyCancellationValueIfActionable(
                sessionIDs: sessionIDs,
                agentModeVM: agentModeVM,
                fallbackSnapshots: snapshots
            ) {
                return value
            }
            throw CancellationError()
        }
    }

    private nonisolated static func waitUntilFirstActionable(
        cursors: [AgentRunSessionStore.WaitCursor],
        fallbackSessionID: UUID,
        timeoutSeconds: TimeInterval
    ) async -> WaitAnyResult {
        let operations: [@Sendable () async -> WaitAnyResult] = cursors.map { cursor in
            { await Self.waitUntilActionable(cursor: cursor, timeoutSeconds: timeoutSeconds) }
        }
        return await resolveFirstWaitAny(
            operations: operations,
            sessionOrder: cursors.map(\.registration.sessionID),
            fallbackSessionID: fallbackSessionID
        )
    }

    private nonisolated static func resolveFirstWaitAny(
        operations: [@Sendable () async -> WaitAnyResult],
        sessionOrder: [UUID],
        fallbackSessionID: UUID,
        afterCancelAll: (@Sendable () async -> Void)? = nil
    ) async -> WaitAnyResult {
        let clock = ContinuousClock()
        return await withTaskGroup(of: TimestampedWaitAnyResult.self) { group in
            for operation in operations {
                group.addTask {
                    let result = await operation()
                    return TimestampedWaitAnyResult(result: result, completedAt: clock.now)
                }
            }
            guard let first = await group.next() else {
                return WaitAnyResult(sessionID: fallbackSessionID, disposition: .expired)
            }
            let cutoff = clock.now
            var resolvedResults = [first.result]
            group.cancelAll()
            await afterCancelAll?()
            while let candidate = await group.next() {
                guard candidate.completedAt <= cutoff else { continue }
                resolvedResults.append(candidate.result)
            }
            return Self.arbitrateWaitAnyResults(
                resolvedResults,
                sessionOrder: sessionOrder,
                fallbackSessionID: fallbackSessionID
            )
        }
    }

    private nonisolated static func waitUntilActionable(
        cursor initialCursor: AgentRunSessionStore.WaitCursor,
        timeoutSeconds: TimeInterval
    ) async -> WaitAnyResult {
        let sessionID = initialCursor.registration.sessionID
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        var cursor = initialCursor
        while true {
            if Task.isCancelled {
                return WaitAnyResult(sessionID: sessionID, disposition: .cancelled)
            }
            let remaining = timeInterval(from: clock.now.duration(to: deadline))
            guard remaining > 0 else {
                return WaitAnyResult(sessionID: sessionID, disposition: .timedOut)
            }
            let disposition = await AgentRunSessionStore.waitUntilInteresting(
                cursor: cursor,
                timeoutSeconds: remaining
            )
            switch disposition {
            case let .snapshotReady(snapshot):
                if snapshot.isActionableForMCPWait {
                    return WaitAnyResult(sessionID: sessionID, disposition: .actionable(snapshot))
                }
            case let .noteworthySnapshot(snapshot, reason):
                if snapshot.isActionableForMCPWait {
                    return WaitAnyResult(sessionID: sessionID, disposition: .actionable(snapshot))
                }
                if reason == .steeringRequested {
                    return WaitAnyResult(sessionID: sessionID, disposition: .steeringInterrupted(snapshot))
                }
            case let .epochAdvanced(epoch, transitionKind):
                if transitionKind == .unrelated {
                    let snapshot = await AgentRunSessionStore.snapshot(
                        for: .init(registration: cursor.registration, epoch: epoch)
                    ) ?? AgentRunMCPSnapshot.expired(sessionID: sessionID)
                    return WaitAnyResult(sessionID: sessionID, disposition: .superseded(snapshot))
                }
                cursor = .init(registration: cursor.registration, epoch: epoch)
            case let .terminalPublicationRejected(_, reason):
                return WaitAnyResult(sessionID: sessionID, disposition: .terminalPublicationRejected(reason))
            case .timedOut:
                return WaitAnyResult(sessionID: sessionID, disposition: .timedOut)
            case .expired:
                return WaitAnyResult(sessionID: sessionID, disposition: .expired)
            case .cancelled:
                return WaitAnyResult(sessionID: sessionID, disposition: .cancelled)
            }
        }
    }

    private nonisolated static func arbitrateWaitAnyResults(
        _ results: [WaitAnyResult],
        sessionOrder: [UUID],
        fallbackSessionID: UUID
    ) -> WaitAnyResult {
        guard !results.isEmpty else {
            return WaitAnyResult(sessionID: fallbackSessionID, disposition: .expired)
        }
        let order = Dictionary(uniqueKeysWithValues: sessionOrder.enumerated().map { ($1, $0) })
        return results.min { lhs, rhs in
            let lhsPriority = arbitrationPriority(lhs.disposition)
            let rhsPriority = arbitrationPriority(rhs.disposition)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return order[lhs.sessionID, default: Int.max] < order[rhs.sessionID, default: Int.max]
        } ?? results[0]
    }

    private nonisolated static func arbitrationPriority(_ disposition: MultiWaitDisposition) -> Int {
        switch disposition {
        case .terminalPublicationRejected:
            0
        case .steeringInterrupted:
            1
        case .actionable:
            2
        case .superseded:
            3
        case .expired:
            4
        case .timedOut:
            5
        case .cancelled:
            6
        }
    }

    #if DEBUG
        static func test_decoratedMultiWaitInterruptValue(
            sessionIDs: [UUID],
            representativeSnapshot: AgentRunMCPSnapshot? = nil,
            snapshots: [AgentRunMCPSnapshot],
            pendingSessionIDs: [UUID],
            interruptedSessionID: UUID
        ) -> Value {
            decoratedMultiWaitInterruptValue(
                sessionIDs: sessionIDs,
                representativeSnapshot: representativeSnapshot
                    ?? snapshots.first { $0.sessionID == interruptedSessionID }
                    ?? AgentRunMCPSnapshot.expired(sessionID: interruptedSessionID),
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs,
                interruptedSessionID: interruptedSessionID
            )
        }

        static func test_waitAnyCutoffExcludesPostCancellationSteering(
            actionableSessionID: UUID,
            steeringSessionID: UUID
        ) async -> (sessionID: UUID, disposition: String) {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            let operations: [@Sendable () async -> WaitAnyResult] = [
                {
                    WaitAnyResult(
                        sessionID: actionableSessionID,
                        disposition: .actionable(.expired(sessionID: actionableSessionID))
                    )
                },
                {
                    for await _ in stream {
                        break
                    }
                    return WaitAnyResult(
                        sessionID: steeringSessionID,
                        disposition: .steeringInterrupted(.expired(sessionID: steeringSessionID))
                    )
                }
            ]
            let result = await resolveFirstWaitAny(
                operations: operations,
                sessionOrder: [actionableSessionID, steeringSessionID],
                fallbackSessionID: actionableSessionID,
                afterCancelAll: {
                    continuation.yield()
                    continuation.finish()
                }
            )
            let disposition = switch result.disposition {
            case .actionable: "actionable"
            case .steeringInterrupted: "steering_interrupted"
            default: "other"
            }
            return (result.sessionID, disposition)
        }

        static func test_expiredWaitValue(sessionID: UUID) -> Value {
            expiredWaitValue(sessionID: sessionID)
        }

        static func test_waitUntilActionableDisposition(
            sessionID: UUID,
            timeoutSeconds: TimeInterval
        ) async -> (disposition: String, wakeReason: String?, sessionID: UUID, snapshotStatus: String?) {
            guard let registration = await AgentRunSessionStore.currentRegistration(for: sessionID),
                  let cursor = await AgentRunSessionStore.currentCursor(for: registration)
            else {
                return ("expired", nil, sessionID, nil)
            }
            let result = await waitUntilActionable(cursor: cursor, timeoutSeconds: timeoutSeconds)
            switch result.disposition {
            case let .actionable(snapshot):
                return ("actionable", nil, result.sessionID, snapshot.status.rawValue)
            case let .steeringInterrupted(snapshot):
                return (
                    "steering_interrupted",
                    AgentRunSessionStore.WakeReason.steeringRequested.rawValue,
                    result.sessionID,
                    snapshot.status.rawValue
                )
            case let .superseded(snapshot):
                return ("superseded", "superseded_turn", result.sessionID, snapshot.status.rawValue)
            case .terminalPublicationRejected:
                return ("publication_rejected", nil, result.sessionID, nil)
            case .timedOut:
                return ("timed_out", nil, result.sessionID, nil)
            case .expired:
                return ("expired", nil, result.sessionID, nil)
            case .cancelled:
                return ("cancelled", nil, result.sessionID, nil)
            }
        }

        static func test_waitUntilFirstActionableDisposition(
            sessionIDs: [UUID],
            timeoutSeconds: TimeInterval
        ) async -> (sessionID: UUID, disposition: String) {
            var cursors: [AgentRunSessionStore.WaitCursor] = []
            for sessionID in sessionIDs {
                guard let registration = await AgentRunSessionStore.currentRegistration(for: sessionID),
                      let cursor = await AgentRunSessionStore.currentCursor(for: registration)
                else { continue }
                cursors.append(cursor)
            }
            let result = await waitUntilFirstActionable(
                cursors: cursors,
                fallbackSessionID: sessionIDs[0],
                timeoutSeconds: timeoutSeconds
            )
            let disposition = switch result.disposition {
            case .terminalPublicationRejected: "publication_rejected"
            case .steeringInterrupted: "steering_interrupted"
            case .actionable: "actionable"
            case .superseded: "superseded"
            case .expired: "expired"
            case .timedOut: "timed_out"
            case .cancelled: "cancelled"
            }
            return (result.sessionID, disposition)
        }

        static func test_arbitrateWaitAnyDisposition(
            sessionIDs: [UUID],
            candidates: [(sessionID: UUID, disposition: String)]
        ) -> (sessionID: UUID, disposition: String) {
            let results = candidates.compactMap { candidate -> WaitAnyResult? in
                let snapshot = AgentRunMCPSnapshot.expired(sessionID: candidate.sessionID)
                let disposition: MultiWaitDisposition
                switch candidate.disposition {
                case "publication_rejected":
                    disposition = .terminalPublicationRejected("test")
                case "steering_interrupted":
                    disposition = .steeringInterrupted(snapshot)
                case "actionable":
                    disposition = .actionable(snapshot)
                case "superseded":
                    disposition = .superseded(snapshot)
                case "expired":
                    disposition = .expired
                case "timed_out":
                    disposition = .timedOut
                case "cancelled":
                    disposition = .cancelled
                default:
                    return nil
                }
                return WaitAnyResult(sessionID: candidate.sessionID, disposition: disposition)
            }
            let fallbackSessionID = sessionIDs.first ?? candidates.first?.sessionID ?? UUID()
            let result = arbitrateWaitAnyResults(
                results,
                sessionOrder: sessionIDs,
                fallbackSessionID: fallbackSessionID
            )
            let disposition = switch result.disposition {
            case .terminalPublicationRejected: "publication_rejected"
            case .steeringInterrupted: "steering_interrupted"
            case .actionable: "actionable"
            case .superseded: "superseded"
            case .expired: "expired"
            case .timedOut: "timed_out"
            case .cancelled: "cancelled"
            }
            return (result.sessionID, disposition)
        }
    #endif

    private nonisolated static func timeInterval(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private nonisolated func waitScopeCompletion(from value: Value, fallbackSessionIDs: [UUID]) -> AgentRunWaitScopeCompletion {
        let object = value.objectValue
        let wait = object?["wait"]?.objectValue
        let result = wait?["result"]?.stringValue
        let winnerSessionID = wait?["winner_session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let pendingSessionIDs = Set(wait?["pending_session_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? fallbackSessionIDs)
        let reason: AgentRunWaitScopeCompletion.Reason = switch result {
        case "timed_out": .timedOut
        case "expired": .expired
        case "superseded": .superseded
        case "cancelled", "interrupted_by_steering": .cancelled
        case "error": .error
        default: .snapshotReady
        }
        return AgentRunWaitScopeCompletion(
            reason: reason,
            result: result,
            winnerSessionID: winnerSessionID,
            pendingSessionIDs: pendingSessionIDs,
            errorDescription: nil
        )
    }

    private nonisolated func singleWaitScopeCompletion(from value: Value, sessionID: UUID) -> AgentRunWaitScopeCompletion {
        let status = value.objectValue?["status"]?.stringValue.flatMap(AgentRunMCPSnapshot.Status.init(rawValue:))
        let reason: AgentRunWaitScopeCompletion.Reason = status == .expired ? .expired : .snapshotReady
        return AgentRunWaitScopeCompletion(
            reason: reason,
            result: reason.rawValue,
            winnerSessionID: status == .expired ? nil : sessionID,
            pendingSessionIDs: [],
            errorDescription: nil
        )
    }

    private func decoratedRunValue(
        snapshot: AgentRunMCPSnapshot,
        workflow: AgentWorkflowDefinition? = nil,
        delivery: AgentModeViewModel.MCPInstructionDispatch? = nil,
        wakeReason: AgentRunSessionStore.WakeReason? = nil,
        warning: String? = nil
    ) -> Value {
        var object = snapshot.asObject()
        if let warning = warning?.trimmingCharacters(in: .whitespacesAndNewlines), !warning.isEmpty {
            object["warning"] = .string(warning)
        }
        if let workflow {
            object["workflow_id"] = .string(workflow.id)
            object["workflow_name"] = .string(workflow.displayName)
        }
        if let meta = metadataObject(for: snapshot, delivery: delivery, wakeReason: wakeReason) {
            object["_meta"] = .object(meta)
        }
        // After a steer dispatch into an active run, the assistant_text is from the
        // *previous* turn and would confuse the caller into thinking the steer produced
        // no new output.  Strip it so the caller sees a clean "instruction accepted" response.
        if !snapshot.status.isTerminal,
           delivery?.isActiveRunDispatch == true || wakeReason?.suppressesAssistantPreview == true
        {
            object.removeValue(forKey: "assistant_text")
        }
        if wakeReason == .steeringRequested {
            object["status_text"] = .string("Wait interrupted by a new steering instruction; the agent run is still running.")
            object["wait"] = .object([
                "result": .string("interrupted_by_steering"),
                "instruction": .string(agentRunSteeringWakeNote)
            ])
        }
        return .object(object)
    }

    private nonisolated func decoratedMultiWaitValue(
        snapshot: AgentRunMCPSnapshot,
        sessionIDs: [UUID],
        result: String,
        snapshots: [AgentRunMCPSnapshot]? = nil,
        pendingSessionIDs: [UUID]? = nil
    ) -> Value {
        var object = snapshot.asObject()
        object["_meta"] = .object(["wait_result": .string(result)])
        object["wait"] = .object([
            "mode": .string("any"),
            "result": .string(result),
            "winner_session_id": result == "timed_out" || result == "expired" || result == "superseded"
                ? .null : .string(snapshot.sessionID.uuidString),
            "session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
            "waited_count": .int(sessionIDs.count),
            "pending_session_ids": .array(
                (pendingSessionIDs ?? sessionIDs.filter { $0 != snapshot.sessionID }).map { .string($0.uuidString) }
            ),
            "instruction": .null
        ])
        if let snapshots {
            object["snapshots"] = .array(snapshots.map { .object($0.asObject()) })
        }
        return .object(object)
    }

    private nonisolated func decoratedMultiWaitSupersededValue(
        snapshot: AgentRunMCPSnapshot,
        sessionIDs: [UUID],
        snapshots: [AgentRunMCPSnapshot],
        pendingSessionIDs: [UUID]
    ) -> Value {
        let value = decoratedMultiWaitValue(
            snapshot: snapshot,
            sessionIDs: sessionIDs,
            result: "superseded",
            snapshots: snapshots,
            pendingSessionIDs: pendingSessionIDs
        )
        guard var object = value.objectValue else { return value }
        var meta = object["_meta"]?.objectValue ?? [:]
        meta["wake_reason"] = .string("superseded_turn")
        object["_meta"] = .object(meta)
        return .object(object)
    }

    private nonisolated func decoratedMultiPollValue(
        sessionIDs: [UUID],
        snapshots: [AgentRunMCPSnapshot]
    ) -> Value {
        let interestingIDs = snapshots.filter { isInterestingSnapshot($0) }.map(\.sessionID)
        let runningIDs = snapshots.filter { $0.status == .running }.map(\.sessionID)
        let terminalIDs = snapshots.filter(\.status.isTerminal).map(\.sessionID)
        return .object([
            "poll": .object([
                "mode": .string("many"),
                "session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
                "polled_count": .int(sessionIDs.count),
                "interesting_session_ids": .array(interestingIDs.map { .string($0.uuidString) }),
                "running_session_ids": .array(runningIDs.map { .string($0.uuidString) }),
                "terminal_session_ids": .array(terminalIDs.map { .string($0.uuidString) })
            ]),
            "snapshots": .array(snapshots.map { .object($0.asObject()) })
        ])
    }

    private func metadataObject(
        for snapshot: AgentRunMCPSnapshot,
        delivery: AgentModeViewModel.MCPInstructionDispatch?,
        wakeReason: AgentRunSessionStore.WakeReason?
    ) -> [String: Value]? {
        guard !snapshot.status.isTerminal else { return nil }
        var metadata: [String: Value] = [:]
        if let delivery {
            switch delivery {
            case .queuedFollowUp, .queuedClaudeInterrupt, .queuedACPInterrupt, .deliveredIntoWaitingContinuation, .dispatchedCodexTurn:
                metadata["delivery"] = .string(delivery.rawValue)
            case .startedRun:
                break
            }
        }
        if let wakeReason {
            metadata["wake_reason"] = .string(wakeReason.rawValue)
            if wakeReason == .steeringRequested {
                metadata["note"] = .string(agentRunSteeringWakeNote)
            }
        }
        return metadata.isEmpty ? nil : metadata
    }

    private func wakeReason(from object: [String: Value]) -> AgentRunSessionStore.WakeReason? {
        guard let raw = object["_meta"]?.objectValue?["wake_reason"]?.stringValue else { return nil }
        return AgentRunSessionStore.WakeReason(rawValue: raw)
    }

    private func snapshot(from object: [String: Value]) -> AgentRunMCPSnapshot? {
        guard let sessionIDRaw = object["session_id"]?.stringValue,
              let sessionID = UUID(uuidString: sessionIDRaw),
              let statusRaw = object["status"]?.stringValue,
              let status = AgentRunMCPSnapshot.Status(rawValue: statusRaw)
        else {
            return nil
        }
        let session = object["session"]?.objectValue
        let agent = object["agent"]?.objectValue
        let runID = object["run_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let interaction = object["interaction"]?.objectValue.flatMap(interaction(from:))
        let updatedAt = object["updated_at"]?.stringValue.flatMap(Self.timestampFormatter.date(from:)) ?? Date()
        let tabID = (session?["context_id"] ?? session?["tab_id"])?.stringValue.flatMap(UUID.init(uuidString:))
        let parentSessionID = session?["parent_session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let failureReason = object["failure_reason"]?.stringValue.flatMap(AgentRunMCPSnapshot.FailureReason.init(rawValue:))
        let worktreeBindings = worktreeBindings(from: object)
        let activeWorktreeMerges = activeWorktreeMerges(from: object)
        return AgentRunMCPSnapshot(
            sessionID: sessionID,
            runID: runID,
            tabID: tabID,
            sessionName: session?["name"]?.stringValue,
            agentRaw: agent?["id"]?.stringValue,
            agentDisplayName: agent?["name"]?.stringValue,
            modelRaw: agent?["model"]?.stringValue,
            reasoningEffortRaw: agent?["reasoning_effort"]?.stringValue,
            status: status,
            statusText: object["status_text"]?.stringValue,
            latestAssistantPreview: object["assistant_text"]?.stringValue,
            interaction: interaction,
            transcriptItemCount: object["transcript_item_count"]?.intValue ?? 0,
            updatedAt: updatedAt,
            parentSessionID: parentSessionID,
            failureReason: failureReason,
            worktreeBindings: worktreeBindings,
            activeWorktreeMerges: activeWorktreeMerges
        )
    }

    private func activeWorktreeMerges(from object: [String: Value]) -> [AgentSessionWorktreeMergeSummary] {
        guard let values = object["active_worktree_merges"]?.arrayValue else { return [] }
        return values.compactMap { value in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let statusRaw = object["status"]?.stringValue,
                  let status = AgentSessionWorktreeMergeOperation.Status(rawValue: statusRaw),
                  let repositoryID = object["repository_id"]?.stringValue,
                  let repoKey = object["repo_key"]?.stringValue,
                  let sourceWorktreeID = object["source_worktree_id"]?.stringValue,
                  let sourceLabel = object["source_label"]?.stringValue,
                  let sourcePath = object["source_path"]?.stringValue,
                  let targetWorktreeID = object["target_worktree_id"]?.stringValue,
                  let targetLabel = object["target_label"]?.stringValue,
                  let targetPath = object["target_path"]?.stringValue,
                  let updatedAtRaw = object["updated_at"]?.stringValue,
                  let updatedAt = Self.timestampFormatter.date(from: updatedAtRaw)
            else { return nil }
            return AgentSessionWorktreeMergeSummary(
                id: id,
                status: status,
                sourceWorktreeID: sourceWorktreeID,
                sourceLabel: sourceLabel,
                sourceBranch: object["source_branch"]?.stringValue,
                sourcePath: sourcePath,
                targetWorktreeID: targetWorktreeID,
                targetLabel: targetLabel,
                targetBranch: object["target_branch"]?.stringValue,
                targetPath: targetPath,
                repositoryID: repositoryID,
                repoKey: repoKey,
                conflictFileCount: object["conflict_file_count"]?.intValue ?? 0,
                updatedAt: updatedAt
            )
        }
    }

    private func worktreeBindings(from object: [String: Value]) -> [AgentRunMCPSnapshot.WorktreeBinding] {
        if let values = object["worktree_bindings"]?.arrayValue {
            return values.compactMap { value in
                guard let object = value.objectValue else { return nil }
                return worktreeBinding(from: object)
            }
        }
        if let object = object["worktree"]?.objectValue,
           let binding = worktreeBinding(from: object)
        {
            return [binding]
        }
        return []
    }

    private func worktreeBinding(from object: [String: Value]) -> AgentRunMCPSnapshot.WorktreeBinding? {
        guard let id = object["id"]?.stringValue,
              let repositoryID = object["repository_id"]?.stringValue,
              let repoKey = object["repo_key"]?.stringValue,
              let logicalRootPath = object["logical_root_path"]?.stringValue,
              let worktreeID = object["worktree_id"]?.stringValue,
              let worktreeRootPath = object["worktree_root_path"]?.stringValue,
              let boundAtRaw = object["bound_at"]?.stringValue,
              let boundAt = Self.timestampFormatter.date(from: boundAtRaw),
              let source = object["source"]?.stringValue
        else {
            return nil
        }
        return AgentRunMCPSnapshot.WorktreeBinding(
            id: id,
            repositoryID: repositoryID,
            repoKey: repoKey,
            logicalRootPath: logicalRootPath,
            logicalRootName: object["logical_root_name"]?.stringValue,
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRootPath,
            worktreeName: object["worktree_name"]?.stringValue,
            branch: object["branch"]?.stringValue,
            head: object["head"]?.stringValue,
            visualLabel: object["visual_label"]?.stringValue,
            visualColorHex: object["visual_color_hex"]?.stringValue,
            boundAt: boundAt,
            source: source,
            unavailable: object["unavailable"]?.boolValue ?? false
        )
    }

    private func interaction(from object: [String: Value]) -> AgentRunMCPSnapshot.Interaction? {
        guard let idRaw = object["id"]?.stringValue,
              let id = UUID(uuidString: idRaw),
              let kindRaw = object["kind"]?.stringValue,
              let kind = AgentRunMCPSnapshot.Interaction.Kind(rawValue: kindRaw),
              let responseTypeRaw = object["response_type"]?.stringValue,
              let responseType = AgentRunMCPSnapshot.Interaction.ResponseType(rawValue: responseTypeRaw)
        else {
            return nil
        }
        let options = object["options"]?.arrayValue?.compactMap { option -> AgentRunMCPSnapshot.Interaction.Option? in
            guard let optionObject = option.objectValue,
                  let label = optionObject["label"]?.stringValue else { return nil }
            return .init(label: label, description: optionObject["description"]?.stringValue)
        } ?? []
        let fields = object["fields"]?.arrayValue?.compactMap { field -> AgentRunMCPSnapshot.Interaction.Field? in
            guard let fieldObject = field.objectValue,
                  let id = fieldObject["id"]?.stringValue,
                  let prompt = fieldObject["prompt"]?.stringValue else { return nil }
            let fieldOptions = fieldObject["options"]?.arrayValue?.compactMap { option -> AgentRunMCPSnapshot.Interaction.Option? in
                guard let optionObject = option.objectValue,
                      let label = optionObject["label"]?.stringValue else { return nil }
                return .init(label: label, description: optionObject["description"]?.stringValue)
            } ?? []
            return .init(
                id: id,
                header: fieldObject["header"]?.stringValue,
                prompt: prompt,
                isSecret: fieldObject["is_secret"]?.boolValue == true,
                allowsOther: fieldObject["allows_other"]?.boolValue == true,
                options: fieldOptions
            )
        } ?? []
        let details = object["details"]?.arrayValue?.compactMap { detail -> AgentRunMCPSnapshot.Interaction.Detail? in
            guard let detailObject = detail.objectValue,
                  let label = detailObject["label"]?.stringValue,
                  let value = detailObject["value"]?.stringValue else { return nil }
            return .init(label: label, value: value, isCode: detailObject["is_code"]?.boolValue == true)
        } ?? []
        return .init(
            id: id,
            kind: kind,
            responseType: responseType,
            title: object["title"]?.stringValue,
            prompt: object["prompt"]?.stringValue,
            context: object["context"]?.stringValue,
            allowsMultiple: object["allows_multiple"]?.boolValue,
            options: options,
            fields: fields,
            details: details
        )
    }

    private func collectCurrentSnapshots(sessionIDs: [UUID], agentModeVM: AgentModeViewModel) async -> [AgentRunMCPSnapshot] {
        var snapshots: [AgentRunMCPSnapshot] = []
        snapshots.reserveCapacity(sessionIDs.count)
        for sessionID in sessionIDs {
            await snapshots.append(currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM))
        }
        return snapshots
    }

    private nonisolated func isInterestingSnapshot(_ snapshot: AgentRunMCPSnapshot) -> Bool {
        snapshot.isActionableForMCPWait
    }

    private nonisolated func pendingSessionIDs(from snapshots: [AgentRunMCPSnapshot]) -> [UUID] {
        snapshots.filter { !isInterestingSnapshot($0) }.map(\.sessionID)
    }

    private func currentSnapshot(
        sessionID: UUID,
        registration suppliedRegistration: AgentRunSessionStore.Registration? = nil,
        agentModeVM: AgentModeViewModel
    ) async -> AgentRunMCPSnapshot {
        let registration = suppliedRegistration ?? agentModeVM.mcpRegistration(sessionID: sessionID)
        let storedSnapshot: AgentRunMCPSnapshot? = if let registration {
            await AgentRunSessionStore.snapshot(for: registration)
        } else {
            nil
        }
        if let storedSnapshot, storedSnapshot.status.isTerminal {
            return storedSnapshot
        }
        if let providedSnapshot = await currentSnapshotProvider?(sessionID, agentModeVM) {
            return providedSnapshot
        }
        guard let registration else {
            return .expired(sessionID: sessionID)
        }
        if let liveSnapshot = agentModeVM.mcpSnapshot(registration: registration) {
            return liveSnapshot
        }
        if let storedSnapshot {
            return storedSnapshot
        }
        return .expired(sessionID: sessionID)
    }

    private func resolveSessionID(reference: String?, workspace: WorkspaceModel, agentModeVM: AgentModeViewModel) async throws -> UUID? {
        guard let reference else { return nil }
        guard let sessionID = try await agentModeVM.mcpResolveSessionID(reference: reference, workspace: workspace) else {
            throw MCPError.invalidParams("Session '\(reference)' was not found in the active workspace.")
        }
        return sessionID
    }

    private func resolveWorkflow(args: [String: Value]) throws -> AgentWorkflowDefinition? {
        let workflowID = normalizedString(args["workflow_id"])
        let workflowName = normalizedString(args["workflow_name"])
        if workflowID != nil, workflowName != nil {
            throw MCPError.invalidParams("Specify either workflow_id or workflow_name, not both.")
        }
        guard let reference = workflowID ?? workflowName else {
            return nil
        }
        guard let workflow = AgentWorkflowStore.shared.resolveWorkflowReference(reference) else {
            throw MCPError.invalidParams("Workflow '\(reference)' was not found.")
        }
        return workflow
    }

    private func resolveMessage(_ value: Value?, name: String) throws -> String {
        let message = normalizedString(value) ?? ""
        guard !message.isEmpty else {
            throw MCPError.invalidParams("\(name) is required.")
        }
        return message
    }

    private struct ParsedAnswers {
        let flat: [String: [String]]
        let structured: [String: AgentAskUserAnswer]
        let hasStructuredObjects: Bool
    }

    private func parseResponsePayload(args: [String: Value]) throws -> AgentModeViewModel.MCPInteractionResponsePayload {
        let parsedAnswers: ParsedAnswers = if let rawAnswers = args["answers"] {
            try parseAnswers(rawAnswers)
        } else {
            ParsedAnswers(flat: [:], structured: [:], hasStructuredObjects: false)
        }

        let responseRaw = normalizedString(args["response"])
        let explicitSkip: Bool
        if let skipValue = args["skip"] {
            guard let skipBool = skipValue.boolValue else {
                throw MCPError.invalidParams("skip must be a boolean.")
            }
            explicitSkip = skipBool
        } else {
            explicitSkip = false
        }
        let responseIsSkipSentinel = responseRaw?.lowercased() == "skip"
        let isSkip = explicitSkip || responseIsSkipSentinel
        if isSkip, !parsedAnswers.flat.isEmpty || !parsedAnswers.structured.isEmpty {
            throw MCPError.invalidParams("skip cannot be combined with answers.")
        }
        if explicitSkip, responseRaw != nil, !responseIsSkipSentinel {
            throw MCPError.invalidParams("skip cannot be combined with response.")
        }
        let decisionRaw = responseRaw

        let content = try parseAgentJSONObject(args["content"], name: "content")
        let meta = try parseAgentJSONObject(args["meta"] ?? args["_meta"], name: "meta")

        return AgentModeViewModel.MCPInteractionResponsePayload(
            text: responseRaw,
            skip: isSkip,
            explicitSkip: explicitSkip,
            decisionRaw: isSkip ? nil : decisionRaw,
            amendment: normalizedString(args["amendment"]),
            answersByQuestionID: parsedAnswers.flat,
            askUserAnswersByQuestionID: parsedAnswers.structured,
            hasStructuredAnswerObjects: parsedAnswers.hasStructuredObjects,
            elicitationActionRaw: isSkip ? nil : responseRaw,
            elicitationContent: content,
            elicitationMeta: meta
        )
    }

    private func parseAgentJSONObject(_ value: Value?, name: String) throws -> [String: AgentJSONValue] {
        guard let value else { return [:] }
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("\(name) must be an object.")
        }
        return try object.reduce(into: [String: AgentJSONValue]()) { partialResult, entry in
            partialResult[entry.key] = try agentJSONValue(from: entry.value)
        }
    }

    private func agentJSONValue(from value: Value) throws -> AgentJSONValue {
        switch value {
        case .null:
            return .null
        case let .bool(boolValue):
            return .bool(boolValue)
        case let .int(intValue):
            return .int(intValue)
        case let .double(doubleValue):
            return .double(doubleValue)
        case let .string(stringValue):
            return .string(stringValue)
        case let .array(values):
            return try .array(values.map { try agentJSONValue(from: $0) })
        case let .object(object):
            return try .object(object.reduce(into: [String: AgentJSONValue]()) { partialResult, entry in
                partialResult[entry.key] = try agentJSONValue(from: entry.value)
            })
        default:
            throw MCPError.invalidParams("Unsupported JSON value in MCP response payload.")
        }
    }

    private func parseAnswers(_ value: Value) throws -> ParsedAnswers {
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("answers must be an object keyed by question ID.")
        }
        var flat = [String: [String]]()
        var structured = [String: AgentAskUserAnswer]()
        var hasStructuredObjects = false
        for entry in object {
            let questionID = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !questionID.isEmpty else {
                throw MCPError.invalidParams("answers cannot contain an empty question ID.")
            }

            if entry.value.objectValue != nil {
                hasStructuredObjects = true
            }
            let parsed = try parseAnswerValue(entry.value, questionID: questionID)
            flat[questionID] = parsed.answers
            structured[questionID] = parsed
        }
        return ParsedAnswers(flat: flat, structured: structured, hasStructuredObjects: hasStructuredObjects)
    }

    private func parseAnswerValue(_ value: Value, questionID: String) throws -> AgentAskUserAnswer {
        if let answer = value.stringValue {
            return AgentAskUserAnswer(
                answers: [answer],
                selectedOptions: [],
                customResponse: nil,
                skipped: false
            )
        }
        if let answerArray = value.arrayValue {
            let answers = try parseAnswerStringArray(answerArray, name: "answers['\(questionID)']")
            return AgentAskUserAnswer(
                answers: answers,
                selectedOptions: [],
                customResponse: nil,
                skipped: false
            )
        }
        guard let answerObject = value.objectValue else {
            throw MCPError.invalidParams("answers['\(questionID)'] must be a string, array of strings, or object.")
        }

        let skipped = answerObject["skipped"]?.boolValue == true || answerObject["skip"]?.boolValue == true
        let selectedOptions = try parseOptionalAnswerStrings(
            answerObject["selected_options"] ?? answerObject["selectedOptions"],
            name: "answers['\(questionID)'].selected_options"
        ) ?? []
        let customResponse = normalizedString(answerObject["custom_response"] ?? answerObject["customResponse"])
        let explicitAnswers = try parseOptionalAnswerStrings(
            answerObject["answers"],
            name: "answers['\(questionID)'].answers"
        )

        let answers: [String] = if let explicitAnswers {
            explicitAnswers
        } else {
            selectedOptions + (customResponse.map { [$0] } ?? [])
        }

        if skipped {
            let hasAnswerContent = !answers.isEmpty || !selectedOptions.isEmpty || customResponse != nil
            guard !hasAnswerContent else {
                throw MCPError.invalidParams("answers['\(questionID)'] cannot be skipped and answered at the same time.")
            }
            return AgentAskUserAnswer(answers: [], selectedOptions: [], customResponse: nil, skipped: true)
        }

        return AgentAskUserAnswer(
            answers: answers,
            selectedOptions: selectedOptions,
            customResponse: customResponse,
            skipped: false
        )
    }

    private func parseOptionalAnswerStrings(_ value: Value?, name: String) throws -> [String]? {
        guard let value else { return nil }
        if let answer = value.stringValue {
            return [answer]
        }
        guard let answerArray = value.arrayValue else {
            throw MCPError.invalidParams("\(name) must be a string or array of strings.")
        }
        return try parseAnswerStringArray(answerArray, name: name)
    }

    private func parseAnswerStringArray(_ values: [Value], name: String) throws -> [String] {
        try values.map { element -> String in
            guard let text = element.stringValue else {
                throw MCPError.invalidParams("\(name) must contain only strings.")
            }
            return text
        }
    }

    /// Resolves session_id for control operations (poll/wait/cancel/steer/respond).
    /// Accepts both full UUIDs and short IDs for a uniform caller experience.
    private func resolveControlSessionID(
        reference raw: String,
        targetWindow: WindowState,
        agentModeVM: AgentModeViewModel
    ) async throws -> UUID {
        if let uuid = UUID(uuidString: raw) {
            return uuid
        }
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available to resolve session_id '\(raw)'.")
        }
        guard let resolved = try await agentModeVM.mcpResolveSessionID(reference: raw, workspace: workspace) else {
            throw MCPError.invalidParams("Session '\(raw)' was not found. Provide a full UUID or a valid short ID.")
        }
        return resolved
    }

    private func resolveControlSessionID(
        _ args: [String: Value],
        targetWindow: WindowState,
        agentModeVM: AgentModeViewModel
    ) async throws -> UUID {
        guard let raw = normalizedString(args["session_id"]) else {
            throw MCPError.invalidParams("session_id is required for agent_run control operations.")
        }
        return try await resolveControlSessionID(reference: raw, targetWindow: targetWindow, agentModeVM: agentModeVM)
    }

    private func parseSessionIDArray(_ args: [String: Value]) throws -> [String] {
        if normalizedString(args["session_id"]) != nil {
            throw MCPError.invalidParams("Specify either session_id or session_ids, not both.")
        }
        guard let raw = args["session_ids"] else {
            throw MCPError.invalidParams("session_ids is required for multi-session wait.")
        }
        guard let values = raw.arrayValue, !values.isEmpty else {
            throw MCPError.invalidParams("session_ids must be a non-empty array of session IDs.")
        }
        return try values.map { value -> String in
            guard let reference = normalizedString(value) else {
                throw MCPError.invalidParams("session_ids must contain only non-empty strings.")
            }
            return reference
        }
    }

    private func resolveControlSessionIDs(
        _ references: [String],
        targetWindow: WindowState,
        agentModeVM: AgentModeViewModel
    ) async throws -> [UUID] {
        var resolved: [UUID] = []
        var seen: Set<UUID> = []
        for reference in references {
            let sessionID = try await resolveControlSessionID(
                reference: reference,
                targetWindow: targetWindow,
                agentModeVM: agentModeVM
            )
            if seen.insert(sessionID).inserted {
                resolved.append(sessionID)
            }
        }
        guard !resolved.isEmpty else {
            throw MCPError.invalidParams("session_ids did not resolve to any sessions.")
        }
        return resolved
    }

    private func requireUUID(_ value: Value?, name: String) throws -> UUID {
        guard let raw = normalizedString(value), let uuid = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("\(name) must be a UUID string.")
        }
        return uuid
    }

    private func requireNonEmptyString(_ value: Value?, name: String) throws -> String {
        guard let normalized = normalizedString(value), !normalized.isEmpty else {
            throw MCPError.invalidParams("\(name) is required.")
        }
        return normalized
    }

    private func normalizedString(_ value: Value?) -> String? {
        let trimmed = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseBool(_ value: Value?) -> Bool? {
        switch value {
        case let .bool(boolValue):
            boolValue
        case let .string(stringValue):
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                true
            case "false", "0", "no":
                false
            default:
                nil
            }
        case let .int(intValue):
            intValue != 0
        case let .double(doubleValue):
            doubleValue != 0
        case .null, .array(_), .object:
            nil
        default:
            nil
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension AgentRunSessionStore.WakeReason {
    var suppressesAssistantPreview: Bool {
        switch self {
        case .instructionDelivered, .steeringRequested:
            true
        }
    }
}
