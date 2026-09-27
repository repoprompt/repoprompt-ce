import Foundation
import UserNotifications

/// Stable `UNNotificationAction` identifiers. Part of the delivered-notification contract.
enum AppNotificationActionID {
    static let defaultAction = UNNotificationDefaultActionIdentifier
    static let dismissAction = UNNotificationDismissActionIdentifier
    static let review = "rp.action.review"
    static let open = "rp.action.open"
    static let approve = "rp.action.approve"
    static let decline = "rp.action.decline"
    static let skip = "rp.action.skip"
    static let reply = "rp.action.reply"
    static let choicePrefix = "rp.action.choice."

    static func choice(_ index: Int) -> String {
        choicePrefix + String(index)
    }
}

enum AppNotificationCategoryID {
    static let actionsPrefix = "rp.agent.actions."
    static let choicePrefix = "rp.agent.choice."

    static func isDynamic(_ identifier: String) -> Bool {
        identifier.hasPrefix(choicePrefix)
    }
}

/// Owns the process-wide notification category set.
///
/// `setNotificationCategories` replaces the whole set, so the registry always writes the union of the
/// static categories and the live dynamic (per-interaction choice) categories. After each write it
/// awaits a read round-trip before callers `add` a request that references the new category, which
/// avoids delivering a notification whose actions are not registered yet.
@MainActor
final class NotificationCategoryRegistry {
    static let maximumDynamicCategories = 32

    private let client: UserNotificationCenterClient
    private let staticCategories: [String: NotificationCategorySpec]
    private var dynamicCategories: [String: NotificationCategorySpec] = [:]
    private var didInstall = false

    init(client: UserNotificationCenterClient, staticCategories: Set<NotificationCategorySpec>) {
        self.client = client
        self.staticCategories = Dictionary(
            staticCategories.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var registeredIdentifiers: Set<String> {
        Set(staticCategories.keys).union(dynamicCategories.keys)
    }

    var dynamicIdentifiers: Set<String> {
        Set(dynamicCategories.keys)
    }

    /// Registers the static set only, dropping dynamic categories left by a previous launch.
    func installStaticCategories() async {
        dynamicCategories.removeAll()
        didInstall = true
        await writeRegisteredSet()
    }

    /// Ensures `spec` is registered. Returns `false` when the dynamic cap is reached; callers then
    /// fall back to an Open-only category.
    @discardableResult
    func ensureRegistered(_ spec: NotificationCategorySpec) async -> Bool {
        if staticCategories[spec.identifier] == spec || dynamicCategories[spec.identifier] == spec {
            if !didInstall {
                didInstall = true
                await writeRegisteredSet()
            }
            return true
        }
        if staticCategories[spec.identifier] != nil {
            // Static identifiers are fixed; a mismatched spec would silently rewrite a shared category.
            return false
        }
        guard dynamicCategories[spec.identifier] != nil
            || dynamicCategories.count < Self.maximumDynamicCategories
        else {
            return false
        }
        dynamicCategories[spec.identifier] = spec
        didInstall = true
        await writeRegisteredSet()
        return true
    }

    /// Drops dynamic categories that no live notification references.
    func pruneDynamicCategories(keeping identifiers: Set<String>) async {
        let stale = Set(dynamicCategories.keys).subtracting(identifiers)
        guard !stale.isEmpty else { return }
        for identifier in stale {
            dynamicCategories.removeValue(forKey: identifier)
        }
        await writeRegisteredSet()
    }

    private func writeRegisteredSet() async {
        let all = Set(staticCategories.values).union(dynamicCategories.values)
        await client.setCategories(all)
        _ = await client.registeredCategoryIdentifiers()
    }
}
