import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentRepromptSessionLinkIsolationTests: XCTestCase {
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
        fixture.viewModel.repromptEnabled = true
        fixture.viewModel.interviewFirst = true
        fixture.viewModel.repromptService = .init(transport: { _, _, _ in XCTFail("Managed steer must not rewrite")
            throw CancellationError()
        })
        fixture.session.installRunID(UUID())
        fixture.session.runState = .running
        fixture.session.isMCPInstructionDispatchInProgress = true
        fixture.viewModel.storeDraftText(for: fixture.session.tabID, "Private local draft")
        let endpoint = DomainAgentSessionLinkEndpointIdentity(
            windowID: 1, workspaceID: UUID(), tabID: fixture.session.tabID, sessionID: UUID(),
            persistentBindingGeneration: UUID(), bindingTransitionGeneration: 0
        )
        let turn = AgentNoncomposerTurn(endpoint: endpoint, providerText: "Managed envelope", sink: .init())
        XCTAssertTrue(fixture.viewModel.submitNoncomposerSteer(tabID: fixture.session.tabID, session: fixture.session, displayText: "Managed instruction", turn: turn, route: .claudeInterrupt))
        XCTAssertTrue(fixture.viewModel.repromptEnabled)
        XCTAssertTrue(fixture.viewModel.interviewFirst)
        XCTAssertEqual(fixture.session.draftText, "Private local draft")
        XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.providerText, "Managed envelope")
        XCTAssertEqual(fixture.session.pendingClaudeSteeringInstructions.last?.draftText, "")
        XCTAssertNil(fixture.viewModel.repromptOperation)
    }

    func testManagedInboundTargetReplacementRestoresLocalReviewOriginal() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        _ = fixture.viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: fixture.session)
        fixture.session.hasLoadedPersistedState = true
        fixture.session.recordRestorationAuthoritative(.persistedPayloadApplied)
        fixture.session.installRunID(UUID())
        fixture.session.runState = .running
        fixture.session.isMCPInstructionDispatchInProgress = true
        fixture.enableReprompt()
        XCTAssertTrue(try fixture.begin(text: "Private original"))
        try await AsyncTestWait.waitUntil("local review", timeout: 5) { fixture.viewModel.repromptOperation?.phase == .completed }
        let endpoint = DomainAgentSessionLinkEndpointIdentity(windowID: 1, workspaceID: UUID(), tabID: fixture.session.tabID, sessionID: UUID(), persistentBindingGeneration: UUID(), bindingTransitionGeneration: 0)
        let turn = AgentNoncomposerTurn(endpoint: endpoint, providerText: "Managed envelope", sink: .init())
        XCTAssertTrue(fixture.viewModel.submitNoncomposerSteer(tabID: fixture.session.tabID, session: fixture.session, displayText: "Managed instruction", turn: turn, route: .claudeInterrupt))
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
        let held = AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(session: fixture.session, endpointMatchesGrant: true, isClosing: false)
        XCTAssertTrue(held.isComposerSubmissionInFlight)
        fixture.viewModel.releaseComposerSubmitClaim(claim)
        let released = AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(session: fixture.session, endpointMatchesGrant: true, isClosing: false)
        XCTAssertFalse(released.isComposerSubmissionInFlight)
    }
}
