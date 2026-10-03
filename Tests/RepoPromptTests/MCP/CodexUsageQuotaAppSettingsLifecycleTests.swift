import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

/// `app_settings` writes for the Codex quota flag must apply, not merely persist.
///
/// Without the `afterWrite` transition, disabling over MCP would update the document while an
/// already-visible pane kept observing, so the service would hold its app-server process open
/// until that pane happened to close.
@MainActor
final class CodexUsageQuotaAppSettingsLifecycleTests: XCTestCase {
    private let key = "agent_mode.codex_usage_quota_enabled"

    private func makeService() throws -> (AppSettingsMCPService, GlobalSettingsStore, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageQuotaAppSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "CodexUsageQuotaAppSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let cleanup = {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        return (AppSettingsMCPService(store: store), store, cleanup)
    }

    func testWriteAppliesTheRuntimeTransitionInBothDirections() async throws {
        let (service, store, cleanup) = try makeService()
        defer { cleanup() }

        let original = CodexUsageQuotaRuntimeBridge.applyEnabled
        defer { CodexUsageQuotaRuntimeBridge.applyEnabled = original }

        var transitions: [Bool] = []
        CodexUsageQuotaRuntimeBridge.applyEnabled = { transitions.append($0) }

        XCTAssertFalse(store.codexUsageQuotaEnabled(), "production default is off")

        _ = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])
        XCTAssertTrue(store.codexUsageQuotaEnabled(), "the flag persists")
        XCTAssertEqual(transitions, [true], "and is applied immediately")

        _ = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(false)
        ])
        XCTAssertFalse(store.codexUsageQuotaEnabled())
        XCTAssertEqual(
            transitions,
            [true, false],
            "disabling tears down without waiting for the pane to close"
        )
    }

    func testSettingIsReadableAndDefaultsOffInTheCatalog() async throws {
        let (service, _, cleanup) = try makeService()
        defer { cleanup() }

        let original = CodexUsageQuotaRuntimeBridge.applyEnabled
        defer { CodexUsageQuotaRuntimeBridge.applyEnabled = original }
        CodexUsageQuotaRuntimeBridge.applyEnabled = { _ in }

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("agent_mode"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let entry = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })

        XCTAssertEqual(entry.objectValue?["type"]?.stringValue, "boolean")
        XCTAssertEqual(entry.objectValue?["value"]?.boolValue, false, "observe-only feature ships off")

        // Quota values themselves must never be exposed over MCP; only the flag is.
        let description = try XCTUnwrap(entry.objectValue?["description"]?.stringValue)
        XCTAssertTrue(description.contains("observe-only"))
    }
}
