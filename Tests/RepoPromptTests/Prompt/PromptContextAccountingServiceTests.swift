@testable import RepoPromptApp
import XCTest

final class PromptContextAccountingServiceTests: XCTestCase {
    func testExactSelectedFilesPreserveStoredSelectionOrderAfterBatchLookupAndConcurrentReads() async throws {
        let root = try makeTemporaryRoot(name: "AccountingOrder")
        let fileA = root.appendingPathComponent("A.swift")
        let fileB = root.appendingPathComponent("B.swift")
        let fileC = root.appendingPathComponent("C.swift")
        try write("alpha", to: fileA)
        try write("beta", to: fileB)
        try write("gamma", to: fileC)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: [fileC.path, fileA.path, fileB.path],

            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .none)

        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), ["C.swift", "A.swift", "B.swift"])
        XCTAssertEqual(resolution.entries.map(\.loadedContent), ["gamma", "alpha", "beta"])
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testPhysicalizedSelectionRefreshesSessionBoundBatchLookupAfterWorktreeLoad() async throws {
        let logicalRoot = try makeTemporaryRoot(name: "AccountingLogical")
        let worktreeRoot = try makeTemporaryRoot(name: "AccountingWorktree")
        let logicalFile = logicalRoot.appendingPathComponent("Sources/App.swift")
        let worktreeFile = worktreeRoot.appendingPathComponent("Sources/App.swift")
        try write("canonical", to: logicalFile)
        try write("worktree", to: worktreeFile)

        let store = WorkspaceFileContextStore()
        let logicalRootRecord = try await store.loadRoot(path: logicalRoot.path)
        let logicalRootRef = WorkspaceRootRef(
            id: logicalRootRecord.id,
            name: logicalRootRecord.name,
            fullPath: logicalRootRecord.standardizedFullPath
        )
        let physicalRootRef = WorkspaceRootRef(
            id: UUID(),
            name: logicalRootRecord.name,
            fullPath: worktreeRoot.path
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRootRef,
                    physicalRoot: physicalRootRef,
                    binding: AgentSessionWorktreeBinding(
                        id: "accounting-binding",
                        repositoryID: "accounting-repository",
                        repoKey: "accounting-repo",
                        logicalRootPath: logicalRoot.path,
                        logicalRootName: logicalRootRecord.name,
                        worktreeID: "accounting-worktree",
                        worktreeRootPath: worktreeRoot.path,
                        source: "test"
                    )
                )
            ],
            visibleLogicalRoots: [logicalRootRef]
        )
        let lookupContext = WorkspaceLookupContext(
            // This test intentionally exercises a dynamic path selector that begins before
            // the worktree root is loaded. Authoritative file-tool projections use the
            // identity-pinned `projection.lookupRootScope` instead.
            rootScope: .sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [worktreeRoot.path]
            ),
            bindingProjection: projection
        )
        let logicalSelection = StoredSelection(
            selectedPaths: [logicalFile.path],
            codemapAutoEnabled: false
        )
        let physicalSelection = lookupContext.physicalizeSelection(logicalSelection)
        XCTAssertEqual(physicalSelection.selectedPaths, [worktreeFile.path])

        let request = WorkspacePathLookupRequest(
            userPath: worktreeFile.path,
            profile: .uiAssisted,
            rootScope: lookupContext.rootScope
        )
        let generationBeforeWorktreeLoad = await store.catalogGeneration(rootScope: lookupContext.rootScope)
        let lookupBeforeWorktreeLoad = await store.lookupPaths([request])
        XCTAssertTrue(lookupBeforeWorktreeLoad.isEmpty)

        let worktreeRootRecord = try await store.loadRoot(path: worktreeRoot.path, kind: .sessionWorktree)
        let generationAfterWorktreeLoad = await store.catalogGeneration(rootScope: lookupContext.rootScope)
        XCTAssertNotEqual(generationAfterWorktreeLoad, generationBeforeWorktreeLoad)
        let resolution = await PromptContextAccountingService().resolveEntries(
            selection: physicalSelection,
            store: store,
            rootScope: lookupContext.rootScope,
            codeMapUsage: .none
        )

        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertEqual(resolution.entries.count, 1)
        XCTAssertEqual(entry.file.rootID, worktreeRootRecord.id)
        XCTAssertEqual(entry.file.standardizedRelativePath, "Sources/App.swift")
        XCTAssertEqual(entry.loadedContent, "worktree")
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testDuplicateSelectedPathsPreserveExistingEntryDedupOrder() async throws {
        let root = try makeTemporaryRoot(name: "AccountingDuplicates")
        let fileA = root.appendingPathComponent("A.swift")
        let fileB = root.appendingPathComponent("B.swift")
        try write("alpha", to: fileA)
        try write("beta", to: fileB)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: [fileA.path, fileA.path, fileB.path],

            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .none)

        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), ["A.swift", "B.swift"])
        XCTAssertEqual(resolution.entries.map(\.loadedContent), ["alpha", "beta"])
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testSelectedCodemapUsageDoesNotLoadContentWhenCodemapExists() async throws {
        let root = try makeTemporaryRoot(name: "AccountingSelectedCodemap")
        let fileURL = root.appendingPathComponent("A.swift")
        try write("struct A { func fullContent() {} }", to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let fileLookup = await store.lookupPath(fileURL.path)
        let file = try XCTUnwrap(fileLookup?.file)
        let api = makeSyntaxArtifact(path: fileURL.path)
        let presentation = try makePresentation(entries: [(file, api.renderedCodeMap(displayPath: "AccountingSelectedCodemap/A.swift"))])
        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: [fileURL.path],

            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(
            selection: selection,
            store: store,
            codeMapUsage: .selected,
            codemapPresentation: presentation
        )

        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertEqual(resolution.entries.count, 1)
        XCTAssertTrue(entry.isCodemap)
        XCTAssertEqual(entry.mode, .codemap)
        XCTAssertNil(entry.lineRanges)
        XCTAssertNil(entry.loadedContent)
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testAutoCodemapResolutionUsesCanonicalPathsAndPreservesSlices() async throws {
        let root = try makeTemporaryRoot(name: "AccountingCanonicalAutoCodemap")
        let selectedURL = root.appendingPathComponent("Selected.swift")
        let targetURL = root.appendingPathComponent("Target.swift")
        try write("let excluded = 0\nlet selected = TargetType()\n", to: selectedURL)
        try write("struct TargetType { func targetFullContent() {} }\n", to: targetURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let targetLookup = await store.lookupPath(targetURL.path)
        let target = try XCTUnwrap(targetLookup?.file)
        let targetAPI = makeSyntaxArtifact(
            path: targetURL.path,
            symbolName: "targetCodemapSymbol",
            className: "TargetType"
        )
        let targetPresentation = try makePresentation(entries: [
            (target, targetAPI.renderedCodeMap(displayPath: "AccountingCanonicalAutoCodemap/Target.swift"))
        ])
        let service = PromptContextAccountingService()
        let slice = LineRange(start: 2, end: 2)
        let selectionWithoutCanonicalCodemap = StoredSelection(
            selectedPaths: [selectedURL.path],

            slices: [selectedURL.path: [slice]],
            codemapAutoEnabled: false
        )

        let withoutCanonicalCodemap = await service.resolveEntries(
            selection: selectionWithoutCanonicalCodemap,
            store: store,
            codeMapUsage: .auto
        )

        let selectedOnlyEntry = try XCTUnwrap(withoutCanonicalCodemap.entries.first)
        XCTAssertEqual(withoutCanonicalCodemap.entries.count, 1)
        XCTAssertEqual(selectedOnlyEntry.file.standardizedFullPath, selectedURL.standardizedFileURL.path)
        XCTAssertEqual(selectedOnlyEntry.mode, .sliced)
        XCTAssertEqual(selectedOnlyEntry.lineRanges, [slice])
        XCTAssertFalse(selectedOnlyEntry.isCodemap)

        let canonicalSelection = StoredSelection(
            selectedPaths: selectionWithoutCanonicalCodemap.selectedPaths,

            slices: selectionWithoutCanonicalCodemap.slices,
            codemapAutoEnabled: true
        )
        let canonicalResolution = await service.resolveEntries(
            selection: canonicalSelection,
            store: store,
            codeMapUsage: .auto,
            codemapPresentation: targetPresentation
        )

        XCTAssertEqual(canonicalResolution.entries.count, 2)
        let selectedEntry = try XCTUnwrap(canonicalResolution.entries.first { $0.file.standardizedFullPath == selectedURL.standardizedFileURL.path })
        XCTAssertEqual(selectedEntry.mode, .sliced)
        XCTAssertEqual(selectedEntry.lineRanges, [slice])
        let codemapEntry = try XCTUnwrap(canonicalResolution.entries.first { $0.file.standardizedFullPath == targetURL.standardizedFileURL.path })
        XCTAssertEqual(codemapEntry.mode, .codemap)
        XCTAssertTrue(codemapEntry.isCodemap)
        XCTAssertNil(codemapEntry.loadedContent)
    }

    func testMissingSelectedPathsRemainMissingAndInvalidPathsRemainEmpty() async throws {
        let root = try makeTemporaryRoot(name: "AccountingMissing")
        try write("alpha", to: root.appendingPathComponent("A.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = PromptContextAccountingService()
        let missingPath = root.appendingPathComponent("Missing.swift").path
        let unresolvedRelativePath = "DefinitelyMissing.swift"
        let selection = StoredSelection(
            selectedPaths: [missingPath, unresolvedRelativePath],

            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .none)

        XCTAssertEqual(resolution.entries, [])
        XCTAssertEqual(resolution.missingPaths, [unresolvedRelativePath, missingPath].sorted())
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testExpandedSelectedFolderFilesRemainRelativePathOrderedWithContents() async throws {
        let root = try makeTemporaryRoot(name: "AccountingFolder")
        try write("b", to: root.appendingPathComponent("Sources/B.swift"))
        try write("a", to: root.appendingPathComponent("Sources/Nested/A.swift"))
        try write("notes", to: root.appendingPathComponent("Sources/notes.txt"))
        try write("outside", to: root.appendingPathComponent("Outside.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let expansion = await store.expandFolderInputToFiles("Sources", rootScope: .visibleWorkspace)
        XCTAssertTrue(expansion.handled)
        XCTAssertEqual(expansion.files.map(\.standardizedRelativePath), [
            "Sources/B.swift",
            "Sources/Nested/A.swift",
            "Sources/notes.txt"
        ])

        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: expansion.files.map(\.standardizedFullPath),

            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .none)

        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), [
            "Sources/B.swift",
            "Sources/Nested/A.swift",
            "Sources/notes.txt"
        ])
        XCTAssertEqual(resolution.entries.map(\.loadedContent), ["b", "a", "notes"])
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testCancelledAccountingReadBatchStopsSchedulingRemainingFiles() async throws {
        #if DEBUG
            let root = try makeTemporaryRoot(name: "AccountingCancellation")
            let fileCount = 24
            var selectedPaths: [String] = []
            for index in 0 ..< fileCount {
                let fileURL = root.appendingPathComponent("File\(index).swift")
                try write("struct File\(index) {}", to: fileURL)
                selectedPaths.append(fileURL.path)
            }

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedService = await store.fileSystemServiceForTesting(rootID: rootRecord.id)
            let service = try XCTUnwrap(loadedService)
            let gate = AccountingReadCancellationGate()
            await service.setContentReadChunkHandlerForTesting { _ in
                await gate.markStartedAndWaitForRelease()
            }

            let accountingTask = Task {
                await PromptContextAccountingService().resolveEntries(
                    selection: StoredSelection(
                        selectedPaths: selectedPaths,
                        codemapAutoEnabled: false
                    ),
                    store: store,
                    codeMapUsage: .none
                )
            }
            await gate.waitUntilStarted()
            accountingTask.cancel()
            await gate.release()
            _ = await accountingTask.value
            try? await Task.sleep(for: .milliseconds(50))

            let startedReadCount = await gate.startedCount()
            await service.setContentReadChunkHandlerForTesting(nil)
            XCTAssertLessThanOrEqual(
                startedReadCount,
                4,
                "A cancelled accounting batch should not continue draining all selected files"
            )
        #endif
    }

    func testResolvedContentMetricsPreserveOrderIdentityAndAccountingSemantics() async throws {
        let root = try makeTemporaryRoot(name: "ResolvedAccountingMetrics").resolvingSymlinksInPath().standardizedFileURL
        let fullID = UUID()
        let sliceID = UUID()
        let rootID = UUID()
        let fullContent = "let unicode = \"é🙂\"\nlet full = true\n"
        let sliceContent = "skip\nslice one é\nslice two 🙂\nskip\n"
        let sliceRanges = [LineRange(start: 2, end: 3)]
        let contents = [
            "Full.swift": fullContent,
            "Slice.swift": sliceContent
        ]
        let recorder = ResolvedAccountingReaderRecorder(contents: contents)
        let service = PromptContextAccountingService(resolvedContentReader: { location, workloadClass in
            await recorder.read(location: location, workloadClass: workloadClass)
        })
        let entries = [
            PromptContextResolvedContentMetricsEntry(
                fileID: fullID,
                rootID: rootID,
                location: ResolvedFileContentLocation(
                    resolvedRootURL: root,
                    resolvedFileURL: root.appendingPathComponent("Full.swift"),
                    relativePath: "Full.swift"
                ),
                renderedDisplayPath: "Logical/Full.swift",
                lineRanges: nil
            ),
            PromptContextResolvedContentMetricsEntry(
                fileID: sliceID,
                rootID: rootID,
                location: ResolvedFileContentLocation(
                    resolvedRootURL: root,
                    resolvedFileURL: root.appendingPathComponent("Slice.swift"),
                    relativePath: "Slice.swift"
                ),
                renderedDisplayPath: "Logical/Slice.swift",
                lineRanges: sliceRanges
            )
        ]

        let snapshot = try await service.calculateEntryMetricsSnapshot(resolvedContentEntries: entries)

        let inputs = await recorder.recordedInputs()
        XCTAssertEqual(inputs.map(\.location.relativePath), ["Full.swift", "Slice.swift"])
        XCTAssertEqual(inputs.map(\.workloadClass), [.promptAccounting, .promptAccounting])
        let fullMetric = try XCTUnwrap(snapshot.metric(forFileID: fullID))
        let sliceMetric = try XCTUnwrap(snapshot.metric(forFileID: sliceID))
        let renderedSlice = SliceAssemblyBuilder.build(from: sliceContent, ranges: sliceRanges).combinedText
        let expectedFullTokens = TokenCalculationService.estimateTokens(for: fullContent)
        let expectedSliceTokens = TokenCalculationService.estimateTokens(for: renderedSlice)
        let expectedTotal = expectedFullTokens + expectedSliceTokens
        XCTAssertEqual(snapshot.totalSelectedDisplayTokens, expectedTotal)
        XCTAssertEqual(fullMetric.standardizedFullPath, root.appendingPathComponent("Full.swift").path)
        XCTAssertEqual(fullMetric.renderedDisplayPath, "Logical/Full.swift")
        XCTAssertEqual(fullMetric.renderMode, .full)
        XCTAssertEqual(fullMetric.displayTokenCount, expectedFullTokens)
        XCTAssertEqual(fullMetric.displayPercentage, Double(expectedFullTokens) / Double(expectedTotal))
        XCTAssertEqual(fullMetric.includedLineCount, 2)
        XCTAssertEqual(sliceMetric.standardizedFullPath, root.appendingPathComponent("Slice.swift").path)
        XCTAssertEqual(sliceMetric.renderedDisplayPath, "Logical/Slice.swift")
        XCTAssertEqual(sliceMetric.renderMode, .slice)
        XCTAssertEqual(sliceMetric.displayTokenCount, expectedSliceTokens)
        XCTAssertEqual(sliceMetric.displayPercentage, Double(expectedSliceTokens) / Double(expectedTotal))
        XCTAssertEqual(sliceMetric.includedLineCount, 2)
    }

    func testResolvedContentReadFailureThrowsWithoutPartialSnapshot() async throws {
        let root = try makeTemporaryRoot(name: "ResolvedAccountingFailure").standardizedFileURL
        let location = ResolvedFileContentLocation(
            resolvedRootURL: root,
            resolvedFileURL: root.appendingPathComponent("Failure.swift"),
            relativePath: "Failure.swift"
        )
        let service = PromptContextAccountingService(resolvedContentReader: { _, _ in
            throw ResolvedAccountingReaderError.failed
        })

        do {
            _ = try await service.calculateEntryMetricsSnapshot(resolvedContentEntries: [
                PromptContextResolvedContentMetricsEntry(
                    fileID: UUID(),
                    rootID: UUID(),
                    location: location,
                    renderedDisplayPath: "Failure.swift",
                    lineRanges: nil
                )
            ])
            XCTFail("Expected the resolved content read failure")
        } catch ResolvedAccountingReaderError.failed {
            // Expected
        }
    }

    func testResolvedContentNilThrowsWithoutPartialSnapshot() async throws {
        let root = try makeTemporaryRoot(name: "ResolvedAccountingUnavailable").standardizedFileURL
        let location = ResolvedFileContentLocation(
            resolvedRootURL: root,
            resolvedFileURL: root.appendingPathComponent("Unavailable.swift"),
            relativePath: "Unavailable.swift"
        )
        let service = PromptContextAccountingService(resolvedContentReader: { _, _ in nil })

        do {
            _ = try await service.calculateEntryMetricsSnapshot(resolvedContentEntries: [
                PromptContextResolvedContentMetricsEntry(
                    fileID: UUID(),
                    rootID: UUID(),
                    location: location,
                    renderedDisplayPath: "Unavailable.swift",
                    lineRanges: nil
                )
            ])
            XCTFail("Expected unavailable resolved content to fail accounting")
        } catch let error as PromptContextResolvedContentAccountingError {
            XCTAssertEqual(error, .contentUnavailable(location))
        }
    }

    func testResolvedContentCancellationBeforeFirstEntryStopsReads() async throws {
        let root = try makeTemporaryRoot(name: "ResolvedAccountingCancelledBefore").standardizedFileURL
        let location = ResolvedFileContentLocation(
            resolvedRootURL: root,
            resolvedFileURL: root.appendingPathComponent("Unread.swift"),
            relativePath: "Unread.swift"
        )
        let recorder = ResolvedAccountingReaderRecorder(contents: ["Unread.swift": "unreachable"])
        let service = PromptContextAccountingService(resolvedContentReader: { location, workloadClass in
            await recorder.read(location: location, workloadClass: workloadClass)
        })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.calculateEntryMetricsSnapshot(resolvedContentEntries: [
                PromptContextResolvedContentMetricsEntry(
                    fileID: UUID(),
                    rootID: UUID(),
                    location: location,
                    renderedDisplayPath: "Unread.swift",
                    lineRanges: nil
                )
            ])
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before the first read")
        } catch is CancellationError {
            // Expected
        }
        let inputs = await recorder.recordedInputs()
        XCTAssertTrue(inputs.isEmpty)
    }

    func testResolvedContentCancellationAfterLastEntryThrowsWithoutSnapshot() async throws {
        let root = try makeTemporaryRoot(name: "ResolvedAccountingCancelledAfter").standardizedFileURL
        let location = ResolvedFileContentLocation(
            resolvedRootURL: root,
            resolvedFileURL: root.appendingPathComponent("Read.swift"),
            relativePath: "Read.swift"
        )
        let recorder = ResolvedAccountingReaderRecorder(contents: ["Read.swift": "let read = true\n"])
        let service = PromptContextAccountingService(resolvedContentReader: { location, workloadClass in
            let content = await recorder.read(location: location, workloadClass: workloadClass)
            withUnsafeCurrentTask { $0?.cancel() }
            return content
        })

        do {
            _ = try await service.calculateEntryMetricsSnapshot(resolvedContentEntries: [
                PromptContextResolvedContentMetricsEntry(
                    fileID: UUID(),
                    rootID: UUID(),
                    location: location,
                    renderedDisplayPath: "Read.swift",
                    lineRanges: nil
                )
            ])
            XCTFail("Expected cancellation after the final resolved read")
        } catch is CancellationError {
            // Expected
        }
        let inputs = await recorder.recordedInputs()
        XCTAssertEqual(inputs.map(\.location.relativePath), ["Read.swift"])
    }

    func testResolvedAndStoreBackedReadersDecodeSmallNonUTF8FileIdentically() async throws {
        let root = try makeTemporaryRoot(name: "ResolvedAccountingDecoding").standardizedFileURL
        let fileURL = root.appendingPathComponent("Encoded.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: fileURL)
        let store = WorkspaceFileContextStore()
        let loadedRoot = try await store.loadRoot(path: root.path)

        let storeContent = try await store.readContent(rootID: loadedRoot.id, relativePath: "Encoded.txt")
        let resolvedContent = try await FileSystemService.loadEntireFileContentOptimized(
            at: ResolvedFileContentLocation(
                resolvedRootURL: root,
                resolvedFileURL: fileURL,
                relativePath: "Encoded.txt"
            ),
            workloadClass: .promptAccounting
        )

        XCTAssertNotNil(storeContent)
        XCTAssertEqual(resolvedContent, storeContent)
    }

    func testEntryMetricsSnapshotCountsIncludedLinesForFullSlicesAndCodemaps() async throws {
        let root = try makeTemporaryRoot(name: "AccountingEntryMetrics")
        let fullURL = root.appendingPathComponent("Full.swift")
        let sliceURL = root.appendingPathComponent("Slice.swift")
        let codemapURL = root.appendingPathComponent("Codemap.swift")
        let fullContent = "full one\r\nfull two\nfull three"
        let sliceContent = "skip\nslice one\r\nslice two\nskip"
        try write(fullContent, to: fullURL)
        try write(sliceContent, to: sliceURL)
        try write("struct CodemapOnly { func rendered() {} }", to: codemapURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let codemapLookup = await store.lookupPath(codemapURL.path)
        let codemapFile = try XCTUnwrap(codemapLookup?.file)
        let renderedCodemap = makeSyntaxArtifact(
            path: codemapURL.path,
            symbolName: "renderedMetricSentinel",
            imports: ["Foundation"]
        )
        .renderedCodeMap(displayPath: "Codemap.swift")
        let presentation = try makePresentation(entries: [(codemapFile, renderedCodemap)])

        let sliceRange = LineRange(start: 2, end: 3)
        let result = await PromptContextAccountingService().calculatePromptStats(
            request: PromptContextAccountingRequest(
                selection: StoredSelection(
                    selectedPaths: [fullURL.path, sliceURL.path],
                    slices: [sliceURL.path: [sliceRange]],
                    codemapAutoEnabled: true
                ),
                codeMapUsage: .auto,
                filePathDisplay: .relative
            ),
            store: store,
            codemapPresentation: presentation
        )

        let fullEntry = try XCTUnwrap(
            result.resolvedEntries.first { $0.file.standardizedFullPath == fullURL.standardizedFileURL.path }
        )
        let sliceEntry = try XCTUnwrap(
            result.resolvedEntries.first { $0.file.standardizedFullPath == sliceURL.standardizedFileURL.path }
        )
        let codemapEntry = try XCTUnwrap(
            result.resolvedEntries.first { $0.file.standardizedFullPath == codemapURL.standardizedFileURL.path }
        )
        let sliceAssembly = FileViewModel.buildSliceAssembly(from: sliceContent, ranges: [sliceRange])
        let expectedFullTokens = TokenCalculationService.estimateTokens(for: fullContent)
        let expectedSliceTokens = TokenCalculationService.estimateTokens(for: sliceAssembly.combinedText)
        let expectedCodemapTokens = TokenCalculationService.estimateTokens(for: renderedCodemap)
        let expectedTotal = expectedFullTokens + expectedSliceTokens + expectedCodemapTokens
        let metrics = result.entryMetricsSnapshot
        let rowEntryMetrics = await PromptContextAccountingService().calculateEntryMetricsSnapshot(
            entries: result.resolvedEntries.map { entry in
                ResolvedPromptFileEntry(
                    file: entry.file,
                    isCodemap: entry.isCodemap,
                    lineRanges: entry.lineRanges,
                    mode: entry.mode,
                    loadedContent: nil,
                    rootFolderPath: entry.rootFolderPath,
                    role: entry.role
                )
            },
            store: store,
            codemapPresentation: presentation,
            filePathDisplay: .relative
        )

        XCTAssertEqual(rowEntryMetrics, metrics)
        XCTAssertEqual(metrics.totalSelectedDisplayTokens, expectedTotal)
        XCTAssertEqual(result.tokenResult.entryResultsByFileID.count, 3)
        XCTAssertEqual(WorkspaceTextLineCounter.countLines(in: ""), 0)
        XCTAssertEqual(WorkspaceTextLineCounter.countLines(in: "a\r\nb\rc\n"), 3)

        let fullMetric = try XCTUnwrap(metrics.metric(forFileID: fullEntry.file.id))
        XCTAssertEqual(fullMetric.standardizedFullPath, fullURL.standardizedFileURL.path)
        XCTAssertEqual(fullMetric.renderedDisplayPath, "Full.swift")
        XCTAssertEqual(
            metrics.metric(forStandardizedFullPath: fullURL.standardizedFileURL.path)?.fileID,
            fullEntry.file.id
        )
        XCTAssertEqual(fullMetric.renderMode, .full)
        XCTAssertEqual(fullMetric.displayTokenCount, expectedFullTokens)
        XCTAssertEqual(fullMetric.includedLineCount, 3)
        XCTAssertEqual(
            fullMetric.displayPercentage,
            Double(expectedFullTokens) / Double(expectedTotal),
            accuracy: 0.000_000_000_001
        )

        let sliceMetric = try XCTUnwrap(metrics.metric(forFileID: sliceEntry.file.id))
        XCTAssertEqual(sliceMetric.standardizedFullPath, sliceURL.standardizedFileURL.path)
        XCTAssertEqual(sliceMetric.renderedDisplayPath, "Slice.swift")
        XCTAssertEqual(sliceMetric.renderMode, .slice)
        XCTAssertEqual(sliceMetric.displayTokenCount, expectedSliceTokens)
        XCTAssertEqual(sliceMetric.includedLineCount, 2)
        XCTAssertEqual(
            sliceMetric.displayPercentage,
            Double(expectedSliceTokens) / Double(expectedTotal),
            accuracy: 0.000_000_000_001
        )

        let codemapMetric = try XCTUnwrap(metrics.metric(forFileID: codemapEntry.file.id))
        XCTAssertEqual(codemapMetric.standardizedFullPath, codemapURL.standardizedFileURL.path)
        XCTAssertEqual(codemapMetric.renderedDisplayPath, "Codemap.swift")
        XCTAssertEqual(codemapMetric.renderMode, .codemap)
        XCTAssertEqual(codemapMetric.displayTokenCount, expectedCodemapTokens)
        XCTAssertEqual(
            codemapMetric.includedLineCount,
            WorkspaceTextLineCounter.countLines(in: renderedCodemap)
        )
        XCTAssertEqual(
            codemapMetric.displayPercentage,
            Double(expectedCodemapTokens) / Double(expectedTotal),
            accuracy: 0.000_000_000_001
        )
    }

    func testCodemapAccountingCountsExactRenderedHeaderAndImports() async throws {
        let root = try makeTemporaryRoot(name: "AccountingRenderedCodemapTokens")
        let fileURL = root.appendingPathComponent("Nested/Target.swift")
        try write(SwiftFixtureSource.emptyStruct("Target", trailingNewline: false), to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let api = makeSyntaxArtifact(
            path: fileURL.path,
            symbolName: "renderedTokenSentinel",
            imports: ["Foundation", "Combine"]
        )
        let fileLookup = await store.lookupPath(fileURL.path)
        let file = try XCTUnwrap(fileLookup?.file)
        let rendered = api.renderedCodeMap(displayPath: "AccountingRenderedCodemapTokens/Nested/Target.swift")
        let presentation = try makePresentation(entries: [(file, rendered)])

        let result = await PromptContextAccountingService().calculatePromptStats(
            request: PromptContextAccountingRequest(
                selection: StoredSelection(
                    selectedPaths: [fileURL.path],
                    codemapAutoEnabled: false
                ),
                codeMapUsage: .selected,
                filePathDisplay: .relative
            ),
            store: store,
            codemapPresentation: presentation
        )

        let expectedTokens = TokenCalculationService.estimateTokens(for: rendered)
        let snapshot = try XCTUnwrap(result.promptFileEntrySnapshots.first)
        XCTAssertEqual(result.promptFileEntrySnapshots.count, 1)
        XCTAssertEqual(snapshot.codeMapContent, rendered)
        XCTAssertEqual(snapshot.availableCodeMapTokenCount, expectedTokens)
        XCTAssertEqual(result.tokenResult.codeMapTokenCount, expectedTokens)
        XCTAssertEqual(result.tokenResult.totalTokenCountFilesOnly, 0)
    }

    func testAccountingAndPackagingShareExactPresentationArtifactAndRenderedText() async throws {
        let root = try makeTemporaryRoot(name: "AccountingPackagingIdentity")
        let fileURL = root.appendingPathComponent("Target.swift")
        try write(SwiftFixtureSource.emptyStruct("Target", trailingNewline: false), to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let fileLookup = await store.lookupPath(fileURL.path)
        let file = try XCTUnwrap(fileLookup?.file)
        let rendered = makeSyntaxArtifact(path: fileURL.path, symbolName: "sharedArtifactSentinel")
            .renderedCodeMap(displayPath: "LogicalRoot/Target.swift")
        let presentation = try makePresentation(entries: [(file, rendered)])

        let result = await PromptContextAccountingService().calculatePromptStats(
            request: PromptContextAccountingRequest(
                selection: StoredSelection(selectedPaths: [fileURL.path], codemapAutoEnabled: false),
                codeMapUsage: .selected
            ),
            store: store,
            codemapPresentation: presentation
        )
        let blocks = PromptPackagingService.generatePartitionedFileBlocks(
            result.resolvedEntries,
            filePathDisplay: .relative,
            codemapPresentation: result.codemapPresentation
        )

        let operationEntry = try XCTUnwrap(result.codemapPresentation.renderedEntriesByFileID[file.id])
        let snapshot = try XCTUnwrap(result.promptFileEntrySnapshots.first)
        XCTAssertEqual(result.codemapPresentation.id, presentation.id)
        XCTAssertEqual(operationEntry.artifactKey, presentation.renderedEntriesByFileID[file.id]?.artifactKey)
        XCTAssertEqual(blocks.codemapBlocks, [rendered])
        XCTAssertEqual(snapshot.codeMapContent, rendered)
        XCTAssertEqual(snapshot.availableCodeMapTokenCount, TokenCalculationService.estimateTokens(for: rendered))
        XCTAssertEqual(result.tokenResult.codeMapTokenCount, snapshot.availableCodeMapTokenCount)
    }

    func testNonGitSelectedCodemapIsTypedUnavailableAndFallsBackToContent() async throws {
        let root = try makeTemporaryRoot(name: "AccountingNonGitFallback")
        let fileURL = root.appendingPathComponent("A.swift")
        let content = SwiftFixtureSource.emptyStruct("NonGitFallback", trailingNewline: false)
        try write(content, to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let resolution = await PromptContextAccountingService().resolveEntries(
            selection: StoredSelection(selectedPaths: [fileURL.path], codemapAutoEnabled: false),
            store: store,
            codeMapUsage: .selected
        )

        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertFalse(entry.isCodemap)
        XCTAssertEqual(entry.loadedContent, content)
        guard case let .unavailable(issues) = resolution.codemapPresentation.coverage else {
            return XCTFail("Expected typed unavailable presentation coverage")
        }
        XCTAssertTrue(issues.contains { issue in
            if case .unavailable(_, .gitTerminal(.nonGit)) = issue { return true }
            return false
        })
    }

    func testCompleteCodemapResolutionUsesSingleFrozenOperationPresentation() async throws {
        let root = try makeTemporaryRoot(name: "AccountingCompleteCodemapBatch")
        let fileCount = 24
        for index in 0 ..< fileCount {
            try write("struct File\(index) {}", to: root.appendingPathComponent("File\(index).swift"))
        }

        let store = WorkspaceFileContextStore()
        let loadedRoot = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loadedRoot.id)
        let presentation = try makePresentation(entries: files.map { file in
            let api = makeSyntaxArtifact(path: file.standardizedFullPath)
            return (file, api.renderedCodeMap(displayPath: "AccountingCompleteCodemapBatch/\(file.standardizedRelativePath)"))
        })

        let resolution = await PromptContextAccountingService().resolveEntries(
            selection: StoredSelection(codemapAutoEnabled: false),
            store: store,
            codeMapUsage: .complete,
            codemapPresentation: presentation
        )

        XCTAssertEqual(resolution.codemapPresentation.id, presentation.id)
        XCTAssertEqual(resolution.entries.count, fileCount)
        XCTAssertTrue(resolution.entries.allSatisfy { $0.mode == .codemap })
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        try makeTestDirectory(name: name)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeSyntaxArtifact(
        path: String,
        symbolName: String = "codemapOnlySymbol",
        className: String? = nil,
        imports: [String] = [],
        referencedTypes: [String] = []
    ) -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: imports,
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

    private func makePresentation(
        entries: [(WorkspaceFileRecord, String)]
    ) throws -> WorkspaceCodemapOperationPresentation {
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let bundleID = WorkspaceCodemapFrozenPresentationBundleID()
        let rendered = try entries.enumerated().map { index, pair in
            let (file, text) = pair
            let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: "LogicalRoot",
                standardizedRelativePath: file.standardizedRelativePath
            ))
            return WorkspaceCodemapOperationRenderedEntry(
                bundleID: bundleID,
                fileID: file.id,
                rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: file.rootID,
                    rootLifetimeID: UUID()
                ),
                artifactKey: CodeMapArtifactKey(
                    rawSHA256: CodeMapRawSourceDigest(
                        bytes: Data(repeating: UInt8((index % 254) + 1), count: 32)
                    ),
                    rawByteCount: UInt64(text.utf8.count),
                    pipelineIdentity: pipeline
                ),
                logicalPath: logicalPath,
                text: text,
                tokenCount: TokenCalculationService.estimateTokens(for: text)
            )
        }
        return WorkspaceCodemapOperationPresentation(
            orderedEntries: rendered,
            coverage: .complete,
            issues: [],
            publicationReceipt: nil
        )
    }
}

private enum ResolvedAccountingReaderError: Error {
    case failed
}

private actor ResolvedAccountingReaderRecorder {
    struct Input {
        let location: ResolvedFileContentLocation
        let workloadClass: ContentReadWorkloadClass
    }

    private let contents: [String: String]
    private var inputs: [Input] = []

    init(contents: [String: String]) {
        self.contents = contents
    }

    func read(
        location: ResolvedFileContentLocation,
        workloadClass: ContentReadWorkloadClass
    ) -> String? {
        inputs.append(Input(location: location, workloadClass: workloadClass))
        return contents[location.relativePath]
    }

    func recordedInputs() -> [Input] {
        inputs
    }
}

#if DEBUG
    private actor AccountingReadCancellationGate {
        private var count = 0
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            count += 1
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted() async {
            guard count > 0 else {
                await withCheckedContinuation { continuation in
                    startWaiters.append(continuation)
                }
                return
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func startedCount() -> Int {
            count
        }
    }
#endif
