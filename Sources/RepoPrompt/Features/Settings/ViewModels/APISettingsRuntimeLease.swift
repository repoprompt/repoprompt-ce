import Foundation

/// A lease on the caller-supplied live settings authority, not a settings snapshot or a window
/// election. App composition can supply that same owner before any presentation is constructed.
@MainActor
final class APISettingsRuntimeLease {
    let settings: APISettingsViewModel
    private(set) var isReleased = false

    private init(settings: APISettingsViewModel) {
        self.settings = settings
        settings.retainForManagedRuntime()
    }

    static func acquire(from settings: APISettingsViewModel) -> APISettingsRuntimeLease? {
        guard settings.canAcquireManagedRuntimeLease else { return nil }
        return APISettingsRuntimeLease(settings: settings)
    }

    /// The resource owner calls this after joining its users. Releasing a settings lease does
    /// not cancel a session; it only permits the existing settings teardown request to finish.
    func release() {
        guard !isReleased else { return }
        isReleased = true
        settings.releaseManagedRuntime()
    }
}
