import Foundation
import MCP

// SEARCH-HELPER: Claude, ToolTracking, ToolCorrelation, TrackerLifecycle, ProviderToolStream
/// Dedicated tool-tracking handler for Claude agent sessions.
///
/// Owns:
/// - Shared `AgentToolTrackingController` lifecycle management
/// - Dual-source provider/tracker tool correlation (the hardest provider-specific logic)
/// - Turn-scoped correlation state reset between Claude turns
/// - Provider-stream RepoPrompt tool call/result handling (slot reservation + enrichment)
/// - MCP tracker callback → transcript item mutation for RepoPrompt tools
///
/// Related:
/// - ClaudeAgentModeCoordinator: /RepoPrompt/Services/AgentMode/Claude/ClaudeAgentModeCoordinator.swift
/// - AgentToolTrackingController: /RepoPrompt/Services/AI/Agents/AgentToolTracker.swift
/// - AgentToolTrackingContracts: /RepoPrompt/Services/AgentMode/ToolTracking/AgentToolTrackingContracts.swift
@MainActor
final class ClaudeAgentToolTrackingHandler {
    struct ExplicitProviderToolResultAckObservation: Equatable {
        let timestamp: Date
        let runID: UUID?
        let toolName: String
        let invocationID: UUID?
        let counted: Bool
        let reason: String
        let ackCountAfterEvent: Int
    }

    struct ExplicitProviderToolResultAckSnapshot: Equatable {
        let requestedRunID: UUID
        let trackedRunID: UUID?
        let ackCount: Int
        let ackedInvocationCount: Int
        let recentObservations: [ExplicitProviderToolResultAckObservation]
    }

    private struct AckWaiter {
        let runID: UUID
        let minimumAckCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    // MARK: - Tracker State

    private let trackingController = AgentToolTrackingController()
    private let maxExplicitProviderAckObservationCount = 24

    // MARK: - Correlation State (moved from AgentTabSession)

    /// Pending provider-stream invocation IDs queued for correlation with tracker callbacks, keyed by signature.
    private enum CorrelationSlot: Hashable {
        case signature(String)
        case native(attemptID: UUID, toolUseID: String)
    }

    private var pendingProviderRepoPromptInvocationsBySignature: [CorrelationSlot: [UUID]] = [:]
    /// Maps tracker invocation IDs to provider-stream invocation IDs for dual-source correlation.
    private struct TrackerCorrelation {
        var providerID: UUID
        var nativeID: String?
        var owner: AgentRunOwnership?
        var nativeCallSeen = false
        var nativeResultSeen = false
        var hostResultSeen = false
        var ambiguous = false
    }

    // Enrich the existing, turn-reset correlation map; no parallel invocation registry.
    private var providerInvocationByTrackerInvocationID: [UUID: TrackerCorrelation] = [:]
    private var exactObservationOwner: AgentRunOwnership?

    /// Sequence boundary for provider/tracker tool correlation within the active Claude turn.
    private var toolCorrelationStartSequenceIndex: Int = 0
    /// Currently tracked Claude run for explicit provider `tool_result` acknowledgements.
    private var trackedRunID: UUID?
    var currentTrackedRunID: UUID? {
        trackedRunID
    }

    /// Dedup set of explicit provider `tool_result` invocation IDs acknowledged for the tracked run.
    private var explicitProviderToolResultAckedInvocationIDs: Set<UUID> = []
    /// Monotonic count of deduped explicit provider `tool_result` acknowledgements for the tracked run.
    private var explicitProviderToolResultAckCount: Int = 0
    /// Continuation-based waiters parked until the tracked run reaches a minimum explicit provider ACK count.
    private var ackWaitersByID: [UUID: AckWaiter] = [:]
    /// Bounded ring buffer of recent explicit provider ACK observations for diagnostics.
    private var explicitProviderToolResultAckObservations: [ExplicitProviderToolResultAckObservation] = []

    var hooks: AgentToolTrackingHooks

    init(hooks: AgentToolTrackingHooks = .noOp) {
        self.hooks = hooks
    }

    private func diagnosticLog(_ message: @autoclosure () -> String) {
        #if DEBUG
            print("[ClaudeToolTracking] \(message())")
        #endif
    }

    private static func diagnosticID(_ id: UUID?) -> String {
        id?.uuidString ?? "nil"
    }

    private static func diagnosticSignature(_ signature: String) -> String {
        guard !signature.isEmpty else { return "empty" }
        let hash = signature.utf8.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { partial, byte in
            (partial ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return "hash=\(String(format: "%016llx", hash)) chars=\(signature.count)"
    }

    // MARK: - Tracking Lifecycle

    func startTracking(
        runID: UUID,
        session: AgentTabSession,
        clientNameHint: String?
    ) async {
        let capturedOwner = session.runID == runID ? session.activeRunOwnership : nil
        exactObservationOwner = capturedOwner
        if trackedRunID != runID {
            beginTrackingExplicitProviderToolResultAcks(for: runID)
        }
        await trackingController.startTracking(
            runID: runID,
            attemptID: capturedOwner?.attemptID,
            clientNameHint: clientNameHint,
            onCalled: { [weak self, weak session] invocationID, toolName, args in
                guard let self, let session else { return }
                handleTrackerToolCall(
                    invocationID: invocationID,
                    toolName: toolName,
                    args: args,
                    session: session,
                    observationOwner: capturedOwner
                )
            },
            onCompleted: { [weak self, weak session] invocationID, toolName, args, resultJSON, isError in
                guard let self, let session else { return }
                handleTrackerToolResult(
                    invocationID: invocationID,
                    toolName: toolName,
                    args: args,
                    resultJSON: resultJSON,
                    isError: isError,
                    session: session,
                    observationOwner: capturedOwner
                )
            }
        )
    }

    func stopTracking(
        for session: AgentTabSession
    ) async {
        await trackingController.stopTracking()
        resetCorrelationState(session)
        stopTrackingExplicitProviderToolResultAcks()
    }

    func resetTurnState(
        for session: AgentTabSession
    ) {
        let registeredOwner = exactObservationOwner
        resetCorrelationState(session)
        // The send path resets after tracking is registered. Preserve only that same current
        // registration; a successor must register its own callbacks before acquiring exact proof.
        if let registeredOwner,
           session.isCurrentRunAttemptForCurrentBinding(registeredOwner, expectedRunID: trackedRunID)
        {
            exactObservationOwner = registeredOwner
        }
    }

    // MARK: - Provider Stream Event Handling

    @discardableResult
    func handleProviderToolEvent(
        _ event: AgentToolStreamEvent,
        session: AgentTabSession
    ) -> Bool {
        switch event {
        case let .toolCall(call):
            handleProviderToolCall(call, session: session)
        case let .toolResult(result):
            handleProviderToolResult(result, session: session)
        case .legacyEvent:
            // Claude doesn't use legacy "Using tool:" events; not consumed.
            false
        }
    }

    // MARK: - Provider-Stream Tool Call Handling

    /// Handles `tool_call` events from the Claude provider stream.
    /// Returns `true` when the event was consumed (either processed or suppressed).
    private func handleProviderToolCall(
        _ call: AgentToolStreamEvent.ToolCall,
        session: AgentTabSession
    ) -> Bool {
        let toolName = call.toolName

        // Suppress orphan placeholder tool names.
        if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "tool",
           let invocationID = call.invocationID,
           session.indexedToolItemIndices(invocationID: invocationID).isEmpty
        {
            return true
        }

        if handleExactNativeObservation(
            providerID: call.invocationID,
            nativeID: call.claudeToolUseID,
            toolName: toolName,
            argsJSON: call.argsJSON,
            isResult: false,
            session: session
        ) {
            hooks.addToolInputTokens(call.argsJSON, session)
            return true
        }

        // Explicit RepoPrompt tools: handle as provider-sourced slot reservation.
        if AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
           !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName)
        {
            hooks.addToolInputTokens(call.argsJSON, session)
            handleClaudeProviderRepoPromptToolCall(
                invocationID: call.invocationID,
                toolName: toolName,
                argsJSON: call.argsJSON,
                session: session
            )
            return true
        }

        // Non-explicit RepoPrompt tools are suppressed (tracker is authoritative).
        if AgentToolTrackingSupport.shouldSuppressProviderToolEvent(
            toolName: toolName,
            invocationID: call.invocationID
        ) {
            return true
        }

        return false
    }

    /// Handles `tool_result` events from the Claude provider stream.
    /// Returns `true` when the event was consumed (either processed or suppressed).
    private func handleProviderToolResult(
        _ result: AgentToolStreamEvent.ToolResult,
        session: AgentTabSession
    ) -> Bool {
        let toolName = result.toolName
        let outputJSON = result.resultJSON

        recordExplicitProviderToolResultAckIfNeeded(
            toolName: toolName,
            invocationID: result.invocationID
        )

        if handleExactNativeObservation(
            providerID: result.invocationID,
            nativeID: result.claudeToolUseID,
            toolName: toolName,
            argsJSON: result.argsJSON,
            isResult: true,
            session: session
        ) {
            if result.isError == true {
                session.noteUncertainToolCorrelation()
                // A client-side failure may have no host completion. Keep the existing provider
                // result/error rendering instead of leaving its reserved slot pending.
            } else {
                hooks.addToolOutputTokens(outputJSON, session)
                return true
            }
        }

        // Claude Code emits `<tool_use_error>Error: No such tool available: …</tool_use_error>`
        // when the model invokes a tool the CLI doesn't know (e.g. a bare `mcp__RepoPrompt`
        // server prefix with no trailing tool segment). Drop both this error row and the
        // paired placeholder tool_call so the transcript stays clean.
        // See: ClaudeInvalidToolErrorFilter.swift
        if ClaudeInvalidToolErrorFilter.isNoSuchToolAvailableError(
            resultText: outputJSON,
            isError: result.isError
        ) {
            retractInvalidToolPlaceholder(
                toolName: toolName,
                invocationID: result.invocationID,
                session: session
            )
            hooks.requestUIRefresh(session.tabID, false)
            return true
        }

        // Suppress orphan placeholder tool results.
        if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "tool",
           let invocationID = result.invocationID,
           session.indexedToolItemIndices(invocationID: invocationID).isEmpty
        {
            return true
        }

        // Explicit RepoPrompt tool results are consumed from the provider stream. When Claude
        // supplies a provider invocation ID that exactly matches a provider-created slot,
        // terminalize that slot in place so the UI does not stay pending while waiting for
        // the MCP tracker completion. Do not fall back by nil ID, name, or signature here.
        if shouldSuppressClaudeProviderToolResult(
            toolName: toolName,
            argsJSON: result.argsJSON,
            outputJSON: outputJSON,
            isError: result.isError,
            invocationID: result.invocationID,
            session: session
        ) {
            if AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
               !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName)
            {
                hooks.addToolOutputTokens(outputJSON, session)
            }
            return true
        }

        // Non-explicit RepoPrompt tools are suppressed (tracker is authoritative).
        if AgentToolTrackingSupport.shouldSuppressProviderToolEvent(
            toolName: toolName,
            invocationID: result.invocationID
        ) {
            return true
        }

        return false
    }

    /// Remove the placeholder tool_call row paired with a Claude `tool_use_error` that
    /// reported an unknown tool. The tool_call was already appended when the provider
    /// emitted `tool_use`, so this drops it retroactively using the invocation id
    /// (or tool-name fallback) to find the matching row. Both lookups are scoped to
    /// the current correlation turn so an invalid call in this turn cannot retract a
    /// legitimate placeholder left over from a prior turn.
    private func retractInvalidToolPlaceholder(
        toolName: String,
        invocationID: UUID?,
        session: AgentTabSession
    ) {
        let turnStart = toolCorrelationStartSequenceIndex
        func isEligible(_ item: AgentChatItem) -> Bool {
            item.kind == .toolCall && item.sequenceIndex >= turnStart
        }
        let placeholderIndex: Int? = {
            if let invocationID {
                let indexed = session.indexedToolItemIndices(invocationID: invocationID)
                if let byInvocation = indexed.last(where: { isEligible(session.items[$0]) }) {
                    return byInvocation
                }
                let fallback = session.activeTurnToolItemIndices(where: {
                    isEligible($0) && $0.toolInvocationID == invocationID
                })
                if let byInvocation = fallback.lastIndex {
                    return byInvocation
                }
            }
            let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(toolName)
            let indexed = session.indexedNilInvocationToolItemIndices(
                normalizedToolName: normalizedToolName
            )
            if let byName = indexed.last(where: { index in
                let item = session.items[index]
                return isEligible(item) && item.toolName == toolName
            }) {
                return byName
            }
            return session.activeTurnToolItemIndices(where: { item in
                isEligible(item)
                    && item.toolName == toolName
                    && item.toolInvocationID == nil
            }).lastIndex
        }()
        guard let placeholderIndex else { return }
        session.removeItem(at: placeholderIndex)
    }

    // MARK: - Explicit Provider ACK Waiting (Steering Safety)

    func awaitExplicitProviderToolResultAcks(
        for runID: UUID,
        atLeast minimumAckCount: Int
    ) async throws {
        guard minimumAckCount > 0 else { return }
        if trackedRunID == runID, explicitProviderToolResultAckCount >= minimumAckCount {
            return
        }

        let waiterID = UUID()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if trackedRunID == runID, explicitProviderToolResultAckCount >= minimumAckCount {
                    continuation.resume()
                    return
                }
                ackWaitersByID[waiterID] = AckWaiter(
                    runID: runID,
                    minimumAckCount: minimumAckCount,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let waiter = ackWaitersByID.removeValue(forKey: waiterID) {
                    waiter.continuation.resume()
                }
            }
        }

        try Task.checkCancellation()
    }

    func explicitProviderToolResultAckSnapshot(
        for runID: UUID
    ) -> ExplicitProviderToolResultAckSnapshot {
        let isTrackedRun = trackedRunID == runID
        return ExplicitProviderToolResultAckSnapshot(
            requestedRunID: runID,
            trackedRunID: trackedRunID,
            ackCount: isTrackedRun ? explicitProviderToolResultAckCount : 0,
            ackedInvocationCount: isTrackedRun ? explicitProviderToolResultAckedInvocationIDs.count : 0,
            recentObservations: isTrackedRun ? explicitProviderToolResultAckObservations : []
        )
    }

    // MARK: - Provider-Sourced RepoPrompt Tool Handling (Correlation)

    func handleClaudeProviderRepoPromptToolCall(
        invocationID: UUID?,
        toolName: String,
        argsJSON: String?,
        session: AgentTabSession
    ) {
        guard AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName) else { return }
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }

        let storedToolName = Self.canonicalTranscriptToolName(toolName)
        let signature = Self.repoPromptInvocationSignature(toolName: toolName, argsJSON: argsJSON)
        if let existingIndex = findCorrelationItemIndex(
            invocationID: invocationID,
            signature: signature,
            toolName: toolName,
            session: session
        ) {
            var updated = session.items[existingIndex]
            var didMutate = false
            if let providerInvocationID = invocationID,
               updated.kind == .toolCall,
               let trackerInvocationID = updated.toolInvocationID,
               trackerInvocationID != providerInvocationID
            {
                providerInvocationByTrackerInvocationID[trackerInvocationID] = TrackerCorrelation(providerID: providerInvocationID)
            }
            if let providerInvocationID = invocationID {
                if updated.kind == .toolCall, updated.toolInvocationID != providerInvocationID {
                    updated.toolInvocationID = providerInvocationID
                    didMutate = true
                } else if updated.toolInvocationID == nil {
                    updated.toolInvocationID = providerInvocationID
                    didMutate = true
                }
            }
            if updated.toolName != storedToolName {
                updated.toolName = storedToolName
                didMutate = true
            }
            if let argsJSON, argsJSON != updated.toolArgsJSON {
                updated.toolArgsJSON = argsJSON
                didMutate = true
            }
            if didMutate {
                session.replaceItem(at: existingIndex, with: updated)
            }
            if updated.kind == .toolResult {
                // Late provider placeholder: tracker already finalized this tool in the current turn.
                return
            }
            return
        }

        if let invocationID {
            var pending = pendingProviderRepoPromptInvocationsBySignature[.signature(signature), default: []]
            if !pending.contains(invocationID) {
                pending.append(invocationID)
                pendingProviderRepoPromptInvocationsBySignature[.signature(signature)] = pending
            }
        }

        let toolItem = AgentChatItem.toolCall(
            name: storedToolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(toolItem)
    }

    func shouldSuppressClaudeProviderToolResult(
        toolName: String,
        argsJSON: String?,
        outputJSON: String,
        isError: Bool? = nil,
        invocationID: UUID?,
        session: AgentTabSession
    ) -> Bool {
        guard session.selectedAgent.usesClaudeNativeRuntime else { return false }
        if AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
           !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName)
        {
            let terminalizedExactProviderSlot = terminalizeExplicitProviderToolResultIfExactProviderSlot(
                toolName: toolName,
                argsJSON: argsJSON,
                outputJSON: outputJSON,
                isError: isError,
                invocationID: invocationID,
                session: session
            )
            let matchingProviderItemCount = invocationID.map { providerInvocationID in
                session.indexedToolItemIndices(invocationID: providerInvocationID).count
            } ?? 0
            diagnosticLog(
                "suppressing explicit RepoPrompt provider tool_result tab=\(session.tabID.uuidString) " +
                    "tool=\(toolName) providerInvocation=\(Self.diagnosticID(invocationID)) " +
                    "matchingItems=\(matchingProviderItemCount) exactProviderSlotTerminalized=\(terminalizedExactProviderSlot) " +
                    "pendingProviderIDs=\(pendingProviderInvocationCount()) " +
                    "trackerMappings=\(providerInvocationByTrackerInvocationID.count)"
            )
            return true
        }
        if !AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
           AgentToolTrackingSupport.isRepoPromptTool(toolName),
           outputJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           argsJSON == nil,
           let invocationID,
           session.indexedToolItemIndices(invocationID: invocationID).isEmpty
        {
            return true
        }
        return false
    }

    private func terminalizeExplicitProviderToolResultIfExactProviderSlot(
        toolName: String,
        argsJSON: String?,
        outputJSON: String,
        isError: Bool?,
        invocationID: UUID?,
        session: AgentTabSession
    ) -> Bool {
        guard let providerInvocationID = invocationID else { return false }
        let normalizedToolName = MCPIntegrationHelper.normalizedRepoPromptToolName(toolName)
        let indexedCandidates = session.indexedToolItemIndices(invocationID: providerInvocationID)
        let indexedMatch = indexedCandidates.last(where: { index in
            let item = session.items[index]
            return item.kind == .toolCall
                && MCPIntegrationHelper.normalizedRepoPromptToolName(item.toolName ?? "") == normalizedToolName
        })
        let fallbackMatch = indexedMatch == nil
            ? session.activeTurnToolItemIndices(where: { item in
                item.kind == .toolCall
                    && item.toolInvocationID == providerInvocationID
                    && MCPIntegrationHelper.normalizedRepoPromptToolName(item.toolName ?? "") == normalizedToolName
            }).lastIndex
            : nil
        guard let index = indexedMatch ?? fallbackMatch else { return false }

        var updated = session.items[index]
        updated.kind = .toolResult
        updated.toolName = Self.canonicalTranscriptToolName(toolName)
        updated.toolResultJSON = outputJSON
        updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
        updated.toolIsError = isError
        updated.text = outputJSON
        session.replaceItem(at: index, with: updated)
        hooks.requestUIRefresh(session.tabID, false)
        return true
    }

    // MARK: - Tracker Callbacks (MCP observer)

    func handleTrackerToolCall(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        session: AgentTabSession,
        observationOwner: AgentRunOwnership? = nil
    ) {
        if let observationOwner,
           !session.isCurrentRunAttemptForCurrentBinding(observationOwner, expectedRunID: trackedRunID) { return }
        guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
        if handleExactHostObservation(
            invocationID: invocationID,
            toolName: toolName,
            args: args,
            result: nil,
            isError: false,
            observationOwner: observationOwner,
            session: session
        ) { return }
        // Flush buffered assistant content before inserting tool card to preserve interleaving order.
        hooks.flushPendingAssistantDelta(session)
        hooks.endActiveAssistantSegment(session)
        hooks.endActiveReasoningSegment(session)
        let storedToolName = Self.canonicalTranscriptToolName(toolName)
        let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
        let signature = Self.repoPromptInvocationSignature(toolName: toolName, argsJSON: argsJSON)
        if let providerInvocationID = consumePendingProviderInvocationID(
            forSignature: signature,
            session: session
        ) {
            diagnosticLog(
                "tracker call consumed pending provider fallback tab=\(session.tabID.uuidString) " +
                    "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                    "providerInvocation=\(providerInvocationID.uuidString) signature=\(Self.diagnosticSignature(signature))"
            )
            providerInvocationByTrackerInvocationID[invocationID] = TrackerCorrelation(providerID: providerInvocationID)
            let indexedCandidates = session.indexedToolItemIndices(invocationID: providerInvocationID)
            let fallback = indexedCandidates.isEmpty
                ? session.activeTurnToolItemIndices(where: { $0.toolInvocationID == providerInvocationID })
                : .init(indices: [], scannedItemCount: 0)
            if let index = indexedCandidates.last ?? fallback.lastIndex {
                var updated = session.items[index]
                updated.toolName = storedToolName
                updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
                session.replaceItem(at: index, with: updated)
            } else {
                let toolItem = AgentChatItem.toolCall(
                    name: storedToolName,
                    invocationID: providerInvocationID,
                    argsJSON: argsJSON,
                    sequenceIndex: session.nextSequenceIndex
                )
                session.appendItem(toolItem)
            }
            hooks.requestUIRefresh(session.tabID, false)
            MCPToolObserverAttributionContext.record(
                correlationPath: fallback.lastIndex == nil ? "signature_pending_map" : "signature_pending_map_active_turn_scan",
                scannedItemCount: indexedCandidates.count + fallback.scannedItemCount
            )
            return
        }

        var inspectedItemCount = 0
        let indexedSignatureCandidates = session.indexedToolItemIndices(
            signature: signature,
            pendingCallsOnly: true
        )
        inspectedItemCount += indexedSignatureCandidates.count
        var signatureCandidates = indexedSignatureCandidates
        var signatureUsedFallback = false
        if signatureCandidates.isEmpty {
            let fallback = session.activeTurnToolItemIndices(where: { item in
                item.kind == .toolCall
                    && Self.repoPromptInvocationSignature(
                        toolName: item.toolName ?? "",
                        argsJSON: item.toolArgsJSON
                    ) == signature
            })
            inspectedItemCount += fallback.scannedItemCount
            signatureCandidates = fallback.indices
            signatureUsedFallback = !fallback.indices.isEmpty
        }

        let matchingProviderBackedSignatureIndices = signatureCandidates.filter {
            session.items[$0].toolInvocationID != nil
        }
        if matchingProviderBackedSignatureIndices.count > 1 {
            diagnosticLog(
                "ambiguous tracker call signature fallback tab=\(session.tabID.uuidString) " +
                    "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                    "matches=\(matchingProviderBackedSignatureIndices.count) signature=\(Self.diagnosticSignature(signature))"
            )
        }
        if let existingInvocationIndex = matchingProviderBackedSignatureIndices.last,
           let providerInvocationID = session.items[existingInvocationIndex].toolInvocationID
        {
            diagnosticLog(
                "tracker call using signature fallback tab=\(session.tabID.uuidString) " +
                    "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                    "providerInvocation=\(providerInvocationID.uuidString) matches=\(matchingProviderBackedSignatureIndices.count)"
            )
            session.noteUncertainToolCorrelation()
            providerInvocationByTrackerInvocationID[invocationID] = TrackerCorrelation(providerID: providerInvocationID)
            var updated = session.items[existingInvocationIndex]
            updated.toolName = storedToolName
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            session.replaceItem(at: existingInvocationIndex, with: updated)
            hooks.requestUIRefresh(session.tabID, false)
            MCPToolObserverAttributionContext.record(
                correlationPath: signatureUsedFallback ? "signature_active_turn_scan" : "signature",
                scannedItemCount: inspectedItemCount
            )
            return
        }

        let matchingNilIDSignatureIndices = signatureCandidates.filter {
            session.items[$0].toolInvocationID == nil
        }
        if matchingNilIDSignatureIndices.count > 1 {
            diagnosticLog(
                "ambiguous tracker call nil-id signature fallback tab=\(session.tabID.uuidString) " +
                    "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                    "matches=\(matchingNilIDSignatureIndices.count) signature=\(Self.diagnosticSignature(signature))"
            )
        }
        if let fallbackIndex = matchingNilIDSignatureIndices.last {
            diagnosticLog(
                "tracker call using nil-id signature fallback tab=\(session.tabID.uuidString) " +
                    "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                    "matches=\(matchingNilIDSignatureIndices.count)"
            )
            session.noteUncertainToolCorrelation()
            var updated = session.items[fallbackIndex]
            updated.toolName = storedToolName
            updated.toolInvocationID = invocationID
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            session.replaceItem(at: fallbackIndex, with: updated)
            hooks.requestUIRefresh(session.tabID, false)
            MCPToolObserverAttributionContext.record(
                correlationPath: signatureUsedFallback ? "signature_nil_id_active_turn_scan" : "signature_nil_id",
                scannedItemCount: inspectedItemCount
            )
            return
        }

        let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(toolName)
        let indexedNameCandidates = session.indexedNilInvocationToolItemIndices(
            normalizedToolName: normalizedToolName
        )
        inspectedItemCount += indexedNameCandidates.count
        var matchingNilIDNameIndices = indexedNameCandidates.filter { index in
            let item = session.items[index]
            return item.kind == .toolCall
                && AgentTabSession.normalizedToolCorrelationName(item.toolName) == normalizedToolName
        }
        var nameUsedFallback = false
        if matchingNilIDNameIndices.isEmpty {
            let fallback = session.activeTurnToolItemIndices(where: { item in
                item.kind == .toolCall
                    && item.toolInvocationID == nil
                    && AgentTabSession.normalizedToolCorrelationName(item.toolName) == normalizedToolName
            })
            inspectedItemCount += fallback.scannedItemCount
            matchingNilIDNameIndices = fallback.indices
            nameUsedFallback = !fallback.indices.isEmpty
        }
        if matchingNilIDNameIndices.count > 1 {
            diagnosticLog(
                "ambiguous tracker call nil-id name fallback tab=\(session.tabID.uuidString) " +
                    "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                    "matches=\(matchingNilIDNameIndices.count)"
            )
        }
        if let fallbackByNameIndex = matchingNilIDNameIndices.last {
            diagnosticLog(
                "tracker call using nil-id name fallback tab=\(session.tabID.uuidString) " +
                    "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                    "matches=\(matchingNilIDNameIndices.count)"
            )
            session.noteUncertainToolCorrelation()
            var updated = session.items[fallbackByNameIndex]
            updated.toolName = storedToolName
            if updated.toolInvocationID == nil {
                updated.toolInvocationID = invocationID
            }
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            session.replaceItem(at: fallbackByNameIndex, with: updated)
            hooks.requestUIRefresh(session.tabID, false)
            MCPToolObserverAttributionContext.record(
                correlationPath: nameUsedFallback ? "name_active_turn_scan" : "name_fallback",
                scannedItemCount: inspectedItemCount
            )
            return
        }

        let toolItem = AgentChatItem.toolCall(
            name: storedToolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(toolItem)
        hooks.requestUIRefresh(session.tabID, false)
        MCPToolObserverAttributionContext.record(
            correlationPath: "new_item",
            scannedItemCount: inspectedItemCount
        )
    }

    func handleTrackerToolResult(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        resultJSON: String,
        isError: Bool,
        session: AgentTabSession,
        observationOwner: AgentRunOwnership? = nil
    ) {
        if let observationOwner,
           !session.isCurrentRunAttemptForCurrentBinding(observationOwner, expectedRunID: trackedRunID) { return }
        guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
        if handleExactHostObservation(
            invocationID: invocationID,
            toolName: toolName,
            args: args,
            result: resultJSON,
            isError: isError,
            observationOwner: observationOwner,
            session: session
        ) { return }
        // Flush buffered assistant content before inserting tool result to preserve interleaving order.
        hooks.flushPendingAssistantDelta(session)
        hooks.endActiveAssistantSegment(session)
        hooks.endActiveReasoningSegment(session)
        let storedToolName = Self.canonicalTranscriptToolName(toolName)
        let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
        let signature = Self.repoPromptInvocationSignature(toolName: toolName, argsJSON: argsJSON)
        let resolvedInvocationID = providerInvocationByTrackerInvocationID[invocationID]?.providerID ?? invocationID
        providerInvocationByTrackerInvocationID.removeValue(forKey: invocationID)

        var correlationPath = "none"
        var inspectedItemCount = 0
        let targetIndex: Int? = {
            let invocationCandidates = session.indexedToolItemIndices(invocationID: resolvedInvocationID)
            inspectedItemCount += invocationCandidates.count
            if let byInvocation = invocationCandidates.last {
                correlationPath = "invocation_id"
                return byInvocation
            }
            let invocationFallback = session.activeTurnToolItemIndices(where: {
                $0.toolInvocationID == resolvedInvocationID
            })
            inspectedItemCount += invocationFallback.scannedItemCount
            if let byInvocation = invocationFallback.lastIndex {
                correlationPath = "invocation_id_active_turn_scan"
                return byInvocation
            }
            if let providerInvocationID = consumePendingProviderInvocationID(
                forSignature: signature,
                session: session
            ) {
                let providerCandidates = session.indexedToolItemIndices(invocationID: providerInvocationID)
                inspectedItemCount += providerCandidates.count
                let providerFallback = providerCandidates.isEmpty
                    ? session.activeTurnToolItemIndices(where: { $0.toolInvocationID == providerInvocationID })
                    : .init(indices: [], scannedItemCount: 0)
                inspectedItemCount += providerFallback.scannedItemCount
                if let byProviderInvocation = providerCandidates.last ?? providerFallback.lastIndex {
                    diagnosticLog(
                        "tracker result consumed pending provider fallback tab=\(session.tabID.uuidString) " +
                            "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                            "providerInvocation=\(providerInvocationID.uuidString) signature=\(Self.diagnosticSignature(signature))"
                    )
                    providerInvocationByTrackerInvocationID[invocationID] = TrackerCorrelation(providerID: providerInvocationID)
                    correlationPath = providerFallback.lastIndex == nil
                        ? "signature_pending_map"
                        : "signature_pending_map_active_turn_scan"
                    return byProviderInvocation
                }
            }
            let indexedSignatureCandidates = session.indexedToolItemIndices(
                signature: signature,
                pendingCallsOnly: true
            )
            inspectedItemCount += indexedSignatureCandidates.count
            var matchingPendingSignatureIndices = indexedSignatureCandidates
            var signatureUsedFallback = false
            if matchingPendingSignatureIndices.isEmpty {
                let fallback = session.activeTurnToolItemIndices(where: { item in
                    item.kind == .toolCall
                        && Self.repoPromptInvocationSignature(
                            toolName: item.toolName ?? "",
                            argsJSON: item.toolArgsJSON
                        ) == signature
                })
                inspectedItemCount += fallback.scannedItemCount
                matchingPendingSignatureIndices = fallback.indices
                signatureUsedFallback = !fallback.indices.isEmpty
            }
            if matchingPendingSignatureIndices.count > 1 {
                diagnosticLog(
                    "ambiguous tracker result signature fallback tab=\(session.tabID.uuidString) " +
                        "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                        "resolvedInvocation=\(resolvedInvocationID.uuidString) matches=\(matchingPendingSignatureIndices.count) " +
                        "signature=\(Self.diagnosticSignature(signature))"
                )
            }
            if let byPendingCallSignature = matchingPendingSignatureIndices.last {
                diagnosticLog(
                    "tracker result using signature fallback tab=\(session.tabID.uuidString) " +
                        "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                        "resolvedInvocation=\(resolvedInvocationID.uuidString) matches=\(matchingPendingSignatureIndices.count)"
                )
                correlationPath = signatureUsedFallback ? "signature_active_turn_scan" : "signature"
                session.noteUncertainToolCorrelation()
                return byPendingCallSignature
            }
            let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(toolName)
            let indexedNameCandidates = session.indexedNilInvocationToolItemIndices(
                normalizedToolName: normalizedToolName
            )
            inspectedItemCount += indexedNameCandidates.count
            var matchingPendingNameIndices = indexedNameCandidates.filter {
                session.items[$0].kind == .toolCall
            }
            var nameUsedFallback = false
            if matchingPendingNameIndices.isEmpty {
                let fallback = session.activeTurnToolItemIndices(where: { item in
                    item.kind == .toolCall
                        && item.toolInvocationID == nil
                        && AgentTabSession.normalizedToolCorrelationName(item.toolName) == normalizedToolName
                })
                inspectedItemCount += fallback.scannedItemCount
                matchingPendingNameIndices = fallback.indices
                nameUsedFallback = !fallback.indices.isEmpty
            }
            if matchingPendingNameIndices.count > 1 {
                diagnosticLog(
                    "ambiguous tracker result nil-id name fallback tab=\(session.tabID.uuidString) " +
                        "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                        "matches=\(matchingPendingNameIndices.count)"
                )
            }
            if let byPendingCallName = matchingPendingNameIndices.last {
                diagnosticLog(
                    "tracker result using nil-id name fallback tab=\(session.tabID.uuidString) " +
                        "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                        "matches=\(matchingPendingNameIndices.count)"
                )
                correlationPath = nameUsedFallback ? "name_active_turn_scan" : "name_fallback"
                session.noteUncertainToolCorrelation()
                return byPendingCallName
            }
            return nil
        }()
        MCPToolObserverAttributionContext.record(
            correlationPath: correlationPath,
            scannedItemCount: inspectedItemCount
        )

        let trimmedResult = resultJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if isError, trimmedResult.isEmpty {
            if let index = targetIndex, session.items[index].kind == .toolCall {
                session.removeItem(at: index)
                hooks.requestUIRefresh(session.tabID, false)
            }
            return
        }

        if let index = targetIndex {
            var updated = session.items[index]
            updated.toolName = storedToolName
            updated.kind = .toolResult
            updated.toolResultJSON = resultJSON
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            updated.toolIsError = isError
            updated.text = resultJSON
            if updated.toolInvocationID == nil {
                updated.toolInvocationID = resolvedInvocationID
            }
            session.replaceItem(at: index, with: updated)
        } else {
            let toolResultItem = AgentChatItem.toolResult(
                name: storedToolName,
                invocationID: resolvedInvocationID,
                resultJSON: resultJSON,
                isError: isError,
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(toolResultItem)
        }
        hooks.requestUIRefresh(session.tabID, false)
    }

    /// Exact candidate association is run/attempt scoped. The external client's metadata contract
    /// is assumed only by deterministic W0 fixtures, not certified as live runtime behavior.
    private func exactOwner(in session: AgentTabSession) -> AgentRunOwnership? {
        guard session.selectedAgent == .claudeCode, let owner = exactObservationOwner,
              trackedRunID == session.runID, session.activeRunOwnership == owner,
              session.isCurrentRunAttemptForCurrentBinding(owner), session.quietLedger.isOpen(owner: owner),
              session.quietLedger.routineWakeID(owner: owner) != nil
        else { return nil }
        return owner
    }

    private func nativePendingKey(_ raw: String, owner: AgentRunOwnership) -> CorrelationSlot {
        .native(attemptID: owner.attemptID, toolUseID: raw)
    }

    private func handleExactNativeObservation(
        providerID: UUID?,
        nativeID: String?,
        toolName: String,
        argsJSON: String?,
        isResult: Bool,
        session: AgentTabSession
    ) -> Bool {
        guard let owner = exactOwner(in: session), let providerID,
              let raw = ToolInvocationContext.candidateClaudeToolUseID(nativeID.map(Value.string)),
              AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
              !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName)
        else { return false }
        let matches = providerInvocationByTrackerInvocationID.filter { $0.value.nativeID == raw && $0.value.owner == owner }
        guard matches.count <= 1 else { session.noteUncertainToolCorrelation()
            return false
        }
        if let (hostID, existing) = matches.first {
            guard !existing.ambiguous, existing.providerID == hostID || existing.providerID == providerID else {
                session.noteUncertainToolCorrelation()
                return false
            }
            var pair = existing
            pair.providerID = providerID
            pair.nativeCallSeen = pair.nativeCallSeen || !isResult
            pair.nativeResultSeen = pair.nativeResultSeen || isResult
            if isResult, !pair.nativeCallSeen { pair.ambiguous = true
                session.noteUncertainToolCorrelation()
            }
            providerInvocationByTrackerInvocationID[hostID] = pair
            // The host UUID is canonical; provider local UUID is only representation identity.
            if let index = session.indexedToolItemIndices(invocationID: hostID).last {
                if !isResult, let argsJSON { session.mutateItem(at: index) { $0.toolArgsJSON = argsJSON } }
            } else { session.noteUncertainToolCorrelation() }
            return true
        }
        let key = nativePendingKey(raw, owner: owner)
        var pending = pendingProviderRepoPromptInvocationsBySignature[key, default: []]
        // A result cannot manufacture proof that its native declaration was observed.
        if isResult, !pending.contains(providerID) {
            session.noteUncertainToolCorrelation()
            return false
        }
        if !pending.contains(providerID) { pending.append(providerID) }
        pendingProviderRepoPromptInvocationsBySignature[key] = pending
        guard pending.count == 1 else { session.noteUncertainToolCorrelation()
            return false
        }
        if isResult {
            // This can precede FIFO host delivery; the existing native ACK set retains it.
            return true
        }
        if session.indexedToolItemIndices(invocationID: providerID).isEmpty {
            let storedName = Self.canonicalTranscriptToolName(toolName)
            session.appendItem(.toolCall(name: storedName, invocationID: providerID, argsJSON: argsJSON, sequenceIndex: session.nextSequenceIndex))
            let signature = Self.repoPromptInvocationSignature(toolName: toolName, argsJSON: argsJSON)
            pendingProviderRepoPromptInvocationsBySignature[.signature(signature), default: []].append(providerID)
        }
        return true
    }

    private func handleExactHostObservation(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        result: String?,
        isError: Bool,
        observationOwner: AgentRunOwnership?,
        session: AgentTabSession
    ) -> Bool {
        guard let owner = exactOwner(in: session), observationOwner == owner else { return false }
        guard let context = MCPInvocationContextBridge.current, context.invocationID == invocationID,
              context.metadata.invocationID == invocationID, let raw = context.claudeToolUseID
        else { session.noteUncertainToolCorrelation()
            return false
        }
        let matches = providerInvocationByTrackerInvocationID.filter { $0.value.nativeID == raw && $0.value.owner == owner }
        guard matches.isEmpty || (matches.count == 1 && matches.first?.key == invocationID) else {
            for (id, var pair) in matches {
                pair.ambiguous = true
                providerInvocationByTrackerInvocationID[id] = pair
            }
            session.noteUncertainToolCorrelation()
            return false
        }
        let key = nativePendingKey(raw, owner: owner)
        let pending = pendingProviderRepoPromptInvocationsBySignature[key] ?? []
        guard pending.count <= 1 else { session.noteUncertainToolCorrelation()
            return false
        }
        if result != nil && providerInvocationByTrackerInvocationID[invocationID] == nil {
            session.noteUncertainToolCorrelation()
            return false
        }
        var pair = providerInvocationByTrackerInvocationID[invocationID]
            ?? TrackerCorrelation(
                providerID: pending.first ?? invocationID,
                nativeID: raw,
                owner: owner,
                nativeCallSeen: !pending.isEmpty,
                nativeResultSeen: pending.first.map { explicitProviderToolResultAckedInvocationIDs.contains($0) } ?? false
            )
        guard !pair.ambiguous else { session.noteUncertainToolCorrelation()
            return false
        }
        pair.hostResultSeen = pair.hostResultSeen || result != nil
        providerInvocationByTrackerInvocationID[invocationID] = pair
        hooks.flushPendingAssistantDelta(session)
        hooks.endActiveAssistantSegment(session)
        hooks.endActiveReasoningSegment(session)
        let candidates = session.indexedToolItemIndices(invocationID: invocationID)
        let providerCandidates = session.indexedToolItemIndices(invocationID: pair.providerID)
        let index = candidates.last ?? providerCandidates.last
        let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
        if let index {
            var item = session.items[index]
            item.toolInvocationID = invocationID
            item.toolName = Self.canonicalTranscriptToolName(toolName)
            item.toolArgsJSON = argsJSON ?? item.toolArgsJSON
            if let result { item.kind = .toolResult
                item.toolResultJSON = result
                item.text = result
                item.toolIsError = isError
            }
            session.replaceItem(at: index, with: item)
        } else if let result {
            session.appendItem(.toolResult(name: toolName, invocationID: invocationID, resultJSON: result, isError: isError, sequenceIndex: session.nextSequenceIndex))
        } else {
            session.appendItem(.toolCall(name: Self.canonicalTranscriptToolName(toolName), invocationID: invocationID, argsJSON: argsJSON, sequenceIndex: session.nextSequenceIndex))
        }
        // Retire only the exact provider ID from legacy pending queues. No signature chooses a join.
        for key in Array(pendingProviderRepoPromptInvocationsBySignature.keys) {
            pendingProviderRepoPromptInvocationsBySignature[key]?.removeAll { $0 == pair.providerID }
            if pendingProviderRepoPromptInvocationsBySignature[key]?.isEmpty == true { pendingProviderRepoPromptInvocationsBySignature[key] = nil }
        }
        if isError { session.noteUncertainToolCorrelation() }
        hooks.requestUIRefresh(session.tabID, false)
        return true
    }

    #if DEBUG
        var pendingEventDeliveryWaiterCountForTesting: Int {
            trackingController.pendingEventDeliveryWaiterCountForTesting
        }

        func enqueueEventDeliveryBarrierForTesting(_ operation: @escaping @Sendable () async -> Void) {
            trackingController.enqueueEventDeliveryBarrierForTesting(operation)
        }
    #endif

    func waitForPendingEventDeliveries() async {
        await trackingController.waitForPendingEventDeliveries()
    }

    func hasExactNativeResult(hostInvocationID: UUID, owner: AgentRunOwnership, session: AgentTabSession) -> Bool {
        guard exactOwner(in: session) == owner, let pair = providerInvocationByTrackerInvocationID[hostInvocationID] else { return false }
        return pair.owner == owner && pair.nativeID != nil && pair.nativeCallSeen && pair.nativeResultSeen && !pair.ambiguous
    }

    func hasCompleteExactAssociation(hostInvocationID: UUID, owner: AgentRunOwnership, session: AgentTabSession) -> Bool {
        guard exactOwner(in: session) == owner, let pair = providerInvocationByTrackerInvocationID[hostInvocationID] else { return false }
        return pair.owner == owner && pair.nativeID != nil && pair.nativeCallSeen && pair.nativeResultSeen && pair.hostResultSeen && !pair.ambiguous
    }

    // MARK: - Correlation Helpers

    private func resetCorrelationState(_ session: AgentTabSession) {
        let pendingProviderCount = pendingProviderInvocationCount()
        let trackerMappingCount = providerInvocationByTrackerInvocationID.count
        if pendingProviderCount > 0 || trackerMappingCount > 0 {
            diagnosticLog(
                "reset clearing Claude tool correlation state tab=\(session.tabID.uuidString) " +
                    "pendingProviderIDs=\(pendingProviderCount) trackerMappings=\(trackerMappingCount) " +
                    "nextSequenceIndex=\(session.nextSequenceIndex)"
            )
        }
        pendingProviderRepoPromptInvocationsBySignature.removeAll(keepingCapacity: false)
        providerInvocationByTrackerInvocationID.removeAll(keepingCapacity: false)
        toolCorrelationStartSequenceIndex = session.nextSequenceIndex
        exactObservationOwner = nil
    }

    private func pendingProviderInvocationCount() -> Int {
        pendingProviderRepoPromptInvocationsBySignature.values.reduce(0) { $0 + $1.count }
    }

    private func beginTrackingExplicitProviderToolResultAcks(for runID: UUID) {
        resumeAckWaiters(matching: { $0.runID != runID })
        trackedRunID = runID
        explicitProviderToolResultAckedInvocationIDs.removeAll(keepingCapacity: false)
        explicitProviderToolResultAckCount = 0
        explicitProviderToolResultAckObservations.removeAll(keepingCapacity: false)
        resumeEligibleAckWaiters()
    }

    private func stopTrackingExplicitProviderToolResultAcks() {
        trackedRunID = nil
        explicitProviderToolResultAckedInvocationIDs.removeAll(keepingCapacity: false)
        explicitProviderToolResultAckCount = 0
        explicitProviderToolResultAckObservations.removeAll(keepingCapacity: false)
        resumeAckWaiters(matching: { _ in true })
    }

    private func recordExplicitProviderToolResultAckIfNeeded(
        toolName: String,
        invocationID: UUID?
    ) {
        guard AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName) else { return }
        guard let invocationID else {
            appendExplicitProviderAckObservation(
                toolName: toolName,
                invocationID: nil,
                counted: false,
                reason: "missing_invocation_id"
            )
            return
        }
        guard trackedRunID != nil else {
            appendExplicitProviderAckObservation(
                toolName: toolName,
                invocationID: invocationID,
                counted: false,
                reason: "no_tracked_run"
            )
            return
        }
        let inserted = explicitProviderToolResultAckedInvocationIDs.insert(invocationID).inserted
        guard inserted else {
            appendExplicitProviderAckObservation(
                toolName: toolName,
                invocationID: invocationID,
                counted: false,
                reason: "duplicate_invocation"
            )
            return
        }

        explicitProviderToolResultAckCount += 1
        appendExplicitProviderAckObservation(
            toolName: toolName,
            invocationID: invocationID,
            counted: true,
            reason: "acked"
        )
        resumeEligibleAckWaiters()
    }

    private func appendExplicitProviderAckObservation(
        toolName: String,
        invocationID: UUID?,
        counted: Bool,
        reason: String
    ) {
        explicitProviderToolResultAckObservations.append(
            ExplicitProviderToolResultAckObservation(
                timestamp: Date(),
                runID: trackedRunID,
                toolName: toolName,
                invocationID: invocationID,
                counted: counted,
                reason: reason,
                ackCountAfterEvent: explicitProviderToolResultAckCount
            )
        )
        if explicitProviderToolResultAckObservations.count > maxExplicitProviderAckObservationCount {
            explicitProviderToolResultAckObservations.removeFirst(
                explicitProviderToolResultAckObservations.count - maxExplicitProviderAckObservationCount
            )
        }
    }

    private func resumeEligibleAckWaiters() {
        guard let trackedRunID else { return }
        resumeAckWaiters(matching: {
            $0.runID == trackedRunID && explicitProviderToolResultAckCount >= $0.minimumAckCount
        })
    }

    private func resumeAckWaiters(matching predicate: (AckWaiter) -> Bool) {
        let matchingIDs = ackWaitersByID.compactMap { waiterID, waiter in
            predicate(waiter) ? waiterID : nil
        }
        for waiterID in matchingIDs {
            guard let waiter = ackWaitersByID.removeValue(forKey: waiterID) else { continue }
            waiter.continuation.resume()
        }
    }

    private func findCorrelationItemIndex(
        invocationID: UUID?,
        signature: String,
        toolName: String,
        session: AgentTabSession
    ) -> Int? {
        let turnStartSequenceIndex = toolCorrelationStartSequenceIndex
        let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(toolName)
        func isEligible(_ item: AgentChatItem) -> Bool {
            item.sequenceIndex >= turnStartSequenceIndex
                && (item.kind == .toolCall || item.kind == .toolResult)
        }

        if let invocationID {
            let indexed = session.indexedToolItemIndices(invocationID: invocationID)
            if let match = indexed.last(where: { isEligible(session.items[$0]) }) {
                return match
            }
            let fallback = session.activeTurnToolItemIndices(where: {
                isEligible($0) && $0.toolInvocationID == invocationID
            })
            if let match = fallback.lastIndex {
                return match
            }
        }

        let signatureCandidates = session.indexedToolItemIndices(signature: signature)
        if let bySignature = signatureCandidates.last(where: { isEligible(session.items[$0]) }) {
            session.noteUncertainToolCorrelation()
            return bySignature
        }
        let signatureFallback = session.activeTurnToolItemIndices(where: {
            isEligible($0)
                && Self.repoPromptInvocationSignature(
                    toolName: $0.toolName ?? "",
                    argsJSON: $0.toolArgsJSON
                ) == signature
        })
        if let bySignature = signatureFallback.lastIndex {
            session.noteUncertainToolCorrelation()
            return bySignature
        }

        let nameCandidates = session.indexedNilInvocationToolItemIndices(
            normalizedToolName: normalizedToolName
        )
        if let byName = nameCandidates.last(where: { index in
            let item = session.items[index]
            guard isEligible(item) else { return false }
            if item.kind == .toolCall {
                return true
            }
            return item.toolArgsJSON?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }) {
            session.noteUncertainToolCorrelation()
            return byName
        }
        let nameMatch = session.activeTurnToolItemIndices(where: { item in
            guard isEligible(item) else { return false }
            guard AgentTabSession.normalizedToolCorrelationName(item.toolName) == normalizedToolName else {
                return false
            }
            if item.kind == .toolCall {
                return item.toolInvocationID == nil
            }
            return item.toolArgsJSON?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }).lastIndex
        if nameMatch != nil { session.noteUncertainToolCorrelation() }
        return nameMatch
    }

    private func consumePendingProviderInvocationID(
        forSignature signature: String,
        session: AgentTabSession
    ) -> UUID? {
        guard var queue = pendingProviderRepoPromptInvocationsBySignature[.signature(signature)], !queue.isEmpty else {
            return nil
        }
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            let indexedCandidates = session.indexedToolItemIndices(invocationID: candidate)
            let exists = !indexedCandidates.isEmpty
                || session.activeTurnToolItemIndices(where: { $0.toolInvocationID == candidate }).lastIndex != nil
            if exists {
                session.noteUncertainToolCorrelation()
                pendingProviderRepoPromptInvocationsBySignature[.signature(signature)] = queue.isEmpty ? nil : queue
                return candidate
            }
        }
        pendingProviderRepoPromptInvocationsBySignature[.signature(signature)] = nil
        return nil
    }

    // MARK: - Static Helpers

    private static func canonicalTranscriptToolName(_ toolName: String) -> String {
        MCPIntegrationHelper.canonicalRepoPromptAskUserToolName(toolName) ?? toolName
    }

    private static func repoPromptInvocationSignature(toolName: String, argsJSON: String?) -> String {
        AgentTabSession.canonicalToolInvocationSignature(
            toolName: toolName,
            argsJSON: argsJSON
        )
    }
}
