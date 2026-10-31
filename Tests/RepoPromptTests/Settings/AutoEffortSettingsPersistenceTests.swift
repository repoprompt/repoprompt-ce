import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

@MainActor
final class AutoEffortSettingsPersistenceTests: XCTestCase {
    func testLegacyEnabledSelectionResolvesToJevWithoutMaterializingField() throws {
        let fixture = try makeStore(agentMode: .init(autoEffortEnabled: true))
        let configuration = fixture.store.autoEffortConfiguration()
        XCTAssertTrue(configuration.enabled)
        XCTAssertNil(configuration.selectedBackendRawValue)
        XCTAssertEqual(configuration.selectedBackendID, .jev)
        XCTAssertEqual(fixture.store.routerDemandSnapshot().requiredBackendIDs, [.jev])

        fixture.store.setModelRouterCustomInstructions("Keep the legacy selection")
        let loaded = try fixture.file.load()
        XCTAssertNil(loaded.scalarPreferences?.agentMode?.autoEffortBackendRawValue)
        XCTAssertLessThan(loaded.schemaVersion, GlobalSettingsDocument.autoEffortServiceSchemaVersion)
    }

    func testExplicitSelectionRaisesSchemaAndSurvivesUnrelatedEdits() throws {
        let fixture = try makeStore(agentMode: .init(autoEffortEnabled: true))
        let before = fixture.store.autoEffortConfiguration().revision
        fixture.store.setAutoEffortBackend(.openAIDecisions)
        let selected = fixture.store.autoEffortConfiguration()
        XCTAssertEqual(selected.selectedBackendRawValue, "openai-decisions")
        XCTAssertEqual(selected.selectedBackendID, .openAIDecisions)
        XCTAssertGreaterThan(selected.revision, before)
        fixture.store.setModelRouterCustomInstructions("Unrelated edit")

        let loaded = try fixture.file.load()
        XCTAssertEqual(loaded.schemaVersion, GlobalSettingsDocument.autoEffortServiceSchemaVersion)
        XCTAssertEqual(loaded.scalarPreferences?.agentMode?.autoEffortBackendRawValue, "openai-decisions")
        XCTAssertEqual(
            GlobalSettingsFileStore.preservationBlockReason(
                schemaVersion: loaded.schemaVersion,
                schemaLineage: loaded.schemaLineage,
                supportedVersion: GlobalSettingsDocument.scopedModelRouterSchemaVersion
            ),
            .unsupportedFutureSchema(onDiskVersion: 12, supportedVersion: 10)
        )
    }

    func testBlankAndUnknownRawSelectionsRemainExactAndUnavailable() throws {
        for raw in ["", "  ", "future-service", " Future-Service "] {
            let fixture = try makeStore(agentMode: .init(autoEffortEnabled: true, autoEffortBackendRawValue: raw))
            let configuration = fixture.store.autoEffortConfiguration()
            XCTAssertEqual(configuration.selectedBackendRawValue, raw)
            XCTAssertEqual(
                configuration.selectedBackendID,
                raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : DecisionServiceID(rawValue: raw)
            )
            XCTAssertEqual(fixture.store.routerDemandSnapshot().autoEffortBackendRawValue, raw)
            fixture.store.setModelRouterCustomInstructions("Unrelated edit")
            XCTAssertEqual(try fixture.file.load().scalarPreferences?.agentMode?.autoEffortBackendRawValue, raw)
            XCTAssertFalse(fixture.store.routerDemandSnapshot().requiredBackendIDs.contains(.jev))
        }
    }

    func testAutoEffortRevisionChangesOnlyForActualIntentChanges() throws {
        let fixture = try makeStore(agentMode: .init(autoEffortEnabled: true))
        let initial = fixture.store.autoEffortConfiguration().revision
        fixture.store.setAutoEffortEnabled(true)
        XCTAssertEqual(fixture.store.autoEffortConfiguration().revision, initial)
        fixture.store.setModelRouterBackend(.openAIDecisions)
        XCTAssertEqual(fixture.store.autoEffortConfiguration().revision, initial)
        fixture.store.setAutoEffortBackend(.jev) // Explicitly install the legacy selection.
        XCTAssertEqual(fixture.store.autoEffortConfiguration().revision, initial + 1)
        fixture.store.setAutoEffortBackend(.jev)
        XCTAssertEqual(fixture.store.autoEffortConfiguration().revision, initial + 1)
        fixture.store.setAutoEffortEnabled(false)
        XCTAssertEqual(fixture.store.autoEffortConfiguration().revision, initial + 2)
    }

    private struct Fixture {
        let store: GlobalSettingsStore
        let file: GlobalSettingsFileStore
    }

    private func makeStore(agentMode: GlobalScalarPreferences.AgentModeSettings) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
        try file.save(GlobalSettingsDocument(scalarPreferences: .init(agentMode: agentMode)))
        let suite = "AutoEffortPersistence.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Fixture(store: GlobalSettingsStore(defaults: defaults, fileStore: file), file: file)
    }
}

// MARK: - Auto Workflow regressions

@MainActor
final class AutoWorkflowSettingsPersistenceTests: XCTestCase {
    func testDefaultOffAndToggleRoundTrip() throws {
        let (store, file) = try makeStore()
        XCTAssertFalse(store.autoWorkflowEnabled())
        let initial = store.autoWorkflowSettingsRevision
        store.setAutoWorkflowEnabled(true)
        XCTAssertTrue(try file.load().scalarPreferences?.agentMode?.autoWorkflowEnabled == true)
        XCTAssertEqual(store.autoWorkflowSettingsRevision, initial + 1)
        store.setAutoWorkflowEnabled(true)
        XCTAssertEqual(store.autoWorkflowSettingsRevision, initial + 1)
        store.setAutoWorkflowEnabled(false)
        XCTAssertNil(try file.load().scalarPreferences?.agentMode?.autoWorkflowEnabled)
        XCTAssertEqual(store.autoWorkflowSettingsRevision, initial + 2)
    }

    func testEnabledAndDisabledIntentSurviveFreshStoreInstances() throws {
        let (store, file) = try makeStore()
        store.setModelRouterBackend(.openAIDecisions)
        store.setModelRouterEnabled(false)
        store.setAutoWorkflowEnabled(true)
        let suite = "AutoWorkflowRelaunch.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let relaunched = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: file.fileURL))
        XCTAssertTrue(relaunched.autoWorkflowEnabled())
        XCTAssertTrue(relaunched.routingSettingsSnapshot().autoWorkflowEnabled)
        XCTAssertEqual(relaunched.autoWorkflowConfiguration().selectedBackendID, .openAIDecisions)
        XCTAssertEqual(relaunched.routerDemandSnapshot().requiredBackendIDs, [.openAIDecisions])
        relaunched.setAutoWorkflowEnabled(false)
        let relaunchedAgain = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: file.fileURL))
        XCTAssertFalse(relaunchedAgain.autoWorkflowEnabled())
        XCTAssertFalse(relaunchedAgain.routingSettingsSnapshot().autoWorkflowEnabled)
        XCTAssertTrue(relaunchedAgain.routerDemandSnapshot().requiredBackendIDs.isEmpty)
    }

    func testIndependentDemandAndSharedBackendRevision() throws {
        let (store, _) = try makeStore()
        store.setModelRouterBackend(.jev)
        store.setAutoWorkflowEnabled(true)
        XCTAssertFalse(store.modelRouterConfiguration().enabled)
        XCTAssertEqual(store.routerDemandSnapshot().requiredBackendIDs, [.jev])
        let revision = store.autoWorkflowSettingsRevision
        store.setModelRouterCustomInstructions("Unrelated guidance")
        store.setModelRouterEnabled(true)
        store.setAutoEffortEnabled(true)
        XCTAssertEqual(store.autoWorkflowSettingsRevision, revision)
        store.setModelRouterBackend(.openAIDecisions)
        XCTAssertEqual(store.autoWorkflowSettingsRevision, revision + 1)
        XCTAssertEqual(store.autoWorkflowConfiguration().selectedBackendID, .openAIDecisions)
        store.setAutoEffortEnabled(false)
        store.setModelRouterEnabled(false)
        XCTAssertEqual(store.routerDemandSnapshot().requiredBackendIDs, [.openAIDecisions])
        store.setAutoWorkflowEnabled(false)
        XCTAssertTrue(store.routerDemandSnapshot().requiredBackendIDs.isEmpty)
    }

    func testReloadChangesRevisionAndPreservesUnknownPreferences() throws {
        let (store, file) = try makeStore()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.fileURL)) as? [String: Any])
        json["scalarPreferences"] = ["agentMode": ["autoWorkflowEnabled": true, "futureWorkflowPreference": "keep"]]
        try JSONSerialization.data(withJSONObject: json).write(to: file.fileURL)
        let initial = store.autoWorkflowSettingsRevision
        XCTAssertTrue(store.reloadFromDisk())
        XCTAssertTrue(store.autoWorkflowEnabled())
        XCTAssertEqual(store.autoWorkflowSettingsRevision, initial + 1)
        XCTAssertTrue(store.reloadFromDisk())
        XCTAssertEqual(store.autoWorkflowSettingsRevision, initial + 1)
        store.setAutoWorkflowEnabled(false)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.fileURL)) as? [String: Any])
        let scalars = try XCTUnwrap(saved["scalarPreferences"] as? [String: Any])
        let agent = try XCTUnwrap(scalars["agentMode"] as? [String: Any])
        XCTAssertEqual(agent["futureWorkflowPreference"] as? String, "keep")
    }

    private func makeStore() throws -> (GlobalSettingsStore, GlobalSettingsFileStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
        try file.save(GlobalSettingsDocument())
        let suite = "AutoWorkflowPersistence.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (GlobalSettingsStore(defaults: defaults, fileStore: file), file)
    }
}
