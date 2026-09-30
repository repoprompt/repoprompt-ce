/// Cursor-specific construction wrapper around the shared visible Terminal login runner.
enum CursorFigmaTerminalHandoff {
    static func makeProcessRunner(
        sessionController: FigmaMCPProviderTerminalHandoff.SessionController
    ) -> FigmaMCPProviderSubprocessLoginDriver.ProcessRunner {
        FigmaMCPProviderTerminalHandoff.makeProcessRunner(
            provider: .cursor,
            resultFilePrefix: "repoprompt-cursor-figma-login",
            sessionTitlePrefix: "RepoPrompt CE Cursor Figma",
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
