import Foundation

extension SentryTelemetryBootstrap {
    enum Category: String, CaseIterable {
        case agentMessage = "agent.message"
        case agentRun = "agent.run"
        case agentTool = "agent.tool"
        case agentRuntime = "agent.runtime"
        case appLifecycle = "app.lifecycle"
        case contextBuilderAction = "context_builder.action"
        case mcpBootstrap = "mcp.bootstrap"
        case mcpTool = "mcp.tool"
        case persistenceAction = "persistence.action"
        case workspaceAction = "workspace.action"
        case workspaceTool = "workspace.tool"
    }

    enum Action: String, CaseIterable {
        case agentMessageObserved = "agent.message.observed"
        case agentRunCancelled = "agent.run.cancelled"
        case agentRunCompleted = "agent.run.completed"
        case agentRunFailed = "agent.run.failed"
        case agentRunStarted = "agent.run.started"
        case agentProviderError = "agent.provider.error"
        case agentRuntimeRecoveryFailed = "agent.runtime.recovery.failed"
        case agentRuntimeRecoveryRecovered = "agent.runtime.recovery.recovered"
        case agentRuntimeRecoverySkipped = "agent.runtime.recovery.skipped"
        case agentRuntimeRecoveryStarted = "agent.runtime.recovery.started"
        case agentRuntimeStallProbeTriggered = "agent.runtime.stall_probe.triggered"
        case agentRuntimeStallWarningShown = "agent.runtime.stall_warning.shown"
        case agentRuntimeTransportClosed = "agent.runtime.transport_closed"
        case agentToolCompleted = "agent.tool.completed"
        case agentToolFailed = "agent.tool.failed"
        case agentToolStarted = "agent.tool.started"
        case appInitialized = "app.initialized"
        case contextBuilderCompleted = "context_builder.completed"
        case contextBuilderFailed = "context_builder.failed"
        case contextBuilderStarted = "context_builder.started"
        case mcpBootstrapAccepted = "mcp.bootstrap.accepted"
        case mcpBootstrapRejected = "mcp.bootstrap.rejected"
        case mcpServerStarted = "mcp.server.started"
        case mcpToolCancelled = "mcp.tool.cancelled"
        case mcpToolCompleted = "mcp.tool.completed"
        case mcpToolFailed = "mcp.tool.failed"
        case mcpToolStarted = "mcp.tool.started"
        case mcpToolTimedOut = "mcp.tool.timed_out"
        case persistenceCompleted = "persistence.completed"
        case persistenceFailed = "persistence.failed"
        case persistenceScheduled = "persistence.scheduled"
        case workspaceActionCompleted = "workspace.action.completed"
        case workspaceActionFailed = "workspace.action.failed"
        case workspaceActionStarted = "workspace.action.started"
    }

    enum Transaction: CaseIterable {
        case agentRun
        case appLaunch
        case contextBuilderRun
        case mcpBootstrapAdmission
        case mcpServerStart
        case mcpToolCall
        case workspaceAction

        var name: String {
            switch self {
            case .agentRun: "agent.run"
            case .appLaunch: "app.launch"
            case .contextBuilderRun: "context_builder.run"
            case .mcpBootstrapAdmission: "mcp.bootstrap.admission"
            case .mcpServerStart: "app.mcp_server.start"
            case .mcpToolCall: "mcp.tool.call"
            case .workspaceAction: "workspace.action"
            }
        }

        var operation: String {
            switch self {
            case .agentRun: "agent.run"
            case .appLaunch, .mcpServerStart: "app.startup"
            case .contextBuilderRun: "context_builder.run"
            case .mcpBootstrapAdmission: "mcp.bootstrap"
            case .mcpToolCall: "mcp.tool.call"
            case .workspaceAction: "workspace.action"
            }
        }

        static var allowedOperations: Set<String> {
            Set(allCases.map(\.operation) + SpanOperation.allCases.map(\.rawValue))
        }
    }

    enum Metric: String, CaseIterable {
        case agentProviderErrors = "agent.provider.errors"
        case agentRunActive = "agent.run.active"
        case agentRunDuration = "agent.run.duration"
        case agentRunSessionStarts = "agent.run.session.starts"
        case agentRuntimeEvents = "agent.runtime.events"
        case mcpExternalSessionStarts = "mcp.external.session.starts"
    }

    enum SpanOperation: String, CaseIterable {
        case agentProviderFirstEvent = "agent.provider.first_event"
        case agentSessionPersist = "agent.session.persist"
        case agentSessionPrepare = "agent.session.prepare"
        case agentTerminalCommit = "agent.terminal_commit"
        case codeMapStructure = "codemap.structure"
        case contextBuilderDiscovery = "context_builder.discovery"
        case contextBuilderExport = "context_builder.export"
        case contextBuilderOracleResponse = "context_builder.oracle.response"
        case contextBuilderSelectionCommit = "context_builder.selection.commit"
        case fileEditApply = "file.edit.apply"
        case fileRead = "file.read"
        case mcpArgumentsNormalize = "mcp.args.normalize"
        case mcpDispatch = "mcp.dispatch"
        case mcpPolicyCheck = "mcp.policy.check"
        case mcpResultFormat = "mcp.result.format"
        case mcpWatchdogWait = "mcp.watchdog.wait"
        case promptRender = "prompt.render"
        case selectionUpdate = "selection.update"
        case workspaceSearch = "workspace.search"
    }

    enum ApprovalKind: String {
        case applyEdits = "apply_edits"
        case commandExecution = "command_execution"
        case fileChange = "file_change"
        case toolPermission = "tool_permission"
        case worktreeMerge = "worktree_merge"
    }

    enum ApprovalOutcome: String { case approved, denied }
    enum CancellationReason: String { case superseded, timeout, user }
    enum ClientClass: String { case externalAgent = "external_agent", inApp = "in_app", unknown }
    enum Entrypoint: String { case agent, app, cli, mcp, user }
    enum ErrorKind: String { case cancelled, error, timeout }
    enum MessageRole: String { case assistant, system, tool, user }

    enum ProviderErrorKind: String {
        case apiError = "api_error"
        case authRequired = "auth_required"
        case cancelled
        case executableUnavailable = "executable_unavailable"
        case invalidConfiguration = "invalid_configuration"
        case invalidResponse = "invalid_response"
        case missingCredential = "missing_credential"
        case missingProviderURL = "missing_provider_url"
        case providerNotConfigured = "provider_not_configured"
        case streamEndedUnexpectedly = "stream_ended_unexpectedly"
        case timeout
        case transportClosed = "transport_closed"
        case unknown
    }

    enum RuntimeEvent: String {
        case codexRecoveryFailed = "codex_recovery_failed"
        case codexRecoveryRecovered = "codex_recovery_recovered"
        case codexRecoverySkipped = "codex_recovery_skipped"
        case codexRecoveryStarted = "codex_recovery_started"
        case codexStallProbeTriggered = "codex_stall_probe_triggered"
        case codexStallWarningShown = "codex_stall_warning_shown"
        case codexTransportClosed = "codex_transport_closed"
    }

    enum ToolDomain: String { case agent, app, context, file, git, mcp, prompt, search, selection, workspace }
    enum WorkspaceAction: String { case create, delete, folder, hide, switchWorkspace = "switch", tab }

    enum ModelFamily: String {
        case claude
        case codex
        case cursor
        case customClaudeCompatible = "custom_claude_compatible"
        case defaultModel = "default"
        case fable
        case glm
        case gpt
        case gpt52 = "gpt_5_2"
        case gpt53Codex = "gpt_5_3_codex"
        case gpt54 = "gpt_5_4"
        case gpt55 = "gpt_5_5"
        case gptMini = "gpt_mini"
        case haiku
        case kimi
        case openCode = "opencode"
        case opus
        case sonnet
    }

    enum ProviderKind: String {
        case claudeCode = "claude_code"
        case claudeCodeGLM = "claude_code_glm"
        case codexExec = "codex_exec"
        case cursor
        case customClaudeCompatible = "custom_claude_compatible"
        case kimiCode = "kimi_code"
        case openCode = "opencode"

        init(agentKind: AgentProviderKind) {
            switch agentKind {
            case .claudeCode:
                self = .claudeCode
            case .codexExec:
                self = .codexExec
            case .openCode:
                self = .openCode
            case .cursor:
                self = .cursor
            case .claudeCodeGLM:
                self = .claudeCodeGLM
            case .kimiCode:
                self = .kimiCode
            case .customClaudeCompatible:
                self = .customClaudeCompatible
            }
        }

        init?(agentKindRaw: String) {
            guard let agentKind = AgentProviderKind(rawValue: agentKindRaw) else { return nil }
            self.init(agentKind: agentKind)
        }
    }

    enum ToolName: String {
        case agentManage = "agent_manage"
        case agentRun = "agent_run"
        case appSettings = "app_settings"
        case applyEdits = "apply_edits"
        case askOracle = "ask_oracle"
        case askUser = "ask_user"
        case bindContext = "bind_context"
        case contextBuilder = "context_builder"
        case fileActions = "file_actions"
        case fileSearch = "file_search"
        case getCodeStructure = "get_code_structure"
        case getFileTree = "get_file_tree"
        case git
        case manageSelection = "manage_selection"
        case manageWorkspaces = "manage_workspaces"
        case manageWorktree = "manage_worktree"
        case oracleChatLog = "oracle_chat_log"
        case oracleSend = "oracle_send"
        case oracleUtils = "oracle_utils"
        case prompt
        case readFile = "read_file"
        case setStatus = "set_status"
        case shareThoughts = "share_thoughts"
        case uploadFile = "upload_file"
        case waitForNextInstruction = "wait_for_next_user_instruction"
        case workspaceContext = "workspace_context"

        init?(rawToolName: String) {
            self.init(rawValue: rawToolName)
        }

        var domain: ToolDomain {
            switch self {
            case .agentManage, .agentRun:
                .agent
            case .appSettings, .askUser, .bindContext, .oracleChatLog, .oracleSend, .oracleUtils, .setStatus,
                 .shareThoughts, .waitForNextInstruction:
                .mcp
            case .applyEdits, .fileActions, .readFile, .uploadFile:
                .file
            case .fileSearch:
                .search
            case .contextBuilder, .getCodeStructure, .getFileTree, .workspaceContext:
                .context
            case .git, .manageWorktree:
                .git
            case .askOracle, .prompt:
                .prompt
            case .manageSelection:
                .selection
            case .manageWorkspaces:
                .workspace
            }
        }
    }

    enum ContextBuilderPhase: String {
        case discovery
        case export
        case oracleResponse = "oracle_response"
        case selectionCommit = "selection_commit"
    }

    enum Outcome: String {
        case accepted
        case cancelled
        case completed
        case failed
        case rejected
        case started
        case timedOut = "timed_out"
    }

    enum TokenBudgetBucket: String {
        case under25K = "under_25k"
        case k25To75 = "25k_75k"
        case k75To150 = "75k_150k"
        case over150K = "over_150k"
        case unknown
    }

    enum Attribute {
        case action(Action)
        case activeHandshakes(Int)
        case attachmentCount(Int)
        case approvalKind(ApprovalKind)
        case approvalOutcome(ApprovalOutcome)
        case cacheHit(Bool)
        case cancellationReason(CancellationReason)
        case clientClass(ClientClass)
        case contextBuilderPhase(ContextBuilderPhase)
        case entrypoint(Entrypoint)
        case hasProviderResumeSession(Bool)
        case errorKind(ErrorKind)
        case isChildSession(Bool)
        case isError(Bool)
        case limitHit(Bool)
        case messageCount(Int)
        case messageRole(MessageRole)
        case modelFamily(ModelFamily)
        case outcome(Outcome)
        case protocolVersion(Int)
        case providerErrorKind(ProviderErrorKind)
        case providerKind(ProviderKind)
        case resultCount(Int)
        case runtimeEvent(RuntimeEvent)
        case selectionFileCount(Int)
        case tokenBudgetBucket(TokenBudgetBucket)
        case toolCallCount(Int)
        case toolDomain(ToolDomain)
        case toolName(ToolName)
        case workspaceAction(WorkspaceAction)

        static let allowedKeys: Set<String> = [
            "action", "active_handshakes", "approval_kind", "approval_outcome", "attachment_count", "cache_hit",
            "cancellation_reason", "client_class", "context_builder_phase", "entrypoint",
            "error_kind", "has_provider_resume_session", "is_child_session", "is_error",
            "limit_hit", "message_count", "message_role", "model_family", "outcome",
            "protocol_version", "provider_error_kind", "provider_kind", "result_count", "runtime_event",
            "selection_file_count", "token_budget_bucket", "tool_call_count", "tool_domain", "tool_name",
            "workspace_action"
        ]

        var key: String {
            switch self {
            case .action: "action"
            case .activeHandshakes: "active_handshakes"
            case .attachmentCount: "attachment_count"
            case .approvalKind: "approval_kind"
            case .approvalOutcome: "approval_outcome"
            case .cacheHit: "cache_hit"
            case .cancellationReason: "cancellation_reason"
            case .clientClass: "client_class"
            case .contextBuilderPhase: "context_builder_phase"
            case .entrypoint: "entrypoint"
            case .hasProviderResumeSession: "has_provider_resume_session"
            case .errorKind: "error_kind"
            case .isChildSession: "is_child_session"
            case .isError: "is_error"
            case .limitHit: "limit_hit"
            case .messageCount: "message_count"
            case .messageRole: "message_role"
            case .modelFamily: "model_family"
            case .outcome: "outcome"
            case .protocolVersion: "protocol_version"
            case .providerErrorKind: "provider_error_kind"
            case .providerKind: "provider_kind"
            case .resultCount: "result_count"
            case .runtimeEvent: "runtime_event"
            case .selectionFileCount: "selection_file_count"
            case .tokenBudgetBucket: "token_budget_bucket"
            case .toolCallCount: "tool_call_count"
            case .toolDomain: "tool_domain"
            case .toolName: "tool_name"
            case .workspaceAction: "workspace_action"
            }
        }

        var value: String? {
            switch self {
            case let .action(action): action.rawValue
            case let .activeHandshakes(count): SentryTelemetryValue.formatCount(count)
            case let .attachmentCount(count): SentryTelemetryValue.formatCount(count)
            case let .approvalKind(kind): kind.rawValue
            case let .approvalOutcome(outcome): outcome.rawValue
            case let .cacheHit(hit): SentryTelemetryValue.formatBool(hit)
            case let .cancellationReason(reason): reason.rawValue
            case let .clientClass(clientClass): clientClass.rawValue
            case let .contextBuilderPhase(phase): phase.rawValue
            case let .entrypoint(entrypoint): entrypoint.rawValue
            case let .hasProviderResumeSession(hasSession): SentryTelemetryValue.formatBool(hasSession)
            case let .errorKind(kind): kind.rawValue
            case let .isChildSession(isChildSession): SentryTelemetryValue.formatBool(isChildSession)
            case let .isError(isError): SentryTelemetryValue.formatBool(isError)
            case let .limitHit(hit): SentryTelemetryValue.formatBool(hit)
            case let .messageCount(count): SentryTelemetryValue.formatCount(count)
            case let .messageRole(role): role.rawValue
            case let .modelFamily(family): family.rawValue
            case let .outcome(outcome): outcome.rawValue
            case let .protocolVersion(version): SentryTelemetryValue.formatCount(version)
            case let .providerErrorKind(kind): kind.rawValue
            case let .providerKind(kind): kind.rawValue
            case let .resultCount(count): SentryTelemetryValue.formatCount(count)
            case let .runtimeEvent(event): event.rawValue
            case let .selectionFileCount(count): SentryTelemetryValue.formatCount(count)
            case let .tokenBudgetBucket(bucket): bucket.rawValue
            case let .toolCallCount(count): SentryTelemetryValue.formatCount(count)
            case let .toolDomain(domain): domain.rawValue
            case let .toolName(name): name.rawValue
            case let .workspaceAction(action): action.rawValue
            }
        }
    }

    static func telemetryData(from attributes: [Attribute]) -> [String: String] {
        var data: [String: String] = [:]
        for attribute in attributes {
            guard let value = attribute.value else { continue }
            data[attribute.key] = value
        }
        return data
    }
}

enum SentryTelemetryValue {
    private static let maxCount = 999_999

    static func formatBool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    static func formatCount(_ value: Int) -> String? {
        guard value >= 0 else { return nil }
        return String(min(value, maxCount))
    }
}
