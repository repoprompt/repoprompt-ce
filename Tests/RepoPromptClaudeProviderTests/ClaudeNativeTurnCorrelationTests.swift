import Darwin
import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptClaudeProvider
import RepoPromptDomainRuntime
import XCTest

private struct OwnerResolver: ClaudeCodeLaunchEnvironmentResolving {
    func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCompatiblePluginLaunchEnvironment {
        ClaudeCompatiblePluginLaunchEnvironment(effectiveModel: requestedModel, environmentOverrides: [:], backendID: nil)
    }
}

private struct OwnerHost: ClaudeNativeSessionHosting {
    var routeWitness = false

    func repoPromptPermissionMatch(toolName _: String, requestPayload _: [String: Any]) -> ClaudeNativePermissionMatch? {
        nil
    }

    func filterEnvironment(_ environment: [String: String], variant _: ClaudeCodeRuntimeVariant) async -> [String: String] {
        environment
    }

    func mergeCurrentCarrier(into environment: [String: String]) -> [String: String] {
        environment
    }

    func processEnvironmentOverrides(for _: AgentCLIToolContext) -> [String: String] {
        routeWitness ? ["OWNER_ROUTE_WITNESS": "host"] : [:]
    }

    func hasModelSpecifier(_ model: String?) -> Bool {
        model != nil
    }

    func explicitEffortLevel(for _: String?) -> ClaudeCodeEffortLevel? {
        routeWitness ? .high : nil
    }

    func isDefaultModel(_ model: String) -> Bool {
        routeWitness && model == "host-default"
    }

    func shouldSuppressAbortArtifact(_ message: String) -> Bool {
        routeWitness && message == "host-abort"
    }

    func validateReadSourceFD(_ fd: Int32, label: String) throws {
        guard fcntl(fd, F_GETFL) >= 0 else { throw NSError(domain: label, code: Int(errno)) }
    }

    func supplementedPathHints(_ hints: [String]) -> [String] {
        hints
    }

    func expectedAgentClientName(for _: ClaudeCodeRuntimeVariant) -> String? {
        nil
    }

    func isRawEventFileLoggingEnabled() -> Bool {
        false
    }

    func makeRawEventLogFileURL(workspacePath _: String?, sessionID _: String) -> URL? {
        nil
    }

    func recordLastRawEventLogFileURL(_: URL) {}
    func isReasoningExtractionEnabled() -> Bool {
        false
    }

    func appendReasoningDebug(_: String) {}
    func isRepoPromptToolName(_: String) -> Bool {
        false
    }

    #if DEBUG
        func debugStatusLineArguments(launchArguments _: [String], isFirstParty _: Bool, providerArguments: [String]) -> [String] {
            providerArguments
        }
    #endif
    func isMCPServerRunning() async -> Bool {
        false
    }

    func prepareMCPLaunchConfig() async throws -> any ClaudeNativeConfigLease {
        throw NSError(domain: "owner fixture", code: 1)
    }

    func registerExpectedAgentPID(_: pid_t, clientName _: String, runID _: UUID) async {}
    func clearExpectedAgentPID(_: pid_t, clientName _: String, runID _: UUID) async {}
}

private func ownerConfig() -> ClaudeCodeAgentConfig {
    ClaudeCodeAgentConfig(
        commandName: "/usr/bin/false",
        additionalPathHints: [],
        modelString: nil,
        runtimeVariant: .standard,
        enableDebugLogging: false,
        sdkConnectTimeoutSeconds: 10,
        sdkRelaunchMaxAttempts: 1,
        permissionMode: "bypassPermissions",
        allowNativeBashTool: false,
        toolContext: .discoverRun,
        disallowedBuiltInTools: [],
        mcpStrictMode: true,
        toolSearchEnabled: false,
        effortLevel: nil
    )
}

final class ClaudeNativeTurnCorrelationTests: XCTestCase {
    func testInjectedHostRoutesLaunchAndModelPoliciesWithoutApp() async throws {
        let controller = ClaudeNativeProcessSessionController(
            host: OwnerHost(routeWitness: true), runID: UUID(), tabID: UUID(), windowID: 1,
            workspacePath: nil, config: ownerConfig(), environmentResolver: OwnerResolver()
        )
        let environment = await controller.test_effectiveLaunchEnvironment(base: [:])
        XCTAssertEqual(environment["OWNER_ROUTE_WITNESS"], "host")
        let defaultRequest = await controller.test_buildApplyFlagSettingsRequest(model: "host-default")
        XCTAssertNil(defaultRequest)
        let request = try await controller.test_resolveApplyFlagSettingsRequest(model: "owner-model")
        XCTAssertEqual((request?["settings"] as? [String: Any])?["effortLevel"] as? String, "high")
        let suppressed = await controller.shouldSuppressUserFacingStreamResult(AIStreamResult(type: "error", text: "host-abort"))
        XCTAssertTrue(suppressed)
        await controller.shutdown()
    }

    private func controller(fallback: TimeInterval = 1) async -> ClaudeNativeProcessSessionController {
        let controller = ClaudeNativeProcessSessionController(
            host: OwnerHost(),
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: ownerConfig(), environmentResolver: OwnerResolver(),
            authoritativeTurnIdleFallbackSeconds: fallback
        )
        await controller.test_installConfigurationTransport(write: { _ in })
        return controller
    }

    private let initFrame: [String: Any] = [
        "type": "system", "subtype": "init", "claude_code_version": "2.1.292",
        "capabilities": ["msg_lifecycle_v1"]
    ]

    private func feed(_ payload: [String: Any], to controller: ClaudeNativeProcessSessionController) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        await controller.test_receiveConfigurationResponseLine(data)
    }

    private func result(_ ids: [UUID]? = nil, text: String = "answer") -> [String: Any] {
        var frame: [String: Any] = ["type": "result", "subtype": "success", "num_turns": 0, "result": text]
        if let ids {
            frame["user_message_uuids"] = ids.map(\.uuidString)
            frame["user_message_uuid"] = ids.last?.uuidString
        }
        return frame
    }

    private func assistant(_ id: UUID? = nil, text: String = "") -> [String: Any] {
        var frame: [String: Any] = [
            "type": "assistant", "message": ["id": "synthetic-message", "role": "assistant", "content": [["type": "text", "text": text]]]
        ]
        if let id { frame["user_message_uuid"] = id.uuidString }
        return frame
    }

    private func completions(_ events: [ClaudeNativeProcessSessionController.Event]) -> [([UUID], ClaudeNativeProcessSessionController.TurnStatus)] {
        events.compactMap {
            switch $0 {
            case let .turnCompleted(id, status): ([id], status)
            case let .turnsCompleted(ids, status): (ids, status)
            default: nil
            }
        }
    }

    private func finish(_ controller: ClaudeNativeProcessSessionController) async -> [ClaudeNativeProcessSessionController.Event] {
        await controller.shutdown()
        var events: [ClaudeNativeProcessSessionController.Event] = []
        for await event in await controller.events {
            events.append(event)
        }
        return events
    }

    private func failureEvents(_ controller: ClaudeNativeProcessSessionController) async -> [ClaudeNativeProcessSessionController.Event] {
        let stream = await controller.events
        let finished = expectation(description: "Protocol failure closes its event stream")
        let reader = Task {
            var events: [ClaudeNativeProcessSessionController.Event] = []
            for await event in stream {
                events.append(event)
            }
            finished.fulfill()
            return events
        }
        await fulfillment(of: [finished], timeout: 2)
        await controller.shutdown()
        return await reader.value
    }

    func testFirstInputAndZeroTurnCommandsUseExactEchoWithoutAnEchoLatch() async throws {
        let controller = await controller()
        let first = try await controller.sendUserMessage("baseline")
        try await feed(initFrame, to: controller)
        try await feed(result([first]), to: controller)
        let cost = try await controller.sendUserMessage("/cost")
        let compact = try await controller.sendUserMessage("/compact")
        try await feed(result([compact]), to: controller)
        try await feed(result([cost]), to: controller)
        let pending = await controller.hasTurnInFlight
        XCTAssertFalse(pending)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[first], [compact], [cost]])
    }

    func testUnsolicitedResultCannotStealNewHostInputOrItsOutputAndApprovalsStillFlow() async throws {
        let controller = await controller()
        try await feed(initFrame, to: controller)
        try await feed(assistant(text: "unowned text"), to: controller)
        let host = try await controller.sendUserMessage("B")
        try await feed([
            "type": "control_request", "request_id": "approval-U",
            "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "echo synthetic"]]
        ], to: controller)
        await controller.test_receiveConfigurationResponseLine(Data("Unsolicited background work completed while another input waited for service.".utf8))
        try await feed(result(text: "unowned final"), to: controller)
        let pending = await controller.hasTurnInFlight
        XCTAssertTrue(pending)
        var subagent = assistant(host, text: "child answer")
        subagent["parent_tool_use_id"] = "synthetic-parent-tool"
        try await feed(subagent, to: controller)
        try await feed(assistant(text: "subagent ownership probe"), to: controller)
        try await feed(assistant(host, text: "owned text"), to: controller)
        try await feed(assistant(UUID(), text: "stale answer"), to: controller)
        try await feed(result([host], text: "owned final"), to: controller)
        try await feed(result([host], text: "duplicate"), to: controller)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[host]])
        let text = events.compactMap { event -> String? in
            if case let .stream(result) = event { return result.text }
            return nil
        }.joined()
        XCTAssertFalse(text.contains("unowned"))
        XCTAssertFalse(text.contains("duplicate"))
        XCTAssertFalse(text.contains("stale answer"))
        XCTAssertFalse(text.contains("child answer"))
        XCTAssertFalse(text.contains("subagent ownership probe"))
        XCTAssertFalse(text.contains("Unsolicited background"))
        XCTAssertTrue(text.contains("owned text"))
        XCTAssertTrue(events.contains { if case .approvalRequest = $0 { return true }
            return false
        })
    }

    private func streamEvent(_ event: [String: Any], inputID: UUID? = nil, parentKey: String? = nil) -> [String: Any] {
        var frame: [String: Any] = ["type": "stream_event", "event": event]
        if let inputID { frame["user_message_uuid"] = inputID.uuidString }
        if let parentKey { frame[parentKey] = "synthetic-parent-tool" }
        return frame
    }

    func testForeignMessageRejectionPersistsAcrossDeltasWithoutRetiringHostInput() async throws {
        let controller = await controller()
        try await feed(initFrame, to: controller)
        let retired = try await controller.sendUserMessage("previous input")
        try await feed(result([retired]), to: controller)
        let host = try await controller.sendUserMessage("host input")
        try await feed(assistant(host), to: controller)
        for foreign in [retired, UUID()] {
            try await feed(streamEvent([
                "type": "message_start", "message": ["id": host.uuidString, "role": "assistant"]
            ], inputID: host), to: controller)
            try await feed(streamEvent([
                "type": "content_block_delta", "delta": ["type": "text_delta", "text": "accepted host delta"]
            ]), to: controller)
            try await feed(streamEvent([
                "type": "message_start", "message": ["id": foreign.uuidString, "role": "assistant"]
            ], inputID: foreign), to: controller)
            try await feed(streamEvent([
                "type": "content_block_delta", "delta": ["type": "text_delta", "text": "rejected foreign text"]
            ]), to: controller)
            try await feed(streamEvent([
                "type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "rejected foreign reasoning"]
            ]), to: controller)
            try await feed(streamEvent(["type": "message_stop"]), to: controller)
            let pending = await controller.hasTurnInFlight
            XCTAssertTrue(pending, "Rejecting a message must not retire the host execution")
        }
        // A keyed result still settles A even while the latest message is rejected.
        try await feed(result([host], text: "host final"), to: controller)
        let pending = await controller.hasTurnInFlight
        XCTAssertFalse(pending)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[retired], [host]])
        let output = events.compactMap { event -> String? in
            guard case let .stream(value) = event, ["content", "final_content", "reasoning"].contains(value.type) else { return nil }
            return value.text ?? value.reasoning
        }
        XCTAssertFalse(output.joined().contains("rejected foreign"))
        XCTAssertEqual(output.count(where: { $0 == "accepted host delta" }), 2)
        XCTAssertTrue(output.joined().contains("host final"))
    }

    func testSubagentDeltasCannotBorrowOrReplaceMainThreadOutputOwnership() async throws {
        let controller = await controller()
        try await feed(initFrame, to: controller)
        let host = try await controller.sendUserMessage("host input")
        try await feed(streamEvent([
            "type": "message_start", "message": ["id": host.uuidString, "role": "assistant"]
        ], inputID: host), to: controller)
        for parentKey in ["parent_tool_use_id", "parentToolUseId"] {
            try await feed(streamEvent([
                "type": "message_start", "message": ["id": "child-message", "role": "assistant"]
            ], inputID: UUID(), parentKey: parentKey), to: controller)
            try await feed(streamEvent([
                "type": "content_block_delta", "delta": ["type": "text_delta", "text": "rejected child text"]
            ], parentKey: parentKey), to: controller)
            try await feed(streamEvent([
                "type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "rejected child reasoning"]
            ], parentKey: parentKey), to: controller)
            try await feed(streamEvent(["type": "message_stop"], parentKey: parentKey), to: controller)
            // The main stream resumes without a new message_start; child frames must
            // neither inherit its output owner nor overwrite it with their own.
            try await feed(streamEvent([
                "type": "content_block_delta", "delta": ["type": "text_delta", "text": "resumed host delta"]
            ]), to: controller)
        }
        let pending = await controller.hasTurnInFlight
        XCTAssertTrue(pending)
        try await feed(result([host]), to: controller)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[host]])
        let output = events.compactMap { event -> String? in
            guard case let .stream(value) = event, ["content", "final_content", "reasoning"].contains(value.type) else { return nil }
            return value.text ?? value.reasoning
        }
        XCTAssertFalse(output.joined().contains("rejected child"))
        XCTAssertEqual(output.count(where: { $0 == "resumed host delta" }), 2)
    }

    func testGroupedPickupAndForeignIDsDoNotConsumeOtherPendingInputs() async throws {
        let controller = await controller()
        try await feed(initFrame, to: controller)
        try await feed(assistant(), to: controller)
        let b = try await controller.sendUserMessage("B")
        let c = try await controller.sendUserMessage("C")
        let d = try await controller.sendUserMessage("D")
        try await feed(result([UUID()]), to: controller)
        var grouped = result([b, c])
        grouped["origin"] = ["type": "task-notification"]
        try await feed(grouped, to: controller)
        let pending = await controller.hasTurnInFlight
        XCTAssertTrue(pending)
        try await feed(result([d]), to: controller)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[b, c], [d]])
    }

    func testResolvedDeferredTargetsSurviveNewSendAndEOFDrainsOnlyUnresolved() async throws {
        let controller = await controller()
        try await feed(initFrame, to: controller)
        try await feed(["type": "system", "subtype": "session_state_changed", "state": "busy"], to: controller)
        let a = try await controller.sendUserMessage("A")
        let b = try await controller.sendUserMessage("B")
        try await feed(result([b]), to: controller)
        await controller.test_handleStdoutEOF()
        await controller.test_handleStdoutEOF()
        let events = await finish(controller)
        let completed = completions(events)
        XCTAssertEqual(completed.map(\.0), [[b], [a]])
        guard completed.count == 2 else { return }
        if case .completed = completed[0].1 {} else { XCTFail("Preserve resolved status") }
        if case .failed = completed[1].1 {} else { XCTFail("Fail only unresolved A") }
    }

    func testIdleAndFallbackUseResolvedTargetsRatherThanLaterSend() async throws {
        for useIdle in [true, false] {
            let controller = await controller(fallback: useIdle ? 10 : 0.01)
            let stream = await controller.events
            let completed = expectation(description: "Resolved A completes via idle or fallback")
            let a = try await controller.sendUserMessage("A")
            let b = try await controller.sendUserMessage("B")
            let reader = Task {
                var events: [ClaudeNativeProcessSessionController.Event] = []
                for await event in stream {
                    events.append(event)
                    if case let .turnsCompleted(ids, _) = event, ids == [b] { completed.fulfill() }
                }
                return events
            }
            try await feed(initFrame, to: controller)
            try await feed(["type": "system", "subtype": "session_state_changed", "state": "busy"], to: controller)
            try await feed(result([b]), to: controller)
            try await feed(result(), to: controller) // U's result cannot steal A or alter B's resolved status.
            if useIdle {
                try await feed(["type": "system", "subtype": "session_state_changed", "state": "idle"], to: controller)
            }
            await fulfillment(of: [completed], timeout: 2)
            let pending = await controller.hasTurnInFlight
            XCTAssertTrue(pending, "B's completion must leave A pending")
            try await feed(result([a]), to: controller)
            await controller.test_handleStdoutEOF()
            let events = await reader.value
            XCTAssertEqual(completions(events).map(\.0), [[b], [a]])
            await controller.shutdown()
        }
    }

    func testUnsupportedVersionRetainsLegacySettlement() async throws {
        let controller = await controller()
        var old = initFrame
        old["claude_code_version"] = "2.1.291"
        try await feed(old, to: controller)
        let host = try await controller.sendUserMessage("B")
        try await feed(result(), to: controller)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[host]])
    }

    func testMalformedGroupsFailAtomicallyAndInterruptBindingCannotMoveToLaterInput() throws {
        let a = UUID(), b = UUID()
        var state = ClaudeNativeTurnCorrelation()
        state.observeInit(initFrame)
        state.register(a)
        try state.observeActivity(assistant(a))
        let target = state.beginInterrupt()
        state.register(b)
        let resolved = try state.resolve(result([a]))
        XCTAssertTrue(resolved.interrupted, "Result-before-ACK is cancelled at the captured target")
        XCTAssertFalse(state.isInterruptPending(target), "A later ACK/failure is safe even with B outstanding")
        state.abandonInterrupt(target) // A late failure/timeout cannot modify B; success needs no mutation.
        XCTAssertFalse(try state.resolve(result([b])).interrupted)

        state.register(a)
        try state.observeActivity(assistant(a))
        let failedTarget = state.beginInterrupt()
        state.abandonInterrupt(failedTarget) // failed/timed-out interrupt before result
        XCTAssertFalse(try state.resolve(result([a])).interrupted)
        state.register(b)
        for malformed: [String: Any] in [
            ["user_message_uuids": [b.uuidString, "invalid"]],
            ["user_message_uuids": Array(repeating: b.uuidString, count: 65)],
            ["user_message_uuids": [b.uuidString], "user_message_uuid": a.uuidString]
        ] {
            XCTAssertThrowsError(try state.resolve(malformed))
            XCTAssertTrue(state.hasOutstanding)
        }
        XCTAssertEqual(try state.resolve(result([b])).inputIDs, [b])
    }

    func testPreEvidenceInterruptDoesNotAssignQueuedInputToUnsolicitedExecution() throws {
        var state = ClaudeNativeTurnCorrelation()
        state.observeInit(initFrame)
        let b = UUID()
        state.register(b)
        let token = state.beginInterrupt()
        XCTAssertFalse(try state.observeActivity(assistant(text: "U")))
        XCTAssertFalse(state.ownsOutput)
        var interruptedResult = result()
        interruptedResult["is_error"] = true
        let completion = try state.resolve(interruptedResult)
        XCTAssertTrue(completion.inputIDs.isEmpty)
        XCTAssertTrue(completion.interrupted)
        XCTAssertFalse(state.isInterruptPending(token))
        XCTAssertEqual(try state.resolve(result([b])).inputIDs, [b])
        let c = UUID()
        state.register(c)
        let noEvidence = state.beginInterrupt()
        state.acknowledgeInterrupt(noEvidence)
        try state.observeActivity(assistant(c))
        XCTAssertFalse(try state.resolve(result([c])).interrupted, "A no-op ACK must not cancel a future execution")
    }

    func testSilentAbortDoesNotRetireQueuedHostInEitherACKOrdering() throws {
        for response in ["ack", "result-first", "timeout"] {
            var state = ClaudeNativeTurnCorrelation()
            state.observeInit(initFrame)
            let b = UUID()
            state.register(b)
            let token = state.beginInterrupt()
            if response == "ack" { state.acknowledgeInterrupt(token) }
            if response == "timeout" { state.abandonInterrupt(token) }
            var aborted = result()
            aborted["subtype"] = "error_during_execution"
            aborted["is_error"] = true
            XCTAssertTrue(try state.resolve(aborted).inputIDs.isEmpty)
            XCTAssertTrue(state.hasOutstanding)
            XCTAssertEqual(try state.resolve(result([b])).inputIDs, [b])
        }
    }

    func testProtocolFailureFencesFollowingSuccessInSameRecoveredBurst() async throws {
        let controller = await controller()
        try await feed(initFrame, to: controller)
        let b = try await controller.sendUserMessage("B")
        var malformed = result([b])
        malformed["user_message_uuids"] = [b.uuidString, "invalid"]
        var burst = try JSONSerialization.data(withJSONObject: malformed)
        try burst.append(JSONSerialization.data(withJSONObject: result([b], text: "must not appear")))
        await controller.test_receiveConfigurationResponseLine(burst)
        let events = await failureEvents(controller)
        let answers = completions(events)
        XCTAssertEqual(answers.map(\.0), [[b]])
        guard let answer = answers.first else { return }
        if case .failed = answer.1 {} else { XCTFail("Protocol failure cannot later become success") }
        XCTAssertFalse(events.contains { if case let .stream(value) = $0 { return value.text == "must not appear" }
            return false
        })
    }

    func testMissingAnswerIdentityFailsKnownCommandAndSessionErrorWithoutHanging() async throws {
        for knownCommand in [true, false] {
            let controller = await controller()
            try await feed(initFrame, to: controller)
            let b = try await controller.sendUserMessage("synthetic input")
            if knownCommand {
                try await feed(["type": "command_lifecycle", "state": "started", "command_uuid": b.uuidString], to: controller)
            }
            var missing = result()
            missing["is_error"] = !knownCommand
            try await feed(missing, to: controller)
            let events = await failureEvents(controller)
            XCTAssertEqual(completions(events).map(\.0), [[b]])
            if case .failed = completions(events).first?.1 {} else { XCTFail("Missing answer identity is finite protocol failure") }
        }
    }

    func testAbsentIdentityFormsAndTransportResetDoNotCreateAHostOwner() async throws {
        for payload: [String: Any] in [
            ["user_message_uuid": NSNull()], ["user_message_uuids": NSNull()], ["user_message_uuids": []]
        ] {
            XCTAssertNil(try ClaudeNativeTurnCorrelation.inputIDs(payload))
        }
        let controller = await controller()
        try await feed(initFrame, to: controller)
        _ = await finish(controller)
        await controller.test_installConfigurationTransport(write: { _ in })
        await controller.ensureEventsStreamReady()
        var prooflessInit = initFrame
        prooflessInit.removeValue(forKey: "capabilities")
        try await feed(prooflessInit, to: controller)
        let b = try await controller.sendUserMessage("resumed input")
        try await feed(result(), to: controller)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[b]], "A new transport without capability proof stays legacy")
    }

    private actor InterruptGate {
        private let entered: XCTestExpectation
        private var response: CheckedContinuation<[String: Any], Error>?
        private var releasedFailure: Bool?
        private(set) var didEnter = false

        init(entered: XCTestExpectation) {
            self.entered = entered
        }

        func request() async throws -> [String: Any] {
            didEnter = true
            entered.fulfill()
            // Cleanup can release the gate before a delayed request reaches it.
            if let failed = releasedFailure {
                if failed {
                    throw ClaudeNativeProcessSessionController.ControllerError.controlRequestTimedOut(requestID: "test-interrupt")
                }
                return [:]
            }
            return try await withCheckedThrowingContinuation { continuation in
                response = continuation
            }
        }

        func release(failed: Bool = false) {
            releasedFailure = failed
            if failed {
                response?.resume(throwing: ClaudeNativeProcessSessionController.ControllerError.controlRequestTimedOut(requestID: "test-interrupt"))
            } else { response?.resume(returning: [:]) }
            response = nil
        }
    }

    func testControllerInterruptGlueBindsResultAcrossACKAndEOFOrderings() async throws {
        // Two ACK orderings, timeout after settlement, and EOF while ACK is held.
        for ordering in ["result-before-ack", "ack-before-result", "timeout-after-result", "eof"] {
            let controller = await controller()
            try await feed(initFrame, to: controller)
            let a = try await controller.sendUserMessage("A")
            try await feed(assistant(a), to: controller)
            let b = try await controller.sendUserMessage("B")
            let entered = expectation(description: "Interrupt request enters gate: \(ordering)")
            let gate = InterruptGate(entered: entered)
            await controller.test_setConfigurationControlRequest { _ in try await gate.request() }
            let interrupt = Task { await controller.test_interruptRunningTurn(reason: "synthetic steer") }
            await fulfillment(of: [entered], timeout: 2)
            guard await gate.didEnter else {
                await gate.release(failed: true)
                await controller.shutdown()
                interrupt.cancel()
                _ = await interrupt.value
                continue
            }
            if ordering == "ack-before-result" {
                await gate.release()
                let outcome = await interrupt.value
                XCTAssertEqual(outcome, .acknowledged)
                try await feed(result([a]), to: controller)
            } else {
                if ordering == "eof" { await controller.test_handleStdoutEOF() }
                else { try await feed(result([a]), to: controller) }
                await gate.release(failed: ordering == "timeout-after-result")
                let outcome = await interrupt.value
                XCTAssertEqual(outcome, ordering == "eof" ? .failed : .noTurnInFlight)
            }
            if ordering != "eof" { try await feed(result([b]), to: controller) }
            let events = await finish(controller)
            let answers = completions(events)
            XCTAssertEqual(answers.map(\.0), [[a], [b]], ordering)
            guard answers.count == 2 else { continue }
            if ordering != "eof" {
                if case .cancelled = answers[0].1 {} else { XCTFail("Target A must be cancelled") }
                if case .completed = answers[1].1 {} else { XCTFail("B must not inherit A's interrupt") }
            }
        }
    }

    func testUnownedStampedResultRetiresInterruptWithoutCancellingQueuedHostInputs() async throws {
        for ackFirst in [true, false] {
            for grouped in [false, true] {
                let controller = await controller()
                try await feed(initFrame, to: controller)
                let unowned = UUID()
                try await feed(assistant(), to: controller)
                try await feed(assistant(unowned, text: "unowned activity"), to: controller)
                let b = try await controller.sendUserMessage("B")
                var hostIDs = [b]
                if grouped { try await hostIDs.append(controller.sendUserMessage("C")) }
                let entered = expectation(description: "Interrupt unowned execution: ackFirst=\(ackFirst), grouped=\(grouped)")
                let gate = InterruptGate(entered: entered)
                await controller.test_setConfigurationControlRequest { _ in try await gate.request() }
                let interrupt = Task { await controller.test_interruptRunningTurn(reason: "interrupt provider-owned work") }
                await fulfillment(of: [entered], timeout: 2)
                guard await gate.didEnter else {
                    await gate.release(failed: true)
                    await controller.shutdown()
                    interrupt.cancel()
                    _ = await interrupt.value
                    continue
                }
                if ackFirst {
                    await gate.release()
                    let outcome = await interrupt.value
                    XCTAssertEqual(outcome, .acknowledged)
                }
                try await feed(result([unowned], text: "unowned final"), to: controller)
                let queued = await controller.hasTurnInFlight
                XCTAssertTrue(queued, "U's result cannot settle B or C")
                for id in hostIDs {
                    try await feed(assistant(id), to: controller)
                }
                if !ackFirst {
                    // Even a new host pickup before the old ACK must not inherit U's interrupt.
                    await gate.release()
                    let outcome = await interrupt.value
                    XCTAssertEqual(outcome, .noTurnInFlight)
                }
                try await feed(result(hostIDs, text: "host final"), to: controller)
                try await feed(result([unowned], text: "late unowned final"), to: controller)
                try await feed(result(hostIDs, text: "duplicate host final"), to: controller)
                let pending = await controller.hasTurnInFlight
                XCTAssertFalse(pending)
                let events = await finish(controller)
                let answers = completions(events)
                XCTAssertEqual(answers.map(\.0), [hostIDs], "Only B or the B/C group completes, exactly once")
                if case .completed = answers.first?.1 {} else { XCTFail("Queued host work must not inherit U's cancellation") }
                let output = events.compactMap { event -> String? in
                    if case let .stream(value) = event { return value.text ?? value.reasoning }
                    return nil
                }.joined()
                XCTAssertFalse(output.contains("unowned"))
                XCTAssertFalse(output.contains("duplicate host final"))
                XCTAssertTrue(output.contains("host final"))
            }
        }
    }

    func testLateForeignResultCannotClearInterruptForExecutingHostInput() async throws {
        for ackFirst in [true, false] {
            let controller = await controller()
            try await feed(initFrame, to: controller)
            let retiredUnowned = UUID()
            try await feed(assistant(), to: controller)
            try await feed(assistant(retiredUnowned), to: controller)
            try await feed(result([retiredUnowned]), to: controller)
            let a = try await controller.sendUserMessage("A")
            try await feed(assistant(a), to: controller)
            let b = try await controller.sendUserMessage("B")
            let entered = expectation(description: "Interrupt host A: ackFirst=\(ackFirst)")
            let gate = InterruptGate(entered: entered)
            await controller.test_setConfigurationControlRequest { _ in try await gate.request() }
            let interrupt = Task { await controller.test_interruptRunningTurn(reason: "interrupt host A") }
            await fulfillment(of: [entered], timeout: 2)
            guard await gate.didEnter else {
                await gate.release(failed: true)
                await controller.shutdown()
                interrupt.cancel()
                _ = await interrupt.value
                continue
            }
            if ackFirst {
                await gate.release()
                let outcome = await interrupt.value
                XCTAssertEqual(outcome, .acknowledged)
            }
            // Even foreign activity cannot reidentify an already host-owned execution.
            try await feed(assistant(retiredUnowned), to: controller)
            try await feed(result([retiredUnowned]), to: controller)
            try await feed(result([UUID()]), to: controller)
            try await feed(result([a]), to: controller)
            if !ackFirst {
                await gate.release()
                let outcome = await interrupt.value
                XCTAssertEqual(outcome, .noTurnInFlight)
            }
            try await feed(assistant(b), to: controller)
            try await feed(result([b]), to: controller)
            let events = await finish(controller)
            let answers = completions(events)
            XCTAssertEqual(answers.map(\.0), [[a], [b]])
            guard answers.count == 2 else { continue }
            if case .cancelled = answers[0].1 {} else { XCTFail("Late foreign results cannot clear A's interrupt") }
            if case .completed = answers[1].1 {} else { XCTFail("B must not inherit A's interrupt") }
        }
    }
}
