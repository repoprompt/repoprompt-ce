#if DEBUG
    import Combine
    import CoreServices
    import MCP
    @testable import RepoPrompt
    import RepoPromptShared
    import XCTest

    final class MCPReadSearchLatencyDiagnosticsGuardTests: XCTestCase {
        private var temporaryRoots = FileSystemTemporaryRoots()

        override func tearDown() {
            EditFlowPerf.resetDebugCaptureForTesting()
            temporaryRoots.removeAll()
            super.tearDown()
        }

        func testHiddenDispatcherRecognizesReadSearchCaptureOperations() throws {
            let diagnostics = try diagnosticsSource()
            XCTAssertTrue(diagnostics.contains("mcp_read_search_capture_begin"))
            XCTAssertTrue(diagnostics.contains("mcp_read_search_capture_snapshot"))
            XCTAssertTrue(diagnostics.contains("mcp_read_search_admission_snapshot"))
            XCTAssertTrue(diagnostics.contains("mcp_read_search_admission_configure"))
            XCTAssertTrue(diagnostics.contains("mcp_read_search_content_read_scheduler_snapshot"))

            let sibling = try source("Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift")
            XCTAssertTrue(sibling.contains("#if DEBUG"))
            XCTAssertTrue(sibling.contains("100 ... 100_000"))
            XCTAssertTrue(sibling.contains("100 ... 60000"))
            XCTAssertTrue(sibling.contains("0 ... 60000"))
            XCTAssertTrue(sibling.contains("overload_count"))
            XCTAssertTrue(sibling.contains("wait_expiry_count"))
            XCTAssertTrue(sibling.contains("active_count"))
            XCTAssertTrue(sibling.contains("queued_count"))
            XCTAssertTrue(sibling.contains("window_count"))
            XCTAssertTrue(sibling.contains("\"lanes\""))
            XCTAssertTrue(sibling.contains("\"lane_count\""))
            XCTAssertTrue(sibling.contains("MCPConnectionCallLane.ordinary.rawValue"))
            XCTAssertTrue(sibling.contains("MCPConnectionCallLane.control.rawValue"))
            XCTAssertTrue(sibling.contains("MCPConnectionCallLane.smallRead.rawValue"))
            XCTAssertTrue(sibling.contains("MCPConnectionCallLane.gitRead.rawValue"))
            XCTAssertTrue(sibling.contains("MCPConnectionCallLane.fileSearch.rawValue"))
            XCTAssertTrue(sibling.contains("maximum_active_count"))
            XCTAssertTrue(sibling.contains("maximum_queued_count"))
            XCTAssertTrue(sibling.contains("max_queued_waiters"))
            XCTAssertTrue(sibling.contains("active_permit_count"))
            XCTAssertTrue(sibling.contains("queued_waiter_count"))
            XCTAssertTrue(sibling.contains("owner_lane_count"))
            XCTAssertTrue(sibling.contains("cancellation_count"))
            XCTAssertTrue(sibling.contains("interactive_grant_count"))
            XCTAssertTrue(sibling.contains("bulk_grant_count"))
        }

        func testPerStoreAdmissionDebugConfigurationIsFixedCapacityIdleOnlyAndBounded() async {
            let store = WorkspaceFileContextStore()
            let baseline = await store.searchLaneSnapshotForTesting()
            XCTAssertEqual(baseline.activePermitCount, 0)
            XCTAssertEqual(baseline.waiterCount, 0)

            let replacement = StoreBackedWorkspaceSearchLane.Configuration(
                maxQueueWait: .seconds(60),
                retryAfterMilliseconds: 60000
            )
            guard case let .applied(configured) = await store.configureSearchLaneForTesting(replacement) else {
                return XCTFail("Idle per-store lane should accept bounded DEBUG configuration")
            }
            XCTAssertEqual(configured.configuration.maxQueueWaitMilliseconds, 60000)
            XCTAssertEqual(configured.configuration.retryAfterMilliseconds, 60000)
            XCTAssertTrue(configured.isIdle)

            let sibling = try? source("Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift")
            XCTAssertTrue(sibling?.contains("\"active_capacity\": entry.snapshot.configuration.maxActiveLeases") == true)
            XCTAssertTrue(sibling?.contains("\"max_queued\": entry.snapshot.configuration.maxQueuedWaiters") == true)
            XCTAssertTrue(sibling?.contains("range: 100 ... 60000") == true)
            XCTAssertTrue(sibling?.contains("range: 0 ... 60000") == true)
            XCTAssertFalse(sibling?.contains("global_capacity") == true)
        }

        func testSearchLaneInvalidWindowErrorsRetainRequestedOperation() async throws {
            let manager = ServerNetworkManager.shared
            for operation in [
                "mcp_read_search_admission_snapshot",
                "mcp_read_search_admission_configure"
            ] {
                let result = await manager.handleDebugDiagnosticsTool(
                    connectionID: UUID(),
                    arguments: [
                        "op": .string(operation),
                        "window_id": .int(0)
                    ]
                )
                let payload = try debugDiagnosticsPayload(result)
                XCTAssertEqual(payload["ok"] as? Bool, false)
                XCTAssertEqual(payload["op"] as? String, operation)
                XCTAssertEqual(payload["code"] as? String, "invalid_params")
            }
        }

        func testContentReadSchedulerDebugDiagnosticsExposeAggregateSnapshot() async throws {
            let manager = ServerNetworkManager.shared
            let result = await manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: ["op": .string("mcp_read_search_content_read_scheduler_snapshot")]
            )
            let payload = try debugDiagnosticsPayload(result)
            XCTAssertEqual(payload["ok"] as? Bool, true)
            let scheduler = try XCTUnwrap(payload["scheduler"] as? [String: Any])
            XCTAssertEqual((scheduler["capacity"] as? NSNumber)?.intValue, FileSystemService.contentReadWorkerLimitForTesting)
            XCTAssertEqual((scheduler["max_queued_waiters"] as? NSNumber)?.intValue, 512)
            XCTAssertNotNil(scheduler["active_permit_count"])
            XCTAssertNotNil(scheduler["queued_waiter_count"])
            XCTAssertNotNil(scheduler["owner_lane_count"])
            XCTAssertNotNil(scheduler["grant_count"])
            XCTAssertNotNil(scheduler["overload_count"])
        }

        func testPermitLifecycleTimelineEventsJoinBySharedRequestIdentity() async throws {
            let manager = ServerNetworkManager.shared
            let connectionID = UUID()
            _ = await manager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)
            addTeardownBlock {
                await manager.debugRemoveConnection(connectionID)
            }

            let identity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .number(41),
                connectionID: connectionID.uuidString,
                connectionGeneration: 7,
                appInvocationID: UUID().uuidString,
                requestOrdinal: 3
            )
            _ = startedCapture(label: "permit-identity", maxSamples: 100)
            let correlation = try XCTUnwrap(
                EditFlowPerf.makeLifecycleCorrelationIfActive(requestIdentity: identity)
            )

            let value = try await manager.withConnectionCallPermitForTesting(
                connectionID: connectionID,
                lane: .ordinary,
                toolName: "read_file",
                lifecycleCorrelation: correlation
            ) {
                "ok"
            }
            XCTAssertEqual(value, "ok")

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let permitEvents = snapshot.lifecycleEvents.filter {
                [
                    "MCP.ToolCall.PermitQueued",
                    "MCP.ToolCall.PermitAcquired",
                    "MCP.ToolCall.PermitReleased"
                ].contains($0.eventName)
            }
            XCTAssertEqual(permitEvents.map(\.eventName), [
                "MCP.ToolCall.PermitQueued",
                "MCP.ToolCall.PermitAcquired",
                "MCP.ToolCall.PermitReleased"
            ])
            XCTAssertEqual(Set(permitEvents.map(\.correlationID)).count, 1)
            XCTAssertTrue(permitEvents.allSatisfy { $0.requestIdentity == identity })
            XCTAssertTrue(permitEvents.allSatisfy {
                $0.sanitizedDimensions.contains("tool=read_file")
                    && $0.sanitizedDimensions.contains("admissionClass=ordinary")
                    && $0.sanitizedDimensions.contains("queueDepth=")
                    && $0.sanitizedDimensions.contains("ownerResource=connection_\(connectionID.uuidString)")
            })
            XCTAssertTrue(permitEvents.last?.sanitizedDimensions.contains("outcome=completed") == true)

            let payloads = try XCTUnwrap(
                EditFlowPerf.debugCaptureSnapshot(finish: false)
                    .payload()["lifecycle_events"] as? [[String: Any]]
            )
            let joinedIdentities = payloads.compactMap { $0["request_identity"] as? [String: Any] }
            XCTAssertEqual(joinedIdentities.count, 3)
            XCTAssertTrue(joinedIdentities.allSatisfy {
                $0["jsonrpc_request_id"] as? String == "number:41"
                    && $0["connection_id"] as? String == connectionID.uuidString
                    && ($0["connection_generation"] as? NSNumber)?.uint64Value == 7
                    && $0["app_invocation_id"] as? String == identity.appInvocationID
                    && ($0["request_ordinal"] as? NSNumber)?.uint64Value == 3
            })

            let managerSource = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            for hook in [
                "EditFlowPerf.Lifecycle.MCPToolCall.permitQueued",
                "EditFlowPerf.Lifecycle.MCPToolCall.permitAcquired",
                "EditFlowPerf.Lifecycle.MCPToolCall.permitReleased",
                "requestIdentity: resolvedRequestIdentity"
            ] {
                XCTAssertTrue(managerSource.contains(hook), "Missing permit timeline hook: \(hook)")
            }
        }

        func testCorrelatedRequestTimelineJoinsAllWI2StagesAndWorkloadMatrices() throws {
            let connectionID = UUID().uuidString
            let identity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string("request-7"),
                connectionID: connectionID,
                connectionGeneration: 2,
                requestOrdinal: 11
            )
            let invocationID = try XCTUnwrap(identity.appInvocationID)
            XCTAssertEqual(
                invocationID,
                MCPRequestTimelineIdentity.deterministicAppInvocationID(
                    jsonRPCRequestID: .string("request-7"),
                    connectionID: connectionID,
                    connectionGeneration: 2,
                    requestOrdinal: 11
                )
            )
            let otherConnectionIdentity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string("request-7"),
                connectionID: UUID().uuidString,
                connectionGeneration: 2,
                requestOrdinal: 11
            )
            XCTAssertNotEqual(invocationID, otherConnectionIdentity.appInvocationID)

            _ = startedCapture(label: "wi2-all-stages", maxSamples: 200)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(requestIdentity: identity))
            for event in [
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                EditFlowPerf.Lifecycle.MCPToolCall.permitQueued,
                EditFlowPerf.Lifecycle.MCPToolCall.permitAcquired,
                EditFlowPerf.Lifecycle.MCPToolCall.mainActorScheduled,
                EditFlowPerf.Lifecycle.MCPToolCall.mainActorEntered,
                EditFlowPerf.Lifecycle.MCPToolCall.mainActorExited,
                EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderBegan,
                EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderEnded,
                EditFlowPerf.Lifecycle.MCPToolCall.observerScheduled,
                EditFlowPerf.Lifecycle.MCPToolCall.observerEntered,
                EditFlowPerf.Lifecycle.MCPToolCall.observerExited,
                EditFlowPerf.Lifecycle.MCPToolCall.publicationOwnershipState,
                EditFlowPerf.Lifecycle.MCPToolCall.handlerResultReady,
                EditFlowPerf.Lifecycle.MCPToolCall.permitReleased
            ] {
                EditFlowPerf.lifecycleEvent(event, correlation: correlation)
            }
            let capturePayload = EditFlowPerf.debugCaptureSnapshot(finish: true).payload()
            XCTAssertEqual((capturePayload["request_timeline_count"] as? NSNumber)?.intValue, 1)
            let timelines = try XCTUnwrap(capturePayload["request_timelines"] as? [[String: Any]])
            XCTAssertEqual(timelines.first?["join_key"] as? String, invocationID)
            let catalog = try XCTUnwrap(capturePayload["workload_matrix_catalog"] as? [[String: Any]])
            XCTAssertEqual(Set(catalog.compactMap { $0["id"] as? String }), [
                "same_connection_ordinary_burst",
                "same_connection_mixed_ordinary_search",
                "distinct_connections_one_window",
                "distinct_windows",
                "agent_transcript_short_vs_long"
            ])

            let previousPerf = UserDefaults.standard.object(forKey: "enableAgentModePerfDiagnostics")
            UserDefaults.standard.set(true, forKey: "enableAgentModePerfDiagnostics")
            defer {
                if let previousPerf {
                    UserDefaults.standard.set(previousPerf, forKey: "enableAgentModePerfDiagnostics")
                } else {
                    UserDefaults.standard.removeObject(forKey: "enableAgentModePerfDiagnostics")
                }
                MCPResponseDeliveryTracer.resetDebugEvents()
            }
            MCPResponseDeliveryTracer.resetDebugEvents()
            for (layer, phase) in [
                ("app_uds_transport", "frame_accepted"),
                ("app_sdk", "sdk_decode_completed"),
                ("app_tool_handler", "handler_result_ready"),
                ("app_uds_transport", "sdk_encode_completed"),
                ("app_uds_transport", "transport_write_completed"),
                ("proxy_ledger", "frame_committed"),
                ("proxy_stdout", "stdout_write_completed")
            ] {
                MCPResponseDeliveryTracer.emit(MCPResponseDeliveryTraceEvent(
                    layer: layer,
                    phase: phase,
                    connectionID: connectionID,
                    connectionGeneration: 2,
                    direction: phase == "frame_accepted" ? .clientToServer : .serverToClient,
                    id: .string("request-7"),
                    method: "tools/call",
                    tool: "read_file",
                    requestOrdinal: 11,
                    requestIdentity: identity
                ))
            }
            let delivery = MCPResponseDeliveryTracer.debugEventSnapshot()
            XCTAssertEqual(delivery.count, 7)
            XCTAssertTrue(delivery.allSatisfy { $0.requestIdentity?.appInvocationID == invocationID })

            let sources = try [
                source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift"),
                source("Sources/RepoPrompt/Infrastructure/MCP/UnixSocketMCPTransport.swift"),
                source("Sources/RepoPromptShared/MCP/JSONRPCBridgeLedger.swift"),
                source("Sources/RepoPromptMCP/main.swift"),
                source("Sources/RepoPrompt/Infrastructure/AI/Agents/AgentToolTracker.swift"),
                source("Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunTerminalCommitBarrier.swift")
            ].joined(separator: "\n")
            for hook in [
                "frame_accepted",
                "sdk_decode_completed",
                "permitQueued",
                "permitAcquired",
                "mainActorScheduled",
                "resolvedProviderBegan",
                "observerScheduled",
                "handler_result_ready",
                "sdk_encode_completed",
                "transport_write_completed",
                "stdout_write_completed",
                "publicationPending",
                "terminalBarrier"
            ] {
                XCTAssertTrue(sources.contains(hook), "Missing WI-2 stage hook: \(hook)")
            }
        }

        func testLimiterDiagnosticsReportPromptQueuedCancellationAndIdleState() async {
            let clock = LockedMCPDiagnosticsClock(nowNanoseconds: 1_000_000_000)
            let limiter = AsyncLimiter(limit: 1, debugNowNanoseconds: { clock.now() })
            let holderGate = MCPDiagnosticsGate()
            let waiterBodyRan = MCPDiagnosticsSignal()
            let snapshotSignal = MCPDiagnosticsSnapshotSignal()
            await limiter.setDebugStateObserver { snapshot in
                Task { await snapshotSignal.record(snapshot) }
            }

            let holder = Task {
                try await limiter.withPermit {
                    await holderGate.markStartedAndWaitForRelease()
                }
            }
            await holderGate.waitUntilStarted()

            let waiter = Task {
                do {
                    try await limiter.withPermit {
                        await waiterBodyRan.mark()
                    }
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }

            let queued = await snapshotSignal.waitUntil { $0.waiterCount == 1 }
            XCTAssertEqual(queued.limit, 1)
            XCTAssertEqual(queued.permits, 0)
            XCTAssertEqual(queued.activePermitCount, 1)
            XCTAssertEqual(queued.waiterCount, 1)
            XCTAssertEqual(queued.inFlight, 2)
            XCTAssertEqual(queued.oldestWaiterAgeMilliseconds, 0)
            XCTAssertFalse(queued.isClosed)
            XCTAssertFalse(queued.isIdle)

            clock.advance(milliseconds: 275)
            let aged = await limiter.debugSnapshot()
            XCTAssertEqual(aged.oldestWaiterAgeMilliseconds, 275)

            waiter.cancel()
            let cancelled = await snapshotSignal.waitUntil {
                $0.cancelledWaiterCount == 1 && $0.waiterCount == 0 && $0.inFlight == 1
            }
            XCTAssertEqual(cancelled.waiterCount, 0)
            XCTAssertEqual(cancelled.cancelledWaiterCount, 1)
            let waiterWasCancelled = await waiter.value
            let didRunWaiterBody = await waiterBodyRan.isMarked()
            XCTAssertTrue(waiterWasCancelled)
            XCTAssertFalse(didRunWaiterBody)

            await holderGate.release()
            try? await holder.value

            let settled = await snapshotSignal.waitUntil { $0.isIdle }
            XCTAssertEqual(settled.permits, 1)
            XCTAssertEqual(settled.activePermitCount, 0)
            XCTAssertEqual(settled.waiterCount, 0)
            XCTAssertEqual(settled.inFlight, 0)
            XCTAssertNil(settled.oldestWaiterAgeMilliseconds)
            XCTAssertEqual(settled.cancelledWaiterCount, 1)
            XCTAssertFalse(settled.isClosed)
            XCTAssertTrue(settled.isIdle)
            await limiter.setDebugStateObserver(nil)
        }

        @MainActor
        func testRuntimeSnapshotHiddenOperationValidatesBoundsAndReturnsAggregateShape() async throws {
            let manager = ServerNetworkManager.shared
            let connectionID = UUID()
            _ = await manager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)
            addTeardownBlock {
                await manager.debugRemoveConnection(connectionID)
            }
            let runID = UUID()
            await manager.registerToolCallObserver(for: runID) { _ in }
            await manager.registerToolEventObserver(
                for: runID,
                observer: ServerNetworkManager.ToolEventObserver(onCalled: { _, _, _ in }, onCompleted: nil)
            )
            addTeardownBlock {
                await manager.unregisterToolObservers(for: runID)
            }

            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            addTeardownBlock { @MainActor in
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }

            let expectedToolCallObserverCount = await manager.toolCallObserverCount()
            let expectedToolEventObserverCount = await manager.toolEventObserverCount()
            let result = await manager.handleDebugDiagnosticsTool(
                connectionID: connectionID,
                arguments: [
                    "op": .string("mcp_read_search_runtime_snapshot"),
                    "window_id": .int(window.windowID),
                    "recent_publication_limit": .int(0),
                    "root_limit": .int(1)
                ]
            )
            let payload = try debugDiagnosticsPayload(result)
            XCTAssertEqual(payload["ok"] as? Bool, true)
            XCTAssertEqual(payload["op"] as? String, "mcp_read_search_runtime_snapshot")
            let runtime = try XCTUnwrap(payload["runtime"] as? [String: Any])
            XCTAssertEqual(runtime["consistency"] as? String, "best_effort")
            XCTAssertEqual((runtime["window_count"] as? NSNumber)?.intValue, 1)
            let observers = try XCTUnwrap(runtime["observers"] as? [String: Any])
            XCTAssertEqual(
                (observers["tool_call_observer_count"] as? NSNumber)?.intValue,
                expectedToolCallObserverCount
            )
            XCTAssertEqual(
                (observers["tool_event_observer_count"] as? NSNumber)?.intValue,
                expectedToolEventObserverCount
            )
            let windows = try XCTUnwrap(runtime["windows"] as? [[String: Any]])
            let windowPayload = try XCTUnwrap(windows.first)
            XCTAssertEqual((windowPayload["window_id"] as? NSNumber)?.intValue, window.windowID)
            XCTAssertNotNil(windowPayload["projection_direct_file_id_lookup_count"])
            XCTAssertNotNil(windowPayload["projection_direct_folder_id_lookup_count"])
            XCTAssertNotNil(windowPayload["projection_direct_id_lookup_miss_count"])
            XCTAssertNotNil(windowPayload["projection_canonical_resync_count"])
            let uiIndexRebuild = try XCTUnwrap(windowPayload["ui_index_rebuild"] as? [String: Any])
            XCTAssertNotNil(uiIndexRebuild["count"])
            XCTAssertNotNil(uiIndexRebuild["visited_file_count"])
            let storeWork = try XCTUnwrap(windowPayload["store_work"] as? [String: Any])
            XCTAssertNotNil(storeWork["invalidations"])
            XCTAssertNotNil(storeWork["catalog_rebuild"])
            let searchRebuild = try XCTUnwrap(windowPayload["search_rebuild"] as? [String: Any])
            XCTAssertNotNil(searchRebuild["c_index_build_us"])
            XCTAssertNotNil(searchRebuild["stale_discarded_count"])
            let duplication = try XCTUnwrap(runtime["physical_root_duplication"] as? [[String: Any]])
            XCTAssertTrue(duplication.isEmpty)
            let toolWork = try XCTUnwrap(runtime["tool_work"] as? [String: Any])
            XCTAssertNotNil(toolWork["git_invocations"])
            XCTAssertNotNil(toolWork["read_file_invocations"])
            let autoSelection = try XCTUnwrap(windowPayload["read_file_auto_selection"] as? [String: Any])
            for key in [
                "canonical_lane_count",
                "canonical_worker_count",
                "mirror_lane_count",
                "mirror_worker_count",
                "closing_context_count",
                "pending_canonical_batch_count",
                "pending_mirror_batch_count"
            ] {
                XCTAssertEqual((autoSelection[key] as? NSNumber)?.intValue, 0, key)
            }
            let smallReadLaneLimit = ServerNetworkManager.smallReadCallLaneLimit
            let controlLaneLimit = ServerNetworkManager.controlCallLaneLimit
            let gitReadLaneLimit = ServerNetworkManager.gitReadCallLaneLimit
            let fileSearchLaneLimit = ServerNetworkManager.fileSearchCallLaneLimit
            let totalLaneLimit = 1 + controlLaneLimit + smallReadLaneLimit + gitReadLaneLimit + fileSearchLaneLimit
            let limiter = try XCTUnwrap(runtime["limiter"] as? [String: Any])
            XCTAssertEqual(limiter["found"] as? Bool, true)
            XCTAssertEqual(limiter["connection_id"] as? String, connectionID.uuidString)
            XCTAssertEqual((limiter["lane_count"] as? NSNumber)?.intValue, MCPConnectionCallLane.allCases.count)
            XCTAssertEqual((limiter["limit"] as? NSNumber)?.intValue, totalLaneLimit)
            XCTAssertEqual((limiter["permits"] as? NSNumber)?.intValue, totalLaneLimit)
            XCTAssertEqual((limiter["active_permit_count"] as? NSNumber)?.intValue, 0)
            XCTAssertEqual((limiter["waiter_count"] as? NSNumber)?.intValue, 0)
            XCTAssertEqual((limiter["in_flight_count"] as? NSNumber)?.intValue, 0)
            XCTAssertEqual(limiter["is_closed"] as? Bool, false)
            XCTAssertEqual(limiter["is_idle"] as? Bool, true)
            let lanes = try XCTUnwrap(limiter["lanes"] as? [String: Any])
            XCTAssertEqual(Set(lanes.keys), Set(MCPConnectionCallLane.allCases.map(\.rawValue)))
            for (laneName, laneLimit) in [
                ("ordinary", 1),
                ("control", controlLaneLimit),
                ("small_read", smallReadLaneLimit),
                ("git_read", gitReadLaneLimit),
                ("file_search", fileSearchLaneLimit)
            ] {
                let lane = try XCTUnwrap(lanes[laneName] as? [String: Any])
                XCTAssertEqual((lane["limit"] as? NSNumber)?.intValue, laneLimit, laneName)
                XCTAssertEqual((lane["permits"] as? NSNumber)?.intValue, laneLimit, laneName)
                XCTAssertEqual((lane["active_permit_count"] as? NSNumber)?.intValue, 0, laneName)
                XCTAssertEqual((lane["waiter_count"] as? NSNumber)?.intValue, 0, laneName)
                XCTAssertEqual((lane["in_flight_count"] as? NSNumber)?.intValue, 0, laneName)
                XCTAssertEqual(lane["is_closed"] as? Bool, false, laneName)
                XCTAssertEqual(lane["is_idle"] as? Bool, true, laneName)
            }

            let missingConnectionID = UUID()
            let missingResult = await manager.handleDebugDiagnosticsTool(
                connectionID: connectionID,
                arguments: [
                    "op": .string("mcp_read_search_runtime_snapshot"),
                    "connection_id": .string(missingConnectionID.uuidString),
                    "window_id": .int(window.windowID),
                    "recent_publication_limit": .int(0),
                    "root_limit": .int(1)
                ]
            )
            let missingPayload = try debugDiagnosticsPayload(missingResult)
            let missingRuntime = try XCTUnwrap(missingPayload["runtime"] as? [String: Any])
            let missingLimiter = try XCTUnwrap(missingRuntime["limiter"] as? [String: Any])
            XCTAssertEqual(missingLimiter["found"] as? Bool, false)
            XCTAssertEqual(missingLimiter["connection_id"] as? String, missingConnectionID.uuidString)

            for invalidArguments: [String: Value] in [
                [
                    "op": .string("mcp_read_search_runtime_snapshot"),
                    "connection_id": .string("not-a-uuid")
                ],
                [
                    "op": .string("mcp_read_search_runtime_snapshot"),
                    "recent_publication_limit": .int(33)
                ],
                [
                    "op": .string("mcp_read_search_runtime_snapshot"),
                    "root_limit": .int(0)
                ]
            ] {
                let invalidResult = await manager.handleDebugDiagnosticsTool(
                    connectionID: connectionID,
                    arguments: invalidArguments
                )
                let invalidPayload = try debugDiagnosticsPayload(invalidResult)
                XCTAssertEqual(invalidPayload["ok"] as? Bool, false)
                XCTAssertEqual(invalidPayload["op"] as? String, "mcp_read_search_runtime_snapshot")
                XCTAssertEqual(invalidPayload["code"] as? String, "invalid_params")
            }
        }

        @MainActor
        func testRuntimeSnapshotProjectsActiveAndCoalescedPendingBarrierState() async throws {
            let manager = ServerNetworkManager.shared
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            addTeardownBlock { @MainActor in
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }

            let root = try temporaryRoots.makeRoot(suiteName: "RuntimePendingBarrier")
            let firstURL = root.appendingPathComponent("First.swift")
            let secondURL = root.appendingPathComponent("Second.swift")
            try FileSystemTestSupport.write("first", to: firstURL)
            try FileSystemTestSupport.write("second", to: secondURL)
            let store = window.workspaceFileContextStore
            let record = try await store.loadRoot(path: root.path)
            let watcherStartGate = MCPDiagnosticsGate()
            await store.setWatcherServiceStateWillReconcileHandler { observedRootID, shouldWatch in
                guard observedRootID == record.id, shouldWatch else { return }
                await watcherStartGate.markStartedAndWaitForRelease()
            }
            let watcherStartTask = Task {
                try await store.startWatchingRoot(id: record.id)
            }
            await watcherStartGate.waitUntilStarted()

            let flushGate = MCPDiagnosticsGate()
            await store.setScopedIngressBarrierWillFlushHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await flushGate.markStartedAndWaitForRelease()
            }
            let activeBarrier = Task {
                await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            }
            var pendingBarrier: Task<[WorkspaceIngressBarrierSample], Never>?
            var coalescedBarrier: Task<[WorkspaceIngressBarrierSample], Never>?

            do {
                await flushGate.waitUntilStarted()
                let createdFileFlags = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
                )
                let firstAccepted = try await store.acceptWatcherPayloadForTesting(
                    rootID: record.id,
                    events: [(absolutePath: firstURL.path, flags: createdFileFlags, eventId: 500)],
                    scheduleDrain: false
                )
                _ = try XCTUnwrap(firstAccepted, "Expected first watcher watermark")
                pendingBarrier = Task {
                    await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
                }
                for _ in 0 ..< 1000 {
                    if await store.scopedIngressBarrierStatsForTesting(rootID: record.id).successorCount == 1 { break }
                    await Task.yield()
                }

                let acceptedSecondWatermark = try await store.acceptWatcherPayloadForTesting(
                    rootID: record.id,
                    events: [(absolutePath: secondURL.path, flags: createdFileFlags, eventId: 501)],
                    scheduleDrain: false
                )
                let secondAccepted = try XCTUnwrap(
                    acceptedSecondWatermark,
                    "Expected second watcher watermark"
                )
                try await store.publishSyntheticFileSystemDeltasForTesting(
                    rootID: record.id,
                    deltas: [.fileModified("First.swift", nil)]
                )
                let acceptedServicePublicationSequence = await store.appliedIngressSnapshotForTesting(rootID: record.id)
                    .acceptedServicePublicationSequence
                coalescedBarrier = Task {
                    await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
                }
                for _ in 0 ..< 1000 {
                    if await store.scopedIngressBarrierStatsForTesting(rootID: record.id).coalescedSuccessorCount == 1 {
                        break
                    }
                    await Task.yield()
                }

                let result = await manager.handleDebugDiagnosticsTool(
                    connectionID: UUID(),
                    arguments: [
                        "op": .string("mcp_read_search_runtime_snapshot"),
                        "window_id": .int(window.windowID),
                        "recent_publication_limit": .int(0),
                        "root_limit": .int(1)
                    ]
                )
                await cleanupRuntimePendingBarrierTest(
                    store: store,
                    rootID: record.id,
                    watcherStartGate: watcherStartGate,
                    flushGate: flushGate,
                    watcherStartTask: watcherStartTask,
                    activeBarrier: activeBarrier,
                    pendingBarrier: pendingBarrier,
                    coalescedBarrier: coalescedBarrier
                )

                let payload = try debugDiagnosticsPayload(result)
                let runtime = try XCTUnwrap(payload["runtime"] as? [String: Any])
                let windows = try XCTUnwrap(runtime["windows"] as? [[String: Any]])
                let windowPayload = try XCTUnwrap(windows.first)
                let roots = try XCTUnwrap(windowPayload["roots"] as? [[String: Any]])
                let rootPayload = try XCTUnwrap(roots.first)
                let barrier = try XCTUnwrap(rootPayload["barrier"] as? [String: Any])
                XCTAssertEqual((barrier["launch_count"] as? NSNumber)?.intValue, 1)
                XCTAssertEqual((barrier["join_count"] as? NSNumber)?.intValue, 1)
                XCTAssertEqual((barrier["successor_count"] as? NSNumber)?.intValue, 1)
                XCTAssertEqual((barrier["coalesced_successor_count"] as? NSNumber)?.intValue, 1)
                XCTAssertEqual((barrier["completion_count"] as? NSNumber)?.intValue, 0)
                let active = try XCTUnwrap(barrier["active"] as? [String: Any])
                XCTAssertEqual((active["target_watcher_watermark"] as? NSNumber)?.uint64Value, 0)
                let pending = try XCTUnwrap(barrier["pending"] as? [String: Any])
                XCTAssertEqual(
                    (pending["target_watcher_watermark"] as? NSNumber)?.uint64Value,
                    secondAccepted.rawValue
                )
                XCTAssertEqual(
                    (pending["target_service_publication_sequence"] as? NSNumber)?.uint64Value,
                    acceptedServicePublicationSequence
                )
                XCTAssertNotNil((pending["age_ms"] as? NSNumber)?.uint64Value)
            } catch {
                await cleanupRuntimePendingBarrierTest(
                    store: store,
                    rootID: record.id,
                    watcherStartGate: watcherStartGate,
                    flushGate: flushGate,
                    watcherStartTask: watcherStartTask,
                    activeBarrier: activeBarrier,
                    pendingBarrier: pendingBarrier,
                    coalescedBarrier: coalescedBarrier
                )
                throw error
            }
        }

        func testExpectedAttributionStagesRemainPresent() throws {
            let perf = try source("Sources/RepoPrompt/Infrastructure/Diffing/EditFlowPerf.swift")
            for stage in [
                "EditFlow.MCPToolCall.PreToolFilesystemFlush",
                "EditFlow.MCPToolCall.EffectivePolicySnapshot",
                "EditFlow.MCPToolCall.RoutingSnapshot",
                "EditFlow.MCPToolCall.PreLimiterEnvelope",
                "EditFlow.MCPToolCall.LimiterResolution",
                "EditFlow.MCPToolCall.LimiterEnvelope",
                "EditFlow.MCPToolCall.LimiterWait",
                "EditFlow.MCPToolCall.PermitBodyEnvelope",
                "EditFlow.MCPToolCall.PermitPreDispatchEnvelope",
                "EditFlow.MCPToolCall.EnabledStateSnapshot",
                "EditFlow.MCPToolCall.WindowRunResolution",
                "EditFlow.MCPToolCall.OwnershipPurposeResolution",
                "EditFlow.MCPToolCall.ToolCallRecording",
                "EditFlow.MCPToolCall.RunScopedTabRebindFallback",
                "EditFlow.MCPToolCall.LegacyTabBindingCompatibility",
                "EditFlow.MCPToolCall.ServiceToolLookup",
                "EditFlow.MCPToolCall.ServiceToolLookup.ServiceToolsAwait",
                "EditFlow.MCPToolCall.ServiceToolLookup.ToolDefinitionScan",
                "EditFlow.MCPToolCall.ServiceToolLookup.PublicWindowIDInjection",
                "EditFlow.MCPToolCall.ServiceToolLookup.AppSettingsToolsBuild",
                "EditFlow.MCPToolCall.ServiceToolLookup.WindowRoutingToolsCacheActorBody",
                "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsActorBodyTotal",
                "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsMaterialization",
                "EditFlow.MCPWindowToolCatalog.Construction",
                "EditFlow.MCPWindowToolCatalog.InvalidateToolsCache",
                "EditFlow.MCPWindowToolCatalog.Invalidation.ToolSummariesChange",
                "EditFlow.MCPWindowToolCatalog.Invalidation.ToolRegistrationUpdate",
                "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.WindowToolsEnabledDidSet",
                "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.AgentBootstrap",
                "EditFlow.MCPWindowToolCatalog.ReadinessWarmAccess",
                "EditFlow.MCPWindowToolCatalog.ServiceRegistryToolsPublication",
                "EditFlow.MCPWindowToolCatalog.CodexTurnMCPServerEnable",
                "EditFlow.MCPToolCall.PermitPostDispatchEnvelope",
                "EditFlow.MCPToolCall.CompletionObservers",
                "EditFlow.MCPToolCall.CompletionObserverResultEncoding",
                "EditFlow.MCPToolCall.CompletionObserverCallbacks",
                "EditFlow.MCPToolCall.RunToolSetup",
                "EditFlow.MCPToolCall.RunToolRegistration",
                "EditFlow.MCPToolCall.ProviderExecution",
                "EditFlow.MCPToolCall.ResolvedProviderDispatch",
                "EditFlow.MCPToolCall.HandlerResultHandoff",
                "EditFlow.MCPToolCall.RunToolTimeoutEnvelope",
                "EditFlow.MCPToolCall.RunToolCompletionCleanup",
                "EditFlow.MCPToolCall.FormatResult",
                "EditFlow.ReadFile.ProviderTotal",
                "EditFlow.ReadFile.ProviderArgumentParsing",
                "EditFlow.ReadFile.ProviderRequestMetadata",
                "EditFlow.ReadFile.ProviderLookupContextResolution",
                "EditFlow.ReadFile.ProviderPathTranslation",
                "EditFlow.ReadFile.ProviderReadEnvelope",
                "EditFlow.ReadFile.ProviderReplyProjection",
                "EditFlow.ReadFile.ProviderAutoSelect",
                "EditFlow.ReadFile.ProviderValueEncoding",
                "EditFlow.ReadFile.ResolveReadableFile",
                "EditFlow.ReadFile.ExplicitIngressFreshnessWait",
                "EditFlow.ReadFile.ExactCatalogShortcut",
                "EditFlow.ReadFile.StoreReadContentForwardAwait",
                "EditFlow.ReadFile.FolderResolutionGeneralLookupFallback",
                "EditFlow.ReadFile.PathLookupStaticSnapshotBuild",
                "EditFlow.ReadFile.ExactPathIssueDetection",
                "EditFlow.ReadFile.RootRefsLookup",
                "EditFlow.ReadFile.FolderResolution",
                "EditFlow.ReadFile.ExternalFolderGuard",
                "EditFlow.ReadFile.ReadableServiceResolution",
                "EditFlow.ReadFile.ExactCatalogLookupAwait",
                "EditFlow.ReadFile.ExactCatalogLookupActorBody",
                "EditFlow.ReadFile.ExplicitMaterialization",
                "EditFlow.ReadFile.GeneralLookupFallback",
                "EditFlow.ReadFile.ExternalFileFallback",
                "EditFlow.ReadFile.WorkspaceContentLoad",
                "EditFlow.ReadFile.SplitPreservingLineEndings",
                "EditFlow.ReadFile.BuildSlice",
                "EditFlow.ReadFile.AutoSelect.ResponseEnqueue",
                "EditFlow.ReadFile.AutoSelect.CanonicalQueueWait",
                "EditFlow.ReadFile.AutoSelect.CanonicalMutation",
                "EditFlow.ReadFile.AutoSelect.CanonicalStoredCommit",
                "EditFlow.ReadFile.AutoSelect.MirrorEnqueue",
                "EditFlow.ReadFile.AutoSelect.MirrorQueueWait",
                "EditFlow.ReadFile.AutoSelect.MirrorApply",
                "EditFlow.ReadFile.AutoSelect.DrainWait",
                "EditFlow.WorkspaceDurability.FlushWait",
                "EditFlow.WorkspaceDurability.AtomicWrite",
                "EditFlow.Search.CatalogSnapshot",
                "EditFlow.Search.DTOBuild",
                "EditFlow.Search.DTOBuild.RootRefSnapshotLookup",
                "EditFlow.Search.DTOBuild.DisplayResolverPreparation",
                "EditFlow.Search.DTOBuild.PathDisplayProjection",
                "EditFlow.Search.DTOBuild.CapAccounting",
                "EditFlow.Search.DTOBuild.Assembly",
                "EditFlow.Search.ProviderTotal",
                "EditFlow.Search.ProviderWorkspaceSearchAwait",
                "EditFlow.Search.ProviderAutoSelection",
                "EditFlow.Search.ProviderValueEncoding",
                "EditFlow.Search.AutoSelect.ShapeEligibility",
                "EditFlow.Search.AutoSelect.AgentEligibility",
                "EditFlow.Search.AutoSelect.Mutation",
                "EditFlow.Search.BroadAdmissionWait",
                "EditFlow.Search.BroadAdmissionLeaseHold",
                "EditFlow.Search.IngressFreshnessWait",
                "EditFlow.Search.ContentFreshnessValidation",
                "EditFlow.Search.ContentFreshnessValidation.StoreActorBody",
                "EditFlow.Search.ContentFreshnessValidation.RootActorBody",
                "EditFlow.Search.ContentScanTotal",
                "EditFlow.Search.ResultConstruction",
                "EditFlow.FileSystem.ContentLoadTotal",
                "EditFlow.FileSystem.ContentLoadActorBody",
                "EditFlow.FileSystem.ContentReadRequestPreparation",
                "EditFlow.FileSystem.ContentReadOffActorAwait",
                "EditFlow.FileSystem.ContentModificationDateLookup",
                "EditFlow.FileSystem.ContentReadWorkerPermitWait",
                "EditFlow.FileSystem.ContentReadWorkerBody",
                "EditFlow.Bootstrap.HandshakeIOQueueEnvelope",
                "EditFlow.Bootstrap.HandshakeIOBlockingRead",
                "EditFlow.Bootstrap.Admission",
                "EditFlow.Bootstrap.PostAcceptStartup"
            ] {
                XCTAssertTrue(perf.contains(stage), "Missing attribution stage: \(stage)")
            }
        }

        func testMCPCallDispatchDecompositionHooksRemainScopedAndResolvedToolDirect() throws {
            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            for hook in [
                "effectivePolicySnapshot",
                "routingSnapshot",
                "limiterWait",
                "windowRunResolution",
                "serviceToolLookup",
                "completionObservers"
            ] {
                XCTAssertTrue(manager.contains(hook), "Missing MCP call decomposition hook: \(hook)")
            }

            let limiterBegin = try XCTUnwrap(manager.range(of: "let limiterWaitState = EditFlowPerf.begin("))
            let limiterEnd = try XCTUnwrap(manager.range(of: "defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.limiterWait, limiterWaitState) }", range: limiterBegin.upperBound ..< manager.endIndex))
            let withPermit = try XCTUnwrap(manager.range(of: "return await self.withConnectionCallPermit(", range: limiterEnd.upperBound ..< manager.endIndex))
            XCTAssertLessThan(limiterBegin.lowerBound, limiterEnd.lowerBound)
            XCTAssertLessThan(limiterEnd.lowerBound, withPermit.lowerBound)

            let lookupBegin = try XCTUnwrap(manager.range(of: "let serviceToolLookupState = EditFlowPerf.begin("))
            let directInvocation = try XCTUnwrap(manager.range(of: "toolDef.callAsFunction(effectiveArgs)", range: lookupBegin.upperBound ..< manager.endIndex))
            XCTAssertLessThan(lookupBegin.lowerBound, directInvocation.lowerBound)
            XCTAssertTrue(manager.contains("EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookup, serviceToolLookupState)"))
            XCTAssertFalse(manager.contains("service.call("))
        }

        func testFileSearchReplyPathTelemetryAndSharedAutoSelectionLaneRemainOrdered() throws {
            let provider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            let toolClosureStart = try XCTUnwrap(provider.range(of: "EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerEntered)"))
            let executeStart = try XCTUnwrap(provider.range(of: "    private func executeFileSearch(", range: toolClosureStart.upperBound ..< provider.endIndex))
            let toolClosure = String(provider[toolClosureStart.lowerBound ..< executeStart.lowerBound])
            assertSourceOrder(
                in: toolClosure,
                hooks: [
                    "EditFlowPerf.Lifecycle.Search.providerEntered",
                    "EditFlowPerf.Stage.Search.providerTotal",
                    "executeFileSearch(args: args)",
                    "EditFlowPerf.Stage.Search.providerValueEncoding",
                    "Value(reply)",
                    "EditFlowPerf.Lifecycle.Search.providerResultReady"
                ]
            )

            let execute = String(provider[executeStart.lowerBound...])
            assertSourceOrder(
                in: execute,
                hooks: [
                    "EditFlowPerf.Stage.Search.providerWorkspaceSearchAwait",
                    "dependencies.workspaceSearch(",
                    "EditFlowPerf.Lifecycle.Search.providerWorkspaceSearchReturned",
                    "let dtoBuildState = EditFlowPerf.begin(",
                    "EditFlowPerf.Stage.Search.dtoRootRefSnapshotLookup",
                    "displayRootRefsSnapshot()",
                    "EditFlowPerf.Stage.Search.dtoDisplayResolverPreparation",
                    "makeCachedMCPDisplayPathResolver",
                    "endDTOBuildIfNeeded()",
                    "EditFlowPerf.Lifecycle.Search.providerDTOReady",
                    "EditFlowPerf.Stage.Search.providerAutoSelection",
                    "dependencies.enqueueFileSearchAutoSelection(mode, contextLines, reply, metadata)",
                    "EditFlowPerf.Lifecycle.Search.providerAutoSelectionReturned"
                ]
            )
            XCTAssertEqual(execute.components(separatedBy: "displayRootRefsSnapshot()").count - 1, 1)
            XCTAssertFalse(execute.contains("rootRefs(scope: .visibleWorkspace)"))
            XCTAssertFalse(execute.contains("rootRefs(scope: .allLoaded)"))

            let countOnlyStart = try XCTUnwrap(execute.range(of: "        if countOnly {"))
            let fullProjectionStart = try XCTUnwrap(execute.range(of: "        let (normalizedMatches, pathMatchesFull) = EditFlowPerf.measure(", range: countOnlyStart.upperBound ..< execute.endIndex))
            let countOnlyDTOBuild = String(execute[countOnlyStart.lowerBound ..< fullProjectionStart.lowerBound])
            assertSourceOrder(
                in: countOnlyDTOBuild,
                hooks: [
                    "EditFlowPerf.Stage.Search.dtoPathDisplayProjection",
                    "EditFlowPerf.Stage.Search.dtoCapAccounting",
                    "outcome: \"skippedCountOnly\"",
                    "EditFlowPerf.Stage.Search.dtoAssembly",
                    "endDTOBuildIfNeeded()",
                    "EditFlowPerf.Lifecycle.Search.providerDTOReady",
                    "EditFlowPerf.Lifecycle.Search.providerAutoSelectionReturned"
                ]
            )

            let fullDTOBuild = String(execute[fullProjectionStart.lowerBound...])
            assertSourceOrder(
                in: fullDTOBuild,
                hooks: [
                    "EditFlowPerf.Stage.Search.dtoPathDisplayProjection",
                    "let dtoCapAccountingState = EditFlowPerf.begin(",
                    "EditFlowPerf.Stage.Search.dtoCapAccounting",
                    "dtoCapAccountingState,",
                    "EditFlowPerf.Stage.Search.dtoAssembly",
                    "endDTOBuildIfNeeded()",
                    "EditFlowPerf.Lifecycle.Search.providerDTOReady",
                    "EditFlowPerf.Stage.Search.providerAutoSelection",
                    "dependencies.enqueueFileSearchAutoSelection(mode, contextLines, reply, metadata)",
                    "EditFlowPerf.Lifecycle.Search.providerAutoSelectionReturned"
                ]
            )
            for outcome in ["skippedWorktreeScopeUnavailable", "skippedBackpressure", "skippedPatternError", "skippedCountOnly"] {
                XCTAssertTrue(execute.contains("EditFlowPerf.Dimensions(outcome: \"\(outcome)\""), "Missing search auto-selection reply outcome: \(outcome)")
            }

            let server = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            let enqueueStart = try XCTUnwrap(server.range(of: "    private func enqueueFileSearchAutoSelection("))
            let enqueueEnd = try XCTUnwrap(server.range(of: "    private func applySelectionSlices(", range: enqueueStart.upperBound ..< server.endIndex))
            let enqueue = String(server[enqueueStart.lowerBound ..< enqueueEnd.lowerBound])
            assertSourceOrder(
                in: enqueue,
                hooks: [
                    "EditFlowPerf.Stage.Search.AutoSelect.shapeEligibility",
                    "AutoSliceSelection.shouldSliceFileSearch(mode: mode, contextLines: contextLines)",
                    "guard !reply.contentMatchGroups.isEmpty else",
                    "EditFlowPerf.Stage.Search.AutoSelect.agentEligibility",
                    "resolveTabContextSnapshot(",
                    "EditFlowPerf.Stage.Search.AutoSelect.mutation",
                    "readFileAutoSelectionCoordinator.enqueue(intent: .slices(entries: entries), for: key)"
                ]
            )
            XCTAssertFalse(server.contains("guard await shouldAutoSelectAgentSlices()"))
            XCTAssertFalse(provider.contains("maybeAutoSelectFileSearchSlices"))

            let perf = try source("Sources/RepoPrompt/Infrastructure/Diffing/EditFlowPerf.swift")
            XCTAssertTrue(perf.contains("var usesWorktreeProjection: Bool?"))
            XCTAssertTrue(perf.contains("usesWorktreeProjection: Bool? = nil"))
            XCTAssertTrue(perf.contains("self.usesWorktreeProjection = usesWorktreeProjection"))
            XCTAssertTrue(perf.contains("append(\"usesWorktreeProjection\", usesWorktreeProjection, to: &parts)"))
            XCTAssertTrue(provider.contains("let usesWorktreeProjection = lookupContext.bindingProjection != nil"))
            XCTAssertTrue(provider.contains("usesWorktreeProjection: usesWorktreeProjection"))
            for forbiddenDimension in ["path:", "pattern:", "payload:", "workspaceName:", "worktreeName:", "rootName:"] {
                XCTAssertFalse(provider.contains("EditFlowPerf.Dimensions(\(forbiddenDimension)"))
            }

            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            XCTAssertEqual(manager.components(separatedBy: "EditFlowPerf.Stage.MCPToolCall.completionObserverResultEncoding").count - 1, 5)
            XCTAssertEqual(manager.components(separatedBy: "EditFlowPerf.Stage.MCPToolCall.completionObserverCallbacks").count - 1, 5)
            XCTAssertEqual(manager.components(separatedBy: "EditFlowPerf.Lifecycle.MCPToolCall.formatResultReturned").count - 1, 2)
            XCTAssertFalse(manager.contains("Task {\n                                                            await self.fireToolCompletedObservers"))
        }

        func testSearchDTOBuildNestedRecorderCapturesOnlyCoarseSanitizedDimensions() {
            _ = startedCapture(label: "search-dto-build-decomposition", maxSamples: 100)
            let stages: [(StaticString, String)] = [
                (EditFlowPerf.Stage.Search.dtoRootRefSnapshotLookup, "EditFlow.Search.DTOBuild.RootRefSnapshotLookup"),
                (EditFlowPerf.Stage.Search.dtoDisplayResolverPreparation, "EditFlow.Search.DTOBuild.DisplayResolverPreparation"),
                (EditFlowPerf.Stage.Search.dtoPathDisplayProjection, "EditFlow.Search.DTOBuild.PathDisplayProjection"),
                (EditFlowPerf.Stage.Search.dtoCapAccounting, "EditFlow.Search.DTOBuild.CapAccounting"),
                (EditFlowPerf.Stage.Search.dtoAssembly, "EditFlow.Search.DTOBuild.Assembly")
            ]
            let dimensions = EditFlowPerf.Dimensions(
                outcome: "completed",
                scannedFileCount: 1630,
                contentMatchCount: 0,
                pathMatchCount: 80,
                usesWorktreeProjection: true,
                searchMode: "path",
                countOnly: false
            )
            for (stage, _) in stages {
                EditFlowPerf.measure(stage, dimensions) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, stages.count)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            XCTAssertEqual(Set(snapshot.stages.map(\.stageName)), Set(stages.map(\.1)))
            XCTAssertTrue(snapshot.stages.allSatisfy { $0.sampleCount == 1 })
            XCTAssertTrue(snapshot.stages.allSatisfy {
                $0.sanitizedDimensions == "outcome=completed scannedFileCount=1630 contentMatchCount=0 pathMatchCount=80 usesWorktreeProjection=true searchMode=path countOnly=false"
            })
            XCTAssertTrue(snapshot.stages.allSatisfy {
                !$0.sanitizedDimensions.contains("/") &&
                    !$0.sanitizedDimensions.contains("payload") &&
                    !$0.sanitizedDimensions.contains("pattern") &&
                    !$0.sanitizedDimensions.contains("workspace") &&
                    !$0.sanitizedDimensions.contains("root")
            })
        }

        func testMCPCallOuterEnvelopeHooksRemainNestedCloseOnceAndSanitized() throws {
            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            let handlerStart = try XCTUnwrap(manager.range(of: "let totalState = EditFlowPerf.begin("))
            let handlerEnd = try XCTUnwrap(manager.range(of: "/// Update the enabled state", range: handlerStart.upperBound ..< manager.endIndex))
            let handler = String(manager[handlerStart.lowerBound ..< handlerEnd.lowerBound])

            var searchStart = handler.startIndex
            for hook in [
                "let totalState = EditFlowPerf.begin(",
                "let preLimiterEnvelopeState = EditFlowPerf.begin(",
                "EditFlowPerf.Stage.MCPToolCall.normalizeArgs",
                "EditFlowPerf.Stage.MCPToolCall.limiterResolution",
                "endPreLimiterEnvelopeIfNeeded()",
                "EditFlowPerf.Stage.MCPToolCall.limiterEnvelope",
                "let limiterWaitState = EditFlowPerf.begin(",
                "defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.limiterWait, limiterWaitState) }",
                "await self.withConnectionCallPermit(",
                "EditFlowPerf.Stage.MCPToolCall.permitBodyEnvelope",
                "let permitPreDispatchEnvelopeState = EditFlowPerf.begin(",
                "EditFlowPerf.Stage.MCPToolCall.enabledStateSnapshot",
                "EditFlowPerf.Stage.MCPToolCall.windowRunResolution",
                "EditFlowPerf.Stage.MCPToolCall.observerCallbacks",
                "EditFlowPerf.Stage.MCPToolCall.ownershipPurposeResolution",
                "EditFlowPerf.Stage.MCPToolCall.toolCallRecording",
                "EditFlowPerf.Stage.MCPToolCall.runScopedTabRebindFallback",
                "EditFlowPerf.Stage.MCPToolCall.legacyTabBindingCompatibility",
                "let serviceToolLookupState = EditFlowPerf.begin(",
                "toolDef.callAsFunction(effectiveArgs)",
                "EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope"
            ] {
                let match = try XCTUnwrap(handler.range(of: hook, range: searchStart ..< handler.endIndex), "Missing or out-of-order outer-envelope hook: \(hook)")
                searchStart = match.upperBound
            }

            XCTAssertEqual(handler.components(separatedBy: "endPreLimiterEnvelopeIfNeeded()").count - 1, 3)
            XCTAssertEqual(handler.components(separatedBy: "endPermitPreDispatchEnvelopeIfNeeded()").count - 1, 4)
            XCTAssertEqual(handler.components(separatedBy: "outcome: \"success\"").count - 1, 5)
            XCTAssertEqual(handler.components(separatedBy: "outcome: \"dispatchError\"").count - 1, 4)
            XCTAssertEqual(handler.components(separatedBy: "outcome: \"toolNotFound\"").count - 1, 2)
            XCTAssertEqual(handler.components(separatedBy: "outcome: shouldAttemptRunScopedTabRebindFallback ? \"attempted\" : \"skipped\"").count - 1, 1)
            XCTAssertEqual(handler.components(separatedBy: "outcome: shouldAttemptLegacyTabBindingCompatibility ? \"attempted\" : \"skipped\"").count - 1, 1)
            XCTAssertTrue(handler.contains("toolDef.callAsFunction(effectiveArgs)"))
            XCTAssertFalse(handler.contains("service.call("))
        }

        func testRoutinePerCallRunScopedTabRebindFallbackSkipClassifierRemainsNarrowlyWired() throws {
            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            let handlerStart = try XCTUnwrap(manager.range(of: "let totalState = EditFlowPerf.begin("))
            let handlerEnd = try XCTUnwrap(manager.range(of: "/// Update the enabled state", range: handlerStart.upperBound ..< manager.endIndex))
            let handler = String(manager[handlerStart.lowerBound ..< handlerEnd.lowerBound])
            let decisionStart = try XCTUnwrap(handler.range(of: "let shouldAttemptRunScopedTabRebindFallback ="))
            let fallbackEnd = try XCTUnwrap(handler.range(of: "// Legacy compatibility: sticky tab binding via hidden _tabID", range: decisionStart.upperBound ..< handler.endIndex))
            let fallback = String(handler[decisionStart.lowerBound ..< fallbackEnd.lowerBound])
            let classifierCall = "Self.shouldSkipPerCallRunScopedTabRebindFallback(\n                                        toolName: toolName,\n                                        purpose: policy.purpose\n                                    )"

            XCTAssertEqual(handler.components(separatedBy: "Self.shouldSkipPerCallRunScopedTabRebindFallback(").count - 1, 1)
            XCTAssertTrue(fallback.contains("capturedTabID == nil"))
            XCTAssertTrue(fallback.contains("observerRunIDForCallbacksFinal != nil"))
            XCTAssertTrue(fallback.contains("chosenID != nil"))
            XCTAssertTrue(fallback.contains("&& !\(classifierCall)"))
            XCTAssertTrue(fallback.contains("outcome: shouldAttemptRunScopedTabRebindFallback ? \"attempted\" : \"skipped\""))
            XCTAssertTrue(fallback.contains("_ = await self.ensureTabBoundForRunIfPossible("))
            XCTAssertTrue(handler[fallbackEnd.lowerBound...].contains("EditFlowPerf.Stage.MCPToolCall.legacyTabBindingCompatibility"))
            XCTAssertTrue(handler.contains("toolDef.callAsFunction(effectiveArgs)"))
            XCTAssertFalse(handler.contains("service.call("))
        }

        func testRunToolDecompositionHooksRemainScopedAndProviderExecutionIsDimensioned() throws {
            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            let runToolStart = try XCTUnwrap(viewModel.range(of: "    private func runTool<T>("))
            let runToolEnd = try XCTUnwrap(
                viewModel.range(
                    of: "    var windowMCPTools: [Tool]",
                    range: runToolStart.upperBound ..< viewModel.endIndex
                )
            )
            let runTool = String(viewModel[runToolStart.lowerBound ..< runToolEnd.lowerBound])
            for hook in [
                "runToolSetup",
                "runToolRegistration",
                "runToolTimeoutEnvelope",
                "runToolCompletionCleanup"
            ] {
                XCTAssertTrue(runTool.contains(hook), "Missing runTool decomposition hook: \(hook)")
            }
            let providerExecution = try XCTUnwrap(runTool.range(of: "EditFlowPerf.Stage.MCPToolCall.providerExecution,"))
            let providerInvocation = runTool[providerExecution.lowerBound...].prefix(180)
            XCTAssertTrue(providerInvocation.contains("EditFlowPerf.Dimensions(toolName: name)"))
            XCTAssertFalse(runTool.contains("withThrowingTaskGroup(of: T.self)"))
            XCTAssertTrue(runTool.contains("withTaskCancellationHandler"))
            XCTAssertTrue(runTool.contains("MCPRunToolCleanupClaim"))
            XCTAssertFalse(runTool.contains("Task {\n                    await cleanupExecution"))
            XCTAssertTrue(runTool.contains("await cleanupExecution(outcome)"))
            XCTAssertFalse(runTool.contains("throw MCPError.internalError(\"tool cancelled by user\")"))
            XCTAssertTrue(runTool.contains("throw MCPToolExecutionCancelledError()"))
            XCTAssertEqual(runTool.components(separatedBy: "EditFlowPerf.Stage.MCPToolCall.runToolCompletionCleanup,").count - 1, 2)
        }

        func testNewReadDispatchStageRecorderCapturesToolDimensionAndFinishes() throws {
            _ = startedCapture(label: "dispatch-decomposition", maxSamples: 100)
            EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookup,
                EditFlowPerf.Dimensions(toolName: "read_file")
            ) {}

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            let aggregate = try XCTUnwrap(snapshot.stages.first)
            XCTAssertEqual(aggregate.stageName, "EditFlow.MCPToolCall.ServiceToolLookup")
            XCTAssertEqual(aggregate.sanitizedDimensions, "tool=read_file")
            XCTAssertEqual(aggregate.sampleCount, 1)
        }

        func testServiceToolLookupInnerAttributionRecorderUsesStaticEmptyDimensions() {
            _ = startedCapture(label: "service-tool-lookup-inner", maxSamples: 100)
            for stage in [
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupServiceToolsAwait,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupPublicWindowIDInjection,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupAppSettingsToolsBuild,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowRoutingToolsCacheActorBody,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsActorBodyTotal,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsMaterialization
            ] {
                EditFlowPerf.measure(stage) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, 7)
            XCTAssertEqual(
                Set(snapshot.stages.map(\.stageName)),
                Set([
                    "EditFlow.MCPToolCall.ServiceToolLookup.ServiceToolsAwait",
                    "EditFlow.MCPToolCall.ServiceToolLookup.ToolDefinitionScan",
                    "EditFlow.MCPToolCall.ServiceToolLookup.PublicWindowIDInjection",
                    "EditFlow.MCPToolCall.ServiceToolLookup.AppSettingsToolsBuild",
                    "EditFlow.MCPToolCall.ServiceToolLookup.WindowRoutingToolsCacheActorBody",
                    "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsActorBodyTotal",
                    "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsMaterialization"
                ])
            )
            XCTAssertTrue(snapshot.stages.allSatisfy(\.sanitizedDimensions.isEmpty))
            XCTAssertTrue(snapshot.stages.allSatisfy { $0.sampleCount == 1 })
        }

        func testServiceToolLookupInnerAttributionHooksRemainCompileGatedAndOwnMeasuredOperations() throws {
            func assertCompileGated(
                _ marker: Range<String.Index>,
                in source: String,
                context: String
            ) throws {
                let opening = try XCTUnwrap(
                    source.range(
                        of: "#if DEBUG || EDIT_FLOW_PERF",
                        options: .backwards,
                        range: source.startIndex ..< marker.lowerBound
                    ),
                    "Missing DEBUG gate before \(context)"
                )
                if let precedingClose = source.range(
                    of: "#endif",
                    options: .backwards,
                    range: source.startIndex ..< marker.lowerBound
                ) {
                    XCTAssertLessThan(precedingClose.lowerBound, opening.lowerBound, context)
                }
                _ = try XCTUnwrap(
                    source.range(of: "#endif", range: marker.upperBound ..< source.endIndex),
                    "Missing DEBUG gate close after \(context)"
                )
            }

            func scopedSource(
                from startMarker: String,
                to endMarker: String,
                in source: String,
                context: String
            ) throws -> String {
                let start = try XCTUnwrap(source.range(of: startMarker), "Missing scope start for \(context)")
                let end = try XCTUnwrap(
                    source.range(of: endMarker, range: start.upperBound ..< source.endIndex),
                    "Missing scope end for \(context)"
                )
                return String(source[start.lowerBound ..< end.lowerBound])
            }

            func measuredRegion(
                stage: String,
                in source: String,
                context: String
            ) throws -> String {
                let begin = try XCTUnwrap(
                    source.range(of: "EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.\(stage))"),
                    "Missing begin marker for \(context)"
                )
                let end = try XCTUnwrap(
                    source.range(
                        of: "EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.\(stage),",
                        range: begin.upperBound ..< source.endIndex
                    ),
                    "Missing end marker for \(context)"
                )
                try assertCompileGated(begin, in: source, context: "\(context) begin")
                try assertCompileGated(end, in: source, context: "\(context) end")
                return String(source[begin.lowerBound ..< end.upperBound])
            }

            func assertMeasured(
                stage: String,
                operation: String,
                in source: String,
                context: String
            ) throws {
                let region = try measuredRegion(stage: stage, in: source, context: context)
                XCTAssertTrue(region.contains(operation), "\(context) no longer owns \(operation)")
            }

            func assertDeferredMeasurement(
                stage: String,
                operation: String,
                in source: String,
                context: String
            ) throws {
                let begin = try XCTUnwrap(
                    source.range(of: "EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.\(stage))"),
                    "Missing begin marker for \(context)"
                )
                let end = try XCTUnwrap(
                    source.range(
                        of: "EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.\(stage),",
                        range: begin.upperBound ..< source.endIndex
                    ),
                    "Missing deferred end marker for \(context)"
                )
                let deferOpen = try XCTUnwrap(
                    source.range(of: "defer {", range: begin.upperBound ..< end.lowerBound),
                    "Missing defer ownership for \(context)"
                )
                let deferClose = try XCTUnwrap(
                    source.range(of: "}", range: end.upperBound ..< source.endIndex),
                    "Missing defer close for \(context)"
                )
                let ownedOperation = try XCTUnwrap(
                    source.range(of: operation, range: deferClose.upperBound ..< source.endIndex),
                    "Missing owned operation for \(context)"
                )
                try assertCompileGated(begin, in: source, context: "\(context) begin")
                try assertCompileGated(end, in: source, context: "\(context) end")
                XCTAssertLessThan(begin.lowerBound, deferOpen.lowerBound, context)
                XCTAssertLessThan(deferOpen.lowerBound, end.lowerBound, context)
                XCTAssertLessThan(end.lowerBound, deferClose.lowerBound, context)
                XCTAssertLessThan(deferClose.lowerBound, ownedOperation.lowerBound, context)
            }

            // Structural exception: recorder tests prove the stage inventory. These checks retain
            // only telemetry ownership and DEBUG-gating facts that runtime tests cannot observe.
            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            try assertMeasured(
                stage: "serviceToolLookupServiceToolsAwait",
                operation: "await service.tools",
                in: manager,
                context: "service-tools await"
            )
            try assertMeasured(
                stage: "serviceToolLookupToolDefinitionScan",
                operation: ".first(where:",
                in: manager,
                context: "tool-definition scan"
            )
            let injectionRegion = try measuredRegion(
                stage: "serviceToolLookupPublicWindowIDInjection",
                in: manager,
                context: "public window-ID injection"
            )
            let providerDestination = try XCTUnwrap(injectionRegion.range(of: "effectiveArgs ="))
            let providerInjection = try XCTUnwrap(
                injectionRegion.range(
                    of: "injectWindowIDIfNeeded(",
                    range: providerDestination.upperBound ..< injectionRegion.endIndex
                )
            )
            let formatterDestination = try XCTUnwrap(
                injectionRegion.range(
                    of: "effectiveArgsForFormatter =",
                    range: providerInjection.upperBound ..< injectionRegion.endIndex
                )
            )
            let formatterInjection = try XCTUnwrap(
                injectionRegion.range(
                    of: "injectWindowIDIfNeeded(",
                    range: formatterDestination.upperBound ..< injectionRegion.endIndex
                )
            )
            XCTAssertLessThan(providerDestination.lowerBound, providerInjection.lowerBound)
            XCTAssertLessThan(providerInjection.lowerBound, formatterDestination.lowerBound)
            XCTAssertLessThan(formatterDestination.lowerBound, formatterInjection.lowerBound)
            XCTAssertEqual(injectionRegion.components(separatedBy: "injectWindowIDIfNeeded(").count - 1, 2)

            let appSettings = try source("Sources/RepoPrompt/Infrastructure/MCP/AppSettingsMCPService.swift")
            let appSettingsTools = try scopedSource(
                from: "var tools: [Tool] {",
                to: "private func makeTools()",
                in: appSettings,
                context: "app-settings tools accessor"
            )
            try assertDeferredMeasurement(
                stage: "serviceToolLookupAppSettingsToolsBuild",
                operation: "makeTools()",
                in: appSettingsTools,
                context: "app-settings tool construction"
            )

            let routing = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowRoutingService.swift")
            let routingCacheGet = try scopedSource(
                from: "func get() -> [Tool] {",
                to: "private extension Array",
                in: routing,
                context: "window-routing cache getter"
            )
            try assertDeferredMeasurement(
                stage: "serviceToolLookupWindowRoutingToolsCacheActorBody",
                operation: "return tools",
                in: routingCacheGet,
                context: "window-routing cache actor body"
            )

            let catalog = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolCatalogService.swift")
            let catalogTools = try scopedSource(
                from: "var tools: [Tool] {",
                to: "func invalidateToolsCache()",
                in: catalog,
                context: "window-catalog tools accessor"
            )
            try assertDeferredMeasurement(
                stage: "serviceToolLookupWindowCatalogToolsActorBodyTotal",
                operation: "if let toolsCache",
                in: catalogTools,
                context: "window-catalog total actor body"
            )
            try assertDeferredMeasurement(
                stage: "serviceToolLookupWindowCatalogToolsMaterialization",
                operation: "providersByGroup",
                in: catalogTools,
                context: "window-catalog materialization"
            )
        }

        func testMCPWindowToolCatalogLifecycleAttributionRecorderUsesStaticEmptyDimensions() {
            _ = startedCapture(label: "window-tool-catalog-lifecycle", maxSamples: 100)
            for stage in [
                EditFlowPerf.Stage.MCPWindowToolCatalog.construction,
                EditFlowPerf.Stage.MCPWindowToolCatalog.invalidateToolsCache,
                EditFlowPerf.Stage.MCPWindowToolCatalog.invalidationToolSummariesChange,
                EditFlowPerf.Stage.MCPWindowToolCatalog.invalidationToolRegistrationUpdate,
                EditFlowPerf.Stage.MCPWindowToolCatalog.registrationUpdateWindowToolsEnabledDidSet,
                EditFlowPerf.Stage.MCPWindowToolCatalog.registrationUpdateAgentBootstrap,
                EditFlowPerf.Stage.MCPWindowToolCatalog.readinessWarmAccess,
                EditFlowPerf.Stage.MCPWindowToolCatalog.serviceRegistryToolsPublication,
                EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable
            ] {
                EditFlowPerf.measure(stage) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, 9)
            XCTAssertEqual(
                Set(snapshot.stages.map(\.stageName)),
                Set([
                    "EditFlow.MCPWindowToolCatalog.Construction",
                    "EditFlow.MCPWindowToolCatalog.InvalidateToolsCache",
                    "EditFlow.MCPWindowToolCatalog.Invalidation.ToolSummariesChange",
                    "EditFlow.MCPWindowToolCatalog.Invalidation.ToolRegistrationUpdate",
                    "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.WindowToolsEnabledDidSet",
                    "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.AgentBootstrap",
                    "EditFlow.MCPWindowToolCatalog.ReadinessWarmAccess",
                    "EditFlow.MCPWindowToolCatalog.ServiceRegistryToolsPublication",
                    "EditFlow.MCPWindowToolCatalog.CodexTurnMCPServerEnable"
                ])
            )
            XCTAssertTrue(snapshot.stages.allSatisfy(\.sanitizedDimensions.isEmpty))
            XCTAssertTrue(snapshot.stages.allSatisfy { $0.sampleCount == 1 })
        }

        func testMCPWindowToolCatalogLifecycleHooksRemainCompileGatedOwnedAndReleaseEquivalent() throws {
            let catalog = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolCatalogService.swift")
            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            let readiness = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPToolCatalogReadiness.swift")
            let registry = try source("Sources/RepoPrompt/Infrastructure/MCP/ServiceRegistry.swift")
            let codexRunner = try source("Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/CodexIntegratedAgentModeRunner.swift")

            XCTAssertEqual(viewModel.components(separatedBy: "MCPWindowToolCatalogService(").count - 1, 1)
            XCTAssertTrue(viewModel.contains("private lazy var windowToolCatalogService = MCPWindowToolCatalogService("))
            XCTAssertEqual(catalog.components(separatedBy: "toolsCache = nil").count - 1, 1)
            XCTAssertEqual(catalog.components(separatedBy: "MCPWindowToolCatalog.construction").count - 1, 2)
            XCTAssertEqual(catalog.components(separatedBy: "MCPWindowToolCatalog.invalidateToolsCache").count - 1, 2)
            XCTAssertTrue(catalog.contains("self.windowID = windowID\n        self.providers = providers"))

            XCTAssertEqual(viewModel.components(separatedBy: "MCPWindowToolCatalog.invalidationToolSummariesChange").count - 1, 2)
            XCTAssertEqual(viewModel.components(separatedBy: "MCPWindowToolCatalog.invalidationToolRegistrationUpdate").count - 1, 2)
            XCTAssertEqual(viewModel.components(separatedBy: "MCPWindowToolCatalog.registrationUpdateWindowToolsEnabledDidSet").count - 1, 2)
            XCTAssertEqual(viewModel.components(separatedBy: "MCPWindowToolCatalog.registrationUpdateAgentBootstrap").count - 1, 2)
            XCTAssertEqual(viewModel.components(separatedBy: "self?.invalidateToolsCache()").count - 1, 1)
            XCTAssertEqual(viewModel.components(separatedBy: "windowToolCatalogService.invalidateToolsCache()").count - 1, 1)
            XCTAssertTrue(viewModel.contains("#else\n                Task { await updateToolRegistration() }"))
            XCTAssertEqual(viewModel.components(separatedBy: "await updateToolRegistration()").count - 1, 2)
            XCTAssertTrue(viewModel.contains("private func updateToolRegistration(invalidateCatalogBeforeUpdate: Bool = true) async {"))
            XCTAssertTrue(viewModel.contains("let invalidateCatalogBeforeUpdate = !windowToolsEnabled\n            || !ServiceRegistry.services.contains { service in\n                (service as AnyObject) === (windowToolCatalogService as AnyObject)\n            }"))
            XCTAssertEqual(viewModel.components(separatedBy: "await updateToolRegistration(invalidateCatalogBeforeUpdate:").count - 1, 1)
            XCTAssertTrue(viewModel.contains("await updateToolRegistration(invalidateCatalogBeforeUpdate: invalidateCatalogBeforeUpdate)\n        #if DEBUG || EDIT_FLOW_PERF\n            EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.registrationUpdateAgentBootstrap"))

            let bootstrapStart = try XCTUnwrap(viewModel.range(of: "func ensureServerReadyForAgentBootstrap() async {"))
            let predicate = try XCTUnwrap(viewModel.range(of: "let invalidateCatalogBeforeUpdate = !windowToolsEnabled", range: bootstrapStart.upperBound ..< viewModel.endIndex))
            let bootstrapEnable = try XCTUnwrap(viewModel.range(of: "if !windowToolsEnabled {\n            windowToolsEnabled = true\n        }", range: predicate.upperBound ..< viewModel.endIndex))
            let update = try XCTUnwrap(viewModel.range(of: "await updateToolRegistration(invalidateCatalogBeforeUpdate: invalidateCatalogBeforeUpdate)", range: bootstrapEnable.upperBound ..< viewModel.endIndex))
            let bootstrapEnd = try XCTUnwrap(viewModel.range(of: "    /// Disables tools for this window.", range: update.upperBound ..< viewModel.endIndex))
            let bootstrap = viewModel[bootstrapStart.lowerBound ..< bootstrapEnd.lowerBound]
            XCTAssertLessThan(predicate.lowerBound, bootstrapEnable.lowerBound)
            XCTAssertLessThan(bootstrapEnable.lowerBound, update.lowerBound)
            XCTAssertFalse(bootstrap.contains("return"))

            let helperStart = try XCTUnwrap(viewModel.range(of: "private func updateToolRegistration(invalidateCatalogBeforeUpdate: Bool = true) async {"))
            let policy = try XCTUnwrap(viewModel.range(of: "if invalidateCatalogBeforeUpdate {", range: helperStart.upperBound ..< viewModel.endIndex))
            let invalidate = try XCTUnwrap(viewModel.range(of: "invalidateToolsCache()", range: policy.upperBound ..< viewModel.endIndex))
            let enabled = try XCTUnwrap(viewModel.range(of: "if windowToolsEnabled {", range: invalidate.upperBound ..< viewModel.endIndex))
            let register = try XCTUnwrap(viewModel.range(of: "ServiceRegistry.register(windowToolCatalogService)", range: enabled.upperBound ..< viewModel.endIndex))
            let join = try XCTUnwrap(viewModel.range(of: "try await service.join(windowID: windowID)", range: register.upperBound ..< viewModel.endIndex))
            let enabledRefresh = try XCTUnwrap(viewModel.range(of: "await service.refreshState()", range: join.upperBound ..< viewModel.endIndex))
            let unregister = try XCTUnwrap(viewModel.range(of: "ServiceRegistry.unregister(windowToolCatalogService)", range: enabledRefresh.upperBound ..< viewModel.endIndex))
            let leave = try XCTUnwrap(viewModel.range(of: "await service.leave(windowID: windowID)", range: unregister.upperBound ..< viewModel.endIndex))
            let disabledRefresh = try XCTUnwrap(viewModel.range(of: "await service.refreshState()", range: leave.upperBound ..< viewModel.endIndex))
            XCTAssertLessThan(policy.lowerBound, invalidate.lowerBound)
            XCTAssertLessThan(invalidate.lowerBound, enabled.lowerBound)
            XCTAssertLessThan(enabled.lowerBound, register.lowerBound)
            XCTAssertLessThan(register.lowerBound, join.lowerBound)
            XCTAssertLessThan(join.lowerBound, enabledRefresh.lowerBound)
            XCTAssertLessThan(enabledRefresh.lowerBound, unregister.lowerBound)
            XCTAssertLessThan(unregister.lowerBound, leave.lowerBound)
            XCTAssertLessThan(leave.lowerBound, disabledRefresh.lowerBound)

            XCTAssertEqual(readiness.components(separatedBy: "MCPWindowToolCatalog.readinessWarmAccess").count - 1, 2)
            XCTAssertTrue(readiness.contains("_ = await mcpServer.windowMCPTools"))

            let dedupe = try XCTUnwrap(registry.range(of: "if _services.contains(where:"))
            let append = try XCTUnwrap(registry.range(of: "_services.append(service)", range: dedupe.upperBound ..< registry.endIndex))
            let publication = try XCTUnwrap(registry.range(of: "MCPWindowToolCatalog.serviceRegistryToolsPublication", range: append.upperBound ..< registry.endIndex))
            let broadcast = try XCTUnwrap(registry.range(of: "await ServerNetworkManager.shared.broadcastToolListChanged()", range: publication.upperBound ..< registry.endIndex))
            XCTAssertLessThan(dedupe.lowerBound, append.lowerBound)
            XCTAssertLessThan(append.lowerBound, publication.lowerBound)
            XCTAssertLessThan(publication.lowerBound, broadcast.lowerBound)
            XCTAssertEqual(registry.components(separatedBy: "MCPWindowToolCatalog.serviceRegistryToolsPublication").count - 1, 1)
            XCTAssertTrue(registry.contains("#else\n                await ToolAvailabilityStore.shared.registerTools(service.tools)"))

            let enable = try XCTUnwrap(codexRunner.range(of: "await mcpServerEnabler()"))
            let send = try XCTUnwrap(codexRunner.range(of: "let outcome = await codexCoordinator.sendCodexNativeMessage(", range: enable.upperBound ..< codexRunner.endIndex))
            XCTAssertLessThan(enable.lowerBound, send.lowerBound)
            XCTAssertEqual(codexRunner.components(separatedBy: "MCPWindowToolCatalog.codexTurnMCPServerEnable").count - 1, 2)
        }

        func testOuterEnvelopeRecorderCapturesCombinedToolAndSanitizedOutcomes() throws {
            _ = startedCapture(label: "outer-envelope", maxSamples: 100)
            EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.preLimiterEnvelope,
                EditFlowPerf.Dimensions(toolName: "read_file")
            ) {}
            for outcome in ["attempted", "skipped"] {
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.runScopedTabRebindFallback,
                    EditFlowPerf.Dimensions(toolName: "read_file", outcome: outcome)
                ) {}
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.legacyTabBindingCompatibility,
                    EditFlowPerf.Dimensions(toolName: "read_file", outcome: outcome)
                ) {}
            }
            for outcome in ["success", "dispatchError", "toolNotFound"] {
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                    EditFlowPerf.Dimensions(toolName: "read_file", outcome: outcome)
                ) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, 8)

            let plain = try XCTUnwrap(snapshot.stages.first { $0.stageName == "EditFlow.MCPToolCall.PreLimiterEnvelope" })
            XCTAssertEqual(plain.sanitizedDimensions, "tool=read_file")
            XCTAssertEqual(plain.sampleCount, 1)

            let expectedCombinedDimensions = [
                "tool=read_file outcome=attempted",
                "tool=read_file outcome=dispatchError",
                "tool=read_file outcome=skipped",
                "tool=read_file outcome=success",
                "tool=read_file outcome=toolNotFound"
            ]
            let combinedRows = snapshot.stages.filter { $0.stageName != "EditFlow.MCPToolCall.PreLimiterEnvelope" }
            XCTAssertTrue(combinedRows.allSatisfy { $0.sampleCount == 1 })
            XCTAssertTrue(combinedRows.allSatisfy { expectedCombinedDimensions.contains($0.sanitizedDimensions) })
            XCTAssertTrue(combinedRows.allSatisfy { !$0.sanitizedDimensions.contains("/") && !$0.sanitizedDimensions.contains("payload") })
            XCTAssertEqual(
                Set(combinedRows.map(\.sanitizedDimensions)),
                Set(expectedCombinedDimensions)
            )
        }

        func testReadFileProviderHooksRemainScopedOrderedAndConditional() throws {
            let provider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            let methodStart = try XCTUnwrap(provider.range(of: "private func executeReadFile(args:"))
            let nextMethod = try XCTUnwrap(provider.range(of: "private func fileSearchTool()", range: methodStart.upperBound ..< provider.endIndex))
            let method = String(provider[methodStart.lowerBound ..< nextMethod.lowerBound])

            var searchStart = method.startIndex
            for hook in [
                "providerTotal",
                "providerArgumentParsing",
                "providerRequestMetadata",
                "providerLookupContextResolution",
                "providerPathTranslation",
                "providerReadEnvelope",
                "providerReplyProjection",
                "providerAutoSelect",
                "providerValueEncoding"
            ] {
                let match = try XCTUnwrap(method.range(of: hook, range: searchStart ..< method.endIndex), "Missing or out-of-order provider hook: \(hook)")
                searchStart = match.upperBound
            }

            XCTAssertTrue(method.contains("EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.ReadFile.providerEntered)"))
            XCTAssertTrue(method.contains("let providerTotalState = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.providerTotal)"))
            XCTAssertTrue(method.contains("defer { EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.providerTotal, providerTotalState) }"))

            let readEnvelope = try XCTUnwrap(method.range(of: "EditFlowPerf.Stage.ReadFile.providerReadEnvelope"))
            let readCall = try XCTUnwrap(method.range(of: "dependencies.readFile", range: readEnvelope.upperBound ..< method.endIndex))
            XCTAssertLessThan(readEnvelope.lowerBound, readCall.lowerBound)

            let autoSelect = try XCTUnwrap(method.range(of: "EditFlowPerf.Stage.ReadFile.providerAutoSelect"))
            let conditional = try XCTUnwrap(method.range(of: "if readResult.shouldAutoSelect", range: autoSelect.upperBound ..< method.endIndex))
            let autoSelectCall = try XCTUnwrap(method.range(of: "await dependencies.enqueueReadFileAutoSelection", range: conditional.upperBound ..< method.endIndex))
            XCTAssertLessThan(autoSelect.lowerBound, conditional.lowerBound)
            XCTAssertLessThan(conditional.lowerBound, autoSelectCall.lowerBound)

            let valueEncoding = try XCTUnwrap(method.range(of: "EditFlowPerf.Stage.ReadFile.providerValueEncoding"))
            let valueCall = try XCTUnwrap(method.range(of: "MCPProviderProjectionWorker.encode(", range: valueEncoding.upperBound ..< method.endIndex))
            XCTAssertLessThan(valueEncoding.lowerBound, valueCall.lowerBound)
        }

        func testProviderReadRecorderCapturesTotalAndSanitizedAutoSelectOutcomes() throws {
            _ = startedCapture(label: "provider-read-decomposition", maxSamples: 100)
            EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerTotal) {}
            EditFlowPerf.measure(
                EditFlowPerf.Stage.ReadFile.providerAutoSelect,
                EditFlowPerf.Dimensions(outcome: "attempted")
            ) {}
            EditFlowPerf.measure(
                EditFlowPerf.Stage.ReadFile.providerAutoSelect,
                EditFlowPerf.Dimensions(outcome: "skipped")
            ) {}

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, 3)

            let total = try XCTUnwrap(snapshot.stages.first { $0.stageName == "EditFlow.ReadFile.ProviderTotal" })
            XCTAssertEqual(total.sanitizedDimensions, "")
            XCTAssertEqual(total.sampleCount, 1)

            let autoSelectRows = snapshot.stages.filter { $0.stageName == "EditFlow.ReadFile.ProviderAutoSelect" }
            XCTAssertEqual(autoSelectRows.map(\.sanitizedDimensions).sorted(), ["outcome=attempted", "outcome=skipped"])
            XCTAssertTrue(autoSelectRows.allSatisfy { $0.sampleCount == 1 })
            XCTAssertTrue(autoSelectRows.allSatisfy { !$0.sanitizedDimensions.contains("/") && !$0.sanitizedDimensions.contains("payload") })
        }

        func testProviderAutoSelectDecompositionStagesRemainStaticCompleteAndScoped() throws {
            let perf = try source("Sources/RepoPrompt/Infrastructure/Diffing/EditFlowPerf.swift")
            for stage in [
                "EditFlow.ReadFile.AutoSelect.Total",
                "EditFlow.ReadFile.AutoSelect.EligibilityResolution",
                "EditFlow.ReadFile.AutoSelect.SelectionProjection",
                "EditFlow.ReadFile.AutoSelect.FullFlowTotal",
                "EditFlow.ReadFile.AutoSelect.FullRequestMetadata",
                "EditFlow.ReadFile.AutoSelect.FullLookupContext",
                "EditFlow.ReadFile.AutoSelect.FullSnapshotResolution",
                "EditFlow.ReadFile.AutoSelect.StructuralAddTotal",
                "EditFlow.ReadFile.AutoSelect.CandidateResolutionTotal",
                "EditFlow.ReadFile.AutoSelect.StructuralMerge",
                "EditFlow.ReadFile.AutoSelect.AutoCodemapRecomputeTotal",
                "EditFlow.ReadFile.AutoSelect.SelectedFileLookup",
                "EditFlow.ReadFile.AutoSelect.CodemapAPILoad",
                "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.ActorBodyTotal",
                "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.StateSnapshot",
                "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.Materialization",
                "EditFlow.ReadFile.AutoSelect.ReferencedPathResolution",
                "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter",
                "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter.PathGrouping",
                "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter.SelectedRecordProjection",
                "EditFlow.ReadFile.AutoSelect.AutoReferencedAPIComputation",
                "EditFlow.ReadFile.AutoSelect.FullSliceClearing",
                "EditFlow.ReadFile.AutoSelect.FinalSelectionEquality",
                "EditFlow.ReadFile.AutoSelect.Persistence",
                "EditFlow.ReadFile.AutoSelect.ResponseEnqueue",
                "EditFlow.ReadFile.AutoSelect.CanonicalQueueWait",
                "EditFlow.ReadFile.AutoSelect.CanonicalMutation",
                "EditFlow.ReadFile.AutoSelect.CanonicalStoredCommit",
                "EditFlow.ReadFile.AutoSelect.MirrorEnqueue",
                "EditFlow.ReadFile.AutoSelect.MirrorQueueWait",
                "EditFlow.ReadFile.AutoSelect.MirrorApply",
                "EditFlow.ReadFile.AutoSelect.DrainWait",
                "EditFlow.ReadFile.AutoSelect.SliceFlowTotal"
            ] {
                XCTAssertTrue(perf.contains(stage), "Missing nested auto-select attribution stage: \(stage)")
            }

            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            for hook in [
                "total",
                "eligibilityResolution",
                "selectionProjection",
                "fullFlowTotal",
                "fullRequestMetadata",
                "fullLookupContext",
                "fullSnapshotResolution",
                "structuralAddTotal",
                "fullSliceClearing",
                "finalSelectionEquality",
                "persistence",
                "sliceFlowTotal"
            ] {
                XCTAssertTrue(viewModel.contains("Stage.ReadFile.AutoSelect.\(hook)"), "Missing view-model nested auto-select hook: \(hook)")
            }

            let mutations = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionMutationService.swift")
            for hook in [
                "candidateResolutionTotal",
                "structuralMerge",
                "autoCodemapRecomputeTotal",
                "selectedFileLookup",
                "codemapAPILoad",
                "referencedPathResolution"
            ] {
                XCTAssertTrue(mutations.contains("Stage.ReadFile.AutoSelect.\(hook)"), "Missing mutation-service nested auto-select hook: \(hook)")
            }

            let extractor = try source("Sources/RepoPrompt/Features/CodeMap/CodeMapExtractor.swift")
            let workspaceOverloadStart = try XCTUnwrap(extractor.range(of: "static func resolveReferencedFilePaths(\n        from selectedFiles: [WorkspaceFileRecord]"))
            let workspaceOverloadEnd = try XCTUnwrap(extractor.range(of: "/// Returns the list of file paths", range: workspaceOverloadStart.upperBound ..< extractor.endIndex))
            let workspaceOverload = String(extractor[workspaceOverloadStart.lowerBound ..< workspaceOverloadEnd.lowerBound])
            XCTAssertTrue(workspaceOverload.contains("Stage.ReadFile.AutoSelect.acceptedFileAPIFilter"))
            XCTAssertTrue(workspaceOverload.contains("Stage.ReadFile.AutoSelect.autoReferencedAPIComputation"))

            let fileViewModelOverloadStart = try XCTUnwrap(extractor.range(of: "static func resolveReferencedFilePaths(\n        from selectedFiles: [FileViewModel]"))
            let fileViewModelOverload = String(extractor[fileViewModelOverloadStart.lowerBound ..< workspaceOverloadStart.lowerBound])
            XCTAssertFalse(fileViewModelOverload.contains("Stage.ReadFile.AutoSelect"))

            let provider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            let diagnostics = try diagnosticsSource()
            for forbiddenOwner in [provider, manager, diagnostics] {
                XCTAssertFalse(forbiddenOwner.contains("Stage.ReadFile.AutoSelect"))
                XCTAssertFalse(forbiddenOwner.contains("EditFlow.ReadFile.AutoSelect."))
            }
        }

        func testProviderAutoSelectDecompositionKeepsAwaitOrderingAndCoarseOutcomes() throws {
            let provider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            let replyProjection = try XCTUnwrap(provider.range(of: "EditFlowPerf.Stage.ReadFile.providerReplyProjection"))
            let dependencyAwait = try XCTUnwrap(provider.range(of: "await dependencies.enqueueReadFileAutoSelection", range: replyProjection.upperBound ..< provider.endIndex))
            let valueEncoding = try XCTUnwrap(provider.range(of: "EditFlowPerf.Stage.ReadFile.providerValueEncoding", range: dependencyAwait.upperBound ..< provider.endIndex))
            XCTAssertLessThan(replyProjection.lowerBound, dependencyAwait.lowerBound)
            XCTAssertLessThan(dependencyAwait.lowerBound, valueEncoding.lowerBound)

            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            let mutations = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionMutationService.swift")
            let nestedSources = viewModel + mutations
            for outcome in [
                "eligible",
                "ineligible",
                "missing",
                "full",
                "slice",
                "changed",
                "unchanged",
                "attempted",
                "skipped",
                "error"
            ] {
                XCTAssertTrue(nestedSources.contains("\"\(outcome)\""), "Missing approved nested outcome: \(outcome)")
            }
            XCTAssertFalse(nestedSources.contains("EditFlowPerf.Dimensions(path:"))
            XCTAssertFalse(nestedSources.contains("EditFlowPerf.Dimensions(pattern:"))
            XCTAssertFalse(nestedSources.contains("EditFlowPerf.Dimensions(payload:"))
        }

        func testProviderAutoSelectNestedRecorderCapturesRepresentativeSanitizedOutcomes() {
            _ = startedCapture(label: "provider-auto-select-decomposition", maxSamples: 100)
            let samples: [(StaticString, String)] = [
                (EditFlowPerf.Stage.ReadFile.AutoSelect.eligibilityResolution, "eligible"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.selectionProjection, "full"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.fullFlowTotal, "unchanged"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.autoCodemapRecomputeTotal, "attempted"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.finalSelectionEquality, "unchanged"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.persistence, "skipped")
            ]
            for (stage, outcome) in samples {
                EditFlowPerf.measure(stage, EditFlowPerf.Dimensions(outcome: outcome)) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, samples.count)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            XCTAssertTrue(snapshot.stages.allSatisfy { $0.sampleCount == 1 })
            XCTAssertEqual(
                Set(snapshot.stages.map(\.sanitizedDimensions)),
                Set(samples.map { "outcome=\($0.1)" })
            )
            XCTAssertTrue(snapshot.stages.allSatisfy {
                !$0.sanitizedDimensions.contains("/") &&
                    !$0.sanitizedDimensions.contains("payload") &&
                    !$0.sanitizedDimensions.contains("namespace")
            })
        }

        func testReadFileAutoSelectionQueueAndDurabilityHooksRemainOwnedByCoordinatorAndDiskWriter() throws {
            let coordinator = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPReadFileAutoSelectionCoordinator.swift")
            for hook in [
                "responseEnqueue",
                "canonicalQueueWait",
                "canonicalMutation",
                "mirrorEnqueue",
                "mirrorQueueWait",
                "mirrorApply",
                "drainWait"
            ] {
                XCTAssertTrue(coordinator.contains("Stage.ReadFile.AutoSelect.\(hook)"), "Missing coordinator attribution hook: \(hook)")
            }
            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+TabContext.swift")
            XCTAssertTrue(viewModel.contains("Stage.ReadFile.AutoSelect.canonicalStoredCommit"))

            let workspaceManager = try source("Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift")
            XCTAssertTrue(workspaceManager.contains("Stage.WorkspaceDurability.flushWait"))
            XCTAssertTrue(workspaceManager.contains("Stage.WorkspaceDurability.atomicWrite"))
            XCTAssertFalse(coordinator.contains("EditFlowPerf.Dimensions(path:"))
            XCTAssertFalse(workspaceManager.contains("EditFlowPerf.Dimensions(path:"))
        }

        func testAgentExportPopoverResolvesSlicesAndCodemapsWithBatchedLookups() throws {
            let resolver = try source("Sources/RepoPrompt/Features/AgentMode/Services/AgentContextExportResolver.swift")
            let resolveStart = try XCTUnwrap(resolver.range(of: "    private static func resolveRows("))
            let resolveEnd = try XCTUnwrap(
                resolver.range(
                    of: "    private static func row(",
                    range: resolveStart.upperBound ..< resolver.endIndex
                )
            )
            let resolveRows = String(resolver[resolveStart.lowerBound ..< resolveEnd.lowerBound])

            XCTAssertTrue(resolveRows.contains("await store.lookupPaths(sliceLookupRequests)"))
            XCTAssertTrue(resolveRows.contains("await store.lookupPaths(codemapLookupRequests)"))
            XCTAssertFalse(resolveRows.contains("await store.lookupPath(path, profile: profile, rootScope: rootScope)"))
        }

        func testCanonicalSelectionRebaseRemainsInsideDeferredAutoSelectionWorker() throws {
            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            let applyStart = try XCTUnwrap(viewModel.range(of: "    private func applyReadFileAutoSelectionBatch("))
            let applyEnd = try XCTUnwrap(
                viewModel.range(
                    of: "    @MainActor\n    func readFileAutoSelectionContext(",
                    range: applyStart.upperBound ..< viewModel.endIndex
                )
            )
            let applyMethod = String(viewModel[applyStart.lowerBound ..< applyEnd.lowerBound])
            XCTAssertTrue(applyMethod.contains("workspaceManager?.composeTab("))

            let readEnqueueStart = try XCTUnwrap(viewModel.range(of: "    private func enqueueReadFileAutoSelection("))
            let readEnqueueEnd = try XCTUnwrap(
                viewModel.range(
                    of: "    @MainActor\n    func drainReadFileAutoSelection(",
                    range: readEnqueueStart.upperBound ..< viewModel.endIndex
                )
            )
            let readEnqueue = String(viewModel[readEnqueueStart.lowerBound ..< readEnqueueEnd.lowerBound])
            XCTAssertFalse(readEnqueue.contains("composeTab("))

            let searchEnqueueStart = try XCTUnwrap(viewModel.range(of: "    private func enqueueFileSearchAutoSelection("))
            let searchEnqueueEnd = try XCTUnwrap(
                viewModel.range(
                    of: "    private func applySelectionSlices(",
                    range: searchEnqueueStart.upperBound ..< viewModel.endIndex
                )
            )
            let searchEnqueue = String(viewModel[searchEnqueueStart.lowerBound ..< searchEnqueueEnd.lowerBound])
            XCTAssertFalse(searchEnqueue.contains("composeTab("))

            let coordinator = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPReadFileAutoSelectionCoordinator.swift")
            let workerStart = try XCTUnwrap(coordinator.range(of: "    private func runCanonicalWorker("))
            let workerEnd = try XCTUnwrap(
                coordinator.range(
                    of: "    private func completeCanonicalBatch(",
                    range: workerStart.upperBound ..< coordinator.endIndex
                )
            )
            let worker = String(coordinator[workerStart.lowerBound ..< workerEnd.lowerBound])
            XCTAssertTrue(worker.contains("await applyCanonical(key, queued.batch)"))
        }

        func testReadFileAutoSelectionQueueRecorderCapturesSanitizedStagesAndLifecycle() throws {
            _ = startedCapture(label: "read-file-auto-selection-queue", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            let samples: [StaticString] = [
                EditFlowPerf.Stage.ReadFile.AutoSelect.responseEnqueue,
                EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalQueueWait,
                EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalMutation,
                EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalStoredCommit,
                EditFlowPerf.Stage.ReadFile.AutoSelect.mirrorEnqueue,
                EditFlowPerf.Stage.ReadFile.AutoSelect.mirrorQueueWait,
                EditFlowPerf.Stage.ReadFile.AutoSelect.mirrorApply,
                EditFlowPerf.Stage.ReadFile.AutoSelect.drainWait,
                EditFlowPerf.Stage.WorkspaceDurability.flushWait,
                EditFlowPerf.Stage.WorkspaceDurability.atomicWrite
            ]
            for stage in samples {
                EditFlowPerf.measure(stage, EditFlowPerf.Dimensions(outcome: "success", queueDepth: 1)) {}
            }
            for event in [
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.enqueueAccepted,
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.canonicalApplyBegan,
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.mirrorScheduled,
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.mirrorApplyEnded,
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.drainEnded,
                EditFlowPerf.Lifecycle.WorkspaceDurability.flushEnded,
                EditFlowPerf.Lifecycle.WorkspaceDurability.writeEnded
            ] {
                EditFlowPerf.lifecycleEvent(event, correlation: correlation, EditFlowPerf.Dimensions(outcome: "success"))
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.retainedSampleCount, samples.count)
            XCTAssertEqual(snapshot.retainedLifecycleEventCount, 7)
            XCTAssertTrue(snapshot.stages.allSatisfy { !$0.sanitizedDimensions.contains("/") })
            XCTAssertTrue(snapshot.lifecycleEvents.allSatisfy { !$0.sanitizedDimensions.contains("/") })
        }

        func testAcceptedFileAPIFilterInnerAttributionRemainsBehaviorNeutralScopedAndOrdered() throws {
            let extractor = try source("Sources/RepoPrompt/Features/CodeMap/CodeMapExtractor.swift")
            let helperStart = try XCTUnwrap(extractor.range(of: "    private static func acceptedFileAPIs(from files: [WorkspaceFileRecord], allFileAPIs: [FileAPI]) -> [FileAPI] {"))
            let helperEnd = try XCTUnwrap(extractor.range(of: "    private static func isUnderCurrentRoots", range: helperStart.upperBound ..< extractor.endIndex))
            let helper = String(extractor[helperStart.lowerBound ..< helperEnd.lowerBound])

            var searchStart = helper.startIndex
            for hook in [
                "guard !files.isEmpty, !allFileAPIs.isEmpty else { return [] }",
                "#if DEBUG || EDIT_FLOW_PERF",
                "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.pathGrouping)",
                "let apisByPath = Dictionary(grouping: allFileAPIs, by: { standardizedAPIFilePath($0) })",
                "EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.pathGrouping, pathGrouping)",
                "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection)",
                "let selectedAPIs = files.compactMap { file in",
                "apisByPath[file.standardizedFullPath]?.first",
                "EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection, selectedRecordProjection)",
                "return selectedAPIs",
                "#else",
                "let apisByPath = Dictionary(grouping: allFileAPIs, by: { standardizedAPIFilePath($0) })",
                "return files.compactMap { file in",
                "apisByPath[file.standardizedFullPath]?.first",
                "#endif"
            ] {
                let match = try XCTUnwrap(helper.range(of: hook, range: searchStart ..< helper.endIndex), "Missing or out-of-order accepted-file attribution hook: \(hook)")
                searchStart = match.upperBound
            }
            for forbidden in [
                "await",
                "Task",
                "cache",
                "generation",
                "UserDefaults",
                "app_settings",
                "nonisolated",
                "EditFlowPerf.Dimensions",
                "print(",
                "Logger",
                "os_log",
                "workspaceFileContextStore",
                "MCP",
                "routing",
                "limiter"
            ] {
                XCTAssertFalse(helper.contains(forbidden), "Forbidden accepted-file attribution semantic: \(forbidden)")
            }

            let indexedHelperStart = try XCTUnwrap(extractor.range(of: "    private static func acceptedFileAPIs(\n        from files: [WorkspaceFileRecord],\n        firstFileAPIByStandardizedNestedPath: [String: FileAPI]"))
            let indexedHelperEnd = try XCTUnwrap(extractor.range(of: "    private static func isUnderCurrentRoots", range: indexedHelperStart.upperBound ..< extractor.endIndex))
            let indexedHelper = String(extractor[indexedHelperStart.lowerBound ..< indexedHelperEnd.lowerBound])
            XCTAssertTrue(indexedHelper.contains("guard !files.isEmpty, !firstFileAPIByStandardizedNestedPath.isEmpty else { return [] }"))
            XCTAssertTrue(indexedHelper.contains("EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection)"))
            XCTAssertTrue(indexedHelper.contains("firstFileAPIByStandardizedNestedPath[file.standardizedFullPath]"))
            XCTAssertTrue(indexedHelper.contains("EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection, selectedRecordProjection)"))
            XCTAssertFalse(indexedHelper.contains("pathGrouping"))
            XCTAssertFalse(indexedHelper.contains("Dictionary(grouping:"))

            let fileViewModelHelperStart = try XCTUnwrap(extractor.range(of: "    private static func acceptedFileAPIs(from files: [FileViewModel]) -> [FileAPI] {"))
            let fileViewModelHelper = String(extractor[fileViewModelHelperStart.lowerBound ..< helperStart.lowerBound])
            XCTAssertFalse(fileViewModelHelper.contains("AcceptedFileAPIFilter"))

            let resolverStart = try XCTUnwrap(extractor.range(of: "static func resolveReferencedFilePaths(\n        from selectedFiles: [WorkspaceFileRecord]"))
            let resolverEnd = try XCTUnwrap(extractor.range(of: "/// Returns the list of file paths", range: resolverStart.upperBound ..< extractor.endIndex))
            let resolver = String(extractor[resolverStart.lowerBound ..< resolverEnd.lowerBound])
            let outerBegin = try XCTUnwrap(resolver.range(of: "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.acceptedFileAPIFilter)"))
            let helperCall = try XCTUnwrap(resolver.range(of: "acceptedFileAPIs(from: selectedFiles, allFileAPIs: allFileAPIs)", range: outerBegin.upperBound ..< resolver.endIndex))
            let outerEnd = try XCTUnwrap(resolver.range(of: "EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.acceptedFileAPIFilter, acceptedFileAPIFilter)", range: helperCall.upperBound ..< resolver.endIndex))
            let indexedResolver = try XCTUnwrap(resolver.range(of: "firstFileAPIByStandardizedNestedPath: [String: FileAPI]"))
            let indexedHelperCall = try XCTUnwrap(resolver.range(of: "firstFileAPIByStandardizedNestedPath: firstFileAPIByStandardizedNestedPath", range: indexedResolver.upperBound ..< resolver.endIndex))
            let lowerComputation = try XCTUnwrap(resolver.range(of: "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.autoReferencedAPIComputation)", range: indexedHelperCall.upperBound ..< resolver.endIndex))
            XCTAssertLessThan(outerBegin.lowerBound, helperCall.lowerBound)
            XCTAssertLessThan(helperCall.lowerBound, outerEnd.lowerBound)
            XCTAssertLessThan(outerEnd.lowerBound, indexedResolver.lowerBound)
            XCTAssertLessThan(indexedResolver.lowerBound, indexedHelperCall.lowerBound)
            XCTAssertLessThan(indexedHelperCall.lowerBound, lowerComputation.lowerBound)
        }

        func testAcceptedFileAPIFilterInnerAttributionRecorderCapturesEmptyDimensions() throws {
            _ = startedCapture(label: "accepted-file-api-filter-inner", maxSamples: 100)
            let stages: [(StaticString, String)] = [
                (EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.pathGrouping, "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter.PathGrouping"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection, "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter.SelectedRecordProjection")
            ]
            for (stage, _) in stages {
                EditFlowPerf.measure(stage) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, stages.count)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            for (_, stageName) in stages {
                let row = try XCTUnwrap(snapshot.stages.first { $0.stageName == stageName })
                XCTAssertEqual(row.sampleCount, 1)
                XCTAssertEqual(row.sanitizedDimensions, "")
            }
        }

        func testAllCodemapFileAPIsActorOwnedCacheHooksRemainScopedAndExhaustivelyInvalidated() throws {
            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            XCTAssertTrue(store.contains("private var cachedCodemapFileAPIAggregate: WorkspaceCodemapFileAPIAggregate?"))
            XCTAssertFalse(store.contains("private var cachedAllCodemapFileAPIs: [FileAPI]?"))
            XCTAssertEqual(store.components(separatedBy: "invalidateAllCodemapFileAPIsCache").count - 1, 9)

            let invalidatorStart = try XCTUnwrap(store.range(of: "    private func invalidateAllCodemapFileAPIsCache() {"))
            let invalidatorEnd = try XCTUnwrap(store.range(of: "    private func isDiscoverableFileID", range: invalidatorStart.upperBound ..< store.endIndex))
            let invalidator = String(store[invalidatorStart.lowerBound ..< invalidatorEnd.lowerBound])
            XCTAssertTrue(invalidator.contains("cachedCodemapFileAPIAggregate = nil"))
            for forbidden in ["await", "Task", "nonisolated", "generation"] {
                XCTAssertFalse(invalidator.contains(forbidden), "Forbidden aggregate-cache invalidator semantic: \(forbidden)")
            }

            let compatibilityAccessorStart = try XCTUnwrap(store.range(of: "    func allCodemapFileAPIs() -> [FileAPI] {"))
            let accessorStart = try XCTUnwrap(store.range(of: "    func codemapFileAPIAggregate() -> WorkspaceCodemapFileAPIAggregate {", range: compatibilityAccessorStart.upperBound ..< store.endIndex))
            let compatibilityAccessor = String(store[compatibilityAccessorStart.lowerBound ..< accessorStart.lowerBound])
            XCTAssertTrue(compatibilityAccessor.contains("codemapFileAPIAggregate().orderedFileAPIs"))
            let accessorEnd = try XCTUnwrap(store.range(of: "    func codemapSnapshotDictionary()", range: accessorStart.upperBound ..< store.endIndex))
            let accessor = String(store[accessorStart.lowerBound ..< accessorEnd.lowerBound])
            var searchStart = accessor.startIndex
            for hook in [
                "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.actorBodyTotal)",
                "defer { EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.actorBodyTotal, actorBodyTotal) }",
                "if let cachedCodemapFileAPIAggregate {",
                "return cachedCodemapFileAPIAggregate",
                "#if DEBUG || EDIT_FLOW_PERF",
                "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.stateSnapshot)",
                "codemapSnapshotsByFileID.values",
                ".filter { isDiscoverableFileID($0.fileID) }",
                "EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.stateSnapshot, stateSnapshot)",
                "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.materialization)",
                ".sorted { $0.fullPath < $1.fullPath }",
                ".compactMap(\\.fileAPI)",
                "#else",
                "let APIs = allCodemapSnapshots().compactMap(\\.fileAPI)",
                "#endif",
                "var firstFileAPIByStandardizedNestedPath: [String: FileAPI] = [:]",
                "firstFileAPIByStandardizedNestedPath.reserveCapacity(APIs.count)",
                "for api in APIs {",
                "let standardizedNestedPath = StandardizedPath.absolute(api.filePath)",
                "if firstFileAPIByStandardizedNestedPath[standardizedNestedPath] == nil {",
                "firstFileAPIByStandardizedNestedPath[standardizedNestedPath] = api",
                "let aggregate = WorkspaceCodemapFileAPIAggregate(",
                "orderedFileAPIs: APIs,",
                "firstFileAPIByStandardizedNestedPath: firstFileAPIByStandardizedNestedPath",
                "EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.materialization, materialization)",
                "cachedCodemapFileAPIAggregate = aggregate",
                "return aggregate"
            ] {
                let match = try XCTUnwrap(accessor.range(of: hook, range: searchStart ..< accessor.endIndex), "Missing or out-of-order allCodemapFileAPIs hook: \(hook)")
                searchStart = match.upperBound
            }
            for forbidden in [
                "await",
                "Task",
                "Array(codemapSnapshotsByFileID.values)",
                "generation",
                "UserDefaults",
                "app_settings",
                "nonisolated",
                "EditFlowPerf.Dimensions",
                "print(",
                "Logger",
                "os_log",
                "Dimensions(path:",
                "Dimensions(fileName:",
                "Dimensions(fileID:",
                "Dimensions(identifier:"
            ] {
                XCTAssertFalse(accessor.contains(forbidden), "Forbidden allCodemapFileAPIs cache semantic: \(forbidden)")
            }

            for requiredInvalidationWiring in [
                "if !snapshotsByRootID.isEmpty {\n            invalidateAllCodemapFileAPIsCache()",
                "if managedOnlyFileIDs.insert(file.id).inserted {\n                    invalidateAllCodemapFileAPIsCache()",
                "codemapFileIDsByRootID[rootID]?.remove(fileID)\n        invalidateAllCodemapFileAPIsCache()",
                "if codemapSnapshotsByFileID.removeValue(forKey: fileID) != nil {\n            invalidateAllCodemapFileAPIsCache()",
                "if managedOnlyFileIDs.remove(file.id) != nil {\n            invalidateAllCodemapFileAPIsCache()",
                "codemapFileIDsByRootID.removeAll(keepingCapacity: false)\n        invalidateAllCodemapFileAPIsCache()",
                "if removedSnapshot {\n            invalidateAllCodemapFileAPIsCache()"
            ] {
                XCTAssertTrue(store.contains(requiredInvalidationWiring), "Missing aggregate-cache invalidation wiring: \(requiredInvalidationWiring)")
            }

            let unloadStart = try XCTUnwrap(store.range(of: "    func unloadRoots(ids rootIDs: [UUID]) async {"))
            let unloadEnd = try XCTUnwrap(store.range(of: "    func file(rootID: UUID, relativePath: String)", range: unloadStart.upperBound ..< store.endIndex))
            let unload = String(store[unloadStart.lowerBound ..< unloadEnd.lowerBound])
            let rootDetach = try XCTUnwrap(unload.range(of: "rootStatesByID.removeValue(forKey: rootID)"))
            let watcherStopStart = try XCTUnwrap(unload.range(of: "let detachedWatcherStops = startDetachedWatcherStops(statesToUnload)"))
            let watcherStopWait = try XCTUnwrap(unload.range(of: "let watcherStopReports = await awaitDetachedWatcherStops(detachedWatcherStops)"))
            let managedOnlyCleanup = try XCTUnwrap(unload.range(of: "managedOnlyFileIDs.remove(fileID)"))
            let rootSnapshotCleanup = try XCTUnwrap(unload.range(of: "removeCodemapSnapshots(forRootID: rootID)"))
            XCTAssertLessThan(rootDetach.lowerBound, watcherStopStart.lowerBound)
            XCTAssertLessThan(watcherStopStart.lowerBound, watcherStopWait.lowerBound)
            XCTAssertLessThan(watcherStopWait.lowerBound, managedOnlyCleanup.lowerBound)
            XCTAssertLessThan(managedOnlyCleanup.lowerBound, rootSnapshotCleanup.lowerBound)
            XCTAssertFalse(String(unload[rootDetach.lowerBound ..< watcherStopStart.lowerBound]).contains("invalidateAllCodemapFileAPIsCache"))
            XCTAssertFalse(String(unload[managedOnlyCleanup.lowerBound ..< rootSnapshotCleanup.lowerBound]).contains("await"))

            let provider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            let mutations = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionMutationService.swift")
            let extractor = try source("Sources/RepoPrompt/Features/CodeMap/CodeMapExtractor.swift")
            let diagnostics = try diagnosticsSource() + source("Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift")
            for forbiddenOwner in [provider, mutations, extractor, diagnostics] {
                XCTAssertFalse(forbiddenOwner.contains("AllCodemapFileAPIs"))
                XCTAssertFalse(forbiddenOwner.contains("cachedAllCodemapFileAPIs"))
                XCTAssertFalse(forbiddenOwner.contains("cachedCodemapFileAPIAggregate"))
                XCTAssertFalse(forbiddenOwner.contains("invalidateAllCodemapFileAPIsCache"))
            }

            let recomputeStart = try XCTUnwrap(mutations.range(of: "    func recomputeAutoCodemaps("))
            let recompute = String(mutations[recomputeStart.lowerBound ..< mutations.endIndex])
            let outerBegin = try XCTUnwrap(recompute.range(of: "let codemapAPILoad = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.codemapAPILoad)"))
            let outerAwait = try XCTUnwrap(recompute.range(of: "let aggregate = await store.codemapFileAPIAggregate()", range: outerBegin.upperBound ..< recompute.endIndex))
            XCTAssertEqual(recompute.components(separatedBy: "await store.codemapFileAPIAggregate()").count - 1, 1)
            XCTAssertFalse(recompute.contains("await store.allCodemapFileAPIs()"))
            XCTAssertTrue(recompute.contains("among: aggregate.orderedFileAPIs"))
            XCTAssertTrue(recompute.contains("firstFileAPIByStandardizedNestedPath: aggregate.firstFileAPIByStandardizedNestedPath"))
            let outerEnd = try XCTUnwrap(recompute.range(of: "EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.codemapAPILoad, codemapAPILoad)", range: outerAwait.upperBound ..< recompute.endIndex))
            XCTAssertLessThan(outerBegin.lowerBound, outerAwait.lowerBound)
            XCTAssertLessThan(outerAwait.lowerBound, outerEnd.lowerBound)
        }

        func testAllCodemapFileAPIsActorBodyAttributionRecorderCapturesEmptyDimensions() throws {
            _ = startedCapture(label: "all-codemap-file-apis-actor-body", maxSamples: 100)
            let stages: [(StaticString, String)] = [
                (EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.actorBodyTotal, "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.ActorBodyTotal"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.stateSnapshot, "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.StateSnapshot"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.materialization, "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.Materialization")
            ]
            for (stage, _) in stages {
                EditFlowPerf.measure(stage) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, stages.count)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            for (_, stageName) in stages {
                let row = try XCTUnwrap(snapshot.stages.first { $0.stageName == stageName })
                XCTAssertEqual(row.sampleCount, 1)
                XCTAssertEqual(row.sanitizedDimensions, "")
            }
        }

        func testReadResolutionDecompositionHooksRemainOnExpectedLayers() throws {
            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            for hook in [
                "resolveReadableFile",
                "rootRefsLookup",
                "resolveReadFileRequest"
            ] {
                XCTAssertTrue(viewModel.contains(hook), "Missing view-model read-resolution hook: \(hook)")
            }

            let readableService = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceReadableFileService.swift")
            for hook in [
                "exactCatalogLookupAwait",
                "explicitMaterialization",
                "generalLookupFallback",
                "externalFileFallback",
                "allowGeneralLookupFallback: false"
            ] {
                XCTAssertTrue(readableService.contains(hook), "Missing readable-service resolution hook: \(hook)")
            }

            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            XCTAssertTrue(store.contains("exactCatalogLookupActorBody"))
            XCTAssertTrue(store.contains("exactCatalogLookupRoute"))
            XCTAssertTrue(store.contains("Dimensions(status: exactCatalogLookupRoute, outcome: exactCatalogLookupOutcome)"))
            XCTAssertTrue(store.contains("Lifecycle.ReadFile.exactCatalogLookupResolved"))
            XCTAssertTrue(store.contains("Dimensions(outcome:"))
        }

        func testReadResolutionDecompositionAvoidsOrdinaryReleaseOutcomeBookkeeping() throws {
            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            XCTAssertFalse(viewModel.contains("let readableServiceOutcome ="))
            XCTAssertTrue(viewModel.contains("switch resolution"))
            XCTAssertTrue(viewModel.contains("case let .readable(handle):"))

            let readableService = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceReadableFileService.swift")
            XCTAssertFalse(readableService.contains("let exactCatalogLookupOutcome ="))
            XCTAssertFalse(readableService.contains("let explicitMaterializationOutcome ="))
            XCTAssertTrue(readableService.contains("Dimensions(outcome: {\n                switch exactCatalogLookup"))
            XCTAssertTrue(readableService.contains("Dimensions(outcome: {\n                switch materialization"))

            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            XCTAssertTrue(store.contains("#if DEBUG || EDIT_FLOW_PERF\n            var exactCatalogLookupOutcome"))
            XCTAssertTrue(store.contains("var exactCatalogLookupRoute = \"empty\""))
            XCTAssertTrue(store.contains("exactCatalogLookupRoute = \"absolute\""))
            XCTAssertTrue(store.contains("exactCatalogLookupRoute = \"rootAlias\""))
            XCTAssertTrue(store.contains("exactCatalogLookupRoute = \"relative\""))
            XCTAssertTrue(store.contains("exactCatalogLookupRoute = \"blocked\""))
            XCTAssertTrue(store.contains("#if DEBUG || EDIT_FLOW_PERF\n                exactCatalogLookupOutcome ="))
        }

        func testSearchCatalogSnapshotCacheUsesSelectiveDependencyKeyedEviction() throws {
            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            XCTAssertTrue(store.contains("private static let maxCachedSearchCatalogSnapshotScopes = 16"))
            XCTAssertTrue(store.contains("private var searchCatalogSnapshotsByScope: [WorkspaceLookupRootScope: SearchCatalogSnapshotCacheEntry] = [:]"))
            XCTAssertTrue(store.contains("let lifetimeID: UUID"))
            XCTAssertTrue(store.contains("generation: catalogGenerationsByRootID[root.id] ?? 0"))
            XCTAssertTrue(store.contains("dependencies: dependencies"))
            XCTAssertFalse(store.contains("case .sessionBoundWorkspace:\n            scopedSnapshotGeneration(scope: .allLoaded)"))
            XCTAssertTrue(store.contains("lastAccessSequence: nextSearchCatalogAccessSequence()"))
            XCTAssertTrue(store.contains("searchCatalogSnapshotsByScope.min(by:"))
            XCTAssertTrue(store.contains("scopes: [eviction.key]"))
            XCTAssertFalse(store.contains("searchCatalogSnapshotsByScope.removeAll(keepingCapacity: true)"))
            XCTAssertFalse(store.contains("clearSearchCatalogSnapshotCache"))
            XCTAssertFalse(store.contains("rootStatesByID[eligible.rootID] = state\n            evict"))
            assertSourceOrder(
                in: store,
                hooks: [
                    "guard !statesToUnload.isEmpty else { return }",
                    "invalidatePathMatchSnapshot(\n            affectedRootKinds: Set(statesToUnload.map(\\.state.root.kind))",
                    "await searchDecodedContentCache.invalidate(rootID: entry.rootID)",
                    "finishRootUnload(for: unloadingPaths)"
                ]
            )
            XCTAssertTrue(store.contains("bumpCatalogGenerations(\n            affectedRootKinds: affectedRootKinds,\n            affectedRootIDs: affectedRootIDs"))
            XCTAssertTrue(store.contains("evictInvalidSearchCatalogSnapshots("))
            XCTAssertTrue(store.contains("invalidatePathMatchCache(snapshotIdentities: stalePathMatchIdentities)"))
            XCTAssertFalse(store.contains("#endif\n        invalidatePathMatchCache()\n        finishRootUnload(for: unloadingPaths)"))
            XCTAssertTrue(store.contains("cacheHit: true"))
            XCTAssertTrue(store.contains("cacheHit: false"))
            XCTAssertFalse(store.contains("Dimensions(rootScope:"))
            XCTAssertFalse(store.contains("Dimensions(path:"))
        }

        func testInactiveCaptureFastPathRemainsAtomicAndUnusedOutputBytesIsAbsent() throws {
            let perf = try source("Sources/RepoPrompt/Infrastructure/Diffing/EditFlowPerf.swift")
            XCTAssertTrue(perf.contains("Lightweight, gated instrumentation for hot-path diagnostics."))
            XCTAssertTrue(perf.contains("private let activeHint = DebugCaptureActiveHint()"))
            XCTAssertTrue(perf.contains("if let active = activeHint.loadIfAvailable(), !active { return nil }"))
            XCTAssertTrue(perf.contains("@available(macOS 15.0, *)"))
            XCTAssertFalse(perf.contains("outputBytes"))
        }

        func testCaptureRejectsConcurrentStartAndFinishDisablesCapture() {
            switch EditFlowPerf.beginDebugCapture(label: "first", maxSamples: 100) {
            case .started:
                break
            case .busy:
                XCTFail("First capture should start.")
            }
            switch EditFlowPerf.beginDebugCapture(label: "second", maxSamples: 100) {
            case .started:
                XCTFail("Concurrent capture should be rejected.")
            case let .busy(snapshot):
                XCTAssertEqual(snapshot.label, "first")
                XCTAssertTrue(snapshot.active)
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
        }

        func testStaleIntervalFromFinishedCaptureDoesNotContaminateNextCapture() throws {
            _ = startedCapture(label: "capture-a", maxSamples: 100)
            let staleState = try XCTUnwrap(EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.providerExecution))
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)

            _ = startedCapture(label: "capture-b", maxSamples: 100)
            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.providerExecution, staleState)

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.label, "capture-b")
            XCTAssertEqual(snapshot.retainedSampleCount, 0)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            XCTAssertTrue(snapshot.stages.isEmpty)
        }

        func testDirectCaptureSampleLimitIsClampedToDiagnosticBounds() {
            let lowerBound = startedCapture(label: "lower", maxSamples: 1)
            XCTAssertEqual(lowerBound.maxSamples, 100)
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)

            let upperBound = startedCapture(label: "upper", maxSamples: 100_001)
            XCTAssertEqual(upperBound.maxSamples, 100_000)
            XCTAssertEqual(upperBound.maxLifecycleEvents, 20000)
        }

        func testUnsafeSyntheticLabelAndDimensionsAreSanitizedAndBounded() throws {
            let unsafe = "synthetic /:|\\n" + String(repeating: "x", count: 100)
            let started = startedCapture(label: unsafe, maxSamples: 100)
            assertPermittedLabel(started.label)

            EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.providerExecution,
                EditFlowPerf.Dimensions(toolName: unsafe, status: unsafe)
            ) {}

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let aggregate = try XCTUnwrap(snapshot.stages.first)
            let components = aggregate.sanitizedDimensions.split(separator: " ")
            XCTAssertEqual(components.count, 2)
            for component in components {
                let parts = component.split(separator: "=", maxSplits: 1)
                XCTAssertEqual(parts.count, 2)
                assertPermittedLabel(String(parts[1]))
            }
        }

        func testBoundedCaptureReportsDroppedSamplesAndSanitizedDimensions() throws {
            switch EditFlowPerf.beginDebugCapture(label: "bounded", maxSamples: 100) {
            case .started:
                break
            case .busy:
                XCTFail("Capture should start.")
            }

            for _ in 0 ..< 101 {
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.providerExecution,
                    EditFlowPerf.Dimensions(toolName: "read_file", status: "ok")
                ) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.retainedSampleCount, 100)
            XCTAssertEqual(snapshot.droppedSampleCount, 1)
            let aggregate = try XCTUnwrap(snapshot.stages.first)
            XCTAssertEqual(aggregate.sampleCount, 100)
            XCTAssertTrue(aggregate.sanitizedDimensions.contains("tool=read_file"))
            XCTAssertFalse(aggregate.sanitizedDimensions.contains("/"))
            XCTAssertFalse(aggregate.sanitizedDimensions.contains("namespace"))
        }

        func testLifecycleEventInventoryAndHiddenTimelineToggleRemainPresent() throws {
            let perf = try source("Sources/RepoPrompt/Infrastructure/Diffing/EditFlowPerf.swift")
            for eventName in [
                "MCP.ToolCall.Received",
                "MCP.ToolCall.RoutingSnapshotCompleted",
                "MCP.ToolCall.LimiterWaitBegan",
                "MCP.ToolCall.LimiterAcquired",
                "MCP.ToolCall.CompletionObserverReturned",
                "MCP.ToolCall.FormatResultReturned",
                "MCP.ToolCall.ResolvedProviderBegan",
                "MCP.ToolCall.ResolvedProviderEnded",
                "MCP.ToolCall.HandlerResultReady",
                "MCP.RunTool.PreflushBegan",
                "MCP.RunTool.PreflushEnded",
                "MCP.RunTool.RegistrationScheduled",
                "MCP.RunTool.RegistrationMainActorEntered",
                "MCP.RunTool.RegistrationEnded",
                "MCP.RunTool.ProviderBegan",
                "MCP.RunTool.ProviderEnded",
                "MCP.RunTool.CleanupScheduled",
                "MCP.RunTool.CleanupMainActorEntered",
                "MCP.RunTool.Unregister",
                "MCP.RunTool.IdleWaitersResumed",
                "MCP.RunTool.CleanupEnded",
                "MCP.RunTool.Return",
                "FileSystem.CallbackAccepted",
                "FileSystem.ServiceEnqueueEntered",
                "FileSystem.ServicePublish",
                "FileSystem.ContentLoadEntered",
                "FileSystem.ContentReadRequestPrepared",
                "FileSystem.ContentReadOffActorScheduled",
                "FileSystem.ContentReadWorkerPermitWaitBegan",
                "FileSystem.ContentReadWorkerPermitAcquired",
                "FileSystem.ContentReadWorkerPermitCancelled",
                "FileSystem.ContentReadWorkerOverloaded",
                "FileSystem.ContentReadWorkerReturned",
                "FileSystem.ContentLoadReturned",
                "Search.BroadAdmissionWaitBegan",
                "Search.BroadAdmissionPermitAcquired",
                "Search.BroadAdmissionPermitCancelled",
                "Search.BroadAdmissionPermitReleased",
                "Search.BroadAdmissionOverloaded",
                "Search.BroadAdmissionWaitExpired",
                "Search.ContentFreshnessStoreEntered",
                "Search.ContentFreshnessStoreReturned",
                "Search.ContentFreshnessRootEntered",
                "Search.ContentFreshnessRootReturned",
                "Search.ProviderEntered",
                "Search.ProviderWorkspaceSearchReturned",
                "Search.ProviderDTOReady",
                "Search.ProviderAutoSelectionReturned",
                "Search.ProviderResultReady",
                "ReadFile.ProviderEntered",
                "ReadFile.ExplicitFreshnessBegan",
                "ReadFile.ExplicitFreshnessEnded",
                "ReadFile.ExactCatalogLookupResolved",
                "ReadFile.ExactCatalogShortcutResolved",
                "ReadFile.FolderResolutionReturned",
                "ReadFile.ReadableServiceResolutionReturned",
                "ReadFile.StoreReadContentEntered",
                "ReadFile.StoreReadContentReturned",
                "ReadFile.ProviderResultReady",
                "Bootstrap.SocketAccepted",
                "Bootstrap.HandshakeIOQueued",
                "Bootstrap.HandshakeIOBegan",
                "Bootstrap.HandshakeIOEnded",
                "Bootstrap.AdmissionBegan",
                "Bootstrap.AdmissionEnded",
                "Bootstrap.AcceptedResponseSent",
                "Bootstrap.OwnershipTransferred",
                "Bootstrap.PostAcceptStartupBegan",
                "Bootstrap.PostAcceptStartupEnded",
                "WorkspaceIngress.StoreSinkScheduled",
                "WorkspaceIngress.StoreSinkBegan",
                "WorkspaceIngress.StoreCanonicalApplyCompleted",
                "WorkspaceIngress.RootFlushBegan",
                "WorkspaceIngress.RootFlushEnded",
                "ReadFile.AutoSelect.EnqueueAccepted",
                "ReadFile.AutoSelect.EnqueueCoalesced",
                "ReadFile.AutoSelect.CanonicalApplyBegan",
                "ReadFile.AutoSelect.CanonicalApplyEnded",
                "ReadFile.AutoSelect.MirrorScheduled",
                "ReadFile.AutoSelect.MirrorCoalesced",
                "ReadFile.AutoSelect.MirrorApplyBegan",
                "ReadFile.AutoSelect.MirrorApplyEnded",
                "ReadFile.AutoSelect.DrainBegan",
                "ReadFile.AutoSelect.DrainEnded",
                "WorkspaceDurability.FlushBegan",
                "WorkspaceDurability.FlushEnded",
                "WorkspaceDurability.WriteBegan",
                "WorkspaceDurability.WriteEnded"
            ] {
                XCTAssertTrue(perf.contains(eventName), "Missing lifecycle event inventory entry: \(eventName)")
            }

            let sibling = try source("Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift")
            XCTAssertTrue(sibling.contains("include_timeline"))
            XCTAssertTrue(sibling.contains("snapshot.payload(includeTimeline: includeTimeline)"))
        }

        func testLifecycleTimelinePreservesCorrelationOrderingAndSanitizesDimensions() throws {
            _ = startedCapture(label: "timeline", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            let unsafe = "unsafe /:|\\n" + String(repeating: "x", count: 100)

            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    toolName: unsafe,
                    storeCapacity: -1,
                    globalCapacity: -2,
                    storeActiveCount: -3,
                    globalActiveCount: -4,
                    storeQueueDepth: -5,
                    globalQueueDepth: -6,
                    workloadClass: unsafe,
                    admissionClass: unsafe,
                    queueAgeBucket: unsafe,
                    contentSource: unsafe,
                    rootToken: unsafe,
                    queueDepth: -7,
                    waiterCount: -8
                )
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.routingSnapshotCompleted,
                correlation: correlation,
                EditFlowPerf.Dimensions(toolName: "read_file")
            )

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.maxLifecycleEvents, 100)
            XCTAssertEqual(snapshot.retainedLifecycleEventCount, 2)
            XCTAssertEqual(snapshot.droppedLifecycleEventCount, 0)
            XCTAssertEqual(snapshot.lifecycleEvents.map(\.ordinal), [1, 2])
            XCTAssertEqual(snapshot.lifecycleEvents.map(\.eventName), [
                "MCP.ToolCall.Received",
                "MCP.ToolCall.RoutingSnapshotCompleted"
            ])
            XCTAssertEqual(Set(snapshot.lifecycleEvents.map(\.correlationID)).count, 1)
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("queueDepth=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("waiterCount=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("storeCapacity=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("globalCapacity=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("storeActiveCount=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("globalActiveCount=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("storeQueueDepth=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("globalQueueDepth=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("workloadClass=unsafe"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("admissionClass=unsafe"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("queueAgeBucket=unsafe"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("contentSource=unsafe"))
            XCTAssertFalse(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("/"))
            XCTAssertFalse(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("|"))
        }

        func testLifecycleTimelineBoundReportsDroppedEventsWithoutConsumingIntervalBudget() throws {
            _ = startedCapture(label: "timeline-bound", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            for _ in 0 ..< 101 {
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.received,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(toolName: "read_file")
                )
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.retainedSampleCount, 0)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            XCTAssertEqual(snapshot.maxLifecycleEvents, 100)
            XCTAssertEqual(snapshot.retainedLifecycleEventCount, 100)
            XCTAssertEqual(snapshot.droppedLifecycleEventCount, 1)
            XCTAssertEqual(snapshot.lifecycleEvents.count, 100)
        }

        func testStaleLifecycleCorrelationCannotContaminateNextCapture() throws {
            _ = startedCapture(label: "timeline-a", maxSamples: 100)
            let staleCorrelation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)

            _ = startedCapture(label: "timeline-b", maxSamples: 100)
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: staleCorrelation,
                EditFlowPerf.Dimensions(toolName: "read_file")
            )

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.label, "timeline-b")
            XCTAssertEqual(snapshot.retainedLifecycleEventCount, 0)
            XCTAssertEqual(snapshot.droppedLifecycleEventCount, 0)
            XCTAssertTrue(snapshot.lifecycleEvents.isEmpty)
        }

        func testInactiveLifecycleEventDoesNotEvaluateDimensionsAndAggregateOnlyPayloadOmitsTimeline() throws {
            var dimensionsEvaluated = false
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: nil,
                EditFlowPerf.Dimensions(toolName: {
                    dimensionsEvaluated = true
                    return "should_not_evaluate"
                }())
            )
            XCTAssertFalse(dimensionsEvaluated)

            var intervalDimensionsEvaluated = false
            let inactiveState = EditFlowPerf.begin(
                EditFlowPerf.Stage.Search.broadAdmissionLeaseHold,
                EditFlowPerf.Dimensions(admissionClass: {
                    intervalDimensionsEvaluated = true
                    return "should_not_evaluate"
                }())
            )
            XCTAssertNil(inactiveState)
            XCTAssertFalse(intervalDimensionsEvaluated)

            _ = startedCapture(label: "aggregate-only", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.MCPToolCall.received, correlation: correlation)
            let payload = EditFlowPerf.debugCaptureSnapshot(finish: true).payload(includeTimeline: false)
            XCTAssertEqual(payload["timeline_included"] as? Bool, false)
            XCTAssertNil(payload["lifecycle_events"])
            XCTAssertEqual(payload["retained_lifecycle_event_count"] as? Int, 1)
        }

        func testWithConnectionIDScopesLifecycleCorrelationAcrossChildTaskAndRestoresIt() async throws {
            _ = startedCapture(label: "connection-task-local", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            XCTAssertNil(EditFlowPerf.currentLifecycleCorrelation)

            let observed = await ServerNetworkManager.withConnectionID(UUID(), lifecycleCorrelation: correlation) {
                let immediate = EditFlowPerf.currentLifecycleCorrelation?.id
                let child = await Task { EditFlowPerf.currentLifecycleCorrelation?.id }.value
                return (immediate, child)
            }

            XCTAssertEqual(observed.0, correlation.id)
            XCTAssertEqual(observed.1, correlation.id)
            XCTAssertNil(EditFlowPerf.currentLifecycleCorrelation)
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
        }

        func testFileSystemPublicationScopesCorrelationDuringSynchronousSinkAndChildTask() async throws {
            let root = try temporaryRoots.makeRoot(suiteName: "FileSystemPublicationCorrelation")
            let service = try await FileSystemService(
                path: root.path,
                respectGitignore: false,
                respectRepoIgnore: false,
                respectCursorignore: false,
                skipSymlinks: true
            )
            let publisher = await service.publisherForChanges()
            let childTaskCompleted = expectation(description: "sink child task captured publication correlation")
            let observations = LockedCorrelationIDs()
            let cancellable = publisher.sink { _ in
                observations.recordSink(EditFlowPerf.currentFileSystemPublicationCorrelation?.id)
                Task {
                    observations.recordChildTask(EditFlowPerf.currentFileSystemPublicationCorrelation?.id)
                    childTaskCompleted.fulfill()
                }
            }

            _ = startedCapture(label: "filesystem-publication", maxSamples: 100)
            XCTAssertNil(EditFlowPerf.currentFileSystemPublicationCorrelation)
            await service.publishFileSystemDeltas([.fileAdded("Synthetic.swift")], source: .syntheticMutation)
            XCTAssertNil(EditFlowPerf.currentFileSystemPublicationCorrelation)
            await fulfillment(of: [childTaskCompleted], timeout: 1)

            let ids = observations.snapshot()
            let sinkID = try XCTUnwrap(ids.sink)
            XCTAssertEqual(ids.childTask, sinkID)
            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertTrue(snapshot.lifecycleEvents.contains {
                $0.eventName == "FileSystem.ServicePublish" && $0.correlationID == sinkID.uuidString
            })
            withExtendedLifetime(cancellable) {}
            await service.stopWatchingForChanges()
        }

        func testContentReadWorkerPermitAndBroadSearchAdmissionHooksRemainOwnedSanitizedAndOrdered() throws {
            let contentLoading = try source("Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+ContentLoading.swift")
            XCTAssertTrue(contentLoading.contains("EditFlowPerf.Stage.FileSystem.contentReadWorkerPermitWait"))
            XCTAssertTrue(contentLoading.contains("EditFlowPerf.Lifecycle.FileSystem.contentReadWorkerPermitWaitBegan"))
            XCTAssertTrue(contentLoading.contains("EditFlowPerf.Lifecycle.FileSystem.contentReadWorkerPermitAcquired"))
            XCTAssertTrue(contentLoading.contains("EditFlowPerf.Lifecycle.FileSystem.contentReadWorkerPermitCancelled"))
            XCTAssertTrue(contentLoading.contains("EditFlowPerf.Lifecycle.FileSystem.contentReadWorkerOverloaded"))
            XCTAssertTrue(contentLoading.contains("maxQueuedWaiterCount: 512"))
            XCTAssertTrue(contentLoading.contains("ownerID: request.schedulerOwnerID"))
            XCTAssertTrue(contentLoading.contains("agePromotionNanoseconds"))
            XCTAssertTrue(contentLoading.contains("maxConsecutiveInteractiveGrants"))
            XCTAssertTrue(contentLoading.contains("EditFlowPerf.Stage.FileSystem.contentReadWorkerBody"))
            XCTAssertTrue(contentLoading.contains("workloadClass: request.workloadClass"))
            XCTAssertTrue(contentLoading.contains("contentSource: \"disk\""))
            XCTAssertTrue(contentLoading.contains("workerBodyFileBytes = telemetryFileBytes(validated.fileSize)"))
            XCTAssertFalse(contentLoading.contains("EditFlowPerf.Dimensions(path:"))
            assertSourceOrder(
                in: contentLoading,
                hooks: [
                    "let permitWaitState = EditFlowPerf.begin(",
                    "let acquisition: PermitAcquisition",
                    "acquisition = try await acquire(",
                    "EditFlowPerf.end(\n                EditFlowPerf.Stage.FileSystem.contentReadWorkerPermitWait",
                    "defer { release(acquisition) }",
                    "return try await body()"
                ]
            )

            let coordinator = try source("Sources/RepoPrompt/Features/Search/StoreBackedWorkspaceSearchLane.swift")
            XCTAssertTrue(coordinator.contains("EditFlowPerf.Stage.Search.broadAdmissionWait"))
            XCTAssertTrue(coordinator.contains("EditFlowPerf.Lifecycle.Search.broadAdmissionWaitBegan"))
            XCTAssertTrue(coordinator.contains("EditFlowPerf.Lifecycle.Search.broadAdmissionPermitAcquired"))
            XCTAssertTrue(coordinator.contains("EditFlowPerf.Lifecycle.Search.broadAdmissionPermitCancelled"))
            XCTAssertTrue(coordinator.contains("EditFlowPerf.Lifecycle.Search.broadAdmissionPermitReleased"))
            XCTAssertTrue(coordinator.contains("EditFlowPerf.Lifecycle.Search.broadAdmissionOverloaded"))
            XCTAssertTrue(coordinator.contains("EditFlowPerf.Lifecycle.Search.broadAdmissionWaitExpired"))
            XCTAssertTrue(coordinator.contains("EditFlowPerf.Stage.Search.broadAdmissionLeaseHold"))
            XCTAssertTrue(coordinator.contains("storeCapacity: configuration.maxActiveLeases"))
            XCTAssertTrue(coordinator.contains("globalCapacity: 0"))
            XCTAssertTrue(coordinator.contains("storeQueueDepth: metrics.queueDepth"))
            XCTAssertTrue(coordinator.contains("globalQueueDepth: 0"))
            XCTAssertTrue(coordinator.contains("queueAgeBucket: queueAgeBucket"))
            XCTAssertFalse(coordinator.contains("EditFlowPerf.Dimensions(path:"))
            assertSourceOrder(
                in: coordinator,
                hooks: [
                    "let waitState = EditFlowPerf.begin(",
                    "acquisition = try await acquire(",
                    "let leaseHoldState = EditFlowPerf.begin(",
                    "defer {",
                    "EditFlowPerf.Stage.Search.broadAdmissionLeaseHold",
                    "release(acquisition)",
                    "return try await operation(fileSearchActor)"
                ]
            )
        }

        func testExactReadAndBootstrapAttributionHooksRemainOwnedCoarseAndDirect() throws {
            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            for hook in [
                "EditFlowPerf.Stage.MCPToolCall.resolvedProviderDispatch",
                "EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderBegan",
                "EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderEnded",
                "EditFlowPerf.Stage.MCPToolCall.handlerResultHandoff",
                "EditFlowPerf.Lifecycle.MCPToolCall.handlerResultReady",
                "EditFlowPerf.Stage.Bootstrap.postAcceptStartup",
                "EditFlowPerf.Lifecycle.Bootstrap.postAcceptStartupBegan",
                "EditFlowPerf.Lifecycle.Bootstrap.postAcceptStartupEnded"
            ] {
                XCTAssertTrue(manager.contains(hook), "Missing manager attribution hook: \(hook)")
            }
            XCTAssertEqual(manager.components(separatedBy: "try await toolDef.callAsFunction(effectiveArgs)").count - 1, 1)
            XCTAssertFalse(manager.contains("service.call("))

            let readable = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceReadableFileService.swift")
            XCTAssertTrue(readable.contains("EditFlowPerf.Stage.ReadFile.explicitIngressFreshnessWait"))
            XCTAssertTrue(readable.contains("EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan"))
            XCTAssertTrue(readable.contains("EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded"))

            let server = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            assertSourceOrder(
                in: server,
                hooks: [
                    "let roots = await store.rootRefs(scope: lookupRootScope)",
                    "await readableService.awaitFreshnessForExplicitRequest(path, rootRefs: roots)",
                    "await readableService.resolveReadFileRequest("
                ]
            )
            let provider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            assertSourceOrder(
                in: provider,
                hooks: [
                    "EditFlowPerf.Stage.ReadFile.providerValueEncoding",
                    "MCPProviderProjectionWorker.encode(",
                    "EditFlowPerf.Lifecycle.ReadFile.providerResultReady",
                    "return value"
                ]
            )

            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            for hook in [
                "EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait",
                "EditFlowPerf.Lifecycle.ReadFile.storeReadContentEntered",
                "EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned",
                "EditFlowPerf.Stage.ReadFile.folderResolutionGeneralLookupFallback",
                "EditFlowPerf.Stage.ReadFile.pathLookupStaticSnapshotBuild",
                "EditFlowPerf.Stage.Search.contentFreshnessValidationStoreActorBody",
                "EditFlowPerf.Lifecycle.Search.contentFreshnessStoreEntered",
                "EditFlowPerf.Lifecycle.Search.contentFreshnessStoreReturned"
            ] {
                XCTAssertTrue(store.contains(hook), "Missing store attribution hook: \(hook)")
            }

            let fileSystem = try source("Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+ContentLoading.swift")
            for hook in [
                "EditFlowPerf.Stage.FileSystem.contentLoadTotal",
                "EditFlowPerf.Stage.FileSystem.contentReadRequestPreparation",
                "EditFlowPerf.Stage.FileSystem.contentReadOffActorAwait",
                "EditFlowPerf.Lifecycle.FileSystem.contentLoadEntered",
                "EditFlowPerf.Lifecycle.FileSystem.contentReadRequestPrepared",
                "EditFlowPerf.Lifecycle.FileSystem.contentReadOffActorScheduled",
                "EditFlowPerf.Lifecycle.FileSystem.contentReadWorkerReturned",
                "EditFlowPerf.Lifecycle.FileSystem.contentLoadReturned"
            ] {
                XCTAssertTrue(fileSystem.contains(hook), "Missing filesystem attribution hook: \(hook)")
            }

            let fileEvents = try source("Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+FSEvents.swift")
            XCTAssertTrue(fileEvents.contains("EditFlowPerf.Stage.Search.contentFreshnessValidationRootActorBody"))
            XCTAssertTrue(fileEvents.contains("EditFlowPerf.Lifecycle.Search.contentFreshnessRootEntered"))
            XCTAssertTrue(fileEvents.contains("EditFlowPerf.Lifecycle.Search.contentFreshnessRootReturned"))

            let bootstrap = try source("Sources/RepoPrompt/Infrastructure/MCP/BootstrapSocketServer.swift")
            for hook in [
                "EditFlowPerf.Lifecycle.Bootstrap.socketAccepted",
                "EditFlowPerf.Lifecycle.Bootstrap.handshakeIOQueued",
                "EditFlowPerf.Lifecycle.Bootstrap.handshakeIOBegan",
                "EditFlowPerf.Lifecycle.Bootstrap.handshakeIOEnded",
                "EditFlowPerf.Stage.Bootstrap.handshakeIOQueueEnvelope",
                "EditFlowPerf.Stage.Bootstrap.handshakeIOBlockingRead",
                "EditFlowPerf.Stage.Bootstrap.admission",
                "EditFlowPerf.Lifecycle.Bootstrap.acceptedResponseSent",
                "EditFlowPerf.Lifecycle.Bootstrap.ownershipTransferred"
            ] {
                XCTAssertTrue(bootstrap.contains(hook), "Missing bootstrap attribution hook: \(hook)")
            }
            assertSourceOrder(
                in: bootstrap,
                hooks: [
                    "EditFlowPerf.Lifecycle.Bootstrap.acceptedResponseSent",
                    "handshakeSocket.transferOwnershipIfOpen(",
                    "EditFlowPerf.Lifecycle.Bootstrap.ownershipTransferred",
                    "await postAccept()"
                ]
            )

            for privacySafeSource in [manager, readable, server, provider, store, fileSystem, fileEvents, bootstrap] {
                XCTAssertFalse(privacySafeSource.contains("EditFlowPerf.Dimensions(path:"))
                XCTAssertFalse(privacySafeSource.contains("EditFlowPerf.Dimensions(payload:"))
            }
            XCTAssertFalse(bootstrap.contains("EditFlowPerf.Dimensions(client"))
            XCTAssertFalse(bootstrap.contains("EditFlowPerf.Dimensions(session"))
            XCTAssertFalse(bootstrap.contains("EditFlowPerf.Dimensions(fd:"))
        }

        func testSearchTailTelemetryRemainsCoarseAndPrivacySafe() throws {
            let searchMatch = try source("Sources/RepoPrompt/Features/Search/SearchMatch.swift")
            for hook in [
                "EditFlowPerf.Stage.Search.contentFreshnessValidation",
                "EditFlowPerf.Stage.Search.contentScanTotal",
                "EditFlowPerf.Stage.Search.resultConstruction",
                "admittedFileCount:",
                "scannedFileCount:",
                "batchSize:",
                "workerCount:",
                "matchedFileCount:",
                "contentMatchCount:",
                "pathMatchCount:",
                "freshnessPolicy:"
            ] {
                XCTAssertTrue(searchMatch.contains(hook), "Missing coarse search-tail telemetry hook: \(hook)")
            }
            XCTAssertFalse(searchMatch.contains("EditFlowPerf.Dimensions(path:"))
            XCTAssertFalse(searchMatch.contains("EditFlowPerf.Dimensions(pattern:"))
            XCTAssertFalse(searchMatch.contains("workspaceName:"))
            assertSourceOrder(
                in: searchMatch,
                hooks: [
                    "} catch let error as ContentReadSchedulerError {",
                    "StoreBackedWorkspaceSearchAdmissionError.contentReadQueueFull(",
                    "} catch let error as StoreBackedWorkspaceSearchAdmissionError {",
                    "throw error",
                    "} catch is CancellationError {",
                    "throw CancellationError()",
                    "} catch let error as RegexPatternFailure {",
                    "} catch let error as PCRE2Error {",
                    "} catch {"
                ]
            )
        }

        func testAdmissionDebugControlsRemainIdleOnlyAggregateBoundedAndPrivacySafe() throws {
            let coordinator = try source("Sources/RepoPrompt/Features/Search/StoreBackedWorkspaceSearchLane.swift")
            XCTAssertTrue(coordinator.contains("snapshotForTesting"))
            XCTAssertTrue(coordinator.contains("configureForTesting"))
            XCTAssertTrue(coordinator.contains("resetConfigurationForTesting"))
            XCTAssertTrue(coordinator.contains("activeLeaseIDs.isEmpty, waiterStatesByID.isEmpty"))
            XCTAssertTrue(coordinator.contains("let enqueuedAt = clock.now()"))
            XCTAssertTrue(coordinator.contains("maximumActivePermitCount"))
            XCTAssertTrue(coordinator.contains("maximumWaiterCount"))
            XCTAssertFalse(coordinator.contains("static let shared"))
            XCTAssertFalse(coordinator.contains("ObjectIdentifier"))

            let sibling = try source("Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift")
            XCTAssertTrue(sibling.contains("\"overload_count\": entries.reduce"))
            XCTAssertTrue(sibling.contains("\"wait_expiry_count\": entries.reduce"))
            XCTAssertTrue(sibling.contains("\"queued_cancellation_count\": entries.reduce"))
            XCTAssertTrue(sibling.contains("\"lanes\": entries.map"))
            XCTAssertTrue(sibling.contains("\"active_count\": entry.snapshot.activePermitCount"))
            XCTAssertTrue(sibling.contains("\"queued_count\": entry.snapshot.waiterCount"))
            XCTAssertFalse(sibling.contains("store_identifier"))
            XCTAssertFalse(sibling.contains("workspace_name"))

            let contentLoading = try source("Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+ContentLoading.swift")
            XCTAssertTrue(contentLoading.contains("struct Snapshot: Equatable"))
            XCTAssertTrue(contentLoading.contains("activePermitCount == 0 && queuedWaiterCount == 0 && ownerLaneCount == 0"))
            XCTAssertTrue(contentLoading.contains("maxQueuedWaiterCount: 512"))
            XCTAssertTrue(contentLoading.contains("ContentReadSchedulerError.queueFull"))
            XCTAssertFalse(contentLoading.contains("ObjectIdentifier"))
            XCTAssertTrue(sibling.contains("\"active_permit_count\": activePermitCount"))
            XCTAssertTrue(sibling.contains("\"queued_waiter_count\": queuedWaiterCount"))
            XCTAssertTrue(sibling.contains("\"owner_lane_count\": ownerLaneCount"))
            XCTAssertTrue(sibling.contains("\"grant_count\": grantCount"))
        }

        func testReadSearchBarrierDiagnosticsExposeBoundedPendingSuccessorState() throws {
            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            for hook in [
                "ScopedIngressBarrierRootFlightState",
                "ScopedIngressBarrierPendingFlight",
                "scopedIngressBarrierFlightStatesByRootID",
                "scopedIngressBarrierCoalescedSuccessorCountsByRootID",
                "flightState.pending = ScopedIngressBarrierPendingFlight(",
                "pending.target = pending.target.merging(target)",
                "flightState.active?.task?.cancel()",
                "flightState.pending?.join.complete(with: nil)"
            ] {
                XCTAssertTrue(store.contains(hook), "Missing bounded barrier-state hook: \(hook)")
            }
            XCTAssertFalse(store.contains("scopedIngressBarrierFlightsByRootID"))

            let diagnostics = try source(
                "Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift"
            )
            XCTAssertTrue(diagnostics.contains("\"coalesced_successor_count\": snapshot.coalescedSuccessorCount"))
            XCTAssertTrue(diagnostics.contains("\"pending\": Self.debugOptionalValue(pending)"))
            XCTAssertTrue(diagnostics.contains("target_service_publication_sequence"))
            XCTAssertTrue(diagnostics.contains("\"age_ms\": pending.ageMilliseconds"))
        }

        func testLifecycleSourceOrderCoversDispatchRunToolAndIngressBoundaries() throws {
            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            assertSourceOrder(
                in: manager,
                hooks: [
                    "EditFlowPerf.Lifecycle.MCPToolCall.received",
                    "EditFlowPerf.Lifecycle.MCPToolCall.routingSnapshotCompleted",
                    "EditFlowPerf.Lifecycle.MCPToolCall.limiterWaitBegan",
                    "return await self.withConnectionCallPermit(",
                    "EditFlowPerf.Lifecycle.MCPToolCall.limiterAcquired",
                    "Self.withConnectionID(connectionID, lifecycleCorrelation: lifecycleCorrelation)"
                ]
            )
            XCTAssertEqual(manager.components(separatedBy: "EditFlowPerf.Lifecycle.MCPToolCall.completionObserverReturned").count - 1, 5)

            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            assertSourceOrder(
                in: viewModel,
                hooks: [
                    "EditFlowPerf.Lifecycle.MCPRunTool.preflushBegan",
                    "awaitAppliedIngressForAllRoots()",
                    "EditFlowPerf.Lifecycle.MCPRunTool.preflushEnded",
                    "EditFlowPerf.Lifecycle.MCPRunTool.registrationScheduled",
                    "EditFlowPerf.Lifecycle.MCPRunTool.registrationMainActorEntered",
                    "EditFlowPerf.Lifecycle.MCPRunTool.providerBegan",
                    "EditFlowPerf.Lifecycle.MCPRunTool.providerEnded",
                    "EditFlowPerf.Lifecycle.MCPRunTool.cleanupScheduled",
                    "EditFlowPerf.Lifecycle.MCPRunTool.cleanupMainActorEntered",
                    "EditFlowPerf.Lifecycle.MCPRunTool.cleanupEnded",
                    "EditFlowPerf.Lifecycle.MCPRunTool.returned"
                ]
            )
            XCTAssertTrue(viewModel.contains("EditFlowPerf.Lifecycle.MCPRunTool.unregister"))
            XCTAssertTrue(viewModel.contains("EditFlowPerf.Lifecycle.MCPRunTool.idleWaitersResumed"))

            let fileSystemService = try source("Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService.swift")
            let fileSystem = try source("Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+FSEvents.swift")
            assertSourceOrder(
                in: fileSystem,
                hooks: [
                    "watcherIngressMailbox.accept(",
                    "EditFlowPerf.Lifecycle.FileSystem.callbackAccepted",
                    "func drainAcceptedWatcherIngressMailbox()",
                    "EditFlowPerf.Lifecycle.FileSystem.serviceEnqueueEntered",
                    "watcherAcceptedWatermark: publishableWatcherWatermark"
                ]
            )

            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            assertSourceOrder(
                in: store,
                hooks: [
                    "EditFlowPerf.Lifecycle.WorkspaceIngress.storeSinkScheduled",
                    "publisherIngressCoordinator.accept("
                ]
            )
            XCTAssertTrue(store.contains("EditFlowPerf.Lifecycle.WorkspaceIngress.storeSinkBegan"))
            XCTAssertTrue(store.contains("handleObservedFileSystemDeltas("))
            XCTAssertTrue(store.contains("EditFlowPerf.Lifecycle.WorkspaceIngress.storeCanonicalApplyCompleted"))
            XCTAssertTrue(store.contains("EditFlowPerf.Lifecycle.WorkspaceIngress.rootFlushBegan"))
            XCTAssertTrue(store.contains("EditFlowPerf.Lifecycle.WorkspaceIngress.rootFlushEnded"))
            XCTAssertTrue(store.contains("ingressSequence: publication.watcherAcceptedWatermark?.rawValue"))
            XCTAssertTrue(store.contains("barrierSequence: publication.servicePublicationSequence"))
            XCTAssertTrue(fileSystemService.contains("ingressSequence: watcherAcceptedWatermark?.rawValue"))
            XCTAssertTrue(fileSystemService.contains("barrierSequence: servicePublicationSequence"))
        }

        func testRuntimeRegistrationsSelectExplicitFreshnessPoliciesAndKeepAggressiveRefreshOptIn() throws {
            let runtime = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolRuntime.swift")
            XCTAssertTrue(runtime.contains("enum MCPToolFreshnessPolicy"))
            XCTAssertTrue(runtime.contains("freshnessPolicy: MCPToolFreshnessPolicy"))
            XCTAssertFalse(runtime.contains("freshnessPolicy: MCPToolFreshnessPolicy ="))
            XCTAssertFalse(runtime.contains("flushFS"))

            let providerPaths = [
                "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAgentControlToolProvider.swift",
                "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAgentSessionControlToolProvider.swift",
                "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPApplyEditsToolProvider.swift",
                "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAskUserToolProvider.swift",
                "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPContextBuilderToolProvider.swift",
                "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift",
                "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPGitToolProvider.swift",
                "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPOracleToolProvider.swift",
                "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPPromptContextToolProvider.swift",
                "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPSelectionToolProvider.swift",
                "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWorktreeToolProvider.swift"
            ]
            let providers = try providerPaths.map(source).joined(separator: "\n")
            let registrationCount = providers.components(separatedBy: "runtime.tool(").count - 1
            let freshnessPolicyCount = providers.components(separatedBy: "freshnessPolicy:").count - 1
            XCTAssertEqual(registrationCount, 23)
            XCTAssertEqual(freshnessPolicyCount, registrationCount)
            XCTAssertFalse(providers.contains("freshnessPolicy: .allLoadedAggressive"))

            let server = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            assertSourceOrder(
                in: server,
                hooks: [
                    "let readableService = WorkspaceReadableFileService(store: store)",
                    "let roots = await store.rootRefs(scope: lookupRootScope)",
                    "try await readableService.awaitFreshnessForExplicitRequest(path, rootRefs: roots)",
                    "await readableService.resolveReadFileRequest("
                ]
            )
            let search = try source("Sources/RepoPrompt/Features/Search/StoreBackedWorkspaceSearch.swift")
            assertSourceOrder(
                in: search,
                hooks: [
                    "let appliedIngressSamples = await store.awaitAppliedIngress(rootScope: rootScope)",
                    "let contentFreshnessPolicy = await store.contentSearchFreshnessPolicy(",
                    "switch await store.searchCatalogAccess(rootScope: rootScope)"
                ]
            )
            let workspaceFiles = try source("Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift")
            XCTAssertEqual(workspaceFiles.components(separatedBy: "awaitAppliedIngressForAllRoots()").count - 1, 2)
        }

        func testReadFileWI7CacheFreshnessAndRequestReuseBoundariesRemainExplicit() throws {
            let cache = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceInteractiveReadCache.swift")
            XCTAssertTrue(cache.contains("rootLifetimeID: UUID"))
            XCTAssertTrue(cache.contains("fingerprint: FileContentFingerprint"))
            XCTAssertTrue(cache.contains("invalidationEpoch: UInt64"))
            XCTAssertTrue(cache.contains("maxEstimatedCost: Int = 64 * 1024 * 1024"))
            XCTAssertTrue(cache.contains("Task.detached(priority: priority)"))

            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            XCTAssertTrue(store.contains("completedScopedIngressBarrierCutsByRootID"))
            XCTAssertTrue(store.contains("applied.appliedWatcherWatermark >= target.watcherAcceptedWatermark"))
            XCTAssertTrue(store.contains("applied.appliedServicePublicationSequence >= target.acceptedServicePublicationSequence"))
            XCTAssertTrue(store.contains("interactiveReadCache.invalidate(searchContentInvalidations)"))
            XCTAssertTrue(store.contains("rootLifetimeID: state.lifetimeID"))

            let server = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            XCTAssertTrue(server.contains("MCPReadFileToolProjection.makeBaseReply"))
            XCTAssertFalse(server.contains("WorkspaceInteractiveReadProcessor.sliceOffActor"))
            XCTAssertFalse(server.contains("String.splitContentPreservingAllLineEndings(full)"))

            let tabContext = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+TabContext.swift")
            let lookupStart = try XCTUnwrap(tabContext.range(of: "    func resolveFileToolLookupContext(\n"))
            let lookupEnd = try XCTUnwrap(tabContext.range(
                of: "    @MainActor\n    func materializeWorkspaceBindingProjection",
                range: lookupStart.upperBound ..< tabContext.endIndex
            ))
            let lookupContext = String(tabContext[lookupStart.lowerBound ..< lookupEnd.lowerBound])
            XCTAssertTrue(lookupContext.contains("let purpose = metadata.runPurpose ?? .unknown"))
            XCTAssertFalse(lookupContext.contains("ServerNetworkManager.shared.runPurpose"))
        }

        func testGitProviderKeepsWI5ResolutionBuildAndIngressNarrowing() throws {
            let provider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPGitToolProvider.swift")
            XCTAssertEqual(
                provider.components(separatedBy: "workspaceFileContextStore.rootRefs(scope: lookupContext.rootScope)").count - 1,
                1
            )
            XCTAssertTrue(provider.contains("MCPGitRequestContext(rootRefs: visibleRoots, vcsService: vcsService)"))
            XCTAssertFalse(provider.contains("resolveDefaultGitRepo"))
            let repoKeyBranch = try XCTUnwrap(provider.range(of: "if let repoKey = args[\"repo_key\"]"))
            let defaultResolution = try XCTUnwrap(provider.range(of: "guard let defaultRepo = allRepos.first"))
            XCTAssertLessThan(repoKeyBranch.lowerBound, defaultResolution.lowerBound)
            XCTAssertFalse(provider.contains("awaitAppliedIngress(rootScope: .visibleWorkspacePlusGitData)"))
            XCTAssertEqual(
                provider.components(separatedBy: "awaitAppliedIngressForExplicitRequest(").count - 1,
                2
            )

            let publisher = try source("Sources/RepoPrompt/Infrastructure/VCS/GitDiff/GitDiffSnapshotPublisher.swift")
            XCTAssertEqual(publisher.components(separatedBy: "engine.buildSnapshotInputs(").count - 1, 1)
            XCTAssertTrue(publisher.contains("generateDiffText: mode != .quick"))

            let selection = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+SelectionEngine.swift")
            XCTAssertTrue(selection.contains("rootScope: WorkspaceLookupRootScope = .visibleWorkspacePlusGitData"))
        }

        func testFileSystemChangePublisherSendsRemainCentralized() throws {
            let service = try source("Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService.swift")
            let fsevents = try source("Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+FSEvents.swift")
            let operations = try source("Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+FileOperations.swift")

            XCTAssertTrue(service.contains("source: FileSystemDeltaPublicationSource"))
            XCTAssertEqual(service.components(separatedBy: "changePublisher.send(publication)").count - 1, 3)
            XCTAssertFalse(fsevents.contains("changePublisher.send"))
            XCTAssertFalse(operations.contains("changePublisher.send"))
            XCTAssertTrue(fsevents.contains("source: .watcherBarrierNoop"))
            XCTAssertTrue(fsevents.contains("watcherAcceptedWatermark: publishableWatcherWatermark"))
            let mutationPublicationCount = operations.components(separatedBy: "publishFileSystemDeltas(").count - 1
            let syntheticMutationSourceCount = operations.components(separatedBy: "source: .syntheticMutation").count - 1
            XCTAssertGreaterThan(mutationPublicationCount, 0)
            XCTAssertEqual(syntheticMutationSourceCount, mutationPublicationCount)
        }

        func testCancellationSafeReadAutoSelectionDrainResultsArePropagated() throws {
            let coordinator = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPReadFileAutoSelectionCoordinator.swift")
            let server = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            let tabContext = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+TabContext.swift")
            let contextBuilder = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPContextBuilderToolProvider.swift")
            let promptContext = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPPromptContextToolProvider.swift")

            XCTAssertTrue(coordinator.contains("enum DrainResult: Equatable"))
            XCTAssertTrue(coordinator.contains("async -> DrainResult"))
            XCTAssertTrue(server.contains("executeAskOracle"))
            XCTAssertTrue(server.contains("executeOracleSend"))
            XCTAssertEqual(server.components(separatedBy: "guard await drainReadFileAutoSelection(").count - 1, 2)
            XCTAssertTrue(contextBuilder.contains("drainReadFileAutoSelection(metadata, .mirroredSelectionAndMetrics) == .completed else"))
            XCTAssertEqual(promptContext.components(separatedBy: "drainReadFileAutoSelection(metadata, .mirroredSelectionAndMetrics) == .completed else").count - 1, 2)
            XCTAssertTrue(tabContext.contains("if finishResult == .cancelled"))
            XCTAssertTrue(tabContext.contains("shouldCommit = false"))
        }

        @MainActor
        private func cleanupRuntimePendingBarrierTest(
            store: WorkspaceFileContextStore,
            rootID: UUID,
            watcherStartGate: MCPDiagnosticsGate,
            flushGate: MCPDiagnosticsGate,
            watcherStartTask: Task<Void, Error>,
            activeBarrier: Task<[WorkspaceIngressBarrierSample], Never>,
            pendingBarrier: Task<[WorkspaceIngressBarrierSample], Never>?,
            coalescedBarrier: Task<[WorkspaceIngressBarrierSample], Never>?
        ) async {
            await flushGate.release()
            activeBarrier.cancel()
            pendingBarrier?.cancel()
            coalescedBarrier?.cancel()
            _ = await activeBarrier.value
            _ = await pendingBarrier?.value
            _ = await coalescedBarrier?.value
            await store.setScopedIngressBarrierWillFlushHandler(nil)
            await store.setWatcherServiceStateWillReconcileHandler(nil)
            await watcherStartGate.release()
            _ = try? await watcherStartTask.value
            await store.stopWatchingRoot(id: rootID)
        }

        private actor MCPDiagnosticsGate {
            private var started = false
            private var released = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func markStartedAndWaitForRelease() async {
                started = true
                let pendingStartWaiters = startWaiters
                startWaiters.removeAll()
                pendingStartWaiters.forEach { $0.resume() }
                guard !released else { return }
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }

            func waitUntilStarted() async {
                guard !started else { return }
                await withCheckedContinuation { continuation in
                    startWaiters.append(continuation)
                }
            }

            func release() {
                released = true
                let pendingReleaseWaiters = releaseWaiters
                releaseWaiters.removeAll()
                pendingReleaseWaiters.forEach { $0.resume() }
            }
        }

        private actor MCPDiagnosticsSignal {
            private var marked = false

            func mark() {
                marked = true
            }

            func isMarked() -> Bool {
                marked
            }
        }

        private actor MCPDiagnosticsSnapshotSignal {
            typealias Snapshot = AsyncLimiter.DebugSnapshot
            private var latest: Snapshot?
            private var waiter: (
                predicate: @Sendable (Snapshot) -> Bool,
                continuation: CheckedContinuation<Snapshot, Never>
            )?

            func record(_ snapshot: Snapshot) {
                latest = snapshot
                guard let waiter, waiter.predicate(snapshot) else { return }
                self.waiter = nil
                waiter.continuation.resume(returning: snapshot)
            }

            func waitUntil(
                _ predicate: @escaping @Sendable (Snapshot) -> Bool
            ) async -> Snapshot {
                if let latest, predicate(latest) { return latest }
                return await withCheckedContinuation { continuation in
                    waiter = (predicate, continuation)
                }
            }
        }

        private final class LockedMCPDiagnosticsClock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64

            init(nowNanoseconds: UInt64) {
                value = nowNanoseconds
            }

            func now() -> UInt64 {
                lock.lock()
                defer { lock.unlock() }
                return value
            }

            func advance(milliseconds: UInt64) {
                lock.lock()
                value &+= milliseconds * 1_000_000
                lock.unlock()
            }
        }

        private final class LockedCorrelationIDs: @unchecked Sendable {
            private let lock = NSLock()
            private var sinkID: UUID?
            private var childTaskID: UUID?

            func recordSink(_ id: UUID?) {
                lock.lock()
                sinkID = id
                lock.unlock()
            }

            func recordChildTask(_ id: UUID?) {
                lock.lock()
                childTaskID = id
                lock.unlock()
            }

            func snapshot() -> (sink: UUID?, childTask: UUID?) {
                lock.lock()
                defer { lock.unlock() }
                return (sinkID, childTaskID)
            }
        }

        @MainActor
        func testWI8ProviderProjectionWorkerRunsOffMainActorAndEmitsHandoffTimeline() async throws {
            _ = startedCapture(label: "wi8-provider-projection", maxSamples: 100)
            let identity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string("wi8"),
                connectionID: UUID().uuidString,
                connectionGeneration: 1,
                requestOrdinal: 1
            )
            let correlation = try XCTUnwrap(
                EditFlowPerf.makeLifecycleCorrelationIfActive(requestIdentity: identity)
            )

            let workerRanOnMainThread = try await EditFlowPerf.$currentLifecycleCorrelation.withValue(correlation) {
                try await MCPProviderProjectionWorker.run(
                    toolName: MCPWindowToolName.git,
                    phase: "test_projection"
                ) {
                    let ranOnMainThread = Thread.isMainThread
                    Thread.sleep(forTimeInterval: 0.02)
                    return ranOnMainThread
                }
            }
            XCTAssertFalse(workerRanOnMainThread)

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let handoffEvents = snapshot.lifecycleEvents.filter {
                $0.sanitizedDimensions.contains("outcome=test_projection")
            }
            XCTAssertEqual(handoffEvents.map(\.eventName), [
                "MCP.ToolCall.MainActorScheduled",
                "MCP.ToolCall.MainActorEntered",
                "MCP.ToolCall.MainActorExited",
                "MCP.ToolCall.MainActorScheduled",
                "MCP.ToolCall.MainActorEntered",
                "MCP.ToolCall.MainActorExited"
            ])
            XCTAssertTrue(handoffEvents.prefix(3).allSatisfy {
                $0.sanitizedDimensions.contains("observerType=provider_projection_capture")
            })
            XCTAssertTrue(handoffEvents.suffix(3).allSatisfy {
                $0.sanitizedDimensions.contains("observerType=provider_projection_resume")
            })
            let workerStage = try XCTUnwrap(snapshot.stages.first {
                $0.stageName == "EditFlow.MCPProviderProjection.WorkerBody"
            })
            XCTAssertEqual(workerStage.sanitizedDimensions, "tool=git outcome=test_projection")
            XCTAssertGreaterThanOrEqual(workerStage.p50MS, 10)
            XCTAssertGreaterThanOrEqual(
                handoffEvents[3].offsetMS - handoffEvents[2].offsetMS,
                10,
                "Worker body time must fall after MainActor exit and before resume scheduling"
            )
        }

        @MainActor
        func testWI8GitAndReadProjectionPreserveDTOContents() async throws {
            let patch = """
            diff --git a/Sample.swift b/Sample.swift
            --- a/Sample.swift
            +++ b/Sample.swift
            @@ -1,1 +1,1 @@
            -old
            +new
            """
            let changedFiles = [
                VCSUncommittedFile(path: "Sample.swift", status: "M", additions: 1, deletions: 1)
            ]
            let diff = try await MCPGitToolProjection.makeDiffDTO(
                compare: "uncommitted",
                detail: "patches",
                changedFiles: changedFiles,
                perFilePatches: ["Sample.swift": patch],
                maxLinesForPatches: 100
            )
            XCTAssertEqual(diff.totals, .init(files: 1, insertions: 1, deletions: 1))
            XCTAssertEqual(diff.byStatus, ["M": 1])
            XCTAssertEqual(diff.files?.first?.path, "Sample.swift")
            XCTAssertEqual(diff.files?.first?.hunks?.first?.oldStart, 1)
            XCTAssertEqual(diff.files?.first?.hunks?.first?.newStart, 1)
            XCTAssertEqual(diff.truncated, false)

            let prepared = WorkspaceInteractiveReadProcessor.prepare("one\r\ntwo\nthree")
            let read = try await MCPReadFileToolProjection.makeBaseReply(
                preparedContent: prepared,
                startLine1Based: 2,
                lineCount: 1,
                displayPath: "Sample.txt"
            )
            XCTAssertEqual(read.reply.content, "two\n")
            XCTAssertEqual(read.reply.totalLines, 3)
            XCTAssertEqual(read.reply.firstLine, 2)
            XCTAssertEqual(read.reply.lastLine, 2)
            XCTAssertEqual(read.returnedLineCount, 1)
        }

        func testWI8ProviderProjectionHeavyWorkStaysOutOfMainActorProviders() throws {
            let worker = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPProviderProjectionWorker.swift")
            XCTAssertTrue(worker.contains("Task.detached(priority: priority)"))
            XCTAssertGreaterThanOrEqual(worker.components(separatedBy: "mainActorScheduled").count - 1, 2)
            XCTAssertGreaterThanOrEqual(worker.components(separatedBy: "mainActorEntered").count - 1, 2)
            XCTAssertGreaterThanOrEqual(worker.components(separatedBy: "mainActorExited").count - 1, 2)

            let gitProvider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPGitToolProvider.swift")
            for forbidden in [
                "GitService.splitUnifiedDiffByFile",
                "GitDiffPatchParsing.parseHunks",
                "GitDiffPatchParsing.truncatePatches",
                "String(contentsOf: mapURL",
                "try Value(executeGitTool"
            ] {
                XCTAssertFalse(gitProvider.contains(forbidden), "Git provider retained MainActor work: \(forbidden)")
            }
            for handoff in [
                "MCPGitToolProjection.makeShowDTO",
                "MCPGitToolProjection.makeDiffDTO",
                "MCPGitToolProjection.makeArtifactProjection",
                "MCPGitToolProjection.decorateArtifactRepoResults",
                "MCPProviderProjectionWorker.encode("
            ] {
                XCTAssertTrue(gitProvider.contains(handoff), "Missing Git worker handoff: \(handoff)")
            }

            let gitProjection = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPGitToolProjection.swift")
            for workerBody in [
                "GitService.splitUnifiedDiffByFile",
                "GitDiffPatchParsing.parseHunks",
                "GitDiffPatchParsing.truncatePatches",
                "String(contentsOf: mapURL",
                "GitDiffMapBuilder.inlineExcerpt"
            ] {
                XCTAssertTrue(gitProjection.contains(workerBody), "Missing Git worker computation: \(workerBody)")
            }

            let fileProvider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            assertSourceOrder(
                in: fileProvider,
                hooks: [
                    "MCPReadFileToolProjection.projectReply",
                    "await dependencies.enqueueReadFileAutoSelection",
                    "MCPProviderProjectionWorker.encode("
                ]
            )
            XCTAssertFalse(fileProvider.contains("try Value(readResult.reply)"))

            let server = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            XCTAssertTrue(server.contains("MCPReadFileToolProjection.makeBaseReply"))
            XCTAssertFalse(server.contains("WorkspaceInteractiveReadProcessor.sliceOffActor"))
        }

        private func assertSourceOrder(
            in source: String,
            hooks: [String],
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            var searchStart = source.startIndex
            for hook in hooks {
                guard let match = source.range(of: hook, range: searchStart ..< source.endIndex) else {
                    XCTFail("Missing or out-of-order hook: \(hook)", file: file, line: line)
                    return
                }
                searchStart = match.upperBound
            }
        }

        private func startedCapture(label: String, maxSamples: Int) -> EditFlowPerf.DebugCaptureSnapshot {
            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: maxSamples) {
            case let .started(snapshot):
                return snapshot
            case .busy:
                XCTFail("Capture should start.")
                fatalError("Capture should start.")
            }
        }

        private func assertPermittedLabel(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            XCTAssertLessThanOrEqual(value.unicodeScalars.count, 64, file: file, line: line)
            XCTAssertTrue(value.unicodeScalars.allSatisfy(allowed.contains), "Unexpected unsafe label: \(value)", file: file, line: line)
        }

        private func debugDiagnosticsPayload(_ result: CallTool.Result) throws -> [String: Any] {
            let text = result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined()
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        private func diagnosticsSource() throws -> String {
            let root = try RepoRoot.url()
            let directory = root.appendingPathComponent("Sources/RepoPrompt/Features/Diagnostics/MCP")
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("MCPConnectionManager+DebugDiagnostics") && $0.pathExtension == "swift" }
                .map { try String(contentsOf: $0, encoding: .utf8) }
                .joined(separator: "\n")
        }

        private func source(_ relativePath: String) throws -> String {
            try String(contentsOf: RepoRoot.url().appendingPathComponent(relativePath), encoding: .utf8)
        }
    }
#endif
