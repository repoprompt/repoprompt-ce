import MCP
@testable import RepoPromptApp
import XCTest

final class GeneratedOracleExportFileWriterTests: XCTestCase {
    func testOracleExportInstructionQuotesExactAbsolutePathLiteral() throws {
        let path = "/tmp/repo root/prompt-exports/oracle `plan`.md"
        let literal = try XCTUnwrap(String(data: JSONEncoder().encode(path), encoding: .utf8))
        let instruction = AgentOracleExport.instruction(path: path)

        XCTAssertTrue(instruction.contains("`read_file`"), instruction)
        XCTAssertTrue(instruction.contains("{\"path\": \(literal)}"), instruction)
        XCTAssertTrue(instruction.contains("exact absolute `path` value verbatim"), instruction)
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
        switch try await readableService.resolveReadableFile(resolvedPath, rootScope: .visibleWorkspace) {
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

    func testGeneratedExportWriterCollisionPreservesCompetingWinner() async throws {
        let root = try makeTemporaryRoot(name: "OracleExportCompetingCreator")
        let destinationURL = root.appendingPathComponent("prompt-exports/oracle-plan-collision.md")
        let winnerContent = "winner bytes must survive\n"
        let loserContent = "loser bytes must never replace\n"
        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        guard let service = await store.fileSystemServiceForTesting(rootID: rootRecord.id) else {
            return XCTFail("The isolated root must expose its filesystem service")
        }
        let gate = GeneratedOracleExportCreateGate()
        await service.setCreateFileDataPreparationForTesting { content in
            await gate.wait()
            return Data(content.utf8)
        }

        let writeTask = Task {
            try await GeneratedOracleExportFileWriter(store: store).write(
                path: destinationURL.path,
                content: loserContent,
                destination: OracleExportDestination(
                    workspaceID: UUID(),
                    windowID: 1,
                    tabID: nil,
                    primaryRootPath: root.path
                )
            )
        }

        await gate.waitUntilEntered()
        try write(winnerContent, to: destinationURL)
        await gate.open()

        do {
            _ = try await writeTask.value
            XCTFail("The losing generated export must fail")
        } catch let error as MCPError {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("path already exists"), message)
        } catch {
            XCTFail("Expected an MCP existing-path error, got \(error)")
        }
        await service.setCreateFileDataPreparationForTesting(nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), winnerContent)
    }

    func testGeneratedExportWriterRetainsOutputAfterPostDiskCatalogFailure() async throws {
        let root = try makeTemporaryRoot(name: "OracleExportPostDiskCatalogFailure")
        let destinationURL = root.appendingPathComponent("prompt-exports/oracle-plan-partial.md")
        let content = "output remains after catalog failure\n"
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        await store.setCreateFilePostDiskWriteHandlerForTesting { _, _ in
            throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                "injected post-disk catalog failure"
            )
        }

        do {
            _ = try await GeneratedOracleExportFileWriter(store: store).write(
                path: destinationURL.path,
                content: content,
                destination: OracleExportDestination(
                    workspaceID: UUID(),
                    windowID: 1,
                    tabID: nil,
                    primaryRootPath: root.path
                )
            )
            XCTFail("Expected the injected post-disk catalog failure")
        } catch let error as MCPError {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("injected post-disk catalog failure"), message)
            XCTAssertTrue(message.contains("Output may remain at the requested path"), message)
            XCTAssertTrue(message.contains("do not blindly retry"), message)
        } catch {
            XCTFail("Expected a truthful partial-state MCP error, got \(error)")
        }
        await store.setCreateFilePostDiskWriteHandlerForTesting(nil)

        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), content)
    }

    func testGeneratedExportWriterRetainsPostCreateCompetingReplacementAfterVerificationFailure() async throws {
        let root = try makeTemporaryRoot(name: "OracleExportPostCreateReplacement")
        let destinationURL = root.appendingPathComponent("prompt-exports/oracle-plan-replaced.md")
        let replacement = "competing replacement must survive\n"
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        await store.setCreateFilePostDiskWriteHandlerForTesting { _, _ in
            try replacement.write(to: destinationURL, atomically: true, encoding: .utf8)
        }

        do {
            _ = try await GeneratedOracleExportFileWriter(store: store).write(
                path: destinationURL.path,
                content: "original export content\n",
                destination: OracleExportDestination(
                    workspaceID: UUID(),
                    windowID: 1,
                    tabID: nil,
                    primaryRootPath: root.path
                )
            )
            XCTFail("Expected verification to reject the competing replacement")
        } catch let error as MCPError {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("loaded different contents"), message)
            XCTAssertTrue(message.contains("Output may remain at the requested path"), message)
        } catch {
            XCTFail("Expected a truthful post-create verification error, got \(error)")
        }
        await store.setCreateFilePostDiskWriteHandlerForTesting(nil)

        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), replacement)
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
        let readable = try await WorkspaceReadableFileService(store: store).resolveReadableFile(
            lookupContext.translateInputPath(resolvedPath),
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
        let ignoredReadableFile = try await readableService.resolveReadableFile(exportPath, rootScope: .visibleWorkspace)
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

    func testGeneratedExportWriterRejectsSymlinkedExportPathWithoutWritingOutsideWorkspace() async throws {
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

        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideTarget), "Rejected generated exports must not write outside the workspace")
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
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor GeneratedOracleExportCreateGate {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var isOpen = false

    func wait() async {
        if !hasEntered {
            hasEntered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                openContinuation = continuation
            }
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            if hasEntered {
                continuation.resume()
            } else {
                enteredContinuation = continuation
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        openContinuation?.resume()
        openContinuation = nil
    }
}
