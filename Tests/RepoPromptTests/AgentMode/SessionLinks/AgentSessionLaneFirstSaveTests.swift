import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

@MainActor
final class AgentSessionLaneFirstSaveTests: XCTestCase {
    @MainActor
    private final class AdvertisementRecorder {
        var sessionIDs: [UUID] = []

        func record(_ sessionID: UUID) {
            sessionIDs.append(sessionID)
        }
    }

    private struct Fixture {
        let window: WindowState
        let root: URL
        let workspaceID: UUID
        let selection: AgentSessionLanePolicy.RoleSelection
    }

    private func withFixture(ephemeral: Bool = true, _ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-first-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
        if !ephemeral {
            UserDefaults.standard.set(root.appendingPathComponent("storage").path, forKey: "GlobalCustomStorageURL")
        }
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        let cleanup: @MainActor () async -> Void = {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            if !ephemeral {
                await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
                if let previousStoragePath {
                    UserDefaults.standard.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            await window.workspaceManager.awaitInitialized()
            let workspace = window.workspaceManager.createWorkspace(
                name: "Lane first save \(UUID().uuidString.prefix(8))",
                repoPaths: [root.path], ephemeral: ephemeral
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace, saveState: false, reason: "laneFirstSaveTest"
            )
            let selection = try AgentSessionLanePolicy.resolveRole(
                "pair", availability: .current, workspaceID: workspace.id
            )
            try await body(Fixture(
                window: window, root: root, workspaceID: workspace.id, selection: selection
            ))
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    /// Model denied-role ownership at the property boundary: public MCP activation correctly
    /// refuses to capture an app-owned linked overseer. These races test proof revocation and
    /// rollback, not capture admission; the production didSet and release path still run.
    private func installDeniedRoleControlFixture(on session: AgentTabSession, sessionID: UUID) async {
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        session.mcpControlContext = AgentModeViewModel.AgentMCPControlContext(
            sessionID: sessionID, activationID: UUID(), registration: registration,
            currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil,
            originatingConnectionID: nil,
            interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
            suppressUserNotifications: true, forceAutoEditEnabled: false,
            autoEditEnabledBeforeOverride: session.autoEditEnabled, taskLabelKind: .explore
        )
    }

    /// Routes activation retirement to a local recorder, so tests that drive activation without
    /// attaching their own bridge never notify the shared production bridge. Install inside the
    /// fixture body: window registration re-attaches the production bridge. Restore the result.
    private func installLocalRetirementSink(_ recorder: AdvertisementRecorder) -> ((UUID) -> Void)? {
        let previous = AgentSessionLinkInvalidationSink.overseerActivationRetired
        AgentSessionLinkInvalidationSink.overseerActivationRetired = { recorder.record($0) }
        return previous
    }

    private func withSecondRegisteredWindow(_ body: (WindowState) async throws -> Void) async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        do {
            await window.workspaceManager.awaitInitialized()
            try await body(window)
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            throw error
        }
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
    }

    func testFreshForegroundSessionPublishesToolbarEligibilityAfterConfiguredSave() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let host = WindowStatesManager.shared
            let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
                runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()
            ))
            let bridge = AgentSessionLinkRuntimeBridge(
                authority: authority, host: host, toolAdvertisementInvalidator: { _ in }
            )
            let retirements = AdvertisementRecorder()
            let previousRetirementSink = installLocalRetirementSink(retirements)
            defer {
                viewModel.test_afterFreshForegroundSessionCreation = nil
                AgentSessionLinkInvalidationSink.overseerActivationRetired = previousRetirementSink
            }
            var preparingSnapshot: AgentMonitorPillProps?
            viewModel.test_afterFreshForegroundSessionCreation = { handle in
                XCTAssertTrue(handle.session.qualifiedRestorationReadiness.isCreating)
                XCTAssertEqual(viewModel.currentTabID, handle.session.tabID)
                // Model the foreground publication while the new tab's first save is pending.
                // No explicit UI refresh is allowed after persistence acknowledges readiness.
                viewModel.applySessionToBindings(handle.session)
                preparingSnapshot = viewModel.ui.statusPills.snapshot.monitor
            }

            let createdTabID = await viewModel.createAndActivateSessionTab()
            let tabID = try XCTUnwrap(createdTabID)
            let session = try XCTUnwrap(viewModel.sessions[tabID])
            let sessionID = try XCTUnwrap(session.activeAgentSessionID)
            let preparing = try XCTUnwrap(preparingSnapshot)
            XCTAssertNil(preparing.overseerBootstrapState)
            XCTAssertNotNil(preparing.canAddReason)
            guard case .authoritative(_, .freshBindingDurablyCreated) = session.qualifiedRestorationReadiness else {
                return XCTFail("The foreground session must earn readiness from its configured first save")
            }
            // Capture before another suspension can incidentally repaint the toolbar.
            let rendered = viewModel.ui.statusPills.snapshot.monitor
            XCTAssertEqual(rendered, viewModel.currentMonitorPillProps(), "The toolbar cannot retain the pre-save loading snapshot")
            let endpoint = try XCTUnwrap(rendered.endpoint)
            let expected = try XCTUnwrap(rendered.overseerBootstrapState)
            XCTAssertNil(expected.activation)
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let payload = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: workspace)
            XCTAssertEqual(payload?.id, sessionID)
            XCTAssertEqual(payload?.toLiveItems(), [])
            let enabled = await bridge.enableOverseerFromToolbar(
                endpoint: endpoint, expected: expected, isEnabled: { true }
            )
            XCTAssertTrue(enabled)
            XCTAssertNotNil(viewModel.ui.statusPills.snapshot.monitor.overseerBootstrapState?.activation)
            XCTAssertFalse(viewModel.ui.statusPills.snapshot.monitor.isOverseer)
            XCTAssertNil(session.oversight.pendingAutoWake)
            XCTAssertNil(session.runID)
            XCTAssertTrue(session.items.isEmpty)
            let links = await authority.links(forObserver: sessionID)
            XCTAssertTrue(links.items.isEmpty, "Toolbar consent must not manufacture oversight grants")
        }
    }

    func testToolbarActivatedNoLinkCreatorDurablyCreatesFirstLaneInAnotherWindowWorkspace() async throws {
        try await exerciseActivatedFirstLaneFromAnotherWindow(toolbar: true)
    }

    func testActivatedNoLinkCreatorDurablyCreatesFirstLaneInAnotherWindowWorkspace() async throws {
        try await exerciseActivatedFirstLaneFromAnotherWindow(toolbar: false)
    }

    private func exerciseActivatedFirstLaneFromAnotherWindow(toolbar: Bool) async throws {
        try await withFixture(ephemeral: false) { fixture in
            let host = WindowStatesManager.shared
            let creatorOutcome = try await host.agentSessionLinkCreateLane(destinationWindowID: fixture.window.windowID, workspaceID: fixture.workspaceID, creatorSessionID: UUID(), sessionName: "Ordinary creator", selection: fixture.selection)
            guard case let .created(creatorID, creatorTabID, _) = creatorOutcome else { return XCTFail("creator seed must save") }
            let creator = try XCTUnwrap(fixture.window.agentModeViewModel.sessions[creatorTabID])
            creator.createdByOverseerSessionID = nil
            let endpoint = try XCTUnwrap(host.agentSessionLinkCandidates().first { $0.sessionID == creatorID }).domainEndpoint
            let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()))
            let bridge = AgentSessionLinkRuntimeBridge(authority: authority, host: host, toolAdvertisementInvalidator: { _ in })
            bridge.installIntentStore(AgentSessionOversightIntentStore(fileURL: fixture.root.appendingPathComponent(AgentSessionOversightIntentStore.filename), backupsDirectoryURL: fixture.root.appendingPathComponent("Backups"), mode: .enabled))
            let viewModel = fixture.window.agentModeViewModel
            viewModel.test_setCurrentTabIDOverride(creatorTabID)
            defer { viewModel.test_setCurrentTabIDOverride(nil) }
            let before = viewModel.currentMonitorPillProps()
            let expected = try XCTUnwrap(before.overseerBootstrapState)
            XCTAssertNil(expected.activation)
            let denied = await bridge.laneCreationCallerPreflight(endpoint)
            XCTAssertEqual(denied, .denied, "zero links alone do not authorize creation")
            let activated: Bool = if toolbar {
                await bridge.enableOverseerFromToolbar(endpoint: endpoint, expected: expected, isEnabled: { true })
            } else {
                await bridge.becomeOverseer(endpoint: endpoint, isEnabled: { true }, revalidateRoute: { true }, commitIfCurrent: { $0() }) != nil
            }
            XCTAssertTrue(activated)
            let enabled = viewModel.ui.statusPills.snapshot.monitor
            XCTAssertNotNil(enabled.overseerBootstrapState?.activation, "commit publishes the dashboard immediately")
            XCTAssertFalse(enabled.isOverseer, "activation is not an outbound role badge")
            XCTAssertNil(enabled.dashboardOutboundCount)
            XCTAssertNil(enabled.dashboardInboundCount)
            XCTAssertNil(creator.oversight.pendingAutoWake, "consent cannot start a turn")
            let noLinks = await authority.links(forObserver: creatorID)
            XCTAssertTrue(noLinks.items.isEmpty, "consent manufactures no grants")
            AgentAdvertisedModelCatalog.shared.record([
                AgentModelOption(rawValue: "sonnet:high", displayName: "Fixture model", description: nil, isPlaceholderDefault: false, isProviderDefault: false)
            ], for: .claudeCode, generation: AgentAdvertisedModelCatalog.shared.productionGeneration(for: .claudeCode))
            defer { AgentAdvertisedModelCatalog.shared.invalidate(.claudeCode) }
            try await withSecondRegisteredWindow { destinationWindow in
                // Simulate only the destination's published CLI-availability input; never run a provider.
                destinationWindow.apiSettingsViewModel.isClaudeCodeConnected = true
                try await AsyncTestWait.waitUntil("fixture destination model availability") {
                    destinationWindow.apiSettingsViewModel.agentAvailability.claudeCodeAvailable
                }
                let workspace = destinationWindow.workspaceManager.createWorkspace(name: "Other destination", repoPaths: [fixture.root.path], ephemeral: false)
                await destinationWindow.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "activatedFirstLaneTest")
                let request = AgentSessionLaneCreateRequest(idempotencyKey: "real-first-lane", role: nil, modelID: "claudeCode:sonnet:high", sessionName: "Activated first lane", workspaceSelector: workspace.id.uuidString, message: nil, workflowReference: nil)
                let receipt = await bridge.createLane(observerEndpoint: endpoint, request: request, resolveDestination: { (destinationWindow.windowID, workspace.id, workspace.name) })
                XCTAssertEqual(receipt.result, .created, "\(receipt)")
                XCTAssertTrue(receipt.linked)
                let laneID = try XCTUnwrap(receipt.sessionID)
                let lane = try XCTUnwrap(host.agentSessionLinkCandidates().first { $0.sessionID == laneID })
                XCTAssertEqual(lane.windowID, destinationWindow.windowID)
                XCTAssertEqual(lane.workspaceID, workspace.id)
                XCTAssertTrue(lane.restorationReadiness.isAuthoritative)
                let payload = try await AgentSessionDataService.shared.loadAgentSession(id: laneID, for: workspace)
                XCTAssertEqual(payload?.createdByOverseerSessionID, creatorID)
                let inventory = await authority.links(forObserver: creatorID)
                XCTAssertEqual(inventory.items.map(\.targetSessionID), [laneID])
                XCTAssertEqual(fixture.window.workspaceManager.activeWorkspaceID, fixture.workspaceID, "creation never switches the creator workspace")
            }
        }
    }

    func testFailedRouteRetiresZeroLinkActivationPresentationAndAdvertisement() async throws {
        try await exerciseFailedRouteSettlement(activated: true)
    }

    func testFailedRouteRefreshesNeverActivatedZeroLinkPillEndpoint() async throws {
        try await exerciseFailedRouteSettlement(activated: false)
    }

    private func exerciseFailedRouteSettlement(activated: Bool) async throws {
        try await withFixture(ephemeral: false) { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let seed = try await host.agentSessionLinkCreateLane(
                destinationWindowID: fixture.window.windowID, workspaceID: fixture.workspaceID,
                creatorSessionID: UUID(), sessionName: "Failed route consent", selection: fixture.selection
            )
            guard case let .created(sessionID, tabID, _) = seed else { return XCTFail("seed must save") }
            let session = try XCTUnwrap(viewModel.sessions[tabID])
            session.createdByOverseerSessionID = nil
            viewModel.test_setCurrentTabIDOverride(tabID)
            defer { viewModel.test_setCurrentTabIDOverride(nil) }
            let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: tabID))
            let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
                runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()
            ))
            let invalidated = AdvertisementRecorder()
            let bridge = AgentSessionLinkRuntimeBridge(
                authority: authority, host: host, toolAdvertisementInvalidator: { await invalidated.record($0) }
            )
            bridge.attach(host: host)
            defer { host.attachAgentSessionLinkBridge() }
            if activated {
                let expected = try XCTUnwrap(viewModel.agentSessionLinkBootstrapState(for: endpoint))
                let enabled = await bridge.enableOverseerFromToolbar(endpoint: endpoint, expected: expected, isEnabled: { true })
                XCTAssertTrue(enabled)
                XCTAssertNotNil(viewModel.ui.statusPills.snapshot.monitor.overseerBootstrapState?.activation)
                invalidated.sessionIDs.removeAll()
            } else {
                viewModel.syncStatusPillsUIState()
                XCTAssertEqual(viewModel.ui.statusPills.snapshot.monitor.endpoint, endpoint)
            }
            // Counted for this session only: the fresh authority holds no links, so no revocation or
            // readiness reconciliation should notify anything else, but those are not under test here.
            let retirements = { invalidated.sessionIDs.count { $0 == sessionID } }
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let result = await viewModel.activateRoutedAgentSession(tabID: tabID, sessionID: UUID(), workspace: workspace)
            XCTAssertEqual(result, .sessionNotFound)
            XCTAssertEqual(session.activeAgentSessionID, sessionID, "failed route leaves the same session on screen")
            XCTAssertFalse(session.bindingTransitionInProgress)
            XCTAssertTrue(session.permitsBoundOperationAndSave, "The failed route must leave the original saved session usable.")
            XCTAssertNil(session.operationAdmissionFailureMessage)
            XCTAssertNil(session.oversight.overseerActivation)
            let saveResult = await viewModel.flushSaveRequired(for: tabID, workspaceID: fixture.workspaceID)
            guard case .success = saveResult else { return XCTFail("The unchanged session must remain saveable: \(saveResult)") }
            if activated {
                try await AsyncTestWait.waitUntil("retired advertisement", timeout: 10) { retirements() == 1 }
            }
            let currentEndpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: tabID))
            XCTAssertNotEqual(currentEndpoint, endpoint)
            let settledBootstrapState = AgentSessionOverseerBootstrapState(
                sessionIdentity: ObjectIdentifier(session), provider: session.selectedAgent, activation: nil
            )
            // The settlement repaint is deferred past the enclosing mutation. A mid-transition
            // repaint can already show the new endpoint without a bootstrap state, so wait for both.
            try await AsyncTestWait.waitUntil("settled pill endpoint and bootstrap state", timeout: 10) {
                let monitor = viewModel.ui.statusPills.snapshot.monitor
                return monitor.endpoint == currentEndpoint && monitor.overseerBootstrapState == settledBootstrapState
            }
            XCTAssertEqual(retirements(), activated ? 1 : 0, "one retirement per activation, never a settlement replay")
            let monitor = viewModel.ui.statusPills.snapshot.monitor
            XCTAssertFalse(monitor.isOverseer)
            XCTAssertTrue(monitor.outbound.isEmpty)
            XCTAssertNil(session.oversight.pendingAutoWake)
            let inventory = await authority.links(forObserver: sessionID)
            XCTAssertTrue(inventory.items.isEmpty)
            let staleCall = await bridge.laneCreationCallerPreflight(endpoint)
            let freshCall = await bridge.laneCreationCallerPreflight(currentEndpoint)
            XCTAssertEqual(staleCall, .denied)
            XCTAssertEqual(freshCall, .denied, "authority already failed closed before this publication repair")
        }
    }

    func testToolbarActivationRejectsAlreadyLinkedIncarnationDespiteStaleDashboard() async throws {
        for inbound in [false, true] {
            try await withFixture(ephemeral: false) { fixture in
                let host = WindowStatesManager.shared
                let viewModel = fixture.window.agentModeViewModel
                var seedIDs: [UUID] = []
                for _ in 0 ..< 2 {
                    let seed = try await host.agentSessionLinkCreateLane(
                        destinationWindowID: fixture.window.windowID, workspaceID: fixture.workspaceID,
                        creatorSessionID: UUID(), sessionName: "Linked consent", selection: fixture.selection
                    )
                    guard case let .created(sessionID, tabID, _) = seed else { return XCTFail("seed must save") }
                    viewModel.sessions[tabID]?.createdByOverseerSessionID = nil
                    seedIDs.append(sessionID)
                }
                let endpoint = try XCTUnwrap(host.agentSessionLinkCandidates().first { $0.sessionID == seedIDs[0] }).domainEndpoint
                let expected = try XCTUnwrap(viewModel.agentSessionLinkBootstrapState(for: endpoint))
                let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
                    runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()
                ))
                let invalidated = AdvertisementRecorder()
                let bridge = AgentSessionLinkRuntimeBridge(authority: authority, host: host, toolAdvertisementInvalidator: { await invalidated.record($0) })
                bridge.installIntentStore(AgentSessionOversightIntentStore(
                    fileURL: fixture.root.appendingPathComponent(AgentSessionOversightIntentStore.filename),
                    backupsDirectoryURL: fixture.root.appendingPathComponent("Backups"), mode: .enabled
                ))
                let pair = AgentSessionOversightIntent(
                    observerSessionID: seedIDs[inbound ? 1 : 0], targetSessionID: seedIDs[inbound ? 0 : 1]
                )
                guard case .added = await bridge.addMonitorLink(pair: pair) else { return XCTFail("real link must activate") }
                invalidated.sessionIDs.removeAll()
                let enabled = await bridge.enableOverseerFromToolbar(endpoint: endpoint, expected: expected, isEnabled: { true })
                XCTAssertFalse(enabled, "a lagging dashboard cannot opt in an already linked incarnation")
                XCTAssertNil(viewModel.agentSessionLinkBootstrapState(for: endpoint)?.activation)
                XCTAssertTrue(invalidated.sessionIDs.isEmpty)
            }
        }
    }

    func testToolbarActivationRejectsDisabledStaleAndIneligibleIncarnations() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let retired = AdvertisementRecorder()
            let previousRetiredSink = self.installLocalRetirementSink(retired)
            defer { AgentSessionLinkInvalidationSink.overseerActivationRetired = previousRetiredSink }
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let seed = try await host.agentSessionLinkCreateLane(
                destinationWindowID: fixture.window.windowID, workspaceID: fixture.workspaceID,
                creatorSessionID: UUID(), sessionName: "Toolbar consent", selection: fixture.selection
            )
            guard case let .created(sessionID, tabID, _) = seed else { return XCTFail("seed must save") }
            let session = try XCTUnwrap(viewModel.sessions[tabID])
            session.createdByOverseerSessionID = nil
            let endpoint = try XCTUnwrap(host.agentSessionLinkCandidates().first { $0.sessionID == sessionID }).domainEndpoint
            let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
                runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()
            ))
            let invalidated = AdvertisementRecorder()
            let bridge = AgentSessionLinkRuntimeBridge(authority: authority, host: host, toolAdvertisementInvalidator: { await invalidated.record($0) })
            let expected = try XCTUnwrap(viewModel.agentSessionLinkBootstrapState(for: endpoint))
            let disabled = await bridge.enableOverseerFromToolbar(endpoint: endpoint, expected: expected, isEnabled: { false })
            XCTAssertFalse(disabled)
            XCTAssertNil(session.oversight.overseerActivation)
            XCTAssertTrue(invalidated.sessionIDs.isEmpty)
            for exclusion in ["mcp-origin", "child", "lane", "mcp-control"] {
                switch exclusion {
                case "mcp-origin": session.isMCPOriginated = true
                case "child": session.parentSessionID = UUID()
                case "lane": session.createdByOverseerSessionID = UUID()
                default: await self.installDeniedRoleControlFixture(on: session, sessionID: sessionID)
                }
                let refused = await bridge.enableOverseerFromToolbar(endpoint: endpoint, expected: expected, isEnabled: { true })
                XCTAssertFalse(refused, exclusion)
                XCTAssertNil(session.oversight.overseerActivation, exclusion)
                session.isMCPOriginated = false
                session.parentSessionID = nil
                session.createdByOverseerSessionID = nil
                if session.mcpControlContext != nil {
                    await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
                }
            }
            let enabled = await bridge.enableOverseerFromToolbar(endpoint: endpoint, expected: expected, isEnabled: { true })
            XCTAssertTrue(enabled)
            XCTAssertEqual(invalidated.sessionIDs, [sessionID])
            let activation = try XCTUnwrap(session.oversight.overseerActivation)
            let stale = await bridge.enableOverseerFromToolbar(endpoint: endpoint, expected: expected, isEnabled: { true })
            XCTAssertFalse(stale, "displayed pre-activation state is a CAS, not reusable consent")
            XCTAssertEqual(session.oversight.overseerActivation, activation)
            XCTAssertEqual(invalidated.sessionIDs, [sessionID])
            XCTAssertTrue(retired.sessionIDs.isEmpty, "refusals and a live activation retire nothing")
            session.beginPersistentBindingTransition()
            XCTAssertEqual(retired.sessionIDs, [sessionID], "rebind retires the activation once, synchronously")
            let rebound = await bridge.enableOverseerFromToolbar(endpoint: endpoint, expected: expected, isEnabled: { true })
            XCTAssertFalse(rebound)
            XCTAssertNil(session.oversight.overseerActivation)
            XCTAssertEqual(invalidated.sessionIDs, [sessionID])
            XCTAssertEqual(retired.sessionIDs, [sessionID])
            let inventory = await authority.links(forObserver: sessionID)
            XCTAssertTrue(inventory.items.isEmpty)
        }
    }

    func testPendingActivatedFirstLaneCannotAuthorizeNestedLaneAfterControlRelease() async throws {
        try await exerciseNestedCreationAfterControlRelease(independentDirection: nil)
    }

    func testPendingFirstLaneRollbackPreservesIndependentExactInboundAndOutboundGrants() async throws {
        for direction in ["inbound", "outbound"] {
            try await exerciseNestedCreationAfterControlRelease(independentDirection: direction)
        }
    }

    func testIndependentGrantSampleRejectsRolledBackBootstrapGeneration() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let seed = try await host.agentSessionLinkCreateLane(
                destinationWindowID: fixture.window.windowID, workspaceID: fixture.workspaceID,
                creatorSessionID: UUID(), sessionName: "ABA caller", selection: fixture.selection
            )
            guard case let .created(creatorID, creatorTabID, _) = seed else { return XCTFail("creator seed must save") }
            let creator = try XCTUnwrap(viewModel.sessions[creatorTabID])
            creator.createdByOverseerSessionID = nil
            let endpoint = try XCTUnwrap(host.agentSessionLinkCandidates().first { $0.sessionID == creatorID }).domainEndpoint
            let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
                runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()
            ))
            let bridge = AgentSessionLinkRuntimeBridge(authority: authority, host: host, toolAdvertisementInvalidator: { _ in })
            let store = AgentSessionOversightIntentStore(
                fileURL: fixture.root.appendingPathComponent(AgentSessionOversightIntentStore.filename),
                backupsDirectoryURL: fixture.root.appendingPathComponent("Backups"), mode: .enabled
            )
            bridge.attach(host: host)
            defer {
                bridge.freezeForTermination()
                AgentSessionLinkRuntimeBridge.shared.attach(host: host)
            }
            await bridge.bootstrapIntentStore(store)
            await bridge.test_settleLaunchReconciliation()
            AgentAdvertisedModelCatalog.shared.record([
                AgentModelOption(rawValue: "sonnet:high", displayName: "Fixture model", description: nil, isPlaceholderDefault: false, isProviderDefault: false)
            ], for: .claudeCode, generation: AgentAdvertisedModelCatalog.shared.productionGeneration(for: .claudeCode))
            defer { AgentAdvertisedModelCatalog.shared.invalidate(.claudeCode) }
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            try await AsyncTestWait.waitUntil("ABA creation model availability") {
                fixture.window.apiSettingsViewModel.agentAvailability.claudeCodeAvailable
            }
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let start: (String) -> Task<AgentSessionLaneCreateReceipt, Never> = { key in
                Task { @MainActor in
                    await bridge.createLane(
                        observerEndpoint: endpoint,
                        request: AgentSessionLaneCreateRequest(idempotencyKey: key, role: nil, modelID: "claudeCode:sonnet:high", sessionName: key, workspaceSelector: workspace.id.uuidString, message: nil, workflowReference: nil),
                        resolveDestination: { (fixture.window.windowID, workspace.id, workspace.name) }
                    )
                }
            }
            let consumeActivation: @MainActor () async throws -> Void = {
                await self.installDeniedRoleControlFixture(on: creator, sessionID: creatorID)
                XCTAssertNil(creator.oversight.overseerActivation)
                await bridge.test_auditObserverEligibility()
                await bridge.test_settleLaunchReconciliation()
                await viewModel.mcpDeactivateControlContext(sessionID: creatorID, cleanupSessionStore: true)
                let returned = try XCTUnwrap(viewModel.agentSessionLinkBootstrapState(for: endpoint))
                XCTAssertNil(returned.activation, "real role release cannot restore an old opt-in")
            }
            let optIn: @MainActor () async throws -> AgentSessionOverseerActivation = {
                let noLink = await authority.hasActiveLink(endpoint: endpoint)
                XCTAssertFalse(noLink, "each explicit opt-in must occur after all prior relationships are gone")
                let result = await bridge.becomeOverseer(endpoint: endpoint, isEnabled: { true }, revalidateRoute: { true }, commitIfCurrent: { $0() })
                XCTAssertNotNil(result, "use the real bootstrap eligibility/authority gates, not a stored-state assignment")
                return try XCTUnwrap(creator.oversight.overseerActivation)
            }
            let parked = (0 ..< 3).map { XCTestExpectation(description: "activation-backed A\($0) is indexed and parked") }
            var pairs: [AgentSessionOversightIntent] = []
            var releases: [Int: CheckedContinuation<Void, Never>] = [:]
            var tasks: [Task<AgentSessionLaneCreateReceipt, Never>] = []
            bridge.test_afterActivationBeforeDeletionFence = { pair in
                guard pairs.count < 3 else { return }
                let index = pairs.count
                pairs.append(pair)
                await withCheckedContinuation { continuation in
                    releases[index] = continuation
                    parked[index].fulfill()
                }
            }
            var releaseInvocation: CheckedContinuation<Void, Never>?
            var releaseResponse: CheckedContinuation<Void, Never>?
            let invocationParked = XCTestExpectation(description: "B captured A0's exclusion set before actor execution")
            let responseParked = XCTestExpectation(description: "real authority sample returned A1 before B consumes it")
            var sampled: DomainAgentSessionLinkGrant?
            bridge.test_beforeLaneCreationIndependentGrantSample = { excluded in
                bridge.test_beforeLaneCreationIndependentGrantSample = nil
                XCTAssertEqual(excluded.count, 1)
                XCTAssertEqual(excluded.first?.sessionID, pairs.first?.targetSessionID)
                await withCheckedContinuation { continuation in
                    releaseInvocation = continuation
                    invocationParked.fulfill()
                }
            }
            bridge.test_afterLaneCreationIndependentGrantSample = { grant in
                bridge.test_afterLaneCreationIndependentGrantSample = nil
                sampled = grant
                await withCheckedContinuation { continuation in
                    releaseResponse = continuation
                    responseParked.fulfill()
                }
            }
            do {
                var activations = try await [optIn()]
                let a0 = start("ABA-A0")
                tasks.append(a0)
                await fulfillment(of: [parked[0]], timeout: 10)
                try await consumeActivation()
                let b = start("ABA-B")
                tasks.append(b)
                await fulfillment(of: [invocationParked], timeout: 10)
                releases.removeValue(forKey: 0)?.resume()
                let receipt0 = await a0.value
                XCTAssertFalse(receipt0.linked)
                XCTAssertEqual(receipt0.reason, .addFailed)
                try await activations.append(optIn())
                let a1 = start("ABA-A1")
                tasks.append(a1)
                await fulfillment(of: [parked[1]], timeout: 10)
                try await consumeActivation()
                let illegalOptIn = await bridge.becomeOverseer(endpoint: endpoint, isEnabled: { true }, revalidateRoute: { true }, commitIfCurrent: { $0() })
                XCTAssertNil(illegalOptIn, "a new opt-in is correctly refused while provisional A1 is still indexed")
                releaseInvocation?.resume()
                releaseInvocation = nil
                await fulfillment(of: [responseParked], timeout: 10)
                let sample = try XCTUnwrap(sampled)
                XCTAssertEqual(sample.target.sessionID, pairs[1].targetSessionID, "actual domain sample is provisional A1, not a fabricated independent grant")
                XCTAssertEqual(sample.observer, endpoint)
                releases.removeValue(forKey: 1)?.resume()
                let receipt1 = await a1.value
                XCTAssertFalse(receipt1.linked)
                XCTAssertEqual(receipt1.reason, .addFailed)
                let staleSample = await authority.activeGrant(for: DomainAgentSessionLinkReference(linkID: sample.id, generation: sample.generation))
                XCTAssertNil(staleSample, "A1's sampled exact generation is revoked before B resumes")
                try await activations.append(optIn())
                XCTAssertEqual(Set(activations.map(\.token)).count, 3)
                XCTAssertTrue(activations.allSatisfy { $0.endpoint == endpoint }, "the ABA uses the same session incarnation")
                let a2 = start("ABA-A2")
                tasks.append(a2)
                await fulfillment(of: [parked[2]], timeout: 10)
                try await consumeActivation()
                let beforeB = await authority.links(forObserverEndpoint: endpoint)
                XCTAssertEqual(beforeB.items.map(\.targetSessionID), [pairs[2].targetSessionID], "only unsettled A2 exists; there was never a settled independent grant")
                let freshSettlement = XCTestExpectation(description: "B resamples and waits for current A2 instead of promoting stale A1")
                freshSettlement.assertForOverFulfill = true
                bridge.test_beforeLaneCreationBootstrapSettlement = { freshSettlement.fulfill() }
                releaseResponse?.resume()
                releaseResponse = nil
                await fulfillment(of: [freshSettlement], timeout: 10)
                let whileBWaits = await authority.links(forObserverEndpoint: endpoint)
                XCTAssertEqual(whileBWaits.items.map(\.targetSessionID), [pairs[2].targetSessionID], "B cannot allocate/index while its only current basis is unsettled A2")
                releases.removeValue(forKey: 2)?.resume()
                let receipt2 = await a2.value
                XCTAssertFalse(receipt2.linked)
                XCTAssertEqual(receipt2.reason, .addFailed)
                let receiptB = await b.value
                XCTAssertEqual(receiptB.result, .refused)
                XCTAssertEqual(receiptB.reason, .denied)
                XCTAssertFalse(receiptB.linked)
                XCTAssertNil(receiptB.sessionID, "no lane may be allocated from stale A1 or provisional A2")
                let afterRollback = await authority.links(forObserverEndpoint: endpoint)
                XCTAssertTrue(afterRollback.items.isEmpty)
                for pair in pairs {
                    let token = await store.token(for: pair)
                    XCTAssertNil(token)
                }
                print("P1_ABA_REGRESSION: real opt-ins=3; sampled A1 stale=true; B result=\(receiptB.result) reason=\(String(describing: receiptB.reason)) linked=\(receiptB.linked); A0/A1/A2 addFailed; final relationships=\(afterRollback.items.count); B allocated=\(receiptB.sessionID != nil)")
            } catch {
                bridge.test_beforeLaneCreationIndependentGrantSample = nil
                bridge.test_afterLaneCreationIndependentGrantSample = nil
                bridge.test_afterActivationBeforeDeletionFence = nil
                bridge.test_beforeLaneCreationBootstrapSettlement = nil
                releaseInvocation?.resume()
                releaseResponse?.resume()
                for release in releases.values {
                    release.resume()
                }
                for task in tasks {
                    _ = await task.value
                }
                throw error
            }
            bridge.test_beforeLaneCreationIndependentGrantSample = nil
            bridge.test_afterLaneCreationIndependentGrantSample = nil
            bridge.test_afterActivationBeforeDeletionFence = nil
            bridge.test_beforeLaneCreationBootstrapSettlement = nil
        }
    }

    func testIndependentGrantSampleResamplesAcrossActivationBackedEntryMutations() async throws {
        for inserting in [true, false] {
            try await withFixture(ephemeral: false) { fixture in
                let host = WindowStatesManager.shared
                let viewModel = fixture.window.agentModeViewModel
                let seed = try await host.agentSessionLinkCreateLane(
                    destinationWindowID: fixture.window.windowID, workspaceID: fixture.workspaceID,
                    creatorSessionID: UUID(), sessionName: "Lifecycle caller", selection: fixture.selection
                )
                guard case let .created(creatorID, creatorTabID, _) = seed else { return XCTFail("creator seed must save") }
                let creator = try XCTUnwrap(viewModel.sessions[creatorTabID])
                creator.createdByOverseerSessionID = nil
                let endpoint = try XCTUnwrap(host.agentSessionLinkCandidates().first { $0.sessionID == creatorID }).domainEndpoint
                let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
                    runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()
                ))
                let bridge = AgentSessionLinkRuntimeBridge(authority: authority, host: host, toolAdvertisementInvalidator: { _ in })
                let store = AgentSessionOversightIntentStore(
                    fileURL: fixture.root.appendingPathComponent(AgentSessionOversightIntentStore.filename),
                    backupsDirectoryURL: fixture.root.appendingPathComponent("Backups"), mode: .enabled
                )
                bridge.attach(host: host)
                defer {
                    bridge.freezeForTermination()
                    AgentSessionLinkRuntimeBridge.shared.attach(host: host)
                }
                await bridge.bootstrapIntentStore(store)
                await bridge.test_settleLaunchReconciliation()
                AgentAdvertisedModelCatalog.shared.record([
                    AgentModelOption(rawValue: "sonnet:high", displayName: "Fixture model", description: nil, isPlaceholderDefault: false, isProviderDefault: false)
                ], for: .claudeCode, generation: AgentAdvertisedModelCatalog.shared.productionGeneration(for: .claudeCode))
                defer { AgentAdvertisedModelCatalog.shared.invalidate(.claudeCode) }
                fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
                try await AsyncTestWait.waitUntil("entry lifecycle model availability") {
                    fixture.window.apiSettingsViewModel.agentAvailability.claudeCodeAvailable
                }
                let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
                let independentSeed = try await host.agentSessionLinkCreateLane(
                    destinationWindowID: fixture.window.windowID, workspaceID: fixture.workspaceID,
                    creatorSessionID: UUID(), sessionName: "Independent stable lane", selection: fixture.selection
                )
                guard case let .created(independentID, _, _) = independentSeed else { return XCTFail("independent seed must save") }
                let optIn = await bridge.becomeOverseer(endpoint: endpoint, isEnabled: { true }, revalidateRoute: { true }, commitIfCurrent: { $0() })
                XCTAssertNotNil(optIn, "one real no-link activation backs both owned creations")
                let start: (String) -> Task<AgentSessionLaneCreateReceipt, Never> = { key in
                    Task { @MainActor in
                        await bridge.createLane(
                            observerEndpoint: endpoint,
                            request: AgentSessionLaneCreateRequest(idempotencyKey: key, role: nil, modelID: "claudeCode:sonnet:high", sessionName: key, workspaceSelector: workspace.id.uuidString, message: nil, workflowReference: nil),
                            resolveDestination: { (fixture.window.windowID, workspace.id, workspace.name) }
                        )
                    }
                }
                let parked = XCTestExpectation(description: "A0 indexed before sample")
                let otherParked = XCTestExpectation(description: inserting ? "A1 assigned and saved before entry insertion" : "A1 indexed before sample")
                var firstPair: AgentSessionOversightIntent?
                var otherPair: AgentSessionOversightIntent?
                var releaseFirst: CheckedContinuation<Void, Never>?
                var releaseOther: CheckedContinuation<Void, Never>?
                var releaseMutation: CheckedContinuation<Void, Never>?
                var releaseSample: CheckedContinuation<Void, Never>?
                bridge.test_afterActivationBeforeDeletionFence = { pair in
                    if firstPair == nil {
                        firstPair = pair
                        await withCheckedContinuation { releaseFirst = $0
                            parked.fulfill()
                        }
                    } else if !inserting, otherPair == nil {
                        otherPair = pair
                        await withCheckedContinuation { releaseOther = $0
                            otherParked.fulfill()
                        }
                    }
                }
                let a0 = start("Lifecycle-A0")
                var tasks = [a0]
                var preflight: Task<AgentSessionLaneCreateReceipt.Reason?, Never>?
                @MainActor func releaseAll() {
                    bridge.test_afterActivationBeforeDeletionFence = nil
                    bridge.test_afterAddInsertionBeforeEstablishment = nil
                    bridge.test_afterActivationBackedEstablishmentMutation = nil
                    bridge.test_afterLaneCreationIndependentGrantSample = nil
                    releaseFirst?.resume()
                    releaseFirst = nil
                    releaseOther?.resume()
                    releaseOther = nil
                    releaseMutation?.resume()
                    releaseMutation = nil
                    releaseSample?.resume()
                    releaseSample = nil
                }
                do {
                    await fulfillment(of: [parked], timeout: 10)
                    if inserting {
                        bridge.test_afterAddInsertionBeforeEstablishment = { pair in
                            bridge.test_afterAddInsertionBeforeEstablishment = nil
                            otherPair = pair
                            await withCheckedContinuation { releaseOther = $0
                                otherParked.fulfill()
                            }
                        }
                    }
                    let a1 = start("Lifecycle-A1")
                    tasks.append(a1)
                    await fulfillment(of: [otherParked], timeout: 10)
                    await self.installDeniedRoleControlFixture(on: creator, sessionID: creatorID)
                    XCTAssertNil(creator.oversight.overseerActivation)
                    await viewModel.mcpDeactivateControlContext(sessionID: creatorID, cleanupSessionStore: true)
                    XCTAssertNil(viewModel.agentSessionLinkBootstrapState(for: endpoint)?.activation)
                    let mutationParked = XCTestExpectation(description: "exact entry owner paused before cap release")
                    let mutatedPair = try XCTUnwrap(inserting ? otherPair : firstPair)
                    bridge.test_afterActivationBackedEstablishmentMutation = { pair, inserted in
                        guard pair == mutatedPair, inserted == inserting else { return }
                        bridge.test_afterActivationBackedEstablishmentMutation = nil
                        await withCheckedContinuation { releaseMutation = $0
                            mutationParked.fulfill()
                        }
                    }
                    let sampleParked = XCTestExpectation(description: "real nil authority sample held across entry mutation")
                    let freshSample = XCTestExpectation(description: "fresh sample observes independent grant without waiting for A")
                    var sampleCount = 0
                    var stableGrant: DomainAgentSessionLinkGrant?
                    bridge.test_afterLaneCreationIndependentGrantSample = { grant in
                        sampleCount += 1
                        if sampleCount == 1 {
                            XCTAssertNil(grant, "all real links at the original sample belong to captured bootstrap entries")
                            await withCheckedContinuation { releaseSample = $0
                                sampleParked.fulfill()
                            }
                        } else {
                            stableGrant = grant
                            freshSample.fulfill()
                        }
                    }
                    let completed = XCTestExpectation(description: "independent preflight finishes while entry owner remains paused")
                    var didComplete = false
                    preflight = Task { @MainActor in
                        let result = await bridge.laneCreationCallerPreflight(endpoint)
                        didComplete = true
                        completed.fulfill()
                        return result
                    }
                    await fulfillment(of: [sampleParked], timeout: 10)
                    if inserting {
                        releaseOther?.resume()
                        releaseOther = nil
                    } else {
                        releaseFirst?.resume()
                        releaseFirst = nil
                    }
                    await fulfillment(of: [mutationParked], timeout: 10)
                    // The fresh exact independent grant changes authority, not creator reservations.
                    // The entry owner remains parked, so neither compensation nor its cap defer ran.
                    let stablePair = AgentSessionOversightIntent(observerSessionID: creatorID, targetSessionID: independentID)
                    let added = await bridge.addMonitorLink(pair: stablePair)
                    guard case .added = added else { throw NSError(domain: "EntryLifecycleTest", code: 1) }
                    releaseSample?.resume()
                    releaseSample = nil
                    await fulfillment(of: [freshSample, completed], timeout: 10)
                    let bypassBeforeRelease = didComplete
                    XCTAssertTrue(bypassBeforeRelease, "fresh independent authority must bypass still-unsettled pair owners")
                    XCTAssertEqual(sampleCount, 2, "one invalidated sample, then one stable sample; no unbounded retry")
                    XCTAssertEqual(stableGrant?.observer, endpoint)
                    XCTAssertEqual(stableGrant?.target.sessionID, independentID)
                    let duringMutation = await authority.links(forObserverEndpoint: endpoint)
                    XCTAssertFalse(duringMutation.items.contains { $0.targetSessionID == mutatedPair.targetSessionID }, "consumed activation cannot index the pre-entry lane; a removed entry has already revoked its grant")
                    releaseAll()
                    for task in tasks {
                        let receipt = await task.value
                        XCTAssertFalse(receipt.linked)
                        XCTAssertEqual(receipt.reason, .addFailed, "consumed activation cannot re-enter successfully")
                    }
                    let result = await preflight?.value
                    XCTAssertNil(result ?? nil)
                    let remaining = await authority.links(forObserverEndpoint: endpoint)
                    XCTAssertEqual(remaining.items.map(\.targetSessionID), [independentID])
                    print("P1_ENTRY_LIFECYCLE: inserting=\(inserting); real samples=\(sampleCount); independent bypass before cap release=\(bypassBeforeRelease); surviving grants=\(remaining.items.count)")
                } catch {
                    releaseAll()
                    for task in tasks {
                        _ = await task.value
                    }
                    _ = await preflight?.value
                    throw error
                }
            }
        }
    }

    private func exerciseNestedCreationAfterControlRelease(independentDirection: String?) async throws {
        try await withFixture(ephemeral: false) { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let seed = try await host.agentSessionLinkCreateLane(
                destinationWindowID: fixture.window.windowID, workspaceID: fixture.workspaceID,
                creatorSessionID: UUID(), sessionName: "Nested creation caller", selection: fixture.selection
            )
            guard case let .created(creatorID, creatorTabID, _) = seed else {
                return XCTFail("creator seed must save")
            }
            let creator = try XCTUnwrap(viewModel.sessions[creatorTabID])
            creator.createdByOverseerSessionID = nil
            let endpoint = try XCTUnwrap(host.agentSessionLinkCandidates().first { $0.sessionID == creatorID }).domainEndpoint
            let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
                runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()
            ))
            let bridge = AgentSessionLinkRuntimeBridge(authority: authority, host: host, toolAdvertisementInvalidator: { _ in })
            let store = AgentSessionOversightIntentStore(
                fileURL: fixture.root.appendingPathComponent(AgentSessionOversightIntentStore.filename),
                backupsDirectoryURL: fixture.root.appendingPathComponent("Backups"), mode: .enabled
            )
            bridge.attach(host: host)
            defer {
                bridge.freezeForTermination()
                AgentSessionLinkRuntimeBridge.shared.attach(host: host)
            }
            await bridge.bootstrapIntentStore(store)
            await bridge.test_settleLaunchReconciliation()
            let activated = await bridge.becomeOverseer(
                endpoint: endpoint, isEnabled: { true }, revalidateRoute: { true }, commitIfCurrent: { $0() }
            )
            XCTAssertNotNil(activated)
            AgentAdvertisedModelCatalog.shared.record([
                AgentModelOption(rawValue: "sonnet:high", displayName: "Fixture model", description: nil, isPlaceholderDefault: false, isProviderDefault: false)
            ], for: .claudeCode, generation: AgentAdvertisedModelCatalog.shared.productionGeneration(for: .claudeCode))
            defer { AgentAdvertisedModelCatalog.shared.invalidate(.claudeCode) }
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            try await AsyncTestWait.waitUntil("nested creation model availability") {
                fixture.window.apiSettingsViewModel.agentAvailability.claudeCodeAvailable
            }
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let request: (String) -> AgentSessionLaneCreateRequest = { key in
                AgentSessionLaneCreateRequest(
                    idempotencyKey: key, role: nil, modelID: "claudeCode:sonnet:high",
                    sessionName: key, workspaceSelector: workspace.id.uuidString,
                    message: nil, workflowReference: nil
                )
            }
            let resolveDestination: @MainActor () -> (windowID: Int, workspaceID: UUID, workspaceName: String)? = {
                (fixture.window.windowID, workspace.id, workspace.name)
            }
            let firstParked = expectation(description: "A has activated and published inventory")
            var firstPair: AgentSessionOversightIntent?
            var resumeFirst: CheckedContinuation<Void, Never>?
            bridge.test_afterActivationBeforeDeletionFence = { pair in
                guard firstPair == nil else { return }
                firstPair = pair
                await withCheckedContinuation { continuation in
                    resumeFirst = continuation
                    firstParked.fulfill()
                }
            }
            let first = Task { @MainActor in
                await bridge.createLane(observerEndpoint: endpoint, request: request("nested-A"), resolveDestination: resolveDestination)
            }
            await fulfillment(of: [firstParked], timeout: 10)
            // Always release and join A before the fixture tears down, including assertion failures.
            do {
                let pairA = try XCTUnwrap(firstPair)
                let beforeControl = await authority.links(forObserver: creatorID)
                XCTAssertEqual(beforeControl.items.map(\.targetSessionID), [pairA.targetSessionID])
                XCTAssertNotNil(creator.oversight.overseerActivation)
                await self.installDeniedRoleControlFixture(on: creator, sessionID: creatorID)
                XCTAssertNil(creator.oversight.overseerActivation)
                XCTAssertNil(viewModel.agentSessionLinkBootstrapState(for: endpoint))
                await bridge.test_auditObserverEligibility()
                await bridge.test_settleLaunchReconciliation()
                let duringControl = await authority.hasActiveLink(endpoint: endpoint)
                XCTAssertTrue(duringControl, "the pending A grant is not yet in the completed-observer audit set")
                await viewModel.mcpDeactivateControlContext(sessionID: creatorID, cleanupSessionStore: true)
                let ordinaryAgain = try XCTUnwrap(viewModel.agentSessionLinkBootstrapState(for: endpoint))
                XCTAssertNil(ordinaryAgain.activation, "real control release must not restore opt-in")
                await bridge.test_auditObserverEligibility()
                await bridge.test_settleLaunchReconciliation()
                var stableReference: DomainAgentSessionLinkReference?
                var stablePair: AgentSessionOversightIntent?
                if let independentDirection {
                    let independentSeed = try await host.agentSessionLinkCreateLane(
                        destinationWindowID: fixture.window.windowID, workspaceID: fixture.workspaceID,
                        creatorSessionID: UUID(), sessionName: "Independent \(independentDirection)", selection: fixture.selection
                    )
                    guard case let .created(independentID, _, _) = independentSeed else {
                        throw NSError(domain: "NestedLaneTest", code: 1)
                    }
                    let pair = AgentSessionOversightIntent(
                        observerSessionID: independentDirection == "inbound" ? independentID : creatorID,
                        targetSessionID: independentDirection == "inbound" ? creatorID : independentID
                    )
                    let added = await bridge.addMonitorLink(pair: pair)
                    guard case .added = added else { throw NSError(domain: "NestedLaneTest", code: 2) }
                    let inventory = await authority.links(forObserver: pair.observerSessionID)
                    let item = try XCTUnwrap(inventory.items.first { $0.targetSessionID == pair.targetSessionID })
                    stableReference = DomainAgentSessionLinkReference(linkID: item.linkID, generation: item.generation)
                    stablePair = pair
                }
                let gateEntered = XCTestExpectation(description: "preflight and claimed B wait for A's transaction")
                gateEntered.expectedFulfillmentCount = 3
                gateEntered.assertForOverFulfill = true
                bridge.test_beforeLaneCreationBootstrapSettlement = {
                    if independentDirection == nil {
                        gateEntered.fulfill()
                    } else {
                        XCTFail("an independent exact grant must bypass A's settlement wait")
                    }
                }
                let secondCompleted = XCTestExpectation(description: "independently authorized B completes while A remains parked")
                var completedSecond: AgentSessionLaneCreateReceipt?
                let preflight = Task { @MainActor in await bridge.laneCreationCallerPreflight(endpoint) }
                let cancelledPreflightCompleted = XCTestExpectation(description: "cancelled preflight exits without settling or cancelling A")
                let cancelledPreflight: Task<AgentSessionLaneCreateReceipt.Reason?, Never>? = independentDirection == nil ? Task { @MainActor in
                    let result = await bridge.laneCreationCallerPreflight(endpoint)
                    cancelledPreflightCompleted.fulfill()
                    return result
                } : nil
                let second = Task { @MainActor in
                    let receipt = await bridge.createLane(observerEndpoint: endpoint, request: request("nested-B"), resolveDestination: resolveDestination)
                    completedSecond = receipt
                    if independentDirection != nil { secondCompleted.fulfill() }
                    return receipt
                }
                if independentDirection == nil {
                    await fulfillment(of: [gateEntered], timeout: 10)
                    XCTAssertNil(completedSecond, "sole-basis B remains parked without allocating")
                    cancelledPreflight?.cancel()
                    await fulfillment(of: [cancelledPreflightCompleted], timeout: 10)
                    if let cancelledPreflight {
                        let cancelledResult = await cancelledPreflight.value
                        XCTAssertEqual(cancelledResult, .denied, "cancellation exits the wait while A remains paused")
                    }
                } else {
                    await fulfillment(of: [secondCompleted], timeout: 10)
                    XCTAssertEqual(completedSecond?.result, .created)
                    XCTAssertEqual(completedSecond?.linked, true, "independent B must finish before A resumes")
                }
                let replayClaimed = expectation(description: "same-key replay joins B before settlement waits")
                bridge.test_afterLaneCreationClaim = { XCTFail("same-key replay must not claim or wait again") }
                let replay = Task { @MainActor in
                    let admission = await bridge.laneCreationCallerPreflight(endpoint, idempotencyKey: "nested-B")
                    XCTAssertNil(admission, "the service preflight must let an existing exact claim reach its digest-checked replay join")
                    replayClaimed.fulfill()
                    return await bridge.createLane(observerEndpoint: endpoint, request: request("nested-B"), resolveDestination: resolveDestination)
                }
                await fulfillment(of: [replayClaimed], timeout: 10)
                second.cancel() // Owned creation continues; cancellation must not cancel A or duplicate B.
                let beforeRollback = await authority.links(forObserver: creatorID)
                if independentDirection == nil {
                    XCTAssertEqual(beforeRollback.items.map(\.targetSessionID), [pairA.targetSessionID], "sole-basis B has not allocated/indexed a relationship")
                } else {
                    XCTAssertTrue(beforeRollback.items.contains { $0.targetSessionID == completedSecond?.sessionID })
                }
                resumeFirst?.resume()
                resumeFirst = nil
                let firstReceipt = await first.value
                let preflightResult = await preflight.value
                let secondReceipt = await second.value
                let replayReceipt = await replay.value
                bridge.test_afterActivationBeforeDeletionFence = nil
                bridge.test_beforeLaneCreationBootstrapSettlement = nil
                bridge.test_afterLaneCreationClaim = nil
                XCTAssertFalse(firstReceipt.linked, "A must roll back its lost activation basis")
                XCTAssertEqual(firstReceipt.reason, .addFailed)
                XCTAssertTrue(replayReceipt.duplicate)
                XCTAssertEqual(replayReceipt.sessionID, secondReceipt.sessionID)
                XCTAssertEqual(replayReceipt.result, secondReceipt.result)
                let afterRollback = await authority.links(forObserver: creatorID)
                let tokenA = await store.token(for: pairA)
                XCTAssertNil(tokenA, "A's exact durable intent is compensated before B chooses a fresh basis")
                if let stableReference, let stablePair {
                    let sampledStableGrant = await authority.activeGrant(for: stableReference)
                    let stableGrant = try XCTUnwrap(sampledStableGrant)
                    XCTAssertEqual(stableGrant.observer.sessionID, stablePair.observerSessionID)
                    XCTAssertEqual(stableGrant.target.sessionID, stablePair.targetSessionID)
                    XCTAssertTrue(stableGrant.observer == endpoint || stableGrant.target == endpoint, "independent grant must match this exact caller incarnation")
                    XCTAssertNil(preflightResult)
                    XCTAssertEqual(secondReceipt.result, .created)
                    XCTAssertTrue(secondReceipt.linked)
                    let secondID = try XCTUnwrap(secondReceipt.sessionID)
                    let pairB = AgentSessionOversightIntent(observerSessionID: creatorID, targetSessionID: secondID)
                    let tokenB = await store.token(for: pairB)
                    XCTAssertNotNil(tokenB)
                    XCTAssertTrue(afterRollback.items.contains { $0.targetSessionID == secondID })
                    let payloadB = try await AgentSessionDataService.shared.loadAgentSession(id: secondID, for: workspace)
                    XCTAssertEqual(payloadB?.createdByOverseerSessionID, creatorID)
                } else {
                    XCTAssertEqual(preflightResult, .denied)
                    XCTAssertEqual(secondReceipt.result, .refused)
                    XCTAssertEqual(secondReceipt.reason, .denied)
                    XCTAssertNil(secondReceipt.sessionID, "B must not allocate using A's rolled-back relationship")
                    XCTAssertFalse(secondReceipt.linked)
                    XCTAssertTrue(afterRollback.items.isEmpty)
                }
            } catch {
                resumeFirst?.resume()
                resumeFirst = nil
                _ = await first.value
                bridge.test_afterActivationBeforeDeletionFence = nil
                throw error
            }
        }
    }

    func testOverseerActivationIsIncarnationLocalAndExcludedSessionsCannotBootstrap() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let retired = AdvertisementRecorder()
            let previousRetiredSink = self.installLocalRetirementSink(retired)
            defer { AgentSessionLinkInvalidationSink.overseerActivationRetired = previousRetiredSink }
            let viewModel = fixture.window.agentModeViewModel
            let host = WindowStatesManager.shared
            let outcome = try await host.agentSessionLinkCreateLane(destinationWindowID: fixture.window.windowID, workspaceID: fixture.workspaceID, creatorSessionID: UUID(), sessionName: "Activation state", selection: fixture.selection)
            guard case let .created(sessionID, tabID, _) = outcome else { return XCTFail("seed must save") }
            let session = try XCTUnwrap(viewModel.sessions[tabID])
            let endpoint = try XCTUnwrap(host.agentSessionLinkCandidates().first { $0.sessionID == sessionID }).domainEndpoint
            XCTAssertNil(viewModel.agentSessionLinkBootstrapState(for: endpoint), "lane-created sessions are excluded")
            // Model an ordinary user-created session using the owning real memory/binding fixture.
            session.createdByOverseerSessionID = nil
            let initial = try XCTUnwrap(viewModel.agentSessionLinkBootstrapState(for: endpoint))
            XCTAssertTrue(viewModel.agentSessionLinkActivateOverseer(for: endpoint, expected: initial))
            let activation = try XCTUnwrap(session.oversight.overseerActivation)
            session.oversight.retirePeriodicScheduling()
            session.selectedAgent = .codexExec
            XCTAssertEqual(viewModel.agentSessionLinkBootstrapState(for: endpoint)?.activation, activation, "controller/provider repair is not a binding change")
            XCTAssertFalse(viewModel.agentSessionLinkActivateOverseer(for: endpoint, expected: initial), "stale pre-activation state cannot activate twice")
            let staleEndpoint = DomainAgentSessionLinkEndpointIdentity(
                windowID: endpoint.windowID, workspaceID: endpoint.workspaceID,
                tabID: endpoint.tabID, sessionID: endpoint.sessionID,
                persistentBindingGeneration: UUID(),
                bindingTransitionGeneration: endpoint.bindingTransitionGeneration
            )
            let staleActivation = AgentSessionOverseerActivation(endpoint: staleEndpoint, token: UUID())
            session.oversight.overseerActivation = staleActivation
            for _ in 0 ..< 2 {
                XCTAssertNil(viewModel.agentSessionLinkBootstrapState(for: endpoint), "stale activation cannot qualify for this binding")
                XCTAssertEqual(session.oversight.overseerActivation, staleActivation, "bootstrap reads must not retire stored state")
                XCTAssertNil(host.agentSessionLinkBootstrapState(for: endpoint), "catalog forwarding must refuse stale activation")
                XCTAssertEqual(session.oversight.overseerActivation, staleActivation, "catalog reads must not retire stored state")
            }
            for exclusion in ["mcp-origin", "child", "lane"] {
                session.oversight.overseerActivation = activation
                switch exclusion {
                case "mcp-origin": session.isMCPOriginated = true
                case "child": session.parentSessionID = UUID()
                case "lane": session.createdByOverseerSessionID = UUID()
                default: XCTFail("uncovered exclusion")
                }
                XCTAssertNil(session.oversight.overseerActivation, exclusion)
                XCTAssertNil(viewModel.agentSessionLinkBootstrapState(for: endpoint), exclusion)
                session.isMCPOriginated = false
                session.parentSessionID = nil
                session.createdByOverseerSessionID = nil
            }
            session.oversight.overseerActivation = activation
            _ = try await viewModel.mcpActivateControlContext(
                forTabID: tabID, sessionID: sessionID, originatingConnectionID: nil,
                taskLabelKind: .explore, markSessionAsMCPOriginated: false
            )
            XCTAssertEqual(session.mcpControlContext?.taskLabelKind, .explore)
            XCTAssertFalse(session.isMCPOriginated, "exercise control ownership, not the origin hook")
            XCTAssertNil(session.oversight.overseerActivation, "production denied-role attachment consumes activation")
            XCTAssertNil(viewModel.agentSessionLinkBootstrapState(for: endpoint))
            await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            XCTAssertNil(session.mcpControlContext)
            let returnedToDirect = try XCTUnwrap(viewModel.agentSessionLinkBootstrapState(for: endpoint))
            XCTAssertNil(returnedToDirect.activation, "production role release must not resurrect the old opt-in")
            XCTAssertTrue(viewModel.agentSessionLinkActivateOverseer(for: endpoint, expected: returnedToDirect), "direct requires a fresh opt-in")
            let retiredBeforeRebind = retired.sessionIDs.count
            session.beginPersistentBindingTransition()
            XCTAssertNil(session.oversight.overseerActivation, "rebind consumes activation immediately")
            XCTAssertEqual(retired.sessionIDs.count, retiredBeforeRebind + 1)
            XCTAssertTrue(retired.sessionIDs.allSatisfy { $0 == sessionID }, "retirement names only this session")
            XCTAssertNil(viewModel.agentSessionLinkBootstrapState(for: endpoint), "suspended binding is ineligible")
            let restarted = AgentTabSession(tabID: tabID)
            XCTAssertNil(restarted.oversight.overseerActivation, "new object/restart never restores activation")
        }
    }

    func testPersistedDevinRoleLanesSaveLinkAndDispatchFirstTask() async throws {
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
        let registry = AgentACPModelRegistry.shared
        registry.test_reset(providerID: .devin)
        defer { registry.test_reset(providerID: .devin) }
        XCTAssertTrue(registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: "swe-2-high", displayName: "SWE-2", description: nil, isDefault: true
                )],
                currentModelRaw: "swe-2-high",
                modelParameterSets: [ACPModelParameterSet(
                    baseModelRaw: "swe-2-high",
                    parameters: [ACPModelParameterDefinition(
                        kind: .thinking, configID: "thought_level", displayName: "Thinking",
                        choices: ["medium", "high", "max"].map {
                            ACPModelParameterChoice(rawValue: $0, displayName: $0)
                        },
                        currentValueRaw: "high"
                    )]
                )]
            ), for: .devin
        ))
        // Install the fake CLI before window construction also on hosts that cache availability.
        let transportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-devin-transport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: transportRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: transportRoot) }
        let script = try AgentSessionLinkACPServerScript.write(to: transportRoot)
        let command = transportRoot.appendingPathComponent("devin")
        try FileManager.default.copyItem(at: script, to: command)
        let previousPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", transportRoot.path + ":" + (previousPath ?? ""), 1)
        _ = DevinRuntimeLocator.isInstalledSync(now: Date(timeIntervalSinceNow: 4))
        defer {
            if let previousPath { setenv("PATH", previousPath, 1) } else { unsetenv("PATH") }
            _ = DevinRuntimeLocator.isInstalledSync(now: Date(timeIntervalSinceNow: 8))
        }
        try await withFixture(ephemeral: false) { fixture in
            let suiteName = "lane-devin-role-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let fileStore = GlobalSettingsFileStore(fileURL: fixture.root.appendingPathComponent("roles.json"))
            let pins = ["explore": "devin:swe-2-medium", "engineer": "devin:swe-2-max"]
            try fileStore.save(GlobalSettingsDocument(globalDefaults: GlobalDefaults(
                discoverAgentRaw: nil, discoverModelsByAgent: nil, mcpAgentRoleOverrides: pins
            )))
            let settings = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
            XCTAssertEqual(settings.globalMCPAgentRoleOverrides(), pins)
            let store = GlobalSettingsStore.shared
            let originalProfile = store.globalAgentModelsProfile()
            defer { store.setGlobalAgentModelsProfile(originalProfile, contextBuilderWriteIntent: .preserveExistingOwnership) }
            var profile = originalProfile
            profile.mcpAgentRoleOverrides = settings.globalMCPAgentRoleOverrides()
            profile.mcpAgentRoleModelParameters = [:]
            store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)

            fixture.window.agentModeViewModel.setAgentModeActive(true)
            try await AsyncTestWait.waitUntil("destination workspace activation") {
                !fixture.window.agentModeViewModel.workspaceSwitchInFlight
            }
            let host = WindowStatesManager.shared
            let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
                runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()
            ))
            let bridge = AgentSessionLinkRuntimeBridge(
                authority: authority, host: host, toolAdvertisementInvalidator: { _ in }
            )
            bridge.installIntentStore(AgentSessionOversightIntentStore(
                fileURL: fixture.root.appendingPathComponent(AgentSessionOversightIntentStore.filename),
                backupsDirectoryURL: fixture.root.appendingPathComponent(AgentSessionOversightIntentStore.backupsDirectoryName),
                mode: .enabled
            ))
            // A creator must already oversee a real endpoint before it can admit a lane.
            var seedIDs: [UUID] = []
            for name in ["Creator", "Initial target"] {
                let outcome = try await host.agentSessionLinkCreateLane(
                    destinationWindowID: fixture.window.windowID, workspaceID: fixture.workspaceID,
                    creatorSessionID: UUID(), sessionName: name, selection: fixture.selection
                )
                guard case let .created(sessionID, _, _) = outcome else {
                    return XCTFail("seed endpoint must durably save")
                }
                seedIDs.append(sessionID)
            }
            let creatorID = seedIDs[0]
            guard case .added = await bridge.addMonitorLink(
                observerSessionID: creatorID, rawTargetSessionID: seedIDs[1].uuidString
            ) else { return XCTFail("creator must have a real active link") }
            let observer = try XCTUnwrap(host.agentSessionLinkCandidates().first { $0.sessionID == creatorID })
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            for (role, thinking) in [("explore", "medium"), ("engineer", "max")] {
                let model = "swe-2-\(thinking)"
                let task = "First task for \(role): reply done."
                let rpcLog = fixture.root.appendingPathComponent("\(role)-rpc.jsonl")
                let provider = AgentSessionLinkCapturingACPProvider(
                    providerID: .devin, commandPath: command.path,
                    environment: ["ACP_DEVIN_FIXTURE": "1", "ACP_RPC_LOG": rpcLog.path]
                )
                var savedBeforeDispatch: UUID?
                var controller: ACPAgentSessionController?
                bridge.test_afterAddInsertionBeforeEstablishment = { pair in
                    do {
                        let candidate = try XCTUnwrap(host.agentSessionLinkCandidates().first {
                            $0.sessionID == pair.targetSessionID
                        })
                        let lane = try XCTUnwrap(fixture.window.agentModeViewModel.sessions[candidate.tabID])
                        let loaded = try await AgentSessionDataService.shared.loadAgentSession(id: pair.targetSessionID, for: workspace)
                        let saved = try XCTUnwrap(loaded)
                        XCTAssertEqual(saved.id, pair.targetSessionID)
                        XCTAssertEqual(saved.createdByOverseerSessionID, creatorID)
                        XCTAssertEqual(saved.agentKind, "devin")
                        XCTAssertEqual(saved.agentModel, model)
                        XCTAssertNil(saved.parentSessionID)
                        XCTAssertFalse(lane.runState.isActive)
                        XCTAssertFalse(lane.isMCPOriginated)
                        savedBeforeDispatch = saved.id
                        // Approved reused-transport boundary: production host/save/grant/send remain real.
                        let transport = try ACPAgentSessionController(
                            provider: provider,
                            runRequest: ACPRunRequest(
                                agentKind: .devin, modelString: model, workspacePath: fixture.root.path,
                                resumeSessionID: nil, attachments: [], taskLabelKind: nil
                            ),
                            allowsProviderProcessLaunchForTesting: true
                        )
                        controller = transport
                        let bootstrap = try await transport.bootstrap()
                        lane.acpController = transport
                        lane.providerSessionID = bootstrap.sessionID
                        lane.installRunID(UUID())
                    } catch {
                        XCTFail("\(role) transport preparation failed: \(error)")
                    }
                }
                let receipt = await bridge.createLane(
                    observerEndpoint: observer.domainEndpoint,
                    request: AgentSessionLaneCreateRequest(
                        idempotencyKey: role, role: role, sessionName: "Devin \(role) lane",
                        message: task, workflowReference: nil
                    ),
                    resolveDestination: { (fixture.window.windowID, fixture.workspaceID, workspace.name) }
                )
                bridge.test_afterAddInsertionBeforeEstablishment = nil
                XCTAssertEqual(receipt.result, .created, role)
                XCTAssertNil(receipt.reason, role)
                XCTAssertTrue(receipt.linked, role)
                XCTAssertEqual(receipt.firstTask, .delivered, role)
                XCTAssertNil(receipt.firstTaskReason, role)
                // Keep the engineer control observable even when the explore regression is red.
                if let sessionID = receipt.sessionID, savedBeforeDispatch == sessionID {
                    let inventory = await authority.links(forObserver: creatorID)
                    let grant = try XCTUnwrap(inventory.items.first { $0.targetSessionID == sessionID })
                    XCTAssertEqual(grant.observerSessionID, creatorID)
                    XCTAssertTrue(grant.capabilities.contains(.sendWhenIdle))
                    XCTAssertTrue(grant.capabilities.contains(.manage))
                    let targetInventory = await authority.links(forTarget: sessionID)
                    XCTAssertEqual(targetInventory.items.map(\.linkID), [grant.linkID])
                    let candidate = try XCTUnwrap(host.agentSessionLinkCandidates().first { $0.sessionID == sessionID })
                    let lane = try XCTUnwrap(fixture.window.agentModeViewModel.sessions[candidate.tabID])
                    try await AsyncTestWait.waitUntil("\(role) first prompt to finish") {
                        !lane.runState.isActive && (provider.promptedMessages.count == 1 || lane.runState == .failed)
                    }
                    XCTAssertEqual(lane.runState, .completed, role)
                    XCTAssertTrue(try XCTUnwrap(provider.promptedMessages.first).userMessage.contains(task))
                    let records = try String(contentsOf: rpcLog, encoding: .utf8).split(separator: "\n").map {
                        try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
                    }
                    let requests = records.filter { $0["direction"] as? String == "request" }
                        .compactMap { $0["payload"] as? [String: Any] }
                    let prompt = try XCTUnwrap(requests.first { $0["method"] as? String == "session/prompt" })
                    XCTAssertEqual(requests.count(where: { $0["method"] as? String == "session/prompt" }), 1)
                    let params = try XCTUnwrap(prompt["params"] as? [String: Any])
                    let blocks = try XCTUnwrap(params["prompt"] as? [[String: Any]])
                    XCTAssertEqual(blocks.first?["text"] as? String, provider.promptedMessages.first?.userMessage)
                    let ack = try XCTUnwrap(
                        records.filter { $0["direction"] as? String == "response" }
                            .compactMap { $0["payload"] as? [String: Any] }
                            .first { ($0["id"] as? NSNumber) == (prompt["id"] as? NSNumber) }
                    )
                    XCTAssertEqual((ack["result"] as? [String: Any])?["stopReason"] as? String, "end_turn")
                    XCTAssertTrue(requests.contains {
                        let parameters = $0["params"] as? [String: Any]
                        return $0["method"] as? String == "session/set_config_option"
                            && parameters?["configId"] as? String == "thought_level"
                            && parameters?["value"] as? String == thinking
                    }, role)
                } else {
                    XCTFail("\(role) must save before grant and first-task dispatch")
                }
                await controller?.shutdown()
            }
        }
    }

    func testPreparingLaneRejectsGenericSaveAndSubmitBeforeConfiguredFirstSave() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let creatorID = UUID()
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            var saveCount = 0
            var savedFileURL: URL?
            var provisionedSession: AgentTabSession?
            var provisionedBindingToken: AgentSessionRestorationBindingToken?
            viewModel.test_setAgentSessionSaver { session, workspace, canonicalItemCount in
                saveCount += 1
                let fileURL = try await AgentSessionDataService.shared.saveAgentSession(
                    session, for: workspace, preparation: .alreadyCanonicalTranscript,
                    trustedCanonicalItemCount: canonicalItemCount
                )
                savedFileURL = fileURL
                return fileURL
            }
            viewModel.test_afterOversightLaneProvision = { tabID in
                do {
                    let lane = try XCTUnwrap(viewModel.sessions[tabID])
                    let sessionID = try XCTUnwrap(lane.activeAgentSessionID)
                    provisionedSession = lane
                    provisionedBindingToken = try XCTUnwrap(lane.currentRestorationBindingToken)
                    XCTAssertTrue(lane.qualifiedRestorationReadiness.isCreating)
                    XCTAssertFalse(lane.restorationReadiness.isAuthoritative)
                    XCTAssertNil(viewModel.captureSessionCreationRetry(for: lane), "Preparation has no configured payload to retry.")
                    XCTAssertTrue(lane.items.isEmpty)

                    let requiredSave = await viewModel.flushSaveRequired(
                        for: tabID, workspaceID: fixture.workspaceID
                    )
                    guard case let .failure(failure) = requiredSave else {
                        return XCTFail("A generic required save must not persist a preparing lane.")
                    }
                    XCTAssertEqual(failure.operation, .save)
                    XCTAssertEqual(failure.tabID, tabID)
                    await viewModel.flushSave(for: tabID)
                    let blocker = try XCTUnwrap(lane.operationAdmissionFailureMessage)
                    let submission = viewModel.submitUserTurn(text: "Do not dispatch while preparing", tabID: tabID)
                    guard case let .blocked(message) = submission else {
                        return XCTFail("A preparing lane must refuse submission before admitting a user row.")
                    }
                    XCTAssertEqual(message, blocker)
                    let files = try await AgentSessionDataService.shared.listAgentSessions(for: workspace)
                    XCTAssertFalse(files.contains { $0.lastPathComponent == "AgentSession-\(sessionID.uuidString).json" })
                    XCTAssertEqual(saveCount, 0, "Neither generic save may enter the real saver before configuration.")
                    XCTAssertTrue(lane.items.isEmpty)
                    XCTAssertFalse(lane.runState.isActive)
                    XCTAssertNil(lane.runID)
                    XCTAssertNil(lane.provider)
                    XCTAssertNil(lane.codexController)
                    XCTAssertNil(lane.claudeController)
                    XCTAssertNil(lane.acpController)
                    XCTAssertNil(viewModel.captureSessionCreationRetry(for: lane))
                    XCTAssertFalse(lane.restorationReadiness.isAuthoritative)
                } catch {
                    XCTFail("Preparing lane assertions failed: \(error)")
                }
            }
            defer { viewModel.test_afterOversightLaneProvision = nil }

            let outcome = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: creatorID, sessionName: "Persisted lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(sessionID, tabID, bindingToken) = outcome else {
                return XCTFail("Configured lane did not establish its durable first-save proof: \(outcome)")
            }
            let fileURL = try XCTUnwrap(savedFileURL)
            let expectedFileURL = WorkspaceSessionSidecarMigration.workspaceDirectory(
                for: workspace, root: AgentSessionDataService.defaultWorkspaceRootURL()
            ).appendingPathComponent("AgentSessions").appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
            XCTAssertEqual(fileURL.resolvingSymlinksInPath().path, expectedFileURL.resolvingSymlinksInPath().path)
            let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
            XCTAssertEqual(saved.id, sessionID)
            XCTAssertEqual(saved.workspaceID, fixture.workspaceID)
            XCTAssertEqual(saved.composeTabID, tabID)
            let loaded = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: workspace)
            let reopened = try XCTUnwrap(loaded)
            XCTAssertEqual(reopened.id, sessionID)
            XCTAssertEqual(reopened.workspaceID, fixture.workspaceID)
            XCTAssertEqual(reopened.composeTabID, tabID)
            XCTAssertEqual(saved.createdByOverseerSessionID, creatorID)
            XCTAssertEqual(saved.agentKind, fixture.selection.agentRaw)
            XCTAssertEqual(
                CodexModelSpecifier(raw: saved.agentModel).baseModel,
                CodexModelSpecifier(raw: fixture.selection.modelRaw).baseModel
            )
            XCTAssertEqual(saved.agentReasoningEffort, fixture.selection.reasoningEffortRaw)
            XCTAssertNil(saved.parentSessionID)
            XCTAssertEqual(saveCount, 1, "Only the configured owner may perform the lane's first save.")
            let lane = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertTrue(lane === provisionedSession)
            XCTAssertEqual(bindingToken, provisionedBindingToken)
            XCTAssertEqual(
                lane.restorationReadiness,
                .authoritative(bindingToken, .freshBindingDurablyCreated)
            )
            XCTAssertTrue(lane.items.isEmpty)
            XCTAssertFalse(lane.runState.isActive)
            XCTAssertFalse(lane.isMCPOriginated)
            XCTAssertNil(lane.runID)
            XCTAssertNil(lane.provider)
            XCTAssertNil(lane.codexController)
            XCTAssertNil(lane.claudeController)
            XCTAssertNil(lane.acpController)
        }
    }

    func testFailedFirstSaveKeepsTheLaneForRecoveryWithoutLinkProof() async throws {
        enum SaveFailure: Error { case expected }
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let creatorID = UUID()
            viewModel.test_setAgentSessionSaver { _, _, _ in throw SaveFailure.expected }
            let outcome = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: creatorID, sessionName: "Recoverable lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .creationIncomplete(sessionID, tabID) = outcome else {
                return XCTFail("save failure unexpectedly proved a lane")
            }
            let lane = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(lane.activeAgentSessionID, sessionID)
            XCTAssertEqual(lane.createdByOverseerSessionID, creatorID)
            XCTAssertFalse(lane.restorationReadiness.isAuthoritative)
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == tabID && $0.activeAgentSessionID == sessionID
            } == true)
        }
    }

    func testRebindDuringHydrationDoesNotMarkReplacementAsCreatorOwned() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let originalTabs = Set(fixture.window.workspaceManager.activeWorkspace?.composeTabs.map(\.id) ?? [])
            let replacementID = UUID()
            let creatorID = UUID()
            var reboundTabID: UUID?
            viewModel.test_setAfterDurableChildTabCreation {
                guard let tabID = fixture.window.workspaceManager.activeWorkspace?.composeTabs.first(where: {
                    !originalTabs.contains($0.id)
                })?.id else { return XCTFail("fresh tab was not published") }
                reboundTabID = tabID
                do {
                    _ = try await viewModel.test_rebindPersistentSession(
                        replacementID, to: viewModel.session(for: tabID)
                    )
                } catch { XCTFail("test rebind failed: \(error)") }
            }
            defer { viewModel.test_setAfterDurableChildTabCreation(nil) }
            let outcome = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: creatorID, sessionName: "Rebound lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            let tabID = try XCTUnwrap(reboundTabID)
            guard case let .creationIncomplete(sessionID, publishedTabID) = outcome else {
                return XCTFail("rebound lane unexpectedly received a first-save proof")
            }
            XCTAssertEqual(publishedTabID, tabID)
            XCTAssertNotEqual(sessionID, replacementID)
            let replacement = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(replacement.activeAgentSessionID, replacementID)
            XCTAssertNil(replacement.createdByOverseerSessionID)
        }
    }

    func testConfigurationFailureAlsoRetainsTheCreatedLane() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let creatorID = UUID()
            let invalidSelection = AgentSessionLanePolicy.RoleSelection(
                role: .pair, agentRaw: "unavailable-provider", modelRaw: "unavailable-model",
                reasoningEffortRaw: nil, modelParameterSelections: []
            )
            let outcome = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: creatorID, sessionName: "Recoverable configuration",
                selection: invalidSelection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .creationIncomplete(sessionID, tabID) = outcome else {
                return XCTFail("invalid configuration unexpectedly proved a lane")
            }
            let lane = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(lane.activeAgentSessionID, sessionID)
            XCTAssertEqual(lane.createdByOverseerSessionID, creatorID)
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == tabID && $0.activeAgentSessionID == sessionID
            } == true)
        }
    }

    func testCreatorLabelUsesLiveLaneBeforeSidebarIndexCatchesUp() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let creatorID = UUID()
            var capturedLabel: String?
            viewModel.test_afterOversightLaneProvision = { tabID in
                guard let sessionID = viewModel.sessions[tabID]?.activeAgentSessionID else {
                    return XCTFail("published lane missing a session")
                }
                XCTAssertNil(viewModel.test_ownerValidatedSessionIndex[sessionID])
                capturedLabel = viewModel.agentSidebarLaneCreator(tabID: tabID, expectedSessionID: sessionID)?.label
            }
            defer { viewModel.test_afterOversightLaneProvision = nil }
            _ = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: creatorID, sessionName: "Fresh label",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            XCTAssertEqual(capturedLabel, AgentMonitorSessionIDFormatter.short(creatorID))
        }
    }

    func testRetireBindingCountIgnoresInactiveWindowCopyButKeepsActivePeer() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let outcome = try await fixture.window.agentModeViewModel.mcpCreateOversightLane(
                creatorSessionID: UUID(), sessionName: "Retirable lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(sessionID, tabID, _) = outcome else {
                return XCTFail("fresh lane did not establish its binding")
            }
            let viewModel = fixture.window.agentModeViewModel
            let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: tabID))
            let uniquelyBound = { WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: sessionID) == 1 }
            XCTAssertTrue(uniquelyBound())
            try await withSecondRegisteredWindow { second in
                let originalWorkspace = try XCTUnwrap(second.workspaceManager.activeWorkspace)
                let copy = try XCTUnwrap(second.workspaceManager.workspace(withID: fixture.workspaceID))
                XCTAssertNotEqual(second.workspaceManager.activeWorkspaceID, fixture.workspaceID)
                XCTAssertEqual(
                    WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: sessionID), 1,
                    "an inactive copy of the same workspace/tab is not a second binding"
                )
                await second.workspaceManager.switchWorkspace(
                    to: copy, saveState: false, reason: "retireBindingCountTest"
                )
                XCTAssertEqual(
                    WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: sessionID), 2,
                    "an active peer window must still block retirement"
                )
                let blocked = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                    endpoint: endpoint, commit: false, isStillRetirable: uniquelyBound
                )
                XCTAssertFalse(blocked)
                await second.workspaceManager.switchWorkspace(
                    to: originalWorkspace, saveState: false, reason: "retireBindingCountTest"
                )
                XCTAssertTrue(uniquelyBound())
                let claim = try XCTUnwrap(WindowStatesManager.shared.agentSessionLinkClaimLaneRetirement(endpoint: endpoint))
                let retired = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                    endpoint: endpoint, commit: true, isStillRetirable: uniquelyBound
                )
                WindowStatesManager.shared.agentSessionLinkReleaseLaneRetirement(endpoint: endpoint, claimID: claim)
                XCTAssertTrue(retired)
                XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.stashedTabs.contains(where: {
                    $0.tab.id == tabID
                }) == true)
                XCTAssertFalse(second.workspaceManager.workspace(withID: fixture.workspaceID)?.composeTabs.contains(where: {
                    $0.id == tabID
                }) == true, "retirement must reconcile the inactive peer before activation")
                let reopened = await second.workspaceManager.switchWorkspace(
                    to: copy, saveState: false, reason: "retireBindingCountTest"
                )
                XCTAssertEqual(reopened, .switched)
                XCTAssertEqual(second.workspaceManager.activeWorkspaceID, fixture.workspaceID)
                XCTAssertFalse(second.workspaceManager.activeWorkspace?.composeTabs.contains(where: {
                    $0.id == tabID
                }) == true, "activating a stale catalog copy must reload the retired binding")
            }
        }
    }

    func testRetirementClaimFencesPendingAndNewWorkspaceActivations() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let outcome = try await fixture.window.agentModeViewModel.mcpCreateOversightLane(
                creatorSessionID: UUID(), sessionName: "Activation-fenced lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(_, tabID, _) = outcome else {
                return XCTFail("fresh lane did not establish its binding")
            }
            let endpoint = try XCTUnwrap(fixture.window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: tabID))
            try await withSecondRegisteredWindow { second in
                let originalWorkspace = try XCTUnwrap(second.workspaceManager.activeWorkspace)
                let copy = try XCTUnwrap(second.workspaceManager.workspace(withID: fixture.workspaceID))
                let activationLoaded = expectation(description: "peer loaded workspace before publication")
                var releaseActivation: CheckedContinuation<Void, Never>?
                second.workspaceManager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting { id in
                    guard id == fixture.workspaceID else { return }
                    await withCheckedContinuation { continuation in
                        releaseActivation = continuation
                        activationLoaded.fulfill()
                    }
                }
                let switching = Task {
                    await second.workspaceManager.switchWorkspace(
                        to: copy, saveState: false, reason: "retirementActivationFenceTest"
                    )
                }
                await fulfillment(of: [activationLoaded], timeout: 3)
                XCTAssertNil(WindowStatesManager.shared.agentSessionLinkClaimLaneRetirement(endpoint: endpoint))
                releaseActivation?.resume()
                let firstSwitch = await switching.value
                XCTAssertEqual(firstSwitch, .switched)
                second.workspaceManager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting(nil)
                XCTAssertEqual(WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: endpoint.sessionID), 2)

                let switchedAway = await second.workspaceManager.switchWorkspace(
                    to: originalWorkspace, saveState: false, reason: "retirementActivationFenceTest"
                )
                XCTAssertEqual(switchedAway, .switched)
                let claim = try XCTUnwrap(WindowStatesManager.shared.agentSessionLinkClaimLaneRetirement(endpoint: endpoint))
                let blocked = await second.workspaceManager.switchWorkspace(
                    to: copy, saveState: false, reason: "retirementActivationFenceTest"
                )
                XCTAssertFalse(blocked.didSwitch)
                WindowStatesManager.shared.agentSessionLinkReleaseLaneRetirement(endpoint: endpoint, claimID: claim)
                let switchedAfterRelease = await second.workspaceManager.switchWorkspace(
                    to: copy, saveState: false, reason: "retirementActivationFenceTest"
                )
                XCTAssertEqual(switchedAfterRelease, .switched)
            }
        }
    }

    func testRetireBindingCountKeepsEphemeralInactiveWindowCopy() async throws {
        try await withFixture { fixture in
            let outcome = try await fixture.window.agentModeViewModel.mcpCreateOversightLane(
                creatorSessionID: UUID(), sessionName: "Ephemeral lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(sessionID, _, _) = outcome else {
                return XCTFail("fresh lane did not establish its binding")
            }
            try await withSecondRegisteredWindow { second in
                let copy = try XCTUnwrap(fixture.window.workspaceManager.workspace(withID: fixture.workspaceID))
                second.workspaceManager.workspaces.append(copy)
                XCTAssertEqual(
                    WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: sessionID), 2,
                    "an ephemeral copy can reopen without a canonical reload and must block retirement"
                )
            }
        }
    }

    func testBindingCountIncludesInactiveWorkspaceWithoutHydration() async throws {
        try await withFixture { fixture in
            let sessionID = UUID()
            let activeIndex = try XCTUnwrap(fixture.window.workspaceManager.workspaces.firstIndex {
                $0.id == fixture.workspaceID
            })
            fixture.window.workspaceManager.workspaces[activeIndex].composeTabs.append(
                ComposeTabState(id: UUID(), name: "Active", activeAgentSessionID: sessionID)
            )
            let inactive = fixture.window.workspaceManager.createWorkspace(
                name: "Inactive duplicate", repoPaths: [fixture.root.path], ephemeral: true
            )
            let inactiveIndex = try XCTUnwrap(fixture.window.workspaceManager.workspaces.firstIndex {
                $0.id == inactive.id
            })
            let hiddenTabID = UUID()
            fixture.window.workspaceManager.workspaces[inactiveIndex].composeTabs.append(
                ComposeTabState(id: hiddenTabID, name: "Hidden", activeAgentSessionID: sessionID)
            )
            XCTAssertEqual(fixture.window.workspaceManager.activeWorkspaceID, fixture.workspaceID)
            XCTAssertNil(fixture.window.agentModeViewModel.sessions[hiddenTabID])
            XCTAssertEqual(WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: sessionID), 2)
        }
    }

    func testChildRetirementInventoryKeepsActiveDuplicatesAndNestedDescendants() {
        let parentID = UUID()
        let childID = UUID()
        let grandchildID = UUID()
        let finished = AgentSessionLaneChildRetirementRecord(
            sessionID: childID, parentSessionID: parentID, blocksRetirement: false
        )
        let activeDuplicate = AgentSessionLaneChildRetirementRecord(
            sessionID: childID, parentSessionID: parentID, blocksRetirement: true
        )
        let activeGrandchild = AgentSessionLaneChildRetirementRecord(
            sessionID: grandchildID, parentSessionID: childID, blocksRetirement: true
        )
        XCTAssertFalse(AgentSessionLaneChildRetirementRecord.hasBlockingDescendant(of: parentID, in: [finished]))
        for records in [[finished, activeDuplicate], [activeDuplicate, finished], [finished, activeGrandchild]] {
            XCTAssertTrue(AgentSessionLaneChildRetirementRecord.hasBlockingDescendant(of: parentID, in: records))
        }
    }

    func testCreatedLaneRetirementStashesFinishedChildrenAndRefusesRunningChild() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let created = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: UUID(), sessionName: "Parent lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(parentID, parentTabID, _) = created else {
                return XCTFail("fresh lane did not establish its binding")
            }
            let childTarget = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "Child",
                parentSessionID: parentID, expectedWorkspaceID: fixture.workspaceID
            )
            let committedChildTarget = await viewModel.commitConfiguredSessionCreation(target: childTarget)
            XCTAssertTrue(committedChildTarget, "The descendant fixture must finish its real first payload save.")
            let child = try XCTUnwrap(viewModel.sessions[childTarget.tabID])
            let childID = try XCTUnwrap(child.activeAgentSessionID)
            let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: parentTabID))
            let childrenSettled = {
                !WindowStatesManager.shared.agentSessionLinkHasActiveChildSessions(parentSessionID: parentID)
            }

            child.runState = .running
            XCTAssertFalse(childrenSettled())
            let blocked = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                endpoint: endpoint, commit: true, isStillRetirable: childrenSettled
            )
            XCTAssertFalse(blocked)
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == parentTabID
            } == true)

            child.runState = .completed
            child.isDirty = true
            await viewModel.flushSave(for: child.tabID)
            let grandchildTarget = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "Grandchild",
                parentSessionID: childID, expectedWorkspaceID: fixture.workspaceID
            )
            let committedGrandchildTarget = await viewModel.commitConfiguredSessionCreation(target: grandchildTarget)
            XCTAssertTrue(committedGrandchildTarget, "The descendant fixture must finish its real first payload save.")
            let grandchild = try XCTUnwrap(viewModel.sessions[grandchildTarget.tabID])
            grandchild.runState = .waitingForApproval
            XCTAssertFalse(childrenSettled(), "an active grandchild must also block the stash cascade")
            grandchild.runState = .completed
            grandchild.isDirty = true
            await viewModel.flushSave(for: grandchild.tabID)
            XCTAssertTrue(childrenSettled(), "finished children must not block retirement")
            let persistedBlocker = await WindowStatesManager.shared.agentSessionLinkHasPersistedActiveChildSessions(
                parentSessionID: parentID
            )
            XCTAssertFalse(persistedBlocker)
            let retired = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                endpoint: endpoint, commit: true, isStillRetirable: childrenSettled
            )
            XCTAssertTrue(retired)
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            XCTAssertTrue(workspace.stashedTabs.contains { $0.tab.id == parentTabID })
            XCTAssertTrue(workspace.stashedTabs.contains { $0.tab.id == child.tabID })
            XCTAssertTrue(workspace.stashedTabs.contains { $0.tab.id == grandchild.tabID })
            XCTAssertFalse(workspace.composeTabs.contains { $0.id == child.tabID || $0.id == grandchild.tabID })
            let savedChild = try await AgentSessionDataService.shared.loadAgentSession(id: childID, for: workspace)
            let persistedChild = try XCTUnwrap(savedChild)
            XCTAssertEqual(persistedChild.id, childID)
            XCTAssertEqual(persistedChild.parentSessionID, parentID)
        }
    }

    func testRetirementJoinsDiskOnlyAncestryWithLiveGrandchildState() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let created = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: UUID(), sessionName: "Mixed lineage",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(parentID, parentTabID, _) = created else {
                return XCTFail("parent creation failed")
            }
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            var diskOnlyChild = AgentSession(id: UUID(), name: "Disk-only connector", savedAt: Date())
            diskOnlyChild.parentSessionID = parentID
            diskOnlyChild.lastRunState = AgentSessionRunState.completed.rawValue
            _ = try await AgentSessionDataService.shared.saveAgentSession(diskOnlyChild, for: workspace)
            let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "Live grandchild",
                parentSessionID: diskOnlyChild.id, expectedWorkspaceID: fixture.workspaceID
            )
            let committedTarget = await viewModel.commitConfiguredSessionCreation(target: target)
            XCTAssertTrue(committedTarget, "The descendant fixture must finish its real first payload save.")
            let grandchild = try XCTUnwrap(viewModel.sessions[target.tabID])
            grandchild.runState = .completed
            grandchild.isDirty = true
            await viewModel.flushSave(for: target.tabID)
            XCTAssertNil(viewModel.test_ownerValidatedSessionIndex[diskOnlyChild.id])
            let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: parentTabID))
            grandchild.runState = .running // Disk still says completed.
            let blocked = await WindowStatesManager.shared.agentSessionLinkHasPersistedActiveChildSessions(
                parentSessionID: parentID
            )
            XCTAssertTrue(blocked)
            let refused = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                endpoint: endpoint, commit: true, isStillRetirable: { true }
            )
            XCTAssertFalse(refused)
            grandchild.runState = .completed
            let retired = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                endpoint: endpoint, commit: true, isStillRetirable: { true }
            )
            XCTAssertTrue(retired)
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.stashedTabs.contains {
                $0.tab.id == target.tabID
            } == true, "disk-only connector must also connect the stash cascade")
        }
    }

    func testRetirementRefusesFinishedDescendantBoundInActivePeerWithoutParent() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let created = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: UUID(), sessionName: "Parent",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(parentID, parentTabID, _) = created else { return XCTFail("parent creation failed") }
            let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "Finished child",
                parentSessionID: parentID, expectedWorkspaceID: fixture.workspaceID
            )
            let committedTarget = await viewModel.commitConfiguredSessionCreation(target: target)
            XCTAssertTrue(committedTarget, "The descendant fixture must finish its real first payload save.")
            let child = try XCTUnwrap(viewModel.sessions[target.tabID])
            child.runState = .completed
            child.isDirty = true
            await viewModel.flushSave(for: target.tabID)
            _ = await fixture.window.workspaceManager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspaceID, source: WorkspaceSaveSource("retireChildTest")
            )
            let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: parentTabID))
            try await withSecondRegisteredWindow { peer in
                let copy = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
                _ = await peer.workspaceManager.switchWorkspace(to: copy, saveState: false, reason: "retireChildTest")
                var projected = peer.workspaceManager.workspaces
                let index = try XCTUnwrap(projected.firstIndex { $0.id == fixture.workspaceID })
                projected[index].composeTabs.removeAll { $0.id == parentTabID }
                peer.workspaceManager.workspaces = projected
                XCTAssertEqual(WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: parentID), 1)
                let retired = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                    endpoint: endpoint, commit: true, isStillRetirable: { true }
                )
                XCTAssertFalse(retired)
                XCTAssertTrue(peer.workspaceManager.activeWorkspace?.composeTabs.contains { $0.id == target.tabID } == true)
                XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains { $0.id == parentTabID } == true)
            }
        }
    }

    func testPersistedActiveChildAbsentFromLiveSessionsAndSidebarIndexStillBlocksRetirement() async throws {
        try await withFixture { fixture in
            let dataService = AgentSessionDataService.shared
            await dataService.test_setWorkspaceRootOverride(fixture.root)
            do {
                let parentID = UUID()
                var child = AgentSession(id: UUID(), name: "Unindexed child", savedAt: Date())
                child.parentSessionID = parentID
                child.lastRunState = AgentSessionRunState.running.rawValue
                let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
                _ = try await dataService.saveAgentSession(child, for: workspace)
                XCTAssertFalse(fixture.window.agentModeViewModel.sessions.values.contains {
                    $0.parentSessionID == parentID
                })
                XCTAssertFalse(fixture.window.agentModeViewModel.test_ownerValidatedSessionIndex.values.contains {
                    $0.parentSessionID == parentID
                })
                let hasPersistedChild = await WindowStatesManager.shared.agentSessionLinkHasPersistedActiveChildSessions(
                    parentSessionID: parentID
                )
                XCTAssertTrue(hasPersistedChild)
            } catch {
                await dataService.test_setWorkspaceRootOverride(nil)
                throw error
            }
            await dataService.test_setWorkspaceRootOverride(nil)
        }
    }

    func testUnreadablePersistedChildAncestorCannotProveRetirementSafe() async throws {
        try await withFixture { fixture in
            let dataService = AgentSessionDataService.shared
            let protectedRoot = fixture.root.appendingPathComponent("protected", isDirectory: true)
            try FileManager.default.createDirectory(at: protectedRoot, withIntermediateDirectories: true)
            await dataService.test_setWorkspaceRootOverride(protectedRoot)
            do {
                let parentID = UUID()
                var child = AgentSession(id: UUID(), name: "Unindexed child", savedAt: Date())
                child.parentSessionID = parentID
                child.lastRunState = AgentSessionRunState.running.rawValue
                let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
                _ = try await dataService.saveAgentSession(child, for: workspace)
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: protectedRoot.path)
                defer {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o700], ofItemAtPath: protectedRoot.path
                    )
                }
                do {
                    _ = try await dataService.persistedChildRetirementRecords(workspace: workspace)
                    XCTFail("inaccessible inventory was treated as child-free")
                } catch {}
                let retirementBlocked = await WindowStatesManager.shared.agentSessionLinkHasPersistedActiveChildSessions(
                    parentSessionID: parentID
                )
                XCTAssertTrue(retirementBlocked)
            } catch {
                await dataService.test_setWorkspaceRootOverride(nil)
                throw error
            }
            await dataService.test_setWorkspaceRootOverride(nil)
        }
    }

    // MARK: - retire_lane preflight ordering

    /// The real-host wiring the MCP `retire_lane` call uses: a seeded overseer session, a real
    /// authority, an attached bridge with a durable intent store, and an activated observer grant.
    private struct LinkedOverseer {
        let bridge: AgentSessionLinkRuntimeBridge
        let authority: DomainAgentSessionLinkAuthority
        let endpoint: DomainAgentSessionLinkEndpointIdentity
        let sessionID: UUID
    }

    private func makeLinkedOverseer(fixture: Fixture) async throws -> LinkedOverseer {
        let host = WindowStatesManager.shared
        let viewModel = fixture.window.agentModeViewModel
        let seed = try await host.agentSessionLinkCreateLane(
            destinationWindowID: fixture.window.windowID, workspaceID: fixture.workspaceID,
            creatorSessionID: UUID(), sessionName: "Retire overseer", selection: fixture.selection
        )
        guard case let .created(overseerID, overseerTabID, _) = seed else {
            XCTFail("overseer seed must save")
            throw CancellationError()
        }
        let overseer = try XCTUnwrap(viewModel.sessions[overseerTabID])
        overseer.createdByOverseerSessionID = nil
        let endpoint = try XCTUnwrap(host.agentSessionLinkCandidates().first {
            $0.sessionID == overseerID
        }).domainEndpoint
        let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
            runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()
        ))
        let bridge = AgentSessionLinkRuntimeBridge(
            authority: authority, host: host, toolAdvertisementInvalidator: { _ in }
        )
        bridge.attach(host: host)
        bridge.installIntentStore(AgentSessionOversightIntentStore(
            fileURL: fixture.root.appendingPathComponent(AgentSessionOversightIntentStore.filename),
            backupsDirectoryURL: fixture.root.appendingPathComponent("Backups"), mode: .enabled
        ))
        let activated = await bridge.becomeOverseer(
            endpoint: endpoint, isEnabled: { true }, revalidateRoute: { true },
            commitIfCurrent: { $0() }
        )
        XCTAssertNotNil(activated)
        return LinkedOverseer(
            bridge: bridge, authority: authority, endpoint: endpoint, sessionID: overseerID
        )
    }

    /// Runs the real claimed-creation path — caller preflight, model resolution, durable publish —
    /// and leaves the observer->lane link `retireLane` later consumes.
    private func createLinkedLane(
        fixture: Fixture,
        overseer: LinkedOverseer,
        name: String,
        idempotencyKey: String
    ) async throws -> (sessionID: UUID, tabID: UUID) {
        let catalog = AgentAdvertisedModelCatalog.shared
        catalog.record([
            AgentModelOption(
                rawValue: "sonnet:high", displayName: "Fixture model", description: nil,
                isPlaceholderDefault: false, isProviderDefault: false
            )
        ], for: .claudeCode, generation: catalog.productionGeneration(for: .claudeCode))
        defer { catalog.invalidate(.claudeCode) }
        fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
        try await AsyncTestWait.waitUntil("retire fixture model availability") {
            fixture.window.apiSettingsViewModel.agentAvailability.claudeCodeAvailable
        }
        let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
        let receipt = await overseer.bridge.createLane(
            observerEndpoint: overseer.endpoint,
            request: AgentSessionLaneCreateRequest(
                idempotencyKey: idempotencyKey, role: nil, modelID: "claudeCode:sonnet:high",
                sessionName: name, workspaceSelector: workspace.id.uuidString,
                message: nil, workflowReference: nil
            ),
            resolveDestination: { (fixture.window.windowID, workspace.id, workspace.name) }
        )
        guard receipt.result == .created, receipt.linked, let sessionID = receipt.sessionID else {
            XCTFail("linked lane creation refused: \(String(describing: receipt.reason))")
            throw CancellationError()
        }
        let tabID = try XCTUnwrap(fixture.window.agentModeViewModel.sessions.first {
            $0.value.activeAgentSessionID == sessionID
        }?.key)
        return (sessionID, tabID)
    }

    /// The settle save must land while the observer link is still live; only then may retire unlink.
    func testCodexLaneRetiresAfterCompactSettleFlushBeforeUnlink() async throws {
        try await withFixture { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let linked = try await makeLinkedOverseer(fixture: fixture)
            defer {
                linked.bridge.freezeForTermination()
                AgentSessionLinkRuntimeBridge.shared.attach(host: host)
            }
            let lane = try await createLinkedLane(
                fixture: fixture, overseer: linked,
                name: "Codex compact lane", idempotencyKey: "codex-compact-retire"
            )
            let laneSession = try XCTUnwrap(viewModel.sessions[lane.tabID])
            laneSession.selectedAgent = .codexExec

            // A compact still in flight refuses without touching the link or the tab.
            var compact = AgentSelfCompactState()
            _ = compact.reserve(
                note: "Continue after compaction.", idempotencyKey: "compact-\(lane.sessionID)",
                maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes
            )
            compact.active?.phase = .acpSettling
            laneSession.selfCompactState = compact
            laneSession.runState = .running
            laneSession.isDirty = true
            let midCompact = await linked.bridge.retireLane(
                observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
            )
            XCTAssertEqual(midCompact, .notRetired(sessionID: lane.sessionID, reason: .laneBusy))
            var inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertEqual(inbound.items.count, 1, "a mid-compact refusal must keep the link")
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == lane.tabID
            } == true, "a mid-compact refusal must keep the tab bound")

            // The compact settled but the settle save has not landed; the required flush inside the
            // preflight carries it. Parking the saver proves the write happens before unlinking.
            compact.settle(.noteAccepted, noteDelivery: .accepted, completionVerified: true)
            laneSession.selfCompactState = compact
            laneSession.runState = .completed
            laneSession.isDirty = true
            let flushReached = expectation(description: "settle flush runs while the link is live")
            var flushParked = false
            var releaseFlush: CheckedContinuation<Void, Never>?
            viewModel.test_setAgentSessionSaver { session, workspace, canonicalItemCount in
                if session.id == lane.sessionID, !flushParked {
                    flushParked = true
                    flushReached.fulfill()
                    await withCheckedContinuation { releaseFlush = $0 }
                }
                return try await AgentSessionDataService.shared.saveAgentSession(
                    session, for: workspace,
                    preparation: .alreadyCanonicalTranscript,
                    trustedCanonicalItemCount: canonicalItemCount
                )
            }
            defer {
                viewModel.test_setAgentSessionSaver { session, workspace, canonicalItemCount in
                    try await AgentSessionDataService.shared.saveAgentSession(
                        session, for: workspace,
                        preparation: .alreadyCanonicalTranscript,
                        trustedCanonicalItemCount: canonicalItemCount
                    )
                }
            }
            let retireDone = expectation(description: "retire finishes after the gated flush")
            var outcome: AgentSessionLaneRetireOutcome?
            Task { @MainActor in
                outcome = await linked.bridge.retireLane(
                    observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
                )
                retireDone.fulfill()
            }
            await fulfillment(of: [flushReached], timeout: 10)
            inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertEqual(inbound.items.count, 1, "the settle save must land while the link is live")
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == lane.tabID
            } == true, "the lane tab must still be bound while the flush is parked")
            releaseFlush?.resume()
            await fulfillment(of: [retireDone], timeout: 10)
            XCTAssertEqual(outcome, .retired(sessionID: lane.sessionID))
            inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertTrue(inbound.items.isEmpty)
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            XCTAssertTrue(workspace.stashedTabs.contains { $0.tab.id == lane.tabID })
            let savedRecord = try await AgentSessionDataService.shared.loadAgentSession(
                id: lane.sessionID, for: workspace
            )
            let saved = try XCTUnwrap(savedRecord)
            XCTAssertEqual(saved.lastRunState, AgentSessionRunState.completed.rawValue)
            XCTAssertEqual(saved.selfCompactState?.latest?.outcome, .noteAccepted)
        }
    }

    /// Stale persisted `running` headers must not survive the preflight flush: finished children
    /// retire with the lane and their disk records show the settled state.
    func testFinishedSubagentsRetireAfterPreflightFlushFreshensHeaders() async throws {
        try await withFixture { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let linked = try await makeLinkedOverseer(fixture: fixture)
            defer {
                linked.bridge.freezeForTermination()
                AgentSessionLinkRuntimeBridge.shared.attach(host: host)
            }
            let lane = try await createLinkedLane(
                fixture: fixture, overseer: linked,
                name: "Retire parent", idempotencyKey: "finished-subagents-retire"
            )
            var children: [(sessionID: UUID, tabID: UUID)] = []
            for index in 0 ..< 2 {
                let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                    tabID: nil, sessionID: nil, createIfNeeded: true,
                    sessionName: "Finished child \(index)", parentSessionID: lane.sessionID,
                    expectedWorkspaceID: fixture.workspaceID
                )
                let committedTarget = await viewModel.commitConfiguredSessionCreation(target: target)
                XCTAssertTrue(committedTarget, "The descendant fixture must finish its real first payload save.")
                let child = try XCTUnwrap(viewModel.sessions[target.tabID])
                try children.append((XCTUnwrap(child.activeAgentSessionID), target.tabID))
                child.runState = .running
                child.isDirty = true
                await viewModel.flushSave(for: target.tabID)
                child.runState = .completed
                child.isDirty = true
            }
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            // The persisted-child scan reads raw headers; the loaded-session reader normalizes
            // active states to idle, so staleness must be proven at the header layer.
            let rawRecords = try await AgentSessionDataService.shared.persistedChildRetirementRecords(
                workspace: workspace
            )
            for child in children {
                let staleHeader = try XCTUnwrap(rawRecords.first { $0.sessionID == child.sessionID })
                XCTAssertTrue(
                    staleHeader.blocksRetirement,
                    "precondition: the persisted header still reports an active run"
                )
            }
            let outcome = await linked.bridge.retireLane(
                observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
            )
            XCTAssertEqual(outcome, .retired(sessionID: lane.sessionID))
            let inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertTrue(inbound.items.isEmpty)
            let settledWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            XCTAssertTrue(settledWorkspace.stashedTabs.contains { $0.tab.id == lane.tabID })
            for child in children {
                XCTAssertTrue(settledWorkspace.stashedTabs.contains { $0.tab.id == child.tabID })
                let settledRecord = try await AgentSessionDataService.shared.loadAgentSession(
                    id: child.sessionID, for: settledWorkspace
                )
                let settled = try XCTUnwrap(settledRecord)
                XCTAssertEqual(settled.lastRunState, AgentSessionRunState.completed.rawValue)
            }
        }
    }

    /// A refusal raised inside the preflight leaves the grant and the tab retryably intact.
    func testInjectedPreflightRefusalKeepsLinkAndTab() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let promptManager = try XCTUnwrap(viewModel.promptManager)
            let linked = try await makeLinkedOverseer(fixture: fixture)
            defer {
                linked.bridge.freezeForTermination()
                AgentSessionLinkRuntimeBridge.shared.attach(host: host)
            }
            let lane = try await createLinkedLane(
                fixture: fixture, overseer: linked,
                name: "Preflight refusal lane", idempotencyKey: "preflight-refusal-retire"
            )

            // The required-session flush refuses inside the validate-only pass.
            let abortToken = promptManager.setComposeTabsRemovalPreflight { _, _, _ in
                .abort(.init(
                    stage: .requiredSessionFlush, tabID: nil,
                    message: "injected retirement preflight refusal"
                ))
            }
            let refused = await linked.bridge.retireLane(
                observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
            )
            XCTAssertEqual(refused, .notRetired(sessionID: lane.sessionID, reason: .laneBusy))
            var inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertEqual(inbound.items.count, 1, "a preflight refusal must keep the link")
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == lane.tabID
            } == true, "a preflight refusal must keep the tab bound")
            XCTAssertFalse(fixture.window.workspaceManager.activeWorkspace?.stashedTabs.contains {
                $0.tab.id == lane.tabID
            } == true)

            // The save-admission probe refuses the same way, still without unlinking.
            promptManager.removeComposeTabsRemovalPreflight(abortToken)
            _ = promptManager.setComposeTabsRemovalPreflight { [weak viewModel] tabIDs, reason, workspaceID in
                guard let viewModel else { return .proceed }
                return await viewModel.preflightComposeTabsRemoval(
                    tabIDs, reason: reason, workspaceID: workspaceID
                )
            }
            fixture.window.workspaceManager.setWorkspacePersistenceOutcomeOverrideForTesting(
                .rejected(reason: "injected workspace save refusal")
            )
            defer {
                fixture.window.workspaceManager.setWorkspacePersistenceOutcomeOverrideForTesting(nil)
            }
            let saveRefused = await linked.bridge.retireLane(
                observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
            )
            XCTAssertEqual(saveRefused, .notRetired(sessionID: lane.sessionID, reason: .laneBusy))
            inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertEqual(inbound.items.count, 1, "a save-admission refusal must keep the link")
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == lane.tabID
            } == true)

            // With the injection cleared, the identical call retires the lane.
            fixture.window.workspaceManager.setWorkspacePersistenceOutcomeOverrideForTesting(nil)
            let retired = await linked.bridge.retireLane(
                observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
            )
            XCTAssertEqual(retired, .retired(sessionID: lane.sessionID))
            inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertTrue(inbound.items.isEmpty)
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.stashedTabs.contains {
                $0.tab.id == lane.tabID
            } == true)
        }
    }

    /// A workspace-save refusal raised after the stash has committed does not un-retire the lane:
    /// the link is gone, the tab and its settled children already sit in `stashedTabs`, and the
    /// outcome is `retired` — the normal save cadence persists the mutation later.
    func testWorkspaceSaveRefusalAfterCommittedStashStillReportsRetired() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let linked = try await makeLinkedOverseer(fixture: fixture)
            defer {
                linked.bridge.freezeForTermination()
                AgentSessionLinkRuntimeBridge.shared.attach(host: host)
            }
            let lane = try await createLinkedLane(
                fixture: fixture, overseer: linked,
                name: "Post-stash save refusal lane", idempotencyKey: "post-stash-save-refusal"
            )
            let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true,
                sessionName: "Settled child", parentSessionID: lane.sessionID,
                expectedWorkspaceID: fixture.workspaceID
            )
            let committedTarget = await viewModel.commitConfiguredSessionCreation(target: target)
            XCTAssertTrue(committedTarget, "The descendant fixture must finish its real first payload save.")
            let child = try XCTUnwrap(viewModel.sessions[target.tabID])
            child.runState = .idle
            child.isDirty = true
            await viewModel.flushSave(for: target.tabID)
            // Arm the refusal inside the stop admission hook: the preflight probe has already
            // passed, so the rejection can only land on the post-unlink workspace save — which no
            // longer gates the outcome once the stash has committed.
            linked.bridge.test_afterStopAdmission = {
                linked.bridge.test_afterStopAdmission = nil
                fixture.window.workspaceManager.setWorkspacePersistenceOutcomeOverrideForTesting(
                    .rejected(reason: "injected post-stash save refusal")
                )
            }
            defer {
                fixture.window.workspaceManager.setWorkspacePersistenceOutcomeOverrideForTesting(nil)
            }
            let outcome = await linked.bridge.retireLane(
                observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
            )
            XCTAssertEqual(outcome, .retired(sessionID: lane.sessionID))
            let inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertTrue(inbound.items.isEmpty, "the link was honestly removed before the refusal")
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            XCTAssertTrue(workspace.stashedTabs.contains { $0.tab.id == lane.tabID })
            XCTAssertTrue(
                workspace.stashedTabs.contains { $0.tab.id == target.tabID },
                "the settled child must ride the same committed stash"
            )
            XCTAssertFalse(workspace.composeTabs.contains { $0.id == lane.tabID })
        }
    }

    /// `unlinked_not_stashed` is reserved for the genuine case: the link is gone but the stash
    /// itself never committed. A quiescence flip injected after the unlink makes the commit-time
    /// CAS refuse before any projection mutation, so the tab stays live and the outcome is honest.
    func testPostUnlinkUncommittedStashStillReportsUnlinkedNotStashed() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let linked = try await makeLinkedOverseer(fixture: fixture)
            defer {
                linked.bridge.freezeForTermination()
                AgentSessionLinkRuntimeBridge.shared.attach(host: host)
            }
            let lane = try await createLinkedLane(
                fixture: fixture, overseer: linked,
                name: "Uncommitted stash lane", idempotencyKey: "uncommitted-stash-retire"
            )
            // Flip the lane's live session to active inside the stop admission hook: the commit-time
            // revalidation then refuses before the stash mutates anything — the honest residual.
            linked.bridge.test_afterStopAdmission = {
                linked.bridge.test_afterStopAdmission = nil
                viewModel.sessions[lane.tabID]?.runState = .running
            }
            let outcome = await linked.bridge.retireLane(
                observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
            )
            XCTAssertEqual(outcome, .unlinkedNotStashed(sessionID: lane.sessionID))
            let inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertTrue(inbound.items.isEmpty, "the link was honestly removed before the refusal")
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            XCTAssertFalse(
                workspace.stashedTabs.contains { $0.tab.id == lane.tabID },
                "an uncommitted stash must leave the tab live"
            )
            XCTAssertTrue(workspace.composeTabs.contains { $0.id == lane.tabID })
        }
    }

    /// A lazily-bound child whose state has not hydrated looks quiescent on defaults alone, so its
    /// live record must never shadow the persisted header's fail-closed signal. The flushed index
    /// stays non-blocking so only the merged disk scan can refuse.
    private func seedUnhydratedBoundChild(
        fixture: Fixture, viewModel: AgentModeViewModel, laneSessionID: UUID,
        persistedRunState: String?
    ) async throws -> (sessionID: UUID, tabID: UUID) {
        let target = try await viewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil, sessionID: nil, createIfNeeded: true,
            sessionName: "Mid-hydration child", parentSessionID: laneSessionID,
            expectedWorkspaceID: fixture.workspaceID
        )
        let committedTarget = await viewModel.commitConfiguredSessionCreation(target: target)
        XCTAssertTrue(committedTarget, "The descendant fixture must finish its real first payload save.")
        let child = try XCTUnwrap(viewModel.sessions[target.tabID])
        let childSessionID = try XCTUnwrap(child.activeAgentSessionID)
        child.runState = .idle
        child.isDirty = true
        await viewModel.flushSave(for: target.tabID)
        child.hasLoadedPersistedState = false
        var persisted = AgentSession(id: childSessionID, name: "Mid-hydration child", savedAt: Date())
        persisted.parentSessionID = laneSessionID
        persisted.lastRunState = persistedRunState
        let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
        _ = try await AgentSessionDataService.shared.saveAgentSession(persisted, for: workspace)
        return (childSessionID, target.tabID)
    }

    /// A persisted `running` header plus an unhydrated idle-looking stub must still refuse the
    /// unlink before it happens, keeping the link and the tab retryably intact.
    func testUnhydratedChildStubKeepsPersistedActiveHeaderBlocking() async throws {
        try await withFixture { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let linked = try await makeLinkedOverseer(fixture: fixture)
            defer {
                linked.bridge.freezeForTermination()
                AgentSessionLinkRuntimeBridge.shared.attach(host: host)
            }
            let lane = try await createLinkedLane(
                fixture: fixture, overseer: linked,
                name: "Unhydrated-stub parent", idempotencyKey: "unhydrated-stub-blocks"
            )
            let child = try await seedUnhydratedBoundChild(
                fixture: fixture, viewModel: viewModel, laneSessionID: lane.sessionID,
                persistedRunState: AgentSessionRunState.running.rawValue
            )
            let blocked = await host.agentSessionLinkHasPersistedActiveChildSessions(
                parentSessionID: lane.sessionID
            )
            XCTAssertTrue(blocked, "the unhydrated stub must not clear the persisted block")
            let outcome = await linked.bridge.retireLane(
                observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
            )
            XCTAssertEqual(outcome, .notRetired(sessionID: lane.sessionID, reason: .laneInUseDiskChild))
            let inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertEqual(inbound.items.count, 1, "a pre-unlink refusal must keep the link")
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == lane.tabID
            } == true, "a pre-unlink refusal must keep the tab")
            XCTAssertFalse(fixture.window.workspaceManager.activeWorkspace?.stashedTabs.contains {
                $0.tab.id == lane.tabID || $0.tab.id == child.tabID
            } == true)
        }
    }

    /// A persisted header that decodes without a usable `lastRunState` fails closed; an unhydrated
    /// stub must not clear that either.
    func testUnhydratedChildStubKeepsMissingHeaderBlocking() async throws {
        try await withFixture { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let linked = try await makeLinkedOverseer(fixture: fixture)
            defer {
                linked.bridge.freezeForTermination()
                AgentSessionLinkRuntimeBridge.shared.attach(host: host)
            }
            let lane = try await createLinkedLane(
                fixture: fixture, overseer: linked,
                name: "Unhydrated-stub parent", idempotencyKey: "unhydrated-missing-blocks"
            )
            let child = try await seedUnhydratedBoundChild(
                fixture: fixture, viewModel: viewModel, laneSessionID: lane.sessionID,
                persistedRunState: nil
            )
            let blocked = await host.agentSessionLinkHasPersistedActiveChildSessions(
                parentSessionID: lane.sessionID
            )
            XCTAssertTrue(blocked, "a missing header state must fail closed under an unhydrated stub")
            let outcome = await linked.bridge.retireLane(
                observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
            )
            XCTAssertEqual(outcome, .notRetired(sessionID: lane.sessionID, reason: .laneInUseDiskChild))
            let inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertEqual(inbound.items.count, 1, "a pre-unlink refusal must keep the link")
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == lane.tabID
            } == true, "a pre-unlink refusal must keep the tab")
            XCTAssertFalse(fixture.window.workspaceManager.activeWorkspace?.stashedTabs.contains {
                $0.tab.id == lane.tabID || $0.tab.id == child.tabID
            } == true)
        }
    }

    /// Ambiguous lineage across provenance tiers fails closed: conflicting non-nil parents, or a
    /// hydrated "no parent" vote against a claimed edge, keep every edge and force the block. Only
    /// coherent lineage lets hydrated quiescence shadow a stale persisted or index block.
    func testChildRetirementMergeFailsClosedOnAmbiguousLineage() {
        let sessionID = UUID()
        let parentA = UUID()
        let parentB = UUID()
        let parentC = UUID()
        func record(
            _ source: AgentSessionLaneChildRetirementRecord.Source,
            parent: UUID? = parentA, blocks: Bool
        ) -> AgentSessionLaneChildRetirementRecord {
            .init(sessionID: sessionID, parentSessionID: parent, blocksRetirement: blocks, source: source)
        }
        let blockingPersisted = record(.persisted, blocks: true)
        // Conflicting session-derived parents keep both edges and force the block.
        let conflicted = AgentSessionLaneChildRetirementRecord.merging(
            sessionID: sessionID,
            live: [
                record(.hydratedSession, parent: parentA, blocks: true),
                record(.hydratedSession, parent: parentB, blocks: true)
            ],
            persisted: [blockingPersisted]
        )
        XCTAssertEqual(Set(conflicted.map(\.parentSessionID)), [parentA, parentB])
        XCTAssertTrue(conflicted.allSatisfy(\.blocksRetirement))
        XCTAssertTrue(AgentSessionLaneChildRetirementRecord.hasBlockingDescendant(of: parentA, in: conflicted))
        XCTAssertTrue(AgentSessionLaneChildRetirementRecord.hasBlockingDescendant(of: parentB, in: conflicted))
        // Cross-tier disagreement keeps every claimed edge and blocks even with quiescent records.
        let crossTier = AgentSessionLaneChildRetirementRecord.merging(
            sessionID: sessionID,
            live: [
                record(.unhydratedSession, parent: parentB, blocks: false),
                record(.sessionIndex, parent: parentC, blocks: false)
            ],
            persisted: [blockingPersisted]
        )
        XCTAssertEqual(Set(crossTier.map(\.parentSessionID)), [parentA, parentB, parentC])
        XCTAssertTrue(crossTier.allSatisfy(\.blocksRetirement))
        // Persisted rows that disagree with each other get the same ambiguous-lineage treatment.
        let persistedConflict = AgentSessionLaneChildRetirementRecord.merging(
            sessionID: sessionID,
            live: [],
            persisted: [blockingPersisted, record(.persisted, parent: parentB, blocks: false)]
        )
        XCTAssertEqual(Set(persistedConflict.map(\.parentSessionID)), [parentA, parentB])
        XCTAssertTrue(persistedConflict.allSatisfy(\.blocksRetirement))
        // A hydrated "no parent" vote against a claimed edge is a conflict, not absent evidence:
        // the edge survives and blocks.
        for live in [
            [record(.hydratedSession, parent: nil, blocks: false)],
            [record(.hydratedSession, parent: nil, blocks: false), record(.sessionIndex, blocks: false)]
        ] {
            let merged = AgentSessionLaneChildRetirementRecord.merging(
                sessionID: sessionID, live: live, persisted: [blockingPersisted]
            )
            XCTAssertEqual(merged.map(\.parentSessionID), [parentA])
            XCTAssertTrue(merged.allSatisfy(\.blocksRetirement))
        }
        // A decoded disk header's nil is a complete-lineage "no parent" claim too: persisted-nil
        // against any claimed edge is ambiguous and forces the block.
        for persisted in [
            [record(.persisted, parent: nil, blocks: true)],
            [record(.persisted, parent: nil, blocks: false), record(.persisted, blocks: false)]
        ] {
            let merged = AgentSessionLaneChildRetirementRecord.merging(
                sessionID: sessionID,
                live: [record(.hydratedSession, blocks: false)],
                persisted: persisted
            )
            XCTAssertEqual(merged.map(\.parentSessionID), [parentA])
            XCTAssertTrue(merged.allSatisfy(\.blocksRetirement))
        }
        // Index and unhydrated nils stay non-authoritative: they can neither conflict nor erase.
        let unknownNil = AgentSessionLaneChildRetirementRecord.merging(
            sessionID: sessionID,
            live: [
                record(.unhydratedSession, parent: nil, blocks: false),
                record(.sessionIndex, parent: nil, blocks: false)
            ],
            persisted: [blockingPersisted]
        )
        XCTAssertEqual(unknownNil.map(\.parentSessionID), [parentA])
        XCTAssertTrue(unknownNil.allSatisfy(\.blocksRetirement))
        // Coherent lineage keeps the single agreed edge and the hydration gate on blocking.
        for live in [
            [record(.unhydratedSession, blocks: false)],
            [record(.sessionIndex, blocks: false)],
            [record(.unhydratedSession, blocks: false), record(.sessionIndex, blocks: false)]
        ] {
            let merged = AgentSessionLaneChildRetirementRecord.merging(
                sessionID: sessionID, live: live, persisted: [blockingPersisted]
            )
            XCTAssertEqual(merged.map(\.parentSessionID), [parentA])
            XCTAssertTrue(merged.allSatisfy(\.blocksRetirement))
        }
        for (live, expectBlocks) in [
            ([record(.hydratedSession, blocks: false)], false),
            ([record(.hydratedSession, blocks: false), record(.sessionIndex, blocks: true)], false),
            ([record(.hydratedSession, blocks: true)], true),
            ([record(.hydratedSession, blocks: false), record(.unhydratedSession, blocks: true)], true)
        ] {
            let merged = AgentSessionLaneChildRetirementRecord.merging(
                sessionID: sessionID, live: live, persisted: [blockingPersisted]
            )
            XCTAssertEqual(merged.map(\.blocksRetirement), [expectBlocks])
        }
        // Nil-only evidence yields a single nil-parent record — agreeing "no parent" votes are
        // coherent, not a conflict.
        for persisted in [
            [record(.persisted, parent: nil, blocks: false)],
            [record(.persisted, parent: nil, blocks: true)],
            []
        ] {
            let topLevel = AgentSessionLaneChildRetirementRecord.merging(
                sessionID: sessionID,
                live: [record(.hydratedSession, parent: nil, blocks: false)],
                persisted: persisted
            )
            XCTAssertEqual(topLevel.map(\.parentSessionID), [nil])
            XCTAssertFalse(topLevel[0].blocksRetirement)
        }
    }

    /// Persisted `X -> lane running` plus a hydrated `X -> otherParent idle` is ambiguous lineage:
    /// the persisted edge must survive and force the block, so retiring the lane refuses with the
    /// link and both tabs intact.
    func testCrossTierParentConflictKeepsPersistedEdgeBlocking() async throws {
        try await withFixture { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let linked = try await makeLinkedOverseer(fixture: fixture)
            defer {
                linked.bridge.freezeForTermination()
                AgentSessionLinkRuntimeBridge.shared.attach(host: host)
            }
            let lane = try await createLinkedLane(
                fixture: fixture, overseer: linked,
                name: "Persisted parent", idempotencyKey: "cross-tier-conflict-blocks"
            )
            let otherTarget = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true,
                sessionName: "Unrelated parent", parentSessionID: nil,
                expectedWorkspaceID: fixture.workspaceID
            )
            let committedOtherTarget = await viewModel.commitConfiguredSessionCreation(target: otherTarget)
            XCTAssertTrue(committedOtherTarget, "The descendant fixture must finish its real first payload save.")
            let otherParent = try XCTUnwrap(viewModel.sessions[otherTarget.tabID])
            let otherParentSessionID = try XCTUnwrap(otherParent.activeAgentSessionID)
            let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true,
                sessionName: "Cross-tier child", parentSessionID: otherParentSessionID,
                expectedWorkspaceID: fixture.workspaceID
            )
            let committedTarget = await viewModel.commitConfiguredSessionCreation(target: target)
            XCTAssertTrue(committedTarget, "The descendant fixture must finish its real first payload save.")
            let child = try XCTUnwrap(viewModel.sessions[target.tabID])
            let childSessionID = try XCTUnwrap(child.activeAgentSessionID)
            child.runState = .idle
            child.isDirty = true
            await viewModel.flushSave(for: target.tabID)
            // The disk row disagrees with live lineage: it claims the lane as parent and is active.
            var persisted = AgentSession(id: childSessionID, name: "Cross-tier child", savedAt: Date())
            persisted.parentSessionID = lane.sessionID
            persisted.lastRunState = AgentSessionRunState.running.rawValue
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            _ = try await AgentSessionDataService.shared.saveAgentSession(persisted, for: workspace)
            let blocked = await host.agentSessionLinkHasPersistedActiveChildSessions(
                parentSessionID: lane.sessionID
            )
            XCTAssertTrue(blocked, "the dropped persisted edge must still reach the lane's subtree")
            let outcome = await linked.bridge.retireLane(
                observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
            )
            XCTAssertEqual(outcome, .notRetired(sessionID: lane.sessionID, reason: .laneInUseDiskChild))
            let inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertEqual(inbound.items.count, 1, "a pre-unlink refusal must keep the link")
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == lane.tabID
            } == true, "a pre-unlink refusal must keep the tab")
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == target.tabID
            } == true, "the ambiguous-lineage child must not be stashed")
        }
    }

    /// A persisted header's nil parent is a complete top-level lineage claim, so `X -> nil` active
    /// on disk plus a hydrated `X -> lane idle` is ambiguous: the live edge survives and forces
    /// the block, and retiring the lane refuses with link and child tab intact.
    func testPersistedNilParentConflictKeepsLiveEdgeBlocking() async throws {
        try await withFixture { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let linked = try await makeLinkedOverseer(fixture: fixture)
            defer {
                linked.bridge.freezeForTermination()
                AgentSessionLinkRuntimeBridge.shared.attach(host: host)
            }
            let lane = try await createLinkedLane(
                fixture: fixture, overseer: linked,
                name: "Persisted nil parent", idempotencyKey: "persisted-nil-conflict-blocks"
            )
            let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true,
                sessionName: "Disk-orphaned child", parentSessionID: lane.sessionID,
                expectedWorkspaceID: fixture.workspaceID
            )
            let committedTarget = await viewModel.commitConfiguredSessionCreation(target: target)
            XCTAssertTrue(committedTarget, "The descendant fixture must finish its real first payload save.")
            let child = try XCTUnwrap(viewModel.sessions[target.tabID])
            let childSessionID = try XCTUnwrap(child.activeAgentSessionID)
            child.runState = .idle
            child.isDirty = true
            await viewModel.flushSave(for: target.tabID)
            // The disk row disagrees completely: it claims no parent edge and still says running.
            var persisted = AgentSession(id: childSessionID, name: "Disk-orphaned child", savedAt: Date())
            persisted.parentSessionID = nil
            persisted.lastRunState = AgentSessionRunState.running.rawValue
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            _ = try await AgentSessionDataService.shared.saveAgentSession(persisted, for: workspace)
            let blocked = await host.agentSessionLinkHasPersistedActiveChildSessions(
                parentSessionID: lane.sessionID
            )
            XCTAssertTrue(blocked, "a persisted no-parent claim must not erase the live lane edge")
            let outcome = await linked.bridge.retireLane(
                observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
            )
            XCTAssertEqual(outcome, .notRetired(sessionID: lane.sessionID, reason: .laneInUseDiskChild))
            let inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertEqual(inbound.items.count, 1, "a pre-unlink refusal must keep the link")
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == lane.tabID
            } == true, "a pre-unlink refusal must keep the tab")
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == target.tabID
            } == true, "the disk-orphaned child must not be stashed")
        }
    }

    /// A hydrated "no parent" vote against the persisted edge is a lineage conflict, not absent
    /// evidence: the edge survives and forces the block, so the lane refuses and the child is
    /// never stashed into it.
    func testHydratedNilParentConflictKeepsPersistedEdgeBlocking() async throws {
        try await withFixture { fixture in
            let host = WindowStatesManager.shared
            let viewModel = fixture.window.agentModeViewModel
            let linked = try await makeLinkedOverseer(fixture: fixture)
            defer {
                linked.bridge.freezeForTermination()
                AgentSessionLinkRuntimeBridge.shared.attach(host: host)
            }
            let lane = try await createLinkedLane(
                fixture: fixture, overseer: linked,
                name: "Persisted parent", idempotencyKey: "hydrated-nil-conflict-blocks"
            )
            let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true,
                sessionName: "Repudiated child", parentSessionID: lane.sessionID,
                expectedWorkspaceID: fixture.workspaceID
            )
            let committedTarget = await viewModel.commitConfiguredSessionCreation(target: target)
            XCTAssertTrue(committedTarget, "The descendant fixture must finish its real first payload save.")
            let child = try XCTUnwrap(viewModel.sessions[target.tabID])
            child.runState = .idle
            child.isDirty = true
            await viewModel.flushSave(for: target.tabID)
            // The loaded session now reports itself top-level while disk still claims the edge.
            child.parentSessionID = nil
            let blocked = await host.agentSessionLinkHasPersistedActiveChildSessions(
                parentSessionID: lane.sessionID
            )
            XCTAssertTrue(blocked, "a hydrated no-parent vote must not silently erase the disk edge")
            let outcome = await linked.bridge.retireLane(
                observerEndpoint: linked.endpoint, targetSessionID: lane.sessionID
            )
            XCTAssertEqual(outcome, .notRetired(sessionID: lane.sessionID, reason: .laneInUseDiskChild))
            let inbound = await linked.authority.links(forTarget: lane.sessionID)
            XCTAssertEqual(inbound.items.count, 1, "a pre-unlink refusal must keep the link")
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            XCTAssertTrue(workspace.composeTabs.contains { $0.id == lane.tabID })
            XCTAssertFalse(workspace.stashedTabs.contains {
                $0.tab.id == lane.tabID || $0.tab.id == target.tabID
            }, "the conflicted child must never be stashed into a disputed subtree")
        }
    }
}
