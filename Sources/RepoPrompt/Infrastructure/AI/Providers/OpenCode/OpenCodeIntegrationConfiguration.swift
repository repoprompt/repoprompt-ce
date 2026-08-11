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
    private static let maximumInheritedConfigBytes = 2 * 1024 * 1024

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

    /// Discovers MCP server names from the same local config authorities OpenCode merges before
    /// RepoPrompt's process-ephemeral `OPENCODE_CONFIG_CONTENT` overlay.
    static func discoverInheritedMCPServerNames(
        workingDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String] {
        var names = Set<String>()
        for path in inheritedConfigPaths(
            workingDirectory: workingDirectory,
            environment: environment,
            fileManager: fileManager
        ) {
            guard let object = readBoundedJSONObject(atPath: path),
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
        let currentDirectoryURL = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let trimmedWorkingDirectory = workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectoryURL = resolvedFileURL(
            path: nonEmpty(trimmedWorkingDirectory) ?? fileManager.currentDirectoryPath,
            relativeTo: currentDirectoryURL,
            isDirectory: true
        )
        let globalConfigDirectory = configDirectoryURL(
            environment: environment,
            fileManager: fileManager
        )

        // Mirrors OpenCode's global loader, which merges all three filenames rather than selecting one.
        var urls = ["config.json", "opencode.json", "opencode.jsonc"].map {
            globalConfigDirectory.appendingPathComponent($0, isDirectory: false)
        }

        if let customConfigPath = nonEmpty(environment["OPENCODE_CONFIG"]) {
            urls.append(resolvedFileURL(
                path: customConfigPath,
                relativeTo: workingDirectoryURL,
                isDirectory: false
            ))
        }

        if !environmentFlagIsTruthy(environment["OPENCODE_DISABLE_PROJECT_CONFIG"]) {
            let projectDirectories = projectConfigDirectories(
                from: workingDirectoryURL,
                fileManager: fileManager
            )
            for directory in projectDirectories {
                urls.append(directory.appendingPathComponent("opencode.jsonc", isDirectory: false))
                urls.append(directory.appendingPathComponent("opencode.json", isDirectory: false))
            }
            for directory in projectDirectories {
                let configDirectory = directory.appendingPathComponent(".opencode", isDirectory: true)
                urls.append(configDirectory.appendingPathComponent("opencode.json", isDirectory: false))
                urls.append(configDirectory.appendingPathComponent("opencode.jsonc", isDirectory: false))
            }
        }

        let openCodeHome = openCodeHomeDirectoryURL(
            environment: environment,
            fileManager: fileManager
        ).appendingPathComponent(".opencode", isDirectory: true)
        urls.append(openCodeHome.appendingPathComponent("opencode.json", isDirectory: false))
        urls.append(openCodeHome.appendingPathComponent("opencode.jsonc", isDirectory: false))

        if let customConfigDirectoryPath = nonEmpty(environment["OPENCODE_CONFIG_DIR"]) {
            let customConfigDirectory = resolvedFileURL(
                path: customConfigDirectoryPath,
                relativeTo: workingDirectoryURL,
                isDirectory: true
            )
            urls.append(customConfigDirectory.appendingPathComponent("opencode.json", isDirectory: false))
            urls.append(customConfigDirectory.appendingPathComponent("opencode.jsonc", isDirectory: false))
        }

        // RepoPrompt sets its own OPENCODE_CONFIG_CONTENT on the child process, so caller inline
        // content is replaced rather than inherited and cannot contribute an additional MCP name.
        var seen = Set<String>()
        return urls
            .map(\.standardizedFileURL.path)
            .filter { seen.insert($0).inserted }
    }

    private static func projectConfigDirectories(
        from workingDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        var directories: [URL] = []
        var current = workingDirectory.standardizedFileURL
        while true {
            directories.append(current)
            // OpenCode walks upward only to its worktree boundary. A .git file also identifies
            // linked worktrees, while .jj covers colocated Jujutsu workspaces supported by RepoPrompt.
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path)
                || fileManager.fileExists(atPath: current.appendingPathComponent(".jj").path)
            {
                break
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return directories.reversed()
    }

    private static func openCodeHomeDirectoryURL(
        environment: [String: String],
        fileManager: FileManager
    ) -> URL {
        if let testHome = nonEmpty(environment["OPENCODE_TEST_HOME"]) {
            return resolvedFileURL(
                path: testHome,
                relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
                isDirectory: true
            )
        }
        if let home = nonEmpty(environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return resolvedFileURL(
                path: home,
                relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
                isDirectory: true
            )
        }
        return fileManager.homeDirectoryForCurrentUser.standardizedFileURL
    }

    private static func resolvedFileURL(
        path: String,
        relativeTo baseDirectory: URL,
        isDirectory: Bool
    ) -> URL {
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path, isDirectory: isDirectory).standardizedFileURL
        }
        return baseDirectory
            .appendingPathComponent(path, isDirectory: isDirectory)
            .standardizedFileURL
    }
    private static func environmentFlagIsTruthy(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value == "true" || value == "1"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func readBoundedJSONObject(atPath path: String) -> [String: Any]? {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            guard let chunk = try handle.read(upToCount: maximumInheritedConfigBytes + 1),
                  !chunk.isEmpty,
                  chunk.count <= maximumInheritedConfigBytes
            else {
                return nil
            }
            data = chunk
        } catch {
            return nil
        }

        guard let normalized = normalizedJSONCData(data),
              let object = try? JSONSerialization.jsonObject(with: normalized) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func normalizedJSONCData(_ data: Data) -> Data? {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        guard let uncommented = removingJSONComments(from: bytes) else { return nil }
        return Data(removingTrailingCommas(from: uncommented))
    }

    private static func removingJSONComments(from bytes: [UInt8]) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var isInsideString = false
        var isEscaped = false
        var isInsideLineComment = false
        var isInsideBlockComment = false

        while index < bytes.count {
            let byte = bytes[index]

            if isInsideLineComment {
                if byte == 0x0A || byte == 0x0D {
                    output.append(byte)
                    isInsideLineComment = false
                }
                index += 1
                continue
            }

            if isInsideBlockComment {
                if byte == 0x2A, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                    isInsideBlockComment = false
                    index += 2
                    continue
                }
                if byte == 0x0A || byte == 0x0D {
                    output.append(byte)
                }
                index += 1
                continue
            }

            if isInsideString {
                output.append(byte)
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
                index += 1
                continue
            }

            if byte == 0x22 {
                isInsideString = true
                output.append(byte)
                index += 1
                continue
            }

            if byte == 0x2F, index + 1 < bytes.count {
                if bytes[index + 1] == 0x2F {
                    isInsideLineComment = true
                    index += 2
                    continue
                }
                if bytes[index + 1] == 0x2A {
                    isInsideBlockComment = true
                    index += 2
                    continue
                }
            }

            output.append(byte)
            index += 1
        }

        return isInsideBlockComment ? nil : output
    }

    private static func removingTrailingCommas(from bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var isInsideString = false
        var isEscaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if isInsideString {
                output.append(byte)
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
                index += 1
                continue
            }

            if byte == 0x22 {
                isInsideString = true
                output.append(byte)
                index += 1
                continue
            }

            if byte == 0x2C {
                var lookahead = index + 1
                while lookahead < bytes.count, isJSONWhitespace(bytes[lookahead]) {
                    lookahead += 1
                }
                if lookahead < bytes.count,
                   bytes[lookahead] == 0x7D || bytes[lookahead] == 0x5D
                {
                    index += 1
                    continue
                }
            }

            output.append(byte)
            index += 1
        }
        return output
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
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