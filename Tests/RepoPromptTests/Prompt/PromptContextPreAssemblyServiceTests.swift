@testable import RepoPrompt
import XCTest

final class PromptContextPreAssemblyServiceTests: XCTestCase {
    private actor CapturedPaths {
        private var value: [String] = []
        func set(_ paths: [String]) {
            value = paths
        }

        func get() -> [String] {
            value
        }
    }

    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testResolveUsesWorktreeContentAndLogicalizesFileTree() async throws {
        let fixture = try await makeBoundFixture()
        let request = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .complete),
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false),
            store: fixture.store,
            lookupContext: fixture.lookupContext,
            filePathDisplay: .full,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .filesOnly,
            selectedGitDiffProvider: { _ in "unexpected selected diff" },
            completeGitDiffProvider: { "base checkout complete diff must not appear" }
        )

        let result = await PromptContextPreAssemblyService.resolve(request)

        XCTAssertEqual(result.physicalSelection.selectedPaths, [fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL.path])
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertTrue(result.entries.first?.loadedContent?.contains("worktree") ?? false)
        XCTAssertFalse(result.entries.first?.loadedContent?.contains("base") ?? true)
        XCTAssertTrue(result.fileTreeContent?.contains(fixture.logicalRoot.standardizedFileURL.path) ?? false, result.fileTreeContent ?? "")
        XCTAssertFalse(result.fileTreeContent?.contains(fixture.worktreeRoot.standardizedFileURL.path) ?? true, result.fileTreeContent ?? "")
        XCTAssertEqual(result.gitDiff, PromptContextGitDiffPolicy.deferredCompleteWorktreeGitDiffMessage)
    }

    func testResolveSelectedDiffUsesPhysicalizedSelectionAndPolicy() async throws {
        let fixture = try await makeBoundFixture()
        let captured = CapturedPaths()
        let request = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .selected),
            selection: StoredSelection(selectedPaths: ["Sources"], codemapAutoEnabled: false),
            store: fixture.store,
            lookupContext: fixture.lookupContext,
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .expandFolders,
            selectedGitDiffLookupProfile: .uiAssisted,
            selectedGitDiffProvider: { paths in
                await captured.set(paths)
                return "selected diff"
            },
            completeGitDiffProvider: { "unexpected complete diff" }
        )

        let result = await PromptContextPreAssemblyService.resolve(request)
        let paths = await captured.get()

        XCTAssertEqual(result.gitDiff, "selected diff")
        XCTAssertEqual(Set(paths), Set([
            fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL.path,
            fixture.worktreeRoot.appendingPathComponent("Sources/Keep.swift").standardizedFileURL.path
        ]))
        XCTAssertFalse(paths.contains(fixture.logicalRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL.path))
    }

    func testCanonicalAutoCodemapsDrivePreassemblyAndClipboardWithoutHiddenRediscovery() async throws {
        let root = try makeTemporaryRoot(name: "PromptPreAssemblyCanonicalCodemap")
        let selectedURL = root.appendingPathComponent("Selected.swift")
        let targetURL = root.appendingPathComponent("Target.swift")
        let selectedContent = "let selectedFullContentSentinel = TargetType()\n"
        let targetContent = "struct TargetType { func targetFullContentSentinel() {} }\n"
        try FileSystemTestSupport.write(selectedContent, to: selectedURL)
        try FileSystemTestSupport.write(targetContent, to: targetURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: selectedURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: selectedURL.path,
                    symbolName: "selectedCodemapSymbol",
                    referencedTypes: ["TargetType"]
                )
            ),
            WorkspaceObservedCodemapResult(
                fullPath: targetURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: targetURL.path,
                    symbolName: "targetCodemapSymbol",
                    className: "TargetType"
                )
            )
        ])
        let lookupContext = WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)

        let hiddenRediscoveryRequest = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .none, codeMapUsage: .auto),
            selection: StoredSelection(
                selectedPaths: [selectedURL.path],
                autoCodemapPaths: [],
                codemapAutoEnabled: false
            ),
            store: store,
            lookupContext: lookupContext,
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .expandFolders,
            includeLocalDefinitionsInFileTree: true,
            selectedGitDiffProvider: { _ in nil },
            completeGitDiffProvider: { nil }
        )
        let hiddenRediscoveryResult = await PromptContextPreAssemblyService.resolve(hiddenRediscoveryRequest)

        XCTAssertEqual(hiddenRediscoveryResult.entries.count, 1)
        XCTAssertFalse(hiddenRediscoveryResult.fileTreeContent?.contains("targetCodemapSymbol") ?? false)
        XCTAssertFalse(hiddenRediscoveryResult.fileTreeContent?.contains("<Referenced APIs>") ?? false)

        let canonicalRequest = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .none, codeMapUsage: .auto),
            selection: StoredSelection(
                selectedPaths: [selectedURL.path],
                autoCodemapPaths: [targetURL.path],
                codemapAutoEnabled: false
            ),
            store: store,
            lookupContext: lookupContext,
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .expandFolders,
            includeLocalDefinitionsInFileTree: true,
            selectedGitDiffProvider: { _ in nil },
            completeGitDiffProvider: { nil }
        )
        let canonicalResult = await PromptContextPreAssemblyService.resolve(canonicalRequest)
        let clipboard = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [],
            userInstructions: "",
            files: canonicalResult.entries,
            fileTreeContent: canonicalResult.fileTreeContent,
            gitDiff: canonicalResult.gitDiff,
            includeSavedPrompts: false,
            includeFiles: true,
            includeUserPrompt: false,
            filePathDisplay: .relative,
            codemapSnapshotBundle: canonicalResult.codemapSnapshotBundle,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false
        )

        XCTAssertEqual(canonicalResult.entries.count, 2)
        XCTAssertEqual(occurrences(of: "targetCodemapSymbol", in: clipboard), 1, clipboard)
        XCTAssertEqual(occurrences(of: "selectedFullContentSentinel", in: clipboard), 1, clipboard)
        XCTAssertFalse(clipboard.contains("targetFullContentSentinel"), clipboard)
        XCTAssertFalse(clipboard.contains("<Referenced APIs>"), clipboard)
    }

    func testResolveFreezesCodemapResolutionTreeAndRenderingAcrossAwait() async throws {
        #if DEBUG
            let root = try makeTemporaryRoot(name: "PromptPreAssemblyFrozenCodemap")
            let selectedURL = root.appendingPathComponent("Selected.swift")
            let targetURL = root.appendingPathComponent("Target.swift")
            try FileSystemTestSupport.write("let selected = true\n", to: selectedURL)
            try FileSystemTestSupport.write("struct Target {}\n", to: targetURL)

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedFileSystemService = await store.fileSystemServiceForTesting(rootID: rootRecord.id)
            let fileSystemService = try XCTUnwrap(loadedFileSystemService)
            await store.applyObservedCodemapResults([
                WorkspaceObservedCodemapResult(
                    fullPath: targetURL.path,
                    modificationDate: Date(),
                    fileAPI: makeFileAPI(
                        path: targetURL.path,
                        symbolName: "frozenCodemapSentinel"
                    )
                )
            ])
            let gate = PreAssemblyContentReadGate()
            await fileSystemService.setContentReadChunkHandlerForTesting { _ in
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                Task {
                    await fileSystemService.setContentReadChunkHandlerForTesting(nil)
                    await gate.release()
                }
            }

            let request = PromptContextPreAssemblyRequest(
                cfg: makeConfig(gitInclusion: .none, codeMapUsage: .auto),
                selection: StoredSelection(
                    selectedPaths: [selectedURL.path],
                    autoCodemapPaths: [targetURL.path],
                    codemapAutoEnabled: true
                ),
                store: store,
                lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: true,
                showCodeMapMarkers: true,
                selectedGitDiffFolderPolicy: .filesOnly,
                selectedGitDiffProvider: { _ in nil },
                completeGitDiffProvider: { nil }
            )
            let resolveTask = Task {
                await PromptContextPreAssemblyService.resolve(request)
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
            let result = await resolveTask.value
            await fileSystemService.setContentReadChunkHandlerForTesting(nil)

            let clipboard = await PromptPackagingService.generateClipboardContent(
                metaInstructions: [],
                userInstructions: "",
                files: result.entries,
                fileTreeContent: result.fileTreeContent,
                includeSavedPrompts: false,
                includeFiles: true,
                includeUserPrompt: false,
                filePathDisplay: .relative,
                codemapSnapshotBundle: result.codemapSnapshotBundle,
                promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
                disabledPromptSections: [],
                duplicateUserInstructionsAtTop: false
            )

            XCTAssertEqual(result.entries.filter(\.isCodemap).map(\.file.standardizedFullPath), [targetURL.standardizedFileURL.path])
            XCTAssertTrue(result.fileTreeContent?.contains("Target.swift +") == true, result.fileTreeContent ?? "")
            XCTAssertTrue(clipboard.contains("frozenCodemapSentinel"), clipboard)
            XCTAssertTrue(result.codemapSnapshotBundle.orderedSnapshots.contains {
                $0.fileAPI?.apiDescription.contains("frozenCodemapSentinel") == true
            })
            let currentBundle = await store.codemapSnapshotBundle()
            XCTAssertFalse(currentBundle.orderedSnapshots.contains {
                $0.fileAPI?.apiDescription.contains("frozenCodemapSentinel") == true
            })
        #endif
    }

    func testSelectedDiffArtifactPolicyCanRespectGitInclusionNone() async throws {
        let root = try makeTemporaryRoot(name: "PromptPreAssemblyDiffArtifact")
        let diffText = "diff --git a/Sources/App.swift b/Sources/App.swift\n"
        try FileSystemTestSupport.write(diffText, to: root.appendingPathComponent("_git_data/diff/selected.diff"))
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let selection = StoredSelection(selectedPaths: ["_git_data/diff/selected.diff"], codemapAutoEnabled: false)
        let baseRequest = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .none),
            selection: selection,
            store: store,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .expandFolders,
            selectedGitDiffProvider: { _ in "unexpected selected provider" },
            completeGitDiffProvider: { "unexpected complete provider" }
        )
        let includeResult = await PromptContextPreAssemblyService.resolve(baseRequest)

        let respectRequest = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .none),
            selection: selection,
            store: store,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .expandFolders,
            selectedGitDiffArtifactPolicy: .respectGitInclusion,
            selectedGitDiffProvider: { _ in "unexpected selected provider" },
            completeGitDiffProvider: { "unexpected complete provider" }
        )
        let respectResult = await PromptContextPreAssemblyService.resolve(respectRequest)

        let includeClipboard = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [],
            userInstructions: "",
            files: includeResult.entries,
            fileTreeContent: includeResult.fileTreeContent,
            gitDiff: includeResult.gitDiff,
            includeSavedPrompts: false,
            includeFiles: true,
            includeUserPrompt: false,
            filePathDisplay: .relative,
            codemapSnapshotBundle: includeResult.codemapSnapshotBundle,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false
        )
        let respectClipboard = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [],
            userInstructions: "",
            files: respectResult.entries,
            fileTreeContent: respectResult.fileTreeContent,
            gitDiff: respectResult.gitDiff,
            includeSavedPrompts: false,
            includeFiles: true,
            includeUserPrompt: false,
            filePathDisplay: .relative,
            codemapSnapshotBundle: respectResult.codemapSnapshotBundle,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false
        )

        XCTAssertEqual(includeResult.gitDiff, diffText)
        XCTAssertTrue(includeClipboard.contains(diffText), includeClipboard)
        XCTAssertNil(respectResult.gitDiff)
        XCTAssertTrue(respectResult.entries.isEmpty)
        XCTAssertFalse(respectClipboard.contains("<git_diff>"), respectClipboard)
        XCTAssertFalse(respectClipboard.contains(diffText), respectClipboard)
    }

    private func makeBoundFixture() async throws -> (
        logicalRoot: URL,
        worktreeRoot: URL,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext
    ) {
        let logicalRoot = try makeTemporaryRoot(name: "PromptPreAssemblyLogical")
        let worktreeRoot = try makeTemporaryRoot(name: "PromptPreAssemblyWorktree")
        try FileSystemTestSupport.write("let origin = \"base\"\n", to: logicalRoot.appendingPathComponent("Sources/App.swift"))
        try FileSystemTestSupport.write("let origin = \"keep-base\"\n", to: logicalRoot.appendingPathComponent("Sources/Keep.swift"))
        try FileSystemTestSupport.write("let origin = \"worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/App.swift"))
        try FileSystemTestSupport.write("let origin = \"keep-worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/Keep.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let sessionID = UUID()
        let binding = makeBinding(logicalRoot: logicalRoot, worktreeRoot: worktreeRoot)
        let materializedProjection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(sessionID: sessionID, bindings: [binding])
        let projection = try XCTUnwrap(materializedProjection)
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        return (logicalRoot, worktreeRoot, store, lookupContext)
    }

    private func makeConfig(
        gitInclusion: GitInclusion,
        codeMapUsage: CodeMapUsage = .none
    ) -> PromptContextResolved {
        PromptContextResolved(
            includeFiles: true,
            includeUserPrompt: true,
            includeMetaPrompts: false,
            includeFileTree: true,
            fileTreeMode: .auto,
            codeMapUsage: codeMapUsage,
            gitInclusion: gitInclusion,
            storedPromptIds: []
        )
    }

    private func makeFileAPI(
        path: String,
        symbolName: String,
        className: String? = nil,
        referencedTypes: [String] = []
    ) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: className.map { [ClassInfo(name: $0, methods: [], properties: [])] } ?? [],
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
            referencedTypes: referencedTypes
        )
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func makeBinding(logicalRoot: URL, worktreeRoot: URL) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "bind_test",
            repositoryID: "repo_test",
            repoKey: "repo",
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: "worktree_test",
            worktreeRootPath: worktreeRoot.path,
            worktreeName: worktreeRoot.lastPathComponent,
            branch: "feature/test",
            head: "abcdef",
            visualLabel: "test",
            visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSinceReferenceDate: 123),
            source: "test"
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        try temporaryRoots.makeRoot(suiteName: name)
    }
}

#if DEBUG
    private actor PreAssemblyContentReadGate {
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
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
#endif
