import Foundation

package enum ShellEnvironmentSource: Equatable {
    case inheritedRichEnvironment
    case capturedLoginShell
    case previousCapturedFallback
    case enrichedFallback
}

package enum ShellEnvironmentCaptureMode: Hashable, CaseIterable {
    case interactiveLoginShell
    case loginShell
}

package struct CLIEnvironmentSnapshot: Equatable {
    package let environment: [String: String]
    package let source: ShellEnvironmentSource
}

package enum ProcessLaunchPurpose: Equatable {
    case cliRunner
    case codexAppServer
    case codexPreflight
    case claudeNative
    case acpAgent(providerID: String?)
    case sidebarAgentTerminal(provider: String?)
    case sidebarInteractiveShell
    case shellEnvironmentProbe
}

package struct ProcessEnvironmentRequest: Equatable {
    package let purpose: ProcessLaunchPurpose
    package let inheritedEnvironment: [String: String]
    package let overrides: [String: String]
    package let additionalRemovedKeys: Set<String>
    package let forceRefreshShellEnvironment: Bool
    package let enableDebugLogging: Bool

    package init(
        purpose: ProcessLaunchPurpose,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:],
        additionalRemovedKeys: Set<String> = [],
        forceRefreshShellEnvironment: Bool = false,
        enableDebugLogging: Bool = false
    ) {
        self.purpose = purpose
        self.inheritedEnvironment = inheritedEnvironment
        self.overrides = overrides
        self.additionalRemovedKeys = additionalRemovedKeys
        self.forceRefreshShellEnvironment = forceRefreshShellEnvironment
        self.enableDebugLogging = enableDebugLogging
    }
}

package struct ProcessEnvironmentResult: Equatable {
    package let environment: [String: String]
    package let launchContext: ProcessLaunchContext
    package let shellEnvironmentSource: ShellEnvironmentSource
}

package enum ProcessEnvironmentBuilder {
    package typealias ShellEnvironmentProvider = @Sendable (_ enableLogging: Bool, _ forceRefresh: Bool) async -> CLIEnvironmentSnapshot

    package static func build(_ request: ProcessEnvironmentRequest) async -> ProcessEnvironmentResult {
        let captureMode = preferredShellCaptureMode(for: request.purpose)
        return await build(request) { enableLogging, forceRefresh in
            await CLIEnvironmentCache.shared.environmentSnapshot(
                enableLogging: enableLogging,
                forceRefresh: forceRefresh,
                captureMode: captureMode
            )
        }
    }

    package static func build(
        _ request: ProcessEnvironmentRequest,
        shellEnvironmentProvider: ShellEnvironmentProvider
    ) async -> ProcessEnvironmentResult {
        let launchContext = ProcessLaunchContext.detect(from: request.inheritedEnvironment)
        let baseSnapshot: CLIEnvironmentSnapshot = if shouldUseInheritedEnvironment(
            purpose: request.purpose,
            launchContext: launchContext,
            forceRefreshShellEnvironment: request.forceRefreshShellEnvironment
        ) {
            CLIEnvironmentSnapshot(
                environment: request.inheritedEnvironment,
                source: .inheritedRichEnvironment
            )
        } else {
            await shellEnvironmentProvider(
                request.enableDebugLogging,
                request.forceRefreshShellEnvironment
            )
        }

        let merged = composedEnvironment(
            base: baseSnapshot.environment,
            inherited: request.inheritedEnvironment,
            overrides: request.overrides,
            additionalRemovedKeys: request.additionalRemovedKeys
        )

        return ProcessEnvironmentResult(
            environment: merged,
            launchContext: launchContext,
            shellEnvironmentSource: baseSnapshot.source
        )
    }

    private static func preferredShellCaptureMode(for purpose: ProcessLaunchPurpose) -> ShellEnvironmentCaptureMode {
        switch purpose {
        case .codexAppServer, .codexPreflight:
            .loginShell
        default:
            .interactiveLoginShell
        }
    }

    private static func shouldUseInheritedEnvironment(
        purpose: ProcessLaunchPurpose,
        launchContext: ProcessLaunchContext,
        forceRefreshShellEnvironment: Bool
    ) -> Bool {
        guard !forceRefreshShellEnvironment else { return false }
        guard launchContext.source == .terminalInherited else { return false }
        switch purpose {
        case .codexAppServer, .codexPreflight, .shellEnvironmentProbe:
            return false
        default:
            return true
        }
    }

    package static func composedEnvironment(
        base: [String: String],
        inherited: [String: String],
        overrides: [String: String] = [:],
        additionalRemovedKeys: Set<String> = []
    ) -> [String: String] {
        var environment = base
        for (key, value) in inherited {
            if key == "PATH" {
                environment[key] = mergePathValues(primary: environment[key], secondary: value)
            } else if environment[key] == nil {
                environment[key] = value
            }
        }
        for (key, value) in overrides {
            environment[key] = value
        }
        if environment["HOME"].map({ !$0.isEmpty }) != true {
            environment["HOME"] = NSHomeDirectory()
        }
        if environment["TERM"].map({ !$0.isEmpty }) != true {
            environment["TERM"] = "xterm-256color"
        }
        return ProcessEnvironmentSanitizer.sanitizedForChildLaunch(
            environment,
            additionalRemovedKeys: additionalRemovedKeys
        )
    }

    package static func mergePathValues(primary: String?, secondary: String?) -> String {
        let primaryComponents = (primary ?? "").split(separator: ":").map(String.init)
        let secondaryComponents = (secondary ?? "").split(separator: ":").map(String.init)
        var ordered: [String] = []
        var seen = Set<String>()
        for path in primaryComponents where !path.isEmpty {
            if seen.insert(path).inserted {
                ordered.append(path)
            }
        }
        for path in secondaryComponents where !path.isEmpty {
            if seen.insert(path).inserted {
                ordered.append(path)
            }
        }
        return ordered.joined(separator: ":")
    }
}
