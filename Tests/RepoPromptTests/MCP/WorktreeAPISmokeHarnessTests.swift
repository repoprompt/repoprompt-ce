import Foundation
import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class WorktreeAPISmokeHarnessTests: XCTestCase {
    func testManageWorktreeAndAgentRunAPISmokeFlow() async throws {
        let fixture = try Self.makeGitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

        let window = try await Self.makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)

        let graphList = try await manageWorktree([
            "op": .string("list"),
            "include_graph": .bool(true),
            "graph_limit": .int(8),
            "persist_visuals": .bool(true)
        ])
        try assertManageWorktreeGraphListContract(graphList)

        let createValue = try await manageWorktree([
            "op": .string("create"),
            "branch": .string("feature/item12-create-\(fixture.suffix)"),
            "base_ref": .string("HEAD"),
            "label": .string("Item 12 Create"),
            "color": .string("#2563EB"),
            "include_status": .bool(true)
        ])
        let createdWorktree = try Self.worktreeObject(createValue, key: "created_worktree")
        let createdWorktreeID = try XCTUnwrap(createdWorktree["worktree_id"]?.stringValue)
        let createdWorktreePath = try XCTUnwrap(createdWorktree["path"]?.stringValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdWorktreePath), createdWorktreePath)

        let bindSessionID = UUID()
        let activeWorkspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
        let bindTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let bindSession = window.agentModeViewModel.session(for: bindTabID)
        bindSession.activeAgentSessionID = bindSessionID
        XCTAssertTrue(window.workspaceManager.setActiveAgentSessionID(bindSessionID, forTabID: bindTabID, inWorkspaceID: activeWorkspaceID))

        let bindValue = try await manageWorktree([
            "op": .string("bind"),
            "worktree_id": .string(createdWorktreeID),
            "session_id": .string(bindSessionID.uuidString),
            "label": .string("Bound Item 12"),
            "color": .string("#7C3AED")
        ])
        let binding = try Self.object(bindValue, key: "binding")
        XCTAssertEqual(binding["worktree_id"]?.stringValue, createdWorktreeID)
        XCTAssertEqual(binding["worktree_root_path"]?.stringValue, createdWorktreePath)
        XCTAssertEqual(binding["logical_root_path"]?.stringValue, fixture.repo.path)
        XCTAssertEqual(binding["visual_label"]?.stringValue, "Bound Item 12")

        try await assertDiscoveryToolsReportWorktreeScope(
            window: window,
            logicalRootPath: fixture.repo.path,
            effectiveRootPath: createdWorktreePath,
            worktreeID: createdWorktreeID
        )

        let existingStartTab = try await Self.createBackgroundTab(in: window, name: "Item 12 Existing Start")
        let existingStart = try await Self.makeAgentRunService(window: window, targetTabID: existingStartTab.id).execute(args: [
            "op": .string("start"),
            "message": .string("Smoke existing worktree binding"),
            "detach": .bool(true),
            "timeout": .int(0),
            "worktree_id": .string(createdWorktreeID),
            "worktree_label": .string("Agent Existing WT"),
            "worktree_color": .string("#0EA5E9")
        ])
        let existingStartBinding = try Self.firstWorktreeBinding(existingStart)
        XCTAssertEqual(existingStartBinding["worktree_id"]?.stringValue, createdWorktreeID)
        XCTAssertEqual(existingStartBinding["worktree_root_path"]?.stringValue, createdWorktreePath)
        try await assertBoundSessionReadAndApplyUseWorktree(
            value: existingStart,
            window: window,
            logicalRoot: fixture.repo,
            originalTrackedFile: fixture.trackedFile
        )

        let createStartTab = try await Self.createBackgroundTab(in: window, name: "Item 12 Create Start")
        let createStart = try await Self.makeAgentRunService(window: window, targetTabID: createStartTab.id).execute(args: [
            "op": .string("start"),
            "message": .string("Smoke created worktree binding"),
            "detach": .bool(true),
            "timeout": .int(0),
            "worktree_create": .bool(true),
            "worktree_branch": .string("feature/item12-agent-\(fixture.suffix)"),
            "worktree_base_ref": .string("HEAD"),
            "worktree_label": .string("Agent Created WT"),
            "worktree_color": .string("#16A34A")
        ])
        let createStartBinding = try Self.firstWorktreeBinding(createStart)
        XCTAssertNotNil(createStartBinding["worktree_id"]?.stringValue)
        XCTAssertEqual(createStartBinding["visual_label"]?.stringValue, "Agent Created WT")
        let createStartPath = try XCTUnwrap(createStartBinding["worktree_root_path"]?.stringValue)
        XCTAssertNotEqual(createStartPath, fixture.repo.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: createStartPath), createStartPath)

        let formattedList = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: ["op": .string("list")], value: graphList))
        XCTAssertTrue(formattedList.contains("## Manage Worktree List"), formattedList)
        XCTAssertTrue(formattedList.contains("### Commit / Worktree Graph"), formattedList)
        XCTAssertTrue(formattedList.contains("bounded to 8 lines"), formattedList)

        let formattedStart = try Self.onlyText(ToolOutputFormatter.formatAgentRun(args: ["op": .string("start")], value: createStart))
        XCTAssertTrue(formattedStart.contains("Worktree:"), formattedStart)
        XCTAssertTrue(formattedStart.contains("Agent Created WT"), formattedStart)
    }

    func testManageWorktreeMergePreviewCleanApplyRawAndFormattedContract() async throws {
        let fixture = try Self.makeGitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

        let window = try await Self.makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)
        let sessionID = UUID()
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let session = window.agentModeViewModel.session(for: tabID)
        session.activeAgentSessionID = sessionID

        let createValue = try await manageWorktree([
            "op": .string("create"),
            "branch": .string("feature/merge-smoke-\(fixture.suffix)"),
            "base_ref": .string("HEAD")
        ])
        let created = try Self.worktreeObject(createValue, key: "created_worktree")
        let sourceWorktreeID = try XCTUnwrap(created["worktree_id"]?.stringValue)
        let sourcePath = try XCTUnwrap(created["path"]?.stringValue)
        let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: true)
        try "feature\n".write(to: sourceURL.appendingPathComponent("Feature.txt"), atomically: true, encoding: .utf8)
        try Self.runGit(["add", "Feature.txt"], cwd: sourceURL)
        try Self.runGit(["commit", "-m", "Feature commit"], cwd: sourceURL)

        _ = try await manageWorktree([
            "op": .string("bind"),
            "worktree_id": .string(sourceWorktreeID),
            "session_id": .string(sessionID.uuidString)
        ])

        let previewValue = try await manageWorktree([
            "op": .string("preview"),
            "session_id": .string(sessionID.uuidString),
            "target": .string("@main"),
            "include_graph": .bool(true),
            "graph_limit": .int(12)
        ])
        let previewObject = try XCTUnwrap(previewValue.objectValue)
        XCTAssertEqual(previewObject["op"]?.stringValue, "preview")
        XCTAssertNil(previewObject["operation_id"])
        let previewMerge = try XCTUnwrap(previewObject["merge"]?.objectValue)
        XCTAssertEqual(previewMerge["status"]?.stringValue, "preview")
        let operationID = try XCTUnwrap(previewMerge["operation_id"]?.stringValue)
        XCTAssertEqual(previewMerge["visualization"]?.objectValue?["source"]?.stringValue, "manage_worktree.preview")
        XCTAssertTrue(previewMerge["next_actions"]?.arrayValue?.contains { $0.stringValue?.contains("manage_worktree") == true } == true)

        let formattedPreview = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: ["op": .string("preview")], value: previewValue))
        XCTAssertTrue(formattedPreview.contains("## Manage Worktree Preview"), formattedPreview)
        XCTAssertTrue(formattedPreview.contains("### ASCII Visualization"), formattedPreview)

        let applyValue = try await manageWorktree([
            "op": .string("apply"),
            "session_id": .string(sessionID.uuidString),
            "operation_id": .string(operationID),
            "confirm_preview": .bool(true),
            "include_graph": .bool(true)
        ])
        let applyObject = try XCTUnwrap(applyValue.objectValue)
        XCTAssertEqual(applyObject["op"]?.stringValue, "apply")
        let applyMerge = try XCTUnwrap(applyObject["merge"]?.objectValue)
        XCTAssertEqual(applyMerge["status"]?.stringValue, "completed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("Feature.txt").path))

        let formattedApply = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: ["op": .string("apply")], value: applyValue))
        XCTAssertTrue(formattedApply.contains("## Manage Worktree Apply"), formattedApply)
        XCTAssertTrue(formattedApply.contains("Validate from target cwd"), formattedApply)
    }

    private func assertManageWorktreeGraphListContract(_ value: Value) throws {
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["op"]?.stringValue, "list")
        let worktrees = try XCTUnwrap(object["worktrees"]?.arrayValue)
        XCTAssertFalse(worktrees.isEmpty)
        let first = try XCTUnwrap(worktrees.first?.objectValue)
        XCTAssertNotNil(first["worktree_id"]?.stringValue)
        XCTAssertNotNil(first["specifier"]?.stringValue)
        XCTAssertNotNil(first["visual"]?.objectValue?["color_hex"]?.stringValue)

        let graph = try XCTUnwrap(object["graph"]?.objectValue)
        XCTAssertEqual(graph["requested"]?.boolValue, true)
        XCTAssertEqual(graph["limit"]?.intValue, 8)
        XCTAssertNotNil(graph["line_count"]?.intValue)
        XCTAssertFalse(graph["lines"]?.arrayValue?.isEmpty ?? true)
        XCTAssertTrue(graph["source"]?.stringValue?.contains("git log --graph") ?? false)
    }

    private func assertDiscoveryToolsReportWorktreeScope(
        window: WindowState,
        logicalRootPath: String,
        effectiveRootPath: String,
        worktreeID: String
    ) async throws {
        let getFileTree = try await Self.windowTool(named: MCPWindowToolName.getFileTree, in: window)
        let readFile = try await Self.windowTool(named: MCPWindowToolName.readFile, in: window)
        let fileSearch = try await Self.windowTool(named: MCPWindowToolName.search, in: window)

        let treeValue = try await getFileTree(["type": .string("files"), "max_depth": .int(1)])
        try Self.assertWorktreeScope(
            in: treeValue,
            logicalRootPath: logicalRootPath,
            effectiveRootPath: effectiveRootPath,
            worktreeID: worktreeID
        )
        let formattedTree = try Self.onlyText(ToolOutputFormatter.formatFileTree(value: treeValue))
        XCTAssertTrue(formattedTree.contains(logicalRootPath), formattedTree)
        XCTAssertTrue(formattedTree.contains(effectiveRootPath), formattedTree)
        XCTAssertTrue(formattedTree.contains("session-bound worktree"), formattedTree)

        let readValue = try await readFile(["path": .string("Tracked.txt")])
        try Self.assertWorktreeScope(
            in: readValue,
            logicalRootPath: logicalRootPath,
            effectiveRootPath: effectiveRootPath,
            worktreeID: worktreeID
        )
        let formattedRead = try Self.onlyText(ToolOutputFormatter.formatReadFile(args: ["path": .string("Tracked.txt")], value: readValue))
        XCTAssertTrue(formattedRead.contains(logicalRootPath), formattedRead)
        XCTAssertTrue(formattedRead.contains(effectiveRootPath), formattedRead)
        XCTAssertTrue(formattedRead.contains("session-bound worktree"), formattedRead)

        let searchValue = try await fileSearch(["pattern": .string("original"), "mode": .string("content"), "max_results": .int(5)])
        try Self.assertWorktreeScope(
            in: searchValue,
            logicalRootPath: logicalRootPath,
            effectiveRootPath: effectiveRootPath,
            worktreeID: worktreeID
        )
        let formattedSearch = try Self.onlyText(ToolOutputFormatter.formatSearch(value: searchValue))
        XCTAssertTrue(formattedSearch.contains(logicalRootPath), formattedSearch)
        XCTAssertTrue(formattedSearch.contains(effectiveRootPath), formattedSearch)
        XCTAssertTrue(formattedSearch.contains("session-bound worktree"), formattedSearch)
    }

    private func assertBoundSessionReadAndApplyUseWorktree(
        value: Value,
        window: WindowState,
        logicalRoot: URL,
        originalTrackedFile: URL
    ) async throws {
        let sessionID = try Self.sessionID(value)
        let bindings = window.agentModeViewModel.worktreeBindings(forAgentSessionID: sessionID)
        XCTAssertFalse(bindings.isEmpty)
        let materializedProjection = await window.mcpServer.materializeWorkspaceBindingProjection(sessionID: sessionID, bindings: bindings)
        let projection = try XCTUnwrap(materializedProjection)
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let store = window.workspaceFileContextStore

        let readPath = lookupContext.translateInputPath("Tracked.txt")
        XCTAssertFalse(readPath.hasPrefix(logicalRoot.path + "/"), readPath)
        let lookupResult = await store.lookupPath(readPath, profile: .mcpRead, rootScope: lookupContext.rootScope)
        let readRecord = try XCTUnwrap(lookupResult?.file)
        let readContent = try await store.readContent(rootID: readRecord.rootID, relativePath: readRecord.standardizedRelativePath)
        XCTAssertEqual(readContent, "original\n")

        let host = WorkspaceFileEditHost(
            store: store,
            lookupRootScope: lookupContext.rootScope,
            createPathResolutionPolicy: .canonicalAliasFirst,
            selectCreatedFiles: false
        )
        let service = ApplyEditsService(engine: .default, host: host)
        let result = try await service.run(ApplyEditsRequest(
            path: lookupContext.translateInputPath("Tracked.txt"),
            mode: .single(search: "original", replace: "worktree-edited", replaceAll: false),
            verbose: true
        ))
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(try String(contentsOf: originalTrackedFile, encoding: .utf8), "original\n")
        XCTAssertEqual(try String(contentsOfFile: readPath, encoding: .utf8), "worktree-edited\n")
    }

    private static func makeAgentRunService(window: WindowState, targetTabID: UUID) -> AgentRunMCPToolService {
        AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: "worktree-api-smoke", windowID: window.windowID)
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in targetTabID },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { target, _, _, _, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, _, _ in
                guard let sessionID = target.sessionID else {
                    throw MCPError.internalError("Smoke start target did not resolve a session ID.")
                }
                let bindings = agentModeVM.worktreeBindings(forAgentSessionID: sessionID, tabID: target.tabID)
                let snapshot = AgentRunMCPSnapshot(
                    sessionID: sessionID,
                    tabID: target.tabID,
                    sessionName: "Worktree API Smoke",
                    agentRaw: agentRaw,
                    agentDisplayName: agentRaw.flatMap { AgentProviderKind(rawValue: $0)?.displayName },
                    modelRaw: modelRaw,
                    reasoningEffortRaw: reasoningEffortRaw,
                    status: .running,
                    statusText: "Smoke harness running",
                    latestAssistantPreview: nil,
                    interaction: nil,
                    transcriptItemCount: 0,
                    updatedAt: Date(),
                    parentSessionID: nil,
                    failureReason: nil,
                    worktreeBindings: bindings.map { AgentRunMCPSnapshot.WorktreeBinding(binding: $0) },
                    activeWorktreeMerges: []
                )
                return AgentExternalMCPRunStarter.StartOutcome(snapshot: snapshot, delivery: .startedRun)
            }
        )
    }

    private static func makeWindow(root: URL) async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Worktree API Smoke \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "worktreeAPISmokeHarness")
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        _ = try await window.workspaceFileContextStore.loadRoot(path: root.path)
        return window
    }

    private static func createBackgroundTab(in window: WindowState, name: String) async throws -> ComposeTabState {
        let tab = await window.promptManager.createBackgroundComposeTab(
            strategy: .blank,
            name: name,
            capacityPolicy: .mcpBackgroundAgent
        )
        return try XCTUnwrap(tab)
    }

    private static func windowTool(named name: String, in window: WindowState) async throws -> RepoPrompt.Tool {
        let tools = await window.mcpServer.windowMCPTools
        return try XCTUnwrap(tools.first { $0.name == name })
    }

    private struct GitFixture {
        let sandbox: URL
        let repo: URL
        let trackedFile: URL
        let suffix: String
    }

    private static func makeGitFixture() throws -> GitFixture {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorktreeAPISmokeHarnessTests-\(suffix)", isDirectory: true)
        let repo = sandbox.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init"], cwd: repo)
        try runGit(["config", "user.name", "RepoPrompt Test"], cwd: repo)
        try runGit(["config", "user.email", "repoprompt@example.test"], cwd: repo)
        try runGit(["config", "commit.gpgSign", "false"], cwd: repo)
        try runGit(["checkout", "-b", "main"], cwd: repo)
        let trackedFile = repo.appendingPathComponent("Tracked.txt")
        try "original\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try runGit(["add", "Tracked.txt"], cwd: repo)
        try runGit(["commit", "-m", "Initial commit"], cwd: repo)
        return GitFixture(sandbox: sandbox, repo: repo.standardizedFileURL, trackedFile: trackedFile.standardizedFileURL, suffix: String(suffix))
    }

    private static func runGit(_ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: data, as: UTF8.self)
            throw NSError(
                domain: "WorktreeAPISmokeHarnessTests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(text)"]
            )
        }
    }

    private static func worktreeObject(_ value: Value, key: String) throws -> [String: Value] {
        try object(value, key: key)
    }

    private static func object(_ value: Value, key: String) throws -> [String: Value] {
        let root = try XCTUnwrap(value.objectValue)
        return try XCTUnwrap(root[key]?.objectValue)
    }

    private static func assertWorktreeScope(
        in value: Value,
        logicalRootPath: String,
        effectiveRootPath: String,
        worktreeID: String
    ) throws {
        let object = try XCTUnwrap(value.objectValue)
        let scope = try XCTUnwrap(object["worktree_scope"]?.objectValue)
        let mappings = try XCTUnwrap(scope["root_mappings"]?.arrayValue)
        let first = try XCTUnwrap(mappings.first?.objectValue)
        XCTAssertEqual(first["logical_root_path"]?.stringValue, logicalRootPath)
        XCTAssertEqual(first["effective_root_path"]?.stringValue, effectiveRootPath)
        XCTAssertEqual(first["worktree_id"]?.stringValue, worktreeID)
    }

    private static func sessionID(_ value: Value) throws -> UUID {
        let object = try XCTUnwrap(value.objectValue)
        let raw = try XCTUnwrap(object["session_id"]?.stringValue)
        return try XCTUnwrap(UUID(uuidString: raw))
    }

    private static func firstWorktreeBinding(_ value: Value) throws -> [String: Value] {
        let object = try XCTUnwrap(value.objectValue)
        let bindings = try XCTUnwrap(object["worktree_bindings"]?.arrayValue)
        let first = try XCTUnwrap(bindings.first)
        return try XCTUnwrap(first.objectValue)
    }

    private static func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}
