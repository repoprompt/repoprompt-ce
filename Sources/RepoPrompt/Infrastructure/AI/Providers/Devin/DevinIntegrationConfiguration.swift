import Darwin
import Foundation

enum DevinIntegrationConfiguration {
    static let cleanupArtifactKind = "devinIsolatedMCPConfiguration"
    private static let directoryPrefix = "RepoPromptDevinACP-"
    private static let sourceDevinPathMarkerName = ".repoprompt-source-devin-path"
    private static let sourceDevinSnapshotMarkerName = ".repoprompt-source-devin-snapshot.json"
    /// Bytes of the overlay settings as `prepare` wrote them, so cleanup can tell an untouched
    /// overlay apart from a Devin write even after native settings changed during the run.
    private static let preparedSettingsMarkerName = ".repoprompt-prepared-devin-settings.json"
    private static let settingsFileName = "config.json"
    private static let readConfigFromKey = "read_config_from"
    /// Devin imports MCP servers from these tools' configs, and a same-named project entry
    /// (for example `RepoPromptCE` in `~/.claude.json`) replaces the injected server. The
    /// replacement then connects under another client identity and the run never routes.
    private static let foreignMCPImportSources = ["claude", "cursor"]

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
        sourceEnvironment: [String: String],
        isolateForeignMCPImports: Bool = true
    ) throws -> PreparedConfiguration {
        let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration? = switch policy {
        case let .mergeRepoPrompt(configuration):
            configuration
        case .disableAll:
            nil
        }
        try repoPromptMCPConfiguration?.validateACPLaunchCommand(workingDirectory: workingDirectory)
        // Ordinary Agent Mode keeps Devin's imports (they also carry rules and skills) unless an
        // imported server would replace the injected RepoPrompt one and leave the run unrouted.
        let isolateForeignMCPImports = isolateForeignMCPImports || repoPromptMCPConfiguration.map {
            foreignImportsShadowServer(
                named: $0.name,
                workingDirectory: workingDirectory,
                environment: sourceEnvironment
            )
        } == true
        if isolateForeignMCPImports {
            try validateProjectImportIsolation(workingDirectory: workingDirectory)
        }

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
            // Import switches also suppress rules/skills. Headless runs isolate them; ordinary
            // Agent Mode keeps native settings unless an import would replace RepoPrompt's server.
            if isolateForeignMCPImports {
                try writeImportIsolatedSettings(
                    from: sourceDevinDirectory.appendingPathComponent(settingsFileName),
                    to: devinDirectory.appendingPathComponent(settingsFileName)
                )
                let preparedSettingsMarker = root.appendingPathComponent(preparedSettingsMarkerName)
                try Data(contentsOf: devinDirectory.appendingPathComponent(settingsFileName))
                    .write(to: preparedSettingsMarker, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preparedSettingsMarker.path)
            }
            try linkExistingConfiguration(
                from: sourceDevinDirectory,
                to: devinDirectory,
                excluding: isolateForeignMCPImports ? ["mcp_config.json", settingsFileName] : ["mcp_config.json"]
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
        let preparedSettings = try? Data(contentsOf: root.appendingPathComponent(preparedSettingsMarkerName))
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
            if entry.lastPathComponent == settingsFileName,
               let preparedSettings,
               (try? Data(contentsOf: entry)) == preparedSettings
            {
                // Devin wrote nothing; a foreign native change is not ours to publish over.
                continue
            }
            if entry.lastPathComponent == settingsFileName,
               preparedSettings != nil,
               try !restoreNativeImportSettings(overlay: entry, native: sourceEntry)
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

    /// Project/local settings override the user overlay. Resolve nearest-directory and local
    /// overrides first, stopping at the checkout root (including Git worktrees), without writes.
    private static func validateProjectImportIsolation(workingDirectory: String) throws {
        var directory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        var resolvedSources = Set<String>()
        while true {
            for fileName in ["config.local.json", "config.json"] {
                let file = directory.appendingPathComponent(".devin").appendingPathComponent(fileName)
                guard let settings = settingsObject(at: file) else {
                    throw AIProviderError.invalidConfiguration(
                        detail: "Cannot verify Devin import isolation: \(file.path) is not a readable JSON object. Please fix or remove that file."
                    )
                }
                guard let value = settings[readConfigFromKey] else { continue }
                guard let imports = value as? [String: Any] else {
                    throw AIProviderError.invalidConfiguration(
                        detail: "Cannot verify Devin import isolation: read_config_from in \(file.path) must be an object."
                    )
                }
                for source in foreignMCPImportSources where !resolvedSources.contains(source) {
                    guard let value = imports[source] else { continue }
                    guard let enabled = value as? Bool, !enabled else {
                        throw AIProviderError.invalidConfiguration(
                            detail: "Devin import isolation is overridden by \(file.path): set read_config_from.\(source) to false "
                                + "or remove that override before running Devin through RepoPrompt. RepoPrompt has not changed the file."
                        )
                    }
                    resolvedSources.insert(source)
                }
            }
            if directory.path == "/"
                || FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
                || FileManager.default.fileExists(atPath: directory.appendingPathComponent(".jj").path)
            {
                return
            }
            directory.deleteLastPathComponent()
        }
    }

    /// Whether a Claude or Cursor config Devin imports MCP servers from defines a server named like
    /// the injected RepoPrompt one, which the import would replace. Checks `~/.claude.json` (global
    /// and per-project entries for the working directory or an ancestor), `~/.cursor/mcp.json`,
    /// and project `.mcp.json` / `.cursor/mcp.json` up to the checkout root. A config that exists
    /// but cannot be parsed counts as shadowing, so the launch isolates instead of risking it.
    private static func foreignImportsShadowServer(
        named serverName: String,
        workingDirectory: String,
        environment: [String: String]
    ) -> Bool {
        let name = serverName.lowercased()
        func shadows(configAt url: URL, serverTables: ([String: Any]) -> [Any?]) -> Bool {
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data, options: .json5Allowed)) as? [String: Any]
            else { return true }
            return serverTables(object).contains { table in
                (table as? [String: Any])?.keys.contains { $0.lowercased() == name } ?? false
            }
        }
        let homePath = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        var directory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let workingPath = directory.path
        let claudeShadows = shadows(configAt: home.appendingPathComponent(".claude.json")) { object in
            var tables: [Any?] = [object["mcpServers"]]
            for (path, project) in object["projects"] as? [String: Any] ?? [:] {
                let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
                guard workingPath == root || workingPath.hasPrefix(root == "/" ? root : root + "/") else { continue }
                tables.append((project as? [String: Any])?["mcpServers"])
            }
            return tables
        }
        if claudeShadows || shadows(configAt: home.appendingPathComponent(".cursor/mcp.json"), serverTables: { [$0["mcpServers"]] }) {
            return true
        }
        while true {
            for file in [".mcp.json", ".cursor/mcp.json"]
                where shadows(configAt: directory.appendingPathComponent(file), serverTables: { [$0["mcpServers"]] })
            {
                return true
            }
            if directory.path == "/"
                || FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
                || FileManager.default.fileExists(atPath: directory.appendingPathComponent(".jj").path)
            {
                return false
            }
            directory.deleteLastPathComponent()
        }
    }

    /// A missing native file isolates from an empty object; one that cannot be read or is not a
    /// JSON object throws rather than fall back to the native file.
    private static func writeImportIsolatedSettings(from source: URL, to destination: URL) throws {
        guard var settings = settingsObject(at: source) else {
            throw AIProviderError.invalidConfiguration(
                detail: "Devin settings at \(source.path) could not be read as a JSON object, so RepoPrompt cannot "
                    + "turn off Devin's Claude and Cursor MCP imports for this launch. Please fix or remove that file."
            )
        }
        var readConfigFrom = settings[readConfigFromKey] as? [String: Any] ?? [:]
        for importSource in foreignMCPImportSources {
            readConfigFrom[importSource] = false
        }
        settings[readConfigFromKey] = readConfigFrom
        try writeSettings(settings, to: destination, permissions: posixPermissions(at: source) ?? 0o600)
    }

    /// Keeps the launch-only import switches out of native config. Returns false when the
    /// overlay holds no Devin write to publish.
    private static func restoreNativeImportSettings(overlay: URL, native: URL) throws -> Bool {
        guard var settings = settingsObject(at: overlay),
              let nativeSettings = settingsObject(at: native)
        else {
            return true
        }
        settings[readConfigFromKey] = restoredReadConfigFrom(
            overlay: settings[readConfigFromKey],
            native: nativeSettings[readConfigFromKey]
        )
        guard !NSDictionary(dictionary: settings).isEqual(to: nativeSettings) else { return false }
        // Publishing re-serializes as strict JSON; never do that over JSON5-only syntax
        // (comments, trailing commas) the user wrote. The overlay stays as recovery data.
        if let nativeData = try? Data(contentsOf: native),
           (try? JSONSerialization.jsonObject(with: nativeData)) == nil
        {
            throw AIProviderError.invalidConfiguration(
                detail: "Devin changed its settings during the run, but \(native.path) uses JSON5 syntax "
                    + "RepoPrompt cannot rewrite without losing it, so the native file was left unchanged."
            )
        }
        try writeSettings(settings, to: overlay, permissions: posixPermissions(at: overlay) ?? 0o600)
        return true
    }

    /// Undoes only the import toggles RepoPrompt set, keeping every other key's current value.
    /// A toggle present natively gets its native value back; one RepoPrompt added is removed.
    private static func restoredReadConfigFrom(overlay: Any?, native: Any?) -> Any? {
        guard var restored = overlay as? [String: Any] else { return overlay }
        let nativeReadConfigFrom = native as? [String: Any]
        for importSource in foreignMCPImportSources {
            restored[importSource] = nativeReadConfigFrom?[importSource]
        }
        // Prepare replaces an absent or non-object value with an object; with nothing else
        // written into it, the native value is restored as it was.
        if restored.isEmpty, nativeReadConfigFrom == nil {
            return native
        }
        return restored
    }

    /// Returns an empty object for a missing file and nil for anything that is not a JSON object.
    private static func settingsObject(at url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .json5Allowed)) as? [String: Any]
    }

    private static func writeSettings(_ settings: [String: Any], to url: URL, permissions: Int) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func posixPermissions(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
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
