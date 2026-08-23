import Foundation
@testable import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class HistoryIdlePersistTests: XCTestCase {
    func testMissingIdleThresholdMatchesDesktopDefaultAndClampsPersistRange() throws {
        XCTAssertEqual(
            AdvancedServerSettings.default.historyIdleThresholdMinutes,
            AdvancedServerSettings.HistoryIdleThreshold.defaultMinutes
        )
        XCTAssertEqual(AdvancedServerSettings.HistoryIdleThreshold.defaultMinutes, 10)

        let missing = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{}"#.utf8)
        )
        XCTAssertEqual(missing.historyIdleThresholdMinutes, 10)

        let high = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":2000}"#.utf8)
        )
        XCTAssertEqual(high.historyIdleThresholdMinutes, 1440)

        let low = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":-4}"#.utf8)
        )
        XCTAssertEqual(low.historyIdleThresholdMinutes, 0)
        XCTAssertEqual(AdvancedServerSettings(historyIdleThresholdMinutes: 70).historyIdleThresholdMinutes, 70)
    }

    func testLongGapsAddZeroInsteadOfClampingToTheThreshold() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let timestamps = [
            start,
            start.addingTimeInterval(30),
            start.addingTimeInterval(30 + 20 * 60),
        ]
        XCTAssertEqual(
            AdvancedServerSettings.HistoryIdleThreshold.activeDurationSeconds(
                timestamps: timestamps,
                thresholdMinutes: 1
            ),
            30
        )
        XCTAssertEqual(
            AdvancedServerSettings.HistoryIdleThreshold.activeDurationSeconds(
                timestamps: timestamps,
                thresholdMinutes: 30
            ),
            30 + 20 * 60
        )
        XCTAssertEqual(
            AdvancedServerSettings.HistoryIdleThreshold.activeDurationSeconds(
                timestamps: timestamps,
                thresholdMinutes: 0
            ),
            0
        )
    }

    func testPersistAllowsDesktopRangeAndExplicitMCPOverrideFailsClosed() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyHistoryIdleCatalog(),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let attribution = SettingsMutationAttribution(actorID: "idle", actorLabel: "Idle", channel: "test")

        let initialDefault = try await authority.historyIdleThresholdMinutes(explicit: nil)
        XCTAssertEqual(initialDefault, 10)

        let written = try await service.replaceAdvanced(
            .init(expectedRevision: 0, settings: .init(historyIdleThresholdMinutes: 70)),
            attribution: attribution
        )
        XCTAssertEqual(written.settings.historyIdleThresholdMinutes, 70)
        let stored = try await authority.historyIdleThresholdMinutes(explicit: nil)
        let explicitTwo = try await authority.historyIdleThresholdMinutes(explicit: 2)
        let explicitMax = try await authority.historyIdleThresholdMinutes(explicit: 1440)
        XCTAssertEqual(stored, 70)
        XCTAssertEqual(explicitTwo, 2)
        XCTAssertEqual(explicitMax, 1440)

        do {
            _ = try await authority.historyIdleThresholdMinutes(explicit: 1441)
            XCTFail("explicit override above 1440 should fail closed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, AdvancedServerSettings.HistoryIdleThreshold.rangeMessage)
        }
    }

    func testHistoryListSessionsAndTimeHonorIdleThreshold() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "idle".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "idle", username: "idle", displayName: "Idle")
        let project = try await authority.createProject(
            input: .init(name: "Idle", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "idle-project",
            requestDigest: "idle-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "idle-session",
            requestDigest: "idle-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)

        let omittedData = try await adapter.invoke(
            toolName: "history",
            argumentsJSON: json(["op": "time"]),
            binding: binding
        )
        let omitted = try JSONSerialization.jsonObject(with: omittedData) as? [String: Any]
        XCTAssertEqual(omitted?["idle_threshold_minutes"] as? Int, 10)

        let listedData = try await adapter.invoke(
            toolName: "history",
            argumentsJSON: json(["op": "list_sessions"]),
            binding: binding
        )
        let listed = try JSONSerialization.jsonObject(with: listedData) as? [[String: Any]]
        XCTAssertEqual(listed?.first?["active_duration_seconds"] as? Int, 0)
        XCTAssertEqual(listed?.first?["sessionId"] as? String, session.sessionID.uuidString)

        do {
            _ = try await adapter.invoke(
                toolName: "history",
                argumentsJSON: json(["op": "time", "idle_threshold_minutes": 2000]),
                binding: binding
            )
            XCTFail("out-of-range explicit idle threshold should fail closed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, AdvancedServerSettings.HistoryIdleThreshold.rangeMessage)
        }

        do {
            _ = try await adapter.invoke(
                toolName: "history",
                argumentsJSON: json(["op": "list_sessions", "idle_threshold_minutes": 10.5]),
                binding: binding
            )
            XCTFail("non-integer idle threshold should fail closed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, AdvancedServerSettings.HistoryIdleThreshold.integerRequiredMessage)
        }
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private struct EmptyHistoryIdleCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
