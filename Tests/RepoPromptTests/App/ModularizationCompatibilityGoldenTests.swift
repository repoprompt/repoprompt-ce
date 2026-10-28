import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

/// Build-modularization P0.6 goldens: runtime identities that a module move must not change.
///
/// Inventory and classification: `docs/migrations/build-modularization/ledger.md`, section
/// "P0.6 compatibility inventory". When a slice moves one of these types, move the matching test
/// with it and keep the literals unchanged.
final class ModularizationCompatibilityGoldenTests: XCTestCase {
    func testSettingsProviderIdentitiesMatchAppProviderMappings() throws {
        XCTAssertEqual(
            Set(SettingsAgentKind.allCases.map(\.rawValue)),
            Set(AgentProviderKind.allCases.map(\.rawValue))
        )
        for agent in AgentProviderKind.allCases {
            let settingsIdentity = try XCTUnwrap(SettingsAgentKind(rawValue: agent.rawValue))
            XCTAssertEqual(settingsIdentity.acpProviderID, agent.acpProviderID)
        }
    }

    // MARK: - Cross-process notification names

    /// Darwin notifications cross process boundaries between running app instances.
    @MainActor
    func testFontScaleDarwinNotificationNameIsPinned() {
        XCTAssertEqual(FontScaleManager.externalChangeNotificationRawName, "com.repoprompt.fontScaleDidChange")
    }

    // MARK: - Persisted settings document keys

    /// The global settings document's root keys and scalar-preference group keys are persisted
    /// JSON. Field-level keys inside each group are covered by the settings persistence suites.
    func testGlobalSettingsDocumentPersistedKeysArePinned() throws {
        let groupKeys: Set = [
            "agentMode",
            "contextBuilder",
            "fileSystem",
            "mcp",
            "modelOverrides",
            "modelRouter",
            "modelSelection",
            "notifications",
            "promptPackaging",
            "telemetry",
            "ui"
        ]
        let scalarJSON = "{" + groupKeys.sorted().map { "\"\($0)\":{}" }.joined(separator: ",") + "}"
        let scalarPreferences = try JSONDecoder().decode(GlobalScalarPreferences.self, from: Data(scalarJSON.utf8))
        let document = GlobalSettingsDocument(
            updatedAt: Date(timeIntervalSince1970: 0),
            scalarPreferences: scalarPreferences
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), [
            "chatSettingsByWorkspaceID",
            "copySettingsByWorkspaceID",
            "globalDefaults",
            "scalarPreferences",
            "schemaLineage",
            "schemaVersion",
            "updatedAt"
        ])
        XCTAssertEqual(root["schemaLineage"] as? String, "repoprompt-ce.global-settings")
        let encodedGroups = try XCTUnwrap(root["scalarPreferences"] as? [String: Any])
        XCTAssertEqual(Set(encodedGroups.keys), groupKeys)

        // `agentModelsSettingsByWorkspaceID` is omitted when empty; pin its key on the read side.
        root["agentModelsSettingsByWorkspaceID"] = [String: Any]()
        let decoded = try decoder.decode(
            GlobalSettingsDocument.self,
            from: JSONSerialization.data(withJSONObject: root)
        )
        XCTAssertNotNil(decoded.agentModelsSettingsByWorkspaceID)
        XCTAssertEqual(decoded.scalarPreferences, scalarPreferences)
    }
}
