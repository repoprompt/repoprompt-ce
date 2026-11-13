import Combine
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionRuntimeStoreTests: XCTestCase {
    func testPersistentWriterReceiptCannotRetainOrAdoptAnOwner() throws {
        let store = AgentSessionRuntimeStore()
        let sessionID = UUID(), workspaceID = UUID()
        weak var weakScope: AgentSessionRuntimeStore.Scope?
        weak var weakSession: AgentTabSession?
        let receipt: AgentSessionRuntimeStore.WriterReceipt
        do {
            let session = AgentTabSession(tabID: UUID())
            weakSession = session
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: workspaceID))
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            let scope = store.makeScope()
            weakScope = scope
            scope.replaceSessions([session.tabID: session])
            guard case let .unique(writer) = store.resolveWriter(sessionID: sessionID) else { return XCTFail("Missing writer") }
            receipt = try XCTUnwrap(AgentSessionRuntimeStore.WriterReceipt(writer.admitCommand(.restored).get()))
            XCTAssertEqual(receipt.disposition(for: session), .current)
            let conflicting = store.makeScope()
            let duplicate = conflicting.makeSession(tabID: UUID())
            duplicate.installPersistentSessionBinding(.init(tabID: duplicate.tabID, sessionID: sessionID, workspaceID: workspaceID))
            conflicting.replaceSessions([duplicate.tabID: duplicate])
            XCTAssertEqual(receipt.disposition(for: session), .claimLost)
            conflicting.replaceSessions([:])
            XCTAssertEqual(receipt.disposition(for: session), .current)
            scope.beginRetirement()
            XCTAssertEqual(receipt.disposition(for: session), .ownedSuspended)
            scope.replaceSessions([:])
            scope.replaceSessions([session.tabID: session])
            XCTAssertEqual(receipt.disposition(for: session), .claimLost)
        }
        XCTAssertNil(weakScope, "A persistent task's receipt must not retain scope -> session -> task")
        XCTAssertNil(weakSession, "The value identity must not retain the session either")
        XCTAssertEqual(receipt.disposition(for: AgentTabSession(tabID: UUID())), .claimLost)
    }

    func testBindingChangesAndDuplicateClaimsStayIndexedWithoutPresentation() {
        let store = AgentSessionRuntimeStore().makeScope()
        let first = AgentTabSession(tabID: UUID())
        let second = AgentTabSession(tabID: UUID())
        let original = UUID(), rebound = UUID()
        first.installPersistentSessionBinding(.init(tabID: first.tabID, sessionID: original))
        second.installPersistentSessionBinding(.init(tabID: second.tabID, sessionID: original))
        store.replaceSessions([first.tabID: first, second.tabID: second])
        XCTAssertTrue(store.sessions[first.tabID] === first)
        XCTAssertEqual(store.liveSessionTabIDs(for: original), [first.tabID, second.tabID])

        first.installPersistentSessionBinding(.init(tabID: first.tabID, sessionID: rebound))
        XCTAssertEqual(store.liveSessionTabIDs(for: original), [second.tabID])
        XCTAssertEqual(store.liveSessionTabIDs(for: rebound), [first.tabID])
        first.installPersistentSessionBinding(nil)
        XCTAssertTrue(store.liveSessionTabIDs(for: rebound).isEmpty)
        store.replaceSessions([first.tabID: first])
        XCTAssertTrue(store.liveSessionTabIDs(for: original).isEmpty)
        XCTAssertNil(second.persistentSessionBindingDidChange)
    }

    func testMembershipTracksUnboundIncarnationsWithoutAdmittingAPersistentWriter() throws {
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope()
        let session = scope.makeSession(tabID: UUID())
        XCTAssertNil(scope.membership(of: session))
        scope.replaceSessions([session.tabID: session])
        let original = try XCTUnwrap(scope.membership(of: session))
        XCTAssertTrue(original.isCurrent)
        XCTAssertTrue(original.permitsBindingPreparation)
        scope.replaceSessions([session.tabID: session])
        XCTAssertTrue(original.isCurrent, "Republishing membership is not a new owner")
        scope.replaceSessions([:])
        scope.replaceSessions([session.tabID: session])
        XCTAssertFalse(original.isCurrent, "Even an unbound same-object reacquisition is a new owner")
        let reacquired = try XCTUnwrap(scope.membership(of: session))
        session.installPersistentSessionBinding(nil)
        XCTAssertFalse(reacquired.isCurrent, "An explicit install rotates the existing slot")
        let unbound = try XCTUnwrap(scope.membership(of: session))
        let sessionID = UUID()
        XCTAssertTrue(scope.liveSessionTabIDs(for: sessionID).isEmpty)
        guard case .unavailable(.absent) = store.resolveWriter(sessionID: sessionID) else {
            return XCTFail("An unbound slot cannot elect a persistent writer")
        }
        let binding = AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: sessionID)
        session.installPersistentSessionBinding(binding)
        XCTAssertFalse(unbound.isCurrent)
        let unscoped = try XCTUnwrap(scope.membership(of: session))
        XCTAssertTrue(unscoped.permitsBindingPreparation, "Qualification must not require completed restoration")
        XCTAssertEqual(scope.liveSessionTabIDs(for: sessionID), [session.tabID])
        guard case .unavailable(.unscopedBinding) = store.resolveWriter(sessionID: sessionID) else {
            return XCTFail("Membership is not a workspace or restoration authority")
        }
        scope.beginRetirement()
        XCTAssertTrue(unscoped.isCurrent)
        XCTAssertFalse(unscoped.permitsBindingPreparation)
        XCTAssertTrue(scope.releaseWriterClaimsAfterDrain())
        XCTAssertFalse(unscoped.isCurrent)
        XCTAssertNil(scope.membership(of: session))
        XCTAssertTrue(scope.liveSessionTabIDs(for: sessionID).isEmpty)
    }

    func testMembershipRefusesConflictsWithoutLosingItsOriginatingCleanupReceipt() throws {
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope(), competing = store.makeScope()
        let session = scope.makeSession(tabID: UUID())
        scope.replaceSessions([session.tabID: session])
        let unbound = try XCTUnwrap(scope.membership(of: session))
        competing.replaceSessions([session.tabID: session])
        XCTAssertTrue(unbound.isCurrent)
        XCTAssertFalse(unbound.permitsBindingPreparation, "Another scope cannot lend bootstrap authority")
        competing.replaceSessions([:])
        XCTAssertTrue(unbound.permitsBindingPreparation)
        let binding = AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID(), workspaceID: UUID())
        session.installPersistentSessionBinding(binding)
        let bound = try XCTUnwrap(scope.membership(of: session))
        let duplicate = competing.makeSession(tabID: UUID())
        duplicate.installPersistentSessionBinding(.init(tabID: duplicate.tabID, sessionID: binding.sessionID, workspaceID: binding.workspaceID))
        competing.replaceSessions([duplicate.tabID: duplicate])
        XCTAssertTrue(bound.isCurrent)
        XCTAssertFalse(bound.permitsBindingPreparation)
        competing.replaceSessions([:])
        XCTAssertTrue(bound.permitsBindingPreparation)
        let generation = session.beginPersistentBindingTransition()
        XCTAssertTrue(bound.permitsBindingPreparation, "Preparation suspends commands, not its own structural receipt")
        session.finishPersistentBindingTransition(generation: generation)
        XCTAssertTrue(bound.isCurrent)
    }

    func testRetiredCallbackCannotChangeReplacementIndex() throws {
        let store = AgentSessionRuntimeStore().makeScope()
        let tabID = UUID(), oldID = UUID(), newID = UUID()
        let old = AgentTabSession(tabID: tabID)
        old.installPersistentSessionBinding(.init(tabID: tabID, sessionID: oldID))
        store.replaceSessions([tabID: old])
        let retiredCallback = try XCTUnwrap(old.persistentSessionBindingDidChange)
        let replacement = AgentTabSession(tabID: tabID)
        replacement.installPersistentSessionBinding(.init(tabID: tabID, sessionID: newID))
        store.replaceSessions([tabID: replacement])
        XCTAssertNil(old.persistentSessionBindingDidChange)
        old.installPersistentSessionBinding(.init(tabID: tabID, sessionID: UUID()))
        retiredCallback()
        XCTAssertTrue(store.sessions[tabID] === replacement)
        XCTAssertTrue(store.liveSessionTabIDs(for: oldID).isEmpty)
        XCTAssertEqual(store.liveSessionTabIDs(for: newID), [tabID])

        // Reinstalling the same object must not detach its live binding callback.
        store.replaceSessions([tabID: replacement])
        replacement.installPersistentSessionBinding(.init(tabID: tabID, sessionID: oldID))
        XCTAssertEqual(store.liveSessionTabIDs(for: oldID), [tabID])
        XCTAssertTrue(store.liveSessionTabIDs(for: newID).isEmpty)
    }

    func testBindingCallbackDoesNotRetainStoreOrSession() throws {
        var store: AgentSessionRuntimeStore.Scope? = AgentSessionRuntimeStore().makeScope()
        var session: AgentTabSession? = AgentTabSession(tabID: UUID())
        weak let weakStore = store
        weak let weakSession = session
        try store?.replaceSessions([XCTUnwrap(session?.tabID): XCTUnwrap(session)])
        let callback = session?.persistentSessionBindingDidChange
        session = nil
        XCTAssertNotNil(weakSession, "The store owns the live object.")
        store = nil
        XCTAssertNil(weakStore)
        XCTAssertNil(weakSession, "The derived-index callback must not form a retain cycle.")
        callback?()
    }

    func testWriterResolutionPinsWorkspaceObjectAndIncarnation() {
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope()
        let workspaceID = UUID(), sessionID = UUID()
        let session = AgentTabSession(tabID: UUID())
        guard case .unavailable(.absent) = store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID) else {
            return XCTFail("No live claim must not elect a writer")
        }
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: workspaceID))
        scope.replaceSessions([session.tabID: session])
        guard case let .unique(writer) = store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID) else {
            return XCTFail("The exact scoped object must resolve")
        }
        XCTAssertTrue(writer.isCurrent)
        XCTAssertTrue(writer.session === session)
        guard case .conflicting = store.resolveWriter(workspaceID: UUID(), sessionID: sessionID) else {
            return XCTFail("A workspace mismatch must fail closed")
        }
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: workspaceID))
        XCTAssertFalse(writer.isCurrent, "Same UUID with a new generation cannot reuse a lease")
        _ = session.beginPersistentBindingTransition()
        guard case .unavailable(.bindingTransition) = store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID) else {
            return XCTFail("An in-flight rebind is not an admitted writer")
        }
    }

    func testUnscopedBindingCannotAdmitWriterAndLeaseRetainsScope() throws {
        let store = AgentSessionRuntimeStore()
        var scope: AgentSessionRuntimeStore.Scope? = store.makeScope()
        weak let retainedScope = scope
        let session = AgentTabSession(tabID: UUID())
        let workspaceID = UUID(), sessionID = UUID()
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID))
        scope?.replaceSessions([session.tabID: session])
        guard case .unavailable(.unscopedBinding) = store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID) else {
            return XCTFail("No selected-window fallback may supply missing workspace authority")
        }
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: workspaceID))
        var lease: AgentSessionRuntimeStore.Writer?
        if case let .unique(writer) = store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID) {
            lease = writer
        }
        XCTAssertTrue(try XCTUnwrap(lease).isCurrent)
        scope = nil
        XCTAssertNotNil(retainedScope, "An admitted command keeps its exact owner alive across suspension")
        lease = nil
        XCTAssertNil(retainedScope)
        guard case .unavailable(.absent) = store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID) else {
            return XCTFail("A completed command leaves no phantom writer after its scope retires")
        }
    }

    func testConflictingScopesAreNotElectedAndRetiredScopesDoNotLeaveClaims() {
        let store = AgentSessionRuntimeStore()
        let first = store.makeScope()
        var second: AgentSessionRuntimeStore.Scope? = store.makeScope()
        let workspaceID = UUID(), sessionID = UUID(), tabID = UUID()
        let a = AgentTabSession(tabID: tabID), b = AgentTabSession(tabID: tabID)
        for session in [a, b] {
            session.installPersistentSessionBinding(.init(tabID: tabID, sessionID: sessionID, workspaceID: workspaceID))
        }
        first.replaceSessions([tabID: a])
        second?.replaceSessions([tabID: b])
        guard case .conflicting = store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID) else {
            return XCTFail("Agreeing metadata on distinct live objects is still conflicting writers")
        }
        second = nil
        guard case let .unique(writer) = store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID) else {
            return XCTFail("A dead scope cannot retain a phantom claim")
        }
        XCTAssertTrue(writer.session === a)
        first.replaceSessions([:])
        XCTAssertFalse(writer.isCurrent)
    }

    func testCommandCapabilityRejectsConflictsAndSameIdentityRebind() throws {
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope(), competing = store.makeScope()
        let workspaceID = UUID()
        let claim = AgentSessionCreationClaim(workspaceID: workspaceID)
        let session = scope.makeSession(tabID: UUID())
        let binding = AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: claim.sessionID, workspaceID: workspaceID)
        session.installPersistentSessionBinding(binding)
        let creation = try XCTUnwrap(session.acceptFreshCreation(claim, workspaceID: workspaceID))
        scope.replaceSessions([session.tabID: session])
        guard case let .unique(writer) = store.resolveWriter(workspaceID: workspaceID, sessionID: claim.sessionID) else {
            return XCTFail("Exact runtime must admit first configuration without presentation")
        }
        let command = try writer.admitCommand(.creation(creation)).get()
        XCTAssertNil(AgentSessionRuntimeStore.WriterReceipt(command), "Persistent provider tasks require restored admission")
        XCTAssertTrue(command.isCurrent)
        XCTAssertEqual(command.identity.restoration, session.currentRestorationBindingToken)
        let deletion = try AgentSessionDeletionRegistry.shared.beginDurableDeletion(sessionID: claim.sessionID)
        XCTAssertFalse(command.isCurrent)
        XCTAssertEqual(writer.query()?.commandRejection, .deleted)
        AgentSessionDeletionRegistry.shared.didFailDurableDeletion(deletion)
        XCTAssertTrue(command.isCurrent)
        let replica = AgentTabSession(tabID: session.tabID)
        replica.installPersistentSessionBinding(binding)
        XCTAssertTrue(command.isCurrent, "An unregistered UI replica is not another writer")
        competing.replaceSessions([replica.tabID: replica])
        XCTAssertFalse(command.isCurrent, "An actual competing runtime claim fails closed")
        XCTAssertNil(writer.query())
        competing.replaceSessions([:])
        XCTAssertTrue(command.isCurrent)
        _ = session.beginPersistentBindingTransition()
        session.installPersistentSessionBinding(binding)
        XCTAssertFalse(command.isCurrent, "Even an identical binding has a new restoration incarnation")
        XCTAssertNil(writer.query())
        guard case let .unique(rebound) = store.resolveWriter(workspaceID: workspaceID, sessionID: claim.sessionID) else {
            return XCTFail("Expected rebound writer")
        }
        scope.replaceSessions([replica.tabID: replica])
        guard case let .unique(replaced) = store.resolveWriter(workspaceID: workspaceID, sessionID: claim.sessionID) else {
            return XCTFail("Expected replacement writer")
        }
        XCTAssertNotEqual(replaced.identity, rebound.identity, "A replacement cannot inherit its predecessor's acknowledgement")
        XCTAssertEqual(replaced.restoration, writer.restoration)
        XCTAssertNotEqual(replaced.identity, writer.identity, "Copied binding tokens do not make two objects the same incarnation")
        XCTAssertFalse(rebound.isCurrent)
        scope.replaceSessions([replica.tabID: replica])
        XCTAssertTrue(replaced.isCurrent, "Republishing the same object preserves its claim")
        scope.replaceSessions([:])
        scope.replaceSessions([replica.tabID: replica])
        XCTAssertFalse(replaced.isCurrent, "Reacquiring a released claim cannot revive an old acknowledgement")
        guard case let .unique(reacquired) = store.resolveWriter(workspaceID: workspaceID, sessionID: claim.sessionID) else {
            return XCTFail("Expected a newly admitted claim")
        }
        XCTAssertNotEqual(reacquired.identity.incarnationID, replaced.identity.incarnationID)
    }

    func testSameObjectInTwoScopesRemainsConflictingAcrossRebind() {
        let store = AgentSessionRuntimeStore()
        let first = store.makeScope(), second = store.makeScope()
        let session = AgentTabSession(tabID: UUID())
        let workspaceID = UUID(), oldID = UUID(), newID = UUID()
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: oldID, workspaceID: workspaceID))
        first.replaceSessions([session.tabID: session])
        second.replaceSessions([session.tabID: session])
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: newID, workspaceID: workspaceID))
        guard case .conflicting = store.resolveWriter(workspaceID: workspaceID, sessionID: newID) else {
            return XCTFail("Rebinding cannot hide a competing scope")
        }
        first.replaceSessions([:])
        XCTAssertNotNil(session.persistentSessionBindingDidChange)
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: oldID, workspaceID: workspaceID))
        XCTAssertEqual(second.liveSessionTabIDs(for: oldID), [session.tabID])
    }

    func testRetirementBlocksSuccessorButPreservesOriginatingWriterUntilAcknowledgedDrain() {
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope(), successor = store.makeScope()
        let workspaceID = UUID(), sessionID = UUID()
        let session = AgentTabSession(tabID: UUID())
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: workspaceID))
        scope.replaceSessions([session.tabID: session])
        guard case let .unique(writer) = store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID) else {
            return XCTFail("Expected exact originating writer")
        }
        let replacement = AgentTabSession(tabID: session.tabID)
        XCTAssertFalse(successor.permitsBinding(sessionID, on: replacement), "A cold replica cannot create a second writer")
        XCTAssertFalse(scope.permitsBinding(sessionID, on: replacement), "Another object in the same scope is not the writer")
        XCTAssertTrue(scope.permitsBinding(sessionID, on: session))
        guard case let .unique(sessionOnlyWriter) = store.resolveWriter(sessionID: sessionID) else {
            return XCTFail("Session-only lookup must use the runtime's workspace, not UI metadata")
        }
        XCTAssertEqual(sessionOnlyWriter.identity, writer.identity)
        scope.beginRetirement()
        XCTAssertTrue(store.hasRetiringWriter(sessionID: sessionID))
        XCTAssertFalse(successor.permitsBinding(sessionID, on: replacement))
        XCTAssertTrue(scope.permitsBinding(sessionID, on: session), "Originating final save keeps its capability")
        XCTAssertTrue(writer.isCurrent)
        session.isDirty = true
        XCTAssertFalse(scope.releaseWriterClaimsAfterDrain(), "A failed save must retain the claim")
        session.isDirty = false
        XCTAssertTrue(session.runLifecycle.beginTerminalCommit())
        XCTAssertFalse(scope.releaseWriterClaimsAfterDrain(), "An unsettled terminal publication still owns the session")
        session.runLifecycle.completeTerminalCommit()
        XCTAssertTrue(scope.saveQueue.begin(sessionID: sessionID))
        XCTAssertFalse(scope.releaseWriterClaimsAfterDrain(), "A possible durable effect must finish first")
        _ = scope.saveQueue.finish(sessionID: sessionID)
        XCTAssertTrue(scope.releaseWriterClaimsAfterDrain())
        XCTAssertFalse(writer.isCurrent, "Even a retained old scope cannot compete with the successor")
        XCTAssertFalse(store.hasRetiringWriter(sessionID: sessionID))
        XCTAssertTrue(successor.permitsBinding(sessionID, on: replacement))
        scope.replaceSessions([session.tabID: session])
        XCTAssertTrue(scope.sessions.isEmpty, "A released scope cannot resurrect its old writer")
    }

    func testPerSessionReleaseRequiresRetirementAndPreservesBusySiblingIdentity() throws {
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope()
        let workspaceID = UUID()
        let first = scope.makeSession(tabID: UUID()), sibling = scope.makeSession(tabID: UUID())
        for session in [first, sibling] {
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: UUID(), workspaceID: workspaceID))
        }
        scope.replaceSessions([first.tabID: first, sibling.tabID: sibling])
        let origin = try controlWriterIdentity(for: sibling, scope: scope)
        XCTAssertFalse(scope.releaseWriterClaim(for: first), "An idle label is not a retirement fence")
        sibling.runState = .running
        sibling.isDirty = true
        let siblingID = try XCTUnwrap(sibling.activeAgentSessionID)
        XCTAssertTrue(scope.saveQueue.begin(sessionID: siblingID))
        scope.beginRetirement()
        first.isDirty = true
        XCTAssertFalse(scope.releaseWriterClaim(for: first), "Failed durability keeps the exact writer")
        first.isDirty = false
        XCTAssertTrue(scope.releaseWriterClaim(for: first), "A sibling's run/save does not join this session's drain")
        XCTAssertTrue(try scope.liveSessionTabIDs(for: XCTUnwrap(first.activeAgentSessionID)).isEmpty)
        XCTAssertTrue(scope.sessions[sibling.tabID] === sibling)
        XCTAssertEqual(try controlWriterIdentity(for: sibling, scope: scope), origin)
        XCTAssertFalse(scope.releaseWriterClaim(for: first), "Release is exact-object and cannot be repeated")
        scope.replaceSessions([first.tabID: first, sibling.tabID: sibling])
        XCTAssertNil(scope.sessions[first.tabID], "A stale map publication must not resurrect a released claim")
        XCTAssertEqual(try controlWriterIdentity(for: sibling, scope: scope), origin)
        XCTAssertFalse(scope.releaseWriterClaim(for: sibling))
        sibling.runState = .completed
        sibling.isDirty = false
        XCTAssertFalse(scope.releaseWriterClaim(for: sibling), "Its own save is still in flight")
        _ = scope.saveQueue.finish(sessionID: siblingID)
        XCTAssertTrue(scope.releaseWriterClaim(for: sibling))
        XCTAssertTrue(scope.releaseWriterClaimsAfterDrain())
    }

    func testSessionKeyedContinuationDrainCannotBeAcknowledgedByCancellingWaiter() async {
        let scope = AgentSessionRuntimeStore().makeScope()
        let first = scope.makeSession(tabID: UUID()), sibling = scope.makeSession(tabID: UUID())
        scope.replaceSessions([first.tabID: first, sibling.tabID: sibling])
        let entered = expectation(description: "sibling producer entered")
        var release: CheckedContinuation<Void, Never>?
        let launch = AgentSessionRunContinuationRuntime.Launch { session, _, _ in
            if session === sibling {
                await withCheckedContinuation { release = $0
                    entered.fulfill()
                }
            }
        }
        scope.continuation.scheduleTypedACPFollowUp(session: sibling, instruction: .providerOnly("held sibling"), launch: launch)
        await fulfillment(of: [entered], timeout: 2)
        scope.continuation.scheduleTypedACPFollowUp(session: first, instruction: .providerOnly("independent"), launch: launch)
        await scope.continuation.drainPendingStarts(for: first)
        XCTAssertFalse(scope.continuation.hasPendingStarts(for: first))
        XCTAssertTrue(scope.continuation.hasPendingStarts(for: sibling))
        let replacement = AgentTabSession(tabID: sibling.tabID)
        XCTAssertFalse(scope.continuation.hasPendingStarts(for: replacement), "A recycled tab cannot inherit the original producer")
        await scope.continuation.drainPendingStarts(for: replacement)
        scope.beginRetirement()
        first.isDirty = false
        sibling.isDirty = false
        XCTAssertTrue(scope.releaseWriterClaim(for: first))
        XCTAssertFalse(scope.releaseWriterClaim(for: sibling))
        let joining = expectation(description: "cancelled waiter joined")
        var drained = false
        let drain = Task {
            joining.fulfill()
            await scope.continuation.drainPendingStarts(for: sibling)
            drained = true
        }
        await fulfillment(of: [joining], timeout: 2)
        drain.cancel()
        XCTAssertFalse(drained)
        release?.resume()
        await drain.value
        XCTAssertTrue(drained)
        XCTAssertFalse(scope.continuation.hasPendingStarts)
        XCTAssertFalse(sibling.mcpFollowUpRunPending)
        sibling.isDirty = false
        XCTAssertTrue(scope.releaseWriterClaim(for: sibling))
    }

    func testPerSessionReleaseWaitsForItsInteractionEffectNotASibling() async {
        let scope = AgentSessionRuntimeStore().makeScope()
        let held = scope.makeSession(tabID: UUID()), sibling = scope.makeSession(tabID: UUID())
        scope.replaceSessions([held.tabID: held, sibling.tabID: sibling])
        let interactions = scope.interactions(routeID: -1406, approvalStore: ApplyEditsApprovalStore())
        let entered = expectation(description: "interaction effect entered")
        var release: CheckedContinuation<Void, Never>?
        interactions.test_beforeApprovalCancellation = {
            await withCheckedContinuation { release = $0
                entered.fulfill()
            }
        }
        interactions.cancelPendingApplyEditsReview(for: held, reason: "fixture retirement")
        await fulfillment(of: [entered], timeout: 2)
        scope.beginRetirement()
        held.isDirty = false
        sibling.isDirty = false
        XCTAssertTrue(scope.settlement(for: held).blockers.contains(.effects))
        XCTAssertFalse(scope.releaseWriterClaim(for: held))
        XCTAssertTrue(scope.releaseWriterClaim(for: sibling))
        release?.resume()
        await interactions.drainPendingEffects(for: held)
        XCTAssertTrue(scope.releaseWriterClaim(for: held))
    }

    func testSettlementSeparatesLiveWorkDrainEffectsAndDurability() {
        let scope = AgentSessionRuntimeStore().makeScope()
        let session = scope.makeSession(tabID: UUID())
        let sessionID = UUID()
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: UUID()))
        scope.replaceSessions([session.tabID: session])
        session.isDirty = false
        XCTAssertTrue(scope.settlement(for: session).isSettled)
        session.runState = .waitingForQuestion
        XCTAssertTrue(scope.settlement(for: session).blockers.contains(.run), "Waiting is live work, not a settlement boundary")
        session.runState = .completed
        let ownership = session.beginRunAttempt(source: "settlement-characterisation")
        XCTAssertTrue(scope.settlement(for: session).blockers.contains(.run), "An idle label cannot hide an owned attempt")
        XCTAssertTrue(scope.settlement(for: session).legacyPreparedOwnerIsIdle, "Phase 0 does not silently adopt the later handoff policy")
        XCTAssertTrue(session.endRunAttempt(ifCurrent: ownership, source: "settlement-test"))
        XCTAssertTrue(session.runLifecycle.beginTerminalCommit())
        XCTAssertFalse(scope.settlement(for: session).isQuiescent)
        session.runLifecycle.completeTerminalCommit()
        session.mcpFollowUpRunPending = true
        XCTAssertTrue(scope.settlement(for: session).blockers.contains(.pendingStart))
        session.mcpFollowUpRunPending = false
        session.selfCompactAdmissionPendingID = UUID()
        XCTAssertFalse(scope.settlement(for: session).isQuiescent)
        session.selfCompactAdmissionPendingID = nil
        session.pendingInstructions = [.providerOnly("persisted queued instruction")]
        session.isDirty = false
        XCTAssertFalse(scope.settlement(for: session).isSettled)
        XCTAssertTrue(scope.settlement(for: session).legacyDrainCanRelease, "Legacy retirement keeps its prior acknowledgement contract")
        session.pendingInstructions = []
        session.codexFallbackPumpTask = Task {}
        XCTAssertTrue(scope.settlement(for: session).blockers.contains(.provider))
        session.codexFallbackPumpTask = nil
        session.isDirty = true
        XCTAssertTrue(scope.settlement(for: session).isQuiescent, "The existing handoff save may prepare a dirty payload")
        XCTAssertFalse(scope.settlement(for: session).isSettled)
        session.isDirty = false
        XCTAssertTrue(scope.saveQueue.begin(sessionID: sessionID))
        XCTAssertTrue(scope.settlement(for: session).blockers.contains(.effects))
        XCTAssertFalse(scope.settlement(for: session).isSettled)
        _ = scope.saveQueue.finish(sessionID: sessionID)
        XCTAssertTrue(scope.settlement(for: session).isSettled)
        scope.replaceSessions([session.tabID: AgentTabSession(tabID: session.tabID)])
        XCTAssertEqual(scope.settlement(for: session).blockers, [.notInstalled])
    }

    /// M9.4 phase 0 pins today's cancelling policy; later detach phases must flip this deliberately.
    func testLegacyWindowCloseCancelsOwnedRunBeforeDetachingPresentation() async {
        let (vm, session, ownership) = makeLegacyRunningFixture()
        await vm.prepareForWindowClose()
        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, ownership)
        XCTAssertTrue(vm.tabsWithActiveAgentRun.isEmpty)
        await vm.test_retireAndCancelFixture()
    }

    func testLegacyWorkspaceSwitchCancelsOwnedRunWithoutRetiringWriter() async throws {
        let (vm, session, ownership) = makeLegacyRunningFixture()
        let identity = try controlWriterIdentity(for: session)
        let provider = AgentModeWorkspaceSwitchSessionProvider(agentModeViewModel: vm)
        XCTAssertEqual(provider.switchSessionItems().first?.count, 1)
        await provider.cancelSwitchSessions()
        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, ownership)
        XCTAssertTrue(provider.switchSessionItems().isEmpty)
        XCTAssertEqual(try controlWriterIdentity(for: session), identity, "A workspace switch cancels but does not elect a writer")
        await vm.test_retireAndCancelFixture()
    }

    private func makeLegacyRunningFixture() -> (AgentModeViewModel, AgentTabSession, AgentRunOwnership) {
        let vm = AgentModeViewModel(
            testWindowID: -1406,
            codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Characterisation must not launch a provider") }
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .openCode
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: UUID(), workspaceID: UUID()))
        vm.test_installLiveSession(session)
        let ownership = session.beginRunAttempt(source: "m9.4.legacy-presentation-policy")
        session.runState = .running
        vm.runtimeSessionStore.presentation.makeRunHooks().setAgentRunActive(session, true)
        return (vm, session, ownership)
    }

    func testViewModelPublishesBeforeStorageChangesAndUsesRuntimeIndex() {
        let vm = AgentModeViewModel(
            testWindowID: -1406,
            codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Store publication must not launch a provider") }
        )
        XCTAssertTrue(vm.runtimeSessionStore === vm.runtimeHost.scope)
        XCTAssertTrue(vm.codexCoordinator === vm.runtimeHost.codexCoordinator)
        XCTAssertTrue(vm.claudeCoordinator === vm.runtimeHost.claudeCoordinator)
        XCTAssertNotNil(vm.runtimeHost.scope.execution, "Compose execution before creating a visible session")
        XCTAssertNotNil(vm.runtimeHost.scope.linkExecution)
        XCTAssertTrue(vm.runtimeHost.scope.sessions.isEmpty)
        let session = vm.runtimeHost.scope.makeSession(tabID: UUID())
        let sessionID = UUID()
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID))
        var observedPresence: [Bool] = []
        let subscription = vm.objectWillChange.sink {
            observedPresence.append(vm.sessions[session.tabID] != nil)
        }
        defer { subscription.cancel() }
        vm.test_installLiveSession(session)
        XCTAssertEqual(observedPresence.first, false, "Preserve @Published will-change ordering.")
        XCTAssertTrue(vm.sessions[session.tabID] === session)
        XCTAssertEqual(vm.runtimeSessionStore.liveSessionTabIDs(for: sessionID), [session.tabID])
        observedPresence.removeAll()
        vm.test_removeSession(tabID: session.tabID)
        XCTAssertEqual(observedPresence.first, true)
        XCTAssertNil(vm.sessions[session.tabID])
        XCTAssertTrue(vm.runtimeSessionStore.liveSessionTabIDs(for: sessionID).isEmpty)
        XCTAssertNil(session.persistentSessionBindingDidChange)
    }
}

@MainActor
final class AgentSessionAdministrationRuntimeTests: XCTestCase {
    func testForkRejectsReacquiredSourceBeforeDestinationPreparation() async throws {
        let fixture = try Fixture()
        var preparations = 0
        fixture.scope.administration.prepareForkDestination = { _ in
            preparations += 1
            throw SessionAdminHostError.sessionUnavailable
        }
        fixture.scope.replaceSessions([:])
        fixture.scope.replaceSessions([fixture.source.tabID: fixture.source])
        XCTAssertFalse(fixture.command.isCurrent)
        do {
            _ = try await fixture.scope.administration.fork(command: fixture.command, upToItemID: UUID(), isStillAuthorized: { true })
            XCTFail("An old incarnation cannot start a fork")
        } catch {}
        XCTAssertEqual(preparations, 0)
    }

    func testForkPreparationCarriesExactIncarnationAcrossSuspension() async throws {
        let fixture = try Fixture()
        fixture.scope.administration.prepareForkDestination = { request in
            XCTAssertTrue(request.source === fixture.source)
            XCTAssertEqual(request.workspaceID, fixture.command.identity.workspaceID)
            XCTAssertTrue(request.isStillAuthorized())
            await Task.yield()
            fixture.scope.replaceSessions([:])
            fixture.scope.replaceSessions([fixture.source.tabID: fixture.source])
            XCTAssertFalse(request.isStillAuthorized(), "Same object and session ID cannot reacquire the old command")
            throw SessionAdminHostError.authorityEnded
        }
        do {
            _ = try await fixture.scope.administration.fork(command: fixture.command, upToItemID: UUID(), isStillAuthorized: { true })
            XCTFail("Preparation must not commit after losing its source")
        } catch {}
        XCTAssertEqual(fixture.scope.sessions.count, 1)
    }

    func testCommittedDestinationReceiptSurvivesLateSourceRevocation() async throws {
        let fixture = try Fixture()
        var authorized = true
        let destination = fixture.scope.makeSession(tabID: UUID())
        let destinationID = UUID()
        destination.installPersistentSessionBinding(.init(
            tabID: destination.tabID, sessionID: destinationID, workspaceID: fixture.command.identity.workspaceID
        ))
        destination.recordRestorationAuthoritative(.persistedPayloadApplied)
        fixture.scope.administration.prepareForkDestination = { request in
            XCTAssertTrue(request.isStillAuthorized())
            fixture.scope.replaceSessions([fixture.source.tabID: fixture.source, destination.tabID: destination])
            guard case let .unique(destinationWriter) = fixture.store.resolveWriter(sessionID: destinationID) else {
                throw SessionAdminHostError.sessionUnavailable
            }
            let receipt = AgentSessionAdministrationRuntime.ForkReceipt(identity: destinationWriter.identity)
            await Task.yield()
            authorized = false
            XCTAssertFalse(request.isStillAuthorized())
            // A later occupant of the same tab must never replace the acknowledged destination.
            destination.installPersistentSessionBinding(.init(
                tabID: destination.tabID, sessionID: UUID(), workspaceID: fixture.command.identity.workspaceID
            ))
            // Simulates the existing creation owner's durable receipt, not persistence itself.
            return receipt
        }
        let result = try await fixture.scope.administration.fork(
            command: fixture.command, upToItemID: UUID(), isStillAuthorized: { authorized }
        )
        XCTAssertEqual(result, destinationID)
        XCTAssertTrue(fixture.scope.sessions[destination.tabID] === destination)
        XCTAssertNotEqual(destination.activeAgentSessionID, result, "Completion must report the saved fork, not the replacement")
    }

    func testForeignDestinationReceiptReportsPartialIdentityWithoutRetargeting() async throws {
        let fixture = try Fixture(), foreign = try Fixture()
        fixture.scope.administration.prepareForkDestination = { _ in .init(identity: foreign.command.identity) }
        do {
            _ = try await fixture.scope.administration.fork(command: fixture.command, upToItemID: UUID(), isStillAuthorized: { true })
            XCTFail("A foreign destination cannot acknowledge this fork")
        } catch let partial as SessionAdminPartialForkError {
            XCTAssertEqual(partial.sessionID, foreign.command.identity.sessionID)
            XCTAssertEqual(partial.code, "target_changed")
        }
        XCTAssertEqual(fixture.scope.sessions.count, 1)
        XCTAssertEqual(foreign.scope.sessions.count, 1)
        XCTAssertTrue(foreign.command.isCurrent)
    }

    private struct Fixture {
        let store: AgentSessionRuntimeStore
        let scope: AgentSessionRuntimeStore.Scope
        let source: AgentTabSession
        let command: AgentSessionRuntimeStore.Command

        @MainActor
        init() throws {
            store = AgentSessionRuntimeStore()
            scope = store.makeScope()
            source = scope.makeSession(tabID: UUID())
            let workspaceID = UUID(), sessionID = UUID()
            source.installPersistentSessionBinding(.init(tabID: source.tabID, sessionID: sessionID, workspaceID: workspaceID))
            source.recordRestorationAuthoritative(.persistedPayloadApplied)
            scope.replaceSessions([source.tabID: source])
            guard case let .unique(writer) = store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID) else {
                throw SessionAdminHostError.sessionUnavailable
            }
            command = try writer.admitCommand().get()
        }
    }
}
