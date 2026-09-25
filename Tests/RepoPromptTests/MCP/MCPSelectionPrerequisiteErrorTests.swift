import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    /// Negative controls for the read-file auto-selection drain consumers that #1049 left out of
    /// scope. Each of these tools throws `CancellationError` for any drain that does not complete,
    /// and `runTool` turns that into `MCPToolExecutionCancelledError`.
    ///
    /// Every test drives a real bound `read_file`, then holds either the physical mirror or the
    /// canonical apply with a DEBUG gate, so the tool observes a real deferred or invalidated
    /// prerequisite. Classification assertions state the intended behavior and fail while the
    /// defect exists. Harness assertions (the tool waited on the read's own work, dispatched
    /// nothing and rolled nothing back) and the controls pass on current main.
    @MainActor
    final class MCPSelectionPrerequisiteErrorTests: XCTestCase {
        typealias ToolReply = (content: [MCP.Tool.Content], isError: Bool?)

        func testDeferredManageSelectionPrerequisiteIsNotCancellation() async throws {
            try await withPrerequisite(timeout: .zero) { prerequisite in
                try await prerequisite.acceptRead()
                let error = try await prerequisite.driver.fixture.perform("registered manage_selection deferred prerequisite") {
                    await prerequisite.invokeFailure(MCPWindowToolName.manageSelection, prerequisite.addArguments)
                }
                prerequisite.assertPrerequisiteError(error, outcome: "deferred")
                prerequisite.assertMirrorWaiterSettled()
                prerequisite.assertSelectionUnchanged()
                XCTAssertTrue(prerequisite.server.isReadFileAutoSelectionContextCurrent(prerequisite.owner))
            }
        }

        func testInvalidatedManageSelectionPrerequisiteIsNotCancellation() async throws {
            try await withPrerequisite(timeout: .seconds(60)) { prerequisite in
                try await prerequisite.acceptRead()
                let completed = XCTestExpectation(description: "invalidated manage_selection returned")
                var failure: Error?
                prerequisite.startInvocation {
                    failure = await prerequisite.invokeFailure(MCPWindowToolName.manageSelection, prerequisite.addArguments)
                    completed.fulfill()
                }
                try await prerequisite.awaitPendingMirrorWaiter()
                prerequisite.invalidateBinding()
                try await prerequisite.driver.fixture.awaitGateEvent(completed)
                let error = try XCTUnwrap(failure)
                prerequisite.assertPrerequisiteError(error, outcome: "invalidated")
                prerequisite.assertMirrorWaiterSettled()
                prerequisite.assertSelectionUnchanged()
            }
        }

        func testSocketDeferredManageSelectionPrerequisiteIsNotCancellation() async throws {
            for rawJSON in [false, true] {
                try await withPrerequisite(timeout: .zero) { prerequisite in
                    try await prerequisite.acceptRead()
                    let arguments = prerequisite.addArguments.merging(["_rawJSON": .bool(rawJSON)]) { $1 }
                    let reply = try await prerequisite.driver.fixture.perform("socket manage_selection deferred prerequisite raw=\(rawJSON)") {
                        try await prerequisite.call(MCPWindowToolName.manageSelection, arguments)
                    }
                    try prerequisite.assertCallerVisiblePrerequisiteError(reply, rawJSON: rawJSON, outcome: "deferred")
                    prerequisite.assertMirrorWaiterSettled()
                    prerequisite.assertSelectionUnchanged()
                }
            }
        }

        func testDeferredAskOraclePrerequisiteIsNotCancellation() async throws {
            try await withPrerequisite(timeout: .zero) { prerequisite in
                try await prerequisite.acceptRead()
                let sends = SendCounter()
                prerequisite.server.setOracleChatSendOverrideForTesting { _, _, _ in
                    sends.value += 1
                    throw UnexpectedDispatch()
                }
                let error = try await prerequisite.driver.fixture.perform("registered ask_oracle deferred prerequisite") {
                    await prerequisite.invokeFailure(MCPWindowToolName.askOracle, ["message": .string("prerequisite regression")])
                }
                prerequisite.assertPrerequisiteError(error, outcome: "deferred")
                XCTAssertEqual(sends.value, 0, "An unsatisfied prerequisite must not dispatch an Oracle request")
                prerequisite.assertMirrorWaiterSettled()
                prerequisite.assertSelectionUnchanged()
            }
        }

        func testSocketDeferredWorkspaceContextPrerequisiteIsNotCancellation() async throws {
            try await withPrerequisite(timeout: .zero) { prerequisite in
                try await prerequisite.acceptRead()
                let reply = try await prerequisite.driver.fixture.perform("socket workspace_context deferred prerequisite") {
                    try await prerequisite.call(MCPWindowToolName.workspaceContext, ["include": .array([.string("selection")])])
                }
                try prerequisite.assertCallerVisiblePrerequisiteError(reply, rawJSON: false, outcome: "deferred")
                prerequisite.assertMirrorWaiterSettled()
                prerequisite.assertSelectionUnchanged()
            }
        }

        func testSocketInvalidatedSelectedFileTreePrerequisiteIsNotCancellation() async throws {
            try await assertSocketInvalidatedCanonicalPrerequisite(
                MCPWindowToolName.getFileTree,
                ["mode": .string("selected")]
            )
        }

        func testSocketInvalidatedCodeStructurePrerequisiteIsNotCancellation() async throws {
            // Without `paths`, get_code_structure seeds from the canonical selection.
            try await assertSocketInvalidatedCanonicalPrerequisite(MCPWindowToolName.getCodeStructure, [:])
        }

        func testCancellationWhileWaitingRemainsCancellation() async throws {
            try await withPrerequisite(timeout: .seconds(60)) { prerequisite in
                try await prerequisite.acceptRead()
                let completed = XCTestExpectation(description: "cancelled manage_selection returned")
                var failure: Error?
                let invocation = prerequisite.startInvocation {
                    failure = await prerequisite.invokeFailure(MCPWindowToolName.manageSelection, prerequisite.addArguments)
                    completed.fulfill()
                }
                try await prerequisite.awaitPendingMirrorWaiter()
                invocation.cancel()
                try await prerequisite.driver.fixture.awaitGateEvent(completed)
                let error = try XCTUnwrap(failure)
                XCTAssertTrue(error is MCPToolExecutionCancelledError, "runTool must normalize genuine cancellation: \(error)")
                XCTAssertTrue(MCPToolExecutionCancelledError.matches(error))
                prerequisite.assertMirrorWaiterSettled()
                prerequisite.assertSelectionUnchanged()
                XCTAssertTrue(prerequisite.server.isReadFileAutoSelectionContextCurrent(prerequisite.owner))
            }
        }

        func testCompletedPrerequisitePermitsManageSelection() async throws {
            try await withPrerequisite(timeout: .seconds(60)) { prerequisite in
                try await prerequisite.acceptRead()
                try await prerequisite.releaseMirror()
                let drained = await prerequisite.coordinator.drain(.mirroredSelectionAndMetrics, for: prerequisite.owner)
                XCTAssertEqual(drained, .completed, "converged mirror control")
                let reply = try await prerequisite.driver.fixture.perform("socket manage_selection completed control") {
                    try await prerequisite.call(MCPWindowToolName.manageSelection, prerequisite.addArguments)
                }
                XCTAssertNotEqual(reply.isError, true, ContextBuilderMultiRootDiscoveryDriver.text(reply))
                let selection = try XCTUnwrap(prerequisite.currentSelection)
                XCTAssertTrue(selection.selectedPaths.contains(prerequisite.readPath))
                XCTAssertTrue(selection.selectedPaths.contains(prerequisite.addPath))
            }
        }

        func testCompletedCanonicalPrerequisitePermitsSelectedFileTree() async throws {
            try await withPrerequisite(timeout: .seconds(60)) { prerequisite in
                try await prerequisite.acceptRead()
                // The physical mirror stays held: canonical-only consumers must not wait for it.
                let reply = try await prerequisite.driver.fixture.perform("socket get_file_tree completed control") {
                    try await prerequisite.call(MCPWindowToolName.getFileTree, ["mode": .string("selected")])
                }
                let text = ContextBuilderMultiRootDiscoveryDriver.text(reply)
                XCTAssertNotEqual(reply.isError, true, text)
                XCTAssertTrue(text.contains("README.md"), text)
                XCTAssertEqual(prerequisite.coordinator.debugSnapshot().mirrorWorkerCount, 1)
            }
        }

        private func assertSocketInvalidatedCanonicalPrerequisite(
            _ toolName: String,
            _ arguments: [String: MCP.Value]
        ) async throws {
            try await withPrerequisite(timeout: .seconds(60), holdsCanonicalApply: true) { prerequisite in
                try await prerequisite.acceptReadHoldingCanonicalApply()
                let completed = XCTestExpectation(description: "invalidated \(toolName) returned")
                var reply: ToolReply?
                var transportError: Error?
                prerequisite.startInvocation {
                    do {
                        reply = try await prerequisite.call(toolName, arguments)
                    } catch {
                        transportError = error
                    }
                    completed.fulfill()
                }
                try await prerequisite.awaitPendingCanonicalWaiter()
                prerequisite.invalidateBinding()
                try await prerequisite.driver.fixture.awaitGateEvent(completed)
                XCTAssertNil(transportError, "\(toolName) failed at the transport: \(String(describing: transportError))")
                try prerequisite.assertCallerVisiblePrerequisiteError(XCTUnwrap(reply), rawJSON: false, outcome: "invalidated")
                prerequisite.assertCanonicalWaiterSettled()
                prerequisite.assertSelectionUnchanged()
            }
        }

        private func withPrerequisite(
            timeout: Duration,
            holdsCanonicalApply: Bool = false,
            _ body: @escaping (Prerequisite) async throws -> Void
        ) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(routedRuntime: true) { driver in
                let context = try await driver.resolve()
                let connection = try await driver.fixture.perform("admitted prerequisite connection") {
                    try await driver.connectInvokingAgent(context)
                }
                let prerequisite = try Prerequisite(
                    driver: driver,
                    connection: connection,
                    timeout: timeout,
                    holdsCanonicalApply: holdsCanonicalApply
                )
                do {
                    try await body(prerequisite)
                    await prerequisite.cleanup()
                } catch {
                    await prerequisite.cleanup()
                    throw error
                }
            }
        }

        /// One bound Agent Mode connection with a real accepted read and DEBUG gates on its lanes.
        @MainActor
        private final class Prerequisite {
            let driver: ContextBuilderMultiRootDiscoveryDriver
            let connection: ContextBuilderMultiRootDiscoveryDriver.RoutedConnection
            let owner: MCPReadFileAutoSelectionCoordinator.ContextKey
            let probe: DiagnosticProbe
            let mirrorGate: WorkspaceAuthorityRootTestFixture.Gate
            let canonicalGate: WorkspaceAuthorityRootTestFixture.Gate?
            let mirrorEntered = XCTestExpectation(description: "real physical mirror entered")
            let canonicalEntered = XCTestExpectation(description: "real canonical apply entered")
            let readPath: String
            let addPath: String
            var acceptedSelection: StoredSelection?
            var acceptedSequence: UInt64?
            var requiredTicket: UInt64?
            private var mirrorJoined = false
            private var invocations: [Task<Void, Never>] = []

            var server: MCPServerViewModel {
                driver.window.mcpServer
            }

            var coordinator: MCPReadFileAutoSelectionCoordinator {
                server.readFileAutoSelectionCoordinator
            }

            var currentSelection: StoredSelection? {
                driver.manager.composeTab(for: .init(workspaceID: driver.fixture.workspace.id, tabID: owner.tabID))?.selection
            }

            var addArguments: [String: MCP.Value] {
                ["op": .string("add"), "paths": .array([.string(addPath)])]
            }

            init(
                driver: ContextBuilderMultiRootDiscoveryDriver,
                connection: ContextBuilderMultiRootDiscoveryDriver.RoutedConnection,
                timeout: Duration,
                holdsCanonicalApply: Bool
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
                canonicalGate = holdsCanonicalApply ? driver.fixture.makeGate() : nil
                readPath = driver.fixture.rootPaths[0] + "/README.md"
                addPath = driver.fixture.rootPaths[1] + "/README.md"
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
                if let canonicalGate {
                    let canonicalEntered = canonicalEntered
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                        canonicalEntered.fulfill()
                        await canonicalGate.wait()
                    }
                }
                coordinator.setMirrorWaitTimeoutForTesting(timeout)
            }

            /// Accepts and applies a real read's canonical selection while its physical mirror is held.
            func acceptRead() async throws {
                let before = try XCTUnwrap(currentSelection)
                XCTAssertFalse(before.selectedPaths.contains(readPath))
                XCTAssertFalse(before.selectedPaths.contains(addPath))
                let reply = try await driver.fixture.perform("real prerequisite read") {
                    try await self.call(MCPWindowToolName.readFile, ["path": .string(self.readPath)])
                }
                XCTAssertNotEqual(reply.isError, true, ContextBuilderMultiRootDiscoveryDriver.text(reply))
                try await driver.fixture.awaitGateEvent(mirrorEntered)
                try await driver.fixture.awaitGateEvent(probe.canonicalStopped)
                let state = try XCTUnwrap(coordinator.debugContextSnapshot(for: owner))
                XCTAssertGreaterThan(state.acceptedHighWaterSequence, 0)
                XCTAssertEqual(state.completedHighWaterSequence, state.acceptedHighWaterSequence)
                XCTAssertEqual(state.changedApplyCount, 1)
                acceptedSequence = state.acceptedHighWaterSequence
                requiredTicket = try XCTUnwrap(probe.events().last(where: {
                    $0.lane == .canonical && $0.kind == .workerStopped
                })?.requiredMirrorTicket)
                XCTAssertGreaterThan(try XCTUnwrap(requiredTicket), 0)
                acceptedSelection = try XCTUnwrap(currentSelection)
                XCTAssertTrue(try XCTUnwrap(acceptedSelection).selectedPaths.contains(readPath))
                XCTAssertNotEqual(acceptedSelection, before)
                XCTAssertEqual(coordinator.debugSnapshot().mirrorWaiterCount, 0)
                XCTAssertEqual(coordinator.debugSnapshot().mirrorWorkerCount, 1)
                XCTAssertTrue(server.isReadFileAutoSelectionContextCurrent(owner))
            }

            /// Accepts a real read whose canonical apply is held before it mutates the selection.
            func acceptReadHoldingCanonicalApply() async throws {
                let before = try XCTUnwrap(currentSelection)
                XCTAssertFalse(before.selectedPaths.contains(readPath))
                let reply = try await driver.fixture.perform("real prerequisite read before its canonical apply") {
                    try await self.call(MCPWindowToolName.readFile, ["path": .string(self.readPath)])
                }
                XCTAssertNotEqual(reply.isError, true, ContextBuilderMultiRootDiscoveryDriver.text(reply))
                try await driver.fixture.awaitGateEvent(canonicalEntered)
                let state = try XCTUnwrap(coordinator.debugContextSnapshot(for: owner))
                XCTAssertGreaterThan(state.acceptedHighWaterSequence, state.completedHighWaterSequence)
                XCTAssertTrue(state.workerActive)
                XCTAssertFalse(state.pendingWork)
                XCTAssertEqual(state.canonicalApplyAttemptCount, 0)
                acceptedSequence = state.acceptedHighWaterSequence
                acceptedSelection = before
                XCTAssertEqual(currentSelection, before, "The held canonical apply must not have landed")
                XCTAssertEqual(coordinator.debugSnapshot().canonicalWaiterCount, 0)
                XCTAssertTrue(server.isReadFileAutoSelectionContextCurrent(owner))
            }

            func call(_ toolName: String, _ arguments: [String: MCP.Value]) async throws -> ToolReply {
                try await connection.client.callTool(name: toolName, arguments: arguments)
            }

            /// Calls the registered window tool directly so `runTool` normalizes the thrown error.
            func invokeFailure(_ toolName: String, _ arguments: [String: MCP.Value]) async -> Error {
                do {
                    let tools = await server.windowMCPTools
                    let tool = try XCTUnwrap(tools.first { $0.name == toolName }, "\(toolName) is not a registered window tool")
                    server.setRequestMetadataOverrideForTesting(.init(
                        connectionID: connection.connectionID, clientName: nil, windowID: owner.windowID,
                        runPurpose: .agentModeRun,
                        tabContextHint: .init(tabID: owner.tabID, workspaceID: owner.workspaceID, windowID: owner.windowID)
                    ))
                    defer { server.setRequestMetadataOverrideForTesting(nil) }
                    _ = try await tool(arguments)
                    XCTFail("An unsatisfied selection prerequisite must reject \(toolName)")
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

            func awaitPendingMirrorWaiter() async throws {
                try await driver.fixture.awaitGateEvent(probe.mirrorWaiterRegistered)
                let waiter = try XCTUnwrap(probe.events().last { $0.lane == .mirror && $0.kind == .waiterRegistered })
                XCTAssertEqual(waiter.target, requiredTicket)
                XCTAssertNotNil(waiter.waiterID)
                XCTAssertTrue(server.isReadFileAutoSelectionContextCurrent(owner))
                XCTAssertEqual(coordinator.debugSnapshot().mirrorWaiterCount, 1)
                XCTAssertEqual(coordinator.debugSnapshot().liveMirrorDeadlineCount, 1)
            }

            func awaitPendingCanonicalWaiter() async throws {
                try await driver.fixture.awaitGateEvent(probe.canonicalWaiterRegistered)
                let waiter = try XCTUnwrap(probe.events().last { $0.lane == .canonical && $0.kind == .waiterRegistered })
                XCTAssertEqual(waiter.target, acceptedSequence)
                XCTAssertNotNil(waiter.waiterID)
                XCTAssertTrue(server.isReadFileAutoSelectionContextCurrent(owner))
                XCTAssertEqual(coordinator.debugSnapshot().canonicalWaiterCount, 1)
            }

            /// Releases the exact binding while the tool waits, which invalidates its drain context.
            func invalidateBinding() {
                server.removeTabContext(forConnectionID: connection.connectionID, clientName: nil, windowID: owner.windowID)
                XCTAssertNil(server.tabContextByConnectionID[connection.connectionID])
                XCTAssertFalse(server.isReadFileAutoSelectionContextCurrent(owner))
            }

            func releaseMirror() async throws {
                mirrorGate.release()
                guard !mirrorJoined else { return }
                mirrorJoined = true
                try await driver.fixture.awaitGateEvent(probe.mirrorStopped)
            }

            /// The intended contract: an unsatisfied prerequisite is its own error, not cancellation.
            func assertPrerequisiteError(
                _ error: Error,
                outcome: String,
                file: StaticString = #filePath,
                line: UInt = #line
            ) {
                let description = String(describing: error)
                XCTAssertFalse(
                    MCPToolExecutionCancelledError.matches(error),
                    "The \(outcome) selection prerequisite was reported as cancellation: \(description)",
                    file: file,
                    line: line
                )
                XCTAssertTrue(
                    description.localizedCaseInsensitiveContains(outcome),
                    "The error does not name the \(outcome) prerequisite: \(description)",
                    file: file,
                    line: line
                )
                XCTAssertTrue(
                    error.localizedDescription.localizedCaseInsensitiveContains(outcome),
                    "The localized error does not name the \(outcome) prerequisite: \(error.localizedDescription)",
                    file: file,
                    line: line
                )
            }

            /// The same contract as delivered to the MCP caller over the socket.
            func assertCallerVisiblePrerequisiteError(
                _ reply: ToolReply,
                rawJSON: Bool,
                outcome: String,
                file: StaticString = #filePath,
                line: UInt = #line
            ) throws {
                let text = ContextBuilderMultiRootDiscoveryDriver.text(reply)
                XCTAssertEqual(reply.isError, true, text, file: file, line: line)
                let message: String
                if rawJSON {
                    let json = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                        text,
                        file: file,
                        line: line
                    )
                    XCTAssertEqual(json["is_error"] as? Bool, true, text, file: file, line: line)
                    message = try XCTUnwrap(json["error"] as? String, text, file: file, line: line)
                } else {
                    message = text
                }
                XCTAssertFalse(
                    message.contains("MCPToolExecutionCancelledError"),
                    "The caller saw cancellation for the \(outcome) selection prerequisite: \(message)",
                    file: file,
                    line: line
                )
                XCTAssertTrue(
                    message.localizedCaseInsensitiveContains(outcome),
                    "The caller-visible error does not name the \(outcome) prerequisite: \(message)",
                    file: file,
                    line: line
                )
            }

            func assertMirrorWaiterSettled(file: StaticString = #filePath, line: UInt = #line) {
                let waiter = probe.events().last { $0.lane == .mirror && $0.kind == .waiterRegistered }
                XCTAssertEqual(waiter?.target, requiredTicket, "The tool did not wait on the read's mirror ticket", file: file, line: line)
                XCTAssertNotNil(waiter?.waiterID, file: file, line: line)
                XCTAssertEqual(coordinator.debugSnapshot().mirrorWaiterCount, 0, file: file, line: line)
                XCTAssertEqual(coordinator.debugSnapshot().liveMirrorDeadlineCount, 0, file: file, line: line)
            }

            func assertCanonicalWaiterSettled(file: StaticString = #filePath, line: UInt = #line) {
                let waiter = probe.events().last { $0.lane == .canonical && $0.kind == .waiterRegistered }
                XCTAssertEqual(waiter?.target, acceptedSequence, "The tool did not wait on the read's canonical work", file: file, line: line)
                XCTAssertNotNil(waiter?.waiterID, file: file, line: line)
                XCTAssertEqual(coordinator.debugSnapshot().canonicalWaiterCount, 0, file: file, line: line)
            }

            /// Neither the rejected tool's own change nor a rollback of the read's accepted selection.
            func assertSelectionUnchanged(file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertEqual(currentSelection, acceptedSelection, "The rejected tool changed the stored selection", file: file, line: line)
                XCTAssertFalse(currentSelection?.selectedPaths.contains(addPath) ?? false, file: file, line: line)
            }

            func cleanup() async {
                invocations.forEach { $0.cancel() }
                canonicalGate?.release()
                mirrorGate.release()
                for task in invocations {
                    await task.value
                }
                server.setRequestMetadataOverrideForTesting(nil)
                server.setOracleChatSendOverrideForTesting(nil)
                coordinator.setMirrorWaitTimeoutForTesting(.seconds(10))
                server.setReadFileAutoSelectionMirrorGateForTesting(nil)
                server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                server.removeTabContext(
                    forConnectionID: connection.connectionID, clientName: nil, windowID: owner.windowID
                )
                if canonicalGate != nil, probe.events().contains(where: { $0.lane == .canonical && $0.kind == .workerStarted }) {
                    let result = await XCTWaiter.fulfillment(of: [probe.canonicalStopped], timeout: 5)
                    XCTAssertEqual(result, .completed, "The held canonical apply must settle before fixture shutdown")
                }
                if !mirrorJoined, probe.events().contains(where: { $0.lane == .mirror && $0.kind == .workerStarted }) {
                    mirrorJoined = true
                    let result = await XCTWaiter.fulfillment(of: [probe.mirrorStopped], timeout: 5)
                    XCTAssertEqual(result, .completed, "Physical mirror must settle before fixture shutdown")
                }
                MCPReadFileAutoSelectionDiagnosticTracer.setTestSink(nil)
                let state = coordinator.debugSnapshot()
                XCTAssertEqual(state.canonicalWaiterCount, 0)
                XCTAssertEqual(state.canonicalWorkerCount, 0)
                XCTAssertEqual(state.mirrorWaiterCount, 0)
                XCTAssertEqual(state.liveMirrorDeadlineCount, 0)
                XCTAssertEqual(state.retiredMirrorWorkerCount, 0)
                XCTAssertEqual(state.mirrorWorkerCount, 0)
            }
        }

        @MainActor
        private final class SendCounter {
            var value = 0
        }

        private struct UnexpectedAdmission: Error {}

        private struct UnexpectedDispatch: Error {}

        /// The global tracer is owned only inside the isolated driver's lifetime. Mirror events are
        /// tab-scoped; canonical events must also match the owner's binding generation.
        private final class DiagnosticProbe: @unchecked Sendable {
            let owner: MCPReadFileAutoSelectionCoordinator.ContextKey
            let canonicalStopped = XCTestExpectation(description: "canonical worker settled")
            let mirrorStopped = XCTestExpectation(description: "physical mirror worker settled")
            let mirrorWaiterRegistered = XCTestExpectation(description: "mirror drain waiter registered")
            let canonicalWaiterRegistered = XCTestExpectation(description: "canonical drain waiter registered")
            private let lock = NSLock()
            private var recorded: [MCPReadFileAutoSelectionDiagnosticEvent] = []

            init(owner: MCPReadFileAutoSelectionCoordinator.ContextKey) {
                self.owner = owner
                for expectation in [canonicalStopped, mirrorStopped, mirrorWaiterRegistered, canonicalWaiterRegistered] {
                    expectation.assertForOverFulfill = false
                }
            }

            func record(_ event: MCPReadFileAutoSelectionDiagnosticEvent) {
                guard event.windowID == owner.windowID, event.workspaceID == owner.workspaceID,
                      event.tabID == owner.tabID,
                      event.lane == .mirror || event.bindingGeneration == owner.bindingGeneration
                else { return }
                lock.lock()
                recorded.append(event)
                lock.unlock()
                switch (event.lane, event.kind) {
                case (.canonical, .workerStopped):
                    canonicalStopped.fulfill()
                case (.mirror, .workerStopped):
                    mirrorStopped.fulfill()
                case (.mirror, .waiterRegistered):
                    mirrorWaiterRegistered.fulfill()
                case (.canonical, .waiterRegistered):
                    canonicalWaiterRegistered.fulfill()
                default:
                    break
                }
            }

            func events() -> [MCPReadFileAutoSelectionDiagnosticEvent] {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }
        }
    }
#endif
