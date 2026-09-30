import Foundation

/// Stable, nonsecret identity for an external MCP integration.
typealias ExternalMCPIntegrationID = String

/// Canonical, nonpersisted target identity. This remains available even when the shared Figma
/// definition is absent; the definition is activation metadata, not provider authentication proof.
enum ExternalMCPIntegrationTarget: String, Codable, CaseIterable, Equatable, Hashable {
    case figma

    var integrationID: ExternalMCPIntegrationID {
        "figma:figma"
    }
}

/// Provider-neutral display metadata. This is presentation data, never provider configuration.
struct ExternalMCPIntegrationDisplayMetadata: Codable, Equatable, Hashable {
    let title: String
    let subtitle: String?
    let iconName: String?

    init(title: String, subtitle: String? = nil, iconName: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
    }
}

extension ExternalMCPIntegrationTarget {
    init?(definition: ExternalMCPIntegrationDefinition) {
        guard definition.isSupportedDefinition else { return nil }
        self = .figma
    }
}

extension ExternalMCPIntegrationDefinition {
    /// Compatibility projection from the persisted definition to the canonical runtime target.
    var externalMCPTarget: ExternalMCPIntegrationTarget? {
        ExternalMCPIntegrationTarget(definition: self)
    }

    var canonicalExternalMCPTarget: ExternalMCPIntegrationTarget? {
        externalMCPTarget
    }

    /// The current Figma definition predates an explicit ID, so its canonical provider/server
    /// identity is used as a stable compatibility projection.
    var integrationID: ExternalMCPIntegrationID {
        "\(provider.rawValue):\(serverName)"
    }

    var displayMetadata: ExternalMCPIntegrationDisplayMetadata {
        switch provider {
        case .figma:
            ExternalMCPIntegrationDisplayMetadata(
                title: "Figma",
                subtitle: "External MCP integration",
                iconName: "rectangle.3.group"
            )
        }
    }
}

/// Runtime/provider identity is deliberately separate from the persisted integration identity
/// (`ExternalMCPIntegrationProvider.figma`). One integration may be routed through several
/// provider runtimes without sharing authentication or configuration ownership.
enum ExternalMCPRuntimeProvider: String, Codable, CaseIterable, Equatable, Hashable {
    case codex
    case claudeCode
    case openCode
    case cursor
    case grokBuild
    case devin
    case antigravity
}

enum ExternalMCPRuntimeKind: String, Codable, Equatable, Hashable {
    case nativeCLI
    case appServer
    case headlessCLI
    case acp
    case discovery
    case unknown
}

enum ExternalMCPSessionClass: String, Codable, Equatable, Hashable {
    case topLevel
    case managedChild
    case providerNativeChild
    case headless
    case cloudChild
    case discovery
}

enum ExternalMCPIsolationMode: String, Codable, Equatable, Hashable {
    case ceIsolated
    case userNative
    case unknown
}

enum ExternalMCPEnvironmentRemovalPolicy: String, Codable, Equatable, Hashable {
    case none
    case providerCredentialLikeKeys
    case allProviderCredentialLikeKeys
}

struct ExternalMCPProviderRuntimeIdentity: Codable, Equatable, Hashable {
    let provider: ExternalMCPRuntimeProvider
    let runtimeKind: ExternalMCPRuntimeKind
    let executableIdentity: String
    let executableVersion: String?

    init(
        provider: ExternalMCPRuntimeProvider,
        runtimeKind: ExternalMCPRuntimeKind,
        executableIdentity: String,
        executableVersion: String? = nil
    ) {
        self.provider = provider
        self.runtimeKind = runtimeKind
        self.executableIdentity = executableIdentity
        self.executableVersion = executableVersion
    }
}

/// Explicit inputs for an adapter call. Adapters must not infer these from global process state.
struct ExternalMCPProviderRuntimeContext: Equatable {
    let identity: ExternalMCPProviderRuntimeIdentity
    let sessionClass: ExternalMCPSessionClass
    let workspaceID: UUID?
    let sessionID: UUID?
    let isolation: ExternalMCPIsolationMode
    let homePath: String?
    let configPath: String?
    let dataPath: String?
    let environmentRemovalPolicy: ExternalMCPEnvironmentRemovalPolicy
    let processOwner: String?
    let coordinatorRevision: UInt64
    let cancellationToken: ExternalMCPCancellationToken

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity
            && lhs.sessionClass == rhs.sessionClass
            && lhs.workspaceID == rhs.workspaceID
            && lhs.sessionID == rhs.sessionID
            && lhs.isolation == rhs.isolation
            && lhs.homePath == rhs.homePath
            && lhs.configPath == rhs.configPath
            && lhs.dataPath == rhs.dataPath
            && lhs.environmentRemovalPolicy == rhs.environmentRemovalPolicy
            && lhs.processOwner == rhs.processOwner
            && lhs.coordinatorRevision == rhs.coordinatorRevision
    }

    init(
        identity: ExternalMCPProviderRuntimeIdentity,
        sessionClass: ExternalMCPSessionClass,
        workspaceID: UUID? = nil,
        sessionID: UUID? = nil,
        isolation: ExternalMCPIsolationMode = .unknown,
        homePath: String? = nil,
        configPath: String? = nil,
        dataPath: String? = nil,
        environmentRemovalPolicy: ExternalMCPEnvironmentRemovalPolicy = .none,
        processOwner: String? = nil,
        coordinatorRevision: UInt64 = 0,
        cancellationToken: ExternalMCPCancellationToken = ExternalMCPCancellationToken()
    ) {
        self.identity = identity
        self.sessionClass = sessionClass
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.isolation = isolation
        self.homePath = homePath
        self.configPath = configPath
        self.dataPath = dataPath
        self.environmentRemovalPolicy = environmentRemovalPolicy
        self.processOwner = processOwner
        self.coordinatorRevision = coordinatorRevision
        self.cancellationToken = cancellationToken
    }
}

/// Injectable cancellation token for adapter tests; it carries no provider state.
final class ExternalMCPCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
