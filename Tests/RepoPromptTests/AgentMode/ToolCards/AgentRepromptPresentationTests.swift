import AppKit
import Foundation
@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class AgentRepromptPresentationTests: XCTestCase {
    func testAttachmentMutationAndNativePasteAreBlockedWhilePreparationOwnsComposer() {
        let store = AgentRepromptUIStore()
        let tabID = UUID()
        XCTAssertTrue(store.allowsAttachmentMutation(tabID: tabID, currentTabID: tabID))
        store.presentation = .init(id: UUID(), sourceTabID: tabID, original: "original", modelName: "model")
        for phase in [AgentRepromptUIStore.Phase.generating, .refining, .clarifying] {
            store.presentation?.phase = phase
            XCTAssertFalse(store.allowsAttachmentMutation(tabID: tabID, currentTabID: tabID), "Picker, drop, tagging and removal callbacks share this live gate")
        }
        store.presentation?.phase = .completed
        XCTAssertTrue(store.allowsAttachmentMutation(tabID: tabID, currentTabID: tabID))
        XCTAssertFalse(store.allowsAttachmentMutation(tabID: tabID, currentTabID: nil), "Delayed intake must reject a cleared live selection, not fall back to a captured tab")
        XCTAssertFalse(store.allowsAttachmentMutation(tabID: tabID, currentTabID: UUID()))
        let textView = ImageAwareTextView()
        textView.string = "Original"
        textView.isEditable = false
        textView.enablesImagePasteHandling = true
        var pastes = 0
        textView.imagePasteHandler = { _ in pastes += 1
            return true
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("new text", forType: .string)
        textView.paste(board)
        XCTAssertFalse(textView.readSelection(from: board, type: .string))
        XCTAssertEqual(pastes, 0)
        XCTAssertEqual(textView.string, "Original")
    }

    func testValidationPublicationsCoalesceIntoOneNextTurnCheck() async throws {
        var checks = 0
        let operation = AgentRepromptOperation(sourceTabID: UUID(), rawDraft: "original", draftGeneration: 0, request: .init(originalText: "original"), model: nil, service: nil, store: AgentRepromptUIStore(), currentDraft: { "original" }, applyDraft: { _ in 0 }, isCurrent: { checks += 1
            return true
        })
        for _ in 0 ..< 100 {
            operation.scheduleValidation()
        }
        try await AsyncTestWait.waitUntil("coalesced validation", timeout: 3) { checks > 0 }
        XCTAssertEqual(checks, 1)
        operation.cancel()
    }

    func testPillSnapshotStopsSpinningAtCompletionNotAtDispatch() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        let gate = AgentRepromptStartGate()
        defer { Task { await gate.release() } }
        fixture.viewModel.repromptService = .init(transport: { _, _, publish in
            try await publish("A partial")
            _ = await gate.wait()
            try await publish(" brief")
        })
        XCTAssertTrue(try fixture.begin(text: "Original"))
        XCTAssertTrue(fixture.viewModel.ui.statusPills.snapshot.reprompt.isPreparing)
        await gate.release()
        try await AsyncTestWait.waitUntil("complete", timeout: 5) { fixture.viewModel.repromptOperation?.phase == .completed }
        XCTAssertFalse(fixture.viewModel.ui.statusPills.snapshot.reprompt.isPreparing, "The value-only pill snapshot must refresh when streaming ends")
        XCTAssertNotNil(fixture.viewModel.repromptOperation, "Completion is not dispatch or close")
        XCTAssertTrue(fixture.session.items.isEmpty)
    }

    func testCommandReturnIsScopedAndShiftReturnKeepsNewline() throws {
        func event(_ flags: NSEvent.ModifierFlags, code: UInt16 = 36) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(try ImageAwareTextView.isCommandReturn(event(.command)))
        XCTAssertTrue(try ImageAwareTextView.isCommandReturn(event(.command, code: 76)))
        let otherFlags: [NSEvent.ModifierFlags] = [[], .shift, [.command, .shift], [.command, .option], [.command, .control]]
        for flags in otherFlags {
            XCTAssertFalse(try ImageAwareTextView.isCommandReturn(event(flags)))
        }
        var escapes = 0
        let field = CustomTextField(text: .constant("prepared"), placeholder: "", onReturn: {}, onEscape: { escapes += 1 }, currentHeightPresetIndex: .constant(0), onHeightChange: { _ in })
        let coordinator = CustomTextField.Coordinator(field)
        XCTAssertTrue(coordinator.textView(NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(escapes, 1, "Esc must also work after streaming unlocks editing")
    }

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
        XCTAssertFalse(fixture.viewModel.ui.statusPills.snapshot.reprompt.isPreparing, "Questions are not provider streaming")
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
        XCTAssertTrue(fixture.viewModel.ui.statusPills.snapshot.reprompt.isPreparing)
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

    func testRevertCreatesOneUndoActionThatRecoversEditedRewrite() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        XCTAssertTrue(try fixture.begin(text: "First original"))
        try await AsyncTestWait.waitUntil("prepared", timeout: 5) { fixture.viewModel.repromptOperation?.phase == .completed }
        fixture.viewModel.storeDraftText(for: fixture.session.tabID, "Edited rewrite")
        fixture.viewModel.undoReprompt()
        XCTAssertEqual(fixture.session.draftText, "First original")
        let recovery = try XCTUnwrap(fixture.viewModel.repromptUIStore.recoveries[fixture.session.tabID])
        let field = CustomTextField(
            text: .constant("First original"), placeholder: "", onReturn: {},
            externalEditTransaction: .init(id: recovery.id, isComplete: true),
            onUndoExternalEdit: { _ = fixture.viewModel.restoreRepromptRecovery(tabID: fixture.session.tabID) },
            currentHeightPresetIndex: .constant(0), onHeightChange: { _ in }
        )
        let coordinator = CustomTextField.Coordinator(field)
        let manager = try XCTUnwrap(coordinator.undoManager(for: NSTextView()))
        manager.groupsByEvent = false
        coordinator.beginExternalEditIfNeeded()
        manager.beginUndoGrouping()
        coordinator.completeExternalEditIfNeeded()
        manager.endUndoGrouping()
        manager.undo()
        XCTAssertEqual(fixture.session.draftText, "Edited rewrite")
        XCTAssertFalse(manager.canUndo)
    }

    func testOldNativeUndoCannotRestoreAnInactiveTab() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let inactiveTabID = UUID()
        fixture.viewModel.repromptUIStore.recoveries[inactiveTabID] = .init(text: "Old rewrite", originalDraft: "Original", reason: "Original restored", draftAtInvalidation: "Original")
        XCTAssertFalse(fixture.viewModel.restoreRepromptRecovery(tabID: inactiveTabID, confirmedReplacement: true))
        XCTAssertNotNil(fixture.viewModel.repromptUIStore.recoveries[inactiveTabID], "A stale action cannot consume another tab's recovery")
        XCTAssertTrue(fixture.session.draftText.isEmpty)
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
        XCTAssertTrue(fixture.viewModel.repromptUIStore.recoveries[tabID]?.bypassesPreparation == true)
    }
}
