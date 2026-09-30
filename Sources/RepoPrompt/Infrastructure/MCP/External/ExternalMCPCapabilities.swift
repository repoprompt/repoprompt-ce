import Foundation

enum ExternalMCPCapabilitySupport: String, Codable, Equatable {
    case supported
    case unsupported
    case providerNative
    case requiresPersistentApproval
    case indeterminate
}

enum ExternalMCPCapability: String, Codable, CaseIterable {
    case discovery
    case interactiveAuthentication
    case statusVerification
    case managedConfigurationInstallation
    case adoptedImport
    case credentialLogout
    case runtimeInjection
    case childSessionInheritance
}

/// Generic adapter capabilities describe plumbing only. They are not Settings authority for
/// provider-native Figma login, proof, revocation, or runtime binding; those axes are represented
/// by `FigmaMCPProviderCapabilityRegistration` and must be checked independently.
struct ExternalMCPCapabilityDescriptor: Codable, Equatable {
    let discovery: ExternalMCPCapabilitySupport
    let interactiveAuthentication: ExternalMCPCapabilitySupport
    let statusVerification: ExternalMCPCapabilitySupport
    let managedConfigurationInstallation: ExternalMCPCapabilitySupport
    let adoptedImport: ExternalMCPCapabilitySupport
    let credentialLogout: ExternalMCPCapabilitySupport
    let runtimeInjection: ExternalMCPCapabilitySupport
    let childSessionInheritance: ExternalMCPCapabilitySupport

    init(
        discovery: ExternalMCPCapabilitySupport = .unsupported,
        interactiveAuthentication: ExternalMCPCapabilitySupport = .unsupported,
        statusVerification: ExternalMCPCapabilitySupport = .unsupported,
        managedConfigurationInstallation: ExternalMCPCapabilitySupport = .unsupported,
        adoptedImport: ExternalMCPCapabilitySupport = .unsupported,
        credentialLogout: ExternalMCPCapabilitySupport = .unsupported,
        runtimeInjection: ExternalMCPCapabilitySupport = .unsupported,
        childSessionInheritance: ExternalMCPCapabilitySupport = .unsupported
    ) {
        self.discovery = discovery
        self.interactiveAuthentication = interactiveAuthentication
        self.statusVerification = statusVerification
        self.managedConfigurationInstallation = managedConfigurationInstallation
        self.adoptedImport = adoptedImport
        self.credentialLogout = credentialLogout
        self.runtimeInjection = runtimeInjection
        self.childSessionInheritance = childSessionInheritance
    }

    static let unsupported = Self()

    func support(for capability: ExternalMCPCapability) -> ExternalMCPCapabilitySupport {
        switch capability {
        case .discovery: discovery
        case .interactiveAuthentication: interactiveAuthentication
        case .statusVerification: statusVerification
        case .managedConfigurationInstallation: managedConfigurationInstallation
        case .adoptedImport: adoptedImport
        case .credentialLogout: credentialLogout
        case .runtimeInjection: runtimeInjection
        case .childSessionInheritance: childSessionInheritance
        }
    }
}

enum ExternalMCPAccessDecisionReason: String, Codable, Equatable {
    case granted
    case noDefinition
    case disabled
    case unauthenticated
    case unavailable
    case unsupported
    case staleRevision
    case unsupportedSessionClass
    case explicitlyDenied
    case cancelled
}

struct ExternalMCPAccessDecision: Codable, Equatable {
    let integrationID: ExternalMCPIntegrationID
    let runtimeIdentity: ExternalMCPProviderRuntimeIdentity
    let revision: UInt64
    let isAllowed: Bool
    let reason: ExternalMCPAccessDecisionReason
    /// The sanitized runtime state evaluated for an allowed decision. This proof prevents an
    /// adapter from authorizing a later, unrelated service snapshot.
    let verifiedSnapshot: ExternalMCPRuntimeSnapshot?

    init(
        integrationID: ExternalMCPIntegrationID,
        runtimeIdentity: ExternalMCPProviderRuntimeIdentity,
        revision: UInt64,
        isAllowed: Bool,
        reason: ExternalMCPAccessDecisionReason,
        verifiedSnapshot: ExternalMCPRuntimeSnapshot? = nil
    ) {
        self.integrationID = integrationID
        self.runtimeIdentity = runtimeIdentity
        self.revision = revision
        self.isAllowed = isAllowed
        self.reason = isAllowed ? .granted : reason
        self.verifiedSnapshot = verifiedSnapshot
    }

    static func denied(
        integrationID: ExternalMCPIntegrationID,
        runtimeIdentity: ExternalMCPProviderRuntimeIdentity,
        revision: UInt64,
        reason: ExternalMCPAccessDecisionReason = .unavailable,
        verifiedSnapshot: ExternalMCPRuntimeSnapshot? = nil
    ) -> Self {
        Self(
            integrationID: integrationID,
            runtimeIdentity: runtimeIdentity,
            revision: revision,
            isAllowed: false,
            reason: reason,
            verifiedSnapshot: verifiedSnapshot
        )
    }
}
