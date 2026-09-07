import Combine
@testable import RepoPromptApp
import XCTest

@MainActor
final class SwitchboardSessionAvailabilityTests: XCTestCase {
    func testEntryRejectionDoesNotTerminalizeUntouchedOrExistingActiveOwnership() async throws {
        for isActive in [false, true] {
            let fence = CodexManagedSessionFence()
            let fixture = Fixture(fence: fence)
            try await fixture.connectAndApply()
            let ownership = fixture.session.beginRunAttempt(source: "synthetic-entry-rejection")
            if isActive {
                fixture.session.runState = .running
                fixture.session.runningStatusText = "Existing turn"
                fixture.viewModel.setAgentRunActive(fixture.session.tabID, isActive: true)
            }
            let priorState = fixture.session.runState
            _ = fence.beginLogout()
            let outcome = await fixture.viewModel.codexCoordinator.sendCodexNativeMessage(
                session: fixture.session, text: "Never dispatched", attachments: [], terminalizeRejectedSend: !isActive
            )
            if case .preDispatchRejected = outcome {} else { XCTFail("Logout must reject at entry") }
            XCTAssertEqual(fixture.session.runState, priorState)
            XCTAssertEqual(fixture.session.activeRunOwnership, ownership)
            XCTAssertEqual(fixture.session.runningStatusText, isActive ? "Existing turn" : nil)
            XCTAssertEqual(fixture.viewModel.tabsWithActiveAgentRun.contains(fixture.session.tabID), isActive)
            XCTAssertEqual(fixture.controller.startCalls, 0)
            await fixture.control.revokeAndWait()
        }
    }

    func testRealViewModelRevokesOnlyManagedAuthorityBeforeLogoutPublication() async throws {
        let fence = CodexManagedSessionFence()
        let first = Fixture(fence: fence)
        let second = Fixture(fence: fence)
        try await first.connectAndApply()
        try await second.connectAndApply()
        let ordinary = AgentTabSession(tabID: UUID())
        ordinary.selectedAgent = .codexExec
        ordinary.hasLoadedPersistedState = true
        let ordinaryController = Controller()
        ordinaryController.usesManagedHTTPAccountAdoption = false
        ordinary.codexController = ordinaryController
        let claude = AgentTabSession(tabID: UUID())
        claude.selectedAgent = .claudeCode
        claude.providerSessionID = "synthetic-ordinary-claude"
        claude.draftText = "Preserve ordinary draft"
        first.viewModel.test_installLiveSession(ordinary)
        first.viewModel.test_installLiveSession(claude)
        var published = false
        let observation = fence.$isLogoutInProgress.sink { inProgress in
            guard inProgress else { return }
            published = true
            XCTAssertNil(try? first.control.authorization.withAuthorization { true })
            XCTAssertNil(try? second.control.authorization.withAuthorization { true })
            XCTAssertTrue(ordinary.codexController === ordinaryController)
            XCTAssertFalse(ordinary.requiresSwitchboardPairing)
            XCTAssertEqual(claude.providerSessionID, "synthetic-ordinary-claude")
            XCTAssertEqual(claude.draftText, "Preserve ordinary draft")
        }
        let coordinator = CodexManagedLogoutCoordinator(fence: fence, logoutOperation: { .signedOut })
        let result = await coordinator.stopSessionsAndSignOut(participants: [first.viewModel, second.viewModel])
        XCTAssertTrue(published)
        XCTAssertEqual(result, .signedOut)
        XCTAssertEqual(claude.providerSessionID, "synthetic-ordinary-claude")
        XCTAssertEqual(claude.draftText, "Preserve ordinary draft")
        withExtendedLifetime(observation) {}
    }

    func testSuspendedSendRejectsInProgressAndChangedLogoutGeneration() async throws {
        for finishLogout in [false, true] {
            let fence = CodexManagedSessionFence()
            let fixture = Fixture(fence: fence)
            try await fixture.connectAndApply()
            fixture.session.codexControllerWorkspacePaths = .uniform("/synthetic-switchboard-no-files")
            fixture.session.codexControllerPermissionProfile = fixture.session.permissionProfile
            fixture.session.codexControllerFeatureState = .init(
                computerUseEnabled: false, goalSupportEnabled: false,
                reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled, memoriesEnabled: CodexMemories.isEnabled
            )
            let hookEntered = expectation(description: "Send reached its final hook await")
            fixture.controller.didEnterHooks = { hookEntered.fulfill() }
            // Production runner construction installs the real terminal barrier.
            // This direct coordinator test must do the same before owning a run.
            fixture.viewModel.test_initializeRunService()
            _ = fixture.session.beginRunAttempt(source: "synthetic-logout-send")
            let attachment = AgentImageAttachment(source: .url("https://synthetic.invalid/never-fetched.png"))
            let reservation = fixture.viewModel.reserveAttachmentsForTurn([attachment], session: fixture.session)
            let sending = Task {
                await fixture.viewModel.codexCoordinator.sendCodexNativeMessage(
                    session: fixture.session, text: "Synthetic gated send", attachments: [attachment],
                    attachmentReservationID: reservation
                )
            }
            await fulfillment(of: [hookEntered], timeout: 2)
            let logout = fence.beginLogout()
            if finishLogout { fence.finishLogout(token: logout, succeeded: true) }
            // No real logout/teardown: isolate stale generation admission while
            // the independent managed authority is deliberately still valid.
            XCTAssertNoThrow(try fixture.control.authorization.withAuthorization {})
            fixture.controller.resumeHooks()
            let outcome = await sending.value
            XCTAssertEqual(fixture.controller.startCalls, 0)
            if case .preDispatchRejected = outcome {} else { XCTFail("Stale logout generation must reject before provider dispatch") }
            XCTAssertFalse(fixture.session.runState.isActive)
            XCTAssertNil(fixture.session.runningStatusText)
            XCTAssertFalse(fixture.viewModel.tabsWithActiveAgentRun.contains(fixture.session.tabID))
            XCTAssertNil(fixture.session.activeRunOwnership)
            XCTAssertNil(fixture.session.codexPendingAuthRetryTurn)
            XCTAssertEqual(fixture.session.attachmentTurnState, .idle)
            XCTAssertTrue(fixture.session.pendingImageAttachments.contains(attachment))
            await fixture.control.revokeAndWait()
            fixture.session.codexEventTask?.cancel()
        }
    }

    func testOrdinaryCanonicalHistoryRefusesPairingBeforeManagedSetup() async throws {
        var controllerCreations = 0
        var policyChanges = 0
        var routingChanges = 0
        let fence = CodexManagedSessionFence()
        let viewModel = AgentModeViewModel(
            testAgentAvailability: AgentModelCatalog.AvailabilityContext.none, testManagedSessionFence: fence,
            testWorkspacePath: "/synthetic-switchboard-no-files",
            skillCatalog: AgentSkillCatalog(homeDirectoryURL: URL(fileURLWithPath: "/synthetic-switchboard-no-home")),
            codexControllerFactory: { _, _, _, _, _, _ in
                controllerCreations += 1
                return Controller()
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in policyChanges += 1 },
            mcpRunRoutingCleaner: { _, _, _ in routingChanges += 1 }
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.hasLoadedPersistedState = true
        session.transcript = AgentTranscript(turns: [AgentTranscriptTurn(
            request: .init(from: AgentChatItem(timestamp: Date(), kind: .user, text: "Synthetic canonical history")),
            terminalState: .completed, startedAt: Date()
        )])
        let retained = session.transcript
        let generation = session.codexControllerGeneration
        viewModel.test_installLiveSession(session)
        // Pairing is scoped to its captured tab even if the user changes tabs;
        // no active legacy-row projection is needed for canonical-only history.
        viewModel.test_setCurrentTabIDOverride(UUID())
        let envelope = try JSONSerialization.data(withJSONObject: [
            "v": 1, "socket_path": "/private/tmp/synthetic-never-connected/session.sock",
            "peer_pid": 1, "peer_start": ["seconds": 1, "microseconds": 0],
            "capability": SwitchboardBridgeTestData.capability,
            "expires_at": Int(Date().addingTimeInterval(120).timeIntervalSince1970)
        ])
        do {
            try await viewModel.pairSwitchboardSession(tabID: session.tabID, envelopeData: envelope)
            XCTFail("Ordinary canonical history must not be converted")
        } catch AgentModeViewModel.SwitchboardPairingFailure.legacySession {
            // This must be the early history refusal, not a later setup failure.
        } catch {
            XCTFail("Expected preflight legacy-session refusal")
        }
        XCTAssertEqual(session.transcript, retained)
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertNil(session.codexConversationID)
        XCTAssertNil(session.codexRolloutPath)
        XCTAssertNil(session.switchboardAccountControl)
        XCTAssertFalse(session.requiresSwitchboardPairing)
        XCTAssertNil(session.codexController)
        XCTAssertEqual(session.codexControllerGeneration, generation)
        XCTAssertEqual(controllerCreations, 0)
        XCTAssertEqual(policyChanges, 0)
        XCTAssertEqual(routingChanges, 0)
        XCTAssertTrue(viewModel.availableAgents.isEmpty)
        XCTAssertFalse(fence.isFenced)
    }

    func testDisconnectedAppliedRootCanSendWithoutGlobalConnection() async throws {
        let fixture = Fixture()
        try await fixture.connectAndApply()
        XCTAssertTrue(fixture.viewModel.canSendWithCurrentProvider)
        XCTAssertTrue(fixture.viewModel.makeComposerProps().canSendWithCurrentProvider)
        XCTAssertTrue(fixture.viewModel.makeComposerProps().hasAvailableAgentProviders)
        XCTAssertEqual(fixture.viewModel.makeComposerProps().availableAgents, [.codexExec])
        XCTAssertFalse(fixture.viewModel.modelOptions(for: .codexExec).isEmpty)
        XCTAssertFalse(fixture.viewModel.availableAgents.contains(.codexExec))
        await fixture.control.revokeAndWait()
    }

    func testPreparingUnpairedRevokedAndChildNeverBorrowGlobalConnection() async throws {
        for state in ["unpaired", "preparing", "revoked", "child", "wrongThread", "wrongSession"] {
            let fixture = Fixture(availability: .init())
            switch state {
            case "unpaired": fixture.session.switchboardAccountControl = nil
            case "preparing": break
            default:
                try await fixture.connectAndApply()
                switch state {
                case "revoked": fixture.control.revoke()
                case "child": fixture.session.parentSessionID = UUID()
                case "wrongThread": fixture.session.codexConversationID = "foreign-thread"
                default: _ = fixture.viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: fixture.session)
                }
            }
            XCTAssertFalse(fixture.viewModel.canSendWithCurrentProvider, state)
            XCTAssertFalse(fixture.viewModel.makeComposerProps().canSendWithCurrentProvider, state)
            await fixture.control.revokeAndWait()
        }
        let ordinary = Fixture()
        ordinary.session.requiresSwitchboardPairing = false
        ordinary.session.switchboardAccountControl = nil
        XCTAssertFalse(ordinary.viewModel.canSendWithCurrentProvider)
        await ordinary.control.revokeAndWait()
    }

    func testSettledAsyncApplicationAndRevocationRefreshComposerSnapshot() async throws {
        let fixture = Fixture()
        fixture.suspendInstall = true
        try await fixture.connect()
        fixture.viewModel.syncComposerUIState()
        let application = Task { await fixture.control.pollOnce() }
        while fixture.installContinuation == nil {
            await Task.yield()
        }
        XCTAssertFalse(fixture.viewModel.ui.composer.props.canSendWithCurrentProvider)
        fixture.installContinuation?.resume()
        fixture.installContinuation = nil
        await application.value
        XCTAssertFalse(fixture.control.blocksDispatch)
        XCTAssertTrue(fixture.viewModel.ui.composer.props.canSendWithCurrentProvider)
        fixture.control.revoke()
        XCTAssertFalse(fixture.viewModel.ui.composer.props.canSendWithCurrentProvider)
        await fixture.control.revokeAndWait()
    }

    func testAvailabilityRefreshPreservesUnpairedManagedProviderAndHistory() {
        let fixture = Fixture()
        fixture.viewModel.test_setAgentAvailabilityContext(.init(claudeCodeAvailable: true, codexAvailable: false))
        XCTAssertEqual(fixture.viewModel.selectedAgent, .codexExec)
        XCTAssertEqual(fixture.session.selectedAgent, .codexExec)
        XCTAssertEqual(fixture.session.codexConversationID, "synthetic-retained")
    }

    func testCompletedGlobalLogoutFenceDoesNotBlockIndependentLiveAuthority() async throws {
        let fence = CodexManagedSessionFence()
        let token = fence.beginLogout()
        fence.finishLogout(token: token, succeeded: true)
        let fixture = Fixture(fence: fence)
        try await fixture.connectAndApply()
        XCTAssertTrue(fence.isFenced)
        XCTAssertTrue(fixture.viewModel.canSendWithCurrentProvider)
        let activeLogout = fence.beginLogout()
        XCTAssertFalse(fixture.viewModel.canSendWithCurrentProvider)
        fixture.control.revoke()
        fence.finishLogout(token: activeLogout, succeeded: true)
        XCTAssertFalse(fixture.viewModel.canSendWithCurrentProvider)
        await fixture.control.revokeAndWait()
    }

    func testControlReplacementInvalidatesCapturedComposerTarget() async throws {
        let fixture = Fixture()
        try await fixture.connectAndApply()
        let captured = try XCTUnwrap(fixture.viewModel.makeComposerProps().submitTarget)
        fixture.session.switchboardAccountControl = CodexSwitchboardSessionControl()
        XCTAssertThrowsError(try fixture.control.authorization.withAuthorization {})
        XCTAssertNotEqual(captured.expectedSubmissionToken, fixture.session.composerSubmissionToken)
        XCTAssertFalse(fixture.viewModel.ui.composer.props.canSendWithCurrentProvider)
        let attempt = AgentComposerSubmitAttempt(id: UUID(), target: captured, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: "retained draft")
        guard case .rejected = fixture.viewModel.claimComposerSubmitAttempt(attempt) else {
            XCTFail("A captured target must not be rebound to a replacement control")
            return
        }
        await fixture.control.revokeAndWait()
        await fixture.session.switchboardAccountControl?.revokeAndWait()
    }

    func testNewEntryCreatesSeparateUnpairedRootAndNeverRepurposesHistory() async {
        let fixture = Fixture()
        await fixture.control.revokeAndWait()
        fixture.session.switchboardAccountControl = nil
        fixture.session.requiresSwitchboardPairing = false
        fixture.session.codexController = nil
        fixture.session.selectedAgent = .claudeCode
        fixture.session.providerSessionID = "ordinary-claude-history"
        fixture.session.draftText = "Keep this ordinary draft"
        let retainedID = fixture.session.activeAgentSessionID
        let fresh = AgentTabSession(tabID: UUID())
        let created = await fixture.viewModel.createAndActivateSwitchboardSessionTab(createFreshTab: {
            fixture.viewModel.test_installLiveSession(fresh)
            fixture.viewModel.test_setCurrentTabIDOverride(fresh.tabID)
            fixture.viewModel.markSessionAsFreshlyCreated(fresh)
            return fresh.tabID
        })
        XCTAssertEqual(created, fresh.tabID)
        XCTAssertEqual(fixture.viewModel.selectedAgent, .codexExec)
        XCTAssertEqual(fixture.viewModel.ui.statusPills.snapshot.selectedAgent, .codexExec)
        XCTAssertTrue(fresh.requiresSwitchboardPairing)
        XCTAssertEqual(fresh.selectedAgent, .codexExec)
        XCTAssertNil(fresh.parentSessionID)
        XCTAssertNil(fresh.codexController)
        XCTAssertNil(fresh.switchboardAccountControl)
        XCTAssertNil(fresh.providerSessionID)
        XCTAssertNil(fresh.codexConversationID)
        XCTAssertTrue(fresh.items.isEmpty)
        XCTAssertFalse(fixture.viewModel.makeComposerProps().canSendWithCurrentProvider)
        XCTAssertEqual(fixture.session.providerSessionID, "ordinary-claude-history")
        XCTAssertEqual(fixture.session.draftText, "Keep this ordinary draft")
        XCTAssertEqual(fixture.session.activeAgentSessionID, retainedID)
        let refused = await fixture.viewModel.createAndActivateSwitchboardSessionTab(createFreshTab: { fixture.session.tabID })
        XCTAssertNil(refused)
        XCTAssertEqual(fixture.session.selectedAgent, .claudeCode)
        XCTAssertFalse(fixture.session.requiresSwitchboardPairing)
    }

    func testStaleControlCallbackCannotRefreshReplacementOrAnotherTab() async throws {
        let fixture = Fixture()
        try await fixture.connectAndApply()
        let previousCallback = fixture.control.availabilityDidChange
        let replacement = AgentTabSession(tabID: fixture.session.tabID)
        fixture.viewModel.test_installLiveSession(replacement)
        fixture.viewModel.syncComposerUIState()
        let before = fixture.viewModel.ui.composer.props
        previousCallback?()
        XCTAssertEqual(fixture.viewModel.ui.composer.props, before)
        await fixture.control.revokeAndWait()
    }

    func testNewEntryRefusesLogoutAndWorkspaceChangeBeforeGrantingManagedMarker() async {
        let fence = CodexManagedSessionFence()
        let fixture = Fixture(fence: fence)
        let logout = fence.beginLogout()
        var creates = 0
        let whileLoggingOut = await fixture.viewModel.createAndActivateSwitchboardSessionTab(createFreshTab: {
            creates += 1
            return UUID()
        })
        XCTAssertNil(whileLoggingOut)
        XCTAssertEqual(creates, 0)
        fence.finishLogout(token: logout, succeeded: true)
        let fresh = AgentTabSession(tabID: UUID())
        let changedWorkspace = await fixture.viewModel.createAndActivateSwitchboardSessionTab(createFreshTab: {
            fixture.viewModel.test_installLiveSession(fresh)
            fixture.viewModel.test_setActiveWorkspaceIDForSessionIndex(UUID())
            return fresh.tabID
        })
        XCTAssertNil(changedWorkspace)
        XCTAssertFalse(fresh.requiresSwitchboardPairing)
        XCTAssertNil(fresh.switchboardAccountControl)
        await fixture.control.revokeAndWait()
    }

    func testOrdinaryConnectedSessionKeepsItsGlobalAvailabilityContract() async {
        let fixture = Fixture(availability: .init())
        fixture.session.requiresSwitchboardPairing = false
        fixture.session.switchboardAccountControl = nil
        fixture.controller.usesManagedHTTPAccountAdoption = false
        XCTAssertTrue(fixture.viewModel.canSendWithCurrentProvider)
        fixture.viewModel.test_setAgentAvailabilityContext(.none)
        XCTAssertFalse(fixture.viewModel.canSendWithProvider(.codexExec, session: fixture.session))
        await fixture.control.revokeAndWait()
    }

    @MainActor private final class Fixture {
        let viewModel: AgentModeViewModel
        let session = AgentTabSession(tabID: UUID())
        let controller = Controller()
        let control = CodexSwitchboardSessionControl()
        let bridge = Bridge()
        var suspendInstall = false
        var installContinuation: CheckedContinuation<Void, Never>?

        init(availability: AgentModelCatalog.AvailabilityContext = .none, fence: CodexManagedSessionFence? = nil) {
            viewModel = AgentModeViewModel(
                testAgentAvailability: availability, testManagedSessionFence: fence ?? CodexManagedSessionFence(),
                testWorkspacePath: "/synthetic-switchboard-no-files",
                skillCatalog: AgentSkillCatalog(homeDirectoryURL: URL(fileURLWithPath: "/synthetic-switchboard-no-home")),
                codexControllerFactory: { _, _, _, _, _, _ in fatalError("Availability tests never launch a backend") },
                connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
                mcpRunRoutingCleaner: { _, _, _ in }
            )
            session.selectedAgent = .codexExec
            session.requiresSwitchboardPairing = true
            session.hasLoadedPersistedState = true
            session.codexController = controller
            session.codexConversationID = "synthetic-retained"
            viewModel.test_installLiveSession(session)
            viewModel.test_setCurrentTabIDOverride(session.tabID)
            _ = viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session)
            session.switchboardAccountControl = control
            viewModel.selectedAgent = .codexExec
        }

        var scope: CodexAccountAdoptionScope {
            .init(consentID: consentID, sessionID: session.activeAgentSessionID!, controllerGeneration: session.codexControllerGeneration, threadID: "synthetic-retained")
        }

        private let consentID = UUID()
        func connect() async throws {
            let pinned = scope
            try await control.connect(scope: pinned, bridge: bridge, runtime: .init(
                admission: { .init(
                    scope: pinned,
                    isExplicitRootCodexSession: true,
                    isManagedHTTPBackend: true,
                    isIdle: true,
                    hasPendingInteraction: false,
                    hasActiveTools: false,
                    hasActiveChildren: false,
                    hasQueuedDispatch: false,
                    hasRecoveryOrReconnect: false
                ) },
                inspect: { .init(
                    threadID: pinned.threadID,
                    loadedThreadIDs: [pinned.threadID],
                    isAuthoritativelyIdle: true,
                    hasInProgressTools: false,
                    managedHTTP: true,
                    pinnedRuntime: true
                ) },
                reserve: { UUID() }, finish: { _, _ in }, install: { [weak self] _ in
                    if let self, suspendInstall { await withCheckedContinuation { self.installContinuation = $0 } }
                    return .init(externalTokenLogin: true, isChatGPTAccount: true, email: nil)
                }
            ))
        }

        func connectAndApply() async throws {
            try await connect()
            await control.pollOnce()
            XCTAssertFalse(control.blocksDispatch)
        }
    }

    private actor Bridge: CodexSwitchboardBridge {
        let grant = CodexAccountAdoptionGrant(
            adoptionID: UUID(),
            selectionID: UUID(),
            revision: 1,
            expiresAt: Date().addingTimeInterval(600),
            accountID: "synthetic-account",
            email: nil,
            plan: nil,
            accessToken: "synthetic-availability-token"
        )
        func register(threadID: String?) {}
        func poll(lastSeenRevision: Int64) -> CodexAccountAdoptionGrant? {
            lastSeenRevision == 0 ? grant : nil
        }

        func refresh(previousGrant: CodexAccountAdoptionGrant) throws -> CodexAccountAdoptionGrant {
            throw CodexAccountAdoptionReason.bridgeUnavailable
        }

        func status(adoptionID: UUID, expectedRevision: Int64, state: String, reason: String) {}
        func revoke() {}
    }

    private final class Controller: CodexSessionControlling {
        var startCalls = 0
        var didEnterHooks: (() -> Void)?
        private var hooksContinuation: CheckedContinuation<Void, Never>?
        private var hooksReleased = false

        func listHooksForCurrentWorkspace() async throws -> CodexHookInventory {
            if !hooksReleased {
                await withCheckedContinuation { continuation in
                    hooksContinuation = continuation
                    didEnterHooks?()
                }
            }
            return try CodexHookInventory(executionCWD: "/synthetic-switchboard-no-files", hooks: [])
        }

        func resumeHooks() {
            hooksReleased = true
            hooksContinuation?.resume()
            hooksContinuation = nil
        }

        var hasActiveThread = true
        var usesManagedHTTPAccountAdoption = true
        let currentSessionReference: CodexNativeSessionController.SessionRef? = .init(conversationID: "synthetic-retained")
        let events = AsyncStream<CodexNativeSessionController.Event> { _ in }
        func ensureEventsStreamReady() {}
        func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
            throw CodexAccountAdoptionReason.runtimeUnavailable
        }

        func startUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexTurnStartReceipt {
            startCalls += 1
            throw CodexAccountAdoptionReason.runtimeUnavailable
        }

        func steerUserTurn(text: String, images: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
            throw CodexAccountAdoptionReason.runtimeUnavailable
        }

        func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
            throw CodexAccountAdoptionReason.runtimeUnavailable
        }

        func cancelCurrentTurn() async {}
        func shutdown() async {}
        func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
    }
}
