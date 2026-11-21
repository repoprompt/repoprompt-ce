import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

@MainActor
final class AppSettingsMCPServiceIgnorePolicyTests: XCTestCase {
    func testGitignoreSettingIsListedAndPersistsBothValues() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceIgnorePolicyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppSettingsMCPServiceIgnorePolicyTests.\(UUID().uuidString)"))
        let fileURL = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        let service = AppSettingsMCPService(store: store)

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("file_system")
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let key = "file_system.respect_gitignore"
        let entry = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
        XCTAssertEqual(entry.objectValue?["writable"]?.boolValue, false)
        XCTAssertTrue(store.respectGitignore())
        do {
            _ = try await service.handleForTesting([
                "op": .string("set"), "key": .string(key), "value": .bool(false)
            ])
            XCTFail("Agents must not be able to opt themselves out of .gitignore rules")
        } catch {
            XCTAssertTrue(store.respectGitignore())
        }
        for enabled in [false, true] {
            store.setRespectGitignore(enabled)
            let result = try await service.handleForTesting(["op": .string("get"), "key": .string(key)])
            XCTAssertEqual(result.objectValue?["values"]?.objectValue?[key]?.boolValue, enabled)
            let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
            XCTAssertEqual(reloaded.respectGitignore(), enabled)
        }
    }
}
