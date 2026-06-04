import Darwin
import Foundation
import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentRunWorktreeStartTests: XCTestCase {
    func testEffectiveWorkspacePathUsesBoundWorktreeAndPreservesUnboundFallback() throws {
        let root = try makeTemporaryDirectory(named: "root")
        let worktree = try makeTemporaryDirectory(named: "worktree")
        let viewModel = makeViewModel(workspacePath: root.path)
        let boundSession = AgentModeViewModel.TabSession(tabID: UUID())
        boundSession.worktreeBindings = [makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path)]

        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: boundSession), worktree.path)

        let unboundSession = AgentModeViewModel.TabSession(tabID: UUID())
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: unboundSession), root.path)
    }

    func testMissingBoundWorktreeFailsWithRecoveryMessage() throws {
        let root = try makeTemporaryDirectory(named: "root")
        let missingWorktree = root.appendingPathComponent("missing-worktree")
        let viewModel = makeViewModel(workspacePath: root.path)
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.worktreeBindings = [
            makeBinding(
                logicalRoot: root.path,
                worktreeRoot: missingWorktree.path,
                label: "Feature WT"
            )
        ]

        XCTAssertThrowsError(try viewModel.effectiveWorkspacePath(for: session)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            XCTAssertTrue(message.contains("Feature WT"), message)
            XCTAssertTrue(message.contains(missingWorktree.path), message)
            XCTAssertTrue(message.contains("unbind the session"), message)
        }
    }

    func testAgentRunSnapshotIncludesWorktreeBindingFields() throws {
        let root = try makeTemporaryDirectory(named: "root")
        let worktree = try makeTemporaryDirectory(named: "worktree")
        let binding = makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path, label: "Feature WT")
        let snapshot = AgentRunMCPSnapshot(
            sessionID: UUID(),
            tabID: UUID(),
            sessionName: "Worktree Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: .running,
            statusText: nil,
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [AgentRunMCPSnapshot.WorktreeBinding(binding: binding)],
            activeWorktreeMerges: []
        )

        let object = snapshot.asObject()
        let worktreeObject = try XCTUnwrap(object["worktree"]?.objectValue)
        XCTAssertEqual(worktreeObject["worktree_id"]?.stringValue, "wt_test")
        XCTAssertEqual(worktreeObject["worktree_root_path"]?.stringValue, worktree.path)
        XCTAssertEqual(worktreeObject["visual_label"]?.stringValue, "Feature WT")
        XCTAssertEqual(worktreeObject["unavailable"]?.boolValue, false)
        XCTAssertEqual(object["worktree_bindings"]?.arrayValue?.count, 1)
    }

    func testChildSessionWorktreeBindingInheritanceCanBeOptedOut() throws {
        let root = try makeTemporaryDirectory(named: "root")
        let worktree = try makeTemporaryDirectory(named: "worktree")
        let parentID = UUID()
        let viewModel = makeViewModel(workspacePath: root.path)
        let parent = viewModel.session(for: UUID())
        parent.activeAgentSessionID = parentID
        parent.worktreeBindings = [makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path)]

        let inheritedChild = viewModel.session(for: UUID())
        inheritedChild.activeAgentSessionID = UUID()
        viewModel.applySpawnParentSessionID(parentID, to: inheritedChild)
        XCTAssertEqual(inheritedChild.parentSessionID, parentID)
        XCTAssertEqual(inheritedChild.worktreeBindings, parent.worktreeBindings)
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: inheritedChild), worktree.path)

        let optedOutChild = viewModel.session(for: UUID())
        optedOutChild.activeAgentSessionID = UUID()
        viewModel.applySpawnParentSessionID(parentID, to: optedOutChild, inheritWorktreeBindings: false)
        XCTAssertEqual(optedOutChild.parentSessionID, parentID)
        XCTAssertTrue(optedOutChild.worktreeBindings.isEmpty)
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: optedOutChild), root.path)
    }

    func testAgentRunStartParentSourceWorktreeInheritanceMatrix() async throws {
        for (sourceIsMCPControlled, inheritWorktreeBindings) in [
            (true, true),
            (true, false),
            (false, true),
            (false, false)
        ] {
            let root = try makeTemporaryDirectory(named: "root")
            let worktree = try makeTemporaryDirectory(named: "worktree")
            let window = try await makeWindow(root: root)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
            let parentID = UUID()
            let parentBinding = makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path)
            if sourceIsMCPControlled {
                installParentAgentSession(parentID, binding: parentBinding, sourceTabID: sourceTabID, in: window)
            } else {
                let source = window.agentModeViewModel.session(for: sourceTabID)
                source.activeAgentSessionID = parentID
                source.worktreeBindings = [parentBinding]
                XCTAssertNil(source.mcpControlContext)
            }
            let service = makeAgentRunStartService(window: window, sourceTabID: sourceTabID)
            var args: [String: Value] = [
                "op": .string("start"),
                "message": .string("parent source inheritance matrix"),
                "detach": .bool(true),
                "timeout": .int(0)
            ]
            if !inheritWorktreeBindings {
                args["inherit_worktree"] = .bool(false)
            }

            let value = try await service.execute(args: args)

            let object = try XCTUnwrap(value.objectValue)
            let sessionObject = try XCTUnwrap(object["session"]?.objectValue)
            let childSessionID = try XCTUnwrap(try UUID(uuidString: XCTUnwrap(object["session_id"]?.stringValue)))
            let childTabID = try XCTUnwrap(try UUID(uuidString: XCTUnwrap(sessionObject["context_id"]?.stringValue)))
            XCTAssertEqual(sessionObject["parent_session_id"]?.stringValue, parentID.uuidString)

            let child = window.agentModeViewModel.session(for: childTabID)
            XCTAssertEqual(child.activeAgentSessionID, childSessionID)
            XCTAssertEqual(child.parentSessionID, parentID)
            if inheritWorktreeBindings {
                let bindings = try XCTUnwrap(object["worktree_bindings"]?.arrayValue)
                XCTAssertEqual(bindings.count, 1)
                let bindingObject = try XCTUnwrap(bindings.first?.objectValue)
                XCTAssertEqual(bindingObject["worktree_root_path"]?.stringValue, worktree.path)
                XCTAssertEqual(child.worktreeBindings, [parentBinding])
                XCTAssertEqual(try window.agentModeViewModel.effectiveWorkspacePath(for: child), worktree.path)
            } else {
                XCTAssertNil(object["worktree"])
                XCTAssertNil(object["worktree_bindings"])
                XCTAssertTrue(child.worktreeBindings.isEmpty)
                XCTAssertEqual(try window.agentModeViewModel.effectiveWorkspacePath(for: child), root.path)
            }
        }
    }

    func testAgentRunTopLevelStartWithoutSpawnSourceRemainsAllowed() async throws {
        let root = try makeTemporaryDirectory(named: "root")
        let window = try await makeWindow(root: root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let service = makeAgentRunStartService(window: window, sourceTabID: nil)

        let value = try await service.execute(args: [
            "op": .string("start"),
            "message": .string("legitimate external top-level start"),
            "detach": .bool(true),
            "timeout": .int(0)
        ])

        let object = try XCTUnwrap(value.objectValue)
        let sessionObject = try XCTUnwrap(object["session"]?.objectValue)
        let childTabID = try XCTUnwrap(try UUID(uuidString: XCTUnwrap(sessionObject["context_id"]?.stringValue)))
        XCTAssertNil(sessionObject["parent_session_id"]?.stringValue)
        XCTAssertNil(object["worktree"])
        XCTAssertNil(object["worktree_bindings"])

        let child = window.agentModeViewModel.session(for: childTabID)
        XCTAssertNil(child.parentSessionID)
        XCTAssertTrue(child.worktreeBindings.isEmpty)
        XCTAssertEqual(try window.agentModeViewModel.effectiveWorkspacePath(for: child), root.path)
    }

    func testManualFirstSendCanCreateAndBindNewWorktree() async throws {
        let fixture = try makeGitFixture()
        let window = try await makeWindow(root: fixture.repo)
        let viewModel = window.agentModeViewModel
        window.apiSettingsViewModel.isCodexConnected = true
        let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let sourceSession = await viewModel.ensureSessionReady(tabID: sourceTabID)
        sourceSession.selectedAgent = .codexExec
        viewModel.selectedAgent = .codexExec
        viewModel.selectInitialStartLocation(.newWorktree, for: sourceTabID)
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))

        try await withIsolatedBootstrapSocketNamespace(window: window) { namespace in
            let result = await viewModel.submitUserTurnCreatingSessionIfNeeded(
                text: "start in a worktree",
                target: target,
                createAndActivateSessionTab: {
                    let destinationTabID = await viewModel.createAndActivateSessionTab()
                    if let destinationTabID {
                        namespace.track(tabID: destinationTabID, session: viewModel.session(for: destinationTabID))
                    }
                    return destinationTabID
                }
            )

            XCTAssertEqual(result, .submitted)
            if result == .submitted {
                try await namespace.acceptedSubmitAndAwaitOwnedSocket()
            }
            let destinationTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
            XCTAssertNotEqual(destinationTabID, sourceTabID)
            let destinationSession = viewModel.session(for: destinationTabID)
            let binding = try XCTUnwrap(destinationSession.worktreeBindings.first)
            XCTAssertEqual(binding.source, "agent_ui.initial_send")
            XCTAssertEqual(binding.logicalRootPath, fixture.repo.path)
            XCTAssertTrue(binding.worktreeRootPath.contains(".repoprompt-worktrees"), binding.worktreeRootPath)
            XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: destinationSession), binding.worktreeRootPath)
            XCTAssertNil(viewModel.initialStartLocationProps(tabID: destinationTabID))
            XCTAssertEqual(viewModel.executionLocationProps(tabID: destinationTabID)?.indicator?.worktreeID, binding.worktreeID)
            XCTAssertEqual(destinationSession.items.first(where: { $0.kind == .user })?.text, "start in a worktree")
        }
    }

    func testManualNewWorktreeFirstSendBlocksForNonGitPrimaryRootWithoutBinding() async throws {
        let root = try makeTemporaryDirectory(named: "non-git-root")
        let window = try await makeWindow(root: root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        window.apiSettingsViewModel.isCodexConnected = true
        let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let sourceSession = await viewModel.ensureSessionReady(tabID: sourceTabID)
        sourceSession.selectedAgent = .codexExec
        viewModel.selectedAgent = .codexExec
        viewModel.selectInitialStartLocation(.newWorktree, for: sourceTabID)
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))

        let result = await viewModel.submitUserTurnCreatingSessionIfNeeded(text: "cannot create worktree", target: target)

        guard case let .blocked(message) = result else {
            return XCTFail("Expected non-Git worktree start to be blocked")
        }
        XCTAssertTrue(message.contains("Git-backed primary workspace root"), message)
        XCTAssertEqual(sourceSession.pendingInitialStartLocation, .newWorktree)
        XCTAssertTrue(sourceSession.worktreeBindings.isEmpty)
        XCTAssertTrue(sourceSession.items.isEmpty)
    }

    func testFreshLinkedManualFirstSendCanCreateAndBindNewWorktreeInPlace() async throws {
        let fixture = try makeGitFixture()
        let window = try await makeWindow(root: fixture.repo)
        let viewModel = window.agentModeViewModel
        window.apiSettingsViewModel.isCodexConnected = true
        let createdTabID = await viewModel.createAndActivateSessionTab()
        let linkedTabID = try XCTUnwrap(createdTabID)
        let linkedSession = await viewModel.ensureSessionReady(tabID: linkedTabID)
        linkedSession.selectedAgent = .codexExec
        viewModel.selectedAgent = .codexExec
        viewModel.selectInitialStartLocation(.newWorktree, for: linkedTabID)
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: linkedTabID, session: linkedSession))
        XCTAssertEqual(target.route, .existingAgentSession)

        try await withIsolatedBootstrapSocketNamespace(window: window) { namespace in
            namespace.track(tabID: linkedTabID, session: linkedSession)
            let result = await viewModel.submitUserTurnCreatingSessionIfNeeded(
                text: "start linked thread in a worktree",
                target: target,
                createAndActivateSessionTab: {
                    XCTFail("Linked first send must not create another destination tab")
                    return nil
                }
            )

            XCTAssertEqual(result, .submitted)
            if result == .submitted {
                try await namespace.acceptedSubmitAndAwaitOwnedSocket()
            }
            XCTAssertEqual(window.workspaceManager.activeWorkspace?.activeComposeTabID, linkedTabID)
            let binding = try XCTUnwrap(linkedSession.worktreeBindings.first)
            XCTAssertEqual(binding.source, "agent_ui.initial_send")
            XCTAssertEqual(binding.logicalRootPath, fixture.repo.path)
            XCTAssertTrue(binding.worktreeRootPath.contains(".repoprompt-worktrees"), binding.worktreeRootPath)
            XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: linkedSession), binding.worktreeRootPath)
            XCTAssertNil(viewModel.initialStartLocationProps(tabID: linkedTabID))
            XCTAssertEqual(viewModel.executionLocationProps(tabID: linkedTabID)?.indicator?.worktreeID, binding.worktreeID)
            XCTAssertEqual(linkedSession.items.first(where: { $0.kind == .user })?.text, "start linked thread in a worktree")
        }
    }

    func testFreshLinkedManualNewWorktreeFirstSendBlocksForNonGitPrimaryRootInPlace() async throws {
        let root = try makeTemporaryDirectory(named: "linked-non-git-root")
        let window = try await makeWindow(root: root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        window.apiSettingsViewModel.isCodexConnected = true
        let createdTabID = await viewModel.createAndActivateSessionTab()
        let linkedTabID = try XCTUnwrap(createdTabID)
        let linkedSession = await viewModel.ensureSessionReady(tabID: linkedTabID)
        linkedSession.selectedAgent = .codexExec
        viewModel.selectedAgent = .codexExec
        viewModel.selectInitialStartLocation(.newWorktree, for: linkedTabID)
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: linkedTabID, session: linkedSession))
        XCTAssertEqual(target.route, .existingAgentSession)

        let result = await viewModel.submitUserTurnCreatingSessionIfNeeded(
            text: "cannot create linked worktree",
            target: target,
            createAndActivateSessionTab: {
                XCTFail("Linked failed first send must not create another destination tab")
                return nil
            }
        )

        guard case let .blocked(message) = result else {
            return XCTFail("Expected non-Git linked worktree start to be blocked")
        }
        XCTAssertTrue(message.contains("Git-backed primary workspace root"), message)
        XCTAssertEqual(window.workspaceManager.activeWorkspace?.activeComposeTabID, linkedTabID)
        XCTAssertEqual(linkedSession.pendingInitialStartLocation, .newWorktree)
        XCTAssertTrue(linkedSession.worktreeBindings.isEmpty)
        XCTAssertTrue(linkedSession.items.isEmpty)
        XCTAssertEqual(viewModel.initialStartLocationProps(tabID: linkedTabID)?.selection, .newWorktree)
    }

    func testManualFirstSendListsAndBindsExistingPrimaryRepositoryWorktree() async throws {
        let fixture = try makeGitFixture()
        let sibling = fixture.sandbox.appendingPathComponent("existing-ui-worktree", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature/existing-ui-\(fixture.suffix)", sibling.path, "HEAD"], cwd: fixture.repo)
        let window = try await makeWindow(root: fixture.repo)
        let viewModel = window.agentModeViewModel
        window.apiSettingsViewModel.isCodexConnected = true
        let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let sourceSession = await viewModel.ensureSessionReady(tabID: sourceTabID)
        sourceSession.selectedAgent = .codexExec
        viewModel.selectedAgent = .codexExec

        let choices = try await viewModel.availableExecutionWorktrees(for: sourceTabID)
        let existing = try XCTUnwrap(choices.first { samePath($0.path, sibling.path) })
        XCTAssertFalse(choices.contains { samePath($0.path, fixture.repo.path) })
        let selectionResult = await viewModel.selectExecutionLocation(.existingWorktree(existing), for: sourceTabID)
        XCTAssertEqual(selectionResult, .applied)
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))

        try await withIsolatedBootstrapSocketNamespace(window: window) { namespace in
            let result = await viewModel.submitUserTurnCreatingSessionIfNeeded(
                text: "start in existing",
                target: target,
                createAndActivateSessionTab: {
                    let destinationTabID = await viewModel.createAndActivateSessionTab()
                    if let destinationTabID {
                        namespace.track(tabID: destinationTabID, session: viewModel.session(for: destinationTabID))
                    }
                    return destinationTabID
                }
            )

            XCTAssertEqual(result, .submitted)
            if result == .submitted {
                try await namespace.acceptedSubmitAndAwaitOwnedSocket()
            }
            let destinationTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
            let destination = viewModel.session(for: destinationTabID)
            let binding = try XCTUnwrap(destination.worktreeBindings.first)
            XCTAssertEqual(binding.worktreeID, existing.worktreeID)
            XCTAssertEqual(binding.worktreeRootPath, sibling.standardizedFileURL.path)
            XCTAssertEqual(binding.source, "agent_ui.initial_send_existing")
            XCTAssertEqual(viewModel.executionLocationProps(tabID: destinationTabID)?.indicator?.worktreeID, existing.worktreeID)
        }
    }

    func testIdleStartedThreadRequiresRestartConfirmationBeforeReturningLocalAndClearsOldCWDProviderIdentity() async throws {
        let fixture = try makeGitFixture()
        let sibling = fixture.sandbox.appendingPathComponent("bound-existing", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature/bound-\(fixture.suffix)", sibling.path, "HEAD"], cwd: fixture.repo)
        let window = try await makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let createdTabID = await viewModel.createAndActivateSessionTab()
        let tabID = try XCTUnwrap(createdTabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.selectedAgent = .codexExec
        session.providerSessionID = "old-provider-cwd"
        session.codexConversationID = "old-codex-cwd"
        session.codexRolloutPath = "/tmp/old-rollout"
        session.worktreeBindings = [makeBinding(logicalRoot: fixture.repo.path, worktreeRoot: sibling.path)]

        let warning = await viewModel.selectExecutionLocation(.local, for: tabID)

        XCTAssertEqual(warning, .confirmationRequired(.startedThreadRestart))
        XCTAssertEqual(session.worktreeBindings.first?.worktreeRootPath, sibling.standardizedFileURL.path)
        XCTAssertEqual(session.providerSessionID, "old-provider-cwd")

        let result = await viewModel.selectExecutionLocation(
            .local,
            for: tabID,
            confirmedChange: .startedThreadRestart
        )

        XCTAssertEqual(result, .applied)
        XCTAssertTrue(session.worktreeBindings.isEmpty)
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: session), fixture.repo.path)
        XCTAssertNil(session.providerSessionID)
        XCTAssertNil(session.codexConversationID)
        XCTAssertNil(session.codexRolloutPath)
        XCTAssertEqual(viewModel.executionLocationProps(tabID: tabID)?.selection, .local)
    }

    func testStartedThreadCanCreateNewWorktreeAndReplacePrimaryBinding() async throws {
        let fixture = try makeGitFixture()
        let window = try await makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let createdTabID = await viewModel.createAndActivateSessionTab()
        let tabID = try XCTUnwrap(createdTabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true

        let unchanged = await viewModel.selectExecutionLocation(.local, for: tabID)
        XCTAssertEqual(unchanged, .unchanged)

        let warning = await viewModel.selectExecutionLocation(.newWorktree, for: tabID)
        XCTAssertEqual(warning, .confirmationRequired(.startedThreadRestart))
        XCTAssertTrue(session.worktreeBindings.isEmpty)

        let result = await viewModel.selectExecutionLocation(
            .newWorktree,
            for: tabID,
            confirmedChange: .startedThreadRestart
        )

        XCTAssertEqual(result, .applied)
        let binding = try XCTUnwrap(session.worktreeBindings.first)
        XCTAssertEqual(binding.source, "agent_ui.location_change_new")
        XCTAssertTrue(binding.worktreeRootPath.contains(".repoprompt-worktrees"), binding.worktreeRootPath)
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: session), binding.worktreeRootPath)
    }

    func testStartedThreadCanSwitchAgainWhileRecoveryHandoffWaitsForNextSend() async throws {
        let fixture = try makeGitFixture()
        let sibling = fixture.sandbox.appendingPathComponent("reusable-location", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature/reusable-location-\(fixture.suffix)", sibling.path, "HEAD"], cwd: fixture.repo)
        let window = try await makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let createdTabID = await viewModel.createAndActivateSessionTab()
        let tabID = try XCTUnwrap(createdTabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.items = [
            .user("Previous question", sequenceIndex: 0),
            .assistant("Previous answer", sequenceIndex: 1)
        ]
        session.worktreeBindings = [makeBinding(logicalRoot: fixture.repo.path, worktreeRoot: sibling.path)]

        let firstWarning = await viewModel.selectExecutionLocation(.local, for: tabID)
        XCTAssertEqual(firstWarning, .confirmationRequired(.startedThreadRestart))
        let firstResult = await viewModel.selectExecutionLocation(
            .local,
            for: tabID,
            confirmedChange: .startedThreadRestart
        )

        XCTAssertEqual(firstResult, .applied)
        let pendingPayload = try XCTUnwrap(session.pendingHandoff.payload)
        XCTAssertFalse(session.pendingHandoff.defersProviderLockUntilSend)
        XCTAssertFalse(session.pendingHandoff.isStagedForSend)
        XCTAssertEqual(viewModel.executionLocationProps(tabID: tabID)?.isEnabled, true)

        let choices = try await viewModel.availableExecutionWorktrees(for: tabID)
        let existing = try XCTUnwrap(choices.first { samePath($0.path, sibling.path) })
        let secondWarning = await viewModel.selectExecutionLocation(.existingWorktree(existing), for: tabID)
        XCTAssertEqual(secondWarning, .confirmationRequired(.startedThreadRestart))
        let secondResult = await viewModel.selectExecutionLocation(
            .existingWorktree(existing),
            for: tabID,
            confirmedChange: .startedThreadRestart
        )

        XCTAssertEqual(secondResult, .applied)
        XCTAssertEqual(session.worktreeBindings.first?.worktreeID, existing.worktreeID)
        XCTAssertEqual(session.pendingHandoff.payload, pendingPayload)
        XCTAssertFalse(session.pendingHandoff.isStagedForSend)
    }

    func testDeferredPendingHandoffStillBlocksStartedThreadLocationChange() async throws {
        let root = try makeTemporaryDirectory(named: "deferred-root")
        let worktree = try makeTemporaryDirectory(named: "deferred-worktree")
        let viewModel = makeViewModel(workspacePath: root.path)
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.activeAgentSessionID = UUID()
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.worktreeBindings = [makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path)]
        session.pendingHandoff = .init(payload: "fork handoff", defersProviderLockUntilSend: true)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let props = try XCTUnwrap(viewModel.executionLocationProps(tabID: tabID))
        XCTAssertFalse(props.isEnabled)
        XCTAssertEqual(props.disabledReason, "Send or clear the pending handoff before changing location.")

        let result = await viewModel.selectExecutionLocation(.local, for: tabID)

        XCTAssertEqual(result, .blocked("This thread cannot change execution location right now."))
        XCTAssertEqual(session.worktreeBindings.first?.worktreeRootPath, worktree.path)
        XCTAssertEqual(session.pendingHandoff.payload, "fork handoff")
    }

    func testActiveStartedThreadRequiresConfirmationAndNeverCommitsStaleIdentityMidSwitch() async throws {
        let root = try makeTemporaryDirectory(named: "active-root")
        let oldWorktree = try makeTemporaryDirectory(named: "old-worktree")
        let viewModel = makeViewModel(workspacePath: root.path)
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        let sessionID = UUID()
        session.activeAgentSessionID = sessionID
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.runState = .running
        session.runID = UUID()
        session.activeHeadlessRunAttemptID = UUID()
        session.providerSessionID = "provider-from-old-cwd"
        session.worktreeBindings = [makeBinding(logicalRoot: root.path, worktreeRoot: oldWorktree.path)]
        session.items = [.user("in-flight prompt", sequenceIndex: 0)]
        session.pendingACPSteeringInstructions = [
            .init(
                id: UUID(),
                targetRunID: session.runID,
                targetRunAttemptID: session.activeHeadlessRunAttemptID,
                providerText: "provider-wrapped queued steering",
                interruptedPromptProviderText: "in-flight prompt",
                attachments: [],
                taggedFileAttachments: [],
                draftText: "queued ACP draft",
                optimisticUserItemID: nil,
                createdAt: Date()
            )
        ]
        session.pendingInstructions = ["queued shared draft"]
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let result = await viewModel.selectExecutionLocation(.local, for: tabID)

        XCTAssertEqual(result, .confirmationRequired(.activeRunStop))
        XCTAssertEqual(session.worktreeBindings.first?.worktreeRootPath, oldWorktree.path)
        XCTAssertEqual(session.providerSessionID, "provider-from-old-cwd")

        let applied = await viewModel.selectExecutionLocation(
            .local,
            for: tabID,
            confirmedChange: .activeRunStop
        )
        XCTAssertEqual(applied, .applied)
        XCTAssertTrue(session.worktreeBindings.isEmpty)
        XCTAssertNil(session.providerSessionID)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "queued ACP draft\nqueued shared draft")
        XCTAssertFalse(viewModel.retrieveDraftText(for: tabID).contains("in-flight prompt"))
        XCTAssertEqual(session.items.filter { $0.kind == .user }.map(\.text), ["in-flight prompt"])
    }

    func testExternalPrimaryRebindRejectsDuringActiveRunWithoutDroppingOldIdentity() async throws {
        let root = try makeTemporaryDirectory(named: "managed-active-root")
        let oldWorktree = try makeTemporaryDirectory(named: "managed-old-worktree")
        let newWorktree = try makeTemporaryDirectory(named: "managed-new-worktree")
        let viewModel = makeViewModel(workspacePath: root.path)
        let session = viewModel.session(for: UUID())
        let sessionID = UUID()
        session.activeAgentSessionID = sessionID
        session.runState = .running
        session.runID = UUID()
        session.providerSessionID = "managed-old-identity"
        let oldBinding = makeBinding(logicalRoot: root.path, worktreeRoot: oldWorktree.path, worktreeID: "wt_old")
        let newBinding = makeBinding(logicalRoot: root.path, worktreeRoot: newWorktree.path, worktreeID: "wt_new")
        session.worktreeBindings = [oldBinding]

        do {
            _ = try await viewModel.transitionWorktreeBindings(
                [newBinding],
                forSessionID: sessionID,
                intent: .externalManagement
            )
            XCTFail("Active external worktree rebinding must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Stop the active Agent run"), error.localizedDescription)
        }
        XCTAssertEqual(session.worktreeBindings, [oldBinding])
        XCTAssertEqual(session.providerSessionID, "managed-old-identity")
    }

    func testAgentRunStartExplicitWorktreeIDOverridesInheritanceSetting() async throws {
        for inheritWorktreeBindings in [true, false] {
            let fixture = try makeGitFixture()
            let parentWorktree = fixture.sandbox.appendingPathComponent("parent-worktree", isDirectory: true)
            let explicitWorktree = fixture.sandbox.appendingPathComponent("explicit-worktree", isDirectory: true)
            try runGit(["worktree", "add", "-b", "feature/parent-\(fixture.suffix)", parentWorktree.path, "HEAD"], cwd: fixture.repo)
            try runGit(["worktree", "add", "-b", "feature/explicit-\(fixture.suffix)", explicitWorktree.path, "HEAD"], cwd: fixture.repo)
            let descriptors = try await VCSService.shared.listGitWorktrees(at: fixture.repo)
            let explicitDescriptor = try XCTUnwrap(descriptors.first { samePath($0.path, explicitWorktree.path) })
            let window = try await makeWindow(root: fixture.repo)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
            let parentID = UUID()
            let parentBinding = makeBinding(
                logicalRoot: fixture.repo.path,
                worktreeRoot: parentWorktree.standardizedFileURL.path,
                worktreeID: "parent-\(fixture.suffix)"
            )
            installParentAgentSession(parentID, binding: parentBinding, sourceTabID: sourceTabID, in: window)
            let service = makeAgentRunStartService(window: window, sourceTabID: sourceTabID)
            var args: [String: Value] = [
                "op": .string("start"),
                "message": .string("explicit worktree overrides inheritance setting"),
                "detach": .bool(true),
                "timeout": .int(0),
                "worktree_id": .string(explicitDescriptor.worktreeID)
            ]
            if !inheritWorktreeBindings {
                args["inherit_worktree"] = .bool(false)
            }

            let value = try await service.execute(args: args)

            let object = try XCTUnwrap(value.objectValue)
            let sessionObject = try XCTUnwrap(object["session"]?.objectValue)
            let childSessionID = try XCTUnwrap(try UUID(uuidString: XCTUnwrap(object["session_id"]?.stringValue)))
            let childTabID = try XCTUnwrap(try UUID(uuidString: XCTUnwrap(sessionObject["context_id"]?.stringValue)))
            XCTAssertEqual(sessionObject["parent_session_id"]?.stringValue, parentID.uuidString)
            let bindings = try XCTUnwrap(object["worktree_bindings"]?.arrayValue)
            XCTAssertEqual(bindings.count, 1)
            let bindingObject = try XCTUnwrap(bindings.first?.objectValue)
            XCTAssertEqual(bindingObject["worktree_id"]?.stringValue, explicitDescriptor.worktreeID)
            XCTAssertEqual(bindingObject["worktree_root_path"]?.stringValue, explicitDescriptor.path)
            XCTAssertNotEqual(bindingObject["worktree_id"]?.stringValue, parentBinding.worktreeID)

            let child = window.agentModeViewModel.session(for: childTabID)
            XCTAssertEqual(child.activeAgentSessionID, childSessionID)
            XCTAssertEqual(child.parentSessionID, parentID)
            XCTAssertEqual(child.worktreeBindings.count, 1)
            XCTAssertEqual(child.worktreeBindings.first?.worktreeID, explicitDescriptor.worktreeID)
            XCTAssertEqual(child.worktreeBindings.first?.worktreeRootPath, explicitDescriptor.path)
        }
    }

    #if DEBUG
        @MainActor
        private final class BootstrapSocketNamespaceFixture {
            enum FixtureError: Error {
                case defaultSocketURLWasNotProduction
                case installedSocketURLDidNotResolve
                case trackedSessionMissing
                case ownedPathWasNotSocket
                case ownedSocketDidNotAppear
                case retainedAgentTaskDidNotFinish
                case trackedAgentTaskWasNotCleared
                case managerWasNotStopped
                case previousEnabledStateMissing
                case enabledStateWasNotRestored
                case resolvedSocketURLChangedBeforeRestore
                case productionSocketURLWasNotRestored
            }

            let productionSocketURL: URL
            let directoryURL: URL
            let socketURL: URL
            private(set) var trackedTabID: UUID?
            private(set) var trackedSession: AgentModeViewModel.TabSession?
            private(set) var firstObservedAgentTask: Task<Void, Never>?
            private(set) var acceptedSubmit = false
            private(set) var ownedSocketObserved = false
            private(set) var cleanupStarted = false
            private(set) var overrideInstalled = false
            private var previousEnabledState: Bool?
            private var retainedAgentTaskFinished = false

            static func make() throws -> BootstrapSocketNamespaceFixture {
                let productionSocketURL = MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL
                let directoryURL = URL(
                    fileURLWithPath: "/tmp/rpce-xctest-bs-\(getpid())-\(UUID().uuidString)",
                    isDirectory: true
                )
                let socketURL = directoryURL.appendingPathComponent("bootstrap.sock").standardizedFileURL
                let address = sockaddr_un()
                XCTAssertLessThanOrEqual(socketURL.path.utf8CString.count, MemoryLayout.size(ofValue: address.sun_path))
                XCTAssertNotEqual(socketURL, productionSocketURL)
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return .init(productionSocketURL: productionSocketURL, directoryURL: directoryURL, socketURL: socketURL)
            }

            init(productionSocketURL: URL, directoryURL: URL, socketURL: URL) {
                self.productionSocketURL = productionSocketURL
                self.directoryURL = directoryURL
                self.socketURL = socketURL
            }

            func install() async throws {
                let manager = ServerNetworkManager.shared
                guard await manager.debugResolvedBootstrapSocketURL() == productionSocketURL else {
                    throw FixtureError.defaultSocketURLWasNotProduction
                }
                previousEnabledState = await manager.debugIsEnabledForBootstrapSocketURLOverride()
                try await manager.debugInstallBootstrapSocketURLOverride(socketURL)
                overrideInstalled = true
                guard await manager.debugResolvedBootstrapSocketURL() == socketURL else {
                    throw FixtureError.installedSocketURLDidNotResolve
                }
            }

            func track(tabID: UUID, session: AgentModeViewModel.TabSession) {
                if let trackedTabID, let trackedSession {
                    XCTAssertEqual(trackedTabID, tabID)
                    XCTAssertTrue(trackedSession === session)
                    return
                }
                trackedTabID = tabID
                trackedSession = session
            }

            func acceptedSubmitAndAwaitOwnedSocket() async throws {
                acceptedSubmit = true
                guard trackedSession != nil else {
                    throw FixtureError.trackedSessionMissing
                }
                let deadline = ContinuousClock.now + .seconds(5)
                while ContinuousClock.now < deadline {
                    observeFirstAgentTaskIfNeeded()
                    if FileManager.default.fileExists(atPath: socketURL.path) {
                        let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
                        guard attributes[.type] as? FileAttributeType == .typeSocket else {
                            throw FixtureError.ownedPathWasNotSocket
                        }
                        ownedSocketObserved = true
                        return
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw FixtureError.ownedSocketDidNotAppear
            }

            func cleanup(window: WindowState) async throws {
                guard !cleanupStarted else { return }
                cleanupStarted = true

                if acceptedSubmit {
                    guard let trackedTabID, let trackedSession else {
                        throw FixtureError.trackedSessionMissing
                    }
                    observeFirstAgentTaskIfNeeded()
                    await window.agentModeViewModel.cancelAgentRun(tabID: trackedTabID, waitForCleanup: true)
                    if let firstObservedAgentTask {
                        firstObservedAgentTask.cancel()
                        try await boundedAwaitRetainedAgentTask(firstObservedAgentTask)
                    }
                    guard trackedSession.agentTask == nil else {
                        throw FixtureError.trackedAgentTaskWasNotCleared
                    }
                }

                await window.mcpServer.stopServer()
                ServiceRegistry.unregister(window.mcpServer.windowMCPToolCatalogService)
                await window.mcpServer.shutdownListener()

                let manager = ServerNetworkManager.shared
                guard await !(manager.isRunning()) else {
                    throw FixtureError.managerWasNotStopped
                }
                guard await manager.debugResolvedBootstrapSocketURL() == socketURL else {
                    throw FixtureError.resolvedSocketURLChangedBeforeRestore
                }
                try await manager.debugRestoreBootstrapSocketURLOverride(expected: socketURL)
                guard await manager.debugResolvedBootstrapSocketURL() == productionSocketURL else {
                    throw FixtureError.productionSocketURLWasNotRestored
                }
                guard let previousEnabledState else {
                    throw FixtureError.previousEnabledStateMissing
                }
                await manager.setEnabled(previousEnabledState)
                guard await manager.debugIsEnabledForBootstrapSocketURLOverride() == previousEnabledState else {
                    throw FixtureError.enabledStateWasNotRestored
                }
                guard await !(manager.isRunning()) else {
                    throw FixtureError.managerWasNotStopped
                }
                guard await manager.debugResolvedBootstrapSocketURL() == productionSocketURL else {
                    throw FixtureError.productionSocketURLWasNotRestored
                }
                overrideInstalled = false
                removeOwnedDirectory()
                WindowStatesManager.shared.unregisterWindowState(window)
            }

            func removeOwnedDirectory() {
                try? FileManager.default.removeItem(at: directoryURL)
            }

            private func observeFirstAgentTaskIfNeeded() {
                if firstObservedAgentTask == nil {
                    firstObservedAgentTask = trackedSession?.agentTask
                }
            }

            private func boundedAwaitRetainedAgentTask(_ task: Task<Void, Never>) async throws {
                retainedAgentTaskFinished = false
                let observer = Task { @MainActor [weak self] in
                    await task.value
                    self?.retainedAgentTaskFinished = true
                }
                let deadline = ContinuousClock.now + .seconds(5)
                while !retainedAgentTaskFinished, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard retainedAgentTaskFinished else {
                    observer.cancel()
                    throw FixtureError.retainedAgentTaskDidNotFinish
                }
            }
        }
    #endif

    private func withIsolatedBootstrapSocketNamespace(
        window: WindowState,
        operation: (BootstrapSocketNamespaceFixture) async throws -> Void
    ) async throws {
        #if DEBUG
            let namespace: BootstrapSocketNamespaceFixture
            do {
                namespace = try BootstrapSocketNamespaceFixture.make()
            } catch {
                WindowStatesManager.shared.unregisterWindowState(window)
                throw error
            }

            do {
                try await namespace.install()
                try await operation(namespace)
                try await namespace.cleanup(window: window)
            } catch {
                if namespace.overrideInstalled, !namespace.cleanupStarted {
                    do {
                        try await namespace.cleanup(window: window)
                    } catch {
                        XCTFail("Failed to contain isolated Agent Run bootstrap socket namespace: \(error)")
                        throw error
                    }
                } else if !namespace.overrideInstalled {
                    namespace.removeOwnedDirectory()
                    WindowStatesManager.shared.unregisterWindowState(window)
                }
                throw error
            }
        #else
            throw XCTSkip("Bootstrap socket URL override seam is DEBUG-only")
        #endif
    }

    private func makeAgentRunStartService(window: WindowState, sourceTabID: UUID?) -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: "agent-run-worktree-start", windowID: window.windowID)
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnSourceTabID: { _ in sourceTabID },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { target, _, _, _, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, _, _ in
                guard let sessionID = target.sessionID else {
                    throw MCPError.internalError("Test start target did not resolve a session ID.")
                }
                let bindings = agentModeVM.worktreeBindings(forAgentSessionID: sessionID, tabID: target.tabID)
                let session = agentModeVM.session(for: target.tabID)
                let snapshot = AgentRunMCPSnapshot(
                    sessionID: sessionID,
                    tabID: target.tabID,
                    sessionName: "Worktree Start Test",
                    agentRaw: agentRaw,
                    agentDisplayName: agentRaw.flatMap { AgentProviderKind(rawValue: $0)?.displayName },
                    modelRaw: modelRaw,
                    reasoningEffortRaw: reasoningEffortRaw,
                    status: .running,
                    statusText: "Test harness running",
                    latestAssistantPreview: nil,
                    interaction: nil,
                    transcriptItemCount: 0,
                    updatedAt: Date(),
                    parentSessionID: session.parentSessionID,
                    failureReason: nil,
                    worktreeBindings: bindings.map { AgentRunMCPSnapshot.WorktreeBinding(binding: $0) },
                    activeWorktreeMerges: []
                )
                return AgentExternalMCPRunStarter.StartOutcome(snapshot: snapshot, delivery: .startedRun)
            }
        )
        service.resolveSpawnParentSessionIDFromSourceTabID = { (sourceTabID: UUID, window: WindowState) async -> UUID? in
            window.agentModeViewModel.mcpSpawnParentSessionID(sourceTabID: sourceTabID)
        }
        return service
    }

    private func installParentAgentSession(
        _ parentID: UUID,
        binding: AgentSessionWorktreeBinding,
        sourceTabID: UUID,
        in window: WindowState
    ) {
        let source = window.agentModeViewModel.session(for: sourceTabID)
        source.activeAgentSessionID = parentID
        source.mcpControlContext = makeMCPControlContext(sessionID: parentID)
        source.worktreeBindings = [binding]
    }

    private func makeMCPControlContext(sessionID: UUID) -> AgentModeViewModel.AgentMCPControlContext {
        AgentModeViewModel.AgentMCPControlContext(
            sessionID: sessionID,
            activationID: UUID(),
            originatingConnectionID: nil,
            interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
            suppressUserNotifications: false,
            forceAutoEditEnabled: false,
            autoEditEnabledBeforeOverride: true,
            taskLabelKind: .pair
        )
    }

    private struct GitFixture {
        let sandbox: URL
        let repo: URL
        let suffix: String
    }

    private func makeGitFixture() throws -> GitFixture {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRunWorktreeStartTests-\(suffix)", isDirectory: true)
        let repo = sandbox.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init"], cwd: repo)
        try runGit(["config", "user.name", "RepoPrompt Test"], cwd: repo)
        try runGit(["config", "user.email", "repoprompt@example.test"], cwd: repo)
        try runGit(["config", "commit.gpgSign", "false"], cwd: repo)
        try runGit(["checkout", "-b", "main"], cwd: repo)
        try "original\n".write(to: repo.appendingPathComponent("Tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "Tracked.txt"], cwd: repo)
        try runGit(["commit", "-m", "Initial commit"], cwd: repo)
        return GitFixture(sandbox: sandbox, repo: repo.standardizedFileURL, suffix: String(suffix))
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            throw NSError(
                domain: "AgentRunWorktreeStartTests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(text)"]
            )
        }
    }

    private func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    private func makeWindow(root: URL) async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Agent Run Worktree Start \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "agentRunWorktreeStartTests")
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        _ = try await window.workspaceFileContextStore.loadRoot(path: root.path)
        return window
    }

    private func makeViewModel(workspacePath: String) -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspacePath: workspacePath,
            codexControllerFactory: { _, _, _, _, _, _ in WorktreeStartFakeCodexController() }
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRunWorktreeStartTests-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    private func makeBinding(
        logicalRoot: String,
        worktreeRoot: String,
        worktreeID: String = "wt_test",
        label: String? = nil
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-\(UUID().uuidString)",
            repositoryID: "gitrepo_test",
            repoKey: "test",
            logicalRootPath: logicalRoot,
            logicalRootName: "root",
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRoot,
            worktreeName: "worktree",
            branch: "feature/test",
            visualLabel: label,
            visualColorHex: "#3366FF",
            source: "test"
        )
    }
}

private final class WorktreeStartFakeCodexController: CodexSessionControlling {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func sendUserMessage(_ text: String) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
