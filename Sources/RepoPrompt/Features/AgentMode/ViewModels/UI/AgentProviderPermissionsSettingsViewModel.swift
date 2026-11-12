//
//  AgentProviderPermissionsSettingsViewModel.swift
//  RepoPrompt
//
//  Focused view model for direct/top-level CLI provider permission controls.
//

import Combine
import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts

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
    var claudeEffortLevelProvider: (() -> ClaudeCodeEffortLevel?)?

    init(
        defaults: UserDefaults = .standard,
        bindingService: AgentModeProviderBindingService? = nil,
        securePermissions: AgentPermissionSecureStore? = nil,
        diagnostics: AgentPermissionStorageDiagnosticsViewModel? = nil,
        notificationCenter: NotificationCenter = .default,
        onProviderPreferenceChanged: ((AgentProviderBindingID) -> Void)? = nil,
        claudeEffortLevelProvider: (() -> ClaudeCodeEffortLevel?)? = nil,
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
        self.claudeEffortLevelProvider = claudeEffortLevelProvider
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
        return bindingService.topLevelSettingsControlsBinding(
            providerID: providerID,
            claudeEffortLevel: providerID == .claude ? claudeEffortLevelProvider?() : nil
        )
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
            AgentProviderPreferenceSnapshotStore.writePermissionLevel(id, defaults: defaults, securePermissions: securePermissions)
        }
        finalizeProviderMutation(for: id.providerID)
    }

    func applyCodexToolSettingMutation(_ mutation: CodexToolSettingMutation) {
        if let bindingService {
            bindingService.applyCodexToolSettingMutation(mutation)
        } else {
            AgentProviderPreferenceSnapshotStore.writeCodexToolSettingMutation(mutation, defaults: defaults, securePermissions: securePermissions)
        }
        finalizeProviderMutation(for: .codex)
    }

    func applyClaudeToolSettingMutation(_ mutation: ClaudeToolSettingMutation) {
        if let bindingService {
            bindingService.applyClaudeToolSettingMutation(mutation)
        } else {
            AgentProviderPreferenceSnapshotStore.writeClaudeToolSettingMutation(mutation, defaults: defaults, securePermissions: securePermissions)
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
