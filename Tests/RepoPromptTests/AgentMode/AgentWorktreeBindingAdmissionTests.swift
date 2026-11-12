import Foundation
import MCP
import RepoPromptAgentProviderContracts
@testable import RepoPromptApp
import RepoPromptCodexProvider
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import RepoPromptVCS
@testable import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore
import XCTest

@MainActor
final class AgentWorktreeBindingAdmissionTests: XCTestCase {
    func testQueuedFollowUpCannotChangeExecutionLocation() async {
        let (viewModel, session, sessionID) = fixture()
        session.mcpFollowUpRunPending = true
        await assertRemovalRejected(viewModel, session: session, sessionID: sessionID)
    }

    func testTerminalPublicationCannotChangeExecutionLocation() async {
        let (viewModel, session, sessionID) = fixture()
        session.pendingSupersedingTurnCompletions = 1
        await assertRemovalRejected(viewModel, session: session, sessionID: sessionID)
    }

    func testActiveTurnCannotChangeExecutionLocation() async {
        let (viewModel, session, sessionID) = fixture()
        session.runState = .running
        await assertRemovalRejected(viewModel, session: session, sessionID: sessionID)
    }

    func testPendingInteractionRejectsBeforeCommitCallback() async throws {
        let (viewModel, session, sessionID) = fixture()
        session.waitingPrompt = "Old checkout question"
        var committed = false
        do {
            _ = try await viewModel.transitionWorktreeBindings(
                [], forSessionID: sessionID, intent: .externalManagement,
                beforeCommit: { committed = true }
            )
            XCTFail("Pending old-root interaction must not transfer")
        } catch {
            XCTAssertFalse(committed)
            XCTAssertEqual(session.worktreeBindings.count, 1)
        }
    }

    func testProviderOwnedTurnRejectsEvenWhenPublishedStateIsIdle() async throws {
        let (viewModel, session, sessionID) = fixture()
        let native = MonitorFakeNativeController()
        await native.setTurnInFlight(true)
        session.claudeController = native
        var committed = false
        do {
            _ = try await viewModel.transitionWorktreeBindings(
                [], forSessionID: sessionID, intent: .externalManagement,
                beforeCommit: { committed = true }
            )
            XCTFail("Provider-owned turn must block switching independently of UI state")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Claude runtime"))
            XCTAssertFalse(committed)
            XCTAssertFalse(session.isChangingExecutionLocation)
            XCTAssertEqual(session.worktreeBindings.count, 1)
            let shutdownCount = await native.shutdownCount
            XCTAssertEqual(shutdownCount, 0)
        }
    }

    func testActiveLifecycleOwnershipRejectsEvenWhenPublishedStateIsIdle() async {
        let (viewModel, session, sessionID) = fixture()
        _ = session.beginRunAttempt(source: "test")
        await assertRemovalRejected(viewModel, session: session, sessionID: sessionID)
    }

    func testExactNoOpPreservesActiveProviderAndDoesNotCommit() async throws {
        let (viewModel, session, sessionID) = fixture()
        session.runState = .running
        var committed = false
        let result = try await viewModel.transitionWorktreeBindings(
            session.worktreeBindings, forSessionID: sessionID, intent: .externalManagement,
            beforeCommit: { committed = true }
        )
        XCTAssertEqual(result, session.worktreeBindings)
        XCTAssertFalse(committed)
        XCTAssertEqual(session.runState, .running)
    }

    func testSecondaryExecutionMappingCannotChangeUnderActiveTurn() async throws {
        let git = try ReviewGitRepositoryFixture(name: "SecondaryBindingAdmission")
        defer { git.cleanup() }
        let logical = try git.makeRepository(named: "logical", files: ["README.md": "fixture\n"])
        let physical = git.sandbox.appendingPathComponent("physical")
        try git.runGit(["worktree", "add", "--detach", physical.path, "HEAD"], at: logical)
        let identity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: physical))
        let (viewModel, session, sessionID) = fixture()
        let primary = AgentSessionWorktreeBinding(
            id: "primary", repositoryID: identity.repository.repositoryID,
            repoKey: identity.repository.repoKey, logicalRootPath: "/tmp/logical-worktree-admission",
            logicalRootName: "Project", worktreeID: identity.worktreeID,
            worktreeRootPath: physical.path, commonGitDir: identity.repository.commonGitDir,
            isMainWorktree: false, source: "test"
        )
        let secondary = Self.copyBinding(primary, id: "secondary", logicalRootPath: "/tmp/secondary-logical")
        session.worktreeBindings = [primary, secondary]
        session.runState = .running
        var committed = false
        do {
            _ = try await viewModel.transitionWorktreeBindings(
                [primary], forSessionID: sessionID, intent: .externalManagement,
                beforeCommit: { committed = true }
            )
            XCTFail("Secondary MCP remapping must remain frozen during an active turn")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("active Agent run"))
            XCTAssertFalse(committed)
            XCTAssertEqual(session.worktreeBindings, [primary, secondary])
        }
    }

    func testSecondaryIdentityReplacementAtSamePathRejectsUnderActiveTurn() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let primary = fixture.session.worktreeBindings[0]
        let desiredSecondary = Self.copyBinding(primary, id: "secondary", logicalRootPath: "/tmp/second-project")
        let staleSecondary = AgentSessionWorktreeBinding(
            id: desiredSecondary.id, repositoryID: "previous-repository",
            repoKey: desiredSecondary.repoKey, logicalRootPath: desiredSecondary.logicalRootPath,
            logicalRootName: desiredSecondary.logicalRootName, worktreeID: "previous-worktree",
            worktreeRootPath: desiredSecondary.worktreeRootPath, source: "test"
        )
        fixture.session.worktreeBindings = [primary, staleSecondary]
        fixture.session.runState = .running
        var committed = false
        do {
            _ = try await fixture.viewModel.transitionWorktreeBindings(
                [primary, desiredSecondary], forSessionID: fixture.sessionID, intent: .externalManagement,
                beforeCommit: { committed = true }
            )
            XCTFail("Execution authority includes secondary Git identity, not only its path")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("active Agent run"))
            XCTAssertFalse(committed)
            XCTAssertEqual(fixture.session.worktreeBindings, [primary, staleSecondary])
        }
    }

    func testReturningToLogicalCheckoutRemovesOnlyThatRootsBinding() {
        let (_, session, _) = fixture()
        let primary = session.worktreeBindings[0]
        let secondary = Self.copyBinding(primary, id: "secondary", logicalRootPath: "/tmp/second-project")
        XCTAssertEqual(
            MCPWorktreeToolProvider.bindingsReturningToLogicalCheckout(
                [primary, secondary], logicalRootPath: primary.logicalRootPath,
                selectedWorktreePath: primary.logicalRootPath
            ), [secondary]
        )
        XCTAssertNil(MCPWorktreeToolProvider.bindingsReturningToLogicalCheckout(
            [primary, secondary], logicalRootPath: primary.logicalRootPath,
            selectedWorktreePath: secondary.worktreeRootPath
        ), "An arbitrary visible target must not be treated as a local-checkout unbind")
    }

    func testIdleSwitchInvalidatesRuntimeAndPersistsBeforeReply() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let native = MonitorFakeNativeController()
        fixture.session.claudeController = native
        fixture.session.providerSessionID = "old-provider-session"
        var savedBindings: [AgentSessionWorktreeBinding]?
        var savedWithGateHeld = false
        fixture.viewModel.test_setAgentSessionSaver { saved, _, _ in
            savedBindings = saved.worktreeBindings
            savedWithGateHeld = fixture.session.isChangingExecutionLocation
            return fixture.git.sandbox.appendingPathComponent("session.json")
        }
        var commits = 0
        let result = try await fixture.viewModel.transitionWorktreeBindings(
            [], forSessionID: fixture.sessionID, intent: .externalManagement,
            beforeCommit: { commits += 1 }
        )
        XCTAssertEqual(result, [])
        XCTAssertEqual(savedBindings, [])
        XCTAssertTrue(savedWithGateHeld, "The next-turn gate must remain held through durable persistence")
        XCTAssertEqual(commits, 1)
        XCTAssertNil(fixture.session.claudeController)
        XCTAssertNil(fixture.session.providerSessionID)
        XCTAssertNotNil(fixture.session.pendingHandoff.payload)
        XCTAssertFalse(fixture.session.isChangingExecutionLocation)
        let shutdownCount = await native.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
    }

    func testCancelledCommitPreparationLeavesBindingAndProviderUntouched() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let native = MonitorFakeNativeController()
        fixture.session.claudeController = native
        let original = fixture.session.worktreeBindings
        do {
            _ = try await fixture.viewModel.transitionWorktreeBindings(
                [], forSessionID: fixture.sessionID, intent: .externalManagement,
                beforeCommit: { throw CancellationError() }
            )
            XCTFail("Cancelled preparation must not apply")
        } catch is CancellationError {
            XCTAssertEqual(fixture.session.worktreeBindings, original)
            XCTAssertTrue(fixture.session.claudeController === native)
            XCTAssertFalse(fixture.session.isChangingExecutionLocation)
            let ownership = await fixture.prompt.workspaceFileContextStore.sessionWorktreeOwnershipDebugSnapshotForTesting()
            XCTAssertEqual(ownership.provisionalOwnerCount, 0)
            XCTAssertEqual(ownership.installedOwnerCount, 1)
            let shutdownCount = await native.shutdownCount
            XCTAssertEqual(shutdownCount, 0)
        }
    }

    func testPersistenceFailureDoesNotPretendCommittedSwitchWasRejected() async throws {
        let intents: [AgentModeViewModel.WorktreeBindingTransitionIntent] = [
            .externalManagement, .userExecutionLocationChange(confirmation: .startedThreadRestart)
        ]
        for intent in intents {
            let fixture = try await durableFixture()
            defer { fixture.git.cleanup() }
            struct SaveFailure: Error {}
            fixture.viewModel.test_setAgentSessionSaver { _, _, _ in throw SaveFailure() }
            var committed = false
            do {
                _ = try await fixture.viewModel.transitionWorktreeBindings(
                    [], forSessionID: fixture.sessionID, intent: intent,
                    beforeCommit: { committed = true }
                )
                XCTFail("A failed required save cannot produce an applied reply")
            } catch let partial as AgentSessionWorktreeRuntime.PartialTransition {
                XCTAssertTrue(committed, "The protected wrapper must settle this as indeterminate after commit")
                XCTAssertTrue(partial.bindingsPublished)
                XCTAssertFalse(partial.recoverySaved)
                XCTAssertEqual(fixture.session.worktreeBindings, [])
                XCTAssertFalse(fixture.session.isChangingExecutionLocation)
            } catch { XCTFail("Expected an honest postpublication receipt: \(error)") }
        }
    }

    func testOuterAdmissionCannotAdoptChangedBindingsResourcesOrReacquiredWriter() async throws {
        for change in ["bindings", "resources", "writer"] {
            let fixture = try await durableFixture()
            defer { fixture.git.cleanup() }
            let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
            let runtime = command.writer.scope.worktrees
            let originalCapture = try XCTUnwrap(runtime.captureResources)
            var resourcesCurrent = true
            runtime.captureResources = { command in
                guard let resources = originalCapture(command) else { return nil }
                return .init(
                    store: resources.store,
                    fallbackWorkspacePath: resources.fallbackWorkspacePath,
                    declaredRepoPaths: resources.declaredRepoPaths,
                    isCurrent: { resourcesCurrent && resources.isCurrent() }
                )
            }
            let admission = try runtime.admit(command)
            switch change {
            case "bindings": fixture.session.worktreeBindings = [Self.copyBinding(admission.bindings[0], visualLabel: "New metadata")]
            case "resources": resourcesCurrent = false
            default:
                fixture.viewModel.test_removeSession(tabID: fixture.session.tabID)
                fixture.viewModel.test_installLiveSession(fixture.session)
            }
            let expected = fixture.session.worktreeBindings
            do {
                // Resources/writer drift must refuse even an otherwise exact no-op.
                _ = try await runtime.transition(change == "bindings" ? [] : expected, admission: admission, intent: .externalManagement)
                XCTFail("Outer work must not be adopted by newer state: \(change)")
            } catch AgentSessionWorktreeRuntime.TransitionError.stale {} catch { XCTFail("\(error)") }
            XCTAssertEqual(fixture.session.worktreeBindings, expected)
            XCTAssertFalse(fixture.session.worktreeBindingTransitionInProgress)
        }
    }

    func testSynchronousCommandNoOpStillNeedsNoWorkspaceResources() async throws {
        let (viewModel, session, sessionID) = fixture()
        let command = try XCTUnwrap(viewModel.runtimeCommand(sessionID: sessionID))
        command.writer.scope.worktrees.captureResources = { _ in XCTFail("No-op must not capture resources")
            return nil
        }
        let result = try await command.writer.scope.worktrees.transition(session.worktreeBindings, command: command, intent: .externalManagement)
        XCTAssertEqual(result, session.worktreeBindings)
    }

    func testSessionAdminUnbindForwardsPublicationCallbackBeforeACompletionFailure() async throws {
        for busyDuringSave in [false, true] {
            let fixture = try await durableFixture()
            defer { fixture.git.cleanup() }
            let original = fixture.session.worktreeBindings
            XCTAssertFalse(original.isEmpty)
            struct SaveFailure: Error {}
            fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
                // A run that becomes pending while the required save awaits must not turn the
                // committed unbind into a pre-commit "not idle" refusal.
                if busyDuringSave { fixture.session.mcpFollowUpRunPending = true }
                throw SaveFailure()
            }
            var removed: Set<String>?
            var bindingsAtCallback: [AgentSessionWorktreeBinding]?
            do {
                _ = try await SessionAdminWindowsWorktreeHost().unbindWorktrees(
                    command: XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID)), worktreeID: nil,
                    isStillAuthorized: { true },
                    bindingsRemoved: { ids in
                        removed = ids
                        bindingsAtCallback = fixture.session.worktreeBindings
                    }
                )
                XCTFail("A failed required save cannot produce a completed unbind")
            } catch SessionAdminHostError.notIdle {
                XCTFail("A published unbind must not be reported as a busy target (busyDuringSave=\(busyDuringSave))")
            } catch {
                // The completion failure surfaces; the callback is the commit evidence.
            }
            XCTAssertEqual(removed, Set(original.map(\.worktreeID)), "busyDuringSave=\(busyDuringSave)")
            XCTAssertEqual(bindingsAtCallback, [], "The callback runs at publication")
            XCTAssertEqual(fixture.session.worktreeBindings, [])
        }
    }

    func testSessionAdminUnbindNoOpNeedsWriterButNotWorkspaceResources() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        command.writer.scope.worktrees.captureResources = { _ in nil }
        let host = SessionAdminWindowsWorktreeHost()
        let removed = try await host.unbindWorktrees(
            command: command, worktreeID: "not-bound", isStillAuthorized: { true },
            bindingsRemoved: { _ in XCTFail("No publication for a no-op") }
        )
        XCTAssertTrue(removed.isEmpty)
        do {
            _ = try await host.unbindWorktrees(
                command: command, worktreeID: nil, isStillAuthorized: { true }, bindingsRemoved: { _ in XCTFail() }
            )
            XCTFail("A real change requires workspace resources")
        } catch SessionAdminHostError.sessionUnavailable {} catch {
            XCTFail("Missing resources are not revoked consent: \(error)")
        }
        fixture.viewModel.test_removeSession(tabID: fixture.session.tabID)
        fixture.viewModel.test_installLiveSession(fixture.session)
        do {
            _ = try await host.unbindWorktrees(
                command: command, worktreeID: "not-bound", isStillAuthorized: { true }, bindingsRemoved: { _ in XCTFail() }
            )
            XCTFail("Even a no-op cannot adopt a reacquired writer")
        } catch SessionAdminHostError.authorityEnded {} catch { XCTFail("\(error)") }
    }

    func testVisualOnlyChangePreservesActiveRuntimeAndExecutionMapping() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let native = MonitorFakeNativeController()
        await native.setTurnInFlight(true)
        fixture.session.claudeController = native
        fixture.session.runState = .running
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in fixture.git.sandbox.appendingPathComponent("session.json") }
        let changed = Self.copyBinding(fixture.session.worktreeBindings[0], visualLabel: "Presentation only")
        let result = try await fixture.viewModel.transitionWorktreeBindings(
            [changed], forSessionID: fixture.sessionID, intent: .externalManagement
        )
        XCTAssertEqual(result, [changed])
        XCTAssertEqual(fixture.session.runState, .running)
        XCTAssertTrue(fixture.session.claudeController === native)
        let shutdownCount = await native.shutdownCount
        XCTAssertEqual(shutdownCount, 0)
    }

    func testVisibleFolderCollisionRejectsBeforeCommitWithoutOwnershipPromotion() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let binding = fixture.session.worktreeBindings[0]
        let store = fixture.prompt.workspaceFileContextStore
        await WorkspaceRootBindingProjectionMaterializer(store: store).release(sessionID: fixture.sessionID)
        let visiblePhysical = try await store.loadRoot(path: binding.worktreeRootPath)
        fixture.session.worktreeBindings = []
        let originalOwnership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
        var committed = false
        do {
            _ = try await fixture.viewModel.transitionWorktreeBindings(
                [binding], forSessionID: fixture.sessionID, intent: .externalManagement,
                beforeCommit: { committed = true }
            )
            XCTFail("Visible-folder ownership must not be promoted into session authority")
        } catch {
            XCTAssertFalse(committed)
            XCTAssertTrue(error.localizedDescription.contains("Remove that folder"), error.localizedDescription)
            XCTAssertEqual(fixture.session.worktreeBindings, [])
            let roots = await store.roots()
            XCTAssertEqual(roots.first { $0.id == visiblePhysical.id }?.kind, .primaryWorkspace)
            let ownership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
            XCTAssertEqual(ownership, originalOwnership)
        }
    }

    func testIdleSwitchAlignsMCPAndNativeExecutionAuthorityWithoutChangingBootstrapRoot() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let old = fixture.session.worktreeBindings[0]
        let logical = URL(fileURLWithPath: old.logicalRootPath)
        let target = fixture.git.sandbox.appendingPathComponent("physical-next")
        try fixture.git.runGit(["worktree", "add", "--detach", target.path, "HEAD"], at: logical)
        let identity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: target))
        let next = AgentSessionWorktreeBinding(
            id: old.id, repositoryID: identity.repository.repositoryID,
            repoKey: identity.repository.repoKey, logicalRootPath: old.logicalRootPath,
            logicalRootName: old.logicalRootName, worktreeID: identity.worktreeID,
            worktreeRootPath: target.path, commonGitDir: identity.repository.commonGitDir,
            isMainWorktree: false, source: "test"
        )
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in fixture.git.sandbox.appendingPathComponent("session.json") }
        let applied = try await fixture.viewModel.transitionWorktreeBindings(
            [next], forSessionID: fixture.sessionID, intent: .externalManagement
        )
        let roots = await fixture.prompt.workspaceFileContextStore.roots()
        let visible = roots.filter { $0.kind == .primaryWorkspace }.map {
            WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.standardizedFullPath)
        }
        let context = try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
            source: AgentWorkspaceLookupContextSource(activeAgentSessionID: fixture.sessionID, worktreeBindings: applied),
            visibleRoots: visible, store: fixture.prompt.workspaceFileContextStore
        )
        let projection = try XCTUnwrap(context.bindingProjection)
        XCTAssertEqual(projection.translateInputPath(logical.appendingPathComponent("README.md").path), target.appendingPathComponent("README.md").path)
        XCTAssertEqual(try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
            bindings: applied, fallbackWorkspacePath: logical.path
        ), target.path)
        let paths = try AgentWorktreeRuntimeWorkspaceResolver.codexRuntimeWorkspacePaths(
            bindings: applied, fallbackWorkspacePath: logical.path
        )
        XCTAssertEqual(paths.processLaunchDirectory, logical.path, "Bootstrap is intentionally logical, not proof of effective turn cwd")
        XCTAssertEqual(paths.executionDirectory, target.path)
        let sandbox = CodexNativeSessionController.appServerTurnSandboxPolicyPayload(
            mode: .workspaceWrite, executionDirectory: paths.executionDirectory
        )
        XCTAssertEqual(sandbox["writableRoots"] as? [String], [target.path])
        XCTAssertNotEqual(paths.executionDirectory, old.worktreeRootPath)
    }

    func testTargetIdentityChangeDuringCommitCallbackDoesNotPublishNewBinding() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let old = fixture.session.worktreeBindings[0]
        let target = fixture.git.sandbox.appendingPathComponent("physical-next")
        let logical = URL(fileURLWithPath: old.logicalRootPath)
        try fixture.git.runGit(["worktree", "add", "--detach", target.path, "HEAD"], at: logical)
        let identity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: target))
        let next = AgentSessionWorktreeBinding(
            id: old.id, repositoryID: identity.repository.repositoryID,
            repoKey: identity.repository.repoKey, logicalRootPath: old.logicalRootPath,
            logicalRootName: old.logicalRootName, worktreeID: identity.worktreeID,
            worktreeRootPath: target.path, commonGitDir: identity.repository.commonGitDir,
            isMainWorktree: false, source: "test"
        )
        var committed = false
        do {
            _ = try await fixture.viewModel.transitionWorktreeBindings(
                [next], forSessionID: fixture.sessionID, intent: .externalManagement,
                beforeCommit: {
                    committed = true
                    try fixture.git.runGit(["worktree", "remove", "--force", target.path], at: logical)
                }
            )
            XCTFail("A disappeared target must not be published after an awaited commit callback")
        } catch {
            XCTAssertTrue(committed, "Actual callback mutation remains post-commit indeterminate")
            XCTAssertEqual(fixture.session.worktreeBindings, [old])
            XCTAssertFalse(fixture.session.isChangingExecutionLocation)
            let ownership = await fixture.prompt.workspaceFileContextStore.sessionWorktreeOwnershipDebugSnapshotForTesting()
            XCTAssertEqual(ownership.provisionalOwnerCount, 0)
            XCTAssertEqual(ownership.installedOwnerCount, 1)
        }
    }

    func testCodexIdleProbeUsesExistingBoundedDeadlineAndFailurePreservesRuntime() async throws {
        let (viewModel, session, sessionID) = fixture()
        let controller = WorktreeProbeCodexController(failSnapshot: true)
        session.codexController = controller
        let original = session.worktreeBindings
        var committed = false
        do {
            _ = try await viewModel.transitionWorktreeBindings(
                [], forSessionID: sessionID, intent: .externalManagement,
                beforeCommit: { committed = true }
            )
            XCTFail("Unverified provider readiness must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not verify"))
            XCTAssertEqual(controller.requestedTimeouts, [2])
            XCTAssertFalse(committed)
            XCTAssertEqual(session.worktreeBindings, original)
            XCTAssertTrue(session.codexController === controller)
            XCTAssertFalse(session.isChangingExecutionLocation)
        }
    }

    func testCodexNotLoadedIsNotAssumedIdle() async {
        let (viewModel, session, sessionID) = fixture()
        session.codexController = WorktreeProbeCodexController(runtimeStatus: .notLoaded)
        await assertRemovalRejected(viewModel, session: session, sessionID: sessionID)
    }

    func testCancellationAfterProviderTeardownPersistsVisibleOldRootRecovery() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let original = fixture.session.worktreeBindings
        let native = WorktreeTeardownNativeController {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        fixture.session.claudeController = native
        var savedRecovery: AgentSession?
        var saverWasCancelled = true
        fixture.viewModel.test_setAgentSessionSaver { saved, _, _ in
            savedRecovery = saved
            saverWasCancelled = Task.isCancelled
            return fixture.git.sandbox.appendingPathComponent("session.json")
        }
        var committed = false
        let transition = Task { @MainActor in
            try await fixture.viewModel.transitionWorktreeBindings(
                [], forSessionID: fixture.sessionID, intent: .externalManagement,
                beforeCommit: { committed = true }
            )
        }
        do {
            _ = try await transition.value
            XCTFail("Cancelled post-teardown switch must not publish the target")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("previous execution binding is unchanged"))
            XCTAssertTrue(committed, "Retirement follows the real protected mutation fence")
            XCTAssertEqual(fixture.session.worktreeBindings, original)
            XCTAssertNil(fixture.session.claudeController)
            XCTAssertNotNil(fixture.session.pendingHandoff.payload)
            XCTAssertFalse(fixture.session.isChangingExecutionLocation)
            XCTAssertFalse(saverWasCancelled)
            let saved = try XCTUnwrap(savedRecovery)
            XCTAssertEqual(saved.worktreeBindings, original)
            XCTAssertNotNil(saved.pendingHandoffPayload)
            XCTAssertNotNil(saved.transcript, "Modern session persistence stores the transcript, not legacy flat items")
            XCTAssertTrue(saved.workingSourceItems().contains { $0.text.contains("provider runtime was retired") })
            let ownership = await fixture.prompt.workspaceFileContextStore.sessionWorktreeOwnershipDebugSnapshotForTesting()
            XCTAssertEqual(ownership.installedOwnerCount, 1)
            XCTAssertEqual(ownership.provisionalOwnerCount, 0)
        }
    }

    func testRealManageLinkRevokedDuringProviderTeardownDoesNotPublishBinding() async throws {
        let target = try await durableFixture()
        let observer = try await durableFixture(windowID: -992)
        defer { target.git.cleanup()
            observer.git.cleanup()
        }
        let original = target.session.worktreeBindings
        for node in [target, observer] {
            node.session.selectedAgent = .claudeCode
            let workspaceID = try XCTUnwrap(node.manager.activeWorkspaceID)
            XCTAssertTrue(node.manager.compareAndSetActiveAgentSessionID(
                expected: node.sessionID, replacement: node.sessionID, forTabID: node.session.tabID, inWorkspaceID: workspaceID
            ))
        }
        let host = LiveWindowEndpointHost()
        host.register(target.viewModel, windowID: -991)
        host.register(observer.viewModel, windowID: -992)
        let bridge = AgentSessionLinkRuntimeBridge(
            authority: DomainAgentSessionLinkAuthority(identity: .init(runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date())),
            host: host, toolAdvertisementInvalidator: { _ in }
        )
        let outcome = await bridge.addMonitorLink(observerSessionID: observer.sessionID, rawTargetSessionID: target.sessionID.uuidString)
        guard case .added = outcome else { return XCTFail("Expected Manage link, got \(outcome)") }
        let endpoint = try XCTUnwrap(host.agentSessionLinkCandidates().first { $0.sessionID == observer.sessionID }).domainEndpoint
        guard case let .success(authorized) = await bridge.authorizeTarget(
            operation: .monitorWorktreeBinding, observerEndpoint: endpoint, targetSessionID: target.sessionID
        ) else { return XCTFail("Expected live Manage authority") }
        let proof = await MCPWorktreeToolProvider.sessionLinkManageGrant(
            observerEndpoint: endpoint, targetSessionID: target.sessionID, bridge: bridge
        )
        let grant = try XCTUnwrap(proof)
        let observerID = observer.sessionID, targetID = target.sessionID
        target.session.claudeController = WorktreeTeardownNativeController {
            let stopped = await bridge.stopMonitorLink(
                observerSessionID: observerID, targetSessionID: targetID,
                linkID: authorized.lease.linkID, generation: authorized.lease.linkGeneration
            )
            XCTAssertEqual(stopped, .stopped)
        }
        target.viewModel.test_setAgentSessionSaver { _, _, _ in target.git.sandbox.appendingPathComponent("session.json") }
        do {
            _ = try await target.viewModel.transitionWorktreeBindings(
                [], forSessionID: target.sessionID, intent: .externalManagement,
                revalidateAuthority: grant.revalidate, commitAuthority: grant.commit
            )
            XCTFail("Unlink during teardown must prevent publication")
        } catch {}
        XCTAssertEqual(target.session.worktreeBindings, original)
        XCTAssertNil(target.session.claudeController, "The refusal must happen after the fake teardown, not during initial admission")
    }

    func testSessionAdminScopeRevokedDuringProviderTeardownReportsEffectsAndTypedCause() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let original = fixture.session.worktreeBindings
        let scopes = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        scopes.isGlobalAutoApproveEnabled = { false }
        let grantee = UUID()
        let request = try scopes.requestScope(
            requesterSessionID: grantee, requesterTabID: nil, kind: .session(targetSessionID: fixture.sessionID),
            capabilities: DomainDelegationScopeCapability.fullPreset, guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        let scope = try scopes.approve(requestID: request.id).get()
        fixture.session.claudeController = WorktreeTeardownNativeController {
            _ = await MainActor.run { scopes.revoke(scopeID: scope.id) }
        }
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in fixture.git.sandbox.appendingPathComponent("session.json") }
        do {
            try await SessionAdminWindowsWorktreeHost().transition(
                [], command: XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID)),
                isStillAuthorized: { scopes.hasLiveScope(grantedTo: grantee) }
            )
            XCTFail("Revoked scope must refuse publication")
        } catch let receipt as AgentSessionWorktreeRuntime.PartialTransition {
            XCTAssertTrue(receipt.providerRetired)
            XCTAssertFalse(receipt.bindingsPublished)
            XCTAssertTrue(receipt.recoverySaved)
            guard let cause = receipt.cause as? SessionAdminHostError, case .authorityEnded = cause else {
                return XCTFail("Lost typed authority-ended cause")
            }
        } catch {
            XCTFail("Lost scope-revocation cause: \(error)")
        }
        XCTAssertEqual(fixture.session.worktreeBindings, original)
        XCTAssertNil(fixture.session.claudeController)
        XCTAssertNotNil(fixture.session.pendingHandoff.payload)
    }

    func testSameRootRefusalDoesNotResurrectHandoffDeliveredDuringTransition() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let original = fixture.session.worktreeBindings
        let presentation = Self.copyBinding(original[0], visualLabel: "Refused label")
        fixture.session.pendingHandoff = .init(payload: "handoff P", createdAt: Date())
        let native = MonitorFakeNativeController()
        fixture.session.claudeController = native
        var saved: AgentSession?
        fixture.viewModel.test_setAgentSessionSaver { value, _, _ in
            saved = value
            return fixture.git.sandbox.appendingPathComponent("session.json")
        }
        do {
            _ = try await fixture.viewModel.transitionWorktreeBindings(
                [presentation], forSessionID: fixture.sessionID, intent: .externalManagement,
                beforeCommit: {
                    // The transition is suspended while another MainActor task sends. Use the
                    // provider-facing prepend and accepted-send consumption used by the runner.
                    try await Task { @MainActor in
                        XCTAssertFalse(fixture.session.isChangingExecutionLocation)
                        let text = fixture.viewModel.handoffRuntime.prependPendingHandoffIfNeeded("message", session: fixture.session)
                        _ = try await native.sendUserMessage(text)
                        fixture.session.pendingHandoff.clearAfterSend()
                    }.value
                    throw MCPError.invalidParams("Refused after concurrent send")
                }
            )
            XCTFail("The presentation change must be refused")
        } catch {}
        let sent = await native.sentMessages
        XCTAssertEqual(sent, ["handoff P\n\nmessage"])
        XCTAssertEqual(fixture.session.worktreeBindings, original)
        XCTAssertNil(fixture.session.pendingHandoff.payload, "A delivered handoff must not be resurrected by an unrelated rollback")
        XCTAssertNil(saved?.pendingHandoffPayload, "Rollback must not force-save the already-delivered payload")
        XCTAssertEqual(fixture.viewModel.handoffRuntime.prependPendingHandoffIfNeeded("next", session: fixture.session), "next")
    }

    func testSameRootRefusalDoesNotRestageHandoffAfterConcurrentCancelRun() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let original = fixture.session.worktreeBindings
        let presentation = Self.copyBinding(original[0], visualLabel: "Refused label")
        fixture.session.selectedAgent = .claudeCode
        fixture.session.installRunID(UUID())
        fixture.session.runState = .running
        fixture.session.pendingHandoff = .init(payload: "handoff P", createdAt: Date(), isStagedForSend: true)
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let runner = Task { @MainActor in
            for await _ in events {}
            // Model the runner's recordPendingHandoffSendOutcome(false) cancellation cleanup.
            if Task.isCancelled { fixture.session.pendingHandoff.isStagedForSend = false }
        }
        fixture.session.agentTask = runner
        defer { runner.cancel()
            continuation.finish()
        }
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in fixture.git.sandbox.appendingPathComponent("session.json") }
        do {
            _ = try await fixture.viewModel.transitionWorktreeBindings(
                [presentation], forSessionID: fixture.sessionID, intent: .externalManagement,
                beforeCommit: {
                    await fixture.viewModel.cancelAgentRun(tabID: fixture.session.tabID, completion: .terminalTeardownCompleted)
                    await runner.value
                    XCTAssertFalse(fixture.session.pendingHandoff.isStagedForSend, "The cancelled runner must unstage the undelivered handoff")
                    throw MCPError.invalidParams("Refused after concurrent cancellation")
                }
            )
            XCTFail("The presentation change must be refused")
        } catch {}
        XCTAssertEqual(fixture.session.worktreeBindings, original)
        XCTAssertEqual(fixture.session.pendingHandoff.payload, "handoff P")
        XCTAssertFalse(fixture.session.pendingHandoff.isStagedForSend, "Rollback must not undo cancelRun's unstage")
        XCTAssertEqual(fixture.viewModel.handoffRuntime.prependPendingHandoffIfNeeded("next", session: fixture.session), "handoff P\n\nnext")
    }

    func testRefusalDoesNotOverwriteNewerHandoffAfterTransitionStaging() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let newer = AgentModeViewModel.PendingHandoffState(payload: "newer handoff", createdAt: Date())
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in fixture.git.sandbox.appendingPathComponent("session.json") }
        do {
            _ = try await fixture.viewModel.transitionWorktreeBindings(
                [], forSessionID: fixture.sessionID, intent: .externalManagement,
                revalidateAuthority: {
                    if fixture.session.pendingHandoff.hasPayload {
                        fixture.session.pendingHandoff = newer
                        throw SessionAdminHostError.authorityEnded
                    }
                }
            )
            XCTFail("The transition must be refused after staging")
        } catch {}
        XCTAssertEqual(fixture.session.pendingHandoff, newer, "Rollback only owns its exact staged value")
    }

    func testRefusalAfterHandoffStagingRestoresOriginalHandoffBeforeRetirement() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let original = fixture.session.pendingHandoff
        let native = MonitorFakeNativeController()
        fixture.session.claudeController = native
        var saved: AgentSession?
        fixture.viewModel.test_setAgentSessionSaver { value, _, _ in
            saved = value
            return fixture.git.sandbox.appendingPathComponent("session.json")
        }
        do {
            _ = try await fixture.viewModel.transitionWorktreeBindings(
                [], forSessionID: fixture.sessionID, intent: .externalManagement,
                revalidateAuthority: {
                    if fixture.session.pendingHandoff != original { throw SessionAdminHostError.authorityEnded }
                }
            )
            XCTFail("Staged handoff must not survive a pre-retirement refusal")
        } catch {}
        XCTAssertEqual(fixture.session.pendingHandoff, original)
        XCTAssertEqual(saved?.pendingHandoffPayload, original.payload)
        XCTAssertTrue(fixture.session.claudeController === native)
        let shutdowns = await native.shutdownCount
        XCTAssertEqual(shutdowns, 0)
    }

    func testRevokedAuthorityDuringProviderTeardownDoesNotPublishBinding() async throws {
        for unbind in [true, false] {
            let fixture = try await durableFixture()
            defer { fixture.git.cleanup() }
            let original = fixture.session.worktreeBindings
            let next = try makeNextBinding(fixture)
            let grant = WorktreeTestManageGrant()
            fixture.session.claudeController = WorktreeTeardownNativeController {
                await grant.revoke()
            }
            fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
                fixture.git.sandbox.appendingPathComponent("session.json")
            }
            do {
                _ = try await fixture.viewModel.transitionWorktreeBindings(
                    unbind ? [] : [next], forSessionID: fixture.sessionID, intent: .externalManagement,
                    beforeCommit: { try await grant.validate() },
                    revalidateAuthority: { try await grant.validate() }
                )
                XCTFail("Revocation during the awaited teardown must refuse the binding change")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("revoked"), error.localizedDescription)
            }
            XCTAssertEqual(fixture.session.worktreeBindings, original)
            XCTAssertFalse(fixture.session.isChangingExecutionLocation)
            XCTAssertFalse(fixture.session.worktreeBindingTransitionInProgress)
            XCTAssertTrue(FileManager.default.fileExists(atPath: next.worktreeRootPath), "A created but unbound worktree stays available for manual cleanup")
        }
    }

    func testPublicationFenceRefusalReleasesInstalledDestinationOwnership() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let original = fixture.session.worktreeBindings
        let next = try makeNextBinding(fixture)
        fixture.session.claudeController = MonitorFakeNativeController()
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in fixture.git.sandbox.appendingPathComponent("session.json") }
        var fences = 0
        do {
            _ = try await fixture.viewModel.transitionWorktreeBindings(
                [next], forSessionID: fixture.sessionID, intent: .externalManagement,
                commitAuthority: { body in
                    fences += 1
                    if fences == 3 { throw MCPError.invalidParams("Manage grant revoked at publication") }
                    try body()
                }
            )
            XCTFail("The final publication fence must refuse a revoked grant")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("revoked at publication"), error.localizedDescription)
        }
        XCTAssertEqual(fixture.session.worktreeBindings, original)
        XCTAssertNotNil(fixture.session.pendingHandoff.payload)
        XCTAssertTrue(fixture.session.items.contains { $0.text.contains("previous execution binding is unchanged") })
        let store = fixture.prompt.workspaceFileContextStore
        let ownership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
        XCTAssertEqual(ownership.installedOwnerCount, 0, "The refused destination must not remain installed")
        XCTAssertEqual(ownership.provisionalOwnerCount, 0)
        let recovered = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(sessionID: fixture.sessionID, bindings: original)
        XCTAssertNotNil(recovered, "The unchanged old binding can rebuild its released projection")
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.worktreeRootPath))
    }

    func testPublicationRefusalPreservesReusedRootsOfAnActiveProvider() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let original = fixture.session.worktreeBindings
        let presentation = Self.copyBinding(original[0], visualLabel: "Refused label", head: "changed-head")
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in fixture.git.sandbox.appendingPathComponent("session.json") }
        let native = MonitorFakeNativeController()
        await native.setTurnInFlight(true)
        fixture.session.claudeController = native
        fixture.session.runState = .running
        defer {
            fixture.session.runState = .idle
            fixture.session.claudeController = nil
        }
        do {
            _ = try await fixture.viewModel.transitionWorktreeBindings(
                [presentation], forSessionID: fixture.sessionID, intent: .externalManagement,
                commitAuthority: { _ in throw MCPError.invalidParams("Manage grant revoked") }
            )
            XCTFail("The final fence must refuse the presentation change")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("revoked"), error.localizedDescription)
        }
        XCTAssertEqual(fixture.session.worktreeBindings, original)
        XCTAssertTrue(fixture.session.claudeController === native)
        XCTAssertEqual(fixture.session.runState, .running)
        let ownership = await fixture.prompt.workspaceFileContextStore.sessionWorktreeOwnershipDebugSnapshotForTesting()
        XCTAssertEqual(ownership.installedOwnerCount, 1, "Reused old roots still belong to the active provider")
        XCTAssertEqual(ownership.provisionalOwnerCount, 0)
        let shutdowns = await native.shutdownCount
        XCTAssertEqual(shutdowns, 0)
        _ = try await fixture.viewModel.transitionWorktreeBindings(
            [presentation], forSessionID: fixture.sessionID, intent: .externalManagement,
            beforeCommit: { fixture.session.runState = .idle }
        )
        XCTAssertEqual(fixture.session.worktreeBindings, [presentation], "Authorized same-root edits survive a run-state change")
        XCTAssertTrue(fixture.session.claudeController === native)
    }

    func testLogicalRootLookupAndUnbindAgreeAcrossSymlinkAlias() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let primary = fixture.session.worktreeBindings[0]
        let alias = fixture.git.sandbox.appendingPathComponent("logical-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: primary.logicalRootPath))
        let aliased = Self.copyBinding(primary, logicalRootPath: alias.path)
        XCTAssertEqual(MCPWorktreeToolProvider.bindingForLogicalRoot([aliased], logicalRootPath: primary.logicalRootPath), aliased)
        XCTAssertEqual(MCPWorktreeToolProvider.bindingsReturningToLogicalCheckout(
            [aliased], logicalRootPath: primary.logicalRootPath, selectedWorktreePath: alias.path
        ), [])
    }

    func testLogicalCheckoutVisualArgumentsAreRejectedRatherThanClaimedApplied() throws {
        XCTAssertThrowsError(try MCPWorktreeToolProvider.validateLogicalCheckoutVisualArguments(["color": .string("#112233")])) {
            XCTAssertTrue($0.localizedDescription.contains("Visual updates are not applied"))
        }
        XCTAssertNoThrow(try MCPWorktreeToolProvider.validateLogicalCheckoutVisualArguments([:]))
    }

    func testRequestedVisualColorIsValidatedWithoutCrossingMutationFence() throws {
        XCTAssertThrowsError(try MCPWorktreeToolProvider.validatedPlannedVisualColor("#BAD")) {
            XCTAssertTrue($0.localizedDescription.contains("#RRGGBB"))
        }
        XCTAssertEqual(try MCPWorktreeToolProvider.validatedPlannedVisualColor(" #abcdef "), "#ABCDEF")
        XCTAssertNil(try MCPWorktreeToolProvider.validatedPlannedVisualColor(nil))
    }

    func testPersistedVisualIdentityIsTheExactPlanDespiteInterveningSettingsChange() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let suite = "WorktreeVisualPlan-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fixture.git.sandbox.appendingPathComponent("settings.json")))
        let planned = WorktreeVisualIdentity(label: "Planned", colorHex: "#112233", iconName: "branch", markerStyle: .capsule, updatedAt: Date(timeIntervalSince1970: 123))
        _ = try store.ensureWorktreeVisualIdentity(repositoryID: "repo", worktreeID: "wt", label: "Intervening", colorHex: "#445566", commit: false)
        try MCPWorktreeToolProvider.persistPlannedVisualIdentity(planned, repositoryID: "repo", worktreeID: "wt", store: store)
        XCTAssertEqual(store.worktreeVisualIdentity(repositoryID: "repo", worktreeID: "wt"), planned)
    }

    func testInstalledSessionRootOwnershipRemainsReusable() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let store = fixture.prompt.workspaceFileContextStore
        let before = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
        let preparation = try await WorkspaceRootBindingProjectionMaterializer(store: store).prepare(
            sessionID: fixture.sessionID, bindings: fixture.session.worktreeBindings
        )
        XCTAssertTrue(preparation.ownership.reusesInstalledOwnership)
        let after = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
        XCTAssertEqual(before, after)
    }

    // MARK: - Self relocation from a live turn

    func testSelfRelocationFromLiveTurnSchedulesWithoutTouchingRunningProvider() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let turn = try await liveSelfTurn(fixture)
        let original = fixture.session.worktreeBindings
        let next = try makeNextBinding(fixture)
        var recorded = false
        let scheduled = try await fixture.viewModel.scheduleSelfWorktreeRelocation(
            [next], forSessionID: fixture.sessionID,
            originRunID: turn.runID, originRunAttemptID: turn.ownership.attemptID,
            beforeRecord: { recorded = true }
        )
        let pending = try XCTUnwrap(scheduled, "A self switch from the live turn must be deferred, not rejected")
        XCTAssertTrue(recorded)
        XCTAssertEqual(pending.phase, .scheduled)
        XCTAssertEqual(fixture.session.pendingSelfWorktreeRelocation, pending)
        XCTAssertEqual(fixture.session.worktreeBindings, original, "The running turn keeps its execution roots")
        XCTAssertEqual(fixture.session.runState, .running)
        XCTAssertTrue(fixture.session.claudeController === turn.native)
        let shutdownCount = await turn.native.shutdownCount
        XCTAssertEqual(shutdownCount, 0)
    }

    func testSelfRelocationCannotCrossWriterReacquisitionAtRecordOrTerminalBoundary() async throws {
        for duringRecord in [true, false] {
            let fixture = try await durableFixture()
            defer { fixture.git.cleanup() }
            let turn = try await liveSelfTurn(fixture)
            let original = fixture.session.worktreeBindings
            let next = try makeNextBinding(fixture)
            @MainActor func replaceWriter() {
                fixture.viewModel.test_removeSession(tabID: fixture.session.tabID)
                fixture.viewModel.test_installLiveSession(fixture.session)
            }
            if duringRecord {
                do {
                    _ = try await fixture.viewModel.scheduleSelfWorktreeRelocation(
                        [next], forSessionID: fixture.sessionID,
                        originRunID: turn.runID, originRunAttemptID: turn.ownership.attemptID,
                        beforeRecord: { replaceWriter() }
                    )
                    XCTFail("The old request cannot schedule on the reacquired writer")
                } catch {}
            } else {
                _ = try await fixture.viewModel.scheduleSelfWorktreeRelocation(
                    [next], forSessionID: fixture.sessionID,
                    originRunID: turn.runID, originRunAttemptID: turn.ownership.attemptID
                )
                await endTurn(fixture, turn, state: .completed)
                replaceWriter()
                let items = fixture.session.items.count
                fixture.viewModel.test_selfWorktreeRelocationContinuationStarter = { _, _ in XCTFail("No successor continuation") }
                fixture.viewModel.selfWorktreeRelocationTerminalSettled(
                    session: fixture.session, revision: revision(turn, state: .completed),
                    publication: .accepted(successorEpoch: nil), teardownSettled: { true }
                )
                XCTAssertEqual(fixture.session.items.count, items, "No old-operation transcript row on the successor")
            }
            XCTAssertNil(fixture.session.pendingSelfWorktreeRelocation)
            XCTAssertEqual(fixture.session.worktreeBindings, original)
        }
    }

    func testSelfRelocationReleasesOnlyItsReservationAfterWriterReplacementDuringSave() async throws {
        enum SaveFailure: Error { case expected }
        for successorReserves in [false, true] {
            let fixture = try await durableFixture()
            defer { fixture.git.cleanup() }
            let turn = try await liveSelfTurn(fixture)
            let next = try makeNextBinding(fixture)
            _ = try await fixture.viewModel.scheduleSelfWorktreeRelocation(
                [next], forSessionID: fixture.sessionID,
                originRunID: turn.runID, originRunAttemptID: turn.ownership.attemptID
            )
            await endTurn(fixture, turn, state: .completed)
            var successorItems: Int?
            fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
                guard successorItems == nil, fixture.session.worktreeBindings == [next] else {
                    return fixture.git.sandbox.appendingPathComponent("session.json")
                }
                XCTAssertTrue(fixture.session.mcpFollowUpRunPending)
                fixture.viewModel.test_removeSession(tabID: fixture.session.tabID)
                fixture.viewModel.test_installLiveSession(fixture.session)
                if successorReserves { fixture.session.mcpFollowUpRunPending = true }
                successorItems = fixture.session.items.count
                throw SaveFailure.expected
            }
            fixture.viewModel.test_selfWorktreeRelocationContinuationStarter = { _, _ in XCTFail("No successor continuation") }
            fixture.viewModel.selfWorktreeRelocationTerminalSettled(
                session: fixture.session, revision: revision(turn, state: .completed),
                publication: .accepted(successorEpoch: nil), teardownSettled: { true }
            )
            for _ in 0 ..< 1000 where fixture.session.pendingSelfWorktreeRelocation != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(successorItems, "Exercise the post-publication required save")
            XCTAssertEqual(fixture.session.items.count, successorItems)
            XCTAssertNil(fixture.session.pendingSelfWorktreeRelocation)
            XCTAssertEqual(fixture.session.mcpFollowUpRunPending, successorReserves)
            XCTAssertNil(fixture.session.selfWorktreeRelocationFollowUpOwner)
        }
    }

    func testSelfRelocationReportsUnavailableWorkspaceOnItsOriginalWriter() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let turn = try await liveSelfTurn(fixture)
        let original = fixture.session.worktreeBindings
        _ = try await fixture.viewModel.scheduleSelfWorktreeRelocation(
            [makeNextBinding(fixture)], forSessionID: fixture.sessionID,
            originRunID: turn.runID, originRunAttemptID: turn.ownership.attemptID
        )
        await endTurn(fixture, turn, state: .completed)
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        command.writer.scope.worktrees.captureResources = { _ in nil }
        fixture.viewModel.test_selfWorktreeRelocationContinuationStarter = { _, _ in XCTFail("No unavailable-workspace continuation") }
        fixture.viewModel.selfWorktreeRelocationTerminalSettled(
            session: fixture.session, revision: revision(turn, state: .completed),
            publication: .accepted(successorEpoch: nil), teardownSettled: { true }
        )
        for _ in 0 ..< 200 where fixture.session.pendingSelfWorktreeRelocation != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(fixture.session.pendingSelfWorktreeRelocation)
        XCTAssertEqual(fixture.session.worktreeBindings, original)
        XCTAssertTrue(fixture.session.items.contains { $0.kind == .system && $0.text.contains("workspace was unavailable") })
    }

    func testUITransitionCannotReleaseSuccessorLocationGateAfterRequiredSave() async throws {
        enum SaveFailure: Error { case expected }
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        fixture.viewModel.test_setCurrentTabIDOverride(fixture.session.tabID)
        let successorGate = UUID()
        var saved = false
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
            saved = true
            XCTAssertTrue(fixture.session.isChangingExecutionLocation)
            fixture.viewModel.test_removeSession(tabID: fixture.session.tabID)
            fixture.viewModel.test_installLiveSession(fixture.session)
            fixture.session.isChangingExecutionLocation = true
            fixture.session.executionLocationChangeOwner = successorGate
            throw SaveFailure.expected
        }
        let result = await fixture.viewModel.selectExecutionLocation(
            .local, for: fixture.session.tabID, confirmedChange: .startedThreadRestart
        )
        guard case let .blocked(detail) = result else { return XCTFail("Expected post-effect failure, got \(result)") }
        XCTAssertTrue(saved)
        XCTAssertTrue(detail.contains("bindings published=true"))
        XCTAssertTrue(fixture.session.isChangingExecutionLocation)
        XCTAssertEqual(fixture.session.executionLocationChangeOwner, successorGate)
    }

    func testSelfRelocationAppliesAtCompletedTerminalAndContinuesInNewLocation() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let turn = try await liveSelfTurn(fixture)
        let next = try makeNextBinding(fixture)
        _ = try await fixture.viewModel.scheduleSelfWorktreeRelocation(
            [next], forSessionID: fixture.sessionID,
            originRunID: turn.runID, originRunAttemptID: turn.ownership.attemptID
        )
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in fixture.git.sandbox.appendingPathComponent("session.json") }
        let continued = expectation(description: "automatic continuation")
        var continuation: (bindings: [AgentSessionWorktreeBinding], handoffStaged: Bool, reserved: Bool, message: String)?
        fixture.viewModel.test_selfWorktreeRelocationContinuationStarter = { session, message in
            continuation = (
                session.worktreeBindings, session.pendingHandoff.payload != nil,
                session.mcpFollowUpRunPending, message
            )
            continued.fulfill()
        }
        await endTurn(fixture, turn, state: .completed)
        fixture.viewModel.selfWorktreeRelocationTerminalSettled(
            session: fixture.session, revision: revision(turn, state: .completed),
            publication: .accepted(successorEpoch: nil), teardownSettled: { true }
        )
        await fulfillment(of: [continued], timeout: 10)
        let started = try XCTUnwrap(continuation)
        XCTAssertEqual(started.bindings, [next], "The continuation starts only after the binding is published")
        XCTAssertTrue(started.handoffStaged, "The fresh provider in the new cwd receives the conversation handoff")
        XCTAssertTrue(started.reserved, "The next turn stays reserved from binding publication until the continuation starts")

        XCTAssertTrue(started.message.contains(next.worktreeRootPath))
        XCTAssertEqual(fixture.session.worktreeBindings, [next])
        XCTAssertNil(fixture.session.pendingSelfWorktreeRelocation)
        XCTAssertNil(fixture.session.claudeController, "The old-root provider is retired, never rerouted")
        XCTAssertFalse(fixture.session.isChangingExecutionLocation)
        // The test starter does not start a run, so the reservation must not leak.
        for _ in 0 ..< 200 where fixture.session.mcpFollowUpRunPending {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(fixture.session.mcpFollowUpRunPending)
        XCTAssertTrue(fixture.session.items.contains { $0.kind == .system && $0.text.contains("Execution worktree switched") })
        let shutdownCount = await turn.native.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
    }

    func testStoppedFailedOrSucceededOriginTurnDropsSelfRelocationVisibly() async throws {
        let cases: [(AgentSessionRunState, AgentRunEpochTransitionKind?, String)] = [
            (.cancelled, nil, "stopped"),
            (.failed, nil, "failed"),
            (.completed, .relatedFollowUp, "queued input")
        ]
        for (state, successor, reason) in cases {
            let fixture = try await durableFixture()
            defer { fixture.git.cleanup() }
            let turn = try await liveSelfTurn(fixture)
            let original = fixture.session.worktreeBindings
            _ = try await fixture.viewModel.scheduleSelfWorktreeRelocation(
                [makeNextBinding(fixture)], forSessionID: fixture.sessionID,
                originRunID: turn.runID, originRunAttemptID: turn.ownership.attemptID
            )
            fixture.viewModel.test_selfWorktreeRelocationContinuationStarter = { _, _ in
                XCTFail("A dropped switch must not start a continuation (\(state))")
            }
            await endTurn(fixture, turn, state: state)
            fixture.viewModel.selfWorktreeRelocationTerminalSettled(
                session: fixture.session, revision: revision(turn, state: state, successor: successor),
                publication: .accepted(successorEpoch: nil), teardownSettled: { true }
            )
            XCTAssertNil(fixture.session.pendingSelfWorktreeRelocation, "\(state)")
            XCTAssertEqual(fixture.session.worktreeBindings, original)
            XCTAssertTrue(
                fixture.session.items.contains { $0.kind == .system && $0.text.contains(reason) },
                "The dropped switch is visible in the transcript (\(state))"
            )
        }
    }

    func testExplicitStopBeforeOrAfterBoundaryHookCancelsSwitchAndContinuation() async throws {
        for stopBeforeHook in [true, false] {
            let fixture = try await durableFixture()
            defer { fixture.git.cleanup() }
            let turn = try await liveSelfTurn(fixture)
            let original = fixture.session.worktreeBindings
            _ = try await fixture.viewModel.scheduleSelfWorktreeRelocation(
                [makeNextBinding(fixture)], forSessionID: fixture.sessionID,
                originRunID: turn.runID, originRunAttemptID: turn.ownership.attemptID
            )
            fixture.viewModel.test_selfWorktreeRelocationContinuationStarter = { _, _ in
                XCTFail("Stop must withdraw the continuation")
            }
            await endTurn(fixture, turn, state: .completed)
            // Before: Stop lands while the barrier awaits publication. After: the apply task has
            // not run yet. Either way the fence captured at scheduling withdraws the switch.
            if stopBeforeHook { fixture.session.stopState.invalidateQueuedDeliveries() }
            fixture.viewModel.selfWorktreeRelocationTerminalSettled(
                session: fixture.session, revision: revision(turn, state: .completed),
                publication: .accepted(successorEpoch: nil), teardownSettled: { true }
            )
            if !stopBeforeHook { fixture.session.stopState.invalidateQueuedDeliveries() }
            for _ in 0 ..< 200 where fixture.session.pendingSelfWorktreeRelocation != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(fixture.session.pendingSelfWorktreeRelocation)
            XCTAssertEqual(fixture.session.worktreeBindings, original)
            XCTAssertTrue(fixture.session.claudeController === turn.native)
            XCTAssertFalse(fixture.session.mcpFollowUpRunPending)
            XCTAssertTrue(fixture.session.items.contains { $0.kind == .system && $0.text.contains("cancelled by Stop") })
        }
    }

    func testSelfRelocationIsNotDeferredForStaleOriginOrPresentationOnlyChange() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let turn = try await liveSelfTurn(fixture)
        let staleAttempt = try await fixture.viewModel.scheduleSelfWorktreeRelocation(
            [makeNextBinding(fixture)], forSessionID: fixture.sessionID,
            originRunID: turn.runID, originRunAttemptID: UUID()
        )
        XCTAssertNil(staleAttempt, "Only the exact live origin attempt may defer; others keep the active-run rejection")
        let visualOnly = Self.copyBinding(fixture.session.worktreeBindings[0], visualLabel: "Presentation only")
        let presentation = try await fixture.viewModel.scheduleSelfWorktreeRelocation(
            [visualOnly], forSessionID: fixture.sessionID,
            originRunID: turn.runID, originRunAttemptID: turn.ownership.attemptID
        )
        XCTAssertNil(presentation, "Presentation-only changes apply immediately through the ordinary transition")
        XCTAssertNil(fixture.session.pendingSelfWorktreeRelocation)
    }

    func testSecondSelfRequestInSameTurnIsRefusedAndFirstPendingSwitchIsPreserved() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        // Two logical roots: A (the fixture's primary) and B, both currently in the same checkout.
        let rootA = fixture.session.worktreeBindings[0]
        let rootB = Self.copyBinding(rootA, id: "secondary", logicalRootPath: "/tmp/second-project")
        fixture.session.worktreeBindings = [rootA, rootB]
        let turn = try await liveSelfTurn(fixture)
        let next = try makeNextBinding(fixture)
        let movedA = [next, rootB]
        let first = try await fixture.viewModel.scheduleSelfWorktreeRelocation(
            movedA, forSessionID: fixture.sessionID,
            originRunID: turn.runID, originRunAttemptID: turn.ownership.attemptID
        )
        let pending = try XCTUnwrap(first)

        let movedB = [rootA, Self.copyBinding(next, id: rootB.id, logicalRootPath: rootB.logicalRootPath)]
        let followUps: [(String, [AgentSessionWorktreeBinding])] = [
            ("other logical root", movedB),
            ("same root repeated", movedA),
            ("return to current bindings", [rootA, rootB])
        ]
        for (label, desired) in followUps {
            var committed = false
            do {
                _ = try await fixture.viewModel.scheduleSelfWorktreeRelocation(
                    desired, forSessionID: fixture.sessionID,
                    originRunID: turn.runID, originRunAttemptID: turn.ownership.attemptID,
                    beforeRecord: { committed = true }
                )
                XCTFail("A second self request in the same turn must be refused (\(label))")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Only one switch is allowed per turn"), "\(label): \(error)")
                XCTAssertTrue(error.localizedDescription.contains(pending.id.uuidString), label)
                XCTAssertFalse(committed, "Refused before the mutation fence (\(label))")
            }
            XCTAssertEqual(fixture.session.pendingSelfWorktreeRelocation, pending, "First switch unchanged (\(label))")
        }

        // The provider's no-op and presentation-only paths use the same owner guard before committing.
        XCTAssertThrowsError(try fixture.viewModel.requireNoPendingSelfWorktreeRelocation(
            forSessionID: fixture.sessionID, originRunAttemptID: turn.ownership.attemptID
        ))
        XCTAssertNoThrow(try fixture.viewModel.requireNoPendingSelfWorktreeRelocation(
            forSessionID: fixture.sessionID, originRunAttemptID: UUID()
        ), "Only the turn that scheduled the switch is limited")
        XCTAssertEqual(fixture.session.pendingSelfWorktreeRelocation?.desiredBindings, movedA)
        XCTAssertEqual(fixture.session.worktreeBindings, [rootA, rootB], "Nothing applies before the turn ends")
    }

    func testPendingApplicationIsReportedInReplyAndFormattedOutput() throws {
        let (viewModel, session, sessionID) = fixture()
        let command = try XCTUnwrap(viewModel.runtimeCommand(sessionID: sessionID))
        let relocation = AgentSelfWorktreeRelocation(
            id: UUID(), writer: command.identity, originRunID: UUID(), originRunAttemptID: UUID(),
            previousBindings: [], desiredBindings: [],
            stopFence: AgentRunStartStopFence(session: session)
        )
        let reply = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "select", pendingApplication: MCPWorktreeToolProvider.pendingApplicationDTO(relocation)
        )
        let value = try Value(reply)
        let pending = try XCTUnwrap(value.objectValue?["pending_application"]?.objectValue)
        XCTAssertEqual(pending["state"]?.stringValue, "scheduled")
        XCTAssertEqual(pending["applies_after"]?.stringValue, "current_turn_completes")
        XCTAssertEqual(pending["continuation"]?.stringValue, "automatic")
        let text = ToolOutputFormatter.formatManageWorktree(args: [:], value: value).compactMap {
            if case let .text(text, _, _) = $0 { return text }
            return nil
        }.joined()
        XCTAssertTrue(text.contains("Pending Switch"))
        XCTAssertTrue(text.contains(relocation.id.uuidString))
    }

    private struct LiveSelfTurn {
        let runID: UUID
        let ownership: AgentRunOwnership
        let native: MonitorFakeNativeController
    }

    private func liveSelfTurn(_ fixture: DurableFixture) async throws -> LiveSelfTurn {
        let native = MonitorFakeNativeController()
        await native.setTurnInFlight(true)
        fixture.session.claudeController = native
        fixture.session.providerSessionID = "origin-provider-session"
        let runID = UUID()
        fixture.session.installRunID(runID)
        let ownership = fixture.session.beginRunAttempt(source: "self-relocation-test")
        fixture.session.runState = .running
        return LiveSelfTurn(runID: runID, ownership: ownership, native: native)
    }

    private func endTurn(_ fixture: DurableFixture, _ turn: LiveSelfTurn, state: AgentSessionRunState) async {
        await turn.native.setTurnInFlight(false)
        fixture.session.runState = state
        _ = fixture.session.endRunAttempt(ifCurrent: turn.ownership, source: "self-relocation-test")
    }

    private func revision(
        _ turn: LiveSelfTurn,
        state: AgentSessionRunState,
        successor: AgentRunEpochTransitionKind? = nil
    ) -> AgentRunTerminalCommitRevision {
        AgentRunTerminalCommitRevision(
            commitID: UUID(), ownership: turn.ownership, terminalState: state,
            failureReason: nil, expectedRunID: turn.runID, sourceItemsRevision: 0,
            assistantDeltaFlushGeneration: 0, providerDrainGeneration: 0,
            mcpPublicationEnvelope: nil, successorKind: successor, providerSuccessorID: nil
        )
    }

    private func makeNextBinding(_ fixture: DurableFixture) throws -> AgentSessionWorktreeBinding {
        let old = fixture.session.worktreeBindings[0]
        let target = fixture.git.sandbox.appendingPathComponent("physical-next")
        if !FileManager.default.fileExists(atPath: target.path) {
            try fixture.git.runGit(["worktree", "add", "--detach", target.path, "HEAD"], at: URL(fileURLWithPath: old.logicalRootPath))
        }
        let identity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: target))
        return AgentSessionWorktreeBinding(
            id: old.id, repositoryID: identity.repository.repositoryID,
            repoKey: identity.repository.repoKey, logicalRootPath: old.logicalRootPath,
            logicalRootName: old.logicalRootName, worktreeID: identity.worktreeID,
            worktreeRootPath: target.path, commonGitDir: identity.repository.commonGitDir,
            isMainWorktree: false, source: "test"
        )
    }

    func testTransitionRejectsReacquiredWriterAfterPreparationWithoutTouchingSuccessorGate() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        let previous = fixture.session.worktreeBindings
        var published = false
        do {
            _ = try await command.writer.scope.worktrees.transition(
                [], command: command, intent: .externalManagement,
                beforeCommit: {
                    fixture.viewModel.test_removeSession(tabID: fixture.session.tabID)
                    fixture.viewModel.test_installLiveSession(fixture.session)
                    fixture.session.isChangingExecutionLocation = true
                }, afterCommit: { published = true }
            )
            XCTFail("An old command cannot follow a reacquired claim")
        } catch {
            XCTAssertFalse(error is AgentSessionWorktreeRuntime.PartialTransition)
        }
        XCTAssertFalse(command.isCurrent)
        XCTAssertFalse(fixture.session.worktreeBindingTransitionInProgress, "The old transition must release its own gate despite losing its claim")
        XCTAssertFalse(published)
        XCTAssertEqual(fixture.session.worktreeBindings, previous)
        XCTAssertTrue(fixture.session.isChangingExecutionLocation, "Old cleanup must not clear the successor gate")
        XCTAssertEqual(command.writer.scope.worktrees.pendingTransitions, 0)
    }

    func testProviderRetirementCannotClearReboundWriterMetadataOrSaveItsRecovery() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        let replacementID = UUID()
        let replacementController = MonitorFakeNativeController()
        let session = fixture.session
        let workspaceID = command.identity.workspaceID
        let oldController = WorktreeTeardownNativeController {
            await MainActor.run {
                session.installPersistentSessionBinding(.init(
                    tabID: session.tabID, sessionID: replacementID, workspaceID: workspaceID
                ))
                session.recordRestorationAuthoritative(.persistedPayloadApplied)
                session.providerSessionID = "successor-provider"
                session.claudeController = replacementController
                session.isChangingExecutionLocation = true
            }
        }
        fixture.session.claudeController = oldController
        var saves = 0
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
            saves += 1
            return fixture.git.sandbox.appendingPathComponent("session.json")
        }
        do {
            _ = try await command.writer.scope.worktrees.transition([], command: command, intent: .externalManagement)
            XCTFail("A retired origin must return a partial receipt after rebinding")
        } catch let receipt as AgentSessionWorktreeRuntime.PartialTransition {
            XCTAssertEqual(receipt.writer, command.identity)
            XCTAssertTrue(receipt.providerRetired)
            XCTAssertFalse(receipt.bindingsPublished)
            XCTAssertFalse(receipt.recoverySaved)
        }
        XCTAssertEqual(fixture.session.activeAgentSessionID, replacementID)
        XCTAssertEqual(fixture.session.providerSessionID, "successor-provider")
        XCTAssertTrue(fixture.session.claudeController === replacementController)
        XCTAssertTrue(fixture.session.isChangingExecutionLocation)
        XCTAssertEqual(saves, 0)
        XCTAssertFalse(session.worktreeBindingTransitionInProgress)
        let shutdowns = await replacementController.shutdownCount
        XCTAssertEqual(shutdowns, 0)
    }

    func testPublishedBindingReportsOriginWithoutSavingAReboundSuccessor() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        let desired = [Self.copyBinding(fixture.session.worktreeBindings[0], visualLabel: "Committed label")]
        var saves = 0
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
            saves += 1
            return fixture.git.sandbox.appendingPathComponent("session.json")
        }
        do {
            _ = try await command.writer.scope.worktrees.transition(
                desired, command: command, intent: .externalManagement,
                afterCommit: {
                    fixture.session.saveDebounceTask?.cancel()
                    fixture.session.installPersistentSessionBinding(.init(
                        tabID: fixture.session.tabID, sessionID: UUID(), workspaceID: command.identity.workspaceID
                    ))
                    fixture.session.recordRestorationAuthoritative(.persistedPayloadApplied)
                }
            )
            XCTFail("Committed effects cannot acknowledge a successor's save")
        } catch let receipt as AgentSessionWorktreeRuntime.PartialTransition {
            XCTAssertEqual(receipt.writer, command.identity)
            XCTAssertTrue(receipt.bindingsPublished)
            XCTAssertFalse(receipt.recoverySaved)
        }
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(fixture.session.worktreeBindings, desired)
    }

    func testRuntimeUnbindAcknowledgesRealPersistenceWithoutTestFlush() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        let result = try await command.writer.scope.worktrees.transition([], command: command, intent: .externalManagement)
        XCTAssertEqual(result, [])
        let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let saved = try await AgentSessionDataService.shared.loadAgentSession(id: fixture.sessionID, for: workspace)
        XCTAssertEqual(saved?.id, fixture.sessionID)
        XCTAssertEqual(saved?.worktreeBindings, [])
        XCTAssertFalse(fixture.session.isDirty)
        XCTAssertFalse(fixture.session.worktreeBindingTransitionInProgress)
        XCTAssertFalse(fixture.session.isChangingExecutionLocation)
    }

    func testConflictingClaimStillReleasesTheOriginatingTransitionGates() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        let competitor = AgentSessionRuntimeStore.shared.makeScope()
        let replica = competitor.makeSession(tabID: fixture.session.tabID)
        replica.installPersistentSessionBinding(command.writer.binding)
        do {
            _ = try await command.writer.scope.worktrees.transition(
                [], command: command, intent: .externalManagement,
                beforeCommit: { competitor.replaceSessions([replica.tabID: replica]) }
            )
            XCTFail("A competing claim must refuse publication")
        } catch {
            XCTAssertFalse(error is AgentSessionWorktreeRuntime.PartialTransition)
        }
        XCTAssertFalse(command.writer.ownsPersistentClaim)
        XCTAssertFalse(fixture.session.worktreeBindingTransitionInProgress)
        XCTAssertFalse(fixture.session.isChangingExecutionLocation)
        competitor.replaceSessions([:])
        XCTAssertTrue(command.isCurrent)
    }

    func testRetirementJoinsTransitionCleanupBeforeReleasingItsWriter() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        fixture.session.isDirty = false
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        let scope = command.writer.scope
        var release: CheckedContinuation<Void, Never>?
        let operation = Task { @MainActor in
            try await scope.worktrees.transition([], command: command, intent: .externalManagement, beforeCommit: {
                await withCheckedContinuation { release = $0 }
            })
        }
        try await AsyncTestWait.waitUntil("transition preparation held") { release != nil }
        scope.beginRetirement()
        XCTAssertFalse(scope.releaseWriterClaimsAfterDrain())
        var joined = false
        let drain = Task { @MainActor in
            await scope.worktrees.waitForTransitions()
            joined = true
        }
        await Task.yield()
        XCTAssertFalse(joined)
        release?.resume()
        _ = try? await operation.value
        await drain.value
        XCTAssertTrue(joined)
        XCTAssertFalse(fixture.session.worktreeBindingTransitionInProgress)
        XCTAssertFalse(fixture.session.isChangingExecutionLocation)
        XCTAssertTrue(scope.releaseWriterClaimsAfterDrain(), "The drain owner, not transition completion, releases claims")
    }

    func testInitialTransitionUsesExactCreationCapabilityWithoutRestorationBypass() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let source = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        let scope = source.writer.scope
        let fresh = scope.makeSession(tabID: UUID())
        let claim = AgentSessionCreationClaim(workspaceID: source.identity.workspaceID)
        fresh.installPersistentSessionBinding(.init(tabID: fresh.tabID, sessionID: claim.sessionID, workspaceID: claim.workspaceID))
        let creation = try XCTUnwrap(fresh.acceptFreshCreation(claim, workspaceID: claim.workspaceID))
        scope.replaceSessions([fixture.session.tabID: fixture.session, fresh.tabID: fresh])
        XCTAssertThrowsError(try fixture.viewModel.runtimeCommand(sessionID: claim.sessionID))
        let installed = try await fixture.viewModel.transitionWorktreeBindings(
            fixture.session.worktreeBindings, forSessionID: claim.sessionID, intent: .initialSend, creationHandle: creation
        )
        XCTAssertEqual(installed, fixture.session.worktreeBindings)
        XCTAssertTrue(fresh.creationHandleIsCurrent(creation), "The transition does not claim configured creation durability")
        XCTAssertFalse(fresh.worktreeBindingTransitionInProgress)
    }

    func testMergePreviewAndApplyAcknowledgeActualOriginSaves() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let source = URL(fileURLWithPath: fixture.session.worktreeBindings[0].worktreeRootPath)
        try fixture.git.write("merge payload\n", to: "merged.txt", at: source)
        try fixture.git.stage("merged.txt", at: source)
        try fixture.git.commit("Source payload", at: source)
        let dataService = AgentSessionDataService()
        await dataService.test_setWorkspaceRootOverride(fixture.git.sandbox.appendingPathComponent("sessions"))
        var savedStates: [AgentSessionWorktreeMergeOperation.Status] = []
        var savedURL: URL?
        fixture.viewModel.test_setAgentSessionSaver { payload, workspace, count in
            let url = try await dataService.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
            savedURL = url
            savedStates += payload.worktreeMergeOperations.map(\.status)
            return url
        }
        let preview = try await fixture.viewModel.previewWorktreeMerge(sessionID: fixture.sessionID, publishArtifacts: false)
        XCTAssertEqual(savedStates.last, .previewed)
        XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(savedURL).path))
        let result = try await fixture.viewModel.applyConfirmedWorktreeMerge(sessionID: fixture.sessionID, operationID: preview.operationID)
        XCTAssertEqual(result.status, .completed)
        XCTAssertTrue(savedStates.contains(.applying), "Intent must be acknowledged before Git")
        XCTAssertEqual(savedStates.last, .completed)
        XCTAssertNotNil(result.mergeCommit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: fixture.session.worktreeBindings[0].logicalRootPath).appendingPathComponent("merged.txt").path))
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        XCTAssertEqual(command.writer.scope.worktrees.pendingTransitions, 0)
        XCTAssertTrue(command.writer.scope.worktrees.mergeOwners.isEmpty)
    }

    func testMergeIntentSaveFailurePreventsGitAndRetainsPreparationReceipt() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let source = URL(fileURLWithPath: fixture.session.worktreeBindings[0].worktreeRootPath)
        let target = URL(fileURLWithPath: fixture.session.worktreeBindings[0].logicalRootPath)
        try fixture.git.write("merge payload\n", to: "merged.txt", at: source)
        try fixture.git.stage("merged.txt", at: source)
        try fixture.git.commit("Source payload", at: source)
        let dataService = AgentSessionDataService()
        await dataService.test_setWorkspaceRootOverride(fixture.git.sandbox.appendingPathComponent("sessions"))
        fixture.viewModel.test_setAgentSessionSaver { payload, workspace, count in
            try await dataService.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
        }
        let preview = try await fixture.viewModel.previewWorktreeMerge(sessionID: fixture.sessionID, publishArtifacts: false)
        let head = try fixture.git.runGit(["rev-parse", "HEAD"], at: target)
        struct SaveFailure: Error {}
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in throw SaveFailure() }
        do {
            _ = try await fixture.viewModel.applyConfirmedWorktreeMerge(sessionID: fixture.sessionID, operationID: preview.operationID)
            XCTFail("Required intent persistence must precede physical Git")
        } catch let partial as AgentSessionWorktreeRuntime.PartialMerge {
            XCTAssertTrue(partial.operationRecorded)
            XCTAssertFalse(partial.requiredSaveAcknowledged)
            XCTAssertFalse(partial.physicalAttemptAdmitted)
            XCTAssertNil(partial.applyResult)
        }
        XCTAssertEqual(try fixture.git.runGit(["rev-parse", "HEAD"], at: target), head)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("merged.txt").path))
        XCTAssertEqual(fixture.session.worktreeMergeOperations.first?.status, .previewed)
    }

    func testMergePreviewAuthorizationCannotFollowReacquiredWriter() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        let runtime = command.writer.scope.worktrees
        let admission = try runtime.admit(command)
        var changed = false
        do {
            _ = try await runtime.previewMerge(admission: admission, publishArtifacts: true, revalidateAuthority: {
                guard !changed else { return }
                changed = true
                fixture.viewModel.test_removeSession(tabID: fixture.session.tabID)
                fixture.viewModel.test_installLiveSession(fixture.session)
            })
            XCTFail("Discovery cannot grant a successor writer the old command")
        } catch {
            XCTAssertFalse(error is AgentSessionWorktreeRuntime.PartialMerge)
        }
        XCTAssertTrue(changed)
        XCTAssertFalse(command.isCurrent)
        XCTAssertTrue(fixture.session.worktreeMergeOperations.isEmpty)
        XCTAssertEqual(runtime.pendingTransitions, 0)
        XCTAssertTrue(runtime.mergeOwners.isEmpty)
    }

    func testMergePostGitSaveFailureRetainsCommitAndDurableIntent() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let source = URL(fileURLWithPath: fixture.session.worktreeBindings[0].worktreeRootPath)
        try fixture.git.write("merge payload\n", to: "merged.txt", at: source)
        try fixture.git.stage("merged.txt", at: source)
        try fixture.git.commit("Source payload", at: source)
        let dataService = AgentSessionDataService()
        await dataService.test_setWorkspaceRootOverride(fixture.git.sandbox.appendingPathComponent("sessions"))
        struct SaveFailure: Error {}
        var lastSavedURL: URL?
        fixture.viewModel.test_setAgentSessionSaver { payload, workspace, count in
            if payload.worktreeMergeOperations.contains(where: { $0.status == .completed }) { throw SaveFailure() }
            let url = try await dataService.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
            lastSavedURL = url
            return url
        }
        let preview = try await fixture.viewModel.previewWorktreeMerge(sessionID: fixture.sessionID, publishArtifacts: false)
        do {
            _ = try await fixture.viewModel.applyConfirmedWorktreeMerge(sessionID: fixture.sessionID, operationID: preview.operationID)
            XCTFail("Completion cannot acknowledge a failed required save")
        } catch let partial as AgentSessionWorktreeRuntime.PartialMerge {
            XCTAssertTrue(partial.physicalAttemptAdmitted)
            XCTAssertTrue(partial.operationRecorded)
            XCTAssertFalse(partial.requiredSaveAcknowledged)
            XCTAssertEqual(partial.applyResult?.status, .completed)
            XCTAssertNotNil(partial.applyResult?.mergeCommit)
        }
        // The restoration loader reconciles Git state and may rewrite the operation. Inspect the
        // actual acknowledged bytes here, before invoking that separate recovery owner.
        let bytes = try Data(contentsOf: XCTUnwrap(lastSavedURL))
        let durable = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let operations = try XCTUnwrap(durable["worktreeMergeOperations"] as? [[String: Any]])
        XCTAssertEqual(operations.first?["status"] as? String, "applying")
        XCTAssertEqual(fixture.session.worktreeMergeOperations.first?.status, .completed)
    }

    func testMergeReviewDoesNotHoldDrainAndBindingDriftPreventsApply() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let dataService = AgentSessionDataService()
        await dataService.test_setWorkspaceRootOverride(fixture.git.sandbox.appendingPathComponent("sessions"))
        fixture.viewModel.test_setAgentSessionSaver { payload, workspace, count in
            try await dataService.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
        }
        let preview = try await fixture.viewModel.previewWorktreeMerge(sessionID: fixture.sessionID, publishArtifacts: false)
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        let runtime = command.writer.scope.worktrees
        let admission = try runtime.admit(command)
        let applying = Task { @MainActor in
            try await runtime.applyMerge(admission: admission, operationID: preview.operationID, review: true, timeoutSeconds: 5)
        }
        defer { applying.cancel() }
        try await AsyncTestWait.waitUntil("merge review shown") { fixture.session.pendingWorktreeMergeReview != nil }
        XCTAssertEqual(runtime.pendingTransitions, 0, "Human review is not a drain dependency")
        await runtime.waitForTransitions()
        do {
            _ = try await runtime.transition([], admission: admission, intent: .externalManagement)
            XCTFail("A concurrent binding transition must not race the pending review")
        } catch {}
        fixture.session.worktreeBindings = []
        let review = try XCTUnwrap(fixture.session.pendingWorktreeMergeReview)
        XCTAssertTrue(try XCTUnwrap(command.writer.scope.installedInteractions).submitWorktreeMergeReviewDecision(
            command: command, reviewID: review.id, decision: .accept
        ))
        do {
            _ = try await applying.value
            XCTFail("The accepted review cannot follow changed bindings")
        } catch {}
        XCTAssertEqual(fixture.session.worktreeMergeOperations.first?.status, .cancelled)
        XCTAssertTrue(runtime.mergeOwners.isEmpty)
    }

    func testMergeContinueRefusalPreservesConflictAndCanContinueOrAbort() async throws {
        for abort in [false, true] {
            let fixture = try await durableFixture()
            defer { fixture.git.cleanup() }
            let source = URL(fileURLWithPath: fixture.session.worktreeBindings[0].worktreeRootPath)
            let target = URL(fileURLWithPath: fixture.session.worktreeBindings[0].logicalRootPath)
            try fixture.git.write("source\n", to: "README.md", at: source)
            try fixture.git.stage("README.md", at: source)
            try fixture.git.commit("Source conflict", at: source)
            try fixture.git.write("target\n", to: "README.md", at: target)
            try fixture.git.stage("README.md", at: target)
            try fixture.git.commit("Target conflict", at: target)
            let dataService = AgentSessionDataService()
            await dataService.test_setWorkspaceRootOverride(fixture.git.sandbox.appendingPathComponent("sessions"))
            fixture.viewModel.test_setAgentSessionSaver { payload, workspace, count in
                try await dataService.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
            }
            let preview = try await fixture.viewModel.previewWorktreeMerge(sessionID: fixture.sessionID, publishArtifacts: false)
            let applied = try await fixture.viewModel.applyConfirmedWorktreeMerge(sessionID: fixture.sessionID, operationID: preview.operationID)
            XCTAssertEqual(applied.status, .conflicted)
            do {
                _ = try await fixture.viewModel.continueWorktreeMerge(sessionID: fixture.sessionID, operationID: preview.operationID)
                XCTFail("Unresolved conflicts must refuse commit")
            } catch let partial as AgentSessionWorktreeRuntime.PartialMerge {
                XCTAssertFalse(partial.physicalAttemptAdmitted, "Git checks conflicts before the physical callback")
                XCTAssertTrue(partial.requiredSaveAcknowledged)
            }
            XCTAssertEqual(fixture.session.worktreeMergeOperations.first?.status, .conflicted)
            if abort {
                let result = try await fixture.viewModel.abortWorktreeMerge(sessionID: fixture.sessionID, operationID: preview.operationID)
                XCTAssertTrue(result.aborted)
                XCTAssertEqual(fixture.session.worktreeMergeOperations.first?.status, .aborted)
            } else {
                try fixture.git.write("resolved\n", to: "README.md", at: target)
                try fixture.git.stage("README.md", at: target)
                let result = try await fixture.viewModel.continueWorktreeMerge(sessionID: fixture.sessionID, operationID: preview.operationID)
                XCTAssertEqual(result.status, .completed)
                XCTAssertEqual(fixture.session.worktreeMergeOperations.first?.status, .completed)
            }
        }
    }

    func testCancelledUnlimitedMergeReviewSettlesItsOwnerAndReleasesExclusion() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let dataService = AgentSessionDataService()
        await dataService.test_setWorkspaceRootOverride(fixture.git.sandbox.appendingPathComponent("sessions"))
        fixture.viewModel.test_setAgentSessionSaver { payload, workspace, count in
            try await dataService.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
        }
        let preview = try await fixture.viewModel.previewWorktreeMerge(sessionID: fixture.sessionID, publishArtifacts: false)
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        let runtime = command.writer.scope.worktrees
        let admission = try runtime.admit(command)
        let applying = Task { @MainActor in
            try await runtime.applyMerge(admission: admission, operationID: preview.operationID, review: true, timeoutSeconds: 0)
        }
        try await AsyncTestWait.waitUntil("unlimited review shown") { fixture.session.pendingWorktreeMergeReview != nil }
        XCTAssertEqual(fixture.session.runState, .waitingForApproval)
        applying.cancel()
        try await AsyncTestWait.waitUntil("cancelled review settled") { runtime.mergeOwners.isEmpty }
        do { _ = try await applying.value
            XCTFail("Cancelled review must not apply")
        } catch {}
        XCTAssertNil(fixture.session.pendingWorktreeMergeReview)
        XCTAssertEqual(fixture.session.worktreeMergeOperations.first?.status, .cancelled)
        XCTAssertEqual(fixture.session.runState, .idle, "A cancelled standalone review must not invent a provider run")
        XCTAssertEqual(runtime.pendingTransitions, 0)
    }

    func testAcceptedReviewFailureBeforeIntentRestoresActionablePreview() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let dataService = AgentSessionDataService()
        await dataService.test_setWorkspaceRootOverride(fixture.git.sandbox.appendingPathComponent("sessions"))
        fixture.viewModel.test_setAgentSessionSaver { payload, workspace, count in
            try await dataService.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
        }
        let preview = try await fixture.viewModel.previewWorktreeMerge(sessionID: fixture.sessionID, publishArtifacts: false)
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        let runtime = command.writer.scope.worktrees
        let admission = try runtime.admit(command)
        var afterAcceptanceChecks = 0
        let applying = Task { @MainActor in
            try await runtime.applyMerge(admission: admission, operationID: preview.operationID, review: true, revalidateAuthority: {
                if fixture.session.pendingWorktreeMergeReview == nil,
                   fixture.session.worktreeMergeOperations.first?.status == .awaitingApproval
                {
                    afterAcceptanceChecks += 1
                    // First check resumes the accepted caller. The second is its final intent fence.
                    if afterAcceptanceChecks == 2 { throw SessionAdminHostError.authorityEnded }
                }
            })
        }
        try await AsyncTestWait.waitUntil("merge review shown") { fixture.session.pendingWorktreeMergeReview != nil }
        let review = try XCTUnwrap(fixture.session.pendingWorktreeMergeReview)
        XCTAssertTrue(try XCTUnwrap(command.writer.scope.installedInteractions).submitWorktreeMergeReviewDecision(command: command, reviewID: review.id, decision: .accept))
        do { _ = try await applying.value
            XCTFail("Revoked final intent fence must refuse Git")
        } catch let partial as AgentSessionWorktreeRuntime.PartialMerge {
            XCTAssertFalse(partial.physicalAttemptAdmitted)
            XCTAssertTrue(partial.requiredSaveAcknowledged)
        }
        XCTAssertEqual(afterAcceptanceChecks, 2)
        XCTAssertEqual(fixture.session.worktreeMergeOperations.first?.status, .previewed)
        XCTAssertNil(fixture.session.pendingWorktreeMergeReview)
    }

    func testMergeCompletedSaveCannotWriteThroughReacquiredSessionObject() async throws {
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        let source = URL(fileURLWithPath: fixture.session.worktreeBindings[0].worktreeRootPath)
        try fixture.git.write("merge payload\n", to: "merged.txt", at: source)
        try fixture.git.stage("merged.txt", at: source)
        try fixture.git.commit("Source payload", at: source)
        let dataService = AgentSessionDataService()
        await dataService.test_setWorkspaceRootOverride(fixture.git.sandbox.appendingPathComponent("sessions"))
        var replacementInstalled = false
        fixture.viewModel.test_setAgentSessionSaver { payload, workspace, count in
            let url = try await dataService.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
            if !replacementInstalled, payload.worktreeMergeOperations.contains(where: { $0.status == .completed }) {
                replacementInstalled = true
                fixture.viewModel.test_removeSession(tabID: fixture.session.tabID)
                fixture.viewModel.test_installLiveSession(fixture.session)
                fixture.session.worktreeMergeOperations = []
            }
            return url
        }
        let preview = try await fixture.viewModel.previewWorktreeMerge(sessionID: fixture.sessionID, publishArtifacts: false)
        let origin = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        do {
            _ = try await fixture.viewModel.applyConfirmedWorktreeMerge(sessionID: fixture.sessionID, operationID: preview.operationID)
            XCTFail("A successor cannot acknowledge the old command")
        } catch let partial as AgentSessionWorktreeRuntime.PartialMerge {
            XCTAssertEqual(partial.writer, origin.identity)
            XCTAssertEqual(partial.applyResult?.status, .completed)
            XCTAssertNotNil(partial.applyResult?.mergeCommit)
        }
        XCTAssertTrue(replacementInstalled)
        XCTAssertFalse(origin.isCurrent)
        XCTAssertTrue(fixture.session.worktreeMergeOperations.isEmpty, "Old failure cleanup must not recreate a successor's operation")
    }

    private struct DurableFixture {
        let git: ReviewGitRepositoryFixture
        let prompt: PromptViewModel
        let manager: WorkspaceManagerViewModel
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
    }

    private func durableFixture(windowID: Int = -991) async throws -> DurableFixture {
        let git = try ReviewGitRepositoryFixture(name: "DurableWorktreeSwitch")
        let logical = try git.makeRepository(named: "logical", files: ["README.md": "fixture\n"])
        let physical = git.sandbox.appendingPathComponent("physical")
        try git.runGit(["worktree", "add", "--detach", physical.path, "HEAD"], at: logical)
        let identity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: physical))
        let files = WorkspaceFilesViewModel()
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager), keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: files, apiSettingsViewModel: apiSettings,
            windowID: -991, settingsManager: WindowSettingsManager(windowID: -991)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: files, promptViewModel: prompt, performInitialWorkspaceActivation: false
        )
        let (viewModel, session, sessionID) = fixture(workspacePath: logical.path, windowID: windowID, scoped: false)
        let workspace = WorkspaceModel(
            name: "Worktree switch", repoPaths: [logical.path], ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: session.tabID, activeAgentSessionID: sessionID)], activeComposeTabID: session.tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        viewModel.workspaceManager = manager
        viewModel.promptManager = prompt
        // The durable fixture owns an exact workspace carrier, not an unscoped test-only binding.
        // Exercise the production qualification CAS before granting restored-payload readiness.
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(
            sessionID: sessionID, on: session, compareAndSetInWorkspaceID: workspace.id
        ))
        XCTAssertEqual(session.persistentSessionBindingIdentity?.workspaceID, workspace.id)
        session.hasLoadedPersistedState = true
        XCTAssertNotNil(session.restorationAdmissionFailureMessage)
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        _ = try XCTUnwrap(
            session.permitsBoundOperationAndSave ? session.currentRestorationBindingToken : nil,
            "Durable worktree transitions require an already-restored session."
        )
        session.worktreeBindings = [.init(
            id: "primary", repositoryID: identity.repository.repositoryID,
            repoKey: identity.repository.repoKey, logicalRootPath: logical.path,
            logicalRootName: "Project", worktreeID: identity.worktreeID,
            worktreeRootPath: physical.path, commonGitDir: identity.repository.commonGitDir,
            isMainWorktree: false, source: "test"
        )]
        _ = try await prompt.workspaceFileContextStore.loadRoot(path: logical.path)
        let materializer = WorkspaceRootBindingProjectionMaterializer(store: prompt.workspaceFileContextStore)
        let preparation = try await materializer.prepare(sessionID: sessionID, bindings: session.worktreeBindings)
        _ = try await materializer.commit(preparation)
        return DurableFixture(git: git, prompt: prompt, manager: manager, viewModel: viewModel, session: session, sessionID: sessionID)
    }

    private static func copyBinding(
        _ binding: AgentSessionWorktreeBinding,
        id: String? = nil,
        logicalRootPath: String? = nil,
        visualLabel: String? = nil,
        head: String? = nil
    ) -> AgentSessionWorktreeBinding {
        .init(
            id: id ?? binding.id, repositoryID: binding.repositoryID,
            repoKey: binding.repoKey, logicalRootPath: logicalRootPath ?? binding.logicalRootPath,
            logicalRootName: binding.logicalRootName, worktreeID: binding.worktreeID,
            worktreeRootPath: binding.worktreeRootPath, commonGitDir: binding.commonGitDir,
            isMainWorktree: binding.isMainWorktree, head: head ?? binding.head, visualLabel: visualLabel ?? binding.visualLabel,
            boundAt: binding.boundAt, source: binding.source
        )
    }

    private func assertRemovalRejected(
        _ viewModel: AgentModeViewModel,
        session: AgentModeViewModel.TabSession,
        sessionID: UUID
    ) async {
        let original = session.worktreeBindings
        do {
            _ = try await viewModel.transitionWorktreeBindings([], forSessionID: sessionID, intent: .externalManagement)
            XCTFail("A reserved or active provider boundary must reject a destination change")
        } catch {
            XCTAssertEqual(session.worktreeBindings, original)
            XCTAssertFalse(session.worktreeBindingTransitionInProgress)
        }
    }

    private func fixture(workspacePath: String = "/tmp/logical-worktree-admission", windowID: Int = -991, scoped: Bool = true) -> (AgentModeViewModel, AgentModeViewModel.TabSession, UUID) {
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: workspacePath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Admission tests must not start a provider")
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let sessionID = UUID()
        viewModel.test_installLiveSession(session)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        if scoped {
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: UUID()))
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            guard case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: sessionID) else {
                preconditionFailure("Admission fixture must own an exact writer")
            }
            // These unit cases stop before materialization. Only resources are substituted;
            // canonical claim/restoration admission and production provider probes remain real.
            writer.scope.worktrees.captureResources = { _ in
                .init(store: nil, fallbackWorkspacePath: workspacePath, declaredRepoPaths: [], isCurrent: { true })
            }
        }
        session.worktreeBindings = [.init(
            id: "primary", repositoryID: "repo", repoKey: "repo",
            logicalRootPath: "/tmp/logical-worktree-admission", logicalRootName: "Project",
            worktreeID: "worktree", worktreeRootPath: "/tmp/physical-worktree-admission", source: "test"
        )]
        return (viewModel, session, sessionID)
    }
}

private final class WorktreeProbeCodexController: CodexSessionControllerPassiveStubDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var deadlines: [TimeInterval?] = []
    private let failSnapshot: Bool
    private let runtimeStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus

    init(failSnapshot: Bool = false, runtimeStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus = .idle) {
        self.failSnapshot = failSnapshot
        self.runtimeStatus = runtimeStatus
    }

    var requestedTimeouts: [TimeInterval?] {
        lock.withLock { deadlines }
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { $0.finish() }
    }

    func readThreadSnapshot(includeTurns _: Bool, timeout: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        lock.withLock { deadlines.append(timeout) }
        if failSnapshot { throw CodexAppServerClient.ClientError.invalidResponse }
        return .init(conversationID: "test", rolloutPath: nil, model: nil, reasoningEffort: nil, runtimeStatus: runtimeStatus, currentTurnID: nil, activeTurnIDs: [], latestTurnStatus: nil)
    }

    func shutdown() async {}
}

private actor WorktreeTestManageGrant {
    private var live = true

    func revoke() {
        live = false
    }

    func validate() throws {
        guard live else { throw MCPError.invalidParams("Manage grant revoked") }
    }
}

private actor WorktreeTeardownNativeController: NativeAgentRuntimeControlling {
    private let delegate = MonitorFakeNativeController()
    private let onShutdown: @Sendable () async -> Void
    init(onShutdown: @escaping @Sendable () async -> Void) {
        self.onShutdown = onShutdown
    }

    var hasActiveSession: Bool {
        true
    }

    var hasTurnInFlight: Bool {
        false
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        get async { await delegate.events }
    }

    func ensureEventsStreamReady() async {}
    func resetEventsStreamForNewRun() async {}
    func startOrResume(existingSessionID: String?, model: String?, effortLevel: NativeAgentRuntimeEffortLevel?, systemPromptOverride: String?) async throws -> NativeAgentRuntimeSessionRef {
        try await delegate.startOrResume(existingSessionID: existingSessionID, model: model, effortLevel: effortLevel, systemPromptOverride: systemPromptOverride)
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        await delegate.currentSessionRef()
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {
        try await delegate.applyModelAndEffort(model: model, effortLevel: effortLevel)
    }

    func applyModelAndEffortWithProof(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws -> NativeAgentRuntimeConfigurationApplication {
        try await delegate.applyModelAndEffortWithProof(model: model, effortLevel: effortLevel)
    }

    func sendUserMessage(_ text: String, configuration: NativeAgentRuntimeConfigurationProof) async throws -> UUID {
        try await delegate.sendUserMessage(text, configuration: configuration)
    }

    func sendUserMessage(_ text: String) async throws -> UUID {
        try await delegate.sendUserMessage(text)
    }

    func interruptTurn(reason _: String) async -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() async {
        await delegate.shutdown()
        await onShutdown()
    }

    func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) async {}
}
