import Foundation

package struct WorkspaceRootUnloadTerminationPolicy: @unchecked Sendable {
    static let productionGraceNanoseconds: UInt64 = 5_000_000_000

    package static let production = WorkspaceRootUnloadTerminationPolicy(
        publisherIngressGraceNanoseconds: productionGraceNanoseconds,
        watcherStopGraceNanoseconds: productionGraceNanoseconds,
        sleep: { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    )

    let publisherIngressGraceNanoseconds: UInt64
    let watcherStopGraceNanoseconds: UInt64
    let sleep: @Sendable (UInt64) async -> Void

    package init(
        publisherIngressGraceNanoseconds: UInt64,
        watcherStopGraceNanoseconds: UInt64,
        sleep: @escaping @Sendable (UInt64) async -> Void
    ) {
        self.publisherIngressGraceNanoseconds = publisherIngressGraceNanoseconds
        self.watcherStopGraceNanoseconds = watcherStopGraceNanoseconds
        self.sleep = sleep
    }
}

package enum WorkspaceRootWatcherStopOutcome: String, Equatable {
    case completed
    case cancelled
    case timedOut
}

package struct WorkspaceRootWatcherStopReport: Equatable {
    package let rootID: UUID
    package let rootPath: String
    package let outcome: WorkspaceRootWatcherStopOutcome
    package let graceNanoseconds: UInt64
}

package struct WorkspaceRootUnloadTerminationDiagnostics: Equatable {
    package let publisherIngressReports: [WorkspaceFileSystemIngressCoordinator.TerminationReport]
    package let watcherStopReports: [WorkspaceRootWatcherStopReport]
}

package final class WorkspaceRootUnloadCompletionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isCompleted = false
    private var waiters: [UUID: CheckedContinuation<WorkspaceRootWatcherStopOutcome, Never>] = [:]
    private var cancelledWaiterIDs = Set<UUID>()

    package init() {}

    func complete() {
        let continuations: [CheckedContinuation<WorkspaceRootWatcherStopOutcome, Never>]
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        continuations = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        continuations.forEach { $0.resume(returning: .completed) }
    }

    func resolvedOutcome(after provisionalOutcome: WorkspaceRootWatcherStopOutcome) -> WorkspaceRootWatcherStopOutcome {
        lock.lock()
        defer { lock.unlock() }
        return isCompleted ? .completed : provisionalOutcome
    }

    func wait() async -> WorkspaceRootWatcherStopOutcome {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if cancelledWaiterIDs.remove(waiterID) != nil {
                    lock.unlock()
                    continuation.resume(returning: .cancelled)
                } else if isCompleted {
                    lock.unlock()
                    continuation.resume(returning: .completed)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: .cancelled)
                } else {
                    waiters[waiterID] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel(waiterID: waiterID)
        }
    }

    private func cancel(waiterID: UUID) {
        let continuation: CheckedContinuation<WorkspaceRootWatcherStopOutcome, Never>?
        lock.lock()
        continuation = waiters.removeValue(forKey: waiterID)
        if continuation == nil, !isCompleted {
            cancelledWaiterIDs.insert(waiterID)
        }
        lock.unlock()
        continuation?.resume(returning: .cancelled)
    }
}

package enum WorkspaceRootUnloadBoundedWait {
    package static func waitForCompletion(
        _ latch: WorkspaceRootUnloadCompletionLatch,
        timeoutNanoseconds: UInt64,
        sleep: @escaping @Sendable (UInt64) async -> Void
    ) async -> WorkspaceRootWatcherStopOutcome {
        await withTaskGroup(of: WorkspaceRootWatcherStopOutcome.self) { group in
            group.addTask {
                await latch.wait()
            }
            group.addTask {
                await sleep(timeoutNanoseconds)
                return Task.isCancelled ? .cancelled : .timedOut
            }
            let provisionalOutcome = await group.next() ?? .cancelled
            group.cancelAll()
            while await group.next() != nil {}
            return latch.resolvedOutcome(after: provisionalOutcome)
        }
    }
}

package enum WorkspaceRootUnloadDiagnosticsLog {
    static func record(_ diagnostics: WorkspaceRootUnloadTerminationDiagnostics) {
        for report in diagnostics.publisherIngressReports where report.outcome == .forced || report.outcome == .superseded {
            WorkspaceRuntimeDiagnosticsLog.event(
                "workspace.rootUnload.publisherIngress",
                fields: [
                    "rootID": report.rootID.uuidString,
                    "outcome": report.outcome.rawValue,
                    "graceNanoseconds": String(report.graceNanoseconds),
                    "acceptedSequence": String(report.acceptedServicePublicationSequence),
                    "appliedSequence": String(report.appliedServicePublicationSequence),
                    "sequenceGap": String(report.acceptedAppliedSequenceGap),
                    "queuedCount": String(report.queuedPublicationCount),
                    "applyingCount": String(report.applyingPublicationCount),
                    "waiterCount": String(report.waiterCount),
                    "oldestAgeMilliseconds": String(report.oldestOutstandingPublicationAgeMilliseconds ?? 0)
                ],
                bypassEnablement: true
            )
        }
        for report in diagnostics.watcherStopReports where report.outcome == .timedOut {
            WorkspaceRuntimeDiagnosticsLog.event(
                "workspace.rootUnload.watcherStop",
                fields: [
                    "rootID": report.rootID.uuidString,
                    "rootPath": report.rootPath,
                    "outcome": report.outcome.rawValue,
                    "graceNanoseconds": String(report.graceNanoseconds)
                ],
                bypassEnablement: true
            )
        }
    }
}
