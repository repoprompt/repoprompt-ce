import Foundation
@testable import RepoPromptApp
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

    @MainActor
    func testCancelStreamTargetsOnlyRegisteredTabStream() async throws {
        let tabID = UUID()
        let streamID = UUID()
        let controller = OracleHeadlessTestStreamController()

        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    Task { await controller.install(continuation) }
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

        for _ in 0 ..< 100 where !runtime.hasActiveStream(for: tabID) {
            await Task.yield()
        }
        XCTAssertTrue(runtime.hasActiveStream(for: tabID))

        await runtime.cancelStream(for: tabID)
        let output = try await execution.value

        XCTAssertEqual(output.text, "partial")
        let cancelledStreamIDs = await controller.cancelledStreamIDs()
        XCTAssertEqual(cancelledStreamIDs, [streamID])
        XCTAssertFalse(runtime.hasActiveStream(for: tabID))
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

    func finish() {
        continuation?.finish()
        continuation = nil
    }

    func cancelledStreamIDs() -> [ChatStreamID] {
        cancellations
    }
}
