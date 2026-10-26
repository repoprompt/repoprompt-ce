import Foundation
@testable import RepoPromptSettingsCore
import XCTest

@MainActor
final class MCPConnectionApprovalSettingsTests: XCTestCase {
    func testStrictApprovalDefaultsOffAndPersistsBothChoicesWithoutChangingSiblingSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "MCPConnectionApprovalSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: url))
        XCTAssertFalse(store.mcpStrictConnectionApproval())
        store.setMCPAutoStart(true)
        for strict in [true, false] {
            store.setMCPStrictConnectionApproval(strict)
            let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: url))
            XCTAssertEqual(reloaded.mcpStrictConnectionApproval(), strict)
            XCTAssertTrue(reloaded.mcpAutoStart())
        }
    }

    func testSettingsFilesWithoutStrictKeyDecodeWithAlwaysAllowDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        for version in [GlobalSettingsDocument.baselineSchemaVersion, GlobalSettingsDocument.currentSchemaVersion] {
            let suite = "MCPConnectionApprovalSettingsTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let url = root.appendingPathComponent("globalSettings-v\(version).json")
            let old = GlobalSettingsDocument(
                schemaVersion: version,
                scalarPreferences: GlobalScalarPreferences(mcp: .init(autoStart: true))
            )
            let bytes = try encoder.encode(old)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let scalar = try XCTUnwrap(json["scalarPreferences"] as? [String: Any])
            let mcp = try XCTUnwrap(scalar["mcp"] as? [String: Any])
            XCTAssertNil(mcp["strictConnectionApproval"], "Fixture must model a pre-setting file")
            try bytes.write(to: url, options: .atomic)

            let fileStore = GlobalSettingsFileStore(fileURL: url)
            XCTAssertNil(try fileStore.load().scalarPreferences?.mcp?.strictConnectionApproval)
            let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
            XCTAssertFalse(store.mcpStrictConnectionApproval(), "v\(version)")
            XCTAssertTrue(store.mcpAutoStart(), "v\(version)")
        }
    }

    func testStrictSettingDoesNotRaiseRequiredSchemaVersion() {
        let base = GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(mcp: .init(autoStart: true)))
        let strict = GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(mcp: .init(autoStart: true, strictConnectionApproval: true))
        )
        XCTAssertEqual(strict.requiredSchemaVersion, base.requiredSchemaVersion)
    }
}
