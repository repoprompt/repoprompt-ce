import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRepromptPresentationTests: XCTestCase {
    func testDisclosurePersistsAcrossWindowsButNotProviderChanges() throws {
        let suite = "AgentRepromptDisclosureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(AgentRepromptDisclosure.isAcknowledged(providerID: "one", defaults: defaults))
        AgentRepromptDisclosure.acknowledge(providerID: "one", defaults: defaults)
        let anotherWindow = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(AgentRepromptDisclosure.isAcknowledged(providerID: "one", defaults: anotherWindow))
        XCTAssertFalse(AgentRepromptDisclosure.isAcknowledged(providerID: "two", defaults: anotherWindow))
        AgentRepromptDisclosure.acknowledge(providerID: "two", defaults: anotherWindow)
        XCTAssertFalse(AgentRepromptDisclosure.isAcknowledged(providerID: "one", defaults: defaults))
    }

    func testReviewValidationAndTimeoutFreeWizardPulse() {
        let store = AgentRepromptUIStore()
        store.presentation = .init(id: UUID(), sourceTabID: UUID(), original: "Original", modelName: "Oracle", phase: .reviewing)
        for invalid in ["", " \n", String(repeating: "x", count: 64 * 1024 + 1)] {
            store.reviewText = invalid
            XCTAssertFalse(store.canApprove)
        }
        store.reviewText = "An edited brief"
        XCTAssertTrue(store.canApprove)
        store.presentation?.phase = .generating
        XCTAssertFalse(store.canApprove)
        XCTAssertEqual(AgentAskUserWizardCard.activityInterval(timeoutSeconds: 0.1, showsTimeout: false), 1)
        XCTAssertEqual(AgentAskUserWizardCard.activityInterval(timeoutSeconds: 300, showsTimeout: false), 1)
        XCTAssertEqual(AgentAskUserWizardCard.activityInterval(timeoutSeconds: 0.1, showsTimeout: true), 0.05)
    }

    func testClarificationHasNoPreselectionAndSkipReachesMandatoryReview() async throws {
        let store = AgentRepromptUIStore()
        let body = AgentRepromptServiceTests.valid.replacingOccurrences(of: "\"openQuestions\":[]", with: "\"openQuestions\":[{\"id\":\"scope\",\"question\":\"Which scope?\",\"options\":[{\"label\":\"Small\"},{\"label\":\"Large\"}]}]")
        let operation = AgentRepromptOperation(sourceTabID: UUID(), rawDraft: "Original", request: .init(originalText: "Original"), model: .gpt61Sol, service: .init(transport: { _, _ in body }), store: store, consultant: nil, isCurrent: { true })
        let task = Task { await operation.prepare() }
        try await AsyncTestWait.waitUntil("clarification", timeout: 3) { store.presentation?.phase == .clarifying }
        let drafts = try XCTUnwrap(store.pendingQuestions?.draftsByQuestionID)
        XCTAssertTrue(drafts.values.allSatisfy { $0.selectedOptionLabels.isEmpty && $0.customResponse.isEmpty && !$0.skipped })
        operation.completeQuestions(skipAll: true)
        try await AsyncTestWait.waitUntil("review", timeout: 3) { store.presentation?.phase == .reviewing }
        XCTAssertNil(operation.terminal)
        store.reviewText = "My final edit"
        operation.approve()
        guard case let .approved(text) = await task.value else { return XCTFail("Expected explicit approval") }
        XCTAssertEqual(text, "My final edit")
    }

    func testRejectedDispatchRestoresOriginalDraftAndRecoversApprovedBriefSeparately() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.restoreRejectedManualSubmissionComposerState(
            repromptedText: "Approved edited brief", tabID: fixture.session.tabID, session: fixture.session,
            draftText: "Original raw draft", images: [], taggedFiles: [], selectedWorkflow: nil,
            selectedWorkflowMutationGeneration: nil, message: "Provider did not accept the turn."
        )
        XCTAssertEqual(fixture.session.draftText, "Original raw draft")
        XCTAssertEqual(fixture.viewModel.repromptUIStore.recoveries[fixture.session.tabID]?.text, "Approved edited brief")
        XCTAssertTrue(fixture.viewModel.restoreRepromptRecovery(tabID: fixture.session.tabID))
        XCTAssertEqual(fixture.session.draftText, "Approved edited brief")
        fixture.viewModel.storeDraftText(for: fixture.session.tabID, "Approved edited brief")
        XCTAssertEqual(fixture.session.draftText, "Approved edited brief", "Old restoration fragments must not be prepended again.")
    }

    func testRecoveryNeverReplacesNewDraftWithoutExplicitConfirmation() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let tabID = fixture.session.tabID
        fixture.viewModel.storeDraftText(for: tabID, "New typing")
        fixture.viewModel.repromptUIStore.recoveries[tabID] = .init(text: "Reviewed brief", originalDraft: "Original", reason: "Context changed", draftAtInvalidation: "Older draft")
        XCTAssertFalse(fixture.viewModel.restoreRepromptRecovery(tabID: tabID))
        XCTAssertEqual(fixture.session.draftText, "New typing")
        XCTAssertTrue(fixture.viewModel.restoreRepromptRecovery(tabID: tabID, confirmedReplacement: true))
        XCTAssertEqual(fixture.session.draftText, "Reviewed brief")
        XCTAssertNil(fixture.viewModel.repromptUIStore.recoveries[tabID])
    }
}
