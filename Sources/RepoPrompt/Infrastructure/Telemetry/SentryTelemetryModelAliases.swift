import RepoPromptInstrumentation

extension SentryTelemetryBootstrap {
    typealias Category = SentryTelemetryModel.Category
    typealias Action = SentryTelemetryModel.Action
    typealias Transaction = SentryTelemetryModel.Transaction
    typealias Metric = SentryTelemetryModel.Metric
    typealias SpanOperation = SentryTelemetryModel.SpanOperation
    typealias ApprovalKind = SentryTelemetryModel.ApprovalKind
    typealias ApprovalOutcome = SentryTelemetryModel.ApprovalOutcome
    typealias CancellationReason = SentryTelemetryModel.CancellationReason
    typealias ClientClass = SentryTelemetryModel.ClientClass
    typealias Entrypoint = SentryTelemetryModel.Entrypoint
    typealias ErrorKind = SentryTelemetryModel.ErrorKind
    typealias MessageRole = SentryTelemetryModel.MessageRole
    typealias ProviderErrorKind = SentryTelemetryModel.ProviderErrorKind
    typealias RuntimeEvent = SentryTelemetryModel.RuntimeEvent
    typealias ToolDomain = SentryTelemetryModel.ToolDomain
    typealias WorkspaceAction = SentryTelemetryModel.WorkspaceAction
    typealias ModelFamily = SentryTelemetryModel.ModelFamily
    typealias ProviderKind = SentryTelemetryModel.ProviderKind
    typealias ToolName = SentryTelemetryModel.ToolName
    typealias ContextBuilderPhase = SentryTelemetryModel.ContextBuilderPhase
    typealias Outcome = SentryTelemetryModel.Outcome
    typealias TokenBudgetBucket = SentryTelemetryModel.TokenBudgetBucket
    typealias Attribute = SentryTelemetryModel.Attribute

    static func telemetryData(from attributes: [Attribute]) -> [String: String] {
        SentryTelemetryModel.telemetryData(from: attributes)
    }
}

extension SentryTelemetryModel.ProviderKind {
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
        case .grokBuild:
            self = .grokBuild
        case .antigravity:
            self = .antigravity
        case .devin:
            self = .devin
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
