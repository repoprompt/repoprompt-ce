import AppKit
import Foundation
@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class AgentRepromptPresentationTests: XCTestCase {
    func testAcknowledgedPublicationResumesFinalDraftFlushing() {
        let tabID = UUID()
        let update = AgentRepromptUIStore.DraftUpdate(operationID: UUID(), tabID: tabID, revision: 7, text: "brief")
        var presentation = AgentRepromptUIStore.Presentation(id: update.operationID, sourceTabID: tabID, original: "original", modelName: "model")
        func flush(_ acknowledged: AgentRepromptUIStore.PublicationIdentity?) -> Bool {
            AgentRepromptUIStore.shouldFlushDraftOnDeparture(tabID: tabID, presentation: presentation, publication: update, acknowledged: acknowledged)
        }
        XCTAssertFalse(flush(update.identity), "Streaming owns the canonical draft even after an earlier chunk was acknowledged")
        presentation.phase = .completed
        XCTAssertFalse(flush(nil), "An unconsumed publication must not be overwritten by stale editor text")
        XCTAssertTrue(flush(update.identity), "A historical publication must not suppress the final edited keystroke")
        XCTAssertFalse(flush(.init(operationID: update.operationID, revision: 6)))
        XCTAssertTrue(AgentRepromptUIStore.shouldFlushDraftOnDeparture(tabID: tabID, presentation: nil, publication: update, acknowledged: update.identity))
    }

    func testDisclosureIsPerRecipientAndDoesNotReuseOldConsultReceipt() throws {
        let suite = "AgentRepromptDisclosureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agentReprompt.acknowledgedProviders.v2.one")
        XCTAssertFalse(AgentRepromptDisclosure.isAcknowledged(providerID: "one", defaults: defaults))
        AgentRepromptDisclosure.acknowledge(providerID: "one", defaults: defaults)
        AgentRepromptDisclosure.acknowledge(providerID: "two", defaults: defaults)
        XCTAssertTrue(AgentRepromptDisclosure.isAcknowledged(providerID: "one", defaults: defaults))
        XCTAssertFalse(AgentRepromptDisclosure.isAcknowledged(providerID: "one.recent-chat", defaults: defaults))
    }

    func testClarificationsAreTransientAndSkipAllDoesNotRefine() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        fixture.viewModel.repromptService = .init(transport: { _, _, publish in
            try await publish("Generated body" + AgentRepromptStreamParser.delimiter + AgentRepromptServiceTests.questions + AgentRepromptStreamParser.endDelimiter)
        })
        XCTAssertTrue(try fixture.begin(text: "Original"))
        try await AsyncTestWait.waitUntil("inline questions", timeout: 5) { fixture.viewModel.repromptOperation?.phase == .clarifying }
        let store = fixture.viewModel.repromptUIStore
        XCTAssertEqual(store.pendingQuestions?.interaction.title, "Before sending")
        XCTAssertTrue(store.pendingQuestions?.draftsByQuestionID.values.allSatisfy { $0.selectedOptionLabels.isEmpty && $0.customResponse.isEmpty && !$0.skipped } == true)
        XCTAssertEqual(fixture.session.draftText, "Generated body")
        XCTAssertNil(fixture.session.pendingAskUser)
        XCTAssertTrue(fixture.session.items.isEmpty, "Pre-send questions never enter provider history")
        fixture.viewModel.repromptOperation?.completeQuestions(skipAll: true)
        XCTAssertEqual(fixture.viewModel.repromptOperation?.phase, .completed)
        XCTAssertEqual(AgentAskUserWizardCard.activityInterval(timeoutSeconds: 0.1, showsTimeout: false), 1)
    }

    func testSubstantiveAnswersRefineOnceFromOriginalNotPriorRewrite() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        let probe = AgentRepromptStreamProbe()
        fixture.viewModel.repromptService = .init(transport: { message, _, publish in
            let input = message.conversationMessages[0].content
            await probe.append(input)
            if input.contains("\"answers\"") { try await publish("Refined body") }
            else { try await publish("First generated body" + AgentRepromptStreamParser.delimiter + AgentRepromptServiceTests.questions + AgentRepromptStreamParser.endDelimiter) }
        })
        XCTAssertTrue(try fixture.begin(text: "Original words"))
        try await AsyncTestWait.waitUntil("questions", timeout: 5) { fixture.viewModel.repromptOperation?.phase == .clarifying }
        var draft = try XCTUnwrap(fixture.viewModel.repromptUIStore.pendingQuestions?.draftsByQuestionID["scope"])
        draft.selectedOptionLabels = ["Small"]
        fixture.viewModel.repromptOperation?.updateDraft(questionID: "scope", draft: draft)
        fixture.viewModel.repromptOperation?.completeQuestions()
        try await AsyncTestWait.waitUntil("refined", timeout: 5) { fixture.viewModel.repromptOperation?.phase == .completed }
        let inputs = await probe.values
        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(inputs[1].contains("Original words") && inputs[1].contains("Small"))
        XCTAssertFalse(inputs[1].contains("First generated body"))
        XCTAssertEqual(fixture.session.draftText, "Refined body")
    }

    func testNativeUndoRegistersOneReplacementNotPerToken() throws {
        let id = UUID()
        var undos = 0
        var field = CustomTextField(
            text: .constant(""),
            placeholder: "",
            onReturn: {},
            externalEditTransaction: .init(id: id, isComplete: false),
            onUndoExternalEdit: { undos += 1 },
            currentHeightPresetIndex: .constant(0),
            onHeightChange: { _ in }
        )
        let coordinator = CustomTextField.Coordinator(field)
        let textView = NSTextView()
        let manager = try XCTUnwrap(coordinator.undoManager(for: textView))
        manager.groupsByEvent = false
        coordinator.beginExternalEditIfNeeded()
        for index in 1 ... 10 {
            coordinator.applyExternalTextReplacement(String(repeating: "token ", count: index), to: textView, externalUpdateTick: index)
            XCTAssertFalse(manager.canUndo)
        }
        field.externalEditTransaction = .init(id: id, isComplete: true)
        coordinator.parent = field
        manager.beginUndoGrouping()
        coordinator.completeExternalEditIfNeeded()
        coordinator.completeExternalEditIfNeeded()
        manager.endUndoGrouping()
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        XCTAssertEqual(undos, 1)
        XCTAssertFalse(manager.canUndo)
        XCTAssertEqual(ResizableTextField.presetIndex(forVisibleLineFragmentCount: 1000), ResizableTextField.heightPresets.count - 1)
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
