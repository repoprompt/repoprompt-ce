import Foundation
import os

struct WorkspaceRootUnloadTerminationPolicy: @unchecked Sendable {
    static let productionGraceNanoseconds: UInt64 = 5_000_000_000

    static let production = WorkspaceRootUnloadTerminationPolicy(
        publisherIngressGraceNanoseconds: productionGraceNanoseconds,
        watcherStopGraceNanoseconds: productionGraceNanoseconds,
        sleep: { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    )

    let publisherIngressGraceNanoseconds: UInt64
    let watcherStopGraceNanoseconds: UInt64
    let sleep: @Sendable (UInt64) async -> Void
}

enum WorkspaceRootWatcherStopOutcome: String, Equatable {
    case completed
    case cancelled
    case timedOut
}

struct WorkspaceRootWatcherStopReport: Equatable {
    let rootID: UUID
    let rootPath: String
    let outcome: WorkspaceRootWatcherStopOutcome
    let graceNanoseconds: UInt64
}

struct WorkspaceRootUnloadTerminationDiagnostics: Equatable {
    let publisherIngressReports: [WorkspaceFileSystemIngressCoordinator.TerminationReport]
    let watcherStopReports: [WorkspaceRootWatcherStopReport]
}

final class WorkspaceRootUnloadCompletionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isCompleted = false
    private var waiters: [UUID: CheckedContinuation<WorkspaceRootWatcherStopOutcome, Never>] = [:]
    private var cancelledWaiterIDs = Set<UUID>()

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

enum WorkspaceRootUnloadBoundedWait {
    static func waitForCompletion(
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

enum WorkspaceRootUnloadDiagnosticsLog {
    private static let logger = Logger(
        subsystem: "com.repoprompt.workspace",
        category: "RootUnloadTermination"
    )

    static func record(_ diagnostics: WorkspaceRootUnloadTerminationDiagnostics) {
        for report in diagnostics.publisherIngressReports where report.outcome == .forced || report.outcome == .superseded {
            logger.fault(
                "Publisher ingress termination root=\(report.rootID.uuidString, privacy: .public) outcome=\(report.outcome.rawValue, privacy: .public) graceNs=\(report.graceNanoseconds, privacy: .public) accepted=\(report.acceptedServicePublicationSequence, privacy: .public) applied=\(report.appliedServicePublicationSequence, privacy: .public) gap=\(report.acceptedAppliedSequenceGap, privacy: .public) queued=\(report.queuedPublicationCount, privacy: .public) applying=\(report.applyingPublicationCount, privacy: .public) waiters=\(report.waiterCount, privacy: .public) oldestMs=\(report.oldestOutstandingPublicationAgeMilliseconds ?? 0, privacy: .public)"
            )
        }
        for report in diagnostics.watcherStopReports where report.outcome == .timedOut {
            logger.fault(
                "Watcher stop timed out root=\(report.rootID.uuidString, privacy: .public) path=\(report.rootPath, privacy: .private(mask: .hash)) graceNs=\(report.graceNanoseconds, privacy: .public); caller continued without claiming synchronous FSEvents interruption"
            )
        }
    }
}
