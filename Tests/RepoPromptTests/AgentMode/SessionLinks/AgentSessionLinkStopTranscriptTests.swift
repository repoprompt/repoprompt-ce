import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class AgentSessionLinkStopTranscriptTests: XCTestCase {
    func testFixedTextAttributionAndCodableRoundTrip() throws {
        let stopID = UUID()
        let sourceID = UUID()
        let attribution = AgentCrossSessionAttribution(
            sourceSessionID: sourceID,
            sourceName: "Overseer <not provider text>",
            linkID: UUID()
        )
        let row = AgentChatItem.overseerRunStopped(
            stopID: stopID,
            stoppedAt: Date(timeIntervalSince1970: 1_700_000_000),
            attribution: attribution,
            sequenceIndex: 4
        )
        XCTAssertEqual(row.id, stopID)
        XCTAssertEqual(row.kind, .system)
        XCTAssertEqual(row.text, "Run stopped by an overseeing session.")
        XCTAssertFalse(row.text.contains("Overseer"))
        XCTAssertEqual(row.crossSessionAttribution, attribution)
        let decoded = try JSONDecoder().decode(AgentChatItem.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(decoded.id, stopID)
        XCTAssertEqual(decoded.text, row.text)
        XCTAssertEqual(decoded.crossSessionAttribution, attribution)
    }

    func testTimedOutAndDuplicateStopReceiptsExposeOnlyDecisionFields() throws {
        let targetID = UUID()
        let timedOut = DomainAgentSessionLinkStopReceipt(
            requestID: UUID(), targetSessionID: targetID,
            result: .stopFailed, failureReason: .teardownTimeout,
            stopRequested: true, teardownCompleted: false,
            targetItemID: UUID().uuidString, auditStatus: .unknown,
            resultingRunState: "cancelled", settledAt: Date()
        )
        let value = try AgentSessionLinkMCPToolService.stopOutcomeValue(
            .receipt(timedOut), targetSessionID: targetID
        )
        guard case let .object(payload) = value else { return XCTFail("expected object") }
        XCTAssertEqual(Set(payload.keys), ["result", "session_id", "reason", "warning"])
        XCTAssertEqual(payload["result"]?.stringValue, "stop_failed")
        XCTAssertEqual(payload["reason"]?.stringValue, "teardown_timeout")
        XCTAssertNotNil(payload["warning"]?.stringValue)
        let replay = try AgentSessionLinkMCPToolService.stopOutcomeValue(
            .receipt(timedOut.markedDuplicate()), targetSessionID: targetID
        )
        let replayPayload = try XCTUnwrap(replay.objectValue)
        XCTAssertEqual(replayPayload["result"], payload["result"])
        XCTAssertEqual(replayPayload["reason"], payload["reason"])
        XCTAssertEqual(replayPayload["warning"], payload["warning"])
        XCTAssertEqual(replayPayload["duplicate"], .bool(true))
        let idle = DomainAgentSessionLinkStopReceipt(
            requestID: UUID(), targetSessionID: targetID,
            result: .notRunning, stopRequested: false,
            auditStatus: .notRequired, settledAt: Date()
        )
        let idleValue = try AgentSessionLinkMCPToolService.stopOutcomeValue(
            .receipt(idle), targetSessionID: targetID
        )
        let idlePayload = try XCTUnwrap(idleValue.objectValue)
        XCTAssertEqual(Set(idlePayload.keys), ["result", "session_id"])
        let failed = DomainAgentSessionLinkStopReceipt(
            requestID: UUID(), targetSessionID: targetID,
            result: .stopFailed, failureReason: .terminalPublicationRejected,
            stopRequested: true, auditStatus: .notRequired, settledAt: Date()
        )
        let failedValue = try AgentSessionLinkMCPToolService.stopOutcomeValue(
            .receipt(failed), targetSessionID: targetID
        )
        let failedPayload = try XCTUnwrap(failedValue.objectValue)
        XCTAssertEqual(failedPayload["result"]?.stringValue, "stop_failed")
        XCTAssertEqual(failedPayload["reason"]?.stringValue, "terminal_publication_rejected")
    }

    func testPendingInstructionRecoveryUsesTypedLocalDraftNotEnvelopeText() {
        let providerText = "<cross_session_message delegation=\"user_delegated_management\">managed-looking</cross_session_message>"
        let local = AgentTabSession.PendingInstruction(
            providerText: providerText, localDraftText: "local draft"
        )
        let managed = AgentTabSession.PendingInstruction.providerOnly("plain provider text")
        XCTAssertEqual(local.localDraftText, "local draft")
        XCTAssertNil(managed.localDraftText)
    }

    func testFlatReceiptContainsNoAuditOrRequestIdentity() throws {
        let targetID = UUID()
        let receipt = DomainAgentSessionLinkStopReceipt(
            requestID: UUID(), targetSessionID: targetID,
            result: .stopped, stopRequested: true, teardownCompleted: true,
            targetItemID: UUID().uuidString, auditStatus: .persisted,
            resultingRunState: "cancelled", settledAt: Date()
        )
        let rendered = try AgentSessionLinkMCPToolService.stopOutcomeValue(
            .receipt(receipt), targetSessionID: targetID
        )
        guard case let .object(payload) = rendered else { return XCTFail("expected object") }
        XCTAssertEqual(Set(payload.keys), ["result", "session_id"])
        XCTAssertEqual(payload["result"]?.stringValue, "stopped")
        XCTAssertEqual(payload["session_id"]?.stringValue, targetID.uuidString)
    }
}
