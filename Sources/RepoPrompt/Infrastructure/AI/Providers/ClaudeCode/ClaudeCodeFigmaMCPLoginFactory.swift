import Foundation

/// Provider-local construction seam for Claude Code's future Figma login path.
///
/// This factory intentionally does not register or enable the capability. Production composition
/// must still supply a reviewed live gate and provider-owned proof/revocation contract before
/// exposing Connect.
struct ClaudeCodeFigmaMCPLoginComponents {
    let descriptor: ClaudeCodeFigmaMCPLoginDescriptor
    let targetResolver: ClaudeCodeFigmaMCPTargetResolver
    let subprocessDescriptor: FigmaMCPProviderSubprocessLoginDescriptor
    let executableVersionProbe: ClaudeCodeExecutableVersionProbe
    let sessionController: FigmaMCPProviderTerminalHandoff.SessionController

    func makeLoginDriver(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        environmentBuilder: @escaping FigmaMCPProviderSubprocessLoginDriver.EnvironmentBuilder = { request in
            await ProcessEnvironmentBuilder.build(request)
        },
        processRunner: FigmaMCPProviderSubprocessLoginDriver.ProcessRunner? = nil
    ) -> FigmaMCPProviderSubprocessLoginDriver {
        let probe = executableVersionProbe
        return FigmaMCPProviderSubprocessLoginDriver(
            descriptor: subprocessDescriptor,
            inheritedEnvironment: inheritedEnvironment,
            environmentBuilder: environmentBuilder,
            executableVersionProbe: { executablePath, environment in
                await probe.probe(executablePath: executablePath, environment: environment)
            },
            processRunner: processRunner ?? ClaudeCodeFigmaTerminalHandoff.makeProcessRunner(
                sessionController: sessionController
            )
        )
    }
}

enum ClaudeCodeFigmaMCPLoginFactory {
    static func makeComponents(
        sessionController: FigmaMCPProviderTerminalHandoff.SessionController,
        timeout: TimeInterval = 5 * 60,
        executableVersionProbe: ClaudeCodeExecutableVersionProbe? = nil
    ) -> ClaudeCodeFigmaMCPLoginComponents {
        let descriptor = ClaudeCodeFigmaMCPLoginDescriptor()
        return ClaudeCodeFigmaMCPLoginComponents(
            descriptor: descriptor,
            targetResolver: ClaudeCodeFigmaMCPTargetResolver(),
            subprocessDescriptor: FigmaMCPProviderSubprocessLoginDescriptor(
                provider: descriptor.provider,
                command: descriptor.executableProfile.commandName,
                additionalPaths: descriptor.executableProfile.supplementalSearchPaths,
                timeout: timeout,
                minimumSupportedVersion: descriptor.minimumSupportedVersion,
                arguments: { targetIdentifier in
                    ClaudeCodeFigmaMCPLoginDescriptor().loginArguments(targetIdentifier: targetIdentifier)
                }
            ),
            executableVersionProbe: executableVersionProbe ?? ClaudeCodeExecutableVersionProbe(),
            sessionController: sessionController
        )
    }
}
