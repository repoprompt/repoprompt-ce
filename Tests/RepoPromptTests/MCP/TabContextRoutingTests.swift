import Foundation
import MCP
@testable import RepoPrompt
import XCTest

final class TabContextRoutingTests: XCTestCase {
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
