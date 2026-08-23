import Foundation

public enum DomainClientPrincipalKind: String, Codable, CaseIterable, Sendable {
    case appProxy = "app_proxy"
    case directStdio = "direct_stdio"
    case runScoped = "run_scoped"
    case ttyAdministrator = "tty_administrator"
}

public enum DomainClientPrincipalAssurance: String, Codable, CaseIterable, Sendable {
    case displayNameOnly = "display_name_only"
    case verifiedProcess = "verified_process"
    case hostLaunchToken = "host_launch_token"
    case localTTY = "local_tty"
}

public struct DomainClientPrincipal: Codable, Hashable, Sendable {
    public let principalID: UUID
    public let stableKey: String?
    public let displayName: String
    public let kind: DomainClientPrincipalKind
    public let assurance: DomainClientPrincipalAssurance
    /// Kernel-observed process identifier eligible for verified-process assurance.
    public let processID: Int32?
    /// Client-declared handshake metadata. Never grants authority.
    public let claimedProcessID: Int32?
    public let runID: UUID?
    public let provider: String?
    /// Kernel-derived executable identity. Display names and provider labels are never grant authority.
    public let verifiedIdentityFingerprint: String?

    public init(
        principalID: UUID,
        stableKey: String?,
        displayName: String,
        kind: DomainClientPrincipalKind,
        assurance: DomainClientPrincipalAssurance,
        processID: Int32?,
        runID: UUID?,
        provider: String?,
        verifiedIdentityFingerprint: String? = nil,
        claimedProcessID: Int32? = nil
    ) {
        self.principalID = principalID
        self.stableKey = stableKey
        self.displayName = displayName
        self.kind = kind
        self.assurance = assurance
        self.processID = processID
        self.claimedProcessID = claimedProcessID
        self.runID = runID
        self.provider = provider
        self.verifiedIdentityFingerprint = verifiedIdentityFingerprint
    }
}

public struct DomainToolInvocationSecurityContext: Hashable, Sendable {
    /// Authoritative server-owned durable request namespace. Public operation_id remains correlation-only.
    public static func durableMutationRequestKey(
        connectionID: UUID,
        connectionGeneration: UInt64,
        invocationID: UUID
    ) -> String {
        [
            "v1",
            connectionID.uuidString.lowercased(),
            String(connectionGeneration),
            invocationID.uuidString.lowercased()
        ].joined(separator: ":")
    }

    public let principal: DomainClientPrincipal
    public let connectionID: UUID
    public let connectionGeneration: UInt64
    public let invocationID: UUID
    /// Server-owned request identity used for journal dedupe. Public operation_id remains correlation-only.
    public private(set) var mutationRequestKey: String
    public let runtimeID: UUID
    public let runtimeGeneration: UInt64
    public let workspaceID: UUID?
    public let workspaceRevision: UInt64?
    public let authorizedCanonicalRoots: Set<String>
    /// False when no authoritative routing registration/context could be resolved.
    public let hasAuthoritativeRoutingContext: Bool
    public let ephemeralGrantedToolNames: Set<String>
    /// Exact `tool.action` grants for invocation classes whose safe defaults are narrower than a whole tool.
    public let ephemeralGrantedOperations: Set<String>

    public init(
        principal: DomainClientPrincipal,
        connectionID: UUID,
        connectionGeneration: UInt64,
        invocationID: UUID,
        runtimeID: UUID,
        runtimeGeneration: UInt64,
        workspaceID: UUID? = nil,
        workspaceRevision: UInt64? = nil,
        authorizedCanonicalRoots: Set<String> = [],
        hasAuthoritativeRoutingContext: Bool = true,
        ephemeralGrantedToolNames: Set<String>,
        ephemeralGrantedOperations: Set<String> = []
    ) {
        self.principal = principal
        self.connectionID = connectionID
        self.connectionGeneration = connectionGeneration
        self.invocationID = invocationID
        self.mutationRequestKey = Self.durableMutationRequestKey(
            connectionID: connectionID,
            connectionGeneration: connectionGeneration,
            invocationID: invocationID
        )
        self.runtimeID = runtimeID
        self.runtimeGeneration = runtimeGeneration
        self.workspaceID = workspaceID
        self.workspaceRevision = workspaceRevision
        self.authorizedCanonicalRoots = authorizedCanonicalRoots
        self.hasAuthoritativeRoutingContext = hasAuthoritativeRoutingContext
        self.ephemeralGrantedToolNames = ephemeralGrantedToolNames
        self.ephemeralGrantedOperations = ephemeralGrantedOperations
    }

    #if DEBUG
        /// Journal-unit-test escape hatch. Production/package callers cannot replace authoritative request identity.
        internal mutating func overrideMutationRequestKeyForTesting(_ mutationRequestKey: String) {
            self.mutationRequestKey = mutationRequestKey
        }
    #endif
}

public enum MCPDomainInvocationSecurityContext {
    @TaskLocal public static var current: DomainToolInvocationSecurityContext?
}
