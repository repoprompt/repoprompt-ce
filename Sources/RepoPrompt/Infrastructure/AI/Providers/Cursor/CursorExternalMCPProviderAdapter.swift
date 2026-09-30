import Foundation

struct CursorExternalMCPApprovalProof {
    let isCapabilityProven: Bool
    let isAuthenticated: Bool
    let approvalID: String?
}

struct CursorExternalMCPRuntimeBinding {
    let integrationID: ExternalMCPIntegrationID
    let approvalID: String
    let lease: ExternalMCPRuntimeBindingLease
}

struct CursorExternalMCPPreparationResult {
    let cursorBinding: CursorExternalMCPRuntimeBinding?
    let neutralResult: ExternalMCPRuntimeBindingResult
}

/// Cursor approval leases remain provider-owned. This adapter accepts a proof supplied by the
/// Cursor integration only when capability, authentication, and the approval identifier are all
/// verified; absent proof remains fail-closed and never mutates Cursor configuration.
struct CursorExternalMCPProviderAdapter: ExternalMCPProviderAdapter {
    typealias ProofProvider = @Sendable (
        ExternalMCPProviderRuntimeContext,
        ExternalMCPIntegrationDefinition
    ) async -> CursorExternalMCPApprovalProof?
    typealias TeardownOperation = @Sendable (
        ExternalMCPProviderRuntimeContext,
        ExternalMCPIntegrationDefinition,
        String
    ) async -> ExternalMCPCleanupReceipt

    let runtimeProvider: ExternalMCPRuntimeProvider = .cursor
    private let proofProvider: ProofProvider?
    private let teardownOperation: TeardownOperation?

    init(
        proofProvider: ProofProvider? = nil,
        teardownOperation: TeardownOperation? = nil
    ) {
        self.proofProvider = proofProvider
        self.teardownOperation = teardownOperation
    }

    func capabilities(in context: ExternalMCPProviderRuntimeContext) async -> ExternalMCPCapabilityDescriptor {
        guard proofProvider != nil,
              teardownOperation != nil,
              eligibleContext(context), await validProof(in: context, integration: .figma()) != nil
        else {
            return .unsupported
        }
        return ExternalMCPCapabilityDescriptor(
            statusVerification: .providerNative,
            credentialLogout: .providerNative,
            runtimeInjection: .requiresPersistentApproval,
            childSessionInheritance: .unsupported
        )
    }

    func discoverExisting(in _: ExternalMCPProviderRuntimeContext) async -> ExternalMCPDiscoveryResult {
        .init(status: .unsupported, definition: nil)
    }

    func authenticate(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPAuthenticationResult {
        let snapshot = await refreshStatus(in: context, integration: integration)
        return .init(
            status: snapshot.authentication == .providerOwned ? .authenticated : .unsupported,
            snapshot: snapshot
        )
    }

    func refreshStatus(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPRuntimeSnapshot {
        guard eligibleContext(context), await validProof(in: context, integration: integration) != nil else {
            return unavailableSnapshot(for: integration)
        }
        return .init(
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
        await prepareRuntimeAccess(in: context, integration: .figma(), decision: decision).neutralResult
    }

    func prepareRuntimeAccess(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition,
        decision: ExternalMCPAccessDecision
    ) async -> CursorExternalMCPPreparationResult {
        guard decision.isAllowed,
              decision.reason == .granted,
              decision.integrationID == integration.integrationID,
              decision.runtimeIdentity == context.identity,
              decision.revision == context.coordinatorRevision,
              eligibleContext(context),
              !context.cancellationToken.isCancelled,
              let teardownOperation
        else {
            return .init(cursorBinding: nil, neutralResult: deniedResult(for: decision, context: context))
        }
        guard let proof = await validProof(in: context, integration: integration),
              let approvalID = proof.approvalID,
              !context.cancellationToken.isCancelled
        else {
            return .init(cursorBinding: nil, neutralResult: deniedResult(for: decision, context: context))
        }

        let lease = ExternalMCPRuntimeBindingLease(
            integrationID: integration.integrationID,
            runtimeIdentity: context.identity,
            sessionClass: context.sessionClass,
            coordinatorRevision: context.coordinatorRevision,
            isAccepted: true,
            cancellationToken: context.cancellationToken,
            revokeOperation: { [teardownOperation, context, integration, approvalID] in
                await teardownOperation(context, integration, approvalID)
            }
        )
        return .init(
            cursorBinding: .init(integrationID: integration.integrationID, approvalID: approvalID, lease: lease),
            neutralResult: .init(lease: lease, decision: decision)
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
              let proof = await validProof(in: context, integration: integration),
              let approvalID = proof.approvalID
        else {
            return .init(
                receipt: .init(outcome: .unsupported, detail: "Cursor external MCP cleanup was not authorized."),
                snapshot: .disconnected(integrationID: integration.integrationID)
            )
        }
        guard !context.cancellationToken.isCancelled,
              let teardownOperation
        else {
            return .init(
                receipt: .init(outcome: .indeterminate, detail: "Cursor approval lease cleanup was not configured."),
                snapshot: .disconnected(integrationID: integration.integrationID)
            )
        }
        return await .init(
            receipt: teardownOperation(context, integration, approvalID),
            snapshot: .disconnected(integrationID: integration.integrationID)
        )
    }

    private func eligibleContext(_ context: ExternalMCPProviderRuntimeContext) -> Bool {
        context.identity.provider == .cursor
            && context.identity.runtimeKind == .acp
            && context.isolation == .ceIsolated
            && context.sessionClass == .topLevel
    }

    private func validProof(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> CursorExternalMCPApprovalProof? {
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
              let approvalID = proof.approvalID,
              !approvalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return proof
    }

    private func unavailableSnapshot(
        for integration: ExternalMCPIntegrationDefinition
    ) -> ExternalMCPRuntimeSnapshot {
        .init(
            integrationID: integration.integrationID,
            connection: .unavailable,
            authentication: .unsupported,
            diagnostics: ["Cursor external MCP support was not proven."]
        )
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
