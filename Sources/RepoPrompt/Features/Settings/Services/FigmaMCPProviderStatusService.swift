import Foundation

/// Read-only status results for provider-owned Figma MCP routes.
enum FigmaMCPProviderStatusCheckResult: Equatable {
    /// Legacy presentation result retained for source compatibility with existing Settings test
    /// doubles. The production service uses `verifiedProvider` below.
    case verified(ExternalMCPRuntimeSnapshot)
    /// A provider-bound proof that survived the exact target, capability, freshness, and
    /// cancellation fences. This is the only result the new structured status path publishes.
    case verifiedProvider(FigmaMCPVerifiedProviderStatus)
    case unverifiedCapability
    case unsupported
    case stale
    case cancelled
}

/// Settings-facing status seam for the existing Settings view-model. The legacy definition input
/// remains a compatibility adapter; production Figma status authority is the canonical-target
/// overload on `FigmaMCPProviderStatusService`.
@MainActor
protocol FigmaMCPProviderStatusChecking: AnyObject {
    func checkStatus(
        provider: ExternalMCPRuntimeProvider,
        integration: ExternalMCPIntegrationDefinition,
        cancellationToken: ExternalMCPCancellationToken
    ) async -> FigmaMCPProviderStatusCheckResult
}

/// Performs structured-proof-only status checks through the composed registry.
///
/// This service never calls a generic adapter's `refreshStatus`. A provider must register both an
/// exact target resolver and an explicitly structured proof/status checker. In particular, no saved
/// Figma definition, adapter presence, CLI state, configuration presence, or process result can
/// create a connected status.
/// create a connected status.
@MainActor
final class FigmaMCPProviderStatusService: FigmaMCPProviderStatusChecking {
    typealias RuntimeContextFactory = @MainActor (
        ExternalMCPRuntimeProvider,
        UInt64,
        ExternalMCPCancellationToken
    ) -> ExternalMCPProviderRuntimeContext?

    let registry: ExternalMCPAdapterRegistry
    let coordinator: ExternalMCPIntegrationCoordinator
    private let contextFactory: RuntimeContextFactory

    init(
        registry: ExternalMCPAdapterRegistry,
        coordinator: ExternalMCPIntegrationCoordinator,
        contextFactory: @escaping RuntimeContextFactory = FigmaMCPProviderStatusService.defaultContext
    ) {
        self.registry = registry
        self.coordinator = coordinator
        self.contextFactory = contextFactory
    }

    /// Compatibility bridge for the pre-canonical Settings seam. It intentionally ignores the
    /// definition's activation state: provider-owned proof is independent of saved app metadata.
    func checkStatus(
        provider: ExternalMCPRuntimeProvider,
        integration: ExternalMCPIntegrationDefinition,
        cancellationToken: ExternalMCPCancellationToken = ExternalMCPCancellationToken()
    ) async -> FigmaMCPProviderStatusCheckResult {
        guard integration.isSupportedDefinition else { return .unsupported }
        return await checkStatus(
            provider: provider,
            target: .figma,
            operationGeneration: 0,
            cancellationToken: cancellationToken
        )
    }

    /// Canonical status API. It requires no persisted definition.
    func checkStatus(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget,
        operationGeneration: UInt64 = 0,
        cancellationToken: ExternalMCPCancellationToken = ExternalMCPCancellationToken()
    ) async -> FigmaMCPProviderStatusCheckResult {
        await withTaskCancellationHandler(operation: {
            await checkCanonicalStatus(
                provider: provider,
                target: target,
                operationGeneration: operationGeneration,
                cancellationToken: cancellationToken
            )
        }, onCancel: {
            cancellationToken.cancel()
        })
    }

    private func checkCanonicalStatus(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget,
        operationGeneration: UInt64,
        cancellationToken: ExternalMCPCancellationToken
    ) async -> FigmaMCPProviderStatusCheckResult {
        guard !isCancelled(cancellationToken) else { return .cancelled }
        guard target == .figma, provider != .codex else { return .unsupported }
        guard let registration = registry.registration(for: provider),
              registration.adapter.runtimeProvider == provider
        else { return .unsupported }

        guard case let .verified(evidence) = registration.figmaCapabilities.proofSupport else {
            return isUnverified(registration.figmaCapabilities.proofSupport)
                ? .unverifiedCapability
                : .unsupported
        }
        guard let resolver = registration.targetResolver,
              resolver.runtimeProvider == provider,
              registration.structuredProofChecker != nil || registration.structuredStatusChecker != nil
        else { return .unverifiedCapability }

        let revision = await coordinator.activeRevision()
        guard !isCancelled(cancellationToken) else { return .cancelled }
        let executableIdentity = await currentExecutableIdentity(for: registration)
        let executableVersion = await currentExecutableVersion(for: registration)
        guard await supportsExecutableVersion(executableVersion, registration: registration) else {
            return .unsupported
        }
        let resolution = await resolver.resolveTarget(for: target)
        guard case .resolved = resolution else {
            return isCancelled(cancellationToken) ? .cancelled : .unverifiedCapability
        }
        guard !isCancelled(cancellationToken) else { return .cancelled }
        guard let context = contextFactory(provider, revision, cancellationToken),
              isValidStatusContext(
                  context,
                  provider: provider,
                  revision: revision,
                  cancellationToken: cancellationToken,
                  executableVersion: executableVersion,
                  executableIdentity: executableIdentity
              )
        else {
            return isCancelled(cancellationToken) ? .cancelled : .unsupported
        }

        let outcome: FigmaMCPProviderStructuredStatusOutcome
        if let checker = registration.structuredStatusChecker {
            outcome = await checker(target, resolution, context, operationGeneration)
        } else if let proofChecker = registration.structuredProofChecker {
            // Preserve the pre-typed checker ABI while making nil explicitly unknown.
            let proof = await proofChecker(target, resolution, context, operationGeneration)
            outcome = proof.map(FigmaMCPProviderStructuredStatusOutcome.verified) ?? .unknown
        } else {
            return .unverifiedCapability
        }
        guard !isCancelled(cancellationToken) else { return .cancelled }
        guard await coordinator.isCurrent(revision: revision),
              await currentExecutableIdentity(for: registration) == executableIdentity,
              await currentExecutableVersion(for: registration) == executableVersion,
              await supportsExecutableVersion(executableVersion, registration: registration)
        else { return .stale }
        switch outcome {
        case .unauthenticated, .expired:
            // The app-lifetime connection coordinator consumes this typed negative answer and
            // publishes Needs Login. The legacy Settings bridge remains fail-closed.
            return .stale
        case .unknown, .stale:
            return .stale
        case let .verified(proof):
            guard proof.runtimeProvider == provider,
                  proof.canonicalTarget == target,
                  proof.evidenceID == evidence.evidenceID,
                  proof.capabilityRevision == evidence.capabilityRevision,
                  proof.operationGeneration == operationGeneration,
                  proof.executableIdentity == nil || proof.executableIdentity == context.identity.executableIdentity,
                  proof.executableVersion == nil || proof.executableVersion == executableVersion,
                  proof.observedAt <= Date().addingTimeInterval(1),
                  proof.validUntil > Date(),
                  proofMatchesResolution(proof, resolution),
                  proof.sanitizedSnapshot.integrationID == target.integrationID,
                  proof.sanitizedSnapshot.connection == .connected,
                  proof.sanitizedSnapshot.authentication == .providerOwned
            else { return .stale }
            return .verifiedProvider(sanitizedProof(proof))
        }
    }

    private func isUnverified(_ support: FigmaMCPProviderCapabilitySupport) -> Bool {
        if case .unverified = support { return true }
        return false
    }

    private func proofMatchesResolution(
        _ proof: FigmaMCPVerifiedProviderStatus,
        _ resolution: FigmaMCPProviderTargetResolution
    ) -> Bool {
        guard case let .resolved(identifier, _, credentialContext) = resolution else { return false }
        return proof.providerTargetIdentifier == identifier
            && proof.credentialContext == credentialContext
    }

    private func sanitizedProof(_ proof: FigmaMCPVerifiedProviderStatus) -> FigmaMCPVerifiedProviderStatus {
        FigmaMCPVerifiedProviderStatus(
            runtimeProvider: proof.runtimeProvider,
            canonicalTarget: proof.canonicalTarget,
            providerTargetIdentifier: proof.providerTargetIdentifier,
            credentialContext: proof.credentialContext,
            sanitizedSnapshot: ExternalMCPRuntimeSnapshot(
                integrationID: proof.sanitizedSnapshot.integrationID,
                connection: proof.sanitizedSnapshot.connection,
                authentication: proof.sanitizedSnapshot.authentication,
                verifiedAt: proof.sanitizedSnapshot.verifiedAt,
                toolCount: proof.sanitizedSnapshot.toolCount,
                toolLabels: proof.sanitizedSnapshot.toolLabels,
                diagnostics: proof.sanitizedSnapshot.diagnostics
            ),
            evidenceID: proof.evidenceID,
            capabilityRevision: proof.capabilityRevision,
            executableIdentity: proof.executableIdentity,
            executableVersion: proof.executableVersion,
            observedAt: proof.observedAt,
            validUntil: proof.validUntil,
            operationGeneration: proof.operationGeneration
        )
    }

    private func isValidStatusContext(
        _ context: ExternalMCPProviderRuntimeContext,
        provider: ExternalMCPRuntimeProvider,
        revision: UInt64,
        cancellationToken: ExternalMCPCancellationToken,
        executableVersion: String?,
        executableIdentity: String?
    ) -> Bool {
        guard let profile = Self.statusContextProfile(for: provider) else { return false }
        return context.identity.provider == provider
            && context.identity.runtimeKind == profile.runtimeKind
            && (
                context.identity.executableIdentity == profile.agentProvider.commandName
                    || context.identity.executableIdentity == executableIdentity
            )
            && context.sessionClass == profile.sessionClass
            && context.workspaceID == nil
            && context.sessionID == nil
            && context.isolation == profile.isolation
            && context.homePath == nil
            && context.configPath == nil
            && context.dataPath == nil
            && context.environmentRemovalPolicy == .none
            && context.processOwner == nil
            && context.coordinatorRevision == revision
            && (context.identity.executableVersion == nil || context.identity.executableVersion == executableVersion)
            && context.cancellationToken === cancellationToken
    }

    private struct StatusContextProfile {
        let agentProvider: AgentProviderKind
        let runtimeKind: ExternalMCPRuntimeKind
        let sessionClass: ExternalMCPSessionClass
        let isolation: ExternalMCPIsolationMode
    }

    private static func defaultContext(
        provider: ExternalMCPRuntimeProvider,
        revision: UInt64,
        cancellationToken: ExternalMCPCancellationToken
    ) -> ExternalMCPProviderRuntimeContext? {
        guard let profile = statusContextProfile(for: provider) else { return nil }
        return ExternalMCPProviderRuntimeContext(
            identity: ExternalMCPProviderRuntimeIdentity(
                provider: provider,
                runtimeKind: profile.runtimeKind,
                executableIdentity: profile.agentProvider.commandName
            ),
            sessionClass: profile.sessionClass,
            isolation: profile.isolation,
            coordinatorRevision: revision,
            cancellationToken: cancellationToken
        )
    }

    private static func statusContextProfile(
        for provider: ExternalMCPRuntimeProvider
    ) -> StatusContextProfile? {
        switch provider {
        case .claudeCode:
            .init(agentProvider: .claudeCode, runtimeKind: .nativeCLI, sessionClass: .discovery, isolation: .userNative)
        case .openCode:
            .init(agentProvider: .openCode, runtimeKind: .acp, sessionClass: .topLevel, isolation: .ceIsolated)
        case .cursor:
            .init(agentProvider: .cursor, runtimeKind: .acp, sessionClass: .topLevel, isolation: .ceIsolated)
        case .grokBuild:
            .init(agentProvider: .grokBuild, runtimeKind: .acp, sessionClass: .topLevel, isolation: .ceIsolated)
        case .codex, .devin, .antigravity:
            nil
        }
    }

    private func currentExecutableIdentity(
        for registration: ExternalMCPProviderRegistration
    ) async -> String? {
        guard let resolver = registration.loginDriver as? any FigmaMCPProviderSubprocessExecutableResolving else {
            return nil
        }
        return await resolver.executableIdentity()
    }

    private func currentExecutableVersion(
        for registration: ExternalMCPProviderRegistration
    ) async -> String? {
        guard let resolver = registration.loginDriver as? any FigmaMCPProviderSubprocessExecutableResolving else {
            return nil
        }
        return await resolver.currentExecutableVersion()
    }

    private func supportsExecutableVersion(
        _ version: String?,
        registration: ExternalMCPProviderRegistration
    ) async -> Bool {
        guard let resolver = registration.loginDriver as? any FigmaMCPProviderSubprocessExecutableResolving else {
            return true
        }
        return await resolver.supportsExecutableVersion(version)
    }

    private func isCancelled(_ cancellationToken: ExternalMCPCancellationToken) -> Bool {
        cancellationToken.isCancelled || Task.isCancelled
    }
}
