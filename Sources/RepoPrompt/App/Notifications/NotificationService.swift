import AppKit
import Foundation
import os
import UserNotifications

private let notificationServiceLog = Logger(subsystem: "com.repoprompt.ce", category: "NotificationService")

/// SEARCH-HELPER: Notifications, UserNotifications, Alerts, Chat Complete, Actionable Notifications
///
/// App-wide facade over macOS user notifications. Owns the `UNUserNotificationCenter` delegate, the
/// category registry, the Agent Mode attention coordinator, and the response handler. See
/// `docs/architecture/actionable-macos-notifications.md`.
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    private let liveClient: LiveUserNotificationCenter
    let client: UserNotificationCenterClient
    let categoryRegistry: NotificationCategoryRegistry
    private(set) var authorizationStatus: NotificationAuthorizationStatus = .notDetermined
    private var didInstallDelegate = false
    private var observers: [NSObjectProtocol] = []

    private(set) lazy var agentNotifications = AgentNotificationCoordinator(
        client: client,
        registry: categoryRegistry,
        preferences: GlobalSettingsStore.shared,
        visibility: LiveAgentSessionVisibility(),
        authorization: { [unowned self] in authorizationStatus }
    )

    private lazy var responseHandler = AppNotificationResponseHandler(
        router: LiveAppNotificationRouter(),
        dispatcher: LiveAgentNotificationActionDispatcher(),
        preferences: GlobalSettingsStore.shared,
        postFeedback: { [unowned self] title, body, route in
            agentNotifications.postFeedback(title: title, body: body, route: route)
        }
    )

    override private init() {
        let liveClient = LiveUserNotificationCenter()
        self.liveClient = liveClient
        client = liveClient
        categoryRegistry = NotificationCategoryRegistry(
            client: liveClient,
            staticCategories: AgentNotificationAction.staticCategories
        )
        super.init()
    }

    // MARK: Launch

    /// Installs the delegate synchronously. Call from `applicationWillFinishLaunching` so a click that
    /// launched the app is delivered to us (Apple requires the delegate before launch finishes).
    func installDelegate() {
        guard !didInstallDelegate, liveClient.isAvailable else { return }
        didInstallDelegate = true
        liveClient.installDelegate(self)

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let service = NotificationService.shared
                service.agentNotifications.visibilityMayHaveChanged()
                Task { await service.refreshAuthorizationStatus() }
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NotificationService.shared.agentNotifications.visibilityMayHaveChanged()
            }
        })
        observers.append(center.addObserver(
            forName: .notificationPreferencesDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NotificationService.shared.agentNotifications.preferencesDidChange()
            }
        })

        Task { @MainActor in
            await categoryRegistry.installStaticCategories()
            await agentNotifications.sweepPreviousLaunchNotifications()
            await refreshAuthorizationStatus()
        }
    }

    /// Request notification authorization on app launch.
    func requestAuthorization() async {
        installDelegate()
        authorizationStatus = await client.requestAuthorization()
        if !authorizationStatus.allowsDelivery {
            notificationServiceLog.debug("Notification authorization not granted")
        }
        agentNotifications.preferencesDidChange()
    }

    @discardableResult
    func refreshAuthorizationStatus() async -> NotificationAuthorizationStatus {
        let previous = authorizationStatus
        authorizationStatus = await client.authorizationStatus()
        if previous != authorizationStatus {
            agentNotifications.preferencesDidChange()
        }
        return authorizationStatus
    }

    /// Check current authorization status.
    func checkAuthorizationStatus() async -> Bool {
        await refreshAuthorizationStatus().allowsDelivery
    }

    func prepareForTermination() async {
        await agentNotifications.resetBadgeForTermination()
    }

    // MARK: Chat / Context Builder

    /// Send a notification when a chat completes.
    func notifyChatComplete(chatName: String?, groupID: UUID? = nil, fallbackToDockBounce: Bool = true) {
        let preferences = GlobalSettingsStore.shared.notificationPreferences()
        guard preferences.enabled, preferences.chatComplete, NSApp?.isActive != true else { return }
        let body: String = if preferences.showDetails, let name = chatName, !name.isEmpty, name != "New Chat" {
            name
        } else {
            "Your AI response is ready"
        }
        postComposeNotification(
            identifier: AppNotificationIdentifier.chatComplete(tabID: groupID),
            kind: .chatComplete,
            title: "Chat Complete",
            body: body,
            groupID: groupID,
            fallbackToDockBounce: fallbackToDockBounce
        )
    }

    /// Send a notification when Context Builder completes and its tab is renamed.
    func notifyContextBuilderComplete(tabName: String, tabID: UUID? = nil, fallbackToDockBounce: Bool = true) {
        let preferences = GlobalSettingsStore.shared.notificationPreferences()
        guard preferences.enabled, preferences.contextBuilderComplete, NSApp?.isActive != true else { return }
        postComposeNotification(
            identifier: AppNotificationIdentifier.contextBuilderComplete(tabID: tabID),
            kind: .contextBuilderComplete,
            title: "Context Builder Complete",
            body: preferences.showDetails ? tabName : "Your context is ready",
            groupID: tabID,
            fallbackToDockBounce: fallbackToDockBounce
        )
    }

    private func postComposeNotification(
        identifier: String,
        kind: AppNotificationKind,
        title: String,
        body: String,
        groupID: UUID?,
        fallbackToDockBounce: Bool
    ) {
        guard client.isAvailable, authorizationStatus.allowsDelivery else {
            if fallbackToDockBounce {
                NSApp?.requestUserAttention(.informationalRequest)
            }
            return
        }
        let request = NotificationRequestSpec(
            identifier: identifier,
            title: title,
            body: body,
            threadIdentifier: AppNotificationIdentifier.composeThread(tabID: groupID),
            relevanceScore: 0.3,
            payload: AppNotificationPayload(kind: kind, route: nil)
        )
        Task { @MainActor [client] in
            do {
                try await client.add(request)
            } catch {
                notificationServiceLog.error("Error sending notification: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Response handling

    fileprivate func handle(_ response: AppNotificationResponse) async {
        await responseHandler.handle(response)
    }

    fileprivate func presentationOptions(for payload: AppNotificationPayload?) -> UNNotificationPresentationOptions {
        agentNotifications.shouldPresentWhileActive(payload) ? [.banner, .list, .sound] : []
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Only called while RepoPrompt is frontmost. Show the banner unless the notification's session is
    /// the one on screen (or the user opted out of foreground banners for that kind).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let payload = AppNotificationPayload.parse(notification.request.content.userInfo)
        return await presentationOptions(for: payload)
    }

    /// Click, action button, or text reply. The `Sendable` extraction happens before the actor hop.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let extracted = AppNotificationResponse(response: response)
        await handle(extracted)
    }
}
