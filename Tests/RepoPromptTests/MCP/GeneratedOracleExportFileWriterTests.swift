import MCP
@testable import RepoPrompt
import XCTest

final class GeneratedOracleExportFileWriterTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    func testOracleExportInstructionQuotesExactAbsolutePathLiteral() throws {
        let path = "/tmp/repo root/prompt-exports/oracle `plan`.md"
        let literal = try XCTUnwrap(String(data: JSONEncoder().encode(path), encoding: .utf8))
        let instruction = AgentOracleExport.instruction(path: path)

        XCTAssertTrue(instruction.contains("`read_file`"), instruction)
        XCTAssertTrue(instruction.contains("{\"path\": \(literal)}"), instruction)
        XCTAssertTrue(instruction.contains("exact absolute `path` value verbatim"), instruction)
    }

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testGeneratedExportWriterReturnsPathImmediatelyReadableByReadFileSemantics() async throws {
        let root = try makeTemporaryRoot(name: "OracleExportReadable")
        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        let destination = OracleExportDestination(
            workspaceID: UUID(),
            windowID: 1,
            tabID: nil,
            primaryRootPath: root.path
        )
        let exportPath = root.appendingPathComponent("prompt-exports/oracle-plan-readable.md").path

        let resolvedPath = try await GeneratedOracleExportFileWriter(store: store).write(
            path: exportPath,
            content: "# Oracle Plan\n\nRead me",
            destination: destination
        )

        XCTAssertEqual(resolvedPath, StandardizedPath.absolute(exportPath))
        let readableService = WorkspaceReadableFileService(store: store)
        switch await readableService.resolveReadableFile(resolvedPath, profile: .mcpRead, rootScope: .visibleWorkspace) {
        case let .some(.workspace(file)):
            XCTAssertEqual(file.standardizedFullPath, resolvedPath)
            let content = try await store.readContent(rootID: rootRecord.id, relativePath: file.standardizedRelativePath)
            XCTAssertEqual(content, "# Oracle Plan\n\nRead me")
        case let .some(.external(file)):
            XCTFail("Generated export should resolve as workspace file, got external file: \(file.displayPath)")
        case nil:
            XCTFail("Generated export was not readable through WorkspaceReadableFileService")
        }
    }

    func testGeneratedExportWriterWritesToBoundWorktreeAndReturnsLogicalPath() async throws {
        let logicalRoot = try makeTemporaryRoot(name: "OracleExportLogical")
        let worktreeRoot = try makeTemporaryRoot(name: "OracleExportWorktree")
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let sessionID = UUID()
        let binding = makeBinding(logicalRoot: logicalRoot, worktreeRoot: worktreeRoot)
        let materializedProjection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: [binding]
        )
        let projection = try XCTUnwrap(materializedProjection)
        let lookupContext = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let destination = OracleExportDestination(
            workspaceID: UUID(),
            windowID: 1,
            tabID: nil,
            primaryRootPath: logicalRoot.path,
            lookupContext: lookupContext
        )
        let logicalExportPath = logicalRoot.appendingPathComponent("prompt-exports/oracle-plan-worktree.md").path
        let physicalExportPath = worktreeRoot.appendingPathComponent("prompt-exports/oracle-plan-worktree.md").path

        let resolvedPath = try await GeneratedOracleExportFileWriter(store: store).write(
            path: logicalExportPath,
            content: "# Bound Worktree Export",
            destination: destination
        )

        XCTAssertEqual(resolvedPath, StandardizedPath.absolute(logicalExportPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logicalExportPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: physicalExportPath))
        XCTAssertEqual(try String(contentsOfFile: physicalExportPath), "# Bound Worktree Export")
        let readable = await WorkspaceReadableFileService(store: store).resolveReadableFile(
            lookupContext.translateInputPath(resolvedPath),
            profile: .mcpRead,
            rootScope: lookupContext.rootScope
        )
        guard case let .workspace(file) = readable else {
            return XCTFail("Returned logical export path should translate to a readable bound-worktree file")
        }
        XCTAssertEqual(file.standardizedFullPath, StandardizedPath.absolute(physicalExportPath))
    }

    func testGeneratedExportWriterRejectsUnloadedPrimaryRootWithoutDirectFileManagerFallback() async throws {
        let root = try makeTemporaryRoot(name: "OracleExportUnloaded")
        let store = WorkspaceFileContextStore()
        let destination = OracleExportDestination(
            workspaceID: UUID(),
            windowID: 1,
            tabID: nil,
            primaryRootPath: root.path
        )
        let exportPath = root.appendingPathComponent("prompt-exports/oracle-plan-unloaded.md").path

        do {
            _ = try await GeneratedOracleExportFileWriter(store: store).write(
                path: exportPath,
                content: "unreadable",
                destination: destination
            )
            XCTFail("Expected unloaded generated export root to fail")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("not loaded in the bound read_file workspace scope"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportPath), "Generated exports must not direct-write outside loaded read_file roots")
    }

    func testGeneratedExportWriterAllowsIgnoredAppManagedExportWithoutDiscoveryExposure() async throws {
        let root = try makeTemporaryRoot(name: "OracleExportIgnored")
        try write("prompt-exports/\n", to: root.appendingPathComponent(".gitignore"))
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let destination = OracleExportDestination(
            workspaceID: UUID(),
            windowID: 1,
            tabID: nil,
            primaryRootPath: root.path
        )
        let exportPath = root.appendingPathComponent("prompt-exports/oracle-plan-ignored.md").path

        let resolvedPath = try await GeneratedOracleExportFileWriter(store: store).write(
            path: exportPath,
            content: "ignored",
            destination: destination
        )

        XCTAssertEqual(resolvedPath, exportPath)
        let readableService = WorkspaceReadableFileService(store: store)
        let ignoredReadableFile = await readableService.resolveReadableFile(exportPath, profile: .mcpRead, rootScope: .visibleWorkspace)
        guard case let .workspace(file) = ignoredReadableFile else {
            return XCTFail("Ignored generated export should remain exactly readable through read_file semantics")
        }
        let content = try await store.readContent(rootID: file.rootID, relativePath: file.standardizedRelativePath)
        XCTAssertEqual(content, "ignored")
        let searchSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertFalse(searchSnapshot.files.contains { $0.standardizedFullPath == exportPath })

        let treeSnapshot = await store.makeFileTreeSelectionSnapshot(
            selection: StoredSelection(),
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: false,
                rootScope: .visibleWorkspace
            ),
            profile: .mcpRead
        )
        let tree = CodeMapExtractor.generateFileTree(using: treeSnapshot)
        XCTAssertFalse(tree.contains("prompt-exports"), tree)
        XCTAssertFalse(tree.contains("oracle-plan-ignored.md"), tree)
    }

    func testGeneratedExportWriterCleansUpSymlinkedExportPathFailure() async throws {
        let root = try makeTemporaryRoot(name: "OracleExportSymlink")
        let outside = try makeTemporaryRoot(name: "OracleExportSymlinkOutside")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("prompt-exports"),
            withDestinationURL: outside
        )
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let destination = OracleExportDestination(
            workspaceID: UUID(),
            windowID: 1,
            tabID: nil,
            primaryRootPath: root.path
        )
        let exportPath = root.appendingPathComponent("prompt-exports/oracle-plan-symlink.md").path
        let outsideTarget = outside.appendingPathComponent("oracle-plan-symlink.md").path

        do {
            _ = try await GeneratedOracleExportFileWriter(store: store).write(
                path: exportPath,
                content: "symlinked",
                destination: destination
            )
            XCTFail("Expected symlinked generated export path to fail")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("not readable by read_file") || message.contains("symlink"), message)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideTarget), "Rejected generated exports should clean up symlinked disk artifacts")
    }

    private func makeBinding(logicalRoot: URL, worktreeRoot: URL) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "oracle-export-binding",
            repositoryID: "oracle-export-repo",
            repoKey: logicalRoot.path,
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: "oracle-export-worktree",
            worktreeRootPath: worktreeRoot.path,
            worktreeName: worktreeRoot.lastPathComponent,
            branch: "feature/oracle-export",
            source: "test"
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptCE-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
