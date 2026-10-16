import Foundation

/// The user's global Overseer auto-approve ("yolo") setting, Settings › Agent Permissions › Overseer.
///
/// When on, an Agent session acting as Overseer is never stopped by an approval card, a missing
/// scope or capability, or the direct-child restriction on existing `agent_run` / `agent_manage`
/// target operations. Off by default. Written only by the Settings toggle; deliberately not exposed
/// through MCP `app_settings`, so an agent cannot turn it on.
@MainActor
enum OverseerGlobalAutoApprove {
    static let defaultsKey = "agentMode.delegation.autoApproveAllRequests"

    /// Injectable for tests; production reads the user's stored setting.
    static var isEnabled: @MainActor () -> Bool = {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
