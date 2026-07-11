import Foundation

public struct ClaudeSDKNDJSONTranslator {
    public private(set) var cliSessionID: String?
    private var toolNameByToolUseID: [String: String] = [:]
    private var invocationIDByToolUseID: [String: UUID] = [:]
    // Per-stream main-model attribution state for canonical `modelUsage.contextWindow`
    // selection. The init `model` (e.g. "claude-opus-4-8[1m]") anchors tracking; a top-level
    // assistant `message.model` is a fallback anchor only when tracking is still unset. The
    // controller resets this state explicitly for each process stream (including shutdown/EOF
    // reuse), and a new init also re-anchors it.
    private var trackedMainModelID: String?
    private var lastMatchedMainContextWindow: Int?
    private var didLogModelUsageNoMatchFallback = false
    private let enableDebugLogging: Bool
    private let treatsToolResultErrorsAsHostOwned: @Sendable (String) -> Bool

    public init(
        enableDebugLogging: Bool = false,
        treatsToolResultErrorsAsHostOwned: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        self.enableDebugLogging = enableDebugLogging
        self.treatsToolResultErrorsAsHostOwned = treatsToolResultErrorsAsHostOwned
    }

    public mutating func resetMainModelTracking() {
        trackedMainModelID = nil
        lastMatchedMainContextWindow = nil
        didLogModelUsageNoMatchFallback = false
    }

    #if DEBUG
        private func reasoningDebug(_ message: @autoclosure () -> String) {
            guard ClaudeReasoningExtractionFeature.isEnabled else { return }
            let line = "[ClaudeReasoningDebug][Translator] \(message())"
            ClaudeReasoningDebugLog.emit(line)
        }
    #else
        private func reasoningDebug(_ message: @autoclosure () -> String) {}
    #endif

    private func debugSnippet(_ text: String, limit: Int = 160) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(limit)
            .description
    }

    public mutating func parseNDJSONLine(_ lineData: Data) -> [ClaudeProviderStreamResult] {
        guard let trimmed = trimmedASCIIWhitespace(lineData), !trimmed.isEmpty else { return [] }
        guard let json = (try? JSONSerialization.jsonObject(with: trimmed)) as? [String: Any] else {
            if enableDebugLogging, let snippet = String(data: trimmed.prefix(160), encoding: .utf8) {
                print("[DEBUG] ClaudeSDKTranslator: Skipping non-object payload: \(snippet)")
            }
            return []
        }
        return parseMessageDictionary(json)
    }

    /// Translates a DTO stream payload returned by `ClaudeSDKProtocolCodec.decodeLine(_:)`.
    public mutating func parseStreamPayload(_ payload: [String: ClaudeProviderJSONValue]) -> [ClaudeProviderStreamResult] {
        parseMessageDictionary(payload.mapValues { $0.foundationObject() })
    }

    private mutating func parseMessageDictionary(_ json: [String: Any]) -> [ClaudeProviderStreamResult] {
        if let sessionID = firstString(in: json, keys: ["session_id", "sessionId"]) {
            cliSessionID = sessionID
        }
        let type = (json["type"] as? String) ?? ""
        switch type {
        case "system":
            return parseSystemMessage(json)
        case "assistant", "message":
            return parseAssistantMessage(json)
        case "user":
            return parseUserMessage(json)
        case "stream_event":
            return parseStreamEvent(json)
        case "tool_use":
            return parseTopLevelToolUse(json)
        case "tool_result":
            return parseTopLevelToolResult(json)
        case "result":
            return parseResultMessage(json)
        case "tool_progress":
            return parseToolProgressMessage(json)
        case "auth_status":
            return parseAuthStatusMessage(json)
        case "tool_use_summary":
            return parseToolUseSummaryMessage(json)
        case "rate_limit_event":
            return parseRateLimitEventMessage(json)
        case "error":
            if let message = firstString(in: json, keys: ["error", "message"]), !message.isEmpty {
                return [ClaudeProviderStreamResult(type: "error", text: message)]
            }
            return []
        default:
            return []
        }
    }

    private mutating func parseSystemMessage(_ json: [String: Any]) -> [ClaudeProviderStreamResult] {
        let subtype = (json["subtype"] as? String)?.lowercased()
        if subtype == "init" {
            if let sessionID = firstString(in: json, keys: ["session_id", "sessionId"]) {
                cliSessionID = sessionID
            }
            // The init `model` is the exact `modelUsage` key for the main model and
            // authoritatively anchors attribution for this stream. It overwrites tracking
            // unconditionally and re-anchors sticky/no-match state for a new stream.
            if let initModel = firstString(in: json, keys: ["model"]) {
                trackedMainModelID = initModel
                lastMatchedMainContextWindow = nil
                didLogModelUsageNoMatchFallback = false
            }
            return [ClaudeProviderStreamResult(type: ClaudeProviderStreamResult.lifecycleType, text: "initialized")]
        }

        if subtype == "status" {
            let status = firstString(in: json, keys: ["status"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var fragments: [String] = []
            if let status, !status.isEmpty, status != "null" {
                if status.caseInsensitiveCompare("compacting") == .orderedSame {
                    fragments.append("Compacting context")
                } else {
                    fragments.append(status)
                }
            }
            guard !fragments.isEmpty else { return [] }
            return [ClaudeProviderStreamResult(type: "status", text: fragments.joined(separator: " — "))]
        }

        if subtype == "task_started" {
            let taskID = firstString(in: json, keys: ["task_id"])
            let description = firstString(in: json, keys: ["description"])
            let fragments = ["Task started", taskID, description]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return fragments.isEmpty ? [] : [ClaudeProviderStreamResult(type: "system", text: fragments.joined(separator: " — "))]
        }

        if subtype == "task_notification" {
            let taskID = firstString(in: json, keys: ["task_id"])
            let status = firstString(in: json, keys: ["status"])
            let summary = firstString(in: json, keys: ["summary"])
            let fragments = ["Task update", taskID, status, summary]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return fragments.isEmpty ? [] : [ClaudeProviderStreamResult(type: "system", text: fragments.joined(separator: " — "))]
        }

        if subtype == "compact_boundary" {
            let metadata = (json["compact_metadata"] as? [String: Any]) ?? [:]
            let trigger = firstString(in: metadata, keys: ["trigger"])
            let preTokens = numberToInt(metadata["pre_tokens"])
            var fragments = ["Context compacted"]
            if let trigger, !trigger.isEmpty {
                fragments.append("trigger: \(trigger)")
            }
            if let preTokens, preTokens > 0 {
                fragments.append("at ~\(preTokens) tokens")
            }
            return [ClaudeProviderStreamResult(type: "system", text: fragments.joined(separator: " — "))]
        }

        // Claude Code lifecycle: session_state_changed (running / idle / etc.)
        if subtype == "session_state_changed" {
            let state = firstString(
                in: json,
                keys: ["session_state", "sessionState", "state", "current_state", "currentState"]
            )?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let state, !state.isEmpty else { return [] }
            return [ClaudeProviderStreamResult(type: "session_state_changed", text: state)]
        }

        // Claude Code lifecycle: task_progress — used for run-state status updates, not transcript rows
        if subtype == "task_progress" {
            let fragments: [String] = ["message", "text", "summary", "description", "status"]
                .compactMap { key in
                    firstString(in: json, keys: [key])?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
            guard !fragments.isEmpty else {
                // Fall back to task_id if no descriptive text is available
                if let taskID = firstString(in: json, keys: ["task_id", "taskId"]),
                   !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return [ClaudeProviderStreamResult(type: "task_progress", text: "Task \(taskID.trimmingCharacters(in: .whitespacesAndNewlines))")]
                }
                return []
            }
            return [ClaudeProviderStreamResult(type: "task_progress", text: fragments.joined(separator: " — "))]
        }

        if let message = firstString(in: json, keys: ["message"]), !message.isEmpty {
            return [ClaudeProviderStreamResult(type: "system", text: message)]
        }
        return []
    }

    private mutating func parseAssistantMessage(_ json: [String: Any]) -> [ClaudeProviderStreamResult] {
        let payload = (json["message"] as? [String: Any]) ?? json
        // A top-level assistant `message.model` is a fallback main-model anchor. It SETS
        // tracking only when currently unset (so it never downgrades an init-tracked exact id
        // such as "claude-opus-4-8[1m]" to the assistant base id "claude-opus-4-8"), and only
        // from a non-sidechain event. Sidechain/subagent assistant events carry a non-null
        // `parent_tool_use_id` and must not retarget main-model tracking.
        if trackedMainModelID == nil,
           !isSidechainAssistantEvent(json),
           let assistantModel = firstString(in: payload, keys: ["model"])
        {
            trackedMainModelID = assistantModel
        }
        let usageResult: ClaudeProviderStreamResult? = {
            guard let usage = parseUsage(payload["usage"] as? [String: Any]) else { return nil }
            return ClaudeProviderStreamResult(
                type: "usage",
                text: nil,
                promptTokens: usage.inputTokens,
                completionTokens: usage.outputTokens,
                contextUsedTokens: usage.contextUsedTokens
            )
        }()
        guard let content = payload["content"] as? [Any] else {
            if let fallback = extractString(payload["content"]), !fallback.isEmpty {
                var fallbackResults: [ClaudeProviderStreamResult] = []
                if let usageResult {
                    fallbackResults.append(usageResult)
                }
                fallbackResults.append(ClaudeProviderStreamResult(type: "content", text: fallback))
                return fallbackResults
            }
            if let usageResult {
                return [usageResult]
            }
            return []
        }

        var results: [ClaudeProviderStreamResult] = []
        if let usageResult {
            results.append(usageResult)
        }
        for item in content {
            guard let block = item as? [String: Any], let type = block["type"] as? String else { continue }
            #if DEBUG
                if ClaudeReasoningExtractionFeature.isEnabled {
                    reasoningDebug("assistant content block type=\(type) keys=\(block.keys.sorted())")
                }
            #endif
            switch type {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    results.append(ClaudeProviderStreamResult(type: "content", text: text))
                }
            case "thinking":
                guard ClaudeReasoningExtractionFeature.isEnabled else { continue }
                if let text = block["thinking"] as? String, !text.isEmpty {
                    reasoningDebug("assistant thinking block mapped len=\(text.count) snippet=\(debugSnippet(text))")
                    results.append(ClaudeProviderStreamResult(type: "reasoning", text: nil, reasoning: text))
                } else {
                    reasoningDebug("assistant thinking block missing/empty thinking field keys=\(block.keys.sorted())")
                }
            case "tool_use":
                let toolName = (block["name"] as? String) ?? "tool"
                let toolUseID = toolUseID(in: block)
                if let toolUseID, !toolUseID.isEmpty {
                    toolNameByToolUseID[toolUseID] = toolName
                }
                let invocationID = resolveInvocationID(for: toolUseID)
                let input = (block["input"] as? [String: Any]) ?? [:]
                let inputJSON = serializeJSONObjectString(input)
                results.append(
                    ClaudeProviderStreamResult(
                        type: "tool_call",
                        text: nil,
                        toolName: toolName,
                        toolArgs: inputJSON,
                        toolInvocationID: invocationID,
                        toolArgsJSON: inputJSON
                    )
                )
            case "tool_result":
                let toolUseID = toolUseID(in: block)
                let toolName = resolveToolName(
                    rawName: block["name"] as? String,
                    toolUseID: toolUseID
                )
                let isError = inferToolResultError(from: block, toolName: toolName)
                let output = serializeToolResultContent(block["content"])
                let invocationID = resolveInvocationID(for: toolUseID)
                results.append(
                    ClaudeProviderStreamResult(
                        type: "tool_result",
                        text: nil,
                        toolName: toolName,
                        toolOutput: output,
                        toolInvocationID: invocationID,
                        toolResultJSON: output,
                        toolIsError: isError
                    )
                )
            default:
                continue
            }
        }
        return results
    }

    private mutating func parseUserMessage(_ json: [String: Any]) -> [ClaudeProviderStreamResult] {
        let payload = (json["message"] as? [String: Any]) ?? json
        guard let content = payload["content"] as? [Any] else { return [] }
        var results: [ClaudeProviderStreamResult] = []
        for item in content {
            guard let block = item as? [String: Any],
                  let type = block["type"] as? String,
                  type == "tool_result"
            else {
                continue
            }
            let toolUseID = toolUseID(in: block)
            let toolName = resolveToolName(
                rawName: block["name"] as? String,
                toolUseID: toolUseID
            )
            let isError = inferToolResultError(from: block, toolName: toolName)
            let output = serializeToolResultContent(block["content"])
            let invocationID = resolveInvocationID(for: toolUseID)
            results.append(
                ClaudeProviderStreamResult(
                    type: "tool_result",
                    text: nil,
                    toolName: toolName,
                    toolOutput: output,
                    toolInvocationID: invocationID,
                    toolResultJSON: output,
                    toolIsError: isError
                )
            )
        }
        return results
    }

    private mutating func parseStreamEvent(_ json: [String: Any]) -> [ClaudeProviderStreamResult] {
        guard let event = json["event"] as? [String: Any] else {
            #if DEBUG
                if ClaudeReasoningExtractionFeature.isEnabled {
                    reasoningDebug("stream_event missing event object keys=\(json.keys.sorted())")
                }
            #endif
            return []
        }
        guard let eventType = event["type"] as? String else {
            #if DEBUG
                if ClaudeReasoningExtractionFeature.isEnabled {
                    reasoningDebug("stream_event missing event.type keys=\(event.keys.sorted())")
                }
            #endif
            return []
        }
        #if DEBUG
            if ClaudeReasoningExtractionFeature.isEnabled {
                reasoningDebug("stream_event type=\(eventType) keys=\(event.keys.sorted())")
            }
        #endif

        switch eventType {
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any], let deltaType = delta["type"] as? String else {
                #if DEBUG
                    if ClaudeReasoningExtractionFeature.isEnabled {
                        reasoningDebug("content_block_delta missing delta/type keys=\(event.keys.sorted())")
                    }
                #endif
                return []
            }
            #if DEBUG
                if ClaudeReasoningExtractionFeature.isEnabled {
                    reasoningDebug("content_block_delta deltaType=\(deltaType) deltaKeys=\(delta.keys.sorted())")
                }
            #endif
            switch deltaType {
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty {
                    return [ClaudeProviderStreamResult(type: "content", text: text)]
                }
            case "thinking_delta":
                guard ClaudeReasoningExtractionFeature.isEnabled else { return [] }
                if let text = delta["thinking"] as? String, !text.isEmpty {
                    reasoningDebug("thinking_delta mapped len=\(text.count) snippet=\(debugSnippet(text))")
                    return [ClaudeProviderStreamResult(type: "reasoning", text: nil, reasoning: text)]
                }
                reasoningDebug("thinking_delta missing/empty thinking field deltaKeys=\(delta.keys.sorted())")
            default:
                #if DEBUG
                    if ClaudeReasoningExtractionFeature.isEnabled {
                        reasoningDebug("unsupported content_block_delta deltaType=\(deltaType)")
                    }
                #endif
            }
            return []

        case "message_start":
            guard let message = event["message"] as? [String: Any],
                  let usage = parseUsage(message["usage"] as? [String: Any])
            else {
                return []
            }
            return [
                ClaudeProviderStreamResult(
                    type: "usage",
                    text: nil,
                    promptTokens: usage.inputTokens,
                    completionTokens: usage.outputTokens,
                    contextUsedTokens: usage.contextUsedTokens
                )
            ]

        case "message_delta":
            var results: [ClaudeProviderStreamResult] = []
            if let usage = parseUsage(event["usage"] as? [String: Any]) {
                results.append(
                    ClaudeProviderStreamResult(
                        type: "usage",
                        text: nil,
                        promptTokens: usage.inputTokens,
                        completionTokens: usage.outputTokens,
                        contextUsedTokens: usage.contextUsedTokens
                    )
                )
            }
            if let delta = event["delta"] as? [String: Any],
               let stopReason = firstString(in: delta, keys: ["stop_reason", "stopReason"]),
               !stopReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                results.append(ClaudeProviderStreamResult(type: "message_stop", text: nil, stopReason: stopReason))
            }
            return results

        case "message_stop":
            return [ClaudeProviderStreamResult(type: "message_stop", text: nil)]

        default:
            return []
        }
    }

    private mutating func parseTopLevelToolUse(_ json: [String: Any]) -> [ClaudeProviderStreamResult] {
        let toolName = firstString(in: json, keys: ["tool_name", "toolName", "name"]) ?? "tool"
        let toolUseID = toolUseID(in: json)
        if let toolUseID, !toolUseID.isEmpty {
            toolNameByToolUseID[toolUseID] = toolName
        }
        let invocationID = resolveInvocationID(for: toolUseID)
        let args = extractDictionary(json["tool_args"] ?? json["toolArgs"] ?? json["input"] ?? json["arguments"])
        let argsJSON = serializeJSONObjectString(args)
        return [ClaudeProviderStreamResult(type: "tool_call", text: nil, toolName: toolName, toolArgs: argsJSON, toolInvocationID: invocationID, toolArgsJSON: argsJSON)]
    }

    private mutating func parseTopLevelToolResult(_ json: [String: Any]) -> [ClaudeProviderStreamResult] {
        let toolUseID = toolUseID(in: json)
        let resultPayload = json["tool_result"]
            ?? json["toolResult"]
            ?? json["content"]
            ?? json["result"]
            ?? json["output"]
            ?? json["response"]
        let output = serializeToolResultContent(resultPayload)
        let toolName = resolveToolName(
            rawName: firstString(in: json, keys: ["tool_name", "toolName", "name"]),
            toolUseID: toolUseID
        )
        let invocationID = resolveInvocationID(for: toolUseID)
        let isError = inferToolResultError(from: json, toolName: toolName, resultPayload: resultPayload)
        return [ClaudeProviderStreamResult(type: "tool_result", text: nil, toolName: toolName, toolOutput: output, toolInvocationID: invocationID, toolResultJSON: output, toolIsError: isError)]
    }

    private mutating func parseResultMessage(_ json: [String: Any]) -> [ClaudeProviderStreamResult] {
        let usage = parseUsage(json["usage"] as? [String: Any])
        let modelContextWindow = parseModelContextWindow(json["modelUsage"] as? [String: Any])
        let cost = json["total_cost_usd"] as? Double
        let stopReason = firstString(in: json, keys: ["stop_reason", "stopReason"])
        let resultSubtype = firstString(in: json, keys: ["subtype"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isError = boolValue(in: json, keys: ["is_error", "isError"]) == true
        let resultSessionID = firstString(in: json, keys: ["session_id", "sessionId"])
        if let resultSessionID {
            cliSessionID = resultSessionID
        }

        var results: [ClaudeProviderStreamResult] = []
        let resultErrors = extractResultErrorMessages(from: json)
        let shouldEmitResultError = isError
            || (resultSubtype?.contains("error") ?? false)
            || !resultErrors.isEmpty
        let shouldSuppressResultError = shouldSuppressResultErrorEmission(
            subtype: resultSubtype,
            stopReason: stopReason,
            errors: resultErrors
        )
        if shouldEmitResultError,
           !shouldSuppressResultError,
           let errorMessage = resultErrors.first,
           !errorMessage.isEmpty
        {
            results.append(ClaudeProviderStreamResult(type: "error", text: errorMessage))
        }
        if let finalText = json["result"] as? String, !finalText.isEmpty {
            results.append(ClaudeProviderStreamResult(type: "final_content", text: finalText))
        }
        // Note: contextUsedTokens is intentionally nil here. Claude's result.usage is an aggregate
        // billed-turn total, not a live context snapshot. Live context snapshots come from stream
        // usage events (message_start / message_delta) and are tracked separately by the estimator.
        results.append(
            ClaudeProviderStreamResult(
                type: "message_stop",
                text: nil,
                promptTokens: usage?.inputTokens,
                completionTokens: usage?.outputTokens,
                cost: cost,
                providerSessionID: cliSessionID,
                stopReason: stopReason,
                modelContextWindow: modelContextWindow
            )
        )
        return results
    }

    private mutating func parseToolProgressMessage(_ json: [String: Any]) -> [ClaudeProviderStreamResult] {
        let toolName = firstString(in: json, keys: ["tool_name", "toolName", "name"])
        let status = firstString(in: json, keys: ["status", "stage"])
        let detail = firstString(in: json, keys: ["message", "text", "progress"])
        let fragments = [toolName, status, detail].compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }
        guard !fragments.isEmpty else { return [] }
        let text = fragments.joined(separator: " — ")
        return [ClaudeProviderStreamResult(type: "tool_progress", text: text, toolName: toolName)]
    }

    private mutating func parseAuthStatusMessage(_ json: [String: Any]) -> [ClaudeProviderStreamResult] {
        if let isAuthenticating = json["isAuthenticating"] as? Bool {
            let output = (json["output"] as? [String])?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let error = firstString(in: json, keys: ["error"])
            var fragments: [String] = [isAuthenticating ? "Authenticating" : "Authenticated"]
            if let output, !output.isEmpty {
                fragments.append(output)
            }
            if let error, !error.isEmpty {
                fragments.append(error)
            }
            let text = fragments.joined(separator: " — ")
            return [ClaudeProviderStreamResult(type: "auth_status", text: text)]
        }

        let status = firstString(in: json, keys: ["status", "auth_status", "authStatus"])
        let message = firstString(in: json, keys: ["message", "text", "detail"])
        let parts = [status, message].compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }
        guard !parts.isEmpty else { return [] }
        let text = parts.joined(separator: " — ")
        return [ClaudeProviderStreamResult(type: "auth_status", text: text)]
    }

    private mutating func parseToolUseSummaryMessage(_ json: [String: Any]) -> [ClaudeProviderStreamResult] {
        guard let summary = firstString(in: json, keys: ["summary"]), !summary.isEmpty else {
            return []
        }
        return [ClaudeProviderStreamResult(type: "system", text: "Tool summary — \(summary)")]
    }

    private mutating func parseRateLimitEventMessage(_ json: [String: Any]) -> [ClaudeProviderStreamResult] {
        guard let info = json["rate_limit_info"] as? [String: Any] else { return [] }
        let status = firstString(in: info, keys: ["status"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // "allowed" is a routine telemetry event and should not clutter transcript UI.
        guard status != "allowed" else { return [] }
        let rateLimitType = firstString(in: info, keys: ["rateLimitType", "rate_limit_type"])
        let overageStatus = firstString(in: info, keys: ["overageStatus", "overage_status"])
        let fragments = ["Rate limit", status, rateLimitType, overageStatus]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !fragments.isEmpty else { return [] }
        return [ClaudeProviderStreamResult(type: "system", text: fragments.joined(separator: " — "))]
    }

    private func firstString(in json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func extractResultErrorMessages(from json: [String: Any]) -> [String] {
        var messages: [String] = []

        if let errors = json["errors"] as? [Any] {
            for entry in errors {
                switch entry {
                case let message as String:
                    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        messages.append(trimmed)
                    }
                case let object as [String: Any]:
                    if let message = firstString(in: object, keys: ["message", "error"])?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !message.isEmpty
                    {
                        messages.append(message)
                    }
                default:
                    continue
                }
            }
        }

        if let explicit = firstString(in: json, keys: ["error", "message"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !explicit.isEmpty,
            !messages.contains(explicit)
        {
            messages.append(explicit)
        }

        return messages
    }

    private func shouldSuppressResultErrorEmission(
        subtype: String?,
        stopReason: String?,
        errors: [String]
    ) -> Bool {
        guard !errors.isEmpty else { return false }
        if isInterruptedTurnSignal(subtype) || isInterruptedTurnSignal(stopReason) {
            return true
        }
        let normalizedErrors = errors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalizedErrors.isEmpty else { return false }
        // Suppress when ALL errors are recognizable abort/interrupt artifacts.
        // This covers JSON parse errors from killed tool processes, the bundled CLI
        // stack trace variant, non-fatal lock warnings, and MCP abort errors.
        return normalizedErrors.allSatisfy { message in
            isInterruptedTurnSignal(message) || ClaudeAbortArtifactFilter.shouldSuppressUserFacingError(message)
        }
    }

    private func isInterruptedTurnSignal(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else {
            return false
        }
        return value.contains("interrupt")
            || value.contains("cancel")
            || value.contains("aborted")
            || value.contains("request was aborted")
    }

    private func toolUseID(in json: [String: Any]) -> String? {
        firstString(in: json, keys: ["tool_use_id", "toolUseId", "toolUseID", "id"])
    }

    private mutating func resolveToolName(rawName: String?, toolUseID: String?) -> String {
        let trimmedRaw = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = toolUseID.flatMap { toolNameByToolUseID[$0] }
        let resolved = trimmedRaw?.isEmpty == false ? trimmedRaw! : (mapped ?? "tool")
        if let toolUseID, !toolUseID.isEmpty,
           !resolved.isEmpty,
           resolved != "tool"
        {
            toolNameByToolUseID[toolUseID] = resolved
        }
        return resolved
    }

    private func inferToolResultError(
        from payload: [String: Any],
        toolName: String,
        resultPayload: Any? = nil
    ) -> Bool? {
        if treatsToolResultErrorsAsHostOwned(toolName) {
            // RepoPrompt MCP tool status is tracked by the completion handler.
            return nil
        }

        if let explicit = boolValue(in: payload, keys: ["is_error", "isError"]) {
            return explicit
        }
        if let inferred = inferToolResultErrorSignal(from: payload) {
            return inferred
        }
        if let inferred = inferToolResultErrorSignal(from: resultPayload) {
            return inferred
        }
        return nil
    }

    private func inferToolResultErrorSignal(from value: Any?) -> Bool? {
        switch value {
        case let object as [String: Any]:
            return inferToolResultErrorSignal(fromObject: object)
        case let array as [Any]:
            var sawSuccessSignal = false
            for element in array {
                if let inferred = inferToolResultErrorSignal(from: element) {
                    if inferred {
                        return true
                    }
                    sawSuccessSignal = true
                }
            }
            return sawSuccessSignal ? false : nil
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
                || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
                let data = trimmed.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data)
            {
                return inferToolResultErrorSignal(from: json)
            }
            return nil
        default:
            return nil
        }
    }

    private func inferToolResultErrorSignal(fromObject object: [String: Any]) -> Bool? {
        if let explicit = boolValue(in: object, keys: ["is_error", "isError"]) {
            return explicit
        }

        if let status = firstString(in: object, keys: ["status", "result", "outcome", "state", "subtype"]),
           let statusInference = inferStatusError(from: status)
        {
            return statusInference
        }

        if let exitCode = intValue(in: object, keys: ["exitCode", "exit_code", "code"]) {
            if exitCode == 0 { return false }
            if exitCode > 0 { return true }
        }

        if let error = firstString(in: object, keys: ["error", "error_message", "errorMessage"]),
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        if let errors = object["errors"] as? [Any], !errors.isEmpty {
            return true
        }
        if boolValue(in: object, keys: ["success", "ok"]) == true {
            return false
        }

        let nestedKeys = [
            "tool_result", "toolResult", "result", "output", "response",
            "content", "payload", "data", "value", "tool_use_result", "toolUseResult"
        ]
        for key in nestedKeys {
            if let inferred = inferToolResultErrorSignal(from: object[key]) {
                return inferred
            }
        }

        if let contentBlocks = object["content"] as? [Any], !contentBlocks.isEmpty {
            return false
        }
        return nil
    }

    private func inferStatusError(from value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ok", "success", "succeeded", "complete", "completed":
            false
        case "error", "failed", "failure", "rejected", "denied", "cancelled", "canceled":
            true
        default:
            nil
        }
    }

    private func boolValue(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = object[key] as? Bool {
                return value
            }
            if let number = object[key] as? NSNumber {
                return number.boolValue
            }
            if let text = object[key] as? String {
                switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "yes", "y":
                    return true
                case "false", "0", "no", "n":
                    return false
                default:
                    break
                }
            }
        }
        return nil
    }

    private func intValue(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int {
                return value
            }
            if let number = object[key] as? NSNumber {
                return number.intValue
            }
            if let text = object[key] as? String,
               let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return parsed
            }
        }
        return nil
    }

    private mutating func resolveInvocationID(for toolUseID: String?) -> UUID? {
        guard let toolUseID, !toolUseID.isEmpty else { return nil }
        if let existing = invocationIDByToolUseID[toolUseID] {
            return existing
        }
        let generated = UUID()
        invocationIDByToolUseID[toolUseID] = generated
        return generated
    }

    private func serializeJSONObjectString(_ value: [String: Any]) -> String? {
        guard !value.isEmpty, JSONSerialization.isValidJSONObject(value) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func serializeToolResultContent(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String {
            return text
        }
        if let blocks = value as? [[String: Any]] {
            let textBlocks = blocks.compactMap { block -> String? in
                let blockType = (block["type"] as? String)?.lowercased()
                if blockType == "text" || blockType == "output_text" {
                    return block["text"] as? String
                }
                return nil
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            if !textBlocks.isEmpty {
                return textBlocks.joined(separator: "\n")
            }
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        return String(describing: value)
    }

    private func extractString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let dict as [String: Any]:
            if let text = dict["text"] as? String { return text }
            return nil
        case let array as [Any]:
            return array.compactMap { extractString($0) }.joined(separator: "")
        default:
            return nil
        }
    }

    private func extractDictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    /// Selects the canonical `contextWindow` by deterministic main-model attribution
    /// instead of the first positive entry of an unordered `modelUsage` map. Selection order:
    ///   1. exact match on the tracked main-model id
    ///   2. deterministic MAX within the first non-empty candidate tier: normalized equality,
    ///      then segment-boundary base-prefix
    ///   3. sticky last-matched main-model window (never downgraded by background-only events)
    ///   4. deterministic global MAX only when neither candidate tier matched and sticky is unset
    /// A disagreeing candidate-tier MAX may transiently over-report until a later exact/equality
    /// anchor overwrites sticky. Numerator/usage parsing is untouched.
    private mutating func parseModelContextWindow(_ value: [String: Any]?) -> Int? {
        guard let value, !value.isEmpty else {
            // No `modelUsage` this event: preserve the sticky main-model window.
            return lastMatchedMainContextWindow
        }

        var positiveWindows: [String: Int] = [:]
        for (key, usageAny) in value {
            guard let usage = usageAny as? [String: Any],
                  let contextWindow = numberToInt(usage["contextWindow"]),
                  contextWindow > 0
            else { continue }
            positiveWindows[key] = contextWindow
        }
        guard !positiveWindows.isEmpty else {
            return lastMatchedMainContextWindow
        }

        if let trackedMainModelID {
            // 1. Exact match on the tracked main-model id.
            if let window = positiveWindows[trackedMainModelID] {
                lastMatchedMainContextWindow = window
                return window
            }
            // 2. Resolve within the strongest non-empty normalized candidate tier.
            if let window = attributedCandidateContextWindow(for: trackedMainModelID, in: positiveWindows) {
                lastMatchedMainContextWindow = window
                return window
            }
        }

        // 3. Sticky last-matched main-model window; non-candidate background-only events preserve it.
        if let sticky = lastMatchedMainContextWindow {
            return sticky
        }

        // 4. Deterministic MAX across positive entries (never blind first-positive).
        let maxWindow = positiveWindows.values.max()
        if enableDebugLogging, !didLogModelUsageNoMatchFallback, let maxWindow {
            didLogModelUsageNoMatchFallback = true
            print("[DEBUG] ClaudeSDKTranslator: modelUsage main-model attribution found no match for tracked id \(trackedMainModelID ?? "<none>"); using deterministic MAX contextWindow \(maxWindow) across \(positiveWindows.count) entries.")
        }
        return maxWindow
    }

    /// Resolves the strongest non-empty normalized candidate tier. Equality is stronger than
    /// segment-boundary prefix attribution; ambiguity resolves to the tier's deterministic MAX.
    private func attributedCandidateContextWindow(for trackedID: String, in positiveWindows: [String: Int]) -> Int? {
        let normalizedTracked = normalizeModelID(trackedID)

        // 2a. Normalized equality after stripping one trailing bracketed suffix from each side.
        let equalMatches = positiveWindows.filter { normalizeModelID($0.key) == normalizedTracked }
        if !equalMatches.isEmpty { return equalMatches.values.max() }

        // 2b. Segment-boundary base-prefix candidates are considered only when equality is empty.
        let prefixMatches = positiveWindows.filter { entry in
            prefixMatchHasAcceptedBoundary(normalizedTracked, normalizeModelID(entry.key))
        }
        return prefixMatches.values.max()
    }

    private func prefixMatchHasAcceptedBoundary(_ left: String, _ right: String) -> Bool {
        guard left != right else { return false }
        let shorter: String
        let longer: String
        if left.count <= right.count {
            shorter = left
            longer = right
        } else {
            shorter = right
            longer = left
        }
        guard longer.hasPrefix(shorter), shorter.count < longer.count else { return false }
        let boundary = longer[longer.index(longer.startIndex, offsetBy: shorter.count)]
        return boundary == "-" || boundary == "["
    }

    /// Strips a single trailing bracketed group such as `[1m]` (e.g. "claude-opus-4-8[1m]" ->
    /// "claude-opus-4-8"). Non-bracketed ids are returned unchanged.
    private func normalizeModelID(_ id: String) -> String {
        guard id.hasSuffix("]"), let open = id.lastIndex(of: "[") else { return id }
        return String(id[id.startIndex ..< open])
    }

    /// A non-null `parent_tool_use_id` marks a subagent/sidechain assistant event.
    private func isSidechainAssistantEvent(_ json: [String: Any]) -> Bool {
        guard let parent = json["parent_tool_use_id"] else { return false }
        if parent is NSNull { return false }
        if let identifier = parent as? String {
            return !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func parseUsage(_ value: [String: Any]?) -> TokenUsage? {
        guard let value else { return nil }

        let input = numberToInt(value["input_tokens"]) ?? numberToInt(value["inputTokens"])
        let output = numberToInt(value["output_tokens"]) ?? numberToInt(value["outputTokens"])
        let cacheRead = numberToInt(value["cache_read_input_tokens"]) ?? numberToInt(value["cacheReadInputTokens"])
        let cacheCreation = numberToInt(value["cache_creation_input_tokens"]) ?? numberToInt(value["cacheCreationInputTokens"])

        let hasAnyUsageField = input != nil || output != nil || cacheRead != nil || cacheCreation != nil
        guard hasAnyUsageField else { return nil }

        let normalizedInput = max(0, input ?? 0)
        let normalizedOutput = max(0, output ?? 0)
        let hasContextBreakdown = input != nil || cacheRead != nil || cacheCreation != nil
        let contextUsedTokens: Int? = hasContextBreakdown
            ? saturatedNonNegativeSum(normalizedInput, max(0, cacheRead ?? 0), max(0, cacheCreation ?? 0))
            : nil

        return TokenUsage(
            inputTokens: normalizedInput,
            outputTokens: normalizedOutput,
            contextUsedTokens: contextUsedTokens
        )
    }

    private func saturatedNonNegativeSum(_ values: Int...) -> Int {
        var total = 0
        for value in values {
            let nonNegative = max(0, value)
            let result = total.addingReportingOverflow(nonNegative)
            if result.overflow {
                return Int.max
            }
            total = result.partialValue
        }
        return total
    }

    private func numberToInt(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            guard double.isFinite else { return nil }
            return Int(exactly: double)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            if let exactInteger = Int(number.stringValue) {
                return exactInteger
            }
            let double = number.doubleValue
            guard double.isFinite else { return nil }
            return Int(exactly: double)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let int = Int(trimmed) {
                return int
            }
            guard let double = Double(trimmed), double.isFinite else { return nil }
            return Int(exactly: double)
        default:
            return nil
        }
    }
}
