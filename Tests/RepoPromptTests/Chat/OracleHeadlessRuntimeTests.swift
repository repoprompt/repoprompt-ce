import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class OracleHeadlessRuntimeTests: XCTestCase {
    @MainActor
    func testExecuteAccumulatesStreamOutputAndClearsTabRegistration() async throws {
        let tabID = UUID()
        let streamID = UUID()
        var progressText: [String] = []

        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    continuation.yield(
                        ChatStreamOutput(
                            text: "  Hello ",
                            reasoning: nil,
                            tokens: ChatTokenInfo(promptTokens: 1)
                        )
                    )
                    continuation.yield(
                        ChatStreamOutput(
                            text: "world  ",
                            reasoning: nil,
                            tokens: ChatTokenInfo(promptTokens: 2, completionTokens: 3, cost: 0.25),
                            terminalOutcome: .completed
                        )
                    )
                    continuation.finish()
                }
                return (streamID, stream)
            },
            cancelStream: { _ in },
            cleanupConversation: { _, _ in }
        )

        let output = try await runtime.execute(
            message: AIMessage(systemPrompt: "system", userMessage: "prompt"),
            model: .claude4Sonnet,
            tabID: tabID,
            completionPolicy: .contextBuilderStrict,
            onProgress: { text, _ in progressText.append(text) }
        )

        XCTAssertEqual(output.text, "Hello world")
        XCTAssertEqual(output.tokenInfo.promptTokens, 2)
        XCTAssertEqual(output.tokenInfo.completionTokens, 3)
        XCTAssertEqual(output.tokenInfo.cost, 0.25)
        XCTAssertEqual(progressText, ["  Hello ", "  Hello world  "])
        XCTAssertFalse(runtime.hasActiveStream(for: tabID))
    }

    /// Issue #26: aborting the owning task (an Agent Mode thread stop during a context_builder
    /// follow-up) must terminate the provider stream explicitly, clear the tab registration, and
    /// ignore any late chunks — not merely drop the iterator.
    @MainActor
    func testCancellingExecuteCancelsUpstreamStreamClearsRegistrationAndIgnoresLateChunks() async throws {
        let tabID = UUID()
        let streamID = UUID()
        let cancelledStreams = LateChunkRecorder()
        let progress = LateChunkRecorder()
        let continuationBox = ContinuationBox()
        let cleanupCalls = LateChunkRecorder()

        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    Task { await continuationBox.store(continuation) }
                    continuation.yield(ChatStreamOutput(text: "partial", reasoning: nil, tokens: ChatTokenInfo()))
                    // Never finishes on its own: a provider stream that is still generating.
                }
                return (streamID, stream)
            },
            cancelStream: { id in await cancelledStreams.record(id.uuidString) },
            cleanupConversation: { _, _ in await cleanupCalls.record("cleanup") }
        )

        let execution = Task { @MainActor in
            try await runtime.execute(
                message: AIMessage(systemPrompt: "system", userMessage: "prompt"),
                model: .claude4Sonnet,
                tabID: tabID,
                completionPolicy: .contextBuilderStrict,
                onProgress: { text, _ in Task { await progress.record(text) } }
            )
        }
        try await Self.waitUntil("first chunk observed") { await progress.values().contains("partial") }
        XCTAssertTrue(runtime.hasActiveStream(for: tabID))

        execution.cancel()
        do {
            _ = try await execution.value
            XCTFail("Cancelled execute must not return output")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected error after abort: \(error)")
        }

        try await Self.waitUntil("upstream stream cancelled") { await cancelledStreams.values() == [streamID.uuidString] }
        XCTAssertFalse(runtime.hasActiveStream(for: tabID), "no spinner-backing registration may survive an abort")

        // A chunk that arrives after the abort must not reach the progress sink.
        let storedContinuation = await continuationBox.current()
        let continuation = try XCTUnwrap(storedContinuation)
        continuation.yield(ChatStreamOutput(text: "late", reasoning: nil, tokens: ChatTokenInfo()))
        continuation.finish()
        try await Task.sleep(for: .milliseconds(50))
        let observed = await progress.values()
        XCTAssertFalse(observed.contains { $0.contains("late") }, "late chunk leaked after abort: \(observed)")
    }

    private static func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    func testEmptyAdditionalRosterUsesExactSingleOracleBypass() {
        XCTAssertFalse(AppOracleGroupRouting.usesGroup(additionalModelRaws: []))
        XCTAssertTrue(AppOracleGroupRouting.usesGroup(additionalModelRaws: ["secondary-model"]))
    }

    func testResolvedExecutionProfileCapturesRuntimeModelAndEffectiveEffort() throws {
        let codex = AIModel.codexCustom(name: "gpt-5.6-sol-high")
        let codexProfile = try XCTUnwrap(AppOracleGroupRouting.executionProfile(for: codex))
        XCTAssertEqual(codexProfile.providerID, "codex")
        XCTAssertEqual(codexProfile.modelID, codex.modelName)
        XCTAssertEqual(codexProfile.effectiveReasoningEffort, "high")

        let thinkingProfile = try XCTUnwrap(
            AppOracleGroupRouting.executionProfile(for: .claude4SonnetThinkingMax)
        )
        XCTAssertEqual(thinkingProfile.providerID, "anthropic")
        XCTAssertEqual(thinkingProfile.modelID, "claude-sonnet-4-5-20250929-thinking-max")
        XCTAssertNil(thinkingProfile.effectiveReasoningEffort)

        let customProfile = try XCTUnwrap(AppOracleGroupRouting.executionProfile(for: .customProvider(
            name: "Custom",
            provider: "acme-runtime",
            model: "acme-model"
        )))
        XCTAssertEqual(customProfile.providerID, "acme-runtime")
        XCTAssertEqual(customProfile.modelID, "acme-model")
    }

    @MainActor
    func testCanonicalGroupReplyPreservesOrderAndRoutesTopLevelFieldsToPrimary() throws {
        let groupID = try OracleGroupID(rawValue: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")))
        let result = try OracleGroupResult(
            groupID: groupID,
            status: .completed,
            oracleResults: [
                OracleLaneResult(
                    laneIndex: 0,
                    chatID: "primary-chat",
                    providerID: "provider-a",
                    modelID: "model-a",
                    status: .completed,
                    response: "primary-response"
                ),
                OracleLaneResult(
                    laneIndex: 1,
                    chatID: "secondary-chat",
                    providerID: "provider-b",
                    modelID: "model-b",
                    status: .completed,
                    response: "secondary-response"
                )
            ]
        )

        let reply = OracleViewModel.oracleGroupValue(result, mode: "review", tabContext: nil)
        XCTAssertEqual(reply["chat_id"]?.stringValue, "primary-chat")
        XCTAssertEqual(reply["response"]?.stringValue, "primary-response")
        XCTAssertEqual(reply["mode"]?.stringValue, "review")
        XCTAssertEqual(reply["backend"]?.stringValue, "app")
        XCTAssertEqual(reply["oracle_group_id"]?.stringValue, groupID.rawValue.uuidString)
        XCTAssertEqual(reply["oracle_count"]?.intValue, 2)
        let lanes = try XCTUnwrap(reply["oracle_results"]?.arrayValue)
        XCTAssertEqual(lanes.compactMap { $0.objectValue?["chat_id"]?.stringValue }, ["primary-chat", "secondary-chat"])
        XCTAssertEqual(lanes.compactMap { $0.objectValue?["role"]?.stringValue }, ["primary", "additional"])
    }
}

private actor LateChunkRecorder {
    private var recorded: [String] = []

    func record(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }
}

private actor ContinuationBox {
    private var continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation?

    func store(_ continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation) {
        self.continuation = continuation
    }

    func current() -> AsyncThrowingStream<ChatStreamOutput, Error>.Continuation? {
        continuation
    }
}
