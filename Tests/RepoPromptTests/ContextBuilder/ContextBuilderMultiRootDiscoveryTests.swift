import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class ContextBuilderMultiRootDiscoveryTests: XCTestCase {
        func testActualSocketMultiRootDiscoveryCommitsRoutedSelectionAndPrompt() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A", "B", "Unrelated"], routedRuntime: true) { driver in
                let context = try await driver.resolve()
                let authority = try await driver.authority(context)
                let observer = try XCTUnwrap(driver.vm.armStartupObservationForTesting(
                    windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id,
                    tabID: driver.tabID, invokingRunID: context.frozenTabContext.runID!
                ))
                driver.streamBody = { runID in
                    let connection = try await driver.connectChild(runID: runID)
                    let binding = driver.window.mcpServer.connectionBindingSnapshot(forConnection: connection.connectionID)
                    XCTAssertEqual(binding.runID, runID)
                    XCTAssertEqual(binding.workspaceID, driver.fixture.workspace.id)
                    try await driver.discover(using: connection)
                }
                let completion = try await driver.fixture.perform("actual routed discovery commit") {
                    try await driver.run(context, authority: authority)
                }
                XCTAssertEqual(completion.terminalDisposition, .completed)
                let committed = try XCTUnwrap(completion.committedTab)
                XCTAssertEqual(committed.tab.promptText, "ROUTED_DISCOVERY_RESULT")
                XCTAssertEqual(Set(committed.tab.selection.selectedPaths), Set(driver.fixture.rootPaths.prefix(2).map { $0 + "/README.md" }))
                XCTAssertEqual(driver.committed?.nestedRunID, completion.runID)
                try await driver.assertReleased(runID: completion.runID)
                try await driver.assertRoutedLeaseReleasedExactlyOnce(runID: completion.runID)
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.streamStarts, 1)
                XCTAssertEqual(driver.disposed, 1)
                XCTAssertEqual(observer.streamStartCount, 1)
                XCTAssertEqual(observer.runTerminalCount, 1)
                XCTAssertEqual(observer.teardownCount, 1)
                for connection in driver.connections {
                    await connection.cleanup()
                    XCTAssertEqual(connection.cleanupCount, 1)
                }
            }
        }

        func testActualSocketReplacementAfterStreamingRejectsReadAndNeverCommitsStaleResult() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A", "B", "Unrelated"], routedRuntime: true) { driver in
                let context = try await driver.resolve()
                let authority = try await driver.authority(context)
                let original = try XCTUnwrap(context.primaryRootSnapshot).roots
                driver.streamBody = { runID in
                    let connection = try await driver.connectChild(runID: runID)
                    try await driver.discover(using: connection)
                    let before = try driver.promotedSnapshot(for: connection)
                    XCTAssertEqual(before.frozenLookupContext?.rootScope, context.lookupContext.rootScope)
                    await driver.files.unloadRootFolderPath(driver.fixture.rootPaths[1])
                    try "REPLACEMENT_SENTINEL_MUST_NOT_LEAK".write(
                        toFile: driver.fixture.rootPaths[1] + "/README.md", atomically: true, encoding: .utf8
                    )
                    try await driver.files.loadFolder(at: URL(fileURLWithPath: driver.fixture.rootPaths[1]), for: driver.fixture.workspace)
                    let replacement = await driver.files.workspaceFileContextStore.primaryRootReadinessObservation(orderedPaths: Array(driver.fixture.rootPaths.prefix(2)))
                    XCTAssertNotEqual(replacement.requestedRoots[1].id, original[1].id)
                    let read = try await connection.client.callTool(name: "read_file", arguments: ["path": .string(driver.fixture.rootPaths[1] + "/README.md")])
                    XCTAssertEqual(read.isError, true)
                    XCTAssertFalse(ContextBuilderMultiRootDiscoveryDriver.text(read).contains("REPLACEMENT_SENTINEL_MUST_NOT_LEAK"))
                    let after = try driver.promotedSnapshot(for: connection)
                    XCTAssertEqual(after.runID, runID)
                    XCTAssertEqual(after.frozenLookupContext?.rootScope, before.frozenLookupContext?.rootScope)
                    XCTAssertEqual(context.primaryRootSnapshot?.roots, original)
                }
                let completion = try await driver.fixture.perform("post-stream replacement ordinary commit") {
                    try await driver.run(context, authority: authority)
                }
                XCTAssertNotEqual(completion.terminalDisposition, .completed, "Stale discovery claimed a successful commit")
                XCTAssertNil(completion.committedTab)
                XCTAssertNil(driver.committed)
                try await driver.assertReleased(runID: completion.runID)
                try await driver.assertRoutedLeaseReleasedExactlyOnce(runID: completion.runID)
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.streamStarts, 1)
                XCTAssertEqual(driver.disposed, 1)
                for connection in driver.connections {
                    await connection.cleanup()
                    XCTAssertEqual(connection.cleanupCount, 1)
                }
            }
        }

        func testActualContextBuilderToolReturnsCommittedRoutedResultAndObservesRequestTerminal() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A", "B", "Unrelated"], routedRuntime: true) { driver in
                let context = try await driver.resolve()
                let parent = try await driver.fixture.perform("actual invoking Agent Mode socket") { try await driver.connectInvokingAgent(context) }
                let observer = try XCTUnwrap(driver.vm.armStartupObservationForTesting(
                    windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id,
                    tabID: driver.tabID, invokingRunID: context.frozenTabContext.runID!
                ))
                driver.streamBody = { runID in
                    let child = try await driver.connectChild(runID: runID)
                    try await driver.discover(using: child)
                }
                let reply = try await driver.fixture.perform("actual context_builder request") { try await driver.invoke(using: parent) }
                XCTAssertNotEqual(reply.isError, true, ContextBuilderMultiRootDiscoveryDriver.text(reply))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ContextBuilderMultiRootDiscoveryDriver.text(reply).utf8)) as? [String: Any])
                XCTAssertEqual(json["status"] as? String, "completed")
                XCTAssertEqual(json["prompt"] as? String, "ROUTED_DISCOVERY_RESULT")
                XCTAssertEqual(json["file_count"] as? Int, 2)
                let committed = try XCTUnwrap(driver.committed)
                XCTAssertEqual(committed.tab.promptText, "ROUTED_DISCOVERY_RESULT")
                try await driver.assertReleased(runID: committed.nestedRunID)
                try await driver.assertRoutedLeaseReleasedExactlyOnce(runID: committed.nestedRunID)
                XCTAssertEqual(observer.streamStartCount, 1)
                XCTAssertEqual(observer.runTerminalCount, 1)
                XCTAssertEqual(observer.teardownCount, 1)
                XCTAssertEqual(observer.requestTerminalCount, 1)
                XCTAssertEqual(observer.discoveryRunID, committed.nestedRunID)
                XCTAssertFalse(observer.description.contains("SENSITIVE_DISCOVERY_PROMPT"))
                XCTAssertFalse(observer.description.contains(driver.fixture.base.path))
            }
        }

        func testActualTwoTabAdmissionDoesNotCancelCommitFenceValidation() async throws {
            try await assertTwoTabAdmissionDoesNotCancelValidation(beforeCommit: true)
        }

        func testActualTwoTabAdmissionDoesNotCancelPostCommitResponseValidation() async throws {
            try await assertTwoTabAdmissionDoesNotCancelValidation(beforeCommit: false)
        }

        private func assertTwoTabAdmissionDoesNotCancelValidation(beforeCommit: Bool) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(routedRuntime: true) { driver in
                let secondTabID = try await driver.installAdditionalTab()
                let firstContext = try await driver.resolve(tabID: driver.tabID)
                let secondContext = try await driver.resolve(tabID: secondTabID)
                let firstParent = try await driver.connectInvokingAgent(firstContext)
                let secondParent = try await driver.connectInvokingAgent(secondContext)
                driver.teardown.expectedFulfillmentCount = 2
                let validationEntered = XCTestExpectation(description: "first tab validation held")
                validationEntered.assertForOverFulfill = false
                let gate = driver.fixture.makeGate()
                let armValidationGate = {
                    driver.manager.rootReconciliationGateForTesting = { event in
                        guard event.phase == .probeResponse else { return }
                        validationEntered.fulfill()
                        await gate.wait()
                    }
                }
                if !beforeCommit {
                    driver.afterCommittedTabSnapshotCaptured = { _, snapshot in
                        guard snapshot.identity.tabID == driver.tabID else { return }
                        armValidationGate()
                    }
                }
                let expectedPrompts = [
                    driver.tabID: "FIRST_TAB_OVERLAP_RESULT",
                    secondTabID: "SECOND_TAB_OVERLAP_RESULT"
                ]
                driver.streamBody = { runID in
                    let activeTabID = try driver.activeTabID(forRunID: runID)
                    let expectedPrompt = try XCTUnwrap(expectedPrompts[activeTabID])
                    let child = try await driver.connectChild(runID: runID)
                    let result = try await child.client.callTool(name: "prompt", arguments: [
                        "op": .string("set"),
                        "text": .string(expectedPrompt)
                    ])
                    XCTAssertNotEqual(result.isError, true, ContextBuilderMultiRootDiscoveryDriver.text(result))
                    if beforeCommit, activeTabID == driver.tabID {
                        // Routed writes have drained; the next root validation is the pre-commit fence.
                        armValidationGate()
                    }
                }

                let firstDone = XCTestExpectation(description: "first tab request completed")
                var firstReply: (content: [MCP.Tool.Content], isError: Bool?)?
                driver.fixture.startOwnedTask {
                    do { firstReply = try await driver.invoke(using: firstParent) }
                    catch { XCTFail("First tab transport failed: \(error)") }
                    firstDone.fulfill()
                }
                try await driver.fixture.awaitGateEvent(validationEntered)
                XCTAssertEqual(driver.committedByRunID.isEmpty, beforeCommit)

                let secondRegistered = XCTestExpectation(description: "second tab admission queued behind validation")
                secondRegistered.assertForOverFulfill = false
                driver.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in
                    if count >= 2 { secondRegistered.fulfill() }
                }
                let secondDone = XCTestExpectation(description: "second tab request completed")
                var secondReply: (content: [MCP.Tool.Content], isError: Bool?)?
                driver.fixture.startOwnedTask {
                    do { secondReply = try await driver.invoke(using: secondParent) }
                    catch { XCTFail("Second tab transport failed: \(error)") }
                    secondDone.fulfill()
                }
                try await driver.fixture.awaitGateEvent(secondRegistered)
                XCTAssertTrue(driver.manager.rootReconciliationStateForTesting.hasPending)
                XCTAssertEqual(
                    driver.committedByRunID.isEmpty,
                    beforeCommit,
                    "The held validation must stay on the intended side of commit during admission"
                )
                gate.release()
                try await driver.fixture.awaitGateEvent(firstDone)
                try await driver.fixture.awaitGateEvent(secondDone)

                let repliesByTabID = try [
                    driver.tabID: XCTUnwrap(firstReply),
                    secondTabID: XCTUnwrap(secondReply)
                ]
                for (tabID, reply) in repliesByTabID {
                    let text = ContextBuilderMultiRootDiscoveryDriver.text(reply)
                    XCTAssertNotEqual(reply.isError, true, text)
                    XCTAssertFalse(text.contains("context_builder_roots_changing"), text)
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    XCTAssertEqual(json["status"] as? String, "completed")
                    XCTAssertEqual(json["prompt"] as? String, expectedPrompts[tabID])
                }
                try await driver.fixture.awaitGateEvent(driver.teardown)
                try await driver.fixture.settle()
                XCTAssertEqual(driver.storedPrompt(tabID: driver.tabID), expectedPrompts[driver.tabID])
                XCTAssertEqual(driver.storedPrompt(tabID: secondTabID), expectedPrompts[secondTabID])
                XCTAssertEqual(Set(driver.committedByRunID.values.map(\.identity.tabID)), Set([driver.tabID, secondTabID]))
                XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
                XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: secondTabID))
                XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.waiterCount, 0)
            }
        }

        func testActualContextBuilderIngressAuthorityAndPrelaunchFailuresUseTypedInvalidParams() async throws {
            for boundary in ["ingress", "authority", "prelaunch"] {
                try await ContextBuilderMultiRootDiscoveryDriver.withDriver(routedRuntime: true) { driver in
                    let context = try await driver.resolve()
                    let parent = try await driver.fixture.perform("invoking socket for " + boundary) { try await driver.connectInvokingAgent(context) }
                    let observer = try XCTUnwrap(driver.vm.armStartupObservationForTesting(
                        windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id,
                        tabID: driver.tabID, invokingRunID: context.frozenTabContext.runID!
                    ))
                    if boundary == "ingress" {
                        driver.manager.activeWorkspace = nil
                    } else if boundary == "authority" {
                        driver.providerValidationBody = {
                            await driver.manager.removeFolder(driver.fixture.rootPaths[1], from: driver.fixture.workspace)
                        }
                    } else {
                        var armed = true
                        driver.manager.rootReconciliationGateForTesting = { event in
                            guard event.phase == .probeResponse, driver.constructed == 1, armed else { return }
                            armed = false
                            await driver.files.unloadRootFolderPath(driver.fixture.rootPaths[1])
                        }
                    }
                    let reply = try await driver.fixture.perform("actual rejected context_builder " + boundary) { try await driver.invoke(using: parent) }
                    let text = ContextBuilderMultiRootDiscoveryDriver.text(reply)
                    XCTAssertEqual(reply.isError, true, text)
                    XCTAssertTrue(text.contains("[-32602] Invalid params:"), text)
                    XCTAssertTrue(text.contains("context_builder_" + (boundary == "ingress" ? "workspace_inactive" : "stale_invocation")), text)
                    XCTAssertTrue(text.contains("retryable=true"), text)
                    XCTAssertFalse(text.contains(driver.fixture.base.path))
                    XCTAssertFalse(text.contains("SENSITIVE_DISCOVERY_PROMPT"))
                    XCTAssertEqual(driver.streamStarts, 0)
                    XCTAssertNil(driver.committed)
                    XCTAssertEqual(observer.requestTerminalCount, 1)
                    XCTAssertEqual(observer.streamStartCount, 0)
                    if boundary == "prelaunch" {
                        let runID = try XCTUnwrap(observer.discoveryRunID)
                        try await driver.assertReleased(runID: runID)
                        try await driver.assertLeaseFailedExactlyOnce(runID: runID)
                        XCTAssertEqual(driver.constructed, 1)
                        XCTAssertEqual(driver.disposed, 1)
                        XCTAssertEqual(observer.runTerminalCount, 1)
                        XCTAssertEqual(observer.teardownCount, 1)
                    } else {
                        XCTAssertEqual(driver.constructed, 0)
                        XCTAssertEqual(observer.runTerminalCount, 0)
                        XCTAssertEqual(observer.teardownCount, 0)
                        XCTAssertEqual(driver.runSettlementCount, 1)
                        XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
                        let token = try driver.vm.beginMCPControlledRun(forTabID: driver.tabID, responseType: nil, planModelName: nil)
                        driver.vm.clearMCPControlledRun(forTabID: driver.tabID, controlToken: token)
                    }
                }
            }
        }

        func testActualContextBuilderCase26IngressFailuresNeverStartProvider() async throws {
            let invalid = "context_builder_invalid_configuration; retryable=false. Correct blank or invalid workspace root entries before retrying Context Builder."
            let cases: [(name: String, error: String)] = [
                ("empty", "context_builder_empty_configuration; retryable=false. Configure at least one workspace root before retrying Context Builder."),
                ("whitespace", invalid), ("mixedInvalid", invalid), ("nul", invalid), ("malformedURI", invalid),
                ("deletedDirectory", "context_builder_roots_unavailable; retryable=true. subreason=missingDirectory. Restore or remove the configured directory, then refresh the workspace and retry."),
                ("regularFile", "context_builder_roots_unavailable; retryable=true. subreason=notDirectory. Replace the configured file with a directory or correct the root configuration, then refresh and retry."),
                ("accessDenied", "context_builder_roots_unavailable; retryable=true. subreason=accessDenied. Restore directory access, then refresh the workspace and retry."),
                ("loadFailed", "context_builder_roots_unavailable; retryable=true. subreason=loadFailed. Refresh the workspace and retry after resolving its root loading issue."),
                ("wrongKind", "context_builder_wrong_root_kind; retryable=false. Correct workspace root ownership before retrying. A non-primary root cannot substitute for a configured primary root."),
                ("partialCoverage", "context_builder_incomplete_projection; retryable=true. Not all configured primary roots are queryable. Refresh the workspace and retry."),
                ("delayedProjection", "context_builder_roots_changing; retryable=true. Workspace roots are still changing. Retry this request shortly.")
            ]
            for variant in cases {
                try await ContextBuilderMultiRootDiscoveryDriver.withDriver(routedRuntime: true) { driver in
                    let context = try await driver.resolve()
                    let parent = try await driver.fixture.perform("case26 invoking socket " + variant.name) {
                        try await driver.connectInvokingAgent(context)
                    }
                    let observer = try XCTUnwrap(driver.vm.armStartupObservationForTesting(
                        windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id,
                        tabID: driver.tabID, invokingRunID: context.frozenTabContext.runID!
                    ))
                    let workspaceID = driver.fixture.workspace.id
                    let originalPaths = try XCTUnwrap(driver.manager.workspace(withID: workspaceID)).repoPaths
                    var invalidPaths: [String]?
                    // Only malformed loaded-model input is transiently substituted. The actual
                    // MCP resolver reads it; no authority, policy, routing or destination tab changes.
                    defer {
                        if invalidPaths != nil, let index = driver.manager.workspaces.firstIndex(where: { $0.id == workspaceID }) {
                            driver.manager.workspaces[index].repoPaths = originalPaths
                        }
                    }
                    let rootB = driver.fixture.rootPaths[1]
                    let gate = driver.fixture.makeGate()
                    let entered = XCTestExpectation(description: "case26 missing B held before actual load")
                    var checkpointFired = false
                    switch variant.name {
                    case "empty": invalidPaths = []
                    case "whitespace": invalidPaths = [" \n"]
                    case "mixedInvalid": invalidPaths = [driver.fixture.rootPaths[0], ""]
                    case "nul": invalidPaths = ["SENSITIVE_INVALID\0PATH"]
                    case "malformedURI": invalidPaths = ["file://SENSITIVE_INVALID"]
                    case "deletedDirectory":
                        try FileManager.default.moveItem(atPath: rootB, toPath: driver.fixture.base.appendingPathComponent("moved-B").path)
                    case "regularFile":
                        await driver.files.unloadRootFolderPath(rootB)
                        try FileManager.default.removeItem(atPath: rootB)
                        try "SENSITIVE_FILE_CONTENT".write(toFile: rootB, atomically: true, encoding: .utf8)
                    case "accessDenied": driver.manager.rootProbeFailureForTesting = .accessDenied
                    case "loadFailed": driver.manager.rootProbeFailureForTesting = .loadFailed
                    case "wrongKind":
                        await driver.files.unloadRootFolderPath(rootB)
                        try await driver.files.loadFolder(at: URL(fileURLWithPath: rootB), for: driver.fixture.workspace, rootKind: .supplementalSystem)
                    case "partialCoverage":
                        driver.manager.rootReconciliationGateForTesting = { event in
                            guard event.phase == .beforeReorder, !checkpointFired else { return }
                            checkpointFired = true
                            await driver.files.unloadRootFolderPath(rootB)
                        }
                    case "delayedProjection":
                        await driver.files.unloadRootFolderPath(rootB)
                        driver.manager.rootReconciliationGateForTesting = { event in
                            guard event.phase == .beforeLoad, event.rootIndex == 1, !checkpointFired else { return }
                            checkpointFired = true
                            entered.fulfill()
                            await gate.wait()
                        }
                    default: XCTFail("Unknown case26 variant")
                    }
                    if let invalidPaths {
                        let index = try XCTUnwrap(driver.manager.workspaces.firstIndex(where: { $0.id == workspaceID }))
                        driver.manager.workspaces[index].repoPaths = invalidPaths
                    }
                    let done = XCTestExpectation(description: "case26 actual request settled " + variant.name)
                    var reply: (content: [MCP.Tool.Content], isError: Bool?)?
                    let started = ContinuousClock.now
                    driver.fixture.startOwnedTask {
                        do {
                            reply = try await driver.fixture.perform("case26 actual MCP request " + variant.name) {
                                try await driver.invoke(using: parent)
                            }
                        } catch { XCTFail("Unexpected case26 transport failure \(variant.name): \(error)") }
                        done.fulfill()
                    }
                    if variant.name == "delayedProjection" {
                        try await driver.fixture.awaitGateEvent(entered)
                        let held = await driver.files.workspaceFileContextStore.primaryRootReadinessObservation(orderedPaths: originalPaths)
                        XCTAssertEqual(held.requestedRoots.map(\.standardizedFullPath), [driver.fixture.rootPaths[0]])
                        XCTAssertEqual(held.missingPaths, [rootB])
                        XCTAssertNil(reply, "Request returned before its held projection deadline")
                    }
                    try await driver.fixture.awaitGateEvent(done)
                    let result = try XCTUnwrap(reply)
                    let text = ContextBuilderMultiRootDiscoveryDriver.text(result)
                    XCTAssertEqual(result.isError, true, variant.name)
                    let literalErrorMatched = text.contains("[-32602] Invalid params: " + variant.error)
                    XCTAssertTrue(literalErrorMatched, "\(variant.name): \(text)")
                    for sensitive in [driver.fixture.base.path, "SENSITIVE_DISCOVERY_PROMPT", "SENSITIVE_INVALID", "SENSITIVE_FILE_CONTENT"] {
                        XCTAssertFalse(text.contains(sensitive), variant.name)
                    }
                    if variant.name == "partialCoverage" || variant.name == "delayedProjection" {
                        XCTAssertTrue(checkpointFired, variant.name)
                        let incomplete = await driver.files.workspaceFileContextStore.primaryRootReadinessObservation(orderedPaths: originalPaths)
                        XCTAssertEqual(incomplete.requestedRoots.map(\.standardizedFullPath), [driver.fixture.rootPaths[0]], variant.name)
                        XCTAssertEqual(incomplete.missingPaths, [rootB], variant.name)
                    }
                    if variant.name == "delayedProjection" {
                        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .seconds(1.8))
                        XCTAssertLessThan(started.duration(to: .now), .seconds(4))
                    }
                    XCTAssertEqual(driver.streamStarts, 0, variant.name)
                    XCTAssertEqual(observer.streamStartCount, 0, variant.name)
                    XCTAssertEqual(driver.constructed, 0, variant.name)
                    XCTAssertEqual(driver.disposed, 0, variant.name)
                    XCTAssertNil(driver.committed, variant.name)
                    XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: driver.tabID), variant.name)
                    XCTAssertNil(observer.discoveryRunID, variant.name)
                    XCTAssertEqual(observer.runTerminalCount, 0, variant.name)
                    XCTAssertEqual(observer.teardownCount, 0, variant.name)
                    XCTAssertEqual(observer.requestTerminalCount, 1, variant.name)
                    XCTAssertEqual(driver.runSettlementCount, 1, variant.name)
                    let token = try driver.vm.beginMCPControlledRun(forTabID: driver.tabID, responseType: nil, planModelName: nil)
                    driver.vm.clearMCPControlledRun(forTabID: driver.tabID, controlToken: token)
                    gate.release()
                    await driver.manager.awaitRootReconciliationShutdown()
                    XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.waiterCount, 0, variant.name)
                    XCTAssertEqual(driver.streamStarts, 0, "No late stream: " + variant.name)
                    XCTAssertEqual(observer.streamStartCount, 0, variant.name)
                    XCTAssertEqual(observer.requestTerminalCount, 1, variant.name)
                    XCTAssertEqual(driver.runSettlementCount, 1, variant.name)
                    XCTAssertNil(driver.committed, variant.name)
                    // withDriver joins requests, connections, window/runtime owners on every exit;
                    // its real connection removal and exact runtime/catalog restoration assertions apply.
                    print(
                        "ISSUE944 case26=\(variant.name) literalErrorMatched=\(literalErrorMatched) "
                            + "streams=\(driver.streamStarts) observerStreams=\(observer.streamStartCount) constructions=\(driver.constructed) "
                            + "requestTerminals=\(observer.requestTerminalCount) settlements=\(driver.runSettlementCount) "
                            + "lateCommit=\(driver.committed != nil) waiters=\(driver.manager.rootReconciliationStateForTesting.waiterCount)"
                    )
                }
            }
        }

        func testActualContextBuilderAdmissionDeadlineAndCancellationLeaveSharedProbeAlive() async throws {
            for phase in [WorkspaceManagerViewModel.RootReconciliationTestEvent.Phase.observationResponse, .probeResponse] {
                try await ContextBuilderMultiRootDiscoveryDriver.withDriver(routedRuntime: true) { driver in
                    let firstContext = try await driver.resolve()
                    let first = try await driver.fixture.perform("first admission socket") { try await driver.connectInvokingAgent(firstContext) }
                    let secondContext = try await driver.resolve()
                    let second = try await driver.fixture.perform("second admission socket") { try await driver.connectInvokingAgent(secondContext) }
                    let firstObserver = try XCTUnwrap(driver.vm.armStartupObservationForTesting(
                        windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id,
                        tabID: driver.tabID, invokingRunID: firstContext.frozenTabContext.runID!
                    ))
                    let entered = XCTestExpectation(description: "actual MCP ingress observation/probe held")
                    let gate = driver.fixture.makeGate()
                    var armed = true
                    let starts = driver.manager.rootReconciliationStateForTesting.attemptStarts
                    let probes = driver.manager.rootReconciliationStateForTesting.probeBatches
                    driver.manager.rootReconciliationGateForTesting = { event in
                        guard event.phase == phase, armed else { return }
                        armed = false
                        entered.fulfill()
                        await gate.wait()
                    }
                    let firstDone = XCTestExpectation(description: "actual ingress deadline settled")
                    let started = ContinuousClock.now
                    driver.fixture.startOwnedTask {
                        do {
                            let reply = try await driver.invoke(using: first)
                            let text = ContextBuilderMultiRootDiscoveryDriver.text(reply)
                            XCTAssertEqual(reply.isError, true)
                            XCTAssertTrue(text.contains("[-32602] Invalid params: context_builder_roots_changing; retryable=true."), text)
                            XCTAssertFalse(text.contains(driver.fixture.base.path))
                            XCTAssertFalse(text.contains("SENSITIVE_DISCOVERY_PROMPT"))
                        } catch { XCTFail("Unexpected ingress error: \(error)") }
                        firstDone.fulfill()
                    }
                    try await driver.fixture.awaitGateEvent(entered)
                    let secondObserver = try XCTUnwrap(driver.vm.armStartupObservationForTesting(
                        windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id,
                        tabID: driver.tabID, invokingRunID: secondContext.frozenTabContext.runID!
                    ))
                    let cancelledOnServer = XCTestExpectation(description: "cancelled request actually left server executor")
                    secondObserver.requestTerminalDidFireForTesting = { cancelledOnServer.fulfill() }
                    defer { secondObserver.requestTerminalDidFireForTesting = nil }
                    let registered = XCTestExpectation(description: "two actual requests and shared operation registered")
                    var registeredOnce = false
                    driver.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in
                        if count == 3, !registeredOnce { registeredOnce = true
                            registered.fulfill()
                        }
                    }
                    let request = try await second.client.send(CallTool.request(.init(name: "context_builder", arguments: ["response_type": .string("clarify")])))
                    let ticket = try XCTUnwrap(driver.manager.requestRootReconciliation(workspaceID: driver.fixture.workspace.id))
                    let survivorDone = XCTestExpectation(description: "operation survived actual request cancellation and timeout")
                    var survived = false
                    driver.fixture.startOwnedTask {
                        do { _ = try await driver.manager.awaitRootReconciliationCompletion(ticket: ticket) }
                        catch { XCTFail("Shared operation failed: \(error)") }
                        survived = true
                        survivorDone.fulfill()
                    }
                    try await driver.fixture.awaitGateEvent(registered)
                    let cancelStarted = ContinuousClock.now
                    try await second.client.cancelRequest(request.requestID, reason: "isolated cancellation control")
                    do { _ = try await request.value
                        XCTFail("Cancelled client request returned a value")
                    } catch is CancellationError {} catch { XCTFail("Unexpected client cancellation: \(error)") }
                    try await driver.fixture.awaitGateEvent(cancelledOnServer)
                    XCTAssertLessThan(cancelStarted.duration(to: .now), .seconds(1))
                    try await driver.fixture.awaitGateEvent(firstDone)
                    XCTAssertGreaterThanOrEqual(started.duration(to: .now), .seconds(1.8))
                    XCTAssertLessThan(started.duration(to: .now), .seconds(4))
                    XCTAssertFalse(survived)
                    XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.waiterCount, 1)
                    XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.attemptStarts - starts, 1)
                    XCTAssertEqual(firstObserver.requestTerminalCount, 1)
                    XCTAssertEqual(secondObserver.requestTerminalCount, 1)
                    XCTAssertEqual(driver.constructed, 0)
                    XCTAssertEqual(driver.streamStarts, 0)
                    XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
                    XCTAssertNil(driver.committed)
                    gate.release()
                    try await driver.fixture.awaitGateEvent(survivorDone)
                    XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.waiterCount, 0)
                    XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.probeBatches - probes, 1)
                    XCTAssertEqual(firstObserver.requestTerminalCount, 1)
                    XCTAssertEqual(secondObserver.requestTerminalCount, 1)
                    let token = try driver.vm.beginMCPControlledRun(forTabID: driver.tabID, responseType: nil, planModelName: nil)
                    driver.vm.clearMCPControlledRun(forTabID: driver.tabID, controlToken: token)
                }
            }
        }

        func testActualContextBuilderPostAuthorityValidationGetsFreshDeadlineWithoutCancellingOperation() async throws {
            for phase in [WorkspaceManagerViewModel.RootReconciliationTestEvent.Phase.observationResponse, .probeResponse] {
                try await ContextBuilderMultiRootDiscoveryDriver.withDriver(routedRuntime: true) { driver in
                    let context = try await driver.resolve()
                    let parent = try await driver.fixture.perform("startup-budget invoking socket") { try await driver.connectInvokingAgent(context) }
                    let observer = try XCTUnwrap(driver.vm.armStartupObservationForTesting(
                        windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id,
                        tabID: driver.tabID, invokingRunID: context.frozenTabContext.runID!
                    ))
                    let gate = driver.fixture.makeGate()
                    let entered = XCTestExpectation(description: "post-authority manager response held")
                    var enteredAt: ContinuousClock.Instant?
                    var ticket: WorkspaceRootReconciliationTicket?
                    var probes = 0
                    driver.providerValidationBody = {
                        var armed = true
                        driver.manager.rootReconciliationGateForTesting = { event in
                            guard event.phase == phase, armed else { return }
                            armed = false
                            enteredAt = .now
                            entered.fulfill()
                            await gate.wait()
                        }
                        probes = driver.manager.rootReconciliationStateForTesting.probeBatches
                        ticket = driver.manager.requestRootReconciliation(workspaceID: driver.fixture.workspace.id)
                    }
                    let terminal = XCTestExpectation(description: "actual caller startup validation deadline")
                    driver.fixture.startOwnedTask {
                        do {
                            let reply = try await driver.invoke(using: parent)
                            let text = ContextBuilderMultiRootDiscoveryDriver.text(reply)
                            XCTAssertEqual(reply.isError, true)
                            XCTAssertTrue(text.contains("[-32602] Invalid params: context_builder_roots_changing; retryable=true."), text)
                            XCTAssertFalse(text.contains(driver.fixture.base.path))
                            XCTAssertFalse(text.contains("SENSITIVE_DISCOVERY_PROMPT"))
                        } catch { XCTFail("Unexpected startup caller error: \(error)") }
                        terminal.fulfill()
                    }
                    try await driver.fixture.awaitGateEvent(entered)
                    let operationTicket = try XCTUnwrap(ticket)
                    let survivorDone = XCTestExpectation(description: "post-authority shared operation completes after caller expiry")
                    var survived = false
                    driver.fixture.startOwnedTask {
                        do {
                            let ready = try await driver.manager.awaitRootReconciliationCompletion(ticket: operationTicket)
                            XCTAssertEqual(ready.roots, context.primaryRootSnapshot?.roots)
                        } catch { XCTFail("Surviving operation failed: \(error)") }
                        survived = true
                        survivorDone.fulfill()
                    }
                    try await driver.fixture.awaitGateEvent(terminal)
                    let elapsed = try XCTUnwrap(enteredAt).duration(to: .now)
                    XCTAssertGreaterThanOrEqual(elapsed, .seconds(1.8))
                    XCTAssertLessThan(elapsed, .seconds(4))
                    XCTAssertFalse(survived)
                    XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.waiterCount, 1)
                    XCTAssertEqual(observer.requestTerminalCount, 1)
                    XCTAssertEqual(observer.runTerminalCount, 0)
                    XCTAssertEqual(observer.streamStartCount, 0)
                    XCTAssertEqual(driver.constructed, 0)
                    XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
                    gate.release()
                    try await driver.fixture.awaitGateEvent(survivorDone)
                    XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.waiterCount, 0)
                    XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.probeBatches - probes, 1)
                    XCTAssertEqual(observer.requestTerminalCount, 1)
                    XCTAssertEqual(driver.runSettlementCount, 1)
                    let token = try driver.vm.beginMCPControlledRun(forTabID: driver.tabID, responseType: nil, planModelName: nil)
                    driver.vm.clearMCPControlledRun(forTabID: driver.tabID, controlToken: token)
                }
            }
        }

        func testIsolatedRuntimeScopeRejectsOverlapAndRestoresCatalogAfterThrowingSocketExit() async throws {
            enum FixtureExit: Error { case expected }
            var connection: ContextBuilderMultiRootDiscoveryDriver.RoutedConnection?
            do {
                try await ContextBuilderMultiRootDiscoveryDriver.withDriver(routedRuntime: true) { driver in
                    do {
                        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(driver.fixture.runtime) { XCTFail("Nested scope executed") }
                        XCTFail("Nested scope was admitted")
                    } catch let error as AppDomainRuntimeComposition.RuntimeScopeError {
                        guard case .alreadyScoped = error else { return XCTFail("Wrong idle overlap rejection") }
                    }
                    let context = try await driver.resolve()
                    connection = try await driver.fixture.perform("throwing-exit socket") { try await driver.connectInvokingAgent(context) }
                    do {
                        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(driver.fixture.runtime) { XCTFail("Active-owner scope executed") }
                        XCTFail("Active-owner scope was admitted")
                    } catch let error as AppDomainRuntimeComposition.RuntimeScopeError {
                        guard case .ownersActive = error else { return XCTFail("Wrong active-owner rejection") }
                    }
                    throw FixtureExit.expected
                }
                XCTFail("Expected throwing fixture exit")
            } catch FixtureExit.expected {}
            XCTAssertEqual(connection?.cleanupCount, 1)
            XCTAssertNil(AppDomainRuntimeComposition.shared.runtimeForTesting)
            XCTAssertEqual(AppGlobalMCPServiceComposition.shared.registrationScopeStateForTesting.owners, 0)
            XCTAssertNil(AppGlobalMCPServiceComposition.shared.registrationScopeStateForTesting.attemptID)
        }

        func testActualMCPServerStartupCallerDeadlineDetachesFromHeldObservationAndProbe() async throws {
            for phase in [WorkspaceManagerViewModel.RootReconciliationTestEvent.Phase.observationResponse, .probeResponse] {
                try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                    let context = try await driver.resolve()
                    let authority = try await driver.authority(context)
                    let gate = driver.fixture.makeGate()
                    let entered = XCTestExpectation(description: "registered run after real MCP server startup validation held")
                    var armed = true
                    var attemptStarts = 0
                    var runID: UUID?
                    driver.manager.rootReconciliationGateForTesting = { event in
                        guard event.phase == phase, armed,
                              let active = driver.vm.activeRunIDForTesting(tabID: driver.tabID) else { return }
                        armed = false
                        runID = active
                        XCTAssertTrue(driver.window.mcpServer.windowToolsEnabled)
                        attemptStarts = driver.manager.rootReconciliationStateForTesting.attemptStarts
                        entered.fulfill()
                        await gate.wait()
                    }
                    let terminal = XCTestExpectation(description: "actual startup caller deadline settled while gate held")
                    var completion: ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion?
                    var started: ContinuousClock.Instant?
                    driver.fixture.startOwnedTask {
                        do {
                            started = .now
                            completion = try await driver.run(context, authority: authority)
                        } catch { XCTFail("Unexpected caller failure: \(error)") }
                        terminal.fulfill()
                    }
                    try await driver.fixture.awaitGateEvent(entered)
                    try await driver.fixture.awaitGateEvent(terminal)
                    let elapsed = try XCTUnwrap(started).duration(to: .now)
                    XCTAssertGreaterThanOrEqual(elapsed, .seconds(1.8))
                    XCTAssertLessThan(elapsed, .seconds(4))
                    let result = try XCTUnwrap(completion)
                    XCTAssertEqual(result.runID, runID)
                    guard case let .failed(message) = result.terminalDisposition else { return XCTFail("Held startup validation completed") }
                    XCTAssertTrue(message.hasPrefix("context_builder_roots_changing; retryable=true."), message)
                    XCTAssertFalse(message.contains(driver.fixture.base.path))
                    XCTAssertFalse(message.contains("SENSITIVE_DISCOVERY_PROMPT"))
                    XCTAssertNil(result.committedTab)
                    XCTAssertEqual(driver.constructed, 0)
                    XCTAssertEqual(driver.streamStarts, 0)
                    XCTAssertEqual(driver.disposed, 0)
                    XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.waiterCount, 0)
                    XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.attemptStarts, attemptStarts)
                    try await driver.assertReleased(runID: result.runID)
                    gate.release()
                    await driver.manager.awaitRootReconciliationShutdown()
                    XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.waiterCount, 0)
                    XCTAssertEqual(driver.runSettlementCount, 1)
                }
            }
        }

        // MARK: - Settings changes during active runs (#810)

        private static let desiredSettingsA = ContextBuilderBehaviorSettings(
            contextTokenBudget: 70000,
            analysisTokenBudget: 90000,
            enhancementMode: .augment,
            questionTimeoutSeconds: 120,
            allowUIClarifyingQuestions: true,
            allowMCPClarifyingQuestions: true,
            followUpAnalysisEnabled: false
        )

        private static let desiredSettingsB = ContextBuilderBehaviorSettings(
            contextTokenBudget: 50000,
            analysisTokenBudget: 60000,
            enhancementMode: .preserve,
            questionTimeoutSeconds: 30,
            allowUIClarifyingQuestions: false,
            allowMCPClarifyingQuestions: false,
            followUpAnalysisEnabled: true
        )

        private static func desiredSettings(_ vm: ContextBuilderAgentViewModel) -> ContextBuilderBehaviorSettings {
            ContextBuilderBehaviorSettings(
                contextTokenBudget: vm.contextTokenBudget,
                analysisTokenBudget: vm.analysisTokenBudget,
                enhancementMode: vm.enhancementMode,
                questionTimeoutSeconds: vm.questionTimeoutSeconds,
                allowUIClarifyingQuestions: vm.allowUIClarifyingQuestions,
                allowMCPClarifyingQuestions: vm.allowMCPClarifyingQuestions,
                followUpAnalysisEnabled: vm.followUpAnalysisEnabled
            )
        }

        /// The production projection fed exactly as `ContextBuilderAgentView` feeds it: real
        /// active membership, the ownership-checked capture, and the desired preference getters.
        private static func presentation(_ driver: ContextBuilderMultiRootDiscoveryDriver) -> ContextBuilderBehaviorPresentation {
            let running = driver.vm.tabsWithActiveContextBuilderRun.contains(driver.tabID)
            return ContextBuilderBehaviorPresentation.resolve(
                isRunning: running,
                activeRunBehavior: running ? driver.vm.activeRunBehavior(for: driver.tabID) : nil,
                desiredSettings: desiredSettings(driver.vm),
                selectedFollowUp: driver.vm.selectedFollowUpType
            )
        }

        /// `liveBudgetTag` is the budget a live re-read of desired B would have produced for the
        /// origin under test (UI B enables follow-up analysis: 60000 - 1500; MCP B: 50000 - 1500).
        private static func assertMessageBuiltFromA(
            _ message: AgentMessage?,
            liveBudgetTag: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            guard let message else { return XCTFail("provider did not receive a message", file: file, line: line) }
            XCTAssertTrue(message.userMessage.contains("<token_budget>68500</token_budget>"), "A budget missing", file: file, line: line)
            XCTAssertFalse(message.userMessage.contains("<token_budget>\(liveBudgetTag)</token_budget>"), "live B budget present", file: file, line: line)
            XCTAssertTrue(message.systemPrompt.contains("ask_user"), "A question guidance missing", file: file, line: line)
            // Captured A is Augment; desired B is Preserve. The mode instructions must come from the capture.
            XCTAssertTrue(
                message.systemPrompt.contains("Augment the handoff prompt (MANDATORY)"),
                "captured Augment handoff guidance missing from the provider-bound system prompt",
                file: file,
                line: line
            )
            XCTAssertFalse(
                message.systemPrompt.contains("Leave the prompt COMPLETELY unchanged"),
                "live Preserve handoff guidance present in the provider-bound system prompt",
                file: file,
                line: line
            )
        }

        /// Run IDs admitted by a journey, shared with the guaranteed cleanup even when the journey throws.
        private final class AdmittedRuns {
            var ids: [UUID] = []
        }

        /// Original behavior preferences, captured once inside a successfully entered driver scope
        /// (after the fixture has validated its sandbox) and restored by the outer wrapper.
        private final class OriginalBehaviorSettings {
            var value: ContextBuilderBehaviorSettings?
        }

        /// Restores the seven original behavior preferences only after `body` — which wraps the
        /// whole driver scope — has returned or thrown, i.e. after the driver's own guaranteed
        /// shutdown (cancel all runs, join owned tasks, tear down the window). Nothing is read or
        /// written here unless the driver scope captured the original values; the body's error is
        /// preserved and rethrown after restoration.
        private static func withOriginalBehaviorSettings(
            _ body: @escaping @MainActor (OriginalBehaviorSettings) async throws -> Void
        ) async throws {
            let captured = OriginalBehaviorSettings()
            var failure: Error?
            do { try await body(captured) } catch { failure = error }
            if let original = captured.value {
                GlobalSettingsStore.shared.setContextBuilderBehaviorSettings(original, commit: false)
                XCTAssertEqual(GlobalSettingsStore.shared.contextBuilderBehaviorSettings(), original)
            }
            if let failure { throw failure }
        }

        /// Runs a journey inside the driver scope, then always clears the reconciliation hook,
        /// cancels every admitted run, releases gates, joins each run's teardown with a bounded
        /// fresh per-run expectation, and restores the tab's follow-up selection before rethrowing
        /// the journey's error. A teardown that does not join within the bound is reported as its
        /// own failure and is never treated as joined; the driver's shutdown that follows this
        /// scope still cancels and joins fixture-owned work before settings are restored.
        private static func settlingAdmittedRuns(
            _ driver: ContextBuilderMultiRootDiscoveryDriver,
            original: OriginalBehaviorSettings,
            _ journey: @escaping @MainActor (AdmittedRuns) async throws -> Void
        ) async throws {
            original.value = GlobalSettingsStore.shared.contextBuilderBehaviorSettings()
            let originalFollowUp = driver.vm.selectedFollowUpType
            let admitted = AdmittedRuns()
            var failure: Error?
            do { try await journey(admitted) } catch { failure = error }

            driver.manager.rootReconciliationGateForTesting = nil
            // A run can be registered before the journey recorded its ID (for example when a
            // wait threw); join it too rather than relying on journey bookkeeping.
            if let active = driver.vm.activeRunIDForTesting(tabID: driver.tabID), !admitted.ids.contains(active) {
                admitted.ids.append(active)
            }
            await driver.vm.cancelAllActiveRuns()
            driver.fixture.releaseAllGates()
            for runID in admitted.ids {
                let joined = await XCTWaiter.fulfillment(of: [driver.teardownExpectation(runID: runID)], timeout: 5)
                XCTAssertEqual(joined, .completed, "teardown for run \(runID) did not join within the bound")
            }
            driver.vm.selectedFollowUpType = originalFollowUp
            if let failure { throw failure }
        }

        /// After an earlier run has torn down, a later admitted run that is still active when the
        /// driver scope exits is identified by the driver's run-specific bookkeeping and joined by
        /// the driver's cooperative shutdown before the scope returns. A first-teardown-only join
        /// would skip it once `teardownIDs` is non-empty. Not exercised: a run whose teardown never
        /// completes (shutdown would wait cooperatively, by design).
        func testDriverShutdownJoinsLaterAdmittedRunAfterEarlierTeardown() async throws {
            var scoped: ContextBuilderMultiRootDiscoveryDriver?
            var firstRunID: UUID?
            var secondRunID: UUID?
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                scoped = driver
                let firstEntered = XCTestExpectation(description: "run 1 provider stream entered")
                let firstHold = driver.fixture.makeGate()
                driver.streamBody = { _ in
                    firstEntered.fulfill()
                    await firstHold.wait()
                }
                driver.vm.runContextBuilderAgent()
                let first = try XCTUnwrap(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
                firstRunID = first
                try await driver.fixture.awaitGateEvent(firstEntered)
                await driver.vm.cancelAgentRun()
                firstHold.release()
                try await driver.fixture.awaitGateEvent(driver.teardownExpectation(runID: first))
                XCTAssertEqual(driver.teardownIDs, [first])
                XCTAssertTrue(driver.pendingTeardownRunIDs.isEmpty)

                // Second admission: held on its stream and deliberately left active at scope exit.
                let secondEntered = XCTestExpectation(description: "run 2 provider stream entered")
                let secondHold = driver.fixture.makeGate()
                driver.streamBody = { _ in
                    secondEntered.fulfill()
                    await secondHold.wait()
                }
                driver.vm.runContextBuilderAgent()
                let second = try XCTUnwrap(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
                secondRunID = second
                XCTAssertNotEqual(second, first)
                try await driver.fixture.awaitGateEvent(secondEntered)
                XCTAssertEqual(driver.teardownIDs, [first])
                XCTAssertEqual(driver.pendingTeardownRunIDs, [second])
            }
            let driver = try XCTUnwrap(scoped)
            let first = try XCTUnwrap(firstRunID)
            let second = try XCTUnwrap(secondRunID)
            XCTAssertEqual(driver.teardownIDs, [first, second])
            XCTAssertTrue(driver.pendingTeardownRunIDs.isEmpty)
            XCTAssertFalse(driver.vm.isRunTeardownPendingForTesting(runID: second))
            XCTAssertEqual(driver.disposed, 2)
        }

        /// A real UI admission captures A; desired settings become B on the same actor before the
        /// queued execution builds its message. Execution and the production projection stay on A
        /// while the run is active, idle presentation returns to B, and a second real admission
        /// captures B. Runs are cancelled after execution is observed; no follow-up can start.
        func testUIRunKeepsCapturedExecutionAndPresentationAfterGlobalMutation() async throws {
            try await Self.withOriginalBehaviorSettings { original in
                try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                    try await Self.settlingAdmittedRuns(driver, original: original) { admitted in
                        try await Self.uiJourney(driver, admitted: admitted)
                    }
                }
            }
        }

        private static func uiJourney(_ driver: ContextBuilderMultiRootDiscoveryDriver, admitted: AdmittedRuns) async throws {
            let selectedFollowUp = driver.vm.selectedFollowUpType
            XCTAssertEqual(driver.vm.currentTabID, driver.tabID)
            XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
            GlobalSettingsStore.shared.setContextBuilderBehaviorSettings(desiredSettingsA, commit: false)
            XCTAssertEqual(desiredSettings(driver.vm), desiredSettingsA, "view model does not read the shared store")
            let expectedA = ContextBuilderRunBehavior.ui(settings: desiredSettingsA, selectedFollowUp: selectedFollowUp)
            XCTAssertEqual(expectedA.tokenBudget, 70000)

            let streamEntered = XCTestExpectation(description: "UI run 1 provider stream entered")
            let hold = driver.fixture.makeGate()
            driver.streamBody = { _ in
                streamEntered.fulfill()
                await hold.wait()
            }

            // Admission captures and publishes A synchronously; execution is only queued.
            driver.vm.runContextBuilderAgent()
            let runID = try XCTUnwrap(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
            admitted.ids.append(runID)
            XCTAssertTrue(driver.vm.tabsWithActiveContextBuilderRun.contains(driver.tabID))
            XCTAssertEqual(driver.vm.activeRunBehavior(for: driver.tabID), expectedA)
            XCTAssertEqual(driver.constructed, 0, "provider constructed before the queued execution ran")
            // Desired settings become B on the same actor, with no suspension since admission.
            GlobalSettingsStore.shared.setContextBuilderBehaviorSettings(desiredSettingsB, commit: false)
            XCTAssertEqual(desiredSettings(driver.vm), desiredSettingsB)
            XCTAssertEqual(driver.vm.activeRunBehavior(for: driver.tabID), expectedA)

            // The provider holds its stream, so the run is still active while execution and
            // presentation are inspected.
            try await driver.fixture.awaitGateEvent(streamEntered)
            XCTAssertEqual(driver.vm.activeRunIDForTesting(tabID: driver.tabID), runID)
            assertMessageBuiltFromA(driver.messagesByRunID[runID], liveBudgetTag: "58500")
            XCTAssertEqual(driver.vm.capturedQuestionTimeoutSeconds(tabID: driver.tabID, runID: runID), 120)
            let active = presentation(driver)
            XCTAssertEqual(active, .active(expectedA))
            XCTAssertEqual(active.tokenBudgetLabel, "70k")
            XCTAssertEqual(active.modeLabel, "Augment")
            XCTAssertEqual(active.allowsClarifyingQuestions, true)
            XCTAssertEqual(active.automaticFollowUpPresentation, .off)
            XCTAssertEqual(desiredSettings(driver.vm), desiredSettingsB, "desired B was not retained")

            // Settle by cancellation after execution was observed; idle presentation follows B.
            await driver.vm.cancelAgentRun()
            hold.release()
            try await driver.fixture.awaitGateEvent(driver.teardownExpectation(runID: runID))
            XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
            XCTAssertFalse(driver.vm.tabsWithActiveContextBuilderRun.contains(driver.tabID))
            XCTAssertFalse(driver.vm.isRunTeardownPendingForTesting(runID: runID))
            let idle = presentation(driver)
            XCTAssertEqual(idle, .idle(ContextBuilderRunBehavior.ui(settings: desiredSettingsB, selectedFollowUp: selectedFollowUp)))
            XCTAssertEqual(idle.tokenBudgetLabel, "60k")
            XCTAssertEqual(idle.modeLabel, "Preserve")
            XCTAssertEqual(idle.allowsClarifyingQuestions, false)
            XCTAssertEqual(idle.automaticFollowUpPresentation, .enabled(selectedFollowUp))

            // A second real admission captures B. It is cancelled before any completion, so the
            // captured automatic follow-up can never start a generated response.
            let secondEntered = XCTestExpectation(description: "UI run 2 provider stream entered")
            let secondHold = driver.fixture.makeGate()
            driver.streamBody = { _ in
                secondEntered.fulfill()
                await secondHold.wait()
            }
            driver.vm.runContextBuilderAgent()
            let secondRunID = try XCTUnwrap(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
            admitted.ids.append(secondRunID)
            XCTAssertNotEqual(secondRunID, runID)
            let expectedB = ContextBuilderRunBehavior.ui(settings: desiredSettingsB, selectedFollowUp: selectedFollowUp)
            XCTAssertEqual(driver.vm.activeRunBehavior(for: driver.tabID), expectedB)
            XCTAssertEqual(expectedB.tokenBudget, 60000)
            XCTAssertEqual(expectedB.automaticFollowUp, selectedFollowUp)
            try await driver.fixture.awaitGateEvent(secondEntered)
            XCTAssertEqual(presentation(driver), .active(expectedB))
            await driver.vm.cancelAgentRun()
            secondHold.release()
            try await driver.fixture.awaitGateEvent(driver.teardownExpectation(runID: secondRunID))
            XCTAssertEqual(driver.teardownIDs, [runID, secondRunID])
            XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
            XCTAssertEqual(driver.streamStarts, 2)
            XCTAssertEqual(driver.constructed, 2)
            XCTAssertEqual(driver.disposed, 2)
            XCTAssertNil(driver.vm.pendingAskUser(for: driver.tabID))
        }

        /// A real MCP admission captures A; desired settings become B inside the first
        /// post-registration root-reconciliation callback for the owning run, before the MCP
        /// message is built. The provider receives a message built from A, the projection stays on
        /// A, idle presentation returns to B, and a second real admission captures B.
        func testMCPRunKeepsCapturedExecutionAndPresentationAfterGlobalMutation() async throws {
            try await Self.withOriginalBehaviorSettings { original in
                try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                    try await Self.settlingAdmittedRuns(driver, original: original) { admitted in
                        try await Self.mcpJourney(driver, admitted: admitted)
                    }
                }
            }
        }

        private static func mcpJourney(_ driver: ContextBuilderMultiRootDiscoveryDriver, admitted: AdmittedRuns) async throws {
            let selectedFollowUp = driver.vm.selectedFollowUpType
            // Captured MCP permission derives from the desired MCP preference for an active
            // target, never from the UI preference. In A the UI preference is off while MCP
            // questions are allowed, so the capture is true although the live UI preference is
            // false. B flips both preferences: the held run's capture stays true while the live
            // MCP preference is false, and a later real admission of B captures false although
            // the live UI preference is then true.
            var settingsA = desiredSettingsA
            settingsA.allowUIClarifyingQuestions = false
            var settingsB = desiredSettingsB
            settingsB.allowUIClarifyingQuestions = true
            GlobalSettingsStore.shared.setContextBuilderBehaviorSettings(settingsA, commit: false)
            XCTAssertEqual(desiredSettings(driver.vm), settingsA)
            let expectedA = ContextBuilderRunBehavior.mcp(settings: settingsA, wantsResponse: false, targetIsActive: true)
            XCTAssertTrue(expectedA.allowClarifyingQuestions)
            XCTAssertEqual(expectedA.tokenBudget, 70000)

            let context = try await driver.resolve()
            let authority = try await driver.authority(context)
            XCTAssertEqual(authority.configuration.runBehavior, expectedA)

            // One-shot mutation at the first reconciliation event observed with the owning run
            // registered and published. The run's discover policy is installed only after the MCP
            // message has been built, so "active run, no discover policy yet" places this callback
            // in the startup validation that precedes message construction. The callback returns
            // immediately; nothing is held here.
            var observationRunIDs: [UUID] = []
            var mutatedInRunID: UUID?
            let mutated = XCTestExpectation(description: "desired settings mutated inside the reconciliation callback")
            let discoverClientName = try XCTUnwrap(AgentProviderKind.claudeCode.mcpClientNameHint)
            driver.manager.rootReconciliationGateForTesting = { event in
                guard event.phase == .observationResponse,
                      let active = driver.vm.activeRunIDForTesting(tabID: driver.tabID) else { return }
                observationRunIDs.append(active)
                guard mutatedInRunID == nil else { return }
                mutatedInRunID = active
                admitted.ids.append(active)
                XCTAssertTrue(driver.vm.tabsWithActiveContextBuilderRun.contains(driver.tabID))
                XCTAssertEqual(driver.vm.activeRunBehavior(for: driver.tabID), expectedA)
                XCTAssertNil(driver.messagesByRunID[active], "message already delivered before the callback")
                XCTAssertEqual(driver.constructed, 0)
                let pendingPolicies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: discoverClientName)
                XCTAssertFalse(
                    pendingPolicies.contains { $0.runID == active && $0.purpose == .discoverRun },
                    "callback fired after the discover policy was installed, i.e. after message construction"
                )
                GlobalSettingsStore.shared.setContextBuilderBehaviorSettings(settingsB, commit: false)
                XCTAssertEqual(desiredSettings(driver.vm), settingsB)
                XCTAssertEqual(driver.vm.activeRunBehavior(for: driver.tabID), expectedA)
                mutated.fulfill()
            }

            let streamEntered = XCTestExpectation(description: "MCP run 1 provider stream entered")
            let hold = driver.fixture.makeGate()
            driver.streamBody = { _ in
                streamEntered.fulfill()
                await hold.wait()
            }
            let terminal = XCTestExpectation(description: "MCP run 1 settled")
            var completion: ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion?
            var callerCancelled = false
            driver.fixture.startOwnedTask {
                do { completion = try await driver.run(context, authority: authority) }
                catch is CancellationError { callerCancelled = true }
                catch { XCTFail("Unexpected MCP caller failure: \(error)") }
                terminal.fulfill()
            }
            try await driver.fixture.awaitGateEvent(mutated)
            let runID = try XCTUnwrap(mutatedInRunID)
            XCTAssertEqual(admitted.ids, [runID])

            // The provider receives a message built from A and holds its stream, so the run is
            // still active while execution and presentation are inspected.
            try await driver.fixture.awaitGateEvent(streamEntered)
            XCTAssertEqual(driver.vm.activeRunIDForTesting(tabID: driver.tabID), runID)
            XCTAssertEqual(observationRunIDs.first, runID)
            assertMessageBuiltFromA(driver.messagesByRunID[runID], liveBudgetTag: "48500")
            XCTAssertEqual(driver.vm.capturedQuestionTimeoutSeconds(tabID: driver.tabID, runID: runID), 120)
            let active = presentation(driver)
            XCTAssertEqual(active, .active(expectedA))
            XCTAssertEqual(active.tokenBudgetLabel, "70k")
            XCTAssertEqual(active.allowsClarifyingQuestions, true)
            XCTAssertNil(active.automaticFollowUp)
            XCTAssertEqual(desiredSettings(driver.vm), settingsB, "desired B was not retained")
            // The live MCP preference now disagrees with the captured permission. The live UI
            // preference agrees with it, so this check alone cannot rule out a live UI read; the
            // A capture above and the second admission below do.
            XCTAssertTrue(driver.vm.allowUIClarifyingQuestions)
            XCTAssertFalse(driver.vm.allowMCPClarifyingQuestions)

            // Settle by cancellation after execution was observed. Cancelling an MCP-controlled
            // run whose stream is still held resolves its caller with CancellationError.
            await driver.vm.cancelMCPContextBuilderRun(runID: runID)
            hold.release()
            try await driver.fixture.awaitGateEvent(terminal)
            XCTAssertTrue(callerCancelled, "MCP caller did not receive CancellationError for run 1")
            XCTAssertNil(completion)
            try await driver.fixture.awaitGateEvent(driver.teardownExpectation(runID: runID))
            XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
            XCTAssertFalse(driver.vm.isRunTeardownPendingForTesting(runID: runID))
            let idle = presentation(driver)
            XCTAssertEqual(idle, .idle(ContextBuilderRunBehavior.ui(settings: settingsB, selectedFollowUp: selectedFollowUp)))
            XCTAssertEqual(idle.tokenBudgetLabel, "60k")
            XCTAssertEqual(idle.allowsClarifyingQuestions, true)

            // A second real MCP admission captures B: MCP questions are now suppressed even though
            // the live UI preference allows questions.
            let secondContext = try await driver.resolve()
            let secondAuthority = try await driver.authority(secondContext)
            let expectedB = ContextBuilderRunBehavior.mcp(settings: settingsB, wantsResponse: false, targetIsActive: true)
            XCTAssertEqual(secondAuthority.configuration.runBehavior, expectedB)
            XCTAssertFalse(expectedB.allowClarifyingQuestions)
            XCTAssertTrue(driver.vm.allowUIClarifyingQuestions)
            let secondEntered = XCTestExpectation(description: "MCP run 2 provider stream entered")
            let secondHold = driver.fixture.makeGate()
            driver.streamBody = { _ in
                secondEntered.fulfill()
                await secondHold.wait()
            }
            let secondTerminal = XCTestExpectation(description: "MCP run 2 settled")
            var secondCompletion: ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion?
            var secondCallerCancelled = false
            driver.fixture.startOwnedTask {
                do { secondCompletion = try await driver.run(secondContext, authority: secondAuthority) }
                catch is CancellationError { secondCallerCancelled = true }
                catch { XCTFail("Unexpected second MCP caller failure: \(error)") }
                secondTerminal.fulfill()
            }
            try await driver.fixture.awaitGateEvent(secondEntered)
            let secondRunID = try XCTUnwrap(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
            admitted.ids.append(secondRunID)
            XCTAssertEqual(admitted.ids, [runID, secondRunID])
            XCTAssertNotEqual(secondRunID, runID)
            XCTAssertEqual(driver.vm.activeRunBehavior(for: driver.tabID), expectedB)
            XCTAssertEqual(driver.vm.activeRunBehavior(for: driver.tabID)?.allowClarifyingQuestions, false)
            XCTAssertEqual(presentation(driver), .active(expectedB))
            let secondMessage = try XCTUnwrap(driver.messagesByRunID[secondRunID])
            XCTAssertTrue(secondMessage.userMessage.contains("<token_budget>48500</token_budget>"))
            XCTAssertFalse(secondMessage.systemPrompt.contains("ask_user"))
            XCTAssertEqual(mutatedInRunID, runID, "callback mutated more than once or for the wrong run")
            await driver.vm.cancelMCPContextBuilderRun(runID: secondRunID)
            secondHold.release()
            try await driver.fixture.awaitGateEvent(secondTerminal)
            XCTAssertTrue(secondCallerCancelled, "MCP caller did not receive CancellationError for run 2")
            XCTAssertNil(secondCompletion)
            try await driver.fixture.awaitGateEvent(driver.teardownExpectation(runID: secondRunID))
            XCTAssertEqual(driver.teardownIDs, [runID, secondRunID])
            XCTAssertEqual(driver.runSettlementCount, 2)
            XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
            XCTAssertEqual(driver.streamStarts, 2)
            XCTAssertEqual(driver.constructed, 2)
            XCTAssertEqual(driver.disposed, 2)
        }

        func testRemovalReorderOwnershipAndDeletionDuringProviderValidationRejectBeforeConstruction() async throws {
            for mutation in ["remove", "reorder", "ownership", "delete"] {
                try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                    let context = try await driver.resolve()
                    driver.providerValidationBody = {
                        switch mutation {
                        case "remove": await driver.manager.removeFolder(driver.fixture.rootPaths[1], from: driver.fixture.workspace)
                        case "reorder": await driver.manager.moveActiveWorkspaceRoot(
                                path: driver.fixture.rootPaths[1], direction: .up, visibleRootOrder: driver.fixture.rootPaths
                            )
                        case "ownership": driver.manager.activeWorkspace = nil
                        default:
                            await driver.manager.debugDrainScheduledSaves()
                            await driver.manager.debugAwaitWorkingDocumentCommitToDomainAuthority(workspaceID: driver.fixture.workspace.id)
                            try await driver.fixture.settle()
                            // Ordinary app deletion protects active workspaces; deactivate before deleting.
                            driver.manager.activeWorkspace = nil
                            let deleted = await driver.manager.deleteWorkspaceAsync(driver.fixture.workspace)
                            XCTAssertTrue(deleted)
                        }
                    }
                    let authority = try await driver.fixture.perform("provider validation mutation " + mutation) {
                        try await driver.authority(context)
                    }
                    do {
                        _ = try await driver.fixture.perform("changed invocation startup " + mutation) {
                            try await driver.run(context, authority: authority)
                        }
                        XCTFail("Changed invocation registered a run: " + mutation)
                    } catch let error as ContextBuilderWorkspaceContextError {
                        let expected = mutation == "delete" ? "workspace_unavailable" : mutation == "ownership" ? "workspace_inactive" : "stale_invocation"
                        XCTAssertTrue(error.localizedDescription.contains("context_builder_" + expected), error.localizedDescription)
                        XCTAssertFalse(error.localizedDescription.contains(driver.fixture.base.path))
                    }
                    XCTAssertEqual(driver.constructed, 0, mutation)
                    XCTAssertEqual(driver.streamStarts, 0, mutation)
                    XCTAssertEqual(driver.disposed, 0, mutation)
                    XCTAssertEqual(driver.runSettlementCount, 1)
                    XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
                }
            }
        }

        func testCancellationWhileActualProviderStartingProgressIsHeldSettlesOnceWithoutStream() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                let context = try await driver.resolve()
                let authority = try await driver.authority(context)
                let observation = try XCTUnwrap(driver.vm.armStartupObservationForTesting(
                    windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id,
                    tabID: driver.tabID, invokingRunID: context.frozenTabContext.runID!
                ))
                let entered = XCTestExpectation(description: "actual provider starting callback held")
                let cancelled = XCTestExpectation(description: "MCP continuation cancelled before progress gate opens")
                let gate = driver.fixture.makeGate()
                var settlements = 0
                let task = driver.fixture.startOwnedTask {
                    do {
                        _ = try await driver.run(context, authority: authority) { phase in
                            guard phase == .providerProcessStarting else { return }
                            entered.fulfill()
                            await gate.wait()
                        }
                        XCTFail("Cancelled request returned a completion")
                    } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
                    settlements += 1
                    cancelled.fulfill()
                }
                try await driver.fixture.awaitGateEvent(entered)
                let runID = try XCTUnwrap(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
                task.cancel()
                try await driver.fixture.awaitGateEvent(cancelled)
                XCTAssertEqual(settlements, 1)
                XCTAssertEqual(driver.streamStarts, 0)
                XCTAssertEqual(observation.runTerminalCount, 1)
                gate.release()
                await task.value
                try await driver.assertReleased(runID: runID)
                try await driver.assertLeaseFailedExactlyOnce(runID: runID)
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.disposed, 1)
                XCTAssertEqual(observation.streamStartCount, 0)
                XCTAssertEqual(observation.teardownCount, 1)
            }
        }

        func testSamePathReplacementAtHeldFinalProgressRejectsOriginalIDsAndRecordsOneLaunchRejection() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                let events = ReadinessEvents()
                let context = try await driver.resolve(diagnosticSink: events.sink)
                let authority = try await driver.authority(context)
                let original = try XCTUnwrap(context.primaryRootSnapshot).roots
                let observation = try XCTUnwrap(driver.vm.armStartupObservationForTesting(
                    windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id,
                    tabID: driver.tabID, invokingRunID: context.frozenTabContext.runID!
                ))
                let gate = driver.fixture.makeGate()
                let entered = XCTestExpectation(description: "actual final launch progress gate")
                let completed = XCTestExpectation(description: "replacement launch terminal")
                var result: ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion?
                driver.fixture.startOwnedTask {
                    do {
                        result = try await driver.run(context, authority: authority) { phase in
                            guard phase == .providerProcessStarting else { return }
                            entered.fulfill()
                            await gate.wait()
                        }
                    } catch { XCTFail("Unexpected request failure: \(error)") }
                    completed.fulfill()
                }
                try await driver.fixture.awaitGateEvent(entered)
                await driver.files.unloadRootFolderPath(driver.fixture.rootPaths[1])
                try await driver.files.loadFolder(at: URL(fileURLWithPath: driver.fixture.rootPaths[1]), for: driver.fixture.workspace)
                let current = await driver.files.workspaceFileContextStore.primaryRootReadinessObservation(orderedPaths: driver.fixture.rootPaths)
                XCTAssertNotEqual(current.requestedRoots[1].id, original[1].id)
                XCTAssertEqual(context.primaryRootSnapshot?.roots, original)
                gate.release()
                try await driver.fixture.awaitGateEvent(completed)
                let completion = try XCTUnwrap(result)
                guard case let .failed(message) = completion.terminalDisposition else { return XCTFail("Stale launch completed") }
                XCTAssertTrue(message.contains("context_builder_stale_invocation"))
                XCTAssertTrue(message.contains("retryable=true"))
                try await driver.assertReleased(runID: completion.runID)
                try await driver.assertLeaseFailedExactlyOnce(runID: completion.runID)
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.streamStarts, 0)
                XCTAssertEqual(driver.disposed, 1)
                XCTAssertEqual(observation.streamStartCount, 0)
                XCTAssertEqual(observation.runTerminalCount, 1)
                XCTAssertEqual(observation.teardownCount, 1)
                let launchEvents = events.values.filter { $0.phase == .launchRevalidation }
                XCTAssertEqual(launchEvents.count, 1)
                XCTAssertEqual(launchEvents.first?.outcome, .rejected)
                XCTAssertEqual(launchEvents.first?.reason, .staleInvocation)
                for event in events.values {
                    XCTAssertFalse(event.description.contains(driver.fixture.base.path))
                    XCTAssertFalse(event.description.contains("SENSITIVE_DISCOVERY_PROMPT"))
                }
            }
        }

        func testSessionOwnershipLostDuringFinalValidationRetiresRealRunWithoutStream() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                let context = try await driver.resolve()
                let authority = try await driver.authority(context)
                let observation = try XCTUnwrap(driver.vm.armStartupObservationForTesting(
                    windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id,
                    tabID: driver.tabID, invokingRunID: context.frozenTabContext.runID!
                ))
                var replaced = false
                let completion = try await driver.fixture.perform("ownership lost across actual launch validation await") {
                    try await driver.run(context, authority: authority) { phase in
                        guard phase == .providerProcessStarting else { return }
                        driver.manager.rootReconciliationGateForTesting = { event in
                            guard event.phase == .probeResponse, !replaced else { return }
                            replaced = true
                            driver.vm.replaceSessionForTesting(tabID: driver.tabID)
                        }
                    }
                }
                XCTAssertTrue(replaced)
                XCTAssertEqual(completion.terminalDisposition, .cancelled)
                try await driver.assertReleased(runID: completion.runID)
                try await driver.assertLeaseFailedExactlyOnce(runID: completion.runID)
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.streamStarts, 0)
                XCTAssertEqual(driver.disposed, 1)
                XCTAssertEqual(observation.runTerminalCount, 1)
                XCTAssertEqual(observation.teardownCount, 1)
            }
        }

        func testUnboundRunAuthoritySkipsBoundProviderCWDProbe() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                try await BoundWorkspaceProbeTestCheckpoint.withCheckpoint { checkpoint in
                    let context = try await driver.resolve(boundWorkspaceProbe: checkpoint.probe)
                    _ = try await driver.authority(context)
                    XCTAssertTrue(context.worktreeBindings.isEmpty)
                    XCTAssertEqual(checkpoint.providerDirectoryStartCount, 0)
                }
            }
        }

        func testBoundRunAuthorityCWDProbeCancelsBeforeHeldResultWithoutConstructingProvider() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A", "B", "Worktree"]) { driver in
                try await BoundWorkspaceProbeTestCheckpoint.withCheckpoint { checkpoint in
                    let binding = try driver.fixture.makeWorktreeBinding(logicalRootIndex: 0, worktreeRootIndex: 2)
                    let context = try await driver.resolve(bindings: [binding], boundWorkspaceProbe: checkpoint.probe)
                    let starts = driver.manager.rootReconciliationStateForTesting.attemptStarts
                    checkpoint.arm(.providerDirectory, phase: .afterFileSystem)
                    let settled = XCTestExpectation(description: "run authority cancelled before CWD result released")
                    var cancellations = 0
                    let task = driver.fixture.startOwnedTask {
                        do {
                            _ = try await driver.authority(context)
                            XCTFail("Held bound authority probe was bypassed")
                        } catch is CancellationError { cancellations += 1 }
                        catch { XCTFail("Unexpected run authority failure: \(error)") }
                        settled.fulfill()
                    }
                    try await driver.fixture.awaitGateEvent(checkpoint.entered)
                    XCTAssertTrue(checkpoint.wasOffMainActor)
                    XCTAssertFalse(checkpoint.didFinish)
                    task.cancel()
                    await self.fulfillment(of: [settled], timeout: 1)
                    XCTAssertEqual(cancellations, 1)
                    XCTAssertFalse(checkpoint.didFinish)
                    XCTAssertEqual(driver.constructed, 0)
                    XCTAssertEqual(driver.streamStarts, 0)
                    checkpoint.release()
                    try await driver.fixture.awaitGateEvent(checkpoint.finished)
                    await checkpoint.joinWorkers()
                    try await driver.fixture.perform("bound authority cancellation joined") { await task.value }
                    XCTAssertEqual(cancellations, 1)
                    XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.attemptStarts, starts)
                    XCTAssertEqual(driver.constructed, 0)
                    XCTAssertEqual(driver.streamStarts, 0)
                }
            }
        }

        func testBoundProbeCancellationAtActualStreamBoundarySettlesAndDisposesBeforeLateWorker() async throws {
            for heldPhase in [ContextBuilderBoundWorkspaceProbe.Phase.beforeFileSystem, .afterFileSystem] {
                try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A", "B", "Worktree"]) { driver in
                    try await BoundWorkspaceProbeTestCheckpoint.withCheckpoint { checkpoint in
                        let binding = try driver.fixture.makeWorktreeBinding(logicalRootIndex: 0, worktreeRootIndex: 2)
                        let events = ReadinessEvents()
                        let context = try await driver.resolve(bindings: [binding], diagnosticSink: events.sink, boundWorkspaceProbe: checkpoint.probe)
                        let authority = try await driver.authority(context)
                        let starts = driver.manager.rootReconciliationStateForTesting.attemptStarts
                        let projection = context.lookupContext
                        let observation = try XCTUnwrap(driver.vm.armStartupObservationForTesting(
                            windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id,
                            tabID: driver.tabID, invokingRunID: context.frozenTabContext.runID!
                        ))
                        let cancelled = XCTestExpectation(description: "actual run cancelled while bound probe held")
                        var settlements = 0
                        let task = driver.fixture.startOwnedTask {
                            do {
                                _ = try await driver.run(context, authority: authority) { phase in
                                    guard phase == .providerProcessStarting else { return }
                                    checkpoint.arm(.availability, phase: heldPhase)
                                }
                                XCTFail("Cancelled actual run returned a completion")
                            } catch is CancellationError {} catch { XCTFail("Unexpected actual cancellation: \(error)") }
                            settlements += 1
                            cancelled.fulfill()
                        }
                        try await driver.fixture.awaitGateEvent(checkpoint.entered)
                        XCTAssertTrue(checkpoint.wasOffMainActor)
                        XCTAssertFalse(checkpoint.didFinish)
                        let runID = try XCTUnwrap(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
                        let started = ContinuousClock.now
                        task.cancel()
                        await self.fulfillment(of: [cancelled], timeout: 1)
                        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
                        try await driver.assertReleased(runID: runID)
                        try await driver.assertLeaseFailedExactlyOnce(runID: runID)
                        XCTAssertFalse(checkpoint.didFinish, "Run teardown must not join uncancellable filesystem I/O")
                        XCTAssertEqual(settlements, 1)
                        XCTAssertEqual(driver.constructed, 1)
                        XCTAssertEqual(driver.disposed, 1)
                        XCTAssertEqual(driver.streamStarts, 0)
                        XCTAssertEqual(observation.streamStartCount, 0)
                        XCTAssertEqual(observation.runTerminalCount, 1)
                        XCTAssertEqual(observation.teardownCount, 1)
                        checkpoint.release()
                        try await driver.fixture.awaitGateEvent(checkpoint.finished)
                        await checkpoint.joinWorkers()
                        try await driver.fixture.perform("actual cancelled bound run joined") { await task.value }
                        XCTAssertEqual(events.values.filter { $0.phase == .launchRevalidation }.map(\.outcome), [.cancelled])
                        XCTAssertEqual(driver.streamStarts, 0, "Late filesystem success cannot start the provider")
                        XCTAssertEqual(driver.disposed, 1)
                        XCTAssertEqual(observation.runTerminalCount, 1)
                        XCTAssertEqual(observation.teardownCount, 1)
                        XCTAssertEqual(driver.providerWorkspacePaths.compactMap(\.self), [driver.fixture.rootPaths[2]])
                        XCTAssertEqual(context.lookupContext, projection)
                        XCTAssertNil(context.primaryRootSnapshot)
                        XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.attemptStarts, starts)
                    }
                }
            }
        }

        func testBoundProviderCWDDisappearancePreservesStartupAndRunAuthorityErrors() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A", "B", "Worktree"]) { driver in
                // Bind B, leaving the existing primary fallback CWD A distinct from the worktree.
                let binding = try driver.fixture.makeWorktreeBinding(logicalRootIndex: 1, worktreeRootIndex: 2)
                let context = try await driver.resolve(bindings: [binding])
                XCTAssertEqual(context.providerWorkspacePath, driver.fixture.rootPaths[0])
                let projection = context.lookupContext
                let starts = driver.manager.rootReconciliationStateForTesting.attemptStarts
                let moved = driver.fixture.base.appendingPathComponent("temporarily-missing-cwd")
                try FileManager.default.moveItem(atPath: driver.fixture.rootPaths[0], toPath: moved.path)
                defer { try? FileManager.default.moveItem(atPath: moved.path, toPath: driver.fixture.rootPaths[0]) }
                do {
                    try await context.validateStartupAvailability(workspaceManager: driver.manager)
                    XCTFail("Missing provider CWD was accepted")
                } catch { XCTAssertEqual(error as? ContextBuilderWorkspaceContextError, .unavailableProviderWorkspace) }
                do {
                    _ = try await driver.authority(context)
                    XCTFail("Run authority accepted a missing provider CWD")
                } catch {
                    let error = error as NSError
                    XCTAssertEqual(error.domain, "DiscoverAgent")
                    XCTAssertEqual(error.code, 8)
                    XCTAssertEqual(error.localizedDescription, "The target workspace provider root is unavailable: " + driver.fixture.rootPaths[0])
                }
                try FileManager.default.moveItem(atPath: moved.path, toPath: driver.fixture.rootPaths[0])
                try await context.validateStartupAvailability(workspaceManager: driver.manager)
                _ = try await driver.authority(context)
                XCTAssertEqual(context.lookupContext, projection)
                XCTAssertNil(context.primaryRootSnapshot)
                XCTAssertEqual(driver.manager.rootReconciliationStateForTesting.attemptStarts, starts)
                XCTAssertEqual(driver.constructed, 0)
                XCTAssertEqual(driver.streamStarts, 0)
            }
        }

        func testBoundWorktreeDirectoryDisappearingAtActualProgressStillRejectsWithoutStream() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A", "B", "Worktree"]) { driver in
                let binding = try driver.fixture.makeWorktreeBinding(logicalRootIndex: 0, worktreeRootIndex: 2)
                let context = try await driver.resolve(bindings: [binding])
                let authority = try await driver.authority(context)
                let completion = try await driver.fixture.perform("bound worktree unavailable at launch") {
                    try await driver.run(context, authority: authority) { phase in
                        guard phase == .providerProcessStarting else { return }
                        do { try FileManager.default.removeItem(atPath: driver.fixture.rootPaths[2]) }
                        catch { XCTFail("Could not remove disposable worktree: \(error)") }
                    }
                }
                guard case let .failed(message) = completion.terminalDisposition else { return XCTFail("Unavailable binding launched") }
                XCTAssertEqual(message, ContextBuilderWorkspaceContextError.unavailableWorktreeProjection.localizedDescription)
                try await driver.assertReleased(runID: completion.runID)
                try await driver.assertLeaseFailedExactlyOnce(runID: completion.runID)
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.streamStarts, 0)
                XCTAssertEqual(driver.disposed, 1)
            }
        }

        func testBoundWorktreeStartupKeepsExistingProjectionWhenUnrelatedPrimaryRootDisappears() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A", "B", "Worktree"]) { driver in
                let binding = try driver.fixture.makeWorktreeBinding(logicalRootIndex: 0, worktreeRootIndex: 2)
                let context = try await driver.resolve(bindings: [binding])
                XCTAssertNil(context.primaryRootSnapshot)
                let authority = try await driver.authority(context)
                await driver.files.unloadRootFolderPath(driver.fixture.rootPaths[1])
                let completion = try await driver.fixture.perform("bound worktree launch control") {
                    try await driver.run(context, authority: authority)
                }
                try await driver.assertReleased(runID: completion.runID)
                XCTAssertEqual(driver.providerWorkspacePaths.compactMap(\.self), [driver.fixture.rootPaths[2]])
                XCTAssertEqual(driver.streamStarts, 1, "Unbound primary snapshot policy must not replace worktree validation")
                XCTAssertEqual(driver.disposed, 1)
            }
        }

        func testScopedActualStreamObserverHasPositiveControlAndRedactedTerminalCounts() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                let context = try await driver.resolve()
                let authority = try await driver.authority(context)
                XCTAssertNil(driver.vm.armStartupObservationForTesting(
                    windowID: driver.window.windowID + 1, workspaceID: driver.fixture.workspace.id,
                    tabID: driver.tabID, invokingRunID: context.frozenTabContext.runID!
                ))
                let observation = try XCTUnwrap(driver.vm.armStartupObservationForTesting(
                    windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id,
                    tabID: driver.tabID, invokingRunID: context.frozenTabContext.runID!
                ))
                // Deliberately throw at the substituted provider boundary: this proves the actual
                // call observer, not routed successful completion (owned by W6b).
                let completion = try await driver.fixture.perform("actual stream observation control") {
                    try await driver.run(context, authority: authority)
                }
                try await driver.assertReleased(runID: completion.runID)
                XCTAssertEqual(driver.streamStarts, 1)
                XCTAssertEqual(observation.streamStartCount, 1)
                XCTAssertEqual(observation.runTerminalCount, 1)
                XCTAssertEqual(observation.teardownCount, 1)
                XCTAssertEqual(observation.requestTerminalCount, 0, "This control enters the VM, not the MCP tool")
                XCTAssertEqual(observation.discoveryRunID, completion.runID)
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.disposed, 1)
                for sentinel in [driver.fixture.base.path, "SENSITIVE_DISCOVERY_PROMPT", "unexpected stream start"] {
                    XCTAssertFalse(observation.description.contains(sentinel))
                }
                driver.vm.clearStartupObservationForTesting()
                XCTAssertNil(driver.vm.startupObservationForTesting(
                    workspaceID: driver.fixture.workspace.id, tabID: driver.tabID,
                    invokingRunID: context.frozenTabContext.runID
                ))
            }
        }

        func testReplacedRootBeforeRegistrationThrowsTypedFailureWithoutConstructingProvider() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                let context = try await driver.resolve()
                let authority = try await driver.authority(context)
                await driver.files.unloadRootFolderPath(driver.fixture.rootPaths[1])
                try await driver.files.loadFolder(at: URL(fileURLWithPath: driver.fixture.rootPaths[1]), for: driver.fixture.workspace, freshStart: false)
                do {
                    _ = try await driver.fixture.perform("stale invocation before registration") {
                        try await driver.run(context, authority: authority)
                    }
                    XCTFail("Stale startup must throw before registering a run")
                } catch let error as ContextBuilderWorkspaceContextError {
                    XCTAssertTrue(error.localizedDescription.contains("context_builder_stale_invocation"))
                    XCTAssertTrue(error.localizedDescription.contains("retryable=true"))
                }
                XCTAssertEqual(driver.constructed, 0)
                XCTAssertEqual(driver.streamStarts, 0)
                XCTAssertNil(driver.vm.activeRunIDForTesting(tabID: driver.tabID))
            }
        }

        func testRootRemovedDuringActualProviderStartingProgressNeverStartsStreamAndDisposesConstructedProvider() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                let context = try await driver.resolve()
                let authority = try await driver.authority(context)
                var progressCount = 0
                let completion = try await driver.fixture.perform("root invalidation at actual pre-stream await") {
                    try await driver.run(context, authority: authority) { phase in
                        guard phase == .providerProcessStarting else { return }
                        progressCount += 1
                        await driver.files.unloadRootFolderPath(driver.fixture.rootPaths[1])
                    }
                }
                XCTAssertEqual(progressCount, 1)
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.streamStarts, 0)
                guard case let .failed(message) = completion.terminalDisposition else {
                    return XCTFail("Expected typed prelaunch failure")
                }
                XCTAssertTrue(message.contains("context_builder_stale_invocation"), message)
                XCTAssertTrue(message.contains("retryable=true"), message)
                XCTAssertFalse(message.contains(driver.fixture.base.path))
                XCTAssertNil(completion.committedTab)
                try await driver.assertReleased(runID: completion.runID)
                try await driver.assertLeaseFailedExactlyOnce(runID: completion.runID)
                XCTAssertEqual(driver.disposed, 1)
            }
        }

        private final class ReadinessEvents: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [ContextBuilderWorkspaceReadinessDiagnosticEvent] = []
            var values: [ContextBuilderWorkspaceReadinessDiagnosticEvent] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }

            var sink: ContextBuilderWorkspaceReadinessDiagnosticSink {
                { [self] event in
                    lock.lock()
                    storage.append(event)
                    lock.unlock()
                }
            }
        }
    }
#endif
