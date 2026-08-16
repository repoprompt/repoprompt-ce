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

    @MainActor
    func testStrictIncompleteTerminationFailsAndCleansUpProviderConversation() async throws {
        let tabID = UUID()
        let handle = ProviderConversationCleanupHandle(
            provider: "test-provider",
            conversationID: "conversation-1"
        )
        let cleanupExpectation = expectation(description: "provider cleanup")

        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    continuation.yield(
                        ChatStreamOutput(
                            text: "partial",
                            reasoning: nil,
                            tokens: ChatTokenInfo(),
                            terminalOutcome: .incomplete(reason: "max_tokens"),
                            cleanupHandle: handle
                        )
                    )
                    continuation.finish()
                }
                return (UUID(), stream)
            },
            cancelStream: { _ in },
            cleanupConversation: { cleanedHandle, _ in
                XCTAssertEqual(cleanedHandle, handle)
                cleanupExpectation.fulfill()
            }
        )

        do {
            _ = try await runtime.execute(
                message: AIMessage(systemPrompt: "system", userMessage: "prompt"),
                model: .claude4Sonnet,
                tabID: tabID,
                completionPolicy: .contextBuilderStrict
            )
            XCTFail("Expected strict incomplete termination to fail")
        } catch {
            XCTAssertEqual(
                error as? OracleContextBuilderCompletionError,
                .providerTerminatedIncomplete(reason: "max_tokens")
            )
        }

        await fulfillment(of: [cleanupExpectation], timeout: 1)
        XCTAssertFalse(runtime.hasActiveStream(for: tabID))
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

    @MainActor
    func testCancelStreamTargetsOnlyRegisteredTabStream() async throws {
        let tabID = UUID()
        let streamID = UUID()
        let controller = OracleHeadlessTestStreamController()
        let continuationInstalled = expectation(description: "stream continuation installed")
        let progressObserved = expectation(description: "runtime consumed first stream chunk")

        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    Task {
                        await controller.install(continuation)
                        await MainActor.run { continuationInstalled.fulfill() }
                    }
                    continuation.yield(
                        ChatStreamOutput(
                            text: "partial",
                            reasoning: nil,
                            tokens: ChatTokenInfo()
                        )
                    )
                }
                return (streamID, stream)
            },
            cancelStream: { cancelledStreamID in
                await controller.recordCancellation(cancelledStreamID)
                await controller.finish()
            },
            cleanupConversation: { _, _ in },
            timeout: .seconds(2)
        )

        let execution = Task { @MainActor in
            try await runtime.execute(
                message: AIMessage(systemPrompt: "system", userMessage: "prompt"),
                model: .claude4Sonnet,
                tabID: tabID,
                completionPolicy: .interactive,
                onProgress: { _, _ in progressObserved.fulfill() }
            )
        }

        await fulfillment(of: [continuationInstalled, progressObserved], timeout: 1)
        guard await controller.hasInstalledContinuation(),
              runtime.hasActiveStream(for: tabID)
        else {
            await controller.finish()
            execution.cancel()
            _ = try? await execution.value
            XCTFail("Expected a registered stream with an installed continuation")
            return
        }

        do {
            await runtime.cancelStream(for: tabID)
            let output = try await execution.value
            await controller.finish()

            XCTAssertEqual(output.text, "partial")
            let cancelledStreamIDs = await controller.cancelledStreamIDs()
            XCTAssertEqual(cancelledStreamIDs, [streamID])
            XCTAssertFalse(runtime.hasActiveStream(for: tabID))
        } catch {
            await controller.finish()
            execution.cancel()
            _ = try? await execution.value
            throw error
        }
    }

    @MainActor
    func testCancelStreamCancelsEveryConcurrentStreamRegisteredToSameTab() async throws {
        let tabID = UUID()
        let streamIDs = [UUID(), UUID()]
        var nextStreamIndex = 0
        let controller = MultiOracleHeadlessTestStreamController()
        let installed = expectation(description: "both stream continuations installed")
        installed.expectedFulfillmentCount = 2
        let progressed = expectation(description: "both streams produced output")
        progressed.expectedFulfillmentCount = 2

        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let streamID = streamIDs[nextStreamIndex]
                nextStreamIndex += 1
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    Task {
                        await controller.install(continuation, for: streamID)
                        await MainActor.run { installed.fulfill() }
                    }
                    continuation.yield(ChatStreamOutput(text: "partial", reasoning: nil, tokens: ChatTokenInfo()))
                }
                return (streamID, stream)
            },
            cancelStream: { streamID in
                await controller.cancelAndFinish(streamID)
            },
            cleanupConversation: { _, _ in },
            timeout: .seconds(2)
        )
        let executions = (0 ..< 2).map { _ in
            Task { @MainActor in
                try await runtime.execute(
                    message: AIMessage(systemPrompt: "system", userMessage: "prompt"),
                    model: .claude4Sonnet,
                    tabID: tabID,
                    completionPolicy: .interactive,
                    onProgress: { _, _ in progressed.fulfill() }
                )
            }
        }

        await fulfillment(of: [installed, progressed], timeout: 1)
        XCTAssertTrue(runtime.hasActiveStream(for: tabID))
        await runtime.cancelStream(for: tabID)
        for execution in executions {
            let output = try await execution.value
            XCTAssertEqual(output.text, "partial")
        }
        let cancelledStreamIDs = await controller.cancelledStreamIDs()
        XCTAssertEqual(Set(cancelledStreamIDs), Set(streamIDs))
        XCTAssertFalse(runtime.hasActiveStream(for: tabID))
    }

    @MainActor
    func testCancellationWhileSendPromptIsPendingCancelsReturnedStream() async throws {
        let tabID = UUID()
        let streamID = UUID()
        let gate = OracleHeadlessSendPromptGate()
        let started = expectation(description: "sendPrompt started")

        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                started.fulfill()
                await gate.wait()
                return (
                    streamID,
                    AsyncThrowingStream<ChatStreamOutput, Error> { $0.finish() }
                )
            },
            cancelStream: { await gate.recordCancellation($0) },
            cleanupConversation: { _, _ in }
        )
        let execution = Task { @MainActor in
            try await runtime.execute(
                message: AIMessage(systemPrompt: "system", userMessage: "prompt"),
                model: .claude4Sonnet,
                tabID: tabID,
                completionPolicy: .interactive
            )
        }

        await fulfillment(of: [started], timeout: 1)
        await runtime.cancelStream(for: tabID)
        await gate.release()
        do {
            _ = try await execution.value
            XCTFail("Expected structural cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let cancelledStreamIDs = await gate.cancelledStreamIDs()
        XCTAssertEqual(cancelledStreamIDs, [streamID])
        XCTAssertFalse(runtime.hasActiveStream(for: tabID))
    }

    @MainActor
    func testCancelInvocationDoesNotCancelSuccessorOnSameTab() async throws {
        let tabID = UUID()
        let invocationIDs = [UUID(), UUID()]
        let streamIDs = [UUID(), UUID()]
        var nextStreamIndex = 0
        let controller = MultiOracleHeadlessTestStreamController()
        let installed = expectation(description: "both invocation streams installed")
        installed.expectedFulfillmentCount = 2
        let progressed = expectation(description: "both invocation streams produced output")
        progressed.expectedFulfillmentCount = 2

        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let streamID = streamIDs[nextStreamIndex]
                nextStreamIndex += 1
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    Task {
                        await controller.install(continuation, for: streamID)
                        await MainActor.run { installed.fulfill() }
                    }
                    continuation.yield(ChatStreamOutput(text: "partial", reasoning: nil, tokens: ChatTokenInfo()))
                }
                return (streamID, stream)
            },
            cancelStream: { streamID in
                await controller.cancelAndFinish(streamID)
            },
            cleanupConversation: { _, _ in },
            timeout: .seconds(2)
        )
        let first = Task { @MainActor in
            try await runtime.execute(
                message: AIMessage(systemPrompt: "system", userMessage: "first"),
                model: .claude4Sonnet,
                tabID: tabID,
                invocationID: invocationIDs[0],
                completionPolicy: .interactive,
                onProgress: { _, _ in progressed.fulfill() }
            )
        }
        let second = Task { @MainActor in
            try await runtime.execute(
                message: AIMessage(systemPrompt: "system", userMessage: "second"),
                model: .claude4Sonnet,
                tabID: tabID,
                invocationID: invocationIDs[1],
                completionPolicy: .interactive,
                onProgress: { _, _ in progressed.fulfill() }
            )
        }

        await fulfillment(of: [installed, progressed], timeout: 1)
        await runtime.cancelStream(invocationID: invocationIDs[0])
        let firstOutput = try await first.value
        XCTAssertEqual(firstOutput.text, "partial")
        XCTAssertTrue(runtime.hasActiveStream(for: tabID))
        let cancellationsAfterFirst = await controller.cancelledStreamIDs()
        XCTAssertEqual(cancellationsAfterFirst, [streamIDs[0]])

        await controller.finish(streamIDs[1])
        let secondOutput = try await second.value
        XCTAssertEqual(secondOutput.text, "partial")
        XCTAssertFalse(runtime.hasActiveStream(for: tabID))
        let finalCancellations = await controller.cancelledStreamIDs()
        XCTAssertEqual(finalCancellations, [streamIDs[0]])
    }

    @MainActor
    func testCancelAllCountsConcurrentPendingStreamsForSameTab() async throws {
        let tabID = UUID()
        let streamIDs = [UUID(), UUID()]
        let gate = MultiPendingOracleSendPromptGate()
        var nextIndex = 0
        let bothStarted = expectation(description: "both sendPrompt calls started")
        bothStarted.expectedFulfillmentCount = 2
        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let index = nextIndex
                nextIndex += 1
                bothStarted.fulfill()
                await gate.wait(index: index)
                return (
                    streamIDs[index],
                    AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                        continuation.yield(ChatStreamOutput(
                            text: "done",
                            reasoning: nil,
                            tokens: ChatTokenInfo(),
                            terminalOutcome: .completed
                        ))
                        continuation.finish()
                    }
                )
            },
            cancelStream: { await gate.recordCancellation($0) },
            cleanupConversation: { _, _ in }
        )
        let first = Task { @MainActor in
            try await runtime.execute(
                message: AIMessage(systemPrompt: "system", userMessage: "first"),
                model: .claude4Sonnet,
                tabID: tabID,
                completionPolicy: .interactive
            )
        }
        let second = Task { @MainActor in
            try await runtime.execute(
                message: AIMessage(systemPrompt: "system", userMessage: "second"),
                model: .claude4Sonnet,
                tabID: tabID,
                completionPolicy: .interactive
            )
        }
        await fulfillment(of: [bothStarted], timeout: 1)
        await gate.release(index: 0)
        let firstOutput = try await first.value
        XCTAssertEqual(firstOutput.text, "done")
        await runtime.cancelAllStreams()
        await gate.release(index: 1)
        do {
            _ = try await second.value
            XCTFail("Expected the still-pending stream to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        let cancelled = await gate.cancelledStreamIDs()
        XCTAssertEqual(cancelled, [streamIDs[1]])
    }
}

private actor MultiPendingOracleSendPromptGate {
    private var released: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var cancellations: [ChatStreamID] = []

    func wait(index: Int) async {
        guard !released.contains(index) else { return }
        await withCheckedContinuation { continuations[index] = $0 }
    }

    func release(index: Int) {
        released.insert(index)
        continuations.removeValue(forKey: index)?.resume()
    }

    func recordCancellation(_ streamID: ChatStreamID) {
        cancellations.append(streamID)
    }

    func cancelledStreamIDs() -> [ChatStreamID] {
        cancellations
    }
}

private actor OracleHeadlessSendPromptGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var cancellations: [ChatStreamID] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func recordCancellation(_ streamID: ChatStreamID) {
        cancellations.append(streamID)
    }

    func cancelledStreamIDs() -> [ChatStreamID] {
        cancellations
    }
}

private actor OracleHeadlessTestStreamController {
    private var continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation?
    private var cancellations: [ChatStreamID] = []

    func install(_ continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation) {
        self.continuation = continuation
    }

    func recordCancellation(_ streamID: ChatStreamID) {
        cancellations.append(streamID)
    }

    func hasInstalledContinuation() -> Bool {
        continuation != nil
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }

    func cancelledStreamIDs() -> [ChatStreamID] {
        cancellations
    }
}

private actor MultiOracleHeadlessTestStreamController {
    private var continuations: [ChatStreamID: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation] = [:]
    private var cancellations: [ChatStreamID] = []

    func install(
        _ continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation,
        for streamID: ChatStreamID
    ) {
        continuations[streamID] = continuation
    }

    func cancelAndFinish(_ streamID: ChatStreamID) {
        cancellations.append(streamID)
        continuations.removeValue(forKey: streamID)?.finish()
    }

    func finish(_ streamID: ChatStreamID) {
        continuations.removeValue(forKey: streamID)?.finish()
    }

    func cancelledStreamIDs() -> [ChatStreamID] {
        cancellations
    }
}
