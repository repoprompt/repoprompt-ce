import Foundation
import RepoPromptProcessSupport

struct ACPLaunchEnvironment: Equatable {
    let environment: [String: String]
    let shellEnvironmentSource: ShellEnvironmentSource?

    init(environment: [String: String], shellEnvironmentSource: ShellEnvironmentSource? = nil) {
        self.environment = environment
        self.shellEnvironmentSource = shellEnvironmentSource
    }
}

enum AgentCLILaunchDiagnostics {
    static func fallbackEnvironmentHint(for source: ShellEnvironmentSource?) -> String? {
        switch source {
        case .enrichedFallback:
            "Environment was built from RepoPrompt's fallback PATH because login-shell capture failed or timed out; PATH may not match Terminal."
        case .previousCapturedFallback:
            "Environment reused the last captured shell PATH because login-shell capture failed or timed out; PATH may be stale."
        case .capturedLoginShell, .inheritedRichEnvironment, .none:
            nil
        }
    }

    static func appendFallbackEnvironmentHint(to message: String, source: ShellEnvironmentSource?) -> String {
        guard let hint = fallbackEnvironmentHint(for: source) else { return message }
        return "\(message) \(hint)"
    }

    static func recordPathResolutionFailure(
        providerKind: SentryTelemetryBootstrap.ProviderKind,
        shellEnvironmentSource: ShellEnvironmentSource?,
        candidateCount: Int
    ) {
        SentryTelemetryBootstrap.addBreadcrumb(
            .cliPath,
            action: .cliPathResolutionFailed,
            attributes: [
                .providerKind(providerKind),
                .shellEnvironmentSource(shellEnvironmentSource),
                .resultCount(candidateCount),
                .outcome(.failed)
            ]
        )
        SentryTelemetryBootstrap.increment(
            .cliPathResolutionFailures,
            attributes: [
                .providerKind(providerKind),
                .shellEnvironmentSource(shellEnvironmentSource),
                .resultCount(candidateCount)
            ]
        )
    }
}
