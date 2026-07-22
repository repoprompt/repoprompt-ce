import Foundation

/// Configuration for Codex Exec agent provider.
struct CodexExecAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    let modelString: String?
    let enableDebugLogging: Bool
    let runtimeResolution: CodexProviderHelpers.CodexExecutableResolution

    init(
        commandName: String? = nil,
        additionalPathHints: [String] = CLIPathHints.codex,
        modelString: String? = nil,
        enableDebugLogging: Bool = false
    ) {
        let requestedCommand = commandName ?? CLILaunchProfiles.codex.commandName
        let resolution = CodexProviderHelpers.resolveCodexExecutable(
            commandName: requestedCommand,
            environment: ProcessInfo.processInfo.environment,
            additionalPathHints: additionalPathHints
        )
        self.commandName = resolution.resolvedCommand
        self.additionalPathHints = additionalPathHints
        self.modelString = modelString
        self.enableDebugLogging = enableDebugLogging
        runtimeResolution = resolution
    }
}
