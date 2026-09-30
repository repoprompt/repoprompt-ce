import Foundation

/// Neutral adapter for the existing Codex-owned Figma lifecycle.
///
/// This adapter is deliberately a translation layer: OAuth, Codex state, configuration
/// reconciliation, credential logout, and the app-lifetime revocation barrier remain owned by
/// `CodexExternalMCPIntegrationService` and `FigmaMCPIntegrationCoordinator`.
struct CodexFigmaExternalMCPProviderAdapter: ExternalMCPProviderAdapter {
    let runtimeProvider: ExternalMCPRuntimeProvider = .codex

    typealias RevocationOperation = @MainActor @Sendable () async -> ExternalMCPCleanupReceipt

    private let service: any FigmaMCPIntegrationManaging
    private let bindingCleanupOperation: RevocationOperation?

    init(
        service: any FigmaMCPIntegrationManaging = CodexExternalMCPIntegrationService(),
        bindingCleanupOperation: RevocationOperation? = nil,
        revocationOperation: RevocationOperation? = nil
    ) {
        self.service = service
        self.bindingCleanupOperation = bindingCleanupOperation ?? revocationOperation
    }

    #if DEBUG
        var serviceForTesting: AnyObject {
            service as AnyObject
        }
    #endif

    func capabilities(in context: ExternalMCPProviderRuntimeContext) async -> ExternalMCPCapabilityDescriptor {
        guard isTopLevelCodexContext(context) else { return .unsupported }
        return ExternalMCPCapabilityDescriptor(
            discovery: .supported,
            interactiveAuthentication: .supported,
            statusVerification: .supported,
            managedConfigurationInstallation: .supported,
            adoptedImport: .supported,
            credentialLogout: .supported,
            runtimeInjection: .supported,
            childSessionInheritance: .unsupported
        )
    }

    func discoverExisting(in context: ExternalMCPProviderRuntimeContext) async -> ExternalMCPDiscoveryResult {
        guard isCodexDiscoveryContext(context) else {
            return .init(status: .unsupported, definition: nil)
        }
        switch await service.discoverExistingImport() {
        case .absent:
            return .init(status: .notFound, definition: nil)
        case .available:
            return .init(status: .found, definition: .adoptedFigmaImport())
        case .unavailable:
            return .init(status: .indeterminate, definition: nil)
        case .cancelled:
            return .init(status: .indeterminate, definition: nil)
        }
    }

    func authenticate(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPAuthenticationResult {
        guard isTopLevelCodexContext(context), integration.isSupportedDefinition else {
            return unsupportedAuthentication(for: integration)
        }

        let result = await service.connectWithEffects(definition: integration)
        let currentSnapshot = await service.snapshot()
        switch result.result {
        case let .connected(snapshot):
            return .init(status: .authenticated, snapshot: neutralSnapshot(from: snapshot))
        case .authorizationRequired:
            return .init(
                status: context.cancellationToken.isCancelled ? .cancelled : .requiresHandoff,
                handoffURL: context.cancellationToken.isCancelled ? nil : result.authorizationRequest?.url,
                snapshot: neutralSnapshot(from: currentSnapshot)
            )
        case .cancelled:
            return .init(status: .cancelled, snapshot: neutralSnapshot(from: currentSnapshot))
        case .failed:
            return .init(status: .failed, snapshot: neutralSnapshot(from: currentSnapshot))
        }
    }

    func refreshStatus(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPRuntimeSnapshot {
        guard isTopLevelCodexContext(context), integration.isSupportedDefinition else {
            return unavailableSnapshot(for: integration)
        }
        let receipt = await service.refreshWithReceipt(definition: integration)
        guard receipt.isAuthoritative else {
            return unavailableSnapshot(for: integration)
        }
        return neutralSnapshot(from: receipt.snapshot)
    }

    func applyRuntimeAccess(
        in context: ExternalMCPProviderRuntimeContext,
        decision: ExternalMCPAccessDecision
    ) async -> ExternalMCPRuntimeBindingResult {
        // An authoritative denial is already the coordinator's answer. Never rewrite it as
        // unsupported: callers need to distinguish authentication, availability, and revision
        // failures for safe retry/presentation behavior.
        guard decision.isAllowed else {
            return .init(lease: nil, decision: decision)
        }
        guard decision.reason == .granted,
              decision.integrationID == ExternalMCPIntegrationDefinition.figma().integrationID,
              decision.runtimeIdentity == context.identity,
              decision.revision == context.coordinatorRevision,
              isTopLevelCodexContext(context),
              !context.cancellationToken.isCancelled
        else {
            return deniedResult(for: decision, context: context, reason: .staleRevision)
        }

        guard let snapshot = decision.verifiedSnapshot,
              snapshot.integrationID == decision.integrationID
        else {
            return deniedResult(for: decision, context: context, reason: .staleRevision)
        }
        guard snapshot.connection == .connected,
              snapshot.authentication == .authenticated,
              !context.cancellationToken.isCancelled
        else {
            return deniedResult(
                for: decision,
                context: context,
                reason: context.cancellationToken.isCancelled ? .cancelled :
                    (snapshot.connection == .unavailable ? .unavailable : .unauthenticated)
            )
        }

        let lease = ExternalMCPRuntimeBindingLease(
            integrationID: decision.integrationID,
            runtimeIdentity: context.identity,
            sessionClass: context.sessionClass,
            coordinatorRevision: context.coordinatorRevision,
            isAccepted: true,
            cancellationToken: context.cancellationToken,
            revokeOperation: bindingCleanupOperation
                .map { operation in
                    { await operation() }
                }
        )
        return .init(lease: lease, decision: decision)
    }

    func disconnect(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPDisconnectResult {
        guard isTopLevelCodexContext(context), integration.isSupportedDefinition else {
            return .init(
                receipt: .init(outcome: .unsupported),
                snapshot: unavailableSnapshot(for: integration)
            )
        }

        let result = await service.disconnectWithEffects(definition: integration)
        let receipt: ExternalMCPCleanupReceipt = switch result.result {
        case .disconnected: .init(outcome: .completed)
        case .cancelled: .init(outcome: .cancelled)
        case .failed: .init(outcome: .failed)
        }
        return await .init(receipt: receipt, snapshot: neutralSnapshot(from: service.snapshot()))
    }

    private func isTopLevelCodexContext(_ context: ExternalMCPProviderRuntimeContext) -> Bool {
        context.identity.provider == .codex
            && context.identity.runtimeKind == .appServer
            && context.isolation == .ceIsolated
            && context.sessionClass == .topLevel
    }

    private func isCodexDiscoveryContext(_ context: ExternalMCPProviderRuntimeContext) -> Bool {
        context.identity.provider == .codex
            && context.identity.runtimeKind == .appServer
            && context.isolation == .ceIsolated
            && context.sessionClass == .discovery
    }

    private func unsupportedAuthentication(
        for integration: ExternalMCPIntegrationDefinition
    ) -> ExternalMCPAuthenticationResult {
        .init(status: .unsupported, snapshot: unavailableSnapshot(for: integration))
    }

    private func unavailableSnapshot(
        for integration: ExternalMCPIntegrationDefinition
    ) -> ExternalMCPRuntimeSnapshot {
        .init(
            integrationID: integration.integrationID,
            connection: .unavailable,
            authentication: .unsupported,
            diagnostics: ["Codex Figma MCP runtime is unavailable."]
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

    private func neutralSnapshot(
        from snapshot: FigmaMCPIntegrationSnapshot
    ) -> ExternalMCPRuntimeSnapshot {
        let connection: ExternalMCPRuntimeConnectionState = switch snapshot.state {
        case .notConfigured: .disconnected
        case .connecting, .reconnecting: .connecting
        case .connected: .connected
        case .authorizationRequired, .expired, .failed: .failed
        case .serverUnavailable: .unavailable
        }
        let authentication: ExternalMCPAuthenticationState = switch snapshot.authentication {
        case .unknown: .unknown
        case .notLoggedIn: .unauthenticated
        case .expired: .expired
        case .authenticated: .authenticated
        case .unsupported: .unsupported
        }
        return .init(
            integrationID: ExternalMCPIntegrationDefinition.figma().integrationID,
            connection: connection,
            authentication: authentication,
            verifiedAt: snapshot.lastSuccessfulCheck,
            toolCount: snapshot.tools.count,
            toolLabels: snapshot.tools.map(\.name),
            diagnostics: snapshot.failureMessage.map { [$0] } ?? []
        )
    }
}
