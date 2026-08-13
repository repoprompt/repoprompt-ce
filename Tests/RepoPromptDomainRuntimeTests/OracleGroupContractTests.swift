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
        XCTAssertEqual(try JSONDecoder().decode(OracleGroupResult.self, from: JSONEncoder().encode(result)), result)
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
