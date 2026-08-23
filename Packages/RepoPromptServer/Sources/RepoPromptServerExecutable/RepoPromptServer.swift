import Crypto
import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
import RepoPromptRuntimeModel
import RepoPromptServerHost
import RepoPromptServiceHTTP
import RepoPromptServicePersistence

@main
struct RepoPromptServer {
    static func main() async throws {
        do {
            if CommandLine.arguments.dropFirst().first == "mcp-stdio" {
                try await HeadlessMCPStdioBridge.run()
                return
            }
            if CommandLine.arguments.dropFirst().first == "import-json" {
                try await importJSON(arguments: Array(CommandLine.arguments.dropFirst(2)))
                return
            }
            if CommandLine.arguments.dropFirst().first == "backup" {
                try await backup(arguments: Array(CommandLine.arguments.dropFirst(2)))
                return
            }
            if CommandLine.arguments.dropFirst().first == "migrate" {
                try await migrate(arguments: Array(CommandLine.arguments.dropFirst(2)))
                return
            }
            if CommandLine.arguments.dropFirst().first == "restore" {
                try await restore(arguments: Array(CommandLine.arguments.dropFirst(2)))
                return
            }
            if CommandLine.arguments.dropFirst().first == "operator" {
                try await operatorRecovery(arguments: Array(CommandLine.arguments.dropFirst(2)))
                return
            }
            if CommandLine.arguments.dropFirst().first == "process-family-smoke" {
                try await processFamilySmoke()
                return
            }
            try await RepoPromptServerRunner.run(configuration: .environment())
        } catch {
            ServerStructuredLogger.write(
                level: "error",
                event: "server.command",
                outcome: "failure",
                fields: ["errorType": String(reflecting: type(of: error))]
            )
            throw error
        }
    }

    private static func processFamilySmoke() async throws {
        #if os(Linux)
            let store = try await SQLiteServiceStore.open(storage: .memory)
            do {
                let launchingPort = try PortableProcessSupervisionPort()
                let leader = try await launchingPort.launch(
                    executable: "/bin/sh",
                    arguments: ["-c", "setsid /bin/sh -c 'sleep 30' & wait"],
                    environment: ["PATH": "/usr/local/bin:/usr/bin:/bin"],
                    workingDirectory: "/tmp",
                    helperToken: UUID().uuidString
                )
                let runID = UUID()
                let initial = ProviderProcessSupervisor(processPort: launchingPort, store: store)
                try await initial.register(runID: runID, leader: leader)
                let persistedFamilies = try await store.activeProcessFamilies()
                guard persistedFamilies.count == 1 else {
                    throw ConfigurationError.invalid("process family was not persisted")
                }

                let recoveredPort = try PortableProcessSupervisionPort()
                let recovered = ProviderProcessSupervisor(processPort: recoveredPort, store: store)
                try await recovered.recoverPersistedFamilies(graceScans: 3)
                let remainingFamilies = try await store.activeProcessFamilies()
                guard remainingFamilies.isEmpty else {
                    throw ConfigurationError.invalid("recovered process family was not reaped")
                }
                try await store.close()
                FileHandle.standardOutput.write(Data("RepoPromptServer process-family smoke passed\n".utf8))
            } catch {
                try? await store.close(clean: false)
                throw error
            }
        #else
            throw ConfigurationError.invalid("process-family-smoke is supported only on Linux")
        #endif
    }

    private static func importJSON(arguments: [String]) async throws {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let source = value(after: "--source") else {
            throw ConfigurationError.missing("--source")
        }
        let database = value(after: "--database") ?? ProcessInfo.processInfo.environment["REPOPROMPT_STATE_DB"] ?? "/var/lib/repoprompt/state/repoprompt.sqlite"
        let root = value(after: "--project-root").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let storageRoot = URL(fileURLWithPath: database).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let namespace = try AuthorityNamespaceDescriptor(
            storageRoot: storageRoot.path,
            databasePath: database,
            profile: ProcessInfo.processInfo.environment["REPOPROMPT_PROFILE"] ?? "default",
            servingMode: .server
        )
        let maintenance = try await AuthorityMaintenanceSession.open(
            configuration: .init(namespace: namespace)
        )
        do {
            let report = try await maintenance.importLegacyJSON(
                source: URL(fileURLWithPath: source),
                projectRoot: root
            )
            try await maintenance.close(clean: true)
            FileHandle.standardOutput.write(try JSONEncoder.serviceEncoder.encode(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            try? await maintenance.close(clean: false)
            throw error
        }
    }

    private static func backup(arguments: [String]) async throws {
        guard let operation = arguments.first else { throw ConfigurationError.missing("backup create|verify") }
        let options = Array(arguments.dropFirst())
        let service = try backupService()
        switch operation {
        case "create":
            guard let recipients = value(after: "--recipients-file", in: options) else {
                throw ConfigurationError.missing("--recipients-file")
            }
            guard let output = value(after: "--output", in: options) else {
                throw ConfigurationError.missing("--output")
            }
            let namespace = try authorityNamespace(arguments: options)
            let session = try await AuthorityMaintenanceSession.open(configuration: .init(namespace: namespace))
            do {
                let inventory = try productionBackupInventory(namespace: namespace)
                let sidecar = try await session.createBackup(
                    service: service,
                    request: BackupCreateRequest(
                        outputURL: URL(fileURLWithPath: output),
                        recipientsFileURL: URL(fileURLWithPath: recipients),
                        roots: inventory.roots,
                        externalAssets: inventory.externalAssets,
                        namespaceKind: namespace.servingMode.rawValue,
                        databaseIdentityDigest: namespace.namespaceID
                    )
                )
                try await session.close(clean: true)
                try writeJSON(sidecar)
            } catch {
                try? await session.close(clean: false)
                throw error
            }
        case "verify":
            guard let archive = options.first(where: { !$0.hasPrefix("-") }),
                  let identity = value(after: "--identity-file", in: options)
            else {
                throw ConfigurationError.missing("backup verify <archive> --identity-file")
            }
            let archiveURL = URL(fileURLWithPath: archive)
            let identityURL = URL(fileURLWithPath: identity)
            if options.contains("--database") {
                let namespace = try authorityNamespace(arguments: options)
                let session = try await AuthorityMaintenanceSession.open(configuration: .init(namespace: namespace))
                do {
                    let verified = try await session.verifyBackup(
                        service: service,
                        archiveURL: archiveURL,
                        identityFileURL: identityURL
                    )
                    try await session.close(clean: true)
                    try writeJSON(verified.sidecar)
                } catch {
                    try? await session.close(clean: false)
                    throw error
                }
            } else {
                let verified = try await service.verify(
                    archiveURL: archiveURL,
                    identityFileURL: identityURL
                )
                try writeJSON(verified.sidecar)
            }
        default:
            throw ConfigurationError.invalid("backup operation must be create or verify")
        }
    }

    private static func operatorRecovery(arguments: [String]) async throws {
        guard let operation = arguments.first else {
            throw ConfigurationError.missing("operator reset-password|issue-setup-token|revoke-all-sessions")
        }
        let options = Array(arguments.dropFirst())
        let namespace = try authorityNamespace(arguments: options)
        let session = try await AuthorityMaintenanceSession.open(configuration: .init(namespace: namespace))
        do {
            switch operation {
            case "reset-password":
                let descriptor = Int32(value(after: "--password-fd", in: options) ?? "0") ?? 0
                guard descriptor >= 0 else { throw ConfigurationError.invalid("--password-fd must be nonnegative") }
                let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
                let password = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
                try await session.resetOperatorPassword(password)
                try writeJSON(["ok": true])
            case "issue-setup-token":
                guard let output = value(after: "--output", in: options) else {
                    throw ConfigurationError.missing("operator issue-setup-token --output <owner-only-file>")
                }
                let token = try await session.issueOperatorSetupToken()
                let url = URL(fileURLWithPath: output)
                try writeOwnerOnlySecret(Data((token + "\n").utf8), to: url)
                try writeJSON(["output": url.path])
            case "revoke-all-sessions":
                try writeJSON(["revoked": try await session.revokeAllOperatorSessions()])
            default:
                throw ConfigurationError.invalid("operator operation must be reset-password, issue-setup-token, or revoke-all-sessions")
            }
            try await session.close(clean: true)
        } catch {
            try? await session.close(clean: false)
            throw error
        }
    }

    private static func migrate(arguments: [String]) async throws {
        guard let archive = value(after: "--verified-backup", in: arguments) else {
            throw ConfigurationError.missing("--verified-backup")
        }
        guard let identity = value(after: "--identity-file", in: arguments) else {
            throw ConfigurationError.missing("--identity-file")
        }
        let namespace = try authorityNamespace(arguments: arguments, requireNamespaceKind: true)
        let service = try backupService()
        let session = try await AuthorityMaintenanceSession.open(configuration: .init(namespace: namespace))
        do {
            let evidence = try await session.migrate(
                service: service,
                verifiedBackup: URL(fileURLWithPath: archive),
                identityFileURL: URL(fileURLWithPath: identity)
            )
            try await session.close(clean: true)
            try writeJSON(evidence)
        } catch {
            try? await session.close(clean: false)
            throw error
        }
    }

    private static func restore(arguments: [String]) async throws {
        guard arguments.first == "prepare" else {
            throw ConfigurationError.invalid("restore operation must be prepare")
        }
        let options = Array(arguments.dropFirst())
        guard let archive = options.first(where: { !$0.hasPrefix("-") }),
              let identity = value(after: "--identity-file", in: options),
              let target = value(after: "--target", in: options)
        else {
            throw ConfigurationError.missing("restore prepare <archive> --identity-file --target")
        }
        let kind = try namespaceKind(value(after: "--namespace-kind", in: options) ?? "server")
        let targetURL = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        let namespace = try AuthorityNamespaceDescriptor(
            storageRoot: targetURL.path,
            databasePath: targetURL.appendingPathComponent("repoprompt.sqlite").path,
            profile: ProcessInfo.processInfo.environment["REPOPROMPT_PROFILE"] ?? "default",
            servingMode: kind
        )
        let service = try backupService()
        let session = try AuthorityMaintenanceSession.acquireForRestore(
            configuration: .init(namespace: namespace)
        )
        do {
            let inventory = try productionBackupInventory(namespace: namespace)
            let manifest = try await session.prepareRestore(
                service: service,
                request: BackupRestoreRequest(
                    archiveURL: URL(fileURLWithPath: archive),
                    identityFileURL: URL(fileURLWithPath: identity),
                    targetRootURL: targetURL,
                    targetNamespaceKind: kind.rawValue,
                    targetDatabaseIdentityDigest: namespace.namespaceID,
                    observedExternalAssets: inventory.observedExternalAssets,
                    includedAssetTargetRoots: inventory.includedAssetTargetRoots
                )
            )
            try await session.close(clean: true)
            try writeJSON(manifest)
        } catch {
            try? await session.close(clean: false)
            throw error
        }
    }

    private static func authorityNamespace(
        arguments: [String],
        requireNamespaceKind: Bool = false
    ) throws -> AuthorityNamespaceDescriptor {
        let environment = ProcessInfo.processInfo.environment
        let database = value(after: "--database", in: arguments)
            ?? environment["REPOPROMPT_STATE_DB"]
            ?? "/var/lib/repoprompt/state/repoprompt.sqlite"
        let configuredKind = value(after: "--namespace-kind", in: arguments)
        if requireNamespaceKind, configuredKind == nil {
            throw ConfigurationError.missing("--namespace-kind server|direct-headless")
        }
        let kind = try namespaceKind(configuredKind ?? "server")
        let root = URL(fileURLWithPath: database).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try AuthorityNamespaceDescriptor(
            storageRoot: root.path,
            databasePath: database,
            profile: environment["REPOPROMPT_PROFILE"] ?? "default",
            servingMode: kind
        )
    }

    private static func namespaceKind(_ value: String) throws -> RepoPromptAuthorityServingMode {
        switch value {
        case "server": .server
        case "direct-headless", "directHeadless": .directHeadless
        default: throw ConfigurationError.invalid("namespace kind must be server or direct-headless")
        }
    }

    private struct ProductionBackupInventory {
        let roots: [BackupAssetRoot]
        let externalAssets: [BackupExternalAsset]
        let observedExternalAssets: [String: String]
        let includedAssetTargetRoots: [String: URL]
    }

    /// Mirrors every durable/configured production dependency without placing
    /// private paths or values in the archive manifest. Managed state is
    /// included; externally provisioned keys/trust are required fingerprints;
    /// provider extensions and credentials are optional degraded dependencies.
    private static func productionBackupInventory(
        namespace: AuthorityNamespaceDescriptor,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ProductionBackupInventory {
        let stateRoot = URL(fileURLWithPath: namespace.storageRoot, isDirectory: true).standardizedFileURL
        var roots = [BackupAssetRoot(logicalID: "", url: stateRoot)]
        let managedRoots: [(String, String)] = [
            (environment["REPOPROMPT_ARTIFACT_DIR"] ?? "/var/lib/repoprompt/artifacts", "artifacts"),
            (environment["REPOPROMPT_PROJECT_DIR"] ?? "/srv/repoprompt/projects", "projects"),
            (environment["REPOPROMPT_WORKTREE_DIR"] ?? "/srv/repoprompt/worktrees", "worktrees"),
            (environment["REPOPROMPT_PROVIDER_HOME_DIR"] ?? stateRoot.appendingPathComponent("provider-homes").path, "provider-homes-output"),
        ]
        let canonicalStateRoot = stateRoot.resolvingSymlinksInPath()
        var seenRoots = Set([canonicalStateRoot.path])
        var includedAssetTargetRoots: [String: URL] = [:]
        for (path, logicalID) in managedRoots {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let comparisonURL = FileManager.default.fileExists(atPath: url.path) ? url.resolvingSymlinksInPath() : url
            if comparisonURL.path == canonicalStateRoot.path || comparisonURL.path.hasPrefix(canonicalStateRoot.path + "/") { continue }
            includedAssetTargetRoots[logicalID] = url
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if seenRoots.insert(comparisonURL.path).inserted {
                roots.append(.init(logicalID: logicalID, url: url))
            }
        }

        var externalAssets: [BackupExternalAsset] = []
        var observed: [String: String] = [:]
        func record(
            logicalID: String,
            path: String?,
            disposition: BackupAssetDisposition,
            expectedVersion: String? = nil
        ) throws {
            guard let path, !path.isEmpty else { return }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let digest: String
            if FileManager.default.fileExists(atPath: url.path) {
                digest = try productionAssetDigest(url)
                observed[logicalID] = digest
            } else if disposition == .externalRequired {
                throw ServiceAPIError(
                    code: .dependencyUnavailable,
                    message: "Required configured backup dependency is unavailable: \(logicalID)"
                )
            } else {
                digest = SHA256.hash(data: Data("unavailable:\(logicalID):\(expectedVersion ?? "")".utf8))
                    .map { String(format: "%02x", $0) }.joined()
            }
            externalAssets.append(.init(
                logicalID: logicalID,
                disposition: disposition,
                expectedVersion: expectedVersion,
                expectedSHA256: digest
            ))
        }

        let requiredFiles: [(String, String)] = [
            ("signing.app.active", "REPOPROMPT_APP_HMAC_FILE"),
            ("signing.app.previous", "REPOPROMPT_APP_PREVIOUS_HMAC_FILE"),
            ("signing.sync.active", "REPOPROMPT_SYNC_HMAC_FILE"),
            ("signing.sync.previous", "REPOPROMPT_SYNC_PREVIOUS_HMAC_FILE"),
            ("signing.operator.active", "REPOPROMPT_OPERATOR_HMAC_FILE"),
            ("signing.operator.previous", "REPOPROMPT_OPERATOR_PREVIOUS_HMAC_FILE"),
            ("signing.event.active", "REPOPROMPT_EVENT_HMAC_FILE"),
            ("vault.provider.active", "REPOPROMPT_PROVIDER_VAULT_MASTER_KEY_FILE"),
            ("vault.provider.previous", "REPOPROMPT_PROVIDER_VAULT_PREVIOUS_MASTER_KEY_FILE"),
            ("tls.server.certificate", "REPOPROMPT_TLS_CERT_FILE"),
            ("tls.server.private-key", "REPOPROMPT_TLS_KEY_FILE"),
            ("tls.client-ca", "REPOPROMPT_TLS_CLIENT_CA_FILE"),
            ("project-source.policy", "REPOPROMPT_PROJECT_SOURCE_POLICY_FILE"),
        ]
        for (logicalID, key) in requiredFiles {
            try record(logicalID: logicalID, path: environment[key], disposition: .externalRequired)
        }
        // The default credential vault is archived by the state root. An
        // explicitly relocated vault remains durable configured state, but its
        // physical location must be reprovisioned and fingerprint-matched before
        // restore activation can safely reuse it.
        if let vaultPath = environment["REPOPROMPT_PROVIDER_VAULT_FILE"], !vaultPath.isEmpty {
            let vaultURL = URL(fileURLWithPath: vaultPath).standardizedFileURL.resolvingSymlinksInPath()
            let canonicalState = stateRoot.resolvingSymlinksInPath()
            if vaultURL.path != canonicalState.path,
               !vaultURL.path.hasPrefix(canonicalState.path + "/")
            {
                try record(
                    logicalID: "vault.provider.credential-store",
                    path: vaultPath,
                    disposition: .externalRequired
                )
            }
        }

        let providerDefinitions: [(String, String, String, String)] = [
            ("codex", "REPOPROMPT_CODEX_EXECUTABLE", "/opt/repoprompt/providers/codex", CodexCLIContract.pinnedVersion),
            ("claudeCompatible", "REPOPROMPT_CLAUDE_EXECUTABLE", "/opt/repoprompt/providers/claude", "2.1.226"),
            ("openCodeACP", "REPOPROMPT_OPENCODE_EXECUTABLE", "/opt/repoprompt/providers/opencode", "1.15.11"),
            ("cursorACP", "REPOPROMPT_CURSOR_EXECUTABLE", "/opt/repoprompt/providers/cursor-agent", "2026.08.04-aaa8809"),
            ("grokBuildACP", "REPOPROMPT_GROK_EXECUTABLE", "/opt/repoprompt/providers/grok", "1.0.4"),
        ]
        let enabled = Set((environment["REPOPROMPT_ENABLED_PROVIDERS"] ?? "codex,claudeCompatible")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        for (providerID, key, fallback, version) in providerDefinitions where enabled.contains(providerID) {
            try record(
                logicalID: "provider.\(providerID).binary",
                path: environment[key] ?? fallback,
                disposition: .externalOptional,
                expectedVersion: version
            )
        }

        let optionalFiles: [(String, String)] = [
            ("provider.codex.credentials", "REPOPROMPT_CODEX_CREDENTIAL_HOME"),
            ("provider.codex.auth-status", "REPOPROMPT_CODEX_AUTH_STATUS_FILE"),
            ("provider.claudeCompatible.credentials", "REPOPROMPT_CLAUDE_CREDENTIAL_HOME"),
            ("provider.openCodeACP.credentials", "REPOPROMPT_OPENCODE_CREDENTIAL_HOME"),
            ("provider.cursorACP.credentials", "REPOPROMPT_CURSOR_CREDENTIAL_HOME"),
            ("provider.grokBuildACP.credentials", "REPOPROMPT_GROK_CREDENTIAL_HOME"),
            ("provider.claudeCompatible.auth-status", "REPOPROMPT_CLAUDE_AUTH_STATUS_FILE"),
            ("provider.openCodeACP.auth-status", "REPOPROMPT_OPENCODE_AUTH_STATUS_FILE"),
            ("provider.cursorACP.auth-status", "REPOPROMPT_CURSOR_AUTH_STATUS_FILE"),
            ("provider.grokBuildACP.auth-status", "REPOPROMPT_GROK_AUTH_STATUS_FILE"),
            ("provider.xAI.auth-status", "REPOPROMPT_XAI_AUTH_STATUS_FILE"),
            ("provider.codex.model-catalog", "REPOPROMPT_CODEX_MODEL_CATALOG_FILE"),
            ("provider.claudeCompatible.model-catalog", "REPOPROMPT_CLAUDE_MODEL_CATALOG_FILE"),
            ("provider.openCodeACP.model-catalog", "REPOPROMPT_OPENCODE_MODEL_CATALOG_FILE"),
            ("provider.cursorACP.model-catalog", "REPOPROMPT_CURSOR_MODEL_CATALOG_FILE"),
            ("provider.grokBuildACP.model-catalog", "REPOPROMPT_GROK_MODEL_CATALOG_FILE"),
            ("provider.xAI.model-catalog", "REPOPROMPT_XAI_MODEL_CATALOG_FILE"),
            ("project-source.git-ssh-key", "REPOPROMPT_GIT_SSH_KEY_FILE"),
            ("project-source.git-known-hosts", "REPOPROMPT_GIT_KNOWN_HOSTS_FILE"),
        ]
        for (logicalID, key) in optionalFiles {
            try record(logicalID: logicalID, path: environment[key], disposition: .externalOptional)
        }

        return ProductionBackupInventory(
            roots: roots,
            externalAssets: externalAssets.sorted { $0.logicalID < $1.logicalID },
            observedExternalAssets: observed,
            includedAssetTargetRoots: includedAssetTargetRoots
        )
    }

    private static func productionAssetDigest(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ServiceAPIError(code: .invalidRequest, message: "Configured backup dependency may not be a symbolic link")
        }
        if values.isRegularFile == true {
            return SHA256.hash(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
                .map { String(format: "%02x", $0) }.joined()
        }
        guard values.isDirectory == true,
              let enumerator = FileManager.default.enumerator(
                  at: url,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              )
        else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Configured backup dependency is not a regular file or directory")
        }
        var entries: [String] = []
        while let entry = enumerator.nextObject() as? URL {
            let entryValues = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard entryValues.isSymbolicLink != true else {
                throw ServiceAPIError(code: .invalidRequest, message: "Configured backup dependency contains a symbolic link")
            }
            guard entryValues.isRegularFile == true else { continue }
            let relative = String(entry.path.dropFirst(url.path.count + 1))
            let digest = SHA256.hash(data: try Data(contentsOf: entry, options: [.mappedIfSafe]))
                .map { String(format: "%02x", $0) }.joined()
            entries.append("\(relative)\u{0}\(digest)")
        }
        return SHA256.hash(data: Data(entries.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func backupService() throws -> BackupRestoreService {
        let envelope = try AgeBackupEnvelope(configuration: .environment())
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let digest = (try? Data(contentsOf: executable, options: [.mappedIfSafe])).map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        } ?? String(repeating: "0", count: 64)
        return BackupRestoreService(envelope: envelope, toolVersion: "RepoPromptServer/0.1.0", toolDigest: digest)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
