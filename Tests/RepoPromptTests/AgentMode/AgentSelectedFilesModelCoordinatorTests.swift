@testable import RepoPromptApp
import XCTest

final class AgentSelectedFilesModelCoordinatorTests: XCTestCase {
    @MainActor
    func testStableLoadedIdentitySkipsSecondResolve() async {
        let resolver = ImmediateModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let request = makeRequest(name: "A.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        let didLoadInitialModel = await waitUntilModel(promptText: "A.swift", in: coordinator)
        let initialStartCount = await resolver.startCount()
        XCTAssertTrue(didLoadInitialModel)
        XCTAssertEqual(initialStartCount, 1)
        XCTAssertEqual(coordinator.debugStats.resolverStarts, 1)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 1)

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .skippedLoaded)

        let startCountAfterSkip = await resolver.startCount()
        XCTAssertEqual(startCountAfterSkip, 1)
        XCTAssertEqual(coordinator.debugStats.refreshRequests, 2)
        XCTAssertEqual(coordinator.debugStats.skippedLoaded, 1)
        XCTAssertEqual(coordinator.debugStats.resolverStarts, 1)
    }

    @MainActor
    func testTokenMetricsCompletionRefreshPreservesLoadedSameIdentityModel() async {
        let fileID = UUID()
        let resolver = GatedTokenMetricsModelResolver(fileID: fileID)
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let initialRequest = makeRequest(name: "Metrics.swift")
        let enrichedRequest = AgentSelectedFilesModelRequest(
            identity: initialRequest.identity,
            source: initialRequest.source,
            store: initialRequest.store,
            filePathDisplay: initialRequest.filePathDisplay,
            codeMapUsage: initialRequest.codeMapUsage,
            entryMetricsSnapshot: makeMetricsSnapshot(fileID: fileID, name: "Metrics.swift")
        )

        XCTAssertEqual(coordinator.refreshIfNeeded(initialRequest), .started)
        let didStartInitialLoad = await resolver.waitUntilStartCount(1)
        XCTAssertTrue(didStartInitialLoad)
        await resolver.releaseNext()
        let didLoadInitialModel = await waitUntilModel(promptText: "Metrics.swift", in: coordinator)
        XCTAssertTrue(didLoadInitialModel)
        XCTAssertEqual(coordinator.rowSplit.fileRows.first?.metrics, .unknown)

        XCTAssertEqual(coordinator.refreshIfNeeded(enrichedRequest), .skippedLoaded)
        XCTAssertEqual(coordinator.rowSplit.fileRows.first?.metrics, .unknown)

        XCTAssertEqual(coordinator.refreshAfterTokenMetricsCompletion(enrichedRequest), .started)
        let didStartEnrichedRefresh = await resolver.waitUntilStartCount(2)
        XCTAssertTrue(didStartEnrichedRefresh)
        XCTAssertEqual(coordinator.rowSplit.fileRows.first?.metrics, .unknown)
        XCTAssertEqual(coordinator.model?.totalSelectedDisplayTokens, 0)
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertFalse(coordinator.canMutateDisplayedModel)

        await resolver.releaseNext()
        let expectedMetrics = AgentContextExportRow.Metrics.known(
            tokenCount: 91,
            tokenPercentage: 1,
            lineCount: 11
        )
        let didDisplayEnrichedMetrics = await waitUntilDisplayedFileMetrics(
            expectedMetrics,
            promptText: "Metrics.swift",
            in: coordinator
        )
        XCTAssertTrue(didDisplayEnrichedMetrics)
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertEqual(coordinator.model?.totalSelectedDisplayTokens, 91)
        XCTAssertEqual(coordinator.debugStats.resolverStarts, 2)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 2)
    }

    @MainActor
    func testDuplicateRequestWhileLoadingCoalescesIntoOneResolve() async {
        let resolver = GatedModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let request = makeRequest(name: "A.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        let didStartInitialLoad = await resolver.waitUntilStartCount("A.swift", count: 1)
        XCTAssertTrue(didStartInitialLoad)

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .skippedLoading)
        let duplicateStartCount = await resolver.startCount()
        XCTAssertEqual(duplicateStartCount, 1)
        XCTAssertEqual(coordinator.debugStats.skippedLoading, 1)
        XCTAssertEqual(coordinator.debugStats.resolverStarts, 1)

        await resolver.releaseNext("A.swift")
        let didLoadAfterRelease = await waitUntilModel(promptText: "A.swift", in: coordinator)
        XCTAssertTrue(didLoadAfterRelease)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 1)
    }

    @MainActor
    func testAutoCodemapRequestPublishesFileRowsBeforeFullModelCompletes() async {
        func assertProgressiveCodemapRequest(
            name: String,
            codeMapUsage: CodeMapUsage,
            codemapAutoEnabled: Bool = false,
            entryMetricsSnapshot: PromptContextEntryMetricsSnapshot? = nil
        ) async {
            let resolver = ProgressiveCodemapModelResolver()
            let coordinator = AgentSelectedFilesModelCoordinator { request, interimFileRowsHandler in
                await resolver.resolve(request, interimFileRowsHandler: interimFileRowsHandler)
            }
            let request = makeRequest(
                name: name,
                codeMapUsage: codeMapUsage,
                codemapAutoEnabled: codemapAutoEnabled,
                entryMetricsSnapshot: entryMetricsSnapshot
            )

            XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
            let didDisplayFileRows = await waitUntilDisplayedModel(promptText: name, in: coordinator)
            let didStartFullCodemapModel = await resolver.waitUntilStartCount(codeMapUsage, count: 1)

            XCTAssertTrue(didDisplayFileRows)
            XCTAssertTrue(didStartFullCodemapModel)
            XCTAssertTrue(coordinator.isLoading)
            XCTAssertFalse(coordinator.canMutateDisplayedModel)
            XCTAssertEqual(coordinator.rowSplit.fileRows.count, 1)
            XCTAssertEqual(coordinator.rowSplit.codemapRows.count, 0)
            XCTAssertEqual(coordinator.model?.totalSelectedDisplayTokens, 0)
            XCTAssertEqual(coordinator.model?.rows.first?.metrics, .unknown)
            let startedUsages = await resolver.startedUsages()
            XCTAssertEqual(startedUsages, [codeMapUsage])
            let startedMetricsSnapshots = await resolver.startedMetricsSnapshots()
            XCTAssertEqual(startedMetricsSnapshots.count, 1)
            XCTAssertEqual(startedMetricsSnapshots[0], entryMetricsSnapshot)
            let interimPublicationCount = await resolver.interimPublicationCount()
            XCTAssertEqual(interimPublicationCount, 1)

            await resolver.releaseNext(codeMapUsage)
            let didLoadFullModel = await waitUntilModel(promptText: name, in: coordinator)

            XCTAssertTrue(didLoadFullModel)
            XCTAssertFalse(coordinator.isLoading)
            XCTAssertTrue(coordinator.canMutateDisplayedModel)
            XCTAssertEqual(coordinator.debugStats.resolverStarts, 1)
            XCTAssertEqual(coordinator.debugStats.resolverCompletions, 1)
        }

        let providedMetricsSnapshot = PromptContextEntryMetricsSnapshot(
            totalSelectedDisplayTokens: 123,
            metrics: [
                PromptContextEntryMetric(
                    fileID: UUID(),
                    standardizedFullPath: "/tmp/RepoPromptTests/Sources/Provided.swift",
                    renderedDisplayPath: "Sources/Provided.swift",
                    renderMode: .full,
                    displayTokenCount: 123,
                    displayPercentage: 1,
                    includedLineCount: 9
                )
            ]
        )
        let activeTabID = UUID()
        let selectedSource = AgentContextExportSource(
            tabID: activeTabID,
            promptText: "Provided.swift",
            selection: StoredSelection(selectedPaths: ["Sources/Provided.swift"], codemapAutoEnabled: true),
            selectedMetaPromptIDs: [],
            tabName: "Test",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )

        func publishedSnapshot(
            isStale: Bool = false,
            refreshPending: Bool = false,
            codeMapUsage: CodeMapUsage? = .auto
        ) -> TokenCountingViewModel.PublishedTokenSnapshot {
            TokenCountingViewModel.PublishedTokenSnapshot(
                breakdown: TokenCountingViewModel.TokenBreakdown(
                    total: 123,
                    files: 123,
                    prompt: 0,
                    meta: 0,
                    fileTree: 0,
                    git: 0,
                    other: 0
                ),
                filesContentTokens: 123,
                codeMapTokens: 0,
                entryMetricsSnapshot: providedMetricsSnapshot,
                codeMapUsage: codeMapUsage,
                filePathDisplay: .relative,
                isComplete: true,
                isStale: isStale,
                refreshPending: refreshPending || isStale
            )
        }

        XCTAssertEqual(
            AgentSelectedFilesRequestMetricsSnapshotResolver.activeTokenMetricsSnapshot(
                source: selectedSource,
                activeComposeTabID: activeTabID,
                codeMapUsage: .auto,
                filePathDisplay: .relative,
                published: publishedSnapshot()
            ),
            providedMetricsSnapshot
        )
        XCTAssertNil(
            AgentSelectedFilesRequestMetricsSnapshotResolver.activeTokenMetricsSnapshot(
                source: selectedSource,
                activeComposeTabID: activeTabID,
                codeMapUsage: .auto,
                filePathDisplay: .relative,
                published: publishedSnapshot(isStale: true)
            )
        )
        XCTAssertNil(
            AgentSelectedFilesRequestMetricsSnapshotResolver.activeTokenMetricsSnapshot(
                source: selectedSource,
                activeComposeTabID: activeTabID,
                codeMapUsage: .auto,
                filePathDisplay: .relative,
                published: publishedSnapshot(refreshPending: true)
            )
        )
        XCTAssertNil(
            AgentSelectedFilesRequestMetricsSnapshotResolver.activeTokenMetricsSnapshot(
                source: selectedSource,
                activeComposeTabID: activeTabID,
                codeMapUsage: .complete,
                filePathDisplay: .relative,
                published: publishedSnapshot()
            )
        )
        XCTAssertNil(
            AgentSelectedFilesRequestMetricsSnapshotResolver.activeTokenMetricsSnapshot(
                source: AgentContextExportSource(
                    tabID: activeTabID,
                    promptText: "Provided.swift",
                    selection: selectedSource.selection,
                    selectedMetaPromptIDs: [],
                    tabName: "Test",
                    activeAgentSessionID: UUID(),
                    worktreeBindings: []
                ),
                activeComposeTabID: activeTabID,
                codeMapUsage: .auto,
                filePathDisplay: .relative,
                published: publishedSnapshot()
            )
        )

        await assertProgressiveCodemapRequest(name: "Auto.swift", codeMapUsage: .auto, codemapAutoEnabled: true)
        await assertProgressiveCodemapRequest(name: "Complete.swift", codeMapUsage: .complete)
        await assertProgressiveCodemapRequest(
            name: "Provided.swift",
            codeMapUsage: .auto,
            codemapAutoEnabled: true,
            entryMetricsSnapshot: providedMetricsSnapshot
        )
    }

    func testSelectionDisplayTextNamesManualCodemaps() {
        let summary = AgentContextExportResolver.selectionSummary(
            for: StoredSelection(manualCodemapPaths: ["Sources/Codemap.swift"], codemapAutoEnabled: false)
        )

        let text = AgentContextFileCodemapCountSummary.selectionDisplayText(from: summary)

        XCTAssertEqual(summary.totalExplicitFileCount, 1)
        XCTAssertEqual(summary.codemapFileCount, 1)
        XCTAssertEqual(text.compact, "1 codemap")
        XCTAssertEqual(text.detailed, "1 codemap")
    }

    @MainActor
    func testUnresolvedFileCodemapCountReadinessUsesResolutionStability() {
        func unresolvedReadiness(
            codeMapUsage: CodeMapUsage,
            codemapAutoEnabled: Bool = false
        ) -> AgentContextFileCodemapCountReadiness {
            let request = makeRequest(
                name: "\(codeMapUsage.rawValue).swift",
                codeMapUsage: codeMapUsage,
                codemapAutoEnabled: codemapAutoEnabled
            )
            let summary = AgentContextFileCodemapCountSummary.intent(
                from: AgentContextExportResolver.selectionSummary(for: request.source.selection)
            )
            return AgentSelectedFilesModelCoordinator.unresolvedFileCodemapCountReadiness(
                for: request.identity,
                summary: summary
            )
        }

        XCTAssertEqual(
            unresolvedReadiness(codeMapUsage: .selected),
            AgentContextFileCodemapCountReadiness(file: .unknown, codemap: .unknown)
        )
        XCTAssertEqual(
            unresolvedReadiness(codeMapUsage: .complete),
            AgentContextFileCodemapCountReadiness(file: .known(1), codemap: .unknown)
        )
        XCTAssertEqual(
            unresolvedReadiness(codeMapUsage: .auto, codemapAutoEnabled: true),
            AgentContextFileCodemapCountReadiness(file: .known(1), codemap: .unknown)
        )
        XCTAssertEqual(
            unresolvedReadiness(codeMapUsage: .none),
            AgentContextFileCodemapCountReadiness(file: .known(1), codemap: .known(0))
        )

        let manualCodemapSelection = StoredSelection(
            manualCodemapPaths: ["Sources/Codemap.swift"],
            codemapAutoEnabled: false
        )
        let manualCodemapSource = AgentContextExportSource(
            tabID: UUID(),
            promptText: "ManualCodemap.swift",
            selection: manualCodemapSelection,
            selectedMetaPromptIDs: [],
            tabName: "Test",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )
        let manualCodemapIdentity = AgentSelectedFilesModelIdentity(
            exportContextIdentity: manualCodemapSource.exportContextIdentity,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )
        let manualCodemapSummary = AgentContextFileCodemapCountSummary.intent(
            from: AgentContextExportResolver.selectionSummary(for: manualCodemapSelection)
        )

        XCTAssertEqual(
            AgentSelectedFilesModelCoordinator.unresolvedFileCodemapCountReadiness(
                for: manualCodemapIdentity,
                summary: manualCodemapSummary
            ),
            AgentContextFileCodemapCountReadiness(file: .known(0), codemap: .known(0))
        )
    }

    func testRowSplitFileCodemapSummaryUsesMaterializedRows() {
        let rootID = UUID()
        let fullFileRow = AgentContextExportRow(
            id: ResolvedPromptFileEntryID(fileID: UUID(), mode: .fullFile, lineRanges: nil),
            kind: .full,
            rootID: rootID,
            relativePath: "Sources/Full.swift",
            displayPath: "Sources/Full.swift",
            displayName: "Full.swift",
            directoryDisplay: "Sources",
            lineRanges: nil,
            canRemove: true
        )
        let slicedFileRow = AgentContextExportRow(
            id: ResolvedPromptFileEntryID(
                fileID: UUID(),
                mode: .sliced,
                lineRanges: [LineRange(start: 1, end: 2), LineRange(start: 5, end: 6)]
            ),
            kind: .slices,
            rootID: rootID,
            relativePath: "Sources/Sliced.swift",
            displayPath: "Sources/Sliced.swift",
            displayName: "Sliced.swift",
            directoryDisplay: "Sources",
            lineRanges: [LineRange(start: 1, end: 2), LineRange(start: 5, end: 6)],
            canRemove: true
        )
        let codemapRow = AgentContextExportRow(
            id: ResolvedPromptFileEntryID(fileID: UUID(), mode: .codemap, lineRanges: nil),
            kind: .codemap,
            rootID: rootID,
            relativePath: "Sources/Codemap.swift",
            displayPath: "Sources/Codemap.swift",
            displayName: "Codemap.swift",
            directoryDisplay: "Sources",
            lineRanges: nil,
            canRemove: true
        )

        let split = AgentSelectedFilesRowSplit(rows: [fullFileRow, slicedFileRow, codemapRow])

        XCTAssertEqual(split.fileRows.map(\.kind), [.full, .slices])
        XCTAssertEqual(split.codemapRows.map(\.kind), [.codemap])
        XCTAssertEqual(split.fileCodemapCountSummary.fileCount, 2)
        XCTAssertEqual(split.fileCodemapCountSummary.codemapCount, 1)
        XCTAssertEqual(split.fileCodemapCountSummary.sliceRangeCount, 2)
        XCTAssertEqual(split.fileCodemapCountSummary.headlineText, "2 files · 1 codemap · 2 slices")
    }

    @MainActor
    func testLoadedFileCodemapSummaryRequiresMatchingIdentity() async {
        let resolver = ImmediateModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let loadedRequest = makeRequest(name: "Loaded.swift")
        let currentRequest = makeRequest(name: "Current.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(loadedRequest), .started)
        let didLoad = await waitUntilModel(promptText: "Loaded.swift", in: coordinator)
        XCTAssertTrue(didLoad)

        XCTAssertEqual(coordinator.loadedFileCodemapCountSummary(for: loadedRequest.identity)?.fileCount, 1)
        XCTAssertNil(coordinator.loadedFileCodemapCountSummary(for: currentRequest.identity))
    }

    @MainActor
    func testDisplayedCountReadinessReportsInterimUnknownAndCompletedCounts() async {
        let resolver = ProgressiveCodemapModelResolver(finalCodemapCount: 2)
        let coordinator = AgentSelectedFilesModelCoordinator { request, interimFileRowsHandler in
            await resolver.resolve(request, interimFileRowsHandler: interimFileRowsHandler)
        }
        let request = makeRequest(name: "Progressive.swift", codeMapUsage: .auto, codemapAutoEnabled: true)
        let otherRequest = makeRequest(name: "Other.swift", codeMapUsage: .auto, codemapAutoEnabled: true)

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        let didDisplayInterimModel = await waitUntilDisplayedModel(promptText: "Progressive.swift", in: coordinator)
        XCTAssertTrue(didDisplayInterimModel)

        XCTAssertEqual(
            coordinator.displayedFileCodemapCountReadiness(for: request.identity),
            AgentContextFileCodemapCountReadiness(file: .known(1), codemap: .unknown)
        )
        XCTAssertNil(coordinator.displayedFileCodemapCountReadiness(for: otherRequest.identity))

        await resolver.releaseNext(.auto)
        let didLoadCompletedModel = await waitUntilModel(promptText: "Progressive.swift", in: coordinator)
        XCTAssertTrue(didLoadCompletedModel)

        XCTAssertEqual(
            coordinator.displayedFileCodemapCountReadiness(for: request.identity),
            AgentContextFileCodemapCountReadiness(file: .known(1), codemap: .known(2))
        )
    }

    @MainActor
    func testPendingCodemapPromptFilesTransitionPreservesRowsDuringMatchingRefresh() async {
        let resolver = ProgressiveCodemapModelResolver(finalCodemapCount: 2)
        let coordinator = AgentSelectedFilesModelCoordinator { request, interimFileRowsHandler in
            await resolver.resolve(request, interimFileRowsHandler: interimFileRowsHandler)
        }
        let request = makeRequest(
            name: "Transition.swift",
            codeMapUsage: .auto,
            codemapAutoEnabled: true
        )
        let pendingReadiness = AgentContextFileCodemapCountReadiness(file: .known(1), codemap: .unknown)

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        let didDisplayInterimModel = await waitUntilDisplayedModel(
            promptText: "Transition.swift",
            in: coordinator
        )
        XCTAssertTrue(didDisplayInterimModel)
        XCTAssertEqual(coordinator.rowSplit.rows.count, 1)
        XCTAssertEqual(coordinator.displayedFileCodemapCountReadiness(for: request.identity), pendingReadiness)
        XCTAssertTrue(coordinator.displayedModelMatches(request.identity))
        XCTAssertFalse(coordinator.completedModelMatches(request.identity))
        XCTAssertFalse(coordinator.canMutateDisplayedModel)

        // Both Prompt and Files tabs use this cancellation path when transitioning away
        coordinator.cancelLoading(keepLoadedModel: true)
        XCTAssertEqual(coordinator.rowSplit.rows.count, 1)
        XCTAssertEqual(coordinator.displayedFileCodemapCountReadiness(for: request.identity), pendingReadiness)
        XCTAssertTrue(coordinator.displayedModelMatches(request.identity))
        XCTAssertFalse(coordinator.completedModelMatches(request.identity))
        XCTAssertFalse(coordinator.canMutateDisplayedModel)

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        XCTAssertEqual(coordinator.rowSplit.rows.count, 1)
        XCTAssertEqual(coordinator.displayedFileCodemapCountReadiness(for: request.identity), pendingReadiness)
        XCTAssertTrue(coordinator.displayedModelMatches(request.identity))
        XCTAssertFalse(coordinator.completedModelMatches(request.identity))
        XCTAssertFalse(coordinator.canMutateDisplayedModel)

        let didRestartResolution = await resolver.waitUntilStartCount(.auto, count: 2)
        XCTAssertTrue(didRestartResolution)
        let bothResolutionsArePending = await resolver.waitUntilPendingContinuationCount(.auto, count: 2)
        XCTAssertTrue(bothResolutionsArePending)
        await resolver.releaseNext(.auto)
        await resolver.releaseNext(.auto)
        let didLoadCompletedModel = await waitUntilModel(promptText: "Transition.swift", in: coordinator)
        XCTAssertTrue(didLoadCompletedModel)
        XCTAssertEqual(coordinator.rowSplit.rows.count, 3)
        XCTAssertEqual(
            coordinator.displayedFileCodemapCountReadiness(for: request.identity),
            AgentContextFileCodemapCountReadiness(file: .known(1), codemap: .known(2))
        )
        XCTAssertTrue(coordinator.displayedModelMatches(request.identity))
        XCTAssertTrue(coordinator.completedModelMatches(request.identity))
        XCTAssertTrue(coordinator.canMutateDisplayedModel)
    }

    @MainActor
    func testKnownVisibleFileMetricsArePreservedWhileCodemapPending() async {
        let knownMetrics = AgentContextExportRow.Metrics.known(
            tokenCount: 91,
            tokenPercentage: 1,
            lineCount: 11
        )
        let fileID = UUID()
        let resolver = VisibleFileMetricsPreservationResolver(fileID: fileID)
        let coordinator = AgentSelectedFilesModelCoordinator { request, interimFileRowsHandler in
            await resolver.resolve(request, interimFileRowsHandler: interimFileRowsHandler)
        }
        let knownMetricsRequest = makeRequest(
            name: "Metric.swift",
            codeMapUsage: .auto,
            codemapAutoEnabled: true,
            entryMetricsSnapshot: makeMetricsSnapshot(fileID: fileID, name: "Metric.swift")
        )
        let missingMetricsRequest = makeRequest(
            name: "Metric.swift",
            codeMapUsage: .auto,
            codemapAutoEnabled: true,
            entryMetricsSnapshot: nil
        )
        XCTAssertNotEqual(knownMetricsRequest.identity, missingMetricsRequest.identity)

        XCTAssertEqual(coordinator.refreshIfNeeded(knownMetricsRequest), .started)
        let didDisplayKnownMetrics = await waitUntilDisplayedFileMetrics(
            knownMetrics,
            promptText: "Metric.swift",
            in: coordinator
        )
        XCTAssertTrue(didDisplayKnownMetrics)
        XCTAssertEqual(
            coordinator.displayedFileCodemapCountReadiness(for: knownMetricsRequest.identity),
            AgentContextFileCodemapCountReadiness(file: .known(1), codemap: .unknown)
        )

        XCTAssertEqual(coordinator.refreshIfNeeded(missingMetricsRequest, force: true), .started)
        let didPublishSecondInterim = await resolver.waitUntilInterimPublicationCount(2)
        XCTAssertTrue(didPublishSecondInterim)
        XCTAssertEqual(coordinator.rowSplit.fileRows.first?.metrics, knownMetrics)
        XCTAssertEqual(coordinator.rowSplit.fileRows.first?.rootDisplayName, "Metric Root")
        XCTAssertEqual(coordinator.rowSplit.fileRows.first?.rootColorKey, "metric-root")
        XCTAssertEqual(coordinator.rowSplit.fileRows.first?.showRootPill, true)
        XCTAssertEqual(coordinator.model?.totalSelectedDisplayTokens, 91)
        XCTAssertEqual(
            coordinator.displayedFileCodemapCountReadiness(for: missingMetricsRequest.identity),
            AgentContextFileCodemapCountReadiness(file: .known(1), codemap: .unknown)
        )
        await resolver.releaseAll(.auto)
        await drainCancelledTask()
    }

    @MainActor
    func testKnownVisibleFileMetricsAreNotPreservedAcrossDifferentRoots() async {
        let knownMetrics = AgentContextExportRow.Metrics.known(
            tokenCount: 91,
            tokenPercentage: 1,
            lineCount: 11
        )
        let fileID = UUID()
        let resolver = VisibleFileMetricsPreservationResolver(
            fileID: fileID,
            rootIDs: [UUID(), UUID()]
        )
        let coordinator = AgentSelectedFilesModelCoordinator { request, interimFileRowsHandler in
            await resolver.resolve(request, interimFileRowsHandler: interimFileRowsHandler)
        }
        let knownMetricsRequest = makeRequest(
            name: "Metric.swift",
            codeMapUsage: .auto,
            codemapAutoEnabled: true,
            entryMetricsSnapshot: makeMetricsSnapshot(fileID: fileID, name: "Metric.swift")
        )
        let missingMetricsRequest = makeRequest(
            name: "Metric.swift",
            codeMapUsage: .auto,
            codemapAutoEnabled: true,
            entryMetricsSnapshot: nil
        )

        XCTAssertEqual(coordinator.refreshIfNeeded(knownMetricsRequest), .started)
        let didDisplayKnownMetrics = await waitUntilDisplayedFileMetrics(
            knownMetrics,
            promptText: "Metric.swift",
            in: coordinator
        )
        XCTAssertTrue(didDisplayKnownMetrics)

        XCTAssertEqual(coordinator.refreshIfNeeded(missingMetricsRequest, force: true), .started)
        let didPublishSecondInterim = await resolver.waitUntilInterimPublicationCount(2)
        XCTAssertTrue(didPublishSecondInterim)
        XCTAssertEqual(coordinator.rowSplit.fileRows.first?.metrics, .unknown)
        XCTAssertEqual(coordinator.model?.totalSelectedDisplayTokens, 0)

        await resolver.releaseAll(.auto)
        await drainCancelledTask()
    }

    @MainActor
    func testKnownVisibleFileMetricsAreNotPreservedAcrossDifferentFiles() async {
        let knownMetrics = AgentContextExportRow.Metrics.known(
            tokenCount: 91,
            tokenPercentage: 1,
            lineCount: 11
        )
        let firstFileID = UUID()
        let resolver = VisibleFileMetricsPreservationResolver(
            fileID: firstFileID,
            fileIDs: [firstFileID, UUID()]
        )
        let coordinator = AgentSelectedFilesModelCoordinator { request, interimFileRowsHandler in
            await resolver.resolve(request, interimFileRowsHandler: interimFileRowsHandler)
        }
        let knownMetricsRequest = makeRequest(
            name: "Metric.swift",
            codeMapUsage: .auto,
            codemapAutoEnabled: true,
            entryMetricsSnapshot: makeMetricsSnapshot(fileID: firstFileID, name: "Metric.swift")
        )
        let missingMetricsRequest = makeRequest(
            name: "Metric.swift",
            codeMapUsage: .auto,
            codemapAutoEnabled: true,
            entryMetricsSnapshot: nil
        )

        XCTAssertEqual(coordinator.refreshIfNeeded(knownMetricsRequest), .started)
        let didDisplayKnownMetrics = await waitUntilDisplayedFileMetrics(
            knownMetrics,
            promptText: "Metric.swift",
            in: coordinator
        )
        XCTAssertTrue(didDisplayKnownMetrics)

        XCTAssertEqual(coordinator.refreshIfNeeded(missingMetricsRequest, force: true), .started)
        let didPublishSecondInterim = await resolver.waitUntilInterimPublicationCount(2)
        XCTAssertTrue(didPublishSecondInterim)
        XCTAssertEqual(coordinator.rowSplit.fileRows.first?.metrics, .unknown)
        XCTAssertEqual(coordinator.model?.totalSelectedDisplayTokens, 0)

        await resolver.releaseAll(.auto)
        await drainCancelledTask()
    }

    @MainActor
    func testDisplayedCountReadinessUsesCompletedCodemapSnapshotDuringSameIdentityRefresh() async {
        let resolver = ProgressiveCodemapModelResolver(finalCodemapCount: 2)
        let coordinator = AgentSelectedFilesModelCoordinator { request, interimFileRowsHandler in
            await resolver.resolve(request, interimFileRowsHandler: interimFileRowsHandler)
        }
        let request = makeRequest(name: "Stable.swift", codeMapUsage: .auto, codemapAutoEnabled: true)

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        let didStartInitialLoad = await resolver.waitUntilStartCount(.auto, count: 1)
        XCTAssertTrue(didStartInitialLoad)
        await resolver.releaseNext(.auto)
        let didLoadInitialModel = await waitUntilModel(promptText: "Stable.swift", in: coordinator)
        XCTAssertTrue(didLoadInitialModel)
        XCTAssertEqual(coordinator.rowSplit.codemapRows.count, 2)

        XCTAssertEqual(coordinator.refreshIfNeeded(request, force: true, preserveDisplayedModel: true), .started)
        let didStartRefresh = await resolver.waitUntilStartCount(.auto, count: 2)
        let didPublishInterimFileRows = await waitUntilFileOnlyLoading(promptText: "Stable.swift", in: coordinator)
        XCTAssertTrue(didStartRefresh)
        XCTAssertTrue(didPublishInterimFileRows)
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertEqual(coordinator.rowSplit.fileRows.count, 1)
        XCTAssertEqual(coordinator.rowSplit.codemapRows.count, 0)
        XCTAssertEqual(
            coordinator.displayedFileCodemapCountReadiness(for: request.identity),
            AgentContextFileCodemapCountReadiness(file: .known(1), codemap: .known(2))
        )

        await resolver.releaseNext(.auto)
        let didReloadCompletedModel = await waitUntilModel(promptText: "Stable.swift", in: coordinator)
        XCTAssertTrue(didReloadCompletedModel)
        XCTAssertEqual(
            coordinator.displayedFileCodemapCountReadiness(for: request.identity),
            AgentContextFileCodemapCountReadiness(file: .known(1), codemap: .known(2))
        )
    }

    @MainActor
    func testNonPreservedIdentityChangeClearsDisplayedRowsWhileLoading() async {
        let resolver = GatedModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let loadedRequest = makeRequest(name: "Loaded.swift")
        let currentRequest = makeRequest(name: "Current.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(loadedRequest), .started)
        let didStartLoaded = await resolver.waitUntilStartCount("Loaded.swift", count: 1)
        XCTAssertTrue(didStartLoaded)
        await resolver.releaseNext("Loaded.swift")
        let didLoad = await waitUntilModel(promptText: "Loaded.swift", in: coordinator)
        XCTAssertTrue(didLoad)
        XCTAssertEqual(coordinator.rowSplit.rows.count, 1)
        XCTAssertTrue(coordinator.displayedModelMatches(loadedRequest.identity))
        XCTAssertTrue(coordinator.completedModelMatches(loadedRequest.identity))

        XCTAssertEqual(coordinator.refreshIfNeeded(currentRequest), .started)

        XCTAssertNil(coordinator.model)
        XCTAssertTrue(coordinator.rowSplit.rows.isEmpty)
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertFalse(coordinator.canMutateDisplayedModel)
        XCTAssertFalse(coordinator.displayedModelMatches(loadedRequest.identity))
        XCTAssertFalse(coordinator.displayedModelMatches(currentRequest.identity))
        XCTAssertFalse(coordinator.completedModelMatches(loadedRequest.identity))
        XCTAssertFalse(coordinator.completedModelMatches(currentRequest.identity))

        let didStartCurrent = await resolver.waitUntilStartCount("Current.swift", count: 1)
        XCTAssertTrue(didStartCurrent)
        await resolver.releaseNext("Current.swift")
        let didLoadCurrent = await waitUntilModel(promptText: "Current.swift", in: coordinator)
        XCTAssertTrue(didLoadCurrent)
    }

    @MainActor
    func testPreservedSameIdentityRefreshKeepsDisplayedRowsWithoutMutation() async {
        let resolver = GatedModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let request = makeRequest(name: "Stable.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        let didStartInitialLoad = await resolver.waitUntilStartCount("Stable.swift", count: 1)
        XCTAssertTrue(didStartInitialLoad)
        await resolver.releaseNext("Stable.swift")
        let didLoad = await waitUntilModel(promptText: "Stable.swift", in: coordinator)
        XCTAssertTrue(didLoad)
        XCTAssertEqual(coordinator.model?.source.promptText, "Stable.swift")
        XCTAssertTrue(coordinator.canMutateDisplayedModel)

        XCTAssertEqual(coordinator.refreshIfNeeded(request, force: true, preserveDisplayedModel: true), .started)
        let didStartRefresh = await resolver.waitUntilStartCount("Stable.swift", count: 2)
        XCTAssertTrue(didStartRefresh)

        XCTAssertEqual(coordinator.model?.source.promptText, "Stable.swift")
        XCTAssertEqual(coordinator.rowSplit.rows.count, 1)
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertFalse(coordinator.canMutateDisplayedModel)
        XCTAssertTrue(coordinator.displayedModelMatches(request.identity))
        XCTAssertFalse(coordinator.completedModelMatches(request.identity))

        await resolver.releaseNext("Stable.swift")
        let didReload = await waitUntilModel(promptText: "Stable.swift", in: coordinator)
        XCTAssertTrue(didReload)
    }

    @MainActor
    func testDisplayedModelMatchesUsesFullIdentityDuringPreservedRefresh() async {
        let resolver = GatedModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let loadedRequest = makeRequest(name: "Shared.swift", codeMapUsage: .none)
        let currentRequest = AgentSelectedFilesModelRequest(
            identity: AgentSelectedFilesModelIdentity(
                exportContextIdentity: loadedRequest.source.exportContextIdentity,
                filePathDisplay: loadedRequest.filePathDisplay,
                codeMapUsage: .selected
            ),
            source: loadedRequest.source,
            store: WorkspaceFileContextStore(),
            filePathDisplay: loadedRequest.filePathDisplay,
            codeMapUsage: .selected,
            entryMetricsSnapshot: nil
        )

        XCTAssertEqual(coordinator.refreshIfNeeded(loadedRequest), .started)
        let didStartInitialLoad = await resolver.waitUntilStartCount("Shared.swift", count: 1)
        XCTAssertTrue(didStartInitialLoad)
        await resolver.releaseNext("Shared.swift")
        let didLoadInitialModel = await waitUntilModel(promptText: "Shared.swift", in: coordinator)
        XCTAssertTrue(didLoadInitialModel)
        XCTAssertTrue(coordinator.displayedModelMatches(loadedRequest.identity))
        XCTAssertFalse(coordinator.displayedModelMatches(currentRequest.identity))

        XCTAssertEqual(coordinator.refreshIfNeeded(currentRequest, preserveDisplayedModel: true), .started)
        let didStartPreservedRefresh = await resolver.waitUntilStartCount("Shared.swift", count: 2)
        XCTAssertTrue(didStartPreservedRefresh)

        XCTAssertEqual(coordinator.model?.source.promptText, "Shared.swift")
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertFalse(coordinator.canMutateDisplayedModel)
        XCTAssertTrue(coordinator.displayedModelMatches(loadedRequest.identity))
        XCTAssertFalse(coordinator.displayedModelMatches(currentRequest.identity))
        XCTAssertFalse(coordinator.completedModelMatches(loadedRequest.identity))
        XCTAssertFalse(coordinator.completedModelMatches(currentRequest.identity))

        await resolver.releaseNext("Shared.swift")
        let didLoadCurrentModel = await waitUntilModel(promptText: "Shared.swift", in: coordinator)
        XCTAssertTrue(didLoadCurrentModel)
        XCTAssertFalse(coordinator.displayedModelMatches(loadedRequest.identity))
        XCTAssertTrue(coordinator.displayedModelMatches(currentRequest.identity))
        XCTAssertTrue(coordinator.completedModelMatches(currentRequest.identity))
    }

    @MainActor
    func testIdentityHelpersDistinguishInterimDisplayedModelFromCompletedModel() async {
        let resolver = ProgressiveCodemapModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request, interimFileRowsHandler in
            await resolver.resolve(request, interimFileRowsHandler: interimFileRowsHandler)
        }
        let loadedRequest = makeRequest(name: "Loaded.swift")
        let request = makeRequest(name: "Progressive.swift", codeMapUsage: .complete)

        XCTAssertEqual(coordinator.refreshIfNeeded(loadedRequest), .started)
        let didLoadInitialModel = await waitUntilModel(promptText: "Loaded.swift", in: coordinator)
        XCTAssertTrue(didLoadInitialModel)
        XCTAssertTrue(coordinator.displayedModelMatches(loadedRequest.identity))
        XCTAssertTrue(coordinator.completedModelMatches(loadedRequest.identity))

        XCTAssertEqual(coordinator.refreshIfNeeded(request, preserveDisplayedModel: true), .started)
        let didDisplayInterimModel = await waitUntilDisplayedModel(promptText: "Progressive.swift", in: coordinator)
        XCTAssertTrue(didDisplayInterimModel)
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertFalse(coordinator.canMutateDisplayedModel)
        XCTAssertFalse(coordinator.displayedModelMatches(loadedRequest.identity))
        XCTAssertFalse(coordinator.completedModelMatches(loadedRequest.identity))
        XCTAssertTrue(coordinator.displayedModelMatches(request.identity))
        XCTAssertFalse(coordinator.completedModelMatches(request.identity))

        await resolver.releaseNext(.complete)
        let didLoadCompletedModel = await waitUntilModel(promptText: "Progressive.swift", in: coordinator)
        XCTAssertTrue(didLoadCompletedModel)
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertTrue(coordinator.canMutateDisplayedModel)
        XCTAssertTrue(coordinator.displayedModelMatches(request.identity))
        XCTAssertTrue(coordinator.completedModelMatches(request.identity))
    }

    @MainActor
    func testCancelLoadingWithoutKeepingLoadedModelRetainsCachedModels() async {
        let resolver = ImmediateModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let cachedRequest = makeRequest(name: "Cached.swift")
        let displayedRequest = makeRequest(name: "Displayed.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(cachedRequest), .started)
        let didLoadCached = await waitUntilModel(promptText: "Cached.swift", in: coordinator)
        XCTAssertTrue(didLoadCached)
        XCTAssertEqual(coordinator.refreshIfNeeded(displayedRequest), .started)
        let didLoadDisplayed = await waitUntilModel(promptText: "Displayed.swift", in: coordinator)
        let startCountAfterLoads = await resolver.startCount()
        XCTAssertTrue(didLoadDisplayed)
        XCTAssertEqual(startCountAfterLoads, 2)

        coordinator.cancelLoading(keepLoadedModel: false)
        XCTAssertNil(coordinator.model)
        XCTAssertTrue(coordinator.rowSplit.rows.isEmpty)
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertFalse(coordinator.displayedModelMatches(cachedRequest.identity))
        XCTAssertFalse(coordinator.completedModelMatches(cachedRequest.identity))

        XCTAssertEqual(coordinator.refreshIfNeeded(cachedRequest), .skippedLoaded)

        let finalStartCount = await resolver.startCount()
        XCTAssertEqual(finalStartCount, 2)
        XCTAssertEqual(coordinator.model?.source.promptText, "Cached.swift")
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertTrue(coordinator.canMutateDisplayedModel)
        XCTAssertTrue(coordinator.displayedModelMatches(cachedRequest.identity))
        XCTAssertTrue(coordinator.completedModelMatches(cachedRequest.identity))
    }

    @MainActor
    func testForceRefreshAfterClearingDisplayedModelBypassesCachedIdentity() async {
        let resolver = GatedModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let request = makeRequest(name: "SameIdentity.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        let didStartInitialLoad = await resolver.waitUntilStartCount("SameIdentity.swift", count: 1)
        XCTAssertTrue(didStartInitialLoad)
        await resolver.releaseNext("SameIdentity.swift")
        let didLoadInitialModel = await waitUntilModel(promptText: "SameIdentity.swift", in: coordinator)
        XCTAssertTrue(didLoadInitialModel)

        coordinator.cancelLoading(keepLoadedModel: false)
        XCTAssertNil(coordinator.model)
        XCTAssertTrue(coordinator.rowSplit.rows.isEmpty)
        XCTAssertFalse(coordinator.displayedModelMatches(request.identity))

        XCTAssertEqual(coordinator.refreshIfNeeded(request, force: true), .started)
        let didStartForcedReload = await resolver.waitUntilStartCount("SameIdentity.swift", count: 2)
        let startCountBeforeRelease = await resolver.startCount()
        XCTAssertTrue(didStartForcedReload)
        XCTAssertEqual(startCountBeforeRelease, 2)
        XCTAssertNil(coordinator.model)
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertFalse(coordinator.displayedModelMatches(request.identity))

        await resolver.releaseNext("SameIdentity.swift")
        let didLoadForcedModel = await waitUntilModel(promptText: "SameIdentity.swift", in: coordinator)
        XCTAssertTrue(didLoadForcedModel)
        XCTAssertTrue(coordinator.displayedModelMatches(request.identity))
        XCTAssertTrue(coordinator.completedModelMatches(request.identity))
    }

    @MainActor
    func testCancelledGenerationPublishesCachesAndCompletesNothingWhileReplacementLoads() async {
        let resolver = CancellableGatedModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator {
            (request: AgentSelectedFilesModelRequest) async throws(CancellationError) in
            try await resolver.resolve(request)
        }
        let requestA = makeRequest(name: "A.swift")
        let requestB = makeRequest(name: "B.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(requestA), .started)
        let didStartA = await resolver.waitUntilStartCount("A.swift", count: 1)
        XCTAssertTrue(didStartA)

        XCTAssertEqual(coordinator.refreshIfNeeded(requestB), .started)
        let didStartB = await resolver.waitUntilStartCount("B.swift", count: 1)
        let changedIdentityStartCount = await resolver.startCount()
        XCTAssertTrue(didStartB)
        XCTAssertEqual(changedIdentityStartCount, 2)
        XCTAssertEqual(coordinator.debugStats.cancellations, 1)

        await resolver.releaseNext("A.swift")
        await drainCancelledTask()
        XCTAssertNil(coordinator.model)
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 0)

        await resolver.releaseNext("B.swift")
        let didLoadNewestModel = await waitUntilModel(promptText: "B.swift", in: coordinator)
        XCTAssertTrue(didLoadNewestModel)
        XCTAssertEqual(coordinator.model?.source.promptText, "B.swift")
        XCTAssertEqual(coordinator.debugStats.resolverStarts, 2)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 1)

        XCTAssertEqual(coordinator.refreshIfNeeded(requestA), .started)
        let didStartAAgain = await resolver.waitUntilStartCount("A.swift", count: 2)
        XCTAssertTrue(didStartAAgain)
        coordinator.cancelLoading(keepLoadedModel: false)
        await resolver.releaseNext("A.swift")
        await drainCancelledTask()
    }

    @MainActor
    func testRecentlyLoadedDifferentIdentityRestoresFromCacheWithoutResolving() async {
        let resolver = ImmediateModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let requestA = makeRequest(name: "A.swift")
        let requestB = makeRequest(name: "B.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(requestA), .started)
        let didLoadA = await waitUntilModel(promptText: "A.swift", in: coordinator)
        XCTAssertTrue(didLoadA)
        XCTAssertEqual(coordinator.refreshIfNeeded(requestB), .started)
        let didLoadB = await waitUntilModel(promptText: "B.swift", in: coordinator)
        let startCountAfterTwoLoads = await resolver.startCount()
        XCTAssertTrue(didLoadB)
        XCTAssertEqual(startCountAfterTwoLoads, 2)

        XCTAssertEqual(coordinator.refreshIfNeeded(requestA), .skippedLoaded)

        let finalStartCount = await resolver.startCount()
        XCTAssertEqual(coordinator.model?.source.promptText, "A.swift")
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertEqual(finalStartCount, 2)
        XCTAssertEqual(coordinator.debugStats.skippedLoaded, 1)
    }

    @MainActor
    func testCachedIdentityCancelsDifferentInFlightResolve() async {
        let resolver = GatedModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let requestA = makeRequest(name: "A.swift")
        let requestB = makeRequest(name: "B.swift")
        let requestC = makeRequest(name: "C.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(requestB), .started)
        let didStartB = await resolver.waitUntilStartCount("B.swift", count: 1)
        XCTAssertTrue(didStartB)
        await resolver.releaseNext("B.swift")
        let didLoadB = await waitUntilModel(promptText: "B.swift", in: coordinator)
        XCTAssertTrue(didLoadB)

        XCTAssertEqual(coordinator.refreshIfNeeded(requestC), .started)
        let didStartC = await resolver.waitUntilStartCount("C.swift", count: 1)
        XCTAssertTrue(didStartC)
        await resolver.releaseNext("C.swift")
        let didLoadC = await waitUntilModel(promptText: "C.swift", in: coordinator)
        XCTAssertTrue(didLoadC)

        XCTAssertEqual(coordinator.refreshIfNeeded(requestA, preserveDisplayedModel: true), .started)
        let didStartA = await resolver.waitUntilStartCount("A.swift", count: 1)
        XCTAssertTrue(didStartA)
        XCTAssertEqual(coordinator.model?.source.promptText, "C.swift")
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertFalse(coordinator.canMutateDisplayedModel)

        XCTAssertEqual(coordinator.refreshIfNeeded(requestB), .skippedLoaded)
        XCTAssertEqual(coordinator.model?.source.promptText, "B.swift")
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertTrue(coordinator.canMutateDisplayedModel)
        XCTAssertEqual(coordinator.debugStats.cancellations, 1)

        await resolver.releaseNext("A.swift")
        await drainCancelledTask()

        XCTAssertEqual(coordinator.model?.source.promptText, "B.swift")
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertTrue(coordinator.canMutateDisplayedModel)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 2)
    }

    @MainActor
    func testPreservedDisplayedModelCannotMutateWhileNewIdentityLoads() async {
        let resolver = GatedModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let requestA = makeRequest(name: "A.swift")
        let requestB = makeRequest(name: "B.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(requestA), .started)
        let didStartA = await resolver.waitUntilStartCount("A.swift", count: 1)
        XCTAssertTrue(didStartA)
        await resolver.releaseNext("A.swift")
        let didLoadA = await waitUntilModel(promptText: "A.swift", in: coordinator)
        XCTAssertTrue(didLoadA)
        XCTAssertTrue(coordinator.canMutateDisplayedModel)

        XCTAssertEqual(coordinator.refreshIfNeeded(requestB, preserveDisplayedModel: true), .started)
        let didStartB = await resolver.waitUntilStartCount("B.swift", count: 1)
        XCTAssertTrue(didStartB)
        XCTAssertEqual(coordinator.model?.source.promptText, "A.swift")
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertFalse(coordinator.canMutateDisplayedModel)

        await resolver.releaseNext("B.swift")
        let didLoadB = await waitUntilModel(promptText: "B.swift", in: coordinator)
        XCTAssertTrue(didLoadB)
        XCTAssertTrue(coordinator.canMutateDisplayedModel)
    }

    @MainActor
    func testLoadedIdentityCancelsDifferentInFlightResolveWhenPreservingDisplayedModel() async {
        let resolver = GatedModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let requestA = makeRequest(name: "A.swift")
        let requestB = makeRequest(name: "B.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(requestB), .started)
        let didStartB = await resolver.waitUntilStartCount("B.swift", count: 1)
        XCTAssertTrue(didStartB)
        await resolver.releaseNext("B.swift")
        let didLoadB = await waitUntilModel(promptText: "B.swift", in: coordinator)
        XCTAssertTrue(didLoadB)

        XCTAssertEqual(coordinator.refreshIfNeeded(requestA, preserveDisplayedModel: true), .started)
        let didStartA = await resolver.waitUntilStartCount("A.swift", count: 1)
        XCTAssertTrue(didStartA)
        XCTAssertEqual(coordinator.model?.source.promptText, "B.swift")
        XCTAssertTrue(coordinator.isLoading)

        XCTAssertEqual(coordinator.refreshIfNeeded(requestB), .skippedLoaded)
        XCTAssertEqual(coordinator.model?.source.promptText, "B.swift")
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertEqual(coordinator.debugStats.cancellations, 1)

        await resolver.releaseNext("A.swift")
        await drainCancelledTask()

        XCTAssertEqual(coordinator.model?.source.promptText, "B.swift")
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 1)
    }

    @MainActor
    func testInvalidateWithoutRefreshClearsLoadedRowsAndStartsNoResolverWork() async {
        let resolver = ImmediateModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let request = makeRequest(name: "A.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        let didLoad = await waitUntilModel(promptText: "A.swift", in: coordinator)
        XCTAssertTrue(didLoad)
        XCTAssertEqual(coordinator.rowSplit.rows.count, 1)

        coordinator.invalidate()

        let startCountAfterInvalidate = await resolver.startCount()
        XCTAssertEqual(startCountAfterInvalidate, 1)
        XCTAssertEqual(coordinator.debugStats.refreshRequests, 1)
        XCTAssertEqual(coordinator.debugStats.resolverStarts, 1)
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertNil(coordinator.model)
        XCTAssertTrue(coordinator.rowSplit.rows.isEmpty)
    }

    @MainActor
    func testForceRefreshLoadedSameIdentityStartsOneAdditionalResolve() async {
        let resolver = ImmediateModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let request = makeRequest(name: "A.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        let didLoadInitialModel = await waitUntilModel(promptText: "A.swift", in: coordinator)
        XCTAssertTrue(didLoadInitialModel)

        XCTAssertEqual(coordinator.refreshIfNeeded(request, force: true), .started)
        let didReloadModel = await waitUntilModel(promptText: "A.swift", in: coordinator)
        let startCount = await resolver.startCount()
        XCTAssertTrue(didReloadModel)
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(coordinator.debugStats.resolverStarts, 2)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 2)
    }

    @MainActor
    func testForceRefreshWhileSameIdentityIsLoadingAcceptsNewestGenerationOnly() async {
        let resolver = GatedModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let request = makeRequest(name: "A.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        let didStartFirst = await resolver.waitUntilStartCount("A.swift", count: 1)
        XCTAssertTrue(didStartFirst)

        XCTAssertEqual(coordinator.refreshIfNeeded(request, force: true), .started)
        let didStartSecond = await resolver.waitUntilStartCount("A.swift", count: 2)
        let startCount = await resolver.startCount()
        XCTAssertTrue(didStartSecond)
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(coordinator.debugStats.cancellations, 1)

        await resolver.releaseNext("A.swift")
        await drainCancelledTask()
        XCTAssertNil(coordinator.model)
        XCTAssertTrue(coordinator.isLoading)

        await resolver.releaseNext("A.swift")
        let didLoadNewestGeneration = await waitUntilModel(promptText: "A.swift", in: coordinator)
        XCTAssertTrue(didLoadNewestGeneration)
        XCTAssertEqual(coordinator.debugStats.resolverStarts, 2)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 1)
    }

    @MainActor
    func testCancelLoadingRejectsLateResolverResult() async {
        let resolver = GatedModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let request = makeRequest(name: "A.swift")

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        let didStart = await resolver.waitUntilStartCount("A.swift", count: 1)
        XCTAssertTrue(didStart)

        coordinator.cancelLoading(keepLoadedModel: false)
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertNil(coordinator.model)
        XCTAssertTrue(coordinator.rowSplit.rows.isEmpty)
        XCTAssertEqual(coordinator.debugStats.cancellations, 1)

        await resolver.releaseNext("A.swift")
        await drainCancelledTask()

        XCTAssertFalse(coordinator.isLoading)
        XCTAssertNil(coordinator.model)
        XCTAssertTrue(coordinator.rowSplit.rows.isEmpty)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 0)
    }

    @MainActor
    private func waitUntilModel(
        promptText: String,
        in coordinator: AgentSelectedFilesModelCoordinator
    ) async -> Bool {
        for _ in 0 ..< 500 {
            if coordinator.model?.source.promptText == promptText, !coordinator.isLoading { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return coordinator.model?.source.promptText == promptText && !coordinator.isLoading
    }

    @MainActor
    private func waitUntilDisplayedModel(
        promptText: String,
        in coordinator: AgentSelectedFilesModelCoordinator
    ) async -> Bool {
        for _ in 0 ..< 500 {
            if coordinator.model?.source.promptText == promptText { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return coordinator.model?.source.promptText == promptText
    }

    @MainActor
    private func waitUntilFileOnlyLoading(
        promptText: String,
        in coordinator: AgentSelectedFilesModelCoordinator
    ) async -> Bool {
        for _ in 0 ..< 500 {
            if coordinator.model?.source.promptText == promptText,
               coordinator.isLoading,
               coordinator.rowSplit.fileRows.count == 1,
               coordinator.rowSplit.codemapRows.isEmpty
            {
                return true
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return coordinator.model?.source.promptText == promptText
            && coordinator.isLoading
            && coordinator.rowSplit.fileRows.count == 1
            && coordinator.rowSplit.codemapRows.isEmpty
    }

    @MainActor
    private func waitUntilDisplayedFileMetrics(
        _ metrics: AgentContextExportRow.Metrics,
        promptText: String,
        in coordinator: AgentSelectedFilesModelCoordinator
    ) async -> Bool {
        for _ in 0 ..< 500 {
            if coordinator.model?.source.promptText == promptText,
               coordinator.rowSplit.fileRows.first?.metrics == metrics
            {
                return true
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return coordinator.model?.source.promptText == promptText
            && coordinator.rowSplit.fileRows.first?.metrics == metrics
    }

    private func makeRequest(
        name: String,
        codeMapUsage: CodeMapUsage = .none,
        codemapAutoEnabled: Bool = false,
        entryMetricsSnapshot: PromptContextEntryMetricsSnapshot? = nil
    ) -> AgentSelectedFilesModelRequest {
        let source = AgentContextExportSource(
            tabID: UUID(),
            promptText: name,
            selection: StoredSelection(selectedPaths: ["Sources/\(name)"], codemapAutoEnabled: codemapAutoEnabled),
            selectedMetaPromptIDs: [],
            tabName: "Test",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )
        return AgentSelectedFilesModelRequest(
            identity: AgentSelectedFilesModelIdentity(
                exportContextIdentity: source.exportContextIdentity,
                filePathDisplay: .relative,
                codeMapUsage: codeMapUsage
            ),
            source: source,
            store: WorkspaceFileContextStore(),
            filePathDisplay: .relative,
            codeMapUsage: codeMapUsage,
            entryMetricsSnapshot: entryMetricsSnapshot
        )
    }

    private func makeMetricsSnapshot(fileID: UUID, name: String) -> PromptContextEntryMetricsSnapshot {
        PromptContextEntryMetricsSnapshot(
            totalSelectedDisplayTokens: 91,
            metrics: [
                PromptContextEntryMetric(
                    fileID: fileID,
                    standardizedFullPath: "/tmp/RepoPromptTests/Sources/\(name)",
                    renderedDisplayPath: "Sources/\(name)",
                    renderMode: .full,
                    displayTokenCount: 91,
                    displayPercentage: 1,
                    includedLineCount: 11
                )
            ]
        )
    }

    private func drainCancelledTask() async {
        for _ in 0 ..< 10 {
            await Task.yield()
        }
    }
}

private actor ImmediateModelResolver {
    private var starts = 0

    func resolve(_ request: AgentSelectedFilesModelRequest) async -> AgentContextExportModel {
        starts += 1
        return makeModel(for: request)
    }

    func startCount() -> Int {
        starts
    }
}

private actor GatedModelResolver {
    private var starts = 0
    private var startedCounts: [String: Int] = [:]
    private var continuations: [String: [CheckedContinuation<Void, Never>]] = [:]

    func resolve(_ request: AgentSelectedFilesModelRequest) async -> AgentContextExportModel {
        starts += 1
        let key = request.source.promptText
        await withCheckedContinuation { continuation in
            continuations[key, default: []].append(continuation)
            startedCounts[key, default: 0] += 1
        }
        return makeModel(for: request)
    }

    func waitUntilStartCount(_ key: String, count: Int) async -> Bool {
        for _ in 0 ..< 500 {
            if startedCounts[key, default: 0] >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return startedCounts[key, default: 0] >= count
    }

    func releaseNext(_ key: String) {
        guard var queued = continuations[key], !queued.isEmpty else { return }
        let continuation = queued.removeFirst()
        continuations[key] = queued
        continuation.resume()
    }

    func startCount() -> Int {
        starts
    }
}

private actor CancellableGatedModelResolver {
    private var starts = 0
    private var startedCounts: [String: Int] = [:]
    private var continuations: [String: [CheckedContinuation<Void, Never>]] = [:]

    func resolve(
        _ request: AgentSelectedFilesModelRequest
    ) async throws(CancellationError) -> AgentContextExportModel {
        starts += 1
        let key = request.source.promptText
        await withCheckedContinuation { continuation in
            continuations[key, default: []].append(continuation)
            startedCounts[key, default: 0] += 1
        }
        guard !Task.isCancelled else { throw CancellationError() }
        return makeModel(for: request)
    }

    func waitUntilStartCount(_ key: String, count: Int) async -> Bool {
        for _ in 0 ..< 500 {
            if startedCounts[key, default: 0] >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return startedCounts[key, default: 0] >= count
    }

    func releaseNext(_ key: String) {
        guard var queued = continuations[key], !queued.isEmpty else { return }
        let continuation = queued.removeFirst()
        continuations[key] = queued
        continuation.resume()
    }

    func startCount() -> Int {
        starts
    }
}

private actor GatedTokenMetricsModelResolver {
    private let fileID: UUID
    private let rootID = UUID()
    private var starts = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(fileID: UUID) {
        self.fileID = fileID
    }

    func resolve(_ request: AgentSelectedFilesModelRequest) async -> AgentContextExportModel {
        starts += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        return makeVisibleFileMetricsModel(for: request, fileID: fileID, rootID: rootID)
    }

    func waitUntilStartCount(_ count: Int) async -> Bool {
        for _ in 0 ..< 500 {
            if starts >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return starts >= count
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor ProgressiveCodemapModelResolver {
    private let finalCodemapCount: Int
    private var usages: [CodeMapUsage] = []
    private var metricsSnapshots: [PromptContextEntryMetricsSnapshot?] = []
    private var startedCounts: [String: Int] = [:]
    private var continuations: [String: [CheckedContinuation<Void, Never>]] = [:]

    private var interimPublications = 0

    init(finalCodemapCount: Int = 0) {
        self.finalCodemapCount = finalCodemapCount
    }

    func resolve(
        _ request: AgentSelectedFilesModelRequest,
        interimFileRowsHandler: AgentSelectedFilesModelCoordinator.ResolveInterimFileRows?
    ) async -> AgentContextExportModel {
        usages.append(request.codeMapUsage)
        metricsSnapshots.append(request.entryMetricsSnapshot)
        let key = request.codeMapUsage.rawValue
        startedCounts[key, default: 0] += 1
        if let interimFileRowsHandler, request.codeMapUsage == .auto || request.codeMapUsage == .complete {
            interimPublications += 1
            await interimFileRowsHandler(makeModel(for: request))
        }
        if request.codeMapUsage == .auto || request.codeMapUsage == .complete {
            await withCheckedContinuation { continuation in
                continuations[key, default: []].append(continuation)
            }
        }
        return makeModel(for: request, codemapCount: finalCodemapCount)
    }

    func waitUntilStartCount(_ usage: CodeMapUsage, count: Int) async -> Bool {
        let key = usage.rawValue
        for _ in 0 ..< 500 {
            if startedCounts[key, default: 0] >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return startedCounts[key, default: 0] >= count
    }

    func waitUntilPendingContinuationCount(_ usage: CodeMapUsage, count: Int) async -> Bool {
        let key = usage.rawValue
        for _ in 0 ..< 500 {
            if continuations[key, default: []].count >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return continuations[key, default: []].count >= count
    }

    func releaseNext(_ usage: CodeMapUsage) {
        let key = usage.rawValue
        guard var queued = continuations[key], !queued.isEmpty else { return }
        let continuation = queued.removeFirst()
        continuations[key] = queued
        continuation.resume()
    }

    func startedUsages() -> [CodeMapUsage] {
        usages
    }

    func startedMetricsSnapshots() -> [PromptContextEntryMetricsSnapshot?] {
        metricsSnapshots
    }

    func interimPublicationCount() -> Int {
        interimPublications
    }
}

private actor VisibleFileMetricsPreservationResolver {
    private let fileIDs: [UUID]
    private let rootIDs: [UUID]
    private var interimPublications = 0
    private var continuations: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(fileID: UUID, fileIDs: [UUID]? = nil, rootIDs: [UUID] = [UUID()]) {
        self.fileIDs = fileIDs ?? [fileID]
        self.rootIDs = rootIDs
    }

    func resolve(
        _ request: AgentSelectedFilesModelRequest,
        interimFileRowsHandler: AgentSelectedFilesModelCoordinator.ResolveInterimFileRows?
    ) async -> AgentContextExportModel {
        let key = request.codeMapUsage.rawValue
        if let interimFileRowsHandler, request.codeMapUsage == .auto || request.codeMapUsage == .complete {
            let publicationIndex = interimPublications
            interimPublications += 1
            await interimFileRowsHandler(makeVisibleFileMetricsModel(
                for: request,
                fileID: fileID(for: publicationIndex),
                rootID: rootID(for: publicationIndex)
            ))
        }
        if request.codeMapUsage == .auto || request.codeMapUsage == .complete {
            await withCheckedContinuation { continuation in
                continuations[key, default: []].append(continuation)
            }
        }
        let publicationIndex = max(interimPublications - 1, 0)
        return makeVisibleFileMetricsModel(
            for: request,
            fileID: fileID(for: publicationIndex),
            rootID: rootID(for: publicationIndex),
            codemapCount: 1
        )
    }

    private func fileID(for publicationIndex: Int) -> UUID {
        fileIDs[min(publicationIndex, fileIDs.count - 1)]
    }

    private func rootID(for publicationIndex: Int) -> UUID {
        rootIDs[min(publicationIndex, rootIDs.count - 1)]
    }

    func waitUntilInterimPublicationCount(_ count: Int) async -> Bool {
        for _ in 0 ..< 500 {
            if interimPublications >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return interimPublications >= count
    }

    func releaseAll(_ usage: CodeMapUsage) {
        let key = usage.rawValue
        let queued = continuations.removeValue(forKey: key) ?? []
        for continuation in queued {
            continuation.resume()
        }
    }
}

private func makeVisibleFileMetricsModel(
    for request: AgentSelectedFilesModelRequest,
    fileID: UUID,
    rootID: UUID,
    codemapCount: Int = 0
) -> AgentContextExportModel {
    let fileName = request.source.promptText
    let metric = request.entryMetricsSnapshot?.metric(forFileID: fileID)
    let row = AgentContextExportRow(
        id: ResolvedPromptFileEntryID(fileID: fileID, mode: .fullFile, lineRanges: nil),
        kind: .full,
        rootID: rootID,
        relativePath: "Sources/\(fileName)",
        displayPath: "Sources/\(fileName)",
        displayName: fileName,
        directoryDisplay: "Sources",
        lineRanges: nil,
        metrics: metric.map {
            AgentContextExportRow.Metrics.known(
                tokenCount: $0.displayTokenCount,
                tokenPercentage: $0.displayPercentage,
                lineCount: $0.includedLineCount
            )
        } ?? .unknown,
        rootDisplayName: "Metric Root",
        rootColorKey: "metric-root",
        showRootPill: true,
        canRemove: true
    )
    let codemapRows = (0 ..< codemapCount).map { index in
        let codemapName = "Codemap\(index).swift"
        return AgentContextExportRow(
            id: ResolvedPromptFileEntryID(fileID: UUID(), mode: .codemap, lineRanges: nil),
            kind: .codemap,
            rootID: rootID,
            relativePath: "Sources/\(codemapName)",
            displayPath: "Sources/\(codemapName)",
            displayName: codemapName,
            directoryDisplay: "Sources",
            lineRanges: nil,
            canRemove: true
        )
    }
    return AgentContextExportModel(
        source: request.source,
        lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
        rows: [row] + codemapRows,
        totalSelectedDisplayTokens: request.entryMetricsSnapshot?.totalSelectedDisplayTokens ?? 0,
        missingPaths: [],
        invalidPaths: [],
        codemapPresentation: .empty
    )
}

private func makeModel(for request: AgentSelectedFilesModelRequest, codemapCount: Int = 0) -> AgentContextExportModel {
    let fileName = request.source.promptText
    let rootID = UUID()
    let row = AgentContextExportRow(
        id: ResolvedPromptFileEntryID(fileID: UUID(), mode: .fullFile, lineRanges: nil),
        kind: .full,
        rootID: rootID,
        relativePath: "Sources/\(fileName)",
        displayPath: "Sources/\(fileName)",
        displayName: fileName,
        directoryDisplay: "Sources",
        lineRanges: nil,
        canRemove: true
    )
    let codemapRows = (0 ..< codemapCount).map { index in
        let codemapName = "Codemap\(index).swift"
        return AgentContextExportRow(
            id: ResolvedPromptFileEntryID(fileID: UUID(), mode: .codemap, lineRanges: nil),
            kind: .codemap,
            rootID: rootID,
            relativePath: "Sources/\(codemapName)",
            displayPath: "Sources/\(codemapName)",
            displayName: codemapName,
            directoryDisplay: "Sources",
            lineRanges: nil,
            canRemove: true
        )
    }
    return AgentContextExportModel(
        source: request.source,
        lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
        rows: [row] + codemapRows,
        totalSelectedDisplayTokens: 0,
        missingPaths: [],
        invalidPaths: [],
        codemapPresentation: .empty
    )
}
