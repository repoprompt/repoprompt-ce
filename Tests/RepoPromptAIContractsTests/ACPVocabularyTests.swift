import Foundation
@testable import RepoPromptAIContracts
import XCTest

final class ACPVocabularyTests: XCTestCase {
    func testFutureEffortSurvivesRecordRoundTripWithoutInboundProof() throws {
        let option = AgentModelOption(
            rawValue: "model", displayName: "Model", description: nil,
            isPlaceholderDefault: false, isProviderDefault: true,
            supportedReasoningEffortRawValues: ["future-effort"],
            defaultReasoningEffortRawValue: "future-effort"
        )
        var snapshot = ACPDiscoveredSessionModels(options: [option], currentModelRaw: "model", currentEffortRaw: "future-effort")
        snapshot.currentEffortInboundSequence = 42
        let record = try XCTUnwrap(ACPDynamicModelCanonicalization.canonicalProviderRecord(from: snapshot, providerID: .grokBuild))
        let data = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("currentEffortInboundSequence"))
        let restored = try XCTUnwrap(ACPDynamicModelCanonicalization.snapshot(from: JSONDecoder().decode(ACPDynamicProviderRecord.self, from: data)))
        XCTAssertEqual(restored.options.first?.supportedReasoningEffortRawValues, ["future-effort"])
        XCTAssertEqual(restored.currentEffortRaw, "future-effort")
        XCTAssertNil(restored.currentEffortInboundSequence)
        XCTAssertEqual(restored.preferredModelRaw, "model")
    }

    func testProviderRawIdentityAndClaudeBindingGrouping() {
        for kind in AgentProviderKind.allCases {
            XCTAssertEqual(AgentProviderKind(rawValue: kind.rawValue), kind)
        }
        for kind: AgentProviderKind in [.claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible] {
            XCTAssertEqual(kind.providerBindingID, .claude)
            XCTAssertEqual(kind.claudeRuntimeVariant?.agentKind, kind)
            XCTAssertEqual(kind.runtimeKind, "claude_native")
        }
        XCTAssertEqual(AgentProviderKind.cursor.acpProviderID, .cursor)
        XCTAssertNil(AgentProviderKind.codexExec.acpProviderID)
    }
}
