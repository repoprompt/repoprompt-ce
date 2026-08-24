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
