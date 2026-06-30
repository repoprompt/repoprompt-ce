@testable import RepoPrompt
import XCTest

final class AgentSessionProviderCleanupHandlePersistenceTests: XCTestCase {
    func testAgentSessionRoundTripsProviderCleanupHandleAsVersionSeven() throws {
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
        XCTAssertEqual(decoded.serializationVersion, 7)
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
