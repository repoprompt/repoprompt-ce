import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

#if DEBUG
    @MainActor
    final class ContextBuilderGroupedSupervisionTests: XCTestCase {
        func testCancelledAdmissionReleasesBuilderControlForNextRoutedRun() async throws {
            try await withHarness(routed: true) { harness in
                let driver = harness.driver
                let jobs = WindowStatesManager.shared.longRunningJobs
                let context = try await driver.resolve()
                let connection = try await driver.connectInvokingAgent(context)
                let admitted = XCTestExpectation(description: "builder ticket registered before worker entry")
                let gate = driver.fixture.makeGate()
                var jobID: UUID?
                jobs.admissionDidRegister = { id in
                    jobID = id
                    admitted.fulfill()
                    await gate.wait()
                }
                defer {
                    jobs.admissionDidRegister = nil
                    gate.release()
                }
                var startError: Error?
                let starting = driver.fixture.startOwnedTask {
                    do {
                        _ = try await connection.client.callTool(name: "context_builder", arguments: [
                            "op": .string("start"), "detach": .bool(true),
                            "instructions": .string("Cancelled before discovery"), "_rawJSON": .bool(true)
                        ])
                    } catch { startError = error }
                }
                try await harness.wait(admitted)
                let id = try XCTUnwrap(jobID)
                jobs.cancel(id: id)
                jobs.admissionDidRegister = nil
                gate.release()
                await starting.value
                if let startError { throw startError }
                let cancelled = await jobs.store.wait(id: id, timeout: 5)
                XCTAssertEqual(cancelled?.status, .cancelled)
                XCTAssertEqual(driver.constructed, 0)

                // Exercise the real preparation/token acquisition again, not just the job's busy slot.
                driver.streamBody = { runID in
                    let child = try await driver.connectChild(runID: runID)
                    try await driver.discover(using: child)
                }
                let next = try await connection.client.callTool(name: "context_builder", arguments: [
                    "op": .string("start"), "timeout": .int(5),
                    "instructions": .string("Discovery after abandoned admission"), "_rawJSON": .bool(true)
                ])
                let text = next.content.compactMap { content -> String? in
                    if case let .text(text, _, _) = content { return text }
                    return nil
                }.joined(separator: "\n")
                XCTAssertNotEqual(next.isError, true, text)
                if next.isError != true {
                    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    XCTAssertEqual((fields["job"] as? [String: Any])?["status"] as? String, "completed", text)
                }
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.streamStarts, 1)
            }
        }

        func testOwningRunCancellationDuringAdmissionPreventsRoutedDiscovery() async throws {
            try await withHarness(routed: true) { harness in
                let driver = harness.driver
                let jobs = WindowStatesManager.shared.longRunningJobs
                let context = try await driver.resolve()
                let connection = try await driver.connectInvokingAgent(context)
                let runID = try XCTUnwrap(context.frozenTabContext.runID)
                let admitted = XCTestExpectation(description: "owning run has admitting ticket")
                let gate = driver.fixture.makeGate()
                var jobID: UUID?
                jobs.admissionDidRegister = { id in
                    jobID = id
                    admitted.fulfill()
                    await gate.wait()
                }
                defer {
                    jobs.admissionDidRegister = nil
                    gate.release()
                }
                driver.streamBody = { runID in
                    let child = try await driver.connectChild(runID: runID)
                    try await driver.discover(using: child)
                }
                var startError: Error?
                let starting = driver.fixture.startOwnedTask {
                    do {
                        _ = try await connection.client.callTool(name: "context_builder", arguments: [
                            "op": .string("start"), "detach": .bool(true),
                            "instructions": .string("Must not outlive cancelled owner"), "_rawJSON": .bool(true)
                        ])
                    } catch { startError = error }
                }
                try await harness.wait(admitted)
                let id = try XCTUnwrap(jobID)
                XCTAssertGreaterThan(driver.window.mcpServer.cancelActiveToolsForRun(runID: runID, reason: "admission regression"), 0)
                jobs.admissionDidRegister = nil
                gate.release()
                await starting.value
                if let startError { throw startError }
                let terminal = await jobs.store.wait(id: id, timeout: 5)
                XCTAssertEqual(terminal?.status, .cancelled)
                XCTAssertEqual(driver.constructed, 0)
                XCTAssertEqual(driver.streamStarts, 0)
                XCTAssertFalse(driver.window.mcpServer.hasActiveToolExecutions(runID: runID))
            }
        }

        func testTicketCLIExplicitContextSelectorSupportsControlsWithoutWeakeningOwnership() async throws {
            try await withHarness(routed: true) { harness in
                let driver = harness.driver
                driver.streamBody = { runID in
                    let child = try await driver.connectChild(runID: runID)
                    try await driver.discover(using: child)
                }
                await driver.window.mcpServer.startServer()
                let initiating = try await driver.connect(name: "RepoPromptCLI-selector-start", purpose: .unknown)
                @MainActor
                func call(_ connection: ContextBuilderMultiRootDiscoveryDriver.RoutedConnection, _ args: [String: Value], selector: UUID? = nil) async throws -> (content: [MCP.Tool.Content], isError: Bool?) {
                    var routed = args
                    routed["_windowID"] = .int(driver.window.windowID)
                    routed["context_id"] = .string((selector ?? driver.tabID).uuidString)
                    routed["_rawJSON"] = .bool(true)
                    let reply = try await connection.client.callTool(name: "context_builder", arguments: routed)
                    return (reply.content, reply.isError)
                }
                func payload(_ reply: (content: [MCP.Tool.Content], isError: Bool?)) throws -> [String: Any] {
                    let text = reply.content.compactMap { content -> String? in
                        if case let .text(text, _, _) = content { return text }
                        return nil
                    }.joined(separator: "\n")
                    XCTAssertNotEqual(reply.isError, true, text)
                    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                }
                let started = try await payload(call(initiating, [
                    "op": .string("start"), "detach": .bool(true),
                    "instructions": .string("Build one controlled plan"), "response_type": .string("plan"),
                    "oracle_preset": .string(harness.preset.name)
                ]))
                guard let id = started["job_id"] as? String else { return XCTFail("Valid CLI selectors must admit a job") }
                await initiating.cleanup()
                try await harness.waitForStreams()
                let reconnected = try await driver.connect(name: "RepoPromptCLI-selector-reconnect", purpose: .unknown)
                let poll = try await payload(call(reconnected, ["op": .string("poll"), "job_id": .string(id)]))
                XCTAssertEqual((poll["job"] as? [String: Any])?["status"] as? String, "running")
                XCTAssertNil(poll["plan"])
                let wait = try await payload(call(reconnected, ["op": .string("wait"), "job_id": .string(id), "timeout": .double(0)]))
                XCTAssertEqual(wait["job_id"] as? String, id)
                let wrong = try await call(reconnected, ["op": .string("cancel"), "job_id": .string(id)], selector: UUID())
                XCTAssertEqual(wrong.isError, true)
                let invoking = try await driver.connectInvokingAgent(driver.resolve())
                let wrongOwner = try await invoking.client.callTool(name: "context_builder", arguments: ["op": .string("cancel"), "job_id": .string(id)])
                XCTAssertEqual(wrongOwner.isError, true)
                XCTAssertEqual(driver.constructed, 1)
                _ = try await payload(call(reconnected, ["op": .string("cancel"), "job_id": .string(id)]))
                let terminal = try await payload(call(reconnected, ["op": .string("wait"), "job_id": .string(id), "timeout": .double(5)]))
                XCTAssertEqual((terminal["job"] as? [String: Any])?["status"] as? String, "cancelled")
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.streamStarts, 1)
            }
        }

        func testBuilderRejectsOracleRequestDiagnosticsBeforeDiscovery() async throws {
            try await withHarness(routed: true) { harness in
                let driver = harness.driver
                let context = try await driver.resolve()
                let connection = try await driver.connectInvokingAgent(context)
                for diagnostic in ["debug_primary_only", "debug_lane_timeout_seconds"] {
                    for ticketed in [false, true] {
                        var args: [String: Value] = [
                            "instructions": .string("Build one controlled plan"),
                            "response_type": .string("plan"),
                            "oracle_preset": .string(harness.preset.name),
                            diagnostic: diagnostic == "debug_primary_only" ? .bool(true) : .double(3)
                        ]
                        if ticketed { args["op"] = .string("start") }
                        let reply = try await connection.client.callTool(name: "context_builder", arguments: args)
                        XCTAssertEqual(reply.isError, true)
                        XCTAssertTrue(reply.content.contains { content in
                            if case let .text(text, _, _) = content {
                                return text.contains("Context Builder does not support Oracle request diagnostics")
                            }
                            return false
                        })
                        XCTAssertEqual(driver.constructed, 0)
                        XCTAssertEqual(driver.streamStarts, 0)
                        XCTAssertTrue(harness.registeredModels.isEmpty)
                    }
                }
            }
        }

        func testOracleRequestPrimaryOnlyDispatchesOneControlledTransport() async throws {
            try await withHarness { harness in
                let driver = harness.driver
                var context = OracleViewModel.OracleSendTabContext(
                    tabID: driver.tabID,
                    workspaceID: driver.fixture.workspace.id,
                    activationPolicy: .background,
                    packaging: .init(
                        sourceTabID: driver.tabID,
                        sourceWorkspaceID: driver.fixture.workspace.id,
                        sourceSelectionRevision: 0,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        promptText: "",
                        selection: StoredSelection(),
                        lookupContext: .visibleWorkspace,
                        reviewGitContext: .automaticOnly(),
                        provenance: .direct
                    )
                )
                context.requestDiagnostics.primaryOnly = true
                var reply: [String: Value]?
                harness.start {
                    reply = try await driver.window.oracleViewModel.tool_chatSendWithConfiguredRoster(
                        args: ["message": .string("Controlled primary-only"), "new_chat": .bool(true), "model": .string(harness.preset.name)],
                        promptVM: driver.window.oracleViewModel.promptViewModel, tabContext: context
                    )
                }
                try await harness.waitForStream(.gpt54Mini)
                harness.complete(.gpt54Mini, text: "only primary")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                XCTAssertEqual(reply?["response"], .string("only primary"))
                XCTAssertNil(reply?["oracle_group_id"])
                XCTAssertEqual(harness.registeredModels, [.gpt54Mini])
                XCTAssertEqual(harness.preset.modelStrings, [AIModel.gpt54Mini.rawValue, AIModel.gpt54.rawValue])
            }
        }

        func testOracleRequestDiagnosticDeadlineSettlesAndDrainsWithoutLateSuccess() async throws {
            try await withHarness { harness in
                let driver = harness.driver
                var context = OracleViewModel.OracleSendTabContext(
                    tabID: driver.tabID,
                    workspaceID: driver.fixture.workspace.id,
                    activationPolicy: .background,
                    packaging: .init(
                        sourceTabID: driver.tabID,
                        sourceWorkspaceID: driver.fixture.workspace.id,
                        sourceSelectionRevision: 0,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        promptText: "",
                        selection: StoredSelection(),
                        lookupContext: .visibleWorkspace,
                        reviewGitContext: .automaticOnly(),
                        provenance: .direct
                    )
                )
                context.requestDiagnostics.laneTimeout = 3
                var reply: [String: Value]?
                harness.start {
                    reply = try await driver.window.oracleViewModel.tool_chatSendWithConfiguredRoster(
                        args: ["message": .string("Controlled deadline"), "new_chat": .bool(true), "model": .string(harness.preset.name)],
                        promptVM: driver.window.oracleViewModel.promptViewModel, tabContext: context
                    )
                }
                try await harness.waitForStreams()
                harness.complete(.gpt54Mini, text: "completed primary")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                let result = try XCTUnwrap(reply?["oracle_results"]?.arrayValue)
                XCTAssertEqual(result.map { $0.objectValue?["status"]?.stringValue }, ["completed", "failed"])
                XCTAssertEqual(result[1].objectValue?["error"]?.objectValue?["code"]?.stringValue, "oracle_diagnostic_overall_timeout")
                let owner = try OracleViewModel.oracleGroupOwner(workspaceID: driver.fixture.workspace.id, tabID: driver.tabID)
                let groupID = try OracleGroupID(rawValue: XCTUnwrap(reply?["oracle_group_id"]?.stringValue.flatMap(UUID.init(uuidString:))))
                let store = AppDomainRuntimeComposition.shared.oracleConversationStore
                let loadedBefore = try await store.load(groupID: groupID, owner: owner)
                let before = try XCTUnwrap(loadedBefore)
                let delivery = harness.complete(.gpt54, text: "must not become late success")
                guard case .terminated? = delivery else { return XCTFail("Timed-out transport was not drained") }
                await Task.yield()
                let loadedAfter = try await store.load(groupID: groupID, owner: owner)
                let after = try XCTUnwrap(loadedAfter)
                XCTAssertEqual(after, before)
                XCTAssertEqual(after.turns.last?.results.map(\.status), [.completed, .failed])
                XCTAssertEqual(harness.registeredModels.count, 2)
            }
        }

        func testTicketSurvivesRoutedDisconnectAndExportsOnePipelineExactlyOnce() async throws {
            try await withHarness(routed: true) { harness in
                let driver = harness.driver
                let gate = driver.fixture.makeGate()
                let entered = XCTestExpectation(description: "ticket discovery started")
                driver.streamBody = { runID in
                    entered.fulfill()
                    await gate.wait()
                    let child = try await driver.connectChild(runID: runID)
                    try await driver.discover(using: child)
                }
                func payload(_ connection: ContextBuilderMultiRootDiscoveryDriver.RoutedConnection, _ args: [String: Value]) async throws -> [String: Any] {
                    let reply = try await connection.client.callTool(name: "context_builder", arguments: args.merging(["_rawJSON": .bool(true)]) { _, new in new })
                    let text = reply.content.compactMap { content -> String? in
                        if case let .text(text, _, _) = content { return text }
                        return nil
                    }.joined(separator: "\n")
                    XCTAssertNotEqual(reply.isError, true, text)
                    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                }
                let context = try await driver.resolve()
                let initiating = try await driver.connectInvokingAgent(context)
                let started = try await payload(initiating, [
                    "op": .string("start"), "detach": .bool(true),
                    "instructions": .string("Build one controlled plan"), "response_type": .string("plan"),
                    "oracle_preset": .string(harness.preset.name), "export_response": .bool(true)
                ])
                let jobID = try XCTUnwrap(started["job_id"] as? String)
                try await harness.wait(entered)
                await initiating.cleanup()
                let reconnected = try await driver.connectInvokingAgent(context)
                let observing = try await payload(reconnected, ["op": .string("wait"), "job_id": .string(jobID), "timeout": .double(0)])
                XCTAssertEqual(observing["job_id"] as? String, jobID)
                XCTAssertEqual((observing["job"] as? [String: Any])?["status"] as? String, "running")
                XCTAssertNil(observing["plan"])
                XCTAssertEqual(driver.constructed, 1)
                let wrongKind = try await reconnected.client.callTool(name: "ask_oracle", arguments: ["op": .string("cancel"), "job_id": .string(jobID)])
                XCTAssertEqual(wrongKind.isError, true)
                XCTAssertTrue(wrongKind.content.contains { content in
                    if case let .text(text, _, _) = content { return text.contains("belongs to a different tool") }
                    return false
                }, "The owning service rejects kind, not tool visibility")
                let otherOrigin = try await driver.connectInvokingAgent(driver.resolve())
                let wrongOwner = try await otherOrigin.client.callTool(name: "context_builder", arguments: ["op": .string("cancel"), "job_id": .string(jobID)])
                XCTAssertEqual(wrongOwner.isError, true)
                XCTAssertTrue(wrongOwner.content.contains { content in
                    if case let .text(text, _, _) = content { return text.contains("belongs to a different Agent session/run") }
                    return false
                })
                XCTAssertEqual(driver.constructed, 1, "Control authorization never enters discovery")
                gate.release()
                try await harness.waitForStreams()
                try await harness.emit(.gpt54Mini, text: "primary partial ")
                let streaming = try await payload(reconnected, ["op": .string("poll"), "job_id": .string(jobID)])
                XCTAssertFalse(String(describing: streaming).contains("primary partial"), "poll projects lane state, never response bodies")
                harness.complete(.gpt54, text: "sibling complete")
                harness.complete(.gpt54Mini, text: "primary complete")
                let terminal = try await payload(reconnected, ["op": .string("wait"), "job_id": .string(jobID), "timeout": .double(10)])
                XCTAssertEqual((terminal["job"] as? [String: Any])?["status"] as? String, "completed")
                let plan = try XCTUnwrap(terminal["plan"] as? [String: Any])
                let lanes = try XCTUnwrap(plan["oracle_results"] as? [[String: Any]])
                XCTAssertEqual(lanes.map { $0["status"] as? String }, ["completed", "completed"])
                XCTAssertEqual(lanes[0]["response"] as? String, "primary partial primary complete")
                let exportPath = try XCTUnwrap(terminal["oracle_export_path"] as? String)
                let exportURL = URL(fileURLWithPath: exportPath.hasPrefix("/") ? exportPath : driver.fixture.rootPaths[0] + "/" + exportPath)
                let exported = try Data(contentsOf: exportURL)
                XCTAssertFalse(exported.isEmpty)
                let exports = try FileManager.default.contentsOfDirectory(at: exportURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                XCTAssertEqual(exports.count(where: { $0.pathExtension == "md" }), 1)
                for op in ["poll", "wait", "cancel"] {
                    let result = try await payload(reconnected, ["op": .string(op), "job_id": .string(jobID)])
                    XCTAssertEqual(NSDictionary(dictionary: result), NSDictionary(dictionary: terminal))
                }
                XCTAssertEqual(try Data(contentsOf: exportURL), exported)
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.streamStarts, 1)
                XCTAssertEqual(driver.teardownIDs.count, 1)
                XCTAssertEqual(harness.registeredModels.count, 2)
                XCTAssertEqual(Set(harness.registeredModels), Set([.gpt54Mini, .gpt54]))
            }
        }

        func testTicketCancellationRetainsPartialFollowUpAndDrainsBothLanes() async throws {
            try await withHarness(routed: true) { harness in
                let driver = harness.driver
                driver.streamBody = { runID in
                    let child = try await driver.connectChild(runID: runID)
                    try await driver.discover(using: child)
                }
                let context = try await driver.resolve()
                let connection = try await driver.connectInvokingAgent(context)
                func call(_ args: [String: Value]) async throws -> [String: Any] {
                    let reply = try await connection.client.callTool(name: "context_builder", arguments: args.merging(["_rawJSON": .bool(true)]) { _, new in new })
                    XCTAssertNotEqual(reply.isError, true)
                    let text = reply.content.compactMap { content -> String? in
                        if case let .text(text, _, _) = content { return text }
                        return nil
                    }.joined(separator: "\n")
                    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                }
                let start = try await call(["op": .string("start"), "detach": .bool(true), "instructions": .string("Controlled cancellation"), "response_type": .string("plan"), "oracle_preset": .string(harness.preset.name), "export_response": .bool(true)])
                let id = try XCTUnwrap(start["job_id"] as? String)
                try await harness.waitForStreams()
                try await harness.emit(.gpt54Mini, text: "retained partial")
                _ = try await call(["op": .string("cancel"), "job_id": .string(id)])
                let terminal = try await call(["op": .string("wait"), "job_id": .string(id), "timeout": .double(10)])
                XCTAssertEqual((terminal["job"] as? [String: Any])?["status"] as? String, "cancelled")
                let lanes = try XCTUnwrap((terminal["plan"] as? [String: Any])?["oracle_results"] as? [[String: Any]])
                XCTAssertEqual(lanes.map { $0["status"] as? String }, ["cancelled", "cancelled"])
                XCTAssertEqual((lanes[0]["error"] as? [String: Any])?["partial_response"] as? String, "retained partial")
                XCTAssertNotNil(terminal["oracle_export_error"])
                XCTAssertNil(terminal["oracle_export_path"])
                XCTAssertFalse(FileManager.default.fileExists(atPath: driver.fixture.rootPaths[0] + "/prompt-exports"))
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(harness.registeredModels.count, 2)
                try await harness.wait(harness.cancelled[.gpt54Mini]!)
                try await harness.wait(harness.cancelled[.gpt54]!)
            }
        }

        func testTicketRetainsSettledGroupWhenExportFailsOrIsCancelledDuringWrite() async throws {
            for cancelDuringExport in [false, true] {
                try await withHarness(routed: true) { harness in
                    let driver = harness.driver
                    driver.streamBody = { runID in
                        let child = try await driver.connectChild(runID: runID)
                        try await driver.discover(using: child)
                    }
                    let entered = XCTestExpectation(description: "writer entered exactly once")
                    entered.assertForOverFulfill = true
                    let gate = driver.fixture.makeGate()
                    driver.window.mcpServer.contextBuilderExportFileOverrideForTesting = { _, _, _ in
                        entered.fulfill()
                        await gate.wait()
                        if cancelDuringExport { try Task.checkCancellation() }
                        throw NSError(domain: "SENSITIVE_WRITER_FAILURE", code: 1)
                    }
                    let context = try await driver.resolve()
                    let connection = try await driver.connectInvokingAgent(context)
                    func call(_ args: [String: Value]) async throws -> [String: Any] {
                        let reply = try await connection.client.callTool(name: "context_builder", arguments: args.merging(["_rawJSON": .bool(true)]) { _, new in new })
                        let text = reply.content.compactMap { content -> String? in
                            if case let .text(text, _, _) = content { return text }
                            return nil
                        }.joined(separator: "\n")
                        XCTAssertNotEqual(reply.isError, true, text)
                        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    }
                    let start = try await call(["op": .string("start"), "detach": .bool(true), "instructions": .string("One export attempt"), "response_type": .string("plan"), "oracle_preset": .string(harness.preset.name), "export_response": .bool(true)])
                    let id = try XCTUnwrap(start["job_id"] as? String)
                    try await harness.waitForStreams()
                    harness.complete(.gpt54Mini, text: "completed primary")
                    harness.complete(.gpt54, text: "completed sibling")
                    try await harness.wait(entered)
                    if cancelDuringExport { _ = try await call(["op": .string("cancel"), "job_id": .string(id)]) }
                    gate.release()
                    let terminal = try await call(["op": .string("wait"), "job_id": .string(id), "timeout": .double(10)])
                    XCTAssertEqual((terminal["job"] as? [String: Any])?["status"] as? String, cancelDuringExport ? "cancelled" : "completed")
                    let plan = try XCTUnwrap(terminal["plan"] as? [String: Any])
                    let lanes = try XCTUnwrap(plan["oracle_results"] as? [[String: Any]])
                    XCTAssertEqual(lanes.map { $0["status"] as? String }, ["completed", "completed"])
                    XCTAssertEqual(lanes.map { $0["response"] as? String }, ["completed primary", "completed sibling"])
                    XCTAssertNotNil(plan["oracle_group_id"])
                    XCTAssertNotNil(lanes[0]["chat_id"])
                    XCTAssertNotNil(lanes[1]["chat_id"])
                    XCTAssertNotNil(terminal["oracle_export_error"])
                    XCTAssertNil(terminal["oracle_export_path"])
                    XCTAssertFalse(String(describing: terminal).contains("SENSITIVE_WRITER_FAILURE"))
                    let value = try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: terminal))
                    let rendered = ToolOutputFormatter.buildContentBlocks(toolName: "context_builder", args: [:], result: value, emitResources: false)
                        .compactMap { content -> String? in
                            if case let .text(text, _, _) = content { return text }
                            return nil
                        }.joined(separator: "\n")
                    XCTAssertTrue(rendered.contains(cancelDuringExport ? "Oracle export cancelled" : "Oracle export failed"))
                    XCTAssertTrue(rendered.contains("completed primary"))
                    XCTAssertTrue(rendered.contains("completed sibling"))
                    let repeated = try await call(["op": .string("poll"), "job_id": .string(id)])
                    XCTAssertEqual(NSDictionary(dictionary: repeated), NSDictionary(dictionary: terminal))
                    XCTAssertEqual(driver.constructed, 1)
                    XCTAssertEqual(harness.registeredModels.count, 2)
                }
            }
        }

        func testLegacyBuilderExportFailureRemainsRequestError() async throws {
            try await withHarness(routed: true) { harness in
                let driver = harness.driver
                driver.streamBody = { runID in
                    let child = try await driver.connectChild(runID: runID)
                    try await driver.discover(using: child)
                }
                driver.window.mcpServer.contextBuilderExportFileOverrideForTesting = { _, _, _ in
                    throw NSError(domain: "fixture-export-error", code: 1)
                }
                let context = try await driver.resolve()
                let connection = try await driver.connectInvokingAgent(context)
                var failed = false
                harness.start {
                    let reply = try await connection.client.callTool(name: "context_builder", arguments: ["instructions": .string("Legacy export"), "response_type": .string("plan"), "oracle_preset": .string(harness.preset.name), "export_response": .bool(true)])
                    failed = reply.isError == true
                }
                try await harness.waitForStreams()
                harness.complete(.gpt54Mini, text: "legacy primary")
                harness.complete(.gpt54, text: "legacy sibling")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                XCTAssertTrue(failed, "Omitted op preserves legacy export failure, not ticket retention")
            }
        }

        func testUIGroupWaitsForAuthoritativeCompletionAfterInteractiveGrace() async throws {
            try await withHarness { harness in
                let driver = harness.driver
                let index = try XCTUnwrap(driver.manager.workspaces.firstIndex { $0.id == driver.fixture.workspace.id })
                driver.manager.workspaces[index].composeTabs[0].promptText = "Build the controlled plan"
                driver.window.promptManager.loadComposeTabsFromWorkspace(driver.manager.workspaces[index], syncPromptText: true)
                harness.start {
                    harness.uiReply = try await driver.vm.generatePlanFromDiscovery(
                        tabID: driver.tabID, originWorkspaceID: driver.fixture.workspace.id,
                        oracleViewModel: driver.window.oracleViewModel
                    )
                }
                try await harness.waitForStreams()
                try await harness.emit(.gpt54Mini, text: "first ")
                harness.clock.advance(to: 2)
                try await harness.emit(.gpt54Mini, text: "second ")
                XCTAssertTrue(harness.interactiveWatchdogObserved)
                let interactive = harness.interactiveWatchdogEnabled
                if interactive { try await harness.clock.waitForSleep(10) }
                harness.clock.advance(to: 13)
                if interactive {
                    try await harness.wait(harness.oldWatchdogChecked)
                    try await harness.wait(harness.cancelled[.gpt54Mini]!)
                }
                // Authoritative completion arrives after the old watchdog, but well before CB's budget.
                harness.complete(.gpt54Mini, text: "late completion")
                harness.complete(.gpt54, text: "auxiliary complete")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                let result = try XCTUnwrap(harness.uiReply?.oracleGroup?.result)
                XCTAssertEqual(result.oracleResults.map(\.status), [.completed, .completed])
                XCTAssertEqual(result.oracleResults[0].response, "first second late completion")
                XCTAssertEqual(result.oracleResults[1].response, "auxiliary complete")
            }
        }

        func testRegisteredMCPGroupBoundsInitialSilenceIndependentlyOfActiveSibling() async throws {
            try await withHarness(routed: true) { harness in
                let driver = harness.driver
                driver.streamBody = { runID in
                    let child = try await driver.connectChild(runID: runID)
                    try await driver.discover(using: child)
                }
                let context = try await driver.resolve()
                let connection = try await driver.connectInvokingAgent(context)
                harness.start {
                    let reply = try await connection.client.callTool(name: "context_builder", arguments: [
                        "instructions": .string("Build a controlled plan"), "response_type": .string("plan"),
                        "oracle_preset": .string(harness.preset.name), "_rawJSON": .bool(true)
                    ])
                    let text = reply.content.compactMap { content -> String? in
                        if case let .text(text, _, _) = content { return text }
                        return nil
                    }.joined(separator: "\n")
                    harness.mcpReply = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                }
                try await harness.waitForStreams()
                harness.clock.advance(to: 599)
                try await harness.emit(.gpt54, text: "active sibling ")
                harness.clock.advance(to: 605)
                // Assert autonomous cancellation BEFORE any rescue. A strict-only forwarding patch
                // leaves this registered silent lane pending; an active sibling must not renew it.
                let autonomous = await XCTWaiter.fulfillment(of: [harness.cancelled[.gpt54Mini]!], timeout: 2) == .completed
                XCTAssertTrue(autonomous, "Silent lane must time out without caller cancellation or fixture rescue")
                XCTAssertFalse(harness.didSettle, "The still-running sibling remains independent")
                if !autonomous { harness.complete(.gpt54Mini, text: "RESCUE ONLY") }
                harness.complete(.gpt54, text: "complete")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                let plan = try XCTUnwrap(harness.mcpReply?["plan"] as? [String: Any])
                let lanes = try XCTUnwrap(plan["oracle_results"] as? [[String: Any]])
                XCTAssertEqual(lanes.count, 2)
                XCTAssertEqual(lanes[0]["status"] as? String, "failed")
                XCTAssertEqual((lanes[0]["error"] as? [String: Any])?["code"] as? String, "context_builder_inactivity_timeout")
                XCTAssertEqual(lanes[1]["status"] as? String, "completed")
                XCTAssertEqual(lanes[1]["response"] as? String, "active sibling complete")
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.teardownIDs.count, 1)
            }
        }

        func testUnthrottledTransportRenewsButTokenOnlyProgressDoesNot() async throws {
            for transport in [true, false] {
                try await withHarness { harness in
                    try harness.startUI()
                    try await harness.waitForStreams()
                    harness.clock.advance(to: 599)
                    try await harness.emit(.gpt54Mini, text: "partial ")
                    harness.clock.advance(to: 599.5)
                    try await harness.emitOutput(.gpt54Mini, output: .init(
                        text: "", reasoning: nil, tokens: .init(completionTokens: 42), isTransportActivity: transport
                    ))
                    harness.complete(.gpt54, text: "sibling")
                    harness.clock.advance(to: 1199.25)
                    // This terminal admission itself checks expiry; no poll scheduling assumption.
                    harness.complete(.gpt54Mini, text: "complete")
                    try await harness.wait(harness.settled)
                    let result = try XCTUnwrap(harness.uiReply?.oracleGroup?.result.oracleResults.first)
                    if transport {
                        XCTAssertEqual(result.status, .completed)
                        XCTAssertEqual(result.response, "partial complete")
                    } else {
                        XCTAssertEqual(result.status, .failed)
                        XCTAssertEqual(result.error?.code, "context_builder_inactivity_timeout")
                        XCTAssertEqual(result.error?.partialResponse, "partial ")
                        XCTAssertNotNil(result.executionProfile)
                    }
                }
            }
        }

        func testRejectedActivityCannotProjectAfterIntraEventTimeoutOrCancellation() async throws {
            for cancels in [false, true] {
                try await withHarness { harness in
                    let oracle = harness.driver.window.oracleViewModel
                    let released = XCTestExpectation(description: "rejected activity released exact lane")
                    var primary: ContextBuilderOracleLaneScope?
                    var progressTexts: [String] = []
                    var progressReasoning: [String?] = []
                    oracle.contextBuilderBeforeChatResolutionForTesting = { scope, model in
                        if model == .gpt54Mini { primary = scope }
                    }
                    oracle.contextBuilderLaneReleasedForTesting = { scope in
                        if scope === primary { released.fulfill() }
                    }
                    try harness.startUI { text, reasoning in
                        progressTexts.append(text)
                        progressReasoning.append(reasoning)
                    }
                    try await harness.waitForStreams()
                    let scope = try XCTUnwrap(primary)
                    let queryID = try XCTUnwrap(scope.queryID)
                    oracle.pinSession(scope.sessionID)
                    defer { oracle.unpinSession(scope.sessionID) }
                    try await harness.emitOutput(.gpt54Mini, output: .init(
                        text: "accepted ", reasoning: "accepted reasoning", tokens: .init()
                    ))
                    let accepted = try XCTUnwrap(oracle.getChatMessage(withId: queryID))
                    XCTAssertEqual(accepted.content, "accepted ")
                    XCTAssertEqual(progressTexts, ["accepted "])
                    XCTAssertEqual(progressReasoning, [accepted.reasoningContent])
                    harness.clock.advance(to: 599)
                    try await harness.emit(.gpt54, text: "sibling ")
                    var boundaryFired = false
                    oracle.streamWatchdogNowForTesting = { [clock = harness.clock] in
                        // This synchronous hook runs AFTER the projection guard, before the scope's
                        // activity observation. A due poll cannot interleave inside this block.
                        if !boundaryFired {
                            boundaryFired = true
                            if cancels { scope.cancellation.request() }
                            else { clock.advance(to: 600) }
                        }
                        return Date(timeIntervalSince1970: clock.now)
                    }
                    harness.complete(.gpt54Mini, text: "late", reasoning: " late reasoning")
                    // Rejected output intentionally has no post-projection acknowledgment.
                    try await harness.wait(released)
                    XCTAssertTrue(boundaryFired, "The intended intra-event boundary must be reached")
                    let retained = try XCTUnwrap(oracle.getChatMessage(withId: queryID))
                    XCTAssertEqual(retained.content, accepted.content, "Rejected delta reached the transcript; cancellation=\(cancels)")
                    XCTAssertEqual(retained.reasoningContent, accepted.reasoningContent, "Rejected reasoning reached the transcript")
                    XCTAssertEqual(progressTexts, ["accepted "], "Rejected delta reached the UI progress callback")
                    XCTAssertEqual(progressReasoning, [accepted.reasoningContent], "Rejected reasoning reached the UI progress callback")
                    harness.complete(.gpt54, text: "complete")
                    try await harness.wait(harness.settled)
                    XCTAssertNil(harness.error)
                    let results = try XCTUnwrap(harness.uiReply?.oracleGroup?.result.oracleResults)
                    XCTAssertEqual(results.map(\.status), [cancels ? .cancelled : .failed, .completed])
                    XCTAssertEqual(results[0].error?.code, cancels ? "cancelled" : "context_builder_inactivity_timeout")
                    XCTAssertEqual(results[0].error?.partialResponse, "accepted ", "Rejected delta reached the returned partial")
                    XCTAssertEqual(results[1].response, "sibling complete")
                    XCTAssertTrue(scope.hasDrainedForTesting)
                }
            }
        }

        func testOrdinaryInteractiveWatchdogAndAttachedN1StrictRouteRemainDistinct() async throws {
            try await withHarness { harness in
                let oracle = harness.driver.window.oracleViewModel
                let session = try await oracle.locateOrCreateChat(nil, desiredName: "Ordinary", forceNew: true, tabID: harness.driver.tabID, activateInUI: false)
                let query = await oracle.sendMessage("Ordinary request", sessionID: session, overrideModel: .gpt54Mini)
                let queryID = try XCTUnwrap(query)
                try await harness.waitForStream(.gpt54Mini)
                try await harness.emit(.gpt54Mini, text: "first ")
                harness.clock.advance(to: 2)
                try await harness.emit(.gpt54Mini, text: "second ")
                XCTAssertTrue(harness.interactiveWatchdogEnabled)
                try await harness.clock.waitForSleep(10)
                harness.clock.advance(to: 13)
                try await harness.wait(harness.cancelled[.gpt54Mini]!)
                do { _ = try await oracle.waitForContextBuilderCompletion(queryID)
                    XCTFail("Ordinary watchdog is still non-authoritative")
                } catch OracleContextBuilderCompletionError.interactiveWatchdogFinalization {
                    // Authoritative old-watchdog outcome.
                } catch is CancellationError {
                    // The existing stream cancellation/finalizer race is also an old-policy outcome.
                } catch {
                    XCTFail("Unexpected ordinary completion error: \(error)")
                }
            }
            try await withHarness { harness in
                GlobalSettingsStore.shared.setWorkspaceAgentModelsProfile(
                    workspaceID: harness.driver.fixture.workspace.id,
                    profile: .init(planningModelRaw: AIModel.gpt54Mini.rawValue)
                )
                try harness.startUI()
                try await harness.waitForStream(.gpt54Mini)
                try await harness.emit(.gpt54Mini, text: "N1 ")
                harness.clock.advance(to: 2)
                try await harness.emit(.gpt54Mini, text: "strict ")
                XCTAssertTrue(harness.interactiveWatchdogObserved)
                XCTAssertFalse(harness.interactiveWatchdogEnabled)
                harness.clock.advance(to: 13)
                harness.complete(.gpt54Mini, text: "complete")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                XCTAssertNil(harness.uiReply?.oracleGroup)
                XCTAssertEqual(harness.uiReply?.response, "N1 strict complete")
                XCTAssertEqual(harness.registeredModels, [.gpt54Mini])
            }
        }

        func testStartupDeadlineIncludesPreQueryAwaitWithoutInventingAStream() async throws {
            try await withHarness { harness in
                let gate = harness.driver.fixture.makeGate()
                let entered = XCTestExpectation(description: "primary pre-query await entered")
                var primary: ContextBuilderOracleLaneScope?
                harness.driver.window.oracleViewModel.contextBuilderBeforeChatResolutionForTesting = { scope, model in
                    if model == .gpt54Mini {
                        primary = scope
                        entered.fulfill()
                        await gate.wait()
                    }
                }
                try harness.startUI()
                try await harness.wait(entered)
                try await harness.waitForStream(.gpt54)
                try await harness.clock.waitForSleep(5)
                harness.clock.advance(to: 599)
                try await harness.emit(.gpt54, text: "active ")
                try await harness.clock.waitForSleep(5)
                harness.clock.advance(to: 605)
                // There is no provider/waiter to release while startup itself is gated.
                // Explicit admission after expiry must reject even if the poll has not run yet.
                let scope = try XCTUnwrap(primary)
                XCTAssertThrowsError(try scope.checkpoint())
                XCTAssertEqual((scope.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
                XCTAssertNil(scope.queryID)
                XCTAssertNil(scope.streamID)
                gate.release()
                harness.complete(.gpt54, text: "complete")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                XCTAssertEqual(harness.registeredModels, [.gpt54])
                XCTAssertTrue(scope.hasDrainedForTesting)
                XCTAssertEqual(harness.uiReply?.oracleGroup?.result.oracleResults[0].error?.code, "context_builder_inactivity_timeout")
            }
        }

        func testLateUnavailableModelSettlesWithoutBindingOrProviderDispatch() async throws {
            try await withHarness { harness in
                var rejected: ContextBuilderOracleLaneScope?
                let oracle = harness.driver.window.oracleViewModel
                defer { if let rejected { oracle.unpinSession(rejected.sessionID) } }
                oracle.contextBuilderBeforeAvailabilityForTesting = { scope, model in
                    // This is AFTER actual UI resolution/validation, at sendMessage's own late branch.
                    harness.driver.window.apiSettingsViewModel.isOpenAIKeyValid = model != .gpt54Mini
                    if model == .gpt54Mini {
                        rejected = scope
                        oracle.pinSession(scope.sessionID) // Resident, as a displayed or recently viewed chat.
                    }
                }
                try harness.startUI()
                try await harness.waitForStream(.gpt54)
                harness.complete(.gpt54, text: "available sibling")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                let scope = try XCTUnwrap(rejected)
                XCTAssertNil(scope.queryID)
                XCTAssertNil(scope.streamID)
                XCTAssertTrue(scope.hasDrainedForTesting)
                XCTAssertEqual(harness.registeredModels, [.gpt54])
                XCTAssertEqual(harness.uiReply?.oracleGroup?.result.oracleResults.map(\.status), [.failed, .completed])
                let results = try XCTUnwrap(harness.uiReply?.oracleGroup?.result.oracleResults)
                let presented = try results.map { lane in
                    let member = try XCTUnwrap(oracle.sessions.first { $0.shortID == lane.chatID })
                    return oracle.oracleMemberPresentation(for: member).status
                }
                XCTAssertEqual(presented, [.failed, .completed], "Normal completion publishes both member outcomes")
                let error = try XCTUnwrap(harness.uiReply?.oracleGroup?.result.oracleResults.first?.error)
                XCTAssertTrue(error.message.contains("not available"))
                // Opening the lane chat must not show the failed send's MCP mode/model/preset label.
                XCTAssertTrue(oracle.isSessionPinnedForTesting(scope.sessionID))
                oracle.currentSessionID = scope.sessionID
                XCTAssertNil(oracle.mcpModelInfo)
                XCTAssertNil(oracle.mcpOverrideModelName)
                XCTAssertNil(oracle.mcpOverrideChatPresetName)
            }
        }

        func testRefusedBindRollsBackUserTurnWithoutProviderDispatch() async throws {
            try await withHarness { harness in
                var refused: ContextBuilderOracleLaneScope?
                let oracle = harness.driver.window.oracleViewModel
                defer { if let refused { oracle.unpinSession(refused.sessionID) } }
                oracle.contextBuilderBeforeAvailabilityForTesting = { scope, model in
                    // sendMessage has appended this lane's user turn; its query bind comes next.
                    guard model == .gpt54Mini else { return }
                    refused = scope
                    // Keep the chat resident, as a displayed or recently viewed chat stays;
                    // otherwise tool_chatSend's unpin unloads it and hides the unsaved turn.
                    oracle.pinSession(scope.sessionID)
                    scope.cancellation.request()
                }
                try harness.startUI()
                try await harness.waitForStream(.gpt54)
                harness.complete(.gpt54, text: "available sibling")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                let scope = try XCTUnwrap(refused)
                XCTAssertNil(scope.queryID)
                XCTAssertNil(scope.streamID)
                XCTAssertTrue(scope.hasDrainedForTesting)
                XCTAssertEqual(harness.registeredModels, [.gpt54])
                XCTAssertEqual(harness.uiReply?.oracleGroup?.result.oracleResults.map(\.status), [.cancelled, .completed])
                XCTAssertTrue(oracle.isSessionPinnedForTesting(scope.sessionID))
                XCTAssertEqual(
                    oracle.messagesSnapshot(for: scope.sessionID).map(\.id), [],
                    "A refused bind must leave the fresh lane chat empty"
                )
                // Opening the lane chat must not show the refused send's MCP mode/model/preset label.
                oracle.currentSessionID = scope.sessionID
                XCTAssertNil(oracle.mcpModelInfo)
                XCTAssertNil(oracle.mcpOverrideModelName)
                XCTAssertNil(oracle.mcpOverrideChatPresetName)
            }
        }

        func testCancelledLaneWithLateUnavailableModelLeavesNoTurns() async throws {
            try await withHarness { harness in
                var cancelled: ContextBuilderOracleLaneScope?
                let oracle = harness.driver.window.oracleViewModel
                defer { if let cancelled { oracle.unpinSession(cancelled.sessionID) } }
                oracle.contextBuilderBeforeAvailabilityForTesting = { scope, model in
                    // The lane is revoked after its user turn exists, just before the late availability branch.
                    harness.driver.window.apiSettingsViewModel.isOpenAIKeyValid = model != .gpt54Mini
                    guard model == .gpt54Mini else { return }
                    cancelled = scope
                    oracle.pinSession(scope.sessionID) // Resident, as a displayed or recently viewed chat.
                    scope.cancellation.request()
                }
                try harness.startUI()
                try await harness.waitForStream(.gpt54)
                harness.complete(.gpt54, text: "available sibling")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                let scope = try XCTUnwrap(cancelled)
                XCTAssertNil(scope.queryID)
                XCTAssertTrue(scope.hasDrainedForTesting)
                XCTAssertEqual(harness.registeredModels, [.gpt54])
                XCTAssertEqual(harness.uiReply?.oracleGroup?.result.oracleResults.map(\.status), [.cancelled, .completed])
                XCTAssertTrue(oracle.isSessionPinnedForTesting(scope.sessionID))
                XCTAssertEqual(
                    oracle.messagesSnapshot(for: scope.sessionID).map(\.id), [],
                    "A revoked lane must keep no user turn and add no unavailable-model error turn"
                )
            }
        }

        func testExpiredLaneLinksTheBackgroundTabItAlreadyCreated() async throws {
            try await withHarness { harness in
                let oracle = harness.driver.window.oracleViewModel
                let manager = harness.driver.manager
                let name = "Lane chat \(UUID().uuidString)"
                let session = ChatSession(composeTabID: UUID(), name: name) // Its tab no longer exists.
                oracle.sessions.append(session)
                // The lane expires exactly once ensureTabForSession's background tab exists.
                let group = ContextBuilderOracleGroupSupervision(clock: {
                    manager.workspaces.contains { $0.composeTabs.contains { $0.name == name } } ? 10000 : 0
                })
                let lane = group.makeLane(sessionID: session.id)
                _ = await oracle.ensureTabForSession(session, contextBuilderScope: lane)
                XCTAssertFalse(lane.isLive)
                let created = manager.workspaces.flatMap(\.composeTabs).filter { $0.name == name }
                XCTAssertEqual(created.count, 1)
                XCTAssertEqual(
                    oracle.sessions.first { $0.id == session.id }?.composeTabID, created.first?.id,
                    "A tab created for the lane chat must not be left unlinked"
                )
            }
        }

        func testTimedOutOrCancelledLanePersistsItsAdmittedPartial() async throws {
            // A silent lane keeps its dispatched user turn but, like an ordinary cancel, no empty assistant turn.
            let cases: [(stop: String, partial: String?)] = [("timeout", "partial "), ("cancel", "partial "), ("silent timeout", nil)]
            for (stop, partial) in cases {
                try await withHarness { harness in
                    var primary: ContextBuilderOracleLaneScope?
                    let oracle = harness.driver.window.oracleViewModel
                    oracle.contextBuilderBeforeChatResolutionForTesting = { scope, model in
                        if model == .gpt54Mini { primary = scope }
                    }
                    try harness.startUI()
                    try await harness.waitForStreams()
                    if let partial { try await harness.emit(.gpt54Mini, text: partial) }
                    harness.complete(.gpt54, text: "sibling")
                    let scope = try XCTUnwrap(primary, stop)
                    var frozen: ChatSession?
                    if partial == nil {
                        // Show the silent lane's chat on the active tab with different live controls, so a save
                        // that took live prompt state would overwrite what tool_chatSend froze for the lane.
                        let lane = try XCTUnwrap(oracle.sessions.first { $0.id == scope.sessionID }, stop)
                        frozen = lane
                        oracle.currentSessionID = scope.sessionID
                        oracle.promptViewModel.restorePreferredModelForSession(AIModel.gpt54.rawValue)
                        oracle.promptViewModel.selectedChatPresetID = lane.selectedChatPresetID == ChatPreset.BuiltIn.chat.id
                            ? ChatPreset.BuiltIn.plan.id : ChatPreset.BuiltIn.chat.id
                        XCTAssertTrue(OracleViewModel.shouldUseLivePromptStateForAutosave(
                            sessionID: scope.sessionID, currentSessionID: oracle.currentSessionID,
                            sessionComposeTabID: lane.composeTabID, activeComposeTabID: oracle.promptViewModel.activeComposeTabID
                        ), "\(stop): the lane chat is current on the active tab")
                        XCTAssertNotEqual(oracle.promptViewModel.preferredModel, lane.preferredAIModel, stop)
                        XCTAssertNotEqual(oracle.promptViewModel.selectedChatPresetID, lane.selectedChatPresetID, stop)
                    }
                    if stop == "cancel" {
                        await oracle.cancelAIResponse(in: scope.sessionID)
                    } else {
                        try await harness.clock.waitForSleep(5)
                        harness.clock.advance(to: 605)
                    }
                    try await harness.wait(harness.settled)
                    XCTAssertNil(harness.error, stop)
                    let result = try XCTUnwrap(harness.uiReply?.oracleGroup?.result.oracleResults.first, stop)
                    XCTAssertEqual(result.status, stop == "cancel" ? .cancelled : .failed, stop)
                    XCTAssertEqual(result.error?.partialResponse, partial, "\(stop): the admitted partial")
                    // Read the saved chat back from disk, independent of what is still in memory.
                    let session = try XCTUnwrap(oracle.sessions.first { $0.id == scope.sessionID }, stop)
                    try await oracle.drainTrackedAutosaves(for: XCTUnwrap(session.workspaceID, stop))
                    let saved = try await oracle.chatData.loadChatSession(from: XCTUnwrap(session.fileURL, stop))
                    XCTAssertEqual(saved.messages.map(\.isUser), partial == nil ? [true] : [true, false], "\(stop): saved turns")
                    XCTAssertEqual(saved.messages.last { !$0.isUser }?.rawText, partial, "\(stop): saved partial")
                    if let frozen {
                        XCTAssertEqual(saved.preferredAIModel, frozen.preferredAIModel, "\(stop): saved model")
                        XCTAssertEqual(saved.selectedChatPresetID, frozen.selectedChatPresetID, "\(stop): saved preset")
                    }
                }
            }
        }

        func testDeletingCancelledLaneChatAfterGroupSettlesLeavesNoChatFile() async throws {
            try await withHarness { harness in
                var primary: ContextBuilderOracleLaneScope?
                let oracle = harness.driver.window.oracleViewModel
                oracle.contextBuilderBeforeChatResolutionForTesting = { scope, model in
                    if model == .gpt54Mini { primary = scope }
                }
                try harness.startUI()
                try await harness.waitForStreams()
                try await harness.emit(.gpt54Mini, text: "partial ")
                harness.complete(.gpt54, text: "sibling")
                let scope = try XCTUnwrap(primary)
                // Cancelling queues the lane's release save; a running group can't be deleted, so delete once settled.
                await oracle.cancelAIResponse(in: scope.sessionID)
                try await harness.wait(harness.settled)
                let session = try XCTUnwrap(oracle.sessions.first { $0.id == scope.sessionID })
                let workspace = try XCTUnwrap(harness.driver.manager.workspaces.first { $0.id == session.workspaceID })
                await oracle.deleteSession(session)
                await oracle.drainTrackedAutosaves(for: workspace.id)
                XCTAssertNil(oracle.sessionOperationError)
                let files = try await oracle.chatData.listChatSessions(for: workspace).map(\.lastPathComponent)
                XCTAssertFalse(files.contains("ChatSession-\(session.id.uuidString).json"), "A deleted lane chat's file came back")
            }
        }

        func testTimedOutFinalizerDrainsWithoutClearingReplacementDuringOuterCancellation() async throws {
            try await withHarness { harness in
                let driver = harness.driver
                let oracle = driver.window.oracleViewModel
                let gate = driver.fixture.makeGate()
                let entered = XCTestExpectation(description: "owned finalizer suspended")
                let released = XCTestExpectation(description: "exact stream and hub released before finalizer join")
                var primary: ContextBuilderOracleLaneScope?
                oracle.contextBuilderBeforeChatResolutionForTesting = { scope, model in
                    if model == .gpt54Mini { primary = scope }
                }
                oracle.contextBuilderBeforeFinalizationForTesting = { scope in
                    if scope === primary { entered.fulfill()
                        await gate.wait()
                    }
                }
                oracle.contextBuilderLaneReleasedForTesting = { scope in
                    if scope === primary { released.fulfill() }
                }
                try harness.startUI()
                try await harness.waitForStreams()
                harness.complete(.gpt54Mini, text: "unprocessed <chatName name=\"Stale rename\"/>")
                harness.complete(.gpt54, text: "complete sibling")
                try await harness.wait(entered)
                let scope = try XCTUnwrap(primary)
                let oldQuery = try XCTUnwrap(scope.queryID)
                // Keep the observation target resident: ordinary MCP unpin may legitimately evict it.
                oracle.pinSession(scope.sessionID)
                defer { oracle.unpinSession(scope.sessionID) }
                let oldContent = oracle.getChatMessage(withId: oldQuery)?.content
                let oldName = oracle.sessions.first { $0.id == scope.sessionID }?.name
                XCTAssertGreaterThanOrEqual(scope.ownedTaskCountForTesting, 2)
                try await harness.clock.waitForSleep(5)
                harness.clock.advance(to: 605)
                try await harness.wait(released)
                XCTAssertEqual((scope.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
                XCTAssertFalse(scope.hasDrainedForTesting, "Stream/observer end is not finalizer drainage")
                XCTAssertFalse(harness.didSettle)
                let replacementRegistered = harness.expectNextStream(.gpt54Mini)
                let replacement = await oracle.sendMessage("Replacement", sessionID: scope.sessionID, overrideModel: .gpt54Mini)
                let replacementQuery = try XCTUnwrap(replacement)
                try await harness.wait(replacementRegistered)
                try await harness.emit(.gpt54Mini, text: "replacement ")
                let generation = try XCTUnwrap(driver.vm.sessions[driver.tabID]).followUpOracleGroupState.generation
                let groupID = try XCTUnwrap(driver.vm.sessions[driver.tabID]?.followUpOracleGroupState.groupID)
                harness.cancelRequest() // outer withTaskCancellationHandler path
                driver.vm.cancelBackgroundPlanGeneration(forTabID: driver.tabID) // cancelAndDrain path
                gate.release()
                try await harness.wait(harness.settled)
                XCTAssertTrue(scope.hasDrainedForTesting)
                XCTAssertEqual(scope.ownedTaskCountForTesting, 0)
                let owner = try OracleViewModel.oracleGroupOwner(workspaceID: driver.fixture.workspace.id, tabID: driver.tabID)
                let stored = try await AppDomainRuntimeComposition.shared.oracleConversationStore.load(groupID: groupID, owner: owner)
                XCTAssertEqual(stored?.turns.last?.results.first?.error?.code, "context_builder_inactivity_timeout")
                XCTAssertEqual((scope.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
                XCTAssertNotEqual(driver.vm.sessions[driver.tabID]?.followUpOracleGroupState.generation, generation)
                XCTAssertEqual(oracle.activeQueryId(for: scope.sessionID), replacementQuery)
                XCTAssertTrue(oracle.isSessionStreaming(scope.sessionID))
                XCTAssertEqual(oracle.getChatMessage(withId: oldQuery)?.content, oldContent)
                XCTAssertEqual(oracle.sessions.first { $0.id == scope.sessionID }?.name, oldName)
                harness.complete(.gpt54Mini, text: "complete")
                let response = try await oracle.waitForContextBuilderCompletion(replacementQuery)
                XCTAssertEqual(response, "replacement complete")
                XCTAssertEqual(harness.registeredModels.count, 3)
            }
        }

        func testMemberCancellationWaitsForOwnedFinalizerDrain() async throws {
            try await withHarness { harness in
                let oracle = harness.driver.window.oracleViewModel
                let gate = harness.driver.fixture.makeGate()
                let entered = XCTestExpectation(description: "member finalizer entered")
                let released = XCTestExpectation(description: "member cancellation released dependencies")
                var primary: ContextBuilderOracleLaneScope?
                oracle.contextBuilderBeforeChatResolutionForTesting = { scope, model in
                    if model == .gpt54Mini { primary = scope }
                }
                oracle.contextBuilderBeforeFinalizationForTesting = { scope in
                    if scope === primary { entered.fulfill()
                        await gate.wait()
                    }
                }
                oracle.contextBuilderLaneReleasedForTesting = { scope in
                    if scope === primary { released.fulfill() }
                }
                try harness.startUI()
                try await harness.waitForStreams()
                harness.complete(.gpt54Mini, text: "cancelled partial")
                harness.complete(.gpt54, text: "completed sibling")
                try await harness.wait(entered)
                let scope = try XCTUnwrap(primary)
                var stopReturned = false
                let stop = Task { @MainActor in
                    await oracle.cancelAIResponse(in: scope.sessionID)
                    stopReturned = true
                }
                do {
                    try await harness.wait(released)
                    XCTAssertFalse(stopReturned)
                    XCTAssertFalse(scope.hasDrainedForTesting)
                    XCTAssertTrue(scope.terminalError is CancellationError)
                    gate.release()
                    await stop.value
                } catch {
                    gate.release()
                    await stop.value
                    throw error
                }
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                XCTAssertTrue(scope.hasDrainedForTesting)
                XCTAssertEqual(harness.uiReply?.oracleGroup?.result.oracleResults.map(\.status), [.cancelled, .completed])
            }
        }

        func testRemoteCleanupIsNeitherCancelledNorJoinedBySuccessOrTimeout() async throws {
            for timesOut in [false, true] {
                try await withHarness { harness in
                    let oracle = harness.driver.window.oracleViewModel
                    let gate = harness.driver.fixture.makeGate()
                    let entered = XCTestExpectation(description: "fake remote cleanup entered")
                    var calls = 0
                    var finished = false
                    oracle.providerConversationCleanupForTesting = { handle in
                        XCTAssertEqual(handle.sessionID, "controlled-remote")
                        XCTAssertFalse(Task.isCancelled, "Local latch must not cancel remote cleanup")
                        calls += 1
                        entered.fulfill()
                        await gate.wait()
                        XCTAssertFalse(Task.isCancelled)
                        finished = true
                    }
                    try harness.startUI()
                    try await harness.waitForStreams()
                    try await harness.emitOutput(.gpt54Mini, output: .init(
                        text: "partial ", reasoning: nil, tokens: .init(),
                        cleanupHandle: .init(provider: "controlled", sessionID: "controlled-remote")
                    ))
                    harness.complete(.gpt54, text: "sibling complete")
                    if timesOut {
                        try await harness.clock.waitForSleep(5)
                        harness.clock.advance(to: 605)
                    } else {
                        harness.complete(.gpt54Mini, text: "complete")
                    }
                    try await harness.wait(entered)
                    try await harness.wait(harness.settled)
                    XCTAssertNil(harness.error)
                    XCTAssertEqual(harness.uiReply?.oracleGroup?.result.oracleResults[0].status, timesOut ? .failed : .completed)
                    if timesOut {
                        XCTAssertEqual(harness.uiReply?.oracleGroup?.result.oracleResults[0].error?.code, "context_builder_inactivity_timeout")
                    }
                    XCTAssertEqual(calls, 1, "Transferred cleanup handle must not be reused by producer catch")
                    XCTAssertFalse(finished, "Group must settle while remote disposal is still gated")
                    gate.release()
                }
            }
        }

        private func withHarness(
            routed: Bool = false,
            _ body: @escaping @MainActor (GroupedOracleHarness) async throws -> Void
        ) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A", "B", "C"], routedRuntime: routed) { driver in
                let harness = try GroupedOracleHarness(driver: driver)
                do {
                    try await body(harness)
                    await harness.close()
                } catch {
                    await harness.close()
                    throw error
                }
            }
        }
    }

    @MainActor
    final class SingleOracleTicketLifetimeTests: XCTestCase {
        func testFiredInteractiveWatchdogFinalizerDrainsBeforeTicketTerminalAndCannotClearReplacement() async throws {
            try await withHarness { harness in
                let driver = harness.driver
                let oracle = driver.window.oracleViewModel
                let jobs = WindowStatesManager.shared.longRunningJobs
                let gate = driver.fixture.makeGate()
                let fired = XCTestExpectation(description: "real interactive watchdog fired")
                let entered = XCTestExpectation(description: "real watchdog finalizer held before processing")
                var scope: ContextBuilderOracleLaneScope?
                var queryID: UUID?
                var finalizer: Task<Void, Never>?
                var heldFinalizerReturned = false
                oracle.contextBuilderBeforeAvailabilityForTesting = { lane, _ in scope = lane }
                oracle.interactiveWatchdogBeforeFinalizationForTesting = { id in
                    guard id == queryID else { return }
                    entered.fulfill()
                    await gate.wait()
                    heldFinalizerReturned = true
                }
                oracle.interactiveWatchdogFinalizerScheduledForTesting = { id, task in
                    if id == queryID { finalizer = task }
                }
                let connection = try await driver.connectInvokingAgent(driver.resolve())
                let started = try await self.payload(connection, tool: "ask_oracle", args: [
                    "op": .string("start"), "detach": .bool(true), "new_chat": .bool(true),
                    "message": .string("Controlled fired watchdog"), "debug_primary_only": .bool(true)
                ])
                let id = try XCTUnwrap(UUID(uuidString: XCTUnwrap(started["job_id"] as? String)))
                try await harness.waitForStream(.gpt54Mini)
                let lane = try XCTUnwrap(scope)
                let oldQuery = try XCTUnwrap(lane.queryID)
                queryID = oldQuery
                let observer = oracle.addMessageLifecycleActivityObserver(for: oldQuery) { event in
                    if event.kind == .streamInactivityWatchdogFired { fired.fulfill() }
                }
                defer { oracle.removeMessageLifecycleActivityObserver(for: oldQuery, observerID: observer) }
                oracle.pinSession(lane.sessionID)
                defer { oracle.unpinSession(lane.sessionID) }
                try await harness.emit(.gpt54Mini, text: "partial ")
                harness.clock.advance(to: 2)
                try await harness.emit(.gpt54Mini, text: "<chatName name=\"Stale watchdog rename\"/>")
                let oldContent = oracle.getChatMessage(withId: oldQuery)?.content
                let oldName = oracle.sessions.first { $0.id == lane.sessionID }?.name
                try await harness.clock.waitForSleep(10)
                harness.clock.advance(to: 13)
                try await harness.wait(fired)
                try await harness.wait(entered)
                let watchdogFinalizer = try XCTUnwrap(finalizer)
                _ = try await self.payload(connection, tool: "ask_oracle", args: ["op": .string("cancel"), "job_id": .string(id.uuidString)])
                let cancellingSnapshot = await jobs.store.wait(id: id, timeout: 0.1)
                let cancelling = try XCTUnwrap(cancellingSnapshot)
                XCTAssertEqual(cancelling.status, .cancelling, "A fired local finalizer is not remotely disposed work")
                XCTAssertFalse(heldFinalizerReturned)
                XCTAssertFalse(lane.hasDrainedForTesting)
                XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 1)
                do {
                    try await jobs.store.checkAdmission(owner: cancelling.owner)
                    XCTFail("Admission released before the held watchdog finalizer drained")
                } catch {}
                let replacementRegistered = harness.expectNextStream(.gpt54Mini)
                let replacement = await oracle.sendMessage("Replacement", sessionID: lane.sessionID, overrideModel: .gpt54Mini)
                let replacementQuery = try XCTUnwrap(replacement)
                try await harness.wait(replacementRegistered)
                try await harness.emit(.gpt54Mini, text: "replacement ")
                gate.release()
                await watchdogFinalizer.value
                let terminalSnapshot = await jobs.store.wait(id: id, timeout: 10)
                let terminal = try XCTUnwrap(terminalSnapshot)
                XCTAssertEqual(terminal.status, .cancelled)
                XCTAssertTrue(heldFinalizerReturned)
                XCTAssertTrue(lane.hasDrainedForTesting)
                XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 0)
                try await jobs.store.checkAdmission(owner: terminal.owner)
                XCTAssertEqual(oracle.getChatMessage(withId: oldQuery)?.content, oldContent, "Revoked watchdog must not process stale content")
                XCTAssertEqual(oracle.sessions.first { $0.id == lane.sessionID }?.name, oldName, "Revoked watchdog must not rename the chat")
                XCTAssertEqual(oracle.activeQueryId(for: lane.sessionID), replacementQuery)
                XCTAssertTrue(oracle.isSessionStreaming(lane.sessionID), "Old watchdog must not clear replacement state")
                harness.complete(.gpt54Mini, text: "complete")
                let response = try await oracle.waitForContextBuilderCompletion(replacementQuery)
                XCTAssertEqual(response, "replacement complete")
            }
        }

        func testGroupedTicketCancellationDrainsAdditionalProducerAndProtectsSettledPrimaryAndReplacement() async throws {
            try await withHarness { harness in
                let driver = harness.driver
                let oracle = driver.window.oracleViewModel
                let jobs = WindowStatesManager.shared.longRunningJobs
                let gate = driver.fixture.makeGate()
                var heldProducerReturned = false
                var firstAdditional = true
                var scopes: [AIModel: ContextBuilderOracleLaneScope] = [:]
                oracle.contextBuilderBeforeChatResolutionForTesting = { scope, model in scopes[model] = scope }
                harness.beforeTransportReturn = { id in
                    guard firstAdditional, harness.streams[.gpt54]?.id == id else { return }
                    firstAdditional = false
                    await gate.wait()
                    heldProducerReturned = true
                }
                let context = try await driver.resolve()
                let connection = try await driver.connectInvokingAgent(context)
                let started = try await self.payload(connection, tool: "ask_oracle", args: [
                    "op": .string("start"), "detach": .bool(true), "new_chat": .bool(true),
                    "model": .string(harness.preset.name), "message": .string("Ordinary two-lane ticket")
                ])
                let id = try XCTUnwrap(UUID(uuidString: XCTUnwrap(started["job_id"] as? String)))
                try await harness.waitForStreams()
                let primary = try XCTUnwrap(oracle.sessions.first { $0.oracleGroupID != nil && $0.preferredAIModel == AIModel.gpt54Mini.rawValue })
                let additional = try XCTUnwrap(oracle.sessions.first { $0.oracleGroupID != nil && $0.preferredAIModel == AIModel.gpt54.rawValue })
                let primaryQuery = try XCTUnwrap(oracle.activeQueryId(for: primary.id))
                let oldQuery = try XCTUnwrap(oracle.activeQueryId(for: additional.id))
                let oldStream = try XCTUnwrap(harness.streams[.gpt54])
                oracle.pinSession(primary.id)
                oracle.pinSession(additional.id)
                defer { oracle.unpinSession(primary.id)
                    oracle.unpinSession(additional.id)
                }
                harness.complete(.gpt54Mini, text: "settled paid primary")
                let paidResponse = try await oracle.waitForContextBuilderCompletion(primaryQuery)
                XCTAssertEqual(paidResponse, "settled paid primary")
                oldStream.continuation.yield(.init(text: "MUST NOT COMMIT", reasoning: nil, tokens: .init(), terminalOutcome: .completed))
                _ = try await self.payload(connection, tool: "ask_oracle", args: ["op": .string("cancel"), "job_id": .string(id.uuidString)])
                let cancellingSnapshot = await jobs.store.wait(id: id, timeout: 0.1)
                let cancelling = try XCTUnwrap(cancellingSnapshot)
                XCTAssertEqual(cancelling.status, .cancelling, "The additional producer is still held at transport return")
                XCTAssertFalse(heldProducerReturned)
                XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 1, "Run cancellation registration must remain until every local lane drains")
                do {
                    try await jobs.store.checkAdmission(owner: cancelling.owner)
                    XCTFail("Busy reservation released while additional producer remains held")
                } catch {}
                XCTAssertNotNil(scopes[.gpt54], "Every ordinary ticket lane needs the common lifetime owner, not a progress-field shortcut")
                XCTAssertEqual(scopes[.gpt54]?.checkDeadlines(at: ProcessInfo.processInfo.systemUptime + 14400), false, "Cancellation revokes admission without a CB deadline")
                let replacementRegistered = harness.expectNextStream(.gpt54)
                let replacement = await oracle.sendMessage("Replacement", sessionID: additional.id, overrideModel: .gpt54)
                let replacementQuery = try XCTUnwrap(replacement)
                try await harness.wait(replacementRegistered)
                try await harness.emit(.gpt54, text: "replacement ")
                gate.release()
                let terminalSnapshot = await jobs.store.wait(id: id, timeout: 10)
                let terminal = try XCTUnwrap(terminalSnapshot)
                XCTAssertTrue(heldProducerReturned, "Ticket terminal must follow actual additional producer return")
                XCTAssertEqual(terminal.status, .cancelled)
                XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 0)
                try await jobs.store.checkAdmission(owner: terminal.owner)
                let lanes = try XCTUnwrap(terminal.result?.objectValue?["oracle_results"]?.arrayValue)
                XCTAssertEqual(lanes.map { $0.objectValue?["status"]?.stringValue }, ["completed", "cancelled"])
                XCTAssertEqual(lanes.first?.objectValue?["response"]?.stringValue, "settled paid primary")
                XCTAssertEqual(terminal.result?.objectValue?["status"]?.stringValue, "partial_failure")
                try await harness.wait(harness.cancelled[.gpt54]!)
                if case .terminated = oldStream.continuation.yield(.init(text: "late", reasoning: nil, tokens: .init())) {} else {
                    XCTFail("Exact additional stream remained live after ticket cancellation")
                }
                XCTAssertFalse(oracle.messagesSnapshot(for: additional.id).contains { $0.content.contains("MUST NOT COMMIT") })
                XCTAssertNil(oracle.getChatMessage(withId: oldQuery))
                XCTAssertEqual(oracle.getChatMessage(withId: primaryQuery)?.content, "settled paid primary")
                XCTAssertEqual(oracle.activeQueryId(for: additional.id), replacementQuery)
                XCTAssertTrue(oracle.isSessionStreaming(additional.id), "Old group cleanup must not clear the replacement")
                harness.complete(.gpt54, text: "complete")
                let response = try await oracle.waitForContextBuilderCompletion(replacementQuery)
                XCTAssertEqual(response, "replacement complete")
            }
        }

        func testCancellationKeepsTicketOwnershipUntilExactProducerDrainsAndProtectsReplacement() async throws {
            let tool = "ask_oracle"
            try await withHarness { harness in
                let driver = harness.driver
                let oracle = driver.window.oracleViewModel
                let jobs = WindowStatesManager.shared.longRunningJobs
                let gate = driver.fixture.makeGate()
                var heldProducerReturned = false
                var first = true
                harness.beforeTransportReturn = { _ in
                    guard first else { return }
                    first = false
                    await gate.wait()
                    heldProducerReturned = true
                }
                let context = try await driver.resolve()
                let connection = try await driver.connectInvokingAgent(context)
                let started = try await self.payload(connection, tool: tool, args: [
                    "op": .string("start"), "detach": .bool(true), "new_chat": .bool(true),
                    "message": .string("Controlled single ticket"), "debug_primary_only": .bool(true)
                ])
                let id = try XCTUnwrap(UUID(uuidString: XCTUnwrap(started["job_id"] as? String)))
                try await harness.waitForStream(.gpt54Mini)
                let sessionID = try XCTUnwrap(oracle.sessions.last?.id)
                let oldQuery = try XCTUnwrap(oracle.activeQueryId(for: sessionID))
                let oldStream = try XCTUnwrap(harness.streams[.gpt54Mini])
                oracle.pinSession(sessionID)
                defer { oracle.unpinSession(sessionID) }
                // Buffer a successful late output inside the actual Oracle producer's transport admission.
                oldStream.continuation.yield(.init(text: "MUST NOT COMMIT", reasoning: nil, tokens: .init(), terminalOutcome: .completed))
                _ = try await self.payload(connection, tool: tool, args: ["op": .string("cancel"), "job_id": .string(id.uuidString)])
                let cancellingSnapshot = await jobs.store.wait(id: id, timeout: 0.1)
                let cancelling = try XCTUnwrap(cancellingSnapshot)
                XCTAssertEqual(cancelling.status, .cancelling, "Ticket must not settle before the gated Oracle producer returns: \(tool)")
                XCTAssertFalse(heldProducerReturned)
                XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 1, "Keep run cancellation registration through local drain")
                do {
                    try await jobs.store.checkAdmission(owner: cancelling.owner)
                    XCTFail("Busy reservation released before producer drain: \(tool)")
                } catch {}
                let replacementRegistered = harness.expectNextStream(.gpt54Mini)
                let replacement = await oracle.sendMessage("Replacement", sessionID: sessionID, overrideModel: .gpt54Mini)
                let replacementQuery = try XCTUnwrap(replacement)
                try await harness.wait(replacementRegistered)
                try await harness.emit(.gpt54Mini, text: "replacement ")
                gate.release()
                let terminalSnapshot = await jobs.store.wait(id: id, timeout: 10)
                let terminal = try XCTUnwrap(terminalSnapshot)
                XCTAssertEqual(terminal.status, .cancelled)
                XCTAssertTrue(heldProducerReturned, "Terminal means the actual local producer has drained")
                XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 0)
                try await jobs.store.checkAdmission(owner: terminal.owner)
                try await harness.wait(harness.cancelled[.gpt54Mini]!)
                if case .terminated = oldStream.continuation.yield(.init(text: "late", reasoning: nil, tokens: .init())) {} else {
                    XCTFail("Exact old stream remained live after ticket cancellation")
                }
                XCTAssertFalse(oracle.messagesSnapshot(for: sessionID).contains { $0.content.contains("MUST NOT COMMIT") })
                XCTAssertNil(oracle.getChatMessage(withId: oldQuery))
                XCTAssertEqual(oracle.activeQueryId(for: sessionID), replacementQuery)
                XCTAssertTrue(oracle.isSessionStreaming(sessionID), "Old-ticket cleanup cannot cancel the replacement")
                harness.complete(.gpt54Mini, text: "complete")
                let response = try await oracle.waitForContextBuilderCompletion(replacementQuery)
                XCTAssertEqual(response, "replacement complete")
            }
        }

        func testObserverCancellationAndDisconnectLeaveSingleProducerRunningUntilExplicitTicketCancel() async throws {
            let tool = "ask_oracle"
            try await withHarness { harness in
                let driver = harness.driver
                let oracle = driver.window.oracleViewModel
                let jobs = WindowStatesManager.shared.longRunningJobs
                let context = try await driver.resolve()
                let initiating = try await driver.connectInvokingAgent(context)
                var scope: ContextBuilderOracleLaneScope?
                var watchdogEnabled: Bool?
                oracle.streamWatchdogScheduledForTesting = { _, _, enabled in watchdogEnabled = enabled }
                oracle.contextBuilderBeforeAvailabilityForTesting = { lane, _ in scope = lane }
                let started = try await self.payload(initiating, tool: tool, args: [
                    "op": .string("start"), "detach": .bool(true), "new_chat": .bool(true),
                    "message": .string("Controlled consuming ticket"), "debug_primary_only": .bool(true)
                ])
                let id = try XCTUnwrap(UUID(uuidString: XCTUnwrap(started["job_id"] as? String)))
                try await harness.waitForStream(.gpt54Mini)
                let sessionID = try XCTUnwrap(oracle.sessions.last?.id)
                let query = try XCTUnwrap(oracle.activeQueryId(for: sessionID))
                let stream = try XCTUnwrap(harness.streams[.gpt54Mini])
                oracle.pinSession(sessionID)
                defer { oracle.unpinSession(sessionID) }
                try await harness.emit(.gpt54Mini, text: "admitted partial ")
                XCTAssertEqual(scope?.checkDeadlines(at: ProcessInfo.processInfo.systemUptime + 14400), true, "Single tickets gain ownership, not Context Builder deadlines")
                XCTAssertEqual(watchdogEnabled, true, "Retain ordinary Oracle's existing watchdog policy")
                let observer = Task { await jobs.store.wait(id: id, timeout: 60) }
                observer.cancel()
                _ = await observer.value
                await initiating.cleanup()
                let reconnected = try await driver.connectInvokingAgent(context)
                let observed = try await self.payload(reconnected, tool: tool, args: ["op": .string("poll"), "job_id": .string(id.uuidString)])
                XCTAssertEqual((observed["job"] as? [String: Any])?["status"] as? String, "running")
                XCTAssertEqual(oracle.activeQueryId(for: sessionID), query)
                XCTAssertTrue(oracle.isSessionStreaming(sessionID))
                XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 1)
                _ = try await self.payload(reconnected, tool: tool, args: ["op": .string("cancel"), "job_id": .string(id.uuidString)])
                let terminalSnapshot = await jobs.store.wait(id: id, timeout: 10)
                let terminal = try XCTUnwrap(terminalSnapshot)
                XCTAssertEqual(terminal.status, .cancelled)
                if case .terminated = stream.continuation.yield(.init(text: "late forbidden", reasoning: nil, tokens: .init())) {} else {
                    XCTFail("Explicit ticket cancel did not reach the exact consuming stream: \(tool)")
                }
                XCTAssertFalse(oracle.isSessionStreaming(sessionID))
                XCTAssertEqual(oracle.getChatMessage(withId: query)?.content, "admitted partial ")
                XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 0)
            }
        }

        func testOmittedOperationStillBlocksWithoutTicketLifetimeOrContextBuilderBudgets() async throws {
            let tool = "ask_oracle"
            try await withHarness { harness in
                let driver = harness.driver
                let oracle = driver.window.oracleViewModel
                let connection = try await driver.connectInvokingAgent(driver.resolve())
                var scoped = false
                var watchdogEnabled: Bool?
                oracle.streamWatchdogScheduledForTesting = { _, _, enabled in watchdogEnabled = enabled }
                oracle.contextBuilderBeforeAvailabilityForTesting = { _, _ in scoped = true }
                var reply: [String: Any]?
                harness.start {
                    reply = try await self.payload(connection, tool: tool, args: [
                        "new_chat": .bool(true), "message": .string("Blocking compatibility"), "debug_primary_only": .bool(true)
                    ])
                }
                try await harness.waitForStream(.gpt54Mini)
                try await harness.emit(.gpt54Mini, text: "blocking ")
                XCTAssertFalse(harness.didSettle)
                XCTAssertFalse(scoped, "Omitted op must retain the existing blocking path")
                XCTAssertEqual(watchdogEnabled, true)
                harness.complete(.gpt54Mini, text: "complete")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                XCTAssertNil(reply?["job_id"])
                XCTAssertEqual(reply?["response"] as? String, "blocking complete")
            }
        }

        func testOrdinaryGroupedTicketObserverDisconnectAndOmittedOperationPreserveInteractivePolicy() async throws {
            for ticketed in [false, true] {
                try await withHarness { harness in
                    let driver = harness.driver
                    let oracle = driver.window.oracleViewModel
                    let jobs = WindowStatesManager.shared.longRunningJobs
                    let context = try await driver.resolve()
                    let initiating = try await driver.connectInvokingAgent(context)
                    var scopes: [ContextBuilderOracleLaneScope] = []
                    var watchdogs: [Bool] = []
                    oracle.contextBuilderBeforeAvailabilityForTesting = { lane, _ in scopes.append(lane) }
                    oracle.streamWatchdogScheduledForTesting = { _, _, enabled in watchdogs.append(enabled) }
                    var args: [String: Value] = [
                        "new_chat": .bool(true), "message": .string("Ordinary group compatibility"),
                        "model": .string(harness.preset.name)
                    ]
                    if ticketed {
                        args["op"] = .string("start")
                        args["detach"] = .bool(true)
                    }
                    var reply: [String: Any]?
                    harness.start { reply = try await self.payload(initiating, tool: "ask_oracle", args: args) }
                    try await harness.waitForStreams()
                    try await harness.emit(.gpt54Mini, text: "primary ")
                    try await harness.emit(.gpt54, text: "additional ")
                    XCTAssertFalse(watchdogs.isEmpty)
                    XCTAssertTrue(watchdogs.allSatisfy(\.self), "Ordinary grouped lanes keep interactive watchdogs")
                    let sessions = oracle.sessions.filter { $0.oracleGroupID != nil }
                    XCTAssertEqual(sessions.count, 2)
                    sessions.forEach { oracle.pinSession($0.id) }
                    defer { sessions.forEach { oracle.unpinSession($0.id) } }
                    let queries = try sessions.map { try XCTUnwrap(oracle.activeQueryId(for: $0.id)) }
                    var ticketID: UUID?
                    if ticketed {
                        try await harness.wait(harness.settled)
                        XCTAssertNil(harness.error)
                        ticketID = try XCTUnwrap(UUID(uuidString: XCTUnwrap(reply?["job_id"] as? String)))
                        XCTAssertEqual(scopes.count, 2, "Every ordinary ticket lane shares the group lifetime")
                        for scope in scopes {
                            XCTAssertEqual(scope.completionPolicy, .interactive)
                            XCTAssertTrue(scope.checkDeadlines(at: ProcessInfo.processInfo.systemUptime + 14400), "Ownership adds no Context Builder budget")
                        }
                        let id = try XCTUnwrap(ticketID)
                        let observer = Task { await jobs.store.wait(id: id, timeout: 60) }
                        observer.cancel()
                        _ = await observer.value
                        await initiating.cleanup()
                        let reconnected = try await driver.connectInvokingAgent(context)
                        let observed = try await self.payload(reconnected, tool: "ask_oracle", args: ["op": .string("poll"), "job_id": .string(id.uuidString)])
                        XCTAssertEqual((observed["job"] as? [String: Any])?["status"] as? String, "running")
                        XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 1)
                        for (session, query) in zip(sessions, queries) {
                            XCTAssertEqual(oracle.activeQueryId(for: session.id), query)
                            XCTAssertTrue(oracle.isSessionStreaming(session.id))
                        }
                    } else {
                        XCTAssertFalse(harness.didSettle, "Omitted op blocks until the configured group completes")
                        XCTAssertTrue(scopes.isEmpty, "Blocking callers do not gain a ticket lifetime")
                    }
                    harness.complete(.gpt54Mini, text: "complete")
                    harness.complete(.gpt54, text: "complete")
                    if let ticketID {
                        let terminal = await jobs.store.wait(id: ticketID, timeout: 10)
                        XCTAssertEqual(terminal?.status, .completed)
                        XCTAssertTrue(scopes.allSatisfy(\.hasDrainedForTesting))
                        XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 0)
                    } else {
                        try await harness.wait(harness.settled)
                        XCTAssertNil(harness.error)
                        XCTAssertNil(reply?["job_id"])
                        XCTAssertEqual(reply?["status"] as? String, "completed")
                        let lanes = try XCTUnwrap(reply?["oracle_results"] as? [[String: Any]])
                        XCTAssertEqual(lanes.map { $0["status"] as? String }, ["completed", "completed"])
                    }
                    for (session, query) in zip(sessions, queries) {
                        XCTAssertEqual(oracle.getChatMessage(withId: query)?.content, session.preferredAIModel == AIModel.gpt54Mini.rawValue ? "primary complete" : "additional complete")
                    }
                }
            }
        }

        private func payload(_ connection: ContextBuilderMultiRootDiscoveryDriver.RoutedConnection, tool: String, args: [String: Value]) async throws -> [String: Any] {
            let reply = try await connection.client.callTool(name: tool, arguments: args.merging(["_rawJSON": .bool(true)]) { _, new in new })
            let text = reply.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined(separator: "\n")
            XCTAssertNotEqual(reply.isError, true, text)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }

        private func withHarness(_ body: @escaping @MainActor (GroupedOracleHarness) async throws -> Void) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A", "B", "C"], routedRuntime: true) { driver in
                let harness = try GroupedOracleHarness(driver: driver)
                do {
                    try await body(harness)
                    await harness.close()
                } catch {
                    await harness.close()
                    throw error
                }
            }
        }
    }

    @MainActor
    final class SingleOracleFollowUpGenerationTests: XCTestCase {
        func testCancelledBackgroundFollowUpDrainsWithoutClearingReplacementGeneration() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A", "B", "C"], routedRuntime: true) { driver in
                let harness = try GroupedOracleHarness(driver: driver)
                let oracle = driver.window.oracleViewModel
                let vm = driver.vm
                var tasks: [Task<Void, Never>] = []
                do {
                    GlobalSettingsStore.shared.setWorkspaceAgentModelsProfile(workspaceID: driver.fixture.workspace.id, profile: .init(
                        planningModelRaw: AIModel.gpt54Mini.rawValue, additionalOracleModelRaws: []
                    ))
                    let index = try XCTUnwrap(driver.manager.workspaces.firstIndex { $0.id == driver.fixture.workspace.id })
                    driver.manager.workspaces[index].composeTabs[0].promptText = "Build the controlled plan"
                    driver.window.promptManager.loadComposeTabsFromWorkspace(driver.manager.workspaces[index], syncPromptText: true)
                    let gate = driver.fixture.makeGate()
                    let entered = XCTestExpectation(description: "A owned finalizer entered")
                    let released = XCTestExpectation(description: "Cancel A released exact dependencies before finalizer join")
                    var scopes: [ContextBuilderOracleLaneScope] = []
                    oracle.contextBuilderBeforeAvailabilityForTesting = { scope, _ in scopes.append(scope) }
                    oracle.contextBuilderBeforeFinalizationForTesting = { scope in
                        if scope === scopes.first {
                            entered.fulfill()
                            await gate.wait()
                        }
                    }
                    oracle.contextBuilderLaneReleasedForTesting = { scope in
                        if scope === scopes.first { released.fulfill() }
                    }

                    vm.startBackgroundPlanGeneration(tabID: driver.tabID, oracleViewModel: oracle)
                    let session = try XCTUnwrap(vm.sessions[driver.tabID])
                    let taskA = try XCTUnwrap(session.backgroundPlanTask)
                    tasks.append(taskA)
                    let generationA = try XCTUnwrap(session.backgroundPlanGenerationID)
                    try await harness.waitForStream(.gpt54Mini)
                    harness.complete(.gpt54Mini, text: "cancelled A")
                    try await harness.wait(entered)
                    let scopeA = try XCTUnwrap(scopes.first)
                    vm.cancelBackgroundPlanGeneration(forTabID: driver.tabID)
                    try await harness.wait(released)
                    XCTAssertFalse(scopeA.hasDrainedForTesting, "Cancel releases dependencies but still owes the real finalizer")

                    let registeredB = harness.expectNextStream(.gpt54Mini)
                    vm.startBackgroundPlanGeneration(tabID: driver.tabID, oracleViewModel: oracle)
                    let taskB = try XCTUnwrap(session.backgroundPlanTask)
                    tasks.append(taskB)
                    let generationB = try XCTUnwrap(session.backgroundPlanGenerationID)
                    XCTAssertNotEqual(generationA, generationB)
                    try await harness.wait(registeredB)
                    try await harness.emit(.gpt54Mini, text: "replacement ")
                    let routeB = try XCTUnwrap(session.generatedAnswerRoute)
                    let followUpB = try XCTUnwrap(session.followUpOracleSessionID)
                    XCTAssertEqual(session.backgroundPlanResponseText, "replacement ")
                    XCTAssertEqual(scopes.count, 2, "Actual single-lane A and B, not a grouped request")

                    gate.release()
                    await taskA.value
                    XCTAssertTrue(scopeA.hasDrainedForTesting)
                    XCTAssertEqual(session.backgroundPlanGenerationID, generationB)
                    XCTAssertNotNil(session.backgroundPlanTask)
                    XCTAssertTrue(session.isBackgroundPlanGenerating, "Drained A must not clear B's generating state")
                    XCTAssertEqual(session.followUpOracleSessionID, followUpB)
                    XCTAssertEqual(session.generatedAnswerRoute, routeB)
                    XCTAssertEqual(session.backgroundPlanResponseText, "replacement ")
                    try await harness.emit(.gpt54Mini, text: "continues ")
                    XCTAssertEqual(session.backgroundPlanResponseText, "replacement continues ", "B progress remains publishable after A drains")
                    harness.complete(.gpt54Mini, text: "complete")
                    await taskB.value
                    XCTAssertTrue(scopes.allSatisfy(\.hasDrainedForTesting))
                    XCTAssertEqual(session.backgroundPlanResponseText, "replacement continues complete")
                    XCTAssertEqual(session.generatedAnswerRoute, routeB)
                    XCTAssertFalse(session.isBackgroundPlanGenerating)
                    XCTAssertNil(session.backgroundPlanGenerationID)
                    XCTAssertNil(session.backgroundPlanTask)
                    XCTAssertNil(session.backgroundPlanError)
                    XCTAssertNil(session.followUpOracleSessionID)
                    XCTAssertEqual(harness.registeredModels, [.gpt54Mini, .gpt54Mini])
                    await harness.close()
                } catch {
                    vm.cancelBackgroundPlanGeneration(forTabID: driver.tabID)
                    await harness.close()
                    for task in tasks {
                        await task.value
                    }
                    throw error
                }
            }
        }
    }

    /// One clock drives both the real legacy watchdog and the candidate lane scope.
    /// Sleeps acknowledge registration and are cancellation-connected; advancing never guesses
    /// how many executor yields constitute an observation.
    @MainActor
    final class OracleSupervisionTestClock {
        private(set) var now: TimeInterval = 0
        private var waits: [UUID: (deadline: TimeInterval, seconds: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = [:]
        private var armWaits: [(TimeInterval, XCTestExpectation)] = []

        func sleep(_ seconds: TimeInterval) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    waits[id] = (now + seconds, seconds, continuation)
                    let matching = armWaits.filter { $0.0 == seconds }
                    armWaits.removeAll { $0.0 == seconds }
                    matching.forEach { $0.1.fulfill() }
                }
            } onCancel: {
                Task { @MainActor in self.waits.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
            }
        }

        func advance(to value: TimeInterval) {
            precondition(value >= now)
            now = value
            let due = waits.filter { $0.value.deadline <= now }
            for (id, wait) in due {
                waits.removeValue(forKey: id)
                wait.continuation.resume()
            }
        }

        func waitForSleep(_ seconds: TimeInterval) async throws {
            if waits.values.contains(where: { $0.seconds == seconds }) { return }
            let event = XCTestExpectation(description: "scheduler armed \(seconds)s")
            armWaits.append((seconds, event))
            guard await XCTWaiter.fulfillment(of: [event], timeout: 5) == .completed else {
                throw GroupedOracleHarness.Failure.checkpoint(event.expectationDescription)
            }
        }

        func releaseAll() {
            let pending = waits.values
            waits.removeAll()
            pending.forEach { $0.continuation.resume(throwing: CancellationError()) }
        }
    }

    @MainActor
    final class StandaloneOracleTicketRecoveryTests: XCTestCase {
        func testTypedCodexInputLimitGuidanceSurvivesTicketFailureAndChatPersistence() async throws {
            let failure = CodexAppServerClient.RequestFailure(
                method: "turn/start", code: -32602,
                message: "Input exceeds the maximum length of 1048576 characters (1049069 Unicode scalar values supplied).",
                data: .object([
                    "input_error_code": .string("input_too_large"),
                    "max_chars": .number(1_048_576), "actual_chars": .number(1_049_069)
                ])
            )
            let wrapped = AIProviderError.apiError(source: CodexAppServerClient.ClientError.requestFailed(failure))
            let expected = failure.userFacingMessage
            XCTAssertEqual(wrapped.asFriendlyString(), expected, "The real provider wrapper must retain the typed input-limit guidance")
            try await withHarness { harness in
                let driver = harness.driver
                let oracle = driver.window.oracleViewModel
                GlobalSettingsStore.shared.setMCPShowModelPresets(false, commit: false)
                GlobalSettingsStore.shared.setWorkspaceAgentModelsProfile(workspaceID: driver.fixture.workspace.id, profile: .init(
                    planningModelRaw: AIModel.gpt54Mini.rawValue, additionalOracleModelRaws: []
                ))
                let connection = try await self.connect(tool: "ask_oracle", driver: driver)
                let started = try await self.payload(connection, tool: "ask_oracle", args: [
                    "op": .string("start"), "detach": .bool(true), "new_chat": .bool(true),
                    "message": .string("Controlled typed rejection; no oversized input or remote request")
                ])
                let id = try XCTUnwrap(started["job_id"] as? String)
                try await harness.waitForStream(.gpt54Mini)
                let created = try XCTUnwrap(oracle.sessions.last)
                oracle.pinSession(created.id)
                defer { oracle.unpinSession(created.id) }
                // Deliver the exact Codex provider error through the real Oracle failure owner.
                // The controlled stream avoids invoking Codex or replaying the live oversized request.
                harness.streams[.gpt54Mini]?.continuation.finish(throwing: wrapped)
                let terminal = try await self.payload(connection, tool: "ask_oracle", args: [
                    "op": .string("wait"), "job_id": .string(id), "timeout": .int(10)
                ])
                let job = try XCTUnwrap(terminal["job"] as? [String: Any])
                XCTAssertEqual(job["status"] as? String, "failed")
                XCTAssertEqual(job["chat_id"] as? String, created.shortID)
                let error = try XCTUnwrap(job["error"] as? [String: Any])
                XCTAssertEqual(error["code"] as? String, "failed", "Formatting does not reclassify the ticket")
                XCTAssertEqual(error["message"] as? String, expected)
                XCTAssertTrue(expected.contains("Reduce the selected context or message"))
                XCTAssertTrue(expected.contains("does not truncate or automatically retry"))
                XCTAssertNil(terminal["response"], "A local rejection is not a paid successful reply")
                XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 0)
                await oracle.drainTrackedAutosaves(for: driver.fixture.workspace.id)
                let persisted = try XCTUnwrap(oracle.sessions.first { $0.id == created.id })
                let saved = try await oracle.chatData.loadChatSession(from: XCTUnwrap(persisted.fileURL))
                let savedError = try XCTUnwrap(saved.messages.last { !$0.isUser }?.rawText)
                XCTAssertTrue(savedError.hasSuffix(expected), "Actual saved assistant history must retain exact guidance after its existing Error block prefix")
                XCTAssertEqual(harness.registeredModels, [.gpt54Mini], "No retry or additional lane is introduced by formatting")
            }
        }

        func testTypedCodexNonInputFailureKeepsPrivateDataOutOfTicketAndChatPersistence() async throws {
            let privateMarker = "PRIVATE_CODEX_ERROR_DATA"
            let publicMessage = "Codex could not complete this request."
            let failure = CodexAppServerClient.RequestFailure(
                method: "turn/start", code: -32603, message: publicMessage,
                data: .object(["diagnostic": .string(privateMarker)])
            )
            let wrapped = AIProviderError.apiError(source: CodexAppServerClient.ClientError.requestFailed(failure))
            XCTAssertEqual(wrapped.asFriendlyString(), publicMessage, "Only the public message belongs at the friendly boundary")
            try await withHarness { harness in
                let driver = harness.driver
                let oracle = driver.window.oracleViewModel
                GlobalSettingsStore.shared.setMCPShowModelPresets(false, commit: false)
                GlobalSettingsStore.shared.setWorkspaceAgentModelsProfile(workspaceID: driver.fixture.workspace.id, profile: .init(
                    planningModelRaw: AIModel.gpt54Mini.rawValue, additionalOracleModelRaws: []
                ))
                let connection = try await self.connect(tool: "ask_oracle", driver: driver)
                let started = try await self.payload(connection, tool: "ask_oracle", args: [
                    "op": .string("start"), "detach": .bool(true), "new_chat": .bool(true),
                    "message": .string("Controlled non-input Codex failure; no remote request")
                ])
                let id = try XCTUnwrap(started["job_id"] as? String)
                try await harness.waitForStream(.gpt54Mini)
                let created = try XCTUnwrap(oracle.sessions.last)
                oracle.pinSession(created.id)
                defer { oracle.unpinSession(created.id) }
                harness.streams[.gpt54Mini]?.continuation.finish(throwing: wrapped)
                let terminal = try await self.payload(connection, tool: "ask_oracle", args: [
                    "op": .string("wait"), "job_id": .string(id), "timeout": .int(10)
                ])
                let job = try XCTUnwrap(terminal["job"] as? [String: Any])
                XCTAssertEqual(job["status"] as? String, "failed")
                XCTAssertEqual(job["chat_id"] as? String, created.shortID)
                let error = try XCTUnwrap(job["error"] as? [String: Any])
                XCTAssertEqual(error["code"] as? String, "failed")
                XCTAssertEqual(error["message"] as? String, publicMessage, "Native failed tickets must not expose typed error data")
                XCTAssertNil(terminal["response"])
                XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 0)
                await oracle.drainTrackedAutosaves(for: driver.fixture.workspace.id)
                let persisted = try XCTUnwrap(oracle.sessions.first { $0.id == created.id })
                let saved = try await oracle.chatData.loadChatSession(from: XCTUnwrap(persisted.fileURL))
                let savedError = try XCTUnwrap(saved.messages.last { !$0.isUser }?.rawText)
                XCTAssertTrue(savedError.hasSuffix(publicMessage), "Saved assistant history must retain the public message")
                XCTAssertFalse(savedError.contains(privateMarker), "Private provider error data must not be persisted")
                XCTAssertFalse(savedError.contains("CodexAppServerClient.RequestFailure"), "Internal typed error dumps must not be persisted")
                XCTAssertEqual(harness.registeredModels, [.gpt54Mini])
            }
        }

        func testCreatedStandaloneChatSurvivesPartialFailureAndCancellationInEveryRecoveryProjection() async throws {
            for tool in ["ask_oracle", "oracle_send"] {
                for cancelled in [false, true] {
                    try await withHarness { harness in
                        let driver = harness.driver
                        let oracle = driver.window.oracleViewModel
                        GlobalSettingsStore.shared.setMCPShowModelPresets(false, commit: false)
                        GlobalSettingsStore.shared.setWorkspaceAgentModelsProfile(workspaceID: driver.fixture.workspace.id, profile: .init(
                            planningModelRaw: AIModel.gpt54Mini.rawValue, additionalOracleModelRaws: []
                        ))
                        let connection = try await self.connect(tool: tool, driver: driver)
                        let started = try await self.payload(connection, tool: tool, args: [
                            "op": .string("start"), "detach": .bool(true), "new_chat": .bool(true),
                            "message": .string("PRIVATE_RECOVERY_INPUT")
                        ])
                        let id = try XCTUnwrap(started["job_id"] as? String)
                        try await harness.waitForStream(.gpt54Mini)
                        XCTAssertEqual(harness.registeredModels, [.gpt54Mini], "Real singleton roster, not a group child")
                        let created = try XCTUnwrap(oracle.sessions.last)
                        let query = try XCTUnwrap(oracle.activeQueryId(for: created.id))
                        oracle.pinSession(created.id)
                        defer { oracle.unpinSession(created.id) }
                        try await harness.emit(.gpt54Mini, text: "PRIVATE_PAID_PARTIAL")
                        XCTAssertEqual(oracle.getChatMessage(withId: query)?.content, "PRIVATE_PAID_PARTIAL")
                        let running = try await self.payload(connection, tool: tool, args: ["op": .string("poll"), "job_id": .string(id)])
                        XCTAssertEqual((running["job"] as? [String: Any])?["status"] as? String, "running", "Publishing a handle must not fake completion")
                        XCTAssertEqual((running["job"] as? [String: Any])?["chat_id"] as? String, created.shortID)
                        if cancelled {
                            _ = try await self.payload(connection, tool: tool, args: ["op": .string("cancel"), "job_id": .string(id)])
                        } else {
                            harness.streams[.gpt54Mini]?.continuation.finish(throwing: ChatToolError.internalError("Controlled failure after accepted partial"))
                        }
                        let terminal = try await self.payload(connection, tool: tool, args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(10)])
                        XCTAssertEqual((terminal["job"] as? [String: Any])?["status"] as? String, cancelled ? "cancelled" : "failed")
                        XCTAssertEqual((terminal["job"] as? [String: Any])?["chat_id"] as? String, created.shortID, "Created chats require recovery, never an optional nil route")
                        XCTAssertNil(terminal["response"], "Partial paid text remains in history, not a fabricated successful reply")
                        XCTAssertEqual(driver.window.mcpServer.test_activeToolExecutionCount(), 0, "Terminal still follows exact local drain")
                        await oracle.drainTrackedAutosaves(for: driver.fixture.workspace.id)
                        let persisted = try XCTUnwrap(oracle.sessions.first { $0.id == created.id })
                        let savedChat = try await oracle.chatData.loadChatSession(from: XCTUnwrap(persisted.fileURL))
                        XCTAssertEqual(savedChat.shortID, created.shortID)
                        XCTAssertTrue(savedChat.messages.last { !$0.isUser }?.rawText.hasPrefix("PRIVATE_PAID_PARTIAL") == true, "Provider failure may append its diagnostic, but must retain accepted paid text")
                        let formatted = try await connection.client.callTool(name: tool, arguments: ["op": .string("poll"), "job_id": .string(id)])
                        XCTAssertNotEqual(formatted.isError, true)
                        XCTAssertTrue(self.text(formatted.content).contains("**Oracle chat**: `\(created.shortID)`"), "Actual default formatted response must expose the same recovery handle")
                        try await self.assertSavedRecovery(terminal, chatID: created.shortID, tool: tool, driver: driver)
                    }
                }
            }
        }

        func testGroupedTicketKeepsCanonicalPrimaryRecoveryWithoutStandaloneLanePublication() async throws {
            for tool in ["ask_oracle", "oracle_send"] {
                try await withHarness { harness in
                    let driver = harness.driver
                    let oracle = driver.window.oracleViewModel
                    let connection = try await self.connect(tool: tool, driver: driver)
                    let started = try await self.payload(connection, tool: tool, args: [
                        "op": .string("start"), "detach": .bool(true), "new_chat": .bool(true),
                        "message": .string("Group recovery"), "model": .string(harness.preset.name)
                    ])
                    let id = try XCTUnwrap(started["job_id"] as? String)
                    try await harness.waitForStreams()
                    let primary = try XCTUnwrap(oracle.sessions.first { $0.preferredAIModel == AIModel.gpt54Mini.rawValue })
                    let additional = try XCTUnwrap(oracle.sessions.first { $0.preferredAIModel == AIModel.gpt54.rawValue })
                    let observed = try await self.payload(connection, tool: tool, args: ["op": .string("poll"), "job_id": .string(id)])
                    let job = try XCTUnwrap(observed["job"] as? [String: Any])
                    XCTAssertNil(job["chat_id"], "Group children must not publish standalone metadata over group authority")
                    let lanes = try XCTUnwrap(job["oracle_lanes"] as? [[String: Any]])
                    XCTAssertEqual(lanes.map { $0["chat_id"] as? String }, [primary.shortID, additional.shortID])
                    try await harness.emit(.gpt54Mini, text: "paid primary ")
                    harness.complete(.gpt54Mini, text: "complete")
                    harness.streams[.gpt54]?.continuation.finish(throwing: ChatToolError.internalError("Controlled additional failure"))
                    let terminal = try await self.payload(connection, tool: tool, args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(10)])
                    XCTAssertEqual(terminal["status"] as? String, "partial_failure")
                    XCTAssertEqual(terminal["chat_id"] as? String, primary.shortID)
                    XCTAssertEqual((terminal["job"] as? [String: Any])?["chat_id"] as? String, primary.shortID)
                    let results = try XCTUnwrap(terminal["oracle_results"] as? [[String: Any]])
                    XCTAssertEqual(results.map { $0["chat_id"] as? String }, [primary.shortID, additional.shortID])
                    XCTAssertEqual(results.first?["response"] as? String, "paid primary complete")
                }
            }
        }

        private func assertSavedRecovery(_ native: [String: Any], chatID: String, tool: String, driver: ContextBuilderMultiRootDiscoveryDriver) async throws {
            let raw = try JSONSerialization.data(withJSONObject: native)
            let open = AgentOracleOpenContext(windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, tabID: driver.tabID)
            for representation in [native, ["rawOutput": native], ["rawOutput": String(decoding: raw, as: UTF8.self)]] {
                var item = try AgentChatItem.toolResult(name: tool, argsJSON: #"{"message":"PRIVATE_RECOVERY_INPUT"}"#, resultJSON: String(decoding: JSONSerialization.data(withJSONObject: representation), as: UTF8.self), isError: false, sequenceIndex: 1)
                item.toolInvocationID = UUID()
                let session = AgentSession(workspaceID: driver.fixture.workspace.id, composeTabID: driver.tabID, name: "Standalone recovery", transcript: AgentTranscriptIO.importLegacyItems([.user("Inspect", sequenceIndex: 0), item]), lastRunState: "completed")
                let file = try await AgentSessionDataService().saveAgentSession(session, for: driver.fixture.workspace)
                let bytes = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(bytes.contains("PRIVATE_RECOVERY_INPUT"))
                XCTAssertFalse(bytes.contains("PRIVATE_PAID_PARTIAL"))
                let loaded = try await AgentSessionDataService().loadAgentSession(from: file)
                let projection = try AgentTranscriptProjectionBuilder.build(from: XCTUnwrap(loaded.transcript))
                let restored = try XCTUnwrap((projection.archivedBlocks + projection.workingBlocks).flatMap(\.rows).first { $0.kind == .toolResult && $0.toolInvocationID == item.toolInvocationID })
                XCTAssertNil(restored.toolArgsJSON)
                let restoredRaw = try XCTUnwrap(restored.toolResultJSON)
                XCTAssertLessThanOrEqual(restoredRaw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
                let data = try XCTUnwrap(ToolResultDTOs.LongRunningJobTicketDTO.nativeJSONData(from: restoredRaw))
                let ticket = try JSONDecoder().decode(ToolResultDTOs.LongRunningJobTicketDTO.self, from: data)
                XCTAssertEqual(ticket.job.chatID, chatID, "Bounded saved/restored projection must retain the exact created handle")
                for row in [item, restored] {
                    let route = AgentOraclePopoverRoute(notificationUserInfo: oracleToolResultPopoverUserInfo(item: row, openContext: open))
                    XCTAssertEqual(route?.chatID, chatID)
                    XCTAssertEqual(route?.tabID, driver.tabID)
                    XCTAssertEqual(route?.presentation, .generatedAnswerReadOnly)
                    XCTAssertNil(oracleToolResultPopoverUserInfo(item: row, openContext: .init(windowID: open.windowID, workspaceID: open.workspaceID, tabID: UUID())))
                    XCTAssertEqual(ChatSendResultCard(item: row, oracleOpenContext: open).status, .failure)
                }
            }
        }

        private func connect(tool: String, driver: ContextBuilderMultiRootDiscoveryDriver) async throws -> ContextBuilderMultiRootDiscoveryDriver.RoutedConnection {
            if tool == "ask_oracle" { return try await driver.connectInvokingAgent(driver.resolve()) }
            // oracle_send belongs to app-backed CLI clients, not the restricted Agent tool set.
            await driver.window.mcpServer.startServer()
            let connection = try await driver.connect(name: "RepoPromptCLI-recovery", purpose: .unknown)
            let bound = try await connection.client.callTool(name: "bind_context", arguments: [
                "op": .string("bind"), "context_id": .string(driver.tabID.uuidString),
                "_windowID": .int(driver.window.windowID)
            ])
            XCTAssertNotEqual(bound.isError, true, text(bound.content))
            return connection
        }

        private func text(_ content: [MCP.Tool.Content]) -> String {
            content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined(separator: "\n")
        }

        private func payload(_ connection: ContextBuilderMultiRootDiscoveryDriver.RoutedConnection, tool: String, args: [String: Value]) async throws -> [String: Any] {
            let reply = try await connection.client.callTool(name: tool, arguments: args.merging(["_rawJSON": .bool(true)]) { _, new in new })
            XCTAssertNotEqual(reply.isError, true, text(reply.content))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(reply.content).utf8)) as? [String: Any])
        }

        private func withHarness(_ body: @escaping @MainActor (GroupedOracleHarness) async throws -> Void) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["OracleRecovery"], routedRuntime: true) { driver in
                let harness = try GroupedOracleHarness(driver: driver)
                do {
                    try await body(harness)
                    await harness.close()
                } catch {
                    await harness.close()
                    throw error
                }
            }
        }
    }

    @MainActor
    private final class GroupedOracleHarness {
        enum Failure: Error { case checkpoint(String) }
        let driver: ContextBuilderMultiRootDiscoveryDriver
        let clock = OracleSupervisionTestClock()
        let preset: ModelPreset
        let settled = XCTestExpectation(description: "consumer result settled")
        let oldWatchdogChecked = XCTestExpectation(description: "legacy watchdog checked after its armed grace")
        let cancelled: [AIModel: XCTestExpectation] = [
            .gpt54Mini: XCTestExpectation(description: "primary stream cancelled by production owner"),
            .gpt54: XCTestExpectation(description: "auxiliary stream cancelled by production owner")
        ]
        var uiReply: ChatSendReply?
        var mcpReply: [String: Any]?
        var error: Error?
        private(set) var didSettle = false
        private(set) var interactiveWatchdogEnabled = false
        private(set) var interactiveWatchdogObserved = false
        private var remoteCleanupTasks: [Task<Void, Never>] = []
        private(set) var streams: [AIModel: (id: UUID, continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation)] = [:]
        var beforeTransportReturn: ((UUID) async -> Void)?
        private var streamEvents: [AIModel: XCTestExpectation] = [:]
        private var outputEvent: (text: String, event: XCTestExpectation)?
        private var producers: [Task<Void, Never>] = []
        private var allStreams: [(id: UUID, continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation)] = []
        private(set) var registeredModels: [AIModel] = []
        private var request: Task<Void, Never>?
        private var producerExits = 0
        private let previousPresets: [ModelPreset]
        private let previousExposure: Bool
        private let previousDisabled: Bool

        init(driver: ContextBuilderMultiRootDiscoveryDriver) throws {
            self.driver = driver
            let settings = GlobalSettingsStore.shared
            previousPresets = ModelPresetsManager.shared.presets
            previousExposure = settings.mcpShowModelPresets()
            previousDisabled = settings.mcpTemporarilyDisablePresets()
            preset = try ModelPreset(name: "Controlled 1033", models: [.gpt54Mini, .gpt54])
            ModelPresetsManager.shared.presets = [preset]
            settings.setMCPShowModelPresets(true, commit: false)
            settings.setMCPTemporarilyDisablePresets(false, commit: false)
            settings.setWorkspaceAgentModelsProfile(workspaceID: driver.fixture.workspace.id, profile: .init(
                planningModelRaw: AIModel.gpt54Mini.rawValue, additionalOracleModelRaws: [AIModel.gpt54.rawValue]
            ))
            driver.window.apiSettingsViewModel.openAIApiKey = "test-key"
            driver.window.apiSettingsViewModel.isOpenAIKeyValid = true
            let oracle = driver.window.oracleViewModel
            oracle.streamWatchdogNowForTesting = { [clock] in Date(timeIntervalSince1970: clock.now) }
            oracle.streamWatchdogSleepForTesting = { [clock] in try await clock.sleep($0) }
            driver.vm.oracleGroupClockForTesting = { [clock] in clock.now }
            driver.vm.oracleGroupSleepForTesting = { [clock] in try await clock.sleep($0) }
            oracle.streamWatchdogScheduledForTesting = { [weak self] _, grace, enabled in
                if grace == 10 {
                    self?.interactiveWatchdogObserved = true
                    self?.interactiveWatchdogEnabled = enabled
                }
            }
            oracle.streamWatchdogCheckedForTesting = { [weak self] _ in self?.oldWatchdogChecked.fulfill() }
            oracle.providerConversationCleanupForTesting = { _ in XCTFail("Unexpected fixture cleanup handle") }
            oracle.providerCleanupTaskScheduledForTesting = { [weak self] task in self?.remoteCleanupTasks.append(task) }
            oracle.streamOutputObservedForTesting = { [weak self] _, output in
                guard let self, let pending = outputEvent, pending.text == output.text else { return }
                outputEvent = nil
                pending.event.fulfill()
            }
            oracle.setOraclePostPackagingTransportOverrideForTesting { [unowned self] _, model in
                let id = UUID()
                let stream = AsyncThrowingStream<ChatStreamOutput, Error>.makeStream()
                let stopped = AsyncStream<Void>.makeStream()
                let cancelledEvent = cancelled[model]!
                stream.continuation.onTermination = { reason in
                    switch reason {
                    case .cancelled: cancelledEvent.fulfill()
                    case let .finished(error): if error is CancellationError { cancelledEvent.fulfill() }
                    @unknown default: break
                    }
                    stopped.continuation.finish()
                }
                let producer = Task { @MainActor in
                    for await _ in stopped.stream {}
                    self.producerExits += 1
                }
                producers.append(producer)
                await driver.window.aiQueriesService.registerControlledStreamForTesting(
                    id: id, continuation: stream.continuation, producer: producer
                )
                streams[model] = (id, stream.continuation)
                allStreams.append((id, stream.continuation))
                registeredModels.append(model)
                streamEvents.removeValue(forKey: model)?.fulfill()
                await beforeTransportReturn?(id)
                return (id, stream.stream)
            }
        }

        func startUI(onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil) throws {
            let index = try XCTUnwrap(driver.manager.workspaces.firstIndex { $0.id == driver.fixture.workspace.id })
            driver.manager.workspaces[index].composeTabs[0].promptText = "Build the controlled plan"
            driver.window.promptManager.loadComposeTabsFromWorkspace(driver.manager.workspaces[index], syncPromptText: true)
            start {
                self.uiReply = try await self.driver.vm.generatePlanFromDiscovery(
                    tabID: self.driver.tabID, originWorkspaceID: self.driver.fixture.workspace.id,
                    oracleViewModel: self.driver.window.oracleViewModel, onProgress: onProgress
                )
            }
        }

        func cancelRequest() {
            request?.cancel()
        }

        func expectNextStream(_ model: AIModel) -> XCTestExpectation {
            let event = XCTestExpectation(description: "registered controlled \(model.rawValue) stream")
            streamEvents[model] = event
            return event
        }

        func waitForStream(_ model: AIModel) async throws {
            if streams[model] != nil { return }
            try await wait(expectNextStream(model))
        }

        func start(_ operation: @escaping @MainActor () async throws -> Void) {
            request = Task { @MainActor in
                do { try await operation() } catch { self.error = error }
                didSettle = true
                settled.fulfill()
            }
        }

        func wait(_ event: XCTestExpectation) async throws {
            guard await XCTWaiter.fulfillment(of: [event], timeout: 10) == .completed else {
                throw Failure.checkpoint(event.expectationDescription)
            }
        }

        func waitForStreams() async throws {
            for model in [AIModel.gpt54Mini, .gpt54] where streams[model] == nil {
                let event = XCTestExpectation(description: "registered controlled \(model.rawValue) stream")
                streamEvents[model] = event
                try await wait(event)
            }
        }

        func emit(_ model: AIModel, text: String) async throws {
            try await emitOutput(model, output: .init(text: text, reasoning: nil, tokens: .init()))
        }

        func emitOutput(_ model: AIModel, output: ChatStreamOutput) async throws {
            let event = XCTestExpectation(description: "Oracle consumed controlled output")
            outputEvent = (output.text, event)
            streams[model]!.continuation.yield(output)
            try await wait(event)
        }

        @discardableResult
        func complete(_ model: AIModel, text: String, reasoning: String? = nil) -> AsyncThrowingStream<ChatStreamOutput, Error>.Continuation.YieldResult? {
            let delivery = streams[model]?.continuation.yield(.init(text: text, reasoning: reasoning, tokens: .init(), terminalOutcome: .completed))
            streams[model]?.continuation.finish()
            return delivery
        }

        func close() async {
            // Release every fixture-owned dependency BEFORE joining, even after an assertion/escape.
            driver.fixture.releaseAllGates()
            allStreams.forEach { $0.continuation.finish(throwing: CancellationError()) }
            request?.cancel()
            clock.releaseAll()
            await request?.value
            // The fixture joins its own fake remote cleanup; production lane supervision does not.
            for cleanup in remoteCleanupTasks {
                await cleanup.value
            }
            for producer in producers {
                producer.cancel()
                await producer.value
            }
            for stream in allStreams {
                await driver.window.aiQueriesService.removeControlledStreamForTesting(id: stream.id)
            }
            XCTAssertEqual(producerExits, producers.count, "Controlled producer tasks drained (not a remote provider-disposal claim)")
            driver.window.mcpServer.contextBuilderExportFileOverrideForTesting = nil
            let oracle = driver.window.oracleViewModel
            // Oracle persistence is separately owned, not part of lane drainage. The fixture
            // must finish its workspace's tracked writes before the driver removes its files.
            await oracle.drainTrackedAutosaves(for: driver.fixture.workspace.id)
            oracle.setOraclePostPackagingTransportOverrideForTesting(nil)
            oracle.streamWatchdogNowForTesting = nil
            oracle.streamWatchdogSleepForTesting = nil
            oracle.streamOutputObservedForTesting = nil
            oracle.streamWatchdogCheckedForTesting = nil
            oracle.streamWatchdogScheduledForTesting = nil
            oracle.contextBuilderBeforeChatResolutionForTesting = nil
            oracle.contextBuilderBeforeAvailabilityForTesting = nil
            oracle.contextBuilderBeforeFinalizationForTesting = nil
            oracle.interactiveWatchdogBeforeFinalizationForTesting = nil
            oracle.interactiveWatchdogFinalizerScheduledForTesting = nil
            oracle.contextBuilderLaneReleasedForTesting = nil
            oracle.providerConversationCleanupForTesting = nil
            oracle.providerCleanupTaskScheduledForTesting = nil
            driver.vm.oracleGroupClockForTesting = nil
            driver.vm.oracleGroupSleepForTesting = nil
            ModelPresetsManager.shared.presets = previousPresets
            GlobalSettingsStore.shared.setMCPShowModelPresets(previousExposure, commit: false)
            GlobalSettingsStore.shared.setMCPTemporarilyDisablePresets(previousDisabled, commit: false)
        }
    }
#endif
