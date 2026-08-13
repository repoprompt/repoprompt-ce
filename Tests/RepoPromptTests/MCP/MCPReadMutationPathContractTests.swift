@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class MCPReadMutationPathContractTests: XCTestCase {
    func testReadDisplayPathAppliesEditsToLiteralCollisionFile() async throws {
        let parent = try makeTemporaryDirectory(name: "LiteralCollision")
        let root = parent.appendingPathComponent("mimic", isDirectory: true)
        let rootFile = root.appendingPathComponent("session.py")
        let nestedFile = root.appendingPathComponent("mimic/session.py")
        try write("root token\n", to: rootFile)
        try write("nested token\n", to: nestedFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let namespace = WorkspaceLookupContext.visibleWorkspace.exactFileNamespace(storeRoots: roots)
        let readableService = WorkspaceReadableFileService(store: store)

        let nestedResolution = try await readableService.resolveReadFileRequest(
            WorkspaceExactFileInput.parse("mimic/session.py"),
            rootScope: .visibleWorkspace,
            rootRefs: roots,
            namespace: namespace
        )
        guard case let .workspace(match) = nestedResolution else {
            return XCTFail("Expected the literal nested file")
        }
        XCTAssertTrue(match.canonicalPath.hasSuffix("//mimic/session.py"))
        let applyResolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(match.canonicalPath),
            namespace: namespace
        )
        guard case let .matched(applyMatch) = applyResolution else {
            return XCTFail("Expected the read path to resolve for apply_edits")
        }
        XCTAssertEqual(applyMatch.file.id, match.file.id)

        let host = WorkspaceFileEditHost(
            store: store,
            target: .existing(applyMatch.file),
            lookupRootScope: .visibleWorkspace,
            createPathResolutionPolicy: .canonicalAliasFirst,
            selectCreatedFiles: false
        )
        let result = try await ApplyEditsService(engine: .default, host: host).run(
            ApplyEditsRequest(
                path: match.canonicalPath,
                mode: .single(search: "nested", replace: "edited", replaceAll: false),
                verbose: true
            )
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(try String(contentsOf: rootFile, encoding: .utf8), "root token\n")
        XCTAssertEqual(try String(contentsOf: nestedFile, encoding: .utf8), "edited token\n")
    }

    func testReadDisplayPathAppliesEditsToRootFileBesideLiteralCollision() async throws {
        let parent = try makeTemporaryDirectory(name: "RootCollision")
        let root = parent.appendingPathComponent("mimic", isDirectory: true)
        let rootFile = root.appendingPathComponent("session.py")
        let nestedFile = root.appendingPathComponent("mimic/session.py")
        try write("root token\n", to: rootFile)
        try write("nested token\n", to: nestedFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let namespace = WorkspaceLookupContext.visibleWorkspace.exactFileNamespace(storeRoots: roots)
        let readableService = WorkspaceReadableFileService(store: store)
        let resolution = try await readableService.resolveReadFileRequest(
            WorkspaceExactFileInput.parse("session.py"),
            rootScope: .visibleWorkspace,
            rootRefs: roots,
            namespace: namespace
        )
        guard case let .workspace(match) = resolution else {
            return XCTFail("Expected the root file")
        }
        XCTAssertEqual(match.canonicalPath, "session.py")
        let applyResolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(match.canonicalPath),
            namespace: namespace
        )
        guard case let .matched(applyMatch) = applyResolution else {
            return XCTFail("Expected the read path to resolve for apply_edits")
        }
        XCTAssertEqual(applyMatch.file.id, match.file.id)

        let host = WorkspaceFileEditHost(
            store: store,
            target: .existing(applyMatch.file),
            lookupRootScope: .visibleWorkspace,
            createPathResolutionPolicy: .canonicalAliasFirst,
            selectCreatedFiles: false
        )
        _ = try await ApplyEditsService(engine: .default, host: host).run(
            ApplyEditsRequest(
                path: match.canonicalPath,
                mode: .single(search: "root", replace: "edited", replaceAll: false),
                verbose: true
            )
        )

        XCTAssertEqual(try String(contentsOf: rootFile, encoding: .utf8), "edited token\n")
        XCTAssertEqual(try String(contentsOf: nestedFile, encoding: .utf8), "nested token\n")
    }

    func testIgnoredLiteralCollisionDoesNotFallThroughToAlias() async throws {
        let parent = try makeTemporaryDirectory(name: "IgnoredLiteralCollision")
        let root = parent.appendingPathComponent("mimic", isDirectory: true)
        let rootFile = root.appendingPathComponent("session.py")
        let ignoredLiteral = root.appendingPathComponent("mimic/session.py")
        try write("mimic/session.py\n", to: root.appendingPathComponent(".gitignore"))
        try write("alias target\n", to: rootFile)
        try write("literal target\n", to: ignoredLiteral)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let resolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse("mimic/session.py"),
            namespace: namespace
        )
        guard case let .matched(match) = resolution else {
            return XCTFail("Expected the ignored literal file")
        }
        XCTAssertEqual(match.file.standardizedFullPath, StandardizedPath.absolute(ignoredLiteral.path))
        XCTAssertTrue(match.canonicalPath.hasSuffix("//mimic/session.py"))

        let applyResolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(match.canonicalPath),
            namespace: namespace
        )
        guard case let .matched(applyMatch) = applyResolution else {
            return XCTFail("Expected the ignored read path to resolve for apply_edits")
        }
        XCTAssertEqual(applyMatch.file.id, match.file.id)

        try FileManager.default.removeItem(at: ignoredLiteral)
        let missingResolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(match.canonicalPath),
            namespace: namespace
        )
        XCTAssertEqual(missingResolution, .claimedMissing)
        XCTAssertEqual(try String(contentsOf: rootFile, encoding: .utf8), "alias target\n")
    }

    func testLiteralDirectoryDoesNotFallThroughToAliasFile() async throws {
        let parent = try makeTemporaryDirectory(name: "LiteralDirectoryCollision")
        let root = parent.appendingPathComponent("mimic", isDirectory: true)
        let rootFile = root.appendingPathComponent("session.py")
        let literalDirectory = root.appendingPathComponent("mimic/session.py", isDirectory: true)
        try write("alias target\n", to: rootFile)
        try FileManager.default.createDirectory(at: literalDirectory, withIntermediateDirectories: true)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let readable = try await WorkspaceReadableFileService(store: store).resolveReadFileRequest(
            WorkspaceExactFileInput.parse("mimic/session.py"),
            rootScope: .visibleWorkspace,
            rootRefs: roots,
            namespace: namespace
        )
        guard case .folder = readable else {
            return XCTFail("Expected the literal directory to terminate alias lookup")
        }

        do {
            _ = try await WorkspaceFileMutationService(store: store).resolveExactExistingFileForMutation(
                "mimic/session.py",
                rootScope: .visibleWorkspace
            )
            XCTFail("Expected apply resolution to reject the literal directory")
        } catch {
            XCTAssertEqual(try String(contentsOf: rootFile, encoding: .utf8), "alias target\n")
        }
    }

    func testExplicitCanonicalAliasRoundTripsAcrossDisplayAliasCollisions() async throws {
        let parent = try makeTemporaryDirectory(name: "ExactAliasCollision")
        let rootURLs = ["lookup-a", "lookup-b", "lookup-c"].map {
            parent.appendingPathComponent($0, isDirectory: true)
        }
        for (index, rootURL) in rootURLs.enumerated() {
            try write("root \(index)\n", to: rootURL.appendingPathComponent("shared.txt"))
        }

        let store = WorkspaceFileContextStore()
        for rootURL in rootURLs {
            _ = try await store.loadRoot(path: rootURL.path)
        }
        let lookupRoots = await store.rootRefs(scope: .visibleWorkspace)
            .sorted { $0.standardizedFullPath < $1.standardizedFullPath }
        let clientRoots = [
            WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/Docs"),
            WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/tmp/Project"),
            WorkspaceRootRef(id: UUID(), name: "Docs", fullPath: "/else/Docs")
        ]
        let namespace = WorkspaceExactFileNamespace(
            rootBindings: zip(lookupRoots, clientRoots).map { lookupRoot, clientRoot in
                WorkspaceExactFileNamespace.RootBinding(
                    lookupRoot: lookupRoot,
                    lookupRole: .projectedPhysical,
                    clientRoots: [clientRoot],
                    preferredClientRoot: clientRoot
                )
            }
        )
        let firstFile = rootURLs.sorted { $0.path < $1.path }[0].appendingPathComponent("shared.txt")
        let resolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(firstFile.path),
            namespace: namespace
        )
        guard case let .matched(match) = resolution else {
            return XCTFail("Expected the first colliding root file")
        }
        XCTAssertTrue(match.canonicalPath.hasSuffix("//shared.txt"))

        let roundTrip = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(match.canonicalPath),
            namespace: namespace
        )
        guard case let .matched(roundTripMatch) = roundTrip else {
            return XCTFail("Expected the namespace-owned alias to round-trip")
        }
        XCTAssertEqual(roundTripMatch.file.id, match.file.id)
    }

    func testHiddenDuplicateRequiresExplicitCanonicalPath() async throws {
        let parent = try makeTemporaryDirectory(name: "HiddenDuplicate")
        let firstRoot = parent.appendingPathComponent("alpha", isDirectory: true)
        let secondRoot = parent.appendingPathComponent("beta", isDirectory: true)
        let firstFile = firstRoot.appendingPathComponent("shared.txt")
        let secondFile = secondRoot.appendingPathComponent("shared.txt")
        try write("first\n", to: firstFile)
        try write("shared.txt\n", to: secondRoot.appendingPathComponent(".gitignore"))
        try write("second\n", to: secondFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: firstRoot.path)
        _ = try await store.loadRoot(path: secondRoot.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let resolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(firstFile.path),
            namespace: namespace
        )
        guard case let .matched(match) = resolution else {
            return XCTFail("Expected the first duplicate")
        }
        XCTAssertTrue(match.canonicalPath.hasSuffix("//shared.txt"))

        let roundTrip = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(match.canonicalPath),
            namespace: namespace
        )
        guard case let .matched(roundTripMatch) = roundTrip else {
            return XCTFail("Expected the explicit canonical path to round-trip")
        }
        XCTAssertEqual(roundTripMatch.file.id, match.file.id)
    }

    func testNestedUnavailableWorktreeDoesNotResolveCanonicalAncestorFile() async throws {
        let parent = try makeTemporaryDirectory(name: "NestedUnavailableWorktree")
        let canonicalRootURL = parent.appendingPathComponent("repo", isDirectory: true)
        let logicalRootURL = canonicalRootURL.appendingPathComponent("project", isDirectory: true)
        let unavailablePhysicalURL = parent.appendingPathComponent("missing-worktree", isDirectory: true)
        let logicalFile = logicalRootURL.appendingPathComponent("Sources/App.swift")
        try write("base token\n", to: logicalFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: canonicalRootURL.path)
        let loadedRoots = await store.rootRefs(scope: .allLoaded)
        let canonicalRoot = try XCTUnwrap(loadedRoots.first)
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: logicalRootURL.path)
        let unavailablePhysical = WorkspaceRootRef(
            id: UUID(),
            name: "Project",
            fullPath: unavailablePhysicalURL.path
        )
        let binding = AgentSessionWorktreeBinding(
            id: "binding-unavailable",
            repositoryID: "repo-unavailable",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "worktree-unavailable",
            worktreeRootPath: unavailablePhysical.fullPath,
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(logicalRoot: logicalRoot, physicalRoot: unavailablePhysical, binding: binding)
            ],
            visibleLogicalRoots: [canonicalRoot, logicalRoot]
        )
        let lookupContext = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let namespace = lookupContext.exactFileNamespace(storeRoots: [canonicalRoot])
        let resolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(logicalFile.path),
            namespace: namespace
        )

        XCTAssertEqual(resolution, .claimedMissing)
        let readableService = WorkspaceReadableFileService(store: store, homeDirectoryURL: canonicalRootURL)
        let folderResolution = try await readableService.resolveReadFileRequest(
            WorkspaceExactFileInput.parse(logicalRootURL.appendingPathComponent("Sources").path),
            rootScope: lookupContext.rootScope,
            rootRefs: [canonicalRoot],
            namespace: namespace
        )
        guard case .noCandidate = folderResolution else {
            return XCTFail("Expected unavailable projected folder to fail closed")
        }
        let fileResolution = try await readableService.resolveReadFileRequest(
            WorkspaceExactFileInput.parse(logicalFile.path),
            rootScope: lookupContext.rootScope,
            rootRefs: [canonicalRoot],
            namespace: namespace
        )
        guard case .noCandidate = fileResolution else {
            return XCTFail("Expected unavailable projected file to avoid external fallback")
        }
        XCTAssertEqual(try String(contentsOf: logicalFile, encoding: .utf8), "base token\n")
    }

    func testUnavailableWorktreeBlocksRelativeUniquenessBesideAvailableMatch() async throws {
        let parent = try makeTemporaryDirectory(name: "UnavailableWorktreeRelativeCollision")
        let canonicalRootURL = parent.appendingPathComponent("repo", isDirectory: true)
        let unavailablePhysicalURL = parent.appendingPathComponent("missing-worktree", isDirectory: true)
        let canonicalFile = canonicalRootURL.appendingPathComponent("Sources/App.swift")
        try write("base token\n", to: canonicalFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: canonicalRootURL.path)
        let loadedRoots = await store.rootRefs(scope: .allLoaded)
        let canonicalRoot = try XCTUnwrap(loadedRoots.first)
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/logical/project")
        let unavailablePhysical = WorkspaceRootRef(
            id: UUID(),
            name: "Project",
            fullPath: unavailablePhysicalURL.path
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRoot,
                    physicalRoot: unavailablePhysical,
                    binding: AgentSessionWorktreeBinding(
                        id: "binding-unavailable-collision",
                        repositoryID: "repo-unavailable-collision",
                        repoKey: "repo-key",
                        logicalRootPath: logicalRoot.fullPath,
                        logicalRootName: logicalRoot.name,
                        worktreeID: "worktree-unavailable-collision",
                        worktreeRootPath: unavailablePhysical.fullPath,
                        source: "test"
                    )
                )
            ],
            visibleLogicalRoots: [canonicalRoot, logicalRoot]
        )
        let namespace = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        ).exactFileNamespace(storeRoots: [canonicalRoot])

        let relativeResolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse("Sources/App.swift"),
            namespace: namespace
        )
        XCTAssertEqual(relativeResolution, .issue(.unresolved(input: "Sources/App.swift")))

        let absoluteResolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(canonicalFile.path),
            namespace: namespace
        )
        guard case let .matched(match) = absoluteResolution else {
            return XCTFail("Expected the absolute canonical file to remain addressable")
        }
        XCTAssertTrue(match.canonicalPath.hasSuffix("//Sources/App.swift"))
    }

    func testNestedBoundLogicalAbsolutePathResolvesWorktree() async throws {
        let parent = try makeTemporaryDirectory(name: "NestedBoundLogicalRoot")
        let canonicalRootURL = parent.appendingPathComponent("repo", isDirectory: true)
        let logicalRootURL = canonicalRootURL.appendingPathComponent("project", isDirectory: true)
        let physicalRootURL = parent.appendingPathComponent("worktree", isDirectory: true)
        let logicalFile = logicalRootURL.appendingPathComponent("Sources/App.swift")
        let physicalFile = physicalRootURL.appendingPathComponent("Sources/App.swift")
        try write("base token\n", to: logicalFile)
        try write("worktree token\n", to: physicalFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: canonicalRootURL.path)
        _ = try await store.loadRoot(path: physicalRootURL.path)
        let loadedRoots = await store.rootRefs(scope: .allLoaded)
        let canonicalRoot = try XCTUnwrap(loadedRoots.first {
            $0.standardizedFullPath == StandardizedPath.absolute(canonicalRootURL.path)
        })
        let physicalRoot = try XCTUnwrap(loadedRoots.first {
            $0.standardizedFullPath == StandardizedPath.absolute(physicalRootURL.path)
        })
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: logicalRootURL.path)
        let binding = AgentSessionWorktreeBinding(
            id: "binding-nested",
            repositoryID: "repo-nested",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "worktree-nested",
            worktreeRootPath: physicalRoot.fullPath,
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding)],
            visibleLogicalRoots: [canonicalRoot, logicalRoot]
        )
        let lookupContext = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let namespace = lookupContext.exactFileNamespace(storeRoots: loadedRoots)
        let folderResolution = try await WorkspaceReadableFileService(store: store).resolveReadFileRequest(
            WorkspaceExactFileInput.parse(logicalRootURL.appendingPathComponent("Sources").path),
            rootScope: lookupContext.rootScope,
            rootRefs: loadedRoots,
            namespace: namespace
        )
        guard case .folder = folderResolution else {
            return XCTFail("Expected the logical folder to resolve through the physical worktree")
        }
        let resolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(logicalFile.path),
            namespace: namespace
        )
        guard case let .matched(match) = resolution else {
            return XCTFail("Expected the nested logical path to resolve into the worktree")
        }
        XCTAssertEqual(match.file.standardizedFullPath, StandardizedPath.absolute(physicalFile.path))

        let roundTrip = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(match.canonicalPath),
            namespace: namespace
        )
        guard case let .matched(roundTripMatch) = roundTrip else {
            return XCTFail("Expected the worktree read path to resolve for apply_edits")
        }
        XCTAssertEqual(roundTripMatch.file.id, match.file.id)
        let host = WorkspaceFileEditHost(store: store, target: .existing(roundTripMatch.file))
        _ = try await ApplyEditsService(engine: .default, host: host).run(
            ApplyEditsRequest(
                path: match.canonicalPath,
                mode: .single(search: "worktree", replace: "edited", replaceAll: false),
                verbose: true
            )
        )
        XCTAssertEqual(try String(contentsOf: logicalFile, encoding: .utf8), "base token\n")
        XCTAssertEqual(try String(contentsOf: physicalFile, encoding: .utf8), "edited token\n")
    }

    func testCanonicalPathRoundTripsLeadingWhitespaceRelativePath() async throws {
        let root = try makeTemporaryDirectory(name: "LeadingWhitespaceRelativePath")
        let fileURL = root.appendingPathComponent(" Target.swift")
        try write("whitespace token\n", to: fileURL)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let resolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(fileURL.path),
            namespace: namespace
        )
        guard case let .matched(match) = resolution else {
            return XCTFail("Expected the whitespace-leading workspace file, got \(resolution)")
        }
        XCTAssertEqual(match.canonicalPath, " Target.swift")

        let roundTrip = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse(match.canonicalPath),
            namespace: namespace
        )
        guard case let .matched(roundTripMatch) = roundTrip else {
            return XCTFail("Expected the whitespace-leading canonical path to round-trip")
        }
        XCTAssertEqual(roundTripMatch.file.id, match.file.id)
    }

    func testAbsoluteWorkspaceRootResolvesAsFolder() async throws {
        let root = try makeTemporaryDirectory(name: "AbsoluteWorkspaceRootFolder")
        try write("content\n", to: root.appendingPathComponent("Target.swift"))
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let resolution = try await WorkspaceReadableFileService(store: store).resolveReadFileRequest(
            WorkspaceExactFileInput.parse(root.path),
            rootScope: .visibleWorkspace,
            rootRefs: roots,
            namespace: namespace
        )
        guard case .folder = resolution else {
            return XCTFail("Expected the loaded root path to resolve as a folder, got \(resolution)")
        }
    }

    func testMalformedMutationInputsUseFileManagerErrorBoundary() async throws {
        let store = WorkspaceFileContextStore()
        let mutationService = WorkspaceFileMutationService(store: store)
        for input in ["", " \n ", "../Target.swift", "root///Target.swift", "bad\0path"] {
            do {
                _ = try await mutationService.resolveExactExistingFileForMutation(input)
                XCTFail("Expected malformed input to fail: \(input)")
            } catch is FileManagerError {
                continue
            } catch {
                XCTFail("Expected FileManagerError for \(input), got \(error)")
            }
        }
    }

    func testApprovedWriteRejectsReplacementAfterPreview() async throws {
        let root = try makeTemporaryDirectory(name: "ApprovedWriteReplacement")
        let fileURL = root.appendingPathComponent("Target.swift")
        try write("reviewed token\n", to: fileURL)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let resolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse("Target.swift"),
            namespace: namespace
        )
        guard case let .matched(match) = resolution else {
            return XCTFail("Expected the target file")
        }
        let host = WorkspaceFileEditHost(store: store, target: .existing(match.file))
        let preview = try await ApplyEditsService(engine: .default, host: host).preview(
            ApplyEditsRequest(
                path: match.canonicalPath,
                mode: .single(search: "reviewed", replace: "approved", replaceAll: false),
                verbose: true
            )
        )
        let originalText = try XCTUnwrap(preview.originalText)
        try write("replacement content\n", to: fileURL)

        do {
            try await host.writeTextIfUnchanged(
                path: match.canonicalPath,
                content: preview.result.updatedText,
                expectedOriginalText: originalText
            )
            XCTFail("Expected the approved write to reject replacement content")
        } catch FileSystemError.fileContentChanged {
            XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "replacement content\n")
        } catch {
            XCTFail("Expected fileContentChanged, got \(error)")
        }

        try await host.writeTextIfUnchanged(
            path: match.canonicalPath,
            content: "accepted replacement\n",
            expectedOriginalText: "replacement content\n"
        )
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "accepted replacement\n")
    }

    func testApprovedWriteUsesStreamedPreviewEncodingAtCommit() async throws {
        let root = try makeTemporaryDirectory(name: "ApprovedWriteStreamedEncoding")
        let fileURL = root.appendingPathComponent("Large.swift")
        let fileBody = String(repeating: "a", count: 1_100_000) + " reviewed token\n"
        let reviewedText = "\u{FEFF}" + fileBody
        var originalData = Data([0xFF, 0xFE])
        try originalData.append(XCTUnwrap(fileBody.data(using: .utf16LittleEndian)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try originalData.write(to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let resolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse("Large.swift"),
            namespace: namespace
        )
        guard case let .matched(match) = resolution else {
            return XCTFail("Expected the streamed target file")
        }
        let host = WorkspaceFileEditHost(store: store, target: .existing(match.file))
        let preview = try await ApplyEditsService(engine: .default, host: host).preview(
            ApplyEditsRequest(
                path: match.canonicalPath,
                mode: .single(search: "reviewed", replace: "approved", replaceAll: false),
                verbose: false
            )
        )
        let previewOriginalText = try XCTUnwrap(preview.originalText)
        XCTAssertEqual(previewOriginalText, reviewedText)

        try await host.writeTextIfUnchanged(
            path: match.canonicalPath,
            content: preview.result.updatedText,
            expectedOriginalText: previewOriginalText
        )
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf16LittleEndian),
            "\u{FEFF}" + String(repeating: "a", count: 1_100_000) + " approved token\n"
        )
    }

    func testMissingResolvedTargetFailsInsteadOfReadingEmptyContent() async throws {
        let root = try makeTemporaryDirectory(name: "MissingResolvedTarget")
        let fileURL = root.appendingPathComponent("Target.swift")
        try write("content\n", to: fileURL)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let resolution = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse("Target.swift"),
            namespace: namespace
        )
        guard case let .matched(match) = resolution else {
            return XCTFail("Expected the target file")
        }
        let host = WorkspaceFileEditHost(store: store, target: .existing(match.file))
        try FileManager.default.removeItem(at: fileURL)

        do {
            _ = try await host.readText(path: match.canonicalPath)
            XCTFail("Expected a missing resolved target to fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    private func makeTemporaryDirectory(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
