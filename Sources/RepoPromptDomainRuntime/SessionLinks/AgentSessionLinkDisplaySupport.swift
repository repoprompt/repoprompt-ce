import Foundation

/// Short display form for an Agent session ID.
///
/// The full canonical UUID remains available through the row's tooltip, accessibility value, and
/// Copy Session ID actions. The compact form is retained for fallback task names, previews, inbound
/// labels, notices, and attribution.
package enum AgentMonitorSessionIDFormatter {
    private static let baseTokenLength = 4

    package static func short(_ sessionID: UUID) -> String {
        token(sessionID, endLength: baseTokenLength)
    }

    private static func token(_ sessionID: UUID, endLength: Int) -> String {
        let raw = sessionID.uuidString
        guard raw.count > endLength * 2 else { return raw }
        return "\(raw.prefix(endLength))…\(raw.suffix(endLength))"
    }
}

/// The durable (tab, session, generation) triple that pins a persisted Agent binding to one
/// exact conversation incarnation.
package struct AgentPersistentSessionBindingIdentity: Equatable, Hashable {
    package let tabID: UUID
    package let sessionID: UUID
    package let generation: UUID

    package init(tabID: UUID, sessionID: UUID, generation: UUID = UUID()) {
        self.tabID = tabID
        self.sessionID = sessionID
        self.generation = generation
    }
}
