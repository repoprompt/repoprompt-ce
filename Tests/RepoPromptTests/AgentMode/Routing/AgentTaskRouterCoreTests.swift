import Foundation
@testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
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

    func testLongRoutingExcerptIsDeterministicBoundedAndMasksBothEnds() {
        let task = "Investigate the parser. password=openingSecret "
            + String(repeating: "irrelevant middle ", count: 300)
            + " Finally, verify the fix. token=endingSecret"

        let excerpt = AgentTaskRoutingTaskExcerpt.make(from: task)

        XCTAssertEqual(excerpt, AgentTaskRoutingTaskExcerpt.make(from: task))
        XCTAssertTrue(excerpt.contains("Investigate the parser"))
        XCTAssertTrue(excerpt.contains("verify the fix"))
        XCTAssertTrue(excerpt.contains("middle omitted"))
        XCTAssertFalse(excerpt.contains("openingSecret"))
        XCTAssertFalse(excerpt.contains("endingSecret"))
        XCTAssertLessThanOrEqual(excerpt.count, AgentTaskRoutingEnvelopeBuilder.maximumCharacters)
        XCTAssertLessThanOrEqual(excerpt.utf8.count, AgentTaskRoutingEnvelopeBuilder.maximumUTF8Bytes)
    }

    func testLongRoutingExcerptOmitsUnsafeCutSegmentsButStillProvidesJevInput() {
        let task = "```\nprivate text\n" + String(repeating: "secret", count: 1000)
            + "\n```\nPlease inspect the result."

        let excerpt = AgentTaskRoutingTaskExcerpt.make(from: task)

        XCTAssertFalse(excerpt.contains("private text"))
        XCTAssertFalse(excerpt.contains("secret"))
        XCTAssertTrue(excerpt.contains("middle omitted"))
        XCTAssertNoThrow(try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: excerpt, candidates: [descriptor("a"), descriptor("b")]
        ))
    }

    func testShortRoutingTaskRemainsExact() {
        XCTAssertEqual(AgentTaskRoutingTaskExcerpt.make(from: "  Implement a parser  "), "Implement a parser")
    }

    func testLongRoutingExcerptRespectsUTF8Limit() {
        let task = "Review Unicode handling. " + String(repeating: "✈️ ", count: 3000)
            + " Finally, add tests."

        let excerpt = AgentTaskRoutingTaskExcerpt.make(from: task)

        XCTAssertTrue(excerpt.contains("middle omitted"))
        XCTAssertTrue(excerpt.contains("add tests"))
        XCTAssertLessThanOrEqual(excerpt.utf8.count, AgentTaskRoutingEnvelopeBuilder.maximumUTF8Bytes)
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
        // The shipped routing policy stays one choice question per decision.
        XCTAssertEqual(request?.questions.count, 1)
        XCTAssertEqual(request?.questions["route"]?.type, "choice")
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

    func testJevBackendRejectsStructurallyInvalidRequestsWithoutCallingService() async {
        let invalidCandidateSets: [(String, [AgentTaskRoutingCandidateDescriptor])] = [
            ("duplicate opaque keys", [descriptor("duplicate"), descriptor("duplicate")]),
            ("fewer than two candidates", [descriptor("only")]),
            ("empty opaque key", [descriptor(""), descriptor("b")]),
            (
                "more than the maximum candidates",
                (0 ... AgentTaskRoutingEnvelopeBuilder.maximumCandidates).map { descriptor("key-\($0)") }
            )
        ]
        for (name, candidates) in invalidCandidateSets {
            let client = SelectingJevClient()
            let credentials = JevRouterCredentialService(
                secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()),
                client: client
            )
            let backend = JevTaskRouterBackend(credentialService: credentials)
            let outcome = await backend.route(.init(
                requestID: UUID(), contractVersion: AgentTaskRoutingRequest.currentContractVersion,
                task: "task", scope: .primarySession, customInstructions: nil,
                candidates: candidates
            ))
            XCTAssertEqual(outcome, .failed(category: .invalidRequest, retryable: false, evidence: nil), name)
            let request = await client.lastRequest
            XCTAssertNil(request, name)
        }
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
    private static let advertisedCodexOptions = [
        modelOption("gpt-5.6-luna-low", "GPT-5.6 Luna Low"),
        modelOption("gpt-5.6-terra-medium", "GPT-5.6 Terra Medium"),
        modelOption("gpt-5.6-sol-high", "GPT-5.6 Sol High"),
        modelOption("gpt-6-luna-low", "GPT-6 Luna Low"),
        modelOption("gpt-6-sol-medium", "GPT-6 Sol Medium"),
        modelOption("gpt-6-sol-high", "GPT-6 Sol High")
    ]

    private static let advertisedClaudeOptions = [
        modelOption("claude-haiku-4-5", "Claude Haiku 4.5"),
        modelOption("claude-sonnet-5", "Claude Sonnet 5"),
        modelOption("opus", "Claude Opus"),
        modelOption("claude-opus-5-5", "Claude Opus 5.5"),
        modelOption("claude-fable-5-1", "Claude Fable 5.1")
    ]

    private static func modelOption(_ raw: String, _ name: String) -> AgentModelOption {
        AgentModelOption(rawValue: raw, displayName: name, description: nil, isDefault: false)
    }

    private func candidateBuilder(
        codexOptions: [AgentModelOption]? = nil,
        claudeOptions: [AgentModelOption]? = nil
    ) -> AgentTaskRoutingCandidateBuilder {
        let codexOptions = codexOptions ?? Self.advertisedCodexOptions
        let claudeOptions = claudeOptions ?? Self.advertisedClaudeOptions
        return AgentTaskRoutingCandidateBuilder { provider, _ in
            switch provider {
            case .codexExec: codexOptions
            case .claudeCode: claudeOptions
            default: []
            }
        }
    }

    func testModelCandidatesIncludeAuditedCapabilityAndPricingWithoutPreselectedEffort() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )

        let candidates = try candidateBuilder().build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        )

        let lunaCandidate = try XCTUnwrap(candidates.first(where: {
            CodexModelSpecifier(raw: $0.target.modelRaw).baseModel == "gpt-6-luna"
        }))
        XCTAssertEqual(lunaCandidate.utilityTier, "gpt-6-luna")
        XCTAssertTrue(lunaCandidate.descriptor.targetDescription.contains("efficient, high-volume"))
        XCTAssertTrue(lunaCandidate.descriptor.targetDescription.contains("$0.10 input / $0.50 output"))
        XCTAssertNil(lunaCandidate.target.reasoningEffortRaw)
        XCTAssertFalse(lunaCandidate.descriptor.targetDescription.contains("Effort:"))
        XCTAssertEqual(lunaCandidate.descriptor.rubricVersion, AgentTaskRoutingModelProfileCatalog.rubricVersion)

        let fableCandidate = try XCTUnwrap(candidates.first(where: {
            ClaudeModelSpecifier(raw: $0.target.modelRaw).baseModel == AgentModel.claudeFable51.rawValue
        }))
        XCTAssertEqual(fableCandidate.utilityTier, "claude-fable")
        XCTAssertTrue(fableCandidate.descriptor.targetDescription.contains("Terminal-Bench 4.0"))
        XCTAssertTrue(fableCandidate.descriptor.targetDescription.contains("$10 input / $50 output"))
        XCTAssertNil(fableCandidate.target.reasoningEffortRaw)

        let opusCandidate = try XCTUnwrap(candidates.first(where: {
            ClaudeModelSpecifier(raw: $0.target.modelRaw).baseModel == AgentModel.claudeOpus55.rawValue
        }))
        XCTAssertEqual(opusCandidate.utilityTier, "claude-opus")
        XCTAssertTrue(opusCandidate.descriptor.targetDescription.contains("recommended starting point for most workloads"))
        XCTAssertTrue(opusCandidate.descriptor.targetDescription.contains("$4 input / $20 output"))
    }

    func testClaudeOpusAliasIsFallbackWhenPinned55IsUnavailable() throws {
        let claudeOptions = Self.advertisedClaudeOptions.filter {
            $0.rawValue != AgentModel.claudeOpus55.rawValue
        }
        let candidates = try candidateBuilder(claudeOptions: claudeOptions).build(
            allowedProviders: [.claudeCode],
            availability: .init(claudeCodeAvailable: true, codexAvailable: false, openCodeAvailable: false)
        )

        let opusCandidate = try XCTUnwrap(candidates.first { $0.utilityTier == "claude-opus" })
        XCTAssertEqual(opusCandidate.target.modelRaw, "opus")
    }

    func testGPT6EffortAndAgentModelResolution() {
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-6-sol-max").reasoningEffort, .max)
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-6-sol-xhigh").reasoningEffort, .xhigh)
        XCTAssertNil(CodexModelSpecifier(raw: "gpt-6-sol-ultra").reasoningEffort)
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-6-sol-max", agentKind: .codexExec), .gpt6SolMax)
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-6-luna-low", agentKind: .codexExec), .gpt6LunaLow)
    }

    func testRoutingPrefersGPT61SolAndSonnet55WhenAdvertised() throws {
        let codexOptions = Self.advertisedCodexOptions + [
            Self.modelOption("gpt-6.1-sol-medium", "GPT-6.1 Sol Medium"),
            Self.modelOption("gpt-6.1-sol-high", "GPT-6.1 Sol High")
        ]
        let claudeOptions = Self.advertisedClaudeOptions + [
            Self.modelOption("claude-sonnet-5-5", "Claude Sonnet 5.5")
        ]
        let candidates = try candidateBuilder(codexOptions: codexOptions, claudeOptions: claudeOptions).build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: .init(claudeCodeAvailable: true, codexAvailable: true, openCodeAvailable: false)
        )

        let solCandidate = try XCTUnwrap(candidates.first {
            CodexModelSpecifier(raw: $0.target.modelRaw).baseModel?.hasSuffix("-sol") == true
        })
        XCTAssertEqual(CodexModelSpecifier(raw: solCandidate.target.modelRaw).baseModel, "gpt-6.1-sol")
        XCTAssertTrue(solCandidate.descriptor.targetDescription.contains("GPT-6.1 Sol"))
        XCTAssertTrue(solCandidate.descriptor.targetDescription.contains("$2 input / $10 output"))
        XCTAssertFalse(solCandidate.descriptor.targetDescription.contains("No verified API list price"))

        let sonnetCandidate = try XCTUnwrap(candidates.first { $0.utilityTier == "claude-sonnet" })
        XCTAssertEqual(ClaudeModelSpecifier(raw: sonnetCandidate.target.modelRaw).baseModel, "claude-sonnet-5-5")
        XCTAssertTrue(sonnetCandidate.descriptor.targetDescription.contains("Claude Sonnet 5.5"))
        XCTAssertTrue(sonnetCandidate.descriptor.targetDescription.contains("$2 input / $10 output"))
        XCTAssertFalse(sonnetCandidate.descriptor.targetDescription.contains("No verified API list price"))

        XCTAssertEqual(
            AutoEffortModelPolicy.codexEfforts(modelRaw: "gpt-6.1-sol-high", advertised: [.low, .medium, .high, .xhigh, .max, .ultra]),
            ["low", "medium", "high", "xhigh", "max"]
        )
        XCTAssertEqual(
            AutoEffortModelPolicy.claudeEfforts(modelRaw: "claude-sonnet-5-5:high", advertised: [.low, .medium, .high, .xhigh, .max]),
            ["low", "medium", "high", "xhigh", "max"]
        )
    }

    func testApprovedCodexFamilySelectionTracksNewestAdvertisedVersionOnly() throws {
        let options = [
            AgentModelOption(rawValue: "gpt-5.6-sol-high", displayName: "GPT-5.6 Sol High", description: nil, isDefault: false),
            AgentModelOption(rawValue: "gpt-6-sol-high", displayName: "GPT-6 Sol High", description: nil, isDefault: false),
            AgentModelOption(rawValue: "gpt-7-sol-high", displayName: "GPT-7 Sol High", description: nil, isDefault: false),
            AgentModelOption(rawValue: "gpt-99-nova-high", displayName: "GPT-99 Nova High", description: nil, isDefault: false)
        ]

        let selected = try XCTUnwrap(AgentModelCatalog.preferredCodexFamilyOption("sol", from: options))

        XCTAssertEqual(CodexModelSpecifier(raw: selected.rawValue).baseModel, "gpt-7-sol")
        XCTAssertNil(AgentModelCatalog.preferredCodexFamilyOption("nova", from: Array(options.prefix(3))))
    }

    func testAutomaticModelCandidatesCoverAvailableBaseModelsWithoutTierDefaults() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )

        let candidates = try candidateBuilder().build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        )

        XCTAssertTrue(Set(candidates.map(\.utilityTier)).isSuperset(of: [
            "gpt-6-luna", "gpt-5.6-terra", "gpt-6-sol"
        ]))
        XCTAssertEqual(Set(candidates.map(\.target.agentRaw)), [
            AgentProviderKind.claudeCode.rawValue,
            AgentProviderKind.codexExec.rawValue
        ])
        XCTAssertFalse(candidates.contains { $0.descriptor.roleLabels.contains("explore") })
        XCTAssertGreaterThan(candidates.count, 4)
        XCTAssertLessThanOrEqual(candidates.count, AgentTaskRoutingEnvelopeBuilder.maximumCandidates)
    }

    func testPaidFastNeverEntersAutomaticEffortsWithoutExplicitOptIn() throws {
        let options = ["gpt-6.1-sol-high", "gpt-6.1-sol-fast", "gpt-6.1-sol-fast-high"].map {
            AgentModelOption(rawValue: $0, displayName: $0, description: nil, isDefault: false)
        }
        let availability = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false)
        let builder = candidateBuilder(codexOptions: options)
        let models = try builder.build(allowedProviders: [.codexExec], availability: availability)
        XCTAssertTrue(models.allSatisfy { !AgentTaskRoutingCandidateBuilder.isPaidFast($0.target) })
        let selected = try XCTUnwrap(models.first)
        let ordinary = try builder.buildEfforts(for: selected, availability: availability)
        XCTAssertFalse(ordinary.isEmpty)
        XCTAssertTrue(ordinary.allSatisfy { !AgentTaskRoutingCandidateBuilder.isPaidFast($0.target) })
        let optedIn = try builder.buildEfforts(for: selected, availability: availability, allowPaidFast: true)
        XCTAssertTrue(optedIn.contains { AgentTaskRoutingCandidateBuilder.isPaidFast($0.target) })
    }

    func testStandalonePeersKeepClassAndAdvertisedEffortWithoutFast() throws {
        let availability = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: true, codexAvailable: true, openCodeAvailable: false)
        let claudeHigh = ClaudeModelSpecifier.encodedRaw(baseModelRaw: "claude-opus-5-5", effort: .high)
        let builder = candidateBuilder(claudeOptions: Self.advertisedClaudeOptions + [Self.modelOption(claudeHigh, "Opus High")])
        let input = try XCTUnwrap(builder.usageCandidates(
            basedOn: .init(agentRaw: AgentProviderKind.codexExec.rawValue, modelRaw: "gpt-6-sol-high", reasoningEffortRaw: "high", modelParameters: []),
            allowedProviders: [.claudeCode, .codexExec], availability: availability, surface: .headless
        ))
        XCTAssertEqual(input.selected.target.modelRaw, "gpt-6-sol-high")
        let peer = try XCTUnwrap(input.candidates.first { $0.target.agentRaw == AgentProviderKind.claudeCode.rawValue })
        XCTAssertEqual(peer.usagePeerClass, input.selected.usagePeerClass)
        XCTAssertEqual(ClaudeModelSpecifier(raw: peer.target.modelRaw).effortLevel?.rawValue, "high")
        XCTAssertFalse(AgentTaskRoutingCandidateBuilder.isPaidFast(peer.target))
        let reverse = try XCTUnwrap(builder.usageCandidates(basedOn: peer.target, allowedProviders: [.claudeCode, .codexExec], availability: availability, surface: .headless))
        let reversePeer = try XCTUnwrap(reverse.candidates.first { $0.target.agentRaw == AgentProviderKind.codexExec.rawValue })
        XCTAssertEqual(reversePeer.target.reasoningEffortRaw, "high")
        let unsupported = try XCTUnwrap(candidateBuilder().usageCandidates(basedOn: input.selected.target, allowedProviders: [.claudeCode, .codexExec], availability: availability, surface: .headless))
        XCTAssertEqual(unsupported.candidates.count, 1, "No exact advertised effort means no swap—not a provider-default downgrade")
        let limited = try XCTUnwrap(builder.usageCandidates(basedOn: input.selected.target, allowedProviders: [.codexExec], availability: availability, surface: .general))
        XCTAssertEqual(limited.candidates.count, 1)
        XCTAssertNil(builder.usageCandidates(basedOn: .init(agentRaw: "codexExec", modelRaw: "default", reasoningEffortRaw: nil, modelParameters: []), allowedProviders: [.codexExec, .claudeCode], availability: availability, surface: .general))
    }

    func testEffortCandidatesAreBuiltOnlyAfterModelSelection() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let builder = candidateBuilder()
        let model = try XCTUnwrap(builder.build(
            allowedProviders: [.codexExec],
            availability: availability
        ).first(where: { $0.target.modelRaw == "gpt-6-sol" }))

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
        let candidates = try candidateBuilder().build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability,
            roleDefaults: [
                .init(
                    roleLabel: "Engineer",
                    provider: .codexExec,
                    modelRaw: "gpt-6-sol-high",
                    isUserOverride: true
                )
            ]
        )

        XCTAssertGreaterThan(candidates.count, 1)
        let sol = try XCTUnwrap(candidates.first(where: { $0.target.modelRaw == "gpt-6-sol" }))
        XCTAssertTrue(sol.descriptor.targetDescription.contains("Engineer (user-set)"))
        XCTAssertTrue(sol.descriptor.targetDescription.contains("not constraints or automatic choices"))
        XCTAssertTrue(candidates.contains { $0.target.modelRaw == "gpt-5.6-terra" })
    }

    func testCodexCandidatesFallBackToGPT56BeforeDiscovery() throws {
        let codexOptions = Self.advertisedCodexOptions.filter {
            !$0.rawValue.hasPrefix("gpt-6-")
        }
        let candidates = try candidateBuilder(codexOptions: codexOptions).build(
            allowedProviders: [.codexExec],
            availability: .init(claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false)
        )

        XCTAssertEqual(Set(candidates.map(\.target.modelRaw)), [
            "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"
        ])
        XCTAssertFalse(candidates.contains { $0.target.modelRaw.hasPrefix("gpt-6-") })
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
        let candidates = try candidateBuilder().build(
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

/// `hasAvailableTarget` is the Model Router status pill's availability probe. It must answer exactly
/// what a non-empty `build` answers while never constructing candidates.
@MainActor
final class AgentTaskRoutingCandidateBuilderAvailabilityTests: XCTestCase {
    private final class Counter {
        var value = 0
    }

    private struct OptionFixture {
        let name: String
        let codex: [AgentModelOption]
        let claude: [AgentModelOption]
    }

    private static func option(_ raw: String) -> AgentModelOption {
        AgentModelOption(rawValue: raw, displayName: raw, description: nil, isDefault: false)
    }

    private static let fullCodex = [
        "gpt-5.6-luna-low", "gpt-5.6-terra-medium", "gpt-5.6-sol-high",
        "gpt-6-luna-low", "gpt-6-sol-medium", "gpt-6-sol-high"
    ].map(option)

    private static let fullClaude = [
        "claude-haiku-4-5", "claude-sonnet-5", "opus", "claude-opus-5-5", "claude-fable-5-1"
    ].map(option)

    private static let optionFixtures: [OptionFixture] = [
        OptionFixture(name: "full", codex: fullCodex, claude: fullClaude),
        OptionFixture(name: "empty", codex: [], claude: []),
        OptionFixture(name: "codex-only", codex: fullCodex, claude: []),
        OptionFixture(name: "claude-only", codex: [], claude: fullClaude),
        OptionFixture(
            name: "unrecognized",
            codex: ["gpt-99-nova-high", "not-a-model"].map(option),
            claude: ["claude-unknown-9", "not-a-model"].map(option)
        ),
        OptionFixture(
            name: "pre-gpt6-terra-and-opus-alias",
            codex: ["gpt-5.6-terra-medium"].map(option),
            claude: ["opus"].map(option)
        )
    ]

    private static let providerUniverse: [AgentProviderKind] = [
        .claudeCode, .codexExec, .openCode, .antigravity
    ]

    private static var providerSets: [Set<AgentProviderKind>] {
        (0 ..< (1 << providerUniverse.count)).map { mask in
            Set(providerUniverse.enumerated().compactMap { index, provider in
                mask & (1 << index) != 0 ? provider : nil
            })
        }
    }

    private static var availabilityContexts: [AgentModelCatalog.AvailabilityContext] {
        [false, true].flatMap { claude in
            [false, true].flatMap { codex in
                [false, true].map { openCode in
                    AgentModelCatalog.AvailabilityContext(
                        claudeCodeAvailable: claude,
                        codexAvailable: codex,
                        openCodeAvailable: openCode
                    )
                }
            }
        }
    }

    private func builder(
        _ fixture: OptionFixture,
        opaqueKeys: Counter = Counter(),
        optionReads: Counter = Counter()
    ) -> AgentTaskRoutingCandidateBuilder {
        AgentTaskRoutingCandidateBuilder(
            opaqueKey: {
                opaqueKeys.value += 1
                return "key-\(opaqueKeys.value)"
            },
            modelOptions: { provider, _ in
                optionReads.value += 1
                switch provider {
                case .codexExec: return fixture.codex
                case .claudeCode: return fixture.claude
                default: return []
                }
            }
        )
    }

    func testHasAvailableTargetMatchesNonEmptyBuildAcrossFixtureMatrix() {
        var outcomes: Set<Bool> = []
        for fixture in Self.optionFixtures {
            let builder = builder(fixture)
            for providers in Self.providerSets {
                for availability in Self.availabilityContexts {
                    for surface in [AgentModelCatalog.AgentSelectionSurface.general, .headless] {
                        let expected = (try? builder.build(
                            allowedProviders: providers,
                            availability: availability,
                            surface: surface
                        )) != nil
                        let actual = builder.hasAvailableTarget(
                            allowedProviders: providers,
                            availability: availability,
                            surface: surface
                        )
                        XCTAssertEqual(
                            actual,
                            expected,
                            "fixture=\(fixture.name) providers=\(providers.map(\.rawValue).sorted()) availability=\(availability) surface=\(surface)"
                        )
                        outcomes.insert(actual)
                    }
                }
            }
        }
        // The grid must exercise both answers, or the equivalence above proves nothing.
        XCTAssertEqual(outcomes, [true, false])
    }

    func testHasAvailableTargetStopsAtFirstResolvedDefinitionWithoutBuildingCandidates() throws {
        let fixture = Self.optionFixtures[0]
        let opaqueKeys = Counter()
        let optionReads = Counter()
        let builder = builder(fixture, opaqueKeys: opaqueKeys, optionReads: optionReads)
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )

        XCTAssertTrue(builder.hasAvailableTarget(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        ))
        // An opaque key is minted immediately before each candidate's display name and description
        // are rendered, so zero keys means no candidate was constructed. One catalog read means model
        // resolution stopped at the first eligible definition that resolved (eligibility filtering
        // itself is a cheap eager pass over the static definition table).
        XCTAssertEqual(opaqueKeys.value, 0)
        XCTAssertEqual(optionReads.value, 1)

        opaqueKeys.value = 0
        optionReads.value = 0
        let candidates = try builder.build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        )
        XCTAssertEqual(opaqueKeys.value, candidates.count)
        XCTAssertGreaterThan(optionReads.value, 1)
    }

    func testHasAvailableTargetReadsEveryEligibleDefinitionBeforeAnsweringNo() {
        let fixture = Self.optionFixtures[1]
        let opaqueKeys = Counter()
        let optionReads = Counter()
        let builder = builder(fixture, opaqueKeys: opaqueKeys, optionReads: optionReads)
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )

        XCTAssertFalse(builder.hasAvailableTarget(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        ))
        let noReads = optionReads.value
        optionReads.value = 0
        XCTAssertThrowsError(try builder.build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        ))
        XCTAssertEqual(noReads, optionReads.value)
        XCTAssertEqual(opaqueKeys.value, 0)
    }
}
