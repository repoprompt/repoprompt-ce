import Foundation

extension Notification.Name {
    static let showAPISettingsTab = Notification.Name("showAPISettingsTab")
    /// General request to open/focus the dedicated Settings window (Appearance / current tab).
    /// `object` should be the WindowState to target; when omitted, the focused/latest window is used.
    static let showSettingsPopover = Notification.Name("showSettingsPopover")
    static let showManageWorkspacesTab = Notification.Name("showManageWorkspacesTab")
    static let showManagePresetsTab = Notification.Name("showManagePresetsTab")
    /// Posted when the UI should present the "Create Preset" naming sheet
    static let showCreatePresetSheet = Notification.Name("showCreatePresetSheet")
    /// Posted when the UI should show the MCP settings tab
    static let showMCPSettingsTab = Notification.Name("showMCPSettingsTab")
    /// Posted when the UI should show the CLI Providers settings tab
    static let showCLIProvidersTab = Notification.Name("showCLIProvidersTab")
    /// Posted when the UI should show the Agent Mode settings tab
    static let showAgentModeSettingsTab = Notification.Name("showAgentModeSettingsTab")
    /// Posted when the UI should open Settings to the Agent Models tab.
    static let showAgentModelsSettingsTab = Notification.Name("showAgentModelsSettingsTab")
    /// Posted when the UI should open Settings to the Agent Permissions tab.
    ///
    /// Callers that want to preselect a scope should also set
    /// `AgentPermissionsScopeRouter.shared.requestScope(...)` before posting so
    /// the scope is applied whether the Agent Permissions view is already
    /// mounted or is about to mount for the first time.
    static let showAgentPermissionsSettingsTab = Notification.Name("showAgentPermissionsSettingsTab")
    /// Posted when the UI should open Settings to the Workspace Approvals tab.
    static let showWorkspaceApprovalsSettingsTab = Notification.Name("showWorkspaceApprovalsSettingsTab")
    /// Posted alongside a settings navigation to pre-select a scope inside the
    /// Agent Permissions tab. Post this on the main queue *after* the tab
    /// switch so the Agent Permissions view is already mounted and its
    /// `.onReceive` subscription is active.
    /// userInfo: ["scope": AgentPermissionSettingsScope.rawValue (String)]
    static let setAgentPermissionsScope = Notification.Name("setAgentPermissionsScope")
    /// Posted when the UI should show the Keyboard Shortcuts settings tab.
    /// `userInfo["windowID"]` should be the target window ID (optional; when omitted, any open settings sheet may react).
    static let showKeyboardShortcutsSettingsTab = Notification.Name("showKeyboardShortcutsSettingsTab")
    /// Posted when the UI should show the Model Presets settings tab
    static let showModelPresetsTab = Notification.Name("showModelPresetsTab")
    /// Posted when the UI should show the Copy Presets settings tab
    static let showCopyPresetsTab = Notification.Name("showCopyPresetsTab")
    /// Posted when the UI should show the Chat Presets settings tab
    static let showChatPresetsTab = Notification.Name("showChatPresetsTab")
    /// Posted when recommendation wizard applies settings - triggers PromptViewModel to reload
    static let recommendationsDidApply = Notification.Name("recommendationsDidApply")
    /// Posted when underlying inputs for recommendations change (not an "apply" event).
    /// Triggers wizard to recompute without affecting other VMs.
    /// userInfo may include: ["workspaceID": UUID, "reason": String]
    static let recommendationsShouldRefresh = Notification.Name("recommendationsShouldRefresh")
    /// Request to open the recommendation wizard popover for a specific window.
    /// userInfo: ["windowID": Int, "step": String?]
    static let showRecommendationWizard = Notification.Name("showRecommendationWizard")
    /// Posted when a new workspace is created (for auto-apply recommendations).
    /// userInfo: ["workspaceID": UUID]
    static let workspaceDidCreate = Notification.Name("workspaceDidCreate")
    /// Posted when the UI should show the Context Builder settings tab.
    static let showContextBuilderSettingsTab = Notification.Name("showContextBuilderSettingsTab")
    /// Posted when the UI should show the Updates settings tab.
    static let showLicenseUpdatesTab = Notification.Name("showLicenseUpdatesTab")
    /// Posted when the UI should show the agent onboarding wizard.
    /// userInfo: ["windowID": Int]
    static let showAgentOnboardingWizard = Notification.Name("showAgentOnboardingWizard")
    /// Posted when the UI should open the MCP server toolbar popover.
    /// userInfo: ["windowID": Int]
    static let showMCPServerPopover = Notification.Name("showMCPServerPopover")
    /// Posted when Agent Mode should open the Oracle pill popover.
    /// userInfo: ["windowID": Int, "tabID": UUID?, "chatID": String?]
    static let showAgentOraclePopover = Notification.Name("showAgentOraclePopover")
    /// Posted when Agent Mode should open the Workflow pill popover.
    /// userInfo: ["windowID": Int]
    static let showAgentWorkflowPopover = Notification.Name("showAgentWorkflowPopover")
    /// Posted by WorkspaceManagerViewModel when workspace switch overlay visibility changes.
    /// object: WorkspaceManagerViewModel instance (window-scoped)
    /// userInfo: ["isVisible": Bool]
    static let workspaceSwitchOverlayDidChange = Notification.Name("workspaceSwitchOverlayDidChange")
    /// Posted when a compose tab's persisted display name changes.
    /// userInfo: ["tabID": UUID, "windowID": Int, "name": String]
    static let composeTabNameChanged = Notification.Name("composeTabNameChanged")

    /// Toggle the Agent session sidebar for the focused window.
    /// `userInfo["windowID"]` should be the target window ID.
    static let toggleRepoPromptNavigationSidebar = Notification.Name("toggleRepoPromptNavigationSidebar")
}
