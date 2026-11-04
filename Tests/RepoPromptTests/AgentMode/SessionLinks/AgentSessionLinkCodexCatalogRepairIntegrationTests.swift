import Combine
import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptShared
import XCTest

/// Covers the production server path that repairs a stale Codex catalog when an exact grant is
/// restored, including an inbound-only created lane.
@MainActor
final class AgentSessionLinkCodexCatalogRepairIntegrationTests: XCTestCase {
    private let clientName = AgentProviderKind.openCodeMCPClientID

    func testRestoredOutboundGrantInvalidationRepairsCodexCatalogThroughServerProjection() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: true)
    }

    func testRestoredCreatedLaneInboundGrantRepairsCodexCatalogWithoutOutboundAuthority() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: false)
    }

    func testActivatedNoLinkRepairsCatalogOnNextTurn() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: false, surfaceTransition: .activation)
    }

    func testReducedCatalogUpgradeRepairsOnceAfterQuiescence() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: true, surfaceTransition: .upgrade)
    }

    func testBareOrchestratorCanDiscoverScopeRequestsWithoutAnyGrant() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: false, surfaceTransition: .orchestrator)
    }

    func testDelegationEligibilityAndForcedRelistPreserveRoleSizedOversightSurface() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: false, surfaceTransition: .delegation)
    }

    func testToolbarActivationAndRetirementRelistScopeEligibilityWithoutGrantingAuthority() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: false, surfaceTransition: .toolbar)
    }

    func testIgnoredScopeGrantNotificationRepairsCatalogAfterQuiescence() async throws {
        // With oversight enabled, an eligible session lists session_admin from its first turn, so a
        // scope grant or revocation does not change its surface and needs no repair. The repair
        // path remains for the oversight-disabled surface, where only scope authority lists it.
        for oversightEnabled in [false] {
            try await assertRestoredGrantRepairsCatalog(
                outbound: false, surfaceTransition: .delegationGrant, oversightEnabled: oversightEnabled
            )
        }
    }

    func testIgnoredScopeRevocationNotificationRepairsCatalogAfterQuiescence() async throws {
        // With oversight enabled, an eligible session lists session_admin from its first turn, so a
        // scope grant or revocation does not change its surface and needs no repair. The repair
        // path remains for the oversight-disabled surface, where only scope authority lists it.
        for oversightEnabled in [false] {
            try await assertRestoredGrantRepairsCatalog(
                outbound: false, surfaceTransition: .delegationRevocation, oversightEnabled: oversightEnabled
            )
        }
    }

    private enum SurfaceTransition { case activation, upgrade, orchestrator, delegation, toolbar, delegationGrant, delegationRevocation }

    private func assertRestoredGrantRepairsCatalog(
        outbound: Bool, surfaceTransition: SurfaceTransition? = nil, oversightEnabled: Bool = true
    ) async throws {
        #if DEBUG
            let manager = ServerNetworkManager(
                domainHost: AppDomainRuntimeComposition.shared.runtime.domainHost
            )
            let window = makeWindow()
            WindowStatesManager.shared.registerWindowState(window)
            let runID = UUID()
            let connectionID = UUID()
            let tabID = UUID()
            let conversationID = "restored-oversight-thread"
            let rolloutPath = "/tmp/restored-oversight-rollout.jsonl"

            let registration: MCPDomainToolRegistrationResult
            do {
                try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                registration = try await AppDomainRuntimeComposition.shared.register(
                    window.mcpServer.windowMCPToolCatalogService
                )
            } catch {
                WindowStatesManager.shared.unregisterWindowState(window)
                throw error
            }
            addTeardownBlock { @MainActor in
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(
                    anyActive: nil,
                    outbound: nil
                )
                await self.cleanup(
                    manager: manager,
                    runID: runID,
                    connectionID: connectionID,
                    windowID: window.windowID
                )
                await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                WindowStatesManager.shared.unregisterWindowState(window)
            }

            await window.workspaceManager.awaitInitialized()
            try await installRoutingSnapshot(for: tabID, in: window)
            let session = window.agentModeViewModel.session(for: tabID)
            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            session.selectedAgent = .codexExec
            session.hasLoadedPersistedState = true
            session.createdByOverseerSessionID = outbound || surfaceTransition != nil ? nil : UUID()
            session.installRunID(runID)
            session.codexConversationID = conversationID
            session.codexRolloutPath = rolloutPath
            session.codexController = controller
            // Catalog repair begins with an existing restored conversation.
            _ = try XCTUnwrap(window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session, updateWorkspaceMetadata: true))
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            XCTAssertTrue(session.qualifiedRestorationReadiness.isAuthoritative)
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                window.agentModeViewModel,
                tabID: tabID
            )
            let isScopeRepair = surfaceTransition == .delegationGrant || surfaceTransition == .delegationRevocation
            let scopes = AgentSessionLinkRuntimeBridge.shared.delegationScopes
            let scopeSessionID = try XCTUnwrap(session.activeAgentSessionID)
            func grantScope() throws -> UUID {
                let request = try scopes.requestScope(
                    requesterSessionID: scopeSessionID, requesterTabID: tabID,
                    kind: .tree(rootSessionID: scopeSessionID), capabilities: [.observe],
                    guardrails: .init(), reason: nil, idempotencyKey: nil
                ).get()
                let scope = try scopes.approve(
                    requestID: request.id, presentedWindowID: window.windowID,
                    presentedTabID: tabID, presentedSessionID: scopeSessionID
                ).get()
                addTeardownBlock { @MainActor in scopes.revoke(scopeID: scope.id) }
                return scope.id
            }
            var scopeToRevoke: UUID?
            if isScopeRepair {
                let availability = ToolAvailabilityStore.shared
                let wasEnabled = availability.isEnabled(MCPWindowToolName.agentSessionLink)
                XCTAssertTrue(availability.isEnabled(MCPWindowToolName.sessionAdmin))
                await availability.toggle(MCPWindowToolName.agentSessionLink, enabled: oversightEnabled)
                addTeardownBlock { @MainActor in
                    await availability.toggle(MCPWindowToolName.agentSessionLink, enabled: wasEnabled)
                }
                if surfaceTransition == .delegationRevocation { scopeToRevoke = try grantScope() }
            }
            await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: surfaceTransition == .upgrade ? [endpoint] : [], outbound: [])
            if surfaceTransition != nil { session.runState = .running }
            await installAuthoritativePolicy(
                manager: manager,
                runID: runID,
                tabID: tabID,
                windowID: window.windowID,
                allowsAgentExternalControlTools: surfaceTransition == .orchestrator
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            let testConnection = CatalogRepairPolicyAuthorityTestConnection()
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: testConnection,
                pendingClientID: clientName
            )
            let applied = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: "catalog-repair-\(runID.uuidString)",
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            XCTAssertEqual(applied.outcome, "applied")

            let names = try await manager.debugListToolNames(for: connectionID)
            XCTAssertEqual(names.contains(MCPWindowToolName.agentSessionLink), surfaceTransition == .upgrade)
            let unlinkedProjection = await manager.debugRunCatalogProjection(for: runID)
            let unlinked = try XCTUnwrap(unlinkedProjection)
            XCTAssertEqual(unlinked.hasAgentSessionLink, surfaceTransition == .upgrade)
            XCTAssertEqual(unlinked.hasActiveOutboundLink, false)
            XCTAssertNil(session.codexSessionLinkCatalogRepairCycle?.observedControllerGeneration)
            XCTAssertNotNil(session.codexController)

            let sessionID = try XCTUnwrap(session.activeAgentSessionID)
            if surfaceTransition == .orchestrator {
                XCTAssertTrue(names.contains(MCPWindowToolName.sessionAdmin), "Bare orchestrators can request authority, not exercise it")
                XCTAssertFalse(AgentSessionLinkRuntimeBridge.shared.delegationScopes.hasLiveScope(grantedTo: sessionID))
                return
            }
            if surfaceTransition == .toolbar {
                XCTAssertTrue(names.contains(MCPWindowToolName.sessionAdmin), "An eligible session can request a scope from its first turn")
                let host = WindowStatesManager.shared
                let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
                    runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()
                ))
                let bridge = AgentSessionLinkRuntimeBridge(
                    authority: authority, host: host,
                    toolAdvertisementInvalidator: { await manager.notifyToolListChangedForAgentSession($0) }
                )
                bridge.attach(host: host)
                defer { host.attachAgentSessionLinkBridge() }
                let scopes = AgentSessionLinkRuntimeBridge.shared.delegationScopes
                let availability = ToolAvailabilityStore.shared
                let oversightWasEnabled = availability.isEnabled(MCPWindowToolName.agentSessionLink)
                XCTAssertTrue(oversightWasEnabled)
                addTeardownBlock { @MainActor in
                    await availability.toggle(MCPWindowToolName.agentSessionLink, enabled: oversightWasEnabled)
                }
                for (keepScope, disableOversight) in [(false, false), (false, true), (true, true)] {
                    let beforeActivation = await testConnection.notificationCount()
                    let expected = try XCTUnwrap(window.agentModeViewModel.agentSessionLinkBootstrapState(for: endpoint))
                    let enabled = await bridge.enableOverseerFromToolbar(endpoint: endpoint, expected: expected, isEnabled: { true })
                    XCTAssertTrue(enabled)
                    let afterActivation = await testConnection.notificationCount()
                    XCTAssertGreaterThan(afterActivation, beforeActivation, "Toolbar consent relists the exact running Agent route")
                    let activatedNames = try await manager.debugListToolNames(for: connectionID)
                    XCTAssertTrue(activatedNames.contains(MCPWindowToolName.sessionAdmin))
                    XCTAssertTrue(activatedNames.contains(MCPWindowToolName.agentSessionLink))
                    // Activation exposes controls but retains targeted bootstrap discovery.
                    XCTAssertTrue(activatedNames.contains(MCPWindowToolName.becomeOverseer))
                    XCTAssertFalse(scopes.hasLiveScope(grantedTo: sessionID), "Opt-in is discovery, not user-granted scope authority")
                    let links = await authority.links(forObserver: sessionID)
                    XCTAssertTrue(links.items.isEmpty, "Toolbar consent never manufactures a link")
                    var scopeID: UUID?
                    if keepScope {
                        let request = try scopes.requestScope(
                            requesterSessionID: sessionID, requesterTabID: tabID,
                            kind: .tree(rootSessionID: sessionID), capabilities: [.observe],
                            guardrails: .init(), reason: nil, idempotencyKey: nil
                        ).get()
                        let scope = try scopes.approve(
                            requestID: request.id, presentedWindowID: window.windowID,
                            presentedTabID: tabID, presentedSessionID: sessionID
                        ).get()
                        scopeID = scope.id
                        addTeardownBlock { @MainActor in scopes.revoke(scopeID: scope.id) }
                    }
                    if disableOversight {
                        await availability.toggle(MCPWindowToolName.agentSessionLink, enabled: false)
                        let disabledNames = try await manager.debugListToolNames(for: connectionID)
                        XCTAssertEqual(disabledNames.contains(MCPWindowToolName.sessionAdmin), keepScope, "Disabled oversight withdraws opt-in-only scope requests, not independently approved scope authority")
                        XCTAssertFalse(disabledNames.contains(MCPWindowToolName.agentSessionLink))
                        XCTAssertFalse(disabledNames.contains(MCPWindowToolName.becomeOverseer))
                        XCTAssertNotNil(session.oversight.overseerActivation, "Availability changes do not retire user consent")
                    }
                    let beforeRetirement = await testConnection.notificationCount()
                    session.oversight.overseerActivation = nil
                    if !disableOversight {
                        try await AsyncTestWait.waitUntil("activation retirement relists the exact Agent route") {
                            await testConnection.notificationCount() > beforeRetirement
                        }
                    }
                    let retiredNames = try await manager.debugListToolNames(for: connectionID)
                    XCTAssertEqual(
                        retiredNames.contains(MCPWindowToolName.sessionAdmin), keepScope || !disableOversight,
                        "Retirement keeps scope requests for an eligible session; disabled oversight keeps only approved scope authority"
                    )
                    XCTAssertFalse(retiredNames.contains(MCPWindowToolName.agentSessionLink), "A durable scope does not fabricate oversight activation or pair grants")
                    XCTAssertEqual(retiredNames.contains(MCPWindowToolName.becomeOverseer), !disableOversight)
                    if let scopeID {
                        scopes.revoke(scopeID: scopeID)
                        let beforeRevoke = await testConnection.notificationCount()
                        await manager.notifyToolListChangedForAgentSession(sessionID, forceRelist: true)
                        let afterRevoke = await testConnection.notificationCount()
                        XCTAssertGreaterThan(afterRevoke, beforeRevoke, "Scope-only withdrawal relists despite an unchanged oversight fingerprint")
                        let revokedNames = try await manager.debugListToolNames(for: connectionID)
                        XCTAssertFalse(revokedNames.contains(MCPWindowToolName.sessionAdmin))
                    }
                    if disableOversight {
                        await availability.toggle(MCPWindowToolName.agentSessionLink, enabled: true)
                        await manager.notifyToolListChangedForAgentSession(sessionID)
                        let reenabledNames = try await manager.debugListToolNames(for: connectionID)
                        XCTAssertTrue(reenabledNames.contains(MCPWindowToolName.sessionAdmin), "Re-enabling the family restores scope requests for an eligible session")
                        XCTAssertFalse(reenabledNames.contains(MCPWindowToolName.agentSessionLink), "Re-enabling the family cannot revive retired opt-in")
                        XCTAssertTrue(reenabledNames.contains(MCPWindowToolName.becomeOverseer))
                    }
                }
                XCTAssertEqual(session.runID, runID)
                XCTAssertTrue(session.codexController === controller, "Discovery cannot replace a held provider")
                XCTAssertNil(session.oversight.pendingAutoWake, "Opt-in and retirement never manufacture a turn")
                return
            }
            if surfaceTransition == .delegation {
                // An eligible session lists session_admin to request a scope; listing grants nothing.
                XCTAssertTrue(names.contains(MCPWindowToolName.sessionAdmin))
                // Inbound oversight alone is not a scope request/administration grant.
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: [endpoint], outbound: [])
                let inboundNames = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(inboundNames.contains(MCPWindowToolName.agentSessionLink))
                XCTAssertTrue(inboundNames.contains(MCPWindowToolName.sessionAdmin))
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: [endpoint], outbound: [endpoint])
                let outboundNames = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(outboundNames.contains(MCPWindowToolName.sessionAdmin))
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: [], outbound: [])
                let noLinkNames = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(noLinkNames.contains(MCPWindowToolName.sessionAdmin))

                let scopes = AgentSessionLinkRuntimeBridge.shared.delegationScopes
                let request = try scopes.requestScope(
                    requesterSessionID: sessionID, requesterTabID: tabID,
                    kind: .tree(rootSessionID: sessionID), capabilities: [.observe],
                    guardrails: .init(), reason: nil, idempotencyKey: nil
                ).get()
                let scope = try scopes.approve(
                    requestID: request.id, presentedWindowID: window.windowID,
                    presentedTabID: tabID, presentedSessionID: sessionID
                ).get()
                addTeardownBlock { @MainActor in scopes.revoke(scopeID: scope.id) }
                let notificationsBeforeGrant = await testConnection.notificationCount()
                await manager.notifyToolListChangedForAgentSession(sessionID, forceRelist: true)
                let notificationsAfterGrant = await testConnection.notificationCount()
                XCTAssertGreaterThan(notificationsAfterGrant, notificationsBeforeGrant, "A scope-only grant must relist even when every link fact is unchanged")
                let scopedNames = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(scopedNames.contains(MCPWindowToolName.sessionAdmin))
                XCTAssertFalse(scopedNames.contains(MCPWindowToolName.agentSessionLink), "A scope does not fabricate pair or activated-overseer authority")
                scopes.revoke(scopeID: scope.id)
                await manager.notifyToolListChangedForAgentSession(sessionID, forceRelist: true)
                let revokedNames = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(revokedNames.contains(MCPWindowToolName.sessionAdmin))
                XCTAssertFalse(scopes.hasLiveScope(grantedTo: sessionID), "Listing survives revocation; authority does not")
                XCTAssertEqual(session.runID, runID, "Scope discovery never retargets the run")
                XCTAssertNotNil(session.codexController, "Scope changes do not recycle a running provider")
                return
            }
            let sourceGeneration = session.codexControllerGeneration
            if isScopeRepair {
                XCTAssertEqual(names.contains(MCPWindowToolName.sessionAdmin), surfaceTransition == .delegationRevocation)
                if let scopeToRevoke {
                    scopes.revoke(scopeID: scopeToRevoke)
                } else {
                    _ = try grantScope()
                }
            } else if surfaceTransition == .activation {
                let state = try XCTUnwrap(window.agentModeViewModel.agentSessionLinkBootstrapState(for: endpoint))
                XCTAssertTrue(window.agentModeViewModel.agentSessionLinkActivateOverseer(for: endpoint, expected: state))
            } else {
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: [endpoint], outbound: outbound ? [endpoint] : [])
            }
            // This connection records notifications but intentionally does not relist: exercise
            // the stale client catalog rather than healing it in the test before reconciliation.
            await manager.notifyToolListChangedForAgentSession(sessionID, forceRelist: isScopeRepair)

            let stuckProjection = await manager.debugRunCatalogProjection(for: runID)
            let stuck = try XCTUnwrap(stuckProjection)
            XCTAssertEqual(stuck.hasAgentSessionLink, surfaceTransition == .upgrade)
            if surfaceTransition != nil {
                XCTAssertNotEqual(stuck.expectedSurface, stuck.returnedSurface)
                XCTAssertEqual(stuck.returnedSurface, unlinked.returnedSurface)
                XCTAssertNotNil(session.codexController, "Busy provider is not replaced")
                XCTAssertEqual(session.runID, runID)
                XCTAssertEqual(session.codexSessionLinkCatalogRepairCycle?.observedControllerGeneration, sourceGeneration)
                if isScopeRepair {
                    XCTAssertFalse(stuck.hasAnyActiveLink == true)
                    XCTAssertTrue(AgentSessionLinkCatalogSurface.differs(
                        toolName: MCPWindowToolName.sessionAdmin,
                        expected: stuck.expectedSurface, returned: stuck.returnedSurface
                    ))
                }
                session.runState = .completed
                window.agentModeViewModel.test_codexCoordinator.codexRepairSessionLinkCatalogIfQuiescent(for: session)
            }
            XCTAssertEqual(stuck.hasActiveOutboundLink, outbound)
            XCTAssertEqual(stuck.routeToken?.observerEndpoint, endpoint)
            XCTAssertEqual(stuck.isReady, surfaceTransition == .upgrade, "Schema freshness is not outbound prompt authority")
            XCTAssertNil(session.runID, "the stale process run is retired so cold bootstrap applies")
            XCTAssertNil(session.codexController, "exactly one controller replacement")
            XCTAssertEqual(session.codexConversationID, conversationID)
            XCTAssertEqual(session.codexRolloutPath, rolloutPath)
            XCTAssertEqual(session.codexSessionLinkCatalogRepairCycle?.observedControllerGeneration, sourceGeneration)
            XCTAssertNotEqual(sourceGeneration, session.codexControllerGeneration)
            if surfaceTransition != nil {
                XCTAssertNil(session.oversight.pendingAutoWake, "An empty passive queue never manufactures a continuation")
                XCTAssertEqual(session.oversight.overseerActivation != nil, surfaceTransition == .activation)
                let spentGeneration = session.codexControllerGeneration
                window.agentModeViewModel.test_codexCoordinator.codexRepairSessionLinkCatalogIfQuiescent(for: session)
                XCTAssertEqual(session.codexControllerGeneration, spentGeneration)
                // Production retirement clears the old run's provider PID when its transport
                // terminates (CodexAppServerClient.finishTransportTermination). This no-op controller
                // has no process, and both runs share the XCTest PID, so mirror that clear; otherwise
                // the retired run still looks like a live ancestor and the next bootstrap is
                // correctly refused as ambiguous_run_policy.
                await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
                // The next ordinary installed run re-lists the full surface; no synthetic turn.
                let nextRunID = UUID()
                let nextConnectionID = UUID()
                session.installRunID(nextRunID)
                session.codexController = LifecycleNoopCodexController(recorder: LifecycleRecorder())
                await installAuthoritativePolicy(manager: manager, runID: nextRunID, tabID: tabID, windowID: window.windowID)
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: nextRunID)
                await manager.debugInstallDirectAdmissionConnectionForTesting(connectionID: nextConnectionID, connection: CatalogRepairPolicyAuthorityTestConnection(), pendingClientID: clientName)
                let nextApplied = await manager.debugApplyPendingPolicy(clientName: clientName, connectionID: nextConnectionID, clientPid: Int(getpid()), bootstrapClientName: "repoprompt_ce_cli_debug", sessionKey: "next-\(nextRunID)", pidGateTimeout: 0.25, requireRunRouting: true)
                XCTAssertEqual(nextApplied.outcome, "applied")
                let nextNames = try await manager.debugListToolNames(for: nextConnectionID)
                XCTAssertEqual(nextNames.contains(MCPWindowToolName.agentSessionLink), !isScopeRepair)
                XCTAssertEqual(nextNames.contains(MCPWindowToolName.becomeOverseer), oversightEnabled, "Eligible roles retain targeted bootstrap; disabled oversight still removes it")
                if isScopeRepair {
                    XCTAssertEqual(nextNames.contains(MCPWindowToolName.sessionAdmin), surfaceTransition == .delegationGrant)
                } else if surfaceTransition == .activation {
                    XCTAssertTrue(nextNames.contains(MCPWindowToolName.sessionAdmin), "A still-activated zero-link overseer can request a scope on the next ordinary run")
                }
                let healed = await manager.debugRunCatalogProjection(for: nextRunID)
                XCTAssertEqual(healed?.expectedSurface, healed?.returnedSurface)
                XCTAssertEqual(healed?.returnedSurface, stuck.expectedSurface)
                XCTAssertNil(session.codexSessionLinkCatalogRepairCycle)
                XCTAssertEqual(session.codexConversationID, conversationID)
                XCTAssertEqual(session.codexRolloutPath, rolloutPath)
                await cleanup(manager: manager, runID: nextRunID, connectionID: nextConnectionID, windowID: window.windowID)
            }
        #else
            throw XCTSkip("Run catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    #if DEBUG
        private func installRoutingSnapshot(for tabID: UUID, in window: WindowState) async throws {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Run catalog observation \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                ephemeral: true
            )
            let switchResult = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "runCatalogObservationInitial"
            )
            XCTAssertEqual(switchResult, .switched)
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                ComposeTabState(id: tabID, name: "Run catalog observation")
            ]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabID
            let reloadResult = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
                window.workspaceManager.workspaces[workspaceIndex],
                reason: "runCatalogObservationTab"
            )
            XCTAssertEqual(reloadResult, .switched)
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        }

        private func makeWindow() -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            return window
        }

        private func installAuthoritativePolicy(
            manager: ServerNetworkManager,
            runID: UUID,
            tabID: UUID,
            windowID: Int,
            allowsAgentExternalControlTools: Bool = false
        ) async {
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "Restored oversight catalog repair integration test",
                ttl: 10,
                tabID: tabID,
                runID: runID,
                additionalTools: nil,
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                requiresExpectedAgentPID: true
            )
        }

        private func cleanup(
            manager: ServerNetworkManager,
            runID: UUID,
            connectionID: UUID,
            windowID: Int
        ) async {
            await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
            await manager.removeConnection(connectionID)
            await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
        }

    #endif
}

#if DEBUG
    private actor CatalogRepairPolicyAuthorityTestConnection: MCPServerConnection {
        private var toolListChangedCount = 0

        func notificationCount() -> Int {
            toolListChangedCount
        }

        nonisolated var isFilesystemBacked: Bool {
            false
        }

        nonisolated var connectionFolderURL: URL? {
            nil
        }

        nonisolated var capabilityToken: String? {
            nil
        }

        func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {}
        func stop() async {}
        func abortForExecutionWatchdog(context _: MCPExecutionWatchdogTerminalContext) async {}
        func notifyToolListChanged() async {
            toolListChangedCount += 1
        }

        func connectionState() -> ConnectionStateSnapshot {
            .ready
        }

        func isViableForRetention() -> Bool {
            true
        }

        func secondsSinceLastActivity() async -> TimeInterval {
            0
        }

        func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
            nil
        }

        func responseDeliverySnapshot() async -> MCPResponseDeliverySnapshot? {
            nil
        }

        func terminate(reason _: TerminationReason, message _: String?) async {}
        func sendProgress(
            tool _: String,
            kind _: RepoPromptProgressKind,
            stage _: String,
            message _: String
        ) async {}
    }
#endif

#if DEBUG
    /// Pins RP's live absent-to-present discovery, not any vendor's model-side tool cache.
    @MainActor
    final class AgentSessionLinkLiveDiscoveryTests: XCTestCase {
        func testUserOverseeGrantRefreshesExactAgentRouteDuringHeldProviderTurn() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery()
            }
        }

        func testBecomeOverseerRefreshesExactAgentRouteWithoutGrantDuringHeldTurn() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(activate: true)
            }
        }

        func testFamilyDisableAndReenableBeforeProofSubscriptionRejectsOriginalInvocation() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(activate: true, originalQualificationFamilyABA: true)
            }
        }

        func testUnrelatedConnectionAndRunPolicyChurnPreservesPendingBootstrap() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(activate: true, proofMutation: .unrelatedRoute)
            }
        }

        func testExactConnectionPolicyABADuringQualificationRejectsPendingBootstrap() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(activate: true, proofMutation: .exactConnectionPolicyABA)
            }
        }

        func testW0fClaudeReturnedCatalogConvergesAfterLateGrant() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode)
            }
        }

        func testW0fCodexReturnedCatalogNeverRepairsQuietOnlyChanges() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .codexExec)
            }
        }

        func testW3RegisteredRingClaudeFirstDoesNotEchoQuietClosures() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w3Ring: true)
            }
        }

        func testW3RegisteredRingCodexFirstDoesNotEchoQuietClosures() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .codexExec, w3Ring: true)
            }
        }

        func testW3ProvenRepromptCauseClaudeFirst() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w3Ring: true, w3Reprompt: true)
            }
        }

        func testW3ProvenRepromptCauseCodexFirst() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .codexExec, w3Ring: true, w3Reprompt: true)
            }
        }

        func testW3LateW1MarkerDuringW2KeepsItsOwnCertificate() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .lateMarker)
            }
        }

        func testW3InactiveDispatchRequiresCurrentOrdinaryBaseline() async throws {
            for stale in [false, true] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .inactiveBaseline(stale: stale))
                }
            }
        }

        func testW3RepromptRequiresAcceptedDeclarationBeforeFrameAndNoLaterTool() async throws {
            for phase in ["before", "afterOtherTool"] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .reprompt(phase: phase))
                }
            }
        }

        func testW3TerminalCertificateRejectsChangedMemberRowAtomically() async throws {
            for kind in [AgentProviderKind.claudeCode, .codexExec] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: kind, w2Probe: .terminal(delayed: false, nativeResult: true, corrupt: true))
                }
            }
        }

        func testW4ProvisionalDeclarationNeverAppearsInAnyPublishedSnapshot() async throws {
            for delayed in [false, true] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .terminal(delayed: delayed, nativeResult: true, closing: true), w4Display: true)
                }
            }
        }

        func testW4RepeatWakePreservesEveryPublishedBlockAndSummary() async throws {
            for tools in [0, 8, 9] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .repeatDisplay(tools: tools))
                }
            }
        }

        func testW4OrdinaryPromotionReleasesStagedRowsWithoutHidingSiblings() async throws {
            let probes: [W2Probe] = [.terminal(delayed: true, nativeResult: false, closing: true), .terminal(delayed: true, nativeResult: true, leading: true), .terminal(delayed: true, nativeResult: true, closing: true, cancel: true)]
            for probe in probes {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: probe, w4Display: true)
                }
            }
        }

        func testW3SilentUndeclaredCloseRemainsOrdinary() async throws {
            for kind in [AgentProviderKind.claudeCode, .codexExec] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: kind, w2Probe: .undeclared)
                }
            }
        }

        func testW2RegisteredNoopKeepsFinalQuietFactsWhenHostCallbacksAreQueued() async throws {
            for kind in [AgentProviderKind.claudeCode, .codexExec] {
                for delayed in [false, true] {
                    try await MCPSharedServerTestLease.shared.withLease { _ in
                        try await self.exerciseLiveDiscovery(w0fProvider: kind, w2Probe: .terminal(delayed: delayed, nativeResult: true))
                    }
                }
            }
        }

        func testW2ClosingTextAfterAcceptedBodySurvivesQueuedCanonicalRows() async throws {
            for kind in [AgentProviderKind.claudeCode, .codexExec] {
                for delayed in [false, true] {
                    try await MCPSharedServerTestLease.shared.withLease { _ in
                        try await self.exerciseLiveDiscovery(w0fProvider: kind, w2Probe: .terminal(delayed: delayed, nativeResult: true, closing: true))
                    }
                }
            }
        }

        func testW2LeadingTextRemainsOrdinaryWithQueuedDeclaration() async throws {
            for kind in [AgentProviderKind.claudeCode, .codexExec] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: kind, w2Probe: .terminal(delayed: true, nativeResult: true, leading: true))
                }
            }
        }

        func testW2RunServiceStopDuringQueuedObservationCutSettlesExactlyOnce() async throws {
            for kind in [AgentProviderKind.claudeCode, .codexExec] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: kind, w2Probe: .terminal(delayed: true, nativeResult: true, closing: true, cancel: true))
                }
            }
        }

        func testW2RegisteredNoopWithoutNativeResultRemainsOrdinaryAfterQueuedHostDrain() async throws {
            for kind in [AgentProviderKind.claudeCode, .codexExec] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: kind, w2Probe: .terminal(delayed: true, nativeResult: false))
                }
            }
        }

        func testW2FailedAuthoritativeProofVetoesAReplacedRoutineClaim() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .hint(withdraw: true, replaced: true))
            }
        }

        func testW2FailedProofVetoesAReplacedOrdinaryCandidate() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .hint(withdraw: true, replaced: true, ordinaryCandidate: true))
            }
        }

        func testW2SameRouteCatalogWithdrawalDuringLocalProofRemovesActualSentHint() async throws {
            for withdraw in [false, true] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .hint(withdraw: withdraw))
                }
            }
        }

        func testW2AttentionArrivingAfterRoutineMarkDemotesTheReleasedAttempt() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .codexExec, w2Probe: .lateAttention)
            }
        }

        func testW2ProductionCatalogProofHandoffCostWithActualAndTenfoldCatalog() async throws {
            try XCTSkipUnless(ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "quiet-w2-catalog", "Opt-in catalog proof/handoff cost gate")
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .catalogCost)
            }
        }

        func testCatalogPublicationOverlapKeepsActualWakeOrdinary() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .coldCatalogOverlap)
            }
        }

        func testQuietFullOwnerScaleDiagnostic() async throws {
            try XCTSkipUnless(ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "quiet-w3-diagnostic", "Opt-in bounded quiet scale diagnostic")
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .scale(stamps: true, diagnostic: true))
            }
        }

        func testQuietFullOwnerScaleGate() async throws {
            try XCTSkipUnless(ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "quiet-w3", "Opt-in binding quiet scale gate")
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .scale(stamps: true, diagnostic: false))
            }
        }

        func testQuietAcceptedW2FullOwnerScaleControl() async throws {
            try XCTSkipUnless(ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "quiet-w2-control", "Opt-in accepted W2 scale control")
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .scale(stamps: false, diagnostic: false))
            }
        }

        private enum W2Probe {
            case coldCatalogOverlap
            case repeatDisplay(tools: Int)
            case scale(stamps: Bool, diagnostic: Bool)
            case lateMarker
            case inactiveBaseline(stale: Bool)
            case reprompt(phase: String)
            case undeclared
            case terminal(delayed: Bool, nativeResult: Bool, closing: Bool = false, leading: Bool = false, cancel: Bool = false, corrupt: Bool = false)
            case hint(withdraw: Bool, replaced: Bool = false, ordinaryCandidate: Bool = false)
            case lateAttention
            case catalogCost
        }

        private enum ProofMutation {
            case unrelatedRoute
            case exactConnectionPolicyABA
        }

        func testInboundCreationPromotesReducedCatalogToFullDuringHeldTurn() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(inbound: true)
            }
        }

        private func exerciseLiveDiscovery(
            activate: Bool = false, inbound: Bool = false, originalQualificationFamilyABA: Bool = false,
            proofMutation: ProofMutation? = nil, w0fProvider: AgentProviderKind? = nil,
            w2Probe: W2Probe? = nil, w3Ring: Bool = false, w3Reprompt: Bool = false, w4Display: Bool = false
        ) async throws {
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let manager = ServerNetworkManager.shared
            let provider = HeldDiscoveryProvider()
            let window = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
            WindowStatesManager.shared.registerWindowState(window)
            WindowStatesManager.shared.attachAgentSessionLinkBridge()
            let bridge = AgentSessionLinkRuntimeBridge.shared
            let authority = AppDomainRuntimeComposition.shared.runtime.agentSessionLinkAuthority
            let codexRecorder = LifecycleRecorder()
            let codex = LifecycleNoopCodexController(recorder: codexRecorder)
            let clientName = w0fProvider == .codexExec ? AgentProviderKind.codexMCPClientID : AgentProviderKind.claudeMCPClientID
            let w0fKind = w0fProvider ?? .claudeCode
            let runID = UUID()
            var transport: PersistentMCPTestEndpoint?
            var grant: DomainAgentSessionLinkReference?
            let catalogGate = DiscoveryCatalogGate()
            let disabledCatalogGate = DiscoveryCatalogGate()
            let qualificationGate = DiscoveryCatalogGate()
            var pendingBootstrap: Task<PersistentMCPTestRPCResponse, Error>?
            let unrelatedRunID = UUID()
            let unrelatedClientName = "proof-unrelated-\(UUID())"
            var unrelatedTransport: PersistentMCPTestEndpoint?
            var catalogDisabledForTesting = false
            var delayedCatalog: Task<Set<String>, Error>?
            let registration = try await AppDomainRuntimeComposition.shared.register(window.mcpServer.windowMCPToolCatalogService)
            let cleanup: @MainActor () async -> Void = {
                await manager.debugSetReturnedCatalogToolsForTesting(nil)
                await manager.debugSetAfterExpectedCatalogSurfaceForTesting(nil)
                await manager.debugSetAfterBecomeOverseerProofRegistrationForTesting(nil)
                await qualificationGate.release()
                _ = await pendingBootstrap?.result
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.becomeOverseer, operation: nil)
                await catalogGate.release()
                await disabledCatalogGate.release()
                _ = await delayedCatalog?.result
                if catalogDisabledForTesting { await manager.setEnabled(true) }
                if let grant { await bridge.revokeLink(linkID: grant.linkID, generation: grant.generation) }
                await provider.shutdown()
                if let unrelatedTransport {
                    unrelatedTransport.client.close()
                    await unrelatedTransport.connectionManager.stop()
                    await manager.debugRemoveConnection(unrelatedTransport.connectionID)
                }
                if case .unrelatedRoute? = proofMutation {
                    await manager.clearClientConnectionPolicy(for: unrelatedClientName, windowID: window.windowID, runID: unrelatedRunID)
                    await manager.cleanupRunRoutingState(for: unrelatedRunID, windowID: window.windowID)
                }
                if let transport {
                    transport.client.close()
                    await transport.connectionManager.stop()
                    await manager.debugRemoveConnection(transport.connectionID)
                }
                await manager.clearClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)
                await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                await window.tearDown()
                await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            do {
                await window.workspaceManager.awaitInitialized()
                let observerTab = UUID()
                let targetTab = UUID()
                let observerID = UUID()
                let targetID = UUID()
                var workspace = WorkspaceModel(name: "Live discovery", repoPaths: [])
                workspace.isEphemeral = true
                workspace.composeTabs = [
                    ComposeTabState(id: observerTab, name: "User-created planning chat", activeAgentSessionID: observerID),
                    ComposeTabState(id: targetTab, name: "Harmless idle target", activeAgentSessionID: targetID)
                ]
                workspace.activeComposeTabID = observerTab
                // Restoration must earn both runtime readiness and owner-valid placement metadata.
                // A fabricated loaded latch has no index row until an unrelated debounced save wins.
                for tab in workspace.composeTabs {
                    let payload = try AgentSession(
                        id: XCTUnwrap(tab.activeAgentSessionID), workspaceID: workspace.id,
                        composeTabID: tab.id, name: tab.name, agentKind: w0fKind.rawValue,
                        autoWakeOnOversightUpdates: false
                    )
                    _ = try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace)
                }
                window.workspaceManager.workspaces.append(workspace)
                let switched = await window.workspaceManager.switchWorkspace(to: workspace, saveState: false)
                XCTAssertTrue(switched.didSwitch)
                window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
                let vm = window.agentModeViewModel
                let observer = await vm.ensureSessionReady(tabID: observerTab, reconnectActiveProviders: false)
                let target = await vm.ensureSessionReady(tabID: targetTab, reconnectActiveProviders: false)
                for (session, expectedID) in [(observer, observerID), (target, targetID)] {
                    XCTAssertEqual(session.activeAgentSessionID, expectedID)
                    XCTAssertEqual(session.selectedAgent, w0fKind)
                    XCTAssertTrue(session.qualifiedRestorationReadiness.isAuthoritative)
                    XCTAssertEqual(vm.ownerValidatedSessionIndex[expectedID]?.tabID, session.tabID)
                    let projector = SpawnProvenanceDelegationMembershipProjector.production(worktreeOwnership: bridge.worktreeOwnership)
                    XCTAssertEqual(projector.pointResolutionState(for: expectedID), .unique)
                    XCTAssertFalse(projector.authorityConflictInAncestry(of: expectedID))
                }
                let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(vm, tabID: observerTab)
                XCTAssertNil(observer.parentSessionID)
                XCTAssertFalse(observer.isMCPOriginated)
                XCTAssertNil(observer.mcpControlContext)
                XCTAssertFalse(vm.isMCPControlled(tabID: observerTab))
                let initialLinks = await authority.links(forObserver: observerID)
                XCTAssertTrue(initialLinks.items.isEmpty)
                if inbound {
                    guard case .added = await bridge.addMonitorLink(observerSessionID: targetID, rawTargetSessionID: observerID.uuidString) else {
                        throw DiscoveryFailure.overseeRefused
                    }
                    let links = await authority.links(forObserver: targetID)
                    let link = try XCTUnwrap(links.items.first)
                    grant = .init(linkID: link.linkID, generation: link.generation)
                }

                observer.installRunID(runID)
                if w0fProvider == .codexExec {
                    observer.codexController = codex
                    _ = try await codex.startOrResume(existing: nil, baseInstructions: "")
                    _ = try await codex.startUserTurn(text: "", attachments: [], model: nil, reasoningEffort: nil, serviceTier: nil)
                } else {
                    observer.claudeController = provider
                }
                if w0fProvider != nil {
                    await manager.debugSetReturnedCatalogToolsForTesting(Self.w0fReturnedShape())
                }
                observer.runState = .running
                // Install the ordinary restricted Agent policy BEFORE initialize/tools/list. This
                // transport is never an external unrestricted caller that is converted after the fact.
                await manager.installClientConnectionPolicy(
                    for: clientName, windowID: window.windowID,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools, oneShot: true,
                    reason: "Live Oversee discovery regression", ttl: 60, tabID: observerTab,
                    runID: runID, additionalTools: nil, purpose: .agentModeRun,
                    taskLabelKind: nil, allowsAgentExternalControlTools: false
                )
                await manager.setEnabled(true)
                let connection = try await PersistentMCPTestEndpoint.make(
                    label: "held-provider", networkManager: manager,
                    clientName: clientName, requiredToolNames: [MCPWindowToolName.readFile]
                )
                transport = connection
                await provider.attach(connection)
                let turnID = try await provider.sendUserMessage("Hold this synthetic turn until the test releases it.")
                let heldTurn = await provider.heldTurnSnapshot
                XCTAssertEqual(heldTurn.activeTurnID, turnID)
                let before = try await provider.listTools()
                XCTAssertEqual(before.contains(MCPWindowToolName.agentSessionLink), inbound)
                XCTAssertTrue(before.contains(MCPWindowToolName.becomeOverseer), "Inbound discovery requests no additional authority")
                let beforeDefinitions = try await provider.definitions(wireCaptureName: inbound ? "inbound-before" : (activate ? "activation-before" : "grant-before"))
                try DiscoveryArtifactCapture.write(beforeDefinitions, name: inbound ? "inbound-before" : (activate ? "activation-before" : "grant-before"))
                if inbound {
                    let reduced = try XCTUnwrap(beforeDefinitions.first { $0["name"] as? String == MCPWindowToolName.agentSessionLink })
                    XCTAssertEqual(DiscoveryArtifactCapture.operations(reduced), ["set_waiting_on", "request_attention", "create_lane"])
                }
                let policy = await manager.debugConnectionPolicyState(for: connection.connectionID)
                XCTAssertEqual(policy.purpose, .agentModeRun)
                XCTAssertEqual(policy.windowID, window.windowID)
                XCTAssertEqual(policy.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
                let routeBefore = await manager.authoritativeRunCatalogRouteToken(runID: runID, windowID: window.windowID, tabID: observerTab)
                let route = try XCTUnwrap(routeBefore)
                XCTAssertEqual(route.connectionID, connection.connectionID)
                XCTAssertEqual(route.observerEndpoint, endpoint)
                XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], connection.connectionID)

                if w0fProvider != nil {
                    let initial = try await w0fProjection(manager, runID)
                    let supported = await manager.hasCurrentReturnedTool(Self.w0fTool(), routeToken: route, projectionRevision: initial.projectionRevision)
                    XCTAssertFalse(supported, "A started provider without the returned definition has no positive support")
                }

                if originalQualificationFamilyABA || proofMutation != nil {
                    let registered = expectation(description: "Exact observed proof registered before async qualification")
                    await manager.debugSetAfterBecomeOverseerProofRegistrationForTesting { _, sampledEndpoint in
                        guard sampledEndpoint == endpoint else { return }
                        registered.fulfill()
                        await qualificationGate.hold()
                    }
                    pendingBootstrap = Task {
                        try await connection.callTool(name: MCPWindowToolName.becomeOverseer, arguments: [:], timeoutSeconds: 5)
                    }
                    await fulfillment(of: [registered], timeout: 2)
                    if let proofMutation {
                        switch proofMutation {
                        case .unrelatedRoute:
                            target.installRunID(unrelatedRunID)
                            await manager.installClientConnectionPolicy(
                                for: unrelatedClientName, windowID: window.windowID,
                                restrictedTools: AgentModeMCPToolPolicy.restrictedTools, oneShot: true,
                                reason: "Unrelated route churn while bootstrap is parked", ttl: 60, tabID: targetTab,
                                runID: unrelatedRunID, additionalTools: nil, purpose: .agentModeRun,
                                taskLabelKind: nil, allowsAgentExternalControlTools: false
                            )
                            let unrelated = try await PersistentMCPTestEndpoint.make(
                                label: "unrelated-proof-route", networkManager: manager,
                                clientName: unrelatedClientName, requiredToolNames: [MCPWindowToolName.readFile]
                            )
                            unrelatedTransport = unrelated
                            let unrelatedPolicy = await manager.debugConnectionPolicyState(for: unrelated.connectionID)
                            XCTAssertEqual(unrelatedPolicy.purpose, .agentModeRun)
                            XCTAssertEqual(unrelatedPolicy.windowID, window.windowID)
                            unrelated.client.close()
                            await unrelated.connectionManager.stop()
                            await manager.debugRemoveConnection(unrelated.connectionID)
                            unrelatedTransport = nil
                            await manager.clearClientConnectionPolicy(for: unrelatedClientName, windowID: window.windowID, runID: unrelatedRunID)
                            await manager.cleanupRunRoutingState(for: unrelatedRunID, windowID: window.windowID)
                        case .exactConnectionPolicyABA:
                            await manager.debugSetAdditionalTools(
                                for: connection.connectionID, additionalTools: policy.additionalTools.union([MCPWindowToolName.getFileTree])
                            )
                            await manager.debugSetAdditionalTools(for: connection.connectionID, additionalTools: policy.additionalTools)
                            let restored = await manager.debugConnectionPolicyState(for: connection.connectionID)
                            XCTAssertEqual(restored.additionalTools, policy.additionalTools)
                        }
                        let routeAfter = await manager.authoritativeRunCatalogRouteToken(runID: runID, windowID: window.windowID, tabID: observerTab)
                        XCTAssertEqual(routeAfter, route, "The original exact route remains current; policy ABA must still revoke its old proof")
                        let policyAfter = await manager.debugConnectionPolicyState(for: connection.connectionID)
                        XCTAssertEqual(policyAfter.restrictedTools, policy.restrictedTools)
                        XCTAssertEqual(policyAfter.additionalTools, policy.additionalTools)
                        XCTAssertEqual(policyAfter.purpose, policy.purpose)
                        XCTAssertEqual(policyAfter.windowID, policy.windowID)
                        await manager.debugSetAfterBecomeOverseerProofRegistrationForTesting(nil)
                        await qualificationGate.release()
                        let response = try await XCTUnwrap(pendingBootstrap).value
                        let result = try XCTUnwrap(try MCPExportWatchdogIntegrationTests.responseObject(from: response)["result"] as? [String: Any])
                        let links = await authority.links(forObserver: observerID)
                        XCTAssertTrue(links.items.isEmpty, "Bootstrap never manufactures a link")
                        switch proofMutation {
                        case .unrelatedRoute:
                            XCTAssertNotEqual(result["isError"] as? Bool, true, "Unrelated connection/run churn must not revoke this invocation: \(response.rawJSON)")
                            XCTAssertNotNil(observer.oversight.overseerActivation)
                            let tools = try await provider.listTools()
                            XCTAssertTrue(tools.contains(MCPWindowToolName.agentSessionLink))
                            XCTAssertTrue(tools.contains(MCPWindowToolName.becomeOverseer), "Targeted bootstrap remains available after activation")
                        case .exactConnectionPolicyABA:
                            XCTAssertEqual(result["isError"] as? Bool, true, "Exact-connection policy ABA must latch revocation: \(response.rawJSON)")
                            XCTAssertNil(observer.oversight.overseerActivation)
                        }
                        await cleanup()
                        return
                    }
                    let store = ToolAvailabilityStore.shared
                    let beforeDisabled = store.disabledTools
                    let beforePersisted = UserDefaults.standard.object(forKey: "mcp.disabledTools") as? [String]
                    XCTAssertTrue(store.isEnabled(MCPWindowToolName.agentSessionLink))
                    var disabledProposals: [Bool] = []
                    let availabilityProbe = store.$disabledTools.sink { names in
                        disabledProposals.append(names.contains(MCPWindowToolName.agentSessionLink))
                    }
                    defer { availabilityProbe.cancel() }
                    // Keep the original RED schedule's gate after registry insertion. Observation
                    // now precedes the first network check, so this withdrawal must already be latched.
                    // Use real @Published mutations without defaults or delayed broadcast work.
                    store.debugDisableAndReenableWithoutPersistenceForTesting(MCPWindowToolName.agentSessionLink)
                    XCTAssertEqual(disabledProposals, [false, true, false], "Withdrawal and restoration both completed during registered proof qualification")
                    XCTAssertEqual(store.disabledTools, beforeDisabled)
                    XCTAssertEqual(UserDefaults.standard.object(forKey: "mcp.disabledTools") as? [String], beforePersisted)
                    await manager.debugSetAfterBecomeOverseerProofRegistrationForTesting(nil)
                    await qualificationGate.release()
                    let response = try await XCTUnwrap(pendingBootstrap).value
                    let result = try XCTUnwrap(try MCPExportWatchdogIntegrationTests.responseObject(from: response)["result"] as? [String: Any])
                    let links = await authority.links(forObserver: observerID)
                    XCTAssertTrue(links.items.isEmpty, "Bootstrap must never manufacture a link")
                    XCTAssertEqual(result["isError"] as? Bool, true, "Original invocation crossed a family withdrawal during qualification: \(response.rawJSON)")
                    XCTAssertNil(observer.oversight.overseerActivation, "Disable/re-enable at the original qualification gate must invalidate the invocation")
                    await cleanup()
                    return
                }

                if activate {
                    // Network-owner proof test through a real admitted invocation, before opt-in.
                    // The override only tests the commit fence; it never activates or invents grants.
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.becomeOverseer) {
                        let invocation = try MCPInvocationContextBridge.require(
                            toolName: MCPWindowToolName.becomeOverseer, expectedWindowID: endpoint.windowID
                        )
                        let observed = await MCPBecomeOverseerActivationProof.prepareObservingFamily(
                            invocation: invocation, endpoint: endpoint
                        )
                        let observedProof = try XCTUnwrap(observed)
                        let issued = await manager.issueBecomeOverseerActivationProof(
                            invocation: invocation, endpoint: endpoint, observedProof: observedProof
                        )
                        let proof = try XCTUnwrap(issued)
                        await manager.setEnabled(false)
                        await manager.setEnabled(true)
                        let committed = await proof.commitIfCurrent(invocation: invocation, endpoint: endpoint) { true }
                        proof.invalidate()
                        return .object(["committed": .bool(committed)])
                    }
                    let deniedCommit = try await connection.callTool(name: MCPWindowToolName.becomeOverseer, arguments: ["_rawJSON": true], timeoutSeconds: 2)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.becomeOverseer, operation: nil)
                    let object = try MCPExportWatchdogIntegrationTests.responseObject(from: deniedCommit)
                    let result = try XCTUnwrap(object["result"] as? [String: Any])
                    XCTAssertNotEqual(result["isError"] as? Bool, true, deniedCommit.rawJSON)
                    let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                    let text = content.compactMap { $0["text"] as? String }.joined()
                    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    XCTAssertEqual(payload["committed"] as? Bool, false, "Global disable/re-enable must not resurrect the synchronous commit fence")
                    XCTAssertNil(observer.oversight.overseerActivation)
                    let noLinks = await authority.links(forObserver: observerID)
                    XCTAssertTrue(noLinks.items.isEmpty)
                }

                let received = expectation(description: "Actual tools/list_changed frame on the provider's socket")
                received.assertForOverFulfill = false
                let frames = DiscoveryNotificationFrames()
                connection.client.observeNotifications { data in
                    if frames.captureListChanged(data) { received.fulfill() }
                }
                if activate {
                    let paused = expectation(description: "tools/list sampled bootstrap before activation")
                    await manager.debugSetAfterExpectedCatalogSurfaceForTesting {
                        await catalogGate.hold { paused.fulfill() }
                    }
                    delayedCatalog = Task { try await provider.listTools() }
                    await fulfillment(of: [paused], timeout: 2)
                    await manager.debugSetAfterExpectedCatalogSurfaceForTesting(nil)
                }
                // Catalog/activation requests and notification waits retain their two-second watchdogs.
                // Prove refresh is independent of turn completion and the deliberately held catalog
                // response; aggregate elapsed time also includes their serial setup and actor hops.
                let clock = ContinuousClock()
                let start = clock.now
                var expectedTargetID = targetID
                if activate {
                    let response = try await connection.callTool(name: MCPWindowToolName.becomeOverseer, arguments: [:], timeoutSeconds: 2)
                    XCTAssertNotNil(try MCPExportWatchdogIntegrationTests.responseObject(from: response)["result"] as? [String: Any])
                    let noLinks = await authority.links(forObserver: observerID)
                    XCTAssertTrue(noLinks.items.isEmpty, "Activation manufactures no grants")
                    XCTAssertNotNil(observer.oversight.overseerActivation)
                } else if !inbound {
                    let added = await bridge.addMonitorLink(observerSessionID: observerID, rawTargetSessionID: targetID.uuidString)
                    guard case .added = added else {
                        XCTFail("Real user Oversee Add failed: \(added)")
                        throw DiscoveryFailure.overseeRefused
                    }
                }
                if inbound {
                    window.apiSettingsViewModel.isClaudeCodeConnected = true
                    try await AsyncTestWait.waitUntil("fixture destination availability") { window.apiSettingsViewModel.agentAvailability.claudeCodeAvailable }
                    AgentAdvertisedModelCatalog.shared.record([AgentModelOption(rawValue: "sonnet:high", displayName: "Fixture model", description: nil, isPlaceholderDefault: false, isProviderDefault: false)], for: .claudeCode, generation: AgentAdvertisedModelCatalog.shared.productionGeneration(for: .claudeCode))
                    defer { AgentAdvertisedModelCatalog.shared.invalidate(.claudeCode) }
                    let created = try await connection.callTool(name: MCPWindowToolName.agentSessionLink, arguments: ["op": "create_lane", "model_id": "claudeCode:sonnet:high", "idempotency_key": "discovery-first-lane", "session_name": "Harmless created lane", "_rawJSON": true], timeoutSeconds: 10)
                    let object = try MCPExportWatchdogIntegrationTests.responseObject(from: created)
                    let result = try XCTUnwrap(object["result"] as? [String: Any])
                    XCTAssertNotEqual(result["isError"] as? Bool, true, created.rawJSON)
                    let createdContent = try XCTUnwrap(result["content"] as? [[String: Any]])
                    let createdText = createdContent.compactMap { $0["text"] as? String }.joined()
                    let createdReceipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(createdText.utf8)) as? [String: Any])
                    XCTAssertEqual(createdReceipt["result"] as? String, "created", created.rawJSON)
                    XCTAssertEqual(createdReceipt["linked"] as? Bool, true, created.rawJSON)
                    let inventory = await authority.links(forObserver: observerID)
                    expectedTargetID = try XCTUnwrap(inventory.items.first?.targetSessionID)
                    XCTAssertNil(observer.oversight.overseerActivation, "Inbound creation needs no bootstrap")
                }
                let inventory = await authority.links(forObserver: observerID)
                let item = inventory.items.first { $0.targetSessionID == expectedTargetID }
                if let item, !inbound { grant = DomainAgentSessionLinkReference(linkID: item.linkID, generation: item.generation) }
                await fulfillment(of: [received], timeout: 2)
                XCTAssertFalse(frames.snapshot.isEmpty)
                let turnAtNotification = await provider.heldTurnSnapshot
                XCTAssertEqual(turnAtNotification, heldTurn, "Discovery must notify without interrupting, restarting, or completing the held turn")
                if activate {
                    let staleCatalogIsHeld = await catalogGate.isHeld
                    XCTAssertTrue(staleCatalogIsHeld, "The real notification must arrive before the older tools/list response is released")
                    await catalogGate.release()
                    let stale = try await XCTUnwrap(delayedCatalog).value
                    XCTAssertTrue(stale.contains(MCPWindowToolName.becomeOverseer))
                    XCTAssertFalse(stale.contains(MCPWindowToolName.agentSessionLink))
                    let observed = await manager.debugRunCatalogProjection(for: runID)
                    let projection = try XCTUnwrap(observed)
                    XCTAssertNotEqual(projection.expectedSurface, projection.returnedSurface, "A late bootstrap completion must preserve newer full expectations")
                    XCTAssertTrue(AgentSessionLinkCodexCatalogRepair.isStuckProjection(projection))
                }
                if w0fProvider != nil {
                    await bridge.test_settleProjections()
                    let stale = try await w0fProjection(manager, runID)
                    let supported = await manager.hasCurrentReturnedTool(Self.w0fTool(), routeToken: route, projectionRevision: stale.projectionRevision)
                    XCTAssertFalse(supported, "A grant/notification is not returned tool evidence")
                }
                let after = try await provider.listTools()
                let visibleElapsed = start.duration(to: clock.now)
                let turnAtVisibleCatalog = await provider.heldTurnSnapshot
                XCTAssertEqual(turnAtVisibleCatalog, heldTurn, "The refreshed catalog must be observable on the same uninterrupted provider turn")
                XCTAssertTrue(after.contains(MCPWindowToolName.agentSessionLink))
                XCTAssertTrue(after.contains(MCPWindowToolName.becomeOverseer), "Targeted bootstrap remains discoverable in the continuing flow")
                if w3Ring {
                    try await w3RegisteredRing(window: window, first: observer, second: target, firstConnection: connection, firstProvider: provider, provenReprompt: w3Reprompt)
                    await cleanup()
                    return
                }
                if let w2Probe {
                    switch w2Probe {
                    case let .repeatDisplay(tools):
                        try await w2RegisteredTerminal(window: window, session: observer, connection: connection, runID: runID, delayed: false, nativeResult: true, closing: true, leading: false, cancel: false, w4BaselineTools: tools)
                        let turnID = try XCTUnwrap(observer.transcript.turns.last?.id)
                        XCTAssertTrue(observer.items.contains { $0.quietCheckInWakeID != nil }, "W1 must already hold a real terminal certificate")
                        try await w2RegisteredTerminal(window: window, session: observer, connection: connection, runID: runID, delayed: true, nativeResult: true, closing: true, leading: false, cancel: false, w4Display: true, w4Repeat: true)
                        XCTAssertEqual(observer.transcript.turns.last?.id, turnID, "W2 continues the same canonical turn")
                    case .coldCatalogOverlap:
                        try await w3ColdCatalogOverlap(window: window, session: observer, target: target, connection: connection, provider: provider)
                    case let .scale(stamps, diagnostic):
                        try await w3FullOwnerScale(window: window, session: observer, target: target, connection: connection, provider: provider, expectsStamps: stamps, diagnostic: diagnostic)
                    case .lateMarker:
                        try await w3InactiveBaseline(window: window, session: observer, connection: connection, provider: provider, stale: false, lateMarker: true)
                    case let .inactiveBaseline(stale):
                        try await w3InactiveBaseline(window: window, session: observer, connection: connection, provider: provider, stale: stale)
                    case let .reprompt(phase):
                        try await w2RegisteredTerminal(window: window, session: observer, connection: connection, runID: runID, delayed: false, nativeResult: true, closing: false, leading: false, cancel: false, repromptPhase: phase)
                    case .undeclared:
                        try await w2RegisteredTerminal(window: window, session: observer, connection: connection, runID: runID, delayed: false, nativeResult: false, closing: false, leading: false, cancel: false, w3Undeclared: true)
                    case let .terminal(delayed, nativeResult, closing, leading, cancel, corrupt):
                        try await w2RegisteredTerminal(window: window, session: observer, connection: connection, runID: runID, delayed: delayed, nativeResult: nativeResult, closing: closing, leading: leading, cancel: cancel, corrupt: corrupt, w4Display: w4Display)
                    case let .hint(withdraw, replaced, ordinaryCandidate):
                        try await w2CatalogProof(window: window, session: observer, provider: provider, endpoint: endpoint, route: route, runID: runID, withdraw: withdraw, replaced: replaced, ordinaryCandidate: ordinaryCandidate)
                    case .lateAttention:
                        try await w2LateAttention(window: window, session: observer, target: target, endpoint: endpoint)
                    case .catalogCost:
                        try await w2CatalogCost(window: window, session: observer, provider: provider, endpoint: endpoint, runID: runID, inactiveTabID: targetTab)
                    }
                    await cleanup()
                    return
                }
                if let w0fProvider {
                    try await w0fRepairControls(manager: manager, provider: provider, window: window, observer: observer, endpoint: endpoint, route: route, runID: runID, kind: w0fProvider, codex: codex, codexRecorder: codexRecorder)
                    await cleanup()
                    return
                }
                let afterDefinitions = try await provider.definitions(wireCaptureName: inbound ? "inbound-after" : (activate ? "activation-after" : "grant-after"))
                try DiscoveryArtifactCapture.write(afterDefinitions, name: inbound ? "inbound-after" : (activate ? "activation-after" : "grant-after"))
                let full = try XCTUnwrap(afterDefinitions.first { $0["name"] as? String == MCPWindowToolName.agentSessionLink })
                XCTAssertGreaterThan(DiscoveryArtifactCapture.operations(full).count, 3)
                if activate {
                    let noLinks = await authority.links(forObserver: observerID)
                    XCTAssertTrue(noLinks.items.isEmpty)
                    let stable = await manager.debugRunCatalogProjection(for: runID)
                    XCTAssertEqual(stable?.expectedSurface, stable?.returnedSurface)
                    XCTAssertEqual(stable?.hasAnyActiveLink, false)
                    XCTAssertEqual(stable?.isReady, false, "Activation is never prompt authority")
                    let frameCount = frames.snapshot.count
                    await manager.notifyToolListChangedForAgentSession(observerID)
                    _ = try await provider.listTools()
                    XCTAssertEqual(frames.snapshot.count, frameCount, "Stable full/no-link must not loop notices")

                    // Configuration-only overlap: activation and link membership remain unchanged.
                    // The old full list must merge its returned evidence with the newer empty
                    // expectation, not restore equality from its pre-disable shaping snapshot.
                    let fullProjection = try XCTUnwrap(stable)
                    let fullSurface = try XCTUnwrap(fullProjection.expectedSurface)
                    let emptySurface = Data("[]".utf8)
                    let paused = expectation(description: "tools/list sampled activated full before global MCP disable")
                    await manager.debugSetAfterExpectedCatalogSurfaceForTesting {
                        paused.fulfill()
                        await disabledCatalogGate.hold()
                    }
                    delayedCatalog = Task { try await provider.listTools() }
                    await fulfillment(of: [paused], timeout: 2)
                    await manager.debugSetAfterExpectedCatalogSurfaceForTesting(nil)
                    catalogDisabledForTesting = true
                    await manager.setEnabled(false)
                    await manager.notifyToolListChangedForAgentSession(observerID)
                    let disabledObservation = await manager.debugRunCatalogProjection(for: runID)
                    let disabledProjection = try XCTUnwrap(disabledObservation)
                    XCTAssertGreaterThan(disabledProjection.projectionRevision, fullProjection.projectionRevision)
                    XCTAssertEqual(disabledProjection.expectedSurface, emptySurface)
                    XCTAssertEqual(disabledProjection.returnedSurface, fullSurface)
                    XCTAssertEqual(disabledProjection.hasAnyActiveLink, fullProjection.hasAnyActiveLink)
                    XCTAssertEqual(disabledProjection.hasActiveOutboundLink, fullProjection.hasActiveOutboundLink)
                    XCTAssertNotNil(observer.oversight.overseerActivation)
                    XCTAssertTrue(AgentSessionLinkCodexCatalogRepair.isStuckProjection(disabledProjection))
                    XCTAssertFalse(AgentSessionLinkCodexCatalogRepair.projectionResolvesCycle(disabledProjection))

                    await disabledCatalogGate.release()
                    let lateFull = try await XCTUnwrap(delayedCatalog).value
                    XCTAssertTrue(lateFull.contains(MCPWindowToolName.agentSessionLink))
                    let lateObservation = await manager.debugRunCatalogProjection(for: runID)
                    let lateProjection = try XCTUnwrap(lateObservation)
                    XCTAssertGreaterThan(lateProjection.projectionRevision, disabledProjection.projectionRevision)
                    XCTAssertEqual(lateProjection.routeToken, route)
                    XCTAssertEqual(lateProjection.expectedSurface, emptySurface, "Late full completion must preserve newer disabled expectations")
                    XCTAssertEqual(lateProjection.returnedSurface, fullSurface)
                    XCTAssertEqual(lateProjection.hasAnyActiveLink, fullProjection.hasAnyActiveLink)
                    XCTAssertEqual(lateProjection.hasActiveOutboundLink, fullProjection.hasActiveOutboundLink)
                    XCTAssertFalse(lateProjection.isReady, "Activation still grants no prompt authority")
                    XCTAssertTrue(AgentSessionLinkCodexCatalogRepair.isStuckProjection(lateProjection))
                    XCTAssertFalse(AgentSessionLinkCodexCatalogRepair.projectionResolvesCycle(lateProjection))

                    let emptyList = try await provider.listTools()
                    XCTAssertFalse(emptyList.contains(MCPWindowToolName.agentSessionLink))
                    XCTAssertFalse(emptyList.contains(MCPWindowToolName.becomeOverseer))
                    let freshObservation = await manager.debugRunCatalogProjection(for: runID)
                    let freshProjection = try XCTUnwrap(freshObservation)
                    XCTAssertEqual(freshProjection.expectedSurface, emptySurface)
                    XCTAssertEqual(freshProjection.returnedSurface, emptySurface)
                    XCTAssertEqual(freshProjection.hasAnyActiveLink, fullProjection.hasAnyActiveLink)
                    XCTAssertEqual(freshProjection.hasActiveOutboundLink, fullProjection.hasActiveOutboundLink)
                    XCTAssertFalse(freshProjection.isReady)
                    XCTAssertFalse(AgentSessionLinkCodexCatalogRepair.isStuckProjection(freshProjection))
                    XCTAssertTrue(AgentSessionLinkCodexCatalogRepair.projectionResolvesCycle(freshProjection))
                    XCTAssertNotNil(observer.oversight.overseerActivation)

                    await manager.setEnabled(true)
                    catalogDisabledForTesting = false
                    await manager.notifyToolListChangedForAgentSession(observerID)
                    let restored = try await provider.listTools()
                    XCTAssertTrue(restored.contains(MCPWindowToolName.agentSessionLink))
                    XCTAssertTrue(restored.contains(MCPWindowToolName.becomeOverseer), "Re-enabling oversight restores bootstrap too")
                }
                let response = try await provider.listLinks()
                let object = try MCPExportWatchdogIntegrationTests.responseObject(from: response)
                let result = try XCTUnwrap(object["result"] as? [String: Any])
                // An activated Overseer with no links lists an empty inventory instead of an error.
                XCTAssertNotEqual(result["isError"] as? Bool, true, response.rawJSON)
                let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                let text = content.compactMap { $0["text"] as? String }.joined()
                if activate {
                    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    XCTAssertEqual((payload["items"] as? [[String: Any]])?.count, 0)
                }
                if !activate {
                    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    let listed = try XCTUnwrap(payload["items"] as? [[String: Any]])
                    XCTAssertEqual(listed.count, 1)
                    XCTAssertEqual(listed.first?["session_id"] as? String, expectedTargetID.uuidString)
                    XCTAssertEqual(listed.first?["link_id"] as? String, item?.linkID.uuidString)
                    XCTAssertEqual(listed.first?["managed"] as? Bool, true)
                }
                if activate {
                    window.apiSettingsViewModel.isClaudeCodeConnected = true
                    try await AsyncTestWait.waitUntil("activated fixture destination availability") { window.apiSettingsViewModel.agentAvailability.claudeCodeAvailable }
                    AgentAdvertisedModelCatalog.shared.record([AgentModelOption(rawValue: "sonnet:high", displayName: "Fixture model", description: nil, isPlaceholderDefault: false, isProviderDefault: false)], for: .claudeCode, generation: AgentAdvertisedModelCatalog.shared.productionGeneration(for: .claudeCode))
                    defer { AgentAdvertisedModelCatalog.shared.invalidate(.claudeCode) }
                    let created = try await connection.callTool(name: MCPWindowToolName.agentSessionLink, arguments: ["op": "create_lane", "model_id": "claudeCode:sonnet:high", "idempotency_key": "activated-discovery-first-lane", "_rawJSON": true], timeoutSeconds: 10)
                    let object = try MCPExportWatchdogIntegrationTests.responseObject(from: created)
                    let result = try XCTUnwrap(object["result"] as? [String: Any])
                    XCTAssertNotEqual(result["isError"] as? Bool, true, created.rawJSON)
                    let createdContent = try XCTUnwrap(result["content"] as? [[String: Any]])
                    let createdText = createdContent.compactMap { $0["text"] as? String }.joined()
                    let createdReceipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(createdText.utf8)) as? [String: Any])
                    XCTAssertEqual(createdReceipt["result"] as? String, "created", created.rawJSON)
                    XCTAssertEqual(createdReceipt["linked"] as? Bool, true, created.rawJSON)
                    let inventory = await authority.links(forObserver: observerID)
                    XCTAssertEqual(inventory.items.count, 1)
                    let link = try XCTUnwrap(inventory.items.first)
                    grant = .init(linkID: link.linkID, generation: link.generation)
                }
                let routeAfter = await manager.authoritativeRunCatalogRouteToken(runID: runID, windowID: window.windowID, tabID: observerTab)
                XCTAssertEqual(routeAfter, route)
                XCTAssertTrue(observer.claudeController === provider)
                XCTAssertEqual(observer.runID, runID)
                XCTAssertEqual(observer.runState, .running)
                let finalTurn = await provider.heldTurnSnapshot
                XCTAssertEqual(finalTurn, heldTurn, "No completion, interruption, restart, or controller replacement during discovery")
                XCTAssertNil(observer.parentSessionID)
                XCTAssertFalse(observer.isMCPOriginated)
                XCTAssertNil(observer.mcpControlContext)
                XCTAssertFalse(vm.isMCPControlled(tabID: observerTab))
                print("LIVE_OVERSEE_DISCOVERY scenario_to_visible=\(visibleElapsed) catalog_watchdog=2s notification_watchdog=2s held_turn_unchanged=\(finalTurn == heldTurn) connection=\(connection.connectionID) turn=\(turnID) notification=\(frames.snapshot)")
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
    }

    enum DiscoveryArtifactCapture {
        static func operations(_ tool: [String: Any]) -> [String] {
            let schema = tool["inputSchema"] as? [String: Any]
            let properties = schema?["properties"] as? [String: Any]
            return (properties?["op"] as? [String: Any])?["enum"] as? [String] ?? []
        }

        static func write(_ tools: [[String: Any]], name: String) throws {
            guard let directory = DiscoveryArtifactConfiguration.directory else { return }
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let family = tools.filter { [MCPWindowToolName.agentSessionLink, MCPWindowToolName.becomeOverseer].contains($0["name"] as? String ?? "") }
            let data = try JSONSerialization.data(withJSONObject: family, options: [.sortedKeys, .withoutEscapingSlashes])
            try data.write(to: root.appendingPathComponent(name + ".json"))
        }
    }

    private actor DiscoveryCatalogGate {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        var isHeld: Bool {
            continuation != nil && !released
        }

        func hold(onHeld: (@Sendable () -> Void)? = nil) async {
            guard !released else { return }
            await withCheckedContinuation {
                continuation = $0
                onHeld?()
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private enum DiscoveryFailure: Error {
        case overseeRefused
    }

    private final class DiscoveryNotificationFrames: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [String] = []
        var snapshot: [String] {
            lock.withLock { frames }
        }

        func captureListChanged(_ data: Data) -> Bool {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "notifications/tools/list_changed", object["id"] == nil
            else { return false }
            return lock.withLock {
                frames.append(String(decoding: data, as: UTF8.self))
                return frames.count == 1
            }
        }
    }

    /// A controllable provider with a held turn and its own real Agent MCP client; never launches a CLI.
    actor HeldDiscoveryProvider: NativeAgentRuntimeControlling {
        struct HeldTurnSnapshot: Equatable {
            let activeTurnID: UUID?
            let lifecycleRevision: Int
        }

        private var connection: PersistentMCPTestEndpoint?
        private(set) var activeTurnID: UUID?
        private var lifecycleRevision = 0
        var heldTurnSnapshot: HeldTurnSnapshot {
            .init(activeTurnID: activeTurnID, lifecycleRevision: lifecycleRevision)
        }

        private var configuration = SessionLinkNativeConfigurationFixture()
        private let eventPair = AsyncStream<NativeAgentRuntimeEvent>.makeStream()
        var hasActiveSession: Bool {
            connection != nil
        }

        var hasTurnInFlight: Bool {
            activeTurnID != nil
        }

        var events: AsyncStream<NativeAgentRuntimeEvent> {
            eventPair.stream
        }

        func attach(_ connection: PersistentMCPTestEndpoint) {
            self.connection = connection
        }

        func currentConnection() throws -> PersistentMCPTestEndpoint {
            try XCTUnwrap(connection)
        }

        func reconnectForBootstrap(clientName: String) async throws {
            let manager = ServerNetworkManager.shared
            let next = try await PersistentMCPTestEndpoint.make(label: "quiet-full-owner-bootstrap", networkManager: manager, clientName: clientName, useProductionAgentAdmission: true, requiredToolNames: [MCPWindowToolName.selfNoop])
            let previous = connection
            connection = next
            previous?.client.close()
            await previous?.connectionManager.stop()
            if let previous { await manager.debugRemoveConnection(previous.connectionID) }
        }

        func ensureEventsStreamReady() {}
        func resetEventsStreamForNewRun() {
            lifecycleRevision += 1
        }

        func startOrResume(existingSessionID _: String?, model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?, systemPromptOverride _: String?) async throws -> NativeAgentRuntimeSessionRef {
            lifecycleRevision += 1
            return currentSessionRef()
        }

        func currentSessionRef() -> NativeAgentRuntimeSessionRef {
            .init(sessionID: "held-discovery-provider")
        }

        func applyModelAndEffort(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws {
            _ = configuration.apply()
        }

        func applyModelAndEffortWithProof(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws -> NativeAgentRuntimeConfigurationApplication {
            configuration.apply()
        }

        func sendUserMessage(_: String, configuration proof: NativeAgentRuntimeConfigurationProof) async throws -> UUID {
            try configuration.validate(proof)
            return try await sendUserMessage("")
        }

        private var sendSuspension: (@Sendable () async -> Void)?

        func setSendSuspension(_ suspension: @escaping @Sendable () async -> Void) {
            sendSuspension = suspension
        }

        func sendUserMessage(_: String) async throws -> UUID {
            let id = UUID()
            lifecycleRevision += 1
            activeTurnID = id
            let suspension = sendSuspension
            sendSuspension = nil
            await suspension?()
            return id
        }

        func completeActiveTurn() {
            guard let id = activeTurnID else { return }
            activeTurnID = nil
            lifecycleRevision += 1
            eventPair.continuation.yield(.turnCompleted(turnID: id, status: .completed))
        }

        func listTools() async throws -> Set<String> {
            try await Set(definitions().compactMap { $0["name"] as? String })
        }

        func definitions(wireCaptureName: String? = nil) async throws -> [[String: Any]] {
            let connection = try XCTUnwrap(connection)
            let response = try await connection.client.request(method: "tools/list", params: [:], timeoutSeconds: 2)
            if let name = wireCaptureName, let directory = DiscoveryArtifactConfiguration.directory {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data(response.rawJSON.utf8).write(to: root.appendingPathComponent(name + "-wire.json"))
            }
            let object = try MCPExportWatchdogIntegrationTests.responseObject(from: response)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            return try XCTUnwrap(result["tools"] as? [[String: Any]])
        }

        func callSelfNoop() async throws -> PersistentMCPTestRPCResponse {
            try await XCTUnwrap(connection).callTool(name: MCPWindowToolName.selfNoop, arguments: [:], timeoutSeconds: 2)
        }

        func listLinks() async throws -> PersistentMCPTestRPCResponse {
            try await XCTUnwrap(connection).callTool(name: MCPWindowToolName.agentSessionLink, arguments: ["op": "list", "_rawJSON": true], timeoutSeconds: 2)
        }

        func interruptTurn(reason _: String) -> NativeAgentRuntimeInterruptOutcome {
            lifecycleRevision += 1
            return .noTurnInFlight
        }

        func shutdown() async {
            lifecycleRevision += 1
            activeTurnID = nil
            let previous = connection
            connection = nil
            eventPair.continuation.finish()
            previous?.client.close()
            await previous?.connectionManager.stop()
            if let previous { await ServerNetworkManager.shared.debugRemoveConnection(previous.connectionID) }
        }

        func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) {}
    }
#endif
#if DEBUG
    @MainActor
    private extension AgentSessionLinkLiveDiscoveryTests {
        nonisolated static func w0fTool() -> MCP.Tool {
            MCP.Tool(
                name: "self_noop", description: "Quietly close a routine wake that needs nothing.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
            )
        }

        nonisolated static func w0fReturnedShape(copies: Int = 1, permissiveSchema: Bool = false) -> @Sendable ([MCP.Tool], Bool) -> [MCP.Tool] {
            { tools, outbound in
                guard outbound, tools.contains(where: { $0.name == MCPWindowToolName.agentSessionLink }) else { return tools }
                guard let candidate = tools.first(where: { $0.name == MCPWindowToolName.selfNoop }) else { return tools }
                let returned = permissiveSchema
                    ? MCP.Tool(name: candidate.name, description: candidate.description, inputSchema: .object(["type": .string("object")]))
                    : candidate
                return tools.filter { $0.name != MCPWindowToolName.selfNoop } + Array(repeating: returned, count: copies)
            }
        }

        func assertW2Acknowledgement(_ content: [[String: Any]]) throws {
            XCTAssertEqual(content.count, 1)
            XCTAssertEqual(content.first?["type"] as? String, "text")
            let text = try XCTUnwrap(content.first?["text"] as? String)
            XCTAssertTrue(text.hasPrefix("```json\n"))
            XCTAssertTrue(text.hasSuffix("\n```"))
            let body = String(text.dropFirst("```json\n".count).dropLast("\n```".count))
            let decoded = try JSONDecoder().decode(Value.self, from: Data(body.utf8))
            XCTAssertEqual(decoded, .object(["result": .string("done")]), "Exact body, decoded through unchanged generic MCP envelope")
        }

        private func w3InactiveBaseline(window: WindowState, session: AgentTabSession, connection: PersistentMCPTestEndpoint, provider: HeldDiscoveryProvider, stale: Bool, lateMarker: Bool = false) async throws {
            let connected = window.apiSettingsViewModel.isClaudeCodeConnected
            window.apiSettingsViewModel.isClaudeCodeConnected = true
            defer { window.apiSettingsViewModel.isClaudeCodeConnected = connected }
            let vm = window.agentModeViewModel
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(vm, tabID: session.tabID)
            session.appendItem(.user("ordinary baseline", sequenceIndex: session.nextSequenceIndex))
            session.appendItem(.assistant("ordinary conclusion", sequenceIndex: session.nextSequenceIndex))
            session.runState = .completed
            vm.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
            let original = try XCTUnwrap(session.transcript.turns.last)
            if stale { session.derivedTranscriptSyncState = nil }
            let activeSibling = try XCTUnwrap(window.workspaceManager.activeWorkspace?.composeTabs.first { $0.id != session.tabID })
            vm.test_setCurrentTabIDOverride(activeSibling.id)
            XCTAssertNotEqual(vm.currentTabID, session.tabID)
            session.oversight.autoWakeOnUpdates = true
            session.isPreparingInitialWorktree = true
            let target = vm.session(for: activeSibling.id)
            target.installRunID(UUID())
            _ = target.beginRunAttempt(source: "W3 ordinary reservation cause")
            target.runState = .running
            target.appendItem(.assistant("ordinary reservation cause", sequenceIndex: target.nextSequenceIndex))
            await vm.test_finishQuietFeasibilityRun(target)
            XCTAssertEqual(target.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 1))
            let bridge = AgentSessionLinkRuntimeBridge.shared
            await bridge.test_settleTargetPublications()
            await bridge.test_refreshStatus(sessionIDs: [endpoint.sessionID])
            let reserved = try XCTUnwrap(session.oversight.pendingAutoWake)
            reserved.task?.cancel()
            await reserved.task?.value
            XCTAssertNotNil(reserved.wakeFingerprint)
            let wake = reserved.wakeID
            session.isPreparingInitialWorktree = false
            let claim = try XCTUnwrap(vm.agentSessionLinkPromptClaim(for: session, dispatchID: .autoWake(wakeID: wake)))
            XCTAssertTrue(claim.routineQuietCheckIn)
            XCTAssertNotNil(vm.agentSessionLinkPrepareAutoWakeDispatch(wakeID: wake, endpoint: endpoint))
            var rebuilds = 0
            AgentTranscriptDebugInstrumentation.configure(.init(rebuildHandler: { _ in rebuilds += 1 }))
            defer { AgentTranscriptDebugInstrumentation.reset() }
            let binding = vm.providerBindingService
            let preferences = binding.preferences
            let runtime = ClaudeControllerLaunchPolicy.resolve(
                permissionMode: binding.runtimePermission(for: session.selectedAgent, profile: session.permissionProfile).claudePermissionMode,
                profile: session.permissionProfile, defaults: preferences.defaults, securePermissions: preferences.securePermissions
            )
            let permission = ClaudeAgentToolPreferences.resolvePermissionMode(
                requestedMode: runtime.permissionMode ?? session.permissionProfile.claudePermissionMode,
                agentKind: session.selectedAgent, selectedModelRaw: session.selectedModelRaw,
                unsupportedAutoFallback: session.parentSessionID == nil ? .autoApproveEdits : .fullAccess
            )
            try vm.test_claudeCoordinator.test_setControllerLaunchSettings(.init(
                runtimeVariant: session.selectedAgent.claudeRuntimeVariant ?? .standard,
                workspacePath: vm.effectiveWorkspacePath(for: session),
                permissionMode: permission.effectiveMode, allowNativeBashTool: runtime.allowNativeBashTool,
                mcpStrictMode: runtime.mcpStrictMode
            ), for: session)
            vm.test_initializeRunService(mcpServerEnabler: { true }, connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in }, expectedPIDPolicyArmer: { _ in true })
            let acceptedReturn = TestReleaseFence(name: "W3 actual native call before fake acceptance")
            defer { acceptedReturn.release() }
            await provider.setSendSuspension { await acceptedReturn.enterAndWait() }
            let before = await provider.heldTurnSnapshot
            let recorder = AgentRunStartOutcomeRecorder()
            await vm.startAgentRun(tabID: session.tabID, initialMessage: "", directStartOptions: .laneUpdate(wakeID: wake), startOutcome: recorder)
            XCTAssertEqual(recorder.outcome, .accepted)
            guard await acceptedReturn.waitUntilEntered() else {
                let history = await ServerNetworkManager.shared.debugRunRoutingHistoryPayload(runID: session.runID, limit: 30)
                print("W3_FULL_START_CALL_REFUSED routing=\(history)")
                throw CancellationError()
            }
            let dispatchOwner = try XCTUnwrap(session.activeRunOwnership)
            XCTAssertEqual(session.quietLedger.baseline(owner: dispatchOwner) == nil, stale)
            XCTAssertEqual(rebuilds, 0, "Currency is proved before the normal accepted-marker append")
            if lateMarker {
                AgentTranscriptDebugInstrumentation.reset()
                let actualTask = session.agentTask
                weak var producer = session.oversight.pendingAutoWake?.quietMarkerProducerLifetime
                XCTAssertNotNil(producer)
                XCTAssertFalse(session.liveItemIDs.contains(wake))
                try await w2RegisteredTerminal(window: window, session: session, connection: connection, runID: XCTUnwrap(session.runID), delayed: false, nativeResult: true, closing: false, leading: false, cancel: false, w3Owner: dispatchOwner)
                XCTAssertTrue(session.quietLedger.hiddenSourceIDs.contains(wake))
                let successor = session.beginRunAttempt(source: "W3 later W2 declaration owner")
                let successorWake = UUID()
                session.quietLedger.markRoutineWake(owner: successor, wakeID: successorWake)
                session.runState = .running
                let foreign = AgentChatItem.laneUpdateAutoWake(wakeID: UUID(), acceptedAt: Date(), sequenceIndex: session.nextSequenceIndex)
                XCTAssertTrue(session.appendAcceptedHostMarker(foreign))
                XCTAssertNil(session.items.last?.quietCheckInWakeID)
                acceptedReturn.release()
                try await AsyncTestWait.waitUntil("late real native acceptance materializes W1 during W2") { session.liveItemIDs.contains(wake) }
                XCTAssertEqual(session.items.first { $0.id == wake }?.quietCheckInWakeID, wake)
                XCTAssertNil(session.items.first { $0.id == foreign.id }?.quietCheckInWakeID)
                XCTAssertEqual(session.activeRunOwnership, successor)
                XCTAssertEqual(session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 0))
                await provider.completeActiveTurn()
                await actualTask?.value
                try await AsyncTestWait.waitUntil("old native producer cohort retires") { producer == nil }
                XCTAssertTrue(session.quietLedger.hiddenSourceIDs.contains(wake), "Materialized ownership survives final producer release")
                XCTAssertEqual(session.activeRunOwnership, successor)
                try await w2RegisteredTerminal(window: window, session: session, connection: connection, runID: XCTUnwrap(session.runID), delayed: false, nativeResult: true, closing: false, leading: false, cancel: false, w3Owner: successor)
                XCTAssertEqual(session.quietLedger.facts, .init(settledThrough: 2, ordinaryThrough: 0))
                XCTAssertEqual(session.items.first { $0.id == wake }?.quietCheckInWakeID, wake, "W2 cannot adopt W1's late member")
                XCTAssertNil(session.items.first { $0.id == foreign.id }?.quietCheckInWakeID)
                XCTAssertTrue(session.items.contains { $0.quietCheckInWakeID == successorWake })
                let markerIndex = try XCTUnwrap(session.items.firstIndex { $0.id == wake })
                _ = session.removeItem(at: markerIndex)
                session.clearDerivedTranscriptCaches()
                XCTAssertFalse(session.quietLedger.hiddenSourceIDs.contains(wake), "Exact source and anchor retirement remove only that proof")
                _ = try XCTUnwrap(vm.test_installPersistentSessionBinding(sessionID: UUID(), on: session, updateWorkspaceMetadata: true))
                let revision = session.sourceItemsRevision
                let rows = session.items
                vm.agentSessionLinkRecordAcceptedAutoWake(claim)
                XCTAssertEqual(session.items, rows, "An old binding's captured acceptance cannot append a marker")
                XCTAssertEqual(session.sourceItemsRevision, revision)
                print("W3_LATE_MARKER own=certified foreign=ordinary retired=true staleBinding=rejected")
                return
            }
            acceptedReturn.release()
            do {
                try await AsyncTestWait.waitUntil("full startAgentRun physically accepts native fake input") {
                    await provider.heldTurnSnapshot.lifecycleRevision > before.lifecycleRevision && session.liveItemIDs.contains(wake)
                }
            } catch {
                let history = await ServerNetworkManager.shared.debugRunRoutingHistoryPayload(runID: session.runID, limit: 30)
                let data = try JSONSerialization.data(withJSONObject: history, options: [.sortedKeys])
                print("W3_FULL_START_REFUSAL state=\(session.runState) owner=\(String(describing: session.activeRunOwnership)) phase=\(String(describing: session.oversight.pendingAutoWake?.phase)) routing=\(String(decoding: data, as: UTF8.self))")
                throw error
            }
            let owner = try XCTUnwrap(session.activeRunOwnership)
            XCTAssertEqual(session.quietLedger.routineWakeID(owner: owner), wake)
            let baseline = session.quietLedger.baseline(owner: owner)
            XCTAssertEqual(baseline == nil, stale)
            if !stale {
                XCTAssertEqual(baseline?.turnID, original.id)
                XCTAssertEqual(baseline?.local.conclusionActivityID, original.conclusionActivityID)
                XCTAssertEqual(baseline?.local.completedAt, original.completedAt)
            }
            AgentTranscriptDebugInstrumentation.reset()
            print("W3_FULL_START stale=\(stale) owner=\(owner.attemptID) wake=\(wake) baseline=\(baseline != nil) rebuilds=\(rebuilds)")
            try await w2RegisteredTerminal(window: window, session: session, connection: connection, runID: XCTUnwrap(session.runID), delayed: false, nativeResult: true, closing: false, leading: false, cancel: false, w3Owner: owner, expectOrdinary: stale, w3Provider: provider)
        }

        /// Actual registered body + normal native ingress and production terminal hooks. The only
        /// eligibility input supplied by this fixture is the routine wake's origin qualification.
        func w2RegisteredTerminal(
            window: WindowState, session: AgentTabSession, connection: PersistentMCPTestEndpoint,
            runID: UUID, delayed: Bool, nativeResult: Bool, closing: Bool, leading: Bool, cancel: Bool,
            w3Owner: AgentRunOwnership? = nil, w3Undeclared: Bool = false, w3Reprompt: Bool = false, corrupt: Bool = false, repromptPhase: String? = nil, expectOrdinary: Bool = false, w3Provider: HeldDiscoveryProvider? = nil, scaleControl: Bool? = nil, scaleDiagnostic: Bool = false, unqualifiedOrigin: Bool = false, w4Display: Bool = false, w4Repeat: Bool = false, w4BaselineTools: Int = 0
        ) async throws {
            let vm = window.agentModeViewModel
            let manager = ServerNetworkManager.shared
            let connection = try await w3Provider?.currentConnection() ?? connection
            let claude = session.selectedAgent == .claudeCode
            var phaseStart = ContinuousClock.now
            func phase(_ label: String) {
                let now = ContinuousClock.now
                if scaleDiagnostic { print("W3_TERMINAL_PHASE label=\(label) duration=\(phaseStart.duration(to: now))") }
                phaseStart = now
            }
            vm.test_initializeRunService()
            let openingFacts = try XCTUnwrap(session.quietLedger.facts)
            if w3Owner == nil, !w4Repeat {
                session.appendItem(.user("routine fixture origin", sequenceIndex: session.nextSequenceIndex))
                for _ in 0 ..< w4BaselineTools {
                    let invocation = UUID()
                    // Native ingress completes one canonical row in place. A separate raw
                    // call row would remain pending and the real terminal finalizer would
                    // rewrite it during W1, correctly invalidating that synthetic range.
                    session.appendItem(.toolResult(name: "read_file", invocationID: invocation, argsJSON: #"{"path":"example.swift"}"#, resultJSON: #"{"content":"ordinary"}"#, isError: false, sequenceIndex: session.nextSequenceIndex))
                }
                session.appendItem(.assistant("ordinary baseline conclusion", sequenceIndex: session.nextSequenceIndex))
                if w4BaselineTools > 0 {
                    session.runState = .running
                    vm.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
                }
                session.runState = .completed
                vm.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
                if w4BaselineTools > 0 {
                    XCTAssertEqual(Set(session.items.filter { $0.toolName == "read_file" }.compactMap(\.toolInvocationID)).count, w4BaselineTools)
                    XCTAssertFalse(session.items.contains { $0.kind == .toolCall }, "Completed ordinary baseline has no unfinished native tool row")
                }
            }
            if w4Repeat {
                vm.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
                _ = vm.test_publishTranscriptPresentation(tabID: session.tabID)
                vm.syncTranscriptUIState()
            }
            let repeatBaseline = vm.ui.transcript.snapshot
            var repeatPublications = 0
            // Compare whole value trees, not just leaf membership: Equatable includes
            // summary-only groups, nested sections, counts, narration and tool state.
            let repeatSubscription = w4Repeat ? vm.ui.transcript.$snapshot.sink { snapshot in
                repeatPublications += 1
                XCTAssertEqual(snapshot.presentation.visibleRows, repeatBaseline.presentation.visibleRows, "Repeat W2 publication \(repeatPublications): exact rows")
                XCTAssertEqual(snapshot.presentation.visibleBlocks, repeatBaseline.presentation.visibleBlocks, "Repeat W2 publication \(repeatPublications): complete blocks/summaries")
                XCTAssertEqual(snapshot.archivedBlocks, repeatBaseline.archivedBlocks, "Repeat W2 publication \(repeatPublications): archived blocks/summaries")
            } : nil
            defer { repeatSubscription?.cancel() }
            let owner = w3Owner ?? session.beginRunAttempt(source: "W2.registered-native-terminal")
            let attemptStart = try XCTUnwrap(session.quietLedger.startKey(owner: owner))
            let openingTerminalRevision = session.lastTerminalCommitRevision
            let preparedRevision = session.sourceItemsRevision
            session.runState = .running
            if w4BaselineTools > 0 || w4Repeat {
                XCTAssertEqual(session.sourceItemsRevision, preparedRevision, "Prepared fixture must not structurally change when the attempt becomes running")
            }
            let handler = vm.test_claudeCoordinator.testToolTrackingHandler(for: session)
            let codex = vm.test_codexCoordinator
            let decoder = CodexNativeSessionController(client: CodexAppServerClient(), runID: runID, tabID: session.tabID, windowID: window.windowID, workspacePaths: .uniform(nil))
            let thread = "w2-exact-thread"
            let turn = "w2-exact-turn-\(owner.attemptID)"
            let raw = (claude ? "toolu_w2_queued_host" : "w2_original_native_call_string") + "-\(owner.attemptID)"
            let mailbox = TestReleaseFence(name: "before first registered noop host callback")
            var translator = ClaudeSDKNDJSONTranslator()
            var nativeTask: Task<Void, Never>?
            var terminalTask: Task<Void, Never>?
            var nativeIDs: [UUID] = []
            var nativeDelivered: XCTestExpectation?
            let terminalDelivered = AsyncStream<Void>.makeStream()
            if claude {
                await handler.startTracking(runID: runID, session: session, clientNameHint: nil)
            } else {
                session.codexController = decoder
                session.codexConversationID = thread
                session.codexPendingTurnKind = .user
                await decoder.test_installThreadState(threadID: thread, authoritativeTurnID: turn, routingTurnID: turn)
                await codex.test_handleCodexNativeEvent(.turnStarted(turnID: turn), session: session, sourceController: decoder)
                await codex.testStartCodexToolTracking(for: session, runID: runID)
                let events = decoder.events
                nativeTask = Task {
                    for await event in events {
                        await codex.test_handleCodexNativeEvent(event, session: session, sourceController: decoder)
                        switch event {
                        case let .toolCall(_, id, _, _), let .toolResult(_, id, _, _, _, _):
                            if let id { nativeIDs.append(id) }
                            nativeDelivered?.fulfill()
                        case .turnCompleted: terminalDelivered.continuation.yield(())
                        default: break
                        }
                    }
                }
            }
            if w3Owner == nil {
                session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
            } else {
                XCTAssertEqual(session.quietLedger.routineWakeID(owner: owner) == nil, unqualifiedOrigin, "The assembled caller supplies its actual qualified or overlap-disqualified owner")
            }
            let ownedWake = session.quietLedger.routineWakeID(owner: owner)
            var w4Published = 0
            let w4CanonicalBefore = session.items
            let w4Subscription = w4Display ? vm.ui.transcript.$snapshot.sink { snapshot in
                guard session.quietDisplayCandidate != nil else { return }
                w4Published += 1
                func allBlocks(_ blocks: [AgentTranscriptRenderBlock]) -> [AgentTranscriptRenderBlock] {
                    blocks.flatMap { [$0] + allBlocks($0.groupedHistory?.sections.flatMap(\.childBlocks) ?? []) }
                }
                let blocks = allBlocks(snapshot.presentation.visibleBlocks + snapshot.archivedBlocks)
                let rows = snapshot.presentation.visibleRows + blocks.flatMap(\.rows)
                XCTAssertFalse(rows.contains { $0.sequenceIndex >= attemptStart && ($0.kind != .system || $0.id == ownedWake) }, "No provisional source member in any published snapshot")
                XCTAssertFalse(blocks.flatMap(\.activityIDs).contains { id in
                    session.items.contains { $0.id == id && $0.sequenceIndex >= attemptStart && ($0.kind != .system || $0.id == ownedWake) }
                }, "No nested group membership or narration carrier")
            } : nil
            defer { w4Subscription?.cancel() }
            func w4Publish() {
                guard w4Display else { return }
                vm.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
                _ = vm.test_publishTranscriptPresentation(tabID: session.tabID)
                vm.syncTranscriptUIState()
            }
            w4Publish()
            if w4Display, !w4Repeat {
                let wake = try XCTUnwrap(ownedWake)
                XCTAssertTrue(session.appendAcceptedHostMarker(.laneUpdateAutoWake(wakeID: wake, acceptedAt: Date(), sequenceIndex: session.nextSequenceIndex)))
                w4Publish()
                let foreign = AgentChatItem.laneUpdateAutoWake(wakeID: UUID(), acceptedAt: Date(), sequenceIndex: session.nextSequenceIndex)
                XCTAssertTrue(session.appendAcceptedHostMarker(foreign))
                w4Publish()
                XCTAssertTrue(vm.ui.transcript.snapshot.presentation.visibleRows.contains { $0.id == foreign.id }, "A foreign ordinary marker never joins the staged range")
                await vm.test_handleStreamResult(.init(type: "reasoning", text: "Provisional private reasoning"), session: session, runID: runID, runAttemptID: owner.attemptID)
                w4Publish()
                vm.test_setCurrentTabIDOverride(UUID())
                vm.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
                vm.test_setCurrentTabIDOverride(session.tabID)
                w4Publish()
            }
            let foreignMembers = session.items.filter { $0.sequenceIndex >= attemptStart && $0.kind == .system && $0.id != ownedWake }
            func flush() async {
                if claude { await handler.waitForPendingEventDeliveries() }
                else { await codex.testFlushCodexToolTracking(for: session) }
            }
            func native(result: Bool) async throws {
                defer { w4Publish() }
                if claude {
                    let block: [String: Any] = result
                        ? ["type": "tool_result", "tool_use_id": raw, "content": [["type": "text", "text": "{\"result\":\"done\"}"]]]
                        : ["type": "tool_use", "id": raw, "name": "mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__self_noop", "input": [:]]
                    let data = try JSONSerialization.data(withJSONObject: ["type": result ? "user" : "assistant", "message": ["content": [block]]])
                    for stream in translator.parseNDJSONLine(data) {
                        if stream.type == "tool_result" { XCTAssertNil(stream.toolIsError, "Host-owned error verdict is intentionally not inferred by the translator") }
                        if let id = stream.toolInvocationID { nativeIDs.append(id) }
                        await vm.test_handleStreamResult(stream, session: session, runID: runID, runAttemptID: owner.attemptID)
                    }
                } else {
                    let delivered = expectation(description: "registered noop native representation")
                    nativeDelivered = delivered
                    await decoder.test_handleNotification(method: result ? "item/completed" : "item/started", params: [
                        "threadId": .string(thread), "turnId": .string(turn), "item": .object([
                            "type": .string("mcpToolCall"), "id": .string(raw),
                            "server": .string(MCPIntegrationHelper.repoPromptMCPServerName), "tool": .string("self_noop"),
                            "arguments": .object([:]), "status": .string(result ? "completed" : "inProgress"),
                            "result": result ? .object(["content": .array([.object(["type": .string("text"), "text": .string("{\"result\":\"done\"}")])])]) : .null
                        ])
                    ])
                    await fulfillment(of: [delivered], timeout: 5)
                    nativeDelivered = nil
                }
            }
            func assistantText(_ text: String) async throws {
                defer { w4Publish() }
                if claude {
                    let data = try JSONSerialization.data(withJSONObject: ["type": "assistant", "message": ["content": [["type": "text", "text": text]]]])
                    for stream in translator.parseNDJSONLine(data) {
                        await vm.test_handleStreamResult(stream, session: session, runID: runID, runAttemptID: owner.attemptID)
                    }
                } else {
                    await codex.test_handleCodexNativeEvent(.assistantDelta(text), session: session, sourceController: decoder)
                }
            }
            func cleanup() async {
                mailbox.release()
                await terminalTask?.value
                await decoder.shutdown()
                await nativeTask?.value
                terminalDelivered.continuation.finish()
                if claude {
                    await handler.stopTracking(for: session)
                } else {
                    await codex.testStopCodexToolTracking(for: session)
                }
            }
            func harnessReprompt() async throws {
                let data = try JSONSerialization.data(withJSONObject: [
                    "type": "user", "isSynthetic": true,
                    "message": ["content": [["type": "text", "text": "[Your previous response had no visible output. Please continue and produce a user-visible response.]"]]]
                ])
                for stream in translator.parseNDJSONLine(data) {
                    await vm.test_handleStreamResult(stream, session: session, runID: runID, runAttemptID: owner.attemptID)
                }
            }
            do {
                if repromptPhase == "before" {
                    try await harnessReprompt()
                }
                if leading {
                    try await assistantText("leading output before declaration")
                }
                if !w3Undeclared {
                    try await native(result: false)
                }
                phase("tracking-and-native-call")
                if delayed {
                    if claude { handler.enqueueEventDeliveryBarrierForTesting { await mailbox.enterAndWait() } }
                    else { codex.testEnqueueCodexToolTrackingBarrier(for: session) { await mailbox.enterAndWait() } }
                    guard await mailbox.waitUntilEntered() else { throw CancellationError() }
                }
                if !w3Undeclared {
                    let metadata: [String: Any] = claude ? ["claudecode/toolUseId": raw] : ["callId": raw, "threadId": thread, "itemId": "not-a-host-UUID"]
                    let response = try await connection.client.request(method: "tools/call", params: ["name": "self_noop", "arguments": [:], "_meta": metadata])
                    phase("registered-body")
                    let result = try XCTUnwrap(try MCPExportWatchdogIntegrationTests.responseObject(from: response)["result"] as? [String: Any])
                    XCTAssertNotEqual(result["isError"] as? Bool, true, response.rawJSON)
                    let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                    try assertW2Acknowledgement(content)
                    let hostID = session.quietLedger.acceptedDeclarationInvocationID(owner: owner)
                    XCTAssertEqual(hostID == nil, leading || repromptPhase == "before" || unqualifiedOrigin, "Leading activity or missing positive origin prevents acceptance")
                    XCTAssertEqual(session.quietLedger.declarationBodyEntryCardinality(owner: owner), 1)
                    if let hostID {
                        XCTAssertTrue(nativeIDs.allSatisfy { $0 != hostID })
                    }
                    XCTAssertFalse(window.mcpServer.hasActiveToolExecutions(runID: runID))
                    XCTAssertFalse(manager.hasPendingToolCardObservations(windowID: window.windowID, runID: runID))
                    if nativeResult {
                        try await native(result: true)
                    }
                    XCTAssertEqual(nativeIDs.count, nativeResult ? 2 : 1)
                }
                let hostID = session.quietLedger.acceptedDeclarationInvocationID(owner: owner)
                if !delayed {
                    await flush()
                }
                phase("native-result-and-host-drain")
                let replayReprompt = w3Reprompt && w3Owner != nil && claude && !w3Undeclared
                if replayReprompt {
                    // Preserve the SDK's harness-only retry; this is not new user work.
                    try await assistantText("")
                    let prompt = "[Your previous response had no visible output. Please continue and produce a user-visible response.]"
                    let data = try JSONSerialization.data(withJSONObject: [
                        "type": "user", "isSynthetic": true,
                        "message": ["role": "user", "content": [["type": "text", "text": prompt]]],
                        "parent_tool_use_id": NSNull(), "session_id": session.providerSessionID ?? "held-discovery-provider",
                        "uuid": UUID().uuidString, "timestamp": "2026-10-21T00:00:00.000Z"
                    ])
                    let streams = translator.parseNDJSONLine(data)
                    print("W3_PROVEN_REPROMPT staticSDK=2.1.292 liveCapture=false isSynthetic=true isMeta=absent providerInput=\(prompt) translatedTypes=\(streams.map(\.type))")
                    for stream in streams {
                        await vm.test_handleStreamResult(stream, session: session, runID: runID, runAttemptID: owner.attemptID)
                    }
                }
                if repromptPhase == "afterOtherTool" {
                    let data = try JSONSerialization.data(withJSONObject: ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "toolu_other", "name": "read_file", "input": [:]]]]])
                    for stream in translator.parseNDJSONLine(data) {
                        await vm.test_handleStreamResult(stream, session: session, runID: runID, runAttemptID: owner.attemptID)
                    }
                    try await harnessReprompt()
                }
                if closing {
                    try await assistantText(w4Repeat ? "allowed closing output after accepted body W2" : "allowed closing output after accepted body")
                }
                XCTAssertEqual(session.quietLedger.hasOrdinaryOccurrence(owner: owner), leading || repromptPhase != nil || unqualifiedOrigin, "Temporal ingress distinguishes missing origin/leading text from allowed closing output")
                let complete = hostID.map { id in claude ? handler.hasCompleteExactAssociation(hostInvocationID: id, owner: owner, session: session) : session.quietLedger.codexAssociationIsComplete(owner: owner, hostID: id, runID: runID, threadID: thread) } ?? false
                if scaleControl == nil {
                    let rowDiagnostics = session.items.map { "\($0.sequenceIndex):\($0.kind):\($0.toolInvocationID == hostID):\($0.isStreaming)" }
                    print("W2_PRE_TERMINAL provider=\(session.selectedAgent.rawValue) delayed=\(delayed) occurrence=\(session.quietLedger.hasOrdinaryOccurrence(owner: owner)) complete=\(complete) start=\(String(describing: session.quietLedger.startKey(owner: owner))) rows=\(rowDiagnostics)")
                }
                if scaleControl != nil { XCTAssertTrue(complete, "Measured completion retains actual native correlation") }
                if unqualifiedOrigin {
                    XCTAssertNil(hostID)
                    XCTAssertFalse(complete, "Missing accepted declaration cannot supply complete quiet association")
                }
                if corrupt {
                    session.test_beforeQuietMetadataSeal = {
                        session.test_beforeQuietMetadataSeal = nil
                        guard let index = session.items.lastIndex(where: { $0.toolInvocationID == hostID }) else { XCTFail("Missing actual registered member")
                            return
                        }
                        let sameID = session.items[index].id
                        session.mutateItem(at: index) { $0.toolName = "read_file" }
                        XCTAssertEqual(session.items[index].id, sameID)
                    }
                }
                terminalTask = Task {
                    if let w3Provider {
                        let actualTask = session.agentTask
                        await w3Provider.completeActiveTurn()
                        await actualTask?.value
                    } else if claude {
                        let id = UUID()
                        session.claudeExpectedTurnIDs.insert(id)
                        let stream = AsyncStream<NativeAgentRuntimeEvent> { c in
                            c.yield(.turnCompleted(turnID: id, status: .completed))
                            c.finish()
                        }
                        _ = await vm.test_consumeClaudeTerminalEvents(stream, session: session, runID: runID, owner: owner)
                    } else {
                        await decoder.test_handleNotification(method: "turn/completed", params: ["threadId": .string(thread), "turn": .object(["id": .string(turn), "status": .string("completed")])])
                        for await _ in terminalDelivered.stream {
                            break
                        }
                    }
                }
                if delayed {
                    try await AsyncTestWait.waitUntil("terminal reaches the queued observation cut or conservative leading-text settlement") {
                        (claude ? handler.pendingEventDeliveryWaiterCountForTesting : codex.testCodexToolTrackingWaiterCount(for: session)) > 0 || session.lastTerminalCommitRevision != openingTerminalRevision
                    }
                    if !leading, !w3Undeclared {
                        XCTAssertEqual(session.lastTerminalCommitRevision, openingTerminalRevision, "Must drain queued host evidence before deciding eligibility")
                    }
                    if cancel {
                        print("W2_CANCEL_CUT provider=\(session.selectedAgent.rawValue) phase=\(session.terminalCommitInProgress) revision=\(session.lastTerminalCommitRevision != nil) drain=\(session.providerTerminalDrainGeneration)")
                        await vm.cancelAgentRun(tabID: session.tabID, completion: .terminalPublished)
                    }
                    mailbox.release()
                }
                await terminalTask?.value
                phase("runner-terminal-and-task-completion")
                if scaleDiagnostic {
                    await print("W3_ROUTE_TERMINAL outcome=\(String(describing: MCPRoutingWaiter.currentTerminalOutcome(runID: runID))) history=\(manager.debugRunRoutingHistoryPayload(runID: runID, limit: 30))")
                }
                XCTAssertEqual(session.quietLedger.facts, .init(settledThrough: openingFacts.settledThrough + 1, ordinaryThrough: nativeResult && !leading && !cancel && !w3Undeclared && !corrupt && repromptPhase == nil && !expectOrdinary ? openingFacts.ordinaryThrough : openingFacts.settledThrough + 1), "\(session.selectedAgent) delayed=\(delayed) nativeResult=\(nativeResult) closing=\(closing) leading=\(leading) cancel=\(cancel)")
                XCTAssertNotNil(session.lastTerminalCommitRevision)
                if w4Display {
                    w4Publish()
                    XCTAssertGreaterThan(w4Published, 0)
                    if w4Repeat {
                        XCTAssertGreaterThan(repeatPublications, 1)
                        XCTAssertEqual(session.transcript.turns.last?.retentionTier, .full)
                        XCTAssertNil(session.quietDisplayCandidate, "W2 must finish through durable certification, not a still-held candidate")
                        print("W4_REPEAT_DISPLAY tools=\(Set(session.items.filter { $0.toolName == "read_file" }.compactMap(\.toolInvocationID)).count) publications=\(repeatPublications) spans=\(session.transcript.turns.last?.responseSpans.count ?? 0)")
                    }
                    XCTAssertEqual(Array(session.items.prefix(w4CanonicalBefore.count)), w4CanonicalBefore, "Local staging cannot rewrite ordinary source")
                    let expected = AgentModeViewModel.buildTranscriptPresentation(
                        from: session.transcript, sourceItems: session.items, selectedAgent: session.selectedAgent,
                        previousPerformanceSnapshot: .empty
                    )
                    XCTAssertEqual(vm.ui.transcript.snapshot.presentation.visibleRows, expected.projection.workingRows, "Terminal releases actual ordinary work, or uses durable certified omission")
                    XCTAssertEqual(vm.ui.transcript.snapshot.presentation.visibleBlocks, expected.projection.workingBlocks)
                }
                XCTAssertNotEqual(session.lastTerminalCommitRevision, openingTerminalRevision)
                if cancel {
                    XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .cancelled)
                    XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, owner)
                    XCTAssertNil(session.activeRunOwnership)
                    XCTAssertFalse(session.terminalCommitInProgress)
                    let revision = session.lastTerminalCommitRevision
                    await vm.cancelAgentRun(tabID: session.tabID, completion: .terminalPublished)
                    XCTAssertEqual(session.lastTerminalCommitRevision, revision, "Duplicate Stop must not create a second terminal revision")
                    XCTAssertEqual(session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 1))
                }
                if closing {
                    XCTAssertTrue(session.items.contains { $0.text.contains("allowed closing output after accepted body") }, "Buffered output survives terminal/cancellation settlement")
                }
                let shouldStamp = nativeResult && !leading && !cancel && !w3Undeclared && !corrupt && repromptPhase == nil && !expectOrdinary && scaleControl != false
                let stamped = session.items.filter { $0.sequenceIndex >= attemptStart && $0.quietCheckInWakeID != nil && $0.quietCheckInWakeID == ownedWake }
                for foreign in foreignMembers {
                    XCTAssertEqual(session.items.first { $0.id == foreign.id }?.quietCheckInWakeID, foreign.quietCheckInWakeID)
                }
                XCTAssertEqual(stamped.isEmpty, !shouldStamp, "Production terminal must stamp exactly qualified members")
                if shouldStamp {
                    if w4Repeat {
                        XCTAssertTrue(stamped.contains { $0.text == "allowed closing output after accepted body W2" }, "The second native turn must materialize and certify its own distinct closing row")
                    }
                    let wake = try XCTUnwrap(stamped.first?.quietCheckInWakeID)
                    XCTAssertTrue(stamped.allSatisfy { $0.quietCheckInWakeID == wake })
                    XCTAssertFalse(stamped.contains { $0.kind == .user || $0.text == "ordinary baseline conclusion" })
                    XCTAssertNotNil(session.transcript.turns.last?.quietLocal)
                }
                print("W2_REGISTERED_TERMINAL provider=\(session.selectedAgent.rawValue) delayed=\(delayed) nativeResult=\(nativeResult) settled=\(session.quietLedger.facts?.settledThrough ?? 0) ordinary=\(session.quietLedger.facts?.ordinaryThrough ?? 0)")
                phase("terminal-assertions")
                await cleanup()
                phase("tracking-cleanup")
            } catch { await cleanup()
                throw error
            }
        }

        /// Read only the existing authoritative observation; never relist or wait for convergence.
        private func w3RequireCurrentCatalog(vm: AgentModeViewModel, session: AgentTabSession, label: String) async throws {
            let manager = ServerNetworkManager.shared
            let run = try XCTUnwrap(session.runID)
            let observedRoute = await manager.authoritativeRunCatalogRouteToken(runID: run, windowID: vm.windowID, tabID: session.tabID)
            let route = try XCTUnwrap(observedRoute)
            let observedProjection = await manager.debugRunCatalogProjection(for: run)
            let projection = try XCTUnwrap(observedProjection)
            let positive = await manager.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: route, projectionRevision: projection.projectionRevision)
            guard positive, projection.routeToken == route,
                  vm.agentSessionLinkRunCatalogProjectionByEndpoint[route.observerEndpoint] == projection,
                  vm.selfNoopHintIsCurrent(for: session)
            else { XCTFail("Steady catalog proof failed without retry: \(label) revision=\(projection.projectionRevision)")
                throw CancellationError()
            }
            print("W3_CATALOG_READY label=\(label) run=\(run) connection=\(route.connectionID) routingGeneration=\(route.routingAuthorityGeneration) revision=\(projection.projectionRevision) exactCurrentDefinition=true mirrorMatches=true")
        }

        /// Force a real list/publication overlap through existing gates, not a fabricated catalog.
        private func w3ForceCatalogOverlap(vm: AgentModeViewModel, session: AgentTabSession, provider: HeldDiscoveryProvider) async throws {
            let manager = ServerNetworkManager.shared
            let run = try XCTUnwrap(session.runID)
            let id = try XCTUnwrap(session.activeAgentSessionID)
            let gate = TestReleaseFence(name: "catalog completion before newer real publication")
            await manager.debugSetAfterExpectedCatalogSurfaceForTesting { await gate.enterAndWait() }
            let list = Task { try await provider.listTools() }
            do {
                guard await gate.waitUntilEntered() else { throw CancellationError() }
                await manager.debugSetAfterExpectedCatalogSurfaceForTesting(nil)
                let beforeObservation = await manager.debugRunCatalogProjection(for: run)
                let before = try XCTUnwrap(beforeObservation)
                await manager.notifyToolListChangedForAgentSession(id, forceRelist: true)
                let newerObservation = await manager.debugRunCatalogProjection(for: run)
                let newer = try XCTUnwrap(newerObservation)
                XCTAssertGreaterThan(newer.projectionRevision, before.projectionRevision)
                gate.release()
                let names = try await list.value
                XCTAssertTrue(names.contains(MCPWindowToolName.selfNoop))
                let overlapObservation = await manager.debugRunCatalogProjection(for: run)
                let overlapped = try XCTUnwrap(overlapObservation)
                XCTAssertGreaterThan(overlapped.projectionRevision, newer.projectionRevision)
                XCTAssertEqual(overlapped.routeToken, newer.routeToken)
                XCTAssertTrue(overlapped.isReady, "Family/route readiness is not exact positive definition evidence")
                XCTAssertNil(overlapped.returnedCatalog, "The real overlap fence must withhold positive evidence")
                XCTAssertFalse(vm.selfNoopHintIsCurrent(for: session))
                print("W3_COLD_OVERLAP before=\(before.projectionRevision) newer=\(newer.projectionRevision) completion=\(overlapped.projectionRevision) exactEvidence=unknown expected=ordinary")
            } catch {
                await manager.debugSetAfterExpectedCatalogSurfaceForTesting(nil)
                gate.release()
                _ = try? await list.value
                throw error
            }
        }

        private func w3ColdCatalogOverlap(window: WindowState, session: AgentTabSession, target: AgentTabSession, connection: PersistentMCPTestEndpoint, provider: HeldDiscoveryProvider) async throws {
            let vm = window.agentModeViewModel
            let bridge = AgentSessionLinkRuntimeBridge.shared
            let connected = window.apiSettingsViewModel.isClaudeCodeConnected
            window.apiSettingsViewModel.isClaudeCodeConnected = true
            defer { window.apiSettingsViewModel.isClaudeCodeConnected = connected
                session.oversight.autoWakeOnUpdates = false
            }
            session.appendItem(.user("cold catalog characterization", sequenceIndex: session.nextSequenceIndex))
            session.appendItem(.assistant("ordinary baseline", sequenceIndex: session.nextSequenceIndex))
            session.runState = .completed
            vm.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
            vm.test_setCurrentTabIDOverride(target.tabID)
            session.isPreparingInitialWorktree = true
            session.oversight.autoWakeOnUpdates = true
            let binding = vm.providerBindingService
            let preferences = binding.preferences
            let runtime = ClaudeControllerLaunchPolicy.resolve(permissionMode: binding.runtimePermission(for: session.selectedAgent, profile: session.permissionProfile).claudePermissionMode, profile: session.permissionProfile, defaults: preferences.defaults, securePermissions: preferences.securePermissions)
            let permission = ClaudeAgentToolPreferences.resolvePermissionMode(requestedMode: runtime.permissionMode ?? session.permissionProfile.claudePermissionMode, agentKind: session.selectedAgent, selectedModelRaw: session.selectedModelRaw, unsupportedAutoFallback: .autoApproveEdits)
            try vm.test_claudeCoordinator.test_setControllerLaunchSettings(.init(runtimeVariant: session.selectedAgent.claudeRuntimeVariant ?? .standard, workspacePath: vm.effectiveWorkspacePath(for: session), permissionMode: permission.effectiveMode, allowNativeBashTool: runtime.allowNativeBashTool, mcpStrictMode: runtime.mcpStrictMode), for: session)
            w3InitializeSocketBootstrap(vm: vm, provider: provider, coldOverlap: true)
            vm.test_beforeRoutineIdleFollowUpStart = { current, wake in
                let claim = vm.agentSessionLinkPromptClaimStore.pendingClaim(dispatchID: .autoWake(wakeID: wake), observerSessionID: current.activeAgentSessionID!)
                XCTAssertEqual(claim?.routineQuietCheckIn, true, "The controlled overlap happens after the initial positive reservation")
                return true
            }
            defer { vm.test_beforeRoutineIdleFollowUpStart = nil }
            target.installRunID(UUID())
            _ = target.beginRunAttempt(source: "cold catalog ordinary cause")
            target.runState = .running
            target.appendItem(.assistant("ordinary cause", sequenceIndex: target.nextSequenceIndex))
            await vm.test_finishQuietFeasibilityRun(target)
            await bridge.test_settleTargetPublications()
            try await bridge.test_refreshStatus(sessionIDs: [XCTUnwrap(session.activeAgentSessionID)])
            let reserved = try XCTUnwrap(session.oversight.pendingAutoWake)
            let before = await provider.heldTurnSnapshot
            let opening = try XCTUnwrap(session.quietLedger.facts)
            session.isPreparingInitialWorktree = false
            try await AsyncTestWait.waitUntil("actual native acceptance after controlled catalog overlap") {
                await provider.heldTurnSnapshot.lifecycleRevision > before.lifecycleRevision && session.liveItemIDs.contains(reserved.wakeID)
            }
            let owner = try XCTUnwrap(session.activeRunOwnership)
            XCTAssertNil(session.quietLedger.routineWakeID(owner: owner))
            XCTAssertTrue(session.quietLedger.hasOrdinaryOccurrence(owner: owner))
            try await w2RegisteredTerminal(window: window, session: session, connection: connection, runID: XCTUnwrap(session.runID), delayed: false, nativeResult: true, closing: false, leading: false, cancel: false, w3Owner: owner, expectOrdinary: true, w3Provider: provider, unqualifiedOrigin: true)
            XCTAssertEqual(session.quietLedger.facts, .init(settledThrough: opening.settledThrough + 1, ordinaryThrough: opening.settledThrough + 1))
            XCTAssertFalse(session.items.contains { $0.quietCheckInWakeID != nil })
        }

        private func w3BootstrapCatalogSetup(vm: AgentModeViewModel, provider: HeldDiscoveryProvider, tabID: UUID?, coldOverlap: Bool) async throws {
            let session = try XCTUnwrap(try vm.sessions[XCTUnwrap(tabID)])
            if coldOverlap {
                try await w3ForceCatalogOverlap(vm: vm, session: session, provider: provider)
            } else {
                // Exactly one explicit setup list after both owners prove handover complete.
                // It is not a retry of unknown evidence and never loops until positive.
                let names = try await provider.listTools()
                XCTAssertTrue(names.contains(MCPWindowToolName.selfNoop))
                try await w3RequireCurrentCatalog(vm: vm, session: session, label: "post-handover-single-list")
            }
        }

        private func w3InitializeSocketBootstrap(vm: AgentModeViewModel, provider: HeldDiscoveryProvider, coldOverlap: Bool = false) {
            vm.test_initializeRunService(mcpServerEnabler: { true }, expectedPIDPolicyArmer: { spec in
                let manager = ServerNetworkManager.shared
                guard let clientName = spec.clientName else { return false }
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: spec.runID)
                let armed = await manager.requireExpectedAgentPIDForPendingPolicy(for: clientName, runID: spec.runID, windowID: spec.windowID)
                do {
                    guard armed else {
                        await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: spec.runID)
                        return false
                    }
                    try await provider.reconnectForBootstrap(clientName: clientName)
                    let committed = await manager.isRunRouteAuthoritativelyCommitted(runID: spec.runID, windowID: spec.windowID, tabID: spec.tabID, expectedAgentPID: getpid())
                    await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: spec.runID)
                    XCTAssertTrue(committed, "Existing socket admission, not a test-supplied routing outcome")
                    guard committed else { return false }
                    try await self.w3BootstrapCatalogSetup(vm: vm, provider: provider, tabID: spec.tabID, coldOverlap: coldOverlap)
                    return true
                } catch {
                    await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: spec.runID)
                    XCTFail("Quiet fake bootstrap socket failed: \(error)")
                    return false
                }
            })
        }

        /// Opt-in diagnostic/measurement entry points share this exact owner-to-quiescence path.
        /// Other overseers retain real queues but have automatic admission disabled.
        private func w3FullOwnerScale(
            window: WindowState, session: AgentTabSession, target: AgentTabSession,
            connection: PersistentMCPTestEndpoint, provider: HeldDiscoveryProvider,
            expectsStamps: Bool, diagnostic: Bool
        ) async throws {
            let watchdog = ContinuousClock.now
            let vm = window.agentModeViewModel
            let bridge = AgentSessionLinkRuntimeBridge.shared
            let authority = AppDomainRuntimeComposition.shared.runtime.agentSessionLinkAuthority
            let connected = window.apiSettingsViewModel.isClaudeCodeConnected
            window.apiSettingsViewModel.isClaudeCodeConnected = true
            let originalMaskCallback = session.onQuietDisplayMaskChanged
            var extraWindows: [WindowState] = []
            var registrations: [MCPDomainToolRegistrationHandle] = []
            var extraGrants: [DomainAgentSessionLinkReference] = []
            var allSessions = [session, target]
            var overseers = [session, target]
            var measuring = false
            var countingSetup = true
            var fixtureSaves = 0
            var rebuilds = 0
            var summaries = 0
            var summaryRows = 0
            var refreshes = 0
            var samples = 0
            var fanouts = 0
            var publications = 0
            var saves = 0
            var physicalWakes = 0
            var starts = 0
            var certificationStart: ContinuousClock.Instant?
            var certificationMS: Double?
            var maskCallbacks = 0
            var wholeSamples: [Double] = []
            var certificationSamples: [Double] = []
            var structuralTail: [[String: Int]] = []
            func milliseconds(_ duration: Duration) -> Double {
                Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            }
            func addChats(_ count: Int, to owner: WindowState) async throws -> [AgentTabSession] {
                let ownerVM = owner.agentModeViewModel
                var workspace = try XCTUnwrap(owner.workspaceManager.activeWorkspace)
                let added = (0 ..< count).map { index in
                    ComposeTabState(id: UUID(), name: "W3 unrelated chat \(index)", activeAgentSessionID: UUID())
                }
                for tab in added {
                    let payload = try AgentSession(id: XCTUnwrap(tab.activeAgentSessionID), workspaceID: workspace.id, composeTabID: tab.id, name: tab.name, agentKind: AgentProviderKind.claudeCode.rawValue, autoWakeOnOversightUpdates: false)
                    _ = try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace)
                    fixtureSaves += 1
                }
                workspace.composeTabs.append(contentsOf: added)
                let workspaceIndex = try XCTUnwrap(owner.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
                owner.workspaceManager.workspaces[workspaceIndex] = workspace
                owner.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: false)
                var result: [AgentTabSession] = []
                for tab in added {
                    let restored = await ownerVM.ensureSessionReady(tabID: tab.id, reconnectActiveProviders: false)
                    XCTAssertEqual(restored.activeAgentSessionID, tab.activeAgentSessionID)
                    XCTAssertTrue(restored.qualifiedRestorationReadiness.isAuthoritative)
                    result.append(restored)
                }
                for restored in result {
                    await restored.saveDebounceTask?.value
                }
                return result
            }
            func drain() async {
                await bridge.test_settleTargetPublications()
                await bridge.test_settleCandidateAvailabilityNotifications()
                await bridge.test_refreshStatus(sessionIDs: Set(overseers.compactMap(\.activeAgentSessionID)))
                await bridge.test_settleTargetPublications()
                await bridge.test_settleCandidateAvailabilityNotifications()
            }
            func workCounts() -> [String: Int] {
                ["rebuilds": rebuilds, "summaryTraversals": summaries, "summaryRows": summaryRows, "refreshes": refreshes, "passiveLinkSamples": samples, "factsFanouts": fanouts, "sourcePublications": publications, "saves": saves]
            }
            func resetWorkCounts() {
                rebuilds = 0
                summaries = 0
                summaryRows = 0
                refreshes = 0
                samples = 0
                fanouts = 0
                publications = 0
                saves = 0
            }
            func awaitRestorationWork() async {
                for owner in [window] + extraWindows {
                    let ownerVM = owner.agentModeViewModel
                    await ownerVM.test_waitForSessionListCacheRefresh()
                    for current in Array(ownerVM.sessions.values) {
                        await ownerVM.test_drainScheduledDerivedTranscriptRefresh(tabID: current.tabID)
                        await current.saveDebounceTask?.value
                    }
                    ownerVM.test_flushPendingUIRefresh()
                }
                await bridge.test_settleTargetPublications()
                await bridge.test_settleCandidateAvailabilityNotifications()
            }
            func completeSetup(_ label: String, since start: ContinuousClock.Instant) async throws {
                await drain()
                await awaitRestorationWork()
                await drain()
                await awaitRestorationWork()
                let settled = workCounts()
                let generations = allSessions.map(\.saveRequestGeneration)
                await awaitRestorationWork()
                await Task { @MainActor in }.value
                guard workCounts() == settled, allSessions.map(\.saveRequestGeneration) == generations,
                      allSessions.allSatisfy({ $0.derivedTranscriptRefreshTask == nil })
                else {
                    XCTFail("Restored setup still has rebuild/save/summary work: \(label) before=\(settled) after=\(workCounts())")
                    throw CancellationError()
                }
                if label == "initial-restoration" {
                    let observed = try await ServerNetworkManager.shared.debugRunCatalogProjection(for: XCTUnwrap(session.runID))
                    let prior = try XCTUnwrap(observed)
                    let oldSupport = try await ServerNetworkManager.shared.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: XCTUnwrap(prior.routeToken), projectionRevision: prior.projectionRevision)
                    XCTAssertFalse(oldSupport, "An offer predating restored chats and new links must be invalidated")
                }
                // Material setup changes invalidate the earlier offer. Obtain one real list after
                // setup, outside measurement, without retrying until positive.
                let names = try await provider.listTools()
                XCTAssertTrue(names.contains(MCPWindowToolName.selfNoop))
                try await w3RequireCurrentCatalog(vm: vm, session: session, label: label)
                guard workCounts() == settled, allSessions.map(\.saveRequestGeneration) == generations,
                      allSessions.allSatisfy({ $0.derivedTranscriptRefreshTask == nil })
                else { XCTFail("Read-only catalog proof exposed unsettled setup: \(label)")
                    throw CancellationError()
                }
                let data = try JSONSerialization.data(withJSONObject: ["label": label, "durationMS": milliseconds(start.duration(to: .now)), "workCounts": settled, "fixturePayloadSaves": fixtureSaves, "chats": allSessions.count, "ownedSaveHandlesAwaited": allSessions.count(where: { $0.saveDebounceTask != nil }), "pendingDerivedRefreshes": 0, "verificationWorkDelta": 0, "saveGenerationsStable": true] as [String: Any], options: [.sortedKeys])
                print("W3_SETUP \(String(decoding: data, as: UTF8.self))")
                countingSetup = false
            }
            func restoreUnrelatedHistory() async throws {
                let prior = allSessions[10]
                await prior.saveDebounceTask?.value
                await vm.test_drainScheduledDerivedTranscriptRefresh(tabID: prior.tabID)
                let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                let sessionID = try XCTUnwrap(prior.activeAgentSessionID)
                let rows = [AgentChatItem.user("unrelated history", sequenceIndex: 0)] + (1 ... 10000).map {
                    AgentChatItem.assistant("unrelated historical activity", sequenceIndex: $0)
                }
                let canonical = AgentTranscriptIO.buildTranscript(from: rows, terminalState: .completed)
                let payload = AgentSession(id: sessionID, workspaceID: workspace.id, composeTabID: prior.tabID, name: "Unrelated restored history", transcript: canonical, agentKind: AgentProviderKind.claudeCode.rawValue, lastRunState: AgentSessionRunState.completed.rawValue, autoWakeOnOversightUpdates: false)
                _ = try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace)
                fixtureSaves += 1
                vm.test_removeSession(tabID: prior.tabID)
                let restored = await vm.ensureSessionReady(tabID: prior.tabID, reconnectActiveProviders: false)
                XCTAssertFalse(restored === prior)
                XCTAssertEqual(restored.activeAgentSessionID, sessionID)
                XCTAssertTrue(restored.qualifiedRestorationReadiness.isAuthoritative)
                XCTAssertEqual(restored.items.map(\.id), rows.map(\.id), "Existing canonical restore, not 10000 live append events")
                XCTAssertNotNil(restored.derivedTranscriptSyncState)
                allSessions[10] = restored
            }
            func cleanup() async {
                measuring = false
                countingSetup = false
                AgentTranscriptDebugInstrumentation.reset()
                session.test_beforeQuietMetadataSeal = nil
                session.onQuietDisplayMaskChanged = originalMaskCallback
                bridge.test_onPassiveSample = nil
                bridge.test_onFactsFanout = nil
                bridge.test_afterTargetPublicationAcceptance = nil
                vm.test_beforeRoutineIdleFollowUpStart = nil
                window.apiSettingsViewModel.isClaudeCodeConnected = connected
                for current in allSessions {
                    current.oversight.autoWakeOnUpdates = false
                    current.oversight.pendingAutoWake?.task?.cancel()
                }
                for grant in extraGrants {
                    await bridge.revokeLink(linkID: grant.linkID, generation: grant.generation)
                }
                for (index, owner) in extraWindows.enumerated() {
                    await owner.tearDown()
                    if registrations.indices.contains(index) { await AppDomainRuntimeComposition.shared.unregister(registrations[index]) }
                    WindowStatesManager.shared.unregisterWindowState(owner)
                }
            }
            bridge.test_onPassiveSample = { _ in if measuring || countingSetup { samples += 1 } }
            bridge.test_onFactsFanout = { _ in if measuring || countingSetup { fanouts += 1 } }
            bridge.test_afterTargetPublicationAcceptance = { _ in if measuring || countingSetup { publications += 1 } }
            AgentTranscriptDebugInstrumentation.configure(.init(
                rebuildHandler: { _ in if measuring || countingSetup { rebuilds += 1 } },
                summaryTraversalHandler: { metrics in if measuring || countingSetup { summaries += 1
                    summaryRows += metrics.activityCount
                } },
                refreshAttemptHandler: { _ in if measuring || countingSetup { refreshes += 1 } }
            ))
            do {
                allSessions += try await addChats(98, to: window)
                for index in 0 ..< 2 {
                    let owner = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
                    WindowStatesManager.shared.registerWindowState(owner)
                    extraWindows.append(owner)
                    let registration = try await AppDomainRuntimeComposition.shared.register(owner.mcpServer.windowMCPToolCatalogService)
                    registrations.append(registration.handle)
                    await owner.workspaceManager.awaitInitialized()
                    var workspace = WorkspaceModel(name: "W3 scale window \(index)", repoPaths: [])
                    workspace.isEphemeral = true
                    owner.workspaceManager.workspaces.append(workspace)
                    let switched = await owner.workspaceManager.switchWorkspace(to: workspace, saveState: false)
                    XCTAssertTrue(switched.didSwitch)
                    let restored = try await addChats(100, to: owner)
                    if index == 0 { overseers += restored.prefix(4) }
                    allSessions += restored
                }
                XCTAssertEqual(allSessions.count, 300)
                XCTAssertEqual(overseers.count, 6)
                for current in allSessions {
                    current.oversight.autoWakeOnUpdates = false
                    current.oversight.routineWakeIntervalEnabled = false
                    current.runState = .completed
                }
                for (source, destination) in [(1, 0), (0, 2), (1, 2), (2, 0), (3, 0), (4, 1), (5, 1), (2, 3), (4, 5)] {
                    let observerID = try XCTUnwrap(overseers[source].activeAgentSessionID)
                    let targetID = try XCTUnwrap(overseers[destination].activeAgentSessionID)
                    guard case .added = await bridge.addMonitorLink(observerSessionID: observerID, rawTargetSessionID: targetID.uuidString) else { throw DiscoveryFailure.overseeRefused }
                    let links = await authority.links(forObserver: observerID)
                    let link = try XCTUnwrap(links.items.first { $0.targetSessionID == targetID })
                    extraGrants.append(.init(linkID: link.linkID, generation: link.generation))
                }
                var linkCount = 0
                for current in overseers {
                    linkCount += try await authority.links(forObserver: XCTUnwrap(current.activeAgentSessionID)).items.count
                }
                XCTAssertEqual(linkCount, 10)
                session.appendItem(.user("ordinary suffix origin", sequenceIndex: session.nextSequenceIndex))
                for _ in 0 ..< 999 {
                    session.appendItem(.assistant("ordinary suffix activity", sequenceIndex: session.nextSequenceIndex))
                }
                vm.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
                vm.test_setCurrentTabIDOverride(target.tabID)
                session.oversight.autoWakeOnUpdates = true
                let binding = vm.providerBindingService
                let preferences = binding.preferences
                let runtime = ClaudeControllerLaunchPolicy.resolve(permissionMode: binding.runtimePermission(for: session.selectedAgent, profile: session.permissionProfile).claudePermissionMode, profile: session.permissionProfile, defaults: preferences.defaults, securePermissions: preferences.securePermissions)
                let permission = ClaudeAgentToolPreferences.resolvePermissionMode(requestedMode: runtime.permissionMode ?? session.permissionProfile.claudePermissionMode, agentKind: session.selectedAgent, selectedModelRaw: session.selectedModelRaw, unsupportedAutoFallback: .autoApproveEdits)
                try vm.test_claudeCoordinator.test_setControllerLaunchSettings(.init(runtimeVariant: session.selectedAgent.claudeRuntimeVariant ?? .standard, workspacePath: vm.effectiveWorkspacePath(for: session), permissionMode: permission.effectiveMode, allowNativeBashTool: runtime.allowNativeBashTool, mcpStrictMode: runtime.mcpStrictMode), for: session)
                w3InitializeSocketBootstrap(vm: vm, provider: provider)
                vm.test_setAgentSessionSaver { payload, workspace, count in
                    let url = try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
                    if measuring || countingSetup { saves += 1 }
                    return url
                }
                vm.test_beforeRoutineIdleFollowUpStart = { current, _ in
                    XCTAssertTrue(current === session)
                    starts += 1
                    return true
                }
                session.test_beforeQuietMetadataSeal = { certificationStart = .now }
                session.onQuietDisplayMaskChanged = { current in
                    originalMaskCallback?(current)
                    if certificationMS == nil, let start = certificationStart { certificationMS = milliseconds(start.duration(to: .now)) }
                    if measuring {
                        maskCallbacks += 1
                        if diagnostic { print("W3_MASK_CALLBACK ordinal=\(maskCallbacks) sinceSealMS=\(certificationStart.map { milliseconds($0.duration(to: .now)) } ?? -1) stack=\(Thread.callStackSymbols.prefix(14))") }
                    }
                }
                try await completeSetup("initial-restoration", since: watchdog)
                let cycles = diagnostic ? 3 : 64
                for iteration in 0 ..< cycles {
                    guard milliseconds(watchdog.duration(to: .now)) < 300_000 else { XCTFail("W3 five-minute runaway gate")
                        throw CancellationError()
                    }
                    if iteration == (diagnostic ? 1 : 58) {
                        countingSetup = true
                        resetWorkCounts()
                        fixtureSaves = 0
                        let setupStart = ContinuousClock.now
                        try await restoreUnrelatedHistory()
                        try await completeSetup("unrelated-history-restoration", since: setupStart)
                    }
                    if iteration == (diagnostic ? 2 : 61) {
                        countingSetup = true
                        resetWorkCounts()
                        fixtureSaves = 0
                        let setupStart = ContinuousClock.now
                        for owner in [window] + extraWindows {
                            allSessions += try await addChats(100, to: owner)
                        }
                        XCTAssertEqual(allSessions.count, 600)
                        try await completeSetup("unrelated-chat-restoration", since: setupStart)
                    }
                    session.isPreparingInitialWorktree = true
                    target.installRunID(UUID())
                    _ = target.beginRunAttempt(source: "W3 scale ordinary cause")
                    target.runState = .running
                    target.appendItem(.assistant("ordinary source close", sequenceIndex: target.nextSequenceIndex))
                    await vm.test_finishQuietFeasibilityRun(target)
                    await drain()
                    let reserved = try XCTUnwrap(session.oversight.pendingAutoWake)
                    XCTAssertNotNil(reserved.wakeFingerprint)
                    let wake = reserved.wakeID
                    let before = await provider.heldTurnSnapshot
                    let openingFacts = try XCTUnwrap(session.quietLedger.facts)
                    let memberVisits = session.test_quietMetadataVisitedItems
                    resetWorkCounts()
                    certificationStart = nil
                    certificationMS = nil
                    maskCallbacks = 0
                    measuring = true
                    let wholeStart = ContinuousClock.now
                    session.isPreparingInitialWorktree = false
                    try await AsyncTestWait.waitUntil("scale scheduled full-start physically accepts native fake input") {
                        await provider.heldTurnSnapshot.lifecycleRevision > before.lifecycleRevision && session.liveItemIDs.contains(wake)
                    }
                    let acceptedAt = ContinuousClock.now
                    physicalWakes += 1
                    let owner = try XCTUnwrap(session.activeRunOwnership)
                    XCTAssertEqual(session.quietLedger.routineWakeID(owner: owner), wake)
                    try await w2RegisteredTerminal(window: window, session: session, connection: connection, runID: XCTUnwrap(session.runID), delayed: false, nativeResult: true, closing: false, leading: false, cancel: false, w3Owner: owner, w3Provider: provider, scaleControl: expectsStamps, scaleDiagnostic: diagnostic)
                    let terminalAt = ContinuousClock.now
                    await drain()
                    let drainedAt = ContinuousClock.now
                    let wholeMS = milliseconds(wholeStart.duration(to: .now))
                    measuring = false
                    XCTAssertNil(session.oversight.pendingAutoWake, "Paid ordinary debt cannot echo the quiet close")
                    XCTAssertEqual(session.quietLedger.facts, .init(settledThrough: openingFacts.settledThrough + 1, ordinaryThrough: openingFacts.ordinaryThrough))
                    XCTAssertEqual(starts, iteration + 1)
                    XCTAssertEqual(physicalWakes, iteration + 1)
                    if expectsStamps { XCTAssertNotNil(certificationMS) } else { XCTAssertNil(certificationMS) }
                    let phase = diagnostic ? "diagnostic" : iteration < 5 ? "warmup" : iteration < 55 ? "sample" : iteration < 58 ? "tail-control" : iteration < 61 ? "unrelated-history" : "unrelated-chats"
                    let record: [String: Any] = ["iteration": iteration, "phase": phase, "stamps": expectsStamps, "wholeMS": wholeMS, "nativeAcceptanceMS": milliseconds(wholeStart.duration(to: acceptedAt)), "registeredBodyAndTerminalMS": milliseconds(acceptedAt.duration(to: terminalAt)), "postTerminalDrainMS": milliseconds(terminalAt.duration(to: drainedAt)), "certificationMS": certificationMS ?? -1, "maskCallbacks": maskCallbacks, "memberValidationWriteVisits": session.test_quietMetadataVisitedItems - memberVisits, "rebuilds": rebuilds, "summaryTraversals": summaries, "summaryRows": summaryRows, "refreshes": refreshes, "passiveLinkSamples": samples, "factsFanouts": fanouts, "sourcePublications": publications, "physicalWakes": 1, "saves": saves, "sourceRows": session.items.count, "chats": allSessions.count, "windows": 3, "overseers": 6, "directionalLinks": linkCount]
                    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    print("W3_PERF \(String(decoding: data, as: UTF8.self))")
                    if iteration >= 55 {
                        structuralTail.append(["members": session.test_quietMetadataVisitedItems - memberVisits, "rebuilds": rebuilds, "summaries": summaries, "summaryRows": summaryRows, "refreshes": refreshes, "linkSamples": samples, "fanouts": fanouts, "publications": publications, "physical": 1, "saves": saves])
                    }
                    if phase == "sample" { wholeSamples.append(wholeMS)
                        if let certificationMS { certificationSamples.append(certificationMS) }
                    }
                }
                XCTAssertLessThanOrEqual(milliseconds(watchdog.duration(to: .now)), 300_000, "Five-minute total harness watchdog, including setup")
                if !diagnostic {
                    XCTAssertEqual(structuralTail.count, 9)
                    if structuralTail.count == 9 {
                        // Coalesced link samples use the predeclared fresh matched-band series oracle;
                        // retain every raw callback count, but do not treat a timing-dependent maximum as a resource ceiling.
                        for key in ["members", "rebuilds", "summaries", "refreshes", "fanouts", "publications", "physical", "saves"] {
                            let controls = structuralTail.prefix(3).compactMap { $0[key] }
                            let ceiling = try XCTUnwrap(controls.max())
                            for row in structuralTail.dropFirst(3) {
                                XCTAssertLessThanOrEqual(try XCTUnwrap(row[key]), ceiling, "Unrelated history/chats must not grow measured \(key)")
                            }
                        }
                        let first = try XCTUnwrap(structuralTail[0]["summaryRows"])
                        let second = try XCTUnwrap(structuralTail[1]["summaryRows"])
                        let third = try XCTUnwrap(structuralTail[2]["summaryRows"])
                        let slope = max(second - first, third - second)
                        for index in 3 ..< 9 {
                            XCTAssertLessThanOrEqual(try XCTUnwrap(structuralTail[index]["summaryRows"]), third + slope * (index - 2), "Only the measured unchanged-suffix growth may remain; unrelated source history must not be traversed")
                        }
                    }
                    XCTAssertEqual(wholeSamples.count, 50)
                    func report(_ label: String, _ values: [Double]) {
                        guard !values.isEmpty else { return }
                        let sorted = values.sorted()
                        print("W3_COUNTS metric=\(label) count=\(values.count) median=\(sorted[24]) p95=\(sorted[47]) max=\(sorted[sorted.count - 1])")
                    }
                    report("whole", wholeSamples)
                    report("certification", certificationSamples)
                    if expectsStamps {
                        XCTAssertEqual(certificationSamples.count, 50)
                        XCTAssertLessThanOrEqual(certificationSamples.sorted()[47], 8, "120Hz full synchronous certification gate")
                    }
                }
                await cleanup()
            } catch { await cleanup()
                throw error
            }
        }

        private struct W3CauseClose {
            let endpoint: DomainAgentSessionLinkEndpointIdentity
            let before: AgentRunQuietFacts
            let after: AgentRunQuietFacts
            let sourceSequence: UInt64
            let terminalCommit: UUID
            let label: String

            var isQuiet: Bool {
                after.ordinaryThrough == before.ordinaryThrough
            }
        }

        /// Assembled W3 discriminator on the accepted W2 host. Only provider/socket doubles and
        /// deterministic scheduling gates are test-owned; declaration and settlement are not injected.
        func w3RegisteredRing(
            window: WindowState, first: AgentTabSession, second: AgentTabSession,
            firstConnection: PersistentMCPTestEndpoint, firstProvider: HeldDiscoveryProvider,
            provenReprompt: Bool
        ) async throws {
            let vm = window.agentModeViewModel
            vm.test_initializeRunService()
            let bridge = AgentSessionLinkRuntimeBridge.shared
            let authority = AppDomainRuntimeComposition.shared.runtime.agentSessionLinkAuthority
            let manager = ServerNetworkManager.shared
            let firstKind = first.selectedAgent
            second.selectedAgent = firstKind == .claudeCode ? .codexExec : .claudeCode
            let secondRun = UUID()
            second.installRunID(secondRun)
            let secondClient = second.selectedAgent == .claudeCode ? AgentProviderKind.claudeMCPClientID : AgentProviderKind.codexMCPClientID
            let secondProvider = HeldDiscoveryProvider()
            var secondConnection: PersistentMCPTestEndpoint?
            var reverseGrant: DomainAgentSessionLinkReference?
            var frameGate: TestReleaseFence?
            var gatedRefresh: Task<Void, Never>?
            let peers = [first, second]
            let ids = Set(peers.compactMap(\.activeAgentSessionID))
            var accepted: [String] = []
            var codexControllers: [MonitorFakeCodexController] = []
            let variant = provenReprompt ? "proven-reprompt" : "closing-text-and-silent"
            var closes: [W3CauseClose] = []
            var edgeCauses: [String: W3CauseClose] = [:]
            var reservationCauses: [UUID: W3CauseClose] = [:]
            // Test audit of actual accepted receipt cutoffs; never used for production admission.
            var paidCutoffs: [DomainAgentSessionLinkReference: UInt64] = [:]
            var quietCausedAccepted = 0
            var seedCausedAccepted = 0
            var seedDebtPaid: Set<DomainAgentSessionLinkReference> = []
            var controlCausedAccepted = 0
            var repromptCausedAccepted = 0
            var sampleCount = 0
            func edgeKey(_ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot, _ entry: AgentSessionLinkPassiveStatusNotices.PendingEntry) -> String {
                "\(snapshot.observerEndpoint.sessionID):\(snapshot.queueEpoch):\(entry.reference.linkID):\(entry.reference.generation):\(entry.edgeSequence):\(String(describing: entry.ordinaryThrough))"
            }
            func recordClose(_ session: AgentTabSession, before: AgentRunQuietFacts, label: String) async throws -> W3CauseClose {
                let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(vm, tabID: session.tabID)
                let after = try XCTUnwrap(session.quietLedger.facts)
                let observed = await authority.observationSnapshot(forTargetEndpoint: endpoint)
                let envelope = try XCTUnwrap(observed)
                let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
                XCTAssertEqual(envelope.runFacts, after)
                XCTAssertEqual(envelope.snapshot.status, .idle)
                XCTAssertEqual(after.settledThrough, before.settledThrough + 1)
                let close = W3CauseClose(endpoint: endpoint, before: before, after: after, sourceSequence: envelope.sourcePublicationSequence, terminalCommit: revision.commitID, label: label)
                closes.append(close)
                print("W3_CAUSE_CLOSE variant=\(variant) first=\(firstKind.rawValue) source=\(endpoint.sessionID) provider=\(session.selectedAgent.rawValue) publication=\(close.sourceSequence) commit=\(close.terminalCommit) label=\(label) quiet=\(close.isQuiet) settled=\(after.settledThrough) ordinary=\(after.ordinaryThrough)")
                return close
            }
            func auditQueues(trigger: W3CauseClose?) throws {
                for peer in peers {
                    let observerID = try XCTUnwrap(peer.activeAgentSessionID)
                    let snapshot = try XCTUnwrap(vm.agentSessionLinkPassiveNoticesBySessionID[observerID])
                    for entry in snapshot.entries where entry.isRoutineWakeEligible {
                        let key = edgeKey(snapshot, entry)
                        if edgeCauses[key] != nil {
                            continue
                        }
                        let paid = paidCutoffs[entry.reference] ?? 0
                        let targetCloses = closes.filter { $0.endpoint == entry.targetEndpoint }
                        let latest = try XCTUnwrap(targetCloses.last, "No actual source close for eligible edge")
                        let cause: W3CauseClose
                        if latest.after.ordinaryThrough > paid {
                            XCTAssertEqual(entry.ordinaryThrough, latest.after.ordinaryThrough, "Attribute only coverage actually carried by the production queue")
                            cause = try XCTUnwrap(targetCloses.last { !$0.isQuiet && $0.after.ordinaryThrough == latest.after.ordinaryThrough }, "Unpaid coverage needs its actual ordinary producer")
                        } else {
                            cause = try XCTUnwrap(trigger, "No unpaid ordinary coverage and no isolated closing publication: cannot attribute")
                            guard cause.endpoint == entry.targetEndpoint, cause.isQuiet, entry.toStatus == .idle else {
                                XCTFail("No isolated quiet closing publication explains this new eligible edge")
                                throw DiscoveryFailure.overseeRefused
                            }
                        }
                        edgeCauses[key] = cause
                        print("W3_CAUSE_EDGE variant=\(variant) first=\(firstKind.rawValue) observer=\(observerID) target=\(entry.targetSessionID) link=\(entry.reference.linkID) generation=\(entry.reference.generation) queueEpoch=\(snapshot.queueEpoch) queueRevision=\(snapshot.queueRevision) edge=\(entry.edgeSequence) change=\(entry.changeSequence) from=\(entry.fromStatus) to=\(entry.toStatus) opening=\(String(describing: entry.openingSettledThrough)) cutoff=\(String(describing: entry.receiptSettledThrough)) paid=\(paid) ordinary=\(String(describing: entry.ordinaryThrough)) cause=\(cause.label) causePublicationWitness=\(cause.sourceSequence) causeCommit=\(cause.terminalCommit) quietCause=\(cause.isQuiet)")
                    }
                    if let pending = peer.oversight.pendingAutoWake, reservationCauses[pending.wakeID] == nil {
                        let edge = try XCTUnwrap(pending.wakeFingerprint?.edges.first)
                        let entry = try XCTUnwrap(snapshot.entries.first { $0.reference == edge.reference && $0.edgeSequence == edge.edgeSequence && $0.ordinaryThrough == edge.ordinaryThrough })
                        let cause = try XCTUnwrap(edgeCauses[edgeKey(snapshot, entry)], "New actual reservation needs an attributable eligible edge")
                        reservationCauses[pending.wakeID] = cause
                        print("W3_CAUSE_RESERVE variant=\(variant) first=\(firstKind.rawValue) observer=\(observerID) wake=\(pending.wakeID) link=\(entry.reference.linkID) edge=\(entry.edgeSequence) queueRevision=\(snapshot.queueRevision) cause=\(cause.label) causePublicationWitness=\(cause.sourceSequence) causeCommit=\(cause.terminalCommit) quietCause=\(cause.isQuiet)")
                    }
                }
            }
            let cleanup: @MainActor () async -> Void = {
                bridge.test_afterPassiveObservationSnapshot = nil
                bridge.test_onPassiveSample = nil
                frameGate?.release()
                await gatedRefresh?.value
                for session in peers {
                    session.oversight.autoWakeOnUpdates = false
                    session.oversight.pendingAutoWake?.task?.cancel()
                }
                if let reverseGrant {
                    await bridge.revokeLink(linkID: reverseGrant.linkID, generation: reverseGrant.generation)
                }
                await secondProvider.shutdown()
                if let secondConnection {
                    secondConnection.client.close()
                    await secondConnection.connectionManager.stop()
                    await manager.debugRemoveConnection(secondConnection.connectionID)
                }
                await manager.clearClientConnectionPolicy(for: secondClient, windowID: window.windowID, runID: secondRun)
                await manager.cleanupRunRoutingState(for: secondRun, windowID: window.windowID)
            }
            do {
                for session in peers {
                    session.runState = .completed
                    session.isPreparingInitialWorktree = true // Hold automatic preparation, not admission.
                    session.oversight.autoWakeOnUpdates = false
                    session.oversight.routineWakeIntervalEnabled = false
                }
                guard case .added = try await bridge.addMonitorLink(observerSessionID: XCTUnwrap(second.activeAgentSessionID), rawTargetSessionID: XCTUnwrap(first.activeAgentSessionID).uuidString) else {
                    throw DiscoveryFailure.overseeRefused
                }
                let links = try await authority.links(forObserver: XCTUnwrap(second.activeAgentSessionID))
                let reverse = try XCTUnwrap(links.items.first)
                reverseGrant = .init(linkID: reverse.linkID, generation: reverse.generation)
                await manager.installClientConnectionPolicy(
                    for: secondClient, windowID: window.windowID,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools, oneShot: true,
                    reason: "W3 assembled reciprocal fake route", ttl: 60, tabID: second.tabID,
                    runID: secondRun, additionalTools: nil, purpose: .agentModeRun,
                    taskLabelKind: nil, allowsAgentExternalControlTools: false
                )
                let connection = try await PersistentMCPTestEndpoint.make(
                    label: "w3-reciprocal-provider", networkManager: manager, clientName: secondClient,
                    requiredToolNames: [MCPWindowToolName.selfNoop]
                )
                secondConnection = connection
                await secondProvider.attach(connection)
                let connections = [firstConnection, connection]
                let providers = [firstProvider, secondProvider]
                for (index, session) in peers.enumerated() {
                    if session.selectedAgent == .claudeCode {
                        session.claudeController = providers[index]
                    }
                    let listed = try await providers[index].listTools()
                    XCTAssertTrue(listed.contains(MCPWindowToolName.selfNoop))
                }
                await bridge.test_settleProjections()
                await bridge.test_settleTargetPublications()
                for peer in peers {
                    XCTAssertEqual(peer.quietLedger.facts, .zero, "New exact grants baseline at live zero before any seed")
                    XCTAssertTrue(try XCTUnwrap(vm.agentSessionLinkPassiveNoticesBySessionID[XCTUnwrap(peer.activeAgentSessionID)]).entries.isEmpty)
                }
                bridge.test_onPassiveSample = { sample in
                    sampleCount += 1
                    print("W3_CAUSE_SAMPLE variant=\(variant) first=\(firstKind.rawValue) ordinal=\(sampleCount) link=\(sample.reference.linkID) target=\(sample.targetSessionID) status=\(sample.status) facts=\(String(describing: sample.runFacts))")
                }
                // Two ordinary seeds make both provider orders executable without injecting a
                // passive queue/facts value. Real registered calls are vetoed by leading text.
                for (index, session) in peers.enumerated() {
                    let before = try XCTUnwrap(session.quietLedger.facts)
                    session.runState = .running
                    try await w2RegisteredTerminal(
                        window: window, session: session, connection: connections[index],
                        runID: XCTUnwrap(session.runID), delayed: false, nativeResult: true,
                        closing: false, leading: true, cancel: false
                    )
                    await bridge.test_settleTargetPublications()
                    let seed = try await recordClose(session, before: before, label: "initial-ordinary-debt")
                    XCTAssertFalse(seed.isQuiet)
                    await bridge.test_refreshStatus(sessionIDs: ids)
                    try auditQueues(trigger: seed)
                }
                for session in peers {
                    session.oversight.autoWakeOnUpdates = true
                }
                await bridge.test_refreshStatus(sessionIDs: ids)
                try auditQueues(trigger: nil)
                var didOrdinaryControl = false
                // Bounded observation horizon, not an accepted-count or drain-length oracle.
                for step in 0 ..< 8 {
                    if peers.allSatisfy({ $0.oversight.pendingAutoWake == nil }) {
                        if didOrdinaryControl {
                            break
                        }
                        didOrdinaryControl = true
                        let before = try XCTUnwrap(first.quietLedger.facts)
                        first.runState = .running
                        try await w2RegisteredTerminal(
                            window: window, session: first, connection: firstConnection,
                            runID: XCTUnwrap(first.runID), delayed: false, nativeResult: true,
                            closing: false, leading: true, cancel: false
                        )
                        await bridge.test_settleTargetPublications()
                        let control = try await recordClose(first, before: before, label: "ordinary-close-control")
                        XCTAssertFalse(control.isQuiet)
                        await bridge.test_refreshStatus(sessionIDs: ids)
                        try auditQueues(trigger: control)
                        XCTAssertNotNil(second.oversight.pendingAutoWake, "A new ordinary close must still reserve the reciprocal observer")
                    }
                    let preferred = step % 2
                    let index = peers[preferred].oversight.pendingAutoWake != nil ? preferred : 1 - preferred
                    let session = peers[index]
                    guard let reserved = session.oversight.pendingAutoWake else { break }
                    reserved.task?.cancel()
                    session.isPreparingInitialWorktree = false
                    let claim = try XCTUnwrap(vm.agentSessionLinkPromptClaim(for: session, dispatchID: .autoWake(wakeID: reserved.wakeID)))
                    XCTAssertTrue(claim.routineQuietCheckIn, "Actual initially idle claim without attention")
                    XCTAssertNotNil(vm.agentSessionLinkPrepareAutoWakeDispatch(wakeID: reserved.wakeID, endpoint: reserved.observerEndpoint))
                    let snapshot = try XCTUnwrap(vm.agentSessionLinkPassiveNoticesBySessionID[XCTUnwrap(session.activeAgentSessionID)])
                    let edge = try XCTUnwrap(reserved.wakeFingerprint?.edges.first)
                    let entry = try XCTUnwrap(snapshot.entries.first { $0.reference == edge.reference && $0.edgeSequence == edge.edgeSequence && $0.ordinaryThrough == edge.ordinaryThrough })
                    XCTAssertTrue(entry.isRoutineWakeEligible)
                    let coverageCause = try XCTUnwrap(edgeCauses[edgeKey(snapshot, entry)], "Physical claim needs an attributed actual eligibility edge")
                    let cause = try XCTUnwrap(reservationCauses[reserved.wakeID], "Preserve the actual reservation's original cause even if newer debt hitchhikes")
                    let delivered = try XCTUnwrap(claim.passive?.receipt.deliveredStatuses.first { $0.reference == entry.reference && $0.targetEndpoint == entry.targetEndpoint })
                    XCTAssertEqual(delivered.changeSequence, entry.changeSequence)
                    let owner = session.beginRunAttempt(source: "W3.assembled-physical")
                    if session.selectedAgent == .claudeCode {
                        await providers[index].attach(connections[index])
                        session.claudeController = providers[index]
                        let binding = vm.providerBindingService
                        let preferences = binding.preferences
                        let runtime = ClaudeControllerLaunchPolicy.resolve(
                            permissionMode: binding.runtimePermission(for: session.selectedAgent, profile: session.permissionProfile).claudePermissionMode,
                            profile: session.permissionProfile, defaults: preferences.defaults, securePermissions: preferences.securePermissions
                        )
                        let permission = ClaudeAgentToolPreferences.resolvePermissionMode(
                            requestedMode: runtime.permissionMode ?? session.permissionProfile.claudePermissionMode,
                            agentKind: session.selectedAgent, selectedModelRaw: session.selectedModelRaw,
                            unsupportedAutoFallback: session.parentSessionID == nil ? .autoApproveEdits : .fullAccess
                        )
                        try vm.test_claudeCoordinator.test_setControllerLaunchSettings(.init(
                            runtimeVariant: session.selectedAgent.claudeRuntimeVariant ?? .standard,
                            workspacePath: vm.effectiveWorkspacePath(for: session),
                            permissionMode: permission.effectiveMode, allowNativeBashTool: runtime.allowNativeBashTool,
                            mcpStrictMode: runtime.mcpStrictMode
                        ), for: session)
                        session.runState = .running
                        XCTAssertTrue(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: claim.dispatchID))
                        let intent = try ClaudeAgentModeCoordinator.NativeSessionIntent.runAttempt(ownership: owner, runID: XCTUnwrap(session.runID))
                        let outcome = await vm.test_claudeCoordinator.sendClaudeNativeMessage(session: session, text: "", attachments: [], intent: intent, allowsCatalogRouteControllerRecovery: false)
                        guard outcome == .sent else {
                            XCTFail("W3 fixture Claude physical call refused: \(outcome)")
                            throw DiscoveryFailure.overseeRefused
                        }
                    } else {
                        let controller = MonitorFakeCodexController(dispatches: MonitorCodexDispatchRecorder())
                        codexControllers.append(controller)
                        controller.setStartOrResumeHook { _ = try? await providers[index].listTools() }
                        _ = try await controller.startOrResume(existing: nil, baseInstructions: "", model: nil, reasoningEffort: nil, serviceTier: nil)
                        session.codexController = controller
                        session.codexNeedsReconnect = false
                        session.codexConversationID = "monitor-thread"
                        session.codexControllerPermissionProfile = session.permissionProfile
                        session.codexControllerTaskLabelKind = session.mcpControlContext?.taskLabelKind
                        session.codexControllerWorkspacePaths = try vm.codexRuntimeWorkspacePaths(for: session)
                        session.codexControllerFeatureState = .init(
                            computerUseEnabled: false, goalSupportEnabled: CodexGoalSupport.isEnabled,
                            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled, memoriesEnabled: CodexMemories.isEnabled,
                            capabilities: vm.providerBindingService.codexCapabilitiesForLaunch(isMCPRelated: session.isMCPRelated)
                        )
                        let outcome = await vm.test_codexCoordinator.sendCodexNativeMessage(session: session, text: "", attachments: [])
                        guard outcome == .sent else {
                            XCTFail("W3 fixture Codex physical call refused: \(outcome)")
                            throw DiscoveryFailure.overseeRefused
                        }
                        XCTAssertEqual(controller.startedTurns.count + controller.steeredTurns.count, 1)
                    }
                    XCTAssertTrue(session.liveItemIDs.contains(reserved.wakeID), "Count only actual native acceptance and its captured claim marker")
                    XCTAssertNotNil(session.quietLedger.routineWakeID(owner: owner))
                    accepted.append(session.selectedAgent.rawValue)
                    if cause.isQuiet {
                        quietCausedAccepted += 1
                    } else if cause.label == "initial-ordinary-debt" {
                        seedCausedAccepted += 1
                    } else if cause.label == "ordinary-close-control" {
                        controlCausedAccepted += 1
                    } else if cause.label == "proven-reprompt" {
                        repromptCausedAccepted += 1
                    }
                    print("W3_CAUSE_ACCEPT variant=\(variant) first=\(firstKind.rawValue) step=\(step) observer=\(session.activeAgentSessionID!) provider=\(session.selectedAgent.rawValue) wake=\(reserved.wakeID) link=\(entry.reference.linkID) edge=\(entry.edgeSequence) queueEpoch=\(snapshot.queueEpoch) queueRevision=\(snapshot.queueRevision) receiptChange=\(delivered.changeSequence) receiptCutoff=\(String(describing: delivered.settledThrough)) cause=\(cause.label) causeSource=\(cause.endpoint.sessionID) causePublicationWitness=\(cause.sourceSequence) causeCommit=\(cause.terminalCommit) causeSettled=\(cause.after.settledThrough) causeOrdinary=\(cause.after.ordinaryThrough) quietCause=\(cause.isQuiet) coverageCause=\(coverageCause.label) coveragePublicationWitness=\(coverageCause.sourceSequence)")
                    for status in claim.passive?.receipt.deliveredStatuses ?? [] {
                        guard let cutoff = status.settledThrough else { continue }
                        paidCutoffs[status.reference] = max(paidCutoffs[status.reference] ?? 0, cutoff)
                        if let seed = closes.first(where: { $0.endpoint == status.targetEndpoint && $0.label == "initial-ordinary-debt" }), cutoff >= seed.after.ordinaryThrough {
                            seedDebtPaid.insert(status.reference)
                        }
                    }
                    session.isPreparingInitialWorktree = true
                    let targetEndpoint = try AgentSessionLinkEndpointTestSupport.endpoint(vm, tabID: session.tabID)
                    try await AsyncTestWait.waitUntil("W3 running pair accepted before delayed observer sample") {
                        await bridge.test_pairedRunStatus(for: targetEndpoint) == .running
                    }
                    await bridge.test_settleTargetPublications()
                    let openingObservation = await authority.observationSnapshot(forTargetEndpoint: targetEndpoint)
                    let opening = try XCTUnwrap(openingObservation)
                    let sourceBefore = try XCTUnwrap(session.quietLedger.facts)
                    XCTAssertEqual(opening.snapshot.status, .running)
                    XCTAssertEqual(opening.runFacts, sourceBefore)
                    // Capture an accepted opening pair, suspend its application, then accept the
                    // closing pair first. Existing serial refresh must consume both coherently.
                    let gate = TestReleaseFence(name: "W3 sampled opening pair held across terminal publication")
                    frameGate = gate
                    var armed = true
                    bridge.test_afterPassiveObservationSnapshot = { endpoint in
                        guard endpoint == targetEndpoint, armed else { return }
                        armed = false
                        await gate.enterAndWait()
                    }
                    let peerID = try XCTUnwrap(peers[1 - index].activeAgentSessionID)
                    gatedRefresh = Task { await bridge.test_refreshStatus(sessionIDs: [peerID]) }
                    guard await gate.waitUntilEntered() else { throw CancellationError() }
                    try await w2RegisteredTerminal(
                        window: window, session: session, connection: connections[index],
                        runID: XCTUnwrap(session.runID), delayed: true, nativeResult: true,
                        closing: session.selectedAgent == .claudeCode, leading: false, cancel: false,
                        w3Owner: owner, w3Reprompt: provenReprompt
                    )
                    try await AsyncTestWait.waitUntil("W3 closing pair accepted while older opening sample is held") {
                        let status = await bridge.test_pairedRunStatus(for: targetEndpoint)
                        let facts = await bridge.test_pairedRunFacts(for: targetEndpoint)
                        return status == .idle && facts == session.quietLedger.facts
                    }
                    let label = session.selectedAgent == .codexExec ? "silent-noop" : (provenReprompt ? "proven-reprompt" : "closing-text-noop")
                    let close = try await recordClose(session, before: sourceBefore, label: label)
                    XCTAssertGreaterThan(close.sourceSequence, opening.sourcePublicationSequence)
                    print("W3_CAUSE_PAIR variant=\(variant) first=\(firstKind.rawValue) step=\(step) target=\(targetEndpoint.sessionID) heldOpeningPublication=\(opening.sourcePublicationSequence) closingPublication=\(close.sourceSequence) heldOpeningFacts=\(String(describing: opening.runFacts)) closingFacts=\(close.after)")
                    bridge.test_afterPassiveObservationSnapshot = nil
                    gate.release()
                    await gatedRefresh?.value
                    gatedRefresh = nil
                    await bridge.test_settleTargetPublications()
                    await bridge.test_refreshStatus(sessionIDs: ids)
                    try auditQueues(trigger: close)
                    let owed = peers.map { peer in vm.agentSessionLinkPassiveNoticesBySessionID[peer.activeAgentSessionID!]?.entries.filter(\.isRoutineWakeEligible).count ?? 0 }
                    print("W3_CAUSE_STEP variant=\(variant) first=\(firstKind.rawValue) step=\(step) accepted=\(accepted) eligible=\(owed) pending=\(peers.map { $0.oversight.pendingAutoWake != nil })")
                }
                for _ in 0 ..< 4 {
                    await bridge.test_refreshStatus(sessionIDs: ids)
                }
                let pending = peers.count(where: { $0.oversight.pendingAutoWake != nil })
                let eligible = peers.reduce(0) { count, session in
                    count + (vm.agentSessionLinkPassiveNoticesBySessionID[session.activeAgentSessionID!]?.entries.filter(\.isRoutineWakeEligible).count ?? 0)
                }
                try auditQueues(trigger: nil)
                var quietCausedPending = 0
                for peer in peers where peer.oversight.pendingAutoWake != nil {
                    if let wakeID = peer.oversight.pendingAutoWake?.wakeID, reservationCauses[wakeID]?.isQuiet == true {
                        quietCausedPending += 1
                    }
                }
                print("W3_CAUSE_OUTCOME variant=\(variant) first=\(firstKind.rawValue) acceptedPhysical=\(accepted.count) sequence=\(accepted) quietCausedAccepted=\(quietCausedAccepted) quietCausedPending=\(quietCausedPending) seedCausedAccepted=\(seedCausedAccepted) seedDebtsPaid=\(seedDebtPaid.count) ordinaryControlCausedAccepted=\(controlCausedAccepted) repromptOrdinaryCausedAccepted=\(repromptCausedAccepted) samples=\(sampleCount) pending=\(pending) eligible=\(eligible)")
                XCTAssertEqual(quietCausedAccepted, 0, "No accepted reciprocal routine wake may be caused by a quiet close")
                XCTAssertEqual(quietCausedPending, 0, "No reciprocal reservation may be caused by a quiet close")
                XCTAssertEqual(repromptCausedAccepted, 0, "The exact otherwise-qualified harness frame creates no ordinary-coverage peer wake")
                XCTAssertEqual(seedDebtPaid.count, 2, "Initial ordinary debts are paid only through their actual frozen receipts")
                XCTAssertGreaterThanOrEqual(controlCausedAccepted, 1, "The isolated ordinary-close control must actually wake its reciprocal observer")
                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
        }

        func w2RoutineClaim(
            window: WindowState, session: AgentTabSession, endpoint: DomainAgentSessionLinkEndpointIdentity,
            localRead: Bool, ordinaryCandidate: Bool = false
        ) throws -> (AgentRunOwnership, AgentSessionLinkPromptDispatchID, AgentSessionLinkOutboundPromptClaim) {
            let vm = window.agentModeViewModel
            session.runState = .idle
            let inventory = try XCTUnwrap(vm.agentSessionLinkPromptInventoryBySessionID[endpoint.sessionID])
            let wake = UUID()
            let snapshot = AgentSessionLinkPassiveStatusNotices.Snapshot(observerEndpoint: endpoint, queueEpoch: UUID(), queueRevision: 1, linkSetRevision: inventory.inventory.linkSetRevision, isEnabled: true, isDeliverable: true, entries: [], unacknowledgedOverflowCount: 1, overflowProduced: 1)
            vm.agentSessionLinkPublishPassiveStatusNotices(snapshot, to: endpoint)
            session.oversight.pendingAutoWake = .init(wakeID: wake, observerEndpoint: endpoint, queueEpoch: snapshot.queueEpoch, queueRevision: 1, wakeFingerprint: nil, admissionBasis: .routineStatusOrOverflow, attemptedFingerprint: nil, physicalOutcome: .notAttempted, phase: .preparingDispatch, task: nil)
            if localRead {
                vm.test_agentSessionLinkLocalInputDecoration = { baseline in
                    .init(fragment: baseline.fragment + "\n<user_input>proof gate fixture</user_input>", markupDeltaBytes: 49, requirements: [])
                }
            }
            let dispatch = AgentSessionLinkPromptDispatchID.autoWake(wakeID: wake)
            let projection = vm.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint]
            if ordinaryCandidate {
                session.oversight.pendingAutoWake?.routineQuietCandidate = true
                vm.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint] = nil
            }
            let claim = try XCTUnwrap(vm.agentSessionLinkPromptClaimOutcome(for: session, dispatchID: dispatch).claim)
            vm.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint] = projection
            XCTAssertEqual(claim.routineQuietCheckIn, !ordinaryCandidate)
            XCTAssertEqual(claim.fragment.contains("Nothing needed? Call self_noop."), !ordinaryCandidate)
            let owner = session.beginRunAttempt(source: "W2.production-proof-fixture")
            session.quietLedger.markRoutineWake(owner: owner, wakeID: wake)
            if !ordinaryCandidate { session.oversight.pendingAutoWake?.phase = .dispatching }
            session.runState = .running
            return (owner, dispatch, claim)
        }

        func w2LateAttention(
            window: WindowState, session: AgentTabSession, target: AgentTabSession,
            endpoint: DomainAgentSessionLinkEndpointIdentity
        ) async throws {
            let vm = window.agentModeViewModel
            let (owner, dispatch, original) = try w2RoutineClaim(window: window, session: session, endpoint: endpoint, localRead: false)
            defer { session.oversight.pendingAutoWake = nil }
            let proof = await vm.agentSessionLinkProveProviderInput(for: session, claim: original)
            XCTAssertFalse(session.quietLedger.hasOrdinaryOccurrence(owner: owner))
            let previous = try XCTUnwrap(vm.agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID])
            let inventory = try XCTUnwrap(vm.agentSessionLinkPromptInventoryBySessionID[endpoint.sessionID])
            let item = try XCTUnwrap(inventory.inventory.items.first)
            let reference = try XCTUnwrap(item.reference)
            let targetEndpoint = try XCTUnwrap(vm.agentSessionLinkObserverEndpoint(tabID: target.tabID))
            let attention = AgentSessionLinkPassiveStatusNotices.PendingAttentionRequest(
                occurrence: .init(queueEpoch: previous.queueEpoch, reference: reference, attentionSequence: 1),
                targetEndpoint: targetEndpoint, targetSessionID: targetEndpoint.sessionID,
                requestedAt: .distantPast, status: .idle
            )
            vm.agentSessionLinkPublishPassiveStatusNotices(.init(
                observerEndpoint: endpoint, queueEpoch: previous.queueEpoch, queueRevision: previous.queueRevision + 1,
                linkSetRevision: previous.linkSetRevision, isEnabled: true, isDeliverable: true,
                entries: previous.entries, attentionRequests: [attention],
                unacknowledgedOverflowCount: previous.unacknowledgedOverflowCount, overflowProduced: previous.overflowProduced
            ), to: endpoint)
            let released = vm.agentSessionLinkHandoffProviderInput(for: session, dispatchID: dispatch, claim: original, proof: proof)
            XCTAssertFalse(released.mustAbortDispatch)
            XCTAssertFalse(try XCTUnwrap(released.claim).routineQuietCheckIn)
            XCTAssertEqual(released.claim?.passive?.receipt.deliveredAttentionOccurrences, [attention.occurrence])
            XCTAssertFalse(released.text("").contains("Nothing needed? Call self_noop."))
            XCTAssertTrue(session.quietLedger.hasOrdinaryOccurrence(owner: owner), "The actual attention-bearing release, not the earlier reservation, decides quiet qualification")
        }

        func w2CatalogProof(
            window: WindowState, session: AgentTabSession, provider: HeldDiscoveryProvider,
            endpoint: DomainAgentSessionLinkEndpointIdentity, route: AgentSessionLinkRunCatalogRouteToken,
            runID: UUID, withdraw: Bool, replaced: Bool, ordinaryCandidate: Bool
        ) async throws {
            let vm = window.agentModeViewModel
            let manager = ServerNetworkManager.shared
            let gate = TestReleaseFence(name: "production local-read proof before final catalog fence")
            let nativeBefore = await provider.heldTurnSnapshot
            let generation = session.codexControllerGeneration
            let repair = session.codexSessionLinkCatalogRepairCycle
            let (_, dispatch, original) = try w2RoutineClaim(window: window, session: session, endpoint: endpoint, localRead: true, ordinaryCandidate: ordinaryCandidate)
            let frozenProjection = try XCTUnwrap(vm.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint])
            vm.test_agentSessionLinkLocalInputReadProof = { _ in await gate.enterAndWait()
                return false
            }
            let proofTask = Task { await vm.agentSessionLinkProveProviderInput(for: session, claim: original) }
            var catalogTask: Task<Set<String>, Error>?
            func cleanup() async {
                gate.release()
                _ = await proofTask.value
                await manager.debugResumeRunCatalogPublicationBeforeMainActor()
                _ = await catalogTask?.result
                await manager.debugSetReturnedCatalogToolsForTesting(nil)
                vm.test_agentSessionLinkLocalInputDecoration = nil
                vm.test_agentSessionLinkLocalInputReadProof = nil
                session.oversight.pendingAutoWake = nil
            }
            do {
                guard await gate.waitUntilEntered() else { throw CancellationError() }
                if withdraw {
                    await manager.debugSetReturnedCatalogToolsForTesting(Self.w0fReturnedShape(copies: 0))
                    await manager.debugSuspendNextRunCatalogPublicationBeforeMainActor()
                    catalogTask = Task { try await provider.listTools() }
                    try await AsyncTestWait.waitUntil("server catalog withdrawn before MainActor publication") { await manager.debugIsRunCatalogPublicationBeforeMainActorSuspended() }
                    let latest = try await w0fProjection(manager, runID)
                    XCTAssertEqual(latest.routeToken, route)
                    XCTAssertFalse(latest.containsReturnedTool(Self.w0fTool()))
                    XCTAssertEqual(vm.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint], frozenProjection, "Mirror intentionally lags the authoritative observation")
                }
                if ordinaryCandidate {
                    XCTAssertTrue(session.oversight.pendingAutoWake?.routineQuietCandidate == true)
                    XCTAssertEqual(session.oversight.pendingAutoWake?.phase, .preparingDispatch)
                    XCTAssertTrue(vm.selfNoopHintIsCurrent(for: session))
                }
                if replaced {
                    if !ordinaryCandidate {
                        let previous = try XCTUnwrap(vm.agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID])
                        vm.agentSessionLinkPublishPassiveStatusNotices(.init(
                            observerEndpoint: endpoint, queueEpoch: previous.queueEpoch, queueRevision: previous.queueRevision + 1,
                            linkSetRevision: previous.linkSetRevision, isEnabled: true, isDeliverable: true,
                            entries: previous.entries, attentionRequests: previous.attentionRequests,
                            unacknowledgedOverflowCount: previous.unacknowledgedOverflowCount, overflowProduced: previous.overflowProduced
                        ), to: endpoint)
                    }
                    let successor = try XCTUnwrap(vm.agentSessionLinkPromptClaimOutcome(for: session, dispatchID: dispatch).claim)
                    XCTAssertTrue(successor.routineQuietCheckIn, "The mirror still advertises the withdrawn declaration")
                    XCTAssertNotEqual(successor, original)
                    XCTAssertFalse(vm.agentSessionLinkPromptClaimStore.isPending(original))
                }
                gate.release()
                let proof = await proofTask.value
                let released = vm.agentSessionLinkHandoffProviderInput(for: session, dispatchID: dispatch, claim: original, proof: proof)
                XCTAssertFalse(released.mustAbortDispatch, "Missing optional noop support never blocks ordinary delivery")
                let capturing = AgentSessionLinkCapturingHeadlessProvider()
                _ = try await capturing.streamAgentMessage(released.message(AgentMessage(systemPrompt: "fixture", userMessage: "routine")), runID: runID)
                let messages = await capturing.messages
                XCTAssertEqual(messages.count, 1)
                XCTAssertEqual(messages[0].userMessage.contains("Nothing needed? Call self_noop."), !withdraw)
                XCTAssertEqual(released.claim?.routineQuietCheckIn, !withdraw)
                if withdraw {
                    let stillHeld = await manager.debugIsRunCatalogPublicationBeforeMainActorSuspended()
                    XCTAssertTrue(stillHeld, "The send did not wait for mirror publication/repair")
                }
                let nativeAfter = await provider.heldTurnSnapshot
                XCTAssertEqual(nativeBefore, nativeAfter)
                XCTAssertEqual(session.codexControllerGeneration, generation)
                XCTAssertEqual(session.codexSessionLinkCatalogRepairCycle, repair)
                print("W2_PRODUCTION_HINT withdraw=\(withdraw) messages=\(messages.count) routine=\(released.claim?.routineQuietCheckIn == true)")
                await cleanup()
            } catch { await cleanup()
                throw error
            }
        }

        /// Debug dispatch-preparation budget, not an importer or end-to-end provider benchmark.
        /// Separately vary catalog bytes and unrelated history; fixture construction is untimed.
        func w2CatalogCost(
            window: WindowState, session: AgentTabSession, provider: HeldDiscoveryProvider,
            endpoint: DomainAgentSessionLinkEndpointIdentity, runID: UUID, inactiveTabID: UUID
        ) async throws {
            let manager = ServerNetworkManager.shared
            let vm = window.agentModeViewModel
            // Isolate dispatch preparation from unrelated active-transcript UI rebuilds. This is a
            // valid second tab in the same fixture window, not a rendering/importer benchmark.
            vm.test_setCurrentTabIDOverride(inactiveTabID)
            defer { vm.test_setCurrentTabIDOverride(nil) }
            let baseline = try await w0fProjection(manager, runID)
            let actualTools = try Array(XCTUnwrap(baseline.returnedCatalog).values.joined())
            let clock = ContinuousClock()
            func ms(_ duration: Duration) -> Double {
                Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            }
            func stats(_ values: [Double]) -> [String: Double] {
                let ordered = values.sorted()
                return ["median": (ordered[19] + ordered[20]) / 2, "p95": ordered[37], "max": ordered[39]]
            }
            let repairBefore = session.codexSessionLinkCatalogRepairCycle
            let generationBefore = session.codexControllerGeneration
            // Three comparisons, not a Cartesian matrix: catalog growth and history growth isolated.
            for (factor, historyCount) in [(1, 0), (10, 0), (1, 10000)] {
                if let owner = session.activeRunOwnership { _ = session.endRunAttempt(ifCurrent: owner, source: "W2.cost-fixture-reset") }
                session.oversight.pendingAutoWake = nil
                await manager.debugSetReturnedCatalogToolsForTesting { _, _ in
                    var expanded = actualTools
                    if factor > 1 {
                        for copyIndex in 1 ..< factor {
                            expanded += actualTools.map { tool in
                                MCP.Tool(name: "w2_cost_\(copyIndex)__\(tool.name)", description: tool.description, inputSchema: tool.inputSchema, annotations: tool.annotations)
                            }
                        }
                    }
                    return expanded
                }
                _ = try await provider.listTools()
                let projection = try await w0fProjection(manager, runID)
                let returned = try XCTUnwrap(projection.returnedCatalog)
                // Footprint encoding is evidence-only, outside all production-path timing.
                let catalog = try JSONEncoder().encode(Array(returned.values.joined()))
                let toolCount = returned.values.reduce(0) { $0 + $1.count }
                XCTAssertEqual(toolCount, actualTools.count * factor)
                session.setItemsSilently((0 ..< historyCount).map { .assistant("unrelated fixture history", sequenceIndex: $0) }, reason: .persistedSessionHydration)
                let (owner, dispatch, original) = try w2RoutineClaim(window: window, session: session, endpoint: endpoint, localRead: false)
                var claimMS: [Double] = [], proofMS: [Double] = [], handoffMS: [Double] = [], totalMS: [Double] = [], syncMS: [Double] = []
                let sourceRevision = session.sourceItemsRevision
                var rebuilds = 0, projectionBuilds = 0
                defer { AgentTranscriptDebugInstrumentation.reset() }
                for sample in 0 ..< 45 {
                    if sample == 5 {
                        AgentTranscriptDebugInstrumentation.configure(.init(rebuildHandler: { _ in rebuilds += 1 }, projectionBuildHandler: { _ in projectionBuilds += 1 }))
                    }
                    let start = clock.now
                    let outcome = vm.agentSessionLinkPromptClaimOutcome(for: session, dispatchID: dispatch)
                    let claimedAt = clock.now
                    let proof = await vm.agentSessionLinkProveProviderInput(for: session, claim: outcome.claim)
                    let provedAt = clock.now
                    let released = vm.agentSessionLinkHandoffProviderInput(for: session, dispatchID: dispatch, claim: outcome.claim, proof: proof)
                    let finished = clock.now
                    XCTAssertFalse(released.mustAbortDispatch)
                    XCTAssertEqual(released.claim, original)
                    XCTAssertTrue(released.fragment?.contains("Nothing needed? Call self_noop.") == true)
                    if sample >= 5 {
                        claimMS.append(ms(start.duration(to: claimedAt)))
                        proofMS.append(ms(claimedAt.duration(to: provedAt)))
                        handoffMS.append(ms(provedAt.duration(to: finished)))
                        totalMS.append(ms(start.duration(to: finished)))
                        syncMS.append(ms(start.duration(to: claimedAt)) + ms(provedAt.duration(to: finished)))
                    }
                }
                AgentTranscriptDebugInstrumentation.reset()
                XCTAssertEqual(rebuilds, 0, "Catalog proof/handoff must not rebuild transcript history")
                XCTAssertEqual(projectionBuilds, 0)
                XCTAssertEqual(session.sourceItemsRevision, sourceRevision)
                let total = stats(totalMS), synchronous = stats(syncMS)
                // Predeclared local Debug budgets: actual catalog total p95 < ~11% of W0's supplied
                // 466ms wake context; 10x stress bounded separately. Not new production limits.
                XCTAssertLessThanOrEqual(total["p95"]!, factor == 1 ? 50 : 250)
                XCTAssertLessThanOrEqual(synchronous["p95"]!, factor == 1 ? 25 : 125)
                XCTAssertLessThanOrEqual(total["max"]!, 1000)
                let record: [String: Any] = [
                    "catalog_factor": factor, "catalog_tools": toolCount, "catalog_bytes": catalog.count,
                    "unrelated_history_rows": historyCount, "observer_tab_active": false, "samples": 40, "warmups": 5,
                    "claim_ms": stats(claimMS), "proof_ms": stats(proofMS), "handoff_ms": stats(handoffMS),
                    "total_ms": total, "sync_claim_plus_handoff_ms": synchronous,
                    "full_decodes_per_positive_path_source_derived": 0,
                    "decoded_bytes_40_samples_source_derived": 0,
                    "exact_name_lookups_per_positive_path_source_derived": 4,
                    "observed_transcript_rebuilds": rebuilds, "observed_projection_builds": projectionBuilds,
                    "redundant_observation_encodes_per_tools_list_source_derived": 0,
                    "budget_total_p95_ms": factor == 1 ? 50 : 250,
                    "budget_sync_p95_ms": factor == 1 ? 25 : 125,
                    "budget_total_max_ms": 1000
                ]
                try print("W2_CATALOG_COST " + (JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])).base64EncodedString())
                vm.abandonAgentSessionLinkPromptClaim(original)
                _ = session.endRunAttempt(ifCurrent: owner, source: "W2.cost-fixture-end")
            }
            XCTAssertEqual(session.codexSessionLinkCatalogRepairCycle, repairBefore)
            XCTAssertEqual(session.codexControllerGeneration, generationBefore)
            await manager.debugSetReturnedCatalogToolsForTesting(nil)
            session.oversight.pendingAutoWake = nil
        }

        func w0fProjection(_ manager: ServerNetworkManager, _ runID: UUID) async throws -> AgentSessionLinkRunCatalogProjection {
            let projection = await manager.debugRunCatalogProjection(for: runID)
            return try XCTUnwrap(projection)
        }

        func w0fRepairControls(
            manager: ServerNetworkManager, provider: HeldDiscoveryProvider, window: WindowState,
            observer: AgentTabSession, endpoint: DomainAgentSessionLinkEndpointIdentity,
            route: AgentSessionLinkRunCatalogRouteToken, runID: UUID, kind: AgentProviderKind,
            codex: LifecycleNoopCodexController, codexRecorder: LifecycleRecorder
        ) async throws {
            let owner = observer.beginRunAttempt(source: "W0f.catalog-proof")
            let wireDefinitions = try await provider.definitions()
            let wireTools = try JSONDecoder().decode([MCP.Tool].self, from: JSONSerialization.data(withJSONObject: wireDefinitions))
            let positive = try await w0fProjection(manager, runID)
            XCTAssertEqual(positive.returnedCatalog, Dictionary(grouping: wireTools, by: \.name), "The single typed observation slot preserves every actual returned definition and duplicate")
            let nativeBefore = await provider.heldTurnSnapshot
            let codexBefore = codexRecorder.events
            let generation = observer.codexControllerGeneration
            XCTAssertEqual(positive.expectedSurface, positive.returnedSurface)
            XCTAssertTrue(positive.containsReturnedTool(Self.w0fTool()))
            let actualTools = try Array(XCTUnwrap(positive.returnedCatalog).values.joined())
            let actualDefinition = try XCTUnwrap(actualTools.first { $0.name == MCPWindowToolName.selfNoop })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let wireDefinition = try XCTUnwrap(wireTools.first { $0.name == MCPWindowToolName.selfNoop })
            XCTAssertEqual(actualDefinition, wireDefinition)
            let producedDefinition = try encoder.encode(wireDefinition)
            // The existing W0 fixture is the exact pinned fork trial definition. Use the same
            // real MCP.Tool encoder, without assuming empty-annotation wire behavior.
            let trialDefinition = try encoder.encode(Self.w0fTool())
            XCTAssertEqual(producedDefinition, trialDefinition)
            print("W2_TRIAL_DEFINITION " + trialDefinition.base64EncodedString())
            print("W2_ACTUAL_DEFINITION " + producedDefinition.base64EncodedString())

            /// W0-only consumer. No product hint, dispatch admission or terminal decision is wired.
            func hint(_ sample: AgentSessionLinkRunCatalogProjection, owner capturedOwner: AgentRunOwnership) async -> String? {
                guard let token = await manager.authoritativeRunCatalogRouteToken(runID: runID, windowID: window.windowID, tabID: endpoint.tabID) else { return nil }
                let supported = await manager.hasCurrentReturnedTool(Self.w0fTool(), routeToken: token, projectionRevision: sample.projectionRevision)
                guard supported, !Task.isCancelled, sample.routeToken == token,
                      ToolAvailabilityStore.shared.isEnabled(Self.w0fTool().name),
                      sample.hasActiveOutboundLink == true, observer.runID == runID,
                      observer.isCurrentRunAttemptForCurrentBinding(capturedOwner),
                      window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
                      window.agentModeViewModel.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint]?.projectionRevision == sample.projectionRevision,
                      manager.hasLiveProviderInputConnection(token)
                else { return nil }
                return "Nothing needed? Call self_noop."
            }
            func assertNoQuietRepair() {
                guard kind == .codexExec else { return }
                window.agentModeViewModel.test_codexCoordinator.codexRepairSessionLinkCatalogIfQuiescent(for: observer)
                XCTAssertNil(observer.codexSessionLinkCatalogRepairCycle)
                XCTAssertEqual(observer.codexControllerGeneration, generation)
                XCTAssertTrue(observer.codexController === codex)
                XCTAssertEqual(observer.runID, runID)
            }
            let supportedHint = await hint(positive, owner: owner)
            XCTAssertEqual(supportedHint, "Nothing needed? Call self_noop.")
            let acknowledgement = try await provider.callSelfNoop()
            let callObject = try MCPExportWatchdogIntegrationTests.responseObject(from: acknowledgement)
            let callResult = try XCTUnwrap(callObject["result"] as? [String: Any])
            XCTAssertNotEqual(callResult["isError"] as? Bool, true)
            let content = try XCTUnwrap(callResult["content"] as? [[String: Any]])
            try assertW2Acknowledgement(content)
            XCTAssertEqual(observer.quietLedger.declarationBodyEntryCardinality(owner: owner), 1, "The real registration packet reaches the current caller body")
            XCTAssertNil(observer.quietLedger.acceptedDeclarationInvocationID(owner: owner), "A non-routine advertised caller is acknowledged, not quiet")
            // The returned catalog is not permission to borrow another attempt or route.
            let successor = observer.beginRunAttempt(source: "W0f.catalog-proof.successor")
            let oldAttemptHint = await hint(positive, owner: owner)
            XCTAssertNil(oldAttemptHint)
            let foreign = AgentSessionLinkRunCatalogRouteToken(runID: runID, observerEndpoint: endpoint, connectionID: UUID(), routingAuthorityGeneration: route.routingAuthorityGeneration, connectionLifecycleGeneration: route.connectionLifecycleGeneration)
            let foreignSupport = await manager.hasCurrentReturnedTool(Self.w0fTool(), routeToken: foreign, projectionRevision: positive.projectionRevision)
            XCTAssertFalse(foreignSupport)

            // Equivalent absent/suppressed and ambiguous returned catalogs. The healthy idle Codex
            // controller must not even open a cycle; ordinary delivery remains available.
            if kind == .codexExec { observer.runState = .idle }
            for (label, copies, permissive) in [("absent/suppressed", 0, false), ("ambiguous", 2, false), ("non-exact schema", 1, true)] {
                await manager.debugSetReturnedCatalogToolsForTesting(Self.w0fReturnedShape(copies: copies, permissiveSchema: permissive))
                _ = try await provider.listTools()
                let current = try await w0fProjection(manager, runID)
                XCTAssertEqual(current.expectedSurface, positive.expectedSurface, label)
                XCTAssertEqual(current.returnedSurface, positive.returnedSurface, label)
                XCTAssertTrue(current.isReady, "Quiet support cannot gate ordinary delivery: \(label)")
                let delivery = await window.agentModeViewModel.qualifyProviderInputRoute(for: observer)
                XCTAssertEqual(delivery, .ready(route), "Ordinary route qualification never waits on quiet support")
                let absentHint = await hint(current, owner: successor)
                let staleHint = await hint(positive, owner: successor)
                XCTAssertNil(absentHint, label)
                XCTAssertNil(staleHint, "A prior positive catalog revision is not current")
                assertNoQuietRepair()
            }

            // Real global disable is confined to the test runner's disposable sandbox. It must
            // veto retained positive evidence even before tools/list has refreshed.
            observer.runState = .running
            await manager.debugSetReturnedCatalogToolsForTesting(Self.w0fReturnedShape())
            _ = try await provider.listTools()
            let beforeDisable = try await w0fProjection(manager, runID)
            await manager.setEnabled(false)
            let disabledHint = await hint(beforeDisable, owner: successor)
            XCTAssertNil(disabledHint)
            _ = try await provider.listTools()
            let disabled = try await w0fProjection(manager, runID)
            XCTAssertFalse(disabled.containsReturnedTool(Self.w0fTool()))
            await manager.setEnabled(true)
            _ = try await provider.listTools()
            let restored = try await w0fProjection(manager, runID)
            let restoredHint = await hint(restored, owner: successor)
            XCTAssertEqual(restoredHint, "Nothing needed? Call self_noop.")
            let nativeAfter = await provider.heldTurnSnapshot
            XCTAssertEqual(nativeAfter, nativeBefore)
            XCTAssertEqual(codexRecorder.events, codexBefore)
            if kind == .codexExec {
                observer.runState = .idle
                assertNoQuietRepair()
                // One deterministic overlap proves the new payload cannot revive an older
                // positive response after a newer same-run catalog publication.
                let gate = DiscoveryCatalogGate()
                let paused = expectation(description: "older catalog completion suspended")
                await manager.debugSetAfterExpectedCatalogSurfaceForTesting { await gate.hold { paused.fulfill() } }
                let older = Task { try await provider.listTools() }
                await fulfillment(of: [paused], timeout: 2)
                await manager.debugSetAfterExpectedCatalogSurfaceForTesting(nil)
                do {
                    await manager.debugSetReturnedCatalogToolsForTesting(Self.w0fReturnedShape(copies: 0))
                    _ = try await provider.listTools()
                    await gate.release()
                    _ = try await older.value
                } catch {
                    await gate.release()
                    _ = await older.result
                    throw error
                }
                let latest = try await w0fProjection(manager, runID)
                XCTAssertNil(latest.returnedCatalog, "Overlapping older completion is unknown, never positive support")
                let overlappedHint = await hint(latest, owner: successor)
                XCTAssertNil(overlappedHint)
                assertNoQuietRepair()
            }
        }
    }
#endif
