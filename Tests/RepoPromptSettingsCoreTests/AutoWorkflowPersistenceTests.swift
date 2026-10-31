import Foundation
import RepoPromptSettingsCore
import XCTest

@MainActor
final class AutoWorkflowPersistenceTests: XCTestCase {
    func testDurableIntentSurvivesNewStoreConstructionInBothDirections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        try file.save(GlobalSettingsDocument())
        let suite = "AutoWorkflowCoreRelaunch.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let original = GlobalSettingsStore(defaults: defaults, fileStore: file)
        XCTAssertFalse(original.autoWorkflowEnabled())
        original.updateModelRouterScalar(commit: true) { $0.selectedBackendRawValue = "openai-decisions" }
        original.setAutoWorkflowEnabled(true)
        // Saving is synchronous: a process ending immediately after the setter leaves
        // both the intent and its shared service selection on disk.
        XCTAssertEqual(try file.load().scalarPreferences?.agentMode?.autoWorkflowEnabled, true)
        let afterRelaunch = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: file.fileURL))
        XCTAssertTrue(afterRelaunch.autoWorkflowEnabled())
        XCTAssertTrue(afterRelaunch.routingSettingsSnapshot().autoWorkflowEnabled)
        XCTAssertEqual(afterRelaunch.routingSettingsSnapshot().selectedBackendRawValue, "openai-decisions")
        afterRelaunch.setAutoWorkflowEnabled(false)
        XCTAssertNil(try file.load().scalarPreferences?.agentMode?.autoWorkflowEnabled)
        let afterSecondRelaunch = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: file.fileURL))
        XCTAssertFalse(afterSecondRelaunch.autoWorkflowEnabled())
        XCTAssertFalse(afterSecondRelaunch.routingSettingsSnapshot().autoWorkflowEnabled)
    }
}
