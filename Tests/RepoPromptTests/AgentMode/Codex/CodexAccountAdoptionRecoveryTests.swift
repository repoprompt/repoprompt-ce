@testable import RepoPromptApp
import XCTest

final class CodexAccountAdoptionRecoveryTests: XCTestCase {
    func testActualRuntimeInitialAndCompletedHistoryPayloads() throws {
        for (index, fixture) in try CodexManagedHTTPThreadFixture.responses().enumerated() {
            let response = try XCTUnwrap(fixture["read"] as? [String: Any])
            let loaded = try XCTUnwrap(fixture["loaded"] as? [String: Any])
            let thread = try XCTUnwrap(response["thread"] as? [String: Any])
            let id = try XCTUnwrap(thread["id"] as? String)
            let proof = try CodexManagedHTTPPolicy.threadProof(
                response: response,
                loaded: loaded,
                expectedThreadID: id,
                pendingMutation: false,
                persistedTools: []
            )
            XCTAssertTrue(proof.isAuthoritativelyIdle)
            XCTAssertFalse(proof.hasInProgressTools)
            let turns = try XCTUnwrap(thread["turns"] as? [[String: Any]])
            XCTAssertEqual(turns.count, index)
        }
    }

    func testRevokedConsentCannotWritePrivilegedNativePayload() throws {
        let authorization = CodexAccountAdoptionAuthorization()
        var writes = 0
        try authorization.withAuthorization { writes += 1 }
        authorization.invalidate()
        XCTAssertThrowsError(try authorization.withAuthorization { writes += 1 })
        XCTAssertEqual(writes, 1)
    }

    func testMetadataOnlyProofRequiresFreshNeverDispatchedController() throws {
        var fresh = CodexManagedHTTPPolicy.RequestGate()
        XCTAssertFalse(fresh.permitsUnmaterializedThreadProof)
        try fresh.claimStartup()
        try fresh.authorize(method: "thread/start")
        try fresh.bindThread("new")
        XCTAssertTrue(fresh.permitsUnmaterializedThreadProof)
        XCTAssertThrowsError(try fresh.authorize(method: "turn/start"))
        XCTAssertTrue(fresh.permitsUnmaterializedThreadProof)
        let lease = try fresh.reserve()
        fresh.finish(lease, allowTurns: true)
        try fresh.authorize(method: "turn/start")
        XCTAssertFalse(fresh.permitsUnmaterializedThreadProof)
        var resumed = CodexManagedHTTPPolicy.RequestGate(expectedResumeThreadID: "existing")
        try resumed.claimStartup()
        try resumed.authorize(method: "thread/resume", requestedThreadID: "existing")
        try resumed.bindThread("existing")
        XCTAssertFalse(resumed.permitsUnmaterializedThreadProof)
    }

    func testRepairMarkerSurvivesReopenAndLegacySessionsStayOff() throws {
        let saved = AgentSession(codexConversationID: "retained-thread", requiresSwitchboardPairing: true)
        let reopened = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reopened.requiresSwitchboardPairing, true)
        XCTAssertEqual(reopened.codexConversationID, "retained-thread")
        let ordinary = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(AgentSession()))
        XCTAssertNil(ordinary.requiresSwitchboardPairing)
        XCTAssertNil(AgentSession(parentSessionID: saved.id).requiresSwitchboardPairing)
    }

    func testExplicitRepairCanOnlyResumeTheRetainedNativeThreadOnce() throws {
        var gate = CodexManagedHTTPPolicy.RequestGate(expectedResumeThreadID: "retained-thread")
        try gate.claimStartup()
        XCTAssertThrowsError(try gate.authorize(method: "thread/start"))
        XCTAssertThrowsError(try gate.authorize(method: "thread/resume", requestedThreadID: "replacement"))
        try gate.authorize(method: "thread/resume", requestedThreadID: "retained-thread")
        XCTAssertThrowsError(try gate.authorize(method: "thread/resume", requestedThreadID: "retained-thread"))
        XCTAssertThrowsError(try gate.bindThread("replacement"))
        try gate.bindThread("retained-thread")
        XCTAssertThrowsError(try gate.authorize(method: "turn/start"))
    }

    func testNativeIdleProofUsesActualRPCIdentityAndStatus() throws {
        let proof = try CodexManagedHTTPPolicy.threadProof(
            response: Self.thread(), loaded: ["data": ["retained-thread"]], expectedThreadID: "retained-thread",
            pendingMutation: false, persistedTools: []
        )
        XCTAssertEqual(proof.threadID, "retained-thread")
        XCTAssertTrue(proof.isAuthoritativelyIdle)
        XCTAssertFalse(proof.hasInProgressTools)
        let blocked = try CodexManagedHTTPPolicy.threadProof(
            response: Self.thread(), loaded: ["data": ["retained-thread"]], expectedThreadID: "retained-thread",
            pendingMutation: true, persistedTools: ["exec"]
        )
        XCTAssertFalse(blocked.isAuthoritativelyIdle)
        XCTAssertTrue(blocked.hasInProgressTools)
    }

    func testMalformedUnknownAndMismatchedNativeStateFailsClosed() throws {
        var variants: [[String: Any]] = [[:]]
        for key in ["id", "modelProvider", "status", "turns"] {
            var thread = try XCTUnwrap(Self.thread()["thread"] as? [String: Any])
            thread.removeValue(forKey: key)
            variants.append(["thread": thread])
        }
        for status in ["unknown", "systemError", "notLoaded"] {
            var thread = try XCTUnwrap(Self.thread()["thread"] as? [String: Any])
            thread["status"] = ["type": status]
            variants.append(["thread": thread])
        }
        for response in variants {
            XCTAssertThrowsError(try CodexManagedHTTPPolicy.threadProof(
                response: response, loaded: ["data": ["retained-thread"]], expectedThreadID: "retained-thread",
                pendingMutation: false, persistedTools: []
            ))
        }
        for loaded in [[:], ["data": []], ["data": ["retained-thread", "other"]], ["data": ["other"]]] as [[String: Any]] {
            XCTAssertThrowsError(try CodexManagedHTTPPolicy.threadProof(
                response: Self.thread(), loaded: loaded, expectedThreadID: "retained-thread",
                pendingMutation: false, persistedTools: []
            ))
        }
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.threadProof(
            response: Self.thread(), loaded: ["data": ["retained-thread"], "nextCursor": "more-hidden-threads"],
            expectedThreadID: "retained-thread", pendingMutation: false, persistedTools: []
        ))
    }

    private static func thread() -> [String: Any] {
        ["thread": [
            "id": "retained-thread",
            "modelProvider": CodexManagedHTTPPolicy.providerID,
            "status": ["type": "idle"],
            "turns": []
        ]]
    }
}
