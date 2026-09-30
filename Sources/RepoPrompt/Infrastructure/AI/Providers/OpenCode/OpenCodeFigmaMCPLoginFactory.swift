import Foundation

/// Provider-local construction seam for OpenCode's Figma login path.
///
/// This factory intentionally does not register or enable the capability. Production composition
/// must still supply a reviewed executable/version gate and live evidence before exposing Login
/// with Figma.
struct OpenCodeFigmaMCPLoginComponents {
    let descriptor: OpenCodeFigmaMCPLoginDescriptor
    let targetResolver: OpenCodeFigmaMCPTargetResolver
    let subprocessDescriptor: FigmaMCPProviderSubprocessLoginDescriptor
}

enum OpenCodeFigmaMCPLoginFactory {
    static func makeComponents(
        configURL: URL? = nil,
        timeout: TimeInterval = 5 * 60
    ) -> OpenCodeFigmaMCPLoginComponents {
        let descriptor = OpenCodeFigmaMCPLoginDescriptor()
        return OpenCodeFigmaMCPLoginComponents(
            descriptor: descriptor,
            targetResolver: OpenCodeFigmaMCPTargetResolver(
                configURL: configURL
            ),
            subprocessDescriptor: FigmaMCPProviderSubprocessLoginDescriptor(
                provider: descriptor.provider,
                command: descriptor.executableProfile.commandName,
                additionalPaths: descriptor.executableProfile.supplementalSearchPaths,
                timeout: timeout,
                minimumSupportedVersion: descriptor.minimumSupportedVersion,
                arguments: { targetIdentifier in
                    OpenCodeFigmaMCPLoginDescriptor().loginArguments(targetIdentifier: targetIdentifier)
                }
            )
        )
    }
}
