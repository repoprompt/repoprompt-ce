import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptVCS
import XCTest

@MainActor
final class SessionAdminWorktreeRecoveryTests: XCTestCase {
    func testExistingCheckoutRecoveryReplaysThroughToolBindAndRelease() async throws {
        try await withFixture { fixture in
            let checkout = fixture.git.sandbox.appendingPathComponent("existing-checkout")
            try fixture.git.runGit(["worktree", "add", "-b", "e2e/recovery", checkout.path, "HEAD"], at: fixture.repository)
            let before = try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository)
            let refused = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/recovery"), "idempotency_key": .string("existing-checkout")
            ])
            XCTAssertEqual(refused["code"], .string("branch_exists"))
            XCTAssertEqual(try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository), before)
            XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
            let next = try XCTUnwrap(refused["next_call"]?.objectValue)
            XCTAssertEqual(next["tool"], .string("session_admin"))
            let arguments = try XCTUnwrap(next["arguments"]?.objectValue)
            XCTAssertEqual(arguments["op"], .string("worktree_bind"))
            XCTAssertEqual(arguments["session_id"], .string(fixture.sessionID.uuidString))
            let recoveryPath = try XCTUnwrap(arguments["worktree"]?.stringValue)
            XCTAssertEqual(GitRepoRootAuthorization.canonicalPath(recoveryPath), GitRepoRootAuthorization.canonicalPath(checkout.path))

            // Replay the returned public call verbatim, without supplying missing target or scope
            // arguments. The production host resolves Git identity and durably binds the session.
            let bound = try await fixture.call(arguments)
            XCTAssertEqual(bound["result"], .string("applied"))
            let binding = try XCTUnwrap(fixture.session.worktreeBindings.first)
            XCTAssertEqual(GitRepoRootAuthorization.canonicalPath(binding.worktreeRootPath), GitRepoRootAuthorization.canonicalPath(checkout.path))
            let savedBound = try await fixture.savedSession()
            let persistedBound = try XCTUnwrap(savedBound)
            XCTAssertEqual(persistedBound.worktreeBindings.map(\.worktreeID), [binding.worktreeID])

            let released = try await fixture.call([
                "op": .string("worktree_release"), "worktree_id": .string(binding.worktreeID)
            ])
            XCTAssertEqual(released["result"], .string("applied"))
            XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
            let savedReleased = try await fixture.savedSession()
            let persistedReleased = try XCTUnwrap(savedReleased)
            XCTAssertTrue(persistedReleased.worktreeBindings.isEmpty)
            XCTAssertNotNil(fixture.authorization.ownership.record(worktreeID: binding.worktreeID)?.releasedAt)
            XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("README.md").path))
            XCTAssertEqual(
                try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository),
                before,
                "Release leaves the checkout and Git registration for human cleanup"
            )
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.foregroundTabID)
        }
    }

    func testExistingBranchWithoutCheckoutDoesNotInventBindRecovery() async throws {
        try await withFixture { fixture in
            try fixture.git.runGit(["branch", "e2e/no-checkout"], at: fixture.repository)
            let before = try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository)
            let refused = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/no-checkout"), "idempotency_key": .string("existing-branch")
            ])
            XCTAssertEqual(refused["code"], .string("branch_exists"))
            XCTAssertNil(refused["next_call"], "A branch with no checkout supplies no path that can be bound")
            XCTAssertTrue(refused["detail"]?.stringValue?.contains("new branch name") == true)
            XCTAssertEqual(try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository), before)
            XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
            XCTAssertTrue(fixture.authorization.ownership.records.isEmpty)
        }
    }

    @MainActor
    private struct Fixture {
        let git: ReviewGitRepositoryFixture
        let repository: URL
        let window: WindowState
        let session: AgentTabSession
        let sessionID: UUID
        let foregroundTabID: UUID
        let dataService: AgentSessionDataService
        let authorization: SessionAdminStructureTests.Fixture
        let service: SessionAdminMCPToolService

        func call(_ arguments: [String: Value]) async throws -> [String: Value] {
            let result = try await service.execute(args: arguments)
            return try XCTUnwrap(result.objectValue)
        }

        func savedSession() async throws -> AgentSession? {
            let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            return try await dataService.loadAgentSession(id: sessionID, for: workspace)
        }
    }

    /// The caller route and permission census are isolated fixtures. Worktree discovery, the host,
    /// bind/release transitions, and session writes use their production implementations against
    /// a disposable Git repository. No agent provider is started.
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let git = try ReviewGitRepositoryFixture(name: "SessionAdminWorktreeRecovery")
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        let previousFullAccess = OverseerGlobalAutoApprove.isEnabled
        OverseerGlobalAutoApprove.isEnabled = { true }
        let cleanup: @MainActor () async -> Void = {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            OverseerGlobalAutoApprove.isEnabled = previousFullAccess
            git.cleanup()
        }
        do {
            let repository = try git.makeRepository(named: "repository", files: ["README.md": "fixture\n"])
            await window.workspaceManager.awaitInitialized()
            let created = window.workspaceManager.createWorkspace(name: "Worktree recovery", repoPaths: [repository.path], ephemeral: true)
            await window.workspaceManager.switchWorkspace(to: created, saveState: false, reason: "worktreeRecoveryTest")
            _ = try await window.promptManager.workspaceFileContextStore.loadRoot(path: repository.path)
            var workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let foregroundTabID = try XCTUnwrap(workspace.activeComposeTabID)
            let sessionID = UUID(), callerID = UUID()
            let targetTab = ComposeTabState(name: "Background target", activeAgentSessionID: sessionID)
            workspace.composeTabs.append(targetTab)
            let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
            window.workspaceManager.workspaces[workspaceIndex] = workspace
            window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
            let viewModel = window.agentModeViewModel
            let session = viewModel.session(for: targetTab.id)
            _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session))
            session.hasLoadedPersistedState = true
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
            var entry = AgentSessionIndexEntry(
                id: sessionID, tabID: targetTab.id, name: targetTab.name, savedAt: Date(), itemCount: 0,
                autoEditEnabled: false, hasUnknownConversationContent: false, isMCPOriginated: false,
                worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
            entry.lastRunStateRaw = "idle"
            viewModel.test_installSessionIndexSnapshot([sessionID: entry], owner: owner, latestOwner: owner, activeWorkspace: workspace)
            let dataService = AgentSessionDataService()
            await dataService.test_setWorkspaceRootOverride(git.sandbox.appendingPathComponent("sessions"))
            viewModel.test_setAgentSessionSaver { payload, workspace, count in
                try await dataService.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
            }
            XCTAssertTrue(try viewModel.authoritativeLiveSession(for: sessionID) === session)

            let authorization = SessionAdminStructureTests.Fixture()
            authorization.provenance.add(callerID, parent: nil, workspace: workspace.id)
            authorization.provenance.add(sessionID, parent: callerID, workspace: workspace.id)
            typealias Organizing = SessionAdminOrganizingOperationTests
            let organizer = Organizing.FakeOrganizer(), links = Organizing.FakeLinks()
            let inventoryProvenance = SessionAdminScopeLifecycleTests.FakeProvenance()
            defer { withExtendedLifetime((organizer, links, inventoryProvenance)) {} }
            let door = AgentSessionAdministrationFrontDoor(
                core: authorization.core, scopes: authorization.runtime, projector: authorization.projector,
                inventory: Organizing.FakeInventory(organizer: organizer, provenance: inventoryProvenance, links: links, now: Date()),
                liveBoundSession: { $0 == foregroundTabID ? callerID : nil }
            )
            door.registerStructureHandlers(
                scopes: authorization.runtime, worktreeOwnership: authorization.ownership, projector: authorization.projector,
                structureHost: SessionAdminWindowsStructureHost(), worktreeHost: SessionAdminWindowsWorktreeHost()
            )
            let endpoint = DomainAgentSessionLinkEndpointIdentity(
                windowID: window.windowID, workspaceID: workspace.id, tabID: foregroundTabID, sessionID: callerID,
                persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
            )
            var service = SessionAdminMCPToolService(
                captureRequestMetadata: { .init(connectionID: UUID(), clientName: "worktree-recovery-test", windowID: window.windowID) },
                requireTargetWindow: { window }, resolveObserverEndpoint: { _, _ in endpoint },
                scopes: { authorization.runtime }, administration: { door }
            )
            service.isToolEnabled = { true }
            try await body(.init(
                git: git, repository: repository, window: window, session: session, sessionID: sessionID,
                foregroundTabID: foregroundTabID, dataService: dataService, authorization: authorization, service: service
            ))
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}
