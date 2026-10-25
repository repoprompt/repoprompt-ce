import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptPersistence
import RepoPromptSettingsCore
import RepoPromptVCS
import XCTest

@MainActor
final class SessionAdminWorktreeRecoveryTests: XCTestCase {
    func testUnopenedLaneModelAndEffortUseItsWriterDespiteEarlierWorkspaceReplica() async throws {
        for fullAccess in [true, false] {
            try await withFixture(fullAccess: fullAccess) { fixture in
                let settings = GlobalSettingsStore.shared
                let originalProfile = settings.globalAgentModelsProfile()
                defer {
                    settings.setGlobalAgentModelsProfile(originalProfile, contextBuilderWriteIntent: .preserveExistingOwnership)
                    AgentAdvertisedModelCatalog.shared.invalidate(.claudeCode)
                }
                var profile = originalProfile
                profile.mcpAgentRoleOverrides = ["explore": "claudeCode:sonnet:medium"]
                profile.mcpAgentRoleModelParameters = [:]
                settings.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
                fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
                try await AsyncTestWait.waitUntil("model writer availability") {
                    fixture.window.apiSettingsViewModel.agentAvailability.claudeCodeAvailable
                }
                AgentAdvertisedModelCatalog.shared.record([
                    AgentModelOption(
                        rawValue: "sonnet:medium", displayName: "Sonnet", description: nil,
                        isPlaceholderDefault: false, isProviderDefault: false
                    )
                ], for: .claudeCode, generation: AgentAdvertisedModelCatalog.shared.productionGeneration(for: .claudeCode))
                let binding = fixture.session.persistentSessionBindingIdentity
                let peerWorkspace = fixture.replica.workspaceManager.activeWorkspace
                let peerIndex = fixture.replica.agentModeViewModel.ownerValidatedSessionIndex
                let modelRequest: [String: Value] = [
                    "op": .string("set_model"), "session_id": .string(fixture.sessionID.uuidString),
                    "model_id": .string("explore")
                ]
                let model = try await fixture.call(modelRequest)
                XCTAssertEqual(model["result"], .string("applied"), String(describing: model))
                XCTAssertEqual(fixture.session.selectedModelRaw, "sonnet:medium")
                let repeatedModel = try await fixture.call(modelRequest)
                XCTAssertEqual(repeatedModel["result"], .string("applied"), String(describing: repeatedModel))
                XCTAssertEqual(repeatedModel["changed_count"], .int(0))
                XCTAssertEqual(repeatedModel["state_satisfied"], .bool(true))
                let effortRequest: [String: Value] = [
                    "op": .string("set_effort"), "session_id": .string(fixture.sessionID.uuidString),
                    "effort": .string("high")
                ]
                let effort = try await fixture.call(effortRequest)
                XCTAssertEqual(effort["result"], .string("applied"), String(describing: effort))
                XCTAssertEqual(fixture.session.selectedClaudeEffortRaw, "high")
                let repeatedEffort = try await fixture.call(effortRequest)
                XCTAssertEqual(repeatedEffort["result"], .string("applied"), String(describing: repeatedEffort))
                XCTAssertEqual(repeatedEffort["changed_count"], .int(0))
                XCTAssertEqual(repeatedEffort["state_satisfied"], .bool(true))
                try await fixture.window.agentModeViewModel.flushSaveRequired(
                    for: fixture.session.tabID, workspaceID: fixture.workspaceID
                ).get()
                let saved = try await fixture.savedSession()
                let persisted = try XCTUnwrap(saved)
                XCTAssertEqual(persisted.agentKind, AgentProviderKind.claudeCode.rawValue)
                XCTAssertEqual(persisted.agentModel, "sonnet:medium")
                XCTAssertEqual(persisted.agentReasoningEffort, "high")
                XCTAssertEqual(fixture.session.persistentSessionBindingIdentity, binding)
                XCTAssertNil(fixture.session.runID)
                XCTAssertTrue(fixture.session.items.isEmpty)
                XCTAssertNil(fixture.replica.agentModeViewModel.sessions[fixture.session.tabID])
                XCTAssertEqual(fixture.replica.workspaceManager.activeWorkspace, peerWorkspace)
                XCTAssertEqual(fixture.replica.agentModeViewModel.ownerValidatedSessionIndex, peerIndex)
                fixture.assertForegroundUnchanged()
            }
        }
    }

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
            XCTAssertNotNil(fixture.ownership.record(worktreeID: binding.worktreeID)?.releasedAt)
            XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("README.md").path))
            XCTAssertEqual(
                try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository),
                before,
                "Release leaves the checkout and Git registration for human cleanup"
            )
            XCTAssertNil(fixture.replica.agentModeViewModel.sessions[fixture.session.tabID])
            fixture.assertForegroundUnchanged()
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
            XCTAssertTrue(fixture.ownership.records.isEmpty)
        }
    }

    func testCompetingBoundWritersCannotMutateConfigurationOrCreateWorktree() async throws {
        for peerReady in [true, false] {
            try await withFixture { fixture in
                let originalOwner = try XCTUnwrap(SessionAdminWindows.runtimeOwner(for: fixture.sessionID))
                XCTAssertTrue(SessionAdminWindows.isCurrent(originalOwner))
                let peer = fixture.replica.agentModeViewModel.session(for: fixture.session.tabID)
                peer.selectedAgent = .claudeCode
                peer.selectedModelRaw = "haiku"
                peer.selectedClaudeEffortRaw = "low"
                peer.parentSessionID = fixture.session.parentSessionID
                peer.createdByOverseerSessionID = fixture.session.createdByOverseerSessionID
                peer.hasLoadedPersistedState = peerReady
                _ = try XCTUnwrap(fixture.replica.agentModeViewModel.test_installPersistentSessionBinding(
                    sessionID: fixture.sessionID, on: peer
                ))
                if peerReady { peer.recordRestorationAuthoritative(.persistedPayloadApplied) }
                XCTAssertEqual(peer.permitsBoundOperationAndSave, peerReady)
                XCTAssertTrue(try fixture.replica.agentModeViewModel.authoritativeLiveSession(for: fixture.sessionID) === peer)
                let source = OpenWindowsDelegationProvenanceSource()
                XCTAssertEqual(source.resolutionState(for: fixture.sessionID), .replicated)
                XCTAssertEqual(source.provenance(for: fixture.sessionID)?.hasUniqueRuntimeOwner, false)
                XCTAssertNil(SessionAdminWindows.runtimeOwner(for: fixture.sessionID))
                XCTAssertFalse(SessionAdminWindows.isCurrent(originalOwner), "A second bound object invalidates prior owner proof before it finishes loading")
                let before = try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository)
                let ownerSaveGeneration = fixture.session.saveRequestGeneration
                let peerSaveGeneration = peer.saveRequestGeneration
                for arguments: [String: Value] in [
                    ["op": .string("set_model"), "model_id": .string("explore")],
                    ["op": .string("set_effort"), "effort": .string("high")],
                    ["op": .string("worktree_create"), "branch": .string("e2e/competing-writers"), "idempotency_key": .string("competing-writers")]
                ] {
                    var request = arguments
                    request["session_id"] = .string(fixture.sessionID.uuidString)
                    let refused = try await fixture.call(request)
                    XCTAssertEqual(refused["code"], .string("mutation_owner_unavailable"), String(describing: refused))
                    XCTAssertEqual(refused["subreason"], .string("replicated_binding"))
                }
                XCTAssertEqual(fixture.session.selectedModelRaw, "haiku")
                XCTAssertEqual(peer.selectedModelRaw, "haiku")
                XCTAssertEqual(fixture.session.selectedClaudeEffortRaw, "low")
                XCTAssertEqual(peer.selectedClaudeEffortRaw, "low")
                XCTAssertEqual(fixture.session.saveRequestGeneration, ownerSaveGeneration)
                XCTAssertEqual(peer.saveRequestGeneration, peerSaveGeneration)
                XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
                XCTAssertTrue(peer.worktreeBindings.isEmpty)
                XCTAssertTrue(fixture.ownership.records.isEmpty)
                XCTAssertEqual(try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository), before)
                fixture.assertForegroundUnchanged()
            }
        }
    }

    @MainActor
    private struct Fixture {
        let git: ReviewGitRepositoryFixture
        let repository: URL
        let window: WindowState
        let replica: WindowState
        let session: AgentTabSession
        let sessionID: UUID
        let workspaceID: UUID
        let foregroundTabID: UUID
        let dataService: AgentSessionDataService
        let ownership: WorktreeOwnershipStore
        let service: SessionAdminMCPToolService

        func call(_ arguments: [String: Value]) async throws -> [String: Value] {
            let result = try await service.execute(args: arguments)
            return try XCTUnwrap(result.objectValue)
        }

        func savedSession() async throws -> AgentSession? {
            let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            return try await dataService.loadAgentSession(id: sessionID, for: workspace)
        }

        func assertForegroundUnchanged() {
            XCTAssertEqual(window.promptManager.activeComposeTabID, foregroundTabID)
            XCTAssertEqual(replica.promptManager.activeComposeTabID, foregroundTabID)
            XCTAssertEqual(window.promptManager.promptText, "Owner draft")
            XCTAssertEqual(replica.promptManager.promptText, "Replica draft")
            XCTAssertNotEqual(window.agentModeViewModel.currentTabID, session.tabID)
            XCTAssertNotEqual(replica.agentModeViewModel.currentTabID, session.tabID)
        }
    }

    /// The passive replica is registered first and shares the physical tab and owner-valid index.
    /// Only the second window binds the background payload. Production provenance, caller binding,
    /// authorization and hosts must distinguish those facts without selecting either target tab.
    private func withFixture(fullAccess: Bool = true, _ body: (Fixture) async throws -> Void) async throws {
        let git = try ReviewGitRepositoryFixture(name: "SessionAdminWorktreeRecovery")
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let replica = WindowState()
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(replica)
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        let previousFullAccess = OverseerGlobalAutoApprove.isEnabled
        OverseerGlobalAutoApprove.isEnabled = { fullAccess }
        let cleanup: @MainActor () async -> Void = {
            window.beginClose()
            replica.beginClose()
            await window.tearDown()
            await replica.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            WindowStatesManager.shared.unregisterWindowState(replica)
            OverseerGlobalAutoApprove.isEnabled = previousFullAccess
            git.cleanup()
        }
        do {
            let repository = try git.makeRepository(named: "repository", files: ["README.md": "fixture\n"])
            await replica.workspaceManager.awaitInitialized()
            await window.workspaceManager.awaitInitialized()
            let created = window.workspaceManager.createWorkspace(name: "Worktree recovery", repoPaths: [repository.path], ephemeral: true)
            await window.workspaceManager.switchWorkspace(to: created, saveState: false, reason: "worktreeRecoveryTest")
            _ = try await window.promptManager.workspaceFileContextStore.loadRoot(path: repository.path)
            var workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let foregroundTabID = try XCTUnwrap(workspace.activeComposeTabID)
            let sessionID = UUID(), callerID = UUID()
            let foregroundIndex = try XCTUnwrap(workspace.composeTabs.firstIndex { $0.id == foregroundTabID })
            workspace.composeTabs[foregroundIndex].activeAgentSessionID = callerID
            let targetTab = ComposeTabState(name: "Background target", activeAgentSessionID: sessionID)
            workspace.composeTabs.append(targetTab)
            let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
            window.workspaceManager.workspaces[workspaceIndex] = workspace
            window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
            let viewModel = window.agentModeViewModel
            let caller = viewModel.session(for: foregroundTabID)
            _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: callerID, on: caller))
            caller.hasLoadedPersistedState = true
            caller.recordRestorationAuthoritative(.persistedPayloadApplied)
            let session = viewModel.session(for: targetTab.id)
            _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session))
            session.selectedAgent = .claudeCode
            session.selectedModelRaw = "haiku"
            session.selectedReasoningEffortRaw = "low"
            session.selectedClaudeEffortRaw = "low"
            session.parentSessionID = callerID
            session.createdByOverseerSessionID = callerID
            session.hasLoadedPersistedState = true
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
            var entry = AgentSessionIndexEntry(
                id: sessionID, tabID: targetTab.id, name: targetTab.name, savedAt: Date(), itemCount: 0,
                autoEditEnabled: false, hasUnknownConversationContent: false, isMCPOriginated: false,
                worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
            entry.lastRunStateRaw = "idle"
            entry.parentSessionID = callerID
            entry.createdByOverseerSessionID = callerID
            let callerEntry = AgentSessionIndexEntry(
                id: callerID, tabID: foregroundTabID, name: "Overseer", savedAt: Date(), itemCount: 0,
                autoEditEnabled: false, hasUnknownConversationContent: false, isMCPOriginated: false,
                worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
            viewModel.test_installSessionIndexSnapshot(
                [sessionID: entry, callerID: callerEntry], owner: owner, latestOwner: owner, activeWorkspace: workspace
            )
            let dataService = AgentSessionDataService()
            await dataService.test_setWorkspaceRootOverride(git.sandbox.appendingPathComponent("sessions"))
            viewModel.test_setAgentSessionSaver { payload, workspace, count in
                try await dataService.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
            }
            session.isDirty = true
            try await viewModel.flushSaveRequired(for: targetTab.id, workspaceID: workspace.id).get()
            XCTAssertTrue(try viewModel.authoritativeLiveSession(for: sessionID) === session)
            workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            replica.workspaceManager.workspaces = [workspace]
            replica.workspaceManager.activeWorkspace = workspace
            replica.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
            for tabID in Array(replica.agentModeViewModel.sessions.keys) {
                replica.agentModeViewModel.test_removeSession(tabID: tabID)
            }
            replica.agentModeViewModel.test_installSessionIndexSnapshot(
                viewModel.ownerValidatedSessionIndex, owner: owner, latestOwner: owner, activeWorkspace: workspace
            )
            window.promptManager.promptText = "Owner draft"
            replica.promptManager.promptText = "Replica draft"
            // Draft publication is asynchronous. Capture the no-peer-mutation baseline only
            // after fixture setup has reached both workspace projections.
            try await AsyncTestWait.waitUntil("foreground drafts published") {
                window.workspaceManager.activeWorkspace?.composeTabs.first { $0.id == foregroundTabID }?.promptText == "Owner draft"
                    && replica.workspaceManager.activeWorkspace?.composeTabs.first { $0.id == foregroundTabID }?.promptText == "Replica draft"
            }
            let source = OpenWindowsDelegationProvenanceSource()
            XCTAssertEqual(source.resolutionState(for: sessionID), .replicated)
            XCTAssertEqual(source.censusSnapshot().states[sessionID], .replicated)
            XCTAssertEqual(source.placement(for: sessionID)?.workspaceID, workspace.id)
            XCTAssertEqual(source.provenance(for: sessionID)?.hasUniqueRuntimeOwner, true)
            let runtimeOwner = try XCTUnwrap(SessionAdminWindows.runtimeOwner(for: sessionID))
            XCTAssertTrue(runtimeOwner.location.window === window)
            XCTAssertTrue(runtimeOwner.session === session)
            XCTAssertEqual(runtimeOwner.binding, session.currentRestorationBindingToken)
            let metadataPresenters = WindowStatesManager.shared.allWindows.filter {
                $0.agentModeViewModel.ownerValidatedSessionIndex[sessionID] != nil
            }
            XCTAssertTrue(metadataPresenters.first === replica, "Metadata order must not select the passive replica as writer")
            XCTAssertEqual(metadataPresenters.count, 2)
            XCTAssertNil(replica.agentModeViewModel.sessions[targetTab.id])
            let scopes = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
            if !fullAccess {
                let request = try scopes.requestScope(
                    requesterSessionID: callerID, requesterTabID: nil,
                    kind: .session(targetSessionID: sessionID), capabilities: [.control],
                    guardrails: .init(), reason: nil, idempotencyKey: nil
                ).get()
                let grant = try scopes.approve(requestID: request.id).get()
                XCTAssertEqual(grant.grant.kind, .session(targetSessionID: sessionID))
                XCTAssertEqual(grant.grant.capabilities, [.control])
            }
            let ownership = WorktreeOwnershipStore()
            let core = AgentSessionAdministrationCore.makeProduction(scopes: scopes, worktreeOwnership: ownership)
            let location = HistoryWorkspaceLocation(
                runtimeID: UUID(), workspaceID: workspace.id, name: workspace.name,
                directory: WorkspaceSessionSidecarMigration.workspaceDirectory(
                    for: workspace, root: git.sandbox.appendingPathComponent("sessions")
                )
            )
            let locations = HistoryWorkspaceLocationResolver(resolve: { selector in
                switch selector {
                case let .id(id) where id == location.workspaceID: .matched(location)
                case let .exactName(name) where name == location.name: .matched(location)
                default: .notRegistered
                }
            })
            let door = AgentSessionAdministrationFrontDoor.production(core: core, scopes: scopes, workspaceLocations: locations)
            door.registerStructureHandlers(scopes: scopes, worktreeOwnership: ownership)
            var service = SessionAdminMCPToolService(
                captureRequestMetadata: { .init(connectionID: UUID(), clientName: "worktree-recovery-test", windowID: window.windowID) },
                requireTargetWindow: { window },
                resolveObserverEndpoint: { _, _ in viewModel.agentSessionLinkObserverEndpoint(tabID: foregroundTabID) },
                scopes: { scopes }, administration: { door }
            )
            service.isToolEnabled = { true }
            try await body(.init(
                git: git, repository: repository, window: window, replica: replica, session: session, sessionID: sessionID,
                workspaceID: workspace.id, foregroundTabID: foregroundTabID, dataService: dataService,
                ownership: ownership, service: service
            ))
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}

@MainActor
final class DelegationScopeEndingTests: XCTestCase {
    func testEndingsRetainReasonTimeAndOwnerAcrossRestart() async throws {
        for reason: OverseerScopeEnding.Reason in [.userRevoked, .granteeReleased, .sessionDeleted, .expired] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            func store() -> DelegationScopeStore {
                .init(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
            }
            var clock = Date(timeIntervalSince1970: 2_000_000)
            let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { clock }, notifyCatalogChanged: { _ in })
            await runtime.bootstrap(store: store())
            let caller = UUID()
            let request = try runtime.requestScope(requesterSessionID: caller, requesterTabID: nil, kind: .tree(rootSessionID: caller), capabilities: [.observe, .spawn], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: nil).get()
            let scope = try runtime.approve(requestID: request.id).get()
            let childSession = UUID()
            let child = try runtime.attenuate(parentScopeID: scope.id, presentedGeneration: scope.generation, caller: .agentSession(caller), newGranteeSessionID: childSession, newGranteeMemberships: [.init(scopeID: scope.id, targetSessionID: childSession, basis: .treePath([childSession, caller]))], capabilities: [.observe], guardrails: scope.grant.guardrails).get()
            if reason != .granteeReleased { await runtime.flushPersistence() }
            clock = clock.addingTimeInterval(10)
            switch reason {
            case .userRevoked: runtime.revoke(scopeID: scope.id)
            case .granteeReleased: _ = try runtime.release(scopeID: scope.id, caller: .agentSession(caller)).get()
            case .sessionDeleted: runtime.revokeAll(involving: caller)
            default:
                clock = clock.addingTimeInterval(50)
                XCTAssertFalse(runtime.hasLiveScope(grantedTo: caller))
            }
            let evidence = try XCTUnwrap(runtime.ending(for: scope.id), reason.rawValue)
            XCTAssertEqual(evidence.reason, reason)
            XCTAssertEqual(evidence.at, clock)
            if reason == .granteeReleased { XCTAssertEqual(evidence.actorSessionID, caller) }
            if reason == .sessionDeleted { XCTAssertEqual(evidence.originatingSessionID, caller) }
            await runtime.flushPersistence()
            XCTAssertEqual(runtime.continuityState, "saved")
            runtime.freezeForTermination()
            let restored = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { clock }, notifyCatalogChanged: { _ in })
            await restored.bootstrap(store: store())
            XCTAssertFalse(restored.hasLiveScope(grantedTo: caller))
            XCTAssertNil(restored.record(id: scope.id), "Restored history must not participate in authorization")
            XCTAssertEqual(restored.statusRecord(id: scope.id)?.id, scope.id)
            XCTAssertEqual(restored.ending(for: scope.id), evidence)
            XCTAssertEqual(restored.ending(for: child.id), evidence)
            XCTAssertFalse(restored.hasLiveScope(grantedTo: childSession))
            let record = try XCTUnwrap(restored.scopes(grantedTo: caller).first)
            XCTAssertEqual(record.id, scope.id)
            XCTAssertEqual(record.state, reason == .expired ? .expired : .revoked)
            let value = SessionAdminMCPToolService.scopeValue(record, now: clock, ending: restored.ending(for: scope.id))
            XCTAssertEqual(value.objectValue?["ending"]?.objectValue?["reason"], .string(reason.rawValue))
            restored.revoke(scopeID: scope.id)
            XCTAssertEqual(restored.ending(for: scope.id), evidence, "A later revoke must not replace the first ending")
            restored.freezeForTermination()
        }
    }

    func testFailedChildEndingSurvivesLaterAncestorCascadeAndRetry() async throws {
        final class FailureGate: @unchecked Sendable {
            private let lock = NSLock()
            private var failing = false
            func setFailing(_ value: Bool) {
                lock.withLock { failing = value }
            }

            func check() throws {
                if lock.withLock({ failing }) { throw CocoaError(.fileWriteOutOfSpace) }
            }
        }
        for (deleteAncestor, storeOnlyChild, failAncestorSave) in [
            (false, false, false), (true, false, false),
            (false, true, false), (true, true, false),
            (false, true, true), (true, true, true)
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let gate = FailureGate()
            func store() -> DelegationScopeStore {
                .init(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled, beforeCommit: { try gate.check() })
            }
            var clock = Date(timeIntervalSince1970: 2_000_000)
            let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { clock }, notifyCatalogChanged: { _ in })
            await runtime.bootstrap(store: store())
            let owner = UUID(), childOwner = UUID()
            let request = try runtime.requestScope(requesterSessionID: owner, requesterTabID: nil, kind: .tree(rootSessionID: owner), capabilities: [.observe, .spawn], guardrails: .init(), reason: nil, idempotencyKey: nil).get()
            let parent = try runtime.approve(requestID: request.id).get()
            await runtime.flushPersistence()
            let child: DomainDelegationScopeGrant
            if storeOnlyChild {
                child = .init(id: UUID(), granteeSessionID: childOwner, kind: .tree(rootSessionID: childOwner), capabilities: [.observe], guardrails: .init(), origin: .attenuatedFrom(scopeID: parent.id), grantedAt: clock)
                XCTAssertEqual(store().record(operationID: UUID(), grants: [child], revoked: []), .applied)
                XCTAssertNil(runtime.record(id: child.id), "Another writer's child must remain absent from this runtime")
            } else {
                child = try runtime.attenuate(parentScopeID: parent.id, presentedGeneration: parent.generation, caller: .agentSession(owner), newGranteeSessionID: childOwner, newGranteeMemberships: [.init(scopeID: parent.id, targetSessionID: childOwner, basis: .treePath([childOwner, owner]))], capabilities: [.observe], guardrails: .init()).get().grant
            }
            await runtime.flushPersistence()
            gate.setFailing(true)
            clock = clock.addingTimeInterval(1)
            let firstEnding: OverseerScopeEnding
            if storeOnlyChild {
                runtime.revokeAll(involving: childOwner, origin: .mcpClient(owner), fileRemoved: false)
                firstEnding = .init(reason: .sessionDeleted, at: clock, actorSessionID: owner, originatingSessionID: childOwner, deletionOrigin: .mcpClient, fileRemoved: false)
            } else {
                _ = try runtime.release(scopeID: child.id, caller: .agentSession(childOwner)).get()
                firstEnding = try XCTUnwrap(runtime.ending(for: child.id))
                XCTAssertEqual(firstEnding.reason, .granteeReleased)
            }
            XCTAssertEqual(runtime.lastPersistenceOutcome, .writeFailed)
            XCTAssertNotEqual(runtime.continuityState, "saved")
            // No suspension between the failed child save and the ancestor's save attempt:
            // the queued retry cannot run first and accidentally hide the ordering defect.
            gate.setFailing(failAncestorSave)
            clock = clock.addingTimeInterval(1)
            if deleteAncestor { runtime.revokeAll(involving: owner, origin: .userUI, fileRemoved: true) }
            else { runtime.revoke(scopeID: parent.id) }
            let parentEnding = try XCTUnwrap(runtime.ending(for: parent.id))
            XCTAssertNotEqual(parentEnding, firstEnding)
            if failAncestorSave { XCTAssertEqual(runtime.lastPersistenceOutcome, .writeFailed) }
            gate.setFailing(false)
            await runtime.flushPersistence()
            XCTAssertEqual(runtime.continuityState, "saved")
            runtime.freezeForTermination()
            let restored = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { clock }, notifyCatalogChanged: { _ in })
            await restored.bootstrap(store: store())
            XCTAssertEqual(restored.ending(for: child.id), firstEnding, "A later ancestor transaction must retain the child's earlier reason, clock, and actor")
            XCTAssertEqual(restored.ending(for: parent.id), parentEnding)
            XCTAssertFalse(restored.hasLiveScope(grantedTo: owner))
            XCTAssertFalse(restored.hasLiveScope(grantedTo: childOwner))
            XCTAssertNil(restored.record(id: child.id))
            restored.freezeForTermination()
        }
    }

    func testExpiryDuringShutdownIsRecordedOnRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func store() -> DelegationScopeStore {
            .init(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
        }
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { clock }, notifyCatalogChanged: { _ in })
        await runtime.bootstrap(store: store())
        let caller = UUID()
        let request = try runtime.requestScope(requesterSessionID: caller, requesterTabID: nil, kind: .tree(rootSessionID: caller), capabilities: [.observe, .spawn], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: nil).get()
        let scope = try runtime.approve(requestID: request.id).get()
        await runtime.flushPersistence()
        runtime.freezeForTermination()
        clock = clock.addingTimeInterval(61)
        var recoveryReads = 0
        let restored = DelegationScopeRuntime(persistenceMode: .requiresStore, now: {
            recoveryReads += 1
            // The grant crosses its deadline while recovery offers are read across an await.
            return recoveryReads == 1 ? clock.addingTimeInterval(-2) : clock
        }, notifyCatalogChanged: { _ in })
        await restored.bootstrap(store: store())
        await restored.flushPersistence()
        XCTAssertEqual(restored.ending(for: scope.id)?.reason, .expired)
        XCTAssertEqual(restored.statusRecord(id: scope.id)?.state, .expired)
        XCTAssertNil(restored.record(id: scope.id))
        XCTAssertFalse(restored.hasLiveScope(grantedTo: caller))
        let reopened = store()
        _ = reopened.loadForLaunch()
        XCTAssertEqual(reopened.endedScopes[scope.id]?.ending.reason, .expired)
        restored.freezeForTermination()
    }

    func testExpiryCascadeIsStableForBothSavedIdentityOrders() async throws {
        let ids = try [XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")), XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))]
        for reversed in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            func store() -> DelegationScopeStore {
                .init(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
            }
            let date = Date(timeIntervalSince1970: 2_000_000)
            let parentID = ids[reversed ? 1 : 0], childID = ids[reversed ? 0 : 1]
            let owner = UUID(), childOwner = UUID()
            let parent = DomainDelegationScopeGrant(id: parentID, granteeSessionID: owner, kind: .tree(rootSessionID: owner), capabilities: [.observe, .spawn], guardrails: .init(expiresAt: date), origin: .user, grantedAt: date.addingTimeInterval(-60))
            let child = DomainDelegationScopeGrant(id: childID, granteeSessionID: childOwner, kind: .tree(rootSessionID: childOwner), capabilities: [.observe], guardrails: parent.guardrails, origin: .attenuatedFrom(scopeID: parentID), grantedAt: parent.grantedAt)
            XCTAssertEqual(store().record(operationID: UUID(), grants: [parent, child], revoked: []), .applied)
            let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { date }, notifyCatalogChanged: { _ in })
            await runtime.bootstrap(store: store())
            await runtime.flushPersistence()
            let evidence = try XCTUnwrap(runtime.ending(for: childID))
            XCTAssertEqual(evidence.originatingScopeID, parentID)
            let reopened = store()
            _ = reopened.loadForLaunch()
            XCTAssertEqual(reopened.endedScopes[childID]?.ending, evidence)
            XCTAssertEqual(reopened.endedScopes[parentID]?.ending, evidence)
            runtime.freezeForTermination()
        }
    }

    func testDisablingFullAccessRecordsItsOwnEndingReason() throws {
        var enabled = true
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        runtime.isGlobalAutoApproveEnabled = { enabled }
        let owner = UUID()
        let request = try runtime.requestScope(requesterSessionID: owner, requesterTabID: nil, kind: .tree(rootSessionID: owner), capabilities: [.observe], guardrails: .init(), reason: nil, idempotencyKey: nil).get()
        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: request.id))
        let scope = try XCTUnwrap(runtime.liveScopes(grantedTo: owner).first)
        let childOwner = UUID()
        let child = try runtime.attenuate(parentScopeID: scope.id, presentedGeneration: scope.generation, caller: .agentSession(owner), newGranteeSessionID: childOwner, newGranteeMemberships: [.init(scopeID: scope.id, targetSessionID: childOwner, basis: .allSessions)], capabilities: [.observe], guardrails: .init()).get()
        enabled = false
        runtime.reconcileGlobalAutoApprove(userInitiated: true)
        XCTAssertEqual(runtime.ending(for: scope.id)?.reason, .fullAccessDisabled)
        XCTAssertEqual(runtime.ending(for: child.id)?.originatingScopeID, scope.id)
        XCTAssertEqual(runtime.ending(for: child.id)?.reason, .fullAccessDisabled)
        XCTAssertFalse(runtime.hasLiveScope(grantedTo: owner))
        XCTAssertFalse(runtime.hasLiveScope(grantedTo: childOwner))
        runtime.freezeForTermination()
    }

    func testDeletionCommitCarriesOriginRemovalAndOneClockToStoreOnlyScopes() async throws {
        for origin: AgentSessionDeletionOrigin in [.unknown, .mcpClient(), .mcpClient(UUID()), .userUI, .agentCleanup(UUID()), .automaticDiscard, .composeTabBatch] {
            for removed in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = DelegationScopeStore(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
                let date = Date(timeIntervalSince1970: 2_000_000), owner = UUID(), id = UUID()
                let grant = DomainDelegationScopeGrant(id: id, granteeSessionID: owner, kind: .tree(rootSessionID: owner), capabilities: [.observe], guardrails: .init(), origin: .user, grantedAt: date)
                // Deliberately do not load this grant into runtime: the deletion mutation must
                // terminalize scopes owned by another writer with the very same evidence.
                let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { date }, notifyCatalogChanged: { _ in })
                await runtime.bootstrap(store: store)
                XCTAssertEqual(store.record(operationID: UUID(), grants: [grant], revoked: []), .applied)
                let registry = AgentSessionDeletionRegistry.test_instance(scopePersistenceMode: .ephemeral)
                var committedOrigin: AgentSessionDeletionOrigin?
                registry.commitObserver = { sessionID, observedOrigin, fileRemoved in
                    committedOrigin = observedOrigin
                    runtime.revokeAll(involving: sessionID, origin: observedOrigin, fileRemoved: fileRemoved)
                }
                let token = try registry.beginDurableDeletion(sessionID: owner, origin: origin)
                await registry.didCommitDurableDeletion(token, fileRemoved: removed)
                await runtime.flushPersistence()
                _ = store.loadForLaunch()
                let ending = try XCTUnwrap(store.endedScopes[id]?.ending)
                XCTAssertEqual(committedOrigin, origin)
                XCTAssertEqual(ending.at, date)
                XCTAssertEqual(ending.deletionOrigin, origin.kind)
                XCTAssertEqual(ending.actorSessionID, origin.actorSessionID)
                XCTAssertEqual(ending.fileRemoved, removed)
                XCTAssertNil(ending.originatingScopeID, "Store must not fabricate an origin different from runtime")
                let record = DomainDelegationScopeRecord(grant: grant, generation: 0, state: .revoked)
                let status = SessionAdminMCPToolService.scopeValue(record, now: date, ending: ending).objectValue?["ending"]?.objectValue
                XCTAssertEqual(status?["file_removed"], .bool(removed))
                XCTAssertEqual(status?["initiator"], .string(ending.initiator))
                if origin.actorSessionID != owner { XCTAssertNil(status?["actor_session_id"]) }
                runtime.freezeForTermination()
            }
        }
    }

    func testHistoryOutputIsBoundedOrderedAndGranteeIndexedWithMissingDates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DelegationScopeStore(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
        let owner = UUID(), outsider = UUID(), date = Date(timeIntervalSince1970: 2_000_000)
        var expected: [UUID] = []
        for i in 0 ..< 20 {
            let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i)))
            let grant = DomainDelegationScopeGrant(id: id, granteeSessionID: owner, kind: .tree(rootSessionID: owner), capabilities: [.observe], guardrails: .init(), origin: .user, grantedAt: date)
            let ending = try OverseerEndedScope(ending: .init(reason: .userRevoked, at: i < 14 ? date.addingTimeInterval(Double(i)) : nil), originalPayload: JSONEncoder().encode(grant))
            XCTAssertEqual(store.record(operationID: UUID(), grants: [], revoked: [id], endings: [id: ending]), .applied)
            expected.append(id)
        }
        expected = Array(expected.prefix(14).reversed()) + Array(expected.suffix(6))
        let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { date }, notifyCatalogChanged: { _ in })
        await runtime.bootstrap(store: store)
        XCTAssertEqual(runtime.recentScopeEndings.map(\.id), Array(expected.prefix(16)))
        XCTAssertEqual(runtime.scopes(grantedTo: owner).map(\.id), Array(expected.prefix(16)))
        XCTAssertTrue(runtime.scopes(grantedTo: outsider).isEmpty)
        XCTAssertEqual(runtime.recentScopeEndings.map(\.id), Array(expected.prefix(16)), "Cached projection remains stable")
        for id in expected {
            XCTAssertNil(runtime.record(id: id))
        }
        runtime.freezeForTermination()
    }

    func testMalformedEvidenceStillPersistsDenyAndFutureReasonPreservesOriginalPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DelegationScopeStore(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
        let id = UUID(), owner = UUID(), date = Date(timeIntervalSince1970: 2_000_000)
        let grant = DomainDelegationScopeGrant(id: id, granteeSessionID: owner, kind: .tree(rootSessionID: owner), capabilities: [.observe], guardrails: .init(), origin: .user, grantedAt: date)
        XCTAssertEqual(store.record(operationID: UUID(), grants: [grant], revoked: []), .applied)
        XCTAssertEqual(store.record(operationID: UUID(), grants: [], revoked: [id], endings: [id: .init(ending: .init(reason: .userRevoked), originalPayload: Data("malformed".utf8))]), .applied)
        _ = store.loadForLaunch()
        XCTAssertTrue(store.currentGrants.isEmpty)
        XCTAssertEqual(store.endedScopes[id]?.ending.reason, .historicalUnknown)
        let original = try JSONEncoder().encode(grant)
        let envelope = OverseerEndedScope(ending: .init(reason: .userRevoked, at: date), originalPayload: original)
        let bytes = try JSONEncoder().encode(envelope)
        let future = try XCTUnwrap(String(data: bytes, encoding: .utf8)).replacingOccurrences(of: "user_revoked", with: "future_reason")
        let decoded = try JSONDecoder().decode(OverseerEndedScope.self, from: Data(future.utf8))
        XCTAssertEqual(decoded.ending.reason, .historicalUnknown)
        XCTAssertEqual(decoded.originalPayload, original)
    }

    func testTerminalRetryRetainsFirstEvidenceAndHistoricalUnknownIsNotAttributed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DelegationScopeStore(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
        let id = UUID(), owner = UUID(), operation = UUID()
        let date = Date(timeIntervalSince1970: 2_000_000)
        let grant = DomainDelegationScopeGrant(id: id, granteeSessionID: owner, kind: .tree(rootSessionID: owner), capabilities: [.observe, .spawn, .control, .organize], guardrails: .init(), origin: .user, grantedAt: date)
        let ending = OverseerScopeEnding(reason: .userRevoked, at: date, originatingScopeID: id)
        let ended = try OverseerEndedScope(ending: ending, originalPayload: JSONEncoder().encode(grant))
        for _ in 0 ..< 10 {
            XCTAssertEqual(store.record(operationID: operation, grants: [], revoked: [id], endings: [id: ended]), .applied)
        }
        XCTAssertTrue(store.lastReceipt?.replayed == true)
        XCTAssertEqual(store.replace(with: [], revokedScopeIDs: [id]), .applied)
        _ = store.loadForLaunch()
        XCTAssertEqual(store.endedScopes[id]?.ending, ending)
        let record = DomainDelegationScopeRecord(grant: grant, generation: 0, state: .revoked)
        let status = SessionAdminMCPToolService.scopeValue(record, now: date, ending: .init(reason: .historicalUnknown))
        XCTAssertEqual(status.objectValue?["ending"]?.objectValue?["initiator"], .string("unknown"))
        XCTAssertNil(status.objectValue?["ending"]?.objectValue?["at"])
    }
}
