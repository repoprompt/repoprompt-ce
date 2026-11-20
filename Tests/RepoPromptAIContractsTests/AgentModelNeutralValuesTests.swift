import Foundation
@testable import RepoPromptAIContracts
import XCTest

final class AgentModelNeutralValuesTests: XCTestCase {
    func testSelectionIDPreservesColonAndRejectsLegacyAndMalformedIDs() {
        let parsed = AgentModelSelectionID.parse("  openCode:vendor:model-v1  ")
        XCTAssertEqual(parsed?.agentRaw, "openCode")
        XCTAssertEqual(parsed?.modelRaw, "vendor:model-v1")
        XCTAssertEqual(parsed?.rawValue, "openCode:vendor:model-v1")
        for raw in ["", "openCode", ":model", "openCode:", "agent-selection:openCode:model"] {
            XCTAssertNil(AgentModelSelectionID.parse(raw), raw)
        }
    }

    func testParameterSelectionWireKeysAndFutureRawValueRoundTrip() throws {
        let data = Data(#"{"providerID":"cursor","baseModelRaw":" Model-A ","kind":"thinking","configID":"Effort.ID","valueRaw":"future/ULTRA"}"#.utf8)
        let selection = try JSONDecoder().decode(ACPModelParameterSelection.self, from: data)
        XCTAssertEqual(selection.providerID, .cursor)
        XCTAssertEqual(selection.baseModelRaw, " Model-A ")
        XCTAssertEqual(selection.configID, "Effort.ID")
        XCTAssertEqual(selection.valueRaw, "future/ULTRA")
        let encoded = try JSONEncoder().encode(selection)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(object, ["providerID": "cursor", "baseModelRaw": " Model-A ", "kind": "thinking", "configID": "Effort.ID", "valueRaw": "future/ULTRA"])
        XCTAssertEqual(try JSONDecoder().decode(ACPModelParameterSelection.self, from: encoded), selection)
        XCTAssertThrowsError(try JSONDecoder().decode(ACPModelParameterSelection.self, from: Data(#"{"providerID":"future-provider","baseModelRaw":"x","kind":"thinking","configID":"effort","valueRaw":"high"}"#.utf8)))
    }

    func testChoiceExactBeforeAmbiguousCaseAndThinkingPin() {
        let definition = ACPModelParameterDefinition(
            kind: .thinking, configID: "thought_level", displayName: "Thinking",
            choices: [
                .init(rawValue: "HIGH", displayName: "Upper"),
                .init(rawValue: "high", displayName: "Lower"),
                .init(rawValue: "medium", displayName: "Medium")
            ], currentValueRaw: "HIGH"
        )
        XCTAssertEqual(definition.choice(matching: "HIGH")?.displayName, "Upper")
        XCTAssertNil(definition.choice(matching: "High"))
        XCTAssertEqual(definition.choice(matching: "MEDIUM")?.rawValue, "medium")
        let pin = ACPModelParameterSelection.thinkingPin(configID: " thought_level ", valueRaw: "future", providerID: .openCode, modelRaw: "m")
        XCTAssertEqual(pin?.first?.configID, "thought_level")
        XCTAssertEqual(pin?.first?.valueRaw, "future")
        XCTAssertNil(ACPModelParameterSelection.thinkingPin(configID: "  ", valueRaw: "high", providerID: .openCode, modelRaw: "m"))
        XCTAssertNil(ACPModelParameterSelection.thinkingPin(configID: "effort", valueRaw: nil, providerID: .openCode, modelRaw: "m"))
    }
}
