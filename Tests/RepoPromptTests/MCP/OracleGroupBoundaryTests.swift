import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import RepoPromptSettingsCore
import XCTest

#if DEBUG
    @MainActor
    final class OracleGroupBoundaryTests: XCTestCase {
        func testOracleSendStartWithChatIDDoesNotRebind() async {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            await assertStopsAfterRoute(
                fixture,
                args: [
                    "message": .string("start fresh"),
                    "chat_id": .string("existing-chat"),
                    "new_chat": .bool(true)
                ]
            )
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testOracleSendInvalidContinuationModelDoesNotRebind() async throws {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            do {
                _ = try await fixture.service.executeOracleSend(args: [
                    "message": .string("continue"),
                    "chat_id": .string("existing-chat"),
                    "model": .string("override-model")
                ], invocationContext: fixture.invocationContext)
                XCTFail("Expected invalid continuation route")
            } catch OracleBoundaryTestStop.afterRoute {
                XCTFail("Invalid route reached tab resolution")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("model"), error.localizedDescription)
            }
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testOracleSendValidContinuationRebindsOnce() async {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            await assertStopsAfterRoute(
                fixture,
                args: [
                    "message": .string("continue"),
                    "chat_id": .string("  existing-chat  ")
                ]
            )
            XCTAssertEqual(fixture.rebindRecorder.chatIDs, ["existing-chat"])
        }

        func testOracleSendMessageOnlyUsesImplicitSelectionWithoutRebind() async {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            await assertStopsAfterRoute(
                fixture,
                args: ["message": .string("continue selected")]
            )
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testOracleSendMessageOnlyRejectsModelBeforeTabResolution() async {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            do {
                _ = try await fixture.service.executeOracleSend(args: [
                    "message": .string("continue selected"),
                    "model": .string("override-model")
                ], invocationContext: fixture.invocationContext)
                XCTFail("Expected implicit continuation model rejection")
            } catch OracleBoundaryTestStop.afterRoute {
                XCTFail("Invalid route reached tab resolution")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("model"), error.localizedDescription)
            }
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testOracleSendExplicitStartAllowsModelWithoutRebind() async {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            await assertStopsAfterRoute(
                fixture,
                args: [
                    "message": .string("start"),
                    "new_chat": .bool(true),
                    "model": .string("override-model")
                ]
            )
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testOracleSendMessageOnlyForwardingDoesNotSynthesizeStartArguments() async throws {
            let fixture = makeOracleSendFixture(stopAfterRoute: false)
            defer { fixture.cleanup() }

            _ = try await fixture.service.executeOracleSend(args: [
                "message": .string("continue selected")
            ], invocationContext: fixture.invocationContext)

            XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
            XCTAssertEqual(fixture.sendRecorder.calls[0]["message"], .string("continue selected"))
            XCTAssertNil(fixture.sendRecorder.calls[0]["chat_id"])
            XCTAssertNil(fixture.sendRecorder.calls[0]["new_chat"])
            XCTAssertNil(fixture.sendRecorder.calls[0]["model"])
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testAgentModeOracleSendDoesNotCompatibilityRebind() async {
            let fixture = makeOracleSendFixture(connectionID: UUID(), livePurpose: .agentModeRun)
            defer { fixture.cleanup() }

            await assertStopsAfterRoute(
                fixture,
                args: [
                    "message": .string("continue"),
                    "chat_id": .string("existing-chat")
                ]
            )
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testSingleOracleExportRemainsByteCompatible() {
            let request = OracleExportRequest(
                sourceTool: "oracle_send",
                mode: "plan",
                message: "Plan it",
                chatID: "primary-chat",
                response: "Primary answer"
            )
            XCTAssertEqual(AgentOracleExport.oracleMarkdown(request: request), "# Oracle Plan\n\nPrimary answer")
        }

        func testExportBoundaryDecodesCanonicalGroupAndRejectsMalformedEnvelope() throws {
            let group = try OracleGroupResult(
                groupID: OracleGroupID(rawValue: UUID()),
                status: .partialFailure,
                oracleResults: [
                    OracleLaneResult(
                        laneIndex: 0,
                        chatID: "chat-0",
                        providerID: "provider-0",
                        modelID: "model-0",
                        status: .completed,
                        response: "response-0"
                    ),
                    OracleLaneResult(
                        laneIndex: 1,
                        chatID: "chat-1",
                        providerID: "provider-1",
                        modelID: "model-1",
                        status: .failed,
                        error: OracleLaneError(
                            code: "failed",
                            message: "lane failed",
                            partialResponse: "partial-1"
                        )
                    )
                ],
                warnings: [OracleGroupWarning(code: "warning", message: "group warning")]
            )
            var fields = OracleGroupMCPCodec.groupFields(group)
            fields["chat_id"] = .string(group.primary.chatID)
            fields["response"] = try .string(XCTUnwrap(group.primary.response))

            XCTAssertEqual(try MCPOracleToolService.decodeOracleGroupResultForExport(fields), group)
            XCTAssertNil(try MCPOracleToolService.decodeOracleGroupResultForExport([
                "chat_id": .string("legacy"),
                "response": .string("legacy response")
            ]))

            fields["oracle_count"] = .int(3)
            XCTAssertThrowsError(try MCPOracleToolService.decodeOracleGroupResultForExport(fields))
        }

        func testTwoOracleExportRetainsCanonicalGroupDetails() throws {
            let groupID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
            let group = try OracleGroupResult(
                groupID: OracleGroupID(rawValue: groupID),
                status: .partialFailure,
                oracleResults: [
                    OracleLaneResult(
                        laneIndex: 0,
                        chatID: "primary-chat",
                        providerID: "configured-primary-provider",
                        modelID: "configured-primary-model",
                        status: .completed,
                        executionProfile: OracleExecutionProfile(
                            providerID: "executed-primary-provider",
                            modelID: "executed-primary-model",
                            effectiveReasoningEffort: "high"
                        ),
                        response: "Primary lane answer"
                    ),
                    OracleLaneResult(
                        laneIndex: 1,
                        chatID: "secondary-chat",
                        providerID: "configured-secondary-provider",
                        modelID: "configured-secondary-model",
                        status: .failed,
                        error: OracleLaneError(
                            code: "provider_failed",
                            message: "Secondary provider failed",
                            partialResponse: "Secondary partial answer"
                        )
                    )
                ],
                warnings: [
                    OracleGroupWarning(code: "lane_failure", message: "One lane failed")
                ]
            )
            let request = OracleExportRequest(
                sourceTool: "oracle_send",
                mode: "review",
                message: "Review it",
                chatID: "primary-chat",
                response: "Primary lane answer",
                groupResult: group
            )

            let markdown = AgentOracleExport.oracleMarkdown(request: request)

            XCTAssertTrue(markdown.hasPrefix("# Oracle Review\n\n"))
            XCTAssertTrue(markdown.contains("- Group ID: `\(groupID.uuidString)`"))
            XCTAssertTrue(markdown.contains("- Status: `partial_failure`"))
            XCTAssertTrue(markdown.contains("- Oracle count: 2"))
            XCTAssertTrue(markdown.contains("- `lane_failure`: One lane failed"))
            XCTAssertTrue(markdown.contains("### Oracle (Primary)"))
            XCTAssertTrue(markdown.contains("### Oracle 2"))
            XCTAssertTrue(markdown.contains("- Chat ID: `primary-chat`"))
            XCTAssertTrue(markdown.contains("- Provider: `configured-primary-provider`"))
            XCTAssertTrue(markdown.contains("- Model: `configured-primary-model`"))
            XCTAssertTrue(markdown.contains("- Execution provider: `executed-primary-provider`"))
            XCTAssertTrue(markdown.contains("- Execution model: `executed-primary-model`"))
            XCTAssertTrue(markdown.contains("- Effective reasoning effort: `high`"))
            XCTAssertTrue(markdown.contains("Primary lane answer"))
            XCTAssertTrue(markdown.contains("Secondary partial answer"))
            XCTAssertTrue(markdown.contains("- Code: `provider_failed`"))
            XCTAssertTrue(markdown.contains("- Message: Secondary provider failed"))
            XCTAssertLessThan(
                try XCTUnwrap(markdown.range(of: "### Oracle (Primary)")?.lowerBound),
                try XCTUnwrap(markdown.range(of: "### Oracle 2")?.lowerBound)
            )
            XCTAssertFalse(markdown.localizedCaseInsensitiveContains("combined answer"))
            XCTAssertFalse(markdown.localizedCaseInsensitiveContains("synthesized answer"))
        }

        func testFiveOracleExportRetainsEveryLaneInOrder() throws {
            let lanes = try (0 ..< 5).map { index -> OracleLaneResult in
                if index == 2 {
                    return try OracleLaneResult(
                        laneIndex: index,
                        chatID: "chat-\(index)",
                        providerID: "provider-\(index)",
                        modelID: "model-\(index)",
                        status: .completed,
                        response: "response-\(index)"
                    )
                }
                let status: OracleLaneResultStatus = index.isMultiple(of: 2) ? .failed : .cancelled
                return try OracleLaneResult(
                    laneIndex: index,
                    chatID: "chat-\(index)",
                    providerID: "provider-\(index)",
                    modelID: "model-\(index)",
                    status: status,
                    error: OracleLaneError(
                        code: "error-\(index)",
                        message: "message-\(index)",
                        partialResponse: "partial-\(index)"
                    )
                )
            }
            let group = try OracleGroupResult(
                groupID: OracleGroupID(rawValue: UUID()),
                status: .failed,
                oracleResults: lanes
            )
            let markdown = AgentOracleExport.oracleMarkdown(request: OracleExportRequest(
                sourceTool: "ask_oracle",
                mode: "chat",
                message: "Compare",
                chatID: "chat-0",
                response: nil,
                groupResult: group
            ))

            XCTAssertTrue(markdown.contains("- Status: `failed`"))
            XCTAssertTrue(markdown.contains("- Oracle count: 5"))
            var priorHeadingIndex = markdown.startIndex
            for index in 0 ..< 5 {
                let label = OracleRosterContract.displayLabel(laneIndex: index)
                let heading = index == 0 ? "### \(label) (Primary)" : "### \(label)"
                let headingIndex = try XCTUnwrap(markdown.range(of: heading)?.lowerBound)
                XCTAssertGreaterThanOrEqual(headingIndex, priorHeadingIndex)
                priorHeadingIndex = headingIndex
                XCTAssertTrue(markdown.contains("- Chat ID: `chat-\(index)`"))
                if index == 2 {
                    XCTAssertTrue(markdown.contains("response-\(index)"))
                } else {
                    XCTAssertTrue(markdown.contains("partial-\(index)"))
                    XCTAssertTrue(markdown.contains("- Code: `error-\(index)`"))
                    XCTAssertTrue(markdown.contains("- Message: message-\(index)"))
                }
            }
        }

        func testGroupExportCancellationPreservesSettledLaneHandlesBeforeAndDuringExport() async throws {
            let lanes = try [
                OracleLaneResult(
                    laneIndex: 0, chatID: "completed-chat", providerID: "fixture", modelID: "primary",
                    status: .completed, response: "sum 81"
                ),
                OracleLaneResult(
                    laneIndex: 1, chatID: "cancelled-chat", providerID: "fixture", modelID: "additional",
                    status: .cancelled, error: OracleLaneError(code: "cancelled", message: "Cancelled")
                )
            ]
            let group = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure, oracleResults: lanes)
            let payload = ContextBuilderOracleGroupReply(result: group).toMCPFields()
            for cancelBeforeExport in [true, false] {
                let fixture = makeOracleSendFixture(exportOperation: { _ in
                    XCTAssertFalse(cancelBeforeExport, "A cancelled request must not begin exporting")
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw CancellationError()
                })
                defer { fixture.cleanup() }
                let request = OracleExportRequest(
                    sourceTool: "ask_oracle", mode: "chat",
                    message: "Read only fixture.txt. Write a 400-word essay about the fixture values, then give the sum.",
                    chatID: "completed-chat", response: nil, groupResult: group
                )
                let task = Task {
                    if cancelBeforeExport { withUnsafeCurrentTask { $0?.cancel() } }
                    return try await fixture.service.exportSettledOracleResponse(payload, request: request)
                }
                let reply = try await task.value
                XCTAssertEqual(reply["oracle_group_id"], payload["oracle_group_id"])
                XCTAssertEqual(reply["status"], .string("partial_failure"))
                XCTAssertEqual(reply["oracle_results"], payload["oracle_results"])
                XCTAssertNotNil(reply["oracle_export_error"])
                XCTAssertNil(reply["oracle_export_path"])
            }
        }

        func testOrdinaryExportFailurePreservesSettledGroupedAndSingleRepliesOnBlockingPaths() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("oracle-export-fixture-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let group = try OracleGroupResult(
                groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure,
                oracleResults: [
                    OracleLaneResult(
                        laneIndex: 0, chatID: "primary-chat", providerID: "fixture", modelID: "primary",
                        status: .completed, response: "Primary answer"
                    ),
                    OracleLaneResult(
                        laneIndex: 1, chatID: "additional-chat", providerID: "fixture", modelID: "additional",
                        status: .failed, error: OracleLaneError(code: "provider_error", message: "Additional failed", partialResponse: "Partial answer")
                    )
                ]
            )
            var grouped = OracleGroupMCPCodec.groupFields(group)
            grouped["chat_id"] = .string(group.primary.chatID)
            grouped["response"] = .string("Primary answer")
            let capturedGuidance = "  Retain each material disagreement.\nDo not vote.  "
            grouped["oracle_reconciliation_guidance"] = .string(capturedGuidance)
            let single: [String: Value] = ["chat_id": .string("single-chat"), "response": .string("Single answer")]
            for (sourceTool, payload) in [grouped, single].flatMap({ payload in
                ["oracle_send", "ask_oracle"].map { ($0, payload) }
            }) {
                let fixture = makeOracleSendFixture(stopAfterRoute: false, connectionID: UUID(), exportOperation: { request in
                    XCTAssertEqual(request.chatID, payload["chat_id"]?.stringValue)
                    XCTAssertEqual(request.reconciliationGuidance, payload["oracle_reconciliation_guidance"]?.stringValue)
                    let markdown = AgentOracleExport.oracleMarkdown(request: request)
                    if request.groupResult != nil {
                        XCTAssertTrue(markdown.contains(capturedGuidance))
                        XCTAssertFalse(markdown.contains(OracleGroupDeliveryContract.defaultReconciliationGuidance))
                    } else {
                        XCTAssertEqual(markdown, "# Oracle Response\n\nSingle answer")
                    }
                    throw NSError(domain: "OracleExportFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Private export diagnostic"])
                }, settledReply: payload)
                defer { fixture.cleanup() }
                await fixture.window.workspaceManager.awaitInitialized()
                let workspace = try WorkspaceModel(
                    id: XCTUnwrap(fixture.context.workspaceID), name: "Oracle export fixture",
                    repoPaths: [root.path], ephemeralFlag: true
                )
                fixture.window.workspaceManager.workspaces = [workspace]
                fixture.window.workspaceManager.activeWorkspace = workspace
                let args: [String: Value] = ["message": .string("fixture"), "new_chat": .bool(true), "export_response": .bool(true)]
                let reply: Value
                do {
                    reply = if sourceTool == "ask_oracle" {
                        try await fixture.service.executeAskOracle(args: args, invocationContext: fixture.invocationContext)
                    } else {
                        try await fixture.service.executeOracleSend(args: args, invocationContext: fixture.invocationContext)
                    }
                } catch {
                    XCTFail("Optional export failure discarded settled reply: \(error)")
                    XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
                    continue
                }
                var fields = try XCTUnwrap(reply.objectValue)
                guard let notice = fields.removeValue(forKey: "oracle_export_error")?.stringValue else {
                    XCTFail("Export failure erased the settled payload: \(reply)")
                    XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
                    continue
                }
                XCTAssertTrue(notice.contains("returned chat IDs"))
                XCTAssertFalse(notice.contains("Private export diagnostic"))
                XCTAssertNil(fields["oracle_export_path"])
                XCTAssertNil(fields["oracle_export_instruction"])
                XCTAssertEqual(fields, payload)
                XCTAssertEqual(fixture.sendRecorder.calls.count, 1, "Recovery must not rerun paid work")
            }
        }

        func testNonGroupExportCancellationStillThrows() async {
            let fixture = makeOracleSendFixture(exportOperation: { _ in throw CancellationError() })
            defer { fixture.cleanup() }
            do {
                _ = try await fixture.service.exportSettledOracleResponse(
                    ["chat_id": .string("single-chat")],
                    request: OracleExportRequest(sourceTool: "ask_oracle", mode: "chat", message: "fixture", chatID: "single-chat", response: nil)
                )
                XCTFail("Expected ordinary non-group cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        private func assertStopsAfterRoute(
            _ fixture: OracleSendBoundaryFixture,
            args: [String: Value]
        ) async {
            do {
                _ = try await fixture.service.executeOracleSend(args: args, invocationContext: fixture.invocationContext)
                XCTFail("Expected test stop after route validation")
            } catch OracleBoundaryTestStop.afterRoute {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        private func makeOracleSendFixture(
            stopAfterRoute: Bool = true,
            connectionID: UUID? = nil,
            livePurpose: MCPRunPurpose = .unknown,
            exportOperation: MCPOracleToolService.ExportOracleResponse? = nil,
            settledReply: [String: Value]? = nil
        ) -> OracleSendBoundaryFixture {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

            let snapshot = MCPTabContextSnapshot(
                tabID: UUID(),
                windowID: window.windowID,
                workspaceID: UUID(),
                promptText: "",
                selection: StoredSelection(),
                selectedMetaPromptIDs: [],
                tabName: "Oracle boundary",
                runID: nil,
                frozenLookupContext: .visibleWorkspace,
                explicitlyBound: true
            )
            let metadata = MCPRequestMetadata(
                connectionID: connectionID,
                clientName: "oracle-boundary-test",
                windowID: window.windowID
            )
            let recorder = OracleRebindRecorder()
            let sendRecorder = OracleSendArgsRecorder()
            let service = MCPOracleToolService(
                askOracleToolName: "ask_oracle",
                oracleSendToolName: "oracle_send",
                oracleChatLogToolName: "oracle_chat_log",
                promptVM: window.promptManager,
                oracleVM: window.oracleViewModel,
                liveRunPurpose: { requestedConnectionID in
                    requestedConnectionID == connectionID ? livePurpose : .unknown
                },
                resolveTabContextSnapshot: { _ in .init(snapshot: snapshot) },
                requireCurrentTabContext: { _ in
                    if stopAfterRoute { throw OracleBoundaryTestStop.afterRoute }
                    return snapshot
                },
                stabilizedVirtualContext: { $0 },
                resolveDelegatedReviewPackaging: { _, _, _, _ in nil },
                rebindChatSessionIfNeeded: { _, chatID in recorder.record(chatID) },
                resolveTabIDForAgentMode: { _, _ in snapshot.tabID },
                requireTargetWindow: { window },
                rawExplicitTabID: { _ in nil },
                sendStageProgress: { _, _, _, _ in },
                withHeartbeat: { _, _, _, _, operation in try await operation() },
                sendChat: { args, _, _ in
                    sendRecorder.record(args)
                    return settledReply ?? [
                        "chat_id": .string("selected-chat"),
                        "response": .string("response")
                    ]
                },
                exportOracleResponse: exportOperation ?? { _ in throw OracleBoundaryTestStop.unexpectedExport }
            )
            return OracleSendBoundaryFixture(
                window: window,
                context: snapshot,
                service: service,
                invocationContext: .trustedLocal(toolName: "oracle_send", metadata: metadata),
                rebindRecorder: recorder,
                sendRecorder: sendRecorder
            )
        }
    }

    final class OracleContextBuilderCommandRunnerTests: XCTestCase {
        func testInstructionsOnlyAndPackOnlyReachSession() async throws {
            let fixture = try await makeCommandRunnerFixture()
            addTeardownBlock { await fixture.cleanup() }

            let instructionsResult = await fixture.runner.runLine(
                #"call context_builder {"instructions":"Inspect the workspace"}"#
            )
            let packResult = await fixture.runner.runLine(
                #"call context_builder {"context_pack_ref":"oracle-pack:sha256:fixture"}"#
            )

            XCTAssertTrue(instructionsResult.succeeded)
            XCTAssertTrue(packResult.succeeded)
            let calls = await fixture.recorder.recordedCalls()
            guard calls.count == 2 else {
                XCTFail("Expected two forwarded calls, got \(calls.count)")
                return
            }
            XCTAssertEqual(calls[0].arguments?["instructions"], .string("Inspect the workspace"))
            XCTAssertEqual(calls[1].arguments?["context_pack_ref"], .string("oracle-pack:sha256:fixture"))
        }

        func testOraclePresetIsForwardedToAppBackedBoundary() async throws {
            let fixture = try await makeCommandRunnerFixture()
            addTeardownBlock { await fixture.cleanup() }

            let result = await fixture.runner.runLine(
                #"call context_builder {"instructions":"Inspect","response_type":"plan","oracle_preset":"Deep"}"#
            )

            XCTAssertTrue(result.succeeded)
            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.first?.arguments?["oracle_preset"], .string("Deep"))
        }

        func testAliasNormalizesToInstructionsBeforeExclusiveInputValidation() async throws {
            let fixture = try await makeCommandRunnerFixture()
            addTeardownBlock { await fixture.cleanup() }

            let result = await fixture.runner.runLine(
                #"call context_builder {"task":"Inspect aliases"}"#
            )

            XCTAssertTrue(result.succeeded)
            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.first?.arguments?["instructions"], .string("Inspect aliases"))
            XCTAssertNil(calls.first?.arguments?["task"])
        }

        func testEmptyInputIsAbsentWhenOtherInputIsNonempty() async throws {
            let fixture = try await makeCommandRunnerFixture()
            addTeardownBlock { await fixture.cleanup() }

            let packResult = await fixture.runner.runLine(
                #"call context_builder {"instructions":"  ","context_pack_ref":"oracle-pack:sha256:fixture"}"#
            )
            let instructionsResult = await fixture.runner.runLine(
                #"call context_builder {"instructions":"Inspect","context_pack_ref":"\n"}"#
            )

            XCTAssertTrue(packResult.succeeded)
            XCTAssertTrue(instructionsResult.succeeded)
            let calls = await fixture.recorder.recordedCalls()
            XCTAssertEqual(calls.count, 2)
        }

        func testBothNeitherAndEmptyInputsFailBeforeSession() async throws {
            let fixture = try await makeCommandRunnerFixture()
            addTeardownBlock { await fixture.cleanup() }
            let invalidLines = [
                "call context_builder",
                #"call context_builder {}"#,
                #"call context_builder {"instructions":"inspect","context_pack_ref":"oracle-pack:sha256:fixture"}"#,
                #"call context_builder {"instructions":"  ","context_pack_ref":"\n"}"#
            ]

            for line in invalidLines {
                let result = await fixture.runner.runLine(line)
                XCTAssertFalse(result.succeeded, line)
            }
            let calls = await fixture.recorder.recordedCalls()
            XCTAssertTrue(calls.isEmpty)
        }

        private func makeCommandRunnerFixture() async throws -> OracleCommandRunnerFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let recorder = OracleCommandRunnerRecorder()
            let server = Server(
                name: "Oracle command runner boundary server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(CallTool.self) { params in
                await recorder.record(params)
                return .init(content: [.text(text: "ok", annotations: nil, _meta: nil)], isError: false)
            }
            try await server.start(transport: transports.server)

            let requestSendBarrier = MCPRequestSendBarrier()
            let clientTransport = OrderedMCPTransport(
                underlying: transports.client,
                requestSendBarrier: requestSendBarrier,
                logger: transports.client.logger
            )
            let client = Client(name: "Oracle command runner boundary client", version: "1.0")
            _ = try await client.connect(transport: clientTransport)
            let session = InteractiveMCPClientSession(
                connectedClientForTesting: client,
                requestSendBarrier: requestSendBarrier
            )
            let runner = MCPCommandRunner(
                session: session,
                initialDirectory: FileManager.default.currentDirectoryPath,
                settings: RunnerSettings(),
                outputHandler: { _, _ in }
            )
            return OracleCommandRunnerFixture(
                client: client,
                server: server,
                runner: runner,
                recorder: recorder
            )
        }
    }

    @MainActor
    private enum OracleBoundaryTestStop: Error {
        case afterRoute
        case unexpectedSend
        case unexpectedExport
    }

    @MainActor
    private final class OracleRebindRecorder {
        private(set) var chatIDs: [String] = []

        var count: Int {
            chatIDs.count
        }

        func record(_ chatID: String) {
            chatIDs.append(chatID)
        }
    }

    @MainActor
    private final class OracleSendArgsRecorder {
        private(set) var calls: [[String: Value]] = []

        func record(_ args: [String: Value]) {
            calls.append(args)
        }
    }

    @MainActor
    private struct OracleSendBoundaryFixture {
        let window: WindowState
        let context: MCPTabContextSnapshot
        let service: MCPOracleToolService
        let invocationContext: ToolInvocationContext
        let rebindRecorder: OracleRebindRecorder
        let sendRecorder: OracleSendArgsRecorder

        func cleanup() {
            WindowStatesManager.shared.unregisterWindowState(window)
        }
    }

    private struct OracleRecordedCommandCall {
        let arguments: [String: Value]?
    }

    private actor OracleCommandRunnerRecorder {
        private var calls: [OracleRecordedCommandCall] = []

        func record(_ params: CallTool.Parameters) {
            calls.append(.init(arguments: params.arguments))
        }

        func recordedCalls() -> [OracleRecordedCommandCall] {
            calls
        }
    }

    private struct OracleCommandRunnerFixture {
        let client: Client
        let server: Server
        let runner: MCPCommandRunner
        let recorder: OracleCommandRunnerRecorder

        func cleanup() async {
            await client.disconnect()
            await server.stop()
        }
    }
#endif

@MainActor
final class OracleImageContractTests: XCTestCase {
    func testParserAcceptsOnlyBoundedPathAndOptionalTitleObjects() throws {
        XCTAssertEqual(try MCPOracleToolService.parseOracleImageRequests(nil), [])
        XCTAssertEqual(try MCPOracleToolService.parseOracleImageRequests(.array([])), [])

        let parsed = try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("  /workspace/diagram.png  "),
                "title": .string("  Architecture  ")
            ]),
            .object(["path": .string("/workspace/photo.jpg")])
        ]))

        XCTAssertEqual(parsed, [
            .init(index: 0, path: "  /workspace/diagram.png  ", title: "Architecture"),
            .init(index: 1, path: "/workspace/photo.jpg", title: nil)
        ])
    }

    func testParserRejectsOversizedAndExpandedAttachmentShapes() {
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array([
            .object(["path": .string("/workspace/image.png"), "_meta": .string("ignored")])
        ])))
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array(
            (0 ... 10).map { .object(["path": .string("/workspace/\($0).png")]) }
        )))
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("/workspace/image.png"),
                "url": .string("https://example.com/image.png")
            ])
        ])))
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("/workspace/image.png"),
                "title": .string(String(repeating: "x", count: 201))
            ])
        ])))
    }

    func testAskOracleImageDocumentationIsProviderNeutralAndMatchesLimits() throws {
        XCTAssertEqual(OracleImageAttachmentLimits.production.maxCount, 10)
        XCTAssertEqual(OracleImageAttachmentLimits.production.maxBytesPerImage, 20 * 1024 * 1024)
        XCTAssertEqual(OracleImageAttachmentLimits.production.maxTotalBytes, 50 * 1024 * 1024)
        let canonical = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "ask_oracle"))
        let schema = try XCTUnwrap(canonical.inputSchema.objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        let canonicalArgument = try XCTUnwrap(properties["images"]?.objectValue?["description"]?.stringValue)
        let headlessDisclaimer = " Requires the app backend; the direct headless backend rejects `images`."
        XCTAssertEqual(canonicalArgument, MCPOracleToolProvider.askOracleImagesArgumentDescription + headlessDisclaimer)
        XCTAssertTrue(canonical.description.contains(MCPOracleToolProvider.askOracleImageUsageDescription + headlessDisclaimer))

        let documentation = [
            MCPOracleToolProvider.askOracleImageUsageDescription,
            MCPOracleToolProvider.askOracleImagesArgumentDescription
        ].joined(separator: " ")

        XCTAssertFalse(documentation.lowercased().contains("anthropic"))
        XCTAssertTrue(documentation.contains("10 images"))
        XCTAssertTrue(documentation.contains("20 MiB each"))
        XCTAssertTrue(documentation.contains("50 MiB total"))
        for description in [
            MCPOracleToolProvider.askOracleImageUsageDescription,
            MCPOracleToolProvider.askOracleImagesArgumentDescription
        ] {
            XCTAssertTrue(description.contains("raw attachment-file bytes before provider encoding"))
            XCTAssertTrue(description.contains("provider or model may impose additional restrictions"))
            XCTAssertTrue(description.contains("do not guarantee full-request or model-context fit"))
        }
        let usage = MCPOracleToolProvider.askOracleImageUsageDescription
        XCTAssertTrue(usage.contains("additional to pre-send text estimates and Context Builder text-selection budgets"))
        XCTAssertTrue(usage.contains("Originals, not transcript thumbnails, are sent to each Oracle lane"))
        XCTAssertTrue(usage.contains("group fan-out multiplies image usage/cost, not any one request's attachment cap"))
        XCTAssertTrue(usage.contains("Provider-reported input totals may already include image usage"))
        XCTAssertTrue(usage.contains("this-turn-only"))
        XCTAssertTrue(usage.contains("continuations do not automatically reattach prior images or send saved thumbnails"))
        XCTAssertTrue(documentation.contains("PNG"))
        XCTAssertTrue(documentation.lowercased().contains("rejected"))

        // Images the user attached to the agent session are accepted at their exact path, so every
        // surface (app tool, canonical/headless definition, path field) must say so.
        for description in [
            MCPOracleToolProvider.askOracleImageUsageDescription,
            MCPOracleToolProvider.askOracleImagesArgumentDescription
        ] {
            XCTAssertTrue(description.contains("image the user attached to this agent session"))
            XCTAssertTrue(description.contains("sibling attachments"))
            XCTAssertTrue(description.contains("arbitrary"))
        }
        let items = try XCTUnwrap(properties["images"]?.objectValue?["items"]?.objectValue)
        let pathDescription = try XCTUnwrap(
            items["properties"]?.objectValue?["path"]?.objectValue?["description"]?.stringValue
        )
        XCTAssertTrue(pathDescription.contains("image attached to this agent session"))
    }

    func testRawImagesAtOracleDispatchAreAnInternalInvariantFailure() {
        XCTAssertNoThrow(try OracleViewModel.validateRawImageDispatchInvariant([
            "message": .string("inspect")
        ]))
        XCTAssertThrowsError(try OracleViewModel.validateRawImageDispatchInvariant([
            "images": .array([.object(["path": .string("/workspace/image.png")])])
        ])) { error in
            guard let toolError = error as? ChatToolError else {
                return XCTFail("Expected ChatToolError, got \(error)")
            }
            XCTAssertEqual(toolError.code, .internalError)
            XCTAssertTrue(toolError.message.contains("must be consumed before Oracle dispatch"))
        }
    }

    func testAskOracleToolArgumentsAreRedactedBeforePersistence() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/secret.png","title":"Secret"}]}"#
        let item = AgentChatItem.toolCall(
            name: "mcp__RepoPromptCE__ask_oracle",
            argsJSON: raw
        )

        let sanitized = try XCTUnwrap(item.toolArgsJSON)
        XCTAssertTrue(sanitized.contains("inspect"))
        XCTAssertFalse(sanitized.contains("images"))
        XCTAssertFalse(sanitized.contains("/Users/secret.png"))
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(item), as: UTF8.self).contains("secret.png"))

        let unrelated = AgentChatItem.toolCall(name: "read_file", argsJSON: raw)
        XCTAssertEqual(unrelated.toolArgsJSON, raw)
    }

    func testMalformedOracleArgumentsFailClosed() {
        // Every malformed or truncated ask_oracle payload fails closed — a partial prefix
        // might yet grow an "images" key, and an impossible prefix may already carry one.
        let malformed = [
            #"{"message":"partial""#,
            #"{"message":"say \"images\": hi""#,
            #"{"message":"\ud83d"#,
            #"{"message":"x","m"#,
            #"{"message":"x",""#,
            #"{"message":"x","ima"#,
            #"{"images":[{"path":"/Users/secret.png""#,
            #"{"\u0069mages":[{"path":"/Users/secret.png""#,
            #"{"i\u006Dages":[{"path":"/Users/secret.png""#,
            #"{"message":"x" "images":[{"path":"/Users/secret.png""#,
            #"{"message":"x" "ima"#,
            #"{"message":1 "images""#,
            #"{"message":"x"}{"images":[]"#,
            #"{"message":"x","other""#,
            // Syntactically impossible nested content still carrying image material.
            #"{"message":["x","images":[{"path":"/Users/secret.png","title":"Secret"#,
            // Complete non-object values cannot carry a top-level images key, but fail
            // closed anyway — tool arguments are always objects.
            #"[{"images":[]}]"#,
            #""images""#
        ]

        for raw in malformed {
            XCTAssertNil(
                AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(
                    toolName: "ask_oracle",
                    argsJSON: raw
                ),
                raw
            )
            XCTAssertEqual(
                AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(
                    toolName: "read_file",
                    argsJSON: raw
                ),
                raw,
                raw
            )
        }
    }

    func testNamespacedAndAliasedOracleToolNamesAreRedacted() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/secret.png"}]}"#
        let oracleNames = [
            "ask_oracle",
            "mcp__RepoPromptCE__ask_oracle",
            "RepoPromptCE__ask_oracle",
            "RepoPromptCE_ask_oracle",
            "functions.ask_oracle",
            "other_server:ask_oracle",
            "mcp__other__ask_oracle"
        ]
        for name in oracleNames {
            let sanitized = try XCTUnwrap(
                AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(toolName: name, argsJSON: raw),
                name
            )
            XCTAssertFalse(sanitized.contains("secret.png"), name)
            XCTAssertTrue(sanitized.contains("inspect"), name)
        }

        // Non-oracle tools keep their arguments untouched.
        let unrelated = #"{"images":[{"path":"/tmp/not-an-oracle-image.png"}]}"#
        for name in ["ask_oracle_extended", "oracle_send", "read_file"] {
            XCTAssertEqual(
                AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(
                    toolName: name,
                    argsJSON: unrelated
                ),
                unrelated,
                name
            )
        }
    }

    func testEscapedImagesKeysAndPersistedItemsAreSanitized() throws {
        let raw = #"{"\u0069mages":[{"path":"/Users/secret.png"}],"message":"inspect"}"#
        let sanitized = try XCTUnwrap(AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(
            toolName: "ask_oracle",
            argsJSON: raw
        ))
        XCTAssertTrue(sanitized.contains("inspect"))
        XCTAssertFalse(sanitized.contains("secret.png"))

        let source = AgentChatItem.toolCall(name: "read_file", argsJSON: raw)
        var persisted = AgentChatItemPersist(from: source, sanitizeToolResults: false)
        persisted.toolName = "mcp__RepoPromptCE__ask_oracle"
        let encoded = try JSONEncoder().encode(persisted)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret.png"))
        let decoded = try JSONDecoder().decode(AgentChatItemPersist.self, from: encoded)
        XCTAssertFalse(decoded.toolArgsJSON?.contains("secret.png") == true)
    }

    func testLegacyImageArgumentsAreSanitizedOnDecode() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/legacy-secret.png"}]}"#
        let source = AgentChatItem.toolCall(name: "read_file", argsJSON: raw)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any]
        )
        object["toolName"] = "ask_oracle"
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentChatItem.self, from: legacyData)
        XCTAssertFalse(decoded.toolArgsJSON?.contains("legacy-secret") == true)
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(decoded), as: UTF8.self).contains("legacy-secret"))
    }

    func testUnrelatedAndImageFreeArgumentsRoundTripUnchanged() throws {
        let unrelatedRaw = #"{"images":[{"path":"/tmp/not-an-oracle-image.png"}]}"#
        let unrelated = AgentChatItem.toolCall(name: "read_file", argsJSON: unrelatedRaw)
        let unrelatedRoundTrip = try JSONDecoder().decode(
            AgentChatItem.self,
            from: JSONEncoder().encode(unrelated)
        )
        XCTAssertEqual(unrelatedRoundTrip.toolArgsJSON, unrelatedRaw)

        let oracleRaw = #"{"message":"hi","mode":"plan"}"#
        let oracle = AgentChatItem.toolCall(name: "ask_oracle", argsJSON: oracleRaw)
        let oracleRoundTrip = try JSONDecoder().decode(
            AgentChatItem.self,
            from: JSONEncoder().encode(oracle)
        )
        XCTAssertEqual(oracleRoundTrip.toolArgsJSON, oracleRaw)
    }

    func testLateToolArgumentsRedactImagesAndFailClosed() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/late-secret.png"}]}"#
        var item = AgentChatItem.toolCall(name: "read_file", argsJSON: nil)
        item.toolName = "ask_oracle"
        item.toolArgsJSON = raw

        let sanitized = try XCTUnwrap(item.toolArgsJSON)
        XCTAssertFalse(sanitized.contains("images"))
        XCTAssertFalse(sanitized.contains("late-secret"))

        item.toolArgsJSON = #"{"message":"partial"#
        XCTAssertNil(item.toolArgsJSON)
        item.toolArgsJSON = #"{"images":[{"path":"/Users/partial-secret.png"#
        XCTAssertNil(item.toolArgsJSON)
    }
}

final class OracleGroupDeliveryContractTests: XCTestCase {
    func testContractIsSilentForSingleLaneAndDescribesEveryLaneOtherwise() throws {
        let single = [OracleGroupDeliveryContract.Lane(laneIndex: 0, modelID: "m", chatID: "chat-0", status: "Completed", response: "x")]
        XCTAssertNil(OracleGroupDeliveryContract.preamble(lanes: single))
        XCTAssertNil(OracleGroupDeliveryContract.endMarker(laneCount: 1))
        XCTAssertNil(OracleGroupDeliveryContract.followUpReminder(laneCount: 1))
        XCTAssertNil(OracleGroupDeliveryContract.exportReadingRequirement(laneCount: 1))

        let preamble = OracleGroupDeliveryContract.preamble(lanes: [
            .init(laneIndex: 2, modelID: nil, chatID: "chat-2", status: "Failed", response: nil),
            .init(laneIndex: 1, modelID: "model-b", chatID: "chat-1", status: "Failed", response: " \n", partialResponse: "part\r\nial\n"),
            .init(laneIndex: 0, modelID: "model-a", chatID: "chat-0", status: "Completed", response: "one\ntwo\nthree\n")
        ])
        let text = try XCTUnwrap(preamble)
        XCTAssertTrue(text.contains(
            "3 independent answers to the same request follow. Lane order is not a ranking; "
                + "the first lane supplies the top-level continuation handle, and a successful follow-up through any lane's chat ID re-runs every lane."
        ), text)
        XCTAssertFalse(text.contains("only the chat that follow-ups continue"), text)
        XCTAssertTrue(text.contains("Read every lane through the end-of-group marker (`End of Oracle group: 3 lanes above.`)"), text)
        XCTAssertTrue(text.contains("read-only `oracle_chat_log` with that lane's chat ID"), text)
        XCTAssertTrue(text.contains("Do not start a follow-up just to retrieve prior text."), text)
        XCTAssertTrue(text.contains(
            "Begin your answer with `**Oracle reconciliation**`, "
                + "state how many lanes completed and name any that did not."
        ), text)
        XCTAssertTrue(text.contains("exactly one disposition: `accepted`, `rejected`, or `unresolved`."), text)
        XCTAssertTrue(text.hasSuffix("""
        Lanes (3):
        - Oracle — `model-a` — Completed — chat ID `chat-0`
        - Oracle 2 — `model-b` — Failed (partial) — chat ID `chat-1`
        - Oracle 3 — model unspecified — Failed — chat ID `chat-2`
        """), text)
    }

    func testPreambleKeepsCompleteInventoryGuidanceCompactAcrossSupportedLaneCounts() throws {
        for count in 2 ... OracleRosterContract.maximumCount {
            let lanes = (0 ..< count).map { index in
                OracleGroupDeliveryContract.Lane(
                    laneIndex: index, modelID: "model-\(index)", chatID: "chat-\(index)", status: "Completed", response: "answer"
                )
            }
            let text = try XCTUnwrap(OracleGroupDeliveryContract.preamble(lanes: lanes))
            XCTAssertTrue(text.contains(
                "Before synthesizing, inventory every material claim from every lane, including single-lane claims."
            ), text)
            XCTAssertTrue(text.contains("exactly one disposition"), text)
            XCTAssertTrue(text.contains("Never silently omit an item."), text)
            XCTAssertTrue(text.contains("\(count) independent answers to the same request follow."), text)
            XCTAssertTrue(try text.contains("`\(XCTUnwrap(OracleGroupDeliveryContract.endMarker(laneCount: count)))`"), text)

            let lines = text.components(separatedBy: "\n")
            let manifestRows = lines.filter { $0.hasPrefix("- Oracle") }
            XCTAssertEqual(manifestRows, (0 ..< count).map { index in
                let label = index == 0 ? "Oracle" : "Oracle \(index + 1)"
                return "- \(label) — `model-\(index)` — Completed — chat ID `chat-\(index)`"
            }, text)
            let guidance = lines.filter { !$0.hasPrefix("- Oracle") }.joined(separator: "\n")
            XCTAssertLessThanOrEqual(guidance.utf8.count, 1400, "\(count) lanes: \(guidance.utf8.count) guidance bytes")
        }
    }

    func testLaneIsPartialOnlyWhenResponseIsBlankAndPartialIsNot() {
        let cases: [(response: String?, partial: String?, expected: Bool)] = [
            ("answer", nil, false),
            ("answer", "partial", false),
            (nil, "partial", true),
            (" \n\t", "partial", true),
            (nil, nil, false),
            (" \n", " \r\n", false)
        ]
        for (response, partial, expected) in cases {
            let lane = OracleGroupDeliveryContract.Lane(
                laneIndex: 0, modelID: nil, chatID: "chat-0", status: "Failed", response: response, partialResponse: partial
            )
            XCTAssertEqual(lane.isPartial, expected, "response: \(String(describing: response)), partial: \(String(describing: partial))")
        }
    }

    func testInlineGroupPutsGuidanceBeforeLanesAndEndMarkerLast() throws {
        let fields = try groupFields(lanes: [
            lane(index: 0, response: "primary answer"),
            lane(index: 1, response: "adviser answer\nsecond line")
        ], warnings: [OracleGroupWarning(code: "slow_lane", message: "Lane was slow")])
        let text = joinedText(ToolOutputFormatter.formatAskOracle(args: [:], value: .object(fields), emitResources: false))

        let guidance = try XCTUnwrap(text.range(of: "**Reconciling these Oracle lanes**"))
        let firstLane = try XCTUnwrap(text.range(of: "\n### Oracle\n"))
        let warning = try XCTUnwrap(text.range(of: "Warning [slow_lane]"))
        XCTAssertLessThan(guidance.lowerBound, firstLane.lowerBound)
        XCTAssertLessThan(firstLane.lowerBound, warning.lowerBound)
        XCTAssertTrue(text.contains("- Oracle 2 — `model-1` — Completed — chat ID `chat-1`\n"), text)
        XCTAssertTrue(text.hasSuffix("\n\nEnd of Oracle group: 2 lanes above.\n"), text)
        XCTAssertEqual(
            text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init),
            "End of Oracle group: 2 lanes above."
        )
        XCTAssertFalse(text.localizedCaseInsensitiveContains("synthesis"))
    }

    func testGroupedAskOracleEndMarkerStaysOnItsOwnLineWhenBlocksAreConcatenated() throws {
        var fields = try groupFields(lanes: [
            lane(index: 0, response: "primary answer"),
            lane(index: 1, response: "adviser answer")
        ])
        fields["oracle_export_path"] = .string("/tmp/prompt-exports/oracle.md")
        let blocks = texts(ToolOutputFormatter.formatAskOracle(args: [:], value: .object(fields), emitResources: false))
        XCTAssertGreaterThanOrEqual(blocks.count, 2)

        let concatenated = blocks.joined()
        XCTAssertTrue(
            concatenated.contains("\nEnd of Oracle group: 2 lanes above.\n### Oracle export"),
            concatenated
        )
        XCTAssertFalse(concatenated.contains("lanes above.###"), concatenated)
    }

    func testGroupedExportFileFramesLanesWithManifestAndEndMarker() throws {
        let group = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()),
            status: .partialFailure,
            oracleResults: [
                lane(index: 0, response: "primary answer"),
                OracleLaneResult(
                    laneIndex: 1,
                    chatID: "chat-1",
                    providerID: "provider-1",
                    modelID: "model-1",
                    status: .failed,
                    error: OracleLaneError(code: "provider_failed", message: "failed", partialResponse: "partial")
                )
            ]
        )
        let markdown = AgentOracleExport.oracleMarkdown(request: OracleExportRequest(
            sourceTool: "ask_oracle",
            mode: "review",
            message: "Review it",
            chatID: "chat-0",
            response: "primary answer",
            groupResult: group
        ))

        XCTAssertLessThan(
            try XCTUnwrap(markdown.range(of: "**Reconciling these Oracle lanes**")).lowerBound,
            try XCTUnwrap(markdown.range(of: "## Oracle results")).lowerBound
        )
        XCTAssertTrue(markdown.contains("- Oracle 2 — `model-1` — failed (partial) — chat ID `chat-1`"), markdown)
        XCTAssertTrue(markdown.hasSuffix("\n\nEnd of Oracle group: 2 lanes above."), markdown)
    }

    func testExportInstructionAddsReadingRequirementOnlyForGroups() {
        let path = "/tmp/prompt-exports/oracle \"review\".md"
        let single = AgentOracleExport.instruction(path: path)
        XCTAssertEqual(AgentOracleExport.instruction(path: path, oracleLaneCount: 1), single)
        XCTAssertFalse(single.contains("End of Oracle group"))

        let grouped = AgentOracleExport.instruction(path: path, oracleLaneCount: 3)
        XCTAssertTrue(grouped.hasPrefix(single + " "), grouped)
        XCTAssertTrue(grouped.contains("The file contains 3 independent Oracle lanes"), grouped)
        XCTAssertTrue(grouped.contains("read through the \"End of Oracle group\" marker"), grouped)
    }

    func testCapturedGuidanceSurvivesReplyRoundTripAndNestedPlanReviewDelivery() throws {
        let group = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()), status: .completed,
            oracleResults: [lane(index: 0, response: "primary"), lane(index: 1, response: "additional")]
        )
        let guidance = "  Compare evidence.\nPreserve disagreements verbatim.  "
        let reply = ChatSendReply(
            chatId: UUID(), shortId: "chat-0", mode: "plan", response: "primary", errors: nil,
            oracleGroup: ContextBuilderOracleGroupReply(result: group, reconciliationGuidance: guidance)
        )
        let roundTrip = try JSONDecoder().decode(ChatSendReply.self, from: JSONEncoder().encode(reply))
        let value = roundTrip.toMCPValue()
        XCTAssertEqual(value.objectValue?["oracle_reconciliation_guidance"]?.stringValue, guidance)
        for blocks in [
            ToolOutputFormatter.formatAskOracle(args: [:], value: value, emitResources: false),
            ToolOutputFormatter.formatChatSend(args: [:], value: value, emitResources: false),
            ToolOutputFormatter.formatDiscoverContext(value: .object(["plan": value])),
            ToolOutputFormatter.formatDiscoverContext(value: .object(["review": value]))
        ] {
            let text = joinedText(blocks)
            XCTAssertTrue(text.contains(guidance), text)
            XCTAssertFalse(text.contains(OracleGroupDeliveryContract.defaultReconciliationGuidance), text)
            XCTAssertTrue(text.contains("Lanes (2):"), text)
            XCTAssertTrue(text.contains("End of Oracle group: 2 lanes above."), text)
        }

        let legacyFields = OracleGroupMCPCodec.groupFields(group)
        let defaultText = joinedText(ToolOutputFormatter.formatChatSend(args: [:], value: .object(legacyFields), emitResources: false))
        for override in [nil, " \n\t", OracleGroupDeliveryContract.defaultReconciliationGuidance] as [String?] {
            let fields = ContextBuilderOracleGroupReply(result: group, reconciliationGuidance: override).toMCPFields()
            XCTAssertEqual(fields, legacyFields)
        }
        for raw in [Value.null, .string(" \n")] {
            var fields = legacyFields
            fields["oracle_reconciliation_guidance"] = raw
            XCTAssertEqual(joinedText(ToolOutputFormatter.formatChatSend(args: [:], value: .object(fields), emitResources: false)), defaultText)
        }
        let single = ChatSendReply(chatId: UUID(), shortId: "single", mode: "chat", response: "single answer", errors: nil)
        XCTAssertEqual(single.toMCPValue(), .object([
            "chat_id": .string("single"), "mode": .string("chat"), "response": .string("single answer")
        ]))
    }

    func testGroupedFollowUpHintIsNeutralAndSingleLaneHintIsUnchanged() {
        let continuation = "Continue this plan conversation with ask_oracle(chat_id: \"chat-0\", new_chat: false)"
        for count in [nil, 1] as [Int?] {
            XCTAssertEqual(
                MCPContextBuilderToolProvider.generatedResponseFollowUpHint(modeLabel: "plan", chatID: "chat-0", oracleCount: count),
                continuation
            )
        }

        let grouped = MCPContextBuilderToolProvider.generatedResponseFollowUpHint(modeLabel: "plan", chatID: "chat-0", oracleCount: 3)
        XCTAssertTrue(grouped.hasPrefix("The 3 Oracle lanes above are independent answers"), grouped)
        XCTAssertTrue(grouped.hasSuffix("\n\nOptional later follow-up: " + continuation), grouped)
    }

    // MARK: - Helpers

    private func lane(index: Int, response: String) throws -> OracleLaneResult {
        try OracleLaneResult(
            laneIndex: index,
            chatID: "chat-\(index)",
            providerID: "provider-\(index)",
            modelID: "model-\(index)",
            status: .completed,
            response: response
        )
    }

    private func groupFields(lanes: [OracleLaneResult], warnings: [OracleGroupWarning] = []) throws -> [String: Value] {
        let result = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()),
            status: warnings.isEmpty ? .completed : .partialFailure,
            oracleResults: lanes,
            warnings: warnings
        )
        return ContextBuilderOracleGroupReply(result: result).toMCPFields()
    }

    private func texts(_ blocks: [MCP.Tool.Content]) -> [String] {
        blocks.compactMap { block -> String? in
            guard case let .text(text, _, _) = block else { return nil }
            return text
        }
    }

    private func joinedText(_ blocks: [MCP.Tool.Content]) -> String {
        texts(blocks).joined(separator: "\n")
    }
}

final class MCPToolHeartbeatTests: XCTestCase {
    private enum OperationFailure: Error { case expected }

    private actor HeartbeatGate {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private(set) var exited = false

        func send() async {
            guard !entered else { return }
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            await withCheckedContinuation { releaseContinuation = $0 }
            exited = true
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    func testSuccessAndFailureDrainInFlightHeartbeatBeforeReturning() async {
        for shouldThrow in [false, true] {
            let gate = HeartbeatGate()
            let operationFinished = expectation(description: "operation finished")
            let returnedBeforeCleanup = expectation(description: "request returned before heartbeat cleanup")
            returnedBeforeCleanup.isInverted = true
            let task = Task { () -> Result<String, Error> in
                let outcome: Result<String, Error>
                do {
                    let value = try await MCPToolHeartbeat.run(interval: .milliseconds(1), heartbeat: { await gate.send() }) {
                        await gate.waitUntilEntered()
                        operationFinished.fulfill()
                        if shouldThrow { throw OperationFailure.expected }
                        return "settled"
                    }
                    outcome = .success(value)
                } catch {
                    outcome = .failure(error)
                }
                if await !gate.exited { returnedBeforeCleanup.fulfill() }
                return outcome
            }
            await fulfillment(of: [operationFinished], timeout: 2)
            await fulfillment(of: [returnedBeforeCleanup], timeout: 0.1)
            await gate.release()
            let outcome = await task.value
            let heartbeatExited = await gate.exited
            XCTAssertTrue(heartbeatExited)
            switch outcome {
            case let .success(value):
                XCTAssertFalse(shouldThrow)
                XCTAssertEqual(value, "settled")
            case let .failure(error):
                XCTAssertTrue(shouldThrow)
                XCTAssertTrue(error is OperationFailure)
            }
        }
    }

    func testCancellationPreservesSettledPartialOperationResult() async throws {
        let entered = expectation(description: "operation entered")
        let task = Task {
            try await MCPToolHeartbeat.run(interval: .milliseconds(1), heartbeat: {}) {
                entered.fulfill()
                do {
                    try await Task.sleep(for: .seconds(60))
                    XCTFail("Expected cancellation")
                } catch is CancellationError {
                    // Oracle settles its completed and cancelled lanes before returning.
                }
                return "partial_failure"
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result, "partial_failure")
    }

    func testCancellationStillPropagatesWhenOperationThrows() async throws {
        let entered = expectation(description: "operation entered")
        let task = Task {
            try await MCPToolHeartbeat.run(interval: .milliseconds(1), heartbeat: {}) {
                entered.fulfill()
                try await Task.sleep(for: .seconds(60))
                return "unexpected"
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Operation cancellation must not be suppressed")
        } catch is CancellationError {
            // Expected.
        }
    }
}
