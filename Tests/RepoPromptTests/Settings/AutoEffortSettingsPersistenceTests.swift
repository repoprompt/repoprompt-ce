import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AutoEffortSettingsPersistenceTests: XCTestCase {
    func testIndependentSettingStaysInBaselineSchemaAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        let suite = "AutoEffortSettingsPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        XCTAssertFalse(store.autoEffortEnabled())
        XCTAssertFalse(store.modelRouterConfiguration().enabled)
        store.setAutoEffortEnabled(false)
        let originalSchemaVersion = try fileStore.load().schemaVersion
        store.setAutoEffortEnabled(true)
        XCTAssertTrue(store.autoEffortEnabled())
        XCTAssertFalse(store.modelRouterConfiguration().enabled)
        let enabled = try fileStore.load()
        XCTAssertEqual(enabled.schemaVersion, originalSchemaVersion)
        XCTAssertEqual(enabled.scalarPreferences?.agentMode?.autoEffortEnabled, true)
        XCTAssertEqual(
            GlobalSettingsDocument(scalarPreferences: .init(
                agentMode: .init(autoEffortEnabled: true)
            )).requiredSchemaVersion,
            GlobalSettingsDocument.baselineSchemaVersion
        )

        let reloaded = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "\(suite).reload")),
            fileStore: fileStore
        )
        XCTAssertTrue(reloaded.autoEffortEnabled())
        reloaded.setAutoEffortEnabled(false)
        XCTAssertFalse(reloaded.autoEffortEnabled())
        let disabled = try fileStore.load()
        XCTAssertEqual(disabled.schemaVersion, originalSchemaVersion)
        XCTAssertNil(disabled.scalarPreferences?.agentMode?.autoEffortEnabled)
    }
}
