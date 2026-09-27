import AppKit
import Foundation
import UserNotifications

// MARK: - Sendable value types

enum NotificationAuthorizationStatus: Equatable {
    case unavailable
    case notDetermined
    case denied
    case authorized
    case provisional

    var allowsDelivery: Bool {
        self == .authorized || self == .provisional
    }
}

struct NotificationActionSpec: Hashable {
    enum Style: Hashable {
        case button
        case textInput(buttonTitle: String, placeholder: String)
    }

    let identifier: String
    let title: String
    let style: Style
    let foreground: Bool
    let destructive: Bool
    let authenticationRequired: Bool

    init(
        identifier: String,
        title: String,
        style: Style = .button,
        foreground: Bool = false,
        destructive: Bool = false,
        authenticationRequired: Bool = false
    ) {
        self.identifier = identifier
        self.title = title
        self.style = style
        self.foreground = foreground
        self.destructive = destructive
        self.authenticationRequired = authenticationRequired
    }
}

struct NotificationCategorySpec: Hashable {
    let identifier: String
    let actions: [NotificationActionSpec]
}

struct NotificationRequestSpec: Equatable {
    let identifier: String
    let title: String
    let subtitle: String?
    let body: String
    let threadIdentifier: String?
    let categoryIdentifier: String?
    let playsSound: Bool
    let relevanceScore: Double
    let payload: AppNotificationPayload?

    init(
        identifier: String,
        title: String,
        subtitle: String? = nil,
        body: String,
        threadIdentifier: String? = nil,
        categoryIdentifier: String? = nil,
        playsSound: Bool = true,
        relevanceScore: Double = 0.5,
        payload: AppNotificationPayload? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.threadIdentifier = threadIdentifier
        self.categoryIdentifier = categoryIdentifier
        self.playsSound = playsSound
        self.relevanceScore = relevanceScore
        self.payload = payload
    }
}

struct DeliveredNotificationSummary: Equatable {
    let identifier: String
    let threadIdentifier: String
    let categoryIdentifier: String
    let payload: AppNotificationPayload?
}

// MARK: - Seam

/// Main-actor seam over `UNUserNotificationCenter`. Only `Sendable` value types cross it; the live
/// adapter is the single place that constructs or reads `UN*` objects.
@MainActor
protocol UserNotificationCenterClient: AnyObject {
    var isAvailable: Bool { get }
    func requestAuthorization() async -> NotificationAuthorizationStatus
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func setCategories(_ categories: Set<NotificationCategorySpec>) async
    func registeredCategoryIdentifiers() async -> Set<String>
    func add(_ request: NotificationRequestSpec) async throws
    func deliveredNotifications() async -> [DeliveredNotificationSummary]
    func removeDelivered(identifiers: [String])
    func removePending(identifiers: [String])
    func setBadgeCount(_ count: Int) async
}

// MARK: - Live adapter

@MainActor
final class LiveUserNotificationCenter: UserNotificationCenterClient {
    private let center: UNUserNotificationCenter?

    /// `UNUserNotificationCenter.current()` traps outside an app bundle (e.g. `swift test`), so the
    /// adapter is inert there.
    init(bundleURL: URL = Bundle.main.bundleURL) {
        center = bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    var isAvailable: Bool {
        center != nil
    }

    func installDelegate(_ delegate: UNUserNotificationCenterDelegate) {
        center?.delegate = delegate
    }

    func requestAuthorization() async -> NotificationAuthorizationStatus {
        guard let center else { return .unavailable }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return .denied
        }
        return await authorizationStatus()
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        guard let center else { return .unavailable }
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let status: NotificationAuthorizationStatus = switch settings.authorizationStatus {
                case .authorized: .authorized
                case .provisional: .provisional
                case .denied: .denied
                case .notDetermined: .notDetermined
                @unknown default: .denied
                }
                continuation.resume(returning: status)
            }
        }
    }

    func setCategories(_ categories: Set<NotificationCategorySpec>) async {
        guard let center else { return }
        center.setNotificationCategories(Set(categories.map(Self.makeCategory)))
    }

    func registeredCategoryIdentifiers() async -> Set<String> {
        guard let center else { return [] }
        return await withCheckedContinuation { continuation in
            center.getNotificationCategories { categories in
                continuation.resume(returning: Set(categories.map(\.identifier)))
            }
        }
    }

    func add(_ request: NotificationRequestSpec) async throws {
        guard let center else { return }
        let unRequest = UNNotificationRequest(
            identifier: request.identifier,
            content: Self.makeContent(request),
            trigger: nil
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(unRequest) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func deliveredNotifications() async -> [DeliveredNotificationSummary] {
        guard let center else { return [] }
        return await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                let summaries = notifications.map { notification in
                    let content = notification.request.content
                    return DeliveredNotificationSummary(
                        identifier: notification.request.identifier,
                        threadIdentifier: content.threadIdentifier,
                        categoryIdentifier: content.categoryIdentifier,
                        payload: AppNotificationPayload.parse(content.userInfo)
                    )
                }
                continuation.resume(returning: summaries)
            }
        }
    }

    func removeDelivered(identifiers: [String]) {
        guard let center, !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removePending(identifiers: [String]) {
        guard let center, !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func setBadgeCount(_ count: Int) async {
        guard let center else {
            NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil
            return
        }
        do {
            try await center.setBadgeCount(max(0, count))
        } catch {
            NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
    }

    // MARK: Builders

    private static func makeContent(_ request: NotificationRequestSpec) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = request.title
        if let subtitle = request.subtitle {
            content.subtitle = subtitle
        }
        content.body = request.body
        if let threadIdentifier = request.threadIdentifier {
            content.threadIdentifier = threadIdentifier
        }
        if let categoryIdentifier = request.categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        content.sound = request.playsSound ? .default : nil
        content.relevanceScore = request.relevanceScore
        if let payload = request.payload {
            content.userInfo = payload.userInfo
            content.targetContentIdentifier = payload.route?.url.absoluteString
        }
        return content
    }

    private static func makeCategory(_ spec: NotificationCategorySpec) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: spec.identifier,
            actions: spec.actions.map(makeAction),
            intentIdentifiers: [],
            options: []
        )
    }

    private static func makeAction(_ spec: NotificationActionSpec) -> UNNotificationAction {
        var options: UNNotificationActionOptions = []
        if spec.foreground { options.insert(.foreground) }
        if spec.destructive { options.insert(.destructive) }
        if spec.authenticationRequired { options.insert(.authenticationRequired) }
        switch spec.style {
        case .button:
            return UNNotificationAction(identifier: spec.identifier, title: spec.title, options: options)
        case let .textInput(buttonTitle, placeholder):
            return UNTextInputNotificationAction(
                identifier: spec.identifier,
                title: spec.title,
                options: options,
                textInputButtonTitle: buttonTitle,
                textInputPlaceholder: placeholder
            )
        }
    }
}
