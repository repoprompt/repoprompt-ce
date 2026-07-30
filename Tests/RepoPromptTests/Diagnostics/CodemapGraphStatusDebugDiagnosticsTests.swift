#if DEBUG
    import Foundation
    import MCP
    @testable import RepoPromptApp
    import XCTest

    @MainActor
    final class CodemapGraphStatusDebugDiagnosticsTests: XCTestCase {
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
                if case let .text(text, _, _) = content { return text }
                return nil
            }.first)
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }
#endif
