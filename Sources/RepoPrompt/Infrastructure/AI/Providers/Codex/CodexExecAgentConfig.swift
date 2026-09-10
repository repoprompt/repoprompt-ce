import Foundation

/// Run-scoped restrictions for a Codex headless invocation that must not inherit
/// the interactive Agent Mode permission preferences.
struct CodexExecRunConstraints: Equatable {
    let workingDirectory: String
    let requireExactModel: Bool
    let disableNativeShell: Bool
    let disableWebSearch: Bool
    let disableMultiAgent: Bool

    static func promptExperiment(workingDirectory: String) -> Self {
        Self(
            workingDirectory: workingDirectory,
            requireExactModel: true,
            disableNativeShell: true,
            disableWebSearch: true,
            disableMultiAgent: true
        )
    }
}

/// Configuration for Codex Exec agent provider.
struct CodexExecAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    let modelString: String?
    let enableDebugLogging: Bool
    let fullAccess: Bool
    let runConstraints: CodexExecRunConstraints?

    init(
        commandName: String? = nil,
        additionalPathHints: [String] = CLIPathHints.codex,
        modelString: String? = nil,
        enableDebugLogging: Bool = false,
        fullAccess: Bool = false,
        runConstraints: CodexExecRunConstraints? = nil
    ) {
        self.commandName = commandName ?? CLILaunchProfiles.codex.commandName
        self.additionalPathHints = additionalPathHints
        self.modelString = modelString
        self.enableDebugLogging = enableDebugLogging
        self.fullAccess = fullAccess
        self.runConstraints = runConstraints
    }
}
