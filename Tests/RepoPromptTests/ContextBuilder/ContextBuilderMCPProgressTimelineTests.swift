import Foundation
@testable import RepoPromptApp
import XCTest

final class ContextBuilderMCPProgressTimelineTests: XCTestCase {
    func testPhaseCatalogCoversExpectedDiscoveryAndGenerationSequence() {
        XCTAssertEqual(ContextBuilderMCPProgressPhase.allCases, [
            .providerProcessStarting,
            .waitingForChildConnection,
            .childConnectionObserved,
            .waitingForRouting,
            .routingConfirmed,
            .routingTimeoutBeforeConnection,
            .routingTimeoutAfterConnection,
            .readFileAutoSelectionFinish,
            .tabContextCommit,
            .statePersistence,
            .childConnectionTermination,
            .childConnectionTerminationJoin,
            .runFinalization,
            .modelResolution,
            .payloadPackaging,
            .sessionCreationAndPersist,
            .messageSend,
            .activeQueryAcquisition,
            .streaming,
            .messageFinalization
        ])
        XCTAssertEqual(
            ContextBuilderMCPProgressPhase.allCases.map(\.stage),
            Array(repeating: "discovering", count: 13) + Array(repeating: "generating", count: 7)
        )
    }

    func testTimelineEmitsTimedTransitionsAndUsesCurrentSubphaseForHeartbeat() async {
        let clock = ContextBuilderProgressTestClock()
        let recorder = ContextBuilderProgressEventRecorder()
        let timeline = ContextBuilderMCPProgressTimeline(
            clock: { clock.now() },
            sink: { event in await recorder.record(event) }
        )

        await timeline.transition(to: .modelResolution)
        clock.advance(by: 1.25)

        let heartbeat = await timeline.heartbeat(
            fallbackStage: "generating",
            fallbackMessage: "Still generating plan..."
        )
        XCTAssertEqual(heartbeat.stage, "generating")
        XCTAssertTrue(heartbeat.message.contains("follow-up model resolution"), heartbeat.message)
        XCTAssertTrue(heartbeat.message.contains("phase 1.250s"), heartbeat.message)

        await timeline.transition(to: .payloadPackaging)
        clock.advance(by: 0.5)
        await timeline.finishCurrentPhase()

        let events = await recorder.snapshot()
        XCTAssertEqual(events.map(\.kind), [.started, .completed, .started, .completed])
        XCTAssertEqual(events.map(\.phase), [
            .modelResolution,
            .modelResolution,
            .payloadPackaging,
            .payloadPackaging
        ])
        XCTAssertEqual(events.map(\.stage), ["generating", "generating", "generating", "generating"])
        XCTAssertEqual(events[1].phaseElapsed, 1.25, accuracy: 0.000_1)
        XCTAssertEqual(events[3].phaseElapsed, 0.5, accuracy: 0.000_1)
        XCTAssertTrue(events[1].message.contains("completed in 1.250s"), events[1].message)
        XCTAssertTrue(events[3].message.contains("total 1.750s"), events[3].message)
    }

    func testSuspendingSinkPreservesEveryTimedTransitionWhenItReentersTimeline() async {
        let clock = ContextBuilderProgressTestClock()
        let timelineReference = ContextBuilderProgressTimelineReference()
        let sink = ContextBuilderSuspendingProgressSink(
            suspendedKind: .completed,
            suspendedPhase: .modelResolution,
            reentrantAction: {
                clock.advance(by: 0.75)
                guard let timeline = timelineReference.timeline() else { return }
                await timeline.transition(to: .sessionCreationAndPersist)
            }
        )
        let timeline = ContextBuilderMCPProgressTimeline(
            clock: { clock.now() },
            sink: { event in await sink.receive(event) }
        )
        timelineReference.setTimeline(timeline)

        await timeline.transition(to: .modelResolution)
        clock.advance(by: 1.25)
        let payloadTransition = Task {
            await timeline.transition(to: .payloadPackaging)
        }
        await sink.waitUntilSuspended()

        let heartbeat = await timeline.heartbeat(
            fallbackStage: "generating",
            fallbackMessage: "fallback"
        )
        XCTAssertTrue(
            heartbeat.message.contains(ContextBuilderMCPProgressPhase.sessionCreationAndPersist.displayName),
            heartbeat.message
        )

        await sink.release()
        await payloadTransition.value
        await timeline.flush()

        let events = await sink.snapshot()
        XCTAssertEqual(events.map(\.kind), [
            .started,
            .completed,
            .started,
            .completed,
            .started
        ])
        XCTAssertEqual(events.map(\.phase), [
            .modelResolution,
            .modelResolution,
            .payloadPackaging,
            .payloadPackaging,
            .sessionCreationAndPersist
        ])
        XCTAssertEqual(events[1].phaseElapsed, 1.25, accuracy: 0.000_1)
        XCTAssertEqual(events[3].phaseElapsed, 0.75, accuracy: 0.000_1)
        for phase in [
            ContextBuilderMCPProgressPhase.modelResolution,
            .payloadPackaging
        ] {
            guard let startIndex = events.firstIndex(where: {
                $0.kind == .started && $0.phase == phase
            }),
                let completionIndex = events.firstIndex(where: {
                    $0.kind == .completed && $0.phase == phase
                })
            else {
                XCTFail("Missing start/completion pair for \(phase)")
                continue
            }
            XCTAssertLessThan(startIndex, completionIndex)
        }
    }

    func testSoftStageBoundEmitsOnceWithoutFailingTimeline() async throws {
        let clock = ContextBuilderProgressTestClock()
        let recorder = ContextBuilderProgressEventRecorder()
        let softBoundSleep = ContextBuilderSoftBoundSleepGate()
        let timeline = ContextBuilderMCPProgressTimeline(
            clock: { clock.now() },
            sleep: { seconds in try await softBoundSleep.sleep(seconds: seconds) },
            sink: { event in await recorder.record(event) }
        )

        await timeline.transition(to: .modelResolution)
        let scheduledSoftBound = try await softBoundSleep.waitUntilSleeping()
        XCTAssertEqual(scheduledSoftBound, 2, accuracy: 0.000_1)
        clock.advance(by: 2.5)
        await timeline.checkSoftBound()
        await timeline.checkSoftBound()
        await timeline.reportActivity(
            phase: .modelResolution,
            message: "Model registry lookup still running"
        )
        await timeline.finishCurrentPhase()

        let events = await recorder.snapshot()
        XCTAssertEqual(events.map(\.kind), [.started, .softBoundExceeded, .activity, .completed])
        XCTAssertEqual(events.count { $0.kind == .softBoundExceeded }, 1)
        XCTAssertTrue(events[1].message.contains("soft bound 2.000s"), events[1].message)
        XCTAssertEqual(events.last?.phaseElapsed ?? 0, 2.5, accuracy: 0.000_1)
        try await softBoundSleep.waitUntilCancelled()
    }

    @MainActor
    func testRunMCPPlanOrQuestionReportsProductionPhaseSequenceThroughFinalization() async throws {
        #if DEBUG
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let composition = WindowStateCompositionFactory.make(
                windowID: -76,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                aiQueriesServiceFactory: { keyManager in
                    AIQueriesService(
                        keyManager: keyManager,
                        sendPromptOverride: { _, _ in
                            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                                continuation.yield(ChatStreamOutput(
                                    text: "deterministic follow-up",
                                    reasoning: nil,
                                    tokens: ChatTokenInfo(),
                                    isFinal: true
                                ))
                                continuation.finish()
                            }
                            return (UUID(), stream)
                        }
                    )
                }
            )
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            await composition.workspaceManager.awaitInitialized()

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ContextBuilderMCPFollowUpTimelineTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let workspace = composition.workspaceManager.createWorkspace(
                name: "Context Builder follow-up timeline test",
                repoPaths: [root.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderMCPProgressTimelineTests.runMCPPlanOrQuestion"
            )
            let activeWorkspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
            let tabID = try XCTUnwrap(
                activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id
            )

            let agentModeSessionID = UUID()
            let agentModeRunID = UUID()
            let viewModel = composition.contextBuilderAgentViewModel
            viewModel.installRunTestHooks(
                ContextBuilderAgentViewModel.RunTestHooks(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    resolveMCPFollowUpModel: { _ in
                        (
                            model: .customProvider(
                                name: "Unconfigured test provider",
                                provider: "custom",
                                model: "unconfigured-test-model"
                            ),
                            chatPresetID: nil,
                            mcpControlInfo: nil
                        )
                    }
                )
            )
            defer { viewModel.installRunTestHooks(nil) }

            let recorder = ContextBuilderProgressPhaseRecorder()
            let reply = try await viewModel.runMCPPlanOrQuestion(
                for: tabID,
                oracleViewModel: composition.oracleViewModel,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID,
                mode: .plan,
                prompt: "Summarize the selected context.",
                selection: StoredSelection(),
                reviewGitContext: .automaticOnly(),
                progressReporter: { phase in
                    await recorder.record(phase)
                }
            )

            XCTAssertEqual(reply.mode, "plan")
            XCTAssertEqual(reply.response, "deterministic follow-up")
            let createdSession = try XCTUnwrap(
                composition.oracleViewModel.sessions.first(where: { $0.id == reply.chatId })
            )
            XCTAssertEqual(createdSession.agentModeSessionID, agentModeSessionID)
            XCTAssertEqual(createdSession.agentModeRunID, agentModeRunID)
            let phases = await recorder.snapshot()
            XCTAssertEqual(phases, [
                .modelResolution,
                .payloadPackaging,
                .sessionCreationAndPersist,
                .messageSend,
                .activeQueryAcquisition,
                .streaming,
                .messageFinalization
            ])
        #else
            throw XCTSkip("Production follow-up phase injection is DEBUG-only.")
        #endif
    }

    @MainActor
    func testContextBuilderToolProviderReportsDiscoveryAndGenerationStageEnvelope() async throws {
        #if DEBUG
            let provider = ContextBuilderImmediateCompletionProvider()
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState { _, _, _ in provider }
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            WindowStatesManager.shared.registerWindowState(window)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            await window.workspaceManager.awaitInitialized()

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ContextBuilderProviderTimelineTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let workspace = window.workspaceManager.createWorkspace(
                name: "Context Builder provider timeline test",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderMCPProgressTimelineTests.providerPath"
            )

            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            ContextBuilderTestReadinessSupport.seedCanonicalProviderReadiness(
                apiSettingsViewModel: window.apiSettingsViewModel,
                workspaceID: activeWorkspace.id
            )
            let tabID = try XCTUnwrap(
                activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id
            )
            var tab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
            tab.promptText = "Provider-path follow-up prompt"
            window.workspaceManager.updateComposeTab(tab, markDirty: false)
            window.promptManager.promptText = tab.promptText

            let stageRecorder = ContextBuilderProviderStageRecorder()
            window.mcpServer.installStageProgressSinkForTesting { _, tool, stage, message in
                guard tool == MCPWindowToolName.contextBuilder else { return }
                await stageRecorder.record(stage: stage, message: message)
            }
            defer { window.mcpServer.installStageProgressSinkForTesting(nil) }

            let followUpRecorder = ContextBuilderFollowUpInvocationRecorder()
            window.contextBuilderAgentViewModel.installRunTestHooks(
                ContextBuilderAgentViewModel.RunTestHooks(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    allowSyntheticRoutingWithoutFinalContext: true,
                    runMCPFollowUp: { mode, prompt, selection in
                        await followUpRecorder.record(
                            mode: mode,
                            prompt: prompt,
                            selection: selection
                        )
                        let chatID = UUID()
                        return ChatSendReply(
                            chatId: chatID,
                            shortId: String(chatID.uuidString.prefix(8)).lowercased(),
                            mode: mode.mcpModeName,
                            response: "deterministic provider follow-up",
                            errors: nil
                        )
                    }
                )
            )
            defer { window.contextBuilderAgentViewModel.installRunTestHooks(nil) }

            let tools = await window.mcpServer.windowMCPTools
            let contextBuilder = try XCTUnwrap(
                tools.first { $0.name == MCPWindowToolName.contextBuilder }
            )
            _ = try await contextBuilder([
                "instructions": .string("Inspect the test workspace."),
                "response_type": .string("plan"),
                "context_id": .string(tabID.uuidString)
            ])

            let recordedInvocation = await followUpRecorder.snapshot()
            let invocation = try XCTUnwrap(recordedInvocation)
            XCTAssertEqual(invocation.mode, .plan)
            XCTAssertEqual(invocation.prompt, "Provider-path follow-up prompt")
            XCTAssertTrue(invocation.selection.selectedPaths.isEmpty)

            let stages = await stageRecorder.snapshot()
            let envelopeStages = stages
                .map(\.stage)
                .filter { ["discovering", "discovered", "generating", "complete"].contains($0) }
                .reduce(into: [String]()) { collapsed, stage in
                    if collapsed.last != stage {
                        collapsed.append(stage)
                    }
                }
            XCTAssertEqual(envelopeStages, [
                "discovering",
                "discovered",
                "generating",
                "complete"
            ])
            let startupMessages = stages
                .filter { $0.stage == "discovering" }
                .map(\.message)
            let expectedStartupMarkers = [
                ContextBuilderMCPProgressPhase.providerProcessStarting.displayName,
                ContextBuilderMCPProgressPhase.waitingForChildConnection.displayName,
                ContextBuilderMCPProgressPhase.childConnectionObserved.displayName,
                ContextBuilderMCPProgressPhase.waitingForRouting.displayName,
                ContextBuilderMCPProgressPhase.routingConfirmed.displayName
            ]
            let startupIndexes = try expectedStartupMarkers.map { marker in
                try XCTUnwrap(
                    startupMessages.firstIndex { $0.contains("\(marker) started") },
                    "Missing production-lineage startup phase: \(marker)"
                )
            }
            XCTAssertEqual(startupIndexes, startupIndexes.sorted())
        #else
            throw XCTSkip("Provider-path Context Builder injection is DEBUG-only.")
        #endif
    }

    @MainActor
    func testContextBuilderToolProviderUsesCallerPromptWithoutMutatingDiscoveryFallback() async throws {
        #if DEBUG
            let discoveryInputRecorder = ContextBuilderDiscoveryInputRecorder()
            let provider = ContextBuilderImmediateCompletionProvider(
                discoveryInputRecorder: discoveryInputRecorder
            )
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState { _, _, _ in provider }
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            WindowStatesManager.shared.registerWindowState(window)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            await window.workspaceManager.awaitInitialized()

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ContextBuilderProviderPromptTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let workspace = window.workspaceManager.createWorkspace(
                name: "Context Builder provider prompt test",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderMCPProgressTimelineTests.providerPrompt"
            )

            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            ContextBuilderTestReadinessSupport.seedCanonicalProviderReadiness(
                apiSettingsViewModel: window.apiSettingsViewModel,
                workspaceID: activeWorkspace.id
            )
            let tabID = try XCTUnwrap(
                activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id
            )
            let tabIdentity = WorkspaceSelectionIdentity(
                workspaceID: activeWorkspace.id,
                tabID: tabID
            )
            var initialTab = try XCTUnwrap(window.workspaceManager.composeTab(for: tabIdentity))
            initialTab.promptText = ""
            window.workspaceManager.updateComposeTab(initialTab, markDirty: false)
            window.promptManager.promptText = ""
            XCTAssertTrue(initialTab.promptText.isEmpty)

            let stageRecorder = ContextBuilderProviderStageRecorder()
            window.mcpServer.installStageProgressSinkForTesting { _, tool, stage, message in
                guard tool == MCPWindowToolName.contextBuilder else { return }
                await stageRecorder.record(stage: stage, message: message)
            }
            defer { window.mcpServer.installStageProgressSinkForTesting(nil) }

            let followUpRecorder = ContextBuilderFollowUpInvocationRecorder()
            let committedSnapshotRecorder = ContextBuilderCommittedSnapshotRecorder()
            window.contextBuilderAgentViewModel.installRunTestHooks(
                ContextBuilderAgentViewModel.RunTestHooks(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    allowSyntheticRoutingWithoutFinalContext: true,
                    runMCPFollowUp: { mode, prompt, selection in
                        await followUpRecorder.record(
                            mode: mode,
                            prompt: prompt,
                            selection: selection
                        )
                        let chatID = UUID()
                        return ChatSendReply(
                            chatId: chatID,
                            shortId: String(chatID.uuidString.prefix(8)).lowercased(),
                            mode: mode.mcpModeName,
                            response: "deterministic provider follow-up",
                            errors: nil
                        )
                    },
                    committedTabSnapshotCaptured: { runID, snapshot in
                        committedSnapshotRecorder.record(runID: runID, snapshot: snapshot)
                    }
                )
            )
            defer { window.contextBuilderAgentViewModel.installRunTestHooks(nil) }

            let task = "<task>Inspect request-local prompt.</task>"
            let context = "<context>Keep caller context.</context>"
            let discoverySentinel = "DISCOVERY_ONLY_SENTINEL"
            let instructions = """
            \(task)
            \(context)
            <discovery_agent-guidelines>\(discoverySentinel)</discovery_agent-guidelines>
            """
            let expectedPrompt = """
            \(task)
            \(context)
            """

            let tools = await window.mcpServer.windowMCPTools
            let contextBuilder = try XCTUnwrap(
                tools.first { $0.name == MCPWindowToolName.contextBuilder }
            )
            let result = try await {
                do {
                    return try await contextBuilder([
                        "instructions": .string(instructions),
                        "response_type": .string("plan"),
                        "context_id": .string(tabID.uuidString)
                    ])
                } catch {
                    let stages = await stageRecorder.snapshot().map(\.stage)
                    XCTFail("Context Builder failed after stages \(stages): \(error)")
                    throw error
                }
            }()

            let discoveryInputs = await discoveryInputRecorder.snapshot()
            let discoveryInput = try XCTUnwrap(discoveryInputs.last)
            XCTAssertTrue(discoveryInput.contains(instructions))

            let recordedInvocation = await followUpRecorder.snapshot()
            let invocation = try XCTUnwrap(recordedInvocation)
            XCTAssertEqual(invocation.mode, .plan)
            XCTAssertEqual(invocation.prompt, expectedPrompt)

            guard case let .object(resultObject) = result else {
                return XCTFail("Expected Context Builder object result")
            }
            XCTAssertEqual(resultObject["prompt"]?.stringValue, expectedPrompt)

            // The MCP path's authoritative promptText contract is the immutable committed provider
            // snapshot, which the tool provider itself consumes as `resultTab`. The live compose tab
            // is only a non-authoritative active-tab UI projection here: it can be overwritten by an
            // empty prompt-editor snapshot after the silent stored-only commit, so reading it back is
            // racy. Assert the committed provenance captured at the commit seam instead.
            let committedCaptures = committedSnapshotRecorder.snapshotAll()
            XCTAssertEqual(
                committedCaptures.count,
                1,
                "Exactly one committed tab snapshot should be retained for the run"
            )
            let committed = try XCTUnwrap(committedCaptures.first)
            XCTAssertEqual(committed.runID, committed.snapshot.nestedRunID)
            XCTAssertEqual(committed.snapshot.identity, tabIdentity)
            XCTAssertEqual(committed.snapshot.tab.id, tabID)
            XCTAssertEqual(committed.snapshot.tab.promptText, "Discovery complete")
            XCTAssertTrue(committed.snapshot.usedAgentOutputAsPrompt)
        #else
            throw XCTSkip("Provider-path Context Builder injection is DEBUG-only.")
        #endif
    }

    func testTypedPromptResolverEnforcesPrecedenceAndReservedMarkupGrammar() {
        struct Case {
            let name: String
            let effectivePrompt: String
            let usedAgentOutputAsPrompt: Bool
            let callerInstructions: String
            let expected: ContextBuilderTypedPromptResolution
        }

        let cases = [
            Case(
                name: "committed prompt wins without parsing malformed unused instructions",
                effectivePrompt: "Committed prompt",
                usedAgentOutputAsPrompt: false,
                callerInstructions: "<DISCOVERY_AGENT-GUIDELINES>unused",
                expected: .resolved("Committed prompt")
            ),
            Case(
                name: "plain caller instructions",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: "<task>Caller task</task>",
                expected: .resolved("<task>Caller task</task>")
            ),
            Case(
                name: "exact lowercase block removed",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: """
                <task>Caller task</task>
                <discovery_agent-guidelines>hidden</discovery_agent-guidelines>
                <context>Caller context</context>
                """,
                expected: .resolved("""
                <task>Caller task</task>

                <context>Caller context</context>
                """)
            ),
            Case(
                name: "repeated sibling blocks removed",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: """
                <discovery_agent-guidelines>first</discovery_agent-guidelines>
                <task>Caller task</task>
                <discovery_agent-guidelines>second</discovery_agent-guidelines>
                """,
                expected: .resolved("<task>Caller task</task>")
            ),
            Case(
                name: "blank caller instructions",
                effectivePrompt: "",
                usedAgentOutputAsPrompt: false,
                callerInstructions: "  \n",
                expected: .missingCallerTask
            ),
            Case(
                name: "guidelines only",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: "<discovery_agent-guidelines>hidden</discovery_agent-guidelines>",
                expected: .discoveryGuidelinesOnly
            ),
            Case(
                name: "unmatched opening tag",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: "<task>Caller task</task><discovery_agent-guidelines>hidden",
                expected: .malformedDiscoveryMarkup
            ),
            Case(
                name: "unmatched closing tag",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: "<task>Caller task</task></discovery_agent-guidelines>",
                expected: .malformedDiscoveryMarkup
            ),
            Case(
                name: "nested blocks",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: "<discovery_agent-guidelines>outer<discovery_agent-guidelines>inner</discovery_agent-guidelines></discovery_agent-guidelines>",
                expected: .malformedDiscoveryMarkup
            ),
            Case(
                name: "case variant",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: "<DISCOVERY_AGENT-GUIDELINES>hidden</DISCOVERY_AGENT-GUIDELINES>",
                expected: .malformedDiscoveryMarkup
            ),
            Case(
                name: "attribute variant",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: "<discovery_agent-guidelines scope=\"narrow\">hidden</discovery_agent-guidelines>",
                expected: .malformedDiscoveryMarkup
            ),
            Case(
                name: "self-closing variant",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: "<task>Caller task</task><discovery_agent-guidelines/>",
                expected: .malformedDiscoveryMarkup
            ),
            Case(
                name: "quoted greater-than before reserved attribute text",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: "<task note=\">discovery_agent-guidelines: SECRET\">Caller task</task>",
                expected: .malformedDiscoveryMarkup
            ),
            Case(
                name: "exact guideline pair embedded in attribute",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: "<task note=\"<discovery_agent-guidelines>hidden</discovery_agent-guidelines>\">Caller task</task>",
                expected: .malformedDiscoveryMarkup
            ),
            Case(
                name: "reserved name in ordinary prose",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: "Explain discovery_agent-guidelines behavior.",
                expected: .resolved("Explain discovery_agent-guidelines behavior.")
            ),
            Case(
                name: "empty committed prompt falls back to caller instructions",
                effectivePrompt: "",
                usedAgentOutputAsPrompt: false,
                callerInstructions: "<task>Caller task</task>",
                expected: .resolved("<task>Caller task</task>")
            ),
            Case(
                name: "copied discovery output without independent caller prompt",
                effectivePrompt: "Discovery output",
                usedAgentOutputAsPrompt: true,
                callerInstructions: "",
                expected: .onlyCopiedDiscoveryOutput
            )
        ]

        for testCase in cases {
            XCTAssertEqual(
                ContextBuilderTypedPromptResolver.resolve(
                    effectivePrompt: testCase.effectivePrompt,
                    usedAgentOutputAsPrompt: testCase.usedAgentOutputAsPrompt,
                    callerInstructions: testCase.callerInstructions
                ),
                testCase.expected,
                testCase.name
            )
        }

        let disposition = MCPContextBuilderToolProvider.responseDisposition(
            responseType: .plan,
            terminalDisposition: .completed,
            usedAgentOutputAsPrompt: true,
            effectivePrompt: "Discovery output",
            callerInstructions: "<task>Shared caller task</task>"
        )
        guard case let .generate(mode, prompt) = disposition else {
            return XCTFail("Expected plan to generate from caller authority")
        }
        XCTAssertEqual(mode, .plan)
        XCTAssertEqual(prompt, "<task>Shared caller task</task>")
    }

    func testResponseDispositionRoutesRequestedModesAndFailsClosedOnMissingFollowUpState() {
        func assertGenerates(
            _ responseType: ContextBuilderResponseType,
            expectedMode: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let disposition = MCPContextBuilderToolProvider.responseDisposition(
                responseType: responseType,
                terminalDisposition: .completed,
                usedAgentOutputAsPrompt: false,
                effectivePrompt: "Committed prompt",
                callerInstructions: ""
            )
            guard case let .generate(mode, prompt) = disposition else {
                return XCTFail("Expected generate for \(responseType.rawValue)", file: file, line: line)
            }
            XCTAssertEqual(mode.mcpModeName, expectedMode, file: file, line: line)
            XCTAssertEqual(prompt, "Committed prompt", file: file, line: line)
        }

        assertGenerates(.plan, expectedMode: "plan")
        assertGenerates(.review, expectedMode: "review")
        assertGenerates(.question, expectedMode: "chat")

        for responseType in [ContextBuilderResponseType?.none, .some(.clarify)] {
            guard case .contextOnly = MCPContextBuilderToolProvider.responseDisposition(
                responseType: responseType,
                terminalDisposition: .completed,
                usedAgentOutputAsPrompt: false,
                effectivePrompt: "Committed prompt",
                callerInstructions: "<DISCOVERY_AGENT-GUIDELINES>unused"
            ) else {
                return XCTFail("Context-only response type must not generate a follow-up")
            }
        }

        for terminalDisposition in [
            ContextBuilderRunTerminalOutcome.cancelled,
            .failed("discovery failed")
        ] {
            guard case .contextOnly = MCPContextBuilderToolProvider.responseDisposition(
                responseType: .plan,
                terminalDisposition: terminalDisposition,
                usedAgentOutputAsPrompt: false,
                effectivePrompt: "Committed prompt",
                callerInstructions: "<DISCOVERY_AGENT-GUIDELINES>unused"
            ) else {
                return XCTFail("Failed or cancelled discovery must preserve its terminal result")
            }
        }

        // Each completed-run failure surfaces the stable "without a prompt" stem plus a distinct, safe reason
        // that never echoes the withheld caller instructions or discovery-guideline content.
        guard case let .failed(guidelinesOnlyError) = MCPContextBuilderToolProvider.responseDisposition(
            responseType: .plan,
            terminalDisposition: .completed,
            usedAgentOutputAsPrompt: true,
            effectivePrompt: "Agent output",
            callerInstructions: "<discovery_agent-guidelines>hidden</discovery_agent-guidelines>"
        ) else {
            return XCTFail("Discovery output must not silently satisfy a requested response")
        }
        XCTAssertTrue(guidelinesOnlyError.contains("without a prompt"))
        XCTAssertTrue(guidelinesOnlyError.contains("only discovery guidelines"))
        XCTAssertFalse(guidelinesOnlyError.contains("hidden"))

        guard case let .failed(missingCallerTaskError) = MCPContextBuilderToolProvider.responseDisposition(
            responseType: .review,
            terminalDisposition: .completed,
            usedAgentOutputAsPrompt: false,
            effectivePrompt: "  \n",
            callerInstructions: ""
        ) else {
            return XCTFail("Empty committed prompt must fail a requested response")
        }
        XCTAssertTrue(missingCallerTaskError.contains("without a prompt"))
        XCTAssertTrue(missingCallerTaskError.contains("no caller task or context"))

        guard case let .failed(copiedDiscoveryError) = MCPContextBuilderToolProvider.responseDisposition(
            responseType: .plan,
            terminalDisposition: .completed,
            usedAgentOutputAsPrompt: true,
            effectivePrompt: "Agent output",
            callerInstructions: ""
        ) else {
            return XCTFail("Copied discovery output without a caller task must fail a requested response")
        }
        XCTAssertTrue(copiedDiscoveryError.contains("without a prompt"))
        XCTAssertTrue(copiedDiscoveryError.contains("only copied discovery output"))

        guard case let .failed(malformedMarkupError) = MCPContextBuilderToolProvider.responseDisposition(
            responseType: .question,
            terminalDisposition: .completed,
            usedAgentOutputAsPrompt: true,
            effectivePrompt: "Agent output",
            callerInstructions: "<task>Caller task</task><discovery_agent-guidelines>hidden"
        ) else {
            return XCTFail("Malformed reserved markup must fail closed for a requested response")
        }
        XCTAssertTrue(malformedMarkupError.contains("without a prompt"))
        XCTAssertTrue(malformedMarkupError.contains("malformed discovery-guideline markup"))
        XCTAssertFalse(malformedMarkupError.contains("hidden"))
    }

    @MainActor
    func testCommitAndClearTabContextReportsPersistenceSubphasesInOrder() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        WindowStatesManager.shared.registerWindowState(window)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderMCPProgressTimelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = window.workspaceManager.createWorkspace(
            name: "Context Builder progress test",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "ContextBuilderMCPProgressTimelineTests"
        )

        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(
            activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id
        )
        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "context-builder-progress-test",
            tabID: tabID,
            workspaceID: activeWorkspace.id,
            windowID: window.windowID
        )

        let recorder = ContextBuilderProgressPhaseRecorder()
        await window.mcpServer.commitAndClearTabContext(
            connectionID: connectionID,
            progressReporter: { phase in
                await recorder.record(phase)
            }
        )

        let phases = await recorder.snapshot()
        XCTAssertEqual(phases, [
            .readFileAutoSelectionFinish,
            .tabContextCommit,
            .statePersistence
        ])
    }

    @MainActor
    func testDeferredRunMappingSurvivesCommitUntilCallerCleanup() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        WindowStatesManager.shared.registerWindowState(window)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderDeferredMappingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = window.workspaceManager.createWorkspace(
            name: "Context Builder deferred mapping test",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "ContextBuilderMCPProgressTimelineTests.deferredMapping"
        )

        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(
            activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id
        )
        let connectionID = UUID()
        let runID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "context-builder-deferred-mapping-test",
            tabID: tabID,
            workspaceID: activeWorkspace.id,
            windowID: window.windowID,
            runID: runID
        )
        XCTAssertTrue(window.mcpServer.hasRunID(runID))

        await window.mcpServer.commitAndClearTabContext(
            connectionID: connectionID,
            expectedRunID: runID,
            deferRunMappingCleanupUntilCaller: true
        )
        XCTAssertTrue(window.mcpServer.hasRunID(runID))

        window.mcpServer.removeTabContext(
            forConnectionID: connectionID,
            clientName: "context-builder-deferred-mapping-test",
            windowID: window.windowID,
            runID: runID
        )
        XCTAssertFalse(window.mcpServer.hasRunID(runID))
    }
}

private final class ContextBuilderImmediateCompletionProvider: HeadlessAgentProvider {
    private let discoveryInputRecorder: ContextBuilderDiscoveryInputRecorder?

    init(discoveryInputRecorder: ContextBuilderDiscoveryInputRecorder? = nil) {
        self.discoveryInputRecorder = discoveryInputRecorder
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        await discoveryInputRecorder?.record(message.userMessage)
        let stream = AsyncThrowingStream<AIStreamResult, Error> { continuation in
            continuation.yield(AIStreamResult(type: "content", text: "Discovery complete"))
            continuation.finish()
        }
        if let runID {
            await MCPRoutingWaiter.notifyConnectionObserved(runID: runID)
            await MCPRoutingWaiter.notifyRouted(runID: runID)
        }
        return stream
    }

    func dispose() async {}
}

private actor ContextBuilderDiscoveryInputRecorder {
    private var inputs: [String] = []

    func record(_ input: String) {
        inputs.append(input)
    }

    func snapshot() -> [String] {
        inputs
    }
}

private actor ContextBuilderProviderStageRecorder {
    struct Entry {
        let stage: String
        let message: String
    }

    private var entries: [Entry] = []

    func record(stage: String, message: String) {
        entries.append(Entry(stage: stage, message: message))
    }

    func snapshot() -> [Entry] {
        entries
    }
}

private actor ContextBuilderFollowUpInvocationRecorder {
    struct Invocation {
        let mode: HeadlessMode
        let prompt: String
        let selection: StoredSelection
    }

    private var invocation: Invocation?

    func record(mode: HeadlessMode, prompt: String, selection: StoredSelection) {
        invocation = Invocation(mode: mode, prompt: prompt, selection: selection)
    }

    func snapshot() -> Invocation? {
        invocation
    }
}

private final class ContextBuilderCommittedSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [(runID: UUID, snapshot: MCPServerViewModel.ContextBuilderCommittedTabSnapshot)] = []

    func record(runID: UUID, snapshot: MCPServerViewModel.ContextBuilderCommittedTabSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        captures.append((runID: runID, snapshot: snapshot))
    }

    func snapshotAll() -> [(runID: UUID, snapshot: MCPServerViewModel.ContextBuilderCommittedTabSnapshot)] {
        lock.lock()
        defer { lock.unlock() }
        return captures
    }
}

private final class ContextBuilderProgressTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value += interval
        lock.unlock()
    }
}

private actor ContextBuilderSuspendingProgressSink {
    private let suspendedKind: ContextBuilderMCPProgressEvent.Kind
    private let suspendedPhase: ContextBuilderMCPProgressPhase
    private let reentrantAction: (@Sendable () async -> Void)?
    private var events: [ContextBuilderMCPProgressEvent] = []
    private var isSuspending = false
    private var didSuspend = false
    private var isReleased = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        suspendedKind: ContextBuilderMCPProgressEvent.Kind,
        suspendedPhase: ContextBuilderMCPProgressPhase,
        reentrantAction: (@Sendable () async -> Void)? = nil
    ) {
        self.suspendedKind = suspendedKind
        self.suspendedPhase = suspendedPhase
        self.reentrantAction = reentrantAction
    }

    func receive(_ event: ContextBuilderMCPProgressEvent) async {
        events.append(event)
        guard !isSuspending,
              !didSuspend,
              event.kind == suspendedKind,
              event.phase == suspendedPhase
        else {
            return
        }

        isSuspending = true
        await reentrantAction?()
        didSuspend = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        guard !didSuspend else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func snapshot() -> [ContextBuilderMCPProgressEvent] {
        events
    }
}

private final class ContextBuilderProgressTimelineReference: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTimeline: ContextBuilderMCPProgressTimeline?

    func setTimeline(_ timeline: ContextBuilderMCPProgressTimeline) {
        lock.lock()
        storedTimeline = timeline
        lock.unlock()
    }

    func timeline() -> ContextBuilderMCPProgressTimeline? {
        lock.lock()
        defer { lock.unlock() }
        return storedTimeline
    }
}

/// Soft-bound sleep gate: lock-backed sticky cancel (no `Task { await }` hop).
private final class ContextBuilderSoftBoundSleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepingSeconds: TimeInterval?
    private var cancelled = false
    private var sleepWaitTerminalError: Error?
    private var sleepContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledSleepWaiters = Set<UUID>()
    private var sleepingWaiters: [CheckedContinuation<TimeInterval, Error>] = []

    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var result: Result<Void, Error>?
                lock.lock()
                if cancelled || Task.isCancelled || cancelledSleepWaiters.remove(waiterID) != nil {
                    result = .failure(CancellationError())
                } else {
                    if sleepingSeconds == nil {
                        sleepingSeconds = seconds
                    }
                    sleepContinuations[waiterID] = continuation
                    let waiters = sleepingWaiters
                    sleepingWaiters.removeAll()
                    lock.unlock()
                    waiters.forEach { $0.resume(returning: seconds) }
                    return
                }
                lock.unlock()
                if case let .failure(error) = result {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancelSleep(waiterID: waiterID)
        }
    }

    func waitUntilSleeping(timeout: TimeInterval = TestFenceDefaults.enterWait) async throws -> TimeInterval {
        if let seconds = peekSleepingSeconds { return seconds }
        if isCancelled { throw CancellationError() }
        if let terminal = terminalError { throw terminal }

        let timeoutError = AsyncTestConditionTimeout(
            description: "context builder soft-bound sleep gate",
            timeout: timeout
        )
        return try await withThrowingTaskGroup(of: TimeInterval.self) { group in
            group.addTask {
                try await self.waitForSleepSignal()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64((timeout * 1_000_000_000).rounded()))
                self.closeSleepWait(with: timeoutError)
                throw timeoutError
            }
            defer { group.cancelAll() }
            do {
                if let value = try await group.next() {
                    return value
                }
            } catch {
                if let seconds = self.peekSleepingSeconds {
                    return seconds
                }
                throw error
            }
            if let seconds = peekSleepingSeconds {
                return seconds
            }
            throw timeoutError
        }
    }

    func waitUntilCancelled(timeout: TimeInterval = TestFenceDefaults.enterWait) async throws {
        if isCancelled { return }
        try await AsyncTestWait.waitUntil(
            "context builder soft-bound cancellation",
            timeout: timeout
        ) {
            self.isCancelled
        }
    }

    private var peekSleepingSeconds: TimeInterval? {
        lock.withLock { sleepingSeconds }
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    private var terminalError: Error? {
        lock.withLock { sleepWaitTerminalError }
    }

    private func waitForSleepSignal() async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let sleepingSeconds {
                lock.unlock()
                continuation.resume(returning: sleepingSeconds)
                return
            }
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            if let sleepWaitTerminalError {
                lock.unlock()
                continuation.resume(throwing: sleepWaitTerminalError)
                return
            }
            sleepingWaiters.append(continuation)
            lock.unlock()
        }
    }

    private func closeSleepWait(with error: Error) {
        lock.lock()
        if sleepWaitTerminalError == nil {
            sleepWaitTerminalError = error
        }
        let waiters = sleepingWaiters
        sleepingWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func cancelSleep(waiterID: UUID) {
        lock.lock()
        cancelled = true
        let pending = Array(sleepContinuations.values)
        let hadRegisteredWaiter = sleepContinuations.removeValue(forKey: waiterID) != nil
        sleepContinuations.removeAll()
        if !hadRegisteredWaiter {
            cancelledSleepWaiters.insert(waiterID)
        }
        if sleepWaitTerminalError == nil {
            sleepWaitTerminalError = CancellationError()
        }
        let waiters = sleepingWaiters
        sleepingWaiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(throwing: CancellationError()) }
        waiters.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private actor ContextBuilderProgressEventRecorder {
    private var events: [ContextBuilderMCPProgressEvent] = []

    func record(_ event: ContextBuilderMCPProgressEvent) {
        events.append(event)
    }

    func snapshot() -> [ContextBuilderMCPProgressEvent] {
        events
    }
}

private actor ContextBuilderProgressPhaseRecorder {
    private var phases: [ContextBuilderMCPProgressPhase] = []

    func record(_ phase: ContextBuilderMCPProgressPhase) {
        phases.append(phase)
    }

    func snapshot() -> [ContextBuilderMCPProgressPhase] {
        phases
    }
}
