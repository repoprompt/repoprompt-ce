import Foundation
import RepoPromptACPProviders
import RepoPromptFoundation

extension AgentCLILaunchDiagnostics {
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
