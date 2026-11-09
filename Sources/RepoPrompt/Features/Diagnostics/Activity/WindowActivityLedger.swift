import Foundation

/// Settings > Advanced reads this ledger without waiting on a busy filesystem actor.
final class WindowActivityLedger: @unchecked Sendable {
    enum Kind { case fileWatching }
    enum Phase { case began, ended }
    struct Snapshot: Equatable {
        let windowID: Int
        let sampledAt: UInt64
        let busyTotal: UInt64
        let busySince: UInt64?
        let lastEnded: UInt64?
        let root: String?
    }

    private struct State {
        var activeCount = 0
        var busySince: UInt64?
        var cumulativeBusyNs: UInt64 = 0
        var lastEndedNs: UInt64?
        var root: String?
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> UInt64
    private var windows: [Int: State] = [:]

    init(clock: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }) {
        self.clock = clock
    }

    func registerWindow(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        if windows[id] == nil { windows[id] = State() }
    }

    func removeWindow(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        windows.removeValue(forKey: id)
    }

    /// End only scopes whose begin returned true: registration may occur mid-batch.
    @discardableResult
    func record(windowID: Int, kind: Kind = .fileWatching, phase: Phase, root: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var state = windows[windowID] else { return false }
        let now = clock()
        switch phase {
        case .began:
            if state.activeCount == 0 {
                state.busySince = now
                state.root = root
            } else {
                // A single label cannot identify the survivor after overlap resolves.
                state.root = "Multiple roots"
            }
            state.activeCount += 1
        case .ended:
            guard state.activeCount > 0 else { return false }
            state.activeCount -= 1
            if state.activeCount == 0 {
                state.cumulativeBusyNs = Self.add(state.cumulativeBusyNs, Self.elapsed(state.busySince, now))
                state.busySince = nil
                state.lastEndedNs = now
            }
        }
        windows[windowID] = state
        return true
    }

    func snapshot() -> [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        return windows.map { id, state in
            Snapshot(
                windowID: id,
                sampledAt: now,
                busyTotal: Self.add(state.cumulativeBusyNs, Self.elapsed(state.busySince, now)),
                busySince: state.busySince,
                lastEnded: state.lastEndedNs,
                root: state.root
            )
        }
    }

    private static func elapsed(_ start: UInt64?, _ end: UInt64) -> UInt64 {
        guard let start, end >= start else { return 0 }
        return end - start
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}
