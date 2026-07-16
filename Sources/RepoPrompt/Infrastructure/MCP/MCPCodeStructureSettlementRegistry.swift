import Foundation

/// Grants at most one same-window `get_code_structure` call permission to detach after
/// watchdog cleanup grace. A concurrent call remains legal but uses force-disconnect.
/// Once the eligible call actually detaches, later structure calls receive typed busy
/// until the generation-safe slot settles.
final class MCPCodeStructureSettlementRegistry: @unchecked Sendable {
    enum Admission {
        case detachEligible(Slot)
        case forceDisconnect
        case busy
    }

    enum CompletionDisposition: Equatable {
        case ignored
        case reserved
        case detached
    }

    struct Snapshot: Equatable {
        let activeCount: Int
        let detachedCount: Int
    }

    final class Slot: @unchecked Sendable {
        let windowID: Int
        let generation: UInt64
        let connectionID: UUID
        let invocationID: UUID

        private weak var registry: MCPCodeStructureSettlementRegistry?

        fileprivate init(
            registry: MCPCodeStructureSettlementRegistry,
            windowID: Int,
            generation: UInt64,
            connectionID: UUID,
            invocationID: UUID
        ) {
            self.registry = registry
            self.windowID = windowID
            self.generation = generation
            self.connectionID = connectionID
            self.invocationID = invocationID
        }

        @discardableResult
        func markDetached() -> Bool {
            registry?.markDetached(windowID: windowID, generation: generation) ?? false
        }

        @discardableResult
        func complete() -> CompletionDisposition {
            registry?.complete(windowID: windowID, generation: generation) ?? .ignored
        }

        deinit {
            _ = complete()
        }
    }

    private enum State: Equatable {
        case reserved
        case detached
    }

    private struct Entry {
        let generation: UInt64
        let connectionID: UUID
        let invocationID: UUID
        var state: State
    }

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 1
    private var entriesByWindowID: [Int: Entry] = [:]
    private var drainWaitersByWindowID: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func admit(
        windowID: Int,
        connectionID: UUID,
        invocationID: UUID
    ) -> Admission {
        lock.withLock {
            if let entry = entriesByWindowID[windowID] {
                switch entry.state {
                case .reserved:
                    return .forceDisconnect
                case .detached:
                    return .busy
                }
            }

            let generation = nextGeneration
            nextGeneration &+= 1
            if nextGeneration == 0 {
                nextGeneration = 1
            }
            entriesByWindowID[windowID] = Entry(
                generation: generation,
                connectionID: connectionID,
                invocationID: invocationID,
                state: .reserved
            )
            return .detachEligible(Slot(
                registry: self,
                windowID: windowID,
                generation: generation,
                connectionID: connectionID,
                invocationID: invocationID
            ))
        }
    }

    func snapshot(windowID: Int) -> Snapshot {
        lock.withLock {
            guard let entry = entriesByWindowID[windowID] else {
                return Snapshot(activeCount: 0, detachedCount: 0)
            }
            return Snapshot(
                activeCount: 1,
                detachedCount: entry.state == .detached ? 1 : 0
            )
        }
    }

    func awaitDrained(windowID: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard entriesByWindowID[windowID] != nil else { return true }
                drainWaitersByWindowID[windowID, default: []].append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func markDetached(windowID: Int, generation: UInt64) -> Bool {
        lock.withLock {
            guard var entry = entriesByWindowID[windowID],
                  entry.generation == generation
            else { return false }
            entry.state = .detached
            entriesByWindowID[windowID] = entry
            return true
        }
    }

    private func complete(
        windowID: Int,
        generation: UInt64
    ) -> CompletionDisposition {
        let result: (CompletionDisposition, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard let entry = entriesByWindowID[windowID],
                  entry.generation == generation
            else { return (.ignored, []) }

            entriesByWindowID.removeValue(forKey: windowID)
            let disposition: CompletionDisposition = entry.state == .detached ? .detached : .reserved
            return (disposition, drainWaitersByWindowID.removeValue(forKey: windowID) ?? [])
        }
        result.1.forEach { $0.resume() }
        return result.0
    }
}
