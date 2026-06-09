import Foundation

/// MCP routing projection for reusable runtime sessions.
///
/// Compatibility snapshots retain `windowID` terminology while existing MCP
/// schemas continue to expose `window_id`. Internally these values are routing
/// session IDs and no longer retain app windows.
@MainActor
final class MCPRuntimeSessionRegistry {
    enum RegistrationResult: Equatable {
        case accepted
        case alreadyRegistered
        case routingIDInUse
        case retiredRoutingID
    }

    enum Lifecycle {
        case active
        case draining
    }

    struct RoutingSnapshot {
        let generation: UInt64
        let orderedActiveWindowIDs: [Int]
        let mcpEnabledWindowIDs: Set<Int>

        var activeWindowCount: Int {
            orderedActiveWindowIDs.count
        }

        var isMultiWindowModeEffectivelyActive: Bool {
            activeWindowCount > 1
        }

        var firstMCPEnabledWindowID: Int? {
            orderedActiveWindowIDs.first { mcpEnabledWindowIDs.contains($0) }
        }

        func hasActiveWindow(_ windowID: Int) -> Bool {
            orderedActiveWindowIDs.contains(windowID)
        }

        func hasMCPEnabledWindow(_ windowID: Int) -> Bool {
            hasActiveWindow(windowID) && mcpEnabledWindowIDs.contains(windowID)
        }
    }

    private final class Entry {
        let windowID: Int
        let sessionID: RepoPromptSessionID
        weak var session: RepoPromptCoreSession?
        var lifecycle: Lifecycle
        var isMCPEnabled: Bool

        init(session: RepoPromptCoreSession, isMCPEnabled: Bool) {
            windowID = session.routingSessionID.rawValue
            sessionID = session.sessionID
            self.session = session
            lifecycle = .active
            self.isMCPEnabled = isMCPEnabled
        }
    }

    private struct PendingEnable {
        let sessionID: RepoPromptSessionID?
        let enabled: Bool
    }

    private var entriesByID: [Int: Entry] = [:]
    private var orderedIDs: [Int] = []
    private var pendingEnabledByUnknownID: [Int: PendingEnable] = [:]
    private var retiredIDs: Set<Int> = []
    private var generation: UInt64 = 0

    nonisolated init() {}

    @discardableResult
    func register(session: RepoPromptCoreSession) -> RegistrationResult {
        let windowID = session.routingSessionID.rawValue
        guard !retiredIDs.contains(windowID) else { return .retiredRoutingID }
        if let existing = entriesByID[windowID] {
            guard existing.sessionID == session.sessionID else { return .routingIDInUse }
            guard existing.lifecycle == .active else { return .routingIDInUse }
            existing.session = session
            return .alreadyRegistered
        }

        let pendingEnable = pendingEnabledByUnknownID.removeValue(forKey: windowID)
        let isEnabled = if let pendingEnable,
                           pendingEnable.sessionID == nil || pendingEnable.sessionID == session.sessionID
        {
            pendingEnable.enabled
        } else {
            false
        }
        entriesByID[windowID] = Entry(session: session, isMCPEnabled: isEnabled)
        orderedIDs.append(windowID)
        generation &+= 1
        return .accepted
    }

    func setMCPEnabled(windowID: Int, enabled: Bool) {
        _ = setMCPEnabled(windowID: windowID, expectedSessionID: nil, enabled: enabled)
    }

    @discardableResult
    func setMCPEnabled(
        windowID: Int,
        expectedSessionID: RepoPromptSessionID,
        enabled: Bool
    ) -> Bool {
        setMCPEnabled(windowID: windowID, expectedSessionID: Optional(expectedSessionID), enabled: enabled)
    }

    private func setMCPEnabled(
        windowID: Int,
        expectedSessionID: RepoPromptSessionID?,
        enabled: Bool
    ) -> Bool {
        if retiredIDs.contains(windowID) {
            return false
        }
        guard let entry = entriesByID[windowID] else {
            if let pending = pendingEnabledByUnknownID[windowID] {
                if let expectedSessionID,
                   let pendingSessionID = pending.sessionID,
                   pendingSessionID != expectedSessionID
                {
                    return false
                }
                if expectedSessionID == nil, pending.sessionID != nil {
                    return false
                }
                guard pending.enabled != enabled || pending.sessionID != expectedSessionID else { return true }
            }
            pendingEnabledByUnknownID[windowID] = PendingEnable(
                sessionID: expectedSessionID,
                enabled: enabled
            )
            generation &+= 1
            return true
        }
        if let expectedSessionID, entry.sessionID != expectedSessionID { return false }
        if entry.lifecycle == .draining, enabled {
            return false
        }
        guard entry.isMCPEnabled != enabled else { return true }
        entry.isMCPEnabled = enabled
        generation &+= 1
        return true
    }

    @discardableResult
    func beginDraining(windowID: Int, expectedSessionID: RepoPromptSessionID) -> Bool {
        guard let entry = entriesByID[windowID],
              entry.sessionID == expectedSessionID
        else {
            return false
        }
        guard entry.lifecycle == .active else { return true }
        entry.lifecycle = .draining
        entry.isMCPEnabled = false
        generation &+= 1
        return true
    }

    @discardableResult
    func remove(windowID: Int, expectedSessionID: RepoPromptSessionID) -> Bool {
        guard let entry = entriesByID[windowID],
              entry.sessionID == expectedSessionID
        else {
            return false
        }
        entriesByID.removeValue(forKey: windowID)
        orderedIDs.removeAll { $0 == windowID }
        generation &+= 1
        pendingEnabledByUnknownID.removeValue(forKey: windowID)
        retiredIDs.insert(windowID)
        return true
    }

    func routingSnapshot() -> RoutingSnapshot {
        let activeIDs = orderedIDs.filter { windowID in
            guard let entry = entriesByID[windowID],
                  entry.lifecycle == .active,
                  entry.session != nil
            else {
                return false
            }
            return true
        }
        let enabledIDs = Set(activeIDs.filter { entriesByID[$0]?.isMCPEnabled == true })
        return RoutingSnapshot(
            generation: generation,
            orderedActiveWindowIDs: activeIDs,
            mcpEnabledWindowIDs: enabledIDs
        )
    }

    func session(withRoutingID windowID: Int, includeDraining: Bool = false) -> RepoPromptCoreSession? {
        guard let entry = entriesByID[windowID],
              includeDraining || entry.lifecycle == .active
        else {
            return nil
        }
        return entry.session
    }

    func sessions(includeDraining: Bool = false) -> [RepoPromptCoreSession] {
        orderedIDs.compactMap { session(withRoutingID: $0, includeDraining: includeDraining) }
    }

    func hasActiveWindow(id windowID: Int) -> Bool {
        session(withRoutingID: windowID) != nil
    }

    func hasActiveSession(windowID: Int, expectedSessionID: RepoPromptSessionID) -> Bool {
        guard let entry = entriesByID[windowID],
              entry.sessionID == expectedSessionID,
              entry.lifecycle == .active,
              entry.session != nil
        else {
            return false
        }
        return true
    }

    func hasMCPEnabledWindow(id windowID: Int) -> Bool {
        guard let entry = entriesByID[windowID],
              entry.lifecycle == .active,
              entry.isMCPEnabled,
              entry.session != nil
        else {
            return false
        }
        return true
    }

    func isInvocationAllowed(windowID: Int) -> Bool {
        hasMCPEnabledWindow(id: windowID)
    }

    #if DEBUG
        func debugIsRetired(windowID: Int) -> Bool {
            retiredIDs.contains(windowID)
        }
    #endif
}
