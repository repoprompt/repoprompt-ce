import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    @MainActor
    final class MCPAskOracleWorktreeTests: XCTestCase {
        func testAskOracleWaitsForReadAutoSelectionAndPackagesWorktreeContent() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gate = OracleWorktreeGate()
                let drainSignal = OracleWorktreeSignal()
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
                    fixture.contextA.window.mcpServer.setOracleReadAutoSelectionDrainObserverForTesting {
                        drainSignal.markStarted()
                    }
                    fixture.contextA.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                        await gate.markStartedAndWaitForRelease()
                    }

                    let readTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": logicalFile.path],
                            timeoutSeconds: 20
                        )
                    }
                    await gate.waitUntilStarted()
                    let readResponse = try await readTask.value
                    XCTAssertTrue(try toolResultText(readResponse).contains(worktreeSentinel))

                    let askTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.askOracle,
                            arguments: ["message": "Explain the selected implementation."],
                            timeoutSeconds: 30
                        )
                    }
                    await drainSignal.waitUntilStarted()
                    XCTAssertFalse(capture.wasInvoked)

                    await gate.release()
                    let askResponse = try await askTask.value
                    XCTAssertTrue(try toolResultText(askResponse).contains("captured oracle response"))
                    XCTAssertTrue(capture.wasInvoked)
                    let tabContext = try XCTUnwrap(capture.tabContext)
                    XCTAssertEqual(tabContext.selection.selectedPaths, [logicalFile.path])
                    let packaged = capture.fileBlocks.joined(separator: "\n")
                    XCTAssertTrue(packaged.contains(worktreeSentinel), packaged)
                    XCTAssertFalse(packaged.contains(canonicalSentinel), packaged)
                    XCTAssertFalse(packaged.contains(worktreeRoot.path), packaged)
                    XCTAssertFalse(capture.fileTree.contains(worktreeRoot.path), capture.fileTree)

                    fixture.contextA.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleReadAutoSelectionDrainObserverForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    await gate.release()
                    fixture.contextA.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleReadAutoSelectionDrainObserverForTesting(nil)
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
                    let logicalRootA = fixture.contextA.rootURL
                    let logicalFileA = fixture.contextA.fileURL
                    let logicalRootB = try makeTemporaryRoot(name: "OracleLogicalB")
                    let logicalFileB = logicalRootB.appendingPathComponent("Sources/Second.swift")
                    let worktreeRootA = try makeTemporaryRoot(name: "OracleWorktreeA")
                    let worktreeRootB = try makeTemporaryRoot(name: "OracleWorktreeB")
                    let worktreeFileA = worktreeRootA
                        .appendingPathComponent("Sources", isDirectory: true)
                        .appendingPathComponent(logicalFileA.lastPathComponent)
                    let worktreeFileB = worktreeRootB.appendingPathComponent("Sources/Second.swift")

                    try write("let value = \"canonical_oracle_a\"\n", to: logicalFileA)
                    try write("let value = \"canonical_oracle_b\"\n", to: logicalFileB)
                    try write("let value = \"worktree_oracle_a\"\n", to: worktreeFileA)
                    try write("let value = \"worktree_oracle_b\"\n", to: worktreeFileB)
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
                    installOracleCapture(capture, on: fixture.contextA.window)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Compare both selected roots."],
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
                    XCTAssertEqual(capture.tabContext?.lookupContext?.bindingProjection?.boundRootsForMetadata.count, 2)

                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
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
                    XCTAssertTrue(response.rawJSON.contains(missingWorktreeB.standardizedFileURL.path), response.rawJSON)
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
                    XCTAssertTrue(response.rawJSON.contains(missingWorktree.standardizedFileURL.path), response.rawJSON)
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
            on window: WindowState
        ) {
            window.mcpServer.setOracleChatSendOverrideForTesting { args, promptVM, tabContext in
                let context = try XCTUnwrap(tabContext)
                let config = PromptContextResolved(
                    includeFiles: true,
                    includeUserPrompt: true,
                    includeMetaPrompts: false,
                    includeFileTree: true,
                    fileTreeMode: .auto,
                    codeMapUsage: .none,
                    gitInclusion: .none,
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
                    overrideMode: .chat,
                    selectionOverride: context.selection,
                    lookupContextOverride: context.lookupContext
                )
                capture.record(
                    tabContext: context,
                    fileTree: message.fileTree,
                    fileBlocks: message.fileBlocks
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
            bindings: [AgentSessionWorktreeBinding]
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

        private func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return content.compactMap { $0["text"] as? String }.joined()
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
    }

    @MainActor
    private final class OracleWorktreeCapture {
        private(set) var wasInvoked = false
        private(set) var tabContext: OracleViewModel.OracleSendTabContext?
        private(set) var fileTree = ""
        private(set) var fileBlocks: [String] = []

        func record(
            tabContext: OracleViewModel.OracleSendTabContext,
            fileTree: String,
            fileBlocks: [String]
        ) {
            wasInvoked = true
            self.tabContext = tabContext
            self.fileTree = fileTree
            self.fileBlocks = fileBlocks
        }
    }

    @MainActor
    private final class OracleWorktreeSignal {
        private var started = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            guard !started else { return }
            started = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private actor OracleWorktreeGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
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
