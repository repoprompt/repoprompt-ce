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
            XCTAssertNil(observers["tool_call_observer_count"])
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
