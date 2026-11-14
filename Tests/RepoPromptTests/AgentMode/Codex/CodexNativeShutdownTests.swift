import Foundation
import os
import RepoPromptCodexProvider
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class CodexNativeShutdownTests: XCTestCase {
    private enum Observation: Equatable {
        case phase(CodexNativeSessionController.ShutdownPhase)
        case handlerReleased
        case callerReturned
    }

    func testConcurrentAndCancelledRetirementsJoinOneEventDrain() async throws {
        let controller = makeController()
        try await controller.test_beginBindingSession()
        let observations = AsyncStream<Observation>.makeStream()
        let releaseHandler = AsyncStream<Void>.makeStream()
        let handlerEntered = expectation(description: "event handler owns mutex")
        let shutdownJoined = expectation(description: "both retirement callers joined")
        shutdownJoined.expectedFulfillmentCount = 2
        let drainStarted = expectation(description: "shutdown reaches event drain")
        controller.test_shutdownObserver = { phase in
            observations.continuation.yield(.phase(phase))
            switch phase {
            case .joined: shutdownJoined.fulfill()
            case .waitingForEventDrain: drainStarted.fulfill()
            default: break
            }
        }
        let handler = Task {
            await controller.test_withEventHandlingLock {
                handlerEntered.fulfill()
                for await _ in releaseHandler.stream {
                    break
                }
                observations.continuation.yield(.handlerReleased)
            }
        }
        await fulfillment(of: [handlerEntered], timeout: 2)
        let first = Task {
            await controller.shutdown()
            observations.continuation.yield(.callerReturned)
        }
        let second = Task {
            await controller.shutdown()
            observations.continuation.yield(.callerReturned)
        }
        // Cancellation must not skip joining or cancel the shared teardown.
        first.cancel()
        second.cancel()
        await fulfillment(of: [shutdownJoined, drainStarted], timeout: 2)
        do {
            try await controller.test_ensureInboundStreamsStarted()
            XCTFail("Shutdown-time recovery must refuse, not report successful installation")
        } catch let error as CodexSessionControllerError {
            if case .invalidLifecycleState = error {} else {
                XCTFail("Unexpected lifecycle refusal: \(error)")
            }
        } catch {
            XCTFail("Expected lifecycle refusal, not transport failure: \(error)")
        }
        let streamFinished = expectation(description: "event delivery closes before handler drain")
        let eventReader = Task {
            var events = controller.events.makeAsyncIterator()
            let next = await events.next()
            XCTAssertNil(next)
            streamFinished.fulfill()
        }
        await fulfillment(of: [streamFinished], timeout: 2)
        releaseHandler.continuation.yield(())
        releaseHandler.continuation.finish()
        await handler.value
        await first.value
        await second.value
        await eventReader.value
        observations.continuation.finish()
        var recorded: [Observation] = []
        for await event in observations.stream {
            recorded.append(event)
        }
        XCTAssertEqual(recorded.count(where: { $0 == .phase(.joined(isOwner: true)) }), 1)
        XCTAssertEqual(recorded.count(where: { $0 == .phase(.joined(isOwner: false)) }), 1)
        XCTAssertEqual(recorded.count(where: { $0 == .phase(.eventStateCleared) }), 1)
        XCTAssertEqual(recorded.count(where: { $0 == .phase(.finished) }), 1)
        let released = try XCTUnwrap(recorded.firstIndex(of: .handlerReleased))
        let cleared = try XCTUnwrap(recorded.firstIndex(of: .phase(.eventStateCleared)))
        let finished = try XCTUnwrap(recorded.firstIndex(of: .phase(.finished)))
        XCTAssertLessThan(released, cleared)
        XCTAssertLessThan(cleared, finished)
        XCTAssertEqual(recorded.count(where: { $0 == .callerReturned }), 2)
        for index in recorded.indices where recorded[index] == .callerReturned {
            XCTAssertLessThan(finished, index)
        }
    }

    func testRetainedDetachedHostJoinsManagedLogoutWithoutFollowingSameRunSuccessor() async throws {
        let route = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: nil)
        let coordinator = CodexAgentModeCoordinator(
            windowID: route.identity.routeID, runtimeWorkspacePathsProvider: { _ in .uniform(nil) },
            codexControllerFactory: { _, _, _, _, _, _, _, _, _ in preconditionFailure("Logout cannot launch a controller") },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            shouldManageCodexTooling: false, codexHookApprovalSettings: GlobalSettingsStore.shared
        )
        let host = AgentSessionRuntimeHost(
            route: route, codexCoordinator: coordinator,
            claudeCoordinator: .init(windowID: route.identity.routeID, workspacePathProvider: { _ in nil }),
            providerResources: .live(), runRoutingCleaner: { _, _, _ in XCTFail("Logout must use the controller's exact receipt") },
            runToolCanceller: { _, _ in 0 }
        )
        let session = host.scope.makeSession(tabID: UUID())
        host.scope.replaceSessions([session.tabID: session])
        session.selectedAgent = .codexExec
        session.runID = UUID()
        let runID = try XCTUnwrap(session.runID)
        let original = makeController(tabID: session.tabID, runID: runID, windowID: route.identity.routeID)
        let successor = makeController(tabID: session.tabID, runID: runID, windowID: route.identity.routeID)
        try await original.test_beginBindingSession()
        session.codexController = original
        let gate = TestReleaseFence(name: "detached host original event handler")
        let handler = Task { await original.test_withEventHandlingLock { await gate.enterAndWait() } }
        let entered = await gate.waitUntilEntered(timeout: 2)
        XCTAssertTrue(entered)
        let draining = expectation(description: "logout reaches original controller drain")
        original.test_shutdownObserver = { if $0 == .waitingForEventDrain { draining.fulfill() } }
        host.scope.retainExecutableHost()
        addTeardownBlock { @MainActor in
            gate.release()
            await handler.value
            await original.shutdown()
            await successor.shutdown()
            host.scope.replaceSessions([:])
            // This fixture installs no input worker or session after removal. Release its
            // retained census entry via the normal acknowledged drain, not a test force-release.
            let drain = host.beginRetirement(adapters: .init(
                managedInput: AgentSessionHostDrainTestEffects.empty, selfCompact: AgentSessionHostDrainTestEffects.empty,
                captureProvider: { _ in throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
            ))
            drain.attemptRecovery()
            let outcome = await drain.wait(until: .now.advanced(by: .seconds(5)))
            XCTAssertEqual(outcome, .released)
        }
        let participants = WindowStatesManager.managedCodexLogoutParticipants(
            presenters: [], retainedHosts: AgentSessionRuntimeStore.shared.retainedExecutionHosts.filter { $0 === host }
        )
        XCTAssertEqual(participants.count, 1)
        XCTAssertTrue(participants.first === host)
        let fence = CodexManagedSessionFence()
        let originalAuth = try XCTUnwrap(fence.beginAuthenticationAttempt())
        let logoutCalls = OSAllocatedUnfairLock(initialState: 0)
        let logout = CodexManagedLogoutCoordinator(fence: fence, logoutOperation: {
            logoutCalls.withLock { $0 += 1 }
            return .signedOut
        })
        let waiter = Task { await logout.stopSessionsAndSignOut(participants: participants) }
        await fulfillment(of: [draining], timeout: 2)
        XCTAssertEqual(logoutCalls.withLock { $0 }, 0)
        XCTAssertFalse(fence.allowsAuthenticationPublication(originalAuth))
        XCTAssertNil(fence.beginAuthenticationAttempt())
        XCTAssertFalse(host.scope.isRetiring, "Provider logout is not whole-host retirement")
        // Same tab/run IDs do not make the replacement part of the original cleanup receipt.
        let replacement = host.scope.makeSession(tabID: session.tabID)
        replacement.runID = runID
        replacement.selectedAgent = .claudeCode
        replacement.codexController = successor
        host.scope.replaceSessions([replacement.tabID: replacement])
        waiter.cancel()
        gate.release()
        let result = await waiter.value
        XCTAssertEqual(result, .signedOut)
        XCTAssertEqual(logoutCalls.withLock { $0 }, 1)
        XCTAssertTrue(replacement.codexController === successor)
        XCTAssertEqual(replacement.runID, runID)
        XCTAssertFalse(fence.finishAuthentication(token: originalAuth), "A pre-logout credential response cannot authorize a retained host")
        let authenticated = try XCTUnwrap(fence.beginAuthenticationAttempt())
        XCTAssertTrue(fence.finishAuthentication(token: authenticated))
        XCTAssertTrue(fence.allowsCodexSessionInstallation(authenticated))
    }

    func testCoordinatorRetirementReceiptJoinsOriginalControllerNotTabSuccessor() async throws {
        let route = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: nil)
        let runID = UUID()
        let client = "controller-cleanup-\(UUID().uuidString)"
        let manager = ServerNetworkManager.shared
        let coordinator = CodexAgentModeCoordinator(
            windowID: route.identity.routeID, runtimeWorkspacePathsProvider: { _ in .uniform(nil) },
            codexControllerFactory: { _, _, _, _, _, _, _, _, _ in
                preconditionFailure("Retirement must not create a controller")
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            shouldManageCodexTooling: true, codexHookApprovalSettings: GlobalSettingsStore.shared
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        let original = makeController(tabID: session.tabID, runID: runID, windowID: route.identity.routeID)
        let successor = makeController(tabID: session.tabID, runID: runID, windowID: route.identity.routeID)
        try await original.test_beginBindingSession()
        try await successor.test_beginBindingSession()
        let originalGate = TestReleaseFence(name: "original controller event drain")
        let successorGate = TestReleaseFence(name: "successor controller event drain")
        defer { originalGate.release()
            successorGate.release()
        }
        let originalHandler = Task { await original.test_withEventHandlingLock { await originalGate.enterAndWait() } }
        let successorHandler = Task { await successor.test_withEventHandlingLock { await successorGate.enterAndWait() } }
        let originalEntered = await originalGate.waitUntilEntered(timeout: 2)
        let successorEntered = await successorGate.waitUntilEntered(timeout: 2)
        XCTAssertTrue(originalEntered)
        XCTAssertTrue(successorEntered)
        let originalFinished = OSAllocatedUnfairLock(initialState: false)
        let successorFinished = OSAllocatedUnfairLock(initialState: false)
        let draining = expectation(description: "original shutdown waits for its event handler")
        original.test_shutdownObserver = { phase in
            if phase == .waitingForEventDrain { draining.fulfill() }
            if phase == .finished { originalFinished.withLock { $0 = true } }
        }
        successor.test_shutdownObserver = { phase in
            if phase == .finished { successorFinished.withLock { $0 = true } }
        }
        let previousRegistration = await manager.installClientConnectionPolicy(
            for: client, windowID: route.identity.routeID, restrictedTools: [], runID: runID,
            purpose: .agentModeRun, routingOwner: route
        )
        let previousCleanup = try XCTUnwrap(previousRegistration)
        XCTAssertTrue(original.retainRoutingCleanup(previousCleanup))
        let originalRegistration = await manager.installClientConnectionPolicy(
            for: client, windowID: route.identity.routeID, restrictedTools: [], runID: runID,
            purpose: .agentModeRun, routingOwner: route
        )
        let originalCleanup = try XCTUnwrap(originalRegistration)
        XCTAssertTrue(original.retainRoutingCleanup(originalCleanup))
        XCTAssertTrue(original.retainRoutingCleanup(originalCleanup), "Repeated handoff is idempotent")
        let originalPIDRegistrar = CodexAppServerClient.ExpectedAgentPIDRegistrar.serverNetworkManager(registration: originalCleanup)
        await originalPIDRegistrar.register(12345, client, runID)
        await coordinator.ensureCodexToolTrackingIfNeeded(for: session, runID: runID)
        XCTAssertNil(coordinator.codexControllerRetirementReceipt(for: original))
        let receipt = coordinator.retireCodexController(original, tabID: session.tabID, source: "receipt-test")
        session.codexController = original
        let teardown = try XCTUnwrap(coordinator.prepareCodexCancellationTeardown(session, expectedRunID: runID, capturedTarget: nil))
        XCTAssertNil(session.codexController)
        session.codexController = successor
        let successorRegistration = await manager.installClientConnectionPolicy(
            for: client, windowID: route.identity.routeID, restrictedTools: ["edit_file"], runID: runID,
            purpose: .agentModeRun, routingOwner: route
        )
        let successorCleanup = try XCTUnwrap(successorRegistration)
        XCTAssertTrue(successor.retainRoutingCleanup(successorCleanup))
        let successorPIDRegistrar = CodexAppServerClient.ExpectedAgentPIDRegistrar.serverNetworkManager(registration: successorCleanup)
        await successorPIDRegistrar.register(12345, client, runID)
        await originalPIDRegistrar.clear(12345, client, runID)
        await originalPIDRegistrar.register(12346, client, runID)
        let survivingPIDs = await manager.debugExpectedAgentPIDs(for: client, runID: runID)
        XCTAssertEqual(survivingPIDs, [12345], "Same-run replacement must keep its PID when original registration and cleanup arrive late")
        await coordinator.ensureCodexToolTrackingIfNeeded(for: session, runID: runID)
        let registeredObservers = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
        XCTAssertEqual(registeredObservers, 2)
        let successorReceipt = coordinator.retireCodexController(successor, tabID: session.tabID, source: "successor-test")
        let repeated = coordinator.retireCodexController(original, tabID: session.tabID, source: "repeat-test")
        XCTAssertEqual(receipt.generation, repeated.generation)
        XCTAssertNotEqual(receipt.generation, successorReceipt.generation)
        XCTAssertTrue(receipt.controller === original)
        XCTAssertEqual(receipt.tabID, session.tabID)
        let joined = expectation(description: "cancelled waiter joins original shutdown, not successor")
        var returned = false
        let waiter = Task {
            await teardown()
            await repeated.waitForCompletion()
            XCTAssertTrue(originalFinished.withLock { $0 }, "Only actual shutdown completion acknowledges the receipt")
            returned = true
            joined.fulfill()
        }
        waiter.cancel()
        await fulfillment(of: [draining], timeout: 2)
        XCTAssertFalse(returned)
        XCTAssertFalse(originalFinished.withLock { $0 })
        originalGate.release()
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertFalse(successorFinished.withLock { $0 }, "The original receipt must not wait for a later tab retirement")
        XCTAssertTrue(session.codexController === successor, "Originating cleanup must not clear the successor")
        let survivingPolicy = await manager.debugRunPolicyState(for: runID)
        XCTAssertEqual(survivingPolicy?.restrictedTools, ["edit_file"])
        XCTAssertTrue(previousCleanup.isConsumed, "Shutdown joins cleanup of a registration replaced on the same controller")
        XCTAssertTrue(originalCleanup.isConsumed)
        XCTAssertFalse(successorCleanup.isConsumed)
        XCTAssertFalse(original.retainRoutingCleanup(successorCleanup), "A shutting-down controller cannot take successor cleanup")
        let survivingObservers = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
        XCTAssertEqual(survivingObservers, 1, "Cancellation joins only the original tracker, even when tab and run IDs are reused")
        let completedRepeat = coordinator.retireCodexController(original, tabID: session.tabID, source: "completed-repeat-test")
        XCTAssertEqual(completedRepeat.generation, receipt.generation)
        XCTAssertEqual(coordinator.codexControllerRetirementReceipt(for: original)?.generation, receipt.generation)
        XCTAssertEqual(coordinator.codexControllerRetirementReceipt(for: successor)?.generation, successorReceipt.generation)
        await completedRepeat.waitForCompletion()
        let detached = try XCTUnwrap(coordinator.detachForWorkspaceSwitchFinalizeSync(session, runIDs: [runID]))
        await coordinator.ensureCodexToolTrackingIfNeeded(for: session, runID: runID)
        successorGate.release()
        await successorReceipt.waitForCompletion()
        await coordinator.retireDetachedControllerForWorkspaceSwitch(detached)
        let afterDetachedCleanup = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
        XCTAssertEqual(afterDetachedCleanup, 1, "Detached provider cleanup must not sweep the successor's observer")
        let finalTracking = try XCTUnwrap(coordinator.detachForWorkspaceSwitchFinalizeSync(session, runIDs: [runID]))
        await coordinator.retireDetachedControllerForWorkspaceSwitch(finalTracking)
        let afterOriginCleanup = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
        XCTAssertEqual(afterOriginCleanup, 0)
        await waiter.value
        await originalHandler.value
        await successorHandler.value
        XCTAssertTrue(successorFinished.withLock { $0 })
        XCTAssertTrue(successorCleanup.isConsumed)
        let finalPolicy = await manager.debugRunPolicyState(for: runID)
        XCTAssertNil(finalPolicy, "Positive shutdown completion includes originating registration cleanup")
        let finalPIDs = await manager.debugExpectedAgentPIDs(for: client)
        XCTAssertTrue(finalPIDs.isEmpty)
        await route.close()
    }

    func testTerminatedControllerStillCleansUpOnceAndReleasesItsShutdownTaskCapture() async throws {
        weak var releasedController: CodexNativeSessionController?
        let observations = AsyncStream<CodexNativeSessionController.ShutdownPhase>.makeStream()
        let client = CodexAppServerClient(writeFrameHandler: { _, _ in }, livenessProbe: { _ in true })
        await client.debugInstallTestTransport()
        let originalGeneration = await client.healthyTransportGeneration()
        XCTAssertNotNil(originalGeneration)
        do {
            let controller = CodexNativeSessionController(
                client: client, runID: UUID(), tabID: UUID(), windowID: 1,
                workspacePaths: .uniform(nil), clientShutdownBehavior: .stopOnShutdown
            )
            releasedController = controller
            controller.test_shutdownObserver = { observations.continuation.yield($0) }
            try await controller.test_beginBindingSession()
            await controller.test_simulateTransportStreamEnded(source: "shutdown-owner-test")
            await controller.shutdown()
            await controller.shutdown()
        }
        XCTAssertNil(releasedController, "The stored completed task must not retain its controller")
        let stoppedGeneration = await client.healthyTransportGeneration()
        XCTAssertNil(stoppedGeneration, "A transport-ended controller still owns explicit client cleanup")
        observations.continuation.finish()
        var recorded: [CodexNativeSessionController.ShutdownPhase] = []
        for await phase in observations.stream {
            recorded.append(phase)
        }
        XCTAssertEqual(recorded.count(where: { $0 == .joined(isOwner: true) }), 1)
        XCTAssertEqual(recorded.count(where: { $0 == .joined(isOwner: false) }), 1)
        XCTAssertEqual(recorded.count(where: { $0 == .eventStateCleared }), 1)
        XCTAssertEqual(recorded.count(where: { $0 == .finished }), 1)
    }

    private func makeController(tabID: UUID = UUID(), runID: UUID = UUID(), windowID: Int = 1) -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: runID,
            tabID: tabID,
            windowID: windowID,
            workspacePaths: .uniform(nil)
        )
    }
}
