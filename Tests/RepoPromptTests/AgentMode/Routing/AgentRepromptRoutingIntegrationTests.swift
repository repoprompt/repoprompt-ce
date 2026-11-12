import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

@MainActor
final class AgentRepromptRoutingIntegrationTests: XCTestCase {
    func testPendingSendIsVisibleAndDraftEmptyWhileRoutingIsSuspended() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let gate = AgentRepromptStartGate()
        await fixture.backend.setGate(gate)
        defer { Task { await gate.release() } }
        let vm = fixture.viewModel
        let tabID = fixture.session.tabID
        vm.storeDraftText(for: tabID, "Send this task")
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: fixture.session))
        let attempt = AgentComposerSubmitAttempt(id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: "Send this task")
        guard case let .claimed(claim) = vm.claimComposerSubmitForImmediatePresentation(attempt) else {
            return XCTFail("Expected local handoff")
        }
        let task = Task { @MainActor in
            let result = await vm.submitUserTurnAfterFreshTaskRouting(
                text: "Send this task", claim: claim, session: fixture.session, destinationTabID: tabID
            )
            vm.finishPresentedComposerSubmitAttempt(claim, result: result)
            return result
        }
        try await AsyncTestWait.waitUntil("routing suspended", timeout: 5) { await !fixture.backend.requests.isEmpty }
        XCTAssertEqual(vm.draftRuntime.text(for: tabID), "")
        XCTAssertEqual(vm.ui.composer.pendingSubmissions[attempt.id]?.text, "Send this task")
        XCTAssertFalse(fixture.session.items.contains { $0.kind == .user })
        vm.storeDraftText(for: tabID, "Next draft")
        await gate.release()
        let result = await task.value
        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(vm.ui.composer.pendingSubmissions.isEmpty)
        XCTAssertEqual(fixture.session.items.count(where: { $0.kind == .user }), 1)
        XCTAssertEqual(vm.draftRuntime.text(for: tabID), "Next draft")
    }

    func testUsagePeerReconciliationDoesNotInvalidatePreparedSpeculation() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.store.setUsageBalancingEnabled(true)
        let advisor = AgentUsageBalancer()
        fixture.runtime.usageBalancer = advisor
        let claim = try fixture.claim(text: "Original")
        defer { fixture.viewModel.releaseComposerSubmitClaim(claim) }
        fixture.viewModel.startRepromptSpeculation(session: fixture.session, operationID: claim.attempt.id, text: "Complete brief", originalText: "Original")
        let speculation = try XCTUnwrap(fixture.viewModel.repromptSpeculations[claim.attempt.id])
        _ = await speculation.routingTask?.value
        var base = try XCTUnwrap(AgentTaskRoutingCandidateBuilder().build(allowedProviders: [.claudeCode], availability: fixture.viewModel.modelRouterAvailabilityContext).first)
        base.usagePeerClass = "reconciliation-peer"
        let peer = AgentTaskRoutingCandidateBuilder.Candidate(opaqueKey: "peer", utilityTier: base.utilityTier, target: .init(agentRaw: AgentProviderKind.codexExec.rawValue, modelRaw: "gpt-6-sol-high", reasoningEffortRaw: "high", modelParameters: []), descriptor: base.descriptor, usagePeerClass: base.usagePeerClass)
        var reconciliations = 0
        advisor.onRoutingActivity = {
            reconciliations += 1
            advisor.update(nil, provider: AgentProviderKind.codexExec.rawValue)
            advisor.update(nil, provider: AgentProviderKind.claudeCode.rawValue)
        }
        defer { advisor.onRoutingActivity = nil }
        let configuration = fixture.store.modelRouterConfiguration()
        _ = advisor.choose(selected: base, candidates: [base, peer], evidence: nil, configuration: configuration)
        XCTAssertGreaterThan(reconciliations, 0, "Exercise the peer-selection callback that reconciles disallowed leases")
        XCTAssertEqual(advisor.revision, speculation.usageRevision, "Already-empty leases do not change effective usage state")
        let before = await fixture.backend.requests.count
        XCTAssertNotNil(fixture.viewModel.reusableRepromptRouting(speculation, approved: "Complete brief", configuration: configuration, backendID: fixture.backend.id, runtime: fixture.runtime))
        XCTAssertEqual(speculation.reuse, .reused)
        let after = await fixture.backend.requests.count
        XCTAssertEqual(before, after)
    }

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
        fixture.viewModel.startRepromptSpeculation(session: fixture.session, operationID: claim.attempt.id, text: approved, originalText: claim.attempt.rawDraftSnapshot)
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

    func testMCPAutoEffortCannotAdoptAReactivatedSuccessorWriter() async throws {
        for change in ["none", "restorationRefresh", "staleContext", "newContext", "deactivated", "retire"] {
            let succeeds = change == "none" || change == "restorationRefresh"
            let fixture = try await AgentRepromptTestFixture()
            defer { fixture.cleanUp() }
            let vm = fixture.viewModel
            let session = fixture.session
            try fixture.installPersistentWriter()
            session.hasLoadedPersistedState = true
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            // Model a restored MCP-origin session, not app-owned resident consent.
            session.isMCPOriginated = true
            _ = vm.runService
            let sessionID = try XCTUnwrap(session.activeAgentSessionID)
            let writer = try XCTUnwrap(vm.runtimeCommand(sessionID: sessionID)).writer
            let originalContext = try await vm.mcpActivateControlContext(
                forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: nil
            )
            if change == "restorationRefresh" {
                let generation = session.beginPersistentBindingTransition()
                session.finishPersistentBindingTransition(generation: generation)
                session.recordRestorationAuthoritative(.persistedPayloadApplied)
                XCTAssertTrue(writer.ownsPersistentClaim)
                XCTAssertFalse(writer.isCurrent, "A retained control registration need not have today's restoration generation")
            }
            fixture.store.setModelRouterEnabled(false)
            fixture.store.setAutoEffortBackendRaw(fixture.backend.id.rawValue)
            fixture.store.setAutoEffortEnabled(true)
            await fixture.runtime.reconcileDemand()
            let option = try XCTUnwrap(AgentModelCatalog.options(for: .claudeCode, availability: vm.modelRouterAvailabilityContext).first {
                AutoEffortModelPolicy.claudeEfforts(modelRaw: $0.rawValue, advertised: AgentModelCatalog.supportedClaudeEfforts(forSelectedModelRaw: $0.rawValue, agentKind: .claudeCode)).count >= 2
            })
            session.selectedModelRaw = option.rawValue
            session.selectedClaudeEffortRaw = nil
            let gate = AgentRepromptStartGate()
            await fixture.backend.setGate(gate)
            defer { Task { await gate.release() } }
            var starts = 0
            vm.test_providerSwitchStart = { _, _, _ in starts += 1 }
            let dispatch = Task { @MainActor in
                try await vm.mcpDispatchInstruction(sessionID: sessionID, text: "Inspect the parser behavior", allowStartingRun: true)
            }
            defer { dispatch.cancel() }
            try await AsyncTestWait.waitUntil("MCP judgment is held in the decision backend", timeout: 5) {
                await fixture.backend.requests.count == 1
            }
            XCTAssertNotNil(session.selectedClaudeEffortRaw, "An admitted judgment still normalizes its manual effort")
            let binding = session.currentRestorationBindingToken
            if change == "retire" {
                writer.scope.beginRetirement()
            } else if change == "deactivated" {
                await vm.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
                XCTAssertTrue(writer.isCurrent)
            } else if !succeeds {
                let members = writer.scope.sessions
                writer.scope.replaceSessions(members.filter { $0.key != session.tabID })
                writer.scope.replaceSessions(members)
                XCTAssertFalse(writer.ownsPersistentClaim)
                XCTAssertNil(vm.mcpRuntime.controlledWriter(sessionID: sessionID)?.session)
                if change == "newContext" {
                    let state = session.runState
                    let task = session.agentTask
                    _ = try await vm.mcpActivateControlContext(
                        forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: nil
                    )
                    XCTAssertTrue(vm.mcpRuntime.controlledWriter(sessionID: sessionID)?.session === session)
                    XCTAssertNotEqual(session.mcpControlContext?.writerIdentity, writer.identity)
                    XCTAssertEqual(session.runState, state)
                    XCTAssertEqual(session.agentTask, task)
                }
            }
            XCTAssertEqual(session.currentRestorationBindingToken, binding)
            let context = session.mcpControlContext
            let items = session.items
            if !succeeds {
                // Isolate the old judgment from the successor's independently admitted
                // approval-sync task, whose active-tab permission projection normalizes effort.
                vm.test_setCurrentTabIDOverride(nil)
                session.selectedClaudeEffortRaw = nil
                session.isDirty = false
            }
            let saveGeneration = session.saveRequestGeneration
            await gate.release()
            switch await dispatch.result {
            case let .success(delivery):
                XCTAssertTrue(succeeds, change)
                XCTAssertEqual(delivery, .startedRun)
                XCTAssertEqual(session.items.last(where: { $0.kind == .user })?.text, "Inspect the parser behavior")
                XCTAssertNotNil(session.autoEffortFeedback, "This synthetic fixture qualifies input admission, not a connected provider launch")
            case let .failure(error):
                XCTAssertFalse(succeeds, String(describing: error))
                XCTAssertTrue(String(describing: error).contains("session changed"), String(describing: error))
                XCTAssertEqual(session.items, items)
                XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
                XCTAssertNil(session.agentTask)
                XCTAssertNil(session.autoEffortFeedback)
                XCTAssertEqual(session.mcpControlContext, context)
                XCTAssertEqual(starts, 0)
                XCTAssertNil(session.selectedClaudeEffortRaw, "\(change): The old judgment must not normalize the successor's selection")
                XCTAssertFalse(session.isDirty, change)
                XCTAssertEqual(session.saveRequestGeneration, saveGeneration, change)
            }
            XCTAssertNil(session.autoEffortJudgmentID)
            await fixture.startGate.release()
            await vm.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            await AgentRunSessionStore.cleanup(registration: originalContext.registration)
            let registered = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
            XCTAssertFalse(registered)
            await fixture.runtime.teardown()
        }
    }

    func testReleasedComposerCannotNormalizeEffortAfterJudgment() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let vm = fixture.viewModel
        let session = fixture.session
        try fixture.installPersistentWriter()
        session.hasLoadedPersistedState = true
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        fixture.store.setModelRouterEnabled(false)
        fixture.store.setAutoEffortBackendRaw(fixture.backend.id.rawValue)
        fixture.store.setAutoEffortEnabled(true)
        await fixture.runtime.reconcileDemand()
        let option = try XCTUnwrap(AgentModelCatalog.options(for: .claudeCode, availability: vm.modelRouterAvailabilityContext).first {
            AutoEffortModelPolicy.claudeEfforts(modelRaw: $0.rawValue, advertised: AgentModelCatalog.supportedClaudeEfforts(forSelectedModelRaw: $0.rawValue, agentKind: .claudeCode)).count >= 2
        })
        session.selectedModelRaw = option.rawValue
        let claim = try fixture.claim(text: "Inspect the parser behavior")
        defer { vm.releaseComposerSubmitClaim(claim) }
        let gate = AgentRepromptStartGate()
        await fixture.backend.setGate(gate)
        defer { Task { await gate.release() } }
        let submit = Task { @MainActor in
            await vm.submitUserTurnAfterAutoEffort(text: claim.attempt.rawDraftSnapshot, claim: claim, session: session, destinationTabID: session.tabID)
        }
        defer { submit.cancel() }
        try await AsyncTestWait.waitUntil("composer judgment held", timeout: 5) { await fixture.backend.requests.count == 1 }
        vm.releaseComposerSubmitClaim(claim)
        session.selectedClaudeEffortRaw = nil
        session.isDirty = false
        let generation = session.saveRequestGeneration
        await gate.release()
        guard case .blocked = await submit.value else { return XCTFail("Released composer must not submit") }
        XCTAssertNil(session.selectedClaudeEffortRaw)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.saveRequestGeneration, generation)
        XCTAssertFalse(session.items.contains { $0.kind == .user })
        XCTAssertNil(session.autoEffortJudgmentID)
        await fixture.startGate.release()
        await fixture.runtime.teardown()
    }

    func testEffortSpeculationCapturesMembershipBeforeItsTaskAndRecomputesAfterFirstBinding() async throws {
        for change in ["none", "reacquire", "bind"] {
            let fixture = try await AgentRepromptTestFixture()
            defer { fixture.cleanUp() }
            let vm = fixture.viewModel
            let session = fixture.session
            fixture.store.setModelRouterEnabled(false)
            fixture.store.setAutoEffortBackendRaw(fixture.backend.id.rawValue)
            fixture.store.setAutoEffortEnabled(true)
            await fixture.runtime.reconcileDemand()
            let option = try XCTUnwrap(AgentModelCatalog.options(for: .claudeCode, availability: vm.modelRouterAvailabilityContext).first {
                AutoEffortModelPolicy.claudeEfforts(modelRaw: $0.rawValue, advertised: AgentModelCatalog.supportedClaudeEfforts(forSelectedModelRaw: $0.rawValue, agentKind: .claudeCode)).count >= 2
            })
            session.selectedModelRaw = option.rawValue
            let claim = try fixture.claim(text: "Original task")
            defer { vm.releaseComposerSubmitClaim(claim) }
            let approved = "Inspect the parser behavior"
            vm.startRepromptSpeculation(session: session, operationID: claim.attempt.id, text: approved, originalText: claim.attempt.rawDraftSnapshot)
            let speculation = try XCTUnwrap(vm.repromptSpeculations[claim.attempt.id])
            let task = try XCTUnwrap(speculation.effortTask)
            // No suspension between task creation and membership drift: the task has not entered.
            if change == "reacquire" {
                let members = claim.scope.sessions
                claim.scope.replaceSessions(members.filter { $0.key != session.tabID })
                claim.scope.replaceSessions(members)
            } else if change == "bind" {
                try fixture.installPersistentWriter()
                session.hasLoadedPersistedState = true
                session.recordRestorationAuthoritative(.persistedPayloadApplied)
            }
            session.selectedClaudeEffortRaw = nil
            session.isDirty = false
            let choice = await task.value
            let requests = await fixture.backend.requests.count
            if change == "none" {
                XCTAssertNotNil(choice?.selection)
                XCTAssertEqual(requests, 1)
            } else {
                XCTAssertNil(choice)
                XCTAssertEqual(requests, 0)
                XCTAssertNil(session.selectedClaudeEffortRaw)
                XCTAssertFalse(session.isDirty)
            }
            if change == "bind" {
                XCTAssertTrue(vm.composerSubmitRuntime.isCurrent(claim), "First binding is a supported continuation of a local creation claim")
                let result = await vm.submitUserTurnAfterAutoEffort(
                    text: claim.attempt.rawDraftSnapshot, claim: claim, session: session,
                    destinationTabID: session.tabID, repromptedText: approved
                )
                XCTAssertEqual(result, .submitted)
                let requests = await fixture.backend.requests.count
                XCTAssertEqual(requests, 1, "A refused speculation is recomputed through the accepting claim")
                XCTAssertNotNil(session.autoEffortFeedback)
            }
            await fixture.startGate.release()
            await fixture.runtime.teardown()
        }
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
            let approved = oversized ? String(repeating: "x", count: 4001) : "/review Approved parser requirement"
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
            fixture.viewModel.startRepromptSpeculation(session: fixture.session, operationID: claim.attempt.id, text: "Generated", originalText: claim.attempt.rawDraftSnapshot)
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

    func testCompletedReturnPreservesSpeculationAndAdoptsIntoFreshLocalClaim() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        XCTAssertTrue(try fixture.begin(text: AgentRepromptServiceTests.valid))
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt)
        try await AsyncTestWait.waitUntil("prepared draft", timeout: 5) { fixture.viewModel.repromptOperation?.phase == .completed }
        let operationID = try XCTUnwrap(fixture.viewModel.repromptOperation?.id)
        let staged = try XCTUnwrap(fixture.viewModel.repromptSpeculations[operationID])
        _ = await staged.routingTask?.value
        let operation = try XCTUnwrap(fixture.viewModel.repromptOperation)
        let generation = operation.expectedDraftGeneration
        operation.useCurrentDraft(fixture.session.draftText) // The same entry point as composer Return.
        XCTAssertEqual(operation.expectedDraftGeneration, generation)
        XCTAssertFalse(operation.usedOriginal, "An unchanged rewrite must not become an explicit send-original audit")
        XCTAssertTrue(fixture.viewModel.repromptSpeculations[operationID] === staged)
        let claim = try fixture.claim(text: fixture.session.draftText, local: true)
        defer { fixture.viewModel.releaseComposerSubmitClaim(claim) }
        XCTAssertNil(fixture.viewModel.repromptOperation)
        XCTAssertNil(fixture.viewModel.repromptSpeculations[operationID])
        XCTAssertTrue(fixture.viewModel.repromptSpeculations[claim.attempt.id] === staged)
        XCTAssertEqual(fixture.viewModel.repromptDispatchTexts[claim.attempt.id], AgentRepromptServiceTests.valid)
        XCTAssertTrue(fixture.session.items.isEmpty)
    }
}

/// Single-session tests read preparation state without naming the tab that owns it.
extension AgentRepromptUIStore {
    var presentation: Presentation? {
        get { presentations.values.first }
        set {
            if let newValue {
                presentations[newValue.sourceTabID] = newValue
            } else {
                presentations.removeAll()
            }
        }
    }

    var pendingQuestions: AgentAskUserPendingState? {
        pendingQuestionsByTab.values.first
    }

    var autoSendRequest: AutoSendRequest? {
        autoSendRequests.values.first
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

    /// This isolated host has no workspace manager. Qualify the restored runtime identity;
    /// callers still establish (or deliberately withhold) payload restoration themselves.
    func installPersistentWriter() throws {
        let sessionID = UUID()
        XCTAssertNil(viewModel.runtimeSessionStore.bindingRejection(sessionID, on: session))
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: UUID()))
        guard case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: sessionID) else {
            throw NSError(domain: "AgentRepromptTestFixture.writer", code: 1)
        }
        XCTAssertTrue(writer.session === session)
        XCTAssertTrue(writer.isCurrent)
    }

    func enableReprompt() {
        viewModel.repromptEnabled = true
        viewModel.repromptAvailability = { $0 == .gpt61SolLow }
        viewModel.repromptService = .init(transport: { _, _, publish in try await publish(AgentRepromptServiceTests.valid) })
        var profile = store.globalAgentModelsProfile()
        profile.agentRepromptModelRaw = AIModel.gpt61SolLow.rawValue
        store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
    }

    func begin(text: String) throws -> Bool {
        viewModel.storeDraftText(for: session.tabID, text)
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: session.tabID, session: session))
        return viewModel.beginComposerReprompt(target: target, text: text)
    }

    func claim(text: String, local: Bool = false) throws -> AgentModeViewModel.AgentComposerSubmitClaim {
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: session.tabID, session: session))
        let attempt = AgentComposerSubmitAttempt(id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: text)
        guard case let .claimed(claim) = viewModel.claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: local)
        else { throw CancellationError() }
        return claim
    }

    func cleanUp() {
        viewModel.cancelReprompt()
        for id in Array(viewModel.repromptSpeculations.keys) {
            viewModel.repromptSpeculations.removeValue(forKey: id)?.cancel(runtime: viewModel.modelRouterRuntime)
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
    private var gate: AgentRepromptStartGate?
    func setGate(_ gate: AgentRepromptStartGate) {
        self.gate = gate
    }

    func readinessSnapshot() -> DecisionReadiness {
        .ready(generation: 1, policyVersion: "test")
    }

    func decide(_ request: FiniteChoiceDecisionRequest) async -> DecisionOutcome {
        requests.append(request)
        if let gate { _ = await gate.wait() }
        return .selected(opaqueKey: request.question.choices.last!.opaqueKey, evidence: nil)
    }
}
