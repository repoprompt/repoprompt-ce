import Foundation

/// OpenCode-specific integration configuration helpers.
///
/// This namespace owns OpenCode config schema details, RepoPrompt-managed OpenCode modes,
/// per-process ACP overlays, explicit persistent MCP install config, and cleanup of legacy
/// RepoPrompt-managed persistent entries.
enum OpenCodeIntegrationConfiguration {
    private static let configSchemaURL = "https://opencode.ai/config.json"
    private static let mcpTimeoutMilliseconds = 14_400_000
    private static let disabledMCPCommand = "/usr/bin/false"
    private static let repoPromptMCPServerName = RepoPromptMCPServerConfiguration.defaultServerName
    /// Bound reads of inherited OpenCode config used only to discover MCP server names.
    private static let maximumInheritedConfigBytes: UInt64 = 2 * 1024 * 1024

    struct PersistentMCPConfigResult {
        let configURL: URL
        let wasMCPServerAlreadyPresent: Bool
    }

    static func configDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let xdgConfigHome = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdgConfigHome.isEmpty
        {
            return URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
        }
        let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let homeURL = if let home, !home.isEmpty {
            URL(fileURLWithPath: home, isDirectory: true)
        } else {
            fileManager.homeDirectoryForCurrentUser
        }
        return homeURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    static func configURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        configDirectoryURL(environment: environment, fileManager: fileManager)
            .appendingPathComponent("opencode.json")
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
    /// Intended for `OPENCODE_CONFIG_CONTENT`. OpenCode merges this overlay with global/project
    /// config by MCP server name. `session/new` waits for those MCP servers to connect, so a
    /// hanging non-RepoPrompt entry (or a recursive RepoPrompt CE CLI entry) can exceed the ACP
    /// bootstrap timeout. This overlay therefore:
    /// - disables every inherited global/project MCP server name it can discover
    /// - sets the current-build RepoPrompt MCP entry active or disabled
    /// - always provides RepoPrompt-managed agent modes
    static func ephemeralACPConfigDict(
        includeRepoPromptMCPServer: Bool,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        workingDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        inheritedMCPServerNamesOverride: [String]? = nil
    ) -> [String: Any] {
        var mcp: [String: Any] = [:]
        let inheritedNames = inheritedMCPServerNamesOverride ?? discoverInheritedMCPServerNames(
            workingDirectory: workingDirectory,
            environment: environment,
            fileManager: fileManager
        )
        for name in inheritedNames {
            if name.compare(repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame {
                continue
            }
            mcp[name] = disabledMCPConfigDict()
        }
        mcp[repoPromptMCPServerName] = includeRepoPromptMCPServer
            ? mcpConfigDict(for: repoPromptMCPConfiguration)
            : disabledMCPConfigDict()

        return [
            "$schema": configSchemaURL,
            "agent": managedAgentConfigDicts,
            "mcp": mcp
        ]
    }

    /// Serializes the process-ephemeral OpenCode config overlay for `OPENCODE_CONFIG_CONTENT`.
    static func ephemeralACPConfigJSON(
        includeRepoPromptMCPServer: Bool,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        workingDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        inheritedMCPServerNamesOverride: [String]? = nil
    ) throws -> String {
        let dict = ephemeralACPConfigDict(
            includeRepoPromptMCPServer: includeRepoPromptMCPServer,
            repoPromptMCPConfiguration: repoPromptMCPConfiguration,
            workingDirectory: workingDirectory,
            environment: environment,
            fileManager: fileManager,
            inheritedMCPServerNamesOverride: inheritedMCPServerNamesOverride
        )
        let data = try JSONSerialization.data(
            withJSONObject: dict,
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

    /// Discovers MCP server names that OpenCode may inherit from global/project config.
    /// Used only to neutralize those names in the process-ephemeral overlay.
    static func discoverInheritedMCPServerNames(
        workingDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String] {
        var names = Set<String>()
        for path in inheritedConfigPaths(workingDirectory: workingDirectory, environment: environment, fileManager: fileManager) {
            guard let object = readBoundedJSONObject(atPath: path, fileManager: fileManager),
                  let mcp = object["mcp"] as? [String: Any]
            else {
                continue
            }
            for key in mcp.keys where !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                names.insert(key)
            }
        }
        return names.sorted()
    }

    static func inheritedConfigPaths(
        workingDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String] {
        var paths: [String] = []
        paths.append(configURL(environment: environment, fileManager: fileManager).path)
        if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty
        {
            let root = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            paths.append(root.appendingPathComponent("opencode.json").path)
            paths.append(root.appendingPathComponent(".opencode/opencode.json").path)
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func readBoundedJSONObject(
        atPath path: String,
        fileManager: FileManager
    ) -> [String: Any]? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value
            ?? attributes[.size] as? UInt64
        guard let size, size > 0, size <= maximumInheritedConfigBytes else {
            return nil
        }
        guard let data = fileManager.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
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
