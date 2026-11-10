import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionPresentationRuntimeTests: XCTestCase {
    func testDetachLeavesWriterAndActivityOwnedWithoutPresentation() throws {
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope()
        let session = AgentTabSession(tabID: UUID())
        let workspaceID = UUID(), sessionID = UUID()
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: workspaceID))
        session.runState = .running
        scope.replaceSessions([session.tabID: session])
        guard case let .unique(writer) = store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID) else {
            return XCTFail("Expected exact runtime owner")
        }
        let events = Events()
        let attachment = scope.presentation.attach(session, sink: events.sink)
        let hooks = scope.presentation.makeRunHooks()
        hooks.setAgentRunActive(session, true)
        let startedAt = try XCTUnwrap(session.activeAgentRunStartedAt)
        XCTAssertEqual(events.activity, [true])
        scope.presentation.detach(attachment)
        hooks.requestUIRefresh(session, true)
        hooks.notifyAgentTurnComplete(session)
        hooks.notifyAgentTurnFailed(session, "late failure")
        hooks.setAgentRunActive(session, true)
        XCTAssertEqual(session.activeAgentRunStartedAt, startedAt)
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(writer.isCurrent, "Presentation detachment must never release writer ownership")
        hooks.setAgentRunActive(session, false)
        XCTAssertNil(session.activeAgentRunStartedAt, "Runtime accounting still settles with no presenter")
        XCTAssertEqual(events.activity, [true])
        XCTAssertEqual(events.refreshes, 0)
        XCTAssertEqual(events.completions, 0)
        XCTAssertEqual(events.failures, 0)
    }

    func testOldDetachCannotDisconnectNewAttachmentAndRecycledTabCannotReceiveCallbacks() {
        let runtime = AgentSessionPresentationRuntime()
        let session = AgentTabSession(tabID: UUID())
        let oldEvents = Events(), newEvents = Events(), replacementEvents = Events()
        let old = runtime.attach(session, sink: oldEvents.sink)
        let current = runtime.attach(session, sink: newEvents.sink)
        runtime.detach(old)
        let hooks = runtime.makeRunHooks()
        hooks.requestUIRefresh(session, true)
        XCTAssertEqual(oldEvents.refreshes, 0)
        XCTAssertEqual(newEvents.refreshes, 1)
        runtime.detach(current)
        let replacement = AgentTabSession(tabID: session.tabID)
        _ = runtime.attach(replacement, sink: replacementEvents.sink)
        hooks.requestUIRefresh(session, true)
        hooks.notifyAgentTurnComplete(session)
        hooks.setAgentRunActive(session, true)
        XCTAssertNil(replacement.activeAgentRunStartedAt)
        XCTAssertEqual(replacementEvents.refreshes, 0)
        hooks.requestUIRefresh(replacement, true)
        XCTAssertEqual(replacementEvents.refreshes, 1)
    }

    func testViewModelReplacementDetachesOldObjectAndCloseDrainsBeforeDetach() async throws {
        var vm: AgentModeViewModel? = AgentModeViewModel(
            testWindowID: -1406,
            codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Presentation attachment cannot launch providers") }
        )
        let first = AgentTabSession(tabID: UUID())
        vm?.test_installLiveSession(first)
        let hooks = try XCTUnwrap(vm?.test_runPresentationHooks())
        hooks.setAgentRunActive(first, true)
        XCTAssertEqual(vm?.tabsWithActiveAgentRun, [first.tabID])
        let replacement = AgentTabSession(tabID: first.tabID)
        vm?.test_installLiveSession(replacement)
        hooks.setAgentRunActive(replacement, true)
        hooks.setAgentRunActive(first, false)
        XCTAssertEqual(vm?.tabsWithActiveAgentRun, [replacement.tabID], "Late predecessor settlement cannot clear a successor's activity")
        XCTAssertNotNil(replacement.activeAgentRunStartedAt)
        await vm?.prepareForWindowClose()
        vm = nil
        hooks.setAgentRunActive(replacement, false)
        XCTAssertNil(replacement.activeAgentRunStartedAt)
    }

    func testRouterHooksDoNotRetainOptionalPresenter() throws {
        let runtime = AgentSessionPresentationRuntime()
        let session = AgentTabSession(tabID: UUID())
        var presenter: Events? = Events()
        weak let weakPresenter = presenter
        _ = try runtime.attach(session, sink: XCTUnwrap(presenter?.sink))
        let hooks = runtime.makeRunHooks()
        hooks.setAgentRunActive(session, true)
        presenter = nil
        XCTAssertNil(weakPresenter, "The presentation adapter supplies weak host callbacks")
        hooks.setAgentRunActive(session, false)
        XCTAssertNil(session.activeAgentRunStartedAt)
    }

    func testDetachedSinkTakesOverOnlyAfterExactPresenterIsGone() throws {
        let runtime = AgentSessionPresentationRuntime()
        let session = AgentTabSession(tabID: UUID())
        var complete = 0, failed = 0, stateChanges = 0
        runtime.detachedSink = .init(
            turnComplete: { _ in complete += 1 }, turnFailed: { _, _ in failed += 1 },
            stateChanged: { stateChanges += 1 }
        )
        var presenter: Events? = Events()
        weak let weakPresenter = presenter
        var sink = try XCTUnwrap(presenter).sink
        sink.isAvailable = { [weak presenter] in presenter != nil }
        let old = runtime.attach(session, sink: sink)
        let hooks = runtime.makeRunHooks()
        hooks.notifyAgentTurnComplete(session)
        runtime.interactionChanged(session)
        XCTAssertEqual(presenter?.completions, 1)
        XCTAssertEqual(complete, 0)
        let beforeLoss = stateChanges
        presenter = nil
        XCTAssertNil(weakPresenter)
        hooks.notifyAgentTurnComplete(session)
        hooks.notifyAgentTurnFailed(session, "failure without a presenter")
        runtime.interactionChanged(session)
        XCTAssertEqual(complete, 1)
        XCTAssertEqual(failed, 1)
        XCTAssertEqual(stateChanges, beforeLoss + 1)
        let next = Events()
        _ = runtime.attach(session, sink: next.sink)
        runtime.detach(old)
        hooks.notifyAgentTurnComplete(session)
        XCTAssertEqual(next.completions, 1)
        XCTAssertEqual(complete, 1, "A stale detach cannot re-enable fallback over a newer presenter")
    }

    @MainActor
    private final class Events {
        var activity: [Bool] = []
        var refreshes = 0
        var completions = 0
        var failures = 0

        var sink: AgentSessionPresentationRuntime.Sink {
            .init(
                activityChanged: { [weak self] _, active in self?.activity.append(active) },
                refresh: { [weak self] _, _, _ in self?.refreshes += 1 },
                turnComplete: { [weak self] _ in self?.completions += 1 },
                turnFailed: { [weak self] _, _ in self?.failures += 1 }
            )
        }
    }
}
