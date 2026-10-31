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

    @MainActor
    func testLargeResumeSettlesWithRestoredStateAndTokenReplayAcrossChunkings() async throws {
        for includesTurnID in [true, false] {
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
                let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
                let session = harness.host.session(for: UUID())
                session.selectedAgent = .codexExec
                session.hasLoadedPersistedState = true
                session.runState = .running
                let runID = UUID()
                session.installRunID(runID)
                let owner = session.beginRunAttempt(source: "buffered-token-scope")
                let wakeID = UUID()
                session.quietLedger.markRoutineWake(owner: owner, wakeID: wakeID)
                let controller = CodexNativeSessionController(
                    client: client, runID: runID, tabID: session.tabID, windowID: 1,
                    workspacePaths: .uniform(NSTemporaryDirectory())
                )
                session.codexController = controller
                session.codexConversationID = "thread-fixture"
                try await controller.test_beginBindingSession()
                var tokenParams: [String: CodexJSONValue] = [
                    "threadId": .string("thread-fixture"), "turnId": .string("active-b"),
                    "tokenUsage": .object(["last": .object(["totalTokens": .number(123)]), "total": .object(["totalTokens": .number(456)]), "modelContextWindow": .number(1000)])
                ]
                if !includesTurnID { tokenParams["turnId"] = nil }
                await controller.test_bufferNotificationDuringBinding(.init(method: "thread/tokenUsage/updated", params: tokenParams))
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
                await harness.host.test_codexCoordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "active-b"), session: session, sourceController: controller)
                var events = controller.events.makeAsyncIterator()
                if !includesTurnID {
                    let next = await events.next()
                    let event = try XCTUnwrap(next)
                    guard case let .livenessActivity(activity) = event else { return XCTFail("Expected uncertainty before unscoped token usage") }
                    XCTAssertEqual(activity.kind, .warning)
                    XCTAssertEqual(activity.method, "thread/tokenUsage/updated")
                    XCTAssertNil(activity.turnID)
                    await harness.host.test_codexCoordinator.test_handleCodexNativeEvent(event, session: session, sourceController: controller)
                }
                let tokenEvent = await events.next()
                guard case let .tokenUsage(usage) = tokenEvent else {
                    XCTFail("Buffered token usage was not replayed after binding")
                    await controller.shutdown()
                    await client.stop()
                    continue
                }
                XCTAssertEqual(usage.lastTotalTokens, 123)
                XCTAssertEqual(usage.totalTotalTokens, 456)
                XCTAssertEqual(usage.modelContextWindow, 1000)
                if let tokenEvent { await harness.host.test_codexCoordinator.test_handleCodexNativeEvent(tokenEvent, session: session, sourceController: controller) }
                XCTAssertEqual(session.quietLedger.candidateStartKey(owner: owner) != nil, includesTurnID, "Unscoped replay vetoes before ordinary terminal settlement")
                _ = await AgentRunTerminalCommitBarrier().commit(.init(
                    binding: harness.hooks.bindTerminalSession(session), ownership: owner, expectedRunID: runID,
                    terminalState: .completed, source: "buffered-token-scope", attachmentDisposition: .deleteFiles,
                    finalizeNonCodexUsage: false, supportsFollowUp: false, notifyTurnComplete: false, classifiesQuietCheckIn: true
                ))
                XCTAssertEqual(session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 1), "Scoped token replay is not a quiet declaration")
                XCTAssertFalse(session.quietLedger.hiddenSourceIDs.contains(wakeID))
                let pending = await client.debugPendingRequestCount()
                let timers = await client.debugTimeoutTaskCount()
                XCTAssertEqual(pending, 0)
                XCTAssertEqual(timers, 0)
                await controller.shutdown()
                let unexpected = await events.next()
                XCTAssertNil(unexpected, "Exactly token usage, or uncertainty then token usage; no extra event")
                await client.stop()
                sent.continuation.finish()
                session.saveDebounceTask?.cancel()
            }
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

final class CodexBoundedThreadSnapshotTests: XCTestCase {
    func testResumeRequestGatesPaginationWithoutChangingIdentityOrPath() async throws {
        for bounded in [false, true] {
            let controller = makeController { method, params, _ in
                XCTAssertEqual(method, "thread/resume")
                XCTAssertEqual(params?["threadId"] as? String, "thread-fixture")
                XCTAssertEqual(params?["path"] as? String, "/fixture/rollout.jsonl")
                XCTAssertNil(params?["baseInstructions"])
                if bounded {
                    XCTAssertEqual(params?["excludeTurns"] as? Bool, true)
                    let page = try XCTUnwrap(params?["initialTurnsPage"] as? [String: Any])
                    XCTAssertEqual(page["itemsView"] as? String, "notLoaded")
                    XCTAssertEqual(page["sortDirection"] as? String, "desc")
                    XCTAssertEqual(page["limit"] as? Int, 32)
                    return Self.response(page: Self.page())
                }
                XCTAssertNil(params?["excludeTurns"])
                XCTAssertNil(params?["initialTurnsPage"])
                return Self.response()
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: bounded ? 164 : 149, patch: 0))
            let result = try await controller.test_resumeThreadBinding(existing: .init(
                conversationID: "thread-fixture", rolloutPath: "/fixture/rollout.jsonl", model: nil, reasoningEffort: nil
            ))
            XCTAssertEqual((result["thread"] as? [String: Any])?["id"] as? String, "thread-fixture")
        }
    }

    func testRichReadUsesOneBoundedMetadataPageAndLegacyKeepsExistingRead() async throws {
        for bounded in [false, true] {
            let controller = makeController { method, params, timeout in
                XCTAssertEqual(params?["threadId"] as? String, "thread-fixture")
                switch method {
                case "thread/read":
                    XCTAssertEqual(params?["includeTurns"] as? Bool, !bounded)
                    return Self.response(active: true, turns: bounded ? [] : [["id": "active-from-read", "status": "inProgress", "items": []]])
                case "thread/turns/list":
                    XCTAssertTrue(bounded)
                    XCTAssertEqual(params?["itemsView"] as? String, "notLoaded")
                    XCTAssertEqual(params?["limit"] as? Int, 32)
                    XCTAssertNil(params?["cursor"])
                    XCTAssertLessThanOrEqual(try XCTUnwrap(timeout), 2)
                    return Self.page(turns: [["id": "active-from-read", "status": "inProgress", "itemsView": "notLoaded"]])
                default:
                    XCTFail("Unexpected history hydration: \(method)")
                    throw CodexAppServerClient.ClientError.invalidResponse
                }
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: bounded ? 164 : 149, patch: 0))
            controller.test_installThreadState(threadID: "thread-fixture", routingTurnID: "cached-old-turn")
            let snapshot = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)
            XCTAssertEqual(snapshot.conversationID, "thread-fixture")
            XCTAssertEqual(snapshot.currentTurnID, "active-from-read")
            XCTAssertEqual(snapshot.activeTurnIDs, ["active-from-read"])
            XCTAssertTrue(snapshot.hasActiveTurn)
            XCTAssertTrue(snapshot.hasCompleteTurnMetadata)
        }
    }

    func testMetadataOnlyReadDoesNotFetchTurns() async throws {
        let controller = makeController { method, params, _ in
            XCTAssertEqual(method, "thread/read")
            XCTAssertEqual(params?["includeTurns"] as? Bool, false)
            return Self.response()
        }
        controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
        controller.test_installThreadState(threadID: "thread-fixture")
        _ = try await controller.readThreadSnapshot(includeTurns: false, timeout: 2)
    }

    func testDescendingPagePreservesNewestFailureAndActiveRoutingWithoutItemAuthority() {
        let result = Self.response(page: Self.page(turns: [
            ["id": "active-new", "status": "inProgress", "itemsView": "notLoaded", "items": []],
            ["id": "active-old", "status": "inProgress", "itemsView": "notLoaded"],
            ["id": "failed-new", "status": "failed", "error": ["message": "new failure"]],
            ["id": "completed-old", "status": "completed"]
        ], nextCursor: "older"))
        let snapshot = CodexNativeSessionController.test_parseThreadSnapshot(result, fallbackEffort: "high")
        XCTAssertEqual(snapshot.activeTurnIDs, ["active-old", "active-new"])
        XCTAssertEqual(snapshot.currentTurnID, "active-new")
        XCTAssertEqual(snapshot.latestTerminalTurnID, "failed-new")
        XCTAssertEqual(snapshot.latestTurnStatus, .failed)
        XCTAssertEqual(snapshot.latestTurnFailure?.message, "new failure")
        XCTAssertEqual(snapshot.reasoningEffort, "high")
        XCTAssertTrue(snapshot.hasActiveTurn)
        XCTAssertFalse(snapshot.hasCompleteTurnMetadata)
        XCTAssertFalse(snapshot.hasAuthoritativeActiveTurnItems)
        XCTAssertTrue(snapshot.activeToolItems.isEmpty)
    }

    func testInterruptExhaustsThirtyThreeTurnMetadataAndRejectsSecondActiveAcrossPages() async throws {
        for secondActive in [false, true] {
            let controller = makeController { method, params, timeout in
                XCTAssertEqual(params?["threadId"] as? String, "thread-fixture")
                XCTAssertLessThanOrEqual(try XCTUnwrap(timeout), 5)
                switch method {
                case "thread/read":
                    XCTAssertEqual(params?["includeTurns"] as? Bool, false)
                    return Self.response(active: true)
                case "thread/turns/list":
                    XCTAssertEqual(params?["itemsView"] as? String, "notLoaded")
                    XCTAssertEqual(params?["limit"] as? Int, 32)
                    if params?["cursor"] == nil {
                        let completed = (1 ... 31).map { ["id": "completed-\($0)", "status": "completed"] }
                        return Self.page(turns: [["id": "active", "status": "inProgress"]] + completed, nextCursor: "older")
                    }
                    XCTAssertEqual(params?["cursor"] as? String, "older")
                    return Self.page(
                        turns: [["id": "oldest", "status": secondActive ? "inProgress" : "completed"]],
                        nextCursor: secondActive ? "must-not-fetch" : nil
                    )
                case "turn/interrupt":
                    XCTAssertFalse(secondActive)
                    XCTAssertEqual(params?["turnId"] as? String, "active")
                    return [:]
                default:
                    XCTFail("Unexpected RPC: \(method)")
                    throw CodexAppServerClient.ClientError.invalidResponse
                }
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            controller.test_installThreadState(threadID: "thread-fixture")
            do {
                let receipt = try await controller.reconcileAndInterruptCurrentTurn()
                XCTAssertFalse(secondActive)
                XCTAssertEqual(receipt.interruptedTurnID, "active")
            } catch let CodexTurnInterruptError.noUniqueActiveTurn(_, observed) {
                XCTAssertTrue(secondActive)
                XCTAssertEqual(observed, ["active", "oldest"])
            }
        }
    }

    func testOrdinarySnapshotStillStopsAfterOnePartialMetadataPage() async throws {
        let controller = makeController { method, params, _ in
            if method == "thread/read" {
                return Self.response(active: true)
            }
            XCTAssertEqual(method, "thread/turns/list")
            XCTAssertNil(params?["cursor"], "Only Stop may exhaust metadata")
            return Self.page(turns: [["id": "active", "status": "inProgress"]], nextCursor: "older")
        }
        controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
        controller.test_installThreadState(threadID: "thread-fixture")
        let snapshot = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)
        XCTAssertEqual(snapshot.activeTurnIDs, ["active"])
        XCTAssertFalse(snapshot.hasCompleteTurnMetadata)
        XCTAssertFalse(snapshot.hasAuthoritativeActiveTurnItems)
    }

    func testInterruptRejectsCursorCyclesMalformedPagesAndUnknownStatuses() async throws {
        for variant in ["cycle", "bad-cursor", "empty-cursor", "bad-data", "unknown-status"] {
            let controller = makeController { method, params, _ in
                if method == "thread/read" {
                    return Self.response(active: true)
                }
                XCTAssertEqual(method, "thread/turns/list", "Invalid metadata must not authorize interrupt")
                if variant == "cycle" {
                    XCTAssertNotEqual(params?["cursor"] as? String, "third-page")
                    return Self.page(turns: [["id": "active", "status": "inProgress"]], nextCursor: "older")
                }
                var page = Self.page(turns: [["id": "active", "status": "inProgress"]])
                switch variant {
                case "bad-cursor": page["nextCursor"] = 123
                case "empty-cursor": page["nextCursor"] = ""
                case "bad-data": page["data"] = [["status": "completed"]]
                case "unknown-status": page["data"] = [["id": "future-turn", "status": "futureStatus"]]
                default: break
                }
                return page
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            controller.test_installThreadState(threadID: "thread-fixture")
            do {
                _ = try await controller.reconcileAndInterruptCurrentTurn()
                XCTFail("Expected invalid metadata rejection: \(variant)")
            } catch CodexAppServerClient.ClientError.invalidResponse {}
        }
    }

    func testInterruptPaginationHonorsSharedDeadlineAndCancellationWithoutInterrupt() async throws {
        for cancel in [false, true] {
            var options = CodexNativeSessionController.Options.agentModeDefault()
            options.requestTimeout = cancel ? 5 : 0.005
            let controller = makeController(options: options) { method, _, _ in
                if method == "thread/read" {
                    return Self.response(active: true)
                }
                XCTAssertEqual(method, "thread/turns/list", "No interrupt after cancellation/deadline")
                if cancel {
                    withUnsafeCurrentTask { $0?.cancel() }
                } else {
                    try await Task.sleep(for: .milliseconds(20))
                }
                return Self.page(turns: [["id": "active", "status": "inProgress"]], nextCursor: "older")
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            controller.test_installThreadState(threadID: "thread-fixture")
            let task = Task { try await controller.reconcileAndInterruptCurrentTurn() }
            do {
                _ = try await task.value
                XCTFail("Expected cancellation or timeout")
            } catch is CancellationError {
                XCTAssertTrue(cancel)
            } catch {
                XCTAssertFalse(cancel)
                XCTAssertTrue(CodexAppServerClient.isTimeoutError(error))
            }
        }
    }

    func testResumeRejectsWrongIdentityAndMalformedInitialPage() async throws {
        for variant in ["wrong-thread", "nested-id", "coerced-id", "malformed-page"] {
            let controller = makeController { method, _, _ in
                XCTAssertEqual(method, "thread/resume", "Invalid identity/page must not trigger a fallback")
                switch variant {
                case "wrong-thread": return ["thread": ["id": "different-thread"], "initialTurnsPage": Self.page()]
                case "nested-id": return ["thread": ["nested": ["id": "thread-fixture"]], "initialTurnsPage": Self.page()]
                case "coerced-id": return ["thread": ["id": 123], "initialTurnsPage": Self.page()]
                default: return Self.response(page: ["data": "invalid"])
                }
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            do {
                _ = try await controller.test_resumeThreadBinding(existing: .init(
                    conversationID: variant == "coerced-id" ? "123" : "thread-fixture", rolloutPath: nil, model: nil, reasoningEffort: nil
                ))
                XCTFail("Invalid binding must not commit")
            } catch CodexAppServerClient.ClientError.invalidResponse {}
        }
    }

    func testResumeMissingOrNullInitialPageUsesOneBoundedFallbackBeforeBinding() async throws {
        for nullPage in [false, true] {
            let controller = makeController { method, params, timeout in
                XCTAssertEqual(params?["threadId"] as? String, "thread-fixture")
                if method == "thread/resume" {
                    XCTAssertEqual(params?["excludeTurns"] as? Bool, true)
                    var response = Self.response(active: true)
                    if nullPage {
                        response["initialTurnsPage"] = NSNull()
                    }
                    return response
                }
                XCTAssertEqual(method, "thread/turns/list")
                XCTAssertNil(params?["cursor"])
                XCTAssertEqual(params?["limit"] as? Int, 32)
                XCTAssertEqual(params?["itemsView"] as? String, "notLoaded")
                XCTAssertLessThanOrEqual(try XCTUnwrap(timeout), 5)
                return Self.page(turns: [["id": "resumed-active", "status": "inProgress"]], nextCursor: "older")
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            try await controller.test_beginBindingSession()
            let result = try await controller.test_resumeThreadBinding(existing: .init(
                conversationID: "thread-fixture", rolloutPath: nil, model: nil, reasoningEffort: nil
            ))
            let reference = await controller.test_finishBinding(result: result, fallbackEffort: nil)
            XCTAssertEqual(reference.conversationID, "thread-fixture")
            XCTAssertEqual(controller.test_routingCurrentTurnID, "resumed-active")
        }
    }

    func testResumeFallbackHonorsOriginalDeadlineAndCancellation() async throws {
        for cancel in [false, true] {
            let controller = makeController { method, _, _ in
                XCTAssertEqual(method, "thread/resume", "No fallback after cancellation/deadline")
                if cancel {
                    withUnsafeCurrentTask { $0?.cancel() }
                } else {
                    try await Task.sleep(for: .milliseconds(20))
                }
                return Self.response()
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            let task = Task {
                try await controller.test_resumeThreadBinding(existing: .init(
                    conversationID: "thread-fixture", rolloutPath: nil, model: nil, reasoningEffort: nil
                ), timeout: cancel ? 5 : 0.005)
            }
            do {
                _ = try await task.value
                XCTFail("Expected cancellation or timeout")
            } catch is CancellationError {
                XCTAssertTrue(cancel)
            } catch {
                XCTAssertFalse(cancel)
                XCTAssertTrue(CodexAppServerClient.isTimeoutError(error))
            }
        }
    }

    func testNativeToolProbeRestoresExactFullCurrentTurnEvidenceIncludingTerminalItems() async throws {
        for itemStatus in ["inProgress", "completed"] {
            let controller = makeController { method, params, timeout in
                XCTAssertEqual(params?["threadId"] as? String, "thread-fixture")
                switch method {
                case "thread/read":
                    XCTAssertEqual(params?["includeTurns"] as? Bool, false)
                    return Self.response(active: true)
                case "thread/turns/list":
                    XCTAssertEqual(params?["limit"] as? Int, 1)
                    XCTAssertEqual(params?["itemsView"] as? String, "full")
                    XCTAssertEqual(params?["sortDirection"] as? String, "desc")
                    XCTAssertNil(params?["cursor"])
                    XCTAssertLessThanOrEqual(try XCTUnwrap(timeout), 2)
                    return Self.page(turns: [[
                        "id": "active-probe", "status": "inProgress", "itemsView": "full",
                        "items": [
                            ["id": "call_probe", "type": "dynamicToolCall", "tool": "offline_probe_wait", "status": itemStatus],
                            ["id": "command-a", "type": "commandExecution", "processId": "123", "status": "inProgress"],
                            ["id": "command-b", "type": "commandExecution", "processId": "123", "status": "completed"]
                        ]
                    ]], nextCursor: "older-turns")
                default:
                    XCTFail("Tool probe must not add history/item RPCs: \(method)")
                    throw CodexAppServerClient.ClientError.invalidResponse
                }
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            controller.test_installThreadState(threadID: "thread-fixture")
            let snapshot = try await controller.readNativeToolProbeSnapshot(expectedTurnID: "active-probe", timeout: 2)
            XCTAssertEqual(snapshot.currentTurnID, "active-probe")
            XCTAssertNil(snapshot.latestTerminalTurnID, "The current-turn-only tool probe intentionally omits prior terminal turns")
            XCTAssertNil(snapshot.latestTurnStatus)
            XCTAssertTrue(snapshot.hasAuthoritativeActiveTurnItems)
            XCTAssertFalse(snapshot.hasCompleteTurnMetadata, "Older turns are omitted, but the exact active turn's item set is full")
            let item = try XCTUnwrap(snapshot.activeToolItems.first)
            XCTAssertEqual(item.turnID, "active-probe")
            XCTAssertEqual(item.itemID, "call_probe")
            XCTAssertNotNil(item.invocationID)
            XCTAssertEqual(snapshot.activeToolItems.filter { $0.kind == .commandExecution }.map(\.itemID), ["command-a", "command-b"], "Keep all commands for the coordinator's process-ID ambiguity check")
            XCTAssertEqual(item.kind, .dynamicToolCall)
            XCTAssertEqual(item.status, itemStatus == "inProgress" ? .inProgress : .terminal)
        }
    }

    func testNativeToolProbeRejectsWrongTurnPartialOrMalformedItemAuthority() async throws {
        for variant in ["wrong-turn", "summary", "notLoaded", "missing-view", "missing-items", "malformed-item", "terminal-turn", "multiple-turns"] {
            let controller = makeController { method, _, _ in
                if method == "thread/read" {
                    return Self.response(active: true)
                }
                XCTAssertEqual(method, "thread/turns/list")
                var turn: [String: Any] = [
                    "id": variant == "wrong-turn" ? "other-active" : "active-probe",
                    "status": variant == "terminal-turn" ? "completed" : "inProgress",
                    "itemsView": "full",
                    "items": [["id": "call_probe", "type": "commandExecution", "status": "inProgress", "processId": "123"]]
                ]
                switch variant {
                case "summary", "notLoaded": turn["itemsView"] = variant
                case "missing-view": turn["itemsView"] = nil
                case "missing-items": turn["items"] = nil
                case "malformed-item": turn["items"] = [["type": "commandExecution", "processId": "123"]]
                default: break
                }
                let turns = variant == "multiple-turns" ? [turn, ["id": "other-active", "status": "inProgress", "itemsView": "full", "items": []]] : [turn]
                return Self.page(turns: turns)
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            controller.test_installThreadState(threadID: "thread-fixture")
            let snapshot = try await controller.readNativeToolProbeSnapshot(expectedTurnID: "active-probe", timeout: 2)
            XCTAssertFalse(snapshot.hasAuthoritativeActiveTurnItems, variant)
        }
    }

    func testNativeToolProbeKeepsIdleThreadsMetadataOnlyAndOlderRuntimeRichRead() async throws {
        for bounded in [false, true] {
            let controller = makeController { method, params, _ in
                switch method {
                case "thread/read":
                    XCTAssertEqual(params?["includeTurns"] as? Bool, !bounded)
                    return Self.response()
                case "thread/turns/list":
                    XCTAssertTrue(bounded)
                    XCTAssertEqual(params?["itemsView"] as? String, "notLoaded")
                    XCTAssertEqual(params?["limit"] as? Int, 32)
                    return Self.page(turns: [["id": "latest-completed", "status": "completed", "itemsView": "notLoaded"]])
                default:
                    XCTFail("Unexpected history hydration: \(method)")
                    throw CodexAppServerClient.ClientError.invalidResponse
                }
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: bounded ? 164 : 149, patch: 0))
            controller.test_installThreadState(threadID: "thread-fixture")
            let snapshot = try await controller.readNativeToolProbeSnapshot(expectedTurnID: "prior-active", timeout: 2)
            XCTAssertFalse(snapshot.hasAuthoritativeActiveTurnItems)
            XCTAssertFalse(snapshot.hasActiveTurn)
        }
    }

    func testLifecycleAuthoritativeInterruptDoesNotNeedHistoryUniquenessProbe() async throws {
        let controller = makeController { method, params, _ in
            XCTAssertEqual(method, "turn/interrupt", "Lifecycle authority bypasses bounded snapshot ambiguity")
            XCTAssertEqual(params?["threadId"] as? String, "thread-fixture")
            XCTAssertEqual(params?["turnId"] as? String, "lifecycle-active")
            return [:]
        }
        controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
        controller.test_installThreadState(threadID: "thread-fixture", authoritativeTurnID: "lifecycle-active")
        let receipt = try await controller.reconcileAndInterruptCurrentTurn()
        XCTAssertEqual(receipt.interruptedTurnID, "lifecycle-active")
    }

    private func makeController(
        options: CodexNativeSessionController.Options? = nil,
        request: @escaping @Sendable (String, [String: Any]?, TimeInterval?) async throws -> [String: Any]
    ) -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(), runID: UUID(), tabID: UUID(), windowID: 1,
            workspacePaths: .uniform(NSTemporaryDirectory()), options: options, requestExecutor: request
        )
    }

    private static func response(page: [String: Any]? = nil, active: Bool = false, turns: [[String: Any]] = []) -> [String: Any] {
        var result: [String: Any] = ["thread": ["id": "thread-fixture", "status": ["type": active ? "active" : "idle"], "turns": turns]]
        result["initialTurnsPage"] = page
        return result
    }

    private static func page(turns: [[String: Any]] = [], nextCursor: String? = nil) -> [String: Any] {
        ["data": turns, "nextCursor": nextCursor.map { $0 as Any } ?? NSNull()]
    }
}
