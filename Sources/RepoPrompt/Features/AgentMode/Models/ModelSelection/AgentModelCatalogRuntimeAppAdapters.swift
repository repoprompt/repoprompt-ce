import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptCodexProvider
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

typealias AgentModelCatalogRuntime = ModelCatalogRuntime<
    AgentACPModelRegistry, AgentCodexModelRegistry, AgentModelCatalog.AvailabilityContext
>

private enum AgentModelCatalogComposition {
    static let runtime = AgentModelCatalogRuntime(registerBackendChanges: { handler in
        ClaudeCodeCompatibleBackendStore.setConfigurationChangeHandler(handler)
    })
}

extension ModelCatalogRuntime where ACPRegistry == AgentACPModelRegistry,
    CodexRegistry == AgentCodexModelRegistry, Availability == AgentModelCatalog.AvailabilityContext
{
    static var shared: AgentModelCatalogRuntime {
        AgentModelCatalogComposition.runtime
    }

    convenience init(registerBackendChanges: @escaping (@escaping @Sendable () -> Void) -> Void) {
        self.init(
            dependencies: Dependencies(
                makeACPRegistry: { AgentACPModelRegistry(dependencies: .app(invalidate: $0)) },
                makeCodexRegistry: { AgentCodexModelRegistry(invalidate: $0) },
                isAgentAvailable: { AgentModelCatalog.isAgentAvailable($0, availability: $1) },
                reasoningEffortRaw: { agent, option in
                    if agent == .codexExec {
                        CodexModelSpecifier(raw: option.rawValue).reasoningEffort?.rawValue
                    } else if agent.usesClaudeTooling {
                        ClaudeModelSpecifier(raw: option.rawValue).explicitEffortLevel?.rawValue
                    } else { nil }
                }
            ),
            registerBackendChanges: registerBackendChanges
        )
    }
}
