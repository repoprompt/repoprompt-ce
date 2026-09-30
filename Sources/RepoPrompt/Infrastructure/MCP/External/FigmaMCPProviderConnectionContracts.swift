import Foundation

enum FigmaMCPProviderCredentialContext: String, Codable, CaseIterable, Equatable, Hashable {
    /// The provider's ordinary user profile. No path, account, token, or environment value is
    /// represented by this enum.
    case providerDefaultUserProfile
}

enum FigmaMCPProviderTargetSource: String, Codable, CaseIterable, Equatable, Hashable {
    case reviewedFixedIdentifier
    case providerStandardUserMetadata
}

enum FigmaMCPProviderTargetMissingReason: String, Codable, Equatable, Hashable {
    case noCanonicalMatch
    case unsupportedProviderContext
    case unavailableProviderMetadata
}

enum FigmaMCPProviderUntrustedCredentialContextReason: String, Codable, Equatable, Hashable {
    case customHomeOrConfig
    case compatibleBackendOverride
    case unknownCredentialStore
}

/// A provider-owned target lookup never returns secrets or filesystem locations.
enum FigmaMCPProviderTargetResolution: Equatable {
    case resolved(
        providerTargetIdentifier: String,
        source: FigmaMCPProviderTargetSource,
        credentialContext: FigmaMCPProviderCredentialContext
    )
    case missing(reason: FigmaMCPProviderTargetMissingReason)
    case ambiguous(matchCount: Int)
    case untrustedCredentialContext(reason: FigmaMCPProviderUntrustedCredentialContextReason)
}

protocol FigmaMCPProviderTargetResolving: Sendable {
    var runtimeProvider: ExternalMCPRuntimeProvider { get }

    func resolveTarget(
        for target: ExternalMCPIntegrationTarget
    ) async -> FigmaMCPProviderTargetResolution
}

struct FigmaMCPProviderCapabilityEvidence: Equatable, Hashable {
    let provider: ExternalMCPRuntimeProvider
    let evidenceID: String
    let capabilityRevision: String
}

enum FigmaMCPProviderCapabilityReason: String, Codable, CaseIterable, Equatable, Hashable {
    case liveGatePending
    case noStructuredProofContract
    case noRevocationContract
    case noRuntimeBindingContract
    case unsupportedProviderRoute
}

enum FigmaMCPProviderCapabilitySupport: Equatable, Hashable {
    case codexManaged
    case verified(FigmaMCPProviderCapabilityEvidence)
    case unverified(FigmaMCPProviderCapabilityReason)
    case unsupported(FigmaMCPProviderCapabilityReason)

    var isAuthorityEnabled: Bool {
        switch self {
        case .codexManaged, .verified:
            true
        case .unverified, .unsupported:
            false
        }
    }

    var evidence: FigmaMCPProviderCapabilityEvidence? {
        guard case let .verified(evidence) = self else { return nil }
        return evidence
    }
}

struct FigmaMCPProviderCapabilityRegistration: Equatable {
    let provider: ExternalMCPRuntimeProvider
    let loginSupport: FigmaMCPProviderCapabilitySupport
    let proofSupport: FigmaMCPProviderCapabilitySupport
    let revocationSupport: FigmaMCPProviderCapabilitySupport
    let runtimeBindingSupport: FigmaMCPProviderCapabilitySupport

    static func adapterOnly(for provider: ExternalMCPRuntimeProvider) -> Self {
        Self(
            provider: provider,
            loginSupport: .unverified(.liveGatePending),
            proofSupport: .unverified(.noStructuredProofContract),
            revocationSupport: .unverified(.noRevocationContract),
            runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
        )
    }
}

/// A login attempt context is intentionally nonsecret and is defined here so later subprocess
/// infrastructure can be added without changing the registry's authority model.
struct FigmaMCPProviderLoginAttemptContext: Equatable {
    let provider: ExternalMCPRuntimeProvider
    let target: ExternalMCPIntegrationTarget
    let providerTargetIdentifier: String
    let credentialContext: FigmaMCPProviderCredentialContext
    let attemptID: UUID
    let evidenceID: String
    let capabilityRevision: String
    let executableIdentity: String
    let executableVersion: String?
    let operationGeneration: UInt64

    init(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget,
        providerTargetIdentifier: String,
        credentialContext: FigmaMCPProviderCredentialContext,
        attemptID: UUID = UUID(),
        evidenceID: String,
        capabilityRevision: String,
        executableIdentity: String,
        executableVersion: String? = nil,
        operationGeneration: UInt64 = 0
    ) {
        self.provider = provider
        self.target = target
        self.providerTargetIdentifier = providerTargetIdentifier
        self.credentialContext = credentialContext
        self.attemptID = attemptID
        self.evidenceID = evidenceID
        self.capabilityRevision = capabilityRevision
        self.executableIdentity = executableIdentity
        self.executableVersion = executableVersion
        self.operationGeneration = operationGeneration
    }
}

enum FigmaMCPProviderLoginAvailability: Equatable {
    case available
    case missingTarget(FigmaMCPProviderTargetMissingReason)
    case ambiguousTarget(Int)
    case unavailable(String)
    case untrustedCredentialContext(FigmaMCPProviderUntrustedCredentialContextReason)
}

enum FigmaMCPProviderLoginSettlement: Equatable {
    case exited(status: Int32)
    /// The dedicated visible authorization session disappeared before its command settled.
    case authorizationSessionClosed
    case launchFailed
    case timedOut
    case cancelled
    /// Another app-local login attempt already owns this provider's subprocess lease.
    case busy
}

/// The provider's structured status answer. A negative answer is deliberately distinct from an
/// unknown answer: only an explicit unauthenticated/expired result can tell Settings that login is
/// required. Unknown, stale, and process-only observations remain unverified.
enum FigmaMCPProviderStructuredStatusOutcome: Equatable {
    case verified(FigmaMCPVerifiedProviderStatus)
    case unauthenticated
    case expired
    case unknown
    case stale
}

typealias FigmaMCPStructuredStatusOutcome = FigmaMCPProviderStructuredStatusOutcome
typealias FigmaMCPStructuredProofOutcome = FigmaMCPProviderStructuredStatusOutcome

/// This protocol describes provider-owned login only. It does not imply proof, revocation, or
/// runtime authority, and it owns no callback, token, or credential data in RepoPrompt.
protocol FigmaMCPProviderLoginDriving: Sendable {
    var runtimeProvider: ExternalMCPRuntimeProvider { get }

    func evaluateAvailability(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget
    ) async -> FigmaMCPProviderLoginAvailability

    func beginLogin(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget,
        attemptContext: FigmaMCPProviderLoginAttemptContext
    ) async -> FigmaMCPProviderLoginSettlement

    func cancelLogin(
        provider: ExternalMCPRuntimeProvider,
        attemptID: UUID
    ) async
}

/// Process-local, non-Codable proof. A provider must supply this through an explicitly registered
/// structured checker; process exit, config presence, and free-form terminal output cannot create it.
struct FigmaMCPVerifiedProviderStatus: Equatable {
    let runtimeProvider: ExternalMCPRuntimeProvider
    let canonicalTarget: ExternalMCPIntegrationTarget
    let providerTargetIdentifier: String
    let credentialContext: FigmaMCPProviderCredentialContext
    let sanitizedSnapshot: ExternalMCPRuntimeSnapshot
    let evidenceID: String
    let capabilityRevision: String
    /// Optional echo fields let a checker bind proof to the exact executable it observed. The
    /// coordinator also fences these values against the live driver before publication.
    let executableIdentity: String?
    let executableVersion: String?
    let observedAt: Date
    let validUntil: Date
    let operationGeneration: UInt64

    init(
        runtimeProvider: ExternalMCPRuntimeProvider,
        canonicalTarget: ExternalMCPIntegrationTarget,
        providerTargetIdentifier: String,
        credentialContext: FigmaMCPProviderCredentialContext,
        sanitizedSnapshot: ExternalMCPRuntimeSnapshot,
        evidenceID: String,
        capabilityRevision: String,
        executableIdentity: String? = nil,
        executableVersion: String? = nil,
        observedAt: Date = Date(),
        validUntil: Date? = nil,
        operationGeneration: UInt64 = 0
    ) {
        self.runtimeProvider = runtimeProvider
        self.canonicalTarget = canonicalTarget
        self.providerTargetIdentifier = providerTargetIdentifier
        self.credentialContext = credentialContext
        self.sanitizedSnapshot = sanitizedSnapshot
        self.evidenceID = evidenceID
        self.capabilityRevision = capabilityRevision
        self.executableIdentity = executableIdentity
        self.executableVersion = executableVersion
        self.observedAt = observedAt
        self.validUntil = validUntil ?? observedAt.addingTimeInterval(60)
        self.operationGeneration = operationGeneration
    }
}

typealias FigmaMCPStructuredProofChecker = @Sendable (
    ExternalMCPIntegrationTarget,
    FigmaMCPProviderTargetResolution,
    ExternalMCPProviderRuntimeContext,
    UInt64
) async -> FigmaMCPVerifiedProviderStatus?

typealias FigmaMCPStructuredStatusChecker = @Sendable (
    ExternalMCPIntegrationTarget,
    FigmaMCPProviderTargetResolution,
    ExternalMCPProviderRuntimeContext,
    UInt64
) async -> FigmaMCPProviderStructuredStatusOutcome

struct ExternalMCPProviderRegistration {
    let provider: ExternalMCPRuntimeProvider
    let adapter: any ExternalMCPProviderAdapter
    let figmaCapabilities: FigmaMCPProviderCapabilityRegistration
    let targetResolver: (any FigmaMCPProviderTargetResolving)?
    let loginDriver: (any FigmaMCPProviderLoginDriving)?
    /// Compatibility proof closure. New registrations should use `structuredStatusChecker` so
    /// unauthenticated and expired answers remain typed rather than collapsing into nil.
    let structuredProofChecker: FigmaMCPStructuredProofChecker?
    let structuredStatusChecker: FigmaMCPStructuredStatusChecker?

    init(
        provider: ExternalMCPRuntimeProvider,
        adapter: any ExternalMCPProviderAdapter,
        figmaCapabilities: FigmaMCPProviderCapabilityRegistration,
        targetResolver: (any FigmaMCPProviderTargetResolving)? = nil,
        loginDriver: (any FigmaMCPProviderLoginDriving)? = nil,
        structuredProofChecker: FigmaMCPStructuredProofChecker? = nil,
        structuredStatusChecker: FigmaMCPStructuredStatusChecker? = nil
    ) {
        self.provider = provider
        self.adapter = adapter
        self.figmaCapabilities = figmaCapabilities
        self.targetResolver = targetResolver
        self.loginDriver = loginDriver
        self.structuredProofChecker = structuredProofChecker
        self.structuredStatusChecker = structuredStatusChecker
    }

    /// Convenience spelling for callers using the design's longer name.
    var figmaCapabilityRegistration: FigmaMCPProviderCapabilityRegistration {
        figmaCapabilities
    }
}
