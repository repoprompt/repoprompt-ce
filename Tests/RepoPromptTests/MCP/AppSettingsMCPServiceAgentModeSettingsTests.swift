import Foundation
import MCP
@testable import RepoPrompt
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
}
