import AppKit
import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentChatTitlebarSafetyTests: XCTestCase {
    func testButtonPointerStandardAndAccessibilityActivationUseTargetAction() throws {
        let probe = ButtonActionProbe()
        let button = AgentChatOptionsButton()
        button.frame = NSRect(x: 0, y: 0, width: 26, height: 24)
        button.target = probe
        button.action = #selector(ButtonActionProbe.activate(_:))

        XCTAssertEqual(button.focusRingType, .exterior)
        XCTAssertEqual(button.focusRingMaskBounds, button.bounds)

        let pointerEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        button.mouseDown(with: pointerEvent)
        XCTAssertEqual(probe.senders.count, 1)
        XCTAssertTrue(probe.senders.last === button)

        button.performClick(nil)
        XCTAssertEqual(probe.senders.count, 2)
        XCTAssertTrue(probe.senders.last === button)

        _ = button.accessibilityPerformPress()
        XCTAssertEqual(probe.senders.count, 3)
        XCTAssertTrue(probe.senders.last === button)
    }

    func testMenuItemsCaptureImmutableRepresentedTarget() throws {
        let target = AgentChatOptionsMenuTarget(
            windowID: 7,
            workspaceID: UUID(),
            tabID: UUID(),
            agentSessionID: UUID(),
            tabName: "Captured"
        )
        let snapshot = AgentChatOptionsMenuSnapshot(target: target, isPinned: true)
        var invocations: [(String, AgentChatOptionsMenuTarget)] = []
        let menu = AgentChatOptionsMenuPresenter.makeMenu(
            snapshot: snapshot,
            actions: AgentChatOptionsMenuActions(
                togglePin: { invocations.append(("pin", $0)) },
                rename: { invocations.append(("rename", $0)) },
                stash: { invocations.append(("stash", $0)) },
                copyHandoffPrompt: { invocations.append(("copy", $0)) },
                copySessionID: { _ in },
                delete: { invocations.append(("delete", $0)) }
            )
        )

        XCTAssertEqual(menu.items.map(\.title), [
            "Unpin",
            "Rename",
            "Stash",
            "Handoff",
            "",
            "Delete"
        ])

        let unpinnedMenu = AgentChatOptionsMenuPresenter.makeMenu(
            snapshot: AgentChatOptionsMenuSnapshot(target: target, isPinned: false),
            actions: AgentChatOptionsMenuActions(
                togglePin: { _ in },
                rename: { _ in },
                stash: { _ in },
                copyHandoffPrompt: { _ in },
                copySessionID: { _ in },
                delete: { _ in }
            )
        )
        XCTAssertEqual(unpinnedMenu.items.map(\.title), [
            "Pin",
            "Rename",
            "Stash",
            "Handoff",
            "",
            "Delete"
        ])

        for index in [0, 1, 2, 3, 5] {
            let item = menu.items[index]
            XCTAssertTrue(item.target === item)
            XCTAssertTrue(try NSApplication.shared.sendAction(
                XCTUnwrap(item.action),
                to: item.target,
                from: item
            ))
        }

        XCTAssertEqual(invocations.map(\.0), ["pin", "rename", "stash", "copy", "delete"])
        XCTAssertEqual(invocations.map(\.1), Array(repeating: target, count: 5))
    }

    func testCopySessionIDItemAppearsOnlyWithAGenerationBearingCaptureAndPassesItThrough() throws {
        let target = AgentChatOptionsMenuTarget(
            windowID: 7,
            workspaceID: UUID(),
            tabID: UUID(),
            agentSessionID: UUID(),
            tabName: "Captured"
        )

        // No eligible endpoint: the action is not offered at all, rather than offered and then denied.
        let withoutCapture = AgentChatOptionsMenuPresenter.makeMenu(
            snapshot: AgentChatOptionsMenuSnapshot(target: target, isPinned: false),
            actions: Self.noopActions()
        )
        XCTAssertFalse(withoutCapture.items.map(\.title).contains("Copy Session ID"))

        let capture = AgentSessionCopyIDTarget(
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            tabID: target.tabID,
            sessionID: target.agentSessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 4
        )
        var copied: [AgentSessionCopyIDTarget] = []
        let menu = AgentChatOptionsMenuPresenter.makeMenu(
            snapshot: AgentChatOptionsMenuSnapshot(
                target: target,
                isPinned: false,
                copySessionIDTarget: capture
            ),
            actions: Self.noopActions(copySessionID: { copied.append($0) })
        )
        XCTAssertEqual(menu.items.map(\.title), [
            "Pin",
            "Rename",
            "Stash",
            "Handoff",
            "Copy Session ID",
            "",
            "Delete"
        ])

        let item = menu.items[4]
        XCTAssertTrue(try NSApplication.shared.sendAction(
            XCTUnwrap(item.action),
            to: item.target,
            from: item
        ))
        // The menu carries the exact incarnation, not just the session ID, so a same-ID rebind
        // between menu open and click is still detectable at the clipboard write.
        XCTAssertEqual(copied, [capture])
    }

    func testTitleClusterCopiedNoticeIsRevisionGuardedAndSurvivesUnrelatedTitleUpdates() async throws {
        let model = AgentChatTitleClusterModel(title: "Alpha")
        XCTAssertNil(model.state.copiedNotice)

        model.showCopiedNotice("Session ID copied", duration: .milliseconds(60))
        XCTAssertEqual(model.state.copiedNotice, "Session ID copied")

        // A title/chat-options refresh must not clear an in-flight confirmation.
        model.update(title: "Alpha renamed", showsChatOptions: true)
        XCTAssertEqual(model.state.title, "Alpha renamed")
        XCTAssertEqual(model.state.copiedNotice, "Session ID copied")

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(model.state.copiedNotice)
    }

    func testLaterCopiedNoticeSupersedesAnInFlightReset() async throws {
        let model = AgentChatTitleClusterModel(title: "Alpha")
        model.showCopiedNotice("first", duration: .milliseconds(40))
        // The second notice takes a newer generation, so the first one's pending reset must not clear
        // it when it fires.
        model.showCopiedNotice("second", duration: .milliseconds(400))

        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(model.state.copiedNotice, "second")

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(model.state.copiedNotice)
    }

    func testTitlebarCopyWritesNothingAndShowsNoFeedbackForAForeignWindow() {
        // A capture from another window can never be satisfied here: zero clipboard writes and no
        // false success confirmation.
        let model = AgentChatTitleClusterModel(title: "Alpha")
        let capture = AgentSessionCopyIDTarget(
            windowID: 1234,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        )
        var writes: [String] = []
        let outcome = AgentSessionCopyIDPolicy.outcome(for: capture, liveCandidates: [])
        if case let .copied(value) = outcome {
            writes.append(value)
            model.showCopiedNotice("Session ID copied")
        }
        XCTAssertEqual(outcome, .staleTarget)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertNil(model.state.copiedNotice)
    }

    private static func noopActions(
        copySessionID: @escaping (AgentSessionCopyIDTarget) -> Void = { _ in }
    ) -> AgentChatOptionsMenuActions {
        AgentChatOptionsMenuActions(
            togglePin: { _ in },
            rename: { _ in },
            stash: { _ in },
            copyHandoffPrompt: { _ in },
            copySessionID: copySessionID,
            delete: { _ in }
        )
    }

    func testHandoffPromptRendersExactBuildAwareMCPAndCLIRouting() throws {
        let target = try AgentChatOptionsMenuTarget(
            windowID: 7,
            workspaceID: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            tabID: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            agentSessionID: XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333")),
            tabName: "Captured"
        )
        let bindRequest = try WindowRoutingService.parseBindContextRequest([
            "op": .string("bind"),
            "window_id": .int(target.windowID),
            "context_id": .string(target.tabID.uuidString)
        ])
        XCTAssertEqual(bindRequest.op, .bind)
        XCTAssertEqual(bindRequest.windowID, target.windowID)
        XCTAssertEqual(bindRequest.contextID, target.tabID)
        XCTAssertEqual(bindRequest.matchKind, .contextID)

        let expectedDebug = """
        Use RepoPrompt CE to continue this exact Agent Mode session.

        Session title: "Captured"
        Window ID: 7
        Workspace ID: 11111111-1111-1111-1111-111111111111
        Context ID (compose tab): 22222222-2222-2222-2222-222222222222
        Agent session ID: 33333333-3333-3333-3333-333333333333

        MCP:
        1. Call `bind_context` with `{"op":"bind","window_id":7,"context_id":"22222222-2222-2222-2222-222222222222"}`.
        2. Call `agent_manage` with `{"op":"extract_handoff","session_id":"33333333-3333-3333-3333-333333333333"}`.
        3. Consume the returned `<forked_session>` XML before continuing.

        CLI equivalent (`rpce-cli-debug`):
        `rpce-cli-debug -w 7 --context-id 22222222-2222-2222-2222-222222222222 -c agent_manage -j '{"op":"extract_handoff","session_id":"33333333-3333-3333-3333-333333333333"}'`
        """
        let expectedRelease = """
        Use RepoPrompt CE to continue this exact Agent Mode session.

        Session title: "Captured"
        Window ID: 7
        Workspace ID: 11111111-1111-1111-1111-111111111111
        Context ID (compose tab): 22222222-2222-2222-2222-222222222222
        Agent session ID: 33333333-3333-3333-3333-333333333333

        MCP:
        1. Call `bind_context` with `{"op":"bind","window_id":7,"context_id":"22222222-2222-2222-2222-222222222222"}`.
        2. Call `agent_manage` with `{"op":"extract_handoff","session_id":"33333333-3333-3333-3333-333333333333"}`.
        3. Consume the returned `<forked_session>` XML before continuing.

        CLI equivalent (`rpce-cli`):
        `rpce-cli -w 7 --context-id 22222222-2222-2222-2222-222222222222 -c agent_manage -j '{"op":"extract_handoff","session_id":"33333333-3333-3333-3333-333333333333"}'`
        """

        XCTAssertEqual(
            AgentSessionHandoffPrompt.render(target: target, cliCommandName: "rpce-cli-debug"),
            expectedDebug
        )
        XCTAssertEqual(
            AgentSessionHandoffPrompt.render(target: target, cliCommandName: "rpce-cli"),
            expectedRelease
        )
    }

    func testHandoffPromptEscapesSessionTitleAsOneHumanReadableLine() throws {
        let target = try AgentChatOptionsMenuTarget(
            windowID: 7,
            workspaceID: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            tabID: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            agentSessionID: XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333")),
            tabName: "Line 1\n\"quoted\" \\ path — 日本語 👨‍👩‍👧‍👦 \u{85}\u{2028}\u{2029}"
        )

        let prompt = AgentSessionHandoffPrompt.render(target: target, cliCommandName: "rpce-cli-debug")
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertEqual(
            lines[2],
            #"Session title: "Line 1\n\"quoted\" \\ path — 日本語 👨‍👩‍👧‍👦 \u{85}\u{2028}\u{2029}""#
        )
        XCTAssertEqual(prompt.components(separatedBy: "Agent session ID:").count, 2)
        XCTAssertTrue(prompt.contains("Agent session ID: 33333333-3333-3333-3333-333333333333"))
    }

    func testHandoffPromptExplicitEmptyMatchesLegacyPromptByteForByte() throws {
        let target = try AgentChatOptionsMenuTarget(
            windowID: 7,
            workspaceID: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            tabID: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            agentSessionID: XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333")),
            tabName: "Captured"
        )

        for cliCommandName in ["rpce-cli-debug", "rpce-cli"] {
            XCTAssertEqual(
                AgentSessionHandoffPrompt.render(target: target, cliCommandName: cliCommandName, instructions: ""),
                AgentSessionHandoffPrompt.render(target: target, cliCommandName: cliCommandName)
            )
        }
    }

    func testHandoffPromptAppendsInstructionsVerbatim() throws {
        let target = try AgentChatOptionsMenuTarget(
            windowID: 7,
            workspaceID: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            tabID: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            agentSessionID: XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333")),
            tabName: "Captured"
        )
        let instructions = "  Lead with this\n\nKeep the blank line\t"
        let legacyPrompt = AgentSessionHandoffPrompt.render(target: target, cliCommandName: "rpce-cli-debug")

        XCTAssertEqual(
            AgentSessionHandoffPrompt.render(
                target: target,
                cliCommandName: "rpce-cli-debug",
                instructions: instructions
            ),
            legacyPrompt + "\n\nAdditional instructions:\n" + instructions
        )
    }

    func testHandoffPromptTreatsWhitespaceOnlyInstructionsAsNonEmpty() throws {
        let target = try AgentChatOptionsMenuTarget(
            windowID: 7,
            workspaceID: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            tabID: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            agentSessionID: XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333")),
            tabName: "Captured"
        )
        let instructions = " \n\t"
        let legacyPrompt = AgentSessionHandoffPrompt.render(target: target, cliCommandName: "rpce-cli")

        XCTAssertEqual(
            AgentSessionHandoffPrompt.render(
                target: target,
                cliCommandName: "rpce-cli",
                instructions: instructions
            ),
            legacyPrompt + "\n\nAdditional instructions:\n" + instructions
        )
    }

    func testHandoffInstructionsPolicyAcceptsTwentyThousandAndRejectsTwentyThousandOne() {
        let maximum = AgentSessionHandoffInstructionsPolicy.maximumCharacterCount
        let composedGrapheme = "👨‍👩‍👧‍👦"

        XCTAssertEqual(AgentSessionHandoffInstructionsPolicy.characterCount(of: composedGrapheme), 1)
        XCTAssertEqual(AgentSessionHandoffInstructionsPolicy.validation(of: ""), .valid(count: 0))
        XCTAssertEqual(
            AgentSessionHandoffInstructionsPolicy.validation(of: String(repeating: "a", count: maximum)),
            .valid(count: maximum)
        )
        XCTAssertEqual(
            AgentSessionHandoffInstructionsPolicy.validation(of: String(repeating: "a", count: maximum + 1)),
            .tooLong(count: maximum + 1, maximum: maximum)
        )
    }

    func testSnapshotAndTargetValidationFailClosedAcrossLifecycleChanges() async throws {
        try await withFixture { fixture in
            let snapshot = try XCTUnwrap(fixture.window.agentChatTitleClusterMenuSnapshot())
            let target = snapshot.target
            XCTAssertEqual(target.windowID, fixture.window.windowID)
            XCTAssertEqual(target.workspaceID, fixture.workspaceID)
            XCTAssertEqual(target.tabID, fixture.tabAID)
            XCTAssertEqual(target.agentSessionID, fixture.sessionAID)
            XCTAssertEqual(target.tabName, "Alpha")
            XCTAssertTrue(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))

            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(
                AgentChatOptionsMenuTarget(
                    windowID: target.windowID + 1,
                    workspaceID: target.workspaceID,
                    tabID: target.tabID,
                    agentSessionID: target.agentSessionID,
                    tabName: target.tabName
                )
            ))
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(
                AgentChatOptionsMenuTarget(
                    windowID: target.windowID,
                    workspaceID: UUID(),
                    tabID: target.tabID,
                    agentSessionID: target.agentSessionID,
                    tabName: target.tabName
                )
            ))
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(
                AgentChatOptionsMenuTarget(
                    windowID: target.windowID,
                    workspaceID: target.workspaceID,
                    tabID: UUID(),
                    agentSessionID: target.agentSessionID,
                    tabName: target.tabName
                )
            ))
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(
                AgentChatOptionsMenuTarget(
                    windowID: target.windowID,
                    workspaceID: target.workspaceID,
                    tabID: target.tabID,
                    agentSessionID: UUID(),
                    tabName: target.tabName
                )
            ))

            // Once Beta's title is actually published, a menu captured for Alpha no longer
            // describes the displayed conversation and must not act.
            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            fixture.viewModel.test_setCurrentTabIDOverride(fixture.tabBID)
            let betaTitle = await awaitWindowTitleResolution(fixture.window)
            XCTAssertEqual(betaTitle, "Titlebar Safety — Beta")
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))
            fixture.window.agentChatTitleClusterMenuActions().togglePin(target)
            XCTAssertEqual(fixture.tab(fixture.tabAID)?.isPinned, false)
            XCTAssertEqual(fixture.tab(fixture.tabBID)?.isPinned, false)

            // Back on a coherent Alpha, the identity controls run against the displayed target.
            await fixture.window.promptManager.switchComposeTab(fixture.tabAID)
            fixture.viewModel.test_setCurrentTabIDOverride(fixture.tabAID)
            let alphaTitle = await awaitWindowTitleResolution(fixture.window)
            XCTAssertEqual(alphaTitle, "Titlebar Safety — Alpha")
            XCTAssertTrue(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))

            fixture.viewModel.test_setCurrentTabIDOverride(fixture.tabBID)
            XCTAssertNil(fixture.window.agentChatTitleClusterMenuSnapshot())
            fixture.viewModel.test_setCurrentTabIDOverride(fixture.tabAID)

            fixture.window.promptManager.renameComposeTab(fixture.tabAID, to: "Alpha Renamed")
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))
            fixture.window.agentChatTitleClusterMenuActions().togglePin(target)
            XCTAssertEqual(fixture.tab(fixture.tabAID)?.isPinned, false)
            fixture.window.promptManager.renameComposeTab(fixture.tabAID, to: "Alpha")
            await awaitWindowTitleResolution(fixture.window)
            XCTAssertTrue(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))
            fixture.window.agentChatTitleClusterMenuActions().togglePin(target)
            XCTAssertEqual(fixture.tab(fixture.tabAID)?.isPinned, true)

            fixture.sessionA.testInstallPersistentSessionBinding(sessionID: UUID())
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))
            fixture.window.agentChatTitleClusterMenuActions().togglePin(target)
            XCTAssertEqual(fixture.tab(fixture.tabAID)?.isPinned, true)
            XCTAssertEqual(fixture.tab(fixture.tabBID)?.isPinned, false)
        }
    }

    func testCopySessionIDRejectsCaptureOnceAnotherConversationIsDisplayed() async throws {
        try await withFixture { fixture in
            fixture.sessionA.selectedAgent = .claudeCode
            fixture.sessionA.hasLoadedPersistedState = true
            _ = try XCTUnwrap(fixture.viewModel.test_ensureSessionBoundToTab(fixture.sessionA))
            await awaitWindowTitleResolution(fixture.window)
            let capture = try XCTUnwrap(
                fixture.window.agentChatTitleClusterMenuSnapshot()?.copySessionIDTarget,
                "precondition: Alpha offers Copy Session ID"
            )

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            fixture.viewModel.test_setCurrentTabIDOverride(fixture.tabBID)
            let betaTitle = await awaitWindowTitleResolution(fixture.window)
            XCTAssertEqual(betaTitle, "Titlebar Safety — Beta")
            var writes: [String] = []
            let copied = fixture.window.copyAgentSessionIDFromTitlebar(target: capture) { writes.append($0) }

            XCTAssertFalse(copied)
            XCTAssertTrue(writes.isEmpty, "\(writes)")
            XCTAssertNil(fixture.window.agentChatTitleCluster.state.copiedNotice)
        }
    }

    func testQuickHandoffUsesCurrentStoredDefault() async throws {
        try await withFixture { fixture in
            let target = try XCTUnwrap(fixture.window.agentChatTitleClusterMenuSnapshot()?.target)
            var storedDefault = "Earlier default"
            var providerReadCount = 0
            var clipboard = "sentinel"
            var writeCount = 0
            let actions = fixture.window.agentChatTitleClusterMenuActions(
                handoffInstructionsProvider: {
                    providerReadCount += 1
                    return storedDefault
                },
                copyToClipboard: { value in
                    clipboard = value
                    writeCount += 1
                }
            )

            storedDefault = "Current default"
            actions.copyHandoffPrompt(target)

            XCTAssertEqual(providerReadCount, 1)
            XCTAssertEqual(writeCount, 1)
            XCTAssertEqual(
                clipboard,
                AgentSessionHandoffPrompt.render(
                    target: target,
                    cliCommandName: MCPFilesystemConstants.identity.pathCLICommandName,
                    instructions: "Current default"
                )
            )
        }
    }

    func testQuickHandoffRejectsStaleTargetWithoutClipboardWrite() async throws {
        try await withFixture { fixture in
            let target = try XCTUnwrap(fixture.window.agentChatTitleClusterMenuSnapshot()?.target)
            var providerReadCount = 0
            var clipboard = "sentinel"
            var writeCount = 0
            let actions = fixture.window.agentChatTitleClusterMenuActions(
                handoffInstructionsProvider: {
                    providerReadCount += 1
                    return "Saved default"
                },
                copyToClipboard: { value in
                    clipboard = value
                    writeCount += 1
                }
            )

            fixture.window.promptManager.renameComposeTab(target.tabID, to: "Stale")
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))
            actions.copyHandoffPrompt(target)

            XCTAssertEqual(providerReadCount, 0)
            XCTAssertEqual(writeCount, 0)
            XCTAssertEqual(clipboard, "sentinel")
        }
    }

    func testQuickHandoffReportsOversizedStoredInstructionsWithoutCopying() async throws {
        try await withFixture { fixture in
            let target = try XCTUnwrap(fixture.window.agentChatTitleClusterMenuSnapshot()?.target)
            let maximum = AgentSessionHandoffInstructionsPolicy.maximumCharacterCount
            let oversized = String(repeating: "a", count: maximum + 1)
            var feedback: [(count: Int, maximum: Int)] = []
            var clipboard = "sentinel"
            var writeCount = 0
            let actions = fixture.window.agentChatTitleClusterMenuActions(
                handoffInstructionsProvider: { oversized },
                handoffOversizedFeedback: { feedback.append((count: $0, maximum: $1)) },
                copyToClipboard: { value in
                    clipboard = value
                    writeCount += 1
                }
            )

            actions.copyHandoffPrompt(target)

            XCTAssertEqual(feedback.count, 1)
            XCTAssertEqual(feedback.first?.count, maximum + 1)
            XCTAssertEqual(feedback.first?.maximum, maximum)
            XCTAssertEqual(writeCount, 0)
            XCTAssertEqual(clipboard, "sentinel")
        }
    }

    func testGuardedCloseAndStashRejectStaleMutationContext() async throws {
        try await withFixture { fixture in
            await fixture.window.promptManager.closeComposeTab(
                fixture.tabAID,
                isMutationContextCurrent: { false }
            )
            XCTAssertNotNil(fixture.tab(fixture.tabAID))
            XCTAssertNotNil(fixture.tab(fixture.tabBID))

            await fixture.window.promptManager.stashTab(
                fixture.tabAID,
                isMutationContextCurrent: { false }
            )
            XCTAssertNotNil(fixture.tab(fixture.tabAID))
            XCTAssertNotNil(fixture.tab(fixture.tabBID))
            XCTAssertFalse(
                fixture.window.workspaceManager.activeWorkspace?.stashedTabs
                    .contains(where: { $0.tab.id == fixture.tabAID }) == true
            )
        }
    }

    func testPostPreflightStashRefusalPreservesSessionTranscriptAndTab() async throws {
        try await withFixture { fixture in
            fixture.sessionA.setItemsSilently([
                .user("Keep this instruction", sequenceIndex: 0),
                .assistant("Keep this answer", sequenceIndex: 1)
            ], reason: .testOverride)
            fixture.viewModel.refreshDerivedTranscriptState(for: fixture.sessionA)
            let originalRows = fixture.sessionA.items.map(\.id)
            let preflight = fixture.window.promptManager.setComposeTabsRemovalPreflight { _, _, _ in .proceed }
            defer { fixture.window.promptManager.removeComposeTabsRemovalPreflight(preflight) }

            let report = await fixture.window.promptManager.stashComposeTabs(
                withIDs: [fixture.tabAID],
                postPreflightValidation: { false },
                expandCascade: false
            )

            XCTAssertFalse(report.rejections.isEmpty)
            XCTAssertNotNil(fixture.tab(fixture.tabAID))
            XCTAssertEqual(fixture.sessionA.items.map(\.id), originalRows)
            XCTAssertEqual(fixture.sessionA.items.count, 2)
            XCTAssertFalse(
                fixture.window.workspaceManager.activeWorkspace?.stashedTabs
                    .contains(where: { $0.tab.id == fixture.tabAID }) == true
            )
        }
    }

    func testGuardedCloseCommitsTabRemovalAfterListenerCleanupInvalidatesTarget() async throws {
        try await withFixture { fixture in
            let target = try XCTUnwrap(fixture.window.agentChatTitleClusterMenuSnapshot()?.target)
            XCTAssertTrue(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))

            await fixture.window.promptManager.closeComposeTab(
                fixture.tabAID,
                isMutationContextCurrent: {
                    fixture.window.agentChatTitleClusterMenuTargetIsValid(target)
                }
            )

            XCTAssertNil(fixture.tab(fixture.tabAID))
            XCTAssertNotNil(fixture.tab(fixture.tabBID))
            XCTAssertNil(fixture.viewModel.explicitActiveSessionID(for: fixture.tabAID))
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture()
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture() async throws -> Fixture {
        _ = try WorkspaceTestProcessSandbox.validate()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentChatTitlebarSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Titlebar Safety",
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentChatTitlebarSafetyTests"
            )

            let tabAID = UUID()
            let tabBID = UUID()
            let sessionAID = UUID()
            let sessionBID = UUID()
            let tabA = ComposeTabState(id: tabAID, name: "Alpha", activeAgentSessionID: sessionAID)
            let tabB = ComposeTabState(id: tabBID, name: "Beta", activeAgentSessionID: sessionBID)
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [tabA, tabB]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabAID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let viewModel = window.agentModeViewModel
            let sessionA = viewModel.session(for: tabAID)
            _ = viewModel.session(for: tabBID)
            viewModel.setAgentModeActive(true)
            viewModel.test_setCurrentTabIDOverride(tabAID)
            window.setAgentTitlebarAccessoryVisible(true, onNewSession: {})
            // Snapshots describe the published title, so start from Alpha's real resolution.
            await awaitWindowTitleResolution(window)

            return Fixture(
                window: window,
                rootURL: rootURL,
                workspaceID: workspace.id,
                viewModel: viewModel,
                tabAID: tabAID,
                tabBID: tabBID,
                sessionAID: sessionAID,
                sessionA: sessionA
            )
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    private func cleanup(_ fixture: Fixture) async {
        fixture.viewModel.test_setCurrentTabIDOverride(nil)
        fixture.window.setAgentTitlebarAccessoryVisible(false)
        fixture.window.beginClose()
        await fixture.window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(fixture.window)
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private final class ButtonActionProbe: NSObject {
        var senders: [NSButton] = []

        @objc func activate(_ sender: NSButton) {
            senders.append(sender)
        }
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let workspaceID: UUID
        let viewModel: AgentModeViewModel
        let tabAID: UUID
        let tabBID: UUID
        let sessionAID: UUID
        let sessionA: AgentModeViewModel.TabSession

        @MainActor
        func tab(_ id: UUID) -> ComposeTabState? {
            window.workspaceManager.activeWorkspace?.composeTabs.first(where: { $0.id == id })
        }
    }
}

/// #1112: the window title, workspace label and native title must never combine the incoming
/// workspace with the outgoing workspace's instance number while a real switch is in flight.
@MainActor
final class WorkspaceRestorationTitleTests: XCTestCase {
    func testSystemToWorkspaceGapRetainsCoherentTitleUntilTargetNumberIsAssigned() async throws {
        try await assertHeldSwitchKeepsCoherentTitle(systemNumber: 6, targetNumber: 1)
    }

    func testSystemToSecondInstanceNeverShowsSuffixlessTargetBeforeItsNumber() async throws {
        try await assertHeldSwitchKeepsCoherentTitle(systemNumber: 8, targetNumber: 2)
    }

    /// After the number is assigned but before the deferred title resolution, the workspace label
    /// still describes the published title rather than racing ahead of it.
    func testWorkspaceLabelFollowsPublishedTitleUntilDeferredResolution() async throws {
        let fixture = try await makeFixture(systemNumber: 6)
        let window = fixture.window
        let target = window.workspaceManager.createWorkspace(
            name: "Labelled \(UUID().uuidString.prefix(6))", repoPaths: [fixture.rootURL.path], ephemeral: true
        )
        let outgoingTitle = await resolveTitle(window)
        var atAssignment: (number: Int?, displayed: String, label: String)?
        let token = window.workspaceManager.addWorkspaceDidSwitchListener(label: "issue1112LabelProbe") { workspace in
            guard workspace?.id == target.id else { return }
            atAssignment = (window.workspaceInstanceNumber, window.displayedWindowTitle, window.workspaceDisplayName)
        }
        defer { window.workspaceManager.removeWorkspaceDidSwitchListener(token) }
        _ = await window.workspaceManager.switchWorkspace(to: target, saveState: false, reason: "titleLabel")

        let probe = try XCTUnwrap(atAssignment)
        XCTAssertEqual(probe.number, 1)
        XCTAssertEqual(probe.displayed, outgoingTitle)
        XCTAssertEqual(probe.label, WindowTitleFormatter.defaultTitle)
        await resolveTitle(window)
        XCTAssertEqual(window.workspaceDisplayName, target.name)
    }

    /// A settled workspace that never received a number is not retained by a later, unrelated
    /// switch that has not yet published its target: that switch's operation does not own it.
    func testLaterSwitchBeforePublicationDoesNotFreezeSettledUnassignedTitle() async throws {
        let fixture = try await makeFixture(systemNumber: 6, register: false)
        let window = fixture.window
        let manager = window.workspaceManager
        for name in ["settled", "later"] {
            try FileManager.default.createDirectory(
                at: fixture.rootURL.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }
        let settled = manager.createWorkspace(
            name: "Settled \(UUID().uuidString.prefix(6))",
            repoPaths: [fixture.rootURL.appendingPathComponent("settled").path],
            ephemeral: true
        )
        let later = manager.createWorkspace(
            name: "Later \(UUID().uuidString.prefix(6))",
            repoPaths: [fixture.rootURL.appendingPathComponent("later").path],
            ephemeral: true
        )
        _ = await manager.switchWorkspace(to: settled, saveState: false, reason: "titleOperation")
        let tabID = try XCTUnwrap(window.promptManager.activeComposeTabID)
        XCTAssertNil(window.workspaceInstanceNumber)
        let settledTitle = await resolveTitle(window)
        XCTAssertTrue(settledTitle.hasPrefix(settled.name), settledTitle)

        let gate = TitleGapGate()
        manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting { id in
            guard id == later.id else { return }
            await gate.hold()
        }
        let switchTask = Task { @MainActor in
            _ = await manager.switchWorkspace(to: later, saveState: false, reason: "titleOperation")
        }
        await gate.waitUntilHeld()
        XCTAssertTrue(manager.isSwitchingWorkspace)
        XCTAssertEqual(manager.activeWorkspaceID, settled.id)
        window.promptManager.renameComposeTab(tabID, to: "Renamed while later switch waits")
        let renamedTitle = await resolveTitle(window)
        XCTAssertEqual(renamedTitle, "\(settled.name) — Renamed while later switch waits")

        await gate.release()
        await switchTask.value
        manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting(nil)
    }

    /// Cancelled before publication, recovery settles without notifying switch listeners; the
    /// switch finish alone reevaluates the title, which resolves System's existing number.
    func testRecoveryWithoutSwitchNotificationSettlesAtSwitchFinish() async throws {
        let fixture = try await makeFixture(systemNumber: 6)
        let window = fixture.window
        let manager = window.workspaceManager
        let target = manager.createWorkspace(
            name: "Abandoned \(UUID().uuidString.prefix(6))", repoPaths: [fixture.rootURL.path], ephemeral: true
        )
        let outgoingTitle = await resolveTitle(window)
        var notifications = 0
        let token = manager.addWorkspaceDidSwitchListener(label: "issue1112RecoveryProbe") { _ in notifications += 1 }
        defer { manager.removeWorkspaceDidSwitchListener(token) }
        let gate = TitleGapGate()
        manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting { id in
            guard id == target.id else { return }
            await gate.hold()
        }
        defer { manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting(nil) }
        let switchTask = Task { @MainActor in
            _ = await manager.switchWorkspace(to: target, saveState: false, reason: "titleRecovery")
        }
        await gate.waitUntilHeld()
        await manager.cancelCurrentWorkspaceSwitchAndReturnToSystem()

        let naturalTitle = await titleResolvedAfterSwitchFinish(window) {
            await gate.release()
            await switchTask.value
        }
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(manager.activeWorkspace?.isSystemWorkspace, true)
        XCTAssertEqual(window.workspaceInstanceNumber, 6)
        XCTAssertEqual(naturalTitle, outgoingTitle)
        XCTAssertEqual(fixture.nsWindow.title, outgoingTitle)
    }

    /// With no switch listener to assign a number, the finished switch settles the workspace as
    /// unassigned instead of retaining the previous title indefinitely.
    func testUnassignedSwitchSettlesAtSwitchFinish() async throws {
        let fixture = try await makeFixture(systemNumber: 6, register: false)
        let window = fixture.window
        let target = window.workspaceManager.createWorkspace(
            name: "Unassigned \(UUID().uuidString.prefix(6))", repoPaths: [fixture.rootURL.path], ephemeral: true
        )
        await resolveTitle(window)
        let naturalTitle = await titleResolvedAfterSwitchFinish(window) {
            _ = await window.workspaceManager.switchWorkspace(to: target, saveState: false, reason: "titleSettle")
        }
        let tabName = try XCTUnwrap(window.workspaceManager.activeWorkspace?.composeTabs.first {
            $0.id == window.promptManager.activeComposeTabID
        }?.name)
        XCTAssertNil(window.workspaceInstanceNumber)
        XCTAssertEqual(naturalTitle, "\(target.name) — \(tabName)")
        XCTAssertEqual(window.workspaceDisplayName, target.name)
    }

    /// Runs `perform`, then returns the first title resolution that completes after a switch
    /// finishes, without requesting one; switch completion itself must schedule it.
    private func titleResolvedAfterSwitchFinish(
        _ window: WindowState,
        perform: () async -> Void
    ) async -> String? {
        let (titles, continuation) = AsyncStream<String>.makeStream()
        window.workspaceManager.setWorkspaceSwitchDidFinishHandlerForTesting { _ in
            window.setWindowTitleResolutionDidCompleteHandlerForTesting {
                window.setWindowTitleResolutionDidCompleteHandlerForTesting(nil)
                continuation.yield(window.displayedWindowTitle)
                continuation.finish()
            }
        }
        defer { window.workspaceManager.setWorkspaceSwitchDidFinishHandlerForTesting(nil) }
        await perform()
        var iterator = titles.makeAsyncIterator()
        return await iterator.next()
    }

    /// A switch cancelled while held recovers System, which resolves its existing assignment again.
    func testCancelledSwitchRecoversOutgoingAssignmentWithoutMixedTitle() async throws {
        let fixture = try await makeFixture(systemNumber: 6)
        let window = fixture.window
        let target = window.workspaceManager.createWorkspace(
            name: "Cancelled \(UUID().uuidString.prefix(6))", repoPaths: [fixture.rootURL.path], ephemeral: true
        )
        await resolveTitle(window)
        let coherentTitle = window.displayedWindowTitle
        var published: [String] = []
        let observation = window.$displayedWindowTitle.sink { published.append($0) }
        defer { observation.cancel() }
        let gate = TitleGapGate()
        window.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { id in
            guard id == target.id else { return }
            await gate.hold()
        }
        let switchTask = Task { @MainActor in
            _ = await window.workspaceManager.switchWorkspace(to: target, saveState: false, reason: "titleCancel")
        }
        await gate.waitUntilHeld()
        await window.workspaceManager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
        await gate.release()
        await switchTask.value
        window.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil)
        await resolveTitle(window)

        XCTAssertEqual(window.workspaceManager.activeWorkspace?.isSystemWorkspace, true)
        XCTAssertEqual(window.workspaceInstanceNumber, 6)
        XCTAssertEqual(window.displayedWindowTitle, coherentTitle)
        XCTAssertFalse(published.contains { $0.hasPrefix(target.name) }, "\(published)")
    }

    /// A true unload resets to the app default; a non-nil ID whose model is unresolved retains.
    func testUnloadResetsTitleButUnresolvedWorkspaceRetainsIt() async throws {
        let fixture = try await makeFixture(systemNumber: 6)
        let window = fixture.window
        let target = window.workspaceManager.createWorkspace(
            name: "Loaded \(UUID().uuidString.prefix(6))", repoPaths: [fixture.rootURL.path], ephemeral: true
        )
        _ = await window.workspaceManager.switchWorkspace(to: target, saveState: false, reason: "titleUnload")
        await resolveTitle(window)
        let settledTitle = window.displayedWindowTitle
        XCTAssertTrue(settledTitle.hasPrefix(target.name), settledTitle)

        let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == target.id })
        let model = window.workspaceManager.workspaces.remove(at: index)
        XCTAssertEqual(window.workspaceManager.activeWorkspaceID, target.id)
        await resolveTitle(window)
        XCTAssertEqual(window.displayedWindowTitle, settledTitle)
        XCTAssertEqual(window.workspaceDisplayName, target.name)
        window.workspaceManager.workspaces.insert(model, at: index)

        window.workspaceManager.activeWorkspace = nil
        await resolveTitle(window)
        XCTAssertEqual(window.displayedWindowTitle, WindowTitleFormatter.defaultTitle)
        XCTAssertEqual(window.workspaceDisplayName, WindowTitleFormatter.defaultTitle)
        XCTAssertEqual(fixture.nsWindow.title, WindowTitleFormatter.defaultTitle)
    }

    /// Settled workspace/conversation renames update; a selection this workspace does not own
    /// (another workspace's tab reaching the resolver) never decorates the title.
    func testSettledRenamesUpdateAndForeignSelectionDoesNotDecorate() async throws {
        let fixture = try await makeFixture(systemNumber: 6)
        let window = fixture.window
        let target = window.workspaceManager.createWorkspace(
            name: "Named \(UUID().uuidString.prefix(6))", repoPaths: [fixture.rootURL.path], ephemeral: true
        )
        _ = await window.workspaceManager.switchWorkspace(to: target, saveState: false, reason: "titleRename")
        let tabID = try XCTUnwrap(window.promptManager.activeComposeTabID)
        window.promptManager.renameComposeTab(tabID, to: "Renamed chat")
        await resolveTitle(window)
        XCTAssertEqual(window.displayedWindowTitle, "\(target.name) — Renamed chat")

        let renamed = "Renamed \(UUID().uuidString.prefix(6))"
        let activeModel = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.workspaceManager.renameWorkspace(activeModel, newName: renamed)
        await resolveTitle(window)
        XCTAssertEqual(window.displayedWindowTitle, "\(renamed) — Renamed chat")

        // Production tab loading projects the outgoing (System) selection while this workspace stays active.
        let system = try XCTUnwrap(window.workspaceManager.workspaces.first(where: \.isSystemWorkspace))
        window.promptManager.loadComposeTabsFromWorkspace(system, syncPromptText: false)
        let foreignID = try XCTUnwrap(window.promptManager.activeComposeTabID)
        XCTAssertFalse(activeModel.composeTabs.contains { $0.id == foreignID })
        var selectionAtResolution: UUID?
        var ownedAtResolution: Bool?
        let foreignTitle = await resolveTitle(window) {
            selectionAtResolution = window.promptManager.activeComposeTabID
            ownedAtResolution = window.workspaceManager.activeWorkspace?.composeTabs.contains { $0.id == foreignID }
        }
        XCTAssertEqual(selectionAtResolution, foreignID)
        XCTAssertEqual(ownedAtResolution, false, "the projected selection must be foreign when resolved")
        XCTAssertEqual(window.workspaceManager.activeWorkspaceID, target.id)
        XCTAssertEqual(foreignTitle, renamed)
    }

    /// Registration during a held switch assigns the target through the manager's established
    /// allocation point; the outgoing selection still keeps the title from mixing identities.
    func testRegistrationDuringHeldSwitchNeverMixesTitle() async throws {
        let fixture = try await makeFixture(systemNumber: 6, register: false)
        let window = fixture.window
        await resolveTitle(window)
        XCTAssertEqual(window.displayedWindowTitle, WindowTitleFormatter.defaultTitle)
        let target = window.workspaceManager.createWorkspace(
            name: "Registered \(UUID().uuidString.prefix(6))", repoPaths: [fixture.rootURL.path], ephemeral: true
        )
        var published: [String] = []
        let observation = window.$displayedWindowTitle.sink { published.append($0) }
        defer { observation.cancel() }
        let gate = TitleGapGate()
        window.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { id in
            guard id == target.id else { return }
            await gate.hold()
        }
        let switchTask = Task { @MainActor in
            _ = await window.workspaceManager.switchWorkspace(to: target, saveState: false, reason: "titleRegister")
        }
        await gate.waitUntilHeld()
        WindowStatesManager.shared.registerWindowState(window)
        XCTAssertEqual(window.workspaceInstanceNumber, 1)
        await resolveTitle(window)
        XCTAssertFalse(window.workspaceDisplayName.hasPrefix("\(target.name) ("), window.workspaceDisplayName)

        await gate.release()
        await switchTask.value
        window.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil)
        await resolveTitle(window)
        XCTAssertEqual(window.workspaceInstanceNumber, 1)
        XCTAssertEqual(window.workspaceDisplayName, target.name)
        XCTAssertFalse(published.contains { $0.hasPrefix("\(target.name) (") }, "\(published)")
    }

    /// While the real switch listener's owner adoption is queued (number already assigned), no
    /// published title or label names the target; it is published once the owner is current.
    func testTargetTitleIsNotPublishedWhileOwnerAdoptionIsQueued() async throws {
        let fixture = try await makeFixture(systemNumber: 6)
        let window = fixture.window
        let viewModel = window.agentModeViewModel
        let target = window.workspaceManager.createWorkspace(
            name: "Queued \(UUID().uuidString.prefix(6))", repoPaths: [fixture.rootURL.path], ephemeral: true
        )
        let outgoingTitle = await resolveTitle(window)
        var publications: [(title: String, pending: Bool)] = []
        let observation = window.$displayedWindowTitle.sink { title in
            publications.append((title, viewModel.hasPendingOwnerAdoption(forWorkspaceID: target.id)))
        }
        defer { observation.cancel() }
        var paneOwners: [AgentTranscriptPaneTarget.Owner] = []
        let paneObservation = viewModel.ui.transcript.$snapshot.sink { paneOwners.append($0.paneTarget.owner) }
        defer { paneObservation.cancel() }
        var atQueued: (pending: Bool, number: Int?, displayed: String, label: String)?
        let token = window.workspaceManager.addWorkspaceDidSwitchListener(label: "issue1112QueuedProbe") { workspace in
            guard workspace?.id == target.id else { return }
            atQueued = (
                viewModel.hasPendingOwnerAdoption(forWorkspaceID: target.id),
                window.workspaceInstanceNumber,
                window.displayedWindowTitle,
                window.workspaceDisplayName
            )
        }
        defer { window.workspaceManager.removeWorkspaceDidSwitchListener(token) }

        let naturalTitle = await titleResolvedAfterSwitchFinish(window) {
            _ = await window.workspaceManager.switchWorkspace(to: target, saveState: false, reason: "titleQueued")
        }
        let queued = try XCTUnwrap(atQueued)
        XCTAssertTrue(queued.pending, "precondition: real adoption queued after the number was assigned")
        XCTAssertEqual(queued.number, 1)
        XCTAssertEqual(queued.displayed, outgoingTitle)
        XCTAssertEqual(queued.label, WindowTitleFormatter.defaultTitle)
        XCTAssertFalse(publications.contains { $0.pending && $0.title.hasPrefix(target.name) }, "\(publications)")
        let installed = try XCTUnwrap(viewModel.currentPaneOwner)
        XCTAssertEqual(installed.workspaceID, target.id)
        XCTAssertTrue(naturalTitle?.hasPrefix(target.name) == true, "\(String(describing: naturalTitle))")
        // The emitted pane target carries the adoption's end: awaiting the target owner, then installed.
        let awaiting = try XCTUnwrap(
            paneOwners.firstIndex(of: .awaitingOwner(workspaceID: target.id)),
            "\(paneOwners)"
        )
        XCTAssertTrue(paneOwners[awaiting...].contains(.owner(installed)), "\(paneOwners)")
    }

    /// The exact overseer role comes from the real link authority for this workspace's selected tab
    /// and current runtime owner; it is retained through a held switch and retired once the next
    /// workspace is coherent, and a revoked link removes it.
    func testOverseerRoleFollowsRealLinkAuthorityAndCurrentOwner() async throws {
        let fixture = try await makeFixture(systemNumber: 6)
        let window = fixture.window
        let link = try await makeSettledOverseerLink(fixture)
        var facts: (overseer: Bool, owner: UUID?, endpoint: UUID?)?
        let overseerTitle = link.overseerTitle

        await link.revokeAll()
        let revokedTitle = await resolveTitle(window) { facts = link.roleFacts() }
        XCTAssertEqual(facts?.overseer, false)
        XCTAssertEqual(revokedTitle, "\(link.workspace.name) — Observer")

        try await link.add()
        let relinkedTitle = await resolveTitle(window)
        XCTAssertEqual(relinkedTitle, overseerTitle)
        try FileManager.default.createDirectory(
            at: fixture.rootURL.appendingPathComponent("next"), withIntermediateDirectories: true
        )
        let next = window.workspaceManager.createWorkspace(
            name: "Next \(UUID().uuidString.prefix(6))",
            repoPaths: [fixture.rootURL.appendingPathComponent("next").path],
            ephemeral: true
        )
        let gate = TitleGapGate()
        window.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { id in
            guard id == next.id else { return }
            await gate.hold()
        }
        defer { window.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil) }
        let switchTask = Task { @MainActor in
            _ = await window.workspaceManager.switchWorkspace(to: next, saveState: false, reason: "titleRole")
        }
        await gate.waitUntilHeld()
        let heldTitle = await resolveTitle(window)
        XCTAssertEqual(heldTitle, overseerTitle)

        await gate.release()
        await switchTask.value
        let settledTitle = await resolveTitle(window) { facts = link.roleFacts() }
        XCTAssertEqual(facts?.owner, next.id)
        XCTAssertTrue(settledTitle.hasPrefix(next.name), settledTitle)
        XCTAssertFalse(settledTitle.contains(WindowTitleFormatter.overseerPrefix), settledTitle)
    }

    /// A stale activation (the real public `handleWorkspaceSwitch(nil)` while this window still
    /// shows the workspace) leaves no current runtime owner; the still-resolvable endpoint's
    /// overseer projection is then not this workspace's runtime fact and must not decorate.
    func testOverseerRoleRequiresCurrentRuntimeOwner() async throws {
        let fixture = try await makeFixture(systemNumber: 6)
        let window = fixture.window
        let viewModel = window.agentModeViewModel
        let link = try await makeSettledOverseerLink(fixture)

        await viewModel.handleWorkspaceSwitch(nil)
        var facts: (overseer: Bool, owner: UUID?, endpoint: UUID?)?
        var selection: UUID?
        let title = await resolveTitle(window) {
            facts = link.roleFacts()
            selection = window.promptManager.activeComposeTabID
        }
        XCTAssertEqual(window.workspaceManager.activeWorkspaceID, link.workspace.id, "precondition: still shown")
        XCTAssertEqual(selection, link.observerTabID, "precondition: owned selection")
        XCTAssertEqual(facts?.overseer, true, "precondition: projection still resolves")
        XCTAssertEqual(facts?.endpoint, link.workspace.id, "precondition: endpoint still resolves")
        XCTAssertNil(facts?.owner, "precondition: no current runtime owner")
        XCTAssertEqual(title, "\(link.workspace.name) — Observer")
    }

    private struct SettledOverseerLink {
        let workspace: WorkspaceModel
        let observerTabID: UUID
        let overseerTitle: String
        let add: @MainActor () async throws -> Void
        let revokeAll: @MainActor () async -> Void
        let roleFacts: @MainActor () -> (overseer: Bool, owner: UUID?, endpoint: UUID?)
    }

    /// Settles a workspace whose selected Observer tab oversees its Target tab through the real
    /// shared link authority (added, projected and later revoked by exact link ID and generation).
    private func makeSettledOverseerLink(_ fixture: Fixture) async throws -> SettledOverseerLink {
        let window = fixture.window
        let viewModel = window.agentModeViewModel
        let bridge = AgentSessionLinkRuntimeBridge.shared
        let authority = AppDomainRuntimeComposition.shared.runtime.agentSessionLinkAuthority
        let root = fixture.rootURL.appendingPathComponent("role")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let overseen = window.workspaceManager.createWorkspace(
            name: "Overseer \(UUID().uuidString.prefix(6))", repoPaths: [root.path], ephemeral: true
        )
        let observerTab = ComposeTabState(id: UUID(), name: "Observer")
        let targetTab = ComposeTabState(id: UUID(), name: "Target")
        let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == overseen.id })
        window.workspaceManager.workspaces[index].composeTabs = [observerTab, targetTab]
        window.workspaceManager.workspaces[index].activeComposeTabID = observerTab.id
        _ = await window.workspaceManager.switchWorkspace(to: overseen, saveState: false, reason: "titleRole")
        XCTAssertEqual(window.promptManager.activeComposeTabID, observerTab.id)
        var sessionIDs: [UUID] = []
        for tabID in [observerTab.id, targetTab.id] {
            let session = viewModel.session(for: tabID)
            session.selectedAgent = .claudeCode
            session.hasLoadedPersistedState = true
            try sessionIDs.append(XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session)))
        }
        let observerSessionID = sessionIDs[0]
        let targetSessionID = sessionIDs[1]
        let revokeAll: @MainActor () async -> Void = {
            for item in await authority.links(forObserver: observerSessionID).items {
                await bridge.revokeLink(linkID: item.linkID, generation: item.generation)
            }
            await bridge.test_settleProjections()
        }
        addTeardownBlock { @MainActor in await revokeAll() }
        let add: @MainActor () async throws -> Void = {
            let outcome = await bridge.addMonitorLink(
                observerSessionID: observerSessionID,
                rawTargetSessionID: targetSessionID.uuidString
            )
            guard case .added = outcome else { return XCTFail("link not added: \(outcome)") }
            await bridge.test_settleProjections()
        }
        let roleFacts: @MainActor () -> (overseer: Bool, owner: UUID?, endpoint: UUID?) = {
            (
                viewModel.agentSessionLinkIsOverseer(tabID: observerTab.id),
                viewModel.currentPaneOwner?.workspaceID,
                viewModel.agentSessionLinkObserverEndpoint(tabID: observerTab.id)?.workspaceID
            )
        }

        try await add()
        var facts: (overseer: Bool, owner: UUID?, endpoint: UUID?)?
        let overseerTitle = await awaitWindowTitleResolution(window) { facts = roleFacts() }
        XCTAssertEqual(facts?.overseer, true)
        XCTAssertEqual(facts?.owner, overseen.id)
        XCTAssertEqual(facts?.endpoint, overseen.id)
        XCTAssertEqual(overseerTitle, WindowTitleFormatter.overseerPrefix + "\(overseen.name) — Observer")
        return SettledOverseerLink(
            workspace: overseen,
            observerTabID: observerTab.id,
            overseerTitle: overseerTitle,
            add: add,
            revokeAll: revokeAll,
            roleFacts: roleFacts
        )
    }

    /// Assignments are qualified installs: one for another workspace is stale, and nil is only an
    /// unload/termination result, never a way to publish the active workspace unnumbered.
    func testStaleAndNilAssignmentsCannotReplaceActiveWorkspaceNumber() async throws {
        let fixture = try await makeFixture(systemNumber: 6)
        let window = fixture.window
        XCTAssertEqual(window.workspaceInstanceNumber, 6)

        window.setWorkspaceInstanceAssignment(WorkspaceInstanceAssignment(workspaceID: UUID(), number: 9))
        XCTAssertEqual(window.workspaceInstanceNumber, 6)
        window.setWorkspaceInstanceAssignment(nil)
        XCTAssertEqual(window.workspaceInstanceNumber, 6)
    }

    /// An ID published outside any switch (authority-only adoption) has no pending assignment:
    /// the current workspace shows unassigned rather than retaining the outgoing title forever.
    func testIDPublishedOutsideSwitchShowsCurrentWorkspaceUnassigned() async throws {
        let fixture = try await makeFixture(systemNumber: 6)
        let window = fixture.window
        let target = window.workspaceManager.createWorkspace(
            name: "Adopted \(UUID().uuidString.prefix(6))",
            repoPaths: [fixture.rootURL.path],
            ephemeral: true
        )
        await resolveTitle(window)

        window.workspaceManager.activeWorkspace = target
        XCTAssertFalse(window.workspaceManager.isSwitchingWorkspace)
        var ownedTabName: String??
        let title = await resolveTitle(window) {
            ownedTabName = window.promptManager.activeComposeTabID.map { tabID in
                window.workspaceManager.activeWorkspace?.composeTabs.first { $0.id == tabID }?.name
            }
        }

        XCTAssertNil(window.workspaceInstanceNumber)
        XCTAssertEqual(window.workspaceDisplayName, target.name)
        // The outgoing selection reached the resolver unowned and is ignored, never decorating.
        XCTAssertEqual(ownedTabName, .some(nil), "expected a selection this workspace does not own")
        XCTAssertEqual(title, target.name)
        XCTAssertEqual(fixture.nsWindow.title, title)
    }

    /// Natural post-compose gap: the target's saved tab is restored (and its tab notification
    /// delivered) while root loading holds the switch before its number is assigned.
    func testPostComposeGapKeepsTitleAndRejectsChatOptionsUntilTargetIsCoherent() async throws {
        let fixture = try await makeFixture(systemNumber: 6)
        let window = fixture.window
        let target = window.workspaceManager.createWorkspace(
            name: "Restored \(UUID().uuidString.prefix(6))",
            repoPaths: [fixture.rootURL.path],
            ephemeral: true
        )
        let sessionID = UUID()
        let tab = ComposeTabState(id: UUID(), name: "Saved chat", activeAgentSessionID: sessionID)
        let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == target.id })
        window.workspaceManager.workspaces[index].composeTabs = [tab]
        window.workspaceManager.workspaces[index].activeComposeTabID = tab.id
        let heldTarget = AgentChatOptionsMenuTarget(
            windowID: window.windowID, workspaceID: target.id, tabID: tab.id, agentSessionID: sessionID, tabName: tab.name
        )
        await resolveTitle(window)
        let coherentTitle = window.displayedWindowTitle
        var published: [String] = []
        let observation = window.$displayedWindowTitle.sink { published.append($0) }
        defer { observation.cancel() }

        let rootName = fixture.rootURL.lastPathComponent
        let gate = TitleGapGate()
        let store = window.workspaceFileContextStore
        await store.setRootLoadWillStartHandler { path in
            guard path.hasSuffix(rootName) else { return }
            await gate.hold()
        }
        addTeardownBlock { @MainActor in
            await gate.release()
            await store.setRootLoadWillStartHandler(nil)
            window.agentModeViewModel.test_setCurrentTabIDOverride(nil)
            window.setAgentTitlebarAccessoryVisible(false)
        }
        let switchTask = Task { @MainActor in
            _ = await window.workspaceManager.switchWorkspace(
                to: target, saveState: false, reason: "workspaceRestorationTitleTests"
            )
        }
        await gate.waitUntilHeld()
        for await activity in window.workspaceManager.$activeWorkspaceSwitch.values
            where activity?.phase == .hydratingRoots
        {
            break
        }
        XCTAssertEqual(window.promptManager.activeComposeTabID, tab.id)
        _ = window.agentModeViewModel.session(for: tab.id)
        window.agentModeViewModel.setAgentModeActive(true)
        window.agentModeViewModel.test_setCurrentTabIDOverride(tab.id)
        window.setAgentTitlebarAccessoryVisible(true, onNewSession: {})
        var clipboardWrites = 0
        let actions = window.agentChatTitleClusterMenuActions(
            handoffInstructionsProvider: { "" },
            copyToClipboard: { _ in clipboardWrites += 1 }
        )

        await resolveTitle(window)
        XCTAssertEqual(window.displayedWindowTitle, coherentTitle)
        XCTAssertEqual(fixture.nsWindow.title, coherentTitle)
        XCTAssertFalse(window.agentChatTitleCluster.state.showsChatOptions)
        XCTAssertNil(window.agentChatTitleClusterMenuSnapshot())
        XCTAssertFalse(window.agentChatTitleClusterMenuTargetIsValid(heldTarget))
        actions.togglePin(heldTarget)
        actions.copyHandoffPrompt(heldTarget)
        XCTAssertEqual(window.workspaceManager.activeWorkspace?.composeTabs.first?.isPinned, false)
        XCTAssertEqual(clipboardWrites, 0)

        await gate.release()
        await switchTask.value
        await resolveTitle(window)
        XCTAssertEqual(window.displayedWindowTitle, "\(target.name) — Saved chat")
        XCTAssertEqual(fixture.nsWindow.title, window.displayedWindowTitle)
        XCTAssertTrue(window.agentChatTitleCluster.state.showsChatOptions)
        XCTAssertEqual(window.agentChatTitleClusterMenuSnapshot()?.target, heldTarget)
        actions.togglePin(heldTarget)
        XCTAssertEqual(window.workspaceManager.activeWorkspace?.composeTabs.first?.isPinned, true)
        XCTAssertFalse(published.contains { $0.hasPrefix("\(target.name) (") }, "\(published)")
    }

    /// Holds a real switch after the target ID is published and before its number is assigned,
    /// resolves the production title there, then releases and checks the settled title.
    private func assertHeldSwitchKeepsCoherentTitle(systemNumber: Int, targetNumber: Int) async throws {
        let fixture = try await makeFixture(systemNumber: systemNumber)
        let window = fixture.window
        XCTAssertEqual(window.workspaceInstanceNumber, systemNumber)
        let target = window.workspaceManager.createWorkspace(
            name: "Restored \(UUID().uuidString.prefix(6))",
            repoPaths: [fixture.rootURL.path],
            ephemeral: true
        )
        for _ in 1 ..< targetNumber {
            WindowStatesManager.shared.recordWorkspaceSwitch(forWindowID: WindowState.reserveWindowIDForTesting(), to: target)
        }
        await resolveTitle(window)
        let coherentTitle = window.displayedWindowTitle
        let coherentLabel = window.workspaceDisplayName
        var published: [String] = []
        let observation = window.$displayedWindowTitle.sink { published.append($0) }
        defer { observation.cancel() }

        let gate = TitleGapGate()
        window.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { id in
            guard id == target.id else { return }
            await gate.hold()
        }
        let switchTask = Task { @MainActor in
            _ = await window.workspaceManager.switchWorkspace(
                to: target, saveState: false, reason: "workspaceRestorationTitleTests"
            )
        }
        await gate.waitUntilHeld()
        XCTAssertEqual(window.workspaceManager.activeWorkspaceID, target.id)

        await resolveTitle(window)
        XCTAssertEqual(window.displayedWindowTitle, coherentTitle)
        XCTAssertEqual(window.workspaceDisplayName, coherentLabel)
        XCTAssertEqual(fixture.nsWindow.title, coherentTitle)

        await gate.release()
        await switchTask.value
        window.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil)
        await resolveTitle(window)

        let settledLabel = targetNumber >= 2 ? "\(target.name) (\(targetNumber))" : target.name
        XCTAssertEqual(window.workspaceInstanceNumber, targetNumber)
        XCTAssertEqual(window.workspaceDisplayName, settledLabel)
        XCTAssertTrue(window.displayedWindowTitle.hasPrefix(settledLabel), window.displayedWindowTitle)
        XCTAssertEqual(fixture.nsWindow.title, window.displayedWindowTitle)
        // Every publication naming the target already carries its own settled label.
        let mixed = published.filter { $0.hasPrefix(target.name) && !$0.hasPrefix(settledLabel) }
        XCTAssertTrue(mixed.isEmpty, "\(published)")
        XCTAssertFalse(published.contains { $0.hasPrefix("\(target.name) (\(systemNumber))") }, "\(published)")
    }

    private struct Fixture {
        let window: WindowState
        let nsWindow: NSWindow
        let rootURL: URL
    }

    /// Registers a fresh window on System with exactly `systemNumber`, seeded from an empty
    /// allocator by reserved window IDs; the process-wide allocator state is restored afterwards.
    private func makeFixture(systemNumber: Int, register: Bool = true) async throws -> Fixture {
        _ = try WorkspaceTestProcessSandbox.validate()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRestorationTitleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        let nsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        nsWindow.isReleasedWhenClosed = false
        let previousAllocator = WindowStatesManager.shared.replaceInstanceAllocatorStateForTesting()
        addTeardownBlock { @MainActor in
            window.attachWindow(nil)
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            WindowStatesManager.shared.replaceInstanceAllocatorStateForTesting(previousAllocator)
            try? FileManager.default.removeItem(at: rootURL)
        }

        await window.workspaceManager.awaitInitialized()
        let system = try XCTUnwrap(window.workspaceManager.workspaces.first(where: \.isSystemWorkspace))
        for _ in 1 ..< systemNumber {
            WindowStatesManager.shared.recordWorkspaceSwitch(forWindowID: WindowState.reserveWindowIDForTesting(), to: system)
        }
        if register {
            WindowStatesManager.shared.registerWindowState(window)
        }
        if window.workspaceManager.activeWorkspaceID != system.id {
            _ = await window.workspaceManager.switchWorkspace(
                to: system, saveState: false, reason: "workspaceRestorationTitleTests"
            )
        }
        window.attachWindow(nsWindow)
        return Fixture(window: window, nsWindow: nsWindow, rootURL: rootURL)
    }

    @discardableResult
    private func resolveTitle(_ window: WindowState, probe: @escaping @MainActor () -> Void = {}) async -> String {
        await awaitWindowTitleResolution(window, probe: probe)
    }

    private actor TitleGapGate {
        private var held = false
        private var released = false
        private var heldWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func hold() async {
            held = true
            heldWaiters.forEach { $0.resume() }
            heldWaiters.removeAll()
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilHeld() async {
            guard !held else { return }
            await withCheckedContinuation { heldWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }
}

/// Requests the production deferred title update, waits for that resolution to publish, and
/// returns the title it installed; `probe` reads other facts at that same checkpoint.
@MainActor
@discardableResult
private func awaitWindowTitleResolution(
    _ window: WindowState,
    probe: @escaping @MainActor () -> Void = {}
) async -> String {
    await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
        window.setWindowTitleResolutionDidCompleteHandlerForTesting {
            window.setWindowTitleResolutionDidCompleteHandlerForTesting(nil)
            probe()
            continuation.resume(returning: window.displayedWindowTitle)
        }
        window.requestWindowTitleUpdate(reason: .explicit)
    }
}
