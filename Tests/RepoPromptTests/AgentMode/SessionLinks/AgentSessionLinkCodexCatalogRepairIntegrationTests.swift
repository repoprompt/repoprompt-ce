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

    private enum SurfaceTransition { case activation, upgrade }

    private func assertRestoredGrantRepairsCatalog(outbound: Bool, surfaceTransition: SurfaceTransition? = nil) async throws {
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
            _ = try XCTUnwrap(window.agentModeViewModel.test_ensureSessionBoundToTab(session))
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                window.agentModeViewModel,
                tabID: tabID
            )
            await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: surfaceTransition == .upgrade ? [endpoint] : [], outbound: [])
            if surfaceTransition != nil { session.runState = .running }
            await installAuthoritativePolicy(
                manager: manager,
                runID: runID,
                tabID: tabID,
                windowID: window.windowID
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
            let sourceGeneration = session.codexControllerGeneration
            if surfaceTransition == .activation {
                let state = try XCTUnwrap(window.agentModeViewModel.agentSessionLinkBootstrapState(for: endpoint))
                XCTAssertTrue(window.agentModeViewModel.agentSessionLinkActivateOverseer(for: endpoint, expected: state))
            } else {
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: [endpoint], outbound: outbound ? [endpoint] : [])
            }
            await manager.notifyToolListChangedForAgentSession(sessionID)

            let stuckProjection = await manager.debugRunCatalogProjection(for: runID)
            let stuck = try XCTUnwrap(stuckProjection)
            XCTAssertEqual(stuck.hasAgentSessionLink, surfaceTransition == .upgrade)
            if surfaceTransition != nil {
                XCTAssertNotEqual(stuck.expectedSurface, stuck.returnedSurface)
                XCTAssertEqual(stuck.returnedSurface, unlinked.returnedSurface)
                XCTAssertNotNil(session.codexController, "Busy provider is not replaced")
                XCTAssertEqual(session.runID, runID)
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
                XCTAssertTrue(nextNames.contains(MCPWindowToolName.agentSessionLink))
                XCTAssertFalse(nextNames.contains(MCPWindowToolName.becomeOverseer))
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
            windowID: Int
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
                allowsAgentExternalControlTools: false,
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
        func notifyToolListChanged() async {}
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
            proofMutation: ProofMutation? = nil
        ) async throws {
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let manager = ServerNetworkManager.shared
            let window = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
            WindowStatesManager.shared.registerWindowState(window)
            WindowStatesManager.shared.attachAgentSessionLinkBridge()
            let bridge = AgentSessionLinkRuntimeBridge.shared
            let authority = AppDomainRuntimeComposition.shared.runtime.agentSessionLinkAuthority
            let provider = HeldDiscoveryProvider()
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
                await manager.clearClientConnectionPolicy(for: AgentProviderKind.claudeMCPClientID, windowID: window.windowID, runID: runID)
                await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                await window.tearDown()
                await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            do {
                await window.workspaceManager.awaitInitialized()
                let observerTab = UUID()
                let targetTab = UUID()
                var workspace = WorkspaceModel(name: "Live discovery", repoPaths: [])
                workspace.isEphemeral = true
                workspace.composeTabs = [
                    ComposeTabState(id: observerTab, name: "User-created planning chat"),
                    ComposeTabState(id: targetTab, name: "Harmless idle target")
                ]
                workspace.activeComposeTabID = observerTab
                window.workspaceManager.workspaces.append(workspace)
                let switched = await window.workspaceManager.switchWorkspace(to: workspace, saveState: false)
                XCTAssertTrue(switched.didSwitch)
                window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
                let vm = window.agentModeViewModel
                vm.test_setAgentSessionSaver { _, _, _ in
                    FileManager.default.temporaryDirectory.appendingPathComponent("discovery-\(UUID()).json")
                }
                let observer = vm.session(for: observerTab)
                let target = vm.session(for: targetTab)
                for session in [observer, target] {
                    session.selectedAgent = .claudeCode
                    session.hasLoadedPersistedState = true
                    session.oversight.autoWakeOnUpdates = false
                    _ = try XCTUnwrap(vm.test_ensureSessionBoundToTab(session))
                }
                let observerID = try XCTUnwrap(observer.activeAgentSessionID)
                let targetID = try XCTUnwrap(target.activeAgentSessionID)
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
                observer.claudeController = provider
                observer.runState = .running
                // Install the ordinary restricted Agent policy BEFORE initialize/tools/list. This
                // transport is never an external unrestricted caller that is converted after the fact.
                await manager.installClientConnectionPolicy(
                    for: AgentProviderKind.claudeMCPClientID, windowID: window.windowID,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools, oneShot: true,
                    reason: "Live Oversee discovery regression", ttl: 60, tabID: observerTab,
                    runID: runID, additionalTools: nil, purpose: .agentModeRun,
                    taskLabelKind: nil, allowsAgentExternalControlTools: false
                )
                await manager.setEnabled(true)
                let connection = try await PersistentMCPTestEndpoint.make(
                    label: "held-provider", networkManager: manager,
                    clientName: AgentProviderKind.claudeMCPClientID, requiredToolNames: [MCPWindowToolName.readFile]
                )
                transport = connection
                await provider.attach(connection)
                let turnID = try await provider.sendUserMessage("Hold this synthetic turn until the test releases it.")
                let before = try await provider.listTools()
                XCTAssertEqual(before.contains(MCPWindowToolName.agentSessionLink), inbound)
                XCTAssertEqual(before.contains(MCPWindowToolName.becomeOverseer), !inbound)
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
                            XCTAssertFalse(tools.contains(MCPWindowToolName.becomeOverseer))
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
                        paused.fulfill()
                        await catalogGate.hold()
                    }
                    delayedCatalog = Task { try await provider.listTools() }
                    await fulfillment(of: [paused], timeout: 2)
                    await manager.debugSetAfterExpectedCatalogSurfaceForTesting(nil)
                }
                // Two seconds is deliberately generous for local in-process socket I/O, but detects
                // delayed delivery or a turn-boundary refresh. No sleeps, polling, or provider inference.
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
                    let inventory = await authority.links(forObserver: observerID)
                    expectedTargetID = try XCTUnwrap(inventory.items.first?.targetSessionID)
                    XCTAssertNil(observer.oversight.overseerActivation, "Inbound creation needs no bootstrap")
                }
                let inventory = await authority.links(forObserver: observerID)
                let item = inventory.items.first { $0.targetSessionID == expectedTargetID }
                if let item, !inbound { grant = DomainAgentSessionLinkReference(linkID: item.linkID, generation: item.generation) }
                if activate {
                    await catalogGate.release()
                    let stale = try await XCTUnwrap(delayedCatalog).value
                    XCTAssertTrue(stale.contains(MCPWindowToolName.becomeOverseer))
                    XCTAssertFalse(stale.contains(MCPWindowToolName.agentSessionLink))
                    let observed = await manager.debugRunCatalogProjection(for: runID)
                    let projection = try XCTUnwrap(observed)
                    XCTAssertNotEqual(projection.expectedSurface, projection.returnedSurface, "A late bootstrap completion must preserve newer full expectations")
                    XCTAssertTrue(AgentSessionLinkCodexCatalogRepair.isStuckProjection(projection))
                }
                await fulfillment(of: [received], timeout: 2)
                XCTAssertFalse(frames.snapshot.isEmpty)
                let after = try await provider.listTools()
                let visibleElapsed = start.duration(to: clock.now)
                XCTAssertTrue(after.contains(MCPWindowToolName.agentSessionLink))
                XCTAssertFalse(after.contains(MCPWindowToolName.becomeOverseer))
                let afterDefinitions = try await provider.definitions(wireCaptureName: inbound ? "inbound-after" : (activate ? "activation-after" : "grant-after"))
                try DiscoveryArtifactCapture.write(afterDefinitions, name: inbound ? "inbound-after" : (activate ? "activation-after" : "grant-after"))
                let full = try XCTUnwrap(afterDefinitions.first { $0["name"] as? String == MCPWindowToolName.agentSessionLink })
                XCTAssertGreaterThan(DiscoveryArtifactCapture.operations(full).count, 3)
                XCTAssertLessThan(visibleElapsed, .seconds(2))
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
                    XCTAssertFalse(restored.contains(MCPWindowToolName.becomeOverseer))
                }
                let response = try await provider.listLinks()
                let object = try MCPExportWatchdogIntegrationTests.responseObject(from: response)
                let result = try XCTUnwrap(object["result"] as? [String: Any])
                XCTAssertEqual(result["isError"] as? Bool == true, activate, response.rawJSON)
                let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                let text = content.compactMap { $0["text"] as? String }.joined()
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
                let activeTurn = await provider.activeTurnID
                XCTAssertEqual(activeTurn, turnID, "No completion, restart, or controller replacement during discovery")
                XCTAssertNil(observer.parentSessionID)
                XCTAssertFalse(observer.isMCPOriginated)
                XCTAssertNil(observer.mcpControlContext)
                XCTAssertFalse(vm.isMCPControlled(tabID: observerTab))
                print("LIVE_OVERSEE_DISCOVERY link_to_visible=\(visibleElapsed) budget=2s connection=\(connection.connectionID) turn=\(turnID) notification=\(frames.snapshot)")
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
        func hold() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
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
        private var connection: PersistentMCPTestEndpoint?
        private(set) var activeTurnID: UUID?
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

        func ensureEventsStreamReady() {}
        func resetEventsStreamForNewRun() {}
        func startOrResume(existingSessionID _: String?, model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?, systemPromptOverride _: String?) async throws -> NativeAgentRuntimeSessionRef {
            currentSessionRef()
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

        func sendUserMessage(_: String) async throws -> UUID {
            let id = UUID()
            activeTurnID = id
            return id
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

        func listLinks() async throws -> PersistentMCPTestRPCResponse {
            try await XCTUnwrap(connection).callTool(name: MCPWindowToolName.agentSessionLink, arguments: ["op": "list", "_rawJSON": true], timeoutSeconds: 2)
        }

        func interruptTurn(reason _: String) -> NativeAgentRuntimeInterruptOutcome {
            .noTurnInFlight
        }

        func shutdown() {
            activeTurnID = nil
            connection = nil
            eventPair.continuation.finish()
        }

        func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) {}
    }
#endif
