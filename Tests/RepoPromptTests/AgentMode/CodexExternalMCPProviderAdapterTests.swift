import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexExternalMCPProviderAdapterTests: XCTestCase {
    func testVerifiedCodexSnapshotIsRequiredBeforeBinding() async throws {
        let service = TestFigmaIntegrationService(
            snapshot: .init(
                state: .connected,
                authentication: .authenticated,
                tools: [.init(name: "figma_whoami")],
                lastSuccessfulCheck: Date(),
                failureMessage: nil
            )
        )
        let adapter = CodexFigmaExternalMCPProviderAdapter(service: service)
        let currentContext = context()
        let result = await adapter.applyRuntimeAccess(in: currentContext, decision: decision(for: currentContext))

        XCTAssertTrue(result.decision.isAllowed)
        let lease = try XCTUnwrap(result.lease)
        XCTAssertTrue(lease.isAccepted)
        let missingRevocation = await lease.revoke()
        XCTAssertEqual(missingRevocation.outcome, .indeterminate)

        let unauthenticatedService = TestFigmaIntegrationService(
            snapshot: .init(
                state: .connected,
                authentication: .notLoggedIn,
                tools: [],
                lastSuccessfulCheck: nil,
                failureMessage: nil
            )
        )
        let unauthenticatedContext = context()
        let denied = await CodexFigmaExternalMCPProviderAdapter(service: unauthenticatedService)
            .applyRuntimeAccess(
                in: unauthenticatedContext,
                decision: decision(
                    for: unauthenticatedContext,
                    snapshot: .init(
                        integrationID: ExternalMCPIntegrationDefinition.figma().integrationID,
                        connection: .connected,
                        authentication: .unauthenticated
                    )
                )
            )
        XCTAssertNil(denied.lease)
        XCTAssertEqual(denied.decision.reason, .unauthenticated)
    }

    func testAlreadyDeniedDecisionIsPreserved() async {
        let current = context()
        let denied = ExternalMCPAccessDecision.denied(
            integrationID: ExternalMCPIntegrationDefinition.figma().integrationID,
            runtimeIdentity: current.identity,
            revision: current.coordinatorRevision,
            reason: .unauthenticated
        )
        let result = await CodexFigmaExternalMCPProviderAdapter()
            .applyRuntimeAccess(in: current, decision: denied)
        XCTAssertNil(result.lease)
        XCTAssertEqual(result.decision, denied)
    }

    func testMissingVerificationProofFailsClosed() async {
        let current = context()
        let decision = ExternalMCPAccessDecision(
            integrationID: ExternalMCPIntegrationDefinition.figma().integrationID,
            runtimeIdentity: current.identity,
            revision: current.coordinatorRevision,
            isAllowed: true,
            reason: .granted
        )
        let result = await CodexFigmaExternalMCPProviderAdapter()
            .applyRuntimeAccess(in: current, decision: decision)
        XCTAssertNil(result.lease)
        XCTAssertEqual(result.decision.reason, .staleRevision)
    }

    @MainActor
    func testAppCompositionReusesFigmaLifecycleAndComposesAllAdapters() {
        let composition = FigmaMCPTestGraph.make()
        XCTAssertIdentical(
            composition.figmaCoordinator.runtimeAvailabilityAuthority,
            composition.figmaCoordinator.runtimeAvailability
        )
        let codexAdapter = composition.registry.adapter(for: .codex) as? CodexFigmaExternalMCPProviderAdapter
        XCTAssertIdentical(codexAdapter?.serviceForTesting, composition.figmaCoordinator.service as AnyObject)
        XCTAssertEqual(composition.registry.registeredProviders, Set(ExternalMCPRuntimeProvider.allCases))
    }

    @MainActor
    func testProductionLeaseRevocationDoesNotGloballyRevokeFigma() async throws {
        let composition = FigmaMCPTestGraph.make()
        let adapter = try XCTUnwrap(
            composition.registry.adapter(for: .codex) as? CodexFigmaExternalMCPProviderAdapter
        )
        let context = context()
        let beforeRevision = composition.figmaCoordinator.runtimeAvailability.revision
        let result = await adapter.applyRuntimeAccess(
            in: context,
            decision: decision(for: context)
        )
        let lease = try XCTUnwrap(result.lease)

        let receipt = await lease.revoke()

        XCTAssertEqual(receipt.outcome, .indeterminate)
        XCTAssertEqual(composition.figmaCoordinator.runtimeAvailability.revision, beforeRevision)
    }

    func testCodexRevocationRunsInjectedCoordinatorCleanup() async throws {
        let service = TestFigmaIntegrationService(
            snapshot: .init(state: .connected, authentication: .authenticated, tools: [], lastSuccessfulCheck: nil, failureMessage: nil)
        )
        let cleanup = CleanupProbe()
        let adapter = CodexFigmaExternalMCPProviderAdapter(
            service: service,
            revocationOperation: {
                await cleanup.markCalled()
                return .init(outcome: .completed, detail: "revoked")
            }
        )
        let current = context()
        let result = await adapter.applyRuntimeAccess(in: current, decision: decision(for: current))
        let lease = try XCTUnwrap(result.lease)
        let firstReceipt = await lease.revoke()
        let secondReceipt = await lease.revoke()
        let cleanupWasCalled = await cleanup.wasCalled()
        XCTAssertEqual(firstReceipt.outcome, .completed)
        XCTAssertTrue(cleanupWasCalled)
        XCTAssertEqual(secondReceipt.detail, "revoked")
    }

    func testRegistryComposesEachRuntimeProviderAndRejectsCollisions() throws {
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(CodexFigmaExternalMCPProviderAdapter())
        try registry.register(ClaudeCodeExternalMCPProviderAdapter())
        try registry.register(OpenCodeExternalMCPProviderAdapter())
        try registry.register(CursorExternalMCPProviderAdapter())
        try registry.register(GrokBuildExternalMCPProviderAdapter())
        try registry.register(AntigravityExternalMCPProviderAdapter())
        try registry.register(DevinExternalMCPProviderAdapter())

        XCTAssertEqual(registry.registeredProviders, Set(ExternalMCPRuntimeProvider.allCases))
        XCTAssertTrue(registry.adapter(for: .codex) is CodexFigmaExternalMCPProviderAdapter)

        XCTAssertThrowsError(try registry.register(GrokBuildExternalMCPProviderAdapter())) { error in
            XCTAssertEqual(
                error as? ExternalMCPAdapterRegistry.RegistrationError,
                .duplicateProvider(.grokBuild)
            )
        }
    }

    func testClaudeAndGrokRemainFailClosed() async {
        let adapters: [any ExternalMCPProviderAdapter] = [
            ClaudeCodeExternalMCPProviderAdapter(),
            GrokBuildExternalMCPProviderAdapter()
        ]
        for adapter in adapters {
            let context = context(provider: adapter.runtimeProvider)
            let capabilities = await adapter.capabilities(in: context)
            XCTAssertEqual(capabilities, .unsupported)
            let status = await adapter.refreshStatus(in: context, integration: .figma())
            XCTAssertEqual(status.connection, .unavailable)
            let result = await adapter.applyRuntimeAccess(in: context, decision: decision(for: context))
            XCTAssertNil(result.lease)
            XCTAssertFalse(result.decision.isAllowed)
        }
    }

    private func context(
        provider: ExternalMCPRuntimeProvider = .codex
    ) -> ExternalMCPProviderRuntimeContext {
        ExternalMCPProviderRuntimeContext(
            identity: .init(
                provider: provider,
                runtimeKind: provider == .codex ? .appServer : .acp,
                executableIdentity: "/usr/local/bin/provider"
            ),
            sessionClass: .topLevel,
            isolation: .ceIsolated,
            coordinatorRevision: 3
        )
    }

    private func decision(
        for context: ExternalMCPProviderRuntimeContext,
        snapshot: ExternalMCPRuntimeSnapshot? = nil
    ) -> ExternalMCPAccessDecision {
        .init(
            integrationID: ExternalMCPIntegrationDefinition.figma().integrationID,
            runtimeIdentity: context.identity,
            revision: context.coordinatorRevision,
            isAllowed: true,
            reason: .granted,
            verifiedSnapshot: snapshot ?? .init(
                integrationID: ExternalMCPIntegrationDefinition.figma().integrationID,
                connection: .connected,
                authentication: .authenticated
            )
        )
    }
}

private actor CleanupProbe {
    private var called = false

    func markCalled() {
        called = true
    }

    func wasCalled() -> Bool {
        called
    }
}

private actor TestFigmaIntegrationService: FigmaMCPIntegrationManaging {
    private let currentSnapshot: FigmaMCPIntegrationSnapshot

    init(snapshot: FigmaMCPIntegrationSnapshot) {
        currentSnapshot = snapshot
    }

    func refresh(definition: ExternalMCPIntegrationDefinition?) async -> FigmaMCPIntegrationSnapshot {
        guard definition?.integrationID == ExternalMCPIntegrationDefinition.figma().integrationID else {
            return invalidRequestSnapshot
        }
        return currentSnapshot
    }

    func cancelStatusRefresh() async {}

    func snapshot() async -> FigmaMCPIntegrationSnapshot {
        currentSnapshot
    }

    func discoverExistingImport() async -> FigmaMCPImportDiscovery {
        .absent
    }

    func connect(
        definition: ExternalMCPIntegrationDefinition
    ) async -> (FigmaMCPConnectResult, FigmaMCPAuthorizationRequest?) {
        guard definition.integrationID == ExternalMCPIntegrationDefinition.figma().integrationID else {
            return (.failed, nil)
        }
        return (.failed, nil)
    }

    func disconnect(definition: ExternalMCPIntegrationDefinition) async -> FigmaMCPDisconnectResult {
        guard definition.integrationID == ExternalMCPIntegrationDefinition.figma().integrationID else {
            return .failed
        }
        return .failed
    }

    func invalidatePresentationSnapshot() async {}
    func settleAuthorizationHandoff(id _: UUID, disposition _: FigmaMCPAuthorizationHandoffDisposition) async {}
    func cancelCurrentOperation() async {}

    private var invalidRequestSnapshot: FigmaMCPIntegrationSnapshot {
        .init(
            state: .failed,
            authentication: .unsupported,
            tools: [],
            lastSuccessfulCheck: nil,
            failureMessage: "unexpected integration identity"
        )
    }
}
