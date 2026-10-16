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
        // Like AppLaunchConfiguration.isUnitTestProcess: an XCTest process can share the debug
        // app's defaults domain and must never inherit the user's real full-access choice. Tests
        // that exercise full access set this closure explicitly.
        guard !isUnitTestProcess else { return false }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    private static var isUnitTestProcess: Bool {
        #if DEBUG
            Bundle.main.bundleURL.pathExtension == "xctest"
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil
        #else
            false
        #endif
    }
}
