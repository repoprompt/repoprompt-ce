import Darwin
import Foundation

enum DevinIntegrationConfiguration {
    static let cleanupArtifactKind = "devinIsolatedMCPConfiguration"
    private static let directoryPrefix = "RepoPromptDevinACP-"
    private static let sourceDevinPathMarkerName = ".repoprompt-source-devin-path"
    private static let sourceDevinSnapshotMarkerName = ".repoprompt-source-devin-snapshot.json"

    private struct SourceEntryFingerprint: Codable, Equatable {
        let deviceID: UInt64
        let fileNumber: UInt64
        let byteSize: Int64
        let kind: UInt32
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let permissionBits: UInt16
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64

        func matchesNativeIdentity(of other: SourceEntryFingerprint) -> Bool {
            deviceID == other.deviceID
                && fileNumber == other.fileNumber
                && byteSize == other.byteSize
                && kind == other.kind
                && permissionBits == other.permissionBits
                && modificationSeconds == other.modificationSeconds
                && modificationNanoseconds == other.modificationNanoseconds
        }
    }

    struct PreparedConfiguration {
        let environment: [String: String]
        let cleanupArtifact: ACPLaunchCleanupArtifact
    }

    enum MCPServersPolicy {
        case mergeRepoPrompt(RepoPromptMCPServerConfiguration)
        case disableAll
    }

    static func prepare(
        workingDirectory: String,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration,
        sourceEnvironment: [String: String]
    ) throws -> PreparedConfiguration {
        try prepare(
            workingDirectory: workingDirectory,
            mcpServers: .mergeRepoPrompt(repoPromptMCPConfiguration),
            sourceEnvironment: sourceEnvironment
        )
    }

    static func prepare(
        workingDirectory: String,
        mcpServers policy: MCPServersPolicy,
        sourceEnvironment: [String: String]
    ) throws -> PreparedConfiguration {
        let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration? = switch policy {
        case let .mergeRepoPrompt(configuration):
            configuration
        case .disableAll:
            nil
        }
        try repoPromptMCPConfiguration?.validateACPLaunchCommand(workingDirectory: workingDirectory)

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
            try JSONEncoder().encode(sourceEntryFingerprints(in: sourceDevinDirectory)).write(
                to: root.appendingPathComponent(sourceDevinSnapshotMarkerName),
                options: .atomic
            )

            let sourceMCPURL = sourceDevinDirectory.appendingPathComponent("mcp_config.json")
            var rootObject = try existingMCPRootObject(at: sourceMCPURL)
            var servers: [String: Any] = [:]
            if let repoPromptMCPConfiguration {
                servers = rootObject["mcpServers"] as? [String: Any] ?? [:]
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
                          usesStdioTransport(child),
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

    static func cleanupReportingFailures(artifact: ACPLaunchCleanupArtifact) {
        do {
            try cleanup(artifact: artifact)
        } catch {
            let message = "[ACP][devin] \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    static func cleanup(
        artifact: ACPLaunchCleanupArtifact,
        beforeReplacing: ((URL) throws -> Void)? = nil
    ) throws {
        guard artifact.providerID == .devin,
              artifact.kind == cleanupArtifactKind
        else {
            return
        }
        let root = configurationRoot(id: artifact.id)
        do {
            try preserveDevinWrites(in: root, beforeReplacing: beforeReplacing)
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

    private static func preserveDevinWrites(
        in root: URL,
        beforeReplacing: ((URL) throws -> Void)?
    ) throws {
        let marker = root.appendingPathComponent(sourceDevinPathMarkerName)
        let sourcePath = try String(contentsOf: marker, encoding: .utf8)
        let sourceDirectory = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL
        let overlayDirectory = root.appendingPathComponent("devin", isDirectory: true)
        let snapshots = try JSONDecoder().decode(
            [String: SourceEntryFingerprint].self,
            from: Data(contentsOf: root.appendingPathComponent(sourceDevinSnapshotMarkerName))
        )
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
            let originalFingerprint = snapshots[entry.lastPathComponent]
            let currentFingerprint = try sourceEntryFingerprint(at: sourceEntry)
            guard currentFingerprint == originalFingerprint,
                  originalFingerprint?.kind != UInt32(S_IFDIR)
            else {
                throw AIProviderError.invalidConfiguration(
                    detail: "Native Devin configuration changed during the run: \(sourceEntry.path)"
                )
            }
            let replacement = sourceDirectory.appendingPathComponent(
                ".\(entry.lastPathComponent).repoprompt-\(UUID().uuidString)"
            )
            try FileManager.default.copyItem(at: entry, to: replacement)
            do {
                try beforeReplacing?(sourceEntry)
            } catch {
                try? FileManager.default.removeItem(at: replacement)
                throw error
            }
            try publishReplacement(
                replacement,
                at: sourceEntry,
                expectedFingerprint: originalFingerprint
            )
        }
    }

    private static func sourceEntryFingerprints(in directory: URL) throws -> [String: SourceEntryFingerprint] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        return try Dictionary(
            uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.lastPathComponent != "mcp_config.json" }
            .map { entry in
                guard let fingerprint = try sourceEntryFingerprint(at: entry) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return (entry.lastPathComponent, fingerprint)
            }
        )
    }

    private static func sourceEntryFingerprint(at url: URL) throws -> SourceEntryFingerprint? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return SourceEntryFingerprint(
            deviceID: UInt64(bitPattern: Int64(info.st_dev)),
            fileNumber: UInt64(info.st_ino),
            byteSize: Int64(info.st_size),
            kind: UInt32(info.st_mode & mode_t(S_IFMT)),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            permissionBits: UInt16(UInt32(info.st_mode) & 0o7777),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private static func publishReplacement(
        _ replacement: URL,
        at source: URL,
        expectedFingerprint: SourceEntryFingerprint?
    ) throws {
        guard let expectedFingerprint else {
            guard renamex_np(replacement.path, source.path, UInt32(RENAME_EXCL)) == 0 else {
                let errorNumber = errno
                try? FileManager.default.removeItem(at: replacement)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber))
            }
            return
        }

        guard let publishedFingerprint = try sourceEntryFingerprint(at: replacement) else {
            throw CocoaError(.fileNoSuchFile)
        }

        guard renamex_np(replacement.path, source.path, UInt32(RENAME_SWAP)) == 0 else {
            let errorNumber = errno
            try? FileManager.default.removeItem(at: replacement)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber))
        }

        let displacedFingerprint: SourceEntryFingerprint
        do {
            guard let fingerprint = try sourceEntryFingerprint(at: replacement) else {
                throw CocoaError(.fileNoSuchFile)
            }
            displacedFingerprint = fingerprint
        } catch {
            try restoreSource(
                replacement: replacement,
                source: source,
                publishedFingerprint: publishedFingerprint
            )
            throw error
        }
        guard displacedFingerprint.matchesNativeIdentity(of: expectedFingerprint) else {
            try restoreSource(
                replacement: replacement,
                source: source,
                publishedFingerprint: publishedFingerprint
            )
            throw AIProviderError.invalidConfiguration(
                detail: "Native Devin configuration changed during publication: \(source.path)"
            )
        }

        // The live path already holds the overlay. Do not swap back on cleanup failure:
        // a concurrent native write to `source` would land in `replacement` and then be deleted.
        try FileManager.default.removeItem(at: replacement)
    }

    private static func restoreSource(
        replacement: URL,
        source: URL,
        publishedFingerprint: SourceEntryFingerprint
    ) throws {
        let current = try sourceEntryFingerprint(at: source)
        guard let current, current.matchesNativeIdentity(of: publishedFingerprint) else {
            try? FileManager.default.removeItem(at: replacement)
            return
        }
        guard renamex_np(replacement.path, source.path, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: replacement.path]
            )
        }
        try? FileManager.default.removeItem(at: replacement)
    }

    private static func usesStdioTransport(_ child: [String: Any]) -> Bool {
        if let transport = child["transport"] as? String {
            return transport == "stdio"
        }
        return child["command"] is String
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
