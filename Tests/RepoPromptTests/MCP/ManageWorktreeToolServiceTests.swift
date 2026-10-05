import Foundation
import MCP
import os
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptVCS
import XCTest

@MainActor
final class ManageWorktreeToolServiceTests: XCTestCase {
    func testWorktreeManageCapabilityRoutingAndRemovedAliasPolicy() {
        XCTAssertEqual(MCPWindowToolName.manageWorktree, "manage_worktree")
        XCTAssertTrue(MCPToolCapabilities.capabilities(for: MCPWindowToolName.manageWorktree).contains(.worktreeManage))
        XCTAssertFalse(MCPToolCapabilities.capabilities(for: MCPWindowToolName.manageWorktree).contains(.gitRead))
        XCTAssertTrue(MCPToolCapabilities.toolNames(for: [.worktreeManage]).contains(MCPWindowToolName.manageWorktree))
        XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains(MCPWindowToolName.manageWorktree))
        XCTAssertFalse(MCPAppToolGroup.orderedToolNames.contains("merge_worktree"))
        XCTAssertTrue(MCPToolCapabilities.capabilities(for: "merge_worktree").isEmpty)
    }

    func testManageWorktreeReplyEncodesSnakeCaseVisualBindingFields() throws {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "bind",
            repository: .init(
                repositoryID: "gitrepo_123",
                repoKey: "repo-123",
                displayName: "Repo",
                rootPath: "/tmp/repo",
                commonGitDir: "/tmp/repo/.git",
                mainWorktreeRoot: "/tmp/repo"
            ),
            worktree: Self.worktreeDTO(),
            binding: Self.bindingDTO(id: "new", worktreeID: "wt_new"),
            previousBinding: Self.bindingDTO(id: "old", worktreeID: "wt_old")
        )

        let value = try Self.value(dto)
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertNotNil(object["previous_binding"])
        XCTAssertNil(object["previousBinding"])

        let repository = try XCTUnwrap(object["repository"]?.objectValue)
        XCTAssertEqual(repository["repository_id"]?.stringValue, "gitrepo_123")
        XCTAssertEqual(repository["common_git_dir"]?.stringValue, "/tmp/repo/.git")
        XCTAssertEqual(repository["main_worktree_root"]?.stringValue, "/tmp/repo")

        let worktree = try XCTUnwrap(object["worktree"]?.objectValue)
        XCTAssertEqual(worktree["worktree_id"]?.stringValue, "wt_123")
        XCTAssertEqual(worktree["is_main"]?.boolValue, false)
        XCTAssertEqual(worktree["is_current"]?.boolValue, true)
        XCTAssertEqual(worktree["is_detached"]?.boolValue, false)
        let visual = try XCTUnwrap(worktree["visual"]?.objectValue)
        XCTAssertEqual(visual["color_hex"]?.stringValue, "#2563EB")
        XCTAssertEqual(visual["icon_name"]?.stringValue, "circle.fill")
        XCTAssertEqual(visual["marker_style"]?.stringValue, "ring")

        let previous = try XCTUnwrap(object["previous_binding"]?.objectValue)
        XCTAssertEqual(previous["worktree_id"]?.stringValue, "wt_old")
        XCTAssertEqual(previous["logical_root_path"]?.stringValue, "/tmp/repo")
        XCTAssertEqual(previous["visual_color_hex"]?.stringValue, "#7C3AED")
    }

    private static func worktreeDTO() -> ToolResultDTOs.ManageWorktreeReplyDTO.WorktreeDTO {
        .init(
            worktreeID: "wt_123",
            specifier: "@id:wt_123",
            path: "/tmp/repo-wt",
            gitDir: "/tmp/repo/.git/worktrees/repo-wt",
            name: "repo-wt",
            branch: "feature/demo",
            head: "abcdef0",
            isMain: false,
            isCurrent: true,
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil,
            visual: .init(label: "demo", colorHex: "#2563EB", iconName: "circle.fill", markerStyle: "ring"),
            status: .init(staged: 1, modified: 2, untracked: 3, isDirty: true)
        )
    }

    private static func bindingDTO(id: String, worktreeID: String) -> ToolResultDTOs.ManageWorktreeReplyDTO.BindingDTO {
        .init(
            id: id,
            repositoryID: "gitrepo_123",
            repoKey: "repo-123",
            logicalRootPath: "/tmp/repo",
            logicalRootName: "Repo",
            worktreeID: worktreeID,
            worktreeRootPath: "/tmp/repo-wt",
            worktreeName: "repo-wt",
            branch: "feature/demo",
            head: "abcdef0",
            visualLabel: "demo",
            visualColorHex: "#7C3AED",
            boundAt: "2026-05-22T00:00:00Z",
            source: "manage_worktree.bind"
        )
    }

    private static func value(_ dto: some Encodable) throws -> Value {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(dto)
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

// Provider-boundary regressions use the real protected mutation and window tool path.
#if DEBUG
    @MainActor
    final class WorktreeBindingProviderRegressionTests: XCTestCase {
        func testSelectingAlreadyLogicalCheckoutSettlesApplied() async throws {
            try await withProvider { fixture in
                let reply = try await fixture.call([
                    "op": .string("select"), "worktree": .string("@main")
                ], includeWorktree: false)
                XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
                XCTAssertNil(reply.objectValue?["binding"]?.objectValue)
                let journal = try await fixture.driver.fixture.runtime.mutationJournal.snapshot()
                XCTAssertEqual(journal.recordSnapshots.last?.status, .applied)
            }
        }

        func testRepeatedUnbindSettlesAppliedWithoutRetiringActiveProvider() async throws {
            try await withProvider { fixture in
                _ = try await fixture.call(["op": .string("bind")])
                _ = try await fixture.call(["op": .string("unbind")], includeWorktree: false)
                let native = MonitorFakeNativeController()
                fixture.session.claudeController = native
                fixture.session.runState = .running
                defer {
                    fixture.session.runState = .idle
                    fixture.session.claudeController = nil
                }
                let reply = try await fixture.call(["op": .string("unbind")], includeWorktree: false)
                XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
                XCTAssertNotNil(reply.objectValue?["warning"]?.stringValue)
                XCTAssertEqual(fixture.session.runState, .running)
                let shutdowns = await native.shutdownCount
                XCTAssertEqual(shutdowns, 0)
                let journal = try await fixture.driver.fixture.runtime.mutationJournal.snapshot()
                XCTAssertEqual(journal.recordSnapshots.last?.status, .applied)
            }
        }

        func testIconAndMarkerOnlyRebindPersistsWithoutRetiringActiveProvider() async throws {
            try await withProvider { fixture in
                _ = try await fixture.call(["op": .string("bind")])
                let original = fixture.session.worktreeBindings
                let native = MonitorFakeNativeController()
                fixture.session.claudeController = native
                fixture.session.runState = .running
                let reply = try await fixture.call([
                    "op": .string("bind"), "icon_name": .string("star"), "marker_style": .string("capsule")
                ])
                let persisted = try XCTUnwrap(GlobalSettingsStore.shared.worktreeVisualIdentity(
                    repositoryID: fixture.identity.repository.repositoryID, worktreeID: fixture.identity.worktreeID
                ))
                XCTAssertEqual(persisted.iconName, "star")
                XCTAssertEqual(persisted.markerStyle, .capsule)
                XCTAssertEqual(reply.objectValue?["worktree"]?.objectValue?["visual"]?.objectValue?["icon_name"]?.stringValue, "star")
                XCTAssertEqual(fixture.session.worktreeBindings, original)
                XCTAssertEqual(fixture.session.runState, .running)
                let shutdowns = await native.shutdownCount
                XCTAssertEqual(shutdowns, 0)
                fixture.session.runState = .idle
                fixture.session.claudeController = nil
            }
        }

        func testPlainUnbindMatchesCanonicalLogicalRootAlias() async throws {
            try await withProvider { fixture in
                _ = try await fixture.call(["op": .string("bind")])
                let old = try XCTUnwrap(fixture.session.worktreeBindings.first)
                let alias = fixture.driver.fixture.base.appendingPathComponent("logical-alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.logical)
                fixture.session.worktreeBindings = [.init(
                    id: old.id, repositoryID: old.repositoryID, repoKey: old.repoKey,
                    logicalRootPath: alias.path, logicalRootName: old.logicalRootName,
                    worktreeID: old.worktreeID, worktreeRootPath: old.worktreeRootPath,
                    commonGitDir: old.commonGitDir, isMainWorktree: old.isMainWorktree, source: old.source
                )]
                let reply = try await fixture.call(["op": .string("unbind")], includeWorktree: false)
                XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
                XCTAssertNil(reply.objectValue?["warning"]?.stringValue)
                XCTAssertEqual(reply.objectValue?["binding"]?.objectValue?["id"]?.stringValue, old.id)
            }
        }

        func testRequiredSaveFailureSettlesIndeterminateWithBindingActuallyChanged() async throws {
            try await withProvider { fixture in
                struct SaveFailure: Error {}
                fixture.driver.window.agentModeViewModel.test_setAgentSessionSaver { _, _, _ in throw SaveFailure() }
                let settlements = OSAllocatedUnfairLock<[DomainProtectedMutationSettlement]>(initialState: [])
                do {
                    _ = try await MCPDomainProtectedMutationSettlementContext.$observer.withValue({ settlement in
                        settlements.withLock { $0.append(settlement) }
                    }) { try await fixture.call(["op": .string("bind")]) }
                    XCTFail("Required save failure must not be reported applied")
                } catch {
                    guard case .partialSuccessAfterCommit = error as? DomainProtectedMutationError else {
                        return XCTFail("Expected genuine postcommit indeterminate, got \(error)")
                    }
                }
                XCTAssertEqual(fixture.session.worktreeBindings.first?.worktreeID, fixture.identity.worktreeID)
                XCTAssertEqual(settlements.withLock { $0.last?.state }, .indeterminateAfterCommit)
                let journal = try await fixture.driver.fixture.runtime.mutationJournal.snapshot()
                XCTAssertEqual(journal.recordSnapshots.last?.status, .indeterminateAfterCommit)
            }
        }

        @MainActor
        private struct Fixture {
            let driver: ContextBuilderMultiRootDiscoveryDriver
            let logical: URL
            let physical: URL
            let identity: GitWorktreeIdentitySnapshot
            let session: AgentModeViewModel.TabSession
            let sessionID: UUID
            let binding: MCPDomainToolBinding
            let security: DomainToolInvocationSecurityContext

            func call(_ extra: [String: Value], includeWorktree: Bool = true) async throws -> Value {
                var args = extra
                args["repo_root"] = .string(logical.path)
                args["session_id"] = .string(sessionID.uuidString)
                if includeWorktree { args["worktree"] = .string(physical.path) }
                let metadata = MCPRequestMetadata(connectionID: nil, clientName: nil, windowID: driver.window.windowID)
                let invocation = ToolInvocationContext.trustedLocal(toolName: "manage_worktree", metadata: metadata)
                let requestSecurity = DomainToolInvocationSecurityContext(
                    principal: security.principal,
                    connectionID: security.connectionID, connectionGeneration: security.connectionGeneration,
                    invocationID: UUID(), runtimeID: security.runtimeID, runtimeGeneration: security.runtimeGeneration,
                    authorizedCanonicalRoots: security.authorizedCanonicalRoots,
                    hasAuthoritativeRoutingContext: true, ephemeralGrantedToolNames: ["manage_worktree"]
                )
                return try await MCPDomainInvocationSecurityContext.$current.withValue(requestSecurity) {
                    try await MCPInvocationContextBridge.withInvocation(invocation) { try await binding(args) }
                }
            }
        }

        private func withProvider(_ body: @escaping @MainActor (Fixture) async throws -> Void) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                let git = try ReviewGitRepositoryFixture(parentDirectory: driver.fixture.base)
                defer { git.cleanup() }
                let logical = URL(fileURLWithPath: driver.fixture.rootPaths[0])
                try git.initializeRepository(at: logical)
                _ = try git.runGit(["add", "README.md"], at: logical)
                try git.commit("Fixture", at: logical)
                let physical = git.sandbox.appendingPathComponent("physical")
                _ = try git.runGit(["worktree", "add", "--detach", physical.path, "HEAD"], at: logical)
                let identity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: physical))
                let vm = driver.window.agentModeViewModel
                let session = AgentModeViewModel.TabSession(tabID: driver.tabID)
                session.hasLoadedPersistedState = true
                let sessionID = UUID()
                vm.test_installLiveSession(session)
                _ = vm.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
                vm.test_setAgentSessionSaver { _, _, _ in git.sandbox.appendingPathComponent("session.json") }
                let tools = await driver.window.mcpServer.windowMCPTools
                let tool = try XCTUnwrap(tools.first { $0.name == "manage_worktree" })
                let runtime = try XCTUnwrap(driver.fixture.runtime)
                let security = DomainToolInvocationSecurityContext(
                    principal: DomainClientPrincipal(
                        principalID: UUID(),
                        stableKey: "worktree-provider-test",
                        displayName: "test",
                        kind: .runScoped,
                        assurance: .hostLaunchToken,
                        processID: 42,
                        runID: UUID(),
                        provider: "test"
                    ),
                    connectionID: UUID(), connectionGeneration: 1, invocationID: UUID(),
                    runtimeID: runtime.identity.runtimeID, runtimeGeneration: runtime.identity.lifecycleGeneration,
                    authorizedCanonicalRoots: [logical.resolvingSymlinksInPath().path, physical.resolvingSymlinksInPath().path],
                    hasAuthoritativeRoutingContext: true, ephemeralGrantedToolNames: ["manage_worktree"]
                )
                try await body(Fixture(
                    driver: driver,
                    logical: logical,
                    physical: physical,
                    identity: identity,
                    session: session,
                    sessionID: sessionID,
                    binding: runtime.protectedMutationProvider.protectedBinding(tool.domainBinding()),
                    security: security
                ))
            }
        }
    }
#endif
