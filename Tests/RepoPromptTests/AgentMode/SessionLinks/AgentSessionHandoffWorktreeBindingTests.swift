import Foundation
import RepoPromptSettingsCore
import RepoPromptVCS
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// The message-footer Handoff must continue in the source conversation's worktree: the fresh
/// destination receives the source's execution mappings, with its own projection ownership, before
/// its first save or activation. A stale or unavailable source fails visibly instead of silently
/// falling back to the primary checkout. Regression coverage for repoprompt-ce#1210.
@MainActor
final class AgentSessionHandoffWorktreeBindingTests: XCTestCase {
    func testBoundSourceHandoffInstallsSourceMappingsBeforeFirstSaveAndActivation() async throws {
        try await withFixture(bindSource: true) { fixture in
            let sourceBindings = fixture.sourceSession.worktreeBindings
            XCTAssertFalse(sourceBindings.isEmpty)
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            var destinationSaves: [[AgentSessionWorktreeBinding]] = []

            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                guard session.id != fixture.sourceSessionID else {
                    return fixture.git.sandbox.appendingPathComponent("source-session.json")
                }
                XCTAssertEqual(
                    fixture.window.promptManager.activeComposeTabID,
                    fixture.sourceTabID,
                    "the destination must not be activated before its first save"
                )
                destinationSaves.append(session.worktreeBindings)
                return fixture.git.sandbox.appendingPathComponent("handoff-session.json")
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in .empty }

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sourceSession.selectedAgent,
                destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
            )

            let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            let destinationSessionID = try XCTUnwrap(destination.activeAgentSessionID)
            XCTAssertNotEqual(destinationSessionID, fixture.sourceSessionID)
            XCTAssertEqual(
                destinationSaves.first,
                sourceBindings,
                "the first durable save must already carry the source mappings"
            )
            XCTAssertEqual(destination.worktreeBindings, sourceBindings)
            XCTAssertEqual(
                fixture.viewModel.worktreeBindingState(forAgentSessionID: destinationSessionID),
                .hydrated(sourceBindings)
            )
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)

            // Fresh conversation identity: no provider, spawn, merge, or overseer provenance aliasing.
            XCTAssertNil(destination.providerSessionID)
            XCTAssertNil(destination.parentSessionID)
            XCTAssertNil(destination.createdByOverseerSessionID)
            XCTAssertTrue(destination.worktreeMergeOperations.isEmpty)
            XCTAssertNotNil(destination.pendingHandoff.payload)
            XCTAssertTrue(destination.pendingHandoff.defersProviderLockUntilSend)
            XCTAssertFalse(destination.pendingHandoff.isStagedForSend)

            // The source conversation is unchanged.
            XCTAssertEqual(fixture.sourceSession.activeAgentSessionID, fixture.sourceSessionID)
            XCTAssertEqual(fixture.sourceSession.worktreeBindings, sourceBindings)
            XCTAssertEqual(
                fixture.viewModel.worktreeBindingState(forAgentSessionID: fixture.sourceSessionID),
                .hydrated(sourceBindings)
            )

            // Independent projection ownership: releasing the source does not invalidate the destination.
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: fixture.store)
            await materializer.release(sessionID: fixture.sourceSessionID)
            let destinationPreparation = try await materializer.prepare(
                sessionID: destinationSessionID,
                bindings: sourceBindings
            )
            XCTAssertTrue(
                destinationPreparation.ownership.reusesInstalledOwnership,
                "the destination must own its installed projection independently of the source"
            )
            let projection = await materializer.materialize(sessionID: destinationSessionID, bindings: sourceBindings)
            XCTAssertEqual(projection?.isFullyMaterialized, true)
        }
    }

    func testUnboundSourceHandoffKeepsPrimaryCheckoutBehavior() async throws {
        try await withFixture(bindSource: false) { fixture in
            XCTAssertTrue(fixture.sourceSession.worktreeBindings.isEmpty)
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            var events: [String] = []
            var hookCalled = false
            fixture.viewModel.test_beforeHandoffDestinationWorktreeInstall = { hookCalled = true }
            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                if session.id != fixture.sourceSessionID {
                    events.append("save")
                    XCTAssertTrue(session.worktreeBindings.isEmpty)
                }
                return fixture.git.sandbox.appendingPathComponent("\(session.id).json")
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in
                events.append("inherit")
                return .empty
            }

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sourceSession.selectedAgent,
                destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
            )

            let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertFalse(hookCalled, "an unbound source never enters the worktree install path")
            XCTAssertEqual(events, ["save", "inherit"])
            XCTAssertTrue(destination.worktreeBindings.isEmpty)
            XCTAssertTrue(fixture.sourceSession.worktreeBindings.isEmpty)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)
        }
    }

    func testSourceExecutionLocationChangeDuringHandoffFailsAndRemovesDestination() async throws {
        try await withFixture(bindSource: true) { fixture in
            XCTAssertFalse(fixture.sourceSession.worktreeBindings.isEmpty)
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            let composeTabIDsBefore = composeTabIDs(fixture)
            var inheritanceWasCalled = false
            var deletedTabIDs: [UUID] = []

            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                fixture.git.sandbox.appendingPathComponent("\(session.id).json")
            }
            fixture.viewModel.test_setAgentSessionsDeleter { tabID, _ in
                deletedTabIDs.append(tabID)
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in
                inheritanceWasCalled = true
                return .empty
            }
            // The source returns to its primary checkout after the payload was built from the worktree.
            fixture.viewModel.test_beforeHandoffDestinationWorktreeInstall = {
                fixture.sourceSession.worktreeBindings = []
            }

            do {
                _ = try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: cutoffItemID,
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
                )
                XCTFail("A stale source must not produce a primary-checkout destination")
            } catch let AgentSessionError.handoffExecutionLocationUnavailable(reason) {
                XCTAssertTrue(reason.contains("changed during Handoff"), reason)
                XCTAssertFalse(reason.contains("could not be removed"), reason)
            }

            XCTAssertFalse(inheritanceWasCalled)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
            XCTAssertEqual(composeTabIDs(fixture), composeTabIDsBefore)
            XCTAssertEqual(deletedTabIDs.count, 1, "the never-activated destination is durably removed")
            XCTAssertFalse(deletedTabIDs.contains(fixture.sourceTabID))
        }
    }

    func testUnavailableSourceWorktreeFailsBeforeCreatingDestination() async throws {
        try await withFixture(bindSource: true) { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            let composeTabIDsBefore = composeTabIDs(fixture)
            var saverCalledForDestination = false
            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                if session.id != fixture.sourceSessionID {
                    saverCalledForDestination = true
                }
                return fixture.git.sandbox.appendingPathComponent("\(session.id).json")
            }
            try fixture.git.runGit(["worktree", "remove", "--force", fixture.linkedWorktreeURL.path], at: fixture.logicalRootURL)

            do {
                _ = try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: cutoffItemID,
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
                )
                XCTFail("An unavailable source worktree must not fall back to the primary checkout")
            } catch let AgentSessionError.handoffExecutionLocationUnavailable(reason) {
                XCTAssertTrue(reason.contains("no longer available"), reason)
            }

            XCTAssertFalse(saverCalledForDestination)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
            XCTAssertEqual(composeTabIDs(fixture), composeTabIDsBefore)
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let git: ReviewGitRepositoryFixture
        let window: WindowState
        let logicalRootURL: URL
        let linkedWorktreeURL: URL
        let viewModel: AgentModeViewModel
        let store: WorkspaceFileContextStore
        let sourceTabID: UUID
        let sourceSessionID: UUID
        let sourceSession: AgentModeViewModel.TabSession
    }

    private func withFixture(bindSource: Bool, _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture(bindSource: bindSource)
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture(bindSource: Bool) async throws -> Fixture {
        let git = try ReviewGitRepositoryFixture(name: "AgentSessionHandoffWorktreeBindingTests")
        let logicalRootURL = try git.makeRepository(named: "logical", files: ["README.md": "fixture\n"])
        let linkedWorktreeURL = git.sandbox.appendingPathComponent("linked", isDirectory: true)
        try git.runGit(["worktree", "add", "--detach", linkedWorktreeURL.path, "HEAD"], at: logicalRootURL)
        let identity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: linkedWorktreeURL))

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Handoff worktree \(UUID().uuidString.prefix(8))",
                repoPaths: [logicalRootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentSessionHandoffWorktreeBindingTests"
            )

            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let sourceTabID = UUID()
            let sourceSessionID = UUID()
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == activeWorkspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                ComposeTabState(id: sourceTabID, name: "Source", activeAgentSessionID: sourceSessionID)
            ]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = sourceTabID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let store = window.promptManager.workspaceFileContextStore
            let visibleRootPaths = await store.rootRefs(scope: .visibleWorkspace).map(\.standardizedFullPath)
            if !visibleRootPaths.contains(logicalRootURL.standardizedFileURL.path) {
                _ = try await store.loadRoot(path: logicalRootURL.path)
            }

            let viewModel = window.agentModeViewModel
            let sourceSession = viewModel.session(for: sourceTabID)
            XCTAssertEqual(sourceSession.activeAgentSessionID, sourceSessionID)
            sourceSession.hasLoadedPersistedState = true
            sourceSession.setItemsSilently(
                [
                    .user("Source user", sequenceIndex: 0),
                    .assistant("Source assistant", sequenceIndex: 1)
                ],
                reason: .testOverride
            )
            viewModel.refreshDerivedTranscriptState(for: sourceSession)

            if bindSource {
                let bindings = [AgentSessionWorktreeBinding(
                    id: "primary",
                    repositoryID: identity.repository.repositoryID,
                    repoKey: identity.repository.repoKey,
                    logicalRootPath: logicalRootURL.path,
                    logicalRootName: "Project",
                    worktreeID: identity.worktreeID,
                    worktreeRootPath: linkedWorktreeURL.path,
                    commonGitDir: identity.repository.commonGitDir,
                    isMainWorktree: false,
                    source: "test"
                )]
                // Give the source its own installed projection, as a real bound session would have.
                let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
                let preparation = try await materializer.prepare(sessionID: sourceSessionID, bindings: bindings)
                _ = try await materializer.commit(preparation)
                sourceSession.worktreeBindings = bindings
            }
            viewModel.setAgentModeActive(true)

            return Fixture(
                git: git,
                window: window,
                logicalRootURL: logicalRootURL,
                linkedWorktreeURL: linkedWorktreeURL,
                viewModel: viewModel,
                store: store,
                sourceTabID: sourceTabID,
                sourceSessionID: sourceSessionID,
                sourceSession: sourceSession
            )
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            git.cleanup()
            throw error
        }
    }

    private func composeTabIDs(_ fixture: Fixture) -> Set<UUID> {
        Set(fixture.window.workspaceManager.activeWorkspace?.composeTabs.map(\.id) ?? [])
    }

    private func cleanup(_ fixture: Fixture) async {
        fixture.viewModel.test_beforeHandoffDestinationWorktreeInstall = nil
        fixture.window.beginClose()
        await fixture.window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(fixture.window)
        fixture.git.cleanup()
    }
}
