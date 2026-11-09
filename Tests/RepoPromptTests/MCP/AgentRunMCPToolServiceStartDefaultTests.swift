import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptSecureStorage
@testable import RepoPromptWorkspaceContext
import XCTest

@MainActor
final class AgentRunMCPToolServiceStartDefaultTests: XCTestCase {
    func testInheritedRestrictiveCodexSettingsRemainRestrictive() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        AgentModePermissionPreferences.setSubagentPermissionPolicy(.inheritProviderSettings, defaults: defaults)
        CodexAgentToolPreferences.setPermissionLevel(.readOnly, defaults: defaults)
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        let service = makeBindingService(defaults: defaults)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .userConfigured)
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.readOnly.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .readOnly)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .user)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, false)
        XCTAssertFalse(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertFalse(profile.codexSuppressesThirdPartyMCPServers)
    }

    func testCustomRestrictiveCodexOverrideWinsOverSafeManagedDefaults() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        AgentModePermissionPreferences.setSubagentPermissionPolicy(.custom, defaults: defaults)
        AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
            .codex(.readOnly),
            for: .codex,
            defaults: defaults
        )
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        let service = makeBindingService(defaults: defaults)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .providerOverride(.codex(.readOnly)))
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.readOnly.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .readOnly)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .user)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, false)
        XCTAssertFalse(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertFalse(profile.codexSuppressesThirdPartyMCPServers)
    }

    func testSubagentPolicyStorageFailureUsesCodexSafeManagedSnapshot() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let secureStore = AgentPermissionSecureStore(
            secureStrings: AgentRunFailingSecurePlainStringStore(),
            notificationCenter: NotificationCenter()
        )
        let service = makeBindingService(defaults: defaults, secureStore: secureStore)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .mcpSafeDefaults)
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.autoReview.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .autoReview)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, true)
        XCTAssertEqual(snapshot.codexTools?.mcpServerStatesByNormalizedName["external-tools"], false)
        XCTAssertTrue(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertTrue(profile.codexSuppressesThirdPartyMCPServers)
        XCTAssertEqual(secureStore.diagnostic(for: .subagent)?.kind, .keychainInteractionNotAllowed)
    }

    func testExplicitTargetTabWithOmittedModelIDPreservesCurrentSelection() {
        let targetTabID = UUID()

        XCTAssertNil(AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: targetTabID))
    }

    func testWorkflowDefaultDoesNotOverridePairForUntargetedStart() {
        XCTAssertEqual(AgentWorkflow.oracleExport.defaultTaskLabelKind, .explore)

        let defaultLabel = AgentRunMCPToolService.defaultTaskLabelForStart(
            resolvedTabID: nil,
            workflow: AgentWorkflow.oracleExport.definition
        )

        XCTAssertEqual(defaultLabel, .pair)
    }

    func testRouterOwnedStartKeepsRoleSemanticsWithoutResolvingChildModelPin() {
        XCTAssertEqual(
            AgentRunMCPToolService.taskLabelKindForRouterOwnedStart(
                requestedModelID: nil,
                defaultTaskLabel: .pair
            ),
            .pair
        )
        XCTAssertEqual(
            AgentRunMCPToolService.taskLabelKindForRouterOwnedStart(
                requestedModelID: "explore",
                defaultTaskLabel: .pair
            ),
            .explore
        )
        XCTAssertNil(
            AgentRunMCPToolService.taskLabelKindForRouterOwnedStart(
                requestedModelID: "claudeCode:unavailable-stale-model",
                defaultTaskLabel: .pair
            )
        )
    }

    func testExplicitModelAndParameterPinsBypassModelRouter() {
        XCTAssertTrue(AgentRunMCPToolService.shouldRouteModelForStart(
            requestedModelID: nil,
            hasExplicitModelParameters: false
        ))
        XCTAssertTrue(AgentRunMCPToolService.shouldRouteModelForStart(
            requestedModelID: "engineer",
            hasExplicitModelParameters: false
        ))
        XCTAssertFalse(AgentRunMCPToolService.shouldRouteModelForStart(
            requestedModelID: "codexExec:gpt-6-sol-xhigh",
            hasExplicitModelParameters: false
        ))
        XCTAssertFalse(AgentRunMCPToolService.shouldRouteModelForStart(
            requestedModelID: "devin:swe-2",
            hasExplicitModelParameters: false
        ))
        XCTAssertFalse(AgentRunMCPToolService.shouldRouteModelForStart(
            requestedModelID: "engineer",
            hasExplicitModelParameters: true
        ))
        XCTAssertFalse(AgentRunMCPToolService.shouldRouteModelForStart(
            requestedModelID: nil,
            hasExplicitModelParameters: true
        ))
    }

    private func makeBindingService(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> AgentModeProviderBindingService {
        AgentModeProviderBindingService(
            preferences: AgentProviderPreferenceSnapshotStore(
                defaults: defaults,
                securePermissions: secureStore,
                codexMCPServerEntries: {
                    [
                        MCPIntegrationHelper.CodexServerEntry(
                            rawName: "external-tools",
                            normalizedName: "external-tools",
                            cliPathComponent: "external-tools"
                        )
                    ]
                }
            )
        )
    }
}

private final class AgentRunFailingSecurePlainStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches = true

    func getPlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws -> String? {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func savePlainValue(_ value: String, for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }
}

final class MCPToolIdleWaitTests: XCTestCase {
    @MainActor
    func testRuntimeTrackingIsTokenOwnedAndIdleIsNotASideEffectDrain() async throws {
        let runtime = MCPToolExecutionRuntime()
        let runID = UUID(), connectionID = UUID(), otherConnectionID = UUID()
        let first = UUID(), second = UUID(), connectionOnly = UUID()
        var cancelled: [UUID] = []
        var publications = 0
        runtime.didChange = { publications += 1 }
        runtime.registerToolExecution(executionID: first, runID: runID, connectionID: connectionID, toolName: "same_tool") {
            cancelled.append(first)
        }
        runtime.registerToolExecution(executionID: second, runID: runID, connectionID: otherConnectionID, toolName: "same_tool") {
            cancelled.append(second)
        }
        runtime.registerToolExecution(executionID: connectionOnly, runID: nil, connectionID: connectionID, toolName: "control_tool") {
            cancelled.append(connectionOnly)
        }
        XCTAssertEqual(runtime.executionIDs(connectionID: connectionID), [first, connectionOnly])
        for id in runtime.executionIDs(connectionID: connectionID) {
            XCTAssertTrue(runtime.cancelToolExecution(executionID: id, reason: "disconnect"))
        }
        XCTAssertEqual(Set(cancelled), [first, connectionOnly])
        XCTAssertTrue(runtime.hasActiveToolExecutions(runID: runID))
        XCTAssertEqual(runtime.toolEndedCount(runID: runID), 1)
        XCTAssertEqual(runtime.executionIDs(connectionID: otherConnectionID), [second])
        XCTAssertFalse(runtime.cancelToolExecution(executionID: first, reason: "duplicate"))
        runtime.unregisterToolExecution(executionID: first)
        XCTAssertEqual(publications, 5)
        runtime.didChange = nil // Optional presentation detachment must not affect tracking.
        XCTAssertEqual(runtime.cancelActiveToolsForRun(runID: runID), 1)
        XCTAssertEqual(cancelled.last, second)
        XCTAssertEqual(runtime.activeExecutionCount, 0)
        XCTAssertEqual(runtime.toolEndedCount(runID: runID), 0)
        try await runtime.awaitNoActiveToolExecutions(runID: runID)
        // The cancel closure only requested cancellation; no external effect completion was awaited.
    }

    @MainActor
    func testRuntimeIdleWaitRetainsOwnerAndCancellationDoesNotCancelTrackedTools() async throws {
        var runtime: MCPToolExecutionRuntime? = MCPToolExecutionRuntime()
        weak let owner = runtime
        let runID = UUID(), executionID = UUID()
        var toolCancelled = false
        runtime?.registerToolExecution(executionID: executionID, runID: runID, connectionID: nil, toolName: "held") {
            toolCancelled = true
        }
        let entered = expectation(description: "idle wait entered on MainActor")
        let wait = Task { @MainActor [runtime] in
            let runtime = try XCTUnwrap(runtime)
            entered.fulfill()
            try await runtime.awaitNoActiveToolExecutions(runID: runID)
        }
        runtime = nil
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertNotNil(owner)
        XCTAssertTrue(owner?.hasActiveToolExecutions(runID: runID) == true)
        wait.cancel()
        do {
            try await wait.value
            XCTFail("Cancelled waiter must throw")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(toolCancelled)
        XCTAssertNil(owner)
    }

    @MainActor
    func testRuntimeIdleWaitResumesOnlyAfterLastTrackedExecution() async throws {
        let runtime = MCPToolExecutionRuntime()
        let runID = UUID(), first = UUID(), second = UUID()
        for id in [first, second] {
            runtime.registerToolExecution(executionID: id, runID: runID, connectionID: nil, toolName: "held", cancel: {})
        }
        let entered = expectation(description: "wait entered")
        var completed = false
        let wait = Task { @MainActor in
            entered.fulfill()
            try await runtime.awaitNoActiveToolExecutions(runID: runID)
            completed = true
        }
        await fulfillment(of: [entered], timeout: 2)
        runtime.unregisterToolExecution(executionID: first)
        XCTAssertFalse(completed)
        XCTAssertTrue(runtime.hasActiveToolExecutions(runID: runID))
        runtime.unregisterToolExecution(executionID: second)
        try await wait.value
        XCTAssertTrue(completed)
        XCTAssertEqual(runtime.toolEndedCount(runID: runID), 2)
    }

    @MainActor
    func testRuntimeWaitScopesRemainDistinctFromToolExecutionsAndExpireByCapturedTimeout() {
        let runtime = MCPToolExecutionRuntime()
        let parent = UUID(), child = UUID()
        let metadata = MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: nil, windowID: nil)
        let short = runtime.beginAgentRunWaitScope(parentRunID: parent, metadata: metadata, sessionIDs: [child], timeoutSeconds: 0)
        let long = runtime.beginAgentRunWaitScope(parentRunID: parent, metadata: metadata, sessionIDs: [child], timeoutSeconds: 600)
        XCTAssertTrue(runtime.hasActiveChildAgentRunWaits(runID: parent))
        XCTAssertFalse(runtime.hasActiveToolExecutions(runID: parent))
        runtime.purgeStaleAgentRunWaitScopes(now: Date().addingTimeInterval(61), source: "test")
        XCTAssertEqual(runtime.waitScopeCount(parentRunID: parent), 1)
        let completion = AgentRunWaitScopeCompletion(reason: .cancelled, result: nil, winnerSessionID: nil, pendingSessionIDs: [], errorDescription: nil)
        runtime.endAgentRunWaitScope(short.token, completion: completion)
        XCTAssertTrue(runtime.hasActiveChildAgentRunWaits(runID: parent))
        runtime.endAgentRunWaitScope(long.token, completion: completion)
        XCTAssertFalse(runtime.hasActiveChildAgentRunWaits(runID: parent))
    }

    @MainActor
    func testRuntimeCompletionSurvivesServerDisposalAndRemainsExactlyOnce() async throws {
        var server: MCPServerViewModel? = makeServerViewModel(service: MCPService(
            hostBootstrapOperation: {}, controllerStartOperation: {}, controllerFullShutdownOperation: {}
        ))
        weak let presentation = server
        let runtime = try XCTUnwrap(server?.toolExecutionRuntime)
        let runID = UUID(), executionID = UUID()
        runtime.registerToolExecution(executionID: executionID, runID: runID, connectionID: nil, toolName: "held", cancel: {})
        let completion = runtime.makeCompletionHandler(executionID: executionID, toolName: "held")
        server = nil
        XCTAssertNil(presentation, "The retained execution owner must not retain the server presentation")
        XCTAssertTrue(runtime.hasActiveToolExecutions(runID: runID))
        await completion("cancelled")
        await completion("success")
        XCTAssertFalse(runtime.hasActiveToolExecutions(runID: runID))
        XCTAssertEqual(runtime.toolEndedCount(runID: runID), 1)
        try await runtime.awaitNoActiveToolExecutions(runID: runID)
    }

    @MainActor
    func testAlreadyCancelledToolIdleWaitDoesNotTakeIdleFastPath() async {
        let server = makeServerViewModel(service: MCPService(
            hostBootstrapOperation: {}, controllerStartOperation: {}, controllerFullShutdownOperation: {}
        ))
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await server.awaitNoActiveToolExecutions(runID: UUID())
        }
        do {
            try await task.value
            XCTFail("Already-cancelled idle waiter must throw")
        } catch is CancellationError {
            // The same guard also closes cancellation before continuation installation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    private func makeServerViewModel(service: MCPService) -> MCPServerViewModel {
        let store = WorkspaceFileContextStore()
        let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let settingsManager = WindowSettingsManager(windowID: -1)
        let prompt = PromptViewModel(
            fileManager: fileManager,
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: settingsManager
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let oracle = OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
        return MCPServerViewModel(
            service: service,
            promptVM: prompt,
            oracleVM: oracle,
            workspaceManager: workspaceManager,
            windowID: -1,
            workspaceSearch: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("workspace search is not used by these tests")
            },
            ensureGitDataRootLoaded: { _, _ in
                throw MCPError.internalError("git-data loading is not used by these tests")
            }
        )
    }
}
