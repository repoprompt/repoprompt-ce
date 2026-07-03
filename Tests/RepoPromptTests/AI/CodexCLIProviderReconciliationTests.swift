@testable import RepoPrompt
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

    func testFreshStreamingThreadTitledFromLastUserMessage() async throws {
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn", itemID: "assistant")
        let (provider, spy) = makeProviderWithSpy(events: [
            .canonicalAssistantDelta(text: "hel", scope: scope),
            .assistantCompleted(.init(scope: scope, text: "hello")),
            .turnCompleted(turnID: "turn", status: .completed)
        ])

        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "Refactor the login flow"),
            model: .codexCustom(name: "test-model")
        )
        _ = try await drain(stream)

        XCTAssertEqual(spy.setThreadNameCalls.count, 1)
        XCTAssertEqual(spy.setThreadNameCalls.first?.name, "Refactor the login flow")
        XCTAssertEqual(spy.setThreadNameCalls.first?.threadID, "thread")
    }

    func testFreshCompletionThreadTitled() async throws {
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn", itemID: "assistant")
        let (provider, spy) = makeProviderWithSpy(events: [
            .canonicalAssistantDelta(text: "hel", scope: scope),
            .assistantCompleted(.init(scope: scope, text: "hello")),
            .turnCompleted(turnID: "turn", status: .completed)
        ])

        _ = try await provider.completeMessage(
            AIMessage(systemPrompt: "", userMessage: "Summarize the auth module"),
            model: .codexCustom(name: "test-model")
        )

        XCTAssertEqual(spy.setThreadNameCalls.count, 1)
        XCTAssertEqual(spy.setThreadNameCalls.first?.name, "Summarize the auth module")
        XCTAssertEqual(spy.setThreadNameCalls.first?.threadID, "thread")
    }

    func testLongFirstLineCappedTo80() async throws {
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn", itemID: "assistant")
        let (provider, spy) = makeProviderWithSpy(events: [
            .canonicalAssistantDelta(text: "hel", scope: scope),
            .assistantCompleted(.init(scope: scope, text: "hello")),
            .turnCompleted(turnID: "turn", status: .completed)
        ])

        let longLine = String(repeating: "x", count: 120)
        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: longLine),
            model: .codexCustom(name: "test-model")
        )
        _ = try await drain(stream)

        XCTAssertEqual(spy.setThreadNameCalls.count, 1)
        XCTAssertLessThanOrEqual(spy.setThreadNameCalls.first?.name.count ?? 0, 80)
    }

    func testMultiLineMessageUsesOnlyFirstLine() async throws {
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn", itemID: "assistant")
        let (provider, spy) = makeProviderWithSpy(events: [
            .canonicalAssistantDelta(text: "hel", scope: scope),
            .assistantCompleted(.init(scope: scope, text: "hello")),
            .turnCompleted(turnID: "turn", status: .completed)
        ])

        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "Line one\nLine two\nLine three"),
            model: .codexCustom(name: "test-model")
        )
        _ = try await drain(stream)

        XCTAssertEqual(spy.setThreadNameCalls.count, 1)
        XCTAssertEqual(spy.setThreadNameCalls.first?.name, "Line one")
    }

    func testTitleFailureDoesNotBreakTurn() async throws {
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn", itemID: "assistant")
        let (provider, spy) = makeProviderWithSpy(events: [
            .canonicalAssistantDelta(text: "hel", scope: scope),
            .assistantCompleted(.init(scope: scope, text: "hello")),
            .turnCompleted(turnID: "turn", status: .completed)
        ])
        spy.setThreadNameShouldThrow = true

        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "Refactor the login flow"),
            model: .codexCustom(name: "test-model")
        )
        let result = try await drain(stream)

        // The title call was attempted (best-effort)...
        XCTAssertEqual(spy.setThreadNameCalls.count, 1)
        // ...and its failure did not propagate: the turn completed normally.
        XCTAssertEqual(result.messageStopCount, 1)
    }

    func testEmptyOrWhitespaceMessageUsesFallbackName() async throws {
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn", itemID: "assistant")
        let (provider, spy) = makeProviderWithSpy(events: [
            .canonicalAssistantDelta(text: "hel", scope: scope),
            .assistantCompleted(.init(scope: scope, text: "hello")),
            .turnCompleted(turnID: "turn", status: .completed)
        ])

        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "   "),
            model: .codexCustom(name: "test-model")
        )
        _ = try await drain(stream)

        XCTAssertEqual(spy.setThreadNameCalls.count, 1)
        XCTAssertEqual(spy.setThreadNameCalls.first?.name, "Agent Session")
    }

    private func makeProvider(
        events: [CodexNativeSessionController.Event]
    ) -> CodexCLIProvider {
        CodexCLIProvider(
            defaultRequestTimeout: 5,
            testRequestTimeout: 5,
            maxRetries: 0,
            appServerReadyHook: {},
            sessionControllerFactory: { _, _ in
                ScriptedCodexProviderController(events: events)
            }
        )
    }

    /// Builds a provider whose factory returns a shared spy, so the test can
    /// inspect `setThreadName` calls captured on that spy after driving a turn.
    private func makeProviderWithSpy(
        events: [CodexNativeSessionController.Event]
    ) -> (provider: CodexCLIProvider, spy: ScriptedCodexProviderController) {
        let spy = ScriptedCodexProviderController(events: events)
        let provider = CodexCLIProvider(
            defaultRequestTimeout: 5,
            testRequestTimeout: 5,
            maxRetries: 0,
            appServerReadyHook: {},
            sessionControllerFactory: { _, _ in spy }
        )
        return (provider, spy)
    }

    private func drain(
        _ stream: AsyncThrowingStream<AIStreamResult, Error>
    ) async throws -> (content: [String], messageStopCount: Int) {
        var content: [String] = []
        var messageStopCount = 0
        for try await result in stream {
            if result.type == "content", let text = result.text {
                content.append(text)
            } else if result.type == "message_stop" {
                messageStopCount += 1
            }
        }
        return (content, messageStopCount)
    }
}

private final class ScriptedCodexProviderController: CodexSessionControlling {
    let events: AsyncStream<CodexNativeSessionController.Event>

    init(events: [CodexNativeSessionController.Event]) {
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

    // Captures `setThreadName` calls instead of relying on the protocol-extension
    // no-op. Production does not yet call `setThreadName`, so the assertions below
    // fail RED with zero captured calls; an implementer wiring the call turns them green.
    var setThreadNameCalls: [(name: String, threadID: String?)] = []
    var setThreadNameShouldThrow: Bool = false

    func setThreadName(_ name: String, threadID: String?) async throws {
        setThreadNameCalls.append((name, threadID))
        if setThreadNameShouldThrow {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "thread", rolloutPath: nil, model: nil, reasoningEffort: nil)
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
