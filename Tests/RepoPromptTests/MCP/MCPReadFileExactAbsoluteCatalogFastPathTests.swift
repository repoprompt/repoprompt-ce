@testable import RepoPrompt
import XCTest

final class MCPReadFileExactAbsoluteCatalogFastPathTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testReadFileSourceOrderKeepsValidationAndRootsBeforeExactAbsoluteShortcutAndFallbackAfterIt() throws {
        let source = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
        let readFile = try XCTUnwrap(source.slice(
            from: "    private func readFile(\n",
            to: "    /// Performs a file action (create, delete, or move/rename)\n"
        ))

        try assertOrdered([
            "await store.exactPathResolutionIssue(for: path, kind: .either, rootScope: lookupRootScope)",
            "await store.rootRefs(scope: lookupRootScope)",
            "await readableService.resolveExactAbsoluteWorkspaceCatalogHit(path, rootScope: lookupRootScope)",
            "await store.resolveFolderInput(path, rootScope: lookupRootScope, profile: .mcpRead)",
            "readableService.resolveAlwaysReadableExternalFolderDisplayPath(path)",
            "await readableService.resolveReadableFile(path, profile: .mcpRead, rootScope: lookupRootScope)"
        ], in: readFile)
        XCTAssertTrue(readFile.contains("return (roots, WorkspaceReadableFileHandle.workspace(exactAbsoluteCatalogHit))"))
        XCTAssertTrue(readFile.contains("is a folder; read_file requires a file path"))
    }

    func testExactAbsoluteQualificationAcceptsTrimmedAndTildeExpandedAbsoluteInputsOnly() {
        XCTAssertEqual(
            WorkspaceReadableFileService.exactAbsoluteCatalogHitInput("  /tmp/example.swift\n"),
            "/tmp/example.swift"
        )
        let tildeExpanded = WorkspaceReadableFileService.exactAbsoluteCatalogHitInput("~/example.swift")
        XCTAssertEqual(tildeExpanded, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("example.swift").path)
        XCTAssertNil(WorkspaceReadableFileService.exactAbsoluteCatalogHitInput(""))
        XCTAssertNil(WorkspaceReadableFileService.exactAbsoluteCatalogHitInput(" \n "))
        XCTAssertNil(WorkspaceReadableFileService.exactAbsoluteCatalogHitInput("Sources/A.swift"))
        XCTAssertNil(WorkspaceReadableFileService.exactAbsoluteCatalogHitInput("RootAlias/Sources/A.swift"))
    }

    func testExactAbsoluteCatalogHitReturnsDeepestNestedRootRecord() async throws {
        let parent = try makeTemporaryRoot(name: "NestedParent")
        let nested = parent.appendingPathComponent("NestedRoot", isDirectory: true)
        let fileURL = nested.appendingPathComponent("Sources/Visible.swift")
        try write("visible", to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: parent.path)
        let nestedRecord = try await store.loadRoot(path: nested.path)
        let service = WorkspaceReadableFileService(store: store)

        let hit = await service.resolveExactAbsoluteWorkspaceCatalogHit(fileURL.path, rootScope: .visibleWorkspace)
        XCTAssertEqual(hit?.rootID, nestedRecord.id)
        XCTAssertEqual(hit?.standardizedFullPath, fileURL.path)
    }

    func testRelativeAndAliasCatalogHitsDoNotUseShortcut() async throws {
        let root = try makeTemporaryRoot(name: "RelativeAlias")
        let fileURL = root.appendingPathComponent("Sources/Visible.swift")
        try write("visible", to: fileURL)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let service = WorkspaceReadableFileService(store: store)
        let relative = "Sources/Visible.swift"
        let alias = "\(record.name)/Sources/Visible.swift"

        guard case .matched = await store.lookupCatalogFileForExplicitRequest(relative, rootScope: .visibleWorkspace) else {
            return XCTFail("Expected the store to preserve relative catalog lookup")
        }
        guard case .matched = await store.lookupCatalogFileForExplicitRequest(alias, rootScope: .visibleWorkspace) else {
            return XCTFail("Expected the store to preserve alias catalog lookup")
        }
        let relativeHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(relative, rootScope: .visibleWorkspace)
        let aliasHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(alias, rootScope: .visibleWorkspace)
        XCTAssertNil(relativeHit)
        XCTAssertNil(aliasHit)
    }

    func testAbsoluteCatalogMissFallsThroughToIgnoredFileMaterialization() async throws {
        let root = try makeTemporaryRoot(name: "IgnoredMaterialization")
        try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
        let ignoredURL = root.appendingPathComponent("existing.ignored")
        try write("hidden", to: ignoredURL)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        let service = WorkspaceReadableFileService(store: store)

        let shortcutHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(ignoredURL.path, rootScope: .visibleWorkspace)
        XCTAssertNil(shortcutHit)
        let readable = await service.resolveReadableFile(ignoredURL.path, profile: .mcpRead, rootScope: .visibleWorkspace)
        guard case let .workspace(file) = readable else {
            return XCTFail("Expected ignored absolute miss to materialize through the existing fallback")
        }
        XCTAssertEqual(file.rootID, record.id)
        XCTAssertEqual(file.standardizedFullPath, ignoredURL.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertFalse(snapshot.files.contains { $0.standardizedFullPath == ignoredURL.path })
    }

    func testFolderAndExternalSupportPathsRemainFallbackOnly() async throws {
        let root = try makeTemporaryRoot(name: "FolderFallback")
        let folderURL = root.appendingPathComponent("Sources", isDirectory: true)
        try write("visible", to: folderURL.appendingPathComponent("Visible.swift"))
        let home = try makeTemporaryRoot(name: "ExternalHome")
        let externalFolder = home.appendingPathComponent(".agents/skills/example", isDirectory: true)
        let externalFile = externalFolder.appendingPathComponent("SKILL.md")
        try write("skill body", to: externalFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = WorkspaceReadableFileService(store: store, homeDirectoryURL: home)

        let folderShortcutHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(folderURL.path, rootScope: .visibleWorkspace)
        XCTAssertNil(folderShortcutHit)
        let folderResolution = await store.resolveFolderInput(folderURL.path, rootScope: .visibleWorkspace, profile: .mcpRead)
        XCTAssertEqual(folderResolution.folder?.standardizedFullPath, folderURL.path)

        let externalShortcutHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(externalFile.path, rootScope: .visibleWorkspace)
        XCTAssertNil(externalShortcutHit)
        XCTAssertEqual(service.resolveAlwaysReadableExternalFolderDisplayPath(externalFolder.path), "~/.agents/skills/example")
        let readable = await service.resolveReadableFile(externalFile.path, profile: .mcpRead, rootScope: .visibleWorkspace)
        guard case let .external(file) = readable else {
            return XCTFail("Expected external support file to resolve through the existing fallback")
        }
        XCTAssertEqual(file.displayPath, "~/.agents/skills/example/SKILL.md")
    }

    func testNonMatchedLookupOutcomesCannotShortCircuit() async throws {
        let parentA = try makeTemporaryRoot(name: "AmbiguousAliasParentA")
        let parentB = try makeTemporaryRoot(name: "AmbiguousAliasParentB")
        let rootA = parentA.appendingPathComponent("App", isDirectory: true)
        let rootB = parentB.appendingPathComponent("App", isDirectory: true)
        try write("a", to: rootA.appendingPathComponent("Visible.swift"))
        try write("b", to: rootB.appendingPathComponent("Visible.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: rootA.path)
        _ = try await store.loadRoot(path: rootB.path)
        let service = WorkspaceReadableFileService(store: store)
        let missing = parentA.appendingPathComponent("missing.swift").path
        let blocked = "/tmp/blocked\0.swift"
        let ambiguousAlias = "App/Visible.swift"

        let missingLookup = await store.lookupCatalogFileForExplicitRequest(missing, rootScope: .visibleWorkspace)
        let missingShortcutHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(missing, rootScope: .visibleWorkspace)
        let blockedLookup = await store.lookupCatalogFileForExplicitRequest(blocked, rootScope: .visibleWorkspace)
        let blockedShortcutHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(blocked, rootScope: .visibleWorkspace)
        let ambiguousLookup = await store.lookupCatalogFileForExplicitRequest(ambiguousAlias, rootScope: .visibleWorkspace)
        let ambiguousShortcutHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(ambiguousAlias, rootScope: .visibleWorkspace)
        XCTAssertEqual(missingLookup, .noCandidate)
        XCTAssertNil(missingShortcutHit)
        XCTAssertEqual(blockedLookup, .blocked)
        XCTAssertNil(blockedShortcutHit)
        XCTAssertEqual(ambiguousLookup, .ambiguous)
        XCTAssertNil(ambiguousShortcutHit)
    }

    func testEmptyAndEmbeddedNULIssuesRemainValidatedBeforeShortcut() async throws {
        let store = WorkspaceFileContextStore()
        let emptyIssue = await store.exactPathResolutionIssue(for: " \n ", kind: .either, rootScope: .visibleWorkspace)
        XCTAssertEqual(emptyIssue, .emptyInput)
        let issue = await store.exactPathResolutionIssue(for: "/tmp/blocked\0.swift", kind: .either, rootScope: .visibleWorkspace)
        guard case let .invalidPathCharacters(input, reason) = issue else {
            return XCTFail("Expected embedded NUL validation issue")
        }
        XCTAssertEqual(input, "/tmp/blocked\0.swift")
        XCTAssertTrue(reason.contains("embedded NUL"))

        let source = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
        let validation = try XCTUnwrap(source.range(of: "await store.exactPathResolutionIssue(for: path"))
        let shortcut = try XCTUnwrap(source.range(of: "await readableService.resolveExactAbsoluteWorkspaceCatalogHit(path"))
        XCTAssertLessThan(validation.lowerBound, shortcut.lowerBound)
    }

    func testShortcutHonorsVisibleGitDataAndSessionBoundScopes() async throws {
        let logicalRoot = try makeTemporaryRoot(name: "LogicalRoot")
        let gitDataRoot = try makeTemporaryRoot(name: "GitDataRoot")
        let worktreeRoot = try makeTemporaryRoot(name: "WorktreeRoot")
        let logicalFile = logicalRoot.appendingPathComponent("Logical.swift")
        let gitDataFile = gitDataRoot.appendingPathComponent("GitData.swift")
        let worktreeFile = worktreeRoot.appendingPathComponent("Worktree.swift")
        try write("logical", to: logicalFile)
        try write("git data", to: gitDataFile)
        try write("worktree", to: worktreeFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let gitDataRecord = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let worktreeRecord = try await store.loadRoot(path: worktreeRoot.path, kind: .sessionWorktree)
        let service = WorkspaceReadableFileService(store: store)

        let visibleGitDataHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(gitDataFile.path, rootScope: .visibleWorkspace)
        XCTAssertNil(visibleGitDataHit)
        let gitDataHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(gitDataFile.path, rootScope: .visibleWorkspacePlusGitData)
        XCTAssertEqual(gitDataHit?.rootID, gitDataRecord.id)

        let visibleWorktreeHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(worktreeFile.path, rootScope: .visibleWorkspace)
        XCTAssertNil(visibleWorktreeHit)
        let sessionScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
            logicalRootPaths: [logicalRoot.path],
            physicalRootPaths: [worktreeRoot.path]
        )
        let worktreeHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(worktreeFile.path, rootScope: sessionScope)
        XCTAssertEqual(worktreeHit?.rootID, worktreeRecord.id)
        let sessionLogicalHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(logicalFile.path, rootScope: sessionScope)
        XCTAssertNil(sessionLogicalHit)
    }

    func testProviderTranslationPrecedesScopedReadDependencyCall() throws {
        let source = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
        let translation = try XCTUnwrap(source.range(of: "let resolvedPath = lookupContext.translateInputPath(path)"))
        let scopedRead = try XCTUnwrap(source.range(of: "dependencies.readFile(resolvedPath, startLine1Based, limit, lookupContext.rootScope)"))
        XCTAssertLessThan(translation.lowerBound, scopedRead.lowerBound)
    }

    private func assertOrdered(_ needles: [String], in source: String) throws {
        var lowerBound = source.startIndex
        for needle in needles {
            let range = try XCTUnwrap(source.range(of: needle, range: lowerBound ..< source.endIndex), "Missing ordered source fragment: \(needle)")
            lowerBound = range.upperBound
        }
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: RepoRoot.url().appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let startRange = range(of: startMarker),
              let endRange = range(of: endMarker, range: startRange.upperBound ..< endIndex)
        else {
            return nil
        }
        return String(self[startRange.lowerBound ..< endRange.lowerBound])
    }
}
