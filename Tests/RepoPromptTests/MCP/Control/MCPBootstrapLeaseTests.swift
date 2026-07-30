import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class MCPBootstrapLeaseTests: XCTestCase {
    func testPIDOwnedSameClientLeasesReleaseBootstrapGateBeforeEitherRoutes() async throws {
        #if DEBUG
            let firstRunID = UUID()
            let secondRunID = UUID()
            let firstGateID = UUID()
            let secondGateID = UUID()
            let clientName = "bootstrap-lease-parallel-same-client"
            let recorder = PolicyRecorder()

            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: firstRunID)
            await MCPRoutingWaiter.cleanup(runID: secondRunID)
            await ServerNetworkManager.shared.debugClearRunRoutingHistoryForTesting()

            func makeLease(runID: UUID, gateID: UUID, tabID: UUID) -> MCPBootstrapLease {
                MCPBootstrapLease(
                    spec: MCPBootstrapLeaseSpec(
                        runID: runID,
                        gateID: gateID,
                        windowID: 1,
                        tabID: tabID,
                        clientName: clientName,
                        restrictedTools: [],
                        additionalTools: nil,
                        oneShot: true,
                        reason: "parallel PID-owned bootstrap regression",
                        ttl: 10,
                        purpose: .agentModeRun,
                        taskLabelKind: nil,
                        allowsAgentExternalControlTools: false,
                        requiresExpectedAgentPID: true
                    ),
                    policyInstaller: { _ in await recorder.recordInstall() },
                    expectedPIDPolicyArmer: { _ in await recorder.recordArm() },
                    policyClearer: { _ in await recorder.recordClear() }
                )
            }

            let firstLease = makeLease(runID: firstRunID, gateID: firstGateID, tabID: UUID())
            let secondLease = makeLease(runID: secondRunID, gateID: secondGateID, tabID: UUID())
            let firstAcquired = await firstLease.acquire()
            let activeGateAfterFirstAcquire = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertTrue(firstAcquired)
            XCTAssertNil(activeGateAfterFirstAcquire)

            let secondCompleted = expectation(description: "second same-client PID-owned lease acquires before first routes")
            let secondAcquisition = Task {
                let acquired = await secondLease.acquire()
                secondCompleted.fulfill()
                return acquired
            }
            await fulfillment(of: [secondCompleted], timeout: 1)
            let secondAcquired = await secondAcquisition.value

            let installCount = await recorder.installCount
            let armCount = await recorder.armCount
            let activeGateAfterSecondAcquire = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertTrue(secondAcquired)
            XCTAssertEqual(installCount, 2)
            XCTAssertEqual(armCount, 2)
            XCTAssertNil(activeGateAfterSecondAcquire)

            await firstLease.providerInitializationStarted(provider: "test-provider")
            await firstLease.providerInitializationCompleted(provider: "test-provider", outcome: "ready")
            let firstHistory = await ServerNetworkManager.shared.debugRunRoutingHistoryPayload(
                runID: firstRunID,
                limit: 50
            )
            let firstEvents = try XCTUnwrap(firstHistory["events"] as? [[String: Any]])
            XCTAssertTrue(firstEvents.contains { $0["event"] as? String == "lease_gate_wait_started" })
            XCTAssertTrue(firstEvents.contains { $0["event"] as? String == "lease_gate_acquired" })
            XCTAssertTrue(firstEvents.contains { $0["event"] as? String == "provider_initialization_started" })
            let providerCompleted = try XCTUnwrap(firstEvents.first { $0["event"] as? String == "provider_initialization_completed" })
            let providerFields = try XCTUnwrap(providerCompleted["fields"] as? [String: String])
            XCTAssertEqual(providerFields["provider"], "test-provider")
            XCTAssertEqual(providerFields["outcome"], "ready")
            let earlyRelease = try XCTUnwrap(firstEvents.first { $0["event"] as? String == "lease_gate_release" })
            let releaseFields = try XCTUnwrap(earlyRelease["fields"] as? [String: String])
            XCTAssertEqual(releaseFields["reason"], "expected_pid_policy_armed")
            XCTAssertEqual(releaseFields["released"], "true")
            XCTAssertNotNil(releaseFields["queue_depth_before_release"])

            await firstLease.cancelAndCleanup()
            await secondLease.cancelAndCleanup()
            let clearCount = await recorder.clearCount
            let firstWaiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: firstRunID)
            let secondWaiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: secondRunID)
            let activeGateAfterCleanup = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(clearCount, 2)
            XCTAssertEqual(firstWaiterCount, 0)
            XCTAssertEqual(secondWaiterCount, 0)
            XCTAssertNil(activeGateAfterCleanup)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }

    func testIndefiniteRoutedOutcomeRemainsObservableForLeaseLifetime() async {
        let runID = UUID()
        let policyRecorder = PolicyRecorder()
        await HeadlessAgentConnectionGate.cancelAll()
        await MCPRoutingWaiter.cleanup(runID: runID)

        let lease = MCPBootstrapLease(
            spec: MCPBootstrapLeaseSpec(
                runID: runID,
                gateID: UUID(),
                windowID: 1,
                tabID: UUID(),
                clientName: "bootstrap-indefinite-terminal-cache",
                restrictedTools: [],
                additionalTools: nil,
                oneShot: true,
                reason: "indefinite routed terminal lifetime regression",
                ttl: 10,
                purpose: .discoverRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: false
            ),
            policyInstaller: { _ in await policyRecorder.recordInstall() },
            policyClearer: { _ in await policyRecorder.recordClear() }
        )
        let acquired = await lease.acquire()
        XCTAssertTrue(acquired)

        await MCPRoutingWaiter.notifyRouted(runID: runID)
        let releaseOutcome = await lease.releaseWhenRoutedIndefinitely()
        let globalOutcomeAfterCleanup = await MCPRoutingWaiter.currentTerminalOutcome(runID: runID)
        let firstLeaseOutcomeAfterCleanup = await lease.currentRoutingTerminalOutcome()
        let secondLeaseOutcomeAfterCleanup = await lease.currentRoutingTerminalOutcome()
        let clearCount = await policyRecorder.clearCount

        XCTAssertEqual(releaseOutcome, .routed)
        XCTAssertNil(globalOutcomeAfterCleanup)
        XCTAssertEqual(firstLeaseOutcomeAfterCleanup, .routed)
        XCTAssertEqual(secondLeaseOutcomeAfterCleanup, .routed)
        XCTAssertEqual(clearCount, 0)
    }

    func testPIDOwnedEarlyReleaseCleanupRemovesRetainedPolicyForEveryExit() async throws {
        #if DEBUG
            enum ExitMode: String, CaseIterable {
                case timeout
                case cancellation
                case failure
            }

            let manager = ServerNetworkManager.shared
            await HeadlessAgentConnectionGate.cancelAll()

            for mode in ExitMode.allCases {
                let runID = UUID()
                let gateID = UUID()
                let clientName = "bootstrap-lease-early-release-\(mode.rawValue)-\(runID.uuidString)"
                let lease = MCPBootstrapLease(
                    spec: MCPBootstrapLeaseSpec(
                        runID: runID,
                        gateID: gateID,
                        windowID: 1,
                        tabID: UUID(),
                        clientName: clientName,
                        restrictedTools: [],
                        additionalTools: nil,
                        oneShot: true,
                        reason: "early release \(mode.rawValue) cleanup regression",
                        ttl: 10,
                        purpose: .agentModeRun,
                        taskLabelKind: nil,
                        allowsAgentExternalControlTools: false,
                        requiresExpectedAgentPID: true
                    )
                )

                await MCPRoutingWaiter.cleanup(runID: runID)
                let acquired = await lease.acquire()
                let activeGateAfterAcquire = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
                let pendingBeforeExit = await manager.debugPendingPolicySnapshot(for: clientName)
                XCTAssertTrue(acquired, mode.rawValue)
                XCTAssertNil(activeGateAfterAcquire, mode.rawValue)
                XCTAssertTrue(pendingBeforeExit.contains { $0.runID == runID }, mode.rawValue)

                switch mode {
                case .timeout:
                    let routed = await lease.releaseWhenRouted(timeoutMs: 10)
                    XCTAssertFalse(routed)
                case .cancellation:
                    await lease.cancelAndCleanup()
                case .failure:
                    await lease.failAndRelease()
                }

                let pendingAfterExit = await manager.debugPendingPolicySnapshot(for: clientName)
                let waiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
                let activeGateAfterExit = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
                XCTAssertFalse(pendingAfterExit.contains { $0.runID == runID }, mode.rawValue)
                XCTAssertEqual(waiterCount, 0, mode.rawValue)
                XCTAssertNil(activeGateAfterExit, mode.rawValue)
                await manager.cleanupRunRoutingState(for: runID, windowID: 1)
                await MCPRoutingWaiter.cleanup(runID: runID)
            }
        #else
            throw XCTSkip("PID-owned policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testRoutingStartupProgressDistinguishesSuccessAndBothTimeoutSides() async throws {
        #if DEBUG
            enum Scenario: String, CaseIterable {
                case success
                case timeoutBeforeConnection
                case timeoutAfterConnection
            }

            await HeadlessAgentConnectionGate.cancelAll()

            for scenario in Scenario.allCases {
                let runID = UUID()
                let recorder = BootstrapProgressRecorder()
                let policyRecorder = PolicyRecorder()
                await MCPRoutingWaiter.cleanup(runID: runID)
                let lease = MCPBootstrapLease(
                    spec: MCPBootstrapLeaseSpec(
                        runID: runID,
                        gateID: UUID(),
                        windowID: 1,
                        tabID: UUID(),
                        clientName: "bootstrap-progress-\(scenario.rawValue)",
                        restrictedTools: [],
                        additionalTools: nil,
                        oneShot: true,
                        reason: "routing startup progress regression",
                        ttl: 10,
                        purpose: .discoverRun,
                        taskLabelKind: nil,
                        allowsAgentExternalControlTools: false,
                        requiresExpectedAgentPID: false
                    ),
                    policyInstaller: { _ in await policyRecorder.recordInstall() },
                    policyClearer: { _ in await policyRecorder.recordClear() }
                )
                let acquired = await lease.acquire()
                XCTAssertTrue(acquired, scenario.rawValue)

                if scenario != .timeoutBeforeConnection {
                    await MCPRoutingWaiter.notifyConnectionObserved(runID: runID)
                }
                if scenario == .success {
                    await MCPRoutingWaiter.notifyRouted(runID: runID)
                }

                let outcome = await lease.releaseWhenRouted(
                    waitPolicy: MCPRoutingWaitPolicy(
                        noConnectionTimeout: .milliseconds(10),
                        observedConnectionGrace: .milliseconds(10)
                    ),
                    progressReporter: { progress in
                        await recorder.record(progress)
                    }
                )
                let phases = await recorder.snapshot()

                switch scenario {
                case .success:
                    XCTAssertEqual(outcome, .routed)
                    XCTAssertEqual(phases, [
                        .waitingForChildConnection,
                        .childConnectionObserved,
                        .waitingForRouting,
                        .routingConfirmed
                    ])
                    let clearCount = await policyRecorder.clearCount
                    XCTAssertEqual(clearCount, 0)
                case .timeoutBeforeConnection:
                    XCTAssertEqual(outcome, .timedOutBeforeConnection)
                    XCTAssertEqual(phases, [
                        .waitingForChildConnection,
                        .routingTimeoutBeforeConnection
                    ])
                    let clearCount = await policyRecorder.clearCount
                    XCTAssertEqual(clearCount, 1)
                case .timeoutAfterConnection:
                    XCTAssertEqual(outcome, .timedOutAfterConnection)
                    XCTAssertEqual(phases, [
                        .waitingForChildConnection,
                        .childConnectionObserved,
                        .waitingForRouting,
                        .routingTimeoutAfterConnection
                    ])
                    let clearCount = await policyRecorder.clearCount
                    XCTAssertEqual(clearCount, 1)
                }

                let activeGate = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
                let waiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
                XCTAssertNil(activeGate)
                XCTAssertEqual(waiterCount, 0)
                await MCPRoutingWaiter.cleanup(runID: runID)
            }

            let indefiniteRunID = UUID()
            let indefinitePolicyRecorder = PolicyRecorder()
            await MCPRoutingWaiter.cleanup(runID: indefiniteRunID)
            let indefiniteLease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: indefiniteRunID,
                    gateID: UUID(),
                    windowID: 1,
                    tabID: UUID(),
                    clientName: "bootstrap-progress-indefinite",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "indefinite routing cancellation regression",
                    ttl: 0.001,
                    purpose: .discoverRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                policyInstaller: { _ in await indefinitePolicyRecorder.recordInstall() },
                policyClearer: { _ in await indefinitePolicyRecorder.recordClear() }
            )
            let indefiniteAcquired = await indefiniteLease.acquire()
            XCTAssertTrue(indefiniteAcquired)
            let indefiniteWait = Task {
                await indefiniteLease.releaseWhenRoutedIndefinitely()
            }
            await Task.yield()
            indefiniteWait.cancel()
            let indefiniteOutcome = await indefiniteWait.value
            let indefiniteClearCount = await indefinitePolicyRecorder.clearCount
            XCTAssertEqual(indefiniteOutcome, .cancelled)
            XCTAssertEqual(indefiniteClearCount, 1)
            await MCPRoutingWaiter.notifyRouted(runID: indefiniteRunID)
            let lateRouteContinuationCount = await MCPRoutingWaiter.debugContinuationCount(runID: indefiniteRunID)
            XCTAssertEqual(lateRouteContinuationCount, 0)

            let settlementRunID = UUID()
            let settlementClientName = "bootstrap-settlement-policy-\(settlementRunID.uuidString)"
            let settlementLease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: settlementRunID,
                    gateID: UUID(),
                    windowID: 1,
                    tabID: UUID(),
                    clientName: settlementClientName,
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "settlement-scoped policy pruning regression",
                    ttl: -1,
                    purpose: .discoverRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                )
            )
            let settlementAcquired = await settlementLease.acquire()
            XCTAssertTrue(settlementAcquired)
            _ = await ServerNetworkManager.shared.requireExpectedAgentPIDForPendingPolicy(
                for: settlementClientName,
                runID: settlementRunID,
                windowID: 1
            )
            let pendingAfterAgePrune = await ServerNetworkManager.shared.debugPendingPolicySnapshot(
                for: settlementClientName
            )
            XCTAssertTrue(pendingAfterAgePrune.contains { $0.runID == settlementRunID })

            await settlementLease.cancelAndCleanup()
            let pendingAfterSettlement = await ServerNetworkManager.shared.debugPendingPolicySnapshot(
                for: settlementClientName
            )
            XCTAssertFalse(pendingAfterSettlement.contains { $0.runID == settlementRunID })

            let providerCompletionRunID = UUID()
            await MCPRoutingWaiter.register(runID: providerCompletionRunID)
            let committedAtProviderCompletionLease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: providerCompletionRunID,
                    gateID: UUID(),
                    windowID: 1,
                    tabID: UUID(),
                    clientName: "bootstrap-provider-completion-race",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "provider completion route authority regression",
                    ttl: 1,
                    purpose: .discoverRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                routeAuthorityResolver: { _ in .committed }
            )
            let providerCompletionAuthority = await committedAtProviderCompletionLease
                .resolveRouteAuthorityAtProviderCompletion()
            XCTAssertEqual(providerCompletionAuthority, .committed)
            let providerCompletionWaitOutcome = await MCPRoutingWaiter.waitForRoutingOutcome(
                runID: providerCompletionRunID,
                timeoutSeconds: 0
            )
            XCTAssertEqual(providerCompletionWaitOutcome, .routed)
            await MCPRoutingWaiter.cleanup(runID: providerCompletionRunID)
        #else
            throw XCTSkip("Bootstrap routing progress diagnostics require DEBUG helpers.")
        #endif
    }

    func testTimeoutSnapshotFencesLateChildObservationProgress() async throws {
        #if DEBUG
            let runID = UUID()
            let recorder = BootstrapProgressRecorder()
            let policyClearGate = BootstrapPolicyClearGate()
            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: runID)

            let lease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: UUID(),
                    windowID: 1,
                    tabID: UUID(),
                    clientName: "bootstrap-progress-timeout-race",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "routing timeout progress fence regression",
                    ttl: 10,
                    purpose: .discoverRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                policyInstaller: { _ in },
                policyClearer: { _ in
                    await policyClearGate.block()
                }
            )
            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)

            let release = Task {
                await lease.releaseWhenRouted(
                    timeoutMs: 10,
                    progressReporter: { progress in
                        await recorder.record(progress)
                    }
                )
            }

            await policyClearGate.waitUntilBlocked()
            await MCPRoutingWaiter.notifyConnectionObserved(runID: runID)
            let stickyObservation = await MCPRoutingWaiter.connectionWasObserved(runID: runID)
            XCTAssertTrue(stickyObservation)
            await policyClearGate.release()

            let routed = await release.value
            let phases = await recorder.snapshot()
            XCTAssertFalse(routed)
            XCTAssertEqual(phases, [
                .waitingForChildConnection,
                .routingTimeoutBeforeConnection
            ])
            XCTAssertFalse(phases.contains(.childConnectionObserved))
            XCTAssertFalse(phases.contains(.waitingForRouting))

            let activeGate = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            let waiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertNil(activeGate)
            XCTAssertEqual(waiterCount, 0)
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Bootstrap routing progress diagnostics require DEBUG helpers.")
        #endif
    }

    func testLateCommittedRouteRecheckWinsBeforeTimeoutCleanup() async {
        let runID = UUID()
        let policyRecorder = PolicyRecorder()
        let progressRecorder = BootstrapProgressRecorder()
        await HeadlessAgentConnectionGate.cancelAll()
        await MCPRoutingWaiter.cleanup(runID: runID)
        let lease = MCPBootstrapLease(
            spec: MCPBootstrapLeaseSpec(
                runID: runID,
                gateID: UUID(),
                windowID: 1,
                tabID: UUID(),
                clientName: "late-route-recheck",
                restrictedTools: [],
                additionalTools: nil,
                oneShot: true,
                reason: "late route recheck",
                ttl: 10,
                purpose: .discoverRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: false
            ),
            policyInstaller: { _ in await policyRecorder.recordInstall() },
            policyClearer: { _ in await policyRecorder.recordClear() },
            routeAuthorityResolver: { _ in .committed }
        )
        let acquired = await lease.acquire()
        XCTAssertTrue(acquired)

        let outcome = await lease.releaseWhenRouted(
            waitPolicy: MCPRoutingWaitPolicy(
                noConnectionTimeout: .milliseconds(10),
                observedConnectionGrace: .milliseconds(20)
            ),
            progressReporter: { progress in
                await progressRecorder.record(progress)
            }
        )
        XCTAssertEqual(outcome, .routed)
        let progress = await progressRecorder.snapshot()
        XCTAssertEqual(progress, [
            .waitingForChildConnection,
            .childConnectionObserved,
            .waitingForRouting,
            .routingConfirmed
        ])
        let clearCount = await policyRecorder.clearCount
        XCTAssertEqual(clearCount, 0)
        await MCPRoutingWaiter.cleanup(runID: runID)
    }

    func testLegacyLeaseBooleanWrapperIgnoresObservedConnectionGrace() async {
        let runID = UUID()
        let policyRecorder = PolicyRecorder()
        await HeadlessAgentConnectionGate.cancelAll()
        await MCPRoutingWaiter.cleanup(runID: runID)
        let lease = MCPBootstrapLease(
            spec: MCPBootstrapLeaseSpec(
                runID: runID,
                gateID: UUID(),
                windowID: 1,
                tabID: UUID(),
                clientName: "legacy-absolute-deadline",
                restrictedTools: [],
                additionalTools: nil,
                oneShot: true,
                reason: "legacy timing regression",
                ttl: 10,
                purpose: .discoverRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: false
            ),
            policyInstaller: { _ in await policyRecorder.recordInstall() },
            policyClearer: { _ in await policyRecorder.recordClear() },
            routeAuthorityResolver: { _ in .revocationFenced }
        )
        let acquired = await lease.acquire()
        XCTAssertTrue(acquired)
        await MCPRoutingWaiter.notifyConnectionObserved(runID: runID)

        let didRoute = await lease.releaseWhenRouted(timeoutMs: 10)
        XCTAssertFalse(didRoute)
        let clearCount = await policyRecorder.clearCount
        XCTAssertEqual(clearCount, 1)
        await MCPRoutingWaiter.cleanup(runID: runID)
    }

    func testPIDOwnedAcquireFailsClosedWhenPolicyCannotBeArmed() async throws {
        #if DEBUG
            let runID = UUID()
            let gateID = UUID()
            let recorder = PolicyRecorder()
            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: runID)

            let lease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: gateID,
                    windowID: 1,
                    tabID: UUID(),
                    clientName: "bootstrap-lease-unarmed-policy",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "unarmed PID policy regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: true
                ),
                policyInstaller: { _ in await recorder.recordInstall() },
                expectedPIDPolicyArmer: { _ in false },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquired = await lease.acquire()
            let clearCount = await recorder.clearCount
            let waiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            let activeGate = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertFalse(acquired)
            XCTAssertEqual(clearCount, 1)
            XCTAssertEqual(waiterCount, 0)
            XCTAssertNil(activeGate)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }

    func testCleanupWhileQueuedReleasesGateOwnershipThatArrivesLater() async throws {
        #if DEBUG
            let blockerGateID = UUID()
            let leaseGateID = UUID()
            let probeGateID = UUID()
            let runID = UUID()
            let recorder = PolicyRecorder()

            await HeadlessAgentConnectionGate.cancelAll()
            await HeadlessAgentConnectionGate.beginConnection(blockerGateID)
            await MCPRoutingWaiter.cleanup(runID: runID)

            let lease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: leaseGateID,
                    windowID: 1,
                    tabID: nil,
                    clientName: "bootstrap-lease-race-test",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "queued cleanup regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                policyInstaller: { _ in await recorder.recordInstall() },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquisition = Task { await lease.acquire() }
            var queued = false
            let queueDeadline = Date().addingTimeInterval(2)
            repeat {
                queued = await HeadlessAgentConnectionGate.shared.debugWaitingCount() == 1
                if queued { break }
                try await Task.sleep(for: .milliseconds(10))
            } while Date() < queueDeadline
            let activeBeforeCleanup = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertTrue(queued, "Expected lease acquisition to queue behind blocker; active=\(String(describing: activeBeforeCleanup))")

            await lease.cancelAndCleanup()
            let activeBlockerID = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(activeBlockerID, blockerGateID)

            await HeadlessAgentConnectionGate.completeConnection(blockerGateID)
            let didAcquireLease = await acquisition.value
            let installCount = await recorder.installCount
            XCTAssertFalse(didAcquireLease)
            XCTAssertEqual(installCount, 0)

            let didAcquireProbe = await HeadlessAgentConnectionGate.acquire(probeGateID)
            let activeProbeID = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertTrue(didAcquireProbe)
            XCTAssertEqual(activeProbeID, probeGateID)
            await HeadlessAgentConnectionGate.completeConnection(probeGateID)
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Gate ownership inspection is DEBUG-only.")
        #endif
    }

    func testDeferredRoutingReleaseFreesGateAndTerminalCleanupClearsPolicy() async throws {
        #if DEBUG
            let leaseGateID = UUID()
            let probeGateID = UUID()
            let runID = UUID()
            let recorder = PolicyRecorder()

            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: runID)

            let lease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: leaseGateID,
                    windowID: 1,
                    tabID: nil,
                    clientName: "bootstrap-lease-deferred-test",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "deferred routing regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                policyInstaller: { _ in await recorder.recordInstall() },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)
            let installCount = await recorder.installCount
            let activeGateAfterAcquire = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(installCount, 1)
            XCTAssertEqual(activeGateAfterAcquire, leaseGateID)

            await lease.releaseGateForDeferredRouting()
            let activeGateAfterDeferredRelease = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            let clearCountAfterDeferredRelease = await recorder.clearCount
            XCTAssertNil(activeGateAfterDeferredRelease)
            XCTAssertEqual(clearCountAfterDeferredRelease, 0)

            let didAcquireProbe = await HeadlessAgentConnectionGate.acquire(probeGateID)
            XCTAssertTrue(didAcquireProbe)
            let activeProbeGate = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(activeProbeGate, probeGateID)
            await HeadlessAgentConnectionGate.completeConnection(probeGateID)

            await lease.cleanupDeferredRouting()
            let clearCountAfterCleanup = await recorder.clearCount
            let continuationCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertEqual(clearCountAfterCleanup, 1)
            XCTAssertEqual(continuationCount, 0)
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Gate ownership inspection is DEBUG-only.")
        #endif
    }

    @MainActor
    func testDeferredCursorRoutingAdvertisesOracleLogAfterPolicyAdmission() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let leaseGateID = UUID()
            let runID = UUID()
            let connectionID = UUID()
            let tabID = UUID()
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPBootstrapLeaseTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let sourceURL = rootURL.appendingPathComponent("CursorDeferredRouting.swift")
            try "let cursorDeferredRoutingToolGrant = true\n".write(to: sourceURL, atomically: true, encoding: .utf8)

            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            await window.workspaceManager.awaitInitialized()

            let catalogService = window.mcpServer.windowMCPToolCatalogService
            var ownedRoutingService: WindowRoutingService?
            var lease: MCPBootstrapLease?
            var loadedRootID: UUID?

            func cleanup() async {
                if let lease {
                    await lease.cleanupDeferredRouting()
                }
                await manager.clearExpectedAgentPID(
                    getpid(),
                    for: AgentProviderKind.cursorMCPClientID,
                    runID: runID
                )
                await manager.clearClientConnectionPolicy(
                    for: AgentProviderKind.cursorMCPClientID,
                    windowID: window.windowID,
                    runID: runID
                )
                await manager.removeConnection(connectionID)
                await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                await MCPRoutingWaiter.cleanup(runID: runID)
                await HeadlessAgentConnectionGate.cancelAll()
                ServiceRegistry.unregister(catalogService)
                if let ownedRoutingService {
                    ServiceRegistry.unregister(ownedRoutingService)
                }
                if let loadedRootID {
                    await window.workspaceFileContextStore.unloadRoot(id: loadedRootID)
                }
                WindowStatesManager.shared.unregisterWindowState(window)
                try? FileManager.default.removeItem(at: rootURL)
            }

            do {
                let workspace = window.workspaceManager.createWorkspace(
                    name: "Cursor Deferred Routing Tools \(UUID().uuidString.prefix(8))",
                    repoPaths: [rootURL.path],
                    ephemeral: true
                )
                await window.workspaceManager.switchWorkspace(
                    to: workspace,
                    saveState: false,
                    reason: "cursorDeferredRoutingToolGrantTest"
                )
                let workspaceIndex = try XCTUnwrap(
                    window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
                )
                window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                    ComposeTabState(id: tabID, name: "Cursor Deferred Routing")
                ]
                window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabID
                await window.workspaceManager.switchWorkspace(
                    to: window.workspaceManager.workspaces[workspaceIndex],
                    saveState: false,
                    reason: "cursorDeferredRoutingToolGrantTestTabs"
                )
                let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
                let loadedRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(in: window, path: rootURL.path)
                loadedRootID = loadedRoot.id

                ServiceRegistry.register(catalogService)
                let routing = try await Self.ensureRoutingService()
                ownedRoutingService = routing.owned ? routing.service : nil

                let cursorAdditionalTools = AgentModeMCPPolicyInstaller.additionalTools(for: .cursor)
                XCTAssertTrue(cursorAdditionalTools.contains(MCPWindowToolName.oracleChatLog))
                XCTAssertTrue(cursorAdditionalTools.contains(MCPWindowToolName.askOracle))

                let resolvedLease = MCPBootstrapLease(
                    spec: .agentMode(
                        tabID: tabID,
                        runID: runID,
                        gateID: leaseGateID,
                        windowID: window.windowID,
                        agent: .cursor
                    )
                )
                lease = resolvedLease

                await HeadlessAgentConnectionGate.cancelAll()
                await MCPRoutingWaiter.cleanup(runID: runID)
                let acquiredLease = await resolvedLease.acquire()
                XCTAssertTrue(acquiredLease)
                await manager.registerExpectedAgentPID(
                    getpid(),
                    for: AgentProviderKind.cursorMCPClientID,
                    runID: runID
                )

                let pendingPolicyBeforeDeferredRelease = await manager.debugRunPolicyState(for: runID)
                let runPolicyBeforeDeferredRelease = try XCTUnwrap(pendingPolicyBeforeDeferredRelease)
                XCTAssertEqual(runPolicyBeforeDeferredRelease.additionalTools, cursorAdditionalTools)

                await resolvedLease.releaseGateForDeferredRouting()
                let activeGateAfterDeferredRelease = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
                XCTAssertNil(activeGateAfterDeferredRelease)
                let pendingPolicyAfterDeferredRelease = await manager.debugRunPolicyState(for: runID)
                let runPolicyAfterDeferredRelease = try XCTUnwrap(pendingPolicyAfterDeferredRelease)
                XCTAssertEqual(runPolicyAfterDeferredRelease.additionalTools, cursorAdditionalTools)

                let appliedPolicy = await manager.debugApplyPendingPolicy(
                    clientName: AgentProviderKind.cursorMCPClientID,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: AgentProviderKind.cursorMCPClientID,
                    sessionKey: "cursor-deferred-routing-tools",
                    pidGateTimeout: 0.25
                )
                XCTAssertEqual(appliedPolicy.outcome, "applied")
                XCTAssertEqual(appliedPolicy.runID, runID)
                XCTAssertEqual(appliedPolicy.additionalTools, cursorAdditionalTools)

                let advertisedTools = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(
                    advertisedTools.contains(MCPWindowToolName.oracleChatLog),
                    "Deferred Cursor routing must still advertise oracle_chat_log after policy admission. Tools: \(advertisedTools)"
                )
                XCTAssertTrue(
                    advertisedTools.contains(MCPWindowToolName.askOracle),
                    "Deferred Cursor routing must still advertise ask_oracle after policy admission. Tools: \(advertisedTools)"
                )

                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
        #else
            throw XCTSkip("Connection policy and catalog diagnostics are DEBUG-only.")
        #endif
    }

    func testRequireRoutingThrowsReadinessErrorWhenRoutingTimesOut() async throws {
        #if DEBUG
            let runID = UUID()
            let gateID = UUID()
            let recorder = PolicyRecorder()
            await resetLeaseGlobals(runID: runID)

            let lease = makeRoutingLease(
                runID: runID,
                gateID: gateID,
                clientName: "bootstrap-lease-require-routing-timeout",
                policyInstaller: { _ in await recorder.recordInstall() },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)

            do {
                try await lease.requireRouting(timeoutMs: 10)
                XCTFail("requireRouting must throw when routing never completes")
            } catch let error as MCPBootstrapReadinessError {
                XCTAssertEqual(error, .routingUnavailable)
            } catch {
                XCTFail("requireRouting threw an unexpected error: \(error)")
            }

            let clearCount = await recorder.clearCount
            XCTAssertEqual(clearCount, 1, "Timed-out routing must clear the pending connection policy exactly once")
            await assertRoutingWaiterAndGateCleared(runID: runID)

            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }

    func testRequireRoutingReturnsWhenRunRoutes() async throws {
        #if DEBUG
            let runID = UUID()
            let gateID = UUID()
            let recorder = PolicyRecorder()
            await resetLeaseGlobals(runID: runID)

            let lease = makeRoutingLease(
                runID: runID,
                gateID: gateID,
                clientName: "bootstrap-lease-require-routing-success",
                policyInstaller: { _ in await recorder.recordInstall() },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)

            // Route through the LIVE continuation path: start the wait, let it register its waiter,
            // then signal routing. requireRouting must return without throwing and must leave the
            // pending policy in place for the real connection.
            let routingTask = Task { try await lease.requireRouting(timeoutMs: 5000) }
            await waitForRoutingContinuations(runID: runID, atLeast: 1)
            await MCPRoutingWaiter.notifyRouted(runID: runID)
            try await routingTask.value

            let clearCount = await recorder.clearCount
            XCTAssertEqual(clearCount, 0, "Successful routing must not clear the pending connection policy")
            await assertRoutingWaiterAndGateCleared(runID: runID)

            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }

    func testRequireRoutingThrowsCancellationErrorWhenCancelledAfterRegistration() async throws {
        #if DEBUG
            let runID = UUID()
            let gateID = UUID()
            let recorder = PolicyRecorder()
            await resetLeaseGlobals(runID: runID)

            let lease = makeRoutingLease(
                runID: runID,
                gateID: gateID,
                clientName: "bootstrap-lease-require-routing-cancel",
                policyInstaller: { _ in await recorder.recordInstall() },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)

            // Cancel only after the waiter registers, so the failure is genuinely a cancellation and
            // not a timeout: requireRouting must surface CancellationError, not a readiness error.
            let routingTask = Task { () -> Error? in
                do {
                    try await lease.requireRouting(timeoutMs: 5000)
                    return nil
                } catch {
                    return error
                }
            }
            await waitForRoutingContinuations(runID: runID, atLeast: 1)
            routingTask.cancel()
            let thrown = await routingTask.value
            XCTAssertTrue(
                thrown is CancellationError,
                "Cancellation after registration must surface CancellationError, got \(String(describing: thrown))"
            )

            let clearCount = await recorder.clearCount
            XCTAssertEqual(clearCount, 1, "A cancelled routing wait must still clear the pending policy exactly once")
            await assertRoutingWaiterAndGateCleared(runID: runID)

            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }

    func testRepeatedRequireRoutingWithRacingCancelJoinsSinglePolicyClear() async throws {
        #if DEBUG
            let runID = UUID()
            let gateID = UUID()
            let recorder = PolicyRecorder()
            await resetLeaseGlobals(runID: runID)

            let lease = makeRoutingLease(
                runID: runID,
                gateID: gateID,
                clientName: "bootstrap-lease-require-routing-race",
                policyInstaller: { _ in await recorder.recordInstall() },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)

            // Scenario: one requireRouting registers the live waiter and suspends; a second, repeated
            // call arrives after the lease is already releasing and fails fast WITHOUT awaiting the
            // releasing call's cleanup; a cancelAndCleanup races the suspended waiter. Both calls must
            // fail closed with the routing readiness error, and the pending policy must be cleared once.
            let suspendedCall = Task { () -> Error? in
                do { try await lease.requireRouting(timeoutMs: 5000)
                    return nil
                } catch { return error }
            }
            await waitForRoutingContinuations(runID: runID, atLeast: 1)
            let repeatedCall = Task { () -> Error? in
                do { try await lease.requireRouting(timeoutMs: 5000)
                    return nil
                } catch { return error }
            }
            await lease.cancelAndCleanup()
            let suspendedError = await suspendedCall.value
            let repeatedError = await repeatedCall.value

            XCTAssertTrue(
                (suspendedError as? MCPBootstrapReadinessError) == .routingUnavailable,
                "The suspended requireRouting must fail closed with .routingUnavailable, got \(String(describing: suspendedError))"
            )
            XCTAssertTrue(
                (repeatedError as? MCPBootstrapReadinessError) == .routingUnavailable,
                "The repeated requireRouting on the already-releasing lease must also fail closed with .routingUnavailable, got \(String(describing: repeatedError))"
            )

            let clearCount = await recorder.clearCount
            XCTAssertEqual(clearCount, 1, "The pending policy must be cleared exactly once across the racing cleanups")
            await assertRoutingWaiterAndGateCleared(runID: runID)

            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }

    func testConcurrentCleanupJoinsSingleInFlightPolicyClear() async throws {
        #if DEBUG
            let runID = UUID()
            let gateID = UUID()
            let events = CleanupEventLog()
            let clearerGate = ClearerGate()
            await resetLeaseGlobals(runID: runID)

            let lease = makeRoutingLease(
                runID: runID,
                gateID: gateID,
                clientName: "bootstrap-lease-cleanup-joinable",
                policyClearer: { _ in
                    await clearerGate.enterAndWait()
                    await events.record("clear_completed")
                }
            )

            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)

            // requireRouting times out, so it clears the policy; the single clearer enters and parks
            // on the gate, holding the one in-flight clear open.
            let requireTask = Task { () -> Error? in
                let outcome: Error?
                do {
                    try await lease.requireRouting(timeoutMs: 10)
                    outcome = nil
                } catch {
                    outcome = error
                }
                await events.record("require_returned")
                return outcome
            }
            await clearerGate.waitUntilEntered()

            // A concurrent cancelAndCleanup must JOIN the same in-flight clear instead of observing a
            // flag and returning while the clear is still suspended.
            let cancelTask = Task {
                await lease.cancelAndCleanup()
                await events.record("cancel_returned")
            }

            // Deterministically wait until cancelAndCleanup enters clearPolicyOnce's existing-operation
            // branch: it is now parked on the single in-flight clear, proving it joined rather than
            // skipped. The probe returns the observed joiner count.
            let joinerCount = await lease.debugWaitForPolicyClearJoiner()

            // The join happened while the clear is still parked, so neither caller has returned.
            let parkedEvents = await events.snapshot()
            XCTAssertFalse(parkedEvents.contains("clear_completed"), "policy clear must still be in-flight")
            XCTAssertFalse(parkedEvents.contains("require_returned"), "requireRouting must not return while the clear is parked")
            XCTAssertFalse(parkedEvents.contains("cancel_returned"), "cancelAndCleanup must not return while the clear is parked")

            // Release the single clear; both joined callers complete only afterwards.
            await clearerGate.open()
            let requireError = await requireTask.value
            await cancelTask.value

            let invocationCount = await clearerGate.invocationCount
            XCTAssertEqual(invocationCount, 1, "the policy clearer must run exactly once for the joined cleanups")
            XCTAssertEqual(joinerCount, 1, "exactly one caller (cancelAndCleanup) must have joined the single in-flight clear")

            let finalEvents = await events.snapshot()
            let clearIndex = finalEvents.firstIndex(of: "clear_completed")
            let requireIndex = finalEvents.firstIndex(of: "require_returned")
            let cancelIndex = finalEvents.firstIndex(of: "cancel_returned")
            XCTAssertNotNil(clearIndex, "the clear must have completed")
            if let clearIndex, let requireIndex {
                XCTAssertLessThan(clearIndex, requireIndex, "requireRouting returned before the shared clear completed")
            }
            if let clearIndex, let cancelIndex {
                XCTAssertLessThan(clearIndex, cancelIndex, "cancelAndCleanup returned before the shared clear completed")
            }
            XCTAssertTrue(
                requireError is MCPBootstrapReadinessError,
                "requireRouting must still surface the readiness error, got \(String(describing: requireError))"
            )

            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }
}

private enum MCPBootstrapLeaseTestError: Error {
    case routingServiceUnavailable
}

private extension MCPBootstrapLeaseTests {
    #if DEBUG
        /// Await the live routing waiter registering at least `atLeast` continuations for `runID`,
        /// polling the DEBUG continuation-count probe with cooperative yields (not a fixed sleep) as
        /// the synchronization signal. Fails the test if the count is not reached before `timeout`.
        func waitForRoutingContinuations(runID: UUID, atLeast: Int, timeout: TimeInterval = 5) async {
            let deadline = Date().addingTimeInterval(timeout)
            while await MCPRoutingWaiter.debugContinuationCount(runID: runID) < atLeast {
                if Date() >= deadline {
                    XCTFail("timed out waiting for \(atLeast) routing continuation(s) for run \(runID)")
                    return
                }
                await Task.yield()
            }
        }

        /// Resets the process-global bootstrap gate and the routing-waiter state for `runID` so each
        /// lease test starts from a clean slate.
        func resetLeaseGlobals(runID: UUID) async {
            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: runID)
        }

        /// Builds a bootstrap lease with the shared agent-mode spec defaults; only the identity,
        /// client name, and policy hooks vary between tests.
        func makeRoutingLease(
            runID: UUID,
            gateID: UUID,
            clientName: String,
            policyInstaller: @escaping (MCPBootstrapLeaseSpec) async -> Void = { _ in },
            policyClearer: @escaping (MCPBootstrapLeaseSpec) async -> Void = { _ in }
        ) -> MCPBootstrapLease {
            MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: gateID,
                    windowID: 1,
                    tabID: UUID(),
                    clientName: clientName,
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "\(clientName) regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                policyInstaller: policyInstaller,
                policyClearer: policyClearer
            )
        }

        /// Asserts the run's routing waiter was torn down and the process-global bootstrap gate is idle.
        func assertRoutingWaiterAndGateCleared(runID: UUID) async {
            let waiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            let activeGate = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(waiterCount, 0, "Routing waiter must be torn down after the lease releases")
            XCTAssertNil(activeGate, "Bootstrap gate must be released after the lease releases")
        }
    #endif

    @MainActor
    static func ensureRoutingService() async throws -> (service: WindowRoutingService, owned: Bool) {
        if let existing = ServiceRegistry.services.first(where: { $0 is WindowRoutingService }) as? WindowRoutingService {
            return (existing, false)
        }
        let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared)
        for _ in 0 ..< 100 {
            let registered = ServiceRegistry.services.contains { $0 as AnyObject === service as AnyObject }
            let names = await service.tools.map(\.name)
            if registered, names.contains("bind_context") {
                return (service, true)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        ServiceRegistry.unregister(service)
        throw MCPBootstrapLeaseTestError.routingServiceUnavailable
    }
}

private actor CleanupEventLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

/// Deterministic gate the joinable-cleanup test injects as the `policyClearer`: it parks the single
/// in-flight clear until the test calls `open()`, and lets the test await first entry without sleeps.
private actor ClearerGate {
    private(set) var invocationCount = 0
    private var hasEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        invocationCount += 1
        hasEntered = true
        for waiter in enteredWaiters {
            waiter.resume()
        }
        enteredWaiters.removeAll()
        if opened {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if hasEntered {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enteredWaiters.append(continuation)
        }
    }

    func open() {
        opened = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }
}

private actor PolicyRecorder {
    private(set) var installCount = 0
    private(set) var armCount = 0
    private(set) var clearCount = 0

    func recordInstall() {
        installCount += 1
    }

    func recordArm() -> Bool {
        armCount += 1
        return true
    }

    func recordClear() {
        clearCount += 1
    }
}

private actor BootstrapPolicyClearGate {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async {
        blocked = true
        let waiters = blockedWaiters
        blockedWaiters = []
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor BootstrapProgressRecorder {
    private var phases: [MCPBootstrapRoutingProgress] = []

    func record(_ phase: MCPBootstrapRoutingProgress) {
        phases.append(phase)
    }

    func snapshot() -> [MCPBootstrapRoutingProgress] {
        phases
    }
}
