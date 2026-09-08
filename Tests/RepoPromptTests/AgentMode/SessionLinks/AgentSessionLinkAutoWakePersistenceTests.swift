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
            autoWakeOnOversightUpdates: false,
            routineWakeIntervalEnabled: false,
            routineWakeIntervalSeconds: 600,
            periodicIdleWakeEnabled: false,
            periodicIdleWakeIntervalSeconds: 7200
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
        XCTAssertFalse(live.oversight.routineWakeIntervalEnabled)
        XCTAssertEqual(live.oversight.routineWakeIntervalSeconds, 300)
        XCTAssertFalse(live.oversight.periodicIdleWakeEnabled)
        XCTAssertEqual(live.oversight.periodicIdleWakeIntervalSeconds, 1800)

        viewModel.restoreAgentSessionLinkState(from: decodedOff, to: live)

        XCTAssertFalse(live.oversight.autoWakeOnUpdates, "the durable saved choice wins")
        XCTAssertFalse(live.oversight.routineWakeIntervalEnabled)
        XCTAssertEqual(live.oversight.routineWakeIntervalSeconds, 600, "disabling retains the selected interval")
        XCTAssertFalse(live.oversight.periodicIdleWakeEnabled)
        XCTAssertEqual(live.oversight.periodicIdleWakeIntervalSeconds, 7200, "disabling retains the periodic interval")
        XCTAssertTrue(live.oversight.autoWakeTargetSessionIDs.isEmpty)
        XCTAssertNil(live.oversight.pendingAutoWake, "restoration must not reserve a provider turn")

        let selectedTargetID = UUID()
        let savedOn = AgentSession(
            id: UUID(),
            name: "Observer",
            savedAt: Date(),
            autoWakeOnOversightUpdates: true,
            agentSessionLinkAutoWakeTargetSessionIDs: [selectedTargetID],
            routineWakeIntervalEnabled: true,
            routineWakeIntervalSeconds: 900,
            periodicIdleWakeEnabled: true,
            periodicIdleWakeIntervalSeconds: 3600
        )
        let decodedOn = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(savedOn))
        viewModel.restoreAgentSessionLinkState(from: decodedOn, to: live)

        XCTAssertTrue(live.oversight.autoWakeOnUpdates)
        XCTAssertTrue(live.oversight.routineWakeIntervalEnabled)
        XCTAssertEqual(live.oversight.routineWakeIntervalSeconds, 900)
        XCTAssertTrue(live.oversight.periodicIdleWakeEnabled)
        XCTAssertEqual(live.oversight.periodicIdleWakeIntervalSeconds, 3600)
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
        XCTAssertFalse(record.routineWakeIntervalEnabled)
        XCTAssertEqual(record.routineWakeIntervalSeconds, 300)
        XCTAssertEqual(record.sidebarEntry(tabID: UUID())?.routineWakeIntervalEnabled, false)
        XCTAssertEqual(record.sidebarEntry(tabID: UUID())?.routineWakeIntervalSeconds, 300)
        XCTAssertFalse(record.periodicIdleWakeEnabled)
        XCTAssertEqual(record.periodicIdleWakeIntervalSeconds, 1800)
        XCTAssertEqual(record.sidebarEntry(tabID: UUID())?.periodicIdleWakeEnabled, false)
        XCTAssertEqual(record.sidebarEntry(tabID: UUID())?.periodicIdleWakeIntervalSeconds, 1800)
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
        XCTAssertFalse(session.routineWakeIntervalEnabled)
        XCTAssertEqual(session.routineWakeIntervalSeconds, 300)
        XCTAssertFalse(session.periodicIdleWakeEnabled)
        XCTAssertEqual(session.periodicIdleWakeIntervalSeconds, 1800)
    }

    func testAutoWakeRoundTripsThroughSessionMetadataAndSidebar() throws {
        let selectedTargetID = UUID()
        var session = AgentSession(id: UUID(), name: "Observer", savedAt: Date())
        session.autoWakeOnOversightUpdates = true
        session.agentSessionLinkAutoWakeTargetSessionIDs = [selectedTargetID]
        session.routineWakeIntervalEnabled = true
        session.routineWakeIntervalSeconds = 10800
        session.periodicIdleWakeEnabled = true
        session.periodicIdleWakeIntervalSeconds = 21600

        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(session)
        )
        XCTAssertTrue(decoded.autoWakeOnOversightUpdates)
        XCTAssertTrue(decoded.routineWakeIntervalEnabled)
        XCTAssertEqual(decoded.routineWakeIntervalSeconds, 10800)
        XCTAssertTrue(decoded.periodicIdleWakeEnabled)
        XCTAssertEqual(decoded.periodicIdleWakeIntervalSeconds, 21600)
        XCTAssertEqual(decoded.agentSessionLinkAutoWakeTargetSessionIDs, [selectedTargetID])

        let record = AgentSessionMetadataRecord.record(
            from: decoded,
            fileURL: URL(fileURLWithPath: "/tmp/AgentSession-observer.json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
        XCTAssertTrue(record.autoWakeOnOversightUpdates)
        XCTAssertEqual(record.agentSessionLinkAutoWakeTargetSessionIDs, [selectedTargetID])

        let decodedRecord = try JSONDecoder().decode(AgentSessionMetadataRecord.self, from: JSONEncoder().encode(record))
        XCTAssertTrue(decodedRecord.routineWakeIntervalEnabled)
        XCTAssertEqual(decodedRecord.routineWakeIntervalSeconds, 10800)
        XCTAssertTrue(decodedRecord.periodicIdleWakeEnabled)
        XCTAssertEqual(decodedRecord.periodicIdleWakeIntervalSeconds, 21600)
        XCTAssertTrue(record.matchesIndexedSessionMetadata(decodedRecord))
        var changedInterval = decodedRecord
        changedInterval.routineWakeIntervalSeconds = 300
        XCTAssertFalse(record.matchesIndexedSessionMetadata(changedInterval))
        var changedEnabled = decodedRecord
        changedEnabled.routineWakeIntervalEnabled = false
        XCTAssertFalse(record.matchesIndexedSessionMetadata(changedEnabled))
        var changedPeriodicInterval = decodedRecord
        changedPeriodicInterval.periodicIdleWakeIntervalSeconds = 1800
        XCTAssertFalse(record.matchesIndexedSessionMetadata(changedPeriodicInterval))
        var changedPeriodicEnabled = decodedRecord
        changedPeriodicEnabled.periodicIdleWakeEnabled = false
        XCTAssertFalse(record.matchesIndexedSessionMetadata(changedPeriodicEnabled))

        let sidebar = try XCTUnwrap(decodedRecord.sidebarEntry(tabID: UUID()))
        XCTAssertTrue(sidebar.autoWakeOnOversightUpdates)
        XCTAssertTrue(sidebar.routineWakeIntervalEnabled)
        XCTAssertEqual(sidebar.routineWakeIntervalSeconds, 10800)
        XCTAssertTrue(sidebar.periodicIdleWakeEnabled)
        XCTAssertEqual(sidebar.periodicIdleWakeIntervalSeconds, 21600)
        let restoredSidebar = AgentSessionRestoreSupport.buildSidebarIndexEntry(
            from: decoded,
            tabID: sidebar.tabID,
            name: decoded.name
        )
        XCTAssertEqual(restoredSidebar.periodicIdleWakeEnabled, sidebar.periodicIdleWakeEnabled)
        XCTAssertEqual(restoredSidebar.periodicIdleWakeIntervalSeconds, sidebar.periodicIdleWakeIntervalSeconds)
        XCTAssertEqual(sidebar.agentSessionLinkAutoWakeTargetSessionIDs, [selectedTargetID])
    }

    func testRoutineIntervalDecodeNormalizesUnsupportedValuesWithoutEnablingIt() throws {
        var saved = AgentSession(id: UUID(), name: "Observer", savedAt: Date())
        saved.routineWakeIntervalSeconds = 700
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(saved))
        XCTAssertFalse(decoded.routineWakeIntervalEnabled)
        XCTAssertEqual(decoded.routineWakeIntervalSeconds, 900)

        var record = AgentSessionMetadataRecord.record(
            from: decoded,
            fileURL: URL(fileURLWithPath: "/tmp/AgentSession-observer.json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
        record.routineWakeIntervalSeconds = 0
        let decodedRecord = try JSONDecoder().decode(AgentSessionMetadataRecord.self, from: JSONEncoder().encode(record))
        XCTAssertFalse(decodedRecord.routineWakeIntervalEnabled)
        XCTAssertEqual(decodedRecord.routineWakeIntervalSeconds, 60)
    }

    func testPeriodicIntervalDecodeCeilsAndCapsWithoutEnablingIt() throws {
        for (stored, expected) in [
            (Int.min, 600), (600, 600), (601, 1800), (1800, 1800),
            (1801, 3600), (3600, 3600), (3601, 7200), (7200, 7200),
            (7201, 21600), (21600, 21600), (Int.max, 21600)
        ] {
            var saved = AgentSession(
                id: UUID(),
                name: "Observer",
                savedAt: Date(),
                periodicIdleWakeIntervalSeconds: stored
            )
            XCTAssertEqual(saved.periodicIdleWakeIntervalSeconds, expected, "constructor: \(stored)")
            // Bypass constructor normalization to model an unsupported value already on disk.
            saved.periodicIdleWakeIntervalSeconds = stored
            let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(saved))
            XCTAssertFalse(decoded.periodicIdleWakeEnabled)
            XCTAssertEqual(decoded.periodicIdleWakeIntervalSeconds, expected, "session decode: \(stored)")

            var record = AgentSessionMetadataRecord.record(
                from: saved,
                fileURL: URL(fileURLWithPath: "/tmp/AgentSession-observer.json"),
                observedFileSize: nil,
                observedFileModificationDate: nil
            )
            XCTAssertEqual(record.periodicIdleWakeIntervalSeconds, expected, "metadata construction: \(stored)")
            record.periodicIdleWakeIntervalSeconds = stored
            let decodedRecord = try JSONDecoder().decode(AgentSessionMetadataRecord.self, from: JSONEncoder().encode(record))
            XCTAssertFalse(decodedRecord.periodicIdleWakeEnabled)
            XCTAssertEqual(decodedRecord.periodicIdleWakeIntervalSeconds, expected, "metadata decode: \(stored)")
        }
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
            "agentKind": "codexExec",
            "routineWakeIntervalEnabled": true,
            "routineWakeIntervalSeconds": 600,
            "periodicIdleWakeEnabled": true,
            "periodicIdleWakeIntervalSeconds": 1900
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
        XCTAssertTrue(stub.routineWakeIntervalEnabled)
        XCTAssertEqual(stub.routineWakeIntervalSeconds, 600)
        XCTAssertTrue(stub.periodicIdleWakeEnabled)
        XCTAssertEqual(stub.periodicIdleWakeIntervalSeconds, 3600)
        XCTAssertEqual(stub.agentSessionLinkAutoWakeTargetSessionIDs, [selectedTargetID])

        // Header-only legacy files must also load with periodic wake disabled, not fail decoding.
        var legacyPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        legacyPayload.removeValue(forKey: "periodicIdleWakeEnabled")
        legacyPayload.removeValue(forKey: "periodicIdleWakeIntervalSeconds")
        let legacyURL = folder.appendingPathComponent("AgentSession-legacy.json")
        try JSONSerialization.data(withJSONObject: legacyPayload).write(to: legacyURL)
        let legacyStub = try await AgentSessionDataService.shared.loadAgentSessionStub(from: legacyURL)
        XCTAssertFalse(legacyStub.periodicIdleWakeEnabled)
        XCTAssertEqual(legacyStub.periodicIdleWakeIntervalSeconds, 1800)
    }
}
