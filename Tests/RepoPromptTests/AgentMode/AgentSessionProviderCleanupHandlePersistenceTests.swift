import Foundation
import RepoPromptAIContracts
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

final class AgentSessionProviderCleanupHandlePersistenceTests: XCTestCase {
    func testAgentSessionRoundTripsProviderCleanupHandleAsCurrentVersion() throws {
        let handle = ProviderConversationCleanupHandle(
            provider: AgentProviderKind.openCode.rawValue,
            sessionID: "open-code-session"
        )
        let session = try AgentSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000701")),
            name: "Cleanup Handle Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 70),
            agentKind: AgentProviderKind.openCode.rawValue,
            providerCleanupHandle: handle,
            autoEditEnabled: true
        )

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        XCTAssertEqual(decoded.serializationVersion, AgentSession.currentSerializationVersion)
        XCTAssertEqual(decoded.serializationVersion, 9)
        XCTAssertEqual(decoded.providerCleanupHandle, handle)
        XCTAssertEqual(decoded.resolvedProviderCleanupHandle, handle)
    }

    func testLegacyCodexFieldsBackfillProviderCleanupHandle() throws {
        let payload = """
        {
          "id": "00000000-0000-0000-0000-000000000702",
          "serializationVersion": 6,
          "name": "Legacy Codex Session",
          "savedAt": 0,
          "items": [],
          "agentKind": "codexExec",
          "autoEditEnabled": true,
          "codexConversationID": "thread-legacy",
          "codexRolloutPath": "/tmp/legacy-rollout.jsonl"
        }
        """

        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(payload.utf8))

        XCTAssertNil(decoded.providerCleanupHandle)
        XCTAssertEqual(
            decoded.resolvedProviderCleanupHandle,
            ProviderConversationCleanupHandle(
                provider: AgentProviderKind.codexExec.rawValue,
                conversationID: "thread-legacy",
                rolloutPath: "/tmp/legacy-rollout.jsonl"
            )
        )
    }

    func testProviderSessionIDBackfillsGenericProviderCleanupHandle() throws {
        let payload = """
        {
          "id": "00000000-0000-0000-0000-000000000703",
          "serializationVersion": 6,
          "name": "Legacy Claude Session",
          "savedAt": 0,
          "items": [],
          "agentKind": "claudeCode",
          "autoEditEnabled": true,
          "providerSessionID": "claude-session-legacy"
        }
        """

        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(payload.utf8))

        XCTAssertNil(decoded.providerCleanupHandle)
        XCTAssertEqual(
            decoded.resolvedProviderCleanupHandle,
            ProviderConversationCleanupHandle(
                provider: AgentProviderKind.claudeCode.rawValue,
                sessionID: "claude-session-legacy"
            )
        )
    }

    func testMissingProviderIdentifiersResolveNoCleanupHandle() {
        let session = AgentSession(
            agentKind: AgentProviderKind.openCode.rawValue,
            autoEditEnabled: true
        )

        XCTAssertNil(session.resolvedProviderCleanupHandle)
    }
}

@MainActor
extension AgentSessionProviderCleanupHandlePersistenceTests {
    func testLegacyDoesNotEmitAnAccountEnvelopeAndRetainsCleanup() throws {
        let session = AgentSession(
            id: UUID(),
            name: "Legacy",
            agentKind: AgentProviderKind.codexExec.rawValue,
            codexConversationID: UUID().uuidString
        )
        let data = try JSONEncoder().encode(session)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(document.keys.contains("subscriptionAccountBinding"))
        let restored = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertEqual(restored.subscriptionAccountBinding, .legacy)
        XCTAssertNotNil(restored.resolvedProviderCleanupHandle)
    }

    func testPinnedAndDetachedRoundTripAndBlockProviderOperations() throws {
        let profileID = SubscriptionProfileID(backend: .codex, uuid: UUID())
        for binding in [
            AgentSessionSubscriptionBinding.pinned(profileID: profileID, identityEpoch: UUID()), .detached
        ] {
            let session = AgentSession(
                id: UUID(),
                name: "Managed",
                agentKind: AgentProviderKind.codexExec.rawValue,
                subscriptionAccountBinding: binding,
                codexConversationID: UUID().uuidString
            )
            let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
            XCTAssertEqual(restored.subscriptionAccountBinding, binding)
            XCTAssertNil(restored.resolvedProviderCleanupHandle)

            let tab = AgentTabSession(tabID: UUID())
            AgentSessionHydrationRuntime.restoreCodexMetadata(from: restored, to: tab)
            XCTAssertEqual(tab.operationAdmissionFailureMessage, AgentSessionSubscriptionBinding.notRunnableMessage)
            XCTAssertNil(tab.providerCleanupHandle)
        }
    }

    func testQueuedLegacyReplacementCannotEraseManagedDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = AgentSession(name: "Previously legacy")
        let url = folder.appendingPathComponent("AgentSession-\(session.id.uuidString).json")
        let writer = AgentSessionDiskWriter()
        let legacy = try JSONEncoder().encode(session)
        _ = try await writer.enqueueAndWait(data: legacy, url: url, protectsSubscriptionBinding: true)

        let fence = TestReleaseFence(name: "legacy account-binding guard")
        await writer.test_setBeforeWriteHook { _ in await fence.enterAndWait() }
        let queued = Task { try await writer.enqueueAndWait(data: legacy, url: url, protectsSubscriptionBinding: true) }
        addTeardownBlock {
            fence.release()
            _ = await queued.result
            await writer.test_setBeforeWriteHook(nil)
        }
        guard await fence.waitUntilEntered() else { return }

        var managed = session
        managed.subscriptionAccountBinding = .pinned(profileID: .init(backend: .codex, uuid: UUID()), identityEpoch: UUID())
        let managedBytes = try JSONEncoder().encode(managed)
        try managedBytes.write(to: url, options: .atomic)
        fence.release()

        guard case .failure(AgentSessionDiskWriter.ProtectedDestinationError.subscriptionAccountBinding) = await queued.result else {
            return XCTFail("A queued legacy save must not erase a managed account binding")
        }
        XCTAssertEqual(try Data(contentsOf: url), managedBytes)
    }

    func testUnsupportedManagedRecordsStayReadableAndBytePreserved() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = AgentSessionDataService()
        for envelope in [
            NSNull() as Any,
            ["version": 99, "kind": "detached"],
            ["version": 1, "kind": "pinned"],
            "unexpected"
        ] {
            let id = UUID()
            let session = AgentSession(id: id, name: "Readable")
            let encoded = try JSONEncoder().encode(session)
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            document["subscriptionAccountBinding"] = envelope
            document["serializationVersion"] = 0
            let bytes = try JSONSerialization.data(withJSONObject: document)
            let url = folder.appendingPathComponent("AgentSession-\(id.uuidString).json")
            try bytes.write(to: url)

            let stub = try await service.loadAgentSessionStub(from: url, recoverMissingMetadata: true, persistRecoveredMetadata: true)
            let restored = try await service.loadAgentSession(from: url)
            XCTAssertEqual(stub.subscriptionAccountBinding, .unreadable)
            XCTAssertEqual(restored.subscriptionAccountBinding, .unreadable)
            XCTAssertEqual(restored.name, "Readable")
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertThrowsError(try JSONEncoder().encode(restored))
        }
    }
}
