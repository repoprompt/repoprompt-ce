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
