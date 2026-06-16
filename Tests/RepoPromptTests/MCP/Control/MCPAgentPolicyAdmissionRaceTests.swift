import Darwin
import Foundation
import MCP
@testable import RepoPrompt
import XCTest

final class MCPAgentPolicyAdmissionRaceTests: XCTestCase {
    private let manager = ServerNetworkManager.shared
    private let clientName = AgentProviderKind.openCodeMCPClientID

    override func tearDown() async throws {
        #if DEBUG
            await manager.debugResumePendingPolicyRouteInstallation()
            await manager.debugResumePendingPolicyCommit()
        #endif
        try await super.tearDown()
    }

    func testHelperIdentityTransitionWaitsForLateExpectedPIDRegistration() async throws {
        #if DEBUG
            let processTree = try makeSleepingProcessTree()
            defer { processTree.terminate() }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61001
            await installPolicy(runID: runID, windowID: windowID)
            await manager.debugClearRunRoutingHistoryForTesting()

            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(processTree.childPID),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 1.0,
                    requireRunRouting: false
                )
            }

            let waitStarted = await waitForEvent("pid_gate_wait_started", runID: runID)
            XCTAssertTrue(waitStarted)
            await manager.registerExpectedAgentPID(processTree.parentPID, for: clientName, runID: runID)
            let result = await application.value

            XCTAssertEqual(result.outcome, "applied")
            XCTAssertEqual(result.runID, runID)
            XCTAssertEqual(result.windowID, windowID)
            let mappedRunID = await manager.runIDForConnection(connectionID)
            let waitCompleted = await waitForEvent("pid_gate_wait_completed", runID: runID)
            let policyApplied = await waitForEvent("policy_applied", runID: runID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(mappedRunID, runID)
            XCTAssertTrue(waitCompleted)
            XCTAssertTrue(policyApplied)
            XCTAssertFalse(pending.contains { $0.runID == runID })

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: processTree.parentPID
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testWrongPIDCannotConsumeRunPolicy() async throws {
        #if DEBUG
            let expectedTree = try makeSleepingProcessTree()
            let unrelatedTree = try makeSleepingProcessTree()
            defer {
                expectedTree.terminate()
                unrelatedTree.terminate()
            }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61002
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(expectedTree.parentPID, for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(unrelatedTree.childPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.05,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "rejected:ownership_timeout")
            let mappedRunID = await manager.runIDForConnection(connectionID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertNil(mappedRunID)
            XCTAssertTrue(pending.contains { $0.runID == runID })
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: expectedTree.parentPID
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testWrongClientCannotConsumeOpenCodePolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61003
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: "unrelated-client",
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.05,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "fallback")
            let mappedRunID = await manager.runIDForConnection(connectionID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertNil(mappedRunID)
            XCTAssertTrue(pending.contains { $0.runID == runID })
            await cleanup(runID: runID, connectionID: connectionID, windowID: windowID, expectedPID: getpid())
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testParallelSameProviderRunsConsumeOnlyTheirRunSpecificPIDPolicy() async throws {
        #if DEBUG
            let firstProcess = try makeSleepingProcessTree()
            let secondProcess = try makeSleepingProcessTree()
            defer {
                firstProcess.terminate()
                secondProcess.terminate()
            }

            let firstRunID = UUID()
            let secondRunID = UUID()
            let firstConnectionID = UUID()
            let secondConnectionID = UUID()
            let firstWindowID = 61004
            let secondWindowID = 61005
            await installPolicy(runID: firstRunID, windowID: firstWindowID)
            await installPolicy(runID: secondRunID, windowID: secondWindowID)
            await manager.registerExpectedAgentPID(firstProcess.parentPID, for: clientName, runID: firstRunID)
            await manager.registerExpectedAgentPID(secondProcess.parentPID, for: clientName, runID: secondRunID)

            async let first = manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: firstConnectionID,
                clientPid: Int(firstProcess.childPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            async let second = manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: secondConnectionID,
                clientPid: Int(secondProcess.childPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            let (firstResult, secondResult) = await (first, second)

            XCTAssertEqual(firstResult.outcome, "applied")
            XCTAssertEqual(firstResult.runID, firstRunID)
            XCTAssertEqual(firstResult.windowID, firstWindowID)
            XCTAssertEqual(secondResult.outcome, "applied")
            XCTAssertEqual(secondResult.runID, secondRunID)
            XCTAssertEqual(secondResult.windowID, secondWindowID)
            let mappedFirstRunID = await manager.runIDForConnection(firstConnectionID)
            let mappedSecondRunID = await manager.runIDForConnection(secondConnectionID)
            XCTAssertEqual(mappedFirstRunID, firstRunID)
            XCTAssertEqual(mappedSecondRunID, secondRunID)

            await cleanup(
                runID: firstRunID,
                connectionID: firstConnectionID,
                windowID: firstWindowID,
                expectedPID: firstProcess.parentPID
            )
            await cleanup(
                runID: secondRunID,
                connectionID: secondConnectionID,
                windowID: secondWindowID,
                expectedPID: secondProcess.parentPID
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testMixedQueuePrioritizesConsumablePIDGatedRunPolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61006
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: [],
                oneShot: true,
                reason: "non-gated mixed queue fixture",
                ttl: 10,
                purpose: .unknown,
                requiresExpectedAgentPID: false
            )
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )

            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(result.outcome, "applied")
            XCTAssertEqual(result.runID, runID)
            XCTAssertEqual(pending.count, 1)
            XCTAssertNil(pending.first?.runID)

            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID)
            await cleanup(runID: runID, connectionID: connectionID, windowID: windowID, expectedPID: getpid())
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testKnownAgentBootstrapTimesOutInsteadOfFallingBackWhenLiveAffinityIsUnusable() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let bootstrapConnectionID = UUID()
            let windowID = 61009
            let sessionKey = "bootstrap-timeout-\(UUID().uuidString)"
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            let applied = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(applied.outcome, "applied")
            await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let readiness = await manager.debugBootstrapPolicyAdmissionStatus(
                bootstrapClientName: clientName,
                connectionID: bootstrapConnectionID,
                sessionKey: sessionKey,
                clientPid: Int(getpid()),
                timeout: 0.01
            )

            XCTAssertEqual(readiness, "timedOut")
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: nil
            )
            await manager.removeConnection(bootstrapConnectionID)
        #else
            throw XCTSkip("Bootstrap admission diagnostics require DEBUG helpers.")
        #endif
    }

    func testSessionTokenAlreadyBoundToLiveRunCannotConsumeAnotherRunPolicy() async throws {
        #if DEBUG
            let firstRunID = UUID()
            let secondRunID = UUID()
            let firstConnectionID = UUID()
            let secondConnectionID = UUID()
            let firstWindowID = 61007
            let secondWindowID = 61008
            let sessionKey = "routing-isolation-\(UUID().uuidString)"
            await installPolicy(runID: firstRunID, windowID: firstWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: firstRunID)

            let firstResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: firstConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(firstResult.outcome, "applied")
            XCTAssertEqual(firstResult.runID, firstRunID)

            await installPolicy(runID: secondRunID, windowID: secondWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: secondRunID)
            let secondResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: secondConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )

            XCTAssertEqual(secondResult.outcome, "rejected:session_token_bound_to_other_run")
            XCTAssertEqual(secondResult.runID, secondRunID)
            let secondMappedRunID = await manager.runIDForConnection(secondConnectionID)
            XCTAssertNil(secondMappedRunID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pending.contains { $0.runID == secondRunID })

            await cleanup(
                runID: firstRunID,
                connectionID: firstConnectionID,
                windowID: firstWindowID,
                expectedPID: getpid()
            )
            await cleanup(
                runID: secondRunID,
                connectionID: secondConnectionID,
                windowID: secondWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testPolicyInstallFreezesBlankTabStateBeforeFirstSelectionGet() async throws {
        #if DEBUG
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PolicyBlankTab-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let selectedFile = root.appendingPathComponent("version.env")
            try "VERSION=1\n".write(to: selectedFile, atomically: true, encoding: .utf8)

            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let seedTabID = UUID()
            let blankTabIDs = [UUID(), UUID()]
            let seedSelection = StoredSelection(
                selectedPaths: [selectedFile.path],
                slices: [selectedFile.path: [LineRange(start: 1, end: 1)]],
                codemapAutoEnabled: false
            )
            let workspace = window.workspaceManager.createWorkspace(
                name: "Policy blank state \(UUID().uuidString.prefix(8))",
                repoPaths: [root.path],
                ephemeral: true
            )
            let initialSwitchResult = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "policyBlankStateInitial"
            )
            XCTAssertEqual(initialSwitchResult, .switched)
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                ComposeTabState(
                    id: seedTabID,
                    name: "Seed",
                    selection: seedSelection,
                    promptText: "seed prompt"
                ),
                ComposeTabState(id: blankTabIDs[0], name: "Agent 1"),
                ComposeTabState(id: blankTabIDs[1], name: "Agent 2")
            ]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = seedTabID
            let reloadResult = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
                window.workspaceManager.workspaces[workspaceIndex],
                reason: "policyBlankStateTabs"
            )
            XCTAssertEqual(reloadResult, .switched)
            _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: root.path
            )
            await window.workspaceFilesViewModel.applyStoredSelection(seedSelection)
            window.promptManager.promptText = "seed prompt"
            XCTAssertEqual(window.workspaceFilesViewModel.snapshotSelection(), seedSelection)

            let tools = await window.mcpServer.windowMCPTools
            let manageSelection = try XCTUnwrap(
                tools.first { $0.name == MCPWindowToolName.manageSelection }
            )

            for (index, blankTabID) in blankTabIDs.enumerated() {
                window.workspaceManager.beginApplyingTabContext(forTabID: blankTabID)
                let currentWorkspaceIndex = try XCTUnwrap(
                    window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
                )
                window.workspaceManager.workspaces[currentWorkspaceIndex].activeComposeTabID = blankTabID
                window.promptManager.loadComposeTabsFromWorkspace(
                    window.workspaceManager.workspaces[currentWorkspaceIndex]
                )
                XCTAssertEqual(window.workspaceFilesViewModel.snapshotSelection(), seedSelection)

                let runID = UUID()
                let connectionID = UUID()
                await installAuthoritativePolicy(
                    runID: runID,
                    tabID: blankTabID,
                    windowID: window.windowID
                )
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                let result = await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    sessionKey: "blank-policy-\(index)-\(UUID().uuidString)",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
                XCTAssertEqual(result.outcome, "applied")
                XCTAssertEqual(result.runID, runID)

                let bound = try XCTUnwrap(window.mcpServer.tabContextByConnectionID[connectionID])
                XCTAssertEqual(bound.tabID, blankTabID)
                XCTAssertEqual(bound.selection, StoredSelection())

                let firstGet = try await ServerNetworkManager.withConnectionID(connectionID) {
                    try await manageSelection([
                        "op": .string("get"),
                        "view": .string("files"),
                        "path_display": .string("full")
                    ])
                }
                let object = try XCTUnwrap(firstGet.objectValue)
                XCTAssertTrue((object["files"]?.arrayValue ?? []).isEmpty)
                XCTAssertTrue((object["file_slices"]?.arrayValue ?? []).isEmpty)
                XCTAssertEqual(window.workspaceManager.composeTab(with: blankTabID)?.selection, StoredSelection())

                await cleanup(
                    runID: runID,
                    connectionID: connectionID,
                    windowID: window.windowID,
                    expectedPID: getpid()
                )
                window.workspaceManager.endApplyingTabContext(forTabID: blankTabID)
            }
        #else
            throw XCTSkip("Policy-bound tab routing diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testRetainedConnectionCannotConsumeDifferentRunPolicy() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let firstRunID = UUID()
            let secondRunID = UUID()
            let retainedConnectionID = UUID()
            let rejectedHandoverConnectionID = UUID()
            let freshConnectionID = UUID()
            let firstTabID = UUID()
            let secondTabID = UUID()
            let firstSelection = StoredSelection(selectedPaths: ["/tmp/first-agent.swift"])
            let secondSelection = StoredSelection(selectedPaths: ["/tmp/second-agent.swift"])
            let windowID = window.windowID
            let sessionKey = "retained-connection-pinning-\(UUID().uuidString)"
            let workspace = window.workspaceManager.createWorkspace(
                name: "Retained connection selection isolation \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                ephemeral: true
            )
            let initialSwitchResult = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "retainedConnectionSelectionIsolation"
            )
            XCTAssertEqual(initialSwitchResult, .switched)
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                ComposeTabState(id: firstTabID, name: "First", selection: firstSelection),
                ComposeTabState(id: secondTabID, name: "Second", selection: secondSelection)
            ]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = firstTabID
            let tabReloadResult = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
                window.workspaceManager.workspaces[workspaceIndex],
                reason: "retainedConnectionSelectionIsolationTabs"
            )
            XCTAssertEqual(tabReloadResult, .switched)
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

            await installAuthoritativePolicy(
                runID: firstRunID,
                tabID: firstTabID,
                windowID: windowID
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: firstRunID)
            let firstResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: retainedConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            XCTAssertEqual(firstResult.outcome, "applied")
            XCTAssertEqual(firstResult.runID, firstRunID)
            let firstBoundContext = try XCTUnwrap(
                window.mcpServer.tabContextByConnectionID[retainedConnectionID]
            )
            XCTAssertEqual(firstBoundContext.tabID, firstTabID)

            await installAuthoritativePolicy(
                runID: secondRunID,
                tabID: secondTabID,
                windowID: windowID
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: secondRunID)
            let retainedStateBeforeRejection = await manager.debugConnectionPolicyState(
                for: retainedConnectionID
            )

            let rejectedResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: retainedConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )

            let retainedRunID = await manager.runIDForConnection(retainedConnectionID)
            let retainedStateAfterRejection = await manager.debugConnectionPolicyState(
                for: retainedConnectionID
            )
            let pendingAfterRejection = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(rejectedResult.outcome, "rejected:connection_bound_to_other_run")
            XCTAssertEqual(rejectedResult.runID, secondRunID)
            XCTAssertEqual(retainedRunID, firstRunID)
            XCTAssertEqual(retainedStateAfterRejection.restrictedTools, retainedStateBeforeRejection.restrictedTools)
            XCTAssertEqual(retainedStateAfterRejection.additionalTools, retainedStateBeforeRejection.additionalTools)
            XCTAssertEqual(retainedStateAfterRejection.purpose, retainedStateBeforeRejection.purpose)
            XCTAssertEqual(retainedStateAfterRejection.windowID, retainedStateBeforeRejection.windowID)
            let retainedContextAfterRejection = try XCTUnwrap(
                window.mcpServer.tabContextByConnectionID[retainedConnectionID]
            )
            XCTAssertEqual(retainedContextAfterRejection.tabID, firstBoundContext.tabID)
            XCTAssertEqual(retainedContextAfterRejection.runID, firstBoundContext.runID)
            XCTAssertEqual(retainedContextAfterRejection.workspaceID, firstBoundContext.workspaceID)
            XCTAssertEqual(retainedContextAfterRejection.selection, firstBoundContext.selection)
            XCTAssertNil(window.mcpServer.connectionID(forRunID: secondRunID))
            XCTAssertTrue(pendingAfterRejection.contains { $0.runID == secondRunID })

            let rejectedHandoverResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: rejectedHandoverConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            XCTAssertEqual(rejectedHandoverResult.outcome, "rejected:session_token_bound_to_other_run")
            XCTAssertEqual(rejectedHandoverResult.runID, secondRunID)
            let rejectedHandoverRunID = await manager.runIDForConnection(rejectedHandoverConnectionID)
            XCTAssertNil(rejectedHandoverRunID)

            let freshSessionKey = "fresh-run-token-\(UUID().uuidString)"
            XCTAssertNotEqual(freshSessionKey, sessionKey)
            let freshResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: freshConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: freshSessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            XCTAssertEqual(freshResult.outcome, "applied")
            XCTAssertEqual(freshResult.runID, secondRunID)
            let freshRunID = await manager.runIDForConnection(freshConnectionID)
            XCTAssertEqual(freshRunID, secondRunID)
            XCTAssertEqual(window.mcpServer.tabContextByConnectionID[freshConnectionID]?.tabID, secondTabID)

            await cleanup(
                runID: secondRunID,
                connectionID: freshConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await manager.removeConnection(rejectedHandoverConnectionID)
            await cleanup(
                runID: firstRunID,
                connectionID: retainedConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Connection/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testRetainedConnectionCanConsumeSameRunPolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let firstWindowID = 61012
            let secondWindowID = 61013
            let sessionKey = "same-run-connection-reuse-\(UUID().uuidString)"
            await installPolicy(runID: runID, windowID: firstWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let firstResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(firstResult.outcome, "applied")

            await installPolicy(runID: runID, windowID: secondWindowID)
            let reconnectResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )

            XCTAssertEqual(reconnectResult.outcome, "applied")
            XCTAssertEqual(reconnectResult.runID, runID)
            XCTAssertEqual(reconnectResult.windowID, secondWindowID)
            let reconnectedRunID = await manager.runIDForConnection(connectionID)
            XCTAssertEqual(reconnectedRunID, runID)

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: secondWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Connection/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testTerminalRunCleanupReleasesAffinityBeforeFreshRunBinding() async throws {
        #if DEBUG
            let completedRunID = UUID()
            let resumedRunID = UUID()
            let completedConnectionID = UUID()
            let resumedConnectionID = UUID()
            let completedWindowID = 61014
            let resumedWindowID = 61015
            let completedSessionKey = "terminal-release-\(UUID().uuidString)"
            let resumedSessionKey = "fresh-resume-\(UUID().uuidString)"
            XCTAssertNotEqual(completedRunID, resumedRunID)
            XCTAssertNotEqual(completedConnectionID, resumedConnectionID)
            XCTAssertNotEqual(completedSessionKey, resumedSessionKey)

            await installPolicy(runID: completedRunID, windowID: completedWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: completedRunID)
            let completedResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: completedConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: completedSessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(completedResult.outcome, "applied")
            XCTAssertEqual(completedResult.runID, completedRunID)

            await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: completedRunID)
            await manager.cleanupRunRoutingState(for: completedRunID, windowID: completedWindowID)
            let releasedRunID = await manager.runIDForConnection(completedConnectionID)
            let releasedRunPolicy = await manager.debugRunPolicyState(for: completedRunID)
            XCTAssertNil(releasedRunID)
            XCTAssertNil(releasedRunPolicy)
            await manager.removeConnection(completedConnectionID)

            await installPolicy(runID: resumedRunID, windowID: resumedWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: resumedRunID)
            let resumedResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: resumedConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: resumedSessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            let boundResumedRunID = await manager.runIDForConnection(resumedConnectionID)

            XCTAssertEqual(resumedResult.outcome, "applied")
            XCTAssertEqual(resumedResult.runID, resumedRunID)
            XCTAssertEqual(boundResumedRunID, resumedRunID)

            await cleanup(
                runID: resumedRunID,
                connectionID: resumedConnectionID,
                windowID: resumedWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Connection/run lifecycle diagnostics require DEBUG helpers.")
        #endif
    }

    func testAuthoritativePIDOwnedAgentModeRouteCannotReplaceLiveAffinityForAnyRole() async throws {
        #if DEBUG
            let roles: [AgentModelCatalog.TaskLabelKind?] = [nil] + AgentModelCatalog.TaskLabelKind.allCases
                .map(Optional.some)
            for (index, role) in roles.enumerated() {
                let sessionKey = "authoritative-role-agnostic-\(index)-\(UUID().uuidString)"
                let affinity = await seedLiveAffinity(sessionKey: sessionKey, windowID: 61100 + index * 2)
                let runID = UUID()
                let connectionID = UUID()
                let windowID = 61101 + index * 2
                await installAuthoritativePolicy(
                    runID: runID,
                    tabID: UUID(),
                    windowID: windowID,
                    taskLabelKind: role
                )
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

                let result = await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    sessionKey: sessionKey,
                    pidGateTimeout: 0.25,
                    requireRunRouting: false
                )

                XCTAssertEqual(
                    result.outcome,
                    "rejected:session_token_bound_to_other_run",
                    "role=\(role?.rawValue ?? "nil")"
                )
                XCTAssertEqual(result.runID, runID)
                let mappedRunID = await manager.runIDForConnection(connectionID)
                XCTAssertNil(mappedRunID)
                let pending = await manager.debugPendingPolicySnapshot(for: clientName)
                XCTAssertTrue(pending.contains { $0.runID == runID })
                await cleanup(
                    runID: runID,
                    connectionID: connectionID,
                    windowID: windowID,
                    expectedPID: getpid()
                )
                await cleanup(
                    runID: affinity.runID,
                    connectionID: affinity.connectionID,
                    windowID: affinity.windowID,
                    expectedPID: nil
                )
            }
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testAuthoritativeRouteCannotReplaceLiveAffinityForMismatchedPID() async throws {
        #if DEBUG
            let expectedTree = try makeSleepingProcessTree()
            let unrelatedTree = try makeSleepingProcessTree()
            defer {
                expectedTree.terminate()
                unrelatedTree.terminate()
            }
            let sessionKey = "authoritative-pid-mismatch-\(UUID().uuidString)"
            let affinity = await seedLiveAffinity(sessionKey: sessionKey, windowID: 61120)
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61121
            await installAuthoritativePolicy(runID: runID, tabID: UUID(), windowID: windowID)
            await manager.registerExpectedAgentPID(expectedTree.parentPID, for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(unrelatedTree.childPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.05,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "rejected:ownership_timeout")
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pending.contains { $0.runID == runID })
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: expectedTree.parentPID
            )
            await cleanup(
                runID: affinity.runID,
                connectionID: affinity.connectionID,
                windowID: affinity.windowID,
                expectedPID: nil
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testStaleLifecycleCannotReplaceLiveAffinityWithAuthoritativeRoute() async throws {
        #if DEBUG
            let sessionKey = "authoritative-stale-generation-\(UUID().uuidString)"
            let affinity = await seedLiveAffinity(sessionKey: sessionKey, windowID: 61122)
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61123
            await installAuthoritativePolicy(runID: runID, tabID: UUID(), windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false,
                expectedLifecycleGeneration: .max
            )

            XCTAssertEqual(result.outcome, "rejected:session_token_bound_to_other_run")
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pending.contains { $0.runID == runID })
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await cleanup(
                runID: affinity.runID,
                connectionID: affinity.connectionID,
                windowID: affinity.windowID,
                expectedPID: nil
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testUnreservedAgentModePolicyCannotReplaceLiveAffinity() async throws {
        #if DEBUG
            let sessionKey = "authoritative-unreserved-\(UUID().uuidString)"
            let affinity = await seedLiveAffinity(sessionKey: sessionKey, windowID: 61124)
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61125
            await installAuthoritativePolicy(
                runID: runID,
                tabID: UUID(),
                windowID: windowID,
                oneShot: false
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "rejected:session_token_bound_to_other_run")
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pending.contains { $0.runID == runID })
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await cleanup(
                runID: affinity.runID,
                connectionID: affinity.connectionID,
                windowID: affinity.windowID,
                expectedPID: nil
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testSameTokenReconnectWithoutConsumablePolicyRestoresLiveAffinity() async throws {
        #if DEBUG
            let sessionKey = "ordinary-live-affinity-reconnect-\(UUID().uuidString)"
            let affinity = await seedLiveAffinity(sessionKey: sessionKey, windowID: 61126)
            let reconnectConnectionID = UUID()

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: reconnectConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.05,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "fallback")
            let restoredRunID = await manager.runIDForConnection(reconnectConnectionID)
            XCTAssertEqual(restoredRunID, affinity.runID)
            await manager.removeConnection(reconnectConnectionID)
            await cleanup(
                runID: affinity.runID,
                connectionID: affinity.connectionID,
                windowID: affinity.windowID,
                expectedPID: nil
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testRejectedAuthoritativeRoutePreservesPriorLiveAffinityForReconnect() async throws {
        #if DEBUG
            let sessionKey = "authoritative-route-rollback-\(UUID().uuidString)"
            let affinity = await seedLiveAffinity(sessionKey: sessionKey, windowID: 61127)
            let childRunID = UUID()
            let childConnectionID = UUID()
            let missingWindowID = 61997
            await installAuthoritativePolicy(
                runID: childRunID,
                tabID: UUID(),
                windowID: missingWindowID
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: childRunID)

            let failedChild = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: childConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )

            XCTAssertEqual(failedChild.outcome, "rejected:session_token_bound_to_other_run")
            let pendingAfterFailure = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pendingAfterFailure.contains { $0.runID == childRunID })

            await cleanup(
                runID: childRunID,
                connectionID: childConnectionID,
                windowID: missingWindowID,
                expectedPID: getpid()
            )

            let reconnectConnectionID = UUID()
            let reconnect = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: reconnectConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.05,
                requireRunRouting: false
            )

            XCTAssertEqual(reconnect.outcome, "fallback")
            let restoredRunID = await manager.runIDForConnection(reconnectConnectionID)
            XCTAssertEqual(restoredRunID, affinity.runID)
            await manager.removeConnection(reconnectConnectionID)
            await cleanup(
                runID: affinity.runID,
                connectionID: affinity.connectionID,
                windowID: affinity.windowID,
                expectedPID: nil
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testRouteMappingFailureRejectsAndRestoresOneShotPolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let missingWindowID = 61999
            await installPolicy(runID: runID, windowID: missingWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )

            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            let mappedRunID = await manager.runIDForConnection(connectionID)
            XCTAssertEqual(result.outcome, "rejected:route_mapping_failed")
            XCTAssertEqual(result.restrictedTools, [])
            XCTAssertEqual(result.additionalTools, [])
            XCTAssertEqual(result.purpose, .unknown)
            XCTAssertNil(result.windowID)
            XCTAssertNil(mappedRunID)
            XCTAssertTrue(pending.contains { $0.runID == runID })

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: missingWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testSuspendedRouteInstallationReservesOneShotPolicyAndRollbackRestoresIt() async throws {
        #if DEBUG
            let runID = UUID()
            let firstConnectionID = UUID()
            let competingConnectionID = UUID()
            let retryConnectionID = UUID()
            let missingWindowID = 61998
            await installPolicy(runID: runID, windowID: missingWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.debugSuspendNextPendingPolicyRouteInstallation()

            let firstApplication = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: firstConnectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }

            let suspended = await waitUntil {
                await self.manager.debugIsPendingPolicyRouteInstallationSuspended()
            }
            XCTAssertTrue(suspended)

            let competingResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: competingConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            let reservedSnapshot = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(competingResult.outcome, "rejected:policy_reserved")
            XCTAssertTrue(reservedSnapshot.contains { $0.runID == runID })

            await manager.debugResumePendingPolicyRouteInstallation()
            let firstResult = await firstApplication.value
            XCTAssertEqual(firstResult.outcome, "rejected:route_mapping_failed")

            let retryResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: retryConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(retryResult.outcome, "applied")
            XCTAssertEqual(retryResult.runID, runID)
            let consumedSnapshot = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(consumedSnapshot.contains { $0.runID == runID })

            await manager.removeConnection(firstConnectionID)
            await manager.removeConnection(competingConnectionID)
            await cleanup(
                runID: runID,
                connectionID: retryConnectionID,
                windowID: missingWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Pending policy reservation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testRoutingSignalWaitsForOneShotPolicyCommit() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = window.windowID
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await MCPRoutingWaiter.cleanup(runID: runID)
            await MCPRoutingWaiter.register(runID: runID)

            let routeWaiter = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 5)
            }
            let didRegisterRouteWaiter = await waitUntil {
                await MCPRoutingWaiter.debugContinuationCount(runID: runID) == 1
            }
            XCTAssertTrue(didRegisterRouteWaiter)

            await manager.debugSuspendNextPendingPolicyCommit()
            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let didSuspendCommit = await waitUntil {
                await self.manager.debugIsPendingPolicyCommitSuspended()
            }
            XCTAssertTrue(didSuspendCommit)

            let pendingBeforeCommit = await manager.debugPendingPolicySnapshot(for: clientName)
            let waiterCountBeforeCommit = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertTrue(pendingBeforeCommit.contains { $0.runID == runID })
            XCTAssertEqual(waiterCountBeforeCommit, 1)

            await manager.debugResumePendingPolicyCommit()
            let result = await application.value
            let didRoute = await routeWaiter.value
            XCTAssertEqual(result.outcome, "applied")
            XCTAssertTrue(didRoute)

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Pending policy commit diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testStaleReplacementAdmissionRestoresDisplacedConnectionWithoutSchedulingReplacement() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let displacedConnectionID = UUID()
            let staleConnectionID = UUID()
            let windowID = window.windowID
            await manager.debugClearPendingPolicyReplacementSchedules()
            let didRegisterDisplacedConnection = window.mcpServer.registerRunIDMapping(
                connectionID: displacedConnectionID,
                runID: runID,
                windowID: windowID,
                signalRouting: false
            )
            XCTAssertTrue(didRegisterDisplacedConnection)
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            await manager.debugSuspendNextPendingPolicyCommit()
            let staleApplication = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: staleConnectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let didSuspendCommit = await waitUntil {
                await self.manager.debugIsPendingPolicyCommitSuspended()
            }
            XCTAssertTrue(didSuspendCommit)
            let mappedBeforeInvalidation = window.mcpServer.connectionID(forRunID: runID)
            let replacementSchedulesBeforeInvalidation = await manager
                .debugPendingPolicyReplacementScheduleCount(
                    existing: displacedConnectionID,
                    replacement: staleConnectionID,
                    runID: runID
                )
            XCTAssertEqual(mappedBeforeInvalidation, staleConnectionID)
            XCTAssertEqual(replacementSchedulesBeforeInvalidation, 0)

            await manager.debugInvalidatePendingPolicyApplication(connectionID: staleConnectionID)
            await manager.debugResumePendingPolicyCommit()
            let staleResult = await staleApplication.value
            XCTAssertEqual(staleResult.outcome, "rejected:stale_connection")

            let pendingAfterRollback = await manager.debugPendingPolicySnapshot(for: clientName)
            let mappedAfterRollback = window.mcpServer.connectionID(forRunID: runID)
            let replacementSchedulesAfterRollback = await manager
                .debugPendingPolicyReplacementScheduleCount(
                    existing: displacedConnectionID,
                    replacement: staleConnectionID,
                    runID: runID
                )
            XCTAssertTrue(pendingAfterRollback.contains { $0.runID == runID })
            XCTAssertEqual(mappedAfterRollback, displacedConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[displacedConnectionID], runID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[staleConnectionID])
            XCTAssertEqual(replacementSchedulesAfterRollback, 0)

            await cleanup(
                runID: runID,
                connectionID: staleConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await manager.debugClearPendingPolicyReplacementSchedules()
        #else
            throw XCTSkip("Pending policy commit diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testSuccessfulReplacementAdmissionSchedulesDisplacedConnectionExactlyOnce() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let displacedConnectionID = UUID()
            let replacementConnectionID = UUID()
            let windowID = window.windowID
            await manager.debugClearPendingPolicyReplacementSchedules()
            let didRegisterDisplacedConnection = window.mcpServer.registerRunIDMapping(
                connectionID: displacedConnectionID,
                runID: runID,
                windowID: windowID,
                signalRouting: false
            )
            XCTAssertTrue(didRegisterDisplacedConnection)
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: replacementConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )

            let replacementScheduleCount = await manager.debugPendingPolicyReplacementScheduleCount(
                existing: displacedConnectionID,
                replacement: replacementConnectionID,
                runID: runID
            )
            let pendingAfterCommit = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(result.outcome, "applied")
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), replacementConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[replacementConnectionID], runID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[displacedConnectionID])
            XCTAssertEqual(replacementScheduleCount, 1)
            XCTAssertFalse(pendingAfterCommit.contains { $0.runID == runID })

            await cleanup(
                runID: runID,
                connectionID: replacementConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await manager.debugClearPendingPolicyReplacementSchedules()
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testSupersededStaleReplacementRollbackDoesNotOverwriteNewerOwner() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let displacedConnectionID = UUID()
            let staleConnectionID = UUID()
            let newerConnectionID = UUID()
            let windowID = window.windowID
            await manager.debugClearPendingPolicyReplacementSchedules()
            XCTAssertTrue(window.mcpServer.registerRunIDMapping(
                connectionID: displacedConnectionID,
                runID: runID,
                windowID: windowID,
                signalRouting: false
            ))
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.debugSuspendNextPendingPolicyCommit()

            let staleApplication = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: staleConnectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let didSuspendCommit = await waitUntil {
                await self.manager.debugIsPendingPolicyCommitSuspended()
            }
            XCTAssertTrue(didSuspendCommit)
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), staleConnectionID)
            XCTAssertTrue(window.mcpServer.registerRunIDMapping(
                connectionID: newerConnectionID,
                runID: runID,
                windowID: windowID,
                signalRouting: false
            ))

            await manager.debugInvalidatePendingPolicyApplication(connectionID: staleConnectionID)
            await manager.debugResumePendingPolicyCommit()
            let staleResult = await staleApplication.value
            let pendingAfterRollback = await manager.debugPendingPolicySnapshot(for: clientName)
            let staleCachedRunID = await manager.debugCachedRunID(for: staleConnectionID)
            let retainedRunPolicy = await manager.debugRunPolicyState(for: runID)
            let deferredReplacementScheduleCount = await manager
                .debugPendingPolicyReplacementScheduleCount(
                    existing: displacedConnectionID,
                    replacement: staleConnectionID,
                    runID: runID
                )

            XCTAssertEqual(staleResult.outcome, "rejected:stale_connection")
            XCTAssertTrue(pendingAfterRollback.contains { $0.runID == runID })
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), newerConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[newerConnectionID], runID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[displacedConnectionID])
            XCTAssertNil(window.mcpServer.connectionIDToRunID[staleConnectionID])
            XCTAssertNil(staleCachedRunID)
            XCTAssertNotNil(retainedRunPolicy)
            XCTAssertEqual(deferredReplacementScheduleCount, 0)

            await cleanup(
                runID: runID,
                connectionID: staleConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await manager.debugClearPendingPolicyReplacementSchedules()
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testStaleReplacementRollbackDoesNotUndoNewerSameConnectionGeneration() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let displacedConnectionID = UUID()
            let replacementConnectionID = UUID()
            let windowID = window.windowID
            await manager.debugClearPendingPolicyReplacementSchedules()
            XCTAssertTrue(window.mcpServer.registerRunIDMapping(
                connectionID: displacedConnectionID,
                runID: runID,
                windowID: windowID,
                signalRouting: false
            ))
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.debugSuspendNextPendingPolicyCommit()

            let staleApplication = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: replacementConnectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let didSuspendCommit = await waitUntil {
                await self.manager.debugIsPendingPolicyCommitSuspended()
            }
            XCTAssertTrue(didSuspendCommit)
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), replacementConnectionID)

            let newerToken = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
                connectionID: replacementConnectionID,
                runID: runID,
                windowID: windowID
            ))
            XCTAssertTrue(window.mcpServer.isCurrentPendingPolicyRunIDMapping(newerToken))

            await manager.debugInvalidatePendingPolicyApplication(connectionID: replacementConnectionID)
            await manager.debugResumePendingPolicyCommit()
            let staleResult = await staleApplication.value
            let cachedRunID = await manager.debugCachedRunID(for: replacementConnectionID)
            let retainedRunPolicy = await manager.debugRunPolicyState(for: runID)

            XCTAssertEqual(staleResult.outcome, "rejected:stale_connection")
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), replacementConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[replacementConnectionID], runID)
            XCTAssertTrue(window.mcpServer.isCurrentPendingPolicyRunIDMapping(newerToken))
            XCTAssertEqual(cachedRunID, runID)
            XCTAssertNotNil(retainedRunPolicy)

            await cleanup(
                runID: runID,
                connectionID: replacementConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await manager.debugClearPendingPolicyReplacementSchedules()
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testSupersededPendingPolicyApplicationOwnershipCannotCommitCurrentRouteToken() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = window.windowID
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.debugSuspendNextPendingPolicyCommit()

            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let didSuspendCommit = await waitUntil {
                await self.manager.debugIsPendingPolicyCommitSuspended()
            }
            XCTAssertTrue(didSuspendCommit)
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), connectionID)

            await manager.debugSupersedePendingPolicyApplicationOwnership(
                connectionID: connectionID,
                runID: runID
            )
            await manager.debugResumePendingPolicyCommit()
            let result = await application.value
            let pendingAfterRollback = await manager.debugPendingPolicySnapshot(for: clientName)

            XCTAssertEqual(result.outcome, "rejected:stale_connection")
            XCTAssertTrue(pendingAfterRollback.contains { $0.runID == runID })
            XCTAssertNil(window.mcpServer.connectionID(forRunID: runID))

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testSupersededPendingTokenDoesNotBecomeCurrentAgainAfterNestedRollback() throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let firstRunID = UUID()
            let secondRunID = UUID()
            let connectionID = UUID()
            let windowID = window.windowID
            let firstToken = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
                connectionID: connectionID,
                runID: firstRunID,
                windowID: windowID
            ))
            let secondToken = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
                connectionID: connectionID,
                runID: secondRunID,
                windowID: windowID
            ))
            XCTAssertFalse(window.mcpServer.isCurrentPendingPolicyRunIDMapping(firstToken))
            XCTAssertTrue(window.mcpServer.isCurrentPendingPolicyRunIDMapping(secondToken))

            let rollbackResult = window.mcpServer.rollbackPendingPolicyRunIDMapping(
                secondToken,
                clientName: clientName,
                windowID: windowID,
                signalRoutingFailure: false
            )

            XCTAssertEqual(rollbackResult, .restored)
            XCTAssertNil(window.mcpServer.connectionID(forRunID: firstRunID))
            XCTAssertNil(window.mcpServer.connectionIDToRunID[connectionID])
            XCTAssertFalse(window.mcpServer.isCurrentPendingPolicyRunIDMapping(firstToken))
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testPendingPolicyRollbackPreservesNewerQueuedContext() throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = window.windowID
            let token = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
                connectionID: connectionID,
                runID: runID,
                windowID: windowID
            ))

            window.mcpServer.installTabContext(
                clientID: nil,
                clientName: clientName,
                windowID: windowID,
                workspaceID: nil,
                snapshot: ComposeTabState(),
                runID: runID,
                signalRouting: false
            )
            XCTAssertEqual(window.mcpServer.pendingContextQueueLength(clientName: clientName, windowID: windowID), 1)

            let rollbackResult = window.mcpServer.rollbackPendingPolicyRunIDMapping(
                token,
                clientName: clientName,
                windowID: windowID,
                signalRoutingFailure: false
            )

            XCTAssertEqual(rollbackResult, .restored)
            XCTAssertEqual(window.mcpServer.pendingContextQueueLength(clientName: clientName, windowID: windowID), 1)
            window.mcpServer.removeTabContext(
                forConnectionID: nil,
                clientName: clientName,
                windowID: windowID,
                runID: runID
            )
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testPendingPolicyRollbackDoesNotRestorePreviousRunAfterPrimaryGenerationChanges() throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let previousRunID = UUID()
            let pendingRunID = UUID()
            let connectionID = UUID()
            let newerPrimaryConnectionID = UUID()
            let windowID = window.windowID
            XCTAssertTrue(window.mcpServer.registerRunIDMapping(
                connectionID: connectionID,
                runID: previousRunID,
                windowID: windowID,
                signalRouting: false
            ))
            let token = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
                connectionID: connectionID,
                runID: pendingRunID,
                windowID: windowID
            ))
            XCTAssertTrue(window.mcpServer.registerRunIDMapping(
                connectionID: newerPrimaryConnectionID,
                runID: previousRunID,
                windowID: windowID,
                signalRouting: false
            ))

            let rollbackResult = window.mcpServer.rollbackPendingPolicyRunIDMapping(
                token,
                clientName: clientName,
                windowID: windowID,
                signalRoutingFailure: false
            )

            XCTAssertEqual(rollbackResult, .restored)
            XCTAssertNil(window.mcpServer.connectionID(forRunID: pendingRunID))
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: previousRunID), newerPrimaryConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[newerPrimaryConnectionID], previousRunID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[connectionID])
            window.mcpServer.cleanupRunIDMapping(
                runID: previousRunID,
                connectionID: newerPrimaryConnectionID,
                signalRoutingFailure: false
            )
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testStaleTabContextCleanupPreservesSilentReplacementRunMapping() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let staleConnectionID = UUID()
            let replacementConnectionID = UUID()
            let snapshot = ComposeTabState()
            await MCPRoutingWaiter.cleanup(runID: runID)
            await MCPRoutingWaiter.register(runID: runID)
            addTeardownBlock {
                await MCPRoutingWaiter.cleanup(runID: runID)
            }
            let routeWaiter = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 1)
            }
            let didRegisterWaiter = await waitUntil {
                await MCPRoutingWaiter.debugContinuationCount(runID: runID) == 1
            }
            XCTAssertTrue(didRegisterWaiter)

            window.mcpServer.installTabContext(
                clientID: staleConnectionID.uuidString,
                clientName: clientName,
                windowID: window.windowID,
                workspaceID: nil,
                snapshot: snapshot,
                runID: runID,
                signalRouting: false
            )
            let didRegisterReplacement = window.mcpServer.registerRunIDMapping(
                connectionID: replacementConnectionID,
                runID: runID,
                windowID: window.windowID,
                signalRouting: false
            )
            window.mcpServer.removeTabContext(
                forConnectionID: staleConnectionID,
                clientName: clientName,
                windowID: window.windowID,
                runID: runID
            )

            let waiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertTrue(didRegisterReplacement)
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], replacementConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[replacementConnectionID], runID)
            XCTAssertEqual(waiterCount, 1)

            await MCPRoutingWaiter.notifyRouted(runID: runID)
            let didRoute = await routeWaiter.value
            XCTAssertTrue(didRoute)
        #else
            throw XCTSkip("Tab-context routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testPolicyCleanupWhileWaitingRejectsWithoutFallbackBinding() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61006
            await installPolicy(runID: runID, windowID: windowID)
            await manager.debugClearRunRoutingHistoryForTesting()

            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 1.0,
                    requireRunRouting: false
                )
            }

            let waitStarted = await waitForEvent("pid_gate_wait_started", runID: runID)
            XCTAssertTrue(waitStarted)
            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
            let result = await application.value

            XCTAssertEqual(result.outcome, "rejected:policy_removed")
            let mappedRunID = await manager.runIDForConnection(connectionID)
            XCTAssertNil(mappedRunID)
            await cleanup(runID: runID, connectionID: connectionID, windowID: windowID, expectedPID: nil)
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    #if DEBUG
        @MainActor
        private func makeWindow() -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            return window
        }

        private func installPolicy(runID: UUID, windowID: Int) async {
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "OpenCode routing race test",
                ttl: 10,
                tabID: nil,
                runID: runID,
                additionalTools: nil,
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: true
            )
        }

        private func installAuthoritativePolicy(
            runID: UUID,
            tabID: UUID,
            windowID: Int,
            oneShot: Bool = true,
            taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil
        ) async {
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: oneShot,
                reason: "Authoritative PID-owned route test",
                ttl: 10,
                tabID: tabID,
                runID: runID,
                additionalTools: nil,
                purpose: .agentModeRun,
                taskLabelKind: taskLabelKind,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: true
            )
        }

        private func seedLiveAffinity(
            sessionKey: String,
            windowID: Int
        ) async -> (runID: UUID, connectionID: UUID, windowID: Int) {
            let runID = UUID()
            let connectionID = UUID()
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(result.outcome, "applied")
            XCTAssertEqual(result.runID, runID)
            await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
            return (runID, connectionID, windowID)
        }

        private func cleanup(
            runID: UUID,
            connectionID: UUID,
            windowID: Int,
            expectedPID: pid_t?
        ) async {
            if let expectedPID {
                await manager.clearExpectedAgentPID(expectedPID, for: clientName, runID: runID)
            }
            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
            await manager.removeConnection(connectionID)
            await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
        }

        private func waitUntil(
            timeout: TimeInterval = 1.0,
            condition: @escaping () async -> Bool
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if await condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            } while Date() < deadline
            return false
        }

        private func waitForEvent(
            _ event: String,
            runID: UUID,
            timeout: TimeInterval = 1.0
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                let payload = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 100)
                let events = payload["events"] as? [[String: Any]] ?? []
                if events.contains(where: { $0["event"] as? String == event }) {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            } while Date() < deadline
            return false
        }

        private struct SleepingProcessTree {
            let parent: Process
            let childPID: pid_t
            let parentExited: DispatchSemaphore

            var parentPID: pid_t {
                parent.processIdentifier
            }

            func terminate() {
                _ = Darwin.kill(childPID, SIGTERM)
                _ = Darwin.kill(parentPID, SIGTERM)
                guard parentExited.wait(timeout: .now() + 0.25) == .timedOut else {
                    parent.waitUntilExit()
                    return
                }

                _ = Darwin.kill(childPID, SIGKILL)
                _ = Darwin.kill(parentPID, SIGKILL)
                if parentExited.wait(timeout: .now() + 1.0) == .success {
                    parent.waitUntilExit()
                }
            }
        }

        private func makeSleepingProcessTree() throws -> SleepingProcessTree {
            let process = Process()
            let stdout = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3",
                "-c",
                "import subprocess; child=subprocess.Popen(['/bin/sleep','30']); print(child.pid, flush=True); child.wait()"
            ]
            process.standardOutput = stdout
            let parentExited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in parentExited.signal() }
            try process.run()
            var data = Data()
            while data.count < 32 {
                guard let byte = try stdout.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { break }
                if byte == Data([0x0A]) { break }
                data.append(byte)
            }
            guard let text = String(data: data, encoding: .utf8),
                  let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                process.terminate()
                process.waitUntilExit()
                throw NSError(
                    domain: "MCPAgentPolicyAdmissionRaceTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to read child PID from process-tree fixture."]
                )
            }
            return SleepingProcessTree(parent: process, childPID: childPID, parentExited: parentExited)
        }
    #endif
}
