import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class OracleGroupContractTests: XCTestCase {
    func testDisplayLabelUsesOracleAndNumberedLanes() {
        XCTAssertEqual(
            (0 ... 4).map(OracleRosterContract.displayLabel(laneIndex:)),
            ["Oracle", "Oracle 2", "Oracle 3", "Oracle 4", "Oracle 5"]
        )
    }

    func testRosterDescriptorNormalizesOrderedStringArrayWithoutDeduplicating() throws {
        let descriptor = try XCTUnwrap(
            DomainAppSettingsCatalog.descriptor(for: OracleRosterContract.additionalSettingKey)
        )
        XCTAssertEqual(descriptor, OracleRosterSettingsDescriptor.additional)
        XCTAssertEqual(descriptor.valueKind, .stringArray)
        XCTAssertEqual(descriptor.maximumArrayCount, 4)
        XCTAssertFalse(descriptor.allowsNull)

        let normalized = try DomainAppSettingsCatalog.normalize(
            .stringArray([" model-a ", "model-a", "model-b"]),
            for: descriptor
        )
        XCTAssertEqual(normalized, .stringArray(["model-a", "model-a", "model-b"]))
        XCTAssertEqual(normalized.mcpValue, .array([.string("model-a"), .string("model-a"), .string("model-b")]))
    }

    func testRosterNormalizationDoesNotAlterUnrelatedScalarStrings() throws {
        let descriptor = try XCTUnwrap(
            DomainAppSettingsCatalog.descriptor(for: "file_system.global_ignore_defaults")
        )
        let value = DomainSettingValue.string("  **/Generated Files/**\n")
        XCTAssertEqual(try DomainAppSettingsCatalog.normalize(value, for: descriptor), value)
    }

    func testRosterDescriptorRejectsInvalidArrays() throws {
        let descriptor = OracleRosterSettingsDescriptor.additional
        XCTAssertThrowsError(
            try DomainAppSettingsCatalog.normalize(
                .stringArray(["a", "b", "c", "d", "e"]),
                for: descriptor
            )
        )
        XCTAssertThrowsError(
            try DomainAppSettingsCatalog.normalize(.stringArray(["ok", "  "]), for: descriptor)
        )
        XCTAssertThrowsError(try DomainAppSettingsCatalog.normalize(.null, for: descriptor))
        XCTAssertNil(DomainSettingValue(mcpValue: .array([.string("ok"), .int(1)])))
    }

    func testAskOracleRouteIsExplicitAndModelOverrideIsStartOnly() throws {
        XCTAssertEqual(
            try OracleConversationRoute.resolve(chatID: nil, newChat: false, modelOverride: nil),
            .start(primaryModelOverride: nil)
        )
        XCTAssertEqual(
            try OracleConversationRoute.resolve(
                chatID: "ignored-existing-chat",
                newChat: true,
                modelOverride: " primary-override "
            ),
            .start(primaryModelOverride: "primary-override")
        )
        XCTAssertEqual(
            try OracleConversationRoute.resolve(chatID: " existing-chat ", newChat: false, modelOverride: nil),
            .continuation(chatID: "existing-chat")
        )
        XCTAssertThrowsError(
            try OracleConversationRoute.resolve(
                chatID: "existing-chat",
                newChat: false,
                modelOverride: "different-model"
            )
        )
    }

    func testRosterPreservesPrimaryAndOrderedAdditionalModels() throws {
        let roster = try OracleRoster(
            primaryModelID: "primary",
            additionalModelIDs: ["second", "second", "third"],
            providerID: "provider"
        )
        XCTAssertEqual(roster.count, 4)
        XCTAssertEqual(roster.orderedModels.map(\.modelID), ["primary", "second", "second", "third"])
        XCTAssertEqual(roster.orderedModels.map(\.providerID), Array(repeating: "provider", count: 4))
    }

    func testInputAndLaneResultsRejectWhitespaceOnlyPayloads() throws {
        XCTAssertThrowsError(try OracleInput(mode: .chat, userMessage: " \n "))
        XCTAssertEqual(
            try OracleInput(mode: .chat, userMessage: "  message  ").userMessage,
            "message"
        )
        XCTAssertThrowsError(try OracleLaneResult(
            laneIndex: 0,
            chatID: "chat",
            providerID: "  ",
            modelID: "model",
            status: .completed,
            response: "answer"
        ))
        XCTAssertThrowsError(try OracleLaneResult(
            laneIndex: 0,
            chatID: "chat",
            providerID: "provider",
            modelID: "model",
            status: .completed,
            response: " \n "
        ))
        XCTAssertThrowsError(try OracleLaneResult(
            laneIndex: 1,
            chatID: "chat",
            providerID: "provider",
            modelID: "model",
            status: .failed,
            error: OracleLaneError(code: " ", message: "failure")
        ))
    }

    func testCompletedResultFixtureRoundTripsCanonicalShape() throws {
        let result = try decodeFixture("oracle-group-completed")
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.oracleCount, 2)
        XCTAssertEqual(result.primary.role, .primary)
        XCTAssertEqual(result.oracleResults[1].role, .additional)
        XCTAssertTrue(result.oracleResults.allSatisfy { $0.executionProfile == nil })
        XCTAssertEqual(try JSONDecoder().decode(OracleGroupResult.self, from: JSONEncoder().encode(result)), result)
    }

    func testExecutionProfileRoundTripsAndUsesCanonicalMCPShape() throws {
        let profile = try OracleExecutionProfile(
            providerID: " codex ",
            modelID: " gpt-5.6-sol ",
            effectiveReasoningEffort: " high "
        )
        let result = try OracleLaneResult(
            laneIndex: 0,
            chatID: "chat",
            providerID: nil,
            modelID: "configured-raw",
            status: .completed,
            executionProfile: profile,
            response: "answer"
        )

        XCTAssertEqual(profile.providerID, "codex")
        XCTAssertEqual(profile.modelID, "gpt-5.6-sol")
        XCTAssertEqual(profile.effectiveReasoningEffort, "high")
        XCTAssertEqual(try JSONDecoder().decode(
            OracleLaneResult.self,
            from: JSONEncoder().encode(result)
        ), result)

        guard case let .object(lane) = OracleGroupMCPCodec.laneValue(result),
              case let .object(encodedProfile)? = lane["execution_profile"]
        else {
            return XCTFail("missing execution profile")
        }
        XCTAssertEqual(encodedProfile["provider_id"], .string("codex"))
        XCTAssertEqual(encodedProfile["model_id"], .string("gpt-5.6-sol"))
        XCTAssertEqual(encodedProfile["effective_reasoning_effort"], .string("high"))
    }

    func testSynthesisRecordsExactCompletedLaneSetAndIsIdempotent() throws {
        let roster = try OracleRoster(primaryModelID: "primary", additionalModelIDs: ["secondary"])
        let group = try OracleGroupDescriptor(size: roster.count)
        let members = try roster.orderedModels.enumerated().map { index, model in
            try OracleGroupMember(
                laneID: OracleLaneID(index: index),
                publicChatID: "chat-\(index)",
                model: model
            )
        }
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let prepared = try OracleGroupDocument(
            group: group,
            owner: OracleConversationOwner(kind: "test", identifier: "synthesis"),
            name: "Synthesis",
            revision: 1,
            createdAt: startedAt,
            updatedAt: startedAt,
            roster: roster,
            members: members,
            turns: [OracleTurnRecord(
                input: OracleInput(mode: .plan, userMessage: "Plan"),
                state: .prepared,
                startedAt: startedAt
            )]
        )
        let laneResults = try members.map { member in
            try OracleLaneResult(
                laneIndex: member.laneID.index,
                chatID: member.publicChatID,
                providerID: member.model.providerID,
                modelID: member.model.modelID,
                status: .completed,
                response: "lane-\(member.laneID.index)"
            )
        }
        let terminal = try prepared.settling(
            OracleGroupResult(groupID: group.id, status: .completed, oracleResults: laneResults),
            finishedAt: startedAt.addingTimeInterval(1)
        )
        let turnID = try XCTUnwrap(terminal.turns.last?.id)
        let model = try OracleExecutionProfile(providerID: "codex", modelID: "gpt-5.6-sol")
        let synthesis = try OracleSynthesisRecord(
            model: model,
            sourceLaneIndices: [0, 1],
            response: "combined",
            finishedAt: startedAt.addingTimeInterval(2)
        )

        let recorded = try terminal.recordingSynthesis(synthesis, for: turnID)
        XCTAssertEqual(recorded.revision, terminal.revision + 1)
        XCTAssertEqual(recorded.turns.last?.results, terminal.turns.last?.results)
        XCTAssertEqual(recorded.turns.last?.synthesis, synthesis)
        XCTAssertEqual(try recorded.recordingSynthesis(synthesis, for: turnID), recorded)
        XCTAssertEqual(
            try JSONDecoder().decode(OracleGroupDocument.self, from: JSONEncoder().encode(recorded)),
            recorded
        )

        let wrongSources = try OracleSynthesisRecord(
            model: model,
            sourceLaneIndices: [0, 2],
            response: "combined",
            finishedAt: startedAt.addingTimeInterval(2)
        )
        XCTAssertThrowsError(try terminal.recordingSynthesis(wrongSources, for: turnID)) {
            XCTAssertEqual($0 as? OracleGroupContractError, .invalidSynthesisRecord)
        }
        let overwrite = try OracleSynthesisRecord(
            model: model,
            sourceLaneIndices: [0, 1],
            response: "different",
            finishedAt: startedAt.addingTimeInterval(2)
        )
        XCTAssertThrowsError(try recorded.recordingSynthesis(overwrite, for: turnID)) {
            XCTAssertEqual($0 as? OracleGroupContractError, .synthesisAlreadyRecorded)
        }
    }

    func testPartialFailureFixtureRetainsFailedAndCancelledLanesInOrder() throws {
        let result = try decodeFixture("oracle-group-partial-failure")
        XCTAssertEqual(result.status, .partialFailure)
        XCTAssertEqual(result.oracleResults.map(\.laneIndex), [0, 1, 2])
        XCTAssertEqual(result.oracleResults.map(\.status), [.completed, .failed, .cancelled])
        XCTAssertEqual(result.warnings.map(\.code), ["lane_failures"])
    }

    func testCanonicalToolSchemasExposeRosterArrayAndStartOnlyModelOverride() throws {
        let appSettings = try XCTUnwrap(
            MCPDomainCanonicalToolDefinitions.definition(named: MCPGlobalToolName.appSettings)
        )
        let appProperties = try properties(of: appSettings)
        guard case let .object(valueSchema)? = appProperties["value"],
              case let .array(anyOf)? = valueSchema["anyOf"]
        else {
            return XCTFail("app_settings.value must be anyOf")
        }
        let arraySchema = try XCTUnwrap(anyOf.first { value in
            guard case let .object(schema) = value else { return false }
            return schema["type"] == .string("array")
        })
        guard case let .object(arrayObject) = arraySchema else { return XCTFail("missing array schema") }
        XCTAssertEqual(arrayObject["maxItems"], .int(OracleRosterContract.maximumAdditionalCount))

        let askOracle = try XCTUnwrap(
            MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.askOracle)
        )
        let askProperties = try properties(of: askOracle)
        guard case let .object(modelSchema)? = askProperties["model"] else {
            return XCTFail("ask_oracle.model missing")
        }
        XCTAssertEqual(modelSchema["type"], .string("string"))
        XCTAssertEqual(modelSchema["maxLength"], .int(OracleRosterContract.maximumModelIdentifierLength))
        XCTAssertNotNil(askProperties["new_chat"])
        XCTAssertNil(askProperties["provider"])
    }

    private func decodeFixture(_ name: String) throws -> OracleGroupResult {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try JSONDecoder().decode(OracleGroupResult.self, from: Data(contentsOf: url))
    }

    private func properties(of definition: MCPDomainToolDefinition) throws -> [String: Value] {
        guard case let .object(schema) = definition.inputSchema,
              case let .object(properties)? = schema["properties"]
        else {
            throw TestError.missingProperties
        }
        return properties
    }

    private enum TestError: Error {
        case missingProperties
    }
}
