import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class GlobalSettingsPersistenceSafetyTests: XCTestCase {
    func testContextBuilderContentGetsV5FenceAndV130CodecRejectsIt() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        let document = makeDocument(
            contextBuilder: makeContextBuilderSettings(),
            fileSystemGlobalIgnoreDefaults: "keep"
        )
        let store = GlobalSettingsFileStore(fileURL: fileURL)

        try store.save(document)

        let savedRoot = try readJSONObject(at: fileURL)
        XCTAssertEqual(
            savedRoot["schemaVersion"] as? Int,
            GlobalSettingsDocument.contextBuilderSchemaVersion
        )
        XCTAssertNotNil((savedRoot["scalarPreferences"] as? [String: Any])?["contextBuilder"])
        XCTAssertThrowsError(try FrozenV130GlobalSettingsDocument.load(from: fileURL)) { error in
            XCTAssertEqual(
                error as? FrozenV130GlobalSettingsDocument.CompatibilityError,
                .unsupportedFutureSchema(GlobalSettingsDocument.contextBuilderSchemaVersion)
            )
        }
    }

    func testPreContextBuilderV130TypedCodecWouldDropTheGroupWithoutTheFence() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        let document = makeDocument(
            contextBuilder: makeContextBuilderSettings(),
            fileSystemGlobalIgnoreDefaults: "keep"
        )
        let store = GlobalSettingsFileStore(fileURL: fileURL)
        try store.save(document)

        var preFenceRoot = try readJSONObject(at: fileURL)
        preFenceRoot["schemaVersion"] = FrozenV130GlobalSettingsDocument.supportedSchemaVersion
        try writeJSONObject(preFenceRoot, to: fileURL)

        var oldDocument = try FrozenV130GlobalSettingsDocument.load(from: fileURL)
        oldDocument.scalarPreferences?.ui?.appearanceMode = "Dark"
        try oldDocument.save(to: fileURL, now: Date(timeIntervalSince1970: 1000))

        let oldWriterRoot = try readJSONObject(at: fileURL)
        let oldWriterScalar = oldWriterRoot["scalarPreferences"] as? [String: Any]
        XCTAssertNil(oldWriterScalar?["contextBuilder"])
        XCTAssertEqual(
            (oldWriterScalar?["ui"] as? [String: Any])?["appearanceMode"] as? String,
            "Dark"
        )
    }

    func testExistingV4DocumentWithContextBuilderIsUpgradedOnSequentialCurrentProcessPath() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        let document = makeDocument(
            contextBuilder: makeContextBuilderSettings(),
            fileSystemGlobalIgnoreDefaults: "already-seeded"
        )
        let initialStore = GlobalSettingsFileStore(fileURL: fileURL)
        try initialStore.save(document)

        var v4Root = try readJSONObject(at: fileURL)
        v4Root["schemaVersion"] = FrozenV130GlobalSettingsDocument.supportedSchemaVersion
        try writeJSONObject(v4Root, to: fileURL)

        let suiteName = "GlobalSettingsPersistenceSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        _ = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        let upgradedRoot = try readJSONObject(at: fileURL)
        XCTAssertEqual(
            upgradedRoot["schemaVersion"] as? Int,
            GlobalSettingsDocument.contextBuilderSchemaVersion
        )
        let upgradedContextBuilder = try XCTUnwrap(
            (upgradedRoot["scalarPreferences"] as? [String: Any])?["contextBuilder"] as? [String: Any]
        )
        let originalContextBuilder = try XCTUnwrap(
            (v4Root["scalarPreferences"] as? [String: Any])?["contextBuilder"] as? [String: Any]
        )
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: upgradedContextBuilder, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: originalContextBuilder, options: [.sortedKeys])
        )
    }

    func testFailedMigrationRetryMergesKnownEditsAndPreservesUnknownFields() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        let workspaceID = UUID()
        let document = makeDocument(
            workspaceID: workspaceID,
            includeLegacyChatSettings: true,
            includeAgentModelsProfile: true,
            contextBuilder: makeContextBuilderSettings(),
            fileSystemGlobalIgnoreDefaults: "keep"
        )
        let initialStore = GlobalSettingsFileStore(fileURL: fileURL)
        try initialStore.save(document)
        try addUnknownFields(to: fileURL, workspaceID: workspaceID)
        var v4Root = try readJSONObject(at: fileURL)
        v4Root["schemaVersion"] = FrozenV130GlobalSettingsDocument.supportedSchemaVersion
        try writeJSONObject(v4Root, to: fileURL)
        let originalBytes = try Data(contentsOf: fileURL)

        var writeAttempts = 0
        let fileStore = GlobalSettingsFileStore(
            fileURL: fileURL,
            startupMigrationAtomicWriter: { data, url in
                writeAttempts += 1
                if writeAttempts <= 2 {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try data.write(to: url, options: .atomic)
            }
        )
        let suiteName = "GlobalSettingsPersistenceSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        XCTAssertEqual(writeAttempts, 1)
        XCTAssertEqual(settings.persistenceBlockReason, .saveFailed)
        XCTAssertTrue(settings.isPendingPreservingMigrationRetry)
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)

        settings.setAppearanceModeRaw("Dark")
        settings.setPlanningModelRaw("retry-planning-model")
        var changedBehavior = settings.contextBuilderBehaviorSettings()
        changedBehavior.analysisTokenBudget += 1
        settings.setContextBuilderBehaviorSettings(changedBehavior)
        XCTAssertEqual(settings.appearanceModeRaw(), "Dark")
        XCTAssertEqual(settings.planningModelRaw(), "retry-planning-model")
        XCTAssertEqual(
            settings.contextBuilderBehaviorSettings().analysisTokenBudget,
            changedBehavior.analysisTokenBudget
        )
        XCTAssertEqual(settings.persistenceBlockReason, .saveFailed)
        XCTAssertThrowsError(try fileStore.save(document)) { error in
            XCTAssertEqual(
                error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError,
                .startupMigrationRetryRequired
            )
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)

        XCTAssertFalse(settings.retryBlockedPersistenceSave())
        XCTAssertEqual(writeAttempts, 2)
        XCTAssertEqual(settings.persistenceBlockReason, .saveFailed)
        XCTAssertTrue(settings.isPendingPreservingMigrationRetry)
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)

        XCTAssertTrue(settings.retryBlockedPersistenceSave())
        XCTAssertEqual(writeAttempts, 3)
        XCTAssertNil(settings.persistenceBlockReason)
        XCTAssertFalse(settings.isPendingPreservingMigrationRetry)

        let freshStore = GlobalSettingsFileStore(fileURL: fileURL)
        let freshDocument = try freshStore.load()
        XCTAssertEqual(
            freshDocument.scalarPreferences?.ui?.appearanceMode,
            "Dark"
        )
        XCTAssertEqual(
            freshDocument.scalarPreferences?.modelSelection?.planningModel,
            "retry-planning-model"
        )
        XCTAssertEqual(
            freshDocument.scalarPreferences?.contextBuilder?.analysisTokenBudget,
            changedBehavior.analysisTokenBudget
        )

        let migratedRoot = try readJSONObject(at: fileURL)
        XCTAssertEqual(
            migratedRoot["schemaVersion"] as? Int,
            GlobalSettingsDocument.contextBuilderSchemaVersion
        )
        XCTAssertEqual(
            (migratedRoot["futureRoot"] as? [String: Any])?["value"] as? String,
            "root-preserved"
        )
        let migratedScalar = try XCTUnwrap(migratedRoot["scalarPreferences"] as? [String: Any])
        XCTAssertEqual(
            (migratedScalar["futureScalar"] as? [String: Any])?["value"] as? String,
            "scalar-preserved"
        )
        XCTAssertEqual(
            ((migratedScalar["contextBuilder"] as? [String: Any])?["futureContextBuilder"] as? [String: Any])?["value"] as? String,
            "context-builder-preserved"
        )
        XCTAssertEqual(
            ((migratedRoot["globalDefaults"] as? [String: Any])?["futureGlobalDefaults"] as? [String: Any])?["value"] as? String,
            "global-defaults-preserved"
        )
        let migratedWorkspace = try XCTUnwrap(
            (migratedRoot["chatSettingsByWorkspaceID"] as? [String: Any])?[workspaceID.uuidString] as? [String: Any]
        )
        XCTAssertEqual(
            (migratedWorkspace["futureWorkspace"] as? [String: Any])?["value"] as? String,
            "workspace-preserved"
        )
        let migratedProfile = try XCTUnwrap(
            (((migratedRoot["agentModelsSettingsByWorkspaceID"] as? [String: Any])?[workspaceID.uuidString] as? [String: Any])?["profile"] as? [String: Any])
        )
        XCTAssertEqual(
            (migratedProfile["futureProfile"] as? [String: Any])?["value"] as? String,
            "profile-preserved"
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlobalSettingsPersistenceSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDocument(
        workspaceID: UUID = UUID(),
        includeLegacyChatSettings: Bool = false,
        includeAgentModelsProfile: Bool = false,
        contextBuilder: GlobalScalarPreferences.ContextBuilderSettings? = nil,
        fileSystemGlobalIgnoreDefaults: String? = nil
    ) -> GlobalSettingsDocument {
        var chatSettings: [UUID: ChatGlobalSettings] = [:]
        if includeLegacyChatSettings {
            var legacy = ChatGlobalSettings(
                workspaceID: workspaceID,
                discoveryTokenBudget: 12345,
                discoveryEnhancementMode: "balanced",
                discoveryAutoGeneratePlan: true
            )
            legacy.discoveryAllowClarifyingQuestions = true
            legacy.discoveryAllowClarifyingQuestionsForMCP = false
            legacy.discoveryQuestionTimeoutSeconds = 91
            legacy.discoveryPlanTokenBudget = 6789
            chatSettings[workspaceID] = legacy
        }

        var agentModelsSettings: [UUID: WorkspaceAgentModelsSettings] = [:]
        if includeAgentModelsProfile {
            agentModelsSettings[workspaceID] = WorkspaceAgentModelsSettings(
                inheritanceMode: .useWorkspaceOverrides,
                profile: AgentModelsSettingsProfile(
                    planningModelRaw: "planning-model",
                    preferredComposeModelRaw: "compose-model",
                    syncChatModelWithOracle: false,
                    contextBuilderAgentRaw: "codexExec",
                    contextBuilderModelsByAgent: ["codexExec": "context-model"],
                    mcpAgentRoleOverrides: ["explore": "context-model"],
                    restrictMCPAgentDiscoveryToRoleLabels: false
                )
            )
        }

        return GlobalSettingsDocument(
            chatSettings: chatSettings,
            agentModelsSettings: agentModelsSettings,
            scalarPreferences: GlobalScalarPreferences(
                ui: .init(appearanceMode: "System"),
                contextBuilder: contextBuilder,
                fileSystem: .init(globalIgnoreDefaults: fileSystemGlobalIgnoreDefaults)
            )
        )
    }

    private func makeContextBuilderSettings() -> GlobalScalarPreferences.ContextBuilderSettings {
        GlobalScalarPreferences.ContextBuilderSettings(
            contextTokenBudget: 1234,
            analysisTokenBudget: 5678,
            enhancementMode: "balanced",
            questionTimeoutSeconds: 91,
            allowUIClarifyingQuestions: true,
            allowMCPClarifyingQuestions: false,
            followUpAnalysisEnabled: true
        )
    }

    private func readJSONObject(at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func addUnknownFields(to url: URL, workspaceID: UUID) throws {
        var root = try readJSONObject(at: url)
        root["futureRoot"] = ["value": "root-preserved"]

        var scalarPreferences = try XCTUnwrap(root["scalarPreferences"] as? [String: Any])
        scalarPreferences["futureScalar"] = ["value": "scalar-preserved"]
        var contextBuilder = try XCTUnwrap(scalarPreferences["contextBuilder"] as? [String: Any])
        contextBuilder["futureContextBuilder"] = ["value": "context-builder-preserved"]
        scalarPreferences["contextBuilder"] = contextBuilder
        root["scalarPreferences"] = scalarPreferences

        var globalDefaults = try XCTUnwrap(root["globalDefaults"] as? [String: Any])
        globalDefaults["futureGlobalDefaults"] = ["value": "global-defaults-preserved"]
        root["globalDefaults"] = globalDefaults

        var chatSettings = try XCTUnwrap(root["chatSettingsByWorkspaceID"] as? [String: Any])
        var workspaceSettings = try XCTUnwrap(chatSettings[workspaceID.uuidString] as? [String: Any])
        workspaceSettings["futureWorkspace"] = ["value": "workspace-preserved"]
        chatSettings[workspaceID.uuidString] = workspaceSettings
        root["chatSettingsByWorkspaceID"] = chatSettings

        var agentModelsSettings = try XCTUnwrap(root["agentModelsSettingsByWorkspaceID"] as? [String: Any])
        var workspaceAgentModels = try XCTUnwrap(agentModelsSettings[workspaceID.uuidString] as? [String: Any])
        var profile = try XCTUnwrap(workspaceAgentModels["profile"] as? [String: Any])
        profile["futureProfile"] = ["value": "profile-preserved"]
        workspaceAgentModels["profile"] = profile
        agentModelsSettings[workspaceID.uuidString] = workspaceAgentModels
        root["agentModelsSettingsByWorkspaceID"] = agentModelsSettings

        try writeJSONObject(root, to: url)
    }
}
