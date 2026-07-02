import Foundation

/// One removable listener-token registration. The token is removed via the
/// `@MainActor` closure supplied at registration time (e.g.
/// `promptManager.removeComposeTabsWillCloseListener(_:)`).
///
/// `removeAll()` on `ListenerRegistry` is `@MainActor` because token removal
/// hops to `@MainActor` managers. It is called from
/// `AgentModeViewModel.prepareForWindowClose()` (the primary teardown path).
/// The nonisolated `deinit` cannot safely call it; deinit relies on
/// `prepareForWindowClose()` having been called, matching the established
/// codebase convention (`WindowState.deinit`, `ContextBuilderAgentViewModel`).
@MainActor
struct ListenerRegistration {
    private let removal: @MainActor () -> Void

    init(removal: @escaping @MainActor () -> Void) {
        self.removal = removal
    }

    func performRemoval() {
        removal()
    }
}

/// Unified registry for listener-token registrations owned by
/// `AgentModeViewModel`. Replaces the per-token `UUID?` fields
/// (`tabCloseListenerToken`, `workspaceDidSwitchListenerToken`,
/// `beforeSaveListenerToken`) and the manual if-let-nil teardown in
/// `unregisterObserverRegistrations()` with a single `removeAll()` call.
///
/// Combine cancellables are intentionally kept on the view model as a
/// `Set<AnyCancellable>` because `AnyCancellable.cancel()` is nonisolated-safe
/// and the view model's `deinit` uses that as a best-effort fallback; token
/// removal requires `@MainActor` hops and cannot run in `deinit`.
@MainActor
final class ListenerRegistry {
    private var registrations: [ListenerRegistration] = []

    /// Registers a listener token returned by an `add*Listener` call. If the
    /// token is `nil` (the manager was unavailable), registration is skipped.
    func addToken(_ token: UUID?, remover: @escaping @MainActor (UUID) -> Void) {
        guard let token else { return }
        registrations.append(ListenerRegistration { remover(token) })
    }

    /// Removes all registered listeners in registration order and clears the
    /// registry. Safe to call multiple times; subsequent calls are no-ops.
    func removeAll() {
        for registration in registrations {
            registration.performRemoval()
        }
        registrations.removeAll()
    }
}
