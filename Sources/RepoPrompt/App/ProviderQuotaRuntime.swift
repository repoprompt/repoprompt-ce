import AppKit
import Combine
import Foundation
import RepoPromptProviderQuota
import RepoPromptSettingsCore

/// One app-owned composition root. Construction performs no provider IO. Sources retain the
/// sole account caches; Settings, the small status pill, and future advisory consumers share them.
@MainActor
final class ProviderQuotaRuntime {
    let codex: CodexProviderQuotaService
    let claude: ProviderAccountQuotaService
    let claudeTelemetry = ClaudeRunRateLimitTelemetryService()
    let data: ProviderUsageHub
    let codexUI: ProviderQuotaUIStore
    let claudeUI: ProviderQuotaUIStore
    let codexIndicator: ProviderQuotaIndicatorStore
    let claudeIndicator: ProviderQuotaIndicatorStore
    private let claudeSource: ClaudeAccountUsageSource
    private let settingsStore: GlobalSettingsStore
    private var claudeConnectionGeneration: UInt64 = 0
    private var foregroundObservation: AnyCancellable?
    var currentClaudeUsageProfileID: String {
        ClaudeUsageCredentialProfile.current().id
    }

    init(
        codexClientFactory: @escaping @Sendable () -> any CodexQuotaAppServerClient = {
            CodexQuotaAppServerAdapter(client: CodexProviderHelpers.makeOwnedNonAgentAppServerClient())
        },
        accountIDProvider: @escaping @Sendable () async -> String? = {
            await CodexManagedAuthRecoveryService.shared.managedAccountSnapshot()?.accountID
        },
        settingsStore: GlobalSettingsStore = .shared
    ) {
        self.settingsStore = settingsStore
        let codex = CodexProviderQuotaService(clientFactory: codexClientFactory, accountIDProvider: accountIDProvider)
        let source = ClaudeAccountUsageSource(consentProvider: {
            await settingsStore.claudeAccountUsageGrant()?.credentialProfileID
        })
        claudeSource = source
        let claude = ProviderAccountQuotaService(read: { context in try await source.read(context) })
        self.codex = codex
        self.claude = claude
        data = ProviderUsageHub(sources: [.codex: codex, .claude: claude])
        codexUI = ProviderQuotaUIStore(
            service: codex,
            settingsProvider: { settingsStore.codexUsageQuotaEnabled() },
            presentationProvider: { settingsStore.usageLimitsDisplayEnabled() }
        )
        claudeUI = ProviderQuotaUIStore(
            service: claude,
            settingsProvider: {
                settingsStore.claudeAccountUsageGrant()?.credentialProfileID == ClaudeUsageCredentialProfile.current().id
            },
            presentationProvider: { settingsStore.usageLimitsDisplayEnabled() }
        )
        codexIndicator = ProviderQuotaIndicatorStore(store: codexUI)
        claudeIndicator = ProviderQuotaIndicatorStore(store: claudeUI)
        // One app-level foreground hook, not one listener per pill/window. Hidden stores
        // immediately return without creating acquisition work.
        foregroundObservation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.codexUI.refreshOnForeground()
                self?.claudeUI.refreshOnForeground()
            }
    }

    func applyUsageDisplayEnabled(_ enabled: Bool) {
        if !enabled {
            claudeConnectionGeneration &+= 1
            Task { [claudeSource] in await claudeSource.cancelUserConnection() }
        }
        codexUI.setPresentationEnabled(enabled)
        claudeUI.setPresentationEnabled(enabled)
    }

    func applyCodexUsageEnabled(_ enabled: Bool) {
        codexUI.setEnabled(enabled)
    }

    /// Only called after the UI's explicit read-only credential disclosure. A prior passive
    /// SDK setting is deliberately not migrated into this profile-scoped consent record.
    func connectClaudeUsage() {
        claudeConnectionGeneration &+= 1
        let generation = claudeConnectionGeneration
        let profileID = currentClaudeUsageProfileID
        settingsStore.setClaudeAccountUsageGrant(ClaudeAccountUsageGrant(credentialProfileID: profileID, grantedAt: Date()))
        Task { [weak self, claudeSource, claude] in
            await claudeSource.prepareUserConnection()
            guard let self, claudeConnectionGeneration == generation,
                  settingsStore.claudeAccountUsageGrant()?.credentialProfileID == profileID else { return }
            await claude.invalidate()
            guard claudeConnectionGeneration == generation,
                  settingsStore.claudeAccountUsageGrant()?.credentialProfileID == profileID else { return }
            claudeUI.setEnabled(true)
        }
    }

    func disconnectClaudeUsage() {
        claudeConnectionGeneration &+= 1
        settingsStore.setClaudeAccountUsageGrant(nil)
        claudeUI.setEnabled(false)
        Task { [claudeSource] in await claudeSource.cancelUserConnection() }
    }
}

@MainActor
enum CodexUsageQuotaRuntimeBridge {
    static var applyEnabled: (Bool) -> Void = { enabled in
        WindowStatesManager.shared.providerQuotaRuntime.applyCodexUsageEnabled(enabled)
    }
}

@MainActor
enum ClaudeUsageQuotaRuntimeBridge {
    static var applyEnabled: (Bool) -> Void = { enabled in
        Task { await WindowStatesManager.shared.providerQuotaRuntime.claudeTelemetry.setEnabled(enabled) }
    }
}
