import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptRuntimeModel
import RepoPromptServerOperations
import RepoPromptServicePersistence
import RepoPromptWorkspaceRuntimeCore

public struct AuthorityServerRuntimeConfiguration: Sendable {
    public let host: AuthorityHostConfiguration
    public let worktreeDirectory: String
    public let artifactDirectory: String
    public let projectDirectory: String
    public let providerHomeDirectory: String
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
    public let restoreActivationTokenPath: String?
    public let projectSourcePolicy: ProjectSourcePolicy
    public let projectSourceGitCredentials: ProjectSourceGitCredentials

    public init(
        host: AuthorityHostConfiguration,
        worktreeDirectory: String,
        artifactDirectory: String,
        projectDirectory: String,
        providerHomeDirectory: String,
        providerExecutables: [ProviderKind: String],
        enabledProviders: Set<ProviderKind>,
        enabledDirectProviders: Set<ProviderSettingsID>,
        providerVersions: [ProviderKind: String],
        providerProtocols: [ProviderKind: String],
        providerCredentialSources: [ProviderKind: String],
        providerAuthenticationStatusFiles: [ProviderSettingsID: String],
        providerModelCatalogFiles: [ProviderSettingsID: String],
        providerVaultKey: ProviderVaultKey?,
        providerVaultDecryptionKeys: [ProviderVaultKey],
        providerVaultFilePath: String,
        restoreActivationTokenPath: String?,
        projectSourcePolicy: ProjectSourcePolicy,
        projectSourceGitCredentials: ProjectSourceGitCredentials
    ) {
        self.host = host
        self.worktreeDirectory = worktreeDirectory
        self.artifactDirectory = artifactDirectory
        self.projectDirectory = projectDirectory
        self.providerHomeDirectory = providerHomeDirectory
        self.providerExecutables = providerExecutables
        self.enabledProviders = enabledProviders
        self.enabledDirectProviders = enabledDirectProviders
        self.providerVersions = providerVersions
        self.providerProtocols = providerProtocols
        self.providerCredentialSources = providerCredentialSources
        self.providerAuthenticationStatusFiles = providerAuthenticationStatusFiles
        self.providerModelCatalogFiles = providerModelCatalogFiles
        self.providerVaultKey = providerVaultKey
        self.providerVaultDecryptionKeys = providerVaultDecryptionKeys
        self.providerVaultFilePath = providerVaultFilePath
        self.restoreActivationTokenPath = restoreActivationTokenPath
        self.projectSourcePolicy = projectSourcePolicy
        self.projectSourceGitCredentials = projectSourceGitCredentials
    }
}

public struct AuthorityServerRuntime: Sendable {
    public let host: RepoPromptAuthorityHost
    public let store: SQLiteServiceStore
    public let authority: RepoPromptHeadlessAuthority
    public let durabilityOperations: DurabilityOperationsService
    public let providerSettings: ProviderSettingsService
    public let serverSettings: ServerSettingsService
    public let portalDesktopSettings: PortalDesktopSettingsService
}

private struct RestoreActivationRequest: Decodable {
    let schemaVersion: Int
    let acknowledged: Bool
    let restoredFromStoreID: UUID
    let backupSequence: Int64
    let backupCreatedAt: String
    let backupManifestSHA256: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, acknowledged, backupSequence, backupCreatedAt
        case restoredFromStoreID = "restoredFromStoreId"
        case backupManifestSHA256 = "backupManifestSha256"
    }
}

public extension RepoPromptAuthorityHostFactory {
    static func startServer(
        configuration: AuthorityServerRuntimeConfiguration
    ) async throws -> AuthorityServerRuntime {
        let host = try await start(configuration: configuration.host)
        do {
            let instanceID = host.instanceID
            let store = try await host.storeForRecovery()
            let stateDirectory = URL(fileURLWithPath: configuration.host.namespace.databasePath)
                .deletingLastPathComponent().path

            if let tokenPath = configuration.restoreActivationTokenPath {
                let token = try Data(contentsOf: URL(fileURLWithPath: tokenPath))
                guard token.count >= 32 else {
                    throw ServiceAPIError(
                        code: .invalidRequest,
                        message: "Restore activation token must contain at least 256 bits"
                    )
                }
                let requestURL = URL(fileURLWithPath: stateDirectory).appendingPathComponent("restore-request.json")
                var metadata = try await store.metadata()
                if metadata.activationState == "active", FileManager.default.fileExists(atPath: requestURL.path) {
                    let request = try JSONDecoder.serviceDecoder.decode(
                        RestoreActivationRequest.self,
                        from: Data(contentsOf: requestURL)
                    )
                    guard request.schemaVersion == 1,
                          request.acknowledged,
                          request.restoredFromStoreID == metadata.storeID,
                          request.backupSequence >= 0,
                          request.backupCreatedAt.utf8.count <= 128,
                          request.backupManifestSHA256.range(
                              of: "^[a-f0-9]{64}$",
                              options: .regularExpression
                          ) != nil
                    else {
                        throw ServiceAPIError(
                            code: .invalidRequest,
                            message: "Restore activation request is invalid or does not match this store"
                        )
                    }
                    _ = try await store.prepareRestoredStore(
                        from: request.restoredFromStoreID,
                        backupSequence: request.backupSequence,
                        digest: request.backupManifestSHA256,
                        activationToken: token
                    )
                    metadata = try await store.metadata()
                }
                if metadata.activationState == "restore_prepared" {
                    _ = try await store.activateRestoredStore(
                        activationToken: token,
                        instanceID: instanceID
                    )
                    if FileManager.default.fileExists(atPath: requestURL.path) {
                        try FileManager.default.removeItem(at: requestURL)
                    }
                } else if metadata.activationState != "active" {
                    throw ServiceAPIError(
                        code: .quiescing,
                        message: "Restored store requires activation fencing"
                    )
                }
            }
            guard try await store.metadata().activationState == "active" else {
                throw ServiceAPIError(
                    code: .quiescing,
                    message: "Restored store requires activation fencing"
                )
            }

            let worktrees = try WorktreeRuntimeService(
                baseDirectory: configuration.worktreeDirectory,
                resources: store,
                ownerInstanceID: instanceID
            )
            let artifacts = try ArtifactRuntimeService(
                baseDirectory: configuration.artifactDirectory,
                resources: store
            )
            let processOutput = URL(fileURLWithPath: stateDirectory)
                .appendingPathComponent("provider-output").path
            try FileManager.default.createDirectory(atPath: processOutput, withIntermediateDirectories: true)
            let projectSources = try ProjectSourceProvisioningService(
                cloneRoot: configuration.projectDirectory,
                policy: configuration.projectSourcePolicy,
                credentials: configuration.projectSourceGitCredentials,
                resources: store,
                git: LocalProjectSourceGitRunner()
            )
            let reconciler = try OwnedResourceReconciliationService(
                repository: store,
                artifactRoot: configuration.artifactDirectory,
                worktreeRoot: configuration.worktreeDirectory,
                providerHomeRoot: configuration.providerHomeDirectory,
                providerOutputRoot: processOutput,
                projectRoot: configuration.projectDirectory
            )
            _ = try await reconciler.reconcileStartup()
            let durabilityOperations = DurabilityOperationsService(store: store, reconciler: reconciler)
            _ = await durabilityOperations.runOnce()

            let processPort = try PortableProcessSupervisionPort()
            let providerConfigurations = configuration.providerExecutables.map { kind, executable in
                ProviderCLIConfiguration(
                    kind: kind,
                    executable: executable,
                    expectedVersion: configuration.providerVersions[kind],
                    protocolVersion: configuration.providerProtocols[kind],
                    credentialSourceDirectory: configuration.providerCredentialSources[kind]
                )
            }
            if FileManager.default.fileExists(atPath: configuration.providerVaultFilePath),
               configuration.providerVaultKey == nil
            {
                throw ServiceAPIError(
                    code: .persistenceUnavailable,
                    message: "Provider credential vault exists but no master key is configured",
                    retryable: false
                )
            }
            let providerVault = try configuration.providerVaultKey.map {
                try ProviderCredentialVault(
                    fileURL: URL(fileURLWithPath: configuration.providerVaultFilePath),
                    activeKey: $0,
                    decryptionKeys: configuration.providerVaultDecryptionKeys
                )
            }
            let managedCodexHome = try CodexManagedAuthHome(
                rootPath: URL(fileURLWithPath: stateDirectory, isDirectory: true)
                    .appendingPathComponent("provider-auth/codex", isDirectory: true).path
            )
            let codexAuthentication = CodexDeviceAuthDriver(
                executable: configuration.providerExecutables[.codex] ?? "",
                expectedVersion: configuration.providerVersions[.codex] ?? CodexCLIContract.pinnedVersion,
                managedHome: managedCodexHome,
                processPort: processPort,
                processStore: store,
                outputDirectory: processOutput
            )
            let portalDesktopSettings = PortalDesktopSettingsService(store: store)
            let directTransport = try ValidatedProviderEgressTransport()
            let directProviderRegistry = DirectProviderRegistry(
                store: store,
                transport: directTransport,
                deploymentAllowlist: configuration.enabledDirectProviders
            )
            try await directProviderRegistry.bootstrap()
            let directCredentialAccessor = VaultDirectProviderCredentialAccessor(
                store: store,
                vault: providerVault
            )
            let directRuntimes: [ProviderSettingsID: any AgentProviderRuntime] = Dictionary(
                uniqueKeysWithValues: configuration.enabledDirectProviders.map { providerID in
                    (
                        providerID,
                        DirectAPIProviderRuntime(
                            providerID: providerID,
                            registry: directProviderRegistry,
                            credentials: directCredentialAccessor,
                            transport: directTransport
                        ) as any AgentProviderRuntime
                    )
                }
            )
            let credentialEnvironment = VaultProviderProcessEnvironment(
                store: store,
                vault: providerVault,
                externallyProvisionedKinds: Set(configuration.providerCredentialSources.keys),
                credentialSourceDirectories: configuration.providerCredentialSources,
                managedCodexCredentialSource: managedCodexHome.credentialSourceDirectory,
                managedCodexRuntimeHome: managedCodexHome,
                backendSettings: portalDesktopSettings
            )
            let providers = ProviderCLIAdapter(
                configurations: providerConfigurations,
                enabledProviders: configuration.enabledProviders,
                exactRuntimes: directRuntimes,
                enabledExactProviders: configuration.enabledDirectProviders,
                processPort: processPort,
                processStore: store,
                outputDirectory: processOutput,
                ephemeralHomeRoot: configuration.providerHomeDirectory,
                credentialEnvironment: credentialEnvironment,
                credentialSource: credentialEnvironment
            )
            let credentialTester = CompositeProviderCredentialTester(
                cli: ProviderAuthenticationAdapter(
                    configurations: providerConfigurations,
                    backendSettings: portalDesktopSettings
                ),
                direct: DirectProviderCredentialTester(
                    registry: directProviderRegistry,
                    transport: directTransport
                )
            )
            let providerSettings = ProviderSettingsService(
                store: store,
                adapter: providers,
                configurations: providerConfigurations,
                initiallyEnabled: configuration.enabledProviders,
                authenticationStatusFiles: configuration.providerAuthenticationStatusFiles,
                modelCatalogFiles: configuration.providerModelCatalogFiles,
                authFlows: TransientProviderAuthFlowCoordinator(driver: codexAuthentication),
                managedAuthentication: codexAuthentication,
                vault: providerVault,
                credentialTester: credentialTester,
                directProviderRegistry: directProviderRegistry,
                directProviderAllowlist: configuration.enabledDirectProviders
            )
            await host.markRecoveringProviders()
            try await providers.recoverProcessFamilies()
            let activeProviderRunIDs = Set(try await store.activeProcessFamilies().map(\.runID))
            _ = await reconciler.reconcileProviderResourcesAfterProcessRecovery(
                activeRunIDs: activeProviderRunIDs
            )
            try await providerSettings.bootstrap()
            let serverSettings = ServerSettingsService(
                store: store,
                providerCatalog: providerSettings,
                projectCatalog: store
            )
            let authority = RepoPromptHeadlessAuthority(
                store: store,
                codeMapBuilder: ServerWorkspaceCodeMapBuilder(),
                worktreeService: worktrees,
                artifactService: artifacts,
                providerAdapter: providers,
                projectSourceService: projectSources,
                serverSettings: serverSettings,
                providerSettings: providerSettings,
                directProviderRegistry: directProviderRegistry,
                directProviderDefaults: portalDesktopSettings
            )
            await host.markRecoveringAuthority()
            try await authority.recover()
            await host.installRecoveredAuthority(
                authority,
                durabilityOperations: durabilityOperations
            )
            await durabilityOperations.start()
            return AuthorityServerRuntime(
                host: host,
                store: store,
                authority: authority,
                durabilityOperations: durabilityOperations,
                providerSettings: providerSettings,
                serverSettings: serverSettings,
                portalDesktopSettings: portalDesktopSettings
            )
        } catch {
            _ = await host.shutdown(reason: "server-recovery-failed")
            throw error
        }
    }
}
