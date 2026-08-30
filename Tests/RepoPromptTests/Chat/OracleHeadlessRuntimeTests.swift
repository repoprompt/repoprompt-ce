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
}
