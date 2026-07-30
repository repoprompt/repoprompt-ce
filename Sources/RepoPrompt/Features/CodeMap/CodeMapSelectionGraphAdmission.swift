import Foundation

struct CodeMapSelectionGraphAdmissionPolicy: Hashable {
    static let initial = Self(
        maximumActiveReservationCount: 1,
        maximumReservedBindingCount: 100_000
    )

    let maximumActiveReservationCount: Int
    let maximumReservedBindingCount: Int

    init(maximumActiveReservationCount: Int, maximumReservedBindingCount: Int) {
        precondition(maximumActiveReservationCount > 0)
        precondition(maximumReservedBindingCount > 0)
        self.maximumActiveReservationCount = maximumActiveReservationCount
        self.maximumReservedBindingCount = maximumReservedBindingCount
    }
}

enum CodeMapSelectionGraphAdmissionBusyReason: Hashable {
    case activeReservationCountLimit
    case reservedBindingCountLimit
}

enum CodeMapSelectionGraphAdmissionError: Error, Hashable {
    case busy(CodeMapSelectionGraphAdmissionBusyReason)
    case accountingOverflow
}

struct CodeMapSelectionGraphAdmissionAccounting: Equatable {
    let activeReservationCount: Int
    let reservedBindingCount: Int
    let busyRejectionCount: UInt64
    let hasFailedClosed: Bool
}

final class CodeMapSelectionGraphAdmissionPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var reservation: Reservation?

    fileprivate init(
        admission: CodeMapSelectionGraphAdmission,
        token: UUID,
        bindingCount: Int
    ) {
        reservation = Reservation(admission: admission, token: token, bindingCount: bindingCount)
    }

    func close() {
        let claimed = lock.withLock {
            defer { reservation = nil }
            return reservation
        }
        if let claimed {
            claimed.admission.release(token: claimed.token, bindingCount: claimed.bindingCount)
        }
    }

    deinit {
        close()
    }

    private struct Reservation {
        let admission: CodeMapSelectionGraphAdmission
        let token: UUID
        let bindingCount: Int
    }
}

final class CodeMapSelectionGraphAdmission: @unchecked Sendable {
    static let processWide = CodeMapSelectionGraphAdmission(policy: .initial)

    private let policy: CodeMapSelectionGraphAdmissionPolicy
    private let lock = NSLock()
    private var reservations: [UUID: Int] = [:]
    private var reservedBindingCount = 0
    private var busyRejectionCount: UInt64 = 0
    private var hasFailedClosed = false
    private var availabilityWaiters: [UUID: AvailabilityWaiter] = [:]

    init(policy: CodeMapSelectionGraphAdmissionPolicy = .initial) {
        self.policy = policy
    }

    func reserve(bindingCount: Int) throws -> CodeMapSelectionGraphAdmissionPermit {
        try lock.withLock {
            guard !hasFailedClosed, bindingCount >= 0 else {
                hasFailedClosed = true
                throw CodeMapSelectionGraphAdmissionError.accountingOverflow
            }
            let (nextActiveCount, activeOverflow) = reservations.count.addingReportingOverflow(1)
            let (nextBindingCount, bindingOverflow) = reservedBindingCount.addingReportingOverflow(bindingCount)
            guard !activeOverflow, !bindingOverflow else {
                hasFailedClosed = true
                throw CodeMapSelectionGraphAdmissionError.accountingOverflow
            }
            guard nextActiveCount <= policy.maximumActiveReservationCount else {
                incrementBusyRejectionCount()
                throw CodeMapSelectionGraphAdmissionError.busy(.activeReservationCountLimit)
            }
            guard nextBindingCount <= policy.maximumReservedBindingCount else {
                incrementBusyRejectionCount()
                throw CodeMapSelectionGraphAdmissionError.busy(.reservedBindingCountLimit)
            }

            var token = UUID()
            while reservations[token] != nil {
                token = UUID()
            }
            reservations[token] = bindingCount
            reservedBindingCount = nextBindingCount
            return CodeMapSelectionGraphAdmissionPermit(
                admission: self,
                token: token,
                bindingCount: bindingCount
            )
        }
    }

    func accounting() -> CodeMapSelectionGraphAdmissionAccounting {
        lock.withLock {
            CodeMapSelectionGraphAdmissionAccounting(
                activeReservationCount: reservations.count,
                reservedBindingCount: reservedBindingCount,
                busyRejectionCount: busyRejectionCount,
                hasFailedClosed: hasFailedClosed
            )
        }
    }

    func waitForAvailability(bindingCount: Int) async {
        let id = UUID()
        let stream = AsyncStream<Void> { continuation in
            let isAvailable = lock.withLock {
                guard !hasFailedClosed, canReserve(bindingCount: bindingCount) else {
                    availabilityWaiters[id] = AvailabilityWaiter(
                        bindingCount: bindingCount,
                        continuation: continuation
                    )
                    return false
                }
                return true
            }
            if isAvailable {
                continuation.yield()
                continuation.finish()
            } else {
                continuation.onTermination = { [weak self] _ in
                    self?.removeAvailabilityWaiter(id)
                }
            }
        }
        for await _ in stream {
            return
        }
    }

    fileprivate func release(token: UUID, bindingCount: Int) {
        let readyWaiters: [AsyncStream<Void>.Continuation] = lock.withLock {
            guard let recordedCount = reservations[token],
                  recordedCount == bindingCount,
                  recordedCount <= reservedBindingCount
            else {
                hasFailedClosed = true
                return []
            }
            reservations.removeValue(forKey: token)
            reservedBindingCount -= recordedCount
            let readyIDs = availabilityWaiters.compactMap { id, waiter in
                canReserve(bindingCount: waiter.bindingCount) ? id : nil
            }
            return readyIDs.compactMap { availabilityWaiters.removeValue(forKey: $0)?.continuation }
        }
        for continuation in readyWaiters {
            continuation.yield()
            continuation.finish()
        }
    }

    private func removeAvailabilityWaiter(_ id: UUID) {
        lock.withLock {
            _ = availabilityWaiters.removeValue(forKey: id)
        }
    }

    private func canReserve(bindingCount: Int) -> Bool {
        guard bindingCount >= 0 else { return false }
        let (nextActiveCount, activeOverflow) = reservations.count.addingReportingOverflow(1)
        let (nextBindingCount, bindingOverflow) = reservedBindingCount.addingReportingOverflow(bindingCount)
        return !activeOverflow && !bindingOverflow &&
            nextActiveCount <= policy.maximumActiveReservationCount &&
            nextBindingCount <= policy.maximumReservedBindingCount
    }

    private func incrementBusyRejectionCount() {
        if busyRejectionCount < .max {
            busyRejectionCount += 1
        }
    }

    private struct AvailabilityWaiter {
        let bindingCount: Int
        let continuation: AsyncStream<Void>.Continuation
    }
}
