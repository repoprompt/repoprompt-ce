import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class WorkspaceSelectionMirrorRecoveryTests: XCTestCase {
    func testCallerCancellationRepairsLatestSelectionWithoutConcurrentPhysicalWorkers() async {
        let initial = selection("initial")
        let latest = selection("latest")
        let staleAttemptGate = SelectionMirrorRecoveryGate()
        let repairGate = SelectionMirrorRecoveryGate()
        let deadline = ManualSelectionMirrorDeadline()
        let requestFinished = SelectionMirrorRecoverySignal()
        let host = SelectionMirrorRecoveryHost(selections: [initial])
        host.gatesByAttempt[1] = staleAttemptGate
        host.gatesByAttempt[2] = repairGate
        let coordinator = makeCoordinator(host: host, deadline: deadline)

        let request = Task { @MainActor in
            let result = await coordinator.mirrorSelectionToActiveUI(initial, forTabID: host.activeTabID)
            requestFinished.signal()
            return result
        }
        guard await staleAttemptGate.waitUntilEntered() else {
            request.cancel()
            await failWait("stale physical attempt to enter", gates: [staleAttemptGate, repairGate], deadline: deadline)
            return
        }
        guard await deadline.waitUntilRegistered(1) else {
            request.cancel()
            await failWait("manual deadline registration", gates: [staleAttemptGate, repairGate], deadline: deadline)
            return
        }
        host.setSelection(latest, forTabID: host.activeTabID)

        request.cancel()
        guard await requestFinished.waitUntilCount(1) else {
            await failWait("cancelled mirror request to finish", gates: [staleAttemptGate, repairGate], deadline: deadline)
            return
        }
        let result = await request.value
        XCTAssertEqual(result, .cancelled)
        assertParkedRepair(coordinator)

        await staleAttemptGate.release()
        guard await host.completed.waitUntilCount(1) else {
            await failWait("stale physical selection to apply", gates: [repairGate], deadline: deadline)
            return
        }
        guard await repairGate.waitUntilEntered() else {
            await failWait("serialized repair attempt to enter", gates: [repairGate], deadline: deadline)
            return
        }

        XCTAssertEqual(host.startedSelections, [initial, latest])
        XCTAssertEqual(host.completedSelections, [initial])
        XCTAssertEqual(host.appliedSelection, initial)
        XCTAssertEqual(host.maximumConcurrentAttempts, 1)

        await repairGate.release()
        guard await host.completed.waitUntilCount(2) else {
            await failWait("latest canonical selection to apply", gates: [repairGate], deadline: deadline)
            return
        }
        guard await deadline.waitUntilExited(1) else {
            await failWait("cancelled manual deadline wait to exit", gates: [repairGate], deadline: deadline)
            return
        }
        guard await waitUntilMirrorWorkIsReclaimed(coordinator) else {
            await failWait("cancelled mirror repair cleanup", gates: [repairGate], deadline: deadline)
            return
        }

        XCTAssertEqual(host.completedSelections, [initial, latest])
        XCTAssertEqual(host.appliedSelection, latest)
        XCTAssertEqual(host.maximumConcurrentAttempts, 1)
        assertFullyReclaimed(coordinator, deadlinesFired: 0)
    }

    func testExplicitDeadlineDefersAndRepairsLatestSelectionBeforeCleanup() async {
        let initial = selection("initial")
        let latest = selection("latest")
        let staleAttemptGate = SelectionMirrorRecoveryGate()
        let repairGate = SelectionMirrorRecoveryGate()
        let deadline = ManualSelectionMirrorDeadline()
        let requestFinished = SelectionMirrorRecoverySignal()
        let host = SelectionMirrorRecoveryHost(selections: [initial])
        host.gatesByAttempt[1] = staleAttemptGate
        host.gatesByAttempt[2] = repairGate
        let coordinator = makeCoordinator(host: host, deadline: deadline)

        let request = Task { @MainActor in
            let result = await coordinator.mirrorSelectionToActiveUI(initial, forTabID: host.activeTabID)
            requestFinished.signal()
            return result
        }
        guard await staleAttemptGate.waitUntilEntered() else {
            request.cancel()
            await failWait("stale physical attempt to enter", gates: [staleAttemptGate, repairGate], deadline: deadline)
            return
        }
        guard await deadline.waitUntilRegistered(1) else {
            request.cancel()
            await failWait("manual deadline registration", gates: [staleAttemptGate, repairGate], deadline: deadline)
            return
        }
        host.setSelection(latest, forTabID: host.activeTabID)

        await deadline.fireNext()
        guard await requestFinished.waitUntilCount(1) else {
            request.cancel()
            await failWait("deferred mirror request to finish", gates: [staleAttemptGate, repairGate], deadline: deadline)
            return
        }
        let result = await request.value
        XCTAssertEqual(result, .deferred)
        assertParkedRepair(coordinator)

        await staleAttemptGate.release()
        guard await host.completed.waitUntilCount(1) else {
            await failWait("stale physical selection to apply", gates: [repairGate], deadline: deadline)
            return
        }
        guard await repairGate.waitUntilEntered() else {
            await failWait("serialized repair attempt to enter", gates: [repairGate], deadline: deadline)
            return
        }

        XCTAssertEqual(host.startedSelections, [initial, latest])
        XCTAssertEqual(host.completedSelections, [initial])
        XCTAssertEqual(host.appliedSelection, initial)
        XCTAssertEqual(host.maximumConcurrentAttempts, 1)

        await repairGate.release()
        guard await host.completed.waitUntilCount(2) else {
            await failWait("latest canonical selection to apply", gates: [repairGate], deadline: deadline)
            return
        }
        guard await deadline.waitUntilExited(1) else {
            await failWait("fired manual deadline wait to exit", gates: [repairGate], deadline: deadline)
            return
        }
        guard await waitUntilMirrorWorkIsReclaimed(coordinator) else {
            await failWait("deadline mirror repair cleanup", gates: [repairGate], deadline: deadline)
            return
        }

        XCTAssertEqual(host.completedSelections, [initial, latest])
        XCTAssertEqual(host.appliedSelection, latest)
        XCTAssertEqual(host.maximumConcurrentAttempts, 1)
        assertFullyReclaimed(coordinator, deadlinesFired: 1)
    }

    func testABATabTransitionFencesStaleCompletionAndRepairsCurrentTarget() async {
        let selectionA = selection("a")
        let selectionB = selection("b")
        let gate = SelectionMirrorRecoveryGate()
        let deadline = ManualSelectionMirrorDeadline()
        let requestFinished = SelectionMirrorRecoverySignal()
        let host = SelectionMirrorRecoveryHost(selections: [selectionA, selectionB])
        let tabA = host.activeTabID
        let tabB = host.inactiveTabID
        host.gatesByAttempt[1] = gate
        let coordinator = makeCoordinator(host: host, deadline: deadline)

        let request = Task { @MainActor in
            let result = await coordinator.mirrorSelectionToActiveUI(selectionA, forTabID: tabA)
            requestFinished.signal()
            return result
        }
        guard await gate.waitUntilEntered() else {
            request.cancel()
            await failWait("ABA physical attempt to enter", gates: [gate], deadline: deadline)
            return
        }
        guard await deadline.waitUntilRegistered(1) else {
            request.cancel()
            await failWait("ABA manual deadline registration", gates: [gate], deadline: deadline)
            return
        }
        host.setActiveTab(tabB)
        host.setActiveTab(tabA)

        await gate.release()
        guard await requestFinished.waitUntilCount(1) else {
            request.cancel()
            await failWait("ABA mirror request to finish", gates: [gate], deadline: deadline)
            return
        }
        let result = await request.value
        XCTAssertEqual(result, .deferred)
        guard await host.completed.waitUntilCount(2) else {
            await failWait("ABA repair completion", gates: [gate], deadline: deadline)
            return
        }
        guard await deadline.waitUntilExited(1) else {
            await failWait("ABA manual deadline wait to exit", gates: [gate], deadline: deadline)
            return
        }
        guard await waitUntilMirrorWorkIsReclaimed(coordinator) else {
            await failWait("ABA mirror repair cleanup", gates: [gate], deadline: deadline)
            return
        }

        XCTAssertEqual(host.selectionMirrorContextRevision, 2)
        XCTAssertEqual(host.startedSelections, [selectionA, selectionA])
        XCTAssertEqual(host.completedSelections, [selectionA, selectionA])
        XCTAssertEqual(host.appliedSelection, selectionA)
        XCTAssertEqual(host.maximumConcurrentAttempts, 1)
        assertFullyReclaimed(coordinator, deadlinesFired: 0)
    }

    private func makeCoordinator(
        host: SelectionMirrorRecoveryHost,
        deadline: ManualSelectionMirrorDeadline
    ) -> WorkspaceSelectionCoordinator {
        WorkspaceSelectionCoordinator(
            workspaceManager: host,
            store: WorkspaceFileContextStore(),
            mcpSelectionMirrorTimeout: .seconds(10),
            waitForMCPSelectionMirrorDeadline: { _ in
                try await deadline.wait()
            }
        )
    }

    private func selection(_ name: String) -> StoredSelection {
        StoredSelection(selectedPaths: ["/tmp/\(name).swift"])
    }

    private func assertParkedRepair(
        _ coordinator: WorkspaceSelectionCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = coordinator.selectionMirrorDebugSnapshot()
        XCTAssertEqual(snapshot.activePhysicalWorkerCount, 1, file: file, line: line)
        XCTAssertEqual(snapshot.pendingDemandCount, 1, file: file, line: line)
        XCTAssertEqual(snapshot.logicalWaiterCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.liveDeadlineCount, 0, file: file, line: line)
    }

    private func assertFullyReclaimed(
        _ coordinator: WorkspaceSelectionCoordinator,
        deadlinesFired: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = coordinator.selectionMirrorDebugSnapshot()
        XCTAssertEqual(snapshot.activePhysicalWorkerCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.pendingDemandCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.logicalWaiterCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.liveDeadlineCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.workersCreated, snapshot.workersExited, file: file, line: line)
        XCTAssertEqual(snapshot.deadlinesCreated, snapshot.deadlinesExited, file: file, line: line)
        XCTAssertEqual(snapshot.deadlinesFired, deadlinesFired, file: file, line: line)
    }

    private func failWait(
        _ description: String,
        gates: [SelectionMirrorRecoveryGate],
        deadline: ManualSelectionMirrorDeadline,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTFail("Bounded yield guard expired while waiting for \(description)", file: file, line: line)
        for gate in gates {
            await gate.release()
        }
        await deadline.cancelAll()
    }

    private func waitUntilMirrorWorkIsReclaimed(_ coordinator: WorkspaceSelectionCoordinator) async -> Bool {
        for _ in 0 ..< selectionMirrorRecoveryHangGuardYieldLimit {
            let snapshot = coordinator.selectionMirrorDebugSnapshot()
            if snapshot.activePhysicalWorkerCount == 0, snapshot.pendingDemandCount == 0 {
                return true
            }
            await Task.yield()
        }
        return false
    }
}

/// Ordering remains continuation-driven; this bound only fails open when a regression would otherwise hang the suite.
private let selectionMirrorRecoveryHangGuardYieldLimit = 10000

private actor SelectionMirrorRecoveryGate {
    private struct EnteredWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var entered = false
    private var released = false
    private var enteredWaiters: [EnteredWaiter] = []
    private var enteredWaitGuards: [UUID: Task<Void, Never>] = [:]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        resumeEnteredWaiters(with: true)
        guard !released else { return }
        // The blocked physical attempt deliberately survives logical cancellation.
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async -> Bool {
        guard !entered else { return true }
        guard !released else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                enteredWaiters.append(EnteredWaiter(id: id, continuation: continuation))
                enteredWaitGuards[id] = Task { [weak self] in
                    for _ in 0 ..< selectionMirrorRecoveryHangGuardYieldLimit {
                        guard !Task.isCancelled else { return }
                        await Task.yield()
                    }
                    await self?.expireEnteredWaiter(id: id)
                }
            }
        } onCancel: {
            Task { await self.expireEnteredWaiter(id: id) }
        }
    }

    func release() {
        released = true
        resumeEnteredWaiters(with: false)
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    private func expireEnteredWaiter(id: UUID) {
        guard let index = enteredWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = enteredWaiters.remove(at: index)
        enteredWaitGuards.removeValue(forKey: id)?.cancel()
        waiter.continuation.resume(returning: false)
    }

    private func resumeEnteredWaiters(with result: Bool) {
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            enteredWaitGuards.removeValue(forKey: waiter.id)?.cancel()
            waiter.continuation.resume(returning: result)
        }
    }
}

private actor ManualSelectionMirrorDeadline {
    private enum CounterKind {
        case registrations
        case exits
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct CountWaiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct CounterState {
        var count = 0
        var waiters: [CountWaiter] = []
        var waitGuards: [UUID: Task<Void, Never>] = [:]
    }

    private var waiters: [Waiter] = []
    private var counters: [CounterKind: CounterState] = [
        .registrations: CounterState(),
        .exits: CounterState()
    ]

    func wait() async throws {
        let id = UUID()
        defer {
            // Cleanup assertions need proof that cancellation reached the injected wait, not merely the cancelling task.
            incrementCounter(.exits)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
                incrementCounter(.registrations)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitUntilRegistered(_ count: Int) async -> Bool {
        await waitUntil(count, counter: .registrations)
    }

    func waitUntilExited(_ count: Int) async -> Bool {
        await waitUntil(count, counter: .exits)
    }

    func fireNext() {
        precondition(!waiters.isEmpty)
        waiters.removeFirst().continuation.resume()
    }

    func cancelAll() {
        let activeWaiters = waiters
        waiters.removeAll()
        activeWaiters.forEach { $0.continuation.resume(throwing: CancellationError()) }
        resumeWaiters(for: .registrations, with: false)
        resumeWaiters(for: .exits, with: false)
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func waitUntil(_ count: Int, counter kind: CounterKind) async -> Bool {
        guard counters[kind, default: CounterState()].count < count else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                let waitGuard = Task { [weak self] in
                    for _ in 0 ..< selectionMirrorRecoveryHangGuardYieldLimit {
                        guard !Task.isCancelled else { return }
                        await Task.yield()
                    }
                    await self?.expireWaiter(id: id, counter: kind)
                }
                counters[kind, default: CounterState()].waiters.append(
                    CountWaiter(id: id, count: count, continuation: continuation)
                )
                counters[kind, default: CounterState()].waitGuards[id] = waitGuard
            }
        } onCancel: {
            Task { await self.expireWaiter(id: id, counter: kind) }
        }
    }

    private func incrementCounter(_ kind: CounterKind) {
        counters[kind, default: CounterState()].count += 1
        satisfyWaiters(for: kind)
    }

    private func expireWaiter(id: UUID, counter kind: CounterKind) {
        guard var state = counters[kind],
              let index = state.waiters.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = state.waiters.remove(at: index)
        state.waitGuards.removeValue(forKey: id)?.cancel()
        counters[kind] = state
        waiter.continuation.resume(returning: false)
    }

    private func satisfyWaiters(for kind: CounterKind) {
        guard var state = counters[kind] else { return }
        let satisfied = state.waiters.filter { state.count >= $0.count }
        state.waiters.removeAll { state.count >= $0.count }
        for waiter in satisfied {
            state.waitGuards.removeValue(forKey: waiter.id)?.cancel()
        }
        counters[kind] = state
        satisfied.forEach { $0.continuation.resume(returning: true) }
    }

    private func resumeWaiters(for kind: CounterKind, with result: Bool) {
        guard var state = counters[kind] else { return }
        let pending = state.waiters
        state.waiters.removeAll()
        for waiter in pending {
            state.waitGuards.removeValue(forKey: waiter.id)?.cancel()
        }
        counters[kind] = state
        pending.forEach { $0.continuation.resume(returning: result) }
    }
}

@MainActor
private final class SelectionMirrorRecoverySignal {
    private struct Waiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var count = 0
    private var waiters: [Waiter] = []
    private var waitGuards: [UUID: Task<Void, Never>] = [:]

    func signal() {
        count += 1
        let satisfied = waiters.filter { count >= $0.count }
        waiters.removeAll { count >= $0.count }
        for waiter in satisfied {
            waitGuards.removeValue(forKey: waiter.id)?.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    func waitUntilCount(_ target: Int) async -> Bool {
        guard count < target else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, count: target, continuation: continuation))
                waitGuards[id] = Task { @MainActor [weak self] in
                    for _ in 0 ..< selectionMirrorRecoveryHangGuardYieldLimit {
                        guard !Task.isCancelled else { return }
                        await Task.yield()
                    }
                    self?.expireWaiter(id: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.expireWaiter(id: id) }
        }
    }

    private func expireWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waitGuards.removeValue(forKey: id)?.cancel()
        waiter.continuation.resume(returning: false)
    }
}

@MainActor
private final class SelectionMirrorRecoveryHost: WorkspaceSelectionHost {
    var activeWorkspace: WorkspaceModel?
    private(set) var selectionMirrorContextRevision: UInt64 = 0
    var gatesByAttempt: [Int: SelectionMirrorRecoveryGate] = [:]
    let completed = SelectionMirrorRecoverySignal()
    private(set) var startedSelections: [StoredSelection] = []
    private(set) var completedSelections: [StoredSelection] = []
    private(set) var appliedSelection: StoredSelection?
    private(set) var maximumConcurrentAttempts = 0
    private var concurrentAttempts = 0

    var activeTabID: UUID {
        activeWorkspace!.activeComposeTabID!
    }

    var inactiveTabID: UUID {
        activeWorkspace!.composeTabs.first(where: { $0.id != activeTabID })!.id
    }

    init(selections: [StoredSelection]) {
        precondition(!selections.isEmpty)
        let tabs = selections.enumerated().map { index, selection in
            ComposeTabState(name: "Mirror \(index)", selection: selection)
        }
        activeWorkspace = WorkspaceModel(
            name: "Mirror Recovery",
            repoPaths: [],
            composeTabs: tabs,
            activeComposeTabID: tabs[0].id
        )
    }

    func composeTab(with id: UUID) -> ComposeTabState? {
        activeWorkspace?.composeTabs.first(where: { $0.id == id })
    }

    func composeTab(for identity: WorkspaceSelectionIdentity) -> ComposeTabState? {
        guard activeWorkspace?.id == identity.workspaceID else { return nil }
        return composeTab(with: identity.tabID)
    }

    func publishActiveComposeTabSnapshot(commitToMemory _: Bool, touchModified _: Bool) {}

    func updateComposeTabStoredOnly(_ tab: ComposeTabState, inWorkspaceID workspaceID: UUID) -> Bool {
        guard var workspace = activeWorkspace,
              workspace.id == workspaceID,
              let index = workspace.composeTabs.firstIndex(where: { $0.id == tab.id })
        else { return false }
        workspace.composeTabs[index] = tab
        activeWorkspace = workspace
        return true
    }

    func applySelectionMirrorAttempt(
        _ selection: StoredSelection,
        forTabID tabID: UUID,
        workspaceID: UUID
    ) async {
        guard activeWorkspace?.id == workspaceID,
              activeWorkspace?.activeComposeTabID == tabID
        else { return }
        startedSelections.append(selection)
        concurrentAttempts += 1
        maximumConcurrentAttempts = max(maximumConcurrentAttempts, concurrentAttempts)
        let attempt = startedSelections.count
        if let gate = gatesByAttempt[attempt] {
            await gate.enter()
        }
        defer { concurrentAttempts -= 1 }
        appliedSelection = selection
        completedSelections.append(selection)
        completed.signal()
    }

    func setSelection(_ selection: StoredSelection, forTabID tabID: UUID) {
        guard var workspace = activeWorkspace,
              let index = workspace.composeTabs.firstIndex(where: { $0.id == tabID })
        else { return }
        workspace.composeTabs[index].selection = selection
        activeWorkspace = workspace
    }

    func setActiveTab(_ tabID: UUID) {
        guard var workspace = activeWorkspace,
              workspace.activeComposeTabID != tabID,
              workspace.composeTabs.contains(where: { $0.id == tabID })
        else { return }
        workspace.activeComposeTabID = tabID
        activeWorkspace = workspace
        selectionMirrorContextRevision &+= 1
    }
}
