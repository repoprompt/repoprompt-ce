import Foundation

/// Process-wide physical-work admission. Outer calls must NOT hold a lease while awaiting
/// children that acquire one. No TaskLocal reentrancy bypass: children inherit task locals.
package final class HostResourceBudget: @unchecked Sendable {
    package enum Kind: Hashable {
        case cpu, io, subprocess
        /// Memory reservation, not a physical worker. Acquire BEFORE fetching content,
        /// then release after matching; it may span sequential I/O and CPU leases.
        case retainedContent
    }

    package enum AdmissionError: Error { case queueFull }
    package typealias Lease = MCPDomainToolResourceAdmissionController.Lease
    package static let shared: HostResourceBudget = {
        let budget = HostResourceBudget(capacity: HostResourceCapacity.resolve(
            HostResourceMonitor.sample(memoryPressure: HostResourceMonitor.currentMemoryPressure(fallback: .normal))
        ))
        let monitor = HostResourceMonitor { [weak budget] in budget?.updateCapacity($0) }
        budget.lock.withLock { budget.monitor = monitor }
        return budget
    }()

    package struct Snapshot: Equatable {
        package let capacity: HostResourceCapacity
        package let active: Int
        package let activeByKind: [Kind: Int]
        package let activeBackground: Int
        package let waiting: Int
        package let peakActive: Int
        package let granted: UInt64
        package let waitNanoseconds: UInt64
        package var activeDescriptorUnits: Int {
            (activeByKind[.io] ?? 0) * HostResourceCapacity.ioDescriptorCost
                + (activeByKind[.subprocess] ?? 0) * HostResourceCapacity.subprocessDescriptorCost
        }
    }

    private final class Request: @unchecked Sendable {
        enum State { case initial, waiting, granted, cancelled }
        let kind: Kind
        let background: Bool
        let enqueuedAt = DispatchTime.now().uptimeNanoseconds
        var state = State.initial // all mutable state protected by the budget lock
        var continuation: CheckedContinuation<Lease, Error>?
        init(kind: Kind, background: Bool) {
            self.kind = kind
            self.background = background
        }
    }

    private let lock = NSLock()
    private var capacity: HostResourceCapacity
    private let maximumWaiters: Int
    private var requests: [Request] = []
    private var active = 0
    private var activeByKind: [Kind: Int] = [:]
    private var activeBackground = 0
    private var peakActive = 0
    private var granted: UInt64 = 0
    private var waitNanoseconds: UInt64 = 0
    private var monitor: HostResourceMonitor?
    private var reportedBusy = false

    package init(capacity: HostResourceCapacity, maximumWaiters: Int = 1024) {
        precondition(maximumWaiters >= 0)
        self.capacity = capacity
        self.maximumWaiters = maximumWaiters
    }

    package func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                capacity: capacity,
                active: active,
                activeByKind: activeByKind,
                activeBackground: activeBackground,
                waiting: requests.count,
                peakActive: peakActive,
                granted: granted,
                waitNanoseconds: waitNanoseconds
            )
        }
    }

    /// Shrinking a capacity never revokes physical ownership. A recovery drains the queue,
    /// even when no active worker remains to release a permit (e.g. descriptor exhaustion).
    package func updateCapacity(_ next: HostResourceCapacity) {
        let handoffs = lock.withLock {
            capacity = next
            return drain()
        }
        resume(handoffs)
    }

    package func acquire(
        _ kind: Kind,
        background: Bool = false,
        deadline: MCPDomainAdmissionDeadline? = nil
    ) async throws -> Lease {
        guard let deadline else { return try await acquireWithoutDeadline(kind, background: background) }
        // A start deadline bounds waiting, not subsequent free-capacity work in an
        // already-admitted sequence. Cancellation still fences every immediate grant.
        try Task.checkCancellation()
        let (immediate, handoffs) = lock.withLock { () -> (Lease?, [Handoff]) in
            let handoffs = drain()
            let request = Request(kind: kind, background: background)
            // Older infeasible classes (e.g. paused background work) must not turn
            // free foreground capacity into an artificial deadline failure.
            return (canGrant(request) ? grant(request) : nil, handoffs)
        }
        resume(handoffs)
        if let immediate {
            do { try Task.checkCancellation()
                return immediate
            } catch { immediate.release()
                throw error
            }
        }
        try deadline.check()
        return try await withThrowingTaskGroup(of: Lease.self) { group in
            group.addTask { try await self.acquireWithoutDeadline(kind, background: background) }
            group.addTask { try await deadline.waitUntilExpired() }
            do {
                guard let lease = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                try? await group.waitForAll()
                do { try deadline.check()
                    return lease
                } catch { lease.release()
                    throw error
                }
            } catch {
                group.cancelAll()
                try? await group.waitForAll()
                throw error
            }
        }
    }

    package func withPermit<Value>(
        _ kind: Kind,
        background: Bool = false,
        _ body: () async throws -> Value
    ) async throws -> Value {
        let lease = try await acquire(kind, background: background)
        defer { lease.release() }
        try Task.checkCancellation()
        return try await body()
    }

    private func acquireWithoutDeadline(_ kind: Kind, background: Bool) async throws -> Lease {
        try Task.checkCancellation()
        let request = Request(kind: kind, background: background)
        let lease: Lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let (result, handoffs): (Result<Lease, Error>?, [Handoff]) = lock.withLock {
                    if request.state == .cancelled || Task.isCancelled {
                        request.state = .cancelled
                        return (.failure(CancellationError()), [])
                    }
                    if requests.isEmpty, canGrant(request) {
                        return (.success(grant(request)), [])
                    }
                    guard requests.count < maximumWaiters else { return (.failure(AdmissionError.queueFull), []) }
                    request.state = .waiting
                    request.continuation = continuation
                    requests.append(request)
                    return (nil, drain())
                }
                if let result { continuation.resume(with: result) }
                resume(handoffs)
            }
        } onCancel: {
            self.cancel(request)
        }
        do { try Task.checkCancellation()
            return lease
        } catch { lease.release()
            throw error
        }
    }

    private func reportBusyLocked() {
        let busy = active > 0 || !requests.isEmpty || (activeByKind[.retainedContent] ?? 0) > 0
        guard busy != reportedBusy else { return }
        reportedBusy = busy
        monitor?.setBusy(busy)
    }

    private func canGrant(_ request: Request) -> Bool {
        if request.kind == .retainedContent {
            return (activeByKind[.retainedContent] ?? 0) < capacity.retainedContent
        }
        guard active < capacity.total else { return false }
        let descriptorCost: Int = switch request.kind {
        case .io: HostResourceCapacity.ioDescriptorCost
        case .subprocess: HostResourceCapacity.subprocessDescriptorCost
        case .cpu, .retainedContent: 0
        }
        if descriptorCost > 0 {
            let used = (activeByKind[.io] ?? 0) * HostResourceCapacity.ioDescriptorCost
                + (activeByKind[.subprocess] ?? 0) * HostResourceCapacity.subprocessDescriptorCost
            guard used + descriptorCost <= capacity.descriptorBudget else { return false }
        }
        if request.background, activeBackground >= capacity.background { return false }
        let classLimit = switch request.kind {
        case .cpu: capacity.cpu
        case .io: capacity.io
        case .subprocess: capacity.subprocess
        case .retainedContent: capacity.retainedContent
        }
        // CPU and Git subprocesses share the CPU ceiling too, not two independent CPU pools.
        if request.kind != .io,
           (activeByKind[.cpu] ?? 0) + (activeByKind[.subprocess] ?? 0) >= capacity.cpu { return false }
        return (activeByKind[request.kind] ?? 0) < classLimit
    }

    private func grant(_ request: Request) -> Lease {
        request.state = .granted
        if request.kind != .retainedContent { active += 1 }
        activeByKind[request.kind, default: 0] += 1
        if request.background, request.kind != .retainedContent { activeBackground += 1 }
        peakActive = max(peakActive, active)
        granted &+= 1
        waitNanoseconds &+= DispatchTime.now().uptimeNanoseconds - request.enqueuedAt
        reportBusyLocked()
        let kind = request.kind
        let background = request.background && request.kind != .retainedContent
        return Lease { [self] in release(kind, background: background) }
    }

    private typealias Handoff = (CheckedContinuation<Lease, Error>, Lease)

    /// FIFO among feasible requests; a descriptor-blocked I/O request cannot block CPU work.
    private func drain() -> [Handoff] {
        var handoffs: [Handoff] = []
        var index = 0
        while index < requests.count {
            let request = requests[index]
            guard canGrant(request) else { index += 1
                continue
            }
            requests.remove(at: index)
            if let continuation = request.continuation {
                request.continuation = nil
                handoffs.append((continuation, grant(request)))
            }
        }
        reportBusyLocked()
        return handoffs
    }

    private func resume(_ handoffs: [Handoff]) {
        for (continuation, lease) in handoffs {
            continuation.resume(returning: lease)
        }
    }

    private func release(_ kind: Kind, background: Bool) {
        let handoffs = lock.withLock {
            if kind != .retainedContent { active -= 1 }
            activeByKind[kind, default: 0] -= 1
            if activeByKind[kind] == 0 { activeByKind.removeValue(forKey: kind) }
            if background { activeBackground -= 1 }
            return drain()
        }
        resume(handoffs)
    }

    private func cancel(_ request: Request) {
        let result: (CheckedContinuation<Lease, Error>?, [Handoff]) = lock.withLock {
            switch request.state {
            case .initial:
                request.state = .cancelled
                return (nil, [])
            case .waiting:
                requests.removeAll { $0 === request }
                request.state = .cancelled
                let continuation = request.continuation
                request.continuation = nil
                return (continuation, drain())
            case .granted, .cancelled:
                return (nil, []) // A granted lease is released only by its physical owner.
            }
        }
        result.0?.resume(throwing: CancellationError())
        resume(result.1)
    }
}
