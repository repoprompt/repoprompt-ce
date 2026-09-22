import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentTaskRouterCoreTests: XCTestCase {
    func testRegistryRejectsDuplicatesAndNeverFallsBackUnknownID() async throws {
        let backend = FakeBackend(id: .init(rawValue: "fake"), readiness: .ready(generation: 1, policyVersion: "v1"))
        XCTAssertThrowsError(try AgentTaskRouterRegistry(registrations: [
            .init(backend: backend), .init(backend: backend)
        ])) { error in
            XCTAssertEqual(error as? AgentTaskRouterRegistryError, .duplicateBackendID(.init(rawValue: "fake")))
        }
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
        let missing = await registry.registration(for: .init(rawValue: "unknown"))
        XCTAssertNil(missing)
        let registrations = await registry.registrations()
        XCTAssertEqual(registrations.map(\.id), [.init(rawValue: "fake")])
    }

    func testSecondBackendRegistrationOwnsSettingsWithoutGenericJevSwitches() async throws {
        let fake = FakeBackend(id: .init(rawValue: "second"), readiness: .ready(generation: 1, policyVersion: "v1"))
        let settings = FakeBackendSettingsController()
        let runtime = try AgentTaskRouterRuntime(registrations: [
            .init(
                backend: fake,
                settings: .init(
                    presentation: .init(
                        title: "Second backend",
                        configurationDetail: "Fake settings",
                        secretFieldLabel: nil,
                        links: []
                    ),
                    controller: settings
                )
            )
        ])
        let registration = await runtime.registry.registration(for: fake.id)
        XCTAssertEqual(registration?.settings?.presentation.title, "Second backend")
        let readiness = await registration?.settings?.controller.readinessSnapshot()
        XCTAssertEqual(readiness, .ready(generation: 1, policyVersion: "v1"))
    }

    func testRuntimeBootstrapsOnlyExplicitSelectedBackendAndNeverBootstrapsWhenDisabled() async throws {
        let selectedID = AgentTaskRouterBackendID(rawValue: "selected")
        let inactiveID = AgentTaskRouterBackendID(rawValue: "inactive")
        let selectedSettings = BootstrapCountingSettingsController()
        let inactiveSettings = BootstrapCountingSettingsController()
        _ = try AgentTaskRouterRuntime(
            registrations: [
                .init(
                    backend: FakeBackend(id: selectedID, readiness: .needsConfiguration(generation: 0, reason: "test")),
                    settings: .init(presentation: testSettingsPresentation("Selected"), controller: selectedSettings)
                ),
                .init(
                    backend: FakeBackend(id: inactiveID, readiness: .needsConfiguration(generation: 0, reason: "test")),
                    settings: .init(presentation: testSettingsPresentation("Inactive"), controller: inactiveSettings)
                )
            ],
            bootstrapBackendID: selectedID
        )
        await selectedSettings.waitUntilObserved()
        await inactiveSettings.waitUntilObserved()
        await selectedSettings.waitUntilBootstrapped()
        let selectedBootstrapCount = await selectedSettings.bootstrapCount
        let inactiveBootstrapCount = await inactiveSettings.bootstrapCount
        XCTAssertEqual(selectedBootstrapCount, 1)
        XCTAssertEqual(inactiveBootstrapCount, 0)

        let disabledA = BootstrapCountingSettingsController()
        let disabledB = BootstrapCountingSettingsController()
        _ = try AgentTaskRouterRuntime(registrations: [
            .init(
                backend: FakeBackend(id: .init(rawValue: "disabled-a"), readiness: .needsConfiguration(generation: 0, reason: "test")),
                settings: .init(presentation: testSettingsPresentation("A"), controller: disabledA)
            ),
            .init(
                backend: FakeBackend(id: .init(rawValue: "disabled-b"), readiness: .needsConfiguration(generation: 0, reason: "test")),
                settings: .init(presentation: testSettingsPresentation("B"), controller: disabledB)
            )
        ])
        await disabledA.waitUntilObserved()
        await disabledB.waitUntilObserved()
        let disabledABootstrapCount = await disabledA.bootstrapCount
        let disabledBBootstrapCount = await disabledB.bootstrapCount
        XCTAssertEqual(disabledABootstrapCount, 0)
        XCTAssertEqual(disabledBBootstrapCount, 0)
    }

    func testEnvelopeIsExactAndRejectsPrivacyExpansionsOrTruncation() throws {
        let candidates = [descriptor("a"), descriptor("b")]
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(),
            text: "  diagnose this  ",
            scope: .subagent,
            customInstructions: "  Prefer Claude for execution.  ",
            candidates: candidates
        )
        XCTAssertEqual(request.task, "diagnose this")
        XCTAssertEqual(request.contractVersion, AgentTaskRoutingRequest.currentContractVersion)
        XCTAssertEqual(request.scope, .subagent)
        XCTAssertEqual(request.decisionStage, .model)
        XCTAssertEqual(request.customInstructions, "Prefer Claude for execution.")
        let effortRequest = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(),
            text: "diagnose this",
            decisionStage: .effort,
            candidates: candidates
        )
        XCTAssertEqual(effortRequest.decisionStage, .effort)
        XCTAssertThrowsError(try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: String(repeating: "a", count: 4001), candidates: candidates
        )) { XCTAssertEqual($0 as? AgentTaskRoutingEnvelopeBuilder.Rejection, .tooManyCharacters) }
        XCTAssertThrowsError(try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: candidates, containsAttachments: true
        )) { XCTAssertEqual($0 as? AgentTaskRoutingEnvelopeBuilder.Rejection, .unsupportedContent) }
        XCTAssertThrowsError(try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a")]
        )) { XCTAssertEqual($0 as? AgentTaskRoutingEnvelopeBuilder.Rejection, .invalidCandidateCount) }
        XCTAssertNoThrow(try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(),
            text: "task",
            candidates: (0 ..< 8).map { descriptor("candidate-\($0)") }
        ))
        XCTAssertThrowsError(try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(),
            text: "task",
            candidates: (0 ... AgentTaskRoutingEnvelopeBuilder.maximumCandidates).map { descriptor("candidate-\($0)") }
        )) { XCTAssertEqual($0 as? AgentTaskRoutingEnvelopeBuilder.Rejection, .invalidCandidateCount) }
    }

    func testExecutableIdentityIncludesEffortAndNormalizedACPParameters() {
        let low = AgentRoutingExecutableTarget(
            agentRaw: "grokBuild", modelRaw: "grok", reasoningEffortRaw: "low", modelParameters: []
        )
        let high = AgentRoutingExecutableTarget(
            agentRaw: "grokBuild", modelRaw: "grok", reasoningEffortRaw: "high", modelParameters: []
        )
        XCTAssertNotEqual(low, high)

        let first = ACPModelParameterSelection(
            providerID: .openCode, baseModelRaw: "model", kind: .thinking, configID: "effort", valueRaw: "low"
        )
        let second = ACPModelParameterSelection(
            providerID: .openCode, baseModelRaw: "model", kind: .speed, configID: "tier", valueRaw: "fast"
        )
        let ordered = AgentRoutingExecutableTarget(
            agentRaw: "openCode", modelRaw: "model", reasoningEffortRaw: nil, modelParameters: [first, second]
        )
        let reversed = AgentRoutingExecutableTarget(
            agentRaw: "openCode", modelRaw: "model", reasoningEffortRaw: nil, modelParameters: [second, first]
        )
        XCTAssertEqual(ordered, reversed)
    }

    func testCoordinatorRejectsUnknownSelectionFromReadyBackend() async throws {
        let backend = FakeBackend(
            id: .init(rawValue: "fake"),
            readiness: .ready(generation: 1, policyVersion: "v1"),
            outcome: .selected(opaqueKey: "not-submitted", evidence: nil)
        )
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
        let coordinator = AgentFreshTaskRoutingCoordinator(registry: registry)
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
        )
        let result = await coordinator.route(backendID: backend.id, request: request)
        XCTAssertEqual(result, .failed(category: .invalidResponse, retryable: false, evidence: nil))
    }

    func testCoordinatorRejectsSelectionAfterReadinessGenerationChanges() async throws {
        let backend = AdvancingReadinessBackend()
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
        let coordinator = AgentFreshTaskRoutingCoordinator(registry: registry)
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
        )
        let result = await coordinator.route(backendID: backend.id, request: request)
        XCTAssertEqual(result, .failed(category: .policyUnavailable, retryable: false, evidence: nil))
    }

    func testCoordinatorCancellationRejectsLateBackendSelection() async throws {
        let backend = LateCompletionBackend()
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
        let coordinator = AgentFreshTaskRoutingCoordinator(registry: registry)
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
        )
        let route = Task { await coordinator.route(backendID: backend.id, request: request) }
        await backend.waitUntilStarted()
        await coordinator.cancel(requestID: request.requestID)
        await backend.completeWithSelection()
        let outcome = await route.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testCoordinatorReservesBeforeReadinessAndDuplicateCannotPass() async throws {
        let backend = SuspendedReadinessBackend()
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
        let coordinator = AgentFreshTaskRoutingCoordinator(registry: registry)
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
        )
        let first = Task { await coordinator.route(backendID: backend.id, request: request) }
        await backend.waitUntilReadinessStarted()
        let duplicate = await coordinator.route(backendID: backend.id, request: request)
        XCTAssertEqual(duplicate, .failed(category: .invalidRequest, retryable: false, evidence: nil))
        await coordinator.cancel(requestID: request.requestID)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .cancelled)
    }

    func testCancelPromptlySettlesWhenBackendNeverCompletes() async throws {
        let backend = NeverCompletingRouteBackend()
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
        let coordinator = AgentFreshTaskRoutingCoordinator(registry: registry)
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
        )
        let route = Task { await coordinator.route(backendID: backend.id, request: request) }
        await backend.waitUntilStarted()
        await coordinator.cancelAll()
        let routeOutcome = await route.value
        XCTAssertEqual(routeOutcome, .cancelled)
    }

    func testOptionalEvidenceIsValidatedUniformly() async throws {
        let invalid = AgentTaskRoutingDecisionEvidence(
            policyVersion: "wrong", confidence: .nan, scores: ["unknown": -1],
            inputTokens: -1, outputTokens: -1, reasonCode: nil
        )
        for outcome in [
            AgentTaskRoutingBackendOutcome.abstained(reason: "test", evidence: invalid),
            .failed(category: .transport, retryable: true, evidence: invalid)
        ] {
            let backend = FakeBackend(
                id: .init(rawValue: UUID().uuidString),
                readiness: .ready(generation: 1, policyVersion: "v1"),
                outcome: outcome
            )
            let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
            let request = try AgentTaskRoutingEnvelopeBuilder().build(
                requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
            )
            let outcome = await AgentFreshTaskRoutingCoordinator(registry: registry)
                .route(backendID: backend.id, request: request)
            XCTAssertEqual(outcome, .failed(category: .invalidResponse, retryable: false, evidence: nil))
        }
        let nilEvidenceBackend = FakeBackend(
            id: .init(rawValue: "nil-evidence"),
            readiness: .ready(generation: 1, policyVersion: "v1"),
            outcome: .selected(opaqueKey: "a", evidence: nil)
        )
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: nilEvidenceBackend)])
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
        )
        let outcome = await AgentFreshTaskRoutingCoordinator(registry: registry)
            .route(backendID: nilEvidenceBackend.id, request: request)
        XCTAssertEqual(outcome, .selected(opaqueKey: "a", evidence: nil))
    }

    func testJevBackendRoutesToStrictlyValidatedOpaqueChoice() async {
        let storage = TestSecureStorageBackend()
        let client = SelectingJevClient()
        let credentials = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: storage),
            client: client
        )
        guard case .saved = await credentials.validateAndSave("secret", operationID: UUID()) else {
            return XCTFail("Expected test credential to validate")
        }
        let backend = JevTaskRouterBackend(credentialService: credentials)
        let outcome = await backend.route(.init(
            requestID: UUID(), contractVersion: AgentTaskRoutingRequest.currentContractVersion,
            task: "task", scope: .subagent, customInstructions: "Prefer b.",
            candidates: [descriptor("a"), descriptor("b")]
        ))
        guard case let .selected(key, evidence) = outcome else {
            return XCTFail("Expected Jev selection, got \(outcome)")
        }
        XCTAssertEqual(key, "b")
        XCTAssertEqual(evidence?.policyVersion, JevRouterCredentialService.routingPolicyVersion)
        XCTAssertEqual(evidence?.confidence, 0.8)
        XCTAssertEqual(evidence?.scores, ["a": 0.2, "b": 0.8])
        XCTAssertEqual(evidence?.reasonCode, "unique_argmax")

        let request = await client.lastRequest
        XCTAssertEqual(request?.model, JevRouterCredentialService.pinnedModel)
        XCTAssertEqual(request?.state, "HIGHEST-PRIORITY USER ROUTING DIRECTIVE:\nPrefer b.\n\nTASK:\ntask")
        XCTAssertEqual(request?.questions["route"]?.criteria, [
            "a": "Provider: Test; model: a. Suitable work: rubric",
            "b": "Provider: Test; model: b. Suitable work: rubric"
        ])
        XCTAssertTrue(request?.questions["route"]?.instructions.contains("delegated subagent session") == true)
        XCTAssertTrue(request?.questions["route"]?.instructions.contains("Prefer b.") == true)
        XCTAssertTrue(request?.questions["route"]?.instructions.hasPrefix("HIGHEST-PRIORITY USER ROUTING DIRECTIVE: Prefer b.") == true)
        XCTAssertTrue(request?.questions["route"]?.instructions.contains("Choose the model first") == true)
        XCTAssertTrue(request?.questions["route"]?.instructions.contains("No candidate is the ordinary default") == true)
        XCTAssertTrue(request?.questions["route"]?.instructions.contains("Code and pull-request review") == true)
    }

    func testJevBackendRejectsDuplicateOpaqueKeysWithoutCallingService() async {
        let client = SelectingJevClient()
        let credentials = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()),
            client: client
        )
        let backend = JevTaskRouterBackend(credentialService: credentials)
        let outcome = await backend.route(.init(
            requestID: UUID(), contractVersion: AgentTaskRoutingRequest.currentContractVersion,
            task: "task", scope: .primarySession, customInstructions: nil,
            candidates: [descriptor("duplicate"), descriptor("duplicate")]
        ))
        XCTAssertEqual(outcome, .failed(category: .invalidRequest, retryable: false, evidence: nil))
        let request = await client.lastRequest
        XCTAssertNil(request)
    }

    private func descriptor(_ key: String) -> AgentTaskRoutingCandidateDescriptor {
        .init(
            opaqueKey: key,
            roleLabels: [key],
            targetDescription: "Provider: Test; model: \(key).",
            rubricVersion: "v1",
            rubric: "rubric"
        )
    }

    private func testSettingsPresentation(_ title: String) -> AgentTaskRouterBackendSettingsPresentation {
        .init(title: title, configurationDetail: "test", secretFieldLabel: nil, links: [])
    }
}

private actor SelectingJevClient: JevRoutingClientProtocol {
    private(set) var lastRequest: JevRoutingWireRequest?

    func listModels(apiKey: String, timeout: Duration) -> JevModelList {
        .init(models: [.init(name: "jev-latest")])
    }

    func judge(
        request: JevRoutingWireRequest,
        apiKey: String,
        timeout: Duration
    ) -> JevRoutingWireResponse {
        lastRequest = request
        return .init(
            model: JevRouterCredentialService.pinnedModel,
            answers: [
                "route": .init(
                    type: "choice",
                    choice: "b",
                    probabilities: ["a": 0.2, "b": 0.8],
                    confidence: 0.8
                )
            ],
            usage: .init(inputTokens: 12, outputTokens: 4)
        )
    }
}

private struct FakeBackend: AgentTaskRouterBackend {
    let id: AgentTaskRouterBackendID
    let displayName = "Fake"
    let readiness: AgentTaskRouterBackendReadiness
    var outcome: AgentTaskRoutingBackendOutcome = .abstained(reason: "test", evidence: nil)

    func readinessSnapshot() async -> AgentTaskRouterBackendReadiness {
        readiness
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        outcome
    }
}

private actor FakeBackendSettingsController: AgentTaskRouterBackendSettingsController {
    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        .ready(generation: 1, policyVersion: "v1")
    }

    func readinessUpdates() -> AsyncStream<AgentTaskRouterBackendReadiness> {
        AsyncStream { $0.yield(.ready(generation: 1, policyVersion: "v1"))
            $0.finish()
        }
    }

    func perform(_ action: AgentTaskRouterBackendSettingsAction) -> AgentTaskRouterBackendSettingsActionResult {
        .succeeded("ok")
    }

    func bootstrapStoredConfigurationIfNeeded() {}
    func cancelAndAdvanceGeneration() {}
}

private actor BootstrapCountingSettingsController: AgentTaskRouterBackendSettingsController {
    private(set) var bootstrapCount = 0
    private var observed = false
    private var observationWaiters: [CheckedContinuation<Void, Never>] = []
    private var bootstrapWaiters: [CheckedContinuation<Void, Never>] = []

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        .needsConfiguration(generation: 0, reason: "test")
    }

    func readinessUpdates() -> AsyncStream<AgentTaskRouterBackendReadiness> {
        observed = true
        observationWaiters.forEach { $0.resume() }
        observationWaiters.removeAll()
        return AsyncStream { continuation in
            continuation.yield(.needsConfiguration(generation: 0, reason: "test"))
            continuation.finish()
        }
    }

    func perform(_ action: AgentTaskRouterBackendSettingsAction) -> AgentTaskRouterBackendSettingsActionResult {
        .succeeded("test")
    }

    func bootstrapStoredConfigurationIfNeeded() {
        bootstrapCount += 1
        bootstrapWaiters.forEach { $0.resume() }
        bootstrapWaiters.removeAll()
    }

    func cancelAndAdvanceGeneration() {}

    func waitUntilObserved() async {
        if observed {
            return
        }
        await withCheckedContinuation { observationWaiters.append($0) }
    }

    func waitUntilBootstrapped() async {
        if bootstrapCount > 0 {
            return
        }
        await withCheckedContinuation { bootstrapWaiters.append($0) }
    }
}

private actor AdvancingReadinessBackend: AgentTaskRouterBackend {
    nonisolated let id = AgentTaskRouterBackendID(rawValue: "advancing")
    nonisolated let displayName = "Advancing"
    private var readinessCallCount = 0

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        readinessCallCount += 1
        return .ready(generation: UInt64(readinessCallCount), policyVersion: "v1")
    }

    func route(_ request: AgentTaskRoutingRequest) -> AgentTaskRoutingBackendOutcome {
        .selected(
            opaqueKey: request.candidates[0].opaqueKey,
            evidence: .init(
                policyVersion: "v1", confidence: 0.8, scores: nil, inputTokens: 1, outputTokens: 1, reasonCode: nil
            )
        )
    }
}

private actor LateCompletionBackend: AgentTaskRouterBackend {
    nonisolated let id = AgentTaskRouterBackendID(rawValue: "late")
    nonisolated let displayName = "Late"
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<AgentTaskRoutingBackendOutcome, Never>?

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        .ready(generation: 1, policyVersion: "v1")
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { completion = $0 }
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func completeWithSelection() {
        completion?.resume(returning: .selected(
            opaqueKey: "a",
            evidence: .init(
                policyVersion: "v1", confidence: 0.8, scores: nil, inputTokens: 1, outputTokens: 1, reasonCode: nil
            )
        ))
        completion = nil
    }
}

private actor SuspendedReadinessBackend: AgentTaskRouterBackend {
    nonisolated let id = AgentTaskRouterBackendID(rawValue: "suspended-readiness")
    nonisolated let displayName = "Suspended readiness"
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func readinessSnapshot() async -> AgentTaskRouterBackendReadiness {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        return await withUnsafeContinuation { (_: UnsafeContinuation<AgentTaskRouterBackendReadiness, Never>) in }
    }

    func route(_ request: AgentTaskRoutingRequest) -> AgentTaskRoutingBackendOutcome {
        .cancelled
    }

    func waitUntilReadinessStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor NeverCompletingRouteBackend: AgentTaskRouterBackend {
    nonisolated let id = AgentTaskRouterBackendID(rawValue: "never-completing")
    nonisolated let displayName = "Never completing"
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        .ready(generation: 1, policyVersion: "v1")
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        return await withUnsafeContinuation { (_: UnsafeContinuation<AgentTaskRoutingBackendOutcome, Never>) in }
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
final class AgentTaskRoutingCandidateBuilderPolicyTests: XCTestCase {
    func testModelCandidatesIncludeAuditedCapabilityAndPricingWithoutPreselectedEffort() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )

        let candidates = try AgentTaskRoutingCandidateBuilder(opaqueKey: { UUID().uuidString }).build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        )

        let lunaCandidate = try XCTUnwrap(candidates.first(where: {
            CodexModelSpecifier(raw: $0.target.modelRaw).baseModel == "gpt-5.6-luna"
        }))
        XCTAssertEqual(lunaCandidate.utilityTier, "gpt-5.6-luna")
        XCTAssertTrue(lunaCandidate.descriptor.targetDescription.contains("nano-tier"))
        XCTAssertTrue(lunaCandidate.descriptor.targetDescription.contains("$0.20 input / $1.20 output"))
        XCTAssertNil(lunaCandidate.target.reasoningEffortRaw)
        XCTAssertFalse(lunaCandidate.descriptor.targetDescription.contains("Effort:"))
        XCTAssertEqual(lunaCandidate.descriptor.rubricVersion, "rpce.automatic-utility-frontier.v1-evidence-2026-09-19")

        let fableCandidate = try XCTUnwrap(candidates.first(where: {
            ClaudeModelSpecifier(raw: $0.target.modelRaw).baseModel == AgentModel.claudeFable51.rawValue
        }))
        XCTAssertEqual(fableCandidate.utilityTier, "claude-fable")
        XCTAssertTrue(fableCandidate.descriptor.targetDescription.contains("Terminal-Bench 4.0"))
        XCTAssertTrue(fableCandidate.descriptor.targetDescription.contains("$10 input / $50 output"))
        XCTAssertNil(fableCandidate.target.reasoningEffortRaw)
    }

    func testAutomaticModelCandidatesCoverAvailableBaseModelsWithoutTierDefaults() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )

        let candidates = try AgentTaskRoutingCandidateBuilder().build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        )

        XCTAssertTrue(Set(candidates.map(\.utilityTier)).isSuperset(of: [
            "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"
        ]))
        XCTAssertEqual(Set(candidates.map(\.target.agentRaw)), [
            AgentProviderKind.claudeCode.rawValue,
            AgentProviderKind.codexExec.rawValue
        ])
        XCTAssertFalse(candidates.contains { $0.descriptor.roleLabels.contains("explore") })
        XCTAssertGreaterThan(candidates.count, 4)
        XCTAssertLessThanOrEqual(candidates.count, AgentTaskRoutingEnvelopeBuilder.maximumCandidates)
    }

    func testEffortCandidatesAreBuiltOnlyAfterModelSelection() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let builder = AgentTaskRoutingCandidateBuilder()
        let model = try XCTUnwrap(builder.build(
            allowedProviders: [.codexExec],
            availability: availability
        ).first(where: { $0.target.modelRaw == "gpt-5.6-sol" }))

        let efforts = try builder.buildEfforts(for: model, availability: availability)

        XCTAssertGreaterThan(efforts.count, 1)
        XCTAssertTrue(efforts.allSatisfy {
            CodexModelSpecifier(raw: $0.target.modelRaw).baseModel == model.target.modelRaw
        })
        XCTAssertTrue(Set(efforts.compactMap(\.target.reasoningEffortRaw)).contains("high"))
    }

    func testAgentModelDefaultsAreReferenceSignalsWithoutRestrictingCandidates() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let candidates = try AgentTaskRoutingCandidateBuilder().build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability,
            roleDefaults: [
                .init(
                    roleLabel: "Engineer",
                    provider: .codexExec,
                    modelRaw: "gpt-5.6-sol-high",
                    isUserOverride: true
                )
            ]
        )

        XCTAssertGreaterThan(candidates.count, 1)
        let sol = try XCTUnwrap(candidates.first(where: { $0.target.modelRaw == "gpt-5.6-sol" }))
        XCTAssertTrue(sol.descriptor.targetDescription.contains("Engineer (user-set)"))
        XCTAssertTrue(sol.descriptor.targetDescription.contains("not constraints or automatic choices"))
        XCTAssertTrue(candidates.contains { $0.target.modelRaw == "gpt-5.6-terra" })
    }

    func testUnknownModelEvidenceMakesCapabilityAndCostUncertaintyExplicit() {
        let target = AgentRoutingExecutableTarget(
            agentRaw: AgentProviderKind.openCode.rawValue,
            modelRaw: "future-model",
            reasoningEffortRaw: nil,
            modelParameters: []
        )

        let description = AgentTaskRoutingModelProfileCatalog.description(for: target)

        XCTAssertTrue(description.contains("No audited benchmark or pricing profile"))
        XCTAssertTrue(description.contains("Treat capability and cost as uncertain"))
    }

    func testProviderDirectiveConstrainsAutomaticFrontier() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let candidates = try AgentTaskRoutingCandidateBuilder().build(
            allowedProviders: [.claudeCode],
            availability: availability
        )

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.target.agentRaw == AgentProviderKind.claudeCode.rawValue })
    }

    func testAvailableProviderPreferenceNarrowsFrontier() {
        XCTAssertEqual(
            AgentTaskRoutingCandidateBuilder.providers(
                preferring: .claudeCode,
                from: [.claudeCode, .codexExec]
            ),
            [.claudeCode]
        )
    }

    func testUnavailableProviderPreferenceFallsBackToAuthenticatedProviders() {
        XCTAssertEqual(
            AgentTaskRoutingCandidateBuilder.providers(
                preferring: .claudeCode,
                from: [.codexExec]
            ),
            [.codexExec]
        )
    }

    func testUnavailableProviderPolicyFailsClosed() {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        XCTAssertThrowsError(try AgentTaskRoutingCandidateBuilder().build(
            allowedProviders: [],
            availability: availability
        ))
        XCTAssertThrowsError(try AgentTaskRoutingCandidateBuilder().build(
            allowedProviders: [.openCode],
            availability: availability
        ))
    }
}
