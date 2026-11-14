import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import XCTest

@MainActor
final class AgentRepromptSessionLinkIsolationTests: XCTestCase {
    /// These input tests exercise the legacy resource adapter, so its workspace owner must match
    /// the restored writer. A fabricated endpoint or a nil adapter workspace is not live admission.
    private func prepareManagedTarget(_ fixture: AgentRepromptTestFixture) throws -> WorkspaceManagerViewModel {
        let files = WorkspaceFilesViewModel()
        let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let api = APISettingsViewModel(aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, loadStoredDataOnInit: false)
        let prompt = PromptViewModel(fileManager: files, apiSettingsViewModel: api, windowID: -1, settingsManager: WindowSettingsManager(windowID: -1))
        let manager = WorkspaceManagerViewModel(fileManager: files, promptViewModel: prompt, performInitialWorkspaceActivation: false)
        let workspace = WorkspaceModel(
            name: "Managed input isolation", repoPaths: [], ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: fixture.session.tabID)], activeComposeTabID: fixture.session.tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        fixture.viewModel.workspaceManager = manager
        _ = try XCTUnwrap(fixture.viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: fixture.session, updateWorkspaceMetadata: true))
        fixture.session.hasLoadedPersistedState = true
        fixture.session.recordRestorationAuthoritative(.persistedPayloadApplied)
        return manager
    }

    func testNoncomposerUserTurnNeverStartsPreparationOrConsumesEnabledState() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.repromptEnabled = true
        fixture.viewModel.repromptService = .init(transport: { _, _, _ in XCTFail("Noncomposer input must not rewrite")
            throw CancellationError()
        })
        fixture.session.installRunID(UUID())
        fixture.session.runState = .running
        fixture.session.isMCPInstructionDispatchInProgress = true
        XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "External follow-up", tabID: fixture.session.tabID, isLocalComposerInput: false), .submitted)
        XCTAssertTrue(fixture.viewModel.repromptEnabled)
        XCTAssertNil(fixture.viewModel.repromptOperation)
        XCTAssertNil(fixture.viewModel.repromptUIStore.presentation)
        XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.providerText, "External follow-up")
        guard case .blocked = fixture.viewModel.submitUserTurn(text: "External", tabID: fixture.session.tabID, repromptedText: "Forbidden replacement", isLocalComposerInput: false)
        else { return XCTFail("External caller supplied a local replacement") }
    }

    func testManagedSteerBypassesRewriteAndKeepsInterviewAndDraft() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let manager = try prepareManagedTarget(fixture)
        defer { withExtendedLifetime(manager) {} }
        fixture.viewModel.repromptEnabled = true
        fixture.viewModel.interviewFirst = true
        fixture.viewModel.repromptService = .init(transport: { _, _, _ in XCTFail("Managed steer must not rewrite")
            throw CancellationError()
        })
        fixture.session.installRunID(UUID())
        fixture.session.runState = .running
        fixture.session.isMCPInstructionDispatchInProgress = true
        fixture.viewModel.storeDraftText(for: fixture.session.tabID, "Private local draft")
        let endpoint = try XCTUnwrap(fixture.viewModel.linkExecutionRuntime.agentSessionLinkObserverEndpoint(tabID: fixture.session.tabID))
        let turn = AgentNoncomposerTurn(endpoint: endpoint, providerText: "Managed envelope", sink: .init())
        XCTAssertTrue(fixture.viewModel.linkExecutionRuntime.submitNoncomposerSteer(
            tabID: fixture.session.tabID, session: fixture.session, displayText: "Managed instruction", turn: turn, route: .claudeInterrupt,
            environment: .init(workspaceID: endpoint.workspaceID, resourcesAreCurrent: { true }, settings: fixture.viewModel.modelRouterSettingsStore, server: nil)
        ))
        XCTAssertTrue(fixture.viewModel.repromptEnabled)
        XCTAssertTrue(fixture.viewModel.interviewFirst)
        XCTAssertEqual(fixture.session.draftText, "Private local draft")
        XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.providerText, "Managed envelope")
        XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.draftText, "")
        XCTAssertNil(fixture.viewModel.repromptOperation)
    }

    func testManagedInputWithMissingLegacyResourceOwnerRefusesWithoutMutation() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        try fixture.installPersistentWriter()
        fixture.session.hasLoadedPersistedState = true
        fixture.session.recordRestorationAuthoritative(.persistedPayloadApplied)
        fixture.session.installRunID(UUID())
        fixture.session.runState = .running
        fixture.session.isMCPInstructionDispatchInProgress = true
        fixture.viewModel.storeDraftText(for: fixture.session.tabID, "Private local draft")
        XCTAssertNil(fixture.session.operationAdmissionFailureMessage)
        let endpoint = try XCTUnwrap(fixture.viewModel.linkExecutionRuntime.agentSessionLinkObserverEndpoint(tabID: fixture.session.tabID))
        let turn = AgentNoncomposerTurn(endpoint: endpoint, providerText: "Do not dispatch", sink: .init())
        XCTAssertFalse(fixture.viewModel.submitNoncomposerSteer(
            tabID: fixture.session.tabID, session: fixture.session, displayText: "Do not append", turn: turn, route: .claudeInterrupt
        ))
        XCTAssertTrue(fixture.session.items.isEmpty)
        XCTAssertTrue(fixture.session.pendingClaudeSteeringInstructions.isEmpty)
        XCTAssertEqual(fixture.viewModel.draftRuntime.text(for: fixture.session.tabID), "Private local draft")
    }

    func testManagedInboundTargetReplacementRestoresLocalReviewOriginal() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let manager = try prepareManagedTarget(fixture)
        defer { withExtendedLifetime(manager) {} }
        fixture.session.installRunID(UUID())
        fixture.session.runState = .running
        fixture.session.isMCPInstructionDispatchInProgress = true
        fixture.enableReprompt()
        XCTAssertTrue(try fixture.begin(text: "Private original"))
        try await AsyncTestWait.waitUntil("local review", timeout: 5) { fixture.viewModel.repromptOperation?.phase == .completed }
        let endpoint = try XCTUnwrap(fixture.viewModel.linkExecutionRuntime.agentSessionLinkObserverEndpoint(tabID: fixture.session.tabID))
        let turn = AgentNoncomposerTurn(endpoint: endpoint, providerText: "Managed envelope", sink: .init())
        XCTAssertTrue(fixture.viewModel.linkExecutionRuntime.submitNoncomposerSteer(
            tabID: fixture.session.tabID, session: fixture.session, displayText: "Managed instruction", turn: turn, route: .claudeInterrupt,
            environment: .init(workspaceID: endpoint.workspaceID, resourcesAreCurrent: { true }, settings: fixture.viewModel.modelRouterSettingsStore, server: nil)
        ))
        // Provider admission of that inbound work replaces the native run target.
        fixture.session.installRunID(UUID())
        fixture.viewModel.invalidateRepromptIfNeeded()
        XCTAssertNil(fixture.viewModel.repromptOperation)
        XCTAssertEqual(fixture.session.draftText, "Private original")
        XCTAssertEqual(fixture.viewModel.repromptUIStore.recoveries[fixture.session.tabID]?.originalDraft, "Private original")
        XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.providerText, "Managed envelope")
    }

    func testHeldLocalClaimRemainsAnInboundDeliveryBlocker() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let claim = try fixture.claim(text: "Local draft")
        let held = AgentSessionLinkExecutionRuntime.agentSessionLinkDeliveryReadinessSnapshot(session: fixture.session, endpointMatchesGrant: true, isClosing: false)
        XCTAssertTrue(held.isComposerSubmissionInFlight)
        fixture.viewModel.releaseComposerSubmitClaim(claim)
        let released = AgentSessionLinkExecutionRuntime.agentSessionLinkDeliveryReadinessSnapshot(session: fixture.session, endpointMatchesGrant: true, isClosing: false)
        XCTAssertFalse(released.isComposerSubmissionInFlight)
    }
}
