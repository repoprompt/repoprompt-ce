import Darwin
import Foundation
import MCP
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

    /// Exercises the shared WorkspaceFileEditHost create path. The data-preparation gate leaves
    /// the real filesystem commit pending while an external creator claims the destination.
    func testWorkspaceFileEditHostCreateLosingCreatorReturnsFileAlreadyExistsWithoutClobberingWinner() async throws {
        try await assertWorkspaceFileEditHostCreatePreservesCompetingWinner(
            fixtureName: "AtomicCreateCompetingCreator",
            forcedRenameError: nil
        )
    }

    /// Forces the supported-filesystem fallback so the regression exercises O_EXCL directly,
    /// rather than only observing RENAME_EXCL returning EEXIST.
    func testWorkspaceFileEditHostCreateOEXCLFallbackPreservesCompetingWinner() async throws {
        try await assertWorkspaceFileEditHostCreatePreservesCompetingWinner(
            fixtureName: "AtomicCreateOEXCLFallback",
            forcedRenameError: ENOTSUP
        )
    }

    func testWorkspaceFileEditHostCreateNativeRenameExclPublishesNewFile() async throws {
        let root = try makeTemporaryDirectory(name: "AtomicCreateNativeRenameExclSuccess")
        let destination = root.appendingPathComponent("nested/NewFile.swift")
        let content = "native RENAME_EXCL publication succeeds\n"
        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        let resolvedService = await store.fileSystemServiceForTesting(rootID: rootRecord.id)
        let service = try XCTUnwrap(resolvedService)
        let nativeSuccessProbe = Issue859ExclusiveRenameProbe()
        await service.setCreateFileExclusiveRenameForTesting { source, destination in
            let result = renamex_np(source, destination, UInt32(RENAME_EXCL))
            if result == 0 {
                nativeSuccessProbe.recordInvocation()
                return 0
            }
            return errno
        }

        let host = WorkspaceFileEditHost(
            store: store,
            target: .create(path: destination.path),
            lookupRootScope: .visibleWorkspace,
            selectCreatedFiles: false
        )
        do {
            try await host.writeText(
                path: destination.path,
                content: content,
                overwrite: false
            )
        } catch {
            await service.setCreateFileExclusiveRenameForTesting(nil)
            throw error
        }
        await service.setCreateFileExclusiveRenameForTesting(nil)

        XCTAssertTrue(nativeSuccessProbe.wasInvoked, "The local fixture must publish through native RENAME_EXCL, not its fallback")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), content)
    }

    func testWorkspaceFileEditHostCreateOEXCLFallbackPublishesNewFile() async throws {
        let root = try makeTemporaryDirectory(name: "AtomicCreateOEXCLFallbackSuccess")
        let destination = root.appendingPathComponent("nested/NewFile.swift")
        let content = "fallback publication succeeds\n"
        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        guard let service = await store.fileSystemServiceForTesting(rootID: rootRecord.id) else {
            return XCTFail("The isolated root must expose its filesystem service")
        }
        let renameProbe = Issue859ExclusiveRenameProbe()
        await service.setCreateFileExclusiveRenameForTesting { _, _ in
            renameProbe.recordInvocation()
            return ENOTSUP
        }

        let host = WorkspaceFileEditHost(
            store: store,
            target: .create(path: destination.path),
            lookupRootScope: .visibleWorkspace,
            selectCreatedFiles: false
        )
        do {
            try await host.writeText(
                path: destination.path,
                content: content,
                overwrite: false
            )
        } catch {
            await service.setCreateFileExclusiveRenameForTesting(nil)
            throw error
        }
        await service.setCreateFileExclusiveRenameForTesting(nil)

        XCTAssertTrue(renameProbe.wasInvoked)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), content)
    }

    func testWorkspaceFileEditHostCreateCleansOwnedTempAfterPostOpenFailure() async throws {
        let root = try makeTemporaryDirectory(name: "AtomicCreateOwnedTempCleanup")
        let destination = root.appendingPathComponent("nested/NewFile.swift")
        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        guard let service = await store.fileSystemServiceForTesting(rootID: rootRecord.id) else {
            return XCTFail("The isolated root must expose its filesystem service")
        }
        await service.setCreateFilePOSIXFailureAfterOpenForTesting(EIO)

        let host = WorkspaceFileEditHost(
            store: store,
            target: .create(path: destination.path),
            lookupRootScope: .visibleWorkspace,
            selectCreatedFiles: false
        )
        do {
            try await host.writeText(
                path: destination.path,
                content: "the owned temporary file must be removed\n",
                overwrite: false
            )
            XCTFail("Expected the injected post-open write failure")
        } catch FileSystemError.failedToCreateFile {
            // The detached reconciler preserves the failed-create classification.
        } catch {
            XCTFail("Expected failedToCreateFile, got \(error)")
        }
        await service.setCreateFilePOSIXFailureAfterOpenForTesting(nil)

        let contents = try FileManager.default.contentsOfDirectory(
            at: destination.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(contents.contains { $0.lastPathComponent.hasPrefix(".repoprompt.create.") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWorkspaceFileEditHostCreateFallbackPostOpenFailurePreservesCompetingReplacement() async throws {
        let root = try makeTemporaryDirectory(name: "AtomicCreateOEXCLFallbackPostOpenFailure")
        let destination = root.appendingPathComponent("nested/NewFile.swift")
        let winnerContent = "replacement after exclusive claim must survive\n"
        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        guard let service = await store.fileSystemServiceForTesting(rootID: rootRecord.id) else {
            return XCTFail("The isolated root must expose its filesystem service")
        }
        let renameProbe = Issue859ExclusiveRenameProbe()
        await service.setCreateFileExclusiveRenameForTesting { _, _ in
            renameProbe.recordInvocation()
            return ENOTSUP
        }
        await service.setCreateFileFallbackPOSIXFailureAfterOpenForTesting { path in
            try? winnerContent.write(toFile: path, atomically: true, encoding: .utf8)
            return EIO
        }

        let host = WorkspaceFileEditHost(
            store: store,
            target: .create(path: destination.path),
            lookupRootScope: .visibleWorkspace,
            selectCreatedFiles: false
        )
        do {
            try await host.writeText(
                path: destination.path,
                content: "incomplete bytes must not be retried blindly\n",
                overwrite: false
            )
            XCTFail("Expected the injected fallback post-open failure")
        } catch let error as FileSystemError {
            guard case .incompleteFileCreation = error else {
                return XCTFail("Expected incompleteFileCreation, got \(error)")
            }
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("incomplete output may remain"), message)
            XCTAssertTrue(message.contains("do not blindly retry"), message)
        } catch {
            XCTFail("Expected incompleteFileCreation, got \(error)")
        }
        await service.setCreateFileExclusiveRenameForTesting(nil)
        await service.setCreateFileFallbackPOSIXFailureAfterOpenForTesting(nil)

        XCTAssertTrue(renameProbe.wasInvoked)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), winnerContent)
        let contents = try FileManager.default.contentsOfDirectory(
            at: destination.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(contents.contains { $0.lastPathComponent.hasPrefix(".repoprompt.create.") })
    }

    @MainActor
    func testPublicMCPFileActionsCollisionReturnsExistingPathError() async throws {
        let root = try makeTemporaryDirectory(name: "PublicMCPCreateCompetingCreator")
        let destination = root.appendingPathComponent("nested/NewFile.swift")
        let winnerContent = "public winner bytes must survive\n"
        let loserContent = "public loser bytes must never replace\n"
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let (server, _) = try makeInProcessMCPFileActionsServer(store: store, root: root)
        guard let rootID = await store.rootRefs(scope: .visibleWorkspace).first?.id,
              let service = await store.fileSystemServiceForTesting(rootID: rootID)
        else {
            return XCTFail("The isolated root must expose its filesystem service")
        }
        let tool = try await inProcessFileActionsTool(from: server)
        let gate = Issue859CreateGate()
        await service.setCreateFileDataPreparationForTesting { content in
            await gate.wait()
            return Data(content.utf8)
        }
        let createTask = Task {
            try await tool(fileActionArguments(
                path: destination.path,
                content: loserContent,
                ifExists: "error"
            ))
        }
        addTeardownBlock {
            await gate.open()
            _ = await createTask.result
            await service.setCreateFileDataPreparationForTesting(nil)
        }

        guard await gate.waitUntilEntered() else {
            await gate.open()
            switch await createTask.result {
            case .success:
                XCTFail("The public losing create did not reach the data-preparation gate before the bounded observation expired")
            case let .failure(error):
                XCTFail("The public losing create failed before reaching the data-preparation gate: \(error)")
            }
            return
        }
        do {
            try write(winnerContent, to: destination)
        } catch {
            await gate.open()
            switch await createTask.result {
            case .success:
                XCTFail("The public losing create unexpectedly succeeded while recovering from the winner-write failure")
            case let .failure(taskError):
                guard let mcpError = taskError as? MCPError,
                      String(describing: mcpError).contains("path already exists")
                else {
                    XCTFail("Unexpected public losing create failure while recovering from the winner-write failure: \(taskError)")
                    throw taskError
                }
            }
            throw error
        }
        await gate.open()

        do {
            _ = try await createTask.value
            XCTFail("The public losing create must fail")
        } catch let error as MCPError {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("path already exists"), message)
        } catch {
            XCTFail("Expected a public MCP existing-path error, got \(error)")
        }
        await service.setCreateFileDataPreparationForTesting(nil)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), winnerContent)
    }

    @MainActor
    func testPublicMCPFileActionsOverwriteReplacesRacedMissingDestination() async throws {
        let root = try makeTemporaryDirectory(name: "PublicMCPCreateOverwriteRace")
        let destination = root.appendingPathComponent("nested/NewFile.swift")
        let winnerContent = "raced winner must be replaced\n"
        let overwriteContent = "explicit overwrite content\n"
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let (server, _) = try makeInProcessMCPFileActionsServer(store: store, root: root)
        guard let rootID = await store.rootRefs(scope: .visibleWorkspace).first?.id,
              let service = await store.fileSystemServiceForTesting(rootID: rootID)
        else {
            return XCTFail("The isolated root must expose its filesystem service")
        }
        let tool = try await inProcessFileActionsTool(from: server)
        let gate = Issue859CreateGate()
        await service.setCreateFileDataPreparationForTesting { content in
            await gate.wait()
            return Data(content.utf8)
        }
        let createTask = Task {
            try await tool(fileActionArguments(
                path: destination.path,
                content: overwriteContent,
                ifExists: "overwrite"
            ))
        }
        addTeardownBlock {
            await gate.open()
            _ = await createTask.result
            await service.setCreateFileDataPreparationForTesting(nil)
        }

        guard await gate.waitUntilEntered() else {
            await gate.open()
            switch await createTask.result {
            case .success:
                XCTFail("The public overwrite create did not reach the data-preparation gate before the bounded observation expired")
            case let .failure(error):
                XCTFail("The public overwrite create failed before reaching the data-preparation gate: \(error)")
            }
            return
        }
        do {
            try write(winnerContent, to: destination)
        } catch {
            await gate.open()
            switch await createTask.result {
            case .success:
                break
            case let .failure(taskError):
                XCTFail("The public overwrite create failed while recovering from the winner-write failure: \(taskError)")
            }
            throw error
        }
        await gate.open()

        let result = try await createTask.value
        await service.setCreateFileDataPreparationForTesting(nil)
        let reply = try XCTUnwrap(result.decode(ToolResultDTOs.FileActionReply.self))
        XCTAssertEqual(reply.status, "ok")
        XCTAssertEqual(reply.mutationState, "applied")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), overwriteContent)
    }

    @MainActor
    func testPublicMCPFileActionsOverwritePreservesRacedDirectory() async throws {
        let root = try makeTemporaryDirectory(name: "PublicMCPCreateOverwriteRacedDirectory")
        let destination = root.appendingPathComponent("nested/NewFile.swift")
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let (server, _) = try makeInProcessMCPFileActionsServer(store: store, root: root)
        guard let rootID = await store.rootRefs(scope: .visibleWorkspace).first?.id,
              let service = await store.fileSystemServiceForTesting(rootID: rootID)
        else {
            return XCTFail("The isolated root must expose its filesystem service")
        }
        let tool = try await inProcessFileActionsTool(from: server)
        await service.setCreateFileDataPreparationForTesting { content in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            return Data(content.utf8)
        }
        addTeardownBlock {
            await service.setCreateFileDataPreparationForTesting(nil)
        }

        do {
            _ = try await tool(fileActionArguments(
                path: destination.path,
                content: "directory must survive explicit overwrite\n",
                ifExists: "overwrite"
            ))
            XCTFail("Expected explicit overwrite of a raced directory to fail")
        } catch let error as MCPError {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("directory"), message)
        } catch {
            XCTFail("Expected a public MCP directory error, got \(error)")
        }
        await service.setCreateFileDataPreparationForTesting(nil)

        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    private func assertWorkspaceFileEditHostCreatePreservesCompetingWinner(
        fixtureName: String,
        forcedRenameError: Int32?
    ) async throws {
        let root = try makeTemporaryDirectory(name: fixtureName)
        let destination = root.appendingPathComponent("nested/NewFile.swift")
        let winnerContent = "winner bytes must survive\n"
        let loserContent = "loser bytes must never replace\n"
        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        guard let service = await store.fileSystemServiceForTesting(rootID: rootRecord.id) else {
            return XCTFail("The isolated root must expose its filesystem service")
        }
        let gate = Issue859CreateGate()
        let renameProbe = Issue859ExclusiveRenameProbe()
        let mutationService = WorkspaceFileMutationService(store: store)
        let target: WorkspaceFileEditHost.Target = if let existing = await mutationService.exactExistingFile(
            destination.path,
            rootScope: .visibleWorkspace
        ) {
            .existing(existing)
        } else {
            .create(path: destination.path)
        }
        guard case .create = target else {
            return XCTFail("The isolated destination must be missing before the competing create")
        }
        let host = WorkspaceFileEditHost(
            store: store,
            target: target,
            lookupRootScope: .visibleWorkspace,
            selectCreatedFiles: false
        )
        if let forcedRenameError {
            await service.setCreateFileExclusiveRenameForTesting { _, _ in
                renameProbe.recordInvocation()
                return forcedRenameError
            }
        }
        await service.setCreateFileDataPreparationForTesting { content in
            await gate.wait()
            return Data(content.utf8)
        }
        let createTask = Task {
            try await host.writeText(
                path: destination.path,
                content: loserContent,
                overwrite: false
            )
        }
        addTeardownBlock {
            await gate.open()
            _ = await createTask.result
            await service.setCreateFileDataPreparationForTesting(nil)
            await service.setCreateFileExclusiveRenameForTesting(nil)
        }

        guard await gate.waitUntilEntered() else {
            await gate.open()
            switch await createTask.result {
            case .success:
                XCTFail("The losing create did not reach the data-preparation gate before the bounded observation expired")
            case let .failure(error):
                XCTFail("The losing create failed before reaching the data-preparation gate: \(error)")
            }
            return
        }
        do {
            try write(winnerContent, to: destination)
        } catch {
            await gate.open()
            switch await createTask.result {
            case .success:
                XCTFail("The losing create unexpectedly succeeded while recovering from the winner-write failure")
            case let .failure(taskError):
                guard let filesystemError = taskError as? FileSystemError,
                      case .fileAlreadyExists = filesystemError
                else {
                    XCTFail("Unexpected losing create failure while recovering from the winner-write failure: \(taskError)")
                    throw taskError
                }
            }
            throw error
        }
        await gate.open()

        do {
            try await createTask.value
            XCTFail("The losing create must fail with fileAlreadyExists")
        } catch FileSystemError.fileAlreadyExists {
            // The exclusive commit reported the expected typed outcome.
        } catch {
            XCTFail("Expected fileAlreadyExists, got \(error)")
        }
        await service.setCreateFileDataPreparationForTesting(nil)
        await service.setCreateFileExclusiveRenameForTesting(nil)
        if forcedRenameError != nil {
            XCTAssertTrue(
                renameProbe.wasInvoked,
                "The fallback regression must invoke the exclusive-rename seam"
            )
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), winnerContent)
    }

    @MainActor
    private func makeInProcessMCPFileActionsServer(
        store: WorkspaceFileContextStore,
        root: URL
    ) throws -> (server: MCPServerViewModel, connectionID: UUID) {
        let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let settingsManager = WindowSettingsManager(windowID: -859)
        let prompt = PromptViewModel(
            fileManager: fileManager,
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettings,
            windowID: -859,
            settingsManager: settingsManager
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(name: "Issue 859", repoPaths: [root.path])
        workspaceManager.workspaces = [workspace]
        workspaceManager.activeWorkspace = workspace
        let oracle = OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
        let service = MCPService(
            hostBootstrapOperation: {},
            controllerStartOperation: {},
            controllerFullShutdownOperation: {}
        )
        let server = MCPServerViewModel(
            service: service,
            promptVM: prompt,
            oracleVM: oracle,
            workspaceManager: workspaceManager,
            windowID: -859,
            workspaceSearch: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("search is not used by the file_actions regression")
            },
            ensureGitDataRootLoaded: { _, _ in
                throw MCPError.internalError("Git-data loading is not used by the file_actions regression")
            }
        )
        let connectionID = UUID()
        try server.bindTabForConnection(
            connectionID: connectionID,
            clientName: nil,
            tabID: XCTUnwrap(workspace.activeComposeTabID),
            workspaceID: workspace.id,
            windowID: -859
        )
        server.setRequestMetadataOverrideForTesting(
            MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: nil,
                windowID: -859
            )
        )
        return (server, connectionID)
    }

    @MainActor
    private func inProcessFileActionsTool(from server: MCPServerViewModel) async throws -> RepoPromptApp.Tool {
        let tools = await server.windowMCPTools
        return try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.fileActions })
    }

    private func fileActionArguments(
        path: String,
        content: String,
        ifExists: String
    ) -> [String: Value] {
        [
            "action": .string("create"),
            "path": .string(path),
            "content": .string(content),
            "if_exists": .string(ifExists)
        ]
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

private final class Issue859ExclusiveRenameProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    func recordInvocation() {
        lock.lock()
        invocationCount += 1
        lock.unlock()
    }

    var wasInvoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invocationCount > 0
    }
}

private actor Issue859CreateGate {
    private enum EntryObservation: Equatable {
        case entered
        case timedOut
    }

    private static let entryObservationTimeoutNanoseconds: UInt64 = 1_000_000_000

    private var enteredContinuation: CheckedContinuation<EntryObservation, Never>?
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var isOpen = false
    private var entryWaitCancelled = false

    func wait() async {
        if !hasEntered {
            hasEntered = true
            enteredContinuation?.resume(returning: .entered)
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

    func waitUntilEntered() async -> Bool {
        guard !hasEntered else { return true }
        return await withTaskCancellationHandler(operation: {
            await withTaskGroup(of: EntryObservation.self) { group in
                group.addTask {
                    await self.waitForEntry()
                }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: Self.entryObservationTimeoutNanoseconds)
                    } catch {
                        // Cancellation only ends the timer; entry remains event-driven.
                    }
                    return .timedOut
                }
                let observation = await group.next() ?? .timedOut
                if observation == .timedOut {
                    await self.cancelEntryWaiter()
                }
                group.cancelAll()
                return observation == .entered
            }
        }, onCancel: {
            Task { await self.cancelEntryWaiter() }
        })
    }

    private func waitForEntry() async -> EntryObservation {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if hasEntered {
                    continuation.resume(returning: .entered)
                } else if entryWaitCancelled {
                    continuation.resume(returning: .timedOut)
                } else {
                    enteredContinuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelEntryWaiter() }
        })
    }

    private func cancelEntryWaiter() {
        entryWaitCancelled = true
        enteredContinuation?.resume(returning: .timedOut)
        enteredContinuation = nil
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        openContinuation?.resume()
        openContinuation = nil
    }
}
