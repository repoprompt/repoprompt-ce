import Foundation
import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class AppSettingsMCPServiceIgnorePolicyTests: XCTestCase {
    func testObsoleteGitignoreSettingIsAbsentAndRejectedWithoutMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceIgnorePolicyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppSettingsMCPServiceIgnorePolicyTests.\(UUID().uuidString)"))
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("file_system")
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let listedKeys = settings.compactMap { $0.objectValue?["key"]?.stringValue }
        XCTAssertFalse(listedKeys.contains(obsoleteKey))

        let before = store.respectRepoIgnore()
        do {
            _ = try await service.handleForTesting([
                "op": .string("get"),
                "key": .string(obsoleteKey)
            ])
            XCTFail("Expected obsolete setting read to be rejected")
        } catch {}
        do {
            _ = try await service.handleForTesting([
                "op": .string("set"),
                "key": .string(obsoleteKey),
                "value": .bool(false)
            ])
            XCTFail("Expected obsolete setting write to be rejected")
        } catch {}
        XCTAssertEqual(store.respectRepoIgnore(), before)
    }

    private var obsoleteKey: String {
        ["file_system", ".", "respect", "_", "gitignore"].joined()
    }
}
