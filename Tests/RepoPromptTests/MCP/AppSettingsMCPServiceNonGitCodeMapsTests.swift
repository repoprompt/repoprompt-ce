import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class AppSettingsMCPServiceNonGitCodeMapsTests: XCTestCase {
    func testLegacySettingsRemainDisabledUntilPersistedOptIn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NonGitCodeMapsSettings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "NonGitCodeMapsSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        try fileStore.save(GlobalSettingsDocument())
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertFalse(store.nonGitCodeMapsEnabled)

        let service = AppSettingsMCPService(store: store)
        let key = "code_maps.non_git_enabled"
        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("code_maps")
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        XCTAssertTrue(settings.contains { $0.objectValue?["key"]?.stringValue == key })

        let set = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])
        XCTAssertEqual(set.objectValue?["new_value"]?.boolValue, true)
        XCTAssertTrue(store.nonGitCodeMapsEnabled)
        let reloaded = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileStore.fileURL)
        )
        XCTAssertTrue(reloaded.nonGitCodeMapsEnabled)
    }
}
