import Foundation
@testable import RepoPrompt
import XCTest

final class ContextBuilderMCPProgressTimelineTests: XCTestCase {
    func testPhaseCatalogCoversExpectedDiscoveryAndGenerationSequence() {
        XCTAssertEqual(ContextBuilderMCPProgressPhase.allCases, [
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
            Array(repeating: "discovering", count: 6) + Array(repeating: "generating", count: 7)
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

    func testSoftStageBoundEmitsOnceWithoutFailingTimeline() async {
        let clock = ContextBuilderProgressTestClock()
        let recorder = ContextBuilderProgressEventRecorder()
        let timeline = ContextBuilderMCPProgressTimeline(
            clock: { clock.now() },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            sink: { event in await recorder.record(event) }
        )

        await timeline.transition(to: .modelResolution)
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
                mode: .plan,
                prompt: "Summarize the selected context.",
                selection: StoredSelection(),
                progressReporter: { phase in
                    await recorder.record(phase)
                }
            )

            XCTAssertEqual(reply.mode, "plan")
            XCTAssertEqual(reply.response, "deterministic follow-up")
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
        #else
            throw XCTSkip("Provider-path Context Builder injection is DEBUG-only.")
        #endif
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
    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        _ = message
        let stream = AsyncThrowingStream<AIStreamResult, Error> { continuation in
            continuation.yield(AIStreamResult(type: "content", text: "Discovery complete"))
            continuation.finish()
        }
        if let runID {
            await MCPRoutingWaiter.notifyRouted(runID: runID)
        }
        return stream
    }

    func dispose() async {}
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
