import CoreServices
import Dispatch
import Foundation

/// Waits for an asynchronous FSEvents flush target to be observed by the
/// client callback without blocking a cooperative thread in
/// `FSEventStreamFlushSync`.
///
/// Callers must record delivery only after they have accepted the callback's
/// payload. A missed deadline is deliberately fail-closed: the optimization
/// that requested the cut must fall back rather than treating unobserved
/// filesystem state as current.
final class FSEventAsyncDeliveryBarrier: @unchecked Sendable {
    struct Generation: Equatable {
        fileprivate let rawValue: UInt64
    }

    typealias DeadlineScheduler = @Sendable (
        _ delayNanoseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> Void

    private struct Waiter {
        let generation: Generation
        let targetEventID: FSEventStreamEventId
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private let timeoutNanoseconds: UInt64
    private let scheduleDeadline: DeadlineScheduler
    private var generationRawValue: UInt64 = 1
    private var highestDeliveredEventID: FSEventStreamEventId = 0
    private var waiters: [UUID: Waiter] = [:]

    init(
        timeoutNanoseconds: UInt64 = 2 * NSEC_PER_SEC,
        scheduleDeadline: @escaping DeadlineScheduler = { delayNanoseconds, action in
            let clampedDelay = Int(min(delayNanoseconds, UInt64(Int.max)))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .nanoseconds(clampedDelay),
                execute: action
            )
        }
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.scheduleDeadline = scheduleDeadline
    }

    var currentGeneration: Generation {
        lock.withLock { Generation(rawValue: generationRawValue) }
    }

    @discardableResult
    func reset() -> Generation {
        reset(ifCurrent: nil)!
    }

    @discardableResult
    func reset(ifCurrent expectedGeneration: Generation) -> Generation? {
        reset(ifCurrent: Optional(expectedGeneration))
    }

    private func reset(ifCurrent expectedGeneration: Generation?) -> Generation? {
        let result: (generation: Generation, continuations: [CheckedContinuation<Bool, Never>])? = lock.withLock {
            if let expectedGeneration,
               expectedGeneration.rawValue != generationRawValue
            {
                return nil
            }
            generationRawValue &+= 1
            highestDeliveredEventID = 0
            let continuations = waiters.values.map(\.continuation)
            waiters.removeAll(keepingCapacity: false)
            return (Generation(rawValue: generationRawValue), continuations)
        }
        result?.continuations.forEach { $0.resume(returning: false) }
        return result?.generation
    }

    func recordDelivered(
        eventIDs: [FSEventStreamEventId],
        generation: Generation
    ) {
        let deliveredEventID = eventIDs.max() ?? 0
        guard deliveredEventID > 0 else { return }

        let completed: [CheckedContinuation<Bool, Never>] = lock.withLock {
            guard generation.rawValue == generationRawValue else { return [] }
            highestDeliveredEventID = max(highestDeliveredEventID, deliveredEventID)
            let completedIDs = waiters.compactMap { id, waiter in
                waiter.generation == generation && waiter.targetEventID <= highestDeliveredEventID ? id : nil
            }
            return completedIDs.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        }
        completed.forEach { $0.resume(returning: true) }
    }

    func waitUntilDelivered(
        _ targetEventID: FSEventStreamEventId,
        generation: Generation
    ) async -> Bool {
        guard targetEventID > 0 else {
            return generation == currentGeneration
        }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            let state = lock.withLock { () -> (generationCurrent: Bool, alreadyDelivered: Bool) in
                guard generation.rawValue == generationRawValue else { return (false, false) }
                guard highestDeliveredEventID < targetEventID else { return (true, true) }
                waiters[waiterID] = Waiter(
                    generation: generation,
                    targetEventID: targetEventID,
                    continuation: continuation
                )
                return (true, false)
            }
            guard state.generationCurrent else {
                continuation.resume(returning: false)
                return
            }
            if state.alreadyDelivered {
                continuation.resume(returning: true)
                return
            }
            scheduleDeadline(timeoutNanoseconds) { [weak self] in
                guard let self else { return }
                let timedOut = lock.withLock {
                    self.waiters.removeValue(forKey: waiterID)?.continuation
                }
                timedOut?.resume(returning: false)
            }
        }
    }
}
