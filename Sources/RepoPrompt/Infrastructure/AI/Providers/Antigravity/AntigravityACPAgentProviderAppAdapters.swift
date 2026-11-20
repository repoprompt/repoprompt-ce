import Foundation
import RepoPromptACPProviders
import RepoPromptProcess

extension AntigravityACPAgentProvider {
    init(
        executablePath: String = "agy_acp_server.par",
        harnessPath: String? = nil,
        includeRepoPromptMCPServer: Bool = true,
        isolatedProfile: URL? = nil,
        customAgentName: String? = nil
    ) {
        self.init(
            executablePath: executablePath,
            harnessPath: harnessPath,
            installedRuntime: { AntigravityRuntimeManager.installedRuntimeSync() },
            prepareSessionHome: {
                let sessionHome = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("RepoPrompt CE/Antigravity/Profiles/default", isDirectory: true)
                try FileManager.default.createDirectory(at: sessionHome, withIntermediateDirectories: true)
                return sessionHome
            },
            toolNames: ACPAppToolNameResolution.current,
            installedCLI: { AntigravityCLILocator.installedCommand() },
            includeRepoPromptMCPServer: includeRepoPromptMCPServer,
            isolatedProfile: isolatedProfile,
            customAgentName: customAgentName
        )
    }
}

enum AntigravityCLILocator {
    static func installedCommand(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let command = CommandPathResolver.resolve(
            "agy",
            environment: environment,
            additionalPaths: ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"],
            preferredBasenames: ["agy"],
            shellLookupMode: .disabled
        )
        guard CommandPathResolver.launchability(of: command) == .launchable else { return nil }
        return command
    }

    static func isRuntimeInstalled() -> Bool {
        AntigravityRuntimeManager.installedRuntimeSync() != nil || installedCommand() != nil
    }
}
