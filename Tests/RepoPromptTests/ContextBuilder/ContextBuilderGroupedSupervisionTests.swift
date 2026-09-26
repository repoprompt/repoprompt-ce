import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class ContextBuilderGroupedSupervisionTests: XCTestCase {
        func testUIGroupWaitsForAuthoritativeCompletionAfterInteractiveGrace() async throws {
            try await withHarness { harness in
                let driver = harness.driver
                let index = try XCTUnwrap(driver.manager.workspaces.firstIndex { $0.id == driver.fixture.workspace.id })
                driver.manager.workspaces[index].composeTabs[0].promptText = "Build the controlled plan"
                driver.window.promptManager.loadComposeTabsFromWorkspace(driver.manager.workspaces[index], syncPromptText: true)
                harness.start {
                    harness.uiReply = try await driver.vm.generatePlanFromDiscovery(
                        tabID: driver.tabID, originWorkspaceID: driver.fixture.workspace.id,
                        oracleViewModel: driver.window.oracleViewModel
                    )
                }
                try await harness.waitForStreams()
                try await harness.emit(.gpt54Mini, text: "first ")
                harness.clock.advance(to: 2)
                try await harness.emit(.gpt54Mini, text: "second ")
                XCTAssertTrue(harness.interactiveWatchdogObserved)
                let interactive = harness.interactiveWatchdogEnabled
                if interactive { try await harness.clock.waitForSleep(10) }
                harness.clock.advance(to: 13)
                if interactive {
                    try await harness.wait(harness.oldWatchdogChecked)
                    try await harness.wait(harness.cancelled[.gpt54Mini]!)
                }
                // Authoritative completion arrives after the old watchdog, but well before CB's budget.
                harness.complete(.gpt54Mini, text: "late completion")
                harness.complete(.gpt54, text: "auxiliary complete")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                let result = try XCTUnwrap(harness.uiReply?.oracleGroup?.result)
                XCTAssertEqual(result.oracleResults.map(\.status), [.completed, .completed])
                XCTAssertEqual(result.oracleResults[0].response, "first second late completion")
                XCTAssertEqual(result.oracleResults[1].response, "auxiliary complete")
            }
        }

        func testRegisteredMCPGroupBoundsInitialSilenceIndependentlyOfActiveSibling() async throws {
            try await withHarness(routed: true) { harness in
                let driver = harness.driver
                driver.streamBody = { runID in
                    let child = try await driver.connectChild(runID: runID)
                    try await driver.discover(using: child)
                }
                let context = try await driver.resolve()
                let connection = try await driver.connectInvokingAgent(context)
                harness.start {
                    let reply = try await connection.client.callTool(name: "context_builder", arguments: [
                        "instructions": .string("Build a controlled plan"), "response_type": .string("plan"),
                        "oracle_preset": .string(harness.preset.name), "_rawJSON": .bool(true)
                    ])
                    let text = reply.content.compactMap { content -> String? in
                        if case let .text(text, _, _) = content { return text }
                        return nil
                    }.joined(separator: "\n")
                    harness.mcpReply = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                }
                try await harness.waitForStreams()
                harness.clock.advance(to: 599)
                try await harness.emit(.gpt54, text: "active sibling ")
                harness.clock.advance(to: 605)
                // Assert autonomous cancellation BEFORE any rescue. A strict-only forwarding patch
                // leaves this registered silent lane pending; an active sibling must not renew it.
                let autonomous = await XCTWaiter.fulfillment(of: [harness.cancelled[.gpt54Mini]!], timeout: 2) == .completed
                XCTAssertTrue(autonomous, "Silent lane must time out without caller cancellation or fixture rescue")
                XCTAssertFalse(harness.didSettle, "The still-running sibling remains independent")
                if !autonomous { harness.complete(.gpt54Mini, text: "RESCUE ONLY") }
                harness.complete(.gpt54, text: "complete")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                let plan = try XCTUnwrap(harness.mcpReply?["plan"] as? [String: Any])
                let lanes = try XCTUnwrap(plan["oracle_results"] as? [[String: Any]])
                XCTAssertEqual(lanes.count, 2)
                XCTAssertEqual(lanes[0]["status"] as? String, "failed")
                XCTAssertEqual((lanes[0]["error"] as? [String: Any])?["code"] as? String, "context_builder_inactivity_timeout")
                XCTAssertEqual(lanes[1]["status"] as? String, "completed")
                XCTAssertEqual(lanes[1]["response"] as? String, "active sibling complete")
                XCTAssertEqual(driver.constructed, 1)
                XCTAssertEqual(driver.teardownIDs.count, 1)
            }
        }

        func testUnthrottledTransportRenewsButTokenOnlyProgressDoesNot() async throws {
            for transport in [true, false] {
                try await withHarness { harness in
                    try harness.startUI()
                    try await harness.waitForStreams()
                    harness.clock.advance(to: 599)
                    try await harness.emit(.gpt54Mini, text: "partial ")
                    harness.clock.advance(to: 599.5)
                    try await harness.emitOutput(.gpt54Mini, output: .init(
                        text: "", reasoning: nil, tokens: .init(completionTokens: 42), isTransportActivity: transport
                    ))
                    harness.complete(.gpt54, text: "sibling")
                    harness.clock.advance(to: 1199.25)
                    // This terminal admission itself checks expiry; no poll scheduling assumption.
                    harness.complete(.gpt54Mini, text: "complete")
                    try await harness.wait(harness.settled)
                    let result = try XCTUnwrap(harness.uiReply?.oracleGroup?.result.oracleResults.first)
                    if transport {
                        XCTAssertEqual(result.status, .completed)
                        XCTAssertEqual(result.response, "partial complete")
                    } else {
                        XCTAssertEqual(result.status, .failed)
                        XCTAssertEqual(result.error?.code, "context_builder_inactivity_timeout")
                        XCTAssertEqual(result.error?.partialResponse, "partial ")
                        XCTAssertNotNil(result.executionProfile)
                    }
                }
            }
        }

        func testRejectedActivityCannotProjectAfterIntraEventTimeoutOrCancellation() async throws {
            for cancels in [false, true] {
                try await withHarness { harness in
                    let oracle = harness.driver.window.oracleViewModel
                    let released = XCTestExpectation(description: "rejected activity released exact lane")
                    var primary: ContextBuilderOracleLaneScope?
                    var progressTexts: [String] = []
                    var progressReasoning: [String?] = []
                    oracle.contextBuilderBeforeChatResolutionForTesting = { scope, model in
                        if model == .gpt54Mini { primary = scope }
                    }
                    oracle.contextBuilderLaneReleasedForTesting = { scope in
                        if scope === primary { released.fulfill() }
                    }
                    try harness.startUI { text, reasoning in
                        progressTexts.append(text)
                        progressReasoning.append(reasoning)
                    }
                    try await harness.waitForStreams()
                    let scope = try XCTUnwrap(primary)
                    let queryID = try XCTUnwrap(scope.queryID)
                    oracle.pinSession(scope.sessionID)
                    defer { oracle.unpinSession(scope.sessionID) }
                    try await harness.emitOutput(.gpt54Mini, output: .init(
                        text: "accepted ", reasoning: "accepted reasoning", tokens: .init()
                    ))
                    let accepted = try XCTUnwrap(oracle.getChatMessage(withId: queryID))
                    XCTAssertEqual(accepted.content, "accepted ")
                    XCTAssertEqual(progressTexts, ["accepted "])
                    XCTAssertEqual(progressReasoning, [accepted.reasoningContent])
                    harness.clock.advance(to: 599)
                    try await harness.emit(.gpt54, text: "sibling ")
                    var boundaryFired = false
                    oracle.streamWatchdogNowForTesting = { [clock = harness.clock] in
                        // This synchronous hook runs AFTER the projection guard, before the scope's
                        // activity observation. A due poll cannot interleave inside this block.
                        if !boundaryFired {
                            boundaryFired = true
                            if cancels { scope.cancellation.request() }
                            else { clock.advance(to: 600) }
                        }
                        return Date(timeIntervalSince1970: clock.now)
                    }
                    harness.complete(.gpt54Mini, text: "late", reasoning: " late reasoning")
                    // Rejected output intentionally has no post-projection acknowledgment.
                    try await harness.wait(released)
                    XCTAssertTrue(boundaryFired, "The intended intra-event boundary must be reached")
                    let retained = try XCTUnwrap(oracle.getChatMessage(withId: queryID))
                    XCTAssertEqual(retained.content, accepted.content, "Rejected delta reached the transcript; cancellation=\(cancels)")
                    XCTAssertEqual(retained.reasoningContent, accepted.reasoningContent, "Rejected reasoning reached the transcript")
                    XCTAssertEqual(progressTexts, ["accepted "], "Rejected delta reached the UI progress callback")
                    XCTAssertEqual(progressReasoning, [accepted.reasoningContent], "Rejected reasoning reached the UI progress callback")
                    harness.complete(.gpt54, text: "complete")
                    try await harness.wait(harness.settled)
                    XCTAssertNil(harness.error)
                    let results = try XCTUnwrap(harness.uiReply?.oracleGroup?.result.oracleResults)
                    XCTAssertEqual(results.map(\.status), [cancels ? .cancelled : .failed, .completed])
                    XCTAssertEqual(results[0].error?.code, cancels ? "cancelled" : "context_builder_inactivity_timeout")
                    XCTAssertEqual(results[0].error?.partialResponse, "accepted ", "Rejected delta reached the returned partial")
                    XCTAssertEqual(results[1].response, "sibling complete")
                    XCTAssertTrue(scope.hasDrainedForTesting)
                }
            }
        }

        func testOrdinaryInteractiveWatchdogAndAttachedN1StrictRouteRemainDistinct() async throws {
            try await withHarness { harness in
                let oracle = harness.driver.window.oracleViewModel
                let session = try await oracle.locateOrCreateChat(nil, desiredName: "Ordinary", forceNew: true, tabID: harness.driver.tabID, activateInUI: false)
                let query = await oracle.sendMessage("Ordinary request", sessionID: session, overrideModel: .gpt54Mini)
                let queryID = try XCTUnwrap(query)
                try await harness.waitForStream(.gpt54Mini)
                try await harness.emit(.gpt54Mini, text: "first ")
                harness.clock.advance(to: 2)
                try await harness.emit(.gpt54Mini, text: "second ")
                XCTAssertTrue(harness.interactiveWatchdogEnabled)
                try await harness.clock.waitForSleep(10)
                harness.clock.advance(to: 13)
                try await harness.wait(harness.cancelled[.gpt54Mini]!)
                do { _ = try await oracle.waitForContextBuilderCompletion(queryID)
                    XCTFail("Ordinary watchdog is still non-authoritative")
                } catch OracleContextBuilderCompletionError.interactiveWatchdogFinalization {
                    // Authoritative old-watchdog outcome.
                } catch is CancellationError {
                    // The existing stream cancellation/finalizer race is also an old-policy outcome.
                } catch {
                    XCTFail("Unexpected ordinary completion error: \(error)")
                }
            }
            try await withHarness { harness in
                GlobalSettingsStore.shared.setWorkspaceAgentModelsProfile(
                    workspaceID: harness.driver.fixture.workspace.id,
                    profile: .init(planningModelRaw: AIModel.gpt54Mini.rawValue)
                )
                try harness.startUI()
                try await harness.waitForStream(.gpt54Mini)
                try await harness.emit(.gpt54Mini, text: "N1 ")
                harness.clock.advance(to: 2)
                try await harness.emit(.gpt54Mini, text: "strict ")
                XCTAssertTrue(harness.interactiveWatchdogObserved)
                XCTAssertFalse(harness.interactiveWatchdogEnabled)
                harness.clock.advance(to: 13)
                harness.complete(.gpt54Mini, text: "complete")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                XCTAssertNil(harness.uiReply?.oracleGroup)
                XCTAssertEqual(harness.uiReply?.response, "N1 strict complete")
                XCTAssertEqual(harness.registeredModels, [.gpt54Mini])
            }
        }

        func testStartupDeadlineIncludesPreQueryAwaitWithoutInventingAStream() async throws {
            try await withHarness { harness in
                let gate = harness.driver.fixture.makeGate()
                let entered = XCTestExpectation(description: "primary pre-query await entered")
                var primary: ContextBuilderOracleLaneScope?
                harness.driver.window.oracleViewModel.contextBuilderBeforeChatResolutionForTesting = { scope, model in
                    if model == .gpt54Mini {
                        primary = scope
                        entered.fulfill()
                        await gate.wait()
                    }
                }
                try harness.startUI()
                try await harness.wait(entered)
                try await harness.waitForStream(.gpt54)
                try await harness.clock.waitForSleep(5)
                harness.clock.advance(to: 599)
                try await harness.emit(.gpt54, text: "active ")
                try await harness.clock.waitForSleep(5)
                harness.clock.advance(to: 605)
                // There is no provider/waiter to release while startup itself is gated.
                // Explicit admission after expiry must reject even if the poll has not run yet.
                let scope = try XCTUnwrap(primary)
                XCTAssertThrowsError(try scope.checkpoint())
                XCTAssertEqual((scope.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
                XCTAssertNil(scope.queryID)
                XCTAssertNil(scope.streamID)
                gate.release()
                harness.complete(.gpt54, text: "complete")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                XCTAssertEqual(harness.registeredModels, [.gpt54])
                XCTAssertTrue(scope.hasDrainedForTesting)
                XCTAssertEqual(harness.uiReply?.oracleGroup?.result.oracleResults[0].error?.code, "context_builder_inactivity_timeout")
            }
        }

        func testLateUnavailableModelSettlesWithoutBindingOrProviderDispatch() async throws {
            try await withHarness { harness in
                var rejected: ContextBuilderOracleLaneScope?
                let oracle = harness.driver.window.oracleViewModel
                oracle.contextBuilderBeforeAvailabilityForTesting = { scope, model in
                    // This is AFTER actual UI resolution/validation, at sendMessage's own late branch.
                    harness.driver.window.apiSettingsViewModel.isOpenAIKeyValid = model != .gpt54Mini
                    if model == .gpt54Mini { rejected = scope }
                }
                try harness.startUI()
                try await harness.waitForStream(.gpt54)
                harness.complete(.gpt54, text: "available sibling")
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                let scope = try XCTUnwrap(rejected)
                XCTAssertNil(scope.queryID)
                XCTAssertNil(scope.streamID)
                XCTAssertTrue(scope.hasDrainedForTesting)
                XCTAssertEqual(harness.registeredModels, [.gpt54])
                XCTAssertEqual(harness.uiReply?.oracleGroup?.result.oracleResults.map(\.status), [.failed, .completed])
                let error = try XCTUnwrap(harness.uiReply?.oracleGroup?.result.oracleResults.first?.error)
                XCTAssertTrue(error.message.contains("not available"))
            }
        }

        func testTimedOutFinalizerDrainsWithoutClearingReplacementDuringOuterCancellation() async throws {
            try await withHarness { harness in
                let driver = harness.driver
                let oracle = driver.window.oracleViewModel
                let gate = driver.fixture.makeGate()
                let entered = XCTestExpectation(description: "owned finalizer suspended")
                let released = XCTestExpectation(description: "exact stream and hub released before finalizer join")
                var primary: ContextBuilderOracleLaneScope?
                oracle.contextBuilderBeforeChatResolutionForTesting = { scope, model in
                    if model == .gpt54Mini { primary = scope }
                }
                oracle.contextBuilderBeforeFinalizationForTesting = { scope in
                    if scope === primary { entered.fulfill()
                        await gate.wait()
                    }
                }
                oracle.contextBuilderLaneReleasedForTesting = { scope in
                    if scope === primary { released.fulfill() }
                }
                try harness.startUI()
                try await harness.waitForStreams()
                harness.complete(.gpt54Mini, text: "unprocessed <chatName name=\"Stale rename\"/>")
                harness.complete(.gpt54, text: "complete sibling")
                try await harness.wait(entered)
                let scope = try XCTUnwrap(primary)
                let oldQuery = try XCTUnwrap(scope.queryID)
                // Keep the observation target resident: ordinary MCP unpin may legitimately evict it.
                oracle.pinSession(scope.sessionID)
                defer { oracle.unpinSession(scope.sessionID) }
                let oldContent = oracle.getChatMessage(withId: oldQuery)?.content
                let oldName = oracle.sessions.first { $0.id == scope.sessionID }?.name
                XCTAssertGreaterThanOrEqual(scope.ownedTaskCountForTesting, 2)
                try await harness.clock.waitForSleep(5)
                harness.clock.advance(to: 605)
                try await harness.wait(released)
                XCTAssertEqual((scope.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
                XCTAssertFalse(scope.hasDrainedForTesting, "Stream/observer end is not finalizer drainage")
                XCTAssertFalse(harness.didSettle)
                let replacementRegistered = harness.expectNextStream(.gpt54Mini)
                let replacement = await oracle.sendMessage("Replacement", sessionID: scope.sessionID, overrideModel: .gpt54Mini)
                let replacementQuery = try XCTUnwrap(replacement)
                try await harness.wait(replacementRegistered)
                try await harness.emit(.gpt54Mini, text: "replacement ")
                let generation = try XCTUnwrap(driver.vm.sessions[driver.tabID]).followUpOracleGroupState.generation
                let groupID = try XCTUnwrap(driver.vm.sessions[driver.tabID]?.followUpOracleGroupState.groupID)
                harness.cancelRequest() // outer withTaskCancellationHandler path
                driver.vm.cancelBackgroundPlanGeneration(forTabID: driver.tabID) // cancelAndDrain path
                gate.release()
                try await harness.wait(harness.settled)
                XCTAssertTrue(scope.hasDrainedForTesting)
                XCTAssertEqual(scope.ownedTaskCountForTesting, 0)
                let owner = try OracleViewModel.oracleGroupOwner(workspaceID: driver.fixture.workspace.id, tabID: driver.tabID)
                let stored = try await AppDomainRuntimeComposition.shared.oracleConversationStore.load(groupID: groupID, owner: owner)
                XCTAssertEqual(stored?.turns.last?.results.first?.error?.code, "context_builder_inactivity_timeout")
                XCTAssertEqual((scope.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
                XCTAssertNotEqual(driver.vm.sessions[driver.tabID]?.followUpOracleGroupState.generation, generation)
                XCTAssertEqual(oracle.activeQueryId(for: scope.sessionID), replacementQuery)
                XCTAssertTrue(oracle.isSessionStreaming(scope.sessionID))
                XCTAssertEqual(oracle.getChatMessage(withId: oldQuery)?.content, oldContent)
                XCTAssertEqual(oracle.sessions.first { $0.id == scope.sessionID }?.name, oldName)
                harness.complete(.gpt54Mini, text: "complete")
                let response = try await oracle.waitForContextBuilderCompletion(replacementQuery)
                XCTAssertEqual(response, "replacement complete")
                XCTAssertEqual(harness.registeredModels.count, 3)
            }
        }

        func testMemberCancellationWaitsForOwnedFinalizerDrain() async throws {
            try await withHarness { harness in
                let oracle = harness.driver.window.oracleViewModel
                let gate = harness.driver.fixture.makeGate()
                let entered = XCTestExpectation(description: "member finalizer entered")
                let released = XCTestExpectation(description: "member cancellation released dependencies")
                var primary: ContextBuilderOracleLaneScope?
                oracle.contextBuilderBeforeChatResolutionForTesting = { scope, model in
                    if model == .gpt54Mini { primary = scope }
                }
                oracle.contextBuilderBeforeFinalizationForTesting = { scope in
                    if scope === primary { entered.fulfill()
                        await gate.wait()
                    }
                }
                oracle.contextBuilderLaneReleasedForTesting = { scope in
                    if scope === primary { released.fulfill() }
                }
                try harness.startUI()
                try await harness.waitForStreams()
                harness.complete(.gpt54Mini, text: "cancelled partial")
                harness.complete(.gpt54, text: "completed sibling")
                try await harness.wait(entered)
                let scope = try XCTUnwrap(primary)
                var stopReturned = false
                let stop = Task { @MainActor in
                    await oracle.cancelAIResponse(in: scope.sessionID)
                    stopReturned = true
                }
                do {
                    try await harness.wait(released)
                    XCTAssertFalse(stopReturned)
                    XCTAssertFalse(scope.hasDrainedForTesting)
                    XCTAssertTrue(scope.terminalError is CancellationError)
                    gate.release()
                    await stop.value
                } catch {
                    gate.release()
                    await stop.value
                    throw error
                }
                try await harness.wait(harness.settled)
                XCTAssertNil(harness.error)
                XCTAssertTrue(scope.hasDrainedForTesting)
                XCTAssertEqual(harness.uiReply?.oracleGroup?.result.oracleResults.map(\.status), [.cancelled, .completed])
            }
        }

        func testRemoteCleanupIsNeitherCancelledNorJoinedBySuccessOrTimeout() async throws {
            for timesOut in [false, true] {
                try await withHarness { harness in
                    let oracle = harness.driver.window.oracleViewModel
                    let gate = harness.driver.fixture.makeGate()
                    let entered = XCTestExpectation(description: "fake remote cleanup entered")
                    var calls = 0
                    var finished = false
                    oracle.providerConversationCleanupForTesting = { handle in
                        XCTAssertEqual(handle.sessionID, "controlled-remote")
                        XCTAssertFalse(Task.isCancelled, "Local latch must not cancel remote cleanup")
                        calls += 1
                        entered.fulfill()
                        await gate.wait()
                        XCTAssertFalse(Task.isCancelled)
                        finished = true
                    }
                    try harness.startUI()
                    try await harness.waitForStreams()
                    try await harness.emitOutput(.gpt54Mini, output: .init(
                        text: "partial ", reasoning: nil, tokens: .init(),
                        cleanupHandle: .init(provider: "controlled", sessionID: "controlled-remote")
                    ))
                    harness.complete(.gpt54, text: "sibling complete")
                    if timesOut {
                        try await harness.clock.waitForSleep(5)
                        harness.clock.advance(to: 605)
                    } else {
                        harness.complete(.gpt54Mini, text: "complete")
                    }
                    try await harness.wait(entered)
                    try await harness.wait(harness.settled)
                    XCTAssertNil(harness.error)
                    XCTAssertEqual(harness.uiReply?.oracleGroup?.result.oracleResults[0].status, timesOut ? .failed : .completed)
                    if timesOut {
                        XCTAssertEqual(harness.uiReply?.oracleGroup?.result.oracleResults[0].error?.code, "context_builder_inactivity_timeout")
                    }
                    XCTAssertEqual(calls, 1, "Transferred cleanup handle must not be reused by producer catch")
                    XCTAssertFalse(finished, "Group must settle while remote disposal is still gated")
                    gate.release()
                }
            }
        }

        private func withHarness(
            routed: Bool = false,
            _ body: @escaping @MainActor (GroupedOracleHarness) async throws -> Void
        ) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A", "B", "C"], routedRuntime: routed) { driver in
                let harness = try GroupedOracleHarness(driver: driver)
                do {
                    try await body(harness)
                    await harness.close()
                } catch {
                    await harness.close()
                    throw error
                }
            }
        }
    }

    /// One clock drives both the real legacy watchdog and the candidate lane scope.
    /// Sleeps acknowledge registration and are cancellation-connected; advancing never guesses
    /// how many executor yields constitute an observation.
    @MainActor
    final class OracleSupervisionTestClock {
        private(set) var now: TimeInterval = 0
        private var waits: [UUID: (deadline: TimeInterval, seconds: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = [:]
        private var armWaits: [(TimeInterval, XCTestExpectation)] = []

        func sleep(_ seconds: TimeInterval) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    waits[id] = (now + seconds, seconds, continuation)
                    let matching = armWaits.filter { $0.0 == seconds }
                    armWaits.removeAll { $0.0 == seconds }
                    matching.forEach { $0.1.fulfill() }
                }
            } onCancel: {
                Task { @MainActor in self.waits.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
            }
        }

        func advance(to value: TimeInterval) {
            precondition(value >= now)
            now = value
            let due = waits.filter { $0.value.deadline <= now }
            for (id, wait) in due {
                waits.removeValue(forKey: id)
                wait.continuation.resume()
            }
        }

        func waitForSleep(_ seconds: TimeInterval) async throws {
            if waits.values.contains(where: { $0.seconds == seconds }) { return }
            let event = XCTestExpectation(description: "scheduler armed \(seconds)s")
            armWaits.append((seconds, event))
            guard await XCTWaiter.fulfillment(of: [event], timeout: 5) == .completed else {
                throw GroupedOracleHarness.Failure.checkpoint(event.expectationDescription)
            }
        }

        func releaseAll() {
            let pending = waits.values
            waits.removeAll()
            pending.forEach { $0.continuation.resume(throwing: CancellationError()) }
        }
    }

    @MainActor
    private final class GroupedOracleHarness {
        enum Failure: Error { case checkpoint(String) }
        let driver: ContextBuilderMultiRootDiscoveryDriver
        let clock = OracleSupervisionTestClock()
        let preset: ModelPreset
        let settled = XCTestExpectation(description: "consumer result settled")
        let oldWatchdogChecked = XCTestExpectation(description: "legacy watchdog checked after its armed grace")
        let cancelled: [AIModel: XCTestExpectation] = [
            .gpt54Mini: XCTestExpectation(description: "primary stream cancelled by production owner"),
            .gpt54: XCTestExpectation(description: "auxiliary stream cancelled by production owner")
        ]
        var uiReply: ChatSendReply?
        var mcpReply: [String: Any]?
        var error: Error?
        private(set) var didSettle = false
        private(set) var interactiveWatchdogEnabled = false
        private(set) var interactiveWatchdogObserved = false
        private var remoteCleanupTasks: [Task<Void, Never>] = []
        private var streams: [AIModel: (id: UUID, continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation)] = [:]
        private var streamEvents: [AIModel: XCTestExpectation] = [:]
        private var outputEvent: (text: String, event: XCTestExpectation)?
        private var producers: [Task<Void, Never>] = []
        private var allStreams: [(id: UUID, continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation)] = []
        private(set) var registeredModels: [AIModel] = []
        private var request: Task<Void, Never>?
        private var producerExits = 0
        private let previousPresets: [ModelPreset]
        private let previousExposure: Bool
        private let previousDisabled: Bool

        init(driver: ContextBuilderMultiRootDiscoveryDriver) throws {
            self.driver = driver
            let settings = GlobalSettingsStore.shared
            previousPresets = ModelPresetsManager.shared.presets
            previousExposure = settings.mcpShowModelPresets()
            previousDisabled = settings.mcpTemporarilyDisablePresets()
            preset = try ModelPreset(name: "Controlled 1033", models: [.gpt54Mini, .gpt54])
            ModelPresetsManager.shared.presets = [preset]
            settings.setMCPShowModelPresets(true, commit: false)
            settings.setMCPTemporarilyDisablePresets(false, commit: false)
            settings.setWorkspaceAgentModelsProfile(workspaceID: driver.fixture.workspace.id, profile: .init(
                planningModelRaw: AIModel.gpt54Mini.rawValue, additionalOracleModelRaws: [AIModel.gpt54.rawValue]
            ))
            driver.window.apiSettingsViewModel.openAIApiKey = "test-key"
            driver.window.apiSettingsViewModel.isOpenAIKeyValid = true
            let oracle = driver.window.oracleViewModel
            oracle.streamWatchdogNowForTesting = { [clock] in Date(timeIntervalSince1970: clock.now) }
            oracle.streamWatchdogSleepForTesting = { [clock] in try await clock.sleep($0) }
            driver.vm.oracleGroupClockForTesting = { [clock] in clock.now }
            driver.vm.oracleGroupSleepForTesting = { [clock] in try await clock.sleep($0) }
            oracle.streamWatchdogScheduledForTesting = { [weak self] _, grace, enabled in
                if grace == 10 {
                    self?.interactiveWatchdogObserved = true
                    self?.interactiveWatchdogEnabled = enabled
                }
            }
            oracle.streamWatchdogCheckedForTesting = { [weak self] _ in self?.oldWatchdogChecked.fulfill() }
            oracle.providerConversationCleanupForTesting = { _ in XCTFail("Unexpected fixture cleanup handle") }
            oracle.providerCleanupTaskScheduledForTesting = { [weak self] task in self?.remoteCleanupTasks.append(task) }
            oracle.streamOutputObservedForTesting = { [weak self] _, output in
                guard let self, let pending = outputEvent, pending.text == output.text else { return }
                outputEvent = nil
                pending.event.fulfill()
            }
            oracle.setOraclePostPackagingTransportOverrideForTesting { [unowned self] _, model in
                let id = UUID()
                let stream = AsyncThrowingStream<ChatStreamOutput, Error>.makeStream()
                let stopped = AsyncStream<Void>.makeStream()
                let cancelledEvent = cancelled[model]!
                stream.continuation.onTermination = { reason in
                    switch reason {
                    case .cancelled: cancelledEvent.fulfill()
                    case let .finished(error): if error is CancellationError { cancelledEvent.fulfill() }
                    @unknown default: break
                    }
                    stopped.continuation.finish()
                }
                let producer = Task { @MainActor in
                    for await _ in stopped.stream {}
                    self.producerExits += 1
                }
                producers.append(producer)
                await driver.window.aiQueriesService.registerControlledStreamForTesting(
                    id: id, continuation: stream.continuation, producer: producer
                )
                streams[model] = (id, stream.continuation)
                allStreams.append((id, stream.continuation))
                registeredModels.append(model)
                streamEvents.removeValue(forKey: model)?.fulfill()
                return (id, stream.stream)
            }
        }

        func startUI(onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil) throws {
            let index = try XCTUnwrap(driver.manager.workspaces.firstIndex { $0.id == driver.fixture.workspace.id })
            driver.manager.workspaces[index].composeTabs[0].promptText = "Build the controlled plan"
            driver.window.promptManager.loadComposeTabsFromWorkspace(driver.manager.workspaces[index], syncPromptText: true)
            start {
                self.uiReply = try await self.driver.vm.generatePlanFromDiscovery(
                    tabID: self.driver.tabID, originWorkspaceID: self.driver.fixture.workspace.id,
                    oracleViewModel: self.driver.window.oracleViewModel, onProgress: onProgress
                )
            }
        }

        func cancelRequest() {
            request?.cancel()
        }

        func expectNextStream(_ model: AIModel) -> XCTestExpectation {
            let event = XCTestExpectation(description: "registered controlled \(model.rawValue) stream")
            streamEvents[model] = event
            return event
        }

        func waitForStream(_ model: AIModel) async throws {
            if streams[model] != nil { return }
            try await wait(expectNextStream(model))
        }

        func start(_ operation: @escaping @MainActor () async throws -> Void) {
            request = Task { @MainActor in
                do { try await operation() } catch { self.error = error }
                didSettle = true
                settled.fulfill()
            }
        }

        func wait(_ event: XCTestExpectation) async throws {
            guard await XCTWaiter.fulfillment(of: [event], timeout: 10) == .completed else {
                throw Failure.checkpoint(event.expectationDescription)
            }
        }

        func waitForStreams() async throws {
            for model in [AIModel.gpt54Mini, .gpt54] where streams[model] == nil {
                let event = XCTestExpectation(description: "registered controlled \(model.rawValue) stream")
                streamEvents[model] = event
                try await wait(event)
            }
        }

        func emit(_ model: AIModel, text: String) async throws {
            try await emitOutput(model, output: .init(text: text, reasoning: nil, tokens: .init()))
        }

        func emitOutput(_ model: AIModel, output: ChatStreamOutput) async throws {
            let event = XCTestExpectation(description: "Oracle consumed controlled output")
            outputEvent = (output.text, event)
            streams[model]!.continuation.yield(output)
            try await wait(event)
        }

        func complete(_ model: AIModel, text: String, reasoning: String? = nil) {
            streams[model]?.continuation.yield(.init(text: text, reasoning: reasoning, tokens: .init(), terminalOutcome: .completed))
            streams[model]?.continuation.finish()
        }

        func close() async {
            // Release every fixture-owned dependency BEFORE joining, even after an assertion/escape.
            driver.fixture.releaseAllGates()
            allStreams.forEach { $0.continuation.finish(throwing: CancellationError()) }
            request?.cancel()
            clock.releaseAll()
            await request?.value
            // The fixture joins its own fake remote cleanup; production lane supervision does not.
            for cleanup in remoteCleanupTasks {
                await cleanup.value
            }
            for producer in producers {
                producer.cancel()
                await producer.value
            }
            for stream in allStreams {
                await driver.window.aiQueriesService.removeControlledStreamForTesting(id: stream.id)
            }
            XCTAssertEqual(producerExits, producers.count, "Controlled producer tasks drained (not a remote provider-disposal claim)")
            let oracle = driver.window.oracleViewModel
            // Oracle persistence is separately owned, not part of lane drainage. The fixture
            // must finish its workspace's tracked writes before the driver removes its files.
            await oracle.drainTrackedAutosaves(for: driver.fixture.workspace.id)
            oracle.setOraclePostPackagingTransportOverrideForTesting(nil)
            oracle.streamWatchdogNowForTesting = nil
            oracle.streamWatchdogSleepForTesting = nil
            oracle.streamOutputObservedForTesting = nil
            oracle.streamWatchdogCheckedForTesting = nil
            oracle.streamWatchdogScheduledForTesting = nil
            oracle.contextBuilderBeforeChatResolutionForTesting = nil
            oracle.contextBuilderBeforeAvailabilityForTesting = nil
            oracle.contextBuilderBeforeFinalizationForTesting = nil
            oracle.contextBuilderLaneReleasedForTesting = nil
            oracle.providerConversationCleanupForTesting = nil
            oracle.providerCleanupTaskScheduledForTesting = nil
            driver.vm.oracleGroupClockForTesting = nil
            driver.vm.oracleGroupSleepForTesting = nil
            ModelPresetsManager.shared.presets = previousPresets
            GlobalSettingsStore.shared.setMCPShowModelPresets(previousExposure, commit: false)
            GlobalSettingsStore.shared.setMCPTemporarilyDisablePresets(previousDisabled, commit: false)
        }
    }
#endif
