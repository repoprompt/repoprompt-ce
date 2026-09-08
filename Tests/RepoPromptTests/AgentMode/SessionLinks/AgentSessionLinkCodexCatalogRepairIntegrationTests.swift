import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

/// Covers the production server path that turns a restored outbound grant into the false/true
/// projection consumed by the Codex catalog repair.
@MainActor
final class AgentSessionLinkCodexCatalogRepairIntegrationTests: XCTestCase {
    private let clientName = AgentProviderKind.openCodeMCPClientID

    func testRestoredOutboundGrantInvalidationRepairsCodexCatalogThroughServerProjection() async throws {
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
            session.installRunID(runID)
            session.codexConversationID = conversationID
            session.codexRolloutPath = rolloutPath
            session.codexController = controller
            _ = try XCTUnwrap(window.agentModeViewModel.test_ensureSessionBoundToTab(session))
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                window.agentModeViewModel,
                tabID: tabID
            )
            await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: [], outbound: [])
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
            XCTAssertFalse(names.contains(MCPWindowToolName.agentSessionLink))
            let unlinkedProjection = await manager.debugRunCatalogProjection(for: runID)
            let unlinked = try XCTUnwrap(unlinkedProjection)
            XCTAssertEqual(unlinked.hasAgentSessionLink, false)
            XCTAssertEqual(unlinked.hasActiveOutboundLink, false)
            XCTAssertNil(session.codexSessionLinkCatalogRepairSourceGeneration)
            XCTAssertNotNil(session.codexController)

            let sessionID = try XCTUnwrap(session.activeAgentSessionID)
            let sourceGeneration = session.codexControllerGeneration
            await manager.debugSetSessionLinkCatalogEndpointsForTesting(
                anyActive: [endpoint],
                outbound: [endpoint]
            )
            await manager.notifyToolListChangedForAgentSession(sessionID)

            let stuckProjection = await manager.debugRunCatalogProjection(for: runID)
            let stuck = try XCTUnwrap(stuckProjection)
            XCTAssertEqual(stuck.hasAgentSessionLink, false)
            XCTAssertEqual(stuck.hasActiveOutboundLink, true)
            XCTAssertEqual(stuck.routeToken?.observerEndpoint, endpoint)
            XCTAssertFalse(stuck.isReady)
            XCTAssertNil(session.runID, "the stale process run is retired so cold bootstrap applies")
            XCTAssertNil(session.codexController, "exactly one controller replacement")
            XCTAssertEqual(session.codexConversationID, conversationID)
            XCTAssertEqual(session.codexRolloutPath, rolloutPath)
            XCTAssertEqual(session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)
            XCTAssertNotEqual(sourceGeneration, session.codexControllerGeneration)
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
        func abortForExecutionWatchdog() async {}
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
