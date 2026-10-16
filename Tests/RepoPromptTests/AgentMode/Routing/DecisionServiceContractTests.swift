import Foundation
@testable import RepoPromptApp
import XCTest

final class JevJudgmentBatchTests: XCTestCase {
    /// The shipped routing policy submits exactly one `route` choice question. This pins the encoded
    /// payload so the batch seam cannot silently change what the router sends.
    func testOneQuestionBatchEncodesTheUnchangedShippedPayload() throws {
        let request = try JevRoutingWireRequest(
            model: JevRouterCredentialService.pinnedModel,
            state: "task",
            questions: batch(questions: [
                .init(id: "route", instructions: "pick", criteria: [
                    .init(opaqueKey: "a", description: "A"),
                    .init(opaqueKey: "b", description: "B")
                ])
            ]).wireQuestions()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try XCTUnwrap(String(data: encoder.encode(request), encoding: .utf8))
        XCTAssertEqual(
            encoded,
            """
            {"model":"\(JevRouterCredentialService.pinnedModel)",\
            "questions":{"route":{"criteria":{"a":"A","b":"B"},"instructions":"pick","type":"choice"}},\
            "state":"task"}
            """
        )
    }

    func testBatchEncodesEveryQuestionIntoTheDocumentedQuestionMap() throws {
        let wire = try batch(questions: [
            .init(id: "model", instructions: "choose model", criteria: [
                .init(opaqueKey: "m1", description: "M1"),
                .init(opaqueKey: "m2", description: "M2")
            ]),
            .init(id: "effort", instructions: "choose effort", criteria: [
                .init(opaqueKey: "e1", description: "E1"),
                .init(opaqueKey: "e2", description: "E2")
            ])
        ]).wireQuestions()
        XCTAssertEqual(Set(wire.keys), ["model", "effort"])
        XCTAssertEqual(wire["model"]?.type, "choice")
        XCTAssertEqual(wire["model"]?.instructions, "choose model")
        XCTAssertEqual(wire["model"]?.criteria, ["m1": "M1", "m2": "M2"])
        XCTAssertEqual(wire["effort"]?.criteria, ["e1": "E1", "e2": "E2"])
    }

    func testSubmittedKeysAreScopedPerQuestion() throws {
        let built = try batch(questions: [
            .init(id: "model", instructions: "m", criteria: [
                .init(opaqueKey: "shared", description: "M1"),
                .init(opaqueKey: "m2", description: "M2")
            ]),
            .init(id: "effort", instructions: "e", criteria: [
                .init(opaqueKey: "shared", description: "E1"),
                .init(opaqueKey: "e2", description: "E2")
            ])
        ])
        XCTAssertEqual(built.questionIDs, ["model", "effort"])
        XCTAssertEqual(built.submittedOpaqueKeysByQuestionID["model"], ["shared", "m2"])
        XCTAssertEqual(built.submittedOpaqueKeysByQuestionID["effort"], ["shared", "e2"])
    }

    func testRejectsStructurallyInvalidBatches() {
        assertBuildError(.noQuestions, questions: [])
        assertBuildError(.emptyQuestionID, questions: [
            .init(id: "", instructions: "i", criteria: [
                .init(opaqueKey: "a", description: "A"),
                .init(opaqueKey: "b", description: "B")
            ])
        ])
        assertBuildError(.duplicateQuestionID("route"), questions: [
            .init(id: "route", instructions: "i", criteria: [
                .init(opaqueKey: "a", description: "A"),
                .init(opaqueKey: "b", description: "B")
            ]),
            .init(id: "route", instructions: "i", criteria: [
                .init(opaqueKey: "c", description: "C"),
                .init(opaqueKey: "d", description: "D")
            ])
        ])
        assertBuildError(.invalidCriteriaCount(questionID: "route"), questions: [
            .init(id: "route", instructions: "i", criteria: [.init(opaqueKey: "a", description: "A")])
        ])
        assertBuildError(.invalidCriteriaCount(questionID: "route"), questions: [
            .init(
                id: "route",
                instructions: "i",
                criteria: (0 ... JevJudgmentBatch.maximumCriteria).map {
                    .init(opaqueKey: "k\($0)", description: "K\($0)")
                }
            )
        ])
        assertBuildError(.emptyCriterionKey(questionID: "route"), questions: [
            .init(id: "route", instructions: "i", criteria: [
                .init(opaqueKey: "", description: "A"),
                .init(opaqueKey: "b", description: "B")
            ])
        ])
        assertBuildError(.duplicateCriterionKey(questionID: "route"), questions: [
            .init(id: "route", instructions: "i", criteria: [
                .init(opaqueKey: "a", description: "A"),
                .init(opaqueKey: "a", description: "B")
            ])
        ])
    }

    private func batch(questions: [JevJudgmentQuestion]) throws -> JevJudgmentBatch {
        try JevJudgmentBatch(questions: questions)
    }

    private func assertBuildError(
        _ expected: JevJudgmentBatch.BuildError,
        questions: [JevJudgmentQuestion],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try JevJudgmentBatch(questions: questions), file: file, line: line) {
            XCTAssertEqual($0 as? JevJudgmentBatch.BuildError, expected, file: file, line: line)
        }
    }
}

final class DecisionServiceContractTests: XCTestCase {
    private let validator = FiniteChoiceDecisionValidator()

    func testRegistryRejectsBlankDuplicateAndInvalidCapabilityRegistrations() throws {
        let blank = FakeDecisionService(id: .init(rawValue: "  "))
        XCTAssertThrowsError(try DecisionServiceRegistry(registrations: [.init(service: blank)])) {
            XCTAssertEqual($0 as? DecisionServiceRegistryError, .invalidServiceID)
        }
        let first = FakeDecisionService(id: .init(rawValue: "third"))
        let duplicate = FakeDecisionService(id: .init(rawValue: "THIRD"))
        XCTAssertThrowsError(try DecisionServiceRegistry(registrations: [
            .init(service: first), .init(service: duplicate)
        ])) {
            XCTAssertEqual($0 as? DecisionServiceRegistryError, .duplicateServiceID(first.id))
        }
        let invalid = FakeDecisionService(id: .init(rawValue: "invalid"), capabilities: testCapabilities(maxChoices: 1))
        XCTAssertThrowsError(try DecisionServiceRegistry(registrations: [.init(service: invalid)])) {
            XCTAssertEqual($0 as? DecisionServiceRegistryError, .invalidCapabilities(invalid.id))
        }
    }

    func testRegistrationOrderExactLookupUnknownPersistedIDAndNoFallback() async throws {
        let first = FakeDecisionService(id: .init(rawValue: "first"))
        let third = FakeDecisionService(id: .init(rawValue: "third"))
        let registry = try DecisionServiceRegistry(registrations: [
            .init(service: third, displayOrder: 20), .init(service: first, displayOrder: 10)
        ])
        let ids = await registry.registrations().map(\.id)
        XCTAssertEqual(ids, [first.id, third.id])
        let unknown = DecisionServiceID(rawValue: "missing-persisted-id")
        let missing = await registry.registration(for: unknown)
        XCTAssertNil(missing)
        let result = await DecisionCoordinator(registry: registry).decide(serviceID: unknown, request: request())
        XCTAssertEqual(result, .unavailable)
        let firstCalls = await first.decisionCount
        let thirdCalls = await third.decisionCount
        XCTAssertEqual(firstCalls, 0)
        XCTAssertEqual(thirdCalls, 0)
    }

    func testPrimitiveCapabilityFilteringForBothConsumersAndConcreteBounds() async throws {
        let wide = FakeDecisionService(id: .init(rawValue: "wide"), capabilities: testCapabilities(confidence: true))
        let narrow = FakeDecisionService(id: .init(rawValue: "narrow"), capabilities: testCapabilities(maxContext: 4))
        let noConfidence = FakeDecisionService(id: .init(rawValue: "no-confidence"))
        let registry = try DecisionServiceRegistry(registrations: [
            .init(service: wide), .init(service: narrow), .init(service: noConfidence)
        ])
        for consumer in [DecisionConsumerID.modelRouter, .autoEffort] {
            let compatible = await registry.compatibleRegistrations(
                with: .textFiniteChoice,
                request: request(consumer: consumer)
            ).map(\.id)
            XCTAssertEqual(compatible, [narrow.id, noConfidence.id, wide.id])
            let tooLong = await registry.compatibleRegistrations(
                with: .textFiniteChoice,
                request: request(consumer: consumer, context: "long context")
            ).map(\.id)
            XCTAssertEqual(tooLong, [noConfidence.id, wide.id])
        }
        let requirement = DecisionCapabilityRequirement(
            contextKind: .text, requiresConfidence: true, requiresProbabilities: false, requiresUsage: false
        )
        let withConfidence = await registry.compatibleRegistrations(with: requirement, request: request()).map(\.id)
        XCTAssertEqual(withConfidence, [wide.id])
    }

    func testRequestValidationRejectsDuplicateBlankAndOversizedOpaqueChoices() {
        let caps = testCapabilities()
        XCTAssertNoThrow(try validator.validateRequest(request(), capabilities: caps))
        XCTAssertThrowsError(try validator.validateRequest(
            request(choices: [choice("a"), choice("a")]), capabilities: caps
        )) { XCTAssertEqual($0 as? FiniteChoiceDecisionValidator.RequestError, .duplicateOpaqueKey) }
        XCTAssertThrowsError(try validator.validateRequest(
            request(choices: [choice(" "), choice("b")]), capabilities: caps
        )) { XCTAssertEqual($0 as? FiniteChoiceDecisionValidator.RequestError, .invalidOpaqueKey) }
        XCTAssertThrowsError(try validator.validateRequest(
            request(choices: [choice(String(repeating: "é", count: 65)), choice("b")]), capabilities: caps
        )) { XCTAssertEqual($0 as? FiniteChoiceDecisionValidator.RequestError, .invalidOpaqueKey) }
        XCTAssertThrowsError(try validator.validateRequest(
            request(name: "not ascii é"), capabilities: caps
        )) { XCTAssertEqual($0 as? FiniteChoiceDecisionValidator.RequestError, .invalidQuestion) }
        XCTAssertThrowsError(try validator.validateRequest(
            request(choices: (0 ... 12).map { choice("k\($0)") }), capabilities: caps
        )) { XCTAssertEqual($0 as? FiniteChoiceDecisionValidator.RequestError, .invalidChoiceCount) }
        XCTAssertThrowsError(try validator.validateRequest(
            request(context: String(repeating: "a", count: 24 * 1024 + 1)), capabilities: caps
        )) { XCTAssertEqual($0 as? FiniteChoiceDecisionValidator.RequestError, .sizeLimitExceeded) }
    }

    func testExactSelectionAndUnknownOrMissingChoice() async throws {
        let service = FakeDecisionService(id: .init(rawValue: "third"))
        let registry = try DecisionServiceRegistry(registrations: [.init(service: service)])
        let coordinator = DecisionCoordinator(registry: registry)
        let selected = await coordinator.decide(serviceID: service.id, request: request())
        XCTAssertEqual(selected, .selected(opaqueKey: "a", evidence: nil))
        await service.setOutcome(.selected(opaqueKey: "unknown", evidence: nil))
        let invalid = await coordinator.decide(serviceID: service.id, request: request())
        XCTAssertEqual(invalid, .invalidResponse)
        await service.setOutcome(.selected(opaqueKey: "", evidence: nil))
        let missing = await coordinator.decide(serviceID: service.id, request: request())
        XCTAssertEqual(missing, .invalidResponse)
        await service.setOutcome(.abstained(reasonCode: "refused", evidence: nil))
        let refused = await coordinator.decide(serviceID: service.id, request: request())
        XCTAssertEqual(refused, .abstained(reasonCode: "refused", evidence: nil))
    }

    func testEvidenceRequiresExactCoverageSemanticsAndPolicyOnAllOutcomes() {
        let req = request()
        let accepted = evidence(scores: [value("a", 0.2), value("b", 0.8)])
        XCTAssertEqual(validator.validateOutcome(
            .selected(opaqueKey: "b", evidence: accepted), request: req, acceptancePolicyVersion: "v1"
        ), .selected(opaqueKey: "b", evidence: accepted))
        let badEvidence = [
            evidence(scores: [value("a", 0.2), value("a", 0.8)]),
            evidence(scores: [value("a", 0.2)]),
            evidence(scores: [value("a", 0.2), value("unknown", 0.8)]),
            evidence(scores: [value("a", .nan), value("b", 0.8)]),
            evidence(scores: [value("a", -0.1), value("b", 0.8)]),
            evidence(scores: [value("a", 0.2), value("b", 0.8)], scoreSemantics: .probability),
            evidence(probabilities: [value("a", 0.5), value("a", 0.5)]),
            evidence(confidence: .infinity),
            evidence(inputTokens: -1),
            evidence(policyVersion: "stale")
        ]
        for invalid in badEvidence {
            XCTAssertEqual(validator.validateOutcome(
                .selected(opaqueKey: "a", evidence: invalid), request: req, acceptancePolicyVersion: "v1"
            ), .invalidResponse)
            XCTAssertEqual(validator.validateOutcome(
                .abstained(reasonCode: "refused", evidence: invalid), request: req, acceptancePolicyVersion: "v1"
            ), .invalidResponse)
            XCTAssertEqual(validator.validateOutcome(
                .failed(category: .transport, retryable: true, evidence: invalid),
                request: req, acceptancePolicyVersion: "v1"
            ), .invalidResponse)
        }
    }

    func testProbabilityEvidenceRequiresNormalizedSumButIndependentScoresDoNot() {
        let req = request()
        for values in [[0.0, 0.0], [0.8, 0.8], [0.5, 0.5002]] {
            let invalid = evidence(probabilities: [value("a", values[0]), value("b", values[1])])
            XCTAssertEqual(validator.validateOutcome(
                .selected(opaqueKey: "a", evidence: invalid), request: req, acceptancePolicyVersion: "v1"
            ), .invalidResponse)
            let independent = evidence(scores: [value("a", values[0]), value("b", values[1])])
            XCTAssertEqual(validator.validateOutcome(
                .selected(opaqueKey: "a", evidence: independent), request: req, acceptancePolicyVersion: "v1"
            ), .selected(opaqueKey: "a", evidence: independent))
        }
    }

    func testCoordinatorRejectsMalformedRequestBeforeServiceReadinessOrCredentialAccess() async throws {
        let service = FakeDecisionService(id: .init(rawValue: "third"))
        let registry = try DecisionServiceRegistry(registrations: [.init(service: service)])
        let invalid = request(choices: [choice("same"), choice("same")])
        let result = await DecisionCoordinator(registry: registry).decide(serviceID: service.id, request: invalid)
        XCTAssertEqual(result, .invalidRequest)
        let readinessCalls = await service.readinessCount
        let decisionCalls = await service.decisionCount
        XCTAssertEqual(readinessCalls, 0)
        XCTAssertEqual(decisionCalls, 0)
    }

    func testReadinessGenerationChangeRejectsSelection() async throws {
        let service = FakeDecisionService(id: .init(rawValue: "third"), pause: .readiness(2))
        let registry = try DecisionServiceRegistry(registrations: [.init(service: service)])
        let coordinator = DecisionCoordinator(registry: registry)
        let task = Task { await coordinator.decide(serviceID: service.id, request: request()) }
        await service.waitUntilPaused()
        await service.setReadiness(.ready(generation: 2, policyVersion: "v1"))
        await service.release()
        let outcome = await task.value
        XCTAssertEqual(outcome, .unavailable)
    }

    func testCancellationBeforeReadinessPromptlySettlesAndIgnoresLateWork() async throws {
        let service = FakeDecisionService(id: .init(rawValue: "third"), pause: .readiness(1))
        let registry = try DecisionServiceRegistry(registrations: [.init(service: service)])
        let coordinator = DecisionCoordinator(registry: registry)
        let req = request()
        let task = Task { await coordinator.decide(serviceID: service.id, request: req) }
        await service.waitUntilPaused()
        await coordinator.cancel(requestID: req.requestID)
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        await service.release()
        let calls = await service.decisionCount
        XCTAssertEqual(calls, 0)
    }

    func testCancellationIgnoringServiceCannotSettleReusedRequestID() async throws {
        let service = FakeDecisionService(id: .init(rawValue: "third"), pause: .decision(1))
        let registry = try DecisionServiceRegistry(registrations: [.init(service: service)])
        let coordinator = DecisionCoordinator(registry: registry)
        let req = request()
        let first = Task { await coordinator.decide(serviceID: service.id, request: req) }
        await service.waitUntilPaused()
        let duplicate = await coordinator.decide(serviceID: service.id, request: req)
        XCTAssertEqual(duplicate, .invalidRequest)
        await coordinator.cancel(requestID: req.requestID)
        let cancelled = await first.value
        XCTAssertEqual(cancelled, .cancelled)
        let second = await coordinator.decide(serviceID: service.id, request: req)
        XCTAssertEqual(second, .selected(opaqueKey: "a", evidence: nil))
        await service.release()
    }

    func testRevisionAdvanceCancelsOldReservationAndRejectsLateOldAdmission() async throws {
        let service = FakeDecisionService(id: .init(rawValue: "third"), pause: .decision(1))
        let registry = try DecisionServiceRegistry(registrations: [.init(service: service)])
        let coordinator = DecisionCoordinator(registry: registry)
        let old = Task { await coordinator.decide(serviceID: service.id, request: request(), consumerRevision: 1) }
        await service.waitUntilPaused()
        await coordinator.advanceConsumerRevision(consumerID: .modelRouter, revision: 2)
        let oldOutcome = await old.value
        XCTAssertEqual(oldOutcome, .cancelled)
        let late = await coordinator.decide(serviceID: service.id, request: request(), consumerRevision: 1)
        XCTAssertEqual(late, .cancelled)
        let decisionCount = await service.decisionCount
        XCTAssertEqual(decisionCount, 1)
        let current = await coordinator.decide(serviceID: service.id, request: request(), consumerRevision: 2)
        XCTAssertEqual(current, .selected(opaqueKey: "a", evidence: nil))
        await service.release()
    }

    func testDelayedRevisionAdvancePreservesCurrentReservation() async throws {
        let service = FakeDecisionService(id: .init(rawValue: "third"), pause: .decision(1))
        let registry = try DecisionServiceRegistry(registrations: [.init(service: service)])
        let coordinator = DecisionCoordinator(registry: registry)
        let current = Task { await coordinator.decide(serviceID: service.id, request: request(), consumerRevision: 3) }
        await service.waitUntilPaused()
        await coordinator.advanceConsumerRevision(consumerID: .modelRouter, revision: 2)
        await coordinator.advanceConsumerRevision(consumerID: .modelRouter, revision: 3)
        await service.release()
        let outcome = await current.value
        XCTAssertEqual(outcome, .selected(opaqueKey: "a", evidence: nil))
    }

    func testEqualRevisionAdmissionsCoexist() async throws {
        let service = FakeDecisionService(id: .init(rawValue: "third"), pause: .decision(1))
        let registry = try DecisionServiceRegistry(registrations: [.init(service: service)])
        let coordinator = DecisionCoordinator(registry: registry)
        let first = Task { await coordinator.decide(serviceID: service.id, request: request(), consumerRevision: 3) }
        await service.waitUntilPaused()
        let second = await coordinator.decide(serviceID: service.id, request: request(), consumerRevision: 3)
        XCTAssertEqual(second, .selected(opaqueKey: "a", evidence: nil))
        await service.release()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .selected(opaqueKey: "a", evidence: nil))
    }

    func testAutoEffortRevisionAdvanceDoesNotCancelModelRouterReservation() async throws {
        let service = FakeDecisionService(id: .init(rawValue: "third"), pause: .decision(1))
        let registry = try DecisionServiceRegistry(registrations: [.init(service: service)])
        let coordinator = DecisionCoordinator(registry: registry)
        let modelRoute = Task {
            await coordinator.decide(serviceID: service.id, request: request(), consumerRevision: 1)
        }
        await service.waitUntilPaused()
        await coordinator.advanceConsumerRevision(consumerID: .autoEffort, revision: 2)
        await service.release()
        let outcome = await modelRoute.value
        XCTAssertEqual(outcome, .selected(opaqueKey: "a", evidence: nil))
    }

    func testCallerCancellationPromptlySettlesPausedService() async throws {
        let service = FakeDecisionService(id: .init(rawValue: "third"), pause: .decision(1))
        let registry = try DecisionServiceRegistry(registrations: [.init(service: service)])
        let coordinator = DecisionCoordinator(registry: registry)
        let task = Task { await coordinator.decide(serviceID: service.id, request: request()) }
        await service.waitUntilPaused()
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        await service.release()
    }

    func testCallerCancellationWinsAfterServiceSelectedButBeforeSettlement() async throws {
        // Pause after the cancellation-ignoring service has returned its selection, then
        // cancel synchronously at the coordinator's final settlement boundary. An actor-
        // queued cancellation cannot run until that boundary returns and would lose.
        let service = FakeDecisionService(id: .init(rawValue: "third"), pause: .readiness(2))
        let registry = try DecisionServiceRegistry(registrations: [.init(service: service)])
        let req = request()
        let expectedRequestID = req.requestID
        let race = CallerCancellationRace()
        let coordinator = DecisionCoordinator(registry: registry, beforeSettlement: { requestID, outcome in
            guard requestID == expectedRequestID, case .selected = outcome else { return }
            race.cancelCaller()
        })
        let recorder = DecisionOutcomeRecorder()
        let task = Task {
            let outcome = await coordinator.decide(serviceID: service.id, request: req)
            await recorder.record(outcome)
            return outcome
        }
        race.install(task)
        await service.waitUntilPaused()
        let decisionCount = await service.decisionCount
        XCTAssertEqual(decisionCount, 1, "Selected service result must already be ready")

        await service.release()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(race.cancellationCount, 1)
        let delivered = await recorder.outcomes
        XCTAssertEqual(delivered, [.cancelled], "Exactly one terminal outcome reaches the caller; no selection escapes")
    }

    func testCancellationAfterSelectionBeforeReadinessCheck() async throws {
        let service = FakeDecisionService(id: .init(rawValue: "third"), pause: .readiness(2))
        let registry = try DecisionServiceRegistry(registrations: [.init(service: service)])
        let coordinator = DecisionCoordinator(registry: registry)
        let req = request()
        let task = Task { await coordinator.decide(serviceID: service.id, request: req) }
        await service.waitUntilPaused()
        await coordinator.cancel(requestID: req.requestID)
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        await service.release()
    }

    private func request(
        consumer: DecisionConsumerID = .modelRouter,
        context: String = "task",
        name: String = "choice",
        choices: [DecisionChoice] = [
            DecisionChoice(opaqueKey: "a", description: "First"),
            DecisionChoice(opaqueKey: "b", description: "Second")
        ]
    ) -> FiniteChoiceDecisionRequest {
        FiniteChoiceDecisionRequest(
            requestID: UUID(), consumerID: consumer,
            contractVersion: FiniteChoiceDecisionRequest.currentContractVersion,
            policy: .init(id: "test-policy", version: "1"), textContext: context,
            question: .init(name: name, instructions: "Choose one.", choices: choices)
        )
    }

    private func choice(_ key: String) -> DecisionChoice {
        .init(opaqueKey: key, description: "Description")
    }

    private func value(_ key: String, _ score: Double) -> DecisionChoiceValue {
        .init(opaqueKey: key, value: score)
    }

    private func evidence(
        policyVersion: String = "v1",
        confidence: Double? = nil,
        scores: [DecisionChoiceValue]? = nil,
        scoreSemantics: DecisionValueSemantics? = .independentScore,
        probabilities: [DecisionChoiceValue]? = nil,
        inputTokens: Int? = nil
    ) -> DecisionEvidence {
        .init(
            acceptancePolicyVersion: policyVersion, confidence: confidence, scores: scores,
            scoreSemantics: scores == nil ? nil : scoreSemantics, probabilities: probabilities,
            probabilitySemantics: probabilities == nil ? nil : .probability,
            usage: inputTokens.map { .init(inputTokens: $0, outputTokens: 0) }
        )
    }
}

private func testCapabilities(
    maxChoices: Int = 12, maxContext: Int = 24 * 1024, confidence: Bool = false
) -> DecisionServiceCapabilities {
    .init(
        contextKinds: [.text],
        finiteChoice: .init(
            minimumChoices: 2, maximumChoices: maxChoices, maximumContextBytes: maxContext,
            maximumInstructionsBytes: 16 * 1024, maximumChoiceDescriptionBytes: 8 * 1024,
            maximumAggregateBytes: 128 * 1024
        ),
        evidence: .init(confidence: confidence, probabilityDistribution: false, usage: false)
    )
}

/// Deterministic third-service fixture. Suspension deliberately ignores task cancellation.
private actor FakeDecisionService: DecisionService {
    enum PausePoint: Equatable { case none, readiness(Int), decision(Int) }

    let id: DecisionServiceID
    let displayName = "Third service"
    let capabilities: DecisionServiceCapabilities
    private var readiness: DecisionReadiness = .ready(generation: 1, policyVersion: "v1")
    private var outcome: DecisionOutcome = .selected(opaqueKey: "a", evidence: nil)
    private let pause: PausePoint
    private var pausedContinuation: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var readinessCount = 0
    private(set) var decisionCount = 0

    init(id: DecisionServiceID, capabilities: DecisionServiceCapabilities = testCapabilities(), pause: PausePoint = .none) {
        self.id = id
        self.capabilities = capabilities
        self.pause = pause
    }

    func readinessSnapshot() async -> DecisionReadiness {
        readinessCount += 1
        if pause == .readiness(readinessCount) { await suspend() }
        return readiness
    }

    func decide(_ request: FiniteChoiceDecisionRequest) async -> DecisionOutcome {
        decisionCount += 1
        if pause == .decision(decisionCount) { await suspend() }
        return outcome
    }

    func setOutcome(_ newOutcome: DecisionOutcome) {
        outcome = newOutcome
    }

    func setReadiness(_ newReadiness: DecisionReadiness) {
        readiness = newReadiness
    }

    func waitUntilPaused() async {
        guard pausedContinuation == nil else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() {
        pausedContinuation?.resume()
        pausedContinuation = nil
    }

    private func suspend() async {
        await withCheckedContinuation { continuation in
            pausedContinuation = continuation
            let waiters = pauseWaiters
            pauseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}

private actor DecisionOutcomeRecorder {
    private(set) var outcomes: [DecisionOutcome] = []

    func record(_ outcome: DecisionOutcome) {
        outcomes.append(outcome)
    }
}

/// A synchronous cancellation trigger for the instant just before coordinator settlement.
private final class CallerCancellationRace: @unchecked Sendable {
    private let lock = NSLock()
    private var cancel: (() -> Void)?
    private var count = 0

    var cancellationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func install(_ task: Task<DecisionOutcome, Never>) {
        lock.lock()
        cancel = { task.cancel() }
        lock.unlock()
    }

    func cancelCaller() {
        lock.lock()
        let action = cancel
        cancel = nil
        if action != nil { count += 1 }
        lock.unlock()
        action?()
    }
}
