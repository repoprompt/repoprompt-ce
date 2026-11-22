/// Read-only projection. A saved default is a preference, never evidence of sign-in or launch authority.
package struct SubscriptionAccountSettingsSnapshot: Equatable {
    package enum Gate: Equatable {
        case codexIdentityAndIsolationUnverified
        case claudeIdentityUnverified
    }

    package struct Row: Identifiable, Equatable {
        package let id: SubscriptionProfileID
        package let label: String
        package let isArchived: Bool
        package let isDefault: Bool
    }

    package let gate: Gate
    /// Nil means the catalog could not be loaded. Never substitute the legacy account in that case.
    package let defaultSelection: SubscriptionAccountSelection?
    package let rows: [Row]

    package init(backend: SubscriptionBackend, catalog: SubscriptionProfileCatalog?) {
        gate = switch backend {
        case .codex: .codexIdentityAndIsolationUnverified
        case .claudeCode: .claudeIdentityUnverified
        }
        let selection = catalog?.defaultSelection(for: backend)
        defaultSelection = selection
        rows = catalog?.profiles.compactMap { profile in
            guard profile.id.backend == backend else { return nil }
            return .init(
                id: profile.id,
                label: profile.label,
                isArchived: profile.isArchived,
                isDefault: selection == .profile(profile.id)
            )
        } ?? []
    }
}
