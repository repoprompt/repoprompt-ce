import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptVCS
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
        let fixture = try await durableFixture()
        defer { fixture.git.cleanup() }
        struct SaveFailure: Error {}
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in throw SaveFailure() }
        var committed = false
        do {
            _ = try await fixture.viewModel.transitionWorktreeBindings(
                [], forSessionID: fixture.sessionID, intent: .externalManagement,
                beforeCommit: { committed = true }
            )
            XCTFail("A failed required save cannot produce an applied reply")
        } catch {
            XCTAssertTrue(committed, "The protected wrapper must settle this as indeterminate after commit")
            XCTAssertEqual(fixture.session.worktreeBindings, [])
            XCTAssertFalse(fixture.session.isChangingExecutionLocation)
        }
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

    private struct DurableFixture {
        let git: ReviewGitRepositoryFixture
        let prompt: PromptViewModel
        let manager: WorkspaceManagerViewModel
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
    }

    private func durableFixture() async throws -> DurableFixture {
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
        let (viewModel, session, sessionID) = fixture(workspacePath: logical.path)
        let workspace = WorkspaceModel(
            name: "Worktree switch", repoPaths: [logical.path], ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: session.tabID)], activeComposeTabID: session.tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        viewModel.workspaceManager = manager
        viewModel.promptManager = prompt
        session.hasLoadedPersistedState = true
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
        visualLabel: String? = nil
    ) -> AgentSessionWorktreeBinding {
        .init(
            id: id ?? binding.id, repositoryID: binding.repositoryID,
            repoKey: binding.repoKey, logicalRootPath: logicalRootPath ?? binding.logicalRootPath,
            logicalRootName: binding.logicalRootName, worktreeID: binding.worktreeID,
            worktreeRootPath: binding.worktreeRootPath, commonGitDir: binding.commonGitDir,
            isMainWorktree: binding.isMainWorktree, visualLabel: visualLabel ?? binding.visualLabel,
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

    private func fixture(workspacePath: String = "/tmp/logical-worktree-admission") -> (AgentModeViewModel, AgentModeViewModel.TabSession, UUID) {
        let viewModel = AgentModeViewModel(
            testWindowID: -991,
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
        session.worktreeBindings = [.init(
            id: "primary", repositoryID: "repo", repoKey: "repo",
            logicalRootPath: "/tmp/logical-worktree-admission", logicalRootName: "Project",
            worktreeID: "worktree", worktreeRootPath: "/tmp/physical-worktree-admission", source: "test"
        )]
        return (viewModel, session, sessionID)
    }
}
