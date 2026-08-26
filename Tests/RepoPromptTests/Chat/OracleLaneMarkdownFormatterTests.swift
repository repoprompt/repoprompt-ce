import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class OracleLaneMarkdownFormatterTests: XCTestCase {
    func testFormatterUsesCanonicalOrderLabelsMetadataAndFailureWording() throws {
        let payload = OracleLaneMarkdownPayload(lanes: [
            .init(
                laneIndex: 1,
                chatID: "chat-1",
                providerID: "codex",
                modelID: "gpt-5.6-sol",
                effectiveReasoningEffort: "high",
                status: .failed,
                response: nil,
                partialResponse: "partial adviser answer",
                errorCode: "provider_failed",
                errorMessage: "provider exploded"
            ),
            .init(
                laneIndex: 0,
                chatID: "chat-0",
                providerID: nil,
                modelID: "configured-primary",
                effectiveReasoningEffort: nil,
                status: .completed,
                response: "primary answer",
                partialResponse: nil,
                errorCode: nil,
                errorMessage: nil
            )
        ])

        let markdown = OracleLaneMarkdownFormatter.format(payload)
        let primary = try XCTUnwrap(markdown.range(of: "### Oracle\n"))
        let additional = try XCTUnwrap(markdown.range(of: "### Oracle 2\n"))
        XCTAssertLessThan(primary.lowerBound, additional.lowerBound)
        XCTAssertTrue(markdown.contains("- Provider: Provider default / not specified"), markdown)
        XCTAssertTrue(markdown.contains("- Effective effort: `high`"), markdown)
        XCTAssertTrue(markdown.contains("Partial response:\npartial adviser answer"), markdown)
        XCTAssertTrue(markdown.contains("Error [provider_failed]: provider exploded"), markdown)
    }

    func testTerminalPayloadUsesDurableResultsAndExactExecutionProfile() throws {
        let startedAt = Date(timeIntervalSince1970: 1000)
        let fixture = try makeGroup(startedAt: startedAt, terminal: true)
        let forged = ChatSession(
            id: fixture.members[0].memberID.rawValue,
            oracleModelRaw: "mutable-settings-model",
            messages: [StoredMessage(
                isUser: false,
                rawText: "mutable session answer",
                timestamp: startedAt.addingTimeInterval(10)
            )]
        )

        let payload = OracleGroupLanePayloadLoader.payload(
            group: fixture.group,
            sessions: [forged],
            liveMessages: { _ in [AIChatMessage(content: "mutable live answer", isUser: false)] }
        )
        XCTAssertEqual(payload.lanes.map(\.laneIndex), [0, 1, 2])
        XCTAssertEqual(payload.lanes[0].providerID, "runtime-provider-0")
        XCTAssertEqual(payload.lanes[0].modelID, "runtime-model-0")
        XCTAssertEqual(payload.lanes[0].effectiveReasoningEffort, "high")
        XCTAssertEqual(payload.lanes[0].response, "durable primary answer")
        XCTAssertFalse(OracleLaneMarkdownFormatter.format(payload).contains("mutable"))
    }

    func testCopyAllVisibilityUsesCanonicalGroupIdentity() {
        XCTAssertTrue(AgentOraclePillLogic.canCopyAll(ChatSession(oracleGroupID: UUID(), oracleGroupSize: 2)))
        XCTAssertFalse(AgentOraclePillLogic.canCopyAll(ChatSession(oracleGroupSize: 2)))
    }

    func testPreparedPayloadUsesCurrentPartialTextAndExplicitRunningFailedUnavailableStates() throws {
        let startedAt = Date(timeIntervalSince1970: 2000)
        let fixture = try makeGroup(startedAt: startedAt, terminal: false)
        let priorUser = StoredMessage(isUser: true, rawText: "old question", timestamp: startedAt.addingTimeInterval(-20))
        let priorAnswer = StoredMessage(isUser: false, rawText: "old answer", timestamp: startedAt.addingTimeInterval(-19))
        let lane0 = ChatSession(
            id: fixture.members[0].memberID.rawValue,
            messages: [priorUser, priorAnswer]
        )
        let lane1 = ChatSession(id: fixture.members[1].memberID.rawValue)
        let currentUser0 = AIChatMessage(content: "current question", isUser: true, sequenceIndex: 2)
        let currentAnswer0 = AIChatMessage(content: "current partial", isUser: false, sequenceIndex: 3)
        let currentUser1 = AIChatMessage(content: "current question", isUser: true, sequenceIndex: 0)
        let failedAnswer1 = AIChatMessage(
            content: "adviser partial\n\n--\nError:\nprovider exploded",
            isUser: false,
            sequenceIndex: 1
        )
        let messages = [
            lane0.id: [currentUser0, currentAnswer0],
            lane1.id: [currentUser1, failedAnswer1]
        ]

        let payload = OracleGroupLanePayloadLoader.payload(
            group: fixture.group,
            sessions: [lane1, lane0],
            liveMessages: { messages[$0] ?? [] }
        )
        XCTAssertEqual(payload.lanes.map(\.status), [.running, .running, .unavailable])
        XCTAssertEqual(payload.lanes[0].partialResponse, "current partial")
        XCTAssertEqual(
            payload.lanes[1].partialResponse,
            "adviser partial\n\n--\nError:\nprovider exploded"
        )
        XCTAssertNil(payload.lanes[1].errorMessage)

        let markdown = OracleLaneMarkdownFormatter.format(payload)
        XCTAssertTrue(markdown.contains("- Status: Running"), markdown)
        XCTAssertTrue(markdown.contains("- Status: Unavailable"), markdown)
        XCTAssertTrue(markdown.contains("Response unavailable."), markdown)
        XCTAssertFalse(markdown.contains("old answer"), markdown)
        XCTAssertTrue(markdown.contains("adviser partial\n\n--\nError:\nprovider exploded"), markdown)
    }

    func testTerminalCancelledStatusAndResponseWhitespaceArePreserved() throws {
        let startedAt = Date(timeIntervalSince1970: 1000)
        let fixture = try makeGroup(startedAt: startedAt, terminal: true)
        let payload = OracleGroupLanePayloadLoader.payload(
            group: fixture.group,
            sessions: [],
            liveMessages: { _ in [] }
        )
        XCTAssertEqual(payload.lanes.map(\.status), [.completed, .failed, .cancelled])
        XCTAssertEqual(payload.lanes[0].response, "durable primary answer")
        XCTAssertEqual(payload.lanes[2].errorCode, "cancelled")

        let whitespace = OracleLaneMarkdownPayload(lanes: [
            .init(
                laneIndex: 0,
                chatID: "chat-0",
                providerID: "  codex  ",
                modelID: "  gpt-5.6-sol  ",
                effectiveReasoningEffort: "  high  ",
                status: .completed,
                response: "  leading and trailing  ",
                partialResponse: nil,
                errorCode: nil,
                errorMessage: nil
            )
        ])
        let whitespaceMarkdown = OracleLaneMarkdownFormatter.format(whitespace)
        XCTAssertTrue(whitespaceMarkdown.contains("  leading and trailing  "), whitespaceMarkdown)
        XCTAssertTrue(whitespaceMarkdown.contains("- Provider: `codex`"), whitespaceMarkdown)
        XCTAssertTrue(whitespaceMarkdown.contains("- Model: `gpt-5.6-sol`"), whitespaceMarkdown)
        XCTAssertTrue(whitespaceMarkdown.contains("- Effective effort: `high`"), whitespaceMarkdown)
        XCTAssertTrue(OracleLaneMarkdownFormatter.format(payload).contains("- Status: Cancelled"))
    }

    private func makeGroup(
        startedAt: Date,
        terminal: Bool
    ) throws -> (group: OracleGroupDocument, members: [OracleGroupMember]) {
        let roster = try OracleRoster(
            primary: OracleModelReference(providerID: nil, modelID: "configured-primary"),
            additional: [
                OracleModelReference(providerID: "configured-provider-1", modelID: "configured-additional-1"),
                OracleModelReference(providerID: nil, modelID: "configured-additional-2")
            ]
        )
        let descriptor = try OracleGroupDescriptor(size: roster.count)
        let members = try roster.orderedModels.enumerated().map { index, model in
            try OracleGroupMember(
                laneID: OracleLaneID(index: index),
                publicChatID: "chat-\(index)",
                model: model
            )
        }
        let results: [OracleLaneResult] = if terminal {
            try [
                OracleLaneResult(
                    laneIndex: 0,
                    chatID: "chat-0",
                    providerID: nil,
                    modelID: "configured-primary",
                    status: .completed,
                    executionProfile: OracleExecutionProfile(
                        providerID: "runtime-provider-0",
                        modelID: "runtime-model-0",
                        effectiveReasoningEffort: "high"
                    ),
                    response: "durable primary answer"
                ),
                OracleLaneResult(
                    laneIndex: 1,
                    chatID: "chat-1",
                    providerID: "configured-provider-1",
                    modelID: "configured-additional-1",
                    status: .failed,
                    error: OracleLaneError(
                        code: "provider_failed",
                        message: "durable failure",
                        partialResponse: "durable partial"
                    )
                ),
                OracleLaneResult(
                    laneIndex: 2,
                    chatID: "chat-2",
                    providerID: nil,
                    modelID: "configured-additional-2",
                    status: .cancelled,
                    error: OracleLaneError(code: "cancelled", message: "cancelled")
                )
            ]
        } else {
            []
        }
        let turn = try OracleTurnRecord(
            input: OracleInput(mode: .plan, userMessage: "question"),
            state: terminal ? .terminal : .prepared,
            startedAt: startedAt,
            finishedAt: terminal ? startedAt.addingTimeInterval(10) : nil,
            results: results
        )
        let group = try OracleGroupDocument(
            group: descriptor,
            owner: OracleConversationOwner(kind: "test", identifier: UUID().uuidString),
            name: "Test Group",
            revision: 1,
            createdAt: startedAt,
            updatedAt: startedAt,
            roster: roster,
            members: members,
            turns: [turn]
        )
        return (group, members)
    }

    private func laneValue(index: Int, response: String) -> Value {
        .object([
            "lane_index": .int(index),
            "role": .string(index == 0 ? "primary" : "additional"),
            "chat_id": .string("chat-\(index)"),
            "provider_id": .string("configured-provider-\(index)"),
            "model_id": .string("configured-model-\(index)"),
            "status": .string("completed"),
            "execution_profile": .object([
                "provider_id": .string("runtime-provider-\(index)"),
                "model_id": .string("runtime-model-\(index)"),
                "effective_reasoning_effort": .string(index == 0 ? "high" : "medium")
            ]),
            "response": .string(response)
        ])
    }

    private func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let block = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = block else {
            throw XCTSkip("Expected text output")
        }
        return text
    }
}
