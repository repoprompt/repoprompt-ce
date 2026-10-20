import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

@MainActor
final class AgentRepromptRoutingIntegrationTests: XCTestCase {
    func testAutoEffortUsesApprovedTextAndOversizedOriginalFallback() {
        XCTAssertEqual(AgentModeViewModel.automationJudgingText(original: "vague", reprompted: "Approved task"), "Approved task")
        XCTAssertEqual(AgentModeViewModel.automationJudgingText(original: "original", reprompted: String(repeating: "x", count: 4001)), "original")
        XCTAssertEqual(AgentModeViewModel.automationJudgingText(original: "original", reprompted: String(repeating: "x", count: 4000)).count, 4000)
    }

    func testRouterReusesApprovedBriefWithoutSecondJudgmentAndKeepsOwnershipChecks() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let claim = try fixture.claim(text: "Vague original")
        defer { fixture.viewModel.releaseComposerSubmitClaim(claim) }
        let approved = "Implement the explicitly requested parser outcome."
        fixture.viewModel.startRepromptSpeculation(claim: claim, operationID: UUID(), text: approved)
        let speculation = try XCTUnwrap(fixture.viewModel.repromptSpeculations[claim.attempt.id])
        _ = await speculation.routingTask?.value
        let before = await fixture.backend.requests
        XCTAssertFalse(before.isEmpty)
        XCTAssertTrue(before.allSatisfy { $0.textContext.contains(approved) && !$0.textContext.contains("Vague original") })
        XCTAssertTrue(before.allSatisfy { $0.requestID != claim.attempt.id })
        fixture.viewModel.repromptAudits[claim.attempt.id] = .init(outcome: .approved)
        let result = await fixture.viewModel.submitUserTurnAfterFreshTaskRouting(
            text: "Vague original", claim: claim, session: fixture.session, destinationTabID: fixture.session.tabID,
            repromptedText: approved, precomputedRouting: speculation
        )
        XCTAssertEqual(result, .submitted)
        let after = await fixture.backend.requests
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(fixture.session.items.last(where: { $0.kind == .user })?.text, approved)
        XCTAssertEqual(fixture.session.automationTurnAudit.last?.reprompt?.routerSpeculation, .reused)
    }

    func testAutoEffortWrapperJudgesApprovedTextAndOversizedFallback() async throws {
        for oversized in [false, true] {
            let fixture = try await AgentRepromptTestFixture()
            defer { fixture.cleanUp() }
            fixture.store.setModelRouterEnabled(false)
            fixture.store.setAutoEffortBackendRaw(fixture.backend.id.rawValue)
            fixture.store.setAutoEffortEnabled(true)
            await fixture.runtime.reconcileDemand()
            let option = try XCTUnwrap(AgentModelCatalog.options(for: .claudeCode, availability: fixture.viewModel.modelRouterAvailabilityContext).first {
                AutoEffortModelPolicy.claudeEfforts(modelRaw: $0.rawValue, advertised: AgentModelCatalog.supportedClaudeEfforts(forSelectedModelRaw: $0.rawValue, agentKind: .claudeCode)).count >= 2
            })
            fixture.session.selectedModelRaw = option.rawValue
            let claim = try fixture.claim(text: "Original raw draft")
            defer { fixture.viewModel.releaseComposerSubmitClaim(claim) }
            let approved = oversized ? String(repeating: "x", count: 4001) : "Approved parser requirement"
            let result = await fixture.viewModel.submitUserTurnAfterAutoEffort(text: "Original raw draft", claim: claim, session: fixture.session, destinationTabID: fixture.session.tabID, repromptedText: approved)
            XCTAssertEqual(result, .submitted)
            let requests = await fixture.backend.requests
            let request = try XCTUnwrap(requests.last)
            XCTAssertEqual(request.consumerID, .autoEffort)
            XCTAssertTrue(request.textContext.contains(oversized ? "Original raw draft" : "Approved parser requirement"))
        }
    }

    func testEditedAndPolicyChangedSpeculationIsDiscarded() async throws {
        for edited in [true, false] {
            let fixture = try await AgentRepromptTestFixture()
            defer { fixture.cleanUp() }
            let claim = try fixture.claim(text: "Original")
            defer { fixture.viewModel.releaseComposerSubmitClaim(claim) }
            fixture.viewModel.startRepromptSpeculation(claim: claim, operationID: UUID(), text: "Generated")
            let speculation = try XCTUnwrap(fixture.viewModel.repromptSpeculations[claim.attempt.id])
            _ = await speculation.routingTask?.value
            if !edited {
                fixture.store.setModelRouterCustomInstructions("Changed policy")
            }
            let current = fixture.store.modelRouterConfiguration()
            XCTAssertNil(fixture.viewModel.reusableRepromptRouting(
                speculation, approved: edited ? "Edited" : "Generated", configuration: current,
                backendID: fixture.backend.id, runtime: fixture.runtime
            ))
            XCTAssertEqual(speculation.reuse, edited ? .discardedEdited : .discardedStale)
        }
    }

    func testCancellationReleasesComposerClaimAndCancelsSpeculation() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.repromptEnabled = true
        fixture.viewModel.repromptAvailability = { _ in true }
        fixture.viewModel.repromptService = .init(transport: { _, _ in AgentRepromptServiceTests.valid })
        var profile = fixture.store.globalAgentModelsProfile()
        profile.planningModelRaw = AIModel.gpt61Sol.rawValue
        fixture.store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
        let claim = try fixture.claim(text: "Original")
        let task = Task {
            await fixture.viewModel.executeComposerSubmitAttempt(text: "Original", claim: claim, createAndActivateSessionTab: {
                XCTFail("Cancellation must precede destination creation")
                return nil
            })
        }
        try await AsyncTestWait.waitUntil("Re-prompt review", timeout: 5) { fixture.viewModel.repromptUIStore.presentation?.phase == .reviewing }
        fixture.viewModel.cancelReprompt()
        guard case .blocked = await task.value else { return XCTFail("Cancelled preparation submitted") }
        XCTAssertFalse(fixture.viewModel.composerSubmitClaimIsCurrent(claim))
        XCTAssertNil(fixture.viewModel.repromptSpeculations[claim.attempt.id])
        XCTAssertTrue(fixture.session.items.isEmpty)
    }
}

@MainActor
final class AgentRepromptTestFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let store: GlobalSettingsStore
    let backend = AgentRepromptDecisionBackend()
    let startGate = AgentRepromptStartGate()
    let runtime: AgentTaskRouterRuntime
    let viewModel: AgentModeViewModel
    let session: AgentModeViewModel.TabSession

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "AgentRepromptTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json")))
        store.enableModelRouterWithCurrentPolicy(backendID: backend.id, roles: Set(AgentModelCatalog.TaskLabelKind.allCases), providers: [.claudeCode])
        store.setModelRouterProvider(.claudeCode, scope: .primarySession)
        runtime = try AgentTaskRouterRuntime(registrations: [.init(service: backend)], demandSource: store)
        let gate = startGate
        viewModel = AgentModeViewModel(
            testWorkspacePath: root.path,
            codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Re-prompt tests must not start Codex") },
            headlessProviderFactory: { _, _ in UnsupportedHeadlessAgentProvider(reason: "test terminal") },
            mcpServerEnabler: { await gate.wait() },
            testModelRouterSettingsStore: store
        )
        viewModel.modelRouterRuntime = runtime
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        await runtime.reconcileDemand()
        try await AsyncTestWait.waitUntil("synthetic router ready", timeout: 5) { self.runtime.isBackendReady(self.backend.id) }
    }

    func enableReprompt() {
        viewModel.repromptEnabled = true
        viewModel.repromptAvailability = { _ in true }
        viewModel.repromptService = .init(transport: { _, _ in AgentRepromptServiceTests.valid })
        var profile = store.globalAgentModelsProfile()
        profile.planningModelRaw = AIModel.gpt61Sol.rawValue
        store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
    }

    func claim(text: String) throws -> AgentModeViewModel.AgentComposerSubmitClaim {
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: session.tabID, session: session))
        let attempt = AgentComposerSubmitAttempt(id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: text)
        guard case let .claimed(claim) = viewModel.claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false)
        else { throw CancellationError() }
        return claim
    }

    func cleanUp() {
        viewModel.cancelReprompt()
        for id in Array(viewModel.repromptSpeculations.keys) {
            viewModel.cancelRepromptSpeculation(claimID: id)
        }
        for session in viewModel.sessions.values {
            session.agentTask?.cancel()
            session.saveDebounceTask?.cancel()
            session.derivedTranscriptRefreshTask?.cancel()
        }
        Task { await startGate.release()
            await runtime.teardown()
        }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

actor AgentRepromptStartGate {
    private var released = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    func wait() async -> Bool {
        if released {
            return false
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume(returning: false) }
    }
}

actor AgentRepromptDecisionBackend: DecisionService {
    nonisolated let id = DecisionServiceID.jev
    nonisolated let displayName = "Re-prompt test decisions"
    nonisolated let capabilities = DecisionServiceCapabilities(
        contextKinds: [.text],
        finiteChoice: .init(
            minimumChoices: 2,
            maximumChoices: 12,
            maximumContextBytes: 24 * 1024,
            maximumInstructionsBytes: 16 * 1024,
            maximumChoiceDescriptionBytes: 8 * 1024,
            maximumAggregateBytes: 128 * 1024
        ),
        evidence: .init(confidence: true, probabilityDistribution: true, usage: true)
    )
    private(set) var requests: [FiniteChoiceDecisionRequest] = []
    func readinessSnapshot() -> DecisionReadiness {
        .ready(generation: 1, policyVersion: "test")
    }

    func decide(_ request: FiniteChoiceDecisionRequest) -> DecisionOutcome {
        requests.append(request)
        return .selected(opaqueKey: request.question.choices.last!.opaqueKey, evidence: nil)
    }
}
