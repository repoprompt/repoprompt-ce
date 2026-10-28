import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

final class BindContextRoutingAuthorityTests: XCTestCase {
    func testRoutingSummaryInitializerDefaultsDoNotMakeDecodeKeysOptional() throws {
        let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let tabID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let paths = ["/fixture/a", "/fixture/b", "/fixture/c", "/fixture/d"]
        let workspace = MCPWorkspaceSummary(
            id: workspaceID,
            name: "Routing Workspace",
            allRepoPaths: paths,
            showingWindowIDs: [7]
        )
        XCTAssertEqual(workspace.rootCount, 4)
        XCTAssertEqual(workspace.repoPaths, ["/fixture/a", "/fixture/b", "/fixture/c"])
        XCTAssertFalse(workspace.isHidden)

        let tab = MCPComposeTabSummary(
            id: tabID,
            name: "Routing Tab",
            workspaceID: workspaceID,
            workspaceName: "Routing Workspace",
            windowID: 7,
            isActive: true,
            isBoundForClient: false,
            totalFileCount: 4,
            sampleFileNames: ["a.swift", "b.swift"]
        )
        XCTAssertEqual(tab.contextID, tabID)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let workspaceData = try encoder.encode(workspace)
        XCTAssertEqual(try decoder.decode(MCPWorkspaceSummary.self, from: workspaceData), workspace)
        var workspaceJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: workspaceData) as? [String: Any])
        XCTAssertEqual(workspaceJSON.removeValue(forKey: "is_hidden") as? Bool, false)
        let missingHiddenData = try JSONSerialization.data(withJSONObject: workspaceJSON)
        XCTAssertThrowsError(try decoder.decode(MCPWorkspaceSummary.self, from: missingHiddenData)) { error in
            guard case let DecodingError.keyNotFound(key, context) = error else {
                XCTFail("Expected required is_hidden key failure, got \(error)")
                return
            }
            XCTAssertEqual(key.stringValue, "is_hidden")
            XCTAssertTrue(context.codingPath.isEmpty)
        }

        let tabData = try encoder.encode(tab)
        XCTAssertEqual(try decoder.decode(MCPComposeTabSummary.self, from: tabData), tab)
        var tabJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: tabData) as? [String: Any])
        XCTAssertEqual(tabJSON.removeValue(forKey: "context_id") as? String, tabID.uuidString)
        let missingContextData = try JSONSerialization.data(withJSONObject: tabJSON)
        XCTAssertThrowsError(try decoder.decode(MCPComposeTabSummary.self, from: missingContextData)) { error in
            guard case let DecodingError.keyNotFound(key, context) = error else {
                XCTFail("Expected required context_id key failure, got \(error)")
                return
            }
            XCTAssertEqual(key.stringValue, "context_id")
            XCTAssertTrue(context.codingPath.isEmpty)
        }
    }

    func testRoutingResponsesPreserveWireKeysAndNilOmission() throws {
        func assertWire<T: Codable>(_ value: T, expectedJSON: String) throws -> T {
            let encoded = try JSONEncoder().encode(value)
            let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let expected = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(expectedJSON.utf8)) as? [String: Any]
            )
            XCTAssertEqual(Set(actual.keys), Set(expected.keys))
            XCTAssertEqual(actual as NSDictionary, expected as NSDictionary)
            let decoded = try JSONDecoder().decode(T.self, from: encoded)
            let roundTrip = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
            )
            XCTAssertEqual(roundTrip as NSDictionary, expected as NSDictionary)
            return decoded
        }

        let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let tabID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let contextID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let workspace = MCPWorkspaceSummary(
            id: workspaceID,
            name: "Routing Workspace",
            allRepoPaths: ["/fixture/a", "/fixture/b", "/fixture/c", "/fixture/d"],
            showingWindowIDs: [7, 9],
            isHidden: true
        )
        let composeTab = MCPComposeTabSummary(
            id: tabID,
            contextID: contextID,
            name: "Routing Tab",
            workspaceID: workspaceID,
            workspaceName: "Routing Workspace",
            windowID: 7,
            isActive: true,
            isBoundForClient: false,
            totalFileCount: 4,
            sampleFileNames: ["a.swift", "b.swift"]
        )
        let manage = ManageWorkspacesResponse(
            action: "create",
            workspaces: [workspace],
            tabs: [composeTab],
            status: "created",
            windowID: 7,
            closedWindowID: 9
        )
        let decodedManage = try assertWire(manage, expectedJSON: """
        {
          "action": "create",
          "workspaces": [{
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Routing Workspace",
            "root_count": 4,
            "repo_paths": ["/fixture/a", "/fixture/b", "/fixture/c"],
            "showing_window_ids": [7, 9],
            "is_hidden": true
          }],
          "tabs": [{
            "id": "00000000-0000-0000-0000-000000000002",
            "context_id": "00000000-0000-0000-0000-000000000003",
            "name": "Routing Tab",
            "workspace_id": "00000000-0000-0000-0000-000000000001",
            "workspace_name": "Routing Workspace",
            "window_id": 7,
            "is_active": true,
            "is_bound_for_client": false,
            "total_file_count": 4,
            "sample_file_names": ["a.swift", "b.swift"]
          }],
          "status": "created",
          "window_id": 7,
          "closed_window_id": 9
        }
        """)
        XCTAssertEqual(decodedManage.action, "create")
        XCTAssertEqual(decodedManage.workspaces, [workspace])
        XCTAssertEqual(decodedManage.tabs, [composeTab])
        XCTAssertEqual(decodedManage.status, "created")
        XCTAssertEqual(decodedManage.windowID, 7)
        XCTAssertEqual(decodedManage.closedWindowID, 9)

        let minimalManage = try assertWire(
            ManageWorkspacesResponse(action: "list", workspaces: nil, status: nil),
            expectedJSON: """
            {"action": "list"}
            """
        )
        XCTAssertEqual(minimalManage.action, "list")
        XCTAssertNil(minimalManage.workspaces)
        XCTAssertNil(minimalManage.tabs)
        XCTAssertNil(minimalManage.status)
        XCTAssertNil(minimalManage.windowID)
        XCTAssertNil(minimalManage.closedWindowID)

        let boundTab = MCPBindContextTabSummary(
            contextID: contextID,
            name: "Bound Tab",
            workspaceID: workspaceID,
            workspaceName: "Routing Workspace",
            isActive: true,
            isBound: false,
            repoPaths: ["/fixture/a"]
        )
        let window = MCPBindContextWindowSummary(
            windowID: 7,
            isCurrentWindow: true,
            workspace: MCPBindContextWorkspaceSummary(id: workspaceID, name: "Routing Workspace"),
            activeContextID: contextID,
            tabs: [boundTab]
        )
        let binding = MCPBindContextBindingSummary(
            bindingKind: "tab_context",
            windowID: 7,
            contextID: contextID,
            workspaceID: workspaceID,
            workspaceName: "Routing Workspace",
            tabName: "Bound Tab",
            repoPaths: ["/fixture/a"],
            explicit: true,
            runScoped: false
        )
        let unbound = MCPBindContextBindingSummary(
            bindingKind: "unbound",
            windowID: nil,
            contextID: nil,
            workspaceID: nil,
            workspaceName: nil,
            tabName: nil,
            repoPaths: [],
            explicit: false,
            runScoped: false
        )
        let response = BindContextResponse(
            windows: [window],
            binding: binding,
            changed: true,
            previousBinding: unbound,
            matchedBy: "working_dirs",
            createdTab: false,
            createdWorkspace: true,
            normalizedWorkingDirs: ["/fixture/a"],
            note: "Bound with frozen routing",
            error: "Authority unavailable",
            errorCode: "workspace_authority_unavailable",
            retryable: true,
            retryAfterMilliseconds: 1000
        )
        let decodedResponse = try assertWire(response, expectedJSON: """
        {
          "windows": [{
            "window_id": 7,
            "is_current_window": true,
            "workspace": {
              "id": "00000000-0000-0000-0000-000000000001",
              "name": "Routing Workspace"
            },
            "active_context_id": "00000000-0000-0000-0000-000000000003",
            "tabs": [{
              "context_id": "00000000-0000-0000-0000-000000000003",
              "name": "Bound Tab",
              "workspace_id": "00000000-0000-0000-0000-000000000001",
              "workspace_name": "Routing Workspace",
              "is_active": true,
              "is_bound": false,
              "repo_paths": ["/fixture/a"]
            }]
          }],
          "binding": {
            "binding_kind": "tab_context",
            "window_id": 7,
            "context_id": "00000000-0000-0000-0000-000000000003",
            "workspace_id": "00000000-0000-0000-0000-000000000001",
            "workspace_name": "Routing Workspace",
            "tab_name": "Bound Tab",
            "repo_paths": ["/fixture/a"],
            "explicit": true,
            "run_scoped": false
          },
          "changed": true,
          "previous_binding": {
            "binding_kind": "unbound",
            "repo_paths": [],
            "explicit": false,
            "run_scoped": false
          },
          "matched_by": "working_dirs",
          "created_tab": false,
          "created_workspace": true,
          "normalized_working_dirs": ["/fixture/a"],
          "note": "Bound with frozen routing",
          "error": "Authority unavailable",
          "error_code": "workspace_authority_unavailable",
          "retryable": true,
          "retry_after_ms": 1000
        }
        """)
        XCTAssertEqual(decodedResponse.windows, [window])
        XCTAssertEqual(decodedResponse.binding, binding)
        XCTAssertEqual(decodedResponse.changed, true)
        XCTAssertEqual(decodedResponse.previousBinding, unbound)
        XCTAssertEqual(decodedResponse.matchedBy, "working_dirs")
        XCTAssertEqual(decodedResponse.createdTab, false)
        XCTAssertEqual(decodedResponse.createdWorkspace, true)
        XCTAssertEqual(decodedResponse.normalizedWorkingDirs, ["/fixture/a"])
        XCTAssertEqual(decodedResponse.note, "Bound with frozen routing")
        XCTAssertEqual(decodedResponse.error, "Authority unavailable")
        XCTAssertEqual(decodedResponse.errorCode, "workspace_authority_unavailable")
        XCTAssertEqual(decodedResponse.retryable, true)
        XCTAssertEqual(decodedResponse.retryAfterMilliseconds, 1000)

        let minimalResponse = try assertWire(BindContextResponse(binding: unbound), expectedJSON: """
        {
          "binding": {
            "binding_kind": "unbound",
            "repo_paths": [],
            "explicit": false,
            "run_scoped": false
          }
        }
        """)
        XCTAssertEqual(minimalResponse.binding, unbound)
        XCTAssertNil(minimalResponse.windows)
        XCTAssertNil(minimalResponse.changed)
        XCTAssertNil(minimalResponse.previousBinding)
        XCTAssertNil(minimalResponse.matchedBy)
        XCTAssertNil(minimalResponse.createdTab)
        XCTAssertNil(minimalResponse.createdWorkspace)
        XCTAssertNil(minimalResponse.normalizedWorkingDirs)
        XCTAssertNil(minimalResponse.note)
        XCTAssertNil(minimalResponse.error)
        XCTAssertNil(minimalResponse.errorCode)
        XCTAssertNil(minimalResponse.retryable)
        XCTAssertNil(minimalResponse.retryAfterMilliseconds)

        let emptyWindow = MCPBindContextWindowSummary(
            windowID: 7,
            isCurrentWindow: false,
            workspace: nil,
            activeContextID: nil,
            tabs: []
        )
        XCTAssertEqual(try assertWire(emptyWindow, expectedJSON: """
        {"window_id": 7, "is_current_window": false, "tabs": []}
        """), emptyWindow)
    }

    func testBindContextSelectorPrecedenceAndConflictingPrimaryRejection() throws {
        let contextID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let readCases: [(selectors: [String: Value], kind: String?, context: UUID?, dirs: [String], window: Int?)] = [
            (["context_id": .string(contextID.uuidString), "working_dirs": .array([.string("/fixture/a")]), "window_id": .int(7)], "context_id", contextID, ["/fixture/a"], 7),
            (["working_dirs": .array([.string("/fixture/a")]), "window_id": .int(7)], "working_dirs", nil, ["/fixture/a"], 7),
            (["window_id": .int(7)], "window_id", nil, [], 7),
            ([:], nil, nil, [], nil)
        ]
        for op in ["list", "status"] {
            for entry in readCases {
                var args = entry.selectors
                args["op"] = .string(op)
                let request = try WindowRoutingService.parseBindContextRequest(args)
                XCTAssertEqual(request.op.rawValue, op)
                XCTAssertEqual(request.matchKind?.rawValue, entry.kind)
                XCTAssertEqual(request.contextID, entry.context)
                XCTAssertEqual(request.workingDirs, entry.dirs)
                XCTAssertEqual(request.windowID, entry.window)
                XCTAssertFalse(request.createIfMissing)
                XCTAssertNil(request.tabName)
            }
        }

        let bindCases: [(selectors: [String: Value], kind: String, context: UUID?, dirs: [String])] = [
            (["context_id": .string(contextID.uuidString), "window_id": .int(7)], "context_id", contextID, []),
            (["working_dirs": .array([.string("/fixture/a")]), "window_id": .int(7)], "working_dirs", nil, ["/fixture/a"]),
            (["window_id": .int(7)], "window_id", nil, [])
        ]
        for entry in bindCases {
            var args = entry.selectors
            args["op"] = .string("bind")
            let request = try WindowRoutingService.parseBindContextRequest(args)
            XCTAssertEqual(request.op.rawValue, "bind")
            XCTAssertEqual(request.matchKind?.rawValue, entry.kind)
            XCTAssertEqual(request.contextID, entry.context)
            XCTAssertEqual(request.workingDirs, entry.dirs)
            XCTAssertEqual(request.windowID, 7)
            XCTAssertFalse(request.createIfMissing)
            XCTAssertNil(request.tabName)
        }

        let creatingRequest = try WindowRoutingService.parseBindContextRequest([
            "op": .string("bind"),
            "working_dirs": .array([.string("/fixture/a")]),
            "window_id": .int(7),
            "create_if_missing": .bool(true),
            "tab_name": .string("  New Tab  ")
        ])
        XCTAssertEqual(creatingRequest.op.rawValue, "bind")
        XCTAssertEqual(creatingRequest.matchKind?.rawValue, "working_dirs")
        XCTAssertNil(creatingRequest.contextID)
        XCTAssertEqual(creatingRequest.workingDirs, ["/fixture/a"])
        XCTAssertEqual(creatingRequest.windowID, 7)
        XCTAssertTrue(creatingRequest.createIfMissing)
        XCTAssertEqual(creatingRequest.tabName, "New Tab")

        XCTAssertThrowsError(try WindowRoutingService.parseBindContextRequest([
            "op": .string("bind"),
            "context_id": .string(contextID.uuidString),
            "working_dirs": .array([.string("/fixture/a")]),
            "window_id": .int(7)
        ])) { error in
            guard let mcpError = error as? MCPError, case let .invalidParams(message) = mcpError else {
                XCTFail("Expected conflicting-primary invalidParams, got \(error)")
                return
            }
            XCTAssertEqual(message, "bind_context op='bind' accepts exactly one primary selector: context_id, working_dirs, or window_id.")
        }
    }

    func testRunPurposeCodablePreservesRawCasesAndRejectsUnknown() throws {
        let cases: [(purpose: MCPRunPurpose, raw: String)] = [
            (.discoverRun, "discoverRun"),
            (.agentModeRun, "agentModeRun"),
            (.unknown, "unknown")
        ]
        for entry in cases {
            let expected = Data("\"\(entry.raw)\"".utf8)
            let encoded = try JSONEncoder().encode(entry.purpose)
            XCTAssertEqual(entry.purpose.rawValue, entry.raw)
            XCTAssertEqual(encoded, expected)
            XCTAssertEqual(try JSONDecoder().decode(MCPRunPurpose.self, from: expected), entry.purpose)
            XCTAssertEqual(try JSONDecoder().decode(MCPRunPurpose.self, from: encoded), entry.purpose)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(MCPRunPurpose.self, from: Data("\"futureRun\"".utf8))) { error in
            guard case let DecodingError.dataCorrupted(context) = error else {
                XCTFail("Expected unknown run-purpose dataCorrupted, got \(error)")
                return
            }
            XCTAssertTrue(context.codingPath.isEmpty)
        }
    }

    #if DEBUG
        @MainActor
        func testExplicitBindThenContextIDRoutedToolUsesSameCompositeContext() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("repoprompt-bind-routing-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: rootURL)
            }

            let contextID = UUID()
            let staleMatch = workspace(name: "Stored Target", root: rootURL.path, contextID: contextID)
            let unrelated = workspace(
                name: "Active Unrelated",
                root: rootURL.appendingPathComponent("unrelated").path,
                contextID: UUID()
            )
            let activeTarget = workspace(name: "Active Target", root: rootURL.path, contextID: contextID)
            let replacementActive = workspace(
                name: "Replacement Active",
                root: rootURL.appendingPathComponent("replacement").path,
                contextID: UUID()
            )
            let orderedWindows = [makeWindowInstance(), makeWindowInstance()].sorted { $0.windowID < $1.windowID }
            let staleWindow = orderedWindows[0]
            let targetWindow = orderedWindows[1]
            try await configureWindow(staleWindow, activeWorkspace: unrelated, savedWorkspaces: [staleMatch])
            try await configureWindow(targetWindow, activeWorkspace: activeTarget)
            _ = installWindows(orderedWindows)
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let staleToolsEnabled = await staleWindow.mcpServer.setWindowToolsEnabled(true)
            let targetToolsEnabled = await targetWindow.mcpServer.setWindowToolsEnabled(true)
            XCTAssertTrue(staleToolsEnabled)
            XCTAssertTrue(targetToolsEnabled)
            addTeardownBlock { @MainActor in
                _ = await staleWindow.mcpServer.setWindowToolsEnabled(false)
                _ = await targetWindow.mcpServer.setWindowToolsEnabled(false)
            }

            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            let bindResult = try await connection.client.callTool(name: "bind_context", arguments: [
                "op": .string("bind"),
                "context_id": .string(contextID.uuidString),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(bindResult.isError, true, toolText(bindResult))

            let boundBeforeCall = targetWindow.mcpServer.connectionBindingSnapshot(
                forConnection: connection.connectionID
            )
            XCTAssertEqual(boundBeforeCall.windowID, targetWindow.windowID)
            XCTAssertEqual(boundBeforeCall.workspaceID, activeTarget.id)
            XCTAssertEqual(boundBeforeCall.tabID, contextID)
            XCTAssertTrue(boundBeforeCall.explicitlyBound)
            XCTAssertNil(boundBeforeCall.runID)

            let routedResult = try await connection.client.callTool(name: "workspace_context", arguments: [
                "context_id": .string(contextID.uuidString),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(routedResult.isError, true, toolText(routedResult))

            try await configureWindow(
                targetWindow,
                activeWorkspace: replacementActive,
                savedWorkspaces: [activeTarget]
            )
            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspaceID, replacementActive.id)

            let routedAfterWorkspaceSwitch = try await connection.client.callTool(
                name: "workspace_context",
                arguments: [
                    "context_id": .string(contextID.uuidString),
                    "_rawJSON": .bool(true)
                ]
            )
            XCTAssertNotEqual(
                routedAfterWorkspaceSwitch.isError,
                true,
                toolText(routedAfterWorkspaceSwitch)
            )

            let statusResult = try await connection.client.callTool(name: "bind_context", arguments: [
                "op": .string("status"),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(statusResult.isError, true, toolText(statusResult))
            let statusData = try XCTUnwrap(toolText(statusResult).data(using: .utf8))
            let status = try JSONDecoder().decode(BindContextResponse.self, from: statusData)
            XCTAssertEqual(status.binding.windowID, targetWindow.windowID)
            XCTAssertEqual(status.binding.workspaceID, activeTarget.id)
            XCTAssertEqual(status.binding.contextID, contextID)
            XCTAssertTrue(status.binding.explicit)
            XCTAssertFalse(status.binding.runScoped)

            let boundAfterCall = targetWindow.mcpServer.connectionBindingSnapshot(
                forConnection: connection.connectionID
            )
            XCTAssertEqual(boundAfterCall.windowID, boundBeforeCall.windowID)
            XCTAssertEqual(boundAfterCall.workspaceID, boundBeforeCall.workspaceID)
            XCTAssertEqual(boundAfterCall.tabID, boundBeforeCall.tabID)
            XCTAssertTrue(boundAfterCall.explicitlyBound)
            XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)

            await connection.cleanup()
            let networkManagerRunningAfterCleanup = await ServerNetworkManager.shared.isRunning()
            XCTAssertEqual(networkManagerRunningAfterCleanup, connection.wasNetworkManagerRunning)
        }
    #endif

    @MainActor
    func testContextIDBindIgnoresPreferredInactiveWorkspaceMatch() async throws {
        let contextID = UUID()
        let target = workspace(name: "Target", root: "/tmp/repoprompt-bind-target", contextID: contextID)
        let unrelated = workspace(name: "Unrelated", root: "/tmp/repoprompt-bind-unrelated", contextID: UUID())
        let staleWindow = try await makeWindow(activeWorkspace: unrelated, savedWorkspaces: [target])
        let targetWindow = try await makeWindow(activeWorkspace: target)
        let service = installWindows([staleWindow, targetWindow])

        let resolved = try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: staleWindow.windowID
        )

        XCTAssertEqual(resolved.windowID, targetWindow.windowID)
        XCTAssertEqual(resolved.workspaceID, target.id)
        XCTAssertEqual(resolved.tabID, contextID)
        XCTAssertEqual(resolved.repoPaths, target.repoPaths)
        XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)
    }

    @MainActor
    func testContextIDBindDeterministicFallbackExcludesInactiveWorkspaceMatch() async throws {
        let contextID = UUID()
        let root = "/tmp/repoprompt-bind-target"
        let inactiveDuplicate = workspace(name: "Stored Target", root: root, contextID: contextID)
        let firstTarget = workspace(name: "First Active Target", root: root, contextID: contextID)
        let secondTarget = workspace(name: "Second Active Target", root: root, contextID: contextID)
        let unrelated = workspace(name: "Unrelated", root: "/tmp/repoprompt-bind-unrelated", contextID: UUID())
        let staleWindow = try await makeWindow(activeWorkspace: unrelated, savedWorkspaces: [inactiveDuplicate])
        let firstTargetWindow = try await makeWindow(activeWorkspace: firstTarget)
        let secondTargetWindow = try await makeWindow(activeWorkspace: secondTarget)
        let service = installWindows([staleWindow, firstTargetWindow, secondTargetWindow])
        let expectedWindow = try XCTUnwrap(
            [firstTargetWindow, secondTargetWindow].min { $0.windowID < $1.windowID }
        )
        let expectedWorkspace = expectedWindow.windowID == firstTargetWindow.windowID ? firstTarget : secondTarget

        let resolved = try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: nil
        )

        XCTAssertEqual(resolved.windowID, expectedWindow.windowID)
        XCTAssertEqual(resolved.workspaceID, expectedWorkspace.id)
        XCTAssertEqual(resolved.tabID, contextID)
        XCTAssertEqual(resolved.repoPaths, expectedWorkspace.repoPaths)
        XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)
    }

    @MainActor
    func testContextIDBindOnlyInactiveMatchFailsClosed() async throws {
        let contextID = UUID()
        let target = workspace(name: "Target", root: "/tmp/repoprompt-bind-target", contextID: contextID)
        let unrelated = workspace(name: "Unrelated", root: "/tmp/repoprompt-bind-unrelated", contextID: UUID())
        let staleWindow = try await makeWindow(activeWorkspace: unrelated, savedWorkspaces: [target])
        let service = installWindows([staleWindow])

        XCTAssertThrowsError(try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: staleWindow.windowID
        )) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("No open RepoPrompt window actively shows context_id"), message)
        }
        XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)
    }

    #if DEBUG
        @MainActor
        func testMaterializedWindowBindingWithoutInvocationContextFailsClosedWithDiagnostic() async throws {
            let window = makeWindowInstance()
            addTeardownBlock { @MainActor in await window.tearDown() }
            let tools = await window.mcpServer.windowMCPTools
            let tool = try XCTUnwrap(tools.first { $0.name == "workspace_context" })
            let diagnostics = PR4InvocationDiagnosticRecorder()
            let executionCountBefore = window.mcpServer.test_activeToolExecutionCount()

            // Invoke the production materialized binding, not require() in isolation.
            // No network packet and no trusted-local scope may manufacture authority.
            await MCPInvocationContextBridge.currentTaskLocal.withValue(nil) {
                await MCPInvocationContextBridge.$diagnosticSink.withValue({ diagnostics.record($0) }) {
                    do {
                        _ = try await tool(["op": .string("snapshot")])
                        XCTFail("An unscoped window binding must not enter its provider")
                    } catch {
                        XCTAssertEqual(error as? MCPInvocationContextFailure, .missingExpectedContext)
                    }
                }
            }
            XCTAssertEqual(diagnostics.snapshot(), [.missingExpectedContext])
            XCTAssertEqual(window.mcpServer.test_activeToolExecutionCount(), executionCountBefore)
        }

        private func toolText(_ result: (content: [MCP.Tool.Content], isError: Bool?)) -> String {
            result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined(separator: "\n")
        }
    #endif

    @MainActor
    private func makeWindowInstance() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        return WindowState()
    }

    @MainActor
    private func configureWindow(
        _ window: WindowState,
        activeWorkspace: WorkspaceModel,
        savedWorkspaces: [WorkspaceModel] = []
    ) async throws {
        await window.workspaceManager.awaitInitialized()
        window.workspaceManager.workspaces = [activeWorkspace] + savedWorkspaces
        _ = await window.workspaceManager.switchWorkspace(
            to: activeWorkspace,
            saveState: false,
            reason: "bindContextRoutingAuthorityTest"
        )
        guard window.workspaceManager.activeWorkspaceID == activeWorkspace.id else {
            throw BindContextRoutingFixtureError.workspaceActivationFailed
        }
    }

    #if DEBUG
        private func makeProductionMCPConnection() async throws -> ProductionMCPConnection {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
            }
            defer {
                for descriptor in descriptors where descriptor >= 0 {
                    Darwin.close(descriptor)
                }
            }

            let connectionID = UUID()
            let sessionToken = "bind-routing-\(UUID().uuidString)"
            let clientName = "BindContextRoutingAuthorityTests"
            let networkManager = ServerNetworkManager.shared
            let wasNetworkManagerRunning = await networkManager.isRunning()
            let connectionManager = try BootstrapSocketConnectionManager(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientPid: Int(getpid()),
                observedKernelPeerPID: Int(getpid()),
                clientName: clientName,
                purpose: .unknown,
                codeMapsDisabled: true,
                connectedFD: descriptors[0],
                parentManager: networkManager
            )
            descriptors[0] = -1
            let clientTransport = try UnixSocketMCPTransport(
                connectedFD: descriptors[1],
                connectionID: connectionID,
                correlationConnectionID: sessionToken
            )
            descriptors[1] = -1
            await networkManager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: connectionManager,
                pendingClientID: clientName
            )
            _ = await networkManager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)

            do {
                try await connectionManager.start { $0.name == clientName }
                let client = Client(name: clientName, version: "1.0")
                _ = try await client.connect(transport: clientTransport)
                return ProductionMCPConnection(
                    client: client,
                    connectionID: connectionID,
                    connectionManager: connectionManager,
                    wasNetworkManagerRunning: wasNetworkManagerRunning
                )
            } catch {
                await clientTransport.disconnect()
                await connectionManager.stop()
                await networkManager.debugRemoveConnection(connectionID)
                if !wasNetworkManagerRunning {
                    await networkManager.stop()
                }
                throw error
            }
        }
    #endif

    private func workspace(name: String, root: String, contextID: UUID) -> WorkspaceModel {
        WorkspaceModel(
            name: name,
            repoPaths: [root],
            composeTabs: [ComposeTabState(id: contextID, name: "Context")],
            activeComposeTabID: contextID
        )
    }

    @MainActor
    private func makeWindow(
        activeWorkspace: WorkspaceModel,
        savedWorkspaces: [WorkspaceModel] = []
    ) async throws -> WindowState {
        let window = makeWindowInstance()
        try await configureWindow(
            window,
            activeWorkspace: activeWorkspace,
            savedWorkspaces: savedWorkspaces
        )
        return window
    }

    @MainActor
    private func installWindows(_ windows: [WindowState]) -> WindowRoutingService {
        let previousWindows = WindowStatesManager.shared.allWindows
        WindowStatesManager.shared.allWindows = windows
        addTeardownBlock { @MainActor in
            WindowStatesManager.shared.allWindows = previousWindows
        }
        return WindowRoutingService(
            windowStates: WindowStatesManager.shared,
            networkMgr: ServerNetworkManager.shared
        )
    }
}

#if DEBUG
    private final class PR4InvocationDiagnosticRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [MCPInvocationContextFailure] = []

        func record(_ failure: MCPInvocationContextFailure) {
            lock.withLock { failures.append(failure) }
        }

        func snapshot() -> [MCPInvocationContextFailure] {
            lock.withLock { failures }
        }
    }

    private struct ProductionMCPConnection {
        let client: Client
        let connectionID: UUID
        let connectionManager: BootstrapSocketConnectionManager
        let wasNetworkManagerRunning: Bool

        func cleanup() async {
            let networkManager = ServerNetworkManager.shared
            await client.disconnect()
            await connectionManager.stop()
            await networkManager.debugRemoveConnection(connectionID)
            if !wasNetworkManagerRunning {
                await networkManager.stop()
            }
        }
    }
#endif

private enum BindContextRoutingFixtureError: Error {
    case workspaceActivationFailed
}
