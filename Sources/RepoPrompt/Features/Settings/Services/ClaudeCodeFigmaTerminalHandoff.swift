/// Claude-specific construction wrapper around the shared visible Terminal login runner.
enum ClaudeCodeFigmaTerminalHandoff {
    static func makeProcessRunner(
        sessionController: FigmaMCPProviderTerminalHandoff.SessionController
    ) -> FigmaMCPProviderSubprocessLoginDriver.ProcessRunner {
        FigmaMCPProviderTerminalHandoff.makeProcessRunner(
            provider: .claudeCode,
            resultFilePrefix: "repoprompt-claude-figma-login",
            sessionTitlePrefix: "RepoPrompt CE Claude Figma",
            sessionController: sessionController
        )
    }

    static func shellCommand(
        executablePath: String,
        arguments: [String],
        resultPath: String
    ) -> String {
        FigmaMCPProviderTerminalHandoff.shellCommand(
            executablePath: executablePath,
            arguments: arguments,
            resultPath: resultPath
        )
    }

    static var terminalScript: String {
        FigmaMCPProviderTerminalHandoff.terminalScript
    }
}
