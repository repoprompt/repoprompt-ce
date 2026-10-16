import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Binding-qualified hydration proof and owner-qualified discovery levels.
///
/// Automatic restoration may not reauthorize from `hasLoadedPersistedState`, because a missing
/// payload, a superseded source revision, and a thrown load error all set that latch true. These
/// tests pin the narrower fact restoration is allowed to act on, and the level bookkeeping that lets
/// it tell "this window has not described its bindings yet" from "that session is genuinely absent".
@MainActor
final class AgentSessionOversightReadinessTests: XCTestCase {
    private var retained: [AgentModeViewModel] = []
    private var retainedManagers: [WorkspaceManagerViewModel] = []

    override func tearDown() {
        retained.removeAll()
        retainedManagers.removeAll()
        super.tearDown()
    }

    private func makeSession() -> AgentModeViewModel.TabSession {
        AgentModeViewModel.TabSession(tabID: UUID())
    }

    private func makeViewModel() -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            testWindowID: 71,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        return viewModel
    }

    private func bind(_ session: AgentModeViewModel.TabSession, sessionID: UUID = UUID()) {
        _ = session.beginPersistentBindingTransition()
        session.installPersistentSessionBinding(
            AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: sessionID)
        )
    }

    private func makeCreation() throws -> (
        AgentModeViewModel.TabSession, AgentSessionCreationClaim, AgentSessionCreationHandle
    ) {
        let session = makeSession()
        let claim = AgentSessionCreationClaim(workspaceID: UUID())
        bind(session, sessionID: claim.sessionID)
        let handle = try XCTUnwrap(session.acceptFreshCreation(claim, workspaceID: claim.workspaceID))
        return (session, claim, handle)
    }

    // MARK: - Readiness

    func testUnboundTabProvesNothing() {
        let session = makeSession()
        XCTAssertEqual(session.qualifiedRestorationReadiness, .unbound)

        // A record against no binding is a no-op rather than an unattributable proof.
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        XCTAssertEqual(session.qualifiedRestorationReadiness, .unbound)
    }

    func testInstallingABindingStartsPendingAndPayloadApplicationProvesIt() throws {
        let session = makeSession()
        bind(session)

        let token = try XCTUnwrap(session.currentRestorationBindingToken)
        XCTAssertEqual(session.qualifiedRestorationReadiness, .pending(token))

        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        XCTAssertEqual(session.qualifiedRestorationReadiness, .authoritative(token, .persistedPayloadApplied))
    }

    func testTerminalProofIsRecordedAndIsNotAuthoritative() throws {
        let session = makeSession()
        bind(session)
        let token = try XCTUnwrap(session.currentRestorationBindingToken)

        session.recordRestorationTerminal(.missingPayload)
        XCTAssertEqual(session.qualifiedRestorationReadiness, .terminal(token, .missingPayload))
        XCTAssertFalse(session.qualifiedRestorationReadiness.isAuthoritative)
        XCTAssertEqual(session.qualifiedRestorationReadiness.terminalFailure, .missingPayload)
    }

    /// A missing payload does not prove that this runtime allocated the session. A generic save
    /// acknowledgment must not authorize replacing data that failed to restore.
    func testGenericFreshSaveAcknowledgmentCannotPromoteTerminalRestoration() throws {
        let session = makeSession()
        bind(session)
        session.recordRestorationTerminal(.missingPayload)

        session.recordRestorationAuthoritativeIfNeeded(.freshBindingDurablyCreated)

        let token = try XCTUnwrap(session.currentRestorationBindingToken)
        XCTAssertEqual(session.qualifiedRestorationReadiness, .terminal(token, .missingPayload))
        XCTAssertFalse(session.permitsBoundOperationAndSave)
        XCTAssertNil(session.captureCreationRetryHandle())
        XCTAssertEqual(
            session.restorationAdmissionFailureMessage,
            "This session could not be restored. Retry loading it or create a new session; its saved data has not been replaced."
        )
    }

    func testOnlyExactConfiguredAcknowledgmentReleasesCreationOwner() throws {
        let (session, claim, handle) = try makeCreation()
        let stamp = Data("configured payload".utf8)
        let otherStamp = Data("different payload".utf8)
        XCTAssertEqual(claim.creationHandle, handle)
        XCTAssertEqual(session.creationState?.phase, .preparing)
        XCTAssertTrue(session.hasLoadedPersistedState)
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(session.permitsBoundOperationAndSave)
        XCTAssertNil(session.captureCreationRetryHandle())
        XCTAssertFalse(session.acknowledgeConfiguredCreationSave(handle, configurationStamp: stamp))

        // A late generic loader/save result cannot replace the active creation owner.
        session.recordRestorationTerminal(.missingPayload)
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        session.recordRestorationAuthoritativeIfNeeded(.freshBindingDurablyCreated)
        XCTAssertEqual(session.creationState?.phase, .preparing)

        XCTAssertTrue(session.markCreationReady(handle, configurationStamp: stamp))
        XCTAssertTrue(session.markCreationReady(handle, configurationStamp: stamp))
        XCTAssertFalse(session.markCreationReady(handle, configurationStamp: otherStamp))
        XCTAssertFalse(session.permitsBoundOperationAndSave)
        let retry = try XCTUnwrap(session.captureCreationRetryHandle())
        XCTAssertEqual(retry.expectedConfigurationStamp, stamp)
        XCTAssertEqual(session.captureCreationRetryHandle(), retry)
        XCTAssertNotEqual(retry, handle)
        XCTAssertTrue(session.creationHandleIsCurrent(retry))
        XCTAssertFalse(session.acknowledgeConfiguredCreationSave(retry, configurationStamp: otherStamp))

        session.failCreationPreparation(handle, message: "Late preparation failure.")
        XCTAssertEqual(session.creationConfigurationStamp, stamp)
        XCTAssertTrue(session.acknowledgeConfiguredCreationSave(retry, configurationStamp: stamp))
        XCTAssertEqual(
            session.qualifiedRestorationReadiness,
            .authoritative(handle.bindingToken, .freshBindingDurablyCreated)
        )
        XCTAssertTrue(session.permitsBoundOperationAndSave)
        XCTAssertNil(session.restorationAdmissionFailureMessage)
        XCTAssertNil(session.captureCreationRetryHandle())
        XCTAssertFalse(session.creationHandleIsCurrent(handle))
        XCTAssertFalse(session.acknowledgeConfiguredCreationSave(retry, configurationStamp: stamp))
        session.failCreationPreparation(handle, message: "Late preparation failure.")
        XCTAssertTrue(session.permitsBoundOperationAndSave)
    }

    func testFailedPreparationCannotBecomeConfiguredOrRetryable() throws {
        let (session, _, handle) = try makeCreation()
        let message = "Could not prepare the requested worktree."
        session.failCreationPreparation(handle, message: message)

        XCTAssertEqual(session.creationState?.phase, .failedBeforeConfiguration(message))
        XCTAssertEqual(session.restorationAdmissionFailureMessage, message + " Create a new session to try again.")
        XCTAssertFalse(session.permitsBoundOperationAndSave)
        XCTAssertNil(session.captureCreationRetryHandle())
        let stamp = Data("partial recovery payload".utf8)
        XCTAssertFalse(session.markCreationReady(handle, configurationStamp: stamp))
        XCTAssertFalse(session.acknowledgeConfiguredCreationSave(handle, configurationStamp: stamp))
        session.recordRestorationAuthoritativeIfNeeded(.freshBindingDurablyCreated)
        XCTAssertEqual(session.creationState?.phase, .failedBeforeConfiguration(message))
    }

    func testCreationReceiptCannotActOnSameIDReplacementOrRebinding() throws {
        let (session, claim, handle) = try makeCreation()
        let stamp = Data("configured payload".utf8)
        XCTAssertTrue(session.markCreationReady(handle, configurationStamp: stamp))
        let retry = try XCTUnwrap(session.captureCreationRetryHandle())
        let replacement = AgentModeViewModel.TabSession(tabID: session.tabID)
        replacement.installPersistentSessionBinding(handle.bindingToken.bindingIdentity)
        XCTAssertFalse(replacement.creationHandleIsCurrent(handle))
        XCTAssertFalse(replacement.acknowledgeConfiguredCreationSave(retry, configurationStamp: stamp))

        bind(session, sessionID: claim.sessionID)
        XCTAssertFalse(session.creationHandleIsCurrent(handle))
        XCTAssertFalse(session.creationHandleIsCurrent(retry))
        XCTAssertFalse(session.markCreationReady(handle, configurationStamp: stamp))
        XCTAssertFalse(session.acknowledgeConfiguredCreationSave(retry, configurationStamp: stamp))
        XCTAssertNil(session.acceptFreshCreation(claim, workspaceID: claim.workspaceID))
        let current = try XCTUnwrap(session.currentRestorationBindingToken)
        XCTAssertEqual(session.qualifiedRestorationReadiness, .pending(current))
    }

    func testRejectedCreationClaimCannotBeReusedWithCorrectedWorkspace() throws {
        let session = makeSession()
        let claim = AgentSessionCreationClaim(workspaceID: UUID())
        bind(session, sessionID: claim.sessionID)

        XCTAssertNil(session.acceptFreshCreation(claim, workspaceID: UUID()))
        XCTAssertNil(claim.creationHandle)
        XCTAssertNil(session.acceptFreshCreation(claim, workspaceID: claim.workspaceID))
        let current = try XCTUnwrap(session.currentRestorationBindingToken)
        XCTAssertEqual(session.qualifiedRestorationReadiness, .pending(current))
    }

    func testLaterDurableSaveDoesNotRelabelAPayloadAppliedProof() throws {
        let session = makeSession()
        bind(session)
        session.recordRestorationAuthoritative(.persistedPayloadApplied)

        session.recordRestorationAuthoritativeIfNeeded(.freshBindingDurablyCreated)

        let token = try XCTUnwrap(session.currentRestorationBindingToken)
        XCTAssertEqual(session.qualifiedRestorationReadiness, .authoritative(token, .persistedPayloadApplied))
    }

    /// The whole point of qualifying the proof: a rebound tab must wait for a fresh hydration rather
    /// than inherit the previous incarnation's authorization.
    func testProofDoesNotSurviveARebindEvenToTheSameSessionID() throws {
        let session = makeSession()
        let sessionID = UUID()
        bind(session, sessionID: sessionID)
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        XCTAssertTrue(session.qualifiedRestorationReadiness.isAuthoritative)

        bind(session, sessionID: sessionID)

        let token = try XCTUnwrap(session.currentRestorationBindingToken)
        XCTAssertEqual(session.qualifiedRestorationReadiness, .pending(token))
        XCTAssertFalse(session.qualifiedRestorationReadiness.isAuthoritative)
    }

    func testTerminalProofAlsoDoesNotSurviveARebind() throws {
        let session = makeSession()
        bind(session)
        session.recordRestorationTerminal(.loadFailed)

        bind(session)

        let token = try XCTUnwrap(session.currentRestorationBindingToken)
        XCTAssertEqual(session.qualifiedRestorationReadiness, .pending(token))
    }

    func testUnbindingClearsTheProof() {
        let session = makeSession()
        bind(session)
        session.recordRestorationAuthoritative(.persistedPayloadApplied)

        _ = session.beginPersistentBindingTransition()
        session.installPersistentSessionBinding(nil)

        XCTAssertEqual(session.qualifiedRestorationReadiness, .unbound)
    }

    // MARK: - Discovery levels

    func testDiscoveryLevelStartsPendingAndIsSettledByItsOwnActivation() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.agentSessionLinkDiscoveryState.isComplete)

        let epoch = viewModel.beginAgentSessionLinkDiscoveryEpoch(workspaceID: UUID())
        XCTAssertFalse(viewModel.agentSessionLinkDiscoveryState.isComplete)

        viewModel.completeAgentSessionLinkDiscoveryEpoch(epoch)
        XCTAssertTrue(viewModel.agentSessionLinkDiscoveryState.isComplete)
        XCTAssertEqual(viewModel.agentSessionLinkDiscoveryState.epoch, epoch)
    }

    /// An activation that was superseded while suspended must not declare its successor's bindings
    /// settled when it finally resumes and exits.
    func testStaleActivationCannotSettleASuccessorLevel() {
        let viewModel = makeViewModel()
        let stale = viewModel.beginAgentSessionLinkDiscoveryEpoch(workspaceID: UUID())
        let current = viewModel.beginAgentSessionLinkDiscoveryEpoch(workspaceID: UUID())

        viewModel.completeAgentSessionLinkDiscoveryEpoch(stale)
        XCTAssertFalse(viewModel.agentSessionLinkDiscoveryState.isComplete)

        viewModel.completeAgentSessionLinkDiscoveryEpoch(current)
        XCTAssertTrue(viewModel.agentSessionLinkDiscoveryState.isComplete)
    }

    /// A window that registers with no workspace still has to settle: leaving it pending forever
    /// would make restoration wait on a window that will never register a binding.
    func testWindowWithNoWorkspaceStillSettlesItsLevel() {
        let viewModel = makeViewModel()
        let epoch = viewModel.beginAgentSessionLinkDiscoveryEpoch(workspaceID: nil)
        viewModel.completeAgentSessionLinkDiscoveryEpoch(epoch)
        XCTAssertTrue(viewModel.agentSessionLinkDiscoveryState.isComplete)
        XCTAssertNil(viewModel.agentSessionLinkDiscoveryState.epoch.workspaceID)
    }

    /// Descriptors are built from the workspace model, so a background tab that has never been
    /// visited — and therefore has no live `TabSession` and no candidate — is still described.
    func testComposeTabDescriptorsCoverLazyBindingsThatHaveNoLiveCandidate() {
        let viewModel = makeViewModel()
        let visitedTabID = UUID()
        let manager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: visitedTabID,
            name: "Oversight"
        )
        retainedManagers.append(manager)

        let visitedSessionID = UUID()
        let lazyTabID = UUID()
        let lazySessionID = UUID()
        var workspace = manager.workspaces[0]
        workspace.composeTabs = [
            ComposeTabState(id: visitedTabID, activeAgentSessionID: visitedSessionID),
            ComposeTabState(id: lazyTabID, activeAgentSessionID: lazySessionID),
            // No binding yet: nothing durable to restore, so it must not be described.
            ComposeTabState(id: UUID())
        ]
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace

        let descriptors = viewModel.agentSessionLinkComposeTabDescriptors()

        XCTAssertEqual(Set(descriptors.map(\.sessionID)), [visitedSessionID, lazySessionID])
        XCTAssertTrue(
            viewModel.agentSessionLinkCandidates(isWindowClosing: false).isEmpty,
            "Neither tab was hydrated, so describing them must not have produced live candidates."
        )
    }
}
