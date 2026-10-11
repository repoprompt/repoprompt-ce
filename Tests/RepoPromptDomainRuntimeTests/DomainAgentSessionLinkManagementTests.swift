import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// New grants are managed, while exact-grant fences still reject restricted and revoked links.
final class DomainAgentSessionLinkManagementTests: XCTestCase {
    private enum FixtureError: Error {
        case reservationFailed
        case activationFailed
    }

    private func makeAuthority() -> DomainAgentSessionLinkAuthority {
        DomainAgentSessionLinkAuthority(
            identity: DomainRuntimeIdentity(
                runtimeID: UUID(),
                lifecycleGeneration: 1,
                processID: 1,
                mode: .app,
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            now: { Date(timeIntervalSince1970: 1000) }
        )
    }

    private func makeEndpoint(windowID: Int) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: windowID,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        )
    }

    private func activateLink(
        _ authority: DomainAgentSessionLinkAuthority,
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity,
        restrictedCapabilities: Set<DomainAgentSessionLinkCapability>? = nil
    ) async throws -> DomainAgentSessionLinkGrant {
        let disposition: DomainAgentSessionLinkReservationDisposition = if let restrictedCapabilities {
            await authority.reserveLink(observer: observer, target: target, capabilities: restrictedCapabilities)
        } else {
            await authority.reserveLink(observer: observer, target: target)
        }
        guard case let .reserved(pending, _) = disposition else { throw FixtureError.reservationFailed }
        let activation = await authority.activateLink(
            reservation: pending,
            initialSnapshot: DomainAgentSessionObservationSnapshot(
                sessionID: target.sessionID,
                displayName: "Target",
                providerDisplayName: "Codex CLI",
                status: .running,
                board: .empty,
                idleForSend: false,
                pendingInteractionKind: nil,
                latestVisibleAssistantPreview: nil,
                visibleRowCount: 1,
                lastActivityAt: Date(timeIntervalSince1970: 500)
            ),
            sourcePublicationSequence: 1
        )
        guard case let .activated(activated) = activation else { throw FixtureError.activationFailed }
        return activated.grant
    }

    func testSetModelOriginalManageLeaseCannotSurviveRevokeRelinkOrAuthorizeWatchOnly() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorSetModel, observerEndpoint: observer, targetSessionID: target.sessionID
        ).get()
        XCTAssertEqual(DomainAgentSessionTargetOperation.monitorSetModel.family, .monitor)
        XCTAssertFalse(DomainAgentSessionTargetOperation.monitorSetModel.isObserverScoped)
        XCTAssertTrue(DomainAgentSessionTargetOperation.monitorSetModel.mutatesTarget)
        let initial = await authority.validate(lease: lease)
        XCTAssertNil(initial)
        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .userRequested)
        _ = try await activateLink(
            authority,
            observer: observer,
            target: target,
            restrictedCapabilities: DomainAgentSessionLinkCapability.version1
        )
        let stale = await authority.validate(lease: lease)
        XCTAssertNotNil(stale)
        let restricted = await authority.authorize(
            operation: .monitorSetModel, observerEndpoint: observer, targetSessionID: target.sessionID
        )
        XCTAssertEqual(restricted, .failure(.capabilityDenied))
    }

    func testWorktreeBindingRequiresTheExactManageGrant() async throws {
        let operation = DomainAgentSessionTargetOperation.monitorWorktreeBinding
        XCTAssertEqual(operation.family, .monitor)
        XCTAssertFalse(operation.isObserverScoped)
        XCTAssertTrue(operation.mutatesTarget)
        XCTAssertEqual(operation.requiredMonitorCapability, .manage)

        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let unlinked = makeEndpoint(windowID: 3)
        _ = try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: operation, observerEndpoint: observer, targetSessionID: target.sessionID
        ).get()
        XCTAssertEqual(lease.capability, .manage)
        XCTAssertEqual(lease.target, target)

        let notLinked = await authority.authorize(
            operation: operation, observerEndpoint: unlinked, targetSessionID: target.sessionID
        )
        XCTAssertEqual(notLinked, .failure(.noActiveLink))
        let reversed = await authority.authorize(
            operation: operation, observerEndpoint: target, targetSessionID: observer.sessionID
        )
        XCTAssertEqual(reversed, .failure(.noActiveLink), "links are directional")

        let watchOnlyAuthority = makeAuthority()
        _ = try await activateLink(
            watchOnlyAuthority,
            observer: observer,
            target: target,
            restrictedCapabilities: DomainAgentSessionLinkCapability.version1
        )
        let watchOnly = await watchOnlyAuthority.authorize(
            operation: operation, observerEndpoint: observer, targetSessionID: target.sessionID
        )
        XCTAssertEqual(watchOnly, .failure(.capabilityDenied))
    }

    func testNewGrantsStartManagedAndKeepWatchOperationsAvailable() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)

        XCTAssertEqual(grant.capabilities, DomainAgentSessionLinkCapability.managed)
        for operation in [DomainAgentSessionTargetOperation.monitorRespond, .monitorSteer, .monitorSetModel] {
            let lease = try await authority.authorize(
                operation: operation,
                observerEndpoint: observer,
                targetSessionID: target.sessionID
            ).get()
            XCTAssertEqual(lease.capability, .manage, operation.rawValue)
        }
        let watchLease = try await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        XCTAssertEqual(watchLease.capability, .poll)
        let inventory = await authority.links(forObserverEndpoint: observer)
        XCTAssertEqual(inventory.items.first?.capabilityNames, ["manage", "poll", "read", "send_when_idle", "wait"])
    }

    func testRestrictedExistingGrantDoesNotUpgradeWhenDefaultReservationFindsIt() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(
            authority,
            observer: observer,
            target: target,
            restrictedCapabilities: DomainAgentSessionLinkCapability.version1
        )
        XCTAssertEqual(grant.capabilities, DomainAgentSessionLinkCapability.version1)
        let denied = await authority.authorize(
            operation: .monitorRespond,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        )
        guard case let .failure(reason) = denied else { return XCTFail("Restricted grant authorized respond") }
        XCTAssertEqual(reason, .capabilityDenied)

        let repeated = await authority.reserveLink(observer: observer, target: target)
        guard case let .existing(existing) = repeated else { return XCTFail("Expected existing grant") }
        XCTAssertEqual(existing.id, grant.id)
        XCTAssertEqual(existing.capabilities, DomainAgentSessionLinkCapability.version1)
    }

    func testManagedAuthorityRequiresExactObserverAndFreshGeneration() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let otherObserver = makeEndpoint(windowID: 3)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorSteer,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let foreign = await authority.authorize(
            operation: .monitorSteer,
            observerEndpoint: otherObserver,
            targetSessionID: target.sessionID
        )
        guard case .failure = foreign else { return XCTFail("UUID knowledge is not an exact direct grant") }

        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .userRequested)
        let revokedLeaseError = await authority.validate(lease: lease)
        XCTAssertNotNil(revokedLeaseError, "Revocation invalidates issued leases")
        let replacement = try await activateLink(authority, observer: observer, target: target)
        XCTAssertNotEqual(replacement.id, grant.id)
        XCTAssertEqual(replacement.capabilities, DomainAgentSessionLinkCapability.managed)
        let staleLeaseError = await authority.validate(lease: lease)
        XCTAssertNotNil(staleLeaseError, "A stale generation cannot resurrect")
    }
}
