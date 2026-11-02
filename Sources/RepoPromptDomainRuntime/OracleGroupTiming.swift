import Foundation
import os

/// Optional metadata must never invalidate an otherwise valid canonical outcome.
package func normalizedOracleElapsed(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0,
          Int(exactly: value.rounded(.down)) != nil else { return nil }
    return value == 0 ? 0 : value
}

/// One process-local measurement association. Clock closures must be bounded and nonreentrant.
/// Notifications run outside the lock and must only schedule display invalidation.
package final class OracleGroupTiming: Sendable, Equatable {
    package enum Slot: Equatable, Sendable {
        case group
        case lane(OracleLaneID)
    }

    package enum Sample: Equatable, Sendable {
        case unavailable
        case running(Double)
        case frozen(Double)

        package var elapsedSeconds: Double? {
            switch self {
            case .unavailable: nil
            case let .running(value), let .frozen(value): value
            }
        }
    }

    package struct Snapshot: Equatable, Sendable {
        package let revision: UInt64
        package let sample: Sample
    }

    private enum Measurement: Sendable {
        case unentered
        case unavailable
        case running(ContinuousClock.Instant)
        case frozen(Double)
    }

    private struct State: Sendable {
        var slots: [Measurement]
        var revision: UInt64 = 0
        var closed = false
    }

    package let invocationID: UUID
    package let group: OracleGroupDescriptor
    package var groupID: OracleGroupID {
        group.id
    }

    package let turnID: OracleTurnID
    package let laneIDs: [OracleLaneID]
    private let state: OSAllocatedUnfairLock<State>
    private let now: @Sendable () -> ContinuousClock.Instant
    private let onChange: @Sendable (OracleGroupTiming) -> Void

    package init(
        invocationID: UUID,
        group: OracleGroupDescriptor,
        turnID: OracleTurnID,
        laneIDs: [OracleLaneID],
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        onChange: @escaping @Sendable (OracleGroupTiming) -> Void = { _ in }
    ) {
        precondition((2 ... OracleRosterContract.maximumCount).contains(laneIDs.count))
        precondition(group.size == laneIDs.count && laneIDs.map(\.index) == Array(laneIDs.indices))
        self.invocationID = invocationID
        self.group = group
        self.turnID = turnID
        self.laneIDs = laneIDs
        self.now = now
        self.onChange = onChange
        state = OSAllocatedUnfairLock(initialState: State(slots: Array(repeating: .unentered, count: laneIDs.count + 1)))
    }

    package static func == (lhs: OracleGroupTiming, rhs: OracleGroupTiming) -> Bool {
        lhs === rhs
    }

    private func index(_ slot: Slot) -> Int? {
        switch slot {
        case .group: 0
        case let .lane(id): laneIDs.firstIndex(of: id).map { $0 + 1 }
        }
    }

    private func elapsed(since start: ContinuousClock.Instant) -> Double? {
        let components = start.duration(to: now()).components
        return normalizedOracleElapsed(Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    package func read(_ slot: Slot) -> Snapshot {
        state.withLock { state in
            let sample: Sample = if let index = index(slot) {
                switch state.slots[index] {
                case .unentered, .unavailable: .unavailable
                case let .running(start): elapsed(since: start).map(Sample.running) ?? .unavailable
                case let .frozen(value): .frozen(value)
                }
            } else {
                .unavailable
            }
            return Snapshot(revision: state.revision, sample: sample)
        }
    }

    package func start(_ slot: Slot) {
        let changed = state.withLock { state in
            guard !state.closed, let index = index(slot), case .unentered = state.slots[index] else { return false }
            state.slots[index] = .running(now())
            state.revision &+= 1
            return true
        }
        if changed { onChange(self) }
    }

    @discardableResult
    package func freeze(_ slot: Slot) -> Double? {
        let (value, changed): (Double?, Bool) = state.withLock { state in
            guard let index = index(slot) else { return (nil, false) }
            switch state.slots[index] {
            case let .frozen(value): return (value, false)
            case .unentered, .unavailable: return (nil, false)
            case let .running(start):
                let value = elapsed(since: start)
                state.slots[index] = value.map(Measurement.frozen) ?? .unavailable
                state.revision &+= 1
                return (value, true)
            }
        }
        if changed { onChange(self) }
        return value
    }

    package func invalidateRunning() {
        let changed = state.withLock { state in
            guard !state.closed else { return false }
            state.closed = true
            state.slots = state.slots.map { slot in
                if case .frozen = slot { return slot }
                return .unavailable
            }
            state.revision &+= 1
            return true
        }
        if changed { onChange(self) }
    }
}
