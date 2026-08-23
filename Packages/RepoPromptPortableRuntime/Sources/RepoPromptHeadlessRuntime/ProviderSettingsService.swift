import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import RepoPromptWorkspaceRuntimeCore

public protocol ProviderAuthFlowCoordinating: Sendable {
    func start(
        providerID: ProviderSettingsID,
        kind: ProviderManagedAuthenticationFlowKind,
        ownerID: String
    ) async throws -> ProviderManagedAuthenticationTransaction
    func poll(flowID: UUID, ownerID: String) async throws -> ProviderManagedAuthenticationTransaction
    func cancel(flowID: UUID, ownerID: String) async throws
}

public struct UnavailableProviderAuthFlowCoordinator: ProviderAuthFlowCoordinating {
    public init() {}

    public func start(
        providerID _: ProviderSettingsID,
        kind _: ProviderManagedAuthenticationFlowKind,
        ownerID _: String
    ) async throws -> ProviderManagedAuthenticationTransaction {
        throw ServiceAPIError(code: .capabilityMissing, message: "A server-side provider authentication adapter is not installed")
    }

    public func poll(flowID _: UUID, ownerID _: String) async throws -> ProviderManagedAuthenticationTransaction {
        throw ServiceAPIError(code: .notFound, message: "Provider authentication transaction was not found")
    }

    public func cancel(flowID _: UUID, ownerID _: String) async throws {
        throw ServiceAPIError(code: .notFound, message: "Provider authentication transaction was not found")
    }
}

/// Portable provider/settings authority. It owns non-secret preferences and
/// runtime connection behavior; future Server protocol code owns wire projections.
public actor ProviderSettingsService {
    private struct AuthFlowContext {
        let attribution: ProviderMutationAttribution
        let providerID: ProviderSettingsID
        let expectedConnectionRevision: Int64
    }

    private struct BootstrapSelection: Equatable {
        let defaultModel: String?
        let reasoningEffort: String?
        let speedMode: String?
        let serviceTier: String?
    }

    private struct SanitizedAuthenticationDocument: Decodable {
        let authenticated: Bool
        let method: ProviderAuthenticationMethod?
        let expiresAt: Date?
    }

    private struct ExternalAuthenticationValidation {
        let valid: Bool
        let detail: String
    }

    private let store: any ProviderSettingsStore
    private let adapter: any ProviderRuntimeSettingsAdapting
    private let configurations: [ProviderKind: ProviderCLIConfiguration]
    private let initiallyEnabled: Set<ProviderKind>
    private let authenticationStatusFiles: [ProviderSettingsID: String]
    private let modelCatalogFiles: [ProviderSettingsID: String]
    private let authFlows: any ProviderAuthFlowCoordinating
    private let managedAuthentication: any ProviderManagedAuthenticationDriving
    private let vault: (any ProviderCredentialVaulting)?
    private let credentialTester: any ProviderCredentialTesting
    private let directProviderRegistry: (any DirectProviderSettingsProviding)?
    private let directProviderAllowlist: Set<ProviderSettingsID>
    private let runner: any WorkspaceCommandRunning
    private var preferences: [ProviderSettingsID: ProviderSettingsPreference] = [:]
    private var cliHealth: [ProviderSettingsID: ProviderCLIHealth] = [:]
    private var runtimePreflight: [ProviderSettingsID: Bool] = [:]
    private var supportedAuthenticationMethods: [ProviderSettingsID: Set<ProviderAuthenticationMethod>] = [:]
    private var modelCatalogs: [ProviderSettingsID: [ProviderModelCatalogEntry]] = [:]
    private var directConfigurations: [ProviderSettingsID: DirectProviderConfiguration] = [:]
    private var connections: [ProviderSettingsID: StoredProviderConnection] = [:]
    private var managedAuthFlowCapabilities: [ProviderSettingsID: [ProviderManagedAuthenticationFlowCapability]] = [:]
    private var managedAccountSummaries: [ProviderSettingsID: ProviderManagedAccountSummary] = [:]
    private var authFlowContexts: [UUID: AuthFlowContext] = [:]
    private var statusRefreshTasks: [ProviderSettingsID: Task<Void, Never>] = [:]
    private var statusRefreshedAt: [ProviderSettingsID: Date] = [:]
    private var connectedRecoveryStarted = false
    private let statusRefreshTTL: TimeInterval = 15

    public init(
        store: any ProviderSettingsStore,
        adapter: any ProviderRuntimeSettingsAdapting,
        configurations: [ProviderCLIConfiguration],
        initiallyEnabled: Set<ProviderKind>,
        authenticationStatusFiles: [ProviderSettingsID: String] = [:],
        modelCatalogFiles: [ProviderSettingsID: String] = [:],
        authFlows: any ProviderAuthFlowCoordinating = UnavailableProviderAuthFlowCoordinator(),
        managedAuthentication: any ProviderManagedAuthenticationDriving = UnavailableProviderManagedAuthenticationDriver(),
        vault: (any ProviderCredentialVaulting)? = nil,
        credentialTester: any ProviderCredentialTesting = UnavailableProviderCredentialTester(),
        directProviderRegistry: (any DirectProviderSettingsProviding)? = nil,
        directProviderAllowlist: Set<ProviderSettingsID> = [],
        runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner()
    ) {
        self.store = store
        self.adapter = adapter
        self.configurations = Dictionary(uniqueKeysWithValues: configurations.map { ($0.kind, $0) })
        self.initiallyEnabled = initiallyEnabled
        self.authenticationStatusFiles = authenticationStatusFiles
        self.modelCatalogFiles = modelCatalogFiles
        self.authFlows = authFlows
        self.managedAuthentication = managedAuthentication
        self.vault = vault
        self.credentialTester = credentialTester
        self.directProviderRegistry = directProviderRegistry
        self.directProviderAllowlist = Set(directProviderAllowlist.filter(\.isDirectAPI))
        self.runner = runner
    }

    public func bootstrap() async throws {
        modelCatalogs = try loadModelCatalogs()
        if let directProviderRegistry {
            for providerID in ProviderSettingsID.directAPIProviders {
                if let configuration = try? await directProviderRegistry.configuration(for: providerID) {
                    directConfigurations[providerID] = configuration
                }
            }
        }
        for persistedCatalog in try await store.providerModelCatalogs() {
            guard persistedCatalog.models.count <= 500,
                  Set(persistedCatalog.models.map(\.id)).count == persistedCatalog.models.count,
                  persistedCatalog.models.allSatisfy({ validCatalogEntry($0, providerID: persistedCatalog.providerID) })
            else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted provider model catalog is invalid", retryable: false) }
            modelCatalogs[persistedCatalog.providerID] = persistedCatalog.models
        }
        let persisted = try await store.providerSettings()
        preferences = Dictionary(uniqueKeysWithValues: persisted.map { ($0.providerID, $0) })
        for preference in persisted {
            guard preference.revision > 0, preference.revision < Int64.max else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider settings revision is invalid", retryable: false)
            }
            if let reconciled = try reconciledBootstrapPreference(preference) {
                let audit = ProviderConnectionAuditMutation(
                    operation: "bootstrapReconcileSettings",
                    attribution: Self.lifecycleAttribution,
                    authenticationMethod: nil,
                    result: "reconciled"
                )
                preferences[preference.providerID] = try await store.upsertProviderSettings(
                    reconciled,
                    expectedRevision: preference.revision,
                    audit: audit
                )
            }
        }
        connections = try await Dictionary(uniqueKeysWithValues: store.providerConnections().map { ($0.record.providerID, $0) })
        let credentialReferences = Dictionary(uniqueKeysWithValues: connections.compactMap { providerID, stored in
            stored.credentialReference.map { (providerID, $0) }
        })
        if !credentialReferences.isEmpty, vault == nil {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider connections reference an unavailable credential vault", retryable: false)
        }
        if let vault {
            try await vault.rotateToActiveKeyIfNeeded()
            try await vault.reconcile(references: credentialReferences)
        }
        for providerID in ProviderSettingsID.allCases {
            let validatorMethods = await credentialTester.supportedAuthenticationMethods(for: providerID)
            let runtimeEligible: Bool = if providerID.isDirectAPI {
                directProviderAllowlist.contains(providerID) && directProviderRegistry != nil
            } else if let runtimeKind = providerID.runtimeKind,
                      let configuration = configurations[runtimeKind],
                      initiallyEnabled.contains(runtimeKind),
                      FileManager.default.isExecutableFile(atPath: configuration.executable)
            {
                true
            } else {
                false
            }
            if runtimeEligible {
                let vaultMethods: Set<ProviderAuthenticationMethod> = [.apiKey, .enterpriseAccessToken, .authToken]
                var methods = Set(validatorMethods.filter { vault != nil || !vaultMethods.contains($0) })
                if let externalMethod = Self.externalAuthenticationMethod(for: providerID), externallyProvisioned(providerID) {
                    methods.insert(externalMethod)
                }
                supportedAuthenticationMethods[providerID] = methods
                if providerID.isDirectAPI { runtimePreflight[providerID] = true }
            } else {
                supportedAuthenticationMethods[providerID] = []
            }
            if providerID.ownsRuntimeAdmission,
               let runtimeKind = providerID.runtimeKind,
               let configuration = configurations[runtimeKind],
               let expectedVersion = configuration.expectedVersion,
               FileManager.default.isExecutableFile(atPath: configuration.executable)
            {
                // Server-packaged providers are resolved and version-verified
                // when the immutable image is built, matching Desktop's bundled
                // runtime authority. Make that authority available immediately;
                // live protocol preflights remain an asynchronous diagnostic.
                cliHealth[providerID] = ProviderCLIHealth(
                    installed: true,
                    healthy: true,
                    version: expectedVersion,
                    expectedVersion: expectedVersion
                )
                runtimePreflight[providerID] = true
            }
            if preferences[providerID] == nil {
                let selection = try bootstrapSelection(
                    providerID: providerID,
                    defaultModel: nil,
                    reasoningEffort: nil,
                    speedMode: nil,
                    serviceTier: nil
                )
                let initial = ProviderSettingsPreference(
                    providerID: providerID,
                    enabled: false,
                    defaultModel: selection.defaultModel,
                    reasoningEffort: selection.reasoningEffort,
                    speedMode: selection.speedMode,
                    serviceTier: selection.serviceTier,
                    revision: 1
                )
                preferences[providerID] = try await store.upsertProviderSettings(initial, expectedRevision: 0, audit: nil)
            }
            try await applyRuntimePreference(providerID)
        }
    }

    public func catalog(refreshCLI: Bool = false, refreshRuntime: Bool = false) async throws -> ProviderSettingsCatalogResponse {
        if let codex = connections[.codex],
           codex.record.authenticationMethod == .deviceCodeBeta,
           codex.record.testState == .unavailable
        {
            // Portal reads must be able to recover a managed login that an
            // earlier transient probe left degraded. The refresh remains
            // single-flight, TTL-bounded, and off the response path.
            requestProviderStatusRefresh(providerID: .codex)
        }
        if refreshCLI || refreshRuntime {
            for providerID in ProviderSettingsID.allCases where providerID.ownsRuntimeAdmission && !providerID.isDirectAPI {
                guard let kind = providerID.runtimeKind,
                      let configuration = configurations[kind]
                else { continue }
                if refreshCLI {
                    await refreshCLIHealth(providerID: providerID, kind: kind, configuration: configuration)
                    if providerID == .codex {
                        await refreshManagedAuthenticationCapabilities(providerID: providerID, forceRefresh: true)
                    }
                }
                if refreshRuntime {
                    await refreshRuntimePreflight(providerID: providerID, kind: kind)
                }
            }
        }
        let snapshots = try ProviderSettingsID.allCases.map { try snapshot(for: $0) }
        return ProviderSettingsCatalogResponse(providers: snapshots)
    }

    /// Composer reads are served from the durable settings/model projection. Runtime
    /// and authentication health are refreshed opportunistically so opening a chat
    /// never waits for CLI process startup or an external authentication probe.
    public func composerCatalog() async throws -> ProviderSettingsCatalogResponse {
        for providerID in ProviderSettingsID.allCases where providerID.ownsRuntimeAdmission && !providerID.isDirectAPI {
            guard preferences[providerID]?.enabled == true else { continue }
            requestProviderStatusRefresh(providerID: providerID)
        }
        return try ProviderSettingsCatalogResponse(providers: ProviderSettingsID.allCases.map { try snapshot(for: $0) })
    }

    public func update(
        providerID: ProviderSettingsID,
        request: UpdateProviderSettingsRequest,
        attribution: ProviderMutationAttribution? = nil,
        auditOperation: String = "updateSettings"
    ) async throws -> ProviderSettingsSnapshot {
        guard let current = preferences[providerID] else {
            throw ServiceAPIError(code: .notFound, message: "Provider settings are not initialized")
        }
        guard current.revision == request.expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Provider settings revision is stale", currentRevision: current.revision)
        }
        let definition = Self.definition(providerID)
        if request.enabled, providerID.runtimeKind == nil {
            throw ServiceAPIError(code: .capabilityMissing, message: "This provider has no portable server runtime")
        }
        if request.enabled, providerID.isDirectAPI, !directProviderAllowlist.contains(providerID) {
            throw ServiceAPIError(code: .capabilityMissing, message: "Deployment configuration does not allow this direct provider")
        }
        if request.enabled, !providerID.isDirectAPI, let kind = providerID.runtimeKind, !initiallyEnabled.contains(kind) {
            throw ServiceAPIError(code: .capabilityMissing, message: "Deployment configuration does not allow this provider")
        }
        try validateSelection(request, providerID: providerID, definition: definition)
        let next = try ProviderSettingsPreference(
            providerID: providerID,
            enabled: request.enabled,
            defaultModel: normalized(request.defaultModel),
            reasoningEffort: normalized(request.reasoningEffort),
            speedMode: normalized(request.speedMode),
            serviceTier: normalized(request.serviceTier),
            revision: current.revision + 1
        )
        let audit = attribution.map {
            ProviderConnectionAuditMutation(
                operation: auditOperation,
                attribution: $0,
                authenticationMethod: connections[providerID]?.record.authenticationMethod,
                result: auditOperation == "updateSettings" ? "updated" : (request.enabled ? "enabled" : "disabled")
            )
        }
        preferences[providerID] = try await store.upsertProviderSettings(next, expectedRevision: current.revision, audit: audit)
        try await applyRuntimePreference(providerID)
        return try snapshot(for: providerID)
    }

    public func directConfiguration(providerID: ProviderSettingsID) async throws -> DirectProviderConfiguration {
        guard let directProviderRegistry else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Direct provider configuration is unavailable")
        }
        return try await directProviderRegistry.configuration(for: providerID)
    }

    public func updateDirectConfiguration(
        providerID: ProviderSettingsID,
        request: UpdateDirectProviderConfigurationRequest,
        attribution: ProviderMutationAttribution
    ) async throws -> DirectProviderConfiguration {
        guard connections[providerID] == nil else {
            throw ServiceAPIError(code: .invalidRequest, message: "Disconnect the direct provider before changing its runtime configuration")
        }
        guard let directProviderRegistry else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Direct provider configuration is unavailable")
        }
        let updated = try await directProviderRegistry.update(providerID: providerID, request: request, attribution: attribution)
        directConfigurations[providerID] = updated
        return updated
    }

    public func setEnabled(
        providerID: ProviderSettingsID,
        enabled: Bool,
        request: SetProviderEnabledRequest,
        attribution: ProviderMutationAttribution
    ) async throws -> ProviderSettingsSnapshot {
        guard let current = preferences[providerID] else {
            throw ServiceAPIError(code: .notFound, message: "Provider settings are not initialized")
        }
        return try await update(
            providerID: providerID,
            request: .init(
                expectedRevision: request.expectedRevision,
                enabled: enabled,
                defaultModel: current.defaultModel,
                reasoningEffort: current.reasoningEffort,
                speedMode: current.speedMode,
                serviceTier: current.serviceTier
            ),
            attribution: attribution,
            auditOperation: enabled ? "enable" : "disable"
        )
    }

    public func startAuthFlow(
        providerID: ProviderSettingsID,
        kind: ProviderManagedAuthenticationFlowKind,
        attribution: ProviderMutationAttribution
    ) async throws -> ProviderManagedAuthenticationTransaction {
        await refreshManagedAuthenticationCapabilities(providerID: providerID, forceRefresh: true)
        let capability = managedAuthFlowCapabilities[providerID, default: []].first { $0.kind == kind }
        guard capability?.startable == true else {
            throw ServiceAPIError(code: .capabilityMissing, message: capability?.detail ?? "Provider authentication flow is unavailable")
        }
        let status = try await authFlows.start(providerID: providerID, kind: kind, ownerID: attribution.actorID)
        authFlowContexts[status.flowID] = AuthFlowContext(
            attribution: attribution,
            providerID: providerID,
            expectedConnectionRevision: connections[providerID]?.record.revision ?? 0
        )
        try await store.appendProviderConnectionAudit(
            providerID: providerID,
            connectionID: connections[providerID]?.record.connectionID,
            operation: "authFlowStart",
            attribution: attribution,
            authenticationMethod: .deviceCodeBeta,
            result: "started"
        )
        return status
    }

    public func startAuthFlow(
        providerID: ProviderSettingsID,
        request: ProviderManagedAuthenticationStartInput,
        attribution: ProviderMutationAttribution
    ) async throws -> ProviderManagedAuthenticationTransaction {
        try await startAuthFlow(
            providerID: providerID,
            kind: request.kind,
            attribution: attribution
        )
    }

    public func pollAuthFlow(flowID: UUID, ownerID: String) async throws -> ProviderManagedAuthenticationTransaction {
        let status = try await authFlows.poll(flowID: flowID, ownerID: ownerID)
        guard status.state != .pending else { return status }
        guard let context = authFlowContexts.removeValue(forKey: flowID) else { return status }
        if status.state == .completed {
            try await completeManagedAuthFlow(context)
        } else {
            try await store.appendProviderConnectionAudit(
                providerID: context.providerID,
                connectionID: connections[context.providerID]?.record.connectionID,
                operation: "authFlowFinish",
                attribution: context.attribution,
                authenticationMethod: .deviceCodeBeta,
                result: auditResult(for: status.state)
            )
        }
        return status
    }

    public func cancelAuthFlow(flowID: UUID, ownerID: String) async throws {
        try await authFlows.cancel(flowID: flowID, ownerID: ownerID)
        if let context = authFlowContexts.removeValue(forKey: flowID) {
            try await store.appendProviderConnectionAudit(
                providerID: context.providerID,
                connectionID: connections[context.providerID]?.record.connectionID,
                operation: "authFlowCancel",
                attribution: context.attribution,
                authenticationMethod: .deviceCodeBeta,
                result: "cancelled"
            )
        }
    }

    public func connect(providerID: ProviderSettingsID, input: ProviderConnectionInput, attribution: ProviderMutationAttribution) async throws -> ProviderSettingsSnapshot {
        let request = input
        guard supportedAuthenticationMethods[providerID, default: []].contains(request.authenticationMethod) else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Authentication method is not supported by this provider")
        }
        guard ![ProviderAuthenticationMethod.browserOAuth, .deviceCodeBeta].contains(request.authenticationMethod) else {
            throw ServiceAPIError(code: .capabilityMissing, message: "This authentication method must use a provider authentication flow")
        }
        if let expiresAt = request.expiresAt {
            guard expiresAt.timeIntervalSince1970.isFinite, expiresAt > Date() else {
                throw ServiceAPIError(code: .invalidRequest, message: "Provider credential expiration must be in the future")
            }
        }
        let old = connections[providerID]
        let connectionID = old?.record.connectionID ?? UUID()
        let expectedRevision = old?.record.revision ?? 0
        let createdAt = old?.record.createdAt ?? Date()
        let secret = try credentialMaterial(request, providerID: providerID)
        let accountLabel = try safeLabel(request.accountLabel)
        let normalizedCredential = secret.flatMap { String(data: $0, encoding: .utf8) }
        if let label = accountLabel, let normalizedCredential, label.contains(normalizedCredential) {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider account label must not contain credential material")
        }
        let needsVault = secret != nil
        if needsVault, vault == nil {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider credential vault is unavailable")
        }
        let external = !needsVault && [.browserLogin, .providerSpecific].contains(request.authenticationMethod)
        let externalValidation: ExternalAuthenticationValidation?
        if external {
            let validation = await validateExternalAuthentication(providerID)
            guard validation.valid else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: validation.detail)
            }
            externalValidation = validation
        } else {
            externalValidation = nil
        }
        let directValidation: ProviderCredentialTestResult?
        if providerID.isDirectAPI {
            let validation = await credentialTester.test(providerID: providerID, method: request.authenticationMethod, secret: secret)
            guard validation.state == .valid, let models = validation.models else {
                let code: ServiceErrorCode = validation.state == .invalid ? .invalidRequest : .dependencyUnavailable
                throw ServiceAPIError(code: code, message: validation.state == .invalid ? "Provider rejected the configured credential" : "Provider validation is temporarily unavailable", retryable: validation.state != .invalid)
            }
            try await persistDiscoveredCatalog(models, providerID: providerID)
            directValidation = validation
        } else {
            directValidation = nil
        }
        let credentialReference = secret.map { _ in UUID() }
        if let secret, let credentialReference {
            try await vault?.store(secret: secret, providerID: providerID, connectionID: credentialReference)
        }
        if old?.record.authenticationMethod == .deviceCodeBeta {
            do {
                try await managedAuthentication.logout(providerID: providerID)
            } catch {
                if let credentialReference { try? await vault?.delete(providerID: providerID, connectionID: credentialReference) }
                throw error
            }
        }
        let detail = directValidation.map { _ in "Provider credential and model catalog validated" }
            ?? externalValidation?.detail
            ?? "Credential stored; explicit validation is required"
        let initiallyValidated = external || directValidation != nil
        let initialTestState: ProviderCredentialTestState = initiallyValidated ? .valid : .notTested
        let initialState: ProviderConnectionState = initiallyValidated ? .connected : .attention
        let record = ProviderConnectionRecord(
            connectionID: connectionID,
            providerID: providerID,
            authenticationMethod: request.authenticationMethod,
            state: initialState,
            accountLabel: accountLabel,
            expiresAt: request.expiresAt,
            lastTestedAt: initiallyValidated ? Date() : nil,
            testState: initialTestState,
            detail: detail,
            keyHelperConfigured: false,
            workloadIdentityConfigured: false,
            createdAt: createdAt,
            updatedAt: Date(),
            revision: expectedRevision + 1
        )
        let stored = StoredProviderConnection(record: record, credentialReference: credentialReference)
        let audit = ProviderConnectionAuditMutation(
            operation: old == nil ? "connect" : "rotate",
            attribution: attribution,
            authenticationMethod: request.authenticationMethod,
            result: initiallyValidated ? "validated" : "stored"
        )
        do {
            connections[providerID] = try await store.upsertProviderConnection(stored, expectedRevision: expectedRevision, audit: audit)
        } catch {
            if let credentialReference {
                try? await vault?.delete(providerID: providerID, connectionID: credentialReference)
            }
            throw error
        }
        if let oldReference = old?.credentialReference, oldReference != credentialReference {
            // A crash or deletion failure leaves only an encrypted orphan;
            // bootstrap reconciliation removes it after SQLite is authoritative.
            try? await vault?.delete(providerID: providerID, connectionID: oldReference)
        }
        if initialState == .connected {
            requestProviderStatusRefresh(providerID: providerID, force: true)
        }
        return try snapshot(for: providerID)
    }

    public func connect(
        providerID: ProviderSettingsID,
        request: ProviderConnectionInput,
        attribution: ProviderMutationAttribution
    ) async throws -> ProviderSettingsSnapshot {
        try await connect(providerID: providerID, input: request, attribution: attribution)
    }

    public func testConnection(providerID: ProviderSettingsID, attribution: ProviderMutationAttribution) async throws -> ProviderSettingsSnapshot {
        guard let stored = connections[providerID] else {
            throw ServiceAPIError(code: .notFound, message: "Provider connection is not configured")
        }
        if stored.record.authenticationMethod == .deviceCodeBeta {
            try await reconcileManagedAuthentication(attribution: attribution)
            await refreshProviderStatus(providerID: providerID, force: true)
            return try snapshot(for: providerID)
        }
        if stored.credentialReference == nil,
           [.browserLogin, .providerSpecific].contains(stored.record.authenticationMethod)
        {
            let validation = await validateExternalAuthentication(providerID)
            let available = validation.valid
            let now = Date()
            let updated = ProviderConnectionRecord(
                connectionID: stored.record.connectionID,
                providerID: providerID,
                authenticationMethod: stored.record.authenticationMethod,
                state: available ? .connected : .attention,
                accountLabel: stored.record.accountLabel,
                expiresAt: stored.record.expiresAt,
                lastTestedAt: now,
                testState: available ? .valid : .invalid,
                detail: validation.detail,
                keyHelperConfigured: false,
                workloadIdentityConfigured: false,
                createdAt: stored.record.createdAt,
                updatedAt: now,
                revision: stored.record.revision + 1
            )
            connections[providerID] = try await store.upsertProviderConnection(
                .init(record: updated, credentialReference: nil),
                expectedRevision: stored.record.revision,
                audit: .init(
                    operation: "test",
                    attribution: attribution,
                    authenticationMethod: stored.record.authenticationMethod,
                    result: available ? ProviderCredentialTestState.valid.rawValue : ProviderCredentialTestState.invalid.rawValue
                )
            )
            await refreshProviderStatus(providerID: providerID, force: true)
            return try snapshot(for: providerID)
        }
        let secret: Data?
        if let reference = stored.credentialReference {
            guard let vault else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider credential vault is unavailable") }
            secret = try await vault.load(providerID: providerID, connectionID: reference)
        } else { secret = nil }
        let result = await credentialTester.test(providerID: providerID, method: stored.record.authenticationMethod, secret: secret)
        if result.state == .valid, providerID.isDirectAPI {
            guard let models = result.models else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider validation returned no model catalog")
            }
            try await persistDiscoveredCatalog(models, providerID: providerID)
        }
        let knownSecrets = secret.flatMap { String(data: $0, encoding: .utf8) }.map { [$0] } ?? []
        let detail = try safeDetail(ProviderSecretRedaction.redact(result.detail, knownSecrets: knownSecrets))
        let returnedAccountLabel = try safeLabel(result.accountLabel)
        guard returnedAccountLabel.map({ label in knownSecrets.allSatisfy { !label.contains($0) } }) ?? true else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider validation returned unsafe metadata")
        }
        let accountLabel = returnedAccountLabel ?? stored.record.accountLabel
        let expiresAt = result.expiresAt ?? stored.record.expiresAt
        let expirationValid = expiresAt.map { $0.timeIntervalSince1970.isFinite && $0 > Date() } ?? true
        let testState: ProviderCredentialTestState = result.state == .valid && !expirationValid ? .invalid : result.state
        let state: ProviderConnectionState = testState == .valid ? .connected : .attention
        let updated = ProviderConnectionRecord(
            connectionID: stored.record.connectionID, providerID: providerID, authenticationMethod: stored.record.authenticationMethod,
            state: state, accountLabel: accountLabel, expiresAt: expiresAt,
            lastTestedAt: Date(), testState: testState, detail: expirationValid ? detail : "Provider credential has expired",
            keyHelperConfigured: stored.record.keyHelperConfigured, workloadIdentityConfigured: stored.record.workloadIdentityConfigured,
            createdAt: stored.record.createdAt, updatedAt: Date(), revision: stored.record.revision + 1
        )
        let next = StoredProviderConnection(record: updated, credentialReference: stored.credentialReference)
        connections[providerID] = try await store.upsertProviderConnection(
            next,
            expectedRevision: stored.record.revision,
            audit: .init(operation: "test", attribution: attribution, authenticationMethod: stored.record.authenticationMethod, result: testState.rawValue)
        )
        await refreshProviderStatus(providerID: providerID, force: true)
        return try snapshot(for: providerID)
    }

    public func disconnect(providerID: ProviderSettingsID, attribution: ProviderMutationAttribution, revoke: Bool = false) async throws -> ProviderSettingsSnapshot {
        guard let stored = connections[providerID] else { return try snapshot(for: providerID) }
        if stored.record.authenticationMethod == .deviceCodeBeta {
            try await managedAuthentication.logout(providerID: providerID)
        }
        try await store.deleteProviderConnection(
            providerID: providerID,
            expectedRevision: stored.record.revision,
            audit: .init(
                operation: revoke ? "revoke" : "disconnect",
                attribution: attribution,
                authenticationMethod: stored.record.authenticationMethod,
                result: "deleted"
            )
        )
        connections[providerID] = nil
        if let reference = stored.credentialReference {
            try? await vault?.delete(providerID: providerID, connectionID: reference)
        }
        await credentialTester.logout(providerID: providerID, method: stored.record.authenticationMethod)
        return try snapshot(for: providerID)
    }

    private func refreshManagedAuthenticationCapabilities(providerID: ProviderSettingsID, forceRefresh: Bool) async {
        if let descriptor = await managedAuthentication.authFlowDescriptor(providerID: providerID, forceRefresh: forceRefresh) {
            managedAuthFlowCapabilities[providerID] = [descriptor]
        } else {
            managedAuthFlowCapabilities[providerID] = []
        }
    }

    private func completeManagedAuthFlow(_ context: AuthFlowContext) async throws {
        let current = connections[context.providerID]
        guard (current?.record.revision ?? 0) == context.expectedConnectionRevision else {
            try? await managedAuthentication.logout(providerID: context.providerID)
            throw ServiceAPIError(code: .staleRevision, message: "Provider connection changed while authentication was in progress", currentRevision: current?.record.revision)
        }
        guard case let .authenticated(accountLabel) = await managedAuthentication.authenticationState(providerID: context.providerID) else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Codex did not retain the completed server authentication")
        }
        let label = try safeLabel(accountLabel)
        managedAccountSummaries[context.providerID] = await managedAuthentication.accountSummary(providerID: context.providerID)
        let now = Date()
        let record = ProviderConnectionRecord(
            connectionID: current?.record.connectionID ?? UUID(),
            providerID: context.providerID,
            authenticationMethod: .deviceCodeBeta,
            state: .connected,
            accountLabel: label,
            lastTestedAt: now,
            testState: .valid,
            detail: "ChatGPT account authenticated by the server",
            keyHelperConfigured: false,
            workloadIdentityConfigured: false,
            createdAt: current?.record.createdAt ?? now,
            updatedAt: now,
            revision: context.expectedConnectionRevision + 1
        )
        let stored = StoredProviderConnection(record: record, credentialReference: nil)
        connections[context.providerID] = try await store.upsertProviderConnection(
            stored,
            expectedRevision: context.expectedConnectionRevision,
            audit: .init(
                operation: "authFlowFinish",
                attribution: context.attribution,
                authenticationMethod: .deviceCodeBeta,
                result: "completed"
            )
        )
        if let oldReference = current?.credentialReference {
            try? await vault?.delete(providerID: context.providerID, connectionID: oldReference)
        }
        requestProviderStatusRefresh(providerID: context.providerID, force: true)
    }

    private func reconcileManagedAuthentication(attribution: ProviderMutationAttribution) async throws {
        let providerID = ProviderSettingsID.codex
        let state = await managedAuthentication.authenticationState(providerID: providerID)
        switch state {
        case .authenticated:
            managedAccountSummaries[providerID] = await managedAuthentication.accountSummary(providerID: providerID)
        case .notAuthenticated:
            managedAccountSummaries[providerID] = nil
        case .unavailable:
            break
        }
        let current = connections[providerID]
        if current == nil, case let .authenticated(accountLabel) = state {
            let now = Date()
            let record = try ProviderConnectionRecord(
                connectionID: UUID(),
                providerID: providerID,
                authenticationMethod: .deviceCodeBeta,
                state: .connected,
                accountLabel: safeLabel(accountLabel),
                lastTestedAt: now,
                testState: .valid,
                detail: "ChatGPT account authenticated by the server",
                keyHelperConfigured: false,
                workloadIdentityConfigured: false,
                createdAt: now,
                updatedAt: now,
                revision: 1
            )
            let stored = StoredProviderConnection(record: record, credentialReference: nil)
            connections[providerID] = try await store.upsertProviderConnection(
                stored,
                expectedRevision: 0,
                audit: .init(operation: "authReconcile", attribution: attribution, authenticationMethod: .deviceCodeBeta, result: "recovered")
            )
            return
        }
        guard let current, current.record.authenticationMethod == .deviceCodeBeta else { return }
        if case .unavailable = state,
           current.record.state == .connected,
           current.record.testState == .valid
        {
            // A transport, provider, or refresh outage is not evidence that
            // the durable server-managed login was revoked. Preserve the last
            // verified state; an explicit unauthenticated reply still
            // invalidates it through the branch below.
            return
        }
        let projection: (ProviderConnectionState, ProviderCredentialTestState, String?, String?) = switch state {
        case let .authenticated(accountLabel):
            try (.connected, .valid, safeLabel(accountLabel) ?? current.record.accountLabel, "ChatGPT account authenticated by the server")
        case .notAuthenticated:
            (.attention, .invalid, current.record.accountLabel, "ChatGPT authentication is no longer present on the server")
        case .unavailable:
            (.attention, .unavailable, current.record.accountLabel, "Codex authentication status is temporarily unavailable")
        }
        guard current.record.state != projection.0
            || current.record.testState != projection.1
            || current.record.accountLabel != projection.2
            || current.record.detail != projection.3
        else { return }
        let now = Date()
        let updated = ProviderConnectionRecord(
            connectionID: current.record.connectionID,
            providerID: providerID,
            authenticationMethod: .deviceCodeBeta,
            state: projection.0,
            accountLabel: projection.2,
            expiresAt: current.record.expiresAt,
            lastTestedAt: now,
            testState: projection.1,
            detail: projection.3,
            keyHelperConfigured: false,
            workloadIdentityConfigured: false,
            createdAt: current.record.createdAt,
            updatedAt: now,
            revision: current.record.revision + 1
        )
        connections[providerID] = try await store.upsertProviderConnection(
            .init(record: updated, credentialReference: nil),
            expectedRevision: current.record.revision,
            audit: .init(operation: "authReconcile", attribution: attribution, authenticationMethod: .deviceCodeBeta, result: projection.1.rawValue)
        )
    }

    private static let lifecycleAttribution = ProviderMutationAttribution(
        actorID: "repoprompt-server",
        actorLabel: "RepoPrompt Server",
        channel: "provider-lifecycle"
    )

    private func credentialMaterial(_ request: ProviderConnectionInput, providerID: ProviderSettingsID) throws -> Data? {
        switch request.authenticationMethod {
        case .apiKey, .enterpriseAccessToken, .authToken:
            guard let credential = request.credential,
                  let rawValue = String(data: credential, encoding: .utf8)
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "A valid write-only credential is required")
            }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count >= 8,
                  value.utf8.count <= 65536,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "A valid write-only credential is required")
            }
            return Data(value.utf8)
        case .keyHelper, .workloadIdentityFederation:
            throw ServiceAPIError(code: .capabilityMissing, message: "This authentication method is not runtime-wired")
        case .providerSpecific:
            guard [.claudeCompatible, .openCodeACP, .grokBuildACP].contains(providerID), request.credential == nil else {
                throw ServiceAPIError(code: .invalidRequest, message: "CLI provider credentials are not proxied through the portal")
            }
            return nil
        case .browserLogin:
            guard providerID == .cursorACP, request.credential == nil else {
                throw ServiceAPIError(code: .invalidRequest, message: "Cursor browser credentials must be provisioned outside the portal")
            }
            return nil
        case .browserOAuth, .deviceCodeBeta:
            throw ServiceAPIError(code: .capabilityMissing, message: "Authentication method must use a transient provider flow")
        }
    }

    private func persistDiscoveredCatalog(_ models: [ProviderModelCatalogEntry], providerID: ProviderSettingsID) async throws {
        guard providerID.isDirectAPI || providerID == .codex,
              !models.isEmpty,
              models.count <= 500,
              Set(models.map(\.id)).count == models.count,
              models.allSatisfy({ validCatalogEntry($0, providerID: providerID) })
        else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider validation returned an unsafe model catalog") }
        guard modelCatalogs[providerID] != models else { return }
        let currentRevision = try await store.providerModelCatalog(providerID: providerID)?.revision ?? 0
        let persisted = try await store.replaceProviderModelCatalog(
            providerID: providerID,
            models: models,
            expectedRevision: currentRevision
        )
        modelCatalogs[providerID] = persisted.models
    }

    private func safeLabel(_ value: String?) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(value)
        else { throw ServiceAPIError(code: .invalidRequest, message: "Provider metadata is invalid or resembles credential material") }
        return value
    }

    private func safeDetail(_ value: String?) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(value)
        else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider validation returned unsafe metadata") }
        return value
    }

    private nonisolated static func externalAuthenticationMethod(for providerID: ProviderSettingsID) -> ProviderAuthenticationMethod? {
        switch providerID {
        case .claudeCompatible, .openCodeACP, .grokBuildACP: .providerSpecific
        case .cursorACP: .browserLogin
        case .codex, .claudeGLM, .claudeKimi, .claudeCustom,
             .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            nil
        }
    }

    private func externallyProvisioned(_ providerID: ProviderSettingsID) -> Bool {
        guard ![ProviderSettingsID.claudeGLM, .claudeKimi, .claudeCustom].contains(providerID) else { return false }
        guard let kind = providerID.runtimeKind,
              let source = configurations[kind]?.credentialSourceDirectory
        else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func validateExternalAuthentication(_ providerID: ProviderSettingsID) async -> ExternalAuthenticationValidation {
        guard externallyProvisioned(providerID),
              let kind = providerID.runtimeKind,
              let configuration = configurations[kind],
              let source = configuration.credentialSourceDirectory
        else {
            return .init(valid: false, detail: "The dedicated CLI credential directory is unavailable")
        }

        if providerID == .claudeCompatible {
            do {
                var environment = try ProviderCLIProbeEnvironment.prepare(for: kind)
                environment["CLAUDE_CONFIG_DIR"] = source
                environment["ANTHROPIC_API_KEY"] = ""
                environment["ANTHROPIC_AUTH_TOKEN"] = ""
                environment["CLAUDE_CODE_OAUTH_TOKEN"] = ""
                let output = try await runner.run(
                    executable: configuration.executable,
                    arguments: ["auth", "status", "--json"],
                    workingDirectory: FileManager.default.currentDirectoryPath,
                    maximumBytes: 8192,
                    environment: environment
                )
                guard let data = output.data(using: .utf8),
                      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let loggedIn = payload["loggedIn"] as? Bool
                else {
                    return .init(valid: false, detail: "Claude Code could not report a valid authentication status")
                }
                return loggedIn
                    ? .init(valid: true, detail: "Claude Code account authorization verified")
                    : .init(valid: false, detail: "Claude Code is not authenticated; run 'claude login' in the dedicated server account")
            } catch {
                return .init(valid: false, detail: "Claude Code authentication status could not be verified")
            }
        }

        if providerID == .openCodeACP || providerID == .cursorACP || providerID == .grokBuildACP {
            let capability = await adapter.recoveryPreflight(kind: kind)
            let valid = capability.enabled && capability.reasonUnavailable == nil
            let name = switch providerID {
            case .openCodeACP: "OpenCode"
            case .cursorACP: "Cursor"
            case .grokBuildACP: "Grok Build"
            default: "ACP"
            }
            return .init(
                valid: valid,
                detail: valid
                    ? "\(name) ACP account preflight completed"
                    : "\(name) could not initialize ACP with the dedicated server account"
            )
        }

        return .init(valid: false, detail: "This provider does not support an external CLI connection")
    }

    private func applyRuntimePreference(_ providerID: ProviderSettingsID) async throws {
        let ownerID = providerID.runtimeSettingsOwner
        guard let preference = preferences[ownerID] else { return }
        let defaults = ProviderRuntimeDefaults(
            enabled: preference.enabled,
            model: preference.defaultModel,
            reasoningEffort: preference.reasoningEffort,
            speedMode: preference.speedMode,
            serviceTier: preference.serviceTier
        )
        if providerID.isDirectAPI {
            guard directProviderAllowlist.contains(providerID), directProviderRegistry != nil else { return }
            try await adapter.applyRuntimeDefaults(providerID: providerID, defaults: defaults)
            return
        }
        guard let kind = providerID.runtimeKind, configurations[kind] != nil else { return }
        let effectiveAdmission = initiallyEnabled.contains(kind) && preferences.values.contains {
            !$0.providerID.isDirectAPI && $0.providerID.runtimeKind == kind && $0.enabled
        }
        try await adapter.applyRuntimeDefaults(
            kind: kind,
            defaults: ProviderRuntimeDefaults(
                enabled: effectiveAdmission,
                model: preference.defaultModel,
                reasoningEffort: preference.reasoningEffort,
                speedMode: preference.speedMode,
                serviceTier: preference.serviceTier
            )
        )
    }

    public func startConnectedProviderRecovery() {
        guard !connectedRecoveryStarted else { return }
        connectedRecoveryStarted = true
        let connectedProviders = Set(connections.compactMap { providerID, stored -> ProviderSettingsID? in
            let isRecoverableManagedCodex = providerID == .codex
                && stored.record.authenticationMethod == .deviceCodeBeta
                && stored.record.testState == .unavailable
            guard stored.record.state == .connected || isRecoverableManagedCodex,
                  stored.record.expiresAt.map({ $0 > Date() }) ?? true
            else { return nil }
            return providerID.runtimeSettingsOwner
        })
        for providerID in connectedProviders {
            requestProviderStatusRefresh(providerID: providerID, force: true)
        }
    }

    private func requestProviderStatusRefresh(providerID: ProviderSettingsID, force: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            await refreshProviderStatus(providerID: providerID, force: force)
        }
    }

    private func refreshProviderStatus(providerID: ProviderSettingsID, force: Bool = false) async {
        let statusID = providerID.runtimeSettingsOwner
        guard statusID.runtimeKind != nil else { return }
        if let task = statusRefreshTasks[statusID] {
            await task.value
            return
        }
        if !force,
           let refreshedAt = statusRefreshedAt[statusID],
           Date().timeIntervalSince(refreshedAt) < statusRefreshTTL
        {
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await performProviderStatusRefresh(providerID: statusID, forceRuntimeProbe: force)
        }
        statusRefreshTasks[statusID] = task
        await task.value
        statusRefreshTasks[statusID] = nil
        statusRefreshedAt[statusID] = Date()
    }

    private func performProviderStatusRefresh(providerID: ProviderSettingsID, forceRuntimeProbe: Bool) async {
        guard let kind = providerID.runtimeKind,
              let configuration = configurations[kind]
        else { return }
        await refreshCLIHealth(providerID: providerID, kind: kind, configuration: configuration)
        if providerID == .codex {
            await refreshManagedAuthenticationCapabilities(providerID: providerID, forceRefresh: true)
            try? await reconcileManagedAuthentication(attribution: Self.lifecycleAttribution)
        }
        await refreshRuntimePreflight(providerID: providerID, kind: kind, force: forceRuntimeProbe)
        if providerID == .codex,
           (try? snapshot(for: providerID).preflight.ready) == true,
           let models = try? await managedAuthentication.discoverModelCatalog(providerID: providerID, forceRefresh: false)
        {
            try? await persistDiscoveredCatalog(models, providerID: providerID)
        }
    }

    private func refreshCLIHealth(providerID: ProviderSettingsID, kind: ProviderKind, configuration: ProviderCLIConfiguration) async {
        guard FileManager.default.isExecutableFile(atPath: configuration.executable) else {
            cliHealth[providerID] = ProviderCLIHealth(installed: false, healthy: false, expectedVersion: configuration.expectedVersion, detail: "Configured CLI is not executable")
            return
        }
        if let expectedVersion = configuration.expectedVersion {
            // `expectedVersion` is emitted by the packaged runtime authority.
            // The image build already executed and verified this exact binary;
            // do not put another CLI process between the composer and its cache.
            cliHealth[providerID] = ProviderCLIHealth(
                installed: true,
                healthy: true,
                version: expectedVersion,
                expectedVersion: expectedVersion
            )
            return
        }
        do {
            let environment = try ProviderCLIProbeEnvironment.prepare(for: kind)
            let output = try await runner.run(
                executable: configuration.executable,
                arguments: ["--version"],
                workingDirectory: FileManager.default.currentDirectoryPath,
                maximumBytes: 65536,
                environment: environment
            )
            let reported = Self.validCLIVersionOutput(output)
            let matches = reported != nil
            cliHealth[providerID] = ProviderCLIHealth(
                installed: true,
                healthy: matches,
                version: matches ? reported : nil,
                detail: reported == nil ? "CLI returned invalid version output" : nil
            )
        } catch {
            cliHealth[providerID] = ProviderCLIHealth(installed: true, healthy: false, detail: "CLI version probe failed")
        }
    }

    private func refreshRuntimePreflight(providerID: ProviderSettingsID, kind: ProviderKind, force: Bool = false) async {
        let capability = if force {
            await adapter.recoveryPreflight(kind: kind)
        } else {
            await adapter.preflight(kind: kind)
        }
        runtimePreflight[providerID] = capability.enabled && capability.reasonUnavailable == nil
    }

    private func resolvedModels(for providerID: ProviderSettingsID) -> [ProviderModelCatalogEntry] {
        let discovered = modelCatalogs[providerID] ?? []
        return directConfigurations[providerID]?.resolvedCatalog(discovered: discovered) ?? discovered
    }

    private func snapshot(for providerID: ProviderSettingsID) throws -> ProviderSettingsSnapshot {
        guard let preference = preferences[providerID] else {
            throw ServiceAPIError(code: .notFound, message: "Provider settings are not initialized")
        }
        let definition = Self.definition(providerID)
        let runtimeSettingsID = providerID.runtimeSettingsOwner
        let deploymentAllowed = providerID.isDirectAPI
            ? directProviderAllowlist.contains(providerID)
            : (providerID.runtimeKind.map(initiallyEnabled.contains) ?? false)
        let preflightVerified = runtimePreflight[runtimeSettingsID] ?? false
        let models = resolvedModels(for: providerID)
        let connection = connections[providerID]?.record
        let preflight = preflightStatus(
            providerID: providerID,
            preference: preference,
            deploymentAllowed: deploymentAllowed,
            runtimeVerified: preflightVerified,
            connection: connection,
            cli: cliHealth[runtimeSettingsID]
        )
        return ProviderSettingsSnapshot(
            providerID: providerID,
            displayName: definition.displayName,
            category: definition.category,
            summary: definition.summary,
            deploymentAllowed: deploymentAllowed,
            runtimePreflightVerified: preflightVerified,
            effectiveEnabled: preference.enabled && preflight.ready,
            preference: preference,
            cli: providerID.isDirectAPI || providerID.runtimeKind == nil
                ? nil
                : cliHealth[runtimeSettingsID] ?? ProviderCLIHealth(installed: false, healthy: false, detail: "CLI health has not been checked"),
            authentication: authenticationStatus(providerID),
            configurationPresent: configurationPresent(providerID),
            connection: connection,
            preflight: preflight,
            capabilities: projectedCapabilities(
                definition.capabilities,
                providerID: providerID,
                deploymentAllowed: deploymentAllowed
            ),
            models: models
        )
    }

    private func authenticationStatus(_ providerID: ProviderSettingsID) -> ProviderAuthenticationStatus {
        if let connection = connections[providerID]?.record {
            let expired = connection.expiresAt.map { $0 <= Date() } ?? false
            let summary = managedAccountSummaries[providerID]
            return ProviderAuthenticationStatus(
                state: connection.state == .connected && !expired ? .authenticated : .attention,
                authenticated: connection.state == .connected && !expired,
                method: connection.authenticationMethod,
                accountLabel: summary?.account ?? connection.accountLabel,
                planLabel: summary?.plan,
                authenticationLabel: summary?.authentication,
                expiresAt: connection.expiresAt,
                detail: expired ? "Provider credential has expired" : connection.detail
            )
        }
        if let path = authenticationStatusFiles[providerID],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let document = try? JSONDecoder.serviceDecoder.decode(SanitizedAuthenticationDocument.self, from: data)
        {
            return ProviderAuthenticationStatus(
                state: document.authenticated ? .authenticated : .attention,
                authenticated: document.authenticated,
                method: document.method,
                expiresAt: document.expiresAt,
                detail: document.authenticated ? "Authenticated" : "Authentication requires attention"
            )
        }
        if let kind = providerID.runtimeKind,
           providerID.ownsRuntimeAdmission,
           let source = configurations[kind]?.credentialSourceDirectory,
           FileManager.default.fileExists(atPath: source)
        {
            return ProviderAuthenticationStatus(
                state: .unknown,
                authenticated: false,
                detail: "Credential home is mounted; sanitized account status is unavailable"
            )
        }
        return ProviderAuthenticationStatus(
            state: .notConfigured,
            authenticated: false,
            detail: "Provision credentials on the server"
        )
    }

    private func configurationPresent(_ providerID: ProviderSettingsID) -> Bool {
        if connections[providerID] != nil { return true }
        if let path = authenticationStatusFiles[providerID],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           (try? JSONDecoder.serviceDecoder.decode(SanitizedAuthenticationDocument.self, from: data)) != nil
        {
            return true
        }
        guard let kind = providerID.runtimeKind,
              providerID.ownsRuntimeAdmission,
              let source = configurations[kind]?.credentialSourceDirectory
        else { return false }
        return FileManager.default.fileExists(atPath: source)
    }

    private func preflightStatus(providerID: ProviderSettingsID, preference: ProviderSettingsPreference, deploymentAllowed: Bool, runtimeVerified: Bool, connection: ProviderConnectionRecord?, cli: ProviderCLIHealth?) -> ProviderPreflightStatus {
        guard preference.enabled else { return .init(ready: false, reason: .disabled, detail: "Provider is administratively disabled") }
        guard deploymentAllowed else { return .init(ready: false, reason: .deploymentDisabled, detail: "Deployment configuration does not allow this provider runtime") }
        if !providerID.isDirectAPI, providerID.runtimeKind != nil, cli?.installed != true {
            return .init(ready: false, reason: .missingExecutable, detail: "Provider executable is missing")
        }
        guard runtimeVerified else { return .init(ready: false, reason: .runtimeUnavailable, detail: cli?.detail ?? "Provider runtime preflight failed") }
        if providerID.isDirectAPI, modelCatalogs[providerID]?.isEmpty != false {
            return .init(ready: false, reason: .runtimeUnavailable, detail: "Direct provider model catalog is unavailable")
        }
        if let connection,
           [.browserLogin, .providerSpecific].contains(connection.authenticationMethod),
           !externallyProvisioned(providerID)
        {
            return .init(ready: false, reason: .missingCredential, detail: "External provider credential source is unavailable")
        }
        if connection == nil {
            guard externallyProvisioned(providerID) else { return .init(ready: false, reason: .missingCredential, detail: "Provider credential is not configured") }
        }
        if connection?.expiresAt.map({ $0 <= Date() }) == true { return .init(ready: false, reason: .invalidCredential, detail: "Provider credential has expired") }
        // Server readiness: `connected && testState == valid`. This is not
        // Desktop's UserDefaults `ClaudeCodeCompatibleBackendConfigured.<id>`
        // latch. Do not replace this predicate with a fake configured flag.
        if connection?.testState == .invalid { return .init(ready: false, reason: .invalidCredential, detail: "Provider rejected the configured credential") }
        if let connection, connection.testState != .valid {
            return .init(ready: false, reason: .authenticationPending, detail: connection.detail ?? "Provider credential requires validation")
        }
        return .init(ready: true, reason: .ready, detail: "Provider is ready")
    }

    private func validateSelection(_ request: UpdateProviderSettingsRequest, providerID: ProviderSettingsID, definition: Definition) throws {
        let models = resolvedModels(for: providerID)
        let selectedModel: ProviderModelCatalogEntry?
        if let modelID = try normalized(request.defaultModel) {
            guard definition.capabilities.supportsModelSelection,
                  let model = models.first(where: { $0.id == modelID })
            else { throw ServiceAPIError(code: .invalidRequest, message: "Default model is not in the provider catalog") }
            selectedModel = model
        } else {
            selectedModel = nil
        }
        try validateOption(normalized(request.reasoningEffort), allowed: selectedModel?.reasoningEfforts ?? [], capability: definition.capabilities.supportsReasoningEffort, label: "reasoning effort")
        try validateOption(normalized(request.speedMode), allowed: selectedModel?.speedModes ?? [], capability: definition.capabilities.supportsSpeedMode, label: "speed mode")
        try validateOption(normalized(request.serviceTier), allowed: selectedModel?.serviceTiers ?? [], capability: definition.capabilities.supportsServiceTier, label: "service tier")
    }

    private func validateOption(_ value: String?, allowed: [String], capability: Bool, label: String) throws {
        guard let value else { return }
        guard capability, allowed.contains(value) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Selected \(label) is not supported by this model")
        }
    }

    /// Provider catalogs are account-scoped and can legitimately change while
    /// non-secret defaults remain persisted. Reconcile only that semantic drift
    /// during bootstrap; interactive settings mutations continue through the
    /// strict `validateSelection` path above.
    private func reconciledBootstrapPreference(_ preference: ProviderSettingsPreference) throws -> ProviderSettingsPreference? {
        let selection = try bootstrapSelection(
            providerID: preference.providerID,
            defaultModel: preference.defaultModel,
            reasoningEffort: preference.reasoningEffort,
            speedMode: preference.speedMode,
            serviceTier: preference.serviceTier
        )
        let current = BootstrapSelection(
            defaultModel: preference.defaultModel,
            reasoningEffort: preference.reasoningEffort,
            speedMode: preference.speedMode,
            serviceTier: preference.serviceTier
        )
        let request = UpdateProviderSettingsRequest(
            expectedRevision: preference.revision,
            enabled: preference.enabled,
            defaultModel: selection.defaultModel,
            reasoningEffort: selection.reasoningEffort,
            speedMode: selection.speedMode,
            serviceTier: selection.serviceTier
        )
        try validateSelection(request, providerID: preference.providerID, definition: Self.definition(preference.providerID))
        guard selection != current else { return nil }
        return ProviderSettingsPreference(
            providerID: preference.providerID,
            enabled: preference.enabled,
            defaultModel: selection.defaultModel,
            reasoningEffort: selection.reasoningEffort,
            speedMode: selection.speedMode,
            serviceTier: selection.serviceTier,
            revision: preference.revision + 1
        )
    }

    private func bootstrapSelection(
        providerID: ProviderSettingsID,
        defaultModel: String?,
        reasoningEffort: String?,
        speedMode: String?,
        serviceTier: String?
    ) throws -> BootstrapSelection {
        let definition = Self.definition(providerID)
        let normalizedModel = try normalized(defaultModel)
        let normalizedReasoning = try normalized(reasoningEffort)
        let normalizedSpeed = try normalized(speedMode)
        let normalizedTier = try normalized(serviceTier)
        let models = resolvedModels(for: providerID)
        let selectedModel: ProviderModelCatalogEntry? = if definition.capabilities.supportsModelSelection {
            if let normalizedModel, let exact = models.first(where: { $0.id == normalizedModel }) {
                exact
            } else {
                models.first(where: \.isProviderDefault) ?? models.first
            }
        } else {
            nil
        }
        let reasoning: String? = if definition.capabilities.supportsReasoningEffort, let selectedModel {
            if let normalizedReasoning, selectedModel.reasoningEfforts.contains(normalizedReasoning) {
                normalizedReasoning
            } else {
                selectedModel.defaultReasoningEffort ?? selectedModel.reasoningEfforts.first
            }
        } else {
            nil
        }
        let speed = definition.capabilities.supportsSpeedMode
            ? normalizedSpeed.flatMap { selectedModel?.speedModes.contains($0) == true ? $0 : nil }
            : nil
        let tier = definition.capabilities.supportsServiceTier
            ? normalizedTier.flatMap { selectedModel?.serviceTiers.contains($0) == true ? $0 : nil }
            : nil
        return BootstrapSelection(
            defaultModel: selectedModel?.id,
            reasoningEffort: reasoning,
            speedMode: speed,
            serviceTier: tier
        )
    }

    private func loadModelCatalogs() throws -> [ProviderSettingsID: [ProviderModelCatalogEntry]] {
        try modelCatalogFiles.reduce(into: [:]) { result, item in
            let data = try Data(contentsOf: URL(fileURLWithPath: item.value))
            let catalog = try JSONDecoder.serviceDecoder.decode([ProviderModelCatalogEntry].self, from: data)
            guard catalog.count <= 500,
                  Set(catalog.map(\.id)).count == catalog.count,
                  catalog.count(where: \.isProviderDefault) <= 1,
                  catalog.allSatisfy({ validCatalogEntry($0, providerID: item.key) })
            else { throw ServiceAPIError(code: .invalidRequest, message: "Provider model catalog is invalid") }
            result[item.key] = catalog
        }
    }

    private func validCatalogEntry(_ entry: ProviderModelCatalogEntry, providerID: ProviderSettingsID) -> Bool {
        let definition = Self.definition(providerID)
        let safeFields = [entry.id, entry.providerRawValue, entry.displayName, entry.description, entry.serviceTier].compactMap(\.self)
        let optionGroups = [entry.reasoningEfforts, entry.speedModes, entry.serviceTiers]
        guard !entry.id.isEmpty,
              entry.id.utf8.count <= 256,
              entry.providerRawValue?.utf8.count ?? 0 <= 256,
              !entry.displayName.isEmpty,
              entry.displayName.utf8.count <= 256,
              entry.description?.utf8.count ?? 0 <= 1024,
              entry.serviceTier?.utf8.count ?? 0 <= 128,
              safeFields.allSatisfy({ safeCatalogText($0) }),
              optionGroups.allSatisfy({ options in
                  options.count <= 64
                      && Set(options).count == options.count
                      && options.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 && safeCatalogText($0) }
              }),
              definition.capabilities.supportsReasoningEffort || entry.reasoningEfforts.isEmpty,
              entry.defaultReasoningEffort.map(entry.reasoningEfforts.contains) ?? true,
              definition.capabilities.supportsSpeedMode || entry.speedModes.isEmpty,
              definition.capabilities.supportsServiceTier || entry.serviceTiers.isEmpty
        else { return false }
        return true
    }

    private func safeCatalogText(_ value: String) -> Bool {
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !ProviderSecretRedaction.containsLikelySecret(value)
    }

    private func auditResult(for state: ProviderManagedAuthenticationTransactionState) -> String {
        switch state {
        case .pending: "pending"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .expired: "expired"
        }
    }

    private func projectedCapabilities(
        _ capabilities: ProviderSettingsCapabilities,
        providerID: ProviderSettingsID,
        deploymentAllowed: Bool
    ) -> ProviderSettingsCapabilities {
        var supported = supportedAuthenticationMethods[providerID, default: []]
        let refreshedManagedCapabilities = managedAuthFlowCapabilities[providerID, default: []]
        let managedCapabilities: [ProviderManagedAuthenticationFlowCapability] = if refreshedManagedCapabilities.isEmpty, providerID == .codex, deploymentAllowed {
            [
                ProviderManagedAuthenticationFlowCapability(
                    kind: .deviceCodeBeta,
                    displayName: "ChatGPT device authorization",
                    startable: false,
                    detail: "Device authorization settings remain available while RepoPrompt checks the Codex runtime."
                )
            ]
        } else {
            refreshedManagedCapabilities
        }
        if managedCapabilities.contains(where: { $0.kind == .deviceCodeBeta })
            || (providerID == .codex && deploymentAllowed)
        {
            supported.insert(.deviceCodeBeta)
        }
        return .init(
            supportsModelSelection: capabilities.supportsModelSelection,
            supportsReasoningEffort: capabilities.supportsReasoningEffort,
            supportsSpeedMode: capabilities.supportsSpeedMode,
            supportsServiceTier: capabilities.supportsServiceTier,
            authenticationMethods: ProviderAuthenticationMethod.allCases.filter(supported.contains),
            authFlows: managedCapabilities.map { capability in
                let kind: ProviderAuthFlowKind = switch capability.kind {
                case .browserOAuth: .browserOAuth
                case .deviceCodeBeta: .deviceCodeBeta
                case .externalProvisioning: .externalProvisioning
                }
                return ProviderAuthFlowDescriptor(
                    kind: kind,
                    displayName: capability.displayName,
                    startable: capability.startable,
                    detail: capability.detail
                )
            }
        )
    }

    private struct Definition {
        let displayName: String
        let category: ProviderSettingsCategory
        let summary: String
        let capabilities: ProviderSettingsCapabilities
    }

    private nonisolated static func definition(_ providerID: ProviderSettingsID) -> Definition {
        switch providerID {
        case .codex:
            Definition(displayName: "Codex", category: .cliProvider, summary: "OpenAI Codex app-server with isolated CODEX_HOME", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: true))
        case .claudeCompatible:
            Definition(displayName: "Claude Code", category: .cliProvider, summary: "Claude-compatible stream JSON with isolated CLAUDE_CONFIG_DIR", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: false))
        case .claudeGLM:
            Definition(displayName: "CC Zai", category: .cliProvider, summary: "Z.ai coding-plan backend launched through the packaged Claude Code CLI", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: false))
        case .claudeKimi:
            Definition(displayName: "CC Moonshot", category: .cliProvider, summary: "Kimi coding-plan backend launched through the packaged Claude Code CLI", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false))
        case .claudeCustom:
            Definition(displayName: "CC Custom", category: .cliProvider, summary: "Custom Claude Code-compatible HTTPS backend", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false))
        case .openCodeACP:
            Definition(displayName: "OpenCode", category: .cliProvider, summary: "Provider-specific ACP catalog and authentication", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false))
        case .cursorACP:
            Definition(displayName: "Cursor", category: .cliProvider, summary: "Cursor ACP with externally provisioned authentication", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false))
        case .grokBuildACP:
            Definition(displayName: "Grok Build", category: .cliProvider, summary: "Grok Build ACP (`grok agent stdio`) with grok login home or XAI_API_KEY", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: false))
        case .openAIAPI:
            Definition(displayName: "OpenAI API", category: .apiProvider, summary: "Direct fixed-host OpenAI HTTPS runtime", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: true))
        case .anthropicAPI:
            Definition(displayName: "Anthropic API", category: .apiProvider, summary: "Direct fixed-host Anthropic Messages HTTPS runtime", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false))
        case .openRouter:
            Definition(displayName: "OpenRouter", category: .apiProvider, summary: "Direct fixed-host OpenRouter HTTPS runtime", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: false))
        case .customOpenAICompatible:
            Definition(displayName: "Custom OpenAI-Compatible", category: .apiProvider, summary: "Public HTTPS OpenAI-compatible runtime with pinned-address egress", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: false))
        case .gemini:
            Definition(displayName: "Gemini", category: .apiProvider, summary: "Direct fixed-host Gemini HTTPS runtime", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false))
        case .azure:
            Definition(displayName: "Azure", category: .apiProvider, summary: "Direct Azure OpenAI HTTPS runtime with persisted resource URL and API version", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false))
        case .deepseek:
            Definition(displayName: "DeepSeek", category: .apiProvider, summary: "Direct fixed-host DeepSeek HTTPS runtime", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false))
        case .fireworks:
            Definition(displayName: "Fireworks", category: .apiProvider, summary: "Direct fixed-host Fireworks HTTPS runtime", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false))
        case .xAI:
            Definition(displayName: "xAI", category: .apiProvider, summary: "Direct fixed-host xAI HTTPS runtime", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: false))
        case .groq:
            Definition(displayName: "Groq", category: .apiProvider, summary: "Direct fixed-host Groq HTTPS runtime", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false))
        case .zAI:
            Definition(displayName: "Z.AI", category: .apiProvider, summary: "Direct fixed-host Z.AI HTTPS runtime", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false))
        case .ollama:
            Definition(displayName: "Ollama", category: .apiProvider, summary: "Persisted Ollama URL runtime; loopback requires REPOPROMPT_ALLOW_LOCAL_PROVIDER_URLS", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false))
        }
    }

    private nonisolated static func settingsID(_ kind: ProviderKind) -> ProviderSettingsID? {
        switch kind {
        case .codex: .codex
        case .claudeCompatible: .claudeCompatible
        case .openCodeACP: .openCodeACP
        case .cursorACP: .cursorACP
        case .grokBuildACP: .grokBuildACP
        case .headlessAdapter, .mcp: nil
        }
    }

    private nonisolated static func validCLIVersionOutput(_ output: String) -> String? {
        guard let firstLine = output.split(whereSeparator: \.isNewline).first else { return nil }
        let value = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._+-/():"))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    private nonisolated func normalized(_ value: String?) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(value)
        else { throw ServiceAPIError(code: .invalidRequest, message: "Provider setting is invalid") }
        return value
    }
}
