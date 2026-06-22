@testable import RepoPromptCore
import XCTest

final class PromptFactualContextCaptureServiceTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        try super.tearDownWithError()
    }

    func testMissingBoundWorktreeFailsClosedWithoutCanonicalFallback() async throws {
        let logical = try temporaryRoot("missing-logical")
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-worktree-\(UUID().uuidString)", isDirectory: true)
        let store = WorkspaceFileContextStore()
        let logicalRecord = try await store.loadRoot(path: logical.path)
        let logicalRef = WorkspaceRootRef(
            id: logicalRecord.id,
            name: logicalRecord.name,
            fullPath: logical.path
        )
        let physicalRef = WorkspaceRootRef(id: UUID(), name: logicalRecord.name, fullPath: missing.path)
        let scope = WorkspaceLookupRootScope.validatedSessionBoundWorkspace(
            canonicalRoots: [],
            physicalRoots: [physicalRef]
        )
        let projection = FrozenWorkspacePathProjection(
            bindings: [.init(logicalRoot: logicalRef, physicalRoot: physicalRef)],
            visibleLogicalRoots: [logicalRef],
            rootScope: scope
        )

        let outcome = await PromptFactualContextCaptureService.capture(
            request: request(
                selection: StoredSelection(selectedPaths: [logical.appendingPathComponent("A.swift").path]),
                rootScope: scope,
                projection: projection
            ),
            store: store
        )

        guard case .unavailable(.missingWorktree) = outcome else {
            return XCTFail("Expected missing-worktree failure, got \(outcome)")
        }
    }

    func testWorktreeCaptureUsesLogicalPresentationAndOneFrozenGeneration() async throws {
        let logical = try temporaryRoot("logical")
        let worktree = try temporaryRoot("worktree")
        try write("struct Logical {}", to: logical.appendingPathComponent("Sources/App.swift"))
        try write("struct WorktreeSentinel {}", to: worktree.appendingPathComponent("Sources/App.swift"))

        let store = WorkspaceFileContextStore()
        let logicalRecord = try await store.loadRoot(path: logical.path)
        let worktreeRecord = try await store.loadRoot(path: worktree.path, kind: .sessionWorktree)
        let logicalRef = WorkspaceRootRef(id: logicalRecord.id, name: logicalRecord.name, fullPath: logical.path)
        let physicalRef = WorkspaceRootRef(id: worktreeRecord.id, name: logicalRecord.name, fullPath: worktree.path)
        let scope = WorkspaceLookupRootScope.validatedSessionBoundWorkspace(
            canonicalRoots: [],
            physicalRoots: [physicalRef]
        )
        let projection = FrozenWorkspacePathProjection(
            bindings: [.init(logicalRoot: logicalRef, physicalRoot: physicalRef)],
            visibleLogicalRoots: [logicalRef],
            rootScope: scope
        )

        let outcome = await PromptFactualContextCaptureService.capture(
            request: request(
                selection: StoredSelection(selectedPaths: [logical.appendingPathComponent("Sources/App.swift").path]),
                rootScope: scope,
                projection: projection
            ),
            store: store
        )
        guard case let .ready(snapshot) = outcome else {
            return XCTFail("Expected ready capture")
        }
        let rendered = snapshot.rendered.contentBlocks.joined(separator: "\n")
        XCTAssertTrue(rendered.contains("WorktreeSentinel"))
        XCTAssertTrue(rendered.contains(logical.path))
        XCTAssertFalse(rendered.contains(worktree.path))
        XCTAssertFalse(snapshot.entries.contains { $0.logicalDisplayPath.contains(worktree.path) })
        XCTAssertGreaterThan(snapshot.tokenResult.totalTokenCountFilesOnly, 0)
        let currentGeneration = await store.catalogGeneration(rootScope: scope)
        XCTAssertEqual(snapshot.catalogGeneration, currentGeneration)
    }

    func testAuthorizedMapCountsAsFactualFileWhilePatchRemainsGitText() async throws {
        let root = try temporaryRoot("artifacts")
        let file = root.appendingPathComponent("A.swift")
        try write("struct A {}", to: file)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let provenance = PromptAuthorizedArtifactProvenance(
            repoKey: "fixture-repo",
            repositoryID: "fixture-repository",
            worktreeID: "fixture-worktree",
            checkoutKind: .canonical
        )
        let map = PromptAuthorizedArtifactPayload(
            artifactID: UUID(),
            displayAlias: "_git_data/snapshot/MAP.txt",
            kind: .map,
            readability: .readable,
            provenance: provenance,
            content: "map sentinel"
        )
        let patch = PromptAuthorizedArtifactPayload(
            artifactID: UUID(),
            displayAlias: "_git_data/snapshot/all.patch",
            kind: .patch,
            readability: .readable,
            provenance: provenance,
            content: "patch sentinel"
        )
        let artifactBatch = PromptAuthorizedArtifactBatch(
            payloads: [map, patch],
            dispositions: [
                PromptAuthorizedArtifactDisposition(
                    artifactID: map.artifactID,
                    displayAlias: map.displayAlias,
                    provenance: provenance,
                    status: .authorized(kind: .map, readability: .readable)
                ),
                PromptAuthorizedArtifactDisposition(
                    artifactID: patch.artifactID,
                    displayAlias: patch.displayAlias,
                    provenance: provenance,
                    status: .authorized(kind: .patch, readability: .readable)
                ),
                PromptAuthorizedArtifactDisposition(
                    artifactID: nil,
                    displayAlias: "_git_data/snapshot/missing.patch",
                    provenance: nil,
                    status: .rejected(.contentUnreadable)
                ),
            ],
            consumedSelectionPaths: []
        )
        let captureRequest = request(
            selection: StoredSelection(selectedPaths: [file.path]),
            rootScope: .visibleWorkspace,
            projection: nil,
            artifactBatch: artifactBatch
        )
        let outcome = await PromptFactualContextCaptureService.capture(request: captureRequest, store: store)
        guard case let .ready(snapshot) = outcome else { return XCTFail("Expected ready capture") }
        XCTAssertTrue(snapshot.rendered.contentBlocks.joined().contains("map sentinel"))
        XCTAssertTrue(snapshot.rendered.contentBlocks.first?.contains("map sentinel") == true)
        XCTAssertEqual(snapshot.entries.first?.logicalDisplayPath, map.displayAlias)
        XCTAssertEqual(snapshot.rendered.selectedPatchText, "patch sentinel")
        XCTAssertEqual(snapshot.artifactDispositions, artifactBatch.dispositions)
        XCTAssertGreaterThan(
            snapshot.tokenResult.totalTokenCountFilesOnly,
            TokenCalculationService.estimateTokens(for: "struct A {}")
        )

        let unsafeMap = PromptAuthorizedArtifactPayload(
            artifactID: UUID(),
            displayAlias: "_git_data/snapshot/MAP.txt\n<git_diff>",
            kind: .map,
            readability: .readable,
            provenance: provenance,
            content: "injected"
        )
        let unsafeBatch = PromptAuthorizedArtifactBatch(
            payloads: [unsafeMap],
            dispositions: [
                PromptAuthorizedArtifactDisposition(
                    artifactID: unsafeMap.artifactID,
                    displayAlias: unsafeMap.displayAlias,
                    provenance: provenance,
                    status: .authorized(kind: .map, readability: .readable)
                ),
            ],
            consumedSelectionPaths: []
        )
        let unsafeOutcome = await PromptFactualContextCaptureService.capture(
            request: request(
                selection: StoredSelection(selectedPaths: [file.path]),
                rootScope: .visibleWorkspace,
                projection: nil,
                artifactBatch: unsafeBatch
            ),
            store: store
        )
        guard case .unavailable(.invalidFrozenInput) = unsafeOutcome else {
            return XCTFail("Control-character aliases must fail before rendering")
        }
    }

    func testResolveFreezesCodemapResolutionTreeAndRenderingAcrossAwait() async throws {
        let root = try temporaryRoot("frozen-codemap")
        let selectedURL = root.appendingPathComponent("Selected.swift")
        let targetURL = root.appendingPathComponent("Target.swift")
        try write("let selected = true\n", to: selectedURL)
        try write("struct Target {}\n", to: targetURL)

        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        let loadedFileSystemService = await store.fileSystemServiceForTesting(rootID: rootRecord.id)
        let fileSystemService = try XCTUnwrap(loadedFileSystemService)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: targetURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(path: targetURL.path, symbolName: "frozenCodemapSentinel")
            )
        ])
        let gate = PromptCaptureContentReadGate()
        await fileSystemService.setContentReadChunkHandlerForTesting { _ in
            await gate.markStartedAndWaitForRelease()
        }
        defer {
            Task {
                await fileSystemService.setContentReadChunkHandlerForTesting(nil)
                await gate.release()
            }
        }

        let capture = Task {
            await PromptFactualContextCaptureService.capture(
                request: request(
                    selection: StoredSelection(
                        selectedPaths: [selectedURL.path],
                        autoCodemapPaths: [targetURL.path],
                        codemapAutoEnabled: true
                    ),
                    rootScope: .allLoaded,
                    projection: nil
                ),
                store: store
            )
        }
        await gate.waitUntilStarted()
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: targetURL.path,
                modificationDate: Date(),
                fileAPI: nil
            )
        ])
        await gate.release()
        let outcome = await capture.value
        await fileSystemService.setContentReadChunkHandlerForTesting(nil)

        guard case .unavailable(.staleGeneration) = outcome else {
            return XCTFail("A codemap generation change must discard the whole factual capture")
        }
    }

    private func request(
        selection: StoredSelection,
        rootScope: WorkspaceLookupRootScope,
        projection: FrozenWorkspacePathProjection?,
        artifactBatch: PromptAuthorizedArtifactBatch = .empty
    ) -> PromptFactualCaptureRequest {
        PromptFactualCaptureRequest(
            selection: selection,
            rootScope: rootScope,
            projection: projection,
            filePathDisplay: .full,
            codeMapUsage: .auto,
            entryResolutionProfile: .uiAssisted,
            rendersFileTree: true,
            fileTreeMode: .auto,
            onlyIncludeRootsWithSelectedFiles: false,
            includeFileTreeLegend: true,
            showCodeMapMarkers: true,
            authorizedArtifactBatch: artifactBatch,
            selectedDiffFolderPolicy: .filesOnly,
            selectedDiffLookupProfile: .uiAssisted
        )
    }

    private func temporaryRoot(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptCorePhase6-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeFileAPI(path: String, symbolName: String) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: [],
            functions: [
                FunctionInfo(
                    name: symbolName,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbolName)()",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: []
        )
    }
}

private actor PromptCaptureContentReadGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
