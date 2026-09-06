import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class AgentMCPModelParameterSupportTests: XCTestCase {
    func testCursorDefinitionsPreserveExactWireIdentifiersAndChoices() {
        let definitions = AgentMCPModelParameterSupport.definitions(modelRaw: "grok-4.6")

        XCTAssertEqual(definitions.count, 2)
        XCTAssertEqual(definitions[0].configID, "effort")
        XCTAssertEqual(definitions[0].choices.map(\.rawValue), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(definitions[1].configID, "fast")
        XCTAssertEqual(definitions[1].choices.map(\.rawValue), ["false", "true"])
    }

    func testResolveRejectsUnknownConfigBeforeProducingSelections() throws {
        let requested: Value = .array([
            .object(["config_id": .string("unknown"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok-4.6"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("unknown"))
        }
    }

    func testResolveRejectsUnknownValueBeforeProducingSelections() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("maximum")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok-4.6"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("maximum"))
        }
    }

    func testResolvePreservesExactProviderWireValueAndCanonicalBase() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("HIGH")]),
            .object(["config_id": .string("fast"), "value": .string("true")])
        ])

        let selections = try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "Cursor Grok 4.6"
        )

        XCTAssertEqual(selections.map(\.configID), ["effort", "fast"])
        XCTAssertEqual(selections.map(\.valueRaw), ["high", "true"])
        XCTAssertEqual(selections.map(\.baseModelRaw), ["grok-4.6", "grok-4.6"])
    }

    func testResolveCanonicalizesLegacyComposer2BaseModel() throws {
        let selections = try AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string("fast"), "value": .string("true")])
            ]),
            agent: .cursor,
            modelRaw: "composer-2"
        )

        XCTAssertEqual(selections.map(\.baseModelRaw), ["composer-2.5"])
        XCTAssertEqual(selections.map(\.configID), ["fast"])
        XCTAssertEqual(selections.map(\.valueRaw), ["true"])
    }

    func testResolveRejectsWhitespaceBearingProviderConfigID() throws {
        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string(" effort "), "value": .string("high")])
            ]),
            agent: .cursor,
            modelRaw: "grok-4.6"
        ))
    }

    func testResolveRejectsDuplicateConfigIDs() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("low")]),
            .object(["config_id": .string("effort"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok-4.6"
        ))
    }

    func testNonCursorProviderRejectsModelParameters() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .openCode,
            modelRaw: "grok"
        ))
    }

    func testAgentRunSnapshotPublishesEffectiveModelParameterSelections() throws {
        let snapshot = AgentRunMCPSnapshot(
            sessionID: UUID(),
            tabID: UUID(),
            sessionName: "Cursor run",
            agentRaw: AgentProviderKind.cursor.rawValue,
            agentDisplayName: "Cursor",
            modelRaw: "grok",
            reasoningEffortRaw: nil,
            modelParameterSelections: [
                .init(
                    providerID: ACPProviderID.cursor.rawValue,
                    baseModelRaw: "grok",
                    kind: ACPModelParameterKind.thinking.rawValue,
                    configID: "thought_level",
                    valueRaw: "high"
                )
            ],
            status: .running,
            statusText: nil,
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )

        let parameter = try XCTUnwrap(
            snapshot.asObject()["agent"]?.objectValue?["model_parameters"]?.arrayValue?.first?.objectValue
        )
        XCTAssertEqual(parameter["provider_id"]?.stringValue, "cursor")
        XCTAssertEqual(parameter["base_model"]?.stringValue, "grok")
        XCTAssertEqual(parameter["kind"]?.stringValue, "thinking")
        XCTAssertEqual(parameter["config_id"]?.stringValue, "thought_level")
        XCTAssertEqual(parameter["value"]?.stringValue, "high")
    }

    func testEffectiveSelectionsExcludeOtherCursorBaseModels() {
        let selections = [
            ACPModelParameterSelection(
                providerID: .cursor,
                baseModelRaw: "grok-4.6",
                kind: .thinking,
                configID: "Cursor.Thought-Level",
                valueRaw: "high"
            ),
            ACPModelParameterSelection(
                providerID: .cursor,
                baseModelRaw: "composer-2",
                kind: .speed,
                configID: "model_config",
                valueRaw: "fast"
            )
        ]

        XCTAssertEqual(
            AgentMCPModelParameterSupport.effectiveSelections(
                selections,
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: "Grok 4.6"
            ),
            [
                ACPModelParameterSelection(
                    providerID: .cursor,
                    baseModelRaw: "grok-4.6",
                    kind: .thinking,
                    configID: "effort",
                    valueRaw: "high"
                ),
                ACPModelParameterSelection(
                    providerID: .cursor,
                    baseModelRaw: "grok-4.6",
                    kind: .speed,
                    configID: "fast",
                    valueRaw: "true"
                )
            ]
        )
    }
}
