import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class MCPReadAutoSelectionRecoveryTests: XCTestCase {
    func testCanonicalInvalidationSettlesWaiterSkipsStaleApplyAndReclaimsLane() async {
        let gate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryInvocationRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let waiterRegistered = RecoveryMainActorSignal()
        let key = contextKey()
        var current: MCPReadFileAutoSelectionCoordinator.ContextKey? = key
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == current },
            applyCanonical: { _, _ in
                await recorder.recordCanonical()
                return .unchanged
            },
            applyMirror: { _ in .converged },
            diagnosticObserver: { probe.record($0) }
        )
        coordinator.setCanonicalApplyGateForTesting { await gate.enter() }

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        guard await gate.waitUntilEntered() else {
            await failWait("canonical worker to enter", gates: [gate])
            coordinator.invalidate(context: key)
            return
        }
        let drain = Task { @MainActor in
            await coordinator.drain(
                .canonicalSelection,
                for: key,
                onCanonicalWaiterRegistered: { waiterRegistered.signal() }
            )
        }
        guard await waiterRegistered.wait() else {
            drain.cancel()
            await failWait("canonical drain waiter registration", gates: [gate])
            coordinator.invalidate(context: key)
            return
        }

        current = nil
        coordinator.invalidate(context: key)
        let drainResult = await drain.value
        let countBeforeRelease = await recorder.canonicalCount()
        XCTAssertEqual(drainResult, .invalidated)
        XCTAssertEqual(countBeforeRelease, 0)
        XCTAssertFalse(coordinator.enqueue(intent: .full(paths: ["/tmp/stale.swift"]), for: key))

        await gate.release()
        guard await probe.waitFor(kind: .workerStopped, lane: .canonical) != nil else {
            await failWait("canonical worker exit")
            coordinator.invalidate(context: key)
            return
        }
        let countAfterRelease = await recorder.canonicalCount()
        XCTAssertEqual(countAfterRelease, 0)
        assertFullyReclaimed(coordinator)
    }

    func testCancellingCanonicalDrainReleasesWaiterWhilePhysicalWorkerContinues() async {
        let gate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryInvocationRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let waiterRegistered = RecoveryMainActorSignal()
        let key = contextKey()
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == key },
            applyCanonical: { _, _ in
                await recorder.recordCanonical()
                return .unchanged
            },
            applyMirror: { _ in .converged },
            diagnosticObserver: { probe.record($0) }
        )
        coordinator.setCanonicalApplyGateForTesting { await gate.enter() }

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        guard await gate.waitUntilEntered() else {
            await failWait("canonical worker to enter", gates: [gate])
            coordinator.invalidate(context: key)
            return
        }
        let drain = Task { @MainActor in
            await coordinator.drain(
                .canonicalSelection,
                for: key,
                onCanonicalWaiterRegistered: { waiterRegistered.signal() }
            )
        }
        guard await waiterRegistered.wait() else {
            drain.cancel()
            await failWait("canonical drain waiter registration", gates: [gate])
            coordinator.invalidate(context: key)
            return
        }

        drain.cancel()
        let cancelledResult = await drain.value
        XCTAssertEqual(cancelledResult, .cancelled)
        XCTAssertEqual(coordinator.debugSnapshot().canonicalWaiterCount, 0)
        XCTAssertEqual(coordinator.debugSnapshot().canonicalWorkerCount, 1)

        await gate.release()
        guard await probe.waitFor(kind: .workerStopped, lane: .canonical) != nil else {
            await failWait("canonical worker exit")
            coordinator.invalidate(context: key)
            return
        }
        let canonicalCount = await recorder.canonicalCount()
        let settledResult = await coordinator.drain(.canonicalSelection, for: key)
        XCTAssertEqual(canonicalCount, 1)
        XCTAssertEqual(settledResult, .completed)
        coordinator.invalidate(context: key)
        assertFullyReclaimed(coordinator)
    }

    func testCancellingMirrorDrainReleasesWaiterAndDeadlineWhilePhysicalWorkerContinues() async {
        let gate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryInvocationRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let key = contextKey()
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == key },
            applyCanonical: { key, _ in .init(mirrorKey: key.mirrorKey) },
            applyMirror: { mirrorKey in
                _ = await recorder.recordMirror(mirrorKey)
                await gate.enter()
                return .converged
            },
            diagnosticObserver: { probe.record($0) }
        )

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        guard await gate.waitUntilEntered() else {
            await failWait("mirror worker to enter", gates: [gate])
            coordinator.invalidate(context: key)
            return
        }
        let drain = Task { @MainActor in
            await coordinator.drain(.mirroredSelectionAndMetrics, for: key)
        }
        guard await probe.waitFor(kind: .waiterRegistered, lane: .mirror, target: 1) != nil else {
            drain.cancel()
            await failWait("mirror drain waiter registration", gates: [gate])
            coordinator.invalidate(context: key)
            return
        }

        drain.cancel()
        let cancelledResult = await drain.value
        XCTAssertEqual(cancelledResult, .cancelled)
        let cancelled = coordinator.debugSnapshot()
        XCTAssertEqual(cancelled.mirrorWaiterCount, 0)
        XCTAssertEqual(cancelled.liveMirrorDeadlineCount, 0)
        XCTAssertEqual(cancelled.mirrorWorkerCount, 1)

        await gate.release()
        guard await probe.waitFor(kind: .workerStopped, lane: .mirror) != nil else {
            await failWait("mirror worker exit")
            coordinator.invalidate(context: key)
            return
        }
        let settledResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: key)
        let mirrorCount = await recorder.mirrorCount()
        XCTAssertEqual(settledResult, .completed)
        XCTAssertEqual(mirrorCount, 1)
        coordinator.invalidate(context: key)
        assertFullyReclaimed(coordinator)
    }

    func testFinishDeadlineReturnsDeferredRejectsNewWorkAndReclaimsAfterPhysicalExit() async {
        let gate = RecoveryCancellationIgnoringGate()
        let probe = RecoveryDiagnosticEventProbe()
        let key = contextKey()
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == key },
            applyCanonical: { key, _ in .init(mirrorKey: key.mirrorKey) },
            applyMirror: { _ in
                await gate.enter()
                return .converged
            },
            diagnosticObserver: { probe.record($0) },
            mirrorWaitTimeout: .zero
        )

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        guard await gate.waitUntilEntered() else {
            await failWait("deadline mirror worker to enter", gates: [gate])
            coordinator.invalidate(context: key)
            return
        }
        let finishResult = await coordinator.finish(context: key)
        XCTAssertEqual(finishResult, .deferred)
        XCTAssertFalse(coordinator.enqueue(intent: .full(paths: ["/tmp/later.swift"]), for: key))
        let deferred = coordinator.debugSnapshot()
        XCTAssertEqual(deferred.mirrorWaiterCount, 0)
        XCTAssertEqual(deferred.liveMirrorDeadlineCount, 0)
        XCTAssertEqual(deferred.mirrorWorkerCount, 1)

        coordinator.invalidate(context: key)
        XCTAssertEqual(coordinator.debugSnapshot().retiredMirrorWorkerCount, 1)
        await gate.release()
        guard await probe.waitFor(kind: .workerStopped, lane: .mirror) != nil else {
            await failWait("retired mirror worker exit")
            coordinator.invalidate(context: key)
            return
        }
        assertFullyReclaimed(coordinator)

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/reopened.swift"]), for: key))
        guard await probe.waitFor(kind: .workerStopped, lane: .mirror, occurrence: 2) != nil else {
            await failWait("reopened mirror worker exit")
            coordinator.invalidate(context: key)
            return
        }
        let reopenedResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: key)
        XCTAssertEqual(reopenedResult, .completed)
        coordinator.invalidate(context: key)
        assertFullyReclaimed(coordinator)
    }

    func testInvalidatingParkedMirrorOwnerPreservesSameTabSurvivorAndFencesLateExit() async {
        let oldGate = RecoveryCancellationIgnoringGate()
        let replacementGate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryInvocationRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let tabID = UUID()
        let workspaceID = UUID()
        let old = contextKey(tabID: tabID, workspaceID: workspaceID, bindingGeneration: 1)
        let replacement = contextKey(tabID: tabID, workspaceID: workspaceID, bindingGeneration: 2)
        var current: Set<MCPReadFileAutoSelectionCoordinator.ContextKey> = [old, replacement]
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { current.contains($0) },
            applyCanonical: { key, _ in .init(mirrorKey: key.mirrorKey) },
            applyMirror: { mirrorKey in
                let invocation = await recorder.recordMirror(mirrorKey)
                if invocation == 1 {
                    await oldGate.enter()
                } else if invocation == 2 {
                    await replacementGate.enter()
                }
                return .converged
            },
            diagnosticObserver: { probe.record($0) }
        )

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/old.swift"]), for: old))
        guard await oldGate.waitUntilEntered() else {
            await failWait("retiring mirror worker to enter", gates: [oldGate, replacementGate])
            coordinator.invalidate(context: old)
            coordinator.invalidate(context: replacement)
            return
        }
        let oldDrain = Task { @MainActor in
            await coordinator.drain(.mirroredSelectionAndMetrics, for: old)
        }
        guard await probe.waitFor(kind: .waiterRegistered, lane: .mirror, target: 1) != nil else {
            oldDrain.cancel()
            await failWait("retiring mirror waiter registration", gates: [oldGate, replacementGate])
            coordinator.invalidate(context: old)
            coordinator.invalidate(context: replacement)
            return
        }

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/replacement.swift"]), for: replacement))
        let replacementDrain = Task { @MainActor in
            await coordinator.drain(.mirroredSelectionAndMetrics, for: replacement)
        }
        guard await probe.waitFor(kind: .waiterRegistered, lane: .mirror, target: 2) != nil else {
            oldDrain.cancel()
            replacementDrain.cancel()
            await failWait("replacement mirror waiter registration", gates: [oldGate, replacementGate])
            coordinator.invalidate(context: old)
            coordinator.invalidate(context: replacement)
            return
        }

        current.remove(old)
        coordinator.invalidate(context: old)
        let oldResult = await oldDrain.value
        XCTAssertEqual(oldResult, .invalidated)
        XCTAssertEqual(coordinator.debugSnapshot().mirrorWaiterCount, 1)
        guard await replacementGate.waitUntilEntered() else {
            replacementDrain.cancel()
            await failWait("replacement mirror worker to enter", gates: [oldGate, replacementGate])
            coordinator.invalidate(context: replacement)
            return
        }

        let workerStarts = probe.snapshot().filter { $0.kind == .workerStarted && $0.lane == .mirror }
        guard workerStarts.count == 2 else {
            replacementDrain.cancel()
            await failWait("exactly two mirror workers to start", gates: [oldGate, replacementGate])
            coordinator.invalidate(context: replacement)
            return
        }
        XCTAssertNotEqual(workerStarts[0].workerID, workerStarts[1].workerID)

        await replacementGate.release()
        let replacementResult = await replacementDrain.value
        let countBeforeOldExit = await recorder.mirrorCount()
        XCTAssertEqual(replacementResult, .completed)
        XCTAssertEqual(countBeforeOldExit, 2)

        // The retired callback ignores cancellation deliberately, proving its late exit is fenced by worker identity.
        await oldGate.release()
        guard await probe.waitFor(kind: .workerStopped, lane: .mirror, occurrence: 2) != nil else {
            await failWait("both mirror workers to exit")
            current.remove(replacement)
            coordinator.invalidate(context: replacement)
            return
        }
        let countAfterOldExit = await recorder.mirrorCount()
        XCTAssertEqual(countAfterOldExit, 2)
        current.remove(replacement)
        coordinator.invalidate(context: replacement)
        assertFullyReclaimed(coordinator)
    }

    func testLateMirrorDrainReceivesExactTerminalOutcome() async {
        let cases: [(WorkspaceSelectionCoordinator.SelectionMirrorOutcome, MCPReadFileAutoSelectionCoordinator.DrainResult)] = [
            (.converged, .completed),
            (.deferred, .deferred),
            (.invalidated, .invalidated),
            (.cancelled, .cancelled)
        ]

        for (mirrorOutcome, expectedDrain) in cases {
            let probe = RecoveryDiagnosticEventProbe()
            let key = contextKey()
            let coordinator = MCPReadFileAutoSelectionCoordinator(
                isContextCurrent: { $0 == key },
                applyCanonical: { key, _ in .init(mirrorKey: key.mirrorKey) },
                applyMirror: { _ in mirrorOutcome },
                diagnosticObserver: { probe.record($0) }
            )

            XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
            guard await probe.waitFor(kind: .workerStopped, lane: .mirror) != nil else {
                await failWait("terminal-outcome mirror worker exit")
                coordinator.invalidate(context: key)
                return
            }
            let drainResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: key)
            XCTAssertEqual(drainResult, expectedDrain)
            coordinator.invalidate(context: key)
            assertFullyReclaimed(coordinator)
        }
    }

    func testLaterSameTabConvergenceUpgradesDeferredTicketAndPrunesObsoleteSettlement() async {
        let recorder = RecoveryInvocationRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let tabID = UUID()
        let workspaceID = UUID()
        let earlier = contextKey(tabID: tabID, workspaceID: workspaceID, bindingGeneration: 1)
        let later = contextKey(tabID: tabID, workspaceID: workspaceID, bindingGeneration: 2)
        var current: Set<MCPReadFileAutoSelectionCoordinator.ContextKey> = [earlier, later]
        let scripted: [WorkspaceSelectionCoordinator.SelectionMirrorOutcome] = [.deferred, .converged, .deferred]
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { current.contains($0) },
            applyCanonical: { key, _ in .init(mirrorKey: key.mirrorKey) },
            applyMirror: { mirrorKey in
                let invocation = await recorder.recordMirror(mirrorKey)
                return scripted[invocation - 1]
            },
            diagnosticObserver: { probe.record($0) }
        )

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/earlier.swift"]), for: earlier))
        guard await probe.waitFor(kind: .workerStopped, lane: .mirror, occurrence: 1) != nil else {
            await failWait("earlier mirror worker exit")
            coordinator.invalidate(context: earlier)
            coordinator.invalidate(context: later)
            return
        }
        let initialEarlierResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: earlier)
        XCTAssertEqual(initialEarlierResult, .deferred)

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/later.swift"]), for: later))
        guard await probe.waitFor(kind: .workerStopped, lane: .mirror, occurrence: 2) != nil else {
            await failWait("later mirror worker exit")
            coordinator.invalidate(context: earlier)
            coordinator.invalidate(context: later)
            return
        }
        let laterResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: later)
        let upgradedEarlierResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: earlier)
        XCTAssertEqual(laterResult, .completed)
        XCTAssertEqual(upgradedEarlierResult, .completed)

        // Once convergence upgrades the earlier ticket, retiring that owner makes its deferred range obsolete.
        current.remove(earlier)
        coordinator.invalidate(context: earlier)
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/newer.swift"]), for: later))
        guard await probe.waitFor(kind: .workerStopped, lane: .mirror, occurrence: 3) != nil else {
            await failWait("newer mirror worker exit")
            coordinator.invalidate(context: later)
            return
        }
        let newerResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: later)
        let mirrorCount = await recorder.mirrorCount()
        XCTAssertEqual(newerResult, .deferred)
        XCTAssertEqual(mirrorCount, 3)
        XCTAssertEqual(coordinator.debugSnapshot().mirrorSettlementRangeCount, 1)

        current.remove(later)
        coordinator.invalidate(context: earlier)
        coordinator.invalidate(context: later)
        assertFullyReclaimed(coordinator)
    }

    private func contextKey(
        tabID: UUID = UUID(),
        workspaceID: UUID = UUID(),
        bindingGeneration: UInt64 = 1
    ) -> MCPReadFileAutoSelectionCoordinator.ContextKey {
        MCPReadFileAutoSelectionCoordinator.ContextKey(
            windowID: 1,
            workspaceID: workspaceID,
            tabID: tabID,
            route: .bound(connectionID: UUID(), runID: UUID()),
            bindingGeneration: bindingGeneration
        )
    }

    private func failWait(
        _ description: String,
        gates: [RecoveryCancellationIgnoringGate] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTFail("Bounded yield guard expired while waiting for \(description)", file: file, line: line)
        for gate in gates {
            await gate.release()
        }
    }

    private func assertFullyReclaimed(
        _ coordinator: MCPReadFileAutoSelectionCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = coordinator.debugSnapshot()
        XCTAssertEqual(snapshot.canonicalLaneCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.canonicalWorkerCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.mirrorLaneCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.mirrorWorkerCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.closingContextCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.pendingCanonicalBatchCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.pendingMirrorBatchCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.canonicalWaiterCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.mirrorWaiterCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.inFlightMirrorBatchCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.retiredMirrorWorkerCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.liveMirrorDeadlineCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.mirrorSettlementRangeCount, 0, file: file, line: line)
    }
}

/// Ordering remains continuation-driven; this bound only fails open when a regression would otherwise hang the suite.
private let readAutoSelectionRecoveryHangGuardYieldLimit = 10000

private actor RecoveryCancellationIgnoringGate {
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
        // A checked continuation intentionally ignores task cancellation so tests observe physical worker lifetime.
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
                    for _ in 0 ..< readAutoSelectionRecoveryHangGuardYieldLimit {
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

@MainActor
private final class RecoveryMainActorSignal {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var signalled = false
    private var waiters: [Waiter] = []
    private var waitGuards: [UUID: Task<Void, Never>] = [:]

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waitGuards.removeValue(forKey: waiter.id)?.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    func wait() async -> Bool {
        guard !signalled else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
                waitGuards[id] = Task { @MainActor [weak self] in
                    for _ in 0 ..< readAutoSelectionRecoveryHangGuardYieldLimit {
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

private actor RecoveryInvocationRecorder {
    private var canonicalInvocations = 0
    private var mirrorKeys: [MCPReadFileAutoSelectionCoordinator.TabMirrorKey] = []

    func recordCanonical() {
        canonicalInvocations += 1
    }

    func canonicalCount() -> Int {
        canonicalInvocations
    }

    func recordMirror(_ key: MCPReadFileAutoSelectionCoordinator.TabMirrorKey) -> Int {
        mirrorKeys.append(key)
        return mirrorKeys.count
    }

    func mirrorCount() -> Int {
        mirrorKeys.count
    }
}

private final class RecoveryDiagnosticEventProbe: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let kind: MCPReadFileAutoSelectionDiagnosticEvent.Kind
        let lane: MCPReadFileAutoSelectionDiagnosticEvent.Lane
        let target: UInt64?
        let occurrence: Int
        let continuation: CheckedContinuation<MCPReadFileAutoSelectionDiagnosticEvent?, Never>
    }

    private let lock = NSLock()
    private var events: [MCPReadFileAutoSelectionDiagnosticEvent] = []
    private var waiters: [Waiter] = []
    private var waitGuards: [UUID: Task<Void, Never>] = [:]

    func record(_ event: MCPReadFileAutoSelectionDiagnosticEvent) {
        lock.lock()
        events.append(event)
        var remaining: [Waiter] = []
        var resumptions: [(CheckedContinuation<MCPReadFileAutoSelectionDiagnosticEvent?, Never>, MCPReadFileAutoSelectionDiagnosticEvent)] = []
        for waiter in waiters {
            if let match = matchingEvent(
                kind: waiter.kind,
                lane: waiter.lane,
                target: waiter.target,
                occurrence: waiter.occurrence
            ) {
                waitGuards.removeValue(forKey: waiter.id)?.cancel()
                resumptions.append((waiter.continuation, match))
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
        lock.unlock()

        // Resume outside the lock so awakened tasks can safely re-enter the probe.
        for (continuation, match) in resumptions {
            continuation.resume(returning: match)
        }
    }

    func snapshot() -> [MCPReadFileAutoSelectionDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func waitFor(
        kind: MCPReadFileAutoSelectionDiagnosticEvent.Kind,
        lane: MCPReadFileAutoSelectionDiagnosticEvent.Lane,
        target: UInt64? = nil,
        occurrence: Int = 1
    ) async -> MCPReadFileAutoSelectionDiagnosticEvent? {
        precondition(occurrence > 0)
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let match = matchingEvent(kind: kind, lane: lane, target: target, occurrence: occurrence) {
                    lock.unlock()
                    continuation.resume(returning: match)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiters.append(Waiter(
                        id: id,
                        kind: kind,
                        lane: lane,
                        target: target,
                        occurrence: occurrence,
                        continuation: continuation
                    ))
                    waitGuards[id] = Task { [weak self] in
                        for _ in 0 ..< readAutoSelectionRecoveryHangGuardYieldLimit {
                            guard !Task.isCancelled else { return }
                            await Task.yield()
                        }
                        self?.expireWaiter(id: id)
                    }
                    lock.unlock()
                }
            }
        } onCancel: {
            self.expireWaiter(id: id)
        }
    }

    private func expireWaiter(id: UUID) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        waitGuards.removeValue(forKey: id)?.cancel()
        lock.unlock()
        waiter.continuation.resume(returning: nil)
    }

    private func matchingEvent(
        kind: MCPReadFileAutoSelectionDiagnosticEvent.Kind,
        lane: MCPReadFileAutoSelectionDiagnosticEvent.Lane,
        target: UInt64?,
        occurrence: Int
    ) -> MCPReadFileAutoSelectionDiagnosticEvent? {
        var matchingCount = 0
        for event in events where event.kind == kind && event.lane == lane && (target == nil || event.target == target) {
            matchingCount += 1
            if matchingCount == occurrence {
                return event
            }
        }
        return nil
    }
}
