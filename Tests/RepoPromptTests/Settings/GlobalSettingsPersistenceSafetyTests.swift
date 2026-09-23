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

    func testCurrentOutOfRangeAnalysisBudgetIsNormalizedWithUnknownFieldsPreserved() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        let initialStore = GlobalSettingsFileStore(fileURL: fileURL)
        try initialStore.save(makeDocument(
            contextBuilder: makeContextBuilderSettings(analysisTokenBudget: 250_000),
            fileSystemGlobalIgnoreDefaults: "already-seeded"
        ))
        var rawRoot = try readJSONObject(at: fileURL)
        var rawScalar = try XCTUnwrap(rawRoot["scalarPreferences"] as? [String: Any])
        var rawContextBuilder = try XCTUnwrap(rawScalar["contextBuilder"] as? [String: Any])
        rawContextBuilder["futureContextBuilder"] = ["value": "preserved"]
        rawScalar["contextBuilder"] = rawContextBuilder
        rawRoot["scalarPreferences"] = rawScalar
        try writeJSONObject(rawRoot, to: fileURL)

        let suiteName = "GlobalSettingsPersistenceSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertEqual(
            settings.contextBuilderBehaviorSettings().analysisTokenBudget,
            ContextBuilderDefaults.analysisTokenBudgetRange.upperBound
        )
        let persisted = try GlobalSettingsFileStore(fileURL: fileURL).load()
        XCTAssertEqual(
            persisted.scalarPreferences?.contextBuilder?.analysisTokenBudget,
            ContextBuilderDefaults.analysisTokenBudgetRange.upperBound
        )
        let normalizedRoot = try readJSONObject(at: fileURL)
        let normalizedContextBuilder = try XCTUnwrap(
            (normalizedRoot["scalarPreferences"] as? [String: Any])?["contextBuilder"] as? [String: Any]
        )
        XCTAssertEqual(
            (normalizedContextBuilder["futureContextBuilder"] as? [String: Any])?["value"] as? String,
            "preserved"
        )
    }

    func testLegacyOutOfRangeAnalysisBudgetIsNormalizedDuringMigration() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        let workspaceID = UUID()
        let initialStore = GlobalSettingsFileStore(fileURL: fileURL)
        try initialStore.save(makeDocument(
            workspaceID: workspaceID,
            includeLegacyChatSettings: true,
            legacyAnalysisTokenBudget: 250_000,
            fileSystemGlobalIgnoreDefaults: "already-seeded"
        ))

        let suiteName = "GlobalSettingsPersistenceSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertEqual(
            settings.contextBuilderBehaviorSettings().analysisTokenBudget,
            ContextBuilderDefaults.analysisTokenBudgetRange.upperBound
        )
        let persisted = try GlobalSettingsFileStore(fileURL: fileURL).load()
        XCTAssertEqual(
            persisted.scalarPreferences?.contextBuilder?.analysisTokenBudget,
            ContextBuilderDefaults.analysisTokenBudgetRange.upperBound
        )
        XCTAssertNil(persisted.chatSettings[workspaceID]?.discoveryPlanTokenBudget)
    }

    func testAnalysisBudgetSetterNormalizesAndSurvivesRestart() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        let suiteName = "GlobalSettingsPersistenceSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        var behavior = settings.contextBuilderBehaviorSettings()
        behavior.analysisTokenBudget = ContextBuilderDefaults.analysisTokenBudgetRange.lowerBound - 1
        settings.setContextBuilderBehaviorSettings(behavior)

        let restarted = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertEqual(
            restarted.contextBuilderBehaviorSettings().analysisTokenBudget,
            ContextBuilderDefaults.analysisTokenBudgetRange.lowerBound
        )

        behavior = restarted.contextBuilderBehaviorSettings()
        behavior.analysisTokenBudget = ContextBuilderDefaults.analysisTokenBudgetRange.upperBound
        restarted.setContextBuilderBehaviorSettings(behavior)
        let restartedAtUpperBound = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertEqual(
            restartedAtUpperBound.contextBuilderBehaviorSettings().analysisTokenBudget,
            ContextBuilderDefaults.analysisTokenBudgetRange.upperBound
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
            contextBuilder: makeContextBuilderSettings(analysisTokenBudget: 250_000),
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
        XCTAssertEqual(
            settings.contextBuilderBehaviorSettings().analysisTokenBudget,
            ContextBuilderDefaults.analysisTokenBudgetRange.upperBound
        )

        settings.setAppearanceModeRaw("Dark")
        settings.setPlanningModelRaw("retry-planning-model")
        var changedBehavior = settings.contextBuilderBehaviorSettings()
        changedBehavior.analysisTokenBudget = ContextBuilderDefaults.analysisTokenBudgetRange.lowerBound - 1
        settings.setContextBuilderBehaviorSettings(changedBehavior)
        changedBehavior.analysisTokenBudget = ContextBuilderDefaults.analysisTokenBudgetRange.lowerBound
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

    /// Round-trip + global decomposition for the new OpenCode parameter-pin buckets. This is
    /// §2.6's silent-loss failure: a profile field without a backing `GlobalDefaults` field
    /// mapped in **both** `globalAgentModelsProfile()` and `setGlobalAgentModelsProfile` is
    /// dropped on the next read.
    func testAgentModelParameterPinsSurviveCodecAndGlobalDecomposition() throws {
        let pin = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: "ollama-cloud/kimi-k3",
            kind: .thinking,
            configID: "effort",
            valueRaw: "high"
        )
        let cbPin = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: "ollama-cloud/kimi-k3",
            kind: .thinking,
            configID: "effort",
            valueRaw: "low"
        )
        let profile = AgentModelsSettingsProfile(
            contextBuilderAgentRaw: "openCode",
            contextBuilderModelsByAgent: ["openCode": "ollama-cloud/kimi-k3"],
            mcpAgentRoleOverrides: ["engineer": "openCode:ollama-cloud/kimi-k3"],
            mcpAgentRoleModelParameters: ["engineer": [pin]],
            contextBuilderModelParametersByAgent: ["openCode": [cbPin]]
        )

        // Codec round-trip.
        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: encoded)
        XCTAssertEqual(decoded.mcpAgentRoleModelParameters?["engineer"], [pin])
        XCTAssertEqual(decoded.contextBuilderModelParametersByAgent?["openCode"], [cbPin])

        // Global decomposition: set → read through the backing GlobalDefaults store.
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        let suiteName = "GlobalSettingsPersistenceSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .userInitiated)
        let readBack = store.globalAgentModelsProfile()
        XCTAssertEqual(readBack.mcpAgentRoleModelParameters?["engineer"], [pin])
        XCTAssertEqual(readBack.contextBuilderModelParametersByAgent?["openCode"], [cbPin])
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
        legacyAnalysisTokenBudget: Int = 67890,
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
            legacy.discoveryPlanTokenBudget = legacyAnalysisTokenBudget
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

    private func makeContextBuilderSettings(
        analysisTokenBudget: Int = 56780
    ) -> GlobalScalarPreferences.ContextBuilderSettings {
        GlobalScalarPreferences.ContextBuilderSettings(
            contextTokenBudget: 1234,
            analysisTokenBudget: analysisTokenBudget,
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
