#if DEBUG
    import Foundation
    import RepoPromptDomainRuntime

    struct PromptExperimentConnectedModelCompletion: Equatable {
        let output: String
        let promptTokens: Int?
        let completionTokens: Int?
        var cachedInputTokens: Int?
        var cacheCreationInputTokens: Int?
        var cost: Double?
    }

    enum PromptExperimentProviderFailureCode: String, CaseIterable {
        case rateLimited = "provider_rate_limited"
        case temporarilyUnavailable = "provider_temporarily_unavailable"
        case transportInterrupted = "provider_transport_interrupted"
        case incompleteResponse = "provider_incomplete_response"
        case emptyResponse = "provider_empty_response"
        case routingUnavailable = "provider_routing_unavailable"
        case rejected = "provider_rejected"
        case invalidResponse = "provider_invalid_response"
        case toolViolation = "provider_tool_violation"
        /// The logical call's overall deadline (all attempts and backoff) elapsed.
        case timedOut = "provider_timed_out"
        case unknown = "provider_unknown"

        var isRetryable: Bool {
            switch self {
            case .rateLimited, .temporarilyUnavailable, .transportInterrupted,
                 .incompleteResponse, .emptyResponse, .routingUnavailable:
                true
            case .rejected, .invalidResponse, .toolViolation, .timedOut, .unknown:
                false
            }
        }

        var safeMessage: String {
            switch self {
            case .rateLimited: "The connected provider rate-limited the callback."
            case .temporarilyUnavailable: "The connected provider was temporarily unavailable."
            case .transportInterrupted: "The connected provider transport was interrupted."
            case .incompleteResponse: "The connected provider returned an incomplete response."
            case .emptyResponse: "The connected provider returned no terminal content."
            case .routingUnavailable: "The prompt-only provider routing policy was not established."
            case .rejected: "The connected provider rejected the callback configuration or credentials."
            case .invalidResponse: "The connected provider returned an invalid response."
            case .toolViolation: "The prompt-only callback attempted to use a disabled tool."
            case .timedOut: "The connected provider call exceeded its overall deadline."
            case .unknown: "The connected provider callback failed for an unclassified reason."
            }
        }
    }

    struct PromptExperimentProviderFailure: LocalizedError, Equatable {
        let code: PromptExperimentProviderFailureCode
        var errorDescription: String? {
            code.safeMessage
        }
    }

    /// Completion consumers need one assistant answer, not concatenated commentary + final messages.
    /// Preserve provider message boundaries; never repair output by guessing at JSON or deduplicating text.
    struct PromptExperimentCompletionAccumulator {
        private var streamedOutput = ""
        private var lastMessageID: String?
        private var finalOutput: String?
        private(set) var promptTokens: Int?
        private(set) var completionTokens: Int?
        private(set) var totalInputTokens: Int?
        private(set) var cachedInputTokens: Int?
        private(set) var cacheCreationInputTokens: Int?
        private(set) var cost: Double?

        var output: String {
            (finalOutput ?? streamedOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutating func consume(_ event: AIStreamResult) {
            // Codex reports usage on message_stop; other providers may use a separate usage event.
            promptTokens = event.promptTokens ?? promptTokens
            completionTokens = event.completionTokens ?? completionTokens
            totalInputTokens = event.totalInputTokens ?? totalInputTokens
            cachedInputTokens = event.cachedInputTokens ?? cachedInputTokens
            cacheCreationInputTokens = event.cacheCreationInputTokens ?? cacheCreationInputTokens
            cost = event.cost ?? cost
            switch event.type {
            case "content":
                if let messageID = event.contentMessageID, !messageID.isEmpty, messageID != lastMessageID {
                    streamedOutput = ""
                    lastMessageID = messageID
                }
                streamedOutput += event.text ?? ""
            case "final_content":
                finalOutput = event.text
            default:
                break
            }
        }
    }

    /// One prompt-only model completion. Cancellation is structured: cancelling the calling
    /// task disposes only that call's provider, never another attempt's work.
    @MainActor
    protocol PromptExperimentModelCompleting: AnyObject {
        func complete(
            target: PromptExperimentResolvedTarget,
            systemPrompt: String,
            userPrompt: String,
            callbackRoot: URL
        ) async throws -> PromptExperimentConnectedModelCompletion
    }

    /// One-shot model completion over the existing Agent provider/login stack.
    /// Built-ins are disabled; RepoPrompt MCP execution is denied by a run-scoped policy.
    @MainActor
    final class PromptExperimentConnectedModelRunner: PromptExperimentModelCompleting {
        /// Supplies any live window whose MCP server can host the run-scoped policy lease.
        /// Runs are not pinned to the window that created or approved them.
        private let windowProvider: @MainActor () -> WindowState?

        init(windowProvider: @escaping @MainActor () -> WindowState? = { WindowStatesManager.shared.allWindows.first }) {
            self.windowProvider = windowProvider
        }

        static let codexIsolationLimitation = "Connected Codex cannot currently enforce the tool-free completion contract required by GEPA target/reflection/judge callbacks. Shell and MCP tool flags do not disable every native tool. No model is substituted; ordinary Codex Agent and Context Builder runs are unaffected."

        static func supportsPromptOnlyCallbacks(_ target: PromptExperimentResolvedTarget) -> Bool {
            guard let agent = AgentProviderKind(rawValue: target.agentRaw) else { return false }
            return [.claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible].contains(agent)
        }

        static func requirePromptOnlyTarget(_ target: PromptExperimentResolvedTarget) throws {
            guard target.agentRaw != AgentProviderKind.codexExec.rawValue else {
                throw PromptExperimentAuthorityError.targetUnavailable(codexIsolationLimitation)
            }
            guard let agent = AgentProviderKind(rawValue: target.agentRaw),
                  [.claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible].contains(agent)
            else {
                throw PromptExperimentAuthorityError.targetUnavailable("The selected provider has no enforced tool-free completion profile.")
            }
        }

        /// Every role must have an enforced tool-free completion profile. Reported per field.
        static func targetErrors(_ targets: PromptExperimentTargets) -> [PromptExperimentFieldError] {
            let roles: [(String, PromptExperimentResolvedTarget?)] = [
                ("execution", targets.execution), ("reflection", targets.reflection), ("judge", targets.judge)
            ]
            return roles.compactMap { field, target in
                guard let target else { return nil }
                do {
                    try requirePromptOnlyTarget(target)
                    return nil
                } catch {
                    return PromptExperimentFieldError(field: field, message: "\(target.selector): \(error.localizedDescription)")
                }
            }
        }

        static func classifyProviderFailure(_ error: Error) -> PromptExperimentProviderFailure {
            if let failure = error as? PromptExperimentProviderFailure { return failure }
            let cocoaError = error as NSError
            if cocoaError.domain == NSURLErrorDomain {
                return .init(code: .transportInterrupted)
            }
            if error is ClaudeCompatiblePluginProviderError {
                return .init(code: .rejected)
            }
            if let providerError = error as? AIProviderError {
                switch providerError {
                case .missingOllamaURL, .missingAzureConfiguration, .missingAPIKey, .missingURL,
                     .providerNotConfigured, .invalidModel, .invalidSystemPrompt,
                     .messageCreationFailed, .invalidConfiguration:
                    return .init(code: .rejected)
                case .invalidResponse:
                    return .init(code: .invalidResponse)
                case let .apiError(source), let .unknown(source):
                    return classifyProviderDescription(source?.localizedDescription)
                }
            }
            return .init(code: .unknown)
        }

        static func classifyProviderDescription(_ detail: String?) -> PromptExperimentProviderFailure {
            let value = (detail ?? "").lowercased()
            if value.contains("rate limit") || value.contains("rate_limit") || value.contains("too many requests")
                || value.contains("429")
            {
                return .init(code: .rateLimited)
            }
            if value.contains("unauthorized") || value.contains("authentication") || value.contains("api key")
                || value.contains("credentials") || value.contains("401") || value.contains("403")
                || value.contains("quota") || value.contains("billing")
            {
                return .init(code: .rejected)
            }
            if value.contains("temporarily unavailable") || value.contains("service unavailable")
                || value.contains("overloaded") || value.contains("http 503")
                || value.contains("status code 503") || value.contains("error: 503")
                || value.contains("error: 529")
            {
                return .init(code: .temporarilyUnavailable)
            }
            if value.contains("timeout") || value.contains("timed out")
                || value.contains("connection reset") || value.contains("connection lost")
                || value.contains("network connection was lost") || value.contains("broken pipe")
                || value.contains("unexpected eof")
            {
                return .init(code: .transportInterrupted)
            }
            return .init(code: .unknown)
        }

        /// Claude-compatible CLIs report API overload / 429 as in-stream `error` events carrying text only.
        /// Prefer a typed stop reason when present; otherwise classify the payload with the same closed
        /// description rules so transient failures stay retryable within the invoker's retry cap.
        static func classifyStreamError(_ event: AIStreamResult) -> PromptExperimentProviderFailure {
            if let stopReason = event.stopReason {
                let typed = classifyProviderDescription(stopReason)
                if typed.code != .unknown { return typed }
            }
            return classifyProviderDescription(event.text)
        }

        func complete(
            target: PromptExperimentResolvedTarget,
            systemPrompt: String,
            userPrompt: String,
            callbackRoot: URL
        ) async throws -> PromptExperimentConnectedModelCompletion {
            // Before directory creation, policy leases, providers, or any model/process admission.
            try Self.requirePromptOnlyTarget(target)
            guard let windowState = windowProvider() else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("No RepoPrompt window is open to host the provider policy.")
            }
            guard let agent = AgentProviderKind(rawValue: target.agentRaw),
                  [.claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible].contains(agent)
            else {
                throw PromptExperimentAuthorityError.targetUnavailable(
                    "The selected target has no proven prompt-only Prompt Experiment provider profile."
                )
            }
            try FileManager.default.createDirectory(at: callbackRoot, withIntermediateDirectories: true)
            let runID = UUID()
            await windowState.mcpServer.startServer()
            guard windowState.mcpServer.windowToolsEnabled else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("RepoPrompt MCP is unavailable for the run-scoped provider policy.")
            }
            let spec = AgentRunSpec(
                type: .promptExperiment,
                runID: runID,
                agentKind: agent,
                modelString: target.modelRaw,
                windowID: windowState.windowID,
                restrictedTools: Set(MCPDomainToolCatalog.orderedToolNames),
                connectionTTL: 60
            )
            let lease = try await AgentRunCoordinator.shared.prepareAndInstallPolicy(
                spec,
                tabID: nil,
                additionalTools: [],
                reason: "prompt-experiment-model-callback",
                gateID: runID
            )
            let provider = AgentRunCoordinator.shared.makeProvider(
                agentKind: agent,
                modelString: target.modelRaw,
                runType: .promptExperiment,
                workspacePath: callbackRoot.path
            )
            guard !Task.isCancelled else {
                await lease.failAndCleanup()
                await provider.dispose()
                throw CancellationError()
            }
            defer {
                try? FileManager.default.removeItem(at: callbackRoot)
            }

            return try await withTaskCancellationHandler {
                do {
                    let routeTask = Task { await lease.releaseWhenRouted(timeoutMs: 10000) }
                    let stream = try await provider.streamAgentMessage(
                        AgentMessage(systemPrompt: systemPrompt, userMessage: userPrompt),
                        runID: runID
                    )
                    var accumulator = PromptExperimentCompletionAccumulator()
                    var reachedTerminal = false
                    for try await event in stream {
                        try Task.checkCancellation()
                        accumulator.consume(event)
                        switch event.type {
                        case "tool_call", "tool_result":
                            throw PromptExperimentProviderFailure(code: .toolViolation)
                        case "error":
                            // Only the closed transient classes (rate limit, overload/503, transport) retry;
                            // unrecognised prose stays `.unknown` and non-retryable.
                            throw Self.classifyStreamError(event)
                        case "message_incomplete":
                            throw PromptExperimentProviderFailure(code: .incompleteResponse)
                        case "message_stop":
                            reachedTerminal = true
                        default:
                            break
                        }
                    }
                    guard await routeTask.value else {
                        throw PromptExperimentProviderFailure(code: .routingUnavailable)
                    }
                    let effective = accumulator.output
                    guard reachedTerminal else {
                        throw PromptExperimentProviderFailure(code: .incompleteResponse)
                    }
                    guard !effective.isEmpty else {
                        throw PromptExperimentProviderFailure(code: .emptyResponse)
                    }
                    await provider.dispose()
                    return PromptExperimentConnectedModelCompletion(
                        output: effective,
                        promptTokens: accumulator.totalInputTokens,
                        completionTokens: accumulator.completionTokens,
                        cachedInputTokens: accumulator.cachedInputTokens,
                        cacheCreationInputTokens: accumulator.cacheCreationInputTokens,
                        cost: accumulator.cost
                    )
                } catch is CancellationError {
                    await lease.failAndCleanup()
                    await provider.dispose()
                    throw CancellationError()
                } catch {
                    await lease.failAndCleanup()
                    await provider.dispose()
                    throw Self.classifyProviderFailure(error)
                }
            } onCancel: {
                Task { await provider.dispose() }
            }
        }
    }
#endif
