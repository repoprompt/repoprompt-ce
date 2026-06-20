import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    @MainActor
    final class ContextBuilderWorktreeInheritanceTests: XCTestCase {
        func testAgentModeContextBuilderUsesFrozenWorktreeAcrossNestedToolsAccountingAndFollowUps() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let state = ContextBuilderWorktreeProbeState()
                let factory = ContextBuilderWorktreeProbeFactory(state: state)
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    contextBuilderProviderFactory: factory.makeProvider
                )
                do {
                    try await activateWorkspace(fixture.contextA)
                    let logicalRoot = fixture.contextA.rootURL
                    let logicalFile = fixture.contextA.fileURL
                    let gitFixture = try ReviewGitRepositoryFixture(name: "ContextBuilderPublishedWorktree")
                    _ = try gitFixture.runGit(["init"], at: logicalRoot)
                    _ = try gitFixture.runGit(["config", "user.name", "RepoPrompt Test"], at: logicalRoot)
                    _ = try gitFixture.runGit(["config", "user.email", "repoprompt@example.test"], at: logicalRoot)
                    _ = try gitFixture.runGit(["config", "commit.gpgSign", "false"], at: logicalRoot)
                    _ = try gitFixture.runGit(["add", "."], at: logicalRoot)
                    _ = try gitFixture.runGit(["commit", "-m", "Initial commit"], at: logicalRoot)
                    let worktreeRoot = try gitFixture.makeLinkedWorktree(
                        from: logicalRoot,
                        named: "worktree",
                        branch: "feature/context-builder"
                    )
                    let worktreeFile = worktreeRoot
                        .appendingPathComponent("Sources", isDirectory: true)
                        .appendingPathComponent(logicalFile.lastPathComponent)
                    let canonicalSentinel = "CanonicalContextBuilderType"
                    let worktreeSentinel = "WorktreeContextBuilderType"
                    try write(
                        "struct \(canonicalSentinel) { func canonicalOnly() {} }\n",
                        to: logicalFile
                    )
                    try write(
                        "struct \(worktreeSentinel) { func worktreeOnly() {} }\n",
                        to: worktreeFile
                    )
                    try write(
                        "struct BranchOnlyContextBuilderType {}\n",
                        to: worktreeRoot.appendingPathComponent("Sources/BranchOnly.swift")
                    )

                    let sessionID = UUID()
                    let parentRunID = UUID()
                    let binding = try makeGitBinding(
                        logicalRoot: logicalRoot,
                        worktreeRoot: worktreeRoot,
                        suffix: "context-builder"
                    )
                    let selectionIdentity = WorkspaceSelectionIdentity(
                        workspaceID: fixture.contextA.workspaceID,
                        tabID: fixture.contextA.tabID
                    )
                    let sourceSelection = StoredSelection(
                        selectedPaths: [logicalFile.path],
                        codemapAutoEnabled: false
                    )
                    let selectionRevisionBeforeSeed = fixture.contextA.window.workspaceManager
                        .selectionRevisionForMCP(
                            workspaceID: selectionIdentity.workspaceID,
                            tabID: selectionIdentity.tabID
                        )
                    let persistedSelection = await fixture.contextA.window.selectionCoordinator.persistSelection(
                        sourceSelection,
                        for: selectionIdentity,
                        source: .mcpTabContext,
                        mirrorToUIIfActive: true
                    )
                    XCTAssertEqual(persistedSelection, sourceSelection)
                    let sourceSelectionRevision = fixture.contextA.window.workspaceManager.selectionRevisionForMCP(
                        workspaceID: selectionIdentity.workspaceID,
                        tabID: selectionIdentity.tabID
                    )
                    XCTAssertGreaterThan(sourceSelectionRevision, selectionRevisionBeforeSeed)
                    var composeTab = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(for: selectionIdentity)
                    )
                    composeTab.promptText = "Inspect the worktree implementation"
                    fixture.contextA.window.workspaceManager.updateComposeTab(composeTab, markDirty: false)
                    let storedAfterSeed = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(for: selectionIdentity)
                    )
                    XCTAssertEqual(storedAfterSeed.promptText, composeTab.promptText)
                    XCTAssertEqual(storedAfterSeed.selection, sourceSelection)

                    let flushedSourceSnapshot = try XCTUnwrap(
                        fixture.contextA.window.selectionCoordinator.selectionSnapshot(
                            for: selectionIdentity,
                            flushPendingUIIfActive: true
                        )
                    )
                    XCTAssertEqual(flushedSourceSnapshot.selection, sourceSelection)
                    let frozenComposeTab = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(for: selectionIdentity)
                    )
                    XCTAssertEqual(frozenComposeTab.selection, sourceSelection)
                    XCTAssertEqual(
                        fixture.contextA.window.workspaceManager.selectionRevisionForMCP(
                            workspaceID: selectionIdentity.workspaceID,
                            tabID: selectionIdentity.tabID
                        ),
                        sourceSelectionRevision
                    )
                    let frozenContext = MCPServerViewModel.TabContextSnapshot(
                        tabID: fixture.contextA.tabID,
                        windowID: fixture.contextA.window.windowID,
                        workspaceID: fixture.contextA.workspaceID,
                        promptText: frozenComposeTab.promptText,
                        selection: frozenComposeTab.selection,
                        selectionRevision: sourceSelectionRevision,
                        selectedMetaPromptIDs: frozenComposeTab.selectedMetaPromptIDs,
                        selectedContextBuilderPromptIDs: frozenComposeTab.contextBuilder.selectedContextBuilderPromptIDs,
                        tabName: frozenComposeTab.name,
                        runID: parentRunID,
                        activeAgentSessionID: sessionID,
                        worktreeBindings: [binding],
                        explicitlyBound: false
                    )
                    let outerEndpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        outerEndpoint,
                        context: frozenContext,
                        fixture: fixture
                    )

                    _ = try await outerEndpoint.callTool(
                        name: MCPWindowToolName.git,
                        arguments: [
                            "op": "diff",
                            "repo_root": logicalRoot.path,
                            "scope": "all",
                            "detail": "patches",
                            "artifacts": true,
                            "mode": "deep"
                        ],
                        timeoutSeconds: 30
                    )
                    let publishedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(for: selectionIdentity)
                    ).selection
                    let mapPath = try XCTUnwrap(
                        publishedSelection.selectedPaths.first { $0.hasSuffix("/MAP.txt") }
                    )
                    let patchPath = try XCTUnwrap(
                        publishedSelection.selectedPaths.first { $0.hasSuffix("/diff/all.patch") }
                    )
                    let publishedPatch = try String(contentsOfFile: patchPath, encoding: .utf8)
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
                    XCTAssertEqual(
                        Set(publishedSelection.selectedPaths),
                        Set([logicalFile.path, mapPath, patchPath])
                    )
                    XCTAssertTrue(publishedSelection.slices.isEmpty)
                    XCTAssertTrue(publishedSelection.autoCodemapPaths.isEmpty)
                    XCTAssertFalse(publishedSelection.codemapAutoEnabled)
                    let publishedSelectionRevision = fixture.contextA.window.workspaceManager
                        .selectionRevisionForMCP(
                            workspaceID: selectionIdentity.workspaceID,
                            tabID: selectionIdentity.tabID
                        )
                    XCTAssertGreaterThan(publishedSelectionRevision, sourceSelectionRevision)
                    let flushedPublishedSnapshot = try XCTUnwrap(
                        fixture.contextA.window.selectionCoordinator.selectionSnapshot(
                            for: selectionIdentity,
                            flushPendingUIIfActive: true
                        )
                    )
                    XCTAssertEqual(flushedPublishedSnapshot.selection, publishedSelection)
                    XCTAssertEqual(
                        fixture.contextA.window.workspaceManager.composeTab(for: selectionIdentity)?.selection,
                        publishedSelection
                    )
                    XCTAssertEqual(
                        fixture.contextA.window.workspaceManager.selectionRevisionForMCP(
                            workspaceID: selectionIdentity.workspaceID,
                            tabID: selectionIdentity.tabID
                        ),
                        publishedSelectionRevision
                    )
                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting { _ in
                            AutomaticReviewGitDiffResult(
                                text: "AUTOMATIC_FALLBACK_INVOKED",
                                completeness: .complete,
                                outcomes: [],
                                pathIssues: []
                            )
                        }

                    factory.configure(
                        networkManager: fixture.networkManager,
                        logicalFilePath: logicalFile.path,
                        searchPattern: worktreeSentinel
                    )

                    fixture.contextA.window.mcpServer.setContextBuilderSelectionReplyObserverForTesting {
                        selection, lookupContext, reply in
                        state.recordAccounting(
                            selection: selection,
                            lookupContext: lookupContext,
                            totalTokens: reply.totalTokens ?? 0
                        )
                    }
                    fixture.contextA.window.mcpServer.setContextBuilderFollowUpOverrideForTesting {
                        _, tabID, agentModeSessionID, agentModeRunID, mode, prompt, selection, lookupContext, reviewGitContext, _, _ in
                        XCTAssertEqual(agentModeSessionID, sessionID)
                        XCTAssertEqual(agentModeRunID, parentRunID)
                        XCTAssertEqual(reviewGitContext.compareIntent, .uncommittedHEAD)
                        XCTAssertEqual(
                            reviewGitContext.displayContext.roots.first?.physicalRootPath,
                            worktreeRoot.standardizedFileURL.path
                        )
                        let message = await fixture.contextA.window.promptManager.buildHeadlessAIMessage(
                            from: HeadlessContextSnapshot(
                                tabID: tabID,
                                promptText: prompt,
                                selection: selection,
                                lookupContext: lookupContext,
                                reviewGitContext: reviewGitContext
                            ),
                            model: fixture.contextA.window.promptManager.preferredAIModel,
                            mode: mode
                        )
                        state.recordFollowUp(
                            mode: mode,
                            fileTree: message.fileTree,
                            fileBlocks: message.fileBlocks,
                            gitDiff: message.gitDiff,
                            selection: selection,
                            lookupContext: lookupContext
                        )
                        return ChatSendReply(
                            chatId: UUID(),
                            shortId: "cb-\(mode.mcpModeName)",
                            mode: mode.mcpModeName,
                            response: "generated \(mode.mcpModeName)",
                            errors: nil
                        )
                    }
                    defer {
                        fixture.contextA.window.mcpServer.setContextBuilderFollowUpOverrideForTesting(nil)
                        fixture.contextA.window.mcpServer.setContextBuilderSelectionReplyObserverForTesting(nil)
                    }

                    let logicalRelativeFilePath = String(
                        logicalFile.standardizedFileURL.path.dropFirst(logicalRoot.standardizedFileURL.path.count)
                    ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let expectedPublishedPaths = Set([logicalFile.path, mapAlias, patchAlias])
                    for (runIndex, responseType) in ["plan", "review"].enumerated() {
                        let response = try await outerEndpoint.callTool(
                            name: MCPWindowToolName.contextBuilder,
                            arguments: [
                                "instructions": "Inspect the selected implementation.",
                                "response_type": responseType
                            ],
                            timeoutSeconds: 45
                        )
                        let text = try toolResultText(response)
                        XCTAssertTrue(text.contains("generated \(responseType)"), text)
                        XCTAssertTrue(text.contains(logicalFile.lastPathComponent), text)
                        XCTAssertFalse(text.contains(canonicalSentinel), text)
                        XCTAssertEqual(
                            state.runs.count,
                            runIndex + 1,
                            "response_type=\(responseType) expected exactly one new probe run; runs=\(state.runs.count)"
                        )
                        guard state.runs.indices.contains(runIndex) else { continue }
                        let run = state.runs[runIndex]
                        let runDiagnostics = "response_type=\(responseType) run_index=\(runIndex) \(run.selectionBeforeRead.diagnosticDescription)"
                        XCTAssertEqual(
                            Set(run.selectionBeforeRead.fullPaths),
                            expectedPublishedPaths,
                            runDiagnostics
                        )
                        XCTAssertTrue(run.selectionBeforeRead.slicePaths.isEmpty, runDiagnostics)
                        XCTAssertTrue(
                            Set(run.selectionBeforeRead.invalidPaths).isDisjoint(with: expectedPublishedPaths),
                            runDiagnostics
                        )
                        let sourceObservation = try XCTUnwrap(
                            run.selectionBeforeRead.files.first { $0.path == logicalFile.path },
                            runDiagnostics
                        )
                        XCTAssertEqual(sourceObservation.renderMode, "full", runDiagnostics)
                        XCTAssertEqual(
                            sourceObservation.rootPath,
                            logicalRoot.standardizedFileURL.path,
                            runDiagnostics
                        )
                        XCTAssertEqual(
                            sourceObservation.pathWithinRoot,
                            logicalRelativeFilePath,
                            runDiagnostics
                        )
                        XCTAssertEqual(
                            run.selectionBeforeRead.files.first { $0.path == mapAlias }?.renderMode,
                            "full",
                            runDiagnostics
                        )
                        XCTAssertEqual(
                            run.selectionBeforeRead.files.first { $0.path == patchAlias }?.renderMode,
                            "full",
                            runDiagnostics
                        )
                        XCTAssertEqual(
                            run.selectionAfterRead,
                            run.selectionBeforeRead,
                            "response_type=\(responseType) selection changed after read; before=\(run.selectionBeforeRead.diagnosticDescription) after=\(run.selectionAfterRead.diagnosticDescription)"
                        )
                    }

                    let runs = state.runs
                    XCTAssertEqual(runs.count, 2)
                    for run in runs {
                        XCTAssertEqual(run.workspacePath, worktreeRoot.standardizedFileURL.path)
                        XCTAssertTrue(run.userMessage.contains("BranchOnly.swift"), run.userMessage)
                        XCTAssertFalse(run.userMessage.contains(canonicalSentinel), run.userMessage)
                        XCTAssertFalse(run.userMessage.contains(worktreeRoot.path), run.userMessage)
                        for output in [run.tree, run.read, run.search, run.codeStructure, run.selection, run.workspaceContext] {
                            XCTAssertFalse(output.contains(canonicalSentinel), output)
                            XCTAssertFalse(output.contains(worktreeRoot.path), output)
                        }
                        XCTAssertTrue(run.tree.contains("BranchOnly.swift"), run.tree)
                        XCTAssertTrue(run.read.contains(worktreeSentinel), run.read)
                        XCTAssertTrue(run.search.contains(worktreeSentinel), run.search)
                        if run.codeStructure.contains("Codemap generation pending") {
                            XCTAssertTrue(run.codeStructure.contains("Files with codemap**: 0"), run.codeStructure)
                            XCTAssertTrue(run.codeStructure.contains("### Files still awaiting codemap"), run.codeStructure)
                            assertLogicalPath(logicalRelativeFilePath, in: run.codeStructure)
                            XCTAssertFalse(run.codeStructure.contains(worktreeSentinel), run.codeStructure)
                        } else {
                            XCTAssertFalse(run.codeStructure.contains("Without codemap"), run.codeStructure)
                            XCTAssertTrue(run.codeStructure.contains(worktreeSentinel), run.codeStructure)
                        }
                        XCTAssertTrue(run.selection.contains(logicalFile.lastPathComponent), run.selection)
                        XCTAssertTrue(run.workspaceContext.contains(logicalFile.lastPathComponent), run.workspaceContext)
                        XCTAssertTrue(run.workspaceContext.contains("session-bound worktree"), run.workspaceContext)
                    }

                    let followUps = state.followUps
                    XCTAssertEqual(followUps.map(\.mode), ["plan", "review"])
                    for followUp in followUps {
                        let packaged = followUp.fileBlocks.joined(separator: "\n")
                        XCTAssertTrue(packaged.contains(worktreeSentinel), packaged)
                        XCTAssertFalse(packaged.contains(canonicalSentinel), packaged)
                        let nonMapBlocks = followUp.fileBlocks
                            .filter { !$0.contains(mapAlias) }
                            .joined(separator: "\n")
                        XCTAssertFalse(nonMapBlocks.contains(worktreeRoot.path), nonMapBlocks)
                        XCTAssertFalse(followUp.fileTree.contains(worktreeRoot.path), followUp.fileTree)
                        XCTAssertEqual(
                            Set(followUp.selection.selectedPaths),
                            Set([logicalFile.path, mapPath, patchPath])
                        )
                        XCTAssertEqual(
                            followUp.fileBlocks.count(where: { $0.contains(mapAlias) }),
                            1,
                            packaged
                        )
                        XCTAssertFalse(
                            followUp.fileBlocks.contains { $0.contains("<path>\(patchAlias)</path>") },
                            packaged
                        )
                        XCTAssertNotNil(followUp.lookupContext?.bindingProjection)
                    }
                    let planFollowUp = try XCTUnwrap(
                        followUps.first { $0.mode == "plan" },
                        "Expected plan follow-up; recorded modes=\(followUps.map(\.mode))"
                    )
                    let reviewFollowUp = try XCTUnwrap(
                        followUps.first { $0.mode == "review" },
                        "Expected review follow-up; recorded modes=\(followUps.map(\.mode))"
                    )
                    XCTAssertEqual(planFollowUp.gitDiff, publishedPatch)
                    XCTAssertEqual(reviewFollowUp.gitDiff, publishedPatch)
                    XCTAssertTrue(followUps.allSatisfy {
                        $0.gitDiff != "AUTOMATIC_FALLBACK_INVOKED"
                    })
                    XCTAssertFalse(reviewFollowUp.gitDiff?.contains(worktreeRoot.path) ?? true)
                    XCTAssertFalse(reviewFollowUp.gitDiff?.contains(canonicalSentinel) ?? true)

                    let lookupContext = try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
                        source: AgentWorkspaceLookupContextSource(
                            activeAgentSessionID: sessionID,
                            worktreeBindings: [binding]
                        ),
                        store: fixture.contextA.window.workspaceFileContextStore
                    )
                    let followUpSelection = try XCTUnwrap(followUps.first?.selection)
                    let expected = await fixture.contextA.window.mcpServer.buildTabSelectionReply(
                        from: followUpSelection,
                        includeBlocks: false,
                        display: .relative,
                        codeMapUsageOverride: .auto,
                        lookupContextOverride: lookupContext
                    )
                    XCTAssertEqual(
                        Set(expected.files?.compactMap(\.rootPath) ?? []),
                        Set([logicalRoot.standardizedFileURL.path])
                    )
                    let formattedSelection = ToolOutputFormatter.formatSelectionReplyToString(expected)
                    XCTAssertTrue(formattedSelection.contains(logicalRoot.standardizedFileURL.path), formattedSelection)
                    XCTAssertFalse(formattedSelection.contains(worktreeRoot.standardizedFileURL.path), formattedSelection)

                    let slicedSelection = StoredSelection(
                        selectedPaths: [logicalFile.path],
                        autoCodemapPaths: [],
                        slices: [logicalFile.path: [LineRange(start: 1, end: 1)]],
                        codemapAutoEnabled: false
                    )
                    let slicedReply = await fixture.contextA.window.mcpServer.buildTabSelectionReply(
                        from: slicedSelection,
                        includeBlocks: false,
                        display: .relative,
                        codeMapUsageOverride: .none,
                        lookupContextOverride: lookupContext
                    )
                    XCTAssertEqual(
                        Set(slicedReply.fileSlices?.compactMap(\.rootPath) ?? []),
                        Set([logicalRoot.standardizedFileURL.path])
                    )
                    let formattedSlices = ToolOutputFormatter.formatSelectionReplyToString(slicedReply)
                    XCTAssertTrue(formattedSlices.contains(logicalRoot.standardizedFileURL.path), formattedSlices)
                    XCTAssertFalse(formattedSlices.contains(worktreeRoot.standardizedFileURL.path), formattedSlices)

                    XCTAssertEqual(state.accounting.count, 2)
                    for accounting in state.accounting {
                        XCTAssertGreaterThan(accounting.totalTokens, 0)
                        XCTAssertEqual(
                            Set(accounting.selection.selectedPaths),
                            Set([logicalFile.path, mapPath, patchPath])
                        )
                        XCTAssertNotNil(accounting.lookupContext?.bindingProjection)
                    }
                    XCTAssertEqual(
                        state.accounting.map(\.selection),
                        state.followUps.map(\.selection),
                        "Selection replies and requested follow-ups must use the same committed snapshots"
                    )
                    XCTAssertEqual(
                        Set(fixture.contextA.window.workspaceManager.composeTab(for: selectionIdentity)?.selection.selectedPaths ?? []),
                        Set(publishedSelection.selectedPaths)
                    )
                    XCTAssertGreaterThanOrEqual(
                        fixture.contextA.window.workspaceManager.selectionRevisionForMCP(
                            workspaceID: selectionIdentity.workspaceID,
                            tabID: selectionIdentity.tabID
                        ),
                        publishedSelectionRevision
                    )

                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setContextBuilderSelectionReplyObserverForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setContextBuilderFollowUpOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setContextBuilderSelectionReplyObserverForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAgentModeContextBuilderFailsClosedBeforeProviderCreationWhenWorktreeIsUnavailable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let state = ContextBuilderWorktreeProbeState()
                let factory = ContextBuilderWorktreeProbeFactory(state: state)
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    contextBuilderProviderFactory: factory.makeProvider
                )
                do {
                    try await activateWorkspace(fixture.contextA)
                    let canonicalSentinel = "CanonicalUnavailableContextBuilderType"
                    try write(
                        "struct \(canonicalSentinel) { func canonicalOnly() {} }\n",
                        to: fixture.contextA.fileURL
                    )
                    let missingWorktree = fixture.rootURL.appendingPathComponent(
                        "missing-context-builder-worktree-\(UUID().uuidString)",
                        isDirectory: true
                    )
                    let binding = makeBinding(
                        logicalRoot: fixture.contextA.rootURL,
                        worktreeRoot: missingWorktree,
                        suffix: "missing-context-builder"
                    )
                    let frozenContext = MCPServerViewModel.TabContextSnapshot(
                        tabID: fixture.contextA.tabID,
                        windowID: fixture.contextA.window.windowID,
                        workspaceID: fixture.contextA.workspaceID,
                        promptText: "Inspect the unavailable worktree",
                        selection: StoredSelection(
                            selectedPaths: [fixture.contextA.fileURL.path],
                            codemapAutoEnabled: false
                        ),
                        selectedMetaPromptIDs: [],
                        tabName: "Unavailable Agent Context Builder",
                        runID: UUID(),
                        activeAgentSessionID: UUID(),
                        worktreeBindings: [binding],
                        explicitlyBound: false
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: frozenContext, fixture: fixture)
                    factory.configure(
                        networkManager: fixture.networkManager,
                        logicalFilePath: fixture.contextA.fileURL.path,
                        searchPattern: canonicalSentinel
                    )

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.contextBuilder,
                        arguments: ["instructions": "Inspect the unavailable worktree."],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(response.rawJSON.contains("worktree bindings could not be loaded"), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains(missingWorktree.standardizedFileURL.path), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains(canonicalSentinel), response.rawJSON)
                    XCTAssertEqual(state.providerCreationCount, 0)
                    XCTAssertTrue(state.runs.isEmpty)

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let state = ContextBuilderWorktreeProbeState()
                let factory = ContextBuilderWorktreeProbeFactory(state: state)
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    contextBuilderProviderFactory: factory.makeProvider
                )
                do {
                    try await activateWorkspace(fixture.contextA)
                    let store = fixture.contextA.window.workspaceFileContextStore
                    let loadedService = await store.fileSystemServiceForTesting(rootID: fixture.contextA.rootID)
                    let service = try XCTUnwrap(loadedService)
                    await service.stopWatchingForChanges()
                    let gitFixture = try ReviewGitRepositoryFixture(name: "ContextBuilderCanonicalPublication")
                    _ = try gitFixture.runGit(["init"], at: fixture.contextA.rootURL)
                    _ = try gitFixture.runGit(["config", "user.name", "RepoPrompt Test"], at: fixture.contextA.rootURL)
                    _ = try gitFixture.runGit(["config", "user.email", "repoprompt@example.test"], at: fixture.contextA.rootURL)
                    _ = try gitFixture.runGit(["config", "commit.gpgSign", "false"], at: fixture.contextA.rootURL)
                    _ = try gitFixture.runGit(["add", "."], at: fixture.contextA.rootURL)
                    _ = try gitFixture.runGit(["commit", "-m", "Initial commit"], at: fixture.contextA.rootURL)
                    let canonicalSentinel = "CanonicalNonAgentContextBuilderType"
                    try write(
                        "struct \(canonicalSentinel) { func canonicalMethod() {} }\n",
                        to: fixture.contextA.fileURL
                    )
                    let relativePath = "Sources/\(fixture.contextA.fileURL.lastPathComponent)"
                    await store.replayObservedFileSystemDeltas(
                        rootID: fixture.contextA.rootID,
                        deltas: [.fileModified(relativePath, Date())]
                    )
                    try await waitForCodemap(
                        in: store,
                        rootID: fixture.contextA.rootID,
                        relativePath: relativePath,
                        containing: canonicalSentinel
                    )
                    let sourceSelection = StoredSelection(
                        selectedPaths: [fixture.contextA.fileURL.path],
                        codemapAutoEnabled: false
                    )
                    var composeTab = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    )
                    composeTab.selection = sourceSelection
                    composeTab.promptText = "Review the canonical published change"
                    fixture.contextA.window.workspaceManager.updateComposeTab(composeTab, markDirty: false)

                    factory.configure(
                        networkManager: fixture.networkManager,
                        logicalFilePath: fixture.contextA.fileURL.path,
                        searchPattern: canonicalSentinel
                    )
                    let endpoint = try fixture.endpointA()
                    _ = try await endpoint.callTool(
                        name: "bind_context",
                        arguments: ["op": "bind", "context_id": fixture.contextA.tabID.uuidString]
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.git,
                        arguments: [
                            "op": "diff",
                            "repo_root": fixture.contextA.rootURL.path,
                            "scope": "selected",
                            "detail": "patches",
                            "artifacts": true,
                            "mode": "deep"
                        ],
                        timeoutSeconds: 30
                    )
                    let publishedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    ).selection
                    let mapPath = try XCTUnwrap(
                        publishedSelection.selectedPaths.first { $0.hasSuffix("/MAP.txt") }
                    )
                    let patchPath = try XCTUnwrap(
                        publishedSelection.selectedPaths.first { $0.hasSuffix("/diff/all.patch") }
                    )
                    let publishedPatch = try String(contentsOfFile: patchPath, encoding: .utf8)
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
                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting { _ in
                            AutomaticReviewGitDiffResult(
                                text: "AUTOMATIC_FALLBACK_INVOKED",
                                completeness: .complete,
                                outcomes: [],
                                pathIssues: []
                            )
                        }
                    fixture.contextA.window.mcpServer.setContextBuilderFollowUpOverrideForTesting {
                        _, tabID, _, _, mode, prompt, selection, lookupContext, reviewGitContext, _, _ in
                        let message = await fixture.contextA.window.promptManager.buildHeadlessAIMessage(
                            from: HeadlessContextSnapshot(
                                tabID: tabID,
                                promptText: prompt,
                                selection: selection,
                                lookupContext: lookupContext,
                                reviewGitContext: reviewGitContext
                            ),
                            model: fixture.contextA.window.promptManager.preferredAIModel,
                            mode: mode
                        )
                        state.recordFollowUp(
                            mode: mode,
                            fileTree: message.fileTree,
                            fileBlocks: message.fileBlocks,
                            gitDiff: message.gitDiff,
                            selection: selection,
                            lookupContext: lookupContext
                        )
                        return ChatSendReply(
                            chatId: UUID(),
                            shortId: "canonical-review",
                            mode: mode.mcpModeName,
                            response: "generated review",
                            errors: nil
                        )
                    }
                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.contextBuilder,
                        arguments: [
                            "instructions": "Inspect the canonical checkout.",
                            "context_id": fixture.contextA.tabID.uuidString,
                            "response_type": "review"
                        ],
                        timeoutSeconds: 45
                    )
                    let text = try toolResultText(response)
                    XCTAssertTrue(text.contains(fixture.contextA.fileURL.lastPathComponent), text)

                    let run = try XCTUnwrap(state.runs.first)
                    XCTAssertEqual(run.workspacePath, fixture.contextA.rootURL.standardizedFileURL.path)
                    XCTAssertTrue(run.read.contains(canonicalSentinel), run.read)
                    XCTAssertTrue(run.search.contains(canonicalSentinel), run.search)
                    XCTAssertTrue(run.codeStructure.contains(canonicalSentinel), run.codeStructure)

                    let followUp = try XCTUnwrap(state.followUps.first)
                    XCTAssertEqual(followUp.mode, "review")
                    XCTAssertEqual(followUp.gitDiff, publishedPatch)
                    XCTAssertNotEqual(followUp.gitDiff, "AUTOMATIC_FALLBACK_INVOKED")
                    XCTAssertEqual(
                        Set(followUp.selection.selectedPaths),
                        Set([fixture.contextA.fileURL.path, mapPath, patchPath])
                    )
                    XCTAssertEqual(
                        followUp.fileBlocks.count(where: { $0.contains(mapAlias) }),
                        1
                    )
                    XCTAssertFalse(
                        followUp.fileBlocks.contains { $0.contains("<path>\(patchAlias)</path>") }
                    )

                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setContextBuilderFollowUpOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setContextBuilderFollowUpOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private func waitForCodemap(
            in store: WorkspaceFileContextStore,
            rootID: UUID,
            relativePath: String,
            containing expectedText: String,
            timeout: Duration = .seconds(6)
        ) async throws {
            try await store.requestCodemapScan(rootID: rootID, relativePath: relativePath)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if let snapshot = await store.codemapSnapshot(rootID: rootID, relativePath: relativePath),
                   snapshot.fileAPI?.apiDescription.contains(expectedText) == true
                {
                    return
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("Timed out waiting for codemap containing \(expectedText)")
            throw NSError(domain: "ContextBuilderWorktreeInheritanceTests", code: 1)
        }

        private func activateWorkspace(_ context: PersistentMCPTestContext) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            await context.window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderWorktreeInheritanceTests"
            )
            let activeWorkspace = try XCTUnwrap(context.window.workspaceManager.activeWorkspace)
            context.window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
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
            fixture.contextA.window.mcpServer.installFrozenTabContext(
                clientID: endpoint.connectionID.uuidString,
                clientName: endpoint.clientName,
                context: context
            )
        }

        private func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return content.compactMap { $0["text"] as? String }.joined()
        }

        private func assertLogicalPath(_ logicalPath: String, in output: String) {
            let parts = logicalPath.split(separator: "/", maxSplits: 1).map(String.init)
            let root = parts.first ?? logicalPath
            let pathWithinRoot = parts.count > 1 ? parts[1] : logicalPath
            XCTAssertTrue(output.contains("- **\(root)**"), output)
            XCTAssertTrue(output.contains("  - `\(pathWithinRoot)`"), output)
        }

        private func makeGitBinding(
            logicalRoot: URL,
            worktreeRoot: URL,
            suffix: String
        ) throws -> AgentSessionWorktreeBinding {
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
            return AgentSessionWorktreeBinding(
                id: "binding-\(suffix)",
                repositoryID: repositoryIdentity.repositoryID,
                repoKey: logicalRoot.path,
                logicalRootPath: logicalRoot.path,
                logicalRootName: logicalRoot.lastPathComponent,
                worktreeID: worktreeID,
                worktreeRootPath: worktreeRoot.path,
                worktreeName: worktreeRoot.lastPathComponent,
                branch: "feature/\(suffix)",
                source: "test"
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
                .appendingPathComponent("ContextBuilderWorktreeInheritanceTests", isDirectory: true)
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
    }

    @MainActor
    private final class ContextBuilderWorktreeProbeFactory {
        private struct Configuration {
            let networkManager: ServerNetworkManager
            let logicalFilePath: String
            let searchPattern: String
        }

        private let state: ContextBuilderWorktreeProbeState
        private var configuration: Configuration?

        init(state: ContextBuilderWorktreeProbeState) {
            self.state = state
        }

        func configure(
            networkManager: ServerNetworkManager,
            logicalFilePath: String,
            searchPattern: String
        ) {
            configuration = Configuration(
                networkManager: networkManager,
                logicalFilePath: logicalFilePath,
                searchPattern: searchPattern
            )
        }

        func makeProvider(
            agent: AgentProviderKind,
            modelString: String?,
            workspacePath: String?
        ) -> HeadlessAgentProvider {
            _ = modelString
            state.recordProviderCreation()
            guard let configuration else {
                preconditionFailure("Context Builder probe provider used before configuration")
            }
            guard let clientName = agent.mcpClientNameHint else {
                preconditionFailure("Context Builder probe agent has no MCP client name")
            }
            return ContextBuilderWorktreeProbeProvider(
                state: state,
                networkManager: configuration.networkManager,
                logicalFilePath: configuration.logicalFilePath,
                searchPattern: configuration.searchPattern,
                clientName: clientName,
                workspacePath: workspacePath
            )
        }
    }

    private final class ContextBuilderWorktreeProbeProvider: HeadlessAgentProvider {
        private let state: ContextBuilderWorktreeProbeState
        private let networkManager: ServerNetworkManager
        private let logicalFilePath: String
        private let searchPattern: String
        private let clientName: String
        private let workspacePath: String?
        private var endpoint: PersistentMCPTestEndpoint?
        private var activeRunID: UUID?

        init(
            state: ContextBuilderWorktreeProbeState,
            networkManager: ServerNetworkManager,
            logicalFilePath: String,
            searchPattern: String,
            clientName: String,
            workspacePath: String?
        ) {
            self.state = state
            self.networkManager = networkManager
            self.logicalFilePath = logicalFilePath
            self.searchPattern = searchPattern
            self.clientName = clientName
            self.workspacePath = workspacePath
        }

        func streamAgentMessage(
            _ message: AgentMessage,
            runID: UUID?
        ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
            guard let runID else { throw CancellationError() }
            activeRunID = runID
            await networkManager.registerExpectedAgentPID(
                getpid(),
                for: clientName,
                runID: runID
            )
            let endpoint = try await PersistentMCPTestEndpoint.make(
                label: "context-builder-worktree-probe",
                networkManager: networkManager,
                clientName: clientName,
                requiredToolNames: [
                    MCPWindowToolName.getFileTree,
                    MCPWindowToolName.readFile,
                    MCPWindowToolName.search,
                    MCPWindowToolName.getCodeStructure,
                    MCPWindowToolName.manageSelection,
                    MCPWindowToolName.workspaceContext
                ]
            )
            self.endpoint = endpoint

            let selectionBeforeRead = try await selectionObservation(endpoint.callTool(
                name: MCPWindowToolName.manageSelection,
                arguments: [
                    "op": "get",
                    "view": "files",
                    "path_display": "full",
                    "_rawJSON": true
                ],
                timeoutSeconds: 20
            ))
            let tree = try await toolResultText(endpoint.callTool(
                name: MCPWindowToolName.getFileTree,
                arguments: [:],
                timeoutSeconds: 20
            ))
            let read = try await toolResultText(endpoint.callTool(
                name: MCPWindowToolName.readFile,
                arguments: ["path": logicalFilePath],
                timeoutSeconds: 20
            ))
            let selectionAfterRead = try await selectionObservation(endpoint.callTool(
                name: MCPWindowToolName.manageSelection,
                arguments: [
                    "op": "get",
                    "view": "files",
                    "path_display": "full",
                    "_rawJSON": true
                ],
                timeoutSeconds: 20
            ))
            let search = try await toolResultText(endpoint.callTool(
                name: MCPWindowToolName.search,
                arguments: [
                    "pattern": searchPattern,
                    "mode": "content",
                    "regex": false
                ],
                timeoutSeconds: 20
            ))
            let codeStructure = try await toolResultText(endpoint.callTool(
                name: MCPWindowToolName.getCodeStructure,
                arguments: [
                    "paths": [logicalFilePath]
                ],
                timeoutSeconds: 30
            ))
            let selection = try await toolResultText(endpoint.callTool(
                name: MCPWindowToolName.manageSelection,
                arguments: [
                    "op": "add",
                    "paths": [logicalFilePath],
                    "mode": "full"
                ],
                timeoutSeconds: 20
            ))
            let workspaceContext = try await toolResultText(endpoint.callTool(
                name: MCPWindowToolName.workspaceContext,
                arguments: [
                    "include": ["selection", "tree", "tokens"]
                ],
                timeoutSeconds: 30
            ))
            await state.recordRun(ContextBuilderWorktreeProbeState.Run(
                workspacePath: workspacePath,
                userMessage: message.userMessage,
                selectionBeforeRead: selectionBeforeRead,
                tree: tree,
                read: read,
                selectionAfterRead: selectionAfterRead,
                search: search,
                codeStructure: codeStructure,
                selection: selection,
                workspaceContext: workspaceContext
            ))

            return AsyncThrowingStream { continuation in
                continuation.yield(AIStreamResult(type: "content", text: "Context selected."))
                continuation.finish()
            }
        }

        func dispose() async {
            if let endpoint {
                endpoint.client.close()
                await endpoint.connectionManager.stop()
                await networkManager.debugRemoveConnection(endpoint.connectionID)
                await networkManager.clearClientConnectionPolicy(for: endpoint.clientName)
                await networkManager.debugClearPersistedRoutingState(for: endpoint.clientName)
            }
            if let activeRunID {
                await networkManager.clearExpectedAgentPID(
                    getpid(),
                    for: clientName,
                    runID: activeRunID
                )
            }
            endpoint = nil
            activeRunID = nil
        }

        private func selectionObservation(
            _ response: PersistentMCPTestRPCResponse
        ) throws -> ContextBuilderWorktreeProbeState.SelectionObservation {
            let text = try toolResultText(response)
            let data = try XCTUnwrap(text.data(using: .utf8))
            let reply = try JSONDecoder().decode(ToolResultDTOs.SelectionReply.self, from: data)
            return ContextBuilderWorktreeProbeState.SelectionObservation(
                files: (reply.files ?? []).map {
                    ContextBuilderWorktreeProbeState.FileObservation(
                        path: $0.path,
                        renderMode: $0.renderMode,
                        rootPath: $0.rootPath,
                        pathWithinRoot: $0.pathWithinRoot
                    )
                }.sorted { $0.path < $1.path },
                slicePaths: (reply.fileSlices ?? []).map(\.path).sorted(),
                invalidPaths: (reply.invalidPaths ?? []).sorted()
            )
        }

        private func toolResultText(
            _ response: PersistentMCPTestRPCResponse
        ) throws -> String {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return content.compactMap { $0["text"] as? String }.joined()
        }
    }

    @MainActor
    private final class ContextBuilderWorktreeProbeState {
        struct FileObservation: Equatable {
            let path: String
            let renderMode: String
            let rootPath: String?
            let pathWithinRoot: String?
        }

        struct SelectionObservation: Equatable {
            let files: [FileObservation]
            let slicePaths: [String]
            let invalidPaths: [String]

            var fullPaths: [String] {
                files.filter { $0.renderMode == "full" }.map(\.path)
            }

            var diagnosticDescription: String {
                "files=\(files) slices=\(slicePaths) invalid=\(invalidPaths)"
            }

            static let empty = SelectionObservation(files: [], slicePaths: [], invalidPaths: [])
        }

        struct Run {
            let workspacePath: String?
            let userMessage: String
            let selectionBeforeRead: SelectionObservation
            let tree: String
            let read: String
            let selectionAfterRead: SelectionObservation
            let search: String
            let codeStructure: String
            let selection: String
            let workspaceContext: String
        }

        struct FollowUp {
            let mode: String
            let fileTree: String
            let fileBlocks: [String]
            let gitDiff: String?
            let selection: StoredSelection
            let lookupContext: WorkspaceLookupContext?
        }

        struct Accounting {
            let selection: StoredSelection
            let lookupContext: WorkspaceLookupContext?
            let totalTokens: Int
        }

        private(set) var providerCreationCount = 0
        private(set) var runs: [Run] = []
        private(set) var followUps: [FollowUp] = []
        private(set) var accounting: [Accounting] = []

        func recordProviderCreation() {
            providerCreationCount += 1
        }

        func recordRun(_ run: Run) {
            runs.append(run)
        }

        func recordAccounting(
            selection: StoredSelection,
            lookupContext: WorkspaceLookupContext?,
            totalTokens: Int
        ) {
            accounting.append(Accounting(
                selection: selection,
                lookupContext: lookupContext,
                totalTokens: totalTokens
            ))
        }

        func recordFollowUp(
            mode: HeadlessMode,
            fileTree: String,
            fileBlocks: [String],
            gitDiff: String?,
            selection: StoredSelection,
            lookupContext: WorkspaceLookupContext?
        ) {
            followUps.append(FollowUp(
                mode: mode.mcpModeName,
                fileTree: fileTree,
                fileBlocks: fileBlocks,
                gitDiff: gitDiff,
                selection: selection,
                lookupContext: lookupContext
            ))
        }
    }
#endif
