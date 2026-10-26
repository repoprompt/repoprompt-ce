import Combine
import Foundation
@testable import RepoPromptApp
import RepoPromptProviderQuota
import RepoPromptSecureStorage
import RepoPromptSettingsCore
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
    func testSavedScopeProvidersConstrainCandidatesAndSubmittedTarget() async throws {
        let backend = ComposerRoutingBackend(outcome: .preferClaude)
        let controller = ComposerRoutingCodexController()
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend, codexController: controller)
        store.setModelRouterProvider(.codexExec, scope: .primarySession)
        store.setModelRouterProvider(.claudeCode, scope: .subagent)
        await viewModel.modelRouterRuntime?.reconcileDemand()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-6.1-sol-high"
        let text = "Implement parser and tests"
        _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session))
        session.hasLoadedPersistedState = true
        // An installed binding admits operations only after restoration is authoritative (#1363).
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        let claim = try routingClaim(viewModel: viewModel, session: session, text: text)

        let result = await viewModel.submitUserTurnAfterFreshTaskRouting(
            text: text, claim: claim, session: session, destinationTabID: tabID
        )

        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(session.selectedAgent, .codexExec)
        let primaryRequests = await backend.requests
        let primaryModelRequest = try XCTUnwrap(primaryRequests.first { $0.question.name == "model_route" })
        XCTAssertTrue(primaryModelRequest.question.choices.allSatisfy { $0.description.hasPrefix("Provider: codexExec;") })
        XCTAssertEqual(session.automationTurnAudit.last?.acceptedProviderRaw, "codexExec")
        try await AsyncTestWait.waitUntil("routed Codex turn dispatched or rejected", timeout: 5) {
            !controller.submittedModels.isEmpty || session.items.contains { $0.kind == .error }
        }
        XCTAssertEqual(controller.submittedModels, [CodexModelSpecifier(raw: session.selectedModelRaw).baseModel], session.items.map(\.text).joined(separator: "\n"))

        let child = try await viewModel.routeSubagentTargetIfEnabled(task: text, surface: .headless)
        XCTAssertEqual(child?.agentRaw, "claudeCode")
        let childRequests = await backend.requests.dropFirst(primaryRequests.count)
        let childModelRequest = try XCTUnwrap(childRequests.first { $0.question.name == "model_route" })
        XCTAssertTrue(childModelRequest.question.choices.allSatisfy { $0.description.hasPrefix("Provider: claudeCode;") })
    }

    func testSavedScopeProviderFallsBackOnlyWhenUnavailable() async throws {
        let (viewModel, store) = try await makeRoutingViewModel(backend: ComposerRoutingBackend(outcome: .selectLast))
        store.setModelRouterProvider(.codexExec, scope: .primarySession)
        store.setModelRouterProvider(.claudeCode, scope: .subagent)
        let configuration = store.modelRouterConfiguration()
        for scope in [AgentTaskRoutingScope.primarySession, .subagent] {
            let preferred: AgentProviderKind = scope == .primarySession ? .codexExec : .claudeCode
            XCTAssertEqual(AgentTaskRoutingCandidateBuilder.providers(
                for: scope, configuration: configuration, availability: viewModel.modelRouterAvailabilityContext
            ), [preferred])
            let fallback: AgentProviderKind = preferred == .codexExec ? .claudeCode : .codexExec
            let availability = AgentModelCatalog.AvailabilityContext(
                claudeCodeAvailable: fallback == .claudeCode, codexAvailable: fallback == .codexExec, openCodeAvailable: false
            )
            XCTAssertEqual(AgentTaskRoutingCandidateBuilder.providers(
                for: scope, configuration: configuration, availability: availability, surface: .headless
            ), [fallback])
            XCTAssertTrue(AgentTaskRoutingCandidateBuilder.providers(
                for: scope, configuration: configuration, availability: .none, surface: .headless
            ).isEmpty)
        }
    }

    func testAutoEffortFallbackKeepsManualComposerControlsForBothProviders() async throws {
        let defaults = UserDefaults.standard
        let keys = ["claudeCodeEffortLevel", "claudeCodeEffortLevelsByModelSlug"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for unavailable in [false, true] {
            let backend = ComposerRoutingBackend(
                outcome: .selectLast,
                readiness: unavailable ? .needsConfiguration(generation: 1, reason: "No key") : .ready(generation: 1, policyVersion: "fake-v1")
            )
            let (viewModel, store) = try await makeRoutingViewModel(backend: backend)
            store.setModelRouterEnabled(unavailable)
            store.setAutoEffortBackend(backend.id)
            store.setAutoEffortEnabled(true)
            await viewModel.modelRouterRuntime?.reconcileDemand()
            for provider in [AgentProviderKind.codexExec, .claudeCode] {
                let tabID = UUID()
                viewModel.test_setCurrentTabIDOverride(tabID)
                let session = viewModel.session(for: tabID)
                session.selectedAgent = provider
                session.selectedModelRaw = provider == .codexExec ? "gpt-6.1-sol-high" : "claude-opus-5-5"
                if !unavailable {
                    session.selectedWorkflow = AgentWorkflowDefinition(customID: UUID(), displayName: "Custom workflow", template: "$ARGUMENTS")
                } else {
                    session.hasSentFirstMessage = true
                }
                viewModel.updateBindingsFromSession(session)
                let props = viewModel.makeComposerProps(tabID: tabID)
                XCTAssertEqual(props.autoEffortServiceName, backend.displayName)
                XCTAssertFalse(props.areModelControlsDisabled)
                XCTAssertEqual(props.manualEffortControl, provider == .codexExec ? .codex : .claude)

                if provider == .codexExec { viewModel.selectReasoningEffort(.low) }
                else { viewModel.setClaudeEffortLevel(.low) }
                let updated = viewModel.makeComposerProps(tabID: tabID)
                if provider == .codexExec { XCTAssertEqual(updated.selectedReasoningEffortRaw, "low") }
                else { XCTAssertEqual(updated.providerControls?.claudeTools?.effortLevel, .low) }
                XCTAssertTrue(store.autoEffortEnabled(), "Choosing a fallback must not disable global Auto Effort")
                session.saveDebounceTask?.cancel()
            }
        }
    }

    func testGlobalRouterOwnsFreshTaskModelPresentationUntilDisabled() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast, id: .jev, displayName: "Jev")
        let decisions = ComposerRoutingBackend(outcome: .selectLast, id: .openAIDecisions, displayName: "Decisions by OpenAI")
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend, otherBackends: [decisions])
        await viewModel.modelRouterRuntime?.reconcileDemand()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = AgentModel.claudeHaiku.rawValue

        let routedProps = viewModel.makeComposerProps(tabID: tabID)
        XCTAssertTrue(routedProps.isGlobalModelRouterControllingFreshTask)
        XCTAssertTrue(routedProps.areModelControlsDisabled)
        XCTAssertEqual(routedProps.automaticRouterServiceName, "Jev")
        XCTAssertNil(routedProps.autoEffortServiceName)
        XCTAssertNil(routedProps.manualEffortControl, "Router still owns the initial model and effort")
        XCTAssertEqual(session.selectedAgent, .claudeCode)
        XCTAssertEqual(session.selectedModelRaw, AgentModel.claudeHaiku.rawValue)

        let namePublished = expectation(description: "Composer shows the newly selected routing service")
        let observation = viewModel.ui.composer.$props
            .filter { $0.automaticRouterServiceName == "Decisions by OpenAI" }
            .prefix(1)
            .sink { _ in namePublished.fulfill() }
        store.setModelRouterBackend(.openAIDecisions)
        await viewModel.modelRouterRuntime?.reconcileDemand()
        await fulfillment(of: [namePublished], timeout: 5)
        withExtendedLifetime(observation) {}
        let decisionsProps = viewModel.ui.composer.props
        XCTAssertTrue(decisionsProps.isGlobalModelRouterControllingFreshTask)
        XCTAssertEqual(decisionsProps.automaticRouterServiceName, "Decisions by OpenAI")

        store.setAutoEffortEnabled(true)
        XCTAssertEqual(viewModel.makeComposerProps(tabID: tabID).autoEffortServiceName, "Jev")
        store.setAutoEffortBackend(.openAIDecisions)
        XCTAssertEqual(viewModel.makeComposerProps(tabID: tabID).autoEffortServiceName, "Decisions by OpenAI")
        store.setAutoEffortEnabled(false)
        XCTAssertNil(viewModel.makeComposerProps(tabID: tabID).autoEffortServiceName)

        store.setModelRouterEnabled(false)

        let manualProps = viewModel.makeComposerProps(tabID: tabID)
        XCTAssertFalse(manualProps.isGlobalModelRouterControllingFreshTask)
        XCTAssertFalse(manualProps.areModelControlsDisabled)
        XCTAssertNil(manualProps.automaticRouterServiceName)
        XCTAssertEqual(session.selectedModelRaw, AgentModel.claudeHaiku.rawValue)
    }

    func testGlobalRouterOwnsFreshTaskWithSelectedPromptWorkflow() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast)
        let (viewModel, _) = try await makeRoutingViewModel(backend: backend)
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
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend)
        XCTAssertTrue(store.modelRouterConfiguration().enabled)

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
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend)
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
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend)

        let routed = try await viewModel.routeSubagentTargetIfEnabled(task: "Explore the parser", surface: .general)
        XCTAssertNil(routed)
        XCTAssertTrue(store.modelRouterConfiguration().enabled)
    }

    func testFakeReadyRouterCommitsSelectedExecutableTargetAtSubmitBoundary() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast)
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend)
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
        XCTAssertNil(viewModel.modelRouterPillProps().routedModelDisplayName)

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
        XCTAssertEqual(
            viewModel.ui.statusPills.snapshot.modelRouter.routedModelDisplayName,
            "\(viewModel.selectedModelDisplayName) \(ClaudeCodeEffortLevel.parse(session.selectedClaudeEffortRaw)?.displayName ?? String())"
        )

        // Claude keeps its manual effort separately from the Codex-oriented selection field.
        session.selectedReasoningEffortRaw = nil
        session.selectedClaudeEffortRaw = ClaudeCodeEffortLevel.high.rawValue
        viewModel.syncStatusPillsUIState()
        XCTAssertEqual(
            viewModel.ui.statusPills.snapshot.modelRouter.routedModelDisplayName,
            "\(viewModel.selectedModelDisplayName) High"
        )

        viewModel.selectedModelRaw = baseline.modelRaw
        XCTAssertEqual(session.selectedModelRaw, baseline.modelRaw)
        XCTAssertNil(viewModel.ui.statusPills.snapshot.modelRouter.routedModelDisplayName)
        viewModel.selectedModelRaw = selected.modelRaw
        XCTAssertEqual(
            viewModel.ui.statusPills.snapshot.modelRouter.routedModelDisplayName,
            "\(viewModel.selectedModelDisplayName) \(ClaudeCodeEffortLevel.parse(session.selectedClaudeEffortRaw)?.displayName ?? String())"
        )
        session.appendAutomationAudit(AgentAutomationTurnAudit(
            turnID: UUID(),
            createdAt: Date(),
            router: .init(configured: true, eligible: true, judgmentRequested: true, decision: .fallback),
            autoEffort: .init(configured: false, eligible: false, judgmentRequested: false, decision: .disabled),
            acceptedProviderRaw: session.selectedAgent.rawValue,
            acceptedModelRaw: session.selectedModelRaw,
            acceptedEffortRaw: session.selectedReasoningEffortRaw
        ))
        viewModel.syncStatusPillsUIState()
        XCTAssertNil(viewModel.ui.statusPills.snapshot.modelRouter.routedModelDisplayName)
    }

    func testCodexEffortSelectionRefreshesRoutedModelPillWithoutManualSync() async throws {
        let (viewModel, store) = try await makeRoutingViewModel(backend: ComposerRoutingBackend(outcome: .selectLast))
        store.setAutoEffortEnabled(false)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        viewModel.selectedAgent = .codexExec
        viewModel.selectedModelRaw = "gpt-6.1-sol"
        viewModel.selectReasoningEffort(.high)
        session.appendAutomationAudit(AgentAutomationTurnAudit(
            turnID: UUID(),
            createdAt: Date(),
            router: .init(
                configured: true, eligible: true, judgmentRequested: true, decision: .selected,
                chosenModelRaw: session.selectedModelRaw, chosenEffortRaw: "high"
            ),
            autoEffort: .init(configured: false, eligible: false, judgmentRequested: false, decision: .disabled),
            acceptedProviderRaw: session.selectedAgent.rawValue,
            acceptedModelRaw: session.selectedModelRaw,
            acceptedEffortRaw: "high"
        ))
        viewModel.syncStatusPillsUIState()
        XCTAssertEqual(
            viewModel.ui.statusPills.snapshot.modelRouter.routedModelDisplayName,
            "\(viewModel.selectedModelDisplayName) High"
        )

        // Exercise the same action as the effort picker, without manually publishing status pills.
        viewModel.selectReasoningEffort(.low)
        XCTAssertEqual(session.selectedReasoningEffortRaw, "low")
        XCTAssertEqual(
            viewModel.ui.statusPills.snapshot.modelRouter.routedModelDisplayName,
            "\(viewModel.selectedModelDisplayName) Low"
        )

        store.setAutoEffortEnabled(true)
        viewModel.selectReasoningEffort(.high)
        XCTAssertEqual(
            viewModel.ui.statusPills.snapshot.modelRouter.routedModelDisplayName,
            viewModel.selectedModelDisplayName,
            "Auto Effort hides the manual fallback effort"
        )
        store.setAutoEffortEnabled(false)
        viewModel.selectReasoningEffort(.low)
        XCTAssertEqual(
            viewModel.ui.statusPills.snapshot.modelRouter.routedModelDisplayName,
            "\(viewModel.selectedModelDisplayName) Low"
        )
    }

    func testFakeRouterAbstentionSubmitsWithCurrentSelection() async throws {
        let backend = ComposerRoutingBackend(outcome: .abstain)
        let (viewModel, _) = try await makeRoutingViewModel(backend: backend)
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
        XCTAssertNil(viewModel.modelRouterPillProps().routedModelDisplayName)
    }

    func testLongComposerTaskStillRoutesOnMaskedExcerpt() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast)
        let (viewModel, _) = try await makeRoutingViewModel(backend: backend)
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
        XCTAssertEqual(requests.map(\.question.name), ["model_route", "effort_route"])
        XCTAssertEqual(requests.first?.textContext, requests.last?.textContext)
        XCTAssertTrue(requests.allSatisfy { $0.textContext.contains("Implement a parser") })
        XCTAssertTrue(requests.allSatisfy { $0.textContext.contains("add regression tests") })
        XCTAssertTrue(requests.allSatisfy { !$0.textContext.contains("private123") && !$0.textContext.contains("lastsecret") })
        XCTAssertTrue(requests.allSatisfy { $0.textContext.count <= AgentTaskRoutingTaskExcerpt.maximumCharacters })
        XCTAssertEqual(session.transcript.turns.first?.request?.text, text)
    }

    func testLongSubagentTaskStillRoutesOnBoundedExcerpt() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast)
        let (viewModel, _) = try await makeRoutingViewModel(backend: backend)
        let task = "Investigate a concurrency bug. "
            + String(repeating: "background context ", count: 300)
            + " Finally, review the cancellation path."

        let selected = try await viewModel.routeSubagentTargetIfEnabled(task: task, surface: .general)

        XCTAssertNotNil(selected)
        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.question.name), ["model_route", "effort_route"])
        XCTAssertTrue(requests.allSatisfy { $0.question.instructions.contains("delegated subagent session") })
        XCTAssertTrue(requests.allSatisfy { $0.textContext.contains("concurrency bug") })
        XCTAssertTrue(requests.allSatisfy { $0.textContext.contains("cancellation path") })
        XCTAssertTrue(requests.allSatisfy { $0.textContext != task })
    }

    func testEffortAbstentionKeepsJevSelectedModelWithProviderDefaultEffort() async throws {
        let backend = ComposerRoutingBackend(outcome: .abstainEffort)
        let (viewModel, _) = try await makeRoutingViewModel(backend: backend)

        let selected = try await viewModel.routeSubagentTargetIfEnabled(
            task: "Implement parser and tests", surface: .general
        )

        XCTAssertNotNil(selected)
        XCTAssertNil(selected?.reasoningEffortRaw)
        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.question.name), ["model_route", "effort_route"])
    }

    func testModelAbstentionLeavesSubagentRoleDefaultInControl() async throws {
        let backend = ComposerRoutingBackend(outcome: .abstain)
        let (viewModel, _) = try await makeRoutingViewModel(backend: backend)
        let selected = try await viewModel.routeSubagentTargetIfEnabled(
            task: "Implement parser and tests", surface: .general
        )
        XCTAssertNil(selected)
    }

    func testGlobalRouterRoutesSubagentRequestWithScopeGuidanceAndTargetIdentity() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast)
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend)
        XCTAssertTrue(store.setModelRouterCustomInstructions("Prefer Claude Opus for execution."))

        let selected = try await viewModel.routeSubagentTargetIfEnabled(
            task: "Implement the parser and tests",
            surface: .general
        )

        XCTAssertNotNil(selected)
        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.question.name), ["model_route", "effort_route"])
        XCTAssertTrue(requests.allSatisfy { $0.question.instructions.contains("delegated subagent session") })
        XCTAssertTrue(requests.allSatisfy { $0.textContext.contains("HIGHEST-PRIORITY USER ROUTING DIRECTIVE:\nPrefer Claude Opus for execution.") })
        XCTAssertTrue(requests.allSatisfy { $0.textContext.contains("Implement the parser and tests") })
        XCTAssertTrue(requests.allSatisfy { $0.question.choices.allSatisfy { !$0.description.isEmpty } })
    }

    func testRoutingFixtureWaitsForDelayedInitialReadiness() async throws {
        let readinessGate = TestReleaseFence(name: "composer initial readiness")
        let backend = StagedCancellationRoutingBackend(readinessGate: readinessGate)
        var fixtureReady = false
        let setupTask = Task { @MainActor in
            _ = try await makeRoutingViewModel(backend: backend)
            fixtureReady = true
        }
        defer {
            readinessGate.release()
            setupTask.cancel()
        }
        guard await readinessGate.waitUntilEntered(timeout: 5) else { return }
        XCTAssertFalse(fixtureReady, "Fixture must not permit routing before readiness publication")
        readinessGate.release()
        try await AsyncTestWait.waitUntil("composer fixture ready after publication", timeout: 5) {
            fixtureReady
        }
        try await setupTask.value
        let requestCount = await backend.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testCancellationAfterModelSelectionDoesNotStartEffortRouting() async throws {
        let backend = StagedCancellationRoutingBackend()
        let (viewModel, _) = try await makeRoutingViewModel(backend: backend)
        var routingResult: Result<AgentRoutingExecutableTarget?, Error>?
        let routingTask = Task { @MainActor in
            do {
                let target = try await viewModel.routeSubagentTargetIfEnabled(
                    task: "Review the concurrency boundary",
                    surface: .general
                )
                routingResult = .success(target)
            } catch {
                routingResult = .failure(error)
            }
        }
        defer {
            routingTask.cancel()
            Task { await backend.cancelPendingStage() }
        }
        try await AsyncTestWait.waitUntil("cancellation test model stage started", timeout: 5) {
            await backend.requestCount == 1
        }

        routingTask.cancel()
        await backend.completeFirstStageSelection()

        try await AsyncTestWait.waitUntil("cancelled routing task completed", timeout: 5) {
            routingResult != nil
        }
        do {
            _ = try XCTUnwrap(routingResult).get()
            XCTFail("Cancelled routing must not produce a target")
        } catch AgentModeViewModel.GlobalModelRoutingError.cancelled {
            // Expected.
        }
        let requestCount = await backend.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testNewDestinationOwnsVisibleCancelAndRejectsSecondSubmit() async throws {
        let backend = SuspendedComposerRoutingBackend()
        let (viewModel, _) = try await makeRoutingViewModel(backend: backend)
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

    func testUsageBalancingRoutesFreshComposerAndSubagentWithoutJev() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast, readiness: .needsConfiguration(generation: 1, reason: "No key"))
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend)
        await viewModel.modelRouterRuntime?.reconcileDemand()
        store.setModelRouterEnabled(false)
        store.setModelRouterProvider(nil, scope: .primarySession)
        store.setUsageBalancingEnabled(true)
        XCTAssertTrue(store.setModelRouterCustomInstructions("Prefer Claude for execution"))
        let advisor = AgentUsageBalancer()
        viewModel.modelRouterRuntime?.usageBalancer = advisor
        let now = Date(), reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(18000))
        for (provider, used) in [(AgentProviderKind.codexExec, 95), (.claudeCode, 10)] {
            let value = try ClaudeAccountUsageMapper.snapshot(data: Data("{\"five_hour\":{\"utilization\":\(used),\"resets_at\":\"\(reset)\"}}".utf8), account: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: "test"), observedAt: now)
            advisor.update(value, provider: provider.rawValue)
        }
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-6.1-sol-high"
        let baseline = viewModel.executableTarget(for: session)
        let peer = try XCTUnwrap(viewModel.localUsageDecision(basedOn: baseline, scope: .primarySession, surface: .general))
        XCTAssertEqual(peer.candidate.target.agentRaw, AgentProviderKind.claudeCode.rawValue)
        XCTAssertTrue(viewModel.makeStatusPillsSnapshot().modelRouter.usageBalancing)
        XCTAssertFalse(viewModel.makeComposerProps(tabID: tabID).areModelControlsDisabled)
        let subagent = try await viewModel.routeSubagentTargetIfEnabled(task: "Implement parser", surface: .headless, baseline: baseline)
        XCTAssertEqual(subagent?.agentRaw, AgentProviderKind.claudeCode.rawValue)
        let pinned = try await viewModel.routeSubagentTargetIfEnabled(task: "Implement parser", surface: .headless, baseline: baseline, allowUsageBalance: false)
        XCTAssertNil(pinned)
        store.setModelRouterEnabled(true) // Configured but unavailable Jev must remain visible in the audit.
        let claim = try routingClaim(viewModel: viewModel, session: session, text: "Implement parser")
        let result = await viewModel.submitUserTurnAfterFreshTaskRouting(text: "Implement parser", claim: claim, session: session, destinationTabID: tabID)
        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(session.selectedAgent, .claudeCode)
        let audit = try XCTUnwrap(session.automationTurnAudit.last?.router)
        XCTAssertTrue(audit.configured)
        XCTAssertEqual(audit.decision, .unavailable)
        XCTAssertFalse(audit.judgmentRequested)
        XCTAssertNotNil(audit.usageBalancingReason)
        XCTAssertEqual(audit.usageBalancingProviderRaw, AgentProviderKind.claudeCode.rawValue)
        XCTAssertFalse(AgentTaskRoutingCandidateBuilder.isPaidFast(viewModel.executableTarget(for: session)))
        XCTAssertFalse(viewModel.freshTaskRoutingEligibility(session: session, text: "Follow up"))
        store.setUsageBalancingEnabled(false)
        XCTAssertNil(viewModel.localUsageDecision(basedOn: baseline, scope: .primarySession, surface: .general), "Disabled balancing keeps the starting model")
        let requests = await backend.requests
        XCTAssertTrue(requests.isEmpty, "Independent balancing must not request Jev or require a credential")
    }

    func testUsageBalancingKeepsSavedProviderForPrimaryAndSubagent() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast, readiness: .needsConfiguration(generation: 1, reason: "No key"))
        let controller = ComposerRoutingCodexController()
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend, codexController: controller)
        store.setModelRouterProvider(.codexExec, scope: .primarySession)
        store.setModelRouterProvider(.codexExec, scope: .subagent)
        store.setUsageBalancingEnabled(true)
        let advisor = AgentUsageBalancer()
        viewModel.modelRouterRuntime?.usageBalancer = advisor
        let now = Date(), reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(18000))
        for (provider, used) in [(AgentProviderKind.codexExec, 95), (.claudeCode, 10)] {
            let value = try ClaudeAccountUsageMapper.snapshot(data: Data("{\"five_hour\":{\"utilization\":\(used),\"resets_at\":\"\(reset)\"}}".utf8), account: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: "test"), observedAt: now)
            advisor.update(value, provider: provider.rawValue)
        }
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-6.1-sol-high"
        _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session))
        session.hasLoadedPersistedState = true
        // An installed binding admits operations only after restoration is authoritative (#1363).
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        let baseline = viewModel.executableTarget(for: session)
        XCTAssertNil(viewModel.localUsageDecision(basedOn: baseline, scope: .primarySession, surface: .general))
        let child = try await viewModel.routeSubagentTargetIfEnabled(task: "Implement parser", surface: .headless, baseline: baseline)
        XCTAssertNil(child)
        store.setModelRouterProvider(nil, scope: .subagent)
        let unrestrictedChild = try await viewModel.routeSubagentTargetIfEnabled(task: "Implement parser", surface: .headless, baseline: baseline)
        XCTAssertEqual(unrestrictedChild?.agentRaw, "claudeCode", "Clearing the child preference must not clear the primary preference")
        let claim = try routingClaim(viewModel: viewModel, session: session, text: "Implement parser")
        let result = await viewModel.submitUserTurnAfterFreshTaskRouting(text: "Implement parser", claim: claim, session: session, destinationTabID: tabID)
        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(session.selectedAgent, .codexExec)
        XCTAssertNil(session.automationTurnAudit.last?.router.usageBalancingReason)
        try await AsyncTestWait.waitUntil("manual Codex turn dispatched or rejected", timeout: 5) {
            !controller.submittedModels.isEmpty || session.items.contains { $0.kind == .error }
        }
        XCTAssertEqual(controller.submittedModels, ["gpt-6.1-sol"], session.items.map(\.text).joined(separator: "\n"))
        let requests = await backend.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUsageBalancedAuditCannotDispatchAfterModelOrProviderChange() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast, readiness: .needsConfiguration(generation: 1, reason: "No key"))
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend)
        await viewModel.modelRouterRuntime?.reconcileDemand()
        store.setModelRouterEnabled(false)
        store.setModelRouterProvider(nil, scope: .primarySession)
        store.setUsageBalancingEnabled(true)
        store.setAutoEffortEnabled(true)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-6.1-sol-high"
        let claim = try routingClaim(viewModel: viewModel, session: session, text: "Implement parser")
        let staleAudit = AgentAutomationTurnAudit.Feature(
            configured: false,
            eligible: true,
            judgmentRequested: false,
            decision: .selected,
            chosenModelRaw: "claude-opus-5-5-high",
            usageBalancingReason: "usage_balance_evenPace",
            usageBalancingProviderRaw: "claudeCode"
        )
        let result = await viewModel.submitUserTurnAfterAutoEffort(text: "Implement parser", claim: claim, session: session, destinationTabID: tabID, routerAudit: staleAudit)
        guard case .blocked = result else { return XCTFail("A changed balancing target must never silently dispatch") }
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertTrue(session.automationTurnAudit.isEmpty)
        XCTAssertEqual(session.selectedAgent, .codexExec)
        let baseline = viewModel.executableTarget(for: session)
        session.selectedAgent = .claudeCode
        viewModel.restoreUsageStartingTarget(baseline, on: session)
        XCTAssertEqual(viewModel.executableTarget(for: session), baseline)
    }

    func testLocalInputOnlyComposerClaimGivesRetainedQueuedRowPositiveOrigin() async throws {
        let (viewModel, _) = try await makeRoutingViewModel(backend: ComposerRoutingBackend(outcome: .abstain))
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session)
        session.hasLoadedPersistedState = true
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        session.installLocalInputSeed(.init())
        session.selectedAgent = .claudeCode
        session.installRunID(UUID())
        session.runState = .running
        session.isMCPInstructionDispatchInProgress = true // fake retained interrupt owner, no transport
        let claim = try routingClaim(viewModel: viewModel, session: session, text: "Research only; do not edit.")
        defer { viewModel.releaseComposerSubmitClaim(claim) }
        let result = await viewModel.submitUserTurnAfterAutoEffort(text: "Research only; do not edit.", claim: claim, session: session, destinationTabID: tabID)
        XCTAssertEqual(result, .submitted)
        let composerRow = try XCTUnwrap(session.items.last(where: { $0.kind == .user }))
        XCTAssertEqual(composerRow.userInputOrigin, .localComposer)
        XCTAssertEqual(session.pendingClaudeSteeringInstructions.count, 1)
        XCTAssertEqual(session.test_unsettledLocalComposerCandidateCount, 0)
        // Legacy shared default is deliberately still true for unrelated admission policy. It is
        // not proof of authorship: MCP/API callers never supply the positive composer token.
        XCTAssertEqual(viewModel.submitUserTurn(text: "MCP-origin instruction", tabID: tabID), .submitted)
        XCTAssertNil(session.items.last(where: { $0.kind == .user })?.userInputOrigin)
        session.agentTask?.cancel()
        session.saveDebounceTask?.cancel()
        session.derivedTranscriptRefreshTask?.cancel()
    }

    /// The queued-interrupt settle must outlive reply finalization: when `endActiveAssistantSegment`
    /// runs its flag-only batch after the input settled, the retained record stays offerable.
    func testLocalComposerQueuedInterruptOriginSurvivesReplyFinalizationBatch() async throws {
        let (viewModel, _) = try await makeRoutingViewModel(backend: ComposerRoutingBackend(outcome: .abstain))
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session)
        session.hasLoadedPersistedState = true
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        session.installLocalInputSeed(.init())
        session.selectedAgent = .claudeCode
        session.installRunID(UUID())
        session.runState = .running
        session.isMCPInstructionDispatchInProgress = true // fake retained interrupt owner, no transport
        let claim = try routingClaim(viewModel: viewModel, session: session, text: "W1")
        defer { viewModel.releaseComposerSubmitClaim(claim) }
        let result = await viewModel.submitUserTurnAfterAutoEffort(text: "W1", claim: claim, session: session, destinationTabID: tabID)
        XCTAssertEqual(result, .submitted)

        let composerRow = try XCTUnwrap(session.items.last(where: { $0.kind == .user }))
        XCTAssertEqual(composerRow.userInputOrigin, .localComposer)
        XCTAssertTrue(session.localInputIndex.records.contains { $0.itemID == composerRow.id })
        let epoch = session.localInputIndex.epoch
        let producedThrough = session.localInputIndex.producedThrough

        // The reply arrives and streams; its finalization touches no tracked membership or content.
        var reply = AgentChatItem.assistant("W1 sent", sequenceIndex: session.nextSequenceIndex)
        reply.isStreaming = true
        session.appendItem(reply)
        viewModel.endActiveAssistantSegment(session)

        XCTAssertEqual(
            session.localInputIndex.epoch,
            epoch,
            "flag-only reply finalization must not rotate the local-input epoch"
        )
        XCTAssertEqual(session.localInputIndex.producedThrough, producedThrough)
        let snapshot = try XCTUnwrap(session.localInputIndex.snapshot)
        XCTAssertTrue(snapshot.records.contains { $0.itemID == composerRow.id && $0.content?.text != nil })

        session.agentTask?.cancel()
        session.saveDebounceTask?.cancel()
        session.derivedTranscriptRefreshTask?.cancel()
    }

    func testDecisionsAdapterStagesPrimaryAndSubagentThroughSameBackend() async throws {
        for primary in [false, true] {
            let client = ComposerDecisionsClient()
            let credentials = OpenAIDecisionsRouterCredentialService(secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()), decide: { try await client.judge($0, key: $1) })
            let saved = await credentials.validateAndSave("synthetic-test-key", operationID: UUID())
            guard case .saved = saved else { return XCTFail("Synthetic validation failed") }
            let jev = ComposerRoutingBackend(outcome: .selectLast, id: .jev)
            let (viewModel, store) = try await makeRoutingViewModel(backend: OpenAIDecisionsDecisionService(credentialService: credentials), otherBackends: [jev])
            await viewModel.modelRouterRuntime?.reconcileDemand()
            store.setModelRouterCustomInstructions("Prefer reliable choices")
            // This test exercises the two-stage service transaction, not provider ordering.
            // Keep the primary send on the fixture's non-Codex execution path.
            store.setModelRouterProvider(.claudeCode, scope: .primarySession)
            store.setModelRouterProvider(.claudeCode, scope: .subagent)
            await viewModel.modelRouterRuntime?.reconcileDemand()
            let text = "Implement parser and tests"
            if primary {
                let tabID = UUID()
                viewModel.test_setCurrentTabIDOverride(tabID)
                let session = viewModel.session(for: tabID)
                let claim = try routingClaim(viewModel: viewModel, session: session, text: text)
                let result = await viewModel.submitUserTurnAfterFreshTaskRouting(text: text, claim: claim, session: session, destinationTabID: tabID)
                XCTAssertEqual(result, .submitted)
            } else {
                let selected = try await viewModel.routeSubagentTargetIfEnabled(task: text, surface: .general)
                XCTAssertNotNil(selected)
            }
            let requests = await client.requests.filter { $0.questions[0].name != "credential_access" }
            XCTAssertEqual(requests.map { $0.questions[0].name }, ["model_route", "effort_route"])
            XCTAssertEqual(requests.first?.input, requests.last?.input)
            XCTAssertTrue(requests.allSatisfy { $0.input == "HIGHEST-PRIORITY USER ROUTING DIRECTIVE:\nPrefer reliable choices\n\nTASK:\n\(text)" })
            let jevRequests = await jev.requests
            XCTAssertTrue(jevRequests.isEmpty)
            await viewModel.modelRouterRuntime?.teardown()
        }
    }

    func testDecisionsStageFallbacksDoNotUseOtherBackendOrInvalidateKey() async throws {
        for failureStage in ["model_route", "effort_route"] {
            let client = ComposerDecisionsClient(failureStage: failureStage)
            let credentials = OpenAIDecisionsRouterCredentialService(secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()), decide: { try await client.judge($0, key: $1) })
            _ = await credentials.validateAndSave("synthetic-test-key", operationID: UUID())
            let before = await credentials.readinessSnapshot()
            let jev = ComposerRoutingBackend(outcome: .selectLast, id: .jev)
            let (viewModel, _) = try await makeRoutingViewModel(backend: OpenAIDecisionsDecisionService(credentialService: credentials), otherBackends: [jev])
            await viewModel.modelRouterRuntime?.reconcileDemand()
            let selected = try await viewModel.routeSubagentTargetIfEnabled(task: "Implement parser", surface: .general)
            if failureStage == "model_route" { XCTAssertNil(selected) }
            else { XCTAssertNotNil(selected)
                XCTAssertNil(selected?.reasoningEffortRaw)
            }
            let after = await credentials.readinessSnapshot()
            XCTAssertEqual(after, before)
            let jevRequests = await jev.requests
            XCTAssertTrue(jevRequests.isEmpty)
            await viewModel.modelRouterRuntime?.teardown()
        }
    }

    func testDecisionsRejectedSubmissionRestoresCompleteNormalizedTarget() async throws {
        let client = ComposerDecisionsClient(selectCodexModel: true)
        let credentials = OpenAIDecisionsRouterCredentialService(secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()), decide: { try await client.judge($0, key: $1) })
        _ = await credentials.validateAndSave("synthetic-test-key", operationID: UUID())
        let (viewModel, store) = try await makeRoutingViewModel(backend: OpenAIDecisionsDecisionService(credentialService: credentials))
        store.setModelRouterProvider(.codexExec, scope: .primarySession)
        await viewModel.modelRouterRuntime?.reconcileDemand()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = AgentModel.claudeSonnet.rawValue
        session.selectedReasoningEffortRaw = "high"
        session.acpModelParameterSelections = [
            .init(providerID: .openCode, baseModelRaw: "fixture", kind: .speed, configID: "tier", valueRaw: "fast"),
            .init(providerID: .openCode, baseModelRaw: "fixture", kind: .thinking, configID: "effort", valueRaw: "low")
        ]
        let baseline = AgentRoutingExecutableTarget(agentRaw: session.selectedAgent.rawValue, modelRaw: session.selectedModelRaw, reasoningEffortRaw: session.selectedReasoningEffortRaw, modelParameters: session.acpModelParameterSelections)
        let text = "Implement parser and tests"
        let claim = try routingClaim(viewModel: viewModel, session: session, text: text)
        // A local in-process provider-send fence rejects only after routing applies Codex.
        let token = CodexManagedSessionFence.shared.beginLogout()
        defer { CodexManagedSessionFence.shared.finishLogout(token: token, succeeded: false) }
        let result = await viewModel.submitUserTurnAfterFreshTaskRouting(text: text, claim: claim, session: session, destinationTabID: tabID)
        XCTAssertEqual(result, .blocked(message: CodexManagedSessionFence.blockedMessage))
        let restored = AgentRoutingExecutableTarget(agentRaw: session.selectedAgent.rawValue, modelRaw: session.selectedModelRaw, reasoningEffortRaw: session.selectedReasoningEffortRaw, modelParameters: session.acpModelParameterSelections)
        XCTAssertEqual(restored, baseline)
        XCTAssertTrue(session.transcript.turns.isEmpty)
        await viewModel.modelRouterRuntime?.teardown()
    }

    func testCancelledEffortAfterUsageBalancingDoesNotReturnFallbackTarget() async throws {
        let backend = ComposerRoutingBackend(outcome: .cancelEffort)
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend)
        store.setUsageBalancingEnabled(true)
        let advisor = AgentUsageBalancer()
        viewModel.modelRouterRuntime?.usageBalancer = advisor
        let now = Date()
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(18000))
        for (provider, used) in [(AgentProviderKind.claudeCode, 95), (.codexExec, 10)] {
            let data = try JSONSerialization.data(withJSONObject: ["five_hour": ["utilization": used, "resets_at": reset]])
            let usage = try ClaudeAccountUsageMapper.snapshot(
                data: data,
                account: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: "test"),
                observedAt: now
            )
            advisor.update(usage, provider: provider.rawValue)
        }
        do {
            _ = try await viewModel.routeSubagentTargetIfEnabled(task: "Implement parser", surface: .headless)
            XCTFail("Cancellation must not return the usage-balanced model fallback")
        } catch AgentModeViewModel.GlobalModelRoutingError.cancelled {
            // Expected: a cancelled effort stage must not submit the substituted model.
        }
        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.question.name), ["model_route", "effort_route"])
        XCTAssertTrue(
            requests.last?.question.choices.allSatisfy { $0.description.hasPrefix("Provider: codexExec;") } == true,
            "The effort stage must have received the substituted Codex peer"
        )
    }

    func testCriticalUsageOverrideMovesFreshTaskToClaudeWithUnknownCodexAndNoJev() async throws {
        let backend = ComposerRoutingBackend(outcome: .selectLast, readiness: .needsConfiguration(generation: 1, reason: "No key"))
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend)
        store.setModelRouterProvider(nil, scope: .primarySession)
        store.setUsageBalancingEnabled(true)
        store.setUsageBalancingOverride(true)
        let advisor = AgentUsageBalancer()
        viewModel.modelRouterRuntime?.usageBalancer = advisor
        let now = Date()
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(37 * 3600))
        let claude = try ClaudeAccountUsageMapper.snapshot(
            data: JSONSerialization.data(withJSONObject: ["seven_day": ["utilization": 32, "resets_at": reset]]),
            account: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: "test"),
            observedAt: now
        )
        advisor.update(claude, provider: AgentProviderKind.claudeCode.rawValue)
        advisor.update(nil, provider: AgentProviderKind.codexExec.rawValue)
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-6.1-sol-high"
        let decision = try XCTUnwrap(viewModel.localUsageDecision(basedOn: viewModel.executableTarget(for: session), scope: .primarySession, surface: .general))
        XCTAssertEqual(decision.candidate.target.agentRaw, AgentProviderKind.claudeCode.rawValue)
        XCTAssertEqual(decision.reason, "usage_override_expiring")
        XCTAssertTrue(AgentUsageBalancer.mainSessionPeerClasses.contains(decision.candidate.usagePeerClass ?? ""), "The main session never drops to Haiku or Sonnet")
        let configuration = store.modelRouterConfiguration()
        let models = try AgentTaskRoutingCandidateBuilder().build(allowedProviders: [.claudeCode, .codexExec], availability: viewModel.modelRouterAvailabilityContext)
        let primary = try XCTUnwrap(advisor.routerOverride(candidates: models, configuration: configuration, scope: .primarySession))
        XCTAssertTrue(primary.candidates.allSatisfy {
            $0.target.agentRaw == AgentProviderKind.claudeCode.rawValue && AgentUsageBalancer.mainSessionPeerClasses.contains($0.usagePeerClass ?? "")
        })
        let subagent = try XCTUnwrap(advisor.routerOverride(candidates: models, configuration: configuration, scope: .subagent))
        XCTAssertGreaterThanOrEqual(subagent.candidates.count, primary.candidates.count, "Subagents keep every Claude tier")
        XCTAssertTrue(viewModel.applyRoutingTarget(decision.candidate, to: session))
        let requests = await backend.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCriticalUsageOverrideNeverOffersTheOtherProviderToJev() async throws {
        let backend = ComposerRoutingBackend(outcome: .cancelEffort)
        let (viewModel, store) = try await makeRoutingViewModel(backend: backend)
        store.setUsageBalancingEnabled(true)
        store.setUsageBalancingOverride(true)
        let advisor = AgentUsageBalancer()
        viewModel.modelRouterRuntime?.usageBalancer = advisor
        let now = Date()
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(18000))
        for (provider, used) in [(AgentProviderKind.codexExec, 95), (.claudeCode, 10)] {
            let data = try JSONSerialization.data(withJSONObject: ["five_hour": ["utilization": used, "resets_at": reset]])
            let usage = try ClaudeAccountUsageMapper.snapshot(
                data: data,
                account: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: "test"),
                observedAt: now
            )
            advisor.update(usage, provider: provider.rawValue)
        }
        _ = try? await viewModel.routeSubagentTargetIfEnabled(task: "Implement parser", surface: .headless)
        let requests = await backend.requests
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(
            requests.flatMap(\.question.choices).allSatisfy { $0.description.hasPrefix("Provider: claudeCode;") },
            "Critical usage must not let Jev pick the other provider"
        )
        store.setUsageBalancingOverride(false)
        XCTAssertFalse(store.modelRouterConfiguration().usageBalancing.overridesRouter)
    }

    func testStaleRouterAndUsagePeerCandidatesCannotMutateSelection() async throws {
        let (viewModel, _) = try await makeRoutingViewModel(backend: ComposerRoutingBackend(outcome: .selectLast))
        let builder = AgentTaskRoutingCandidateBuilder()
        let snapshot = builder.capture(allowedProviders: [.claudeCode, .codexExec], availability: viewModel.modelRouterAvailabilityContext)
        let candidate = try XCTUnwrap(try builder.build(snapshot: snapshot).first)
        XCTAssertTrue(snapshot.contains(candidate.target))
        let session = viewModel.session(for: UUID())
        let before = viewModel.executableTarget(for: session)
        let staleCatalog = RoutingExecutionMetadataSnapshot.Scope(
            surface: snapshot.scope.surface,
            availability: snapshot.scope.availability,
            allowedProviders: snapshot.scope.allowedProviders,
            catalogRevision: snapshot.scope.catalogRevision + "-stale"
        )
        let staleAvailability = RoutingExecutionMetadataSnapshot.Scope(
            surface: snapshot.scope.surface,
            availability: .init(claudeCodeAvailable: false, codexAvailable: false, openCodeAvailable: false),
            allowedProviders: snapshot.scope.allowedProviders,
            catalogRevision: snapshot.scope.catalogRevision
        )
        for (scope, profile) in [(staleCatalog, candidate.profileIdentity), (staleAvailability, candidate.profileIdentity), (snapshot.scope, "stale-profile")] {
            let stale = AgentTaskRoutingCandidateBuilder.Candidate(
                opaqueKey: candidate.opaqueKey,
                utilityTier: candidate.utilityTier,
                target: candidate.target,
                descriptor: candidate.descriptor,
                snapshotScope: scope,
                profileIdentity: profile,
                usagePeerClass: candidate.usagePeerClass,
                usageModelAliases: candidate.usageModelAliases
            )
            XCTAssertFalse(viewModel.applyRoutingTarget(stale, to: session))
            XCTAssertEqual(viewModel.executableTarget(for: session), before)
        }
    }

    private func makeRoutingViewModel(
        backend: any DecisionService,
        otherBackends: [any DecisionService] = [],
        codexController: (any CodexSessionControlling)? = nil
    ) async throws -> (AgentModeViewModel, GlobalSettingsStore) {
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
        // Keep ordinary submissions on the fixture's non-Codex execution path;
        // tests covering a Codex preference supply a recording controller explicitly.
        store.setModelRouterProvider(.claudeCode, scope: .primarySession)
        let runtime = try AgentTaskRouterRuntime(registrations: [.init(service: backend)] + otherBackends.map { .init(service: $0) }, demandSource: store)
        addTeardownBlock { await runtime.teardown() }
        let viewModel = AgentModeViewModel(
            testWorkspacePath: root.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                if let codexController { return codexController }
                preconditionFailure("Routing transaction test must not start Codex")
            },
            headlessProviderFactory: { _, _ in UnsupportedHeadlessAgentProvider(reason: "test terminal") }
        )
        addTeardownBlock { @MainActor in
            for session in viewModel.sessions.values {
                await viewModel.test_codexCoordinator.shutdownCodexSession(session)
                session.saveDebounceTask?.cancel()
            }
        }
        viewModel.modelRouterSettingsStore = store
        viewModel.modelRouterRuntime = runtime
        await runtime.reconcileDemand()
        try await AsyncTestWait.waitUntil("composer fake router initial readiness", timeout: 5) {
            runtime.backendReadiness(backend.id) != nil
        }
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

/// Synthetic typed fixtures follow contract record Response mapping and acceptance.
private actor ComposerDecisionsClient {
    private(set) var requests: [OpenAIDecisionsWireRequest] = []
    private let failureStage: String?
    private let selectCodexModel: Bool
    init(failureStage: String? = nil, selectCodexModel: Bool = false) {
        self.failureStage = failureStage
        self.selectCodexModel = selectCodexModel
    }

    func judge(_ request: OpenAIDecisionsWireRequest, key: String) throws -> OpenAIDecisionsWireResponse {
        requests.append(request)
        let question = request.questions[0]
        if question.name == failureStage { throw OpenAIDecisionsRoutingClientError.policyUnavailable }
        let selected = if selectCodexModel, question.name == "model_route" {
            try XCTUnwrap(
                question.choices.first { $0.description?.hasPrefix("Provider: \(AgentProviderKind.codexExec.rawValue);") == true },
                "Router must offer an executable Codex model"
            ).value
        } else {
            question.choices.last!.value
        }
        return .init(model: OpenAIDecisionsRouterCredentialService.pinnedModel, answers: [.choice(name: question.name, choice: selected, probabilities: question.choices.map { .init(value: $0.value, probability: $0.value == selected ? 1 : 0) }, confidence: 1)], usage: .init(inputTokens: 10, inputTokensDetails: .init(cachedTokens: 0, cacheWriteTokens: 0), outputTokens: 0, outputTokensDetails: .init(reasoningTokens: 0), totalTokens: 10))
    }
}

private actor ComposerRoutingBackend: DecisionService {
    enum Outcome { case selectLast, preferClaude, abstain, abstainEffort, cancelEffort }
    nonisolated let id: DecisionServiceID
    nonisolated let displayName: String
    nonisolated let capabilities = DecisionServiceCapabilities.routerTest
    let outcome: Outcome
    let readiness: DecisionReadiness
    private(set) var lastRequest: FiniteChoiceDecisionRequest?
    private(set) var requests: [FiniteChoiceDecisionRequest] = []

    init(
        outcome: Outcome,
        readiness: DecisionReadiness = .ready(generation: 1, policyVersion: "fake-v1"),
        id: DecisionServiceID = .init(rawValue: "composer-fake"),
        displayName: String = "Composer fake"
    ) {
        self.id = id
        self.displayName = displayName
        self.outcome = outcome
        self.readiness = readiness
    }

    func readinessSnapshot() -> DecisionReadiness {
        readiness
    }

    func decide(_ request: FiniteChoiceDecisionRequest) -> DecisionOutcome {
        lastRequest = request
        requests.append(request)
        return switch outcome {
        case .selectLast:
            .selected(opaqueKey: request.question.choices[request.question.choices.count - 1].opaqueKey, evidence: nil)
        case .preferClaude:
            .selected(opaqueKey: request.question.choices.first {
                $0.description.hasPrefix("Provider: claudeCode;")
            }?.opaqueKey ?? request.question.choices.last!.opaqueKey, evidence: nil)
        case .abstain:
            .abstained(reasonCode: "ambiguous", evidence: nil)
        case .cancelEffort:
            request.question.name == "effort_route"
                ? .cancelled
                : .selected(opaqueKey: request.question.choices.first {
                    $0.description.contains("model: claude-opus-")
                }?.opaqueKey ?? "missing-claude-opus-fixture", evidence: nil)
        case .abstainEffort:
            request.question.name == "effort_route"
                ? .abstained(reasonCode: "ambiguous effort", evidence: nil)
                : .selected(opaqueKey: request.question.choices[request.question.choices.count - 1].opaqueKey, evidence: nil)
        }
    }
}

private final class ComposerRoutingCodexController: CodexSessionControllerPassiveStubDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var models: [String?] = []
    private var active = false
    private let stream = AsyncStream<CodexNativeSessionController.Event>.makeStream()
    var hasActiveThread: Bool {
        lock.withLock { active }
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        stream.stream
    }

    var submittedModels: [String?] {
        lock.withLock { models }
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        lock.withLock { active = true }
        return .init(conversationID: "scope-preference-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startUserTurn(
        text _: String,
        attachments _: [AgentFileAttachment],
        model: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        lock.withLock { models.append(model) }
        return CodexTurnStartReceipt(provisionalSubmissionID: "scope-preference-test")
    }

    func shutdown() async {
        lock.withLock { active = false }
        stream.continuation.finish()
    }
}

private actor SuspendedComposerRoutingBackend: DecisionService {
    nonisolated let id = DecisionServiceID(rawValue: "composer-suspended")
    nonisolated let displayName = "Composer suspended"
    nonisolated let capabilities = DecisionServiceCapabilities.routerTest
    private var request: FiniteChoiceDecisionRequest?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<DecisionOutcome, Never>?

    func readinessSnapshot() -> DecisionReadiness {
        .ready(generation: 1, policyVersion: "fake-v1")
    }

    func decide(_ request: FiniteChoiceDecisionRequest) async -> DecisionOutcome {
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
        guard let key = request?.question.choices.first?.opaqueKey else { return }
        completion?.resume(returning: .selected(opaqueKey: key, evidence: nil))
        completion = nil
    }
}

private actor StagedCancellationRoutingBackend: DecisionService {
    nonisolated let id = DecisionServiceID(rawValue: "staged-cancellation")
    nonisolated let displayName = "Staged cancellation"
    nonisolated let capabilities = DecisionServiceCapabilities.routerTest
    private(set) var requestCount = 0
    private var firstRequest: FiniteChoiceDecisionRequest?
    private var firstStageCompletion: CheckedContinuation<DecisionOutcome, Never>?
    private var isClosed = false
    private let readinessGate: TestReleaseFence?

    init(readinessGate: TestReleaseFence? = nil) {
        self.readinessGate = readinessGate
    }

    func readinessSnapshot() async -> DecisionReadiness {
        await readinessGate?.enterAndWait()
        return .ready(generation: 1, policyVersion: "fake-v1")
    }

    func decide(_ request: FiniteChoiceDecisionRequest) async -> DecisionOutcome {
        requestCount += 1
        guard requestCount == 1, !isClosed else { return .cancelled }
        firstRequest = request
        return await withCheckedContinuation { firstStageCompletion = $0 }
    }

    func cancelPendingStage() {
        isClosed = true
        firstStageCompletion?.resume(returning: .cancelled)
        firstStageCompletion = nil
    }

    func completeFirstStageSelection() {
        guard let key = firstRequest?.question.choices.last?.opaqueKey else { return }
        firstStageCompletion?.resume(returning: .selected(opaqueKey: key, evidence: nil))
        firstStageCompletion = nil
    }
}

private extension DecisionServiceCapabilities {
    static let routerTest = Self(
        contextKinds: [.text],
        finiteChoice: .init(
            minimumChoices: 2, maximumChoices: 12, maximumContextBytes: 24 * 1024,
            maximumInstructionsBytes: 16 * 1024, maximumChoiceDescriptionBytes: 8 * 1024,
            maximumAggregateBytes: 128 * 1024
        ),
        evidence: .init(confidence: true, probabilityDistribution: true, usage: true)
    )
}

// MARK: - Slash-command composer suggestions

@MainActor
final class AgentSlashCommandSuggestionsTests: XCTestCase {
    func testClaudeCompactIsDiscoverableAndPrefixFiltered() async {
        let viewModel = makeViewModel()
        addTeardownBlock { await viewModel.prepareForWindowClose() }
        viewModel.selectedAgent = .claudeCode

        let fresh = await viewModel.slashSkillSuggestions(for: "")
        XCTAssertFalse(fresh.contains { $0.relativePath == "compact" })
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.providerSessionID = "   "
        viewModel.test_installLiveSession(session)
        viewModel.test_setCurrentTabIDOverride(session.tabID)
        let emptyConversation = await viewModel.slashSkillSuggestions(for: "comp")
        XCTAssertTrue(emptyConversation.isEmpty)
        session.providerSessionID = "restored-conversation"
        let all = await viewModel.slashSkillSuggestions(for: "")
        XCTAssertEqual(all.first?.relativePath, "compact")
        let filtered = await viewModel.slashSkillSuggestions(for: "comp")
        XCTAssertEqual(filtered.first?.displayName, "/compact")
        let unrelated = await viewModel.slashSkillSuggestions(for: "zz-no-command")
        XCTAssertFalse(unrelated.contains { $0.relativePath == "compact" })
        let explicitSkill = await viewModel.slashSkillSuggestions(for: "skill:compact")
        XCTAssertFalse(explicitSkill.contains { $0.subtitle == "Compact Claude Code conversation context" })
    }

    func testClaudeBuiltinDoesNotLeakIntoOtherProviderMenus() async {
        let viewModel = makeViewModel()
        addTeardownBlock { await viewModel.prepareForWindowClose() }
        for provider: AgentProviderKind in [.codexExec, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .cursor, .openCode, .grokBuild, .devin, .antigravity] {
            viewModel.selectedAgent = provider
            let suggestions = await viewModel.slashSkillSuggestions(for: "comp")
            XCTAssertFalse(suggestions.contains { $0.subtitle == "Compact Claude Code conversation context" }, provider.rawValue)
        }
    }

    func testActiveClaudeRuntimeCommandsReachMenuButNotOtherProviders() async {
        let viewModel = makeViewModel()
        addTeardownBlock { await viewModel.prepareForWindowClose() }
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.providerSessionID = "restored-conversation"
        session.claudeController = SlashSuggestionRuntime()
        viewModel.test_installLiveSession(session)
        viewModel.test_setCurrentTabIDOverride(session.tabID)

        let claude = await viewModel.slashSkillSuggestions(for: "context")
        XCTAssertEqual(claude.map(\.relativePath), ["context"])
        session.selectedAgent = .cursor
        let cursor = await viewModel.slashSkillSuggestions(for: "context")
        XCTAssertFalse(cursor.contains { $0.relativePath == "context" })
    }

    func testSuspendedRuntimeLookupCannotPublishAfterProviderSwitch() async {
        let viewModel = makeViewModel()
        addTeardownBlock { await viewModel.prepareForWindowClose() }
        let started = expectation(description: "runtime command lookup started")
        let runtime = SlashSuggestionRuntime(holdLookup: true, onLookup: { started.fulfill() })
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.claudeController = runtime
        viewModel.test_installLiveSession(session)
        viewModel.test_setCurrentTabIDOverride(session.tabID)

        let pending = Task { await viewModel.slashSkillSuggestions(for: "context") }
        await fulfillment(of: [started], timeout: 2)
        session.selectedAgent = .cursor
        await runtime.releaseLookup()
        let stale = await pending.value
        XCTAssertTrue(stale.isEmpty)
    }

    func testAdvertisedCommandsAreMergedAndDeduplicatedWithCompactFallback() {
        let commands: [NativeAgentRuntimeSlashCommand] = [
            .init(name: "context", description: "Show context", argumentHint: "[detail]"),
            .init(name: "compact", description: "Provider compact", argumentHint: ""),
            .init(name: "CONTEXT", description: "Duplicate", argumentHint: "")
        ]
        let all = AgentModeViewModel.claudeSlashCommandSuggestions(for: "", runtimeCommands: commands, canCompact: true)
        XCTAssertEqual(all.map(\.relativePath), ["compact", "context"])
        XCTAssertEqual(all.last?.subtitle, "Show context — [detail]")
        let filtered = AgentModeViewModel.claudeSlashCommandSuggestions(for: " CON ", runtimeCommands: commands, canCompact: true)
        XCTAssertEqual(filtered.map(\.relativePath), ["context"])
    }

    func testExactAdvertisedCommandSurvivesSuggestionLimit() {
        var commands = (0 ..< 80).map {
            NativeAgentRuntimeSlashCommand(name: "context-\($0)", description: "Related command", argumentHint: "")
        }
        commands.append(.init(name: "context", description: "Exact command", argumentHint: ""))
        let native = AgentModeViewModel.claudeSlashCommandSuggestions(for: "context", runtimeCommands: commands, canCompact: true)
        let suggestions = AgentModeViewModel.mergeClaudeSlashSuggestions(native: native, skills: [], query: "context")
        XCTAssertEqual(suggestions.count, 6)
        XCTAssertEqual(suggestions.first?.relativePath, "context")
        XCTAssertEqual(suggestions.count(where: { $0.relativePath == "context" }), 1)
    }

    func testCompactSkillCollisionKeepsNativeCommandAndExplicitSkillSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let commands = root.appendingPathComponent(".claude/commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "Local compact instructions".write(to: commands.appendingPathComponent("compact.md"), atomically: true, encoding: .utf8)
        try "---\ndescription: Local context skill\n---\nLocal context instructions".write(to: commands.appendingPathComponent("context.md"), atomically: true, encoding: .utf8)
        let catalog = AgentSkillCatalog(homeDirectoryURL: root.appendingPathComponent("home"))
        let viewModel = makeViewModel(root: root, catalog: catalog)
        addTeardownBlock { await viewModel.prepareForWindowClose() }
        viewModel.selectedAgent = .claudeCode
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.providerSessionID = "restored-conversation"
        session.claudeController = SlashSuggestionRuntime()
        viewModel.test_installLiveSession(session)
        viewModel.test_setCurrentTabIDOverride(session.tabID)

        let suggestions = await viewModel.slashSkillSuggestions(for: "compact")
        XCTAssertEqual(suggestions.map(\.relativePath), ["compact", "skill:compact"])
        XCTAssertTrue(viewModel.resolvedSlashSkillInvocations(in: "/compact", agentKind: .claudeCode).isEmpty)
        XCTAssertEqual(viewModel.resolvedSlashSkillInvocations(in: "/skill:compact", agentKind: .claudeCode).first?.definition.name, "compact")
        let explicit = await viewModel.slashSkillSuggestions(for: "skill:compact")
        XCTAssertEqual(explicit.map(\.relativePath), ["skill:compact"])
        XCTAssertEqual(viewModel.resolvedSlashSkillInvocations(in: "/compact", agentKind: .cursor).first?.definition.name, "compact")
        // Deliberate compatibility policy: a local skill shadows even an advertised
        // non-compact built-in. The displayed local row must match actual expansion.
        let context = await viewModel.slashSkillSuggestions(for: "context")
        XCTAssertEqual(context.map(\.relativePath), ["context"])
        XCTAssertEqual(context.first?.subtitle, "Local context skill")
        XCTAssertEqual(viewModel.resolvedSlashSkillInvocations(in: "/context", agentKind: .claudeCode).first?.definition.name, "context")
        XCTAssertFalse(context.first?.submitsOnExactEnter ?? true)
        session.selectedAgent = .cursor
        XCTAssertTrue(viewModel.resolvedSlashSkillInvocations(in: "/compact", agentKind: .claudeCode).isEmpty)
        XCTAssertEqual(viewModel.resolvedSlashSkillInvocations(in: "/compact", agentKind: .cursor).first?.definition.name, "compact")
    }

    func testLargeRuntimeMenuRetainsLocalSkillAfterDeduplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let commands = root.appendingPathComponent(".claude/commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "---\ndescription: Local review skill\n---\nReview instructions".write(to: commands.appendingPathComponent("review-local.md"), atomically: true, encoding: .utf8)
        var runtimeCommands = (0 ..< 9).map {
            NativeAgentRuntimeSlashCommand(name: "review-\($0)", description: "Runtime review", argumentHint: "", builtin: true)
        }
        runtimeCommands.append(.init(name: "review-local", description: "Runtime duplicate", argumentHint: ""))
        let viewModel = makeViewModel(root: root, catalog: AgentSkillCatalog(homeDirectoryURL: root.appendingPathComponent("home")))
        addTeardownBlock { await viewModel.prepareForWindowClose() }
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.providerSessionID = "existing-conversation"
        session.claudeController = SlashSuggestionRuntime(commands: runtimeCommands)
        viewModel.test_installLiveSession(session)
        viewModel.test_setCurrentTabIDOverride(session.tabID)

        let suggestions = await viewModel.slashSkillSuggestions(for: "review")
        XCTAssertEqual(suggestions.count, 6)
        XCTAssertEqual(Set(suggestions.map(\.relativePath)).count, 6)
        XCTAssertEqual(suggestions.count(where: { $0.relativePath == "review-local" }), 1)
        XCTAssertEqual(suggestions.first { $0.relativePath == "review-local" }?.subtitle, "Local review skill")
    }

    func testRuntimeBuiltinMarkerAndArgumentHintsControlExactEnterPolicy() {
        let snapshot = ClaudeNativeProcessSessionController.parseInitializeResponseSnapshot(from: ["commands": [
            ["name": "context", "description": "Context", "argumentHint": "", "builtin": true],
            ["name": "review", "description": "Review", "argumentHint": "<file>", "builtin": true],
            ["name": "review-skill", "description": "Skill", "argumentHint": ""],
            ["name": "compact", "description": "Compact", "argumentHint": "", "builtin": true]
        ]])
        let suggestions = AgentModeViewModel.claudeSlashCommandSuggestions(for: "", runtimeCommands: snapshot.commands, canCompact: false)
        XCTAssertEqual(suggestions.first { $0.relativePath == "context" }?.submitsOnExactEnter, true)
        XCTAssertEqual(suggestions.first { $0.relativePath == "review" }?.submitsOnExactEnter, false)
        XCTAssertEqual(suggestions.first { $0.relativePath == "review-skill" }?.submitsOnExactEnter, false)
        XCTAssertFalse(suggestions.contains { $0.relativePath == "compact" })
        let compactWithHint = AgentModeViewModel.claudeSlashCommandSuggestions(for: "", runtimeCommands: [
            .init(name: "compact", description: "Compact", argumentHint: "[instructions]", builtin: true)
        ], canCompact: true)
        XCTAssertEqual(compactWithHint.first?.submitsOnExactEnter, false)
    }

    private func makeViewModel(root: URL? = nil, catalog: AgentSkillCatalog? = nil) -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspacePath: root?.path,
            skillCatalog: catalog,
            codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Slash suggestions must not start Codex") },
            headlessProviderFactory: { _, _ in UnsupportedHeadlessAgentProvider(reason: "slash suggestions test") }
        )
    }
}

/// Command discovery is a cached runtime read, not a provider launch or model turn.
private actor SlashSuggestionRuntime: NativeAgentRuntimeControlling {
    var hasActiveSession = true
    var hasTurnInFlight = false
    var events: AsyncStream<NativeAgentRuntimeEvent> {
        AsyncStream { $0.finish() }
    }

    private let commands: [NativeAgentRuntimeSlashCommand]
    private let holdLookup: Bool
    private let onLookup: (@Sendable () -> Void)?
    private var lookupContinuation: CheckedContinuation<Void, Never>?
    private var lookupReleased = false

    init(
        commands: [NativeAgentRuntimeSlashCommand] = [.init(name: "context", description: "Show runtime context", argumentHint: "", builtin: true)],
        holdLookup: Bool = false,
        onLookup: (@Sendable () -> Void)? = nil
    ) {
        self.commands = commands
        self.holdLookup = holdLookup
        self.onLookup = onLookup
    }

    func availableSlashCommands() async -> [NativeAgentRuntimeSlashCommand] {
        onLookup?()
        if holdLookup, !lookupReleased {
            await withCheckedContinuation { lookupContinuation = $0 }
        }
        return commands
    }

    func releaseLookup() {
        lookupReleased = true
        lookupContinuation?.resume()
        lookupContinuation = nil
    }

    func ensureEventsStreamReady() {}
    func resetEventsStreamForNewRun() {}
    func currentSessionRef() -> NativeAgentRuntimeSessionRef {
        .init(sessionID: "slash-test")
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) {}
    func shutdown() {
        hasActiveSession = false
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) {}

    func startOrResume(existingSessionID: String?, model: String?, effortLevel: NativeAgentRuntimeEffortLevel?, systemPromptOverride: String?) -> NativeAgentRuntimeSessionRef {
        preconditionFailure("Slash suggestions must not start a provider")
    }

    func sendUserMessage(_ text: String) -> UUID {
        preconditionFailure("Slash suggestions must not send provider messages")
    }

    func interruptTurn(reason: String) -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }
}
