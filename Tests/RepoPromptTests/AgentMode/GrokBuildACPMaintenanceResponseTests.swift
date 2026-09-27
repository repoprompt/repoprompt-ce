import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Drives the real ACP controller against a synthetic Grok transport. An unsupported request
/// fences maintenance processing; a separate pipe withholds the owned response until the test
/// has observed both its pending identity and the event consumer's reasoning checkpoint.
final class GrokBuildACPMaintenanceResponseTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
        super.tearDown()
    }

    func testMaintenanceReplyDuringPromptLeavesTurnIntact() async throws {
        let cases: [(label: String, frames: [String], maintenanceID: String)] = [
            ("skills", [MaintenanceFrame.skills], "skills-reload"),
            ("workflows", [MaintenanceFrame.workflows], "workflows-reload"),
            (
                "repeated",
                [MaintenanceFrame.skills, MaintenanceFrame.workflows, MaintenanceFrame.skills, MaintenanceFrame.workflows],
                "skills-reload"
            ),
            ("outer-error", [MaintenanceFrame.outerError], "skills-reload"),
            ("opaque", [MaintenanceFrame.opaque], "workflows-reload")
        ]
        for testCase in cases {
            try await assertPromptTurnSurvives(
                label: testCase.label,
                frames: testCase.frames,
                maintenanceID: testCase.maintenanceID
            )
        }
    }

    func testMaintenanceReplyDuringBootstrapDoesNotFailSessionOpen() async throws {
        let label = "bootstrap"
        let harness = try makeHarness(label: label, phase: .bootstrap, frames: [MaintenanceFrame.skills])
        let controller = try harness.makeController()
        let events = await controller.currentEventsStream()
        do {
            let bootstrap = try await withHangBound(controller) { try await controller.bootstrap() }
            XCTAssertEqual(bootstrap.sessionID, "grok-maintenance-session", "\(label): unexpected session")
        } catch {
            XCTFail("\(label): session open failed: \(error.localizedDescription)")
            XCTAssertTrue(
                Self.isUnmatchedResponseFailure(error, id: "skills-reload"),
                "\(label): failed for a reason other than the unmatched skills-reload reply: \(error)"
            )
            await controller.shutdown()
            return
        }
        var promptError: (any Error)?
        do {
            try await withHangBound(controller) {
                try await controller.prompt(AgentMessage(userMessage: "after bootstrap"), request: harness.request)
            }
        } catch {
            promptError = error
        }
        await controller.shutdown()
        XCTAssertNil(promptError, "\(label): prompt after session open failed: \(String(describing: promptError))")
        let drained = await drain(events)
        assertCompletedTurn(drained, content: ["second"], label: "\(label) prompt")
    }

    func testMaintenanceReplyWhileIdlePreservesSessionReuse() async throws {
        let frames = [MaintenanceFrame.skills, MaintenanceFrame.workflowsError]
        let harness = try makeHarness(label: "idle-reuse", phase: .idle, frames: frames)
        defer { harness.gate.release() }
        let diagnostics = MaintenanceDiagnostics()
        let controller = try harness.makeController(diagnosticSink: { diagnostics.record($0) })
        let stream = await controller.currentEventsStream()
        let observation = TurnObservation()
        let consumer = Task {
            for await event in stream {
                await observation.append(event)
            }
            await observation.finishStream()
        }
        do {
            let bootstrap = try await withHangBound(controller) { try await controller.bootstrap() }
            try await withHangBound(controller) {
                try await controller.prompt(AgentMessage(userMessage: "first"), request: harness.request)
            }
            try await AsyncTestWait.waitUntil("first terminal consumed before idle injection", timeout: 30) {
                await observation.terminalOrStreamFinished
            }
            let completed = await observation.events
            assertCompletedTurn(completed, content: ["first"], label: "idle turn 1")
            guard let terminalIndex = completed.firstIndex(where: {
                if case .terminal = $0 { return true }
                return false
            }), let ownedID = harness.recordedMessages().first(where: {
                $0["method"] as? String == "session/prompt"
            })?["id"] as? Int else {
                throw CheckpointFailure("first turn did not complete before idle injection")
            }
            let snapshot = await controller.debugPendingRequestSnapshot(requestID: ownedID)
            XCTAssertNil(snapshot.method, "completed prompt remained pending")
            XCTAssertFalse(snapshot.promptRunning, "maintenance must be injected while idle")
            XCTAssertTrue(snapshot.didEmitTerminal)

            // An out-of-band command, not another session/prompt, triggers the idle frames.
            harness.gate.release()
            try await AsyncTestWait.waitUntil("idle barrier and consumer checkpoint", timeout: 30) {
                await observation.canStopWaiting
            }
            guard await observation.sawCheckpoint else {
                throw CheckpointFailure("stream ended before the idle barrier's consumer checkpoint")
            }
            try requireBarrierReply(harness)
            XCTAssertEqual(harness.recordedMethods().count(where: { $0 == "session/prompt" }), 1)
            let fencedEvents = await observation.events
            XCTAssertFalse(
                fencedEvents.dropFirst(terminalIndex + 1).contains { Self.streamType(of: $0) == "error" },
                "idle maintenance emitted an error after the completed terminal"
            )
            XCTAssertEqual(Self.terminals(in: fencedEvents), [.completed])
            XCTAssertEqual(fencedEvents.count(where: { Self.streamType(of: $0) == "message_stop" }), 1)
            XCTAssertEqual(diagnostics.unmatchedIDs, [], "idle maintenance reached the protocol-violation fallback")

            let reusable = await controller.prepareForNextTurn()
            XCTAssertTrue(reusable, "idle maintenance poisoned controller reuse after a completed turn")
            guard reusable else {
                print("IDLE_REUSE_FAILURE: completed controller became non-reusable after idle maintenance")
                await controller.shutdown()
                await consumer.value
                return
            }
            await consumer.value
            let turnTwo = await controller.currentEventsStream()
            try await withHangBound(controller) {
                try await controller.prompt(AgentMessage(userMessage: "second"), request: harness.request)
            }
            let messages = harness.recordedMessages()
            let methods = messages.compactMap { $0["method"] as? String }
            let prompts = messages.filter { $0["method"] as? String == "session/prompt" }
            XCTAssertEqual(prompts.count, 2, "one prompt per turn, with no replay")
            XCTAssertEqual(Set(prompts.compactMap { $0["id"] as? Int }).count, 2)
            XCTAssertEqual(
                prompts.compactMap { ($0["params"] as? [String: Any])?["sessionId"] as? String },
                [bootstrap.sessionID, bootstrap.sessionID]
            )
            XCTAssertEqual(Set(messages.compactMap { $0["fixturePID"] as? Int }).count, 1, "transport process changed")
            XCTAssertEqual(methods.count(where: { $0 == "initialize" }), 1)
            XCTAssertEqual(methods.count(where: { $0 == "session/new" }), 1)
            XCTAssertFalse(methods.contains("session/load"), "session was re-bootstrapped")
            XCTAssertFalse(methods.contains("session/cancel"), "cancelled before teardown")
            assertRecognitionDiagnostics(diagnostics, frames: frames, label: "idle")
            await controller.shutdown()
            await assertCompletedTurn(drain(turnTwo), content: ["second"], label: "idle turn 2")
            print("IDLE_REUSE_CHECKPOINT: same controller, process and session completed both turns")
        } catch {
            await controller.shutdown()
            await consumer.value
            XCTFail("idle reuse scenario failed: \(error.localizedDescription)")
        }
    }

    /// Proves the fixture: the same gated sequence without a maintenance reply completes both turns.
    func testNoMaintenanceControlCompletesTurn() async throws {
        try await assertPromptTurnSurvives(label: "no-maintenance", frames: [], maintenanceID: nil)
    }

    /// Other unmatched replies retain the fatal fallback, rather than tolerating arbitrary IDs.
    func testUnknownStringIDStillProtocolViolation() async throws {
        try await assertProtocolViolation(label: "other-reload", frame: MaintenanceFrame.unknownID, id: "other-reload")
    }

    func testKnownMaintenanceIDStillRoutesAsServerRequest() async throws {
        for id in ["skills-reload", "workflows-reload"] {
            try await assertPromptTurnSurvives(label: "server-request-\(id)", frames: [], barrierID: id)
        }
    }

    func testIneligibleMaintenanceFramesKeepProtocolViolation() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let cases: [(String, String, ACPProviderID)] = [
            ("present-null-method", #"{"jsonrpc":"2.0","id":"skills-reload","method":null,"result":{}}"#, .grokBuild),
            ("both-result-and-error", #"{"jsonrpc":"2.0","id":"skills-reload","result":{},"error":{"code":-32603,"message":"reload failed"}}"#, .grokBuild),
            ("non-grok", MaintenanceFrame.skills, .cursor)
        ]
        for (label, frame, providerID) in cases {
            try await assertProtocolViolation(label: label, frame: frame, id: "skills-reload", providerID: providerID)
        }
    }

    func testWithheldPromptSettlesOnOwnerShutdown() async throws {
        try await assertPromptTurnSurvives(label: "shutdown-control", frames: [], shutdownWhileHeld: true)
        try await assertPromptTurnSurvives(
            label: "shutdown-maintenance",
            frames: [MaintenanceFrame.skills],
            maintenanceID: "skills-reload",
            shutdownWhileHeld: true
        )
    }

    func testMaintenanceRecognitionRequiresValidKnownResponseEnvelope() throws {
        let rows: [(label: String, frame: String, recognized: Bool)] = [
            ("skills-object", MaintenanceFrame.skills, true),
            ("workflows-object", MaintenanceFrame.workflows, true),
            ("opaque-result", MaintenanceFrame.opaque, true),
            ("array-result", #"{"jsonrpc":"2.0","id":"skills-reload","result":[1,null]}"#, true),
            ("string-result", #"{"jsonrpc":"2.0","id":"skills-reload","result":"opaque"}"#, true),
            ("number-result", #"{"jsonrpc":"2.0","id":"skills-reload","result":7}"#, true),
            ("boolean-result", #"{"jsonrpc":"2.0","id":"skills-reload","result":false}"#, true),
            ("null-result", #"{"jsonrpc":"2.0","id":"skills-reload","result":null}"#, true),
            ("outer-error", MaintenanceFrame.outerError, true),
            ("opaque-error-data", #"{"jsonrpc":"2.0","id":"workflows-reload","error":{"code":-32603,"message":"reload failed","data":[null,{"skills":false}]}}"#, true),
            ("integral-decimal-code", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":-32603.0,"message":""}}"#, true),
            ("integral-exponent-code", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":-3.2603e4,"message":"error"}}"#, true),
            ("unknown-id", MaintenanceFrame.unknownID, false),
            ("case-id", #"{"jsonrpc":"2.0","id":"Skills-reload","result":{}}"#, false),
            ("suffix-id", #"{"jsonrpc":"2.0","id":"skills-reload-1","result":{}}"#, false),
            ("substring-id", #"{"jsonrpc":"2.0","id":"prefix-workflows-reload","result":{}}"#, false),
            ("numeric-id", #"{"jsonrpc":"2.0","id":3,"result":{}}"#, false),
            ("null-id", #"{"jsonrpc":"2.0","id":null,"result":{}}"#, false),
            ("missing-id", #"{"jsonrpc":"2.0","result":{}}"#, false),
            ("missing-version", #"{"id":"skills-reload","result":{}}"#, false),
            ("wrong-version", #"{"jsonrpc":"1.0","id":"skills-reload","result":{}}"#, false),
            ("numeric-version", #"{"jsonrpc":2.0,"id":"skills-reload","result":{}}"#, false),
            ("both", #"{"jsonrpc":"2.0","id":"skills-reload","result":null,"error":{"code":-32603,"message":"error"}}"#, false),
            ("neither", #"{"jsonrpc":"2.0","id":"skills-reload"}"#, false),
            ("string-method", #"{"jsonrpc":"2.0","id":"skills-reload","method":"unknown","result":{}}"#, false),
            ("null-method", #"{"jsonrpc":"2.0","id":"skills-reload","method":null,"result":{}}"#, false),
            ("numeric-method", #"{"jsonrpc":"2.0","id":"skills-reload","method":7,"result":{}}"#, false),
            ("null-error", #"{"jsonrpc":"2.0","id":"skills-reload","error":null}"#, false),
            ("array-error", #"{"jsonrpc":"2.0","id":"skills-reload","error":[]}"#, false),
            ("missing-code", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"message":"error"}}"#, false),
            ("null-code", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":null,"message":"error"}}"#, false),
            ("boolean-code", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":true,"message":"error"}}"#, false),
            ("false-code", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":false,"message":"error"}}"#, false),
            ("string-code", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":"-32603","message":"error"}}"#, false),
            ("fractional-code", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":-32603.5,"message":"error"}}"#, false),
            ("precise-fractional-code", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":-32603.000000000000001,"message":"error"}}"#, false),
            ("missing-message", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":-32603}}"#, false),
            ("null-message", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":-32603,"message":null}}"#, false),
            ("numeric-message", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":-32603,"message":42}}"#, false)
        ]
        let providers: [(label: String, provider: any ACPAgentProvider, optedIn: Bool)] = [
            ("grok", GrokBuildACPAgentProvider(config: GrokBuildAgentConfig()), true),
            ("id-only-test-provider", IDRecognizingProvider(), true),
            ("default-off", NonOptedInProvider(commandPath: "unused"), false),
            ("grok-identity-without-override", NonOptedInProvider(providerID: .grokBuild, commandPath: "unused"), false)
        ]
        for row in rows {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(row.frame.utf8)) as? [String: Any])
            for entry in providers {
                XCTAssertEqual(
                    ACPAgentSessionController.isRecognizedUnmatchedResponse(json, provider: entry.provider),
                    row.recognized && entry.optedIn,
                    "\(entry.label): \(row.label)"
                )
            }
        }
    }

    // MARK: - Scenario

    private static let checkpointMarker = "maintenance-owned-reply-held"
    private static let toolOutput = "maintenance-tool-output"

    private func assertPromptTurnSurvives(
        label: String,
        frames: [String],
        maintenanceID: String? = nil,
        barrierID: String = "barrier-1",
        shutdownWhileHeld: Bool = false
    ) async throws {
        let harness = try makeHarness(label: label, phase: .prompt, frames: frames, barrierID: barrierID)
        defer { harness.gate.release() }
        let diagnostics = MaintenanceDiagnostics()
        let controller = try harness.makeController(diagnosticSink: { diagnostics.record($0) })
        let stream = await controller.currentEventsStream()
        do {
            _ = try await withHangBound(controller) { try await controller.bootstrap() }
        } catch {
            XCTFail("\(label): bootstrap failed before the prompt: \(error.localizedDescription)")
            await controller.shutdown()
            return
        }

        let observation = TurnObservation()
        let consumer = Task {
            for await event in stream {
                await observation.append(event)
            }
            await observation.finishStream()
        }
        let prompt = Task { () -> Result<Void, Error> in
            let result: Result<Void, Error>
            do {
                try await controller.prompt(AgentMessage(userMessage: "first"), request: harness.request)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await observation.finishPrompt(result)
            return result
        }

        do {
            let ownedID = try await heldReplyCheckpoint(harness: harness, controller: controller, observation: observation)
            print("OWNERSHIP_CHECKPOINT \(label): original request \(ownedID) still pending")
            assertRecognitionDiagnostics(diagnostics, frames: frames, label: label)
            if shutdownWhileHeld {
                // Deliberately do not release the response. Shutdown, not a provider reply,
                // must settle the original pending continuation.
                await controller.shutdown()
                let result = await prompt.value
                switch result {
                case .success:
                    XCTFail("\(label): shutdown fabricated prompt success")
                case let .failure(error):
                    XCTAssertEqual(error.localizedDescription, "ACP transport closed unexpectedly.", label)
                }
                await consumer.value
                let after = await controller.debugPendingRequestSnapshot(requestID: ownedID)
                XCTAssertNil(after.method, "\(label): shutdown left the original request pending")
                XCTAssertFalse(after.promptRunning, label)
                let events = await observation.events
                XCTAssertFalse(Self.terminals(in: events).contains(.completed), label)
                XCTAssertFalse(events.contains { Self.streamType(of: $0) == "message_stop" }, label)
                print("OWNER_SHUTDOWN_OBSERVED \(label)")
                return
            }

            harness.gate.release()
            try await withHangBound(controller) { try await prompt.value.get() }
            let promptsAfterTurnOne = harness.recordedMethods().count(where: { $0 == "session/prompt" })
            let reusable = await controller.prepareForNextTurn()
            var turnTwoEvents: AsyncStream<NormalizedAgentRuntimeEvent>?
            var turnTwoError: (any Error)?
            if reusable {
                turnTwoEvents = await controller.currentEventsStream()
                do {
                    try await withHangBound(controller) {
                        try await controller.prompt(AgentMessage(userMessage: "second"), request: harness.request)
                    }
                } catch {
                    turnTwoError = error
                }
            }
            let methodsBeforeShutdown = harness.recordedMethods()
            await controller.shutdown()
            await consumer.value

            let turnOne = await observation.events
            assertCompletedTurn(turnOne, content: ["prefix", "suffix"], label: "\(label) turn 1")
            let tools = turnOne.compactMap { event -> String? in
                guard case let .stream(result) = event, result.type == "tool_result" else { return nil }
                return result.toolResultJSON
            }
            XCTAssertEqual(tools.count, 1, "\(label): expected exactly one retained tool result")
            XCTAssertTrue(tools.first?.contains(Self.toolOutput) == true, "\(label): tool output was lost")
            XCTAssertEqual(promptsAfterTurnOne, 1, "\(label): original prompt was not sent exactly once")
            XCTAssertTrue(reusable, "\(label): controller was not reusable")
            XCTAssertNil(turnTwoError, "\(label): second turn failed: \(String(describing: turnTwoError))")
            if let turnTwoEvents {
                await assertCompletedTurn(drain(turnTwoEvents), content: ["second"], label: "\(label) turn 2")
            }
            XCTAssertEqual(methodsBeforeShutdown.count(where: { $0 == "session/prompt" }), 2, label)
            XCTAssertFalse(methodsBeforeShutdown.contains("session/cancel"), "\(label): cancelled before teardown")
        } catch {
            await controller.shutdown()
            let promptResult = await prompt.value
            await consumer.value
            if let maintenanceID,
               case let .failure(productError) = promptResult,
               Self.isUnmatchedResponseFailure(productError, id: maintenanceID)
            {
                // Expected red-path classification only; this never turns the failure into a pass.
                XCTFail("\(label): owned prompt failed: \(productError.localizedDescription); checkpoint: \(error.localizedDescription)")
                print("INTENDED_PRODUCT_FAILURE \(label): unmatched \(maintenanceID)")
            } else {
                XCTFail("\(label): held prompt scenario failed: \(error.localizedDescription)")
                print("CHECKPOINT_OR_FIXTURE_FAILURE \(label): \(error.localizedDescription)")
            }
        }
    }

    private func heldReplyCheckpoint(
        harness: Harness,
        controller: ACPAgentSessionController,
        observation: TurnObservation
    ) async throws -> Int {
        // A state-based wait, not a sleep oracle. Prompt failure or stream closure ends this
        // immediately even if the fake exits without creating its gate-entry marker.
        try await AsyncTestWait.waitUntil("held reply and consumer checkpoint", timeout: 30) {
            await observation.canStopWaiting
        }
        if let result = await observation.promptResult {
            try result.get()
            throw CheckpointFailure("owned prompt completed before its real response was released")
        }
        guard await observation.sawCheckpoint else {
            throw CheckpointFailure("event stream ended before the reasoning checkpoint")
        }
        guard FileManager.default.fileExists(atPath: harness.gate.path + ".entered") else {
            throw CheckpointFailure("reasoning checkpoint arrived without the held-response gate")
        }
        try requireBarrierReply(harness)
        let messages = harness.recordedMessages()
        guard let ownedID = messages.first(where: { $0["method"] as? String == "session/prompt" })?["id"] as? Int,
              let heldIDText = try? String(contentsOfFile: harness.gate.path + ".entered", encoding: .utf8),
              Int(heldIDText) == ownedID
        else {
            throw CheckpointFailure("fixture did not hold the original numeric prompt request ID")
        }
        let snapshot = await controller.debugPendingRequestSnapshot(requestID: ownedID)
        guard snapshot.method == "session/prompt", snapshot.promptRunning, !snapshot.didEmitTerminal else {
            throw CheckpointFailure("original request lost ownership while held: \(snapshot)")
        }
        let events = await observation.events
        guard Self.terminals(in: events).isEmpty,
              !events.contains(where: { Self.streamType(of: $0) == "message_stop" }),
              Self.content(in: events) == ["prefix"]
        else {
            throw CheckpointFailure("owned turn settled or emitted suffix before genuine reply release")
        }
        return ownedID
    }

    private func requireBarrierReply(_ harness: Harness) throws {
        let messages = harness.recordedMessages()
        let replies = messages.filter { $0["method"] == nil && $0["id"] as? String == harness.barrierID }
        guard replies.count == 1,
              let reply = replies.first,
              reply["jsonrpc"] as? String == "2.0",
              reply["result"] == nil,
              let error = reply["error"] as? [String: Any],
              error["code"] as? Int == -32601,
              error["message"] is String
        else {
            throw CheckpointFailure("barrier did not receive exactly one matching JSON-RPC method-not-found response")
        }
    }

    private func assertProtocolViolation(
        label: String,
        frame: String,
        id: String,
        providerID: ACPProviderID = .grokBuild
    ) async throws {
        let harness = try makeHarness(label: label, phase: .prompt, frames: [frame], providerID: providerID)
        defer { harness.gate.release() }
        let controller = try harness.makeController()
        let events = await controller.currentEventsStream()
        do {
            _ = try await withHangBound(controller) { try await controller.bootstrap() }
        } catch {
            XCTFail("\(label): bootstrap failed before the prompt: \(error.localizedDescription)")
            await controller.shutdown()
            return
        }
        var promptError: (any Error)?
        do {
            try await withHangBound(controller) {
                try await controller.prompt(AgentMessage(userMessage: "first"), request: harness.request)
            }
        } catch {
            promptError = error
        }
        await controller.shutdown()
        let drained = await drain(events)
        guard let promptError else {
            return XCTFail("\(label): ineligible response must still fail the original prompt")
        }
        XCTAssertTrue(Self.isUnmatchedResponseFailure(promptError, id: id), "\(label): \(promptError)")
        XCTAssertEqual(Self.content(in: drained).first, "prefix", "\(label): prompt never produced output")
        XCTAssertEqual(Self.terminals(in: drained), [.failed], "\(label): expected exactly one failed terminal")
        XCTAssertFalse(drained.contains { Self.streamType(of: $0) == "message_stop" }, label)
    }

    private struct CheckpointFailure: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }

    private actor TurnObservation {
        private(set) var events: [NormalizedAgentRuntimeEvent] = []
        private(set) var promptResult: Result<Void, Error>?
        private var streamFinished = false
        private(set) var sawCheckpoint = false

        var canStopWaiting: Bool {
            sawCheckpoint || promptResult != nil || streamFinished
        }

        var terminalOrStreamFinished: Bool {
            streamFinished || events.contains {
                if case .terminal = $0 { return true }
                return false
            }
        }

        func append(_ event: NormalizedAgentRuntimeEvent) {
            events.append(event)
            if case let .stream(result) = event,
               result.type == "reasoning",
               result.reasoning == GrokBuildACPMaintenanceResponseTests.checkpointMarker
            {
                sawCheckpoint = true
            }
        }

        func finishPrompt(_ result: Result<Void, Error>) {
            promptResult = result
        }

        func finishStream() {
            streamFinished = true
        }
    }

    /// Capture only the new event and unmatched IDs, not raw inbound diagnostics.
    private final class MaintenanceDiagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var recognized: [String] = []
        private var unmatched: [String] = []

        var recognitionInfo: [String] {
            lock.withLock { recognized }
        }

        var unmatchedIDs: [String] {
            lock.withLock { unmatched }
        }

        func record(_ event: ACPAgentSessionController.DiagnosticEvent) {
            lock.withLock {
                switch event {
                case let .info(message) where message.hasPrefix("Ignored provider-recognized unmatched ACP response "):
                    recognized.append(message)
                case let .unmatchedResponse(id, _):
                    unmatched.append(id)
                default:
                    break
                }
            }
        }
    }

    private func assertRecognitionDiagnostics(_ diagnostics: MaintenanceDiagnostics, frames: [String], label: String) {
        let expected = frames.compactMap { frame -> (String, String)? in
            guard let json = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                  let id = json["id"] as? String else { return nil }
            return (id, json.keys.contains("result") ? "result" : "error")
        }
        let messages = diagnostics.recognitionInfo
        XCTAssertEqual(messages.count, expected.count, "\(label): recognition diagnostic count")
        for (message, (id, kind)) in zip(messages, expected) {
            XCTAssertTrue(message.contains("provider=\(ACPProviderID.grokBuild.rawValue) id=\(id) kind=\(kind)."), label)
            for sentinel in ["PRIVATE_RESULT_SENTINEL", "PRIVATE_MESSAGE_SENTINEL", "PRIVATE_DATA_SENTINEL"] {
                XCTAssertFalse(message.contains(sentinel), "\(label): recognition event exposed \(sentinel)")
            }
        }
    }

    private func assertCompletedTurn(_ events: [NormalizedAgentRuntimeEvent], content expected: [String], label: String) {
        XCTAssertEqual(Self.content(in: events), expected, "\(label): owned output was lost or reordered")
        XCTAssertEqual(Self.terminals(in: events), [.completed], "\(label): expected exactly one completed terminal")
        let violations = events.compactMap { event -> String? in
            guard case let .stream(result) = event, let text = result.text, text.contains("unmatched ACP response id") else {
                return nil
            }
            return text
        }
        XCTAssertEqual(violations, [], "\(label): maintenance reply surfaced as a protocol violation")
        let stopIndex = events.firstIndex { Self.streamType(of: $0) == "message_stop" }
        let lastContentIndex = events.lastIndex { Self.streamType(of: $0) == "content" }
        XCTAssertEqual(
            events.count(where: { Self.streamType(of: $0) == "message_stop" }),
            1,
            "\(label): expected exactly one message_stop"
        )
        if let stopIndex, let lastContentIndex {
            XCTAssertLessThan(lastContentIndex, stopIndex, "\(label): output arrived after the turn settled")
        }
    }

    private static func isUnmatchedResponseFailure(_ error: any Error, id: String) -> Bool {
        let text = error.localizedDescription
        return text.contains("unmatched ACP response id") && text.contains(id)
    }

    private static func streamType(of event: NormalizedAgentRuntimeEvent) -> String? {
        guard case let .stream(result) = event else { return nil }
        return result.type
    }

    private static func content(in events: [NormalizedAgentRuntimeEvent]) -> [String] {
        events.compactMap { event in
            guard case let .stream(result) = event, result.type == "content" else { return nil }
            return result.text
        }
    }

    private static func terminals(in events: [NormalizedAgentRuntimeEvent]) -> [AgentSessionRunState] {
        events.compactMap { event in
            guard case let .terminal(state, _) = event else { return nil }
            return state
        }
    }

    private func drain(_ stream: AsyncStream<NormalizedAgentRuntimeEvent>) async -> [NormalizedAgentRuntimeEvent] {
        var events: [NormalizedAgentRuntimeEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    /// A failure bound, not synchronization: `session/prompt` has no request timer, so a fixture
    /// or fix defect would otherwise hang the suite. Exceeds the 30 s bootstrap request tier twice.
    private func withHangBound<T>(
        _ controller: ACPAgentSessionController,
        _ operation: () async throws -> T
    ) async throws -> T {
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 90_000_000_000)
            await controller.shutdown()
        }
        defer { watchdog.cancel() }
        return try await operation()
    }

    // MARK: - Harness

    private enum Phase: String {
        case prompt
        case bootstrap
        case idle
    }

    private enum MaintenanceFrame {
        static let skills = #"{"jsonrpc":"2.0","id":"skills-reload","result":{"result":{"reloaded":1},"payload":"PRIVATE_RESULT_SENTINEL"}}"#
        static let workflows = #"{"jsonrpc":"2.0","id":"workflows-reload","result":{"result":{"reloaded":1},"payload":"PRIVATE_RESULT_SENTINEL"}}"#
        static let outerError = #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":-32603,"message":"PRIVATE_MESSAGE_SENTINEL","data":"PRIVATE_DATA_SENTINEL"}}"#
        static let workflowsError = #"{"jsonrpc":"2.0","id":"workflows-reload","error":{"code":-32603,"message":"PRIVATE_MESSAGE_SENTINEL","data":"PRIVATE_DATA_SENTINEL"}}"#
        static let opaque = #"{"jsonrpc":"2.0","id":"workflows-reload","result":null}"#
        static let unknownID = #"{"jsonrpc":"2.0","id":"other-reload","result":{}}"#
    }

    private struct Harness {
        let workspace: URL
        let recordURL: URL
        let gate: AgentSessionLinkACPResponseGate
        let barrierID: String
        let providerID: ACPProviderID

        var request: ACPRunRequest {
            ACPRunRequest(
                agentKind: providerID == .grokBuild ? .grokBuild : .cursor,
                modelString: nil,
                workspacePath: workspace.path,
                resumeSessionID: nil,
                attachments: [],
                taskLabelKind: nil
            )
        }

        func makeController(diagnosticSink: ACPAgentSessionController.DiagnosticSink? = nil) throws -> ACPAgentSessionController {
            if providerID != .grokBuild {
                return try ACPAgentSessionController(
                    provider: NonOptedInProvider(commandPath: workspace.appendingPathComponent("grok").path),
                    runRequest: request,
                    diagnosticSink: diagnosticSink
                )
            }
            let config = GrokBuildAgentConfig(
                commandName: workspace.appendingPathComponent("grok").path,
                additionalPathHints: [],
                modelString: nil,
                includeRepoPromptMCPServer: false
            )
            return try ACPAgentSessionController(
                provider: GrokBuildACPAgentProvider(config: config), runRequest: request, diagnosticSink: diagnosticSink
            )
        }

        func recordedMessages() -> [[String: Any]] {
            guard let data = try? Data(contentsOf: recordURL),
                  let text = String(data: data, encoding: .utf8)
            else { return [] }
            return text.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }

        func recordedMethods() -> [String] {
            recordedMessages().compactMap { $0["method"] as? String }
        }
    }

    /// Deliberately does not inherit Grok's provider implementation or any future opt-in.
    private struct NonOptedInProvider: ACPAgentProvider {
        var providerID: ACPProviderID = .cursor
        let commandPath: String

        func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
            .supported
        }

        func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
            ACPLaunchConfiguration(
                providerID: providerID,
                command: commandPath,
                arguments: [],
                environment: [:],
                workingDirectory: request.workspacePath,
                additionalPathHints: [],
                enableDebugLogging: false
            )
        }

        func makeSessionConfiguration(
            for request: ACPRunRequest,
            mcpServer _: RepoPromptMCPServerConfiguration
        ) throws -> ACPSessionConfiguration {
            ACPSessionConfiguration(
                mode: .new,
                workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
                mcpServers: []
            )
        }

        func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
            [["type": "text", "text": message.userMessage]]
        }

        func normalizeSessionUpdate(_ payload: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
            GrokBuildACPEventNormalizer.normalize(payload)
        }

        func normalizeError(_ error: Error) -> Error {
            error
        }
    }

    /// Exercises the envelope gate before Grok opts in; it makes no envelope decisions itself.
    private struct IDRecognizingProvider: ACPAgentProvider {
        private let base = NonOptedInProvider(commandPath: "unused")

        var providerID: ACPProviderID {
            base.providerID
        }

        func recognizesUnmatchedResponseID(_ id: String) -> Bool {
            id == "skills-reload" || id == "workflows-reload"
        }

        func support(for request: ACPRunRequest) async throws -> ACPSupportResult {
            try await base.support(for: request)
        }

        func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
            try base.makeLaunchConfiguration(for: request)
        }

        func makeSessionConfiguration(
            for request: ACPRunRequest,
            mcpServer: RepoPromptMCPServerConfiguration
        ) throws -> ACPSessionConfiguration {
            try base.makeSessionConfiguration(for: request, mcpServer: mcpServer)
        }

        func buildPromptBlocks(for message: AgentMessage, request: ACPRunRequest) throws -> [[String: Any]] {
            try base.buildPromptBlocks(for: message, request: request)
        }

        func normalizeSessionUpdate(_ payload: [String: Any], sessionID: String) -> [NormalizedAgentRuntimeEvent] {
            base.normalizeSessionUpdate(payload, sessionID: sessionID)
        }

        func normalizeError(_ error: Error) -> Error {
            base.normalizeError(error)
        }
    }

    /// Writes the fake `grok` before the controller exists: launch identity is captured at init.
    private func makeHarness(
        label: String,
        phase: Phase,
        frames: [String],
        barrierID: String = "barrier-1",
        providerID: ACPProviderID = .grokBuild
    ) throws -> Harness {
        let workspace = try makeTestDirectory(name: "GrokBuildACPMaintenance-\(label)")
        let recordURL = workspace.appendingPathComponent("received.jsonl")
        let gate = try AgentSessionLinkACPResponseGate(directory: workspace)
        let scenario = try JSONSerialization.data(
            withJSONObject: [
                "phase": phase.rawValue, "frames": frames, "gate": gate.path,
                "barrierID": barrierID, "marker": Self.checkpointMarker, "toolOutput": Self.toolOutput
            ],
            options: [.withoutEscapingSlashes]
        )
        let recordPath = try JSONSerialization.data(
            withJSONObject: recordURL.path,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        )
        let script = Self.fakeGrokScript
            .replacingOccurrences(of: "__SCENARIO_JSON__", with: String(decoding: scenario, as: UTF8.self))
            .replacingOccurrences(of: "__RECORD_PATH_JSON__", with: String(decoding: recordPath, as: UTF8.self))
        let scriptURL = workspace.appendingPathComponent("grok")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return Harness(
            workspace: workspace, recordURL: recordURL, gate: gate,
            barrierID: barrierID, providerID: providerID
        )
    }

    /// One serialized binary-input/gate loop. No Python text buffering can hide stdin lines
    /// from select, and holding a prompt never prevents reading another ACP request.
    private static let fakeGrokScript = #"""
    #!/usr/bin/env python3
    import json
    import os
    import select
    import sys

    SCENARIO = json.loads(r'''__SCENARIO_JSON__''')
    RECORD_PATH = json.loads(r'''__RECORD_PATH_JSON__''')
    SESSION_ID = "grok-maintenance-session"
    BARRIER_ID = SCENARIO["barrierID"]
    SESSION_NEW_RESULT = {"sessionId": SESSION_ID, "models": {
        "currentModelId": "grok-4.6",
        "availableModels": [
            {"modelId": "grok-4.6", "name": "Grok 4.6"},
            {"modelId": "grok-4.5", "name": "Grok 4.5"}
        ]
    }}

    if "--help" in sys.argv:
        print("Usage: grok agent [OPTIONS] [COMMAND]\n\nCommands:\n  stdio    Run the agent over stdio")
        sys.exit(0)

    def record(entry):
        with open(RECORD_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(dict(entry, fixturePID=os.getpid())) + "\n")

    def write_line(text):
        try:
            sys.stdout.write(text + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(0)

    def send(message):
        write_line(json.dumps(message))

    def respond(request_id, result):
        send({"jsonrpc": "2.0", "id": request_id, "result": result})

    def chunk(text):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": SESSION_ID,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})

    def update(payload):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": SESSION_ID, "update": payload}})

    def inject_maintenance_then_barrier():
        for frame in SCENARIO["frames"]:
            write_line(frame)
        send({"jsonrpc": "2.0", "id": BARRIER_ID, "method": "fake/barrier", "params": {}})

    held = None
    prompts = 0
    barrier_seen = False
    idle_injected = False
    gate_fd = os.open(SCENARIO["gate"], os.O_RDONLY | os.O_NONBLOCK)

    def release_held():
        global held
        kind, owned_id = held
        held = None
        if kind == "session/new":
            respond(owned_id, SESSION_NEW_RESULT)
        else:
            update({"sessionUpdate": "tool_call_update", "toolCallId": "maintenance-tool",
                    "status": "completed", "rawOutput": {"stdout": SCENARIO["toolOutput"], "exitCode": 0}})
            chunk("suffix")
            respond(owned_id, {"stopReason": "end_turn"})

    def dispatch(message):
        global held, prompts, barrier_seen
        record(message)
        method = message.get("method")
        request_id = message.get("id")
        if method is None:
            if request_id == BARRIER_ID and idle_injected and not barrier_seen:
                barrier_seen = True
                update({"sessionUpdate": "agent_thought_chunk",
                        "content": {"type": "text", "text": SCENARIO["marker"]}})
            elif request_id == BARRIER_ID and held is not None and not barrier_seen:
                barrier_seen = True
                if held[0] == "session/new":
                    release_held()
                else:
                    with open(SCENARIO["gate"] + ".entered", "w", encoding="utf-8") as marker:
                        marker.write(str(held[1]))
                    update({"sessionUpdate": "agent_thought_chunk",
                            "content": {"type": "text", "text": SCENARIO["marker"]}})
            return
        if method == "initialize":
            respond(request_id, {
                "protocolVersion": 1,
                "agentCapabilities": {"loadSession": True, "promptCapabilities": {"embeddedContext": True}},
                "authMethods": []
            })
        elif method == "session/new" and SCENARIO["phase"] == "bootstrap":
            held = ("session/new", request_id)
            inject_maintenance_then_barrier()
        elif method == "session/new":
            respond(request_id, SESSION_NEW_RESULT)
        elif method == "session/prompt":
            prompts += 1
            if prompts == 1 and SCENARIO["phase"] == "prompt":
                chunk("prefix")
                held = ("session/prompt", request_id)
                inject_maintenance_then_barrier()
            elif prompts == 1 and SCENARIO["phase"] == "idle":
                chunk("first")
                respond(request_id, {"stopReason": "end_turn"})
            else:
                chunk("second")
                # Protect the controller's existing numeric-string owned-ID alias.
                respond(str(request_id), {"stopReason": "end_turn"})
        elif request_id is not None:
            respond(request_id, {})

    pending_bytes = b""
    try:
        while True:
            readers = [sys.stdin.fileno()]
            idle_ready = SCENARIO["phase"] == "idle" and prompts == 1 and not idle_injected
            if idle_ready or (held is not None and held[0] == "session/prompt" and barrier_seen):
                readers.append(gate_fd)
            ready, _, _ = select.select(readers, [], [])
            if sys.stdin.fileno() in ready:
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    break
                pending_bytes += data
                while b"\n" in pending_bytes:
                    line, pending_bytes = pending_bytes.split(b"\n", 1)
                    if line.strip():
                        dispatch(json.loads(line))
            if gate_fd in ready and os.read(gate_fd, 1):
                if idle_ready:
                    idle_injected = True
                    inject_maintenance_then_barrier()
                else:
                    release_held()
    finally:
        os.close(gate_fd)
    """# + "\n"
}
