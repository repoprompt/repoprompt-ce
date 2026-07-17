import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class AppSettingsMCPServiceAgentModeSettingsTests: XCTestCase {
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
}
