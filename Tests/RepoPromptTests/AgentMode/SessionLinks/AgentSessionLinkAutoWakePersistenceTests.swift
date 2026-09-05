import Foundation
@testable import RepoPromptApp
import XCTest

/// Auto-wake is live-session configuration: fresh sessions may default on, but every restoration
/// path must preserve the durable choice and legacy payloads must never opt a user in implicitly.
final class AgentSessionLinkAutoWakePersistenceTests: XCTestCase {
    @MainActor
    func testDurableRestorationOverridesFreshDefaultWithoutArmingWake() throws {
        let savedOff = AgentSession(
            id: UUID(),
            name: "Observer",
            savedAt: Date(),
            autoWakeOnOversightUpdates: false
        )
        let decodedOff = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(savedOff))
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let live = viewModel.session(for: UUID())
        XCTAssertTrue(live.oversight.autoWakeOnUpdates, "fresh sessions default on")

        viewModel.restoreAgentSessionLinkState(from: decodedOff, to: live)

        XCTAssertFalse(live.oversight.autoWakeOnUpdates, "the durable saved choice wins")
        XCTAssertTrue(live.oversight.autoWakeTargetSessionIDs.isEmpty)
        XCTAssertNil(live.oversight.pendingAutoWake, "restoration must not reserve a provider turn")

        let selectedTargetID = UUID()
        let savedOn = AgentSession(
            id: UUID(),
            name: "Observer",
            savedAt: Date(),
            autoWakeOnOversightUpdates: true,
            agentSessionLinkAutoWakeTargetSessionIDs: [selectedTargetID]
        )
        let decodedOn = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(savedOn))
        viewModel.restoreAgentSessionLinkState(from: decodedOn, to: live)

        XCTAssertTrue(live.oversight.autoWakeOnUpdates)
        XCTAssertEqual(live.oversight.autoWakeTargetSessionIDs, [selectedTargetID])
        XCTAssertNil(live.oversight.pendingAutoWake, "restoration must not reserve a provider turn")
    }

    func testLegacyPayloadsDecodeAutoWakeFailClosed() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recordJSON = """
        {
            "id": "\(UUID().uuidString.lowercased())",
            "filename": "AgentSession-legacy.json",
            "name": "Legacy Observer",
            "savedAt": \(now.timeIntervalSince1970),
            "itemCount": 5,
            "hasUnknownConversationContent": false,
            "autoEditEnabled": true,
            "lastIndexedAt": \(now.timeIntervalSince1970)
        }
        """
        let record = try JSONDecoder().decode(
            AgentSessionMetadataRecord.self,
            from: XCTUnwrap(recordJSON.data(using: .utf8))
        )
        XCTAssertFalse(record.autoWakeOnOversightUpdates)
        XCTAssertTrue(record.agentSessionLinkAutoWakeTargetSessionIDs.isEmpty)
        XCTAssertEqual(record.sidebarEntry(tabID: UUID())?.autoWakeOnOversightUpdates, false)

        let sessionJSON = """
        {
            "id": "\(UUID().uuidString.lowercased())",
            "serializationVersion": 8,
            "name": "Legacy Observer",
            "savedAt": 0,
            "items": [],
            "autoEditEnabled": true,
            "autoWakeOnOversightUpdates": true
        }
        """
        let session = try JSONDecoder().decode(
            AgentSession.self,
            from: XCTUnwrap(sessionJSON.data(using: .utf8))
        )
        XCTAssertTrue(session.autoWakeOnOversightUpdates)
        XCTAssertTrue(session.agentSessionLinkAutoWakeTargetSessionIDs.isEmpty)
    }

    func testAutoWakeRoundTripsThroughSessionMetadataAndSidebar() throws {
        let selectedTargetID = UUID()
        var session = AgentSession(id: UUID(), name: "Observer", savedAt: Date())
        session.autoWakeOnOversightUpdates = true
        session.agentSessionLinkAutoWakeTargetSessionIDs = [selectedTargetID]

        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(session)
        )
        XCTAssertTrue(decoded.autoWakeOnOversightUpdates)
        XCTAssertEqual(decoded.agentSessionLinkAutoWakeTargetSessionIDs, [selectedTargetID])

        let record = AgentSessionMetadataRecord.record(
            from: decoded,
            fileURL: URL(fileURLWithPath: "/tmp/AgentSession-observer.json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
        XCTAssertTrue(record.autoWakeOnOversightUpdates)
        XCTAssertEqual(record.agentSessionLinkAutoWakeTargetSessionIDs, [selectedTargetID])

        let sidebar = try XCTUnwrap(record.sidebarEntry(tabID: UUID()))
        XCTAssertTrue(sidebar.autoWakeOnOversightUpdates)
        XCTAssertEqual(sidebar.agentSessionLinkAutoWakeTargetSessionIDs, [selectedTargetID])
    }

    func testHeaderOnlyColdLoadPreservesCurrentAutoWakeSettings() async throws {
        let sessionID = UUID()
        let selectedTargetID = UUID()
        let payload = """
        {
            "id": "\(sessionID.uuidString.lowercased())",
            "serializationVersion": 9,
            "name": "Cold Observer",
            "savedAt": 0,
            "itemCount": 4,
            "autoEditEnabled": true,
            "autoWakeOnOversightUpdates": true,
            "agentSessionLinkAutoWakeTargetSessionIDs": ["\(selectedTargetID.uuidString.lowercased())"],
            "agentKind": "codexExec"
        }
        """
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionLinkAutoWakePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fileURL = folder.appendingPathComponent("AgentSession-cold.json")
        try XCTUnwrap(payload.data(using: .utf8)).write(to: fileURL)

        let stub = try await AgentSessionDataService.shared.loadAgentSessionStub(from: fileURL)

        XCTAssertEqual(stub.id, sessionID)
        XCTAssertEqual(stub.name, "Cold Observer")
        XCTAssertEqual(stub.itemCount, 4)
        XCTAssertEqual(stub.agentKind, "codexExec")
        XCTAssertTrue(stub.autoWakeOnOversightUpdates)
        XCTAssertEqual(stub.agentSessionLinkAutoWakeTargetSessionIDs, [selectedTargetID])
    }
}
