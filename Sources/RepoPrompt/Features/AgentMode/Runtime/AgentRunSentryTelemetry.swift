import Foundation

enum AgentRunSentryTelemetry {
    @MainActor private static var observedProviderEventRunKeys: Set<String> = []

    @MainActor
    static func recordStarted(
        session: AgentModeViewModel.TabSession,
        attachments: [AgentImageAttachment]
    ) {
        #if REPOPROMPT_SENTRY_ENABLED
            let attributes = baseAttributes(for: session, outcome: .started)
                + [.attachmentCount(attachments.count)]
            SentryTelemetryBootstrap.addBreadcrumb(
                .agentRun,
                action: .agentRunStarted,
                attributes: attributes
            )
            SentryTelemetryBootstrap.increment(
                .agentRunSessionStarts,
                attributes: attributes
            )
            SentryTelemetryBootstrap.gauge(.agentRunActive, value: 1, attributes: attributes)
        #endif
    }

    @MainActor
    static func recordTerminal(
        session: AgentModeViewModel.TabSession,
        terminalState: AgentSessionRunState
    ) {
        #if REPOPROMPT_SENTRY_ENABLED
            guard let action = action(for: terminalState),
                  let outcome = outcome(for: terminalState)
            else { return }

            let attributes = runSummaryAttributes(for: session, outcome: outcome)
            observedProviderEventRunKeys.remove(providerEventRunKey(for: session))
            SentryTelemetryBootstrap.addBreadcrumb(
                .agentRun,
                action: action,
                attributes: attributes
            )
            SentryTelemetryBootstrap.gauge(.agentRunActive, value: 0, attributes: attributes)
            if let startedAt = session.activeAgentRunStartedAt {
                SentryTelemetryBootstrap.distributionMilliseconds(
                    .agentRunDuration,
                    value: max(0, Date().timeIntervalSince(startedAt) * 1000),
                    attributes: attributes
                )
            }
        #endif
    }

    @MainActor
    static func recordItemAppended(session: AgentModeViewModel.TabSession, item: AgentChatItem) {
        #if REPOPROMPT_SENTRY_ENABLED
            recordProviderFirstEventIfNeeded(session: session)
            recordMessageObserved(session: session, item: item)
            switch item.kind {
            case .toolCall:
                recordToolStarted(session: session, item: item)
            case .toolResult:
                recordToolTerminal(session: session, item: item)
            case .assistant, .assistantInline, .error, .system, .thinking, .user:
                break
            }
        #endif
    }

    @MainActor
    static func recordItemReplaced(
        session: AgentModeViewModel.TabSession,
        previousItem: AgentChatItem,
        updatedItem: AgentChatItem
    ) {
        #if REPOPROMPT_SENTRY_ENABLED
            if previousItem.kind != .toolCall, updatedItem.kind == .toolCall {
                recordToolStarted(session: session, item: updatedItem)
            }
            if previousItem.kind != .toolResult, updatedItem.kind == .toolResult {
                recordToolTerminal(session: session, item: updatedItem)
            }
        #endif
    }

    @MainActor
    static func recordApprovalDecision(
        session: AgentModeViewModel.TabSession,
        kind: SentryTelemetryBootstrap.ApprovalKind,
        outcome: SentryTelemetryBootstrap.ApprovalOutcome,
        cancellationReason: SentryTelemetryBootstrap.CancellationReason? = nil
    ) {
        #if REPOPROMPT_SENTRY_ENABLED
            var attributes = baseAttributes(for: session, outcome: outcome == .approved ? .accepted : .rejected)
            attributes.append(.approvalKind(kind))
            attributes.append(.approvalOutcome(outcome))
            attributes.append(.messageRole(.tool))
            let toolName = toolName(for: kind)
            attributes.append(.toolDomain(toolName.domain))
            attributes.append(.toolName(toolName))
            if let cancellationReason {
                attributes.append(.cancellationReason(cancellationReason))
            }
            SentryTelemetryBootstrap.addBreadcrumb(
                .agentTool,
                action: outcome == .approved ? .agentToolCompleted : .agentToolFailed,
                attributes: attributes
            )
        #endif
    }

    @MainActor
    static func recordRuntimeEvent(
        session: AgentModeViewModel.TabSession,
        event: SentryTelemetryBootstrap.RuntimeEvent,
        action: SentryTelemetryBootstrap.Action,
        outcome: SentryTelemetryBootstrap.Outcome
    ) {
        #if REPOPROMPT_SENTRY_ENABLED
            let attributes = baseAttributes(for: session, outcome: outcome) + [.runtimeEvent(event)]
            SentryTelemetryBootstrap.addBreadcrumb(
                .agentRuntime,
                action: action,
                attributes: attributes
            )
            SentryTelemetryBootstrap.increment(.agentRuntimeEvents, attributes: attributes)
        #endif
    }

    @MainActor
    static func recordProviderError(
        session: AgentModeViewModel.TabSession,
        kind: SentryTelemetryBootstrap.ProviderErrorKind
    ) {
        #if REPOPROMPT_SENTRY_ENABLED
            let attributes = baseAttributes(for: session, outcome: .failed) + [.providerErrorKind(kind)]
            SentryTelemetryBootstrap.addBreadcrumb(
                .agentRuntime,
                action: .agentProviderError,
                attributes: attributes
            )
            SentryTelemetryBootstrap.increment(.agentProviderErrors, attributes: attributes)
        #endif
    }

    @MainActor
    static func recordProviderError(
        session: AgentModeViewModel.TabSession,
        error: Error
    ) {
        #if REPOPROMPT_SENTRY_ENABLED
            recordProviderError(session: session, kind: providerErrorKind(for: error))
        #endif
    }

    #if REPOPROMPT_SENTRY_ENABLED
        @MainActor
        private static func recordProviderFirstEventIfNeeded(session: AgentModeViewModel.TabSession) {
            guard observedProviderEventRunKeys.insert(providerEventRunKey(for: session)).inserted else { return }
            SentryTelemetryBootstrap.span(.agentProviderFirstEvent, attributes: baseAttributes(for: session, outcome: .completed)) {}
        }

        @MainActor
        private static func providerEventRunKey(for session: AgentModeViewModel.TabSession) -> String {
            if let attemptID = session.activeRunOwnership?.attemptID {
                return attemptID.uuidString
            }
            if let runID = session.runID {
                return runID.uuidString
            }
            return session.tabID.uuidString
        }

        @MainActor
        private static func recordMessageObserved(session: AgentModeViewModel.TabSession, item: AgentChatItem) {
            guard let role = messageRole(for: item.kind) else { return }
            SentryTelemetryBootstrap.addBreadcrumb(
                .agentMessage,
                action: .agentMessageObserved,
                attributes: baseAttributes(for: session, outcome: .completed)
                    + [.messageRole(role)]
            )
        }

        @MainActor
        private static func recordToolStarted(session: AgentModeViewModel.TabSession, item: AgentChatItem) {
            let attributes = toolAttributes(for: session, item: item, outcome: .started, isError: false)
            SentryTelemetryBootstrap.addBreadcrumb(
                .agentTool,
                action: .agentToolStarted,
                attributes: attributes
            )
        }

        @MainActor
        private static func recordToolTerminal(session: AgentModeViewModel.TabSession, item: AgentChatItem) {
            let failed = item.toolIsError == true
            let attributes = toolAttributes(
                for: session,
                item: item,
                outcome: failed ? .failed : .completed,
                isError: failed
            )
            SentryTelemetryBootstrap.addBreadcrumb(
                .agentTool,
                action: failed ? .agentToolFailed : .agentToolCompleted,
                attributes: attributes
            )
        }

        @MainActor
        private static func baseAttributes(
            for session: AgentModeViewModel.TabSession,
            outcome: SentryTelemetryBootstrap.Outcome
        ) -> [SentryTelemetryBootstrap.Attribute] {
            [
                .entrypoint(session.mcpControlContext == nil ? .user : .mcp),
                .clientClass(session.mcpControlContext == nil ? .inApp : .externalAgent),
                .providerKind(SentryTelemetryBootstrap.ProviderKind(agentKind: session.selectedAgent)),
                .modelFamily(modelFamily(for: session.selectedAgent, modelRaw: session.selectedModelRaw)),
                .outcome(outcome),
                .isChildSession(session.parentSessionID != nil),
                .hasProviderResumeSession(session.providerSessionID != nil)
            ]
        }

        @MainActor
        private static func runSummaryAttributes(
            for session: AgentModeViewModel.TabSession,
            outcome: SentryTelemetryBootstrap.Outcome
        ) -> [SentryTelemetryBootstrap.Attribute] {
            baseAttributes(for: session, outcome: outcome)
                + [
                    .messageCount(session.items.count),
                    .toolCallCount(session.items.count(where: { $0.kind == .toolCall }))
                ]
        }

        @MainActor
        private static func toolAttributes(
            for session: AgentModeViewModel.TabSession,
            item: AgentChatItem,
            outcome: SentryTelemetryBootstrap.Outcome,
            isError: Bool
        ) -> [SentryTelemetryBootstrap.Attribute] {
            var attributes = baseAttributes(for: session, outcome: outcome)
            attributes.append(.messageRole(.tool))
            attributes.append(.isError(isError))
            if let rawToolName = item.toolName,
               let toolName = SentryTelemetryBootstrap.ToolName(rawToolName: rawToolName)
            {
                attributes.append(.toolName(toolName))
                attributes.append(.toolDomain(toolName.domain))
            }
            return attributes
        }

        private static func action(
            for terminalState: AgentSessionRunState
        ) -> SentryTelemetryBootstrap.Action? {
            switch terminalState {
            case .completed: .agentRunCompleted
            case .cancelled: .agentRunCancelled
            case .failed: .agentRunFailed
            case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
                nil
            }
        }

        private static func outcome(
            for terminalState: AgentSessionRunState
        ) -> SentryTelemetryBootstrap.Outcome? {
            switch terminalState {
            case .completed: .completed
            case .cancelled: .cancelled
            case .failed: .failed
            case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
                nil
            }
        }

        private static func messageRole(for kind: AgentChatItemKind) -> SentryTelemetryBootstrap.MessageRole? {
            switch kind {
            case .assistant, .assistantInline, .thinking:
                .assistant
            case .error, .system:
                .system
            case .toolCall, .toolResult:
                .tool
            case .user:
                .user
            }
        }

        private static func modelFamily(
            for agentKind: AgentProviderKind,
            modelRaw: String
        ) -> SentryTelemetryBootstrap.ModelFamily {
            let trimmed = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame {
                return .defaultModel
            }
            if let model = AgentModel.resolvedModel(forRaw: trimmed, agentKind: agentKind) {
                return modelFamily(for: model)
            }
            return fallbackModelFamily(for: agentKind, modelRaw: trimmed)
        }

        private static func modelFamily(for model: AgentModel) -> SentryTelemetryBootstrap.ModelFamily {
            switch model {
            case .defaultModel:
                .defaultModel
            case .codexMini, .gpt54MiniLow, .gpt54MiniMedium, .gpt54MiniHigh:
                .gptMini
            case .gpt55CodexLow, .gpt55CodexMedium, .gpt55CodexHigh, .gpt55CodexXHigh:
                .gpt55
            case .codexLow, .codexMedium, .codexHigh, .codexXHigh:
                .gpt53Codex
            case .gpt54Low, .gpt54Medium, .gpt54High, .gpt54XHigh:
                .gpt54
            case .gpt5Low, .gpt5Medium, .gpt5High, .gpt5XHigh:
                .gpt52
            case .claudeFable5:
                .fable
            case .claudeOpus, .claudeOpus1m, .claudeOpus45, .claudeOpus46, .claudeOpus47:
                .opus
            case .claudeSonnet, .claudeSonnet5, .claudeSonnet45, .claudeSonnet46:
                .sonnet
            case .claudeHaiku, .claudeHaiku45:
                .haiku
            case .glm45Air, .glm47, .glm52, .glm52_1m, .glm5Turbo, .glm5:
                .glm
            case .kimiCode:
                .kimi
            case .customClaudeCompatible:
                .customClaudeCompatible
            case .cursorAuto, .cursorComposer2:
                .cursor
            }
        }

        private static func fallbackModelFamily(
            for agentKind: AgentProviderKind,
            modelRaw: String
        ) -> SentryTelemetryBootstrap.ModelFamily {
            let lowercasedRaw = modelRaw.lowercased()
            switch agentKind {
            case .codexExec:
                if lowercasedRaw.contains("mini") { return .gptMini }
                if lowercasedRaw.contains("codex") { return .codex }
                if lowercasedRaw.hasPrefix("gpt-") { return .gpt }
                return .codex
            case .claudeCode:
                if lowercasedRaw.contains("opus") { return .opus }
                if lowercasedRaw.contains("sonnet") { return .sonnet }
                if lowercasedRaw.contains("haiku") { return .haiku }
                if lowercasedRaw.contains("fable") { return .fable }
                return .claude
            case .claudeCodeGLM:
                return .glm
            case .kimiCode:
                return .kimi
            case .customClaudeCompatible:
                return .customClaudeCompatible
            case .cursor:
                return .cursor
            case .openCode:
                return .openCode
            }
        }

        private static func providerErrorKind(for error: Error) -> SentryTelemetryBootstrap.ProviderErrorKind {
            if error is CancellationError {
                return .cancelled
            }
            if let providerError = error as? AIProviderError {
                switch providerError {
                case .missingAPIKey:
                    return .missingCredential
                case .missingOllamaURL, .missingURL:
                    return .missingProviderURL
                case .providerNotConfigured:
                    return .providerNotConfigured
                case .invalidConfiguration, .missingAzureConfiguration, .invalidModel, .invalidSystemPrompt,
                     .messageCreationFailed:
                    return .invalidConfiguration
                case .invalidResponse:
                    return .invalidResponse
                case .apiError:
                    return .apiError
                case .unknown:
                    return .unknown
                }
            }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                return .timeout
            }
            return .unknown
        }

        private static func toolName(
            for approvalKind: SentryTelemetryBootstrap.ApprovalKind
        ) -> SentryTelemetryBootstrap.ToolName {
            switch approvalKind {
            case .applyEdits:
                .applyEdits
            case .worktreeMerge:
                .manageWorktree
            case .commandExecution, .fileChange, .toolPermission:
                .agentRun
            }
        }

    #endif
}
