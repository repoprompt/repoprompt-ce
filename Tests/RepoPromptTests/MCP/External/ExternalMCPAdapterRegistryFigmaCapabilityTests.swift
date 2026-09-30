import Foundation
@testable import RepoPromptApp
import XCTest

final class ExternalMCPAdapterRegistryFigmaCapabilityTests: XCTestCase {
    func testAdapterOnlyRegistrationDefaultsEveryFigmaAxisToUnverified() throws {
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(CountingExternalMCPAdapter(provider: .openCode))

        let registration = try XCTUnwrap(registry.registration(for: .openCode))
        XCTAssertEqual(registration.figmaCapabilities, .adapterOnly(for: .openCode))
    }

    func testExplicitUnsupportedRegistrationKeepsEveryFigmaAxisUnsupported() throws {
        let provider = ExternalMCPRuntimeProvider.grokBuild
        let registration = ExternalMCPProviderRegistration(
            provider: provider,
            adapter: GrokBuildExternalMCPProviderAdapter(),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .unsupported(.unsupportedProviderRoute),
                proofSupport: .unsupported(.unsupportedProviderRoute),
                revocationSupport: .unsupported(.unsupportedProviderRoute),
                runtimeBindingSupport: .unsupported(.unsupportedProviderRoute)
            )
        )

        let registry = try ExternalMCPAdapterRegistry(registrations: [registration])
        XCTAssertEqual(registry.registration(for: provider)?.figmaCapabilities, registration.figmaCapabilities)
    }

    func testNewFailClosedAdaptersDoNotGainAuthorityFromRegistration() throws {
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(DevinExternalMCPProviderAdapter())
        try registry.register(ExternalMCPProviderRegistration(
            provider: .antigravity,
            adapter: AntigravityExternalMCPProviderAdapter(),
            figmaCapabilities: .init(
                provider: .antigravity,
                loginSupport: .unsupported(.unsupportedProviderRoute),
                proofSupport: .unsupported(.unsupportedProviderRoute),
                revocationSupport: .unsupported(.unsupportedProviderRoute),
                runtimeBindingSupport: .unsupported(.unsupportedProviderRoute)
            )
        ))
        XCTAssertEqual(registry.registration(for: .devin)?.figmaCapabilities, .adapterOnly(for: .devin))
        for provider in [ExternalMCPRuntimeProvider.devin, .antigravity] {
            let registration = try XCTUnwrap(registry.registration(for: provider))
            XCTAssertFalse(registration.figmaCapabilities.runtimeBindingSupport.isAuthorityEnabled)
            XCTAssertNil(registration.targetResolver)
            XCTAssertNil(registration.loginDriver)
            XCTAssertNil(registration.structuredProofChecker)
            XCTAssertNil(registration.structuredStatusChecker)
        }
    }

    func testRegistrationRejectsProviderAndCapabilityMismatches() {
        var registry = ExternalMCPAdapterRegistry()
        XCTAssertThrowsError(try registry.register(ExternalMCPProviderRegistration(
            provider: .cursor,
            adapter: GrokBuildExternalMCPProviderAdapter(),
            figmaCapabilities: .adapterOnly(for: .cursor)
        ))) { error in
            XCTAssertEqual(
                error as? ExternalMCPAdapterRegistry.RegistrationError,
                .providerMismatch(registration: .cursor, adapter: .grokBuild)
            )
        }

        XCTAssertThrowsError(try registry.register(ExternalMCPProviderRegistration(
            provider: .cursor,
            adapter: CursorExternalMCPProviderAdapter(),
            figmaCapabilities: .adapterOnly(for: .grokBuild)
        ))) { error in
            XCTAssertEqual(
                error as? ExternalMCPAdapterRegistry.RegistrationError,
                .capabilityProviderMismatch(registration: .cursor, capability: .grokBuild)
            )
        }
    }

    func testRegistrationRejectsMismatchedDriverAndIncompleteVerifiedLogin() {
        var registry = ExternalMCPAdapterRegistry()
        let capabilities = FigmaMCPProviderCapabilityRegistration(
            provider: .cursor,
            loginSupport: .verified(.init(provider: .cursor, evidenceID: "login", capabilityRevision: "1")),
            proofSupport: .unverified(.noStructuredProofContract),
            revocationSupport: .unverified(.noRevocationContract),
            runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
        )
        XCTAssertThrowsError(try registry.register(ExternalMCPProviderRegistration(
            provider: .cursor,
            adapter: CursorExternalMCPProviderAdapter(),
            figmaCapabilities: capabilities,
            targetResolver: TestFigmaTargetResolver(runtimeProvider: .cursor),
            loginDriver: TestFigmaLoginDriver(runtimeProvider: .openCode)
        ))) { error in
            XCTAssertEqual(
                error as? ExternalMCPAdapterRegistry.RegistrationError,
                .loginDriverProviderMismatch(registration: .cursor, driver: .openCode)
            )
        }

        XCTAssertThrowsError(try registry.register(ExternalMCPProviderRegistration(
            provider: .cursor,
            adapter: CursorExternalMCPProviderAdapter(),
            figmaCapabilities: capabilities,
            loginDriver: TestFigmaLoginDriver(runtimeProvider: .cursor)
        ))) { error in
            XCTAssertEqual(
                error as? ExternalMCPAdapterRegistry.RegistrationError,
                .verifiedLoginRequiresTargetResolver(.cursor)
            )
        }
    }

    func testVerifiedNonCodexRuntimeRejectsGenericAuthenticatedSnapshots() async throws {
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "structured-proof",
            capabilityRevision: "1"
        )
        let definition = ExternalMCPIntegrationDefinition.figma()
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: CountingExternalMCPAdapter(provider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .unverified(.liveGatePending),
                proofSupport: .verified(evidence),
                revocationSupport: .verified(evidence),
                runtimeBindingSupport: .verified(evidence)
            ),
            targetResolver: TestFigmaTargetResolver(runtimeProvider: .openCode),
            structuredProofChecker: { target, _, _, generation in
                .init(
                    runtimeProvider: .openCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                )
            }
        ))
        let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
        let revision = await coordinator.activeRevision()
        let context = ExternalMCPProviderRuntimeContext(
            identity: .init(provider: .openCode, runtimeKind: .acp, executableIdentity: "opencode"),
            sessionClass: .topLevel,
            isolation: .ceIsolated,
            coordinatorRevision: revision
        )

        let decision = await coordinator.decision(
            integration: definition,
            snapshot: .init(
                integrationID: definition.integrationID,
                connection: .connected,
                authentication: .authenticated
            ),
            context: context
        )

        XCTAssertFalse(decision.isAllowed)
        XCTAssertEqual(decision.reason, .unauthenticated)
    }

    func testVerifiedRuntimeBindingRequiresCurrentExactStructuredProof() async throws {
        let provider = ExternalMCPRuntimeProvider.openCode
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: provider,
            evidenceID: "runtime-proof",
            capabilityRevision: "1"
        )
        let resolver = ResolvedFigmaTargetResolver(runtimeProvider: provider)
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(ExternalMCPProviderRegistration(
            provider: provider,
            adapter: CountingExternalMCPAdapter(provider: provider),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .unverified(.liveGatePending),
                proofSupport: .verified(evidence),
                revocationSupport: .verified(evidence),
                runtimeBindingSupport: .verified(evidence)
            ),
            targetResolver: resolver,
            structuredProofChecker: { _, _, _, _ in nil }
        ))
        let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
        let revision = await coordinator.activeRevision()
        let operationGeneration = await coordinator.beginOperationGeneration(for: provider)
        let context = ExternalMCPProviderRuntimeContext(
            identity: .init(provider: provider, runtimeKind: .acp, executableIdentity: "opencode", executableVersion: "1"),
            sessionClass: .topLevel,
            isolation: .ceIsolated,
            coordinatorRevision: revision
        )
        let proof = FigmaMCPVerifiedProviderStatus(
            runtimeProvider: provider,
            canonicalTarget: .figma,
            providerTargetIdentifier: "figma",
            credentialContext: .providerDefaultUserProfile,
            sanitizedSnapshot: .init(
                integrationID: ExternalMCPIntegrationTarget.figma.integrationID,
                connection: .connected,
                authentication: .providerOwned
            ),
            evidenceID: evidence.evidenceID,
            capabilityRevision: evidence.capabilityRevision,
            executableIdentity: "opencode",
            executableVersion: "1",
            validUntil: Date().addingTimeInterval(60),
            operationGeneration: operationGeneration
        )

        let decision = await coordinator.decision(
            integration: .figma(),
            snapshot: proof.sanitizedSnapshot,
            context: context,
            requestedRevision: revision,
            verifiedStatus: proof,
            operationGeneration: operationGeneration
        )

        XCTAssertTrue(decision.isAllowed)
        XCTAssertEqual(decision.verifiedSnapshot, proof.sanitizedSnapshot)

        try registry.replace(ExternalMCPProviderRegistration(
            provider: provider,
            adapter: CountingExternalMCPAdapter(provider: provider),
            figmaCapabilities: .adapterOnly(for: provider)
        ))
        let staleDecision = await coordinator.decision(
            integration: .figma(),
            snapshot: proof.sanitizedSnapshot,
            context: context,
            requestedRevision: revision,
            verifiedStatus: proof,
            operationGeneration: operationGeneration
        )
        XCTAssertFalse(staleDecision.isAllowed)
        XCTAssertEqual(staleDecision.reason, .staleRevision)
    }

    func testProviderRegistrationReplacementAdvancesSharedRevision() async throws {
        let provider = ExternalMCPRuntimeProvider.openCode
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(CountingExternalMCPAdapter(provider: provider))
        let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
        let originalRevision = await coordinator.activeRevision()

        try registry.replace(ExternalMCPProviderRegistration(
            provider: provider,
            adapter: CountingExternalMCPAdapter(provider: provider),
            figmaCapabilities: .adapterOnly(for: provider)
        ))

        let replacementRevision = await coordinator.currentRevision()
        XCTAssertGreaterThan(replacementRevision, originalRevision)
    }

    func testUnverifiedRuntimeBindingIsDeniedBeforeSnapshotAuthority() async throws {
        let adapter = CountingExternalMCPAdapter(provider: .openCode)
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: adapter,
            figmaCapabilities: .adapterOnly(for: .openCode)
        ))
        let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
        let revision = await coordinator.activeRevision()
        let definition = ExternalMCPIntegrationDefinition.figma()
        let context = ExternalMCPProviderRuntimeContext(
            identity: .init(provider: .openCode, runtimeKind: .acp, executableIdentity: "opencode"),
            sessionClass: .topLevel,
            isolation: .ceIsolated,
            coordinatorRevision: revision
        )

        let decision = await coordinator.decision(
            integration: definition,
            snapshot: .init(
                integrationID: definition.integrationID,
                connection: .connected,
                authentication: .providerOwned
            ),
            context: context
        )

        XCTAssertFalse(decision.isAllowed)
        XCTAssertEqual(decision.reason, .unsupported)
        XCTAssertEqual(adapter.refreshCount, 0)
    }

    func testVerifiedLoginAndProofDoNotEnableRevocationOrRuntime() throws {
        let provider = ExternalMCPRuntimeProvider.openCode
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: provider,
            evidenceID: "proof-only",
            capabilityRevision: "1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: provider,
            adapter: CountingExternalMCPAdapter(provider: provider),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: ResolvedFigmaTargetResolver(runtimeProvider: provider),
            loginDriver: TestFigmaLoginDriver(runtimeProvider: provider),
            structuredProofChecker: { _, _, _, generation in
                .init(
                    runtimeProvider: provider,
                    canonicalTarget: .figma,
                    providerTargetIdentifier: "figma",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: ExternalMCPIntegrationTarget.figma.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                )
            }
        )

        let registry = ExternalMCPAdapterRegistry()
        XCTAssertNoThrow(try registry.register(registration))
        let capabilities = try XCTUnwrap(registry.registration(for: provider)?.figmaCapabilities)
        XCTAssertEqual(capabilities.loginSupport, .verified(evidence))
        XCTAssertEqual(capabilities.proofSupport, .verified(evidence))
        XCTAssertEqual(capabilities.revocationSupport, .unverified(.noRevocationContract))
        XCTAssertEqual(capabilities.runtimeBindingSupport, .unverified(.noRuntimeBindingContract))
    }

    func testVerifiedRuntimeBindingRequiresVerifiedRevocation() throws {
        let provider = ExternalMCPRuntimeProvider.openCode
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: provider,
            evidenceID: "binding-proof",
            capabilityRevision: "1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: provider,
            adapter: CountingExternalMCPAdapter(provider: provider),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .unverified(.liveGatePending),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .verified(evidence)
            ),
            targetResolver: ResolvedFigmaTargetResolver(runtimeProvider: provider),
            structuredProofChecker: { _, _, _, generation in
                .init(
                    runtimeProvider: provider,
                    canonicalTarget: .figma,
                    providerTargetIdentifier: "figma",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: ExternalMCPIntegrationTarget.figma.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                )
            }
        )

        XCTAssertThrowsError(try ExternalMCPAdapterRegistry(registrations: [registration])) { error in
            XCTAssertEqual(
                error as? ExternalMCPAdapterRegistry.RegistrationError,
                .verifiedRuntimeBindingRequiresVerifiedRevocation(provider)
            )
        }
    }

    func testCodexManagedRuntimeBindingRequiresCodexManagedRevocation() throws {
        let registration = ExternalMCPProviderRegistration(
            provider: .codex,
            adapter: CountingExternalMCPAdapter(provider: .codex),
            figmaCapabilities: .init(
                provider: .codex,
                loginSupport: .codexManaged,
                proofSupport: .codexManaged,
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .codexManaged
            )
        )

        XCTAssertThrowsError(try ExternalMCPAdapterRegistry(registrations: [registration])) { error in
            XCTAssertEqual(
                error as? ExternalMCPAdapterRegistry.RegistrationError,
                .codexManagedRuntimeBindingRequiresCodexManagedRevocation(.codex)
            )
        }
    }

    func testReplacementBlocksReadersUntilRevisionInvalidationCompletes() async throws {
        let provider = ExternalMCPRuntimeProvider.openCode
        let initialAdapter = CountingExternalMCPAdapter(provider: provider)
        let replacementAdapter = CountingExternalMCPAdapter(provider: provider)
        let registry = try ExternalMCPAdapterRegistry(registrations: [
            ExternalMCPProviderRegistration(
                provider: provider,
                adapter: initialAdapter,
                figmaCapabilities: .adapterOnly(for: provider)
            )
        ])
        let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
        let originalRevision = await coordinator.activeRevision()
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let replacementFinished = DispatchSemaphore(value: 0)

        registry.onRegistrationReplacement = { _ in
            _ = coordinator.invalidateRevision()
            callbackStarted.signal()
            releaseCallback.wait()
        }

        DispatchQueue.global().async {
            try? registry.replace(ExternalMCPProviderRegistration(
                provider: provider,
                adapter: replacementAdapter,
                figmaCapabilities: .adapterOnly(for: provider)
            ))
            replacementFinished.signal()
        }

        XCTAssertEqual(callbackStarted.wait(timeout: .now() + 1), .success)
        let invalidatedRevision = await coordinator.currentRevision()
        XCTAssertGreaterThan(invalidatedRevision, originalRevision)

        let readFinished = DispatchSemaphore(value: 0)
        let observed = RegistryRegistrationBox()
        DispatchQueue.global().async {
            observed.set(registry.registration(for: provider))
            readFinished.signal()
        }
        XCTAssertEqual(readFinished.wait(timeout: .now() + 0.1), .timedOut)

        releaseCallback.signal()
        XCTAssertEqual(replacementFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(readFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(observed.adapter === replacementAdapter)
    }

    func testCodexManagedRuntimeDecisionGrantsOnlyAuthenticatedState() async throws {
        let provider = ExternalMCPRuntimeProvider.codex
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(ExternalMCPProviderRegistration(
            provider: provider,
            adapter: CountingExternalMCPAdapter(provider: provider),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .codexManaged,
                proofSupport: .codexManaged,
                revocationSupport: .codexManaged,
                runtimeBindingSupport: .codexManaged
            )
        ))
        let coordinator = ExternalMCPIntegrationCoordinator(registry: registry)
        let revision = await coordinator.activeRevision()
        let context = ExternalMCPProviderRuntimeContext(
            identity: .init(provider: provider, runtimeKind: .appServer, executableIdentity: "codex"),
            sessionClass: .topLevel,
            isolation: .ceIsolated,
            coordinatorRevision: revision
        )
        let authenticatedSnapshot = ExternalMCPRuntimeSnapshot(
            integrationID: ExternalMCPIntegrationDefinition.figma().integrationID,
            connection: .connected,
            authentication: .authenticated
        )

        let granted = await coordinator.decision(
            integration: .figma(),
            snapshot: authenticatedSnapshot,
            context: context
        )
        XCTAssertTrue(granted.isAllowed)
        XCTAssertEqual(granted.reason, .granted)
        XCTAssertEqual(granted.verifiedSnapshot, authenticatedSnapshot)

        let providerOwned = await coordinator.decision(
            integration: .figma(),
            snapshot: .init(
                integrationID: authenticatedSnapshot.integrationID,
                connection: .connected,
                authentication: .providerOwned
            ),
            context: context
        )
        XCTAssertFalse(providerOwned.isAllowed)
        XCTAssertEqual(providerOwned.reason, .unauthenticated)
    }
}

private final class RegistryRegistrationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var registration: ExternalMCPProviderRegistration?

    func set(_ registration: ExternalMCPProviderRegistration?) {
        lock.lock()
        self.registration = registration
        lock.unlock()
    }

    var adapter: AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        return registration.map { $0.adapter as AnyObject }
    }
}

private struct ResolvedFigmaTargetResolver: FigmaMCPProviderTargetResolving {
    let runtimeProvider: ExternalMCPRuntimeProvider

    func resolveTarget(for _: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderTargetResolution {
        .resolved(
            providerTargetIdentifier: "figma",
            source: .reviewedFixedIdentifier,
            credentialContext: .providerDefaultUserProfile
        )
    }
}

private struct TestFigmaTargetResolver: FigmaMCPProviderTargetResolving {
    let runtimeProvider: ExternalMCPRuntimeProvider

    func resolveTarget(for _: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderTargetResolution {
        .missing(reason: .noCanonicalMatch)
    }
}

private struct TestFigmaLoginDriver: FigmaMCPProviderLoginDriving {
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

private final class CountingExternalMCPAdapter: @unchecked Sendable, ExternalMCPProviderAdapter {
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
        return .init(integrationID: integration.integrationID, connection: .connected, authentication: .providerOwned)
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
