import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class FigmaMCPProviderStatusServiceTests: XCTestCase {
    func testProductionNewFamiliesCannotProbeOrPublishConnected() async {
        let composition = FigmaMCPTestGraph.make()
        let service = composition.figmaProviderStatusService
        let devin = await service.checkStatus(provider: .devin, target: .figma)
        let antigravity = await service.checkStatus(provider: .antigravity, target: .figma)
        XCTAssertEqual(devin, .unverifiedCapability)
        XCTAssertEqual(antigravity, .unsupported)
        for provider in [ExternalMCPRuntimeProvider.devin, .antigravity] {
            let registration = composition.registry.registration(for: provider)
            XCTAssertNil(registration?.targetResolver)
            XCTAssertNil(registration?.structuredProofChecker)
            XCTAssertNil(registration?.structuredStatusChecker)
        }
    }

    func testCanonicalTargetDoesNotRequirePersistedDefinitionAndUsesOnlyStructuredProof() async throws {
        let adapter = RecordingExternalMCPAdapter(provider: .openCode)
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "opencode-figma-proof",
            capabilityRevision: "1"
        )
        let resolver = TestFigmaTargetResolver(
            provider: .openCode,
            resolution: .resolved(
                providerTargetIdentifier: "figma",
                source: .providerStandardUserMetadata,
                credentialContext: .providerDefaultUserProfile
            )
        )
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: adapter,
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .unverified(.liveGatePending),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: resolver,
            structuredProofChecker: { target, _, _, generation in
                .init(
                    runtimeProvider: .openCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned,
                        toolLabels: ["figma_whoami", "https://private.invalid"]
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                )
            }
        ))
        let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
        let service = FigmaMCPProviderStatusService(registry: registry, coordinator: coordinator)

        let result = await service.checkStatus(provider: .openCode, target: .figma)

        guard case let .verifiedProvider(proof) = result else {
            return XCTFail("Expected a provider-bound structured proof, got \(result)")
        }
        XCTAssertEqual(proof.runtimeProvider, .openCode)
        XCTAssertEqual(proof.canonicalTarget, .figma)
        XCTAssertEqual(proof.providerTargetIdentifier, "figma")
        XCTAssertEqual(proof.credentialContext, .providerDefaultUserProfile)
        XCTAssertEqual(proof.sanitizedSnapshot.toolLabels, ["figma_whoami"])
        XCTAssertEqual(adapter.refreshCount, 0)
        XCTAssertEqual(resolver.callCount, 1)
    }

    func testVerifiedLoginSupportWithoutVerifiedProofCapabilitySkipsStatusChecks() async throws {
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "open-proof",
            capabilityRevision: "1"
        )
        let adapter = RecordingExternalMCPAdapter(provider: .openCode)
        let resolver = TestFigmaTargetResolver(
            provider: .openCode,
            resolution: .resolved(
                providerTargetIdentifier: "figma",
                source: .providerStandardUserMetadata,
                credentialContext: .providerDefaultUserProfile
            )
        )
        let checkerCalls = CallCounter()
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: adapter,
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .unverified(.noStructuredProofContract),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: resolver,
            loginDriver: NoopLoginDriver(runtimeProvider: .openCode),
            structuredProofChecker: { _, _, _, _ in
                checkerCalls.increment()
                return nil
            }
        ))
        let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
        let service = FigmaMCPProviderStatusService(registry: registry, coordinator: coordinator)

        let result = await service.checkStatus(provider: .openCode, target: .figma)

        XCTAssertEqual(result, .unverifiedCapability)
        XCTAssertEqual(adapter.refreshCount, 0)
        XCTAssertEqual(resolver.callCount, 0)
        XCTAssertEqual(checkerCalls.value, 0)
    }

    func testUnverifiedCapabilityDoesNotCallAdapterResolverOrProofChecker() async throws {
        let adapter = RecordingExternalMCPAdapter(provider: .cursor)
        let resolver = TestFigmaTargetResolver(
            provider: .cursor,
            resolution: .resolved(
                providerTargetIdentifier: "figma",
                source: .providerStandardUserMetadata,
                credentialContext: .providerDefaultUserProfile
            )
        )
        let checkerCalls = CallCounter()
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(ExternalMCPProviderRegistration(
            provider: .cursor,
            adapter: adapter,
            figmaCapabilities: .init(
                provider: .cursor,
                loginSupport: .unverified(.liveGatePending),
                proofSupport: .unverified(.noStructuredProofContract),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: resolver,
            structuredProofChecker: { _, _, _, _ in
                checkerCalls.increment()
                return nil
            }
        ))
        let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
        let service = FigmaMCPProviderStatusService(registry: registry, coordinator: coordinator)

        let result = await service.checkStatus(provider: .cursor, target: .figma)

        XCTAssertEqual(result, .unverifiedCapability)
        XCTAssertEqual(adapter.refreshCount, 0)
        XCTAssertEqual(resolver.callCount, 0)
        XCTAssertEqual(checkerCalls.value, 0)
    }

    func testGenericAuthenticatedSnapshotCannotBecomeProviderProof() async throws {
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .claudeCode,
            evidenceID: "claude-proof",
            capabilityRevision: "1"
        )
        let resolver = TestFigmaTargetResolver(
            provider: .claudeCode,
            resolution: .resolved(
                providerTargetIdentifier: "plugin:figma:figma",
                source: .reviewedFixedIdentifier,
                credentialContext: .providerDefaultUserProfile
            )
        )
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(ExternalMCPProviderRegistration(
            provider: .claudeCode,
            adapter: RecordingExternalMCPAdapter(provider: .claudeCode),
            figmaCapabilities: .init(
                provider: .claudeCode,
                loginSupport: .unverified(.liveGatePending),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: resolver,
            structuredProofChecker: { target, _, _, generation in
                .init(
                    runtimeProvider: .claudeCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "plugin:figma:figma",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .authenticated
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                )
            }
        ))
        let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
        let service = FigmaMCPProviderStatusService(registry: registry, coordinator: coordinator)

        let result = await service.checkStatus(provider: .claudeCode, target: .figma)

        XCTAssertEqual(result, .stale)
    }

    func testProofIdentityAndCapabilityMismatchesFailClosed() async throws {
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "expected-proof",
            capabilityRevision: "2"
        )
        let resolver = TestFigmaTargetResolver(
            provider: .openCode,
            resolution: .resolved(
                providerTargetIdentifier: "figma",
                source: .providerStandardUserMetadata,
                credentialContext: .providerDefaultUserProfile
            )
        )
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: RecordingExternalMCPAdapter(provider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .unverified(.liveGatePending),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: resolver,
            structuredProofChecker: { target, _, _, generation in
                .init(
                    runtimeProvider: .cursor,
                    canonicalTarget: target,
                    providerTargetIdentifier: "wrong-target",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: "wrong-proof",
                    capabilityRevision: "wrong-revision",
                    operationGeneration: generation
                )
            }
        ))
        let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
        let service = FigmaMCPProviderStatusService(registry: registry, coordinator: coordinator)

        let result = await service.checkStatus(provider: .openCode, target: .figma)

        XCTAssertEqual(result, .stale)
    }

    func testTypedUnauthenticatedAndExpiredOutcomesRemainNegative() async throws {
        for outcome in [FigmaMCPProviderStructuredStatusOutcome.unauthenticated, .expired] {
            let evidence = FigmaMCPProviderCapabilityEvidence(
                provider: .openCode,
                evidenceID: "negative-proof",
                capabilityRevision: "revision-1"
            )
            let resolution = TestFigmaTargetResolver(
                provider: .openCode,
                resolution: .resolved(
                    providerTargetIdentifier: "figma",
                    source: .providerStandardUserMetadata,
                    credentialContext: .providerDefaultUserProfile
                )
            )
            var registry = ExternalMCPAdapterRegistry()
            try registry.register(ExternalMCPProviderRegistration(
                provider: .openCode,
                adapter: RecordingExternalMCPAdapter(provider: .openCode),
                figmaCapabilities: .init(
                    provider: .openCode,
                    loginSupport: .unverified(.liveGatePending),
                    proofSupport: .verified(evidence),
                    revocationSupport: .unverified(.noRevocationContract),
                    runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
                ),
                targetResolver: resolution,
                structuredStatusChecker: { _, _, _, _ in outcome }
            ))
            let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
            let service = FigmaMCPProviderStatusService(registry: registry, coordinator: coordinator)

            let result = await service.checkStatus(provider: .openCode, target: .figma)
            XCTAssertEqual(result, .stale)
        }
    }

    func testCodexAndUnsupportedProvidersAreRejectedWithoutCalls() async throws {
        let adapter = RecordingExternalMCPAdapter(provider: .grokBuild)
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(adapter)
        let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
        let service = FigmaMCPProviderStatusService(registry: registry, coordinator: coordinator)

        let codexResult = await service.checkStatus(provider: .codex, target: .figma)
        let grokResult = await service.checkStatus(provider: .grokBuild, target: .figma)
        XCTAssertEqual(codexResult, .unsupported)
        XCTAssertEqual(grokResult, .unverifiedCapability)
        XCTAssertEqual(adapter.refreshCount, 0)
    }
}

private final class TestFigmaTargetResolver: FigmaMCPProviderTargetResolving, @unchecked Sendable {
    let runtimeProvider: ExternalMCPRuntimeProvider
    let resolution: FigmaMCPProviderTargetResolution
    private(set) var callCount = 0
    private let lock = NSLock()

    init(provider: ExternalMCPRuntimeProvider, resolution: FigmaMCPProviderTargetResolution) {
        runtimeProvider = provider
        self.resolution = resolution
    }

    func resolveTarget(for _: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderTargetResolution {
        lock.lock()
        callCount += 1
        lock.unlock()
        return resolution
    }
}

private final class CallCounter: @unchecked Sendable {
    private(set) var value = 0
    private let lock = NSLock()

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private struct NoopLoginDriver: FigmaMCPProviderLoginDriving, @unchecked Sendable {
    let runtimeProvider: ExternalMCPRuntimeProvider

    func evaluateAvailability(
        provider _: ExternalMCPRuntimeProvider,
        target _: ExternalMCPIntegrationTarget
    ) async -> FigmaMCPProviderLoginAvailability {
        .available
    }

    func beginLogin(
        provider _: ExternalMCPRuntimeProvider,
        target _: ExternalMCPIntegrationTarget,
        attemptContext _: FigmaMCPProviderLoginAttemptContext
    ) async -> FigmaMCPProviderLoginSettlement {
        .exited(status: 0)
    }

    func cancelLogin(provider _: ExternalMCPRuntimeProvider, attemptID _: UUID) async {}
}

private final class RecordingExternalMCPAdapter: @unchecked Sendable, ExternalMCPProviderAdapter {
    let runtimeProvider: ExternalMCPRuntimeProvider
    private(set) var refreshCount = 0
    private let lock = NSLock()

    init(provider: ExternalMCPRuntimeProvider) {
        runtimeProvider = provider
    }

    func capabilities(in _: ExternalMCPProviderRuntimeContext) async -> ExternalMCPCapabilityDescriptor {
        .unsupported
    }

    func discoverExisting(in _: ExternalMCPProviderRuntimeContext) async -> ExternalMCPDiscoveryResult {
        .init(status: .unsupported, definition: nil)
    }

    func authenticate(
        in _: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPAuthenticationResult {
        .init(status: .unsupported, snapshot: .disconnected(integrationID: integration.integrationID))
    }

    func refreshStatus(
        in _: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPRuntimeSnapshot {
        lock.lock()
        refreshCount += 1
        lock.unlock()
        return .init(
            integrationID: integration.integrationID,
            connection: .connected,
            authentication: .providerOwned
        )
    }

    func applyRuntimeAccess(
        in _: ExternalMCPProviderRuntimeContext,
        decision: ExternalMCPAccessDecision
    ) async -> ExternalMCPRuntimeBindingResult {
        .init(lease: nil, decision: decision)
    }

    func disconnect(
        in _: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPDisconnectResult {
        .init(receipt: .init(outcome: .unsupported), snapshot: .disconnected(integrationID: integration.integrationID))
    }
}
