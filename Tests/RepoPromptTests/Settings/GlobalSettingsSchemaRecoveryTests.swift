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

    func testRedundantV4HealsAndPreservesUnknownFieldsAcrossSavesAndRestart() throws {
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

    func testSupportedV5LoadsWithoutRepairAndPreservesContextBuilderAndUnknownFields() throws {
        try withSettings { url in
            var object = try root(fixture(version: 5))
            object["scalarPreferences"] = ["contextBuilder": ["contextTokenBudget": 4321, "unknownBehavior": "keep"]]
            let original = try JSONSerialization.data(withJSONObject: object)
            try original.write(to: url)
            let store = GlobalSettingsFileStore(fileURL: url)
            var document = try store.load()
            XCTAssertNil(store.blockReason)
            XCTAssertEqual(document.schemaVersion, 5)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("Backups").path))
            document.globalDefaults.discoverAgentRaw = "edited"
            try store.save(document)
            let saved = try root(Data(contentsOf: url))
            XCTAssertEqual(saved["schemaVersion"] as? Int, 5)
            XCTAssertEqual(saved["scalarPreferences"] as? NSDictionary, object["scalarPreferences"] as? NSDictionary)
            XCTAssertEqual(saved["unknownRoot"] as? NSDictionary, object["unknownRoot"] as? NSDictionary)
        }
    }

    func testGenuineFutureForeignAndMalformedDocumentsAreNeverDowngraded() throws {
        for variant in ["secondary", "nullSecondary", "roster", "foreign", "future", "malformed", "invalidProfiles"] {
            try withSettings { url in
                var object = try root(fixture())
                if ["secondary", "nullSecondary", "roster"].contains(variant) { object["schemaVersion"] = 6 }
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

    func testChangedExternalFieldsRequireReloadBeforePreservingUnknownFields() throws {
        try withSettings { url in
            try fixture(version: 2).write(to: url)
            let store = GlobalSettingsFileStore(fileURL: url)
            var document = try store.load()
            var external = try root(Data(contentsOf: url))
            external["externalField"] = ["retain": true]
            let externalData = try JSONSerialization.data(withJSONObject: external)
            try externalData.write(to: url)
            document.globalDefaults.discoverAgentRaw = "changed-agent"
            XCTAssertThrowsError(try store.save(document)) { error in
                XCTAssertEqual(
                    error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError,
                    .settingsChangedOnDisk
                )
            }
            XCTAssertEqual(try Data(contentsOf: url), externalData)

            document = try store.load()
            document.globalDefaults.discoverAgentRaw = "changed-agent"
            try store.save(document)
            XCTAssertEqual(try root(Data(contentsOf: url))["externalField"] as? NSDictionary, ["retain": true] as NSDictionary)
            let future = try fixture(version: 999)
            try future.write(to: url)
            XCTAssertThrowsError(try store.save(document))
            XCTAssertEqual(try Data(contentsOf: url), future)
        }
    }

    func testMalformedCurrentSchemaIsPreservedUntilExplicitRecovery() throws {
        try withSettings { url in
            var object = try root(fixture(version: 5))
            object["globalDefaults"] = "invalid"
            let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try original.write(to: url)

            let store = GlobalSettingsFileStore(fileURL: url)
            let fallback = store.loadOrCreateDefault()
            XCTAssertEqual(store.blockReason, .corruptUnrecoverable)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: url.deletingLastPathComponent().appendingPathComponent("Backups").path
                )
            )
            XCTAssertThrowsError(try store.save(fallback)) { error in
                XCTAssertEqual(
                    error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError,
                    .corruptDocumentPreserved
                )
            }
            XCTAssertEqual(try Data(contentsOf: url), original)

            XCTAssertTrue(store.performUserInitiatedRecovery(replacementDocument: fallback))
            XCTAssertNil(store.blockReason)
            XCTAssertEqual(try store.load().schemaLineage, GlobalSettingsDocument.schemaLineage)
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

    @MainActor
    func testManagerSaveMatchesCaseInsensitiveWorkspaceKeyAndPreservesUnknownFieldsAcrossRestart() throws {
        try withSettings { url in
            let workspaceID = try XCTUnwrap(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
            let lowercaseKey = workspaceID.uuidString.lowercased()
            var object = try root(fixture(version: 5))
            object["scalarPreferences"] = [
                "contextBuilder": ["contextTokenBudget": 1234],
                "fileSystem": ["globalIgnoreDefaults": ""]
            ]
            object["agentModelsSettingsByWorkspaceID"] = [
                lowercaseKey: [
                    "inheritanceMode": "useWorkspaceOverrides",
                    "profile": [
                        "planningModelRaw": "saved-model",
                        "unknownProfileField": ["keep": true]
                    ],
                    "unknownWorkspaceField": ["keep": true]
                ]
            ]
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)

            let firstSuite = "GlobalSettingsSchemaRecoveryTests.first.\(UUID().uuidString)"
            let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
            defer { firstDefaults.removePersistentDomain(forName: firstSuite) }
            let settings = GlobalSettingsStore(
                defaults: firstDefaults,
                fileStore: GlobalSettingsFileStore(fileURL: url)
            )
            XCTAssertNil(settings.persistenceBlockReason)

            // This unrelated typed manager save changes the UUID spelling from
            // the raw lowercase alias to the canonical document key.
            settings.setAppearanceModeRaw("Dark")
            try assertUnknownWorkspaceFields(
                in: root(Data(contentsOf: url)),
                canonicalKey: workspaceID.uuidString
            )

            let secondSuite = "GlobalSettingsSchemaRecoveryTests.second.\(UUID().uuidString)"
            let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
            defer { secondDefaults.removePersistentDomain(forName: secondSuite) }
            let restarted = GlobalSettingsStore(
                defaults: secondDefaults,
                fileStore: GlobalSettingsFileStore(fileURL: url)
            )
            XCTAssertEqual(restarted.appearanceModeRaw(), "Dark")
            restarted.setUseTransparency(false)
            try assertUnknownWorkspaceFields(
                in: root(Data(contentsOf: url)),
                canonicalKey: workspaceID.uuidString
            )
        }
    }

    func testUUIDKeyedWorkspaceAliasesPreserveUnknownFieldsAcrossTypedRewrite() throws {
        let workspaceID = try XCTUnwrap(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let canonicalKey = workspaceID.uuidString
        let lowercaseKey = canonicalKey.lowercased()
        let mapKeys = [
            "copySettingsByWorkspaceID",
            "chatSettingsByWorkspaceID",
            "agentModelsSettingsByWorkspaceID"
        ]

        for mapKey in mapKeys {
            let known = ["known": true]
            let originalRecord = [
                "known": true,
                "unknownNestedField": ["map": mapKey, "keep": true]
            ] as [String: Any]
            let before = try JSONSerialization.data(withJSONObject: [
                mapKey: [lowercaseKey: known]
            ])
            let replacement = try JSONSerialization.data(withJSONObject: [
                mapKey: [canonicalKey: known]
            ])
            let original = try JSONSerialization.data(withJSONObject: [
                mapKey: [lowercaseKey: originalRecord]
            ])

            let saved = try GlobalSettingsJSONPreservation.applyingChanges(
                from: before,
                to: replacement,
                preserving: original
            )
            let savedMap = try XCTUnwrap(root(saved)[mapKey] as? [String: Any])
            XCTAssertNil(savedMap[lowercaseKey])
            let savedRecord = try XCTUnwrap(savedMap[canonicalKey] as? [String: Any])
            XCTAssertEqual(
                savedRecord["unknownNestedField"] as? NSDictionary,
                ["map": mapKey, "keep": true] as NSDictionary
            )

            let duplicateOriginal = try JSONSerialization.data(withJSONObject: [
                mapKey: [
                    lowercaseKey: [
                        "known": true,
                        "unknownNestedField": ["winner": "sorted-alias"]
                    ],
                    canonicalKey: [
                        "known": true,
                        "unknownNestedField": ["winner": "canonical"]
                    ]
                ]
            ])
            let duplicateSaved = try GlobalSettingsJSONPreservation.applyingChanges(
                from: before,
                to: replacement,
                preserving: duplicateOriginal
            )
            let duplicateRecord = try XCTUnwrap(
                try (root(duplicateSaved)[mapKey] as? [String: Any])?[canonicalKey] as? [String: Any]
            )
            XCTAssertEqual(
                duplicateRecord["unknownNestedField"] as? NSDictionary,
                ["winner": "canonical"] as NSDictionary
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
        let id = try XCTUnwrap(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")).uuidString
        let lowercaseID = id.lowercased()
        let before = try JSONSerialization.data(withJSONObject: [
            "agentModelsSettingsByWorkspaceID": [lowercaseID: ["profile": ["known": true]]]
        ])
        let original = try JSONSerialization.data(withJSONObject: [
            "agentModelsSettingsByWorkspaceID": [
                lowercaseID: ["profile": ["known": true, "unknown": "losing alias"]],
                id: ["profile": ["known": true, "unknown": "canonical winner"]]
            ]
        ])
        let saved = try GlobalSettingsJSONPreservation.applyingChanges(
            from: before,
            to: Data("{}".utf8),
            preserving: original
        )
        XCTAssertNil(try root(saved)["agentModelsSettingsByWorkspaceID"])
    }

    private func assertUnknownWorkspaceFields(
        in object: [String: Any],
        canonicalKey: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let workspaceMap = try XCTUnwrap(
            object["agentModelsSettingsByWorkspaceID"] as? [String: Any],
            file: file,
            line: line
        )
        XCTAssertNil(workspaceMap[canonicalKey.lowercased()], file: file, line: line)
        let workspace = try XCTUnwrap(
            workspaceMap[canonicalKey] as? [String: Any],
            file: file,
            line: line
        )
        XCTAssertEqual(
            workspace["unknownWorkspaceField"] as? NSDictionary,
            ["keep": true] as NSDictionary,
            file: file,
            line: line
        )
        let profile = try XCTUnwrap(
            workspace["profile"] as? [String: Any],
            file: file,
            line: line
        )
        XCTAssertEqual(
            profile["unknownProfileField"] as? NSDictionary,
            ["keep": true] as NSDictionary,
            file: file,
            line: line
        )
    }

    private func fixture(version: Int = 4) throws -> Data {
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
