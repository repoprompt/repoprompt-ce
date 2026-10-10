import Foundation
import RepoPromptProcess
import RepoPromptSettingsCore

/// Optional name-based mitigation for provider children, not a credential sandbox.
/// Provider identity is supplied by the launch owner, never inferred from a command.
enum ProviderEnvironmentFiltering {
    typealias RemovedNamesProvider = @Sendable (String) async -> Set<String>

    static func filter(
        _ environment: [String: String],
        for provider: AgentProviderKind,
        explicitOverrides: [String: String] = [:],
        removedNamesProvider: RemovedNamesProvider? = nil
    ) async -> [String: String] {
        let removedNames: Set<String> = if let removedNamesProvider {
            await removedNamesProvider(provider.rawValue)
        } else {
            await MainActor.run {
                GlobalSettingsStore.shared.providerEnvironmentRemovedNames(for: provider.rawValue)
            }
        }
        return applying(removedNames: removedNames, to: environment, explicitOverrides: explicitOverrides)
    }

    static func filterACP(
        _ environment: [String: String],
        launchConfiguration: ACPLaunchConfiguration,
        for provider: AgentProviderKind,
        removedNamesProvider: RemovedNamesProvider? = nil
    ) async -> [String: String] {
        await filter(
            environment,
            for: provider,
            explicitOverrides: launchConfiguration.environment.filter {
                launchConfiguration.explicitEnvironmentKeys.contains($0.key)
            },
            removedNamesProvider: removedNamesProvider
        )
    }

    static func applying(
        removedNames: Set<String>,
        to environment: [String: String],
        explicitOverrides: [String: String] = [:]
    ) -> [String: String] {
        var result = environment.filter { !removedNames.contains($0.key) }
        result.merge(explicitOverrides) { _, explicit in explicit }
        return ProcessEnvironmentSanitizer.sanitizedForChildLaunch(result)
    }

    static func cliFilter(
        for provider: AgentProviderKind,
        explicitOverrides: [String: String] = [:],
        removedNamesProvider: RemovedNamesProvider? = nil
    ) -> CLIProcessConfiguration.EnvironmentFilter {
        { environment, runtimeOverrides in
            await filter(
                environment,
                for: provider,
                explicitOverrides: explicitOverrides.merging(runtimeOverrides) { _, runtime in runtime },
                removedNamesProvider: removedNamesProvider
            )
        }
    }
}
