import Foundation

enum DevinIntegrationConfiguration {
    static let cleanupArtifactKind = "devinIsolatedMCPConfiguration"
    private static let directoryPrefix = "RepoPromptDevinACP-"
    private static let sourceDevinPathMarkerName = ".repoprompt-source-devin-path"

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
        let sourceRoot = sourceConfigurationRoot(environment: sourceEnvironment)
        let sourceDevinDirectory = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: devinDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try linkExistingConfiguration(
                from: sourceRoot,
                to: root,
                excluding: ["devin"]
            )
            try linkExistingConfiguration(
                from: sourceDevinDirectory,
                to: devinDirectory,
                excluding: ["mcp_config.json"]
            )
            try sourceDevinDirectory.path.write(
                to: root.appendingPathComponent(sourceDevinPathMarkerName),
                atomically: true,
                encoding: .utf8
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
            // The overlay is for Devin, not for its MCP children. Preserve the native
            // config root for known stdio entries without overriding explicit server env.
            for (name, value) in servers {
                guard var child = value as? [String: Any],
                      child["transport"] as? String == "stdio",
                      child["env"] == nil || child["env"] is [String: String]
                else { continue }
                var environment = child["env"] as? [String: String] ?? [:]
                if environment["XDG_CONFIG_HOME"] == nil {
                    // A child HOME override owns the fallback when native XDG is unset.
                    let nativeEnvironment = sourceEnvironment.merging(environment) { _, child in child }
                    environment["XDG_CONFIG_HOME"] = sourceConfigurationRoot(environment: nativeEnvironment).path
                }
                child["env"] = environment
                servers[name] = child
            }
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

    static func cleanup(artifact: ACPLaunchCleanupArtifact) throws {
        guard artifact.providerID == .devin,
              artifact.kind == cleanupArtifactKind
        else {
            return
        }
        let root = configurationRoot(id: artifact.id)
        do {
            try preserveDevinWrites(in: root)
            try FileManager.default.removeItem(at: root)
        } catch {
            throw AIProviderError.invalidConfiguration(
                detail: "Unable to preserve Devin configuration writes. Recovery data remains at \(root.path): \(error.localizedDescription)"
            )
        }
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

    private static func linkExistingConfiguration(
        from source: URL,
        to destination: URL,
        excluding excludedNames: Set<String>
    ) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        for entry in try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        ) where !excludedNames.contains(entry.lastPathComponent) {
            try FileManager.default.createSymbolicLink(
                at: destination.appendingPathComponent(entry.lastPathComponent),
                withDestinationURL: entry
            )
        }
    }

    private static func preserveDevinWrites(in root: URL) throws {
        let marker = root.appendingPathComponent(sourceDevinPathMarkerName)
        let sourcePath = try String(contentsOf: marker, encoding: .utf8)
        let sourceDirectory = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL
        let overlayDirectory = root.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for entry in try FileManager.default.contentsOfDirectory(
            at: overlayDirectory,
            includingPropertiesForKeys: nil
        ) where entry.lastPathComponent != "mcp_config.json" {
            let sourceEntry = sourceDirectory.appendingPathComponent(entry.lastPathComponent)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path),
               URL(fileURLWithPath: destination).standardizedFileURL == sourceEntry.standardizedFileURL
            {
                continue
            }
            let replacement = sourceDirectory.appendingPathComponent(
                ".\(entry.lastPathComponent).repoprompt-\(UUID().uuidString)"
            )
            try FileManager.default.copyItem(at: entry, to: replacement)
            do {
                if FileManager.default.fileExists(atPath: sourceEntry.path) {
                    _ = try FileManager.default.replaceItemAt(sourceEntry, withItemAt: replacement)
                } else {
                    try FileManager.default.moveItem(at: replacement, to: sourceEntry)
                }
            } catch {
                try? FileManager.default.removeItem(at: replacement)
                throw error
            }
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
