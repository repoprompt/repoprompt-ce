import Foundation
import RepoPromptProviderQuota

// SEARCH-HELPER: Claude SDK rate_limit_event to usage pill, display overlay forwarding, display consent gate
//
// One app-level subscription that forwards passive Claude run telemetry into the Claude usage
// display as a display-only overlay (`ProviderQuotaUIStore.applyDisplayOverlay`).
//
// Consent: the overlay is applied only while the user's Claude usage display is consented
// (usage display on + ready CLI usage grant for the current profile — see
// `GlobalSettingsStore.claudeUsageDisplayConsented`). The diagnostics toggle alone may record
// telemetry but never puts it on the pill. Without consent the overlay is cleared.
//
// Display-only: nothing here writes to a quota service, routing observation, or balancing.
// The merge itself still refuses a run from a different credential profile.
@MainActor
package final class ClaudeRunTelemetryDisplayBridge {
    private var task: Task<Void, Never>?

    package init(
        telemetry: ClaudeRunRateLimitTelemetryService,
        store: ProviderQuotaUIStore,
        displayConsented: @escaping @MainActor () -> Bool
    ) {
        task = Task { [weak store] in
            for await status in await telemetry.subscribe() {
                guard !Task.isCancelled, let store else { return }
                switch status {
                case let .loaded(snapshot):
                    store.applyDisplayOverlay(displayConsented() ? snapshot : nil)
                case .disabled:
                    store.applyDisplayOverlay(nil)
                case .idle, .loading, .unavailable, .failed:
                    continue
                }
            }
        }
    }

    deinit {
        task?.cancel()
    }
}
