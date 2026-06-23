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
