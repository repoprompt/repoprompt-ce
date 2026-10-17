import Foundation
import MCP
import os
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptProcess
import RepoPromptSettingsCore
import XCTest

#if DEBUG
    @MainActor
    final class ContextBuilderOracleLanePolicyTests: XCTestCase {
        private enum SetupFailure: Error { case rejected }

        func testSourceObservationRenewsBeforeDelayedReportingButCannotResurrect() {
            for observation in [599.0, 600, 601] {
                let clock = OracleSupervisionTestClock()
                let group = ContextBuilderOracleGroupSupervision(clock: { clock.now })
                let lane = group.makeLane(sessionID: UUID())
                XCTAssertTrue(lane.bind(queryID: UUID()))
                clock.advance(to: observation)
                lane.observeActivity()
                clock.advance(to: 605) // A delayed cumulative report has no renewal API.
                XCTAssertEqual(lane.isLive, observation < 600, "observation=\(observation)")
                if observation >= 600 {
                    XCTAssertEqual((lane.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
                }
            }
        }

        func testBindingAndFirstPhaseTransitionsRenewOnceWithoutResettingOverall() throws {
            let clock = OracleSupervisionTestClock()
            let group = ContextBuilderOracleGroupSupervision(clock: { clock.now })
            let lane = group.makeLane(sessionID: UUID())
            clock.advance(to: 100)
            XCTAssertTrue(lane.bind(queryID: UUID()))
            clock.advance(to: 699)
            XCTAssertFalse(lane.bind(queryID: UUID()), "Repeated binding cannot renew")
            lane.observeProviderStop()
            clock.advance(to: 1298)
            lane.observeProviderStop() // Duplicate is not activity.
            lane.observeFinalizationStart()
            clock.advance(to: 1897)
            lane.observeFinalizationStart()
            clock.advance(to: 1898)
            XCTAssertFalse(lane.isLive)
            let error = try XCTUnwrap(lane.terminalError as? OracleLaneFailure)
            XCTAssertEqual(error.code, "context_builder_inactivity_timeout")
            XCTAssertTrue(error.message.contains("finalization"))
            XCTAssertLessThan(error.message.count, 512)

            let overallClock = OracleSupervisionTestClock()
            let overallGroup = ContextBuilderOracleGroupSupervision(
                configuration: .init(overallTimeout: 900, inactivityTimeout: 600, checkInterval: 5),
                clock: { overallClock.now }
            )
            let overallLane = overallGroup.makeLane(sessionID: UUID())
            overallClock.advance(to: 500)
            XCTAssertTrue(overallLane.bind(queryID: UUID()))
            overallClock.advance(to: 899)
            overallLane.observeProviderStop()
            overallClock.advance(to: 900)
            overallLane.observeFinalizationStart()
            XCTAssertEqual((overallLane.terminalError as? OracleLaneFailure)?.code, "context_builder_overall_timeout")
        }

        func testAdmissionChecksEqualityAndOverallPrecedenceWithoutPollingOrProducer() throws {
            for (time, code) in [(600.0, "context_builder_inactivity_timeout"), (14400.0, "context_builder_overall_timeout")] {
                for success in [true, false] {
                    let clock = OracleSupervisionTestClock()
                    let lane = ContextBuilderOracleGroupSupervision(clock: { clock.now }).makeLane(sessionID: UUID())
                    clock.advance(to: time)
                    if success { XCTAssertThrowsError(try lane.admitSuccess()) }
                    else { lane.admitFailure(SetupFailure.rejected) }
                    XCTAssertNil(lane.queryID, "A terminal setup branch need not invent a producer")
                    XCTAssertEqual((lane.terminalError as? OracleLaneFailure)?.code, code)
                }
            }
            let lane = ContextBuilderOracleGroupSupervision().makeLane(sessionID: UUID())
            lane.admitFailure(SetupFailure.rejected)
            XCTAssertTrue(lane.terminalError is SetupFailure)
            XCTAssertNil(lane.queryID)
        }

        func testBoundedOneShotIsNonrenewableAndDoesNotRelaxOtherPhasesOrOverall() {
            let clock = OracleSupervisionTestClock()
            let group = ContextBuilderOracleGroupSupervision(clock: { clock.now })
            let lane = group.makeLane(sessionID: UUID())
            XCTAssertTrue(lane.bind(queryID: UUID()))
            XCTAssertTrue(lane.observeRequestProgressPolicy(.boundedOneShot(timeout: 6000)))
            clock.advance(to: 5999)
            XCTAssertTrue(lane.observeActivity())
            XCTAssertTrue(lane.observeRequestProgressPolicy(.boundedOneShot(timeout: 6000)))
            clock.advance(to: 6000)
            XCTAssertFalse(lane.isLive, "Neither heartbeat nor repeated declaration renews the one-shot bound")
            XCTAssertEqual((lane.terminalError as? OracleLaneFailure)?.code, "context_builder_request_timeout")

            let finalizationClock = OracleSupervisionTestClock()
            let finalizing = ContextBuilderOracleGroupSupervision(clock: { finalizationClock.now }).makeLane(sessionID: UUID())
            XCTAssertTrue(finalizing.bind(queryID: UUID()))
            XCTAssertTrue(finalizing.observeRequestProgressPolicy(.boundedOneShot(timeout: 6000)))
            finalizationClock.advance(to: 601)
            finalizing.observeProviderStop()
            finalizationClock.advance(to: 1201)
            XCTAssertFalse(finalizing.isLive)
            XCTAssertEqual((finalizing.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")

            let overallClock = OracleSupervisionTestClock()
            let overall = ContextBuilderOracleGroupSupervision(configuration: .init(overallTimeout: 900, inactivityTimeout: 600, checkInterval: 5), clock: { overallClock.now }).makeLane(sessionID: UUID())
            XCTAssertTrue(overall.bind(queryID: UUID()))
            XCTAssertTrue(overall.observeRequestProgressPolicy(.boundedOneShot(timeout: 6000)))
            overallClock.advance(to: 900)
            XCTAssertFalse(overall.isLive)
            XCTAssertEqual((overall.terminalError as? OracleLaneFailure)?.code, "context_builder_overall_timeout")

            for bind in [false, true] {
                let expiredClock = OracleSupervisionTestClock()
                let expired = ContextBuilderOracleGroupSupervision(clock: { expiredClock.now }).makeLane(sessionID: UUID())
                if bind { XCTAssertTrue(expired.bind(queryID: UUID())) }
                else { XCTAssertTrue(expired.observeRequestProgressPolicy(.boundedOneShot(timeout: 6000))) }
                expiredClock.advance(to: 600)
                XCTAssertFalse(expired.observeRequestProgressPolicy(.boundedOneShot(timeout: 6000)))
                XCTAssertEqual((expired.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout", "Declaration cannot relax startup or revive an expired stream")
            }
        }

        func testObservableCancellationWinsUnlatchedButLatchedOutcomeIsImmutable() throws {
            let clock = OracleSupervisionTestClock()
            let group = ContextBuilderOracleGroupSupervision(clock: { clock.now })
            let cancelled = group.makeLane(sessionID: UUID())
            let timedOut = group.makeLane(sessionID: UUID())
            let succeeded = group.makeLane(sessionID: UUID())
            clock.advance(to: 599)
            try succeeded.admitSuccess()
            clock.advance(to: 600)
            XCTAssertFalse(timedOut.checkDeadlines())
            cancelled.cancellation.request()
            XCTAssertThrowsError(try cancelled.admitSuccess())
            XCTAssertTrue(cancelled.terminalError is CancellationError)
            timedOut.cancellation.request()
            timedOut.admitFailure(CancellationError())
            XCTAssertEqual((timedOut.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
            group.cancellation.request()
            XCTAssertFalse(succeeded.checkDeadlines())
            XCTAssertNil(succeeded.terminalError, "Later cancellation cannot rewrite accepted success")
        }
    }
#endif

// MARK: - Provider transports through actual Oracle supervision

#if DEBUG
    @MainActor
    final class ProviderOracleActivityIntegrationTests: XCTestCase {
        func testCursorToolOnlyActivityCrossesRealBridgeAndRenewsOnlyItsRequest() async throws {
            try await assertCursorToolOnlyActivity(genericInitialTool: false)
        }

        func testCursorGenericEstablishedIDAdmitsNamelessLifecycleAcrossRealBridge() async throws {
            try await assertCursorToolOnlyActivity(genericInitialTool: true)
        }

        private func assertCursorToolOnlyActivity(genericInitialTool: Bool) async throws {
            try await withFixture(genericInitialTool: genericInitialTool) { fixture, driver in
                let recorder = FixtureStreamRecorder()
                let cursor = CursorCLIProvider { config, _ in
                    CursorACPHeadlessAgentProvider(
                        config: config, workspacePath: fixture.directory.path,
                        providerFactory: { _ in FixtureACPProvider(script: fixture.script.path, directory: fixture.directory.path) },
                        controllerFactory: { provider, request, sink in
                            try ACPAgentSessionController(provider: provider, runRequest: request, diagnosticSink: sink, allowsProviderProcessLaunchForTesting: true)
                        }
                    )
                }
                let run = await FixtureOracleRun(driver: driver, provider: RecordingFixtureProvider(provider: cursor, recorder: recorder))
                let first = XCTestExpectation(description: "first real provider activity consumed")
                let second = XCTestExpectation(description: "known-ID running activity consumed")
                let third = XCTestExpectation(description: "known-ID terminal activity consumed")
                run.onActivity = { count in
                    if count == 1 { first.fulfill() }
                    if count == 2 { second.fulfill() }
                    if count == 3 { third.fulfill() }
                }
                do {
                    try await fixture.waitForStage(0)
                    run.clock.advance(to: 599)
                    try fixture.release(0)
                    // Invalid updates precede the established call: none may create a heartbeat or text.
                    await self.fulfillment(of: [first], timeout: 5)
                    XCTAssertEqual(run.activities, 1)
                    XCTAssertEqual(run.semanticOutputs, [])
                    run.clock.advance(to: 1198)
                    try fixture.release(1)
                    await self.fulfillment(of: [second], timeout: 5)
                    XCTAssertTrue(run.scope.isLive, "Tool-only work must outlive the initial 600s silence budget")
                    run.clock.advance(to: 1797)
                    try fixture.release(2)
                    await self.fulfillment(of: [third], timeout: 5)
                    try fixture.release(3)
                    await run.finish()
                    XCTAssertNil(run.error)
                    XCTAssertEqual(run.response, "fixture answer")
                    XCTAssertEqual(run.activities, 3, "Unknown, wrong-session, and missing-session updates cannot certify activity")
                    let tools = recorder.results.filter { $0.type == "tool_result" }
                    XCTAssertEqual(tools.count, 2)
                    if genericInitialTool {
                        XCTAssertTrue(tools.first?.toolResultJSON?.contains("running") == true)
                    } else {
                        XCTAssertTrue(tools.first?.toolResultJSON?.contains("retained progress") == true)
                    }
                    let name = genericInitialTool ? "other" : "search"
                    XCTAssertEqual(tools.map(\.toolName), [name, name])
                    let call = try XCTUnwrap(recorder.results.first { $0.type == "tool_call" })
                    XCTAssertEqual(tools.map(\.toolInvocationID), [call.toolInvocationID, call.toolInvocationID])
                    XCTAssertEqual(tools.last?.toolIsError, true)
                } catch {
                    XCTFail("Fixture failed; Oracle error: \(String(describing: run.error))")
                    fixture.releaseAll()
                    await run.cancelAndFinish()
                    throw error
                }
                fixture.releaseAll()
                await run.cancelAndFinish()
            }
        }

        func testDevinSilentTextOneShotSurvives600sWithoutFakeActivity() async throws {
            try await withFixture { fixture, driver in
                let provider = fixture.devin(timeout: 6000)
                let run = await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
                    await FixtureOracleRun(driver: driver, provider: provider)
                }
                do {
                    try await fixture.waitForStage(0)
                    // Stage 0 is written by the actual process, after policy admission.
                    // Wait for the stream's declaration before advancing the logical supervisor.
                    await self.fulfillment(of: [run.firstOutput], timeout: 1)
                    run.clock.advance(to: 601)
                    XCTAssertTrue(run.scope.isLive, "A supported bounded silent request is not a stalled stream")
                    XCTAssertEqual(run.activities, 0, "A declaration is not provider activity")
                    XCTAssertEqual(run.semanticOutputs, [])
                    try fixture.release(0)
                    await run.finish()
                    XCTAssertNil(run.error)
                    XCTAssertEqual(run.response, "fixture answer")
                    let calls = try String(contentsOf: fixture.directory.appendingPathComponent("calls"), encoding: .utf8)
                    XCTAssertTrue(calls.contains("--prompt-file"))
                    XCTAssertFalse(calls.split(separator: "\n").contains("acp"), "Text must not dispatch ACP")
                } catch {
                    XCTFail("Fixture failed; Oracle error: \(String(describing: run.error))")
                    fixture.releaseAll()
                    await run.cancelAndFinish()
                    throw error
                }
                fixture.releaseAll()
                await run.cancelAndFinish()
            }
        }

        func testSingleEntryDevinSilentFollowUpKeepsSingleHistoryBeyond600s() async throws {
            try await withFixture { fixture, driver in
                let run = try ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
                    try FixtureSingleFollowUpRun(driver: driver, provider: fixture.devin(timeout: 6000))
                }
                do {
                    try await fixture.waitForStage(0)
                    await self.fulfillment(of: [run.policyObserved], timeout: 5)
                    try await run.clock.waitForSleep(5)
                    run.clock.advance(to: 601)
                    // The actual entry's owner must re-arm rather than cancel its silent child.
                    do { try await run.clock.waitForSleep(5) }
                    catch { XCTFail("Single-entry supervision stopped polling during a supported silent request") }
                    XCTAssertFalse(run.didSettle)
                    XCTAssertEqual(run.activities, 0)
                    try fixture.release(0)
                    await run.finish()
                    XCTAssertNil(run.error)
                    guard let reply = run.reply else {
                        XCTFail("Single entry did not return its completed reply")
                        await run.close()
                        return
                    }
                    XCTAssertEqual(reply.response, "fixture answer")
                    XCTAssertNil(reply.oracleGroup)
                    let chat = try XCTUnwrap(driver.window.oracleViewModel.sessions.first { $0.id == reply.chatId })
                    XCTAssertEqual(chat.shortID, reply.shortId)
                    XCTAssertNil(chat.oracleGroupID)
                    await driver.window.oracleViewModel.drainTrackedAutosaves(for: driver.fixture.workspace.id)
                    let savedURL = try XCTUnwrap(driver.window.oracleViewModel.sessions.first { $0.id == reply.chatId }?.fileURL)
                    let saved = try await driver.window.oracleViewModel.chatData.loadChatSession(from: savedURL)
                    XCTAssertEqual(saved.messages.count, 2)
                    XCTAssertEqual(saved.messages.first?.rawText, "fixture question")
                    XCTAssertTrue(saved.messages.last?.rawText.contains("fixture answer") == true)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("exited").path))
                } catch {
                    XCTFail("Actual single follow-up failed: \(String(describing: run.error))")
                    fixture.releaseAll()
                    await run.close()
                    throw error
                }
                fixture.releaseAll()
                await run.close()
            }
        }

        func testSingleEntryDevinCancellationDrainsActualChildWithoutPublishingSuccess() async throws {
            try await withFixture { fixture, driver in
                let run = try ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
                    try FixtureSingleFollowUpRun(driver: driver, provider: fixture.devin(timeout: 6000))
                }
                do {
                    try await fixture.waitForStage(0)
                    await run.cancelAndFinish()
                    XCTAssertNil(run.reply)
                    XCTAssertTrue(run.error is CancellationError || run.error is OracleLaneCancellation)
                    try await AsyncTestWait.waitUntil("single-entry child drained", timeout: 5) {
                        FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("exited").path)
                    }
                    XCTAssertFalse(driver.vm.isBackgroundPlanGenerating)
                } catch {
                    fixture.releaseAll()
                    await run.close()
                    throw error
                }
                fixture.releaseAll()
                await run.close()
            }
        }

        func testSingleEntryFailedAndCancelledTicketsRetainScopedRecoveryAfterRestore() async throws {
            for cancels in [true, false] {
                try await withFixture { fixture, driver in
                    let oracle = driver.window.oracleViewModel
                    let originalChats = Set(oracle.sessions.map(\.id))
                    var scope: ContextBuilderOracleLaneScope?
                    oracle.contextBuilderBeforeAvailabilityForTesting = { observed, _ in scope = observed }
                    defer { oracle.contextBuilderBeforeAvailabilityForTesting = nil }
                    let jobs = MCPLongRunningJobCenter()
                    let run = try ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
                        try FixtureSingleFollowUpRun(driver: driver, provider: fixture.devin(timeout: 6000), jobs: jobs)
                    }
                    do {
                        try await fixture.waitForStage(0)
                        await self.fulfillment(of: [run.policyObserved], timeout: 5)
                        try await run.clock.waitForSleep(5)
                        let id = try XCTUnwrap(run.jobID)
                        let admittedSnapshot = await jobs.store.snapshot(id: id)
                        let admitted = try XCTUnwrap(admittedSnapshot)
                        let capturedChatID = try XCTUnwrap(admitted.progress["chat_id"]?.stringValue)
                        let chat = try XCTUnwrap(oracle.sessions.first { $0.shortID == capturedChatID })
                        XCTAssertFalse(originalChats.contains(chat.id), "Recovery comes from this actual single chat creation")
                        XCTAssertEqual(chat.workspaceID, driver.fixture.workspace.id)
                        XCTAssertEqual(chat.composeTabID, driver.tabID)
                        XCTAssertNotNil(scope?.queryID, "A real child was admitted before the stop")
                        if cancels {
                            await run.cancelAndFinish()
                        } else {
                            run.clock.advance(to: 4 * 60 * 60)
                            await run.finish()
                        }
                        let terminalSnapshot = await jobs.store.snapshot(id: id)
                        let terminal = try XCTUnwrap(terminalSnapshot)
                        XCTAssertEqual(terminal.status, cancels ? .cancelled : .failed)
                        XCTAssertNil(terminal.result, "No successful reply was published")
                        XCTAssertNil(run.reply)
                        XCTAssertNotNil(run.error)
                        XCTAssertTrue(scope?.hasDrainedForTesting == true)
                        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("exited").path))
                        XCTAssertFalse(driver.vm.isBackgroundPlanGenerating)
                        let value = terminal.value()
                        XCTAssertEqual(value.objectValue?["job"]?.objectValue?["chat_id"]?.stringValue, capturedChatID)
                        XCTAssertNil(value.objectValue?["response_type"])
                        XCTAssertNil(value.objectValue?["plan"])
                        let formatted = ToolOutputFormatter.buildContentBlocks(toolName: "context_builder", args: [:], result: value, emitResources: false).compactMap { block -> String? in
                            if case let .text(text, _, _) = block { return text }
                            return nil
                        }.joined(separator: "\n")
                        XCTAssertTrue(formatted.contains(capturedChatID), "Default output must expose the captured recovery chat: \(formatted)")
                        let nativeJSON = ToolOutputFormatter.rawJSONString(value)
                        let nativeObject = try JSONSerialization.jsonObject(with: Data(nativeJSON.utf8))
                        var representations = [("direct", nativeJSON)]
                        for stringOutput in [false, true] {
                            for conflictingContent in [false, true] {
                                var update: [String: Any] = [
                                    "sessionUpdate": "tool_call_update", "toolCallId": "single-ticket-recovery",
                                    "title": "context_builder", "status": "completed",
                                    "rawOutput": stringOutput ? nativeJSON : nativeObject
                                ]
                                if conflictingContent {
                                    update["content"] = [["type": "text", "text": #"{"status":"completed"}"#]]
                                }
                                let events = CursorACPEventNormalizer.normalize(update)
                                guard case let .stream(output) = events.first else {
                                    throw NSError(domain: "Missing normalized ticket result", code: 1)
                                }
                                try representations.append(("string=\(stringOutput), conflict=\(conflictingContent)", XCTUnwrap(output.toolResultJSON)))
                            }
                        }
                        // A direct terminal ticket outranks an incidental echo of its earlier running state.
                        let earlierJSON = ToolOutputFormatter.rawJSONString(admitted.value())
                        let earlierObject = try JSONSerialization.jsonObject(with: Data(earlierJSON.utf8))
                        for stringOutput in [false, true] {
                            var direct = try XCTUnwrap(nativeObject as? [String: Any])
                            direct["rawOutput"] = stringOutput ? earlierJSON : earlierObject
                            try representations.append(("direct with earlier echo string=\(stringOutput)", String(decoding: JSONSerialization.data(withJSONObject: direct), as: UTF8.self)))
                        }
                        for (representation, resultJSON) in representations {
                            let invocationID = UUID()
                            let item = AgentChatItem.toolResult(
                                name: "context_builder", invocationID: invocationID,
                                argsJSON: #"{"op":"wait","message":"PRIVATE_INPUT"}"#,
                                resultJSON: resultJSON, isError: false, sequenceIndex: 1
                            )
                            let liveContext = ContextBuilderCardContext(
                                tabID: driver.tabID, contextBuilderAgentVM: driver.vm,
                                oracleOpenContext: .init(windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, tabID: driver.tabID),
                                transcriptMetadata: ContextBuilderTranscriptMetadata(rows: [item])
                            )
                            let liveCard = ContextBuilderResultCard(item: item, context: liveContext)
                            XCTAssertEqual(liveCard.followUpChatID, capturedChatID, "Live recovery representation: \(representation)")
                            XCTAssertEqual(liveCard.status, .failure, "Control-call completion must not replace failed/cancelled job status")
                            let saved = AgentSession(
                                workspaceID: driver.fixture.workspace.id, composeTabID: driver.tabID, name: "Single ticket recovery",
                                transcript: AgentTranscriptIO.importLegacyItems([.user("Build", sequenceIndex: 0), item]), lastRunState: "completed"
                            )
                            let service = AgentSessionDataService()
                            let file = try await service.saveAgentSession(saved, for: driver.fixture.workspace)
                            let loaded = try await service.loadAgentSession(from: file)
                            let transcript = try XCTUnwrap(loaded.transcript)
                            let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
                            let rows = (projection.archivedBlocks + projection.workingBlocks).flatMap(\.rows)
                            let restored = try XCTUnwrap(rows.first { $0.toolInvocationID == invocationID })
                            XCTAssertEqual(restored.kind, .toolResult, "Exercise the row that actually reaches the result card")
                            XCTAssertNil(restored.toolArgsJSON)
                            let raw = try XCTUnwrap(restored.toolResultJSON)
                            XCTAssertLessThanOrEqual(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
                            XCTAssertFalse(raw.contains("PRIVATE_INPUT"))
                            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
                            XCTAssertEqual((object["job"] as? [String: Any])?["chat_id"] as? String, capturedChatID)
                            let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: raw))
                            XCTAssertEqual(dto.ticket?.job.status.rawValue, cancels ? "cancelled" : "failed")
                            XCTAssertEqual(dto.ticket?.summaryOnly, true)
                            let context = ContextBuilderCardContext(
                                tabID: driver.tabID, contextBuilderAgentVM: driver.vm,
                                oracleOpenContext: .init(windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, tabID: driver.tabID, chatID: "ambient-chat"),
                                transcriptMetadata: ContextBuilderTranscriptMetadata(rows: rows)
                            )
                            let card = ContextBuilderResultCard(item: restored, context: context)
                            XCTAssertEqual(card.status, .failure)
                            XCTAssertTrue(card.summary.contains(cancels ? "cancelled" : "failed"))
                            let recoveryChatID = card.followUpChatID
                            XCTAssertEqual(recoveryChatID, capturedChatID, "The rendered summary must recover without response_type: \(representation)")
                            // Record explicit boundary failures without an unexpected unwrap error on the red baseline.
                            guard dto.ticket != nil else { continue }
                            if let recoveryChatID {
                                let route = try XCTUnwrap(contextBuilderOraclePopoverUserInfo(openContext: context.oracleOpenContext, chatID: recoveryChatID))
                                XCTAssertEqual(route["presentation"] as? String, "generated_answer_read_only")
                                XCTAssertEqual(route["workspaceID"] as? UUID, driver.fixture.workspace.id)
                                XCTAssertEqual(route["tabID"] as? UUID, driver.tabID)
                                let resolved = await oracle.resolveExactSessionForPopover(chatID: recoveryChatID, workspaceID: driver.fixture.workspace.id, tabID: driver.tabID)
                                XCTAssertEqual(resolved?.id, chat.id)
                            }
                            let foreign = await oracle.resolveExactSessionForPopover(chatID: capturedChatID, workspaceID: UUID(), tabID: driver.tabID)
                            XCTAssertNil(foreign, "Recovery never transfers ownership across workspaces")
                            let wrongTab = await oracle.resolveExactSessionForPopover(chatID: capturedChatID, workspaceID: driver.fixture.workspace.id, tabID: UUID())
                            XCTAssertNil(wrongTab)
                            let rejectedOwners: [(UUID?, AgentOracleOpenContext?)] = [
                                (nil, context.oracleOpenContext), (UUID(), context.oracleOpenContext), (driver.tabID, nil),
                                (driver.tabID, .init(windowID: driver.window.windowID, workspaceID: nil, tabID: driver.tabID)),
                                (driver.tabID, .init(windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, tabID: nil)),
                                (driver.tabID, .init(windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, tabID: UUID()))
                            ]
                            for (tabID, openContext) in rejectedOwners {
                                let rejected = ContextBuilderCardContext(tabID: tabID, contextBuilderAgentVM: driver.vm, oracleOpenContext: openContext, transcriptMetadata: context.transcriptMetadata)
                                XCTAssertNil(ContextBuilderResultCard(item: restored, context: rejected).followUpChatID)
                            }
                            for unrelatedInvocation in [nil, UUID()] {
                                var unrelated = restored
                                unrelated.toolInvocationID = unrelatedInvocation
                                XCTAssertNil(ContextBuilderResultCard(item: unrelated, context: context).followUpChatID)
                            }
                            var missingContext = object
                            var job = try XCTUnwrap(object["job"] as? [String: Any])
                            job.removeValue(forKey: "context_id")
                            missingContext["job"] = job
                            var unscoped = restored
                            unscoped.toolResultJSON = try String(decoding: JSONSerialization.data(withJSONObject: missingContext), as: UTF8.self)
                            XCTAssertNil(ContextBuilderResultCard(item: unscoped, context: context).followUpChatID)
                            var withReply = object
                            withReply["response_type"] = "plan"
                            withReply["plan"] = ["chat_id": "normal-reply-chat", "mode": "plan"]
                            var replyItem = restored
                            replyItem.toolResultJSON = try String(decoding: JSONSerialization.data(withJSONObject: withReply), as: UTF8.self)
                            XCTAssertEqual(ContextBuilderResultCard(item: replyItem, context: context).followUpChatID, "normal-reply-chat", "Normal reply identity remains first")
                            var observation = item
                            observation.toolResultJSON = ToolOutputFormatter.rawJSONString(admitted.value())
                            let observationSession = AgentSession(workspaceID: driver.fixture.workspace.id, composeTabID: driver.tabID, name: "Saved running observation", transcript: AgentTranscriptIO.importLegacyItems([.user("Build", sequenceIndex: 0), observation]), lastRunState: "completed")
                            let observationFile = try await service.saveAgentSession(observationSession, for: driver.fixture.workspace)
                            let restoredObservation = try await service.loadAgentSession(from: observationFile)
                            let observedProjection = try AgentTranscriptProjectionBuilder.build(from: XCTUnwrap(restoredObservation.transcript))
                            let observedRows = (observedProjection.archivedBlocks + observedProjection.workingBlocks).flatMap(\.rows)
                            let observedItem = try XCTUnwrap(observedRows.first { $0.toolInvocationID == invocationID })
                            let observedContext = ContextBuilderCardContext(tabID: driver.tabID, contextBuilderAgentVM: driver.vm, oracleOpenContext: context.oracleOpenContext, transcriptMetadata: ContextBuilderTranscriptMetadata(rows: observedRows))
                            let observationCard = ContextBuilderResultCard(item: observedItem, context: observedContext)
                            XCTAssertEqual(observationCard.status, .neutral)
                            XCTAssertTrue(observationCard.summary.contains("Live job state unknown"))
                            XCTAssertNil(observationCard.followUpChatID, "Saved running evidence must not gain live or recovery authority")
                            for invalidChat in ["  \n", String(repeating: "PRIVATE_RECOVERY_BODY", count: 100)] {
                                var invalid = object
                                var invalidJob = try XCTUnwrap(object["job"] as? [String: Any])
                                invalidJob["chat_id"] = invalidChat
                                invalid["job"] = invalidJob
                                var invalidItem = restored
                                invalidItem.toolResultJSON = try String(decoding: JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)
                                let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: invalidItem))
                                let bounded = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: summary.resultJSON))
                                XCTAssertNil(bounded.ticket?.job.chatID)
                                XCTAssertEqual(bounded.ticket?.job.status, dto.ticket?.job.status)
                                XCTAssertFalse(summary.resultJSON.contains("PRIVATE_RECOVERY_BODY"))
                                XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
                            }
                        }
                    } catch {
                        fixture.releaseAll()
                        await run.close()
                        throw error
                    }
                    fixture.releaseAll()
                    await run.close()
                }
            }
        }

        func testSingleEntryKeepsStartupFinalizationAndOverallAdmissionBoundaries() async throws {
            for phase in [ContextBuilderOracleLaneScope.Phase.startup, .streaming, .finalization] {
                try await withFixture { fixture, driver in
                    let oracle = driver.window.oracleViewModel
                    let clock = OracleSupervisionTestClock()
                    let gate = driver.fixture.makeGate()
                    let finalizing = XCTestExpectation(description: "single-entry finalizer entered")
                    let released = XCTestExpectation(description: "single-entry exact dependency released")
                    var observedScope: ContextBuilderOracleLaneScope?
                    oracle.contextBuilderBeforeAvailabilityForTesting = { scope, _ in
                        observedScope = scope
                        if phase == .startup { clock.advance(to: 600) }
                    }
                    oracle.contextBuilderBeforeFinalizationForTesting = { _ in
                        finalizing.fulfill()
                        await gate.wait()
                    }
                    oracle.contextBuilderLaneReleasedForTesting = { _ in released.fulfill() }
                    let run = try ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
                        try FixtureSingleFollowUpRun(driver: driver, provider: fixture.devin(timeout: 6000), clock: clock)
                    }
                    do {
                        if phase != .startup {
                            try await fixture.waitForStage(0)
                            await self.fulfillment(of: [run.policyObserved], timeout: 5)
                            try await clock.waitForSleep(5)
                            if phase == .finalization {
                                try fixture.release(0)
                                await self.fulfillment(of: [finalizing], timeout: 5)
                                clock.advance(to: 600)
                                await self.fulfillment(of: [released], timeout: 5)
                                XCTAssertFalse(run.didSettle, "The feature must join its blocked finalizer")
                                XCTAssertFalse(observedScope?.hasDrainedForTesting == true)
                                gate.release()
                            } else { clock.advance(to: 4 * 60 * 60) }
                        }
                        await run.finish()
                        XCTAssertNil(run.reply, "Expired work cannot publish single-lane success")
                        XCTAssertEqual(
                            (run.error as? OracleLaneFailure)?.code,
                            phase == .streaming ? "context_builder_overall_timeout" : "context_builder_inactivity_timeout"
                        )
                        XCTAssertTrue(observedScope?.hasDrainedForTesting == true)
                        if phase == .startup { XCTAssertNil(observedScope?.queryID) }
                    } catch {
                        gate.release()
                        fixture.releaseAll()
                        await run.close()
                        oracle.contextBuilderBeforeAvailabilityForTesting = nil
                        oracle.contextBuilderBeforeFinalizationForTesting = nil
                        oracle.contextBuilderLaneReleasedForTesting = nil
                        throw error
                    }
                    gate.release()
                    fixture.releaseAll()
                    await run.close()
                    oracle.contextBuilderBeforeAvailabilityForTesting = nil
                    oracle.contextBuilderBeforeFinalizationForTesting = nil
                    oracle.contextBuilderLaneReleasedForTesting = nil
                }
            }
        }

        func testDevinImageRouteKeepsStreamingSilenceDeadline() async throws {
            try await withFixture { fixture, driver in
                let provider = DevinCLIProvider(headlessProviderFactory: { config, _ in
                    DevinACPHeadlessAgentProvider(
                        config: config,
                        workspacePath: fixture.directory.path,
                        providerFactory: { _ in FixtureACPProvider(script: fixture.script.path, directory: fixture.directory.path) },
                        controllerFactory: { provider, request, sink in
                            try ACPAgentSessionController(provider: provider, runRequest: request, diagnosticSink: sink, allowsProviderProcessLaunchForTesting: true)
                        }
                    )
                })
                let run = await FixtureOracleRun(driver: driver, provider: provider, images: [.init(bytes: Data([1, 2, 3]), mediaType: .png, title: nil)])
                do {
                    try await fixture.waitForStage(0)
                    run.clock.advance(to: 600)
                    XCTAssertFalse(run.scope.isLive)
                    fixture.releaseAll()
                    await run.finish()
                    XCTAssertEqual((run.error as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
                    XCTAssertEqual(run.observedOutputs, 0, "Image ACP must not inherit a text-only silence declaration")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("calls").path))
                } catch {
                    fixture.releaseAll()
                    await run.cancelAndFinish()
                    throw error
                }
                await run.cancelAndFinish()
            }
        }

        func testDevinOneShotEnforcesItsActualProcessTimeout() async throws {
            try await assertOneShotTimeoutStopsActualChild(slowStart: false)
        }

        /// Regression witness for the hosted cold-start failure: the 0.2s timeout fires
        /// while the child is still "starting", before its SIGTERM handler exists, so the
        /// child dies by default disposition without writing `exited`. An oracle that
        /// required `exited` unconditionally fails here exactly like hosted CI did.
        func testDevinOneShotTimeoutStopsChildBeforeItInstallsHandlers() async throws {
            try await assertOneShotTimeoutStopsActualChild(slowStart: true)
        }

        private func assertOneShotTimeoutStopsActualChild(slowStart: Bool) async throws {
            try await withFixture(slowStart: slowStart) { fixture, driver in
                let run = await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
                    await FixtureOracleRun(driver: driver, provider: fixture.devin(timeout: 0.2))
                }
                await run.finish()
                XCTAssertNotNil(run.error)
                XCTAssertTrue(run.error?.localizedDescription.lowercased().contains("timed out") == true)
                XCTAssertTrue(run.scope.hasDrainedForTesting)
                // The contract: the actual child is gone when the timeout error surfaces,
                // independent of how far the interpreter got before SIGTERM arrived.
                XCTAssertFalse(try fixture.hasLiveScriptProcess(), "Timed-out one-shot child still running")
                let handlerReady = FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("handler-ready").path)
                let exited = FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("exited").path)
                if slowStart {
                    XCTAssertFalse(handlerReady, "Slow-start fixture must time out before installing its handlers")
                    XCTAssertFalse(exited)
                } else if handlerReady {
                    XCTAssertTrue(exited, "A child with SIGTERM handlers installed must observe termination")
                }
                fixture.releaseAll()
                await run.cancelAndFinish()
            }
        }

        func testDevinTextCancellationStopsActualChildAndDrainsLane() async throws {
            try await withFixture { fixture, driver in
                let run = await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
                    await FixtureOracleRun(driver: driver, provider: fixture.devin(timeout: 6000))
                }
                do {
                    try await fixture.waitForStage(0)
                    await run.cancelAndFinish()
                    XCTAssertTrue(run.error is OracleLaneCancellation)
                    XCTAssertTrue(run.scope.hasDrainedForTesting)
                    try await AsyncTestWait.waitUntil("one-shot child exited", timeout: 5) {
                        FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("exited").path)
                    }
                } catch {
                    XCTFail("Fixture failed; Oracle error: \(String(describing: run.error))")
                    fixture.releaseAll()
                    await run.cancelAndFinish()
                    throw error
                }
                fixture.releaseAll()
            }
        }

        private func withFixture(genericInitialTool: Bool = false, slowStart: Bool = false, _ body: @escaping @MainActor (ProviderCLIOracleFixture, ContextBuilderMultiRootDiscoveryDriver) async throws -> Void) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A"]) { driver in
                let fixture = try ProviderCLIOracleFixture(directory: self.makeTestDirectory(name: "ProviderOracleActivityIntegrationTests"), genericInitialTool: genericInitialTool, slowStart: slowStart)
                defer { fixture.releaseAll() }
                try await body(fixture, driver)
                await driver.window.oracleViewModel.drainTrackedAutosaves(for: driver.fixture.workspace.id)
            }
        }
    }

    @MainActor
    private final class FixtureSingleFollowUpRun {
        let clock: OracleSupervisionTestClock
        let policyObserved = XCTestExpectation(description: "actual single-entry transport policy consumed")
        let driver: ContextBuilderMultiRootDiscoveryDriver
        var activities = 0
        var didSettle = false
        var reply: ChatSendReply?
        var error: Error?
        private var task: Task<Void, Never>?
        private let jobs: MCPLongRunningJobCenter?
        private(set) var jobID: UUID?

        init(driver: ContextBuilderMultiRootDiscoveryDriver, provider: any AIProvider, clock suppliedClock: OracleSupervisionTestClock? = nil, jobs: MCPLongRunningJobCenter? = nil) throws {
            self.jobs = jobs
            self.driver = driver
            let clock = suppliedClock ?? OracleSupervisionTestClock()
            self.clock = clock
            driver.window.apiSettingsViewModel.openAIApiKey = "local-fixture-key"
            driver.window.apiSettingsViewModel.isOpenAIKeyValid = true
            driver.window.aiQueriesService.providerOverrideForTesting = provider
            driver.vm.oracleGroupClockForTesting = { [clock] in clock.now }
            driver.vm.oracleGroupSleepForTesting = { [clock] in try await clock.sleep($0) }
            driver.window.oracleViewModel.streamOutputObservedForTesting = { [weak self] _, output in
                guard let self else { return }
                if output.requestProgressPolicy != nil { policyObserved.fulfill() }
                if output.isTransportActivity { activities += 1 }
            }
            let preset = ChatPreset.BuiltIn.plan
            let execution = try OracleExecutionResolver(promptViewModel: driver.window.promptManager).resolve(
                choice: .automatic, mode: "plan",
                snapshot: OracleSelectionSnapshot(
                    origin: .mcp, agentModelsProfile: .init(planningModelRaw: AIModel.gpt54Mini.rawValue),
                    modelPresets: [], modelPresetsExposed: false, modelPresetsTemporarilyDisabled: false,
                    chatPresets: [preset], defaultChatPresets: [.plan: preset]
                )
            )
            let selection = try XCTUnwrap(driver.manager.composeTab(with: driver.tabID)?.selection)
            task = Task { @MainActor in
                let send: @MainActor (MCPLongRunningJobProgress?) async throws -> Value = { progress in
                    do {
                        let reply = try await driver.vm.runMCPPlanOrQuestion(
                            for: WorkspaceSelectionIdentity(workspaceID: driver.fixture.workspace.id, tabID: driver.tabID),
                            oracleViewModel: driver.window.oracleViewModel, mode: .plan, execution: execution,
                            prompt: "fixture question", selection: selection, reviewGitContext: .automaticOnly(), jobProgress: progress
                        )
                        self.reply = reply
                        return .object(["plan": .object(["chat_id": .string(reply.shortId)])])
                    } catch { self.error = error
                        throw error
                    }
                }
                do {
                    if let jobs {
                        let started = try await jobs.start(tool: "context_builder", owner: .init(windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, tabID: driver.tabID, sessionID: nil, runID: nil)) { progress in
                            try await send(progress)
                        }
                        self.jobID = started.id
                        _ = await jobs.store.wait(id: started.id, timeout: 30)
                    } else { _ = try await send(nil) }
                } catch { self.error = error }
                didSettle = true
            }
        }

        func finish() async {
            await task?.value
        }

        func cancelAndFinish() async {
            if let jobs, let jobID { jobs.cancel(id: jobID) }
            else { task?.cancel() }
            clock.releaseAll()
            await task?.value
        }

        func close() async {
            await cancelAndFinish()
            driver.vm.oracleGroupClockForTesting = nil
            driver.vm.oracleGroupSleepForTesting = nil
            driver.window.oracleViewModel.streamOutputObservedForTesting = nil
            driver.window.aiQueriesService.providerOverrideForTesting = nil
        }
    }

    @MainActor
    private final class FixtureOracleRun {
        let clock = OracleSupervisionTestClock()
        let scope: ContextBuilderOracleLaneScope
        let oracle: OracleViewModel
        var activities = 0
        let firstOutput = XCTestExpectation(description: "first provider stream output")
        var observedOutputs = 0
        var semanticOutputs: [String] = []
        var onActivity: ((Int) -> Void)?
        var response: String?
        var error: Error?
        private var task: Task<Void, Never>?

        init(driver: ContextBuilderMultiRootDiscoveryDriver, provider: any AIProvider, images: [AITransientImage] = []) async {
            oracle = driver.window.oracleViewModel
            driver.window.apiSettingsViewModel.openAIApiKey = "local-fixture-key"
            driver.window.apiSettingsViewModel.isOpenAIKeyValid = true
            driver.window.aiQueriesService.providerOverrideForTesting = provider
            let sessionID = UUID()
            _ = await oracle.startNewChatSession(id: sessionID, workspaceID: driver.fixture.workspace.id, tabID: driver.tabID, reuseBlankSession: false)
            scope = ContextBuilderOracleGroupSupervision(clock: { [clock] in clock.now }, sleep: { [clock] in try await clock.sleep($0) }).makeLane(sessionID: sessionID)
            oracle.oracleImageThumbnailsForTesting = { _ in [] }
            oracle.streamOutputObservedForTesting = { [weak self] _, output in
                guard let self else { return }
                observedOutputs += 1
                if observedOutputs == 1 { firstOutput.fulfill() }
                if output.isTransportActivity { activities += 1
                    onActivity?(activities)
                }
                if !output.text.isEmpty { semanticOutputs.append(output.text) }
            }
            task = Task {
                do {
                    let result = try await scope.run(oracle: oracle) {
                        let pendingQuery = await self.oracle.sendMessage(
                            "fixture question", sessionID: self.scope.sessionID, overrideModel: .gpt54Mini,
                            oracleTransientImages: images, contextBuilderScope: self.scope
                        )
                        let query = try XCTUnwrap(pendingQuery)
                        let text = try await self.oracle.waitForContextBuilderCompletion(query)
                        return OracleLaneExecutionResponse(response: text)
                    }
                    response = result.response
                } catch { self.error = error }
            }
        }

        func finish() async {
            await task?.value
        }

        func cancelAndFinish() async {
            task?.cancel()
            clock.releaseAll()
            await task?.value
            oracle.streamOutputObservedForTesting = nil
            oracle.oracleImageThumbnailsForTesting = nil
        }
    }

    private final class FixtureStreamRecorder: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: [RepoPromptDomainRuntime.AIStreamResult]())
        var results: [AIStreamResult] {
            state.withLock { $0 }
        }

        func append(_ result: AIStreamResult) {
            state.withLock { $0.append(result) }
        }
    }

    private struct RecordingFixtureProvider: AIProvider {
        let provider: any AIProvider
        let recorder: FixtureStreamRecorder
        func streamMessage(_ message: AIMessage, model: AIModel, maxTokens: Int?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
            let upstream = try await provider.streamMessage(message, model: model, maxTokens: maxTokens)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await result in upstream {
                            recorder.append(result)
                            continuation.yield(result)
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func completeMessage(_ message: AIMessage, model: AIModel, maxTokens: Int?) async throws -> AICompletionResult {
            try await provider.completeMessage(message, model: model, maxTokens: maxTokens)
        }

        func dispose() async {
            await provider.dispose()
        }
    }

    private struct FixtureACPProvider: ACPAgentProvider {
        let script: String
        let directory: String
        let providerID = ACPProviderID.cursor
        func support(for request: ACPRunRequest) async throws -> ACPSupportResult {
            .supported
        }

        func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
            ACPLaunchConfiguration(providerID: providerID, command: script, arguments: [], environment: ["FIXTURE_DIR": directory], workingDirectory: directory, additionalPathHints: [], enableDebugLogging: false)
        }

        func makeSessionConfiguration(for request: ACPRunRequest, mcpServer: RepoPromptMCPServerConfiguration) throws -> ACPSessionConfiguration {
            ACPSessionConfiguration(mode: .load(existingSessionID: "fixture-session"), workingDirectory: directory, mcpServers: [])
        }

        func buildPromptBlocks(for message: AgentMessage, request: ACPRunRequest) throws -> [[String: Any]] {
            [["type": "text", "text": message.userMessage]]
        }

        func normalizeSessionUpdate(_ payload: [String: Any], sessionID: String) -> [NormalizedAgentRuntimeEvent] {
            CursorACPEventNormalizer.normalize(payload)
        }

        func normalizeError(_ error: Error) -> Error {
            error
        }
    }

    private struct ProviderCLIOracleFixture {
        let directory: URL
        let script: URL
        private struct PgrepFailure: Error { let status: Int32 }

        /// `slowStart` simulates a cold interpreter start in the one-shot branch: the child
        /// sleeps before installing its SIGTERM/SIGINT handlers. The sleep far exceeds any
        /// provider timeout used with it, so only real termination ends the child early.
        init(directory: URL, genericInitialTool: Bool = false, slowStart: Bool = false) throws {
            self.directory = directory
            if genericInitialTool {
                try Data().write(to: directory.appendingPathComponent("generic-initial-tool"))
            }
            if slowStart {
                try Data("60".utf8).write(to: directory.appendingPathComponent("slow-start"))
            }
            script = directory.appendingPathComponent("devin")
            let body = #"""
            #!/usr/bin/env python3
            import json, os, sys, time, signal
            from pathlib import Path
            root = Path(os.environ.get("FIXTURE_DIR", str(Path(__file__).parent)))
            def release(n):
                (root / ("stage" + str(n))).write_text("ready")
                while not (root / ("release" + str(n))).exists(): time.sleep(0.01)
            def send(value): print(json.dumps(value), flush=True)
            def update(value, session="fixture-session"):
                send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":session, "update":value}})
            def respond(id, result): send({"jsonrpc":"2.0", "id":id, "result":result})
            if len(sys.argv) > 1:
                if sys.argv[1:] == ["acp", "--help"]:
                    print("Run as an ACP server over stdio")
                    sys.exit(0)
                slow = root / "slow-start"
                if slow.exists(): time.sleep(float(slow.read_text()))
                def stopped(*_):
                    (root / "exited").write_text("cancelled")
                    sys.exit(0)
                signal.signal(signal.SIGTERM, stopped)
                signal.signal(signal.SIGINT, stopped)
                (root / "handler-ready").write_text(str(os.getpid()))
                (root / "calls").write_text("\n".join(sys.argv[1:]))
                release(0)
                print("fixture answer", end="", flush=True)
                (root / "exited").write_text("completed")
                sys.exit(0)
            for line in sys.stdin:
                request = json.loads(line); method = request.get("method"); id = request.get("id")
                if method == "initialize": respond(id, {"agentCapabilities":{"loadSession":True,"promptCapabilities":{"image":True}}, "authMethods":[]})
                elif method == "session/new": respond(id, {"sessionId":"fixture-session", "configOptions":[{"id":"mode", "name":"Mode", "category":"mode", "type":"select", "currentValue":"ask", "options":[{"value":"ask", "name":"Ask"}]}]})
                elif method == "session/load":
                    update({"sessionUpdate":"agent_message_chunk", "content":{"type":"text", "text":"replayed answer"}})
                    update({"sessionUpdate":"tool_call", "toolCallId":"replayed", "title":"search"})
                    update({"sessionUpdate":"usage_update", "used":100})
                    respond(id, {"sessionId":"fixture-session", "configOptions":[{"id":"mode", "name":"Mode", "category":"mode", "type":"select", "currentValue":"ask", "options":[{"value":"ask", "name":"Ask"}]}]})
                elif method == "session/prompt":
                    release(0)
                    update({"sessionUpdate":"tool_call_update", "toolCallId":"unknown", "status":"in_progress"})
                    update({"sessionUpdate":"tool_call_update", "toolCallId":"replayed", "status":"in_progress"})
                    update({"sessionUpdate":"usage_update", "used":100}, session="wrong-session")
                    update({"sessionUpdate":"agent_message_chunk", "content":{"type":"text", "text":"wrong-session answer"}}, session="wrong-session")
                    update({"sessionUpdate":"usage_update", "used":100}, session=None)
                    generic = (root / "generic-initial-tool").exists()
                    initial = {"sessionUpdate":"tool_call", "toolCallId":"known", "rawInput":{"query":"fixture"}}
                    initial.update({"kind":"other"} if generic else {"title":"search"})
                    update(initial)
                    release(1)
                    update({"sessionUpdate":"tool_call_update", "toolCallId":"known ", "status":"in_progress"})
                    running = {"sessionUpdate":"tool_call_update", "toolCallId":"known", "status":"in_progress"}
                    if not generic: running["rawOutput"] = {"output":"retained progress"}
                    update(running)
                    release(2)
                    update({"sessionUpdate":"tool_call_update", "toolCallId":"known", "status":"failed"})
                    release(3)
                    update({"sessionUpdate":"tool_call_update", "toolCallId":"known", "status":"in_progress"})
                    update({"sessionUpdate":"agent_message_chunk", "content":{"type":"text", "text":"fixture answer"}})
                    respond(id, {"stopReason":"end_turn"})
                elif id is not None: respond(id, {})
            """#
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        func waitForStage(_ stage: Int) async throws {
            try await AsyncTestWait.waitUntil("CLI stage \(stage)", timeout: 5) { FileManager.default.fileExists(atPath: directory.appendingPathComponent("stage\(stage)").path) }
        }

        func release(_ stage: Int) throws {
            try Data().write(to: directory.appendingPathComponent("release\(stage)"))
        }

        func releaseAll() {
            for stage in 0 ... 3 {
                try? release(stage)
            }
        }

        /// True while any process whose command line contains this fixture's unique
        /// script path exists (the interpreter runs it as `python3 <script> ...`).
        func hasLiveScriptProcess() throws -> Bool {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            // pgrep takes a POSIX ERE; escape exactly its metacharacters so the path matches literally.
            let pattern = script.path.map { #".[]()*+?{}|^$\"#.contains($0) ? "\\\($0)" : String($0) }.joined()
            pgrep.arguments = ["-f", pattern]
            pgrep.standardOutput = FileHandle.nullDevice
            pgrep.standardError = FileHandle.nullDevice
            try pgrep.run()
            pgrep.waitUntilExit()
            switch pgrep.terminationStatus {
            case 0: return true
            case 1: return false
            default: throw PgrepFailure(status: pgrep.terminationStatus)
            }
        }

        func devin(timeout: TimeInterval) -> DevinCLIProvider {
            DevinCLIProvider(config: DevinAgentConfig(commandName: script.path, includeRepoPromptMCPServer: false), launchResolver: DevinACPLaunchResolver(launchEnvironmentProvider: { _ in ACPLaunchEnvironment(environment: ["PATH": "/usr/bin:/bin", "FIXTURE_DIR": directory.path], shellEnvironmentSource: nil) }), requestTimeout: timeout)
        }
    }
#endif
