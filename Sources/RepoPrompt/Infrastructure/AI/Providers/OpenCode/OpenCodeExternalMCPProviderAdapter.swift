import Foundation

struct OpenCodeExternalMCPInjectionProof {
    let isCapabilityProven: Bool
    let isAuthenticated: Bool
    let resolvedServerName: String?
    let resolvedRemoteURL: String?
}

struct OpenCodeExternalMCPRuntimeBinding {
    let integrationID: ExternalMCPIntegrationID
    let externalMCP: OpenCodeIntegrationConfiguration.OpenCodeEphemeralExternalMCP
    let lease: ExternalMCPRuntimeBindingLease
}

struct OpenCodeExternalMCPPreparationResult {
    let openCodeBinding: OpenCodeExternalMCPRuntimeBinding?
    let neutralResult: ExternalMCPRuntimeBindingResult
}

struct OpenCodeExternalMCPProviderAdapter: ExternalMCPProviderAdapter {
    typealias ProofProvider = @Sendable (
        ExternalMCPProviderRuntimeContext,
        ExternalMCPIntegrationDefinition
    ) async -> OpenCodeExternalMCPInjectionProof?
    typealias TeardownOperation = @Sendable (
        ExternalMCPProviderRuntimeContext,
        ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPCleanupReceipt

    private let proofProvider: ProofProvider?
    private let teardownOperation: TeardownOperation?

    let runtimeProvider: ExternalMCPRuntimeProvider = .openCode

    init(
        proofProvider: ProofProvider? = nil,
        teardownOperation: TeardownOperation? = nil
    ) {
        self.proofProvider = proofProvider
        self.teardownOperation = teardownOperation
    }

    func capabilities(in context: ExternalMCPProviderRuntimeContext) async -> ExternalMCPCapabilityDescriptor {
        guard eligibleContext(context),
              proofProvider != nil,
              teardownOperation != nil
        else { return .unsupported }
        let proven = await validProof(in: context, integration: .figma()) != nil
        return ExternalMCPCapabilityDescriptor(
            discovery: .unsupported,
            interactiveAuthentication: .providerNative,
            statusVerification: .providerNative,
            managedConfigurationInstallation: .unsupported,
            adoptedImport: .unsupported,
            credentialLogout: .providerNative,
            runtimeInjection: proven ? .requiresPersistentApproval : .indeterminate,
            childSessionInheritance: .unsupported
        )
    }

    func discoverExisting(in _: ExternalMCPProviderRuntimeContext) async -> ExternalMCPDiscoveryResult {
        ExternalMCPDiscoveryResult(status: .unsupported, definition: nil)
    }

    func authenticate(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPAuthenticationResult {
        let snapshot = await refreshStatus(in: context, integration: integration)
        let status: ExternalMCPAuthenticationResult.Status = if context.cancellationToken.isCancelled {
            .cancelled
        } else if snapshot.authentication == .providerOwned {
            .authenticated
        } else {
            .unsupported
        }
        return ExternalMCPAuthenticationResult(status: status, snapshot: snapshot)
    }

    func refreshStatus(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPRuntimeSnapshot {
        guard proofProvider != nil,
              eligibleContext(context), integration.isSupportedDefinition,
              integration.repoPromptActivation == .enabled,
              await validProof(in: context, integration: integration) != nil
        else {
            return ExternalMCPRuntimeSnapshot(
                integrationID: integration.integrationID,
                connection: .unavailable,
                authentication: .unsupported,
                diagnostics: ["OpenCode external MCP support was not proven."]
            )
        }
        return ExternalMCPRuntimeSnapshot(
            integrationID: integration.integrationID,
            connection: .connected,
            authentication: .providerOwned,
            verifiedAt: Date()
        )
    }

    func applyRuntimeAccess(
        in context: ExternalMCPProviderRuntimeContext,
        decision: ExternalMCPAccessDecision
    ) async -> ExternalMCPRuntimeBindingResult {
        await prepareEphemeralRuntimeAccess(in: context, integration: .figma(), decision: decision).neutralResult
    }

    func prepareEphemeralRuntimeAccess(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition,
        decision: ExternalMCPAccessDecision
    ) async -> OpenCodeExternalMCPPreparationResult {
        guard decision.isAllowed,
              decision.reason == .granted,
              decision.integrationID == integration.integrationID,
              decision.runtimeIdentity == context.identity,
              decision.revision == context.coordinatorRevision,
              eligibleContext(context),
              integration.isSupportedDefinition,
              integration.repoPromptActivation == .enabled,
              !context.cancellationToken.isCancelled,
              let teardownOperation
        else {
            return OpenCodeExternalMCPPreparationResult(openCodeBinding: nil, neutralResult: deniedResult(for: decision, context: context))
        }
        guard await validProof(in: context, integration: integration) != nil,
              !context.cancellationToken.isCancelled
        else {
            return OpenCodeExternalMCPPreparationResult(openCodeBinding: nil, neutralResult: deniedResult(for: decision, context: context))
        }

        let lease = ExternalMCPRuntimeBindingLease(
            integrationID: integration.integrationID,
            runtimeIdentity: context.identity,
            sessionClass: context.sessionClass,
            coordinatorRevision: context.coordinatorRevision,
            isAccepted: true,
            cancellationToken: context.cancellationToken,
            revokeOperation: { [teardownOperation, context, integration] in
                await teardownOperation(context, integration)
            }
        )
        let binding = OpenCodeExternalMCPRuntimeBinding(
            integrationID: integration.integrationID,
            externalMCP: .figma(serverName: integration.serverName),
            lease: lease
        )
        return OpenCodeExternalMCPPreparationResult(
            openCodeBinding: binding,
            neutralResult: ExternalMCPRuntimeBindingResult(lease: lease, decision: decision)
        )
    }

    func disconnect(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPDisconnectResult {
        guard eligibleContext(context),
              integration.isSupportedDefinition,
              integration.repoPromptActivation == .enabled,
              !context.cancellationToken.isCancelled,
              await validProof(in: context, integration: integration) != nil
        else {
            return .init(
                receipt: .init(outcome: .unsupported, detail: "OpenCode external MCP cleanup was not authorized."),
                snapshot: .disconnected(integrationID: integration.integrationID)
            )
        }
        guard !context.cancellationToken.isCancelled,
              let teardownOperation
        else {
            return .init(
                receipt: .init(outcome: .indeterminate, detail: "OpenCode ephemeral MCP overlay cleanup was not configured."),
                snapshot: .disconnected(integrationID: integration.integrationID)
            )
        }
        return await .init(
            receipt: teardownOperation(context, integration),
            snapshot: .disconnected(integrationID: integration.integrationID)
        )
    }

    private func eligibleContext(_ context: ExternalMCPProviderRuntimeContext) -> Bool {
        context.identity.provider == .openCode
            && context.identity.runtimeKind == .acp
            && context.isolation == .ceIsolated
            && context.sessionClass == .topLevel
    }

    private func validProof(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> OpenCodeExternalMCPInjectionProof? {
        guard integration.isSupportedDefinition,
              integration.repoPromptActivation == .enabled,
              !context.cancellationToken.isCancelled,
              let proofProvider
        else { return nil }
        let reading = await proofProvider(context, integration)
        guard !context.cancellationToken.isCancelled,
              let proof = reading,
              proof.isCapabilityProven,
              proof.isAuthenticated,
              proof.resolvedServerName == integration.serverName,
              proof.resolvedRemoteURL == OpenCodeIntegrationConfiguration.figmaRemoteMCPURL
        else { return nil }
        return proof
    }

    private func deniedResult(
        for decision: ExternalMCPAccessDecision,
        context: ExternalMCPProviderRuntimeContext,
        reason: ExternalMCPAccessDecisionReason = .unsupported
    ) -> ExternalMCPRuntimeBindingResult {
        .init(
            lease: nil,
            decision: .denied(
                integrationID: decision.integrationID,
                runtimeIdentity: context.identity,
                revision: context.coordinatorRevision,
                reason: context.cancellationToken.isCancelled ? .cancelled : reason,
                verifiedSnapshot: decision.verifiedSnapshot
            )
        )
    }
}
