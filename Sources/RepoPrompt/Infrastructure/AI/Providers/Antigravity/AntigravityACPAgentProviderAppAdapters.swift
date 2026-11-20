import Foundation
import RepoPromptACPProviders

extension AntigravityACPAgentProvider {
    init(executablePath: String = "agy_acp_server.par", harnessPath: String? = nil) {
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
            toolNames: ACPAppToolNameResolution.current
        )
    }
}
