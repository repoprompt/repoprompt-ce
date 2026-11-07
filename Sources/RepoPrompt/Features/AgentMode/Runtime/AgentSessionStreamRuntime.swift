import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Provider event application and buffered transcript mutation. Presentation is optional; accepted
/// stream events, usage and terminal transcript repair remain runtime work when it detaches.
@MainActor
final class AgentSessionStreamRuntime {
    private weak var scope: AgentSessionRuntimeStore.Scope?
    private let usage: AgentSessionUsageRuntime
    private let persistence: AgentSessionPersistenceRuntime
    private let presentation: AgentSessionPresentationRuntime
    weak var runService: AgentModeRunService?
    weak var codexCoordinator: CodexAgentModeCoordinator?
    var assistantFlushDelay: () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
        usage = scope.usage
        persistence = scope.persistence
        presentation = scope.presentation
    }

    func makeRunHooks() -> AgentModeRunService.TranscriptProjectionHooks {
        .init(
            handleHeadlessStreamResult: { [self] result, session, runID, attemptID in
                await handleStreamResult(result, session: session, runID: runID, runAttemptID: attemptID)
            },
            finalizeStreamingItems: { [self] in finalizeStreamingItems(in: $0) },
            finalizePendingToolCalls: { [self] session, state in
                _ = finalizePendingToolCalls(in: session, terminalState: state, includeExplicitRepoPromptToolCalls: AgentTranscriptQualityRepair.shouldFinalizeExplicitRepoPromptTools(context: .liveTerminal(agentKind: session.selectedAgent)))
            },
            finalizePendingToolCallsWithUpperBound: { [self] session, state, upperBound in
                _ = finalizePendingToolCalls(in: session, terminalState: state, includeExplicitRepoPromptToolCalls: AgentTranscriptQualityRepair.shouldFinalizeExplicitRepoPromptTools(context: .liveTerminal(agentKind: session.selectedAgent)), maxSequenceIndexExclusive: upperBound)
            },
            flushPendingAssistantDelta: { [self] in flushPendingAssistantDelta($0) },
            beginClaudeProviderOutputSegment: { [self] in flushPendingAssistantDelta($0)
                endActiveAssistantSegment($0)
            },
            clearPendingAssistantDelta: { [self] in clearPendingAssistantDelta($0) }
        )
    }

    func makeToolTrackingHooks() -> AgentToolTrackingHooks {
        .init(
            flushPendingAssistantDelta: { [self] in flushPendingAssistantDelta($0) },
            endActiveAssistantSegment: { [self] in endActiveAssistantSegment($0) },
            endActiveReasoningSegment: { [self] in endActiveReasoningSegment($0) },
            sealAssistantBoundary: { [self] in flushPendingAssistantDelta($0)
                endActiveAssistantSegment($0)
            },
            requestUIRefresh: { [presentation] in presentation.makeRunHooks().requestUIRefresh($0, $1) },
            scheduleSave: { [persistence] in persistence.scheduleSave(for: $0) },
            addToolInputTokens: { [usage] in usage.addToolInputTokens($0, for: $1) },
            addToolOutputTokens: { [usage] in usage.addToolOutputTokens($0, for: $1) }
        )
    }

    private static let claudeReasoningStatusBufferCharacterLimit = 4000
    private static let claudeReasoningStatusPreviewCharacterLimit = 128
    private static let claudeReasoningStatusUpdateIntervalNanos: UInt64 = 120_000_000

    #if DEBUG
        private static func claudeReasoningDebug(_ message: @autoclosure () -> String) {
            guard ClaudeReasoningExtractionFeature.isEnabled else { return }
            let line = "[ClaudeReasoningDebug][ViewModel] \(message())"
            print(line)
            ClaudeReasoningDebugLog.append(line)
        }
    #else
        private static func claudeReasoningDebug(_ message: @autoclosure () -> String) {}
    #endif

    private static func claudeReasoningDebugSnippet(_ text: String, limit: Int = 160) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(limit)
            .description
    }

    static func claudeReasoningStatusPreview(from rawBuffer: String) -> String? {
        let trimmed = rawBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = ReasoningTextFormatter.normalize(trimmed)
        let candidateLine = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
            ?? normalized
        let collapsed = candidateLine
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let cleaned = stripClaudeReasoningPreviewDecoration(collapsed)
        guard !cleaned.isEmpty else { return nil }
        return tailTruncatedOneLine(cleaned, limit: claudeReasoningStatusPreviewCharacterLimit)
    }

    private static func stripClaudeReasoningPreviewDecoration(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("#") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for marker in ["- ", "* ", "• "] where value.hasPrefix(marker) {
            value.removeFirst(marker.count)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.hasPrefix("**"), value.hasSuffix("**"), value.count > 4 {
            value.removeFirst(2)
            value.removeLast(2)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func tailTruncatedOneLine(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let suffixLimit = max(1, limit - 1)
        var suffix = String(text.suffix(suffixLimit))
        if let firstWhitespace = suffix.firstIndex(where: { $0.isWhitespace }),
           firstWhitespace != suffix.startIndex
        {
            suffix = String(suffix[suffix.index(after: firstWhitespace)...])
        }
        if suffix.count > suffixLimit {
            suffix = String(suffix.suffix(suffixLimit))
        }
        return "…" + suffix
    }

    private static func claudeDisplayableStatusText(_ raw: String?) -> String? {
        var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "Permission mode:", options: [.caseInsensitive]) {
            text = String(text[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while text.hasSuffix("—") || text.hasSuffix("-") {
                text.removeLast()
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !text.isEmpty else { return nil }
        return text
    }

    @discardableResult
    func setTransportRunningStatus(
        _ text: String?,
        session: AgentTabSession,
        allowOverrideReasoning: Bool = false
    ) -> Bool {
        if session.runningStatusSource == .reasoning, !allowOverrideReasoning {
            return false
        }
        if allowOverrideReasoning {
            session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        }
        return session.setRunningStatus(text, source: .transport)
    }

    @discardableResult
    func applyClaudeReasoningStatusDelta(_ delta: String, session: AgentTabSession) -> Bool {
        guard ClaudeReasoningExtractionFeature.isEnabled else { return false }
        guard session.selectedAgent.usesClaudeNativeRuntime else {
            Self.claudeReasoningDebug("drop delta for non-Claude-native agent tab=\(session.tabID.uuidString) selectedAgent=\(session.selectedAgent.rawValue)")
            return false
        }
        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDelta.isEmpty else {
            Self.claudeReasoningDebug("drop empty reasoning delta tab=\(session.tabID.uuidString)")
            return false
        }
        Self.claudeReasoningDebug("apply delta tab=\(session.tabID.uuidString) deltaLen=\(delta.count) trimmedLen=\(trimmedDelta.count) snippet=\(Self.claudeReasoningDebugSnippet(delta)) statusBefore=\(session.runningStatusText ?? "nil") sourceBefore=\(String(describing: session.runningStatusSource))")
        session.claudeReasoningStatusBuffer = delta
        if session.claudeReasoningStatusBuffer.count > Self.claudeReasoningStatusBufferCharacterLimit {
            session.claudeReasoningStatusBuffer = String(session.claudeReasoningStatusBuffer.suffix(Self.claudeReasoningStatusBufferCharacterLimit))
            Self.claudeReasoningDebug("trimmed reasoning buffer tab=\(session.tabID.uuidString) bufferLen=\(session.claudeReasoningStatusBuffer.count)")
        }
        guard let preview = Self.claudeReasoningStatusPreview(from: session.claudeReasoningStatusBuffer) else {
            Self.claudeReasoningDebug("no displayable preview tab=\(session.tabID.uuidString) bufferLen=\(session.claudeReasoningStatusBuffer.count)")
            return false
        }
        Self.claudeReasoningDebug("pending preview tab=\(session.tabID.uuidString) preview=\(Self.claudeReasoningDebugSnippet(preview)) existingFlushTask=\(session.claudeReasoningStatusFlushTask != nil)")
        if session.runningStatusSource == .reasoning {
            session.claudeReasoningStatusPendingText = nil
            session.claudeReasoningStatusFlushTask?.cancel()
            session.claudeReasoningStatusFlushTask = nil
            let changed = session.setRunningStatus(preview, source: .reasoning)
            Self.claudeReasoningDebug("replace visible preview tab=\(session.tabID.uuidString) changed=\(changed) preview=\(Self.claudeReasoningDebugSnippet(preview))")
            if changed {
                presentation.makeRunHooks().requestUIRefresh(session, false)
            }
            return changed
        }
        session.claudeReasoningStatusPendingText = preview
        guard session.claudeReasoningStatusFlushTask == nil else { return false }
        let binding = session.persistentSessionBindingIdentity
        let capturedScope = scope
        session.claudeReasoningStatusFlushTask = Task { [self, session, capturedScope] in
            do {
                try await Task.sleep(nanoseconds: Self.claudeReasoningStatusUpdateIntervalNanos)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard capturedScope?.sessions[session.tabID] === session,
                      session.persistentSessionBindingIdentity == binding
                else {
                    // This uncancelled task still owns the pending slot. Do not leave a completed
                    // task there to suppress every later preview after a binding transition.
                    session.claudeReasoningStatusPendingText = nil
                    session.claudeReasoningStatusFlushTask = nil
                    return
                }
                session.claudeReasoningStatusFlushTask = nil
                guard session.selectedAgent.usesClaudeNativeRuntime else {
                    Self.claudeReasoningDebug("flush dropped for non-Claude-native agent tab=\(session.tabID.uuidString) selectedAgent=\(session.selectedAgent.rawValue)")
                    return
                }
                guard let pendingText = session.claudeReasoningStatusPendingText else {
                    Self.claudeReasoningDebug("flush found no pending text tab=\(session.tabID.uuidString)")
                    return
                }
                session.claudeReasoningStatusPendingText = nil
                let changed = session.setRunningStatus(pendingText, source: .reasoning)
                Self.claudeReasoningDebug("flush preview tab=\(session.tabID.uuidString) changed=\(changed) pending=\(Self.claudeReasoningDebugSnippet(pendingText)) statusAfter=\(session.runningStatusText ?? "nil") sourceAfter=\(String(describing: session.runningStatusSource))")
                if changed {
                    self.presentation.makeRunHooks().requestUIRefresh(session, false)
                }
            }
        }
        return false
    }

    @discardableResult
    func clearClaudeReasoningStatus(_ session: AgentTabSession) -> Bool {
        guard session.selectedAgent.usesClaudeNativeRuntime else { return false }
        let shouldLog = !session.claudeReasoningStatusBuffer.isEmpty
            || session.claudeReasoningStatusPendingText != nil
            || session.claudeReasoningStatusFlushTask != nil
            || session.runningStatusSource == .reasoning
        if shouldLog {
            Self.claudeReasoningDebug("clear status tab=\(session.tabID.uuidString) bufferLen=\(session.claudeReasoningStatusBuffer.count) pending=\(session.claudeReasoningStatusPendingText ?? "nil") source=\(String(describing: session.runningStatusSource))")
        }
        let changed = session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        if shouldLog {
            Self.claudeReasoningDebug("clear status complete tab=\(session.tabID.uuidString) changed=\(changed) statusAfter=\(session.runningStatusText ?? "nil") sourceAfter=\(String(describing: session.runningStatusSource))")
        }
        return changed
    }

    func handleStreamResult(
        _ result: AIStreamResult,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async {
        if session.activeRunAttemptID != runAttemptID,
           let reroutedSession = scope?.sessions.values.first(where: {
               $0.runID == runID && $0.activeRunAttemptID == runAttemptID
           }),
           reroutedSession !== session
        {
            await handleStreamResult(
                result,
                session: reroutedSession,
                runID: runID,
                runAttemptID: runAttemptID
            )
            return
        }
        await MainActor.run {
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID,
                  let owner = session.activeRunOwnership,
                  session.isCurrentRunAttemptForCurrentBinding(owner) else { return }
            session.noteAcceptedStream(result, owner: owner)
            var shouldUpdateBindings = false
            switch result.type {
            case "content":
                // Normal content text
                guard let content = result.text, !content.isEmpty else { break }
                shouldUpdateBindings = clearClaudeReasoningStatus(session) || shouldUpdateBindings
                enqueueAssistantDelta(content, session: session)

            case "final_content":
                // Final authoritative message content for the turn.
                guard let content = result.text else { break }
                shouldUpdateBindings = clearClaudeReasoningStatus(session) || shouldUpdateBindings
                // Materialize any pending content delta first so we preserve ordering.
                flushPendingAssistantDelta(session)
                guard AgentDisplayableText.hasDisplayableBody(content) else { break }

                // Search backward for a trailing assistant bubble. It may not be the
                // very last item if system events (e.g. rate-limit telemetry) were
                // interleaved, which can prematurely finalize the streaming segment.
                // Walk past system items but stop at tool calls, user messages, etc.
                let attemptStartKey = session.quietLedger.startKey(owner: owner) ?? session.nextSequenceIndex
                let providerStartKey = session.claudeProviderOutputBoundary.flatMap { $0.attemptID == owner.attemptID ? $0.startSequenceIndex : nil }
                let outputStartKey = max(attemptStartKey, providerStartKey ?? attemptStartKey)
                let tailAssistantIndex: Int? = {
                    if let streamingAssistantIndex = self.resumableStreamingAssistantIndexAcrossTrailingUserInterjections(in: session),
                       session.items[streamingAssistantIndex].sequenceIndex >= outputStartKey
                    {
                        return streamingAssistantIndex
                    }
                    for i in session.items.indices.reversed() {
                        switch session.items[i].kind {
                        case .assistant:
                            return session.items[i].sequenceIndex >= outputStartKey ? i : nil
                        case .system:
                            continue
                        default:
                            return nil
                        }
                    }
                    return nil
                }()

                if let index = tailAssistantIndex {
                    var updated = session.items[index]
                    updated.text = content
                    updated.isStreaming = false
                    session.replaceItem(at: index, with: updated)
                } else {
                    let assistantItem = AgentChatItem.assistant(content, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(assistantItem)
                }
                shouldUpdateBindings = true

            case "reasoning":
                guard ClaudeReasoningExtractionFeature.isEnabled else { break }
                // Claude provider-internal reasoning/thinking traces update only the
                // transient running-status row. They are intentionally never added to
                // the persisted chat transcript.
                Self.claudeReasoningDebug("handleStreamResult reasoning tab=\(session.tabID.uuidString) hasReasoning=\(result.reasoning != nil) textLen=\(result.text?.count ?? 0) reasoningLen=\(result.reasoning?.count ?? 0) selectedAgent=\(session.selectedAgent.rawValue)")
                if session.selectedAgent.usesClaudeNativeRuntime,
                   let reasoning = result.reasoning ?? result.text
                {
                    shouldUpdateBindings = applyClaudeReasoningStatusDelta(reasoning, session: session) || shouldUpdateBindings
                } else {
                    Self.claudeReasoningDebug("reasoning result ignored tab=\(session.tabID.uuidString) usesClaudeNative=\(session.selectedAgent.usesClaudeNativeRuntime)")
                }

            case "tool_call":
                // Structured tool call event with args. Keep any Claude reasoning
                // status visible through tool execution; it is replaced by the next
                // reasoning update or cleared when assistant content starts.
                guard let toolName = result.toolName else { break }
                let argsJSON = result.toolArgsJSON ?? result.toolArgs
                flushPendingAssistantDelta(session)
                endActiveAssistantSegment(session)
                endActiveReasoningSegment(session)
                // Route provider-specific tool events through dedicated handlers.
                if runService?.handleProviderToolStreamEvent(result, session: session) == true {
                    shouldUpdateBindings = true
                    break
                }
                if AgentToolTrackingSupport.shouldSuppressProviderToolEvent(
                    toolName: toolName,
                    invocationID: result.toolInvocationID
                ) {
                    break
                }
                usage.addToolInputTokens(argsJSON, for: session)
                guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { break }
                if AgentToolTrackingSupport.shouldAutoCompleteProviderToolCall(
                    for: session,
                    toolName: toolName,
                    invocationID: result.toolInvocationID
                ) {
                    let syntheticResultJSON = AgentToolTrackingSupport.syntheticCompletedToolResultJSON(
                        note: "Provider emitted tool_call without a matching tool_result event."
                    )
                    var toolResultItem = AgentChatItem.toolResult(
                        name: toolName,
                        invocationID: result.toolInvocationID,
                        resultJSON: syntheticResultJSON,
                        isError: false,
                        sequenceIndex: session.nextSequenceIndex
                    )
                    toolResultItem.toolArgsJSON = argsJSON
                    session.appendItem(toolResultItem)
                } else {
                    let toolItem = AgentChatItem.toolCall(name: toolName, invocationID: result.toolInvocationID, argsJSON: argsJSON, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(toolItem)
                }
                shouldUpdateBindings = true

            case "tool_result":
                // Structured tool result event with output. Preserve Claude reasoning
                // status across tool results.
                guard let toolName = result.toolName else { break }
                let outputJSON = result.toolResultJSON ?? result.toolOutput ?? ""
                let argsJSON = result.toolArgsJSON ?? result.toolArgs
                flushPendingAssistantDelta(session)
                endActiveAssistantSegment(session)
                endActiveReasoningSegment(session)
                // Route provider-specific tool events through dedicated handlers.
                if runService?.handleProviderToolStreamEvent(result, session: session) == true {
                    shouldUpdateBindings = true
                    break
                }
                if AgentToolTrackingSupport.shouldSuppressProviderToolEvent(
                    toolName: toolName,
                    invocationID: result.toolInvocationID
                ) {
                    break
                }
                usage.addToolOutputTokens(outputJSON, for: session)
                guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { break }
                let invocationID = result.toolInvocationID
                if let invocationID,
                   let index = session.items.lastIndex(where: { $0.toolInvocationID == invocationID })
                {
                    var updated = session.items[index]
                    updated.kind = .toolResult
                    updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
                    if let payload = AgentToolResultPayloadRetention.resolvedPayload(
                        existing: updated.toolResultJSON,
                        incoming: outputJSON,
                        incomingIsError: result.toolIsError
                    ) {
                        updated.toolResultJSON = payload
                        updated.toolIsError = result.toolIsError
                        updated.text = payload
                    }
                    session.replaceItem(at: index, with: updated)
                } else if let index = session.items.lastIndex(where: { $0.kind == .toolCall && $0.toolName == toolName }) {
                    var updated = session.items[index]
                    updated.kind = .toolResult
                    updated.toolInvocationID = invocationID ?? updated.toolInvocationID
                    updated.toolResultJSON = outputJSON
                    updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
                    updated.toolIsError = result.toolIsError
                    updated.text = outputJSON
                    session.replaceItem(at: index, with: updated)
                } else {
                    let toolResultItem = AgentChatItem.toolResult(
                        name: toolName,
                        invocationID: invocationID,
                        resultJSON: outputJSON,
                        isError: result.toolIsError,
                        sequenceIndex: session.nextSequenceIndex
                    )
                    session.appendItem(toolResultItem)
                }
                codexCoordinator?.reconcileCodexCommandExecutionRunningUpdate(
                    toolName: toolName,
                    argsJSON: argsJSON,
                    resultJSON: outputJSON,
                    isError: result.toolIsError,
                    session: session
                )
                shouldUpdateBindings = true

            case "event":
                // Legacy tool usage event (e.g., "Using tool: read_file") - fallback for compatibility
                if let eventText = result.text, eventText.hasPrefix("Using tool: ") {
                    flushPendingAssistantDelta(session)
                    endActiveAssistantSegment(session)
                    endActiveReasoningSegment(session)
                    let toolName = String(eventText.dropFirst("Using tool: ".count))
                    if AgentToolTrackingSupport.shouldSuppressProviderToolEvent(toolName: toolName, invocationID: nil) {
                        break
                    }
                    guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { break }
                    let toolItem = AgentChatItem.toolCall(name: toolName, argsJSON: nil, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(toolItem)
                    shouldUpdateBindings = true
                }

            case "tool_progress":
                if let progress = result.text?.trimmingCharacters(in: .whitespacesAndNewlines), !progress.isEmpty {
                    shouldUpdateBindings = setTransportRunningStatus(progress, session: session) || shouldUpdateBindings
                }

            case "status":
                usage.nonCodexContextUsageEstimator(for: session.selectedAgent)?.ingestStatusSignal(result.text, session: session)
                let statusText = session.selectedAgent.usesClaudeNativeRuntime
                    ? Self.claudeDisplayableStatusText(result.text)
                    : result.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let statusText, !statusText.isEmpty {
                    shouldUpdateBindings = setTransportRunningStatus(statusText, session: session) || shouldUpdateBindings
                } else if session.selectedAgent.usesClaudeNativeRuntime,
                          result.text?.range(of: "Permission mode:", options: [.caseInsensitive]) != nil,
                          session.runningStatusSource != .reasoning
                {
                    shouldUpdateBindings = session.setRunningStatus(nil, source: nil) || shouldUpdateBindings
                }

            case "usage":
                if usage.ingestNonCodexUsageReport(
                    promptTokens: result.promptTokens,
                    completionTokens: result.completionTokens,
                    contextUsedTokens: result.contextUsedTokens,
                    modelContextWindow: result.modelContextWindow,
                    session: session
                ) {
                    shouldUpdateBindings = true
                }

            case "auth_status":
                if let status = result.text?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
                    shouldUpdateBindings = setTransportRunningStatus(status, session: session, allowOverrideReasoning: true) || shouldUpdateBindings
                    let systemItem = AgentChatItem.system(status, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(systemItem)
                    shouldUpdateBindings = true
                }

            case "session_state_changed":
                // Claude Code lifecycle event — update run-state UI only, no transcript rows.
                let state = result.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                switch state {
                case "idle":
                    shouldUpdateBindings = clearClaudeReasoningStatus(session) || shouldUpdateBindings
                    shouldUpdateBindings = session.setRunningStatus(nil, source: nil) || shouldUpdateBindings
                case "running":
                    // Keep active reasoning previews; otherwise show the generic fallback.
                    if session.runningStatusText == nil {
                        shouldUpdateBindings = setTransportRunningStatus("Thinking…", session: session) || shouldUpdateBindings
                    }
                default:
                    if !state.isEmpty {
                        // Humanize: replace underscores with spaces, capitalize words
                        let humanized = state.replacingOccurrences(of: "_", with: " ").capitalized
                        shouldUpdateBindings = setTransportRunningStatus(humanized, session: session) || shouldUpdateBindings
                    }
                }

            case "task_progress":
                // Claude Code task progress — update running status text, no transcript rows.
                // Do not displace a visible Claude reasoning preview.
                if let progressText = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !progressText.isEmpty
                {
                    shouldUpdateBindings = setTransportRunningStatus(progressText, session: session) || shouldUpdateBindings
                }

            case "system":
                // System messages - skip lifecycle messages that don't need UI display.
                // Preserve Claude reasoning previews until the next reasoning or assistant message.
                if let text = result.text, !text.isEmpty {
                    if session.selectedAgent == .antigravity,
                       text.trimmingCharacters(in: .whitespacesAndNewlines)
                       .range(of: #"^I\d{4}\s+\d+\s"#, options: .regularExpression) != nil
                    {
                        break
                    }
                    usage.nonCodexContextUsageEstimator(for: session.selectedAgent)?.ingestSystemSignal(text, session: session)
                    flushPendingAssistantDelta(session)
                    endActiveAssistantSegment(session)
                    // Filter out agent lifecycle messages that shouldn't appear in chat
                    let skipMessages = ["Agent initialized", "Agent completed", "Agent cancelled"]
                    guard !skipMessages.contains(text) else { break }
                    let systemItem = AgentChatItem.system(text, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(systemItem)
                    shouldUpdateBindings = true
                }

            case "error":
                // Error messages. Preserve Claude reasoning previews until terminal
                // finalization clears run state.
                if let text = result.text, !text.isEmpty {
                    flushPendingAssistantDelta(session)
                    endActiveAssistantSegment(session)
                    let errorItem = AgentChatItem.error(text, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(errorItem)
                    shouldUpdateBindings = true
                }

            case "message_stop":
                shouldUpdateBindings = clearClaudeReasoningStatus(session) || shouldUpdateBindings
                shouldUpdateBindings = session.setRunningStatus(nil, source: nil) || shouldUpdateBindings
                flushPendingAssistantDelta(session)
                endActiveAssistantSegment(session)
                // Stream completed - assistant streaming segments already finalized above.

                // Store provider session ID for resumption (native Claude or ACP runtimes).
                if let sessionID = result.providerSessionID,
                   session.selectedAgent.usesClaudeNativeRuntime || session.selectedAgent.acpProviderID != nil
                {
                    session.providerSessionID = sessionID
                    session.providerCleanupHandle = ProviderConversationCleanupHandle.resolved(
                        provider: session.selectedAgent.rawValue,
                        explicit: nil,
                        providerSessionID: sessionID,
                        codexConversationID: session.codexConversationID,
                        codexRolloutPath: session.codexRolloutPath
                    )
                    session.isDirty = true
                    persistence.scheduleSave(for: session)
                }

                // Track per-turn token usage for resumable non-Codex agents.
                if usage.ingestNonCodexTurnFinalization(
                    promptTokens: result.promptTokens,
                    completionTokens: result.completionTokens,
                    contextUsedTokens: result.contextUsedTokens,
                    modelContextWindow: result.modelContextWindow,
                    session: session
                ) {
                    persistence.scheduleSave(for: session)
                }
                shouldUpdateBindings = true

            case AIStreamResult.lifecycleType:
                // Lifecycle events (init/complete/cancel) are not rendered in chat
                // They're handled via session.runState for UI state management
                break

            default:
                break
            }

            if shouldUpdateBindings {
                presentation.makeRunHooks().requestUIRefresh(session, false)
            }
        }
    }

    func finalizeStreamingItems(in session: AgentTabSession) {
        // This owner changes streaming flags only, never membership, keys or completed text.
        session.mutateItemsBatch(touchActivity: false, preservesQuietRange: true) { items in
            for index in items.indices where items[index].isStreaming {
                items[index].isStreaming = false
            }
        }
    }

    @discardableResult
    func finalizePendingToolCalls(
        in session: AgentTabSession,
        terminalState: AgentSessionRunState,
        includeExplicitRepoPromptToolCalls: Bool = false
    ) -> Int {
        finalizePendingToolCalls(
            in: session,
            terminalState: terminalState,
            includeExplicitRepoPromptToolCalls: includeExplicitRepoPromptToolCalls,
            maxSequenceIndexExclusive: nil
        )
    }

    @discardableResult
    func finalizePendingToolCalls(
        in session: AgentTabSession,
        terminalState: AgentSessionRunState,
        includeExplicitRepoPromptToolCalls: Bool = false,
        maxSequenceIndexExclusive: Int?
    ) -> Int {
        var finalizedCount = 0
        session.mutateItemsBatch(touchActivity: false) { items in
            finalizedCount = Self.finalizePendingToolCallsInItems(
                &items,
                terminalState: terminalState,
                includeExplicitRepoPromptToolCalls: includeExplicitRepoPromptToolCalls,
                maxSequenceIndexExclusive: maxSequenceIndexExclusive
            )
        }
        if finalizedCount > 0 {
            AgentSessionTranscriptRefreshRuntime.refreshDerivedTranscriptState(for: session, reason: .manualRefresh)
            presentation.derivedTranscriptChanged(session)
        }
        #if DEBUG
            if includeExplicitRepoPromptToolCalls || finalizedCount > 0 {
                let tail = session.items.suffix(6).map { item in
                    let tool = item.toolName ?? "-"
                    return "\(item.sequenceIndex):\(item.kind.rawValue):\(tool)"
                }.joined(separator: " | ")
                print("[ACPAgentRunToolTracking] finalizePendingToolCalls session=\(session.activeAgentSessionID?.uuidString ?? "nil") agent=\(session.selectedAgent.rawValue) state=\(terminalState.rawValue) includeExplicit=\(includeExplicitRepoPromptToolCalls) finalized=\(finalizedCount) tail=\(tail)")
            }
        #endif
        return finalizedCount
    }

    @discardableResult
    nonisolated static func finalizePendingToolCallsInItems(
        _ items: inout [AgentChatItem],
        terminalState: AgentSessionRunState,
        includeExplicitRepoPromptToolCalls: Bool = false,
        maxSequenceIndexExclusive: Int?
    ) -> Int {
        AgentTranscriptIO.finalizePendingToolCalls(
            in: &items,
            terminalState: terminalState,
            includeExplicitRepoPromptToolCalls: includeExplicitRepoPromptToolCalls,
            maxSequenceIndexExclusive: maxSequenceIndexExclusive,
            nonToolBoundary: AgentSessionTranscriptRefreshRuntime.pendingToolFinalizationNonToolBoundary
        )
    }

    func enqueueAssistantDelta(_ delta: String, session: AgentTabSession) {
        session.pendingAssistantDelta += delta
        if session.assistantDeltaFlushTask == nil {
            session.assistantDeltaTaskGeneration &+= 1
            let taskGeneration = session.assistantDeltaTaskGeneration
            let binding = session.persistentSessionBindingIdentity
            let capturedScope = scope
            session.assistantDeltaFlushTask = Task { [self, session, capturedScope] in
                do {
                    try await assistantFlushDelay()
                } catch {
                    return
                }
                await MainActor.run {
                    guard !Task.isCancelled, session.assistantDeltaTaskGeneration == taskGeneration else { return }
                    guard capturedScope?.sessions[session.tabID] === session,
                          session.persistentSessionBindingIdentity == binding
                    else {
                        clearPendingAssistantDelta(session)
                        return
                    }
                    self.flushPendingAssistantDelta(session)
                }
            }
        }
    }

    func clearPendingAssistantDelta(_ session: AgentTabSession) {
        session.pendingAssistantDelta = ""
        session.assistantDeltaTaskGeneration &+= 1
        session.assistantDeltaFlushTask?.cancel()
        session.assistantDeltaFlushTask = nil
    }

    func flushPendingAssistantDelta(_ session: AgentTabSession) {
        guard !session.pendingAssistantDelta.isEmpty else { return }
        let delta = session.pendingAssistantDelta
        clearPendingAssistantDelta(session)
        if applyAssistantDelta(delta, session: session) {
            session.assistantDeltaFlushGeneration &+= 1
            presentation.assistantDeltaApplied(
                session,
                sourceItemsRevision: session.sourceItemsRevision,
                flushGeneration: session.assistantDeltaFlushGeneration
            )
        }
    }

    private func resumableStreamingAssistantIndexAcrossTrailingUserInterjections(in session: AgentTabSession) -> Int? {
        for index in session.items.indices.reversed() {
            let item = session.items[index]
            if item.kind == .assistant, item.isStreaming {
                return index
            }
            guard item.kind == .user else {
                return nil
            }
        }
        return nil
    }

    @discardableResult
    func applyAssistantDelta(_ delta: String, session: AgentTabSession) -> Bool {
        if let streamingAssistantIndex = resumableStreamingAssistantIndexAcrossTrailingUserInterjections(in: session) {
            session.mutateItem(at: streamingAssistantIndex) { item in
                item.text += delta
            }
            return true
        }

        guard AgentDisplayableText.hasDisplayableBody(delta) else {
            return false
        }
        var assistantItem = AgentChatItem.assistant(delta, sequenceIndex: session.nextSequenceIndex)
        assistantItem.isStreaming = true
        session.appendItem(assistantItem)
        return true
    }

    func endActiveAssistantSegment(_ session: AgentTabSession) {
        // Only streaming flags change here; source identity, text and order remain complete.
        session.mutateItemsBatch(touchActivity: false, preservesQuietRange: true) { items in
            for index in items.indices where items[index].kind == .assistant && items[index].isStreaming {
                items[index].isStreaming = false
            }
        }
    }

    func applyReasoningDelta(_ delta: String, groupID: String?, session: AgentTabSession) {
        if let groupID, let localID = session.reasoningItemIDsByGroupID[groupID],
           let index = session.items.firstIndex(where: { $0.id == localID })
        {
            session.mutateItem(at: index) { item in
                item.text += delta
            }
            session.activeReasoningItemID = localID
        } else if let activeID = session.activeReasoningItemID,
                  groupID == nil,
                  let index = session.items.firstIndex(where: { $0.id == activeID })
        {
            session.mutateItem(at: index) { item in
                item.text += delta
            }
        } else {
            var thinkingItem = AgentChatItem.thinking(delta, sequenceIndex: session.nextSequenceIndex)
            thinkingItem.isStreaming = true
            session.appendItem(thinkingItem)
            session.activeReasoningItemID = thinkingItem.id
            if let groupID {
                session.reasoningItemIDsByGroupID[groupID] = thinkingItem.id
            }
        }
    }

    func endActiveReasoningSegment(_ session: AgentTabSession) {
        let activeIDs = Set(session.reasoningItemIDsByGroupID.values)
        let allIDs = session.activeReasoningItemID.map { activeIDs.union([$0]) } ?? activeIDs
        session.mutateItemsBatch(touchActivity: false) { items in
            for itemID in allIDs {
                if let index = items.firstIndex(where: { $0.id == itemID }),
                   items[index].kind == .thinking,
                   items[index].isStreaming
                {
                    items[index].isStreaming = false
                }
            }
        }
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
    }
}
