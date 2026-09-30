import Foundation

/// Static adapter composition. There is no dynamic loading or runtime package discovery. A verified
/// registration may be replaced only through the explicit replacement seam, which advances the
/// neutral authorization revision.
///
/// Adapter-only construction and registration remain source-compatible. Those compatibility paths
/// deliberately receive unverified Figma capability axes rather than inheriting authority from a
/// generic adapter.
final class ExternalMCPAdapterRegistry: @unchecked Sendable {
    enum RegistrationError: Error, Equatable {
        case duplicateProvider(ExternalMCPRuntimeProvider)
        case providerMismatch(
            registration: ExternalMCPRuntimeProvider,
            adapter: ExternalMCPRuntimeProvider
        )
        case capabilityProviderMismatch(
            registration: ExternalMCPRuntimeProvider,
            capability: ExternalMCPRuntimeProvider
        )
        case evidenceProviderMismatch(
            registration: ExternalMCPRuntimeProvider,
            evidence: ExternalMCPRuntimeProvider
        )
        case invalidEvidence(ExternalMCPRuntimeProvider)
        case loginDriverProviderMismatch(
            registration: ExternalMCPRuntimeProvider,
            driver: ExternalMCPRuntimeProvider
        )
        case targetResolverProviderMismatch(
            registration: ExternalMCPRuntimeProvider,
            resolver: ExternalMCPRuntimeProvider
        )
        case verifiedLoginRequiresDriver(ExternalMCPRuntimeProvider)
        case verifiedLoginRequiresTargetResolver(ExternalMCPRuntimeProvider)
        case verifiedProofRequiresChecker(ExternalMCPRuntimeProvider)
        case verifiedProofRequiresTargetResolver(ExternalMCPRuntimeProvider)
        case verifiedRuntimeBindingRequiresProof(ExternalMCPRuntimeProvider)
        case verifiedRuntimeBindingRequiresVerifiedRevocation(ExternalMCPRuntimeProvider)
        case codexManagedRuntimeBindingRequiresCodexManagedRevocation(ExternalMCPRuntimeProvider)
        case replacementRequiresExistingProvider(ExternalMCPRuntimeProvider)
        case nonCodexCodexManagedCapability(ExternalMCPRuntimeProvider)
    }

    private let lock = NSLock()
    private var registrations: [ExternalMCPRuntimeProvider: ExternalMCPProviderRegistration]
    private var registrationReplacementHandler: (@Sendable (ExternalMCPRuntimeProvider) -> Void)?

    /// The handler is a synchronous, non-reentrant invalidation hook. It is invoked while the
    /// registry lock is held by `replace(_:)`; it must not call back into this registry.
    var onRegistrationReplacement: (@Sendable (ExternalMCPRuntimeProvider) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return registrationReplacementHandler
        }
        set {
            lock.lock()
            registrationReplacementHandler = newValue
            lock.unlock()
        }
    }

    init(adapters: [ExternalMCPRuntimeProvider: any ExternalMCPProviderAdapter] = [:]) {
        registrations = adapters.reduce(into: [:]) { result, entry in
            let (provider, adapter) = entry
            guard provider == adapter.runtimeProvider else { return }
            result[provider] = ExternalMCPProviderRegistration(
                provider: provider,
                adapter: adapter,
                figmaCapabilities: .adapterOnly(for: provider)
            )
        }
    }

    convenience init(registrations: [ExternalMCPProviderRegistration]) throws {
        self.init()
        for registration in registrations {
            try register(registration)
        }
    }

    /// A throwing initializer for composition/tests that need dictionary-key validation. The
    /// original `init(adapters:)` remains nonthrowing for source compatibility.
    convenience init(validatingAdapters adapters: [ExternalMCPRuntimeProvider: any ExternalMCPProviderAdapter]) throws {
        self.init()
        for (provider, adapter) in adapters {
            guard provider == adapter.runtimeProvider else {
                throw RegistrationError.providerMismatch(registration: provider, adapter: adapter.runtimeProvider)
            }
            try register(adapter)
        }
    }

    func register(_ adapter: any ExternalMCPProviderAdapter) throws {
        try register(
            ExternalMCPProviderRegistration(
                provider: adapter.runtimeProvider,
                adapter: adapter,
                figmaCapabilities: .adapterOnly(for: adapter.runtimeProvider)
            )
        )
    }

    func register(_ registration: ExternalMCPProviderRegistration) throws {
        try validate(registration)
        lock.lock()
        defer { lock.unlock() }
        guard registrations[registration.provider] == nil else {
            throw RegistrationError.duplicateProvider(registration.provider)
        }
        registrations[registration.provider] = registration
    }

    /// Replaces a live provider registration and invalidates any proof issued by the prior one.
    /// The replacement handler runs synchronously under the same lock, so readers cannot observe
    /// the new registration until its revision invalidation has completed.
    func replace(_ registration: ExternalMCPProviderRegistration) throws {
        try validate(registration)
        lock.lock()
        defer { lock.unlock() }
        guard registrations[registration.provider] != nil else {
            throw RegistrationError.replacementRequiresExistingProvider(registration.provider)
        }
        registrations[registration.provider] = registration
        registrationReplacementHandler?(registration.provider)
    }

    func adapter(for provider: ExternalMCPRuntimeProvider) -> (any ExternalMCPProviderAdapter)? {
        lock.lock()
        defer { lock.unlock() }
        return registrations[provider]?.adapter
    }

    func registration(for provider: ExternalMCPRuntimeProvider) -> ExternalMCPProviderRegistration? {
        lock.lock()
        defer { lock.unlock() }
        return registrations[provider]
    }

    var registeredProviders: Set<ExternalMCPRuntimeProvider> {
        lock.lock()
        defer { lock.unlock() }
        return Set(registrations.keys)
    }

    private func validate(_ registration: ExternalMCPProviderRegistration) throws {
        guard registration.provider == registration.adapter.runtimeProvider else {
            throw RegistrationError.providerMismatch(
                registration: registration.provider,
                adapter: registration.adapter.runtimeProvider
            )
        }
        guard registration.provider == registration.figmaCapabilities.provider else {
            throw RegistrationError.capabilityProviderMismatch(
                registration: registration.provider,
                capability: registration.figmaCapabilities.provider
            )
        }
        if let loginDriver = registration.loginDriver,
           loginDriver.runtimeProvider != registration.provider
        {
            throw RegistrationError.loginDriverProviderMismatch(
                registration: registration.provider,
                driver: loginDriver.runtimeProvider
            )
        }
        let capabilitySupports = [
            registration.figmaCapabilities.loginSupport,
            registration.figmaCapabilities.proofSupport,
            registration.figmaCapabilities.revocationSupport,
            registration.figmaCapabilities.runtimeBindingSupport
        ]
        if registration.provider != .codex,
           capabilitySupports.contains(where: { if case .codexManaged = $0 { true } else { false } })
        {
            throw RegistrationError.nonCodexCodexManagedCapability(registration.provider)
        }
        for support in capabilitySupports {
            guard case let .verified(evidence) = support else { continue }
            guard evidence.provider == registration.provider else {
                throw RegistrationError.evidenceProviderMismatch(
                    registration: registration.provider,
                    evidence: evidence.provider
                )
            }
            guard !evidence.evidenceID.isEmpty, !evidence.capabilityRevision.isEmpty else {
                throw RegistrationError.invalidEvidence(registration.provider)
            }
        }
        if let targetResolver = registration.targetResolver,
           targetResolver.runtimeProvider != registration.provider
        {
            throw RegistrationError.targetResolverProviderMismatch(
                registration: registration.provider,
                resolver: targetResolver.runtimeProvider
            )
        }

        if case .verified = registration.figmaCapabilities.loginSupport {
            guard registration.loginDriver != nil else {
                throw RegistrationError.verifiedLoginRequiresDriver(registration.provider)
            }
            guard registration.targetResolver != nil else {
                throw RegistrationError.verifiedLoginRequiresTargetResolver(registration.provider)
            }
        }
        if case .verified = registration.figmaCapabilities.proofSupport {
            guard registration.structuredProofChecker != nil || registration.structuredStatusChecker != nil else {
                throw RegistrationError.verifiedProofRequiresChecker(registration.provider)
            }
            guard registration.targetResolver != nil else {
                throw RegistrationError.verifiedProofRequiresTargetResolver(registration.provider)
            }
        }
        switch registration.figmaCapabilities.runtimeBindingSupport {
        case .verified:
            guard registration.provider != .codex,
                  case .verified = registration.figmaCapabilities.proofSupport
            else {
                throw RegistrationError.verifiedRuntimeBindingRequiresProof(registration.provider)
            }
            guard case .verified = registration.figmaCapabilities.revocationSupport else {
                throw RegistrationError.verifiedRuntimeBindingRequiresVerifiedRevocation(registration.provider)
            }
        case .codexManaged:
            guard case .codexManaged = registration.figmaCapabilities.revocationSupport else {
                throw RegistrationError.codexManagedRuntimeBindingRequiresCodexManagedRevocation(registration.provider)
            }
        case .unverified, .unsupported:
            break
        }
    }
}

/// Phase-1 revision fence. The existing Codex coordinator remains the compatibility path; this
/// seam supplies the generic runtime defense-in-depth check without changing its lifecycle effects.
private final class ExternalMCPRevisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var operationGenerations: [ExternalMCPRuntimeProvider: UInt64] = [:]

    func active() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if value == 0 { value = 1 }
        return value
    }

    func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func nextOperationGeneration(for provider: ExternalMCPRuntimeProvider) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let next = (operationGenerations[provider] ?? 0) &+ 1
        operationGenerations[provider] = next
        return next
    }

    func currentOperationGeneration(for provider: ExternalMCPRuntimeProvider) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return operationGenerations[provider] ?? 0
    }
}

actor ExternalMCPIntegrationCoordinator {
    private nonisolated let revisionBox: ExternalMCPRevisionBox
    let registry: ExternalMCPAdapterRegistry

    init(registry: ExternalMCPAdapterRegistry = .init()) {
        self.registry = registry
        revisionBox = ExternalMCPRevisionBox()
        registry.onRegistrationReplacement = { [weak self] _ in
            _ = self?.invalidateRevision()
        }
    }

    /// Returns the active revision, allocating the initial revision as one actor-isolated
    /// check-and-act operation. Callers must not split this into `currentRevision` + `beginRevision`.
    func activeRevision() -> UInt64 {
        revisionBox.active()
    }

    func beginRevision() -> UInt64 {
        revisionBox.advance()
    }

    func currentRevision() -> UInt64 {
        revisionBox.current()
    }

    func isCurrent(revision candidate: UInt64) -> Bool {
        candidate == revisionBox.current()
    }

    /// Immediate, nonisolated invalidation for main-actor provider transitions. This closes the
    /// race between publishing proof state and the next runtime-access request.
    nonisolated func invalidateRevision() -> UInt64 {
        revisionBox.advance()
    }

    func beginOperationGeneration(for provider: ExternalMCPRuntimeProvider) -> UInt64 {
        revisionBox.nextOperationGeneration(for: provider)
    }

    func decision(
        integration: ExternalMCPIntegrationDefinition?,
        snapshot: ExternalMCPRuntimeSnapshot,
        context: ExternalMCPProviderRuntimeContext,
        requestedRevision: UInt64? = nil,
        verifiedStatus: FigmaMCPVerifiedProviderStatus? = nil,
        operationGeneration: UInt64? = nil
    ) async -> ExternalMCPAccessDecision {
        let currentRevision = requestedRevision ?? revisionBox.current()
        func denied(
            _ reason: ExternalMCPAccessDecisionReason,
            evaluatedSnapshot: ExternalMCPRuntimeSnapshot? = snapshot
        ) -> ExternalMCPAccessDecision {
            .denied(
                integrationID: integration?.integrationID ?? snapshot.integrationID,
                runtimeIdentity: context.identity,
                revision: currentRevision,
                reason: reason,
                verifiedSnapshot: evaluatedSnapshot
            )
        }
        guard currentRevision == revisionBox.current(),
              context.coordinatorRevision == 0 || context.coordinatorRevision == currentRevision
        else {
            return denied(.staleRevision)
        }
        guard let integration, integration.integrationID == snapshot.integrationID else {
            return denied(.noDefinition)
        }
        guard integration.repoPromptActivation == .enabled else {
            return denied(.disabled)
        }
        // Session class is checked before capability so existing callers retain the more useful
        // child-session denial even when they use an adapter-only compatibility registration.
        guard context.sessionClass == .topLevel else {
            return denied(.unsupportedSessionClass)
        }
        guard let registration = registry.registration(for: context.identity.provider),
              registration.figmaCapabilities.runtimeBindingSupport.isAuthorityEnabled
        else {
            return denied(.unsupported)
        }
        guard currentRevision == revisionBox.current(),
              context.coordinatorRevision == 0 || context.coordinatorRevision == currentRevision
        else {
            return denied(.staleRevision)
        }
        switch registration.figmaCapabilities.runtimeBindingSupport {
        case .codexManaged:
            // This is the existing managed Codex path. Its service snapshot remains the authority.
            guard context.identity.provider == .codex,
                  snapshot.connection == .connected,
                  snapshot.authentication == .authenticated
            else {
                return denied(snapshot.connection == .unavailable ? .unavailable : .unauthenticated)
            }
            return ExternalMCPAccessDecision(
                integrationID: integration.integrationID,
                runtimeIdentity: context.identity,
                revision: currentRevision,
                isAllowed: true,
                reason: .granted,
                verifiedSnapshot: snapshot
            )
        case .verified:
            guard context.identity.provider != .codex,
                  isVerifiedProofCapability(registration.figmaCapabilities.proofSupport),
                  snapshot.authentication == .providerOwned,
                  let evidence = registration.figmaCapabilities.proofSupport.evidence,
                  let verifiedStatus,
                  let operationGeneration,
                  let target = integration.externalMCPTarget,
                  target == .figma,
                  verifiedStatus.runtimeProvider == context.identity.provider,
                  verifiedStatus.canonicalTarget == target,
                  verifiedStatus.sanitizedSnapshot.integrationID == target.integrationID,
                  verifiedStatus.sanitizedSnapshot.connection == .connected,
                  verifiedStatus.sanitizedSnapshot.authentication == .providerOwned,
                  verifiedStatus.evidenceID == evidence.evidenceID,
                  verifiedStatus.capabilityRevision == evidence.capabilityRevision,
                  verifiedStatus.operationGeneration == operationGeneration,
                  operationGeneration == revisionBox.currentOperationGeneration(for: context.identity.provider),
                  verifiedStatus.executableIdentity == context.identity.executableIdentity,
                  verifiedStatus.executableVersion == context.identity.executableVersion,
                  verifiedStatus.observedAt <= Date().addingTimeInterval(1),
                  verifiedStatus.validUntil > Date(),
                  let resolver = registration.targetResolver,
                  resolver.runtimeProvider == context.identity.provider
            else {
                return denied(.unauthenticated)
            }
            let resolution = await resolver.resolveTarget(for: target)
            guard case let .resolved(identifier, _, credentialContext) = resolution,
                  verifiedStatus.providerTargetIdentifier == identifier,
                  verifiedStatus.credentialContext == credentialContext,
                  currentRevision == revisionBox.current(),
                  context.coordinatorRevision == currentRevision
            else {
                return denied(.staleRevision)
            }
            return ExternalMCPAccessDecision(
                integrationID: integration.integrationID,
                runtimeIdentity: context.identity,
                revision: currentRevision,
                isAllowed: true,
                reason: .granted,
                verifiedSnapshot: verifiedStatus.sanitizedSnapshot
            )
        case .unverified, .unsupported:
            return denied(.unsupported)
        }
    }

    private func isVerifiedProofCapability(
        _ support: FigmaMCPProviderCapabilitySupport
    ) -> Bool {
        if case .verified = support { return true }
        return false
    }
}

/// Durable settings remain app-owned. Adapters receive a definition, never the settings file,
/// UserDefaults, Keychain, or provider credentials.
@MainActor
protocol ExternalMCPIntegrationSettingsStore: AnyObject {
    var externalMCPIntegrations: [ExternalMCPIntegrationDefinition] { get }
    func externalMCPIntegration(for provider: ExternalMCPIntegrationProvider) -> ExternalMCPIntegrationDefinition?
    func externalMCPIntegration(for integrationID: ExternalMCPIntegrationID) -> ExternalMCPIntegrationDefinition?
    func setExternalMCPIntegration(_ definition: ExternalMCPIntegrationDefinition) -> Bool
    func removeExternalMCPIntegration(for provider: ExternalMCPIntegrationProvider) -> Bool
    func removeExternalMCPIntegration(for integrationID: ExternalMCPIntegrationID) -> Bool
}

/// Compatibility name for callers that reason about the persisted definition boundary.
typealias ExternalMCPDefinitionStore = ExternalMCPIntegrationSettingsStore
