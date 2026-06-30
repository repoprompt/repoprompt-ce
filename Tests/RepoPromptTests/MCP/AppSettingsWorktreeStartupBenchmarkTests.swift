import Foundation
import MCP
@testable import RepoPrompt
import XCTest

#if DEBUG
    @MainActor
    final class AppSettingsWorktreeStartupBenchmarkTests: XCTestCase {
        func testDebugBenchmarkGateCatalogAndSetSerialization() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AppSettingsWorktreeStartupBenchmarkTests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let suiteName = "AppSettingsWorktreeStartupBenchmarkTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = GlobalSettingsStore(
                defaults: defaults,
                fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
            )
            let service = AppSettingsMCPService(store: store)
            let key = "agent_mode.worktree_startup_benchmark_diagnostics_enabled"

            let listed = try await service.handleForTesting([
                "op": .string("list"),
                "group": .string("agent_mode"),
                "detailed": .bool(true)
            ])
            let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
            let catalog = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
            XCTAssertEqual(catalog.objectValue?["type"]?.stringValue, "boolean")
            XCTAssertEqual(catalog.objectValue?["value"]?.boolValue, false)

            let set = try await service.handleForTesting([
                "op": .string("set"),
                "key": .string(key),
                "value": .bool(true)
            ])
            XCTAssertEqual(set.objectValue?["status"]?.stringValue, "ok")
            XCTAssertEqual(set.objectValue?["old_value"]?.boolValue, false)
            XCTAssertEqual(set.objectValue?["new_value"]?.boolValue, true)
            XCTAssertEqual(set.objectValue?["changed"]?.boolValue, true)
            XCTAssertTrue(store.worktreeStartupBenchmarkDiagnosticsEnabled())
            XCTAssertTrue(WorktreeStartupBenchmarkGate.shared.snapshot().enabled)

            _ = try await service.handleForTesting([
                "op": .string("set"),
                "key": .string(key),
                "value": .bool(false)
            ])
            XCTAssertFalse(WorktreeStartupBenchmarkGate.shared.snapshot().enabled)
        }
    }
#endif
