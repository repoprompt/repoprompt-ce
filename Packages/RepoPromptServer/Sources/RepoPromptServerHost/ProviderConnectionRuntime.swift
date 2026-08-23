import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

/// Vault-backed, per-launch environment projection. Secrets exist only in the
/// child environment and are never rendered into arguments or result DTOs.
public protocol ProviderCredentialSourceProviding: Sendable {
    func sourceDirectory(for kind: ProviderKind) async throws -> String?
    /// Returns a protected, durable provider environment when the provider's
    /// native conversation state must survive across turns. RepoPrompt Desktop
    /// uses one managed Codex home for authentication and thread persistence;
    /// the server runtime must not replace it with a disposable per-turn copy.
    func persistentRuntimeEnvironment(for kind: ProviderKind) async throws -> [String: String]?
}

public extension ProviderCredentialSourceProviding {
    func persistentRuntimeEnvironment(for _: ProviderKind) async throws -> [String: String]? { nil }
}

public struct StaticProviderCredentialSource: ProviderCredentialSourceProviding {
    private let sources: [ProviderKind: String]

    public init(configurations: [ProviderCLIConfiguration]) {
        sources = Dictionary(uniqueKeysWithValues: configurations.compactMap { configuration in
            configuration.credentialSourceDirectory.map { (configuration.kind, $0) }
        })
    }

    public func sourceDirectory(for kind: ProviderKind) async throws -> String? { sources[kind] }
}

public protocol ClaudeCompatibleBackendSettingsProviding: Sendable {
    func backendSettings(for providerID: ProviderSettingsID) async throws -> ClaudeCompatibleBackendSettings?
}

public actor VaultProviderProcessEnvironment: ProviderProcessEnvironmentProviding, ProviderCredentialSourceProviding {
    private let store: SQLiteServiceStore
    private let vault: ProviderCredentialVault?
    private let externallyProvisionedKinds: Set<ProviderKind>
    private let credentialSourceDirectories: [ProviderKind: String]
    private let managedCodexCredentialSource: String?
    private let managedCodexRuntimeHome: CodexManagedAuthHome?
    private let backendSettings: (any ClaudeCompatibleBackendSettingsProviding)?

    public init(
        store: SQLiteServiceStore,
        vault: ProviderCredentialVault?,
        externallyProvisionedKinds: Set<ProviderKind> = [],
        credentialSourceDirectories: [ProviderKind: String] = [:],
        managedCodexCredentialSource: String? = nil,
        managedCodexRuntimeHome: CodexManagedAuthHome? = nil,
        backendSettings: (any ClaudeCompatibleBackendSettingsProviding)? = nil
    ) {
        self.store = store
        self.vault = vault
        self.externallyProvisionedKinds = externallyProvisionedKinds
        self.credentialSourceDirectories = credentialSourceDirectories
        self.managedCodexCredentialSource = managedCodexCredentialSource
        self.managedCodexRuntimeHome = managedCodexRuntimeHome
        self.backendSettings = backendSettings
    }

    public func environment(for kind: ProviderKind, model: String?, policy: ProviderExecutionPolicy) async throws -> [String: String] {
        let providerID: ProviderSettingsID
        if kind == .claudeCompatible,
           let rawBackend = policy.providerSettings["claude.backendID"],
           let backendID = ProviderSettingsID(rawValue: rawBackend),
           [.claudeGLM, .claudeKimi, .claudeCustom].contains(backendID)
        {
            providerID = backendID
        } else if let canonical = Self.providerID(kind) {
            providerID = canonical
        } else {
            return [:]
        }
        guard let stored = try await store.providerConnection(providerID: providerID) else {
            if [.claudeGLM, .claudeKimi, .claudeCustom].contains(providerID) {
                throw ServiceAPIError(code: .providerUnavailable, message: "Claude-compatible backend credential is not configured")
            }
            guard externallyProvisionedKinds.contains(kind) else {
                throw ServiceAPIError(code: .providerUnavailable, message: "Provider credential is not configured")
            }
            return [:]
        }
        // Linux server readiness — not Desktop's UserDefaults configured latch
        // (`ClaudeCodeCompatibleBackendConfigured.<id>`). Desktop sets that
        // latch when a Keychain secret is saved. Linux keeps
        // `connected && testState == valid` as the catalog/launch predicate.
        // Do not invent a fake UserDefaults latch. Server-owned / dedicated
        // accounts, isolated HOME, and vault injection stay additive.
        guard stored.record.state == .connected,
              stored.record.testState == .valid,
              stored.record.expiresAt.map({ $0 > Date() }) ?? true
        else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Provider credential is not validated")
        }
        if providerID == .codex, stored.record.authenticationMethod == .deviceCodeBeta {
            guard managedCodexCredentialSource != nil else {
                throw ServiceAPIError(code: .providerUnavailable, message: "Managed Codex credential source is unavailable")
            }
            return [:]
        }
        guard let reference = stored.credentialReference else {
            guard externallyProvisionedKinds.contains(kind) else {
                throw ServiceAPIError(code: .providerUnavailable, message: "Provider credential source is unavailable")
            }
            return [:]
        }
        guard let vault else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Provider credential vault is unavailable")
        }
        let secret = try await vault.load(providerID: providerID, connectionID: reference)
        guard let value = String(data: secret, encoding: .utf8), !value.isEmpty else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Provider credential could not be injected")
        }
        if [.claudeGLM, .claudeKimi, .claudeCustom].contains(providerID) {
            guard let config = try await backendSettings?.backendSettings(for: providerID),
                  stored.record.authenticationMethod == config.authHeader.authenticationMethod
            else {
                throw ServiceAPIError(code: .providerUnavailable, message: "Claude-compatible backend settings do not match the stored connection")
            }
            return try ClaudeCompatibleLaunchResolver.resolve(
                settings: config,
                secret: value,
                requestedModel: model
            ).environmentOverrides
        }
        switch (providerID, stored.record.authenticationMethod) {
        case (.codex, .apiKey), (.codex, .enterpriseAccessToken): return ["OPENAI_API_KEY": value]
        case (.claudeCompatible, .apiKey): return ["ANTHROPIC_API_KEY": value]
        case (.claudeCompatible, .authToken): return ["ANTHROPIC_AUTH_TOKEN": value]
        case (.cursorACP, .apiKey): return ["CURSOR_API_KEY": value]
        case (.grokBuildACP, .apiKey): return ["XAI_API_KEY": value]
        default:
            throw ServiceAPIError(code: .providerUnavailable, message: "Provider credential method is not runtime-wired")
        }
    }

    public func sourceDirectory(for kind: ProviderKind) async throws -> String? {
        guard let providerID = Self.providerID(kind) else { return credentialSourceDirectories[kind] }
        if providerID == .codex {
            guard let stored = try await store.providerConnection(providerID: .codex),
                  stored.record.authenticationMethod == .deviceCodeBeta,
                  stored.record.state == .connected,
                  stored.record.testState == .valid
            else { return nil }
            guard let managedCodexCredentialSource else {
                throw ServiceAPIError(code: .providerUnavailable, message: "Managed Codex credential source is unavailable")
            }
            return managedCodexCredentialSource
        }
        return credentialSourceDirectories[kind]
    }

    public func persistentRuntimeEnvironment(for kind: ProviderKind) async throws -> [String: String]? {
        guard kind == .codex,
              let stored = try await store.providerConnection(providerID: .codex),
              stored.record.authenticationMethod == .deviceCodeBeta,
              stored.record.state == .connected,
              stored.record.testState == .valid,
              let managedCodexRuntimeHome
        else { return nil }
        return try managedCodexRuntimeHome.environment()
    }

    private nonisolated static func providerID(_ kind: ProviderKind) -> ProviderSettingsID? {
        switch kind {
        case .codex: .codex
        case .claudeCompatible: .claudeCompatible
        case .openCodeACP: .openCodeACP
        case .cursorACP: .cursorACP
        case .grokBuildACP: .grokBuildACP
        case .headlessAdapter, .mcp: nil
        }
    }
}

/// Provider-specific API-key validator. Credentials are sent only to fixed
/// provider HTTPS endpoints in request headers; response bodies and transport
/// diagnostics are discarded before returning a closed result.
public actor ProviderAuthenticationAdapter: ProviderCredentialTesting {
    private let configuredKinds: Set<ProviderKind>
    private let transport: any ProviderCredentialHTTPTransport
    private let backendSettings: (any ClaudeCompatibleBackendSettingsProviding)?

    public init(configurations: [ProviderCLIConfiguration], backendSettings: (any ClaudeCompatibleBackendSettingsProviding)? = nil) {
        configuredKinds = Set(configurations.map(\.kind))
        transport = URLSessionProviderCredentialHTTPTransport()
        self.backendSettings = backendSettings
    }

    init(configurations: [ProviderCLIConfiguration], transport: any ProviderCredentialHTTPTransport, backendSettings: (any ClaudeCompatibleBackendSettingsProviding)? = nil) {
        configuredKinds = Set(configurations.map(\.kind))
        self.transport = transport
        self.backendSettings = backendSettings
    }

    public func supportedAuthenticationMethods(for providerID: ProviderSettingsID) async -> Set<ProviderAuthenticationMethod> {
        switch providerID {
        case .codex:
            return configuredKinds.contains(.codex) ? Set([ProviderAuthenticationMethod.apiKey]) : []
        case .claudeCompatible:
            return configuredKinds.contains(.claudeCompatible) ? Set([ProviderAuthenticationMethod.apiKey]) : []
        case .claudeGLM, .claudeKimi:
            guard configuredKinds.contains(.claudeCompatible),
                  let config = try? await backendSettings?.backendSettings(for: providerID)
            else { return [] }
            return [config.authHeader.authenticationMethod]
        case .grokBuildACP:
            return configuredKinds.contains(.grokBuildACP) ? Set([ProviderAuthenticationMethod.apiKey]) : []
        case .claudeCustom, .openCodeACP, .cursorACP,
             .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            return []
        }
    }

    public func test(providerID: ProviderSettingsID, method: ProviderAuthenticationMethod, secret: Data?) async -> ProviderCredentialTestResult {
        guard await supportedAuthenticationMethods(for: providerID).contains(method) else {
            return .init(state: .unavailable, detail: "Provider credential validation is unavailable")
        }
        guard let secret,
              let value = String(data: secret, encoding: .utf8),
              !value.isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return .init(state: .invalid, detail: "Provider credential is invalid")
        }

        var request: URLRequest
        let acceptedDetail: String
        switch providerID {
        case .codex:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
            acceptedDetail = "OpenAI credential validated"
        case .claudeCompatible:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
            request.setValue(value, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            acceptedDetail = "Anthropic credential validated"
        case .grokBuildACP:
            request = URLRequest(url: URL(string: "https://api.x.ai/v1/models")!)
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
            acceptedDetail = "Grok credential validated"
        case .claudeGLM, .claudeKimi:
            guard let config = try? await backendSettings?.backendSettings(for: providerID),
                  let host = URLComponents(string: config.baseURL)?.host?.lowercased(),
                  (providerID == .claudeGLM && host == "api.z.ai") || (providerID == .claudeKimi && host == "api.kimi.com"),
                  let endpoint = URL(string: config.baseURL)?.appendingPathComponent("v1/messages")
            else { return .init(state: .unavailable, detail: "Compatible backend validation configuration is unavailable") }
            request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            switch config.authHeader {
            case .anthropicAPIKey: request.setValue(value, forHTTPHeaderField: "x-api-key")
            case .anthropicAuthToken: request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let model = providerID == .claudeGLM ? config.sonnetModel : "kimi-for-coding"
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "Reply OK"]]
            ])
            acceptedDetail = providerID == .claudeGLM ? "Z.ai credential validated" : "Kimi credential validated"
        case .claudeCustom, .openCodeACP, .cursorACP,
             .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            return .init(state: .unavailable, detail: "Provider credential validation is unavailable")
        }
        if request.httpMethod == nil { request.httpMethod = "GET" }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let status = try await transport.statusCode(for: request, timeout: .seconds(10))
            switch status {
            case 200 ..< 300:
                return .init(state: .valid, detail: acceptedDetail)
            case 401, 403:
                return .init(state: .invalid, detail: "Provider rejected the configured credential")
            default:
                return .init(state: .unavailable, detail: "Provider credential validation is temporarily unavailable")
            }
        } catch is CancellationError {
            return .init(state: .unavailable, detail: "Provider credential validation was cancelled")
        } catch {
            return .init(state: .unavailable, detail: "Provider credential validation is temporarily unavailable")
        }
    }

    public func logout(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod) async {}
}

public protocol ProviderAuthFlowDriving: Sendable {
    func start(providerID: ProviderSettingsID, kind: ProviderManagedAuthenticationFlowKind) async throws -> ProviderManagedAuthenticationTransaction
    func poll(flowID: UUID) async throws -> ProviderManagedAuthenticationTransaction
    func cancel(flowID: UUID) async
}

/// In-memory owner fence for device/browser authentication. No transaction,
/// code, URL, or process output is written to SQLite or the vault.
public actor TransientProviderAuthFlowCoordinator: ProviderAuthFlowCoordinating {
    private struct Transaction {
        let ownerID: String
        var status: ProviderManagedAuthenticationTransaction
    }

    private let driver: any ProviderAuthFlowDriving
    private let now: @Sendable () -> Date
    private let maximumTransactions: Int
    private var transactions: [UUID: Transaction] = [:]

    public init(driver: any ProviderAuthFlowDriving, now: @escaping @Sendable () -> Date = Date.init, maximumTransactions: Int = 128) {
        self.driver = driver
        self.now = now
        self.maximumTransactions = max(1, maximumTransactions)
    }

    public func start(providerID: ProviderSettingsID, kind: ProviderManagedAuthenticationFlowKind, ownerID: String) async throws -> ProviderManagedAuthenticationTransaction {
        let ownerID = try validatedOwnerID(ownerID)
        await pruneExpired()
        guard transactions.count < maximumTransactions else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Too many provider authentication transactions are active")
        }
        let returned = try await driver.start(providerID: providerID, kind: kind)
        guard returned.providerID == providerID,
              returned.kind == kind,
              returned.expiresAt > now(),
              transactions[returned.flowID] == nil
        else {
            await driver.cancel(flowID: returned.flowID)
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider authentication driver returned an invalid transaction")
        }
        let status = try sanitized(returned, fixedExpiration: returned.expiresAt)
        transactions[status.flowID] = Transaction(ownerID: ownerID, status: status)
        return status
    }

    public func poll(flowID: UUID, ownerID: String) async throws -> ProviderManagedAuthenticationTransaction {
        let ownerID = try validatedOwnerID(ownerID)
        guard var transaction = transactions[flowID], transaction.ownerID == ownerID else {
            throw ServiceAPIError(code: .notFound, message: "Provider authentication transaction was not found")
        }
        if transaction.status.expiresAt <= now() {
            transaction.status = .init(flowID: flowID, providerID: transaction.status.providerID, kind: transaction.status.kind, state: .expired, expiresAt: transaction.status.expiresAt, detail: "Authentication transaction expired")
            transactions[flowID] = nil
            await driver.cancel(flowID: flowID)
            return transaction.status
        }
        let returned = try await driver.poll(flowID: flowID)
        guard returned.flowID == flowID,
              returned.providerID == transaction.status.providerID,
              returned.kind == transaction.status.kind,
              returned.expiresAt <= transaction.status.expiresAt
        else {
            transactions[flowID] = nil
            await driver.cancel(flowID: flowID)
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider authentication driver returned an invalid transaction")
        }
        transaction.status = try sanitized(returned, fixedExpiration: transaction.status.expiresAt)
        transactions[flowID] = transaction.status.state == .pending ? transaction : nil
        return transaction.status
    }

    public func cancel(flowID: UUID, ownerID: String) async throws {
        let ownerID = try validatedOwnerID(ownerID)
        guard let transaction = transactions[flowID], transaction.ownerID == ownerID else {
            throw ServiceAPIError(code: .notFound, message: "Provider authentication transaction was not found")
        }
        transactions[flowID] = nil
        await driver.cancel(flowID: flowID)
    }

    private func sanitized(_ status: ProviderManagedAuthenticationTransaction, fixedExpiration: Date) throws -> ProviderManagedAuthenticationTransaction {
        let terminal = status.state != .pending
        let userCode = try terminal ? nil : sanitizedUserCode(status.userCode)
        let verificationURL = try terminal ? nil : sanitizedVerificationURL(status.verificationURL)
        return .init(
            flowID: status.flowID,
            providerID: status.providerID,
            kind: status.kind,
            state: status.state,
            userCode: userCode,
            verificationURL: verificationURL,
            expiresAt: fixedExpiration,
            detail: sanitizedDetail(status.detail)
        )
    }

    private func validatedOwnerID(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              trimmed.utf8.count <= 256,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider authentication owner is invalid")
        }
        return trimmed
    }

    private func sanitizedUserCode(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard value.utf8.count <= 64,
              value.range(of: "^[A-Za-z0-9 -]+$", options: .regularExpression) != nil
        else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider authentication driver returned an invalid user code")
        }
        return value
    }

    private func sanitizedVerificationURL(_ value: URL?) throws -> URL? {
        guard let value else { return nil }
        guard value.scheme?.lowercased() == "https",
              value.host?.isEmpty == false,
              value.user == nil,
              value.password == nil,
              value.absoluteString.utf8.count <= 2048
        else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider authentication driver returned an invalid verification URL")
        }
        return value
    }

    private func sanitizedDetail(_ value: String?) -> String? {
        guard let value else { return nil }
        let redacted = ProviderSecretRedaction.redact(value)
        let allowedScalars = redacted.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let sanitized = String(String.UnicodeScalarView(allowedScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : String(sanitized.prefix(256))
    }

    private func pruneExpired() async {
        let expired = transactions.compactMap { key, value in value.status.expiresAt <= now() ? key : nil }
        for flowID in expired {
            transactions[flowID] = nil
            await driver.cancel(flowID: flowID)
        }
    }
}
