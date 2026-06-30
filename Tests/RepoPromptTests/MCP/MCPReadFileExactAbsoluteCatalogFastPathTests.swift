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

    func testReadFileSourceOrderingPreservesRootCaptureResolutionAndProviderTranslation() throws {
        do {
            let caseLabel = "testReadFileCapturesRootsOnceBeforeFreshnessAndConsolidatedResolution"
            let viewModelSource = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            let readFile = try XCTUnwrap(viewModelSource.slice(
                from: "    private func readFile(\n",
                to: "    /// Performs a file action (create, delete, or move/rename)\n"
            ), caseLabel)

            try assertOrdered([
                "let roots = await store.rootRefs(scope: lookupRootScope)",
                "await readableService.awaitFreshnessForExplicitRequest(path, rootRefs: roots)",
                "await readableService.resolveReadFileRequest("
            ], in: readFile, label: caseLabel)
            XCTAssertEqual(readFile.components(separatedBy: "store.rootRefs(scope: lookupRootScope)").count - 1, 1, caseLabel)
            XCTAssertFalse(readFile.contains("resolveExactWorkspaceCatalogHit(path"), caseLabel)
            XCTAssertFalse(readFile.contains("resolveFolderInput(path"), caseLabel)

            let serviceSource = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceReadableFileService.swift")
            let resolver = try XCTUnwrap(serviceSource.slice(
                from: "    func resolveReadFileRequest(\n",
                to: "    func resolveAlwaysReadableExternalFolderDisplayPath"
            ), caseLabel)
            try assertOrdered([
                "store.exactPathResolutionIssue(",
                "store.lookupCatalogFileForExplicitRequest(trimmed, rootRefs: roots)",
                "allowGeneralLookupFallback: false",
                "store.materializeExplicitlyRequestedFile(",
                "let lookup = await store.lookupPath("
            ], in: resolver, label: caseLabel)
            XCTAssertEqual(resolver.components(separatedBy: "lookupCatalogFileForExplicitRequest").count - 1, 1, caseLabel)
            XCTAssertEqual(resolver.components(separatedBy: "store.lookupPath(").count - 1, 1, caseLabel)
            XCTAssertTrue(resolver.contains("is a folder") == false, caseLabel)
        }

        do {
            let caseLabel = "testProviderTranslationPrecedesScopedReadDependencyCall"
            let providerSource = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            let translation = try XCTUnwrap(providerSource.range(of: "let resolvedPath = lookupContext.translateInputPath(path)"), caseLabel)
            let authorizedRead = try XCTUnwrap(
                providerSource.range(of: "dependencies.readSelectedAuthorizedGitArtifact("),
                caseLabel
            )
            let scopedRead = try XCTUnwrap(
                providerSource.range(of: "dependencies.readFile("),
                caseLabel
            )
            XCTAssertLessThan(translation.lowerBound, authorizedRead.lowerBound, caseLabel)
            XCTAssertLessThan(authorizedRead.lowerBound, scopedRead.lowerBound, caseLabel)
        }
    }

    func testExactAbsoluteInputValidationCoversQualificationEmptyAndEmbeddedNUL() async throws {
        do {
            let caseLabel = "testExactAbsoluteQualificationAcceptsTrimmedAndTildeExpandedAbsoluteInputsOnly"
            XCTAssertEqual(
                WorkspaceReadableFileService.exactAbsoluteCatalogHitInput("  /tmp/example.swift\n"),
                "/tmp/example.swift",
                caseLabel
            )
            let tildeExpanded = WorkspaceReadableFileService.exactAbsoluteCatalogHitInput("~/example.swift")
            XCTAssertEqual(
                tildeExpanded,
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("example.swift").path,
                caseLabel
            )
            XCTAssertNil(WorkspaceReadableFileService.exactAbsoluteCatalogHitInput(""), caseLabel)
            XCTAssertNil(WorkspaceReadableFileService.exactAbsoluteCatalogHitInput(" \n "), caseLabel)
            XCTAssertNil(WorkspaceReadableFileService.exactAbsoluteCatalogHitInput("Sources/A.swift"), caseLabel)
            XCTAssertNil(WorkspaceReadableFileService.exactAbsoluteCatalogHitInput("RootAlias/Sources/A.swift"), caseLabel)
        }

        do {
            let caseLabel = "testEmptyAndEmbeddedNULIssuesRemainValidatedBeforeShortcut"
            let store = WorkspaceFileContextStore()
            let emptyIssue = await store.exactPathResolutionIssue(for: " \n ", kind: .either, rootScope: .visibleWorkspace)
            XCTAssertEqual(emptyIssue, .emptyInput, caseLabel)
            let issue = await store.exactPathResolutionIssue(for: "/tmp/blocked\0.swift", kind: .either, rootScope: .visibleWorkspace)
            guard case let .invalidPathCharacters(input, reason) = issue else {
                return XCTFail(caseLabel + ": Expected embedded NUL validation issue")
            }
            XCTAssertEqual(input, "/tmp/blocked\0.swift", caseLabel)
            XCTAssertTrue(reason.contains("embedded NUL"), caseLabel)

            let serviceSource = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceReadableFileService.swift")
            let validation = try XCTUnwrap(serviceSource.range(of: "store.exactPathResolutionIssue("), caseLabel)
            let shortcut = try XCTUnwrap(serviceSource.range(of: "store.lookupCatalogFileForExplicitRequest(trimmed, rootRefs: roots)"), caseLabel)
            XCTAssertLessThan(validation.lowerBound, shortcut.lowerBound, caseLabel)
        }
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

    func testRelativeAndAliasCatalogHitsUseGenericShortcutWhileAbsoluteWrapperRemainsNarrow() async throws {
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
        let relativeHit = await service.resolveExactWorkspaceCatalogHit(relative, rootScope: .visibleWorkspace)
        let aliasHit = await service.resolveExactWorkspaceCatalogHit(alias, rootScope: .visibleWorkspace)
        XCTAssertEqual(relativeHit?.standardizedFullPath, fileURL.path)
        XCTAssertEqual(aliasHit?.standardizedFullPath, fileURL.path)
        let absoluteWrapperRelativeHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(relative, rootScope: .visibleWorkspace)
        let absoluteWrapperAliasHit = await service.resolveExactAbsoluteWorkspaceCatalogHit(alias, rootScope: .visibleWorkspace)
        XCTAssertNil(absoluteWrapperRelativeHit)
        XCTAssertNil(absoluteWrapperAliasHit)
    }

    func testAbsoluteCatalogMissesPreserveIgnoredFolderAndExternalFallbacks() async throws {
        do {
            let caseLabel = "testAbsoluteCatalogMissFallsThroughToIgnoredFileMaterialization"
            let root = try makeTemporaryRoot(name: "IgnoredMaterialization")
            try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
            let ignoredURL = root.appendingPathComponent("existing.ignored")
            try write("hidden", to: ignoredURL)

            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            let service = WorkspaceReadableFileService(store: store)

            let shortcutHit = await service.resolveExactWorkspaceCatalogHit(ignoredURL.path, rootScope: .visibleWorkspace)
            XCTAssertNil(shortcutHit, caseLabel)
            let readable = await service.resolveReadableFile(ignoredURL.path, profile: .mcpRead, rootScope: .visibleWorkspace)
            guard case let .workspace(file) = readable else {
                return XCTFail(caseLabel + ": Expected ignored absolute miss to materialize through the existing fallback")
            }
            XCTAssertEqual(file.rootID, record.id, caseLabel)
            XCTAssertEqual(file.standardizedFullPath, ignoredURL.path, caseLabel)
            let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertFalse(snapshot.files.contains { $0.standardizedFullPath == ignoredURL.path }, caseLabel)
        }

        do {
            let caseLabel = "testFolderAndExternalSupportPathsRemainFallbackOnly"
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

            let folderShortcutHit = await service.resolveExactWorkspaceCatalogHit(folderURL.path, rootScope: .visibleWorkspace)
            XCTAssertNil(folderShortcutHit, caseLabel)
            let folderResolution = await store.resolveFolderInput(folderURL.path, rootScope: .visibleWorkspace, profile: .mcpRead)
            XCTAssertEqual(folderResolution.folder?.standardizedFullPath, folderURL.path, caseLabel)

            let externalShortcutHit = await service.resolveExactWorkspaceCatalogHit(externalFile.path, rootScope: .visibleWorkspace)
            XCTAssertNil(externalShortcutHit, caseLabel)
            XCTAssertEqual(service.resolveAlwaysReadableExternalFolderDisplayPath(externalFolder.path), "~/.agents/skills/example", caseLabel)
            let readable = await service.resolveReadableFile(externalFile.path, profile: .mcpRead, rootScope: .visibleWorkspace)
            guard case let .external(file) = readable else {
                return XCTFail(caseLabel + ": Expected external support file to resolve through the existing fallback")
            }
            XCTAssertEqual(file.displayPath, "~/.agents/skills/example/SKILL.md", caseLabel)
        }

        do {
            let caseLabel = "testSymlinkedExternalSupportPathRemainsFallbackOnly"
            let root = try makeTemporaryRoot(name: "SymlinkFallbackWorkspace")
            try write("visible", to: root.appendingPathComponent("Visible.swift"))
            let home = try makeTemporaryRoot(name: "SymlinkFallbackHome")
            let realSkillsRoot = try makeTemporaryRoot(name: "SymlinkFallbackSkills")
            let nominalSkillsRoot = home.appendingPathComponent(".agents/skills", isDirectory: true)
            try FileManager.default.createDirectory(
                at: nominalSkillsRoot.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try createDirectorySymlinkOrSkip(at: nominalSkillsRoot, destination: realSkillsRoot)
            let realSkillFile = realSkillsRoot.appendingPathComponent("example/SKILL.md")
            try write("symlinked skill body", to: realSkillFile)
            let nominalSkillFile = nominalSkillsRoot.appendingPathComponent("example/SKILL.md")

            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            let service = WorkspaceReadableFileService(store: store, homeDirectoryURL: home)

            let externalShortcutHit = await service.resolveExactWorkspaceCatalogHit(
                nominalSkillFile.path,
                rootScope: .visibleWorkspace
            )
            XCTAssertNil(externalShortcutHit, caseLabel)
            let readable = await service.resolveReadableFile(
                nominalSkillFile.path,
                profile: .mcpRead,
                rootScope: .visibleWorkspace
            )
            guard case let .external(file) = readable else {
                return XCTFail(caseLabel + ": Expected symlinked support file to resolve through external fallback")
            }
            XCTAssertEqual(file.absolutePath, realSkillFile.path, caseLabel)
            let content = try await service.readAlwaysReadableExternalFile(file)
            XCTAssertEqual(content, "symlinked skill body", caseLabel)
        }
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
        let ambiguousRelative = "Visible.swift"

        let missingLookup = await store.lookupCatalogFileForExplicitRequest(missing, rootScope: .visibleWorkspace)
        let missingShortcutHit = await service.resolveExactWorkspaceCatalogHit(missing, rootScope: .visibleWorkspace)
        let blockedLookup = await store.lookupCatalogFileForExplicitRequest(blocked, rootScope: .visibleWorkspace)
        let blockedShortcutHit = await service.resolveExactWorkspaceCatalogHit(blocked, rootScope: .visibleWorkspace)
        let ambiguousLookup = await store.lookupCatalogFileForExplicitRequest(ambiguousAlias, rootScope: .visibleWorkspace)
        let ambiguousShortcutHit = await service.resolveExactWorkspaceCatalogHit(ambiguousAlias, rootScope: .visibleWorkspace)
        let ambiguousRelativeLookup = await store.lookupCatalogFileForExplicitRequest(ambiguousRelative, rootScope: .visibleWorkspace)
        let ambiguousRelativeShortcutHit = await service.resolveExactWorkspaceCatalogHit(ambiguousRelative, rootScope: .visibleWorkspace)
        XCTAssertEqual(missingLookup, .noCandidate)
        XCTAssertNil(missingShortcutHit)
        XCTAssertEqual(blockedLookup, .blocked)
        XCTAssertNil(blockedShortcutHit)
        XCTAssertEqual(ambiguousLookup, .ambiguous)
        XCTAssertNil(ambiguousShortcutHit)
        XCTAssertEqual(ambiguousRelativeLookup, .ambiguous)
        XCTAssertNil(ambiguousRelativeShortcutHit)
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

        let visibleGitDataHit = await service.resolveExactWorkspaceCatalogHit(gitDataFile.path, rootScope: .visibleWorkspace)
        XCTAssertNil(visibleGitDataHit)
        let gitDataHit = await service.resolveExactWorkspaceCatalogHit(gitDataFile.path, rootScope: .visibleWorkspacePlusGitData)
        XCTAssertEqual(gitDataHit?.rootID, gitDataRecord.id)

        let visibleWorktreeHit = await service.resolveExactWorkspaceCatalogHit(worktreeFile.path, rootScope: .visibleWorkspace)
        XCTAssertNil(visibleWorktreeHit)
        let sessionScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
            canonicalRootPaths: [],
            physicalRootPaths: [worktreeRoot.path]
        )
        let worktreeHit = await service.resolveExactWorkspaceCatalogHit(worktreeFile.path, rootScope: sessionScope)
        XCTAssertEqual(worktreeHit?.rootID, worktreeRecord.id)
        let sessionLogicalHit = await service.resolveExactWorkspaceCatalogHit(logicalFile.path, rootScope: sessionScope)
        XCTAssertNil(sessionLogicalHit)
    }

    func testReadFreshnessTargetsOnlyRequestedPhysicalWorktree() async throws {
        let logicalRoot = try makeTemporaryRoot(name: "ReadFreshnessLogical")
        let worktreeA = try makeTemporaryRoot(name: "ReadFreshnessWorktreeA")
        let worktreeB = try makeTemporaryRoot(name: "ReadFreshnessWorktreeB")
        let worktreeAFile = worktreeA.appendingPathComponent("Sources/A.swift")
        try write("worktree a", to: worktreeAFile)
        try write("worktree b", to: worktreeB.appendingPathComponent("Sources/B.swift"))

        let store = WorkspaceFileContextStore()
        let logicalRecord = try await store.loadRoot(path: logicalRoot.path)
        let worktreeARecord = try await store.loadRoot(path: worktreeA.path, kind: .sessionWorktree)
        let worktreeBRecord = try await store.loadRoot(path: worktreeB.path, kind: .sessionWorktree)
        let scope = WorkspaceLookupRootScope.sessionBoundWorkspace(
            canonicalRootPaths: [logicalRoot.path],
            physicalRootPaths: [worktreeA.path, worktreeB.path]
        )
        let roots = await store.rootRefs(scope: scope)
        let service = WorkspaceReadableFileService(store: store)
        let baselineLogicalStats = await store.scopedIngressBarrierStatsForTesting(rootID: logicalRecord.id)
        let baselineWorktreeAStats = await store.scopedIngressBarrierStatsForTesting(rootID: worktreeARecord.id)
        let baselineWorktreeBStats = await store.scopedIngressBarrierStatsForTesting(rootID: worktreeBRecord.id)

        try await service.awaitFreshnessForExplicitRequest(worktreeAFile.path, rootRefs: roots)

        let logicalStats = await store.scopedIngressBarrierStatsForTesting(rootID: logicalRecord.id)
        let worktreeAStats = await store.scopedIngressBarrierStatsForTesting(rootID: worktreeARecord.id)
        let worktreeBStats = await store.scopedIngressBarrierStatsForTesting(rootID: worktreeBRecord.id)
        XCTAssertEqual(scopedIngressBarrierWorkDelta(logicalStats, baselineLogicalStats), 0)
        XCTAssertGreaterThan(scopedIngressBarrierWorkDelta(worktreeAStats, baselineWorktreeAStats), 0)
        XCTAssertEqual(scopedIngressBarrierWorkDelta(worktreeBStats, baselineWorktreeBStats), 0)
    }

    private func scopedIngressBarrierWorkDelta(
        _ after: WorkspaceFileContextStore.ScopedIngressBarrierStats,
        _ before: WorkspaceFileContextStore.ScopedIngressBarrierStats
    ) -> Int {
        (after.launchCount - before.launchCount) +
            (after.joinCount - before.joinCount) +
            (after.successorCount - before.successorCount) +
            (after.coalescedSuccessorCount - before.coalescedSuccessorCount) +
            (after.noopCount - before.noopCount)
    }

    private func assertOrdered(
        _ needles: [String],
        in source: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var lowerBound = source.startIndex
        for needle in needles {
            let range = try XCTUnwrap(
                source.range(of: needle, range: lowerBound ..< source.endIndex),
                label + ": Missing ordered source fragment: \(needle)",
                file: file,
                line: line
            )
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

    private func createDirectorySymlinkOrSkip(at link: URL, destination: URL) throws {
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        } catch {
            throw XCTSkip("Directory symlink creation unavailable in this environment: \(error)")
        }
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
