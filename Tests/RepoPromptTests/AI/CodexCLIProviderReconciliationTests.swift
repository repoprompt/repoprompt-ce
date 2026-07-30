import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexCLIProviderReconciliationTests: XCTestCase {
    func testCanonicalCompletionReconcilesStreamingTailAndConnectionReplacement() async throws {
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn", itemID: "assistant")
        let streamingProvider = makeProvider(events: [
            .canonicalAssistantDelta(text: "hel", scope: scope),
            .assistantCompleted(.init(scope: scope, text: "hello")),
            .turnCompleted(turnID: "turn", status: .completed)
        ])

        let stream = try await streamingProvider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "prompt"),
            model: .codexCustom(name: "test-model")
        )
        var content: [String] = []
        var messageStopCount = 0
        for try await result in stream {
            if result.type == "content", let text = result.text {
                content.append(text)
            } else if result.type == "message_stop" {
                messageStopCount += 1
            }
        }
        XCTAssertEqual(content, ["hel", "lo"])
        XCTAssertEqual(messageStopCount, 1)

        let connectionProvider = makeProvider(events: [
            .canonicalAssistantDelta(text: "OK", scope: scope),
            .assistantCompleted(.init(scope: scope, text: "NO")),
            .turnCompleted(turnID: "turn", status: .completed)
        ])
        let connected = try await connectionProvider.testConnection(timeout: 5)
        XCTAssertFalse(connected)
    }

    func testStructuredFailedCompletionMessagePropagatesThroughStreamingAndConnectionPaths() async throws {
        let failure = CodexNativeSessionController.Event.turnCompleted(
            turnID: "turn",
            status: .failed,
            failure: .init(message: "authoritative provider failure")
        )

        let streamingProvider = makeProvider(events: [failure])
        let stream = try await streamingProvider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "prompt"),
            model: .codexCustom(name: "test-model")
        )
        do {
            for try await _ in stream {}
            XCTFail("Expected the structured streaming failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "authoritative provider failure")
        }

        let connectionProvider = makeProvider(events: [failure])
        do {
            _ = try await connectionProvider.testConnection(timeout: 5)
            XCTFail("Expected the structured connection failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "authoritative provider failure")
        }
    }

    @MainActor
    func testNonAgentMemoriesStayDisabledAndStreamingStartsFreshWhenAgentModePreferenceIsEnabled() async throws {
        let settings = GlobalSettingsStore.shared
        let previousMemoriesEnabled = settings.codexMemoriesEnabled()
        settings.setCodexMemoriesEnabled(true, commit: false)
        defer {
            settings.setCodexMemoriesEnabled(previousMemoriesEnabled, commit: false)
        }
        XCTAssertTrue(settings.codexMemoriesEnabled())

        let startRecorder = ScriptedCodexProviderStartRecorder()
        let provider = makeProvider(
            events: [.turnCompleted(turnID: "turn", status: .completed)],
            startRecorder: startRecorder
        )
        let overrides = provider.interactiveConfigOverrides(excludeServers: [])
        for key in ["features.memories", "memories.generate_memories", "memories.use_memories"] {
            XCTAssertEqual(overrides[key] as? Bool, false, key)
        }

        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "prompt"),
            model: .codexCustom(name: "test-model")
        )
        for try await _ in stream {}

        let startSnapshot = await startRecorder.snapshot()
        XCTAssertEqual(startSnapshot.callCount, 1)
        XCTAssertTrue(startSnapshot.resumedThreadIDs.isEmpty)
    }

    private func makeProvider(
        events: [CodexNativeSessionController.Event],
        startRecorder: ScriptedCodexProviderStartRecorder? = nil
    ) -> CodexCLIProvider {
        CodexCLIProvider(
            defaultRequestTimeout: 5,
            testRequestTimeout: 5,
            maxRetries: 0,
            appServerReadyHook: {},
            sessionControllerFactory: { _, _ in
                ScriptedCodexProviderController(events: events, startRecorder: startRecorder)
            }
        )
    }
}

private final class ScriptedCodexProviderController: CodexSessionControlling {
    let events: AsyncStream<CodexNativeSessionController.Event>
    private let startRecorder: ScriptedCodexProviderStartRecorder?

    init(
        events: [CodexNativeSessionController.Event],
        startRecorder: ScriptedCodexProviderStartRecorder? = nil
    ) {
        self.startRecorder = startRecorder
        self.events = AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    var hasActiveThread: Bool {
        true
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        if let startRecorder {
            await startRecorder.record(existing: existing)
        }
        return .init(conversationID: "thread", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        .init(provisionalSubmissionID: "turn")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        .init(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        .init(interruptedTurnID: expectedTurnID)
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}

private actor ScriptedCodexProviderStartRecorder {
    private var callCount = 0
    private var resumedThreadIDs: [String] = []

    func record(existing: CodexNativeSessionController.SessionRef?) {
        callCount += 1
        if let existing {
            resumedThreadIDs.append(existing.conversationID)
        }
    }

    func snapshot() -> (callCount: Int, resumedThreadIDs: [String]) {
        (callCount, resumedThreadIDs)
    }
}
