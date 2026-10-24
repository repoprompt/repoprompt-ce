import AppKit
import Combine
import Foundation
import RepoPromptProviderQuota
import RepoPromptSettingsCore

/// Independent routing leases. Consent belongs to composition, never to observers.
/// Decisions read memory only; coalesced acquisition starts after routing activity.
@MainActor
final class ProviderUsageRoutingObservation {
    private let settings: GlobalSettingsStore
    private let codex: CodexProviderQuotaService
    private let claude: ProviderAccountQuotaService
    private let advisor: AgentUsageBalancer
    private let budget: ProviderUsageRefreshBudget
    private let accountID: @Sendable () async -> String?
    private let profileProvider: () -> String
    private let isAppActive: () -> Bool
    private var observation: AnyCancellable?
    private var inactivityObservation: AnyCancellable?
    private var refreshGrant: ClaudeCLIUsageGrant?
    private var codexLease: Task<Void, Never>?
    private var claudeLease: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var profile: String?
    private var active = false
    private var backgroundPermitted = false
    private var generation: UInt64 = 0

    init(
        settings: GlobalSettingsStore,
        codex: CodexProviderQuotaService,
        claude: ProviderAccountQuotaService,
        advisor: AgentUsageBalancer,
        accountID: @escaping @Sendable () async -> String?,
        profileProvider: @escaping () -> String = { ClaudeUsageCredentialProfile.current().id },
        isAppActive: @escaping () -> Bool = { NSApplication.shared.isActive },
        budgetURL: URL? = nil
    ) {
        self.settings = settings
        self.codex = codex
        self.claude = claude
        self.advisor = advisor
        self.accountID = accountID
        self.profileProvider = profileProvider
        self.isAppActive = isAppActive
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RepoPrompt CE/UsageRefreshBudget", isDirectory: true)
        budget = ProviderUsageRefreshBudget(url: budgetURL ?? directory.appendingPathComponent("claude.json"))
        observation = settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.reconcile() }
        advisor.onRoutingActivity = { [weak self] in self?.routingActivity() }
        inactivityObservation = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.stopRefresh() }
        reconcile()
    }

    deinit { codexLease?.cancel()
        claudeLease?.cancel()
        refreshTask?.cancel()
    }

    var hasObserverDemand: Bool {
        codexLease != nil || claudeLease != nil
    }

    private func stopRefresh() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        if let id = refreshID {
            Task { [claude] in await claude.cancelAdvisoryRefresh(requestID: id) }
        }
        refreshID = nil
    }

    private func reconcile() {
        let configuration = settings.modelRouterConfiguration()
        let requested = configuration.usageBalancing.enabled
        let currentProfile = profileProvider()
        let sourceGrant = settings.claudeCLIUsageGrant()
        let claudeAllowed = requested && sourceGrant?.isReady == true && sourceGrant?.applies(toProfileID: currentProfile) == true
        let grant = settings.scalarPreferences.agentMode?.claudeBalancingRefreshGrant
        let permitted = claudeAllowed && grant?.applies(toProfileID: currentProfile) == true
        if active != requested || profile != (claudeAllowed ? currentProfile : nil) || refreshGrant != grant || backgroundPermitted != permitted {
            stopRefresh()
        }
        active = requested
        refreshGrant = grant
        backgroundPermitted = permitted
        reconcileCodexLease(allowed: requested && settings.codexUsageQuotaEnabled())
        reconcileClaudeLease(allowed: claudeAllowed, currentProfile: currentProfile)
    }

    private func reconcileCodexLease(allowed: Bool) {
        guard allowed else {
            codexLease?.cancel()
            codexLease = nil
            advisor.update(nil, provider: AgentProviderKind.codexExec.rawValue)
            return
        }
        guard codexLease == nil else { return }
        codexLease = Task { [weak self, codex, accountID] in
            for await status in await codex.subscribe() {
                guard !Task.isCancelled, let self else { return }
                if case .loading = status { continue }
                let value = Self.snapshot(status)
                let currentID = await accountID()
                guard !Task.isCancelled, active, settings.codexUsageQuotaEnabled() else { continue }
                let attributed = value?.accountKey.lineage == .codexFirstParty && value?.accountKey.opaqueAccountID == currentID && currentID != nil
                advisor.update(attributed ? value : nil, provider: AgentProviderKind.codexExec.rawValue)
            }
        }
    }

    private func reconcileClaudeLease(allowed: Bool, currentProfile: String) {
        guard allowed else {
            profile = nil
            claudeLease?.cancel()
            claudeLease = nil
            advisor.update(nil, provider: AgentProviderKind.claudeCode.rawValue)
            return
        }
        if profile != currentProfile {
            claudeLease?.cancel()
            claudeLease = nil
            advisor.update(nil, provider: AgentProviderKind.claudeCode.rawValue)
        }
        profile = currentProfile
        guard claudeLease == nil else { return }
        claudeLease = Task { [weak self, claude] in
            for await status in await claude.subscribe() {
                guard !Task.isCancelled, let self else { return }
                if case .loading = status { continue }
                let value = Self.snapshot(status)
                let grant = settings.claudeCLIUsageGrant()
                guard active, profile == currentProfile, grant?.isReady == true,
                      grant?.applies(toProfileID: currentProfile) == true, profileProvider() == currentProfile else { continue }
                let attributed = value?.source == .claudeCLIUsage && value?.accountKey.credentialProfileID == currentProfile
                advisor.update(attributed ? value : nil, provider: AgentProviderKind.claudeCode.rawValue)
            }
        }
    }

    private func routingActivity() {
        reconcile() // Fail closed on an external profile switch, without provider IO.
        guard active, isAppActive() else { return }
        if codexLease != nil { Task { [codex] in await codex.refreshForAdvisory() } }
        guard backgroundPermitted, refreshTask == nil, let profile else { return }
        let expected = generation
        let id = UUID()
        refreshID = id
        refreshTask = Task { [weak self, claude, budget] in
            let cached = await claude.latestSnapshot()
            guard !Task.isCancelled, let self, generation == expected, backgroundPermitted else { return }
            if let cached, Date().timeIntervalSince(cached.observedAt) < 1800 {
                refreshTask = nil
                refreshID = nil
                return
            }
            await claude.refreshForAdvisory(requestID: id) {
                guard !Task.isCancelled else { return false }
                return await budget.reserve(profile: profile, minimumGap: 1800, dailyLimit: 12)
            }
            if generation == expected { refreshTask = nil
                refreshID = nil
            }
        }
    }

    private static func snapshot(_ status: ProviderQuotaStatus) -> ProviderQuotaSnapshot? {
        switch status {
        case let .loaded(value): value
        case let .failed(_, previous): previous
        default: nil
        }
    }
}
