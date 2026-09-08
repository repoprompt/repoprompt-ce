import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainAgentSessionLinkAuthorityTests: XCTestCase {
    private enum FixtureError: Error {
        case reservationFailed
        case activationFailed
    }

    // MARK: - Fixtures

    private func makeAuthority(
        lifecycleGeneration: UInt64 = 1,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1000) }
    ) -> DomainAgentSessionLinkAuthority {
        DomainAgentSessionLinkAuthority(
            identity: DomainRuntimeIdentity(
                runtimeID: UUID(),
                lifecycleGeneration: lifecycleGeneration,
                processID: 1,
                mode: .app,
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            now: now
        )
    }

    private func makeEndpoint(
        windowID: Int = 1,
        workspaceID: UUID = UUID(),
        tabID: UUID = UUID(),
        sessionID: UUID = UUID(),
        persistentBindingGeneration: UUID? = UUID(),
        bindingTransitionGeneration: UInt64 = 1
    ) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            persistentBindingGeneration: persistentBindingGeneration,
            bindingTransitionGeneration: bindingTransitionGeneration
        )
    }

    private func makeSnapshot(
        sessionID: UUID,
        status: DomainAgentSessionLinkStatus = .idle,
        pendingInteractionKind: DomainAgentSessionLinkPendingInteractionKind? = nil,
        displayName: String? = "Target",
        visibleRowCount: Int = 3,
        /// `nil` derives the ordinary case. Pass `false` for the state that motivates `until: sendable`:
        /// status-idle with no interaction, but still committing, queued, or preparing.
        idleForSend: Bool? = nil
    ) -> DomainAgentSessionObservationSnapshot {
        DomainAgentSessionObservationSnapshot(
            sessionID: sessionID,
            displayName: displayName,
            providerDisplayName: "Codex CLI",
            status: status,
            idleForSend: idleForSend ?? (status == .idle && pendingInteractionKind == nil),
            pendingInteractionKind: pendingInteractionKind,
            latestVisibleAssistantPreview: "preview",
            visibleRowCount: visibleRowCount,
            lastActivityAt: Date(timeIntervalSince1970: 500)
        )
    }

    @discardableResult
    private func activateLink(
        _ authority: DomainAgentSessionLinkAuthority,
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity,
        sourcePublicationSequence: UInt64 = 1,
        status: DomainAgentSessionLinkStatus = .idle
    ) async throws -> DomainAgentSessionLinkGrant {
        let reservation = await authority.reserveLink(observer: observer, target: target)
        guard case let .reserved(pending, _) = reservation else {
            XCTFail("Expected reservation, got \(reservation)")
            throw FixtureError.reservationFailed
        }
        let activation = await authority.activateLink(
            reservation: pending,
            initialSnapshot: makeSnapshot(sessionID: target.sessionID, status: status),
            sourcePublicationSequence: sourcePublicationSequence
        )
        guard case let .activated(activated) = activation else {
            XCTFail("Expected activation, got \(activation)")
            throw FixtureError.activationFailed
        }
        return activated.grant
    }

    private func waitUntilParked(
        _ authority: DomainAgentSessionLinkAuthority,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 400 {
            if await authority.snapshot().parkedWaiterCount >= count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Waiter never parked", file: file, line: line)
    }

    // MARK: - Reservation, activation, invariants

    func testActivationSeedsInitialSnapshotSoFirstPollIsNeverEmpty() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)

        let lease = try await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let state = await authority.targetState(for: lease)
        XCTAssertEqual(state?.sessionID, target.sessionID)
        XCTAssertEqual(state?.linkID, grant.id)
        XCTAssertEqual(state?.snapshot.displayName, "Target")
        XCTAssertFalse(state?.waitCursor.isEmpty ?? true)
    }

    func testDuplicateEndpointPairReturnsExistingGrantInsteadOfSecondGeneration() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)

        let second = await authority.reserveLink(observer: observer, target: target)
        guard case let .existing(existing) = second else {
            return XCTFail("Expected existing link, got \(second)")
        }
        XCTAssertEqual(existing.id, grant.id)
        XCTAssertEqual(existing.generation, grant.generation)
        let inventory = await authority.links(forObserver: observer.sessionID)
        XCTAssertEqual(inventory.items.count, 1)
    }

    func testActiveGrantLookupIsGenerationQualifiedReadOnlyAndEndsAtRevocation() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)
        let reference = DomainAgentSessionLinkReference(
            linkID: grant.id,
            generation: grant.generation
        )
        let revisionBeforeLookup = await authority.snapshot().authorityRevision

        let active = await authority.activeGrant(for: reference)
        let staleGeneration = await authority.activeGrant(for: DomainAgentSessionLinkReference(
            linkID: grant.id,
            generation: grant.generation &+ 1
        ))
        let unknownLink = await authority.activeGrant(for: DomainAgentSessionLinkReference(
            linkID: UUID(),
            generation: grant.generation
        ))
        let revisionAfterLookup = await authority.snapshot().authorityRevision

        XCTAssertEqual(active, grant)
        XCTAssertNil(staleGeneration)
        XCTAssertNil(unknownLink)
        XCTAssertEqual(revisionAfterLookup, revisionBeforeLookup)

        _ = await authority.revoke(
            linkID: grant.id,
            generation: grant.generation,
            reason: .userRequested
        )
        let afterRevocation = await authority.activeGrant(for: reference)
        XCTAssertNil(afterRevocation)
    }

    func testSelfMonitorAndUnresolvedBindingsAreRejected() async throws {
        let authority = makeAuthority()
        let sessionID = UUID()
        let selfEndpoint = makeEndpoint(sessionID: sessionID)
        let selfReservation = await authority.reserveLink(observer: selfEndpoint, target: selfEndpoint)
        XCTAssertEqual(selfReservation, .rejected(.selfMonitor))

        let unboundObserver = makeEndpoint(persistentBindingGeneration: nil)
        let target = makeEndpoint(windowID: 2)
        let observerRejection = await authority.reserveLink(observer: unboundObserver, target: target)
        XCTAssertEqual(observerRejection, .rejected(.observerBindingUnresolved))

        let unboundTarget = makeEndpoint(windowID: 2, persistentBindingGeneration: nil)
        let targetRejection = await authority.reserveLink(observer: makeEndpoint(), target: unboundTarget)
        XCTAssertEqual(targetRejection, .rejected(.targetBindingUnresolved))
    }

    func testExistingOutboundRequirementIsRecheckedAtomicallyAtActivation() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let existingTarget = makeEndpoint(windowID: 2)
        let newTarget = makeEndpoint(windowID: 3)

        let noAuthority = await authority.reserveLink(
            observer: observer,
            target: newTarget,
            requiresExistingOutboundLink: true
        )
        XCTAssertEqual(noAuthority, .rejected(.observerHasNoActiveOutboundLink))

        let existingGrant = try await activateLink(
            authority,
            observer: observer,
            target: existingTarget
        )
        let conditional = await authority.reserveLink(
            observer: observer,
            target: newTarget,
            requiresExistingOutboundLink: true
        )
        guard case let .reserved(pending, _) = conditional else {
            return XCTFail("expected conditional reservation, got \(conditional)")
        }

        _ = await authority.revoke(
            linkID: existingGrant.id,
            generation: existingGrant.generation,
            reason: .userRequested
        )
        let activation = await authority.activateLink(
            reservation: pending,
            initialSnapshot: makeSnapshot(sessionID: newTarget.sessionID),
            sourcePublicationSequence: 1
        )

        XCTAssertEqual(activation, .rejected(.observerHasNoActiveOutboundLink))
        let snapshot = await authority.snapshot()
        XCTAssertEqual(snapshot.activeLinkCount, 0)
        XCTAssertEqual(snapshot.pendingReservationCount, 0)
    }

    func testMultipleObserversMayMonitorOneTargetWithoutArtificialCap() async throws {
        let authority = makeAuthority()
        let target = makeEndpoint(windowID: 9)
        var observers: [DomainAgentSessionLinkEndpointIdentity] = []
        for index in 0 ..< 12 {
            let observer = makeEndpoint(windowID: index)
            observers.append(observer)
            try await activateLink(authority, observer: observer, target: target)
        }
        let inbound = await authority.links(forTarget: target.sessionID)
        XCTAssertEqual(inbound.items.count, 12)
        for observer in observers {
            let outbound = await authority.links(forObserver: observer.sessionID)
            XCTAssertEqual(outbound.items.count, 1)
        }
        let snapshot = await authority.snapshot()
        XCTAssertEqual(snapshot.observedTargetCount, 1)
    }

    func testActivationRollsBackWhenTargetEndpointDrifted() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        let reservation = await authority.reserveLink(observer: observer, target: target)
        guard case let .reserved(pending, _) = reservation else { return XCTFail("expected reservation") }

        let mismatch = await authority.activateLink(
            reservation: pending,
            initialSnapshot: makeSnapshot(sessionID: UUID()),
            sourcePublicationSequence: 1
        )
        XCTAssertEqual(mismatch, .rejected(.snapshotSessionMismatch))
        let retry = await authority.activateLink(
            reservation: pending,
            initialSnapshot: makeSnapshot(sessionID: target.sessionID),
            sourcePublicationSequence: 1
        )
        XCTAssertEqual(retry, .rejected(.unknownReservation))
        let snapshot = await authority.snapshot()
        XCTAssertEqual(snapshot.pendingReservationCount, 0)
        XCTAssertEqual(snapshot.activeLinkCount, 0)
    }

    func testConcurrentReservationsForOneTargetElectExactlyOneFirstInboundInstaller() async throws {
        let authority = makeAuthority()
        let target = makeEndpoint(windowID: 9)
        let observerA = makeEndpoint(windowID: 1)
        let observerB = makeEndpoint(windowID: 2)

        // Both reservations are taken before either activates, which is exactly the two-observers-
        // added-back-to-back race. Only one may be told to install the target observation and its
        // serial publication chain.
        let first = await authority.reserveLink(observer: observerA, target: target)
        let second = await authority.reserveLink(observer: observerB, target: target)
        guard case let .reserved(pendingA, _) = first, case let .reserved(pendingB, _) = second else {
            return XCTFail("expected two reservations, got \(first) and \(second)")
        }
        XCTAssertTrue(pendingA.provisionallyInstallsTargetObservation)
        XCTAssertFalse(
            pendingB.provisionallyInstallsTargetObservation,
            "a second concurrent observer must not install a duplicate observation chain"
        )

        let activationA = await authority.activateLink(
            reservation: pendingA,
            initialSnapshot: makeSnapshot(sessionID: target.sessionID),
            sourcePublicationSequence: 11
        )
        XCTAssertTrue(activationA.installsTargetObservation)
        let activationB = await authority.activateLink(
            reservation: pendingB,
            initialSnapshot: makeSnapshot(sessionID: target.sessionID),
            sourcePublicationSequence: 1
        )
        XCTAssertFalse(
            activationB.installsTargetObservation,
            "joining an existing target record never grants the observation role"
        )

        let snapshot = await authority.snapshot()
        XCTAssertEqual(snapshot.activeLinkCount, 2)
        XCTAssertEqual(snapshot.observedTargetCount, 1, "both links share one target record")

        // The joining activation's lower sequence must not have moved the installing chain's fence.
        let stale = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .running),
            sourcePublicationSequence: 5
        )
        XCTAssertEqual(
            stale,
            .stale(currentSourcePublicationSequence: 11),
            "high-water must still reflect the installing chain, not the joining activation"
        )
        let accepted = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .running),
            sourcePublicationSequence: 12
        )
        guard case .accepted = accepted else { return XCTFail("expected accepted, got \(accepted)") }

        // Once the first inbound link is active, a later reservation is also not the installer.
        let third = await authority.reserveLink(observer: makeEndpoint(windowID: 3), target: target)
        guard case let .reserved(pendingC, _) = third else { return XCTFail("expected reservation") }
        XCTAssertFalse(pendingC.provisionallyInstallsTargetObservation)
    }

    func testInstallerRoleIsReElectedWhenTheElectedReservationIsAbandoned() async throws {
        let authority = makeAuthority()
        let target = makeEndpoint(windowID: 9)
        let elected = await authority.reserveLink(observer: makeEndpoint(windowID: 1), target: target)
        let sibling = await authority.reserveLink(observer: makeEndpoint(windowID: 2), target: target)
        guard case let .reserved(pendingElected, _) = elected,
              case let .reserved(pendingSibling, _) = sibling
        else {
            return XCTFail("expected two reservations")
        }
        XCTAssertTrue(pendingElected.provisionallyInstallsTargetObservation)
        XCTAssertFalse(pendingSibling.provisionallyInstallsTargetObservation)

        // The elected reservation never activates: its seed build failed and the bridge rolled back.
        await authority.abandonReservation(pendingElected)

        let activation = await authority.activateLink(
            reservation: pendingSibling,
            initialSnapshot: makeSnapshot(sessionID: target.sessionID),
            sourcePublicationSequence: 7
        )
        guard case .activated = activation else {
            return XCTFail("expected activation, got \(activation)")
        }
        XCTAssertTrue(
            activation.installsTargetObservation,
            "the surviving sibling creates the target record and must inherit the installer role"
        )

        // The surviving activation owns the fence, so its own chain sequence is authoritative.
        let stale = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .running),
            sourcePublicationSequence: 7
        )
        XCTAssertEqual(stale, .stale(currentSourcePublicationSequence: 7))
        let accepted = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .running),
            sourcePublicationSequence: 8
        )
        guard case .accepted = accepted else { return XCTFail("expected accepted, got \(accepted)") }
        let observedTargets = await authority.snapshot().observedTargetCount
        XCTAssertEqual(observedTargets, 1)
    }

    func testInstallerRoleIsReElectedWhenTheElectedObserverIsInvalidatedBeforeSiblingActivation() async throws {
        let authority = makeAuthority()
        let target = makeEndpoint(windowID: 9)
        let electedObserver = makeEndpoint(windowID: 1)
        let elected = await authority.reserveLink(observer: electedObserver, target: target)
        let sibling = await authority.reserveLink(observer: makeEndpoint(windowID: 2), target: target)
        guard case let .reserved(pendingElected, _) = elected,
              case let .reserved(pendingSibling, _) = sibling
        else {
            return XCTFail("expected two reservations")
        }
        XCTAssertTrue(pendingElected.provisionallyInstallsTargetObservation)
        XCTAssertFalse(pendingSibling.provisionallyInstallsTargetObservation)

        // The elected observer's window/tab closes before it activates.
        _ = await authority.invalidate(endpoint: electedObserver, reason: .windowClosed)
        let afterInvalidation = await authority.snapshot()
        XCTAssertEqual(afterInvalidation.pendingReservationCount, 1)

        let staleActivation = await authority.activateLink(
            reservation: pendingElected,
            initialSnapshot: makeSnapshot(sessionID: target.sessionID),
            sourcePublicationSequence: 3
        )
        XCTAssertEqual(staleActivation, .rejected(.unknownReservation))

        let activation = await authority.activateLink(
            reservation: pendingSibling,
            initialSnapshot: makeSnapshot(sessionID: target.sessionID),
            sourcePublicationSequence: 4
        )
        guard case .activated = activation else {
            return XCTFail("expected activation, got \(activation)")
        }
        XCTAssertTrue(
            activation.installsTargetObservation,
            "an invalidated elected reservation must not strand the target without a publisher"
        )
        let accepted = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .running),
            sourcePublicationSequence: 5
        )
        guard case .accepted = accepted else { return XCTFail("expected accepted, got \(accepted)") }
    }

    func testLastInboundRevocationReleasesTheInstallerRoleForTheNextActivation() async throws {
        let authority = makeAuthority()
        let target = makeEndpoint(windowID: 9)
        let observer = makeEndpoint(windowID: 1)
        let grant = try await activateLink(
            authority,
            observer: observer,
            target: target,
            sourcePublicationSequence: 20
        )
        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .tabClosed)
        let observedAfterRevocation = await authority.snapshot().observedTargetCount
        XCTAssertEqual(observedAfterRevocation, 0)

        // A fresh observer re-creates the target record and must be told to install again.
        let reservation = await authority.reserveLink(observer: makeEndpoint(windowID: 2), target: target)
        guard case let .reserved(pending, _) = reservation else { return XCTFail("expected reservation") }
        XCTAssertTrue(pending.provisionallyInstallsTargetObservation)
        let activation = await authority.activateLink(
            reservation: pending,
            initialSnapshot: makeSnapshot(sessionID: target.sessionID),
            sourcePublicationSequence: 1
        )
        XCTAssertTrue(activation.installsTargetObservation)
        // The new chain restarts at a low sequence and must not be fenced by the dead chain's mark.
        let accepted = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .running),
            sourcePublicationSequence: 2
        )
        guard case .accepted = accepted else { return XCTFail("expected accepted, got \(accepted)") }
    }

    // MARK: - Membership revisions

    func testInboundMembershipRevisionIsTrackedSeparatelyFromOutboundRevision() async throws {
        let authority = makeAuthority()
        let hub = makeEndpoint(windowID: 1)
        let observerB = makeEndpoint(windowID: 2)
        let downstream = makeEndpoint(windowID: 3)

        let firstInbound = try await activateLink(authority, observer: observerB, target: hub)
        var inbound = await authority.links(forTarget: hub.sessionID)
        XCTAssertEqual(inbound.linkSetRevision, 1)
        XCTAssertEqual(inbound.items.count, 1)

        // The hub session is also an observer of a third session. Its outbound revision must not
        // alias, or advance, its inbound revision.
        try await activateLink(authority, observer: hub, target: downstream)
        inbound = await authority.links(forTarget: hub.sessionID)
        let hubOutbound = await authority.links(forObserver: hub.sessionID)
        XCTAssertEqual(inbound.linkSetRevision, 1, "an outbound add must not bump inbound membership")
        XCTAssertEqual(hubOutbound.linkSetRevision, 1)
        XCTAssertEqual(hubOutbound.items.count, 1)

        // A second inbound observer advances only the inbound revision.
        try await activateLink(authority, observer: makeEndpoint(windowID: 4), target: hub)
        inbound = await authority.links(forTarget: hub.sessionID)
        XCTAssertEqual(inbound.linkSetRevision, 2)
        XCTAssertEqual(inbound.items.count, 2)
        let hubOutboundAfter = await authority.links(forObserver: hub.sessionID)
        XCTAssertEqual(hubOutboundAfter.linkSetRevision, 1)

        // Inbound revocation advances it again.
        _ = await authority.revoke(
            linkID: firstInbound.id,
            generation: firstInbound.generation,
            reason: .userRequested
        )
        inbound = await authority.links(forTarget: hub.sessionID)
        XCTAssertEqual(inbound.linkSetRevision, 3)
        XCTAssertEqual(inbound.items.count, 1)
        let targetRevision = await authority.targetLinkSetRevision(hub.sessionID)
        XCTAssertEqual(targetRevision, 3)
    }

    // MARK: - Observer-scoped inventory

    func testInventoryAuthorizationIsObserverScopedAndEndsWithTheLastLink() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)

        let ungranted = await authority.authorizeInventory(observerEndpoint: observer)
        XCTAssertEqual(ungranted.failureError, .noActiveLink)

        let grant = try await activateLink(authority, observer: observer, target: target)
        let inventory = try await authority.authorizeInventory(observerEndpoint: observer).get()
        XCTAssertEqual(inventory.items.map(\.targetSessionID), [target.sessionID])
        XCTAssertEqual(inventory.linkSetRevision, 1)

        // The target is not an observer, so it cannot list anything.
        let reversed = await authority.authorizeInventory(observerEndpoint: target)
        XCTAssertEqual(reversed.failureError, .noActiveLink)

        // A targetless operation must never be authorized through the target-bearing lease path.
        let throughTargetPath = await authority.authorize(
            operation: .monitorList,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        )
        XCTAssertEqual(throughTargetPath.failureError, .capabilityDenied)

        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .userRequested)
        let afterFinalRevocation = await authority.authorizeInventory(observerEndpoint: observer)
        XCTAssertEqual(
            afterFinalRevocation.failureError,
            .noActiveLink,
            "after the final revocation `list` is no longer available"
        )
    }

    // MARK: - Authorization fencing

    func testAuthorizeRejectsUngrantedTargetAndNonMonitorOperations() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)

        let unrelated = await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: observer,
            targetSessionID: UUID()
        )
        XCTAssertEqual(unrelated.failureError, .noActiveLink)

        // Regression: a second live incarnation of the *same observer session UUID* — another window
        // holding the same session — holds no grant of its own and must be indistinguishable from an
        // unlinked caller at every observer-scoped entry point.
        let duplicateObserverIncarnation = makeEndpoint(
            windowID: observer.windowID + 10,
            sessionID: observer.sessionID
        )
        let duplicateLease = await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: duplicateObserverIncarnation,
            targetSessionID: target.sessionID
        )
        XCTAssertEqual(
            duplicateLease.failureError,
            .noActiveLink,
            "Knowing the granted session's UUID must not let another incarnation exercise its grant"
        )
        let duplicateAdvertised = await authority.hasActiveOutboundLink(
            observerEndpoint: duplicateObserverIncarnation
        )
        XCTAssertFalse(
            duplicateAdvertised,
            "Tool advertisement is endpoint-scoped, so a duplicate incarnation is never advertised"
        )
        let duplicateInventory = await authority.authorizeInventory(
            observerEndpoint: duplicateObserverIncarnation
        )
        XCTAssertEqual(
            duplicateInventory.failureError,
            .noActiveLink,
            "A duplicate incarnation must not be able to enumerate the granted incarnation's targets"
        )
        let duplicateLinks = await authority.links(forObserverEndpoint: duplicateObserverIncarnation)
        XCTAssertTrue(duplicateLinks.isEmpty)
        let grantedLinks = await authority.links(forObserverEndpoint: observer)
        XCTAssertEqual(
            grantedLinks.items.map(\.targetSessionID),
            [target.sessionID],
            "The granted incarnation keeps its own inventory"
        )

        let reversed = await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: target,
            targetSessionID: observer.sessionID
        )
        XCTAssertEqual(reversed.failureError, .noActiveLink, "links are directed and never reciprocal")

        let control = await authority.authorize(
            operation: .runSteer,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        )
        XCTAssertEqual(control.failureError, .capabilityDenied, "an oversight grant never authorizes agent_run")
    }

    func testRequestAttentionInverseAuthorizationRequiresExactGrantAndCurrentGeneration() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        let firstGrant = try await activateLink(authority, observer: observer, target: target)
        let liveEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = [observer, target]

        let authorization = try await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            liveEndpoints: liveEndpoints
        ).get()
        XCTAssertEqual(
            authorization.reference,
            DomainAgentSessionLinkReference(
                linkID: firstGrant.id,
                generation: firstGrant.generation
            )
        )
        XCTAssertEqual(authorization.observer, observer)
        XCTAssertEqual(authorization.target, target)
        XCTAssertNil(authorization.requestedObserverSessionID)
        let observerLinkSetRevision = await authority.observerLinkSetRevision(observer.sessionID)
        let targetLinkSetRevision = await authority.targetLinkSetRevision(target.sessionID)
        XCTAssertEqual(
            authorization.observerLinkSetRevision,
            observerLinkSetRevision
        )
        XCTAssertEqual(
            authorization.targetLinkSetRevision,
            targetLinkSetRevision
        )
        let initialValidation = await authority.validateRequestAttentionAuthorization(
            authorization,
            liveEndpoints: liveEndpoints
        )
        XCTAssertNil(initialValidation)

        let unrelatedTarget = makeEndpoint(windowID: 20)
        try await activateLink(authority, observer: observer, target: unrelatedTarget)
        let expandedLiveEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = [
            observer,
            target,
            unrelatedTarget
        ]
        let staleReducerRevision = await authority.validateRequestAttentionAuthorization(
            authorization,
            liveEndpoints: expandedLiveEndpoints
        )
        XCTAssertEqual(
            staleReducerRevision,
            .denied,
            "an otherwise-current grant cannot mutate a reducer baselined to an older link-set revision"
        )
        let currentAuthorization = try await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            liveEndpoints: expandedLiveEndpoints
        ).get()

        let duplicateTargetIncarnation = makeEndpoint(
            windowID: target.windowID + 10,
            sessionID: target.sessionID
        )
        let duplicateRoute = await authority.authorizeRequestAttention(
            requesterEndpoint: duplicateTargetIncarnation,
            liveEndpoints: expandedLiveEndpoints.union([duplicateTargetIncarnation])
        )
        XCTAssertEqual(duplicateRoute.requestAttentionFailure, .denied)

        _ = await authority.revoke(
            linkID: firstGrant.id,
            generation: firstGrant.generation,
            reason: .userRequested
        )
        let revokedValidation = await authority.validateRequestAttentionAuthorization(
            currentAuthorization,
            liveEndpoints: expandedLiveEndpoints
        )
        XCTAssertEqual(
            revokedValidation,
            .denied,
            "a proof cannot survive revocation of its exact link generation"
        )

        let secondGrant = try await activateLink(authority, observer: observer, target: target)
        let successor = try await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            observerSessionID: observer.sessionID,
            liveEndpoints: expandedLiveEndpoints
        ).get()
        XCTAssertNotEqual(secondGrant.id, firstGrant.id)
        XCTAssertNotEqual(successor.reference, currentAuthorization.reference)
        let successorValidation = await authority.validateRequestAttentionAuthorization(
            successor,
            liveEndpoints: expandedLiveEndpoints
        )
        XCTAssertNil(successorValidation)
    }

    func testRequestAttentionCardinalityIsDecidedAfterStaleEndpointFiltering() async throws {
        let authority = makeAuthority()
        let staleObserver = makeEndpoint(windowID: 1)
        let liveObserver = makeEndpoint(windowID: 2)
        let target = makeEndpoint(windowID: 3)
        try await activateLink(authority, observer: staleObserver, target: target)
        let liveGrant = try await activateLink(authority, observer: liveObserver, target: target)
        let filteredLiveEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = [liveObserver, target]

        let authorization = try await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            liveEndpoints: filteredLiveEndpoints
        ).get()
        XCTAssertEqual(authorization.reference.linkID, liveGrant.id)
        XCTAssertEqual(authorization.observer, liveObserver)
        let filteredValidation = await authority.validateRequestAttentionAuthorization(
            authorization,
            liveEndpoints: filteredLiveEndpoints
        )
        XCTAssertNil(filteredValidation)

        let explicitlyStale = await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            observerSessionID: staleObserver.sessionID,
            liveEndpoints: filteredLiveEndpoints
        )
        XCTAssertEqual(
            explicitlyStale.requestAttentionFailure,
            .denied,
            "zero live matches for an explicit UUID is an indistinguishable denial"
        )

        let bothLive: Set<DomainAgentSessionLinkEndpointIdentity> = [staleObserver, liveObserver, target]
        let ambiguousValidation = await authority.validateRequestAttentionAuthorization(
            authorization,
            liveEndpoints: bothLive
        )
        XCTAssertEqual(
            ambiguousValidation,
            .ambiguousObserver(
                candidateObserverSessionIDs: [staleObserver.sessionID, liveObserver.sessionID]
                    .sorted { $0.uuidString < $1.uuidString },
                omittedCandidateCount: 0
            ),
            "validation must repeat omitted-selector cardinality when a stale grant becomes live"
        )
        let ambiguous = await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            liveEndpoints: bothLive
        )
        guard case let .ambiguousObserver(candidateIDs, omittedCount) = ambiguous.requestAttentionFailure
        else { return XCTFail("Expected bounded omitted-selector ambiguity") }
        XCTAssertEqual(
            candidateIDs,
            [staleObserver.sessionID, liveObserver.sessionID].sorted {
                $0.uuidString < $1.uuidString
            }
        )
        XCTAssertEqual(omittedCount, 0)
    }

    func testRequestAttentionExplicitObserverUUIDWithTwoLiveIncarnationsIsAmbiguous() async throws {
        let authority = makeAuthority()
        let sharedObserverSessionID = UUID()
        let firstObserver = makeEndpoint(windowID: 1, sessionID: sharedObserverSessionID)
        let secondObserver = makeEndpoint(windowID: 2, sessionID: sharedObserverSessionID)
        let target = makeEndpoint(windowID: 3)
        try await activateLink(authority, observer: firstObserver, target: target)
        try await activateLink(authority, observer: secondObserver, target: target)
        let liveEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = [
            firstObserver,
            secondObserver,
            target
        ]

        let explicit = await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            observerSessionID: sharedObserverSessionID,
            liveEndpoints: liveEndpoints
        )
        XCTAssertEqual(
            explicit.requestAttentionFailure,
            .ambiguousObserver(
                candidateObserverSessionIDs: [],
                omittedCandidateCount: 0
            ),
            "an explicit ambiguity must not enumerate any observer UUID"
        )

        let omitted = await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            liveEndpoints: liveEndpoints
        )
        XCTAssertEqual(
            omitted.requestAttentionFailure,
            .ambiguousObserver(
                candidateObserverSessionIDs: [sharedObserverSessionID],
                omittedCandidateCount: 0
            ),
            "one candidate UUID can still name multiple exact live incarnations"
        )

        let firstOnly: Set<DomainAgentSessionLinkEndpointIdentity> = [firstObserver, target]
        let initiallyUnique = try await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            observerSessionID: sharedObserverSessionID,
            liveEndpoints: firstOnly
        ).get()
        let lateExplicitAmbiguity = await authority.validateRequestAttentionAuthorization(
            initiallyUnique,
            liveEndpoints: liveEndpoints
        )
        XCTAssertEqual(
            lateExplicitAmbiguity,
            .ambiguousObserver(
                candidateObserverSessionIDs: [],
                omittedCandidateCount: 0
            ),
            "late explicit ambiguity remains explicit and never enumerates candidates"
        )
    }

    func testRequestAttentionCandidateEnumerationIsSortedDeduplicatedAndBounded() async throws {
        let authority = makeAuthority()
        let target = makeEndpoint(windowID: 999)
        let uniqueCandidateCount = DomainAgentSessionLinkAuthority
            .requestAttentionObserverCandidateLimit + 3
        var observers: [DomainAgentSessionLinkEndpointIdentity] = []
        var liveEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = [target]

        for index in 0 ..< uniqueCandidateCount {
            let sessionID = try XCTUnwrap(UUID(uuidString: String(
                format: "10000000-0000-0000-0000-%012d",
                uniqueCandidateCount - index
            )))
            let observer = makeEndpoint(windowID: 100 + index, sessionID: sessionID)
            observers.append(observer)
            liveEndpoints.insert(observer)
            try await activateLink(authority, observer: observer, target: target)
        }
        let duplicatedSessionID = try XCTUnwrap(observers.last?.sessionID)
        let duplicateIncarnation = makeEndpoint(
            windowID: 500,
            sessionID: duplicatedSessionID
        )
        liveEndpoints.insert(duplicateIncarnation)
        try await activateLink(authority, observer: duplicateIncarnation, target: target)

        let result = await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            liveEndpoints: liveEndpoints
        )
        guard case let .ambiguousObserver(candidateIDs, omittedCount) = result.requestAttentionFailure
        else { return XCTFail("Expected bounded candidate enumeration") }

        let expectedAll = Array(Set(observers.map(\.sessionID)))
            .sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(
            candidateIDs,
            Array(expectedAll.prefix(
                DomainAgentSessionLinkAuthority.requestAttentionObserverCandidateLimit
            ))
        )
        XCTAssertEqual(Set(candidateIDs).count, candidateIDs.count)
        XCTAssertEqual(omittedCount, uniqueCandidateCount - candidateIDs.count)

        let explicitDenial = await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            observerSessionID: UUID(),
            liveEndpoints: liveEndpoints
        )
        XCTAssertEqual(
            explicitDenial.requestAttentionFailure,
            .denied,
            "an explicit zero-match denial must not return the omitted selector's candidates"
        )
    }

    func testRequestAttentionRouteRebindingInvalidatesAuthorization() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)
        let authorization = try await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            liveEndpoints: [observer, target]
        ).get()

        let reboundTarget = makeEndpoint(
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            tabID: target.tabID,
            sessionID: target.sessionID,
            persistentBindingGeneration: target.persistentBindingGeneration,
            bindingTransitionGeneration: target.bindingTransitionGeneration + 1
        )
        let reboundTargetValidation = await authority.validateRequestAttentionAuthorization(
            authorization,
            liveEndpoints: [observer, reboundTarget]
        )
        XCTAssertEqual(
            reboundTargetValidation,
            .denied
        )
        let reboundRoute = await authority.authorizeRequestAttention(
            requesterEndpoint: reboundTarget,
            observerSessionID: observer.sessionID,
            liveEndpoints: [observer, reboundTarget]
        )
        XCTAssertEqual(
            reboundRoute.requestAttentionFailure,
            .denied,
            "an exact target route must not inherit a previous incarnation's inbound grant"
        )

        let reboundObserver = makeEndpoint(
            windowID: observer.windowID,
            workspaceID: observer.workspaceID,
            tabID: observer.tabID,
            sessionID: observer.sessionID,
            persistentBindingGeneration: observer.persistentBindingGeneration,
            bindingTransitionGeneration: observer.bindingTransitionGeneration + 1
        )
        let reboundObserverValidation = await authority.validateRequestAttentionAuthorization(
            authorization,
            liveEndpoints: [reboundObserver, target]
        )
        XCTAssertEqual(
            reboundObserverValidation,
            .denied
        )
    }

    func testRequestAttentionAuthorizationReportsShutdownDistinctly() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)
        let liveEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = [observer, target]
        let authorization = try await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            liveEndpoints: liveEndpoints
        ).get()

        await authority.beginDrain()

        let rejected = await authority.authorizeRequestAttention(
            requesterEndpoint: target,
            liveEndpoints: liveEndpoints
        )
        XCTAssertEqual(rejected.requestAttentionFailure, .runtimeShuttingDown)
        let validation = await authority.validateRequestAttentionAuthorization(
            authorization,
            liveEndpoints: liveEndpoints
        )
        XCTAssertEqual(
            validation,
            .runtimeShuttingDown
        )
    }

    func testRevokedGenerationCannotAuthorizeAndRelinkMintsFreshIdentity() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        let first = try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorRead,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let cursor = try await authority.openReadCursor(
            lease: lease,
            anchor: DomainAgentSessionLinkReadAnchor(itemID: "a", sequenceIndex: 0, sourceItemsRevision: 1),
            direction: .tail
        ).get()

        let revocation = await authority.revoke(
            linkID: first.id,
            generation: first.generation,
            reason: .userRequested
        )
        guard case let .revoked(notice) = revocation else { return XCTFail("expected revocation") }
        XCTAssertEqual(notice.reason, .userRequested)
        XCTAssertEqual(notice.targetSessionID, target.sessionID)

        let repeated = await authority.revoke(
            linkID: first.id,
            generation: first.generation,
            reason: .userRequested
        )
        XCTAssertEqual(repeated, .notFound, "revocation is idempotent and never resurrects")
        let revokedLeaseError = await authority.validate(lease: lease)
        XCTAssertEqual(revokedLeaseError, .linkRevoked)

        let second = try await activateLink(authority, observer: observer, target: target)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertGreaterThan(second.generation, first.generation)
        let newLease = try await authority.authorize(
            operation: .monitorRead,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let staleCursorDisposition = await authority.resolveReadCursor(
            lease: newLease,
            opaqueCursor: cursor.handle
        )
        XCTAssertEqual(staleCursorDisposition, .expired, "an old cursor never attaches to a re-link")
    }

    func testStaleLifecycleInvalidationCannotRemoveNewerLink() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)
        let staleRevision = await authority.snapshot().authorityRevision

        let secondObserver = makeEndpoint(windowID: 3)
        try await activateLink(authority, observer: secondObserver, target: target)

        let notices = await authority.invalidate(
            endpoint: target,
            reason: .tabClosed,
            notNewerThanAuthorityRevision: staleRevision
        )
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.observerSessionID, observer.sessionID)
        let survivors = await authority.links(forTarget: target.sessionID)
        XCTAssertEqual(survivors.items.count, 1)
        XCTAssertEqual(survivors.items.first?.observerSessionID, secondObserver.sessionID)
    }

    func testStaleInvalidationDoesNotCancelANewerPendingReservation() async throws {
        let authority = makeAuthority()
        let target = makeEndpoint(windowID: 2)
        let staleObserver = makeEndpoint(windowID: 1)
        try await activateLink(authority, observer: staleObserver, target: target)
        let staleRevision = await authority.snapshot().authorityRevision

        // A second observer reserves after the stale lifecycle observation was taken.
        let reservation = await authority.reserveLink(observer: makeEndpoint(windowID: 3), target: target)
        guard case let .reserved(pending, _) = reservation else { return XCTFail("expected reservation") }

        let notices = await authority.invalidate(
            endpoint: target,
            reason: .tabClosed,
            notNewerThanAuthorityRevision: staleRevision
        )
        XCTAssertEqual(notices.count, 1, "only the observed generation is revoked")
        let afterStale = await authority.snapshot()
        XCTAssertEqual(afterStale.activeLinkCount, 0)
        XCTAssertEqual(
            afterStale.pendingReservationCount,
            1,
            "a reservation created after the observation must survive it"
        )

        let activation = await authority.activateLink(
            reservation: pending,
            initialSnapshot: makeSnapshot(sessionID: target.sessionID),
            sourcePublicationSequence: 1
        )
        guard case .activated = activation else {
            return XCTFail("the surviving reservation must still activate, got \(activation)")
        }

        // An unfenced invalidation still cancels everything, including pending reservations.
        let secondReservation = await authority.reserveLink(
            observer: makeEndpoint(windowID: 4),
            target: target
        )
        guard case .reserved = secondReservation else { return XCTFail("expected reservation") }
        _ = await authority.invalidate(endpoint: target, reason: .windowClosed)
        let cleared = await authority.snapshot()
        XCTAssertEqual(cleared.activeLinkCount, 0)
        XCTAssertEqual(cleared.pendingReservationCount, 0)
    }

    func testSessionWindowAndWorkspaceInvalidationHonourTheStalenessFenceForReservations() async throws {
        let authority = makeAuthority()
        let workspaceID = UUID()
        let target = makeEndpoint(windowID: 7, workspaceID: workspaceID)
        try await activateLink(authority, observer: makeEndpoint(windowID: 1), target: target)
        let staleRevision = await authority.snapshot().authorityRevision
        let reservation = await authority.reserveLink(observer: makeEndpoint(windowID: 8), target: target)
        guard case .reserved = reservation else { return XCTFail("expected reservation") }

        _ = await authority.invalidateSession(
            sessionID: target.sessionID,
            reason: .sessionDeleted,
            notNewerThanAuthorityRevision: staleRevision
        )
        var snapshot = await authority.snapshot()
        XCTAssertEqual(snapshot.pendingReservationCount, 1)

        _ = await authority.invalidateWindow(
            windowID: 7,
            reason: .windowClosed,
            notNewerThanAuthorityRevision: staleRevision
        )
        snapshot = await authority.snapshot()
        XCTAssertEqual(snapshot.pendingReservationCount, 1)

        _ = await authority.invalidateWorkspace(
            workspaceID: workspaceID,
            reason: .workspaceSwitched,
            notNewerThanAuthorityRevision: staleRevision
        )
        snapshot = await authority.snapshot()
        XCTAssertEqual(snapshot.pendingReservationCount, 1)

        _ = await authority.invalidateWindow(windowID: 7, reason: .windowClosed)
        snapshot = await authority.snapshot()
        XCTAssertEqual(snapshot.pendingReservationCount, 0)
    }

    func testEndpointIncarnationDriftIsInvalidatedExactly() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)

        let rebound = makeEndpoint(
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            tabID: target.tabID,
            sessionID: target.sessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: target.bindingTransitionGeneration + 1
        )
        let unrelated = await authority.invalidate(endpoint: rebound, reason: .bindingChanged)
        XCTAssertTrue(unrelated.isEmpty, "a different incarnation must not match by session ID alone")

        let exact = await authority.invalidate(endpoint: target, reason: .bindingChanged)
        XCTAssertEqual(exact.count, 1)
        let remaining = await authority.snapshot().activeLinkCount
        XCTAssertEqual(remaining, 0)
    }

    /// A reservation that revokes a stale target incarnation must hand those notices back to the
    /// caller.
    ///
    /// They revoke links belonging to observers that are not party to this call, and the only other
    /// way they reach the app is the `bufferingNewest` change feed — so a dropped event would leave
    /// those observers rendering, and advertising, a link that no longer exists.
    func testReservingOverADriftedTargetSurfacesTheLinksItRevoked() async throws {
        let authority = makeAuthority()
        let dispossessed = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: dispossessed, target: target)

        let rebound = makeEndpoint(
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            tabID: target.tabID,
            sessionID: target.sessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: target.bindingTransitionGeneration + 1
        )
        let reservation = await authority.reserveLink(
            observer: makeEndpoint(windowID: 3),
            target: rebound
        )
        guard case let .reserved(_, collateral) = reservation else {
            return XCTFail("expected reservation, got \(reservation)")
        }
        XCTAssertEqual(collateral.map(\.linkID), [grant.id])
        XCTAssertEqual(collateral.first?.observerSessionID, dispossessed.sessionID)
        XCTAssertEqual(collateral.first?.reason, .targetIdentityDrift)
        let remaining = await authority.snapshot().activeLinkCount
        XCTAssertEqual(remaining, 0, "the drifted incarnation's link is revoked, not carried over")
    }

    func testWindowAndWorkspaceInvalidationRevokeAffectedLinksOnly() async throws {
        let authority = makeAuthority()
        let workspaceID = UUID()
        let observerA = makeEndpoint(windowID: 1, workspaceID: workspaceID)
        let targetA = makeEndpoint(windowID: 2, workspaceID: workspaceID)
        let observerB = makeEndpoint(windowID: 3)
        let targetB = makeEndpoint(windowID: 4)
        try await activateLink(authority, observer: observerA, target: targetA)
        try await activateLink(authority, observer: observerB, target: targetB)

        let windowNotices = await authority.invalidateWindow(windowID: 4, reason: .windowClosed)
        XCTAssertEqual(windowNotices.count, 1)
        XCTAssertEqual(windowNotices.first?.targetSessionID, targetB.sessionID)

        let workspaceNotices = await authority.invalidateWorkspace(
            workspaceID: workspaceID,
            reason: .workspaceSwitched
        )
        XCTAssertEqual(workspaceNotices.count, 1)
        let remaining = await authority.snapshot().activeLinkCount
        XCTAssertEqual(remaining, 0)
    }

    // MARK: - Publication high-water semantics

    func testOutOfOrderPublicationNeverRegressesHighWaterMark() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target, sourcePublicationSequence: 5)

        let accepted = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .running),
            sourcePublicationSequence: 6
        )
        guard case let .accepted(sequence) = accepted else { return XCTFail("expected accepted") }

        let stale = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .idle),
            sourcePublicationSequence: 5
        )
        XCTAssertEqual(stale, .stale(currentSourcePublicationSequence: 6))

        let lease = try await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let state = await authority.targetState(for: lease)
        XCTAssertEqual(state?.snapshot.status, .running, "a late task cannot regress status")
        XCTAssertEqual(state?.changeSequence, sequence)
    }

    func testIdleSinceIsAuthorityStampedStableAndRestartsAfterLeavingIdle() async throws {
        let clock = LinkTestClock(Date(timeIntervalSince1970: 1000))
        let authority = makeAuthority(now: { clock.now })
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        _ = try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        let initialState = await authority.targetState(for: lease)
        let initial = try XCTUnwrap(initialState)
        XCTAssertEqual(initial.snapshot.idleSince, clock.now)
        let initialSequence = initial.changeSequence

        clock.now = Date(timeIntervalSince1970: 2000)
        let idleRefresh = makeSnapshot(sessionID: target.sessionID, displayName: "Renamed")
        guard case .accepted = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: idleRefresh,
            sourcePublicationSequence: 2
        ) else { return XCTFail("Expected idle metadata refresh") }
        let refreshedState = await authority.targetState(for: lease)
        let refreshed = try XCTUnwrap(refreshedState)
        XCTAssertEqual(refreshed.snapshot.idleSince, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(refreshed.changeSequence, initialSequence + 1)

        clock.now = Date(timeIntervalSince1970: 3000)
        _ = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .running),
            sourcePublicationSequence: 3
        )
        let runningState = await authority.targetState(for: lease)
        XCTAssertNil(runningState?.snapshot.idleSince)

        clock.now = Date(timeIntervalSince1970: 4000)
        _ = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID),
            sourcePublicationSequence: 4
        )
        let restartedIdleState = await authority.targetState(for: lease)
        XCTAssertEqual(restartedIdleState?.snapshot.idleSince, Date(timeIntervalSince1970: 4000))
    }

    func testSemanticReplayAdvancesPublicationHighWaterWithoutAdvancingChangeSequence() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        _ = try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let baselineState = await authority.targetState(for: lease)
        let baseline = try XCTUnwrap(baselineState)

        let replay = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID),
            sourcePublicationSequence: 2
        )
        XCTAssertEqual(replay, .unchanged(changeSequence: baseline.changeSequence))
        let replayedState = await authority.targetState(for: lease)
        XCTAssertEqual(replayedState?.changeSequence, baseline.changeSequence)
        let stale = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .running),
            sourcePublicationSequence: 2
        )
        XCTAssertEqual(stale, .stale(currentSourcePublicationSequence: 2))
    }

    func testPublicationFromAMismatchedEndpointIsRejected() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)

        let imposter = makeEndpoint(
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            tabID: UUID(),
            sessionID: target.sessionID
        )
        let disposition = await authority.publishTargetSnapshot(
            endpoint: imposter,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .running),
            sourcePublicationSequence: 99
        )
        XCTAssertEqual(disposition, .unknownTarget)
    }

    // MARK: - Wait

    func testWaitReturnsImmediatelyWhenChangeAlreadyAdvancedAndOnZeroTimeout() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target, status: .running)
        let waitLease = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let baseline = await authority.targetState(for: waitLease)
        let cursor = try XCTUnwrap(baseline?.waitCursor)

        _ = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .idle),
            sourcePublicationSequence: 2
        )
        let changed = await authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: waitLease, cursor: cursor)],
            until: .change,
            timeoutSeconds: 30
        )
        XCTAssertEqual(changed.outcome, .changed(sessionID: target.sessionID))
        XCTAssertEqual(changed.targets.count, 1)

        let successor = try XCTUnwrap(changed.targets.first?.waitCursor)
        let timedOut = await authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: waitLease, cursor: successor)],
            until: .change,
            timeoutSeconds: 0
        )
        XCTAssertEqual(timedOut.outcome, .timedOut)
        XCTAssertEqual(timedOut.targets.count, 1, "timeout is a disposition and still carries cursors")
    }

    func testWaitUntilIdleResolvesImmediatelyForAnAlreadyIdleTarget() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target, status: .idle)
        let lease = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let result = await authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: lease, cursor: nil)],
            until: .idle,
            timeoutSeconds: 30
        )
        XCTAssertEqual(result.outcome, .idle(sessionID: target.sessionID))
    }

    /// `until: idle` is satisfied by a target `send` will still refuse, which is what turns the
    /// documented "wait for idle, then send" recipe into a `send` -> `target_not_idle` -> `wait` loop.
    /// `until: sendable` is the predicate that actually matches the send precondition.
    func testWaitUntilSendableIgnoresAStatusIdleTargetThatIsNotSendReady() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target, status: .running)
        let lease = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        // Status-idle, no pending interaction, but not yet admissible for a send.
        _ = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .idle, idleForSend: false),
            sourcePublicationSequence: 2
        )
        let idleWait = await authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: lease, cursor: nil)],
            until: .idle,
            timeoutSeconds: 0
        )
        XCTAssertEqual(idleWait.outcome, .idle(sessionID: target.sessionID))

        let sendableWait = await authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: lease, cursor: nil)],
            until: .sendable,
            timeoutSeconds: 0
        )
        XCTAssertEqual(sendableWait.outcome, .timedOut, "send-readiness must not be implied by idle")

        _ = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .idle),
            sourcePublicationSequence: 3
        )
        let ready = await authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: lease, cursor: nil)],
            until: .sendable,
            timeoutSeconds: 0
        )
        XCTAssertEqual(ready.outcome, .idle(sessionID: target.sessionID))
    }

    func testParkedWaitWakesOnPublicationWithoutPolling() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target, status: .running)
        let lease = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        async let pending = authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: lease, cursor: nil)],
            until: .change,
            timeoutSeconds: 30
        )
        try await waitUntilParked(authority, count: 1)
        _ = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .idle),
            sourcePublicationSequence: 2
        )
        let result = await pending
        XCTAssertEqual(result.outcome, .changed(sessionID: target.sessionID))
        let parked = await authority.snapshot().parkedWaiterCount
        XCTAssertEqual(parked, 0)
    }

    func testRevocationWakesParkedWaitWithTerminalReason() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target, status: .running)
        let lease = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        async let pending = authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: lease, cursor: nil)],
            until: .change,
            timeoutSeconds: 30
        )
        try await waitUntilParked(authority, count: 1)
        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .tabClosed)
        let result = await pending
        guard case let .revoked(notice) = result.outcome else {
            return XCTFail("expected terminal revocation, got \(result.outcome)")
        }
        XCTAssertEqual(notice.reason, .tabClosed)
    }

    func testSecondWaitOnALinkGenerationIsRejectedAndReservesNoSlots() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let targetA = makeEndpoint(windowID: 2)
        let targetB = makeEndpoint(windowID: 3)
        try await activateLink(authority, observer: observer, target: targetA, status: .running)
        try await activateLink(authority, observer: observer, target: targetB, status: .running)
        let leaseA = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: targetA.sessionID
        ).get()
        let leaseB = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: targetB.sessionID
        ).get()

        async let pending = authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: leaseA, cursor: nil)],
            until: .change,
            timeoutSeconds: 30
        )
        try await waitUntilParked(authority, count: 1)

        let conflict = await authority.wait(
            requests: [
                DomainAgentSessionLinkWaitRequest(lease: leaseB, cursor: nil),
                DomainAgentSessionLinkWaitRequest(lease: leaseA, cursor: nil),
            ],
            until: .change,
            timeoutSeconds: 30
        )
        XCTAssertEqual(conflict.outcome, .waitAlreadyPending(conflictingSessionID: targetA.sessionID))
        XCTAssertTrue(conflict.targets.isEmpty)
        let parkedAfterConflict = await authority.snapshot().parkedWaiterCount
        XCTAssertEqual(
            parkedAfterConflict,
            1,
            "a rejected multi-target registration reserves no slot on any link"
        )

        // The free sibling link is still waitable, proving no partial reservation leaked.
        let siblingOnly = await authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: leaseB, cursor: nil)],
            until: .change,
            timeoutSeconds: 0
        )
        XCTAssertEqual(siblingOnly.outcome, .timedOut)

        _ = await authority.publishTargetSnapshot(
            endpoint: targetA,
            snapshot: makeSnapshot(sessionID: targetA.sessionID, status: .idle),
            sourcePublicationSequence: 2
        )
        _ = await pending
    }

    func testMultiTargetWaitRemovesAggregateRegistrationFromEverySibling() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let targetA = makeEndpoint(windowID: 2)
        let targetB = makeEndpoint(windowID: 3)
        try await activateLink(authority, observer: observer, target: targetA, status: .running)
        try await activateLink(authority, observer: observer, target: targetB, status: .running)
        let leaseA = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: targetA.sessionID
        ).get()
        let leaseB = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: targetB.sessionID
        ).get()

        async let pending = authority.wait(
            requests: [
                DomainAgentSessionLinkWaitRequest(lease: leaseA, cursor: nil),
                DomainAgentSessionLinkWaitRequest(lease: leaseB, cursor: nil),
            ],
            until: .change,
            timeoutSeconds: 30
        )
        try await waitUntilParked(authority, count: 1)
        _ = await authority.publishTargetSnapshot(
            endpoint: targetB,
            snapshot: makeSnapshot(sessionID: targetB.sessionID, status: .idle),
            sourcePublicationSequence: 2
        )
        let result = await pending
        XCTAssertEqual(result.outcome, .changed(sessionID: targetB.sessionID))
        XCTAssertEqual(result.targets.map(\.sessionID), [targetA.sessionID, targetB.sessionID])

        // Both slots must be free again; otherwise the sibling link would stay wedged.
        let reuse = await authority.wait(
            requests: [
                DomainAgentSessionLinkWaitRequest(lease: leaseA, cursor: nil),
                DomainAgentSessionLinkWaitRequest(lease: leaseB, cursor: nil),
            ],
            until: .change,
            timeoutSeconds: 0
        )
        XCTAssertEqual(reuse.outcome, .timedOut)
    }

    func testForgedOrStaleWaitCursorIsRejected() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        let forged = await authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: lease, cursor: "w_forged")],
            until: .change,
            timeoutSeconds: 5
        )
        XCTAssertEqual(forged.outcome, .cursorExpired(sessionID: target.sessionID))
        XCTAssertTrue(forged.targets.isEmpty)
    }

    func testWaitRejectsEmptyDuplicateAndOversizedFanOut() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        let empty = await authority.wait(requests: [], until: .change, timeoutSeconds: 5)
        XCTAssertEqual(empty.outcome, .invalidRequest)

        let duplicated = await authority.wait(
            requests: [
                DomainAgentSessionLinkWaitRequest(lease: lease, cursor: nil),
                DomainAgentSessionLinkWaitRequest(lease: lease, cursor: nil),
            ],
            until: .change,
            timeoutSeconds: 5
        )
        XCTAssertEqual(duplicated.outcome, .invalidRequest)

        let oversized = Array(
            repeating: DomainAgentSessionLinkWaitRequest(lease: lease, cursor: nil),
            count: DomainAgentSessionLinkAuthority.waitFanOutLimit + 1
        )
        let rejected = await authority.wait(requests: oversized, until: .change, timeoutSeconds: 5)
        XCTAssertEqual(rejected.outcome, .invalidRequest)
    }

    func testMultiTargetResponsesAlwaysCarryOneOrderedEntryPerAuthorizedTarget() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let targets = [makeEndpoint(windowID: 2), makeEndpoint(windowID: 3), makeEndpoint(windowID: 4)]
        var leases: [DomainAgentSessionLinkLease] = []
        for target in targets {
            try await activateLink(authority, observer: observer, target: target, status: .running)
            leases.append(try await authority.authorize(
                operation: .monitorWait,
                observerEndpoint: observer,
                targetSessionID: target.sessionID
            ).get())
        }
        // Deliberately not in link-creation order: the response must follow request order.
        let requestOrder = [leases[2], leases[0], leases[1]]
        let expectedOrder = [targets[2].sessionID, targets[0].sessionID, targets[1].sessionID]
        let requests = requestOrder.map { DomainAgentSessionLinkWaitRequest(lease: $0, cursor: nil) }

        let timedOut = await authority.wait(requests: requests, until: .change, timeoutSeconds: 0)
        XCTAssertEqual(timedOut.outcome, .timedOut)
        XCTAssertEqual(timedOut.targets.map(\.sessionID), expectedOrder)

        async let pending = authority.wait(requests: requests, until: .change, timeoutSeconds: 30)
        try await waitUntilParked(authority, count: 1)
        _ = await authority.publishTargetSnapshot(
            endpoint: targets[1],
            snapshot: makeSnapshot(sessionID: targets[1].sessionID, status: .idle),
            sourcePublicationSequence: 2
        )
        let woken = await pending
        XCTAssertEqual(woken.outcome, .changed(sessionID: targets[1].sessionID))
        XCTAssertEqual(
            woken.targets.map(\.sessionID),
            expectedOrder,
            "a wake must still carry a successor cursor for every authorized target"
        )
        XCTAssertEqual(Set(woken.targets.map(\.waitCursor)).count, expectedOrder.count)
    }

    func testSiblingRevocationDuringMultiTargetWaitYieldsATerminalDispositionNotPartialRows() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let targetA = makeEndpoint(windowID: 2)
        let targetB = makeEndpoint(windowID: 3)
        try await activateLink(authority, observer: observer, target: targetA, status: .running)
        let grantB = try await activateLink(authority, observer: observer, target: targetB, status: .running)
        let leaseA = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: targetA.sessionID
        ).get()
        let leaseB = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: targetB.sessionID
        ).get()

        async let pending = authority.wait(
            requests: [
                DomainAgentSessionLinkWaitRequest(lease: leaseA, cursor: nil),
                DomainAgentSessionLinkWaitRequest(lease: leaseB, cursor: nil),
            ],
            until: .change,
            timeoutSeconds: 30
        )
        try await waitUntilParked(authority, count: 1)
        _ = await authority.revoke(linkID: grantB.id, generation: grantB.generation, reason: .tabClosed)

        let result = await pending
        guard case let .revoked(notice) = result.outcome else {
            return XCTFail("expected an explicit terminal disposition, got \(result.outcome)")
        }
        XCTAssertEqual(notice.targetSessionID, targetB.sessionID)
        XCTAssertTrue(
            result.targets.isEmpty,
            "a terminal disposition must not ship a partial successor set that silently drops a target"
        )

        // The surviving sibling link is still fully usable, proving no slot or row leaked.
        let survivor = await authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: leaseA, cursor: nil)],
            until: .change,
            timeoutSeconds: 0
        )
        XCTAssertEqual(survivor.outcome, .timedOut)
        XCTAssertEqual(survivor.targets.map(\.sessionID), [targetA.sessionID])
    }

    // MARK: - Timeout conversion

    func testTimeoutConversionSaturatesBelowUInt64MaxInsteadOfTrapping() {
        // `Double(UInt64.max)` rounds up to exactly 2^64, so clamping seconds against it and then
        // multiplying yields a Double that traps on conversion. These inputs all reach that path.
        XCTAssertEqual(DomainAgentSessionLinkAuthority.timeoutNanoseconds(.infinity), 0)
        XCTAssertEqual(DomainAgentSessionLinkAuthority.timeoutNanoseconds(.nan), 0)
        XCTAssertEqual(DomainAgentSessionLinkAuthority.timeoutNanoseconds(0), 0)
        XCTAssertEqual(DomainAgentSessionLinkAuthority.timeoutNanoseconds(-5), 0)
        XCTAssertEqual(
            DomainAgentSessionLinkAuthority.timeoutNanoseconds(.greatestFiniteMagnitude),
            UInt64.max
        )
        XCTAssertEqual(DomainAgentSessionLinkAuthority.timeoutNanoseconds(Double(UInt64.max)), UInt64.max)
        XCTAssertEqual(DomainAgentSessionLinkAuthority.timeoutNanoseconds(1e300), UInt64.max)
        XCTAssertEqual(DomainAgentSessionLinkAuthority.timeoutNanoseconds(1), 1_000_000_000)
        XCTAssertEqual(DomainAgentSessionLinkAuthority.timeoutNanoseconds(0.0000000001), 1)
    }

    func testWaitWithAnAbsurdTimeoutParksInsteadOfTrapping() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target, status: .running)
        let lease = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        async let pending = authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: lease, cursor: nil)],
            until: .change,
            timeoutSeconds: .greatestFiniteMagnitude
        )
        try await waitUntilParked(authority, count: 1)
        _ = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .idle),
            sourcePublicationSequence: 2
        )
        let result = await pending
        XCTAssertEqual(result.outcome, .changed(sessionID: target.sessionID))
    }

    // MARK: - Read cursors

    func testReadCursorRoundTripEvictionAndCapabilityFencing() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)
        let readLease = try await authority.authorize(
            operation: .monitorRead,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        let anchor = DomainAgentSessionLinkReadAnchor(
            itemID: "row-1",
            sequenceIndex: 4,
            sourceItemsRevision: 12
        )
        let first = try await authority.openReadCursor(lease: readLease, anchor: anchor, direction: .tail).get()
        guard case let .resolved(resolved) = await authority.resolveReadCursor(
            lease: readLease,
            opaqueCursor: first.handle
        ) else {
            return XCTFail("expected resolved cursor")
        }
        XCTAssertEqual(resolved.anchor, anchor)
        XCTAssertEqual(resolved.direction, .tail)

        let pollLease = try await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let pollLeaseDisposition = await authority.resolveReadCursor(
            lease: pollLease,
            opaqueCursor: first.handle
        )
        XCTAssertEqual(pollLeaseDisposition, .expired, "a poll lease never resolves a read cursor")

        for index in 0 ..< DomainAgentSessionLinkAuthority.readCursorsPerLinkLimit {
            _ = try await authority.openReadCursor(
                lease: readLease,
                anchor: DomainAgentSessionLinkReadAnchor(
                    itemID: "row-\(index)",
                    sequenceIndex: index,
                    sourceItemsRevision: nil
                ),
                direction: .start
            ).get()
        }
        let evictedDisposition = await authority.resolveReadCursor(
            lease: readLease,
            opaqueCursor: first.handle
        )
        XCTAssertEqual(
            evictedDisposition,
            .expired,
            "the oldest cursor is LRU-evicted and reports cursor_expired"
        )
    }

    // MARK: - Send reservations

    func testSendIdempotencyDuplicateConflictAndInProgressSemantics() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorSend,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        let first = await authority.beginSend(lease: lease, idempotencyKey: "k1", messageDigest: "d1")
        guard case let .reserved(reservation) = first else { return XCTFail("expected reservation") }

        let sameDigest = await authority.beginSend(
            lease: lease,
            idempotencyKey: "k1",
            messageDigest: "d1"
        )
        XCTAssertEqual(sameDigest, .inProgress)
        let differentDigest = await authority.beginSend(
            lease: lease,
            idempotencyKey: "k1",
            messageDigest: "d2"
        )
        XCTAssertEqual(
            differentDigest,
            .conflict,
            "the same key with a different digest never replays or delivers either payload"
        )

        let commit = await authority.commitSendAuthorization(
            reservation: reservation,
            linkGeneration: reservation.linkGeneration
        )
        XCTAssertEqual(commit, .committed)
        let receipt = DomainAgentSessionLinkSendReceipt(
            targetSessionID: target.sessionID,
            targetItemID: "item-1",
            acceptedAt: Date(timeIntervalSince1970: 42),
            deliveryState: .runStarted,
            resultingRunState: "running"
        )
        await authority.completeSend(reservation: reservation, receipt: receipt)

        let replay = await authority.beginSend(lease: lease, idempotencyKey: "k1", messageDigest: "d1")
        guard case let .duplicate(stored) = replay else { return XCTFail("expected duplicate receipt") }
        XCTAssertTrue(stored.duplicate)
        XCTAssertEqual(stored.targetItemID, "item-1")
        XCTAssertEqual(stored.deliveryState, .runStarted)

        // A new key permits an intentional repeat of the same message.
        let repeated = await authority.beginSend(lease: lease, idempotencyKey: "k2", messageDigest: "d1")
        guard case .reserved = repeated else { return XCTFail("expected a fresh reservation") }
    }

    /// Queued admission has to learn what the ledger already holds for a key *before* it resolves a
    /// workflow, and without reserving: a reservation held for a message that will not be delivered
    /// until the target next becomes sendable would occupy the in-flight ceiling for that whole time.
    func testSendLedgerProbeReportsStoredOutcomesWithoutReservingASlot() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorSend,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        let unused = await authority.probeSend(lease: lease, idempotencyKey: "k1", messageDigest: "d1")
        XCTAssertEqual(unused, .unused)
        let idleSnapshot = await authority.snapshot()
        XCTAssertEqual(
            idleSnapshot.inFlightSendCount,
            0,
            "probing must not reserve; a queued message can wait for hours"
        )

        guard case let .reserved(reservation) = await authority.beginSend(
            lease: lease,
            idempotencyKey: "k1",
            messageDigest: "d1"
        ) else { return XCTFail("expected reservation") }
        let inProgress = await authority.probeSend(
            lease: lease,
            idempotencyKey: "k1",
            messageDigest: "d1"
        )
        XCTAssertEqual(inProgress, .inProgress)
        let conflict = await authority.probeSend(
            lease: lease,
            idempotencyKey: "k1",
            messageDigest: "d2"
        )
        XCTAssertEqual(conflict, .conflict)

        _ = await authority.commitSendAuthorization(
            reservation: reservation,
            linkGeneration: reservation.linkGeneration
        )
        let receipt = DomainAgentSessionLinkSendReceipt(
            targetSessionID: target.sessionID,
            targetItemID: "item-1",
            acceptedAt: Date(timeIntervalSince1970: 42),
            deliveryState: .runStarted,
            resultingRunState: "running"
        )
        await authority.completeSend(reservation: reservation, receipt: receipt)

        guard case let .duplicate(stored) = await authority.probeSend(
            lease: lease,
            idempotencyKey: "k1",
            messageDigest: "d1"
        ) else { return XCTFail("expected the stored receipt") }
        XCTAssertTrue(stored.duplicate)
        XCTAssertEqual(stored.targetItemID, "item-1")
        let settledSnapshot = await authority.snapshot()
        XCTAssertEqual(
            settledSnapshot.inFlightSendCount,
            0,
            "no probe on any path may leave a slot behind"
        )
    }

    /// An indeterminate tombstone must never read as an undelivered retry, on the probe exactly as on
    /// `beginSend`: the row may be on disk, so re-queuing the key could duplicate it.
    func testSendLedgerProbeReportsAnIndeterminateTombstoneRatherThanADuplicate() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorSend,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        guard case let .reserved(reservation) = await authority.beginSend(
            lease: lease,
            idempotencyKey: "k1",
            messageDigest: "d1"
        ) else { return XCTFail("expected reservation") }
        _ = await authority.commitSendAuthorization(
            reservation: reservation,
            linkGeneration: reservation.linkGeneration
        )
        await authority.settleIndeterminateSend(reservation: reservation)

        let probe = await authority.probeSend(lease: lease, idempotencyKey: "k1", messageDigest: "d1")
        XCTAssertEqual(probe, .indeterminate)
    }

    func testManualRevocationRaceAroundTheSendCommitFence() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorSend,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        // Revoke-before-commit: the reservation is cancelled and nothing may mutate the target.
        let losing = await authority.beginSend(lease: lease, idempotencyKey: "loser", messageDigest: "d")
        guard case let .reserved(losingReservation) = losing else { return XCTFail("expected reservation") }
        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .userRequested)
        let losingCommit = await authority.commitSendAuthorization(
            reservation: losingReservation,
            linkGeneration: losingReservation.linkGeneration
        )
        XCTAssertEqual(losingCommit, .linkRevoked)

        // Commit-before-revoke: the already-authorized send still settles exactly once.
        let second = try await activateLink(authority, observer: observer, target: target)
        let secondLease = try await authority.authorize(
            operation: .monitorSend,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let winning = await authority.beginSend(lease: secondLease, idempotencyKey: "winner", messageDigest: "d")
        guard case let .reserved(winningReservation) = winning else { return XCTFail("expected reservation") }
        let winningCommit = await authority.commitSendAuthorization(
            reservation: winningReservation,
            linkGeneration: winningReservation.linkGeneration
        )
        XCTAssertEqual(winningCommit, .committed)
        _ = await authority.revoke(linkID: second.id, generation: second.generation, reason: .userRequested)
        await authority.completeSend(
            reservation: winningReservation,
            receipt: DomainAgentSessionLinkSendReceipt(
                targetSessionID: target.sessionID,
                targetItemID: "item-2",
                acceptedAt: Date(timeIntervalSince1970: 43),
                deliveryState: .persisted,
                resultingRunState: "idle"
            )
        )
        let snapshot = await authority.snapshot()
        XCTAssertEqual(snapshot.inFlightSendCount, 0)
        XCTAssertEqual(
            snapshot.retainedSendOutcomeCount,
            0,
            "revocation releases the dead generation's ledger entries"
        )
    }

    func testDeliveryLedgerRejectsOverflowInsteadOfEvictingInFlightWork() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorSend,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        var reservations: [DomainAgentSessionLinkSendReservation] = []
        for index in 0 ..< DomainAgentSessionLinkAuthority.inFlightSendLimit {
            let disposition = await authority.beginSend(
                lease: lease,
                idempotencyKey: "key-\(index)",
                messageDigest: "digest-\(index)"
            )
            guard case let .reserved(reservation) = disposition else {
                return XCTFail("expected reservation \(index)")
            }
            reservations.append(reservation)
        }
        let overflow = await authority.beginSend(
            lease: lease,
            idempotencyKey: "overflow",
            messageDigest: "d"
        )
        XCTAssertEqual(overflow, .inFlightLimitReached)
        let inFlight = await authority.snapshot().inFlightSendCount
        XCTAssertEqual(inFlight, DomainAgentSessionLinkAuthority.inFlightSendLimit)

        // Abandoning a failed attempt frees the slot without retaining a phantom receipt.
        await authority.abandonSend(reservation: reservations[0])
        let retry = await authority.beginSend(lease: lease, idempotencyKey: "key-0", messageDigest: "digest-0")
        guard case .reserved = retry else { return XCTFail("expected the freed slot to be reusable") }
    }

    // MARK: - Two-phase shutdown

    func testBeginDrainResumesParkedWaitsAndRejectsNewWorkBeforeHostDrain() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target, status: .running)
        let lease = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()

        async let pending = authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: lease, cursor: nil)],
            until: .change,
            timeoutSeconds: 60
        )
        try await waitUntilParked(authority, count: 1)
        await authority.beginDrain()
        let result = await pending
        XCTAssertEqual(result.outcome, .shuttingDown)

        let rejected = await authority.reserveLink(observer: makeEndpoint(windowID: 7), target: target)
        XCTAssertEqual(rejected, .rejected(.shuttingDown))
        let denied = await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        )
        XCTAssertEqual(denied.failureError, .runtimeShuttingDown)

        // The link survives phase one so an in-flight invocation can still settle.
        let survivingLinks = await authority.snapshot().activeLinkCount
        XCTAssertEqual(survivingLinks, 1)
    }

    func testFinishShutdownClearsStateAndAdvancesRuntimeGeneration() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorRead,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let beforeGeneration = await authority.runtimeGeneration

        await authority.beginDrain()
        await authority.finishShutdown()

        let snapshot = await authority.snapshot()
        XCTAssertTrue(snapshot.isShutDown)
        XCTAssertEqual(snapshot.activeLinkCount, 0)
        XCTAssertEqual(snapshot.observedTargetCount, 0)
        XCTAssertEqual(snapshot.parkedWaiterCount, 0)
        XCTAssertEqual(snapshot.readCursorCount, 0)
        XCTAssertGreaterThan(snapshot.runtimeGeneration, beforeGeneration)
        let leaseError = await authority.validate(lease: lease)
        XCTAssertEqual(leaseError, .runtimeShuttingDown)
        await authority.finishShutdown()
        let generationAfterRepeat = await authority.snapshot().runtimeGeneration
        XCTAssertEqual(generationAfterRepeat, snapshot.runtimeGeneration)
    }

    func testChangeFeedCarriesIdentityAndRevisionsOnly() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        let target = makeEndpoint(windowID: 2)
        var iterator = await authority.changeEvents().makeAsyncIterator()

        let grant = try await activateLink(authority, observer: observer, target: target)
        let activated = await iterator.next()
        XCTAssertEqual(activated?.kind, .activated)
        XCTAssertEqual(activated?.linkID, grant.id)
        XCTAssertEqual(activated?.observerSessionID, observer.sessionID)
        XCTAssertEqual(activated?.observerLinkSetRevision, 1)

        _ = await authority.publishTargetSnapshot(
            endpoint: target,
            snapshot: makeSnapshot(sessionID: target.sessionID, status: .running),
            sourcePublicationSequence: 2
        )
        let statusChange = await iterator.next()
        XCTAssertEqual(statusChange?.kind, .targetStateChanged)
        XCTAssertNil(
            statusChange?.observerLinkSetRevision,
            "status refreshes must never advance the observer link-set revision"
        )
        let linkSetRevision = await authority.observerLinkSetRevision(observer.sessionID)
        XCTAssertEqual(
            linkSetRevision,
            1,
            "only membership changes bump the prompt-injection revision"
        )

        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .userRequested)
        let revoked = await iterator.next()
        XCTAssertEqual(revoked?.kind, .revoked)
        XCTAssertEqual(revoked?.observerLinkSetRevision, 2)
    }

    func testRecentRevocationNoticesAreBoundedPerEndpoint() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        for index in 0 ..< (DomainAgentSessionLinkAuthority.recentRevocationNoticesPerEndpoint + 3) {
            let target = makeEndpoint(windowID: 100 + index)
            let grant = try await activateLink(authority, observer: observer, target: target)
            _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .tabClosed)
        }
        let notices = await authority.recentRevocationNotices(forEndpoint: observer)
        XCTAssertEqual(notices.count, DomainAgentSessionLinkAuthority.recentRevocationNoticesPerEndpoint)
    }

    /// Notices belong to the incarnation that held the grant, not to its session UUID.
    ///
    /// A second live incarnation of one session UUID was granted nothing, so handing it the granted
    /// incarnation's endings would leak that a link it never had existed at all.
    func testRecentRevocationNoticesAreScopedToTheExactIncarnation() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint()
        // Same session UUID, different live window: the duplicate incarnation the resolver refuses.
        let duplicate = DomainAgentSessionLinkEndpointIdentity(
            windowID: observer.windowID + 1,
            workspaceID: observer.workspaceID,
            tabID: UUID(),
            sessionID: observer.sessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: observer.bindingTransitionGeneration
        )
        let target = makeEndpoint(windowID: 900)
        let grant = try await activateLink(authority, observer: observer, target: target)
        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .tabClosed)

        let granted = await authority.recentRevocationNotices(forEndpoint: observer)
        let ungranted = await authority.recentRevocationNotices(forEndpoint: duplicate)
        XCTAssertEqual(granted.count, 1, "the granted incarnation keeps its own ending")
        XCTAssertTrue(ungranted.isEmpty, "a duplicate incarnation was granted nothing and learns nothing")

        // The target end is likewise addressed by incarnation, and dismissal is too.
        let targetNotices = await authority.recentRevocationNotices(forEndpoint: target)
        XCTAssertEqual(targetNotices.count, 1)
        await authority.clearRecentRevocationNotices(forEndpoint: observer)
        let dismissed = await authority.recentRevocationNotices(forEndpoint: observer)
        let survivingPeerNotices = await authority.recentRevocationNotices(forEndpoint: target)
        XCTAssertTrue(dismissed.isEmpty)
        XCTAssertEqual(
            survivingPeerNotices.count,
            1,
            "dismissing one endpoint's notices must not clear the peer's"
        )
    }

    /// Endpoint-keyed notices must not grow a bucket per dead incarnation forever.
    func testRecentRevocationNoticeEndpointsAreBounded() async throws {
        let authority = makeAuthority()
        let limit = DomainAgentSessionLinkAuthority.recentRevocationNoticeEndpointLimit
        var observers: [DomainAgentSessionLinkEndpointIdentity] = []
        // Each link contributes two endpoint buckets, so this comfortably exceeds the bound.
        for index in 0 ..< limit {
            let observer = makeEndpoint(windowID: 1000 + index)
            let target = makeEndpoint(windowID: 5000 + index)
            observers.append(observer)
            let grant = try await activateLink(authority, observer: observer, target: target)
            _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .tabClosed)
        }
        let oldest = try XCTUnwrap(observers.first)
        let newest = try XCTUnwrap(observers.last)
        let oldestNotices = await authority.recentRevocationNotices(forEndpoint: oldest)
        let newestNotices = await authority.recentRevocationNotices(forEndpoint: newest)
        XCTAssertTrue(
            oldestNotices.isEmpty,
            "the oldest-written endpoint bucket is evicted once the bound is exceeded"
        )
        XCTAssertEqual(
            newestNotices.count,
            1,
            "the most recent endings survive eviction"
        )
    }

    // MARK: - Agent-facing value budgets

    func testAgentFacingTextIsNormalizedAndByteBounded() throws {
        let long = String(repeating: "é", count: 400)
        let snapshot = DomainAgentSessionObservationSnapshot(
            sessionID: UUID(),
            displayName: "Build\n\tAPI   session \(long)",
            providerDisplayName: "Codex",
            status: .running,
            idleForSend: true,
            pendingInteractionKind: nil,
            latestVisibleAssistantPreview: long,
            visibleRowCount: -4,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        let name = try XCTUnwrap(snapshot.displayName)
        XCTAssertLessThanOrEqual(name.utf8.count, DomainAgentSessionLinkTextBudget.displayNameMaxBytes)
        XCTAssertFalse(name.contains("\n"))
        XCTAssertFalse(name.contains("  "))
        XCTAssertLessThanOrEqual(
            snapshot.latestVisibleAssistantPreview?.utf8.count ?? .max,
            DomainAgentSessionLinkTextBudget.assistantPreviewMaxBytes
        )
        XCTAssertEqual(snapshot.visibleRowCount, 0)
        XCTAssertFalse(snapshot.idleForSend, "a running target can never be admitted for send")

        let waitingOn = try XCTUnwrap(DomainAgentSessionWaitingOn(
            summary: "  dependency\n" + String(repeating: "é", count: 300),
            declaredAt: Date(timeIntervalSince1970: 42)
        ))
        XCTAssertLessThanOrEqual(
            waitingOn.summary.utf8.count,
            DomainAgentSessionLinkTextBudget.waitingOnSummaryMaxBytes
        )
        XCTAssertFalse(waitingOn.summary.contains("\n"))
        XCTAssertEqual(waitingOn.declaredAt, Date(timeIntervalSince1970: 42))
        XCTAssertNil(DomainAgentSessionWaitingOn(summary: " \n ", declaredAt: Date()))
    }

    func testPendingInteractionForcesNonIdleSendAdmission() {
        let snapshot = DomainAgentSessionObservationSnapshot(
            sessionID: UUID(),
            displayName: "Planning",
            providerDisplayName: nil,
            status: .idle,
            idleForSend: true,
            pendingInteractionKind: .approval,
            latestVisibleAssistantPreview: nil,
            visibleRowCount: 1,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(snapshot.hasPendingInteraction)
        XCTAssertFalse(snapshot.idleForSend)
    }
}

private final class LinkTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private extension Result where Failure == DomainAgentSessionLinkError {
    var failureError: DomainAgentSessionLinkError? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}

private extension Result
    where Failure == DomainAgentSessionLinkAuthority.RequestAttentionAuthorizationError
{
    var requestAttentionFailure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
