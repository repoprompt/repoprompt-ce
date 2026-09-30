import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Exercises Stop through the run-service terminal barrier and Claude attempt-lease cleanup.
/// A committed route is deliberately available to preserve: the Stop path must detach the
/// controller before the cancelled attempt decides whether its route can be reused.
@MainActor
final class AgentSessionLinkStopRouteCleanupTests: XCTestCase {
    private var retainedFixtures: [(AgentModeViewModel, WorkspaceManagerViewModel)] = []

    override func tearDown() {
        retainedFixtures.removeAll()
        super.tearDown()
    }

    func testOverseerStopRevokesReusedProcessRouteWithoutTouchingUnrelatedPolicy() async throws {
        let tabID = UUID()
        let files = WorkspaceFilesViewModel()
        let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let api = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keys),
            keyManager: keys, loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: files, apiSettingsViewModel: api, windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: files, promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Stop route target", repoPaths: [], ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)], activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        let viewModel = AgentModeViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(),
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retainedFixtures.append((viewModel, manager))
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { _, _, _ in
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        }
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        let candidate = try XCTUnwrap(viewModel.agentSessionLinkCandidate(
            tabID: tabID, sessionID: sessionID, tabName: "Stop route target", isWindowClosing: false
        ))

        let stoppedRunID = UUID()
        let unrelatedRunID = UUID()
        let routes = StopRoutePolicyStore()
        await routes.installUnrelated(unrelatedRunID)
        session.runState = .running
        session.installRunID(stoppedRunID)
        let ownership = session.beginRunAttempt(source: "stop-route-reuse")
        session.claudeController = MonitorFakeNativeController()
        let lease = MCPBootstrapLease(
            spec: MCPBootstrapLeaseSpec(
                runID: stoppedRunID, gateID: UUID(), windowID: 1, tabID: tabID,
                clientName: "RepoPromptCE", restrictedTools: [], additionalTools: nil,
                oneShot: true, reason: "stop-route-reuse", ttl: 60,
                purpose: .agentModeRun, taskLabelKind: nil,
                allowsAgentExternalControlTools: false, requiresExpectedAgentPID: true
            ),
            policyInstaller: { spec in await routes.install(spec.runID) },
            expectedPIDPolicyArmer: { _ in true },
            policyClearer: { spec in await routes.revoke(spec.runID) },
            routeAuthorityResolver: { spec in await routes.committedRoute(for: spec.runID) }
        )
        let acquired = await lease.acquire()
        let routeInitiallyInstalled = await routes.contains(stoppedRunID)
        XCTAssertTrue(acquired)
        XCTAssertTrue(routeInitiallyInstalled)
        session.installRunAttemptTerminalResources(ownership: ownership) { _ in
            {
                await ClaudeIntegratedAgentModeRunner.cancelAttemptLease(
                    lease, session: session, runID: stoppedRunID
                )
            }
        }
        let observer = DomainAgentSessionLinkEndpointIdentity(
            windowID: 2, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(),
            persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
        )
        let outcome = await viewModel.agentSessionLinkPerformStop(
            to: candidate,
            request: AgentSessionLinkStopRequest(
                requestID: UUID(), linkID: UUID(), linkGeneration: 1,
                observerEndpoint: observer, observerDisplayName: "Overseer"
            ),
            liveness: { AgentSessionLinkSendLiveness(
                observerEndpointIsLive: true, targetEndpointIsLive: true,
                targetWindowIsClosing: false
            ) },
            queueHasCommittedDrain: { false },
            withdrawInbound: { true },
            commitAuthorization: { .committed },
            teardownDeadlineSeconds: 1,
            auditDeadlineSeconds: 1
        )
        guard case let .settled(receipt) = outcome else { return XCTFail("expected Stop receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertEqual(receipt.teardownCompleted, true)
        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertNil(session.claudeController, "Stop detaches the reused controller before attempt cleanup")
        let stoppedRouteRemains = await routes.hasRoute(stoppedRunID)
        let stoppedPolicyRemains = await routes.hasPolicy(stoppedRunID)
        let unrelatedRouteRemains = await routes.hasRoute(unrelatedRunID)
        let unrelatedPolicyRemains = await routes.hasPolicy(unrelatedRunID)
        let preservationChecks = await routes.preservationChecks
        let revocations = await routes.revocations
        XCTAssertFalse(stoppedRouteRemains, "stopped route must be gone")
        XCTAssertFalse(stoppedPolicyRemains, "stopped lease policy must be gone")
        XCTAssertTrue(unrelatedRouteRemains, "unrelated route remains")
        XCTAssertTrue(unrelatedPolicyRemains, "unrelated policy remains")
        XCTAssertEqual(preservationChecks, 0, "Stop must not enter preserved-route lookup")
        XCTAssertEqual(revocations, [stoppedRunID])
    }
}

private actor StopRoutePolicyStore {
    private var routes: Set<UUID> = []
    private var policies: Set<UUID> = []
    private(set) var preservationChecks = 0
    private(set) var revocations: [UUID] = []

    func installUnrelated(_ runID: UUID) {
        routes.insert(runID)
        policies.insert(runID)
    }

    func install(_ runID: UUID) {
        routes.insert(runID)
        policies.insert(runID)
    }

    func revoke(_ runID: UUID) {
        routes.remove(runID)
        policies.remove(runID)
        revocations.append(runID)
    }

    func committedRoute(for runID: UUID) -> MCPRunRouteAuthorityDecision {
        preservationChecks += 1
        return routes.contains(runID) ? .committed : .revocationFenced
    }

    func contains(_ runID: UUID) -> Bool {
        routes.contains(runID) && policies.contains(runID)
    }

    func hasRoute(_ runID: UUID) -> Bool {
        routes.contains(runID)
    }

    func hasPolicy(_ runID: UUID) -> Bool {
        policies.contains(runID)
    }
}
