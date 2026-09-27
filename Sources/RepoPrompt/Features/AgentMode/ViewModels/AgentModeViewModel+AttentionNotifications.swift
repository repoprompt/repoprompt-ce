import Combine
import Foundation

/// Per-window observation state for attention notifications. Held by `AgentModeViewModel` because
/// extensions cannot add stored properties.
@MainActor
final class AgentModeNotificationAttentionTracker {
    fileprivate var observers: [UUID: AnyCancellable] = [:]
    fileprivate var observedSessionIdentities: [UUID: ObjectIdentifier] = [:]
    fileprivate var activeTabObserver: AnyCancellable?
    fileprivate var publishScheduled = false
    /// Emits a tab ID when a notification click asks the transcript to reveal its pending card.
    let revealRequests = PassthroughSubject<UUID, Never>()
}

@MainActor
extension AgentModeViewModel {
    /// Keeps one observer per live session. Called from the `sessions` `didSet`, which is the single
    /// hook for session insertion, replacement, and removal.
    func syncAttentionNotificationObservers() {
        let tracker = notificationAttention
        for (tabID, identity) in tracker.observedSessionIdentities
            where sessions[tabID].map({ ObjectIdentifier($0) }) != identity
        {
            tracker.observers.removeValue(forKey: tabID)?.cancel()
            tracker.observedSessionIdentities.removeValue(forKey: tabID)
        }
        for (tabID, session) in sessions where tracker.observers[tabID] == nil {
            tracker.observers[tabID] = Self.attentionChangePublisher(for: session)
                // `@Published` fires in `willSet`; read settled state on a later main-queue turn.
                // Main queue (not RunLoop.main) so menus, drags, and sheets do not stall delivery.
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleAttentionNotificationPublish() }
                }
            tracker.observedSessionIdentities[tabID] = ObjectIdentifier(session)
        }
        if tracker.activeTabObserver == nil, let promptManager {
            tracker.activeTabObserver = promptManager.$activeComposeTabID
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { _ in
                    MainActor.assumeIsolated {
                        NotificationService.shared.agentNotifications.visibilityMayHaveChanged()
                    }
                }
        }
        scheduleAttentionNotificationPublish()
    }

    func scheduleAttentionNotificationPublish() {
        guard !notificationAttention.publishScheduled else { return }
        notificationAttention.publishScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.publishAttentionNotificationStates() }
        }
    }

    func publishAttentionNotificationStates() {
        notificationAttention.publishScheduled = false
        let states = sessions.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { tabID in
            sessions[tabID].flatMap { attentionNotificationState(for: $0, includeInteraction: true) }
        }
        NotificationService.shared.agentNotifications.update(windowID: windowID, states: states)
    }

    /// Attention snapshot for a live session in this window's active workspace.
    func attentionNotificationState(for session: TabSession, includeInteraction: Bool) -> AgentAttentionState? {
        guard let workspace = workspaceManager?.activeWorkspace else { return nil }
        let tabID = session.tabID
        let tabIsInWorkspace = workspace.composeTabs.contains(where: { $0.id == tabID })
            || workspace.stashedTabs.contains(where: { $0.tab.id == tabID })
        guard tabIsInWorkspace else { return nil }
        return AgentAttentionState(
            windowID: windowID,
            workspaceID: workspace.id,
            tabID: tabID,
            sessionID: session.activeAgentSessionID,
            sessionName: resolvedSessionDisplayName(for: tabID),
            isMCPControlled: isMCPControlled(tabID: tabID),
            interaction: includeInteraction ? AgentPendingInteractionDescriptor.make(from: session) : nil,
            turnMarker: includeInteraction ? nil : AgentNotificationTurnMarker.make(from: session)
        )
    }

    /// Whether `tabID` (optionally a specific session incarnation) is the Agent Mode transcript on
    /// screen in this window. Window focus is checked by the caller.
    func isAgentSessionDisplayed(tabID: UUID, sessionID: UUID?) -> Bool {
        guard isAgentModeActive, currentTabID == tabID else { return false }
        guard let sessionID else { return true }
        return sessions[tabID]?.activeAgentSessionID == sessionID
    }

    /// Asks the transcript for `tabID` to pin to its live bottom, where pending cards render.
    func revealPendingNotificationInteraction(tabID: UUID) {
        notificationAttention.revealRequests.send(tabID)
    }

    private static func attentionChangePublisher(for session: TabSession) -> AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            session.$runState.map { _ in () }.eraseToAnyPublisher(),
            session.$waitingPrompt.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingAskUser.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingUserInputRequest.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingApproval.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingCodexHookReview.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingPermissionsRequest.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingMCPElicitationRequest.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingApplyEditsReview.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingWorktreeMergeReview.map { _ in () }.eraseToAnyPublisher()
        ])
        .eraseToAnyPublisher()
    }
}
