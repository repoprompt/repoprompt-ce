import Foundation
@testable import RepoPrompt
import XCTest

final class AgentContextExportResolverTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

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
        XCTAssertEqual(summary.headlineText, "2 files · 1 sliced · 2 ranges")
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
        XCTAssertEqual(summary.headlineText, "1 file · 1 sliced · 1 range")
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
        XCTAssertEqual(summary.headlineText, "0 files")
    }

    func testSelectionSummaryRetainsFullOnlyFormatting() {
        let singular = AgentContextExportResolver.selectionSummary(
            for: StoredSelection(selectedPaths: ["One.swift"], codemapAutoEnabled: false)
        )
        let plural = AgentContextExportResolver.selectionSummary(
            for: StoredSelection(selectedPaths: ["One.swift", "Two.swift"], codemapAutoEnabled: false)
        )

        XCTAssertEqual(singular.headlineText, "1 file")
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
        XCTAssertEqual(summary.headlineText, "1 file · 1 sliced · 3 ranges")
    }

    func testNonGitAutomaticExportPreservesSelectedRowsWithoutRuntimeOrLegacyFallback() async throws {
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

            let model = await AgentContextExportResolver.resolveModel(
                source: source,
                store: store,
                filePathDisplay: .relative,
                codeMapUsage: .auto
            )
            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let snapshotBuildCount = capture.stages
                .filter { $0.stageName == String(describing: EditFlowPerf.Stage.ReadFile.pathLookupStaticSnapshotBuild) }
                .reduce(0) { $0 + $1.sampleCount }

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
            XCTAssertEqual(capture.droppedSampleCount, 0)
        #endif
    }

    func testWorktreeExportUsesPhysicalContentWhileDisplayingLogicalPath() async throws {
        let fixture = try await makeBoundFixture()
        let source = makeSource(
            logicalRoot: fixture.logicalRoot,
            worktreeRoot: fixture.worktreeRoot,
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false)
        )

        let model = await AgentContextExportResolver.resolveModel(
            source: source,
            store: fixture.store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )

        let row = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(row.displayPath, "Sources/App.swift")

        let previewText = await AgentContextExportResolver.loadRowContent(
            for: row,
            model: model,
            store: fixture.store,
            purpose: .preview
        )
        XCTAssertEqual(previewText, "let origin = \"worktree\"\n")
        XCTAssertFalse(previewText?.contains("base") ?? true)

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
                completeGitDiffProvider: { "unexpected complete diff" }
            )
        )

        XCTAssertTrue(clipboard.contains("Sources/App.swift"), clipboard)
        XCTAssertTrue(clipboard.contains("let origin = \"worktree\""), clipboard)
        XCTAssertFalse(clipboard.contains("let origin = \"base\""), clipboard)
    }

    func testWorktreeSelectedCodemapUsesFrozenLogicalPresentationWithoutPhysicalLeak() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        defer { repositoryFixture.cleanup() }
        let logicalRoot = try repositoryFixture.makeRepository(
            named: "agent-export-logical",
            files: ["App.swift": "struct LogicalBase {}\n"]
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

        let model = await AgentContextExportResolver.resolveModel(
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
        try write("struct SelectedUnavailable {}\n", to: root.appendingPathComponent("Sources/App.swift"))
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

        let model = await AgentContextExportResolver.resolveModel(
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

    func testRevokedCodemapLifetimeOmitsStaleTargetBeforeModelPublication() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        defer { repositoryFixture.cleanup() }
        let logicalRoot = try repositoryFixture.makeRepository(
            named: "agent-export-revoked-logical",
            files: ["Sources/Target.swift": "struct LogicalTarget {}\n"]
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

        let model = await AgentContextExportResolver.resolveModel(
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

        let model = await AgentContextExportResolver.resolveModel(
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
        let model = await AgentContextExportResolver.resolveModel(
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
        let model = await AgentContextExportResolver.resolveModel(
            source: source,
            store: store,
            filePathDisplay: .relative,
            codeMapUsage: .none
        )

        XCTAssertEqual(lookupContext.rootScope, .visibleWorkspace)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.missingPaths, ["Sources/Hidden.swift"])
    }

    func testDuplicateRootBasenamesProduceStableAgentPathsWithoutPhysicalLeaks() async throws {
        let firstParent = try makeTemporaryRoot(name: "AgentDuplicateRootFirst")
        let secondParent = try makeTemporaryRoot(name: "AgentDuplicateRootSecond")
        let firstRoot = firstParent.appendingPathComponent("repo")
        let secondRoot = secondParent.appendingPathComponent("repo")
        let firstFile = firstRoot.appendingPathComponent("Sources/App.swift")
        let secondFile = secondRoot.appendingPathComponent("Sources/App.swift")
        try write("struct FirstDuplicateRoot {}\n", to: firstFile)
        try write("struct SecondDuplicateRoot {}\n", to: secondFile)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: firstRoot.path)
        _ = try await store.loadRoot(path: secondRoot.path)

        func model(paths: [String]) async -> AgentContextExportModel {
            await AgentContextExportResolver.resolveModel(
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

        let first = await model(paths: [secondFile.path, firstFile.path])
        let second = await model(paths: [firstFile.path, secondFile.path])
        let paths = first.rows.map(\.displayPath)

        XCTAssertEqual(paths, second.rows.map(\.displayPath))
        XCTAssertEqual(Set(paths).count, 2)
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
    }

    func testRemoveRowRebasedOntoLatestSelectionPreservesNewlyAddedFiles() async throws {
        let fixture = try await makeBoundFixture()
        let staleSelection = StoredSelection(
            selectedPaths: ["Sources/App.swift", "Sources/Keep.swift"],
            codemapAutoEnabled: false
        )
        let source = makeSource(logicalRoot: fixture.logicalRoot, worktreeRoot: fixture.worktreeRoot, selection: staleSelection)
        let model = await AgentContextExportResolver.resolveModel(
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

        let model = await AgentContextExportResolver.resolveModel(
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
        let model = await AgentContextExportResolver.resolveModel(
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
        let model = await AgentContextExportResolver.resolveModel(
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
