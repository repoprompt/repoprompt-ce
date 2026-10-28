import Foundation
import MCP
import os
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptVCS
import RepoPromptWorkspaceCore
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

/// Execution-time authority for `manage_worktree` binding mutations that name a session explicitly.
///
/// A full session UUID plus same-window routing must not let an Agent run redirect an unrelated
/// session's execution checkout. External MCP clients keep their existing administrative access.
@MainActor
final class ManageWorktreeSessionAuthorityTests: XCTestCase {
    private let callerSessionID = UUID()
    private let targetSessionID = UUID()

    private final class Probe {
        var provenanceLookups: [UUID] = []
        var grantChecks: [UUID] = []
    }

    func testAdministrativePrincipalKeepsExistingExternalAccess() async throws {
        let probe = Probe()
        try await withWindow { window in
            try await self.authorize(window: window, runPurpose: nil, caller: nil, probe: probe)
        }
        XCTAssertTrue(probe.provenanceLookups.isEmpty, "external clients are not re-classified by provenance")
        XCTAssertTrue(probe.grantChecks.isEmpty, "external clients never need an oversight grant")
    }

    func testAgentSessionMayRebindItsOwnSession() async throws {
        let probe = Probe()
        try await withWindow { window in
            try await self.authorize(window: window, caller: self.targetSessionID, probe: probe)
        }
        XCTAssertTrue(probe.grantChecks.isEmpty)
    }

    func testSpawnParentMayRebindItsDirectChild() async throws {
        let probe = Probe()
        try await withWindow { window in
            try await self.authorize(
                window: window, caller: self.callerSessionID, targetParent: self.callerSessionID, probe: probe
            )
        }
        XCTAssertEqual(probe.provenanceLookups, [targetSessionID])
        XCTAssertTrue(probe.grantChecks.isEmpty)
    }

    func testManageGrantedOverseerMayRebindTarget() async throws {
        let probe = Probe()
        try await withWindow { window in
            try await self.authorize(
                window: window,
                caller: self.callerSessionID,
                observer: self.endpoint(sessionID: self.callerSessionID),
                managedTargets: [self.targetSessionID],
                probe: probe
            )
        }
        XCTAssertEqual(probe.grantChecks, [targetSessionID])
    }

    func testBindingAuthorityRetainsOriginalGrantInsteadOfAdoptingReplacement() async throws {
        try await withWindow { window in
            let observer = self.endpoint(sessionID: self.callerSessionID)
            var generation = 1
            var acquisitions = 0
            let authority = try await AgentSessionTargetOperationGuard.requireWorktreeBindingAuthority(
                targetSessionID: self.targetSessionID,
                metadata: MCPRequestMetadata(connectionID: nil, clientName: nil, windowID: window.windowID, runPurpose: .agentModeRun),
                targetWindow: window,
                resolveSpawnParentSessionID: { _, _ in self.callerSessionID },
                resolveObserverEndpoint: { _, _ in observer },
                resolveTargetProvenance: { .known(targetSessionID: $0, parentSessionID: nil) },
                hasManageGrant: { _, target in
                    acquisitions += 1
                    let capturedGeneration = generation
                    return .init(revalidate: {
                        guard generation == capturedGeneration else {
                            throw AgentSessionTargetOperationGuard.denialError(sessionID: target)
                        }
                    })
                }
            )
            try await authority.revalidate()
            // The same UUIDs now have a replacement grant. It must not revive this operation.
            generation += 1
            await self.assertUniformDenial { try await authority.revalidate() }
            XCTAssertEqual(acquisitions, 1)
        }
    }

    func testDisablingFullAccessPreservesIndependentSpawnParentAuthorityOnly() async throws {
        try await withWindow { window in
            for isParent in [true, false] {
                var fullAccess = true
                let scopes = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
                scopes.isGlobalAutoApproveEnabled = { fullAccess }
                let authority = try await AgentSessionTargetOperationGuard.requireWorktreeBindingAuthority(
                    targetSessionID: self.targetSessionID,
                    metadata: MCPRequestMetadata(connectionID: nil, clientName: nil, windowID: window.windowID, runPurpose: .agentModeRun),
                    targetWindow: window,
                    resolveSpawnParentSessionID: { _, _ in self.callerSessionID },
                    resolveObserverEndpoint: { _, _ in nil },
                    resolveTargetProvenance: { .known(targetSessionID: $0, parentSessionID: isParent ? self.callerSessionID : nil) },
                    hasManageGrant: { _, _ in XCTFail("Full access must not acquire a link")
                        return nil
                    },
                    authorizationEngine: scopes.authorization
                )
                fullAccess = false
                var published = false
                if isParent {
                    try await authority.revalidate()
                    try authority.commit { published = true }
                    XCTAssertTrue(published)
                } else {
                    await self.assertUniformDenial { try await authority.revalidate() }
                    XCTAssertThrowsError(try authority.commit { published = true })
                    XCTAssertFalse(published)
                }
            }
        }
    }

    func testDisablingFullAccessPreservesCapturedManageLink() async throws {
        try await withWindow { window in
            var fullAccess = true
            var linkLive = true
            var acquisitions = 0
            let scopes = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
            scopes.isGlobalAutoApproveEnabled = { fullAccess }
            let authority = try await AgentSessionTargetOperationGuard.requireWorktreeBindingAuthority(
                targetSessionID: self.targetSessionID,
                metadata: MCPRequestMetadata(connectionID: nil, clientName: nil, windowID: window.windowID, runPurpose: .agentModeRun),
                targetWindow: window,
                resolveSpawnParentSessionID: { _, _ in self.callerSessionID },
                resolveObserverEndpoint: { _, _ in self.endpoint(sessionID: self.callerSessionID) },
                resolveTargetProvenance: { .known(targetSessionID: $0, parentSessionID: nil) },
                hasManageGrant: { _, _ in
                    acquisitions += 1
                    return .init(revalidate: {
                        guard linkLive else { throw AgentSessionTargetOperationGuard.denialError(sessionID: self.targetSessionID) }
                    }, commit: { body in
                        guard linkLive else { throw AgentSessionTargetOperationGuard.denialError(sessionID: self.targetSessionID) }
                        try body()
                    })
                },
                authorizationEngine: scopes.authorization
            )
            fullAccess = false
            try await authority.revalidate()
            var published = false
            try authority.commit { published = true }
            XCTAssertTrue(published)
            linkLive = false
            await self.assertUniformDenial { try await authority.revalidate() }
            XCTAssertThrowsError(try authority.commit {})
            XCTAssertEqual(acquisitions, 1)
        }
    }

    func testUnrelatedAgentSessionIsDeniedWithUniformNotFound() async throws {
        try await withWindow { window in
            // Linked without management (or not linked at all), and not the spawn parent.
            await self.assertUniformDenial {
                try await self.authorize(
                    window: window,
                    caller: self.callerSessionID,
                    targetParent: UUID(),
                    observer: self.endpoint(sessionID: self.callerSessionID)
                )
            }
        }
    }

    func testObserverEndpointForAnotherSessionDoesNotCarryItsGrant() async throws {
        try await withWindow { window in
            let otherObserver = self.endpoint(sessionID: UUID())
            await self.assertUniformDenial {
                try await self.authorize(
                    window: window,
                    caller: self.callerSessionID,
                    observer: otherObserver,
                    managedTargets: [self.targetSessionID]
                )
            }
        }
    }

    func testUnresolvedAgentRunFailsClosedBeforeConsultingProvenanceOrGrants() async throws {
        let probe = Probe()
        try await withWindow { window in
            await self.assertUniformDenial {
                try await self.authorize(
                    window: window,
                    caller: nil,
                    targetParent: nil,
                    observer: self.endpoint(sessionID: self.callerSessionID),
                    managedTargets: [self.targetSessionID],
                    probe: probe
                )
            }
        }
        XCTAssertTrue(probe.provenanceLookups.isEmpty)
        XCTAssertTrue(probe.grantChecks.isEmpty)
    }

    private func authorize(
        window: WindowState,
        runPurpose: MCPRunPurpose? = .agentModeRun,
        caller: UUID?,
        targetParent: UUID? = nil,
        observer: DomainAgentSessionLinkEndpointIdentity? = nil,
        managedTargets: Set<UUID> = [],
        probe: Probe = Probe()
    ) async throws {
        _ = try await AgentSessionTargetOperationGuard.requireWorktreeBindingAuthority(
            targetSessionID: targetSessionID,
            metadata: MCPRequestMetadata(
                connectionID: nil,
                clientName: "manage-worktree-authority-tests",
                windowID: window.windowID,
                runPurpose: runPurpose
            ),
            targetWindow: window,
            resolveSpawnParentSessionID: { _, _ in caller },
            resolveObserverEndpoint: { _, _ in observer },
            resolveTargetProvenance: { sessionID in
                probe.provenanceLookups.append(sessionID)
                return .known(targetSessionID: sessionID, parentSessionID: targetParent)
            },
            hasManageGrant: { endpoint, sessionID in
                probe.grantChecks.append(sessionID)
                guard endpoint == observer, managedTargets.contains(sessionID) else { return nil }
                return .init(revalidate: {})
            }
        )
    }

    private func endpoint(sessionID: UUID) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: 1,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: sessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        )
    }

    private func assertUniformDenial(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected a worktree binding authorization denial", file: file, line: line)
        } catch {
            XCTAssertEqual(
                "\(error)",
                "\(AgentSessionTargetOperationGuard.denialError(sessionID: targetSessionID))",
                "Denial must be indistinguishable from a missing session",
                file: file,
                line: line
            )
        }
    }

    private func withWindow(_ body: (WindowState) async throws -> Void) async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        try await body(window)
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

        func testAgentRunWithoutAuthorityCannotBindAnExplicitSession() async throws {
            try await withProvider { fixture in
                do {
                    _ = try await fixture.call(["op": .string("bind")], runPurpose: .agentModeRun)
                    XCTFail("An Agent run without authority over the session must not rebind it")
                } catch {
                    XCTAssertTrue("\(error)".contains("is not available to this caller's scope"), "\(error)")
                }
                XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
            }
        }

        func testAgentRunWithoutAuthorityCannotUnbindAnExplicitSession() async throws {
            try await withProvider { fixture in
                _ = try await fixture.call(["op": .string("bind")])
                let original = fixture.session.worktreeBindings
                XCTAssertFalse(original.isEmpty)
                do {
                    _ = try await fixture.call(["op": .string("unbind")], includeWorktree: false, runPurpose: .agentModeRun)
                    XCTFail("An Agent run without authority over the session must not unbind it")
                } catch {
                    XCTAssertTrue("\(error)".contains("is not available to this caller's scope"), "\(error)")
                }
                XCTAssertEqual(fixture.session.worktreeBindings, original)
            }
        }

        func testRequiredSaveFailureSettlesIndeterminateWithBindingActuallyChanged() async throws {
            try await withProvider { fixture in
                struct SaveFailure: Error {}
                var saveAttempted = false
                fixture.driver.window.agentModeViewModel.test_setAgentSessionSaver { _, _, _ in
                    saveAttempted = true
                    throw SaveFailure()
                }
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
                XCTAssertTrue(saveAttempted, "The injected persistence failure must be reached after admission.")
                XCTAssertEqual(fixture.session.worktreeBindings.first?.worktreeID, fixture.identity.worktreeID)
                XCTAssertEqual(settlements.withLock { $0.last?.state }, .indeterminateAfterCommit)
                let journal = try await fixture.driver.fixture.runtime.mutationJournal.snapshot()
                XCTAssertEqual(journal.recordSnapshots.last?.status, .indeterminateAfterCommit)
            }
        }

        func testCreateRefusesExistingBranchAsNotAppliedAndFreshBranchCommitsAtBackendFence() async throws {
            try await withProvider { fixture in
                let base = try fixture.git.runGit(["rev-parse", "HEAD"], at: fixture.logical)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try fixture.git.runGit(["branch", "taken", base], at: fixture.logical)
                try FileManager.default.createDirectory(
                    at: GitWorktreeDefaultPathPlanner.defaultContainer(forMainWorktreeRoot: fixture.logical),
                    withIntermediateDirectories: true
                )
                let registrationsBefore = try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.logical)
                let settlements = OSAllocatedUnfairLock<[DomainProtectedMutationSettlement]>(initialState: [])
                do {
                    _ = try await MCPDomainProtectedMutationSettlementContext.$observer.withValue({ settlement in
                        settlements.withLock { $0.append(settlement) }
                    }) {
                        try await fixture.call([
                            "op": .string("create"), "branch": .string("taken"), "base_ref": .string(base)
                        ], includeWorktree: false)
                    }
                    XCTFail("Creating an existing branch must be refused")
                } catch {
                    XCTAssertNil(error as? DomainProtectedMutationError, "Refusal must not be indeterminate: \(error)")
                    XCTAssertTrue(
                        error.localizedDescription.contains("a branch named 'taken' already exists"),
                        error.localizedDescription
                    )
                }
                XCTAssertEqual(settlements.withLock { $0.last?.state }, .notApplied)
                XCTAssertEqual(
                    try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.logical),
                    registrationsBefore
                )

                let reply = try await fixture.call([
                    "op": .string("create"), "branch": .string("fresh"), "base_ref": .string(base)
                ], includeWorktree: false)
                let createdPath = try XCTUnwrap(reply.objectValue?["created_worktree"]?.objectValue?["path"]?.stringValue)
                XCTAssertEqual(
                    try fixture.git.runGit(["rev-parse", "HEAD"], at: URL(fileURLWithPath: createdPath))
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    base
                )
                let journal = try await fixture.driver.fixture.runtime.mutationJournal.snapshot()
                XCTAssertEqual(
                    journal.recordSnapshots.map(\.status).sorted { $0.rawValue < $1.rawValue },
                    [.applied, .failedBeforeCommit]
                )
            }
        }

        func testCreatePreservesAppliedBindingWhenRequiredPersistenceFails() async throws {
            try await withProvider { fixture in
                struct SaveFailure: Error {}
                var saveAttempted = false
                fixture.driver.window.agentModeViewModel.test_setAgentSessionSaver { _, _, _ in
                    saveAttempted = true
                    throw SaveFailure()
                }
                try FileManager.default.createDirectory(
                    at: GitWorktreeDefaultPathPlanner.defaultContainer(forMainWorktreeRoot: fixture.logical),
                    withIntermediateDirectories: true
                )
                let reply = try await fixture.call([
                    "op": .string("create"), "branch": .string("created-binding-save-failed"), "bind": .bool(true)
                ], includeWorktree: false)
                XCTAssertTrue(saveAttempted, "The real binding must reach its required persistence fence")
                let created = try XCTUnwrap(reply.objectValue?["created_worktree"]?.objectValue)
                let worktreeID = try XCTUnwrap(created["worktree_id"]?.stringValue)
                let binding = try XCTUnwrap(reply.objectValue?["binding"]?.objectValue)
                XCTAssertEqual(binding["worktree_id"]?.stringValue, worktreeID)
                XCTAssertEqual(fixture.session.worktreeBindings.first?.worktreeID, worktreeID)
                let warning = try XCTUnwrap(reply.objectValue?["warning"]?.stringValue)
                XCTAssertTrue(warning.contains("binding is currently applied"), warning)
                XCTAssertTrue(warning.contains("persistence could not be confirmed"), warning)
                XCTAssertFalse(warning.contains("no session binding was applied"), warning)
                XCTAssertFalse(warning.contains("cleanup is manual"), warning)
                XCTAssertNil(AgentSessionLinkRuntimeBridge.shared.worktreeOwnership.records[worktreeID]?.releasedAt)
            }
        }

        func testCreateKeepsDescriptorAndWorktreeWhenBindingIsRefused() async throws {
            try await withProvider { fixture in
                _ = try await fixture.call(["op": .string("bind")])
                let original = fixture.session.worktreeBindings
                fixture.session.runState = .running
                defer { fixture.session.runState = .idle }
                try FileManager.default.createDirectory(
                    at: GitWorktreeDefaultPathPlanner.defaultContainer(forMainWorktreeRoot: fixture.logical),
                    withIntermediateDirectories: true
                )
                let reply = try await fixture.call([
                    "op": .string("create"), "branch": .string("created-unbound"), "bind": .bool(true)
                ], includeWorktree: false)
                let created = try XCTUnwrap(reply.objectValue?["created_worktree"]?.objectValue)
                let path = try XCTUnwrap(created["path"]?.stringValue)
                XCTAssertTrue(FileManager.default.fileExists(atPath: path))
                XCTAssertEqual(fixture.session.worktreeBindings, original)
                XCTAssertNil(reply.objectValue?["binding"])
                let warning = try XCTUnwrap(reply.objectValue?["warning"]?.stringValue)
                XCTAssertTrue(warning.contains("session binding failed"))
                XCTAssertTrue(warning.contains("cleanup is manual"))
                XCTAssertTrue(warning.contains(path))
                XCTAssertTrue(fixture.session.items.contains { $0.text.contains(path) && $0.text.contains("cleanup is manual") })
                let worktreeID = try XCTUnwrap(created["worktree_id"]?.stringValue)
                let repositoryID = try XCTUnwrap(reply.objectValue?["repository"]?.objectValue?["repository_id"]?.stringValue)
                XCTAssertNil(GlobalSettingsStore.shared.worktreeVisualIdentity(repositoryID: repositoryID, worktreeID: worktreeID))
                XCTAssertNotNil(AgentSessionLinkRuntimeBridge.shared.worktreeOwnership.records[worktreeID]?.releasedAt)
            }
        }

        func testRelocatedSessionDefaultSelectorCreateIsCoveredByLogicalRootGrantOnly() async throws {
            try await withProvider { fixture in
                _ = try await fixture.call(["op": .string("bind")])
                let bound = try XCTUnwrap(fixture.session.worktreeBindings.first)
                try FileManager.default.createDirectory(
                    at: GitWorktreeDefaultPathPlanner.defaultContainer(forMainWorktreeRoot: fixture.logical),
                    withIntermediateDirectories: true
                )
                // A live run's grant covers the workspace's logical roots only, never the physical
                // worktree its session is relocated to; omitting repo_root uses the bound root.
                let logicalOnly: Set<String> = [fixture.logical.resolvingSymlinksInPath().path]
                let reply = try await fixture.call(
                    ["op": .string("create"), "branch": .string("relocated-fresh")],
                    includeWorktree: false,
                    includeRepoRoot: false,
                    projectSession: true,
                    authorizedCanonicalRoots: logicalOnly
                )
                let created = try XCTUnwrap(reply.objectValue?["created_worktree"]?.objectValue?["path"]?.stringValue)
                XCTAssertTrue(FileManager.default.fileExists(atPath: created))
                XCTAssertEqual(fixture.session.worktreeBindings, [bound])

                // Unbinding by the default selector resolves the same logical root identity.
                _ = try await fixture.call(
                    ["op": .string("unbind")],
                    includeWorktree: false,
                    includeRepoRoot: false,
                    projectSession: true,
                    authorizedCanonicalRoots: logicalOnly
                )
                XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
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
                    let value = try await fixture.listCall(["limit": .int(2), "offset": .int(offset)])
                    let reply = try XCTUnwrap(value.objectValue)
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
                @MainActor func persisted(_ identity: GitWorktreeIdentitySnapshot) -> Bool {
                    GlobalSettingsStore.shared.worktreeVisualIdentity(
                        repositoryID: identity.repository.repositoryID, worktreeID: identity.worktreeID
                    ) != nil
                }
                XCTAssertFalse(identities.contains { persisted($0) })

                let value = try await fixture.listCall([
                    "limit": .int(1), "offset": .int(1), "persist_visuals": .bool(true)
                ])
                let reply = try XCTUnwrap(value.objectValue)
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

        // MARK: - Default repository election (#1431)

        // Declared [A,B,C] is installed [B,C,A] (bound checkouts install after unbound siblings), so a
        // first-loaded default can never pass by accident.

        func testElectionWithoutBindingUsesDeclaredPrimaryNotFirstInstalledRoot() async throws {
            try await withElectionFixture { fixture in
                try await fixture.assertGitDefault(.alpha)
                let list = try await fixture.manage(["op": .string("list")])
                XCTAssertEqual(Self.repositoryRootPath(list), Self.canonicalPath(fixture.alpha))
                let created = try await fixture.manage(["op": .string("create"), "branch": .string("primary-default")])
                let createdPath = try XCTUnwrap(created.objectValue?["created_worktree"]?.objectValue?["path"]?.stringValue)
                XCTAssertEqual(fixture.repositoryID(URL(fileURLWithPath: createdPath)), fixture.repositoryID(fixture.alpha))
            }
        }

        func testElectionSoleBindingOnPrimaryUsesItsCheckoutAndBareMainStaysInPrimary() async throws {
            try await withElectionFixture { fixture in
                try fixture.bind([(fixture.alpha, fixture.alphaPrime)])
                try await fixture.assertGitDefault(.alphaPrime)
                let main = try await fixture.git(["op": .string("status"), "repo_root": .string("@main")])
                XCTAssertEqual(Self.statusBranch(main), RepoMarker.alpha.branch, Self.json(main))
                let list = try await fixture.manage(["op": .string("list")])
                XCTAssertEqual(Self.repositoryRootPath(list), Self.canonicalPath(fixture.alphaPrime))
            }
        }

        func testElectionSoleSecondaryBindingUsesItsCheckoutNotUnboundSiblings() async throws {
            try await withElectionFixture { fixture in
                try fixture.bind([(fixture.beta, fixture.betaPrime)])
                try await fixture.assertGitDefault(.betaPrime)
                let list = try await fixture.manage(["op": .string("list")])
                XCTAssertEqual(Self.repositoryRootPath(list), Self.canonicalPath(fixture.betaPrime))
            }
        }

        func testElectionMultipleBindingsRefuseUnqualifiedAndRelativeCallsBeforeMutation() async throws {
            try await withElectionFixture { fixture in
                try fixture.bind([(fixture.alpha, fixture.alphaPrime), (fixture.beta, fixture.betaPrime)])
                let original = fixture.session.worktreeBindings
                for args: [String: Value] in [
                    ["op": .string("status")],
                    ["op": .string("diff"), "detail": .string("files")],
                    ["op": .string("log"), "count": .int(1)],
                    ["op": .string("status"), "repo_root": .string("@main")]
                ] {
                    await fixture.assertMultipleBindingRefusal(args, toolName: "git")
                }
                let registrations = try fixture.worktreeRegistrations()
                for args: [String: Value] in [
                    ["op": .string("list")],
                    ["op": .string("show")],
                    ["op": .string("create"), "branch": .string("ambiguous-default")],
                    ["op": .string("bind"), "session_id": .string(fixture.sessionID.uuidString), "worktree": .string("@main")],
                    ["op": .string("unbind"), "session_id": .string(fixture.sessionID.uuidString)]
                ] {
                    await fixture.assertMultipleBindingRefusal(args, toolName: "manage_worktree")
                }
                XCTAssertEqual(try fixture.worktreeRegistrations(), registrations)
                XCTAssertEqual(fixture.session.worktreeBindings, original)
            }
        }

        func testElectionMultipleBindingsStillHonorIdentifyingSelectors() async throws {
            try await withElectionFixture { fixture in
                try fixture.bind([(fixture.alpha, fixture.alphaPrime), (fixture.beta, fixture.betaPrime)])
                let alphaPrimeID = try fixture.worktreeID(fixture.alphaPrime)
                let betaPrimeID = try fixture.worktreeID(fixture.betaPrime)

                let byPath = try await fixture.git(["op": .string("status"), "repo_root": .string(fixture.gamma.path)])
                XCTAssertEqual(Self.statusBranch(byPath), RepoMarker.gamma.branch, Self.json(byPath))
                let key = GitRepoDescriptor(rootURL: fixture.betaPrime.resolvingSymlinksInPath()).repoKey
                let byKey = try await fixture.git(["op": .string("status"), "repo_key": .string(key)])
                XCTAssertEqual(Self.statusBranch(byKey), RepoMarker.betaPrime.branch, Self.json(byKey))
                let byID = try await fixture.git(["op": .string("status"), "repo_root": .string("@id:\(alphaPrimeID)")])
                XCTAssertEqual(Self.statusBranch(byID), RepoMarker.alphaPrime.branch, Self.json(byID))
                let byBranch = try await fixture.git([
                    "op": .string("log"), "count": .int(1), "repo_root": .string("@branch:\(RepoMarker.betaPrime.branch)")
                ])
                XCTAssertTrue(Self.json(byBranch).contains(RepoMarker.betaPrime.subject), Self.json(byBranch))

                // An identifying worktree selects its own repository for the DTO and binding identity.
                let shown = try await fixture.manage(["op": .string("show"), "worktree": .string("@id:\(betaPrimeID)")])
                XCTAssertEqual(shown.objectValue?["worktree"]?.objectValue?["worktree_id"]?.stringValue, betaPrimeID)
                XCTAssertEqual(Self.repositoryRootPath(shown), Self.canonicalPath(fixture.betaPrime))
                _ = try await fixture.manage([
                    "op": .string("unbind"), "session_id": .string(fixture.sessionID.uuidString),
                    "worktree_id": .string(betaPrimeID)
                ])
                XCTAssertEqual(fixture.session.worktreeBindings.map(\.worktreeID), [alphaPrimeID])
            }
        }

        func testElectionRefusesNonGitPrimaryWithoutFallingBackToGitSibling() async throws {
            try await withElectionFixture(gitRootIndices: [1, 2]) { fixture in
                // An enclosing repository is outside the declared roots and cannot supply the default either.
                try fixture.repos.initializeRepository(at: fixture.alpha.deletingLastPathComponent())
                let unqualifiedCalls: [(String, [String: Value])] = [
                    ("git", ["op": .string("status")]),
                    ("git", ["op": .string("log"), "count": .int(1)]),
                    ("manage_worktree", ["op": .string("list")])
                ]
                for (toolName, args) in unqualifiedCalls {
                    do {
                        let reply = try await fixture.invoke(toolName, args)
                        XCTFail("Unqualified \(toolName) must not fall back from a non-Git PRIMARY: \(Self.json(reply))")
                    } catch {
                        let text = Self.errorText(error)
                        XCTAssertTrue(text.contains(fixture.alpha.path), text)
                        XCTAssertTrue(text.contains("not inside a Git repository"), text)
                    }
                }
                let explicit = try await fixture.git(["op": .string("status"), "repo_root": .string(fixture.beta.path)])
                XCTAssertEqual(Self.statusBranch(explicit), RepoMarker.beta.branch, Self.json(explicit))
            }
        }

        func testElectionLoaderGateInstallsSiblingsBeforeHeldPrimary() async throws {
            try await withElectionFixture(adversarialOrder: false) { fixture in
                let driver = fixture.driver
                let workspace = try XCTUnwrap(driver.manager.workspace(withID: driver.fixture.workspace.id))
                for root in fixture.roots {
                    await driver.files.unloadRootFolderPath(root.path)
                }
                for root in [fixture.beta, fixture.gamma] {
                    try await driver.files.loadFolder(at: root, for: workspace)
                }
                let gate = try driver.manager.armRootPreloadGateForTesting(
                    windowID: driver.window.windowID, workspaceID: workspace.id, rootIndex: 0, expectedPath: fixture.alpha.path
                )
                defer { driver.manager.clearRootPreloadGateForTesting() }
                let held = XCTestExpectation(description: "declared PRIMARY held before its hydration")
                gate.didHold = { held.fulfill() }
                let ticket = try XCTUnwrap(driver.manager.requestRootReconciliation(workspaceID: workspace.id))
                let reconciliation = driver.fixture.startOwnedTask {
                    do { _ = try await driver.manager.awaitRootReconciliationCompletion(ticket: ticket) }
                    catch { XCTFail("Gated reconciliation failed: \(error)") }
                }
                try await driver.fixture.awaitGateEvent(held)
                let whileHeld = await fixture.actorRootPaths()
                XCTAssertEqual(whileHeld, [fixture.beta, fixture.gamma].map(Self.standardized))
                driver.manager.clearRootPreloadGateForTesting()
                await reconciliation.value
                await fixture.assertAdversarialOrder()
                try await fixture.assertGitDefault(.alpha)
            }
        }

        func testElectionDiffArtifactManifestRecordsElectedRepositoryAndCheckout() async throws {
            try await withElectionFixture { fixture in
                try await fixture.assertDiffArtifactManifest(repoRoot: fixture.alpha, worktreeRoot: nil, marker: .alpha)
                try fixture.bind([(fixture.beta, fixture.betaPrime)])
                try await fixture.assertDiffArtifactManifest(repoRoot: fixture.betaPrime, worktreeRoot: fixture.betaPrime, marker: .betaPrime)
            }
        }

        func testElectionUnhydratedBindingStateFailsClosedInsteadOfCountingZero() async throws {
            try await withElectionFixture { fixture in
                try fixture.bind([(fixture.alpha, fixture.alphaPrime)])
                fixture.session.hasLoadedPersistedState = false
                defer { fixture.session.hasLoadedPersistedState = true }
                XCTAssertEqual(
                    fixture.driver.window.agentModeViewModel.worktreeBindingState(forAgentSessionID: fixture.sessionID),
                    .unhydrated
                )
                do {
                    let reply = try await fixture.git(["op": .string("status")])
                    XCTFail("Unhydrated bindings must fail closed, not elect a default: \(Self.json(reply))")
                } catch {
                    let message = Self.errorText(error)
                    XCTAssertTrue(message.contains("rather than falling back to the canonical checkout"), message)
                    XCTAssertFalse(message.contains("DefaultRepositoryRequired"), message)
                }
            }
        }

        func testElectionCountsDistinctLogicalBindingsThatShareOneRepository() async throws {
            try await withElectionFixture(gitRootIndices: [0, 1], gammaLinkedToAlpha: true) { fixture in
                let alphaSecond = fixture.repos.sandbox.appendingPathComponent("alpha-wt2")
                _ = try fixture.repos.runGit(["worktree", "add", "-b", "alpha-wt2", alphaSecond.path, "HEAD"], at: fixture.alpha)
                try fixture.bind([(fixture.alpha, fixture.alphaPrime), (fixture.gamma, alphaSecond)])
                let bindings = fixture.session.worktreeBindings
                XCTAssertEqual(Set(bindings.map(\.repositoryID)).count, 1, "both bindings belong to one repository")
                XCTAssertEqual(Set(bindings.map(\.logicalRootPath)).count, 2, "two distinct logical roots")
                do {
                    let reply = try await fixture.git(["op": .string("status")])
                    XCTFail("Two logical bindings must refuse even when they share a repository: \(Self.json(reply))")
                } catch {
                    let message = Self.errorText(error)
                    XCTAssertTrue(message.contains("2 worktree bindings"), message)
                    XCTAssertTrue(message.contains(fixture.alpha.path) && message.contains(fixture.gamma.path), message)
                }
            }
        }

        func testElectionRelativeSelectSelectorUsesTheElectedRepository() async throws {
            try await withElectionFixture { fixture in
                try fixture.bind([(fixture.beta, fixture.betaPrime)])
                let bound = try XCTUnwrap(fixture.session.worktreeBindings.first)
                let reply = try await fixture.manage([
                    "op": .string("select"), "session_id": .string(fixture.sessionID.uuidString), "worktree": .string("@main")
                ])
                // The sole binding B->B' is elected, so `@main` is B's logical checkout: selecting it removes that
                // binding. A first-installed default (C or A) would have been a no-op leaving the binding in place.
                XCTAssertTrue(fixture.session.worktreeBindings.isEmpty, "\(fixture.session.worktreeBindings)")
                XCTAssertEqual(reply.objectValue?["previous_binding"]?.objectValue?["id"]?.stringValue, bound.id)
            }
        }

        func testElectionUnqualifiedShowUsesTheSameDefaultAsStatus() async throws {
            try await withElectionFixture { fixture in
                try fixture.bind([(fixture.beta, fixture.betaPrime)])
                let show = try await fixture.git(["op": .string("show"), "ref": .string("HEAD")])
                XCTAssertTrue(Self.json(show).contains(RepoMarker.betaPrime.subject), Self.json(show))
            }
        }

        func testElectionLeavesExplicitDuplicateRootNameOnFirstVisibleMatch() async throws {
            // Declared [one/dup, two/dup, C] installed [two/dup, C, one/dup]. An explicit name keeps the
            // resolver's existing first-visible-root match; only the default uses declared order. Changing
            // explicit name matching is out of scope for #1431.
            try await withElectionFixture(rootNames: ["one/dup", "two/dup", "C"]) { fixture in
                let explicit = try await fixture.git(["op": .string("status"), "repo_root": .string("dup")])
                XCTAssertEqual(Self.statusBranch(explicit), RepoMarker.beta.branch, Self.json(explicit))
                let unqualified = try await fixture.git(["op": .string("status")])
                XCTAssertEqual(Self.statusBranch(unqualified), RepoMarker.alpha.branch, Self.json(unqualified))
            }
        }

        func testElectionUndeclaredBindingFailsClosedEvenForExplicitSibling() async throws {
            try await withElectionFixture { fixture in
                let undeclared = fixture.repos.sandbox.appendingPathComponent("undeclared-logical", isDirectory: true)
                try FileManager.default.createDirectory(at: undeclared, withIntermediateDirectories: true)
                fixture.session.worktreeBindings = try [fixture.binding(logical: undeclared, worktree: fixture.alphaPrime)]
                for args: [String: Value] in [
                    ["op": .string("status")],
                    ["op": .string("status"), "repo_root": .string(fixture.gamma.path)]
                ] {
                    do {
                        let reply = try await fixture.git(args)
                        XCTFail("An undeclared binding must fail closed, not fall back: \(Self.json(reply))")
                    } catch {
                        XCTAssertFalse(Self.errorText(error).contains("DefaultRepositoryRequired"), Self.errorText(error))
                    }
                }
            }
        }

        func testElectionInvalidRequestedRefNamesTheExecutionCheckoutAndSettlesNotApplied() async throws {
            try await withElectionFixture { fixture in
                // The sole binding B->B' elects checkout B', which differs from its logical root B.
                try fixture.bind([(fixture.beta, fixture.betaPrime)])
                let bindings = fixture.session.worktreeBindings
                let registrations = try fixture.worktreeRegistrations()
                let container = GitWorktreeDefaultPathPlanner.defaultContainer(forMainWorktreeRoot: fixture.beta)
                let checkoutsBefore = Self.checkouts(in: container)
                // A lone "-" keeps the caller's spelling; the context explains Git's @{-1} meaning.
                for (branch, baseRef) in [("bad-base", "no-such-ref"), ("bad-previous", "-")] {
                    let settlements = OSAllocatedUnfairLock<[DomainProtectedMutationSettlement]>(initialState: [])
                    do {
                        let reply = try await MCPDomainProtectedMutationSettlementContext.$observer.withValue({ settlement in
                            settlements.withLock { $0.append(settlement) }
                        }) {
                            try await fixture.manage([
                                "op": .string("create"), "branch": .string(branch), "base_ref": .string(baseRef)
                            ])
                        }
                        XCTFail("An unresolvable base ref must be refused: \(Self.json(reply))")
                    } catch {
                        XCTAssertNil(error as? DomainProtectedMutationError, "Refusal must not be indeterminate: \(error)")
                        let text = Self.errorText(error)
                        XCTAssertTrue(Self.names(text, "repository ", fixture.betaPrime), "names the execution checkout: \(text)")
                        XCTAssertTrue(Self.names(text, "Workspace root ", fixture.beta), "keeps the logical root legible: \(text)")
                        XCTAssertTrue(text.contains("base ref '\(baseRef)' does not resolve to a commit"), text)
                        XCTAssertTrue(text.contains("branch '\(branch)'"), text)
                        XCTAssertTrue(text.contains("Nothing was created."), text)
                        if baseRef == "-" {
                            XCTAssertTrue(text.contains("@{-1}"), text)
                        }
                    }
                    XCTAssertEqual(settlements.withLock { $0.last?.state }, .notApplied, baseRef)
                    XCTAssertThrowsError(
                        try fixture.repos.runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], at: fixture.betaPrime),
                        "no branch is created for base ref \(baseRef)"
                    )
                }
                XCTAssertEqual(try fixture.worktreeRegistrations(), registrations)
                XCTAssertEqual(Self.checkouts(in: container), checkoutsBefore, "no checkout under the app-managed container")
                XCTAssertEqual(fixture.session.worktreeBindings, bindings)
            }
        }

        func testElectionDeclaredRootsCollapseIdenticalPathsButKeepAliasesInOrder() {
            let home = ("~" as NSString).expandingTildeInPath
            let roots = WorkspaceDefaultGitRepositoryElection.Snapshot.declaredRoots([
                " /tmp/election/A/ \n", "/tmp/election/./A", "", "/tmp/election/B", "~/election-C", "/tmp/election/A-alias"
            ])
            XCTAssertEqual(roots.map(\.path), [
                "/tmp/election/A", "/tmp/election/B", (home as NSString).appendingPathComponent("election-C"), "/tmp/election/A-alias"
            ].map { ($0 as NSString).standardizingPath })
            XCTAssertEqual(roots.first?.displayPath, "/tmp/election/A/")
        }

        private static func canonicalPath(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }

        private static func standardized(_ url: URL) -> String {
            (url.path as NSString).standardizingPath
        }

        private static func json(_ value: Value) -> String {
            (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
        }

        private static func errorText(_ error: Error) -> String {
            "\(error) \(error.localizedDescription)"
        }

        /// Whether `text` names `url` after `label`, in its given, symlink-resolved, or realpath spelling.
        private static func names(_ text: String, _ label: String, _ url: URL) -> Bool {
            var spellings = [url.standardizedFileURL.path, canonicalPath(url)]
            if let resolved = realpath(url.path, nil) {
                spellings.append(String(cString: resolved))
                free(resolved)
            }
            return spellings.contains { text.contains(label + $0) }
        }

        /// Entries of `container` that hold a Git checkout, rather than every directory a create may prepare.
        private static func checkouts(in container: URL) -> [String] {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: container.path)) ?? []
            return entries.filter {
                FileManager.default.fileExists(atPath: container.appendingPathComponent($0).appendingPathComponent(".git").path)
            }.sorted()
        }

        private static func statusBranch(_ reply: Value) -> String? {
            reply.objectValue?["status"]?.objectValue?["branch"]?.stringValue
        }

        private static func repositoryRootPath(_ reply: Value) -> String? {
            reply.objectValue?["repository"]?.objectValue?["root_path"]?.stringValue
                .map { canonicalPath(URL(fileURLWithPath: $0)) }
        }

        /// Distinct branch, tracked change, and newest commit subject per checkout.
        private struct RepoMarker: Equatable {
            let branch: String
            let changedFile: String
            let subject: String

            static let alpha = RepoMarker(branch: "alpha-main", changedFile: "alpha-tracked.txt", subject: "alpha fixture commit")
            static let alphaPrime = RepoMarker(branch: "alpha-wt", changedFile: "alphawt-tracked.txt", subject: "alphawt fixture commit")
            static let beta = RepoMarker(branch: "beta-main", changedFile: "beta-tracked.txt", subject: "beta fixture commit")
            static let betaPrime = RepoMarker(branch: "beta-wt", changedFile: "betawt-tracked.txt", subject: "betawt fixture commit")
            static let gamma = RepoMarker(branch: "gamma-main", changedFile: "gamma-tracked.txt", subject: "gamma fixture commit")
            static let all = [alpha, alphaPrime, beta, betaPrime, gamma]
        }

        @MainActor
        private struct ElectionFixture {
            let driver: ContextBuilderMultiRootDiscoveryDriver
            let repos: ReviewGitRepositoryFixture
            let alpha: URL
            let beta: URL
            let gamma: URL
            let alphaPrime: URL
            let betaPrime: URL
            let session: AgentModeViewModel.TabSession
            let sessionID: UUID
            let gitBinding: MCPDomainToolBinding
            let manageBinding: MCPDomainToolBinding
            let security: DomainToolInvocationSecurityContext

            var roots: [URL] {
                [alpha, beta, gamma]
            }

            func git(_ args: [String: Value]) async throws -> Value {
                try await invoke("git", args)
            }

            func manage(_ args: [String: Value]) async throws -> Value {
                try await invoke("manage_worktree", args)
            }

            /// Routed through the fixture tab so the call captures its session and bindings.
            func invoke(_ toolName: String, _ args: [String: Value]) async throws -> Value {
                let binding = toolName == "git" ? gitBinding : manageBinding
                let metadata = MCPRequestMetadata(
                    connectionID: nil, clientName: nil, windowID: driver.window.windowID,
                    tabContextHint: MCPTabContextHint(tabID: driver.tabID, workspaceID: nil, windowID: driver.window.windowID)
                )
                let invocation = ToolInvocationContext.trustedLocal(toolName: toolName, metadata: metadata)
                let requestSecurity = DomainToolInvocationSecurityContext(
                    principal: security.principal,
                    connectionID: security.connectionID, connectionGeneration: security.connectionGeneration,
                    invocationID: UUID(), runtimeID: security.runtimeID, runtimeGeneration: security.runtimeGeneration,
                    authorizedCanonicalRoots: security.authorizedCanonicalRoots,
                    hasAuthoritativeRoutingContext: true, ephemeralGrantedToolNames: [toolName]
                )
                return try await MCPDomainInvocationSecurityContext.currentTaskLocal.withValue(requestSecurity) {
                    try await MCPInvocationContextBridge.withInvocation(invocation) { try await binding(args) }
                }
            }

            func binding(logical: URL, worktree: URL) throws -> AgentSessionWorktreeBinding {
                let identity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: worktree))
                return AgentSessionWorktreeBinding(
                    id: UUID().uuidString, repositoryID: identity.repository.repositoryID, repoKey: identity.repository.repoKey,
                    logicalRootPath: logical.path, logicalRootName: logical.lastPathComponent,
                    worktreeID: identity.worktreeID, worktreeRootPath: worktree.path,
                    commonGitDir: identity.repository.commonGitDir, isMainWorktree: identity.isMain, source: "test"
                )
            }

            func bind(_ pairs: [(logical: URL, worktree: URL)]) throws {
                session.worktreeBindings = try pairs.map { try binding(logical: $0.logical, worktree: $0.worktree) }
            }

            func worktreeID(_ root: URL) throws -> String {
                try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: root)).worktreeID
            }

            func repositoryID(_ root: URL) -> String? {
                GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: root)?.repository.repositoryID
            }

            func worktreeRegistrations() throws -> [String] {
                try [alpha, beta, gamma].map { try repos.runGit(["worktree", "list", "--porcelain"], at: $0) }
            }

            func actorRootPaths() async -> [String] {
                await driver.files.workspaceFileContextStore.roots()
                    .filter { $0.kind == .primaryWorkspace }
                    .map(\.standardizedFullPath)
            }

            func assertAdversarialOrder(file: StaticString = #filePath, line: UInt = #line) async {
                let actor = await actorRootPaths()
                XCTAssertEqual(actor, [beta, gamma, alpha].map(standardized), "actor install order", file: file, line: line)
                XCTAssertEqual(
                    driver.files.visibleRootShellProjections.map(\.fullPath).map { ($0 as NSString).standardizingPath },
                    roots.map(standardized), "shell order", file: file, line: line
                )
                XCTAssertEqual(
                    driver.manager.workspace(withID: driver.fixture.workspace.id)?.repoPaths,
                    roots.map(\.path), "declared order", file: file, line: line
                )
            }

            func assertGitDefault(_ expected: RepoMarker, file: StaticString = #filePath, line: UInt = #line) async throws {
                let status = try await git(["op": .string("status")])
                XCTAssertEqual(
                    status.objectValue?["status"]?.objectValue?["branch"]?.stringValue, expected.branch,
                    "status: \(text(status))", file: file, line: line
                )
                let diff = try await text(git(["op": .string("diff"), "detail": .string("files")]))
                XCTAssertTrue(diff.contains(expected.changedFile), "diff: \(diff)", file: file, line: line)
                for other in RepoMarker.all where other != expected {
                    XCTAssertFalse(diff.contains(other.changedFile), "diff leaked \(other.changedFile): \(diff)", file: file, line: line)
                }
                let log = try await text(git(["op": .string("log"), "count": .int(1)]))
                XCTAssertTrue(log.contains(expected.subject), "log: \(log)", file: file, line: line)
            }

            /// Inspects the published manifest itself, not rendered headings.
            func assertDiffArtifactManifest(
                repoRoot: URL, worktreeRoot: URL?, marker: RepoMarker, file: StaticString = #filePath, line: UInt = #line
            ) async throws {
                let reply = try await git(["op": .string("diff"), "artifacts": .bool(true), "detail": .string("files")])
                let snapshotDir = try XCTUnwrap(
                    reply.objectValue?["snapshot_dir"]?.stringValue, "no snapshot_dir: \(text(reply))", file: file, line: line
                )
                // `snapshot_dir` is relative to the workspace's Git-data root.
                let workspace = try XCTUnwrap(driver.manager.workspace(withID: driver.fixture.workspace.id), file: file, line: line)
                let manifestURL = GitDiffSnapshotStore()
                    .gitDataRoot(workspaceDirectory: driver.manager.workspaceDirectory(for: workspace))
                    .appendingPathComponent(snapshotDir, isDirectory: true)
                    .appendingPathComponent("manifest.json")
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let manifest = try decoder.decode(GitDiffSnapshotManifest.self, from: Data(contentsOf: manifestURL))
                XCTAssertEqual(manifest.repoRoot.map(canonical), canonical(repoRoot.path), "manifest repo_root", file: file, line: line)
                XCTAssertEqual(manifest.worktreeRoot.map(canonical), worktreeRoot.map { canonical($0.path) }, "manifest worktree_root", file: file, line: line)
                XCTAssertEqual(manifest.files.map(\.gitPath), [marker.changedFile], "manifest files", file: file, line: line)
            }

            private func canonical(_ path: String) -> String {
                URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            }

            func assertMultipleBindingRefusal(
                _ args: [String: Value], toolName: String, file: StaticString = #filePath, line: UInt = #line
            ) async {
                do {
                    let reply = try await invoke(toolName, args)
                    XCTFail("\(toolName) \(args) must refuse with multiple bindings: \(text(reply))", file: file, line: line)
                } catch {
                    let message = "\(error) \(error.localizedDescription)"
                    XCTAssertTrue(message.contains("worktree bindings"), message, file: file, line: line)
                    XCTAssertTrue(message.contains(alpha.path) && message.contains(beta.path), message, file: file, line: line)
                    XCTAssertFalse(message.contains("DefaultRepositoryRequired"), message, file: file, line: line)
                }
            }

            private func standardized(_ url: URL) -> String {
                (url.path as NSString).standardizingPath
            }

            private func text(_ value: Value) -> String {
                (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
            }
        }

        private static func makeElectionRepository(_ git: ReviewGitRepositoryFixture, at root: URL, marker: RepoMarker) throws {
            try git.initializeRepository(at: root)
            try git.write("tracked\n", to: marker.changedFile, at: root)
            _ = try git.runGit(["add", "-A"], at: root)
            try git.commit(marker.subject, at: root)
            _ = try git.runGit(["branch", "-m", marker.branch], at: root)
            try git.write("tracked\nchanged\n", to: marker.changedFile, at: root)
        }

        private static func makeElectionWorktree(
            _ git: ReviewGitRepositoryFixture, from root: URL, at path: URL, marker: RepoMarker
        ) throws {
            _ = try git.runGit(["worktree", "add", "-b", marker.branch, path.path, "HEAD"], at: root)
            try git.write("tracked\n", to: marker.changedFile, at: path)
            _ = try git.runGit(["add", "--", marker.changedFile], at: path)
            try git.commit(marker.subject, at: path)
            try git.write("tracked\nchanged\n", to: marker.changedFile, at: path)
        }

        /// `gammaLinkedToAlpha` makes declared root C a second checkout of A's repository instead of its own repository.
        private func withElectionFixture(
            rootNames: [String] = ["A", "B", "C"],
            gitRootIndices: Set<Int> = [0, 1, 2],
            gammaLinkedToAlpha: Bool = false,
            adversarialOrder: Bool = true,
            _ body: @escaping @MainActor (ElectionFixture) async throws -> Void
        ) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: rootNames, configuration: { $0 }) { driver in
                let git = try ReviewGitRepositoryFixture(parentDirectory: driver.fixture.base)
                defer { git.cleanup() }
                let roots = driver.fixture.rootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
                let primes = [git.sandbox.appendingPathComponent("alpha-wt"), git.sandbox.appendingPathComponent("beta-wt")]
                for (index, marker) in [RepoMarker.alpha, .beta, .gamma].enumerated() where gitRootIndices.contains(index) {
                    try Self.makeElectionRepository(git, at: roots[index], marker: marker)
                    try FileManager.default.createDirectory(
                        at: GitWorktreeDefaultPathPlanner.defaultContainer(forMainWorktreeRoot: roots[index]),
                        withIntermediateDirectories: true
                    )
                }
                for (index, marker) in [RepoMarker.alphaPrime, .betaPrime].enumerated() where gitRootIndices.contains(index) {
                    try Self.makeElectionWorktree(git, from: roots[index], at: primes[index], marker: marker)
                }
                if gammaLinkedToAlpha {
                    // Git accepts an existing empty directory, but not the fixture's placeholder file.
                    try FileManager.default.removeItem(at: roots[2].appendingPathComponent("README.md"))
                    _ = try git.runGit(["worktree", "add", "-b", "gamma-linked", roots[2].path, "HEAD"], at: roots[0])
                }
                if adversarialOrder {
                    let workspace = try XCTUnwrap(driver.manager.workspace(withID: driver.fixture.workspace.id))
                    for root in roots {
                        await driver.files.unloadRootFolderPath(root.path)
                    }
                    for root in [roots[1], roots[2], roots[0]] {
                        try await driver.files.loadFolder(at: root, for: workspace)
                    }
                }

                let vm = driver.window.agentModeViewModel
                let session = AgentModeViewModel.TabSession(tabID: driver.tabID)
                session.hasLoadedPersistedState = true
                let sessionID = UUID()
                vm.test_installLiveSession(session)
                _ = vm.test_installPersistentSessionBinding(sessionID: sessionID, on: session, updateWorkspaceMetadata: true)
                session.recordRestorationAuthoritative(.persistedPayloadApplied)
                vm.test_setAgentSessionSaver { _, _, _ in git.sandbox.appendingPathComponent("session.json") }
                let tools = await driver.window.mcpServer.windowMCPTools
                let gitTool = try XCTUnwrap(tools.first { $0.name == "git" })
                let manageTool = try XCTUnwrap(tools.first { $0.name == "manage_worktree" })
                let runtime = try XCTUnwrap(driver.fixture.runtime)
                let security = DomainToolInvocationSecurityContext(
                    principal: DomainClientPrincipal(
                        principalID: UUID(), stableKey: "worktree-election-test", displayName: "test",
                        kind: .runScoped, assurance: .hostLaunchToken, processID: 42, runID: UUID(), provider: "test"
                    ),
                    connectionID: UUID(), connectionGeneration: 1, invocationID: UUID(),
                    runtimeID: runtime.identity.runtimeID, runtimeGeneration: runtime.identity.lifecycleGeneration,
                    authorizedCanonicalRoots: Set((roots + primes).map { $0.resolvingSymlinksInPath().path }),
                    hasAuthoritativeRoutingContext: true, ephemeralGrantedToolNames: ["git", "manage_worktree"]
                )
                let fixture = try ElectionFixture(
                    driver: driver, repos: git,
                    alpha: roots[0], beta: roots[1], gamma: roots[2], alphaPrime: primes[0], betaPrime: primes[1],
                    session: session, sessionID: sessionID,
                    gitBinding: gitTool.domainBinding(),
                    manageBinding: runtime.protectedMutationProvider.protectedBinding(manageTool.domainBinding()),
                    security: security
                )
                if adversarialOrder {
                    await fixture.assertAdversarialOrder()
                }
                let materializer = WorkspaceRootBindingProjectionMaterializer(store: driver.files.workspaceFileContextStore)
                do {
                    try await body(fixture)
                } catch {
                    await materializer.release(sessionID: sessionID)
                    throw error
                }
                await materializer.release(sessionID: sessionID)
            }
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

            func call(
                _ extra: [String: Value],
                includeWorktree: Bool = true,
                includeRepoRoot: Bool = true,
                projectSession: Bool = false,
                runPurpose: MCPRunPurpose? = nil,
                authorizedCanonicalRoots: Set<String>? = nil
            ) async throws -> Value {
                var args = extra
                if includeRepoRoot { args["repo_root"] = .string(logical.path) }
                args["session_id"] = .string(sessionID.uuidString)
                if includeWorktree { args["worktree"] = .string(physical.path) }
                let metadata = MCPRequestMetadata(
                    connectionID: nil, clientName: nil, windowID: driver.window.windowID,
                    runPurpose: runPurpose,
                    tabContextHint: projectSession ? MCPTabContextHint(
                        tabID: driver.tabID, workspaceID: nil, windowID: driver.window.windowID
                    ) : nil
                )
                let invocation = ToolInvocationContext.trustedLocal(toolName: "manage_worktree", metadata: metadata)
                let requestSecurity = DomainToolInvocationSecurityContext(
                    principal: security.principal,
                    connectionID: security.connectionID, connectionGeneration: security.connectionGeneration,
                    invocationID: UUID(), runtimeID: security.runtimeID, runtimeGeneration: security.runtimeGeneration,
                    authorizedCanonicalRoots: authorizedCanonicalRoots ?? security.authorizedCanonicalRoots,
                    hasAuthoritativeRoutingContext: true, ephemeralGrantedToolNames: ["manage_worktree"]
                )
                return try await MCPDomainInvocationSecurityContext.currentTaskLocal.withValue(requestSecurity) {
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
                return try await MCPDomainInvocationSecurityContext.currentTaskLocal.withValue(requestSecurity) {
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
                XCTAssertNotNil(session.restorationAdmissionFailureMessage)
                session.recordRestorationAuthoritative(.persistedPayloadApplied)
                _ = try XCTUnwrap(
                    session.permitsBoundOperationAndSave ? session.currentRestorationBindingToken : nil,
                    "Worktree provider operations require an already-restored session."
                )
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

    @MainActor
    final class GitDefaultElectionReadAuthorizationTests: XCTestCase {
        func testChildOnlyWorkspaceRefusesEnclosingRepositoryForOmittedAndCurrentSelectors() async throws {
            try await assertReadElection(.childOnly)
        }

        func testNestedRepositoryUsesItsOwnDataForOmittedAndCurrentSelectors() async throws {
            try await assertReadElection(.nestedRepository)
        }

        func testLinkedWorktreeUsesItsOwnDataForOmittedAndCurrentSelectors() async throws {
            try await assertReadElection(.linkedWorktree)
        }

        func testNestedPrimaryCanUseIndependentlyDeclaredEnclosingRepository() async throws {
            try await assertReadElection(.declaredParent)
        }

        func testNestedPrimaryPrefersNearestAuthorizedAncestorDespiteLongerOuterAlias() async throws {
            let git = try ReviewGitRepositoryFixture()
            defer { git.cleanup() }
            let outer = git.sandbox.appendingPathComponent("real")
            let inner = outer.appendingPathComponent("project")
            let primary = inner.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
            try Self.makeRepository(git, at: outer, name: "parent")
            try Self.makeRepository(git, at: inner, name: "child")
            let outerAlias = git.sandbox.appendingPathComponent("longer-spelling-for-the-more-distant-ancestor")
            let innerAlias = git.sandbox.appendingPathComponent("i")
            try FileManager.default.createSymbolicLink(at: outerAlias, withDestinationURL: outer)
            try FileManager.default.createSymbolicLink(at: innerAlias, withDestinationURL: inner)
            let roots = [primary, outerAlias, innerAlias].map {
                WorkspaceRootRef(id: UUID(), name: $0.lastPathComponent, fullPath: $0.path)
            }
            let snapshot = WorkspaceDefaultGitRepositoryElection.Snapshot(
                workspaceID: UUID(), declaredRepoPaths: roots.map(\.fullPath),
                bindingSource: .init(activeAgentSessionID: nil, worktreeBindingState: .notApplicable),
                lookupContext: .visibleWorkspace, lookupRoots: roots
            )
            let selection = try await WorkspaceDefaultGitRepositoryElection(vcsService: VCSService()).elect(in: snapshot)
            XCTAssertEqual(
                GitRepoRootAuthorization.canonicalPath(selection.repository.rootPath),
                GitRepoRootAuthorization.canonicalPath(inner.path)
            )
            XCTAssertEqual(selection.logicalRoot, roots[0], "Retain PRIMARY's logical attribution")
        }

        private enum Layout {
            case childOnly, nestedRepository, linkedWorktree, declaredParent
        }

        /// Exercise the real window Git tool binding with only declared roots in the read grant.
        /// Parent-only branch/file/commit witnesses catch status, diff, and log disclosure independently.
        private func assertReadElection(_ layout: Layout) async throws {
            let rootNames = layout == .declaredParent ? ["parent/child", "parent"] : ["parent/child"]
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: rootNames) { driver in
                let git = try ReviewGitRepositoryFixture(parentDirectory: driver.fixture.base)
                defer { git.cleanup() }
                let child = try URL(fileURLWithPath: XCTUnwrap(driver.fixture.rootPaths.first), isDirectory: true)
                let parent = child.deletingLastPathComponent()
                try Self.makeRepository(git, at: parent, name: "parent")
                switch layout {
                case .nestedRepository:
                    try Self.makeRepository(git, at: child, name: "child")
                case .linkedWorktree:
                    try FileManager.default.removeItem(at: child.appendingPathComponent("README.md"))
                    _ = try git.runGit(["worktree", "add", "-b", "child-main", child.path, "HEAD"], at: parent)
                    try git.write("tracked\n", to: "child-marker.txt", at: child)
                    _ = try git.runGit(["add", "child-marker.txt"], at: child)
                    try git.commit("CHILD_ONLY_ELECTION_SUBJECT", at: child)
                    try git.write("tracked\nchanged\n", to: "child-marker.txt", at: child)
                case .childOnly, .declaredParent:
                    break
                }
                let tools = await driver.window.mcpServer.windowMCPTools
                let binding = try XCTUnwrap(tools.first { $0.name == "git" }).domainBinding()
                let runtime = try XCTUnwrap(driver.fixture.runtime)
                let metadata = MCPRequestMetadata(
                    connectionID: nil, clientName: nil, windowID: driver.window.windowID,
                    tabContextHint: MCPTabContextHint(tabID: driver.tabID, workspaceID: nil, windowID: driver.window.windowID)
                )
                let invocation = ToolInvocationContext.trustedLocal(toolName: "git", metadata: metadata)
                let security = DomainToolInvocationSecurityContext(
                    principal: DomainClientPrincipal(
                        principalID: UUID(), stableKey: "git-election-read-test", displayName: "test",
                        kind: .runScoped, assurance: .hostLaunchToken, processID: 42, runID: UUID(), provider: "test"
                    ),
                    connectionID: UUID(), connectionGeneration: 1, invocationID: UUID(),
                    runtimeID: runtime.identity.runtimeID, runtimeGeneration: runtime.identity.lifecycleGeneration,
                    authorizedCanonicalRoots: Set(driver.fixture.rootPaths.map {
                        URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                    }),
                    hasAuthoritativeRoutingContext: true, ephemeralGrantedToolNames: ["git"]
                )
                let expected = layout == .declaredParent ? "parent" : "child"
                for selector: String? in [nil, "@current"] {
                    for op in ["status", "diff", "log"] {
                        var args: [String: Value] = ["op": .string(op)]
                        if let selector { args["repo_root"] = .string(selector) }
                        if op == "diff" { args["detail"] = .string("files") }
                        if op == "log" { args["count"] = .int(1) }
                        do {
                            let reply = try await MCPDomainInvocationSecurityContext.currentTaskLocal.withValue(security) {
                                try await MCPInvocationContextBridge.withInvocation(invocation) { try await binding(args) }
                            }
                            let text = try String(decoding: JSONEncoder().encode(reply), as: UTF8.self)
                            if layout == .childOnly {
                                XCTAssertFalse(text.contains("parent-marker.txt"), text)
                                XCTAssertFalse(text.contains("PARENT_ONLY_ELECTION_SUBJECT"), text)
                                XCTFail("Child-only workspace must refuse parent \(op), selector \(selector ?? "omitted"): \(text)")
                            } else {
                                switch op {
                                case "status":
                                    XCTAssertEqual(reply.objectValue?["status"]?.objectValue?["branch"]?.stringValue, "\(expected)-main", text)
                                    XCTAssertTrue(text.contains("\(expected)-marker.txt"), text)
                                case "diff":
                                    XCTAssertTrue(text.contains("\(expected)-marker.txt"), text)
                                default:
                                    XCTAssertTrue(text.contains("\(expected.uppercased())_ONLY_ELECTION_SUBJECT"), text)
                                }
                                if expected == "child" {
                                    XCTAssertFalse(text.contains("parent-marker.txt"), text)
                                    XCTAssertFalse(text.contains("PARENT_ONLY_ELECTION_SUBJECT"), text)
                                }
                            }
                        } catch {
                            guard layout == .childOnly else { throw error }
                            XCTAssertTrue(error.localizedDescription.contains("no default Git repository"), "\(error)")
                            XCTAssertFalse(error.localizedDescription.contains("PARENT_ONLY_ELECTION_SUBJECT"), "\(error)")
                        }
                    }
                }
            }
        }

        private static func makeRepository(_ git: ReviewGitRepositoryFixture, at root: URL, name: String) throws {
            try git.initializeRepository(at: root)
            try git.write("tracked\n", to: "\(name)-marker.txt", at: root)
            _ = try git.runGit(["add", "-A"], at: root)
            try git.commit("\(name.uppercased())_ONLY_ELECTION_SUBJECT", at: root)
            _ = try git.runGit(["branch", "-m", "\(name)-main"], at: root)
            try git.write("tracked\nchanged\n", to: "\(name)-marker.txt", at: root)
        }
    }
#endif
