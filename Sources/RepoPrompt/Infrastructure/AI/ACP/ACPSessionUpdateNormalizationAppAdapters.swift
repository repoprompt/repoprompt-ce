import RepoPromptAIContracts
import RepoPromptDomainRuntime

enum ACPAppToolNameResolution {
    static var current: ACPToolNameResolution {
        ACPToolNameResolution(
            isRepoPromptServerIdentifier: { MCPIntegrationHelper.isRepoPromptServerIdentifier($0) },
            canonicalRepoPromptToolName: { MCPIntegrationHelper.canonicalRepoPromptToolName($0) },
            isRepoPromptToolNameWithServerPrefix: { MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix($0) }
        )
    }
}

extension ACPRuntimeEventParsing {
    static func normalizedToolName(from payload: [String: Any]) -> String {
        normalizedToolName(from: payload, toolNames: ACPAppToolNameResolution.current)
    }

    static func repoPromptToolName(from payload: [String: Any]) -> String? {
        repoPromptToolName(from: payload, toolNames: ACPAppToolNameResolution.current)
    }

    static func explicitRepoPromptToolName(from rawName: String) -> String? {
        explicitRepoPromptToolName(from: rawName, toolNames: ACPAppToolNameResolution.current)
    }
}

extension ACPDefaultSessionUpdateNormalizer {
    static func normalize(_ payload: [String: Any], providerID: ACPProviderID) -> [NormalizedAgentRuntimeEvent] {
        normalize(payload, providerID: providerID, toolNames: ACPAppToolNameResolution.current)
    }
}
