import Foundation
import os

/// App-owned native adapters retain MCP resources without adding MCP types to provider packages.
/// This is cleanup ownership only; accepting a receipt never grants command or send admission.
protocol MCPRunRoutingCleanupRetaining: Actor {
    func retainRoutingCleanup(_ receipt: MCPRunRoutingCleanupReceipt) -> Bool
}

/// Originating cleanup only. This is not command admission, a current writer, or a durable save
/// acknowledgement. The registration owner issues it in the same actor turn as policy installation.
struct MCPRunRoutingCleanupReceipt: Equatable {
    let managerIdentity: ObjectIdentifier
    let policyID: UUID
    let runID: UUID
    let routeID: Int
    let routingAuthorityGeneration: UInt64
    let routingWaitGeneration: UUID?
    /// Retain the original resource owner. Cleanup must never resolve a current window/host by ID.
    let routeOwner: MCPHostRouteResources?
    /// Metadata retained by the mapping owner must not retain that owner back through this receipt.
    struct MappingOwnership {
        let policyID: UUID
        private let consumed = OSAllocatedUnfairLock(initialState: false)
        init(policyID: UUID) {
            self.policyID = policyID
        }

        var isConsumed: Bool {
            consumed.withLock { $0 }
        }

        func markConsumed() {
            consumed.withLock { $0 = true }
        }
    }

    let mappingOwnership: MappingOwnership

    init(
        managerIdentity: ObjectIdentifier, policyID: UUID, runID: UUID, routeID: Int,
        routingAuthorityGeneration: UInt64, routingWaitGeneration: UUID?, routeOwner: MCPHostRouteResources?
    ) {
        self.managerIdentity = managerIdentity
        self.policyID = policyID
        self.runID = runID
        self.routeID = routeID
        self.routingAuthorityGeneration = routingAuthorityGeneration
        self.routingWaitGeneration = routingWaitGeneration
        self.routeOwner = routeOwner
        mappingOwnership = MappingOwnership(policyID: policyID)
    }

    /// Shared by value copies retained in pending rollback tokens. This records consumption of
    /// this cleanup obligation only; it is not writer currency or fresh command authority.
    var isConsumed: Bool {
        mappingOwnership.isConsumed
    }

    func markConsumed() {
        mappingOwnership.markConsumed()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.managerIdentity == rhs.managerIdentity && lhs.policyID == rhs.policyID
            && lhs.runID == rhs.runID && lhs.routeID == rhs.routeID
            && lhs.routingAuthorityGeneration == rhs.routingAuthorityGeneration
            && lhs.routingWaitGeneration == rhs.routingWaitGeneration
            && lhs.routeOwner.map(ObjectIdentifier.init) == rhs.routeOwner.map(ObjectIdentifier.init)
    }
}
