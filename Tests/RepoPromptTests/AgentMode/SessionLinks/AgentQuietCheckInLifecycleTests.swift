import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentQuietCheckInLifecycleTests: XCTestCase {
    private func fixture(_ agent: AgentProviderKind = .claudeCode) -> (AgentSessionLinkRunnerHarness, AgentTabSession, AgentRunOwnership, UUID) {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, replayTranscript: true)
        let session = harness.makeSession(agent: agent)
        let runID = UUID()
        session.runLifecycle.installRunID(runID)
        session.runState = .running
        let owner = session.beginRunAttempt(source: "quiet-replay")
        // Test-only physical origin. Production marking deliberately does not arrive until C3.
        session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
        return (harness, session, owner, runID)
    }

    @discardableResult
    private func commit(
        _ harness: AgentSessionLinkRunnerHarness,
        _ session: AgentTabSession,
        _ owner: AgentRunOwnership,
        normal: Bool = true,
        successor: AgentRunTerminalCommitBarrier.ProviderSuccessor? = nil,
        prepare: @escaping () -> Void = {}
    ) async -> AgentRunTerminalCommitRevision? {
        await AgentRunTerminalCommitBarrier().commit(.init(
            binding: harness.hooks.bindTerminalSession(session), ownership: owner, expectedRunID: session.runID,
            terminalState: .completed, source: "quiet-replay", attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: false, supportsFollowUp: true, providerSuccessor: successor,
            notifyTurnComplete: true, classifiesQuietCheckIn: normal,
            prepareProviderState: { prepare()
                return nil
            }
        ))
    }

    func testUndeclaredBarrierSealsOrdinaryBeforeTeardownWithoutSuppressingNotification() async {
        let (h, s, owner, _) = fixture()
        var completed = 0
        h.onTurnComplete = { completed += 1 }
        var preparingFacts: AgentRunQuietFacts?
        var idleFacts: AgentRunQuietFacts?
        var teardownFacts: AgentRunQuietFacts?
        s.onRunStateChanged = { session in idleFacts = session.quietRunFacts(capturedState: session.runState) }
        s.installRunAttemptTerminalResources(ownership: owner) { _ in
            teardownFacts = s.quietLedger.facts
            return nil
        }
        let revision = await commit(h, s, owner, prepare: { preparingFacts = s.quietRunFacts(capturedState: .running) })
        XCTAssertNotNil(revision)
        XCTAssertEqual(preparingFacts, .zero)
        XCTAssertEqual(idleFacts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1))
        XCTAssertEqual(teardownFacts, idleFacts)
        XCTAssertEqual(completed, 1)
        XCTAssertNil(s.activeRunOwnership)
        XCTAssertTrue(s.quietLedger.hiddenSourceIDs.isEmpty)
        XCTAssertFalse(s.endRunAttempt(ifCurrent: owner, source: "duplicate"))
        XCTAssertEqual(s.quietLedger.facts, idleFacts)
    }

    func testSecondBarrierGuardRejectsOwnerLostDuringFinalization() async {
        let (h, s, owner, _) = fixture()
        var item = AgentChatItem.assistant("[ack]")
        item.isStreaming = true
        s.appendItem(item)
        s.onSourceItemsChanged = { session, _ in _ = session.endCurrentRunAttempt(source: "finalization-owner-loss") }
        let result = await commit(h, s, owner)
        XCTAssertNil(result)
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1))
        XCTAssertTrue(s.quietLedger.hiddenSourceIDs.isEmpty)
    }

    func testDefaultFalseAndBothSuccessorKindsRemainOrdinary() async {
        for variant in 0 ..< 3 {
            let (h, s, owner, _) = fixture()
            if variant == 1 { s.pendingInstructions.append(AgentRunPendingInstruction(providerText: "follow up", localDraftText: "follow up")) }
            let successor: AgentRunTerminalCommitBarrier.ProviderSuccessor? = variant == 2
                ? .init(id: UUID(), transitionKind: .relatedFollowUp, consumeAfterPublication: { _, _ in true }) : nil
            _ = await commit(h, s, owner, normal: variant != 0, successor: successor)
            XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1))
            XCTAssertTrue(s.quietLedger.hiddenSourceIDs.isEmpty)
        }
    }

    func testBothAcceptedProgressAPIsLatchAndStaleSignalsDoNot() async throws {
        for acceptedAPI in [false, true] {
            let (h, s, owner, _) = fixture()
            let stale = AgentRunOwnership(binding: owner.binding)
            _ = s.recordRunProgress(ownership: stale, kind: .toolActivity, stage: .running)
            XCTAssertNotNil(s.quietLedger.candidateStartKey(owner: owner))
            if acceptedAPI {
                let live = try XCTUnwrap(s.runLifecycle.liveness)
                _ = s.acceptRunProgress(.init(
                    ownership: owner,
                    sequence: live.lastAcceptedSequence + 1,
                    timestampUptimeNanoseconds: live.lastSignalUptimeNanoseconds + 1,
                    kind: .interaction,
                    stage: .waitingForInteraction,
                    retryIntent: .none
                ))
            } else {
                _ = s.recordRunProgress(ownership: owner, kind: .toolActivity, stage: .running)
            }
            XCTAssertNil(s.quietLedger.candidateStartKey(owner: owner))
            _ = await commit(h, s, owner)
            XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1)
        }
    }

    func testCentralEndMissingBeginAbandonAndBindingRetirementUseExistingAuthority() {
        let (_, s, first, _) = fixture()
        let next = s.beginRunAttempt(source: "abandon")
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1))
        XCTAssertFalse(s.endRunAttempt(ifCurrent: first, source: "stale"))
        s.quietLedger = AgentRunQuietLedger() // Simulates a missing begin hook, not restoration.
        XCTAssertTrue(s.endRunAttempt(ifCurrent: next, source: "known-untracked-end"))
        XCTAssertFalse(s.endCurrentRunAttempt(source: "duplicate"))
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1))
        let old = s.beginRunAttempt(source: "old-binding")
        _ = s.beginPersistentBindingTransition()
        XCTAssertTrue(s.endRunAttempt(ifCurrent: old, source: "retired-binding"))
        XCTAssertEqual(s.quietLedger.facts, .zero, "Retired old ownership cannot advance the replacement source")
    }

    func testAcceptedPreSealTaskCannotBecomeQuietAfterWithdrawalAndPostSealCannotReopen() async {
        for managed in [false, true] {
            let (h, s, owner, _) = fixture()
            let attribution = managed ? AgentCrossSessionAttribution(sourceSessionID: UUID(), sourceName: "Observer", linkID: UUID()) : nil
            s.appendItem(.user("task", crossSessionAttribution: attribution))
            _ = s.removeItem(at: 0)
            _ = await commit(h, s, owner)
            XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1)
            let sealed = s.quietLedger.facts
            s.noteAcceptedTaskInput()
            XCTAssertEqual(s.quietLedger.facts, sealed)
        }
        let (h, s, owner, _) = fixture()
        _ = await commit(h, s, owner)
        let hidden = s.quietLedger.hiddenSourceIDs
        s.appendItem(.user("later task"))
        XCTAssertEqual(s.quietLedger.hiddenSourceIDs, hidden)
        let successor = s.beginRunAttempt(source: "accepted-successor")
        XCTAssertTrue(s.endRunAttempt(ifCurrent: successor, source: "ordinary-successor"))
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 2))
    }

    func testFinalizationPreservesIdentityWhileOpaqueRangeChangesAndUndeclaredRowsStayOrdinary() async {
        for variant in 0 ..< 5 {
            let (h, s, owner, _) = fixture()
            var row = AgentChatItem.assistant("[ack]")
            row.isStreaming = true
            s.appendItem(row)
            switch variant {
            case 0: h.host.finalizeStreamingItems(in: s)
            case 1: s.setItemsSilentlyForRetentionCompaction(s.items)
            case 2: s.replaceItem(at: 0, with: .assistant("[ack]", sequenceIndex: 0))
            case 3: s.setItemsSilently(s.items, reason: .persistedSessionHydration)
            default: _ = s.removeItem(at: 0)
            }
            if variant == 0 {
                XCTAssertEqual(s.items.first?.id, row.id)
                XCTAssertEqual(s.items.first?.isStreaming, false)
                XCTAssertNotNil(s.quietLedger.candidateStartKey(owner: owner))
            } else {
                XCTAssertNil(s.quietLedger.candidateStartKey(owner: owner), "Opaque range mutation cannot qualify")
            }
            _ = await commit(h, s, owner)
            XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1, "No declaration: final text is never authority")
        }
    }

    func testOlderRowRekeyedAcrossAttemptBoundaryInvalidatesWithoutRangeScan() async {
        let (h, s, owner, _) = fixture()
        s.appendItem(.assistant("[ack]"))
        _ = await commit(h, s, owner)
        let next = s.beginRunAttempt(source: "rekey-boundary")
        s.quietLedger.markRoutineWake(owner: next, wakeID: UUID())
        XCTAssertNotNil(s.quietLedger.candidateStartKey(owner: next))
        s.mutateItem(at: 0) { $0.sequenceIndex = s.nextSequenceIndex }
        XCTAssertNil(s.quietLedger.candidateStartKey(owner: next))
        s.appendItem(.assistant("[ack]"))
        _ = await commit(h, s, next)
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 2))
    }

    func testClearAndFreshAttemptRangesDoNotRequireAllocatorRepairOrCounterReset() async {
        let (h, s, owner, _) = fixture()
        s.appendItem(.assistant("[ack]"))
        s.setItemsSilently([], reason: .clearedChat)
        s.nextSequenceIndex = 0 // The existing clear writer, under the same source binding.
        _ = await commit(h, s, owner)
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1))
        let next = s.beginRunAttempt(source: "after-clear")
        s.quietLedger.markRoutineWake(owner: next, wakeID: UUID())
        XCTAssertNotNil(s.quietLedger.candidateStartKey(owner: next), "A fresh post-clear allocator range is valid, but still needs a declaration")
        s.appendItem(.assistant("[ack]"))
        _ = await commit(h, s, next)
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 2))
    }

    func testRawClaudeUndeclaredFinishedMessagesAndSilenceRemainOrdinaryAtBarrier() async {
        let cases: [[String]] = [
            [#"{"type":"system","subtype":"init"}"#, #"{"type":"result","subtype":"success","result":"[ack]"}"#],
            [
                #"{"type":"assistant","message":{"id":"one","content":[{"type":"text","text":"prose"}]}}"#,
                #"{"type":"result","subtype":"success","result":"[ack]"}"#
            ],
            [
                #"{"type":"assistant","message":{"id":"one","content":[{"type":"text","text":"prose"}]}}"#,
                #"{"type":"assistant","message":{"id":"two","content":[{"type":"text","text":"[ack]"}]}}"#,
                #"{"type":"result","subtype":"success","result":"[ack]"}"#
            ],
            [#"{"type":"system","subtype":"init"}"#, #"{"type":"result","subtype":"success"}"#],
            // A result without its completion subtype is not positively successful metadata.
            [#"{"type":"result","result":"[ack]"}"#]
        ]
        for wire in cases {
            let (h, s, owner, runID) = fixture()
            var translator = ClaudeSDKNDJSONTranslator()
            let events = wire.flatMap { translator.parseNDJSONLine(Data($0.utf8)) }.map { NativeAgentRuntimeEvent.stream($0) }
            let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: h.host.claudeCoordinator, hooks: h.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
            await runner.testConsumeQuietEvents(events, session: s, runID: runID, owner: owner)
            _ = await commit(h, s, owner)
            XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1, "\(wire)")
        }
    }

    func testClaudeControllerCodecKeepsUndeclaredSilenceAndUnknownActivityOrdinary() async {
        for wire in [
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"system","subtype":"task_started","task_id":"background"}"#,
            #"{"type":"system","subtype":"task_notification"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use"}}}"#,
            #"{"type":"stream_event","event":{"type":"future_event"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"prose"}]}}"#,
            #"{"type":"future_activity"}"#,
            #"{"type":"control_request","request_id":"unknown","request":{"subtype":"future_request"}}"#,
            #"{"type":"control_request","request_id":"permission","request":{"subtype":"can_use_tool","tool_name":"mcp__RepoPrompt__get_file_tree","input":{}}}"#,
            #"{"type":"result","result":"[ack]"}"#,
            "malformed provider line"
        ] {
            let (h, s, owner, runID) = fixture()
            let controller = ClaudeNativeProcessSessionController(
                runID: runID, tabID: s.tabID, windowID: -1, workspacePath: nil,
                config: .agentMode(commandName: "/usr/bin/false")
            )
            await controller.test_installConfigurationTransport(write: { _ in })
            let stream = await controller.events
            let turnID = await controller.test_beginTurnTracking()
            s.claudeExpectedTurnIDs.insert(turnID)
            await controller.test_receiveConfigurationResponseLine(Data(wire.utf8))
            if !wire.contains(#""type":"result""#) {
                await controller.test_receiveConfigurationResponseLine(Data(#"{"type":"result","subtype":"success","result":"[ack]"}"#.utf8))
            }
            await controller.shutdown()
            var events: [NativeAgentRuntimeEvent] = []
            for await event in stream {
                events.append(event)
            }
            let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: h.host.claudeCoordinator, hooks: h.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
            let completed = await runner.testConsumeQuietEvents(events, session: s, runID: runID, owner: owner)
            XCTAssertTrue(completed, "The real runner accepted its expected normal completion")
            _ = await commit(h, s, owner)
            XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1, wire)
        }
    }

    func testClaudeControllerStreamingFinalizationPreservesOrdinaryAuthoritativeReplacement() async {
        let start = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"one","type":"message","role":"assistant","content":[]}}}"#
        let blockStart = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#
        let blockStop = #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#
        let stop = #"{"type":"stream_event","event":{"type":"message_stop"}}"#
        for text in ["[ack]", "prose"] {
            let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
            await assertClaudeControllerUndeclaredCompletion([start, blockStart, delta, blockStop, stop], expectedTexts: ["[ack]"])
        }
        // Final authoritative replacement follows the same ordinary bubble policy;
        // there is no separate quiet-only message-boundary grammar.
        let prose = #"{"type":"assistant","message":{"id":"one","content":[{"type":"text","text":"prose"}]}}"#
        let ack = #"{"type":"assistant","message":{"id":"two","content":[{"type":"text","text":"[ack]"}]}}"#
        await assertClaudeControllerUndeclaredCompletion([prose, stop, ack, stop], expectedTexts: ["prose", "[ack]"])
        await assertClaudeControllerUndeclaredCompletion([], expectedTexts: ["[ack]"])
        await assertClaudeControllerUndeclaredCompletion([], expectedTexts: [], finalText: nil)
    }

    func testClaudeControllerMalformedMessageStartCannotBorrowFinishedMessageQuietProof() async {
        for message in [#"{}"#, #"{"id":7}"#, #"{"id":""}"#] {
            await assertClaudeControllerUndeclaredCompletion([
                #"{"type":"assistant","message":{"id":"one","content":[{"type":"text","text":"prose"}]}}"#,
                #"{"type":"stream_event","event":{"type":"message_stop"}}"#,
                #"{"type":"stream_event","event":{"type":"message_start","message":\#(message)}}"#
            ], expectedTexts: ["[ack]"], expectsUncertainty: true)
        }
    }

    func testClaudeControllerMalformedAssistantTextValuesRemainOrdinaryBeforeAuthoritativeAck() async {
        for type in ["assistant", "message"] {
            for field in ["", #", "text":null"#, #", "text":42"#] {
                // Interpolate raw JSON fields without coercing invalid values into Strings.
                let block = #"{"type":"text"\#(field)}"#
                await assertClaudeControllerUndeclaredCompletion([
                    #"{"type":"\#(type)","message":{"id":"m","content":[\#(block)]}}"#
                ], expectedTexts: ["[ack]"], expectsUncertainty: true)
            }
        }
    }

    func testClaudeControllerMalformedSuccessfulResultValuesRemainOrdinary() async {
        for value in [#"{"unexpected":"content"}"#, #"["content"]"#, "42", "null", "true"] {
            await assertClaudeControllerUndeclaredCompletion(
                [], expectedTexts: [], finalResultValue: value, expectsUncertainty: true
            )
        }
        // Omitted and well-formed empty output are ordinary undeclared completions, not uncertainty.
        await assertClaudeControllerUndeclaredCompletion([], expectedTexts: [], finalText: nil)
        await assertClaudeControllerUndeclaredCompletion([], expectedTexts: [], finalText: "")
        await assertClaudeControllerUndeclaredCompletion([], expectedTexts: ["[ack]"])
    }

    func testClaudeControllerMalformedKnownDeltaPayloadsRemainOrdinary() async {
        let start = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m","content":[]}}}"#
        for (type, field) in [("text_delta", "text"), ("thinking_delta", "thinking"), ("signature_delta", "signature")] {
            for value in [nil, "null", "42"] as [String?] {
                let data = value.map { #", "\#(field)":\#($0)"# } ?? ""
                await assertClaudeControllerUndeclaredCompletion([
                    start, #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"\#(type)"\#(data)}}}"#
                ], expectedTexts: ["[ack]"], expectsUncertainty: true)
            }
        }
    }

    func testClaudeControllerMalformedKnownBlockPayloadsRemainOrdinary() async {
        let start = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m","content":[]}}}"#
        for (type, field) in [("text", "text"), ("thinking", "thinking")] {
            for value in [nil, "null", "42"] as [String?] {
                let data = value.map { #", "\#(field)":\#($0)"# } ?? ""
                let block = #"{"type":"\#(type)"\#(data)}"#
                await assertClaudeControllerUndeclaredCompletion([
                    start, #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":\#(block)}}"#
                ], expectedTexts: ["[ack]"], expectsUncertainty: true)
                if type == "thinking" {
                    await assertClaudeControllerUndeclaredCompletion([
                        #"{"type":"assistant","message":{"id":"m","content":[\#(block)]}}"#
                    ], expectedTexts: ["[ack]"], expectsUncertainty: true)
                }
            }
        }
    }

    func testClaudeControllerWellFormedEmptyReasoningAndSameItemReplacementStayUndeclaredOrdinaryWithoutUncertainty() async {
        for content in [
            #"[{"type":"text","text":""}]"#,
            "[]",
            "\"\"",
            #""prose""#,
            #"[{"type":"thinking","thinking":"reasoning"}]"#,
            #"[{"type":"thinking","thinking":""}]"#
        ] {
            await assertClaudeControllerUndeclaredCompletion([
                #"{"type":"assistant","message":{"id":"m","content":\#(content)}}"#
            ], expectedTexts: ["[ack]"])
        }
        let start = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m","content":[]}}}"#
        for (type, field) in [("text_delta", "text"), ("thinking_delta", "thinking"), ("signature_delta", "signature")] {
            for value in ["", "ordinary streamed prefix"] {
                await assertClaudeControllerUndeclaredCompletion([
                    start, #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"\#(type)","\#(field)":"\#(value)"}}}"#
                ], expectedTexts: ["[ack]"])
            }
        }
        for (type, field) in [("text", "text"), ("thinking", "thinking")] {
            await assertClaudeControllerUndeclaredCompletion([
                start, #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"\#(type)","\#(field)":""}}}"#
            ], expectedTexts: ["[ack]"])
        }
    }

    func testClaudeConsumerBindingReplacementRejectsStaleSemanticAndTerminalWhileSameIDRemainsOrdinary() async throws {
        try await assertConsumerBindingReplacementSafety(claude: true)
    }

    func testACPConsumerBindingReplacementRejectsStaleSemanticAndTerminalWhileSameIDRemainsOrdinary() async throws {
        try await assertConsumerBindingReplacementSafety(claude: false)
    }

    private func assertConsumerBindingReplacementSafety(claude: Bool) async throws {
        for replacesBinding in [false, true] {
            let h = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, replayTranscript: true)
            // ACP's consumer is provider-neutral; use the same supported quiet-ledger fixture as
            // the existing ACP approval test. This does not enable shipped Devin quiet behavior.
            let s = h.makeSession(agent: claude ? .claudeCode : .codexExec)
            h.host.test_installLiveSession(s)
            let sessionID = UUID()
            let installed = try XCTUnwrap(h.host.test_installPersistentSessionBinding(sessionID: sessionID, on: s))
            let runID = UUID()
            s.installRunID(runID)
            s.runState = .running
            let owner = s.beginRunAttempt(source: "binding-consumer-control")
            s.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
            XCTAssertNotNil(s.quietLedger.candidateStartKey(owner: owner))
            let gate = QuietIngressGate()
            let base = try XCTUnwrap(h.hooks)
            var semanticIngressCount = 0
            let hooks = AgentModeRunService.Hooks(
                usage: base.usage, attachments: base.attachments, presentation: base.presentation,
                bindingObservation: base.bindingObservation, queuedWorkRecovery: base.queuedWorkRecovery,
                persistence: base.persistence,
                transcript: .init(
                    handleHeadlessStreamResult: { result, session, runID, attemptID in
                        if result.type == "usage" { await gate.pass() }
                        if result.type == "event" { semanticIngressCount += 1 }
                        await base.transcript.handleHeadlessStreamResult(result, session, runID, attemptID)
                    },
                    finalizeStreamingItems: base.transcript.finalizeStreamingItems,
                    finalizePendingToolCalls: base.transcript.finalizePendingToolCalls,
                    finalizePendingToolCallsWithUpperBound: base.transcript.finalizePendingToolCallsWithUpperBound,
                    flushPendingAssistantDelta: base.transcript.flushPendingAssistantDelta,
                    clearPendingAssistantDelta: base.transcript.clearPendingAssistantDelta
                ),
                providerInput: base.providerInput, interactions: base.interactions,
                terminalSettlement: base.terminalSettlement, continuation: base.continuation
            )
            let turnID = UUID()
            s.claudeExpectedTurnIDs.insert(turnID)
            let results = [AIStreamResult(type: "usage", text: nil), .init(type: "event", text: "semantic activity"), .init(type: "final_content", text: "[ack]", contentMessageID: "m")]
            let task = Task { @MainActor in
                if claude {
                    let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: h.host.claudeCoordinator, hooks: hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
                    return await runner.testConsumeQuietEvents(results.map(NativeAgentRuntimeEvent.stream) + [.turnCompleted(turnID: turnID, status: .completed)], session: s, runID: runID, owner: owner)
                }
                let runner = ACPIntegratedAgentModeRunner(
                    hooks: hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: .noOp,
                    providerFactory: { _, _ in nil }, controllerFactory: { provider, request in try ACPAgentSessionController(provider: provider, runRequest: request) }
                )
                await runner.testConsumeQuietEvents(results.map(NormalizedAgentRuntimeEvent.stream) + [.terminal(state: .completed, errorText: nil)], session: s, runID: runID, owner: owner)
                return false // ACP's existing test seam intentionally discards its outcome.
            }
            defer { gate.open()
                task.cancel()
            }
            await gate.waitUntilEntered()
            XCTAssertTrue(s.isCurrentRunAttemptForCurrentBinding(owner))
            XCTAssertNotNil(s.quietLedger.candidateStartKey(owner: owner), "Paused before semantic ingress")
            let replacement = try XCTUnwrap(h.host.test_installPersistentSessionBinding(sessionID: replacesBinding ? UUID() : sessionID, on: s))
            XCTAssertEqual(replacement == installed, !replacesBinding)
            XCTAssertEqual(s.isCurrentRunAttemptForCurrentBinding(owner), !replacesBinding)
            let replacementFacts = s.quietLedger.facts
            let replacementSequence = s.runLifecycle.liveness?.lastAcceptedSequence
            if replacesBinding { XCTAssertNil(s.quietRunFacts(capturedState: .running), "Retired owner is unknown, not freshly ordinary") }
            gate.open()
            let consumedNormalTerminal = await task.value
            if claude { XCTAssertEqual(consumedNormalTerminal, !replacesBinding) }
            XCTAssertEqual(semanticIngressCount, replacesBinding ? 0 : 1, "The real consumer rejects stale events before the semantic VM hook")
            XCTAssertEqual(s.items.filter { $0.kind == .assistant }.map(\.text), replacesBinding ? [] : ["[ack]"])
            if replacesBinding {
                XCTAssertEqual(s.runLifecycle.liveness?.lastAcceptedSequence, replacementSequence)
                let revision = await commit(h, s, owner)
                XCTAssertNil(revision, "Normal old terminal cannot seal under the replacement binding")
                XCTAssertEqual(s.quietLedger.facts, replacementFacts)
                XCTAssertTrue(s.quietLedger.hiddenSourceIDs.isEmpty)
                XCTAssertNil(s.quietRunFacts(capturedState: .running))
                XCTAssertTrue(s.endRunAttempt(ifCurrent: owner, source: "retired-binding-consumer-control"))
                XCTAssertEqual(s.quietLedger.facts, replacementFacts, "Old central end cannot advance replacement facts")
                XCTAssertTrue(s.quietLedger.hiddenSourceIDs.isEmpty)
            } else {
                XCTAssertNil(s.quietLedger.candidateStartKey(owner: owner), "Accepted semantic activity made the still-current owner ordinary")
                let revision = await commit(h, s, owner)
                XCTAssertNotNil(revision)
                XCTAssertEqual(s.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 1))
                XCTAssertTrue(s.quietLedger.hiddenSourceIDs.isEmpty)
            }
        }
    }

    @MainActor
    private final class QuietIngressGate {
        private var entered = false
        private var opened = false
        private var entryWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func pass() async {
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            if !opened { await withCheckedContinuation { releaseWaiter = $0 } }
        }

        func waitUntilEntered() async {
            if !entered { await withCheckedContinuation { entryWaiter = $0 } }
        }

        func open() {
            opened = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private func assertClaudeControllerUndeclaredCompletion(
        _ wire: [String],
        expectedTexts: [String],
        finalText: String? = "[ack]",
        finalResultValue: String? = nil,
        expectsUncertainty: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let (h, s, owner, runID) = fixture()
        XCTAssertNotNil(s.quietLedger.candidateStartKey(owner: owner), file: file, line: line)
        let controller = ClaudeNativeProcessSessionController(
            runID: runID, tabID: s.tabID, windowID: -1, workspacePath: nil,
            config: .agentMode(commandName: "/usr/bin/false")
        )
        await controller.test_installConfigurationTransport(write: { _ in })
        let stream = await controller.events
        let turnID = await controller.test_beginTurnTracking()
        s.claudeExpectedTurnIDs.insert(turnID)
        let result = finalResultValue.map { #"{"type":"result","subtype":"success","result":\#($0)}"# }
            ?? finalText.map { #"{"type":"result","subtype":"success","result":"\#($0)"}"# }
            ?? #"{"type":"result","subtype":"success"}"#
        for payload in [#"{"type":"system","subtype":"session_state_changed","session_state":"running"}"#]
            + wire + [result, #"{"type":"system","subtype":"session_state_changed","session_state":"idle"}"#]
        {
            await controller.test_receiveConfigurationResponseLine(Data(payload.utf8))
        }
        // A genuine result + idle completion must arrive before shutdown can recover anything.
        var iterator = stream.makeAsyncIterator()
        var events: [NativeAgentRuntimeEvent] = []
        while let event = await iterator.next() {
            events.append(event)
            if case .turnCompleted = event { break }
        }
        await controller.shutdown()
        while let event = await iterator.next() {
            events.append(event)
        }
        let completedTurnIDs = events.compactMap { event -> UUID? in
            if case let .turnCompleted(id, status) = event {
                XCTAssertEqual(status, .completed, file: file, line: line)
                return id
            }
            return nil
        }
        XCTAssertEqual(completedTurnIDs, [turnID], file: file, line: line)
        let streams = events.compactMap { event -> AIStreamResult? in
            if case let .stream(result) = event { return result }
            return nil
        }
        XCTAssertEqual(streams.filter { $0.type == "session_state_changed" }.compactMap(\.text), ["running", "idle"], file: file, line: line)
        XCTAssertFalse(streams.contains { $0.text == "Provider completion recovery" }, file: file, line: line)
        let uncertaintyIndex = streams.firstIndex { $0.type == "event" }
        XCTAssertEqual(streams.count { $0.type == "event" }, expectsUncertainty ? 1 : 0, "\(wire)", file: file, line: line)
        if let uncertaintyIndex, let finalIndex = streams.firstIndex(where: { $0.type == "final_content" }) {
            XCTAssertLessThan(uncertaintyIndex, finalIndex, file: file, line: line)
        }
        let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: h.host.claudeCoordinator, hooks: h.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
        let completed = await runner.testConsumeQuietEvents(events, session: s, runID: runID, owner: owner)
        XCTAssertTrue(completed, file: file, line: line)
        XCTAssertEqual(s.items.filter { $0.kind == .assistant }.map(\.text), expectedTexts, file: file, line: line)
        var notified = 0
        h.onTurnComplete = { notified += 1 }
        let revision = await commit(h, s, owner)
        XCTAssertNotNil(revision, file: file, line: line)
        XCTAssertEqual(notified, 1, file: file, line: line)
        XCTAssertNil(s.activeRunOwnership, file: file, line: line)
        h.host.refreshDerivedTranscriptState(for: s, publishActivePresentation: false)
        let projection = s.workingTranscriptProjection
        let presentation = AgentTranscriptPresentationSnapshot(
            revision: 1, visibleBlocks: projection.workingBlocks, workingBlocks: projection.workingBlocks,
            visibleRows: projection.workingRows, workingRows: projection.workingRows,
            rowAnchorIndex: projection.rowAnchorIndex, anchorBlockIndex: projection.anchorBlockIndex
        )
        let display = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation, archivedBlocks: s.archivedTranscriptSnapshot.blocks, hiddenSourceIDs: s.quietLedger.hiddenSourceIDs)
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1), "\(wire)", file: file, line: line)
        XCTAssertEqual(display.presentation.visibleRows.map(\.text), expectedTexts, "\(wire)", file: file, line: line)
        XCTAssertEqual(s.quietLedger.hiddenSourceIDs.isEmpty, true, file: file, line: line)
    }

    func testSemanticIngressBeforeSuppressionAndStaleCallbackCannotPoisonCurrentOwner() async {
        for type in ["tool_call", "tool_result", "tool_progress", "auth_status", "task_progress", "error", "system", "unclassified"] {
            let (h, s, owner, runID) = fixture()
            await h.host.test_handleStreamResult(.init(type: type, text: "semantic activity", toolName: "read_file"), session: s, runID: runID, runAttemptID: UUID())
            XCTAssertNotNil(s.quietLedger.candidateStartKey(owner: owner))
            await h.host.test_handleStreamResult(.init(type: type, text: "semantic activity", toolName: "read_file"), session: s, runID: runID, runAttemptID: owner.attemptID)
            XCTAssertNil(s.quietLedger.candidateStartKey(owner: owner), type)
            _ = await commit(h, s, owner)
            XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1)
        }
    }

    func testNaturalIngressDoesNotTraverseRangeUntilPositivelyRoutineTerminalCandidate() {
        var ledger = AgentRunQuietLedger()
        let owner = AgentRunOwnership(binding: AgentRunBindingIdentity(tabID: UUID(), persistentSessionID: nil))
        ledger.begin(owner: owner, startKey: 0, provider: .codexExec)
        var visits = 0
        let rows = (0 ..< 10000).lazy.map { index in
            visits += 1
            return AgentChatItem.thinking("thinking", sequenceIndex: index)
        }
        _ = ledger.settle(
            owner: owner,
            terminalState: .completed,
            classifiesQuietCheckIn: true,
            endKey: 9999,
            rangeIsComplete: true,
            rows: rows
        )
        XCTAssertEqual(visits, 0, "Unmarked natural attempt never traverses even a supplied lazy range")
    }
}

extension AgentQuietCheckInLifecycleTests {
    func testACPApprovalCancellationAndBothWaitingStatesKeepAcceptedInteraction() async {
        let (h, s, owner, runID) = fixture(.codexExec)
        let runner = ACPIntegratedAgentModeRunner(
            hooks: h.hooks,
            terminalCommitBarrier: AgentRunTerminalCommitBarrier(),
            toolTrackingHooks: .noOp,
            providerFactory: { _, _ in nil },
            controllerFactory: { provider, request in try ACPAgentSessionController(provider: provider, runRequest: request) }
        )
        let approval = AgentApprovalRequest(
            requestID: .acp("approval"),
            method: "session/request_permission",
            kind: .commandExecution,
            threadID: "current",
            turnID: "current",
            itemID: "tool"
        )
        await runner.testConsumeQuietEvents([.approvalRequested(approval), .approvalCancelled(approval.requestID)], session: s, runID: runID, owner: owner)
        XCTAssertNil(s.pendingApproval)
        XCTAssertNil(s.quietLedger.candidateStartKey(owner: owner), "Typed interaction survives cancellation without a tool row")
        XCTAssertTrue(s.items.isEmpty)
        _ = await commit(h, s, owner)
        XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1)
        for state in [AgentSessionRunState.waitingForApproval, .waitingForQuestion] {
            let (_, waiting, waitingOwner, _) = fixture()
            waiting.runState = state
            waiting.runState = .running
            XCTAssertNil(waiting.quietLedger.candidateStartKey(owner: waitingOwner))
        }
    }

    func testDevinRawUnknownPlanEchoAndControllerForeignLoadFencesRemainDisabledTogether() async throws {
        for providerID in [ACPProviderID.devin, .openCode] {
            for (method, update) in [
                ("session/update", [String: Any]()), ("session/update", ["sessionUpdate": 7]),
                ("session/update", ["sessionUpdate": "future_activity"]), ("session/update", ["sessionUpdate": "plan"]),
                ("session/update", ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "own or foreign fragment"]]),
                ("future/method", [:])
            ] {
                for variant in 0 ..< 4 {
                    let provider = AgentSessionLinkCapturingACPProvider(providerID: providerID, commandPath: "/usr/bin/false")
                    provider.usesDefaultNormalizer = true
                    let request = ACPRunRequest(
                        agentKind: providerID == .devin ? .devin : .openCode,
                        modelString: nil,
                        workspacePath: nil,
                        resumeSessionID: nil,
                        attachments: [],
                        taskLabelKind: nil
                    )
                    let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
                    let params: [String: Any] = variant == 3 ? ["sessionId": "current", "update": "malformed"]
                        : ["sessionId": variant == 1 ? "foreign" : "current", "update": update]
                    let events = await controller.test_replayQuietNotifications([(method, params)], sessionID: "current", loadReplay: variant == 2)
                    let expectedCount = providerID == .devin && variant != 1 && variant != 2 ? 1 : 0
                    XCTAssertEqual(events.count, expectedCount, "\(providerID) \(method) \(variant)")
                    let (h, s, owner, runID) = fixture(providerID == .devin ? .devin : .openCode)
                    let runner = ACPIntegratedAgentModeRunner(
                        hooks: h.hooks,
                        terminalCommitBarrier: AgentRunTerminalCommitBarrier(),
                        toolTrackingHooks: .noOp,
                        providerFactory: { _, _ in nil },
                        controllerFactory: { provider, request in try ACPAgentSessionController(provider: provider, runRequest: request) }
                    )
                    let sequenceBefore = s.runLifecycle.liveness?.lastAcceptedSequence ?? 0
                    await runner.testConsumeQuietEvents(events, session: s, runID: runID, owner: owner)
                    XCTAssertEqual(s.runLifecycle.liveness?.lastAcceptedSequence, sequenceBefore + 1 + UInt64(expectedCount))
                    XCTAssertTrue(s.items.isEmpty, "Uncertainty uses existing non-rendering stream, never a UI row")
                    _ = await commit(h, s, owner)
                    XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1)
                }
            }
        }
        XCTAssertFalse(AgentSessionLinkPrompts.supportsQuietCheckIn(.devin), "One shared predicate keeps future copy and classification disabled together")
    }
}

extension AgentQuietCheckInLifecycleTests {
    func testClaudeTranslatorAndNativeIngressPreserveUnknownOutputBeforeSuppression() async throws {
        let cases: [(String, String)] = [
            ("unknown-assistant-output", #"{"type":"assistant","message":{"id":"w0e-message","content":[{"type":"future_output","value":"opaque"}]}}"#),
            ("unknown-stream-output", #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"future_delta","value":"opaque"}}}"#),
            ("malformed-text-output", #"{"type":"assistant","message":{"id":"w0e-message","content":[{"type":"text","text":17}]}}"#),
            ("system-metadata", #"{"type":"system","subtype":"future_metadata","metadata":{"value":17}}"#)
        ]
        for (label, wire) in cases {
            let (h, s, owner, runID) = fixture()
            defer { s.saveDebounceTask?.cancel() }
            var translator = ClaudeSDKNDJSONTranslator()
            let normalized = translator.parseNDJSONLine(Data(wire.utf8))
            XCTAssertEqual(normalized.map(\.type), ["event"], label)
            XCTAssertNil(normalized.first?.text, "No new model-facing text: \(label)")
            guard let decoded = try ClaudeCompatiblePluginProtocolCodec.decodeLine(Data(wire.utf8)),
                  case let .streamPayload(payload) = decoded
            else {
                XCTFail("Expected the actual codec's stream payload: \(label)")
                continue
            }
            var providerTranslator = ClaudeCompatiblePluginNDJSONTranslator()
            let dtoResults = providerTranslator.parseStreamPayload(payload).map { ClaudeCompatibleProviderRuntimeBridge.streamResult(from: $0) }
            XCTAssertEqual(dtoResults.map(\.type), normalized.map(\.type), "Both entry points preserve the same negative evidence: \(label)")
            for result in normalized {
                await h.host.test_handleStreamResult(result, session: s, runID: runID, runAttemptID: owner.attemptID)
            }
            XCTAssertNil(s.quietLedger.candidateStartKey(owner: owner), "The semantic owner sees negative evidence without the native raw guard: \(label)")
            // Real native codec/controller emits negative evidence before the runner's VM hook.
            await assertClaudeControllerUndeclaredCompletion([wire], expectedTexts: [], finalText: nil, expectsUncertainty: true)
        }
    }
}
