import Foundation

final class MCPServerCatalogAuthority: @unchecked Sendable {
    enum Provider {
        case codex
        case claude
    }

    enum Scope {
        case directSelected
        case repoPromptOnly
    }

    typealias CatalogProvider = @Sendable () throws -> MCPServerCatalog
    typealias EnabledNamesProvider = @Sendable (Provider) -> Set<String>

    static let shared = MCPServerCatalogAuthority(
        catalogProvider: { try CodexIntegrationConfiguration.mcpServerCatalog() },
        enabledNamesProvider: { provider in
            let toggles = switch provider {
            case .codex:
                AgentPermissionSecureStore.shared.codexPermissions().mcpServerTogglesByNormalizedName
            case .claude:
                AgentPermissionSecureStore.shared.claudePermissions().mcpServerTogglesByNormalizedName
            }
            return Set((toggles ?? [:]).compactMap { $0.value ? $0.key : nil })
        }
    )

    private let catalogProvider: CatalogProvider
    private let enabledNamesProvider: EnabledNamesProvider

    init(
        catalogProvider: @escaping CatalogProvider,
        enabledNamesProvider: @escaping EnabledNamesProvider
    ) {
        self.catalogProvider = catalogProvider
        self.enabledNamesProvider = enabledNamesProvider
    }

    func catalog(for provider: Provider, scope: Scope) throws -> MCPServerCatalog {
        let complete = try catalogProvider()
        let enabledNames: Set<String> = switch scope {
        case .directSelected:
            enabledNamesProvider(provider)
        case .repoPromptOnly:
            []
        }
        let selected = complete.selectedServers(enabledNames: enabledNames)
        guard selected.contains(where: { MCPServerCatalog.isRepoPrompt($0.name) }) else {
            throw MCPServerCatalog.MigrationError.invalidDefinition(
                RepoPromptMCPServerConfiguration.defaultServerName
            )
        }
        return try MCPServerCatalog(servers: selected)
    }
}
