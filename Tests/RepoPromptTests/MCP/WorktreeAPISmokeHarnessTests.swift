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
        let bindTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let bindSession = window.agentModeViewModel.session(for: bindTabID)
        _ = window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: bindSessionID,
            on: bindSession,
            updateWorkspaceMetadata: true
        )
        XCTAssertEqual(window.workspaceManager.activeAgentSessionID(forTabID: bindTabID), bindSessionID)

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

    func testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections() async throws {
        let fixture = try Self.makeGitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

        let window = try await Self.makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)
        let manageSelection = try await Self.windowTool(named: MCPWindowToolName.manageSelection, in: window)
        let readFile = try await Self.windowTool(named: MCPWindowToolName.readFile, in: window)
        let createValue = try await manageWorktree([
            "op": .string("create"),
            "branch": .string("feature/selection-\(fixture.suffix)"),
            "base_ref": .string("HEAD")
        ])
        let created = try Self.worktreeObject(createValue, key: "created_worktree")
        let worktreeID = try XCTUnwrap(created["worktree_id"]?.stringValue)
        let worktreePath = try XCTUnwrap(created["path"]?.stringValue)
        let worktreeOnlyFile = URL(fileURLWithPath: worktreePath)
            .appendingPathComponent("WorktreeOnly.swift")
        try "struct WorktreeOnly {}\n".write(to: worktreeOnlyFile, atomically: true, encoding: .utf8)

        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
        let sessionID = UUID()
        let session = window.agentModeViewModel.session(for: tabID)
        _ = window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            updateWorkspaceMetadata: true
        )
        _ = try await manageWorktree([
            "op": .string("bind"),
            "worktree_id": .string(worktreeID),
            "session_id": .string(sessionID.uuidString)
        ])

        let staleConnectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: staleConnectionID,
            clientName: "stale-one-shot-selection-client",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID
        )

        let setterConnectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: setterConnectionID,
            clientName: "setter-one-shot-selection-client",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID
        )
        #if DEBUG
            let staleSelectionRevision = try XCTUnwrap(
                window.mcpServer.debugSelectionRevisionForBoundConnection(staleConnectionID)
            )
        #endif
        let setValue = try await ServerNetworkManager.withConnectionID(setterConnectionID) {
            try await manageSelection([
                "op": .string("set"),
                "paths": .array([.string("WorktreeOnly.swift")]),
                "mode": .string("full"),
                "view": .string("files"),
                "path_display": .string("full"),
                "strict": .bool(true)
            ])
        }

        let logicalPath = fixture.repo.appendingPathComponent("WorktreeOnly.swift").path
        XCTAssertEqual(try Self.selectionPaths(setValue), [logicalPath])
        #if DEBUG
            let canonicalSelectionRevision = window.workspaceManager.selectionRevisionForMCP(
                workspaceID: workspaceID,
                tabID: tabID
            )
            XCTAssertGreaterThan(canonicalSelectionRevision, staleSelectionRevision)
            XCTAssertEqual(
                window.mcpServer.debugSelectionRevisionForBoundConnection(setterConnectionID),
                canonicalSelectionRevision
            )
            XCTAssertEqual(
                window.mcpServer.debugSelectionRevisionForBoundConnection(staleConnectionID),
                staleSelectionRevision
            )
        #endif
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection.selectedPaths, [logicalPath])
        XCTAssertEqual(
            window.promptManager.currentComposeTabs.first(where: { $0.id == tabID })?.selection.selectedPaths,
            [logicalPath]
        )
        XCTAssertTrue(window.workspaceFilesViewModel.snapshotSelection().selectedPaths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logicalPath))

        // Reproduce the app-only race absent from direct provider tests: a debounced file-tree
        // publisher captured the empty logical-base UI before MCP persistence and fires later.
        window.workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true, touchModified: false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection.selectedPaths, [logicalPath])
        XCTAssertEqual(
            window.promptManager.currentComposeTabs.first(where: { $0.id == tabID })?.selection.selectedPaths,
            [logicalPath]
        )

        // Exec-mode CLI disconnect is asynchronous. Exercise the stale cleanup ordering where
        // an older bound snapshot commits after the setter has persisted newer canonical state.
        let staleCleanup = Task { @MainActor in
            await window.mcpServer.commitAndClearTabContext(connectionID: staleConnectionID)
        }
        let staleCommitSucceeded = await staleCleanup.value
        XCTAssertTrue(staleCommitSucceeded)
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection.selectedPaths, [logicalPath])
        XCTAssertTrue(window.workspaceFilesViewModel.snapshotSelection().selectedPaths.isEmpty)
        window.mcpServer.removeTabContext(
            forConnectionID: setterConnectionID,
            clientName: "setter-one-shot-selection-client",
            windowID: window.windowID
        )

        let getterConnectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: getterConnectionID,
            clientName: "getter-one-shot-selection-client",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID
        )
        let getValue = try await ServerNetworkManager.withConnectionID(getterConnectionID) {
            try await manageSelection([
                "op": .string("get"),
                "view": .string("files"),
                "path_display": .string("full")
            ])
        }
        XCTAssertEqual(try Self.selectionPaths(getValue), [logicalPath])
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection.selectedPaths, [logicalPath])
        XCTAssertTrue(window.workspaceFilesViewModel.snapshotSelection().selectedPaths.isEmpty)
        window.mcpServer.removeTabContext(
            forConnectionID: getterConnectionID,
            clientName: "getter-one-shot-selection-client",
            windowID: window.windowID
        )

        // A worktree-bound Agent Mode read auto-selects canonically without attempting to
        // project a physical-only file into the logical base file tree.
        let readConnectionID = UUID()
        let readRunID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: readConnectionID,
            clientName: "read-one-shot-selection-client",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID,
            runID: readRunID,
            explicitlyBound: false
        )
        await ServerNetworkManager.shared.setRunPurpose(.agentModeRun, for: readConnectionID)
        _ = try await ServerNetworkManager.withConnectionID(readConnectionID) {
            try await manageSelection(["op": .string("clear")])
        }
        _ = try await ServerNetworkManager.withConnectionID(readConnectionID) {
            try await readFile(["path": .string("WorktreeOnly.swift")])
        }
        let readSelection = try await ServerNetworkManager.withConnectionID(readConnectionID) {
            try await manageSelection([
                "op": .string("get"),
                "view": .string("files"),
                "path_display": .string("full")
            ])
        }
        XCTAssertEqual(try Self.selectionPaths(readSelection), [logicalPath])
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection.selectedPaths, [logicalPath])
        XCTAssertEqual(
            window.promptManager.currentComposeTabs.first(where: { $0.id == tabID })?.selection.selectedPaths,
            [logicalPath]
        )
        XCTAssertTrue(window.workspaceFilesViewModel.snapshotSelection().selectedPaths.isEmpty)
        window.mcpServer.removeTabContext(
            forConnectionID: readConnectionID,
            clientName: "read-one-shot-selection-client",
            windowID: window.windowID,
            runID: readRunID
        )
        await ServerNetworkManager.shared.setRunPurpose(.unknown, for: readConnectionID)

        window.workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true, touchModified: false)
        try await Task.sleep(for: .milliseconds(250))

        let finalConnectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: finalConnectionID,
            clientName: "final-one-shot-selection-client",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID
        )
        defer {
            window.mcpServer.removeTabContext(
                forConnectionID: finalConnectionID,
                clientName: "final-one-shot-selection-client",
                windowID: window.windowID
            )
        }
        let finalSelection = try await ServerNetworkManager.withConnectionID(finalConnectionID) {
            try await manageSelection([
                "op": .string("get"),
                "view": .string("files"),
                "path_display": .string("full")
            ])
        }
        XCTAssertEqual(try Self.selectionPaths(finalSelection), [logicalPath])
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection.selectedPaths, [logicalPath])
        XCTAssertEqual(
            window.promptManager.currentComposeTabs.first(where: { $0.id == tabID })?.selection.selectedPaths,
            [logicalPath]
        )

        // A genuinely newer manual UI mutation advances the live-owner revision and supersedes
        // the worktree fence rather than leaving canonical selection permanently pinned.
        let manualUISelection = StoredSelection(
            selectedPaths: [fixture.trackedFile.path],
            codemapAutoEnabled: false
        )
        await window.workspaceFilesViewModel.applyStoredSelection(manualUISelection)
        window.workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true, touchModified: false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection, manualUISelection)
        XCTAssertEqual(
            window.promptManager.currentComposeTabs.first(where: { $0.id == tabID })?.selection,
            manualUISelection
        )
    }

    func testContextBuilderExportUsesResolvedWorktreeContextAndIsReadableFromFreshConnection() async throws {
        #if DEBUG
            let fixture = try Self.makeGitFixture()
            defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

            let provider = WorktreeContextBuilderImmediateCompletionProvider()
            let window = try await Self.makeWindow(
                root: fixture.repo,
                contextBuilderProviderFactory: { _, _, _ in provider }
            )
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)
            let contextBuilder = try await Self.windowTool(named: MCPWindowToolName.contextBuilder, in: window)
            let readFile = try await Self.windowTool(named: MCPWindowToolName.readFile, in: window)

            var targetTab = try await Self.createBackgroundTab(in: window, name: "Bound Export Target")
            let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
            XCTAssertNotEqual(window.workspaceManager.activeWorkspace?.activeComposeTabID, targetTab.id)
            targetTab.promptText = "Generate the deterministic worktree export."
            window.workspaceManager.updateComposeTab(targetTab, markDirty: false)
            let sessionID = UUID()
            let session = window.agentModeViewModel.session(for: targetTab.id)
            _ = window.agentModeViewModel.test_installPersistentSessionBinding(
                sessionID: sessionID,
                on: session,
                updateWorkspaceMetadata: true
            )

            let createValue = try await manageWorktree([
                "op": .string("create"),
                "branch": .string("feature/export-\(fixture.suffix)"),
                "base_ref": .string("HEAD")
            ])
            let created = try Self.worktreeObject(createValue, key: "created_worktree")
            let worktreeID = try XCTUnwrap(created["worktree_id"]?.stringValue)
            let worktreePath = try XCTUnwrap(created["path"]?.stringValue)
            _ = try await manageWorktree([
                "op": .string("bind"),
                "worktree_id": .string(worktreeID),
                "session_id": .string(sessionID.uuidString)
            ])

            window.contextBuilderAgentViewModel.installRunTestHooks(
                ContextBuilderAgentViewModel.RunTestHooks(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    runMCPFollowUp: { mode, _, _ in
                        let chatID = UUID()
                        return ChatSendReply(
                            chatId: chatID,
                            shortId: String(chatID.uuidString.prefix(8)).lowercased(),
                            mode: mode.mcpModeName,
                            response: "deterministic worktree export response",
                            errors: nil
                        )
                    }
                )
            )
            defer { window.contextBuilderAgentViewModel.installRunTestHooks(nil) }

            let exportConnectionID = UUID()
            let exportValue = try await ServerNetworkManager.withConnectionID(exportConnectionID) {
                // Exercise the provider's explicit context_id resolution without an ambient
                // TaskLocal hint; the active tab intentionally points at the base checkout.
                try await contextBuilder([
                    "instructions": .string("Inspect the worktree-bound target."),
                    "response_type": .string("plan"),
                    "context_id": .string(targetTab.id.uuidString),
                    "export_response": .bool(true)
                ])
            }
            let exportObject = try XCTUnwrap(exportValue.objectValue)
            XCTAssertNotNil(exportObject["plan"]?.objectValue, String(describing: exportObject))
            let exportPath = try XCTUnwrap(exportObject["oracle_export_path"]?.stringValue)
            let exportInstruction = try XCTUnwrap(exportObject["oracle_export_instruction"]?.stringValue)
            let standardizedLogicalPath = fixture.repo.standardizedFileURL.path
            XCTAssertTrue(
                exportPath.hasPrefix(standardizedLogicalPath + "/prompt-exports/"),
                exportPath
            )
            let exportPathLiteral = try XCTUnwrap(
                String(data: JSONEncoder().encode(exportPath), encoding: .utf8)
            )
            XCTAssertTrue(
                exportInstruction.contains("{\"path\": \(exportPathLiteral)}"),
                exportInstruction
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: exportPath), exportPath)

            let relativeExportPath = String(exportPath.dropFirst(standardizedLogicalPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let physicalExportPath = URL(fileURLWithPath: worktreePath)
                .appendingPathComponent(relativeExportPath)
                .path
            XCTAssertTrue(FileManager.default.fileExists(atPath: physicalExportPath), physicalExportPath)

            let readConnectionID = UUID()
            let contextHint = MCPServerViewModel.TabContextHint(
                tabID: targetTab.id,
                workspaceID: workspaceID,
                windowID: window.windowID
            )
            let readValue = try await ServerNetworkManager.withConnectionID(readConnectionID) {
                try await ServerNetworkManager.$currentTabContextHint.withValue(contextHint) {
                    try await readFile(["path": .string(exportPath)])
                }
            }
            let readReply = try XCTUnwrap(readValue.decode(ToolResultDTOs.ReadFileReply.self))
            XCTAssertTrue(readReply.content.contains("deterministic worktree export response"), readReply.content)
            XCTAssertNotNil(readReply.worktreeScope)
        #else
            throw XCTSkip("Context Builder provider injection is DEBUG-only.")
        #endif
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
        _ = window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            updateWorkspaceMetadata: true
        )

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
        XCTAssertFalse(formattedTree.contains(effectiveRootPath), formattedTree)
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
        XCTAssertFalse(formattedRead.contains(effectiveRootPath), formattedRead)
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
        XCTAssertFalse(formattedSearch.contains(effectiveRootPath), formattedSearch)
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

    private static func makeWindow(
        root: URL,
        contextBuilderProviderFactory: ContextBuilderAgentViewModel.ProviderFactory? = nil
    ) async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window: WindowState
        #if DEBUG
            if let contextBuilderProviderFactory {
                window = WindowState(contextBuilderProviderFactory: contextBuilderProviderFactory)
            } else {
                window = WindowState()
            }
        #else
            _ = contextBuilderProviderFactory
            window = WindowState()
        #endif
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
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: cwd,
            environment: environment
        )
        guard result.terminationStatus == 0 else {
            throw NSError(
                domain: "WorktreeAPISmokeHarnessTests.git",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(result.outputText)"]
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

    private static func selectionPaths(_ value: Value) throws -> [String] {
        let object = try XCTUnwrap(value.objectValue)
        let files = try XCTUnwrap(object["files"]?.arrayValue)
        return try files.map { file in
            try XCTUnwrap(file.objectValue?["path"]?.stringValue)
        }
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

#if DEBUG
    private final class WorktreeContextBuilderImmediateCompletionProvider: HeadlessAgentProvider {
        func streamAgentMessage(
            _ message: AgentMessage,
            runID: UUID?
        ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
            _ = message
            let stream = AsyncThrowingStream<AIStreamResult, Error> { continuation in
                continuation.yield(AIStreamResult(type: "content", text: "Discovery complete"))
                continuation.finish()
            }
            if let runID {
                await MCPRoutingWaiter.notifyRouted(runID: runID)
            }
            return stream
        }

        func dispose() async {}
    }
#endif
