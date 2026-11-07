import Foundation

/// Owns the live session objects and their synchronous reverse binding index.
/// This replaces the view model's storage, not the durable run registry or binding authority.
/// Presentation publishes changes around `replaceSessions`; lifecycle, saves and cancellation
/// remain with their existing owners. Duplicate identity claims are retained, never elected away.
@MainActor
final class AgentSessionRuntimeStore {
    private(set) var sessions: [UUID: AgentTabSession] = [:]
    private var liveClaimByTabID: [UUID: UUID] = [:]
    private var liveTabIDsBySessionID: [UUID: Set<UUID>] = [:]

    func replaceSessions(_ replacement: [UUID: AgentTabSession]) {
        let previous = sessions
        sessions = replacement
        for (tabID, session) in previous where sessions[tabID] !== session {
            session.persistentSessionBindingDidChange = nil
            updateLiveSessionBindingIndex(tabID: tabID)
        }
        for (tabID, session) in sessions where previous[tabID] !== session {
            session.persistentSessionBindingDidChange = { [weak self, weak session] in
                guard let self, let session, self.sessions[tabID] === session else { return }
                self.updateLiveSessionBindingIndex(tabID: tabID)
            }
            updateLiveSessionBindingIndex(tabID: tabID)
        }
    }

    func liveSessionTabIDs(for sessionID: UUID) -> Set<UUID> {
        liveTabIDsBySessionID[sessionID] ?? []
    }

    private func updateLiveSessionBindingIndex(tabID: UUID) {
        if let previous = liveClaimByTabID.removeValue(forKey: tabID) {
            liveTabIDsBySessionID[previous]?.remove(tabID)
            if liveTabIDsBySessionID[previous]?.isEmpty == true {
                liveTabIDsBySessionID.removeValue(forKey: previous)
            }
        }
        if let current = sessions[tabID]?.activeAgentSessionID {
            liveClaimByTabID[tabID] = current
            liveTabIDsBySessionID[current, default: []].insert(tabID)
        }
    }
}
