import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class ContextBuilderRunLifecycleTests: XCTestCase {
    func testTerminalClaimAndContinuationAreExactlyOnce() async throws {
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let ownership = session.beginRunAttempt(source: "test")
        var capturedRecord: ContextBuilderRunRecord?

        let waiter = Task<ContextBuilderAgentViewModel.ContextBuilderRunSnapshot, Error> { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                capturedRecord = ContextBuilderRunRecord(
                    runID: UUID(),
                    tabID: tabID,
                    session: session,
                    ownership: ownership,
                    origin: .mcp(controlToken: UUID()),
                    agentKind: .claudeCode,
                    modelRaw: AgentModel.defaultModel.rawValue,
                    continuation: continuation
                )
            }
        }

        await Task.yield()
        let record = try XCTUnwrap(capturedRecord)
        XCTAssertTrue(record.claimTerminal(.completed))
        XCTAssertFalse(record.claimTerminal(.cancelled))

        let continuation = try XCTUnwrap(record.takeContinuation())
        XCTAssertNil(record.takeContinuation())
        continuation.resume(
            returning: ContextBuilderAgentViewModel.ContextBuilderRunSnapshot(
                runID: record.runID,
                tabID: tabID,
                finalState: nil,
                runState: .completed,
                agentOutput: "done",
                usedAgentOutputAsPrompt: false
            )
        )

        let snapshot = try await waiter.value
        XCTAssertEqual(snapshot.runID, record.runID)
        XCTAssertEqual(snapshot.agentOutput, "done")
    }

    func testLogicalReleaseAdmitsSuccessorAndRejectsOldEvents() {
        let registry = ContextBuilderRunRegistry()
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let firstOwnership = session.beginRunAttempt(source: "first")
        let first = makeRecord(tabID: tabID, session: session, ownership: firstOwnership)

        XCTAssertTrue(registry.register(first))
        XCTAssertTrue(registry.acceptsEvents(from: first, currentSession: session))
        let blocked = makeRecord(tabID: tabID, session: session, ownership: firstOwnership)
        XCTAssertFalse(registry.register(blocked))
        XCTAssertTrue(first.claimTerminal(.cancelled))
        XCTAssertTrue(registry.releaseActiveSlot(for: first))

        let secondOwnership = session.beginRunAttempt(source: "second")
        let second = makeRecord(tabID: tabID, session: session, ownership: secondOwnership)
        XCTAssertTrue(registry.register(second))
        XCTAssertFalse(registry.acceptsEvents(from: first, currentSession: session))
        XCTAssertTrue(registry.acceptsEvents(from: second, currentSession: session))
    }

    func testPendingTeardownDoesNotRetainActiveRunSlot() {
        let registry = ContextBuilderRunRegistry()
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let first = makeRecord(
            tabID: tabID,
            session: session,
            ownership: session.beginRunAttempt(source: "first")
        )
        let provider = LifecycleTestProvider()

        XCTAssertTrue(registry.register(first))
        XCTAssertTrue(first.installProvider(provider))
        XCTAssertTrue(first.claimTerminal(.cancelled))
        XCTAssertTrue(registry.releaseActiveSlot(for: first))

        let teardown = try? XCTUnwrap(first.beginTeardown())
        XCTAssertNotNil(teardown)
        XCTAssertTrue((teardown?.provider as AnyObject?) === provider)
        XCTAssertNil(first.beginTeardown())
        XCTAssertTrue(first.isTeardownPending)

        let second = makeRecord(
            tabID: tabID,
            session: session,
            ownership: session.beginRunAttempt(source: "second")
        )
        XCTAssertTrue(registry.register(second))

        first.markProviderDisposalFinished()
        XCTAssertTrue(first.isTeardownPending)
        first.markExecutionTaskFinished()
        XCTAssertFalse(first.isTeardownPending)
        XCTAssertTrue(registry.removeAfterTeardown(first))
        XCTAssertTrue(registry.acceptsEvents(from: second, currentSession: session))
    }

    func testProductionMCPCancellationResumesBeforeTeardownAndRejectsLateProviderEvent() async throws {
        let firstStreamStarted = expectation(description: "first provider stream started")
        let firstEventAccepted = expectation(description: "first provider event accepted")
        let firstDisposeStarted = expectation(description: "first provider disposal started")
        let firstDisposeFinished = expectation(description: "first provider disposal finished")
        let firstTeardownCompleted = expectation(description: "first run teardown completed")
        let successorStreamStarted = expectation(description: "successor provider stream started")
        let successorEventAccepted = expectation(description: "successor provider event accepted")
        let lateEventParked = expectation(description: "late provider event parked before processing")
        let lateEventRejected = expectation(description: "late provider event rejected")
        let firstProvider = ControllableLifecycleTestProvider(
            eventTexts: ["first-run-event", "late-old-run-event"],
            blocksDisposal: true,
            streamStartedExpectation: firstStreamStarted,
            disposeStartedExpectation: firstDisposeStarted,
            disposeFinishedExpectation: firstDisposeFinished
        )
        let successorProvider = ControllableLifecycleTestProvider(
            eventTexts: ["successor-event"],
            blocksDisposal: false,
            streamStartedExpectation: successorStreamStarted
        )
        let providers = LifecycleTestProviderQueue([firstProvider, successorProvider])
        let previousMCPEnabled = await ServerNetworkManager.shared.debugIsEnabledForBootstrapSocketURLOverride()

        let previousMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let composition = WindowStateCompositionFactory.make(
            windowID: -74,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            coreContainer: RepoPromptAppCoreContainer.shared,
            contextBuilderProviderFactory: { _, _, _ in providers.next() }
        )
        GlobalSettingsStore.shared.setMCPAutoStart(previousMCPAutoStart, commit: false)
        await composition.workspaceManager.awaitInitialized()

        do {
            let workspaceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ContextBuilderRunLifecycleTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: workspaceRoot,
                withIntermediateDirectories: true
            )
            defer {
                try? FileManager.default.removeItem(at: workspaceRoot)
            }

            let workspace = composition.workspaceManager.createWorkspace(
                name: "Context Builder lifecycle test",
                repoPaths: [workspaceRoot.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderRunLifecycleTests"
            )

            let activeWorkspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
            let tabID = try XCTUnwrap(
                activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id
            )
            let viewModel = composition.contextBuilderAgentViewModel
            let lateEventGate = LifecycleTestGate()
            let firstWaiterCompletion = LifecycleTestCounter()
            var firstRunID: UUID?

            viewModel.installRunTestHooks(
                ContextBuilderAgentViewModel.RunTestHooks(
                    beforeProcessingProviderEvent: { result, _ in
                        if result.text == "late-old-run-event" {
                            lateEventParked.fulfill()
                            await lateEventGate.arriveAndWait()
                        }
                    },
                    providerEventDisposition: { result, _, accepted in
                        switch (result.text, accepted) {
                        case ("first-run-event", true):
                            firstEventAccepted.fulfill()
                        case ("successor-event", true):
                            successorEventAccepted.fulfill()
                        case ("late-old-run-event", false):
                            lateEventRejected.fulfill()
                        default:
                            break
                        }
                    },
                    teardownCompleted: { runID in
                        if runID == firstRunID {
                            firstTeardownCompleted.fulfill()
                        }
                    }
                )
            )
            defer {
                viewModel.installRunTestHooks(nil)
                Task {
                    await lateEventGate.release()
                    await firstProvider.releaseDisposal()
                }
            }

            let firstToken = try viewModel.beginMCPControlledRun(
                forTabID: tabID,
                responseType: nil,
                planModelName: nil
            )
            let firstWaiterFinished = expectation(description: "first MCP waiter finished")
            let firstWaiter = Task<Bool, Never> { @MainActor in
                let wasCancelled: Bool
                do {
                    _ = try await viewModel.runContextBuilderForMCP(
                        tabID: tabID,
                        mcpControlToken: firstToken
                    )
                    wasCancelled = false
                } catch is CancellationError {
                    wasCancelled = true
                } catch {
                    XCTFail("Unexpected first-run error: \(error)")
                    wasCancelled = false
                }
                await firstWaiterCompletion.increment()
                firstWaiterFinished.fulfill()
                return wasCancelled
            }

            await fulfillment(
                of: [firstStreamStarted, firstEventAccepted, lateEventParked],
                timeout: 2
            )
            firstRunID = try XCTUnwrap(viewModel.activeRunIDForTesting(tabID: tabID))

            try await viewModel.cancelMCPContextBuilderRun(runID: XCTUnwrap(firstRunID))
            await fulfillment(of: [firstWaiterFinished, firstDisposeStarted], timeout: 1)

            let firstWaiterWasCancelled = await firstWaiter.value
            let firstCompletionCount = await firstWaiterCompletion.value()
            XCTAssertTrue(firstWaiterWasCancelled)
            XCTAssertEqual(firstCompletionCount, 1)
            XCTAssertNil(viewModel.activeRunIDForTesting(tabID: tabID))
            XCTAssertTrue(try viewModel.isRunTeardownPendingForTesting(runID: XCTUnwrap(firstRunID)))

            let successorToken = try viewModel.beginMCPControlledRun(
                forTabID: tabID,
                responseType: nil,
                planModelName: nil
            )
            let successorWaiterFinished = expectation(description: "successor MCP waiter finished")
            let successorWaiter = Task<Bool, Never> { @MainActor in
                let wasCancelled: Bool
                do {
                    _ = try await viewModel.runContextBuilderForMCP(
                        tabID: tabID,
                        mcpControlToken: successorToken
                    )
                    wasCancelled = false
                } catch is CancellationError {
                    wasCancelled = true
                } catch {
                    XCTFail("Unexpected successor error: \(error)")
                    wasCancelled = false
                }
                successorWaiterFinished.fulfill()
                return wasCancelled
            }

            await fulfillment(of: [successorStreamStarted, successorEventAccepted], timeout: 2)
            let successorRunID = try XCTUnwrap(viewModel.activeRunIDForTesting(tabID: tabID))
            XCTAssertNotEqual(successorRunID, firstRunID)
            XCTAssertTrue(try viewModel.isRunTeardownPendingForTesting(runID: XCTUnwrap(firstRunID)))
            let disposalFinishedBeforeLateEvent = await firstProvider.isDisposalFinished()
            XCTAssertFalse(disposalFinishedBeforeLateEvent)

            await lateEventGate.release()
            await fulfillment(of: [lateEventRejected], timeout: 1)

            let completionCountAfterLateEvent = await firstWaiterCompletion.value()
            XCTAssertEqual(completionCountAfterLateEvent, 1)
            XCTAssertFalse(viewModel.agentLog.contains { $0.message.contains("late-old-run-event") })
            XCTAssertTrue(viewModel.agentLog.contains { $0.message.contains("successor-event") })
            XCTAssertEqual(viewModel.activeRunIDForTesting(tabID: tabID), successorRunID)
            XCTAssertTrue(try viewModel.isRunTeardownPendingForTesting(runID: XCTUnwrap(firstRunID)))
            let disposalFinishedBeforeRelease = await firstProvider.isDisposalFinished()
            XCTAssertFalse(disposalFinishedBeforeRelease)

            await firstProvider.releaseDisposal()
            await fulfillment(of: [firstDisposeFinished, firstTeardownCompleted], timeout: 1)
            XCTAssertFalse(try viewModel.isRunTeardownPendingForTesting(runID: XCTUnwrap(firstRunID)))

            await viewModel.cancelMCPContextBuilderRun(runID: successorRunID)
            await fulfillment(of: [successorWaiterFinished], timeout: 1)
            let successorWasCancelled = await successorWaiter.value
            XCTAssertTrue(successorWasCancelled)

            await composition.mcpServer.stopServer()
            await composition.mcpServer.shutdownListener()
            await ServerNetworkManager.shared.setEnabled(previousMCPEnabled)
        } catch {
            await composition.mcpServer.stopServer()
            await composition.mcpServer.shutdownListener()
            await ServerNetworkManager.shared.setEnabled(previousMCPEnabled)
            throw error
        }
    }

    private func makeRecord(
        tabID: UUID,
        session: ContextBuilderAgentViewModel.TabSession,
        ownership: AgentRunOwnership
    ) -> ContextBuilderRunRecord {
        ContextBuilderRunRecord(
            runID: UUID(),
            tabID: tabID,
            session: session,
            ownership: ownership,
            origin: .ui,
            agentKind: .claudeCode,
            modelRaw: AgentModel.defaultModel.rawValue
        )
    }
}

private final class LifecycleTestProvider: HeadlessAgentProvider {
    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func dispose() async {}
}

private final class ControllableLifecycleTestProvider: HeadlessAgentProvider {
    private let eventTexts: [String]
    private let blocksDisposal: Bool
    private let streamStartedExpectation: XCTestExpectation?
    private let disposeStartedExpectation: XCTestExpectation?
    private let disposeFinishedExpectation: XCTestExpectation?
    private let disposeGate = LifecycleTestGate()
    private let state = LifecycleTestProviderState()
    private var streamContinuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation?

    init(
        eventTexts: [String],
        blocksDisposal: Bool,
        streamStartedExpectation: XCTestExpectation? = nil,
        disposeStartedExpectation: XCTestExpectation? = nil,
        disposeFinishedExpectation: XCTestExpectation? = nil
    ) {
        self.eventTexts = eventTexts
        self.blocksDisposal = blocksDisposal
        self.streamStartedExpectation = streamStartedExpectation
        self.disposeStartedExpectation = disposeStartedExpectation
        self.disposeFinishedExpectation = disposeFinishedExpectation
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        _ = message
        guard let runID else {
            throw CancellationError()
        }
        let stream = AsyncThrowingStream<AIStreamResult, Error> { continuation in
            streamContinuation = continuation
            for text in eventTexts {
                continuation.yield(AIStreamResult(type: "content", text: text))
            }
        }
        await MCPRoutingWaiter.notifyRouted(runID: runID)
        streamStartedExpectation?.fulfill()
        return stream
    }

    func dispose() async {
        await state.recordDisposeCall()
        disposeStartedExpectation?.fulfill()
        if blocksDisposal {
            await disposeGate.arriveAndWait()
        }
        streamContinuation?.finish()
        streamContinuation = nil
        await state.recordDisposalFinished()
        disposeFinishedExpectation?.fulfill()
    }

    func releaseDisposal() async {
        await disposeGate.release()
    }

    func disposeCallCount() async -> Int {
        await state.disposeCallCount
    }

    func isDisposalFinished() async -> Bool {
        await state.disposalFinished
    }
}

@MainActor
private final class LifecycleTestProviderQueue {
    private var providers: [HeadlessAgentProvider]

    init(_ providers: [HeadlessAgentProvider]) {
        self.providers = providers
    }

    func next() -> HeadlessAgentProvider {
        precondition(!providers.isEmpty, "Unexpected Context Builder provider request")
        return providers.removeFirst()
    }
}

private actor LifecycleTestProviderState {
    private(set) var disposeCallCount = 0
    private(set) var disposalFinished = false

    func recordDisposeCall() {
        disposeCallCount += 1
    }

    func recordDisposalFinished() {
        disposalFinished = true
    }
}

private actor LifecycleTestCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor LifecycleTestGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arrive() {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func arriveAndWait() async {
        arrive()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
