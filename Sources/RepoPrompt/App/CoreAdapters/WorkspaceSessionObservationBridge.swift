import Combine
import Foundation
import RepoPromptCore

/// The one-way boundary from an authoritative workspace session into app presentation.
///
/// The bridge deliberately has no command-ingress reference. Snapshot application therefore
/// cannot feed mutations back into the selected backend. Complete snapshots make it safe to
/// coalesce observation delivery and recover a sequence gap from the latest immutable value.
@MainActor
final class WorkspaceSessionObservationBridge: ObservableObject {
    typealias SnapshotApplier = @MainActor (WorkspaceSessionSnapshot) async -> Void

    @Published private(set) var snapshot: WorkspaceSessionSnapshot?
    @Published private(set) var projectionApplyDepth = 0

    private let snapshotProvider: @Sendable () async -> WorkspaceSessionSnapshot?
    private let observationProvider: @Sendable (UInt64?) async -> AsyncStream<WorkspaceSessionSnapshot>
    private let applySnapshot: SnapshotApplier
    private var observationTask: Task<Void, Never>?
    private var appliedSequenceWaiters: [UInt64: [UUID: CheckedContinuation<Bool, Never>]] = [:]
    #if DEBUG
        private var beforeApplyForTesting: (@MainActor (WorkspaceSessionSnapshot) async -> Void)?
    #endif

    init(
        snapshotProvider: @escaping @Sendable () async -> WorkspaceSessionSnapshot?,
        observationProvider: @escaping @Sendable (UInt64?) async -> AsyncStream<WorkspaceSessionSnapshot>,
        applySnapshot: @escaping SnapshotApplier
    ) {
        self.snapshotProvider = snapshotProvider
        self.observationProvider = observationProvider
        self.applySnapshot = applySnapshot
    }

    var isApplyingProjection: Bool {
        projectionApplyDepth > 0
    }

    /// Applies the first authoritative snapshot synchronously on MainActor. Callers must await
    /// this before acknowledging activation or admitting commands.
    func applyFirstAuthoritativeSnapshot(_ first: WorkspaceSessionSnapshot) async {
        precondition(snapshot == nil, "the first authoritative snapshot may be applied only once")
        await apply(first)
    }

    func startObserving() {
        guard observationTask == nil else { return }
        let after = snapshot?.snapshotSequence
        observationTask = Task { [weak self, observationProvider] in
            let stream = await observationProvider(after)
            for await value in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(value)
            }
        }
    }

    func waitUntilApplied(sequence: UInt64) async -> Bool {
        if let snapshot, snapshot.snapshotSequence >= sequence { return true }
        guard !Task.isCancelled else { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                appliedSequenceWaiters[sequence, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelAppliedWaiter(sequence: sequence, waiterID: waiterID)
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        let waiters = appliedSequenceWaiters.values.flatMap(\.values)
        appliedSequenceWaiters.removeAll()
        waiters.forEach { $0.resume(returning: false) }
    }

    #if DEBUG
        func test_setBeforeApply(_ handler: (@MainActor (WorkspaceSessionSnapshot) async -> Void)?) {
            beforeApplyForTesting = handler
        }
    #endif

    private func receive(_ incoming: WorkspaceSessionSnapshot) async {
        guard let current = snapshot else {
            await apply(incoming)
            return
        }
        guard incoming.sessionID == current.sessionID,
              incoming.snapshotSequence > current.snapshotSequence
        else { return }

        if incoming.snapshotSequence > current.snapshotSequence &+ 1,
           let latest = await snapshotProvider(),
           latest.sessionID == current.sessionID,
           latest.snapshotSequence >= incoming.snapshotSequence
        {
            await apply(latest)
        } else {
            await apply(incoming)
        }
    }

    private func apply(_ value: WorkspaceSessionSnapshot) async {
        #if DEBUG
            await beforeApplyForTesting?(value)
        #endif
        projectionApplyDepth += 1
        defer { projectionApplyDepth -= 1 }
        await applySnapshot(value)
        snapshot = value
        resumeAppliedWaiters(through: value.snapshotSequence)
    }

    private func resumeAppliedWaiters(through sequence: UInt64) {
        let completed = appliedSequenceWaiters.keys.filter { $0 <= sequence }
        for key in completed {
            let waiters = appliedSequenceWaiters.removeValue(forKey: key).map { Array($0.values) } ?? []
            waiters.forEach { $0.resume(returning: true) }
        }
    }

    private func cancelAppliedWaiter(sequence: UInt64, waiterID: UUID) {
        guard let waiter = appliedSequenceWaiters[sequence]?.removeValue(forKey: waiterID) else { return }
        if appliedSequenceWaiters[sequence]?.isEmpty == true {
            appliedSequenceWaiters.removeValue(forKey: sequence)
        }
        waiter.resume(returning: false)
    }
}
