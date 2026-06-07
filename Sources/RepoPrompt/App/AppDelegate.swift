import Cocoa
import Combine
import Darwin
import Sparkle
import SwiftUI

#if DEBUG
    private var appDelegateDebugLoggingEnabled = false
    private func appDelegateDebugLog(_ message: @autoclosure () -> String) {
        guard appDelegateDebugLoggingEnabled else { return }
        print("[AppDelegate] \(message())")
    }
#else
    private func appDelegateDebugLog(_ message: @autoclosure () -> String) {}
#endif

@MainActor
class AppDelegate: NSObject, ObservableObject, NSApplicationDelegate {
    /// Prevents re-entrant termination (Cmd+Q twice, menu + dock quit, etc.)
    private var terminationInProgress = false
    private let dockMenuController = DockMenuController()

    // New global routing/settings services (kept alive by the AppDelegate)
    private var windowRoutingService: WindowRoutingService?
    private var appSettingsMCPService: AppSettingsMCPService?

    // MARK: - Global references

    let sparkleManager: SparkleUpdaterManager

    /// NEW: weak reference injected by `RepoPromptApp`
    weak var windowStatesManager: WindowStatesManager?

    /// Additional global toggles
    let debugMode: Bool = false

    static var appCounter = 0

    // MARK: - Init

    override init() {
        appDelegateDebugLog("Appcounter \(AppDelegate.appCounter)")
        AppDelegate.appCounter += 1

        // Clean any corrupt Sparkle preferences before initializing
        SparkleUpdaterManager.cleanCorruptPreferences()

        // Initialize Sparkle updater
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        sparkleManager = SparkleUpdaterManager(updaterController: updaterController)
        SparkleUpdaterManager.shared = sparkleManager

        // super.init
        super.init()
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchConfiguration = AppLaunchConfiguration.current
        ProcessTermination.resetAppTerminationFastPath()

        if launchConfiguration.isUITestSession {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // Prevent crashes from broken pipes when a peer closes unexpectedly
        signal(SIGPIPE, SIG_IGN)

        AppearanceController.shared.applyFromGlobalSettings()

        // ───────────────────────────────────────────────────
        // Register global MCP app-wide helpers
        let appSettingsMCPService = AppSettingsMCPService()
        ServiceRegistry.register(appSettingsMCPService)
        self.appSettingsMCPService = appSettingsMCPService

        // Register global MCP window-routing helpers
        windowRoutingService = WindowRoutingService(
            windowStates: WindowStatesManager.shared,
            networkMgr: ServerNetworkManager.shared
        )
        if !launchConfiguration.suppressesNonessentialLaunchSideEffects {
            // Request notification authorization
            Task {
                await NotificationService.shared.requestAuthorization()
            }

            // Validate Codex prompts on app launch (if previously installed)
            Task.detached(priority: .utility) {
                await MCPPromptValidationService.shared.validateCodexPromptsOnLaunch()
            }
        }

        #if DEBUG
            sparkleManager.startUpdater()
            if !launchConfiguration.suppressesNonessentialLaunchSideEffects {
                Task {
                    // Ensure the user-space CLI symlink is available for external tools
                    CLISymlinkManagerUserSpace.ensureLocalSymlink()
                }
            }
            return
        #else
            sparkleManager.startUpdater()

            ApplicationSecurity.startMonitoring()
            ApplicationSecurity.enableAntiDebugging()

            Task {
                CLISymlinkManagerUserSpace.ensureLocalSymlink()
            }
        #endif
    }

    // MARK: - Application Lifecycle

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenuController.makeMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the app running if we intentionally backgrounded the last window.
        !MCPBackgroundModeCoordinator.shared.isBackgrounded
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, MCPBackgroundModeCoordinator.shared.isBackgrounded {
            MCPBackgroundModeCoordinator.shared.restore()
            return true
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Prevent re-entrancy (Cmd+Q twice, menu + dock quit, etc.)
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true

        // 1) Signal termination FIRST to prevent observation crashes.
        // This stops SwiftUI from trying to update views with deallocated objects
        // during the shutdown sequence (fixes EXC_BAD_ACCESS in ObservationRegistrar).
        WindowStatesManager.shared.signalTermination()
        ProcessTermination.beginAppTerminationFastPath()
        MCPBackgroundModeCoordinator.shared.resetForTermination()

        // 2) Persist the final restorable window session before async shutdown begins.
        // Using .terminateLater lets us do async work without deadlocking.
        Task { @MainActor in
            if !AppLaunchConfiguration.current.suppressesWindowPersistence {
                await WindowStatesManager.shared.persistWindowSessionImmediately(reason: "appShouldTerminate")
            }

            // 3) Shut down agent processes and MCP tools on the main actor WITHOUT blocking.
            // Kill Claude CLI and Codex app-server processes BEFORE stopping MCP servers,
            // so child processes are terminated and reaped rather than orphaned on quit.
            await WindowStatesManager.shared.shutdownAllAgentSessions()
            await WindowStatesManager.shared.stopAllServers()
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("Application is terminating...")

        // Defensive fallback: ensure termination flag is set and session is persisted.
        // These are fast, synchronous, and idempotent.
        MCPBackgroundModeCoordinator.shared.resetForTermination()
        WindowStatesManager.shared.signalTermination()
        ProcessTermination.beginAppTerminationFastPath()
        if !AppLaunchConfiguration.current.suppressesWindowPersistence {
            WindowStatesManager.shared.persistWindowSession(reason: "appWillTerminate")
        }
    }

    // MARK: - App Teardown

    func tearDown() async {
        // Put any global-level teardown logic here
        // e.g. flush analytics, etc.
        print("Application teardown completed")
    }
}
