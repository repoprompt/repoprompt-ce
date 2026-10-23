import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentComposerDraftRestorationTests: XCTestCase {
    func testCoalescedManualAndQueuedRecoveriesRestoreEachFragmentOnce() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        viewModel.storeDraftText(for: tabID, "D")

        viewModel.restoreRejectedManualSubmissionComposerState(
            tabID: tabID,
            session: session,
            draftText: "B",
            images: [],
            taggedFiles: [],
            selectedWorkflow: nil,
            selectedWorkflowMutationGeneration: nil,
            message: "Failed start"
        )
        viewModel.restoreComposerDraft(
            tabID: tabID,
            text: "C",
            message: "Stopped queued work",
            strategy: .prependAlways
        )

        let finalEvent = try XCTUnwrap(viewModel.draftRestorationEvent)
        let operation = try XCTUnwrap(finalEvent.operation)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "C\nB\nD")
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                operation,
                to: "D",
                acknowledgedSequence: 0
            ),
            "C\nB\nD"
        )
    }

    func testConsumedRecoveryAndNewerTypingAreNotDuplicated() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")
        viewModel.restoreComposerDraft(
            tabID: tabID,
            text: "B",
            message: "Failed start",
            strategy: .prependAlways
        )
        let firstOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        let firstEditorText = AgentComposerDraftRestorationReducer.apply(
            firstOperation,
            to: "D",
            acknowledgedSequence: 0
        )
        XCTAssertEqual(firstEditorText, "B\nD")

        let editedText = firstEditorText + "\nnew typing"
        viewModel.storeDraftText(
            for: tabID,
            editedText,
            acknowledgingThrough: firstOperation.fragments.last?.sequence ?? 0
        )
        viewModel.restoreComposerDraft(
            tabID: tabID,
            text: "C",
            message: "Stopped queued work",
            strategy: .prependAlways
        )
        let finalOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                finalOperation,
                to: editedText,
                acknowledgedSequence: firstOperation.fragments.last?.sequence ?? 0
            ),
            "C\nB\nD\nnew typing"
        )
    }

    func testSkippedIntermediateRecoveryStillAppliesOnlyMissingFragments() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")
        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)
        let firstOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        let firstEditorText = AgentComposerDraftRestorationReducer.apply(
            firstOperation,
            to: "D",
            acknowledgedSequence: 0
        )
        viewModel.restoreComposerDraft(tabID: tabID, text: "B", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: tabID, text: "C", message: "", strategy: .prependAlways)

        let finalOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                finalOperation,
                to: firstEditorText,
                acknowledgedSequence: firstOperation.fragments.last?.sequence ?? 0
            ),
            "C\nB\nA\nD"
        )
    }

    func testInterleavedTabsRetainEachTabsUnconsumedFragments() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let otherTabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")

        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: otherTabID, text: "X", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: tabID, text: "B", message: "", strategy: .prependAlways)

        let operation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(operation.fragments.map(\.text), ["A", "B"])
        let editorText = AgentComposerDraftRestorationReducer.apply(
            operation,
            to: "D",
            acknowledgedSequence: 0
        )
        XCTAssertEqual(editorText, "B\nA\nD")
        viewModel.storeDraftText(
            for: tabID,
            editorText,
            acknowledgingThrough: operation.fragments.last?.sequence ?? 0
        )
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "B\nA\nD")
        XCTAssertTrue(viewModel.draftRestorationLedger.tabs[tabID]?.pendingFragments.isEmpty == true)
        XCTAssertEqual(viewModel.draftRestorationLedger.tabs[otherTabID]?.pendingFragments.map(\.text), ["X"])
    }

    func testStaleEditorStorePreservesRecoveryPendingAtTabSwitch() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")
        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)

        // The old editor value is stored as the tab changes before it sees A.
        viewModel.storeDraftText(for: tabID, "D", acknowledgingThrough: 0)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "A\nD")
        let snapshot = viewModel.loadDraftSnapshotForComposer(for: tabID)
        XCTAssertEqual(snapshot.text, "A\nD")
        XCTAssertTrue(viewModel.draftRestorationLedger.tabs[tabID]?.pendingFragments.isEmpty == true)
    }

    func testLoadedSnapshotAndDeletionDoNotResurrectAcknowledgedRecovery() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)
        let oldOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        let snapshot = viewModel.loadDraftSnapshotForComposer(for: tabID)
        XCTAssertEqual(snapshot.text, "A")
        XCTAssertTrue(viewModel.draftRestorationLedger.tabs[tabID]?.pendingFragments.isEmpty == true)

        viewModel.storeDraftText(for: tabID, "", acknowledgingThrough: snapshot.restorationSequence)
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                oldOperation,
                to: "",
                acknowledgedSequence: snapshot.restorationSequence
            ),
            ""
        )
        viewModel.restoreComposerDraft(tabID: tabID, text: "B", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: tabID, text: "C", message: "", strategy: .prependAlways)

        let operation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(operation.fragments.map(\.text), ["B", "C"])
        let editorText = AgentComposerDraftRestorationReducer.apply(
            operation,
            to: "",
            acknowledgedSequence: snapshot.restorationSequence
        )
        XCTAssertEqual(editorText, "C\nB")
        viewModel.storeDraftText(
            for: tabID,
            editorText,
            acknowledgingThrough: operation.fragments.last?.sequence ?? 0
        )
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "C\nB")
        XCTAssertTrue(viewModel.draftRestorationLedger.tabs[tabID]?.pendingFragments.isEmpty == true)
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Draft restoration tests must not start Codex")
            },
            headlessProviderFactory: { _, _ in
                UnsupportedHeadlessAgentProvider(reason: "draft restoration test")
            }
        )
    }
}

// MARK: - Slash-command composer suggestions

@MainActor
final class AgentSlashCommandSuggestionsTests: XCTestCase {
    func testClaudeCompactIsDiscoverableAndPrefixFiltered() async {
        let viewModel = makeViewModel()
        addTeardownBlock { await viewModel.prepareForWindowClose() }
        viewModel.selectedAgent = .claudeCode

        let all = await viewModel.slashSkillSuggestions(for: "")
        XCTAssertEqual(all.first?.relativePath, "compact")
        let filtered = await viewModel.slashSkillSuggestions(for: "comp")
        XCTAssertEqual(filtered.first?.displayName, "/compact")
        let unrelated = await viewModel.slashSkillSuggestions(for: "zz-no-command")
        XCTAssertFalse(unrelated.contains { $0.relativePath == "compact" })
        let explicitSkill = await viewModel.slashSkillSuggestions(for: "skill:compact")
        XCTAssertFalse(explicitSkill.contains { $0.subtitle == "Compact Claude Code conversation context" })
    }

    func testClaudeBuiltinDoesNotLeakIntoOtherProviderMenus() async {
        let viewModel = makeViewModel()
        addTeardownBlock { await viewModel.prepareForWindowClose() }
        for provider: AgentProviderKind in [.codexExec, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .cursor, .openCode, .grokBuild, .devin, .antigravity] {
            viewModel.selectedAgent = provider
            let suggestions = await viewModel.slashSkillSuggestions(for: "comp")
            XCTAssertFalse(suggestions.contains { $0.subtitle == "Compact Claude Code conversation context" }, provider.rawValue)
        }
    }

    func testActiveClaudeRuntimeCommandsReachMenuButNotOtherProviders() async {
        let viewModel = makeViewModel()
        addTeardownBlock { await viewModel.prepareForWindowClose() }
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.claudeController = SlashSuggestionRuntime()
        viewModel.test_installLiveSession(session)
        viewModel.test_setCurrentTabIDOverride(session.tabID)

        let claude = await viewModel.slashSkillSuggestions(for: "context")
        XCTAssertEqual(claude.map(\.relativePath), ["context"])
        session.selectedAgent = .cursor
        let cursor = await viewModel.slashSkillSuggestions(for: "context")
        XCTAssertFalse(cursor.contains { $0.relativePath == "context" })
    }

    func testSuspendedRuntimeLookupCannotPublishAfterProviderSwitch() async {
        let viewModel = makeViewModel()
        addTeardownBlock { await viewModel.prepareForWindowClose() }
        let started = expectation(description: "runtime command lookup started")
        let runtime = SlashSuggestionRuntime(holdLookup: true, onLookup: { started.fulfill() })
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.claudeController = runtime
        viewModel.test_installLiveSession(session)
        viewModel.test_setCurrentTabIDOverride(session.tabID)

        let pending = Task { await viewModel.slashSkillSuggestions(for: "context") }
        await fulfillment(of: [started], timeout: 2)
        session.selectedAgent = .cursor
        await runtime.releaseLookup()
        let stale = await pending.value
        XCTAssertTrue(stale.isEmpty)
    }

    func testAdvertisedCommandsAreMergedAndDeduplicatedWithCompactFallback() {
        let commands: [NativeAgentRuntimeSlashCommand] = [
            .init(name: "context", description: "Show context", argumentHint: "[detail]"),
            .init(name: "compact", description: "Provider compact", argumentHint: ""),
            .init(name: "CONTEXT", description: "Duplicate", argumentHint: "")
        ]
        let all = AgentModeViewModel.claudeSlashCommandSuggestions(for: "", runtimeCommands: commands)
        XCTAssertEqual(all.map(\.relativePath), ["compact", "context"])
        XCTAssertEqual(all.last?.subtitle, "Show context — [detail]")
        let filtered = AgentModeViewModel.claudeSlashCommandSuggestions(for: " CON ", runtimeCommands: commands)
        XCTAssertEqual(filtered.map(\.relativePath), ["context"])
    }

    func testExactAdvertisedCommandSurvivesSuggestionLimit() {
        var commands = (0 ..< 80).map {
            NativeAgentRuntimeSlashCommand(name: "context-\($0)", description: "Related command", argumentHint: "")
        }
        commands.append(.init(name: "context", description: "Exact command", argumentHint: ""))
        let suggestions = AgentModeViewModel.claudeSlashCommandSuggestions(for: "context", runtimeCommands: commands)
        XCTAssertEqual(suggestions.first?.relativePath, "context")
        XCTAssertEqual(suggestions.filter { $0.relativePath == "context" }.count, 1)
    }

    func testCompactSkillCollisionKeepsNativeCommandAndExplicitSkillSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let commands = root.appendingPathComponent(".claude/commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "Local compact instructions".write(to: commands.appendingPathComponent("compact.md"), atomically: true, encoding: .utf8)
        try "---\ndescription: Local context skill\n---\nLocal context instructions".write(to: commands.appendingPathComponent("context.md"), atomically: true, encoding: .utf8)
        let catalog = AgentSkillCatalog(homeDirectoryURL: root.appendingPathComponent("home"))
        let viewModel = makeViewModel(root: root, catalog: catalog)
        addTeardownBlock { await viewModel.prepareForWindowClose() }
        viewModel.selectedAgent = .claudeCode
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.claudeController = SlashSuggestionRuntime()
        viewModel.test_installLiveSession(session)
        viewModel.test_setCurrentTabIDOverride(session.tabID)

        let suggestions = await viewModel.slashSkillSuggestions(for: "compact")
        XCTAssertEqual(suggestions.map(\.relativePath), ["compact", "skill:compact"])
        XCTAssertTrue(viewModel.resolvedSlashSkillInvocations(in: "/compact").isEmpty)
        XCTAssertEqual(viewModel.resolvedSlashSkillInvocations(in: "/skill:compact").first?.definition.name, "compact")
        let explicit = await viewModel.slashSkillSuggestions(for: "skill:compact")
        XCTAssertEqual(explicit.map(\.relativePath), ["skill:compact"])
        XCTAssertEqual(viewModel.resolvedSlashSkillInvocations(in: "/compact", agentKind: .cursor).first?.definition.name, "compact")
        // Runtime advertisements also contain skills: keep the local row consistent with expansion.
        let context = await viewModel.slashSkillSuggestions(for: "context")
        XCTAssertEqual(context.map(\.relativePath), ["context"])
        XCTAssertEqual(context.first?.subtitle, "Local context skill")
        XCTAssertEqual(viewModel.resolvedSlashSkillInvocations(in: "/context").first?.definition.name, "context")
    }

    private func makeViewModel(root: URL? = nil, catalog: AgentSkillCatalog? = nil) -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspacePath: root?.path,
            skillCatalog: catalog,
            codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Slash suggestions must not start Codex") },
            headlessProviderFactory: { _, _ in UnsupportedHeadlessAgentProvider(reason: "slash suggestions test") }
        )
    }
}

/// Command discovery is a cached runtime read, not a provider launch or model turn.
private actor SlashSuggestionRuntime: NativeAgentRuntimeControlling {
    var hasActiveSession = true
    var hasTurnInFlight = false
    var events: AsyncStream<NativeAgentRuntimeEvent> { AsyncStream { $0.finish() } }
    private let holdLookup: Bool
    private let onLookup: (@Sendable () -> Void)?
    private var lookupContinuation: CheckedContinuation<Void, Never>?
    private var lookupReleased = false

    init(holdLookup: Bool = false, onLookup: (@Sendable () -> Void)? = nil) {
        self.holdLookup = holdLookup
        self.onLookup = onLookup
    }

    func availableSlashCommands() async -> [NativeAgentRuntimeSlashCommand] {
        onLookup?()
        if holdLookup, !lookupReleased {
            await withCheckedContinuation { lookupContinuation = $0 }
        }
        return [.init(name: "context", description: "Show runtime context", argumentHint: "")]
    }

    func releaseLookup() {
        lookupReleased = true
        lookupContinuation?.resume()
        lookupContinuation = nil
    }

    func ensureEventsStreamReady() {}
    func resetEventsStreamForNewRun() {}
    func currentSessionRef() -> NativeAgentRuntimeSessionRef { .init(sessionID: "slash-test") }
    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) {}
    func shutdown() { hasActiveSession = false }
    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) {}

    func startOrResume(existingSessionID: String?, model: String?, effortLevel: NativeAgentRuntimeEffortLevel?, systemPromptOverride: String?) -> NativeAgentRuntimeSessionRef {
        preconditionFailure("Slash suggestions must not start a provider")
    }

    func sendUserMessage(_ text: String) -> UUID {
        preconditionFailure("Slash suggestions must not send provider messages")
    }

    func interruptTurn(reason: String) -> NativeAgentRuntimeInterruptOutcome { .noTurnInFlight }
}
