import Foundation

/// Prepares an isolated `XDG_CONFIG_HOME` root holding `devin/mcp_config.json` with the
/// RepoPrompt MCP server merged in.
///
/// This overlay is the only delivery path Devin's model can reach: verified against devin
/// 3000.6.14, servers passed through ACP `session/new.mcpServers` are spawned and
/// handshaked but never registered into the state its `mcp_list_servers` /
/// `mcp_list_tools` / `mcp_call_tool` gateway tools read.
///
/// The overlay is per-launch and removed on teardown. The user's real `devin` directory is
/// symlinked entry-by-entry so unrelated configuration keeps working, and any stale
/// user-level RepoPrompt entry is overwritten because it collides on the same server key.
enum DevinIntegrationConfiguration {
    static let cleanupArtifactKind = "devinIsolatedMCPConfiguration"
    private static let directoryPrefix = "RepoPromptDevinACP-"

    struct PreparedConfiguration {
        let environment: [String: String]
        let cleanupArtifact: ACPLaunchCleanupArtifact
    }

    static func prepare(
        workingDirectory: String,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration,
        sourceEnvironment: [String: String]
    ) throws -> PreparedConfiguration {
        try repoPromptMCPConfiguration.validateACPLaunchCommand(workingDirectory: workingDirectory)

        let id = UUID()
        let root = configurationRoot(id: id)
        let devinDirectory = root.appendingPathComponent("devin", isDirectory: true)
        let configURL = devinDirectory.appendingPathComponent("mcp_config.json")
        do {
            try FileManager.default.createDirectory(
                at: devinDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let sourceDevinDirectory = sourceConfigurationRoot(environment: sourceEnvironment)
                .appendingPathComponent("devin", isDirectory: true)
            try linkExistingConfiguration(from: sourceDevinDirectory, to: devinDirectory)

            var rootObject = try existingMCPRootObject(
                at: sourceDevinDirectory.appendingPathComponent("mcp_config.json")
            )
            var servers = rootObject["mcpServers"] as? [String: Any] ?? [:]
            var server: [String: Any] = [
                "transport": "stdio",
                "command": repoPromptMCPConfiguration.command,
                "args": repoPromptMCPConfiguration.args
            ]
            if !repoPromptMCPConfiguration.env.isEmpty {
                server["env"] = repoPromptMCPConfiguration.environmentDictionary
            }
            servers[repoPromptMCPConfiguration.name] = server
            // The overlay is for Devin, not for its MCP children. Point every known stdio
            // child back at the native configuration root without overriding an explicit
            // per-server `env` value.
            for (name, value) in servers {
                guard var child = value as? [String: Any],
                      child["transport"] as? String == "stdio",
                      child["env"] == nil || child["env"] is [String: String]
                else { continue }
                var environment = child["env"] as? [String: String] ?? [:]
                if environment["XDG_CONFIG_HOME"] == nil {
                    // A child `HOME` override owns the fallback when native XDG is unset.
                    let nativeEnvironment = sourceEnvironment.merging(environment) { _, child in child }
                    environment["XDG_CONFIG_HOME"] = sourceConfigurationRoot(environment: nativeEnvironment).path
                }
                child["env"] = environment
                servers[name] = child
            }
            rootObject["mcpServers"] = servers

            try JSONSerialization.data(
                withJSONObject: rootObject,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw AIProviderError.invalidConfiguration(
                detail: "Unable to prepare Devin MCP configuration: \(error.localizedDescription)"
            )
        }

        return PreparedConfiguration(
            environment: ["XDG_CONFIG_HOME": root.path],
            cleanupArtifact: ACPLaunchCleanupArtifact(
                providerID: .devin,
                id: id,
                kind: cleanupArtifactKind
            )
        )
    }

    static func cleanup(artifact: ACPLaunchCleanupArtifact) {
        guard artifact.providerID == .devin,
              artifact.kind == cleanupArtifactKind
        else {
            return
        }
        try? FileManager.default.removeItem(at: configurationRoot(id: artifact.id))
    }

    private static func configurationRoot(id: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(directoryPrefix)\(id.uuidString)", isDirectory: true)
            .standardizedFileURL
    }

    private static func sourceConfigurationRoot(environment: [String: String]) -> URL {
        if let configured = environment["XDG_CONFIG_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            let expanded = CommandPathResolver.expandPath(configured, environment: environment)
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .standardizedFileURL
    }

    private static func linkExistingConfiguration(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        for entry in try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        ) where entry.lastPathComponent != "mcp_config.json" {
            try FileManager.default.createSymbolicLink(
                at: destination.appendingPathComponent(entry.lastPathComponent),
                withDestinationURL: entry
            )
        }
    }

    private static func existingMCPRootObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let root = object as? [String: Any] else {
            throw AIProviderError.invalidConfiguration(
                detail: "Unable to merge Devin MCP configuration at \(url.path): expected a JSON object."
            )
        }
        if let servers = root["mcpServers"], !(servers is [String: Any]) {
            throw AIProviderError.invalidConfiguration(
                detail: "Unable to merge Devin MCP configuration at \(url.path): expected mcpServers to be a JSON object."
            )
        }
        return root
    }
}
