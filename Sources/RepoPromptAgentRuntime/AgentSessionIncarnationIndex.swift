import Foundation

/// The live membership index for one runtime scope. A tab receives a fresh incarnation
/// whenever it acquires a slot or changes binding. Unbound tabs still have an incarnation.
package struct AgentSessionIncarnationIndex {
    package struct Claim {
        package let sessionID: UUID?
        package let incarnationID: UUID
    }

    private var claimByTabID: [UUID: Claim] = [:]
    private var tabIDsBySessionID: [UUID: Set<UUID>] = [:]

    package init() {}

    package func claim(for tabID: UUID) -> Claim? {
        claimByTabID[tabID]
    }

    package func tabIDs(for sessionID: UUID) -> Set<UUID> {
        tabIDsBySessionID[sessionID] ?? []
    }

    package mutating func install(tabID: UUID, sessionID: UUID?) {
        remove(tabID: tabID)
        claimByTabID[tabID] = Claim(sessionID: sessionID, incarnationID: UUID())
        if let sessionID { tabIDsBySessionID[sessionID, default: []].insert(tabID) }
    }

    package mutating func remove(tabID: UUID) {
        guard let sessionID = claimByTabID.removeValue(forKey: tabID)?.sessionID else { return }
        tabIDsBySessionID[sessionID]?.remove(tabID)
        if tabIDsBySessionID[sessionID]?.isEmpty == true { tabIDsBySessionID.removeValue(forKey: sessionID) }
    }
}
