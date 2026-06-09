import Combine
import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

final class TokenCountingViewModelProjectionTests: XCTestCase {
    @MainActor
    func testHeavyProjectionPublishesCoreFileSubdivisionsWithoutDoubleCounting() async throws {
        let fixture = try await makeFixture(name: "CoreSubdivisions", includesAutoCodemap: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        var promptText = "Explain the selection"
        let instructionsText = "Be concise"
        let viewModel = makeViewModel(
            fixture: fixture,
            promptText: { promptText },
            instructionsText: { instructionsText },
            codeMapUsage: .auto
        )
        viewModel.suspendAutomaticRecounts()

        await viewModel.forceImmediateRecount()

        let breakdown = viewModel.latestTokenBreakdown()
        XCTAssertGreaterThan(viewModel.totalTokenCountFilesOnly, 0)
        XCTAssertGreaterThan(viewModel.codeMapTokenCount, 0)
        XCTAssertEqual(
            viewModel.totalFileTokensDisplay,
            viewModel.totalTokenCountFilesOnly + viewModel.codeMapTokenCount
        )
        XCTAssertEqual(breakdown.files, viewModel.totalFileTokensDisplay)
        XCTAssertEqual(
            breakdown.total,
            breakdown.files + breakdown.prompt + breakdown.meta + breakdown.fileTree + breakdown.git + breakdown.other
        )
        XCTAssertEqual(viewModel.totalTokenCount, breakdown.total)
        XCTAssertTrue(viewModel.hasAcceptedSelectionProjectionForTesting)

        promptText = "Explain the selection with examples"
        viewModel.markPromptDirty()
        await viewModel.processPendingRecountForTesting()
        XCTAssertEqual(viewModel.latestTokenBreakdown().files, breakdown.files)
        await viewModel.stopTokenCountUpdateTimer()
    }

    @MainActor
    func testLightRecountReusesAcceptedSelectionAndHeavyDirtyRecaptures() async throws {
        let fixture = try await makeFixture(name: "LightReuse", includesAutoCodemap: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let captureCounter = CaptureCounter()
        var promptText = "Initial"
        let viewModel = makeViewModel(
            fixture: fixture,
            promptText: { promptText },
            instructionsText: { "" },
            codeMapUsage: .none,
            projectionAdapterFactory: countingAdapterFactory(counter: captureCounter)
        )
        viewModel.suspendAutomaticRecounts()

        await viewModel.forceImmediateRecount()
        let initialCaptureCount = await captureCounter.value()
        XCTAssertEqual(initialCaptureCount, 1)
        let initialFileTokens = viewModel.latestTokenBreakdown().files

        promptText = "Updated prompt text"
        viewModel.markPromptDirty()
        await viewModel.processPendingRecountForTesting()
        let lightCaptureCount = await captureCounter.value()
        XCTAssertEqual(lightCaptureCount, 1)
        XCTAssertEqual(viewModel.latestTokenBreakdown().files, initialFileTokens)

        let publishedBeforeHeavyDirty = viewModel.latestTokenBreakdown()
        viewModel.markDirty(.settings)
        XCTAssertFalse(viewModel.hasAcceptedSelectionProjectionForTesting)
        XCTAssertEqual(viewModel.latestTokenBreakdown().total, publishedBeforeHeavyDirty.total)
        XCTAssertEqual(viewModel.latestTokenBreakdown().files, publishedBeforeHeavyDirty.files)
        await viewModel.processPendingRecountForTesting()
        let heavyCaptureCount = await captureCounter.value()
        XCTAssertEqual(heavyCaptureCount, 2)
        XCTAssertTrue(viewModel.hasAcceptedSelectionProjectionForTesting)
        await viewModel.stopTokenCountUpdateTimer()
    }

    @MainActor
    func testFilesDisabledPublishesOnlyCodemapDetails() async throws {
        let fixture = try await makeFixture(name: "FilesDisabled", includesAutoCodemap: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let viewModel = makeViewModel(
            fixture: fixture,
            promptText: { "" },
            instructionsText: { "" },
            codeMapUsage: .auto,
            includeFiles: false
        )
        viewModel.suspendAutomaticRecounts()

        await viewModel.forceImmediateRecount()

        XCTAssertEqual(viewModel.totalTokenCountFilesOnly, 0)
        XCTAssertGreaterThan(viewModel.codeMapTokenCount, 0)
        XCTAssertEqual(viewModel.charCount, 0)
        XCTAssertEqual(viewModel.codeMapFileCount, 1)
        XCTAssertEqual(viewModel.latestTokenBreakdown().files, viewModel.codeMapTokenCount)
        XCTAssertEqual(viewModel.folderTokenInfo.values.reduce(0) { $0 + $1.count }, viewModel.codeMapTokenCount)
        await viewModel.stopTokenCountUpdateTimer()
    }

    @MainActor
    func testInputRevisionGuardRejectsStaleHeavyPublicationAndPendingHeavyRecovers() async throws {
        let fixture = try await makeFixture(name: "StaleHeavy", includesAutoCodemap: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let gate = FirstCaptureGate()
        var selection = fixture.selection
        let viewModel = makeViewModel(
            fixture: fixture,
            promptText: { "" },
            instructionsText: { "" },
            codeMapUsage: .none,
            selection: { selection },
            projectionAdapterFactory: gatedAdapterFactory(gate: gate)
        )
        viewModel.suspendAutomaticRecounts()
        var publications = 0
        let subscription = viewModel.tokenCalculationCompletedPublisher.sink { publications += 1 }
        defer { subscription.cancel() }

        let staleRun = Task { @MainActor in
            await viewModel.forceImmediateRecount()
        }
        await gate.waitUntilStarted()
        selection = StoredSelection()
        viewModel.markDirty(.selection)
        XCTAssertFalse(viewModel.hasAcceptedSelectionProjectionForTesting)
        await gate.release()
        await staleRun.value

        XCTAssertEqual(viewModel.totalTokenCount, 0)
        XCTAssertFalse(viewModel.hasAcceptedSelectionProjectionForTesting)
        XCTAssertEqual(publications, 0)

        await viewModel.processPendingRecountForTesting()
        let recoveredCaptureCount = await gate.captureCount()
        XCTAssertEqual(recoveredCaptureCount, 2)
        XCTAssertEqual(viewModel.totalTokenCount, 0)
        XCTAssertTrue(viewModel.hasAcceptedSelectionProjectionForTesting)
        XCTAssertEqual(publications, 1)
        await viewModel.stopTokenCountUpdateTimer()
    }

    @MainActor
    func testActiveLiveResidualSurvivesVirtualLightRecountAndEachAcceptedResultPublishesOnce() async throws {
        let fixture = try await makeFixture(name: "Residual", includesAutoCodemap: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let residual = 17
        let coreAccounting = RepoPromptCore.PromptContextAccountingService()
        let lightRecorder = LightProjectionRecorder()
        var promptText = "Initial prompt"
        let viewModel = makeViewModel(
            fixture: fixture,
            promptText: { promptText },
            instructionsText: { "Meta" },
            codeMapUsage: .selected,
            accountingOperation: { request, store, capture in
                let result = try await coreAccounting.calculatePromptStats(
                    request: request,
                    store: store,
                    capture: capture
                )
                return Self.addingResidual(residual, to: result)
            },
            lightProjectionOperation: { selection, source, nonFile in
                await lightRecorder.record(source: source, nonFile: nonFile)
                return TokenProjectionService.workspaceComponentEstimates(
                    from: selection,
                    source: source,
                    nonFile: nonFile
                )
            }
        )
        viewModel.suspendAutomaticRecounts()
        var publications = 0
        let subscription = viewModel.tokenCalculationCompletedPublisher.sink { publications += 1 }
        defer { subscription.cancel() }

        await viewModel.forceImmediateRecount()

        let heavy = try XCTUnwrap(viewModel.publishedTokenProjectionForTesting)
        XCTAssertEqual(heavy.provenance.source, .activeLive)
        XCTAssertEqual(heavy.components.other, residual)
        XCTAssertEqual(publications, 1)

        promptText = "Updated prompt with more detail"
        viewModel.markPromptDirty()
        await viewModel.processPendingRecountForTesting()

        let light = try XCTUnwrap(viewModel.publishedTokenProjectionForTesting)
        XCTAssertEqual(light.provenance.source, .virtualRecomputed)
        XCTAssertEqual(light.components.other, residual)
        XCTAssertEqual(viewModel.latestTokenBreakdown().other, residual)
        XCTAssertEqual(publications, 2)
        let recordedLight = await lightRecorder.lastRecord()
        let lightRecord = try XCTUnwrap(recordedLight)
        XCTAssertEqual(lightRecord.source, .virtualRecomputed)
        XCTAssertEqual(lightRecord.other, residual)
        await viewModel.stopTokenCountUpdateTimer()
    }

    @MainActor
    func testConfiguredPoliciesKeepNormalizedAccountingAndPublishExactDetailMembership() async throws {
        let cases: [(CodeMapUsage, Bool, Int)] = [
            (.auto, true, 1),
            (.selected, true, 2),
            (.complete, true, 3),
            (.none, true, 0),
            (.auto, false, 1),
            (.selected, false, 1),
            (.complete, false, 1),
            (.none, false, 0)
        ]

        for (usage, includeFiles, expectedCodemapCount) in cases {
            let fixture = try await makeFixture(
                name: "Policy-\(usage)-\(includeFiles)",
                includesAutoCodemap: true,
                includesCompleteCodemap: true
            )
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            let usageRecorder = AccountingUsageRecorder()
            let coreAccounting = RepoPromptCore.PromptContextAccountingService()
            let viewModel = makeViewModel(
                fixture: fixture,
                promptText: { "" },
                instructionsText: { "" },
                codeMapUsage: usage,
                includeFiles: includeFiles,
                accountingOperation: { request, store, capture in
                    await usageRecorder.record(request.codeMapUsage)
                    return try await coreAccounting.calculatePromptStats(
                        request: request,
                        store: store,
                        capture: capture
                    )
                }
            )
            viewModel.suspendAutomaticRecounts()
            var publications = 0
            let subscription = viewModel.tokenCalculationCompletedPublisher.sink { publications += 1 }

            await viewModel.forceImmediateRecount()

            let recordedUsages = await usageRecorder.values()
            XCTAssertEqual(recordedUsages, [.auto])
            XCTAssertEqual(viewModel.codeMapFileCount, expectedCodemapCount, "\(usage), includeFiles=\(includeFiles)")
            XCTAssertEqual(
                viewModel.fileTokenInfo.values.reduce(0) { $0 + $1.count },
                viewModel.latestTokenBreakdown().files
            )
            XCTAssertEqual(
                viewModel.folderTokenInfo.values.reduce(0) { $0 + $1.count },
                viewModel.latestTokenBreakdown().files
            )
            XCTAssertEqual(viewModel.codeMapContent.isEmpty, expectedCodemapCount == 0)
            if usage == .complete, includeFiles {
                let roots = await fixture.store.roots()
                var records: [WorkspaceFileRecord] = []
                for root in roots {
                    await records.append(contentsOf: fixture.store.files(inRoot: root.id))
                }
                let completeOnly = try XCTUnwrap(records.first { $0.name == "CompleteOnly.swift" })
                XCTAssertEqual(viewModel.fileTokenInfo[completeOnly.id]?.fullCount, 0)
            }
            XCTAssertEqual(publications, 1)
            subscription.cancel()
            await viewModel.stopTokenCountUpdateTimer()
        }
    }

    @MainActor
    func testStaleLightCannotPublishAfterHeavyDirtyAndSuccessorPublishesOnce() async throws {
        let fixture = try await makeFixture(name: "StaleLight", includesAutoCodemap: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let gate = FirstLightProjectionGate()
        var promptText = "Initial"
        let viewModel = makeViewModel(
            fixture: fixture,
            promptText: { promptText },
            instructionsText: { "" },
            codeMapUsage: .auto,
            lightProjectionOperation: { selection, source, nonFile in
                await gate.enter()
                return TokenProjectionService.workspaceComponentEstimates(
                    from: selection,
                    source: source,
                    nonFile: nonFile
                )
            }
        )
        viewModel.suspendAutomaticRecounts()
        var publications = 0
        let subscription = viewModel.tokenCalculationCompletedPublisher.sink { publications += 1 }
        defer { subscription.cancel() }

        await viewModel.forceImmediateRecount()
        let accepted = viewModel.latestTokenBreakdown()
        XCTAssertEqual(publications, 1)

        promptText = "Stale update"
        viewModel.markPromptDirty()
        let staleLight = Task { @MainActor in
            await viewModel.processPendingRecountForTesting()
        }
        await gate.waitUntilStarted()
        viewModel.markDirty(.settings)
        await gate.release()
        await staleLight.value

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(viewModel.latestTokenBreakdown().total, accepted.total)

        await viewModel.processPendingRecountForTesting()
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(viewModel.publishedTokenProjectionForTesting?.provenance.source, .activeLive)
        await viewModel.stopTokenCountUpdateTimer()
    }

    @MainActor
    func testCancelledLightDoesNotPublishAndValidSuccessorRecovers() async throws {
        let fixture = try await makeFixture(name: "CancelledLight", includesAutoCodemap: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let gate = FirstLightProjectionGate()
        var promptText = "Initial"
        let viewModel = makeViewModel(
            fixture: fixture,
            promptText: { promptText },
            instructionsText: { "" },
            codeMapUsage: .none,
            lightProjectionOperation: { selection, source, nonFile in
                await gate.enter()
                try Task.checkCancellation()
                return TokenProjectionService.workspaceComponentEstimates(
                    from: selection,
                    source: source,
                    nonFile: nonFile
                )
            }
        )
        viewModel.suspendAutomaticRecounts()
        var publications = 0
        let subscription = viewModel.tokenCalculationCompletedPublisher.sink { publications += 1 }
        defer { subscription.cancel() }

        await viewModel.forceImmediateRecount()
        let accepted = viewModel.latestTokenBreakdown()

        promptText = "Cancelled"
        viewModel.markPromptDirty()
        let cancelled = Task { @MainActor in
            await viewModel.processPendingRecountForTesting()
        }
        await gate.waitUntilStarted()
        cancelled.cancel()
        await gate.release()
        await cancelled.value

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(viewModel.latestTokenBreakdown().total, accepted.total)

        promptText = "Recovered"
        viewModel.markPromptDirty()
        await viewModel.processPendingRecountForTesting()
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(viewModel.publishedTokenProjectionForTesting?.provenance.source, .virtualRecomputed)
        await viewModel.stopTokenCountUpdateTimer()
    }

    @MainActor
    func testHeavyErrorRetriesInsideSameRecountAndPublishesOnce() async throws {
        let fixture = try await makeFixture(name: "HeavyError", includesAutoCodemap: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let accounting = AccountingFailureController()
        let viewModel = makeViewModel(
            fixture: fixture,
            promptText: { "" },
            instructionsText: { "" },
            codeMapUsage: .none,
            accountingOperation: { request, store, capture in
                try await accounting.calculate(request: request, store: store, capture: capture)
            }
        )
        viewModel.suspendAutomaticRecounts()
        var publications = 0
        let subscription = viewModel.tokenCalculationCompletedPublisher.sink { publications += 1 }
        defer { subscription.cancel() }

        await viewModel.forceImmediateRecount()
        let accepted = viewModel.latestTokenBreakdown()
        XCTAssertEqual(publications, 1)

        viewModel.markDirty(.settings)
        await viewModel.processPendingRecountForTesting()
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(viewModel.latestTokenBreakdown().total, accepted.total)
        let accountingCalls = await accounting.callCount()
        XCTAssertEqual(accountingCalls, 3)
        await viewModel.stopTokenCountUpdateTimer()
    }

    @MainActor
    func testProjectionCoherenceErrorRetriesInsideSameRecountAndPublishesOnce() async throws {
        let fixture = try await makeFixture(name: "ProjectionRetry", includesAutoCodemap: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let accounting = ProjectionMismatchController()
        let viewModel = makeViewModel(
            fixture: fixture,
            promptText: { "" },
            instructionsText: { "" },
            codeMapUsage: .none,
            accountingOperation: { request, store, capture in
                try await accounting.calculate(request: request, store: store, capture: capture)
            }
        )
        viewModel.suspendAutomaticRecounts()
        var publications = 0
        let subscription = viewModel.tokenCalculationCompletedPublisher.sink { publications += 1 }
        defer { subscription.cancel() }

        await viewModel.forceImmediateRecount()
        XCTAssertEqual(publications, 1)

        viewModel.markDirty(.settings)
        await viewModel.processPendingRecountForTesting()

        XCTAssertEqual(publications, 2)
        let accountingCalls = await accounting.callCount()
        XCTAssertEqual(accountingCalls, 3)
        await viewModel.stopTokenCountUpdateTimer()
    }

    private static func addingResidual(
        _ residual: Int,
        to result: PromptContextAccountingResult
    ) -> PromptContextAccountingResult {
        let token = result.tokenResult
        return PromptContextAccountingResult(
            tokenResult: TokenCalculationResult(
                totalTokenCount: token.totalTokenCount + residual,
                totalTokenCountFilesOnly: token.totalTokenCountFilesOnly,
                fileTokenInfo: token.fileTokenInfo,
                folderTokenInfo: token.folderTokenInfo,
                tokenCountString: token.tokenCountString,
                tokenCountFilesOnlyString: token.tokenCountFilesOnlyString,
                charCount: token.charCount,
                fileTreeContent: token.fileTreeContent,
                fileTreeTokenCount: token.fileTreeTokenCount,
                fileTreeTokenCountRaw: token.fileTreeTokenCountRaw,
                codeMapContent: token.codeMapContent,
                codeMapFileCount: token.codeMapFileCount,
                codeMapTokenCount: token.codeMapTokenCount
            ),
            resolvedEntries: result.resolvedEntries,
            promptFileEntrySnapshots: result.promptFileEntrySnapshots,
            tokenCalculationSnapshot: result.tokenCalculationSnapshot,
            missingPaths: result.missingPaths,
            invalidPaths: result.invalidPaths,
            codemapSnapshotsUsed: result.codemapSnapshotsUsed,
            captureProvenance: result.captureProvenance
        )
    }

    private struct Fixture {
        let rootURL: URL
        let store: WorkspaceFileContextStore
        let fileManager: WorkspaceFilesViewModel
        let gitViewModel: GitViewModel
        let selection: StoredSelection
    }

    @MainActor
    private func makeFixture(
        name: String,
        includesAutoCodemap: Bool,
        includesCompleteCodemap: Bool = false
    ) async throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("TokenCountingProjection-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let selectedURL = rootURL.appendingPathComponent("Selected.swift")
        try "struct Selected { let value = 1 }\n".write(to: selectedURL, atomically: true, encoding: .utf8)

        var autoURL: URL?
        if includesAutoCodemap {
            let url = rootURL.appendingPathComponent("Auto.swift")
            try "struct Auto { func helper() {} }\n".write(to: url, atomically: true, encoding: .utf8)
            autoURL = url
        }
        var completeURL: URL?
        if includesCompleteCodemap {
            let url = rootURL.appendingPathComponent("CompleteOnly.swift")
            try "struct CompleteOnly { func helper() {} }\n".write(to: url, atomically: true, encoding: .utf8)
            completeURL = url
        }

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: rootURL.path)
        var codemapResults = [
            WorkspaceObservedCodemapResult(
                fullPath: selectedURL.path,
                modificationDate: Date(timeIntervalSince1970: 0),
                fileAPI: makeFileAPI(path: selectedURL.path, symbol: "selectedSymbol")
            )
        ]
        if let autoURL {
            codemapResults.append(WorkspaceObservedCodemapResult(
                fullPath: autoURL.path,
                modificationDate: Date(timeIntervalSince1970: 0),
                fileAPI: makeFileAPI(path: autoURL.path, symbol: "autoSymbol")
            ))
        }
        if let completeURL {
            codemapResults.append(WorkspaceObservedCodemapResult(
                fullPath: completeURL.path,
                modificationDate: Date(timeIntervalSince1970: 0),
                fileAPI: makeFileAPI(path: completeURL.path, symbol: "completeSymbol")
            ))
        }
        await store.applyObservedCodemapResults(codemapResults)
        let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let gitViewModel = GitViewModel(fileManager: fileManager)
        let selection = StoredSelection(
            selectedPaths: [selectedURL.path],
            autoCodemapPaths: autoURL.map { [$0.path] } ?? [],
            codemapAutoEnabled: includesAutoCodemap
        )
        return Fixture(
            rootURL: rootURL,
            store: store,
            fileManager: fileManager,
            gitViewModel: gitViewModel,
            selection: selection
        )
    }

    @MainActor
    private func makeViewModel(
        fixture: Fixture,
        promptText: @escaping () -> String,
        instructionsText: @escaping () -> String,
        codeMapUsage: CodeMapUsage,
        includeFiles: Bool = true,
        selection: (() -> StoredSelection)? = nil,
        projectionAdapterFactory: @escaping TokenCountingViewModel.ProjectionAdapterFactory = { store in
            WorkspacePromptProjectionAdapter(store: store)
        },
        accountingOperation: TokenCountingViewModel.AccountingOperation? = nil,
        lightProjectionOperation: @escaping TokenCountingViewModel.LightProjectionOperation = { selection, source, nonFile in
            TokenProjectionService.workspaceComponentEstimates(
                from: selection,
                source: source,
                nonFile: nonFile
            )
        }
    ) -> TokenCountingViewModel {
        let viewModel = TokenCountingViewModel(
            projectionAdapterFactory: projectionAdapterFactory,
            accountingOperation: accountingOperation,
            lightProjectionOperation: lightProjectionOperation
        )
        viewModel.configure(
            fileManager: fixture.fileManager,
            gitViewModel: fixture.gitViewModel,
            getPromptText: promptText,
            getSelectedInstructionsText: instructionsText,
            getSettings: {
                TokenCountingViewModel.TokenCalculationSettings(
                    fileTreeOption: .none,
                    codeMapUsage: codeMapUsage,
                    filePathDisplayOption: .relative,
                    includeFilesInClipboard: includeFiles,
                    duplicateUserInstructionsAtTop: false,
                    onlyIncludeRootsWithSelectedFiles: false,
                    codeMapsGloballyDisabled: false
                )
            },
            getCopyContext: {
                TokenCountingViewModel.CopyContextSnapshot(
                    includeFiles: includeFiles,
                    includeUserPrompt: true,
                    includeMetaPrompts: true,
                    includeFileTree: false,
                    fileTreeMode: .none,
                    codeMapUsage: codeMapUsage,
                    gitInclusion: .none,
                    duplicateUserInstructionsAtTop: false
                )
            },
            getStoredSelection: {
                selection?() ?? fixture.selection
            }
        )
        return viewModel
    }

    @MainActor
    private func countingAdapterFactory(
        counter: CaptureCounter
    ) -> TokenCountingViewModel.ProjectionAdapterFactory {
        { store in
            WorkspacePromptProjectionAdapter { selection, request, profile, coverage in
                await counter.increment()
                return try await store.captureWorkspaceFileContext(
                    selection: selection,
                    fileTreeRequest: request,
                    profile: profile,
                    coverage: coverage
                )
            }
        }
    }

    @MainActor
    private func gatedAdapterFactory(
        gate: FirstCaptureGate
    ) -> TokenCountingViewModel.ProjectionAdapterFactory {
        { store in
            WorkspacePromptProjectionAdapter { selection, request, profile, coverage in
                await gate.captureStarted()
                return try await store.captureWorkspaceFileContext(
                    selection: selection,
                    fileTreeRequest: request,
                    profile: profile,
                    coverage: coverage
                )
            }
        }
    }

    private func makeFileAPI(path: String, symbol: String) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: [],
            functions: [
                FunctionInfo(
                    name: symbol,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbol)()",
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

private actor LightProjectionRecorder {
    struct Record {
        let source: TokenProjection.Source
        let other: Int
    }

    private var records: [Record] = []

    func record(
        source: TokenProjection.Source,
        nonFile: TokenProjectionService.WorkspaceNonFileComponents
    ) {
        records.append(Record(source: source, other: nonFile.other))
    }

    func lastRecord() -> Record? {
        records.last
    }
}

private actor AccountingUsageRecorder {
    private var usages: [CodeMapUsage] = []

    func record(_ usage: CodeMapUsage) {
        usages.append(usage)
    }

    func values() -> [CodeMapUsage] {
        usages
    }
}

private actor FirstLightProjectionGate {
    private var count = 0
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        count += 1
        guard count == 1 else { return }
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
        if started { return }
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

private actor AccountingFailureController {
    private enum Failure: Error {
        case injected
    }

    private let core = RepoPromptCore.PromptContextAccountingService()
    private var calls = 0

    func calculate(
        request: PromptContextAccountingRequest,
        store: WorkspaceFileContextStore,
        capture: WorkspaceFileContextCapture
    ) async throws -> PromptContextAccountingResult {
        calls += 1
        if calls == 2 {
            throw Failure.injected
        }
        return try await core.calculatePromptStats(
            request: request,
            store: store,
            capture: capture
        )
    }

    func callCount() -> Int {
        calls
    }
}

private actor ProjectionMismatchController {
    private let core = RepoPromptCore.PromptContextAccountingService()
    private var calls = 0

    func calculate(
        request: PromptContextAccountingRequest,
        store: WorkspaceFileContextStore,
        capture: WorkspaceFileContextCapture
    ) async throws -> PromptContextAccountingResult {
        calls += 1
        let result = try await core.calculatePromptStats(
            request: request,
            store: store,
            capture: capture
        )
        guard calls == 2,
              let resolved = result.resolvedEntries.first,
              let snapshot = result.promptFileEntrySnapshots.first
        else { return result }
        return PromptContextAccountingResult(
            tokenResult: result.tokenResult,
            resolvedEntries: result.resolvedEntries + [resolved],
            promptFileEntrySnapshots: result.promptFileEntrySnapshots + [snapshot],
            tokenCalculationSnapshot: result.tokenCalculationSnapshot,
            missingPaths: result.missingPaths,
            invalidPaths: result.invalidPaths,
            codemapSnapshotsUsed: result.codemapSnapshotsUsed,
            captureProvenance: result.captureProvenance
        )
    }

    func callCount() -> Int {
        calls
    }
}

private actor CaptureCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor FirstCaptureGate {
    private var count = 0
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func captureStarted() async {
        count += 1
        guard count == 1 else { return }
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
        if started { return }
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

    func captureCount() -> Int {
        count
    }
}
