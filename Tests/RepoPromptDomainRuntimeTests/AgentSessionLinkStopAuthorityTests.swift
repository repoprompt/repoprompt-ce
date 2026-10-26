import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class AgentSessionLinkStopAuthorityTests: XCTestCase {
    private func endpoint(windowID: Int) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: windowID,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        )
    }

    private func authority() -> DomainAgentSessionLinkAuthority {
        DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: 1,
            mode: .app,
            createdAt: Date(timeIntervalSince1970: 0)
        ))
    }

    private func lease(
        _ authority: DomainAgentSessionLinkAuthority,
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity,
        capabilities: Set<DomainAgentSessionLinkCapability> = DomainAgentSessionLinkCapability.managed,
        operation: DomainAgentSessionTargetOperation = .monitorStop
    ) async throws -> DomainAgentSessionLinkLease {
        guard case let .reserved(pending, _) = await authority.reserveLink(
            observer: observer,
            target: target,
            capabilities: capabilities
        ) else { throw FixtureError.reservation }
        let snapshot = DomainAgentSessionObservationSnapshot(
            sessionID: target.sessionID,
            displayName: "target",
            providerDisplayName: "test",
            status: .idle,
            board: .empty,
            idleForSend: true,
            pendingInteractionKind: nil,
            latestVisibleAssistantPreview: nil,
            visibleRowCount: 0,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        guard case .activated = await authority.activateLink(
            reservation: pending,
            initialSnapshot: snapshot,
            sourcePublicationSequence: 1
        ) else { throw FixtureError.activation }
        return try await authority.authorize(
            operation: operation,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
    }

    private enum FixtureError: Error { case reservation, activation }

    private func receipt(
        _ reservation: DomainAgentSessionLinkSendReservation,
        result: DomainAgentSessionLinkStopReceipt.Result
    ) -> DomainAgentSessionLinkStopReceipt {
        DomainAgentSessionLinkStopReceipt(
            requestID: reservation.id,
            targetSessionID: reservation.targetSessionID,
            result: result,
            failureReason: result == .stopFailed ? .teardownTimeout : nil,
            stopRequested: result == .notRunning ? false : true,
            teardownCompleted: result == .stopped ? true : nil,
            targetItemID: result == .notRunning ? nil : "item-\(reservation.id.uuidString)",
            auditStatus: result == .notRunning ? .notRequired : .persisted,
            resultingRunState: result == .notRunning ? nil : "cancelled",
            settledAt: Date(timeIntervalSince1970: 42)
        )
    }

    func testManageLeaseRetainsEveryStopOutcomeAndReplaysWithoutNewReservation() async throws {
        let authority = authority()
        let observer = endpoint(windowID: 1)
        let target = endpoint(windowID: 2)
        let lease = try await lease(authority, observer: observer, target: target)

        for result in [
            DomainAgentSessionLinkStopReceipt.Result.stopped,
            .notRunning,
            .stopFailed
        ] {
            let key = result.rawValue
            guard case let .reserved(reservation) = await authority.beginStop(
                lease: lease, idempotencyKey: key
            ) else { return XCTFail("Expected a stop reservation for \(key)") }
            let inProgress = await authority.beginStop(lease: lease, idempotencyKey: key)
            XCTAssertEqual(inProgress, .inProgress)
            let commit = await authority.commitSendAuthorization(
                reservation: reservation,
                linkGeneration: reservation.linkGeneration,
                requiresManagement: true
            )
            XCTAssertEqual(commit, .committed)
            let original = receipt(reservation, result: result)
            await authority.completeStop(reservation: reservation, receipt: original)
            guard case let .duplicate(replayed) = await authority.beginStop(
                lease: lease, idempotencyKey: key
            ) else { return XCTFail("Expected a retained duplicate for \(key)") }
            XCTAssertEqual(replayed, original.markedDuplicate())
            XCTAssertEqual(replayed.requestID, reservation.id)
            let sendReceipt = await authority.storedSendReceipt(reservation: reservation)
            XCTAssertNil(sendReceipt)
        }
    }

    func testStopAndSendKeysConflictAndRestrictedGrantCannotReserveStop() async throws {
        let authority = authority()
        let observer = endpoint(windowID: 1)
        let target = endpoint(windowID: 2)
        let manageLease = try await lease(authority, observer: observer, target: target)
        guard case let .reserved(stopReservation) = await authority.beginStop(
            lease: manageLease, idempotencyKey: "shared"
        ) else { return XCTFail("Expected stop reservation") }
        let sendConflict = await authority.beginSend(
            lease: manageLease,
            idempotencyKey: "shared",
            messageDigest: "send-digest"
        )
        XCTAssertEqual(sendConflict, .conflict)
        let commit = await authority.commitSendAuthorization(
            reservation: stopReservation,
            linkGeneration: stopReservation.linkGeneration,
            requiresManagement: true
        )
        XCTAssertEqual(commit, .committed)
        await authority.completeStop(
            reservation: stopReservation,
            receipt: receipt(stopReservation, result: .notRunning)
        )
        let probeConflict = await authority.probeSend(
            lease: manageLease,
            idempotencyKey: "shared",
            messageDigest: "send-digest"
        )
        XCTAssertEqual(probeConflict, .conflict)

        let restrictedAuthority = self.authority()
        let restrictedLease = try await lease(
            restrictedAuthority,
            observer: endpoint(windowID: 3),
            target: endpoint(windowID: 4),
            capabilities: DomainAgentSessionLinkCapability.version1,
            operation: .monitorSend
        )
        let restrictedStop = await restrictedAuthority.beginStop(
            lease: restrictedLease, idempotencyKey: "restricted"
        )
        XCTAssertEqual(restrictedStop, .rejected(.capabilityDenied))
    }

    func testStopReceiptRejectsWrongRequestIdentityAndRevocationRetiresLedger() async throws {
        let authority = authority()
        let observer = endpoint(windowID: 1)
        let target = endpoint(windowID: 2)
        let lease = try await lease(authority, observer: observer, target: target)
        guard case let .reserved(reservation) = await authority.beginStop(
            lease: lease, idempotencyKey: "once"
        ) else { return XCTFail("Expected stop reservation") }
        let commit = await authority.commitSendAuthorization(
            reservation: reservation,
            linkGeneration: reservation.linkGeneration,
            requiresManagement: true
        )
        XCTAssertEqual(commit, .committed)
        let invalid = DomainAgentSessionLinkStopReceipt(
            requestID: UUID(),
            targetSessionID: target.sessionID,
            result: .notRunning,
            stopRequested: false,
            auditStatus: .notRequired,
            settledAt: Date()
        )
        await authority.completeStop(reservation: reservation, receipt: invalid)
        let stillInProgress = await authority.beginStop(lease: lease, idempotencyKey: "once")
        XCTAssertEqual(stillInProgress, .inProgress)
        await authority.completeStop(
            reservation: reservation,
            receipt: receipt(reservation, result: .stopped)
        )
        _ = await authority.revoke(linkID: lease.linkID, generation: lease.linkGeneration, reason: .userRequested)
        let staleLeaseError = await authority.validate(lease: lease)
        XCTAssertNotNil(staleLeaseError)
        let revokedStop = await authority.beginStop(lease: lease, idempotencyKey: "once")
        XCTAssertEqual(revokedStop, .rejected(.linkRevoked))
    }
}
