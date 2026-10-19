import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
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
        let relocation = AgentSelfWorktreeRelocation(
            id: UUID(), originRunID: UUID(), originRunAttemptID: UUID(),
            previousBindings: [], desiredBindings: [],
            stopFence: AgentRunStartStopFence(session: AgentModeViewModel.TabSession(tabID: UUID()))
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
