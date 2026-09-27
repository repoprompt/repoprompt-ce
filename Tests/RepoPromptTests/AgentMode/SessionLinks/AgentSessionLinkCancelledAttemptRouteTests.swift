import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

/// A cancelled agent-mode attempt that reused a live run must not tear down that run's route.
///
/// Reproduces an observed overnight Auto-wake miss: a routine Auto-wake on an
/// established Claude observer reused its process run, installed a fresh run policy, re-listed its
/// catalog, and was then retracted before the provider call. The lease's cancellation cleanup revoked
/// the run through `cleanupRunRoutingState`, publishing an `unknown/unknown` catalog and unmapping the
/// still-open connection, after which every automatic wake path failed closed until a user send.
///
/// The Claude runner opts into preservation only while the session still owns that reused run
/// (`ClaudeIntegratedAgentModeRunner.cancellationPreservesRunRoute`); every other cancellation revokes.
///
/// Every suite here drives the production server path (`ServerNetworkManager` with a registered
/// window, a real pending-policy application, and a real `tools/list`) with a lease whose hooks are
/// the production defaults bound to this manager instance.
@MainActor
final class AgentSessionLinkCancelledAttemptRouteTests: XCTestCase {
    private let clientName = AgentProviderKind.openCodeMCPClientID

    // MARK: - Connection-manager level

    func testCancelledReusedRunAttemptAfterRelistKeepsCommittedRouteAndReadyCatalog() async throws {
        #if DEBUG
            let observer = try await makeRoutedObserver()
            try await assertRouteAndCatalogReady(observer, "baseline")

            let lease = makeAttemptLease(observer)
            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)
            // The attempt's readiness wait re-lists on the reused connection (rev 180 in the incident).
            _ = try await observer.manager.debugListToolNames(for: observer.connectionID)
            try await assertRouteAndCatalogReady(observer, "after the attempt's relist")

            // Retracted before the provider call: the runner finalizes `.superseded` as `.cancelled`.
            await lease.cancelAndCleanup(preservingCommittedRoute: true)

            try await assertRouteAndCatalogReady(observer, "after the cancelled attempt")
            let decision = await observer.manager.confirmCommittedRunRouteOrFenceRevocation(
                runID: observer.runID,
                windowID: observer.window.windowID,
                tabID: observer.tabID
            )
            XCTAssertEqual(decision, .committed)
        #else
            throw XCTSkip("Requires DEBUG MCP routing fixtures.")
        #endif
    }

    func testCancelledReusedRunAttemptBeforeRelistKeepsRouteAndNextRelistIsReady() async throws {
        #if DEBUG
            let observer = try await makeRoutedObserver()
            let lease = makeAttemptLease(observer)
            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)

            // Cancelled after the policy install bumped the routing generation but before any relist.
            await lease.cancelAndCleanup(preservingCommittedRoute: true)

            let token = await observer.manager.authoritativeRunCatalogRouteToken(
                runID: observer.runID,
                windowID: observer.window.windowID,
                tabID: observer.tabID
            )
            XCTAssertNotNil(token, "the live route survives a cancelled attempt")
            XCTAssertNotNil(
                window(observer).agentSessionLinkPromptContext(for: observer.session),
                "the observer's prompt gate stays open on the still-mapped connection"
            )
            _ = try await observer.manager.debugListToolNames(for: observer.connectionID)
            try await assertRouteAndCatalogReady(observer, "after the next relist")
        #else
            throw XCTSkip("Requires DEBUG MCP routing fixtures.")
        #endif
    }

    // MARK: - Whole wake flow

    func testLaterAutoWakeAndIdleWakeStillScheduleAfterCancelledReusedRunAttempt() async throws {
        #if DEBUG
            let observer = try await makeRoutedObserver()
            let viewModel = window(observer)
            let session = observer.session
            viewModel.agentSessionLinkPeriodicObserverIsLive = { _ in true }
            let clock = AgentSessionLinkAutoWakeSnoozeTestClock()
            session.oversight.snoozeClock = clock.clock
            addTeardownBlock { @MainActor in
                session.oversight.retirePeriodicScheduling()
                session.oversight.pendingAutoWake?.task?.cancel()
            }

            let lease = makeAttemptLease(observer)
            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)
            _ = try await observer.manager.debugListToolNames(for: observer.connectionID)
            await lease.cancelAndCleanup(preservingCommittedRoute: true)

            // The idle-wake timer arms for an idle observer.
            session.runState = .idle
            session.oversight.periodicIdleWakeEnabled = true
            session.oversight.periodicIdleWakeIntervalSeconds = 21600
            XCTAssertNotNil(viewModel.agentSessionLinkPromptContext(for: session), "prompt gate")
            XCTAssertTrue(
                AgentModeViewModel.agentSessionLinkPeriodicWakeSessionIsIdle(session),
                "idle: \(AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(session: session, endpointMatchesGrant: true, isClosing: false))"
            )
            XCTAssertTrue(viewModel.agentSessionLinkPeriodicWakeIsEligible(session, endpoint: observer.endpoint), "periodic eligibility")
            viewModel.agentSessionLinkReconcilePeriodicWake(for: observer.endpoint)
            XCTAssertNotNil(
                session.oversight.periodicDeadline,
                "the periodic idle wake must still arm after a cancelled reused-run attempt"
            )

            // A later routine status edge still admits an Auto-wake. The observer is held busy and the
            // reservation is retracted synchronously, so no provider is ever launched.
            session.oversight.periodicIdleWakeEnabled = false
            session.oversight.autoWakeOnUpdates = true
            session.runState = .running
            viewModel.agentSessionLinkPublishPassiveStatusNotices(
                laneSnapshot(observerEndpoint: observer.endpoint),
                to: observer.endpoint
            )
            let reserved = session.oversight.pendingAutoWake
            reserved?.task?.cancel()
            XCTAssertNotNil(reserved, "a later routine lane edge must still reserve an Auto-wake")
            XCTAssertNotEqual(reserved?.phase, .cancelledBeforeDispatch)
            XCTAssertEqual(reserved?.admissionBasis, .routineStatusOrOverflow)
            if let reserved {
                viewModel.cancelAgentSessionLinkAutoWake(for: reserved.observerEndpoint, reason: .settingDisabled)
            }
        #else
            throw XCTSkip("Requires DEBUG MCP routing fixtures.")
        #endif
    }

    // MARK: - Unchanged full cleanup

    func testEndOfScopeCleanupStillRemovesAPreservedRoute() async throws {
        #if DEBUG
            let observer = try await makeRoutedObserver()
            let lease = makeAttemptLease(observer)
            _ = await lease.acquire()
            await lease.cancelAndCleanup(preservingCommittedRoute: true)
            try await assertRouteAndCatalogReady(observer, "preserved by the cancelled attempt")

            // Tab close.
            await observer.manager.cleanupRunRoutingState(forTabID: observer.tabID, windowID: observer.window.windowID)
            await assertRouteRevoked(observer, "tab close")
        #else
            throw XCTSkip("Requires DEBUG MCP routing fixtures.")
        #endif
    }

    func testSessionDeletionCleanupStillRemovesAPreservedRoute() async throws {
        #if DEBUG
            let observer = try await makeRoutedObserver()
            let lease = makeAttemptLease(observer)
            _ = await lease.acquire()
            await lease.cancelAndCleanup(preservingCommittedRoute: true)
            try await assertRouteAndCatalogReady(observer, "preserved by the cancelled attempt")

            // Session deletion, window close, and workspace discard use the run-scoped cleaner
            // (`AgentModeViewModel.defaultMCPRunRoutingCleaner`), which calls exactly this.
            await observer.manager.cleanupRunRoutingState(for: observer.runID, windowID: observer.window.windowID)
            await assertRouteRevoked(observer, "session deletion")
        #else
            throw XCTSkip("Requires DEBUG MCP routing fixtures.")
        #endif
    }

    func testCancellationThatDoesNotOptInStillRevokesACommittedRoute() async throws {
        #if DEBUG
            // User Stop, provider identity resets, and every non-Claude caller keep the default.
            let observer = try await makeRoutedObserver()
            let lease = makeAttemptLease(observer)
            _ = await lease.acquire()
            await lease.cancelAndCleanup()
            await assertRouteRevoked(observer, "non-preserving cancellation")
        #else
            throw XCTSkip("Requires DEBUG MCP routing fixtures.")
        #endif
    }

    func testClaudeRunnerPreservesOnlyWhileTheSessionStillOwnsTheReusedRun() {
        let viewModel = makeBareViewModel()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        let runID = UUID()
        session.installRunID(runID)

        XCTAssertFalse(
            ClaudeIntegratedAgentModeRunner.cancellationPreservesRunRoute(session: session, runID: runID),
            "no live controller: nothing outlives the attempt"
        )
        session.claudeController = MonitorFakeNativeController()
        XCTAssertTrue(
            ClaudeIntegratedAgentModeRunner.cancellationPreservesRunRoute(session: session, runID: runID),
            "a retracted attempt on the still-owned reused run keeps its route"
        )
        XCTAssertFalse(
            ClaudeIntegratedAgentModeRunner.cancellationPreservesRunRoute(session: session, runID: UUID()),
            "an attempt on a different run never preserves the current one"
        )

        // User Stop detaches the controller and clears the run identity before cancellation cleanup.
        _ = viewModel.claudeCoordinator.prepareClaudeCancelSync(session)
        XCTAssertNil(session.runID)
        XCTAssertFalse(
            ClaudeIntegratedAgentModeRunner.cancellationPreservesRunRoute(session: session, runID: runID),
            "user Stop ends the run's scope, so its cancellation keeps revoking"
        )
    }

    func testClaudeRunnerCancellationConsultsTheRouteOnlyForAStillOwnedRun() async {
        let viewModel = makeBareViewModel()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        let runID = UUID()
        session.installRunID(runID)
        session.claudeController = MonitorFakeNativeController()

        // A retracted attempt on the still-owned reused run asks the route authority and keeps it.
        let owned = LeaseHookSpy()
        let ownedLease = makeSpyLease(runID: runID, spy: owned)
        let ownedAcquired = await ownedLease.acquire()
        XCTAssertTrue(ownedAcquired)
        await ClaudeIntegratedAgentModeRunner.cancelAttemptLease(ownedLease, session: session, runID: runID)
        var resolverCalls = await owned.resolverCalls
        var clearerCalls = await owned.clearerCalls
        XCTAssertEqual(resolverCalls, 1)
        XCTAssertEqual(clearerCalls, 0, "a committed, still-owned run must not be revoked")

        // A released session cannot prove ownership: revoke without consulting the authority.
        let released = LeaseHookSpy()
        let releasedLease = makeSpyLease(runID: runID, spy: released)
        _ = await releasedLease.acquire()
        await ClaudeIntegratedAgentModeRunner.cancelAttemptLease(releasedLease, session: nil, runID: runID)
        resolverCalls = await released.resolverCalls
        clearerCalls = await released.clearerCalls
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(clearerCalls, 1)

        // User Stop detaches the controller and clears the run first, so its cancellation revokes.
        _ = viewModel.claudeCoordinator.prepareClaudeCancelSync(session)
        let stopped = LeaseHookSpy()
        let stoppedLease = makeSpyLease(runID: runID, spy: stopped)
        _ = await stoppedLease.acquire()
        await ClaudeIntegratedAgentModeRunner.cancelAttemptLease(stoppedLease, session: session, runID: runID)
        resolverCalls = await stopped.resolverCalls
        clearerCalls = await stopped.clearerCalls
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(clearerCalls, 1)
    }

    func testPreservingCancellationJoinsARevokeThatStartsWhileTheRouteIsSampled() async throws {
        #if DEBUG
            let spy = LeaseHookSpy()
            let resolverGate = LeaseHookGate()
            let clearerGate = LeaseHookGate()
            let lease = makeSpyLease(
                runID: UUID(),
                spy: spy,
                resolverGate: resolverGate,
                clearerGate: clearerGate
            )
            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)

            let preserving = Task { await lease.cancelAndCleanup(preservingCommittedRoute: true) }
            await resolverGate.waitUntilEntered()
            // A full revoke starts on another path while the preserving cancellation samples authority.
            let failing = Task { await lease.failAndCleanup() }
            await clearerGate.waitUntilEntered()
            let joined = JoinFlag()
            Task {
                _ = await lease.debugWaitForPolicyClearJoiner()
                await joined.set()
            }
            await resolverGate.open()

            // The preserving cancellation must join the in-flight revoke rather than return early.
            let didJoin: Bool
            do {
                try await AsyncTestWait.waitUntil("preserving cancellation joins the in-flight revoke") {
                    await joined.isSet
                }
                didJoin = true
            } catch {
                didJoin = false
            }
            XCTAssertTrue(didJoin)
            await clearerGate.open()
            await preserving.value
            await failing.value
            let clearerCalls = await spy.clearerCalls
            XCTAssertEqual(clearerCalls, 1, "one shared revoke, joined by both paths")
        #else
            throw XCTSkip("Requires the DEBUG policy-clear join probe.")
        #endif
    }

    func testFailedAttemptStillRevokesItsRun() async throws {
        #if DEBUG
            let observer = try await makeRoutedObserver()
            let lease = makeAttemptLease(observer)
            _ = await lease.acquire()
            await lease.failAndCleanup()
            await assertRouteRevoked(observer, "failure cleanup")
        #else
            throw XCTSkip("Requires DEBUG MCP routing fixtures.")
        #endif
    }

    func testCancelledNonAgentModeLeaseStillRevokesItsRun() async throws {
        #if DEBUG
            let observer = try await makeRoutedObserver()
            let lease = makeAttemptLease(observer, purpose: .discoverRun)
            _ = await lease.acquire()
            await lease.cancelAndCleanup(preservingCommittedRoute: true)
            await assertRouteRevoked(observer, "discovery cancellation")
        #else
            throw XCTSkip("Requires DEBUG MCP routing fixtures.")
        #endif
    }

    func testCancelledAttemptWithoutACommittedRouteStillRevokesItsRun() async throws {
        #if DEBUG
            let observer = try await makeRoutedObserver()
            // The attempt's connection is already gone: nothing is left to preserve.
            await observer.manager.removeConnection(observer.connectionID)
            let lease = makeAttemptLease(observer)
            _ = await lease.acquire()
            await lease.cancelAndCleanup(preservingCommittedRoute: true)
            await assertRouteRevoked(observer, "cancellation without a committed route")
        #else
            throw XCTSkip("Requires DEBUG MCP routing fixtures.")
        #endif
    }

    // MARK: - Lease spies

    private func makeBareViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
    }

    /// A lease whose MCP side effects are recorded rather than performed. The route authority always
    /// reports a committed route, so only the caller's opt-in decides whether it is consulted.
    private func makeSpyLease(
        runID: UUID,
        spy: LeaseHookSpy,
        resolverGate: LeaseHookGate? = nil,
        clearerGate: LeaseHookGate? = nil
    ) -> MCPBootstrapLease {
        MCPBootstrapLease(
            spec: MCPBootstrapLeaseSpec(
                runID: runID,
                gateID: UUID(),
                windowID: 1,
                tabID: UUID(),
                clientName: "RepoPromptCE",
                restrictedTools: [],
                additionalTools: nil,
                oneShot: true,
                reason: "cancelled-attempt-route-spy",
                ttl: 60,
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: true
            ),
            policyInstaller: { _ in },
            expectedPIDPolicyArmer: { _ in true },
            policyClearer: { _ in
                await spy.recordClear()
                await clearerGate?.pass()
            },
            routeAuthorityResolver: { _ in
                await spy.recordResolve()
                await resolverGate?.pass()
                return .committed
            }
        )
    }

    #if DEBUG

        // MARK: - Fixture

        private struct RoutedObserver {
            let manager: ServerNetworkManager
            let window: WindowState
            let session: AgentModeViewModel.TabSession
            let endpoint: DomainAgentSessionLinkEndpointIdentity
            let tabID: UUID
            let runID: UUID
            let connectionID: UUID
        }

        private func window(_ observer: RoutedObserver) -> AgentModeViewModel {
            observer.window.agentModeViewModel
        }

        /// An established Claude observer whose reused process run is routed on one live connection
        /// and whose catalog projection is ready for exactly this endpoint.
        private func makeRoutedObserver() async throws -> RoutedObserver {
            let manager = ServerNetworkManager(
                domainHost: AppDomainRuntimeComposition.shared.runtime.domainHost
            )
            let window = makeWindow()
            WindowStatesManager.shared.registerWindowState(window)
            let runID = UUID()
            let connectionID = UUID()
            let tabID = UUID()
            let clientName = clientName

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
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: nil, outbound: nil)
                await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
                await manager.clearClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)
                await manager.removeConnection(connectionID)
                await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                WindowStatesManager.shared.unregisterWindowState(window)
            }

            await window.workspaceManager.awaitInitialized()
            try await installRoutingSnapshot(for: tabID, in: window)
            let session = window.agentModeViewModel.session(for: tabID)
            session.selectedAgent = .claudeCode
            session.hasLoadedPersistedState = true
            session.oversight.autoWakeOnUpdates = false
            session.installRunID(runID)
            let sessionID = try XCTUnwrap(window.agentModeViewModel.test_ensureSessionBoundToTab(session))
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(window.agentModeViewModel, tabID: tabID)
            window.agentModeViewModel.agentSessionLinkPublishPromptInventory(
                AgentSessionLinkPromptInventory(
                    observerSessionID: sessionID,
                    linkSetRevision: 1,
                    items: [
                        AgentSessionLinkPromptInventoryItem(
                            targetSessionID: Self.targetSessionID,
                            displayName: "Window latency lane",
                            capabilityNames: ["poll", "read", "send_when_idle", "wait"],
                            reference: AgentSessionLinkAutoWakeTests.laneReference(0)
                        )
                    ]
                ),
                to: endpoint
            )
            await manager.debugSetSessionLinkCatalogEndpointsForTesting(
                anyActive: [endpoint],
                outbound: [endpoint]
            )

            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "Cancelled attempt route preservation (initial run)",
                ttl: 10,
                tabID: tabID,
                runID: runID,
                additionalTools: nil,
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: true
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: CancelledAttemptRouteTestConnection(),
                pendingClientID: clientName
            )
            let applied = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: "cancelled-attempt-\(runID.uuidString)",
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            XCTAssertEqual(applied.outcome, "applied")
            _ = try await manager.debugListToolNames(for: connectionID)

            return RoutedObserver(
                manager: manager,
                window: window,
                session: session,
                endpoint: endpoint,
                tabID: tabID,
                runID: runID,
                connectionID: connectionID
            )
        }

        /// A lease for one turn attempt on the observer's reused run, with the production default
        /// hooks bound to this test's manager instance instead of `ServerNetworkManager.shared`.
        private func makeAttemptLease(
            _ observer: RoutedObserver,
            purpose: MCPRunPurpose = .agentModeRun
        ) -> MCPBootstrapLease {
            let manager = observer.manager
            let clientName = clientName
            return MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: observer.runID,
                    gateID: UUID(),
                    windowID: observer.window.windowID,
                    tabID: observer.tabID,
                    clientName: clientName,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                    additionalTools: nil,
                    oneShot: true,
                    reason: "Cancelled attempt route preservation (reused run)",
                    ttl: 10,
                    purpose: purpose,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: true
                ),
                policyInstaller: { spec in
                    await manager.installClientConnectionPolicy(
                        for: clientName,
                        windowID: spec.windowID,
                        restrictedTools: spec.restrictedTools,
                        oneShot: spec.oneShot,
                        reason: spec.reason,
                        ttl: spec.ttl,
                        tabID: spec.tabID,
                        runID: spec.runID,
                        additionalTools: spec.additionalTools,
                        purpose: spec.purpose,
                        taskLabelKind: spec.taskLabelKind,
                        allowsAgentExternalControlTools: spec.allowsAgentExternalControlTools,
                        requiresExpectedAgentPID: spec.requiresExpectedAgentPID
                    )
                },
                expectedPIDPolicyArmer: { spec in
                    await manager.requireExpectedAgentPIDForPendingPolicy(
                        for: clientName,
                        runID: spec.runID,
                        windowID: spec.windowID
                    )
                },
                policyClearer: { spec in
                    await manager.revokeClientConnectionPolicy(
                        for: clientName,
                        windowID: spec.windowID,
                        runID: spec.runID
                    )
                },
                routeAuthorityResolver: { spec in
                    await manager.confirmCommittedRunRouteOrFenceRevocation(
                        runID: spec.runID,
                        windowID: spec.windowID,
                        tabID: spec.tabID
                    )
                }
            )
        }

        // MARK: - Assertions

        private func assertRouteAndCatalogReady(
            _ observer: RoutedObserver,
            _ label: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let serverProjection = await observer.manager.debugRunCatalogProjection(for: observer.runID)
            let projection = try XCTUnwrap(serverProjection, "\(label): server catalog observation", file: file, line: line)
            XCTAssertEqual(projection.hasAgentSessionLink, true, "\(label): catalog", file: file, line: line)
            XCTAssertEqual(projection.hasActiveOutboundLink, true, "\(label): outbound", file: file, line: line)
            XCTAssertTrue(projection.isReady, "\(label): server projection ready", file: file, line: line)
            let token = await observer.manager.authoritativeRunCatalogRouteToken(
                runID: observer.runID,
                windowID: observer.window.windowID,
                tabID: observer.tabID
            )
            XCTAssertNotNil(token, "\(label): authoritative route", file: file, line: line)
            let host = window(observer)
            XCTAssertEqual(
                host.agentSessionLinkRunCatalogProjectionByEndpoint[observer.endpoint]?.isReady,
                true,
                "\(label): host projection ready",
                file: file,
                line: line
            )
            XCTAssertNotNil(
                host.agentSessionLinkPromptContext(for: observer.session),
                "\(label): observer prompt gate open",
                file: file,
                line: line
            )
        }

        private func assertRouteRevoked(
            _ observer: RoutedObserver,
            _ label: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let token = await observer.manager.authoritativeRunCatalogRouteToken(
                runID: observer.runID,
                windowID: observer.window.windowID,
                tabID: observer.tabID
            )
            XCTAssertNil(token, "\(label): route revoked", file: file, line: line)
            let serverProjection = await observer.manager.debugRunCatalogProjection(for: observer.runID)
            XCTAssertNil(serverProjection, "\(label): server catalog observation terminated", file: file, line: line)
            XCTAssertNotEqual(
                window(observer).agentSessionLinkRunCatalogProjectionByEndpoint[observer.endpoint]?.isReady,
                true,
                "\(label): host projection no longer ready",
                file: file,
                line: line
            )
        }

        // MARK: - Values

        private static let targetSessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000CA11")!

        private func laneSnapshot(
            observerEndpoint: DomainAgentSessionLinkEndpointIdentity
        ) -> AgentSessionLinkPassiveStatusNotices.Snapshot {
            let reference = AgentSessionLinkAutoWakeTests.laneReference(0)
            let targetEndpoint = DomainAgentSessionLinkEndpointIdentity(
                windowID: observerEndpoint.windowID &+ 1,
                workspaceID: UUID(),
                tabID: UUID(),
                sessionID: Self.targetSessionID,
                persistentBindingGeneration: UUID(),
                bindingTransitionGeneration: 1
            )
            return AgentSessionLinkPassiveStatusNotices.Snapshot(
                observerEndpoint: observerEndpoint,
                queueEpoch: UUID(),
                queueRevision: 1,
                linkSetRevision: 1,
                isEnabled: true,
                isDeliverable: true,
                entries: [
                    AgentSessionLinkPassiveStatusNotices.PendingEntry(
                        reference: reference,
                        targetEndpoint: targetEndpoint,
                        targetSessionID: Self.targetSessionID,
                        displayName: "Window latency lane",
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
                        targetEndpoint: targetEndpoint,
                        targetSessionID: Self.targetSessionID,
                        isEffectivelySelected: true
                    )
                ]
            )
        }

        // MARK: - Window setup

        private func installRoutingSnapshot(for tabID: UUID, in window: WindowState) async throws {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Cancelled attempt route \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                ephemeral: true
            )
            let switchResult = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "cancelledAttemptRouteInitial"
            )
            XCTAssertEqual(switchResult, .switched)
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                ComposeTabState(id: tabID, name: "Cancelled attempt route")
            ]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabID
            let reloadResult = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
                window.workspaceManager.workspaces[workspaceIndex],
                reason: "cancelledAttemptRouteTab"
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
    #endif
}

#if DEBUG
    private actor CancelledAttemptRouteTestConnection: MCPServerConnection {
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

private actor LeaseHookSpy {
    private(set) var resolverCalls = 0
    private(set) var clearerCalls = 0

    func recordResolve() {
        resolverCalls += 1
    }

    func recordClear() {
        clearerCalls += 1
    }
}

private actor LeaseHookGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor JoinFlag {
    private(set) var isSet = false

    func set() {
        isSet = true
    }
}
