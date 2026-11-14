/// Deterministic hysteresis. Drops apply immediately. Increases use the minimum
/// observed capacity over a recovery window, so unrelated fd jitter cannot keep
/// resetting CPU/memory recovery. No clocks/tasks are owned by this value.
package struct HostResourceRecovery {
    private var current: HostResourceCapacity?
    private var recoveryFloor: HostResourceCapacity?
    private var recoveryStartedAt: UInt64?
    package init() {}

    package mutating func ingest(_ next: HostResourceCapacity, now: UInt64) -> HostResourceCapacity {
        guard let previous = current else {
            current = next
            return next
        }
        let conservative = Self.minimum(previous, next)
        let increasing = next.total > previous.total || next.cpu > previous.cpu
            || next.io > previous.io || next.subprocess > previous.subprocess
            || next.background > previous.background || next.retainedContent > previous.retainedContent
            || next.descriptorBudget > previous.descriptorBudget
        if increasing {
            if let floor = recoveryFloor {
                recoveryFloor = Self.minimum(floor, next)
            } else {
                recoveryFloor = next
                recoveryStartedAt = now
            }
            if let started = recoveryStartedAt, now >= started, now - started >= 2_000_000_000 {
                let recovered = Self.minimum(next, recoveryFloor ?? next)
                current = recovered
                recoveryFloor = nil
                recoveryStartedAt = nil
                return recovered
            }
        } else {
            recoveryFloor = nil
            recoveryStartedAt = nil
        }
        current = conservative
        return conservative
    }

    private static func minimum(_ lhs: HostResourceCapacity, _ rhs: HostResourceCapacity) -> HostResourceCapacity {
        HostResourceCapacity(
            total: min(lhs.total, rhs.total), cpu: min(lhs.cpu, rhs.cpu),
            io: min(lhs.io, rhs.io), subprocess: min(lhs.subprocess, rhs.subprocess),
            background: min(lhs.background, rhs.background), connections: min(lhs.connections, rhs.connections),
            descriptorBudget: min(lhs.descriptorBudget, rhs.descriptorBudget),
            retainedContent: min(lhs.retainedContent, rhs.retainedContent)
        )
    }
}
