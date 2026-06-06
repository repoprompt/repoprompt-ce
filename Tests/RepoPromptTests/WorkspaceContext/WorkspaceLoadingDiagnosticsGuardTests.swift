import XCTest

final class WorkspaceLoadingDiagnosticsGuardTests: XCTestCase {
    func testDebugDiagnosticsExposeStoreBackedLoadingSnapshot() throws {
        let root = try RepoRoot.url()
        let diagnosticsDirectory = root.appendingPathComponent("Sources/RepoPrompt/Features/Diagnostics/MCP")
        let diagnosticsFiles = try FileManager.default.contentsOfDirectory(
            at: diagnosticsDirectory,
            includingPropertiesForKeys: nil
        )
        .filter {
            $0.lastPathComponent.hasPrefix("MCPConnectionManager+DebugDiagnostics")
                && $0.pathExtension == "swift"
        }
        XCTAssertFalse(diagnosticsFiles.isEmpty, "Debug MCP diagnostics source files should exist.")
        let diagnostics = try diagnosticsFiles
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertTrue(diagnostics.contains("workspace_loading_snapshot"), "Debug MCP diagnostics should expose a workspace loading snapshot op.")
        XCTAssertTrue(diagnostics.contains("catalogDiagnostics(rootScope: .visibleWorkspace)"), "Workspace loading diagnostics should report canonical store catalog counts.")
        XCTAssertTrue(diagnostics.contains("workspaceSearchReadinessState"), "Workspace loading diagnostics should report readiness state.")
        XCTAssertTrue(diagnostics.contains("indexed_path_count"), "Workspace loading diagnostics should report search index state.")
        XCTAssertTrue(diagnostics.contains("ui_projection"), "Workspace loading diagnostics should keep UI projection counts explicit and secondary.")
        XCTAssertTrue(diagnostics.contains("workspace_switch"), "Workspace loading diagnostics should report workspace switch timing context.")
        XCTAssertTrue(diagnostics.contains("debug_open_trace"), "Workspace loading diagnostics should expose the DEBUG workspace open trace.")
        XCTAssertTrue(diagnostics.contains("workspaceSwitch.loadWorkspaceFolders.firstPrimaryRootVisible"), "Timing notes should preserve the first-root-visible event contract.")
        XCTAssertTrue(diagnostics.contains("workspaceSwitch.loadWorkspaceFolders.rootShellPossible"), "Timing notes should expose root-shell-possible attribution.")
        XCTAssertTrue(diagnostics.contains("workspaceSwitch.loadWorkspaceFolders.rootVisibilitySummary"), "Timing notes should expose root visibility summary attribution.")
        XCTAssertTrue(diagnostics.contains("rootCatalogCompleteAfterVisible"), "Timing notes should reserve catalog-complete-after-visible attribution.")
        XCTAssertTrue(diagnostics.contains("workspaceSwitch.overlay.hidden"), "Timing notes should preserve the overlay hidden event contract.")
        XCTAssertFalse(diagnostics.contains("debugCountTreeShape"), "Diagnostics must not recursively count FolderViewModel trees as the loading source of truth.")
        XCTAssertFalse(diagnostics.contains("rootSummary"), "Diagnostics must not describe workspace size from rootFolders tree summaries.")

        let storePath = root.appendingPathComponent("Sources/RepoPromptCore/WorkspaceContext/WorkspaceFileContextStore.swift")
        let storeSource = try String(contentsOf: storePath, encoding: .utf8)
        XCTAssertFalse(storeSource.contains("WorkspaceRootLoadDebugContext"), "Root-load trace context should not live in the core workspace store API.")
        XCTAssertFalse(storeSource.contains("debugContext:"), "WorkspaceFileContextStore.loadRoot should not accept measurement-only debug context.")

        let managerPath = root.appendingPathComponent("Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift")
        let managerSource = try String(contentsOf: managerPath, encoding: .utf8)
        XCTAssertTrue(managerSource.contains("WorkspaceRootLoadDiagnostics"), "Workspace manager should scope root-load diagnostics through the DEBUG diagnostics helper.")
    }
}
