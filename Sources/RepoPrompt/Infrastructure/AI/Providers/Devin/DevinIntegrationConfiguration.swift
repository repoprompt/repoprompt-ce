import Foundation

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
        sourceConfigurationRoot: URL? = nil
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
            let sourceRoot = sourceConfigurationRoot ?? defaultSourceConfigurationRoot()
            let sourceDevinDirectory = sourceRoot.appendingPathComponent("devin", isDirectory: true)
            try linkExistingConfiguration(
                from: sourceDevinDirectory,
                to: devinDirectory
            )

            let sourceMCPURL = sourceDevinDirectory.appendingPathComponent("mcp_config.json")
            var rootObject = try existingMCPRootObject(at: sourceMCPURL)
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
            rootObject["mcpServers"] = servers
            let data = try JSONSerialization.data(
                withJSONObject: rootObject,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: configURL, options: .atomic)
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

    private static func defaultSourceConfigurationRoot() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["XDG_CONFIG_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            let expanded = (configured as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
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
