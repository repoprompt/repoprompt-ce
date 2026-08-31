import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class AppSettingsMCPServiceContextBuilderBudgetTests: XCTestCase {
    func testContextBuilderBudgetsListPersistAndValidateLikeSettingsUI() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceContextBuilderBudgetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AppSettingsMCPServiceContextBuilderBudgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("context_builder"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let byKey = Dictionary(uniqueKeysWithValues: settings.compactMap { value -> (String, Value)? in
            guard let key = value.objectValue?["key"]?.stringValue else { return nil }
            return (key, value)
        })
        XCTAssertEqual(byKey["context_builder.context_token_budget"]?.objectValue?["type"]?.stringValue, "integer")
        XCTAssertEqual(byKey["context_builder.analysis_token_budget"]?.objectValue?["type"]?.stringValue, "integer")

        _ = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string("context_builder.context_token_budget"),
            "value": .int(100_000)
        ])
        _ = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string("context_builder.analysis_token_budget"),
            "value": .int(150_000)
        ])
        let behavior = store.contextBuilderBehaviorSettings()
        XCTAssertEqual(behavior.contextTokenBudget, 100_000)
        XCTAssertEqual(behavior.analysisTokenBudget, 150_000)

        do {
            _ = try await service.handleForTesting([
                "op": .string("set"),
                "key": .string("context_builder.context_token_budget"),
                "value": .int(100_001)
            ])
            XCTFail("Expected non-step-aligned budget rejection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("increments of 5000"))
        }
    }
}
