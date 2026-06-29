import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class SettingsJSONOnlyPersistenceTests: XCTestCase {
    func testDefaultGlobalSettingsPathUsesCESupportRoot() {
        let path = GlobalSettingsFileStore.defaultFileURL().path
        XCTAssertTrue(path.contains("/Application Support/RepoPrompt CE/Settings/globalSettings.json"), path)
        XCTAssertFalse(path.contains("/Application Support/RepoPrompt/Settings/globalSettings.json"), path)
    }

    func testMissingGlobalSettingsCreatesCurrentDefaultsAndIgnoresLegacyDefaults() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "respectGitignore")

        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(store.respectGitignore())
        XCTAssertTrue(store.respectRepoIgnore())
        XCTAssertTrue(store.respectCursorignore())
        XCTAssertTrue(store.skipSymlinks())
    }

    func testExplicitJSONRespectGitignoreFalseIsPreserved() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(
                fileSystem: .init(respectGitignore: false)
            )
        ))

        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: fileStore
        )

        XCTAssertFalse(store.respectGitignore())
    }

    func testWorktreeVisualIdentityDefaultsAreEmptyAndFallbackDoesNotPersist() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: fileStore
        )
        let before = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertTrue(store.worktreeVisualIdentitiesByRepositoryID().isEmpty)
        let fallback = store.resolvedWorktreeVisualIdentity(
            repositoryID: "gitrepo_alpha",
            worktreeID: "wt_feature",
            fallbackLabel: "Feature",
            fallbackIconName: "leaf.fill",
            fallbackMarkerStyle: .ring
        )

        XCTAssertEqual(fallback.label, "Feature")
        XCTAssertTrue(GlobalSettingsStore.isValidWorktreeColorHex(fallback.colorHex))
        XCTAssertEqual(fallback.iconName, "leaf.fill")
        XCTAssertEqual(fallback.markerStyle, .ring)
        XCTAssertNil(fallback.updatedAt)
        XCTAssertNil(store.worktreeVisualIdentity(repositoryID: "gitrepo_alpha", worktreeID: "wt_feature"))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), before)
    }

    func testWorktreeVisualIdentitySavesAndLoads() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        let updatedAt = Date(timeIntervalSince1970: 1800)

        let identity = try store.ensureWorktreeVisualIdentity(
            repositoryID: " gitrepo_alpha ",
            worktreeID: " wt_feature ",
            label: " Feature ",
            colorHex: "#aabbcc",
            iconName: " folder.badge.gearshape ",
            markerStyle: .capsule,
            updatedAt: updatedAt
        )

        XCTAssertEqual(identity, WorktreeVisualIdentity(
            label: "Feature",
            colorHex: "#AABBCC",
            iconName: "folder.badge.gearshape",
            markerStyle: .capsule,
            updatedAt: updatedAt
        ))

        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertEqual(
            reloaded.worktreeVisualIdentity(repositoryID: "gitrepo_alpha", worktreeID: "wt_feature"),
            WorktreeVisualIdentity(
                label: "Feature",
                colorHex: "#AABBCC",
                iconName: "folder.badge.gearshape",
                markerStyle: .capsule,
                updatedAt: updatedAt
            )
        )
        XCTAssertEqual(
            reloaded.worktreeVisualIdentitiesByRepositoryID()["gitrepo_alpha"]?.identitiesByWorktreeID.keys.sorted(),
            ["wt_feature"]
        )
    }

    func testWorktreeVisualIdentityRejectsInvalidColors() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertThrowsError(try store.ensureWorktreeVisualIdentity(
            repositoryID: "gitrepo_alpha",
            worktreeID: "wt_feature",
            colorHex: "AABBCC"
        )) { error in
            XCTAssertEqual(error as? GlobalSettingsStore.WorktreeVisualIdentityError, .invalidColorHex("AABBCC"))
        }
    }

    func testWorktreeVisualIdentityDecodesMissingUXFieldsWithDefaults() throws {
        let json = """
        {"schemaVersion":4,"updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{"worktreeVisualIdentitiesByRepositoryID":{"gitrepo_alpha":{"identitiesByWorktreeID":{"wt_feature":{"label":"Feature","colorHex":"#112233"}}}}},"scalarPreferences":{}}
        """
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)

        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertEqual(
            store.worktreeVisualIdentity(repositoryID: "gitrepo_alpha", worktreeID: "wt_feature"),
            WorktreeVisualIdentity(
                label: "Feature",
                colorHex: "#112233",
                iconName: WorktreeVisualIdentity.defaultIconName,
                markerStyle: WorktreeVisualIdentity.defaultMarkerStyle
            )
        )
    }

    func testWorktreeVisualIdentityDecodesMissingFieldWithoutSchemaBump() throws {
        let json = #"{"schemaVersion":4,"updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{}}"#
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)

        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertEqual(GlobalSettingsDocument.currentSchemaVersion, 4)
        XCTAssertTrue(store.worktreeVisualIdentitiesByRepositoryID().isEmpty)
    }

    func testCorruptGlobalSettingsIsBackedUpAndReplacedWithDefaults() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        let fileStore = GlobalSettingsFileStore(fileURL: fileURL, now: { Date(timeIntervalSince1970: 0) })
        let document = fileStore.loadOrCreateDefault()

        XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.currentSchemaVersion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let backupDirectory = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)
        XCTAssertTrue(backups.contains { $0.hasPrefix("globalSettings.corrupt-") })
    }

    func testFutureGlobalSettingsSchemaIsPreservedAndSaveIsBlocked() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let futureJSON = #"{"schemaVersion":999,"updatedAt":"2026-05-20T00:00:00Z"}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let document = fileStore.loadOrCreateDefault()

        XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.currentSchemaVersion)
        let preserved = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(preserved, futureJSON)
        XCTAssertThrowsError(try fileStore.save(GlobalSettingsDocument())) { error in
            XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .unsupportedFutureSchemaPreserved)
        }
    }

    func testDirectFutureGlobalSettingsLoadProtectsLaterSave() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(GlobalSettingsDocument())

        let futureJSON = #"{"schemaVersion":999,"updatedAt":"2026-05-20T00:00:00Z"}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        XCTAssertThrowsError(try fileStore.load()) { error in
            XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .unsupportedFutureSchema(999))
        }
        XCTAssertThrowsError(try fileStore.save(GlobalSettingsDocument())) { error in
            XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .unsupportedFutureSchemaPreserved)
        }
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), futureJSON)
    }

    func testFileMentionPickerStyleDefaultsToCompactWithoutPersistingRawSetting() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: fileStore
        )
        let before = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertEqual(store.fileMentionPickerStyle(), .compact)
        XCTAssertEqual(store.fileMentionPickerConfiguration(), .compact)
        XCTAssertNil(try fileStore.load().scalarPreferences?.ui?.fileMentionPickerStyle)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), before)
    }

    func testFileMentionPickerStyleSavesAndLoadsExpandedRawValue() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        store.setFileMentionPickerStyle(.expanded)

        XCTAssertEqual(try fileStore.load().scalarPreferences?.ui?.fileMentionPickerStyle, "expanded")
        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertEqual(reloaded.fileMentionPickerStyle(), .expanded)
        XCTAssertEqual(reloaded.fileMentionPickerConfiguration(), .expanded)
    }

    func testInvalidFileMentionPickerStyleRawDefaultsToCompactWithoutReadTimeMutation() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(
                ui: .init(fileMentionPickerStyle: "wide")
            )
        ))

        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: fileStore
        )

        XCTAssertEqual(store.fileMentionPickerStyle(), .compact)
        XCTAssertEqual(store.fileMentionPickerConfiguration(), .compact)
        XCTAssertEqual(try fileStore.load().scalarPreferences?.ui?.fileMentionPickerStyle, "wide")
    }

    func testShowDatesInMessageTimestampsDefaultsFalseWithoutPersisting() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(ui: .init(showTooltips: false))
        ))
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        let before = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertFalse(store.showDatesInMessageTimestamps())
        XCTAssertNil(try fileStore.load().scalarPreferences?.ui?.showDatesInMessageTimestamps)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), before)
    }

    func testShowDatesInMessageTimestampsSavesAndLoadsTrue() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        store.setShowDatesInMessageTimestamps(true)

        XCTAssertEqual(try fileStore.load().scalarPreferences?.ui?.showDatesInMessageTimestamps, true)
        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertTrue(reloaded.showDatesInMessageTimestamps())
    }

    func testAgentModelsMissingDefaultsResolveGlobalWithoutPersistingWorkspaceProfile() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = try GlobalSettingsStore(
            defaults: makeIsolatedDefaults(),
            fileStore: fileStore
        )
        let workspaceID = UUID()
        let before = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertEqual(store.globalAgentModelsProfile(), AgentModelsSettingsProfile())
        XCTAssertEqual(
            store.workspaceAgentModelsSettings(for: workspaceID),
            WorkspaceAgentModelsSettings()
        )
        XCTAssertNil(store.workspaceAgentModelsProfile(for: workspaceID))
        XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID), store.globalAgentModelsProfile())
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), before)
        XCTAssertTrue(try (fileStore.load()).agentModelsSettings.isEmpty)
    }

    func testAgentModelsPreviousSchemaLoadSavesAsV4WithWorkspaceProfiles() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let codexAgent = AgentProviderKind.codexExec.rawValue
        let codexModel = AgentModelCatalog.defaultModelRaw(for: .codexExec)
        let planningModel = AIModel.gpt54Pro.rawValue
        let composeModel = AIModel.claude4Sonnet.rawValue
        let json = """
        {
          "schemaVersion": 3,
          "updatedAt": "2026-05-20T00:00:00Z",
          "copySettingsByWorkspaceID": {},
          "chatSettingsByWorkspaceID": {},
          "globalDefaults": {
            "discoverAgentRaw": "\(codexAgent)",
            "discoverModelsByAgent": { "\(codexAgent)": "\(codexModel)" },
            "mcpAgentRoleOverrides": { "plan": " codexExec:test-model " }
          },
          "scalarPreferences": {
            "fileSystem": { "globalIgnoreDefaults": "" },
            "modelSelection": {
              "planningModel": "\(planningModel)",
              "preferredComposeModel": "\(composeModel)",
              "syncChatModelWithOracle": false
            },
            "agentMode": { "restrictMCPAgentDiscoveryToRoleLabels": true }
          }
        }
        """
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)

        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let workspaceID = UUID()
        store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)

        let saved = try fileStore.load()
        XCTAssertEqual(saved.schemaVersion, 4)
        XCTAssertEqual(
            saved.agentModelsSettings[workspaceID]?.profile,
            AgentModelsSettingsProfile(
                planningModelRaw: planningModel,
                preferredComposeModelRaw: composeModel,
                syncChatModelWithOracle: false,
                contextBuilderAgentRaw: codexAgent,
                contextBuilderModelsByAgent: [codexAgent: codexModel],
                mcpAgentRoleOverrides: ["plan": "codexExec:test-model"],
                restrictMCPAgentDiscoveryToRoleLabels: true
            )
        )
    }

    func testAgentModelsWorkspaceProfilesSurviveUnrelatedWrites() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let workspaceID = UUID()
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Pro.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: false,
            contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
            contextBuilderModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModelCatalog.defaultModelRaw(for: .claudeCode)
            ],
            mcpAgentRoleOverrides: ["review": "claudeCode:opus"],
            restrictMCPAgentDiscoveryToRoleLabels: true
        )
        try fileStore.save(GlobalSettingsDocument(
            agentModelsSettings: [
                workspaceID: WorkspaceAgentModelsSettings(
                    inheritanceMode: .useWorkspaceOverrides,
                    profile: profile
                )
            ],
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)

        store.setShowDatesInMessageTimestamps(true)
        store.updateCopySettings(CopyGlobalSettings(workspaceID: UUID()))

        let saved = try fileStore.load()
        XCTAssertEqual(saved.agentModelsSettings[workspaceID]?.inheritanceMode, .useWorkspaceOverrides)
        XCTAssertEqual(saved.agentModelsSettings[workspaceID]?.profile, profile)
        XCTAssertEqual(saved.scalarPreferences?.ui?.showDatesInMessageTimestamps, true)
        XCTAssertFalse(saved.copySettings.isEmpty)
    }

    func testAgentModelsProfilePreservesUnknownContextBuilderProviderAndModelRawValues() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileStore = GlobalSettingsFileStore(
            fileURL: temp.appendingPathComponent("Settings/globalSettings.json")
        )
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let workspaceID = UUID()
        let unknownAgent = "future-agent"
        let unknownModel = "future-model-v9"
        let profile = AgentModelsSettingsProfile(
            contextBuilderAgentRaw: "  \(unknownAgent)  ",
            contextBuilderModelsByAgent: ["  \(unknownAgent)  ": "  \(unknownModel)  "]
        )

        store.setGlobalAgentModelsProfile(
            profile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: profile)
        store.setShowDatesInMessageTimestamps(true)

        let reloaded = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        XCTAssertEqual(reloaded.globalAgentModelsProfile().contextBuilderAgentRaw, unknownAgent)
        XCTAssertEqual(
            reloaded.globalAgentModelsProfile().contextBuilderModelsByAgent?[unknownAgent],
            unknownModel
        )
        XCTAssertEqual(
            reloaded.workspaceAgentModelsProfile(for: workspaceID)?.contextBuilderAgentRaw,
            unknownAgent
        )
        XCTAssertEqual(
            reloaded.workspaceAgentModelsProfile(for: workspaceID)?.contextBuilderModelsByAgent?[unknownAgent],
            unknownModel
        )
    }

    func testLegacyGlobalAgentModelsBackingWritersPostGlobalNotifications() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }

        store.setPlanningModelRaw(AIModel.gpt54Pro.rawValue)
        XCTAssertEqual(recorder.snapshot().count, 1)
        store.setPreferredComposeModelRaw(AIModel.claude4Sonnet.rawValue)
        XCTAssertEqual(recorder.snapshot().count, 2)
        store.setSyncChatModelWithOracle(true)
        XCTAssertEqual(recorder.snapshot().count, 3)
        store.updateGlobalMCPAgentRoleOverrides(["plan": "codexExec:test-model"])
        XCTAssertEqual(recorder.snapshot().count, 4)
        store.setRestrictMCPAgentDiscoveryToRoleLabels(true)
        XCTAssertEqual(recorder.snapshot().count, 5)

        store.setPlanningModelRaw(AIModel.gpt54Pro.rawValue)
        XCTAssertEqual(recorder.snapshot().count, 5)
        store.setPreferredComposeModelRaw(AIModel.claude4Sonnet.rawValue)
        XCTAssertEqual(recorder.snapshot().count, 5)
        store.setSyncChatModelWithOracle(true)
        XCTAssertEqual(recorder.snapshot().count, 5)
        store.updateGlobalMCPAgentRoleOverrides(["plan": "codexExec:test-model"])
        XCTAssertEqual(recorder.snapshot().count, 5)
        store.setRestrictMCPAgentDiscoveryToRoleLabels(true)
        XCTAssertEqual(recorder.snapshot().count, 5)

        let notifications = recorder.snapshot()
        XCTAssertEqual(notifications.count, 5)
        XCTAssertTrue(notifications.allSatisfy {
            $0.scope == AgentModelsSettingsNotification.Scope.global.rawValue
                && $0.workspaceID == nil
        })
    }

    func testPromptAgentModelsNotificationRefreshDoesNotWriteBack() async throws {
        let workspaceID = UUID()
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            copySettings: [workspaceID: CopyGlobalSettings(workspaceID: workspaceID)],
            chatSettings: [workspaceID: ChatGlobalSettings(workspaceID: workspaceID)],
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let manager = WindowSettingsManager(windowID: -303, store: store)
        let fileManager = WorkspaceFilesViewModel()
        fileManager.setCurrentWorkspaceID(workspaceID)
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: makeAPISettingsViewModel(),
            windowID: -303,
            settingsManager: manager
        )
        let originalCopyFileTreeOption = fileStore.document.copySettings[workspaceID]?.fileTreeOption
        let originalChatFileTreeOption = fileStore.document.chatSettings[workspaceID]?.fileTreeOption
        fileStore.saveCount = 0
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }

        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54Pro.rawValue),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        await drainMainQueue()

        XCTAssertEqual(fileStore.saveCount, 1)
        XCTAssertEqual(recorder.snapshot().count, 1)
        XCTAssertEqual(fileStore.document.copySettings.count, 1)
        XCTAssertEqual(fileStore.document.chatSettings.count, 1)
        XCTAssertEqual(
            fileStore.document.copySettings[workspaceID]?.fileTreeOption,
            originalCopyFileTreeOption
        )
        XCTAssertEqual(
            fileStore.document.chatSettings[workspaceID]?.fileTreeOption,
            originalChatFileTreeOption
        )
        XCTAssertEqual(prompt.planningModelName, AIModel.gpt54Pro.rawValue)
    }

    func testAgentModelsViewModelDoesNotFallbackUnsyncedBuiltinChatToOracle() async throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let manager = WindowSettingsManager(windowID: -404, store: store)
        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54Pro.rawValue,
                preferredComposeModelRaw: nil,
                syncChatModelWithOracle: false
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        let viewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: makeAPISettingsViewModel(),
            settingsManager: manager,
            settingsStore: store
        )

        XCTAssertEqual(viewModel.currentBuiltinChatModelName, "Select a Built-in Chat model")

        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54Pro.rawValue,
                preferredComposeModelRaw: nil,
                syncChatModelWithOracle: true
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        await drainMainQueue()

        XCTAssertEqual(viewModel.currentBuiltinChatModelName, AIModel.gpt54Pro.displayName)
    }

    func testAgentModelsViewModelBlankBuiltinChatDoesNotMirrorToOracleWhenSynced() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let manager = WindowSettingsManager(windowID: -405, store: store)
        let blankRaw = " \n\t "

        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54Pro.rawValue,
                preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
                syncChatModelWithOracle: true
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        let globalViewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: makeAPISettingsViewModel(),
            settingsManager: manager,
            settingsStore: store
        )

        globalViewModel.setBuiltinChatModel(raw: blankRaw)

        XCTAssertEqual(store.globalAgentModelsProfile().planningModelRaw, AIModel.gpt54Pro.rawValue)

        let workspaceID = UUID()
        store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54Pro.rawValue,
                preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
                syncChatModelWithOracle: true
            )
        )
        let workspaceViewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: makeAPISettingsViewModel(),
            workspaceID: workspaceID,
            workspaceName: "Scoped blank guard",
            settingsManager: manager,
            settingsStore: store
        )

        workspaceViewModel.setBuiltinChatModel(raw: blankRaw)

        XCTAssertEqual(
            store.workspaceAgentModelsProfile(for: workspaceID)?.planningModelRaw,
            AIModel.gpt54Pro.rawValue
        )
    }

    func testAgentModelsGlobalProfileRoundTripsExistingFieldsWithOneSaveAndNotification() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        fileStore.saveCount = 0
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }
        let codexAgent = AgentProviderKind.codexExec.rawValue
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: " \(AIModel.gpt54Pro.rawValue) ",
            preferredComposeModelRaw: " \(AIModel.claude4Sonnet.rawValue) ",
            syncChatModelWithOracle: false,
            contextBuilderAgentRaw: codexAgent,
            contextBuilderModelsByAgent: [codexAgent: AgentModelCatalog.defaultModelRaw(for: .codexExec)],
            mcpAgentRoleOverrides: [" plan ": " codexExec:test-model "],
            restrictMCPAgentDiscoveryToRoleLabels: true
        )

        store.setGlobalAgentModelsProfile(
            profile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )

        let expected = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Pro.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: false,
            contextBuilderAgentRaw: codexAgent,
            contextBuilderModelsByAgent: [codexAgent: AgentModelCatalog.defaultModelRaw(for: .codexExec)],
            mcpAgentRoleOverrides: ["plan": "codexExec:test-model"],
            restrictMCPAgentDiscoveryToRoleLabels: true
        )
        XCTAssertEqual(fileStore.saveCount, 1)
        let notifications = recorder.snapshot()
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.scope, AgentModelsSettingsNotification.Scope.global.rawValue)
        XCTAssertNil(notifications.first?.workspaceID)
        XCTAssertEqual(store.globalAgentModelsProfile(), expected)
        let diagnostic = try XCTUnwrap(store.recentSettingsWriteDiagnostics().last)
        XCTAssertEqual(diagnostic.key, "agentModelsProfile.global")
        XCTAssertEqual(diagnostic.reason, "agent_models.profile.global")
        XCTAssertTrue(diagnostic.newValue?.contains("planning=\(AIModel.gpt54Pro.rawValue)") == true)
        XCTAssertEqual(fileStore.document.scalarPreferences?.modelSelection?.planningModel, expected.planningModelRaw)
        XCTAssertEqual(fileStore.document.scalarPreferences?.modelSelection?.preferredComposeModel, expected.preferredComposeModelRaw)
        XCTAssertEqual(fileStore.document.scalarPreferences?.modelSelection?.syncChatModelWithOracle, false)
        XCTAssertEqual(fileStore.document.scalarPreferences?.agentMode?.restrictMCPAgentDiscoveryToRoleLabels, true)
        XCTAssertEqual(fileStore.document.globalDefaults.discoverAgentRaw, codexAgent)
        XCTAssertEqual(fileStore.document.globalDefaults.discoverModelsByAgent, expected.contextBuilderModelsByAgent)
        XCTAssertEqual(fileStore.document.globalDefaults.mcpAgentRoleOverrides, expected.mcpAgentRoleOverrides)
    }

    func testLegacyGlobalContextBuilderSetterPostsAgentModelsNotification() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        fileStore.saveCount = 0
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }
        let codexAgent = AgentProviderKind.codexExec.rawValue
        let codexModel = AgentModelCatalog.defaultModelRaw(for: .codexExec)

        store.setGlobalContextBuilderAgentSelection(
            agentRaw: codexAgent,
            modelRaw: codexModel,
            markUserDefined: true
        )

        var notifications = recorder.snapshot()
        XCTAssertEqual(fileStore.saveCount, 1)
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.last?.scope, AgentModelsSettingsNotification.Scope.global.rawValue)
        XCTAssertNil(notifications.last?.workspaceID)
        XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderAgentRaw, codexAgent)
        XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderModelsByAgent?[codexAgent], codexModel)

        store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.claudeCode.rawValue,
            modelRaw: String?.none,
            markUserDefined: true
        )

        notifications = recorder.snapshot()
        XCTAssertEqual(fileStore.saveCount, 2)
        XCTAssertEqual(notifications.count, 2)
        XCTAssertEqual(notifications.last?.scope, AgentModelsSettingsNotification.Scope.global.rawValue)
        XCTAssertNil(notifications.last?.workspaceID)
        XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderAgentRaw, AgentProviderKind.claudeCode.rawValue)
    }

    func testAgentModelsWorkspaceOverrideMaterializesAndCopiesGlobalToWorkspace() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let workspaceID = UUID()
        let globalProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Pro.rawValue,
            preferredComposeModelRaw: AIModel.gpt54Pro.rawValue,
            syncChatModelWithOracle: true,
            contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
            contextBuilderModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModelCatalog.defaultModelRaw(for: .claudeCode)
            ],
            mcpAgentRoleOverrides: ["code": "claudeCode:sonnet"],
            restrictMCPAgentDiscoveryToRoleLabels: true
        )
        store.setGlobalAgentModelsProfile(
            globalProfile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fileStore.saveCount = 0
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }

        store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)

        XCTAssertEqual(fileStore.saveCount, 1)
        XCTAssertEqual(recorder.snapshot().count, 1)
        XCTAssertEqual(
            store.workspaceAgentModelsSettings(for: workspaceID),
            WorkspaceAgentModelsSettings(inheritanceMode: .useWorkspaceOverrides, profile: globalProfile)
        )
        XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID), globalProfile)
        let diagnostic = try XCTUnwrap(store.recentSettingsWriteDiagnostics().last)
        XCTAssertEqual(diagnostic.key, "agentModelsProfile.workspace.\(workspaceID.uuidString)")
        XCTAssertEqual(diagnostic.reason, "agent_models.profile.workspace")

        let secondWorkspaceID = UUID()
        store.copyAgentModelsProfile(from: .global, to: .workspace(secondWorkspaceID))
        XCTAssertEqual(
            store.workspaceAgentModelsSettings(for: secondWorkspaceID),
            WorkspaceAgentModelsSettings(inheritanceMode: .useWorkspaceOverrides, profile: globalProfile)
        )
    }

    func testAgentModelsCopyWorkspaceToGlobalOverwritesContextBuilderModelMap() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let workspaceID = UUID()
        let codexAgent = AgentProviderKind.codexExec.rawValue
        let claudeAgent = AgentProviderKind.claudeCode.rawValue
        store.setGlobalAgentModelsProfile(AgentModelsSettingsProfile(
            planningModelRaw: AIModel.claude4Sonnet.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: true,
            contextBuilderAgentRaw: codexAgent,
            contextBuilderModelsByAgent: [codexAgent: AgentModelCatalog.defaultModelRaw(for: .codexExec)],
            mcpAgentRoleOverrides: ["old": "codexExec:old"],
            restrictMCPAgentDiscoveryToRoleLabels: false
        ), contextBuilderWriteIntent: .preserveExistingOwnership)
        let workspaceProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Pro.rawValue,
            preferredComposeModelRaw: nil,
            syncChatModelWithOracle: false,
            contextBuilderAgentRaw: claudeAgent,
            contextBuilderModelsByAgent: [claudeAgent: AgentModelCatalog.defaultModelRaw(for: .claudeCode)],
            mcpAgentRoleOverrides: ["new": "claudeCode:new"],
            restrictMCPAgentDiscoveryToRoleLabels: true
        )
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)
        store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
        fileStore.saveCount = 0
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }

        store.copyAgentModelsProfile(from: .workspace(workspaceID), to: .global)

        XCTAssertEqual(fileStore.saveCount, 1)
        let notifications = recorder.snapshot()
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.scope, AgentModelsSettingsNotification.Scope.global.rawValue)
        XCTAssertEqual(store.globalAgentModelsProfile(), workspaceProfile)
        XCTAssertEqual(fileStore.document.globalDefaults.discoverModelsByAgent, workspaceProfile.contextBuilderModelsByAgent)
        XCTAssertNil(fileStore.document.globalDefaults.discoverModelsByAgent?[codexAgent])
        XCTAssertEqual(fileStore.document.globalDefaults.mcpAgentRoleOverrides, workspaceProfile.mcpAgentRoleOverrides)
        XCTAssertTrue(store.hasUserSetGlobalContextBuilderAgentDefaults)
    }

    func testAgentModelsWindowSettingsManagerBoundaryRoutesScopedWritesAndCopies() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let manager = WindowSettingsManager(windowID: -101, store: store)
        let workspaceID = UUID()
        let globalProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.claude4Sonnet.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: true
        )
        let workspaceProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Pro.rawValue,
            preferredComposeModelRaw: AIModel.gpt54Pro.rawValue,
            syncChatModelWithOracle: false,
            contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
            contextBuilderModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModelCatalog.defaultModelRaw(for: .claudeCode)
            ]
        )
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }

        manager.setGlobalAgentModelsProfile(
            globalProfile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        manager.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)

        XCTAssertEqual(store.globalAgentModelsProfile(), globalProfile)
        XCTAssertEqual(manager.workspaceAgentModelsProfile(for: workspaceID), workspaceProfile)
        XCTAssertEqual(store.workspaceAgentModelsProfile(for: workspaceID), workspaceProfile)

        manager.copyAgentModelsProfile(from: .workspace(workspaceID), to: .global)

        XCTAssertEqual(store.globalAgentModelsProfile(), manager.workspaceAgentModelsProfile(for: workspaceID))
        let notifications = recorder.snapshot()
        XCTAssertTrue(notifications.contains { $0.scope == AgentModelsSettingsNotification.Scope.global.rawValue })
        XCTAssertTrue(notifications.contains { entry in
            entry.scope == AgentModelsSettingsNotification.Scope.workspace.rawValue && entry.workspaceID == workspaceID
        })
    }

    func testAgentModelsViewModelUsesInjectedSettingsManagerForScopedReadsWritesCopiesAndNotifications() async throws {
        let managerFileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let managerStore = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: managerFileStore)
        let engineStore = try GlobalSettingsStore(
            defaults: makeIsolatedDefaults(),
            fileStore: CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
                globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
                scalarPreferences: seededScalarPreferences()
            ))
        )
        let manager = WindowSettingsManager(windowID: -202, store: managerStore)
        let workspaceID = UUID()
        let globalProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.claude4Sonnet.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: true
        )
        var workspaceProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.claude4Sonnet.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: false,
            contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
            contextBuilderModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModelCatalog.defaultModelRaw(for: .claudeCode)
            ]
        )
        manager.setGlobalAgentModelsProfile(
            globalProfile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        manager.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)
        manager.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
        let engineWorkspaceProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Pro.rawValue,
            preferredComposeModelRaw: AIModel.gpt54Pro.rawValue,
            syncChatModelWithOracle: false
        )
        engineStore.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: engineWorkspaceProfile
        )

        let apiSettings = makeAPISettingsViewModel()
        apiSettings.isOpenAIKeyValid = true
        let viewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: apiSettings,
            workspaceID: workspaceID,
            workspaceName: "Scoped test",
            settingsManager: manager,
            settingsStore: engineStore
        )

        XCTAssertTrue(viewModel.isEditingWorkspaceSettings)
        XCTAssertEqual(viewModel.profileSnapshot.planningModelRaw, workspaceProfile.planningModelRaw)
        XCTAssertFalse(
            viewModel.isOracleRecommendationSatisfied,
            "Recommendation satisfaction must read the injected manager profile, not the engine store."
        )

        viewModel.setOracleModel(raw: AIModel.codexCliGpt55CodexHigh.rawValue)

        XCTAssertEqual(
            managerStore.workspaceAgentModelsProfile(for: workspaceID)?.planningModelRaw,
            AIModel.codexCliGpt55CodexHigh.rawValue
        )
        XCTAssertEqual(
            engineStore.workspaceAgentModelsProfile(for: workspaceID),
            engineWorkspaceProfile,
            "Scoped writes must route through the injected SettingsManaging boundary, not the engine/global store."
        )
        XCTAssertEqual(managerStore.globalAgentModelsProfile(), globalProfile)

        viewModel.applyOracleRecommendation()

        XCTAssertEqual(
            managerStore.workspaceAgentModelsProfile(for: workspaceID)?.planningModelRaw,
            AIModel.gpt54Pro.rawValue
        )
        XCTAssertEqual(
            engineStore.workspaceAgentModelsProfile(for: workspaceID),
            engineWorkspaceProfile,
            "Recommendation apply must also route scoped Agent Models writes through the injected SettingsManaging boundary."
        )

        workspaceProfile.planningModelRaw = AIModel.claude4Opus.rawValue
        manager.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)
        await drainMainQueue()

        XCTAssertEqual(viewModel.profileSnapshot.planningModelRaw, AIModel.claude4Opus.rawValue)

        viewModel.copyWorkspaceSettingsToGlobal()

        XCTAssertEqual(managerStore.globalAgentModelsProfile(), workspaceProfile)
        XCTAssertNotEqual(engineStore.globalAgentModelsProfile(), workspaceProfile)
    }

    func testAgentModelsViewModelReportsStoredRecommendedRolePinAsOverrideAndClearsIt() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let manager = WindowSettingsManager(windowID: -203, store: store)
        let workspaceID = UUID()
        let role = AgentModelCatalog.TaskLabelKind.explore
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )
        let baselineResolution = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: role,
            availability: availability,
            recommendedAvailability: availability,
            settingsStore: AgentModelsProfileRoleDefaultsStore(overrides: nil)
        ))
        let recommendedPin = AgentModelSelectionID(
            agentRaw: baselineResolution.recommended.agent.rawValue,
            modelRaw: baselineResolution.recommended.modelRaw
        ).rawValue
        let workspaceProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.claude4Sonnet.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: true,
            mcpAgentRoleOverrides: [role.rawValue: recommendedPin]
        )
        manager.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)
        manager.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)

        let apiSettings = makeAPISettingsViewModel()
        apiSettings.isClaudeCodeConnected = false
        apiSettings.isCodexConnected = true
        apiSettings.isOpenCodeConnected = false
        apiSettings.isCursorConnected = false
        let viewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: apiSettings,
            workspaceID: workspaceID,
            workspaceName: "Pinned role defaults",
            settingsManager: manager,
            settingsStore: store
        )

        let pinnedResolution = try XCTUnwrap(viewModel.roleDefaultsResolutions.first { $0.role == role })
        XCTAssertEqual(pinnedResolution.effective, pinnedResolution.recommended)
        XCTAssertTrue(pinnedResolution.hasStoredOverride)
        XCTAssertFalse(pinnedResolution.hasCustomOverride)
        XCTAssertTrue(viewModel.roleDefaultsHasOverrides)

        viewModel.applyRoleDefault(pinnedResolution)

        XCTAssertNil(viewModel.profileSnapshot.mcpAgentRoleOverrides)
        XCTAssertNil(store.workspaceAgentModelsProfile(for: workspaceID)?.mcpAgentRoleOverrides)
        let clearedResolution = try XCTUnwrap(viewModel.roleDefaultsResolutions.first { $0.role == role })
        XCTAssertFalse(clearedResolution.hasStoredOverride)
        XCTAssertFalse(clearedResolution.hasCustomOverride)
        XCTAssertFalse(viewModel.roleDefaultsHasOverrides)
    }

    private func makeAPISettingsViewModel() -> APISettingsViewModel {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        return APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 1.0)
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func seededScalarPreferences(
        ui: GlobalScalarPreferences.UISettings? = nil,
        modelSelection: GlobalScalarPreferences.ModelSelectionSettings? = nil,
        agentMode: GlobalScalarPreferences.AgentModeSettings? = nil
    ) -> GlobalScalarPreferences {
        GlobalScalarPreferences(
            ui: ui,
            modelSelection: modelSelection,
            fileSystem: .init(globalIgnoreDefaults: IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults),
            agentMode: agentMode
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsJSONOnlyPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class CountingGlobalSettingsFileStore: GlobalSettingsFileStoring {
    let fileURL: URL
    var document: GlobalSettingsDocument
    var saveCount = 0

    init(document: GlobalSettingsDocument) {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CountingGlobalSettingsFileStore-\(UUID().uuidString).json")
        self.document = document
    }

    func load() throws -> GlobalSettingsDocument {
        document
    }

    func loadOrCreateDefault() -> GlobalSettingsDocument {
        document
    }

    func save(_ document: GlobalSettingsDocument) throws {
        saveCount += 1
        var saved = document
        saved.schemaVersion = max(saved.schemaVersion, GlobalSettingsDocument.currentSchemaVersion)
        self.document = saved
    }
}

private final class AgentModelsNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(scope: String?, workspaceID: UUID?)] = []
    private var token: NSObjectProtocol?

    init(observing object: AnyObject) {
        token = NotificationCenter.default.addObserver(
            forName: .agentModelsSettingsDidChange,
            object: object,
            queue: nil
        ) { [weak self] notification in
            self?.record(notification)
        }
    }

    func invalidate() {
        guard let token else { return }
        NotificationCenter.default.removeObserver(token)
        self.token = nil
    }

    func snapshot() -> [(scope: String?, workspaceID: UUID?)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    private func record(_ notification: Notification) {
        let scope = notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
        let workspaceID = notification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey] as? UUID
        lock.lock()
        entries.append((scope: scope, workspaceID: workspaceID))
        lock.unlock()
    }
}
