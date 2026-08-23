import Foundation
import RepoPromptAgentRuntimeCore
@testable import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class HeadlessPresentationParityTests: XCTestCase {
    func testReasoningStatusUsesDesktopIngTitlesOnly() {
        XCTAssertEqual(
            AgentTranscriptPresentationCore.reasoningStatusText(from: "**Inspecting the workspace**\nMore detail"),
            "Inspecting the workspace"
        )
        XCTAssertNil(AgentTranscriptPresentationCore.reasoningStatusText(from: "**Workspace layout**\nNot a status"))
        XCTAssertNil(AgentTranscriptPresentationCore.reasoningStatusText(from: "Inspecting without bold markers"))
        XCTAssertEqual(
            AgentTranscriptPresentationCore.reasoningStatusText(from: "**Checking**\n**Reading files**"),
            "Reading files"
        )
    }

    func testACPNormalizerMatchesDesktopCursorToolAndStatusRules() throws {
        let placeholder = try HeadlessACPSessionUpdateNormalizer.normalize(
            Data(#"{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"t0","title":"other"}}}"#.utf8)
        )
        XCTAssertTrue(placeholder.isEmpty)

        let named = try HeadlessACPSessionUpdateNormalizer.normalize(
            Data(#"{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"read_file (RepoPrompt CE)","rawInput":{"path":"A.swift"}}}}"#.utf8)
        )
        guard case let .toolStarted(_, name, arguments) = named.first else {
            return XCTFail("RepoPrompt-titled ACP tools must keep a machine name")
        }
        XCTAssertEqual(name, "read_file")
        XCTAssertNotNil(arguments)

        let plan = try HeadlessACPSessionUpdateNormalizer.normalize(
            Data(#"{"method":"session/update","params":{"update":{"sessionUpdate":"plan","text":"plan updated"}}}"#.utf8)
        )
        XCTAssertTrue(plan.isEmpty)

        let info = try HeadlessACPSessionUpdateNormalizer.normalize(
            Data(#"{"method":"session/update","params":{"update":{"sessionUpdate":"session_info_update","title":"Exploring the repo"}}}"#.utf8)
        )
        guard case let .runStatusChanged(phase, code, text) = info.first else {
            return XCTFail("session_info_update must become live status, matching Desktop")
        }
        XCTAssertEqual(phase, .thinking)
        XCTAssertEqual(code, HeadlessRunStatusCopy.thinkingCode)
        XCTAssertEqual(text, "Exploring the repo")

        let completed = try HeadlessACPSessionUpdateNormalizer.normalize(
            Data(#"{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","title":"Bash","kind":"shell","rawOutput":{"exitCode":0,"output":"ok"}}}}"#.utf8)
        )
        guard case let .toolCompleted(_, completedName, output, status) = completed.first else {
            return XCTFail("completed ACP tools must keep Desktop terminal payloads")
        }
        XCTAssertEqual(completedName, "bash")
        XCTAssertEqual(status, .success)
        XCTAssertTrue(output?.contains("acp_status") == true)

        let permission = try HeadlessACPSessionUpdateNormalizer.normalize(
            Data(#"{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"toolCall":{"title":"Run tests"},"options":[{"optionId":"allow-once"}]}}"#.utf8)
        )
        guard case let .interactionRequested(_, kind, prompt, choices) = permission.first else {
            return XCTFail("ACP permission requests must stay approvals")
        }
        XCTAssertEqual(kind, .approval)
        XCTAssertEqual(prompt, "Run tests")
        XCTAssertEqual(choices, ["allow-once"])

        let usage = try HeadlessACPSessionUpdateNormalizer.normalize(
            Data(#"{"method":"session/update","params":{"update":{"sessionUpdate":"usage_update","used":1234,"size":200000}}}"#.utf8)
        )
        guard case let .contextUsage(snapshot) = usage.first else {
            return XCTFail("ACP usage_update must become the composer context meter")
        }
        XCTAssertEqual(snapshot.lastTotalTokens, 1234)
        XCTAssertEqual(snapshot.totalTotalTokens, 1234)
        XCTAssertEqual(snapshot.modelContextWindow, 200_000)

        let ignored = try HeadlessACPSessionUpdateNormalizer.normalize(
            Data(#"{"method":"session/update","params":{"update":{"sessionUpdate":"usage_update"}}}"#.utf8)
        )
        XCTAssertTrue(ignored.isEmpty)
    }

    func testACPPromptResultUsageMatchesDesktopGrokMetaUsage() {
        let grok = HeadlessACPSessionUpdateNormalizer.contextUsageFromPromptResult([
            "_meta": [
                "usage": [
                    "inputTokens": 800,
                    "outputTokens": 40,
                    "cachedReadTokens": 200,
                    "cachedWriteTokens": 16
                ]
            ]
        ])
        XCTAssertEqual(grok?.lastTotalTokens, 1016)
        XCTAssertEqual(grok?.totalTotalTokens, 1016)
        XCTAssertNil(grok?.modelContextWindow)

        let standard = HeadlessACPSessionUpdateNormalizer.contextUsageFromPromptResult([
            "usage": ["inputTokens": 10, "cachedReadTokens": 5, "cachedWriteTokens": 1]
        ])
        XCTAssertEqual(standard?.lastTotalTokens, 16)

        XCTAssertNil(HeadlessACPSessionUpdateNormalizer.contextUsageFromPromptResult(["stopReason": "end_turn"]))
    }

    func testPreservedReasoningTitleIsNotReplacedByToolName() {
        let now = Date()
        let current = RunPresentationSnapshot(
            sessionID: UUID(),
            runID: UUID(),
            generation: 1,
            turnEpoch: 1,
            phase: .thinking,
            phaseRevision: 3,
            runningStatusCode: HeadlessRunStatusCopy.reasoningTitleCode,
            runningStatusText: "Inspecting the workspace",
            runStartedAt: now
        )
        let preserved = HeadlessRunStatusCopy.preservedOrThinking(current: current)
        XCTAssertEqual(preserved.code, HeadlessRunStatusCopy.reasoningTitleCode)
        XCTAssertEqual(preserved.text, "Inspecting the workspace")
        let fallback = HeadlessRunStatusCopy.preservedOrThinking(current: nil)
        XCTAssertEqual(fallback.text, HeadlessRunStatusCopy.thinking)
    }

    func testAskUserPayloadDetectionAndDesktopAnswerShaping() throws {
        let arguments = Data(#"{"title":"Need a couple of decisions","timeout_seconds":45,"questions":[{"id":"scope","question":"What first?"}]}"#.utf8)
        XCTAssertTrue(HeadlessAskUser.isAskUserPayload(arguments))
        XCTAssertEqual(HeadlessAskUser.timeoutSeconds(from: arguments), 45)
        XCTAssertFalse(HeadlessAskUser.isAskUserPayload(Data(#"{"prompt":"Choose a branch","choices":["sandbox"]}"#.utf8)))

        let desktop = Data(#"{"title":"Need a couple of decisions","questions":[{"id":"scope","question":"What first?"}],"answers":{"scope":{"answers":["Composer"],"selected_options":["Composer"],"custom_response":null,"skipped":false}},"timed_out":false,"skipped":false,"elapsed_seconds":3}"#.utf8)
        let preserved = try JSONSerialization.jsonObject(with: HeadlessAskUser.desktopResponse(from: desktop)) as? [String: Any]
        XCTAssertEqual(preserved?["timed_out"] as? Bool, false)
        XCTAssertNotNil((preserved?["answers"] as? [String: Any])?["scope"])
        XCTAssertNil(preserved?["questions"])
        let presented = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: HeadlessAskUser.presentationPayload(
                    request: arguments,
                    answer: Data(#"{"answers":{"scope":{"answers":["Composer"],"selected_options":["Composer"],"custom_response":null,"skipped":false}},"timed_out":false,"skipped":false,"elapsed_seconds":3}"#.utf8)
                )
            ) as? [String: Any]
        )
        XCTAssertNotNil(presented["questions"])
        XCTAssertEqual(HeadlessAskUser.resolutionLabel(from: HeadlessAskUser.presentationPayload(request: arguments, answer: desktop)), "answered")

        let legacy = HeadlessAskUser.desktopResponse(
            from: Data(#"{"answers":[{"questionId":"scope","text":"Composer"}]}"#.utf8),
            elapsedSeconds: 2
        )
        let normalized = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        let answer = try XCTUnwrap((normalized["answers"] as? [String: Any])?["scope"] as? [String: Any])
        XCTAssertEqual(answer["answers"] as? [String], ["Composer"])
        XCTAssertEqual(answer["custom_response"] as? String, "Composer")
        XCTAssertEqual(normalized["elapsed_seconds"] as? Int, 2)

        let timedOut = try XCTUnwrap(
            JSONSerialization.jsonObject(with: HeadlessAskUser.desktopResponse(from: Data(), timedOut: true, elapsedSeconds: 9)) as? [String: Any]
        )
        XCTAssertEqual(timedOut["timed_out"] as? Bool, true)
        XCTAssertEqual(timedOut["elapsed_seconds"] as? Int, 9)
    }

    func testAskUserWaitsAndResolvesLocallyWithoutProviderDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let delivery = RecordingAskUserDelivery()
        let authority = RepoPromptHeadlessAuthority(store: store, interactionDelivery: delivery)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(
            input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "p-ask-user",
            requestDigest: "p-ask-user"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "s-ask-user",
            requestDigest: "s-ask-user"
        )
        let arguments = Data(#"{"title":"Need a couple of decisions","questions":[{"id":"scope","question":"What first?","options":[{"label":"Composer"}]}]}"#.utf8)
        async let waited = authority.askUserAndWait(sessionID: session.sessionID, arguments: arguments, timeoutSeconds: 5)
        var pending: InteractionSnapshot?
        for _ in 0 ..< 50 {
            if let current = try await authority.interactionSnapshots(sessionID: session.sessionID).first(where: { $0.state == .pending }) {
                pending = current
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let interaction = try XCTUnwrap(pending)
        XCTAssertTrue(HeadlessAskUser.isAskUserPayload(interaction.payload))
        _ = try await authority.answerInteraction(
            sessionID: session.sessionID,
            interactionID: interaction.interactionID,
            expectedRevision: interaction.revision,
            payload: Data(#"{"answers":{"scope":{"answers":["Composer"],"selected_options":["Composer"],"custom_response":null,"skipped":false}},"timed_out":false,"skipped":false,"elapsed_seconds":1}"#.utf8),
            actor: actor,
            idempotencyKey: "answer-ask-user",
            requestDigest: "answer-ask-user"
        )
        let result = try JSONSerialization.jsonObject(with: try await waited) as? [String: Any]
        XCTAssertEqual(result?["timed_out"] as? Bool, false)
        XCTAssertNotNil((result?["answers"] as? [String: Any])?["scope"])
        let deliveryCount = await delivery.deliveryCount()
        XCTAssertEqual(deliveryCount, 0)
        try await store.close()
    }
}

private actor RecordingAskUserDelivery: InteractionDeliveryPort {
    private var count = 0

    func deliverAnswer(session _: SessionSnapshot, interaction _: InteractionSnapshot, answer _: Data) async throws {
        count += 1
    }

    func deliveryCount() -> Int {
        count
    }
}
