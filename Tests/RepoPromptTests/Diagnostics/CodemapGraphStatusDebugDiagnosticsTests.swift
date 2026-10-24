import RepoPromptSettingsCore
#if DEBUG
    import Foundation
    import MCP
    @testable import RepoPromptApp
    import XCTest

    @MainActor
    final class CodemapGraphStatusDebugDiagnosticsTests: XCTestCase {
        override func setUp() {
            super.setUp()
            GlobalSettingsStore.installApplicationModelIdentityPolicy()
        }

        func testOperationAttachesToCurrentWindowWorkspaceWithoutArm() async throws {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            await window.workspaceManager.awaitInitialized()
            addTeardownBlock { @MainActor in
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }

            let result = await ServerNetworkManager.shared.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("codemap_graph_status"),
                    "window_id": .int(window.windowID),
                    "include_events": .bool(true),
                    "event_limit": .int(8)
                ]
            )
            let payload = try diagnosticsPayload(result)
            XCTAssertEqual(payload["ok"] as? Bool, true)
            XCTAssertEqual(payload["op"] as? String, "codemap_graph_status")
            XCTAssertEqual((payload["schema_version"] as? NSNumber)?.intValue, 1)
            XCTAssertEqual((payload["window_id"] as? NSNumber)?.intValue, window.windowID)
            XCTAssertNotNil(payload["roots"] as? [[String: Any]])
            XCTAssertNotNil(payload["totals"] as? [String: Any])
            let storeEvents = try XCTUnwrap(payload["store_events"] as? [String: Any])
            XCTAssertNotNil(storeEvents["next_ordinal"])

            let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
            var pageMeasurement = WorkspaceCodemapManifestMeasurementAggregate()
            pageMeasurement.loadCount = 2
            pageMeasurement.submissionCount = 2
            pageMeasurement.waitCount = 2
            pageMeasurement.storeAttemptCount = 2
            pageMeasurement.writeCount = 2
            pageMeasurement.mutationCountVolume = 2
            pageMeasurement.mutationByteVolume = 128
            pageMeasurement.inputSnapshotRecordVolume = 1
            pageMeasurement.outputSnapshotRecordVolume = 3
            pageMeasurement.inputSnapshotByteVolume = 256
            pageMeasurement.attemptedOutputSnapshotRecordVolume = 3
            pageMeasurement.attemptedOutputSnapshotByteVolume = 768
            pageMeasurement.outputSnapshotByteVolume = 768
            pageMeasurement.atomicReplaceDurationNanoseconds = 11
            pageMeasurement.temporaryFileSyncDurationNanoseconds = 12
            pageMeasurement.manifestDirectorySyncDurationNanoseconds = 13
            let stablePayload = CodemapGraphStatusDebugSupport.payload(
                snapshot: CodemapGraphStatusSnapshot(
                    sampledUptimeNanoseconds: 1,
                    roots: [CodemapGraphStatusRootSnapshot(
                        rootEpoch: rootEpoch,
                        catalogGeneration: 0,
                        ingressGeneration: 0,
                        rootKind: .primaryWorkspace,
                        eligibilityFlightPresent: false,
                        launch: nil,
                        job: nil,
                        admission: nil,
                        manifest: CodemapGraphStatusManifestSnapshot(
                            failureCounts: [.staleAuthority: 3],
                            lastFailure: WorkspaceCodemapManifestFailureDiagnostic(
                                reason: .staleAuthority,
                                operation: nil,
                                currentAuthorityGeneration: 4,
                                observedPredecessorAuthorityGeneration: 7,
                                attemptStartedUptimeNanoseconds: 10,
                                attemptCompletedUptimeNanoseconds: 25,
                                attemptDurationNanoseconds: 15
                            ),
                            measurements: WorkspaceCodemapManifestMeasurementSnapshot(
                                byOrigin: [.page: pageMeasurement]
                            )
                        ),
                        milestones: [],
                        engineEvents: WorkspaceCodemapGraphIndexDebugEventPage(
                            events: [],
                            firstOrdinal: 0,
                            lastOrdinal: 0,
                            nextOrdinal: nil
                        )
                    )],
                    storeEvents: nil,
                    graphIndexJobCount: 0,
                    queuedGraphIndexBatchCount: 0,
                    activeGraphIndexBatchCount: 0,
                    drainingGraphIndexTaskCount: 0
                ),
                op: "codemap_graph_status",
                windowID: window.windowID,
                workspaceID: nil
            )
            let enginePages = try XCTUnwrap(stablePayload["engine_events"] as? [[String: Any]])
            XCTAssertNotNil(try XCTUnwrap(enginePages.first)["next_ordinal"])
            let roots = try XCTUnwrap(stablePayload["roots"] as? [[String: Any]])
            let manifest = try XCTUnwrap(try XCTUnwrap(roots.first)["manifest"] as? [String: Any])
            XCTAssertTrue(manifest["writers"] is NSNull)
            let counts = try XCTUnwrap(manifest["failure_counts"] as? [String: Any])
            XCTAssertEqual((counts["staleAuthority"] as? NSNumber)?.uint64Value, 3)
            let lastFailure = try XCTUnwrap(manifest["last_failure"] as? [String: Any])
            XCTAssertEqual(lastFailure["reason"] as? String, "staleAuthority")
            XCTAssertEqual((lastFailure["current_authority_generation"] as? NSNumber)?.uint64Value, 4)
            XCTAssertEqual(
                (lastFailure["observed_predecessor_authority_generation"] as? NSNumber)?.uint64Value,
                7
            )
            XCTAssertEqual((lastFailure["attempt_duration_ns"] as? NSNumber)?.uint64Value, 15)
            let measurements = try XCTUnwrap(manifest["measurements"] as? [String: Any])
            let page = try XCTUnwrap(measurements["page"] as? [String: Any])
            XCTAssertEqual((page["load_count"] as? NSNumber)?.uint64Value, 2)
            XCTAssertEqual((page["submission_count"] as? NSNumber)?.uint64Value, 2)
            XCTAssertEqual((page["wait_count"] as? NSNumber)?.uint64Value, 2)
            XCTAssertEqual((page["store_attempt_count"] as? NSNumber)?.uint64Value, 2)
            XCTAssertEqual((page["write_count"] as? NSNumber)?.uint64Value, 2)
            XCTAssertEqual((page["mutation_count_volume"] as? NSNumber)?.uint64Value, 2)
            XCTAssertEqual((page["mutation_byte_volume"] as? NSNumber)?.uint64Value, 128)
            XCTAssertEqual((page["input_snapshot_record_volume"] as? NSNumber)?.uint64Value, 1)
            XCTAssertEqual((page["output_snapshot_record_volume"] as? NSNumber)?.uint64Value, 3)
            XCTAssertEqual((page["input_snapshot_byte_volume"] as? NSNumber)?.uint64Value, 256)
            XCTAssertEqual(
                (page["attempted_output_snapshot_record_volume"] as? NSNumber)?.uint64Value,
                3
            )
            XCTAssertEqual(
                (page["attempted_output_snapshot_byte_volume"] as? NSNumber)?.uint64Value,
                768
            )
            XCTAssertEqual((page["output_snapshot_byte_volume"] as? NSNumber)?.uint64Value, 768)
            XCTAssertEqual((page["atomic_replace_duration_ns"] as? NSNumber)?.uint64Value, 11)
            XCTAssertEqual((page["temporary_file_sync_duration_ns"] as? NSNumber)?.uint64Value, 12)
            XCTAssertEqual(
                (page["manifest_directory_sync_duration_ns"] as? NSNumber)?.uint64Value,
                13
            )
        }

        func testManifestWriterSerializationKeepsPartialRootScopeUnknown() throws {
            let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
            let otherRootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
            let engineID = UUID()
            let workspaceID = UUID()
            let writerID = UUID()
            let batchID = UUID()
            let cases = [
                (name: "capped busy engine", complete: true, quiet: false, capped: true),
                (name: "empty incomplete accounting", complete: false, quiet: false, capped: false),
                (name: "confirmed idle engine", complete: true, quiet: true, capped: false)
            ]
            for scenario in cases {
                let tasks: [CodemapManifestWriterTaskSnapshot] = scenario.capped ? [
                    CodemapManifestWriterTaskSnapshot(
                        writerID: writerID,
                        namespaceDigest: "namespace-a",
                        rootEpoch: otherRootEpoch,
                        batchID: batchID,
                        origin: "graph_page",
                        phase: "awaiting_publication",
                        taskStartedUptimeNanoseconds: 2_000_000,
                        batchStartedUptimeNanoseconds: 4_000_000,
                        phaseStartedUptimeNanoseconds: 6_000_000
                    ),
                    CodemapManifestWriterTaskSnapshot(
                        writerID: UUID(),
                        namespaceDigest: "namespace-b",
                        rootEpoch: nil,
                        batchID: nil,
                        origin: nil,
                        phase: "scheduled",
                        taskStartedUptimeNanoseconds: 3_000_000,
                        batchStartedUptimeNanoseconds: nil,
                        phaseStartedUptimeNanoseconds: 3_000_000
                    )
                ] : []
                let namespaces: [CodemapManifestWriterQueueSnapshot] = scenario.capped ? [
                    CodemapManifestWriterQueueSnapshot(
                        namespaceDigest: "namespace-a",
                        queuedItemCount: 3,
                        deferredTailItemCount: 2,
                        deferredHeadWaitingItemCount: 1,
                        inFlightItemCount: 4,
                        retryPending: true
                    )
                ] : []
                let activity = CodemapManifestWriterActivitySnapshot(
                    engineInstanceID: engineID,
                    rootEpoch: rootEpoch,
                    sampledUptimeNanoseconds: 10_000_000,
                    liveTaskCount: scenario.capped ? 9 : 0,
                    namespaceCount: scenario.capped ? 10 : 0,
                    accountingComplete: scenario.complete,
                    quiescenceConfirmed: scenario.quiet,
                    omittedLiveTaskCount: scenario.capped ? 7 : 0,
                    tasks: tasks,
                    namespaces: namespaces,
                    omittedNamespaceCount: scenario.capped ? 9 : 0
                )
                let payload = CodemapGraphStatusDebugSupport.payload(
                    snapshot: CodemapGraphStatusSnapshot(
                        sampledUptimeNanoseconds: 10_000_000,
                        roots: [CodemapGraphStatusRootSnapshot(
                            rootEpoch: rootEpoch,
                            catalogGeneration: 0,
                            ingressGeneration: 0,
                            rootKind: .primaryWorkspace,
                            eligibilityFlightPresent: false,
                            launch: nil,
                            job: nil,
                            admission: nil,
                            manifest: CodemapGraphStatusManifestSnapshot(
                                failureCounts: [:],
                                lastFailure: nil,
                                measurements: WorkspaceCodemapManifestMeasurementSnapshot(byOrigin: [:]),
                                writerActivity: activity
                            ),
                            milestones: [],
                            engineEvents: nil
                        )],
                        storeEvents: nil,
                        graphIndexJobCount: 0,
                        queuedGraphIndexBatchCount: 0,
                        activeGraphIndexBatchCount: 0,
                        drainingGraphIndexTaskCount: 0
                    ),
                    op: "codemap_graph_status",
                    windowID: 41,
                    workspaceID: workspaceID
                )
                let encoded = try JSONSerialization.data(withJSONObject: payload)
                let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                XCTAssertEqual(decoded["window_id"] as? Int, 41, scenario.name)
                XCTAssertEqual(decoded["workspace_id"] as? String, workspaceID.uuidString, scenario.name)
                XCTAssertEqual(decoded["schema_version"] as? Int, 1, scenario.name)
                let roots = try XCTUnwrap(decoded["roots"] as? [[String: Any]])
                let manifest = try XCTUnwrap(try XCTUnwrap(roots.first)["manifest"] as? [String: Any])
                let writers = try XCTUnwrap(manifest["writers"] as? [String: Any])
                XCTAssertEqual(writers["scope"] as? String, "manifest_writer_tasks", scenario.name)
                XCTAssertEqual(writers["engine_instance_id"] as? String, engineID.uuidString, scenario.name)
                let root = try XCTUnwrap(writers["root"] as? [String: Any])
                XCTAssertEqual(root["scope"] as? String, "root_epoch", scenario.name)
                XCTAssertEqual(root["root_id"] as? String, rootEpoch.rootID.uuidString, scenario.name)
                XCTAssertEqual(root["root_lifetime_id"] as? String, rootEpoch.rootLifetimeID.uuidString, scenario.name)
                XCTAssertTrue(root["queue_item_count"] is NSNull, scenario.name)
                XCTAssertEqual(root["queue_counts_complete"] as? Bool, false, scenario.name)
                if scenario.quiet {
                    XCTAssertEqual(root["quiescence_confirmed"] as? Bool, true, scenario.name)
                } else {
                    XCTAssertTrue(root["quiescence_confirmed"] is NSNull, scenario.name)
                }
                let engine = try XCTUnwrap(writers["engine"] as? [String: Any])
                XCTAssertEqual(engine["scope"] as? String, "engine_all_root_epochs", scenario.name)
                XCTAssertEqual(engine["accounting_complete"] as? Bool, scenario.complete, scenario.name)
                XCTAssertEqual(engine["quiescence_confirmed"] as? Bool, scenario.quiet, scenario.name)
                XCTAssertEqual(engine["live_task_count"] as? Int, scenario.capped ? 9 : 0, scenario.name)
                XCTAssertEqual(engine["namespace_count"] as? Int, scenario.capped ? 10 : 0, scenario.name)
                XCTAssertEqual(engine["omitted_live_task_count"] as? Int, scenario.capped ? 7 : 0, scenario.name)
                XCTAssertEqual(engine["omitted_namespace_count"] as? Int, scenario.capped ? 9 : 0, scenario.name)
                XCTAssertEqual(engine["queue_counts_complete"] as? Bool, !scenario.capped, scenario.name)
                let serializedTasks = try XCTUnwrap(engine["tasks"] as? [[String: Any]])
                let serializedNamespaces = try XCTUnwrap(engine["namespaces"] as? [[String: Any]])
                XCTAssertEqual(serializedTasks.count, tasks.count, scenario.name)
                XCTAssertEqual(serializedNamespaces.count, namespaces.count, scenario.name)
                if scenario.capped {
                    let bound = try XCTUnwrap(serializedTasks.first)
                    XCTAssertEqual(bound["writer_id"] as? String, writerID.uuidString)
                    XCTAssertEqual(bound["batch_id"] as? String, batchID.uuidString)
                    XCTAssertEqual(bound["root_id"] as? String, otherRootEpoch.rootID.uuidString)
                    XCTAssertEqual(bound["root_lifetime_id"] as? String, otherRootEpoch.rootLifetimeID.uuidString)
                    XCTAssertEqual(bound["phase"] as? String, "awaiting_publication")
                    XCTAssertEqual(bound["origin"] as? String, "graph_page")
                    XCTAssertEqual(bound["task_started_uptime_ns"] as? UInt64, 2_000_000)
                    XCTAssertEqual(bound["task_age_ms"] as? UInt64, 8)
                    XCTAssertEqual(bound["batch_started_uptime_ns"] as? UInt64, 4_000_000)
                    XCTAssertEqual(bound["batch_age_ms"] as? UInt64, 6)
                    XCTAssertEqual(bound["phase_started_uptime_ns"] as? UInt64, 6_000_000)
                    XCTAssertEqual(bound["phase_age_ms"] as? UInt64, 4)
                    let unbound = serializedTasks[1]
                    XCTAssertTrue(unbound["root_id"] is NSNull)
                    XCTAssertTrue(unbound["root_lifetime_id"] is NSNull)
                    XCTAssertTrue(unbound["batch_id"] is NSNull)
                    XCTAssertTrue(unbound["origin"] is NSNull)
                    XCTAssertTrue(unbound["batch_started_uptime_ns"] is NSNull)
                    XCTAssertTrue(unbound["batch_age_ms"] is NSNull)
                    let queue = try XCTUnwrap(serializedNamespaces.first)
                    XCTAssertEqual(queue["queued_item_count"] as? Int, 3)
                    XCTAssertEqual(queue["deferred_tail_item_count"] as? Int, 2)
                    XCTAssertEqual(queue["deferred_head_waiting_item_count"] as? Int, 1)
                    XCTAssertEqual(queue["in_flight_item_count"] as? Int, 4)
                    XCTAssertEqual(queue["retry_pending"] as? Bool, true)
                }
            }
        }

        func testOperationRejectsInvalidRootAndEventCursorParameters() async throws {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            await window.workspaceManager.awaitInitialized()
            addTeardownBlock { @MainActor in
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            let manager = ServerNetworkManager.shared
            for var arguments: [String: Value] in [
                [
                    "op": .string("codemap_graph_status"),
                    "root_id": .string("not-a-uuid")
                ],
                [
                    "op": .string("codemap_graph_status"),
                    "since_store_ordinal": .int(-1)
                ],
                [
                    "op": .string("codemap_graph_status"),
                    "event_limit": .int(0)
                ]
            ] {
                arguments["window_id"] = .int(window.windowID)
                let result = await manager.handleDebugDiagnosticsTool(
                    connectionID: UUID(),
                    arguments: arguments
                )
                let payload = try diagnosticsPayload(result)
                XCTAssertEqual(payload["ok"] as? Bool, false)
                XCTAssertEqual(payload["op"] as? String, "codemap_graph_status")
                XCTAssertEqual(payload["code"] as? String, "invalid_params")
            }
        }

        private func diagnosticsPayload(
            _ result: CallTool.Result
        ) throws -> [String: Any] {
            let text = try XCTUnwrap(result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content {
                    return text
                }
                return nil
            }.first)
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }
#endif
