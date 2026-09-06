import Foundation

struct AppLaunchConfiguration {
    enum ForcedRootRoute: Equatable {
        case main
    }

    static let current = AppLaunchConfiguration(
        processInfo: .processInfo,
        bundleURL: Bundle.main.bundleURL
    )

    let isUITestSession: Bool
    let suppressesWindowRestore: Bool
    let suppressesWindowPersistence: Bool
    let suppressesAgentSessionPersistence: Bool
    /// Deterministic or persistence-suppressed launches must perform **no** production oversight
    /// file I/O — no read, existence check, write, move, or quarantine.
    let suppressesAgentSessionOversightPersistence: Bool
    let suppressesNonessentialLaunchSideEffects: Bool
    let forcedRootRoute: ForcedRootRoute?
    #if DEBUG
        let agentChatStress: AgentChatStressLaunchConfiguration?
        let forcesMCPAutoStart: Bool
    #endif

    #if DEBUG
        static func debugBuildForcesMCPAutoStart(
            bundleURL: URL,
            arguments: Set<String> = [],
            environment: [String: String] = [:]
        ) -> Bool {
            let isPackagedApp = bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            let isUITestSession = arguments.contains("-RP_UITEST")
            let isHostedXCTestSession = environment["XCTestConfigurationFilePath"] != nil
                || environment["XCInjectBundleInto"] != nil
                || arguments.contains(where: { $0.hasPrefix("-XCTest") })
            return isPackagedApp && !isUITestSession && !isHostedXCTestSession
        }
    #endif

    /// The one derived oversight-persistence policy for this launch.
    ///
    /// Call sites must use this rather than recombining suppression flags with the auto-restore
    /// preference: "restore is turned off" means saved intent stays dormant, not that it may be
    /// deleted, and "deterministic launch" means no production file I/O at all.
    func agentSessionOversightPersistenceMode(
        autoRestoreWorkspacesEnabled: Bool
    ) -> AgentSessionOversightPersistenceMode {
        Self.agentSessionOversightPersistenceMode(
            suppressesOversightPersistence: suppressesAgentSessionOversightPersistence,
            autoRestoreWorkspacesEnabled: autoRestoreWorkspacesEnabled
        )
    }

    static func agentSessionOversightPersistenceMode(
        suppressesOversightPersistence: Bool,
        autoRestoreWorkspacesEnabled: Bool
    ) -> AgentSessionOversightPersistenceMode {
        guard !suppressesOversightPersistence else { return .suppressed }
        return autoRestoreWorkspacesEnabled ? .enabled : .dormant
    }

    private init(processInfo: ProcessInfo, bundleURL: URL) {
        let arguments = Set(processInfo.arguments)
        let environment = processInfo.environment
        let isUITestSession = arguments.contains("-RP_UITEST")
        #if DEBUG
            let agentChatStress = arguments.contains("-RP_AGENT_CHAT_STRESS")
                ? AgentChatStressLaunchConfiguration(environment: environment)
                : nil
            let isAgentChatStressEnabled = agentChatStress != nil
        #else
            let isAgentChatStressEnabled = false
        #endif
        let isDeterministicUITestLaunch = isUITestSession || isAgentChatStressEnabled
        #if DEBUG
            let allowsStressAgentSessionPersistence = agentChatStress?.allowsAgentSessionPersistence ?? false
        #else
            let allowsStressAgentSessionPersistence = false
        #endif

        self.isUITestSession = isUITestSession
        suppressesWindowRestore = isDeterministicUITestLaunch
        suppressesWindowPersistence = isDeterministicUITestLaunch
        suppressesAgentSessionPersistence = isDeterministicUITestLaunch && !allowsStressAgentSessionPersistence
        // Deliberately not softened by the stress harness's agent-session persistence opt-in: a
        // deterministic launch must never touch the production oversight file, and a stress run has
        // no user-authored oversight intent to preserve.
        suppressesAgentSessionOversightPersistence = isDeterministicUITestLaunch
        suppressesNonessentialLaunchSideEffects = isDeterministicUITestLaunch
        forcedRootRoute = isDeterministicUITestLaunch ? .main : nil
        #if DEBUG
            self.agentChatStress = agentChatStress
            forcesMCPAutoStart = Self.debugBuildForcesMCPAutoStart(
                bundleURL: bundleURL,
                arguments: arguments,
                environment: environment
            )
        #endif
    }
}
