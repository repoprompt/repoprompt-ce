import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptShared
import XCTest

@MainActor
final class AppSettingsMCPServiceAgentModeSettingsTests: XCTestCase {
    func testOracleRosterSettingIsOrderedValidatedAndPersistedAsSchemaV7() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceOracleRosterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceOracleRosterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileURL = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        let service = AppSettingsMCPService(store: store)
        let key = "models.additional_oracle_models"

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("models"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let catalog = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
        XCTAssertEqual(catalog.objectValue?["type"]?.stringValue, "string[]")
        XCTAssertEqual(catalog.objectValue?["value"]?.arrayValue, [])

        let set = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .array([.string(" model-a "), .string("model-a"), .string("model-b")])
        ])
        XCTAssertEqual(
            set.objectValue?["new_value"]?.arrayValue?.compactMap(\.stringValue),
            ["model-a", "model-a", "model-b"]
        )
        XCTAssertEqual(store.additionalOracleModelRaws(), ["model-a", "model-a", "model-b"])

        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(persisted?["schemaVersion"] as? Int, 7)
        let scalar = persisted?["scalarPreferences"] as? [String: Any]
        let models = scalar?["modelSelection"] as? [String: Any]
        XCTAssertEqual(models?["additionalOracleModels"] as? [String], ["model-a", "model-a", "model-b"])
        XCTAssertNil(models?["secondaryPlanningModels"])

        do {
            _ = try await service.handleForTesting([
                "op": .string("set"),
                "key": .string(key),
                "value": .array(["a", "b", "c", "d", "e"].map(Value.string))
            ])
            XCTFail("Expected an oversized roster to be rejected")
        } catch {
            // Expected: validation is atomic and leaves the previous value intact.
        }
        XCTAssertEqual(store.additionalOracleModelRaws(), ["model-a", "model-a", "model-b"])
    }

    func testCodexReasoningSummariesSettingListsReadsAndWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)
        let key = "agent_mode.codex_reasoning_summaries_enabled"

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("agent_mode"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let catalog = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
        XCTAssertEqual(catalog.objectValue?["type"]?.stringValue, "boolean")
        XCTAssertEqual(catalog.objectValue?["value"]?.boolValue, false)

        let getDefault = try await service.handleForTesting([
            "op": .string("get"),
            "key": .string(key)
        ])
        XCTAssertEqual(getDefault.objectValue?["values"]?.objectValue?[key]?.boolValue, false)

        let setTrue = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])
        XCTAssertEqual(setTrue.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(setTrue.objectValue?["old_value"]?.boolValue, false)
        XCTAssertEqual(setTrue.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(setTrue.objectValue?["changed"]?.boolValue, true)
        XCTAssertTrue(store.codexReasoningSummariesEnabled())

        let setFalse = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(false)
        ])
        XCTAssertEqual(setFalse.objectValue?["old_value"]?.boolValue, true)
        XCTAssertEqual(setFalse.objectValue?["new_value"]?.boolValue, false)
        XCTAssertEqual(setFalse.objectValue?["changed"]?.boolValue, true)
        XCTAssertFalse(store.codexReasoningSummariesEnabled())
    }

    func testAgentChatsPresentationPreferenceRemainsOutsideAppSettingsCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)
        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("agent_mode"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let keys = settings.compactMap { $0.objectValue?["key"]?.stringValue }
        let candidateKey = "agent_mode.show_compose_tabs_without_agent_sessions"
        XCTAssertFalse(keys.contains(candidateKey))

        for arguments: [String: Value] in [
            [
                "op": .string("get"),
                "key": .string(candidateKey)
            ],
            [
                "op": .string("set"),
                "key": .string(candidateKey),
                "value": .bool(true)
            ]
        ] {
            do {
                _ = try await service.handleForTesting(arguments)
                XCTFail("Expected \(candidateKey) to remain outside the app_settings catalog")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains("Unknown or unavailable app setting key '\(candidateKey)'."),
                    String(describing: error)
                )
            }
        }
    }

    func testCodexHookApprovalStrictModeIsHumanOnlyAndPersistsWorkspaceOverride() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileURL = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        let workspaceID = UUID()

        XCTAssertFalse(store.codexHookApprovalStrictModeEnabled(workspaceID: workspaceID))
        XCTAssertEqual(
            CodexHookApprovalWorkspaceSetting(
                workspaceOverride: store.codexHookApprovalStrictModeWorkspaceOverride(workspaceID: workspaceID)
            ),
            .appDefault
        )

        store.setGlobalCodexHookApprovalStrictModeEnabled(true)
        XCTAssertTrue(store.codexHookApprovalStrictModeEnabled(workspaceID: workspaceID))
        XCTAssertNil(store.codexHookApprovalStrictModeWorkspaceOverride(workspaceID: workspaceID))

        for (setting, expectedEffectiveValue) in [
            (CodexHookApprovalWorkspaceSetting.dontRequireApproval, false),
            (.alwaysRequireApproval, true),
            (.appDefault, true)
        ] {
            store.setCodexHookApprovalStrictModeOverride(setting.workspaceOverride, for: workspaceID)
            XCTAssertEqual(
                CodexHookApprovalWorkspaceSetting(
                    workspaceOverride: store.codexHookApprovalStrictModeWorkspaceOverride(workspaceID: workspaceID)
                ),
                setting
            )
            XCTAssertEqual(store.codexHookApprovalStrictModeEnabled(workspaceID: workspaceID), expectedEffectiveValue)
        }

        store.setCodexHookApprovalStrictModeOverride(
            CodexHookApprovalWorkspaceSetting.dontRequireApproval.workspaceOverride,
            for: workspaceID
        )
        let reloaded = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertTrue(reloaded.globalCodexHookApprovalStrictModeEnabled())
        XCTAssertEqual(reloaded.codexHookApprovalStrictModeWorkspaceOverride(workspaceID: workspaceID), false)
        XCTAssertFalse(reloaded.codexHookApprovalStrictModeEnabled(workspaceID: workspaceID))

        let service = AppSettingsMCPService(store: reloaded)
        for key in [
            "agent_mode.codex_hook_approval_strict_mode_enabled",
            "agent_mode.codex_hook_approval_strict_mode_workspace_overrides"
        ] {
            do {
                _ = try await service.handleForTesting([
                    "op": .string("set"),
                    "key": .string(key),
                    "value": .bool(true)
                ])
                XCTFail("Expected human-only setting rejection for \(key)")
            } catch {
                let diagnostic = String(describing: error)
                XCTAssertTrue(diagnostic.contains("security-sensitive"), diagnostic)
                XCTAssertTrue(diagnostic.contains("human"), diagnostic)
            }
        }
    }

    func testHandoffInstructionsRemainOutsideAppSettingsCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)
        let candidateKey = "agent_mode.handoff_instructions"

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("agent_mode"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let keys = settings.compactMap { $0.objectValue?["key"]?.stringValue }
        XCTAssertFalse(keys.contains(candidateKey))
        XCTAssertFalse(keys.contains { $0.localizedCaseInsensitiveContains("handoff") })

        for arguments: [String: Value] in [
            [
                "op": .string("get"),
                "key": .string(candidateKey)
            ],
            [
                "op": .string("set"),
                "key": .string(candidateKey),
                "value": .string("Must remain local")
            ]
        ] {
            do {
                _ = try await service.handleForTesting(arguments)
                XCTFail("Expected \(candidateKey) to remain outside the app_settings catalog")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains("Unknown or unavailable app setting key '\(candidateKey)'."),
                    String(describing: error)
                )
            }
        }

        XCTAssertEqual(store.agentSessionHandoffInstructions(), "")
    }

    func testModelSyncClearsAndEnablesPreserveDurableInvariant() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        let service = AppSettingsMCPService(store: store)
        let model = AIModel.gpt54Pro.rawValue

        func set(_ key: String, _ value: Value) async throws -> Value {
            try await service.handleForTesting([
                "op": .string("set"),
                "key": .string(key),
                "value": value
            ])
        }

        let rejectedEnable = try await set("models.sync_chat_model_with_oracle", .bool(true))
        XCTAssertEqual(rejectedEnable.objectValue?["new_value"]?.boolValue, false)
        XCTAssertFalse(store.syncChatModelWithOracle())

        _ = try await set("models.planning_model", .string(model))
        _ = try await set("models.preferred_compose_model", .string(AIModel.claude4Sonnet.rawValue))
        let validEnable = try await set("models.sync_chat_model_with_oracle", .bool(true))
        XCTAssertEqual(validEnable.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(store.planningModelRaw(), model)
        XCTAssertEqual(store.preferredComposeModelRaw(), model)
        XCTAssertTrue(store.syncChatModelWithOracle())

        let clearedCompose = try await set("models.preferred_compose_model", .null)
        XCTAssertNil(clearedCompose.objectValue?["new_value"]?.stringValue)
        XCTAssertEqual(store.planningModelRaw(), model)
        XCTAssertNil(store.preferredComposeModelRaw())
        XCTAssertFalse(store.syncChatModelWithOracle())

        _ = try await set("models.preferred_compose_model", .string(model))
        _ = try await set("models.sync_chat_model_with_oracle", .bool(true))
        let clearedPlanning = try await set("models.planning_model", .null)
        XCTAssertNil(clearedPlanning.objectValue?["new_value"]?.stringValue)
        XCTAssertNil(store.planningModelRaw())
        XCTAssertEqual(store.preferredComposeModelRaw(), model)
        XCTAssertFalse(store.syncChatModelWithOracle())

        let persisted = try fileStore.load()
        XCTAssertNil(persisted.scalarPreferences?.modelSelection?.planningModel)
        XCTAssertEqual(persisted.scalarPreferences?.modelSelection?.preferredComposeModel, model)
        XCTAssertEqual(persisted.scalarPreferences?.modelSelection?.syncChatModelWithOracle, false)
    }

    func testSetWarnsWhenGlobalSettingsPersistenceIsBlocked() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("globalSettings.json")
        let futureJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{}}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertEqual(
            store.persistenceBlockReason,
            .unsupportedFutureSchema(onDiskVersion: 999, supportedVersion: GlobalSettingsDocument.currentSchemaVersion)
        )

        let service = AppSettingsMCPService(store: store)
        let key = "agent_mode.codex_reasoning_summaries_enabled"
        let result = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])

        XCTAssertEqual(result.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(result.objectValue?["changed"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["persistence_blocked"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["persistence_block_reason"]?.stringValue, "unsupported_future_schema")
        XCTAssertTrue(result.objectValue?["persistence_warning"]?.stringValue?.contains("will not persist") ?? false)
        XCTAssertTrue(store.codexReasoningSummariesEnabled())
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), futureJSON)
    }

    func testSetReportsAutomaticSchemaNormalizationFailureWithoutTouchingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("globalSettings.json")
        let falseV4JSON = #"{"schemaVersion":4,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{}}"#
        try Data(falseV4JSON.utf8).write(to: fileURL)
        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(
                fileURL: fileURL,
                normalizationBackupWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
            )
        )
        let service = AppSettingsMCPService(store: store)

        let result = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string("agent_mode.codex_reasoning_summaries_enabled"),
            "value": .bool(true)
        ])

        XCTAssertEqual(
            result.objectValue?["persistence_block_reason"]?.stringValue,
            "automatic_schema_normalization_failed"
        )
        let warning = try XCTUnwrap(result.objectValue?["persistence_warning"]?.stringValue)
        XCTAssertTrue(warning.contains("applied in memory"))
        XCTAssertTrue(warning.contains("original file is preserved"))
        XCTAssertTrue(warning.contains("explicit recovery"))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), falseV4JSON)
    }

    func testContextBuilderAgentRoundTripsPreserveCodexModelAndDiskSelection() async throws {
        try await withContextBuilderSettings { store, service, defaults, fileURL in
            let codexRaw = AgentProviderKind.codexExec.rawValue
            // Recorded Run B starting state: switching to Grok must not replace this with "default".
            let codexModel = "gpt-6.1-sol-fast-high"
            store.setGlobalAgentModelsProfile(
                AgentModelsSettingsProfile(
                    contextBuilderAgentRaw: codexRaw,
                    contextBuilderModelsByAgent: [codexRaw: codexModel]
                ),
                contextBuilderWriteIntent: .userInitiated
            )

            var previousAgentRaw = codexRaw
            for (agent, seededModel, storedModel): (AgentProviderKind, String, String) in [
                (.grokBuild, "default", "default"),
                (.cursor, "auto", "cursor-custom[Cursor.Thought-Level=High,Cursor.Fast-Mode=true]")
            ] {
                let setAgent = try await service.handleForTesting([
                    "op": .string("set"),
                    "key": .string("context_builder.agent"),
                    "value": .string(agent.rawValue)
                ])
                XCTAssertEqual(setAgent.objectValue?["old_value"]?.stringValue, previousAgentRaw)
                XCTAssertEqual(setAgent.objectValue?["new_value"]?.stringValue, agent.rawValue)
                XCTAssertEqual(setAgent.objectValue?["changed"]?.boolValue, true)
                XCTAssertEqual(setAgent.objectValue?["applied"]?.boolValue, true)
                XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderAgentRaw, agent.rawValue)
                XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderModelsByAgent?[agent.rawValue], seededModel)
                XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderModelsByAgent?[codexRaw], codexModel)

                if storedModel != seededModel {
                    // Custom compound Cursor IDs are writable even without catalog membership.
                    let setModel = try await service.handleForTesting([
                        "op": .string("set"),
                        "key": .string("context_builder.model"),
                        "value": .string(storedModel)
                    ])
                    XCTAssertEqual(setModel.objectValue?["old_value"]?.stringValue, seededModel)
                    XCTAssertEqual(setModel.objectValue?["new_value"]?.stringValue, storedModel)
                    XCTAssertEqual(setModel.objectValue?["changed"]?.boolValue, true)
                    XCTAssertEqual(setModel.objectValue?["applied"]?.boolValue, true)
                }

                let reloaded = GlobalSettingsStore(
                    defaults: defaults,
                    fileStore: GlobalSettingsFileStore(fileURL: fileURL)
                )
                for currentStore in [store, reloaded] {
                    let get = try await AppSettingsMCPService(store: currentStore).handleForTesting([
                        "op": .string("get"),
                        "keys": .array([.string("context_builder.agent"), .string("context_builder.model")])
                    ])
                    let values = try XCTUnwrap(get.objectValue?["values"]?.objectValue)
                    XCTAssertEqual(values["context_builder.agent"]?.stringValue, agent.rawValue)
                    XCTAssertEqual(values["context_builder.model"]?.stringValue, storedModel)
                    let profile = currentStore.globalAgentModelsProfile()
                    XCTAssertEqual(profile.contextBuilderAgentRaw, agent.rawValue)
                    XCTAssertEqual(profile.contextBuilderModelsByAgent?[agent.rawValue], storedModel)
                    XCTAssertEqual(profile.contextBuilderModelsByAgent?[codexRaw], codexModel)
                }
                previousAgentRaw = agent.rawValue
            }

            let cursorRaw = AgentProviderKind.cursor.rawValue
            let cursorModel = "cursor-custom[Cursor.Thought-Level=High,Cursor.Fast-Mode=true]"
            for (oldAgentRaw, agentRaw, expectedModel) in [
                (cursorRaw, codexRaw, codexModel),
                (codexRaw, cursorRaw, cursorModel)
            ] {
                let setAgent = try await service.handleForTesting([
                    "op": .string("set"),
                    "key": .string("context_builder.agent"),
                    "value": .string(agentRaw)
                ])
                XCTAssertEqual(setAgent.objectValue?["old_value"]?.stringValue, oldAgentRaw)
                XCTAssertEqual(setAgent.objectValue?["new_value"]?.stringValue, agentRaw)
                XCTAssertEqual(setAgent.objectValue?["changed"]?.boolValue, true)
                XCTAssertEqual(setAgent.objectValue?["applied"]?.boolValue, true)

                let reloaded = GlobalSettingsStore(
                    defaults: defaults,
                    fileStore: GlobalSettingsFileStore(fileURL: fileURL)
                )
                for currentStore in [store, reloaded] {
                    let get = try await AppSettingsMCPService(store: currentStore).handleForTesting([
                        "op": .string("get"),
                        "keys": .array([.string("context_builder.agent"), .string("context_builder.model")])
                    ])
                    let values = try XCTUnwrap(get.objectValue?["values"]?.objectValue)
                    XCTAssertEqual(values["context_builder.agent"]?.stringValue, agentRaw)
                    XCTAssertEqual(values["context_builder.model"]?.stringValue, expectedModel)
                    let profile = currentStore.globalAgentModelsProfile()
                    XCTAssertEqual(profile.contextBuilderAgentRaw, agentRaw)
                    XCTAssertEqual(profile.contextBuilderModelsByAgent?[codexRaw], codexModel)
                    XCTAssertEqual(profile.contextBuilderModelsByAgent?[cursorRaw], cursorModel)
                }
            }
        }
    }

    func testContextBuilderModelOnlyWritePersistsFallbackAgentOnFreshProfile() async throws {
        try await withContextBuilderSettings { store, service, _, _ in
            XCTAssertNil(store.globalAgentModelsProfile().contextBuilderAgentRaw)
            XCTAssertFalse(store.hasUserSetGlobalContextBuilderAgentDefaults)

            let set = try await service.handleForTesting([
                "op": .string("set"),
                "key": .string("context_builder.model"),
                "value": .string("sonnet")
            ])
            XCTAssertEqual(set.objectValue?["new_value"]?.stringValue, "sonnet")

            let profile = store.globalAgentModelsProfile()
            XCTAssertEqual(profile.contextBuilderAgentRaw, AgentProviderKind.claudeCode.rawValue)
            XCTAssertEqual(profile.contextBuilderModelsByAgent?[AgentProviderKind.claudeCode.rawValue], "sonnet")
            XCTAssertTrue(store.hasUserSetGlobalContextBuilderAgentDefaults)
        }
    }

    func testContextBuilderModelWriteRepairsInvalidStoredAgentWithoutLosingRememberedModels() async throws {
        try await withContextBuilderSettings { store, service, _, _ in
            let claudeRaw = AgentProviderKind.claudeCode.rawValue
            for (agentRaw, rememberedModel) in [
                ("unknown-context-builder-agent", "unknown-remembered-model"),
                (AgentProviderKind.antigravity.rawValue, "antigravity-remembered-model")
            ] {
                store.setGlobalAgentModelsProfile(
                    AgentModelsSettingsProfile(
                        contextBuilderAgentRaw: agentRaw,
                        contextBuilderModelsByAgent: [agentRaw: rememberedModel, claudeRaw: "haiku"]
                    ),
                    contextBuilderWriteIntent: .userInitiated
                )

                _ = try await service.handleForTesting([
                    "op": .string("set"),
                    "key": .string("context_builder.model"),
                    "value": .string("sonnet")
                ])

                let profile = store.globalAgentModelsProfile()
                XCTAssertEqual(profile.contextBuilderAgentRaw, claudeRaw, agentRaw)
                XCTAssertEqual(profile.contextBuilderModelsByAgent?[claudeRaw], "sonnet", agentRaw)
                XCTAssertEqual(profile.contextBuilderModelsByAgent?[agentRaw], rememberedModel, agentRaw)
            }
        }
    }

    func testContextBuilderModelReadsWritesAndClearsStoredAgentSlot() async throws {
        try await withContextBuilderSettings { store, service, _, _ in
            for (agent, originalModel, updatedModel): (AgentProviderKind, String, String) in [
                (.grokBuild, "grok-custom-a", "grok-custom-b"),
                (.cursor, "cursor-custom-a", "cursor-custom-b")
            ] {
                var expectedModels = [
                    AgentProviderKind.codexExec.rawValue: "gpt-6.1-sol-fast-high",
                    AgentProviderKind.grokBuild.rawValue: "other-grok-model",
                    AgentProviderKind.cursor.rawValue: "other-cursor-model"
                ]
                expectedModels[agent.rawValue] = originalModel
                store.setGlobalAgentModelsProfile(
                    AgentModelsSettingsProfile(
                        contextBuilderAgentRaw: agent.rawValue,
                        contextBuilderModelsByAgent: expectedModels
                    ),
                    contextBuilderWriteIntent: .userInitiated
                )

                let get = try await service.handleForTesting([
                    "op": .string("get"),
                    "keys": .array([.string("context_builder.agent"), .string("context_builder.model")])
                ])
                let values = try XCTUnwrap(get.objectValue?["values"]?.objectValue)
                XCTAssertEqual(values["context_builder.agent"]?.stringValue, agent.rawValue)
                XCTAssertEqual(values["context_builder.model"]?.stringValue, originalModel)

                let set = try await service.handleForTesting([
                    "op": .string("set"),
                    "key": .string("context_builder.model"),
                    "value": .string(updatedModel)
                ])
                XCTAssertEqual(set.objectValue?["old_value"]?.stringValue, originalModel)
                XCTAssertEqual(set.objectValue?["new_value"]?.stringValue, updatedModel)
                XCTAssertEqual(set.objectValue?["changed"]?.boolValue, true)
                XCTAssertEqual(set.objectValue?["applied"]?.boolValue, true)
                expectedModels[agent.rawValue] = updatedModel
                XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderAgentRaw, agent.rawValue)
                XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderModelsByAgent, expectedModels)

                let clear = try await service.handleForTesting([
                    "op": .string("set"),
                    "key": .string("context_builder.model"),
                    "value": .null
                ])
                XCTAssertEqual(clear.objectValue?["old_value"]?.stringValue, updatedModel)
                XCTAssertEqual(clear.objectValue?["new_value"], .null)
                XCTAssertEqual(clear.objectValue?["changed"]?.boolValue, true)
                XCTAssertEqual(clear.objectValue?["applied"]?.boolValue, true)
                expectedModels[agent.rawValue] = nil
                XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderAgentRaw, agent.rawValue)
                XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderModelsByAgent, expectedModels)

                let getCleared = try await service.handleForTesting([
                    "op": .string("get"),
                    "keys": .array([.string("context_builder.agent"), .string("context_builder.model")])
                ])
                let clearedValues = try XCTUnwrap(getCleared.objectValue?["values"]?.objectValue)
                XCTAssertEqual(clearedValues["context_builder.agent"]?.stringValue, agent.rawValue)
                XCTAssertEqual(clearedValues["context_builder.model"], .null)
            }
        }
    }

    func testContextBuilderGrokOptionsUseKnownModelsWithoutClaimingAvailability() async throws {
        let registry = AgentACPModelRegistry.shared
        registry.test_reset(providerID: .grokBuild)
        defer { registry.test_reset(providerID: .grokBuild) }

        try await withContextBuilderSettings { store, service, _, _ in
            store.setGlobalAgentModelsProfile(
                AgentModelsSettingsProfile(
                    contextBuilderAgentRaw: AgentProviderKind.grokBuild.rawValue,
                    contextBuilderModelsByAgent: [AgentProviderKind.grokBuild.rawValue: "default"]
                ),
                contextBuilderWriteIntent: .userInitiated
            )
            try await assertContextBuilderModelOptions(service: service, agent: .grokBuild, expectedModels: ["default"])

            _ = registry.updateDiscoveredModels(
                ACPDiscoveredSessionModels(
                    options: [AgentModelOption(
                        rawValue: "grok-settings-test-model",
                        displayName: "Grok Settings Test Model",
                        description: nil,
                        isDefault: false
                    )],
                    currentModelRaw: "grok-settings-test-model"
                ),
                for: .grokBuild
            )
            try await assertContextBuilderModelOptions(
                service: service,
                agent: .grokBuild,
                expectedModels: ["default", "grok-settings-test-model"]
            )
        }
    }

    func testContextBuilderCursorOptionsFollowDiscoveredCatalogWithoutClaimingAvailability() async throws {
        let registry = AgentACPModelRegistry.shared
        registry.test_reset(providerID: .cursor)
        defer { registry.test_reset(providerID: .cursor) }

        try await withContextBuilderSettings { store, service, _, _ in
            store.setGlobalAgentModelsProfile(
                AgentModelsSettingsProfile(
                    contextBuilderAgentRaw: AgentProviderKind.cursor.rawValue,
                    contextBuilderModelsByAgent: [AgentProviderKind.cursor.rawValue: "auto"]
                ),
                contextBuilderWriteIntent: .userInitiated
            )
            try await assertContextBuilderModelOptions(service: service, agent: .cursor, expectedModels: ["auto"])

            let discoveredModels = ["cursor-settings-model-a", "cursor-settings-model-b"]
            _ = registry.updateDiscoveredModels(
                ACPDiscoveredSessionModels(
                    options: discoveredModels.map {
                        AgentModelOption(rawValue: $0, displayName: $0, description: nil, isDefault: false)
                    },
                    currentModelRaw: discoveredModels[0]
                ),
                for: .cursor
            )
            // A discovered catalog need not contain "auto"; don't append historical models.
            try await assertContextBuilderModelOptions(
                service: service,
                agent: .cursor,
                expectedModels: Set(discoveredModels)
            )
        }
    }

    private func withContextBuilderSettings(
        _ body: (GlobalSettingsStore, AppSettingsMCPService, UserDefaults, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceContextBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AppSettingsMCPServiceContextBuilderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileURL = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        try await body(store, AppSettingsMCPService(store: store), defaults, fileURL)
    }

    private func assertContextBuilderModelOptions(
        service: AppSettingsMCPService,
        agent: AgentProviderKind,
        expectedModels: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for explicitAgent in [true, false] {
            var arguments: [String: Value] = [
                "op": .string("options"),
                "key": .string("context_builder.model")
            ]
            if explicitAgent {
                arguments["agent"] = .string(agent.rawValue)
            }
            let result = try await service.handleForTesting(arguments)
            XCTAssertEqual(result.objectValue?["filters"]?.objectValue?["agent"]?.stringValue, agent.rawValue, file: file, line: line)
            let options = try XCTUnwrap(result.objectValue?["options"]?.arrayValue, file: file, line: line)
            XCTAssertEqual(Set(options.compactMap { $0.objectValue?["value"]?.stringValue }), expectedModels, file: file, line: line)
            XCTAssertEqual(options.count, expectedModels.count, file: file, line: line)
            XCTAssertTrue(
                options.allSatisfy { $0.objectValue?["agent"]?.stringValue == agent.rawValue },
                "Every option must belong to \(agent.rawValue) (explicit filter: \(explicitAgent))",
                file: file,
                line: line
            )
            XCTAssertTrue(
                options.allSatisfy { $0.objectValue?["available"]?.boolValue == false },
                "Known models must not claim runtime availability (explicit filter: \(explicitAgent))",
                file: file,
                line: line
            )
        }
    }

    func testSubagentDefaultWaitSecondsListsReadsPersistsAndRejectsInvalidValues() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        let service = AppSettingsMCPService(store: store)
        let key = "agent_mode.subagent_default_wait_seconds"

        XCTAssertEqual(store.subagentDefaultWaitSeconds(), 120)

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("agent_mode"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let catalog = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
        XCTAssertEqual(catalog.objectValue?["type"]?.stringValue, "number")
        XCTAssertEqual(
            catalog.objectValue?["allowed_values"]?.arrayValue?.compactMap(\.stringValue),
            MCPTimeoutPolicy.supportedSubagentDefaultWaitSeconds.map(String.init)
        )
        XCTAssertEqual(catalog.objectValue?["value"]?.intValue, 120)

        for seconds in MCPTimeoutPolicy.supportedSubagentDefaultWaitSeconds {
            let set = try await service.handleForTesting([
                "op": .string("set"),
                "key": .string(key),
                "value": .int(seconds)
            ])
            XCTAssertEqual(set.objectValue?["status"]?.stringValue, "ok")
            XCTAssertEqual(set.objectValue?["new_value"]?.intValue, seconds)
            XCTAssertEqual(store.subagentDefaultWaitSeconds(), seconds)
        }

        let reloaded = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertEqual(reloaded.subagentDefaultWaitSeconds(), MCPTimeoutPolicy.supportedSubagentDefaultWaitSeconds.last)

        let invalidPersistedJSON = """
        {
          "schemaVersion": 7,
          "schemaLineage": "repoprompt-ce.global-settings",
          "updatedAt": "2026-01-01T00:00:00Z",
          "copySettingsByWorkspaceID": {},
          "chatSettingsByWorkspaceID": {},
          "globalDefaults": {},
          "scalarPreferences": {
            "agentMode": {
              "subagentDefaultWaitSeconds": 999
            }
          }
        }
        """
        try invalidPersistedJSON.data(using: .utf8)?.write(to: fileURL)
        let invalidReloaded = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertEqual(invalidReloaded.subagentDefaultWaitSeconds(), 120)

        let invalidService = AppSettingsMCPService(store: invalidReloaded)
        let previous = invalidReloaded.subagentDefaultWaitSeconds()
        // `1e20` and `-1e20` are finite and integral but outside `Int`; they must be rejected as
        // invalid parameters rather than trapping during conversion. `.double(300.0)` is the same
        // value a JSON round-trip can produce for a supported choice and must still be accepted.
        for invalidValue: Value in [
            .int(90),
            .double(300.5),
            .double(1e20),
            .double(-1e20),
            .double(.infinity),
            .double(.nan),
            .double(Double(Int.max)),
            .string("600"),
            .null
        ] {
            do {
                _ = try await invalidService.handleForTesting([
                    "op": .string("set"),
                    "key": .string(key),
                    "value": invalidValue
                ])
                XCTFail("Expected rejection for \(invalidValue)")
            } catch {
                // Expected atomic rejection.
            }
            XCTAssertEqual(invalidReloaded.subagentDefaultWaitSeconds(), previous)
        }

        XCTAssertFalse(invalidReloaded.setSubagentDefaultWaitSeconds(450))
        XCTAssertEqual(invalidReloaded.subagentDefaultWaitSeconds(), previous)

        _ = try await invalidService.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .double(300)
        ])
        XCTAssertEqual(invalidReloaded.subagentDefaultWaitSeconds(), 300)
    }
}
