import Foundation
@testable import RepoPromptSettingsCore
import XCTest

@MainActor
final class OracleGuidancePersistenceTests: XCTestCase {
    func testCustomGuidanceSurvivesBothTypedCodecsVerbatim() throws {
        let guidance = "  Check each claim.\nKeep disagreements explicit.  \n"
        let input = try JSONSerialization.data(withJSONObject: ["oracleReconciliationGuidance": guidance])
        let profile = try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: input)
        let scalar = try JSONDecoder().decode(GlobalScalarPreferences.ModelSelectionSettings.self, from: input)
        let profileJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        let scalarJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(scalar)) as? [String: Any])
        XCTAssertEqual(profileJSON["oracleReconciliationGuidance"] as? String, guidance)
        XCTAssertEqual(scalarJSON["oracleReconciliationGuidance"] as? String, guidance)
    }

    func testMissingNullAndBlankUseNoOverrideButWrongTypesAreRejected() throws {
        for value in [nil, NSNull(), "", " \t\r\n"] as [Any?] {
            let object: [String: Any] = value.map { ["oracleReconciliationGuidance": $0] } ?? [:]
            let data = try JSONSerialization.data(withJSONObject: object)
            let profile = try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: data)
            let scalar = try JSONDecoder().decode(GlobalScalarPreferences.ModelSelectionSettings.self, from: data)
            XCTAssertNil(profile.oracleReconciliationGuidance)
            XCTAssertNil(scalar.oracleReconciliationGuidance)
        }
        let malformed = Data(#"{"oracleReconciliationGuidance":42}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: malformed))
        XCTAssertThrowsError(try JSONDecoder().decode(GlobalScalarPreferences.ModelSelectionSettings.self, from: malformed))
    }

    func testGlobalWorkspaceInheritanceCopyAndReloadPreserveGuidanceAndOtherChoices() throws {
        try withStore { store, fileURL, defaults in
            let workspaceID = UUID()
            let globalText = "  Global evidence rule.\n"
            let workspaceText = "Workspace evidence rule.  "
            let profile = AgentModelsSettingsProfile(
                planningModelRaw: "planning-model",
                additionalOracleModelRaws: ["other-model"],
                oracleReconciliationGuidance: globalText,
                preferredComposeModelRaw: "compose-model",
                contextBuilderAgentRaw: "codex",
                contextBuilderModelsByAgent: ["codex": "fixture-model"],
                mcpAgentRoleOverrides: ["engineer": "codex:fixture-model"]
            )
            store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
            XCTAssertEqual(store.globalAgentModelsProfile(), profile)
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID), profile)
            let ownership = store.globalDefaults.didUserSetDiscoverAgentDefaults

            store.copyAgentModelsProfile(from: .global, to: .workspace(workspaceID))
            XCTAssertEqual(store.workspaceAgentModelsProfile(for: workspaceID), profile)
            setGuidance(workspaceText, in: store, workspaceID: workspaceID)
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).oracleReconciliationGuidance, workspaceText)
            XCTAssertEqual(store.globalAgentModelsProfile(), profile)
            store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useGlobalSettings)
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID), profile)
            XCTAssertEqual(store.workspaceAgentModelsProfile(for: workspaceID)?.oracleReconciliationGuidance, workspaceText)
            XCTAssertEqual(store.globalDefaults.didUserSetDiscoverAgentDefaults, ownership)

            let fresh = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
            XCTAssertEqual(fresh.globalAgentModelsProfile(), profile)
            fresh.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
            XCTAssertEqual(fresh.effectiveAgentModelsProfile(workspaceID: workspaceID).oracleReconciliationGuidance, workspaceText)
            fresh.copyAgentModelsProfile(from: .workspace(workspaceID), to: .global)
            var expected = profile
            expected.oracleReconciliationGuidance = workspaceText
            XCTAssertEqual(fresh.globalAgentModelsProfile(), expected)
            setGuidance(" \n\t", in: fresh, workspaceID: workspaceID)
            // Whole-profile inheritance, not per-field inheritance: blank workspace guidance is default.
            XCTAssertNil(fresh.effectiveAgentModelsProfile(workspaceID: workspaceID).oracleReconciliationGuidance)
            XCTAssertEqual(fresh.globalAgentModelsProfile(), expected)
        }
    }

    func testResetDeletesBothKnownFieldsWithoutResurrectingThemOrLosingUnknownFields() throws {
        try withStore { store, fileURL, defaults in
            let workspaceID = UUID()
            let profile = AgentModelsSettingsProfile(oracleReconciliationGuidance: "custom rule")
            store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
            store.copyAgentModelsProfile(from: .global, to: .workspace(workspaceID))
            var root = try json(fileURL)
            var scalar = try XCTUnwrap(root["scalarPreferences"] as? [String: Any])
            var selection = try XCTUnwrap(scalar["modelSelection"] as? [String: Any])
            selection["futureSelection"] = "keep-global"
            scalar["modelSelection"] = selection
            root["scalarPreferences"] = scalar
            var workspaces = try XCTUnwrap(root["agentModelsSettingsByWorkspaceID"] as? [String: Any])
            var record = try XCTUnwrap(workspaces[workspaceID.uuidString] as? [String: Any])
            var rawProfile = try XCTUnwrap(record["profile"] as? [String: Any])
            rawProfile["futureProfile"] = "keep-workspace"
            record["profile"] = rawProfile
            workspaces[workspaceID.uuidString] = record
            root["agentModelsSettingsByWorkspaceID"] = workspaces
            try JSONSerialization.data(withJSONObject: root).write(to: fileURL, options: .atomic)
            XCTAssertTrue(store.reloadFromDisk())

            setGuidance(nil, in: store)
            setGuidance(" \n", in: store, workspaceID: workspaceID)
            let saved = try json(fileURL)
            let savedSelection = (saved["scalarPreferences"] as? [String: Any])?["modelSelection"] as? [String: Any]
            let savedRecord = (saved["agentModelsSettingsByWorkspaceID"] as? [String: Any])?[workspaceID.uuidString] as? [String: Any]
            let savedProfile = savedRecord?["profile"] as? [String: Any]
            XCTAssertNil(savedSelection?["oracleReconciliationGuidance"])
            XCTAssertNil(savedProfile?["oracleReconciliationGuidance"])
            XCTAssertEqual(savedSelection?["futureSelection"] as? String, "keep-global")
            XCTAssertEqual(savedProfile?["futureProfile"] as? String, "keep-workspace")
            XCTAssertLessThan(try XCTUnwrap(saved["schemaVersion"] as? Int), GlobalSettingsDocument.oracleReconciliationGuidanceSchemaVersion)
            let fresh = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
            XCTAssertNil(fresh.globalAgentModelsProfile().oracleReconciliationGuidance)
            XCTAssertNil(fresh.effectiveAgentModelsProfile(workspaceID: workspaceID).oracleReconciliationGuidance)
        }
    }

    func testFailedSaveKeepsOriginalBytesAndRetryPersistsPendingGuidance() throws {
        try withStore { store, fileURL, defaults in
            setGuidance("original", in: store)
            var root = try json(fileURL)
            root["futureRoot"] = "keep"
            let original = try JSONSerialization.data(withJSONObject: root)
            try original.write(to: fileURL, options: .atomic)
            var failWrites = true
            let fileStore = GlobalSettingsFileStore(fileURL: fileURL, atomicWriter: { data, url in
                if failWrites { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
            })
            let pending = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
            setGuidance("  pending\n", in: pending)
            XCTAssertEqual(pending.persistenceBlockReason, .saveFailed)
            XCTAssertEqual(pending.globalAgentModelsProfile().oracleReconciliationGuidance, "  pending\n")
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
            failWrites = false
            XCTAssertTrue(pending.retryBlockedPersistenceSave())
            let fresh = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
            XCTAssertEqual(fresh.globalAgentModelsProfile().oracleReconciliationGuidance, "  pending\n")
            XCTAssertEqual(try json(fileURL)["futureRoot"] as? String, "keep")
        }
    }

    func testCustomGuidanceFencesGlobalAndInactiveWorkspaceProfilesButDefaultDoesNot() throws {
        let featureVersion = GlobalSettingsDocument.oracleReconciliationGuidanceSchemaVersion
        for text in [nil, "", " \t\n", "custom"] {
            let global = GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(
                modelSelection: .init(oracleReconciliationGuidance: text)
            ))
            let workspace = GlobalSettingsDocument(agentModelsSettings: [UUID(): WorkspaceAgentModelsSettings(
                inheritanceMode: .useGlobalSettings,
                profile: .init(oracleReconciliationGuidance: text)
            )])
            if text == "custom" {
                XCTAssertEqual(global.requiredSchemaVersion, featureVersion)
                XCTAssertEqual(workspace.requiredSchemaVersion, featureVersion)
            } else {
                XCTAssertEqual(global.requiredSchemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
                XCTAssertEqual(workspace.requiredSchemaVersion, GlobalSettingsDocument.workspaceAgentModelsSchemaVersion)
            }
        }
        try withStore { store, fileURL, _ in
            setGuidance("custom", in: store)
            XCTAssertEqual(try json(fileURL)["schemaVersion"] as? Int, featureVersion)
            let workspaceID = UUID()
            store.copyAgentModelsProfile(from: .global, to: .workspace(workspaceID))
            store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useGlobalSettings)
            setGuidance(nil, in: store)
            XCTAssertNil(store.effectiveAgentModelsProfile(workspaceID: workspaceID).oracleReconciliationGuidance)
            XCTAssertEqual(try json(fileURL)["schemaVersion"] as? Int, featureVersion)
        }
    }

    func testMalformedGuidanceFileIsPreservedAndCannotBeOverwritten() throws {
        try withStore { _, fileURL, _ in
            var root = try json(fileURL)
            root["scalarPreferences"] = ["modelSelection": ["oracleReconciliationGuidance": 42]]
            let malformed = try JSONSerialization.data(withJSONObject: root)
            try malformed.write(to: fileURL, options: .atomic)
            let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
            XCTAssertThrowsError(try fileStore.load())
            XCTAssertEqual(fileStore.blockReason, .corruptUnrecoverable)
            XCTAssertThrowsError(try fileStore.save(GlobalSettingsDocument()))
            XCTAssertEqual(try Data(contentsOf: fileURL), malformed)
        }
    }

    private func setGuidance(_ text: String?, in store: GlobalSettingsStore, workspaceID: UUID? = nil) {
        var profile = store.effectiveAgentModelsProfile(workspaceID: workspaceID)
        profile.oracleReconciliationGuidance = text
        if let workspaceID {
            store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: profile)
        } else {
            store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
        }
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func withStore(_ body: (GlobalSettingsStore, URL, UserDefaults) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OracleGuidancePersistenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "OracleGuidancePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fileURL = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        try body(store, fileURL, defaults)
    }
}
