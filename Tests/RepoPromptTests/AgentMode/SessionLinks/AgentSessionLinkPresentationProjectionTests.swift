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
        fixture.session.autoWakeOnOversightUpdates = true
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
            XCTAssertEqual(fixture.viewModel.ui.statusPills.snapshot.monitor, stored)
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
