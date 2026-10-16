import Foundation

/// Protocol-neutral first-terminal-cause ownership. The transport supplies the physical
/// terminal record, while this value guarantees that only the first candidate can persist.
package final class MCPDomainTerminalClaimRegistry<Record: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var claims: [UUID: MCPDomainFirstTerminalClaim<Record>] = [:]

    package init() {}

    package subscript(connectionID: UUID) -> MCPDomainFirstTerminalClaim<Record>? {
        get { lock.withLock { claims[connectionID] } }
        set { lock.withLock { claims[connectionID] = newValue } }
    }

    @discardableResult
    package func removeValue(forKey connectionID: UUID) -> MCPDomainFirstTerminalClaim<Record>? {
        lock.withLock { claims.removeValue(forKey: connectionID) }
    }
}

package struct MCPDomainFirstTerminalClaim<Record: Equatable & Sendable>: Equatable, Sendable {
    package private(set) var record: Record?
    package private(set) var didPersist = false

    package init() {}

    package mutating func claim(_ candidate: Record) -> Record? {
        guard !didPersist else { return nil }
        if record == nil {
            record = candidate
        }
        return record
    }

    package mutating func markPersisted() {
        guard record != nil else { return }
        didPersist = true
    }
}
