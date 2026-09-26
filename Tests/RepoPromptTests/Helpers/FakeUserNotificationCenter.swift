import Foundation
@testable import RepoPromptApp

/// In-memory `UserNotificationCenterClient` that records every call and simulates delivered state.
@MainActor
final class FakeUserNotificationCenter: UserNotificationCenterClient {
    var isAvailable = true
    var status: NotificationAuthorizationStatus = .authorized
    var addError: Error?

    private(set) var addedRequests: [NotificationRequestSpec] = []
    private(set) var delivered: [String: NotificationRequestSpec] = [:]
    private(set) var registeredCategories: Set<NotificationCategorySpec> = []
    private(set) var setCategoriesCallCount = 0
    private(set) var removedDeliveredIdentifiers: [String] = []
    private(set) var removedPendingIdentifiers: [String] = []
    private(set) var badgeCounts: [Int] = []
    /// Delivered notifications that did not come from `add` (e.g. a previous launch).
    var externallyDelivered: [DeliveredNotificationSummary] = []

    func requestAuthorization() async -> NotificationAuthorizationStatus {
        status
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        status
    }

    func setCategories(_ categories: Set<NotificationCategorySpec>) async {
        setCategoriesCallCount += 1
        registeredCategories = categories
    }

    func registeredCategoryIdentifiers() async -> Set<String> {
        Set(registeredCategories.map(\.identifier))
    }

    func add(_ request: NotificationRequestSpec) async throws {
        if let addError { throw addError }
        addedRequests.append(request)
        delivered[request.identifier] = request
    }

    func deliveredNotifications() async -> [DeliveredNotificationSummary] {
        externallyDelivered + delivered.values.map { request in
            DeliveredNotificationSummary(
                identifier: request.identifier,
                threadIdentifier: request.threadIdentifier ?? "",
                categoryIdentifier: request.categoryIdentifier ?? "",
                payload: request.payload
            )
        }
    }

    func removeDelivered(identifiers: [String]) {
        removedDeliveredIdentifiers.append(contentsOf: identifiers)
        for identifier in identifiers {
            delivered.removeValue(forKey: identifier)
        }
        externallyDelivered.removeAll { identifiers.contains($0.identifier) }
    }

    func removePending(identifiers: [String]) {
        removedPendingIdentifiers.append(contentsOf: identifiers)
    }

    func setBadgeCount(_ count: Int) async {
        badgeCounts.append(count)
    }

    func category(_ identifier: String?) -> NotificationCategorySpec? {
        guard let identifier else { return nil }
        return registeredCategories.first { $0.identifier == identifier }
    }
}

@MainActor
final class FakeNotificationPreferencesProvider: NotificationPreferencesProviding {
    var currentNotificationPreferences: NotificationPreferences

    init(_ preferences: NotificationPreferences = .defaults) {
        currentNotificationPreferences = preferences
    }
}

@MainActor
final class FakeAgentSessionVisibility: AgentSessionVisibilityProviding {
    var isAppActive = false
    var visibleTabIDs: Set<UUID> = []

    func isAgentSessionVisible(windowID: Int, tabID: UUID, sessionID: UUID?) -> Bool {
        isAppActive && visibleTabIDs.contains(tabID)
    }
}
