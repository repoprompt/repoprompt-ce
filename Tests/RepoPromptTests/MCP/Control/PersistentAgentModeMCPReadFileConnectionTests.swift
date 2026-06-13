import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class PersistentAgentModeMCPReadFileConnectionTests: XCTestCase {
    func testPairAgentOwnedConnectionReplacesPriorSessionAffinityAndPersistsCanonicalSelection() async throws {
        #if DEBUG
            try await withFixture(agentOwned: true) { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .agentOwnedCanonicalSelection)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testAgentOwnedExplicitSetPersistsForIndependentCanonicalLookup() async throws {
        #if DEBUG
            try await withFixture(agentOwned: true) { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .agentOwnedExplicitSetIndependentLookup)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testPairAgentOwnedNoRangeReadSelectsNonEmptyWorktreeLogicalFile() async throws {
        #if DEBUG
            try await withFixture(agentOwned: true, inactiveAgentTab: true) { fixture in
                try await fixture.installWorktreeBinding()
                try await runCheckpoint(fixture: fixture, scenario: .agentOwnedNoRangeNonEmptyWorktreeFile)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testCodexAgentModeLeaseRetainsOneMCPServerSessionAcrossSerialExactAbsoluteReadFileCalls() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .serialReads)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testRetainedReadRepliesReturnBeforeWorkspaceContextDrainSettlesAutoSelection() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .workspaceContextDrain)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testRetainedPromptExportWaitsForPendingReadSelectionDrain() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .promptExportDrain)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testRetainedManageSelectionClearDrainsPendingReadAdditionBeforeApplyingClear() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .manageSelectionClear)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testRetainedEndOfRunCleanupWaitsForAcceptedReadSelectionAndCommitsFinalState() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .endOfRun)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testRetainedEligibleContentSearchReplyReturnsBeforeWorkspaceContextDrainSettlesAutoSelection() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .searchWorkspaceContextDrain)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testReadAutoSelectionDeclinesWhenBoundTabClosesDuringPersistenceSuspension() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .tabCloseDuringPersistence)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testReadAutoSelectionResolvesWorkspaceAndTabAgainAfterWorkspaceReorder() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .workspaceReorderDuringPersistence)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testReadAutoSelectionDeclinesWhenConnectionRebindsDuringPersistenceSuspension() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .rebindDuringPersistence)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }
}

#if DEBUG
    private extension PersistentAgentModeMCPReadFileConnectionTests {
        enum CheckpointScenario {
            case serialReads
            case workspaceContextDrain
            case promptExportDrain
            case manageSelectionClear
            case endOfRun
            case searchWorkspaceContextDrain
            case tabCloseDuringPersistence
            case workspaceReorderDuringPersistence
            case rebindDuringPersistence
            case agentOwnedCanonicalSelection
            case agentOwnedExplicitSetIndependentLookup
            case agentOwnedNoRangeNonEmptyWorktreeFile

            var requiresSerialReadPrelude: Bool {
                switch self {
                case .agentOwnedNoRangeNonEmptyWorktreeFile:
                    false
                default:
                    true
                }
            }
        }

        func withFixture(
            agentOwned: Bool = false,
            inactiveAgentTab: Bool = false,
            _ operation: (Fixture) async throws -> Void
        ) async throws {
            let fixture = try await Fixture.make(agentOwned: agentOwned, inactiveAgentTab: inactiveAgentTab)
            do {
                try await operation(fixture)
                await fixture.cleanup()
                let pendingAfterCleanup = await fixture.networkManager.debugPendingPolicySnapshot(
                    for: AgentProviderKind.codexMCPClientID
                )
                XCTAssertFalse(pendingAfterCleanup.contains { $0.runID == Fixture.runID })
                let runPolicyAfterCleanup = await fixture.networkManager.debugRunPolicyState(for: Fixture.runID)
                XCTAssertNil(runPolicyAfterCleanup)
            } catch {
                await fixture.cleanup()
                throw error
            }
        }

        /// Dynamically proves one real retained BootstrapSocketConnectionManager/MCP.Server
        /// initialization and ordinary wire-level CallTool dispatch over one connected FD.
        /// The direct socketpair manager is intentionally not inserted into the parent's private
        /// dashboard registry, so registry history and registry-derived fingerprint claims remain
        /// outside this checkpoint's proof boundary.
        func runCheckpoint(fixture: Fixture, scenario: CheckpointScenario) async throws {
            let spec = fixture.spec
            XCTAssertEqual(spec.clientName, AgentProviderKind.codexMCPClientID)
            XCTAssertEqual(spec.purpose, .agentModeRun)
            XCTAssertTrue(spec.oneShot)
            XCTAssertTrue(spec.requiresExpectedAgentPID)
            XCTAssertEqual(spec.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
            XCTAssertEqual(spec.additionalTools, AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec))

            let pendingBeforeInitialize = await fixture.networkManager.debugPendingPolicySnapshot(
                for: AgentProviderKind.codexMCPClientID
            )
            XCTAssertEqual(pendingBeforeInitialize.count, 1)
            XCTAssertEqual(pendingBeforeInitialize.first?.windowID, fixture.windowID)
            XCTAssertEqual(pendingBeforeInitialize.first?.tabID, Fixture.tabID)
            XCTAssertEqual(pendingBeforeInitialize.first?.runID, Fixture.runID)
            XCTAssertEqual(pendingBeforeInitialize.first?.oneShot, true)
            XCTAssertEqual(pendingBeforeInitialize.first?.purpose, .agentModeRun)

            let manager = fixture.connectionManager
            let recorder = fixture.handshakeRecorder
            let networkManager = fixture.networkManager
            let startTask = Task {
                try await manager.start { clientInfo in
                    await recorder.recordInitialize(clientName: clientInfo.name)
                    let admission = await networkManager.debugAgentPolicyAdmissionStatus(
                        clientName: AgentProviderKind.codexMCPClientID,
                        bootstrapClientName: AgentProviderKind.codexMCPClientID,
                        connectionID: Fixture.connectionID,
                        sessionKey: Fixture.sessionToken,
                        clientPid: Int(getpid())
                    )
                    await recorder.recordAdmission(admission)
                    guard admission == "ready" else { return false }

                    let applied = await networkManager.debugApplyPendingPolicy(
                        clientName: AgentProviderKind.codexMCPClientID,
                        connectionID: Fixture.connectionID,
                        clientPid: Int(getpid()),
                        bootstrapClientName: AgentProviderKind.codexMCPClientID
                    )
                    await recorder.recordPolicyApplication(
                        restrictedTools: applied.restrictedTools,
                        additionalTools: applied.additionalTools,
                        purpose: applied.purpose,
                        windowID: applied.windowID
                    )
                    return true
                }
            }

            do {
                let initializeResponse = try await fixture.socketClient.request(
                    id: 1,
                    method: "initialize",
                    params: [
                        "protocolVersion": "2025-11-25",
                        "capabilities": [:],
                        "clientInfo": [
                            "name": AgentProviderKind.codexMCPClientID,
                            "version": "persistent-agent-mode-read-file-checkpoint"
                        ]
                    ]
                )
                try Self.assertSuccessfulResponse(initializeResponse, id: 1)
                try await startTask.value
            } catch {
                startTask.cancel()
                await manager.stop()
                _ = try? await startTask.value
                throw error
            }

            try fixture.socketClient.sendNotification(
                method: "notifications/initialized",
                params: [:]
            )
            let toolsResponse = try await fixture.socketClient.request(
                id: 2,
                method: "tools/list",
                params: [:]
            )
            XCTAssertTrue(try Self.toolNames(from: toolsResponse).contains(MCPWindowToolName.readFile))

            let routed = await fixture.lease.releaseWhenRouted(timeoutMs: 1000)
            XCTAssertTrue(routed)

            let baseline = await fixture.retainedConnectionSnapshot()
            Self.assertStableAgentModeSnapshot(baseline, fixture: fixture)
            if scenario == .agentOwnedNoRangeNonEmptyWorktreeFile
                || scenario == .agentOwnedExplicitSetIndependentLookup
            {
                try await fixture.installPeerWindowLookupSnapshot()
            }

            if scenario.requiresSerialReadPrelude {
                var firstFormattedRead: String?
                for requestID in 3 ... 5 {
                    let response = try await fixture.socketClient.request(
                        id: requestID,
                        method: "tools/call",
                        params: [
                            "name": MCPWindowToolName.readFile,
                            "arguments": ["path": fixture.fileURL.path]
                        ]
                    )
                    let formattedRead = try Self.readFileText(from: response, id: requestID)
                    XCTAssertTrue(formattedRead.contains(Fixture.sentinelContent), formattedRead)
                    if let firstFormattedRead {
                        XCTAssertEqual(formattedRead, firstFormattedRead)
                    } else {
                        firstFormattedRead = formattedRead
                    }

                    let current = await fixture.retainedConnectionSnapshot()
                    XCTAssertEqual(current, baseline)
                    Self.assertStableAgentModeSnapshot(current, fixture: fixture)
                }
            }

            switch scenario {
            case .serialReads:
                break
            case .workspaceContextDrain:
                try await assertWorkspaceContextDrain(fixture: fixture)
            case .promptExportDrain:
                try await assertPromptExportDrain(fixture: fixture)
            case .manageSelectionClear:
                try await assertManageSelectionClearOrdering(fixture: fixture)
            case .endOfRun:
                try await assertEndOfRunFinish(fixture: fixture)
            case .searchWorkspaceContextDrain:
                try await assertSearchWorkspaceContextDrain(fixture: fixture)
            case .tabCloseDuringPersistence:
                try await assertTabCloseDuringAutoSelectionPersistence(fixture: fixture)
            case .workspaceReorderDuringPersistence:
                try await assertWorkspaceReorderDuringAutoSelectionPersistence(fixture: fixture)
            case .rebindDuringPersistence:
                try await assertRebindDuringAutoSelectionPersistence(fixture: fixture)
            case .agentOwnedCanonicalSelection:
                try await assertAgentOwnedCanonicalSelection(fixture: fixture)
            case .agentOwnedExplicitSetIndependentLookup:
                try await assertAgentOwnedExplicitSetIndependentLookup(fixture: fixture)
            case .agentOwnedNoRangeNonEmptyWorktreeFile:
                try await assertAgentOwnedNoRangeNonEmptyWorktreeFile(fixture: fixture)
            }
        }

        func assertAgentOwnedExplicitSetIndependentLookup(fixture: Fixture) async throws {
            try await clearSelection(fixture: fixture, id: 6)
            let explicitSet = try await fixture.socketClient.request(
                id: 7,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": [
                        "op": "set",
                        "paths": [Fixture.liveRelativePath],
                        "mode": "full",
                        "view": "files",
                        "strict": true
                    ]
                ]
            )
            try Self.assertSuccessfulResponse(explicitSet, id: 7)
            XCTAssertTrue(explicitSet.contains(fixture.liveFileURL.lastPathComponent), explicitSet)
            assertCanonicalSelection(
                fixture: fixture,
                selectedPaths: [fixture.liveFileURL.path],
                slices: [:]
            )
            XCTAssertEqual(
                fixture.peerCanonicalSelection()?.selectedPaths,
                [fixture.liveFileURL.path]
            )

            let independent = try await fixture.makeIndependentPeerConnection()
            do {
                let independentGet = try await independent.socketClient.request(
                    id: 4,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.manageSelection,
                        "arguments": [
                            "op": "get",
                            "view": "files",
                            "path_display": "full",
                            "_rawJSON": true
                        ]
                    ]
                )
                let selectionText = try Self.readFileText(from: independentGet, id: 4)
                XCTAssertTrue(selectionText.contains(fixture.liveFileURL.path), selectionText)
                XCTAssertTrue(selectionText.contains("\"full_count\":1"), selectionText)
                XCTAssertGreaterThan(try Self.totalTokens(fromSelectionText: selectionText), 0)
            } catch {
                await independent.cleanup()
                throw error
            }
            await independent.cleanup()
        }

        func assertAgentOwnedNoRangeNonEmptyWorktreeFile(fixture: Fixture) async throws {
            let explicitSet = try await fixture.socketClient.request(
                id: 6,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": [
                        "op": "set",
                        "paths": [Fixture.liveRelativePath],
                        "mode": "full",
                        "view": "files"
                    ]
                ]
            )
            try Self.assertSuccessfulResponse(explicitSet, id: 6)
            let explicitGet = try await fixture.socketClient.request(
                id: 7,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": ["op": "get", "view": "files"]
                ]
            )
            try Self.assertSuccessfulResponse(explicitGet, id: 7)
            XCTAssertTrue(explicitGet.contains(fixture.liveFileURL.lastPathComponent), explicitGet)
            assertCanonicalSelection(
                fixture: fixture,
                selectedPaths: [fixture.liveFileURL.path],
                slices: [:]
            )

            try await clearSelection(fixture: fixture, id: 8)
            let rangedRead = try await fixture.socketClient.request(
                id: 9,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.readFile,
                    "arguments": [
                        "path": Fixture.liveRelativePath,
                        "start_line": 2,
                        "limit": 2
                    ]
                ]
            )
            let rangedText = try Self.readFileText(from: rangedRead, id: 9)
            XCTAssertTrue(rangedText.contains("**Lines**: 2–3 of 175"), rangedText)
            let rangedGet = try await fixture.socketClient.request(
                id: 10,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": [
                        "op": "get",
                        "view": "files",
                        "_rawJSON": true
                    ]
                ]
            )
            let rangedSelectionText = try Self.readFileText(from: rangedGet, id: 10)
            XCTAssertTrue(rangedSelectionText.contains("\"full_count\":0"), rangedSelectionText)
            XCTAssertTrue(rangedSelectionText.contains("\"slice_count\":1"), rangedSelectionText)
            XCTAssertTrue(rangedSelectionText.contains("\"render_mode\":\"slice\""), rangedSelectionText)
            assertCanonicalSelection(
                fixture: fixture,
                selectedPaths: [fixture.liveFileURL.path],
                slices: [fixture.liveFileURL.path: [LineRange(start: 2, end: 3)]]
            )

            try await clearSelection(fixture: fixture, id: 11)
            let revisionAfterClear = fixture.canonicalSelectionRevision()
            let predecessorGeneration = try XCTUnwrap(
                fixture.window.mcpServer.tabContextByConnectionID[Fixture.connectionID]?
                    .readFileAutoSelectionGeneration
            )
            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                fixture.window.mcpServer.setReadFileAutoSelectionPredecessorDrainWaiterRegisteredHandlerForTesting(nil)
                Task { await gate.release() }
            }

            let fullRead = try await fixture.socketClient.request(
                id: 12,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.readFile,
                    "arguments": ["path": Fixture.liveRelativePath]
                ]
            )
            let fullText = try Self.readFileText(from: fullRead, id: 12)
            XCTAssertTrue(fullText.contains("/\(Fixture.liveRelativePath)"), fullText)
            XCTAssertFalse(fullText.contains("**Path**: `\(Fixture.liveRelativePath)`"), fullText)
            XCTAssertTrue(fullText.contains("**Lines**: 1–175 of 175"), fullText)
            XCTAssertTrue(fullText.contains("final class GeneratedOracleExportFileWriterTests"), fullText)
            try await requireGateStarted(gate)
            XCTAssertEqual(fixture.canonicalSelectionRevision(), revisionAfterClear)
            XCTAssertEqual(
                fixture.window.mcpServer.readFileAutoSelectionDiagnosticsSnapshot().canonicalWorkerCount,
                1
            )

            let handover = try await fixture.makeHandoverConnection()
            do {
                let replacementContext = try XCTUnwrap(
                    fixture.window.mcpServer.tabContextByConnectionID[handover.connectionID]
                )
                XCTAssertEqual(replacementContext.runID, Fixture.runID)
                XCTAssertEqual(replacementContext.tabID, Fixture.tabID)
                XCTAssertEqual(replacementContext.workspaceID, fixture.workspaceID)
                XCTAssertGreaterThan(replacementContext.readFileAutoSelectionGeneration, predecessorGeneration)
                XCTAssertEqual(
                    fixture.window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                        connectionID: handover.connectionID
                    ),
                    [Fixture.connectionID]
                )
                XCTAssertEqual(fixture.window.mcpServer.connectionID(forRunID: Fixture.runID), handover.connectionID)
                XCTAssertNil(fixture.window.mcpServer.connectionIDToRunID[Fixture.connectionID])

                let predecessorDrainWaiterRegistered = expectation(
                    description: "replacement manage_selection registered predecessor drain waiter"
                )
                fixture.window.mcpServer.setReadFileAutoSelectionPredecessorDrainWaiterRegisteredHandlerForTesting {
                    predecessorDrainWaiterRegistered.fulfill()
                }
                let getFinished = PersistentAsyncSignal()
                let getTask = Task {
                    let response = try await handover.socketClient.request(
                        id: 3,
                        method: "tools/call",
                        params: [
                            "name": MCPWindowToolName.manageSelection,
                            "arguments": ["op": "get", "view": "files"]
                        ]
                    )
                    await getFinished.mark()
                    return response
                }
                await fulfillment(of: [predecessorDrainWaiterRegistered], timeout: 2)
                let getReturnedAfterWaiterRegistration = await getFinished.isMarked()
                XCTAssertFalse(
                    getReturnedAfterWaiterRegistration,
                    "Replacement get must remain suspended after registering the exact predecessor waiter"
                )

                await gate.release()
                let fullGet = try await getTask.value
                try Self.assertSuccessfulResponse(fullGet, id: 3)
                XCTAssertTrue(fullGet.contains(fixture.liveFileURL.lastPathComponent), fullGet)
                XCTAssertGreaterThan(fixture.canonicalSelectionRevision(), revisionAfterClear)
                assertCanonicalSelection(
                    fixture: fixture,
                    selectedPaths: [fixture.liveFileURL.path],
                    slices: [:]
                )

                let addWorktreeOnly = try await handover.socketClient.request(
                    id: 4,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.manageSelection,
                        "arguments": [
                            "op": "add",
                            "paths": [Fixture.worktreeOnlyRelativePath],
                            "view": "files"
                        ]
                    ]
                )
                try Self.assertSuccessfulResponse(addWorktreeOnly, id: 4)
                try await Task.sleep(for: .milliseconds(250))
                let expectedPeerSelection = StoredSelection(
                    selectedPaths: [fixture.liveFileURL.path, fixture.worktreeOnlyLogicalURL.path]
                )
                XCTAssertEqual(
                    Set(fixture.window.workspaceManager.composeTab(
                        for: WorkspaceSelectionIdentity(
                            workspaceID: fixture.workspaceID,
                            tabID: Fixture.tabID
                        )
                    )?.selection.selectedPaths ?? []),
                    Set(expectedPeerSelection.selectedPaths)
                )
                fixture.assertPeerIsolationAndLifecycle(expectedSelection: expectedPeerSelection)

                // Match the completed child lifecycle: terminal cleanup drops run affinity,
                // then the provider-owned connection tears down without a Context Builder commit.
                await fixture.networkManager.cleanupRunRoutingState(
                    for: Fixture.runID,
                    windowID: fixture.windowID
                )
                await handover.cleanup()
                XCTAssertNil(fixture.window.mcpServer.tabContextByConnectionID[handover.connectionID])
                XCTAssertTrue(
                    fixture.window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                        connectionID: handover.connectionID
                    ).isEmpty
                )
                let completedSelection = StoredSelection(
                    selectedPaths: [fixture.liveFileURL.path, fixture.worktreeOnlyLogicalURL.path]
                )
                XCTAssertEqual(
                    Set(fixture.window.workspaceManager.composeTab(
                        for: WorkspaceSelectionIdentity(
                            workspaceID: fixture.workspaceID,
                            tabID: Fixture.tabID
                        )
                    )?.selection.selectedPaths ?? []),
                    Set(completedSelection.selectedPaths)
                )
                fixture.assertPeerIsolationAndLifecycle(expectedSelection: completedSelection)

                let independent = try await fixture.makeIndependentPeerConnection()
                do {
                    let independentGet = try await independent.socketClient.request(
                        id: 4,
                        method: "tools/call",
                        params: [
                            "name": MCPWindowToolName.manageSelection,
                            "arguments": [
                                "op": "get",
                                "view": "files",
                                "path_display": "full",
                                "_rawJSON": true
                            ]
                        ]
                    )
                    let independentSelectionText = try Self.readFileText(from: independentGet, id: 4)
                    XCTAssertTrue(
                        independentSelectionText.contains(fixture.liveFileURL.path),
                        independentSelectionText
                    )
                    XCTAssertTrue(
                        independentSelectionText.contains(fixture.worktreeOnlyLogicalURL.path),
                        independentSelectionText
                    )
                    XCTAssertTrue(
                        independentSelectionText.contains("\"full_count\":1"),
                        independentSelectionText
                    )
                    let totalTokens = try Self.totalTokens(fromSelectionText: independentSelectionText)
                    XCTAssertGreaterThan(totalTokens, 0, independentSelectionText)
                } catch {
                    await independent.cleanup()
                    throw error
                }
                await independent.cleanup()
            } catch {
                await handover.cleanup()
                throw error
            }
            await handover.cleanup()
        }

        func assertAgentOwnedCanonicalSelection(fixture: Fixture) async throws {
            XCTAssertEqual(fixture.spec.taskLabelKind, .pair)
            XCTAssertEqual(
                fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.activeAgentSessionID,
                Fixture.agentSessionID
            )
            XCTAssertEqual(
                fixture.window.promptManager.currentComposeTabs.first(where: { $0.id == Fixture.tabID })?.activeAgentSessionID,
                Fixture.agentSessionID
            )

            try await clearSelection(fixture: fixture, id: 6)
            assertCanonicalSelection(
                fixture: fixture,
                selectedPaths: [],
                slices: [:]
            )

            let addResponse = try await fixture.socketClient.request(
                id: 7,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": [
                        "op": "add",
                        "paths": [fixture.fileURL.path],
                        "view": "files"
                    ]
                ]
            )
            try Self.assertSuccessfulResponse(addResponse, id: 7)
            let getAfterAdd = try await fixture.socketClient.request(
                id: 8,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": ["op": "get", "view": "files"]
                ]
            )
            try Self.assertSuccessfulResponse(getAfterAdd, id: 8)
            XCTAssertTrue(getAfterAdd.contains(fixture.fileURL.lastPathComponent), getAfterAdd)
            assertCanonicalSelection(
                fixture: fixture,
                selectedPaths: [fixture.fileURL.path],
                slices: [:]
            )

            try await clearSelection(fixture: fixture, id: 9)
            let partialRead = try await fixture.socketClient.request(
                id: 10,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.readFile,
                    "arguments": [
                        "path": fixture.fileURL.path,
                        "start_line": 2,
                        "limit": 2
                    ]
                ]
            )
            let partialText = try Self.readFileText(from: partialRead, id: 10)
            XCTAssertTrue(partialText.contains("persistentAgentModeLineTwo"), partialText)
            let partialDrain = try await fixture.socketClient.request(
                id: 11,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": ["op": "get", "view": "files"]
                ]
            )
            try Self.assertSuccessfulResponse(partialDrain, id: 11)
            assertCanonicalSelection(
                fixture: fixture,
                selectedPaths: [fixture.fileURL.path],
                slices: [fixture.fileURL.path: [LineRange(start: 2, end: 3)]]
            )

            let fullRead = try await fixture.socketClient.request(
                id: 12,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.readFile,
                    "arguments": ["path": fixture.fileURL.path]
                ]
            )
            let fullText = try Self.readFileText(from: fullRead, id: 12)
            XCTAssertTrue(fullText.contains(Fixture.sentinelContent), fullText)
            let fullDrain = try await fixture.socketClient.request(
                id: 13,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": ["op": "get", "view": "files"]
                ]
            )
            try Self.assertSuccessfulResponse(fullDrain, id: 13)
            assertCanonicalSelection(
                fixture: fixture,
                selectedPaths: [fixture.fileURL.path],
                slices: [:]
            )

            let committed = await fixture.window.mcpServer.commitAndClearTabContext(
                connectionID: Fixture.connectionID,
                expectedRunID: Fixture.runID
            )
            XCTAssertTrue(committed)
            XCTAssertNil(fixture.window.mcpServer.tabContextByConnectionID[Fixture.connectionID])
            assertCanonicalSelection(
                fixture: fixture,
                selectedPaths: [fixture.fileURL.path],
                slices: [:]
            )
        }

        func assertCanonicalSelection(
            fixture: Fixture,
            selectedPaths: [String],
            slices: [String: [LineRange]],
            expectHeaderMirror: Bool = true
        ) {
            let stored = fixture.window.workspaceManager.composeTab(with: Fixture.tabID)
            XCTAssertEqual(stored?.selection.selectedPaths, selectedPaths)
            XCTAssertEqual(stored?.selection.slices, slices)
            XCTAssertEqual(stored?.activeAgentSessionID, Fixture.agentSessionID)

            let header = fixture.window.promptManager.currentComposeTabs.first { $0.id == Fixture.tabID }
            if expectHeaderMirror {
                XCTAssertEqual(header?.selection.selectedPaths, selectedPaths)
                XCTAssertEqual(header?.selection.slices, slices)
            }
            XCTAssertEqual(header?.activeAgentSessionID, Fixture.agentSessionID)
        }

        func assertWorkspaceContextDrain(fixture: Fixture) async throws {
            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                Task { await gate.release() }
            }

            let firstRead = gatedReadTask(fixture: fixture, id: 6)
            try await requireGateStarted(gate)
            try await assertReadReplyReturned(firstRead, gate: gate, id: 6)
            let secondRead = gatedReadTask(fixture: fixture, id: 7)
            try await assertReadReplyReturned(secondRead, gate: gate, id: 7)

            let contextFinished = PersistentAsyncSignal()
            let contextTask = Task {
                let response = try await fixture.socketClient.request(
                    id: 8,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.workspaceContext,
                        "arguments": [:]
                    ]
                )
                await contextFinished.mark()
                return response
            }
            try await Task.sleep(for: .milliseconds(50))
            let contextReturnedBeforeDrain = await contextFinished.isMarked()
            XCTAssertFalse(contextReturnedBeforeDrain)

            await gate.release()
            let contextResponse = try await contextTask.value
            try Self.assertSuccessfulResponse(contextResponse, id: 8)
            XCTAssertTrue(contextResponse.contains("PersistentAgentModeFixture.swift"), contextResponse)
            let current = await fixture.retainedConnectionSnapshot()
            Self.assertStableAgentModeSnapshot(current, fixture: fixture)
        }

        func assertPromptExportDrain(fixture: Fixture) async throws {
            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                Task { await gate.release() }
            }

            let read = gatedReadTask(fixture: fixture, id: 6)
            try await requireGateStarted(gate)
            try await assertReadReplyReturned(read, gate: gate, id: 6)

            let exportURL = fixture.rootURL.appendingPathComponent("prompt-export.txt")
            let exportFinished = PersistentAsyncSignal()
            let exportTask = Task {
                let response = try await fixture.socketClient.request(
                    id: 7,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.prompt,
                        "arguments": [
                            "op": "export",
                            "path": exportURL.path
                        ]
                    ]
                )
                await exportFinished.mark()
                return response
            }
            try await Task.sleep(for: .milliseconds(50))
            let exportReturnedBeforeDrain = await exportFinished.isMarked()
            XCTAssertFalse(exportReturnedBeforeDrain)

            await gate.release()
            try await Self.assertSuccessfulResponse(exportTask.value, id: 7)
            XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
            let exported = try String(contentsOf: exportURL, encoding: .utf8)
            XCTAssertTrue(exported.contains("PersistentAgentModeFixture.swift"), exported)
            let current = await fixture.retainedConnectionSnapshot()
            Self.assertStableAgentModeSnapshot(current, fixture: fixture)
        }

        func assertManageSelectionClearOrdering(fixture: Fixture) async throws {
            let initialClear = try await fixture.socketClient.request(
                id: 6,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": ["op": "clear"]
                ]
            )
            try Self.assertSuccessfulResponse(initialClear, id: 6)

            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                Task { await gate.release() }
            }

            let read = gatedReadTask(fixture: fixture, id: 7)
            try await requireGateStarted(gate)
            try await assertReadReplyReturned(read, gate: gate, id: 7)

            let clearFinished = PersistentAsyncSignal()
            let clearTask = Task {
                let response = try await fixture.socketClient.request(
                    id: 8,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.manageSelection,
                        "arguments": ["op": "clear"]
                    ]
                )
                await clearFinished.mark()
                return response
            }
            try await Task.sleep(for: .milliseconds(50))
            let clearReturnedBeforeDrain = await clearFinished.isMarked()
            XCTAssertFalse(clearReturnedBeforeDrain)

            await gate.release()
            try await Self.assertSuccessfulResponse(clearTask.value, id: 8)

            fixture.window.workspaceManager.publishActiveComposeTabSnapshot(
                commitToMemory: true,
                touchModified: false
            )
            await Task.yield()

            let finalSelection = fixture.window.mcpServer.tabContextByConnectionID[Fixture.connectionID]?.selection
            XCTAssertEqual(finalSelection?.selectedPaths, [])
            XCTAssertEqual(finalSelection?.slices, [:])
            let storedSelection = fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            XCTAssertEqual(storedSelection?.selectedPaths, [])
            XCTAssertEqual(storedSelection?.slices, [:])
            let current = await fixture.retainedConnectionSnapshot()
            Self.assertStableAgentModeSnapshot(current, fixture: fixture)
        }

        func assertEndOfRunFinish(fixture: Fixture) async throws {
            let initialClear = try await fixture.socketClient.request(
                id: 6,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": ["op": "clear"]
                ]
            )
            try Self.assertSuccessfulResponse(initialClear, id: 6)

            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                Task { await gate.release() }
            }

            let read = gatedReadTask(fixture: fixture, id: 7)
            try await requireGateStarted(gate)
            try await assertReadReplyReturned(read, gate: gate, id: 7)

            let finishCompleted = PersistentAsyncSignal()
            let finishTask = Task { @MainActor in
                await fixture.window.mcpServer.commitAndClearTabContext(
                    connectionID: Fixture.connectionID,
                    expectedRunID: Fixture.runID
                )
                await finishCompleted.mark()
            }
            try await Task.sleep(for: .milliseconds(50))
            let finishedBeforeRelease = await finishCompleted.isMarked()
            XCTAssertFalse(finishedBeforeRelease)

            await gate.release()
            await finishTask.value
            let storedSelection = fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            XCTAssertEqual(storedSelection?.selectedPaths, [fixture.fileURL.path])
            XCTAssertNil(fixture.window.mcpServer.tabContextByConnectionID[Fixture.connectionID])
        }

        func assertSearchWorkspaceContextDrain(fixture: Fixture) async throws {
            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                Task { await gate.release() }
            }

            let searchTask = Task {
                try await fixture.socketClient.request(
                    id: 6,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.search,
                        "arguments": [
                            "pattern": "persistentAgentModeCheckpoint",
                            "mode": "content",
                            "regex": false,
                            "context_lines": 2
                        ]
                    ]
                )
            }
            try await requireGateStarted(gate)
            let searchFinished = PersistentAsyncSignal()
            let searchObserver = Task {
                let result = await searchTask.result
                await searchFinished.mark()
                return result
            }
            let replyReturnedBeforeCanonicalApply = await waitUntilMarked(searchFinished, timeout: .seconds(2))
            XCTAssertTrue(replyReturnedBeforeCanonicalApply)
            if !replyReturnedBeforeCanonicalApply {
                await gate.release()
            }
            let response = try await searchObserver.value.get()
            try Self.assertSuccessfulResponse(response, id: 6)
            XCTAssertTrue(response.contains("PersistentAgentModeFixture.swift"), response)

            let contextFinished = PersistentAsyncSignal()
            let contextTask = Task {
                let response = try await fixture.socketClient.request(
                    id: 7,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.workspaceContext,
                        "arguments": [:]
                    ]
                )
                await contextFinished.mark()
                return response
            }
            try await Task.sleep(for: .milliseconds(50))
            let contextReturnedBeforeDrain = await contextFinished.isMarked()
            XCTAssertFalse(contextReturnedBeforeDrain)

            await gate.release()
            let contextResponse = try await contextTask.value
            try Self.assertSuccessfulResponse(contextResponse, id: 7)
            XCTAssertTrue(contextResponse.contains("PersistentAgentModeFixture.swift"), contextResponse)
        }

        func assertTabCloseDuringAutoSelectionPersistence(fixture: Fixture) async throws {
            try await clearSelection(fixture: fixture, id: 6)
            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionPersistenceGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionPersistenceGateForTesting(nil)
                Task { await gate.release() }
            }

            let read = gatedReadTask(fixture: fixture, id: 7)
            try await requireGateStarted(gate)
            try await assertReadReplyReturned(read, gate: gate, id: 7)

            let manager = fixture.window.workspaceManager
            let workspaceIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspaceID })
            let originalWorkspace = manager.workspaces[workspaceIndex]
            var workspaceWithoutTab = originalWorkspace
            workspaceWithoutTab.composeTabs.removeAll { $0.id == Fixture.tabID }
            if workspaceWithoutTab.activeComposeTabID == Fixture.tabID {
                workspaceWithoutTab.activeComposeTabID = workspaceWithoutTab.composeTabs.first?.id
            }
            manager.workspaces[workspaceIndex] = workspaceWithoutTab

            await gate.release()
            let settled = await waitForCanonicalWorkerToSettle(fixture: fixture)
            XCTAssertTrue(settled)
            let boundSelection = fixture.window.mcpServer.tabContextByConnectionID[Fixture.connectionID]?.selection
            XCTAssertEqual(boundSelection?.selectedPaths, [])
            XCTAssertEqual(boundSelection?.slices, [:])

            manager.workspaces[workspaceIndex] = originalWorkspace
        }

        func assertWorkspaceReorderDuringAutoSelectionPersistence(fixture: Fixture) async throws {
            try await clearSelection(fixture: fixture, id: 6)
            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionPersistenceGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionPersistenceGateForTesting(nil)
                Task { await gate.release() }
            }

            let read = gatedReadTask(fixture: fixture, id: 7)
            try await requireGateStarted(gate)
            try await assertReadReplyReturned(read, gate: gate, id: 7)

            let manager = fixture.window.workspaceManager
            let originalIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspaceID })
            var decoy = WorkspaceModel(
                name: "Read Auto-Selection Reorder Decoy",
                repoPaths: []
            )
            decoy.composeTabs = []
            let decoyID = decoy.id
            manager.workspaces.insert(decoy, at: originalIndex)
            defer { manager.workspaces.removeAll { $0.id == decoyID } }

            await gate.release()
            let settled = await waitForCanonicalWorkerToSettle(fixture: fixture)
            XCTAssertTrue(settled)
            let storedSelection = manager.workspaces
                .first(where: { $0.id == fixture.workspaceID })?
                .composeTabs.first(where: { $0.id == Fixture.tabID })?
                .selection
            XCTAssertEqual(storedSelection?.selectedPaths, [fixture.fileURL.path])
            XCTAssertEqual(storedSelection?.slices, [:])
        }

        func assertRebindDuringAutoSelectionPersistence(fixture: Fixture) async throws {
            try await clearSelection(fixture: fixture, id: 6)
            let manager = fixture.window.workspaceManager
            let workspaceIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspaceID })
            let replacementTabID = UUID()
            manager.workspaces[workspaceIndex].composeTabs.append(
                ComposeTabState(id: replacementTabID, name: "Replacement Auto-Selection Owner")
            )

            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionPersistenceGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionPersistenceGateForTesting(nil)
                Task { await gate.release() }
            }

            let read = gatedReadTask(fixture: fixture, id: 7)
            try await requireGateStarted(gate)
            try await assertReadReplyReturned(read, gate: gate, id: 7)

            try fixture.window.mcpServer.bindTabForConnection(
                connectionID: Fixture.connectionID,
                clientName: AgentProviderKind.codexMCPClientID,
                tabID: replacementTabID,
                workspaceID: fixture.workspaceID,
                windowID: fixture.windowID,
                runID: Fixture.runID,
                explicitlyBound: false
            )
            await gate.release()
            let settled = await waitForCanonicalWorkerToSettle(fixture: fixture)
            XCTAssertTrue(settled)

            let replacementBinding = fixture.window.mcpServer.tabContextByConnectionID[Fixture.connectionID]
            XCTAssertEqual(replacementBinding?.tabID, replacementTabID)
            XCTAssertEqual(replacementBinding?.selection.selectedPaths, [])
            XCTAssertEqual(replacementBinding?.selection.slices, [:])
            let originalSelection = manager.composeTab(with: Fixture.tabID)?.selection
            XCTAssertEqual(originalSelection?.selectedPaths, [])
            XCTAssertEqual(originalSelection?.slices, [:])
        }

        func clearSelection(fixture: Fixture, id: Int) async throws {
            let response = try await fixture.socketClient.request(
                id: id,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": ["op": "clear"]
                ]
            )
            try Self.assertSuccessfulResponse(response, id: id)
        }

        func waitForCanonicalWorkerToSettle(fixture: Fixture) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                if fixture.window.mcpServer.readFileAutoSelectionDiagnosticsSnapshot().canonicalWorkerCount == 0 {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return fixture.window.mcpServer.readFileAutoSelectionDiagnosticsSnapshot().canonicalWorkerCount == 0
        }

        func gatedReadTask(fixture: Fixture, id: Int) -> Task<String, Error> {
            Task {
                try await fixture.socketClient.request(
                    id: id,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.readFile,
                        "arguments": ["path": fixture.fileURL.path]
                    ]
                )
            }
        }

        func assertReadReplyReturned(_ task: Task<String, Error>, gate: PersistentAsyncGate, id: Int) async throws {
            let finished = PersistentAsyncSignal()
            let observer = Task {
                let result = await task.result
                await finished.mark()
                return result
            }
            let replyReturnedBeforeCanonicalApply = await waitUntilMarked(finished, timeout: .seconds(2))
            XCTAssertTrue(replyReturnedBeforeCanonicalApply)
            if !replyReturnedBeforeCanonicalApply {
                await gate.release()
            }
            let response = try await observer.value.get()
            let formattedRead = try Self.readFileText(from: response, id: id)
            XCTAssertTrue(formattedRead.contains(Fixture.sentinelContent), formattedRead)
        }

        func requireGateStarted(_ gate: PersistentAsyncGate) async throws {
            guard await gate.waitUntilStarted() else {
                XCTFail("Timed out waiting for the persistent async gate to start")
                throw PersistentAsyncGateTimeoutError()
            }
        }

        func waitUntilMarked(_ signal: PersistentAsyncSignal, timeout: Duration) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if await signal.isMarked() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await signal.isMarked()
        }

        static func assertStableAgentModeSnapshot(_ snapshot: RetainedConnectionSnapshot, fixture: Fixture) {
            XCTAssertEqual(snapshot.connectionID, Fixture.connectionID)
            XCTAssertEqual(snapshot.capabilityToken, Fixture.sessionToken)
            XCTAssertEqual(snapshot.managerState, .ready)
            XCTAssertTrue(snapshot.managerViable)
            XCTAssertEqual(snapshot.peerPID, Int(getpid()))
            XCTAssertEqual(snapshot.runPurpose, .agentModeRun)
            XCTAssertEqual(snapshot.runID, Fixture.runID)
            XCTAssertEqual(snapshot.connectionPolicy.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
            XCTAssertEqual(
                snapshot.connectionPolicy.additionalTools,
                AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec)
            )
            XCTAssertEqual(snapshot.connectionPolicy.purpose, .agentModeRun)
            XCTAssertEqual(snapshot.connectionPolicy.windowID, fixture.windowID)
            XCTAssertEqual(snapshot.runPolicy?.windowID, fixture.windowID)
            XCTAssertEqual(snapshot.runPolicy?.workspaceID, fixture.workspaceID)
            XCTAssertEqual(snapshot.runPolicy?.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
            XCTAssertEqual(
                snapshot.runPolicy?.additionalTools,
                AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec)
            )
            XCTAssertEqual(snapshot.runPolicy?.purpose, .agentModeRun)
            XCTAssertEqual(snapshot.pendingPolicyCount, 0)
            XCTAssertEqual(snapshot.binding.bindingKind, .tabContext)
            XCTAssertEqual(snapshot.binding.windowID, fixture.windowID)
            XCTAssertEqual(snapshot.binding.tabID, Fixture.tabID)
            XCTAssertEqual(snapshot.binding.workspaceID, fixture.workspaceID)
            XCTAssertEqual(snapshot.binding.repoPaths, [fixture.rootURL.path])
            XCTAssertEqual(snapshot.binding.runID, Fixture.runID)
            XCTAssertEqual(snapshot.mappedConnectionID, Fixture.connectionID)
            XCTAssertEqual(snapshot.handshake.initializeCount, 1)
            XCTAssertEqual(snapshot.handshake.clientName, AgentProviderKind.codexMCPClientID)
            XCTAssertEqual(snapshot.handshake.admissionStatus, "ready")
            XCTAssertEqual(snapshot.handshake.policyApplicationCount, 1)
            XCTAssertEqual(snapshot.handshake.appliedPolicy?.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
            XCTAssertEqual(
                snapshot.handshake.appliedPolicy?.additionalTools,
                AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec)
            )
            XCTAssertEqual(snapshot.handshake.appliedPolicy?.purpose, .agentModeRun)
            XCTAssertEqual(snapshot.handshake.appliedPolicy?.windowID, fixture.windowID)
            XCTAssertEqual(snapshot.limiter?.limit, 1)
            XCTAssertEqual(snapshot.limiter?.permits, 1)
            XCTAssertEqual(snapshot.limiter?.activePermitCount, 0)
            XCTAssertEqual(snapshot.limiter?.waiterCount, 0)
            XCTAssertEqual(snapshot.limiter?.inFlight, 0)
            XCTAssertEqual(snapshot.limiter?.cancelledWaiterCount, 0)
            XCTAssertEqual(snapshot.limiter?.isClosed, false)
            XCTAssertEqual(snapshot.limiter?.isIdle, true)
        }

        static func assertSuccessfulResponse(_ rawJSON: String, id: Int) throws {
            let object = try responseObject(from: rawJSON, id: id)
            XCTAssertNil(object["error"])
        }

        static func toolNames(from rawJSON: String) throws -> [String] {
            let object = try responseObject(from: rawJSON, id: 2)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            return tools.compactMap { $0["name"] as? String }
        }

        static func readFileText(from rawJSON: String, id: Int) throws -> String {
            let object = try responseObject(from: rawJSON, id: id)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            XCTAssertNotEqual(result["isError"] as? Bool, true)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return content.compactMap { $0["text"] as? String }.joined()
        }

        static func totalTokens(fromSelectionText text: String) throws -> Int {
            let regex = try NSRegularExpression(pattern: #"\"total_tokens\"\s*:\s*(\d+)"#)
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            let match = try XCTUnwrap(regex.firstMatch(in: text, range: range))
            let valueRange = try XCTUnwrap(Range(match.range(at: 1), in: text))
            return try XCTUnwrap(Int(text[valueRange]))
        }

        static func responseObject(from rawJSON: String, id: Int) throws -> [String: Any] {
            let data = try XCTUnwrap(rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((object["id"] as? NSNumber)?.intValue, id)
            XCTAssertNil(object["error"])
            return object
        }
    }

    @MainActor
    private final class HandoverConnection {
        let connectionID: UUID
        let socketClient: SocketPairJSONRPCClient
        let manager: BootstrapSocketConnectionManager
        let networkManager: ServerNetworkManager
        unowned let window: WindowState
        private var cleanedUp = false

        init(
            connectionID: UUID,
            socketClient: SocketPairJSONRPCClient,
            manager: BootstrapSocketConnectionManager,
            networkManager: ServerNetworkManager,
            window: WindowState
        ) {
            self.connectionID = connectionID
            self.socketClient = socketClient
            self.manager = manager
            self.networkManager = networkManager
            self.window = window
        }

        func cleanup() async {
            guard !cleanedUp else { return }
            cleanedUp = true
            socketClient.close()
            await manager.stop()
            await networkManager.debugRemoveConnection(connectionID)
            window.mcpServer.removeTabContext(
                forConnectionID: connectionID,
                clientName: AgentProviderKind.codexMCPClientID,
                windowID: window.windowID,
                runID: Fixture.runID
            )
        }
    }

    @MainActor
    private final class IndependentConnection {
        let connectionID: UUID
        let socketClient: SocketPairJSONRPCClient
        let manager: BootstrapSocketConnectionManager
        let networkManager: ServerNetworkManager
        private var cleanedUp = false

        init(
            connectionID: UUID,
            socketClient: SocketPairJSONRPCClient,
            manager: BootstrapSocketConnectionManager,
            networkManager: ServerNetworkManager
        ) {
            self.connectionID = connectionID
            self.socketClient = socketClient
            self.manager = manager
            self.networkManager = networkManager
        }

        func cleanup() async {
            guard !cleanedUp else { return }
            cleanedUp = true
            socketClient.close()
            await manager.stop()
            await networkManager.debugRemoveConnection(connectionID)
        }
    }

    @MainActor
    private final class Fixture {
        static let runID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        static let tabID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        static let activeTabID = UUID(uuidString: "22222222-2222-4222-8222-333333333333")!
        static let gateID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        static let connectionID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        static let handoverConnectionID = UUID(uuidString: "44444444-4444-4444-8444-555555555555")!
        static let independentConnectionID = UUID(uuidString: "44444444-4444-4444-8444-666666666666")!
        static let peerUnrelatedWorkspaceID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        static let parentRunID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        static let parentConnectionID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        static let agentSessionID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        static let sessionToken = "persistent-agent-mode-read-file-checkpoint-session"
        static let sentinelContent = """
        let persistentAgentModeCheckpoint = "retained-session-read"
        let persistentAgentModeLineTwo = 2
        let persistentAgentModeLineThree = 3
        let persistentAgentModeLineFour = 4
        """
        static let liveRelativePath = "Tests/RepoPromptTests/MCP/GeneratedOracleExportFileWriterTests.swift"
        static let worktreeOnlyRelativePath = "Tests/RepoPromptTests/MCP/WorktreeOnlySelection.swift"
        static func liveContents() throws -> (logical: String, worktree: String) {
            let targetURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("GeneratedOracleExportFileWriterTests.swift")
            let logical = try String(contentsOf: targetURL, encoding: .utf8)
            var lines = logical.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
            guard lines.count >= 175 else { throw ClientFixtureError.liveFixtureTooShort(lines.count) }
            return (logical, lines.prefix(175).joined(separator: "\n") + "\n")
        }

        let networkManager = ServerNetworkManager.shared
        let rootURL: URL
        let fileURL: URL
        let liveFileURL: URL
        let rootID: UUID
        let window: WindowState
        let routingGuardWindow: WindowState
        let windowID: Int
        let workspaceID: UUID
        let catalogService: MCPWindowToolCatalogService
        let socketClient: SocketPairJSONRPCClient
        let connectionManager: BootstrapSocketConnectionManager
        let handshakeRecorder = HandshakeRecorder()
        let spec: MCPBootstrapLeaseSpec
        let lease: MCPBootstrapLease
        let agentOwned: Bool
        private var worktreeRootURL: URL?
        private var worktreeRootID: UUID?
        private var auxiliaryRootURL: URL?
        private var auxiliaryRootID: UUID?
        private var peerRootID: UUID?
        private var peerTargetStateVersionBeforeSelection: Int?
        private var peerUnrelatedStateVersionBeforeSelection: Int?
        private var peerCatalogService: MCPWindowToolCatalogService?
        private var ownedRoutingService: WindowRoutingService?
        private var cleanedUp = false

        private init(
            rootURL: URL,
            fileURL: URL,
            liveFileURL: URL,
            rootID: UUID,
            window: WindowState,
            routingGuardWindow: WindowState,
            workspaceID: UUID,
            catalogService: MCPWindowToolCatalogService,
            socketClient: SocketPairJSONRPCClient,
            connectionManager: BootstrapSocketConnectionManager,
            spec: MCPBootstrapLeaseSpec,
            lease: MCPBootstrapLease,
            agentOwned: Bool
        ) {
            self.rootURL = rootURL
            self.fileURL = fileURL
            self.liveFileURL = liveFileURL
            self.rootID = rootID
            self.window = window
            self.routingGuardWindow = routingGuardWindow
            windowID = window.windowID
            self.workspaceID = workspaceID
            self.catalogService = catalogService
            self.socketClient = socketClient
            self.connectionManager = connectionManager
            self.spec = spec
            self.lease = lease
            self.agentOwned = agentOwned
        }

        static func make(agentOwned: Bool = false, inactiveAgentTab: Bool = false) async throws -> Fixture {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PersistentAgentModeMCPReadFileConnectionTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fileURL = rootURL.appendingPathComponent("Sources/PersistentAgentModeFixture.swift")
            let liveFileURL = rootURL.appendingPathComponent(liveRelativePath)
            let liveContents = try liveContents()
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: liveFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try sentinelContent.write(to: fileURL, atomically: true, encoding: .utf8)
                try liveContents.logical.write(to: liveFileURL, atomically: true, encoding: .utf8)
            } catch {
                try? FileManager.default.removeItem(at: rootURL)
                throw error
            }

            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            let routingGuardWindow = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            // Keep dispatch in ordinary multi-window routing mode so catalog services retained by
            // earlier tests are filtered by window ID instead of relying on singleton cleanliness.
            WindowStatesManager.shared.registerWindowState(routingGuardWindow)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

            var rootID: UUID?
            var catalogService: MCPWindowToolCatalogService?
            var socketClient: SocketPairJSONRPCClient?
            var connectionManager: BootstrapSocketConnectionManager?
            var lease: MCPBootstrapLease?

            do {
                let workspace = window.workspaceManager.createWorkspace(
                    name: "Persistent Agent Mode MCP Read",
                    repoPaths: [rootURL.path],
                    ephemeral: true
                )
                let workspaceIndex = try XCTUnwrap(
                    window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
                )
                var composeTabs = [
                    ComposeTabState(
                        id: tabID,
                        name: "Persistent Agent Mode MCP Read",
                        activeAgentSessionID: agentOwned ? agentSessionID : nil
                    )
                ]
                if inactiveAgentTab {
                    composeTabs.insert(
                        ComposeTabState(id: activeTabID, name: "Parent Active Tab"),
                        at: 0
                    )
                }
                window.workspaceManager.workspaces[workspaceIndex].composeTabs = composeTabs
                window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = inactiveAgentTab ? activeTabID : tabID
                let configuredWorkspace = window.workspaceManager.workspaces[workspaceIndex]
                await window.workspaceManager.switchWorkspace(
                    to: configuredWorkspace,
                    saveState: false,
                    reason: "persistentAgentModeMCPReadFileConnectionTest"
                )
                let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
                let rootRecord = try await window.workspaceFileContextStore.loadRoot(path: rootURL.path)
                rootID = rootRecord.id
                let exactHit = await WorkspaceReadableFileService(store: window.workspaceFileContextStore)
                    .resolveExactAbsoluteWorkspaceCatalogHit(fileURL.path, rootScope: .visibleWorkspace)
                guard exactHit?.standardizedFullPath == fileURL.path else {
                    throw ClientFixtureError.exactAbsoluteCatalogMiss
                }

                let resolvedCatalogService = window.mcpServer.windowMCPToolCatalogService
                catalogService = resolvedCatalogService
                ServiceRegistry.register(resolvedCatalogService)

                var socketFDs = [Int32](repeating: -1, count: 2)
                guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &socketFDs) == 0 else {
                    throw SocketPairJSONRPCClient.ClientError.posix(operation: "socketpair", code: errno)
                }
                var noSigPipe: Int32 = 1
                guard Darwin.setsockopt(
                    socketFDs[0],
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    &noSigPipe,
                    socklen_t(MemoryLayout.size(ofValue: noSigPipe))
                ) == 0 else {
                    let code = errno
                    Darwin.close(socketFDs[0])
                    Darwin.close(socketFDs[1])
                    throw SocketPairJSONRPCClient.ClientError.posix(operation: "setsockopt(SO_NOSIGPIPE)", code: code)
                }
                let resolvedSocketClient = SocketPairJSONRPCClient(fd: socketFDs[0])
                socketClient = resolvedSocketClient
                let resolvedConnectionManager = try BootstrapSocketConnectionManager(
                    connectionID: connectionID,
                    sessionToken: sessionToken,
                    clientPid: Int(getpid()),
                    clientName: AgentProviderKind.codexMCPClientID,
                    purpose: .agentModeRun,
                    codeMapsDisabled: false,
                    connectedFD: socketFDs[1],
                    parentManager: ServerNetworkManager.shared
                )
                connectionManager = resolvedConnectionManager
                await ServerNetworkManager.shared.debugRegisterConnectionForSocketFixture(
                    connectionID: connectionID,
                    connection: resolvedConnectionManager,
                    clientName: AgentProviderKind.codexMCPClientID,
                    sessionToken: sessionToken
                )
                if agentOwned {
                    // MCP capability tokens are helper-process identities. This synthetic
                    // fixture models the confirmed provider behavior of retaining the parent's
                    // helper while opening a child session; it does not claim agent_run copies
                    // tokens or replace separate live rpce-cli-debug validation.
                    await ServerNetworkManager.shared.installClientConnectionPolicy(
                        for: AgentProviderKind.codexMCPClientID,
                        windowID: window.windowID,
                        restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                        tabID: nil,
                        runID: parentRunID,
                        additionalTools: AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec),
                        purpose: .agentModeRun,
                        requiresExpectedAgentPID: true
                    )
                    await ServerNetworkManager.shared.registerExpectedAgentPID(
                        getpid(),
                        for: AgentProviderKind.codexMCPClientID,
                        runID: parentRunID
                    )
                    let parentApplication = await ServerNetworkManager.shared.debugApplyPendingPolicy(
                        clientName: AgentProviderKind.codexMCPClientID,
                        connectionID: parentConnectionID,
                        clientPid: Int(getpid()),
                        bootstrapClientName: AgentProviderKind.codexMCPClientID,
                        sessionKey: sessionToken,
                        requireRunRouting: false
                    )
                    guard parentApplication.outcome == "applied", parentApplication.runID == parentRunID else {
                        throw ClientFixtureError.parentAffinitySeedFailed(parentApplication.outcome)
                    }
                    await ServerNetworkManager.shared.clearExpectedAgentPID(
                        getpid(),
                        for: AgentProviderKind.codexMCPClientID,
                        runID: parentRunID
                    )
                }

                let spec = MCPBootstrapLeaseSpec.agentMode(
                    tabID: tabID,
                    runID: runID,
                    gateID: gateID,
                    windowID: window.windowID,
                    agent: .codexExec,
                    taskLabelKind: agentOwned ? .pair : nil
                )
                let resolvedLease = MCPBootstrapLease(spec: spec)
                lease = resolvedLease
                guard await resolvedLease.acquire() else {
                    throw ClientFixtureError.leaseAcquisitionFailed
                }
                await ServerNetworkManager.shared.registerExpectedAgentPID(
                    getpid(),
                    for: AgentProviderKind.codexMCPClientID,
                    runID: runID
                )

                return Fixture(
                    rootURL: rootURL,
                    fileURL: fileURL,
                    liveFileURL: liveFileURL,
                    rootID: rootRecord.id,
                    window: window,
                    routingGuardWindow: routingGuardWindow,
                    workspaceID: activeWorkspace.id,
                    catalogService: resolvedCatalogService,
                    socketClient: resolvedSocketClient,
                    connectionManager: resolvedConnectionManager,
                    spec: spec,
                    lease: resolvedLease,
                    agentOwned: agentOwned
                )
            } catch {
                await connectionManager?.stop()
                socketClient?.close()
                await ServerNetworkManager.shared.removeConnection(connectionID)
                await ServerNetworkManager.shared.clearExpectedAgentPID(
                    getpid(),
                    for: AgentProviderKind.codexMCPClientID,
                    runID: runID
                )
                await ServerNetworkManager.shared.clearClientConnectionPolicy(
                    for: AgentProviderKind.codexMCPClientID,
                    windowID: window.windowID,
                    runID: runID
                )
                await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                if agentOwned {
                    await ServerNetworkManager.shared.removeConnection(parentConnectionID)
                    await ServerNetworkManager.shared.clearClientConnectionPolicy(
                        for: AgentProviderKind.codexMCPClientID,
                        windowID: window.windowID,
                        runID: parentRunID
                    )
                    await ServerNetworkManager.shared.cleanupRunRoutingState(
                        for: parentRunID,
                        windowID: window.windowID
                    )
                }
                await lease?.cancelAndCleanup()
                window.mcpServer.removeTabContext(
                    forConnectionID: connectionID,
                    clientName: AgentProviderKind.codexMCPClientID,
                    windowID: window.windowID,
                    runID: runID
                )
                if let catalogService {
                    ServiceRegistry.unregister(catalogService)
                }
                if let rootID {
                    await window.workspaceFileContextStore.unloadRoot(id: rootID)
                }
                WindowStatesManager.shared.unregisterWindowState(routingGuardWindow)
                WindowStatesManager.shared.unregisterWindowState(window)
                try? FileManager.default.removeItem(at: rootURL)
                throw error
            }
        }

        func installWorktreeBinding() async throws {
            let auxiliaryRootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PersistentAgentModeMCPReadFileConnectionTests-Auxiliary", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            self.auxiliaryRootURL = auxiliaryRootURL
            try FileManager.default.createDirectory(at: auxiliaryRootURL, withIntermediateDirectories: true)
            try "auxiliary".write(
                to: auxiliaryRootURL.appendingPathComponent("README.md"),
                atomically: true,
                encoding: .utf8
            )
            let auxiliaryRoot = try await window.workspaceFileContextStore.loadRoot(path: auxiliaryRootURL.path)
            auxiliaryRootID = auxiliaryRoot.id

            let worktreeRootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PersistentAgentModeMCPReadFileConnectionTests-Worktree", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            self.worktreeRootURL = worktreeRootURL
            let worktreeFileURL = worktreeRootURL.appendingPathComponent("Sources/PersistentAgentModeFixture.swift")
            let worktreeLiveFileURL = worktreeRootURL.appendingPathComponent(Self.liveRelativePath)
            let worktreeOnlyFileURL = worktreeRootURL.appendingPathComponent(Self.worktreeOnlyRelativePath)
            try FileManager.default.createDirectory(
                at: worktreeFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: worktreeLiveFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: worktreeOnlyFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let liveContents = try Self.liveContents()
            try Self.sentinelContent.write(to: worktreeFileURL, atomically: true, encoding: .utf8)
            try liveContents.worktree.write(to: worktreeLiveFileURL, atomically: true, encoding: .utf8)
            try "let worktreeOnlySelection = true\n".write(
                to: worktreeOnlyFileURL,
                atomically: true,
                encoding: .utf8
            )
            let worktreeRoot = try await window.workspaceFileContextStore.loadRoot(
                path: worktreeRootURL.path,
                kind: .sessionWorktree
            )
            worktreeRootID = worktreeRoot.id

            let binding = AgentSessionWorktreeBinding(
                id: "persistent-read-worktree-binding",
                repositoryID: "persistent-read-repository",
                repoKey: "persistent-read-repo-key",
                logicalRootPath: rootURL.path,
                logicalRootName: rootURL.lastPathComponent,
                worktreeID: "persistent-read-worktree",
                worktreeRootPath: worktreeRootURL.path,
                worktreeName: worktreeRootURL.lastPathComponent,
                branch: "test/full-read-selection",
                head: "54410152deac877f8a3422344da97da37eba47e7",
                source: "test"
            )
            window.mcpServer.registerAgentWorktreeBindingsProvider { sessionID, tabID in
                guard sessionID == Self.agentSessionID, tabID == Self.tabID else { return [] }
                return [binding]
            }
        }

        func installPeerWindowLookupSnapshot() async throws {
            var peerWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            peerWorkspace.activeComposeTabID = Self.tabID
            let unrelatedSelection = StoredSelection(selectedPaths: ["/tmp/unrelated-workspace.swift"])
            let unrelatedWorkspace = WorkspaceModel(
                id: Self.peerUnrelatedWorkspaceID,
                name: "Unrelated Duplicate Tab Workspace",
                repoPaths: [],
                ephemeralFlag: true,
                composeTabs: [
                    ComposeTabState(
                        id: Self.tabID,
                        name: "Unrelated Duplicate Tab",
                        selection: unrelatedSelection
                    )
                ],
                activeComposeTabID: Self.tabID
            )
            routingGuardWindow.workspaceManager.workspaces.append(unrelatedWorkspace)
            routingGuardWindow.workspaceManager.workspaces.append(peerWorkspace)
            await routingGuardWindow.workspaceManager.switchWorkspace(
                to: peerWorkspace,
                saveState: false,
                reason: "persistentAgentModeMCPPeerSelectionTest"
            )
            routingGuardWindow.promptManager.loadComposeTabsFromWorkspace(
                peerWorkspace,
                syncPromptText: true
            )
            let unrelatedIdentity = WorkspaceSelectionIdentity(
                workspaceID: Self.peerUnrelatedWorkspaceID,
                tabID: Self.tabID
            )
            var unrelatedTab = try XCTUnwrap(
                routingGuardWindow.workspaceManager.composeTab(for: unrelatedIdentity)
            )
            unrelatedTab.selection = unrelatedSelection
            XCTAssertTrue(
                routingGuardWindow.workspaceManager.updateComposeTabStoredOnly(
                    unrelatedTab,
                    inWorkspaceID: Self.peerUnrelatedWorkspaceID
                )
            )

            let root = try await routingGuardWindow.workspaceFileContextStore.loadRoot(path: rootURL.path)
            peerRootID = root.id
            peerTargetStateVersionBeforeSelection = routingGuardWindow.workspaceManager
                .debugStateVersionForWorkspace(workspaceID)
            peerUnrelatedStateVersionBeforeSelection = routingGuardWindow.workspaceManager
                .debugStateVersionForWorkspace(Self.peerUnrelatedWorkspaceID)

            let targetIdentity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: Self.tabID)
            XCTAssertNotNil(window.workspaceManager.composeTab(for: targetIdentity))
            XCTAssertNotNil(routingGuardWindow.workspaceManager.composeTab(for: targetIdentity))
            XCTAssertEqual(
                routingGuardWindow.workspaceManager.composeTab(for: unrelatedIdentity)?.selection,
                unrelatedSelection
            )
            XCTAssertEqual(routingGuardWindow.workspaceManager.activeWorkspace?.id, workspaceID)
            XCTAssertEqual(routingGuardWindow.workspaceManager.activeWorkspace?.activeComposeTabID, Self.tabID)
        }

        func makeIndependentPeerConnection() async throws -> IndependentConnection {
            let routingService = WindowRoutingService(windowStates: .shared, networkMgr: networkManager)
            ownedRoutingService = routingService
            for _ in 0 ..< 100 {
                let registered = ServiceRegistry.services.contains {
                    $0 as AnyObject === routingService as AnyObject
                }
                let names = await routingService.tools.map(\.name)
                if registered, names.contains(MCPGlobalToolName.bindContext) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            if peerCatalogService == nil {
                let service = routingGuardWindow.mcpServer.windowMCPToolCatalogService
                peerCatalogService = service
                ServiceRegistry.register(service)
            }
            var socketFDs = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &socketFDs) == 0 else {
                throw SocketPairJSONRPCClient.ClientError.posix(operation: "socketpair", code: errno)
            }
            var noSigPipe: Int32 = 1
            guard Darwin.setsockopt(
                socketFDs[0],
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout.size(ofValue: noSigPipe))
            ) == 0 else {
                let code = errno
                Darwin.close(socketFDs[0])
                Darwin.close(socketFDs[1])
                throw SocketPairJSONRPCClient.ClientError.posix(operation: "setsockopt(SO_NOSIGPIPE)", code: code)
            }

            let socketClient = SocketPairJSONRPCClient(fd: socketFDs[0])
            let manager: BootstrapSocketConnectionManager
            do {
                manager = try BootstrapSocketConnectionManager(
                    connectionID: Self.independentConnectionID,
                    sessionToken: Self.sessionToken + "-independent",
                    clientPid: Int(getpid()),
                    clientName: "RepoPrompt Independent Selection Test",
                    purpose: .unknown,
                    codeMapsDisabled: false,
                    connectedFD: socketFDs[1],
                    parentManager: networkManager
                )
            } catch {
                socketClient.close()
                Darwin.close(socketFDs[1])
                throw error
            }
            await networkManager.debugRegisterConnectionForSocketFixture(
                connectionID: Self.independentConnectionID,
                connection: manager,
                clientName: "RepoPrompt Independent Selection Test",
                sessionToken: Self.sessionToken + "-independent"
            )
            let startTask = Task {
                try await manager.start { _ in true }
            }
            do {
                let initialize = try await socketClient.request(
                    id: 1,
                    method: "initialize",
                    params: [
                        "protocolVersion": "2025-11-25",
                        "capabilities": [:],
                        "clientInfo": [
                            "name": "RepoPrompt Independent Selection Test",
                            "version": "post-completion-selection-lookup"
                        ]
                    ]
                )
                try PersistentAgentModeMCPReadFileConnectionTests.assertSuccessfulResponse(initialize, id: 1)
                try await startTask.value
                try socketClient.sendNotification(method: "notifications/initialized", params: [:])
                let tools = try await socketClient.request(id: 2, method: "tools/list", params: [:])
                let toolNames = try PersistentAgentModeMCPReadFileConnectionTests.toolNames(from: tools)
                XCTAssertTrue(toolNames.contains(MCPGlobalToolName.bindContext))
                let bind = try await socketClient.request(
                    id: 3,
                    method: "tools/call",
                    params: [
                        "name": MCPGlobalToolName.bindContext,
                        "arguments": [
                            "op": "bind",
                            "window_id": routingGuardWindow.windowID
                        ]
                    ]
                )
                try PersistentAgentModeMCPReadFileConnectionTests.assertSuccessfulResponse(bind, id: 3)
                return IndependentConnection(
                    connectionID: Self.independentConnectionID,
                    socketClient: socketClient,
                    manager: manager,
                    networkManager: networkManager
                )
            } catch {
                startTask.cancel()
                socketClient.close()
                await manager.stop()
                await networkManager.debugRemoveConnection(Self.independentConnectionID)
                _ = try? await startTask.value
                throw error
            }
        }

        var worktreeOnlyLogicalURL: URL {
            rootURL.appendingPathComponent(Self.worktreeOnlyRelativePath)
        }

        func peerCanonicalSelection() -> StoredSelection? {
            routingGuardWindow.workspaceManager.composeTab(
                for: WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: Self.tabID)
            )?.selection
        }

        func peerUnrelatedSelection() -> StoredSelection? {
            routingGuardWindow.workspaceManager.composeTab(
                for: WorkspaceSelectionIdentity(
                    workspaceID: Self.peerUnrelatedWorkspaceID,
                    tabID: Self.tabID
                )
            )?.selection
        }

        func assertPeerIsolationAndLifecycle(expectedSelection: StoredSelection) {
            XCTAssertEqual(peerCanonicalSelection(), expectedSelection)
            XCTAssertEqual(
                peerUnrelatedSelection(),
                StoredSelection(selectedPaths: ["/tmp/unrelated-workspace.swift"])
            )
            let peerUIPaths = Set(
                routingGuardWindow.workspaceManager.fileManager.snapshotSelection().selectedPaths
            )
            XCTAssertTrue(peerUIPaths.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: worktreeOnlyLogicalURL.path))
            XCTAssertNotNil(WindowStatesManager.shared.window(withID: routingGuardWindow.windowID))
            XCTAssertNotNil(
                routingGuardWindow.workspaceManager.composeTab(
                    for: WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: Self.tabID)
                )
            )
            if let peerTargetStateVersionBeforeSelection {
                XCTAssertGreaterThan(
                    routingGuardWindow.workspaceManager.debugStateVersionForWorkspace(workspaceID),
                    peerTargetStateVersionBeforeSelection
                )
            }
            if let peerUnrelatedStateVersionBeforeSelection {
                XCTAssertEqual(
                    routingGuardWindow.workspaceManager.debugStateVersionForWorkspace(Self.peerUnrelatedWorkspaceID),
                    peerUnrelatedStateVersionBeforeSelection
                )
            }
        }

        func canonicalSelectionRevision() -> UInt64 {
            window.workspaceManager.selectionRevisionForMCP(
                workspaceID: workspaceID,
                tabID: Self.tabID
            )
        }

        func makeHandoverConnection() async throws -> HandoverConnection {
            var socketFDs = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &socketFDs) == 0 else {
                throw SocketPairJSONRPCClient.ClientError.posix(operation: "socketpair", code: errno)
            }
            var noSigPipe: Int32 = 1
            guard Darwin.setsockopt(
                socketFDs[0],
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout.size(ofValue: noSigPipe))
            ) == 0 else {
                let code = errno
                Darwin.close(socketFDs[0])
                Darwin.close(socketFDs[1])
                throw SocketPairJSONRPCClient.ClientError.posix(operation: "setsockopt(SO_NOSIGPIPE)", code: code)
            }
            let socketClient = SocketPairJSONRPCClient(fd: socketFDs[0])
            let manager: BootstrapSocketConnectionManager
            do {
                manager = try BootstrapSocketConnectionManager(
                    connectionID: Self.handoverConnectionID,
                    sessionToken: Self.sessionToken + "-handover",
                    clientPid: Int(getpid()),
                    clientName: AgentProviderKind.codexMCPClientID,
                    purpose: .agentModeRun,
                    codeMapsDisabled: false,
                    connectedFD: socketFDs[1],
                    parentManager: networkManager
                )
            } catch {
                socketClient.close()
                Darwin.close(socketFDs[1])
                throw error
            }
            await networkManager.debugRegisterConnectionForSocketFixture(
                connectionID: Self.handoverConnectionID,
                connection: manager,
                clientName: AgentProviderKind.codexMCPClientID,
                sessionToken: Self.sessionToken + "-handover"
            )
            await networkManager.installClientConnectionPolicy(
                for: AgentProviderKind.codexMCPClientID,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "Persistent read-file real pending-policy handover",
                ttl: 10,
                tabID: Self.tabID,
                runID: Self.runID,
                additionalTools: AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec),
                purpose: .agentModeRun,
                taskLabelKind: .pair,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: true
            )
            let policyApplication = await networkManager.debugApplyPendingPolicy(
                clientName: AgentProviderKind.codexMCPClientID,
                connectionID: Self.handoverConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: AgentProviderKind.codexMCPClientID,
                sessionKey: Self.sessionToken + "-handover",
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            guard policyApplication.outcome == "applied", policyApplication.runID == Self.runID else {
                socketClient.close()
                await manager.stop()
                await networkManager.debugRemoveConnection(Self.handoverConnectionID)
                throw ClientFixtureError.handoverPolicyApplicationFailed(policyApplication.outcome)
            }
            let replacementScheduleCount = await networkManager.debugPendingPolicyReplacementScheduleCount(
                existing: Self.connectionID,
                replacement: Self.handoverConnectionID,
                runID: Self.runID
            )
            XCTAssertEqual(replacementScheduleCount, 1)
            let startTask = Task {
                try await manager.start { clientInfo in
                    clientInfo.name == AgentProviderKind.codexMCPClientID
                }
            }
            do {
                let initialize = try await socketClient.request(
                    id: 1,
                    method: "initialize",
                    params: [
                        "protocolVersion": "2025-11-25",
                        "capabilities": [:],
                        "clientInfo": [
                            "name": AgentProviderKind.codexMCPClientID,
                            "version": "persistent-agent-mode-read-file-handover"
                        ]
                    ]
                )
                try PersistentAgentModeMCPReadFileConnectionTests.assertSuccessfulResponse(initialize, id: 1)
                try await startTask.value
                try socketClient.sendNotification(method: "notifications/initialized", params: [:])
                let tools = try await socketClient.request(id: 2, method: "tools/list", params: [:])
                XCTAssertTrue(try PersistentAgentModeMCPReadFileConnectionTests.toolNames(from: tools).contains(MCPWindowToolName.manageSelection))
                return HandoverConnection(
                    connectionID: Self.handoverConnectionID,
                    socketClient: socketClient,
                    manager: manager,
                    networkManager: networkManager,
                    window: window
                )
            } catch {
                startTask.cancel()
                socketClient.close()
                await manager.stop()
                await networkManager.debugRemoveConnection(Self.handoverConnectionID)
                await networkManager.clearClientConnectionPolicy(
                    for: AgentProviderKind.codexMCPClientID,
                    windowID: windowID,
                    runID: Self.runID
                )
                _ = try? await startTask.value
                throw error
            }
        }

        func retainedConnectionSnapshot() async -> RetainedConnectionSnapshot {
            let connectionPolicy = await networkManager.debugConnectionPolicyState(for: Self.connectionID)
            let runPolicy = await networkManager.debugRunPolicyState(for: Self.runID)
            let pendingPolicyCount = await networkManager.debugPendingPolicySnapshot(
                for: AgentProviderKind.codexMCPClientID
            ).count
            let limiter = await networkManager.connectionLimiterSnapshotForTesting(
                connectionID: Self.connectionID
            )
            return await RetainedConnectionSnapshot(
                connectionID: Self.connectionID,
                capabilityToken: connectionManager.capabilityToken,
                managerState: connectionManager.connectionState(),
                managerViable: connectionManager.isViableForRetention(),
                peerPID: connectionManager.peerPID(),
                runPurpose: networkManager.runPurpose(for: Self.connectionID),
                runID: networkManager.runIDForConnection(Self.connectionID),
                connectionPolicy: ConnectionPolicySnapshot(
                    restrictedTools: connectionPolicy.restrictedTools,
                    additionalTools: connectionPolicy.additionalTools,
                    purpose: connectionPolicy.purpose,
                    windowID: connectionPolicy.windowID
                ),
                runPolicy: runPolicy.map {
                    RunPolicySnapshot(
                        windowID: $0.windowID,
                        workspaceID: $0.workspaceID,
                        restrictedTools: $0.restrictedTools,
                        additionalTools: $0.additionalTools,
                        purpose: $0.purpose
                    )
                },
                pendingPolicyCount: pendingPolicyCount,
                binding: window.mcpServer.connectionBindingSnapshot(forConnection: Self.connectionID),
                mappedConnectionID: window.mcpServer.connectionID(forRunID: Self.runID),
                handshake: handshakeRecorder.snapshot(),
                limiter: limiter
            )
        }

        func cleanup() async {
            guard !cleanedUp else { return }
            cleanedUp = true

            await connectionManager.stop()
            socketClient.close()
            await networkManager.removeConnection(Self.connectionID)
            let limiterAfterRemoval = await networkManager.connectionLimiterSnapshotForTesting(
                connectionID: Self.connectionID
            )
            XCTAssertNil(limiterAfterRemoval)
            await networkManager.clearExpectedAgentPID(
                getpid(),
                for: AgentProviderKind.codexMCPClientID,
                runID: Self.runID
            )
            await networkManager.clearClientConnectionPolicy(
                for: AgentProviderKind.codexMCPClientID,
                windowID: windowID,
                runID: Self.runID
            )
            await networkManager.cleanupRunRoutingState(for: Self.runID, windowID: windowID)
            if agentOwned {
                await networkManager.removeConnection(Self.parentConnectionID)
                await networkManager.clearClientConnectionPolicy(
                    for: AgentProviderKind.codexMCPClientID,
                    windowID: windowID,
                    runID: Self.parentRunID
                )
                await networkManager.cleanupRunRoutingState(for: Self.parentRunID, windowID: windowID)
            }
            await lease.cancelAndCleanup()
            window.mcpServer.removeTabContext(
                forConnectionID: Self.connectionID,
                clientName: AgentProviderKind.codexMCPClientID,
                windowID: windowID,
                runID: Self.runID
            )
            ServiceRegistry.unregister(catalogService)
            if let peerCatalogService {
                ServiceRegistry.unregister(peerCatalogService)
            }
            if let ownedRoutingService {
                ServiceRegistry.unregister(ownedRoutingService)
            }
            await window.workspaceFileContextStore.unloadRoot(id: rootID)
            if let peerRootID {
                await routingGuardWindow.workspaceFileContextStore.unloadRoot(id: peerRootID)
            }
            if let worktreeRootID {
                await window.workspaceFileContextStore.unloadRoot(id: worktreeRootID)
            }
            if let auxiliaryRootID {
                await window.workspaceFileContextStore.unloadRoot(id: auxiliaryRootID)
            }
            WindowStatesManager.shared.unregisterWindowState(routingGuardWindow)
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
            if let worktreeRootURL {
                try? FileManager.default.removeItem(at: worktreeRootURL)
            }
            if let auxiliaryRootURL {
                try? FileManager.default.removeItem(at: auxiliaryRootURL)
            }
        }
    }

    private enum ClientFixtureError: Error {
        case exactAbsoluteCatalogMiss
        case leaseAcquisitionFailed
        case parentAffinitySeedFailed(String)
        case handoverPolicyApplicationFailed(String)
        case liveFixtureTooShort(Int)
    }

    private struct RetainedConnectionSnapshot: Equatable {
        let connectionID: UUID
        let capabilityToken: String?
        let managerState: ConnectionStateSnapshot
        let managerViable: Bool
        let peerPID: Int
        let runPurpose: MCPRunPurpose
        let runID: UUID?
        let connectionPolicy: ConnectionPolicySnapshot
        let runPolicy: RunPolicySnapshot?
        let pendingPolicyCount: Int
        let binding: MCPServerViewModel.ConnectionBindingSnapshot
        let mappedConnectionID: UUID?
        let handshake: HandshakeRecorder.Snapshot
        let limiter: AsyncLimiter.DebugSnapshot?
    }

    private struct ConnectionPolicySnapshot: Equatable {
        let restrictedTools: Set<String>
        let additionalTools: Set<String>
        let purpose: MCPRunPurpose
        let windowID: Int?
    }

    private struct RunPolicySnapshot: Equatable {
        let windowID: Int
        let workspaceID: UUID?
        let restrictedTools: Set<String>
        let additionalTools: Set<String>?
        let purpose: MCPRunPurpose
    }

    private actor HandshakeRecorder {
        struct AppliedPolicy: Equatable {
            let restrictedTools: Set<String>
            let additionalTools: Set<String>
            let purpose: MCPRunPurpose
            let windowID: Int?
        }

        struct Snapshot: Equatable {
            let initializeCount: Int
            let clientName: String?
            let admissionStatus: String?
            let policyApplicationCount: Int
            let appliedPolicy: AppliedPolicy?
        }

        private var initializeCount = 0
        private var clientName: String?
        private var admissionStatus: String?
        private var policyApplicationCount = 0
        private var appliedPolicy: AppliedPolicy?

        func recordInitialize(clientName: String) {
            initializeCount += 1
            self.clientName = clientName
        }

        func recordAdmission(_ status: String) {
            admissionStatus = status
        }

        func recordPolicyApplication(
            restrictedTools: Set<String>,
            additionalTools: Set<String>,
            purpose: MCPRunPurpose,
            windowID: Int?
        ) {
            policyApplicationCount += 1
            appliedPolicy = AppliedPolicy(
                restrictedTools: restrictedTools,
                additionalTools: additionalTools,
                purpose: purpose,
                windowID: windowID
            )
        }

        func snapshot() -> Snapshot {
            Snapshot(
                initializeCount: initializeCount,
                clientName: clientName,
                admissionStatus: admissionStatus,
                policyApplicationCount: policyApplicationCount,
                appliedPolicy: appliedPolicy
            )
        }
    }

    private struct PersistentAsyncGateTimeoutError: Error {}

    private actor PersistentAsyncGate {
        private var started = false
        private var released = false

        func markStartedAndWaitForRelease(timeout: Duration = .seconds(10)) async {
            started = true
            let deadline = ContinuousClock.now + timeout
            while !released, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func waitUntilStarted(timeout: Duration = .seconds(2)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while !started, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return started
        }

        func release() {
            released = true
        }
    }

    private actor PersistentAsyncSignal {
        private var marked = false

        func mark() {
            marked = true
        }

        func isMarked() -> Bool {
            marked
        }
    }

    private final class SocketPairJSONRPCClient: @unchecked Sendable {
        enum ClientError: Error {
            case closed
            case invalidResponse
            case posix(operation: String, code: Int32)
            case timedOut
        }

        private let queue = DispatchQueue(label: "PersistentAgentModeMCPReadFileConnectionTests.socket")
        private var fd: Int32
        private var buffer = Data()
        private var nonMatchingFrames: [String] = []

        init(fd: Int32) {
            self.fd = fd
        }

        deinit {
            close()
        }

        func close() {
            queue.sync {
                guard fd >= 0 else { return }
                Darwin.close(fd)
                fd = -1
            }
        }

        func sendNotification(method: String, params: [String: Any]) throws {
            try sendJSON([
                "jsonrpc": "2.0",
                "method": method,
                "params": params
            ])
        }

        func request(id: Int, method: String, params: [String: Any]) async throws -> String {
            try sendJSON([
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params
            ])
            return try await response(matching: id)
        }

        private func sendJSON(_ object: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            line.append(0x0A)
            try queue.sync {
                try writeAll(line)
            }
        }

        private func response(matching expectedID: Int) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        while true {
                            let line = try self.readLine()
                            let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                            guard let object else { throw ClientError.invalidResponse }
                            if let rawID = object["id"] {
                                guard let responseID = (rawID as? NSNumber)?.intValue else {
                                    throw ClientError.invalidResponse
                                }
                                guard responseID == expectedID else {
                                    throw ClientError.invalidResponse
                                }
                                guard let rawJSON = String(data: line, encoding: .utf8) else {
                                    throw ClientError.invalidResponse
                                }
                                continuation.resume(returning: rawJSON)
                                return
                            }
                            guard object["method"] as? String != nil,
                                  let rawJSON = String(data: line, encoding: .utf8)
                            else {
                                throw ClientError.invalidResponse
                            }
                            self.nonMatchingFrames.append(rawJSON)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private func writeAll(_ data: Data) throws {
            guard fd >= 0 else { throw ClientError.closed }
            var written = 0
            while written < data.count {
                let result = data.withUnsafeBytes { bytes in
                    Darwin.write(fd, bytes.baseAddress?.advanced(by: written), data.count - written)
                }
                if result > 0 {
                    written += result
                    continue
                }
                if result < 0, errno == EINTR { continue }
                throw ClientError.posix(operation: "write", code: errno)
            }
        }

        private func readLine() throws -> Data {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(buffer.startIndex ... newline)
                    return line
                }
                guard fd >= 0 else { throw ClientError.closed }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pollResult = Darwin.poll(&descriptor, 1, 10000)
                if pollResult == 0 { throw ClientError.timedOut }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw ClientError.posix(operation: "poll", code: errno)
                }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0,
                   descriptor.revents & Int16(POLLIN) == 0
                {
                    throw ClientError.closed
                }

                var bytes = [UInt8](repeating: 0, count: 4096)
                let readCount = bytes.withUnsafeMutableBytes { storage in
                    Darwin.read(fd, storage.baseAddress, storage.count)
                }
                if readCount > 0 {
                    buffer.append(contentsOf: bytes.prefix(readCount))
                    continue
                }
                if readCount == 0 { throw ClientError.closed }
                if errno == EINTR { continue }
                throw ClientError.posix(operation: "read", code: errno)
            }
        }
    }
#endif
