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
