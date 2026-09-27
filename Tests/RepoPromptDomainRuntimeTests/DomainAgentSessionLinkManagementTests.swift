import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// The user's management delegation as an authority-owned grant capability.
///
/// Management is the one capability that changes on a live grant, so these tests pin what that
/// change may and may not do: it starts off, it moves only the exact generation it names, it is
/// visible to the observer through the link-set revision and the change feed, and withdrawing it
/// takes effect at the very next fence of an operation already in flight.
final class DomainAgentSessionLinkManagementTests: XCTestCase {
    private enum FixtureError: Error {
        case reservationFailed
        case activationFailed
    }

    // MARK: - Fixtures

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
        target: DomainAgentSessionLinkEndpointIdentity
    ) async throws -> DomainAgentSessionLinkGrant {
        guard case let .reserved(pending, _) = await authority.reserveLink(observer: observer, target: target)
        else { throw FixtureError.reservationFailed }
        let activation = await authority.activateLink(
            reservation: pending,
            initialSnapshot: DomainAgentSessionObservationSnapshot(
                sessionID: target.sessionID,
                displayName: "Target",
                providerDisplayName: "Codex CLI",
                status: .running,
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

    private func reference(_ grant: DomainAgentSessionLinkGrant) -> DomainAgentSessionLinkReference {
        DomainAgentSessionLinkReference(linkID: grant.id, generation: grant.generation)
    }

    private static let managementOperations: [DomainAgentSessionTargetOperation] = [
        .monitorGetInteraction, .monitorRespond, .monitorSteer
    ]

    // MARK: - Default

    func testGrantsStartWatchOnlyAndManagementOperationsNeedTheManageCapability() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)

        XCTAssertEqual(grant.capabilities, DomainAgentSessionLinkCapability.version1)
        XCTAssertFalse(grant.capabilities.contains(.manage))
        for operation in Self.managementOperations {
            let lease = await authority.authorize(
                operation: operation,
                observerEndpoint: observer,
                targetSessionID: target.sessionID
            )
            XCTAssertEqual(lease.failureError, .capabilityDenied, operation.rawValue)
        }
        let watch = await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        )
        XCTAssertNotNil(try? watch.get(), "the watch grant itself is untouched")
        let inventory = await authority.links(forObserverEndpoint: observer)
        XCTAssertEqual(inventory.items.first?.capabilityNames, ["poll", "read", "send_when_idle", "wait"])
    }

    // MARK: - Grant and withdraw

    func testSetManagementChangesOnlyTheExactGrantAndIsVisibleToTheObserver() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let otherTarget = makeEndpoint(windowID: 3)
        var events = await authority.changeEvents().makeAsyncIterator()
        let grant = try await activateLink(authority, observer: observer, target: target)
        _ = await events.next()
        let other = try await activateLink(authority, observer: observer, target: otherTarget)
        _ = await events.next()
        let revisionBefore = await authority.observerLinkSetRevision(observer.sessionID)
        let targetRevisionBefore = await authority.targetLinkSetRevision(target.sessionID)

        let granted = await authority.setManagement(
            true,
            reference: reference(grant),
            observer: observer,
            target: target
        )
        guard case let .changed(managedGrant, observerInventory) = granted else {
            return XCTFail("expected a capability change, got \(granted)")
        }
        XCTAssertEqual(managedGrant.id, grant.id)
        XCTAssertEqual(managedGrant.generation, grant.generation, "the link keeps its identity")
        XCTAssertEqual(managedGrant.capabilities, DomainAgentSessionLinkCapability.managed)
        let managedItem = observerInventory.items.first { $0.targetSessionID == target.sessionID }
        let otherItem = observerInventory.items.first { $0.targetSessionID == otherTarget.sessionID }
        XCTAssertEqual(managedItem?.capabilityNames, ["manage", "poll", "read", "send_when_idle", "wait"])
        XCTAssertEqual(otherItem?.capabilities, DomainAgentSessionLinkCapability.version1, "only the named grant")
        XCTAssertEqual(
            observerInventory.linkSetRevision,
            revisionBefore + 1,
            "the observer must be re-told its capabilities, so its link-set revision advances"
        )
        let targetRevisionAfter = await authority.targetLinkSetRevision(target.sessionID)
        XCTAssertEqual(targetRevisionAfter, targetRevisionBefore, "the inbound grant set did not change")

        let event = await events.next()
        XCTAssertEqual(event?.kind, .capabilitiesChanged)
        XCTAssertEqual(event?.linkID, grant.id)
        XCTAssertEqual(event?.observerSessionID, observer.sessionID)
        XCTAssertEqual(event?.targetSessionID, target.sessionID)
        XCTAssertEqual(event?.observerLinkSetRevision, revisionBefore + 1)

        let steer = await authority.authorize(
            operation: .monitorSteer,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        )
        XCTAssertEqual(try steer.get().capability, .manage)
        let otherSteer = await authority.authorize(
            operation: .monitorSteer,
            observerEndpoint: observer,
            targetSessionID: otherTarget.sessionID
        )
        XCTAssertEqual(otherSteer.failureError, .capabilityDenied)

        let repeated = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)
        guard case .unchanged = repeated else { return XCTFail("expected unchanged, got \(repeated)") }
        let revisionAfterRepeat = await authority.observerLinkSetRevision(observer.sessionID)
        XCTAssertEqual(revisionAfterRepeat, revisionBefore + 1, "a no-op re-owes nothing")

        // Exact addressing: the wrong endpoints or a foreign reference change nothing.
        let wrongTarget = await authority.setManagement(true, reference: reference(other), observer: observer, target: target)
        XCTAssertEqual(wrongTarget, .notFound)
        let wrongObserver = await authority.setManagement(
            false,
            reference: reference(grant),
            observer: makeEndpoint(windowID: 9),
            target: target
        )
        XCTAssertEqual(wrongObserver, .notFound)

        let withdrawn = await authority.setManagement(false, reference: reference(grant), observer: observer, target: target)
        guard case let .changed(watchGrant, _) = withdrawn else { return XCTFail("expected a change, got \(withdrawn)") }
        XCTAssertEqual(watchGrant.capabilities, DomainAgentSessionLinkCapability.version1)
    }

    func testWithdrawingManagementFailsOutstandingLeasesAndTheManagedCommitFence() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)
        _ = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)

        let respondLease = try await authority.authorize(
            operation: .monitorRespond,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let steerLease = try await authority.authorize(
            operation: .monitorSteer,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let pollLease = try await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let respondValid = await authority.validate(lease: respondLease)
        XCTAssertNil(respondValid)

        // A steer reserves in the shared ledger under its management lease.
        guard case let .reserved(reservation) = await authority.beginSend(
            lease: steerLease,
            idempotencyKey: "steer-1",
            messageDigest: "digest"
        ) else { return XCTFail("a management lease may reserve in the ledger") }

        // The user withdraws management while both operations are in flight.
        _ = await authority.setManagement(false, reference: reference(grant), observer: observer, target: target)

        let respondAfter = await authority.validate(lease: respondLease)
        XCTAssertEqual(respondAfter, .capabilityDenied, "the final fence of an in-flight respond now fails")
        let pollAfter = await authority.validate(lease: pollLease)
        XCTAssertNil(pollAfter, "watching is unaffected")
        let commit = await authority.commitSendAuthorization(
            reservation: reservation,
            linkGeneration: reservation.linkGeneration,
            requiresManagement: true
        )
        XCTAssertEqual(commit, .managementRevoked, "a withdrawn delegation delivers nothing")
        let snapshot = await authority.snapshot()
        XCTAssertEqual(snapshot.inFlightSendCount, 0, "the refused reservation is released")

        // Re-granting lets the same key proceed: nothing was delivered under it.
        _ = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)
        let freshLease = try await authority.authorize(
            operation: .monitorSteer,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let retried = await authority.beginSend(lease: freshLease, idempotencyKey: "steer-1", messageDigest: "digest")
        guard case .reserved = retried else { return XCTFail("expected a fresh reservation, got \(retried)") }

        // An ordinary send commit never consults management.
        let sendLease = try await authority.authorize(
            operation: .monitorSend,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        _ = await authority.setManagement(false, reference: reference(grant), observer: observer, target: target)
        guard case let .reserved(sendReservation) = await authority.beginSend(
            lease: sendLease,
            idempotencyKey: "send-1",
            messageDigest: "digest"
        ) else { return XCTFail("expected a send reservation") }
        let sendCommit = await authority.commitSendAuthorization(
            reservation: sendReservation,
            linkGeneration: sendReservation.linkGeneration
        )
        XCTAssertEqual(sendCommit, .committed)
    }

    func testRelinkNeverInheritsManagementAndShutdownRefusesChanges() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)
        _ = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)
        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .userRequested)

        let relinked = try await activateLink(authority, observer: observer, target: target)
        XCTAssertNotEqual(reference(relinked), reference(grant))
        XCTAssertEqual(relinked.capabilities, DomainAgentSessionLinkCapability.version1, "a relink is watch-only")
        let stale = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)
        XCTAssertEqual(stale, .notFound, "a revoked generation can never be managed again")

        await authority.beginDrain()
        let draining = await authority.setManagement(true, reference: reference(relinked), observer: observer, target: target)
        XCTAssertEqual(draining, .shuttingDown)
    }

    // MARK: - Mid-session capability notices

    private func waitUntilParked(_ authority: DomainAgentSessionLinkAuthority, count: Int) async throws {
        for _ in 0 ..< 400 {
            if await authority.snapshot().parkedWaiterCount >= count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Waiter never parked")
    }

    /// A running overseer blocked in `wait` must learn of a Manage change now, not at its next turn:
    /// the change ends every wait that exact observer endpoint has parked — even one on another
    /// target — and records one notice for it alone.
    func testManagementChangeWakesTheObserversParkedWaitAndOwesItExactlyOneNotice() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let unrelatedObserver = makeEndpoint(windowID: 4)
        let target = makeEndpoint(windowID: 2)
        let otherTarget = makeEndpoint(windowID: 3)
        let grant = try await activateLink(authority, observer: observer, target: target)
        _ = try await activateLink(authority, observer: observer, target: otherTarget)
        _ = try await activateLink(authority, observer: unrelatedObserver, target: target)

        // The observer waits on the *other* target; an unrelated observer waits on the same target.
        let waitLease = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: observer,
            targetSessionID: otherTarget.sessionID
        ).get()
        let baseline = await authority.targetState(for: waitLease)
        let cursor = try XCTUnwrap(baseline?.waitCursor)
        let unrelatedLease = try await authority.authorize(
            operation: .monitorWait,
            observerEndpoint: unrelatedObserver,
            targetSessionID: target.sessionID
        ).get()
        let unrelatedBaseline = await authority.targetState(for: unrelatedLease)
        let unrelatedCursor = try XCTUnwrap(unrelatedBaseline?.waitCursor)
        let parked = Task {
            await authority.wait(
                requests: [DomainAgentSessionLinkWaitRequest(lease: waitLease, cursor: cursor)],
                until: .change,
                timeoutSeconds: 30
            )
        }
        let unrelated = Task {
            await authority.wait(
                requests: [DomainAgentSessionLinkWaitRequest(lease: unrelatedLease, cursor: unrelatedCursor)],
                until: .change,
                timeoutSeconds: 30
            )
        }
        try await waitUntilParked(authority, count: 2)

        _ = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)
        let revision = await authority.observerLinkSetRevision(observer.sessionID)

        let woken = await parked.value
        XCTAssertEqual(woken.outcome, .capabilitiesChanged(sessionID: target.sessionID))
        let successor = try XCTUnwrap(woken.targets.first?.waitCursor)
        let again = await authority.wait(
            requests: [DomainAgentSessionLinkWaitRequest(lease: waitLease, cursor: successor)],
            until: .change,
            timeoutSeconds: 0
        )
        XCTAssertEqual(again.outcome, .timedOut, "the capability wake consumed no target change")
        let stillParked = await authority.snapshot().parkedWaiterCount
        XCTAssertEqual(stillParked, 1, "another observer's wait on the same target is not woken")

        let unrelatedNotices = await authority.pendingCapabilityNotices(for: unrelatedObserver)
        XCTAssertTrue(unrelatedNotices.isEmpty, "a notice never reaches another observer")
        // The woken wait claimed the notice in the same actor turn that woke it, so no other channel
        // can take it first and leave the wake without the notice it was for.
        let owed = woken.capabilityNotices
        XCTAssertEqual(owed.count, 1)
        XCTAssertEqual(owed.first?.targetSessionID, target.sessionID)
        XCTAssertEqual(owed.first?.linkGeneration, grant.generation)
        XCTAssertEqual(owed.first?.managed, true)
        XCTAssertEqual(owed.first?.observerLinkSetRevision, revision)
        let leftOver = await authority.takeCapabilityNotices(for: observer)
        XCTAssertTrue(leftOver.isEmpty, "claimed at most once")

        // With no wait parked, the notice stays owed until one channel claims it.
        _ = await authority.setManagement(false, reference: reference(grant), observer: observer, target: target)
        let taken = await authority.takeCapabilityNotices(for: observer)
        XCTAssertEqual(taken.map(\.managed), [false])
        let takenAgain = await authority.takeCapabilityNotices(for: observer)
        XCTAssertTrue(takenAgain.isEmpty, "claimed at most once")

        // A no-op change owes nothing.
        _ = await authority.setManagement(false, reference: reference(grant), observer: observer, target: target)
        let afterNoOp = await authority.pendingCapabilityNotices(for: observer)
        XCTAssertTrue(afterNoOp.isEmpty)
        unrelated.cancel()
        _ = await unrelated.value
    }

    /// Only the newest change per link is owed, a failed push never overwrites a newer change, an
    /// accepted inventory at the change's revision settles it, and revocation drops it.
    func testNoticesKeepTheNewestChangeSettleByRevisionAndDieWithTheLink() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)

        _ = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)
        let granted = await authority.takeCapabilityNotices(for: observer)
        XCTAssertEqual(granted.map(\.managed), [true])
        let grantedIsCurrent = await authority.capabilityNoticesAreCurrent(granted, for: observer)
        XCTAssertTrue(grantedIsCurrent)

        // Withdrawn while the "granted" push was in flight.
        _ = await authority.setManagement(false, reference: reference(grant), observer: observer, target: target)
        let staleIsCurrent = await authority.capabilityNoticesAreCurrent(granted, for: observer)
        XCTAssertFalse(staleIsCurrent, "a push must not tell the model about authority that moved")
        await authority.restoreCapabilityNotices(granted, for: observer)
        let owed = await authority.pendingCapabilityNotices(for: observer)
        XCTAssertEqual(owed.map(\.managed), [false], "the newer withdrawal wins over a restored grant")
        let withdrawnIsCurrent = await authority.capabilityNoticesAreCurrent(owed, for: observer)
        XCTAssertTrue(withdrawnIsCurrent)

        // Claimed elsewhere, then re-granted: the grant reads `true` again, yet the first `true`
        // notice is older than the newest change and may never be restored or pushed.
        let withdrawal = await authority.takeCapabilityNotices(for: observer)
        _ = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)
        let regrant = await authority.takeCapabilityNotices(for: observer)
        let firstGrantIsCurrent = await authority.capabilityNoticesAreCurrent(granted, for: observer)
        XCTAssertFalse(firstGrantIsCurrent, "an older notice is stale even when the state matches again")
        let regrantIsCurrent = await authority.capabilityNoticesAreCurrent(regrant, for: observer)
        XCTAssertTrue(regrantIsCurrent)
        await authority.restoreCapabilityNotices(granted, for: observer)
        let afterOlderRestore = await authority.pendingCapabilityNotices(for: observer)
        XCTAssertTrue(afterOlderRestore.isEmpty, "an older notice never comes back after a newer change")
        let regrantRevision = try XCTUnwrap(regrant.first?.observerLinkSetRevision)
        await authority.acknowledgeCapabilityNotices(for: observer, throughObserverLinkSetRevision: regrantRevision)
        await authority.restoreCapabilityNotices(regrant, for: observer)
        let afterStatedRestore = await authority.pendingCapabilityNotices(for: observer)
        XCTAssertTrue(afterStatedRestore.isEmpty, "a failed push never restores what an accepted inventory stated")
        _ = await authority.setManagement(false, reference: reference(grant), observer: observer, target: target)
        let owedWithdrawal = await authority.pendingCapabilityNotices(for: observer)
        XCTAssertEqual(owedWithdrawal.map(\.managed), [false])
        XCTAssertEqual(withdrawal.map(\.managed), [false])

        let withdrawalRevision = try XCTUnwrap(owedWithdrawal.first?.observerLinkSetRevision)
        await authority.acknowledgeCapabilityNotices(
            for: observer,
            throughObserverLinkSetRevision: withdrawalRevision - 1
        )
        let afterOlderInventory = await authority.pendingCapabilityNotices(for: observer)
        XCTAssertEqual(afterOlderInventory.count, 1, "an older inventory never settles a newer change")
        await authority.acknowledgeCapabilityNotices(for: observer, throughObserverLinkSetRevision: withdrawalRevision)
        let afterInventory = await authority.pendingCapabilityNotices(for: observer)
        XCTAssertTrue(afterInventory.isEmpty)

        _ = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)
        let regranted = await authority.pendingCapabilityNotices(for: observer)
        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .userRequested)
        let afterRevoke = await authority.pendingCapabilityNotices(for: observer)
        XCTAssertTrue(afterRevoke.isEmpty, "a revoked link's notice describes authority that no longer exists")
        await authority.restoreCapabilityNotices(regranted, for: observer)
        let afterRestore = await authority.pendingCapabilityNotices(for: observer)
        XCTAssertTrue(afterRestore.isEmpty, "restoring cannot resurrect a revoked link's notice")
        let revokedIsCurrent = await authority.capabilityNoticesAreCurrent(regranted, for: observer)
        XCTAssertFalse(revokedIsCurrent)

        let relinked = try await activateLink(authority, observer: observer, target: target)
        XCTAssertFalse(relinked.capabilities.contains(.manage))
        let afterRelink = await authority.pendingCapabilityNotices(for: observer)
        XCTAssertTrue(afterRelink.isEmpty, "a relink starts watch-only and owes nothing")
    }
}

private extension Result where Failure == DomainAgentSessionLinkError {
    var failureError: DomainAgentSessionLinkError? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
