import Foundation

/// OpenCode-specific integration configuration helpers.
///
/// This namespace owns OpenCode config schema details, RepoPrompt-managed OpenCode modes,
/// per-process ACP overlays, explicit persistent MCP install config, and cleanup of legacy
/// RepoPrompt-managed persistent entries.
enum OpenCodeIntegrationConfiguration {
    enum OpenCodeEphemeralExternalMCP: Equatable {
        case figma(serverName: String)

        var serverName: String {
            switch self {
            case let .figma(serverName):
                serverName
            }
        }
    }

    enum ExternalMCPConfigurationError: Error, Equatable, LocalizedError {
        case invalidJSON
        case invalidSchema
        case invalidAgentContainer
        case invalidMCPContainer
        case invalidMCPEntry(String)
        case caseInsensitiveCollision([String])
        case conflictingExistingEntry(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON: "OpenCode external MCP config is not valid JSON."
            case .invalidSchema: "OpenCode external MCP config has an incompatible schema."
            case .invalidAgentContainer: "OpenCode external MCP config has an invalid agent container."
            case .invalidMCPContainer: "OpenCode external MCP config has an invalid MCP container."
            case let .invalidMCPEntry(name): "OpenCode external MCP entry '\(name)' is invalid."
            case let .caseInsensitiveCollision(names): "OpenCode external MCP server names collide: \(names.joined(separator: ", "))."
            case let .conflictingExistingEntry(name): "OpenCode external MCP entry '\(name)' conflicts with the managed Figma entry."
            }
        }
    }

    static let configContentEnvironmentKey = "OPENCODE_CONFIG_CONTENT"
    static let figmaRemoteMCPURL = "https://mcp.figma.com/mcp"
    private static let configSchemaURL = "https://opencode.ai/config.json"
    private static let mcpTimeoutMilliseconds = 14_400_000
    private static let disabledMCPCommand = "/usr/bin/false"
    private static let repoPromptMCPServerName = RepoPromptMCPServerConfiguration.defaultServerName

    struct PersistentMCPConfigResult {
        let configURL: URL
        let wasMCPServerAlreadyPresent: Bool
    }

    static func configDirectoryURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    static func configURL() -> URL {
        configDirectoryURL().appendingPathComponent("opencode.json")
    }

    /// MCP config dictionary for OpenCode format.
    /// OpenCode uses "type": "local" with command as an argv array and environment as key-value pairs.
    static func mcpConfigDict(
        for configuration: RepoPromptMCPServerConfiguration = .repoPrompt
    ) -> [String: Any] {
        [
            "type": "local",
            "command": [configuration.command] + configuration.args,
            "environment": configuration.environmentDictionary,
            "timeout": mcpTimeoutMilliseconds
        ]
    }

    /// Disabled same-name OpenCode MCP override used by RepoPrompt-launched no-tools/model-discovery
    /// processes to neutralize any inherited global/project RepoPrompt MCP entry.
    static func disabledMCPConfigDict() -> [String: Any] {
        [
            "type": "local",
            "command": [disabledMCPCommand],
            "environment": [String: String](),
            "enabled": false,
            "timeout": mcpTimeoutMilliseconds
        ]
    }

    /// RepoPrompt-managed OpenCode agent mode used by interactive Agent Mode. It leaves shell
    /// access available while denying built-in tools that overlap with RepoPrompt MCP tools.
    static var managedACPAgentConfigDict: [String: Any] {
        [
            "name": OpenCodeAgentConfig.managedSessionModeID,
            "description": "RepoPrompt-managed Agent Mode. Uses RepoPrompt MCP tools for workspace access while leaving bash available for OpenCode.",
            "mode": "primary",
            "permission": managedAgentModePermissions
        ]
    }

    /// RepoPrompt-managed OpenCode mode that keeps the managed tool surface but suppresses approval prompts.
    static var managedFullAccessACPAgentConfigDict: [String: Any] {
        [
            "name": OpenCodeAgentConfig.managedFullAccessSessionModeID,
            "description": "RepoPrompt-managed Agent Mode with approval prompts disabled for available OpenCode tools.",
            "mode": "primary",
            "permission": managedFullAccessPermissions
        ]
    }

    /// RepoPrompt-managed OpenCode mode used by headless discovery paths. It
    /// denies native tools, including bash, while preserving injected RepoPrompt MCP tools.
    static var managedHeadlessAgentConfigDict: [String: Any] {
        [
            "name": OpenCodeAgentConfig.managedHeadlessSessionModeID,
            "description": "RepoPrompt-managed no-native-tools mode for headless discovery runs.",
            "mode": "primary",
            "permission": managedHeadlessPermissions
        ]
    }

    /// RepoPrompt-managed OpenCode mode used by chat/Oracle paths. It denies every native and
    /// MCP tool, including bash, so those runs can only produce model text.
    static var managedNoToolsAgentConfigDict: [String: Any] {
        [
            "name": OpenCodeAgentConfig.managedNoToolsSessionModeID,
            "description": "RepoPrompt-managed no-tools mode for chat and Oracle runs.",
            "mode": "primary",
            "permission": managedNoToolsPermissions,
            "tools": ["*": false]
        ]
    }

    static var managedAgentConfigDicts: [String: [String: Any]] {
        [
            OpenCodeAgentConfig.managedSessionModeID: managedACPAgentConfigDict,
            OpenCodeAgentConfig.managedFullAccessSessionModeID: managedFullAccessACPAgentConfigDict,
            OpenCodeAgentConfig.managedHeadlessSessionModeID: managedHeadlessAgentConfigDict,
            OpenCodeAgentConfig.managedNoToolsSessionModeID: managedNoToolsAgentConfigDict
        ]
    }

    static var managedAgentModeIDs: Set<String> {
        Set(managedAgentConfigDicts.keys)
    }

    /// Process-ephemeral OpenCode config overlay for RepoPrompt-launched ACP runs.
    ///
    /// Intended for `OPENCODE_CONFIG_CONTENT`; it always provides RepoPrompt-managed modes and
    /// either an active current-build RepoPrompt MCP entry or a disabled same-name override.
    static func ephemeralACPConfigDict(
        includeRepoPromptMCPServer: Bool,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt
    ) -> [String: Any] {
        [
            "$schema": configSchemaURL,
            "agent": managedAgentConfigDicts,
            "mcp": [
                repoPromptMCPServerName: includeRepoPromptMCPServer
                    ? mcpConfigDict(for: repoPromptMCPConfiguration)
                    : disabledMCPConfigDict()
            ]
        ]
    }

    /// Serializes the process-ephemeral OpenCode config overlay for `OPENCODE_CONFIG_CONTENT`.
    static func ephemeralACPConfigJSON(
        includeRepoPromptMCPServer: Bool,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        externalMCP: OpenCodeEphemeralExternalMCP? = nil
    ) throws -> String {
        let base = try serialize(ephemeralACPConfigDict(
            includeRepoPromptMCPServer: includeRepoPromptMCPServer,
            repoPromptMCPConfiguration: repoPromptMCPConfiguration
        ))
        return if let externalMCP {
            try mergingExternalMCP(externalMCP, intoConfigContent: base)
        } else {
            base
        }
    }

    static func mergingExternalMCP(
        _ externalMCP: OpenCodeEphemeralExternalMCP,
        intoConfigContent content: String
    ) throws -> String {
        guard let data = content.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ExternalMCPConfigurationError.invalidJSON }
        guard root["$schema"] as? String == configSchemaURL else { throw ExternalMCPConfigurationError.invalidSchema }
        guard root["agent"] is [String: Any] else { throw ExternalMCPConfigurationError.invalidAgentContainer }
        guard var servers = root["mcp"] as? [String: Any] else { throw ExternalMCPConfigurationError.invalidMCPContainer }

        let keys = servers.keys.sorted()
        for key in keys where !(servers[key] is [String: Any]) {
            throw ExternalMCPConfigurationError.invalidMCPEntry(key)
        }
        let folded = Dictionary(grouping: keys, by: { $0.lowercased() })
        if let collision = folded.values.first(where: { $0.count > 1 }) {
            throw ExternalMCPConfigurationError.caseInsensitiveCollision(collision.sorted())
        }

        let serverName: String = switch externalMCP {
        case let .figma(name): name
        }
        let canonical: [String: Any] = [
            "type": "remote",
            "url": figmaRemoteMCPURL,
            "enabled": true
        ]
        if let existingKey = keys.first(where: { $0 == serverName }) {
            guard NSDictionary(dictionary: servers[existingKey] as! [String: Any]).isEqual(to: canonical) else {
                throw ExternalMCPConfigurationError.conflictingExistingEntry(existingKey)
            }
        } else if keys.first(where: { $0.lowercased() == serverName.lowercased() }) != nil {
            throw ExternalMCPConfigurationError.caseInsensitiveCollision([serverName, keys.first { $0.lowercased() == serverName.lowercased() }!].sorted())
        } else {
            servers[serverName] = canonical
        }

        var result = root
        result["mcp"] = servers
        return try serialize(result)
    }

    private static func serialize(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "OpenCodeIntegrationConfiguration",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode OpenCode config overlay as UTF-8"]
            )
        }
        return string
    }

    /// Ensures the persistent OpenCode config contains the RepoPrompt MCP server.
    ///
    /// This helper is for explicit installation/setup only. RepoPrompt-managed OpenCode ACP
    /// modes are provided by per-process overlays and are never written here.
    @discardableResult
    static func ensurePersistentMCPConfig() throws -> PersistentMCPConfigResult {
        let fm = FileManager.default
        let dirURL = configDirectoryURL()
        let configURL = configURL()
        try fm.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)

        let existingData = try? Data(contentsOf: configURL)
        var root: [String: Any] = [:]
        if let existingData,
           let json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any]
        {
            root = json
        }

        root["$schema"] = root["$schema"] ?? configSchemaURL

        var servers = root["mcp"] as? [String: Any] ?? [:]
        let existingEntry = servers[repoPromptMCPServerName] as? [String: Any]
        let wasMCPServerAlreadyPresent = existingEntry != nil
        servers[repoPromptMCPServerName] = mcpConfigDict()
        root["mcp"] = servers

        let newData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if existingData != newData {
            try newData.write(to: configURL, options: .atomic)
        }

        return PersistentMCPConfigResult(
            configURL: configURL,
            wasMCPServerAlreadyPresent: wasMCPServerAlreadyPresent
        )
    }

    /// Checks if the OpenCode config contains a RepoPrompt MCP server entry.
    static func configContainsRepoPrompt() -> Bool {
        let configURL = configURL()
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcp"] as? [String: Any]
        else {
            return false
        }

        return servers.keys.contains {
            $0.compare(repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
        }
    }

    /// Best-effort cleanup for RepoPrompt-managed OpenCode config entries that older builds
    /// wrote into the user's persistent `~/.config/opencode/opencode.json`.
    @discardableResult
    static func cleanupLegacyACPConfigIfNeeded(preserveExplicitMCPInstall: Bool) -> Bool {
        let fm = FileManager.default
        let configURL = configURL()
        guard fm.fileExists(atPath: configURL.path) else { return false }

        do {
            let data = try Data(contentsOf: configURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }

            let cleaned = cleanLegacyACPConfigRoot(
                root,
                preserveExplicitMCPInstall: preserveExplicitMCPInstall
            )
            guard cleaned.changed else { return false }

            let newData = try JSONSerialization.data(
                withJSONObject: cleaned.root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try newData.write(to: configURL, options: .atomic)
            return true
        } catch {
            print("OpenCodeIntegrationConfiguration – legacy cleanup failed: \(error)")
            return false
        }
    }

    static func cleanLegacyACPConfigRoot(
        _ root: [String: Any],
        preserveExplicitMCPInstall: Bool
    ) -> (root: [String: Any], changed: Bool) {
        var root = root
        var changed = false

        if var agents = root["agent"] as? [String: Any] {
            var agentChanged = false
            for modeID in managedAgentModeIDs {
                guard let entry = agents[modeID] as? [String: Any],
                      isRepoPromptManagedAgentEntry(entry)
                else { continue }

                agents.removeValue(forKey: modeID)
                agentChanged = true
            }

            if agentChanged {
                if agents.isEmpty {
                    root.removeValue(forKey: "agent")
                } else {
                    root["agent"] = agents
                }
                changed = true
            }
        }

        if !preserveExplicitMCPInstall,
           var servers = root["mcp"] as? [String: Any]
        {
            var mcpChanged = false
            for key in Array(servers.keys) where key.compare(repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame {
                guard let entry = servers[key] as? [String: Any],
                      isLegacyRepoPromptMCPEntry(entry)
                else { continue }

                servers.removeValue(forKey: key)
                mcpChanged = true
            }

            if mcpChanged {
                if servers.isEmpty {
                    root.removeValue(forKey: "mcp")
                } else {
                    root["mcp"] = servers
                }
                changed = true
            }
        }

        return (root, changed)
    }

    private static var managedAgentModePermissions: [String: String] {
        [
            "bash": "allow",
            "read": "deny",
            "list": "deny",
            "glob": "deny",
            "grep": "deny",
            "edit": "deny",
            "write": "deny",
            "patch": "deny",
            "webfetch": "allow",
            "websearch": "allow",
            "codesearch": "allow",
            "todowrite": "deny",
            "task": "deny",
            "skill": "deny",
            "question": "deny",
            "plan_enter": "deny",
            "plan_exit": "deny"
        ]
    }

    private static var managedFullAccessPermissions: [String: String] {
        var permissions = managedAgentModePermissions.filter { $0.value == "deny" }
        permissions["*"] = "allow"
        return permissions
    }

    private static var managedHeadlessPermissions: [String: String] {
        managedAgentModePermissions.mapValues { _ in "deny" }
    }

    private static var managedNoToolsPermissions: [String: String] {
        var permissions = managedHeadlessPermissions
        permissions["*"] = "deny"
        return permissions
    }

    private static func isRepoPromptManagedAgentEntry(_ entry: [String: Any]) -> Bool {
        guard let options = entry["options"] as? [String: Any] else { return false }
        return options["repoPromptManaged"] as? Bool == true
    }

    private static func isLegacyRepoPromptMCPEntry(_ entry: [String: Any]) -> Bool {
        guard let type = entry["type"] as? String,
              type == "local",
              let command = entry["command"] as? [String],
              let firstCommand = command.first,
              !firstCommand.isEmpty
        else {
            return false
        }

        let generatedNames: Set = ["repoprompt_cli", "repoprompt_cli_debug", "repoprompt-mcp"]
        let lastPathComponent = (firstCommand as NSString).lastPathComponent
        if generatedNames.contains(lastPathComponent) {
            return true
        }

        let loweredCommand = firstCommand.lowercased()
        return loweredCommand.contains("/repoprompt/")
            && generatedNames.contains(where: { loweredCommand.hasSuffix($0) })
    }
}
