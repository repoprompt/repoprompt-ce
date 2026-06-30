import Darwin
import Foundation
import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class PersistentAgentModeMCPReadFileConnectionTests: XCTestCase {
    func testWorktreeReadCoverageCertificateHitsExactFullAndSliceRepeatsButNotExpansion() async throws {
        #if DEBUG
            try await withFixture(agentOwned: true) { fixture in
                try await fixture.installWorktreeBinding()
                try await runCheckpoint(fixture: fixture, scenario: .worktreeCoverageCertificateRepeats)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testWorktreeReadCoverageCertificateMintsOnlyAfterVerifiedPersistenceAndResponseStaysAsync() async throws {
        #if DEBUG
            try await withFixture(agentOwned: true) { fixture in
                try await fixture.installWorktreeBinding()
                try await runCheckpoint(fixture: fixture, scenario: .worktreeCoverageCertificatePersistenceBoundary)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testWorktreeReadCoverageCertificateFailsClosedAcrossStaleStateAndLifecycleReplacement() async throws {
        #if DEBUG
            try await withFixture(agentOwned: true) { fixture in
                try await fixture.installWorktreeBinding()
                try await runCheckpoint(fixture: fixture, scenario: .worktreeCoverageCertificateFailClosed)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testPairAgentOwnedConnectionWithDistinctRunTokenPersistsCanonicalSelection() async throws {
        #if DEBUG
            try await withFixture(agentOwned: true) { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .agentOwnedCanonicalSelection)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testPairAgentOwnedSequentialFullAndSlicedReadsUnionCanonicalSelection() async throws {
        #if DEBUG
            try await withFixture(agentOwned: true) { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .agentOwnedSequentialReadUnion)
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

    func testManageSelectionGetStopsAtCanonicalHandoverWhileMirrorBlocked() async throws {
        #if DEBUG
            try await withFixture(agentOwned: true) { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .manageSelectionGetCanonicalHandover)
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

    func testAgentOwnedHiddenWorktreeWatcherRebases6500LineReadSlicesBeforePostEditReads() async throws {
        #if DEBUG
            try await withFixture(agentOwned: true) { fixture in
                try await fixture.installWorktreeBinding()
                try await runCheckpoint(fixture: fixture, scenario: .hiddenWorktreeReadSliceRebase)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testAgentOwnedWorktreeContentSearchCarriesPhysicalCoverageAndPreservesFullSelections() async throws {
        #if DEBUG
            try await withFixture(agentOwned: true) { fixture in
                try await fixture.installWorktreeBinding()
                try await runCheckpoint(fixture: fixture, scenario: .worktreeSearchPhysicalCoverage)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testThreeRootSessionScopeReplacesCanonicalGitRootAndPreservesIndependentNonGitRoot() async throws {
        #if DEBUG
            try await withFixture(agentOwned: true, gitBacked: true) { fixture in
                try await fixture.installWorktreeBinding()
                try await runCheckpoint(fixture: fixture, scenario: .threeRootFileToolScope)
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
            case agentOwnedSequentialReadUnion
            case agentOwnedExplicitSetIndependentLookup
            case agentOwnedNoRangeNonEmptyWorktreeFile
            case manageSelectionGetCanonicalHandover
            case worktreeCoverageCertificateRepeats
            case worktreeCoverageCertificatePersistenceBoundary
            case worktreeCoverageCertificateFailClosed
            case worktreeSearchPhysicalCoverage
            case threeRootFileToolScope
            case hiddenWorktreeReadSliceRebase

            var requiresSerialReadPrelude: Bool {
                switch self {
                case .agentOwnedNoRangeNonEmptyWorktreeFile, .agentOwnedSequentialReadUnion,
                     .manageSelectionGetCanonicalHandover, .worktreeCoverageCertificateRepeats,
                     .worktreeCoverageCertificatePersistenceBoundary, .worktreeCoverageCertificateFailClosed,
                     .worktreeSearchPhysicalCoverage, .threeRootFileToolScope, .hiddenWorktreeReadSliceRebase:
                    false
                default:
                    true
                }
            }
        }

        func withFixture(
            agentOwned: Bool = false,
            inactiveAgentTab: Bool = false,
            gitBacked: Bool = false,
            _ operation: (Fixture) async throws -> Void
        ) async throws {
            let fixture = try await Fixture.make(
                agentOwned: agentOwned,
                inactiveAgentTab: inactiveAgentTab,
                gitBacked: gitBacked
            )
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
            case .agentOwnedSequentialReadUnion:
                try await assertAgentOwnedSequentialReadUnion(fixture: fixture)
            case .agentOwnedExplicitSetIndependentLookup:
                try await assertAgentOwnedExplicitSetIndependentLookup(fixture: fixture)
            case .agentOwnedNoRangeNonEmptyWorktreeFile:
                try await assertAgentOwnedNoRangeNonEmptyWorktreeFile(fixture: fixture)
            case .manageSelectionGetCanonicalHandover:
                try await assertManageSelectionGetCanonicalHandover(fixture: fixture)
            case .worktreeCoverageCertificateRepeats:
                try await assertWorktreeCoverageCertificateRepeats(fixture: fixture)
            case .worktreeCoverageCertificatePersistenceBoundary:
                try await assertWorktreeCoverageCertificatePersistenceBoundary(fixture: fixture)
            case .worktreeCoverageCertificateFailClosed:
                try await assertWorktreeCoverageCertificateFailClosed(fixture: fixture)
            case .worktreeSearchPhysicalCoverage:
                try await assertWorktreeSearchPhysicalCoverage(fixture: fixture)
            case .threeRootFileToolScope:
                try await assertThreeRootFileToolScope(fixture: fixture)
            case .hiddenWorktreeReadSliceRebase:
                try await assertHiddenWorktreeReadSliceRebase(fixture: fixture)
            }
        }

        func assertHiddenWorktreeReadSliceRebase(fixture: Fixture) async throws {
            try await clearSelection(fixture: fixture, id: 3)
            let unrelatedLogicalPath = fixture.rootURL
                .appendingPathComponent(Fixture.worktreeOnlyRelativePath)
                .path
            let targetLogicalPath = fixture.rootURL
                .appendingPathComponent(Fixture.largeWorktreeRelativePath)
                .path
            let fullSet = try await fixture.socketClient.request(
                id: 4,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": [
                        "op": "set",
                        "paths": [unrelatedLogicalPath],
                        "mode": "full",
                        "strict": true
                    ]
                ]
            )
            try Self.assertSuccessfulResponse(fullSet, id: 4)

            _ = try await readFile(fixture: fixture, id: 5, path: targetLogicalPath, startLine: 100, limit: 10)
            _ = try await readFile(fixture: fixture, id: 6, path: targetLogicalPath, startLine: 3200, limit: 10)
            _ = try await readFile(fixture: fixture, id: 7, path: targetLogicalPath, startLine: 6400, limit: 10)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let originalRanges = [
                LineRange(start: 100, end: 109),
                LineRange(start: 3200, end: 3209),
                LineRange(start: 6400, end: 6409)
            ]
            var selection = try XCTUnwrap(
                fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            )
            XCTAssertEqual(Set(selection.selectedPaths), Set([unrelatedLogicalPath, targetLogicalPath]))
            XCTAssertNil(selection.slices[unrelatedLogicalPath])
            XCTAssertEqual(selection.slices[targetLogicalPath], originalRanges)

            var editedLines = (1 ... 6500).map { String(format: "line-%05d", $0) }
            editedLines.insert(contentsOf: (1 ... 40).map { "begin-insert-\($0)" }, at: 0)
            editedLines.insert(contentsOf: (1 ... 25).map { "middle-insert-\($0)" }, at: 3039)
            editedLines.removeSubrange(5064 ..< 5084)
            let physicalURL = try fixture.worktreeLargeFileURL
            let replacementURL = physicalURL.deletingLastPathComponent()
                .appendingPathComponent(".SessionWorktree6500.swift.atomic-\(UUID().uuidString)")
            try (editedLines.joined(separator: "\n") + "\n").write(
                to: replacementURL,
                atomically: false,
                encoding: .utf8
            )
            _ = try FileManager.default.replaceItemAt(physicalURL, withItemAt: replacementURL)
            let accepted = try await fixture.window.workspaceFileContextStore.acceptWatcherPayloadForTesting(
                rootID: fixture.installedWorktreeRootID,
                events: [(
                    absolutePath: physicalURL.path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemRenamed
                            | kFSEventStreamEventFlagItemCreated
                            | kFSEventStreamEventFlagItemIsFile
                    ),
                    eventId: 8_900_000_000_000_000_001
                )]
            )
            XCTAssertNotNil(accepted)
            _ = await fixture.window.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                userPath: physicalURL.path,
                fallbackScope: .allLoaded
            )
            let fence = await fixture.window.workspaceFilesViewModel.waitForPendingSliceRebasesAndCaptureFence(
                affectingCandidatePaths: [physicalURL.path]
            )
            XCTAssertTrue(fixture.window.workspaceFilesViewModel.isSliceRebaseFenceCurrent(fence))

            let expectedRanges = [
                LineRange(start: 140, end: 149),
                LineRange(start: 3265, end: 3274),
                LineRange(start: 6445, end: 6454)
            ]
            selection = try XCTUnwrap(
                fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            )
            XCTAssertEqual(Set(selection.selectedPaths), Set([unrelatedLogicalPath, targetLogicalPath]))
            XCTAssertNil(selection.slices[unrelatedLogicalPath])
            XCTAssertEqual(selection.slices[targetLogicalPath], expectedRanges)

            // `manage_selection get` flushes pending active-UI state before replying. Hidden
            // worktree-only paths cannot materialize in the visible file tree, so the MCP-owned
            // canonical selection fence must advance with the watcher-driven rebase rather than
            // accepting the empty visible projection as a newer selection.
            fixture.window.selectionCoordinator.flushPendingUISelectionToActiveTab()
            selection = try XCTUnwrap(
                fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            )
            XCTAssertEqual(Set(selection.selectedPaths), Set([unrelatedLogicalPath, targetLogicalPath]))
            XCTAssertNil(selection.slices[unrelatedLogicalPath])
            XCTAssertEqual(selection.slices[targetLogicalPath], expectedRanges)
            XCTAssertNil(fixture.window.workspaceFilesViewModel.findFileByFullPath(physicalURL.path))
            let physicalRootPath = try fixture.worktreeRootPath
            XCTAssertFalse(fixture.window.workspaceFilesViewModel.rootFolders.contains {
                $0.standardizedFullPath == StandardizedPath.absolute(physicalRootPath)
            })

            // Pause a successor after it computes from the old partition, then remove the
            // target selection and partition entry. The deferred commit must not resurrect it.
            let staleCommitGate = PersistentAsyncGate()
            fixture.window.workspaceFilesViewModel.setHiddenSessionSliceRebaseWillCommitHandlerForTesting { path in
                guard path == physicalURL.path else { return }
                await staleCommitGate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.workspaceFilesViewModel.setHiddenSessionSliceRebaseWillCommitHandlerForTesting(nil)
                Task { await staleCommitGate.release() }
            }
            let staleReplacementURL = physicalURL.deletingLastPathComponent()
                .appendingPathComponent(".SessionWorktree6500.swift.stale-\(UUID().uuidString)")
            let staleReplacementText = try String(contentsOf: physicalURL, encoding: .utf8)
                + "tail-stale-race\n"
            try staleReplacementText.write(to: staleReplacementURL, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(physicalURL, withItemAt: staleReplacementURL)
            let staleAccepted = try await fixture.window.workspaceFileContextStore.acceptWatcherPayloadForTesting(
                rootID: fixture.installedWorktreeRootID,
                events: [(
                    absolutePath: physicalURL.path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemRenamed
                            | kFSEventStreamEventFlagItemCreated
                            | kFSEventStreamEventFlagItemIsFile
                    ),
                    eventId: 8_900_000_000_000_000_002
                )]
            )
            XCTAssertNotNil(staleAccepted)
            _ = await fixture.window.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                userPath: physicalURL.path,
                fallbackScope: .allLoaded
            )
            try await requireGateStarted(staleCommitGate)

            let identity = WorkspaceSelectionIdentity(
                workspaceID: fixture.workspaceID,
                tabID: Fixture.tabID
            )
            let currentSelection = try XCTUnwrap(
                fixture.window.workspaceManager.composeTab(for: identity)?.selection
            )
            let removedTargetSelection = StoredSelection(
                selectedPaths: [unrelatedLogicalPath],
                codemapAutoEnabled: currentSelection.codemapAutoEnabled
            )
            let persisted = await fixture.window.selectionCoordinator.persistSelection(
                removedTargetSelection,
                for: identity,
                source: .mcpTabContext,
                mirrorToUIIfActive: false,
                expectedCurrentSelection: currentSelection
            )
            XCTAssertEqual(persisted, removedTargetSelection)
            let partitionScope = PartitionScope(
                workspaceID: fixture.workspaceID,
                tabID: Fixture.tabID
            )
            try await fixture.window.workspaceFilesViewModel._testPersistSlicesForScope(
                rootPath: physicalRootPath,
                scope: partitionScope,
                relativePath: Fixture.largeWorktreeRelativePath,
                ranges: []
            )
            await staleCommitGate.release()
            fixture.window.workspaceFilesViewModel.setHiddenSessionSliceRebaseWillCommitHandlerForTesting(nil)
            let staleFence = await fixture.window.workspaceFilesViewModel.waitForPendingSliceRebasesAndCaptureFence(
                affectingCandidatePaths: [physicalURL.path]
            )
            XCTAssertTrue(fixture.window.workspaceFilesViewModel.isSliceRebaseFenceCurrent(staleFence))
            let afterStaleCommit = try XCTUnwrap(
                fixture.window.workspaceManager.composeTab(for: identity)?.selection
            )
            XCTAssertEqual(afterStaleCommit.selectedPaths, [unrelatedLogicalPath])
            XCTAssertNil(afterStaleCommit.slices[targetLogicalPath])
            let stalePartition = await fixture.window.workspaceFilesViewModel._testLoadSlicesForScope(
                rootPath: physicalRootPath,
                scope: partitionScope,
                relativePath: Fixture.largeWorktreeRelativePath
            )
            XCTAssertNil(stalePartition)

            let matchingFullSet = try await fixture.socketClient.request(
                id: 8,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": [
                        "op": "set",
                        "paths": [targetLogicalPath],
                        "mode": "full",
                        "strict": true
                    ]
                ]
            )
            try Self.assertSuccessfulResponse(matchingFullSet, id: 8)
            _ = try await readFile(
                fixture: fixture,
                id: 9,
                path: targetLogicalPath,
                startLine: 140,
                limit: 10
            )
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let preservedFull = try XCTUnwrap(
                fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            )
            XCTAssertEqual(preservedFull.selectedPaths, [targetLogicalPath])
            XCTAssertNil(preservedFull.slices[targetLogicalPath])
        }

        func assertWorktreeSearchPhysicalCoverage(fixture: Fixture) async throws {
            try await clearSelection(fixture: fixture, id: 3)

            let unrelatedLogicalPath = fixture.rootURL
                .appendingPathComponent(Fixture.worktreeOnlyRelativePath)
                .path
            let fullSet = try await fixture.socketClient.request(
                id: 4,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": [
                        "op": "set",
                        "paths": [unrelatedLogicalPath],
                        "mode": "full",
                        "strict": true
                    ]
                ]
            )
            try Self.assertSuccessfulResponse(fullSet, id: 4)

            let physicalURL = try fixture.worktreeSearchCreatedFileURL
            var originalLines = (1 ... 29).map { "search-line-\($0)" }
            originalLines[3] = "WATCHER_BEGIN_ANCHOR_9F3A7C"
            originalLines[14] = "WATCHER_MIDDLE_ANCHOR_9F3A7C"
            originalLines[26] = "WATCHER_END_ANCHOR_9F3A7C"
            try (originalLines.joined(separator: "\n") + "\n").write(
                to: physicalURL,
                atomically: false,
                encoding: .utf8
            )
            let created = try await fixture.window.workspaceFileContextStore.acceptWatcherPayloadForTesting(
                rootID: fixture.installedWorktreeRootID,
                events: [(
                    absolutePath: physicalURL.path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
                    ),
                    eventId: 8_900_000_000_000_000_101
                )]
            )
            XCTAssertNotNil(created)
            _ = await fixture.window.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                userPath: physicalURL.path,
                fallbackScope: .allLoaded
            )

            let searchPattern = "WATCHER_(BEGIN|MIDDLE|END)_ANCHOR_9F3A7C"
            let response = try await fixture.socketClient.request(
                id: 5,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.search,
                    "arguments": [
                        "pattern": searchPattern,
                        "mode": "content",
                        "regex": true,
                        "context_lines": 2
                    ]
                ]
            )
            try Self.assertSuccessfulResponse(response, id: 5)
            XCTAssertTrue(response.contains(Fixture.searchCreatedRelativePath), response)
            XCTAssertFalse(try response.contains(fixture.worktreeRootPath), response)

            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let trace = try XCTUnwrap(fixture.window.mcpServer.fileSearchAutoSelectionTraceForTesting())
            XCTAssertEqual(trace.contentGroupCount, 1)
            XCTAssertEqual(trace.logicalEntryCount, 1)
            XCTAssertEqual(trace.resolvedPhysicalPathCount, 1)
            XCTAssertTrue(trace.hasCoverageIdentity)
            XCTAssertTrue(trace.accepted)

            let matchingLogicalPath = fixture.rootURL
                .appendingPathComponent(Fixture.searchCreatedRelativePath)
                .path
            let originalRanges = [
                LineRange(start: 2, end: 6),
                LineRange(start: 13, end: 17),
                LineRange(start: 25, end: 29)
            ]
            var selection = try XCTUnwrap(
                fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            )
            XCTAssertEqual(Set(selection.selectedPaths), Set([unrelatedLogicalPath, matchingLogicalPath]))
            XCTAssertNil(selection.slices[unrelatedLogicalPath])
            XCTAssertEqual(selection.slices[matchingLogicalPath], originalRanges)

            var editedLines = originalLines
            editedLines.insert(contentsOf: (1 ... 4).map { "top-insert-\($0)" }, at: 0)
            editedLines.insert(contentsOf: (1 ... 3).map { "middle-insert-\($0)" }, at: 13)
            editedLines.removeSubrange(26 ... 27)
            let replacementURL = physicalURL.deletingLastPathComponent()
                .appendingPathComponent(".SearchCreated.swift.atomic-\(UUID().uuidString)")
            try (editedLines.joined(separator: "\n") + "\n").write(
                to: replacementURL,
                atomically: false,
                encoding: .utf8
            )
            _ = try FileManager.default.replaceItemAt(physicalURL, withItemAt: replacementURL)
            let modified = try await fixture.window.workspaceFileContextStore.acceptWatcherPayloadForTesting(
                rootID: fixture.installedWorktreeRootID,
                events: [(
                    absolutePath: physicalURL.path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemRenamed
                            | kFSEventStreamEventFlagItemCreated
                            | kFSEventStreamEventFlagItemIsFile
                    ),
                    eventId: 8_900_000_000_000_000_102
                )]
            )
            XCTAssertNotNil(modified)
            _ = await fixture.window.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                userPath: physicalURL.path,
                fallbackScope: .allLoaded
            )
            let fence = await fixture.window.workspaceFilesViewModel.waitForPendingSliceRebasesAndCaptureFence(
                affectingCandidatePaths: [physicalURL.path]
            )
            XCTAssertTrue(fixture.window.workspaceFilesViewModel.isSliceRebaseFenceCurrent(fence))

            let expectedRanges = [
                LineRange(start: 6, end: 10),
                LineRange(start: 20, end: 24),
                LineRange(start: 30, end: 34)
            ]
            selection = try XCTUnwrap(
                fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            )
            XCTAssertEqual(Set(selection.selectedPaths), Set([unrelatedLogicalPath, matchingLogicalPath]))
            XCTAssertNil(selection.slices[unrelatedLogicalPath])
            XCTAssertEqual(selection.slices[matchingLogicalPath], expectedRanges)

            fixture.window.selectionCoordinator.flushPendingUISelectionToActiveTab()
            selection = try XCTUnwrap(
                fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            )
            XCTAssertEqual(Set(selection.selectedPaths), Set([unrelatedLogicalPath, matchingLogicalPath]))
            XCTAssertNil(selection.slices[unrelatedLogicalPath])
            XCTAssertEqual(selection.slices[matchingLogicalPath], expectedRanges)

            let matchingFullSet = try await fixture.socketClient.request(
                id: 6,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": [
                        "op": "set",
                        "paths": [matchingLogicalPath],
                        "mode": "full",
                        "strict": true
                    ]
                ]
            )
            try Self.assertSuccessfulResponse(matchingFullSet, id: 6)
            let repeatSearch = try await fixture.socketClient.request(
                id: 7,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.search,
                    "arguments": [
                        "pattern": searchPattern,
                        "mode": "content",
                        "regex": true,
                        "context_lines": 2
                    ]
                ]
            )
            try Self.assertSuccessfulResponse(repeatSearch, id: 7)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let preservedFull = try XCTUnwrap(
                fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            )
            XCTAssertEqual(preservedFull.selectedPaths, [matchingLogicalPath])
            XCTAssertNil(preservedFull.slices[matchingLogicalPath])
        }

        func assertThreeRootFileToolScope(fixture: Fixture) async throws {
            let searchCases: [(id: Int, pattern: String, expectedMatches: Int, filterPath: String?)] = try [
                (10, Fixture.canonicalOnlyMarker, 0, nil),
                (11, Fixture.worktreeOnlyMarker, 1, nil),
                (12, Fixture.nonGitVisibleMarker, 1, nil),
                (13, Fixture.nonGitVisibleMarker, 1, fixture.auxiliaryRootPath)
            ]
            for testCase in searchCases {
                var arguments: [String: Any] = [
                    "pattern": testCase.pattern,
                    "mode": "content",
                    "regex": false
                ]
                if let filterPath = testCase.filterPath {
                    arguments["filter"] = ["paths": [filterPath]]
                }
                let response = try await fixture.socketClient.request(
                    id: testCase.id,
                    method: "tools/call",
                    params: ["name": MCPWindowToolName.search, "arguments": arguments]
                )
                let text = try Self.readFileText(from: response, id: testCase.id)
                XCTAssertTrue(text.contains("- **Total matches**: \(testCase.expectedMatches)"), text)
                XCTAssertFalse(try text.contains(fixture.worktreeRootPath), text)
            }

            let nonGitFile = try fixture.auxiliarySwiftFileURL
            let readResponse = try await fixture.socketClient.request(
                id: 14,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.readFile,
                    "arguments": ["path": nonGitFile.path]
                ]
            )
            let readText = try Self.readFileText(from: readResponse, id: 14)
            XCTAssertTrue(readText.contains(Fixture.nonGitVisibleMarker), readText)

            MCPToolWorkCountDiagnostics.resetForTesting()
            let structureResponse = try await fixture.socketClient.request(
                id: 15,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.getCodeStructure,
                    "arguments": [
                        "scope": "paths",
                        "paths": [nonGitFile.path]
                    ]
                ]
            )
            let structureText = try Self.readFileText(from: structureResponse, id: 15)
            XCTAssertTrue(structureText.contains("- **Status**: `unavailable`"), structureText)
            XCTAssertTrue(structureText.contains("`git_root_unavailable`"), structureText)
            let work = MCPToolWorkCountDiagnostics.debugSnapshots().git
            XCTAssertEqual(work.count, 1)
            XCTAssertEqual(work.first?.operation, MCPWindowToolName.getCodeStructure)
            let gitCommands = work.first?.commands ?? []
            XCTAssertEqual(work.first?.commandCount, 3, gitCommands.joined(separator: "\n"))
            XCTAssertTrue(
                gitCommands.contains { $0.contains("rev-parse --show-toplevel") },
                gitCommands.joined(separator: "\n")
            )
            XCTAssertEqual(work.first?.outcome, "success")
        }

        func assertWorktreeCoverageCertificateRepeats(fixture: Fixture) async throws {
            try await clearSelection(fixture: fixture, id: 3)

            _ = try await readFile(
                fixture: fixture,
                id: 4,
                path: fixture.fileURL.path
            )
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let afterFull = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(afterFull.authoritativeFallbackCount, 1)
            XCTAssertEqual(afterFull.coverageCertificateHitCount, 0)
            XCTAssertEqual(afterFull.coverageCertificateMissReasonCounts[.noCertificate], 1)
            XCTAssertNotNil(try fixture.readFileAutoSelectionCoverageCertificate())

            _ = try await readFile(
                fixture: fixture,
                id: 5,
                path: fixture.fileURL.path
            )
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let afterFullRepeat = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(afterFullRepeat.coverageCertificateHitCount, 1)
            XCTAssertEqual(afterFullRepeat.authoritativeFallbackCount, 1)

            _ = try await readFile(
                fixture: fixture,
                id: 6,
                path: fixture.liveFileURL.path,
                startLine: 10,
                limit: 11
            )
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let afterSlice = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(afterSlice.authoritativeFallbackCount, 2)
            XCTAssertEqual(afterSlice.coverageCertificateMissReasonCounts[.batchMismatch], 1)

            _ = try await readFile(
                fixture: fixture,
                id: 7,
                path: fixture.liveFileURL.path,
                startLine: 10,
                limit: 11
            )
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let afterSliceRepeat = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(afterSliceRepeat.coverageCertificateHitCount, 2)

            let preexistingSliceFence = try await fixture.window.workspaceManager.fileManager
                .waitForPendingSliceRebasesAndCaptureFence(
                    affectingCandidatePaths: [fixture.liveFileURL.path, fixture.worktreeLiveFileURL.path]
                )
            XCTAssertTrue(
                fixture.window.workspaceManager.fileManager.isSliceRebaseFenceCurrent(preexistingSliceFence),
                "Fixture slice ingress must be quiescent before installing the deterministic late-ingress race"
            )

            let expansionContextKey = try fixture.readFileAutoSelectionContextKey()
            fixture.window.mcpServer.readFileAutoSelectionCoverageCertificates.removeValue(forKey: expansionContextKey)

            let delayedIngressGate = PersistentAsyncGate()
            let delayedIngressCompleted = PersistentAsyncSignal()
            var registeredDelayedIngress = false
            fixture.window.mcpServer.setReadFileAutoSelectionFinalRevalidationHandlerForTesting {
                guard !registeredDelayedIngress else { return }
                registeredDelayedIngress = true
                fixture.window.workspaceManager.fileManager.debugRegisterSliceRebaseTask(
                    fullPath: fixture.liveFileURL.path
                ) {
                    await fixture.window.workspaceManager.rebaseSlicesForFileAcrossTabs(
                        fullPath: fixture.liveFileURL.path,
                        asyncTransform: { _, ranges in
                            await delayedIngressGate.markStartedAndWaitForRelease()
                            return ranges
                        }
                    )
                    await delayedIngressCompleted.mark()
                }
                let started = await delayedIngressGate.waitUntilStarted()
                XCTAssertTrue(started, "Delayed slice-rebase ingress did not start during final revalidation")
                let completed = await self.waitUntilMarked(delayedIngressCompleted, timeout: .seconds(3))
                XCTAssertTrue(completed, "Delayed slice-rebase ingress did not complete before final revalidation")
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionFinalRevalidationHandlerForTesting(nil)
                Task { await delayedIngressGate.release() }
            }

            _ = try await readFile(
                fixture: fixture,
                id: 8,
                path: fixture.liveFileURL.path,
                startLine: 5,
                limit: 16
            )
            try await requireGateStarted(delayedIngressGate)
            XCTAssertNil(try fixture.readFileAutoSelectionCoverageCertificate())

            var selectionAdvancedAfterIngressSnapshot = try XCTUnwrap(
                fixture.window.workspaceManager.composeTab(with: Fixture.tabID)
            )
            selectionAdvancedAfterIngressSnapshot.selection = StoredSelection(
                selectedPaths: [
                    fixture.fileURL.path,
                    fixture.liveFileURL.path,
                    fixture.worktreeOnlyLogicalURL.path
                ],

                slices: [
                    fixture.liveFileURL.path: [LineRange(start: 1, end: 20)],
                    fixture.worktreeOnlyLogicalURL.path: [LineRange(start: 30, end: 40)]
                ],
                codemapAutoEnabled: selectionAdvancedAfterIngressSnapshot.selection.codemapAutoEnabled
            )
            let selectionAdvanceIdentity = WorkspaceSelectionIdentity(
                workspaceID: fixture.workspaceID,
                tabID: Fixture.tabID
            )
            let persistedSelectionAdvance = try await fixture.window.selectionCoordinator.persistSelection(
                selectionAdvancedAfterIngressSnapshot.selection,
                for: selectionAdvanceIdentity,
                source: .mcpTabContext,
                mirrorToUIIfActive: false,
                expectedCurrentSelection: XCTUnwrap(
                    fixture.window.workspaceManager.composeTab(for: selectionAdvanceIdentity)?.selection
                )
            )
            XCTAssertEqual(
                persistedSelectionAdvance,
                selectionAdvancedAfterIngressSnapshot.selection,
                "Deterministic late-ingress selection advance did not persist through the canonical coordinator"
            )

            await delayedIngressGate.release()
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let afterExpansion = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(afterExpansion.authoritativeFallbackCount, 3)
            XCTAssertEqual(afterExpansion.coverageCertificateMissReasonCounts[.noCertificate], 2)
            XCTAssertEqual(afterExpansion.coverageCertificateMissReasonCounts[.batchMismatch], 1)
            XCTAssertNotNil(try fixture.readFileAutoSelectionCoverageCertificate())

            let target = try fixture.readFileAutoSelectionTarget()
            let staleTarget = MCPServerViewModel.DebugReadFileAutoSelectionTarget(
                connectionID: target.connectionID,
                runID: target.runID,
                agentSessionID: UUID(),
                workspaceID: target.workspaceID,
                tabID: target.tabID,
                route: target.route,
                bindingGeneration: target.bindingGeneration,
                contextKey: target.contextKey
            )
            XCTAssertNil(fixture.window.mcpServer.debugBeginReadFileAutoSelectionProbe(
                probeID: UUID(),
                forceAuthoritative: true,
                for: staleTarget
            ))

            let registry = MCPReadFileAutoSelectionProbeRegistry.shared
            await registry.resetForTesting()
            defer { Task { await registry.resetForTesting() } }

            let probeArguments: [String: Value] = [
                "window_id": .int(fixture.windowID),
                "target_connection_id": .string(Fixture.connectionID.uuidString),
                "expected_run_id": .string(Fixture.runID.uuidString),
                "force_authoritative": .bool(true),
                "expiry_ms": .int(10000)
            ]
            var probeIDs: [UUID] = []
            for _ in 0 ..< 16 {
                let begin = await fixture.networkManager.debugMCPReadFileAutoSelectionProbeBeginPayload(
                    op: "mcp_read_file_auto_selection_probe_begin",
                    arguments: probeArguments
                )
                let payload = try Self.diagnosticsPayload(begin)
                XCTAssertEqual(payload["ok"] as? Bool, true)
                try probeIDs.append(XCTUnwrap((payload["probe_id"] as? String).flatMap(UUID.init(uuidString:))))
            }
            XCTAssertEqual(
                fixture.window.mcpServer.debugReadFileAutoSelectionForcedAuthoritativeProbeCount(for: target),
                16
            )
            let otherKey = MCPReadFileAutoSelectionCoordinator.ContextKey(
                windowID: target.contextKey.windowID,
                workspaceID: target.contextKey.workspaceID,
                tabID: UUID(),
                route: target.contextKey.route,
                bindingGeneration: target.contextKey.bindingGeneration
            )
            let otherTarget = MCPServerViewModel.DebugReadFileAutoSelectionTarget(
                connectionID: target.connectionID,
                runID: target.runID,
                agentSessionID: target.agentSessionID,
                workspaceID: target.workspaceID,
                tabID: otherKey.tabID,
                route: target.route,
                bindingGeneration: otherKey.bindingGeneration,
                contextKey: otherKey
            )
            XCTAssertEqual(
                fixture.window.mcpServer.debugReadFileAutoSelectionForcedAuthoritativeProbeCount(for: otherTarget),
                0
            )

            let installCountBeforeRejectedAdmission = fixture.window.mcpServer
                .debugReadFileAutoSelectionForcedAuthoritativeProbeInstallCount()
            let rejectedBegin = await fixture.networkManager.debugMCPReadFileAutoSelectionProbeBeginPayload(
                op: "mcp_read_file_auto_selection_probe_begin",
                arguments: probeArguments
            )
            let rejectedPayload = try Self.diagnosticsPayload(rejectedBegin)
            XCTAssertEqual(rejectedPayload["code"] as? String, "probe_capacity")
            XCTAssertEqual(
                fixture.window.mcpServer.debugReadFileAutoSelectionForcedAuthoritativeProbeInstallCount(),
                installCountBeforeRejectedAdmission,
                "A rejected admission must never invoke force installation"
            )
            XCTAssertEqual(
                fixture.window.mcpServer.debugReadFileAutoSelectionForcedAuthoritativeProbeCount(for: target),
                16,
                "A rejected admission must never transiently install another force lease"
            )

            _ = try await readFile(
                fixture: fixture,
                id: 9,
                path: fixture.liveFileURL.path,
                startLine: 5,
                limit: 16
            )
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let afterForcedAuthoritative = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(afterForcedAuthoritative.authoritativeFallbackCount, 4)
            XCTAssertEqual(afterForcedAuthoritative.coverageCertificateMissReasonCounts[.forcedAuthoritative], 1)

            let drainedProbeID = probeIDs.removeFirst()
            let drain = await fixture.networkManager.debugMCPReadFileAutoSelectionProbeDrainPayload(
                op: "mcp_read_file_auto_selection_probe_drain",
                arguments: ["probe_id": .string(drainedProbeID.uuidString)]
            )
            let drainPayload = try Self.diagnosticsPayload(drain)
            XCTAssertEqual(drainPayload["result"] as? String, "completed")
            XCTAssertEqual(
                fixture.window.mcpServer.debugReadFileAutoSelectionForcedAuthoritativeProbeCount(for: target),
                15
            )
            for probeID in probeIDs {
                let cancel = await fixture.networkManager.debugMCPReadFileAutoSelectionProbeCancelPayload(
                    op: "mcp_read_file_auto_selection_probe_cancel",
                    arguments: ["probe_id": .string(probeID.uuidString)]
                )
                let cancelPayload = try Self.diagnosticsPayload(cancel)
                XCTAssertEqual(cancelPayload["result"] as? String, "cancelled")
            }
            XCTAssertEqual(
                fixture.window.mcpServer.debugReadFileAutoSelectionForcedAuthoritativeProbeCount(for: target),
                0
            )
            let remainingProbeEntryCount = await registry.entryCountForTesting()
            let remainingProbeReservationCount = await registry.reservationCountForTesting()
            XCTAssertEqual(remainingProbeEntryCount, 0)
            XCTAssertEqual(remainingProbeReservationCount, 0)
            _ = try await readFile(
                fixture: fixture,
                id: 10,
                path: fixture.liveFileURL.path,
                startLine: 5,
                limit: 16
            )
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            XCTAssertEqual(try fixture.readFileAutoSelectionContextSnapshot().coverageCertificateHitCount, 3)

            assertCanonicalSelection(
                fixture: fixture,
                selectedPaths: [
                    fixture.fileURL.path,
                    fixture.liveFileURL.path,
                    fixture.worktreeOnlyLogicalURL.path
                ],
                slices: [
                    fixture.liveFileURL.path: [LineRange(start: 1, end: 20)],
                    fixture.worktreeOnlyLogicalURL.path: [LineRange(start: 30, end: 40)]
                ]
            )
        }

        func assertWorktreeCoverageCertificatePersistenceBoundary(fixture: Fixture) async throws {
            try await clearSelection(fixture: fixture, id: 3)
            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionPersistenceGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            fixture.window.mcpServer.setReadFileAutoSelectionFinalRevalidationHandlerForTesting {
                guard var tab = fixture.window.workspaceManager.composeTab(with: Fixture.tabID) else {
                    return XCTFail("Missing canonical tab during final certificate revalidation")
                }
                tab.selection = StoredSelection(selectedPaths: [fixture.fileURL.path, fixture.liveFileURL.path])
                XCTAssertTrue(fixture.window.workspaceManager.updateComposeTabStoredOnly(
                    tab,
                    inWorkspaceID: fixture.workspaceID
                ))
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionPersistenceGateForTesting(nil)
                fixture.window.mcpServer.setReadFileAutoSelectionFinalRevalidationHandlerForTesting(nil)
                Task { await gate.release() }
            }

            let read = gatedReadTask(fixture: fixture, id: 4)
            try await requireGateStarted(gate)
            try await assertReadReplyReturned(read, gate: gate, id: 4)
            XCTAssertNil(try fixture.readFileAutoSelectionCoverageCertificate())

            await gate.release()
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let certificate = try XCTUnwrap(fixture.readFileAutoSelectionCoverageCertificate())
            XCTAssertEqual(certificate.selectionRevision, fixture.canonicalSelectionRevision())
            XCTAssertEqual(
                fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection.selectedPaths,
                [fixture.fileURL.path, fixture.liveFileURL.path]
            )

            _ = try await readFile(fixture: fixture, id: 5, path: fixture.fileURL.path)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let final = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(final.coverageCertificateHitCount, 1)
            XCTAssertEqual(final.authoritativeFallbackCount, 1)
        }

        func assertWorktreeCoverageCertificateFailClosed(fixture: Fixture) async throws {
            try await clearSelection(fixture: fixture, id: 3)
            _ = try await readFile(fixture: fixture, id: 4, path: fixture.fileURL.path)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            _ = try await readFile(fixture: fixture, id: 5, path: fixture.fileURL.path)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            XCTAssertEqual(try fixture.readFileAutoSelectionContextSnapshot().coverageCertificateHitCount, 1)

            try fixture.replaceReadFileAutoSelectionCertificate { certificate in
                ReadFileAutoSelectionCoverageCertificate(
                    batchIdentity: certificate.batchIdentity,
                    agentSessionID: certificate.agentSessionID,
                    bindingFingerprint: certificate.bindingFingerprint,
                    selectionRevision: certificate.selectionRevision &+ 1,
                    rootScope: certificate.rootScope,
                    visibleCatalogGeneration: certificate.visibleCatalogGeneration,
                    rootScopeCatalogGeneration: certificate.rootScopeCatalogGeneration
                )
            }
            _ = try await readFile(fixture: fixture, id: 6, path: fixture.fileURL.path)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            var snapshot = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(snapshot.coverageCertificateMissReasonCounts[.selectionRevisionMismatch], 1)

            try fixture.replaceReadFileAutoSelectionCertificate { certificate in
                ReadFileAutoSelectionCoverageCertificate(
                    batchIdentity: certificate.batchIdentity,
                    agentSessionID: certificate.agentSessionID,
                    bindingFingerprint: certificate.bindingFingerprint,
                    selectionRevision: certificate.selectionRevision,
                    rootScope: certificate.rootScope,
                    visibleCatalogGeneration: certificate.visibleCatalogGeneration &+ 1,
                    rootScopeCatalogGeneration: certificate.rootScopeCatalogGeneration
                )
            }
            _ = try await readFile(fixture: fixture, id: 7, path: fixture.fileURL.path)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            snapshot = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(snapshot.coverageCertificateMissReasonCounts[.visibleCatalogGenerationMismatch], 1)

            try fixture.replaceReadFileAutoSelectionCertificate { certificate in
                ReadFileAutoSelectionCoverageCertificate(
                    batchIdentity: certificate.batchIdentity,
                    agentSessionID: certificate.agentSessionID,
                    bindingFingerprint: certificate.bindingFingerprint,
                    selectionRevision: certificate.selectionRevision,
                    rootScope: certificate.rootScope,
                    visibleCatalogGeneration: certificate.visibleCatalogGeneration,
                    rootScopeCatalogGeneration: certificate.rootScopeCatalogGeneration &+ 1
                )
            }
            _ = try await readFile(fixture: fixture, id: 8, path: fixture.fileURL.path)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            snapshot = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(snapshot.coverageCertificateMissReasonCounts[.rootScopeCatalogGenerationMismatch], 1)

            try fixture.replaceWorktreeBindingCheckoutMetadata()
            _ = try await readFile(fixture: fixture, id: 9, path: fixture.fileURL.path)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            snapshot = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(snapshot.coverageCertificateMissReasonCounts[.bindingFingerprintMismatch], 1)
            _ = try await readFile(fixture: fixture, id: 10, path: fixture.fileURL.path)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            XCTAssertEqual(try fixture.readFileAutoSelectionContextSnapshot().coverageCertificateHitCount, 2)

            let worktreeAKey = try fixture.readFileAutoSelectionContextKey()
            XCTAssertNotNil(fixture.window.mcpServer.readFileAutoSelectionCoverageCertificates[worktreeAKey])
            try await fixture.rebindToReplacementPhysicalWorktree()
            let worktreeBKey = try fixture.readFileAutoSelectionContextKey()
            XCTAssertNotEqual(worktreeBKey, worktreeAKey)
            XCTAssertNil(fixture.window.mcpServer.readFileAutoSelectionCoverageCertificates[worktreeAKey])

            let worktreeBRead = try await readFile(fixture: fixture, id: 11, path: fixture.fileURL.path)
            XCTAssertTrue(worktreeBRead.contains(Fixture.replacementWorktreeSentinelContent), worktreeBRead)
            XCTAssertFalse(worktreeBRead.contains(Fixture.sentinelContent), worktreeBRead)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            snapshot = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(snapshot.authoritativeFallbackCount, 1)
            XCTAssertEqual(snapshot.coverageCertificateHitCount, 0)

            _ = try await readFile(fixture: fixture, id: 12, path: fixture.fileURL.path)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            XCTAssertEqual(try fixture.readFileAutoSelectionContextSnapshot().coverageCertificateHitCount, 1)

            _ = try XCTUnwrap(
                fixture.window.mcpServer.readFileAutoSelectionCoverageCertificates[worktreeBKey]
            )
            let physicalPath = try fixture.worktreeFileURL.path
            try fixture.removeWorktreeDirectory()
            let intent = MCPReadFileAutoSelectionCoordinator.Intent.full(paths: [fixture.fileURL.path])
            let coverage = try XCTUnwrap(MCPReadFileAutoSelectionCoordinator.CoverageIdentity(
                intent: intent,
                resolvedPaths: [physicalPath]
            ))
            XCTAssertTrue(fixture.window.mcpServer.readFileAutoSelectionCoordinator.enqueue(
                intent: intent,
                coverageIdentity: coverage,
                for: worktreeBKey
            ))
            let unavailableDrain = await fixture.window.mcpServer.readFileAutoSelectionCoordinator.drain(
                .canonicalSelection,
                for: worktreeBKey
            )
            XCTAssertEqual(unavailableDrain, .completed)
            snapshot = try fixture.readFileAutoSelectionContextSnapshot()
            XCTAssertEqual(snapshot.coverageCertificateMissReasonCounts[.bindingUnavailable], 1)
            XCTAssertNil(fixture.window.mcpServer.readFileAutoSelectionCoverageCertificates[worktreeBKey])
        }

        func readFile(
            fixture: Fixture,
            id: Int,
            path: String,
            startLine: Int? = nil,
            limit: Int? = nil
        ) async throws -> String {
            let target = try fixture.readFileAutoSelectionTarget()
            let acceptedBeforeRead = fixture.window.mcpServer
                .debugReadFileAutoSelectionContextSnapshot(for: target)?.acceptedIntentCount ?? 0
            var arguments: [String: Any] = ["path": path]
            if let startLine { arguments["start_line"] = startLine }
            if let limit { arguments["limit"] = limit }
            let response = try await fixture.socketClient.request(
                id: id,
                method: "tools/call",
                params: ["name": MCPWindowToolName.readFile, "arguments": arguments]
            )
            let text = try Self.readFileText(from: response, id: id)
            let intentAccepted = await waitForReadFileAutoSelectionAcceptedCount(
                fixture: fixture,
                target: target,
                minimum: acceptedBeforeRead + 1
            )
            XCTAssertTrue(intentAccepted, "Read-file auto-selection intent was not accepted")
            return text
        }

        func waitForReadFileAutoSelectionAcceptedCount(
            fixture: Fixture,
            target: MCPServerViewModel.DebugReadFileAutoSelectionTarget,
            minimum: UInt64
        ) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                let accepted = fixture.window.mcpServer
                    .debugReadFileAutoSelectionContextSnapshot(for: target)?.acceptedIntentCount ?? 0
                if accepted >= minimum { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let accepted = fixture.window.mcpServer
                .debugReadFileAutoSelectionContextSnapshot(for: target)?.acceptedIntentCount ?? 0
            return accepted >= minimum
        }

        func assertAgentOwnedSequentialReadUnion(fixture: Fixture) async throws {
            try await clearSelection(fixture: fixture, id: 3)

            let fullRead = try await fixture.socketClient.request(
                id: 4,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.readFile,
                    "arguments": ["path": fixture.fileURL.path]
                ]
            )
            let fullText = try Self.readFileText(from: fullRead, id: 4)
            XCTAssertTrue(fullText.contains(Fixture.sentinelContent), fullText)
            let firstSettled = await waitForReadFileAutoSelectionToSettle(fixture: fixture)
            XCTAssertTrue(firstSettled, "First read auto-selection did not converge without manage_selection get")
            assertCanonicalSelection(
                fixture: fixture,
                selectedPaths: [fixture.fileURL.path],
                slices: [:]
            )

            // Reproduce the production failure boundary: routing/handoff/mirror state may retain
            // an older working snapshot even though canonical persistence and its mirror completed.
            // The next additive read must merge from canonical storage, never this cache.
            fixture.window.mcpServer.tabContextByConnectionID[Fixture.connectionID]?.selection = StoredSelection()

            let slicedRead = try await fixture.socketClient.request(
                id: 5,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.readFile,
                    "arguments": [
                        "path": fixture.liveFileURL.path,
                        "start_line": 2,
                        "limit": 2
                    ]
                ]
            )
            let slicedText = try Self.readFileText(from: slicedRead, id: 5)
            XCTAssertTrue(slicedText.contains("**Lines**: 2–3"), slicedText)
            let finalSettled = await waitForReadFileAutoSelectionToSettle(fixture: fixture)
            XCTAssertTrue(finalSettled, "Cumulative read auto-selection did not converge without manage_selection get")
            let expectedPaths = [fixture.fileURL.path, fixture.liveFileURL.path]
            let expectedSlices = [fixture.liveFileURL.path: [LineRange(start: 2, end: 3)]]
            assertCanonicalSelection(
                fixture: fixture,
                selectedPaths: expectedPaths,
                slices: expectedSlices
            )
            let liveSelection = fixture.window.workspaceFilesViewModel.snapshotSelection()
            XCTAssertEqual(Set(liveSelection.selectedPaths), Set(expectedPaths))
            XCTAssertEqual(liveSelection.slices, expectedSlices)
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
            } catch {
                await independent.cleanup()
                throw error
            }
            await independent.cleanup()
        }

        func assertManageSelectionGetCanonicalHandover(fixture: Fixture) async throws {
            try await clearSelection(fixture: fixture, id: 3)
            let revisionAfterClear = fixture.canonicalSelectionRevision()
            let predecessorGeneration = try XCTUnwrap(
                fixture.window.mcpServer.tabContextByConnectionID[Fixture.connectionID]?
                    .readFileAutoSelectionGeneration
            )
            let canonicalGate = PersistentAsyncGate()
            let mirrorGate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await canonicalGate.markStartedAndWaitForRelease()
            }
            fixture.window.mcpServer.setReadFileAutoSelectionMirrorGateForTesting {
                await mirrorGate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                fixture.window.mcpServer.setReadFileAutoSelectionMirrorGateForTesting(nil)
                fixture.window.mcpServer.setReadFileAutoSelectionPredecessorDrainWaiterRegisteredHandlerForTesting(nil)
                Task {
                    await canonicalGate.release()
                    await mirrorGate.release()
                }
            }

            let read = try await fixture.socketClient.request(
                id: 4,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.readFile,
                    "arguments": ["path": fixture.fileURL.path]
                ]
            )
            let readText = try Self.readFileText(from: read, id: 4)
            XCTAssertTrue(readText.contains(Fixture.sentinelContent), readText)
            try await requireGateStarted(canonicalGate)
            XCTAssertEqual(fixture.canonicalSelectionRevision(), revisionAfterClear)

            let handover = try await fixture.makeHandoverConnection()
            do {
                let replacementContext = try XCTUnwrap(
                    fixture.window.mcpServer.tabContextByConnectionID[handover.connectionID]
                )
                XCTAssertGreaterThan(replacementContext.readFileAutoSelectionGeneration, predecessorGeneration)
                XCTAssertEqual(
                    fixture.window.mcpServer.readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
                        connectionID: handover.connectionID
                    ),
                    [Fixture.connectionID]
                )

                let predecessorWaiterRegistered = expectation(
                    description: "replacement manage_selection get registered predecessor canonical waiter"
                )
                fixture.window.mcpServer.setReadFileAutoSelectionPredecessorDrainWaiterRegisteredHandlerForTesting {
                    predecessorWaiterRegistered.fulfill()
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
                await fulfillment(of: [predecessorWaiterRegistered], timeout: 2)
                let returnedBeforePredecessorCanonical = await getFinished.isMarked()
                XCTAssertFalse(
                    returnedBeforePredecessorCanonical,
                    "Replacement get must preserve predecessor canonical handover ordering"
                )

                await canonicalGate.release()
                try await requireGateStarted(mirrorGate)
                let returnedWhileMirrorBlocked = await waitUntilMarked(getFinished, timeout: .seconds(2))
                XCTAssertTrue(
                    returnedWhileMirrorBlocked,
                    "manage_selection get must return after canonical persistence without waiting for the mirror"
                )
                if !returnedWhileMirrorBlocked {
                    await mirrorGate.release()
                }
                let response = try await getTask.value
                try Self.assertSuccessfulResponse(response, id: 3)
                XCTAssertTrue(response.contains(fixture.fileURL.lastPathComponent), response)
                XCTAssertGreaterThan(fixture.canonicalSelectionRevision(), revisionAfterClear)
                assertCanonicalSelection(
                    fixture: fixture,
                    selectedPaths: [fixture.fileURL.path],
                    slices: [:]
                )
                await mirrorGate.release()
            } catch {
                await handover.cleanup()
                throw error
            }
            await handover.cleanup()
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
                let failureContext = "canonical=\(String(describing: stored?.selection)); header=\(String(describing: header?.selection)); "
                    + "readAutoSelection=\(fixture.window.mcpServer.readFileAutoSelectionDiagnosticsSnapshot())"
                XCTAssertEqual(header?.selection.selectedPaths, selectedPaths, failureContext)
                XCTAssertEqual(header?.selection.slices, slices, failureContext)
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
            try await clearSelection(fixture: fixture, id: 5)
            let searchNeedle = "persistentAgentModeSearchContextNeedle"
            let searchFixtureContent = [
                "line 1", "line 2", "line 3", "line 4", searchNeedle,
                "line 6", "line 7", "line 8", "line 9"
            ].joined(separator: "\n") + "\n"
            let lookup = await fixture.window.workspaceFileContextStore.lookupPath(
                fixture.fileURL.path,
                profile: .mcpRead,
                rootScope: .visibleWorkspace
            )
            let file = try XCTUnwrap(lookup?.file)
            try await fixture.window.workspaceFileContextStore.editFile(
                rootID: file.rootID,
                relativePath: file.standardizedRelativePath,
                newContent: searchFixtureContent
            )

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
                            "pattern": searchNeedle,
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
            let searchSliceSelection = fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            XCTAssertEqual(
                searchSliceSelection?.slices[fixture.fileURL.path],
                [LineRange(start: 3, end: 7)]
            )

            let fullSet = try await fixture.socketClient.request(
                id: 8,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": [
                        "op": "set",
                        "paths": [fixture.fileURL.path],
                        "mode": "full",
                        "strict": true
                    ]
                ]
            )
            try Self.assertSuccessfulResponse(fullSet, id: 8)
            let repeatSearch = try await fixture.socketClient.request(
                id: 9,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.search,
                    "arguments": [
                        "pattern": searchNeedle,
                        "mode": "content",
                        "regex": false,
                        "context_lines": 2
                    ]
                ]
            )
            try Self.assertSuccessfulResponse(repeatSearch, id: 9)
            await assertReadFileAutoSelectionSettled(fixture: fixture)
            let preservedFullSelection = fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            XCTAssertEqual(preservedFullSelection?.selectedPaths, [fixture.fileURL.path])
            XCTAssertNil(preservedFullSelection?.slices[fixture.fileURL.path])
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

        func assertReadFileAutoSelectionSettled(fixture: Fixture) async {
            let settled = await waitForReadFileAutoSelectionToSettle(fixture: fixture)
            XCTAssertTrue(
                settled,
                "Read-file auto-selection mirrored drain did not complete; diagnostics: \(fixture.window.mcpServer.readFileAutoSelectionDiagnosticsSnapshot())"
            )
        }

        func waitForReadFileAutoSelectionToSettle(fixture: Fixture) async -> Bool {
            guard let target = try? fixture.readFileAutoSelectionTarget() else { return false }
            return await fixture.window.mcpServer.readFileAutoSelectionCoordinator.drain(
                .mirroredSelectionAndMetrics,
                for: target.contextKey
            ) == .completed
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

        static func diagnosticsPayload(_ result: CallTool.Result) throws -> [String: Any] {
            let text = result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined()
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
        static let parentSessionToken = "persistent-agent-mode-read-file-parent-session"
        static let sentinelContent = """
        let persistentAgentModeCheckpoint = "retained-session-read"
        let persistentAgentModeLineTwo = 2
        let persistentAgentModeLineThree = 3
        let persistentAgentModeLineFour = 4
        """
        static let replacementWorktreeSentinelContent = """
        let persistentAgentModeCheckpoint = "replacement-physical-worktree-read"
        let persistentAgentModeReplacementLineTwo = 22
        """
        static let liveRelativePath = "Tests/RepoPromptTests/MCP/GeneratedOracleExportFileWriterTests.swift"
        static let worktreeOnlyRelativePath = "Tests/RepoPromptTests/MCP/WorktreeOnlySelection.swift"
        static let largeWorktreeRelativePath = "Tests/RepoPromptTests/MCP/SessionWorktree6500.swift"
        static let searchCreatedRelativePath = "Tests/RepoPromptTests/MCP/SearchCreated.swift"
        static let canonicalOnlyMarker = "RPCE_CANONICAL_ONLY"
        static let worktreeOnlyMarker = "RPCE_WORKTREE_ONLY"
        static let nonGitVisibleMarker = "RPCE_NONGIT_VISIBLE"
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
        let gitBacked: Bool
        private var worktreeRootURL: URL?
        private var worktreeRootID: UUID?
        private var retiredWorktreeRootURLs: [URL] = []
        private var retiredWorktreeRootIDs: [UUID] = []
        private var worktreeBinding: AgentSessionWorktreeBinding?
        private var auxiliaryRootURL: URL?
        private var auxiliaryRootID: UUID?
        private var peerRootID: UUID?
        private var peerTargetStateVersionBeforeSelection: Int?
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
            agentOwned: Bool,
            gitBacked: Bool
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
            self.gitBacked = gitBacked
        }

        static func make(
            agentOwned: Bool = false,
            inactiveAgentTab: Bool = false,
            gitBacked: Bool = false
        ) async throws -> Fixture {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PersistentAgentModeMCPReadFileConnectionTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fileURL = rootURL.appendingPathComponent("Sources/PersistentAgentModeFixture.swift")
            let canonicalOnlyFileURL = rootURL.appendingPathComponent("Sources/CanonicalOnly.swift")
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
                try "let \(canonicalOnlyMarker) = true\n".write(
                    to: canonicalOnlyFileURL,
                    atomically: true,
                    encoding: .utf8
                )
                try liveContents.logical.write(to: liveFileURL, atomically: true, encoding: .utf8)
                if gitBacked {
                    _ = try GitWorktreeTestSupport.runGit(["init"], cwd: rootURL)
                    _ = try GitWorktreeTestSupport.runGit(["config", "user.name", "RepoPrompt Test"], cwd: rootURL)
                    _ = try GitWorktreeTestSupport.runGit(
                        ["config", "user.email", "repoprompt@example.test"],
                        cwd: rootURL
                    )
                    _ = try GitWorktreeTestSupport.runGit(["config", "commit.gpgSign", "false"], cwd: rootURL)
                    _ = try GitWorktreeTestSupport.runGit(["add", "."], cwd: rootURL)
                    _ = try GitWorktreeTestSupport.runGit(["commit", "-m", "fixture"], cwd: rootURL)
                }
            } catch {
                try? FileManager.default.removeItem(at: rootURL)
                throw error
            }

            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            let routingGuardWindow = WindowState()
            await window.workspaceManager.awaitInitialized()
            await routingGuardWindow.workspaceManager.awaitInitialized()
            if agentOwned {
                window.mcpServer.registerAgentWorktreeBindingsProvider { sessionID, tabID in
                    guard sessionID == agentSessionID, tabID == Self.tabID else { return .hydrated([]) }
                    return .hydrated([])
                }
            }
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
                let rootRecord = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(in: window, path: rootURL.path)
                rootID = rootRecord.id
                let exactHit = await WorkspaceReadableFileService(store: window.workspaceFileContextStore)
                    .resolveExactAbsoluteWorkspaceCatalogHit(fileURL.path, rootScope: .visibleWorkspace)
                guard exactHit?.standardizedFullPath == fileURL.path else {
                    throw ClientFixtureError.exactAbsoluteCatalogMiss
                }
                await window.workspaceManager.fileManager.waitForPendingPresentationTasks()
                let presentationIdentity = WorkspaceSelectionIdentity(
                    workspaceID: activeWorkspace.id,
                    tabID: tabID
                )
                let canonicalPresentationTab = try XCTUnwrap(
                    window.workspaceManager.composeTab(for: presentationIdentity),
                    "Fixture presentation barrier completed without the canonical target tab"
                )
                let headerPresentationTab = try XCTUnwrap(
                    window.promptManager.currentComposeTabs.first { $0.id == tabID },
                    "Fixture presentation barrier completed without the target header tab"
                )
                guard headerPresentationTab.selection == canonicalPresentationTab.selection,
                      headerPresentationTab.activeAgentSessionID == canonicalPresentationTab.activeAgentSessionID
                else {
                    throw ClientFixtureError.presentationStateMismatch(
                        "canonical selection=\(canonicalPresentationTab.selection), session=\(String(describing: canonicalPresentationTab.activeAgentSessionID)); "
                            + "header selection=\(headerPresentationTab.selection), session=\(String(describing: headerPresentationTab.activeAgentSessionID))"
                    )
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
                    // A capability token is pinned to one run for that run's lifetime.
                    // Seed an independent parent-run affinity without reusing the child run's token.
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
                        sessionKey: parentSessionToken,
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
                    agentOwned: agentOwned,
                    gitBacked: gitBacked
                )
            } catch {
                await connectionManager?.stop()
                socketClient?.close()
                window.beginClose()
                routingGuardWindow.beginClose()
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
                await window.tearDown()
                await routingGuardWindow.tearDown()
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
            try "struct \(Self.nonGitVisibleMarker) {}\n".write(
                to: auxiliaryRootURL.appendingPathComponent("Plain.swift"),
                atomically: true,
                encoding: .utf8
            )
            let auxiliaryRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(in: window, path: auxiliaryRootURL.path)
            auxiliaryRootID = auxiliaryRoot.id

            let worktreeRootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PersistentAgentModeMCPReadFileConnectionTests-Worktree", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            self.worktreeRootURL = worktreeRootURL
            if gitBacked {
                _ = try GitWorktreeTestSupport.runGit(
                    ["worktree", "add", "--detach", worktreeRootURL.path, "HEAD"],
                    cwd: rootURL
                )
                try FileManager.default.removeItem(
                    at: worktreeRootURL.appendingPathComponent("Sources/CanonicalOnly.swift")
                )
            }
            let worktreeFileURL = worktreeRootURL.appendingPathComponent("Sources/PersistentAgentModeFixture.swift")
            let worktreeLiveFileURL = worktreeRootURL.appendingPathComponent(Self.liveRelativePath)
            let worktreeOnlyFileURL = worktreeRootURL.appendingPathComponent(Self.worktreeOnlyRelativePath)
            let largeWorktreeFileURL = worktreeRootURL.appendingPathComponent(Self.largeWorktreeRelativePath)
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
            try FileManager.default.createDirectory(
                at: largeWorktreeFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let liveContents = try Self.liveContents()
            try Self.sentinelContent.write(to: worktreeFileURL, atomically: true, encoding: .utf8)
            try liveContents.worktree.write(to: worktreeLiveFileURL, atomically: true, encoding: .utf8)
            try "let \(Self.worktreeOnlyMarker) = true\n".write(
                to: worktreeOnlyFileURL,
                atomically: true,
                encoding: .utf8
            )
            let largeWorktreeText = (1 ... 6500)
                .map { String(format: "line-%05d", $0) }
                .joined(separator: "\n") + "\n"
            try largeWorktreeText.write(
                to: largeWorktreeFileURL,
                atomically: false,
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
            worktreeBinding = binding
            installWorktreeBindingProvider(binding)
            window.workspaceFilesViewModel.setSessionWorktreeBindingsProvider { sessionID in
                sessionID == Self.agentSessionID ? [binding] : []
            }
            let projection = try await WorkspaceRootBindingProjectionMaterializer(
                store: window.workspaceFileContextStore
            ).materialize(sessionID: Self.agentSessionID, bindings: [binding])
            XCTAssertNotNil(projection)
        }

        private func installWorktreeBindingProvider(_ binding: AgentSessionWorktreeBinding) {
            window.mcpServer.registerAgentWorktreeBindingsProvider { sessionID, tabID in
                guard sessionID == Self.agentSessionID, tabID == Self.tabID else { return .hydrated([]) }
                return .hydrated([binding])
            }
        }

        var installedWorktreeRootID: UUID {
            get throws {
                try XCTUnwrap(worktreeRootID)
            }
        }

        var auxiliaryRootPath: String {
            get throws {
                try XCTUnwrap(auxiliaryRootURL).path
            }
        }

        var auxiliarySwiftFileURL: URL {
            get throws {
                try XCTUnwrap(auxiliaryRootURL).appendingPathComponent("Plain.swift")
            }
        }

        var worktreeLargeFileURL: URL {
            get throws {
                try XCTUnwrap(worktreeRootURL).appendingPathComponent(Self.largeWorktreeRelativePath)
            }
        }

        var worktreeSearchCreatedFileURL: URL {
            get throws {
                try XCTUnwrap(worktreeRootURL).appendingPathComponent(Self.searchCreatedRelativePath)
            }
        }

        var worktreeRootPath: String {
            get throws {
                try XCTUnwrap(worktreeRootURL).path
            }
        }

        var worktreeFileURL: URL {
            get throws {
                try XCTUnwrap(worktreeRootURL).appendingPathComponent("Sources/PersistentAgentModeFixture.swift")
            }
        }

        var worktreeLiveFileURL: URL {
            get throws {
                try XCTUnwrap(worktreeRootURL).appendingPathComponent(Self.liveRelativePath)
            }
        }

        func readFileAutoSelectionContextKey() throws -> MCPReadFileAutoSelectionCoordinator.ContextKey {
            let context = try XCTUnwrap(window.mcpServer.tabContextByConnectionID[Self.connectionID])
            return MCPReadFileAutoSelectionCoordinator.ContextKey(
                windowID: context.windowID,
                workspaceID: context.workspaceID,
                tabID: context.tabID,
                route: .bound(connectionID: Self.connectionID, runID: context.runID),
                bindingGeneration: context.readFileAutoSelectionGeneration
            )
        }

        func readFileAutoSelectionTarget() throws -> MCPServerViewModel.DebugReadFileAutoSelectionTarget {
            let targets = window.mcpServer.debugResolveReadFileAutoSelectionTargets(
                targetConnectionID: Self.connectionID,
                agentSessionID: nil,
                tabID: nil,
                expectedRunID: Self.runID
            )
            XCTAssertEqual(targets.count, 1)
            return try XCTUnwrap(targets.first)
        }

        func readFileAutoSelectionContextSnapshot() throws -> MCPReadFileAutoSelectionCoordinator.DebugContextSnapshot {
            let target = try readFileAutoSelectionTarget()
            return try XCTUnwrap(window.mcpServer.debugReadFileAutoSelectionContextSnapshot(for: target))
        }

        func readFileAutoSelectionCoverageCertificate() throws -> ReadFileAutoSelectionCoverageCertificate? {
            let target = try readFileAutoSelectionTarget()
            return window.mcpServer.debugReadFileAutoSelectionCoverageCertificate(for: target)
        }

        func replaceReadFileAutoSelectionCertificate(
            _ transform: (ReadFileAutoSelectionCoverageCertificate) -> ReadFileAutoSelectionCoverageCertificate
        ) throws {
            let key = try readFileAutoSelectionContextKey()
            let certificate = try XCTUnwrap(window.mcpServer.readFileAutoSelectionCoverageCertificates[key])
            window.mcpServer.readFileAutoSelectionCoverageCertificates[key] = transform(certificate)
        }

        func replaceWorktreeBindingCheckoutMetadata() throws {
            let current = try XCTUnwrap(worktreeBinding)
            let replacement = current.updatingCheckout(
                branch: "test/rebound-coverage-certificate",
                head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            )
            worktreeBinding = replacement
            installWorktreeBindingProvider(replacement)
            guard var context = window.mcpServer.tabContextByConnectionID[Self.connectionID] else {
                return XCTFail("Missing bound context")
            }
            context.worktreeBindingState = .hydrated([replacement])
            window.mcpServer.tabContextByConnectionID[Self.connectionID] = context
        }

        func rebindToReplacementPhysicalWorktree() async throws {
            if let worktreeRootURL {
                retiredWorktreeRootURLs.append(worktreeRootURL)
            }
            if let worktreeRootID {
                retiredWorktreeRootIDs.append(worktreeRootID)
            }

            let replacementRootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PersistentAgentModeMCPReadFileConnectionTests-Worktree-B", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let replacementFileURL = replacementRootURL.appendingPathComponent("Sources/PersistentAgentModeFixture.swift")
            let replacementLiveFileURL = replacementRootURL.appendingPathComponent(Self.liveRelativePath)
            let replacementWorktreeOnlyFileURL = replacementRootURL.appendingPathComponent(Self.worktreeOnlyRelativePath)
            try FileManager.default.createDirectory(
                at: replacementFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: replacementLiveFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: replacementWorktreeOnlyFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let liveContents = try Self.liveContents()
            try Self.replacementWorktreeSentinelContent.write(
                to: replacementFileURL,
                atomically: true,
                encoding: .utf8
            )
            try liveContents.worktree.write(to: replacementLiveFileURL, atomically: true, encoding: .utf8)
            try "let replacementWorktreeOnlySelection = true\n".write(
                to: replacementWorktreeOnlyFileURL,
                atomically: true,
                encoding: .utf8
            )
            let replacementRoot = try await window.workspaceFileContextStore.loadRoot(
                path: replacementRootURL.path,
                kind: .sessionWorktree
            )
            worktreeRootURL = replacementRootURL
            worktreeRootID = replacementRoot.id

            let replacementBinding = AgentSessionWorktreeBinding(
                id: "persistent-read-worktree-binding-b",
                repositoryID: "persistent-read-repository",
                repoKey: "persistent-read-repo-key",
                logicalRootPath: rootURL.path,
                logicalRootName: rootURL.lastPathComponent,
                worktreeID: "persistent-read-worktree-b",
                worktreeRootPath: replacementRootURL.path,
                worktreeName: replacementRootURL.lastPathComponent,
                branch: "test/replacement-physical-worktree",
                head: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                source: "test"
            )
            worktreeBinding = replacementBinding
            installWorktreeBindingProvider(replacementBinding)
            try rebindCurrentConnection()
        }

        func removeWorktreeDirectory() throws {
            let root = try XCTUnwrap(worktreeRootURL)
            try FileManager.default.removeItem(at: root)
        }

        func rebindCurrentConnection() throws {
            try window.mcpServer.bindTabForConnection(
                connectionID: Self.connectionID,
                clientName: AgentProviderKind.codexMCPClientID,
                tabID: Self.tabID,
                workspaceID: workspaceID,
                windowID: windowID,
                runID: Self.runID,
                explicitlyBound: false
            )
        }

        func installPeerWindowLookupSnapshot() async throws {
            routingGuardWindow.mcpServer.registerAgentWorktreeBindingsProvider { sessionID, tabID in
                guard sessionID == Self.agentSessionID, tabID == Self.tabID else { return .unavailable }
                return .hydrated([])
            }
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

            let root = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(in: routingGuardWindow, path: rootURL.path)
            peerRootID = root.id
            peerTargetStateVersionBeforeSelection = routingGuardWindow.workspaceManager
                .debugStateVersionForWorkspace(workspaceID)

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
            let replacementScheduleCountBefore = await networkManager.debugPendingPolicyReplacementScheduleCount(
                existing: Self.connectionID,
                replacement: Self.handoverConnectionID,
                runID: Self.runID
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
            XCTAssertEqual(replacementScheduleCount, replacementScheduleCountBefore + 1)
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
            window.beginClose()
            routingGuardWindow.beginClose()
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
            await window.tearDown()
            await routingGuardWindow.tearDown()
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
            for retiredWorktreeRootID in retiredWorktreeRootIDs {
                await window.workspaceFileContextStore.unloadRoot(id: retiredWorktreeRootID)
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
            for retiredWorktreeRootURL in retiredWorktreeRootURLs {
                try? FileManager.default.removeItem(at: retiredWorktreeRootURL)
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
        case presentationStateMismatch(String)
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
