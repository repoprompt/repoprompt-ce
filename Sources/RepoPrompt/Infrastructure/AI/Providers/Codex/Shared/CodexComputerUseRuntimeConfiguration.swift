import Foundation

struct CodexComputerUseRuntimeConfiguration: Equatable {
    enum Source: Equatable {
        case explicitMCPServer(configPath: String)
        case appManagedBundledPlugin(mcpConfigPath: String, manifestPath: String?, version: String?)
    }

    struct Incomplete: Equatable {
        let path: String
        let message: String
    }

    enum Resolution: Equatable {
        case resolved(CodexComputerUseRuntimeConfiguration)
        case incomplete(Incomplete)
        case missingConfigFile(path: String)
        case serverEntryMissing(path: String)
        case unreadable(path: String, message: String)
    }

    private struct PluginManifest: Decodable {
        var name: String
        var version: String?
    }

    private struct MCPJSONDocument: Decodable {
        var mcpServers: [String: MCPJSONServerDefinition]
    }

    private struct MCPJSONServerDefinition: Decodable {
        var command: String?
        var args: [String]?
        var cwd: String?
        var env: [String: String]?
        var enabled: Bool?
        var toolTimeoutSec: Int?

        enum CodingKeys: String, CodingKey {
            case command
            case args
            case cwd
            case env
            case enabled
            case toolTimeoutSec
            case toolTimeoutSnake = "tool_timeout_sec"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decodeIfPresent(String.self, forKey: .command)
            args = try container.decodeIfPresent([String].self, forKey: .args)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
            env = try container.decodeIfPresent([String: String].self, forKey: .env)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            toolTimeoutSec = try container.decodeIfPresent(Int.self, forKey: .toolTimeoutSnake)
                ?? container.decodeIfPresent(Int.self, forKey: .toolTimeoutSec)
        }
    }

    let serverName: String
    let command: String
    let args: [String]
    let cwd: String?
    let env: [String: String]
    let enabled: Bool?
    let toolTimeoutSec: Int?
    let source: Source

    static let appManagedBundledPluginName = "computer-use@openai-bundled"

    static func resolve(
        configURL: URL = CodexIntegrationConfiguration.configURL(),
        codexDirectoryURL: URL = CodexIntegrationConfiguration.configDirectoryURL(),
        fileManager: FileManager = .default
    ) -> Resolution {
        let configPath = configURL.path
        var hasConfigFile = false
        var declaresAppManagedPlugin = false

        if fileManager.fileExists(atPath: configPath) {
            hasConfigFile = true
            do {
                let content = try String(contentsOf: configURL, encoding: .utf8)
                declaresAppManagedPlugin = configDeclaresAppManagedPlugin(content)
                if let explicit = CodexIntegrationConfiguration.mcpServerConfiguration(
                    named: CodexComputerUseConstants.mcpServerName,
                    fromConfigContent: content
                ) {
                    return runtimeConfiguration(
                        from: explicit,
                        baseDirectory: configURL.deletingLastPathComponent(),
                        source: .explicitMCPServer(configPath: configPath),
                        definitionPath: configPath
                    )
                }
            } catch {
                if let appManaged = resolveAppManagedBundledPlugin(
                    codexDirectoryURL: codexDirectoryURL,
                    fileManager: fileManager
                ) {
                    return appManaged
                }
                return .unreadable(path: configPath, message: error.localizedDescription)
            }
        }

        if let appManaged = resolveAppManagedBundledPlugin(
            codexDirectoryURL: codexDirectoryURL,
            fileManager: fileManager
        ) {
            return appManaged
        }

        if declaresAppManagedPlugin {
            return .incomplete(.init(
                path: configPath,
                message: "Codex config declares \(appManagedBundledPluginName), but RepoPrompt could not find a bundled Computer Use .mcp.json definition."
            ))
        }

        if hasConfigFile {
            return .serverEntryMissing(path: configPath)
        }
        return .missingConfigFile(path: configPath)
    }

    static func configDeclaresAppManagedPlugin(_ content: String) -> Bool {
        content.range(
            of: #"\[plugins\."?computer-use@openai-bundled"?\]"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func resolveAppManagedBundledPlugin(
        codexDirectoryURL: URL,
        fileManager: FileManager
    ) -> Resolution? {
        var firstIncomplete: Resolution?

        func recordIncomplete(_ resolution: Resolution) {
            if firstIncomplete == nil {
                firstIncomplete = resolution
            }
        }

        for candidate in appManagedMCPJSONCandidates(codexDirectoryURL: codexDirectoryURL) {
            guard fileManager.fileExists(atPath: candidate.mcpConfigURL.path) else { continue }
            do {
                let data = try Data(contentsOf: candidate.mcpConfigURL)
                let document = try JSONDecoder().decode(MCPJSONDocument.self, from: data)
                guard let definition = document.mcpServers.first(where: {
                    $0.key.caseInsensitiveCompare(CodexComputerUseConstants.mcpServerName) == .orderedSame
                }) else {
                    recordIncomplete(.incomplete(.init(
                        path: candidate.mcpConfigURL.path,
                        message: "Bundled Computer Use .mcp.json does not define mcpServers.\(CodexComputerUseConstants.mcpServerName)."
                    )))
                    continue
                }

                let manifest = pluginManifest(at: candidate.manifestURL, fileManager: fileManager)
                let resolution = runtimeConfiguration(
                    from: definition.value,
                    serverName: definition.key,
                    baseDirectory: candidate.mcpConfigURL.deletingLastPathComponent(),
                    source: .appManagedBundledPlugin(
                        mcpConfigPath: candidate.mcpConfigURL.path,
                        manifestPath: candidate.manifestURL.flatMap { fileManager.fileExists(atPath: $0.path) ? $0.path : nil },
                        version: manifest?.version
                    ),
                    definitionPath: candidate.mcpConfigURL.path
                )
                if case let .resolved(configuration) = resolution,
                   commandRequiresPathMaterialization(configuration.command),
                   !fileManager.fileExists(atPath: configuration.command)
                {
                    recordIncomplete(.incomplete(.init(
                        path: candidate.mcpConfigURL.path,
                        message: "Bundled Computer Use helper command could not be materialized at \(configuration.command)."
                    )))
                    continue
                }
                if case .incomplete = resolution {
                    recordIncomplete(resolution)
                    continue
                }
                return resolution
            } catch {
                recordIncomplete(.incomplete(.init(
                    path: candidate.mcpConfigURL.path,
                    message: "RepoPrompt could not read bundled Computer Use .mcp.json: \(error.localizedDescription)"
                )))
            }
        }
        return firstIncomplete
    }

    private static func runtimeConfiguration(
        from configuration: CodexIntegrationConfiguration.ServerConfiguration,
        baseDirectory: URL,
        source: Source,
        definitionPath: String
    ) -> Resolution {
        guard let command = nonEmpty(configuration.command) else {
            return .incomplete(.init(
                path: definitionPath,
                message: "Computer Use MCP server configuration is missing a command."
            ))
        }

        let resolvedCWD = resolvedPath(configuration.cwd, relativeTo: baseDirectory, leaveBareCommandNames: false)
        let commandBase = resolvedCWD.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? baseDirectory
        return .resolved(CodexComputerUseRuntimeConfiguration(
            serverName: configuration.normalizedName,
            command: resolvedPath(command, relativeTo: commandBase, leaveBareCommandNames: true) ?? command,
            args: configuration.args ?? [],
            cwd: resolvedCWD,
            env: configuration.env,
            enabled: configuration.enabled,
            toolTimeoutSec: configuration.toolTimeoutSec,
            source: source
        ))
    }

    private static func runtimeConfiguration(
        from definition: MCPJSONServerDefinition,
        serverName: String,
        baseDirectory: URL,
        source: Source,
        definitionPath: String
    ) -> Resolution {
        guard let command = nonEmpty(definition.command) else {
            return .incomplete(.init(
                path: definitionPath,
                message: "Bundled Computer Use .mcp.json server definition is missing a command."
            ))
        }

        let resolvedCWD = resolvedPath(definition.cwd, relativeTo: baseDirectory, leaveBareCommandNames: false)
        let commandBase = resolvedCWD.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? baseDirectory
        return .resolved(CodexComputerUseRuntimeConfiguration(
            serverName: serverName,
            command: resolvedPath(command, relativeTo: commandBase, leaveBareCommandNames: true) ?? command,
            args: definition.args ?? [],
            cwd: resolvedCWD,
            env: definition.env ?? [:],
            enabled: definition.enabled,
            toolTimeoutSec: definition.toolTimeoutSec,
            source: source
        ))
    }

    private static func appManagedMCPJSONCandidates(
        codexDirectoryURL: URL
    ) -> [(mcpConfigURL: URL, manifestURL: URL?)] {
        let tmpPlugin = codexDirectoryURL
            .appendingPathComponent(".tmp/bundled-marketplaces/openai-bundled/plugins/computer-use", isDirectory: true)
        let cachePlugin = codexDirectoryURL
            .appendingPathComponent("plugins/cache/openai-bundled/computer-use", isDirectory: true)
        let legacyPlugin = codexDirectoryURL
            .appendingPathComponent("computer-use", isDirectory: true)

        return [tmpPlugin, cachePlugin, legacyPlugin].map { pluginDirectory in
            (
                mcpConfigURL: pluginDirectory.appendingPathComponent(".mcp.json"),
                manifestURL: pluginDirectory.appendingPathComponent(".codex-plugin/plugin.json")
            )
        }
    }

    private static func pluginManifest(at url: URL?, fileManager: FileManager) -> PluginManifest? {
        guard let url, fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data),
              manifest.name.caseInsensitiveCompare(CodexComputerUseConstants.mcpServerName) == .orderedSame
        else {
            return nil
        }
        return manifest
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func commandRequiresPathMaterialization(_ command: String) -> Bool {
        command.hasPrefix("/") || command.hasPrefix(".") || command.contains("/")
    }

    private static func resolvedPath(
        _ value: String?,
        relativeTo baseDirectory: URL,
        leaveBareCommandNames: Bool
    ) -> String? {
        guard let raw = nonEmpty(value) else { return nil }
        if raw.hasPrefix("~") {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).standardizedFileURL.path
        }
        if leaveBareCommandNames, !raw.contains("/") {
            return raw
        }
        return baseDirectory.appendingPathComponent(raw).standardizedFileURL.path
    }
}
