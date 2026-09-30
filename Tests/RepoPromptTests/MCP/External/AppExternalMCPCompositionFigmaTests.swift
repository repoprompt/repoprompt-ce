import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AppExternalMCPCompositionFigmaTests: XCTestCase {
    func testProductionFigmaCapabilityMatrixAndAuthorityReachabilityAreExact() {
        let composition = FigmaMCPTestGraph.make()
        let expectedProviders: Set<ExternalMCPRuntimeProvider> = [
            .codex, .claudeCode, .openCode, .cursor, .devin, .antigravity, .grokBuild
        ]

        XCTAssertEqual(composition.registry.registeredProviders, expectedProviders)
        XCTAssertEqual(
            ExternalMCPRuntimeProvider.allCases.count,
            expectedProviders.count,
            "Adding a provider requires an explicit production composition decision"
        )

        XCTAssertEqual(
            composition.registry.registration(for: .codex)?.figmaCapabilities,
            .init(
                provider: .codex,
                loginSupport: .codexManaged,
                proofSupport: .codexManaged,
                revocationSupport: .codexManaged,
                runtimeBindingSupport: .codexManaged
            )
        )

        let claudeRegistration = composition.registry.registration(for: .claudeCode)
        XCTAssertEqual(
            claudeRegistration?.figmaCapabilities,
            .init(
                provider: .claudeCode,
                loginSupport: .verified(FigmaMCPProviderCapabilityEvidence(
                    provider: .claudeCode,
                    evidenceID: ClaudeCodeFigmaMCPLoginDescriptor.evidenceID,
                    capabilityRevision: ClaudeCodeFigmaMCPLoginDescriptor.capabilityRevision
                )),
                proofSupport: .verified(FigmaMCPProviderCapabilityEvidence(
                    provider: .claudeCode,
                    evidenceID: ClaudeCodeFigmaMCPLoginDescriptor.evidenceID,
                    capabilityRevision: ClaudeCodeFigmaMCPLoginDescriptor.capabilityRevision
                )),
                revocationSupport: .verified(ClaudeCodeFigmaMCPLogoutDescriptor.evidence),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            )
        )
        XCTAssertNotNil(claudeRegistration?.loginDriver, "Claude requires a verified production login driver")
        XCTAssertNotNil(
            claudeRegistration?.targetResolver,
            "Claude requires a verified production target resolver"
        )
        XCTAssertNil(claudeRegistration?.structuredProofChecker)
        XCTAssertNotNil(
            claudeRegistration?.structuredStatusChecker,
            "Claude requires an exact provider-owned status checker before Settings may publish Connected"
        )

        for provider in [ExternalMCPRuntimeProvider.cursor, .devin] {
            let registration = composition.registry.registration(for: provider)
            XCTAssertEqual(
                registration?.figmaCapabilities,
                .init(
                    provider: provider,
                    loginSupport: .unverified(.liveGatePending),
                    proofSupport: .unverified(.noStructuredProofContract),
                    revocationSupport: .unverified(.noRevocationContract),
                    runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
                ),
                "\(provider) must remain production-unverified on every Figma capability axis"
            )
            XCTAssertNil(registration?.loginDriver, "\(provider) must not have a production login driver")
            XCTAssertNil(registration?.targetResolver, "\(provider) must not have a production target resolver")
            XCTAssertNil(
                registration?.structuredProofChecker,
                "\(provider) must not have a production structured-proof checker"
            )
            XCTAssertNil(
                registration?.structuredStatusChecker,
                "\(provider) must not have a production structured-status checker"
            )
        }

        let openCodeRegistration = composition.registry.registration(for: .openCode)
        XCTAssertEqual(
            openCodeRegistration?.figmaCapabilities,
            .init(
                provider: .openCode,
                loginSupport: .unsupported(.unsupportedProviderRoute),
                proofSupport: .unsupported(.unsupportedProviderRoute),
                revocationSupport: .unsupported(.unsupportedProviderRoute),
                runtimeBindingSupport: .unsupported(.unsupportedProviderRoute)
            )
        )
        XCTAssertNil(openCodeRegistration?.loginDriver)
        XCTAssertNil(openCodeRegistration?.targetResolver)
        XCTAssertNil(openCodeRegistration?.structuredProofChecker)
        XCTAssertNil(openCodeRegistration?.structuredStatusChecker)

        let grokRegistration = composition.registry.registration(for: .grokBuild)
        XCTAssertEqual(
            grokRegistration?.figmaCapabilities,
            .init(
                provider: .grokBuild,
                loginSupport: .unsupported(.unsupportedProviderRoute),
                proofSupport: .unsupported(.unsupportedProviderRoute),
                revocationSupport: .unsupported(.unsupportedProviderRoute),
                runtimeBindingSupport: .unsupported(.unsupportedProviderRoute)
            )
        )
        XCTAssertNil(grokRegistration?.loginDriver)
        XCTAssertNil(grokRegistration?.targetResolver)
        XCTAssertNil(grokRegistration?.structuredProofChecker)
        XCTAssertNil(grokRegistration?.structuredStatusChecker)

        let antigravityRegistration = composition.registry.registration(for: .antigravity)
        XCTAssertEqual(
            antigravityRegistration?.figmaCapabilities,
            .init(
                provider: .antigravity,
                loginSupport: .unsupported(.unsupportedProviderRoute),
                proofSupport: .unsupported(.unsupportedProviderRoute),
                revocationSupport: .unsupported(.unsupportedProviderRoute),
                runtimeBindingSupport: .unsupported(.unsupportedProviderRoute)
            )
        )
        XCTAssertNil(antigravityRegistration?.loginDriver)
        XCTAssertNil(antigravityRegistration?.targetResolver)
        XCTAssertNil(antigravityRegistration?.structuredProofChecker)
        XCTAssertNil(antigravityRegistration?.structuredStatusChecker)
    }

    func testPrepareRuntimeAccessDeniesNonCodexBeforeRefreshOrLease() async {
        let composition = FigmaMCPTestGraph.make()
        let definition = ExternalMCPIntegrationDefinition.figma()

        for provider in [ExternalMCPRuntimeProvider.claudeCode, .openCode, .cursor, .devin, .antigravity, .grokBuild] {
            let context = ExternalMCPProviderRuntimeContext(
                identity: .init(
                    provider: provider,
                    runtimeKind: provider == .claudeCode ? .nativeCLI : .acp,
                    executableIdentity: provider.rawValue
                ),
                sessionClass: .topLevel,
                isolation: provider == .claudeCode ? .userNative : .ceIsolated
            )
            let result = await composition.prepareRuntimeAccess(in: context, integration: definition)
            XCTAssertNil(result.lease, provider.rawValue)
            XCTAssertFalse(result.decision.isAllowed, provider.rawValue)
            XCTAssertEqual(result.decision.reason, .unsupported, provider.rawValue)
        }
    }

    func testPrepareRuntimeAccessDoesNotTreatGenericProviderOwnedRefreshAsProof() async throws {
        let provider = ExternalMCPRuntimeProvider.openCode
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: provider,
            evidenceID: "runtime-proof",
            capabilityRevision: "1"
        )
        let adapter = CompositionCountingAdapter(provider: provider)
        var registry = ExternalMCPAdapterRegistry()
        try registry.register(ExternalMCPProviderRegistration(
            provider: provider,
            adapter: adapter,
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .unverified(.liveGatePending),
                proofSupport: .verified(evidence),
                revocationSupport: .verified(evidence),
                runtimeBindingSupport: .verified(evidence)
            ),
            targetResolver: CompositionTargetResolver(runtimeProvider: provider),
            structuredStatusChecker: { _, _, _, _ in
                adapter.recordStructuredStatus()
                return .unknown
            }
        ))
        let composition = AppExternalMCPComposition(
            figmaCoordinator: FigmaMCPIntegrationCoordinator(runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority()), terminalSessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }), cursorToolSurfaceObserver: CursorFigmaMCPSettingsToolSurfaceObserver(),
            registry: registry
        )
        let result = await composition.prepareRuntimeAccess(
            in: .init(
                identity: .init(provider: provider, runtimeKind: .acp, executableIdentity: "opencode", executableVersion: "1"),
                sessionClass: .topLevel,
                isolation: .ceIsolated
            ),
            integration: .figma()
        )

        XCTAssertEqual(adapter.refreshCount, 1)
        XCTAssertEqual(adapter.structuredStatusCount, 1)
        XCTAssertNil(result.lease)
        XCTAssertFalse(result.decision.isAllowed)
        XCTAssertEqual(result.decision.reason, .unauthenticated)
    }
}

private struct CompositionTargetResolver: FigmaMCPProviderTargetResolving {
    let runtimeProvider: ExternalMCPRuntimeProvider

    func resolveTarget(for _: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderTargetResolution {
        .resolved(
            providerTargetIdentifier: "figma-server",
            source: .reviewedFixedIdentifier,
            credentialContext: .providerDefaultUserProfile
        )
    }
}

private final class CompositionCountingAdapter: @unchecked Sendable, ExternalMCPProviderAdapter {
    let runtimeProvider: ExternalMCPRuntimeProvider
    private(set) var refreshCount = 0
    private(set) var structuredStatusCount = 0
    private let lock = NSLock()

    init(provider: ExternalMCPRuntimeProvider) {
        runtimeProvider = provider
    }

    func recordStructuredStatus() {
        lock.lock()
        structuredStatusCount += 1
        lock.unlock()
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
