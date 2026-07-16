// MARK: - DEBUG Agent Diagnostics

import Darwin
import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        func debugAgentPerfMetricsPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            #if DEBUG
                if let enable = debugBool(arguments, "enable") {
                    AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(enable)
                }
                if debugBool(arguments, "clear") == true {
                    AgentModePerfDiagnostics.clearRecentMetrics()
                }
                if debugBool(arguments, "emit_probe") == true {
                    AgentModePerfDiagnostics.event("agent.metrics.probe", fields: ["source": "debugDiagnostics"])
                }
                let mark = debugString(arguments, "mark")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let mark, !mark.isEmpty {
                    AgentModePerfDiagnostics.event("agent.metrics.mark", fields: ["mark": mark])
                }
                let wantsSummary = debugBool(arguments, "summary") == true
                let startMark = debugString(arguments, "start_mark")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let endMark = debugString(arguments, "end_mark")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let eventNames: Set<String>?
                if wantsSummary {
                    guard let parsedEventNames = debugStringArray(arguments, "event_names", op: op) else {
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`event_names` must be a string or array of strings.")
                    }
                    eventNames = parsedEventNames.map { Set($0) }
                } else {
                    eventNames = nil
                }

                // Optional diagnostic-only session snapshot collection. Lets scripted
                // multi-window validation populate `latest_session_snapshots` without
                // forcing focus cycling through every Agent tab. No UI sync runs.
                var snapshotSummary: [String: Any]? = nil
                if debugBool(arguments, "snapshot_sessions") == true {
                    guard let parsedTabIDs = debugUUIDSet(arguments, "tab_ids", op: op) else {
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`tab_ids` must be an array of UUID strings.")
                    }
                    let filter: Set<UUID>? = parsedTabIDs.isEmpty ? nil : parsedTabIDs
                    snapshotSummary = await captureAgentPerfSessionSnapshots(filter: filter)
                }

                let limit: Int
                switch debugBoundedInt(arguments, "limit", defaultValue: 100, range: 1 ... 2000) {
                case let .value(parsed), let .defaulted(parsed):
                    limit = parsed
                case .invalid:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "`limit` must be an integer between 1 and 2000.")
                }

                var payload = AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: limit)
                payload["ok"] = true
                payload["op"] = op
                if let mark, !mark.isEmpty {
                    payload["mark"] = mark
                }
                if let snapshotSummary {
                    payload["snapshot_sessions_result"] = snapshotSummary
                }
                if wantsSummary {
                    payload["summary"] = AgentModePerfDiagnostics.debugMetricSummarySnapshot(
                        lineLimit: limit,
                        startMark: startMark,
                        endMark: endMark,
                        eventNames: eventNames
                    )
                }
                return debugDiagnosticsResult(payload)
            #else
                return debugDiagnosticsError(op: op, code: "unavailable", message: "`agent_perf_metrics` is only available in DEBUG builds.")
            #endif
        }

        func debugAgentMemorySnapshotPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            #if DEBUG
                let includeSessions = debugBool(arguments, "include_sessions") ?? true
                let includeProcess = debugBool(arguments, "include_process") ?? true
                let payload = await Self.debugAgentMemorySnapshotPayloadObject(
                    op: op,
                    includeSessions: includeSessions,
                    includeProcess: includeProcess
                )
                return debugDiagnosticsResult(payload)
            #else
                return debugDiagnosticsError(op: op, code: "unavailable", message: "`agent_memory_snapshot` is only available in DEBUG builds.")
            #endif
        }

        func debugSeedAgentTextDerivationFixturePayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            #if DEBUG
                let windowID: Int
                switch debugBoundedInt(arguments, "window_id", defaultValue: 0, range: 0 ... Int.max) {
                case let .value(parsed), let .defaulted(parsed):
                    windowID = parsed
                case .invalid:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "`window_id` must be a non-negative integer.")
                }
                let reset = debugBool(arguments, "reset") ?? true
                let activateAgentMode = debugBool(arguments, "activate_agent_mode") ?? true
                let tabID: UUID?
                if let rawTabID = debugString(arguments, "tab_id")?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTabID.isEmpty {
                    guard let parsedTabID = UUID(uuidString: rawTabID) else {
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`tab_id` must be a valid UUID when provided.")
                    }
                    tabID = parsedTabID
                } else {
                    tabID = nil
                }

                switch await Self.debugSeedAgentTextDerivationFixture(
                    op: op,
                    windowID: windowID,
                    tabID: tabID,
                    reset: reset,
                    activateAgentMode: activateAgentMode
                ) {
                case let .payload(payload):
                    return debugDiagnosticsResult(payload)
                case let .error(code, message):
                    return debugDiagnosticsError(op: op, code: code, message: message)
                }
            #else
                return debugDiagnosticsError(op: op, code: "unavailable", message: "`seed_agent_text_derivation_fixture` is only available in DEBUG builds.")
            #endif
        }

        @MainActor
        private static func debugSeedAgentTextDerivationFixture(
            op: String,
            windowID: Int,
            tabID: UUID?,
            reset: Bool,
            activateAgentMode: Bool
        ) async -> DebugDiagnosticsPayloadResult {
            let manager = WindowStatesManager.shared
            let selectedWindow: WindowState? = if windowID > 0 {
                manager.allWindows.first { $0.windowID == windowID }
            } else {
                manager.allWindows.first { $0.isCurrentlyFocused } ?? manager.latestWindowState
            }
            guard let window = selectedWindow else {
                return .error(code: "no_window", message: "No matching RepoPrompt window is available for text derivation fixture seeding.")
            }

            guard let tab = await window.promptManager.ensureActiveComposeTab(
                tabID,
                creationStrategy: .blank,
                name: "Text Derivation Fixture"
            ) else {
                return .error(code: "no_tab", message: "Unable to resolve or create a compose tab for text derivation fixture seeding.")
            }

            let counts = await window.agentModeViewModel.testSeedTextDerivationFixture(tabID: tab.id, reset: reset)
            return .payload([
                "ok": true,
                "op": op,
                "window_id": window.windowID,
                "tab_id": tab.id.uuidString,
                "workspace": window.workspaceManager.activeWorkspace?.name ?? NSNull(),
                "reset": reset,
                "activate_agent_mode": activateAgentMode,
                "appended_counts": counts,
                "fixture": "debug_text_derivation_fixture_v1",
                "notes": "DEBUG-only synthetic Agent transcript with three long assistant messages plus plain/diff/json tool payloads. The first assistant is intentionally older than the two most recent assistant rows so collapse derivation can run when rendered."
            ])
        }

        @MainActor
        private static func debugAgentMemorySnapshotPayloadObject(
            op: String,
            includeSessions: Bool,
            includeProcess: Bool
        ) async -> [String: Any] {
            var windowPayloads: [[String: Any]] = []
            var totals = AgentDebugMemoryTotals()

            if includeSessions {
                struct CapturedSession {
                    var payload: [String: Any]
                    let codexController: (any CodexSessionControlling)?
                    let claudeController: (any NativeAgentRuntimeControlling)?
                    let acpController: ACPAgentSessionController?
                }

                for window in WindowStatesManager.shared.allWindows {
                    let agentModeVM = window.agentModeViewModel
                    let capturedWindowID = window.windowID
                    let capturedWorkspace = window.workspaceManager.activeWorkspace.map { $0.name as Any } ?? NSNull()
                    let capturedLiveSessionCount = agentModeVM.sessions.count
                    let sortedSessions = agentModeVM.sessions.values.sorted(by: { lhs, rhs in
                        let lhsName = window.workspaceManager.composeTab(with: lhs.tabID)?.name ?? lhs.tabID.uuidString
                        let rhsName = window.workspaceManager.composeTab(with: rhs.tabID)?.name ?? rhs.tabID.uuidString
                        return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
                    })
                    var capturedSessions: [CapturedSession] = []
                    capturedSessions.reserveCapacity(sortedSessions.count)

                    // Capture every MainActor-owned field without suspension. Controller queries
                    // happen in a second phase so actor reentrancy cannot produce a session payload
                    // assembled from multiple lifecycle moments.
                    for session in sortedSessions {
                        totals.add(session: session)
                        capturedSessions.append(CapturedSession(
                            payload: debugAgentMemorySessionPayload(session, window: window),
                            codexController: session.codexController,
                            claudeController: session.claudeController,
                            acpController: session.acpController
                        ))
                    }

                    var sessionPayloads: [[String: Any]] = []
                    sessionPayloads.reserveCapacity(capturedSessions.count)
                    for var captured in capturedSessions {
                        let codexProcessSnapshot = await captured.codexController?.appServerProcessSnapshot()
                        let claudeProcessSnapshot = await captured.claudeController?.debugProcessSnapshot()
                        let acpProcessSnapshot = await captured.acpController?.debugProcessSnapshot()
                        debugAgentMemoryAttachRuntimeProcesses(
                            to: &captured.payload,
                            codex: codexProcessSnapshot,
                            claude: claudeProcessSnapshot,
                            acp: acpProcessSnapshot
                        )
                        totals.add(
                            codexProcessSnapshot: codexProcessSnapshot,
                            claudeProcessSnapshot: claudeProcessSnapshot,
                            acpProcessSnapshot: acpProcessSnapshot
                        )
                        sessionPayloads.append(captured.payload)
                    }

                    windowPayloads.append([
                        "window_id": capturedWindowID,
                        "workspace": capturedWorkspace,
                        "live_session_count": capturedLiveSessionCount,
                        "sessions": sessionPayloads
                    ])
                }
            }

            let codexModelPollingSnapshot = await CodexModelPollingService.shared.runtimeSnapshot()
            totals.add(codexModelPollingSnapshot: codexModelPollingSnapshot)

            var payload: [String: Any] = [
                "ok": true,
                "op": op,
                "debug_only": true,
                "snapshot_consistency": "session_atomic_process_best_effort",
                "notes": "Each session's fields and controller identities are captured without MainActor suspension. Process probes use those frozen identities and may observe later provider startup or shutdown.",
                "timestamp": AgentMCPToolHelpers.timestamp(Date()),
                "totals": totals.payload(),
                "codex_model_polling": debugAgentMemoryCodexModelPollingPayload(codexModelPollingSnapshot)
            ]
            if includeSessions {
                payload["windows"] = windowPayloads
            }
            if includeProcess {
                payload["process"] = debugAgentMemoryProcessPayload()
            }
            return payload
        }

        @MainActor
        private static func debugAgentMemorySessionPayload(
            _ session: AgentModeViewModel.TabSession,
            window: WindowState
        ) -> [String: Any] {
            let itemStringBytes = debugAgentMemoryItemStringBytes(session.items)
            let transcriptProjectionRows = session.transcriptProjection.workingRows.count + session.transcriptProjection.archivedRows.count
            let projectionCacheRowCount = session.turnProjectionCaches.values.reduce(0) { partial, cache in
                partial + cache.workingRows.count + cache.archivedRows.count
            }
            let projectionCacheBlockCount = session.turnProjectionCaches.values.reduce(0) { partial, cache in
                partial + cache.workingBlocks.count + cache.archivedBlocks.count
            }
            let ephemeralPayloadBytes = session.ephemeralToolResultPayloadByItemID.values.reduce(0) { partial, payload in
                partial + payload.utf8.count
            }
            let bashLiveOutputBytes = session.bashLiveExecutionByKey.values.reduce(0) { partial, state in
                partial + (state.output?.utf8.count ?? 0)
            }
            let pendingCommandOutputBytes = session.pendingCommandRunningByKey.values.reduce(0) { partial, update in
                partial + (update.appendedOutput?.utf8.count ?? 0)
            }
            let codexReasoningBytes = session.codexReasoningSegmentsByKey.values.reduce(0) { partial, segment in
                partial + segment.summaryMarkdown.utf8.count + segment.bodyMarkdown.utf8.count
            }
            let reasoningBytes = codexReasoningBytes
                + session.claudeReasoningStatusBuffer.utf8.count
                + (session.claudeReasoningStatusPendingText?.utf8.count ?? 0)
                + session.pendingAssistantDelta.utf8.count
            let pendingInstructionBytes = session.pendingInstructions.reduce(0) { partial, instruction in
                partial + instruction.utf8.count
            }
            let hasAnyProjection = [
                session.baseTranscriptProjection,
                session.fullTranscriptProjection,
                session.workingTranscriptProjection,
                session.transcriptProjection
            ].contains { projection in
                !projection.workingRows.isEmpty
                    || !projection.archivedRows.isEmpty
                    || !projection.workingBlocks.isEmpty
                    || !projection.archivedBlocks.isEmpty
                    || !projection.rowAnchorIndex.isEmpty
                    || !projection.anchorBlockIndex.isEmpty
            }

            let counts: [String: Any] = [
                "items": session.items.count,
                "transcript_turns": session.transcript.turns.count,
                "canonical_visible_rows": session.transcriptProjectionCounts.canonicalVisibleRowCount,
                "transcript_projection_rows": transcriptProjectionRows,
                "turn_projection_caches": session.turnProjectionCaches.count,
                "projection_cache_rows": projectionCacheRowCount,
                "projection_cache_blocks": projectionCacheBlockCount,
                "archived_snapshot_rows": session.archivedTranscriptSnapshot.rows.count,
                "archived_snapshot_blocks": session.archivedTranscriptSnapshot.blocks.count,
                "archived_snapshot_compressed_items": session.archivedTranscriptSnapshot.compressedItems.count,
                "ephemeral_payloads": session.ephemeralToolResultPayloadByItemID.count,
                "bash_live_executions": session.bashLiveExecutionByKey.count,
                "pending_command_running": session.pendingCommandRunningByKey.count,
                "reasoning_segments": session.codexReasoningSegmentsByKey.count,
                "runtime_footers": session.agentMessageRuntimeFootersByItemID.count,
                "pending_instructions": session.pendingInstructions.count,
                "pending_image_attachments": session.pendingImageAttachments.count,
                "pending_tagged_file_attachments": session.pendingTaggedFileAttachments.count,
                "queued_user_input_requests": session.queuedUserInputRequests.count,
                "queued_mcp_elicitation_requests": session.queuedMCPElicitationRequests.count,
                "pending_claude_steering": session.pendingClaudeSteeringInstructions.count,
                "pending_acp_steering": session.pendingACPSteeringInstructions.count,
                "codex_fallback_queue": session.codexFallbackQueue.count,
                "provider_token_usage_turns": session.providerTokenUsageByTurn.count
            ]
            let bytes: [String: Any] = [
                "item_strings": itemStringBytes,
                "ephemeral_payloads": ephemeralPayloadBytes,
                "bash_live_output": bashLiveOutputBytes,
                "pending_command_output": pendingCommandOutputBytes,
                "reasoning_buffers": reasoningBytes,
                "pending_instructions": pendingInstructionBytes
            ]
            let projections: [String: Any] = [
                "base": debugAgentMemoryProjectionPayload(session.baseTranscriptProjection),
                "full": debugAgentMemoryProjectionPayload(session.fullTranscriptProjection),
                "working": debugAgentMemoryProjectionPayload(session.workingTranscriptProjection),
                "visible": debugAgentMemoryProjectionPayload(session.transcriptProjection)
            ]
            var runtime: [String: Any] = [
                "provider_present": session.provider != nil,
                "agent_task_present": session.agentTask != nil,
                "codex_controller_present": session.codexController != nil,
                "claude_controller_present": session.claudeController != nil,
                "acp_controller_present": session.acpController != nil,
                "codex_event_task_present": session.codexEventTask != nil,
                "derived_transcript_refresh_task_present": session.derivedTranscriptRefreshTask != nil,
                "save_debounce_task_present": session.saveDebounceTask != nil,
                "ask_user_timeout_task_present": session.askUserTimeoutTask != nil,
                "instruction_timeout_task_present": session.instructionTimeoutTask != nil,
                "assistant_delta_flush_task_present": session.assistantDeltaFlushTask != nil,
                "pending_approval": session.pendingApproval != nil,
                "pending_question_ui": session.hasPendingQuestionUI
            ]
            var payload: [String: Any] = [
                "tab_id": session.tabID.uuidString,
                "session_id": session.activeAgentSessionID?.uuidString as Any? ?? NSNull(),
                "name": window.workspaceManager.composeTab(with: session.tabID)?.name ?? "Agent Session",
                "agent": session.selectedAgent.rawValue,
                "model": session.selectedModelRaw,
                "run_state": session.runState.rawValue,
                "is_mcp_originated": session.isMCPOriginated,
                "is_dirty": session.isDirty,
                "has_any_projection": hasAnyProjection
            ]
            payload["counts"] = counts
            payload["bytes"] = bytes
            payload["projections"] = projections
            payload["runtime"] = runtime
            return payload
        }

        private static func debugAgentMemoryAttachRuntimeProcesses(
            to payload: inout [String: Any],
            codex: CodexAppServerClient.ProcessSnapshot?,
            claude: AgentRuntimeProcessSnapshot?,
            acp: AgentRuntimeProcessSnapshot?
        ) {
            guard var runtime = payload["runtime"] as? [String: Any] else { return }
            runtime["codex_controller_process"] = debugAgentMemoryCodexProcessPayload(codex)
            runtime["claude_controller_process"] = debugAgentMemoryRuntimeProcessPayload(claude)
            runtime["acp_controller_process"] = debugAgentMemoryRuntimeProcessPayload(acp)
            payload["runtime"] = runtime
        }

        private static func debugAgentMemoryCodexProcessPayload(
            _ snapshot: CodexAppServerClient.ProcessSnapshot?
        ) -> Any {
            guard let snapshot else { return NSNull() }
            return debugAgentMemoryProcessPayload(pid: snapshot.pid, appearsAlive: snapshot.appearsAlive)
        }

        private static func debugAgentMemoryRuntimeProcessPayload(
            _ snapshot: AgentRuntimeProcessSnapshot?
        ) -> Any {
            guard let snapshot else { return NSNull() }
            return debugAgentMemoryProcessPayload(pid: snapshot.pid, appearsAlive: snapshot.appearsAlive)
        }

        private static func debugAgentMemoryProcessPayload(pid: pid_t, appearsAlive: Bool) -> [String: Any] {
            var payload: [String: Any] = [
                "pid": Int(pid),
                "appears_alive": appearsAlive
            ]
            if let metrics = debugAgentMemoryChildProcessMetrics(pid: pid) {
                payload["resident_bytes"] = NSNumber(value: metrics.residentBytes)
                payload["resident_mb"] = debugAgentMemoryMegabytes(metrics.residentBytes)
                payload["virtual_bytes"] = NSNumber(value: metrics.virtualBytes)
                payload["virtual_mb"] = debugAgentMemoryMegabytes(metrics.virtualBytes)
                payload["thread_count"] = metrics.threadCount
            }
            payload["path"] = debugAgentMemoryProcessPath(pid: pid) ?? NSNull()
            return payload
        }

        private static func debugAgentMemoryCodexModelPollingPayload(
            _ snapshot: CodexModelPollingService.RuntimeSnapshot
        ) -> [String: Any] {
            var payload: [String: Any] = [
                "subscriber_count": snapshot.subscriberCount,
                "is_polling": snapshot.isPolling,
                "has_in_flight_refresh": snapshot.hasInFlightRefresh,
                "is_shutdown": snapshot.isShutdown,
                "latest_fetched_at": snapshot.latestFetchedAt.map { AgentMCPToolHelpers.timestamp($0) } ?? NSNull()
            ]
            payload["process"] = debugAgentMemoryCodexProcessPayload(snapshot.processSnapshot)
            return payload
        }

        private struct DebugAgentMemoryChildProcessMetrics {
            let residentBytes: UInt64
            let virtualBytes: UInt64
            let threadCount: Int
        }

        private static func debugAgentMemoryChildProcessMetrics(pid: pid_t) -> DebugAgentMemoryChildProcessMetrics? {
            var info = proc_taskinfo()
            let expectedSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expectedSize)
            guard result == expectedSize else { return nil }
            return DebugAgentMemoryChildProcessMetrics(
                residentBytes: UInt64(info.pti_resident_size),
                virtualBytes: UInt64(info.pti_virtual_size),
                threadCount: Int(info.pti_threadnum)
            )
        }

        private static func debugAgentMemoryProcessPath(pid: pid_t) -> String? {
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = buffer.withUnsafeMutableBufferPointer { pointer in
                proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
            }
            guard length > 0 else { return nil }
            return String(cString: buffer)
        }

        private static func debugAgentMemoryProjectionPayload(_ projection: AgentTranscriptProjection) -> [String: Any] {
            [
                "working_rows": projection.workingRows.count,
                "archived_rows": projection.archivedRows.count,
                "working_blocks": projection.workingBlocks.count,
                "archived_blocks": projection.archivedBlocks.count,
                "row_anchor_index": projection.rowAnchorIndex.count,
                "anchor_block_index": projection.anchorBlockIndex.count,
                "working_unit_count": projection.workingUnitCount
            ]
        }

        private static func debugAgentMemoryItemStringBytes(_ items: [AgentChatItem]) -> Int {
            items.reduce(0) { partial, item in
                partial
                    + item.text.utf8.count
                    + (item.toolName?.utf8.count ?? 0)
                    + (item.toolArgsJSON?.utf8.count ?? 0)
                    + (item.toolResultJSON?.utf8.count ?? 0)
                    + (item.reasoning?.utf8.count ?? 0)
            }
        }

        private static func debugAgentMemoryProcessPayload() -> [String: Any] {
            let residentBytes = debugAgentMemoryResidentBytes()
            let physicalFootprintBytes = debugAgentMemoryPhysicalFootprintBytes()
            var payload: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "resident_bytes": residentBytes.map { NSNumber(value: $0) } ?? NSNull(),
                "resident_mb": residentBytes.map { debugAgentMemoryMegabytes($0) } ?? NSNull(),
                "physical_footprint_bytes": physicalFootprintBytes.map { NSNumber(value: $0) } ?? NSNull(),
                "physical_footprint_mb": physicalFootprintBytes.map { debugAgentMemoryMegabytes($0) } ?? NSNull()
            ]
            payload["note"] = "This block covers the RepoPrompt app process. Runtime child process metrics are reported on controller/polling process payloads when a PID is available."
            return payload
        }

        private static func debugAgentMemoryResidentBytes() -> UInt64? {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return UInt64(info.resident_size)
        }

        private static func debugAgentMemoryPhysicalFootprintBytes() -> UInt64? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return UInt64(info.phys_footprint)
        }

        private static func debugAgentMemoryMegabytes(_ bytes: UInt64) -> Double {
            ((Double(bytes) / 1_048_576.0) * 10.0).rounded() / 10.0
        }

        private struct AgentDebugMemoryTotals {
            var liveSessions = 0
            var sessionsWithAnyProjection = 0
            var mcpOriginatedSessions = 0
            var items = 0
            var transcriptTurns = 0
            var projectionRows = 0
            var projectionBlocks = 0
            var turnProjectionCaches = 0
            var projectionCacheRows = 0
            var projectionCacheBlocks = 0
            var archivedSnapshotRows = 0
            var archivedSnapshotBlocks = 0
            var archivedSnapshotCompressedItems = 0
            var itemStringBytes = 0
            var ephemeralPayloadBytes = 0
            var bashLiveOutputBytes = 0
            var pendingCommandOutputBytes = 0
            var reasoningBytes = 0
            var pendingInstructionBytes = 0
            var codexControllers = 0
            var claudeControllers = 0
            var acpControllers = 0
            var providerObjects = 0
            var agentTasks = 0
            var codexEventTasks = 0
            var codexControllerProcessIDs: [Int] = []
            var aliveCodexControllerProcessIDs: [Int] = []
            var codexControllerResidentBytes: UInt64 = 0
            var claudeControllerProcessIDs: [Int] = []
            var aliveClaudeControllerProcessIDs: [Int] = []
            var claudeControllerResidentBytes: UInt64 = 0
            var acpControllerProcessIDs: [Int] = []
            var aliveACPControllerProcessIDs: [Int] = []
            var acpControllerResidentBytes: UInt64 = 0
            var codexModelPollingProcessID: Int?
            var codexModelPollingProcessAppearsAlive = false
            var codexModelPollingResidentBytes: UInt64 = 0

            @MainActor
            mutating func add(session: AgentModeViewModel.TabSession) {
                addSessionState(session)
            }

            mutating func add(
                codexProcessSnapshot: CodexAppServerClient.ProcessSnapshot?,
                claudeProcessSnapshot: AgentRuntimeProcessSnapshot?,
                acpProcessSnapshot: AgentRuntimeProcessSnapshot?
            ) {
                addProcessState(
                    codexProcessSnapshot: codexProcessSnapshot,
                    claudeProcessSnapshot: claudeProcessSnapshot,
                    acpProcessSnapshot: acpProcessSnapshot
                )
            }

            @MainActor
            private mutating func addSessionState(_ session: AgentModeViewModel.TabSession) {
                liveSessions += 1
                mcpOriginatedSessions += session.isMCPOriginated ? 1 : 0
                items += session.items.count
                transcriptTurns += session.transcript.turns.count
                let projections = [
                    session.baseTranscriptProjection,
                    session.fullTranscriptProjection,
                    session.workingTranscriptProjection,
                    session.transcriptProjection
                ]
                var hasAnyProjection = false
                for projection in projections {
                    projectionRows += projection.workingRows.count + projection.archivedRows.count
                    projectionBlocks += projection.workingBlocks.count + projection.archivedBlocks.count
                    if !projection.workingRows.isEmpty
                        || !projection.archivedRows.isEmpty
                        || !projection.workingBlocks.isEmpty
                        || !projection.archivedBlocks.isEmpty
                        || !projection.rowAnchorIndex.isEmpty
                        || !projection.anchorBlockIndex.isEmpty
                    {
                        hasAnyProjection = true
                    }
                }
                sessionsWithAnyProjection += hasAnyProjection ? 1 : 0
                turnProjectionCaches += session.turnProjectionCaches.count
                projectionCacheRows += session.turnProjectionCaches.values.reduce(0) { partial, cache in
                    partial + cache.workingRows.count + cache.archivedRows.count
                }
                projectionCacheBlocks += session.turnProjectionCaches.values.reduce(0) { partial, cache in
                    partial + cache.workingBlocks.count + cache.archivedBlocks.count
                }
                archivedSnapshotRows += session.archivedTranscriptSnapshot.rows.count
                archivedSnapshotBlocks += session.archivedTranscriptSnapshot.blocks.count
                archivedSnapshotCompressedItems += session.archivedTranscriptSnapshot.compressedItems.count
                itemStringBytes += debugAgentMemoryItemStringBytes(session.items)
                ephemeralPayloadBytes += session.ephemeralToolResultPayloadByItemID.values.reduce(0) { partial, payload in
                    partial + payload.utf8.count
                }
                bashLiveOutputBytes += session.bashLiveExecutionByKey.values.reduce(0) { partial, state in
                    partial + (state.output?.utf8.count ?? 0)
                }
                pendingCommandOutputBytes += session.pendingCommandRunningByKey.values.reduce(0) { partial, update in
                    partial + (update.appendedOutput?.utf8.count ?? 0)
                }
                reasoningBytes += session.codexReasoningSegmentsByKey.values.reduce(0) { partial, segment in
                    partial + segment.summaryMarkdown.utf8.count + segment.bodyMarkdown.utf8.count
                }
                reasoningBytes += session.claudeReasoningStatusBuffer.utf8.count
                    + (session.claudeReasoningStatusPendingText?.utf8.count ?? 0)
                    + session.pendingAssistantDelta.utf8.count
                pendingInstructionBytes += session.pendingInstructions.reduce(0) { partial, instruction in
                    partial + instruction.utf8.count
                }
                codexControllers += session.codexController == nil ? 0 : 1
                claudeControllers += session.claudeController == nil ? 0 : 1
                acpControllers += session.acpController == nil ? 0 : 1
                providerObjects += session.provider == nil ? 0 : 1
                agentTasks += session.agentTask == nil ? 0 : 1
                codexEventTasks += session.codexEventTask == nil ? 0 : 1
            }

            private mutating func addProcessState(
                codexProcessSnapshot: CodexAppServerClient.ProcessSnapshot?,
                claudeProcessSnapshot: AgentRuntimeProcessSnapshot?,
                acpProcessSnapshot: AgentRuntimeProcessSnapshot?
            ) {
                if let codexProcessSnapshot {
                    let pid = Int(codexProcessSnapshot.pid)
                    codexControllerProcessIDs.append(pid)
                    if codexProcessSnapshot.appearsAlive {
                        aliveCodexControllerProcessIDs.append(pid)
                    }
                    codexControllerResidentBytes += debugAgentMemoryChildProcessMetrics(pid: codexProcessSnapshot.pid)?.residentBytes ?? 0
                }
                if let claudeProcessSnapshot {
                    let pid = Int(claudeProcessSnapshot.pid)
                    claudeControllerProcessIDs.append(pid)
                    if claudeProcessSnapshot.appearsAlive {
                        aliveClaudeControllerProcessIDs.append(pid)
                    }
                    claudeControllerResidentBytes += debugAgentMemoryChildProcessMetrics(pid: claudeProcessSnapshot.pid)?.residentBytes ?? 0
                }
                if let acpProcessSnapshot {
                    let pid = Int(acpProcessSnapshot.pid)
                    acpControllerProcessIDs.append(pid)
                    if acpProcessSnapshot.appearsAlive {
                        aliveACPControllerProcessIDs.append(pid)
                    }
                    acpControllerResidentBytes += debugAgentMemoryChildProcessMetrics(pid: acpProcessSnapshot.pid)?.residentBytes ?? 0
                }
            }

            mutating func add(codexModelPollingSnapshot: CodexModelPollingService.RuntimeSnapshot) {
                guard let processSnapshot = codexModelPollingSnapshot.processSnapshot else { return }
                codexModelPollingProcessID = Int(processSnapshot.pid)
                codexModelPollingProcessAppearsAlive = processSnapshot.appearsAlive
                codexModelPollingResidentBytes = debugAgentMemoryChildProcessMetrics(pid: processSnapshot.pid)?.residentBytes ?? 0
            }

            func payload() -> [String: Any] {
                [
                    "live_sessions": liveSessions,
                    "sessions_with_any_projection": sessionsWithAnyProjection,
                    "mcp_originated_sessions": mcpOriginatedSessions,
                    "items": items,
                    "transcript_turns": transcriptTurns,
                    "projection_rows": projectionRows,
                    "projection_blocks": projectionBlocks,
                    "turn_projection_caches": turnProjectionCaches,
                    "projection_cache_rows": projectionCacheRows,
                    "projection_cache_blocks": projectionCacheBlocks,
                    "archived_snapshot_rows": archivedSnapshotRows,
                    "archived_snapshot_blocks": archivedSnapshotBlocks,
                    "archived_snapshot_compressed_items": archivedSnapshotCompressedItems,
                    "item_string_bytes": itemStringBytes,
                    "ephemeral_payload_bytes": ephemeralPayloadBytes,
                    "bash_live_output_bytes": bashLiveOutputBytes,
                    "pending_command_output_bytes": pendingCommandOutputBytes,
                    "reasoning_bytes": reasoningBytes,
                    "pending_instruction_bytes": pendingInstructionBytes,
                    "codex_controllers": codexControllers,
                    "claude_controllers": claudeControllers,
                    "acp_controllers": acpControllers,
                    "provider_objects": providerObjects,
                    "agent_tasks": agentTasks,
                    "codex_event_tasks": codexEventTasks,
                    "codex_controller_process_ids": codexControllerProcessIDs.sorted(),
                    "alive_codex_controller_process_ids": aliveCodexControllerProcessIDs.sorted(),
                    "codex_controller_resident_bytes": NSNumber(value: codexControllerResidentBytes),
                    "codex_controller_resident_mb": debugAgentMemoryMegabytes(codexControllerResidentBytes),
                    "claude_controller_process_ids": claudeControllerProcessIDs.sorted(),
                    "alive_claude_controller_process_ids": aliveClaudeControllerProcessIDs.sorted(),
                    "claude_controller_resident_bytes": NSNumber(value: claudeControllerResidentBytes),
                    "claude_controller_resident_mb": debugAgentMemoryMegabytes(claudeControllerResidentBytes),
                    "acp_controller_process_ids": acpControllerProcessIDs.sorted(),
                    "alive_acp_controller_process_ids": aliveACPControllerProcessIDs.sorted(),
                    "acp_controller_resident_bytes": NSNumber(value: acpControllerResidentBytes),
                    "acp_controller_resident_mb": debugAgentMemoryMegabytes(acpControllerResidentBytes),
                    "codex_model_polling_process_id": codexModelPollingProcessID.map { $0 as Any } ?? NSNull(),
                    "codex_model_polling_process_appears_alive": codexModelPollingProcessAppearsAlive,
                    "codex_model_polling_resident_bytes": NSNumber(value: codexModelPollingResidentBytes),
                    "codex_model_polling_resident_mb": debugAgentMemoryMegabytes(codexModelPollingResidentBytes)
                ]
            }
        }

        private func captureAgentPerfSessionSnapshots(filter: Set<UUID>?) async -> [String: Any] {
            await MainActor.run { () -> [String: Any] in
                var recordedByWindow: [[String: Any]] = []
                var totalRecorded = 0
                for window in WindowStatesManager.shared.allWindows {
                    let recorded = window.agentModeViewModel.test_recordPerfSessionSnapshotsForAllTabs(
                        source: "debugDiagnostics",
                        tabIDs: filter
                    )
                    totalRecorded += recorded.count
                    recordedByWindow.append([
                        "window_id": window.windowID,
                        "recorded_tab_ids": recorded.map(\.uuidString)
                    ])
                }
                return [
                    "windows": recordedByWindow,
                    "total_recorded": totalRecorded,
                    "diagnostics_enabled": AgentModePerfDiagnostics.isEnabled
                ]
            }
        }
    }
#endif
