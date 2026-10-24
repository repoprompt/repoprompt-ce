import Combine
@testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import XCTest

@MainActor
final class RouterSettingsViewModelTests: XCTestCase {
    func testOpenAICardUnmountsSecureFieldAcrossCollapseAndResignsFocus() async throws {
        let secureKeys = SecureKeysService(secureStorage: TestSecureStorageBackend())
        let credentials = OpenAIDecisionsRouterCredentialService(secureKeys: secureKeys) { _, _ in
            throw CancellationError()
        }
        let registration = DecisionServiceRegistration(
            service: OpenAIDecisionsDecisionService(credentialService: credentials),
            configuration: OpenAIDecisionsDecisionService.settingsRegistration(controller: credentials)
        )
        let fixture = try makeFixture(customRegistrations: [registration])
        await fixture.viewModel.refresh()
        let row = try XCTUnwrap(fixture.viewModel.serviceRows.first { $0.id == .openAIDecisions })
        let host = try RouterAccordionProductionCardFocusFixture(
            viewModel: fixture.viewModel,
            row: row,
            initiallyExpanded: false
        )
        defer { host.tearDown() }

        guard host.waitFor("collapsed OpenAI card content to remain unmounted", until: {
            host.secureField == nil
        }) else { return }
        let collapsedHeight = host.fittingHeight

        host.setExpanded(true)
        guard host.waitFor("OpenAI SecureField to mount on opening", until: {
            host.secureField?.isEnabled == true
                && host.fittingHeight > collapsedHeight + 20
        }) else { return }
        let secureField = try XCTUnwrap(host.secureField)
        guard host.window.makeFirstResponder(secureField) else {
            XCTFail("Could not focus actual card SecureField. \(host.focusDiagnostic)")
            return
        }
        guard host.waitFor("actual card SecureField to own first responder while mounted", until: {
            host.secureField === secureField && host.secureFieldOwnsFirstResponder
        }) else { return }

        host.setExpanded(false)
        guard host.waitFor("collapsed SecureField to unmount and resign keyboard focus", until: {
            host.secureField == nil
                && !host.fieldOwnsFirstResponder(secureField)
                && abs(host.fittingHeight - collapsedHeight) < 0.5
        }) else { return }

        host.setExpanded(true)
        guard host.waitFor("a new SecureField to mount on reopening", until: {
            guard let reopenedField = host.secureField else { return false }
            return reopenedField !== secureField && reopenedField.isEnabled
        }) else { return }
        let reopenedSecureField = try XCTUnwrap(host.secureField)
        guard host.window.makeFirstResponder(reopenedSecureField) else {
            XCTFail("Could not focus reopened card SecureField. \(host.focusDiagnostic)")
            return
        }
        guard host.waitFor("reopened SecureField to own first responder", until: {
            host.secureField === reopenedSecureField && host.secureFieldOwnsFirstResponder
        }) else { return }

        // Exercise the actual card API-key FocusState binding assignment, not a mouse click.
        host.assignOpenAIConfigurationInputFocus()
        guard host.waitFor("SecureField ownership and API-key focus binding update", until: {
            host.secureField === reopenedSecureField
                && host.secureFieldOwnsFirstResponder
                && host.focusedConfigurationInputID == .openAIDecisions
        }) else { return }

        // The enum is binding state only; this deliberately makes no native input-responder claim.
        XCTAssertFalse(reopenedSecureField === secureField, "The card must recreate its conditional content on reopening")
    }

    func testSubscriptionsRefreshOnlyForChangedRouterInputs() async throws {
        let accounting = PreviewRefreshAccounting()
        let fixture = try makeFixture(refreshCompletionObserver: { accounting.recordRefreshCompletion($0) })
        await fixture.viewModel.refresh()
        await drainMainRunLoop()
        let initialRefreshCount = accounting.refreshCompletionCount

        fixture.store.setCodexMemoriesEnabled(!fixture.store.codexMemoriesEnabled())
        await drainMainRunLoop()
        XCTAssertEqual(accounting.refreshCompletionCount, initialRefreshCount)

        await accounting.performAndAwaitRefresh(matching: { _ in fixture.viewModel.autoEffortEnabled }) {
            fixture.store.setAutoEffortEnabled(true)
        }
        XCTAssertTrue(fixture.viewModel.autoEffortEnabled)

        await accounting.performAndAwaitRefresh(matching: {
            $0.selectedBackendID == .openAIDecisions
        }) {
            fixture.store.setModelRouterBackend(.openAIDecisions)
        }
        XCTAssertEqual(fixture.viewModel.selectedBackendID, .openAIDecisions)
    }

    func testDuplicateVerifiedProviderTupleDoesNotScheduleRefresh() async throws {
        let accounting = PreviewRefreshAccounting()
        let fixture = try makeFixture(
            refreshCompletionObserver: { accounting.recordRefreshCompletion($0) },
            verifiedProviders: [.codexExec]
        )
        await fixture.viewModel.refresh()
        await drainMainRunLoop()
        let initialRefreshCount = accounting.refreshCompletionCount

        fixture.api.test_completeContextBuilderProviderValidation(verifiedProviders: [.codexExec])
        await drainMainRunLoop()

        XCTAssertEqual(accounting.refreshCompletionCount, initialRefreshCount)
        let changedProvidersRefresh = accounting.expectRefreshCompletion(description: "Changed verified providers refresh") { _ in true }
        fixture.api.test_completeContextBuilderProviderValidation(verifiedProviders: [])
        await fulfillment(of: [changedProvidersRefresh], timeout: 1)
    }

    func testRuntimePublicationsForwardOnlyChangedSnapshots() async throws {
        let controller = StreamingSettingsController(initial: .ready(generation: 1, policyVersion: "v1"))
        let fixture = try makeFixture(settingsController: controller)
        var forwardedChanges = 0
        var nextPublicationExpectation: XCTestExpectation?
        let observation = fixture.viewModel.objectWillChange.sink {
            forwardedChanges += 1
            nextPublicationExpectation?.fulfill()
            nextPublicationExpectation = nil
        }
        defer { observation.cancel() }
        await fixture.viewModel.refresh()
        await drainMainRunLoop()
        forwardedChanges = 0

        fixture.runtime.objectWillChange.send()
        await drainMainRunLoop()
        XCTAssertEqual(forwardedChanges, 0)

        await controller.waitUntilObserved()
        let readinessChanged = expectation(description: "Changed runtime readiness forwarded")
        nextPublicationExpectation = readinessChanged
        await controller.send(.needsConfiguration(generation: 2, reason: "Reconfigure."))
        await fulfillment(of: [readinessChanged], timeout: 1)
        forwardedChanges = 0
    }

    func testAutomaticFrontierIgnoresLegacyRoleAndProviderSelections() async throws {
        let fixture = try makeFixture()
        fixture.store.setModelRouterCandidateRoles([])
        fixture.store.setModelRouterAllowedProviders([])

        await fixture.viewModel.refresh()

        XCTAssertTrue(fixture.viewModel.policyCanBuildCandidates)
        XCTAssertGreaterThan(fixture.viewModel.distinctTargetCount, 1)
        XCTAssertTrue(fixture.viewModel.availableProviders.contains(.codexExec))
        XCTAssertTrue(fixture.viewModel.availableProviders.contains(.claudeCode))
    }

    func testSelectingBackendImmediatelyClearsOldReadinessAndPreservesConsent() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.refresh()
        XCTAssertTrue(fixture.viewModel.readiness.isReady)
        fixture.store.setModelRouterProvider(.claudeCode, scope: .subagent)

        fixture.viewModel.selectBackend(.init(rawValue: "uninstalled"))
        XCTAssertEqual(fixture.viewModel.selectedBackendID?.rawValue, "uninstalled")
        XCTAssertFalse(fixture.viewModel.canEnable)
        XCTAssertNil(fixture.viewModel.serviceRows.first(where: { $0.id.rawValue == "uninstalled" })?.presentation)
        XCTAssertEqual(fixture.store.modelRouterConfiguration().subagentProvider, .claudeCode)
        await fixture.viewModel.refresh()
        guard case .temporarilyUnavailable = fixture.viewModel.readiness else {
            return XCTFail("Unknown backend must remain unavailable")
        }
    }

    func testReselectingSameBackendDoesNotInvalidateValidatedConfiguration() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.refresh()
        let configuration = fixture.viewModel.configuration
        try fixture.viewModel.selectBackend(XCTUnwrap(configuration.selectedBackendID))
        XCTAssertEqual(fixture.store.modelRouterConfiguration(), configuration)
        XCTAssertTrue(fixture.viewModel.readiness.isReady)
    }

    func testSavedKeyVerificationPublishesExplicitSuccessFeedback() async throws {
        let controller = SettingsTestController(result: .succeeded("Key verified. Jev is ready."))
        let fixture = try makeFixture(settingsController: controller)
        await fixture.viewModel.refresh()

        let succeeded = await fixture.viewModel.performBackendAction(.revalidateStoredSecret, backendID: .jev)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            fixture.viewModel.backendOperationFeedback(for: .jev),
            .succeeded("Key verified. Jev is ready.")
        )
    }

    func testFailedBackendActionReturnsFalseAndPublishesFeedback() async throws {
        let controller = SettingsTestController(result: .failed("Authentication failed."))
        let fixture = try makeFixture(settingsController: controller)
        await fixture.viewModel.refresh()

        let succeeded = await fixture.viewModel.performBackendAction(.validateAndSaveSecret("candidate"), backendID: .jev)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(fixture.viewModel.backendOperationFeedback(for: .jev), .failed("Authentication failed."))
    }

    func testSuccessfulStoredSecretRemovalDisablesRouter() async throws {
        let controller = SettingsTestController(result: .succeeded("Stored key removed."))
        let fixture = try makeFixture(settingsController: controller)
        fixture.store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )
        await fixture.viewModel.refresh()

        let succeeded = await fixture.viewModel.performBackendAction(.removeStoredSecret, backendID: .jev)

        XCTAssertTrue(succeeded)
        XCTAssertFalse(fixture.store.modelRouterConfiguration().enabled)
        XCTAssertFalse(fixture.viewModel.configuration.enabled)
        XCTAssertEqual(
            fixture.viewModel.backendOperationFeedback(for: .jev),
            .succeeded("Stored key removed.")
        )
    }

    func testFailedStoredSecretRemovalPreservesRouterEnablementIntent() async throws {
        let controller = SettingsTestController(result: .failed("Removal failed."))
        let fixture = try makeFixture(settingsController: controller)
        fixture.store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )
        await fixture.viewModel.refresh()

        let succeeded = await fixture.viewModel.performBackendAction(.removeStoredSecret, backendID: .jev)

        XCTAssertFalse(succeeded)
        XCTAssertTrue(fixture.store.modelRouterConfiguration().enabled)
        XCTAssertTrue(fixture.viewModel.configuration.enabled)
    }

    func testUnavailableSettingsControllerClearsBackendOperationProgress() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.refresh()

        await fixture.viewModel.performBackendAction(.revalidateStoredSecret, backendID: .jev)

        XCTAssertFalse(fixture.viewModel.isPerformingBackendOperation)
        XCTAssertEqual(fixture.viewModel.backendOperationFeedback(for: .jev), .idle)
    }

    func testCustomGuidancePersistsThroughViewModel() throws {
        let fixture = try makeFixture()

        XCTAssertTrue(fixture.viewModel.setCustomInstructions("  Prefer Claude Opus for execution.  "))

        XCTAssertEqual(
            fixture.store.modelRouterConfiguration().customInstructions,
            "Prefer Claude Opus for execution."
        )
    }

    func testCompletedProviderValidationWithNoAuthenticatedTargetsPreservesEnablementIntent() async throws {
        let fixture = try makeFixture(
            availability: .none,
            verifiedProviders: []
        )
        fixture.store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )

        await fixture.viewModel.refresh()

        XCTAssertTrue(fixture.store.modelRouterConfiguration().enabled)
        XCTAssertTrue(fixture.viewModel.configuration.enabled)
        XCTAssertFalse(fixture.viewModel.canEnable)
    }

    func testUnavailableSubagentPreferenceDoesNotBlockAuthenticatedCodex() async throws {
        let fixture = try makeFixture(
            availability: AgentModelCatalog.AvailabilityContext(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false
            ),
            verifiedProviders: [.codexExec]
        )
        fixture.store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )
        fixture.store.setModelRouterProvider(.codexExec, scope: .primarySession)
        fixture.store.setModelRouterProvider(.claudeCode, scope: .subagent)

        await fixture.viewModel.refresh()

        XCTAssertTrue(fixture.store.modelRouterConfiguration().enabled)
        XCTAssertTrue(fixture.viewModel.canEnable)
        XCTAssertEqual(fixture.viewModel.availableProviders, [.codexExec])
    }

    func testStaleExcludedPrimaryProviderPreferenceDoesNotBlockCuratedReadiness() async throws {
        let fixture = try makeFixture(
            availability: AgentModelCatalog.AvailabilityContext(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false
            ),
            verifiedProviders: [.codexExec]
        )
        await fixture.viewModel.refresh()
        XCTAssertTrue(fixture.viewModel.policyCanBuildCandidates)

        fixture.store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )
        fixture.store.setModelRouterProvider(.openCode, scope: .primarySession)
        await fixture.viewModel.refresh()

        XCTAssertTrue(fixture.viewModel.readiness.isReady)
        XCTAssertEqual(fixture.viewModel.availableProviders, [.codexExec])
        XCTAssertTrue(fixture.viewModel.policyCanBuildCandidates)
        XCTAssertTrue(fixture.viewModel.canEnable)
        XCTAssertTrue(fixture.viewModel.configuration.enabled)
        XCTAssertEqual(fixture.store.modelRouterConfiguration().primaryProvider, .openCode)
    }

    func testGenericAndExplicitDefaultSelectionTruthTable() async throws {
        let rows: [(Int, String?, DecisionServiceID?, String?)] = [
            (0, nil, nil, nil), (1, nil, nil, "jev"), (1, "  ", nil, "  "),
            (2, nil, nil, nil), (2, "", nil, ""),
            (2, nil, .jev, "jev"), (2, "  ", .jev, "  "),
            (2, "openai-decisions", .jev, "openai-decisions"),
            (2, "future", .jev, "future")
        ]
        for (count, raw, defaultID, expected) in rows {
            let fixture = try makeFixture(selectedRaw: raw, backendCount: count, defaultBackendID: defaultID)
            await fixture.viewModel.refresh()
            XCTAssertEqual(fixture.viewModel.configuration.selectedBackendRawValue, expected)
            XCTAssertEqual(fixture.viewModel.backendOptions.count, count)
            await fixture.runtime.teardown()
        }
    }

    func testLateRemovalCannotDisableAfterSelectionOrRevisionChanges() async throws {
        enum Mutation: Equatable {
            case selection
            case reselection
            case revision
        }

        for mutation in [Mutation.selection, .reselection, .revision] {
            let controller = SuspendedSettingsController()
            let fixture = try makeFixture(settingsController: controller, backendCount: 2)
            fixture.store.setModelRouterEnabled(true)
            fixture.store.setAutoEffortEnabled(true)
            await fixture.viewModel.refresh()
            let action = Task { await fixture.viewModel.performBackendAction(.removeStoredSecret, backendID: .jev) }
            await controller.waitUntilStarted()
            switch mutation {
            case .selection:
                fixture.viewModel.selectBackend(.openAIDecisions)
            case .reselection:
                fixture.viewModel.selectBackend(.openAIDecisions)
                fixture.viewModel.selectBackend(.jev)
            case .revision:
                fixture.viewModel.setCustomInstructions("New configuration")
            }
            await controller.complete()
            let succeeded = await action.value
            XCTAssertFalse(succeeded)
            XCTAssertTrue(fixture.store.modelRouterConfiguration().enabled)
            XCTAssertTrue(fixture.store.autoEffortEnabled())
            XCTAssertEqual(
                fixture.store.modelRouterConfiguration().selectedBackendID,
                mutation == .selection ? .openAIDecisions : .jev
            )
            XCTAssertEqual(fixture.viewModel.backendOperationFeedback(for: .jev), .idle)
            XCTAssertFalse(fixture.viewModel.isPerformingBackendOperation)
            await fixture.runtime.teardown()
        }
    }

    func testSelectionChangesDoNotReleaseSerializedCredentialOperation() async throws {
        let controller = SuspendedSettingsController()
        let decisionsController = SettingsTestController(result: .succeeded("Decisions verified."))
        let fixture = try makeFixture(
            settingsController: controller,
            secondarySettingsController: decisionsController,
            backendCount: 2
        )
        await fixture.viewModel.refresh()
        let old = Task {
            await fixture.viewModel.performBackendAction(.revalidateStoredSecret, backendID: .jev)
        }
        await controller.waitUntilStarted()
        fixture.viewModel.selectBackend(.openAIDecisions)
        fixture.viewModel.selectBackend(.jev)

        let rejected = await fixture.viewModel.performBackendAction(.revalidateStoredSecret, backendID: .jev)

        XCTAssertFalse(rejected)
        let callCount = await controller.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertTrue(fixture.viewModel.isPerformingBackendOperation)
        await controller.complete()
        let oldResult = await old.value
        XCTAssertFalse(oldResult)
        XCTAssertFalse(fixture.viewModel.isPerformingBackendOperation)
        XCTAssertEqual(fixture.viewModel.backendOperationFeedback(for: .jev), .idle)

        let later = await fixture.viewModel.performBackendAction(
            .revalidateStoredSecret,
            backendID: .openAIDecisions
        )
        XCTAssertTrue(later)
        let decisionsCallCount = await decisionsController.callCount()
        XCTAssertEqual(decisionsCallCount, 1)
        XCTAssertEqual(
            fixture.viewModel.backendOperationFeedback(for: .openAIDecisions),
            .succeeded("Decisions verified.")
        )
        await fixture.runtime.teardown()
    }

    func testSecretDraftTypingPublishesOnlyTheEditedDraftObserver() {
        let state = RouterSettingsViewState()
        let editedDraft = state.secretDraftState(for: .jev)
        let siblingDraft = state.secretDraftState(for: .openAIDecisions)
        var parentNotifications = 0
        var editedDraftNotifications = 0
        var siblingDraftNotifications = 0
        let observers = [
            state.objectWillChange.sink { parentNotifications += 1 },
            editedDraft.objectWillChange.sink { editedDraftNotifications += 1 },
            siblingDraft.objectWillChange.sink { siblingDraftNotifications += 1 }
        ]
        defer { observers.forEach { $0.cancel() } }

        for characterCount in 1 ... 100 {
            state.setSecretDraft(String(repeating: "x", count: characterCount), for: .jev)
        }

        XCTAssertEqual(parentNotifications, 0)
        XCTAssertEqual(editedDraftNotifications, 100)
        XCTAssertEqual(siblingDraftNotifications, 0)
    }

    func testViewStateKeepsDraftsKeyedAndRejectsStaleClears() {
        let state = RouterSettingsViewState()
        state.setSecretDraft("jev-old", for: .jev)
        let stale = state.secretDraftSnapshot(for: .jev)
        state.setSecretDraft("jev-new", for: .jev)
        state.setSecretDraft("decisions", for: .openAIDecisions)

        XCTAssertFalse(state.clearSecretDraft(for: .jev, ifRevision: stale.revision))
        XCTAssertEqual(state.secretDraft(for: .jev), "jev-new")
        XCTAssertEqual(state.secretDraft(for: .openAIDecisions), "decisions")

        let current = state.secretDraftSnapshot(for: .jev)
        XCTAssertTrue(state.clearSecretDraft(for: .jev, ifRevision: current.revision))
        XCTAssertEqual(state.secretDraft(for: .jev), "")
        XCTAssertEqual(state.secretDraft(for: .openAIDecisions), "decisions")
    }

    func testLeavingAndReenteringSettingsDuringValidationCannotClearNewSecretDraft() async throws {
        let controller = SuspendedSettingsController()
        let fixture = try makeFixture(settingsController: controller)
        await fixture.viewModel.refresh()
        let viewState = RouterSettingsViewState()
        viewState.setSecretDraft("old-key", for: .jev)
        let oldDraft = viewState.secretDraftSnapshot(for: .jev)
        let action = Task {
            if await fixture.viewModel.performBackendAction(
                .validateAndSaveSecret(oldDraft.value), backendID: .jev
            ) {
                viewState.clearSecretDraft(for: .jev, ifRevision: oldDraft.revision)
            }
        }
        await controller.waitUntilStarted()

        // The same window-local state survives the Settings tab disappearing and reappearing.
        viewState.clearAllSecretDrafts()
        XCTAssertEqual(viewState.secretDraft(for: .jev), "")
        viewState.setSecretDraft("new-key", for: .jev)
        let newDraft = viewState.secretDraftSnapshot(for: .jev)
        XCTAssertGreaterThan(newDraft.revision, oldDraft.revision)

        await controller.complete()
        await action.value
        XCTAssertEqual(viewState.secretDraft(for: .jev), "new-key")
        XCTAssertEqual(viewState.secretDraftSnapshot(for: .jev), newDraft)
    }

    func testDisclosureExpansionIsIndependentByServiceAndSection() {
        let state = RouterSettingsViewState()
        let jevPrivacy = "jev:privacy"
        let decisionsPrivacy = "openai-decisions:privacy"
        let routerPrivacy = "model-router:sharing-details"

        state.setDisclosureExpanded(true, disclosureID: jevPrivacy)
        XCTAssertTrue(state.isDisclosureExpanded(jevPrivacy))
        XCTAssertFalse(state.isDisclosureExpanded(decisionsPrivacy))
        XCTAssertFalse(state.isDisclosureExpanded(routerPrivacy))

        state.setDisclosureExpanded(true, disclosureID: decisionsPrivacy)
        state.setDisclosureExpanded(false, disclosureID: jevPrivacy)
        XCTAssertFalse(state.isDisclosureExpanded(jevPrivacy))
        XCTAssertTrue(state.isDisclosureExpanded(decisionsPrivacy))
    }

    func testRouterSharingDisclosureRetainsNestedExpansionIndependently() {
        let state = RouterSettingsViewState()
        let sharing = "model-router:sharing"
        let details = "model-router:sharing-details"
        let behavior = "model-router:routing-behavior"

        XCTAssertFalse(state.isDisclosureExpanded(sharing))
        XCTAssertFalse(state.isDisclosureExpanded(details))
        state.setDisclosureExpanded(true, disclosureID: sharing)
        state.setDisclosureExpanded(true, disclosureID: details)
        XCTAssertFalse(state.isDisclosureExpanded(behavior))

        state.setDisclosureExpanded(false, disclosureID: sharing)
        XCTAssertTrue(state.isDisclosureExpanded(details))
        state.setDisclosureExpanded(true, disclosureID: behavior)
        XCTAssertFalse(state.isDisclosureExpanded(sharing))

        state.setDisclosureExpanded(true, disclosureID: sharing)
        XCTAssertTrue(state.isDisclosureExpanded(details))
        XCTAssertTrue(state.isDisclosureExpanded(behavior))
    }

    func testServiceCardsStartCollapsedAndExpandOnlyExplicitly() {
        let state = RouterSettingsViewState()

        XCTAssertTrue(state.expandedServiceIDs.isEmpty)

        state.setServiceExpanded(true, backendID: .openAIDecisions)
        XCTAssertEqual(state.expandedServiceIDs, [.openAIDecisions])

        state.setServiceExpanded(false, backendID: .openAIDecisions)
        XCTAssertTrue(state.expandedServiceIDs.isEmpty)
    }

    func testOpenAIOuterExpansionPublishesOnlyItsDedicatedStateAndIgnoresUnchangedWrites() {
        let state = RouterSettingsViewState()
        var sharedStatePublications = 0
        var openAIExpansionPublications = 0
        let sharedStateObservation = state.objectWillChange.sink {
            sharedStatePublications += 1
        }
        let openAIExpansionObservation = state.openAIServiceExpansion.objectWillChange.sink {
            openAIExpansionPublications += 1
        }
        defer {
            sharedStateObservation.cancel()
            openAIExpansionObservation.cancel()
        }

        state.setServiceExpanded(true, backendID: .openAIDecisions)
        XCTAssertTrue(state.isServiceExpanded(.openAIDecisions))
        XCTAssertEqual(state.expandedServiceIDs, [.openAIDecisions])
        XCTAssertEqual(sharedStatePublications, 0)
        XCTAssertEqual(openAIExpansionPublications, 1)

        state.setServiceExpanded(true, backendID: .openAIDecisions)
        XCTAssertEqual(sharedStatePublications, 0)
        XCTAssertEqual(openAIExpansionPublications, 1)

        state.setServiceExpanded(false, backendID: .openAIDecisions)
        XCTAssertFalse(state.isServiceExpanded(.openAIDecisions))
        XCTAssertTrue(state.expandedServiceIDs.isEmpty)
        XCTAssertEqual(sharedStatePublications, 0)
        XCTAssertEqual(openAIExpansionPublications, 2)
    }

    func testJevOuterExpansionStillPublishesSharedStateWithoutChangingOpenAIExpansion() {
        let state = RouterSettingsViewState()
        var sharedStatePublications = 0
        var openAIExpansionPublications = 0
        let sharedStateObservation = state.objectWillChange.sink {
            sharedStatePublications += 1
        }
        let openAIExpansionObservation = state.openAIServiceExpansion.objectWillChange.sink {
            openAIExpansionPublications += 1
        }
        defer {
            sharedStateObservation.cancel()
            openAIExpansionObservation.cancel()
        }

        state.setServiceExpanded(true, backendID: .jev)

        XCTAssertTrue(state.isServiceExpanded(.jev))
        XCTAssertFalse(state.isServiceExpanded(.openAIDecisions))
        XCTAssertEqual(state.expandedServiceIDs, [.jev])
        XCTAssertEqual(sharedStatePublications, 1)
        XCTAssertEqual(openAIExpansionPublications, 0)
    }

    func testConfigureOpenAIExpandsItWithFreshTokensAndPreservesDraftRevision() throws {
        let state = RouterSettingsViewState()
        state.setSecretDraft("openai-key", for: .openAIDecisions)
        let draft = state.secretDraftSnapshot(for: .openAIDecisions)
        var openAIExpansionPublications = 0
        let openAIExpansionObservation = state.openAIServiceExpansion.objectWillChange.sink {
            openAIExpansionPublications += 1
        }
        defer { openAIExpansionObservation.cancel() }

        state.requestConfigure(.openAIDecisions)
        let firstRequest = try XCTUnwrap(state.configureRequest)
        state.requestConfigure(.openAIDecisions)
        let secondRequest = try XCTUnwrap(state.configureRequest)

        XCTAssertTrue(state.isServiceExpanded(.openAIDecisions))
        XCTAssertEqual(firstRequest.backendID, .openAIDecisions)
        XCTAssertEqual(secondRequest.backendID, .openAIDecisions)
        XCTAssertNotEqual(firstRequest.token, secondRequest.token)
        XCTAssertEqual(openAIExpansionPublications, 1)
        XCTAssertEqual(state.secretDraftSnapshot(for: .openAIDecisions), draft)
    }

    func testConfigureRequestOnlyExpandsTargetAndPreservesSettingsDemandAndControllerState() async throws {
        let controller = SettingsTestController(result: .succeeded("unused"))
        let fixture = try makeFixture(
            settingsController: controller,
            selectedRaw: DecisionServiceID.openAIDecisions.rawValue,
            backendCount: 2
        )
        fixture.store.setModelRouterEnabled(true)
        fixture.store.setAutoEffortEnabled(true)
        await fixture.viewModel.refresh()
        let configuration = fixture.store.modelRouterConfiguration()
        let demand = fixture.store.routerDemandSnapshot()
        let readiness = fixture.viewModel.serviceStatesByID
        let viewState = RouterSettingsViewState()
        let bootstrapCount = await controller.bootstrapCallCount()
        let invalidationCount = await controller.invalidationCallCount()

        viewState.requestConfigure(.jev)
        let firstRequest = try XCTUnwrap(viewState.configureRequest)
        viewState.requestConfigure(.jev)
        let secondRequest = try XCTUnwrap(viewState.configureRequest)

        XCTAssertTrue(viewState.isServiceExpanded(.jev))
        XCTAssertEqual(firstRequest.backendID, .jev)
        XCTAssertEqual(secondRequest.backendID, .jev)
        XCTAssertNotEqual(firstRequest.token, secondRequest.token)
        XCTAssertEqual(fixture.store.modelRouterConfiguration(), configuration)
        XCTAssertEqual(fixture.store.routerDemandSnapshot(), demand)
        XCTAssertTrue(fixture.store.autoEffortEnabled())
        XCTAssertEqual(fixture.viewModel.serviceStatesByID, readiness)
        let actionCallCount = await controller.callCount()
        XCTAssertEqual(actionCallCount, 0)
        let currentBootstrapCount = await controller.bootstrapCallCount()
        let currentInvalidationCount = await controller.invalidationCallCount()
        XCTAssertEqual(currentBootstrapCount, bootstrapCount)
        XCTAssertEqual(currentInvalidationCount, invalidationCount)
    }

    func testSyntheticFutureRegistrationRetainsRenderingMetadataOrderAndEligibility() async throws {
        let controller = SettingsTestController(result: .succeeded("ok"))
        let futurePresentation = try DecisionServiceSettingsPresentation(
            title: "CLEF B",
            summary: "Future routing service summary.",
            notices: [.init(id: "future-notice", text: "Future notice.", emphasis: .warning)],
            disclosures: [
                .init(
                    id: "future-privacy",
                    category: .privacy,
                    title: "Future privacy",
                    paragraphs: ["Future privacy detail."]
                )
            ],
            productStatus: .preview,
            capabilities: [
                .init(id: "model-router", title: "Model Router"),
                .init(id: "future-capability", title: "Future capability")
            ],
            secretFieldLabel: "CLEF API key",
            supportedCredentialActions: [.validateAndSaveSecret, .removeStoredSecret],
            links: [
                .init(
                    title: "CLEF documentation",
                    url: XCTUnwrap(URL(string: "https://example.com/clef"))
                )
            ]
        )
        let registrations = [
            DecisionServiceRegistration(
                service: SettingsTestBackend(id: .init(rawValue: "clef-b")),
                configuration: .init(presentation: futurePresentation, controller: controller),
                displayOrder: 300
            ),
            DecisionServiceRegistration(
                service: SettingsTestBackend(id: .openAIDecisions),
                configuration: .init(presentation: testPresentation(title: "Decisions"), controller: controller),
                displayOrder: 200
            ),
            DecisionServiceRegistration(
                service: SettingsTestBackend(id: .jev),
                configuration: .init(presentation: testPresentation(title: "Jev"), controller: controller),
                displayOrder: 100
            ),
            DecisionServiceRegistration(
                service: SettingsTestBackend(id: .init(rawValue: "clef-a"), routerEligible: false),
                configuration: .init(presentation: testPresentation(title: "CLEF A"), controller: controller),
                displayOrder: 300
            )
        ]
        let fixture = try makeFixture(customRegistrations: registrations)

        await fixture.viewModel.refresh()

        XCTAssertEqual(
            fixture.viewModel.serviceRows.map(\.id.rawValue),
            ["jev", "openai-decisions", "clef-a", "clef-b"]
        )
        XCTAssertEqual(
            fixture.viewModel.backendOptions.map(\.id.rawValue),
            ["jev", "openai-decisions", "clef-b"]
        )
        XCTAssertEqual(
            fixture.viewModel.autoEffortBackendOptions.map(\.id.rawValue),
            ["jev", "openai-decisions", "clef-b"]
        )
        fixture.viewModel.selectAutoEffortBackend(.openAIDecisions)
        XCTAssertEqual(fixture.viewModel.selectedAutoEffortBackendID, .openAIDecisions)
        XCTAssertEqual(fixture.viewModel.selectedBackendID, .jev)
        XCTAssertFalse(fixture.viewModel.autoEffortEnabled)
        fixture.viewModel.selectAutoEffortBackend(.init(rawValue: "future-service"))
        await fixture.viewModel.refresh()
        XCTAssertEqual(fixture.viewModel.autoEffortConfiguration.selectedBackendRawValue, "future-service")
        XCTAssertEqual(fixture.viewModel.autoEffortReadiness.isReady, false)
        XCTAssertEqual(fixture.viewModel.selectedBackendID, .jev)
        XCTAssertEqual(
            fixture.viewModel.serviceRows.first(where: { $0.id.rawValue == "clef-a" })?.presentation?.title,
            "CLEF A"
        )
        XCTAssertEqual(
            fixture.viewModel.serviceRows.first(where: { $0.id.rawValue == "clef-b" })?.presentation,
            futurePresentation
        )
    }

    func testReadinessUpdatesRemainKeyedByBackendAndRejectOlderGenerations() async throws {
        let jev = StreamingSettingsController(initial: .ready(generation: 2, policyVersion: "jev-v2"))
        let decisions = StreamingSettingsController(initial: .validating(generation: 4))
        let fixture = try makeFixture(
            settingsController: jev,
            secondarySettingsController: decisions,
            backendCount: 2
        )
        await fixture.viewModel.refresh()
        await jev.waitUntilObserved()
        await decisions.waitUntilObserved()
        await fixture.viewModel.refresh()
        let jevObservationCount = await jev.readinessObservationCount()
        let decisionsObservationCount = await decisions.readinessObservationCount()
        XCTAssertEqual(jevObservationCount, 1)
        XCTAssertEqual(decisionsObservationCount, 1)
        XCTAssertEqual(
            fixture.runtime.decisionServiceReadinessByID[.jev],
            .ready(generation: 2, policyVersion: "jev-v2")
        )

        await jev.send(.needsConfiguration(generation: 3, reason: "Jev key required."))
        await waitUntil {
            fixture.viewModel.serviceState(for: .jev)?.readiness
                == .needsConfiguration(generation: 3, reason: "Jev key required.")
        }
        XCTAssertEqual(
            fixture.viewModel.serviceState(for: .openAIDecisions)?.readiness,
            .validating(generation: 4)
        )

        await jev.send(.ready(generation: 2, policyVersion: "stale"))
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertEqual(
            fixture.viewModel.serviceState(for: .jev)?.readiness,
            .needsConfiguration(generation: 3, reason: "Jev key required.")
        )

        await jev.send(.validating(generation: 3))
        await waitUntil {
            fixture.viewModel.serviceState(for: .jev)?.readiness == .validating(generation: 3)
        }
        XCTAssertEqual(fixture.viewModel.readiness, .validating(generation: 3))
    }

    func testIndependentProviderActionIsRejectedWhileSerializedOperationRuns() async throws {
        let jev = SuspendedSettingsController()
        let decisions = SettingsTestController(result: .succeeded("Decisions verified."))
        let fixture = try makeFixture(
            settingsController: jev,
            secondarySettingsController: decisions,
            backendCount: 2
        )
        await fixture.viewModel.refresh()
        let active = Task {
            await fixture.viewModel.performBackendAction(.revalidateStoredSecret, backendID: .jev)
        }
        await jev.waitUntilStarted()

        let rejected = await fixture.viewModel.performBackendAction(
            .revalidateStoredSecret,
            backendID: .openAIDecisions
        )

        XCTAssertFalse(rejected)
        let decisionsCallCount = await decisions.callCount()
        XCTAssertEqual(decisionsCallCount, 0)
        XCTAssertEqual(
            fixture.viewModel.backendOperationFeedback(for: .openAIDecisions),
            .idle
        )
        await jev.complete()
        let activeResult = await active.value
        XCTAssertTrue(activeResult)
    }

    func testDecisionsSelectedAutoEffortEnabledJevConfigureAndRemovePreserveIntent() async throws {
        let jev = StreamingSettingsController(initial: .ready(generation: 1, policyVersion: "jev-v1"))
        let fixture = try makeFixture(
            settingsController: jev,
            selectedRaw: DecisionServiceID.openAIDecisions.rawValue,
            backendCount: 2
        )
        fixture.store.enableModelRouterWithCurrentPolicy(
            backendID: .openAIDecisions,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )
        fixture.store.setAutoEffortEnabled(true)
        await fixture.viewModel.refresh()
        await jev.waitUntilObserved()
        let configuration = fixture.store.modelRouterConfiguration()
        let demand = fixture.store.routerDemandSnapshot()
        let viewState = RouterSettingsViewState()

        viewState.requestConfigure(.jev)
        XCTAssertTrue(viewState.isServiceExpanded(.jev))
        XCTAssertEqual(fixture.store.modelRouterConfiguration(), configuration)
        XCTAssertEqual(fixture.store.routerDemandSnapshot(), demand)

        let configured = await fixture.viewModel.performBackendAction(
            .validateAndSaveSecret("candidate"),
            backendID: .jev
        )
        XCTAssertTrue(configured)
        let removed = await fixture.viewModel.performBackendAction(
            .removeStoredSecret,
            backendID: .jev
        )
        XCTAssertTrue(removed)
        await waitUntil {
            guard case .needsConfiguration = fixture.viewModel.serviceState(for: .jev)?.readiness else {
                return false
            }
            return true
        }

        XCTAssertEqual(fixture.store.modelRouterConfiguration().selectedBackendID, .openAIDecisions)
        XCTAssertTrue(fixture.store.modelRouterConfiguration().enabled)
        XCTAssertTrue(fixture.store.autoEffortEnabled())
        let jevCallCount = await jev.callCount()
        XCTAssertEqual(jevCallCount, 2)
        XCTAssertEqual(
            fixture.viewModel.backendOperationFeedback(for: .jev),
            .succeeded("Stored key removed.")
        )
        XCTAssertEqual(fixture.viewModel.backendOperationFeedback(for: .openAIDecisions), .idle)
    }

    func testObservingRefreshingAndExpandingServicesDoesNotCreateDemandProbeOrGenerationEffects() async throws {
        let jev = SettingsTestController(result: .succeeded("unused"))
        let decisions = SettingsTestController(result: .succeeded("unused"))
        let fixture = try makeFixture(
            settingsController: jev,
            secondarySettingsController: decisions,
            selectedRaw: DecisionServiceID.openAIDecisions.rawValue,
            backendCount: 2
        )
        await fixture.viewModel.refresh()
        let configuration = fixture.store.modelRouterConfiguration()
        let demand = fixture.store.routerDemandSnapshot()
        let readiness = fixture.viewModel.serviceStatesByID
        let viewState = RouterSettingsViewState()

        viewState.setServiceExpanded(true, backendID: .jev)
        viewState.setServiceExpanded(true, backendID: .openAIDecisions)
        await fixture.viewModel.refresh()
        await fixture.viewModel.refresh()

        XCTAssertEqual(fixture.store.modelRouterConfiguration(), configuration)
        XCTAssertEqual(fixture.store.routerDemandSnapshot(), demand)
        XCTAssertTrue(demand.requiredBackendIDs.isEmpty)
        XCTAssertEqual(fixture.viewModel.serviceStatesByID, readiness)
        let jevCalls = await jev.callCount()
        let decisionsCalls = await decisions.callCount()
        let jevBootstrapCalls = await jev.bootstrapCallCount()
        let decisionsBootstrapCalls = await decisions.bootstrapCallCount()
        let jevInvalidationCalls = await jev.invalidationCallCount()
        let decisionsInvalidationCalls = await decisions.invalidationCallCount()
        XCTAssertEqual(jevCalls, 0)
        XCTAssertEqual(decisionsCalls, 0)
        XCTAssertEqual(jevBootstrapCalls, 0)
        XCTAssertEqual(decisionsBootstrapCalls, 0)
        XCTAssertEqual(jevInvalidationCalls, 0)
        XCTAssertEqual(decisionsInvalidationCalls, 0)
    }

    func testRawNilBlankAndUnknownSelectionsSurviveObservationAndConfigure() async throws {
        for raw in [nil, "", "  ", "future-router"] as [String?] {
            let fixture = try makeFixture(selectedRaw: raw, backendCount: 2)
            await fixture.viewModel.refresh()
            let viewState = RouterSettingsViewState()

            viewState.requestConfigure(.jev)
            await fixture.viewModel.refresh()

            XCTAssertEqual(
                fixture.store.modelRouterConfiguration().selectedBackendRawValue,
                raw
            )
            XCTAssertEqual(
                fixture.viewModel.configuration.selectedBackendRawValue,
                raw
            )
            await fixture.runtime.teardown()
        }
    }

    func testEveryCredentialActionLeavesAutoEffortIntentUnchanged() async throws {
        let controller = SettingsTestController(result: .succeeded("done"))
        let fixture = try makeFixture(settingsController: controller)
        fixture.store.setAutoEffortEnabled(true)
        await fixture.viewModel.refresh()

        let actions: [DecisionServiceSettingsAction] = [
            .validateAndSaveSecret("candidate"),
            .revalidateStoredSecret,
            .removeStoredSecret
        ]
        for action in actions {
            let succeeded = await fixture.viewModel.performBackendAction(action, backendID: .jev)
            XCTAssertTrue(succeeded)
            XCTAssertTrue(fixture.store.autoEffortEnabled())
        }
    }

    func testUndeclaredCredentialActionNeverReachesController() async throws {
        let controller = SettingsTestController(result: .succeeded("unexpected"))
        let registration = DecisionServiceRegistration(
            service: SettingsTestBackend(id: .jev),
            configuration: .init(
                presentation: testPresentation(
                    title: "Jev",
                    actions: [.revalidateStoredSecret]
                ),
                controller: controller
            )
        )
        let fixture = try makeFixture(customRegistrations: [registration])
        await fixture.viewModel.refresh()

        let succeeded = await fixture.viewModel.performBackendAction(.removeStoredSecret, backendID: .jev)
        XCTAssertFalse(succeeded)
        let callCount = await controller.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testTargetPreviewsUseCompleteAvailabilityInputAndStoreDrivenMutationRefreshes() async throws {
        let availability = MutableAvailabilityContext(
            .init(claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false)
        )
        let accounting = PreviewRefreshAccounting()
        let fixture = try makeFixture(
            availabilityProvider: { availability.value },
            targetPreviewBuilder: { context in
                accounting.recordPreviewBuild()
                return [Self.preview(for: context)]
            },
            refreshCompletionObserver: { accounting.recordRefreshCompletion($0) },
            backendCount: 2
        )

        let initialRefresh = accounting.expectRefreshCompletion(description: "initial refresh") { _ in true }
        await fixture.viewModel.refresh()
        await fulfillment(of: [initialRefresh], timeout: 1)
        XCTAssertEqual(accounting.previewBuildCount, 1)
        XCTAssertEqual(fixture.viewModel.targetPreviews, [Self.preview(for: availability.value)])

        let selectedRevision = fixture.store.modelRouterConfiguration().revision
        await accounting.performAndAwaitRefresh(matching: {
            $0.selectedBackendID == .openAIDecisions && $0.revision > selectedRevision
        }) {
            fixture.viewModel.selectBackend(.openAIDecisions)
            XCTAssertEqual(fixture.viewModel.selectedBackendID, .openAIDecisions)
            XCTAssertGreaterThan(fixture.store.modelRouterConfiguration().revision, selectedRevision)
        }
        XCTAssertEqual(fixture.viewModel.serviceRows.map(\.id), [.jev, .openAIDecisions])
        XCTAssertEqual(accounting.previewBuildCount, 1)

        let enabledRevision = fixture.store.modelRouterConfiguration().revision
        await accounting.performAndAwaitRefresh(matching: {
            $0.enabled && $0.revision > enabledRevision
        }) {
            fixture.viewModel.setEnabled(true)
            XCTAssertTrue(fixture.viewModel.configuration.enabled)
            XCTAssertGreaterThan(fixture.store.modelRouterConfiguration().revision, enabledRevision)
        }
        XCTAssertEqual(fixture.viewModel.serviceRows.map(\.id), [.jev, .openAIDecisions])
        XCTAssertEqual(accounting.previewBuildCount, 1)

        availability.value = .init(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            zaiConfigured: true
        )
        let availabilityRefresh = accounting.expectRefreshCompletion(description: "changed availability refresh") { _ in true }
        await fixture.viewModel.refresh()
        await fulfillment(of: [availabilityRefresh], timeout: 1)
        XCTAssertEqual(accounting.previewBuildCount, 2)
        XCTAssertEqual(fixture.viewModel.targetPreviews, [Self.preview(for: availability.value)])
    }

    func testCatalogChangeInvalidatesTargetPreviewCacheWithoutAvailabilityChange() async throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let accounting = PreviewRefreshAccounting()
        let fixture = try makeFixture(
            availabilityProvider: { availability },
            targetPreviewBuilder: { context in
                accounting.recordPreviewBuild()
                return [Self.preview(for: context)]
            },
            refreshCompletionObserver: { accounting.recordRefreshCompletion($0) }
        )

        let initialRefresh = accounting.expectRefreshCompletion(description: "initial catalog preview") { _ in true }
        await fixture.viewModel.refresh()
        await fulfillment(of: [initialRefresh], timeout: 1)
        XCTAssertEqual(accounting.previewBuildCount, 1)

        let refreshCompletionCount = accounting.refreshCompletionCount
        let catalogRefresh = fixture.viewModel.agentExecutionCatalogDidChange()
        await catalogRefresh.value
        XCTAssertGreaterThan(accounting.refreshCompletionCount, refreshCompletionCount)
        XCTAssertEqual(accounting.previewBuildCount, 2)
        XCTAssertEqual(fixture.viewModel.targetPreviews, [Self.preview(for: availability)])
    }

    func testModelTagsPreserveCandidateOrderForRightAlignedDisplay() async throws {
        let previews = ["Luna", "Terra", "Sol", "Astra"].map { displayName in
            RouterSettingsViewModel.TargetPreview(
                utilityTier: displayName.lowercased(),
                provider: .codexExec,
                displayName: displayName,
                target: .init(
                    agentRaw: AgentProviderKind.codexExec.rawValue,
                    modelRaw: displayName.lowercased(),
                    reasoningEffortRaw: nil,
                    modelParameters: []
                )
            )
        }
        let fixture = try makeFixture(targetPreviewBuilder: { _ in previews })

        await fixture.viewModel.refresh()

        XCTAssertEqual(fixture.viewModel.modelTagPreviews.map(\.displayName), ["Luna", "Terra", "Sol", "Astra"])
    }

    func testModelTagLabelUsesAuthoritativeFamilyProjectionAndFallsBackToCatalogName() {
        let projected = Self.modelTagPreview(
            modelRaw: "gpt-6-luna",
            displayName: "GPT-6 Luna",
            familyDisplayName: "Luna"
        )
        XCTAssertEqual(RouterSettingsView.modelTagLabel(for: projected), "Luna")

        let unknown = Self.modelTagPreview(modelRaw: "future-model-x", displayName: "Future Model X")
        XCTAssertEqual(RouterSettingsView.modelTagLabel(for: unknown), "Future Model X")
    }

    func testModelTagHelpAndAccessibilityKeepFullTargetAndEffort() {
        let explicitEffort = Self.modelTagPreview(modelRaw: "gpt-6-astra", displayName: "GPT 6 Astra", effort: "high")
        let help = RouterSettingsView.modelTagHelp(for: explicitEffort)
        XCTAssertTrue(help.contains("Default target: GPT 6 Astra — High"))
        XCTAssertTrue(help.contains("Model Router chooses the model"))
        XCTAssertTrue(help.contains("Auto Effort may later adjust effort"))
        XCTAssertTrue(help.contains("without changing model/cache identity"))
        let alreadySuffixed = Self.modelTagPreview(modelRaw: "gpt-6-luna", displayName: "GPT-6 Luna High", effort: "high")
        XCTAssertTrue(RouterSettingsView.modelTagHelp(for: alreadySuffixed).contains("Default target: GPT-6 Luna — High"))
        XCTAssertEqual(RouterSettingsView.modelTagAccessibilityValue(for: explicitEffort), "Codex CLI target gpt-6-astra, high")

        let modelDefault = Self.modelTagPreview(modelRaw: "gpt-5.6-terra", displayName: "GPT 5.6 Terra")
        XCTAssertTrue(RouterSettingsView.modelTagHelp(for: modelDefault).contains("model default effort"))
        XCTAssertEqual(
            RouterSettingsView.modelTagAccessibilityValue(for: modelDefault),
            "Codex CLI target gpt-5.6-terra, model default effort"
        )
    }

    private static func modelTagPreview(
        modelRaw: String,
        displayName: String,
        familyDisplayName: String? = nil,
        effort: String? = nil
    ) -> RouterSettingsViewModel.TargetPreview {
        .init(
            utilityTier: "test",
            provider: .codexExec,
            displayName: displayName,
            familyDisplayName: familyDisplayName,
            target: .init(
                agentRaw: AgentProviderKind.codexExec.rawValue,
                modelRaw: modelRaw,
                reasoningEffortRaw: effort,
                modelParameters: []
            )
        )
    }

    func testChangedAvailabilityBuildFailureClearsStalePreviewsAndRetries() async throws {
        let availability = MutableAvailabilityContext(
            .init(claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false)
        )
        let behavior = PreviewBuildBehavior()
        let accounting = PreviewRefreshAccounting()
        let fixture = try makeFixture(
            availabilityProvider: { availability.value },
            targetPreviewBuilder: { context in
                accounting.recordPreviewBuild()
                if behavior.shouldFail {
                    throw PreviewBuildError.unavailable
                }
                return [Self.preview(for: context)]
            },
            refreshCompletionObserver: { accounting.recordRefreshCompletion($0) }
        )

        let initialRefresh = accounting.expectRefreshCompletion(description: "initial preview build") { _ in true }
        await fixture.viewModel.refresh()
        await fulfillment(of: [initialRefresh], timeout: 1)
        XCTAssertEqual(fixture.viewModel.targetPreviews, [Self.preview(for: availability.value)])
        XCTAssertTrue(fixture.viewModel.policyCanBuildCandidates)
        let successfulBuildCount = accounting.previewBuildCount

        availability.value = .init(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            zaiConfigured: true
        )
        behavior.shouldFail = true
        let failedRefresh = accounting.expectRefreshCompletion(description: "failed changed preview build") { _ in true }
        await fixture.viewModel.refresh()
        await fulfillment(of: [failedRefresh], timeout: 1)
        XCTAssertTrue(fixture.viewModel.targetPreviews.isEmpty)
        XCTAssertFalse(fixture.viewModel.policyCanBuildCandidates)
        let failedBuildCount = accounting.previewBuildCount
        XCTAssertGreaterThan(failedBuildCount, successfulBuildCount)

        behavior.shouldFail = false
        let retryRefresh = accounting.expectRefreshCompletion(description: "retried changed preview build") { _ in true }
        await fixture.viewModel.refresh()
        await fulfillment(of: [retryRefresh], timeout: 1)
        XCTAssertEqual(fixture.viewModel.targetPreviews, [Self.preview(for: availability.value)])
        XCTAssertTrue(fixture.viewModel.policyCanBuildCandidates)
        XCTAssertEqual(accounting.previewBuildCount, failedBuildCount + 1)
    }

    func testKeyedServiceStateProjectionUsesRuntimeReadinessAndCredentialState() {
        let row = makeServiceRow(id: .jev, displayName: "Jev")
        let token = UUID()
        var readinessLookups: [DecisionServiceID] = []

        let state = RouterSettingsViewModel.serviceState(
            for: .jev,
            in: [row],
            readinessForID: { id in
                readinessLookups.append(id)
                return .ready(generation: 3, policyVersion: "jev-v3")
            },
            credentialStatesByID: [
                .jev: .init(
                    readiness: .needsConfiguration(generation: 0, reason: "ignored"),
                    operationToken: token,
                    feedback: .succeeded("Key verified.")
                )
            ]
        )

        XCTAssertEqual(readinessLookups, [.jev])
        XCTAssertEqual(
            state,
            .init(
                readiness: .ready(generation: 3, policyVersion: "jev-v3"),
                operationToken: token,
                feedback: .succeeded("Key verified.")
            )
        )
    }

    func testKeyedServiceStateProjectionUsesCheckingFallbackWithoutReadiness() {
        let state = RouterSettingsViewModel.serviceState(
            for: .openAIDecisions,
            in: [makeServiceRow(id: .openAIDecisions, displayName: "OpenAI Decisions")],
            readinessForID: { _ in nil },
            credentialStatesByID: [:]
        )

        XCTAssertEqual(
            state,
            .init(
                readiness: .needsConfiguration(
                    generation: 0, reason: "Checking OpenAI Decisions…"
                ),
                operationToken: nil,
                feedback: .idle
            )
        )
    }

    func testKeyedServiceStateProjectionReturnsNilWithoutReadinessLookupForUnknownID() {
        var readinessLookups: [DecisionServiceID] = []

        let state = RouterSettingsViewModel.serviceState(
            for: .openAIDecisions,
            in: [makeServiceRow(id: .jev, displayName: "Jev")],
            readinessForID: { id in
                readinessLookups.append(id)
                return .ready(generation: 1, policyVersion: "unexpected")
            },
            credentialStatesByID: [:]
        )

        XCTAssertNil(state)
        XCTAssertTrue(readinessLookups.isEmpty)
    }

    private static func preview(
        for availability: AgentModelCatalog.AvailabilityContext
    ) -> RouterSettingsViewModel.TargetPreview {
        let modelRaw = availability.zaiConfigured ? "zai-configured" : "zai-unconfigured"
        return .init(
            utilityTier: "high",
            provider: .codexExec,
            displayName: modelRaw,
            target: .init(
                agentRaw: AgentProviderKind.codexExec.rawValue,
                modelRaw: modelRaw,
                reasoningEffortRaw: nil,
                modelParameters: []
            )
        )
    }

    private func makeServiceRow(
        id: DecisionServiceID,
        displayName: String
    ) -> RouterSettingsViewModel.ServiceRow {
        .init(
            id: id,
            displayName: displayName,
            isModelRouterEligible: true,
            isAutoEffortEligible: true,
            displayOrder: 100,
            presentation: nil
        )
    }

    private func drainMainRunLoop() async {
        for _ in 0 ..< 2 {
            await withCheckedContinuation { continuation in
                RunLoop.main.perform { continuation.resume() }
            }
            await Task.yield()
        }
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func testPresentation(
        title: String,
        actions: [DecisionServiceSettingsCredentialActionKind] = [
            .validateAndSaveSecret,
            .revalidateStoredSecret,
            .removeStoredSecret
        ]
    ) -> DecisionServiceSettingsPresentation {
        .init(
            title: title,
            summary: "Test settings",
            notices: [],
            disclosures: [],
            productStatus: nil,
            capabilities: [.init(id: "model-router", title: "Model Router")],
            secretFieldLabel: "Test API key",
            supportedCredentialActions: actions,
            links: []
        )
    }

    private struct Fixture {
        let store: GlobalSettingsStore
        let viewModel: RouterSettingsViewModel
        let workspace: WorkspaceManagerViewModel
        let runtime: AgentTaskRouterRuntime
        let api: APISettingsViewModel
    }

    private func makeFixture(
        policyUnavailable: Bool = false,
        settingsController: (any DecisionServiceConfigurationController)? = nil,
        secondarySettingsController: (any DecisionServiceConfigurationController)? = nil,
        customRegistrations: [DecisionServiceRegistration]? = nil,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        availabilityProvider: (@MainActor () -> AgentModelCatalog.AvailabilityContext)? = nil,
        targetPreviewBuilder: (@MainActor (AgentModelCatalog.AvailabilityContext) throws -> [RouterSettingsViewModel.TargetPreview])? = nil,
        refreshCompletionObserver: (@MainActor (AgentTaskRouterConfiguration) -> Void)? = nil,
        verifiedProviders: Set<AgentProviderKind>? = nil,
        directlyConnectedProviders: Set<AgentProviderKind> = [],
        selectedRaw: String? = "jev",
        backendCount: Int = 1,
        defaultBackendID: DecisionServiceID? = nil
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RouterSettings-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "RouterSettings.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
        try fileStore.save(GlobalSettingsDocument(scalarPreferences: .init(modelRouter: .init(enabled: false, selectedBackendRawValue: selectedRaw))))
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        let backend = SettingsTestBackend(policyUnavailable: policyUnavailable)
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let api = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            antigravityRuntimeInstalledProvider: { directlyConnectedProviders.contains(.antigravity) },
            devinRuntimeInstalledProvider: { directlyConnectedProviders.contains(.devin) }
        )
        api.isClaudeCodeConnected = directlyConnectedProviders.contains(.claudeCode)
        api.isCodexConnected = directlyConnectedProviders.contains(.codexExec)
        api.isOpenCodeConnected = directlyConnectedProviders.contains(.openCode)
        api.isCursorConnected = directlyConnectedProviders.contains(.cursor)
        api.isGrokBuildConnected = directlyConnectedProviders.contains(.grokBuild)
        api.refreshDirectCLIProviderConnectionState()
        if let verifiedProviders {
            api.test_completeContextBuilderProviderValidation(verifiedProviders: verifiedProviders)
        }
        addTeardownBlock { @MainActor in api.prepareForWindowClose() }
        let files = WorkspaceFilesViewModel()
        let prompt = PromptViewModel(
            fileManager: files, apiSettingsViewModel: api, windowID: -1919,
            settingsManager: WindowSettingsManager(windowID: -1919)
        )
        let workspace = WorkspaceManagerViewModel(fileManager: files, promptViewModel: prompt, performInitialWorkspaceActivation: false)
        let credentials = JevRouterCredentialService(secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let settings = settingsController.map {
            DecisionServiceConfigurationRegistration(
                presentation: testPresentation(title: "Jev by TypeSafe"),
                controller: $0
            )
        } ?? (policyUnavailable ? JevDecisionService.settingsRegistration(controller: credentials) : nil)
        var registrations: [DecisionServiceRegistration] = customRegistrations ?? []
        if customRegistrations == nil {
            if backendCount > 0 {
                registrations.append(.init(service: backend, configuration: settings))
            }
            if backendCount > 1 {
                let secondarySettings = secondarySettingsController.map {
                    DecisionServiceConfigurationRegistration(
                        presentation: testPresentation(title: "OpenAI Decisions"),
                        controller: $0
                    )
                }
                registrations.append(.init(
                    service: SettingsTestBackend(id: .openAIDecisions),
                    configuration: secondarySettings
                ))
            }
        }
        let runtime = try AgentTaskRouterRuntime(registrations: registrations, demandSource: store, defaultBackendID: defaultBackendID)
        addTeardownBlock { await runtime.teardown() }
        let viewModel = RouterSettingsViewModel(
            settingsStore: store,
            runtime: runtime,
            apiSettingsViewModel: api,
            workspaceManager: workspace,
            availabilityProvider: availabilityProvider ?? { availability },
            targetPreviewBuilder: targetPreviewBuilder,
            refreshCompletionObserver: refreshCompletionObserver
        )
        return Fixture(
            store: store,
            viewModel: viewModel,
            workspace: workspace,
            runtime: runtime,
            api: api
        )
    }
}

@MainActor
private final class MutableAvailabilityContext {
    var value: AgentModelCatalog.AvailabilityContext

    init(_ value: AgentModelCatalog.AvailabilityContext) {
        self.value = value
    }
}

@MainActor
private final class PreviewRefreshAccounting {
    private struct PendingRefreshCompletion {
        let predicate: (AgentTaskRouterConfiguration) -> Bool
        let complete: () -> Void
    }

    private var pendingRefreshCompletions: [PendingRefreshCompletion] = []
    private(set) var previewBuildCount = 0
    private(set) var refreshCompletionCount = 0

    func recordPreviewBuild() {
        previewBuildCount += 1
    }

    func expectRefreshCompletion(
        description: String,
        matching predicate: @escaping (AgentTaskRouterConfiguration) -> Bool
    ) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        pendingRefreshCompletions.append(.init(predicate: predicate, complete: { expectation.fulfill() }))
        return expectation
    }

    /// Await the subscription's real refresh, without scheduling one ourselves or timing main-run-loop delivery.
    func performAndAwaitRefresh(
        matching predicate: @escaping (AgentTaskRouterConfiguration) -> Bool,
        mutation: () -> Void
    ) async {
        await withCheckedContinuation { continuation in
            pendingRefreshCompletions.append(.init(predicate: predicate, complete: { continuation.resume() }))
            mutation()
        }
    }

    func recordRefreshCompletion(_ configuration: AgentTaskRouterConfiguration) {
        refreshCompletionCount += 1
        pendingRefreshCompletions.removeAll { pending in
            guard pending.predicate(configuration) else { return false }
            pending.complete()
            return true
        }
    }
}

@MainActor
private final class PreviewBuildBehavior {
    var shouldFail = false
}

private enum PreviewBuildError: Error {
    case unavailable
}

private actor SettingsTestController: DecisionServiceConfigurationController {
    let result: DecisionServiceSettingsActionResult
    private var actions: [DecisionServiceSettingsCredentialActionKind] = []
    private var bootstrapCalls = 0
    private var invalidationCalls = 0

    init(result: DecisionServiceSettingsActionResult) {
        self.result = result
    }

    func readinessSnapshot() -> DecisionReadiness {
        .ready(generation: 1, policyVersion: "test-v1")
    }

    func readinessUpdates() -> AsyncStream<DecisionReadiness> {
        AsyncStream { continuation in
            continuation.yield(.ready(generation: 1, policyVersion: "test-v1"))
            continuation.finish()
        }
    }

    func perform(_ action: DecisionServiceSettingsAction) -> DecisionServiceSettingsActionResult {
        actions.append(action.kind)
        return result
    }

    func callCount() -> Int {
        actions.count
    }

    func bootstrapCallCount() -> Int {
        bootstrapCalls
    }

    func invalidationCallCount() -> Int {
        invalidationCalls
    }

    func bootstrapStoredConfigurationIfNeeded() {
        bootstrapCalls += 1
    }

    func cancelAndAdvanceGeneration() {
        invalidationCalls += 1
    }
}

private actor StreamingSettingsController: DecisionServiceConfigurationController {
    private var state: DecisionReadiness
    private var continuations: [UUID: AsyncStream<DecisionReadiness>.Continuation] = [:]
    private var observationCount = 0
    private var observationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var actions: [DecisionServiceSettingsCredentialActionKind] = []

    init(initial: DecisionReadiness) {
        state = initial
    }

    func readinessSnapshot() -> DecisionReadiness {
        state
    }

    func readinessUpdates() -> AsyncStream<DecisionReadiness> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            observationCount += 1
            let ready = observationWaiters.filter { $0.0 <= observationCount }
            observationWaiters.removeAll { $0.0 <= observationCount }
            ready.forEach { $0.1.resume() }
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func readinessObservationCount() -> Int {
        observationCount
    }

    func waitUntilObserved(_ count: Int = 1) async {
        guard observationCount < count else { return }
        await withCheckedContinuation { observationWaiters.append((count, $0)) }
    }

    func send(_ readiness: DecisionReadiness) {
        state = readiness
        publish(readiness)
    }

    func perform(_ action: DecisionServiceSettingsAction) -> DecisionServiceSettingsActionResult {
        actions.append(action.kind)
        let nextGeneration = state.generation &+ 1
        switch action {
        case .removeStoredSecret:
            state = .needsConfiguration(generation: nextGeneration, reason: "Jev key required.")
            publish(state)
            return .succeeded("Stored key removed.")
        case .validateAndSaveSecret, .revalidateStoredSecret:
            state = .ready(generation: nextGeneration, policyVersion: "jev-v\(nextGeneration)")
            publish(state)
            return .succeeded("Jev credential updated.")
        }
    }

    func callCount() -> Int {
        actions.count
    }

    func bootstrapStoredConfigurationIfNeeded() {}
    func cancelAndAdvanceGeneration() {}

    private func publish(_ readiness: DecisionReadiness) {
        continuations.values.forEach { $0.yield(readiness) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

private actor SuspendedSettingsController: DecisionServiceConfigurationController {
    private var completions: [CheckedContinuation<DecisionServiceSettingsActionResult, Never>] = []
    private var calls = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func readinessSnapshot() -> DecisionReadiness {
        .ready(generation: 1, policyVersion: "test-v1")
    }

    func readinessUpdates() -> AsyncStream<DecisionReadiness> {
        AsyncStream { $0.yield(readinessSnapshot())
            $0.finish()
        }
    }

    func perform(_ action: DecisionServiceSettingsAction) async -> DecisionServiceSettingsActionResult {
        calls += 1
        let ready = waiters.filter { $0.0 <= calls }
        waiters.removeAll { $0.0 <= calls }
        ready.forEach { $0.1.resume() }
        return await withCheckedContinuation { completions.append($0) }
    }

    func waitUntilStarted() async {
        await waitForCalls(1)
    }

    func waitForCalls(_ count: Int) async {
        if calls < count { await withCheckedContinuation { waiters.append((count, $0)) } }
    }

    func completeFirst() {
        if !completions.isEmpty { completions.removeFirst().resume(returning: .succeeded("Stored key updated.")) }
    }

    func complete() {
        completions.forEach { $0.resume(returning: .succeeded("Stored key updated.")) }
        completions.removeAll()
    }

    func callCount() -> Int {
        calls
    }

    func bootstrapStoredConfigurationIfNeeded() {}
    func cancelAndAdvanceGeneration() {}
}

private struct SettingsTestBackend: DecisionService {
    var policyUnavailable = false
    var id = DecisionServiceID.jev
    var routerEligible = true
    var capabilities: DecisionServiceCapabilities {
        .init(
            contextKinds: [.text],
            finiteChoice: .init(
                minimumChoices: 2, maximumChoices: 12,
                maximumContextBytes: routerEligible ? 24 * 1024 : 100,
                maximumInstructionsBytes: 16 * 1024, maximumChoiceDescriptionBytes: 8 * 1024,
                maximumAggregateBytes: 128 * 1024
            ),
            evidence: .init(confidence: true, probabilityDistribution: true, usage: true)
        )
    }

    var displayName: String {
        id == .jev ? "Jev" : id.rawValue
    }

    func readinessSnapshot() async -> DecisionReadiness {
        policyUnavailable
            ? .policyUnavailable(generation: 0, reason: "Test backend is unavailable.")
            : .ready(generation: 1, policyVersion: "test-v1")
    }

    func decide(_ request: FiniteChoiceDecisionRequest) async -> DecisionOutcome {
        .cancelled
    }
}
