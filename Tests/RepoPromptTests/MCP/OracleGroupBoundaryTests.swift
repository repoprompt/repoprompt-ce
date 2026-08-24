import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

#if DEBUG
    @MainActor
    final class OracleGroupBoundaryTests: XCTestCase {
        func testOracleSendStartWithChatIDDoesNotRebind() async {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }

            await assertStopsAfterRoute(
                fixture.service,
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
                ])
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
                fixture.service,
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
                fixture.service,
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
                ])
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
                fixture.service,
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
            ])

            XCTAssertEqual(fixture.sendRecorder.calls.count, 1)
            XCTAssertEqual(fixture.sendRecorder.calls[0]["message"], .string("continue selected"))
            XCTAssertNil(fixture.sendRecorder.calls[0]["chat_id"])
            XCTAssertNil(fixture.sendRecorder.calls[0]["new_chat"])
            XCTAssertNil(fixture.sendRecorder.calls[0]["model"])
            XCTAssertEqual(fixture.rebindRecorder.count, 0)
        }

        func testAgentModeOracleSendDoesNotCompatibilityRebind() async {
            let fixture = makeOracleSendFixture()
            defer { fixture.cleanup() }
            let connectionID = UUID()
            await ServerNetworkManager.shared.setRunPurpose(.agentModeRun, for: connectionID)

            await ServerNetworkManager.withConnectionID(connectionID) {
                await assertStopsAfterRoute(
                    fixture.service,
                    args: [
                        "message": .string("continue"),
                        "chat_id": .string("existing-chat")
                    ]
                )
            }
            await ServerNetworkManager.shared.setRunPurpose(.unknown, for: connectionID)
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

        private func assertStopsAfterRoute(
            _ service: MCPOracleToolService,
            args: [String: Value]
        ) async {
            do {
                _ = try await service.executeOracleSend(args: args)
                XCTFail("Expected test stop after route validation")
            } catch OracleBoundaryTestStop.afterRoute {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        private func makeOracleSendFixture(stopAfterRoute: Bool = true) -> OracleSendBoundaryFixture {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

            let snapshot = MCPServerViewModel.TabContextSnapshot(
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
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: nil,
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
                captureRequestMetadata: { metadata },
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
                    return [
                        "chat_id": .string("selected-chat"),
                        "response": .string("response")
                    ]
                },
                exportOracleResponse: { _ in throw OracleBoundaryTestStop.unexpectedExport }
            )
            return OracleSendBoundaryFixture(
                window: window,
                service: service,
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
        let service: MCPOracleToolService
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
