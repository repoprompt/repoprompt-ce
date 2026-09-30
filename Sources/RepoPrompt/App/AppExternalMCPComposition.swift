import Foundation

/// App composition for provider-neutral external MCP adapters.
///
/// AppDelegate constructs and retains this one dependency graph. The Figma coordinator remains
/// the Codex lifecycle/authentication owner; this root supplies it to provider-neutral consumers.
@MainActor
final class AppExternalMCPComposition {
    let registry: ExternalMCPAdapterRegistry
    let coordinator: ExternalMCPIntegrationCoordinator
    let figmaCoordinator: FigmaMCPIntegrationCoordinator
    let terminalSessionController: FigmaMCPProviderTerminalHandoff.SessionController
    let cursorToolSurfaceObserver: any CursorFigmaMCPToolSurfaceObserving
    let figmaProviderStatusService: FigmaMCPProviderStatusService
    /// The sole app-lifetime owner for provider-native Figma login attempts.
    let figmaProviderConnectionCoordinator: FigmaMCPProviderConnectionCoordinator

    init(
        figmaCoordinator: FigmaMCPIntegrationCoordinator,
        terminalSessionController: FigmaMCPProviderTerminalHandoff.SessionController,
        cursorToolSurfaceObserver: any CursorFigmaMCPToolSurfaceObserving,
        registry: ExternalMCPAdapterRegistry? = nil,
        providerConnectionCoordinator: FigmaMCPProviderConnectionCoordinator? = nil,
        terminationObserver: (any ApplicationTerminationObserving)? = nil
    ) {
        self.figmaCoordinator = figmaCoordinator
        self.terminalSessionController = terminalSessionController
        self.cursorToolSurfaceObserver = cursorToolSurfaceObserver
        let resolvedRegistry = registry ?? Self.makeRegistry(
            figmaCoordinator: figmaCoordinator,
            terminalSessionController: terminalSessionController
        )
        let resolvedCoordinator = ExternalMCPIntegrationCoordinator(registry: resolvedRegistry)
        self.registry = resolvedRegistry
        coordinator = resolvedCoordinator
        figmaProviderStatusService = FigmaMCPProviderStatusService(
            registry: resolvedRegistry,
            coordinator: resolvedCoordinator
        )
        figmaProviderConnectionCoordinator = providerConnectionCoordinator ?? FigmaMCPProviderConnectionCoordinator(
            registry: resolvedRegistry,
            sessionController: terminalSessionController,
            terminationObserver: terminationObserver,
            statusCoordinator: resolvedCoordinator
        )
        // Definition changes flow through the existing Codex settings observer, while the
        // provider-neutral fence remains the shared authorization revision.
        figmaCoordinator.installExternalMCPRevisionInvalidator {
            resolvedCoordinator.invalidateRevision()
        }
    }

    /// AppDelegate's synchronous termination fence for provider-owned login attempts.
    func applicationWillTerminate() {
        figmaProviderConnectionCoordinator.applicationWillTerminate()
    }

    /// Waits for the coordinator's bounded provider-login termination drain.
    func awaitApplicationTermination() async {
        await figmaProviderConnectionCoordinator.awaitApplicationTermination()
    }

    /// Neutral runtime entry point used by provider launch code. The adapter owns provider
    /// verification and binding cleanup; this coordinator owns the revisioned authorization.
    func prepareRuntimeAccess(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPRuntimeBindingResult {
        guard let registration = registry.registration(for: context.identity.provider),
              registration.figmaCapabilities.runtimeBindingSupport.isAuthorityEnabled
        else {
            return .init(
                lease: nil,
                decision: .denied(
                    integrationID: integration.integrationID,
                    runtimeIdentity: context.identity,
                    revision: context.coordinatorRevision,
                    reason: .unsupported
                )
            )
        }
        let adapter = registration.adapter

        let revision = await coordinator.activeRevision()
        let runtimeContext = ExternalMCPProviderRuntimeContext(
            identity: context.identity,
            sessionClass: context.sessionClass,
            workspaceID: context.workspaceID,
            sessionID: context.sessionID,
            isolation: context.isolation,
            homePath: context.homePath,
            configPath: context.configPath,
            dataPath: context.dataPath,
            environmentRemovalPolicy: context.environmentRemovalPolicy,
            processOwner: context.processOwner,
            coordinatorRevision: revision,
            cancellationToken: context.cancellationToken
        )
        let snapshot = await adapter.refreshStatus(in: runtimeContext, integration: integration)
        let operationGeneration: UInt64?
        let verifiedStatus: FigmaMCPVerifiedProviderStatus?
        if case .verified = registration.figmaCapabilities.runtimeBindingSupport {
            let generation = await coordinator.beginOperationGeneration(for: context.identity.provider)
            operationGeneration = generation
            verifiedStatus = await currentVerifiedStatus(
                registration: registration,
                context: runtimeContext,
                operationGeneration: generation
            )
        } else {
            operationGeneration = nil
            verifiedStatus = nil
        }
        let decision = await coordinator.decision(
            integration: integration,
            snapshot: snapshot,
            context: runtimeContext,
            requestedRevision: revision,
            verifiedStatus: verifiedStatus,
            operationGeneration: operationGeneration
        )
        let result = await adapter.applyRuntimeAccess(in: runtimeContext, decision: decision)
        guard let lease = result.lease else { return result }
        guard await coordinator.isCurrent(revision: revision) else {
            _ = await lease.revoke()
            return .init(
                lease: nil,
                decision: .denied(
                    integrationID: decision.integrationID,
                    runtimeIdentity: context.identity,
                    revision: revision,
                    reason: .staleRevision,
                    verifiedSnapshot: decision.verifiedSnapshot
                )
            )
        }
        return result
    }

    private func currentVerifiedStatus(
        registration: ExternalMCPProviderRegistration,
        context: ExternalMCPProviderRuntimeContext,
        operationGeneration: UInt64
    ) async -> FigmaMCPVerifiedProviderStatus? {
        guard context.identity.provider != .codex,
              let resolver = registration.targetResolver,
              resolver.runtimeProvider == context.identity.provider
        else { return nil }
        let target = ExternalMCPIntegrationTarget.figma
        let resolution = await resolver.resolveTarget(for: target)
        guard case .resolved = resolution else { return nil }

        let outcome: FigmaMCPProviderStructuredStatusOutcome?
        if let checker = registration.structuredStatusChecker {
            outcome = await checker(target, resolution, context, operationGeneration)
        } else if let checker = registration.structuredProofChecker {
            let proof = await checker(target, resolution, context, operationGeneration)
            outcome = proof.map(FigmaMCPProviderStructuredStatusOutcome.verified)
        } else {
            outcome = nil
        }
        guard !context.cancellationToken.isCancelled,
              let outcome,
              case let .verified(proof) = outcome
        else { return nil }
        return proof
    }

    private static func makeRegistry(
        figmaCoordinator: FigmaMCPIntegrationCoordinator,
        terminalSessionController: FigmaMCPProviderTerminalHandoff.SessionController
    ) -> ExternalMCPAdapterRegistry {
        let codex = CodexFigmaExternalMCPProviderAdapter(service: figmaCoordinator.service)
        let claude = ClaudeCodeExternalMCPProviderAdapter()
        let openCode = OpenCodeExternalMCPProviderAdapter()
        let cursor = CursorExternalMCPProviderAdapter()
        let grok = GrokBuildExternalMCPProviderAdapter()
        let devin = DevinExternalMCPProviderAdapter()
        let antigravity = AntigravityExternalMCPProviderAdapter()
        let claudeLoginComponents = ClaudeCodeFigmaMCPLoginFactory.makeComponents(sessionController: terminalSessionController)
        let claudeLoginTargetIsCanonical = ClaudeCodeFigmaMCPLoginDescriptor.targetIdentifier == "plugin:figma:figma"
        let claudeCapabilities = FigmaMCPProviderCapabilityRegistration(
            provider: .claudeCode,
            loginSupport: claudeLoginTargetIsCanonical
                ? .verified(claudeLoginComponents.descriptor.evidence)
                : .unverified(.liveGatePending),
            // This capability approves only the exact, read-only structured checker registered
            // below. The checker itself requires a current canonical Claude Figma Connected
            // record before it publishes a proof; no target metadata or login exit can connect.
            proofSupport: .verified(claudeLoginComponents.descriptor.evidence),
            // Logout is provider-owned and targets only Claude's canonical Figma plugin record.
            revocationSupport: .verified(ClaudeCodeFigmaMCPLogoutDescriptor.evidence),
            runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
        )
        let claudeLoginDriver = claudeLoginTargetIsCanonical
            ? claudeLoginComponents.makeLoginDriver()
            : nil
        let claudeTargetResolver = claudeLoginTargetIsCanonical
            ? claudeLoginComponents.targetResolver
            : nil
        let claudeStructuredStatusChecker: FigmaMCPStructuredStatusChecker? = if claudeLoginTargetIsCanonical {
            { target, resolution, context, operationGeneration in
                let snapshot = await claude.refreshStatus(
                    in: context,
                    integration: .figma(repoPromptActivation: .enabled)
                )
                guard case let .resolved(providerTargetIdentifier, _, credentialContext) = resolution,
                      target == .figma
                else { return .unknown }
                guard snapshot.connection == .connected,
                      snapshot.authentication == .providerOwned
                else {
                    return snapshot.connection == .disconnected ? .unauthenticated : .unknown
                }
                return .verified(FigmaMCPVerifiedProviderStatus(
                    runtimeProvider: .claudeCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: providerTargetIdentifier,
                    credentialContext: credentialContext,
                    sanitizedSnapshot: snapshot,
                    evidenceID: claudeLoginComponents.descriptor.evidence.evidenceID,
                    capabilityRevision: claudeLoginComponents.descriptor.evidence.capabilityRevision,
                    executableIdentity: context.identity.executableIdentity,
                    observedAt: Date(),
                    operationGeneration: operationGeneration
                ))
            }
        } else {
            nil
        }

        var registry = ExternalMCPAdapterRegistry()
        try? registry.register(ExternalMCPProviderRegistration(
            provider: .codex,
            adapter: codex,
            figmaCapabilities: .init(
                provider: .codex,
                loginSupport: .codexManaged,
                proofSupport: .codexManaged,
                revocationSupport: .codexManaged,
                runtimeBindingSupport: .codexManaged
            )
        ))
        try? registry.register(ExternalMCPProviderRegistration(
            provider: .claudeCode,
            adapter: claude,
            figmaCapabilities: claudeCapabilities,
            targetResolver: claudeTargetResolver,
            loginDriver: claudeLoginDriver,
            structuredStatusChecker: claudeStructuredStatusChecker
        ))
        // Production registration deliberately supplies adapters only for Cursor and Devin. Native
        // login, target resolution, structured proof, revocation, and runtime authority remain
        // unavailable until a provider passes the live capability gate through an injected registry.
        for (provider, adapter) in [
            (ExternalMCPRuntimeProvider.cursor, cursor as any ExternalMCPProviderAdapter),
            (.devin, devin as any ExternalMCPProviderAdapter)
        ] {
            try? registry.register(ExternalMCPProviderRegistration(
                provider: provider,
                adapter: adapter,
                figmaCapabilities: .init(
                    provider: provider,
                    loginSupport: .unverified(.liveGatePending),
                    proofSupport: .unverified(.noStructuredProofContract),
                    revocationSupport: .unverified(.noRevocationContract),
                    runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
                )
            ))
        }
        try? registry.register(ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: openCode,
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .unsupported(.unsupportedProviderRoute),
                proofSupport: .unsupported(.unsupportedProviderRoute),
                revocationSupport: .unsupported(.unsupportedProviderRoute),
                runtimeBindingSupport: .unsupported(.unsupportedProviderRoute)
            )
        ))
        try? registry.register(ExternalMCPProviderRegistration(
            provider: .grokBuild,
            adapter: grok,
            figmaCapabilities: .init(
                provider: .grokBuild,
                loginSupport: .unsupported(.unsupportedProviderRoute),
                proofSupport: .unsupported(.unsupportedProviderRoute),
                revocationSupport: .unsupported(.unsupportedProviderRoute),
                runtimeBindingSupport: .unsupported(.unsupportedProviderRoute)
            )
        ))
        try? registry.register(ExternalMCPProviderRegistration(
            provider: .antigravity,
            adapter: antigravity,
            figmaCapabilities: .init(
                provider: .antigravity,
                loginSupport: .unsupported(.unsupportedProviderRoute),
                proofSupport: .unsupported(.unsupportedProviderRoute),
                revocationSupport: .unsupported(.unsupportedProviderRoute),
                runtimeBindingSupport: .unsupported(.unsupportedProviderRoute)
            )
        ))
        return registry
    }
}
