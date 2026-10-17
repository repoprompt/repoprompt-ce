import Foundation
import os
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import XCTest

final class CodexNativeSessionControllerInterruptTests: XCTestCase {
    func testActiveTurnMismatchParserMatrix() {
        let rows: [(description: String, expectedTurnID: String?)] = [
            ("turn/interrupt failed: expected active turn id `turn-old` but found `turn-new`", "turn-new"),
            ("network failed", nil),
            ("expected active turn id `old` but found ``", nil),
            ("expected active turn id `old` but found turn-new", nil)
        ]

        for row in rows {
            XCTAssertEqual(
                CodexNativeSessionController.activeTurnMismatchActualTurnID(fromErrorDescription: row.description),
                row.expectedTurnID,
                row.description
            )
        }
    }

    func testResolvedInterruptTurnIDMatrix() {
        XCTAssertNil(
            CodexNativeSessionController.resolvedInterruptTurnID(
                cachedTurnID: "stale-turn",
                refreshResult: .refreshed(nil)
            )
        )
        XCTAssertNil(
            CodexNativeSessionController.resolvedInterruptTurnID(
                cachedTurnID: "stale-turn",
                refreshResult: .refreshed(" \t\n")
            )
        )
        XCTAssertEqual(
            CodexNativeSessionController.resolvedInterruptTurnID(
                cachedTurnID: "stale-turn",
                refreshResult: .failed
            ),
            "stale-turn"
        )
        XCTAssertEqual(
            CodexNativeSessionController.resolvedInterruptTurnID(
                cachedTurnID: "stale-turn",
                refreshResult: .refreshed("fresh-turn")
            ),
            "fresh-turn"
        )
    }
}

final class CodexCLIProviderPerfRecorderTests: XCTestCase {
    private final class RecorderSpy: AgentModePerfRecording, @unchecked Sendable {
        private let fallback = NoopAgentModePerfRecorder()
        private let lock = NSLock()
        private var phases: [AgentPerfCodexLifecyclePhase] = []

        var isEnabled: Bool {
            true
        }

        func timestampMSIfEnabled() -> Double? {
            1
        }

        func timestampMS() -> Double {
            fallback.timestampMS()
        }

        func elapsedMS(since startMS: Double) -> Double {
            fallback.elapsedMS(since: startMS)
        }

        func formatMS(_ value: Double) -> String {
            fallback.formatMS(value)
        }

        func formatElapsedMS(since startMS: Double) -> String {
            fallback.formatElapsedMS(since: startMS)
        }

        func shortID(_ id: UUID?) -> String {
            fallback.shortID(id)
        }

        func counterKey(_ base: String, source: String?) -> String {
            fallback.counterKey(base, source: source)
        }

        func increment(_: String, tabID _: UUID?, by _: Int) {}
        func event(_: String, tabID _: UUID?, fields _: [String: String]) {}
        func durationEvent(_: String, startMS _: Double?, tabID _: UUID?, fields _: [String: String]) {}
        func recordStoreUpdate(_: String, published _: Bool, details _: [String: String]) {}
        func recordConversationReplay(_: AgentPerfConversationReplayEvent, startMS _: Double?) {}
        func beginSidebarDelete(_: AgentPerfSidebarDeleteBeginContext) -> UUID {
            UUID()
        }

        func markSidebarDeleteVisibleRemoved(tabID _: UUID, source _: String, fields _: [String: String]) {}
        func markSidebarDeleteAgentCleanupComplete(tabID _: UUID, source _: String, fields _: [String: String]) {}
        func markSidebarDeleteFullCleanupComplete(tabID _: UUID, source _: String, fields _: [String: String]) {}
        func cancelSidebarDeleteTracking(tabID _: UUID, source _: String, fields _: [String: String]) {}
        func recordSessionSnapshot(tabID _: UUID, fields _: [String: AgentPerfSnapshotValue]) {}
        func recordCodexLifecyclePhase(
            _ phase: AgentPerfCodexLifecyclePhase,
            outcome _: AgentPerfCodexLifecycleOutcome,
            startMS _: Double?,
            tabID _: UUID,
            transportGeneration _: UInt64?
        ) {
            lock.lock()
            phases.append(phase)
            lock.unlock()
        }

        func recordedPhases() -> [AgentPerfCodexLifecyclePhase] {
            lock.lock()
            defer { lock.unlock() }
            return phases
        }
    }

    func testDefaultInteractiveControllerReceivesProviderRecorder() async throws {
        let recorder = RecorderSpy()
        let provider = CodexCLIProvider(perfRecorder: recorder)
        let client = CodexAppServerClient()
        let controller = try XCTUnwrap(provider.makeInteractiveSessionController(
            appServerClient: client,
            excludeServers: [],
            requestTimeout: 10
        ) as? CodexNativeSessionController)

        await controller.debugRecordLifecyclePhaseForTesting()

        XCTAssertEqual(recorder.recordedPhases(), [.runtimeResolution])
    }
}

final class CodexMCPDiscoveryPolicyTests: XCTestCase {
    /// Pure configuration tests: no controller/provider factory or process is reachable.
    func testOnlyRepoPromptIsRequiredWithoutChangingThirdPartyEnablement() {
        let entries = ["RepoPromptCE", "Selected", "Disabled"].map {
            MCPIntegrationHelper.CodexServerEntry(rawName: $0, normalizedName: $0, cliPathComponent: $0)
        }
        for suppressThirdParty in [false, true] {
            let overrides = CodexNativeSessionController.appServerMCPServerOverrides(
                serverEntries: entries,
                enabledMCPServerNames: ["Selected"],
                suppressThirdPartyMCPServers: suppressThirdParty,
                computerUseEnabled: false
            )
            XCTAssertEqual(overrides.count, 4)
            XCTAssertEqual(overrides["mcp_servers.RepoPromptCE.enabled"] as? Bool, true)
            XCTAssertEqual(overrides["mcp_servers.RepoPromptCE.required"] as? Bool, true)
            XCTAssertEqual(overrides["mcp_servers.Selected.enabled"] as? Bool, !suppressThirdParty)
            XCTAssertEqual(overrides["mcp_servers.Disabled.enabled"] as? Bool, false)
            XCTAssertNil(overrides["mcp_servers.Selected.required"])
            XCTAssertNil(overrides["mcp_servers.Disabled.required"])
        }
    }

    func testRepoPromptDiscoveryIsRequiredWithoutPersistedServerEntries() {
        let overrides = CodexNativeSessionController.appServerMCPServerOverrides(
            serverEntries: [],
            enabledMCPServerNames: [],
            suppressThirdPartyMCPServers: false,
            computerUseEnabled: false
        )
        XCTAssertEqual(overrides.count, 2)
        XCTAssertEqual(overrides["mcp_servers.RepoPromptCE.enabled"] as? Bool, true)
        XCTAssertEqual(overrides["mcp_servers.RepoPromptCE.required"] as? Bool, true)
    }
}

final class CodexAppServerFramingTests: XCTestCase {
    private let budget = 64 * 1024 * 1024

    func testLargeResumeSettlesWithRestoredStateAndTokenReplayAcrossChunkings() async throws {
        for chunkSize in [31 * 1024 * 1024, 9 * 1024 * 1024, 65537] {
            let sent = AsyncStream<Data>.makeStream()
            let client = CodexAppServerClient(writeFrameHandler: { _, frame in sent.continuation.yield(frame) })
            await client.debugInstallTestTransport()
            let generation = await client.debugTransportGeneration()
            var writes = sent.stream.makeAsyncIterator()
            // Exercise numeric JSON-RPC id 5, matching a resume after initialization.
            for id in 1 ... 4 {
                let request = beginRequest(client, method: "fixture/ping")
                _ = await writes.next()
                await client.debugIngestStdoutChunk(Data("{\"id\":\(id),\"result\":{}}\n".utf8), generation: generation)
                _ = try await request.value
            }
            let controller = CodexNativeSessionController(
                client: client, runID: UUID(), tabID: UUID(), windowID: 1,
                workspacePaths: .uniform(NSTemporaryDirectory())
            )
            try await controller.test_beginBindingSession()
            await controller.test_bufferNotificationDuringBinding(.init(method: "thread/tokenUsage/updated", params: [
                "threadId": .string("thread-fixture"),
                "tokenUsage": .object(["last": .object(["totalTokens": .number(123)]), "total": .object(["totalTokens": .number(456)]), "modelContextWindow": .number(1000)])
            ]))
            let request = beginRequest(client, method: "thread/resume")
            _ = await writes.next()
            let frame = resumeFrame(paddingBytes: 30 * 1024 * 1024)
            for start in stride(from: 0, to: frame.count, by: chunkSize) {
                await client.debugIngestStdoutChunk(frame.subdata(in: start ..< min(start + chunkSize, frame.count)), generation: generation)
            }
            let result = try await request.value
            let snapshot = CodexNativeSessionController.test_parseThreadSnapshot(result, fallbackEffort: nil)
            let small = try XCTUnwrap(try JSONSerialization.jsonObject(with: resumeFrame(paddingBytes: 0)) as? [String: Any])
            let expected = try CodexNativeSessionController.test_parseThreadSnapshot(XCTUnwrap(small["result"] as? [String: Any]), fallbackEffort: nil)
            XCTAssertEqual(snapshot, expected)
            XCTAssertEqual(snapshot.activeTurnIDs, ["active-a", "active-b"])
            XCTAssertEqual(snapshot.currentTurnID, "active-b")
            XCTAssertEqual(snapshot.activeToolItems.map(\.itemID), ["tool-a", "tool-b"])
            XCTAssertEqual(snapshot.latestTerminalTurnID, "failed-turn")
            XCTAssertEqual(snapshot.latestTurnFailure?.message, "fixture failure")
            let reference = await controller.test_finishBinding(result: result, fallbackEffort: nil)
            XCTAssertEqual(reference.conversationID, "thread-fixture")
            XCTAssertEqual(controller.test_routingCurrentTurnID, "active-b")
            var events = controller.events.makeAsyncIterator()
            guard case let .tokenUsage(usage) = await events.next() else {
                XCTFail("Buffered token usage was not replayed after binding")
                await controller.shutdown()
                await client.stop()
                continue
            }
            XCTAssertEqual(usage.lastTotalTokens, 123)
            XCTAssertEqual(usage.totalTotalTokens, 456)
            XCTAssertEqual(usage.modelContextWindow, 1000)
            let pending = await client.debugPendingRequestCount()
            let timers = await client.debugTimeoutTaskCount()
            XCTAssertEqual(pending, 0)
            XCTAssertEqual(timers, 0)
            await controller.shutdown()
            await client.stop()
            sent.continuation.finish()
        }
    }

    func testOverBudgetSplitAndSameChunkFailAllRequestsWithoutSuffixOrTimerLeak() async throws {
        for split in [true, false] {
            let sent = AsyncStream<Data>.makeStream()
            let client = CodexAppServerClient(writeFrameHandler: { _, frame in sent.continuation.yield(frame) })
            await client.debugInstallTestTransport()
            let generation = await client.debugTransportGeneration()
            var writes = sent.stream.makeAsyncIterator()
            let first = beginRequest(client, method: "thread/resume")
            _ = await writes.next()
            let second = beginRequest(client, method: "fixture/ping")
            _ = await writes.next()
            let suffix = Data("\n{\"id\":1,\"result\":{\"recovered\":true}}\n".utf8)
            if split {
                let chunk = Data(repeating: 0x78, count: 1024 * 1024)
                for _ in 0 ..< 64 {
                    await client.debugIngestStdoutChunk(chunk, generation: generation)
                }
                await client.debugIngestStdoutChunk(Data([0x78]), generation: generation)
                // Failure must settle before the delimiter or any recoverable suffix arrives.
            } else {
                var chunk = Data(repeating: 0x78, count: budget + 1)
                chunk.append(suffix)
                await client.debugIngestStdoutChunk(chunk, generation: generation)
            }
            for request in [first, second] {
                do {
                    _ = try await request.value
                    XCTFail("Oversized transport must fail every pending request")
                } catch let error as CodexAppServerClient.ClientError {
                    guard case let .stdoutFrameBudgetExceeded(limitBytes) = error else {
                        XCTFail("Unexpected failure: \(error)")
                        continue
                    }
                    XCTAssertEqual(limitBytes, budget)
                }
            }
            await client.debugIngestStdoutChunk(suffix, generation: generation)
            let pending = await client.debugPendingRequestCount()
            let timers = await client.debugTimeoutTaskCount()
            let running = await client.debugIsProcessRunning()
            let reason = await client.debugLastTransportTerminationReason()
            XCTAssertEqual(pending, 0)
            XCTAssertEqual(timers, 0)
            XCTAssertFalse(running)
            XCTAssertEqual(reason, .stdoutFrameBudgetExceeded(limitBytes: budget))
            let recoveryAttempts = await client.debugDecodeRecoveryAttempts()
            XCTAssertEqual(recoveryAttempts, 0)

            await client.debugInstallTestTransport()
            let successor = await client.debugTransportGeneration()
            let next = beginRequest(client, method: "fixture/ping")
            let written = await writes.next()
            let write = try XCTUnwrap(written)
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: write) as? [String: Any])
            await client.debugIngestStdoutChunk(Data(repeating: 0x78, count: budget + 1), generation: generation)
            let successorRunning = await client.debugIsProcessRunning()
            let successorReason = await client.debugLastTransportTerminationReason()
            XCTAssertTrue(successorRunning)
            XCTAssertNil(successorReason)
            let id = try XCTUnwrap(payload["id"] as? Int)
            await client.debugIngestStdoutChunk(Data("{\"id\":\(id),\"result\":{\"ok\":true}}\n".utf8), generation: successor)
            let reply = try await next.value
            XCTAssertEqual(reply["ok"] as? Bool, true)
            await client.stop()
            sent.continuation.finish()
        }
    }

    private func beginRequest(_ client: CodexAppServerClient, method: String) -> Task<[String: Any], Error> {
        Task { try await client.request(method: method, params: nil, timeout: 120, useDefaultTimeout: false) }
    }

    private func resumeFrame(paddingBytes: Int) -> Data {
        var frame = Data(#"{"id":5,"result":{"model":"fixture-model","thread":{"id":"thread-fixture","status":{"type":"active","activeFlags":[]},"turns":[{"id":"history","status":"completed","items":[{"type":"userMessage","id":"large-item","content":[{"type":"text","text":""#.utf8)
        frame.append(Data(repeating: 0x78, count: paddingBytes))
        frame.append(Data(#""}]}]},{"id":"failed-turn","status":"failed","error":{"message":"fixture failure"},"items":[]},{"id":"active-a","status":"inProgress","itemsView":"full","items":[{"type":"mcpToolCall","id":"tool-a","tool":"fixture_tool","status":"inProgress"}]},{"id":"active-b","status":"inProgress","itemsView":"full","items":[{"type":"commandExecution","id":"tool-b","status":"inProgress"}]}]}}}"#.utf8))
        frame.append(0x0A)
        return frame
    }
}

// MARK: - Assembled Codex turn input boundary

#if DEBUG
    final class CodexInputBoundaryTests: XCTestCase {
        private let limit = 1_048_576

        func testFinalTurnRequestsRejectOnlyAboveScalarAggregateBeforeDispatch() async throws {
            let fixture = BoundaryTransport()
            await fixture.install()
            defer { fixture.release() }
            for method in ["turn/start", "turn/steer"] {
                for count in [limit - 1, limit, limit + 1] {
                    let before = fixture.frames.count
                    let text = String(repeating: "😀", count: count)
                    do {
                        _ = try await fixture.client.request(method: method, params: ["threadId": "fixture", "input": [["type": "text", "text": text]]], timeout: 2)
                        XCTAssertLessThanOrEqual(count, limit, "Oversized input reached dispatch")
                        XCTAssertEqual(fixture.frames.count, before + 1)
                        let frame = try XCTUnwrap(fixture.frames.last)
                        let params = try XCTUnwrap(frame["params"] as? [String: Any])
                        let inputs = try XCTUnwrap(params["input"] as? [[String: Any]])
                        XCTAssertEqual(inputs.first?["text"] as? String, text, "Accepted input must remain byte-for-byte intact")
                    } catch {
                        XCTAssertGreaterThan(count, limit)
                        assertInputFailure(error, method: method, actual: count)
                        XCTAssertEqual(fixture.frames.count, before, "Rejected input must never be written")
                    }
                    let pending = await fixture.client.debugPendingRequestCount()
                    let timers = await fixture.client.debugTimeoutTaskCount()
                    XCTAssertEqual(pending, 0)
                    XCTAssertEqual(timers, 0)
                }
            }
            await fixture.client.stop()
        }

        func testAggregationDecodedUnicodeAndNontextVariantsAtActualRequestBoundary() async throws {
            let fixture = BoundaryTransport()
            await fixture.install()
            defer { fixture.release() }
            // Swift graphemes=524289, UTF8 bytes>limit, Unicode scalars=limit+1.
            let decomposed = String(repeating: "e\u{301}", count: limit / 2)
            let inputs: [[String: Any]] = [
                ["type": "text", "text": decomposed], ["type": "text", "text": "é"],
                ["type": "image", "url": String(repeating: "x", count: limit + 1)],
                ["type": "localImage", "path": "/fixture"], ["type": "audio", "audio": "fixture"],
                ["type": "localAudio", "path": "/fixture"], ["type": "skill", "name": "fixture", "path": "/fixture"],
                ["type": "mention", "name": "fixture", "path": "/fixture"]
            ]
            do {
                _ = try await fixture.client.request(method: "turn/steer", params: ["input": inputs], timeout: 2)
                XCTFail("Individually admissible text items must share one allowance")
            } catch { assertInputFailure(error, method: "turn/steer", actual: limit + 1) }
            XCTAssertTrue(fixture.frames.isEmpty)
            let accepted = Array(inputs.dropFirst(2)) + [["type": "text", "text": String(decomposed.dropLast(2)) + "\"\n\\😀"]]
            // Escaping increases serialized bytes, not decoded scalar count. Nontext contributes zero.
            _ = try await fixture.client.request(method: "turn/start", params: ["input": accepted], timeout: 2)
            XCTAssertEqual(fixture.frames.count, 1)
            // This separate field is not a turn-input quota; only thread/start owns it.
            _ = try await fixture.client.request(method: "thread/start", params: ["baseInstructions": String(repeating: "x", count: limit + 1)], timeout: 2)
            XCTAssertEqual(fixture.frames.count, 2)
            await fixture.client.stop()
        }

        func testControllerAssemblyTrimsBeforeCountingAndRetainsImagesAndText() async throws {
            let fixture = BoundaryTransport()
            await fixture.install()
            defer { fixture.release() }
            let text = String(repeating: "é", count: limit)
            let input = try CodexNativeSessionController.turnInput(text: " \n" + text + "\t ", images: [
                AgentImageAttachment(source: .url(" https://fixture.invalid/image "), title: nil),
                AgentImageAttachment(source: .localFile(path: " /fixture/image.png "), title: nil)
            ])
            _ = try await fixture.client.request(method: "turn/start", params: ["input": input], timeout: 2)
            XCTAssertEqual(input.count, 3)
            XCTAssertEqual(input.last?["text"] as? String, text)
            XCTAssertEqual(input.first?["url"] as? String, "https://fixture.invalid/image")
            XCTAssertEqual(input[1]["path"] as? String, "/fixture/image.png")
            let oversized = try CodexNativeSessionController.turnInput(text: " " + text + "x ", images: [])
            do {
                _ = try await fixture.client.request(method: "turn/start", params: ["input": oversized], timeout: 2)
                XCTFail("Final trimmed text must be guarded")
            } catch { assertInputFailure(error, method: "turn/start", actual: limit + 1) }
            XCTAssertEqual(fixture.frames.count, 1)
            await fixture.client.stop()
        }

        @MainActor
        func testStructuredUpstreamRejectionSurvivesProviderStreamWithoutRetryAndCleansUp() async throws {
            let fixture = BoundaryTransport(upstreamRejection: true)
            await fixture.install()
            defer { fixture.release() }
            let controller = BoundaryFailureController(client: fixture.client)
            // Invalid disposable runtime selection makes discovery fail closed; no real config/provider is provisioned.
            let provider = CodexCLIProvider(launchSnapshot: .init(selection: .external(path: "/nonexistent/codex-boundary-fixture")), sessionControllerFactory: { _, _ in controller })
            let stream = try await provider.streamMessage(AIMessage(systemPrompt: "separate instructions", userMessage: "fixture"), model: .gpt54Mini)
            do {
                for try await _ in stream {}
                XCTFail("Expected upstream rejection")
            } catch {
                guard case let AIProviderError.apiError(source) = error else { return XCTFail("Wrong provider classification: \(type(of: error))") }
                try assertInputFailure(XCTUnwrap(source), method: "turn/start", actual: limit + 7)
                XCTAssertFalse(error.localizedDescription.contains("private_fixture_data"), "Arbitrary upstream data is not user-facing")
            }
            XCTAssertEqual(controller.attempts, 1)
            XCTAssertEqual(controller.shutdowns, 1)
            XCTAssertEqual(fixture.frames.count, 1)
            await fixture.client.stop()
        }

        @MainActor
        func testProviderGuardsItsAssembledPromptAndKeepsSeparateInstructionsOutsideAllowance() async throws {
            for oversized in [false, true] {
                let fixture = BoundaryTransport()
                await fixture.install()
                let controller = BoundaryFailureController(client: fixture.client)
                let provider = CodexCLIProvider(launchSnapshot: .init(selection: .external(path: "/nonexistent/codex-boundary-fixture")), sessionControllerFactory: { _, _ in controller })
                let message = AIMessage(systemPrompt: String(repeating: "x", count: limit + 1), userMessage: oversized ? String(repeating: "é", count: limit) : "fixture")
                let stream = try await provider.streamMessage(message, model: .gpt54Mini)
                do {
                    var results: [AIStreamResult] = []
                    for try await result in stream {
                        results.append(result)
                    }
                    XCTAssertFalse(oversized)
                    XCTAssertEqual(results.last?.type, "message_stop")
                    XCTAssertEqual(fixture.frames.count, 1)
                } catch {
                    XCTAssertTrue(oversized)
                    guard case let AIProviderError.apiError(source) = error else { return XCTFail("Lost provider error source") }
                    let assembled = try XCTUnwrap(controller.submittedText)
                    XCTAssertGreaterThan(assembled.unicodeScalars.count, limit, "Count includes the real provider reminder/conversation envelope")
                    try assertInputFailure(XCTUnwrap(source), method: "turn/start", actual: assembled.unicodeScalars.count)
                    XCTAssertTrue(fixture.frames.isEmpty)
                }
                XCTAssertEqual(controller.attempts, 1)
                XCTAssertEqual(controller.shutdowns, 1)
                XCTAssertEqual(controller.baseInstructions?.unicodeScalars.count, limit + 1)
                await fixture.client.stop()
                fixture.release()
            }
        }

        private func assertInputFailure(_ error: Error, method: String, actual: Int, file: StaticString = #filePath, line: UInt = #line) {
            guard case let CodexAppServerClient.ClientError.requestFailed(failure) = error else { return XCTFail("Lost typed request failure: \(type(of: error))", file: file, line: line) }
            XCTAssertEqual(failure.method, method, file: file, line: line)
            XCTAssertEqual(failure.code, -32602, file: file, line: line)
            guard case let .object(data) = failure.data else { return XCTFail("Missing structured boundary data", file: file, line: line) }
            XCTAssertEqual(data["input_error_code"], .string("input_too_large"), file: file, line: line)
            XCTAssertEqual(data["max_chars"], .number(Double(limit)), file: file, line: line)
            XCTAssertEqual(data["actual_chars"], .number(Double(actual)), file: file, line: line)
            XCTAssertTrue(failure.userFacingMessage.contains("Reduce"), file: file, line: line)
        }
    }

    private final class BoundaryTransport: @unchecked Sendable {
        private struct State { var client: CodexAppServerClient?
            var frames: [[String: Any]] = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let upstreamRejection: Bool
        lazy var client: CodexAppServerClient = {
            let client = CodexAppServerClient(writeFrameHandler: { [weak self] _, bytes in
                guard let self else { throw CodexAppServerClient.ClientError.processNotRunning }
                let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                let client = state.withLock { state in state.frames.append(frame)
                    return state.client
                }
                var response: [String: Any] = ["id": frame["id"]!]
                if upstreamRejection {
                    response["error"] = ["code": -32602, "message": "Input exceeds the maximum length of 1048576 characters. Network timeout diagnostic.", "data": ["input_error_code": "input_too_large", "max_chars": 1_048_576, "actual_chars": 1_048_583, "private_fixture_data": "must not be displayed"]]
                } else { response["result"] = ["turn": ["id": "fixture-turn"], "turnId": "fixture-turn"] }
                let encoded = try JSONSerialization.data(withJSONObject: response)
                Task { await client?.debugIngestRawStdoutLine(encoded) }
            })
            state.withLock { $0.client = client }
            return client
        }()

        init(upstreamRejection: Bool = false) {
            self.upstreamRejection = upstreamRejection
        }

        var frames: [[String: Any]] {
            state.withLock { $0.frames }
        }

        func install() async {
            await client.debugInstallTestTransport()
        }

        func release() {
            state.withLock { $0.client = nil }
        }
    }

    private final class BoundaryFailureController: CodexSessionControlling {
        let client: CodexAppServerClient
        var attempts = 0
        var shutdowns = 0
        var submittedText: String?
        var baseInstructions: String?
        var hasActiveThread: Bool {
            true
        }

        var events: AsyncStream<CodexNativeSessionController.Event> {
            AsyncStream { $0.yield(.turnCompleted(turnID: "fixture-turn", status: .completed, failure: nil))
                $0.finish()
            }
        }

        init(client: CodexAppServerClient) {
            self.client = client
        }

        func ensureEventsStreamReady() {}
        func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
            self.baseInstructions = baseInstructions
            return .init(conversationID: "fixture", rolloutPath: nil, model: nil, reasoningEffort: nil)
        }

        func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
            try await startOrResume(existing: existing, baseInstructions: baseInstructions)
        }

        func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
            try await startOrResume(existing: existing, baseInstructions: baseInstructions)
        }

        func startUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexTurnStartReceipt {
            attempts += 1
            submittedText = text
            let result = try await client.request(method: "turn/start", params: ["input": CodexNativeSessionController.turnInput(text: text, images: images)], timeout: 2)
            let turn = try XCTUnwrap(result["turn"] as? [String: Any])
            return try CodexTurnStartReceipt(provisionalSubmissionID: XCTUnwrap(turn["id"] as? String))
        }

        func steerUserTurn(text: String, images: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
            throw CodexAppServerClient.ClientError.invalidResponse
        }

        func readThreadSnapshot(includeTurns: Bool, timeout: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
            throw CodexAppServerClient.ClientError.invalidResponse
        }

        func setThreadName(_ name: String, threadID: String?) async throws {}
        func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(expectedCurrentTurnID: String, acceptedDispatchTurnID: String) async -> Bool {
            false
        }

        func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
            throw CodexAppServerClient.ClientError.invalidResponse
        }

        func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
            throw CodexAppServerClient.ClientError.invalidResponse
        }

        func compactThread() async throws {}
        func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
            nil
        }

        func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
            throw CodexAppServerClient.ClientError.invalidResponse
        }

        func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
            throw CodexAppServerClient.ClientError.invalidResponse
        }

        func clearThreadGoal() async throws -> Bool {
            false
        }

        func pendingTurnFailure(turnID: String?) async -> CodexNativeSessionController.TurnFailure? {
            nil
        }

        func acknowledgePendingTurnFailure(turnID: String?, failure: CodexNativeSessionController.TurnFailure) async {}
        func cancelCurrentTurn() async {}
        func shutdown() async {
            shutdowns += 1
        }

        func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
    }
#endif
