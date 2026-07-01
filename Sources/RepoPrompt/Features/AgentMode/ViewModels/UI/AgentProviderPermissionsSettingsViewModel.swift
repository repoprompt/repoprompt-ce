//
//  AgentProviderPermissionsSettingsViewModel.swift
//  RepoPrompt
//
//  Focused view model for direct/top-level CLI provider permission controls.
//

import Combine
import Foundation

@MainActor
final class AgentProviderPermissionsSettingsViewModel: ObservableObject {
    /// Bumps on provider-native mutations or external secure-store changes so SwiftUI
    /// re-reads preference helpers, summaries, and controls snapshots.
    @Published private(set) var revision: Int = 0

    let defaults: UserDefaults
    let bindingService: AgentModeProviderBindingService?
    let securePermissions: AgentPermissionSecureStore?
    let diagnostics: AgentPermissionStorageDiagnosticsViewModel

    private let notificationCenter: NotificationCenter
    private var cancellables: Set<AnyCancellable> = []

    /// Fired after each provider-native mutation. Production wiring calls
    /// `AgentModeViewModel.providerPreferenceDidChange(_:)` so active sessions refresh.
    var onProviderPreferenceChanged: ((AgentProviderBindingID) -> Void)?
    /// Specialised hook for Claude effort-level changes. When provided, setting the
    /// effort level delegates end-to-end to this closure so active Claude sessions pick
    /// up the new effort via the existing AgentModeViewModel scheduling path.
    var onClaudeEffortLevelChanged: ((ClaudeCodeEffortLevel) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        bindingService: AgentModeProviderBindingService? = nil,
        securePermissions: AgentPermissionSecureStore? = nil,
        diagnostics: AgentPermissionStorageDiagnosticsViewModel? = nil,
        notificationCenter: NotificationCenter = .default,
        onProviderPreferenceChanged: ((AgentProviderBindingID) -> Void)? = nil,
        onClaudeEffortLevelChanged: ((ClaudeCodeEffortLevel) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.bindingService = bindingService
        let resolvedSecure: AgentPermissionSecureStore? = if let securePermissions {
            securePermissions
        } else if let fromBinding = bindingService?.preferences.securePermissions {
            fromBinding
        } else if defaults === UserDefaults.standard {
            AgentPermissionSecureStore.shared
        } else {
            nil
        }
        self.securePermissions = resolvedSecure
        self.diagnostics = diagnostics ?? AgentPermissionStorageDiagnosticsViewModel(
            securePermissions: resolvedSecure,
            notificationCenter: notificationCenter
        )
        self.notificationCenter = notificationCenter
        self.onProviderPreferenceChanged = onProviderPreferenceChanged
        self.onClaudeEffortLevelChanged = onClaudeEffortLevelChanged
        subscribeToSecureStoreChanges()
    }

    var storageDiagnostics: [AgentPermissionStorageDiagnostic] {
        diagnostics.storageDiagnostics
    }

    var isSecurePermissionStorageDegraded: Bool {
        diagnostics.isSecurePermissionStorageDegraded
    }

    /// Provider-native controls snapshot for editable direct-agent settings rows.
    /// Returns `nil` when the VM was constructed without a binding service (preview /
    /// unit-test fallback contexts).
    func controlsBinding(for providerID: AgentProviderBindingID) -> AgentProviderControlsBinding? {
        guard let bindingService else { return nil }
        _ = revision // ensure SwiftUI redraws when this VM publishes changes
        return bindingService.topLevelSettingsControlsBinding(providerID: providerID)
    }

    func summaries(
        availability: AgentModelCatalog.AvailabilityContext
    ) -> [AgentPermissionCapabilitySummary] {
        _ = revision
        return AgentPermissionCapabilitySummaryBuilder(
            defaults: defaults,
            securePermissions: securePermissions
        ).summaries(profile: .userConfigured, availability: availability)
    }

    func setPermissionLevel(_ id: AgentProviderPermissionLevelID) {
        if let bindingService {
            bindingService.setPermissionLevel(id)
        } else {
            Self.writePermissionLevelDirect(id, defaults: defaults, securePermissions: securePermissions)
        }
        finalizeProviderMutation(for: id.providerID)
    }

    func applyCodexToolSettingMutation(_ mutation: CodexToolSettingMutation) {
        if let bindingService {
            bindingService.applyCodexToolSettingMutation(mutation)
        } else {
            switch mutation {
            case let .bashTool(enabled):
                CodexAgentToolPreferences.setBashToolEnabled(enabled, defaults: defaults, secureStore: securePermissions)
            case let .searchTool(enabled):
                CodexAgentToolPreferences.setSearchToolEnabled(enabled, defaults: defaults)
            case let .goalSupport(enabled):
                CodexAgentModeBooleanPreference.goalSupport.setEnabled(enabled, defaults: defaults)
            case let .reasoningSummaries(enabled):
                CodexAgentModeBooleanPreference.reasoningSummaries.setEnabled(enabled, defaults: defaults)
            case let .mcpServer(normalizedName, enabled):
                CodexAgentToolPreferences.setMCPServerEnabled(
                    normalizedName: normalizedName,
                    isEnabled: enabled,
                    defaults: defaults,
                    secureStore: securePermissions
                )
            }
        }
        finalizeProviderMutation(for: .codex)
    }

    func applyClaudeToolSettingMutation(_ mutation: ClaudeToolSettingMutation) {
        if let bindingService {
            bindingService.applyClaudeToolSettingMutation(mutation)
        } else {
            switch mutation {
            case let .bashTool(enabled):
                ClaudeAgentToolPreferences.setBashToolEnabled(enabled, defaults: defaults, secureStore: securePermissions)
            case let .mcpStrictMode(enabled):
                ClaudeAgentToolPreferences.setMCPStrictModeEnabled(enabled, defaults: defaults, secureStore: securePermissions)
            case let .toolSearch(enabled):
                ClaudeAgentToolPreferences.setToolSearchEnabled(enabled, defaults: defaults)
            case let .agentModePromptDelivery(delivery):
                ClaudeAgentToolPreferences.setAgentModePromptDelivery(delivery, defaults: defaults)
            }
        }
        finalizeProviderMutation(for: .claude)
    }

    func setClaudeEffortLevel(_ level: ClaudeCodeEffortLevel) {
        if let onClaudeEffortLevelChanged {
            onClaudeEffortLevelChanged(level)
            diagnostics.refresh()
            revision &+= 1
            return
        }
        if let bindingService {
            bindingService.setClaudeEffortLevel(level)
        } else {
            ClaudeAgentToolPreferences.setEffortLevel(level, defaults: defaults)
        }
        finalizeProviderMutation(for: .claude)
    }

    private func finalizeProviderMutation(for providerID: AgentProviderBindingID) {
        diagnostics.refresh()
        // Whether healthy or degraded, re-publish so views re-read the effective secure
        // values. When a secure write failed, helpers fail closed to safe/previous values.
        revision &+= 1
        onProviderPreferenceChanged?(providerID)
    }

    private static func writePermissionLevelDirect(
        _ id: AgentProviderPermissionLevelID,
        defaults: UserDefaults,
        securePermissions: AgentPermissionSecureStore?
    ) {
        switch id {
        case let .codex(level):
            CodexAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
        case let .claude(level):
            ClaudeAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
        case let .openCode(level):
            OpenCodeAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
        case let .cursor(level):
            CursorAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
        }
    }

    private func subscribeToSecureStoreChanges() {
        notificationCenter.publisher(for: .agentPermissionSecureStoreDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleSecureStoreDidChange()
            }
            .store(in: &cancellables)
    }

    private func handleSecureStoreDidChange() {
        diagnostics.refresh()
        revision &+= 1
    }
}
