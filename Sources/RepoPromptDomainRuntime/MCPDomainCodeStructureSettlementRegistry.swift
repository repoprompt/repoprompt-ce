import Foundation

/// Owns same-window settlement state for detach-disposition tools outside ordinary lane accounting.
///
/// The fenced tools are `get_code_structure`, `read_file`, and `get_file_tree`. Every admitted
/// provider receives an invocation-scoped lease. Completion, cleanup-grace expiry, and external
/// cancellation transition that lease under this registry's single lock. A blocking lease fences
/// later same-window detach-disposition calls for a bounded recovery horizon. After that horizon,
/// one still-running provider may remain tracked without blocking; its exact lease still owns completion.
package final class MCPCodeStructureSettlementRegistry: @unchecked Sendable {
    package static let recoveryHorizon = Duration.seconds(30)
    package static let releasedProviderLimit = 1

    package init() {}

    package enum BusyReason: Equatable, Sendable {
        case detached
        case abandoned
        case settling
        case releasedProviderLimitReached
    }

    package struct BusyContext: Equatable, Sendable {
        package let reason: BusyReason
        package let originToolName: String
        package let originInvocationID: UUID
        package let originConnectionID: UUID
        package let detachedAge: Duration
        package let recoveryAfter: Duration?
        package let handlerPhase: String?
        package let releasedProviderCount: Int
    }

    package enum Admission: Sendable {
        case admitted(Slot)
        case busy(BusyContext)
    }

    package enum CompletionDirective: Equatable, Sendable {
        case deliver
        case deferred
        case settleDetached
        case settleAbandoned
        case settleForceDisconnected
        case ignored
    }

    package enum GraceExpiryDirective: Equatable, Sendable {
        case detach
        case forceDisconnect
        case settled
    }

    package enum DetachActivationDirective: Equatable, Sendable {
        case activated
        case settled(MCPToolExecutionSettlement)
        case notActivated
    }

    package enum CancellationDirective: Equatable, Sendable {
        case abandoned(MCPToolExecutionSettlement?)
        case alreadyDetached
        case forceDisconnect(MCPToolExecutionSettlement?)
        case settled
    }

    package enum EarlyExitDisposition: Equatable, Sendable {
        case released
        case retained
        case alreadySettled
    }

    package struct Snapshot: Equatable, Sendable {
        package let activeCount: Int
        package let detachedCount: Int
        package let releasedCount: Int

        package init(activeCount: Int, detachedCount: Int, releasedCount: Int = 0) {
            self.activeCount = activeCount
            self.detachedCount = detachedCount
            self.releasedCount = releasedCount
        }
    }

    package final class Slot: @unchecked Sendable {
        package let windowID: Int
        package let leaseID: UUID
        package let connectionID: UUID
        package let invocationID: UUID

        private weak var registry: MCPCodeStructureSettlementRegistry?

        fileprivate init(
            registry: MCPCodeStructureSettlementRegistry,
            windowID: Int,
            leaseID: UUID,
            connectionID: UUID,
            invocationID: UUID
        ) {
            self.registry = registry
            self.windowID = windowID
            self.leaseID = leaseID
            self.connectionID = connectionID
            self.invocationID = invocationID
        }

        package func recordCompletion(_ settlement: MCPToolExecutionSettlement) -> CompletionDirective {
            registry?.recordCompletion(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID,
                settlement: settlement
            ) ?? .ignored
        }

        package func resolveGraceExpiry(now: Duration) -> GraceExpiryDirective {
            registry?.resolveGraceExpiry(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID,
                now: now
            ) ?? .settled
        }

        package func activateDetach() -> DetachActivationDirective {
            registry?.activateDetach(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID
            ) ?? .notActivated
        }

        package func cancel(now: Duration) -> CancellationDirective {
            registry?.cancel(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID,
                now: now
            ) ?? .settled
        }

        @discardableResult
        package func closeBeforeExecutionExit() -> EarlyExitDisposition {
            registry?.closeBeforeExecutionExit(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID
            ) ?? .alreadySettled
        }

        deinit {
            #if DEBUG
                registry?.assertLeaseReleased(
                    windowID: windowID,
                    leaseID: leaseID,
                    invocationID: invocationID
                )
            #endif
        }
    }

    fileprivate enum State: Equatable {
        case reserved
        case detaching(MCPToolExecutionSettlement?)
        case detached
        case abandoned
        case forceDisconnecting
    }

    private struct Entry {
        let leaseID: UUID
        let connectionID: UUID
        let invocationID: UUID
        let toolName: String
        let handlerPhase: @Sendable () -> String?
        var state: State
        var blockingSince: Duration?
        var isReleased: Bool

        var blocksAdmission: Bool {
            state.blocksAdmission && !isReleased
        }
    }

    private struct BusyCandidate {
        let reason: BusyReason
        let entry: Entry
        let detachedAge: Duration
        let recoveryAfter: Duration?
        let releasedProviderCount: Int
    }

    private enum AdmissionDecision {
        case admitted(Slot)
        case busy(BusyCandidate)
    }

    private let lock = NSLock()
    private var entriesByWindowID: [Int: [UUID: Entry]] = [:]
    private var drainWaitersByWindowID: [Int: [CheckedContinuation<Void, Never>]] = [:]

    package func admit(
        windowID: Int,
        connectionID: UUID,
        invocationID: UUID,
        toolName: String,
        now: Duration,
        handlerPhase: @escaping @Sendable () -> String?
    ) -> Admission {
        let decision: AdmissionDecision = lock.withLock {
            var entries = entriesByWindowID[windowID, default: [:]]
            let blockingEntries = entries.values.filter(\.blocksAdmission)
            if !blockingEntries.isEmpty {
                let releasedProviderCount = entries.values.count(where: \.isReleased)
                let origin = Self.oldestEntry(in: blockingEntries)
                let blockingSince = origin.blockingSince
                precondition(blockingSince != nil, "Blocking settlement entry requires an origin timestamp")
                let age = Self.elapsed(since: blockingSince!, now: now)

                guard releasedProviderCount + blockingEntries.count <= Self.releasedProviderLimit else {
                    return .busy(BusyCandidate(
                        reason: .releasedProviderLimitReached,
                        entry: origin,
                        detachedAge: age,
                        recoveryAfter: nil,
                        releasedProviderCount: releasedProviderCount
                    ))
                }

                let recoveryAfter = max(.zero, Self.recoveryHorizon - age)
                guard recoveryAfter == .zero else {
                    return .busy(BusyCandidate(
                        reason: Self.busyReason(for: blockingEntries),
                        entry: origin,
                        detachedAge: age,
                        recoveryAfter: recoveryAfter,
                        releasedProviderCount: releasedProviderCount
                    ))
                }

                entries[origin.leaseID]?.isReleased = true
                entriesByWindowID[windowID] = entries
            }

            let leaseID = UUID()
            entries[leaseID] = Entry(
                leaseID: leaseID,
                connectionID: connectionID,
                invocationID: invocationID,
                toolName: toolName,
                handlerPhase: handlerPhase,
                state: .reserved,
                blockingSince: nil,
                isReleased: false
            )
            entriesByWindowID[windowID] = entries
            return .admitted(Slot(
                registry: self,
                windowID: windowID,
                leaseID: leaseID,
                connectionID: connectionID,
                invocationID: invocationID
            ))
        }

        switch decision {
        case let .admitted(slot):
            return .admitted(slot)
        case let .busy(candidate):
            return .busy(BusyContext(
                reason: candidate.reason,
                originToolName: candidate.entry.toolName,
                originInvocationID: candidate.entry.invocationID,
                originConnectionID: candidate.entry.connectionID,
                detachedAge: candidate.detachedAge,
                recoveryAfter: candidate.recoveryAfter,
                handlerPhase: candidate.entry.handlerPhase(),
                releasedProviderCount: candidate.releasedProviderCount
            ))
        }
    }

    package func snapshot(windowID: Int) -> Snapshot {
        lock.withLock {
            let entries = entriesByWindowID[windowID, default: [:]]
            return Snapshot(
                activeCount: entries.count,
                detachedCount: entries.values.count { $0.state.isZombie },
                releasedCount: entries.values.count(where: \.isReleased)
            )
        }
    }

    package func awaitDrained(windowID: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard entriesByWindowID[windowID]?.isEmpty == false else { return true }
                drainWaitersByWindowID[windowID, default: []].append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func recordCompletion(
        windowID: Int,
        leaseID: UUID,
        invocationID: UUID,
        settlement: MCPToolExecutionSettlement
    ) -> CompletionDirective {
        transition(windowID: windowID, leaseID: leaseID, invocationID: invocationID) { entry in
            switch entry.state {
            case .reserved:
                return (.remove, .deliver)
            case .detaching:
                entry.state = .detaching(settlement)
                return (.retain(entry), .deferred)
            case .detached:
                return (.remove, .settleDetached)
            case .abandoned:
                return (.remove, .settleAbandoned)
            case .forceDisconnecting:
                return (.remove, .settleForceDisconnected)
            }
        } ?? .ignored
    }

    private func resolveGraceExpiry(
        windowID: Int,
        leaseID: UUID,
        invocationID: UUID,
        now: Duration
    ) -> GraceExpiryDirective {
        lock.withLock {
            guard var entries = entriesByWindowID[windowID],
                  var entry = entries[leaseID],
                  entry.invocationID == invocationID
            else { return .settled }

            switch entry.state {
            case .reserved:
                let otherUnsettled = entries.values.contains {
                    $0.leaseID != leaseID && $0.blocksAdmission
                }
                entry.blockingSince = now
                if otherUnsettled {
                    entry.state = .forceDisconnecting
                    entries[leaseID] = entry
                    entriesByWindowID[windowID] = entries
                    return .forceDisconnect
                }
                entry.state = .detaching(nil)
                entries[leaseID] = entry
                entriesByWindowID[windowID] = entries
                return .detach
            case .detaching, .detached:
                return .detach
            case .abandoned:
                return .settled
            case .forceDisconnecting:
                return .forceDisconnect
            }
        }
    }

    private func activateDetach(
        windowID: Int,
        leaseID: UUID,
        invocationID: UUID
    ) -> DetachActivationDirective {
        let result: (DetachActivationDirective, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard var entries = entriesByWindowID[windowID],
                  var entry = entries[leaseID],
                  entry.invocationID == invocationID
            else { return (.notActivated, []) }

            guard case let .detaching(settlement) = entry.state else {
                return (.notActivated, [])
            }
            if let settlement {
                entries.removeValue(forKey: leaseID)
                return (
                    .settled(settlement),
                    storeEntriesAndTakeWaiters(entries, windowID: windowID)
                )
            }
            entry.state = .detached
            entries[leaseID] = entry
            entriesByWindowID[windowID] = entries
            return (.activated, [])
        }
        result.1.forEach { $0.resume() }
        return result.0
    }

    private func cancel(
        windowID: Int,
        leaseID: UUID,
        invocationID: UUID,
        now: Duration
    ) -> CancellationDirective {
        let result: (CancellationDirective, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard var entries = entriesByWindowID[windowID],
                  var entry = entries[leaseID],
                  entry.invocationID == invocationID
            else { return (.settled, []) }

            switch entry.state {
            case .reserved:
                entry.state = .abandoned
                entry.blockingSince = now
                entries[leaseID] = entry
                entriesByWindowID[windowID] = entries
                return (.abandoned(nil), [])

            case let .detaching(settlement):
                if let settlement {
                    entries.removeValue(forKey: leaseID)
                    let waiters = storeEntriesAndTakeWaiters(entries, windowID: windowID)
                    return (.abandoned(settlement), waiters)
                }
                entry.state = .abandoned
                entries[leaseID] = entry
                entriesByWindowID[windowID] = entries
                return (.abandoned(nil), [])

            case .detached:
                return (.alreadyDetached, [])

            case .abandoned:
                return (.abandoned(nil), [])

            case .forceDisconnecting:
                return (.forceDisconnect(nil), [])
            }
        }
        result.1.forEach { $0.resume() }
        return result.0
    }

    private func closeBeforeExecutionExit(
        windowID: Int,
        leaseID: UUID,
        invocationID: UUID
    ) -> EarlyExitDisposition {
        let result: (EarlyExitDisposition, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard var entries = entriesByWindowID[windowID],
                  let entry = entries[leaseID],
                  entry.invocationID == invocationID
            else { return (.alreadySettled, []) }

            guard case .reserved = entry.state else {
                return (.retained, [])
            }
            entries.removeValue(forKey: leaseID)
            return (
                .released,
                storeEntriesAndTakeWaiters(entries, windowID: windowID)
            )
        }
        result.1.forEach { $0.resume() }
        return result.0
    }

    private enum Mutation {
        case retain(Entry)
        case remove
    }

    private func transition<Result>(
        windowID: Int,
        leaseID: UUID,
        invocationID: UUID,
        mutation: (inout Entry) -> (Mutation, Result)
    ) -> Result? {
        let result: (Result?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard var entries = entriesByWindowID[windowID],
                  var entry = entries[leaseID],
                  entry.invocationID == invocationID
            else { return (nil, []) }

            let (entryMutation, value) = mutation(&entry)
            switch entryMutation {
            case let .retain(updated):
                entries[leaseID] = updated
            case .remove:
                entries.removeValue(forKey: leaseID)
            }
            return (
                value,
                storeEntriesAndTakeWaiters(entries, windowID: windowID)
            )
        }
        result.1.forEach { $0.resume() }
        return result.0
    }

    private func storeEntriesAndTakeWaiters(
        _ entries: [UUID: Entry],
        windowID: Int
    ) -> [CheckedContinuation<Void, Never>] {
        if entries.isEmpty {
            entriesByWindowID.removeValue(forKey: windowID)
            return drainWaitersByWindowID.removeValue(forKey: windowID) ?? []
        }
        entriesByWindowID[windowID] = entries
        return []
    }

    private static func busyReason(for entries: [Entry]) -> BusyReason {
        if entries.contains(where: {
            if case .abandoned = $0.state { return true }
            return false
        }) {
            return .abandoned
        }
        if entries.contains(where: \.state.isZombie) {
            return .detached
        }
        return .settling
    }

    private static func oldestEntry(in entries: [Entry]) -> Entry {
        precondition(!entries.isEmpty, "Busy settlement context requires an originating entry")
        return entries.min { lhs, rhs in
            let lhsBlockingSince = lhs.blockingSince
            let rhsBlockingSince = rhs.blockingSince
            precondition(
                lhsBlockingSince != nil && rhsBlockingSince != nil,
                "Blocking settlement entries require origin timestamps"
            )
            if lhsBlockingSince == rhsBlockingSince {
                return lhs.invocationID.uuidString < rhs.invocationID.uuidString
            }
            return lhsBlockingSince! < rhsBlockingSince!
        }!
    }

    private static func elapsed(since start: Duration, now: Duration) -> Duration {
        max(.zero, now - start)
    }

    #if DEBUG
        private func assertLeaseReleased(
            windowID: Int,
            leaseID: UUID,
            invocationID: UUID
        ) {
            let leaked = lock.withLock {
                entriesByWindowID[windowID]?[leaseID]?.invocationID == invocationID
            }
            assert(!leaked, "Leaked get_code_structure settlement lease \(invocationID)")
        }
    #endif
}

private extension MCPCodeStructureSettlementRegistry.State {
    var isZombie: Bool {
        switch self {
        case .detaching, .detached, .abandoned:
            true
        case .reserved, .forceDisconnecting:
            false
        }
    }

    var blocksAdmission: Bool {
        switch self {
        case .reserved:
            false
        case .detaching, .detached, .abandoned, .forceDisconnecting:
            true
        }
    }
}
