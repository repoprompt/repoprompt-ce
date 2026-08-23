import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public protocol DirectProviderConfigurationProviding: Sendable {
    func configuration(for providerID: ProviderSettingsID) async throws -> DirectProviderConfiguration
    func endpoint(for providerID: ProviderSettingsID) async throws -> DirectProviderEndpoint
    func isDeploymentAllowed(_ providerID: ProviderSettingsID) async -> Bool
}

public protocol DirectProviderCredentialAccessing: Sendable {
    func credential(for providerID: ProviderSettingsID) async throws -> Data
}

public actor VaultDirectProviderCredentialAccessor: DirectProviderCredentialAccessing {
    private let store: SQLiteServiceStore
    private let vault: ProviderCredentialVault?

    public init(store: SQLiteServiceStore, vault: ProviderCredentialVault?) {
        self.store = store
        self.vault = vault
    }

    public func credential(for providerID: ProviderSettingsID) async throws -> Data {
        if providerID == .ollama {
            guard providerID.isDirectAPI else {
                throw ServiceAPIError(code: .providerUnavailable, message: "Direct provider credential is unavailable")
            }
            return Data()
        }
        guard providerID.requiresVaultCredential,
              let connection = try await store.providerConnection(providerID: providerID),
              connection.record.state == .connected,
              connection.record.testState == .valid,
              connection.record.expiresAt.map({ $0 > Date() }) ?? true,
              let reference = connection.credentialReference,
              let vault
        else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Direct provider credential is unavailable")
        }
        let credential = try await vault.load(providerID: providerID, connectionID: reference)
        guard !credential.isEmpty, credential.count <= 65_536 else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Direct provider credential is unavailable")
        }
        return credential
    }
}

public actor DirectProviderRegistry: DirectProviderConfigurationProviding, DirectProviderSettingsProviding {
    private let store: SQLiteServiceStore
    private let transport: any ValidatedProviderEgressTransporting
    private let deploymentAllowlist: Set<ProviderSettingsID>
    private let allowLocalURLs: Bool
    private var configurations: [ProviderSettingsID: DirectProviderConfiguration] = [:]

    public init(
        store: SQLiteServiceStore,
        transport: any ValidatedProviderEgressTransporting,
        deploymentAllowlist: Set<ProviderSettingsID>,
        allowLocalURLs: Bool = ProviderLocalURLEscape.isEnabled()
    ) {
        self.store = store
        self.transport = transport
        self.deploymentAllowlist = Set(deploymentAllowlist.filter(\.isDirectAPI))
        self.allowLocalURLs = allowLocalURLs
    }

    public func bootstrap() async throws {
        configurations = try await Dictionary(uniqueKeysWithValues: store.directProviderConfigurations().map { ($0.providerID, $0) })
        for providerID in ProviderSettingsID.directAPIProviders {
            if configurations[providerID] == nil {
                let initial = try Self.validateConfiguration(
                    providerID: providerID,
                    baseURL: providerID == .ollama ? ProviderSettingsID.desktopOllamaDefaultURL : nil,
                    preferredModel: nil,
                    maximumOutputTokens: providerID.desktopBootstrapMaxTokens,
                    customHeaders: [:],
                    contentTypePolicy: .applicationJSON,
                    revision: 1,
                    updatedAt: Date(),
                    apiVersion: nil,
                    allowLocalURLs: allowLocalURLs
                )
                configurations[providerID] = try await store.upsertDirectProviderConfiguration(initial, expectedRevision: 0)
            }
        }
    }

    public func isDeploymentAllowed(_ providerID: ProviderSettingsID) -> Bool {
        deploymentAllowlist.contains(providerID)
    }

    public func configuration(for providerID: ProviderSettingsID) throws -> DirectProviderConfiguration {
        guard deploymentAllowlist.contains(providerID), let configuration = configurations[providerID] else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Direct provider is not admitted by this deployment")
        }
        return configuration
    }

    public func endpoint(for providerID: ProviderSettingsID) async throws -> DirectProviderEndpoint {
        let configuration = try configuration(for: providerID)
        if providerID == .customOpenAICompatible || providerID == .azure {
            guard let baseURL = configuration.baseURL, !baseURL.isEmpty else {
                throw ServiceAPIError(
                    code: .providerUnavailable,
                    message: providerID == .azure
                        ? "Azure OpenAI configuration is missing"
                        : "Custom provider endpoint is not configured"
                )
            }
            return try await transport.validateEndpoint(baseURL)
        }
        if providerID == .openAIAPI, let baseURL = configuration.baseURL, !baseURL.isEmpty {
            return try await transport.validateEndpoint(baseURL)
        }
        if providerID == .ollama {
            guard let baseURL = configuration.baseURL, !baseURL.isEmpty else {
                throw ServiceAPIError(code: .providerUnavailable, message: "Missing Ollama URL.")
            }
            return try ProviderEndpointPolicy.parseOllamaBaseURL(baseURL)
        }
        return try ProviderEndpointPolicy.fixed(providerID: providerID)
    }

    public func update(
        providerID: ProviderSettingsID,
        request: UpdateDirectProviderConfigurationRequest,
        attribution: ProviderMutationAttribution
    ) async throws -> DirectProviderConfiguration {
        guard deploymentAllowlist.contains(providerID), let current = configurations[providerID] else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Direct provider is not admitted by this deployment")
        }
        guard current.revision == request.expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Direct provider configuration revision is stale", currentRevision: current.revision)
        }
        let next = try Self.validateConfiguration(
            providerID: providerID,
            baseURL: request.baseURL,
            preferredModel: request.preferredModel,
            maximumOutputTokens: request.maximumOutputTokens,
            customHeaders: request.customHeaders,
            contentTypePolicy: request.contentTypePolicy,
            revision: current.revision + 1,
            updatedAt: Date(),
            apiVersion: request.apiVersion,
            enabledModels: request.enabledModels,
            includeDefaultModels: request.includeDefaultModels,
            useCustomSettings: request.useCustomSettings,
            includeContentTypeHeader: request.includeContentTypeHeader,
            showServiceTierVariants: request.showServiceTierVariants,
            allowLocalURLs: allowLocalURLs
        )
        if providerID.acceptsPersistedBaseURL, providerID != .ollama, let baseURL = next.baseURL {
            _ = try await transport.validateEndpoint(baseURL)
        }
        configurations[providerID] = try await store.upsertDirectProviderConfiguration(
            next,
            expectedRevision: current.revision,
            audit: .init(operation: "updateDirectConfiguration", attribution: attribution, authenticationMethod: nil, result: "updated")
        )
        return configurations[providerID]!
    }

    static func validateConfiguration(
        providerID: ProviderSettingsID,
        baseURL: String?,
        preferredModel: String?,
        maximumOutputTokens: Int,
        customHeaders: [String: String],
        contentTypePolicy: DirectProviderContentTypePolicy,
        revision: Int64,
        updatedAt: Date,
        apiVersion: String? = nil,
        enabledModels: [String] = [],
        includeDefaultModels: Bool = true,
        useCustomSettings: Bool = true,
        includeContentTypeHeader: Bool = false,
        showServiceTierVariants: Bool = false,
        allowLocalURLs: Bool = ProviderLocalURLEscape.isEnabled()
    ) throws -> DirectProviderConfiguration {
        guard providerID.isDirectAPI,
              revision > 0,
              (0 ... 65_536).contains(maximumOutputTokens),
              customHeaders.count <= 16,
              enabledModels.count <= 256
        else { throw ServiceAPIError(code: .invalidRequest, message: "Direct provider configuration is invalid") }
        let normalizedBaseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if providerID == .customOpenAICompatible || providerID == .azure || providerID == .openAIAPI {
            if let normalizedBaseURL, !normalizedBaseURL.isEmpty {
                let allowLocal = allowLocalURLs && providerID != .azure
                _ = try ProviderEndpointPolicy.parseCustomBaseURL(normalizedBaseURL, allowLocalURLs: allowLocal)
            }
        } else if providerID == .ollama {
            if let normalizedBaseURL, !normalizedBaseURL.isEmpty {
                _ = try ProviderEndpointPolicy.parseOllamaBaseURL(normalizedBaseURL)
            }
        } else if normalizedBaseURL?.isEmpty == false {
            throw ServiceAPIError(code: .invalidRequest, message: "Fixed-host providers do not accept a base URL")
        }
        if !customHeaders.isEmpty, !providerID.acceptsCustomHeaders {
            throw ServiceAPIError(code: .invalidRequest, message: "This provider does not accept custom headers")
        }
        let normalizedAPIVersion: String?
        if providerID.acceptsPersistedAPIVersion {
            normalizedAPIVersion = try safeText(apiVersion, maximumBytes: 64)
        } else if apiVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            throw ServiceAPIError(code: .invalidRequest, message: "This provider does not persist an API version")
        } else {
            normalizedAPIVersion = nil
        }
        let normalizedModel = try safeText(preferredModel, maximumBytes: 256)
        var normalizedEnabled: [String] = []
        var seenEnabled = Set<String>()
        for raw in enabledModels {
            guard let model = try safeText(raw, maximumBytes: 256), seenEnabled.insert(model).inserted else {
                throw ServiceAPIError(code: .invalidRequest, message: "Direct provider allowlist is invalid")
            }
            normalizedEnabled.append(model)
        }
        var normalizedHeaders: [String: String] = [:]
        var totalBytes = 0
        for (rawName, rawValue) in customHeaders {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            let forbidden = Set([
                "authorization", "proxy-authorization", "cookie", "set-cookie", "host",
                "connection", "content-length", "transfer-encoding", "te", "trailer", "upgrade",
                "forwarded", "via", "x-real-ip"
            ])
            guard name.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil,
                  !forbidden.contains(lower),
                  !lower.hasPrefix("x-forwarded-"),
                  !lower.hasPrefix("proxy-"),
                  !lower.contains("api-key"),
                  !lower.contains("apikey"),
                  !lower.contains("token"),
                  !lower.contains("secret"),
                  !lower.contains("credential"),
                  !value.isEmpty,
                  value.utf8.count <= 1024,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !ProviderSecretRedaction.containsLikelySecret(value)
            else { throw ServiceAPIError(code: .invalidRequest, message: "Direct provider header is forbidden or unsafe") }
            totalBytes += name.utf8.count + value.utf8.count
            normalizedHeaders[name] = value
        }
        guard totalBytes <= 8192 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Direct provider headers exceed their bound")
        }
        let persistedBaseURL: String?
        if providerID.acceptsPersistedBaseURL {
            persistedBaseURL = (normalizedBaseURL?.isEmpty == false) ? normalizedBaseURL : (providerID == .ollama ? ProviderSettingsID.desktopOllamaDefaultURL : nil)
        } else {
            persistedBaseURL = nil
        }
        return DirectProviderConfiguration(
            providerID: providerID,
            baseURL: persistedBaseURL,
            preferredModel: normalizedModel,
            maximumOutputTokens: maximumOutputTokens,
            customHeaders: normalizedHeaders,
            contentTypePolicy: contentTypePolicy,
            apiVersion: normalizedAPIVersion,
            enabledModels: normalizedEnabled,
            includeDefaultModels: includeDefaultModels,
            useCustomSettings: useCustomSettings,
            includeContentTypeHeader: includeContentTypeHeader,
            showServiceTierVariants: showServiceTierVariants,
            revision: revision,
            updatedAt: updatedAt
        )
    }

    private static func safeText(_ value: String?, maximumBytes: Int) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(value)
        else { throw ServiceAPIError(code: .invalidRequest, message: "Direct provider setting is invalid") }
        return value
    }
}

public actor DirectProviderCredentialTester: ProviderCredentialTesting {
    private let registry: DirectProviderRegistry
    private let transport: any ValidatedProviderEgressTransporting

    public init(registry: DirectProviderRegistry, transport: any ValidatedProviderEgressTransporting) {
        self.registry = registry
        self.transport = transport
    }

    public func supportedAuthenticationMethods(for providerID: ProviderSettingsID) async -> Set<ProviderAuthenticationMethod> {
        guard providerID.requiresVaultCredential, await registry.isDeploymentAllowed(providerID) else { return [] }
        return [.apiKey]
    }

    public func test(providerID: ProviderSettingsID, method: ProviderAuthenticationMethod, secret: Data?) async -> ProviderCredentialTestResult {
        guard method == .apiKey,
              await supportedAuthenticationMethods(for: providerID).contains(method),
              let secret,
              let credential = String(data: secret, encoding: .utf8),
              !credential.isEmpty,
              credential.utf8.count <= 65_536,
              !credential.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return .init(state: .invalid, detail: "Provider credential is invalid") }
        do {
            let configuration = try await registry.configuration(for: providerID)
            let endpoint = try await registry.endpoint(for: providerID)
            let response = try await transport.execute(.init(
                endpoint: endpoint,
                method: "GET",
                pathAndQuery: Self.catalogPath(providerID: providerID, endpoint: endpoint, configuration: configuration),
                headers: Self.authenticationHeaders(providerID: providerID, credential: credential),
                maximumResponseBodyBytes: 2 * 1024 * 1024,
                totalTimeout: .seconds(15)
            ))
            switch response.statusCode {
            case 200 ..< 300:
                let models = Self.mergingPreferredModel(
                    try Self.parseCatalog(response: response, providerID: providerID),
                    preferredModel: configuration.preferredModel
                )
                return .init(state: .valid, detail: "Provider credential and model catalog validated", models: models)
            case 401, 403:
                return .init(state: .invalid, detail: "Provider rejected the configured credential")
            default:
                return .init(state: .unavailable, detail: "Provider validation is temporarily unavailable")
            }
        } catch is CancellationError {
            return .init(state: .unavailable, detail: "Provider validation was cancelled")
        } catch {
            return .init(state: .unavailable, detail: "Provider validation is temporarily unavailable")
        }
    }

    public func logout(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod) async {}

    static func authenticationHeaders(providerID: ProviderSettingsID, credential: String) -> [String: String] {
        switch providerID {
        case .anthropicAPI:
            ["x-api-key": credential, "anthropic-version": "2023-06-01"]
        case .azure:
            ["api-key": credential]
        case .ollama:
            [:]
        default:
            ["Authorization": "Bearer \(credential)"]
        }
    }

    static func catalogPath(
        providerID: ProviderSettingsID,
        endpoint: DirectProviderEndpoint,
        configuration: DirectProviderConfiguration? = nil
    ) -> String {
        let base = endpoint.basePath
        if providerID == .azure {
            let version = configuration?.apiVersion?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return "\(base)/openai/models?api-version=\(version)"
        }
        if let apiVersion = configuration?.apiVersion, !apiVersion.isEmpty,
           providerID == .openAIAPI || providerID == .customOpenAICompatible
        {
            let stripped = DirectAPIProviderRuntime.strippingTrailingVersion(base)
            return stripped.isEmpty ? "/\(apiVersion)/models" : "\(stripped)/\(apiVersion)/models"
        }
        if providerID == .customOpenAICompatible || providerID == .ollama {
            return base.hasSuffix("/v1") ? "\(base)/models" : "\(base)/v1/models"
        }
        return "\(base)/models"
    }

    static func parseCatalog(response: ValidatedProviderHTTPResponse, providerID: ProviderSettingsID) throws -> [ProviderModelCatalogEntry] {
        guard response.body.count <= 2 * 1024 * 1024,
              response.contentType?.lowercased().contains("json") == true,
              let catalogText = String(data: response.body, encoding: .utf8),
              !ProviderSecretRedaction.containsLikelySecret(catalogText),
              let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider model catalog is invalid") }
        let data: [[String: Any]]
        if let openAI = payload["data"] as? [[String: Any]] {
            data = openAI
        } else if providerID == .gemini, let gemini = payload["models"] as? [[String: Any]] {
            data = gemini
        } else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider model catalog is invalid")
        }
        guard data.count <= 500 else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider model catalog is invalid")
        }
        var seen = Set<String>()
        var models: [ProviderModelCatalogEntry] = []
        for item in data {
            let rawID = (item["id"] as? String)
                ?? (item["name"] as? String)?.replacingOccurrences(of: "models/", with: "")
            guard let rawID,
                  let id = try? safeCatalogText(rawID, maximumBytes: 256),
                  seen.insert(id).inserted
            else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider model catalog is invalid") }
            let rawName = (item["display_name"] as? String) ?? (item["name"] as? String) ?? id
            guard let displayName = try? safeCatalogText(rawName, maximumBytes: 256) else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider model catalog is invalid")
            }
            let description: String?
            if let raw = item["description"] as? String {
                description = try safeCatalogText(raw, maximumBytes: 1024)
            } else {
                description = nil
            }
            let reasoningEfforts: [String] = providerID == .anthropicAPI
                ? []
                : ["low", "medium", "high", "xhigh", "max"]
            let serviceTiers: [String] = providerID == .openAIAPI
                ? ["auto", "default", "flex", "priority", "scale"]
                : []
            models.append(.init(
                id: id,
                displayName: displayName,
                description: description,
                isProviderDefault: false,
                reasoningEfforts: reasoningEfforts,
                serviceTiers: serviceTiers
            ))
        }
        guard !models.isEmpty else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider model catalog is empty")
        }
        return models.sorted { $0.id < $1.id }
    }

    static func mergingPreferredModel(
        _ models: [ProviderModelCatalogEntry],
        preferredModel: String?
    ) -> [ProviderModelCatalogEntry] {
        guard let preferredModel, !preferredModel.isEmpty, !models.contains(where: { $0.id == preferredModel }) else {
            return models
        }
        return (models + [.init(id: preferredModel, displayName: preferredModel)]).sorted { $0.id < $1.id }
    }

    private static func safeCatalogText(_ value: String, maximumBytes: Int) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumBytes,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(normalized)
        else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider model catalog is invalid") }
        return normalized
    }
}

public actor CompositeProviderCredentialTester: ProviderCredentialTesting {
    private let cli: any ProviderCredentialTesting
    private let direct: any ProviderCredentialTesting

    public init(cli: any ProviderCredentialTesting, direct: any ProviderCredentialTesting) {
        self.cli = cli
        self.direct = direct
    }

    public func supportedAuthenticationMethods(for providerID: ProviderSettingsID) async -> Set<ProviderAuthenticationMethod> {
        if providerID.isDirectAPI { return await direct.supportedAuthenticationMethods(for: providerID) }
        return await cli.supportedAuthenticationMethods(for: providerID)
    }

    public func test(providerID: ProviderSettingsID, method: ProviderAuthenticationMethod, secret: Data?) async -> ProviderCredentialTestResult {
        if providerID.isDirectAPI { return await direct.test(providerID: providerID, method: method, secret: secret) }
        return await cli.test(providerID: providerID, method: method, secret: secret)
    }

    public func logout(providerID: ProviderSettingsID, method: ProviderAuthenticationMethod) async {
        if providerID.isDirectAPI { await direct.logout(providerID: providerID, method: method) }
        else { await cli.logout(providerID: providerID, method: method) }
    }
}

public actor DirectAPIProviderRuntime: AgentProviderRuntime {
    public let kind = ProviderKind.headlessAdapter
    public let providerID: ProviderSettingsID
    private let registry: any DirectProviderConfigurationProviding
    private let credentials: any DirectProviderCredentialAccessing
    private let transport: any ValidatedProviderEgressTransporting
    private var activeRuns: Set<UUID> = []

    public init(
        providerID: ProviderSettingsID,
        registry: any DirectProviderConfigurationProviding,
        credentials: any DirectProviderCredentialAccessing,
        transport: any ValidatedProviderEgressTransporting
    ) {
        precondition(providerID.isDirectAPI)
        self.providerID = providerID
        self.registry = registry
        self.credentials = credentials
        self.transport = transport
    }

    public func capability() async -> ProviderCapability {
        let admitted = await registry.isDeploymentAllowed(providerID)
        return .init(
            kind: .headlessAdapter,
            enabled: admitted,
            executable: nil,
            supportsResume: false,
            supportsSteering: false,
            protocolVersion: providerID == .anthropicAPI ? "anthropic-messages-v1" : "openai-chat-completions-v1",
            reasonUnavailable: admitted ? nil : "direct provider is not deployment-admitted"
        )
    }

    public func preflight() async -> ProviderCapability { await capability() }

    public func execute(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        try request.validateLaunch()
        guard request.policy.providerSettings["provider.settingsID"] == providerID.rawValue else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Exact direct provider identity is missing")
        }
        let configuration = try await registry.configuration(for: providerID)
        if providerID == .azure, configuration.baseURL == nil || configuration.apiVersion == nil {
            throw ServiceAPIError(code: .providerUnavailable, message: "Azure OpenAI configuration is missing")
        }
        if providerID == .ollama, configuration.baseURL?.isEmpty != false {
            throw ServiceAPIError(code: .providerUnavailable, message: "Missing Ollama URL.")
        }
        let endpoint = try await registry.endpoint(for: providerID)
        let credentialData = try await credentials.credential(for: providerID)
        let credential = String(data: credentialData, encoding: .utf8) ?? ""
        if providerID.requiresVaultCredential, credential.isEmpty {
            throw ServiceAPIError(code: .providerUnavailable, message: "Direct provider credential is unavailable")
        }
        let model = request.model ?? configuration.preferredModel
        guard let model, !model.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "A direct provider model is required")
        }
        guard configuration.allowsLaunchModel(model) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Model is not in the provider allowlist")
        }
        activeRuns.insert(request.runID)
        defer { activeRuns.remove(request.runID) }
        try Task.checkCancellation()

        let mapped = try Self.mappedRequest(
            providerID: providerID,
            endpoint: endpoint,
            configuration: configuration,
            credential: credential,
            model: model,
            prompt: request.prompt,
            settings: request.policy.providerSettings
        )
        let response: ValidatedProviderHTTPResponse
        do {
            response = try await transport.execute(
                mapped,
                onRequestSent: { try await request.acknowledgeLaunch() }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ServiceAPIError {
            throw error
        } catch {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Direct provider request failed", retryable: true)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ServiceAPIError(
                code: response.statusCode == 401 || response.statusCode == 403 ? .providerUnavailable : .dependencyUnavailable,
                message: response.statusCode == 401 || response.statusCode == 403
                    ? "Direct provider rejected the configured credential"
                    : "Direct provider request failed",
                retryable: response.statusCode != 401 && response.statusCode != 403
            )
        }
        let output = try await Self.parseOutput(response: response, providerID: providerID, maximumBytes: request.maximumBytes) { event in
            await onEvent(event)
        }
        await onEvent(.completed(providerSessionID: nil))
        return .init(output: output, providerSessionID: nil)
    }

    public func interrupt(runID: UUID) async throws {
        guard activeRuns.contains(runID) else { return }
        // Dispatcher cancellation owns the task. This method is an exact-run
        // admission fence; the authority cancels its in-flight task immediately.
    }

    public func hasActiveRun(_ runID: UUID) -> Bool { activeRuns.contains(runID) }

    static func mappedRequest(
        providerID: ProviderSettingsID,
        endpoint: DirectProviderEndpoint,
        configuration: DirectProviderConfiguration,
        credential: String,
        model: String,
        prompt: String,
        settings: [String: String]
    ) throws -> ValidatedProviderHTTPRequest {
        var headers = DirectProviderCredentialTester.authenticationHeaders(providerID: providerID, credential: credential)
        if providerID == .openRouter {
            headers["HTTP-Referer"] = "https://repoprompt.com/"
            headers["X-Title"] = "Repo Prompt"
        }
        if providerID != .openRouter || configuration.useCustomSettings {
            configuration.customHeaders.forEach { headers[$0.key] = $0.value }
        }
        switch configuration.contentTypePolicy {
        case .applicationJSON:
            if headers.keys.contains(where: { $0.lowercased() == "content-type" }) == false {
                headers["Content-Type"] = "application/json"
            }
        }
        let stream = settings["models.stream"] != "false"
        let useResponses = providerID == .customOpenAICompatible && settings["models.responses"] == "true"
        let maxTokens = Self.resolvedMaxTokens(providerID: providerID, configuration: configuration, model: model, stream: stream)
        let payload: [String: Any]
        let path: String
        if providerID == .anthropicAPI {
            path = "\(endpoint.basePath)/messages"
            var body: [String: Any] = [
                "model": model,
                "stream": stream,
                "messages": [["role": "user", "content": prompt]]
            ]
            if let maxTokens { body["max_tokens"] = maxTokens }
            Self.attachTemperature(from: settings, to: &body)
            payload = body
        } else if providerID == .azure {
            guard let apiVersion = configuration.apiVersion, !apiVersion.isEmpty else {
                throw ServiceAPIError(code: .providerUnavailable, message: "Azure OpenAI configuration is missing")
            }
            let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            let encodedVersion = apiVersion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiVersion
            path = "\(endpoint.basePath)/openai/deployments/\(encodedModel)/chat/completions?api-version=\(encodedVersion)"
            var body: [String: Any] = [
                "model": model,
                "stream": stream,
                "messages": [["role": "user", "content": prompt]]
            ]
            if let maxTokens { body["max_tokens"] = maxTokens }
            Self.attachTemperature(from: settings, to: &body)
            payload = body
        } else {
            path = Self.versionedRequestPath(
                providerID: providerID,
                endpoint: endpoint,
                apiVersion: configuration.apiVersion,
                useResponses: useResponses
            )
            var body: [String: Any]
            if useResponses {
                body = [
                    "model": model,
                    "stream": stream,
                    "input": prompt
                ]
                if let maxTokens { body["max_output_tokens"] = maxTokens }
            } else {
                body = [
                    "model": model,
                    "stream": stream,
                    "messages": [["role": "user", "content": prompt]]
                ]
                if let maxTokens { body["max_tokens"] = maxTokens }
            }
            if providerID == .openAIAPI {
                let tier = settings["provider.serviceTier"] ?? "auto"
                guard ["auto", "default", "flex", "priority", "scale"].contains(tier) else {
                    throw ServiceAPIError(code: .invalidRequest, message: "OpenAI service tier is invalid")
                }
                body["service_tier"] = tier
            }
            if let effort = settings["provider.reasoningEffort"] {
                body["reasoning_effort"] = effort
            }
            Self.attachTemperature(from: settings, to: &body)
            payload = body
        }
        return .init(
            endpoint: endpoint,
            method: "POST",
            pathAndQuery: path,
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: payload),
            maximumResponseBodyBytes: min(8 * 1024 * 1024, max(64 * 1024, (maxTokens ?? 4_096) * 32)),
            totalTimeout: .seconds(120)
        )
    }

    /// Desktop `effectiveTemperature`: a stamped value is attached, including an explicit 0.0 override.
    /// Global 0.0 is omitted before stamp, so a present key is always sent.
    static func attachTemperature(from settings: [String: String], to body: inout [String: Any]) {
        guard let raw = settings["models.temperature"], let temperature = Double(raw) else { return }
        body["temperature"] = temperature
    }

    /// Desktop token contract: custom 0/2048 omits; OpenRouter 8192 unless custom settings;
    /// Anthropic stream 8192 / complete 4096; OpenAI uses model defaults when stored is 0.
    static func resolvedMaxTokens(
        providerID: ProviderSettingsID,
        configuration: DirectProviderConfiguration,
        model: String,
        stream: Bool
    ) -> Int? {
        let stored = configuration.maximumOutputTokens
        switch providerID {
        case .customOpenAICompatible:
            return (stored == 0 || stored == 2048) ? nil : stored
        case .openRouter:
            if !configuration.useCustomSettings { return 8192 }
            return stored == 0 ? 8192 : stored
        case .anthropicAPI:
            return stored == 0 ? (stream ? 8192 : 4096) : stored
        case .openAIAPI:
            return stored == 0 ? desktopOpenAIDefaultMaxTokens(model) : stored
        default:
            return stored == 0 ? 4096 : stored
        }
    }

    static func desktopOpenAIDefaultMaxTokens(_ model: String) -> Int {
        if model.hasPrefix("gpt-4.1") { return 16_384 }
        if model == "o3" || model.hasPrefix("o3-") { return 100_000 }
        if model.hasPrefix("o1-mini") { return 65_536 }
        if model.hasPrefix("o1-preview") { return 32_768 }
        if model.hasPrefix("gpt-5"), model.contains("-pro") { return 100_000 }
        if model.hasPrefix("gpt-5") { return 128_000 }
        return 2048
    }

    static func versionedRequestPath(
        providerID: ProviderSettingsID,
        endpoint: DirectProviderEndpoint,
        apiVersion: String?,
        useResponses: Bool
    ) -> String {
        let leaf = useResponses ? "responses" : "chat/completions"
        if let apiVersion, !apiVersion.isEmpty, providerID == .openAIAPI || providerID == .customOpenAICompatible {
            let base = strippingTrailingVersion(endpoint.basePath)
            return base.isEmpty ? "/\(apiVersion)/\(leaf)" : "\(base)/\(apiVersion)/\(leaf)"
        }
        if providerID == .customOpenAICompatible || providerID == .ollama {
            return endpoint.basePath.hasSuffix("/v1")
                ? "\(endpoint.basePath)/\(leaf)"
                : "\(endpoint.basePath)/v1/\(leaf)"
        }
        return "\(endpoint.basePath)/\(leaf)"
    }

    static func strippingTrailingVersion(_ path: String) -> String {
        guard let last = path.split(separator: "/").last,
              String(last).range(of: #"^v\d+([A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil
        else { return path }
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == String(last) { parts.removeLast() }
        let joined = parts.joined(separator: "/")
        return joined == "/" ? "" : joined
    }

    static func parseOutput(
        response: ValidatedProviderHTTPResponse,
        providerID: ProviderSettingsID,
        maximumBytes: Int,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> String {
        guard response.body.count <= min(8 * 1024 * 1024, maximumBytes * 8) else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Direct provider response exceeded its bound")
        }
        var output = ""
        if response.contentType?.lowercased().contains("text/event-stream") == true {
            let text = String(decoding: response.body, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                guard line.hasPrefix("data:") else { continue }
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if value == "[DONE]" { continue }
                guard let data = value.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let delta: String?
                if providerID == .anthropicAPI {
                    delta = (payload["delta"] as? [String: Any])?["text"] as? String
                } else if payload["type"] as? String == "response.output_text.delta" {
                    delta = payload["delta"] as? String
                } else {
                    delta = ((payload["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String
                }
                if let delta, !delta.isEmpty {
                    guard output.utf8.count + delta.utf8.count <= maximumBytes else {
                        throw ServiceAPIError(code: .dependencyUnavailable, message: "Direct provider output exceeded its bound")
                    }
                    output += delta
                    await onEvent(.assistantDelta(delta))
                }
            }
        } else {
            guard response.contentType?.lowercased().contains("json") == true,
                  let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Direct provider returned an invalid response") }
            if providerID == .anthropicAPI {
                let blocks = payload["content"] as? [[String: Any]] ?? []
                output = blocks.compactMap { $0["text"] as? String }.joined()
            } else if let text = payload["output_text"] as? String, !text.isEmpty {
                output = text
            } else {
                output = (((payload["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
            }
            guard output.utf8.count <= maximumBytes else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Direct provider output exceeded its bound")
            }
            if !output.isEmpty { await onEvent(.assistantDelta(output)) }
        }
        guard !output.isEmpty else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Direct provider returned no assistant output")
        }
        await onEvent(.assistantFinal(output))
        return output
    }
}
