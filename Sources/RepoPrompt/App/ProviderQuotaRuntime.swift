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
    let usageAdvisor = AgentUsageBalancer()
    private var routingObservation: ProviderUsageRoutingObservation?
    let codexUI: ProviderQuotaUIStore
    let claudeUI: ProviderQuotaUIStore
    let codexIndicator: ProviderQuotaIndicatorStore
    let claudeIndicator: ProviderQuotaIndicatorStore
    private let claudeSource: ClaudeCLIUsageSource
    private let settingsStore: GlobalSettingsStore
    private var claudeConnectionGeneration: UInt64 = 0
    private var foregroundObservation: AnyCancellable?
    private var consentObservation: AnyCancellable?
    private var consentTask: Task<Void, Never>?
    private var telemetryDisplayBridge: ClaudeRunTelemetryDisplayBridge?
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
        let source = ClaudeCLIUsageSource(consentProvider: {
            let grant = await settingsStore.claudeCLIUsageGrant()
            return grant?.isReady == true && grant?.applies(toProfileID: ClaudeUsageCredentialProfile.current().id) == true ? grant?.credentialProfileID : nil
        })
        claudeSource = source
        let claude = ProviderAccountQuotaService(periodicReads: false, cachedRead: { await source.cachedSnapshot() }, read: { context in try await source.read(context) })
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
                let grant = settingsStore.claudeCLIUsageGrant()
                return grant?.isReady == true && grant?.applies(toProfileID: ClaudeUsageCredentialProfile.current().id) == true
            },
            presentationProvider: { settingsStore.usageLimitsDisplayEnabled() }
        )
        codexIndicator = ProviderQuotaIndicatorStore(store: codexUI)
        claudeIndicator = ProviderQuotaIndicatorStore(store: claudeUI)
        consentObservation = settingsStore.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.applyAcquisitionConsent() }
        applyAcquisitionConsent()
        routingObservation = ProviderUsageRoutingObservation(settings: settingsStore, codex: codex, claude: claude, advisor: usageAdvisor, accountID: accountIDProvider)
        // One app-level foreground hook, not one listener per pill/window. Hidden stores
        // immediately return without creating acquisition work.
        foregroundObservation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.codexUI.refreshOnForeground()
                self?.claudeUI.refreshOnForeground()
            }
        // One app-level subscription. Passive SDK `rate_limit_event` telemetry refreshes the
        // *displayed* Claude snapshot during runs without another CLI launch. It is recorded and
        // shown by default once Claude usage display is connected (no diagnostics toggle
        // needed: it is the run's own output, no extra read or credential). Display-only: the
        // overlay is merged in the UI projection, never into `claude`, routing, or balancing,
        // and the merge refuses a run whose Claude profile differs from the displayed one.
        telemetryDisplayBridge = ClaudeRunTelemetryDisplayBridge(
            telemetry: claudeTelemetry,
            store: claudeUI,
            displayConsented: { settingsStore.claudeUsageDisplayConsented(profileID: ClaudeUsageCredentialProfile.current().id) }
        )
    }

    /// Source authorization has one truth: persisted consent and completed setup. Routing
    /// leases only subscribe; they cannot override a UI setup/disconnect transition.
    /// Run telemetry recording follows the same settings (diagnostics toggle OR connected
    /// usage display), applied in this one ordered task so toggles cannot reorder.
    func applyAcquisitionConsent() {
        consentTask?.cancel()
        consentTask = Task { [weak self, codex, claude, claudeTelemetry] in
            guard let self, !Task.isCancelled else { return }
            await codex.setEnabled(settingsStore.codexUsageQuotaEnabled())
            guard !Task.isCancelled else { return }
            let grant = settingsStore.claudeCLIUsageGrant()
            await claude.setEnabled(grant?.isReady == true && grant?.applies(toProfileID: currentClaudeUsageProfileID) == true)
            guard !Task.isCancelled else { return }
            await claudeTelemetry.setEnabled(settingsStore.claudeRunTelemetryRecordingEnabled(profileID: currentClaudeUsageProfileID))
        }
    }

    func applyUsageDisplayEnabled(_ enabled: Bool) {
        if !enabled {
            claudeConnectionGeneration &+= 1
        }
        codexUI.setPresentationEnabled(enabled)
        claudeUI.setPresentationEnabled(enabled)
        applyAcquisitionConsent()
    }

    func applyCodexUsageEnabled(_ enabled: Bool) {
        codexUI.setEnabled(enabled)
    }

    /// Only called after the UI's explicit CLI usage disclosure. A prior passive
    /// SDK setting is deliberately not migrated into this profile-scoped consent record.
    func connectClaudeUsage(startReading: Bool = true) {
        claudeConnectionGeneration &+= 1
        let generation = claudeConnectionGeneration
        let profileID = currentClaudeUsageProfileID
        settingsStore.setClaudeAccountUsageGrant(nil)
        settingsStore.setClaudeCLIUsageGrant(ClaudeCLIUsageGrant(credentialProfileID: profileID, grantedAt: Date(), setupCompleted: startReading))
        if !startReading { claudeUI.setEnabled(false) }
        Task { [weak self, claude] in
            guard let self, claudeConnectionGeneration == generation,
                  settingsStore.claudeCLIUsageGrant()?.applies(toProfileID: profileID) == true else { return }
            await claude.invalidate()
            guard claudeConnectionGeneration == generation,
                  settingsStore.claudeCLIUsageGrant()?.applies(toProfileID: profileID) == true else { return }
            claudeUI.setEnabled(startReading)
        }
    }

    /// An explicit setup-completion transition, not a bypass of ordinary Refresh throttling.
    func completeClaudeUsageSetup() async throws {
        claudeConnectionGeneration &+= 1
        let generation = claudeConnectionGeneration
        let profileID = currentClaudeUsageProfileID
        guard let grant = settingsStore.claudeCLIUsageGrant(), grant.applies(toProfileID: profileID) else { throw ProviderQuotaReadError.needsConsent }
        settingsStore.setClaudeCLIUsageGrant(ClaudeCLIUsageGrant(credentialProfileID: profileID, grantedAt: grant.grantedAt, setupCompleted: true))
        await claude.invalidate()
        guard generation == claudeConnectionGeneration,
              settingsStore.claudeCLIUsageGrant()?.applies(toProfileID: profileID) == true else { throw ProviderQuotaReadError.needsConsent }
        claudeUI.setEnabled(true)
        claudeUI.refresh()
    }

    func prepareClaudeUsageSetup() async throws -> URL {
        let generation = claudeConnectionGeneration
        let url = try await claudeSource.prepareSetup()
        guard generation == claudeConnectionGeneration,
              settingsStore.claudeCLIUsageGrant()?.applies(toProfileID: currentClaudeUsageProfileID) == true else { throw ProviderQuotaReadError.needsConsent }
        return url
    }

    func disconnectClaudeUsage() {
        claudeConnectionGeneration &+= 1
        let generation = claudeConnectionGeneration
        settingsStore.setClaudeAccountUsageGrant(nil)
        settingsStore.setClaudeCLIUsageGrant(nil)
        settingsStore.setClaudeBalancingRefreshGrant(nil)
        claudeUI.setEnabled(false)
        Task { [weak self, claudeSource] in
            guard let self, claudeConnectionGeneration == generation else { return }
            await claudeSource.clearCache()
        }
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
    /// The diagnostics toggle was already persisted; recording is the combined policy
    /// (diagnostics OR connected usage display), so turning diagnostics off never stops the
    /// display's own telemetry.
    static var applyEnabled: (Bool) -> Void = { _ in
        WindowStatesManager.shared.providerQuotaRuntime.applyAcquisitionConsent()
    }
}
