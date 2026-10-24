import AppKit
import Foundation
import os

private let agentNotificationLog = Logger(subsystem: "com.repoprompt.ce", category: "AgentNotifications")

/// Answers "is this exact agent session on screen right now?" for notification suppression.
@MainActor
protocol AgentSessionVisibilityProviding: AnyObject {
    var isAppActive: Bool { get }
    func isAgentSessionVisible(windowID: Int, tabID: UUID, sessionID: UUID?) -> Bool
}

enum AgentTurnOutcomeNotification: Equatable {
    case completed(preview: String?)
    case failed(message: String?)
}

/// Reconciles live Agent Mode attention state into delivered notifications.
///
/// Windows publish `[AgentAttentionState]`; the coordinator runs the pure `AgentNotificationPlanner`
/// against tracked deliveries and applies the resulting posts/removals through the
/// `UserNotificationCenterClient` seam. Passes are coalesced and strictly serialized.
@MainActor
final class AgentNotificationCoordinator {
    typealias AuthorizationProvider = @MainActor () -> NotificationAuthorizationStatus

    private let client: UserNotificationCenterClient
    private let registry: NotificationCategoryRegistry
    private let preferences: NotificationPreferencesProviding
    private let visibility: AgentSessionVisibilityProviding
    private let authorization: AuthorizationProvider
    private let now: @MainActor () -> Date
    private let gracePeriod: TimeInterval
    private let requestUserAttention: @MainActor () -> Void

    private var statesByWindowID: [Int: [AgentAttentionState]] = [:]
    private var firstSeenAt: [UUID: Date] = [:]
    private var announcedInteractionIDs: Set<UUID> = []
    private var posted: [String: AgentPostedInteraction] = [:]
    private var turnNotificationIDsByTabID: [UUID: Set<String>] = [:]
    /// Turn outcome requests waiting for the next serialized reconcile pass, keyed by request id.
    private var pendingTurnPosts: [String: (tabID: UUID, request: NotificationRequestSpec, category: NotificationCategorySpec?)] = [:]
    private var bouncedInteractionIDs: Set<UUID> = []
    private var lastBadgeCount: Int?
    private var needsReconcile = false
    private var reconcileTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var graceDeadline: Date?

    init(
        client: UserNotificationCenterClient,
        registry: NotificationCategoryRegistry,
        preferences: NotificationPreferencesProviding,
        visibility: AgentSessionVisibilityProviding,
        authorization: @escaping AuthorizationProvider,
        now: @escaping @MainActor () -> Date = { Date() },
        gracePeriod: TimeInterval = 1.0,
        requestUserAttention: @escaping @MainActor () -> Void = { _ = NSApp?.requestUserAttention(.informationalRequest) }
    ) {
        self.client = client
        self.registry = registry
        self.preferences = preferences
        self.visibility = visibility
        self.authorization = authorization
        self.now = now
        self.gracePeriod = gracePeriod
        self.requestUserAttention = requestUserAttention
    }

    // MARK: Inputs

    func update(windowID: Int, states: [AgentAttentionState]) {
        guard client.isAvailable else { return }
        if states.isEmpty {
            guard statesByWindowID.removeValue(forKey: windowID) != nil else { return }
        } else {
            guard statesByWindowID[windowID] != states else { return }
            statesByWindowID[windowID] = states
        }
        scheduleReconcile()
    }

    func removeWindow(_ windowID: Int) {
        update(windowID: windowID, states: [])
    }

    /// Focus, active tab, Agent Mode surface, or app activation changed.
    func visibilityMayHaveChanged() {
        guard client.isAvailable,
              !statesByWindowID.isEmpty || !turnNotificationIDsByTabID.isEmpty || !pendingTurnPosts.isEmpty
        else { return }
        scheduleReconcile()
    }

    func preferencesDidChange() {
        guard client.isAvailable else { return }
        scheduleReconcile()
    }

    /// Live attention state for a tab, if any window currently publishes it.
    func liveState(tabID: UUID) -> AgentAttentionState? {
        statesByWindowID.values.flatMap(\.self).first { $0.tabID == tabID }
    }

    // MARK: Edge-triggered notifications

    func postTurnOutcome(_ outcome: AgentTurnOutcomeNotification, for state: AgentAttentionState) {
        let preferences = preferences.currentNotificationPreferences
        let isFailure: Bool
        let body: String
        switch outcome {
        case let .completed(preview):
            guard preferences.enabled, preferences.agentTurnComplete else { return }
            isFailure = false
            body = preferences.showDetails
                ? (NotificationTextPreview.make(from: preview) ?? "Your agent message is ready")
                : "Your agent message is ready"
        case let .failed(message):
            guard preferences.enabled, preferences.agentTurnFailed else { return }
            isFailure = true
            body = preferences.showDetails
                ? (NotificationTextPreview.make(from: message) ?? "The agent run failed")
                : "The agent run failed"
        }
        guard !state.isMCPControlled || preferences.includeAgentDrivenSessions else { return }
        guard !visibility.isAgentSessionVisible(
            windowID: state.windowID,
            tabID: state.tabID,
            sessionID: state.sessionID
        ) else { return }
        if visibility.isAppActive, !preferences.completionsWhileActive { return }
        guard client.isAvailable, authorization().allowsDelivery else {
            if !visibility.isAppActive { requestUserAttention() }
            return
        }

        let identifier = isFailure
            ? AppNotificationIdentifier.turnFailed(tabID: state.tabID)
            : AppNotificationIdentifier.turnComplete(tabID: state.tabID)
        let actions = isFailure
            ? []
            : AgentNotificationActionEligibility.turnCompleteActions(
                isMCPControlled: state.isMCPControlled,
                preferences: preferences
            )
        let category = AgentNotificationAction.category(for: actions, interactionID: nil)
        let request = NotificationRequestSpec(
            identifier: identifier,
            title: state.sessionName,
            subtitle: isFailure ? "Run failed" : nil,
            body: body,
            threadIdentifier: state.threadIdentifier,
            categoryIdentifier: category?.identifier,
            relevanceScore: isFailure ? 0.7 : 0.4,
            payload: AppNotificationPayload(
                kind: isFailure ? .turnFailed : .turnComplete,
                route: state.route.withInteractionID(nil),
                turnMarker: isFailure ? nil : state.turnMarker,
                postedAt: now()
            )
        )
        // Delivered by the serialized reconcile pass, so a retraction decided in the same pass (the
        // tab became visible or now asks for input) can never be overtaken by a late add.
        pendingTurnPosts[identifier] = (state.tabID, request, category)
        scheduleReconcile()
    }

    /// Informational notification reporting a background action outcome (e.g. stale request).
    func postFeedback(title: String, body: String, route: AgentSessionDeepLinkRoute?) {
        guard client.isAvailable else { return }
        let identifier = AppNotificationIdentifier.feedback(UUID())
        let request = NotificationRequestSpec(
            identifier: identifier,
            title: title,
            body: body,
            threadIdentifier: route.map { AppNotificationIdentifier.sessionThread(tabID: $0.tabID, sessionID: $0.sessionID) },
            playsSound: false,
            relevanceScore: 0.2,
            payload: AppNotificationPayload(kind: .feedback, route: route?.withInteractionID(nil), postedAt: now())
        )
        enqueue { coordinator in
            await coordinator.add(request)
        }
    }

    /// Whether a notification arriving while RepoPrompt is frontmost should still be shown.
    func shouldPresentWhileActive(_ payload: AppNotificationPayload?) -> Bool {
        let preferences = preferences.currentNotificationPreferences
        guard let payload else { return false }
        if let route = payload.route,
           visibility.isAgentSessionVisible(windowID: route.windowID ?? -1, tabID: route.tabID, sessionID: route.sessionID)
        {
            return false
        }
        switch payload.kind {
        case .feedback:
            return true
        case .interaction:
            return preferences.notifyWhileActive
        case .turnComplete, .turnFailed:
            return preferences.completionsWhileActive
        case .chatComplete, .contextBuilderComplete:
            return false
        }
    }

    /// Removes notifications delivered by previous launches: their interactions cannot be resolved.
    func sweepPreviousLaunchNotifications() async {
        guard client.isAvailable else { return }
        let delivered = await client.deliveredNotifications()
        let stale = delivered
            .filter { $0.payload?.isFromCurrentLaunch != true }
            .map(\.identifier)
        client.removeDelivered(identifiers: stale)
        await client.setBadgeCount(0)
        // A pass may have applied a live badge while the sweep was in flight; recompute it.
        lastBadgeCount = nil
        scheduleReconcile()
    }

    func resetBadgeForTermination() async {
        guard client.isAvailable else { return }
        await client.setBadgeCount(0)
    }

    // MARK: Reconciliation

    private func scheduleReconcile() {
        needsReconcile = true
        guard reconcileTask == nil else { return }
        reconcileTask = Task { @MainActor [weak self] in
            // Let same-turn state changes (e.g. `@Published` willSet bursts) settle first.
            await Task.yield()
            while let self, needsReconcile {
                needsReconcile = false
                await reconcileOnce()
            }
            self?.reconcileTask = nil
        }
    }

    private var serialTail: Task<Void, Never>?

    private func enqueue(_ work: @escaping @MainActor (AgentNotificationCoordinator) async -> Void) {
        let previous = serialTail
        serialTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    private func reconcileOnce() async {
        let preferences = preferences.currentNotificationPreferences
        let states = statesByWindowID.keys.sorted().flatMap { statesByWindowID[$0] ?? [] }
        let visibleTabIDs = Set(states.filter {
            visibility.isAgentSessionVisible(windowID: $0.windowID, tabID: $0.tabID, sessionID: $0.sessionID)
        }.map(\.tabID))
        let isAuthorized = authorization().allowsDelivery
        let plan = AgentNotificationPlanner.plan(AgentNotificationPlanInput(
            states: states,
            visibleTabIDs: visibleTabIDs,
            appIsActive: visibility.isAppActive,
            preferences: preferences,
            firstSeenAt: firstSeenAt,
            announcedInteractionIDs: announcedInteractionIDs,
            posted: isAuthorized ? posted : [:],
            now: now(),
            gracePeriod: gracePeriod
        ))
        firstSeenAt = plan.firstSeenAt
        announcedInteractionIDs = plan.announcedInteractionIDs
        bouncedInteractionIDs.formIntersection(Set(plan.firstSeenAt.keys))
        scheduleGraceWakeup(at: plan.nextGraceDeadline)

        guard isAuthorized else {
            pendingTurnPosts.removeAll()
            // Without authorization, fall back to one Dock bounce per newly surfaced interaction.
            let fresh = plan.posts.map(\.interactionID).filter { !bouncedInteractionIDs.contains($0) }
            if !fresh.isEmpty, !visibility.isAppActive {
                bouncedInteractionIDs.formUnion(fresh)
                requestUserAttention()
            }
            await applyBadge(plan.badgeCount)
            return
        }

        let turnRemovals = plan.retractTurnNotificationsForTabs.flatMap { tabID in
            turnNotificationIDsByTabID.removeValue(forKey: tabID) ?? []
        }
        pendingTurnPosts = pendingTurnPosts.filter { !plan.retractTurnNotificationsForTabs.contains($0.value.tabID) }
        let removals = plan.removals + turnRemovals
        if !removals.isEmpty {
            for identifier in plan.removals {
                posted.removeValue(forKey: identifier)
            }
            client.removeDelivered(identifiers: removals)
            client.removePending(identifiers: removals)
        }

        for post in plan.posts {
            var request = post.request
            var categoryIdentifier = post.category?.identifier
            if let category = post.category, await !(registry.ensureRegistered(category)) {
                // Dynamic category cap reached: degrade to an Open-only notification.
                let fallback = AgentNotificationAction.category(for: [.review], interactionID: nil)
                if let fallback {
                    await registry.ensureRegistered(fallback)
                }
                categoryIdentifier = fallback?.identifier
                request = request.replacingCategory(categoryIdentifier)
            }
            // A pass that raced with a newer state change must not resurrect a resolved interaction.
            guard isInteractionLive(post.interactionID), await add(request) else { continue }
            posted[request.identifier] = AgentPostedInteraction(
                requestIdentifier: request.identifier,
                interactionID: post.interactionID,
                tabID: post.tabID,
                contentKey: post.contentKey,
                categoryIdentifier: categoryIdentifier
            )
        }

        let turnPosts = pendingTurnPosts.sorted { $0.key < $1.key }
        pendingTurnPosts.removeAll()
        for (identifier, turnPost) in turnPosts {
            if let category = turnPost.category {
                await registry.ensureRegistered(category)
            }
            if await add(turnPost.request) {
                turnNotificationIDsByTabID[turnPost.tabID, default: []].insert(identifier)
            }
        }

        let liveDynamicCategories = Set(posted.values.compactMap(\.categoryIdentifier).filter(AppNotificationCategoryID.isDynamic))
        await registry.pruneDynamicCategories(keeping: liveDynamicCategories)
        await applyBadge(plan.badgeCount)
    }

    private func isInteractionLive(_ interactionID: UUID) -> Bool {
        statesByWindowID.values.contains { states in
            states.contains { $0.interaction?.id == interactionID }
        }
    }

    /// Returns whether the request was accepted; callers only record deliveries that happened, so a
    /// failed add is retried on the next pass instead of being treated as delivered.
    @discardableResult
    private func add(_ request: NotificationRequestSpec) async -> Bool {
        do {
            try await client.add(request)
            return true
        } catch {
            agentNotificationLog.error("Failed to add notification: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func applyBadge(_ count: Int) async {
        guard lastBadgeCount != count else { return }
        lastBadgeCount = count
        await client.setBadgeCount(count)
    }

    private func scheduleGraceWakeup(at deadline: Date?) {
        guard let deadline else {
            graceTask?.cancel()
            graceTask = nil
            graceDeadline = nil
            return
        }
        if let graceDeadline, graceDeadline <= deadline, graceTask != nil { return }
        graceTask?.cancel()
        graceDeadline = deadline
        let delay = max(0, deadline.timeIntervalSince(now()))
        graceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((delay + 0.01) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            graceTask = nil
            graceDeadline = nil
            scheduleReconcile()
        }
    }

    #if DEBUG
        /// Waits until queued reconcile passes and serialized posts have drained (tests only).
        func waitForIdleForTesting() async {
            for _ in 0 ..< 100 {
                if let reconcileTask { await reconcileTask.value }
                if let serialTail { await serialTail.value }
                await Task.yield()
                if reconcileTask == nil, !needsReconcile { return }
            }
        }

        func forceReconcileForTesting() async {
            scheduleReconcile()
            await waitForIdleForTesting()
        }

        var postedInteractionIDsForTesting: Set<UUID> {
            Set(posted.values.map(\.interactionID))
        }
    #endif
}

extension NotificationRequestSpec {
    func replacingCategory(_ categoryIdentifier: String?) -> NotificationRequestSpec {
        NotificationRequestSpec(
            identifier: identifier,
            title: title,
            subtitle: subtitle,
            body: body,
            threadIdentifier: threadIdentifier,
            categoryIdentifier: categoryIdentifier,
            playsSound: playsSound,
            relevanceScore: relevanceScore,
            payload: payload
        )
    }
}
