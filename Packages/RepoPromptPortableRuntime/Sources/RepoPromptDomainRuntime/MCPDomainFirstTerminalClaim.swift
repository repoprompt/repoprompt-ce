import Foundation

/// Protocol-neutral first-terminal-cause ownership. The transport supplies the physical
/// terminal record, while this value guarantees that only the first candidate can persist.
public final class MCPDomainTerminalClaimRegistry<Record: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var claims: [UUID: MCPDomainFirstTerminalClaim<Record>] = [:]

    public init() {}

    public subscript(connectionID: UUID) -> MCPDomainFirstTerminalClaim<Record>? {
        get { lock.withLock { claims[connectionID] } }
        set { lock.withLock { claims[connectionID] = newValue } }
    }

    @discardableResult
    public func removeValue(forKey connectionID: UUID) -> MCPDomainFirstTerminalClaim<Record>? {
        lock.withLock { claims.removeValue(forKey: connectionID) }
    }
}

public struct MCPDomainFirstTerminalClaim<Record: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var record: Record?
    public private(set) var didPersist = false

    public init() {}

    public mutating func claim(_ candidate: Record) -> Record? {
        guard !didPersist else { return nil }
        if record == nil {
            record = candidate
        }
        return record
    }

    public mutating func markPersisted() {
        guard record != nil else { return }
        didPersist = true
    }
}
