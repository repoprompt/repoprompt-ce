import Foundation
@testable import RepoPromptApp
import XCTest

/// Persistence contract for the opt-in Codex usage quota flag.
///
/// The flag is `Optional` so "never set" survives a round-trip and an older build can still
/// read the document. Production default is off: while unset or false, no quota client,
/// process, subscription, or polling exists.
@MainActor
final class CodexUsageQuotaSettingsTests: XCTestCase {
    func testDefaultsToOffWhenUnset() {
        let document = GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: GlobalScalarPreferences.AgentModeSettings())
        )
        XCTAssertNil(
            document.scalarPreferences?.agentMode?.codexUsageQuotaEnabled,
            "unset must stay unset rather than being written as false"
        )

        // The accessor's default is what production reads, and it is off.
        let settings = GlobalScalarPreferences.AgentModeSettings()
        XCTAssertEqual(settings.codexUsageQuotaEnabled ?? false, false)
    }

    func testRoundTripsThroughDocumentEncoding() throws {
        for value in [true, false] {
            let agentMode = GlobalScalarPreferences.AgentModeSettings(codexUsageQuotaEnabled: value)
            let document = GlobalSettingsDocument(
                scalarPreferences: GlobalScalarPreferences(agentMode: agentMode)
            )
            let decoded = try JSONDecoder().decode(
                GlobalSettingsDocument.self,
                from: JSONEncoder().encode(document)
            )
            XCTAssertEqual(decoded.scalarPreferences?.agentMode?.codexUsageQuotaEnabled, value)
        }
    }

    func testUnsetFlagIsNotEmittedIntoTheDocument() throws {
        let document = GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(
                agentMode: GlobalScalarPreferences.AgentModeSettings(codexGoalSupportEnabled: true)
            )
        )
        let data = try JSONEncoder().encode(document)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let scalarPreferences = try XCTUnwrap(raw["scalarPreferences"] as? [String: Any])
        let agentMode = try XCTUnwrap(scalarPreferences["agentMode"] as? [String: Any])
        XCTAssertNil(
            agentMode["codexUsageQuotaEnabled"],
            "an untouched optional must not be materialized on write"
        )
    }

    func testSiblingAgentModeSettingsSurviveToggling() throws {
        let agentMode = GlobalScalarPreferences.AgentModeSettings(
            codexGoalSupportEnabled: true,
            codexUsageQuotaEnabled: true,
            agentSessionHandoffInstructions: "keep me"
        )
        let document = GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: agentMode)
        )
        let decoded = try JSONDecoder().decode(
            GlobalSettingsDocument.self,
            from: JSONEncoder().encode(document)
        )
        XCTAssertEqual(decoded.scalarPreferences?.agentMode?.codexUsageQuotaEnabled, true)
        XCTAssertEqual(decoded.scalarPreferences?.agentMode?.codexGoalSupportEnabled, true)
        XCTAssertEqual(decoded.scalarPreferences?.agentMode?.agentSessionHandoffInstructions, "keep me")
    }
}
