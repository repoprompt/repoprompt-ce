import Foundation

/// Exact publication ownership for RepoPrompt tool cards. Connection FIFO is not an ownership
/// boundary: concurrent calls retain independent `(window, run, invocation)` records until the
/// synchronous call/result publication path unwinds.
final class MCPToolCardOwnershipLedger: @unchecked Sendable {
    struct Key: Hashable {
        let windowID: Int
        let runID: UUID
    }

    struct Snapshot: Equatable {
        let key: Key
        let invocationIDs: Set<UUID>
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var releaseAction: (() -> Void)?

        fileprivate init(releaseAction: @escaping () -> Void) {
            self.releaseAction = releaseAction
        }

        func release() {
            let action: (() -> Void)? = lock.withLock {
                defer { releaseAction = nil }
                return releaseAction
            }
            action?()
        }

        deinit {
            release()
        }
    }

    private struct Owner {
        let connectionID: UUID
        let toolName: String
    }

    private let lock = NSLock()
    private var ownersByKey: [Key: [UUID: Owner]] = [:]

    func begin(
        windowID: Int,
        runID: UUID,
        invocationID: UUID,
        connectionID: UUID,
        toolName: String
    ) -> Lease? {
        let key = Key(windowID: windowID, runID: runID)
        let inserted = lock.withLock { () -> Bool in
            guard ownersByKey[key]?[invocationID] == nil else { return false }
            ownersByKey[key, default: [:]][invocationID] = Owner(
                connectionID: connectionID,
                toolName: toolName
            )
            return true
        }
        guard inserted else { return nil }
        return Lease { [weak self] in
            self?.end(key: key, invocationID: invocationID)
        }
    }

    func contains(windowID: Int, runID: UUID, invocationID: UUID) -> Bool {
        lock.withLock {
            ownersByKey[Key(windowID: windowID, runID: runID)]?[invocationID] != nil
        }
    }

    func snapshots() -> [Snapshot] {
        lock.withLock {
            ownersByKey.map { key, owners in
                Snapshot(key: key, invocationIDs: Set(owners.keys))
            }
        }
    }

    private func end(key: Key, invocationID: UUID) {
        lock.withLock {
            ownersByKey[key]?.removeValue(forKey: invocationID)
            if ownersByKey[key]?.isEmpty == true {
                ownersByKey.removeValue(forKey: key)
            }
        }
    }
}
