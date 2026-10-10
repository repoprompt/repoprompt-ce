import Foundation
@testable import RepoPromptApp
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
