import Combine
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionRuntimeStoreTests: XCTestCase {
    func testBindingChangesAndDuplicateClaimsStayIndexedWithoutPresentation() {
        let store = AgentSessionRuntimeStore()
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
        let store = AgentSessionRuntimeStore()
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
        var store: AgentSessionRuntimeStore? = AgentSessionRuntimeStore()
        var session: AgentTabSession? = AgentTabSession(tabID: UUID())
        weak var weakStore = store
        weak var weakSession = session
        try store?.replaceSessions([XCTUnwrap(session?.tabID): XCTUnwrap(session)])
        let callback = session?.persistentSessionBindingDidChange
        session = nil
        XCTAssertNotNil(weakSession, "The store owns the live object.")
        store = nil
        XCTAssertNil(weakStore)
        XCTAssertNil(weakSession, "The derived-index callback must not form a retain cycle.")
        callback?()
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
