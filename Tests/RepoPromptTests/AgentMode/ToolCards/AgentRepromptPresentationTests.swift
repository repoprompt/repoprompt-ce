import AppKit
import Foundation
@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
private final class RepromptFocusWindow: NSWindow {
    var reportsKeyWindow = true
    override var isKeyWindow: Bool {
        reportsKeyWindow
    }
}

private struct RepromptFocusSibling: NSViewRepresentable {
    let identifier: String
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: "")
        field.identifier = .init(identifier)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}
}

@MainActor
final class AgentRepromptPresentationTests: XCTestCase {
    func testComposerSendPreparesOnceThenAcceptsVisibleDraftInEveryPhase() async throws {
        for state in ["generating", "clarifying", "refining", "completed", "failed"] {
            let fixture = try await AgentRepromptTestFixture()
            defer { fixture.cleanUp() }
            fixture.enableReprompt()
            let gate = AgentRepromptStartGate()
            defer { Task { await gate.release() } }
            let probe = AgentRepromptStreamProbe()
            fixture.viewModel.repromptService = .init(transport: { message, _, publish in
                let input = message.conversationMessages[0].content
                await probe.append(input)
                if state == "clarifying" || state == "refining", !input.contains("\"answers\"") {
                    try await publish("Visible rewrite" + AgentRepromptStreamParser.delimiter + AgentRepromptServiceTests.questions + AgentRepromptStreamParser.endDelimiter)
                    return
                }
                try await publish(state == "refining" ? "Visible refinement" : "Visible rewrite")
                if state == "failed" { throw AgentRepromptError.provider }
                if state == "generating" || state == "refining" {
                    _ = await gate.wait()
                    try await publish(" late output")
                }
            })
            let vm = fixture.viewModel
            let tabID = fixture.session.tabID
            vm.storeDraftText(for: tabID, "Original")
            let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: fixture.session))
            XCTAssertTrue(vm.prepareRepromptForComposerSend(target: target, text: "Original"), state)
            XCTAssertNil(fixture.session.activeComposerSubmitAttempt)
            if state == "refining" {
                try await AsyncTestWait.waitUntil("clarification before refinement", timeout: 5) { vm.repromptOperation?.phase == .clarifying }
                vm.repromptOperation?.updateDraft(questionID: "scope", draft: .init(selectedOptionLabels: ["Small"]))
                vm.repromptOperation?.completeQuestions()
            }
            let phase: AgentRepromptUIStore.Phase = switch state {
            case "generating": .generating
            case "clarifying": .clarifying
            case "refining": .refining
            case "failed": .failed
            default: .completed
            }
            let visible = state == "refining" ? "Visible refinement" : "Visible rewrite"
            try await AsyncTestWait.waitUntil("visible \(state) draft", timeout: 5) {
                vm.repromptOperation?.phase == phase && fixture.session.draftText == visible
            }
            let operation = try XCTUnwrap(vm.repromptOperation)
            let hadSpeculation = vm.repromptSpeculations[operation.id] != nil
            XCTAssertFalse(vm.prepareRepromptForComposerSend(target: target, text: visible), state)
            XCTAssertEqual(operation.phase, .completed)
            XCTAssertEqual(fixture.session.draftText, visible)
            XCTAssertNil(vm.repromptUIStore.pendingQuestions)
            XCTAssertNil(fixture.session.activeComposerSubmitAttempt)
            if state == "completed" {
                XCTAssertEqual(vm.repromptSpeculations[operation.id] != nil, hadSpeculation, "Accepting a completed draft retains its routing work")
            }
            let claim = try fixture.claim(text: visible, local: true)
            defer { vm.releaseComposerSubmitClaim(claim) }
            XCTAssertEqual(vm.repromptDispatchTexts[claim.attempt.id], visible)
            XCTAssertEqual(vm.repromptDispatchOriginals[claim.attempt.id], "Original")
            XCTAssertNil(vm.repromptOperation)
            await gate.release()
            for _ in 0 ..< 10 {
                await Task.yield()
            }
            XCTAssertEqual(fixture.session.draftText, visible)
            let calls = await probe.values
            XCTAssertEqual(calls.count, state == "refining" ? 2 : 1, "Sending never begins another rewrite")
            XCTAssertTrue(fixture.session.items.isEmpty, "Only the subsequent claimed executor may dispatch")
        }
    }

    func testComposerSendAcceptsOnlyTheExactRecoveryAndRetainsOriginalClassification() async throws {
        for text in ["/compact rewritten data", "A different request"] {
            let fixture = try await AgentRepromptTestFixture()
            defer { fixture.cleanUp() }
            fixture.enableReprompt()
            let vm = fixture.viewModel
            let tabID = fixture.session.tabID
            vm.repromptUIStore.recover(tabID: tabID, text: "/compact rewritten data", originalDraft: "Original", reason: "Context changed", currentDraft: "/compact rewritten data", requiresDecision: true)
            vm.storeDraftText(for: tabID, text)
            let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: fixture.session))
            if text.hasPrefix("/") {
                XCTAssertFalse(vm.prepareRepromptForComposerSend(target: target, text: text))
                let claim = try fixture.claim(text: text, local: true)
                defer { vm.releaseComposerSubmitClaim(claim) }
                XCTAssertEqual(vm.repromptDispatchOriginals[claim.attempt.id], "Original")
                XCTAssertEqual(vm.repromptDispatchTexts[claim.attempt.id], text)
            } else {
                XCTAssertTrue(vm.prepareRepromptForComposerSend(target: target, text: text))
                XCTAssertEqual(vm.repromptOperation?.rawDraft, text)
                XCTAssertFalse(vm.repromptUIStore.recoveries[tabID]?.bypassesPreparation == true)
            }
        }
    }

    func testComposerSendRejectsStaleTargetBeforeChangingPreparation() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        XCTAssertTrue(try fixture.begin(text: "Original"))
        try await AsyncTestWait.waitUntil("completed rewrite", timeout: 5) { fixture.viewModel.repromptOperation?.phase == .completed }
        let vm = fixture.viewModel
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: fixture.session.tabID, session: fixture.session))
        let operation = try XCTUnwrap(vm.repromptOperation)
        let draft = fixture.session.draftText
        fixture.session.composerSubmissionToken = UUID()
        XCTAssertTrue(vm.prepareRepromptForComposerSend(target: target, text: draft))
        XCTAssertTrue(vm.repromptOperation === operation)
        XCTAssertFalse(operation.isClosed, "Reject stale UI before validating or consuming the current operation")
        XCTAssertEqual(fixture.session.draftText, draft)
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt)
    }

    func testUnavailableRewriteModelDoesNotBlockOrdinaryComposerSend() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        fixture.viewModel.repromptAvailability = { _ in false }
        let vm = fixture.viewModel
        vm.storeDraftText(for: fixture.session.tabID, "Original")
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: fixture.session.tabID, session: fixture.session))
        let selection = vm.repromptModelSelectionRaw()
        XCTAssertFalse(vm.prepareRepromptForComposerSend(target: target, text: "Original"))
        XCTAssertNil(vm.repromptOperation)
        XCTAssertEqual(vm.repromptModelSelectionRaw(), selection)
        XCTAssertEqual(fixture.session.draftText, "Original")
    }

    func testComposerSendAcceptsCanonicalEquivalentNativeText() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        fixture.viewModel.repromptService = .init(transport: { _, _, publish in try await publish("Caf\u{00E9}") })
        XCTAssertTrue(try fixture.begin(text: "Original"))
        let vm = fixture.viewModel
        try await AsyncTestWait.waitUntil("completed normalized rewrite", timeout: 5) { vm.repromptOperation?.phase == .completed }
        let nativeText = "Cafe\u{0301}"
        vm.storeDraftText(for: fixture.session.tabID, nativeText)
        XCTAssertEqual(fixture.session.draftText, nativeText)
        XCTAssertFalse(fixture.session.draftText.utf8.elementsEqual(nativeText.utf8), "Draft storage keeps canonical-equivalent text unchanged")
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: fixture.session.tabID, session: fixture.session))
        XCTAssertFalse(vm.prepareRepromptForComposerSend(target: target, text: nativeText), "Normalization alone must not trap Send")
        XCTAssertEqual(vm.repromptOperation?.phase, .completed)
    }

    func testExplicitRewriteRetriesFailedPreparationFromOriginal() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        fixture.enableReprompt()
        let probe = AgentRepromptStreamProbe()
        fixture.viewModel.repromptService = .init(transport: { message, _, publish in
            await probe.append(message.conversationMessages[0].content)
            let calls = await probe.values
            if calls.count == 1 {
                try await publish("/compact Failed partial")
                throw AgentRepromptError.provider
            }
            try await publish("Retried rewrite")
        })
        XCTAssertTrue(try fixture.begin(text: "Original"))
        let vm = fixture.viewModel
        try await AsyncTestWait.waitUntil("failed rewrite", timeout: 5) { vm.repromptOperation?.phase == .failed }
        let failedID = vm.repromptOperation?.id
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: fixture.session.tabID, session: fixture.session))
        XCTAssertTrue(vm.requestComposerRepromptAgain(target: target, text: fixture.session.draftText))
        try await AsyncTestWait.waitUntil("retried rewrite", timeout: 5) { vm.repromptOperation?.phase == .completed }
        XCTAssertNotEqual(vm.repromptOperation?.id, failedID)
        XCTAssertEqual(fixture.session.draftText, "Retried rewrite")
        let calls = await probe.values
        XCTAssertEqual(calls.count, 2)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls[1].utf8)) as? [String: Any])
        XCTAssertEqual(input["originalText"] as? String, "Original")
    }

    func testCancelledDraftReceiptMovesWithSubmissionWithoutReplacingNewerReceipt() {
        let store = AgentRepromptUIStore()
        let tabID = UUID(), otherTabID = UUID()
        store.rememberCancelledDraft(tabID: tabID, text: "Original")
        store.rememberCancelledDraft(tabID: otherTabID, text: "Other")
        let submitted = store.submittedDraftSnapshot(tabID: tabID)
        store.clearSubmittedDraft(submitted)
        XCTAssertFalse(store.hasCancelledDraft(tabID: tabID, text: "Original"))
        XCTAssertTrue(store.hasCancelledDraft(tabID: otherTabID, text: "Other"))
        store.restoreCancelledDraft(submitted.cancelledDraft, tabID: tabID, currentDraft: "Original\nNew typing")
        XCTAssertNil(store.cancelledDrafts[tabID])
        store.restoreCancelledDraft(submitted.cancelledDraft, tabID: tabID, currentDraft: "Original")
        XCTAssertTrue(store.hasCancelledDraft(tabID: tabID, text: "Original"))
        store.rememberCancelledDraft(tabID: tabID, text: "New original")
        store.clearSubmittedDraft(submitted)
        store.restoreCancelledDraft(submitted.cancelledDraft, tabID: tabID, currentDraft: "Original")
        XCTAssertTrue(store.hasCancelledDraft(tabID: tabID, text: "New original"))
    }

    func testHostedFocusHandoffRestoresRemovedQuestionButNeverStealsLiveFieldOrBackgroundWindow() async throws {
        var returns = 0
        func root(questionVisible: Bool, readOnly: Bool, request: UUID?) -> some View {
            VStack {
                if questionVisible { RepromptFocusSibling(identifier: "question") }
                CustomTextField(text: .constant("Draft"), placeholder: "", onReturn: { returns += 1 }, isReadOnly: readOnly, onReadOnlyReturn: { returns += 1 }, focusRestoreRequest: request, currentHeightPresetIndex: .constant(0), onHeightChange: { _ in })
                RepromptFocusSibling(identifier: "unrelated")
            }.frame(width: 480, height: 220)
        }
        let host = NSHostingView(rootView: root(questionVisible: true, readOnly: false, request: nil))
        let window = RepromptFocusWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 220), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? AttachmentAwareTextView }.first)
        let coordinator = try XCTUnwrap(editor.delegate as? CustomTextField.Coordinator)
        func awaitRequest(_ request: UUID) async throws {
            host.layoutSubtreeIfNeeded()
            try await AsyncTestWait.waitUntil("focus request reached native editor", timeout: 3) { coordinator.lastFocusRestoreRequest == request }
            await coordinator.focusRestorationTask?.value
        }
        XCTAssertTrue(window.makeFirstResponder(editor))
        let preparation = UUID()
        host.rootView = root(questionVisible: true, readOnly: true, request: preparation)
        try await awaitRequest(preparation)
        XCTAssertFalse(editor.isEditable)
        XCTAssertTrue(window.firstResponder === editor)

        let question = try XCTUnwrap(descendants(host).first { $0.identifier?.rawValue == "question" })
        XCTAssertTrue(window.makeFirstResponder(question))
        XCTAssertFalse(window.firstResponder === editor)
        let completion = UUID()
        host.rootView = root(questionVisible: false, readOnly: false, request: completion)
        try await awaitRequest(completion)
        XCTAssertNil(question.window)
        XCTAssertTrue(window.firstResponder === editor, "Removing the focused answer must hand the native responder back to the same composer")
        XCTAssertTrue(editor.isEditable)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 30, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(event)
        XCTAssertEqual(returns, 1)

        let unrelated = try XCTUnwrap(descendants(host).first { $0.identifier?.rawValue == "unrelated" })
        XCTAssertTrue(window.makeFirstResponder(unrelated))
        let liveResponder = window.firstResponder
        let laterCompletion = UUID()
        host.rootView = root(questionVisible: false, readOnly: false, request: laterCompletion)
        try await awaitRequest(laterCompletion)
        XCTAssertTrue(window.firstResponder === liveResponder, "A real sibling text field must retain its field editor")
        window.reportsKeyWindow = false
        XCTAssertTrue(window.makeFirstResponder(window))
        let backgroundCompletion = UUID()
        host.rootView = root(questionVisible: false, readOnly: false, request: backgroundCompletion)
        try await awaitRequest(backgroundCompletion)
        XCTAssertTrue(window.firstResponder === window, "Background windows must not reclaim focus")
    }

    func testWindowDeliversNextReturnAfterEditorBecomesReadOnly() throws {
        var returns = 0
        let field = CustomTextField(text: .constant("Original"), placeholder: "", onReturn: { returns += 1 }, onReadOnlyReturn: { returns += 1 }, currentHeightPresetIndex: .constant(0), onHeightChange: { _ in })
        let host = NSHostingView(rootView: field)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> AttachmentAwareTextView? {
            if let text = view as? AttachmentAwareTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let textView = try XCTUnwrap(editor(in: host))
        XCTAssertTrue(window.makeFirstResponder(textView))
        func pressReturn(timestamp: TimeInterval) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            window.sendEvent(event)
        }
        try pressReturn(timestamp: 1)
        XCTAssertEqual(returns, 1)
        textView.isEditable = false
        let coordinator = try XCTUnwrap(textView.delegate as? CustomTextField.Coordinator)
        coordinator.parent.isReadOnly = true
        try pressReturn(timestamp: 30)
        XCTAssertEqual(returns, 2, "The next Return must arrive across preparation's read-only transition, even after a pause")
    }

    func testReadOnlyEditorHandlesReturnDirectlyButNotHeldKeysOrModifiedReturn() throws {
        let textView = AttachmentAwareTextView()
        textView.isEditable = false
        var returns = 0
        textView.readOnlyReturnHandler = { returns += 1 }
        func event(_ flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false, code: UInt16 = 36) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeatKey, keyCode: code))
        }
        try textView.keyDown(with: event())
        XCTAssertEqual(returns, 1, "Read-only Return must not depend on NSTextView insertion delegate delivery")
        try textView.keyDown(with: event(repeatKey: true))
        XCTAssertEqual(returns, 1)
        try textView.keyDown(with: event(code: 76))
        XCTAssertEqual(returns, 2, "Keypad Return also sends")
        let modifiers: [NSEvent.ModifierFlags] = [.shift, .command, .option, .control]
        for flags in modifiers {
            XCTAssertFalse(try textView.handleReadOnlyReturn(event(flags)))
        }
        XCTAssertFalse(try textView.handleReadOnlyReturn(event(code: 0)))
        textView.isEditable = true
        XCTAssertFalse(try textView.handleReadOnlyReturn(event()))
        XCTAssertEqual(returns, 2)
    }

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
        let textView = AttachmentAwareTextView()
        textView.string = "Original"
        textView.isEditable = false
        textView.enablesAttachmentPasteHandling = true
        var pastes = 0
        textView.attachmentPasteHandler = { _ in pastes += 1
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
        XCTAssertTrue(try AttachmentAwareTextView.isCommandReturn(event(.command)))
        XCTAssertTrue(try AttachmentAwareTextView.isCommandReturn(event(.command, code: 76)))
        let otherFlags: [NSEvent.ModifierFlags] = [[], .shift, [.command, .shift], [.command, .option], [.command, .control]]
        for flags in otherFlags {
            XCTAssertFalse(try AttachmentAwareTextView.isCommandReturn(event(flags)))
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
        let panel = NSHostingView(rootView: AgentRepromptQuestionsView(viewModel: fixture.viewModel, store: store, tabID: fixture.session.tabID).frame(width: 480))
        XCTAssertGreaterThanOrEqual(panel.fittingSize.height, 80)
        XCTAssertLessThanOrEqual(panel.fittingSize.height, 250, "Compact clarification content must stay bounded without a duplicated wizard")
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
