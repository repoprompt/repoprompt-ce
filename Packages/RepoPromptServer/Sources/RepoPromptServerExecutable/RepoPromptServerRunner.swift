import Foundation
import Hummingbird
import HummingbirdTLS
import NIOSSL
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
import RepoPromptServerHost
import RepoPromptServiceHTTP
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

public struct RepoPromptServerConfiguration: Sendable {
    public let profileIdentifier: String
    public let stateDatabasePath: String
    public let worktreeDirectory: String
    public let artifactDirectory: String
    public let projectDirectory: String
    public let cacheDirectory: String
    public let providerHomeDirectory: String
    public let bindHost: String
    public let bindPort: Int
    public let healthHost: String
    public let healthPort: Int
    public let portalHost: String
    public let portalPort: Int?
    public let certificatePath: String
    public let privateKeyPath: String
    public let clientCAPath: String?
    public let operatorCertIdentity: String?
    public var usesMutualTLS: Bool { clientCAPath != nil }
    public let signingKeys: [InternalSigningKey]
    public let eventSigningKey: InternalSigningKey
    public let providerExecutables: [ProviderKind: String]
    public let enabledProviders: Set<ProviderKind>
    public let enabledDirectProviders: Set<ProviderSettingsID>
    public let providerVersions: [ProviderKind: String]
    public let providerProtocols: [ProviderKind: String]
    public let providerCredentialSources: [ProviderKind: String]
    public let providerAuthenticationStatusFiles: [ProviderSettingsID: String]
    public let providerModelCatalogFiles: [ProviderSettingsID: String]
    public let providerVaultKey: ProviderVaultKey?
    public let providerVaultDecryptionKeys: [ProviderVaultKey]
    public let providerVaultFilePath: String
    public let minimumFreeBytes: Int64
    public let minimumFreeNodes: Int64
    public let maximumActiveSessions: Int
    public let restoreActivationTokenPath: String?
    public let projectSourcePolicy: ProjectSourcePolicy
    public let projectSourceGitCredentials: ProjectSourceGitCredentials

    public static func environment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else { throw ConfigurationError.missing(name) }
            return value
        }
        func secret(_ variable: String) throws -> Data {
            let path = try required(variable)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return Data(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        }
        func secretFromFile(_ path: String) throws -> Data {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return Data(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        }
        func previousKey(prefix: String, role: InternalRouteRole, direction: String) throws -> InternalSigningKey? {
            let id = environment["\(prefix)_PREVIOUS_KEY_ID"]
            let file = environment["\(prefix)_PREVIOUS_HMAC_FILE"]
            guard id != nil || file != nil else { return nil }
            guard let id, !id.isEmpty, file != nil else { throw ConfigurationError.invalid("\(prefix) previous key ID and HMAC file must be configured together") }
            return try InternalSigningKey(keyID: id, role: role, direction: direction, secret: secret("\(prefix)_PREVIOUS_HMAC_FILE"), active: false)
        }
        func optionalSigningKey(
            hmacFile: String,
            keyIDName: String,
            defaultKeyID: String,
            role: InternalRouteRole,
            direction: String
        ) throws -> InternalSigningKey? {
            guard let path = environment[hmacFile], !path.isEmpty else { return nil }
            return try InternalSigningKey(
                keyID: environment[keyIDName].flatMap { $0.isEmpty ? nil : $0 } ?? defaultKeyID,
                role: role,
                direction: direction,
                secret: secret(hmacFile)
            )
        }
        let app = try optionalSigningKey(
            hmacFile: "REPOPROMPT_APP_HMAC_FILE",
            keyIDName: "REPOPROMPT_APP_KEY_ID",
            defaultKeyID: "app-v1",
            role: .app,
            direction: InternalHMACDirection.appToRepoPrompt
        )
        let sync = try optionalSigningKey(
            hmacFile: "REPOPROMPT_SYNC_HMAC_FILE",
            keyIDName: "REPOPROMPT_SYNC_KEY_ID",
            defaultKeyID: "sync-v1",
            role: .sync,
            direction: InternalHMACDirection.syncToRepoPrompt
        )
        if (app == nil) != (sync == nil) {
            throw ConfigurationError.invalid("App and sync HMAC files must be configured together")
        }
        let operatorKey = try optionalSigningKey(
            hmacFile: "REPOPROMPT_OPERATOR_HMAC_FILE",
            keyIDName: "REPOPROMPT_OPERATOR_KEY_ID",
            defaultKeyID: "repoprompt-operator-v1",
            role: .operatorRole,
            direction: InternalHMACDirection.operatorToRepoPrompt
        )
        let stateDatabase = environment["REPOPROMPT_STATE_DB"] ?? "/var/lib/repoprompt/state/repoprompt.sqlite"
        let event: InternalSigningKey
        if let eventFile = environment["REPOPROMPT_EVENT_HMAC_FILE"], !eventFile.isEmpty {
            event = try InternalSigningKey(
                keyID: environment["REPOPROMPT_EVENT_KEY_ID"] ?? "repoprompt-event-v1",
                role: .sync,
                direction: environment["REPOPROMPT_EVENT_DIRECTION"].flatMap { $0.isEmpty ? nil : $0 } ?? InternalHMACDirection.repoPromptToClient,
                secret: secret("REPOPROMPT_EVENT_HMAC_FILE")
            )
        } else {
            let eventURL = URL(fileURLWithPath: stateDatabase).deletingLastPathComponent().appendingPathComponent("event-signing.hmac")
            try FileManager.default.createDirectory(at: eventURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: eventURL.path) {
                try randomHMACSecret().write(to: eventURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: eventURL.path)
            }
            event = try InternalSigningKey(
                keyID: environment["REPOPROMPT_EVENT_KEY_ID"] ?? "repoprompt-event-v1",
                role: .sync,
                direction: InternalHMACDirection.repoPromptToClient,
                secret: secretFromFile(eventURL.path)
            )
        }
        var signingKeys = [app, sync, operatorKey].compactMap(\.self)
        if let app, let previous = try previousKey(prefix: "REPOPROMPT_APP", role: .app, direction: app.direction) {
            signingKeys.append(previous)
        }
        if let sync, let previous = try previousKey(prefix: "REPOPROMPT_SYNC", role: .sync, direction: sync.direction) {
            signingKeys.append(previous)
        }
        if let operatorKey, let previous = try previousKey(prefix: "REPOPROMPT_OPERATOR", role: .operatorRole, direction: operatorKey.direction) {
            signingKeys.append(previous)
        }
        let allSigningKeys = signingKeys + [event]
        guard allSigningKeys.allSatisfy({
            $0.keyID.range(of: "^[A-Za-z0-9_.:-]{1,128}$", options: .regularExpression) != nil && $0.secret.count >= 32
        }) else { throw ConfigurationError.invalid("Internal signing keys require a valid key ID and at least 256 bits") }
        guard Set(signingKeys.map(\.keyID)).count == signingKeys.count else { throw ConfigurationError.invalid("Internal signing key IDs must be unique across roles and rotations") }
        let providers: [ProviderKind: String] = [
            .codex: environment["REPOPROMPT_CODEX_EXECUTABLE"] ?? "/opt/repoprompt/providers/codex",
            .claudeCompatible: environment["REPOPROMPT_CLAUDE_EXECUTABLE"] ?? "/opt/repoprompt/providers/claude",
            .openCodeACP: environment["REPOPROMPT_OPENCODE_EXECUTABLE"] ?? "/opt/repoprompt/providers/opencode",
            .cursorACP: environment["REPOPROMPT_CURSOR_EXECUTABLE"] ?? "/opt/repoprompt/providers/cursor-agent",
            .grokBuildACP: environment["REPOPROMPT_GROK_EXECUTABLE"] ?? "/opt/repoprompt/providers/grok"
        ]
        let enabledProviderNames = if let configured = environment["REPOPROMPT_ENABLED_PROVIDERS"] {
            configured
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        } else {
            [ProviderKind.codex.rawValue, ProviderKind.claudeCompatible.rawValue]
        }
        var enabledProviders = Set<ProviderKind>()
        for name in enabledProviderNames {
            guard let kind = ProviderKind(rawValue: name), providers[kind] != nil else {
                throw ConfigurationError.invalid("REPOPROMPT_ENABLED_PROVIDERS contains an unknown or non-catalogued provider: \(name)")
            }
            enabledProviders.insert(kind)
        }
        let allowedDirectProviders = Set(ProviderSettingsID.directAPIProviders)
        let enabledDirectProviderNames = environment["REPOPROMPT_ENABLED_DIRECT_PROVIDERS"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        var enabledDirectProviders = Set<ProviderSettingsID>()
        for name in enabledDirectProviderNames where !name.isEmpty {
            guard let providerID = ProviderSettingsID(rawValue: name), allowedDirectProviders.contains(providerID) else {
                throw ConfigurationError.invalid("REPOPROMPT_ENABLED_DIRECT_PROVIDERS contains an unknown or prohibited provider: \(name)")
            }
            enabledDirectProviders.insert(providerID)
        }
        let versions: [ProviderKind: String] = [.codex: CodexCLIContract.pinnedVersion, .claudeCompatible: "2.1.226", .openCodeACP: "1.15.11", .cursorACP: "2026.08.04-aaa8809", .grokBuildACP: "1.0.4"]
        let protocols: [ProviderKind: String] = [.codex: "app-server-v2", .claudeCompatible: "stream-json-v1", .openCodeACP: "acp-v1", .cursorACP: "acp-v1-beta", .grokBuildACP: "acp-v1"]
        if environment["REPOPROMPT_CODEX_CREDENTIAL_HOME"].map({ !$0.isEmpty }) == true
            || environment["REPOPROMPT_CODEX_AUTH_STATUS_FILE"].map({ !$0.isEmpty }) == true
        {
            throw ConfigurationError.invalid("Codex authentication must use the server-managed provider state")
        }
        let credentialSources = [
            (ProviderKind.claudeCompatible, environment["REPOPROMPT_CLAUDE_CREDENTIAL_HOME"]),
            (.openCodeACP, environment["REPOPROMPT_OPENCODE_CREDENTIAL_HOME"]),
            (.cursorACP, environment["REPOPROMPT_CURSOR_CREDENTIAL_HOME"]),
            (.grokBuildACP, environment["REPOPROMPT_GROK_CREDENTIAL_HOME"])
        ].reduce(into: [ProviderKind: String]()) { result, value in if let path = value.1, !path.isEmpty { result[value.0] = path } }
        func optionalAbsoluteFiles(_ values: [(ProviderSettingsID, String?)], label: String) throws -> [ProviderSettingsID: String] {
            try values.reduce(into: [:]) { result, value in
                guard let path = value.1, !path.isEmpty else { return }
                guard path.hasPrefix("/") else { throw ConfigurationError.invalid("\(label) paths must be absolute") }
                result[value.0] = path
            }
        }
        let authenticationStatusFiles = try optionalAbsoluteFiles([
            (.claudeCompatible, environment["REPOPROMPT_CLAUDE_AUTH_STATUS_FILE"]),
            (.openCodeACP, environment["REPOPROMPT_OPENCODE_AUTH_STATUS_FILE"]),
            (.cursorACP, environment["REPOPROMPT_CURSOR_AUTH_STATUS_FILE"]),
            (.grokBuildACP, environment["REPOPROMPT_GROK_AUTH_STATUS_FILE"]),
            (.xAI, environment["REPOPROMPT_XAI_AUTH_STATUS_FILE"])
        ], label: "Provider authentication status")
        let modelCatalogFiles = try optionalAbsoluteFiles([
            (.codex, environment["REPOPROMPT_CODEX_MODEL_CATALOG_FILE"]),
            (.claudeCompatible, environment["REPOPROMPT_CLAUDE_MODEL_CATALOG_FILE"]),
            (.openCodeACP, environment["REPOPROMPT_OPENCODE_MODEL_CATALOG_FILE"]),
            (.cursorACP, environment["REPOPROMPT_CURSOR_MODEL_CATALOG_FILE"]),
            (.grokBuildACP, environment["REPOPROMPT_GROK_MODEL_CATALOG_FILE"]),
            (.xAI, environment["REPOPROMPT_XAI_MODEL_CATALOG_FILE"])
        ], label: "Provider model catalog")
        let vaultKey: ProviderVaultKey?
        if let keyFile = environment["REPOPROMPT_PROVIDER_VAULT_MASTER_KEY_FILE"], !keyFile.isEmpty {
            guard keyFile.hasPrefix("/") else { throw ConfigurationError.invalid("Provider vault master key path must be absolute") }
            vaultKey = try ProviderVaultKey.load(keyID: environment["REPOPROMPT_PROVIDER_VAULT_KEY_ID"] ?? "provider-vault-v1", filePath: keyFile)
        } else {
            vaultKey = nil
        }
        let previousVaultKeyID = environment["REPOPROMPT_PROVIDER_VAULT_PREVIOUS_KEY_ID"]
        let previousVaultKeyFile = environment["REPOPROMPT_PROVIDER_VAULT_PREVIOUS_MASTER_KEY_FILE"]
        guard (previousVaultKeyID == nil) == (previousVaultKeyFile == nil) else {
            throw ConfigurationError.invalid("Provider vault previous key ID and master key file must be configured together")
        }
        let previousVaultKeys: [ProviderVaultKey]
        if let previousVaultKeyID, let previousVaultKeyFile {
            guard !previousVaultKeyID.isEmpty,
                  previousVaultKeyFile.hasPrefix("/"),
                  let vaultKey,
                  previousVaultKeyID != vaultKey.keyID
            else {
                throw ConfigurationError.invalid("Provider vault previous key requires a distinct active key and an absolute key path")
            }
            previousVaultKeys = try [ProviderVaultKey.load(keyID: previousVaultKeyID, filePath: previousVaultKeyFile)]
        } else {
            previousVaultKeys = []
        }
        if !enabledDirectProviders.isEmpty, vaultKey == nil {
            throw ConfigurationError.invalid("Deployment-admitted direct providers require a provider vault master key")
        }
        let vaultFilePath = environment["REPOPROMPT_PROVIDER_VAULT_FILE"] ?? URL(fileURLWithPath: stateDatabase).deletingLastPathComponent().appendingPathComponent("provider-credentials.vault").path
        guard vaultFilePath.hasPrefix("/") else {
            throw ConfigurationError.invalid("Provider vault path must be absolute")
        }
        let projectSourcePolicy: ProjectSourcePolicy
        if let path = environment["REPOPROMPT_PROJECT_SOURCE_POLICY_FILE"], !path.isEmpty {
            guard path.hasPrefix("/") else { throw ConfigurationError.invalid("Project source policy path must be absolute") }
            projectSourcePolicy = try ProjectSourcePolicy.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            projectSourcePolicy = .disabled
        }
        let projectSourceGitCredentials = try ProjectSourceGitCredentials(
            sshPrivateKeyPath: environment["REPOPROMPT_GIT_SSH_KEY_FILE"],
            sshKnownHostsPath: environment["REPOPROMPT_GIT_KNOWN_HOSTS_FILE"]
        )
        let trustDirectory = URL(fileURLWithPath: stateDatabase).deletingLastPathComponent().appendingPathComponent("trust")
        let tlsCert = environment["REPOPROMPT_TLS_CERT_FILE"].flatMap { $0.isEmpty ? nil : $0 }
        let tlsKey = environment["REPOPROMPT_TLS_KEY_FILE"].flatMap { $0.isEmpty ? nil : $0 }
        if (tlsCert == nil) != (tlsKey == nil) {
            throw ConfigurationError.invalid("TLS certificate and key files must be configured together")
        }
        let clientCAPath = environment["REPOPROMPT_TLS_CLIENT_CA_FILE"].flatMap { $0.isEmpty ? nil : $0 }
        let operatorCertIdentity = environment["REPOPROMPT_OPERATOR_CERT_IDENTITY"].flatMap { $0.isEmpty ? nil : $0 }
        if (clientCAPath == nil) != (operatorCertIdentity == nil) {
            throw ConfigurationError.invalid("TLS client CA and operator certificate identity must be configured together")
        }
        let bindHost = environment["REPOPROMPT_BIND_HOST"] ?? "0.0.0.0"
        let bindPort = Int(environment["REPOPROMPT_BIND_PORT"] ?? "9443") ?? 9443
        let portalHost = environment["REPOPROMPT_PORTAL_HOST"] ?? bindHost
        let portalPort: Int?
        if let raw = environment["REPOPROMPT_PORTAL_PORT"] {
            if raw.isEmpty || raw == "off" {
                portalPort = nil
            } else {
                portalPort = Int(raw) ?? 9081
            }
        } else if clientCAPath != nil {
            portalPort = 9081
        } else {
            portalPort = nil
        }
        return Self(
            profileIdentifier: environment["REPOPROMPT_PROFILE"] ?? "default",
            stateDatabasePath: stateDatabase,
            worktreeDirectory: environment["REPOPROMPT_WORKTREE_DIR"] ?? "/srv/repoprompt/worktrees",
            artifactDirectory: environment["REPOPROMPT_ARTIFACT_DIR"] ?? "/var/lib/repoprompt/artifacts",
            projectDirectory: environment["REPOPROMPT_PROJECT_DIR"] ?? "/srv/repoprompt/projects",
            cacheDirectory: environment["REPOPROMPT_CACHE_DIR"] ?? "/var/cache/repoprompt",
            providerHomeDirectory: environment["REPOPROMPT_PROVIDER_HOME_DIR"] ?? URL(fileURLWithPath: stateDatabase).deletingLastPathComponent().appendingPathComponent("provider-homes").path,
            bindHost: bindHost, bindPort: bindPort,
            healthHost: "127.0.0.1", healthPort: Int(environment["REPOPROMPT_HEALTH_PORT"] ?? "9080") ?? 9080,
            portalHost: portalHost,
            portalPort: portalPort,
            certificatePath: tlsCert ?? trustDirectory.appendingPathComponent("server.crt").path,
            privateKeyPath: tlsKey ?? trustDirectory.appendingPathComponent("server.key").path,
            clientCAPath: clientCAPath,
            operatorCertIdentity: operatorCertIdentity,
            signingKeys: signingKeys, eventSigningKey: event,
            providerExecutables: providers,
            enabledProviders: enabledProviders,
            enabledDirectProviders: enabledDirectProviders,
            providerVersions: versions,
            providerProtocols: protocols,
            providerCredentialSources: credentialSources,
            providerAuthenticationStatusFiles: authenticationStatusFiles,
            providerModelCatalogFiles: modelCatalogFiles,
            providerVaultKey: vaultKey,
            providerVaultDecryptionKeys: previousVaultKeys,
            providerVaultFilePath: vaultFilePath,
            minimumFreeBytes: Int64(environment["REPOPROMPT_MINIMUM_FREE_BYTES"] ?? "268435456") ?? 268_435_456,
            minimumFreeNodes: Int64(environment["REPOPROMPT_MINIMUM_FREE_NODES"] ?? "1024") ?? 1024,
            maximumActiveSessions: Int(environment["REPOPROMPT_MAX_ACTIVE_SESSIONS"] ?? "64") ?? 64,
            restoreActivationTokenPath: environment["REPOPROMPT_RESTORE_ACTIVATION_TOKEN_FILE"],
            projectSourcePolicy: projectSourcePolicy,
            projectSourceGitCredentials: projectSourceGitCredentials
        )
    }
}

public enum ConfigurationError: Error, CustomStringConvertible { case missing(String)
    case invalid(String)
    public var description: String {
        switch self {
        case let .missing(name): "Required configuration \(name) is missing"
        case let .invalid(message): message
        }
    }
}

private func operatorOnboardingBanner(
    bindHost: String,
    bindPort: Int,
    portalHost: String,
    portalPort: Int?,
    usesMutualTLS: Bool,
    needsSetup: Bool,
    setupToken: String?
) -> String {
    let httpsHost = bindHost == "0.0.0.0" || bindHost == "::" ? "127.0.0.1" : bindHost
    let httpHost = portalHost == "0.0.0.0" || portalHost == "::" ? "127.0.0.1" : portalHost
    var lines = [
        "",
        "RepoPrompt Server is ready."
    ]
    if let portalPort {
        lines.append("Open http://\(httpHost):\(portalPort)/portal/")
    } else if !usesMutualTLS {
        lines.append("Open https://\(httpsHost):\(bindPort)/portal/")
    } else {
        lines.append("Open /portal/ and create or enter the operator password.")
    }
    if needsSetup, let setupToken {
        lines.append("Create the operator password on first visit.")
        lines.append("Setup token (required unless you are on this machine): \(setupToken)")
    } else {
        lines.append("Sign in with the operator password.")
    }
    lines.append("")
    return lines.joined(separator: "\n")
}

private func randomHMACSecret() -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    var generator = SystemRandomNumberGenerator()
    for index in bytes.indices {
        bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
    }
    return Data(bytes)
}

public enum RepoPromptServerRunner {
    /// Shared by the executable composition root and authenticated HTTP contract tests.
    /// Keeping this seam here prevents tests from silently assembling a different catalog authority.
    public static func composeAgentCatalog(
        providerSettings: ProviderSettingsService,
        store: SQLiteServiceStore,
        workflows: [AgentComposerWorkflowDescriptor],
        suggestions: [ComposerSuggestionDescriptor],
        emptyState: AgentEmptyStateDescriptor,
        providerProfileLoader: (@Sendable (ProviderSettingsID) async throws -> AgentCatalogProviderProfile)? = nil,
        composeModelLoader: (@Sendable () async throws -> String?)? = nil
    ) -> any AgentComposerCatalogProviding {
        AgentComposerCatalogService(
            providerSettings: providerSettings,
            store: store,
            workflows: workflows,
            suggestions: suggestions,
            emptyState: emptyState,
            providerProfileLoader: providerProfileLoader,
            composeModelLoader: composeModelLoader
        )
    }

    public static func run(configuration: RepoPromptServerConfiguration) async throws {
        let stateDirectory = URL(fileURLWithPath: configuration.stateDatabasePath).deletingLastPathComponent().path
        for directory in [
            stateDirectory,
            configuration.worktreeDirectory,
            configuration.artifactDirectory,
            configuration.projectDirectory,
            configuration.cacheDirectory,
            configuration.providerHomeDirectory
        ] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        // Parse all trust material before any listener can report ready.
        let certificateRoles: CertificateIdentityRoleResolver?
        let tls: TLSConfiguration
        if configuration.usesMutualTLS, let clientCAPath = configuration.clientCAPath {
            certificateRoles = try CertificateIdentityRoleResolver.environment()
            tls = try RepoPromptTLSConfiguration.mutualTLS13(
                certificatePath: configuration.certificatePath,
                privateKeyPath: configuration.privateKeyPath,
                trustRootsPath: clientCAPath
            )
        } else {
            try LocalServerTLSMaterial.ensure(
                certificatePath: configuration.certificatePath,
                privateKeyPath: configuration.privateKeyPath
            )
            certificateRoles = nil
            tls = try RepoPromptTLSConfiguration.serverTLS13(
                certificatePath: configuration.certificatePath,
                privateKeyPath: configuration.privateKeyPath
            )
        }
        let namespace = try AuthorityNamespaceDescriptor(
            storageRoot: stateDirectory,
            databasePath: configuration.stateDatabasePath,
            profile: configuration.profileIdentifier,
            servingMode: .server
        )
        let runtime = try await RepoPromptAuthorityHostFactory.startServer(
            configuration: .init(
                host: .init(
                    namespace: namespace,
                    eventSigningKeyID: configuration.eventSigningKey.keyID,
                    eventSigningSecret: configuration.eventSigningKey.secret
                ),
                worktreeDirectory: configuration.worktreeDirectory,
                artifactDirectory: configuration.artifactDirectory,
                projectDirectory: configuration.projectDirectory,
                providerHomeDirectory: configuration.providerHomeDirectory,
                providerExecutables: configuration.providerExecutables,
                enabledProviders: configuration.enabledProviders,
                enabledDirectProviders: configuration.enabledDirectProviders,
                providerVersions: configuration.providerVersions,
                providerProtocols: configuration.providerProtocols,
                providerCredentialSources: configuration.providerCredentialSources,
                providerAuthenticationStatusFiles: configuration.providerAuthenticationStatusFiles,
                providerModelCatalogFiles: configuration.providerModelCatalogFiles,
                providerVaultKey: configuration.providerVaultKey,
                providerVaultDecryptionKeys: configuration.providerVaultDecryptionKeys,
                providerVaultFilePath: configuration.providerVaultFilePath,
                restoreActivationTokenPath: configuration.restoreActivationTokenPath,
                projectSourcePolicy: configuration.projectSourcePolicy,
                projectSourceGitCredentials: configuration.projectSourceGitCredentials
            )
        )
        let host = runtime.host
        let store = runtime.store
        let authority = runtime.authority
        let durabilityOperations = runtime.durabilityOperations
        let providerSettings = runtime.providerSettings
        let serverSettings = runtime.serverSettings
        let portalDesktopSettings = runtime.portalDesktopSettings
        var hostWasShutdown = false
        do {
        let composerWorkflows: [AgentComposerWorkflowDescriptor] = []
        let composerSuggestions: [ComposerSuggestionDescriptor] = [
            .init(kind: .nativeCommand, id: "compact", insertionText: "/compact", displayName: "Compact context", detailText: "Ask Codex to compact the current context.", providerIDs: [.codex], expansion: "/compact")
        ]
        let composerCatalog = composeAgentCatalog(
            providerSettings: providerSettings,
            store: store,
            workflows: composerWorkflows,
            suggestions: composerSuggestions,
            emptyState: .init(featuredWorkflowIDs: [], tips: ["Tag a file to add its current contents to only this turn.", "Choose a concrete model before sending.", "Use Shift+Return to add a new line."]),
            providerProfileLoader: { providerID in
                try await portalDesktopSettings.composerCatalogProfile(for: providerID)
            },
            composeModelLoader: {
                try await serverSettings.agentModels().effectiveProfile.resolvedComposeModelRaw()
            }
        )
        let composerAttachments = try AgentComposerAttachmentStore(
            store: store,
            configuration: .init(acceptedRoot: URL(fileURLWithPath: stateDirectory, isDirectory: true).appendingPathComponent("agent-attachments/accepted", isDirectory: true).path)
        )
        try await composerAttachments.recover()
        let turnCompiler = AgentTurnIntentCompiler(taggedFiles: AuthorityAgentTurnTaggedFileResolver(authority: authority), suggestions: StaticAgentTurnSuggestionResolver(descriptors: composerSuggestions))
        let submissionCoordinator = AgentSubmissionCoordinator(store: store, catalog: composerCatalog, compiler: turnCompiler, attachments: composerAttachments)
        let transcriptPresentation = AgentTranscriptPresentationService(store: store)
        for pending in try await submissionCoordinator.recover() {
            do {
                let accepted = try await submissionCoordinator.acceptedForRecovery(pending)
                let actor = ExternalActor(userID: pending.actorID, username: "recovered-submission", displayName: "Recovered submission")
                try await authority.dispatchAcceptedFollowup(accepted, actor: actor, requestDigest: pending.requestDigest)
                try await submissionCoordinator.markDispatched(submissionID: pending.submissionID)
            } catch {
                try? await submissionCoordinator.markLaunchFailed(submissionID: pending.submissionID, message: "Accepted provider dispatch recovery failed")
            }
        }

        let mutationGate = host.mutationGate
        let authenticator = InternalRequestAuthenticator(keys: configuration.signingKeys, store: store)
        let readiness = RepoPromptReadinessService(
            authority: authority,
            store: store,
            volumes: [
                .init(name: "state", path: stateDirectory),
                .init(name: "artifacts", path: configuration.artifactDirectory),
                .init(name: "projects", path: configuration.projectDirectory),
                .init(name: "worktrees", path: configuration.worktreeDirectory),
                .init(name: "cache", path: configuration.cacheDirectory)
            ],
            requiredProviders: configuration.enabledProviders,
            expectedProviderProtocols: configuration.providerProtocols,
            minimumFreeBytes: configuration.minimumFreeBytes,
            minimumFreeNodes: configuration.minimumFreeNodes,
            maximumActiveSessions: configuration.maximumActiveSessions,
            mutationGate: mutationGate,
            trustConfigurationValid: true,
            providerSettings: providerSettings,
            eventOutboxDispatcher: runtime.eventOutboxDispatcher
        )
        let service = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: authenticator,
            eventSigningKey: configuration.eventSigningKey,
            certificateRoleResolver: certificateRoles,
            readiness: readiness,
            durabilityOperations: durabilityOperations,
            providerSettings: providerSettings,
            serverSettings: serverSettings,
            composerCatalog: composerCatalog,
            composerAttachments: composerAttachments,
            submissionCoordinator: submissionCoordinator,
            transcriptPresentation: transcriptPresentation,
            portalDesktopSettings: portalDesktopSettings,
            portalPasswordLoginEnabled: true,
            mutationGate: mutationGate
        )
        let internalApplication = try Application(
            router: service.internalRouter(),
            server: .tls(tlsConfiguration: tls),
            configuration: .init(
                address: .hostname(configuration.bindHost, port: configuration.bindPort),
                serverName: "RepoPromptServer"
            )
        )
        let healthApplication = Application(
            router: service.healthRouter(),
            configuration: .init(
                address: .hostname(configuration.healthHost, port: configuration.healthPort),
                serverName: nil
            )
        )
        let needsSetup = try await store.hasOperatorAccount() == false
        let setupToken = needsSetup ? try await store.issueOperatorSetupToken() : nil
        FileHandle.standardError.write(Data(operatorOnboardingBanner(
            bindHost: configuration.bindHost,
            bindPort: configuration.bindPort,
            portalHost: configuration.portalHost,
            portalPort: configuration.portalPort,
            usesMutualTLS: configuration.usesMutualTLS,
            needsSetup: needsSetup,
            setupToken: setupToken
        ).utf8))
        let mcpServing = try await host.makeMCPService(
            portalSettings: portalDesktopSettings
        )
        let mcpAdapter = RepoPromptMCPAdapter(serving: mcpServing)
        let mcpSocketURL = URL(
            fileURLWithPath: CodexRepoPromptMCPConfig.socketPath(),
            isDirectory: false
        )
        let mcpSocketServer = HeadlessMCPSocketServer(socketURL: mcpSocketURL, adapter: mcpAdapter)
        if FileManager.default.fileExists(atPath: mcpSocketURL.deletingLastPathComponent().path) {
            do {
                try await mcpSocketServer.start()
            } catch {
                throw error
            }
        }

        var serviceError: Error?
        let transportDrain = ServerTransportDrainCoordinator()
        var transportTasks: [Task<Void, Never>] = []
        transportTasks.append(await transportDrain.start {
            try await internalApplication.runService()
        })
        transportTasks.append(await transportDrain.start {
            try await healthApplication.runService()
        })
        if let portalPort = configuration.portalPort {
            let portalApplication = Application(
                router: service.internalRouter(),
                configuration: .init(
                    address: .hostname(configuration.portalHost, port: portalPort),
                    serverName: "RepoPromptServer"
                )
            )
            transportTasks.append(await transportDrain.start {
                try await portalApplication.runService()
            })
        }
        if case let .failed(message) = await transportDrain.waitForFirstCompletion() {
            serviceError = ServerTransportFailure(message: message)
        }

        let budget = AuthorityHostShutdownBudget(total: .seconds(30))
        // Close mutation and subscription admission before listener cancellation so
        // a still-accepting transport cannot establish new authority work in the gap.
        _ = await host.beginShutdown(using: budget)
        transportTasks.forEach { $0.cancel() }
        let childShutdown = await mcpSocketServer.stop(
            clientDrainTimeout: budget.allowance(maximum: .seconds(5)),
            forceCloseReapTimeout: budget.allowance(maximum: .seconds(1))
        )
        let transportsSettled = await transportDrain.waitForAll(
            timeout: budget.allowance(maximum: .seconds(5))
        )

        let shutdown = await host.shutdown(
            reason: serviceError == nil ? "listener-stopped" : "listener-failed",
            using: budget,
            childDrainTimedOut: !childShutdown.clean,
            childWorkUnsettled: childShutdown.unreapedClientCount > 0,
            externalTransportDrainTimedOut: !transportsSettled
        )
        hostWasShutdown = true
        if !shutdown.clean, serviceError == nil {
            serviceError = ServiceAPIError(code: .dependencyUnavailable, message: "Authority host shutdown exceeded its drain deadline")
        }
        if let serviceError { throw serviceError }
        } catch {
            if !hostWasShutdown {
                _ = await host.shutdown(reason: "startup-or-composition-failed")
            }
            throw error
        }
    }
}

struct ServerTransportFailure: Error, Sendable {
    let message: String
}

enum ServerTransportCompletion: Sendable, Equatable {
    case stopped
    case failed(String)
}

/// Tracks unstructured listener tasks so cancellation-ignoring services cannot
/// hold a structured task scope beyond the authority's one total deadline.
actor ServerTransportDrainCoordinator {
    private var activeTaskIDs: Set<UUID> = []
    private var firstCompletion: ServerTransportCompletion?
    private var firstCompletionWaiters: [CheckedContinuation<ServerTransportCompletion, Never>] = []

    func start(
        operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Never> {
        let taskID = UUID()
        activeTaskIDs.insert(taskID)
        return Task {
            let completion: ServerTransportCompletion
            do {
                try await operation()
                completion = .stopped
            } catch {
                completion = .failed(String(describing: error))
            }
            self.finish(taskID: taskID, completion: completion)
        }
    }

    func waitForFirstCompletion() async -> ServerTransportCompletion {
        if let firstCompletion { return firstCompletion }
        return await withCheckedContinuation { continuation in
            firstCompletionWaiters.append(continuation)
        }
    }

    func waitForAll(timeout: Duration) async -> Bool {
        if activeTaskIDs.isEmpty { return true }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(.zero, timeout))
        while !activeTaskIDs.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return activeTaskIDs.isEmpty
    }

    func activeTaskCount() -> Int { activeTaskIDs.count }

    private func finish(taskID: UUID, completion: ServerTransportCompletion) {
        activeTaskIDs.remove(taskID)
        guard firstCompletion == nil else { return }
        firstCompletion = completion
        let waiters = firstCompletionWaiters
        firstCompletionWaiters.removeAll()
        waiters.forEach { $0.resume(returning: completion) }
    }
}
