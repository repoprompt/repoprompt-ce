import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class ContextBuilderSelectionTransactionTests: XCTestCase {
    func testNamedTabKeepsItsNameAfterTasknamePromptMutation() async throws {
        for name in ["Care", "New Chat about support", "Untitled Chat about support"] {
            let fixture = try await makeFixture(name: "named-taskname")
            defer { fixture.cleanup() }
            fixture.window.promptManager.renameComposeTab(fixture.tabID, to: "T17")
            _ = try fixture.installContext(selection: .init())

            // An explicit rename after discovery captured its context must win over that snapshot.
            fixture.window.agentModeViewModel.renameSession(tabID: fixture.tabID, to: name)
            let prompt = "<taskname=\"Support ticket activity MCP plan\"/>\n<task>Plan support activity</task>"
            try await ServerNetworkManager.$currentConnectionID.withValue(fixture.connectionID) {
                try await fixture.window.mcpServer.updateCurrentTabContext(toolName: "prompt") {
                    $0.promptText = prompt
                }
            }

            let storedTab = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
            XCTAssertEqual(storedTab.name, name)
            XCTAssertEqual(storedTab.promptText, prompt)
            XCTAssertEqual(fixture.boundContext?.promptText, prompt)
            XCTAssertEqual(fixture.window.promptManager.currentComposeTabs.first { $0.id == fixture.tabID }?.name, name)
            XCTAssertEqual(fixture.window.agentModeViewModel.resolvedSessionDisplayName(for: fixture.tabID), name)
        }
    }

    func testChatPlaceholderTabGetsNamedAfterTasknamePromptMutation() async throws {
        try await assertTasknameNamesDefaultTabs(named: ["New Chat", "Untitled Chat", "Untitled", "  new   CHAT\n"])
    }

    func testEmptyTabGetsNamedAfterTasknamePromptMutation() async throws {
        try await assertTasknameNamesDefaultTabs(named: ["", " \n\t"])
    }

    private func assertTasknameNamesDefaultTabs(named names: [String]) async throws {
        for name in names {
            let fixture = try await makeFixture(name: "placeholder-taskname", tabName: name)
            defer { fixture.cleanup() }
            XCTAssertEqual(fixture.window.workspaceManager.composeTab(for: fixture.identity)?.name, name)
            _ = try fixture.installContext(selection: .init())
            let prompt = "<taskname=\"Support   ticket activity MCP plan\"/>\n<task>Plan support activity</task>"
            try await ServerNetworkManager.$currentConnectionID.withValue(fixture.connectionID) {
                try await fixture.window.mcpServer.updateCurrentTabContext(toolName: "prompt") {
                    $0.promptText = prompt
                }
            }

            let expectedName = "Support ticket activity MCP plan"
            let storedTab = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
            XCTAssertEqual(storedTab.name, expectedName, "Original title: \(String(reflecting: name))")
            XCTAssertEqual(storedTab.promptText, prompt)
            XCTAssertEqual(fixture.boundContext?.promptText, prompt)
            XCTAssertEqual(fixture.window.promptManager.currentComposeTabs.first { $0.id == fixture.tabID }?.name, expectedName)
            XCTAssertEqual(fixture.window.agentModeViewModel.resolvedSessionDisplayName(for: fixture.tabID), expectedName)
        }
    }

    func testDefaultTabGetsNamedAfterTasknamePromptMutation() async throws {
        try await assertTasknameNamesDefaultTabs(named: ["T17"])
    }

    /// A headless client (for example Devin) may restart its stdio MCP child mid-run. The successor
    /// re-matches the settlement-retained discovery policy after the pending context was already
    /// consumed, so it must inherit the displaced connection's live run context.
    func testPendingPolicyReplacementInheritsDisplacedDiscoveryContext() async throws {
        let fixture = try await makeFixture(name: "replacement-handover")
        defer { fixture.cleanup() }
        let initialSelection = StoredSelection(selectedPaths: [fixture.fileA.path])
        try await fixture.seedCanonical(initialSelection)
        let server = fixture.window.mcpServer
        try server.installFrozenTabContext(
            clientID: nil,
            clientName: "devin",
            context: fixture.makeContext(selection: initialSelection)
        )
        XCTAssertNotNil(server.registerPendingPolicyRunIDMapping(
            connectionID: fixture.connectionID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "devin"
        ))
        let discoveredSelection = StoredSelection(selectedPaths: [fixture.fileB.path])
        server.tabContextByConnectionID[fixture.connectionID]?.selection = discoveredSelection

        let successorID = UUID()
        let token = try XCTUnwrap(server.registerPendingPolicyRunIDMapping(
            connectionID: successorID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "devin"
        ))
        XCTAssertEqual(token.displacedConnectionID, fixture.connectionID)
        XCTAssertEqual(server.tabContextByConnectionID[successorID]?.runID, fixture.runID)
        XCTAssertEqual(server.tabContextByConnectionID[successorID]?.selection, discoveredSelection)

        // The displaced connection is then torn down as a replacement, not a discovery EOF.
        XCTAssertFalse(server.detachContextBuilderTabContextForDiscoveryTeardown(
            connectionID: fixture.connectionID,
            runID: fixture.runID
        ))
        server.removeTabContext(
            forConnectionID: fixture.connectionID,
            clientName: "devin",
            windowID: fixture.window.windowID,
            runID: nil
        )

        XCTAssertEqual(server.contextBuilderFinalContextConnectionID(runID: fixture.runID), successorID)
        let result = await server.commitContextBuilderTabContext(
            connectionID: successorID,
            expectedRunID: fixture.runID,
            isStillCurrent: { true }
        )
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.committedTab?.tab.selection, discoveredSelection)
    }

    func testRolledBackPendingPolicyReplacementKeepsDisplacedDiscoveryContext() async throws {
        let storageRoot = try makeTestDirectory(name: "DiscoveryHandoffRollback")
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app,
            profileIdentifier: "discovery-handoff-\(UUID().uuidString)",
            storageDirectory: storageRoot.appendingPathComponent("runtime-state"),
            workspaceStorageDirectory: storageRoot,
            eventDirectory: storageRoot.appendingPathComponent("events"),
            temporaryDirectory: storageRoot.appendingPathComponent("tmp"),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock { _ = await runtime.shutdown() }
        let fixture = try await makeFixture(name: "replacement-rollback", domainRuntime: runtime)
        defer { fixture.cleanup() }
        let selection = StoredSelection(selectedPaths: [fixture.fileA.path])
        let server = fixture.window.mcpServer
        try server.installFrozenTabContext(clientID: nil, clientName: "devin", context: fixture.makeContext(selection: selection))
        XCTAssertNotNil(server.registerPendingPolicyRunIDMapping(
            connectionID: fixture.connectionID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "devin"
        ))
        let successorID = UUID()
        let token = try XCTUnwrap(server.registerPendingPolicyRunIDMapping(
            connectionID: successorID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "devin"
        ))

        await server.domainRoutingPublishTask?.value
        XCTAssertNotNil(server.tabContextCancellablesByConnectionID[successorID])
        let coordinator = try XCTUnwrap(server.domainRoutingCoordinator)
        let beforeRollback = await coordinator.snapshot()
        XCTAssertTrue(beforeRollback.connections.contains { $0.registration.connectionID == successorID })

        XCTAssertEqual(
            server.rollbackPendingPolicyRunIDMapping(
                token,
                clientName: "devin",
                windowID: fixture.window.windowID,
                signalRoutingFailure: false
            ),
            .restored
        )

        // Rollback drops only the successor's inherited copy; the displaced snapshot is untouched.
        await server.domainRoutingPublishTask?.value
        let afterRollback = await coordinator.snapshot()
        XCTAssertFalse(afterRollback.connections.contains { $0.registration.connectionID == successorID })
        XCTAssertTrue(afterRollback.connections.contains { $0.registration.connectionID == fixture.connectionID })
        XCTAssertNil(server.tabContextCancellablesByConnectionID[successorID])
        XCTAssertNil(server.tabContextByConnectionID[successorID])
        XCTAssertEqual(fixture.boundContext?.runID, fixture.runID)
        XCTAssertEqual(fixture.boundContext?.selection, selection)
        XCTAssertEqual(server.pendingContextQueueLength(clientName: "devin", windowID: fixture.window.windowID), 0)
    }

    func testDiscoveryRoutingErrorDoesNotSuggestDisabledBindContext() {
        XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains("bind_context"))
        let message = MCPServerViewModel.tabContextRoutingErrorMessage(toolName: "git", runPurpose: .discoverRun)
        XCTAssertTrue(message.contains("No tab context is bound for git"))
        XCTAssertFalse(message.contains("bind_context"))
        XCTAssertTrue(MCPServerViewModel.tabContextRoutingErrorMessage(toolName: "git").contains("bind_context"))
    }

    func testContextBuilderToolMutationPublishesCanonicalSelectionImmediately() async throws {
        let fixture = try await makeFixture(name: "immediate")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        let verification = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )

        XCTAssertTrue(verification?.isVerified == true)
        XCTAssertEqual(verification?.canonicalSelection, discovered)
        XCTAssertEqual(fixture.canonicalSelection, discovered)
        XCTAssertEqual(fixture.boundContext?.selection, discovered)
    }

    func testSuccessfulEarlierToolMutationSurvivesLaterDiscoveryFailure() async throws {
        let fixture = try await makeFixture(name: "failure")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        _ = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )
        fixture.window.mcpServer.removeTabContext(
            forConnectionID: fixture.connectionID,
            clientName: nil,
            windowID: fixture.window.windowID,
            runID: fixture.runID
        )
        let failedCommit = await fixture.window.mcpServer.commitContextBuilderTabContext(
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            isStillCurrent: { true }
        )

        guard case .missingFinalContext = failedCommit.outcome else {
            return XCTFail("Expected the failed discovery to have no terminal context")
        }
        XCTAssertEqual(fixture.canonicalSelection, discovered)
    }

    func testContextBuilderAndOrdinaryAgentMutationsUseSameCanonicalPath() async throws {
        let fixture = try await makeFixture(name: "shared-path")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let first = StoredSelection(selectedPaths: [fixture.fileB.path])
        let second = StoredSelection(selectedPaths: [fixture.fileC.path])
        try await fixture.seedCanonical(source)

        let contextBuilderContext = try fixture.installContext(selection: source)
        let firstVerification = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: contextBuilderContext.withSelection(first)),
            metadata: fixture.metadata,
            mutated: true
        )
        let ordinaryAgentContext = try XCTUnwrap(fixture.boundContext)
        let secondVerification = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: ordinaryAgentContext.withSelection(second)),
            metadata: fixture.metadata,
            mutated: true
        )

        XCTAssertEqual(firstVerification?.canonicalSelection, first)
        XCTAssertEqual(secondVerification?.canonicalSelection, second)
        XCTAssertEqual(fixture.canonicalSelection, second)
    }

    func testDeferredUISnapshotCannotClobberImmediateCanonicalPublication() async throws {
        let fixture = try await makeFixture(name: "ui-fence")
        defer { fixture.cleanup() }
        await fixture.window.promptManager.switchComposeTab(fixture.tabID)
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        _ = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )

        XCTAssertEqual(
            fixture.window.selectionCoordinator.selectionForActiveUISnapshot(
                source,
                tabID: fixture.tabID
            ),
            discovered,
            "A UI snapshot queued before the tool mutation must not revoke canonical selection"
        )
        XCTAssertEqual(fixture.canonicalSelection, discovered)
    }

    func testOraclePackagingObservesImmediateCanonicalContextBuilderSelection() async throws {
        let fixture = try await makeFixture(name: "oracle-packaging")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        _ = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )

        let stabilized = await fixture.window.mcpServer.stabilizedVirtualContext(for: context)
        let packaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: stabilized.tabID,
            sourceWorkspaceID: stabilized.workspaceID,
            sourceSelectionRevision: stabilized.selectionRevision,
            sourceAgentSessionID: stabilized.activeAgentSessionID,
            sourceAgentRunID: stabilized.runID,
            promptText: stabilized.promptText,
            selection: stabilized.selection,
            lookupContext: stabilized.frozenLookupContext,
            reviewGitContext: .automaticOnly(base: "HEAD"),
            provenance: .direct
        )

        XCTAssertEqual(packaging.selection, discovered)
        XCTAssertFalse(packaging.selection.selectedPaths.contains(fixture.fileA.path))
    }

    func testTerminalCommitPreservesNewerCanonicalSelection() async throws {
        let fixture = try await makeFixture(name: "terminal-fence")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let newer = StoredSelection(selectedPaths: [fixture.fileC.path])
        try await fixture.seedCanonical(source)
        let staleRunContext = try fixture.installContext(selection: source)

        _ = await fixture.window.selectionCoordinator.persistSelection(
            newer,
            for: fixture.identity,
            source: .runtimeMutation,
            mirrorToUIIfActive: false
        )
        fixture.window.mcpServer.tabContextByConnectionID[fixture.connectionID] = staleRunContext

        let result = await fixture.window.mcpServer.commitContextBuilderTabContext(
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            isStillCurrent: { true }
        )

        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.committedTab?.tab.selection, newer)
        XCTAssertEqual(fixture.canonicalSelection, newer)
    }

    private func makeFixture(name: String, tabName: String? = nil, domainRuntime: MCPDomainRuntime? = nil) async throws -> Fixture {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = if let domainRuntime { WindowState(domainRuntime: domainRuntime) } else { WindowState() }
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        WindowStatesManager.shared.registerWindowState(window)
        await window.workspaceManager.awaitInitialized()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderSelectionTransactionTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = ["A.swift", "B.swift", "C.swift"].map { root.appendingPathComponent($0) }
        for file in files {
            try "// \(file.lastPathComponent)".write(to: file, atomically: true, encoding: .utf8)
        }
        let workspace = window.workspaceManager.createWorkspace(name: name, repoPaths: [root.path], ephemeral: true)
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: name)
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
        let backgroundTab = await window.promptManager.createBackgroundComposeTab(
            strategy: .blank,
            name: tabName ?? "Transaction \(name)"
        )
        let tabID = try XCTUnwrap(backgroundTab?.id)
        return Fixture(
            window: window,
            root: root,
            workspaceID: workspaceID,
            tabID: tabID,
            fileA: files[0],
            fileB: files[1],
            fileC: files[2]
        )
    }
}

@MainActor
private struct Fixture {
    let window: WindowState
    let root: URL
    let workspaceID: UUID
    let tabID: UUID
    let fileA: URL
    let fileB: URL
    let fileC: URL
    let connectionID = UUID()
    let runID = UUID()

    var identity: WorkspaceSelectionIdentity {
        .init(workspaceID: workspaceID, tabID: tabID)
    }

    var metadata: MCPServerViewModel.RequestMetadata {
        .init(connectionID: connectionID, clientName: "selection-transaction-test", windowID: window.windowID)
    }

    var canonicalSelection: StoredSelection? {
        window.workspaceManager.composeTab(for: identity)?.selection
    }

    var boundContext: MCPServerViewModel.TabContextSnapshot? {
        window.mcpServer.tabContextByConnectionID[connectionID]
    }

    func seedCanonical(_ selection: StoredSelection) async throws {
        _ = await window.selectionCoordinator.persistSelection(
            selection,
            for: identity,
            source: .runtimeMutation,
            mirrorToUIIfActive: false
        )
        XCTAssertEqual(canonicalSelection, selection)
    }

    func installContext(selection: StoredSelection) throws -> MCPServerViewModel.TabContextSnapshot {
        let context = try makeContext(selection: selection)
        window.mcpServer.tabContextByConnectionID[connectionID] = context
        return context
    }

    func makeContext(selection: StoredSelection) throws -> MCPServerViewModel.TabContextSnapshot {
        let tab = try XCTUnwrap(window.workspaceManager.composeTab(for: identity))
        return MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: window.windowID,
            workspaceID: workspaceID,
            promptText: tab.promptText,
            selection: selection,
            selectionRevision: window.workspaceManager.selectionRevisionForMCP(
                workspaceID: workspaceID,
                tabID: tabID
            ),
            selectedMetaPromptIDs: tab.selectedMetaPromptIDs,
            selectedContextBuilderPromptIDs: tab.contextBuilder.selectedContextBuilderPromptIDs,
            tabName: tab.name,
            runID: runID,
            explicitlyBound: false
        )
    }

    func cleanup() {
        WindowStatesManager.shared.unregisterWindowState(window)
        try? FileManager.default.removeItem(at: root)
    }
}

private extension MCPServerViewModel.TabContextSnapshot {
    func withSelection(_ selection: StoredSelection) -> Self {
        var copy = self
        copy.selection = selection
        return copy
    }
}
