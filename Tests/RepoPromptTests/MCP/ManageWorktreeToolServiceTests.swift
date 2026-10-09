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

    // MARK: - List pagination (#1091)

    func testListPaginationWalksSixHundredWorktreesExactlyOnce() {
        let total = 600
        var visited: [Int] = []
        var offset: Int?
        var pageCount = 0
        repeat {
            let page = MCPWorktreeListPagination.page(totalCount: total, limit: nil, offset: offset)
            XCTAssertLessThanOrEqual(page.range.count, MCPWorktreeListPagination.defaultLimit)
            XCTAssertEqual(page.totalCount, total)
            visited.append(contentsOf: page.range)
            offset = page.nextOffset
            XCTAssertEqual(page.hasMore, page.nextOffset != nil)
            pageCount += 1
        } while offset != nil && pageCount < 100

        XCTAssertEqual(pageCount, 6)
        XCTAssertEqual(visited, Array(0 ..< total))
    }

    func testListPaginationClampsLimitAndOffset() {
        let minimum = MCPWorktreeListPagination.page(totalCount: 600, limit: 0, offset: -5)
        XCTAssertEqual(minimum.range, 0 ..< 1)
        XCTAssertEqual(minimum.nextOffset, 1)

        let maximum = MCPWorktreeListPagination.page(totalCount: 600, limit: 10000, offset: 550)
        XCTAssertEqual(maximum.limit, MCPWorktreeListPagination.maxLimit)
        XCTAssertEqual(maximum.range, 550 ..< 600)
        XCTAssertFalse(maximum.hasMore)
        XCTAssertNil(maximum.nextOffset)

        let pastEnd = MCPWorktreeListPagination.page(totalCount: 600, limit: nil, offset: 650)
        XCTAssertTrue(pastEnd.range.isEmpty)
        XCTAssertFalse(pastEnd.hasMore)

        let small = MCPWorktreeListPagination.page(totalCount: 3, limit: nil, offset: nil)
        XCTAssertEqual(small.range, 0 ..< 3)
        XCTAssertNil(small.nextOffset)
    }

    func testListAcceptsPaginationArgumentsOnlyForList() {
        let listKeys = MCPWorktreeToolProvider.validArgumentKeys(for: .list)
        XCTAssertTrue(listKeys.isSuperset(of: ["limit", "offset"]))
        XCTAssertFalse(MCPWorktreeToolProvider.validArgumentKeys(for: .show).contains("limit"))
        XCTAssertFalse(MCPWorktreeToolProvider.validArgumentKeys(for: .show).contains("offset"))
    }

    func testCanonicalManageWorktreeSchemaAdvertisesListPagination() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.manageWorktree))
        let schema = try XCTUnwrap(definition.inputSchema.objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        XCTAssertEqual(properties["limit"]?.objectValue?["type"], .string("integer"))
        XCTAssertEqual(properties["offset"]?.objectValue?["type"], .string("integer"))
        XCTAssertTrue(definition.description.contains(MCPWorktreeListPagination.outputDescriptionLine))
    }

    func testPagedListReplyEncodesPaginationFieldsAndStaysBounded() throws {
        let total = 600
        let allDTOs = (0 ..< total).map { Self.worktreeDTO(index: $0) }
        let page = MCPWorktreeListPagination.page(totalCount: total, limit: nil, offset: nil)
        let paged = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "list",
            worktrees: Array(allDTOs[page.range]),
            totalCount: page.totalCount,
            truncated: page.hasMore ? true : nil,
            nextOffset: page.nextOffset
        )
        let unpaged = ToolResultDTOs.ManageWorktreeReplyDTO(op: "list", worktrees: allDTOs)

        let object = try XCTUnwrap(Self.value(paged).objectValue)
        XCTAssertEqual(object["worktrees"]?.arrayValue?.count, MCPWorktreeListPagination.defaultLimit)
        XCTAssertEqual(object["total_count"]?.intValue, total)
        XCTAssertEqual(object["truncated"]?.boolValue, true)
        XCTAssertEqual(object["next_offset"]?.intValue, MCPWorktreeListPagination.defaultLimit)
        XCTAssertNil(object["totalCount"])
        XCTAssertNil(object["nextOffset"])

        let pagedBytes = try JSONEncoder().encode(paged).count
        let unpagedBytes = try JSONEncoder().encode(unpaged).count
        XCTAssertLessThan(pagedBytes * 5, unpagedBytes)

        let text = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: [:], value: Self.value(paged)))
        XCTAssertTrue(text.contains("### Worktrees (\(MCPWorktreeListPagination.defaultLimit) of \(total))"))
    }

    func testUnpagedListReplyOmitsContinuationFields() throws {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "list",
            worktrees: [Self.worktreeDTO()],
            totalCount: 1
        )

        let object = try XCTUnwrap(Self.value(dto).objectValue)
        XCTAssertEqual(object["total_count"]?.intValue, 1)
        XCTAssertNil(object["truncated"])
        XCTAssertNil(object["next_offset"])

        let text = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: [:], value: Self.value(dto)))
        XCTAssertTrue(text.contains("### Worktrees (1)"))
    }

    private static func worktreeDTO(index: Int) -> ToolResultDTOs.ManageWorktreeReplyDTO.WorktreeDTO {
        .init(
            worktreeID: "wt_\(index)",
            specifier: "@id:wt_\(index)",
            path: "/tmp/repo-worktrees/wt-\(index)",
            gitDir: "/tmp/repo/.git/worktrees/wt-\(index)",
            name: "wt-\(index)",
            branch: "feature/wt-\(index)",
            head: "abcdef0",
            isMain: index == 0,
            isCurrent: false,
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil,
            visual: nil,
            status: nil
        )
    }

    private static func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
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

        func testProjectedSameWorktreeIDVisualBindPreservesActiveExecutionAndPersists() async throws {
            try await withProvider { fixture in
                _ = try await fixture.call([
                    "op": .string("bind"), "label": .string("Session 2026-10-06"), "color": .string("#DB2777")
                ])
                let original = try XCTUnwrap(fixture.session.worktreeBindings.first)
                let native = MonitorFakeNativeController()
                await native.setTurnInFlight(true)
                fixture.session.claudeController = native
                fixture.session.runState = .running
                defer {
                    fixture.session.runState = .idle
                    fixture.session.claudeController = nil
                }
                var savedBindings: [AgentSessionWorktreeBinding]?
                fixture.driver.window.agentModeViewModel.test_setAgentSessionSaver { saved, _, _ in
                    savedBindings = saved.worktreeBindings
                    return fixture.physical.appendingPathComponent("session.json")
                }
                let reply = try await fixture.call([
                    "op": .string("bind"), "worktree_id": .string(original.worktreeID),
                    "label": .string(original.visualLabel ?? "Session"), "color": .string("#2563EB")
                ], includeWorktree: false, projectSession: true)
                let applied = try XCTUnwrap(fixture.session.worktreeBindings.first)
                XCTAssertEqual(applied.id, original.id)
                XCTAssertEqual(applied.boundAt, original.boundAt)
                XCTAssertEqual(applied.logicalRootPath, original.logicalRootPath)
                XCTAssertEqual(applied.worktreeRootPath, original.worktreeRootPath)
                XCTAssertEqual(applied.worktreeID, original.worktreeID)
                XCTAssertEqual(applied.visualColorHex, "#2563EB")
                XCTAssertEqual(savedBindings, [applied])
                XCTAssertEqual(reply.objectValue?["binding"]?.objectValue?["logical_root_path"]?.stringValue, fixture.logical.path)
                XCTAssertEqual(reply.objectValue?["binding"]?.objectValue?["worktree_id"]?.stringValue, original.worktreeID)
                let persisted = try XCTUnwrap(GlobalSettingsStore.shared.worktreeVisualIdentity(
                    repositoryID: original.repositoryID, worktreeID: original.worktreeID
                ))
                XCTAssertEqual(persisted.colorHex, "#2563EB")
                XCTAssertEqual(fixture.session.runState, .running)
                XCTAssertTrue(fixture.session.claudeController === native)
                let shutdowns = await native.shutdownCount
                XCTAssertEqual(shutdowns, 0)
            }
        }

        func testProjectedLogicalCheckoutSelectionRemovesItsBinding() async throws {
            try await withProvider { fixture in
                _ = try await fixture.call(["op": .string("bind")])
                let original = try XCTUnwrap(fixture.session.worktreeBindings.first)
                let reply = try await fixture.call([
                    "op": .string("select"), "worktree": .string("@main")
                ], includeWorktree: false, projectSession: true)
                XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
                XCTAssertNil(reply.objectValue?["binding"]?.objectValue)
                XCTAssertEqual(reply.objectValue?["previous_binding"]?.objectValue?["id"]?.stringValue, original.id)
            }
        }

        func testProjectedActiveDestinationChangeRejectsWithoutMutation() async throws {
            try await withProvider { fixture in
                _ = try await fixture.call(["op": .string("bind")])
                let original = fixture.session.worktreeBindings
                let native = MonitorFakeNativeController()
                await native.setTurnInFlight(true)
                fixture.session.claudeController = native
                fixture.session.runState = .running
                defer {
                    fixture.session.runState = .idle
                    fixture.session.claudeController = nil
                }
                do {
                    _ = try await fixture.call([
                        "op": .string("bind"), "worktree": .string("@main")
                    ], includeWorktree: false, projectSession: true)
                    XCTFail("Projected routing must not permit an active execution change")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("active Agent run"), error.localizedDescription)
                }
                XCTAssertEqual(fixture.session.worktreeBindings, original)
                XCTAssertTrue(fixture.session.claudeController === native)
                XCTAssertEqual(fixture.session.runState, .running)
                let shutdowns = await native.shutdownCount
                XCTAssertEqual(shutdowns, 0)
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

        // MARK: - List paging through the provider boundary (#1091)

        func testListPagesNonPrunableWorktreesThroughProvider() async throws {
            try await withProvider { fixture in
                let extras = try fixture.addWorktrees(["page-a", "page-b", "page-c"])
                let gone = try XCTUnwrap(fixture.addWorktrees(["page-gone"]).first)
                try FileManager.default.removeItem(at: gone)
                let expected = Set(([fixture.logical, fixture.physical] + extras).map(Self.canonicalPath))

                var seen: [String] = []
                var offset = 0
                var pages = 0
                while pages < 10 {
                    let reply = try XCTUnwrap(try await fixture.listCall([
                        "limit": .int(2), "offset": .int(offset)
                    ]).objectValue)
                    pages += 1
                    XCTAssertEqual(reply["total_count"]?.intValue, expected.count)
                    XCTAssertTrue(reply["warning"]?.stringValue?.contains("Omitted 1 stale (prunable)") == true)
                    let worktrees = try XCTUnwrap(reply["worktrees"]?.arrayValue)
                    XCTAssertLessThanOrEqual(worktrees.count, 2)
                    seen += worktrees.compactMap { $0.objectValue?["path"]?.stringValue }.map {
                        Self.canonicalPath(URL(fileURLWithPath: $0))
                    }
                    guard let next = reply["next_offset"]?.intValue else {
                        XCTAssertNil(reply["truncated"])
                        break
                    }
                    XCTAssertEqual(reply["truncated"]?.boolValue, true)
                    XCTAssertEqual(next, offset + worktrees.count)
                    offset = next
                }

                XCTAssertEqual(pages, 3)
                XCTAssertEqual(seen.count, expected.count, "pages must not duplicate worktrees")
                XCTAssertEqual(Set(seen), expected)
                XCTAssertFalse(seen.contains(Self.canonicalPath(gone)))
            }
        }

        func testPersistVisualsListOnlyPersistsReturnedPage() async throws {
            try await withProvider { fixture in
                let extras = try fixture.addWorktrees(["visual-a", "visual-b"])
                let roots = [fixture.logical, fixture.physical] + extras
                let identities = try roots.map { try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: $0)) }
                func persisted(_ identity: GitWorktreeIdentitySnapshot) -> Bool {
                    GlobalSettingsStore.shared.worktreeVisualIdentity(
                        repositoryID: identity.repository.repositoryID, worktreeID: identity.worktreeID
                    ) != nil
                }
                XCTAssertFalse(identities.contains(where: persisted))

                let reply = try XCTUnwrap(try await fixture.listCall([
                    "limit": .int(1), "offset": .int(1), "persist_visuals": .bool(true)
                ]).objectValue)
                let page = try XCTUnwrap(reply["worktrees"]?.arrayValue)
                XCTAssertEqual(page.count, 1)
                let pageID = try XCTUnwrap(page.first?.objectValue?["worktree_id"]?.stringValue)

                for identity in identities {
                    XCTAssertEqual(
                        persisted(identity), identity.worktreeID == pageID,
                        "only the returned page may persist visuals: \(identity.worktreeID)"
                    )
                }
            }
        }

        private static func canonicalPath(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }

        @MainActor
        private struct Fixture {
            let driver: ContextBuilderMultiRootDiscoveryDriver
            let git: ReviewGitRepositoryFixture
            let logical: URL
            let physical: URL
            let identity: GitWorktreeIdentitySnapshot
            let session: AgentModeViewModel.TabSession
            let sessionID: UUID
            let binding: MCPDomainToolBinding
            let security: DomainToolInvocationSecurityContext

            func call(_ extra: [String: Value], includeWorktree: Bool = true, projectSession: Bool = false) async throws -> Value {
                var args = extra
                args["repo_root"] = .string(logical.path)
                args["session_id"] = .string(sessionID.uuidString)
                if includeWorktree { args["worktree"] = .string(physical.path) }
                let metadata = MCPRequestMetadata(
                    connectionID: nil, clientName: nil, windowID: driver.window.windowID,
                    tabContextHint: projectSession ? MCPTabContextHint(
                        tabID: driver.tabID, workspaceID: nil, windowID: driver.window.windowID
                    ) : nil
                )
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

            /// `list` rejects the binding-only `session_id`/`worktree` arguments `call` injects.
            func listCall(_ extra: [String: Value]) async throws -> Value {
                var args = extra
                args["op"] = .string("list")
                args["repo_root"] = .string(logical.path)
                let metadata = MCPRequestMetadata(
                    connectionID: nil, clientName: nil, windowID: driver.window.windowID, tabContextHint: nil
                )
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

            func addWorktrees(_ names: [String]) throws -> [URL] {
                try names.map { name in
                    let url = git.sandbox.appendingPathComponent(name)
                    _ = try git.runGit(["worktree", "add", "--detach", url.path, "HEAD"], at: logical)
                    return url
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
                _ = vm.test_installPersistentSessionBinding(sessionID: sessionID, on: session, updateWorkspaceMetadata: true)
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
                    git: git,
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
