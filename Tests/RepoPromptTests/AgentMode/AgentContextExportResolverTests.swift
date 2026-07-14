import Foundation
@testable import RepoPromptApp
import XCTest

private actor CompleteGitDiffProviderSpy {
    private let text: String?
    private var invocationCount = 0

    init(text: String?) {
        self.text = text
    }

    func provide() -> String? {
        invocationCount += 1
        return text
    }

    func count() -> Int {
        invocationCount
    }
}

private actor AgentContextExportLookupGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ResolvedContentReaderProbe {
    struct Input: Equatable {
        let location: ResolvedFileContentLocation
        let workloadClass: ContentReadWorkloadClass
    }

    private let content: String
    private let blocksFirstRead: Bool
    private var inputs: [Input] = []
    private var firstReadContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(content: String, blocksFirstRead: Bool = false) {
        self.content = content
        self.blocksFirstRead = blocksFirstRead
    }

    func read(
        location: ResolvedFileContentLocation,
        workloadClass: ContentReadWorkloadClass
    ) async throws -> String? {
        inputs.append(Input(location: location, workloadClass: workloadClass))
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if blocksFirstRead, inputs.count == 1 {
            await withCheckedContinuation { continuation in
                firstReadContinuation = continuation
            }
        }
        try Task.checkCancellation()
        return content
    }

    func waitUntilReadStarts() async {
        guard inputs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstRead() {
        firstReadContinuation?.resume()
        firstReadContinuation = nil
    }

    func recordedInputs() -> [Input] {
        inputs
    }
}

private actor CompleteGitDiffInputRecorder {
    struct Input: Equatable {
        let rootPath: String
        let compareIntent: ReviewGitCompareIntent
    }

    private var inputs: [Input] = []

    func resolve(rootPath: String, compareIntent: ReviewGitCompareIntent) -> String? {
        inputs.append(Input(rootPath: rootPath, compareIntent: compareIntent))
        return "diff --git a/Sources/Original.swift b/Sources/Original.swift\n+completeGitSnapshot"
    }

    func recordedInputs() -> [Input] {
        inputs
    }
}

final class AgentContextExportResolverTests: XCTestCase {
    func testDisplayFileCountUsesExplicitSelectionAndExcludesAutoCodemaps() {
        let selection = StoredSelection(
            selectedPaths: ["A.swift", "B.swift", "C.swift", "D.swift", "E.swift"],

            slices: [
                "E.swift": [LineRange(start: 1, end: 2)],
                "F.swift": [LineRange(start: 3, end: 4)]
            ],
            codemapAutoEnabled: true
        )

        XCTAssertEqual(AgentContextExportResolver.explicitSelectionFileCount(selection), 6)
        XCTAssertEqual(
            AgentContextExportResolver.displayFileCount(resolvedModel: nil, sourceSelection: selection),
            6
        )
    }

    func testSelectionSummaryDistinguishesFullAndSlicedFiles() {
        let selection = StoredSelection(
            selectedPaths: ["Sources/Full.swift", "Sources/Sliced.swift"],
            slices: [
                "Sources/Sliced.swift": [
                    LineRange(start: 2, end: 4),
                    LineRange(start: 8, end: 10)
                ]
            ],
            codemapAutoEnabled: false
        )

        let summary = AgentContextExportResolver.selectionSummary(for: selection)

        XCTAssertEqual(summary.totalExplicitFileCount, 2)
        XCTAssertEqual(summary.fullFileCount, 1)
        XCTAssertEqual(summary.slicedFileCount, 1)
        XCTAssertEqual(summary.sliceRangeCount, 2)
        XCTAssertEqual(summary.compactText, "2 files")
        XCTAssertEqual(summary.headlineText, "2 files · 2 slices")
    }

    func testSelectionSummaryIncludesLegacySliceOnlyKey() {
        let selection = StoredSelection(
            slices: ["Sources/SliceOnly.swift": [LineRange(start: 3, end: 7)]],
            codemapAutoEnabled: false
        )

        let summary = AgentContextExportResolver.selectionSummary(for: selection)

        XCTAssertEqual(summary.totalExplicitFileCount, 1)
        XCTAssertEqual(summary.fullFileCount, 0)
        XCTAssertEqual(summary.slicedFileCount, 1)
        XCTAssertEqual(summary.sliceRangeCount, 1)
        XCTAssertEqual(summary.compactText, "1 file")
        XCTAssertEqual(summary.headlineText, "1 file · 1 slice")
    }

    func testSelectionSummaryDeduplicatesSelectedPathWithSlices() {
        let selection = StoredSelection(
            selectedPaths: ["Sources/App.swift"],
            slices: ["Sources/App.swift": [LineRange(start: 1, end: 2)]],
            codemapAutoEnabled: false
        )

        let summary = AgentContextExportResolver.selectionSummary(for: selection)

        XCTAssertEqual(summary.totalExplicitFileCount, 1)
        XCTAssertEqual(summary.fullFileCount, 0)
        XCTAssertEqual(summary.slicedFileCount, 1)
        XCTAssertEqual(summary.sliceRangeCount, 1)
    }

    func testSelectionSummaryIncludesManualCodemapSelections() {
        let selection = StoredSelection(
            selectedPaths: ["Sources/Full.swift", "Sources/Duplicate.swift"],
            manualCodemapPaths: ["Sources/Codemap.swift", "Sources/Duplicate.swift"],
            slices: ["Sources/Sliced.swift": [LineRange(start: 1, end: 2)]],
            codemapAutoEnabled: false
        )

        let summary = AgentContextExportResolver.selectionSummary(for: selection)

        XCTAssertEqual(summary.totalExplicitFileCount, 4)
        XCTAssertEqual(summary.fullFileCount, 2)
        XCTAssertEqual(summary.slicedFileCount, 1)
        XCTAssertEqual(summary.codemapFileCount, 1)
        XCTAssertEqual(summary.sliceRangeCount, 1)

        let fileCodemapSummary = AgentContextFileCodemapCountSummary.intent(from: summary)
        XCTAssertEqual(fileCodemapSummary.fileCount, 3)
        XCTAssertEqual(fileCodemapSummary.codemapCount, 1)
        XCTAssertEqual(fileCodemapSummary.sliceRangeCount, 1)
        XCTAssertEqual(fileCodemapSummary.headlineText, "3 files · 1 codemap · 1 slice")
    }

    func testSelectionSummaryExcludesEmptySlicesAndDoesNotInferCodemaps() {
        let selection = StoredSelection(
            slices: ["Sources/Empty.swift": []],
            codemapAutoEnabled: true
        )

        let summary = AgentContextExportResolver.selectionSummary(for: selection)

        XCTAssertEqual(summary.totalExplicitFileCount, 0)
        XCTAssertEqual(summary.fullFileCount, 0)
        XCTAssertEqual(summary.slicedFileCount, 0)
        XCTAssertEqual(summary.sliceRangeCount, 0)
        XCTAssertEqual(summary.compactText, "0 files")
        XCTAssertEqual(summary.headlineText, "0 files")
    }

    func testSelectionSummaryRetainsFullOnlyFormatting() {
        let singular = AgentContextExportResolver.selectionSummary(
            for: StoredSelection(selectedPaths: ["One.swift"], codemapAutoEnabled: false)
        )
        let plural = AgentContextExportResolver.selectionSummary(
            for: StoredSelection(selectedPaths: ["One.swift", "Two.swift"], codemapAutoEnabled: false)
        )

        XCTAssertEqual(singular.compactText, "1 file")
        XCTAssertEqual(singular.headlineText, "1 file")
        XCTAssertEqual(plural.compactText, "2 files")
        XCTAssertEqual(plural.headlineText, "2 files")
    }

    func testSelectionSummaryDeduplicatesNormalizedAliasesAndSumsStoredRanges() {
        let selection = StoredSelection(
            slices: [
                "Sources/Alias.swift": [LineRange(start: 1, end: 2)],
                " Sources/Alias.swift ": [
                    LineRange(start: 4, end: 5),
                    LineRange(start: 8, end: 9)
                ]
            ],
            codemapAutoEnabled: false
        )

        let summary = AgentContextExportResolver.selectionSummary(for: selection)

        XCTAssertEqual(summary.totalExplicitFileCount, 1)
        XCTAssertEqual(summary.fullFileCount, 0)
        XCTAssertEqual(summary.slicedFileCount, 1)
        XCTAssertEqual(summary.sliceRangeCount, 3)
        XCTAssertEqual(summary.compactText, "1 file")
        XCTAssertEqual(summary.headlineText, "1 file · 3 slices")
    }

    func testNonGitAutomaticExportBatchesSelectedPathLookupsWithoutRuntimeFallback() async throws {
        #if DEBUG
            let root = try makeTemporaryRoot(name: "AgentExportNonGitAuto")
            let explicitFileCount = 7
            var selectedPaths: [String] = []
            var slices: [String: [LineRange]] = [:]
            for index in 0 ..< explicitFileCount {
                let fileURL = root.appendingPathComponent("Selected\(index).swift")
                try write("struct Selected\(index) {}", to: fileURL)
                selectedPaths.append(fileURL.path)
                if index >= 3 {
                    slices[fileURL.path] = [LineRange(start: 1, end: 1)]
                }
            }
            for index in 0 ..< 44 {
                try write(
                    "struct Dependency\(index) {}",
                    to: root.appendingPathComponent("Dependency\(index).swift")
                )
            }

            let runtimeAccessCount = AgentExportLockedCounter()
            let store = WorkspaceFileContextStore(codemapRuntimeProvider: {
                runtimeAccessCount.increment()
                throw AgentExportTestError.unexpectedRuntimeAccess
            })
            _ = try await store.loadRoot(path: root.path)
            let source = AgentContextExportSource(
                tabID: UUID(),
                promptText: "Review",
                selection: StoredSelection(
                    selectedPaths: selectedPaths,
                    slices: slices,
                    codemapAutoEnabled: true
                ),
                selectedMetaPromptIDs: [],
                tabName: "Agent Tab",
                activeAgentSessionID: nil,
                worktreeBindings: []
            )

            EditFlowPerf.resetDebugCaptureForTesting()
            defer { EditFlowPerf.resetDebugCaptureForTesting() }
            switch EditFlowPerf.beginDebugCapture(label: "agent-export-auto-codemap-batch", maxSamples: 200) {
            case .started:
                break
            case .busy:
                XCTFail("Performance capture should start")
            }

            let interimModels = AgentExportLockedModelRecorder()
            let model = try await AgentContextExportResolver.resolveModel(
                source: source,
                store: store,
                filePathDisplay: .relative,
                codeMapUsage: .auto,
                interimFileRowsHandler: { model in
                    interimModels.append(model)
                }
            )
            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let snapshotBuildCount = capture.stages
                .filter { $0.stageName == String(describing: EditFlowPerf.Stage.ReadFile.pathLookupStaticSnapshotBuild) }
                .reduce(0) { $0 + $1.sampleCount }

            let publishedInterimModels = interimModels.values
            XCTAssertEqual(publishedInterimModels.count, 1)
            let interimModel = try XCTUnwrap(publishedInterimModels.first)
            XCTAssertEqual(interimModel.totalSelectedDisplayTokens, 0)
            XCTAssertTrue(interimModel.rows.allSatisfy { $0.metrics == .unknown })
            XCTAssertEqual(interimModel.rows.count(where: { $0.kind != .codemap }), explicitFileCount)
            XCTAssertEqual(interimModel.rows.count(where: { $0.kind == .codemap }), 0)
            XCTAssertEqual(model.rows.count(where: { $0.kind != .codemap }), explicitFileCount)
            XCTAssertEqual(model.rows.count(where: { $0.kind == .slices }), 4)
            XCTAssertEqual(model.rows.count(where: { $0.kind == .codemap }), 0)
            guard case .unavailable = model.codemapCoverage else {
                return XCTFail("Non-Git automatic export must report unavailable codemap coverage")
            }
            XCTAssertFalse(model.codemapIssues.isEmpty)
            XCTAssertEqual(runtimeAccessCount.value, 0)
            XCTAssertEqual(
                AgentContextExportResolver.displayFileCount(
                    resolvedModel: model,
                    sourceSelection: source.selection
                ),
                explicitFileCount
            )
            XCTAssertEqual(snapshotBuildCount, 1)
            XCTAssertLessThan(snapshotBuildCount, explicitFileCount)
            XCTAssertEqual(capture.droppedSampleCount, 0)
        #endif
    }

    func testAutoCodemapInterimRowsPreserveProvidedMetricsSnapshot() async throws {
        let root = try makeTemporaryRoot(name: "AgentExportInterimMetrics")
        let selectedURL = root.appendingPathComponent("Sources/Feature/Selected.swift")
        try write("struct Selected {}", to: selectedURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let selectedLookup = await store.lookupPath(selectedURL.path, profile: .uiAssisted)
        let selectedFile = try XCTUnwrap(selectedLookup?.file)
        let metricsSnapshot = PromptContextEntryMetricsSnapshot(
            totalSelectedDisplayTokens: 42,
            metrics: [
                PromptContextEntryMetric(
                    fileID: selectedFile.id,
                    standardizedFullPath: selectedFile.standardizedFullPath,
                    renderedDisplayPath: "Sources/Feature/Selected.swift",
                    renderMode: .full,
                    displayTokenCount: 42,
                    displayPercentage: 1,
                    includedLineCount: 7
                )
            ]
        )
        let source = AgentContextExportSource(
            tabID: UUID(),
            promptText: "Review",
            selection: StoredSelection(selectedPaths: [selectedURL.path], codemapAutoEnabled: true),
            selectedMetaPromptIDs: [],
            tabName: "Agent Tab",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )
        let interimModels = AgentExportLockedModelRecorder()

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .auto,
            entryMetricsSnapshot: metricsSnapshot,
            interimFileRowsHandler: { model in
                interimModels.append(model)
            }
        )

        let publishedInterimModels = interimModels.values
        XCTAssertEqual(publishedInterimModels.count, 1)
        let interimModel = try XCTUnwrap(publishedInterimModels.first)
        XCTAssertEqual(interimModel.totalSelectedDisplayTokens, 42)
        let interimMetrics = try XCTUnwrap(interimModel.rows.first?.metrics.knownValues)
        XCTAssertEqual(interimMetrics.tokenCount, 42)
        XCTAssertEqual(interimMetrics.tokenPercentage, 1)
        XCTAssertEqual(interimMetrics.lineCount, 7)
        XCTAssertEqual(interimModel.rows.count(where: { $0.kind != .codemap }), 1)
        XCTAssertEqual(interimModel.rows.count(where: { $0.kind == .codemap }), 0)

        XCTAssertEqual(model.totalSelectedDisplayTokens, 42)
        let finalMetrics = try XCTUnwrap(model.rows.first?.metrics.knownValues)
        XCTAssertEqual(finalMetrics.tokenCount, 42)
        XCTAssertEqual(finalMetrics.tokenPercentage, 1)
        XCTAssertEqual(finalMetrics.lineCount, 7)
    }

    func testSelectedFilesModelWithoutCodemapsDoesNotEnumerateWholeRoots() async throws {
        #if DEBUG
            let root = try makeTemporaryRoot(name: "AgentExportNoBroadEnumeration")
            let selectedURL = root.appendingPathComponent("Sources/Feature/Selected.swift")
            try write(SwiftFixtureSource.emptyStruct("Selected", trailingNewline: false), to: selectedURL)
            for index in 0 ..< 80 {
                try write(
                    "struct Bystander\(index) {}",
                    to: root.appendingPathComponent("Sources/Generated/Level\(index % 8)/Nested\(index)/Bystander\(index).swift")
                )
            }

            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            let selectedLookup = await store.lookupPath(selectedURL.path, profile: .uiAssisted)
            let selectedFile = try XCTUnwrap(selectedLookup?.file)
            let metricsSnapshot = PromptContextEntryMetricsSnapshot(
                totalSelectedDisplayTokens: 42,
                metrics: [
                    PromptContextEntryMetric(
                        fileID: selectedFile.id,
                        standardizedFullPath: selectedFile.standardizedFullPath,
                        renderedDisplayPath: "Sources/Feature/Selected.swift",
                        renderMode: .full,
                        displayTokenCount: 42,
                        displayPercentage: 1,
                        includedLineCount: 7
                    )
                ]
            )
            await store.resetFilesInRootRequestCountForTesting()
            let source = AgentContextExportSource(
                tabID: UUID(),
                promptText: "Review",
                selection: StoredSelection(selectedPaths: [selectedURL.path], codemapAutoEnabled: false),
                selectedMetaPromptIDs: [],
                tabName: "Agent Tab",
                activeAgentSessionID: nil,
                worktreeBindings: []
            )
            let codemapOperationCountsBefore = await store.codemapPresentationOperationCountsForTesting()

            let model = try await AgentContextExportResolver.resolveModel(
                source: source,
                store: store,
                filePathDisplay: .relative,
                codeMapUsage: .none,
                entryMetricsSnapshot: metricsSnapshot
            )

            XCTAssertEqual(model.rows.map(\.displayPath), ["Sources/Feature/Selected.swift"])
            XCTAssertEqual(model.totalSelectedDisplayTokens, 42)
            let metrics = try XCTUnwrap(model.rows.first?.metrics.knownValues)
            XCTAssertEqual(metrics.tokenCount, 42)
            XCTAssertEqual(metrics.tokenPercentage, 1)
            XCTAssertEqual(metrics.lineCount, 7)
            XCTAssertTrue(model.codemapPresentation.orderedEntries.isEmpty)
            XCTAssertTrue(model.codemapPresentation.renderedEntriesByFileID.isEmpty)
            XCTAssertEqual(model.codemapPresentation.coverage, .complete)
            XCTAssertTrue(model.codemapPresentation.issues.isEmpty)

            let zeroMetricsSnapshot = PromptContextEntryMetricsSnapshot(
                totalSelectedDisplayTokens: 0,
                metrics: [
                    PromptContextEntryMetric(
                        fileID: selectedFile.id,
                        standardizedFullPath: selectedFile.standardizedFullPath,
                        renderedDisplayPath: "Sources/Feature/Selected.swift",
                        renderMode: .full,
                        displayTokenCount: 0,
                        displayPercentage: 0,
                        includedLineCount: nil
                    )
                ]
            )
            let zeroSnapshotModel = try await AgentContextExportResolver.resolveModel(
                source: source,
                store: store,
                filePathDisplay: .relative,
                codeMapUsage: .none,
                entryMetricsSnapshot: zeroMetricsSnapshot
            )
            XCTAssertEqual(zeroSnapshotModel.totalSelectedDisplayTokens, 0)
            let zeroMetrics = try XCTUnwrap(zeroSnapshotModel.rows.first?.metrics.knownValues)
            XCTAssertEqual(zeroMetrics.tokenCount, 0)
            XCTAssertEqual(zeroMetrics.tokenPercentage, 0)
            XCTAssertNil(zeroMetrics.lineCount)
            XCTAssertEqual(zeroSnapshotModel.rows.first?.metrics.tokenSortKey, 0)

            let emptySnapshotModel = try await AgentContextExportResolver.resolveModel(
                source: source,
                store: store,
                filePathDisplay: .relative,
                codeMapUsage: .none,
                entryMetricsSnapshot: .empty
            )
            XCTAssertEqual(emptySnapshotModel.totalSelectedDisplayTokens, 0)
            XCTAssertEqual(emptySnapshotModel.rows.first?.metrics, .unknown)

            let filesInRootRequestCount = await store.fileEnumerationRequestCountForTesting()
            let codemapOperationCountsAfter = await store.codemapPresentationOperationCountsForTesting()
            XCTAssertEqual(filesInRootRequestCount, 0)
            XCTAssertEqual(codemapOperationCountsAfter, codemapOperationCountsBefore)
        #endif
    }

    func testWorktreeExportUsesPhysicalContentWhileDisplayingLogicalPath() async throws {
        let fixture = try await makeBoundFixture()
        let source = makeSource(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false)
        )

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: fixture.store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )

        let row = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertFalse(try XCTUnwrap(model.lookupContext.bindingProjection).isFullyMaterialized)
        XCTAssertEqual(row.displayPath, "Sources/App.swift")
        XCTAssertEqual(
            row.resolvedContentLocation?.resolvedFileURL,
            fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL
        )
        XCTAssertEqual(model.totalSelectedDisplayTokens, TokenCalculationService.estimateTokens(for: "let origin = \"worktree\"\n"))
        let metrics = try XCTUnwrap(row.metrics.knownValues)
        XCTAssertEqual(metrics.tokenCount, model.totalSelectedDisplayTokens)
        XCTAssertEqual(metrics.tokenPercentage, 1)
        XCTAssertEqual(metrics.lineCount, 1)
        XCTAssertEqual(row.rootDisplayName, fixture.logicalRoot.lastPathComponent)
        XCTAssertEqual(row.rootColorKey, fixture.logicalRoot.standardizedFileURL.path)
        XCTAssertFalse(row.showRootPill)

        let previewText = await AgentContextExportResolver.loadRowContent(
            for: row,
            model: model,
            store: fixture.store,
            purpose: .preview
        )
        XCTAssertEqual(previewText, "let origin = \"worktree\"\n")
        XCTAssertFalse(previewText?.contains("base") ?? true)

        let completeProvider = CompleteGitDiffProviderSpy(text: "unexpected complete diff")
        let clipboard = await AgentContextExportResolver.buildClipboardContent(
            AgentContextClipboardRequest(
                cfg: makeConfig(gitInclusion: .none),
                source: source,
                store: fixture.store,
                lookupContext: model.lookupContext,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: true,
                showCodeMapMarkers: true,
                metaInstructions: [],
                includeDatetimeInUserInstructions: false,
                promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
                disabledPromptSections: [],
                duplicateUserInstructionsAtTop: false,
                reviewGitContext: .automaticOnly(),
                completeGitDiffProvider: { await completeProvider.provide() ?? "" }
            )
        )

        let completeProviderInvocationCount = await completeProvider.count()

        XCTAssertTrue(clipboard.contains("Sources/App.swift"), clipboard)
        XCTAssertTrue(clipboard.contains("let origin = \"worktree\""), clipboard)
        XCTAssertFalse(clipboard.contains("let origin = \"base\""), clipboard)
        XCTAssertEqual(completeProviderInvocationCount, 0)
    }

    func testMetadataOnlyWorktreeMetricsUseBoundedAccountingReader() async throws {
        let fixture = try await makeBoundFixture()
        let source = makeSource(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false)
        )
        let content = "let measured = \"é🙂\"\nlet second = true\n"
        let probe = ResolvedContentReaderProbe(content: content)
        let accountingService = PromptContextAccountingService(resolvedContentReader: { location, workloadClass in
            try await probe.read(location: location, workloadClass: workloadClass)
        })

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: fixture.store,
            filePathDisplay: .relative,
            codeMapUsage: .none,
            accountingService: accountingService
        )

        let recordedInputs = await probe.recordedInputs()
        XCTAssertEqual(recordedInputs.count, 1)
        let input = try XCTUnwrap(recordedInputs.first)
        XCTAssertEqual(input.workloadClass, .promptAccounting)
        XCTAssertEqual(input.location.resolvedRootURL, fixture.worktreeRoot.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(
            input.location.resolvedFileURL,
            fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").resolvingSymlinksInPath().standardizedFileURL
        )
        XCTAssertEqual(input.location.relativePath, "Sources/App.swift")
        XCTAssertEqual(model.totalSelectedDisplayTokens, TokenCalculationService.estimateTokens(for: content))
        XCTAssertEqual(model.rows.count, 1)
        let row = try XCTUnwrap(model.rows.first)
        let metrics = try XCTUnwrap(row.metrics.knownValues)
        XCTAssertEqual(metrics.tokenCount, TokenCalculationService.estimateTokens(for: content))
        XCTAssertEqual(metrics.tokenPercentage, 1)
        XCTAssertEqual(metrics.lineCount, 2)
    }

    func testMetadataOnlyWorktreeMetricsHonorSharedReaderSizeBound() async throws {
        let fixture = try await makeBoundFixture()
        let oversizedContent = String(repeating: "a", count: 10_000_001)
        try write(oversizedContent, to: fixture.worktreeRoot.appendingPathComponent("Sources/App.swift"))
        let source = makeSource(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false)
        )

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: fixture.store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )

        let boundedContent = "[File too large: 10000001 bytes]"
        XCTAssertEqual(model.totalSelectedDisplayTokens, TokenCalculationService.estimateTokens(for: boundedContent))
        let metrics = try XCTUnwrap(model.rows.first?.metrics.knownValues)
        XCTAssertEqual(metrics.tokenCount, TokenCalculationService.estimateTokens(for: boundedContent))
        XCTAssertEqual(metrics.lineCount, 1)
    }

    func testMetadataOnlyWorktreeResolutionCancellationStopsBeforeNextRead() async throws {
        let fixture = try await makeBoundFixture()
        let source = makeSource(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            selection: StoredSelection(
                selectedPaths: ["Sources/App.swift", "Sources/Keep.swift"],
                codemapAutoEnabled: false
            )
        )
        let probe = ResolvedContentReaderProbe(content: "unreachable", blocksFirstRead: true)
        let accountingService = PromptContextAccountingService(resolvedContentReader: { location, workloadClass in
            try await probe.read(location: location, workloadClass: workloadClass)
        })
        let finalModelAssemblyCount = AgentExportLockedCounter()
        let resolutionTask = Task {
            try await AgentContextExportResolver.resolveModel(
                source: source,
                store: fixture.store,
                filePathDisplay: .relative,
                codeMapUsage: .none,
                accountingService: accountingService,
                phaseDidBeginForTesting: { phase in
                    if phase == .finalModelAssembly {
                        finalModelAssemblyCount.increment()
                    }
                }
            )
        }
        await probe.waitUntilReadStarts()

        resolutionTask.cancel()
        await probe.releaseFirstRead()

        do {
            _ = try await resolutionTask.value
            XCTFail("Expected metadata-only resolution cancellation")
        } catch is CancellationError {
            // Expected
        }
        let inputs = await probe.recordedInputs()
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.location.relativePath, "Sources/App.swift")
        XCTAssertEqual(finalModelAssemblyCount.value, 0)
    }

    func testMetadataOnlyCancellationImmediatelyBeforeReturnPublishesNoModel() async throws {
        let fixture = try await makeBoundFixture()
        let source = makeSource(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false)
        )
        let finalModelAssemblyCount = AgentExportLockedCounter()

        do {
            _ = try await AgentContextExportResolver.resolveModel(
                source: source,
                store: fixture.store,
                filePathDisplay: .relative,
                codeMapUsage: .none,
                phaseDidBeginForTesting: { phase in
                    guard phase == .finalModelAssembly else { return }
                    finalModelAssemblyCount.increment()
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
            XCTFail("Expected cancellation immediately before model publication")
        } catch is CancellationError {
            // Expected
        }
        XCTAssertEqual(finalModelAssemblyCount.value, 1)
    }

    func testMetadataOnlyInsideRootSymlinkPreservesResolvedTargetURL() async throws {
        let fixture = try await makeBoundFixture()
        let targetURL = fixture.worktreeRoot.appendingPathComponent("Sources/Target.swift")
        let symlinkURL = fixture.worktreeRoot.appendingPathComponent("Sources/Linked.swift")
        try write("let target = true\n", to: targetURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        let source = makeSource(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            selection: StoredSelection(selectedPaths: ["Sources/Linked.swift"], codemapAutoEnabled: false)
        )
        let probe = ResolvedContentReaderProbe(content: "let target = true\n")
        let accountingService = PromptContextAccountingService(resolvedContentReader: { location, workloadClass in
            try await probe.read(location: location, workloadClass: workloadClass)
        })

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: fixture.store,
            filePathDisplay: .relative,
            codeMapUsage: .none,
            accountingService: accountingService
        )

        let recordedInputs = await probe.recordedInputs()
        let input = try XCTUnwrap(recordedInputs.first)
        XCTAssertEqual(input.location.resolvedFileURL, targetURL.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(input.location.relativePath, "Sources/Target.swift")
        let row = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(row.displayPath, "Sources/Linked.swift")
        XCTAssertEqual(row.physicalPath, symlinkURL.standardizedFileURL.path)
        XCTAssertEqual(row.resolvedContentLocation, input.location)
    }

    func testBoundWorktreeAutoCodemapDoesNotUseMetadataOnlyFastPathWhenAutoCodemapEnabled() async throws {
        let fixture = try await makeBoundFixture()
        _ = try await fixture.store.loadRoot(path: fixture.worktreeRoot.path)
        let source = makeSource(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: true)
        )

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: fixture.store,
            filePathDisplay: .relative,
            codeMapUsage: .auto
        )

        XCTAssertEqual(model.rows.first?.displayPath, "Sources/App.swift")
        XCTAssertTrue(model.rows.allSatisfy { $0.resolvedContentLocation == nil })
    }

    func testMetadataOnlyWorktreeExportDoesNotDirectReadSymlinkEscapingRoot() async throws {
        let fixture = try await makeBoundFixture()
        let externalRoot = try makeTemporaryRoot(name: "AgentExportExternal")
        let externalFile = externalRoot.appendingPathComponent("Secret.swift")
        let symlink = fixture.worktreeRoot.appendingPathComponent("Sources/Linked.swift")
        try write("let secret = true\n", to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: externalFile
        )
        let source = makeSource(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            selection: StoredSelection(selectedPaths: ["Sources/Linked.swift"], codemapAutoEnabled: false)
        )

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: fixture.store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )

        XCTAssertFalse(model.lookupContext.bindingProjection?.isFullyMaterialized == false)
        XCTAssertTrue(model.rows.allSatisfy { $0.resolvedContentLocation == nil })
        if let row = model.rows.first {
            let previewText = await AgentContextExportResolver.loadRowContent(
                for: row,
                model: model,
                store: fixture.store,
                purpose: .preview
            )
            XCTAssertNotEqual(previewText, "let secret = true\n")
        }
    }

    func testEmptyBoundExportSkipsWorktreeProjection() async throws {
        let fixture = try await makeBoundFixture()
        let source = makeSource(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            selection: StoredSelection(codemapAutoEnabled: false)
        )

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: fixture.store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.missingPaths.isEmpty)
        XCTAssertTrue(model.invalidPaths.isEmpty)
        XCTAssertNil(model.lookupContext.bindingProjection)
        XCTAssertEqual(model.lookupContext.rootScope, .visibleWorkspace)
    }

    func testWorktreeSelectedCodemapUsesFrozenLogicalPresentationWithoutPhysicalLeak() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        defer { repositoryFixture.cleanup() }
        let logicalRoot = try repositoryFixture.makeRepository(
            named: "agent-export-logical",
            files: ["App.swift": SwiftFixtureSource.emptyStruct("LogicalBase")]
        )
        let worktreeRoot = try repositoryFixture.makeRepository(
            named: "agent-export-physical-secret",
            files: [
                "App.swift": "struct WorktreeAgentExport { func worktreeExportCodemapSymbol() { let physicalBodySentinel = true } }\n"
            ]
        )
        let store = try makeIsolatedCodemapStore(name: #function)
        _ = try await store.loadRoot(path: logicalRoot.path)
        let source = makeSource(
            logicalRoot: logicalRoot,
            worktreeRoot: worktreeRoot,
            selection: StoredSelection(selectedPaths: ["App.swift"], codemapAutoEnabled: false)
        )
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 20,
                maximumTotalWait: .seconds(10)
            )
        )

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .selected,
            presentationCoordinator: coordinator
        )

        let row = try XCTUnwrap(model.rows.first)
        let rendered = try XCTUnwrap(model.codemapPresentation.renderedEntriesByFileID[row.id.fileID])
        XCTAssertEqual(row.kind, .codemap)
        XCTAssertEqual(row.displayPath, "App.swift")
        XCTAssertEqual(row.directoryDisplay, rendered.logicalPath.rootDisplayName)
        XCTAssertEqual(rendered.rootEpoch.rootID, row.rootID)
        XCTAssertFalse(rendered.logicalPath.rootDisplayName.isEmpty)
        XCTAssertFalse(rendered.logicalPath.rootDisplayName.contains(worktreeRoot.path))
        XCTAssertFalse(rendered.logicalPath.rootDisplayName.contains(worktreeRoot.lastPathComponent))
        XCTAssertEqual(rendered.tokenCount, TokenCalculationService.estimateTokens(for: rendered.text))
        XCTAssertFalse(rendered.text.contains(worktreeRoot.path), rendered.text)
        XCTAssertFalse(rendered.text.contains(worktreeRoot.lastPathComponent), rendered.text)

        let preview = await AgentContextExportResolver.loadRowContent(
            for: row,
            model: model,
            store: store,
            purpose: .preview
        )
        XCTAssertEqual(preview, rendered.text)

        let clipboard = await AgentContextExportResolver.buildClipboardContent(
            AgentContextClipboardRequest(
                cfg: makeConfig(gitInclusion: .none, codeMapUsage: .selected),
                source: source,
                store: store,
                lookupContext: model.lookupContext,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: true,
                showCodeMapMarkers: true,
                metaInstructions: [],
                includeDatetimeInUserInstructions: false,
                promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
                disabledPromptSections: [],
                duplicateUserInstructionsAtTop: false,
                reviewGitContext: .automaticOnly(),
                completeGitDiffProvider: { "" }
            )
        )
        XCTAssertTrue(clipboard.contains("worktreeExportCodemapSymbol"), clipboard)
        XCTAssertFalse(clipboard.contains("physicalBodySentinel"), clipboard)
        XCTAssertFalse(clipboard.contains(worktreeRoot.path), clipboard)
    }

    func testSelectedUnavailableCodemapPreservesFullRowAndReportsIncompleteCoverage() async throws {
        let root = try makeTemporaryRoot(name: "AgentExportSelectedUnavailable")
        try write(SwiftFixtureSource.emptyStruct("SelectedUnavailable"), to: root.appendingPathComponent("Sources/App.swift"))
        let runtimeAccessCount = AgentExportLockedCounter()
        let store = WorkspaceFileContextStore(codemapRuntimeProvider: {
            runtimeAccessCount.increment()
            throw AgentExportTestError.unexpectedRuntimeAccess
        })
        _ = try await store.loadRoot(path: root.path)
        let source = AgentContextExportSource(
            tabID: UUID(),
            promptText: "Review",
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false),
            selectedMetaPromptIDs: [],
            tabName: "Agent Tab",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .selected
        )

        XCTAssertEqual(model.rows.map(\.kind), [.full])
        guard case .unavailable = model.codemapCoverage else {
            return XCTFail("Selected unavailable codemap must report incomplete coverage")
        }
        XCTAssertFalse(model.codemapIssues.isEmpty)
        XCTAssertEqual(runtimeAccessCount.value, 0)
    }

    func testResolveModelCancellationDuringPresentationStopsDownstreamPhases() async throws {
        let root = try makeTemporaryRoot(name: "AgentExportPresentationCancellation")
        try write("struct PresentationCancellation {}\n", to: root.appendingPathComponent("Sources/App.swift"))
        let store = try makeIsolatedCodemapStore(name: #function)
        _ = try await store.loadRoot(path: root.path)
        let source = AgentContextExportSource(
            tabID: UUID(),
            promptText: "Review",
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: true),
            selectedMetaPromptIDs: [],
            tabName: "Agent Tab",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )
        let presentationStarted = expectation(description: "Model resolution reached codemap presentation")
        let presentationGate = AgentContextExportLookupGate()
        let codemapFileRecordCount = AgentExportLockedCounter()
        let metricsAssemblyCount = AgentExportLockedCounter()
        let finalModelAssemblyCount = AgentExportLockedCounter()
        let resolutionTask = Task {
            try await AgentContextExportResolver.resolveModel(
                source: source,
                store: store,
                filePathDisplay: .relative,
                codeMapUsage: .complete,
                presentationWillBeginForTesting: { () async throws(CancellationError) in
                    presentationStarted.fulfill()
                    await presentationGate.wait()
                    guard !Task.isCancelled else { throw CancellationError() }
                },
                phaseDidBeginForTesting: { phase in
                    switch phase {
                    case .codemapFileRecords:
                        codemapFileRecordCount.increment()
                    case .metricsAssembly:
                        metricsAssemblyCount.increment()
                    case .finalModelAssembly:
                        finalModelAssemblyCount.increment()
                    }
                }
            )
        }

        await fulfillment(of: [presentationStarted], timeout: 5)
        resolutionTask.cancel()
        await presentationGate.open()
        do {
            let model = try await resolutionTask.value
            XCTFail("Cancellation was swallowed and returned a downstream model with \(model.rows.count) rows")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        XCTAssertEqual(codemapFileRecordCount.value, 0)
        XCTAssertEqual(metricsAssemblyCount.value, 0)
        XCTAssertEqual(finalModelAssemblyCount.value, 0)
    }

    func testManualUnavailableCodemapOmitsCodemapRowsAndReportsIncompleteCoverage() async throws {
        let root = try makeTemporaryRoot(name: "AgentExportManualUnavailable")
        try write("struct ManualUnavailable {}\n", to: root.appendingPathComponent("Sources/App.swift"))
        let runtimeAccessCount = AgentExportLockedCounter()
        let store = WorkspaceFileContextStore(codemapRuntimeProvider: {
            runtimeAccessCount.increment()
            throw AgentExportTestError.unexpectedRuntimeAccess
        })
        _ = try await store.loadRoot(path: root.path)
        let source = AgentContextExportSource(
            tabID: UUID(),
            promptText: "Review",
            selection: StoredSelection(
                manualCodemapPaths: ["Sources/App.swift"],
                codemapAutoEnabled: false
            ),
            selectedMetaPromptIDs: [],
            tabName: "Agent Tab",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .auto
        )

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.rows.count(where: { $0.kind == .codemap }), 0)
        guard case .unavailable = model.codemapCoverage else {
            return XCTFail("Manual unavailable codemap must report incomplete coverage")
        }
        XCTAssertFalse(model.codemapIssues.isEmpty)
        XCTAssertEqual(runtimeAccessCount.value, 0)
    }

    func testRevokedCodemapLifetimeOmitsStaleTargetBeforeModelPublication() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        defer { repositoryFixture.cleanup() }
        let logicalRoot = try repositoryFixture.makeRepository(
            named: "agent-export-revoked-logical",
            files: ["Sources/Target.swift": SwiftFixtureSource.emptyStruct("LogicalTarget")]
        )
        let worktreeRoot = try repositoryFixture.makeRepository(
            named: "agent-export-revoked-worktree",
            files: ["Sources/Target.swift": "struct RevokedTarget { func retainedUntilPublication() {} }\n"]
        )
        let store = try makeIsolatedCodemapStore(name: #function)
        _ = try await store.loadRoot(path: logicalRoot.path)
        let source = makeSource(
            logicalRoot: logicalRoot,
            worktreeRoot: worktreeRoot,
            selection: StoredSelection(
                selectedPaths: ["Sources/Target.swift"],
                codemapAutoEnabled: false
            )
        )
        let lookupContext = await AgentContextExportResolver.lookupContext(source: source, store: store)
        let boundRoots = await store.rootRefs(scope: lookupContext.rootScope)
        let physicalRootID = try XCTUnwrap(boundRoots.first {
            $0.standardizedFullPath == worktreeRoot.standardizedFileURL.path
        }?.id)
        let revalidationCount = AgentExportLockedCounter()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 20,
                maximumTotalWait: .seconds(10)
            ),
            beforePublicationRevalidation: { _ in
                revalidationCount.increment()
                if revalidationCount.value == 1 {
                    await store.unloadRoot(id: physicalRootID)
                }
            }
        )

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .selected,
            presentationCoordinator: coordinator
        )

        XCTAssertEqual(model.rows.map(\.kind), [.full])
        XCTAssertTrue(model.codemapPresentation.orderedEntries.isEmpty)
        guard case .unavailable = model.codemapCoverage else {
            return XCTFail("Revoked complete export must publish typed incomplete coverage")
        }
        XCTAssertGreaterThanOrEqual(revalidationCount.value, 1)
    }

    func testBoundExportFailsClosedWhenPhysicalWorktreeCannotBeLoaded() async throws {
        let logicalRoot = try makeTemporaryRoot(name: "AgentExportMissingLogical")
        try write("let origin = \"base\"\n", to: logicalRoot.appendingPathComponent("Sources/App.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        // Reusing the visible logical root as the bound physical root forces session-worktree
        // materialization to fail closed instead of silently reading the visible/base checkout.
        let unloadablePhysicalRoot = logicalRoot
        let source = makeSource(
            logicalRoot: logicalRoot,
            worktreeRoot: unloadablePhysicalRoot,
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false)
        )

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )
        XCTAssertEqual(model.lookupContext.bindingProjection?.physicalRootPaths, Set([unloadablePhysicalRoot.standardizedFileURL.path]))
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.missingPaths, ["Sources/App.swift"])
        XCTAssertFalse(model.missingPaths.contains { $0.contains(unloadablePhysicalRoot.path) })
        XCTAssertFalse(model.rows.contains { $0.displayPath == "Sources/App.swift" })
    }

    func testRemoveRowResolvesLogicalSelectionKeysByFileIdentity() async throws {
        let fixture = try await makeBoundFixture()
        let original = StoredSelection(
            selectedPaths: [
                "Sources/App.swift",
                fixture.logicalRoot.appendingPathComponent("Sources/App.swift").path,
                "Sources/Keep.swift"
            ],
            slices: ["Sources/App.swift": [LineRange(start: 1, end: 1)]],
            codemapAutoEnabled: false
        )
        let source = makeSource(logicalRoot: fixture.logicalRoot, worktreeRoot: fixture.worktreeRoot, selection: original)
        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: fixture.store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )
        let row = try XCTUnwrap(model.rows.first { $0.displayPath == "Sources/App.swift" })

        let updated = await AgentContextExportResolver.removeRow(
            row,
            from: original,
            lookupContext: model.lookupContext,
            store: fixture.store
        )

        XCTAssertEqual(updated.selectedPaths, ["Sources/Keep.swift"])
        XCTAssertTrue(updated.slices.isEmpty)
    }

    func testRemovingInferredAutomaticRowDisablesTransientSourceIntent() async throws {
        let fixture = try await makeBoundFixture()
        let lookupContext = await AgentContextExportResolver.lookupContext(
            source: makeSource(
                logicalRoot: fixture.logicalRoot,
                worktreeRoot: fixture.worktreeRoot,
                selection: StoredSelection(
                    selectedPaths: ["Sources/Keep.swift"],
                    codemapAutoEnabled: true
                )
            ),
            store: fixture.store
        )
        let inferredFileID = UUID()
        let inferredRow = AgentContextExportRow(
            id: ResolvedPromptFileEntryID(
                fileID: inferredFileID,
                mode: .codemap,
                lineRanges: nil
            ),
            kind: .codemap,
            rootID: UUID(),
            relativePath: "Sources/Inferred.swift",
            displayPath: "Sources/Inferred.swift",
            displayName: "Inferred.swift",
            directoryDisplay: "Sources",
            lineRanges: nil,
            canRemove: true,
            removesAutomaticSourceIntent: true
        )
        let selection = StoredSelection(
            selectedPaths: ["Sources/Keep.swift"],
            codemapAutoEnabled: true
        )

        let updated = await AgentContextExportResolver.removeRow(
            inferredRow,
            from: selection,
            lookupContext: lookupContext,
            store: fixture.store
        )

        XCTAssertEqual(updated.selectedPaths, selection.selectedPaths)
        XCTAssertTrue(updated.slices.isEmpty)
        XCTAssertFalse(updated.codemapAutoEnabled)
        XCTAssertTrue(inferredRow.canRemove)
    }

    func testUnboundAgentExportDoesNotSeeSessionWorktreeRoots() async throws {
        let logicalRoot = try makeTemporaryRoot(name: "AgentExportVisible")
        let hiddenWorktreeRoot = try makeTemporaryRoot(name: "AgentExportHiddenWorktree")
        try write("let hidden = true\n", to: hiddenWorktreeRoot.appendingPathComponent("Sources/Hidden.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        _ = try await store.loadRoot(path: hiddenWorktreeRoot.path, kind: .sessionWorktree)

        let source = AgentContextExportSource(
            tabID: UUID(),
            promptText: "Review this file",
            selection: StoredSelection(selectedPaths: ["Sources/Hidden.swift"], codemapAutoEnabled: false),
            selectedMetaPromptIDs: [],
            tabName: "Unbound Agent Tab",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )
        let lookupContext = await AgentContextExportResolver.lookupContext(source: source, store: store)
        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )

        XCTAssertEqual(lookupContext.rootScope, .visibleWorkspace)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.missingPaths, ["Sources/Hidden.swift"])
    }

    func testSingleLogicalRootSelectionInMultiRootWorkspaceHidesRootPill() async throws {
        let firstRoot = try makeTemporaryRoot(name: "AgentExportFirstRoot")
        let secondRoot = try makeTemporaryRoot(name: "AgentExportSecondRoot")
        let selectedFile = firstRoot.appendingPathComponent("Sources/Selected.swift")
        try write("struct SelectedOnly {}\n", to: selectedFile)
        try write("struct Unselected {}\n", to: secondRoot.appendingPathComponent("Sources/Unselected.swift"))
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: firstRoot.path)
        _ = try await store.loadRoot(path: secondRoot.path)

        let model = try await AgentContextExportResolver.resolveModel(
            source: AgentContextExportSource(
                tabID: UUID(),
                promptText: "Review one root",
                selection: StoredSelection(selectedPaths: [selectedFile.path], codemapAutoEnabled: false),
                selectedMetaPromptIDs: [],
                tabName: "Single-root selection",
                activeAgentSessionID: nil,
                worktreeBindings: []
            ),
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )

        let row = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(row.rootColorKey, firstRoot.standardizedFileURL.path)
        XCTAssertFalse(row.showRootPill)
    }

    func testSpanningLogicalRootsInMultiRootWorkspaceShowsRootPill() async throws {
        let firstRoot = try makeTemporaryRoot(name: "AgentExportSpanningFirstRoot")
        let secondRoot = try makeTemporaryRoot(name: "AgentExportSpanningSecondRoot")
        let firstFile = firstRoot.appendingPathComponent("Sources/First.swift")
        let secondFile = secondRoot.appendingPathComponent("Sources/Second.swift")
        try write("struct FirstRootSelection {}\n", to: firstFile)
        try write("struct SecondRootSelection {}\n", to: secondFile)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: firstRoot.path)
        _ = try await store.loadRoot(path: secondRoot.path)

        let model = try await AgentContextExportResolver.resolveModel(
            source: AgentContextExportSource(
                tabID: UUID(),
                promptText: "Review two roots",
                selection: StoredSelection(selectedPaths: [firstFile.path, secondFile.path], codemapAutoEnabled: false),
                selectedMetaPromptIDs: [],
                tabName: "Spanning selection",
                activeAgentSessionID: nil,
                worktreeBindings: []
            ),
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )

        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(
            Set(model.rows.map(\.rootColorKey)),
            Set([firstRoot.standardizedFileURL.path, secondRoot.standardizedFileURL.path])
        )
        XCTAssertTrue(model.rows.allSatisfy(\.showRootPill))
    }

    func testDuplicateRootBasenamesProduceStableAgentPathsWithoutPhysicalLeaks() async throws {
        let firstParent = try makeTemporaryRoot(name: "AgentDuplicateRootFirst")
        let secondParent = try makeTemporaryRoot(name: "AgentDuplicateRootSecond")
        let firstRoot = firstParent.appendingPathComponent("repo")
        let secondRoot = secondParent.appendingPathComponent("repo")
        let firstFile = firstRoot.appendingPathComponent("Sources/App.swift")
        let secondFile = secondRoot.appendingPathComponent("Sources/App.swift")
        try write(SwiftFixtureSource.emptyStruct("FirstDuplicateRoot"), to: firstFile)
        try write("struct SecondDuplicateRoot {\n    func largerSelectionRow() {\n        let repeated = \"more selected content\"\n        print(repeated)\n    }\n}\n", to: secondFile)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: firstRoot.path)
        _ = try await store.loadRoot(path: secondRoot.path)

        func model(paths: [String]) async throws -> AgentContextExportModel {
            try await AgentContextExportResolver.resolveModel(
                source: AgentContextExportSource(
                    tabID: UUID(),
                    promptText: "Review duplicate roots",
                    selection: StoredSelection(selectedPaths: paths, codemapAutoEnabled: false),
                    selectedMetaPromptIDs: [],
                    tabName: "Duplicate roots",
                    activeAgentSessionID: nil,
                    worktreeBindings: []
                ),
                store: store,
                filePathDisplay: .relative,
                codeMapUsage: .none
            )
        }

        let first = try await model(paths: [secondFile.path, firstFile.path])
        let second = try await model(paths: [firstFile.path, secondFile.path])
        let paths = first.rows.map(\.displayPath)

        XCTAssertEqual(paths, second.rows.map(\.displayPath))
        XCTAssertEqual(Set(paths).count, 2)
        XCTAssertEqual(first.rows.first?.rootColorKey, secondRoot.standardizedFileURL.path)
        XCTAssertEqual(first.rows.first?.metrics.tokenSortKey, first.rows.map(\.metrics.tokenSortKey).max())
        XCTAssertTrue(first.rows.allSatisfy(\.showRootPill))
        XCTAssertEqual(Set(first.rows.map(\.rootColorKey)), Set([firstRoot.standardizedFileURL.path, secondRoot.standardizedFileURL.path]))
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("root@") && $0.hasSuffix("/Sources/App.swift") })
        XCTAssertFalse(paths.contains { $0.contains(firstParent.path) || $0.contains(secondParent.path) })
        XCTAssertFalse(first.missingPaths.contains { $0.contains(firstParent.path) || $0.contains(secondParent.path) })
    }

    func testExportContextIdentityIncludesWorktreeBindingFingerprint() async throws {
        let fixture = try await makeBoundFixture()
        let otherWorktreeRoot = try makeTemporaryRoot(name: "AgentExportOtherWorktree")
        let tabID = UUID()
        let sessionID = UUID()
        let selection = StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false)
        let firstBinding = makeBinding(logicalRoot: fixture.logicalRoot, worktreeRoot: fixture.worktreeRoot)
        let secondBinding = makeBinding(logicalRoot: fixture.logicalRoot, worktreeRoot: otherWorktreeRoot)
        let firstSource = makeSource(
            tabID: tabID,
            sessionID: sessionID,
            selection: selection,
            bindings: [firstBinding]
        )
        let secondSource = makeSource(
            tabID: tabID,
            sessionID: sessionID,
            selection: selection,
            bindings: [secondBinding]
        )
        let visualOnlyChange = makeBinding(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            visualLabel: "different label"
        )
        let visualOnlySource = makeSource(
            tabID: tabID,
            sessionID: sessionID,
            selection: selection,
            bindings: [visualOnlyChange]
        )

        XCTAssertNotEqual(firstSource.exportContextIdentity, secondSource.exportContextIdentity)
        XCTAssertEqual(firstSource.exportContextIdentity, visualOnlySource.exportContextIdentity)

        let changedSelectionSource = makeSource(
            tabID: tabID,
            sessionID: sessionID,
            selection: StoredSelection(selectedPaths: ["Sources/Keep.swift"], codemapAutoEnabled: false),
            bindings: [firstBinding]
        )
        XCTAssertNotEqual(firstSource.exportContextIdentity, changedSelectionSource.exportContextIdentity)

        let changedSessionSource = makeSource(
            tabID: tabID,
            sessionID: UUID(),
            selection: selection,
            bindings: [firstBinding]
        )
        XCTAssertNotEqual(firstSource.exportContextIdentity, changedSessionSource.exportContextIdentity)
    }

    func testExportContextIdentityIncludesSessionWithoutWorktreeBindings() {
        let tabID = UUID()
        let selection = StoredSelection(selectedPaths: ["Sources/Selected.swift"], codemapAutoEnabled: false)
        let first = AgentContextExportSource(
            tabID: tabID,
            promptText: "",
            selection: selection,
            selectedMetaPromptIDs: [],
            tabName: nil,
            activeAgentSessionID: UUID(),
            worktreeBindings: []
        )
        let second = AgentContextExportSource(
            tabID: tabID,
            promptText: "",
            selection: selection,
            selectedMetaPromptIDs: [],
            tabName: nil,
            activeAgentSessionID: UUID(),
            worktreeBindings: []
        )

        XCTAssertNotEqual(first.exportContextIdentity, second.exportContextIdentity)
    }

    func testRemoveRowRebasedOntoLatestSelectionPreservesNewlyAddedFiles() async throws {
        let fixture = try await makeBoundFixture()
        let staleSelection = StoredSelection(
            selectedPaths: ["Sources/App.swift", "Sources/Keep.swift"],
            codemapAutoEnabled: false
        )
        let source = makeSource(logicalRoot: fixture.logicalRoot, worktreeRoot: fixture.worktreeRoot, selection: staleSelection)
        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: fixture.store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )
        let row = try XCTUnwrap(model.rows.first { $0.displayPath == "Sources/App.swift" })
        let latestSelection = StoredSelection(
            selectedPaths: ["Sources/App.swift", "Sources/Keep.swift", "Sources/New.swift"],
            codemapAutoEnabled: false
        )

        let updated = await AgentContextExportResolver.removeRow(
            row,
            from: latestSelection,
            lookupContext: model.lookupContext,
            store: fixture.store
        )

        XCTAssertEqual(updated.selectedPaths, ["Sources/Keep.swift", "Sources/New.swift"])
    }

    func testClearSelectionSnapshotPreservesNewlyAddedFiles() {
        let staleSnapshot = StoredSelection(
            selectedPaths: ["Sources/App.swift", "Sources/Keep.swift"],

            slices: ["Sources/App.swift": [LineRange(start: 1, end: 1)]],
            codemapAutoEnabled: false
        )
        let latestSelection = StoredSelection(
            selectedPaths: ["Sources/App.swift", "Sources/Keep.swift", "Sources/New.swift"],

            slices: [
                "Sources/App.swift": [LineRange(start: 1, end: 1)],
                "Sources/New.swift": [LineRange(start: 2, end: 2)]
            ],
            codemapAutoEnabled: false
        )

        let updated = AgentContextExportResolver.removeSelectionSnapshot(staleSnapshot, from: latestSelection)

        XCTAssertEqual(updated.selectedPaths, ["Sources/New.swift"])
        XCTAssertEqual(updated.slices, ["Sources/New.swift": [LineRange(start: 2, end: 2)]])
    }

    func testFolderExpandedRowsAreNotIndividuallyRemovable() async throws {
        let root = try makeTemporaryRoot(name: "AgentExportFolder")
        try write("let one = true\n", to: root.appendingPathComponent("Sources/One.swift"))
        try write("let two = true\n", to: root.appendingPathComponent("Sources/Two.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let source = AgentContextExportSource(
            tabID: UUID(),
            promptText: "Review this folder",
            selection: StoredSelection(selectedPaths: [root.path], codemapAutoEnabled: false),
            selectedMetaPromptIDs: [],
            tabName: "Folder Agent Tab",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )

        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )

        XCTAssertEqual(model.rows.map(\.displayPath), ["Sources/One.swift", "Sources/Two.swift"])
        XCTAssertTrue(model.rows.allSatisfy { !$0.canRemove })
    }

    @MainActor
    func testSourceBuilderUsesRequestedInactiveTabInsteadOfActiveSnapshot() {
        let requestedTabID = UUID()
        let activeTabID = UUID()
        let requestedSessionID = UUID()
        let activeSessionID = UUID()
        let requestedSelection = StoredSelection(selectedPaths: ["Sources/Requested.swift"], codemapAutoEnabled: false)
        let activeSelection = StoredSelection(selectedPaths: ["Sources/Active.swift"], codemapAutoEnabled: false)
        let requestedBinding = makeBinding(logicalRoot: URL(fileURLWithPath: "/repo/base"), worktreeRoot: URL(fileURLWithPath: "/repo/worktree"))
        let tabs = [
            ComposeTabState(
                id: requestedTabID,
                name: "Requested",
                activeAgentSessionID: requestedSessionID,
                selection: requestedSelection,
                promptText: "requested prompt"
            ),
            ComposeTabState(
                id: activeTabID,
                name: "Active",
                activeAgentSessionID: activeSessionID,
                selection: activeSelection,
                promptText: "active stored prompt"
            )
        ]
        let activeSnapshot = WorkspaceSelectionCoordinator.Snapshot(
            tabID: activeTabID,
            selection: activeSelection,
            isVirtual: false
        )

        let source = AgentContextExportSourceBuilder.makeSource(
            AgentContextExportSourceBuildRequest(
                requestedTabID: requestedTabID,
                activeComposeTabID: activeTabID,
                activePromptText: "active live prompt",
                selectionSnapshot: activeSnapshot,
                composeTabs: tabs,
                explicitActiveAgentSessionID: nil,
                worktreeBindingsProvider: { sessionID, tabID in
                    sessionID == requestedSessionID && tabID == requestedTabID ? [requestedBinding] : []
                }
            )
        )

        XCTAssertEqual(source.tabID, requestedTabID)
        XCTAssertEqual(source.selection, requestedSelection)
        XCTAssertEqual(source.promptText, "requested prompt")
        XCTAssertEqual(source.activeAgentSessionID, requestedSessionID)
        XCTAssertEqual(source.worktreeBindings, [requestedBinding])
    }

    @MainActor
    func testSourceBuilderUsesRequestedTabSnapshotForInactiveAgentTab() {
        let requestedTabID = UUID()
        let activeTabID = UUID()
        let staleStoredSelection = StoredSelection()
        let coordinatorSelection = StoredSelection(
            selectedPaths: ["Sources/Agent.swift", "Sources/Second.swift"],
            codemapAutoEnabled: false
        )
        let activeSelection = StoredSelection()
        let tabs = [
            ComposeTabState(
                id: requestedTabID,
                name: "Requested",
                selection: staleStoredSelection,
                promptText: "requested prompt"
            ),
            ComposeTabState(
                id: activeTabID,
                name: "Active",
                selection: activeSelection,
                promptText: "active stored prompt"
            )
        ]
        let requestedSnapshot = WorkspaceSelectionCoordinator.Snapshot(
            tabID: requestedTabID,
            selection: coordinatorSelection,
            isVirtual: true
        )

        let source = AgentContextExportSourceBuilder.makeSource(
            AgentContextExportSourceBuildRequest(
                requestedTabID: requestedTabID,
                activeComposeTabID: activeTabID,
                activePromptText: "active live prompt",
                selectionSnapshot: requestedSnapshot,
                composeTabs: tabs,
                explicitActiveAgentSessionID: nil,
                worktreeBindingsProvider: { _, _ in [] }
            )
        )

        XCTAssertEqual(source.tabID, requestedTabID)
        XCTAssertEqual(source.selection, coordinatorSelection)
        XCTAssertEqual(AgentContextExportResolver.explicitSelectionFileCount(source.selection), 2)
        XCTAssertEqual(source.promptText, "requested prompt")
    }

    @MainActor
    func testSourceBuilderUsesActiveSnapshotOnlyForRequestedActiveTab() {
        let activeTabID = UUID()
        let activeSessionID = UUID()
        let storedSelection = StoredSelection(selectedPaths: ["Sources/Stored.swift"], codemapAutoEnabled: false)
        let flushedSelection = StoredSelection(selectedPaths: ["Sources/Flushed.swift"], codemapAutoEnabled: false)
        let tabs = [
            ComposeTabState(
                id: activeTabID,
                name: "Active",
                activeAgentSessionID: activeSessionID,
                selection: storedSelection,
                promptText: "active stored prompt"
            )
        ]
        let activeSnapshot = WorkspaceSelectionCoordinator.Snapshot(
            tabID: activeTabID,
            selection: flushedSelection,
            isVirtual: false
        )

        let source = AgentContextExportSourceBuilder.makeSource(
            AgentContextExportSourceBuildRequest(
                requestedTabID: activeTabID,
                activeComposeTabID: activeTabID,
                activePromptText: "active live prompt",
                selectionSnapshot: activeSnapshot,
                composeTabs: tabs,
                explicitActiveAgentSessionID: nil,
                worktreeBindingsProvider: { _, _ in [] }
            )
        )

        XCTAssertEqual(source.selection, flushedSelection)
        XCTAssertEqual(source.promptText, "active live prompt")
    }

    @MainActor
    func testCurrentManagerPresetIsUsedWithoutStandardSubstitution() {
        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        defer {
            GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false)
        }

        let store = WorkspaceFileContextStore()
        let promptManager = makePrompt(store: store, windowID: 41008)
        let storedPromptID = UUID()
        let storedPrompt = PromptViewModel.StoredPrompt(
            id: storedPromptID,
            title: "Custom instructions",
            content: "Keep this exact stored prompt"
        )
        let customPreset = CopyPreset(
            name: "Manager-only preset",
            description: "Manager-backed configuration outside the Compose base options",
            icon: "shippingbox",
            includeFiles: false,
            includeUserPrompt: true,
            includeMetaPrompts: true,
            includeFileTree: false,
            fileTreeMode: FileTreeOption.none,
            codeMapUsage: .complete,
            gitInclusion: .selected,
            storedPromptIds: [storedPromptID]
        )
        let presetManager = CopyPresetManager.shared
        presetManager.add(customPreset)
        defer { presetManager.remove(id: customPreset.id) }

        promptManager.storedPrompts = [storedPrompt]
        promptManager.selectCopyPreset(customPreset.id)
        let exportContext = AgentContextExportViewContext(
            promptManager: promptManager,
            selectionCoordinator: nil,
            currentTabID: nil,
            activeAgentSessionID: nil,
            worktreeBindingsProvider: nil
        )
        let promptTab = AgentContextDrawerPromptTab(
            promptManager: promptManager,
            modelCoordinator: AgentSelectedFilesModelCoordinator(),
            exportContext: exportContext,
            isSwitchBlankingSelectedFiles: false
        )

        let state = promptTab.makeRenderState()

        XCTAssertEqual(state.selectedPresetID, customPreset.id)
        XCTAssertEqual(state.resolvedConfig.codeMapUsage, .complete)
        XCTAssertEqual(state.resolvedConfig.fileTreeMode, .none)
        XCTAssertEqual(state.resolvedConfig.gitInclusion, .selected)
        XCTAssertEqual(state.selectedPromptIDs, [storedPromptID])
        XCTAssertEqual(state.selectedPrompts.map(\.id), [storedPromptID])
        XCTAssertEqual(state.selectedPrompts.map(\.content), [storedPrompt.content])
        XCTAssertEqual(promptManager.promptSelection(for: .copy), [storedPromptID])
    }

    @MainActor
    func testBuiltInOverrideUsesManagerResolvedConfiguration() {
        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        defer {
            GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false)
        }

        let presetManager = CopyPresetManager.shared
        let presetID = BuiltInCopyPresets.standard.id
        let previousOverride = presetManager.getOverrides(presetID)
        presetManager.upsertOverrides(
            CopyPresetOverrides(
                presetID: presetID,
                includeFiles: false,
                includeFileTree: false,
                fileTreeMode: FileTreeOption.none,
                codeMapUsage: .complete,
                gitInclusion: .complete
            )
        )
        defer {
            if let previousOverride {
                presetManager.upsertOverrides(previousOverride)
            } else {
                presetManager.clearOverrides(for: presetID)
            }
        }

        let store = WorkspaceFileContextStore()
        let promptManager = makePrompt(store: store, windowID: 41009)
        promptManager.selectCopyPreset(presetID)
        let exportContext = AgentContextExportViewContext(
            promptManager: promptManager,
            selectionCoordinator: nil,
            currentTabID: nil,
            activeAgentSessionID: nil,
            worktreeBindingsProvider: nil
        )
        let promptTab = AgentContextDrawerPromptTab(
            promptManager: promptManager,
            modelCoordinator: AgentSelectedFilesModelCoordinator(),
            exportContext: exportContext,
            isSwitchBlankingSelectedFiles: false
        )

        let state = promptTab.makeRenderState()
        let request = exportContext.makeModelRequest(flushPendingUI: false)

        XCTAssertEqual(state.selectedPresetID, presetID)
        XCTAssertFalse(state.resolvedConfig.includeFiles)
        XCTAssertFalse(state.resolvedConfig.includeFileTree)
        XCTAssertEqual(state.resolvedConfig.fileTreeMode, .none)
        XCTAssertEqual(state.resolvedConfig.codeMapUsage, .complete)
        XCTAssertEqual(state.resolvedConfig.gitInclusion, .complete)
        XCTAssertEqual(request.codeMapUsage, .complete)
        XCTAssertEqual(request.identity.codeMapUsage, .complete)
    }

    @MainActor
    func testModelRequestUsesActivePackagingCodemapMode() {
        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        defer {
            GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false)
        }

        let store = WorkspaceFileContextStore()
        let promptManager = makePrompt(store: store, windowID: 41010)
        promptManager.selectCopyPreset(
            BuiltInCopyPresets.manual.id,
            applySettings: false,
            restoreManualSnapshot: false
        )
        let exportContext = AgentContextExportViewContext(
            promptManager: promptManager,
            selectionCoordinator: nil,
            currentTabID: nil,
            activeAgentSessionID: nil,
            worktreeBindingsProvider: nil
        )

        let requests = [CodeMapUsage.none, .complete].map { codeMapUsage in
            promptManager.codeMapUsage = codeMapUsage
            return exportContext.makeModelRequest(flushPendingUI: false)
        }

        XCTAssertEqual(requests.map(\.codeMapUsage), [.none, .complete])
        XCTAssertEqual(requests.map(\.identity.codeMapUsage), [.none, .complete])
        XCTAssertNotEqual(requests[0].identity, requests[1].identity)
    }

    @MainActor
    func testCopyPromptWithModelUsesFreshSourceAndBoundWorktreeLookup() async throws {
        let promptA = "COPY_PROMPT_STALE_BASELINE_A"
        let promptB = "COPY_PROMPT_LIVE_BASELINE_B"
        let root = try makeTemporaryRoot(name: "AgentExportStalePrompt")
        try write("let current = true\n", to: root.appendingPathComponent("Sources/App.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let tabID = UUID()
        let selection = StoredSelection(
            selectedPaths: ["Sources/App.swift"],
            codemapAutoEnabled: false
        )
        let workspace = WorkspaceModel(
            name: "Stale prompt baseline",
            repoPaths: [root.path],
            ephemeralFlag: true,
            composeTabs: [
                ComposeTabState(
                    id: tabID,
                    name: "Copy baseline",
                    selection: selection,
                    promptText: promptA
                )
            ],
            activeComposeTabID: tabID
        )
        let promptManager = makePrompt(store: store, windowID: 41007)
        promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
        let exportContext = AgentContextExportViewContext(
            promptManager: promptManager,
            selectionCoordinator: nil,
            currentTabID: tabID,
            activeAgentSessionID: nil,
            worktreeBindingsProvider: nil
        )
        let model = try await AgentContextExportResolver.resolveModel(
            source: exportContext.makeExportSource(flushPendingUI: false),
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )

        promptManager.promptText = promptB
        let latestSource = exportContext.makeExportSource(flushPendingUI: false)
        XCTAssertEqual(model.source.exportContextIdentity, latestSource.exportContextIdentity)
        XCTAssertEqual(model.source.promptText, promptA)
        XCTAssertEqual(latestSource.promptText, promptB)

        let cfg = makeConfig(gitInclusion: .none)
        for _ in 0 ..< 5 {
            let clipboard = await exportContext.buildClipboardContent(for: cfg, model: model)

            XCTAssertTrue(clipboard.contains(promptB), clipboard)
            XCTAssertFalse(clipboard.contains(promptA), clipboard)
        }

        let worktreeRoot = try makeTemporaryRoot(name: "AgentExportFreshLookup")
        try write("let identity = \"fresh worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/App.swift"))
        let sessionID = UUID()
        let identityMismatchContext = AgentContextExportViewContext(
            promptManager: promptManager,
            selectionCoordinator: nil,
            currentTabID: tabID,
            activeAgentSessionID: sessionID,
            worktreeBindingsProvider: { requestedSessionID, requestedTabID in
                guard requestedSessionID == sessionID, requestedTabID == tabID else { return [] }
                return [self.makeBinding(logicalRoot: root, worktreeRoot: worktreeRoot)]
            }
        )
        let identityMismatchSource = identityMismatchContext.makeExportSource(flushPendingUI: false)
        XCTAssertNotEqual(model.source.exportContextIdentity, identityMismatchSource.exportContextIdentity)

        let identityMismatchClipboard = await identityMismatchContext.buildClipboardContent(for: cfg, model: model)
        XCTAssertTrue(identityMismatchClipboard.contains(promptB), identityMismatchClipboard)
        XCTAssertFalse(identityMismatchClipboard.contains(promptA), identityMismatchClipboard)
        XCTAssertTrue(identityMismatchClipboard.contains("let identity = \"fresh worktree\""), identityMismatchClipboard)
        XCTAssertFalse(identityMismatchClipboard.contains("let current = true"), identityMismatchClipboard)
    }

    @MainActor
    func testClipboardUsesGitStateCapturedBeforeDelayedLookup() async throws {
        let gitFixture = try ReviewGitRepositoryFixture(name: "AgentExportGitSnapshotOriginal")
        let originalRoot = try gitFixture.makeRepository(
            named: "repository",
            files: ["Sources/Original.swift": "let selectedOrigin = \"baseline\"\n"]
        )
        _ = try gitFixture.runGit(["branch", "click-base"], at: originalRoot)
        try gitFixture.write("let selectedOrigin = \"original\"\n", to: "Sources/Original.swift", at: originalRoot)
        try gitFixture.stage("Sources/Original.swift", at: originalRoot)
        try gitFixture.commit("Original selected state", at: originalRoot)
        _ = try gitFixture.runGit(["branch", "later-base"], at: originalRoot)

        let laterRoot = try makeTemporaryRoot(name: "AgentExportGitSnapshotLater")
        try write("let selectedOrigin = \"later\"\n", to: laterRoot.appendingPathComponent("Sources/Later.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: originalRoot.path)
        let tabID = UUID()
        let promptManager = makePrompt(store: store, windowID: 41011)
        promptManager.loadComposeTabsFromWorkspace(
            WorkspaceModel(
                name: "Git click snapshot",
                repoPaths: [originalRoot.path],
                ephemeralFlag: true,
                composeTabs: [
                    ComposeTabState(
                        id: tabID,
                        name: "Git snapshot",
                        selection: StoredSelection(
                            selectedPaths: ["Sources/Original.swift"],
                            codemapAutoEnabled: false
                        ),
                        promptText: "Review original Git state"
                    )
                ],
                activeComposeTabID: tabID
            ),
            syncPromptText: true
        )
        promptManager.gitViewModel.selectedRootFolder = makeFolderViewModel(for: originalRoot)
        promptManager.gitViewModel.selectedDiffBranch = "click-base"

        let lookupStarted = expectation(description: "Clipboard lookup suspended")
        let lookupGate = AgentContextExportLookupGate()
        let exportContext = AgentContextExportViewContext(
            promptManager: promptManager,
            selectionCoordinator: nil,
            currentTabID: tabID,
            activeAgentSessionID: nil,
            worktreeBindingsProvider: nil,
            lookupContextProvider: { _, _ in
                lookupStarted.fulfill()
                await lookupGate.wait()
                return .visibleWorkspace
            }
        )
        let clipboardTask = Task {
            await exportContext.buildClipboardContent(
                for: makeConfig(gitInclusion: .selected),
                model: nil
            )
        }

        await fulfillment(of: [lookupStarted], timeout: 2)
        promptManager.updateComposeTabSelectionPresentation(
            StoredSelection(selectedPaths: ["Sources/Later.swift"], codemapAutoEnabled: false),
            forTabID: tabID
        )
        promptManager.gitViewModel.selectedRootFolder = makeFolderViewModel(for: laterRoot)
        promptManager.gitViewModel.selectedDiffBranch = "later-base"
        await lookupGate.open()

        let clipboard = await clipboardTask.value

        XCTAssertTrue(clipboard.contains("let selectedOrigin = \"original\""), clipboard)
        XCTAssertFalse(clipboard.contains("let selectedOrigin = \"later\""), clipboard)
        XCTAssertTrue(clipboard.contains("<git_diff>"), clipboard)
        XCTAssertTrue(clipboard.contains("-let selectedOrigin = \"baseline\""), clipboard)
        XCTAssertTrue(clipboard.contains("+let selectedOrigin = \"original\""), clipboard)
    }

    @MainActor
    func testCompleteClipboardUsesFrozenMergeBaseThroughDefaultResolver() async throws {
        let gitFixture = try ReviewGitRepositoryFixture(name: "AgentExportCompleteLiveSnapshot")
        let originalRoot = try gitFixture.makeRepository(
            named: "repository",
            files: ["Sources/Original.swift": "let completeOrigin = \"baseline\"\n"]
        )
        _ = try gitFixture.runGit(["branch", "click-base"], at: originalRoot)
        try gitFixture.write("let completeOrigin = \"original\"\n", to: "Sources/Original.swift", at: originalRoot)
        try gitFixture.stage("Sources/Original.swift", at: originalRoot)
        try gitFixture.commit("Original complete state", at: originalRoot)
        _ = try gitFixture.runGit(["branch", "later-base"], at: originalRoot)

        let laterRoot = try makeTemporaryRoot(name: "AgentExportCompleteLiveLater")
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: originalRoot.path)
        let tabID = UUID()
        let promptManager = makePrompt(store: store, windowID: 41013)
        promptManager.loadComposeTabsFromWorkspace(
            WorkspaceModel(
                name: "Complete live Git click snapshot",
                repoPaths: [originalRoot.path],
                ephemeralFlag: true,
                composeTabs: [
                    ComposeTabState(
                        id: tabID,
                        name: "Complete live Git snapshot",
                        selection: StoredSelection(
                            selectedPaths: ["Sources/Original.swift"],
                            codemapAutoEnabled: false
                        ),
                        promptText: "Review complete live Git state"
                    )
                ],
                activeComposeTabID: tabID
            ),
            syncPromptText: true
        )
        promptManager.gitViewModel.selectedRootFolder = makeFolderViewModel(for: originalRoot)
        promptManager.gitViewModel.selectedDiffBranch = "click-base"

        let lookupStarted = expectation(description: "Complete live clipboard lookup suspended")
        let lookupGate = AgentContextExportLookupGate()
        let exportContext = AgentContextExportViewContext(
            promptManager: promptManager,
            selectionCoordinator: nil,
            currentTabID: tabID,
            activeAgentSessionID: nil,
            worktreeBindingsProvider: nil,
            lookupContextProvider: { _, _ in
                lookupStarted.fulfill()
                await lookupGate.wait()
                return .visibleWorkspace
            }
        )
        let clipboardTask = Task {
            await exportContext.buildClipboardContent(
                for: makeConfig(gitInclusion: .complete),
                model: nil
            )
        }

        await fulfillment(of: [lookupStarted], timeout: 2)
        promptManager.gitViewModel.selectedRootFolder = makeFolderViewModel(for: laterRoot)
        promptManager.gitViewModel.selectedDiffBranch = "later-base"
        await lookupGate.open()

        let clipboard = await clipboardTask.value

        XCTAssertTrue(clipboard.contains("<git_diff>"), clipboard)
        XCTAssertTrue(clipboard.contains("-let completeOrigin = \"baseline\""), clipboard)
        XCTAssertTrue(clipboard.contains("+let completeOrigin = \"original\""), clipboard)
    }

    @MainActor
    func testCompleteDiffProviderUsesFrozenRootAndComparison() async throws {
        let originalRoot = try makeTemporaryRoot(name: "AgentExportCompleteSnapshotOriginal")
        let laterRoot = try makeTemporaryRoot(name: "AgentExportCompleteSnapshotLater")
        try write("let completeOrigin = \"original\"\n", to: originalRoot.appendingPathComponent("Sources/Original.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: originalRoot.path)
        let tabID = UUID()
        let promptManager = makePrompt(store: store, windowID: 41012)
        promptManager.loadComposeTabsFromWorkspace(
            WorkspaceModel(
                name: "Complete Git click snapshot",
                repoPaths: [originalRoot.path],
                ephemeralFlag: true,
                composeTabs: [
                    ComposeTabState(
                        id: tabID,
                        name: "Complete Git snapshot",
                        selection: StoredSelection(
                            selectedPaths: ["Sources/Original.swift"],
                            codemapAutoEnabled: false
                        ),
                        promptText: "Review complete Git state"
                    )
                ],
                activeComposeTabID: tabID
            ),
            syncPromptText: true
        )
        promptManager.gitViewModel.selectedRootFolder = makeFolderViewModel(for: originalRoot)
        promptManager.gitViewModel.selectedDiffBranch = "click-base"

        let lookupStarted = expectation(description: "Complete clipboard lookup suspended")
        let lookupGate = AgentContextExportLookupGate()
        let inputRecorder = CompleteGitDiffInputRecorder()
        let exportContext = AgentContextExportViewContext(
            promptManager: promptManager,
            selectionCoordinator: nil,
            currentTabID: tabID,
            activeAgentSessionID: nil,
            worktreeBindingsProvider: nil,
            lookupContextProvider: { _, _ in
                lookupStarted.fulfill()
                await lookupGate.wait()
                return .visibleWorkspace
            },
            completeGitDiffResolver: { rootPath, compareIntent in
                await inputRecorder.resolve(rootPath: rootPath, compareIntent: compareIntent)
            }
        )
        let clipboardTask = Task {
            await exportContext.buildClipboardContent(
                for: makeConfig(gitInclusion: .complete),
                model: nil
            )
        }

        await fulfillment(of: [lookupStarted], timeout: 2)
        promptManager.gitViewModel.selectedRootFolder = makeFolderViewModel(for: laterRoot)
        promptManager.gitViewModel.selectedDiffBranch = "later-base"
        await lookupGate.open()

        let clipboard = await clipboardTask.value
        let inputs = await inputRecorder.recordedInputs()

        XCTAssertEqual(
            inputs,
            [
                CompleteGitDiffInputRecorder.Input(
                    rootPath: originalRoot.path,
                    compareIntent: .uncommittedMergeBase(symbolicBase: "click-base")
                )
            ]
        )
        XCTAssertTrue(clipboard.contains("completeGitSnapshot"), clipboard)
    }

    func testSelectedGitDiffPathsUseBoundWorktreeScope() async throws {
        let fixture = try await makeBoundFixture()
        let source = makeSource(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false)
        )
        let lookupContext = await AgentContextExportResolver.lookupContext(source: source, store: fixture.store)
        let physicalSelection = lookupContext.physicalizeSelection(source.selection)

        let paths = await WorkspaceGitDiffSelectionResolver.selectedGitDiffPaths(
            for: physicalSelection,
            store: fixture.store,
            rootScope: lookupContext.rootScope,
            folderPolicy: .filesOnly,
            profile: .mcpSelection,
            allowFilesystemFallback: lookupContext.rootScope.allowsSelectedGitDiffFilesystemFallback
        )

        XCTAssertEqual(paths, [fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL.path])
        XCTAssertFalse(paths.contains(fixture.logicalRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL.path))
    }

    func testCompleteGitDiffIsGuardedForWorktreeBoundExport() async throws {
        let fixture = try await makeBoundFixture()
        let source = makeSource(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false)
        )
        let lookupContext = await AgentContextExportResolver.lookupContext(source: source, store: fixture.store)

        let clipboard = await AgentContextExportResolver.buildClipboardContent(
            AgentContextClipboardRequest(
                cfg: makeConfig(gitInclusion: .complete),
                source: source,
                store: fixture.store,
                lookupContext: lookupContext,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: true,
                showCodeMapMarkers: true,
                metaInstructions: [],
                includeDatetimeInUserInstructions: false,
                promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
                disabledPromptSections: [],
                duplicateUserInstructionsAtTop: false,
                reviewGitContext: .automaticOnly(),
                completeGitDiffProvider: { "base checkout complete diff must not appear" }
            )
        )

        XCTAssertTrue(clipboard.contains(PromptContextGitDiffPolicy.deferredCompleteWorktreeGitDiffMessage), clipboard)
        XCTAssertFalse(clipboard.contains("base checkout complete diff must not appear"), clipboard)
    }

    func testCompleteGitDiffProviderTextAppearsInClipboard() async throws {
        let root = try makeTemporaryRoot(name: "AgentExportCompleteGitDiff")
        try write("let changed = true\n", to: root.appendingPathComponent("Sources/App.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let source = AgentContextExportSource(
            tabID: UUID(),
            promptText: "Review complete diff",
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false),
            selectedMetaPromptIDs: [],
            tabName: "Agent Tab",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )
        let lookupContext = await AgentContextExportResolver.lookupContext(source: source, store: store)
        let diffText = "diff --git a/Sources/App.swift b/Sources/App.swift\n+let completeGitSentinel = true"
        let provider = CompleteGitDiffProviderSpy(text: diffText)

        let clipboard = await AgentContextExportResolver.buildClipboardContent(
            AgentContextClipboardRequest(
                cfg: makeConfig(gitInclusion: .complete),
                source: source,
                store: store,
                lookupContext: lookupContext,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: true,
                showCodeMapMarkers: true,
                metaInstructions: [],
                includeDatetimeInUserInstructions: false,
                promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
                disabledPromptSections: [],
                duplicateUserInstructionsAtTop: false,
                reviewGitContext: .automaticOnly(),
                completeGitDiffProvider: { await provider.provide() ?? "" }
            )
        )

        let providerInvocationCount = await provider.count()

        XCTAssertTrue(clipboard.contains("<git_diff>"), clipboard)
        XCTAssertTrue(clipboard.contains("completeGitSentinel"), clipboard)
        XCTAssertEqual(providerInvocationCount, 1)
    }

    func testPreviewContentIsPrefixBoundedWhileCopyRemainsFullContent() async throws {
        let root = try makeTemporaryRoot(name: "AgentExportPreviewBound")
        let content = String(repeating: "x", count: AgentContextPreviewContentPolicy.maximumBytes + 2000)
        try write(content, to: root.appendingPathComponent("Sources/Large.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let source = AgentContextExportSource(
            tabID: UUID(),
            promptText: "Review",
            selection: StoredSelection(selectedPaths: ["Sources/Large.swift"], codemapAutoEnabled: false),
            selectedMetaPromptIDs: [],
            tabName: "Agent Tab",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )
        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )
        let row = try XCTUnwrap(model.rows.first)

        let previewResult = await AgentContextExportResolver.loadRowContent(
            for: row,
            model: model,
            store: store,
            purpose: .preview
        )
        let copyResult = await AgentContextExportResolver.loadRowContent(
            for: row,
            model: model,
            store: store,
            purpose: .copy
        )
        let preview = try XCTUnwrap(previewResult)
        let copy = try XCTUnwrap(copyResult)

        XCTAssertLessThan(preview.count, copy.count)
        XCTAssertTrue(preview.contains("Preview truncated"))
        XCTAssertEqual(copy, content)
    }

    func testPreviewContentBelowPrefixLimitUsesCompleteContentWithoutTruncationMarker() async throws {
        let root = try makeTemporaryRoot(name: "AgentExportPreviewSmall")
        let content = String(repeating: "small\n", count: 1000)
        try write(content, to: root.appendingPathComponent("Sources/Small.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let source = AgentContextExportSource(
            tabID: UUID(),
            promptText: "Review",
            selection: StoredSelection(selectedPaths: ["Sources/Small.swift"], codemapAutoEnabled: false),
            selectedMetaPromptIDs: [],
            tabName: "Agent Tab",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )
        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )
        let row = try XCTUnwrap(model.rows.first)

        let previewResult = await AgentContextExportResolver.loadRowContent(
            for: row,
            model: model,
            store: store,
            purpose: .preview
        )
        let copyResult = await AgentContextExportResolver.loadRowContent(
            for: row,
            model: model,
            store: store,
            purpose: .copy
        )

        XCTAssertEqual(previewResult, content)
        XCTAssertEqual(copyResult, content)
        XCTAssertFalse(previewResult?.contains("Preview truncated") ?? true)
    }

    @MainActor
    private func makePrompt(store: WorkspaceFileContextStore, windowID: Int) -> PromptViewModel {
        let secureService = SecureKeysService(secureStorage: TestSecureStorageBackend())
        let keyManager = KeyManager(secureService: secureService)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        return PromptViewModel(
            fileManager: WorkspaceFilesViewModel(workspaceFileContextStore: store),
            apiSettingsViewModel: apiSettings,
            windowID: windowID,
            settingsManager: WindowSettingsManager(windowID: windowID)
        )
    }

    func testEmptyDirectFilePreviewReturnsEmptyContent() async throws {
        let root = try makeTemporaryRoot(name: "AgentExportPreviewEmpty")
        try write("", to: root.appendingPathComponent("Sources/Empty.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let source = AgentContextExportSource(
            tabID: UUID(),
            promptText: "Review",
            selection: StoredSelection(selectedPaths: ["Sources/Empty.swift"], codemapAutoEnabled: false),
            selectedMetaPromptIDs: [],
            tabName: "Agent Tab",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )
        let model = try await AgentContextExportResolver.resolveModel(
            source: source,
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )
        let row = try XCTUnwrap(model.rows.first)

        let previewResult = await AgentContextExportResolver.loadRowContent(
            for: row,
            model: model,
            store: store,
            purpose: .preview
        )
        let copyResult = await AgentContextExportResolver.loadRowContent(
            for: row,
            model: model,
            store: store,
            purpose: .copy
        )

        XCTAssertEqual(previewResult, "")
        XCTAssertEqual(copyResult, "")
    }

    private func makeBoundFixture() async throws -> (logicalRoot: URL, worktreeRoot: URL, store: WorkspaceFileContextStore) {
        let logicalRoot = try makeTemporaryRoot(name: "AgentExportLogical")
        let worktreeRoot = try makeTemporaryRoot(name: "AgentExportWorktree")
        try write("let origin = \"base\"\n", to: logicalRoot.appendingPathComponent("Sources/App.swift"))
        try write("let origin = \"keep\"\n", to: logicalRoot.appendingPathComponent("Sources/Keep.swift"))
        try write("let origin = \"worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/App.swift"))
        try write("let origin = \"keep-worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/Keep.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        return (logicalRoot, worktreeRoot, store)
    }

    private func makeSource(logicalRoot: URL, worktreeRoot: URL, selection: StoredSelection) -> AgentContextExportSource {
        makeSource(
            tabID: UUID(),
            sessionID: UUID(),
            selection: selection,
            bindings: [makeBinding(logicalRoot: logicalRoot, worktreeRoot: worktreeRoot)]
        )
    }

    private func makeSource(
        tabID: UUID,
        sessionID: UUID,
        selection: StoredSelection,
        bindings: [AgentSessionWorktreeBinding]
    ) -> AgentContextExportSource {
        AgentContextExportSource(
            tabID: tabID,
            promptText: "Review this file",
            selection: selection,
            selectedMetaPromptIDs: [],
            tabName: "Agent Tab",
            activeAgentSessionID: sessionID,
            worktreeBindings: bindings
        )
    }

    private func makeBinding(
        logicalRoot: URL,
        worktreeRoot: URL,
        visualLabel: String = "test"
    ) -> AgentSessionWorktreeBinding {
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
            visualLabel: visualLabel,
            visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSinceReferenceDate: 123),
            source: "test"
        )
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

    private func makeIsolatedCodemapStore(name: String) throws -> WorkspaceFileContextStore {
        let runtimeRoot = try makeTemporaryRoot(name: "\(name)-CodemapRuntime")
        guard chmod(runtimeRoot.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let resolvedPath = try runtimeRoot.path.withCString { pointer -> String in
            guard let value = realpath(pointer, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(value) }
            return String(cString: value)
        }
        let registry = WorkspaceCodemapBindingIntegrationRegistry()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: URL(fileURLWithPath: resolvedPath, isDirectory: true),
            bindingIntegrationRegistry: registry,
            bindingEngineFactory: { runtime in
                WorkspaceCodemapBindingEngine(
                    runtime: runtime,
                    capabilityService: WorkspaceCodemapGitCapabilityService(
                        namespaceSalt: Data(
                            repeating: 0x41,
                            count: GitBlobRepositoryNamespace.saltByteCount
                        )
                    ),
                    sourceReader: registry.makeValidatedSourceReaderClient(),
                    catalogClient: registry.makeBindingCatalogClient()
                )
            }
        )
        return WorkspaceFileContextStore(codemapRuntimeProvider: { runtime })
    }

    private func makeFolderViewModel(for root: URL) -> FolderViewModel {
        FolderViewModel(
            folder: Folder(
                name: root.lastPathComponent,
                path: root.path,
                modificationDate: Date(timeIntervalSince1970: 1000)
            ),
            rootPath: root.path,
            isExpanded: true
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        try makeTestDirectory(name: name)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum AgentExportTestError: Error {
    case unexpectedRuntimeAccess
}

private final class AgentExportLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class AgentExportLockedModelRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [AgentContextExportModel] = []

    var values: [AgentContextExportModel] {
        lock.lock()
        defer { lock.unlock() }
        return models
    }

    func append(_ model: AgentContextExportModel) {
        lock.lock()
        models.append(model)
        lock.unlock()
    }
}
