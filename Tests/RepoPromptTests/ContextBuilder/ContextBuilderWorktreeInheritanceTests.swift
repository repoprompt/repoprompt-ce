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
                    let worktreeRoot = try makeTemporaryRoot(name: "ContextBuilderWorktree")
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
                    let binding = makeBinding(
                        logicalRoot: logicalRoot,
                        worktreeRoot: worktreeRoot,
                        suffix: "context-builder"
                    )
                    let frozenContext = MCPServerViewModel.TabContextSnapshot(
                        tabID: fixture.contextA.tabID,
                        windowID: fixture.contextA.window.windowID,
                        workspaceID: fixture.contextA.workspaceID,
                        promptText: "Inspect the worktree implementation",
                        selection: StoredSelection(),
                        selectedMetaPromptIDs: [],
                        tabName: "Agent Context Builder",
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
                    var composeTab = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    )
                    composeTab.promptText = frozenContext.promptText
                    fixture.contextA.window.workspaceManager.updateComposeTab(composeTab, markDirty: false)
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
                        _, tabID, mode, prompt, selection, lookupContext, _, _ in
                        let message = await fixture.contextA.window.promptManager.buildHeadlessAIMessage(
                            from: HeadlessContextSnapshot(
                                tabID: tabID,
                                promptText: prompt,
                                selection: selection,
                                lookupContext: lookupContext
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

                    for responseType in ["plan", "review"] {
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
                    }

                    let runs = state.runs
                    XCTAssertEqual(runs.count, 2)
                    XCTAssertEqual(runs[0].selectionBeforeRead, .empty)
                    XCTAssertEqual(runs[0].selectionAfterRead, .empty)
                    XCTAssertEqual(
                        runs[1].selectionBeforeRead,
                        .init(fullPaths: [logicalFile.path], slicePaths: [])
                    )
                    XCTAssertEqual(runs[1].selectionAfterRead, runs[1].selectionBeforeRead)
                    let logicalRelativeFilePath = String(
                        logicalFile.standardizedFileURL.path.dropFirst(logicalRoot.standardizedFileURL.path.count)
                    ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
                        XCTAssertFalse(packaged.contains(worktreeRoot.path), packaged)
                        XCTAssertFalse(followUp.fileTree.contains(worktreeRoot.path), followUp.fileTree)
                        XCTAssertEqual(followUp.selection.selectedPaths, [logicalFile.path])
                        XCTAssertNotNil(followUp.lookupContext?.bindingProjection)
                    }

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
                        XCTAssertEqual(accounting.totalTokens, expected.totalTokens ?? 0)
                        XCTAssertEqual(accounting.selection.selectedPaths, [logicalFile.path])
                        XCTAssertNotNil(accounting.lookupContext?.bindingProjection)
                    }

                    fixture.contextA.window.mcpServer.setContextBuilderSelectionReplyObserverForTesting(nil)
                    await fixture.cleanup()
                } catch {
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
                    let canonicalSentinel = "CanonicalNonAgentContextBuilderType"
                    try write(
                        "struct \(canonicalSentinel) { func canonicalMethod() {} }\n",
                        to: fixture.contextA.fileURL
                    )
                    await fixture.contextA.window.workspaceFileContextStore.replayObservedFileSystemDeltas(
                        rootID: fixture.contextA.rootID,
                        deltas: [.fileModified("Sources/\(fixture.contextA.fileURL.lastPathComponent)", Date())]
                    )
                    factory.configure(
                        networkManager: fixture.networkManager,
                        logicalFilePath: fixture.contextA.fileURL.path,
                        searchPattern: canonicalSentinel
                    )
                    let endpoint = try fixture.endpointA()
                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.contextBuilder,
                        arguments: [
                            "instructions": "Inspect the canonical checkout.",
                            "context_id": fixture.contextA.tabID.uuidString
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
                    XCTAssertNil(state.followUps.first)

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
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
                    "op": "set",
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
                fullPaths: (reply.files ?? [])
                    .filter { $0.renderMode == "full" }
                    .map(\.path)
                    .sorted(),
                slicePaths: (reply.fileSlices ?? []).map(\.path).sorted()
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
        struct SelectionObservation: Equatable {
            let fullPaths: [String]
            let slicePaths: [String]

            static let empty = SelectionObservation(fullPaths: [], slicePaths: [])
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
