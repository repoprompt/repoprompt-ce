import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class ContextBuilderSelectionPrerequisiteTests: XCTestCase {
        func testDeferredPrerequisiteRemainsNonCancellationAfterRunTool() async throws {
            try await withPrerequisite(timeout: .zero) { prerequisite in
                try await prerequisite.acceptRead()
                let error = try await prerequisite.driver.fixture.perform("registered deferred prerequisite") {
                    await prerequisite.invokeFailure()
                }
                XCTAssertEqual(error as? MCPContextBuilderSelectionPrerequisiteError, .deferred)
                XCTAssertFalse(MCPToolExecutionCancelledError.matches(error), "A noncancelled prerequisite was reported as cancellation: \(error)")
                XCTAssertEqual(String(describing: error), Self.deferredDescription)
                XCTAssertEqual(error.localizedDescription, Self.deferredDescription)
                prerequisite.assertRejectedWithoutRollback()
            }
        }

        func testInvalidatedPrerequisiteRemainsNonCancellationAfterRunTool() async throws {
            try await withPrerequisite(timeout: .seconds(60)) { prerequisite in
                try await prerequisite.acceptRead()
                let completed = XCTestExpectation(description: "invalidated invocation returned")
                var failure: Error?
                prerequisite.startInvocation {
                    failure = await prerequisite.invokeFailure()
                    completed.fulfill()
                }
                try await prerequisite.awaitPendingWaiter()
                prerequisite.server.removeTabContext(
                    forConnectionID: prerequisite.connection.connectionID, clientName: nil,
                    windowID: prerequisite.owner.windowID
                )
                try await prerequisite.driver.fixture.awaitGateEvent(completed)
                let error = try XCTUnwrap(failure)
                XCTAssertEqual(error as? MCPContextBuilderSelectionPrerequisiteError, .invalidated)
                XCTAssertFalse(MCPToolExecutionCancelledError.matches(error))
                XCTAssertEqual(String(describing: error), Self.invalidatedDescription)
                XCTAssertEqual(error.localizedDescription, Self.invalidatedDescription)
                XCTAssertNil(prerequisite.server.tabContextByConnectionID[prerequisite.connection.connectionID])
                prerequisite.assertRejectedWithoutRollback(bindingPreserved: false)
            }
        }

        func testCancellationWhileWaitingPreservesCancellation() async throws {
            try await withPrerequisite(timeout: .seconds(60)) { prerequisite in
                try await prerequisite.acceptRead()
                let completed = XCTestExpectation(description: "cancelled invocation returned")
                var failure: Error?
                let invocation = prerequisite.startInvocation {
                    failure = await prerequisite.invokeFailure()
                    completed.fulfill()
                }
                try await prerequisite.awaitPendingWaiter()
                invocation.cancel()
                try await prerequisite.driver.fixture.awaitGateEvent(completed)
                let error = try XCTUnwrap(failure)
                XCTAssertTrue(error is MCPToolExecutionCancelledError, "runTool must normalize genuine cancellation")
                XCTAssertTrue(MCPToolExecutionCancelledError.matches(error))
                XCTAssertEqual(error.localizedDescription, MCPToolExecutionCancelledError().localizedDescription)
                prerequisite.assertRejectedWithoutRollback()
            }
        }

        func testCompletedAndNoWorkPrerequisitesPermitDiscovery() async throws {
            // Each control has a fresh owner; retained accepted work is not a no-work lane.
            for acceptedWork in [true, false] {
                try await withPrerequisite(timeout: .seconds(60)) { prerequisite in
                    let driver = prerequisite.driver
                    if acceptedWork {
                        try await prerequisite.acceptRead()
                        try await prerequisite.releaseMirror()
                        let result = await prerequisite.coordinator.drain(.mirroredSelectionAndMetrics, for: prerequisite.owner)
                        XCTAssertEqual(result, .completed, "accepted-work convergence control")
                    } else {
                        XCTAssertNil(prerequisite.coordinator.debugContextSnapshot(for: prerequisite.owner), "fresh no-work control")
                        XCTAssertTrue(prerequisite.server.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                            connectionID: prerequisite.connection.connectionID
                        ).isEmpty)
                    }
                    driver.streamBody = { runID in
                        let child = try await driver.connectChild(runID: runID)
                        let reply = try await child.client.callTool(name: "prompt", arguments: [
                            "op": .string("set"), "text": .string("PREREQUISITE_CONTROL_RESULT")
                        ])
                        XCTAssertNotEqual(reply.isError, true, ContextBuilderMultiRootDiscoveryDriver.text(reply))
                    }
                    let reply = try await driver.fixture.perform("completed/no-work discovery control") {
                        try await driver.invoke(using: prerequisite.connection)
                    }
                    XCTAssertNotEqual(reply.isError, true, ContextBuilderMultiRootDiscoveryDriver.text(reply))
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(
                        with: Data(ContextBuilderMultiRootDiscoveryDriver.text(reply).utf8)
                    ) as? [String: Any])
                    XCTAssertEqual(json["status"] as? String, "completed")
                    XCTAssertEqual(json["prompt"] as? String, "PREREQUISITE_CONTROL_RESULT")
                    XCTAssertEqual(driver.streamStarts, 1)
                    let committed = try XCTUnwrap(driver.committed)
                    if acceptedWork { XCTAssertEqual(committed.tab.selection, prerequisite.acceptedSelection) }
                    try await driver.assertReleased(runID: committed.nestedRunID)
                }
            }
        }

        func testSocketDeferredPrerequisitePreservesOrdinaryAndRawErrors() async throws {
            for rawJSON in [false, true] {
                try await withPrerequisite(timeout: .zero) { prerequisite in
                    try await prerequisite.acceptRead()
                    let reply = try await prerequisite.driver.fixture.perform("socket deferred prerequisite raw=\(rawJSON)") {
                        try await prerequisite.connection.client.callTool(name: "context_builder", arguments: [
                            "instructions": .string("prerequisite regression"),
                            "response_type": .string("clarify"), "_rawJSON": .bool(rawJSON)
                        ])
                    }
                    XCTAssertEqual(reply.isError, true)
                    let text = ContextBuilderMultiRootDiscoveryDriver.text(reply)
                    let expected = "Error: " + Self.deferredDescription
                    if rawJSON {
                        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                        XCTAssertEqual(Set(json.keys), Set(["is_error", "error"]))
                        XCTAssertEqual(json["is_error"] as? Bool, true)
                        XCTAssertEqual(json["error"] as? String, expected)
                    } else {
                        XCTAssertEqual(text, expected)
                    }
                    prerequisite.assertRejectedWithoutRollback()
                }
            }
        }

        private static let invalidatedDescription = "context_builder_selection_prerequisite_invalidated: Context Builder discovery was not started because its selection prerequisite was invalidated."
        private static let deferredDescription = "context_builder_selection_prerequisite_deferred: Context Builder discovery was not started because its selection prerequisite was deferred."

        private func withPrerequisite(
            timeout: Duration,
            _ body: @escaping (Prerequisite) async throws -> Void
        ) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(routedRuntime: true) { driver in
                let context = try await driver.resolve()
                let connection = try await driver.fixture.perform("admitted prerequisite connection") {
                    try await driver.connectInvokingAgent(context)
                }
                let prerequisite = try Prerequisite(driver: driver, connection: connection, timeout: timeout)
                do {
                    try await body(prerequisite)
                    await prerequisite.cleanup()
                } catch {
                    await prerequisite.cleanup()
                    throw error
                }
            }
        }

        @MainActor
        private final class Prerequisite {
            let driver: ContextBuilderMultiRootDiscoveryDriver
            let connection: ContextBuilderMultiRootDiscoveryDriver.RoutedConnection
            let owner: MCPReadFileAutoSelectionCoordinator.ContextKey
            let probe: DiagnosticProbe
            let mirrorGate: WorkspaceAuthorityRootTestFixture.Gate
            let mirrorEntered = XCTestExpectation(description: "real physical mirror entered")
            var acceptedSelection: StoredSelection?
            var requiredTicket: UInt64?
            private var mirrorJoined = false
            private var invocations: [Task<Void, Never>] = []

            var server: MCPServerViewModel {
                driver.window.mcpServer
            }

            var coordinator: MCPReadFileAutoSelectionCoordinator {
                server.readFileAutoSelectionCoordinator
            }

            init(
                driver: ContextBuilderMultiRootDiscoveryDriver,
                connection: ContextBuilderMultiRootDiscoveryDriver.RoutedConnection,
                timeout: Duration
            ) throws {
                self.driver = driver
                self.connection = connection
                let snapshot = try driver.promotedSnapshot(for: connection)
                owner = MCPReadFileAutoSelectionCoordinator.ContextKey(
                    windowID: snapshot.windowID, workspaceID: snapshot.workspaceID, tabID: snapshot.tabID,
                    route: .bound(connectionID: connection.connectionID, runID: snapshot.runID),
                    bindingGeneration: snapshot.readFileAutoSelectionGeneration
                )
                probe = DiagnosticProbe(owner: owner)
                mirrorGate = driver.fixture.makeGate()
                XCTAssertTrue(snapshot.worktreeBindings.isEmpty)
                XCTAssertEqual(driver.manager.activeWorkspaceID, owner.workspaceID)
                XCTAssertEqual(driver.manager.activeWorkspace?.activeComposeTabID, owner.tabID)
                XCTAssertNil(coordinator.debugContextSnapshot(for: owner))
                let probe = probe
                MCPReadFileAutoSelectionDiagnosticTracer.setTestSink { probe.record($0) }
                let mirrorGate = mirrorGate
                let mirrorEntered = mirrorEntered
                server.setReadFileAutoSelectionMirrorGateForTesting {
                    mirrorEntered.fulfill()
                    await mirrorGate.wait()
                }
                coordinator.setMirrorWaitTimeoutForTesting(timeout)
            }

            func acceptRead() async throws {
                let path = driver.fixture.rootPaths[0] + "/README.md"
                let before = try XCTUnwrap(driver.manager.composeTab(
                    for: .init(workspaceID: driver.fixture.workspace.id, tabID: owner.tabID)
                )).selection
                XCTAssertFalse(before.selectedPaths.contains(path))
                let reply = try await driver.fixture.perform("real prerequisite read") {
                    try await self.connection.client.callTool(name: "read_file", arguments: ["path": .string(path)])
                }
                XCTAssertNotEqual(reply.isError, true, ContextBuilderMultiRootDiscoveryDriver.text(reply))
                try await driver.fixture.awaitGateEvent(mirrorEntered)
                try await driver.fixture.awaitGateEvent(probe.canonicalStopped)
                let state = try XCTUnwrap(coordinator.debugContextSnapshot(for: owner))
                XCTAssertGreaterThan(state.acceptedHighWaterSequence, 0)
                XCTAssertEqual(state.completedHighWaterSequence, state.acceptedHighWaterSequence)
                XCTAssertEqual(state.changedApplyCount, 1)
                requiredTicket = try XCTUnwrap(probe.events().last(where: {
                    $0.lane == .canonical && $0.kind == .workerStopped
                })?.requiredMirrorTicket)
                XCTAssertGreaterThan(try XCTUnwrap(requiredTicket), 0)
                acceptedSelection = try XCTUnwrap(driver.manager.composeTab(
                    for: .init(workspaceID: driver.fixture.workspace.id, tabID: owner.tabID)
                )).selection
                XCTAssertTrue(try XCTUnwrap(acceptedSelection).selectedPaths.contains(path))
                XCTAssertNotEqual(acceptedSelection, before)
                XCTAssertEqual(coordinator.debugSnapshot().mirrorWaiterCount, 0)
                XCTAssertEqual(coordinator.debugSnapshot().mirrorWorkerCount, 1)
                XCTAssertTrue(server.isReadFileAutoSelectionContextCurrent(owner))
            }

            func invokeFailure() async -> Error {
                do {
                    let tools = await server.windowMCPTools
                    let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.contextBuilder })
                    server.setRequestMetadataOverrideForTesting(.init(
                        connectionID: connection.connectionID, clientName: nil, windowID: owner.windowID,
                        runPurpose: .agentModeRun,
                        tabContextHint: .init(tabID: owner.tabID, workspaceID: owner.workspaceID, windowID: owner.windowID)
                    ))
                    defer { server.setRequestMetadataOverrideForTesting(nil) }
                    _ = try await tool(["instructions": .string("prerequisite regression"), "response_type": .string("clarify")])
                    XCTFail("An unsatisfied prerequisite must reject discovery")
                    return UnexpectedAdmission()
                } catch {
                    return error
                }
            }

            @discardableResult
            func startInvocation(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
                let task = driver.fixture.startOwnedTask(operation)
                invocations.append(task)
                return task
            }

            func awaitPendingWaiter() async throws {
                try await driver.fixture.awaitGateEvent(probe.waiterRegistered)
                let waiter = try XCTUnwrap(probe.events().last { $0.lane == .mirror && $0.kind == .waiterRegistered })
                XCTAssertEqual(waiter.target, requiredTicket)
                XCTAssertNotNil(waiter.waiterID)
                XCTAssertTrue(server.isReadFileAutoSelectionContextCurrent(owner))
                XCTAssertEqual(coordinator.debugSnapshot().mirrorWaiterCount, 1)
                XCTAssertEqual(coordinator.debugSnapshot().liveMirrorDeadlineCount, 1)
            }

            func releaseMirror() async throws {
                mirrorGate.release()
                guard !mirrorJoined else { return }
                mirrorJoined = true
                try await driver.fixture.awaitGateEvent(probe.mirrorStopped)
            }

            func assertRejectedWithoutRollback(bindingPreserved: Bool = true) {
                XCTAssertEqual(driver.constructed, 0)
                XCTAssertEqual(driver.streamStarts, 0)
                XCTAssertEqual(driver.manager.composeTab(
                    for: .init(workspaceID: driver.fixture.workspace.id, tabID: owner.tabID)
                )?.selection, acceptedSelection)
                if bindingPreserved {
                    XCTAssertTrue(server.isReadFileAutoSelectionContextCurrent(owner))
                }
                let waiter = probe.events().last { $0.lane == .mirror && $0.kind == .waiterRegistered }
                XCTAssertEqual(waiter?.target, requiredTicket)
                XCTAssertNotNil(waiter?.waiterID)
                XCTAssertEqual(coordinator.debugSnapshot().mirrorWaiterCount, 0)
                XCTAssertEqual(coordinator.debugSnapshot().liveMirrorDeadlineCount, 0)
            }

            func cleanup() async {
                invocations.forEach { $0.cancel() }
                mirrorGate.release()
                for task in invocations {
                    await task.value
                }
                server.setRequestMetadataOverrideForTesting(nil)
                coordinator.setMirrorWaitTimeoutForTesting(.seconds(10))
                server.setReadFileAutoSelectionMirrorGateForTesting(nil)
                server.removeTabContext(
                    forConnectionID: connection.connectionID, clientName: nil, windowID: owner.windowID
                )
                mirrorGate.release()
                if !mirrorJoined, probe.events().contains(where: { $0.lane == .mirror && $0.kind == .workerStarted }) {
                    mirrorJoined = true
                    let result = await XCTWaiter.fulfillment(of: [probe.mirrorStopped], timeout: 5)
                    XCTAssertEqual(result, .completed, "Physical mirror must settle before fixture shutdown")
                }
                MCPReadFileAutoSelectionDiagnosticTracer.setTestSink(nil)
                let state = coordinator.debugSnapshot()
                XCTAssertEqual(state.canonicalWaiterCount, 0)
                XCTAssertEqual(state.mirrorWaiterCount, 0)
                XCTAssertEqual(state.liveMirrorDeadlineCount, 0)
                XCTAssertEqual(state.retiredMirrorWorkerCount, 0)
                XCTAssertEqual(state.mirrorWorkerCount, 0)
            }
        }

        private struct UnexpectedAdmission: Error {}

        /// The global tracer is owned only inside the isolated driver's lifetime. Mirror events
        /// are tab-scoped: the sole invocation and required ticket establish owner correlation.
        private final class DiagnosticProbe: @unchecked Sendable {
            let owner: MCPReadFileAutoSelectionCoordinator.ContextKey
            let canonicalStopped = XCTestExpectation(description: "canonical work settled with ticket")
            let mirrorStopped = XCTestExpectation(description: "physical mirror worker settled")
            let waiterRegistered = XCTestExpectation(description: "mirror drain waiter registered")
            private let lock = NSLock()
            private var recorded: [MCPReadFileAutoSelectionDiagnosticEvent] = []

            init(owner: MCPReadFileAutoSelectionCoordinator.ContextKey) {
                self.owner = owner
                canonicalStopped.assertForOverFulfill = false
                mirrorStopped.assertForOverFulfill = false
                waiterRegistered.assertForOverFulfill = false
            }

            func record(_ event: MCPReadFileAutoSelectionDiagnosticEvent) {
                guard event.windowID == owner.windowID, event.workspaceID == owner.workspaceID,
                      event.tabID == owner.tabID,
                      event.lane == .mirror || event.bindingGeneration == owner.bindingGeneration
                else { return }
                lock.lock()
                recorded.append(event)
                lock.unlock()
                if event.kind == .workerStopped {
                    if event.lane == .canonical { canonicalStopped.fulfill() }
                    else { mirrorStopped.fulfill() }
                }
                if event.lane == .mirror, event.kind == .waiterRegistered { waiterRegistered.fulfill() }
            }

            func events() -> [MCPReadFileAutoSelectionDiagnosticEvent] {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }
        }
    }
#endif
