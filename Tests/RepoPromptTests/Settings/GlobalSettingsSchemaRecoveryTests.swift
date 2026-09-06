import Foundation
@testable import RepoPromptApp
import XCTest

final class GlobalSettingsSchemaRecoveryTests: XCTestCase {
    @MainActor
    func testDefaultSettingsStoreInUnitTestsUsesAnIsolatedDirectory() {
        XCTAssertTrue(AppLaunchConfiguration.isUnitTestProcess)
        let url = GlobalSettingsFileStore.defaultFileURL()
        let liveURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RepoPrompt CE/Settings/globalSettings.json")
        XCTAssertNotEqual(url.standardizedFileURL, liveURL.standardizedFileURL)
        XCTAssertTrue(url.path.contains("RepoPromptCE-unit-settings-"))
        let store = GlobalSettingsStore()
        XCTAssertNil(store.persistenceBlockReason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRedundantV5HealsAndPreservesUnknownFieldsAcrossSavesAndRestart() throws {
        try withSettings { url in
            let original = try fixture()
            try original.write(to: url)
            let store = GlobalSettingsFileStore(fileURL: url)
            var document = try store.load()
            XCTAssertNil(store.blockReason)
            XCTAssertEqual(document.schemaVersion, 2)
            let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent().appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
            var expected = try root(original)
            expected["schemaVersion"] = 2
            XCTAssertEqual(try root(Data(contentsOf: url)) as NSDictionary, expected as NSDictionary)

            document.globalDefaults.discoverAgentRaw = "changed-agent"
            try store.save(document)
            let restarted = GlobalSettingsFileStore(fileURL: url)
            var reloaded = try restarted.load()
            XCTAssertEqual(reloaded.globalDefaults.discoverAgentRaw, "changed-agent")
            reloaded.globalDefaults.discoverAgentRaw = nil
            try restarted.save(reloaded)
            let saved = try root(Data(contentsOf: url))
            XCTAssertEqual(saved["unknownRoot"] as? NSDictionary, expected["unknownRoot"] as? NSDictionary)
            let defaults = try XCTUnwrap(saved["globalDefaults"] as? [String: Any])
            XCTAssertEqual(defaults["unknownSetting"] as? String, "keep me")
            XCTAssertNil(defaults["discoverAgentRaw"])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().appendingPathComponent("Backups").path).count, 1)
        }
    }

    func testGenuineFutureForeignAndMalformedDocumentsAreNeverDowngraded() throws {
        for variant in ["secondary", "nullSecondary", "roster", "foreign", "future", "malformed", "invalidProfiles"] {
            try withSettings { url in
                var object = try root(fixture())
                switch variant {
                case "secondary": object["scalarPreferences"] = ["modelSelection": ["secondaryOracleModel": "saved-model"]]
                case "nullSecondary": object["scalarPreferences"] = ["modelSelection": ["secondaryOracleModel": NSNull()]]
                case "roster": object["scalarPreferences"] = ["modelSelection": ["additionalOracleModels": ["saved-model"]]]
                case "foreign": object.removeValue(forKey: "schemaLineage")
                case "future": object["schemaVersion"] = 999
                case "malformed": object["copySettingsByWorkspaceID"] = "invalid"
                default: object["agentModelsSettingsByWorkspaceID"] = NSNull()
                }
                let original = try JSONSerialization.data(withJSONObject: object)
                try original.write(to: url)
                let store = GlobalSettingsFileStore(fileURL: url)
                let fallback = store.loadOrCreateDefault()
                XCTAssertNotNil(store.blockReason, variant)
                XCTAssertThrowsError(try store.save(fallback), variant)
                XCTAssertEqual(try Data(contentsOf: url), original, variant)
            }
        }
    }

    func testRecoveryFailureNeverOverwritesOriginalOrConcurrentReplacement() throws {
        enum Failure: Error { case injected }
        for phase in ["backup", "backupVerification", "replacement", "concurrentChange"] {
            try withSettings { url in
                let original = try fixture()
                let concurrent = try fixture(version: 999)
                try original.write(to: url)
                let store = GlobalSettingsFileStore(
                    fileURL: url,
                    normalizationBackupWriter: { data, backup in
                        if phase == "backup" { throw Failure.injected }
                        try (phase == "backupVerification" ? Data("incomplete backup".utf8) : data).write(to: backup)
                        if phase == "concurrentChange" { try concurrent.write(to: url, options: .atomic) }
                    },
                    normalizationAtomicWriter: { data, destination in
                        if phase == "replacement" { throw Failure.injected }
                        try data.write(to: destination, options: .atomic)
                    }
                )
                let fallback = store.loadOrCreateDefault()
                XCTAssertEqual(store.blockReason, .automaticSchemaNormalizationFailed)
                XCTAssertThrowsError(try store.save(fallback))
                XCTAssertEqual(try Data(contentsOf: url), phase == "concurrentChange" ? concurrent : original)
            }
        }
    }

    func testSavePreservesUnchangedExternalFieldsAndBlocksNewFutureReplacement() throws {
        try withSettings { url in
            try fixture(version: 2).write(to: url)
            let store = GlobalSettingsFileStore(fileURL: url)
            var document = try store.load()
            var external = try root(Data(contentsOf: url))
            external["externalField"] = ["retain": true]
            try JSONSerialization.data(withJSONObject: external).write(to: url)
            document.globalDefaults.discoverAgentRaw = "changed-agent"
            try store.save(document)
            XCTAssertEqual(try root(Data(contentsOf: url))["externalField"] as? NSDictionary, ["retain": true] as NSDictionary)
            let future = try fixture(version: 999)
            try future.write(to: url)
            XCTAssertThrowsError(try store.save(document))
            XCTAssertEqual(try Data(contentsOf: url), future)
        }
    }

    func testWorkspaceProfilesKeepTheirRequiredVersionAndUnknownNestedSettings() throws {
        try withSettings { url in
            var object = try root(fixture())
            let workspaceID = UUID().uuidString
            object["agentModelsSettingsByWorkspaceID"] = [workspaceID: [
                "inheritanceMode": "useWorkspaceOverrides",
                "profile": ["planningModelRaw": "saved-model", "unknownProfileField": "keep"]
            ]]
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            let store = GlobalSettingsFileStore(fileURL: url)
            var document = try store.load()
            XCTAssertEqual(document.schemaVersion, 4)
            document.globalDefaults.discoverAgentRaw = "edited"
            try store.save(document)
            XCTAssertEqual(
                try root(Data(contentsOf: url))["agentModelsSettingsByWorkspaceID"] as? NSDictionary,
                object["agentModelsSettingsByWorkspaceID"] as? NSDictionary
            )
        }
    }

    func testClearingKnownGroupPreservesUnknownChildrenAndExternalDeletion() throws {
        let before = Data(#"{"scalarPreferences":{"modelSelection":{"known":true}},"globalDefaults":{"known":"old"}}"#.utf8)
        let after = Data(#"{"scalarPreferences":{},"globalDefaults":{"known":"old"},"changed":true}"#.utf8)
        let original = Data(#"{"scalarPreferences":{"modelSelection":{"known":true,"unknown":{"keep":true}}},"globalDefaults":{}}"#.utf8)
        let saved = try GlobalSettingsJSONPreservation.applyingChanges(from: before, to: after, preserving: original)
        let expected = Data(#"{"scalarPreferences":{"modelSelection":{"unknown":{"keep":true}}},"globalDefaults":{},"changed":true}"#.utf8)
        XCTAssertEqual(try root(saved) as NSDictionary, try root(expected) as NSDictionary)
    }

    func testRemovingLastWorkspaceSettingsDoesNotResurrectUnknownProfileFields() throws {
        let id = UUID().uuidString
        let before = try JSONSerialization.data(withJSONObject: ["agentModelsSettingsByWorkspaceID": [id: ["profile": ["known": true]]]])
        let original = try JSONSerialization.data(withJSONObject: ["agentModelsSettingsByWorkspaceID": [id: ["profile": ["known": true, "unknown": "keep only while workspace exists"]]]])
        let saved = try GlobalSettingsJSONPreservation.applyingChanges(from: before, to: Data("{}".utf8), preserving: original)
        XCTAssertNil(try root(saved)["agentModelsSettingsByWorkspaceID"])
    }

    private func fixture(version: Int = 5) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": version,
            "schemaLineage": GlobalSettingsDocument.schemaLineage,
            "updatedAt": "2026-09-06T00:00:00Z",
            "copySettingsByWorkspaceID": [:],
            "chatSettingsByWorkspaceID": [:],
            "globalDefaults": ["discoverAgentRaw": "existing-agent", "unknownSetting": "keep me"],
            "scalarPreferences": [:],
            "unknownRoot": ["nested": ["array": ["preserve", "all"], "enabled": true]]
        ], options: [.sortedKeys])
    }

    private func root(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func withSettings(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlobalSettingsSchemaRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("globalSettings.json"))
    }
}
