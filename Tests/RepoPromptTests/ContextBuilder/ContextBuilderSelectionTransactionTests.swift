import Foundation
import MCP
import os
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
@testable import RepoPromptMCPServer
import RepoPromptSettingsCore
@testable import RepoPromptWorkspaceContext
import XCTest

@MainActor
final class MCPHostRouteResourceTests: XCTestCase {
    func testHostIdentityDoesNotBecomeTheLatestPresentationWindow() {
        let window = MCPRouteIdentityAllocator.allocateWindowID()
        let first = MCPRouteIdentityAllocator.allocateHost()
        let second = MCPRouteIdentityAllocator.allocateHost()
        XCTAssertEqual(WindowState.latestWindowID(), window)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertLessThan(window, first.routeID)
        XCTAssertLessThan(first.routeID, second.routeID)
        XCTAssertGreaterThan(MCPRouteIdentityAllocator.allocateWindowID(), second.routeID)
    }

    func testPendingMappingRollbackDoesNotResurrectConsumedOrigin() async throws {
        let manager = ServerNetworkManager.shared
        for reuseConnection in [false, true] {
            for retireOrigin in [false, true] {
                let route = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: nil)
                let runID = UUID(), originalConnection = UUID()
                let replacementConnection = reuseConnection ? originalConnection : UUID()
                let client = "rollback-cleanup-\(UUID().uuidString)"
                let first = await manager.installClientConnectionPolicy(
                    for: client, windowID: route.identity.routeID, restrictedTools: [], runID: runID,
                    purpose: .agentModeRun, routingOwner: route
                )
                let original = try XCTUnwrap(first)
                XCTAssertEqual(route.runRouteBindings.register(
                    connectionID: originalConnection, runID: runID, windowID: route.identity.routeID, cleanupReceipt: original
                ), .registered(displacedConnectionID: nil))
                let second = await manager.installClientConnectionPolicy(
                    for: client, windowID: route.identity.routeID, restrictedTools: [], runID: runID,
                    purpose: .agentModeRun, routingOwner: route
                )
                let replacement = try XCTUnwrap(second)
                let pending = try XCTUnwrap(route.runRouteBindings.beginPendingPolicy(
                    connectionID: replacementConnection, runID: runID, windowID: route.identity.routeID,
                    cleanupReceipt: replacement
                ))
                if retireOrigin { await manager.cleanupRunRoutingState(ownedBy: original) }
                XCTAssertTrue(route.runRouteBindings.rollback(pending, removingContext: {}))
                XCTAssertEqual(route.runRouteBindings.connectionID(forRunID: runID), retireOrigin ? nil : originalConnection)
                await manager.cleanupRunRoutingState(ownedBy: original)
                await manager.cleanupRunRoutingState(ownedBy: replacement)
                XCTAssertNil(route.runRouteBindings.connectionID(forRunID: runID))
                XCTAssertEqual(route.runRouteBindings.register(
                    connectionID: originalConnection, runID: runID, windowID: route.identity.routeID, cleanupReceipt: original
                ), .refusedOwnerUnavailable, "A consumed receipt cannot reinstall its mapping")
                await route.close()
            }
        }
    }

    func testOwnedBootstrapCleanupDoesNotNeedFreshCommandAuthorityOrFollowSuccessor() async throws {
        let manager = ServerNetworkManager.shared
        let route = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: nil)
        let runID = UUID(), tabID = UUID()
        let spec = MCPBootstrapLeaseSpec.agentMode(
            tabID: tabID, runID: runID, gateID: UUID(), windowID: route.identity.routeID, agent: .codexExec
        )
        let originalCommandIsCurrent = OSAllocatedUnfairLock(initialState: true)
        let original = MCPBootstrapLease(spec: spec, routingStateOwner: { originalCommandIsCurrent.withLock { $0 } }, routingOwner: route)
        let originalAcquired = await original.acquire()
        XCTAssertTrue(originalAcquired)
        let firstGeneration = await MCPRoutingWaiter.generation(runID: runID)
        let firstReceipts = await original.originatingRoutingCleanupReceipts()
        let firstReceipt = try XCTUnwrap(firstReceipts?.last)
        // A failed process can finish its exact shutdown before this still-acquired lease
        // launches a replacement. Its retired waiter is not reusable by the new process.
        await manager.cleanupRunRoutingState(ownedBy: firstReceipt)
        let reinstalled = await original.reinstallPolicyForReplacementProcess()
        XCTAssertTrue(reinstalled)
        let originalGeneration = await MCPRoutingWaiter.generation(runID: runID)
        XCTAssertNotNil(originalGeneration)
        XCTAssertNotEqual(firstGeneration, originalGeneration)
        let renewedReceipts = await original.originatingRoutingCleanupReceipts()
        XCTAssertEqual(renewedReceipts?.count, 1)
        XCTAssertNotEqual(renewedReceipts?.last?.policyID, firstReceipt.policyID)
        let oldExecution = UUID(), newExecution = UUID(), localExecution = UUID()
        var oldCancellationCount = 0
        var newCancellationCount = 0
        var localCancellationCount = 0
        try route.toolExecutionRuntime.registerToolExecution(
            executionID: oldExecution, runID: runID, connectionID: nil, toolName: "old-policy",
            runRoutingRegistrationID: XCTUnwrap(renewedReceipts?.last).policyID,
            cancel: { oldCancellationCount += 1 }
        )
        route.toolExecutionRuntime.registerToolExecution(
            executionID: localExecution, runID: runID, connectionID: nil, toolName: "trusted-local",
            cancel: { localCancellationCount += 1 }
        )
        await manager.cleanupRunRoutingState(ownedBy: firstReceipt)
        let waiterAfterRepeatedProcessCleanup = await MCPRoutingWaiter.generation(runID: runID)
        XCTAssertEqual(waiterAfterRepeatedProcessCleanup, originalGeneration)
        let replacementSpec = MCPBootstrapLeaseSpec.agentMode(
            tabID: tabID, runID: runID, gateID: UUID(), windowID: route.identity.routeID, agent: .codexExec
        )
        let replacement = MCPBootstrapLease(spec: replacementSpec, routingOwner: route)
        let replacementAcquired = await replacement.acquire()
        XCTAssertTrue(replacementAcquired)
        let replacementGeneration = await MCPRoutingWaiter.generation(runID: runID)
        XCTAssertNotEqual(originalGeneration, replacementGeneration)
        let replacementReceipts = await replacement.originatingRoutingCleanupReceipts()
        try route.toolExecutionRuntime.registerToolExecution(
            executionID: newExecution, runID: runID, connectionID: nil, toolName: "successor-policy",
            runRoutingRegistrationID: XCTUnwrap(replacementReceipts?.last).policyID,
            cancel: { newCancellationCount += 1 }
        )
        originalCommandIsCurrent.withLock { $0 = false }
        let cancelledWaiter = Task { await original.cancelAndCleanup() }
        cancelledWaiter.cancel()
        await cancelledWaiter.value
        await original.cancelAndCleanup()
        let policyAfterOldCleanup = await manager.debugRunPolicyState(for: runID)
        let waiterAfterOldCleanup = await MCPRoutingWaiter.generation(runID: runID)
        XCTAssertNotNil(policyAfterOldCleanup)
        XCTAssertEqual(waiterAfterOldCleanup, replacementGeneration)
        XCTAssertEqual(oldCancellationCount, 1)
        XCTAssertEqual(newCancellationCount, 0)
        XCTAssertEqual(localCancellationCount, 0)
        XCTAssertFalse(route.toolExecutionRuntime.containsExecution(oldExecution))
        XCTAssertTrue(route.toolExecutionRuntime.containsExecution(newExecution))
        let oldOutcome = await original.currentRoutingTerminalOutcome()
        XCTAssertEqual(oldOutcome, .failed(.cleanedUp))
        await replacement.cancelAndCleanup()
        let finalPolicy = await manager.debugRunPolicyState(for: runID)
        let finalWaiter = await MCPRoutingWaiter.generation(runID: runID)
        XCTAssertNil(finalPolicy)
        XCTAssertNil(finalWaiter)
        XCTAssertEqual(newCancellationCount, 1)
        XCTAssertEqual(localCancellationCount, 0, "An unqualified invocation is not owned by a provider registration")
        route.toolExecutionRuntime.unregisterToolExecution(executionID: localExecution)
        await route.close()
    }

    func testOwnedProviderLifetimeCleanupJoinsBootstrapProducerWithoutFollowingSuccessor() async {
        let manager = ServerNetworkManager.shared
        let route = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: nil)
        let runID = UUID(), tabID = UUID()
        let gate = TestReleaseFence(name: "originating bootstrap enabler")
        defer { gate.release() }
        let enabler = Task {
            await gate.enterAndWait()
            return true
        }
        let cancellationObserved = expectation(description: "lifetime cleanup stopped originating acquisition")
        let original = MCPBootstrapLease(
            spec: .agentMode(tabID: tabID, runID: runID, gateID: UUID(), windowID: route.identity.routeID, agent: .codexExec),
            mcpServerEnabler: {
                await withTaskCancellationHandler {
                    await enabler.value
                } onCancel: {
                    cancellationObserved.fulfill()
                }
            },
            routingOwner: route
        )
        let acquisition = Task { await original.acquire() }
        await gate.waitUntilEntered()
        let successor = MCPBootstrapLease(
            spec: .agentMode(tabID: tabID, runID: runID, gateID: UUID(), windowID: route.identity.routeID, agent: .codexExec),
            routingOwner: route
        )
        let acquired = await successor.acquire()
        XCTAssertTrue(acquired)
        let successorGeneration = await MCPRoutingWaiter.generation(runID: runID)
        let completed = OSAllocatedUnfairLock(initialState: false)
        let cleanup = Task {
            await original.finishOwnedProviderRouting()
            completed.withLock { $0 = true }
        }
        await fulfillment(of: [cancellationObserved], timeout: 10)
        cleanup.cancel()
        XCTAssertFalse(completed.withLock { $0 }, "Cancellation is not completion of the original acquisition")
        gate.release()
        await cleanup.value
        let originalAcquired = await acquisition.value
        XCTAssertFalse(originalAcquired)
        await original.finishOwnedProviderRouting()
        let survivingPolicy = await manager.debugRunPolicyState(for: runID)
        let survivingGeneration = await MCPRoutingWaiter.generation(runID: runID)
        XCTAssertNotNil(survivingPolicy)
        XCTAssertEqual(survivingGeneration, successorGeneration)
        // A successful attempt may already have released its waiter. Provider lifetime cleanup
        // must still consume that provider's policy rather than treating hasReleased as complete.
        await successor.releaseWithoutRoutingWait()
        await successor.finishOwnedProviderRouting()
        await successor.finishOwnedProviderRouting()
        let finalPolicy = await manager.debugRunPolicyState(for: runID)
        let finalGeneration = await MCPRoutingWaiter.generation(runID: runID)
        XCTAssertNil(finalPolicy)
        XCTAssertNil(finalGeneration)
        await route.close()
    }

    func testLegacyCleanupSuspendedBeforeReplacementCannotConsumeSuccessor() async throws {
        let manager = ServerNetworkManager.shared
        for independentSuccessor in [false, true] {
            let route = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: nil)
            let runID = UUID(), connectionID = UUID()
            let client = "legacy-cleanup-race-\(UUID().uuidString)"
            _ = await MCPRoutingWaiter.registerOwned(runID: runID)
            _ = await manager.installClientConnectionPolicy(
                for: client, windowID: route.identity.routeID, restrictedTools: [], runID: runID,
                purpose: .agentModeRun
            )
            let oldTracker = AgentToolTracker()
            _ = await oldTracker.registerEnhancedObserver(runID: runID, onCalled: { _, _, _ in }, onCompleted: { _, _, _, _, _ in })
            let gate = TestReleaseFence(name: "legacy cleanup before replacement")
            defer { gate.release() }
            await manager.debugSetAfterLegacyCleanupWaiterCapture { candidate in
                if candidate == runID { await gate.enterAndWait() }
            }
            let oldCleanup = Task {
                await AgentSessionRuntimeHost.cleanRunRouting(.legacyWindow(runID: runID), routeID: route.identity.routeID, reason: "legacy_cleanup_fixture")
            }
            await gate.waitUntilEntered()
            let successorWait = await MCPRoutingWaiter.registerOwned(runID: runID)
            let newTracker = AgentToolTracker()
            _ = await newTracker.registerEnhancedObserver(runID: runID, onCalled: { _, _, _ in }, onCompleted: { _, _, _, _, _ in })
            let installed = await manager.installClientConnectionPolicy(
                for: client, windowID: route.identity.routeID, restrictedTools: ["edit_file"], runID: runID,
                purpose: .agentModeRun, routingOwner: independentSuccessor ? route : nil,
                routingWaitGeneration: successorWait
            )
            let successor = try XCTUnwrap(installed)
            await manager.debugSeedConnectionRunRouting(
                connectionID: connectionID, runID: runID, windowID: route.identity.routeID, registration: successor
            )
            XCTAssertEqual(route.runRouteBindings.register(
                connectionID: connectionID, runID: runID, windowID: route.identity.routeID,
                cleanupReceipt: independentSuccessor ? successor : nil
            ), .registered(displacedConnectionID: nil))
            XCTAssertEqual(route.runRouteBindings.allowsLegacyCleanup(runID: runID, connectionID: connectionID), !independentSuccessor)
            gate.release()
            await oldCleanup.value
            await manager.debugSetAfterLegacyCleanupWaiterCapture(nil)
            let policy = await manager.debugRunPolicyState(for: runID)
            let cachedRun = await manager.debugCachedRunID(for: connectionID)
            let pending = await manager.debugPendingPolicySnapshot(for: client)
            let waiter = await MCPRoutingWaiter.generation(runID: runID)
            XCTAssertEqual(policy?.restrictedTools, ["edit_file"])
            XCTAssertEqual(cachedRun, runID)
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(waiter, successorWait)
            await oldTracker.stop()
            let observerCount = await manager.toolEventObserverCount(for: runID)
            XCTAssertEqual(observerCount, 1, "Legacy cleanup cannot retract the successor's observer after suspension")
            XCTAssertEqual(route.runRouteBindings.connectionID(forRunID: runID), connectionID)
            await newTracker.stop()
            if independentSuccessor {
                await manager.cleanupRunRoutingState(ownedBy: successor)
            } else {
                await manager.cleanupRunRoutingState(for: runID, windowID: route.identity.routeID)
                await MCPRoutingWaiter.cleanup(runID: runID, generation: successorWait)
            }
            await route.close()
        }
    }

    func testPolicyCleanupRetainsOriginalRegistrationAcrossReplacementAndRouteClose() async throws {
        let manager = ServerNetworkManager.shared
        let identity = MCPRouteIdentityAllocator.allocateHost()
        let original = MCPHostRouteResources(identity: identity, coordinator: nil)
        let runID = UUID(), connectionID = UUID()
        let client = "host-cleanup-\(UUID().uuidString)"
        let oldWait = await MCPRoutingWaiter.registerOwned(runID: runID)
        let installed = await manager.installClientConnectionPolicy(
            for: client, windowID: identity.routeID, restrictedTools: [], runID: runID,
            purpose: .agentModeRun, routingOwner: original, routingWaitGeneration: oldWait
        )
        let oldReceipt = try XCTUnwrap(installed)
        XCTAssertEqual(original.runRouteBindings.register(
            connectionID: connectionID, runID: runID, windowID: identity.routeID, cleanupReceipt: oldReceipt
        ), .registered(displacedConnectionID: nil))
        await manager.debugSeedConnectionRunRouting(connectionID: connectionID, runID: runID, windowID: identity.routeID, registration: oldReceipt)
        let oldTracker = AgentToolTracker()
        _ = await oldTracker.registerEnhancedObserver(runID: runID, onCalled: { _, _, _ in }, onCompleted: { _, _, _, _, _ in })

        // Reuse both IDs on a different resource incarnation, while the original provider still
        // retains its policy receipt and observer token. There is no presentation window fixture.
        await original.close()
        let successor = MCPHostRouteResources(identity: identity, coordinator: nil)
        let newWait = await MCPRoutingWaiter.registerOwned(runID: runID)
        let replacement = await manager.installClientConnectionPolicy(
            for: client, windowID: identity.routeID, restrictedTools: ["edit_file"], runID: runID,
            purpose: .agentModeRun, routingOwner: successor, routingWaitGeneration: newWait
        )
        let newReceipt = try XCTUnwrap(replacement)
        XCTAssertNotEqual(oldReceipt.policyID, newReceipt.policyID)
        XCTAssertNotEqual(oldWait, newWait)
        XCTAssertEqual(successor.runRouteBindings.register(
            connectionID: connectionID, runID: runID, windowID: identity.routeID, cleanupReceipt: newReceipt
        ), .registered(displacedConnectionID: nil))
        await manager.debugSeedConnectionRunRouting(connectionID: connectionID, runID: runID, windowID: identity.routeID, registration: newReceipt)
        let newTracker = AgentToolTracker()
        _ = await newTracker.registerEnhancedObserver(runID: runID, onCalled: { _, _, _ in }, onCompleted: { _, _, _, _, _ in })
        await oldTracker.stop()
        await manager.cleanupRunRoutingState(for: runID, windowID: identity.routeID)
        await manager.revokeClientConnectionPolicy(for: client, windowID: identity.routeID, runID: runID)
        await manager.clearClientConnectionPolicy(for: client, windowID: identity.routeID, runID: runID)
        await manager.cleanupRunRoutingState(ownedBy: oldReceipt)
        await manager.cleanupRunRoutingState(ownedBy: oldReceipt)
        XCTAssertNil(original.runRouteBindings.connectionID(forRunID: runID))
        XCTAssertEqual(successor.runRouteBindings.connectionID(forRunID: runID), connectionID)
        let cachedRun = await manager.debugCachedRunID(for: connectionID)
        let policy = await manager.debugRunPolicyState(for: runID)
        let pending = await manager.debugPendingPolicySnapshot(for: client)
        let observers = await manager.toolEventObserverCount(for: runID)
        let remainingWait = await MCPRoutingWaiter.generation(runID: runID)
        XCTAssertEqual(cachedRun, runID)
        XCTAssertEqual(policy?.restrictedTools, ["edit_file"])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(observers, 1, "Delayed old-provider teardown must preserve the successor observer")
        XCTAssertEqual(remainingWait, newWait)

        await newTracker.stop()
        await manager.cleanupRunRoutingState(ownedBy: newReceipt)
        await manager.cleanupRunRoutingState(ownedBy: newReceipt)
        XCTAssertNil(successor.runRouteBindings.connectionID(forRunID: runID))
        let finalRun = await manager.debugCachedRunID(for: connectionID)
        let finalPolicy = await manager.debugRunPolicyState(for: runID)
        let finalPending = await manager.debugPendingPolicySnapshot(for: client)
        let finalObservers = await manager.toolEventObserverCount(for: runID)
        let finalWait = await MCPRoutingWaiter.generation(runID: runID)
        XCTAssertNil(finalRun)
        XCTAssertNil(finalPolicy)
        XCTAssertTrue(finalPending.isEmpty)
        XCTAssertEqual(finalObservers, 0)
        XCTAssertNil(finalWait)
        await successor.close()
    }

    func testWithdrawalRefusesNewMappingsButDoesNotCancelTrackedTools() async throws {
        let owner = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: nil)
        let run = UUID(), connection = UUID(), execution = UUID()
        let pending = try XCTUnwrap(owner.runRouteBindings.beginPendingPolicy(connectionID: connection, runID: run, windowID: owner.identity.routeID))
        var cancellations = 0
        owner.toolExecutionRuntime.registerToolExecution(executionID: execution, runID: run, connectionID: connection, toolName: "read_file") { cancellations += 1 }
        owner.closeDomainAdmission()
        XCTAssertTrue(owner.runRouteBindings.isCurrent(pending), "Legacy domain close must not withdraw the run's mapping owner before drain")
        await owner.close()
        XCTAssertFalse(owner.runRouteBindings.hasCurrentMapping(runID: run, connectionID: connection))
        XCTAssertEqual(owner.runRouteBindings.register(connectionID: UUID(), runID: run, windowID: owner.identity.routeID), .refusedOwnerUnavailable)
        XCTAssertNil(owner.runRouteBindings.beginPendingPolicy(connectionID: UUID(), runID: run, windowID: owner.identity.routeID))
        XCTAssertEqual(cancellations, 0)
        XCTAssertTrue(owner.toolExecutionRuntime.containsExecution(execution))
        XCTAssertTrue(owner.runRouteBindings.rollback(pending, removingContext: {}))
        owner.toolExecutionRuntime.unregisterToolExecution(executionID: execution)
        try await owner.toolExecutionRuntime.awaitNoActiveToolExecutions(runID: run)
        XCTAssertEqual(owner.toolExecutionRuntime.activeExecutionCount, 0)
    }

    func testWindowFreeDomainRouteKeepsItsOriginalConnectionGenerationOnClose() async throws {
        let runtime = try await makeRuntime()
        let windowCount = WindowState.windowCounter
        let owner = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime)
        owner.scheduleRegistration(workspaceID: nil, contextID: nil, revision: 0)
        let descriptor = await owner.ensureRegistered(workspaceID: nil, contextID: nil, revision: 0)
        XCTAssertEqual(descriptor?.windowID, owner.identity.routeID)
        XCTAssertEqual(WindowState.windowCounter, windowCount)
        let connectionID = UUID()
        let context = MCPTabContextSnapshot(
            tabID: UUID(), windowID: owner.identity.routeID, workspaceID: nil,
            promptText: "", selection: .init(), selectedMetaPromptIDs: [], tabName: "Host",
            runID: nil, explicitlyBound: true
        )
        owner.publishBinding(connectionID: connectionID, context: context)
        await owner.settleRoutingPublications()
        let published = await runtime.routingCoordinator.snapshot()
        let receipt = try XCTUnwrap(published.connections.first { $0.registration.connectionID == connectionID }?.registration)
        XCTAssertEqual(published.windows.first?.activeContextID, context.tabID)
        _ = await runtime.routingCoordinator.unregisterConnection(receipt, operationID: UUID())
        let replacement = await runtime.routingCoordinator.registerConnection(connectionID: connectionID, operationID: UUID())
        let successor = try XCTUnwrap(replacement.snapshot.connections.first { $0.registration.connectionID == connectionID }?.registration)
        XCTAssertNotEqual(successor, receipt)
        let pendingConnection = UUID()
        owner.publishBinding(connectionID: pendingConnection, context: context)
        await owner.closeDomainRoute()
        await owner.closeDomainRoute()
        let final = await runtime.routingCoordinator.snapshot()
        XCTAssertFalse(final.windows.contains { $0.windowID == owner.identity.routeID })
        XCTAssertFalse(final.connections.contains { $0.registration.connectionID == pendingConnection }, "Close joins queued publications without resurrecting a route")
        XCTAssertTrue(final.connections.contains { $0.registration == successor }, "Old owner must never retract a replacement registration")
        let refused = await owner.ensureRegistered(workspaceID: nil, contextID: nil, revision: 0)
        XCTAssertNil(refused)
    }

    func testWindowFreeRouteLookupPinsDispatchAcrossReplacementAndLateClose() async throws {
        let runtime = try await makeRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let app = AppDomainRuntimeComposition.shared
            let network = ServerNetworkManager.shared
            let before = WindowState.windowCounter
            let owner = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime)
            let routeID = owner.identity.routeID
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "read_file"))
            @MainActor func catalog() -> MCPAppToolCatalogRegistration {
                let binder = MCPAppToolBinder(windowID: routeID) { name, _, arguments, implementation in
                    try await implementation(.init(toolName: name, windowID: routeID, context: .trustedLocal(
                        toolName: name, metadata: .init(connectionID: nil, clientName: nil, windowID: routeID)
                    )), arguments)
                }
                return MCPAppToolCatalogRegistration(
                    windowID: routeID, providers: [],
                    sharedBindings: [MCPDomainToolBinding(definition: definition) { _ in .bool(true) }],
                    runtime: binder, requiredToolNames: ["read_file"]
                )
            }
            let successor = MCPHostRouteResources(
                identity: .init(id: UUID(), routeID: routeID, kind: .independent), coordinator: runtime.routingCoordinator, runtime: runtime
            )
            do {
                _ = await owner.ensureRegistered(workspaceID: nil, contextID: nil, revision: 0)
                let handle = try await owner.registerCatalog(catalog())
                guard case let .available(found) = await app.independentRouteResources(routeID: routeID) else {
                    XCTFail("Independent owner was not registered")
                    await owner.close()
                    await successor.close()
                    return
                }
                XCTAssertTrue(found === owner)
                XCTAssertNil(WindowStatesManager.shared.window(withID: routeID))
                let captured = await network.captureWindowToolDispatchIdentity(windowID: routeID, catalogRegistrationHandle: handle)
                let dispatch = try XCTUnwrap(captured)
                let valid = await network.isCurrentWindowToolDispatchIdentity(dispatch, expectedServerViewModelIdentity: ObjectIdentifier(owner))
                XCTAssertTrue(valid)
                let runID = UUID(), connectionID = UUID()
                // Independent mapping remains disabled until its originating cleanup is migrated.
                let mapped = await network.mapConnectionToRunID(connectionID, runID: runID, windowID: routeID, signalRouting: false)
                XCTAssertFalse(mapped)
                XCTAssertNil(owner.runRouteBindings.connectionID(forRunID: runID))
                let context = MCPTabContextSnapshot(
                    tabID: UUID(), windowID: routeID, workspaceID: nil, promptText: "", selection: .init(),
                    selectedMetaPromptIDs: [], tabName: "Host", runID: runID, explicitlyBound: true
                )
                owner.publishBinding(connectionID: connectionID, context: context)
                await owner.settleRoutingPublications()
                let originalConnection = try await runtime.routingCoordinator.currentRegistration(connectionID: connectionID)

                // Replace domain and catalog generations without running the old owner's cleanup.
                // Its delayed teardown must not remove the new lookup, catalog or route descriptor.
                _ = await runtime.toolRegistry.unregister(handle)
                _ = await successor.ensureRegistered(workspaceID: nil, contextID: nil, revision: 0)
                let successorHandle = try await successor.registerCatalog(catalog())
                _ = await runtime.routingCoordinator.unregisterConnection(originalConnection, operationID: UUID())
                successor.publishBinding(connectionID: connectionID, context: context)
                await successor.settleRoutingPublications()
                let replacementConnection = try await runtime.routingCoordinator.currentRegistration(connectionID: connectionID)
                XCTAssertNotEqual(originalConnection, replacementConnection)
                app.recordRouteResources(owner, in: runtime) // A late old registration cannot replace the newer generation.
                let stale = await network.isCurrentWindowToolDispatchIdentity(dispatch)
                XCTAssertFalse(stale)
                let successorDispatch = await network.captureWindowToolDispatchIdentity(windowID: routeID, catalogRegistrationHandle: successorHandle)
                XCTAssertNotNil(successorDispatch)
                let wrongHandle = await network.captureWindowToolDispatchIdentity(windowID: routeID, catalogRegistrationHandle: handle)
                XCTAssertNil(wrongHandle)
                await owner.close()
                guard case let .available(stillFound) = await app.independentRouteResources(routeID: routeID) else {
                    XCTFail("Late close removed the successor owner")
                    await successor.close()
                    return
                }
                XCTAssertTrue(stillFound === successor)
                let retainedConnection = try await runtime.routingCoordinator.currentRegistration(connectionID: connectionID)
                XCTAssertEqual(retainedConnection, replacementConnection)
                let stillActive = await successor.hasActiveCatalog()
                XCTAssertTrue(stillActive)
                let stillValid = try await network.isCurrentWindowToolDispatchIdentity(XCTUnwrap(successorDispatch))
                XCTAssertTrue(stillValid)
                XCTAssertEqual(WindowState.windowCounter, before)
                successor.closeDomainAdmission()
                let closedDispatch = await network.captureWindowToolDispatchIdentity(windowID: routeID, catalogRegistrationHandle: successorHandle)
                XCTAssertNil(closedDispatch)
                if case .unavailable = await app.independentRouteResources(routeID: routeID) {} else {
                    XCTFail("Closing independent route must refuse instead of falling back to presentation")
                }
            } catch {
                await owner.close()
                await successor.close()
                throw error
            }
            await owner.close()
            await successor.close()
            if case .unregistered = await app.independentRouteResources(routeID: routeID) {} else {
                XCTFail("Closed owner remained registered")
            }
        }
    }

    func testDisconnectThroughAnotherOwnerReleasesTheCanonicalConnection() async throws {
        let runtime = try await makeRuntime()
        let first = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime)
        let second = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime)
        let connectionID = UUID()
        let registered = await runtime.routingCoordinator.registerConnection(connectionID: connectionID, operationID: UUID())
        let receipt = try XCTUnwrap(registered.snapshot.connections.first { $0.registration.connectionID == connectionID }?.registration)
        first.retainConnection(receipt)
        await second.releaseDisconnectedConnection(connectionID)
        let disconnected = await runtime.routingCoordinator.snapshot()
        XCTAssertFalse(disconnected.connections.contains { $0.registration.connectionID == connectionID })
        let replacement = await runtime.routingCoordinator.registerConnection(connectionID: connectionID, operationID: UUID())
        let successor = try XCTUnwrap(replacement.snapshot.connections.first { $0.registration.connectionID == connectionID }?.registration)
        await first.close()
        let final = await runtime.routingCoordinator.snapshot()
        XCTAssertTrue(final.connections.contains { $0.registration == successor }, "The old receipt retained by another owner cannot retract its successor")
        await second.close()
    }

    func testWindowFreeCatalogFailureAndCloseUseExactRegistrationReceipts() async throws {
        let runtime = try await makeRuntime()
        do {
            let before = WindowState.windowCounter
            let owner = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime)
            let routeID = owner.identity.routeID
            let executions = owner.toolExecutionRuntime
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "read_file"))
            let binding = MCPDomainToolBinding(definition: definition) { _ in
                await .bool(executions.activeExecutionCount == 1)
            }
            let binder = MCPAppToolBinder(windowID: routeID) { name, _, arguments, implementation in
                let invocation = MCPAppToolInvocation(toolName: name, windowID: routeID, context: .trustedLocal(
                    toolName: name, metadata: .init(connectionID: nil, clientName: nil, windowID: routeID)
                ))
                return try await executions.execute(
                    invocation, ownerIdentity: ObjectIdentifier(owner), indexedRunID: nil,
                    validateInvocation: { context, routeID, identity in
                        await ServerNetworkManager.shared.validateToolInvocationContext(
                            context, expectedWindowID: routeID, expectedServerViewModelIdentity: identity
                        )
                    }
                ) { try await implementation(invocation, arguments) }
            }
            func catalog(required: Set<String>) -> MCPAppToolCatalogRegistration {
                MCPAppToolCatalogRegistration(
                    windowID: routeID, providers: [], sharedBindings: [binding],
                    runtime: binder, requiredToolNames: required
                )
            }
            do {
                _ = try await owner.registerCatalog(catalog(required: ["file_search"]))
                XCTFail("A partial catalog cannot be reported registered")
            } catch let MCPAppToolCatalogMaterializationError.missingCanonicalTools(names) {
                XCTAssertEqual(names, ["file_search"])
            }
            XCTAssertNil(owner.catalogHandle)
            let complete = catalog(required: ["read_file"])
            let handle = try await owner.registerCatalog(complete)
            let active = await owner.hasActiveCatalog()
            XCTAssertTrue(active)
            XCTAssertEqual(owner.catalogHandle, handle)
            let unrelated = await AppDomainRuntimeComposition.shared.isActive(handle)
            XCTAssertFalse(unrelated, "Explicit host runtime must not register in the process fallback")
            complete.invalidateToolsCache()
            let refreshed = try await owner.registerCatalog(complete)
            XCTAssertEqual(refreshed, handle, "Refreshing the stable legacy catalog keeps its exact handle")
            let resolved = await runtime.toolRegistry.resolve(toolName: "read_file", scope: .window(id: routeID))
            let tool = try XCTUnwrap(resolved)
            let result = try await tool.binding([:])
            XCTAssertEqual(result, .bool(true), "The real catalog/binder dispatch uses the host-owned execution tracker without a window")
            XCTAssertEqual(executions.activeExecutionCount, 0)
            XCTAssertEqual(WindowState.windowCounter, before)
            // Retire admission after registration but before opening the provider gate. The same
            // window-free execution path must withdraw tracking without dispatch or an ended count.
            let rejectedRun = UUID()
            do {
                _ = try await executions.execute(
                    .init(toolName: "read_file", windowID: routeID, context: .trustedLocal(
                        toolName: "read_file", metadata: .init(connectionID: nil, clientName: nil, windowID: routeID)
                    )),
                    ownerIdentity: ObjectIdentifier(owner), indexedRunID: rejectedRun,
                    validateInvocation: { _, _, _ in await !owner.isClosing },
                    presentation: .init(registered: { _, _ in owner.closeDomainAdmission() })
                ) { XCTFail("A retired route cannot dispatch its provider")
                    return false
                }
                XCTFail("Retired invocation must be refused")
            } catch ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal {}
            XCTAssertEqual(executions.activeExecutionCount, 0)
            XCTAssertEqual(executions.toolEndedCount(runID: rejectedRun), 0)
            await owner.close()
            let retired = await owner.hasActiveCatalog()
            XCTAssertFalse(retired)
            XCTAssertNil(owner.catalogHandle)
            do {
                _ = try await owner.registerCatalog(complete)
                XCTFail("Retired route must not reopen its catalog")
            } catch MCPHostRouteResources.RegistrationFailure.closing {} catch { XCTFail("Unexpected refusal: \(error)") }
        }
    }

    func testSettingsLeaseUsesExactOwnerWithoutWindowElectionAndReleasesOnce() throws {
        let count = WindowState.windowCounter
        let keys = KeyManager()
        let settings = APISettingsViewModel(aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, loadStoredDataOnInit: false)
        let first = try XCTUnwrap(APISettingsRuntimeLease.acquire(from: settings))
        let second = try XCTUnwrap(APISettingsRuntimeLease.acquire(from: settings))
        XCTAssertTrue(first.settings === settings)
        XCTAssertTrue(second.settings === settings)
        XCTAssertEqual(WindowState.windowCounter, count)
        settings.prepareForWindowClose()
        XCTAssertTrue(settings.canAcquireManagedRuntimeLease)
        first.release()
        first.release()
        XCTAssertEqual(settings.managedRuntimeLeaseCount, 1)
        second.release()
        XCTAssertEqual(settings.managedRuntimeLeaseCount, 0)
        XCTAssertFalse(settings.canAcquireManagedRuntimeLease)
        XCTAssertNil(APISettingsRuntimeLease.acquire(from: settings))
    }

    func testCanonicalContextLeaseDefersOnlyItsRootsAndRevalidatesTheAuthority() async throws {
        let runtime = try await makeRuntime()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-root-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let files = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await files.loadRoot(path: directory.path)
        addTeardownBlock { await files.unloadRoot(id: root.id) }
        var workspace = WorkspaceModel(name: "Host context", repoPaths: [directory.path])
        let tab = ComposeTabState()
        workspace.composeTabs = [tab]
        let documentURL = directory.appendingPathComponent("workspace.json")
        let document = try DomainWorkspaceDocument.decode(documentBytes: JSONEncoder().encode(workspace), fileURL: documentURL)
        _ = await runtime.workspaceStore.registerReadDocument(document)
        let resources = AgentHostWorkspaceResources(files: files, contexts: runtime.contextStore)
        let before = WindowState.windowCounter
        do {
            _ = try await resources.acquire(context: .init(workspaceID: workspace.id, contextID: tab.id), rootIDs: [])
            XCTFail("An incomplete root set must not claim a workspace lease")
        } catch AgentHostWorkspaceResources.Failure.rootsChanged {} catch { XCTFail("Unexpected refusal: \(error)") }
        let lease = try await resources.acquire(context: .init(workspaceID: workspace.id, contextID: tab.id), rootIDs: [root.id])
        let current = await lease.isCurrent()
        XCTAssertTrue(current)
        XCTAssertTrue(lease.rootsAreCurrent)
        XCTAssertEqual(WindowState.windowCounter, before)
        workspace.name = "Changed canonical context"
        let replacement = try DomainWorkspaceDocument.decode(documentBytes: JSONEncoder().encode(workspace), fileURL: documentURL)
        _ = await runtime.workspaceStore.registerReadDocument(replacement)
        let stale = await lease.isCurrent()
        XCTAssertFalse(stale)
        let fresh = try await lease.capture(context: .init(workspaceID: workspace.id, contextID: tab.id))
        let freshIsCurrent = await fresh.isCurrent()
        XCTAssertTrue(freshIsCurrent, "A new request reads fresh bytes without refreshing an old request's receipt")
        let discarded = try await lease.capture(context: .init(workspaceID: workspace.id, contextID: tab.id))
        await discarded.release()
        XCTAssertTrue(lease.rootsAreCurrent, "Releasing a borrowed request must not release the activation's roots")
        await files.unloadRoot(id: root.id)
        let retained = await files.rootRefs()
        XCTAssertTrue(retained.contains { $0.id == root.id })
        await lease.release()
        await lease.release()
        let released = await files.rootRefs()
        XCTAssertFalse(released.contains { $0.id == root.id })
        XCTAssertFalse(lease.rootsAreCurrent)
        XCTAssertFalse(fresh.rootsAreCurrent, "Root owner release invalidates every borrowed request even if it is still retained")

        let reloaded = try await files.loadRoot(path: directory.path)
        addTeardownBlock { await files.unloadRoot(id: reloaded.id) }
        let original = try await resources.acquire(context: .init(workspaceID: workspace.id, contextID: tab.id), rootIDs: [reloaded.id])
        XCTAssertTrue(original.rootsAreCurrent)
        try await files.replaceRootLifetimeForTesting(rootID: reloaded.id)
        XCTAssertFalse(original.rootsAreCurrent, "Final dispatch checks must observe exact root revocation without another actor hop")
        await original.release()
        let successorRoots = await files.rootRefs()
        XCTAssertTrue(successorRoots.contains { $0.id == reloaded.id }, "Releasing the old receipt cannot unload a replacement lifetime")
    }

    private func makeRuntime() async throws -> MCPDomainRuntime {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-runtime-\(UUID())")
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app, profileIdentifier: "host-\(UUID())", storageDirectory: directory,
            workspaceStorageDirectory: directory.appendingPathComponent("workspaces"),
            eventDirectory: directory.appendingPathComponent("events"), temporaryDirectory: directory.appendingPathComponent("tmp"),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock {
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        return runtime
    }
}

@MainActor
final class MCPRunRouteBindingsTests: XCTestCase {
    func testStandaloneMappingRejectsReplacementAcrossRunWindowAndTab() {
        let lifetime = MCPRunRouteBindings.OwnerLifetime()
        defer { withExtendedLifetime(lifetime) {} }
        let routes = MCPRunRouteBindings(ownerLifetime: lifetime)
        let runID = UUID(), first = UUID(), replacement = UUID(), tabID = UUID()
        XCTAssertEqual(routes.register(connectionID: first, runID: runID, windowID: 41), .registered(displacedConnectionID: nil))
        routes.tabContextByConnectionID[first] = context(runID: runID, tabID: tabID)
        XCTAssertTrue(routes.hasCurrentMapping(runID: runID, connectionID: first, expectedTabID: tabID))
        XCTAssertFalse(routes.hasCurrentMapping(runID: runID, connectionID: first, expectedTabID: UUID()))
        XCTAssertEqual(routes.register(connectionID: replacement, runID: runID, windowID: 42), .refusedWindow(41))
        let otherRun = UUID()
        XCTAssertEqual(routes.register(connectionID: first, runID: otherRun, windowID: 41), .refusedBoundRun(runID))
        XCTAssertEqual(routes.register(connectionID: replacement, runID: runID, windowID: 41), .registered(displacedConnectionID: first))
        XCTAssertFalse(routes.hasCurrentMapping(runID: runID, connectionID: first, expectedTabID: tabID))
        XCTAssertFalse(routes.hasCurrentMapping(runID: runID, connectionID: replacement, expectedTabID: tabID), "A mapping without its exact context is insufficient")
        routes.tabContextByConnectionID[replacement] = context(runID: runID, tabID: tabID)
        XCTAssertTrue(routes.hasCurrentMapping(runID: runID, connectionID: replacement, expectedTabID: tabID))
        XCTAssertEqual(routes.connectionID(forRunID: runID), replacement)
        XCTAssertEqual(routes.connectionIDs(forRunID: runID), [replacement])
        XCTAssertEqual(routes.liveRunIDsBound(toTabID: tabID), [runID])
        routes.connectionIDToRunID[replacement] = otherRun
        XCTAssertFalse(routes.hasCurrentMapping(runID: runID, connectionID: replacement, expectedTabID: tabID), "Both mapping directions remain required")
        XCTAssertNil(routes.connectionID(forRunID: runID))
        XCTAssertTrue(routes.liveRunIDsBound(toTabID: tabID).isEmpty)
    }

    func testPendingReplacementRestoresCommittedPredecessorButNeverPendingPredecessor() throws {
        let lifetime = MCPRunRouteBindings.OwnerLifetime()
        defer { withExtendedLifetime(lifetime) {} }
        let routes = MCPRunRouteBindings(ownerLifetime: lifetime)
        let runID = UUID(), committed = UUID(), replacement = UUID()
        _ = routes.register(connectionID: committed, runID: runID, windowID: 41)
        let token = try XCTUnwrap(routes.beginPendingPolicy(connectionID: replacement, runID: runID, windowID: 41))
        XCTAssertTrue(routes.isCurrent(token))
        XCTAssertNil(routes.connectionIDToRunID[committed])
        XCTAssertTrue(routes.rollback(token, removingContext: {}))
        XCTAssertTrue(routes.hasCurrentMapping(runID: runID, connectionID: committed))
        XCTAssertNil(routes.connectionIDToRunID[replacement])

        let pending = try XCTUnwrap(routes.beginPendingPolicy(connectionID: replacement, runID: runID, windowID: 41))
        let successor = try XCTUnwrap(routes.beginPendingPolicy(connectionID: UUID(), runID: runID, windowID: 41))
        XCTAssertFalse(routes.isCurrent(pending), "A displaced token cannot begin rollback")
        XCTAssertTrue(routes.isCurrent(successor))
        var staleCleanupRan = false
        XCTAssertFalse(routes.rollback(pending) { staleCleanupRan = true })
        XCTAssertFalse(staleCleanupRan)
        XCTAssertTrue(routes.isCurrent(successor))
        XCTAssertTrue(routes.rollback(successor, removingContext: {}))
        XCTAssertFalse(routes.hasCurrentMapping(runID: runID, connectionID: replacement), "Rollback must not resurrect a displaced pending policy")
        XCTAssertNil(routes.connectionIDByRunID[runID])
    }

    func testRuntimeRetainsSameMappingStorageWithoutPresentation() throws {
        let scope = AgentSessionRuntimeStore().makeScope()
        var lifetime: MCPRunRouteBindings.OwnerLifetime? = .init()
        var routes: MCPRunRouteBindings? = try MCPRunRouteBindings(ownerLifetime: XCTUnwrap(lifetime))
        weak let retainedRoutes = routes
        try scope.mcp.installRunRoute(id: 41, bindings: XCTUnwrap(routes))
        let runID = UUID(), connectionID = UUID()
        _ = try XCTUnwrap(routes).register(connectionID: connectionID, runID: runID, windowID: 41)
        routes = nil
        let retained = try XCTUnwrap(retainedRoutes, "A runtime route must not disappear with its presenter")
        XCTAssertTrue(retained.hasCurrentMapping(runID: runID, connectionID: connectionID))
        retained.connectionIDByRunID.removeValue(forKey: runID)
        XCTAssertFalse(retained.hasCurrentMapping(runID: runID, connectionID: connectionID), "Transport cleanup mutates the retained storage, not a copied snapshot")
        _ = retained.register(connectionID: connectionID, runID: runID, windowID: 41)
        XCTAssertTrue(retained.hasCurrentMapping(runID: runID, connectionID: connectionID))
        lifetime = nil
        XCTAssertFalse(retained.hasCurrentMapping(runID: runID, connectionID: connectionID), "Retained maps must refuse dispatch when their routing composition has gone away")
        XCTAssertEqual(retained.connectionIDByRunID[runID], connectionID, "Refusal does not pretend to perform domain cleanup")
    }

    private func context(runID: UUID, tabID: UUID) -> MCPTabContextSnapshot {
        .init(tabID: tabID, windowID: 41, workspaceID: UUID(), promptText: "", selection: .init(), selectedMetaPromptIDs: [], tabName: "Runtime", runID: runID, explicitlyBound: true)
    }
}

@MainActor
final class ContextBuilderSelectionTransactionTests: XCTestCase {
    func testLegacyDomainUnregistrationKeepsRunMappingOwnerUntilServerRelease() async throws {
        let fixture = try await makePromptMutationFixture(name: "legacy-route-lifetime")
        let server = fixture.window.mcpServer
        let runID = UUID(), connectionID = UUID()
        XCTAssertEqual(server.runRouteBindings.register(connectionID: connectionID, runID: runID, windowID: fixture.window.windowID), .registered(displacedConnectionID: nil))
        XCTAssertTrue(server.runRouteBindings.hasCurrentMapping(runID: runID, connectionID: connectionID))
        await server.unregisterDomainRoutingWindow()
        XCTAssertTrue(server.runRouteBindings.hasCurrentMapping(runID: runID, connectionID: connectionID), "Domain close precedes the existing explicit run drain; it must not withdraw that run's resources")
    }

    func testBackgroundPromptAppendUsesCurrentTextWithoutRefreshingTheStaleBinding() async throws {
        let fixture = try await makePromptMutationFixture(name: "shared-background-prompt")
        let server = fixture.window.mcpServer
        let activeTabID = fixture.window.promptManager.activeComposeTabID
        let activePrompt = fixture.window.promptManager.promptText
        XCTAssertNotEqual(activeTabID, fixture.tabID)
        try fixture.updateStoredPrompt("X0")
        try fixture.bindPromptConnection(fixture.connectionID)
        let otherConnectionID = UUID()
        try fixture.bindPromptConnection(otherConnectionID)

        let otherReply = try await fixture.mutatePrompt(connectionID: otherConnectionID) { $0 = "Y1" }
        XCTAssertEqual(otherReply, "Y1")
        XCTAssertEqual(fixture.boundContext?.promptText, "X0", "The first connection must remain stale before append")
        let appendReply = try await fixture.mutatePrompt(connectionID: fixture.connectionID) { $0 += "+X" }

        XCTAssertEqual(appendReply, "Y1+X")
        XCTAssertEqual(fixture.window.workspaceManager.composeTab(for: fixture.identity)?.promptText, "Y1+X")
        let freshConnectionID = UUID()
        try fixture.bindPromptConnection(freshConnectionID)
        XCTAssertEqual(server.runRouteBindings.tabContextByConnectionID[freshConnectionID]?.promptText, "Y1+X")
        XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, activeTabID)
        XCTAssertEqual(fixture.window.promptManager.promptText, activePrompt)
    }

    func testOrdinaryPromptMutationsPreserveCurrentMetaPromptsAndOtherTabFields() async throws {
        let fixture = try await makePromptMutationFixture(name: "prompt-field-ownership")
        let cachedMetaPromptID = UUID()
        let currentMetaPromptIDs = [UUID(), UUID()]
        let cases: [(name: String, expected: String, mutation: (inout String) -> Void)] = [
            ("set", "Replacement", { $0 = "Replacement" }),
            ("append", "Y1+X", { $0 += "+X" }),
            ("clear", "", { $0 = "" })
        ]
        for testCase in cases {
            try fixture.updateStoredPrompt("X0", metaPromptIDs: [cachedMetaPromptID])
            try fixture.bindPromptConnection(fixture.connectionID)
            var current = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
            current.promptText = "Y1"
            current.selectedMetaPromptIDs = currentMetaPromptIDs
            current.selection = StoredSelection(selectedPaths: [fixture.fileB.path])
            current.contextOverrides.useOverridePrompt = true
            current.contextOverrides.overridePromptText = "Keep this override"
            XCTAssertTrue(fixture.window.workspaceManager.updateComposeTabStoredOnly(current, inWorkspaceID: fixture.workspaceID))
            XCTAssertEqual(fixture.boundContext?.selectedMetaPromptIDs, [cachedMetaPromptID])
            XCTAssertEqual(fixture.boundContext?.promptText, "X0")

            let reply = try await fixture.mutatePrompt(
                connectionID: fixture.connectionID,
                mutation: testCase.mutation
            )

            let stored = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
            XCTAssertEqual(reply, testCase.expected, testCase.name)
            XCTAssertEqual(stored.promptText, testCase.expected, testCase.name)
            XCTAssertEqual(stored.selectedMetaPromptIDs, currentMetaPromptIDs, testCase.name)
            XCTAssertEqual(stored.selection, current.selection, testCase.name)
            XCTAssertEqual(stored.contextOverrides, current.contextOverrides, testCase.name)
        }
    }

    func testActivePromptAppendUsesPendingEditorTextAndKeepsCanonicalMetaPrompts() async throws {
        let fixture = try await makePromptMutationFixture(name: "active-prompt-owner")
        await fixture.window.promptManager.switchComposeTab(fixture.tabID)
        XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabID)
        let metaPromptIDs = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity)).selectedMetaPromptIDs
        try fixture.updateStoredPrompt("Stored", metaPromptIDs: metaPromptIDs)
        try fixture.bindPromptConnection(fixture.connectionID)
        fixture.window.promptManager.promptText = "Pending editor text"
        XCTAssertEqual(fixture.boundContext?.promptText, "Stored")

        let reply = try await fixture.mutatePrompt(connectionID: fixture.connectionID) { $0 += "+MCP" }

        XCTAssertEqual(reply, "Pending editor text+MCP")
        XCTAssertEqual(fixture.window.promptManager.promptText, "Pending editor text+MCP")
        let stored = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
        XCTAssertEqual(stored.promptText, "Pending editor text+MCP")
        XCTAssertEqual(stored.selectedMetaPromptIDs, metaPromptIDs)
    }

    func testRunScopedPromptMutationRetainsItsFrozenPromptSemantics() async throws {
        let fixture = try await makePromptMutationFixture(name: "frozen-prompt-owner")
        try fixture.updateStoredPrompt("Frozen")
        _ = try fixture.installContext(selection: .init())
        try fixture.updateStoredPrompt("Newer ordinary prompt")
        XCTAssertEqual(fixture.boundContext?.runID, fixture.runID)

        let reply = try await fixture.mutatePrompt(connectionID: fixture.connectionID) { $0 += "+Run" }

        XCTAssertEqual(reply, "Frozen+Run")
        XCTAssertEqual(fixture.boundContext?.promptText, "Frozen+Run")
        XCTAssertEqual(fixture.window.workspaceManager.composeTab(for: fixture.identity)?.promptText, "Frozen+Run")
    }

    func testOrdinaryPromptMutationRejectsAStaleBindingToARemovedTab() async throws {
        let fixture = try await makePromptMutationFixture(name: "removed-prompt-target")
        try fixture.updateStoredPrompt("Existing prompt")
        try fixture.bindPromptConnection(fixture.connectionID)
        let manager = fixture.window.workspaceManager
        let workspaceIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspaceID })
        manager.workspaces[workspaceIndex].composeTabs.removeAll { $0.id == fixture.tabID }
        let survivingTabs = manager.workspaces[workspaceIndex].composeTabs
        let activePrompt = fixture.window.promptManager.promptText
        var mutationWasCalled = false

        do {
            _ = try await fixture.mutatePrompt(connectionID: fixture.connectionID) {
                mutationWasCalled = true
                $0 += "+Must not commit"
            }
            XCTFail("A removed target must not report a successful prompt write")
        } catch let error as MCPError {
            guard case let .invalidParams(message) = error else {
                XCTFail("Unexpected prompt mutation error: \(error)")
                return
            }
            let unwrappedMessage = try XCTUnwrap(message)
            XCTAssertTrue(unwrappedMessage.contains("bound tab is no longer available"), unwrappedMessage)
        }

        XCTAssertFalse(mutationWasCalled)
        XCTAssertNil(manager.composeTab(for: fixture.identity))
        XCTAssertEqual(manager.workspaces[workspaceIndex].composeTabs, survivingTabs)
        XCTAssertEqual(fixture.boundContext?.promptText, "Existing prompt")
        XCTAssertEqual(fixture.window.promptManager.promptText, activePrompt)
    }

    func testOwnedPolicyContextUsesPinnedCatalogAndLateCleanupPreservesReopenedRoute() async throws {
        let storageRoot = try makeTestDirectory(name: "OwnedPolicyContext")
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app, profileIdentifier: "owned-context-\(UUID().uuidString)",
            storageDirectory: storageRoot.appendingPathComponent("runtime-state"), workspaceStorageDirectory: storageRoot,
            eventDirectory: storageRoot.appendingPathComponent("events"), temporaryDirectory: storageRoot.appendingPathComponent("tmp"),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock { _ = await runtime.shutdown() }
        let fixture = try await makeFixture(name: "owned-context", domainRuntime: runtime)
        defer { fixture.cleanup() }
        let server = fixture.window.mcpServer
        // The ephemeral UI fixture has not persisted its new background tab. Publish that
        // concrete read document before asking the domain router to bind its exact context.
        let workspace = try XCTUnwrap(fixture.window.workspaceManager.workspaces.first { $0.id == fixture.workspaceID })
        let authority = try XCTUnwrap(server.domainWorkspaceAuthorityClient)
        _ = try await authority.registerForRead(
            workspace, fileURL: fixture.window.workspaceManager.workspaceFileURL(for: workspace)
        )
        let manager = ServerNetworkManager.shared
        let identity = MCPRouteIdentityAllocator.allocateHost()
        let original = MCPHostRouteResources(identity: identity, coordinator: runtime.routingCoordinator, runtime: runtime)
        let successor = MCPHostRouteResources(identity: identity, coordinator: runtime.routingCoordinator, runtime: runtime)
        let count = WindowState.windowCounter
        let client = "owned-context-\(UUID().uuidString)"
        XCTAssertNil(WindowStatesManager.shared.window(withID: identity.routeID))
        let originalCatalog = try await original.registerCatalog(server.makeToolCatalog(route: original))
        let installed = await manager.installClientConnectionPolicy(
            for: client, windowID: identity.routeID, restrictedTools: [], tabID: fixture.tabID,
            runID: fixture.runID, purpose: .agentModeRun, routingOwner: original
        )
        let originalReceipt = try XCTUnwrap(installed)
        let applied = await manager.debugApplyPendingPolicy(clientName: client, connectionID: fixture.connectionID)
        XCTAssertEqual(applied.outcome, "applied")
        await original.settleRoutingPublications()
        XCTAssertEqual(original.runRouteBindings.tabContextByConnectionID[fixture.connectionID]?.tabID, fixture.tabID)
        XCTAssertNotNil(server.tabContextCancellablesByConnectionID[original.connectionKey(fixture.connectionID)])
        XCTAssertNil(fixture.boundContext)
        let originalToken = try XCTUnwrap(original.runRouteBindings.beginPendingPolicy(
            connectionID: fixture.connectionID, runID: fixture.runID, windowID: identity.routeID, cleanupReceipt: originalReceipt
        ))
        let initialRouting = await runtime.routingCoordinator.snapshot()
        let oldDomainConnection = try XCTUnwrap(initialRouting.connections.first { $0.registration.connectionID == fixture.connectionID }?.registration)
        XCTAssertEqual(
            initialRouting.connections.first { $0.registration == oldDomainConnection }?.binding,
            .runScoped(runID: fixture.runID, context: DomainContextIdentity(workspaceID: fixture.workspaceID, contextID: fixture.tabID))
        )

        await original.unregisterCatalog(originalCatalog)
        do {
            _ = try await original.registerCatalog(server.makeToolCatalog(route: original))
            XCTFail("A retained mapping cannot exchange its original context cleanup owner")
        } catch MCPHostRouteResources.RegistrationFailure.differentCatalog {
            // The old catalog's exact operations remain retained until mapping cleanup completes.
        }

        // Retire the route before its provider's delayed cleanup, then reuse every wire ID. The
        // catalog still leases the original context operations, not the reopened route's owner.
        await original.close()
        _ = try await successor.registerCatalog(server.makeToolCatalog(route: successor))
        let replaced = await manager.installClientConnectionPolicy(
            for: client, windowID: identity.routeID, restrictedTools: ["edit_file"], tabID: fixture.tabID,
            runID: fixture.runID, purpose: .agentModeRun, routingOwner: successor
        )
        let successorReceipt = try XCTUnwrap(replaced)
        let reapplied = await manager.debugApplyPendingPolicy(clientName: client, connectionID: fixture.connectionID)
        XCTAssertEqual(reapplied.outcome, "applied")
        await successor.settleRoutingPublications()
        let replacementRouting = await runtime.routingCoordinator.snapshot()
        let newDomainConnection = try XCTUnwrap(replacementRouting.connections.first { $0.registration.connectionID == fixture.connectionID }?.registration)
        XCTAssertNotEqual(oldDomainConnection, newDomainConnection)
        XCTAssertNotEqual(
            original.runRouteBindings.tabContextByConnectionID[fixture.connectionID]?.routeOwnerIdentity,
            successor.runRouteBindings.tabContextByConnectionID[fixture.connectionID]?.routeOwnerIdentity
        )
        XCTAssertNotNil(server.tabContextCancellablesByConnectionID[successor.connectionKey(fixture.connectionID)])
        XCTAssertEqual(original.rollbackPendingPolicy(originalReceipt, token: originalToken, clientName: client), .restored)
        await original.settleRoutingPublications()
        XCTAssertNotNil(server.tabContextCancellablesByConnectionID[successor.connectionKey(fixture.connectionID)], "Original rollback cannot cancel the reopened route's mirror")
        await manager.cleanupRunRoutingState(ownedBy: originalReceipt)
        await manager.cleanupRunRoutingState(ownedBy: originalReceipt)
        XCTAssertNil(original.runRouteBindings.tabContextByConnectionID[fixture.connectionID])
        XCTAssertNil(server.tabContextCancellablesByConnectionID[original.connectionKey(fixture.connectionID)])
        XCTAssertEqual(successor.runRouteBindings.tabContextByConnectionID[fixture.connectionID]?.tabID, fixture.tabID)
        XCTAssertNotNil(server.tabContextCancellablesByConnectionID[successor.connectionKey(fixture.connectionID)])
        let afterOldCleanup = await runtime.routingCoordinator.snapshot()
        XCTAssertTrue(afterOldCleanup.connections.contains { $0.registration == newDomainConnection })
        let mappingCurrent = await manager.mapConnectionToRunID(fixture.connectionID, runID: fixture.runID, windowID: identity.routeID)
        XCTAssertTrue(mappingCurrent)
        XCTAssertEqual(WindowState.windowCounter, count, "Owned route application must not manufacture a window")
        await manager.cleanupRunRoutingState(ownedBy: successorReceipt)
        XCTAssertNil(successor.runRouteBindings.tabContextByConnectionID[fixture.connectionID])
        XCTAssertNil(server.tabContextCancellablesByConnectionID[successor.connectionKey(fixture.connectionID)])
        let finalRouting = await runtime.routingCoordinator.snapshot()
        XCTAssertFalse(finalRouting.connections.contains { $0.registration == newDomainConnection })
        await successor.close()
    }

    func testCursorInitializeNamePromotesQueuedDiscoveryContext() async throws {
        let fixture = try await makeFixture(name: "cursor-initialize-name")
        defer { fixture.cleanup() }
        let server = fixture.window.mcpServer
        let selection = StoredSelection(selectedPaths: [fixture.fileA.path])
        try await fixture.seedCanonical(selection)
        let activeTabID = fixture.window.workspaceManager.activeWorkspace?.activeComposeTabID
        XCTAssertNotEqual(activeTabID, fixture.tabID)

        let route = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: nil)
        XCTAssertNotEqual(route.identity.routeID, fixture.window.windowID)
        let catalog = server.makeToolCatalog(route: route)
        XCTAssertEqual(catalog.windowID, route.identity.routeID)
        XCTAssertEqual(
            try Set(catalog.materializeTools().map(\.name)),
            try Set(server.windowMCPToolCatalogService.materializeTools().map(\.name))
        )
        // Queue through the provider hint, then promote with Cursor's observed initialize name.
        // The real physical operations must use the supplied host route, not the window's maps.
        try server.installFrozenTabContext(
            route: route,
            clientID: nil,
            clientName: XCTUnwrap(AgentProviderKind.cursor.mcpClientNameHint),
            context: fixture.makeContext(selection: selection, routeID: route.identity.routeID)
        )
        let token = try XCTUnwrap(server.registerPendingPolicyRunIDMapping(
            route: route,
            connectionID: fixture.connectionID,
            runID: fixture.runID,
            windowID: route.identity.routeID,
            clientName: "Cursor"
        ))
        let promoted = try XCTUnwrap(token.promotedContext)
        XCTAssertEqual(promoted.runID, fixture.runID)
        XCTAssertEqual(promoted.windowID, route.identity.routeID)
        XCTAssertEqual(promoted.workspaceID, fixture.workspaceID)
        XCTAssertEqual(promoted.tabID, fixture.tabID)
        XCTAssertEqual(promoted.selection, selection)
        XCTAssertEqual(route.runRouteBindings.tabContextByConnectionID[fixture.connectionID]?.selection, selection)
        XCTAssertNil(fixture.boundContext, "A host context must not enter the physical route")
        XCTAssertEqual(server.boundTabID(route: route, forConnection: fixture.connectionID), fixture.tabID)
        XCTAssertEqual(server.pendingContextQueueLength(route: route, clientName: "Cursor", windowID: route.identity.routeID), 0)
        XCTAssertEqual(server.contextBuilderFinalContextConnectionID(route: route, runID: fixture.runID), fixture.connectionID)
        let resolved = try server.resolveTabContextSnapshot(
            route: route,
            from: MCPRequestMetadata(connectionID: fixture.connectionID, clientName: "Cursor", windowID: route.identity.routeID),
            toolName: "host-context-test"
        )
        XCTAssertEqual(resolved.snapshot.windowID, route.identity.routeID)
        let invocation = ToolInvocationContext.trustedLocal(
            toolName: "prompt",
            metadata: MCPRequestMetadata(connectionID: fixture.connectionID, clientName: "Cursor", windowID: route.identity.routeID)
        )
        let updatedPrompt = try await MCPInvocationContextBridge.withInvocation(invocation) {
            try await server.updateCurrentTabPrompt(route: route, toolName: "prompt") { $0 = "Host-owned prompt" }
        }
        XCTAssertEqual(updatedPrompt, "Host-owned prompt")
        XCTAssertEqual(route.runRouteBindings.tabContextByConnectionID[fixture.connectionID]?.promptText, updatedPrompt)
        XCTAssertNil(fixture.boundContext)
        XCTAssertFalse(server.readFileAutoSelectionCoordinator(route: route) === server.readFileAutoSelectionCoordinator(route: server.routeResources))
        server.removeTabContext(route: route, forConnectionID: fixture.connectionID, clientName: "Cursor", windowID: route.identity.routeID, runID: fixture.runID)
        await route.close()
        XCTAssertNil(route.runRouteBindings.tabContextByConnectionID[fixture.connectionID])
        XCTAssertEqual(fixture.window.workspaceManager.activeWorkspace?.activeComposeTabID, activeTabID)
    }

    func testNamedTabKeepsItsNameAfterTasknamePromptMutation() async throws {
        for name in ["Care", "New Chat about support", "Untitled Chat about support"] {
            let fixture = try await makeFixture(name: "named-taskname")
            defer { fixture.cleanup() }
            fixture.window.promptManager.renameComposeTab(fixture.tabID, to: "T17")
            _ = try fixture.installContext(selection: .init())

            // An explicit rename after discovery captured its context must win over that snapshot.
            fixture.window.agentModeViewModel.renameSession(tabID: fixture.tabID, to: name)
            let prompt = "<taskname=\"Support ticket activity MCP plan\"/>\n<task>Plan support activity</task>"
            let invocation = ToolInvocationContext.trustedLocal(
                toolName: "prompt",
                metadata: fixture.metadata
            )
            _ = try await MCPInvocationContextBridge.withInvocation(invocation) {
                try await fixture.window.mcpServer.updateCurrentTabPrompt(route: fixture.window.mcpServer.routeResources, toolName: "prompt") {
                    $0 = prompt
                }
            }

            let storedTab = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
            XCTAssertEqual(storedTab.name, name)
            XCTAssertEqual(storedTab.promptText, prompt)
            XCTAssertEqual(fixture.boundContext?.promptText, prompt)
            XCTAssertEqual(fixture.window.promptManager.currentComposeTabs.first { $0.id == fixture.tabID }?.name, name)
            XCTAssertEqual(fixture.window.agentModeViewModel.resolvedSessionDisplayName(for: fixture.tabID), name)
        }
    }

    func testChatPlaceholderTabGetsNamedAfterTasknamePromptMutation() async throws {
        try await assertTasknameNamesDefaultTabs(named: ["New Chat", "Untitled Chat", "Untitled", "  new   CHAT\n"])
    }

    func testEmptyTabGetsNamedAfterTasknamePromptMutation() async throws {
        try await assertTasknameNamesDefaultTabs(named: ["", " \n\t"])
    }

    private func assertTasknameNamesDefaultTabs(named names: [String]) async throws {
        for name in names {
            let fixture = try await makeFixture(name: "placeholder-taskname", tabName: name)
            defer { fixture.cleanup() }
            XCTAssertEqual(fixture.window.workspaceManager.composeTab(for: fixture.identity)?.name, name)
            _ = try fixture.installContext(selection: .init())
            let prompt = "<taskname=\"Support   ticket activity MCP plan\"/>\n<task>Plan support activity</task>"
            let invocation = ToolInvocationContext.trustedLocal(
                toolName: "prompt",
                metadata: fixture.metadata
            )
            _ = try await MCPInvocationContextBridge.withInvocation(invocation) {
                try await fixture.window.mcpServer.updateCurrentTabPrompt(route: fixture.window.mcpServer.routeResources, toolName: "prompt") {
                    $0 = prompt
                }
            }

            let expectedName = "Support ticket activity MCP plan"
            let storedTab = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
            XCTAssertEqual(storedTab.name, expectedName, "Original title: \(String(reflecting: name))")
            XCTAssertEqual(storedTab.promptText, prompt)
            XCTAssertEqual(fixture.boundContext?.promptText, prompt)
            XCTAssertEqual(fixture.window.promptManager.currentComposeTabs.first { $0.id == fixture.tabID }?.name, expectedName)
            XCTAssertEqual(fixture.window.agentModeViewModel.resolvedSessionDisplayName(for: fixture.tabID), expectedName)
        }
    }

    func testDefaultTabGetsNamedAfterTasknamePromptMutation() async throws {
        try await assertTasknameNamesDefaultTabs(named: ["T17"])
    }

    /// A headless client (for example Devin) may restart its stdio MCP child mid-run. The successor
    /// re-matches the settlement-retained discovery policy after the pending context was already
    /// consumed, so it must inherit the displaced connection's live run context.
    func testPendingPolicyReplacementInheritsDisplacedDiscoveryContext() async throws {
        let fixture = try await makeFixture(name: "replacement-handover")
        defer { fixture.cleanup() }
        let initialSelection = StoredSelection(selectedPaths: [fixture.fileA.path])
        try await fixture.seedCanonical(initialSelection)
        let server = fixture.window.mcpServer
        try server.installFrozenTabContext(
            route: server.routeResources,
            clientID: nil,
            clientName: "devin",
            context: fixture.makeContext(selection: initialSelection)
        )
        XCTAssertNotNil(server.registerPendingPolicyRunIDMapping(
            route: server.routeResources,
            connectionID: fixture.connectionID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "devin"
        ))
        let discoveredSelection = StoredSelection(selectedPaths: [fixture.fileB.path])
        server.runRouteBindings.tabContextByConnectionID[fixture.connectionID]?.selection = discoveredSelection

        let successorID = UUID()
        let token = try XCTUnwrap(server.registerPendingPolicyRunIDMapping(
            route: server.routeResources,
            connectionID: successorID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "devin"
        ))
        XCTAssertEqual(token.displacedConnectionID, fixture.connectionID)
        XCTAssertEqual(server.runRouteBindings.tabContextByConnectionID[successorID]?.runID, fixture.runID)
        XCTAssertEqual(server.runRouteBindings.tabContextByConnectionID[successorID]?.selection, discoveredSelection)

        // The displaced connection is then torn down as a replacement, not a discovery EOF.
        XCTAssertFalse(server.detachContextBuilderTabContextForDiscoveryTeardown(
            route: server.routeResources,
            connectionID: fixture.connectionID,
            runID: fixture.runID
        ))
        server.removeTabContext(
            route: server.routeResources,
            forConnectionID: fixture.connectionID,
            clientName: "devin",
            windowID: fixture.window.windowID,
            runID: nil
        )

        XCTAssertEqual(server.contextBuilderFinalContextConnectionID(route: server.routeResources, runID: fixture.runID), successorID)
        let result = await server.commitContextBuilderTabContext(
            route: server.routeResources,
            connectionID: successorID,
            expectedRunID: fixture.runID,
            isStillCurrent: { true }
        )
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.committedTab?.tab.selection, discoveredSelection)
    }

    func testRolledBackPendingPolicyReplacementKeepsDisplacedDiscoveryContext() async throws {
        let storageRoot = try makeTestDirectory(name: "DiscoveryHandoffRollback")
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app,
            profileIdentifier: "discovery-handoff-\(UUID().uuidString)",
            storageDirectory: storageRoot.appendingPathComponent("runtime-state"),
            workspaceStorageDirectory: storageRoot,
            eventDirectory: storageRoot.appendingPathComponent("events"),
            temporaryDirectory: storageRoot.appendingPathComponent("tmp"),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock { _ = await runtime.shutdown() }
        let fixture = try await makeFixture(name: "replacement-rollback", domainRuntime: runtime)
        defer { fixture.cleanup() }
        let selection = StoredSelection(selectedPaths: [fixture.fileA.path])
        let server = fixture.window.mcpServer
        try server.installFrozenTabContext(route: server.routeResources, clientID: nil, clientName: "devin", context: fixture.makeContext(selection: selection))
        XCTAssertNotNil(server.registerPendingPolicyRunIDMapping(
            route: server.routeResources,
            connectionID: fixture.connectionID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "devin"
        ))
        let successorID = UUID()
        let token = try XCTUnwrap(server.registerPendingPolicyRunIDMapping(
            route: server.routeResources,
            connectionID: successorID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "devin"
        ))

        await server.routeResources.settleRoutingPublications()
        XCTAssertNotNil(server.tabContextCancellablesByConnectionID[server.routeResources.connectionKey(successorID)])
        let coordinator = try XCTUnwrap(server.domainRoutingCoordinator)
        let beforeRollback = await coordinator.snapshot()
        XCTAssertTrue(beforeRollback.connections.contains { $0.registration.connectionID == successorID })

        XCTAssertEqual(
            server.rollbackPendingPolicyRunIDMapping(
                route: server.routeResources,
                token,
                clientName: "devin",
                windowID: fixture.window.windowID,
                signalRoutingFailure: false
            ),
            .restored
        )

        // Rollback drops only the successor's inherited copy; the displaced snapshot is untouched.
        await server.routeResources.settleRoutingPublications()
        let afterRollback = await coordinator.snapshot()
        XCTAssertFalse(afterRollback.connections.contains { $0.registration.connectionID == successorID })
        XCTAssertTrue(afterRollback.connections.contains { $0.registration.connectionID == fixture.connectionID })
        XCTAssertNil(server.tabContextCancellablesByConnectionID[server.routeResources.connectionKey(successorID)])
        XCTAssertNil(server.runRouteBindings.tabContextByConnectionID[successorID])
        XCTAssertEqual(fixture.boundContext?.runID, fixture.runID)
        XCTAssertEqual(fixture.boundContext?.selection, selection)
        XCTAssertEqual(server.pendingContextQueueLength(route: server.routeResources, clientName: "devin", windowID: fixture.window.windowID), 0)
    }

    func testDiscoveryRoutingErrorDoesNotSuggestDisabledBindContext() {
        XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains("bind_context"))
        let message = MCPServerViewModel.tabContextRoutingErrorMessage(toolName: "git", runPurpose: .discoverRun)
        XCTAssertTrue(message.contains("No tab context is bound for git"))
        XCTAssertFalse(message.contains("bind_context"))
        XCTAssertTrue(MCPServerViewModel.tabContextRoutingErrorMessage(toolName: "git").contains("bind_context"))
    }

    func testContextBuilderToolMutationPublishesCanonicalSelectionImmediately() async throws {
        let fixture = try await makeFixture(name: "immediate")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        let verification = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            route: fixture.window.mcpServer.routeResources,
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )

        XCTAssertTrue(verification?.isVerified == true)
        XCTAssertEqual(verification?.canonicalSelection, discovered)
        XCTAssertEqual(fixture.canonicalSelection, discovered)
        XCTAssertEqual(fixture.boundContext?.selection, discovered)
    }

    func testSuccessfulEarlierToolMutationSurvivesLaterDiscoveryFailure() async throws {
        let fixture = try await makeFixture(name: "failure")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        _ = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            route: fixture.window.mcpServer.routeResources,
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )
        fixture.window.mcpServer.removeTabContext(
            route: fixture.window.mcpServer.routeResources,
            forConnectionID: fixture.connectionID,
            clientName: nil,
            windowID: fixture.window.windowID,
            runID: fixture.runID
        )
        let failedCommit = await fixture.window.mcpServer.commitContextBuilderTabContext(
            route: fixture.window.mcpServer.routeResources,
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            isStillCurrent: { true }
        )

        guard case .missingFinalContext = failedCommit.outcome else {
            return XCTFail("Expected the failed discovery to have no terminal context")
        }
        XCTAssertEqual(fixture.canonicalSelection, discovered)
    }

    func testContextBuilderAndOrdinaryAgentMutationsUseSameCanonicalPath() async throws {
        let fixture = try await makeFixture(name: "shared-path")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let first = StoredSelection(selectedPaths: [fixture.fileB.path])
        let second = StoredSelection(selectedPaths: [fixture.fileC.path])
        try await fixture.seedCanonical(source)

        let contextBuilderContext = try fixture.installContext(selection: source)
        let firstVerification = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            route: fixture.window.mcpServer.routeResources,
            .init(snapshot: contextBuilderContext.withSelection(first)),
            metadata: fixture.metadata,
            mutated: true
        )
        let ordinaryAgentContext = try XCTUnwrap(fixture.boundContext)
        let secondVerification = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            route: fixture.window.mcpServer.routeResources,
            .init(snapshot: ordinaryAgentContext.withSelection(second)),
            metadata: fixture.metadata,
            mutated: true
        )

        XCTAssertEqual(firstVerification?.canonicalSelection, first)
        XCTAssertEqual(secondVerification?.canonicalSelection, second)
        XCTAssertEqual(fixture.canonicalSelection, second)
    }

    func testDeferredUISnapshotCannotClobberImmediateCanonicalPublication() async throws {
        let fixture = try await makeFixture(name: "ui-fence")
        defer { fixture.cleanup() }
        await fixture.window.promptManager.switchComposeTab(fixture.tabID)
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        _ = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            route: fixture.window.mcpServer.routeResources,
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )

        XCTAssertEqual(
            fixture.window.selectionCoordinator.selectionForActiveUISnapshot(
                source,
                tabID: fixture.tabID
            ),
            discovered,
            "A UI snapshot queued before the tool mutation must not revoke canonical selection"
        )
        XCTAssertEqual(fixture.canonicalSelection, discovered)
    }

    func testOraclePackagingObservesImmediateCanonicalContextBuilderSelection() async throws {
        let fixture = try await makeFixture(name: "oracle-packaging")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        _ = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            route: fixture.window.mcpServer.routeResources,
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )

        let stabilized = await fixture.window.mcpServer.stabilizedVirtualContext(for: context)
        let packaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: stabilized.tabID,
            sourceWorkspaceID: stabilized.workspaceID,
            sourceSelectionRevision: stabilized.selectionRevision,
            sourceAgentSessionID: stabilized.activeAgentSessionID,
            sourceAgentRunID: stabilized.runID,
            promptText: stabilized.promptText,
            selection: stabilized.selection,
            lookupContext: stabilized.frozenLookupContext,
            reviewGitContext: .automaticOnly(base: "HEAD"),
            provenance: .direct
        )

        XCTAssertEqual(packaging.selection, discovered)
        XCTAssertFalse(packaging.selection.selectedPaths.contains(fixture.fileA.path))
    }

    func testTerminalCommitPreservesNewerCanonicalSelection() async throws {
        let fixture = try await makeFixture(name: "terminal-fence")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let newer = StoredSelection(selectedPaths: [fixture.fileC.path])
        try await fixture.seedCanonical(source)
        let staleRunContext = try fixture.installContext(selection: source)

        _ = await fixture.window.selectionCoordinator.persistSelection(
            newer,
            for: fixture.identity,
            source: .runtimeMutation,
            mirrorToUIIfActive: false
        )
        fixture.window.mcpServer.runRouteBindings.tabContextByConnectionID[fixture.connectionID] = staleRunContext

        let result = await fixture.window.mcpServer.commitContextBuilderTabContext(
            route: fixture.window.mcpServer.routeResources,
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            isStillCurrent: { true }
        )

        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.committedTab?.tab.selection, newer)
        XCTAssertEqual(fixture.canonicalSelection, newer)
    }

    private func makePromptMutationFixture(name: String) async throws -> Fixture {
        let fixture = try await makeFixture(name: name)
        await fixture.window.workspaceManager.waitUntilPostSwitchGitDataLoadComplete()
        return fixture
    }

    private func makeFixture(name: String, tabName: String? = nil, domainRuntime: MCPDomainRuntime? = nil) async throws -> Fixture {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = if let domainRuntime { WindowState(domainRuntime: domainRuntime) } else { WindowState() }
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        WindowStatesManager.shared.registerWindowState(window)
        await window.workspaceManager.awaitInitialized()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderSelectionTransactionTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = ["A.swift", "B.swift", "C.swift"].map { root.appendingPathComponent($0) }
        for file in files {
            try "// \(file.lastPathComponent)".write(to: file, atomically: true, encoding: .utf8)
        }
        let storage = WorkspaceFixtureStorage(root: root)
        addTeardownBlock { @MainActor in
            await window.tearDown()
            await window.workspaceManager.debugDrainScheduledSaves()
            WindowStatesManager.shared.unregisterWindowState(window)
            await storage.remove()
            try? FileManager.default.removeItem(at: root)
        }
        let workspace = storage.isolate(
            window.workspaceManager.createWorkspace(name: name, repoPaths: [root.path], ephemeral: true),
            in: window.workspaceManager
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: name)
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
        let backgroundTab = await window.promptManager.createBackgroundComposeTab(
            strategy: .blank,
            name: tabName ?? "Transaction \(name)"
        )
        let tabID = try XCTUnwrap(backgroundTab?.id)
        return Fixture(
            window: window,
            root: root,
            workspaceID: workspaceID,
            tabID: tabID,
            fileA: files[0],
            fileB: files[1],
            fileC: files[2]
        )
    }
}

@MainActor
private struct Fixture {
    let window: WindowState
    let root: URL
    let workspaceID: UUID
    let tabID: UUID
    let fileA: URL
    let fileB: URL
    let fileC: URL
    let connectionID = UUID()
    let runID = UUID()

    var identity: WorkspaceSelectionIdentity {
        .init(workspaceID: workspaceID, tabID: tabID)
    }

    var metadata: MCPServerViewModel.RequestMetadata {
        .init(connectionID: connectionID, clientName: "selection-transaction-test", windowID: window.windowID)
    }

    var canonicalSelection: StoredSelection? {
        window.workspaceManager.composeTab(for: identity)?.selection
    }

    var boundContext: MCPServerViewModel.TabContextSnapshot? {
        window.mcpServer.runRouteBindings.tabContextByConnectionID[connectionID]
    }

    func seedCanonical(_ selection: StoredSelection) async throws {
        _ = await window.selectionCoordinator.persistSelection(
            selection,
            for: identity,
            source: .runtimeMutation,
            mirrorToUIIfActive: false
        )
        XCTAssertEqual(canonicalSelection, selection)
    }

    func updateStoredPrompt(_ prompt: String, metaPromptIDs: [UUID]? = nil) throws {
        var tab = try XCTUnwrap(window.workspaceManager.composeTab(for: identity))
        tab.promptText = prompt
        if let metaPromptIDs {
            tab.selectedMetaPromptIDs = metaPromptIDs
        }
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(tab, inWorkspaceID: workspaceID))
    }

    func bindPromptConnection(_ connectionID: UUID) throws {
        try window.mcpServer.bindTabForConnection(
            route: window.mcpServer.routeResources,
            connectionID: connectionID,
            clientName: "prompt-mutation-test",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID
        )
    }

    func mutatePrompt(
        connectionID: UUID,
        mutation: (inout String) -> Void
    ) async throws -> String {
        let invocation = ToolInvocationContext.trustedLocal(
            toolName: "prompt",
            metadata: .init(connectionID: connectionID, clientName: "prompt-mutation-test", windowID: window.windowID)
        )
        return try await MCPInvocationContextBridge.withInvocation(invocation) {
            try await window.mcpServer.updateCurrentTabPrompt(route: window.mcpServer.routeResources, toolName: "prompt", mutation: mutation)
        }
    }

    func installContext(selection: StoredSelection) throws -> MCPServerViewModel.TabContextSnapshot {
        let context = try makeContext(selection: selection)
        window.mcpServer.runRouteBindings.tabContextByConnectionID[connectionID] = context
        return context
    }

    func makeContext(selection: StoredSelection, routeID: Int? = nil) throws -> MCPServerViewModel.TabContextSnapshot {
        let tab = try XCTUnwrap(window.workspaceManager.composeTab(for: identity))
        return MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: routeID ?? window.windowID,
            workspaceID: workspaceID,
            promptText: tab.promptText,
            selection: selection,
            selectionRevision: window.workspaceManager.selectionRevisionForMCP(
                workspaceID: workspaceID,
                tabID: tabID
            ),
            selectedMetaPromptIDs: tab.selectedMetaPromptIDs,
            selectedContextBuilderPromptIDs: tab.contextBuilder.selectedContextBuilderPromptIDs,
            tabName: tab.name,
            runID: runID,
            explicitlyBound: false
        )
    }

    func cleanup() {
        // The shared fixture teardown joins saves before removing roots/sidecars.
        WindowStatesManager.shared.unregisterWindowState(window)
    }
}

private extension MCPServerViewModel.TabContextSnapshot {
    func withSelection(_ selection: StoredSelection) -> Self {
        var copy = self
        copy.selection = selection
        return copy
    }
}
