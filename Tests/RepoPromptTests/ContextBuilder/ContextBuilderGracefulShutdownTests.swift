import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ContextBuilderGracefulShutdownTests: XCTestCase {
    func testRetainedSnapshotIncludesEveryRegistryOwnedLifecycleState() {
        let registry = ContextBuilderRunRegistry()
        let active = makeRecord()
        let terminal = makeRecord()
        let activeSlotReleased = makeRecord()
        let teardownStarted = makeRecord()

        for record in [active, terminal, activeSlotReleased, teardownStarted] {
            XCTAssertTrue(registry.register(record))
        }
        XCTAssertTrue(terminal.claimTerminal(.completed))
        XCTAssertTrue(registry.releaseActiveSlot(for: activeSlotReleased))
        XCTAssertNotNil(teardownStarted.beginTeardown())

        let snapshot = registry.retainedRecordsSnapshot()

        XCTAssertEqual(Set(snapshot.map(\.runID)), Set([
            active.runID,
            terminal.runID,
            activeSlotReleased.runID,
            teardownStarted.runID
        ]))
    }

    func testTeardownSettlementSupportsConcurrentAndLateWaitersExactlyOnce() async {
        let record = makeRecord()
        XCTAssertNotNil(record.beginTeardown())
        let first = Task { await record.awaitTeardownSettlement() }
        let second = Task { await record.awaitTeardownSettlement() }

        record.markProviderDisposalFinished()
        record.markProviderDisposalFinished()
        record.markExecutionTaskFinished()
        record.markExecutionTaskFinished()

        await first.value
        await second.value
        await record.awaitTeardownSettlement()
        XCTAssertNotNil(record.teardownFinishedAt)
    }

    func testAppShutdownRetiresHiddenRecordAndWaitsForProviderAndExecution() async {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let provider = GatedHeadlessAgentProvider()
        let executionGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { await executionGate.wait() }
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: false, releaseActiveSlot: true))

        let shutdownFinished = ContextBuilderTestFlag()
        let shutdown = Task {
            await viewModel.shutdownForAppTermination()
            await shutdownFinished.set()
        }
        await provider.waitUntilDisposeStarted()
        await executionGate.waitUntilEntered()

        XCTAssertEqual(record.terminalOutcome, .cancelled)
        let finishedBeforeDisposal = await shutdownFinished.current()
        XCTAssertFalse(finishedBeforeDisposal)
        await provider.allowDispose()
        let finishedBeforeExecution = await shutdownFinished.current()
        XCTAssertFalse(finishedBeforeExecution)
        await executionGate.open()
        await shutdown.value

        let finishedAfterSettlement = await shutdownFinished.current()
        XCTAssertTrue(finishedAfterSettlement)
        XCTAssertNotNil(record.teardownFinishedAt)
    }

    func testWindowRegistrationIsRejectedAfterTerminationSignal() {
        let manager = WindowStatesManager.shared
        let window = makeWindow()
        manager.setTerminatingForTesting(true)
        defer {
            if manager.allWindows.contains(where: { $0 === window }) {
                manager.unregisterWindowState(window)
            }
            manager.setTerminatingForTesting(false)
        }

        manager.registerWindowState(window)

        XCTAssertTrue(window.isClosing)
        XCTAssertFalse(manager.allWindows.contains { $0 === window })
    }

    func testManagerShutdownIncludesWindowUnregisteredBeforeTerminationSignal() async {
        let manager = WindowStatesManager.shared
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let firstEvent = ContextBuilderTestFirstEvent()
        let provider = GatedHeadlessAgentProvider {
            await firstEvent.signal(.providerDisposalStarted)
        }
        let executionGate = ContextBuilderTestGate()
        let closingCaptureGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { await executionGate.wait() }
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: false, releaseActiveSlot: true))

        manager.registerWindowState(window)
        let pendingTearDown = Task { @MainActor [window] in
            await closingCaptureGate.wait()
            _ = window.windowID
        }
        await closingCaptureGate.waitUntilEntered()
        manager.unregisterWindowState(window)
        XCTAssertFalse(manager.allWindows.contains { $0 === window })

        let shutdownFinished = ContextBuilderTestFlag()
        let shutdown = Task {
            await manager.shutdownAllAgentSessions()
            await shutdownFinished.set()
            await firstEvent.signal(.managerShutdownFinished)
        }

        let observedFirstEvent = await firstEvent.wait()
        XCTAssertEqual(observedFirstEvent, .providerDisposalStarted)
        guard observedFirstEvent == .providerDisposalStarted else {
            await provider.allowDispose()
            await executionGate.open()
            await viewModel.shutdownForAppTermination()
            await closingCaptureGate.open()
            await pendingTearDown.value
            return
        }

        await executionGate.waitUntilEntered()
        let finishedBeforeGatesOpen = await shutdownFinished.current()
        XCTAssertFalse(finishedBeforeGatesOpen)
        await provider.allowDispose()
        let finishedBeforeExecution = await shutdownFinished.current()
        XCTAssertFalse(finishedBeforeExecution)
        await executionGate.open()
        await shutdown.value

        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
        XCTAssertNotNil(record.teardownFinishedAt)
        await closingCaptureGate.open()
        await pendingTearDown.value
    }

    func testTerminationSignalRetainsMCPRunOwnerUntilManagerShutdownJoinsProvider() async {
        let manager = WindowStatesManager.shared
        defer { manager.setTerminatingForTesting(false) }
        var window: WindowState? = makeWindow()
        weak var weakWindow: WindowState?
        weakWindow = window
        let firstEvent = ContextBuilderTestFirstEvent()
        let provider = GatedHeadlessAgentProvider {
            await firstEvent.signal(.providerDisposalStarted)
        }
        let record = makeRecord(origin: .mcp(controlToken: UUID()))
        XCTAssertTrue(record.installProvider(provider))
        // The strong binding must stay scoped to this block: once `window` is cleared, the
        // manager's termination retention is the only thing keeping the window alive, which is
        // exactly what the deallocation assertion measures.
        if let registeredWindow = window {
            XCTAssertTrue(registeredWindow.contextBuilderAgentViewModel.registerRunRecordForTesting(
                record,
                makeCurrent: true
            ))
            manager.registerWindowState(registeredWindow)
            manager.signalTermination()
            manager.unregisterWindowState(registeredWindow)
        } else {
            XCTFail("Expected test window")
            return
        }
        window = nil

        let shutdown = Task {
            await manager.shutdownAllAgentSessions()
            await firstEvent.signal(.managerShutdownFinished)
        }
        let observedFirstEvent = await firstEvent.wait()
        guard observedFirstEvent == .providerDisposalStarted else {
            XCTFail("Expected provider disposal before manager shutdown finished, got \(observedFirstEvent)")
            await shutdown.value
            return
        }

        await provider.allowDispose()
        await shutdown.value

        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
        XCTAssertNotNil(record.teardownFinishedAt)
        XCTAssertNil(weakWindow)
    }

    func testAppShutdownJoinsAlreadyStartedTeardownWithoutDuplicateDisposal() async {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let provider = GatedHeadlessAgentProvider()
        let executionGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { await executionGate.wait() }
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: false))
        viewModel.scheduleRunTeardownForTesting(record)
        await provider.waitUntilDisposeStarted()
        await executionGate.waitUntilEntered()

        let shutdown = Task { await viewModel.shutdownForAppTermination() }
        await provider.allowDispose()
        await executionGate.open()
        await shutdown.value

        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
        XCTAssertNotNil(record.teardownFinishedAt)
    }

    func testStartedTeardownSettlesAfterViewModelDeallocationWithoutDuplicateDisposal() async {
        var window: WindowState? = makeWindow()
        weak var weakViewModel = window?.contextBuilderAgentViewModel
        let provider = GatedHeadlessAgentProvider()
        let executionGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { await executionGate.wait() }
        XCTAssertTrue(weakViewModel?.registerRunRecordForTesting(record, makeCurrent: false) == true)
        weakViewModel?.scheduleRunTeardownForTesting(record)
        await provider.waitUntilDisposeStarted()
        await executionGate.waitUntilEntered()

        window?.beginClose()
        window = nil
        XCTAssertNil(weakViewModel)

        await provider.allowDispose()
        await executionGate.open()
        await record.awaitTeardownSettlement()
        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
    }

    func testClaimedFinalContextReachesSafeBoundaryBeforeShutdownDisposal() async {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let provider = GatedHeadlessAgentProvider()
        let safeBoundaryGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { @MainActor [weak viewModel, record] in
            await safeBoundaryGate.wait()
            _ = viewModel?.finishDeferredCancellationAtSafeBoundaryForTesting(record)
        }
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true))
        XCTAssertTrue(record.claimFinalContextCommit())

        let shutdown = Task { await viewModel.shutdownForAppTermination() }
        while record.cancellationState == .none {
            await Task.yield()
        }

        XCTAssertEqual(record.cancellationState, .deferredUntilFinalContextCommitCompletes)
        let disposeCallCountBeforeSafeBoundary = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCountBeforeSafeBoundary, 0)
        await safeBoundaryGate.open()
        await provider.waitUntilDisposeStarted()
        await provider.allowDispose()
        await shutdown.value

        XCTAssertEqual(record.terminalOutcome, .cancelled)
        XCTAssertNotNil(record.teardownFinishedAt)
    }

    func testStaleClaimedFinalContextDefersShutdownUntilSafeBoundary() async {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let provider = GatedHeadlessAgentProvider()
        let safeBoundaryGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { @MainActor [weak viewModel, record] in
            await safeBoundaryGate.wait()
            _ = viewModel?.finishDeferredCancellationAtSafeBoundaryForTesting(record)
        }
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true, releaseActiveSlot: true))
        XCTAssertTrue(record.claimFinalContextCommit())

        let shutdown = Task { await viewModel.shutdownForAppTermination() }
        while record.cancellationState == .none, await provider.disposeCallCount() == 0 {
            await Task.yield()
        }

        XCTAssertEqual(record.cancellationState, .deferredUntilFinalContextCommitCompletes)
        guard record.cancellationState == .deferredUntilFinalContextCommitCompletes else {
            await provider.allowDispose()
            await safeBoundaryGate.open()
            await shutdown.value
            return
        }

        let disposeCallCountBeforeSafeBoundary = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCountBeforeSafeBoundary, 0)
        await safeBoundaryGate.open()
        await provider.waitUntilDisposeStarted()
        await provider.allowDispose()
        await shutdown.value

        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
        XCTAssertNotNil(record.teardownFinishedAt)
    }

    func testExplicitCancellationAndNormalCompletionResolveBeforeGatedTeardown() async throws {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel

        try await assertWaiterResolvesBeforeTeardown(
            viewModel: viewModel,
            terminalOutcome: .cancelled,
            settle: { viewModel.cancelRunForTesting($0) }
        )
        try await assertWaiterResolvesBeforeTeardown(
            viewModel: viewModel,
            terminalOutcome: .completed,
            settle: { _ = viewModel.finalizeRunForTesting($0, outcome: .completed) }
        )
    }

    private func assertWaiterResolvesBeforeTeardown(
        viewModel: ContextBuilderAgentViewModel,
        terminalOutcome: ContextBuilderRunTerminalOutcome,
        settle: (ContextBuilderRunRecord) -> Void
    ) async throws {
        var capturedContinuation: CheckedContinuation<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error>?
        let waiter = Task { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                capturedContinuation = continuation
            }
        }
        while capturedContinuation == nil {
            await Task.yield()
        }

        let provider = GatedHeadlessAgentProvider()
        let executionGate = ContextBuilderTestGate()
        let record = makeRecord(
            continuation: capturedContinuation
        )
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { await executionGate.wait() }
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true))

        settle(record)
        let completion = try await waiter.value
        XCTAssertEqual(completion.terminalDisposition, terminalOutcome)
        XCTAssertNil(record.teardownFinishedAt)

        await provider.waitUntilDisposeStarted()
        await executionGate.waitUntilEntered()
        await provider.allowDispose()
        await executionGate.open()
        await record.awaitTeardownSettlement()
        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
    }

    private func makeWindow() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        return WindowState(contextBuilderProviderFactory: { _, _, _ in
            UnsupportedHeadlessAgentProvider(reason: "Unused by synthetic lifecycle tests")
        })
    }

    private func makeRecord(
        continuation: CheckedContinuation<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error>? = nil,
        origin: ContextBuilderRunOrigin = .ui
    ) -> ContextBuilderRunRecord {
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        return ContextBuilderRunRecord(
            runID: UUID(),
            tabID: tabID,
            session: session,
            ownership: session.beginRunAttempt(source: "graceful-shutdown-test"),
            origin: origin,
            agentKind: .claudeCode,
            modelRaw: AgentModel.defaultModel.rawValue,
            continuation: continuation
        )
    }
}

private final class GatedHeadlessAgentProvider: HeadlessAgentProvider, @unchecked Sendable {
    private let disposeGate = ContextBuilderTestGate()
    private let state = GatedHeadlessAgentProviderState()
    private let onDisposeStarted: @Sendable () async -> Void

    init(onDisposeStarted: @escaping @Sendable () async -> Void = {}) {
        self.onDisposeStarted = onDisposeStarted
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func dispose() async {
        await state.noteDisposeStarted()
        await onDisposeStarted()
        await disposeGate.wait()
    }

    func waitUntilDisposeStarted() async {
        await state.waitUntilDisposeStarted()
    }

    func allowDispose() async {
        await disposeGate.open()
    }

    func disposeCallCount() async -> Int {
        await state.disposeCallCount
    }
}

private actor GatedHeadlessAgentProviderState {
    private(set) var disposeCallCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func noteDisposeStarted() {
        disposeCallCount += 1
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilDisposeStarted() async {
        if disposeCallCount > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor ContextBuilderTestGate {
    private var isOpen = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        pendingEntryWaiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = openWaiters
        openWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ContextBuilderTestFirstEvent {
    enum Event: Equatable {
        case providerDisposalStarted
        case managerShutdownFinished
    }

    private var firstEvent: Event?
    private var waiters: [CheckedContinuation<Event, Never>] = []

    func signal(_ event: Event) {
        guard firstEvent == nil else { return }
        firstEvent = event
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: event) }
    }

    func wait() async -> Event {
        if let firstEvent { return firstEvent }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private actor ContextBuilderTestFlag {
    private var value = false

    func set() {
        value = true
    }

    func current() -> Bool {
        value
    }
}
