import Foundation

/// Owns same-window settlement state for detach-disposition tools outside ordinary lane accounting.
///
/// The fenced tools are `get_code_structure`, `read_file`, and `get_file_tree`. Every admitted
/// provider receives an invocation-scoped lease. Completion, cleanup-grace expiry, and external
/// cancellation transition that lease under this registry's single lock. Once any lease becomes
/// detaching, detached, abandoned, or force-disconnecting, later same-window detach-disposition
/// calls receive typed busy until every unsettled lease clears.
package final class MCPCodeStructureSettlementRegistry: @unchecked Sendable {
    package init() {}
    package enum BusyReason: Equatable, Sendable {
        case detached
        case abandoned
        case settling
    }

    package enum Admission: Sendable {
        case admitted(Slot)
        case busy(BusyReason)
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

        package init(activeCount: Int, detachedCount: Int) {
            self.activeCount = activeCount
            self.detachedCount = detachedCount
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

        package func resolveGraceExpiry() -> GraceExpiryDirective {
            registry?.resolveGraceExpiry(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID
            ) ?? .settled
        }

        package func activateDetach() -> DetachActivationDirective {
            registry?.activateDetach(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID
            ) ?? .notActivated
        }

        package func cancel() -> CancellationDirective {
            registry?.cancel(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID
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
        var state: State
    }

    private let lock = NSLock()
    private var entriesByWindowID: [Int: [UUID: Entry]] = [:]
    private var drainWaitersByWindowID: [Int: [CheckedContinuation<Void, Never>]] = [:]

    package func admit(
        windowID: Int,
        connectionID: UUID,
        invocationID: UUID
    ) -> Admission {
        lock.withLock {
            let entries = entriesByWindowID[windowID, default: [:]]
            if entries.values.contains(where: \.state.blocksAdmission) {
                return .busy(Self.busyReason(for: entries.values))
            }

            let leaseID = UUID()
            entriesByWindowID[windowID, default: [:]][leaseID] = Entry(
                leaseID: leaseID,
                connectionID: connectionID,
                invocationID: invocationID,
                state: .reserved
            )
            return .admitted(Slot(
                registry: self,
                windowID: windowID,
                leaseID: leaseID,
                connectionID: connectionID,
                invocationID: invocationID
            ))
        }
    }

    package func snapshot(windowID: Int) -> Snapshot {
        lock.withLock {
            let entries = entriesByWindowID[windowID, default: [:]]
            return Snapshot(
                activeCount: entries.count,
                detachedCount: entries.values.count { $0.state.isZombie }
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
        invocationID: UUID
    ) -> GraceExpiryDirective {
        lock.withLock {
            guard var entries = entriesByWindowID[windowID],
                  var entry = entries[leaseID],
                  entry.invocationID == invocationID
            else { return .settled }

            switch entry.state {
            case .reserved:
                let otherUnsettled = entries.values.contains {
                    $0.leaseID != leaseID && $0.state.blocksAdmission
                }
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
        invocationID: UUID
    ) -> CancellationDirective {
        let result: (CancellationDirective, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard var entries = entriesByWindowID[windowID],
                  var entry = entries[leaseID],
                  entry.invocationID == invocationID
            else { return (.settled, []) }

            switch entry.state {
            case .reserved:
                entry.state = .abandoned
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

    private static func busyReason(
        for entries: Dictionary<UUID, Entry>.Values
    ) -> BusyReason {
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
