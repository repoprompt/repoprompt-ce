import Combine
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionRuntimeStoreTests: XCTestCase {
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

    func testViewModelPublishesBeforeStorageChangesAndUsesRuntimeIndex() {
        let vm = AgentModeViewModel(
            testWindowID: -1406,
            codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Store publication must not launch a provider") }
        )
        let session = AgentTabSession(tabID: UUID())
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
        XCTAssertEqual(vm.liveSessionTabIDs(for: sessionID), [session.tabID])
        observedPresence.removeAll()
        vm.test_removeSession(tabID: session.tabID)
        XCTAssertEqual(observedPresence.first, true)
        XCTAssertNil(vm.sessions[session.tabID])
        XCTAssertTrue(vm.liveSessionTabIDs(for: sessionID).isEmpty)
        XCTAssertNil(session.persistentSessionBindingDidChange)
    }
}
