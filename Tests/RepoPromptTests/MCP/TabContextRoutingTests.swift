import Combine
import Foundation
import MCP
@testable import RepoPrompt
import XCTest

final class TabContextRoutingTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testBindingResolverResolvesExplicitContextIDAndLegacyTabIDAlias() async throws {
        let contextID = UUID()
        let workspaceID = UUID()
        let explicitResolver = makeResolver(matchesByContextID: [
            contextID: [match(windowID: 7, tabID: contextID, workspaceID: workspaceID, roots: ["/tmp/project"])]
        ])

        let explicit = try await explicitResolver.resolveLogicalContextBinding(
            connectionID: UUID(),
            explicitContextID: contextID,
            legacyTabID: nil,
            workingDirs: [],
            requestedWindowID: nil
        )

        XCTAssertEqual(explicit?.logicalContext.tabID, contextID)
        XCTAssertEqual(explicit?.logicalContext.workspaceID, workspaceID)
        XCTAssertEqual(explicit?.windowID, 7)

        let tabID = UUID()
        let legacyWorkspaceID = UUID()
        let legacyResolver = makeResolver(matchesByContextID: [
            tabID: [match(windowID: 3, tabID: tabID, workspaceID: legacyWorkspaceID)]
        ])

        let legacy = try await legacyResolver.resolveLogicalContextBinding(
            connectionID: UUID(),
            explicitContextID: nil,
            legacyTabID: tabID,
            workingDirs: [],
            requestedWindowID: nil
        )

        XCTAssertEqual(legacy?.logicalContext.tabID, tabID)
        XCTAssertEqual(legacy?.logicalContext.workspaceID, legacyWorkspaceID)
        XCTAssertEqual(legacy?.windowID, 3)
    }

    func testBindingResolverUsesRequestedWindowIDToDisambiguateMultiWindowContext() async throws {
        let contextID = UUID()
        let workspaceID = UUID()
        let resolver = makeResolver(matchesByContextID: [
            contextID: [
                match(windowID: 1, tabID: contextID, workspaceID: workspaceID),
                match(windowID: 2, tabID: contextID, workspaceID: workspaceID)
            ]
        ])

        let resolved = try await resolver.resolveLogicalContextBinding(
            connectionID: UUID(),
            explicitContextID: contextID,
            legacyTabID: nil,
            workingDirs: [],
            requestedWindowID: 2
        )

        XCTAssertEqual(resolved?.windowID, 2)
        XCTAssertEqual(resolved?.logicalContext.windowIDs, [1, 2])
    }

    func testBindingResolverRejectsMultiWindowContextWithoutWindowDisambiguation() async {
        let contextID = UUID()
        let workspaceID = UUID()
        let resolver = makeResolver(matchesByContextID: [
            contextID: [
                match(windowID: 1, tabID: contextID, workspaceID: workspaceID),
                match(windowID: 2, tabID: contextID, workspaceID: workspaceID)
            ]
        ])

        await XCTAssertThrowsErrorAsync({
            try await resolver.resolveLogicalContextBinding(
                connectionID: UUID(),
                explicitContextID: contextID,
                legacyTabID: nil,
                workingDirs: [],
                requestedWindowID: nil
            )
        }) { error in
            XCTAssertTrue(String(describing: error).contains("multiple windows"), String(describing: error))
            XCTAssertTrue(String(describing: error).contains("_windowID"), String(describing: error))
        }
    }

    func testBindingResolverRejectsConflictingContextIDAndLegacyTabID() async {
        let resolver = makeResolver(matchesByContextID: [:])

        await XCTAssertThrowsErrorAsync({
            try await resolver.resolveLogicalContextBinding(
                connectionID: UUID(),
                explicitContextID: UUID(),
                legacyTabID: UUID(),
                workingDirs: [],
                requestedWindowID: nil
            )
        }) { error in
            XCTAssertTrue(String(describing: error).contains("Conflicting binding identifiers"), String(describing: error))
        }
    }

    @MainActor
    func testPendingRunScopedStoreRequiresExactRunHint() {
        var store = MCPServerViewModel.PendingRunScopedContextStore()
        let runID = UUID()
        let wrongRunID = UUID()
        let context = makeTabContext(runID: runID, windowID: 11)
        XCTAssertEqual(store.enqueueReplacing(context, clientName: "agent", windowID: 11), 1)

        let runless = MCPServerViewModel.test_popPendingContextForBinding(
            from: &store,
            clientName: "agent",
            windowID: 11,
            runHint: nil
        )
        XCTAssertNil(runless.context)
        XCTAssertFalse(runless.usedRunHint)
        XCTAssertEqual(runless.remaining, 1)

        let wrong = MCPServerViewModel.test_popPendingContextForBinding(
            from: &store,
            clientName: "agent",
            windowID: 11,
            runHint: wrongRunID
        )
        XCTAssertNil(wrong.context)
        XCTAssertFalse(wrong.usedRunHint)
        XCTAssertEqual(wrong.remaining, 1)

        let exact = MCPServerViewModel.test_popPendingContextForBinding(
            from: &store,
            clientName: "agent",
            windowID: 11,
            runHint: runID
        )
        XCTAssertEqual(exact.context?.runID, runID)
        XCTAssertTrue(exact.usedRunHint)
        XCTAssertEqual(exact.remaining, 0)
    }

    func testRunHandoverRequiresExactForwardAndReverseMapping() {
        let runID = UUID()
        let connectionID = UUID()

        XCTAssertEqual(
            MCPServerViewModel.test_liveConnectionID(
                forRunID: runID,
                connectionIDByRunID: [runID: connectionID],
                connectionIDToRunID: [connectionID: runID]
            ),
            connectionID
        )
        XCTAssertNil(MCPServerViewModel.test_liveConnectionID(
            forRunID: runID,
            connectionIDByRunID: [runID: connectionID],
            connectionIDToRunID: [:]
        ))
        XCTAssertNil(MCPServerViewModel.test_liveConnectionID(
            forRunID: runID,
            connectionIDByRunID: [runID: connectionID],
            connectionIDToRunID: [connectionID: UUID()]
        ))
    }

    @MainActor
    func testPendingPolicyReadSelectionLineagePreservesRapidReplacementOrder() throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let runID = UUID()
        let unrelatedRunID = UUID()
        let workspaceID = UUID()
        let tabID = UUID()
        let firstConnectionID = UUID()
        let secondConnectionID = UUID()
        let thirdConnectionID = UUID()
        let unrelatedConnectionID = UUID()
        let snapshot = ComposeTabState(id: tabID, name: "Agent")

        window.mcpServer.installTabContext(
            clientID: firstConnectionID.uuidString,
            clientName: "agent",
            windowID: window.windowID,
            workspaceID: workspaceID,
            snapshot: snapshot,
            runID: runID,
            signalRouting: false
        )
        window.mcpServer.installTabContext(
            clientID: unrelatedConnectionID.uuidString,
            clientName: "agent",
            windowID: window.windowID,
            workspaceID: workspaceID,
            snapshot: snapshot,
            runID: unrelatedRunID,
            signalRouting: false
        )
        let secondToken = try XCTUnwrap(window.mcpServer.installTabContext(
            clientID: secondConnectionID.uuidString,
            clientName: "agent",
            windowID: window.windowID,
            workspaceID: workspaceID,
            snapshot: snapshot,
            runID: runID,
            signalRouting: false,
            deferRunIDReplacementForPendingPolicy: true
        ))
        XCTAssertEqual(
            window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                connectionID: secondConnectionID
            ),
            [firstConnectionID]
        )
        let thirdToken = try XCTUnwrap(window.mcpServer.installTabContext(
            clientID: thirdConnectionID.uuidString,
            clientName: "agent",
            windowID: window.windowID,
            workspaceID: workspaceID,
            snapshot: snapshot,
            runID: runID,
            signalRouting: false,
            deferRunIDReplacementForPendingPolicy: true
        ))

        XCTAssertEqual(secondToken.displacedConnectionID, firstConnectionID)
        XCTAssertEqual(thirdToken.displacedConnectionID, secondConnectionID)
        XCTAssertTrue(
            window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                connectionID: secondConnectionID
            ).isEmpty
        )
        XCTAssertEqual(
            window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                connectionID: thirdConnectionID
            ),
            [firstConnectionID, secondConnectionID]
        )
        XCTAssertFalse(
            window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                connectionID: thirdConnectionID
            ).contains(unrelatedConnectionID)
        )
    }

    @MainActor
    func testPendingPolicyReadSelectionLineageSurvivesSameConnectionTokenSupersession() throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let runID = UUID()
        let workspaceID = UUID()
        let tabID = UUID()
        let firstConnectionID = UUID()
        let secondConnectionID = UUID()
        let snapshot = ComposeTabState(id: tabID, name: "Agent")

        window.mcpServer.installTabContext(
            clientID: firstConnectionID.uuidString,
            clientName: "agent",
            windowID: window.windowID,
            workspaceID: workspaceID,
            snapshot: snapshot,
            runID: runID,
            signalRouting: false
        )
        _ = try XCTUnwrap(window.mcpServer.installTabContext(
            clientID: secondConnectionID.uuidString,
            clientName: "agent",
            windowID: window.windowID,
            workspaceID: workspaceID,
            snapshot: snapshot,
            runID: runID,
            signalRouting: false,
            deferRunIDReplacementForPendingPolicy: true
        ))
        XCTAssertEqual(
            window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                connectionID: secondConnectionID
            ),
            [firstConnectionID]
        )

        let supersedingToken = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
            connectionID: secondConnectionID,
            runID: runID,
            windowID: window.windowID
        ))
        XCTAssertNil(supersedingToken.displacedConnectionID)
        XCTAssertEqual(supersedingToken.displacedConnectionRunID, runID)
        XCTAssertEqual(
            window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                connectionID: secondConnectionID
            ),
            [firstConnectionID]
        )

        var staleGenerationContext = try XCTUnwrap(
            window.mcpServer.tabContextByConnectionID[secondConnectionID]
        )
        staleGenerationContext.readFileAutoSelectionGeneration &+= 1
        window.mcpServer.tabContextByConnectionID[secondConnectionID] = staleGenerationContext
        _ = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
            connectionID: secondConnectionID,
            runID: runID,
            windowID: window.windowID
        ))
        XCTAssertTrue(
            window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                connectionID: secondConnectionID
            ).isEmpty
        )
    }

    @MainActor
    func testPendingPolicyReadSelectionLineageRejectsStaleDisplacedReverseOwner() throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let runID = UUID()
        let otherRunID = UUID()
        let workspaceID = UUID()
        let tabID = UUID()
        let firstConnectionID = UUID()
        let secondConnectionID = UUID()
        let snapshot = ComposeTabState(id: tabID, name: "Agent")

        window.mcpServer.installTabContext(
            clientID: firstConnectionID.uuidString,
            clientName: "agent",
            windowID: window.windowID,
            workspaceID: workspaceID,
            snapshot: snapshot,
            runID: runID,
            signalRouting: false
        )
        _ = try XCTUnwrap(window.mcpServer.installTabContext(
            clientID: secondConnectionID.uuidString,
            clientName: "agent",
            windowID: window.windowID,
            workspaceID: workspaceID,
            snapshot: snapshot,
            runID: runID,
            signalRouting: false,
            deferRunIDReplacementForPendingPolicy: true
        ))
        XCTAssertEqual(
            window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                connectionID: secondConnectionID
            ),
            [firstConnectionID]
        )

        window.mcpServer.connectionIDByRunID[runID] = firstConnectionID
        window.mcpServer.connectionIDByRunID[otherRunID] = firstConnectionID
        window.mcpServer.connectionIDToRunID[firstConnectionID] = otherRunID
        let staleOwnerToken = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
            connectionID: secondConnectionID,
            runID: runID,
            windowID: window.windowID
        ))

        XCTAssertEqual(staleOwnerToken.displacedConnectionID, firstConnectionID)
        XCTAssertEqual(staleOwnerToken.displacedConnectionRunID, otherRunID)
        XCTAssertTrue(
            window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                connectionID: secondConnectionID
            ).isEmpty
        )
    }

    @MainActor
    func testPendingPolicyReadSelectionLineageRejectsCrossTabAndWorkspaceDisplacement() throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let runID = UUID()
        let firstConnectionID = UUID()
        let crossTabConnectionID = UUID()
        let crossWorkspaceConnectionID = UUID()
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let firstTabID = UUID()
        let secondTabID = UUID()

        window.mcpServer.installTabContext(
            clientID: firstConnectionID.uuidString,
            clientName: "agent",
            windowID: window.windowID,
            workspaceID: firstWorkspaceID,
            snapshot: ComposeTabState(id: firstTabID, name: "First"),
            runID: runID,
            signalRouting: false
        )
        _ = try XCTUnwrap(window.mcpServer.installTabContext(
            clientID: crossTabConnectionID.uuidString,
            clientName: "agent",
            windowID: window.windowID,
            workspaceID: firstWorkspaceID,
            snapshot: ComposeTabState(id: secondTabID, name: "Second"),
            runID: runID,
            signalRouting: false,
            deferRunIDReplacementForPendingPolicy: true
        ))
        _ = try XCTUnwrap(window.mcpServer.installTabContext(
            clientID: crossWorkspaceConnectionID.uuidString,
            clientName: "agent",
            windowID: window.windowID,
            workspaceID: secondWorkspaceID,
            snapshot: ComposeTabState(id: secondTabID, name: "Second Workspace"),
            runID: runID,
            signalRouting: false,
            deferRunIDReplacementForPendingPolicy: true
        ))

        XCTAssertTrue(
            window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                connectionID: crossTabConnectionID
            ).isEmpty
        )
        XCTAssertTrue(
            window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                connectionID: crossWorkspaceConnectionID
            ).isEmpty
        )
    }

    func testActiveTabCompatibilityDecisionAllowsOnlyLegacyNonRunScopedCallers() {
        XCTAssertEqual(
            MCPServerViewModel.activeTabCompatibilityFallbackDecision(
                policy: .allowLegacyImplicitRouting,
                fallbackEnabled: true,
                hasRunScopedContext: false,
                runPurpose: .unknown
            ),
            .allowed
        )
        XCTAssertEqual(
            MCPServerViewModel.activeTabCompatibilityFallbackDecision(
                policy: .allowLegacyImplicitRouting,
                fallbackEnabled: false,
                hasRunScopedContext: false,
                runPurpose: .unknown
            ),
            .disabled
        )
        XCTAssertEqual(
            MCPServerViewModel.activeTabCompatibilityFallbackDecision(
                policy: .requireExplicitOrRunScoped,
                fallbackEnabled: true,
                hasRunScopedContext: false,
                runPurpose: .unknown
            ),
            .notAllowedByPolicy
        )
        XCTAssertEqual(
            MCPServerViewModel.activeTabCompatibilityFallbackDecision(
                policy: .allowLegacyImplicitRouting,
                fallbackEnabled: true,
                hasRunScopedContext: true,
                runPurpose: .unknown
            ),
            .prohibitedForRunScoped(.unknown)
        )
        XCTAssertEqual(
            MCPServerViewModel.activeTabCompatibilityFallbackDecision(
                policy: .allowActiveTabCompatibility,
                fallbackEnabled: true,
                hasRunScopedContext: false,
                runPurpose: .agentModeRun
            ),
            .prohibitedForRunScoped(.agentModeRun)
        )
    }

    func testDisabledActiveTabCompatibilityGuidanceMentionsBindContext() {
        let message = MCPServerViewModel.activeTabCompatibilityDisabledMessage(toolName: "workspace_context")
        XCTAssertTrue(message.contains("bind_context"), message)
        XCTAssertTrue(message.contains("context_id"), message)
        XCTAssertTrue(message.contains("disabled"), message)
    }

    func testAgentModeRoutingRecoveryDoesNotRecommendRejectedExplicitContextOverrides() {
        for message in [
            MCPServerViewModel.tabContextRoutingErrorMessage(
                toolName: "context_builder",
                runPurpose: .agentModeRun
            ),
            MCPServerViewModel.runScopedActiveTabCompatibilityMessage(
                toolName: "context_builder",
                runPurpose: .agentModeRun
            )
        ] {
            XCTAssertTrue(message.contains("Retry"), message)
            XCTAssertTrue(message.contains("restart this Agent Mode run"), message)
            XCTAssertFalse(message.contains("bind_context"), message)
            XCTAssertFalse(message.contains("context_id"), message)
        }

        let ordinary = MCPServerViewModel.tabContextRoutingErrorMessage(
            toolName: "workspace_context",
            runPurpose: .unknown
        )
        XCTAssertTrue(ordinary.contains("bind_context"), ordinary)
        XCTAssertTrue(ordinary.contains("context_id"), ordinary)
    }

    func testConnectionManagerRoutingPoliciesKeepRunScopedToolsOutOfLegacyGenericBinding() {
        XCTAssertFalse(ServerNetworkManager.shouldUseGenericTabBindingCompatibility(for: "agent_run"))
        XCTAssertFalse(ServerNetworkManager.shouldUseGenericTabBindingCompatibility(for: "ask_oracle"))
        XCTAssertFalse(ServerNetworkManager.shouldUseGenericTabBindingCompatibility(for: "context_builder"))
        XCTAssertTrue(ServerNetworkManager.shouldUseGenericTabBindingCompatibility(for: "legacy_tool"))
        XCTAssertTrue(ServerNetworkManager.shouldRehydrateContextID(for: "context_builder"))
        XCTAssertTrue(ServerNetworkManager.shouldRehydrateLegacyTabID(for: "context_builder"))
    }

    func testConnectionManagerSkipsRoutinePerCallRunScopedTabRebindFallbackOnlyForCanonicalAgentModeLookups() {
        for toolName in ["read_file", "file_search"] {
            XCTAssertTrue(ServerNetworkManager.shouldSkipPerCallRunScopedTabRebindFallback(
                toolName: toolName,
                purpose: .agentModeRun
            ))
        }

        for toolName in ["workspace_context", "agent_run"] {
            XCTAssertFalse(ServerNetworkManager.shouldSkipPerCallRunScopedTabRebindFallback(
                toolName: toolName,
                purpose: .agentModeRun
            ))
        }

        for purpose in [MCPRunPurpose.discoverRun, .unknown] {
            for toolName in ["read_file", "file_search", "workspace_context", "agent_run"] {
                XCTAssertFalse(ServerNetworkManager.shouldSkipPerCallRunScopedTabRebindFallback(
                    toolName: toolName,
                    purpose: purpose
                ))
            }
        }

        XCTAssertTrue(ServerNetworkManager.shouldUseGenericTabBindingCompatibility(for: "legacy_tool"))
        XCTAssertTrue(ServerNetworkManager.shouldInjectLegacyTabIDForCompatibility(for: "context_builder"))
        XCTAssertFalse(ServerNetworkManager.shouldUseGenericTabBindingCompatibility(for: "workspace_context"))
    }

    func testBindContextParticipatesInHiddenWindowRoutingWithoutImplicitPublicInjection() {
        XCTAssertFalse(ServerNetworkManager.shouldBypassWindowRouting(for: "bind_context"))
        XCTAssertFalse(ServerNetworkManager.shouldAutoInjectPublicWindowID(for: "bind_context"))
        XCTAssertTrue(ServerNetworkManager.shouldRehydrateExplicitWindowID(for: "bind_context"))
        XCTAssertTrue(ServerNetworkManager.isWindowSelectionExempt(toolName: "bind_context", args: ["op": .string("list")]))
        XCTAssertTrue(ServerNetworkManager.shouldBypassLogicalContextPreResolution(for: "bind_context"))
    }

    func testMigratedToolContextPreResolutionPersistsWindowAffinity() {
        XCTAssertFalse(ServerNetworkManager.shouldUseGenericTabBindingCompatibility(for: "workspace_context"))
        XCTAssertFalse(ServerNetworkManager.shouldUseGenericTabBindingCompatibility(for: "manage_selection"))
        XCTAssertTrue(ServerNetworkManager.shouldPersistResolvedLogicalContextWindowMapping(for: "workspace_context"))
        XCTAssertTrue(ServerNetworkManager.shouldPersistResolvedLogicalContextWindowMapping(for: "manage_selection"))
        XCTAssertFalse(ServerNetworkManager.shouldRehydrateContextID(for: "workspace_context"))
        XCTAssertFalse(ServerNetworkManager.shouldRehydrateLegacyTabID(for: "workspace_context"))
        XCTAssertFalse(ServerNetworkManager.shouldPersistResolvedLogicalContextWindowMapping(for: AppSettingsMCPService.toolName))
    }

    func testRunlessBindingReleasePreservesOrDropsConnectionRunHintAccordingToPolicy() {
        for preserveConnectionRunIDMapping in [true, false] {
            let connectionID = UUID()
            let pendingRunID = UUID()
            let result = MCPServerViewModel.runMappingsAfterBindingRelease(
                contextRunID: nil,
                connectionID: connectionID,
                connectionIDByRunID: [pendingRunID: connectionID],
                connectionIDToRunID: [connectionID: pendingRunID],
                preserveConnectionRunIDMapping: preserveConnectionRunIDMapping
            )

            XCTAssertEqual(result.connectionIDByRunID[pendingRunID], connectionID)
            if preserveConnectionRunIDMapping {
                XCTAssertEqual(result.connectionIDToRunID[connectionID], pendingRunID)
            } else {
                XCTAssertNil(result.connectionIDToRunID[connectionID])
            }
        }
    }

    @MainActor
    func testPersistResolvedTabContextSnapshotPublishesInactiveTabAndLogicalizesWorktreeSelection() async throws {
        let logicalRoot = try makeTemporaryDirectory(named: "logical-root")
        let worktreeRoot = try makeTemporaryDirectory(named: "worktree-root")
        try FileManager.default.createDirectory(
            at: logicalRoot.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: worktreeRoot.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "// app".write(to: worktreeRoot.appendingPathComponent("Sources/App.swift"), atomically: true, encoding: .utf8)
        try "// dependency".write(to: worktreeRoot.appendingPathComponent("Sources/Dependency.swift"), atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: logicalRoot.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: worktreeRoot.deletingLastPathComponent())
        }

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let activeTabID = UUID()
        let inactiveTabID = UUID()
        let activeSelection = StoredSelection(selectedPaths: [logicalRoot.appendingPathComponent("Sources/Active.swift").path])
        let inactiveInitialSelection = StoredSelection(selectedPaths: [logicalRoot.appendingPathComponent("Sources/Old.swift").path])
        let workspace = window.workspaceManager.createWorkspace(
            name: "Persist Resolved Tab Context \(UUID().uuidString.prefix(8))",
            repoPaths: [logicalRoot.path],
            ephemeral: true
        )
        let initialSwitchResult = await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "persistResolvedTabContextSnapshotTest"
        )
        XCTAssertEqual(initialSwitchResult, .switched)
        let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
        window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
            ComposeTabState(id: activeTabID, name: "Active", selection: activeSelection),
            ComposeTabState(id: inactiveTabID, name: "Agent", selection: inactiveInitialSelection)
        ]
        window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = activeTabID
        let tabReloadResult = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
            window.workspaceManager.workspaces[workspaceIndex],
            reason: "persistResolvedTabContextSnapshotTestTabs"
        )
        XCTAssertEqual(tabReloadResult, .switched)
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(in: window, path: logicalRoot.path)

        var changes: [WorkspaceSelectionCoordinator.Change] = []
        window.selectionCoordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let sessionID = UUID()
        let physicalSelection = StoredSelection(
            selectedPaths: [worktreeRoot.appendingPathComponent("Sources/App.swift").path],
            autoCodemapPaths: [worktreeRoot.appendingPathComponent("Sources/Dependency.swift").path],
            codemapAutoEnabled: false
        )
        let context = MCPServerViewModel.TabContextSnapshot(
            tabID: inactiveTabID,
            windowID: window.windowID,
            workspaceID: workspace.id,
            promptText: "agent prompt",
            selection: physicalSelection,
            selectedMetaPromptIDs: [],
            tabName: "Agent",
            runID: nil,
            activeAgentSessionID: sessionID,
            worktreeBindings: [
                makeWorktreeBinding(
                    logicalRoot: WorkspaceRootRef(id: UUID(), name: "logical-root", fullPath: logicalRoot.path),
                    physicalRoot: WorkspaceRootRef(id: UUID(), name: "logical-root", fullPath: worktreeRoot.path)
                )
            ],
            explicitlyBound: true
        )
        let resolved = MCPServerViewModel.ResolvedTabContextSnapshot(
            snapshot: context,
            usesActiveTabCompatibility: false
        )
        let activeSelectionBeforePersistence = try XCTUnwrap(window.workspaceManager.composeTab(with: activeTabID)?.selection)

        await window.mcpServer.persistResolvedTabContextSnapshot(
            resolved,
            metadata: MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: "test", windowID: window.windowID),
            mutated: true
        )

        let persistedInactiveSelection = try XCTUnwrap(window.workspaceManager.composeTab(with: inactiveTabID)?.selection)
        XCTAssertEqual(
            persistedInactiveSelection.selectedPaths,
            [logicalRoot.appendingPathComponent("Sources/App.swift").path]
        )
        XCTAssertEqual(
            persistedInactiveSelection.autoCodemapPaths,
            [logicalRoot.appendingPathComponent("Sources/Dependency.swift").path]
        )
        XCTAssertEqual(window.workspaceManager.composeTab(with: activeTabID)?.selection, activeSelectionBeforePersistence)
        XCTAssertEqual(
            changes.last,
            .init(tabID: inactiveTabID, selection: persistedInactiveSelection, source: .mcpTabContext)
        )
    }

    @MainActor
    func testExactSelectionPersistenceTargetsDuplicateTabInInactiveWorkspaceAndDirtiesOnlyTarget() async throws {
        let duplicateTabID = UUID()
        let activeSelection = StoredSelection(selectedPaths: ["/tmp/active-workspace.swift"])
        let targetSelection = StoredSelection(selectedPaths: ["/tmp/target-before.swift"])
        let nextSelection = StoredSelection(selectedPaths: ["/tmp/target-after.swift"])
        let activeWorkspace = WorkspaceModel(
            name: "Active Workspace",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [
                ComposeTabState(id: duplicateTabID, name: "Duplicate", selection: activeSelection)
            ],
            activeComposeTabID: duplicateTabID
        )
        let targetWorkspace = WorkspaceModel(
            name: "Inactive Target Workspace",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [
                ComposeTabState(id: duplicateTabID, name: "Duplicate", selection: targetSelection)
            ],
            activeComposeTabID: duplicateTabID
        )
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        window.workspaceManager.workspaces = [activeWorkspace, targetWorkspace]
        await window.workspaceManager.switchWorkspace(
            to: activeWorkspace,
            saveState: false,
            reason: "exactSelectionPersistenceTest"
        )
        let activeIdentity = WorkspaceSelectionIdentity(
            workspaceID: activeWorkspace.id,
            tabID: duplicateTabID
        )
        let targetIdentity = WorkspaceSelectionIdentity(
            workspaceID: targetWorkspace.id,
            tabID: duplicateTabID
        )
        var activeTab = try XCTUnwrap(window.workspaceManager.composeTab(for: activeIdentity))
        activeTab.selection = activeSelection
        XCTAssertTrue(
            window.workspaceManager.updateComposeTabStoredOnly(
                activeTab,
                inWorkspaceID: activeWorkspace.id
            )
        )
        var targetTab = try XCTUnwrap(window.workspaceManager.composeTab(for: targetIdentity))
        targetTab.selection = targetSelection
        XCTAssertTrue(
            window.workspaceManager.updateComposeTabStoredOnly(
                targetTab,
                inWorkspaceID: targetWorkspace.id
            )
        )
        let activeVersionBefore = window.workspaceManager.debugStateVersionForWorkspace(activeWorkspace.id)
        let targetVersionBefore = window.workspaceManager.debugStateVersionForWorkspace(targetWorkspace.id)

        _ = await window.selectionCoordinator.persistSelection(
            nextSelection,
            for: targetIdentity,
            source: .mcpTabContext,
            mirrorToUIIfActive: false
        )

        XCTAssertEqual(
            window.workspaceManager.composeTab(for: activeIdentity)?.selection,
            activeSelection
        )
        XCTAssertEqual(window.workspaceManager.composeTab(for: targetIdentity)?.selection, nextSelection)
        XCTAssertEqual(
            window.workspaceManager.debugStateVersionForWorkspace(activeWorkspace.id),
            activeVersionBefore
        )
        XCTAssertGreaterThan(
            window.workspaceManager.debugStateVersionForWorkspace(targetWorkspace.id),
            targetVersionBefore
        )
    }

    @MainActor
    func testDelayedPropagationDoesNotCrossPeerWindowReplacementOrReopen() async {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let sourceWindow = WindowState()
        let originalPeerWindow = WindowState()
        let reopenedPeerWindow = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        WindowStatesManager.shared.registerWindowState(sourceWindow)
        WindowStatesManager.shared.registerWindowState(originalPeerWindow)
        defer {
            WindowStatesManager.shared.unregisterWindowState(reopenedPeerWindow)
            WindowStatesManager.shared.unregisterWindowState(originalPeerWindow)
            WindowStatesManager.shared.unregisterWindowState(sourceWindow)
        }

        let workspaceID = UUID()
        let tabID = UUID()
        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let stale = StoredSelection(selectedPaths: ["/tmp/stale-pre-close.swift"])
        let reopenedCanonical = StoredSelection(selectedPaths: ["/tmp/reopened-canonical.swift"])
        await installSelectionWorkspace(
            in: sourceWindow,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: stale,
            name: "Source"
        )
        await installSelectionWorkspace(
            in: originalPeerWindow,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: initial,
            name: "Original Peer"
        )

        let registration = sourceWindow.workspaceManager.registerMCPSelectionSourceMutation(for: identity)
        XCTAssertEqual(
            registration.peerHostIDs,
            [originalPeerWindow.workspaceManager.mcpSelectionPropagationHostID]
        )

        originalPeerWindow.beginClose()
        WindowStatesManager.shared.unregisterWindowState(originalPeerWindow)
        await installSelectionWorkspace(
            in: reopenedPeerWindow,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: reopenedCanonical,
            name: "Reopened Peer"
        )
        WindowStatesManager.shared.registerWindowState(reopenedPeerWindow)

        await sourceWindow.workspaceManager.propagateMCPSelectionToPeerHosts(
            MCPSelectionPeerPropagation(
                identity: identity,
                selection: stale,
                sourceRevision: registration.sourceRevision,
                peerHostIDs: registration.peerHostIDs,
                mirrorToUIIfActive: true
            )
        )

        XCTAssertEqual(
            reopenedPeerWindow.workspaceManager.composeTab(for: identity)?.selection,
            reopenedCanonical
        )
        XCTAssertNotEqual(
            reopenedPeerWindow.workspaceManager.mcpSelectionPropagationHostID,
            originalPeerWindow.workspaceManager.mcpSelectionPropagationHostID
        )
    }

    @MainActor
    func testPropagationSkipsPeerAfterClosingFinalSaveBoundaryBegins() async {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let sourceWindow = WindowState()
        let closingPeerWindow = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        WindowStatesManager.shared.registerWindowState(sourceWindow)
        WindowStatesManager.shared.registerWindowState(closingPeerWindow)
        defer {
            WindowStatesManager.shared.unregisterWindowState(closingPeerWindow)
            WindowStatesManager.shared.unregisterWindowState(sourceWindow)
        }

        let workspaceID = UUID()
        let tabID = UUID()
        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        let sourceSelection = StoredSelection(selectedPaths: ["/tmp/source.swift"])
        let peerSelection = StoredSelection(selectedPaths: ["/tmp/peer-at-close.swift"])
        let delayedSelection = StoredSelection(selectedPaths: ["/tmp/delayed-after-close.swift"])
        await installSelectionWorkspace(
            in: sourceWindow,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: sourceSelection,
            name: "Source"
        )
        await installSelectionWorkspace(
            in: closingPeerWindow,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: peerSelection,
            name: "Closing Peer"
        )

        let registration = sourceWindow.workspaceManager.registerMCPSelectionSourceMutation(for: identity)
        XCTAssertEqual(
            registration.peerHostIDs,
            [closingPeerWindow.workspaceManager.mcpSelectionPropagationHostID]
        )

        closingPeerWindow.beginClose()
        XCTAssertTrue(closingPeerWindow.isClosing)
        let selectionAtCloseBoundary = closingPeerWindow.workspaceManager.composeTab(for: identity)?.selection

        await sourceWindow.workspaceManager.propagateMCPSelectionToPeerHosts(
            MCPSelectionPeerPropagation(
                identity: identity,
                selection: delayedSelection,
                sourceRevision: registration.sourceRevision,
                peerHostIDs: registration.peerHostIDs,
                mirrorToUIIfActive: true
            )
        )

        XCTAssertEqual(selectionAtCloseBoundary, peerSelection)
        XCTAssertEqual(
            closingPeerWindow.workspaceManager.composeTab(for: identity)?.selection,
            selectionAtCloseBoundary
        )
    }

    @MainActor
    func testMCPSelectionPersistenceWritesInactiveTabThroughCoordinator() async {
        let activeTabID = UUID()
        let inactiveTabID = UUID()
        let activeSelection = StoredSelection(selectedPaths: ["/tmp/active.swift"])
        let inactiveSelection = StoredSelection(selectedPaths: ["/tmp/old-agent.swift"])
        let nextSelection = StoredSelection(
            selectedPaths: ["/tmp/new-agent.swift"],
            codemapAutoEnabled: false
        )
        let manager = FakeMCPSelectionManager(
            tabs: [
                ComposeTabState(id: activeTabID, name: "Active", selection: activeSelection),
                ComposeTabState(id: inactiveTabID, name: "Agent", selection: inactiveSelection)
            ],
            activeTabID: activeTabID
        )
        let coordinator = WorkspaceSelectionCoordinator(
            workspaceManager: manager,
            store: WorkspaceFileContextStore()
        )
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let result = await MCPServerViewModel.persistMCPSelectionThroughCoordinator(
            nextSelection,
            for: inactiveTabID,
            workspaceID: manager.activeWorkspace?.id,
            selectionCoordinator: coordinator
        )

        XCTAssertEqual(result, .persisted)
        XCTAssertEqual(manager.composeTab(with: inactiveTabID)?.selection, nextSelection)
        XCTAssertEqual(manager.composeTab(with: activeTabID)?.selection, activeSelection)
        XCTAssertEqual(changes.last, .init(tabID: inactiveTabID, selection: nextSelection, source: .mcpTabContext))
    }

    @MainActor
    func testMCPSelectionPersistenceReturnsUnchangedWithoutPublishingDuplicateChange() async {
        let activeTabID = UUID()
        let inactiveTabID = UUID()
        let activeSelection = StoredSelection(selectedPaths: ["/tmp/active.swift"])
        let inactiveSelection = StoredSelection(selectedPaths: ["/tmp/agent.swift"], codemapAutoEnabled: false)
        let manager = FakeMCPSelectionManager(
            tabs: [
                ComposeTabState(id: activeTabID, name: "Active", selection: activeSelection),
                ComposeTabState(id: inactiveTabID, name: "Agent", selection: inactiveSelection)
            ],
            activeTabID: activeTabID
        )
        let coordinator = WorkspaceSelectionCoordinator(
            workspaceManager: manager,
            store: WorkspaceFileContextStore()
        )
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let result = await MCPServerViewModel.persistMCPSelectionThroughCoordinator(
            inactiveSelection,
            for: inactiveTabID,
            workspaceID: manager.activeWorkspace?.id,
            selectionCoordinator: coordinator
        )

        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(manager.composeTab(with: inactiveTabID)?.selection, inactiveSelection)
        XCTAssertTrue(changes.isEmpty)
    }

    @MainActor
    func testMCPSelectionPersistenceUnchangedActiveSelectionReconcilesStaleUI() async {
        let activeTabID = UUID()
        let canonical = StoredSelection(selectedPaths: ["/tmp/canonical.swift"], codemapAutoEnabled: false)
        let staleUI = StoredSelection(selectedPaths: ["/tmp/stale-ui.swift"])
        let manager = FakeMCPSelectionManager(
            tabs: [ComposeTabState(id: activeTabID, name: "Active", selection: canonical)],
            activeTabID: activeTabID
        )
        manager.mirroredSelection = staleUI
        let coordinator = WorkspaceSelectionCoordinator(
            workspaceManager: manager,
            store: WorkspaceFileContextStore()
        )
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let result = await MCPServerViewModel.persistMCPSelectionThroughCoordinator(
            canonical,
            for: activeTabID,
            workspaceID: manager.activeWorkspace?.id,
            selectionCoordinator: coordinator,
            mirrorToUIIfActive: true
        )

        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(manager.composeTab(with: activeTabID)?.selection, canonical)
        XCTAssertEqual(manager.mirrorAttempts, [canonical])
        XCTAssertEqual(manager.mirroredSelection, canonical)
        XCTAssertTrue(changes.isEmpty)
    }

    @MainActor
    func testMCPSelectionPersistenceRereadsCanonicalSelectionAndReportsMismatch() async {
        let activeTabID = UUID()
        let inactiveTabID = UUID()
        let staleSelection = StoredSelection(selectedPaths: ["/tmp/old-agent.swift"])
        let requestedSelection = StoredSelection(
            selectedPaths: ["/tmp/new-agent.swift"],
            autoCodemapPaths: ["/tmp/new-dependency.swift"],
            codemapAutoEnabled: false
        )
        let manager = FakeMCPSelectionManager(
            tabs: [
                ComposeTabState(id: activeTabID, name: "Active", selection: StoredSelection()),
                ComposeTabState(id: inactiveTabID, name: "Agent", selection: staleSelection)
            ],
            activeTabID: activeTabID,
            ignoreStoredOnlyUpdates: true
        )
        let coordinator = WorkspaceSelectionCoordinator(
            workspaceManager: manager,
            store: WorkspaceFileContextStore()
        )

        let result = await MCPServerViewModel.persistMCPSelectionAndVerifyThroughCoordinator(
            requestedSelection,
            for: inactiveTabID,
            workspaceID: manager.activeWorkspace?.id,
            selectionCoordinator: coordinator
        )

        XCTAssertEqual(result.outcome, .persisted)
        XCTAssertEqual(result.expectedSelection, requestedSelection)
        XCTAssertEqual(result.canonicalSelection, staleSelection)
        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(manager.composeTab(with: inactiveTabID)?.selection, staleSelection)
    }

    @MainActor
    func testSelectionMutationRejectsCanonicalPersistenceMismatchWithActionableError() {
        let tabID = UUID()
        let requestedSelection = StoredSelection(selectedPaths: ["/tmp/requested.swift"])
        let canonicalSelection = StoredSelection(selectedPaths: ["/tmp/stale.swift"])
        let verification = MCPServerViewModel.MCPSelectionPersistenceVerification(
            outcome: .persisted,
            expectedSelection: requestedSelection,
            canonicalSelection: canonicalSelection
        )

        XCTAssertThrowsError(try MCPSelectionToolProvider.requireCanonicalSelection(
            verification,
            requested: requestedSelection,
            tabID: tabID,
            operation: "manage_selection",
            recovery: "Retry manage_selection for the same context_id or rebind the tab context before continuing."
        )) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Selection persistence handoff failed"), message)
            XCTAssertTrue(message.contains(tabID.uuidString), message)
            XCTAssertTrue(message.contains("Retry manage_selection for the same context_id"), message)
        }
    }

    @MainActor
    func testManageSelectionSetPersistsAcrossConnectionRebindAndWorkspaceSerialization() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let root = try makeTemporaryDirectory(named: "tool-persistence-root")
        let storageRoot = try makeTemporaryDirectory(named: "serialized-workspace")
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: storageRoot.deletingLastPathComponent())
        }
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let selectedFile = sources.appendingPathComponent("App.swift")
        try "struct App {}\n".write(to: selectedFile, atomically: true, encoding: .utf8)

        let activeTabID = UUID()
        let tabID = UUID()
        let workspace = window.workspaceManager.createWorkspace(
            name: "Selection Tool Persistence \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )
        let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
        window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
            ComposeTabState(id: activeTabID, name: "Active"),
            ComposeTabState(id: tabID, name: "Agent")
        ]
        window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = activeTabID
        await window.workspaceManager.switchWorkspace(
            to: window.workspaceManager.workspaces[workspaceIndex],
            saveState: false,
            reason: "manageSelectionPersistenceTestTabs"
        )
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(in: window, path: root.path)
        let tools = await window.mcpServer.windowMCPTools
        let manageSelection = try XCTUnwrap(
            tools.first { $0.name == MCPWindowToolName.manageSelection }
        )

        let firstConnectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: firstConnectionID,
            clientName: "first-selection-client",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let setValue = try await ServerNetworkManager.withConnectionID(firstConnectionID) {
            try await manageSelection([
                "op": .string("set"),
                "paths": .array([.string(selectedFile.path)]),
                "mode": .string("full"),
                "view": .string("files"),
                "path_display": .string("full"),
                "strict": .bool(true)
            ])
        }
        XCTAssertEqual(try selectedPaths(from: setValue), [selectedFile.path])

        await window.mcpServer.commitAndClearTabContext(connectionID: firstConnectionID)
        let secondConnectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: secondConnectionID,
            clientName: "second-selection-client",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let getValue = try await ServerNetworkManager.withConnectionID(secondConnectionID) {
            try await manageSelection([
                "op": .string("get"),
                "view": .string("files"),
                "path_display": .string("full")
            ])
        }
        XCTAssertEqual(try selectedPaths(from: getValue), [selectedFile.path])

        let canonicalTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
        XCTAssertEqual(canonicalTab.selection.selectedPaths, [selectedFile.path])

        var workspaceToSave = try XCTUnwrap(window.workspaceManager.workspace(withID: workspace.id))
        workspaceToSave.customStoragePath = storageRoot
        let savedURL = try window.workspaceManager.saveWorkspaceToFile(workspaceToSave, source: .directUnknown)
        let serializedWorkspace = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: savedURL))
        let serializedTab = try XCTUnwrap(serializedWorkspace.composeTabs.first { $0.id == tabID })
        XCTAssertEqual(serializedTab.selection.selectedPaths, [selectedFile.path])
    }

    @MainActor
    func testMCPLogicalizeSelectionForPersistenceConvertsWorktreePhysicalPaths() {
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project")
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/tmp/worktrees/project-agent")
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRoot,
                    physicalRoot: physicalRoot,
                    binding: makeWorktreeBinding(logicalRoot: logicalRoot, physicalRoot: physicalRoot)
                )
            ]
        )
        let physicalSelection = StoredSelection(
            selectedPaths: ["/tmp/worktrees/project-agent/Sources/App.swift"],
            autoCodemapPaths: ["/tmp/worktrees/project-agent/Sources/Dependency.swift"],
            slices: ["/tmp/worktrees/project-agent/Sources/Sliced.swift": [LineRange(start: 1, end: 4)]],
            codemapAutoEnabled: false
        )

        let persisted = MCPServerViewModel.logicalizeSelectionForPersistence(
            physicalSelection,
            lookupContext: WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        )

        XCTAssertEqual(persisted.selectedPaths, ["/repo/project/Sources/App.swift"])
        XCTAssertEqual(persisted.autoCodemapPaths, ["/repo/project/Sources/Dependency.swift"])
        XCTAssertEqual(
            persisted.slices["/repo/project/Sources/Sliced.swift"],
            [LineRange(start: 1, end: 4)]
        )
    }

    @MainActor
    func testSpawnSourceUsesResolvedTabContextSnapshot() {
        let context = makeTabContext(runID: UUID(), windowID: 11)
        let resolved = MCPServerViewModel.ResolvedTabContextSnapshot(
            snapshot: context,
            usesActiveTabCompatibility: false
        )
        let activeCompatibility = MCPServerViewModel.ResolvedTabContextSnapshot(
            snapshot: context,
            usesActiveTabCompatibility: true
        )

        XCTAssertEqual(
            MCPServerViewModel.spawnSourceTabIDForAgentSessionCreation(
                purpose: .agentModeRun,
                resolvedContext: resolved
            ),
            context.tabID
        )
        XCTAssertNil(MCPServerViewModel.spawnSourceTabIDForAgentSessionCreation(
            purpose: .agentModeRun,
            resolvedContext: activeCompatibility
        ))
        XCTAssertNil(MCPServerViewModel.spawnSourceTabIDForAgentSessionCreation(
            purpose: .unknown,
            resolvedContext: resolved
        ))
    }

    #if DEBUG
        @MainActor
        func testValidateAgentRunStartRoutingRejectsCachedNestedOriginWhenRehydrationCannotRestoreSource() async {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            let connectionID = UUID()
            let runID = UUID()
            await ServerNetworkManager.shared.debugSeedRunPolicyState(
                runID: runID,
                tabID: nil,
                restrictedTools: [],
                additionalTools: nil,
                purpose: .agentModeRun
            )
            await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
                connectionID: connectionID,
                runID: runID,
                purpose: .unknown
            )
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: "cached-nested-routing-test",
                windowID: window.windowID,
                runPurpose: .unknown
            )

            await XCTAssertThrowsErrorAsync({
                try await window.mcpServer.validateAgentRunStartRouting(
                    metadata: metadata,
                    resolvedSourceTabID: nil
                )
            }) { error in
                XCTAssertTrue(String(describing: error).contains("Refusing to create an unparented top-level run"), String(describing: error))
            }
            await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID)
        }
    #endif

    func testAgentRunStartWithoutSourceRejectsNestedOriginsButAllowsLegitimateTopLevelOrigins() {
        XCTAssertTrue(MCPServerViewModel.shouldRejectAgentRunStartWithoutResolvedSource(
            capturedPurpose: .agentModeRun,
            currentPurpose: .unknown,
            cachedRunPolicyPurpose: nil
        ))
        XCTAssertTrue(MCPServerViewModel.shouldRejectAgentRunStartWithoutResolvedSource(
            capturedPurpose: .unknown,
            currentPurpose: .agentModeRun,
            cachedRunPolicyPurpose: nil
        ))
        XCTAssertTrue(MCPServerViewModel.shouldRejectAgentRunStartWithoutResolvedSource(
            capturedPurpose: .unknown,
            currentPurpose: .unknown,
            cachedRunPolicyPurpose: .agentModeRun
        ))
        XCTAssertFalse(MCPServerViewModel.shouldRejectAgentRunStartWithoutResolvedSource(
            capturedPurpose: .unknown,
            currentPurpose: .unknown,
            cachedRunPolicyPurpose: nil
        ))
        XCTAssertFalse(MCPServerViewModel.shouldRejectAgentRunStartWithoutResolvedSource(
            capturedPurpose: nil,
            currentPurpose: .unknown,
            cachedRunPolicyPurpose: .discoverRun
        ))
    }

    @MainActor
    private func installSelectionWorkspace(
        in window: WindowState,
        workspaceID: UUID,
        tabID: UUID,
        selection: StoredSelection,
        name: String
    ) async {
        let workspace = WorkspaceModel(
            id: workspaceID,
            name: name,
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [
                ComposeTabState(id: tabID, name: "Agent", selection: selection)
            ],
            activeComposeTabID: tabID
        )
        window.workspaceManager.workspaces = [workspace]
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "selectionPropagationLifecycleTest"
        )
        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        guard var installedTab = window.workspaceManager.composeTab(for: identity) else {
            XCTFail("Expected installed selection tab")
            return
        }
        installedTab.selection = selection
        XCTAssertTrue(
            window.workspaceManager.updateComposeTabStoredOnly(
                installedTab,
                inWorkspaceID: workspaceID
            )
        )
    }

    private func selectedPaths(from value: Value) throws -> [String] {
        let object = try XCTUnwrap(value.objectValue)
        let files = try XCTUnwrap(object["files"]?.arrayValue)
        return try files.map { file in
            try XCTUnwrap(file.objectValue?["path"]?.stringValue)
        }
    }

    private func makeResolver(
        matchesByContextID: [UUID: [MCPContextBindingMatch]],
        existingWindowID: Int? = nil,
        reusableWindowID: Int? = nil,
        preferredLiveRunWindowID: Int? = nil,
        preferredWindowID: Int? = nil
    ) -> MCPBindingResolver {
        MCPBindingResolver(
            collectMatchesForContextID: { contextID in matchesByContextID[contextID] ?? [] },
            collectMatchesForWorkingDirs: { _ in [] },
            existingWindowIDForConnection: { _ in existingWindowID },
            clientIdentifier: { _ in "test-client" },
            reusableWindowForClient: { _, _ in reusableWindowID },
            sessionKeyForConnection: { _ in "session" },
            preferredLiveRunWindowID: { _, _ in preferredLiveRunWindowID },
            preferredWindowID: { _, _ in preferredWindowID }
        )
    }

    private func match(
        windowID: Int,
        tabID: UUID,
        workspaceID: UUID,
        workspaceName: String = "Workspace",
        roots: [String] = ["/tmp/project"]
    ) -> MCPContextBindingMatch {
        MCPContextBindingMatch(
            windowID: windowID,
            tabID: tabID,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            repoPaths: roots
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabContextRoutingTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    private func makeWorktreeBinding(
        logicalRoot: WorkspaceRootRef,
        physicalRoot: WorkspaceRootRef
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.fullPath,
            source: "test"
        )
    }

    @MainActor
    private func makeTabContext(runID: UUID?, windowID: Int) -> MCPServerViewModel.TabContextSnapshot {
        MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: windowID,
            workspaceID: UUID(),
            promptText: "",
            selection: StoredSelection(),
            selectedMetaPromptIDs: [],
            tabName: "Tab",
            runID: runID,
            explicitlyBound: false
        )
    }
}

@MainActor
private final class FakeMCPSelectionManager: WorkspaceSelectionHost {
    var activeWorkspace: WorkspaceModel?
    private(set) var selectionMirrorContextRevision: UInt64 = 0

    private let ignoreStoredOnlyUpdates: Bool
    private(set) var mirrorAttempts: [StoredSelection] = []
    var mirroredSelection: StoredSelection?

    init(tabs: [ComposeTabState], activeTabID: UUID, ignoreStoredOnlyUpdates: Bool = false) {
        self.ignoreStoredOnlyUpdates = ignoreStoredOnlyUpdates
        activeWorkspace = WorkspaceModel(
            name: "Test Workspace",
            repoPaths: [],
            composeTabs: tabs,
            activeComposeTabID: activeTabID
        )
    }

    func composeTab(with id: UUID) -> ComposeTabState? {
        activeWorkspace?.composeTabs.first(where: { $0.id == id })
    }

    func composeTab(for identity: WorkspaceSelectionIdentity) -> ComposeTabState? {
        guard activeWorkspace?.id == identity.workspaceID else { return nil }
        return activeWorkspace?.composeTabs.first(where: { $0.id == identity.tabID })
    }

    func publishActiveComposeTabSnapshot(commitToMemory: Bool, touchModified: Bool) {}

    func applySelectionMirrorAttempt(
        _ selection: StoredSelection,
        forTabID tabID: UUID,
        workspaceID: UUID
    ) async {
        guard activeWorkspace?.id == workspaceID,
              activeWorkspace?.activeComposeTabID == tabID
        else { return }
        mirrorAttempts.append(selection)
        mirroredSelection = selection
    }

    func updateComposeTabStoredOnly(_ tab: ComposeTabState, inWorkspaceID workspaceID: UUID) -> Bool {
        guard !ignoreStoredOnlyUpdates else { return false }
        guard var workspace = activeWorkspace,
              workspace.id == workspaceID,
              let index = workspace.composeTabs.firstIndex(where: { $0.id == tab.id })
        else { return false }
        workspace.composeTabs[index] = tab
        activeWorkspace = workspace
        return true
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
