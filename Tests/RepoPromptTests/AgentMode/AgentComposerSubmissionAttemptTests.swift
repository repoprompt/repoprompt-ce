import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentComposerSubmissionAttemptTests: XCTestCase {
    func testComposerProductionEqualityRejectsLiveTabChangeBeforePropsCatchUp() {
        let sourceTabID = UUID()
        let destinationTabID = UUID()

        XCTAssertTrue(
            AgentComposerView.hasEquivalentRenderIdentity(
                lhsProps: .empty,
                lhsPlaceholderText: "Send a message...",
                lhsCurrentTabID: sourceTabID,
                rhsProps: .empty,
                rhsPlaceholderText: "Send a message...",
                rhsCurrentTabID: sourceTabID
            )
        )
        XCTAssertFalse(
            AgentComposerView.hasEquivalentRenderIdentity(
                lhsProps: .empty,
                lhsPlaceholderText: "Send a message...",
                lhsCurrentTabID: sourceTabID,
                rhsProps: .empty,
                rhsPlaceholderText: "Send a message...",
                rhsCurrentTabID: destinationTabID
            )
        )
    }

    func testLatchSuppressesRapidSameTabCallbacksButAllowsAnotherTab() throws {
        var latch = AgentComposerSubmissionLatch()
        let firstSession = AgentModeViewModel.TabSession(tabID: UUID())
        let secondSession = AgentModeViewModel.TabSession(tabID: UUID())
        let firstTarget = makeTarget(session: firstSession)
        let secondTarget = makeTarget(session: secondSession)

        let firstAttempt = try XCTUnwrap(latch.begin(target: firstTarget, rawDraftSnapshot: "first"))

        XCTAssertTrue(latch.isLatched(for: firstSession.tabID))
        XCTAssertEqual(latch.activeAttemptID(for: firstSession.tabID), firstAttempt.id)
        XCTAssertNil(latch.begin(target: firstTarget, rawDraftSnapshot: "duplicate"))
        XCTAssertNotNil(latch.begin(target: secondTarget, rawDraftSnapshot: "second"))
    }

    func testMatchingCompletionClearsOnlyUnchangedInput() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        latch.advanceInputRevision()
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "submitted draft")
        )

        let effects = latch.complete(
            attempt,
            result: .submitted,
            currentTabID: session.tabID,
            currentRawDraft: "submitted draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertTrue(effects.shouldClearInput)
        XCTAssertNil(effects.blockedMessage)
        XCTAssertFalse(latch.isLatched(for: session.tabID))
    }

    func testNewerTypingAndDraftRestorationSurviveCompletion() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        latch.advanceInputRevision()
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "submitted draft")
        )

        // A programmatic restoration must advance the same revision even when the
        // resulting text happens to match the submitted text.
        latch.advanceInputRevision()
        let effects = latch.complete(
            attempt,
            result: .submitted,
            currentTabID: session.tabID,
            currentRawDraft: "submitted draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertFalse(effects.shouldClearInput)
    }

    func testTabSwitchPreventsOldCompletionFromClearingCurrentDraft() throws {
        var latch = AgentComposerSubmissionLatch()
        let sourceSession = AgentModeViewModel.TabSession(tabID: UUID())
        let currentSession = AgentModeViewModel.TabSession(tabID: UUID())
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: sourceSession), rawDraftSnapshot: "same text")
        )

        let effects = latch.complete(
            attempt,
            result: .submitted,
            currentTabID: currentSession.tabID,
            currentRawDraft: "same text"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertFalse(effects.shouldClearInput)
    }

    func testStaleCompletionCannotReleaseNewerAttempt() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let target = makeTarget(session: session)
        let oldAttempt = try XCTUnwrap(
            latch.begin(target: target, rawDraftSnapshot: "old", attemptID: UUID())
        )
        XCTAssertTrue(latch.cancel(oldAttempt))
        let newAttempt = try XCTUnwrap(
            latch.begin(target: target, rawDraftSnapshot: "new", attemptID: UUID())
        )

        let staleEffects = latch.complete(
            oldAttempt,
            result: .submitted,
            currentTabID: session.tabID,
            currentRawDraft: "new"
        )

        XCTAssertEqual(staleEffects, .stale)
        XCTAssertEqual(latch.activeAttemptID(for: session.tabID), newAttempt.id)
    }

    func testBlockedCompletionCannotOverwriteNewerNotice() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "draft")
        )
        latch.advanceNoticeRevision()

        let effects = latch.complete(
            attempt,
            result: .blocked(message: "older notice"),
            currentTabID: session.tabID,
            currentRawDraft: "draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertNil(effects.blockedMessage)
    }

    private func makeTarget(session: AgentModeViewModel.TabSession) -> AgentComposerSubmitTarget {
        AgentComposerSubmitTarget(
            tabID: session.tabID,
            route: .createAgentSessionFromSourceTab,
            expectedSourceTabSessionIdentity: ObjectIdentifier(session),
            expectedSourceAgentSessionID: nil,
            expectedPersistentBindingIdentity: nil,
            expectedBindingTransitionGeneration: session.bindingTransitionGeneration,
            expectedRunState: .idle,
            expectedRunID: nil,
            expectedRunAttemptID: nil,
            expectedSubmissionToken: session.composerSubmissionToken,
            expectedInitialStartLocation: .local
        )
    }
}

@MainActor
extension AgentComposerSubmissionAttemptTests {
    func testGlobalRouterOwnsFreshTaskModelPresentationUntilDisabled() throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast)
        let (viewModel, store) = try makeRoutingViewModel(backend: backend)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = AgentModel.claudeHaiku.rawValue

        let routedProps = viewModel.makeComposerProps(tabID: tabID)
        XCTAssertTrue(routedProps.isGlobalModelRouterControllingFreshTask)
        XCTAssertTrue(routedProps.areModelControlsDisabled)
        XCTAssertEqual(session.selectedAgent, .claudeCode)
        XCTAssertEqual(session.selectedModelRaw, AgentModel.claudeHaiku.rawValue)

        store.setModelRouterEnabled(false)

        let manualProps = viewModel.makeComposerProps(tabID: tabID)
        XCTAssertFalse(manualProps.isGlobalModelRouterControllingFreshTask)
        XCTAssertFalse(manualProps.areModelControlsDisabled)
        XCTAssertEqual(session.selectedModelRaw, AgentModel.claudeHaiku.rawValue)
    }

    func testGlobalRouterOwnsFreshTaskWithSelectedPromptWorkflow() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast)
        let (viewModel, _) = try makeRoutingViewModel(backend: backend)
        try await waitForRouterReadiness(
            .ready(generation: 1, policyVersion: "fake-v1"),
            backendID: backend.id,
            viewModel: viewModel
        )
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedWorkflow = AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "Worktree Orchestrate",
            template: "$ARGUMENTS"
        )

        let props = viewModel.makeComposerProps(tabID: tabID)

        XCTAssertTrue(props.isGlobalModelRouterControllingFreshTask)
        XCTAssertTrue(props.areModelControlsDisabled)
    }

    func testMissingRouterCredentialPreservesPersistedEnablementIntent() async throws {
        let backend = ComposerRoutingBackend(
            outcome: .selectLast,
            readiness: .needsConfiguration(generation: 1, reason: "Validate a TypeSafe API key.")
        )
        let (viewModel, store) = try makeRoutingViewModel(backend: backend)
        XCTAssertTrue(store.modelRouterConfiguration().enabled)

        let expected: AgentTaskRouterBackendReadiness = .needsConfiguration(
            generation: 1, reason: "Validate a TypeSafe API key."
        )
        try await waitForRouterReadiness(expected, backendID: backend.id, viewModel: viewModel)

        viewModel.handleModelRouterRuntimeChanged()

        XCTAssertTrue(store.modelRouterConfiguration().enabled)
        XCTAssertTrue(viewModel.modelRouterPillProps().isOn)
        XCTAssertTrue(viewModel.modelRouterPillProps().isAvailable)
        XCTAssertNotNil(viewModel.modelRouterPillProps().disabledReason)
    }

    func testMissingRouterCredentialUsesCurrentSelectionWithoutClearingIntent() async throws {
        let backend = ComposerRoutingBackend(
            outcome: .selectLast,
            readiness: .needsConfiguration(generation: 1, reason: "Validate a TypeSafe API key.")
        )
        let (viewModel, store) = try makeRoutingViewModel(backend: backend)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        let claim = try routingClaim(viewModel: viewModel, session: session, text: "Implement a parser")

        let result = await viewModel.submitUserTurnAfterFreshTaskRouting(
            text: "Implement a parser",
            claim: claim,
            session: session,
            destinationTabID: tabID
        )

        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(store.modelRouterConfiguration().enabled)
    }

    func testMissingRouterCredentialLeavesSubagentRoleDefaultInControl() async throws {
        let backend = ComposerRoutingBackend(
            outcome: .selectLast,
            readiness: .needsConfiguration(generation: 1, reason: "Validate a TypeSafe API key.")
        )
        let (viewModel, store) = try makeRoutingViewModel(backend: backend)

        let routed = try await viewModel.routeSubagentTargetIfEnabled(task: "Explore the parser", surface: .general)
        XCTAssertNil(routed)
        XCTAssertTrue(store.modelRouterConfiguration().enabled)
    }

    func testFakeReadyRouterCommitsSelectedExecutableTargetAtSubmitBoundary() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast)
        let (viewModel, store) = try makeRoutingViewModel(backend: backend)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = AgentModel.claudeSonnet.rawValue
        let baseline = AgentRoutingExecutableTarget(
            agentRaw: session.selectedAgent.rawValue,
            modelRaw: session.selectedModelRaw,
            reasoningEffortRaw: session.selectedReasoningEffortRaw,
            modelParameters: session.acpModelParameterSelections
        )
        let claim = try routingClaim(viewModel: viewModel, session: session, text: "Implement a parser")

        let result = await viewModel.submitUserTurnAfterFreshTaskRouting(
            text: "Implement a parser",
            claim: claim,
            session: session,
            destinationTabID: tabID
        )

        XCTAssertEqual(result, .submitted)
        let selected = AgentRoutingExecutableTarget(
            agentRaw: session.selectedAgent.rawValue,
            modelRaw: session.selectedModelRaw,
            reasoningEffortRaw: session.selectedReasoningEffortRaw,
            modelParameters: session.acpModelParameterSelections
        )
        XCTAssertNotEqual(selected, baseline)
        XCTAssertTrue(store.modelRouterConfiguration().enabled)
    }

    func testFakeRouterAbstentionSubmitsWithCurrentSelection() async throws {
        let backend = ComposerRoutingBackend(outcome: .abstain)
        let (viewModel, _) = try makeRoutingViewModel(backend: backend)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = AgentModel.claudeSonnet.rawValue
        let baseline = (session.selectedAgent, session.selectedModelRaw, session.selectedReasoningEffortRaw, session.acpModelParameterSelections)
        let claim = try routingClaim(viewModel: viewModel, session: session, text: "Investigate a race")

        let result = await viewModel.submitUserTurnAfterFreshTaskRouting(
            text: "Investigate a race",
            claim: claim,
            session: session,
            destinationTabID: tabID
        )

        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(session.selectedAgent, baseline.0)
        XCTAssertEqual(session.selectedModelRaw, baseline.1)
        XCTAssertEqual(session.selectedReasoningEffortRaw, baseline.2)
        XCTAssertEqual(session.acpModelParameterSelections, baseline.3)
    }

    func testLongComposerTaskStillRoutesOnMaskedExcerpt() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast)
        let (viewModel, _) = try makeRoutingViewModel(backend: backend)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        let text = "Implement a parser. password=private123 "
            + String(repeating: "background detail ", count: 300)
            + " Finally, add regression tests. token=lastsecret"
        let claim = try routingClaim(viewModel: viewModel, session: session, text: text)

        let result = await viewModel.submitUserTurnAfterFreshTaskRouting(
            text: text, claim: claim, session: session, destinationTabID: tabID
        )

        XCTAssertEqual(result, .submitted)
        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.decisionStage), [.model, .effort])
        XCTAssertEqual(requests.first?.task, requests.last?.task)
        XCTAssertTrue(requests.allSatisfy { $0.task.contains("Implement a parser") })
        XCTAssertTrue(requests.allSatisfy { $0.task.contains("add regression tests") })
        XCTAssertTrue(requests.allSatisfy { !$0.task.contains("private123") && !$0.task.contains("lastsecret") })
        XCTAssertTrue(requests.allSatisfy { $0.task.count <= AgentTaskRoutingEnvelopeBuilder.maximumCharacters })
        XCTAssertEqual(session.transcript.turns.first?.request?.text, text)
    }

    func testLongSubagentTaskStillRoutesOnBoundedExcerpt() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast)
        let (viewModel, _) = try makeRoutingViewModel(backend: backend)
        let task = "Investigate a concurrency bug. "
            + String(repeating: "background context ", count: 300)
            + " Finally, review the cancellation path."

        let selected = try await viewModel.routeSubagentTargetIfEnabled(task: task, surface: .general)

        XCTAssertNotNil(selected)
        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.decisionStage), [.model, .effort])
        XCTAssertTrue(requests.allSatisfy { $0.scope == .subagent })
        XCTAssertTrue(requests.allSatisfy { $0.task.contains("concurrency bug") })
        XCTAssertTrue(requests.allSatisfy { $0.task.contains("cancellation path") })
        XCTAssertTrue(requests.allSatisfy { $0.task != task })
    }

    func testEffortAbstentionKeepsJevSelectedModelWithProviderDefaultEffort() async throws {
        let backend = ComposerRoutingBackend(outcome: .abstainEffort)
        let (viewModel, _) = try makeRoutingViewModel(backend: backend)

        let selected = try await viewModel.routeSubagentTargetIfEnabled(
            task: "Implement parser and tests", surface: .general
        )

        XCTAssertNotNil(selected)
        XCTAssertNil(selected?.reasoningEffortRaw)
        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.decisionStage), [.model, .effort])
    }

    func testModelAbstentionLeavesSubagentRoleDefaultInControl() async throws {
        let backend = ComposerRoutingBackend(outcome: .abstain)
        let (viewModel, _) = try makeRoutingViewModel(backend: backend)
        let selected = try await viewModel.routeSubagentTargetIfEnabled(
            task: "Implement parser and tests", surface: .general
        )
        XCTAssertNil(selected)
    }

    func testGlobalRouterRoutesSubagentRequestWithScopeGuidanceAndTargetIdentity() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast)
        let (viewModel, store) = try makeRoutingViewModel(backend: backend)
        XCTAssertTrue(store.setModelRouterCustomInstructions("Prefer Claude Opus for execution."))

        let selected = try await viewModel.routeSubagentTargetIfEnabled(
            task: "Implement the parser and tests",
            surface: .general
        )

        XCTAssertNotNil(selected)
        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.decisionStage), [.model, .effort])
        XCTAssertTrue(requests.allSatisfy { $0.scope == .subagent })
        XCTAssertTrue(requests.allSatisfy { $0.customInstructions == "Prefer Claude Opus for execution." })
        XCTAssertTrue(requests.allSatisfy { $0.task == "Implement the parser and tests" })
        XCTAssertTrue(requests.allSatisfy { $0.candidates.allSatisfy { !$0.targetDescription.isEmpty } })
    }

    func testCancellationAfterModelSelectionDoesNotStartEffortRouting() async throws {
        let backend = StagedCancellationRoutingBackend()
        let (viewModel, _) = try makeRoutingViewModel(backend: backend)
        let routingTask = Task { @MainActor in
            try await viewModel.routeSubagentTargetIfEnabled(
                task: "Review the concurrency boundary",
                surface: .general
            )
        }
        await backend.waitUntilFirstStageStarted()

        routingTask.cancel()
        await backend.completeFirstStageSelection()

        do {
            _ = try await routingTask.value
            XCTFail("Cancelled routing must not produce a target")
        } catch AgentModeViewModel.GlobalModelRoutingError.cancelled {
            // Expected.
        }
        let requestCount = await backend.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testNewDestinationOwnsVisibleCancelAndRejectsSecondSubmit() async throws {
        let backend = SuspendedComposerRoutingBackend()
        let (viewModel, _) = try makeRoutingViewModel(backend: backend)
        let sourceTabID = UUID()
        let destinationTabID = UUID()
        viewModel.test_setCurrentTabIDOverride(sourceTabID)
        let sourceSession = viewModel.session(for: sourceTabID)
        let claim = try routingClaim(viewModel: viewModel, session: sourceSession, text: "Route this task")

        let execution = Task { @MainActor in
            await viewModel.executeComposerSubmitAttempt(
                text: "Route this task",
                claim: claim,
                createAndActivateSessionTab: {
                    _ = viewModel.session(for: destinationTabID)
                    viewModel.test_setCurrentTabIDOverride(destinationTabID)
                    return destinationTabID
                }
            )
        }
        await backend.waitUntilStarted()

        XCTAssertTrue(viewModel.makeComposerProps(tabID: destinationTabID).isRoutingFreshTask)
        let destinationSession = viewModel.session(for: destinationTabID)
        let secondTarget = try XCTUnwrap(
            viewModel.makeComposerSubmitTarget(tabID: destinationTabID, session: destinationSession)
        )
        let secondAttempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: secondTarget,
            inputRevision: 0,
            noticeRevision: 0,
            rawDraftSnapshot: "second"
        )
        guard case let .rejected(.activeAttemptExists(activeAttemptID)) = viewModel.claimComposerSubmitAttempt(
            secondAttempt,
            requireActiveTabOwnership: false
        ) else {
            return XCTFail("The visible destination must share exact route ownership")
        }
        XCTAssertEqual(activeAttemptID, claim.attempt.id)

        await viewModel.cancelFreshTaskRouting(tabID: destinationTabID)
        guard case .blocked = await execution.value else {
            return XCTFail("Visible destination cancellation must block the pending send")
        }
        XCTAssertFalse(viewModel.makeComposerProps(tabID: destinationTabID).isRoutingFreshTask)
        XCTAssertTrue(sourceSession.items.isEmpty)
        XCTAssertTrue(destinationSession.items.isEmpty)

        await backend.completeLateSelection()
        await Task.yield()
        XCTAssertTrue(sourceSession.items.isEmpty)
        XCTAssertTrue(destinationSession.items.isEmpty)
    }

    /// Runtime initialization publishes readiness asynchronously; assertions that depend on an
    /// exact backend state must observe that publication rather than race the startup task.
    private func waitForRouterReadiness(
        _ expected: AgentTaskRouterBackendReadiness,
        backendID: AgentTaskRouterBackendID,
        viewModel: AgentModeViewModel
    ) async throws {
        let runtime = try XCTUnwrap(viewModel.modelRouterRuntime)
        let readinessPublished = expectation(description: "Router published expected readiness")
        var didFulfill = false
        func fulfillIfPublished() {
            guard !didFulfill, runtime.backendReadiness(backendID) == expected else { return }
            didFulfill = true
            readinessPublished.fulfill()
        }
        let observation = runtime.objectWillChange.sink { _ in
            Task { @MainActor in fulfillIfPublished() }
        }
        fulfillIfPublished()
        await fulfillment(of: [readinessPublished], timeout: 10)
        observation.cancel()
        XCTAssertEqual(runtime.backendReadiness(backendID), expected)
    }

    private func makeRoutingViewModel(
        backend: any AgentTaskRouterBackend
    ) throws -> (AgentModeViewModel, GlobalSettingsStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AgentComposer.router.\(UUID())"))
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        store.enableModelRouterWithCurrentPolicy(
            backendID: backend.id,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )
        let runtime = try AgentTaskRouterRuntime(registrations: [.init(backend: backend)])
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Routing transaction test must not start Codex")
            },
            headlessProviderFactory: { _, _ in UnsupportedHeadlessAgentProvider(reason: "test terminal") }
        )
        viewModel.modelRouterSettingsStore = store
        viewModel.modelRouterRuntime = runtime
        return (viewModel, store)
    }

    private func routingClaim(
        viewModel: AgentModeViewModel,
        session: AgentModeViewModel.TabSession,
        text: String
    ) throws -> AgentModeViewModel.AgentComposerSubmitClaim {
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: session.tabID, session: session))
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 0,
            noticeRevision: 0,
            rawDraftSnapshot: text
        )
        guard case let .claimed(claim) = viewModel.claimComposerSubmitAttempt(
            attempt,
            requireActiveTabOwnership: false
        ) else {
            throw NSError(domain: "AgentComposerSubmissionAttemptTests", code: 1)
        }
        return claim
    }
}

private actor ComposerRoutingBackend: AgentTaskRouterBackend {
    enum Outcome { case selectLast, abstain, abstainEffort }
    nonisolated let id = AgentTaskRouterBackendID(rawValue: "composer-fake")
    nonisolated let displayName = "Composer fake"
    let outcome: Outcome
    let readiness: AgentTaskRouterBackendReadiness
    private(set) var lastRequest: AgentTaskRoutingRequest?
    private(set) var requests: [AgentTaskRoutingRequest] = []

    init(
        outcome: Outcome,
        readiness: AgentTaskRouterBackendReadiness = .ready(generation: 1, policyVersion: "fake-v1")
    ) {
        self.outcome = outcome
        self.readiness = readiness
    }

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        readiness
    }

    func route(_ request: AgentTaskRoutingRequest) -> AgentTaskRoutingBackendOutcome {
        lastRequest = request
        requests.append(request)
        return switch outcome {
        case .selectLast:
            .selected(opaqueKey: request.candidates[request.candidates.count - 1].opaqueKey, evidence: nil)
        case .abstain:
            .abstained(reason: "ambiguous", evidence: nil)
        case .abstainEffort:
            request.decisionStage == .effort
                ? .abstained(reason: "ambiguous effort", evidence: nil)
                : .selected(opaqueKey: request.candidates[request.candidates.count - 1].opaqueKey, evidence: nil)
        }
    }
}

private actor SuspendedComposerRoutingBackend: AgentTaskRouterBackend {
    nonisolated let id = AgentTaskRouterBackendID(rawValue: "composer-suspended")
    nonisolated let displayName = "Composer suspended"
    private var request: AgentTaskRoutingRequest?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<AgentTaskRoutingBackendOutcome, Never>?

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        .ready(generation: 1, policyVersion: "fake-v1")
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        self.request = request
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        return await withCheckedContinuation { completion = $0 }
    }

    func waitUntilStarted() async {
        if request != nil {
            return
        }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func completeLateSelection() {
        guard let key = request?.candidates.first?.opaqueKey else { return }
        completion?.resume(returning: .selected(opaqueKey: key, evidence: nil))
        completion = nil
    }
}

private actor StagedCancellationRoutingBackend: AgentTaskRouterBackend {
    nonisolated let id = AgentTaskRouterBackendID(rawValue: "staged-cancellation")
    nonisolated let displayName = "Staged cancellation"
    private(set) var requestCount = 0
    private var firstRequest: AgentTaskRoutingRequest?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstStageCompletion: CheckedContinuation<AgentTaskRoutingBackendOutcome, Never>?

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        .ready(generation: 1, policyVersion: "fake-v1")
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        requestCount += 1
        guard requestCount == 1 else { return .cancelled }
        firstRequest = request
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        return await withCheckedContinuation { firstStageCompletion = $0 }
    }

    func waitUntilFirstStageStarted() async {
        if firstRequest != nil { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func completeFirstStageSelection() {
        guard let key = firstRequest?.candidates.last?.opaqueKey else { return }
        firstStageCompletion?.resume(returning: .selected(opaqueKey: key, evidence: nil))
        firstStageCompletion = nil
    }
}
