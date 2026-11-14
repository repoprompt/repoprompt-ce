import Foundation

/// One non-reusing integer namespace for the existing transport wire format. A host route is
/// not a presentation window; allocating one must not change the latest physical window ID.
@MainActor
enum MCPRouteIdentityAllocator {
    private static var nextID = 0
    private(set) static var latestWindowID = 0

    private static func allocate() -> Int {
        precondition(nextID < .max, "MCP route identity space exhausted")
        nextID += 1
        return nextID
    }

    static func allocateWindowID() -> Int {
        let id = allocate()
        latestWindowID = id
        return id
    }

    static func allocateHost() -> MCPHostRouteIdentity {
        MCPHostRouteIdentity(id: UUID(), routeID: allocate(), kind: .independent)
    }
}

/// The UUID identifies resource ownership; the integer is a compatible transport route key.
/// Only the legacy adapter may use a presentation's existing route until visible host cutover.
struct MCPHostRouteIdentity: Equatable {
    enum Kind: Equatable { case independent, legacyWindow }

    let id: UUID
    let routeID: Int
    let kind: Kind

    static func legacyWindow(_ windowID: Int) -> Self {
        .init(id: UUID(), routeID: windowID, kind: .legacyWindow)
    }
}
