import Foundation
import MCP
@testable import RepoPrompt
import XCTest

#if DEBUG
    @MainActor
    final class MCPAskOracleWorktreeTests: XCTestCase {
        func testExplicitWindowProvenanceEndsBeforePostProviderHooks() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                try await activateWorkspace(fixture.contextA)
                fixture.contextA.window.mcpServer.windowToolsEnabled = true
                WindowStatesManager.shared.registerWindowState(fixture.contextA.window)
                let manager = fixture.networkManager
                let capture = ExplicitWindowRoutingHintCapture()
                let endpoint = try fixture.endpointA()
                let endpointConnectionID = endpoint.connectionID
                try await configureAgentModeEndpoint(
                    endpoint,
                    context: makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(
                            selectedPaths: [fixture.contextA.fileURL.path],
                            codemapAutoEnabled: false
                        ),
                        bindings: []
                    ),
                    fixture: fixture
                )
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                    .object(["ok": .bool(true)])
                }
                await manager.debugSetBeforeToolResultFormattingForTesting { connectionID, toolName in
                    guard connectionID == endpointConnectionID,
                          toolName == MCPWindowToolName.readFile
                    else { return }
                    await capture.record(ServerNetworkManager.currentExplicitWindowRoutingHint)
                }

                do {
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString,
                            "_windowID": fixture.contextA.window.windowID
                        ],
                        timeoutSeconds: 30
                    )

                    let hints = await capture.snapshot()
                    XCTAssertEqual(hints.count, 1)
                    XCTAssertNil(hints.first.flatMap(\.self))

                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    WindowStatesManager.shared.unregisterWindowState(fixture.contextA.window)
                    await fixture.cleanup()
                } catch {
                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    WindowStatesManager.shared.unregisterWindowState(fixture.contextA.window)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testOracleSendContextKeepsConversationOwnerSeparateFromDelegatedPackagingSource() throws {
            let childTabID = UUID()
            let childWorkspaceID = UUID()
            let childSessionID = UUID()
            let childRunID = UUID()
            let sourceTabID = UUID()
            let sourceSessionID = UUID()
            let sourceRunID = UUID()
            let delegationID = UUID()
            let sourceSelection = StoredSelection(
                selectedPaths: ["/tmp/source/Sources/Feature.swift"],
                codemapAutoEnabled: false
            )
            let sourceCapability = SelectedGitArtifactCapability(
                workspaceID: childWorkspaceID,
                workspaceDirectoryPath: "/tmp/workspace",
                gitDataRoot: WorkspaceRootRef(
                    id: UUID(),
                    name: "_git_data",
                    fullPath: "/tmp/workspace/_git_data"
                ),
                creatorTabID: sourceTabID,
                sessionID: sourceSessionID,
                boundCheckouts: [],
                canonicalWorkspaceRootPaths: ["/tmp/source"]
            )
            let sourceReviewContext = FrozenPromptGitReviewContext(
                artifactCapability: sourceCapability,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            )
            let capturedSource = AgentRunOracleReviewSource.Captured(
                delegationID: delegationID,
                sourceTabID: sourceTabID,
                workspaceID: childWorkspaceID,
                sourceSelectionRevision: 42,
                promptText: "source prompt",
                selection: sourceSelection,
                lookupContext: .visibleWorkspace,
                reviewGitContext: sourceReviewContext,
                sourceAgentSessionID: sourceSessionID,
                sourceAgentRunID: sourceRunID,
                sourceWorktreeBindings: []
            )
            let delegated = DelegatedAgentRunOracleReviewContext(
                source: .captured(capturedSource),
                target: AgentRunOracleReviewTargetSnapshot(
                    tabID: childTabID,
                    workspaceID: childWorkspaceID,
                    agentSessionID: childSessionID,
                    activationID: UUID(),
                    expectedParentSessionID: sourceSessionID,
                    worktreeBindings: [],
                    validationFailure: nil
                ),
                targetRunID: childRunID
            )
            let packaging = try OracleViewModel.OracleSendPackagingContext(delegated: delegated)
            let context = OracleViewModel.OracleSendTabContext(
                tabID: childTabID,
                workspaceID: childWorkspaceID,
                origin: .askOracle,
                agentModeSessionID: childSessionID,
                agentModeRunID: childRunID,
                packaging: packaging
            )

            XCTAssertEqual(context.tabID, childTabID)
            XCTAssertEqual(context.agentModeSessionID, childSessionID)
            XCTAssertEqual(context.agentModeRunID, childRunID)
            XCTAssertEqual(context.packaging.sourceTabID, sourceTabID)
            XCTAssertEqual(context.packaging.sourceAgentSessionID, sourceSessionID)
            XCTAssertEqual(context.packaging.sourceAgentRunID, sourceRunID)
            XCTAssertEqual(context.packaging.selection, sourceSelection)
            XCTAssertEqual(
                context.packaging.provenance,
                .delegated(delegationID: delegationID)
            )
            guard case let .delegated(artifactDelegation) = try XCTUnwrap(
                context.packaging.reviewGitContext.artifactCapability
            ).access else {
                return XCTFail("Expected delegated artifact capability")
            }
            XCTAssertEqual(artifactDelegation.sourceTabID, sourceTabID)
            XCTAssertEqual(artifactDelegation.targetTabID, childTabID)
            XCTAssertEqual(artifactDelegation.targetAgentSessionID, childSessionID)
            XCTAssertEqual(artifactDelegation.targetAgentRunID, childRunID)
            XCTAssertEqual(
                context.packaging.reviewGitContext.artifactDelegationConsumer,
                SelectedGitArtifactDelegationConsumer(
                    workspaceID: childWorkspaceID,
                    tabID: childTabID,
                    agentSessionID: childSessionID,
                    agentRunID: childRunID,
                    boundCheckouts: []
                )
            )
        }

        func testExplicitOracleContinuationRequiresExactAgentSessionAndRunOwner() {
            let tabID = UUID()
            let sessionID = UUID()
            let runID = UUID()
            let owned = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID
            )
            let unownedLegacy = ChatSession(composeTabID: tabID)

            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: UUID()
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: UUID(),
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    unownedLegacy,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: nil,
                    agentModeRunID: nil
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: nil
                )
            )
            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    unownedLegacy,
                    agentModeSessionID: nil,
                    agentModeRunID: nil
                )
            )
        }

        func testOracleLogLookupDoesNotAdoptLegacyOrSiblingRun() {
            let tabID = UUID()
            let sessionID = UUID()
            let runID = UUID()
            let exact = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID,
                savedAt: Date(timeIntervalSince1970: 1)
            )
            let newerSibling = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: UUID(),
                savedAt: Date(timeIntervalSince1970: 3)
            )
            let newestLegacy = ChatSession(
                composeTabID: tabID,
                savedAt: Date(timeIntervalSince1970: 4)
            )

            XCTAssertEqual(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [newestLegacy, newerSibling, exact],
                    activeSessionID: newestLegacy.id,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )?.id,
                exact.id
            )
            XCTAssertNil(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [newestLegacy, newerSibling],
                    activeSessionID: newestLegacy.id,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
        }

        func testAskOracleWaitsForReadAutoSelectionAndPackagesWorktreeContent() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gate = OracleWorktreeGate()
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let logicalFile = fixture.contextA.fileURL
                    let worktreeRoot = try makeTemporaryRoot(name: "OracleDrainWorktree")
                    let worktreeFile = worktreeRoot
                        .appendingPathComponent("Sources", isDirectory: true)
                        .appendingPathComponent(logicalFile.lastPathComponent)
                    let canonicalSentinel = "canonical_oracle_drain_content"
                    let worktreeSentinel = "worktree_oracle_drain_content"
                    try write("let value = \"\(canonicalSentinel)\"\n", to: logicalFile)
                    try write("let value = \"\(worktreeSentinel)\"\n", to: worktreeFile)

                    let binding = makeBinding(
                        logicalRoot: fixture.contextA.rootURL,
                        worktreeRoot: worktreeRoot,
                        suffix: "drain"
                    )
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(),
                        bindings: [binding]
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)
                    installOracleCapture(capture, on: fixture.contextA.window)
                    fixture.contextA.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                        await gate.markStartedAndWaitForRelease()
                    }

                    let readTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": logicalFile.path],
                            timeoutSeconds: 5
                        )
                    }
                    guard await gate.waitUntilStarted() else {
                        readTask.cancel()
                        let diagnostic: String
                        do {
                            diagnostic = try await readTask.value.rawJSON
                        } catch {
                            diagnostic = String(describing: error)
                        }
                        throw OracleWorktreeTestError.autoSelectionDidNotStart(readDiagnostic: diagnostic)
                    }
                    let readResponse = try await readTask.value
                    XCTAssertTrue(try toolResultText(readResponse).contains(worktreeSentinel))

                    let askTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.askOracle,
                            arguments: ["message": "Explain the selected implementation."],
                            timeoutSeconds: 30
                        )
                    }
                    let drainWaiterRegistered = await waitUntil {
                        fixture.contextA.window.mcpServer
                            .readFileAutoSelectionDiagnosticsSnapshot().canonicalWaiterCount == 1
                    }
                    XCTAssertTrue(drainWaiterRegistered)
                    XCTAssertFalse(capture.wasInvoked)

                    await gate.release()
                    let askResponse = try await askTask.value
                    XCTAssertTrue(try toolResultText(askResponse).contains("captured oracle response"))
                    XCTAssertTrue(capture.wasInvoked)
                    let tabContext = try XCTUnwrap(capture.tabContext)
                    XCTAssertEqual(tabContext.packaging.selection.selectedPaths, [logicalFile.path])
                    let packaged = capture.fileBlocks.joined(separator: "\n")
                    XCTAssertTrue(packaged.contains(worktreeSentinel), packaged)
                    XCTAssertFalse(packaged.contains(canonicalSentinel), packaged)
                    XCTAssertFalse(packaged.contains(worktreeRoot.path), packaged)
                    XCTAssertFalse(capture.fileTree.contains(worktreeRoot.path), capture.fileTree)

                    fixture.contextA.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    await gate.release()
                    fixture.contextA.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOraclePackagesMultipleBoundRootsWithoutCanonicalLeak() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let gitFixture = try ReviewGitRepositoryFixture(name: "OracleMultiRoot")
                    let logicalRootA = try gitFixture.makeRepository(
                        named: "logical-a",
                        files: ["Sources/First.swift": "let value = \"initial_a\"\n"]
                    )
                    let logicalRootB = try gitFixture.makeRepository(
                        named: "logical-b",
                        files: ["Sources/Second.swift": "let value = \"initial_b\"\n"]
                    )
                    let logicalFileA = logicalRootA.appendingPathComponent("Sources/First.swift")
                    let logicalFileB = logicalRootB.appendingPathComponent("Sources/Second.swift")
                    let worktreeRootA = try gitFixture.makeLinkedWorktree(
                        from: logicalRootA,
                        named: "worktree-a",
                        branch: "feature/oracle-a"
                    )
                    let worktreeRootB = try gitFixture.makeLinkedWorktree(
                        from: logicalRootB,
                        named: "worktree-b",
                        branch: "feature/oracle-b"
                    )
                    let worktreeFileA = worktreeRootA.appendingPathComponent("Sources/First.swift")
                    let worktreeFileB = worktreeRootB.appendingPathComponent("Sources/Second.swift")

                    try write("let value = \"canonical_oracle_a\"\n", to: logicalFileA)
                    try write("let value = \"canonical_oracle_b\"\n", to: logicalFileB)
                    try write("let value = \"worktree_oracle_a\"\n", to: worktreeFileA)
                    try write("let value = \"worktree_oracle_b\"\n", to: worktreeFileB)
                    _ = try await fixture.contextA.window.workspaceFileContextStore.loadRoot(path: logicalRootA.path)
                    _ = try await fixture.contextA.window.workspaceFileContextStore.loadRoot(path: logicalRootB.path)

                    let bindings = [
                        makeBinding(logicalRoot: logicalRootA, worktreeRoot: worktreeRootA, suffix: "multi-a"),
                        makeBinding(logicalRoot: logicalRootB, worktreeRoot: worktreeRootB, suffix: "multi-b")
                    ]
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(
                            selectedPaths: [logicalFileA.path, logicalFileB.path],
                            codemapAutoEnabled: false
                        ),
                        bindings: bindings
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)
                    installOracleCapture(capture, on: fixture.contextA.window, gitInclusion: .selected)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Compare both selected roots.", "mode": "review"],
                        timeoutSeconds: 30
                    )
                    XCTAssertTrue(try toolResultText(response).contains("captured oracle response"))

                    let packaged = capture.fileBlocks.joined(separator: "\n")
                    XCTAssertTrue(packaged.contains("worktree_oracle_a"), packaged)
                    XCTAssertTrue(packaged.contains("worktree_oracle_b"), packaged)
                    XCTAssertFalse(packaged.contains("canonical_oracle_a"), packaged)
                    XCTAssertFalse(packaged.contains("canonical_oracle_b"), packaged)
                    XCTAssertFalse(packaged.contains(worktreeRootA.path), packaged)
                    XCTAssertFalse(packaged.contains(worktreeRootB.path), packaged)
                    XCTAssertEqual(capture.tabContext?.packaging.lookupContext?.bindingProjection?.boundRootsForMetadata.count, 2)
                    let gitDiff = try XCTUnwrap(capture.gitDiff)
                    XCTAssertTrue(gitDiff.contains("worktree_oracle_a"), gitDiff)
                    XCTAssertTrue(gitDiff.contains("worktree_oracle_b"), gitDiff)
                    XCTAssertFalse(gitDiff.contains("canonical_oracle_a"), gitDiff)
                    XCTAssertFalse(gitDiff.contains("canonical_oracle_b"), gitDiff)
                    XCTAssertFalse(gitDiff.contains(worktreeRootA.path), gitDiff)
                    XCTAssertFalse(gitDiff.contains(worktreeRootB.path), gitDiff)

                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testGitDiffSelectedArtifactsAutoSelectPatchForBoundLinkedWorktreeWithoutSessionRootCatalog() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gitFixture = try ReviewGitRepositoryFixture(name: "OracleSelectedArtifactNoCatalog")
                defer { gitFixture.cleanup() }
                do {
                    try await activateWorkspace(fixture.contextA)
                    let logicalRoot = try gitFixture.makeRepository(
                        named: "logical",
                        files: ["Sources/Feature.swift": "let value = \"initial\"\n"]
                    )
                    let worktreeRoot = try gitFixture.makeLinkedWorktree(
                        from: logicalRoot,
                        named: "worktree",
                        branch: "feature/artifact-no-catalog"
                    )
                    let logicalFile = logicalRoot.appendingPathComponent("Sources/Feature.swift")
                    let worktreeFile = worktreeRoot.appendingPathComponent("Sources/Feature.swift")
                    try write("let value = \"canonical_artifact_leak\"\n", to: logicalFile)
                    try write("let value = \"linked_artifact_source\"\n", to: worktreeFile)
                    _ = try await fixture.contextA.window.workspaceFileContextStore.loadRoot(
                        path: logicalRoot.path,
                        kind: .primaryWorkspace
                    )
                    let layout = try XCTUnwrap(
                        GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: worktreeRoot)
                    )
                    let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
                        commonGitDir: layout.commonDir,
                        mainWorktreeRoot: layout.knownMainWorktreeRoot
                    )
                    let worktreeID = GitWorktreeIdentity.worktreeID(
                        repositoryID: repositoryIdentity.repositoryID,
                        gitDir: layout.gitDir,
                        isMain: false,
                        path: layout.workTreeRoot
                    )
                    let binding = AgentSessionWorktreeBinding(
                        id: "binding-artifact-no-catalog",
                        repositoryID: repositoryIdentity.repositoryID,
                        repoKey: GitRepoDescriptor(rootURL: logicalRoot).repoKey,
                        logicalRootPath: logicalRoot.path,
                        logicalRootName: "ArtifactNoCatalogRepo",
                        worktreeID: worktreeID,
                        worktreeRootPath: worktreeRoot.path,
                        worktreeName: "worktree",
                        branch: "feature/artifact-no-catalog",
                        source: "test"
                    )

                    let sourceSelection = StoredSelection(
                        selectedPaths: [logicalFile.path],
                        codemapAutoEnabled: false
                    )
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: sourceSelection,
                        bindings: [binding]
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)

                    let gitResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.git,
                        arguments: [
                            "op": "diff",
                            "repo_root": logicalRoot.path,
                            "scope": "selected",
                            "detail": "patches",
                            "artifacts": true,
                            "mode": "deep"
                        ],
                        timeoutSeconds: 30
                    )
                    XCTAssertFalse(gitResponse.rawJSON.contains("\"isError\":true"), gitResponse.rawJSON)
                    let gitText = try toolResultText(gitResponse)
                    let publishedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    ).selection
                    XCTAssertTrue(publishedSelection.selectedPaths.contains(logicalFile.path))
                    _ = try requireSelectedPath(
                        suffix: "/MAP.txt",
                        in: publishedSelection,
                        context: "selected linked-worktree artifact publication without session root catalog",
                        toolOutput: gitText
                    )
                    let patchPath = try requireSelectedPath(
                        suffix: "/diff/all.patch",
                        in: publishedSelection,
                        context: "selected linked-worktree artifact publication without session root catalog",
                        toolOutput: gitText
                    )
                    let patchText = try String(contentsOfFile: patchPath, encoding: .utf8)
                    XCTAssertTrue(patchText.contains("linked_artifact_source"), patchText)
                    XCTAssertFalse(patchText.contains("canonical_artifact_leak"), patchText)

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleReviewUsesAuthorizedSelectedArtifactAndKeepsMapAsContext() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let gitFixture = try ReviewGitRepositoryFixture(name: "OracleSelectedArtifact")
                    let logicalRoot = try gitFixture.makeRepository(
                        named: "logical",
                        files: ["Sources/Feature.swift": "let value = \"initial\"\n"]
                    )
                    let worktreeRoot = try gitFixture.makeLinkedWorktree(
                        from: logicalRoot,
                        named: "worktree",
                        branch: "feature/artifact"
                    )
                    let logicalFile = logicalRoot.appendingPathComponent("Sources/Feature.swift")
                    let worktreeFile = worktreeRoot.appendingPathComponent("Sources/Feature.swift")
                    try write("let value = \"canonical_artifact_leak\"\n", to: logicalFile)
                    try write("let value = \"worktree_artifact_source\"\n", to: worktreeFile)
                    _ = try await fixture.contextA.window.workspaceFileContextStore.loadRoot(path: logicalRoot.path)

                    let layout = try XCTUnwrap(
                        GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: worktreeRoot)
                    )
                    let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
                        commonGitDir: layout.commonDir,
                        mainWorktreeRoot: layout.knownMainWorktreeRoot
                    )
                    let worktreeID = GitWorktreeIdentity.worktreeID(
                        repositoryID: repositoryIdentity.repositoryID,
                        gitDir: layout.gitDir,
                        isMain: false,
                        path: layout.workTreeRoot
                    )
                    let binding = AgentSessionWorktreeBinding(
                        id: "binding-artifact",
                        repositoryID: repositoryIdentity.repositoryID,
                        repoKey: "artifact-repo",
                        logicalRootPath: logicalRoot.path,
                        logicalRootName: "ArtifactRepo",
                        worktreeID: worktreeID,
                        worktreeRootPath: worktreeRoot.path,
                        worktreeName: "artifact",
                        branch: "feature/artifact",
                        source: "test"
                    )

                    let sourceSelection = StoredSelection(
                        selectedPaths: [logicalFile.path],
                        codemapAutoEnabled: false
                    )
                    var composeTab = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    )
                    composeTab.selection = sourceSelection
                    fixture.contextA.window.workspaceManager.updateComposeTab(composeTab, markDirty: false)

                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: sourceSelection,
                        bindings: [binding]
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)

                    let gitResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.git,
                        arguments: [
                            "op": "diff",
                            "repo_root": logicalRoot.path,
                            "scope": "selected",
                            "detail": "patches",
                            "artifacts": true,
                            "mode": "deep"
                        ],
                        timeoutSeconds: 30
                    )
                    let gitText = try toolResultText(gitResponse)
                    XCTAssertTrue(gitText.contains("auto-selected"), gitText)

                    let publishedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    ).selection
                    let mapPath = try requireSelectedPath(
                        suffix: "/MAP.txt",
                        in: publishedSelection,
                        context: "selected-artifact publication",
                        toolOutput: gitText
                    )
                    let patchPath = try requireSelectedPath(
                        suffix: "/diff/all.patch",
                        in: publishedSelection,
                        context: "selected-artifact publication",
                        toolOutput: gitText
                    )
                    XCTAssertTrue(publishedSelection.selectedPaths.contains(logicalFile.path))
                    let patchText = try String(contentsOfFile: patchPath, encoding: .utf8)
                    let patchAlias = try XCTUnwrap(
                        patchPath.range(of: "/_git_data/").map {
                            "_git_data/" + patchPath[$0.upperBound...]
                        }
                    )
                    let mapAlias = try XCTUnwrap(
                        mapPath.range(of: "/_git_data/").map {
                            "_git_data/" + mapPath[$0.upperBound...]
                        }
                    )
                    let previewResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "preview",
                            "paths": [mapAlias, patchAlias],
                            "strict": true,
                            "view": "files"
                        ],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(previewResponse.rawJSON.contains("MAP.txt"))
                    XCTAssertTrue(previewResponse.rawJSON.contains("all.patch"))

                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "remove",
                            "paths": [mapAlias, patchAlias],
                            "strict": true,
                            "view": "files"
                        ],
                        timeoutSeconds: 20
                    )
                    let removedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(
                            with: fixture.contextA.tabID
                        )
                    ).selection
                    XCTAssertEqual(removedSelection.selectedPaths, [logicalFile.path])

                    let readdedResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "set",
                            "paths": [logicalFile.path, mapAlias, patchAlias],
                            "strict": true,
                            "view": "files"
                        ],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(readdedResponse.rawJSON.contains("MAP.txt"))
                    XCTAssertTrue(readdedResponse.rawJSON.contains("all.patch"))
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "add",
                            "paths": [patchAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    let readdedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(
                            with: fixture.contextA.tabID
                        )
                    ).selection
                    XCTAssertEqual(
                        readdedSelection.selectedPaths.count { $0 == patchPath },
                        1
                    )
                    XCTAssertTrue(readdedSelection.selectedPaths.contains(logicalFile.path))
                    let manifestPath = String(
                        patchPath.dropLast("diff/all.patch".count)
                    ) + "manifest.json"
                    let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let manifest = try decoder.decode(
                        GitDiffSnapshotManifest.self,
                        from: manifestData
                    )
                    let perFileRelativePath = try XCTUnwrap(
                        manifest.files.compactMap(\.patchPath).first
                    )
                    let perFileAlias = String(
                        patchAlias.dropLast("diff/all.patch".count)
                    ) + perFileRelativePath
                    let perFileAbsolutePath = String(
                        patchPath.dropLast("diff/all.patch".count)
                    ) + perFileRelativePath
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "add",
                            "paths": [perFileAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(
                        try XCTUnwrap(
                            fixture.contextA.window.workspaceManager.composeTab(
                                with: fixture.contextA.tabID
                            )
                        ).selection.selectedPaths.contains(perFileAbsolutePath)
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "remove",
                            "paths": [perFileAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    let lookupContext = try await AgentWorkspaceLookupContextResolver
                        .requiredLookupContext(
                            source: AgentWorkspaceLookupContextSource(
                                activeAgentSessionID: context.activeAgentSessionID,
                                worktreeBindings: [binding]
                            ),
                            store: fixture.contextA.window.workspaceFileContextStore
                        )
                    let reviewGitContext = await fixture.contextA.window.promptManager
                        .freezePromptGitReviewContext(
                            workspaceID: context.workspaceID,
                            tabID: context.tabID,
                            sessionID: context.activeAgentSessionID,
                            bindings: [binding],
                            base: "HEAD"
                        )
                    var replyContext = context
                    replyContext.selection = publishedSelection
                    let selectionReply = await fixture.contextA.window.mcpServer
                        .buildTabSelectionReply(
                            from: publishedSelection,
                            includeBlocks: true,
                            display: .full,
                            virtualContext: replyContext,
                            lookupContextOverride: lookupContext,
                            reviewGitContextOverride: reviewGitContext
                        )
                    XCTAssertTrue(selectionReply.files?.contains { $0.path == mapAlias } == true)
                    XCTAssertTrue(selectionReply.files?.contains { $0.path == patchAlias } == true)
                    XCTAssertNil(selectionReply.invalidPaths)
                    XCTAssertEqual(
                        selectionReply.blocks?.count(where: { $0.contains(mapAlias) }),
                        1
                    )
                    XCTAssertFalse(
                        selectionReply.blocks?.contains {
                            $0.contains("<path>\(patchAlias)</path>")
                        } ?? true
                    )

                    let readResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: ["path": patchAlias],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(try toolResultText(readResponse).contains("worktree_artifact_source"))

                    let manifestAlias = String(
                        patchAlias.dropLast("diff/all.patch".count)
                    ) + "manifest.json"
                    let rejectedMutation = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "add",
                            "paths": [manifestAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(rejectedMutation.rawJSON.contains("\"isError\":true"))
                    let rejectedRead = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: ["path": manifestAlias],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(rejectedRead.rawJSON.contains("\"isError\":true"))
                    XCTAssertTrue(
                        rejectedRead.rawJSON.contains("Cannot read")
                            || rejectedRead.rawJSON.contains("File not found"),
                        rejectedRead.rawJSON
                    )
                    let searchResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.search,
                        arguments: ["pattern": "all.patch", "mode": "path", "regex": false],
                        timeoutSeconds: 20
                    )
                    XCTAssertFalse(try toolResultText(searchResponse).contains(patchAlias))
                    let treeResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.getFileTree,
                        arguments: ["mode": "full"],
                        timeoutSeconds: 20
                    )
                    XCTAssertFalse(try toolResultText(treeResponse).contains("_git_data"))

                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting { _ in
                            AutomaticReviewGitDiffResult(
                                text: "AUTOMATIC_FALLBACK_INVOKED",
                                completeness: .complete,
                                outcomes: [],
                                pathIssues: []
                            )
                        }
                    installOracleCapture(capture, on: fixture.contextA.window, gitInclusion: .selected)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Review the selected artifact.", "mode": "review"],
                        timeoutSeconds: 30
                    )
                    XCTAssertTrue(try toolResultText(response).contains("captured oracle response"))
                    XCTAssertEqual(capture.gitDiff, patchText)
                    XCTAssertNotEqual(capture.gitDiff, "AUTOMATIC_FALLBACK_INVOKED")
                    let packaged = capture.fileBlocks.joined(separator: "\n")
                    XCTAssertTrue(packaged.contains("worktree_artifact_source"), packaged)
                    XCTAssertFalse(packaged.contains("canonical_artifact_leak"), packaged)
                    XCTAssertEqual(
                        capture.fileBlocks.count(where: { $0.contains(mapAlias) }),
                        1,
                        packaged
                    )
                    XCTAssertFalse(capture.fileBlocks.contains { $0.contains(patchAlias) }, packaged)

                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleReviewUsesPublishedCanonicalArtifactWithoutAutomaticFallback() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let repository = fixture.contextA.rootURL
                    let sourceFile = fixture.contextA.fileURL
                    let gitFixture = try ReviewGitRepositoryFixture(name: "OracleCanonicalArtifact")
                    defer { gitFixture.cleanup() }
                    _ = try gitFixture.runGit(["init"], at: repository)
                    _ = try gitFixture.runGit(["config", "user.name", "RepoPrompt Test"], at: repository)
                    _ = try gitFixture.runGit(["config", "user.email", "repoprompt@example.test"], at: repository)
                    _ = try gitFixture.runGit(["config", "commit.gpgSign", "false"], at: repository)
                    _ = try gitFixture.runGit(["add", "."], at: repository)
                    _ = try gitFixture.runGit(["commit", "-m", "Initial commit"], at: repository)
                    try write("let canonicalPublishedArtifact = true\n", to: sourceFile)

                    let sourceSelection = StoredSelection(
                        selectedPaths: [sourceFile.path],
                        codemapAutoEnabled: false
                    )
                    var composeTab = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    )
                    composeTab.selection = sourceSelection
                    fixture.contextA.window.workspaceManager.updateComposeTab(composeTab, markDirty: false)

                    let context = MCPServerViewModel.TabContextSnapshot(
                        tabID: fixture.contextA.tabID,
                        windowID: fixture.contextA.window.windowID,
                        workspaceID: fixture.contextA.workspaceID,
                        promptText: "Review canonical publication",
                        selection: sourceSelection,
                        selectedMetaPromptIDs: [],
                        tabName: "Canonical Oracle",
                        runID: UUID(),
                        activeAgentSessionID: nil,
                        worktreeBindingState: .notApplicable,
                        explicitlyBound: false
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)

                    let gitResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.git,
                        arguments: [
                            "op": "diff",
                            "repo_root": repository.path,
                            "scope": "selected",
                            "detail": "patches",
                            "artifacts": true,
                            "mode": "deep"
                        ],
                        timeoutSeconds: 30
                    )
                    let gitText = try toolResultText(gitResponse)

                    let publishedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    ).selection
                    let mapPath = try requireSelectedPath(
                        suffix: "/MAP.txt",
                        in: publishedSelection,
                        context: "canonical-artifact publication",
                        toolOutput: gitText
                    )
                    let patchPath = try requireSelectedPath(
                        suffix: "/diff/all.patch",
                        in: publishedSelection,
                        context: "canonical-artifact publication",
                        toolOutput: gitText
                    )
                    XCTAssertTrue(publishedSelection.selectedPaths.contains(sourceFile.path))
                    let patchText = try String(contentsOfFile: patchPath, encoding: .utf8)
                    let mapAlias = try XCTUnwrap(
                        mapPath.range(of: "/_git_data/").map {
                            "_git_data/" + mapPath[$0.upperBound...]
                        }
                    )
                    let patchAlias = try XCTUnwrap(
                        patchPath.range(of: "/_git_data/").map {
                            "_git_data/" + patchPath[$0.upperBound...]
                        }
                    )

                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "remove",
                            "paths": [mapAlias, patchAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "add",
                            "paths": [mapAlias, patchAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    let roundTrippedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(
                            with: fixture.contextA.tabID
                        )
                    ).selection
                    XCTAssertTrue(roundTrippedSelection.selectedPaths.contains(sourceFile.path))
                    XCTAssertEqual(roundTrippedSelection.selectedPaths.count { $0 == mapPath }, 1)
                    XCTAssertEqual(roundTrippedSelection.selectedPaths.count { $0 == patchPath }, 1)

                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting { _ in
                            AutomaticReviewGitDiffResult(
                                text: "AUTOMATIC_FALLBACK_INVOKED",
                                completeness: .complete,
                                outcomes: [],
                                pathIssues: []
                            )
                        }
                    installOracleCapture(capture, on: fixture.contextA.window, gitInclusion: .selected)

                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Review canonical artifacts.", "mode": "review"],
                        timeoutSeconds: 30
                    )
                    XCTAssertEqual(capture.gitDiff, patchText)
                    XCTAssertNotEqual(capture.gitDiff, "AUTOMATIC_FALLBACK_INVOKED")
                    XCTAssertTrue(capture.fileBlocks.joined().contains("canonicalPublishedArtifact"))
                    XCTAssertEqual(
                        capture.fileBlocks.count(where: { $0.contains(mapAlias) }),
                        1
                    )
                    XCTAssertFalse(
                        capture.fileBlocks.contains { $0.contains("<path>\(patchAlias)</path>") }
                    )

                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testOracleReviewTransportUsesPublishedCanonicalPatchForFreshAndContinuingChat() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(repositoryKind: .canonical)
        }

        func testOracleReviewTransportUsesPublishedLinkedWorktreePatchForFreshAndContinuingChat() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(repositoryKind: .linkedWorktree)
        }

        func testAgentRunCanonicalFreshAndContinuingOracleInheritsLaunchArtifact() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(
                repositoryKind: .canonical,
                delegateToChildRun: true
            )
        }

        func testAgentRunCanonicalSourceDelegatesArtifactToFreshAppManagedWorktreeChild() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(
                repositoryKind: .canonical,
                delegateToChildRun: true,
                childCreateWorktree: true
            )
        }

        func testAgentRunLinkedWorktreeFreshAndContinuingOracleInheritsLaunchArtifact() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(
                repositoryKind: .linkedWorktree,
                delegateToChildRun: true
            )
        }

        func testAgentRunLinkedWorktreeSourceDelegatesArtifactToExplicitlyUnboundChild() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(
                repositoryKind: .linkedWorktree,
                delegateToChildRun: true,
                childInheritWorktreeBindings: false
            )
        }

        func testVisibleLinkedWorktreeOracleUsesPublishedPatchForFreshAndContinuingChat() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(
                repositoryKind: .visibleLinkedWorktree
            )
        }

        func testAgentRunVisibleLinkedWorktreeFreshAndContinuingOracleInheritsLaunchArtifact() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(
                repositoryKind: .visibleLinkedWorktree,
                delegateToChildRun: true
            )
        }

        func testAgentRunWindowOnlyNoArtifactUsesAutomaticFallbackAcrossSelectedRepositories() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gitFixture = try ReviewGitRepositoryFixture(name: "AgentRunAutomaticFallback")
                let capture = OracleWorktreeCapture()
                let automaticProviderCounter = OracleAutomaticProviderCounter()
                let window = fixture.contextA.window
                let apiSettings = try XCTUnwrap(window.promptManager.apiSettingsViewModel)
                let previousClaudeCodeConnected = apiSettings.isClaudeCodeConnected
                defer {
                    window.promptManager.setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    window.mcpServer.setAgentRunDispatchOverrideForTesting(nil)
                    window.mcpServer.setRequestMetadataOverrideForTesting(nil)
                    apiSettings.isClaudeCodeConnected = previousClaudeCodeConnected
                    gitFixture.cleanup()
                }

                do {
                    try await activateWorkspace(fixture.contextA)
                    let secondaryRoot = try gitFixture.makeRepository(
                        named: "secondary",
                        files: ["Sources/Secondary.swift": "let secondary = 1\n"]
                    )
                    let secondaryFile = secondaryRoot.appendingPathComponent("Sources/Secondary.swift")
                    try await window.workspaceManager.addFolder(
                        secondaryRoot,
                        to: XCTUnwrap(window.workspaceManager.activeWorkspace)
                    )
                    let sourceSelection = StoredSelection(
                        selectedPaths: [fixture.contextA.fileURL.path, secondaryFile.path],
                        codemapAutoEnabled: false
                    )
                    _ = await window.selectionCoordinator.persistActiveSelection(
                        sourceSelection,
                        source: .runtimeMutation,
                        mirrorToUI: true
                    )
                    let committedSource = try XCTUnwrap(
                        window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    )
                    XCTAssertTrue(
                        Set(committedSource.selection.selectedPaths).isSuperset(
                            of: sourceSelection.selectedPaths
                        )
                    )
                    XCTAssertFalse(committedSource.selection.selectedPaths.contains {
                        $0.contains("/_git_data/")
                    })

                    let startConnectionID = UUID()
                    window.mcpServer.setRequestMetadataOverrideForTesting(.init(
                        connectionID: startConnectionID,
                        clientName: "public-agent-run-automatic-fallback",
                        windowID: window.windowID,
                        runPurpose: .unknown,
                        explicitWindowRoutingHint: MCPExplicitWindowRoutingHint(
                            connectionID: startConnectionID,
                            toolName: "agent_run",
                            windowID: window.windowID,
                            windowStateIdentity: ObjectIdentifier(window),
                            serverViewModelIdentity: ObjectIdentifier(window.mcpServer),
                            provenance: .hiddenWindowArgument
                        )
                    ))
                    XCTAssertEqual(
                        window.mcpServer.connectionBindingSnapshot(forConnection: startConnectionID).bindingKind,
                        .unbound
                    )
                    var targetRunID: UUID?
                    window.mcpServer.setAgentRunDispatchOverrideForTesting {
                        _, tabID, _, _, viewModel in
                        let runID = UUID()
                        targetRunID = runID
                        let session = viewModel.session(for: tabID)
                        session.runID = runID
                        session.runState = .running
                        guard viewModel.mcpBindPendingAgentRunOracleReviewContext(
                            tabID: tabID,
                            runID: runID
                        ) != nil else {
                            throw MCPError.internalError(
                                "Automatic fallback child did not promote its launch carrier."
                            )
                        }
                        return .startedRun
                    }
                    apiSettings.isClaudeCodeConnected = true
                    let startValue = try await window.mcpServer.executeAgentRunForTesting(args: [
                        "op": .string("start"),
                        "message": .string("Start automatic fallback child."),
                        "model_id": .string("claudeCode:sonnet"),
                        "detach": .bool(true),
                        "timeout": .int(0)
                    ])
                    let startObject = try XCTUnwrap(startValue.objectValue)
                    let startSession = try XCTUnwrap(startObject["session"]?.objectValue)
                    let targetSessionID = try XCTUnwrap(
                        startObject["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                    )
                    let targetTabID = try XCTUnwrap(
                        startSession["context_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                    )
                    let resolvedTargetRunID = try XCTUnwrap(targetRunID)
                    XCTAssertNil(startSession["parent_session_id"])
                    XCTAssertTrue(
                        try XCTUnwrap(window.workspaceManager.composeTab(with: targetTabID))
                            .selection.selectedPaths.isEmpty
                    )

                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: MCPServerViewModel.TabContextSnapshot(
                            tabID: targetTabID,
                            windowID: window.windowID,
                            workspaceID: fixture.contextA.workspaceID,
                            promptText: "Blank child",
                            selection: StoredSelection(codemapAutoEnabled: false),
                            selectedMetaPromptIDs: [],
                            tabName: "Automatic fallback child",
                            runID: resolvedTargetRunID,
                            activeAgentSessionID: targetSessionID,
                            worktreeBindingState: .hydrated([]),
                            explicitlyBound: false
                        ),
                        fixture: fixture
                    )
                    window.promptManager.setAutomaticReviewGitDiffProviderOverrideForTesting { request in
                        await automaticProviderCounter.recordInvocation(request)
                        return AutomaticReviewGitDiffResult(
                            text: "AUTOMATIC_PRIMARY_REPO_MARKER\nAUTOMATIC_SECONDARY_REPO_MARKER",
                            completeness: .complete,
                            outcomes: [],
                            pathIssues: []
                        )
                    }
                    installOracleCapture(capture, on: window, gitInclusion: .selected)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: [
                            "message": "Review every selected repository.",
                            "mode": "review"
                        ],
                        timeoutSeconds: 30
                    )
                    XCTAssertTrue(try toolResultText(response).contains("captured oracle response"))
                    let automaticInvocationCount = await automaticProviderCounter.invocationCount()
                    XCTAssertEqual(automaticInvocationCount, 1)
                    let automaticSelectedPaths = await automaticProviderCounter.lastSelectedPaths()
                    XCTAssertEqual(
                        Set(automaticSelectedPaths),
                        Set(sourceSelection.selectedPaths)
                    )
                    XCTAssertTrue(capture.gitDiff?.contains("AUTOMATIC_PRIMARY_REPO_MARKER") == true)
                    XCTAssertTrue(capture.gitDiff?.contains("AUTOMATIC_SECONDARY_REPO_MARKER") == true)
                    XCTAssertFalse(capture.fileBlocks.isEmpty)

                    await window.agentModeViewModel.mcpDeactivateControlContext(
                        sessionID: targetSessionID,
                        cleanupSessionStore: true
                    )
                    XCTAssertFalse(
                        window.agentModeViewModel.mcpHasAgentRunOracleReviewContextExpectation(
                            tabID: targetTabID
                        )
                    )
                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAgentRunOracleReviewSourceCaptureAllowsEquivalentSelectionRevisionDriftButRejectsIdentityChange() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    contextASearchFileCount: 3
                )
                addTeardownBlock {
                    await fixture.cleanup()
                }
                let window = fixture.contextA.window
                defer {
                    window.mcpServer.setRequestMetadataOverrideForTesting(nil)
                }

                do {
                    try await activateWorkspace(fixture.contextA)
                    let sourceTabID = UUID()
                    guard let workspaceIndex = window.workspaceManager.workspaces.firstIndex(where: {
                        $0.id == fixture.contextA.workspaceID
                    }) else {
                        return XCTFail("Expected active fixture workspace")
                    }
                    window.workspaceManager.workspaces[workspaceIndex].composeTabs.append(
                        ComposeTabState(
                            id: sourceTabID,
                            name: "Oracle revision drift source",
                            selection: StoredSelection(),
                            promptText: "Frozen launch source"
                        )
                    )
                    let sourceIdentity = WorkspaceSelectionIdentity(
                        workspaceID: fixture.contextA.workspaceID,
                        tabID: sourceTabID
                    )
                    let searchPaths = Array(fixture.contextA.searchFileURLs.prefix(3).map(\.path))
                    XCTAssertEqual(searchPaths.count, 3)
                    let sourcePaths = Array(searchPaths.prefix(2))
                    let manualCodemapPath = searchPaths[2]
                    let sourceSelection = StoredSelection(
                        selectedPaths: sourcePaths,
                        codemapAutoEnabled: false
                    )
                    _ = await window.selectionCoordinator.persistSelection(
                        sourceSelection,
                        for: sourceIdentity,
                        source: .runtimeMutation,
                        mirrorToUIIfActive: false
                    )
                    let sourceRevision = window.workspaceManager.selectionRevisionForMCP(
                        workspaceID: fixture.contextA.workspaceID,
                        tabID: sourceTabID
                    )
                    let committedSource = try XCTUnwrap(
                        window.workspaceManager.composeTab(with: sourceTabID)
                    )
                    XCTAssertEqual(Set(committedSource.selection.selectedPaths), Set(sourcePaths))
                    let snapshot = AgentRunOracleReviewLaunchSnapshot(
                        route: .explicitTabContext,
                        windowID: window.windowID,
                        workspaceID: fixture.contextA.workspaceID,
                        tabID: sourceTabID,
                        selectionRevision: sourceRevision,
                        promptText: committedSource.promptText,
                        selection: committedSource.selection,
                        sourceAgentSessionID: nil,
                        routedRunID: nil
                    )

                    let equivalentSelection = StoredSelection(
                        selectedPaths: Array(sourcePaths.reversed()),
                        codemapAutoEnabled: false
                    )
                    _ = await window.selectionCoordinator.persistSelection(
                        equivalentSelection,
                        for: sourceIdentity,
                        source: .runtimeMutation,
                        mirrorToUIIfActive: false
                    )
                    XCTAssertNotEqual(
                        window.workspaceManager.selectionRevisionForMCP(
                            workspaceID: fixture.contextA.workspaceID,
                            tabID: sourceTabID
                        ),
                        sourceRevision
                    )
                    let equivalentCapture = await window.mcpServer.testCaptureAgentRunOracleReviewSource(
                        snapshot: snapshot,
                        targetWindow: window
                    )
                    let liveAfterEquivalentCapture = window.workspaceManager.composeTab(
                        with: sourceTabID
                    )?.selection
                    guard case let .captured(captured) = equivalentCapture else {
                        return XCTFail(
                            "Expected equivalent selection identity drift to preserve captured source, " +
                                "got \(equivalentCapture); " +
                                "liveSelection=\(String(describing: liveAfterEquivalentCapture))"
                        )
                    }
                    XCTAssertEqual(captured.sourceSelectionRevision, sourceRevision)
                    XCTAssertEqual(captured.selection, committedSource.selection)
                    XCTAssertEqual(
                        captured.exactSelectedIdentities,
                        AgentRunOracleReviewSelectionIdentity.normalizedSelectedArtifactIdentities(
                            snapshot.selection
                        )
                    )

                    let manualCodemapChangedSelection = StoredSelection(
                        selectedPaths: sourcePaths,
                        manualCodemapPaths: [manualCodemapPath],
                        codemapAutoEnabled: false
                    )
                    _ = await window.selectionCoordinator.persistSelection(
                        manualCodemapChangedSelection,
                        for: sourceIdentity,
                        source: .runtimeMutation,
                        mirrorToUIIfActive: false
                    )
                    let manualCodemapChangedCapture = await window.mcpServer.testCaptureAgentRunOracleReviewSource(
                        snapshot: snapshot,
                        targetWindow: window
                    )
                    guard case let .unavailable(manualCodemapUnavailable) = manualCodemapChangedCapture else {
                        return XCTFail("Expected manual codemap identity drift to fail closed")
                    }
                    guard case .sourceCaptureFailed = manualCodemapUnavailable.reason else {
                        return XCTFail(
                            "Expected manual codemap source capture failure, got \(manualCodemapUnavailable.reason)"
                        )
                    }

                    let changedSelection = StoredSelection(
                        selectedPaths: [sourcePaths[0]],
                        codemapAutoEnabled: false
                    )
                    _ = await window.selectionCoordinator.persistSelection(
                        changedSelection,
                        for: sourceIdentity,
                        source: .runtimeMutation,
                        mirrorToUIIfActive: false
                    )
                    let changedCapture = await window.mcpServer.testCaptureAgentRunOracleReviewSource(
                        snapshot: snapshot,
                        targetWindow: window
                    )
                    guard case let .unavailable(unavailable) = changedCapture else {
                        return XCTFail("Expected real selection identity drift to fail closed")
                    }
                    guard case let .sourceCaptureFailed(message) = unavailable.reason else {
                        return XCTFail("Expected source capture failure, got \(unavailable.reason)")
                    }
                    XCTAssertTrue(message.contains("selection") || message.contains("tab changed"))
                }
            }
        }

        func testAgentRunExplicitContextCapturesInactiveSourceInsteadOfActiveTab() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let window = fixture.contextA.window
                let apiSettings = try XCTUnwrap(window.promptManager.apiSettingsViewModel)
                let previousClaudeCodeConnected = apiSettings.isClaudeCodeConnected
                defer {
                    window.mcpServer.setAgentRunDispatchOverrideForTesting(nil)
                    window.mcpServer.setRequestMetadataOverrideForTesting(nil)
                    apiSettings.isClaudeCodeConnected = previousClaudeCodeConnected
                }

                do {
                    try await activateWorkspace(fixture.contextA)
                    let explicitTabID = UUID()
                    let explicitSelection = StoredSelection(
                        selectedPaths: [fixture.contextA.fileURL.path],
                        codemapAutoEnabled: false
                    )
                    guard let workspaceIndex = window.workspaceManager.workspaces.firstIndex(where: {
                        $0.id == fixture.contextA.workspaceID
                    }) else {
                        return XCTFail("Expected active fixture workspace")
                    }
                    window.workspaceManager.workspaces[workspaceIndex].composeTabs.append(
                        ComposeTabState(
                            id: explicitTabID,
                            name: "Explicit inactive launch source",
                            selection: explicitSelection,
                            promptText: "EXPLICIT_INACTIVE_PROMPT"
                        )
                    )
                    let connectionID = UUID()
                    try window.mcpServer.bindTabForConnection(
                        connectionID: connectionID,
                        clientName: "public-agent-run-explicit",
                        tabID: explicitTabID,
                        workspaceID: fixture.contextA.workspaceID,
                        windowID: window.windowID
                    )
                    window.mcpServer.setRequestMetadataOverrideForTesting(.init(
                        connectionID: connectionID,
                        clientName: "public-agent-run-explicit",
                        windowID: window.windowID,
                        runPurpose: .unknown
                    ))
                    var targetRunID: UUID?
                    window.mcpServer.setAgentRunDispatchOverrideForTesting {
                        _, tabID, _, _, viewModel in
                        let runID = UUID()
                        targetRunID = runID
                        let session = viewModel.session(for: tabID)
                        session.runID = runID
                        session.runState = .running
                        guard viewModel.mcpBindPendingAgentRunOracleReviewContext(
                            tabID: tabID,
                            runID: runID
                        ) != nil else {
                            throw MCPError.internalError(
                                "Explicit launch child did not promote its carrier."
                            )
                        }
                        return .startedRun
                    }
                    apiSettings.isClaudeCodeConnected = true
                    let startValue = try await window.mcpServer.executeAgentRunForTesting(args: [
                        "op": .string("start"),
                        "message": .string("Start from the explicit inactive source."),
                        "model_id": .string("claudeCode:sonnet"),
                        "detach": .bool(true),
                        "timeout": .int(0)
                    ])
                    let startObject = try XCTUnwrap(startValue.objectValue)
                    let sessionObject = try XCTUnwrap(startObject["session"]?.objectValue)
                    let childSessionID = try XCTUnwrap(
                        startObject["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                    )
                    let childTabID = try XCTUnwrap(
                        sessionObject["context_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                    )
                    XCTAssertNil(sessionObject["parent_session_id"])
                    let delegated = try XCTUnwrap(
                        try window.agentModeViewModel.mcpDelegatedAgentRunOracleReviewContext(
                            tabID: childTabID,
                            workspaceID: fixture.contextA.workspaceID,
                            sessionID: childSessionID,
                            runID: XCTUnwrap(targetRunID)
                        )
                    )
                    XCTAssertEqual(delegated.source.sourceTabID, explicitTabID)
                    guard case let .captured(captured) = delegated.source else {
                        return XCTFail("Expected captured explicit launch source")
                    }
                    XCTAssertEqual(captured.promptText, "EXPLICIT_INACTIVE_PROMPT")
                    XCTAssertEqual(captured.selection, explicitSelection)
                    XCTAssertNil(captured.sourceAgentSessionID)
                    XCTAssertNotEqual(explicitTabID, fixture.contextA.tabID)

                    await window.agentModeViewModel.mcpDeactivateControlContext(
                        sessionID: childSessionID,
                        cleanupSessionStore: true
                    )
                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private func assertOracleReviewTransportUsesPublishedPatch(
            repositoryKind: ProductionOracleRepositoryKind,
            delegateToChildRun: Bool = false,
            childInheritWorktreeBindings: Bool = true,
            childCreateWorktree: Bool = false
        ) async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gitFixture = try ReviewGitRepositoryFixture(
                    name: "OracleTransport-" + repositoryKind.rawValue
                )
                let traceCapture = OracleReviewPackagingTraceCapture()
                let transportCapture = OracleReviewTransportCapture()
                let automaticProviderCounter = OracleAutomaticProviderCounter()
                let customOpenAIProvider = CustomOpenAIProvider(
                    baseURL: "https://example.invalid",
                    apiKey: "test-key",
                    defaultModel: "oracle-serialization-test"
                )
                let settings = GlobalSettingsStore.shared
                let previousShowPresets = settings.mcpShowModelPresets()
                let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
                let apiSettings = try XCTUnwrap(
                    fixture.contextA.window.promptManager.apiSettingsViewModel
                )
                let previousCustomProviderValidity = apiSettings.isCustomProviderValid
                let previousClaudeCodeConnected = apiSettings.isClaudeCodeConnected
                let previousPlanningModel = fixture.contextA.window.promptManager.planningModelName
                var syntheticSessionIDsToCleanup: [UUID] = []
                var syntheticRunIDsToCleanup: [UUID] = []
                var syntheticConnectionsToCleanup: [SyntheticMCPConnectionCleanup] = []
                var delegatedConversationSessionIDToDeactivate: UUID?

                func trackSyntheticSession(_ sessionID: UUID) {
                    guard !syntheticSessionIDsToCleanup.contains(sessionID) else { return }
                    syntheticSessionIDsToCleanup.append(sessionID)
                }

                func trackSyntheticRun(_ runID: UUID) {
                    guard !syntheticRunIDsToCleanup.contains(runID) else { return }
                    syntheticRunIDsToCleanup.append(runID)
                }

                func trackSyntheticConnection(
                    connectionID: UUID,
                    clientName: String,
                    runID: UUID?
                ) {
                    guard !syntheticConnectionsToCleanup.contains(where: {
                        $0.connectionID == connectionID
                    }) else { return }
                    syntheticConnectionsToCleanup.append(SyntheticMCPConnectionCleanup(
                        connectionID: connectionID,
                        clientName: clientName,
                        runID: runID
                    ))
                }

                defer {
                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer
                        .setOracleReviewPackagingTraceObserverForTesting(nil)
                    fixture.contextA.window.mcpServer
                        .setOraclePostPackagingTransportOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer
                        .setAgentRunDispatchOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer
                        .setRequestMetadataOverrideForTesting(nil)
                    apiSettings.isCustomProviderValid = previousCustomProviderValidity
                    apiSettings.isClaudeCodeConnected = previousClaudeCodeConnected
                    fixture.contextA.window.promptManager.planningModelName = previousPlanningModel
                    settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                    settings.setMCPTemporarilyDisablePresets(
                        previousTemporaryDisable,
                        commit: false
                    )
                    gitFixture.cleanup()
                }

                do {
                    try await activateWorkspace(fixture.contextA)

                    let publicationRoot: URL
                    let sourceFile: URL
                    let bindings: [AgentSessionWorktreeBinding]
                    let frozenContext: MCPServerViewModel.TabContextSnapshot
                    let expectedMarker: String
                    let forbiddenMarker: String?
                    let physicalSourceFile: URL

                    switch repositoryKind {
                    case .canonical:
                        publicationRoot = fixture.contextA.rootURL
                        sourceFile = fixture.contextA.fileURL
                        _ = try gitFixture.runGit(["init"], at: publicationRoot)
                        _ = try gitFixture.runGit(
                            ["config", "user.name", "RepoPrompt Test"],
                            at: publicationRoot
                        )
                        _ = try gitFixture.runGit(
                            ["config", "user.email", "repoprompt@example.test"],
                            at: publicationRoot
                        )
                        _ = try gitFixture.runGit(
                            ["config", "commit.gpgSign", "false"],
                            at: publicationRoot
                        )
                        _ = try gitFixture.runGit(["add", "."], at: publicationRoot)
                        _ = try gitFixture.runGit(
                            ["commit", "-m", "Initial commit"],
                            at: publicationRoot
                        )
                        expectedMarker = "oracle_canonical_transport_marker"
                        forbiddenMarker = nil
                        try write(
                            "let oracleMarker = \"" + expectedMarker + "\"\n",
                            to: sourceFile
                        )
                        bindings = []
                        physicalSourceFile = sourceFile
                        frozenContext = MCPServerViewModel.TabContextSnapshot(
                            tabID: fixture.contextA.tabID,
                            windowID: fixture.contextA.window.windowID,
                            workspaceID: fixture.contextA.workspaceID,
                            promptText: "Review canonical transport",
                            selection: StoredSelection(
                                selectedPaths: [sourceFile.path],
                                codemapAutoEnabled: false
                            ),
                            selectedMetaPromptIDs: [],
                            tabName: "Canonical Oracle Transport",
                            runID: UUID(),
                            activeAgentSessionID: nil,
                            worktreeBindingState: .notApplicable,
                            explicitlyBound: false
                        )

                    case .linkedWorktree, .visibleLinkedWorktree:
                        let usesVisibleLinkedRoot = repositoryKind == .visibleLinkedWorktree
                        let logicalRoot = try gitFixture.makeRepository(
                            named: "logical",
                            files: ["Sources/Feature.swift": "let oracleMarker = \"initial\"\n"]
                        )
                        let worktreeRoot = try gitFixture.makeLinkedWorktree(
                            from: logicalRoot,
                            named: "linked",
                            branch: "feature/oracle-transport"
                        )
                        publicationRoot = usesVisibleLinkedRoot ? worktreeRoot : logicalRoot
                        let logicalSourceFile = logicalRoot
                            .appendingPathComponent("Sources/Feature.swift")
                        sourceFile = (usesVisibleLinkedRoot ? worktreeRoot : logicalRoot)
                            .appendingPathComponent("Sources/Feature.swift")
                        expectedMarker = usesVisibleLinkedRoot
                            ? "oracle_visible_worktree_transport_marker"
                            : "oracle_worktree_transport_marker"
                        forbiddenMarker = "oracle_canonical_transport_leak"
                        try write(
                            "let oracleMarker = \"" + forbiddenMarker! + "\"\n",
                            to: logicalSourceFile
                        )
                        try write(
                            "let oracleMarker = \"" + expectedMarker + "\"\n",
                            to: worktreeRoot.appendingPathComponent("Sources/Feature.swift")
                        )
                        _ = try await fixture.contextA.window.workspaceFileContextStore
                            .loadRoot(
                                path: usesVisibleLinkedRoot ? worktreeRoot.path : logicalRoot.path,
                                kind: .primaryWorkspace
                            )
                        let layout = try XCTUnwrap(
                            GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: worktreeRoot)
                        )
                        let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
                            commonGitDir: layout.commonDir,
                            mainWorktreeRoot: layout.knownMainWorktreeRoot
                        )
                        let worktreeID = GitWorktreeIdentity.worktreeID(
                            repositoryID: repositoryIdentity.repositoryID,
                            gitDir: layout.gitDir,
                            isMain: false,
                            path: layout.workTreeRoot
                        )
                        let binding = AgentSessionWorktreeBinding(
                            id: "binding-oracle-transport",
                            repositoryID: repositoryIdentity.repositoryID,
                            repoKey: GitRepoDescriptor(rootURL: logicalRoot).repoKey,
                            logicalRootPath: logicalRoot.path,
                            logicalRootName: "OracleTransportRepo",
                            worktreeID: worktreeID,
                            worktreeRootPath: worktreeRoot.path,
                            worktreeName: "linked",
                            branch: "feature/oracle-transport",
                            source: "test"
                        )
                        physicalSourceFile = worktreeRoot
                            .appendingPathComponent("Sources/Feature.swift")
                        if usesVisibleLinkedRoot {
                            let workspaceIndex = try XCTUnwrap(
                                fixture.contextA.window.workspaceManager.workspaces.firstIndex {
                                    $0.id == fixture.contextA.workspaceID
                                }
                            )
                            var workspace = fixture.contextA.window.workspaceManager
                                .workspaces[workspaceIndex]
                            workspace.repoPaths = [worktreeRoot.path]
                            fixture.contextA.window.workspaceManager.workspaces[workspaceIndex] = workspace
                            bindings = []
                            frozenContext = MCPServerViewModel.TabContextSnapshot(
                                tabID: fixture.contextA.tabID,
                                windowID: fixture.contextA.window.windowID,
                                workspaceID: fixture.contextA.workspaceID,
                                promptText: "Review visible linked transport",
                                selection: StoredSelection(
                                    selectedPaths: [sourceFile.path],
                                    codemapAutoEnabled: false
                                ),
                                selectedMetaPromptIDs: [],
                                tabName: "Visible Linked Oracle Transport",
                                runID: UUID(),
                                activeAgentSessionID: nil,
                                worktreeBindingState: .notApplicable,
                                explicitlyBound: false
                            )
                        } else {
                            bindings = [binding]
                            frozenContext = makeFrozenContext(
                                fixture: fixture,
                                selection: StoredSelection(
                                    selectedPaths: [sourceFile.path],
                                    codemapAutoEnabled: false
                                ),
                                bindings: bindings
                            )
                        }
                    }

                    if let activeAgentSessionID = frozenContext.activeAgentSessionID {
                        trackSyntheticSession(activeAgentSessionID)
                    }

                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: frozenContext,
                        fixture: fixture
                    )

                    let gitResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.git,
                        arguments: [
                            "op": "diff",
                            "repo_root": publicationRoot.path,
                            "scope": "selected",
                            "detail": "patches",
                            "artifacts": true,
                            "mode": "deep"
                        ],
                        timeoutSeconds: 30
                    )
                    let gitText = try toolResultText(gitResponse)

                    let publishedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(
                            with: fixture.contextA.tabID
                        )
                    ).selection
                    let diagnosticContext = "oracle transport publication "
                        + "repositoryKind=\(repositoryKind.rawValue) "
                        + "delegateToChildRun=\(delegateToChildRun) "
                        + "childInheritWorktreeBindings=\(childInheritWorktreeBindings) "
                        + "childCreateWorktree=\(childCreateWorktree)"
                    let mapPath = try requireSelectedPath(
                        suffix: "/MAP.txt",
                        in: publishedSelection,
                        context: diagnosticContext,
                        toolOutput: gitText
                    )
                    let patchPath = try requireSelectedPath(
                        suffix: "/diff/all.patch",
                        in: publishedSelection,
                        context: diagnosticContext,
                        toolOutput: gitText
                    )
                    let patchText = try String(contentsOfFile: patchPath, encoding: .utf8)
                    let mapAlias = try XCTUnwrap(
                        mapPath.range(of: "/_git_data/").map {
                            "_git_data/" + mapPath[$0.upperBound...]
                        }
                    )
                    let patchAlias = try XCTUnwrap(
                        patchPath.range(of: "/_git_data/").map {
                            "_git_data/" + patchPath[$0.upperBound...]
                        }
                    )
                    let committedRevision = fixture.contextA.window.workspaceManager
                        .selectionRevisionForMCP(
                            workspaceID: fixture.contextA.workspaceID,
                            tabID: fixture.contextA.tabID
                        )
                    XCTAssertTrue(publishedSelection.selectedPaths.contains(sourceFile.path))
                    XCTAssertTrue(patchText.contains(expectedMarker), patchText)
                    if let forbiddenMarker {
                        XCTAssertFalse(patchText.contains(forbiddenMarker), patchText)
                    }

                    var conversationTabID = fixture.contextA.tabID
                    var conversationSessionID = frozenContext.activeAgentSessionID
                    var conversationRunID = frozenContext.runID
                    var expectedDelegationID: UUID?
                    var expectedPackagedSourceMarker = expectedMarker
                    var directOracleConnectionID: UUID?

                    if delegateToChildRun {
                        let window = fixture.contextA.window
                        let agentModeViewModel = window.agentModeViewModel
                        let startConnectionID = UUID()
                        var targetRunID: UUID?
                        var sourceRunIDToCleanup: UUID?

                        if bindings.isEmpty {
                            window.mcpServer.setRequestMetadataOverrideForTesting(.init(
                                connectionID: startConnectionID,
                                clientName: "public-agent-run-window-only",
                                windowID: window.windowID,
                                runPurpose: .unknown,
                                explicitWindowRoutingHint: MCPExplicitWindowRoutingHint(
                                    connectionID: startConnectionID,
                                    toolName: "agent_run",
                                    windowID: window.windowID,
                                    windowStateIdentity: ObjectIdentifier(window),
                                    serverViewModelIdentity: ObjectIdentifier(window.mcpServer),
                                    provenance: .hiddenWindowArgument
                                )
                            ))
                            XCTAssertEqual(
                                window.mcpServer.connectionBindingSnapshot(forConnection: startConnectionID).bindingKind,
                                .unbound
                            )
                        } else {
                            let sourceClientName = "public-agent-run-nested"
                            let sourceSessionID = UUID()
                            let sourceRunID = UUID()
                            sourceRunIDToCleanup = sourceRunID
                            trackSyntheticSession(sourceSessionID)
                            var sourceTab = try XCTUnwrap(
                                window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                            )
                            sourceTab.activeAgentSessionID = sourceSessionID
                            window.workspaceManager.updateComposeTab(sourceTab, markDirty: false)
                            let sourceSession = agentModeViewModel.session(for: fixture.contextA.tabID)
                            sourceSession.testInstallPersistentSessionBinding(sessionID: sourceSessionID)
                            sourceSession.mcpControlContext = makeAgentMCPControlContext(
                                sessionID: sourceSessionID
                            )
                            sourceSession.worktreeBindings = bindings
                            sourceSession.runID = sourceRunID
                            try window.mcpServer.bindTabForConnection(
                                connectionID: startConnectionID,
                                clientName: sourceClientName,
                                tabID: fixture.contextA.tabID,
                                workspaceID: fixture.contextA.workspaceID,
                                windowID: window.windowID,
                                runID: sourceRunID
                            )
                            trackSyntheticRun(sourceRunID)
                            trackSyntheticConnection(
                                connectionID: startConnectionID,
                                clientName: sourceClientName,
                                runID: sourceRunID
                            )
                            await ServerNetworkManager.shared.debugSeedRunPolicyState(
                                runID: sourceRunID,
                                tabID: fixture.contextA.tabID,
                                restrictedTools: [],
                                additionalTools: nil,
                                purpose: .agentModeRun
                            )
                            await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
                                connectionID: startConnectionID,
                                runID: sourceRunID,
                                purpose: .agentModeRun
                            )
                            window.mcpServer.setRequestMetadataOverrideForTesting(.init(
                                connectionID: startConnectionID,
                                clientName: sourceClientName,
                                windowID: window.windowID,
                                runPurpose: .agentModeRun
                            ))
                        }

                        window.mcpServer.setAgentRunDispatchOverrideForTesting {
                            sessionID,
                            tabID,
                            _,
                            _,
                            viewModel in
                            let runID = UUID()
                            targetRunID = runID
                            let session = viewModel.session(for: tabID)
                            session.runID = runID
                            session.runState = .running
                            guard viewModel.mcpBindPendingAgentRunOracleReviewContext(
                                tabID: tabID,
                                runID: runID
                            ) != nil else {
                                throw MCPError.internalError(
                                    "Public Agent Run test did not promote its staged Oracle source."
                                )
                            }
                            XCTAssertEqual(session.activeAgentSessionID, sessionID)
                            return .startedRun
                        }
                        apiSettings.isClaudeCodeConnected = true
                        let startValue = try await window.mcpServer.executeAgentRunForTesting(args: [
                            "op": .string("start"),
                            "message": .string("Start delegated Oracle review child."),
                            "model_id": .string("claudeCode:sonnet"),
                            "session_name": .string("Delegated Oracle child"),
                            "inherit_worktree": .bool(childInheritWorktreeBindings),
                            "worktree_create": .bool(childCreateWorktree),
                            "detach": .bool(true),
                            "timeout": .int(0)
                        ])
                        let startObject = try XCTUnwrap(startValue.objectValue)
                        let startSession = try XCTUnwrap(startObject["session"]?.objectValue)
                        let targetSessionID = try XCTUnwrap(
                            startObject["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                        )
                        let targetTabID = try XCTUnwrap(
                            startSession["context_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                        )
                        let resolvedTargetRunID = try XCTUnwrap(targetRunID)
                        trackSyntheticSession(targetSessionID)
                        trackSyntheticRun(resolvedTargetRunID)
                        delegatedConversationSessionIDToDeactivate = targetSessionID
                        let delegated = try XCTUnwrap(
                            try agentModeViewModel.mcpDelegatedAgentRunOracleReviewContext(
                                tabID: targetTabID,
                                workspaceID: fixture.contextA.workspaceID,
                                sessionID: targetSessionID,
                                runID: resolvedTargetRunID
                            )
                        )
                        expectedDelegationID = delegated.source.delegationID
                        let actualTargetBindings = agentModeViewModel.session(for: targetTabID).worktreeBindings
                        let expectedTargetBindings = childCreateWorktree
                            ? actualTargetBindings
                            : (childInheritWorktreeBindings ? bindings : [])
                        if childCreateWorktree {
                            XCTAssertEqual(actualTargetBindings.count, 1)
                        }
                        XCTAssertEqual(delegated.target.worktreeBindings, expectedTargetBindings)
                        if bindings.isEmpty {
                            XCTAssertNil(startSession["parent_session_id"])
                            XCTAssertNil(delegated.source.sourceAgentSessionID)
                        } else {
                            XCTAssertNotNil(startSession["parent_session_id"]?.stringValue)
                        }
                        XCTAssertEqual(delegated.source.sourceTabID, fixture.contextA.tabID)
                        XCTAssertEqual(delegated.source.workspaceID, fixture.contextA.workspaceID)
                        if case let .captured(captured) = delegated.source {
                            XCTAssertEqual(captured.sourceSelectionRevision, committedRevision)
                            XCTAssertEqual(captured.selection, publishedSelection)
                        } else {
                            XCTFail("Expected public Agent Run to capture its launch package")
                        }

                        let liveMarker = "oracle_newer_live_" + repositoryKind.rawValue
                        try write(
                            "let oracleMarker = \"" + liveMarker + "\"\n",
                            to: physicalSourceFile
                        )
                        expectedPackagedSourceMarker = liveMarker
                        conversationTabID = targetTabID
                        conversationSessionID = targetSessionID
                        conversationRunID = resolvedTargetRunID
                        let childContext = MCPServerViewModel.TabContextSnapshot(
                            tabID: targetTabID,
                            windowID: fixture.contextA.window.windowID,
                            workspaceID: fixture.contextA.workspaceID,
                            promptText: "Child conversation prompt",
                            selection: StoredSelection(codemapAutoEnabled: false),
                            selectedMetaPromptIDs: [],
                            tabName: "Delegated Oracle child",
                            runID: resolvedTargetRunID,
                            activeAgentSessionID: targetSessionID,
                            worktreeBindingState: .hydrated(expectedTargetBindings),
                            explicitlyBound: false
                        )
                        if let sourceRunIDToCleanup {
                            await cleanupSyntheticMCPRoutingForOracleTest(
                                window: window,
                                sessionIDs: [],
                                runIDs: [sourceRunIDToCleanup],
                                connections: syntheticConnectionsToCleanup.filter {
                                    $0.runID == sourceRunIDToCleanup
                                }
                            )
                        }
                        if bindings.isEmpty {
                            try await configureAgentModeEndpoint(
                                endpoint,
                                context: childContext,
                                fixture: fixture
                            )
                        } else {
                            let childOracleClientName = "linked-public-child-oracle"
                            let connectionID = UUID()
                            directOracleConnectionID = connectionID
                            try window.mcpServer.bindTabForConnection(
                                connectionID: connectionID,
                                clientName: childOracleClientName,
                                tabID: targetTabID,
                                workspaceID: fixture.contextA.workspaceID,
                                windowID: window.windowID,
                                runID: resolvedTargetRunID
                            )
                            trackSyntheticConnection(
                                connectionID: connectionID,
                                clientName: childOracleClientName,
                                runID: resolvedTargetRunID
                            )
                            await ServerNetworkManager.shared.setRunPurpose(
                                .agentModeRun,
                                for: connectionID
                            )
                            try await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
                                connectionID: connectionID,
                                runID: resolvedTargetRunID,
                                purpose: .agentModeRun,
                                windowID: window.windowID
                            )
                            window.mcpServer.setRequestMetadataOverrideForTesting(.init(
                                connectionID: connectionID,
                                clientName: childOracleClientName,
                                windowID: window.windowID,
                                runPurpose: .agentModeRun
                            ))
                        }
                    }

                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting { _ in
                            await automaticProviderCounter.recordInvocation()
                            return AutomaticReviewGitDiffResult(
                                text: "AUTOMATIC_FALLBACK_INVOKED",
                                completeness: .complete,
                                outcomes: [],
                                pathIssues: []
                            )
                        }
                    fixture.contextA.window.mcpServer
                        .setOracleReviewPackagingTraceObserverForTesting {
                            traceCapture.record($0)
                        }
                    fixture.contextA.window.mcpServer
                        .setOraclePostPackagingTransportOverrideForTesting { message, model in
                            transportCapture.record(
                                message: message,
                                model: model,
                                serializedMessages: customOpenAIProvider
                                    .serializedMessagesForTesting(message)
                            )
                            let stream = AsyncThrowingStream<ChatStreamOutput, Error> {
                                continuation in
                                continuation.yield(ChatStreamOutput(
                                    text: "transported oracle response",
                                    reasoning: nil,
                                    tokens: ChatTokenInfo(),
                                    isFinal: true
                                ))
                                continuation.finish()
                            }
                            return (UUID(), stream)
                        }

                    settings.setMCPShowModelPresets(false, commit: false)
                    settings.setMCPTemporarilyDisablePresets(false, commit: false)
                    apiSettings.isCustomProviderValid = true
                    fixture.contextA.window.promptManager.planningModelName =
                        AIModel.customProviderUser(
                            name: "oracle-serialization-test"
                        ).rawValue

                    let oracleViewModel = fixture.contextA.window.oracleViewModel
                    XCTAssertFalse(
                        oracleViewModel.sessions
                            .filter { $0.composeTabID == conversationTabID }
                            .flatMap { oracleViewModel.messagesSnapshot(for: $0.id) }
                            .contains { $0.isUser }
                    )
                    if directOracleConnectionID != nil {
                        let freshValue = try await ServerNetworkManager.withConnectionID(
                            XCTUnwrap(directOracleConnectionID)
                        ) {
                            try await fixture.contextA.window.mcpServer
                                .executeAskOracleForTesting(args: [
                                    "message": .string("Review the published patch."),
                                    "mode": .string("review")
                                ])
                        }
                        XCTAssertTrue(
                            freshValue.objectValue?["response"]?.stringValue?
                                .contains("transported oracle response") == true
                        )
                    } else {
                        let freshResponse = try await endpoint.callTool(
                            name: MCPWindowToolName.askOracle,
                            arguments: [
                                "message": "Review the published patch.",
                                "mode": "review"
                            ],
                            timeoutSeconds: 30
                        )
                        XCTAssertTrue(
                            try toolResultText(freshResponse).contains(
                                "transported oracle response"
                            )
                        )
                    }
                    let sessionDescriptions = oracleViewModel.sessions.map {
                        "tab=\($0.composeTabID) session=\(String(describing: $0.agentModeSessionID)) run=\(String(describing: $0.agentModeRunID))"
                    }
                    let freshSession = try XCTUnwrap(
                        oracleViewModel.sessions.first {
                            $0.composeTabID == conversationTabID
                                && $0.agentModeSessionID == conversationSessionID
                                && $0.agentModeRunID == conversationRunID
                        },
                        "Expected tab=\(conversationTabID) session=\(String(describing: conversationSessionID)) run=\(String(describing: conversationRunID)); actual=\(sessionDescriptions)"
                    )
                    XCTAssertEqual(freshSession.composeTabID, conversationTabID)
                    XCTAssertEqual(freshSession.agentModeSessionID, conversationSessionID)
                    XCTAssertEqual(freshSession.agentModeRunID, conversationRunID)
                    let chatID = freshSession.shortID
                    if directOracleConnectionID != nil {
                        let continuingValue = try await ServerNetworkManager.withConnectionID(
                            XCTUnwrap(directOracleConnectionID)
                        ) {
                            try await fixture.contextA.window.mcpServer
                                .executeAskOracleForTesting(args: [
                                    "message": .string("Continue reviewing the same published patch."),
                                    "mode": .string("review"),
                                    "chat_id": .string(chatID)
                                ])
                        }
                        XCTAssertTrue(
                            continuingValue.objectValue?["response"]?.stringValue?
                                .contains("transported oracle response") == true
                        )
                    } else {
                        let continuingResponse = try await endpoint.callTool(
                            name: MCPWindowToolName.askOracle,
                            arguments: [
                                "message": "Continue reviewing the same published patch.",
                                "mode": "review",
                                "chat_id": chatID
                            ],
                            timeoutSeconds: 30
                        )
                        XCTAssertTrue(
                            try toolResultText(continuingResponse).contains(
                                "transported oracle response"
                            )
                        )
                    }
                    let continuingSessionIDs = Set(
                        oracleViewModel.sessions.compactMap { session in
                            session.composeTabID == conversationTabID
                                && session.agentModeSessionID == conversationSessionID
                                && session.agentModeRunID == conversationRunID
                                ? session.id
                                : nil
                        }
                    )
                    XCTAssertEqual(continuingSessionIDs, [freshSession.id])

                    let messages = transportCapture.messages
                    let expectedFingerprint =
                        OracleReviewPackagingDiagnostics.fingerprint(patchText)
                    XCTAssertEqual(messages.count, 2)
                    XCTAssertEqual(
                        transportCapture.serializedGitDiffFingerprints,
                        Array(repeating: expectedFingerprint, count: 2)
                    )
                    XCTAssertTrue(
                        transportCapture.models.allSatisfy {
                            $0.providerType == .customProvider
                        }
                    )
                    let automaticInvocationCount =
                        await automaticProviderCounter.invocationCount()
                    XCTAssertEqual(automaticInvocationCount, 0)
                    let traceTurns = traceCapture.completedTurns()
                    XCTAssertEqual(traceTurns.count, 2)
                    XCTAssertEqual(Set(traceTurns.map(\.correlationID)).count, 2)

                    for turn in traceTurns {
                        let frozen = try XCTUnwrap(turn.frozen)
                        let preassembly = try XCTUnwrap(turn.preassembly)
                        let submission = try XCTUnwrap(turn.submission)
                        XCTAssertNil(turn.failureType)
                        XCTAssertEqual(frozen.origin, .askOracle)
                        XCTAssertEqual(frozen.conversationTabID, conversationTabID)
                        XCTAssertEqual(frozen.conversationWorkspaceID, fixture.contextA.workspaceID)
                        XCTAssertEqual(frozen.sourceTabID, fixture.contextA.tabID)
                        XCTAssertEqual(frozen.sourceWorkspaceID, fixture.contextA.workspaceID)
                        XCTAssertEqual(frozen.sourceSelectionRevision, committedRevision)
                        XCTAssertEqual(frozen.delegationID, expectedDelegationID)
                        XCTAssertEqual(frozen.conversationAgentSessionID, conversationSessionID)
                        XCTAssertEqual(frozen.conversationAgentRunID, conversationRunID)
                        XCTAssertEqual(
                            Set(frozen.selectedIdentityHashes),
                            Set(publishedSelection.selectedPaths.map(
                                OracleReviewPackagingDiagnostics.identityHash
                            ))
                        )
                        XCTAssertEqual(
                            frozen.capability?.workspaceID,
                            fixture.contextA.workspaceID
                        )
                        XCTAssertEqual(
                            frozen.capability?.creatorTabID,
                            fixture.contextA.tabID
                        )
                        XCTAssertEqual(
                            Set(frozen.capability?.boundRepositoryIDs ?? []),
                            Set(bindings.map(\.repositoryID))
                        )
                        XCTAssertEqual(
                            Set(frozen.capability?.boundWorktreeIDs ?? []),
                            Set(bindings.map(\.worktreeID))
                        )

                        XCTAssertEqual(preassembly.gitInclusion, GitInclusion.selected.rawValue)
                        XCTAssertFalse(
                            preassembly.disabledPromptSections.contains(
                                String(describing: PromptSection.gitDiff)
                            )
                        )
                        XCTAssertEqual(
                            preassembly.selectedArtifactPolicy,
                            String(
                                describing: SelectedGitDiffArtifactPolicy
                                    .includeBeforeGitInclusion
                            )
                        )
                        XCTAssertEqual(preassembly.resolutionSource, .selectedArtifact)
                        XCTAssertEqual(preassembly.gitDiff, expectedFingerprint)
                        XCTAssertEqual(submission.gitDiff, expectedFingerprint)
                        XCTAssertEqual(preassembly.fileBlocks, submission.fileBlocks)
                        XCTAssertTrue(
                            preassembly.artifactDispositions.contains {
                                $0.pathHash == OracleReviewPackagingDiagnostics.identityHash(mapPath)
                                    && $0.status == .authorized
                                    && $0.kind == SelectedGitArtifactKind.map.rawValue
                                    && $0.detail == "readable"
                            }
                        )
                        XCTAssertTrue(
                            preassembly.artifactDispositions.contains {
                                $0.pathHash == OracleReviewPackagingDiagnostics.identityHash(patchPath)
                                    && $0.status == .authorized
                                    && $0.kind == SelectedGitArtifactKind.patch.rawValue
                                    && $0.detail == "readable"
                            }
                        )
                        XCTAssertFalse(
                            preassembly.artifactDispositions.contains {
                                $0.status == .rejected
                            }
                        )
                    }

                    for (message, serializedUserContent) in zip(
                        messages,
                        transportCapture.serializedUserContents
                    ) {
                        XCTAssertEqual(message.gitDiff, patchText)
                        XCTAssertTrue(
                            serializedUserContent.contains(
                                "<git_diff>\n" + patchText + "\n</git_diff>"
                            )
                        )
                        XCTAssertEqual(
                            serializedUserContent.components(
                                separatedBy: mapAlias
                            ).count - 1,
                            1
                        )
                        XCTAssertFalse(serializedUserContent.contains(patchAlias))
                        XCTAssertTrue(serializedUserContent.contains(expectedPackagedSourceMarker))
                        if let forbiddenMarker {
                            XCTAssertFalse(
                                serializedUserContent.contains(forbiddenMarker)
                            )
                        }
                        XCTAssertEqual(
                            message.fileBlocks.count { $0.contains(mapAlias) },
                            1
                        )
                        XCTAssertFalse(
                            message.fileBlocks.contains {
                                $0.contains("<path>" + patchAlias + "</path>")
                            }
                        )
                        let packagedSources = message.fileBlocks.joined(separator: "\n")
                        XCTAssertTrue(
                            packagedSources.contains(expectedPackagedSourceMarker),
                            packagedSources
                        )
                        if delegateToChildRun {
                            XCTAssertFalse(packagedSources.contains(expectedMarker), packagedSources)
                        }
                        if let forbiddenMarker {
                            XCTAssertFalse(
                                packagedSources.contains(forbiddenMarker),
                                packagedSources
                            )
                        }
                    }

                    if delegateToChildRun,
                       let conversationSessionID
                    {
                        await fixture.contextA.window.agentModeViewModel
                            .mcpDeactivateControlContext(
                                sessionID: conversationSessionID,
                                cleanupSessionStore: true
                            )
                        XCTAssertFalse(
                            fixture.contextA.window.agentModeViewModel
                                .mcpHasAgentRunOracleReviewContextExpectation(
                                    tabID: conversationTabID
                                )
                        )
                    }

                    await cleanupSyntheticMCPRoutingForOracleTest(
                        window: fixture.contextA.window,
                        sessionIDs: syntheticSessionIDsToCleanup,
                        runIDs: syntheticRunIDsToCleanup,
                        connections: syntheticConnectionsToCleanup
                    )
                    await fixture.cleanup()
                } catch {
                    if delegateToChildRun,
                       let delegatedConversationSessionIDToDeactivate
                    {
                        await fixture.contextA.window.agentModeViewModel
                            .mcpDeactivateControlContext(
                                sessionID: delegatedConversationSessionIDToDeactivate,
                                cleanupSessionStore: true
                            )
                    }
                    await cleanupSyntheticMCPRoutingForOracleTest(
                        window: fixture.contextA.window,
                        sessionIDs: syntheticSessionIDsToCleanup,
                        runIDs: syntheticRunIDsToCleanup,
                        connections: syntheticConnectionsToCleanup
                    )
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleFailsClosedWhenOneOfMultipleBoundRootsIsUnavailable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let logicalRootA = fixture.contextA.rootURL
                    let logicalFileA = fixture.contextA.fileURL
                    let logicalRootB = try makeTemporaryRoot(name: "OracleMixedLogicalB")
                    let logicalFileB = logicalRootB.appendingPathComponent("Sources/Second.swift")
                    let worktreeRootA = try makeTemporaryRoot(name: "OracleMixedWorktreeA")
                    let worktreeFileA = worktreeRootA
                        .appendingPathComponent("Sources", isDirectory: true)
                        .appendingPathComponent(logicalFileA.lastPathComponent)
                    let missingWorktreeB = fixture.rootURL.appendingPathComponent(
                        "missing-mixed-oracle-worktree-\(UUID().uuidString)",
                        isDirectory: true
                    )

                    try write("let value = \"canonical_oracle_mixed_a\"\n", to: logicalFileA)
                    try write("let value = \"canonical_oracle_mixed_b\"\n", to: logicalFileB)
                    try write("let value = \"worktree_oracle_mixed_a\"\n", to: worktreeFileA)
                    _ = try await fixture.contextA.window.workspaceFileContextStore.loadRoot(path: logicalRootB.path)

                    let bindings = [
                        makeBinding(logicalRoot: logicalRootA, worktreeRoot: worktreeRootA, suffix: "mixed-a"),
                        makeBinding(logicalRoot: logicalRootB, worktreeRoot: missingWorktreeB, suffix: "mixed-b")
                    ]
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(
                            selectedPaths: [logicalFileA.path, logicalFileB.path],
                            codemapAutoEnabled: false
                        ),
                        bindings: bindings
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)
                    installOracleCapture(capture, on: fixture.contextA.window)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Compare the mixed-availability roots."],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(response.rawJSON.contains("worktree projection is unavailable"), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains(missingWorktreeB.standardizedFileURL.path), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains("canonical_oracle_mixed_a"), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains("canonical_oracle_mixed_b"), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains("worktree_oracle_mixed_a"), response.rawJSON)
                    XCTAssertFalse(capture.wasInvoked)

                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleUnavailableWorktreeFailsBeforeCanonicalPackaging() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let canonicalSentinel = "canonical_oracle_must_not_leak"
                    try write("let value = \"\(canonicalSentinel)\"\n", to: fixture.contextA.fileURL)
                    let missingWorktree = fixture.rootURL.appendingPathComponent(
                        "missing-oracle-worktree-\(UUID().uuidString)",
                        isDirectory: true
                    )
                    let binding = makeBinding(
                        logicalRoot: fixture.contextA.rootURL,
                        worktreeRoot: missingWorktree,
                        suffix: "missing"
                    )
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(
                            selectedPaths: [fixture.contextA.fileURL.path],
                            codemapAutoEnabled: false
                        ),
                        bindings: [binding]
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)
                    installOracleCapture(capture, on: fixture.contextA.window)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Inspect the unavailable worktree."],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(response.rawJSON.contains("worktree projection is unavailable"), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains(missingWorktree.standardizedFileURL.path), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains(canonicalSentinel), response.rawJSON)
                    XCTAssertFalse(capture.wasInvoked)

                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleFailsClosedWhenFrozenBindingStateIsUnhydrated() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let canonicalSentinel = "canonical_oracle_unhydrated_must_not_leak"
                    try write("let value = \"\(canonicalSentinel)\"\n", to: fixture.contextA.fileURL)
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(
                            selectedPaths: [fixture.contextA.fileURL.path],
                            codemapAutoEnabled: false
                        ),
                        bindings: [],
                        bindingState: .unhydrated
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)
                    installOracleCapture(capture, on: fixture.contextA.window)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Inspect the unknown worktree state."],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(response.rawJSON.contains("bindings are not hydrated or are unavailable"), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains(canonicalSentinel), response.rawJSON)
                    XCTAssertFalse(capture.wasInvoked)

                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private func installOracleCapture(
            _ capture: OracleWorktreeCapture,
            on window: WindowState,
            gitInclusion: GitInclusion = .none
        ) {
            window.mcpServer.setOracleChatSendOverrideForTesting { args, promptVM, tabContext in
                let context = try XCTUnwrap(tabContext)
                if gitInclusion != .none {
                    promptVM.gitViewModel.selectedDiffBranch = "missing/live-ui-base"
                    XCTAssertEqual(context.packaging.reviewGitContext.compareIntent, .uncommittedHEAD)
                }
                let config = PromptContextResolved(
                    includeFiles: true,
                    includeUserPrompt: true,
                    includeMetaPrompts: false,
                    includeFileTree: true,
                    fileTreeMode: .auto,
                    codeMapUsage: .none,
                    gitInclusion: gitInclusion,
                    storedPromptIds: []
                )
                let message = await promptVM.packagePrompt(
                    conversation: [
                        ConversationEntry(
                            role: .user,
                            content: args["message"]?.stringValue ?? ""
                        )
                    ],
                    overridePromptConfig: config,
                    overrideMode: gitInclusion == .none ? .chat : .review,
                    selectionOverride: context.packaging.selection,
                    lookupContextOverride: context.packaging.lookupContext,
                    reviewGitContextOverride: context.packaging.reviewGitContext
                )
                capture.record(
                    tabContext: context,
                    fileTree: message.fileTree,
                    fileBlocks: message.fileBlocks,
                    gitDiff: message.gitDiff
                )
                return [
                    "chat_id": .string(UUID().uuidString),
                    "short_id": .string("oracle-capture"),
                    "mode": .string("chat"),
                    "response": .string("captured oracle response")
                ]
            }
        }

        private func makeFrozenContext(
            fixture: PersistentMCPTestFixture,
            selection: StoredSelection,
            bindings: [AgentSessionWorktreeBinding],
            bindingState: AgentSessionWorktreeBindingState? = nil
        ) -> MCPServerViewModel.TabContextSnapshot {
            MCPServerViewModel.TabContextSnapshot(
                tabID: fixture.contextA.tabID,
                windowID: fixture.contextA.window.windowID,
                workspaceID: fixture.contextA.workspaceID,
                promptText: "Oracle worktree prompt",
                selection: selection,
                selectedMetaPromptIDs: [],
                tabName: "Oracle Worktree",
                runID: UUID(),
                activeAgentSessionID: UUID(),
                worktreeBindings: bindings,
                worktreeBindingState: bindingState,
                explicitlyBound: false
            )
        }

        private func configureAgentModeEndpoint(
            _ endpoint: PersistentMCPTestEndpoint,
            context: MCPServerViewModel.TabContextSnapshot,
            fixture: PersistentMCPTestFixture
        ) async throws {
            _ = try await endpoint.callTool(
                name: "bind_context",
                arguments: ["op": "bind", "context_id": context.tabID.uuidString]
            )
            await fixture.networkManager.setRunPurpose(.agentModeRun, for: endpoint.connectionID)
            try await fixture.networkManager.debugSeedConnectionRunRouting(
                connectionID: endpoint.connectionID,
                runID: XCTUnwrap(context.runID),
                purpose: .agentModeRun,
                windowID: context.windowID
            )
            await fixture.networkManager.debugSetAdditionalTools(
                for: endpoint.connectionID,
                additionalTools: [MCPWindowToolName.askOracle]
            )
            var canonicalTab = try XCTUnwrap(
                fixture.contextA.window.workspaceManager.composeTab(with: context.tabID)
            )
            canonicalTab.selection = context.selection
            fixture.contextA.window.workspaceManager.updateComposeTab(canonicalTab, markDirty: false)
            fixture.contextA.window.mcpServer.installFrozenTabContext(
                clientID: endpoint.connectionID.uuidString,
                clientName: endpoint.clientName,
                context: context
            )
        }

        private func activateWorkspace(_ context: PersistentMCPTestContext) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            await context.window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "MCPAskOracleWorktreeTests"
            )
            let activeWorkspace = try XCTUnwrap(context.window.workspaceManager.activeWorkspace)
            context.window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        }

        private func writeGitArtifactManifest(
            to url: URL,
            snapshotID: String,
            repoKey: String,
            repoRoot: URL,
            layout: GitRepositoryLayout,
            tabID: UUID
        ) throws {
            let manifest = GitDiffSnapshotManifest(
                snapshotID: snapshotID,
                generatedAt: Date(timeIntervalSince1970: 1),
                mode: .standard,
                compare: "HEAD",
                compareInput: nil,
                scope: .selected,
                requestedPaths: ["Sources/Feature.swift"],
                fingerprint: GitDiffFingerprint(
                    headSHA: "abc",
                    baseRef: "HEAD",
                    statusHash: "status",
                    generatedAt: Date(timeIntervalSince1970: 1)
                ),
                contextLines: 3,
                detectRenames: false,
                summary: GitDiffSnapshotManifest.Summary(files: 1, insertions: 1, deletions: 0),
                files: [],
                repoKey: repoKey,
                repoRoot: repoRoot.path,
                isWorktree: true,
                worktreeName: repoRoot.lastPathComponent,
                worktreeRoot: repoRoot.path,
                mainWorktreeRoot: layout.knownMainWorktreeRoot?.path,
                commonGitDir: layout.commonDir.path,
                tabID: tabID
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try write(
                XCTUnwrap(try String(data: encoder.encode(manifest), encoding: .utf8)),
                to: url
            )
        }

        private func requireSelectedPath(
            suffix: String,
            in selection: StoredSelection,
            context: String,
            toolOutput: String? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws -> String {
            try XCTUnwrap(
                selection.selectedPaths.first { $0.hasSuffix(suffix) },
                missingSelectedPathDiagnostic(
                    suffix: suffix,
                    selection: selection,
                    context: context,
                    toolOutput: toolOutput
                ),
                file: file,
                line: line
            )
        }

        private func missingSelectedPathDiagnostic(
            suffix: String,
            selection: StoredSelection,
            context: String,
            toolOutput: String?
        ) -> String {
            var message = "Missing selected path suffix \(suffix) during \(context)."
            message += "\nSelected paths:\n"
            message += selection.selectedPaths.sorted().joined(separator: "\n")
            if let toolOutput, !toolOutput.isEmpty {
                message += "\nGit tool output:\n"
                message += truncatedDiagnostic(toolOutput)
            }
            return message
        }

        private func truncatedDiagnostic(_ text: String, limit: Int = 6000) -> String {
            guard text.count > limit else { return text }
            return String(text.prefix(limit))
                + "\n… truncated \(text.count - limit) additional characters"
        }

        private func cleanupSyntheticMCPRoutingForOracleTest(
            window: WindowState,
            sessionIDs: [UUID],
            runIDs: [UUID],
            connections: [SyntheticMCPConnectionCleanup]
        ) async {
            var seenConnections = Set<UUID>()
            let uniqueConnections = connections.filter { cleanup in
                seenConnections.insert(cleanup.connectionID).inserted
            }
            for connection in uniqueConnections {
                window.mcpServer.removeTabContext(
                    forConnectionID: connection.connectionID,
                    clientName: connection.clientName,
                    windowID: window.windowID,
                    runID: connection.runID
                )
            }

            var seenSessionIDs = Set<UUID>()
            let uniqueSessionIDs = sessionIDs.filter { seenSessionIDs.insert($0).inserted }
            let materializer = WorkspaceRootBindingProjectionMaterializer(
                store: window.workspaceFileContextStore
            )
            for sessionID in uniqueSessionIDs {
                await materializer.release(sessionID: sessionID)
            }

            var seenRunIDs = Set<UUID>()
            let uniqueRunIDs = runIDs.filter { seenRunIDs.insert($0).inserted }
            for runID in uniqueRunIDs {
                await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
                await ServerNetworkManager.shared.cleanupRunRoutingState(
                    for: runID,
                    windowID: window.windowID
                )
                await AgentRunCoordinator.shared.cleanupRouting(runID: runID)
            }

            for connection in uniqueConnections {
                await ServerNetworkManager.shared.debugRemoveConnection(connection.connectionID)
                await ServerNetworkManager.shared.clearClientConnectionPolicy(
                    for: connection.clientName,
                    windowID: window.windowID,
                    runID: connection.runID
                )
                await ServerNetworkManager.shared.debugClearPersistedRoutingState(
                    for: connection.clientName
                )
            }
        }

        private func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return content.compactMap { $0["text"] as? String }.joined()
        }

        private func makeAgentMCPControlContext(
            sessionID: UUID
        ) -> AgentModeViewModel.AgentMCPControlContext {
            AgentModeViewModel.AgentMCPControlContext(
                sessionID: sessionID,
                activationID: UUID(),
                registration: .init(sessionID: sessionID, generation: 0),
                currentEpoch: nil,
                preparedEpoch: nil,
                pendingEpochTransition: nil,
                originatingConnectionID: nil,
                interactionTransport: .mcp(
                    sessionID: sessionID,
                    originatingConnectionID: nil
                ),
                suppressUserNotifications: false,
                forceAutoEditEnabled: false,
                autoEditEnabledBeforeOverride: true,
                taskLabelKind: .pair
            )
        }

        private func makeBinding(
            logicalRoot: URL,
            worktreeRoot: URL,
            suffix: String
        ) -> AgentSessionWorktreeBinding {
            AgentSessionWorktreeBinding(
                id: "binding-\(suffix)",
                repositoryID: "repo-\(suffix)",
                repoKey: logicalRoot.path,
                logicalRootPath: logicalRoot.path,
                logicalRootName: logicalRoot.lastPathComponent,
                worktreeID: "worktree-\(suffix)",
                worktreeRootPath: worktreeRoot.path,
                worktreeName: worktreeRoot.lastPathComponent,
                branch: "feature/\(suffix)",
                source: "test"
            )
        }

        private func makeTemporaryRoot(name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPAskOracleWorktreeTests", isDirectory: true)
                .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url.standardizedFileURL
        }

        private func write(_ content: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        private func waitUntil(
            timeout: Duration = .seconds(2),
            condition: @MainActor () -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return condition()
        }
    }

    private enum ProductionOracleRepositoryKind: String {
        case canonical
        case linkedWorktree
        case visibleLinkedWorktree
    }

    private struct SyntheticMCPConnectionCleanup {
        let connectionID: UUID
        let clientName: String
        let runID: UUID?
    }

    @MainActor
    private final class OracleReviewPackagingTraceCapture {
        struct Turn {
            let correlationID: UUID
            var frozen: OracleReviewPackagingFrozenSnapshot?
            var preassembly: OracleReviewPackagingPreassemblySnapshot?
            var submission: OracleReviewPackagingSubmissionSnapshot?
            var failureType: String?
        }

        private var order: [UUID] = []
        private var turnsByID: [UUID: Turn] = [:]

        func record(_ event: OracleReviewPackagingTraceEvent) {
            let correlationID: UUID
            switch event {
            case let .contextFrozen(id, snapshot):
                correlationID = id
                ensureTurn(id)
                turnsByID[id]?.frozen = snapshot
            case let .preassemblyCompleted(id, snapshot):
                correlationID = id
                ensureTurn(id)
                turnsByID[id]?.preassembly = snapshot
            case let .messageSubmitted(id, snapshot):
                correlationID = id
                ensureTurn(id)
                turnsByID[id]?.submission = snapshot
            case let .failedOrCancelled(id, errorType):
                correlationID = id
                ensureTurn(id)
                turnsByID[id]?.failureType = errorType
            }
            precondition(turnsByID[correlationID] != nil)
        }

        func completedTurns() -> [Turn] {
            order.compactMap { turnsByID[$0] }
        }

        private func ensureTurn(_ id: UUID) {
            guard turnsByID[id] == nil else { return }
            order.append(id)
            turnsByID[id] = Turn(correlationID: id)
        }
    }

    @MainActor
    private final class OracleReviewTransportCapture {
        private(set) var messages: [AIMessage] = []
        private(set) var models: [AIModel] = []
        private(set) var serializedUserContents: [String] = []
        private(set) var serializedGitDiffFingerprints:
            [OracleReviewPackagingContentFingerprint] = []

        func record(
            message: AIMessage,
            model: AIModel,
            serializedMessages: [CompletionParams.Message]
        ) {
            messages.append(message)
            models.append(model)
            let serializedUserContent = Self.serializedUserContent(
                from: serializedMessages
            )
            serializedUserContents.append(serializedUserContent ?? "")
            serializedGitDiffFingerprints.append(
                OracleReviewPackagingDiagnostics.fingerprint(
                    serializedUserContent.flatMap(Self.serializedGitDiff)
                )
            )
        }

        private static func serializedUserContent(
            from messages: [CompletionParams.Message]
        ) -> String? {
            guard let userMessage = messages.reversed().first(where: {
                $0.role == .user
            }),
                case let .text(content) = userMessage.content
            else { return nil }
            return content
        }

        private static func serializedGitDiff(from content: String) -> String? {
            guard let open = content.range(of: "<git_diff>\n"),
                  let close = content.range(
                      of: "\n</git_diff>",
                      range: open.upperBound ..< content.endIndex
                  )
            else { return nil }
            return String(content[open.upperBound ..< close.lowerBound])
        }
    }

    private actor OracleAutomaticProviderCounter {
        private var count = 0
        private var selectedPaths: [String] = []

        func recordInvocation(_ request: AutomaticReviewGitDiffRequest? = nil) {
            count += 1
            if let request {
                selectedPaths = request.pathResolution.paths
            }
        }

        func invocationCount() -> Int {
            count
        }

        func lastSelectedPaths() -> [String] {
            selectedPaths
        }
    }

    private actor ExplicitWindowRoutingHintCapture {
        private var hints: [MCPExplicitWindowRoutingHint?] = []

        func record(_ hint: MCPExplicitWindowRoutingHint?) {
            hints.append(hint)
        }

        func snapshot() -> [MCPExplicitWindowRoutingHint?] {
            hints
        }
    }

    @MainActor
    private final class OracleWorktreeCapture {
        private(set) var wasInvoked = false
        private(set) var tabContext: OracleViewModel.OracleSendTabContext?
        private(set) var fileTree = ""
        private(set) var fileBlocks: [String] = []
        private(set) var gitDiff: String?

        func record(
            tabContext: OracleViewModel.OracleSendTabContext,
            fileTree: String,
            fileBlocks: [String],
            gitDiff: String?
        ) {
            wasInvoked = true
            self.tabContext = tabContext
            self.fileTree = fileTree
            self.fileBlocks = fileBlocks
            self.gitDiff = gitDiff
        }
    }

    private enum OracleWorktreeTestError: LocalizedError {
        case autoSelectionDidNotStart(readDiagnostic: String)

        var errorDescription: String? {
            switch self {
            case let .autoSelectionDidNotStart(readDiagnostic):
                "read_file auto-selection did not start within 2 seconds. read_file result: " + readDiagnostic
            }
        }
    }

    private actor OracleWorktreeGate {
        private var started = false
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            started = true
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted(timeout: Duration = .seconds(2)) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !started, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            return started
        }

        func release() {
            guard !released else { return }
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
#endif
