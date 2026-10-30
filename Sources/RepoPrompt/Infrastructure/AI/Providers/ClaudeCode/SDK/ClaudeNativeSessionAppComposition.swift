import Foundation
import RepoPromptClaudeProvider

extension ClaudeNativeProcessSessionController {
    init(
        host: any ClaudeNativeSessionHosting,
        runID: UUID,
        tabID: UUID,
        windowID: Int,
        workspacePath: String?,
        config: ClaudeCodeAgentConfig,
        authoritativeTurnIdleFallbackSeconds: TimeInterval = 1.0
    ) {
        self.init(
            host: host,
            runID: runID,
            tabID: tabID,
            windowID: windowID,
            workspacePath: workspacePath,
            config: config,
            environmentResolver: ClaudeCodeLaunchEnvironmentResolver(),
            authoritativeTurnIdleFallbackSeconds: authoritativeTurnIdleFallbackSeconds
        )
    }
}
