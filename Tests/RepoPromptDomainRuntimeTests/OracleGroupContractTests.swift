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

    func testGenericModelSettingsDoNotInheritOracleRosterLengthLimit() throws {
        let longIdentifier = String(repeating: "m", count: OracleRosterContract.maximumModelIdentifierLength + 1)
        for key in ["models.preferred_compose_model", "context_builder.model"] {
            let descriptor = try XCTUnwrap(DomainAppSettingsCatalog.descriptor(for: key))
            XCTAssertNil(descriptor.maximumStringLength)
            XCTAssertEqual(
                try DomainAppSettingsCatalog.normalize(.string(longIdentifier), for: descriptor),
                .string(longIdentifier)
            )
        }
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

    func testConversationRouteRequiresToolSpecificMissingChatIDBehavior() throws {
        XCTAssertEqual(
            try OracleConversationRoute.resolve(
                chatID: nil,
                newChat: false,
                modelOverride: nil,
                whenMissingChatID: .startNew
            ),
            .start(primaryModelOverride: nil)
        )
        XCTAssertEqual(
            try OracleConversationRoute.resolve(
                chatID: nil,
                newChat: false,
                modelOverride: nil,
                whenMissingChatID: .continueCurrent
            ),
            .implicitContinuation
        )

        for behavior in [OracleMissingConversationBehavior.startNew, .continueCurrent] {
            XCTAssertEqual(
                try OracleConversationRoute.resolve(
                    chatID: "ignored-existing-chat",
                    newChat: true,
                    modelOverride: " primary-override ",
                    whenMissingChatID: behavior
                ),
                .start(primaryModelOverride: "primary-override")
            )
            XCTAssertEqual(
                try OracleConversationRoute.resolve(
                    chatID: " existing-chat ",
                    newChat: false,
                    modelOverride: nil,
                    whenMissingChatID: behavior
                ),
                .continuation(chatID: "existing-chat")
            )
        }
    }

    func testConversationRouteRejectsModelOverrideAndEmptyIDOnContinuation() {
        XCTAssertThrowsError(
            try OracleConversationRoute.resolve(
                chatID: "existing-chat",
                newChat: false,
                modelOverride: "different-model",
                whenMissingChatID: .continueCurrent
            )
        )
        XCTAssertThrowsError(
            try OracleConversationRoute.resolve(
                chatID: nil,
                newChat: false,
                modelOverride: "different-model",
                whenMissingChatID: .continueCurrent
            )
        )
        XCTAssertThrowsError(
            try OracleConversationRoute.resolve(
                chatID: "  ",
                newChat: false,
                modelOverride: nil,
                whenMissingChatID: .continueCurrent
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

    func testDecodedLaneAndModelReferencesEnforceValidatedInitializers() {
        assertDecodingThrows(
            OracleLaneID.self,
            json: #"{"index":-1}"#,
            expected: .invalidLaneIndex(-1)
        )
        assertDecodingThrows(
            OracleModelReference.self,
            json: #"{"providerID":null,"modelID":" "}"#,
            expected: .invalidModelIdentifier
        )
        assertDecodingThrows(
            OracleModelReference.self,
            json: #"{"providerID":" ","modelID":"model"}"#,
            expected: .invalidProviderIdentifier
        )
    }

    func testDecodedRosterAndDescriptorsEnforceValidatedInitializers() {
        let model = #"{"providerID":null,"modelID":"model"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                OracleRoster.self,
                from: Data(#"{"additional":[]}"#.utf8)
            )
        )
        assertDecodingThrows(
            OracleRoster.self,
            json: """
            {"primary":\(model),"additional":[\(model),\(model),\(model),\(model),\(model)]}
            """,
            expected: .invalidRosterCount(6)
        )
        assertDecodingThrows(
            OracleGroupDescriptor.self,
            json: #"{"id":"00000000-0000-0000-0000-000000000001","size":1}"#,
            expected: .invalidGroupSize(1)
        )
        assertDecodingThrows(
            OracleGroupDescriptor.self,
            json: #"{"id":"00000000-0000-0000-0000-000000000001","size":6}"#,
            expected: .invalidGroupSize(6)
        )
        assertDecodingThrows(
            OracleLaneDescriptor.self,
            json: """
            {
              "group":{"id":"00000000-0000-0000-0000-000000000001","size":2},
              "laneID":{"index":2},
              "model":\(model)
            }
            """,
            expected: .invalidLaneIndex(2)
        )
    }

    func testDecodedOwnerInputAndMembersEnforceValidatedInitializers() {
        assertDecodingThrows(
            OracleConversationOwner.self,
            json: #"{"kind":" ","identifier":"owner"}"#,
            expected: .invalidConversationOwner
        )
        assertDecodingThrows(
            OracleConversationOwner.self,
            json: #"{"kind":"window","identifier":" "}"#,
            expected: .invalidConversationOwner
        )
        assertDecodingThrows(
            OracleInput.self,
            json: #"{"mode":"chat","userMessage":" ","context":null}"#,
            expected: .invalidUserMessage
        )
        assertDecodingThrows(
            OracleGroupMember.self,
            json: """
            {
              "laneID":{"index":0},
              "memberID":"00000000-0000-0000-0000-000000000002",
              "publicChatID":" ",
              "model":{"providerID":null,"modelID":"model"},
              "providerConversationID":null
            }
            """,
            expected: .invalidPublicChatID
        )
        assertDecodingThrows(
            OracleMemberLookup.self,
            json: #"{"publicChatID":" "}"#,
            expected: .invalidPublicChatID
        )
    }

    func testDecodedFrozenPackEnforcesContentAndCanonicalSchema() throws {
        assertDecodingThrows(
            OracleFrozenContextPack.self,
            json: #"{"schemaVersion":1,"mode":"chat","content":" ","provenance":[]}"#,
            expected: .invalidFrozenPack
        )

        let pack = try OracleFrozenContextPack(mode: .chat, content: "context")
        let current = try pack.canonicalData()
        let future = try XCTUnwrap(
            String(data: current, encoding: .utf8)?
                .replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":2"#)
                .data(using: .utf8)
        )
        XCTAssertThrowsError(try OracleFrozenContextPack.decodeCanonical(future)) { error in
            XCTAssertEqual(error as? OracleGroupContractError, .invalidFrozenPack)
        }
        let noncanonical = Data(
            #"{"schemaVersion":1,"mode":"chat","content":"context","provenance":[]}"#.utf8
        )
        XCTAssertThrowsError(try OracleFrozenContextPack.decodeCanonical(noncanonical)) { error in
            XCTAssertEqual(error as? OracleGroupContractError, .invalidFrozenPack)
        }
        XCTAssertEqual(try OracleFrozenContextPack.decodeCanonical(current), pack)
    }

    func testValidatedOracleContractsRoundTripWithoutWireChanges() throws {
        let laneID = try OracleLaneID(index: 1)
        let model = try OracleModelReference(providerID: " provider ", modelID: " model ")
        let roster = try OracleRoster(primary: model)
        let groupID = OracleGroupID(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        )
        let group = try OracleGroupDescriptor(id: groupID, size: 2)
        let lane = try OracleLaneDescriptor(group: group, laneID: laneID, model: model)
        let owner = try OracleConversationOwner(kind: " window ", identifier: " owner ")
        let pack = try OracleFrozenContextPack(mode: .chat, content: "context")
        let input = try OracleInput(mode: .chat, userMessage: " question ")
        let member = try OracleGroupMember(laneID: laneID, publicChatID: " chat ", model: model)
        let lookup = try OracleMemberLookup(publicChatID: " chat ")

        try assertRoundTrip(laneID)
        try assertRoundTrip(model)
        try assertRoundTrip(roster)
        try assertRoundTrip(group)
        try assertRoundTrip(lane)
        try assertRoundTrip(owner)
        try assertRoundTrip(pack)
        try assertRoundTrip(input)
        try assertRoundTrip(member)
        try assertRoundTrip(lookup)
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

    func testPartialFailureFixtureRetainsFailedAndCancelledLanesInOrder() throws {
        let result = try decodeFixture("oracle-group-partial-failure")
        XCTAssertEqual(result.status, .partialFailure)
        XCTAssertEqual(result.oracleResults.map(\.laneIndex), [0, 1, 2])
        XCTAssertEqual(result.oracleResults.map(\.status), [.completed, .failed, .cancelled])
        XCTAssertEqual(result.warnings.map(\.code), ["lane_failures"])
    }

    func testTerminalTurnRoundTripRetainsStatusWarningsAndOrderedResults() throws {
        let results = try [
            OracleLaneResult(
                laneIndex: 0,
                chatID: "primary",
                providerID: "fixture",
                modelID: "primary-model",
                status: .completed,
                response: "primary response"
            ),
            OracleLaneResult(
                laneIndex: 1,
                chatID: "additional",
                providerID: "fixture",
                modelID: "additional-model",
                status: .failed,
                error: OracleLaneError(code: "provider_error", message: "failed")
            ),
        ]
        let warning = OracleGroupWarning(code: "lane_failures", message: "One lane did not complete")
        let turn = OracleTurnRecord(
            input: try OracleInput(mode: .chat, userMessage: "question"),
            state: .terminal,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            status: .partialFailure,
            warnings: [warning],
            results: results
        )

        let decoded = try JSONDecoder().decode(
            OracleTurnRecord.self,
            from: JSONEncoder().encode(turn)
        )
        XCTAssertEqual(decoded.status, .partialFailure)
        XCTAssertEqual(decoded.warnings, [warning])
        XCTAssertEqual(decoded.results, results)
    }

    func testTurnDecodingDefaultsMissingWarningsToEmpty() throws {
        let turn = OracleTurnRecord(
            input: try OracleInput(mode: .chat, userMessage: "question"),
            state: .prepared,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(turn)) as? [String: Any]
        )
        object.removeValue(forKey: "warnings")

        let decoded = try JSONDecoder().decode(
            OracleTurnRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.warnings, [])
        XCTAssertEqual(decoded.results, [])
        XCTAssertNil(decoded.status)
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

        let oracleSend = try XCTUnwrap(
            MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.oracleSend)
        )
        let sendProperties = try properties(of: oracleSend)
        guard case let .object(sendModelSchema)? = sendProperties["model"] else {
            return XCTFail("oracle_send.model missing")
        }
        XCTAssertEqual(
            sendModelSchema["maxLength"],
            .int(OracleRosterContract.maximumModelIdentifierLength)
        )
        XCTAssertTrue(oracleSend.description.contains("selected eligible conversation"))
        XCTAssertTrue(oracleSend.description.contains("new_chat=true"))
        XCTAssertTrue(
            String(describing: sendProperties["new_chat"]).contains("most recent eligible conversation")
        )
    }

    private func assertDecodingThrows<T: Decodable>(
        _ type: T.Type,
        json: String,
        expected: OracleGroupContractError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try JSONDecoder().decode(type, from: Data(json.utf8)),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? OracleGroupContractError, expected, file: file, line: line)
        }
    }

    private func assertRoundTrip<T: Codable & Equatable>(
        _ value: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(
            try JSONDecoder().decode(T.self, from: encoded),
            value,
            file: file,
            line: line
        )
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
