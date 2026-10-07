import Combine
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Exact projection storage is the presentation truth for overseer role surfaces.
///
/// These tests stay at the live view-model boundary because the ordering contract spans the map
/// mutation, status-pill publication, and raw notification observed by sidebar and window-title UI.
@MainActor
final class AgentSessionLinkPresentationProjectionTests: XCTestCase {
    private var retainedViewModels: [AgentModeViewModel] = []
    private var retainedWorkspaces: [WorkspaceManagerViewModel] = []

    override func tearDown() {
        retainedViewModels.removeAll()
        retainedWorkspaces.removeAll()
        super.tearDown()
    }

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let tabID: UUID
        let endpoint: DomainAgentSessionLinkEndpointIdentity
    }

    private func makeFixture() throws -> Fixture {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 81,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retainedViewModels.append(viewModel)
        retainedWorkspaces.append(AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Overseer projection publication"
        ))
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        _ = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(session),
            "expected a durable persistent binding"
        )
        return try Fixture(
            viewModel: viewModel,
            session: session,
            tabID: tabID,
            endpoint: AgentSessionLinkEndpointTestSupport.endpoint(viewModel, tabID: tabID)
        )
    }

    private func props(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        outboundCount: Int = 1,
        inboundCount: Int = 0,
        sidebarOversightMenu: AgentSidebarOversightMenuProps? = nil
    ) -> AgentMonitorPillProps {
        AgentMonitorPillProps(
            sessionID: endpoint.sessionID,
            sidebarOversightMenu: sidebarOversightMenu,
            outbound: (0 ..< outboundCount).map { index in
                let targetSessionID = UUID()
                return AgentMonitorPillProps.Outbound(
                    linkID: UUID(),
                    generation: UInt64(index + 1),
                    targetSessionID: targetSessionID,
                    targetEndpoint: AgentSessionLinkIdentityTestSupport.endpoint(
                        sessionID: targetSessionID
                    ),
                    displayName: "Target \(index)",
                    providerDisplayName: "Codex CLI",
                    locationLabel: "worktree/\(index)",
                    status: .idle
                )
            },
            inbound: (0 ..< inboundCount).map { index in
                let observerSessionID = UUID()
                return AgentMonitorPillProps.Inbound(
                    linkID: UUID(),
                    generation: UInt64(index + 1),
                    observerSessionID: observerSessionID,
                    observerEndpoint: AgentSessionLinkIdentityTestSupport.endpoint(
                        sessionID: observerSessionID
                    ),
                    displayName: "Observer \(index)",
                    providerDisplayName: "Claude Code"
                )
            },
            recentNotices: [],
            canAddReason: nil
        )
    }

    private func sidebarMenu(
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSidebarOversightMenuProps {
        AgentSidebarOversightMenuProps(
            targetEndpoint: targetEndpoint,
            targetSessionID: targetEndpoint.sessionID,
            targetDisplayName: "Target",
            observerOptions: []
        )
    }

    func testCandidateIdentityWorkIsLinearAndSidebarReadsValidateOneTab() throws {
        let fixture = try makeFixture()
        let manager = try XCTUnwrap(retainedWorkspaces.last)
        // Exercise the real candidate producer, not a mock host's outer read count. Fixture setup
        // is outside the measured reads; no candidate/row read may hydrate or change model bindings.
        for count in [32, 200] {
            var workspace = try XCTUnwrap(manager.activeWorkspace)
            workspace.composeTabs = (0 ..< count).map { index in
                var tab = ComposeTabState(id: UUID(), name: "Chat \(index)")
                tab.activeAgentSessionID = UUID()
                return tab
            }
            manager.workspaces = [workspace]
            for tab in workspace.composeTabs {
                let session = fixture.viewModel.session(for: tab.id)
                session.selectedAgent = .claudeCode
                session.hasLoadedPersistedState = true
            }
            let modelBefore = manager.workspaces
            manager.test_lifecycleBindingTabValidationCount = 0
            let candidates = fixture.viewModel.agentSessionLinkCandidates(isWindowClosing: false)
            XCTAssertEqual(candidates.count, count)
            XCTAssertEqual(
                manager.test_lifecycleBindingTabValidationCount,
                count,
                "One current-model tab validation per candidate, independent of its array position"
            )
            let last = try XCTUnwrap(candidates.last)
            manager.test_lifecycleBindingTabValidationCount = 0
            XCTAssertEqual(fixture.viewModel.agentSidebarOversightTargetEndpoint(
                tabID: last.tabID, expectedSessionID: last.sessionID
            ), last.domainEndpoint)
            XCTAssertFalse(fixture.viewModel.agentSessionLinkIsOverseer(
                tabID: last.tabID, expectedSessionID: last.sessionID
            ))
            XCTAssertNil(fixture.viewModel.agentSidebarOversightMenuProps(
                tabID: last.tabID, expectedSessionID: last.sessionID
            ))
            XCTAssertEqual(manager.test_lifecycleBindingTabValidationCount, 3)
            XCTAssertEqual(manager.workspaces, modelBefore, "Reads must neither rebuild nor mutate bindings")
        }
    }

    func testLifecycleIndexPreservesFirstExactMatchAcrossDuplicatesAndNestedEdits() throws {
        let fixture = try makeFixture()
        let manager = try XCTUnwrap(retainedWorkspaces.last)
        let original = try XCTUnwrap(manager.activeWorkspace)
        let sessionID = fixture.endpoint.sessionID
        var mismatched = original.composeTabs[0]
        mismatched.activeAgentSessionID = UUID()
        var first = WorkspaceModel(name: "First", repoPaths: [], ephemeralFlag: true)
        first.composeTabs = [mismatched, original.composeTabs[0], original.composeTabs[0]]
        // Repeated workspace IDs must not inherit model-routing's ambiguous/last-wins semantics.
        var wrongIncarnation = first
        wrongIncarnation.composeTabs = [mismatched]
        manager.workspaces = [wrongIncarnation, first, original]

        func assertMatchesScan(file: StaticString = #filePath, line: UInt = #line) {
            let expected = manager.workspaces.first { workspace in
                workspace.composeTabs.contains { $0.id == fixture.tabID && $0.activeAgentSessionID == sessionID }
            }?.id
            XCTAssertEqual(fixture.viewModel.agentSessionLifecycleIdentity(
                tabID: fixture.tabID, expectedSessionID: sessionID
            )?.workspaceID, expected, file: file, line: line)
        }
        assertMatchesScan()
        XCTAssertEqual(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID)?.workspaceID, first.id)
        manager.workspaces.swapAt(1, 2)
        assertMatchesScan()
        XCTAssertEqual(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID)?.workspaceID, original.id)
        manager.workspaces[1].composeTabs.removeAll()
        assertMatchesScan()
        manager.workspaces[2].composeTabs.remove(at: 1)
        assertMatchesScan()
        manager.workspaces[2].composeTabs[1].activeAgentSessionID = UUID()
        assertMatchesScan()
        XCTAssertNil(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID))
        manager.workspaces = [original]
        assertMatchesScan()
        XCTAssertEqual(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID), fixture.endpoint)
    }

    func testIndexedIdentityReadsLiveGenerationsAndDoesNotHydrateRemovedBindings() async throws {
        let fixture = try makeFixture()
        let manager = try XCTUnwrap(retainedWorkspaces.last)
        let original = manager.workspaces
        fixture.session.hasLoadedPersistedState = false
        let cold = try XCTUnwrap(fixture.viewModel.agentSessionLinkCandidates(isWindowClosing: false).first)
        XCTAssertFalse(cold.hasLoadedPersistedState)
        XCTAssertEqual(cold.domainEndpoint, fixture.endpoint)
        XCTAssertFalse(fixture.session.hasLoadedPersistedState)
        XCTAssertNil(fixture.session.persistedLoadTask)

        // A synchronous model index must never cache session generations across an authority hop.
        let beforeHop = fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID)
        await Task.yield()
        fixture.session.beginPersistentBindingTransition()
        let transitioned = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
        XCTAssertNotEqual(transitioned, beforeHop)
        XCTAssertEqual(transitioned.bindingTransitionGeneration, fixture.session.bindingTransitionGeneration)
        _ = fixture.viewModel.test_installPersistentSessionBinding(
            sessionID: nil, on: fixture.session, updateWorkspaceMetadata: false
        )
        XCTAssertNil(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID))
        _ = fixture.viewModel.test_installPersistentSessionBinding(
            sessionID: fixture.endpoint.sessionID, on: fixture.session, updateWorkspaceMetadata: false
        )
        let rebound = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
        XCTAssertEqual(rebound.persistentBindingGeneration, fixture.session.persistentSessionBindingIdentity?.generation)
        XCTAssertNotEqual(rebound.persistentBindingGeneration, fixture.endpoint.persistentBindingGeneration)
        manager.workspaces[0].composeTabs[0].activeAgentSessionID = UUID()
        XCTAssertNil(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID))
        manager.workspaces = original
        XCTAssertEqual(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID), rebound)
        fixture.viewModel.test_removeSession(tabID: fixture.tabID)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkCandidates(isWindowClosing: false).isEmpty)
        XCTAssertNil(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID))
    }

    func testProjectionOverlayPreservesSidebarOversightMenu() throws {
        let fixture = try makeFixture()
        let availableEndpoint = AgentSessionLinkIdentityTestSupport.endpoint(
            sessionID: UUID(),
            windowID: 82
        )
        let menu = AgentSidebarOversightMenuProps(
            targetEndpoint: fixture.endpoint,
            targetSessionID: fixture.endpoint.sessionID,
            targetDisplayName: "Target",
            observerOptions: [AgentSidebarOversightMenuProps.ObserverOption(
                observerEndpoint: availableEndpoint,
                observerSessionID: availableEndpoint.sessionID,
                displayName: "Observer",
                providerDisplayName: "Codex CLI",
                menuLabel: "Observer",
                fullIdentityDescription: availableEndpoint.sessionID.uuidString,
                relationship: .available
            )]
        )
        // Forces the private publish-time Auto-wake copy rather than taking its identity fast path.
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.viewModel.agentSessionLinkPublishProjection(
            props(endpoint: fixture.endpoint, sidebarOversightMenu: menu),
            to: fixture.endpoint
        )

        let stored = try XCTUnwrap(fixture.viewModel.monitorPillPropsByEndpoint[fixture.endpoint])
        XCTAssertTrue(try XCTUnwrap(stored.outbound.first).isAutoWakeEffectivelySelected)
        XCTAssertEqual(stored.sidebarOversightMenu, menu)
    }

    func testProjectionPublicationStoresAndSynchronizesBeforeOneOwnerScopedNotification() throws {
        let fixture = try makeFixture()
        let published = props(endpoint: fixture.endpoint)
        var notifications: [Notification] = []
        let cancellable = NotificationCenter.default.publisher(
            for: .agentSessionLinkOverseerProjectionDidChange,
            object: fixture.viewModel
        ).sink { notification in
            notifications.append(notification)
            let stored = fixture.viewModel.monitorPillPropsByEndpoint[fixture.endpoint]
            XCTAssertEqual(stored?.endpoint, fixture.endpoint)
            // Queue presentation is derived live; this fixture has no pending updates.
            var expectedDisplay = stored
            expectedDisplay?.pendingUpdates = .empty
            XCTAssertEqual(fixture.viewModel.ui.statusPills.snapshot.monitor, expectedDisplay)
        }

        fixture.viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)

        XCTAssertEqual(
            Notification.Name.agentSessionLinkOverseerProjectionDidChange.rawValue,
            "RepoPrompt.agentSessionLinkOverseerProjectionDidChange"
        )
        XCTAssertEqual(notifications.count, 1)
        XCTAssertTrue((notifications.first?.object as? AgentModeViewModel) === fixture.viewModel)
        XCTAssertNil(notifications.first?.userInfo)
        withExtendedLifetime(cancellable) {}
    }

    func testRoutineIntervalWritesSynchronizeStatusPillsWithoutProjectionRefresh() throws {
        let fixture = try makeFixture()
        // Match the cached and live master values; this test changes only the interval.
        fixture.session.oversight.autoWakeOnUpdates = false
        fixture.viewModel.agentSessionLinkPublishProjection(
            props(endpoint: fixture.endpoint, outboundCount: 0),
            to: fixture.endpoint
        )
        XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabID)
        XCTAssertFalse(fixture.viewModel.ui.statusPills.snapshot.monitor.routineWakeIntervalEnabled)
        for (enabled, seconds) in [(true, 3600), (false, 10800)] {
            XCTAssertTrue(fixture.viewModel.agentSessionLinkSetRoutineWakeInterval(
                enabled: enabled,
                seconds: seconds,
                for: fixture.endpoint
            ))
            let displayed = fixture.viewModel.ui.statusPills.snapshot.monitor
            XCTAssertEqual(displayed.routineWakeIntervalEnabled, enabled)
            XCTAssertEqual(displayed.routineWakeIntervalSeconds, seconds)
            XCTAssertFalse(displayed.autoWakeOnUpdatesEnabled)
        }
    }

    func testPeriodicIdleWritesSynchronizeStatusPillsWithoutProjectionRefresh() throws {
        let fixture = try makeFixture()
        let published = props(endpoint: fixture.endpoint)
        fixture.viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)
        for (enabled, seconds) in [(true, 7200), (false, 21600)] {
            XCTAssertTrue(fixture.viewModel.agentSessionLinkSetPeriodicIdleWake(
                enabled: enabled,
                seconds: seconds,
                for: fixture.endpoint
            ))
            fixture.viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)
            let displayed = fixture.viewModel.ui.statusPills.snapshot.monitor
            XCTAssertEqual(displayed.periodicIdleWakeEnabled, enabled)
            XCTAssertEqual(displayed.periodicIdleWakeIntervalSeconds, seconds)
            XCTAssertFalse(displayed.routineWakeIntervalEnabled)
            XCTAssertEqual(displayed.routineWakeIntervalSeconds, 300)
        }
    }

    func testMasterWritesSynchronizeLivePolicyWithoutProjectionRefresh() throws {
        let fixture = try makeFixture()
        fixture.session.oversight.autoWakeOnUpdates = false
        let published = props(endpoint: fixture.endpoint)
        fixture.viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)
        XCTAssertFalse(fixture.viewModel.ui.statusPills.snapshot.monitor.autoWakeOnUpdatesEnabled)

        for enabled in [true, false] {
            XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(
                enabled,
                for: fixture.endpoint
            ))
            let displayed = fixture.viewModel.ui.statusPills.snapshot.monitor
            XCTAssertEqual(displayed.autoWakeOnUpdatesEnabled, enabled)
            XCTAssertEqual(try XCTUnwrap(displayed.outbound.first).isAutoWakeEffectivelySelected, enabled)
            // A late projection cannot overwrite a newer saved preference.
            fixture.viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)
            XCTAssertEqual(fixture.viewModel.ui.statusPills.snapshot.monitor.autoWakeOnUpdatesEnabled, enabled)
        }
    }

    func testGranularWritesSynchronizeLivePolicyWithoutProjectionRefresh() throws {
        let fixture = try makeFixture()
        fixture.session.oversight.autoWakeOnUpdates = false
        let published = props(endpoint: fixture.endpoint)
        let targetSessionID = try XCTUnwrap(published.outbound.first).targetSessionID
        fixture.viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)

        for selection: Set<UUID> in [[targetSessionID], []] {
            XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs(
                selection,
                for: fixture.endpoint
            ))
            let displayed = fixture.viewModel.ui.statusPills.snapshot.monitor
            XCTAssertEqual(displayed.autoWakeTargetSessionIDs, selection)
            XCTAssertFalse(displayed.autoWakeOnUpdatesEnabled)
            XCTAssertEqual(
                try XCTUnwrap(displayed.outbound.first).isAutoWakeEffectivelySelected,
                selection.contains(targetSessionID)
            )
        }
    }

    func testEqualProjectionReplacementPublishesNothing() throws {
        let fixture = try makeFixture()
        let published = props(endpoint: fixture.endpoint)
        fixture.viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)

        var notificationCount = 0
        let cancellable = NotificationCenter.default.publisher(
            for: .agentSessionLinkOverseerProjectionDidChange,
            object: fixture.viewModel
        ).sink { _ in notificationCount += 1 }

        fixture.viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)

        XCTAssertEqual(notificationCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testReplacementBatchRemovesSupersededIncarnationBeforeItsSingleNotification() throws {
        let fixture = try makeFixture()
        fixture.viewModel.agentSessionLinkPublishProjection(
            props(endpoint: fixture.endpoint),
            to: fixture.endpoint
        )
        fixture.session.beginPersistentBindingTransition()
        let replacement = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        XCTAssertNotEqual(replacement, fixture.endpoint)

        var notificationCount = 0
        let cancellable = NotificationCenter.default.publisher(
            for: .agentSessionLinkOverseerProjectionDidChange,
            object: fixture.viewModel
        ).sink { _ in
            notificationCount += 1
            XCTAssertEqual(Set(fixture.viewModel.monitorPillPropsByEndpoint.keys), [replacement])
        }

        fixture.viewModel.agentSessionLinkPublishProjection(
            props(endpoint: replacement),
            to: replacement
        )

        XCTAssertEqual(notificationCount, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testPruneRemovesEveryStaleProjectionBeforeOneNotification() throws {
        let fixture = try makeFixture()
        let first = DomainAgentSessionLinkEndpointIdentity(
            windowID: fixture.endpoint.windowID,
            workspaceID: fixture.endpoint.workspaceID,
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 0
        )
        let second = DomainAgentSessionLinkEndpointIdentity(
            windowID: fixture.endpoint.windowID,
            workspaceID: fixture.endpoint.workspaceID,
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 0
        )
        fixture.viewModel.monitorPillPropsByEndpoint = [
            first: props(endpoint: first),
            second: props(endpoint: second)
        ]

        var notificationCount = 0
        let cancellable = NotificationCenter.default.publisher(
            for: .agentSessionLinkOverseerProjectionDidChange,
            object: fixture.viewModel
        ).sink { notification in
            notificationCount += 1
            XCTAssertTrue(fixture.viewModel.monitorPillPropsByEndpoint.isEmpty)
            XCTAssertNil(notification.userInfo)
        }

        fixture.viewModel.agentSessionLinkPruneProjections()

        XCTAssertEqual(notificationCount, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testExactSidebarMenuAccessorRejectsWrongSessionMismatchedValueAndRebind() throws {
        let fixture = try makeFixture()
        let menu = sidebarMenu(targetEndpoint: fixture.endpoint)
        fixture.viewModel.agentSessionLinkPublishProjection(
            props(endpoint: fixture.endpoint, sidebarOversightMenu: menu),
            to: fixture.endpoint
        )

        XCTAssertEqual(
            fixture.viewModel.agentSidebarOversightMenuProps(
                tabID: fixture.tabID,
                expectedSessionID: fixture.endpoint.sessionID
            ),
            menu
        )
        XCTAssertEqual(
            fixture.viewModel.agentSidebarOversightTargetEndpoint(
                tabID: fixture.tabID,
                expectedSessionID: fixture.endpoint.sessionID
            ),
            fixture.endpoint
        )
        XCTAssertNil(fixture.viewModel.agentSidebarOversightMenuProps(
            tabID: fixture.tabID,
            expectedSessionID: UUID()
        ))
        XCTAssertNil(fixture.viewModel.agentSidebarOversightTargetEndpoint(
            tabID: fixture.tabID,
            expectedSessionID: UUID()
        ))

        // A map key is not enough: both the enclosing props and nested target menu must prove the
        // exact incarnation independently.
        fixture.viewModel.monitorPillPropsByEndpoint[fixture.endpoint] = props(
            endpoint: fixture.endpoint,
            sidebarOversightMenu: menu
        )
        XCTAssertNil(fixture.viewModel.agentSidebarOversightMenuProps(
            tabID: fixture.tabID,
            expectedSessionID: fixture.endpoint.sessionID
        ))

        let otherEndpoint = AgentSessionLinkIdentityTestSupport.endpoint(
            sessionID: fixture.endpoint.sessionID,
            windowID: fixture.endpoint.windowID + 1
        )
        fixture.viewModel.agentSessionLinkPublishProjection(
            props(
                endpoint: fixture.endpoint,
                sidebarOversightMenu: sidebarMenu(targetEndpoint: otherEndpoint)
            ),
            to: fixture.endpoint
        )
        XCTAssertNil(fixture.viewModel.agentSidebarOversightMenuProps(
            tabID: fixture.tabID,
            expectedSessionID: fixture.endpoint.sessionID
        ))

        fixture.viewModel.agentSessionLinkPublishProjection(
            props(endpoint: fixture.endpoint, sidebarOversightMenu: menu),
            to: fixture.endpoint
        )
        fixture.session.beginPersistentBindingTransition()
        XCTAssertNotEqual(
            fixture.viewModel.agentSidebarOversightTargetEndpoint(
                tabID: fixture.tabID,
                expectedSessionID: fixture.endpoint.sessionID
            ),
            fixture.endpoint,
            "feedback from an open system menu must not survive an exact endpoint replacement"
        )
        XCTAssertNil(
            fixture.viewModel.agentSidebarOversightMenuProps(
                tabID: fixture.tabID,
                expectedSessionID: fixture.endpoint.sessionID
            ),
            "a replacement incarnation must not inherit the retired target menu"
        )
    }

    func testExactRoleAccessorsFailClosedForInboundWrongSessionAndStaleIncarnation() throws {
        let fixture = try makeFixture()
        fixture.viewModel.agentSessionLinkPublishProjection(
            props(endpoint: fixture.endpoint),
            to: fixture.endpoint
        )
        XCTAssertTrue(fixture.viewModel.agentSessionLinkIsOverseer(
            tabID: fixture.tabID,
            expectedSessionID: fixture.endpoint.sessionID
        ))
        XCTAssertTrue(fixture.viewModel.agentSessionLinkIsOverseer(tabID: fixture.tabID))

        // The exact map key alone is not enough: the stored value must prove it was addressed to
        // the same incarnation. This deliberately bypasses the production publisher, which stamps
        // the key onto the value, to pin the accessor's fail-closed guard.
        fixture.viewModel.monitorPillPropsByEndpoint[fixture.endpoint] = props(endpoint: fixture.endpoint)
        XCTAssertFalse(fixture.viewModel.agentSessionLinkIsOverseer(tabID: fixture.tabID))
        fixture.viewModel.agentSessionLinkPublishProjection(
            props(endpoint: fixture.endpoint),
            to: fixture.endpoint
        )

        XCTAssertFalse(fixture.viewModel.agentSessionLinkIsOverseer(
            tabID: fixture.tabID,
            expectedSessionID: UUID()
        ))

        fixture.viewModel.agentSessionLinkPublishProjection(
            props(endpoint: fixture.endpoint, outboundCount: 0, inboundCount: 1),
            to: fixture.endpoint
        )
        XCTAssertFalse(fixture.viewModel.agentSessionLinkIsOverseer(tabID: fixture.tabID))

        fixture.viewModel.agentSessionLinkPublishProjection(
            props(endpoint: fixture.endpoint),
            to: fixture.endpoint
        )
        fixture.session.beginPersistentBindingTransition()
        XCTAssertFalse(
            fixture.viewModel.agentSessionLinkIsOverseer(tabID: fixture.tabID),
            "a rebound incarnation must not inherit the retired endpoint's role"
        )
    }
}

/// Projection storage rebuilds the status-pill snapshot only when the published monitor is stale
/// for the current tab; every changed transaction still posts its single owner-scoped notification.
@MainActor
final class AgentSessionLinkStatusPillSyncScopeTests: XCTestCase {
    private var retainedViewModels: [AgentModeViewModel] = []
    private var retainedWorkspaces: [WorkspaceManagerViewModel] = []

    override func tearDown() {
        retainedViewModels.removeAll()
        retainedWorkspaces.removeAll()
        super.tearDown()
    }

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let tabID: UUID
        let endpoint: DomainAgentSessionLinkEndpointIdentity
    }

    private func makeFixture() throws -> Fixture {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 83,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retainedViewModels.append(viewModel)
        retainedWorkspaces.append(AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Status pill sync scope"
        ))
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        _ = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(session),
            "expected a durable persistent binding"
        )
        let fixture = try Fixture(
            viewModel: viewModel,
            session: session,
            tabID: tabID,
            endpoint: AgentSessionLinkEndpointTestSupport.endpoint(viewModel, tabID: tabID)
        )
        XCTAssertEqual(viewModel.currentTabID, tabID)
        return fixture
    }

    /// An exact endpoint in the same window that is not the current tab.
    private func nonCurrentEndpoint(_ fixture: Fixture) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: fixture.endpoint.windowID,
            workspaceID: fixture.endpoint.workspaceID,
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 0
        )
    }

    private func props(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        outboundCount: Int = 1
    ) -> AgentMonitorPillProps {
        AgentMonitorPillProps(
            sessionID: endpoint.sessionID,
            sidebarOversightMenu: nil,
            outbound: (0 ..< outboundCount).map { index in
                let targetSessionID = UUID()
                return AgentMonitorPillProps.Outbound(
                    linkID: UUID(),
                    generation: UInt64(index + 1),
                    targetSessionID: targetSessionID,
                    targetEndpoint: AgentSessionLinkIdentityTestSupport.endpoint(
                        sessionID: targetSessionID
                    ),
                    displayName: "Target \(index)",
                    providerDisplayName: "Codex CLI",
                    locationLabel: "worktree/\(index)",
                    status: .idle
                )
            },
            inbound: [],
            recentNotices: [],
            canAddReason: nil
        )
    }

    private func observeNotifications(
        _ viewModel: AgentModeViewModel,
        onPost: @escaping () -> Void = {}
    ) -> (AnyCancellable, () -> Int) {
        var count = 0
        let cancellable = NotificationCenter.default.publisher(
            for: .agentSessionLinkOverseerProjectionDidChange,
            object: viewModel
        ).sink { _ in
            count += 1
            onPost()
        }
        return (cancellable, { count })
    }

    func testNonCurrentEndpointChangesSkipStatusPillRebuildButKeepOneNotificationEach() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        viewModel.agentSessionLinkPublishProjection(props(endpoint: fixture.endpoint), to: fixture.endpoint)
        let snapshotBefore = viewModel.ui.statusPills.snapshot
        let revisionBefore = viewModel.ui.statusPills.revision
        let (cancellable, notificationCount) = observeNotifications(viewModel)
        viewModel.test_statusPillsSnapshotBuildCount = 0

        let others = (0 ..< 3).map { _ in nonCurrentEndpoint(fixture) }
        for (index, endpoint) in others.enumerated() {
            viewModel.agentSessionLinkPublishProjection(props(endpoint: endpoint), to: endpoint)
            XCTAssertEqual(notificationCount(), index + 1)
        }
        // A second, different projection for an already stored non-current endpoint is also a
        // changed transaction that must notify without rebuilding.
        viewModel.agentSessionLinkPublishProjection(props(endpoint: others[0], outboundCount: 2), to: others[0])

        XCTAssertEqual(viewModel.test_statusPillsSnapshotBuildCount, 0)
        XCTAssertEqual(notificationCount(), others.count + 1)
        XCTAssertEqual(Set(viewModel.monitorPillPropsByEndpoint.keys), Set(others + [fixture.endpoint]))
        XCTAssertEqual(viewModel.ui.statusPills.snapshot, snapshotBefore)
        XCTAssertEqual(viewModel.ui.statusPills.revision, revisionBefore)
        withExtendedLifetime(cancellable) {}
    }

    func testCurrentEndpointChangeRebuildsOnceBeforeItsNotification() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let published = props(endpoint: fixture.endpoint, outboundCount: 2)
        var monitorAtNotification: AgentMonitorPillProps?
        let (cancellable, notificationCount) = observeNotifications(viewModel) {
            monitorAtNotification = viewModel.ui.statusPills.snapshot.monitor
        }
        viewModel.test_statusPillsSnapshotBuildCount = 0

        viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)

        XCTAssertEqual(viewModel.test_statusPillsSnapshotBuildCount, 1)
        XCTAssertEqual(notificationCount(), 1)
        var expected = viewModel.monitorPillPropsByEndpoint[fixture.endpoint]
        expected?.pendingUpdates = .empty
        XCTAssertNotNil(expected)
        XCTAssertEqual(monitorAtNotification, expected)
        XCTAssertEqual(monitorAtNotification?.outbound.count, 2)
        withExtendedLifetime(cancellable) {}
    }

    /// One queued status edge for the observer's first outbound row, as the passive reducer would
    /// publish it after a target transition.
    private func passiveSnapshot(
        observer: DomainAgentSessionLinkEndpointIdentity,
        row: AgentMonitorPillProps.Outbound
    ) -> AgentSessionLinkPassiveStatusNotices.Snapshot {
        let reference = DomainAgentSessionLinkReference(linkID: row.linkID, generation: row.generation)
        return AgentSessionLinkPassiveStatusNotices.Snapshot(
            observerEndpoint: observer,
            queueEpoch: UUID(),
            queueRevision: 1,
            linkSetRevision: 1,
            isEnabled: true,
            isDeliverable: true,
            entries: [
                AgentSessionLinkPassiveStatusNotices.PendingEntry(
                    reference: reference,
                    targetEndpoint: row.targetEndpoint,
                    targetSessionID: row.targetSessionID,
                    displayName: row.displayName,
                    fromStatus: .running,
                    toStatus: .idle,
                    observedAt: Date(timeIntervalSince1970: 0),
                    idleForSend: true,
                    latestVisibleAssistantPreview: "Done.",
                    changeSequence: 1,
                    edgeSequence: 1
                )
            ],
            attentionRequests: [],
            unacknowledgedOverflowCount: 0,
            overflowProduced: 0,
            autoWakeLanes: [
                AgentSessionLinkPassiveStatusNotices.AutoWakeLane(
                    reference: reference,
                    targetEndpoint: row.targetEndpoint,
                    targetSessionID: row.targetSessionID,
                    isEffectivelySelected: false
                )
            ]
        )
    }

    /// The pending-updates section is derived from the passive queue, which changes without any link
    /// projection change. Its own publication must refresh the on-screen observer's pill.
    func testPassiveNoticePublishForCurrentObserverRefreshesStatusPills() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        fixture.session.oversight.autoWakeOnUpdates = false
        let published = props(endpoint: fixture.endpoint)
        let row = try XCTUnwrap(published.outbound.first)
        viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)
        viewModel.test_flushPendingUIRefresh()
        let pendingBefore = viewModel.ui.statusPills.snapshot.monitor.pendingUpdates

        viewModel.agentSessionLinkPublishPassiveStatusNotices(
            passiveSnapshot(observer: fixture.endpoint, row: row),
            to: fixture.endpoint
        )
        viewModel.test_flushPendingUIRefresh()

        let fresh = viewModel.makeStatusPillsSnapshot()
        XCTAssertEqual(fresh.monitor.pendingUpdates?.updateCount, 1)
        XCTAssertNotEqual(fresh.monitor.pendingUpdates, pendingBefore)
        XCTAssertEqual(viewModel.ui.statusPills.snapshot, fresh)
    }

    /// Before projection-scoped syncing, an unrelated endpoint's projection change incidentally
    /// repaired a stale pending-updates section. The on-screen pill must not depend on that.
    func testPassiveNoticeFreshnessDoesNotDependOnUnrelatedProjectionChanges() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        fixture.session.oversight.autoWakeOnUpdates = false
        let published = props(endpoint: fixture.endpoint)
        let row = try XCTUnwrap(published.outbound.first)
        viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)

        viewModel.agentSessionLinkPublishPassiveStatusNotices(
            passiveSnapshot(observer: fixture.endpoint, row: row),
            to: fixture.endpoint
        )
        let other = nonCurrentEndpoint(fixture)
        viewModel.agentSessionLinkPublishProjection(props(endpoint: other), to: other)
        viewModel.test_flushPendingUIRefresh()

        XCTAssertEqual(viewModel.ui.statusPills.snapshot.monitor.pendingUpdates?.updateCount, 1)
        XCTAssertEqual(viewModel.ui.statusPills.snapshot, viewModel.makeStatusPillsSnapshot())
    }

    /// The notification contract: whenever projection storage changes, the published monitor is
    /// already current for anyone reading it from the notification — even when an independent
    /// current-tab presentation change (here a queued passive update) is still waiting on its own
    /// coalesced UI refresh.
    func testUnrelatedProjectionNotificationSeesQueuedCurrentObserverUpdate() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        fixture.session.oversight.autoWakeOnUpdates = false
        let published = props(endpoint: fixture.endpoint)
        let row = try XCTUnwrap(published.outbound.first)
        viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)
        viewModel.test_flushPendingUIRefresh()
        viewModel.agentSessionLinkPublishPassiveStatusNotices(
            passiveSnapshot(observer: fixture.endpoint, row: row),
            to: fixture.endpoint
        )
        var observed: (published: AgentMonitorPillProps, live: AgentMonitorPillProps)?
        let (cancellable, notificationCount) = observeNotifications(viewModel) {
            observed = (viewModel.ui.statusPills.snapshot.monitor, viewModel.currentMonitorPillProps())
        }

        let other = nonCurrentEndpoint(fixture)
        viewModel.agentSessionLinkPublishProjection(props(endpoint: other), to: other)

        XCTAssertEqual(notificationCount(), 1)
        let atNotification = try XCTUnwrap(observed)
        XCTAssertEqual(atNotification.live.pendingUpdates?.updateCount, 1)
        XCTAssertEqual(atNotification.published, atNotification.live)
        withExtendedLifetime(cancellable) {}
    }

    /// A rebind makes the tab's current incarnation one with no stored projection yet. A notification
    /// for an unrelated endpoint must not let the pill keep presenting the retired incarnation's rows.
    func testUnrelatedProjectionNotificationAfterRebindDoesNotExposeRetiredIncarnation() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        viewModel.agentSessionLinkPublishProjection(props(endpoint: fixture.endpoint), to: fixture.endpoint)
        viewModel.test_flushPendingUIRefresh()
        fixture.session.beginPersistentBindingTransition()
        let replacement = try AgentSessionLinkEndpointTestSupport.endpoint(viewModel, tabID: fixture.tabID)
        XCTAssertNotEqual(replacement, fixture.endpoint)
        var observed: (published: AgentMonitorPillProps, live: AgentMonitorPillProps)?
        let (cancellable, _) = observeNotifications(viewModel) {
            observed = (viewModel.ui.statusPills.snapshot.monitor, viewModel.currentMonitorPillProps())
        }

        let other = nonCurrentEndpoint(fixture)
        viewModel.agentSessionLinkPublishProjection(props(endpoint: other), to: other)

        let atNotification = try XCTUnwrap(observed)
        XCTAssertTrue(atNotification.live.outbound.isEmpty)
        XCTAssertEqual(atNotification.published, atNotification.live)
        withExtendedLifetime(cancellable) {}
    }

    func testStatusPillSnapshotStaysCurrentAcrossProjectionAndPolicyMutations() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let other = nonCurrentEndpoint(fixture)
        fixture.session.oversight.autoWakeOnUpdates = false

        func assertCurrent(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(
                viewModel.ui.statusPills.snapshot,
                viewModel.makeStatusPillsSnapshot(),
                "status pills stale after \(step)",
                file: file,
                line: line
            )
        }

        viewModel.agentSessionLinkPublishProjection(props(endpoint: fixture.endpoint), to: fixture.endpoint)
        assertCurrent("current endpoint publish")
        viewModel.agentSessionLinkPublishProjection(props(endpoint: other), to: other)
        assertCurrent("non-current endpoint publish")
        viewModel.agentSessionLinkPublishProjection(props(endpoint: other, outboundCount: 3), to: other)
        assertCurrent("non-current endpoint republish")
        XCTAssertTrue(viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(true, for: fixture.endpoint))
        assertCurrent("Auto-wake master write")
        XCTAssertTrue(viewModel.agentSessionLinkSetRoutineWakeInterval(
            enabled: true,
            seconds: 3600,
            for: fixture.endpoint
        ))
        assertCurrent("routine interval write")
        viewModel.agentSessionLinkApplyPersistencePresentation(
            AgentSessionOversightPersistencePresentation(availability: .ready)
        )
        assertCurrent("persistence presentation")
        viewModel.agentSessionLinkPublishProjection(
            props(endpoint: fixture.endpoint, outboundCount: 2),
            to: fixture.endpoint
        )
        assertCurrent("current endpoint republish")
        viewModel.agentSessionLinkPruneProjections()
        XCTAssertNil(viewModel.monitorPillPropsByEndpoint[other])
        XCTAssertNotNil(viewModel.monitorPillPropsByEndpoint[fixture.endpoint])
        assertCurrent("prune of non-current stale endpoint")
    }
}
