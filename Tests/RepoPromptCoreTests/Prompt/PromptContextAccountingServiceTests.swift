import Foundation
@testable import RepoPromptCore
import XCTest

final class PromptContextAccountingServiceTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testExactSelectedFilesPreserveStoredSelectionOrderAfterConcurrentReads() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "AccountingOrder")
        let fileA = root.appendingPathComponent("A.swift")
        let fileB = root.appendingPathComponent("B.swift")
        let fileC = root.appendingPathComponent("C.swift")
        try FileSystemTestSupport.write("alpha", to: fileA)
        try FileSystemTestSupport.write("beta", to: fileB)
        try FileSystemTestSupport.write("gamma", to: fileC)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let selection = StoredSelection(
            selectedPaths: [fileC.path, fileA.path, fileB.path],
            codemapAutoEnabled: false
        )

        let resolution = try await PromptContextAccountingService().resolveEntries(
            selection: selection,
            store: store,
            codeMapUsage: .none
        )

        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), ["C.swift", "A.swift", "B.swift"])
        XCTAssertEqual(resolution.entries.map(\.loadedContent), ["gamma", "alpha", "beta"])
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testDirectSelectedFolderUsesRelativePathOrderAndBoundedReads() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "AccountingFolder")
        let paths = [
            "Sources/Z.swift",
            "Sources/A.swift",
            "Sources/Nested/C.swift",
            "Sources/Nested/B.swift",
            "Sources/notes.txt",
            "Sources/Nested/D.swift"
        ]
        for path in paths {
            try FileSystemTestSupport.write(path, to: root.appendingPathComponent(path))
        }
        try FileSystemTestSupport.write("outside", to: root.appendingPathComponent("Outside.swift"))

        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        let gate = AccountingReadGate()
        let tracker = AccountingReadConcurrencyTracker()
        try await store.setContentReadChunkHandlerForTesting(rootID: rootRecord.id) { _ in
            await tracker.enter()
            await gate.enterAndWaitForRelease()
            await tracker.leave()
        }

        let task = Task {
            try await PromptContextAccountingService().resolveEntries(
                selection: StoredSelection(
                    selectedPaths: [root.appendingPathComponent("Sources").path],
                    codemapAutoEnabled: false
                ),
                store: store,
                codeMapUsage: .none
            )
        }
        let effectiveLimit = min(
            PromptContextAccountingService.selectedFileReadConcurrencyLimit,
            FileSystemService.contentReadWorkerLimitForTesting
        )
        let reachedReadLimit = await gate.waitUntilStarted(atLeast: effectiveLimit)
        XCTAssertTrue(reachedReadLimit)
        let beforeRelease = await tracker.snapshot()
        XCTAssertEqual(beforeRelease.active, effectiveLimit)
        XCTAssertEqual(beforeRelease.maximum, effectiveLimit)

        await gate.release()
        let resolution = try await task.value
        try await store.setContentReadChunkHandlerForTesting(rootID: rootRecord.id, nil)

        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), [
            "Sources/A.swift",
            "Sources/Nested/B.swift",
            "Sources/Nested/C.swift",
            "Sources/Nested/D.swift",
            "Sources/Z.swift",
            "Sources/notes.txt"
        ])
        XCTAssertEqual(
            resolution.entries.map(\.loadedContent),
            resolution.entries.map { Optional($0.file.standardizedRelativePath) }
        )
        let finalConcurrency = await tracker.snapshot()
        XCTAssertEqual(finalConcurrency.maximum, effectiveLimit)
    }

    func testOverlappingFileFolderAndDuplicatePathsKeepFirstEncounterOrder() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "AccountingDedup")
        let fileA = root.appendingPathComponent("Sources/A.swift")
        let fileB = root.appendingPathComponent("Sources/B.swift")
        try FileSystemTestSupport.write("alpha", to: fileA)
        try FileSystemTestSupport.write("beta", to: fileB)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let selection = StoredSelection(
            selectedPaths: [fileB.path, root.appendingPathComponent("Sources").path, fileB.path],
            codemapAutoEnabled: false
        )

        let resolution = try await PromptContextAccountingService().resolveEntries(
            selection: selection,
            store: store,
            codeMapUsage: .none
        )

        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), ["Sources/B.swift", "Sources/A.swift"])
        XCTAssertEqual(resolution.entries.map(\.loadedContent), ["beta", "alpha"])
    }

    func testSelectedFileSliceResolvesRelativeAliasWithoutDuplicatingStandaloneSlice() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "AccountingSlices")
        let file = root.appendingPathComponent("Sources/A.swift")
        try FileSystemTestSupport.write("one\ntwo\nthree", to: file)
        let ranges = [LineRange(start: 2, end: 2, description: "middle")]

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let selection = StoredSelection(
            selectedPaths: [file.path],
            slices: ["Sources/A.swift": ranges],
            codemapAutoEnabled: false
        )

        let resolution = try await PromptContextAccountingService().resolveEntries(
            selection: selection,
            store: store,
            codeMapUsage: .none
        )

        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertEqual(resolution.entries.count, 1)
        XCTAssertEqual(entry.mode, .sliced)
        XCTAssertEqual(entry.lineRanges, ranges)
        XCTAssertEqual(entry.loadedContent, "one\ntwo\nthree")
    }

    func testAmbiguousExactPathIsInvalidWhileOrdinaryUnresolvedPathIsMissing() async throws {
        let parentA = try temporaryRoots.makeRoot(suiteName: "AccountingAmbiguousA")
        let parentB = try temporaryRoots.makeRoot(suiteName: "AccountingAmbiguousB")
        let rootA = parentA.appendingPathComponent("SharedRoot", isDirectory: true)
        let rootB = parentB.appendingPathComponent("SharedRoot", isDirectory: true)
        try FileSystemTestSupport.write("a", to: rootA.appendingPathComponent("Sources/A.swift"))
        try FileSystemTestSupport.write("b", to: rootB.appendingPathComponent("Sources/A.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: rootA.path)
        _ = try await store.loadRoot(path: rootB.path)
        let missing = "DefinitelyMissing.swift"
        let selection = StoredSelection(
            selectedPaths: ["Sources/A.swift", missing],
            codemapAutoEnabled: false
        )

        let resolution = try await PromptContextAccountingService().resolveEntries(
            selection: selection,
            store: store,
            rootScope: .allLoaded,
            codeMapUsage: .none
        )

        XCTAssertEqual(resolution.entries, [])
        XCTAssertEqual(resolution.invalidPaths, ["Sources/A.swift"])
        XCTAssertEqual(resolution.missingPaths, [missing])
    }

    func testSelectedCodemapSkipsFullContentReadWhenAPIExists() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "AccountingSelectedCodemap")
        let file = root.appendingPathComponent("A.swift")
        try FileSystemTestSupport.write("struct A { func fullContent() {} }", to: file)

        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: file.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(path: file.path, symbol: "codemapOnlySymbol")
            )
        ])
        let reads = AccountingReadCounter()
        try await store.setContentReadChunkHandlerForTesting(rootID: rootRecord.id) { _ in
            await reads.increment()
        }

        let resolution = try await PromptContextAccountingService().resolveEntries(
            selection: StoredSelection(selectedPaths: [file.path], codemapAutoEnabled: false),
            store: store,
            codeMapUsage: .selected
        )
        try await store.setContentReadChunkHandlerForTesting(rootID: rootRecord.id, nil)

        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertEqual(resolution.entries.count, 1)
        XCTAssertTrue(entry.isCodemap)
        XCTAssertEqual(entry.mode, .codemap)
        XCTAssertNil(entry.lineRanges)
        XCTAssertNil(entry.loadedContent)
        let readCount = await reads.value()
        XCTAssertEqual(readCount, 0)
    }

    func testSelectedCodemapFallsBackToFullContentWhenAPIIsUnavailable() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "AccountingSelectedCodemapFallback")
        let file = root.appendingPathComponent("A.swift")
        try FileSystemTestSupport.write("struct A {}", to: file)

        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        let reads = AccountingReadCounter()
        try await store.setContentReadChunkHandlerForTesting(rootID: rootRecord.id) { _ in
            await reads.increment()
        }

        let resolution = try await PromptContextAccountingService().resolveEntries(
            selection: StoredSelection(selectedPaths: [file.path], codemapAutoEnabled: false),
            store: store,
            codeMapUsage: .selected
        )
        try await store.setContentReadChunkHandlerForTesting(rootID: rootRecord.id, nil)

        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertFalse(entry.isCodemap)
        XCTAssertEqual(entry.mode, .fullFile)
        XCTAssertEqual(entry.loadedContent, "struct A {}")
        let readCount = await reads.value()
        XCTAssertGreaterThan(readCount, 0)
    }

    func testAutoAndCompleteCodemapModesIncludeOnlyEligibleUnselectedFiles() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "AccountingCodemapModes")
        let selected = root.appendingPathComponent("Selected.swift")
        let auto = root.appendingPathComponent("Auto.swift")
        let complete = root.appendingPathComponent("Complete.swift")
        try FileSystemTestSupport.write("selected", to: selected)
        try FileSystemTestSupport.write("auto", to: auto)
        try FileSystemTestSupport.write("complete", to: complete)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: selected.path, modificationDate: Date(), fileAPI: makeFileAPI(path: selected.path, symbol: "selectedAPI")),
            WorkspaceObservedCodemapResult(fullPath: auto.path, modificationDate: Date(), fileAPI: makeFileAPI(path: auto.path, symbol: "autoAPI")),
            WorkspaceObservedCodemapResult(fullPath: complete.path, modificationDate: Date(), fileAPI: makeFileAPI(path: complete.path, symbol: "completeAPI"))
        ])
        let selection = StoredSelection(
            selectedPaths: [selected.path],
            autoCodemapPaths: [auto.path],
            codemapAutoEnabled: true
        )
        let service = PromptContextAccountingService()

        let autoResolution = try await service.resolveEntries(
            selection: selection,
            store: store,
            codeMapUsage: .auto
        )
        XCTAssertEqual(autoResolution.entries.map(\.file.standardizedRelativePath), ["Selected.swift", "Auto.swift"])
        XCTAssertEqual(autoResolution.entries.map(\.isCodemap), [false, true])
        XCTAssertNil(autoResolution.entries[1].loadedContent)

        let completeResolution = try await service.resolveEntries(
            selection: selection,
            store: store,
            codeMapUsage: .complete
        )
        XCTAssertEqual(completeResolution.entries.first?.file.standardizedRelativePath, "Selected.swift")
        XCTAssertEqual(
            Set(completeResolution.entries.dropFirst().map(\.file.standardizedRelativePath)),
            Set(["Auto.swift", "Complete.swift"])
        )
        XCTAssertTrue(completeResolution.entries.dropFirst().allSatisfy(\.isCodemap))
        XCTAssertTrue(completeResolution.entries.dropFirst().allSatisfy { $0.loadedContent == nil })
    }

    func testOrdinaryReadFailureKeepsEntryWithNilContent() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "AccountingReadFailure")
        let file = root.appendingPathComponent("A.swift")
        try FileSystemTestSupport.write("alpha", to: file)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        try FileManager.default.removeItem(at: file)

        let resolution = try await PromptContextAccountingService().resolveEntries(
            selection: StoredSelection(selectedPaths: [file.path], codemapAutoEnabled: false),
            store: store,
            codeMapUsage: .none
        )

        XCTAssertEqual(resolution.entries.count, 1)
        XCTAssertNil(resolution.entries[0].loadedContent)
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testCancellationThrowsWithoutPartialResultAndReleasesReadCapacity() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "AccountingCancellation")
        let file = root.appendingPathComponent("A.swift")
        try FileSystemTestSupport.write(String(repeating: "a", count: 1_000_000), to: file)

        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        let gate = AccountingReadGate()
        try await store.setContentReadChunkHandlerForTesting(rootID: rootRecord.id) { _ in
            await gate.enterAndWaitForRelease()
        }
        let selection = StoredSelection(selectedPaths: [file.path], codemapAutoEnabled: false)
        let service = PromptContextAccountingService()
        let task = Task {
            try await service.resolveEntries(
                selection: selection,
                store: store,
                codeMapUsage: .none
            )
        }

        let readStarted = await gate.waitUntilStarted(atLeast: 1)
        XCTAssertTrue(readStarted)
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        try await store.setContentReadChunkHandlerForTesting(rootID: rootRecord.id, nil)
        let later = try await service.resolveEntries(
            selection: selection,
            store: store,
            codeMapUsage: .none
        )
        XCTAssertEqual(later.entries.first?.loadedContent?.count, 1_000_000)
        let limiter = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(limiter.queueDepth, 0)
        XCTAssertEqual(limiter.waiterCount, 0)
        XCTAssertEqual(limiter.pendingWaiterCount, 0)
    }

    func testConcurrentCalculationsOnOneServiceDoNotCancelEachOther() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "AccountingIndependentCalculations")
        let fileA = root.appendingPathComponent("A.swift")
        let fileB = root.appendingPathComponent("B.swift")
        try FileSystemTestSupport.write(String(repeating: "a", count: 200_000), to: fileA)
        try FileSystemTestSupport.write(String(repeating: "b", count: 200_000), to: fileB)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = PromptContextAccountingService()
        async let resultA = service.calculatePromptStats(
            request: PromptContextAccountingRequest(
                selection: StoredSelection(selectedPaths: [fileA.path]),
                codeMapUsage: .none
            ),
            store: store
        )
        async let resultB = service.calculatePromptStats(
            request: PromptContextAccountingRequest(
                selection: StoredSelection(selectedPaths: [fileB.path]),
                codeMapUsage: .none
            ),
            store: store
        )
        let (accountingA, accountingB) = try await (resultA, resultB)

        XCTAssertGreaterThan(accountingA.tokenResult.totalTokenCountFilesOnly, 0)
        XCTAssertGreaterThan(accountingB.tokenResult.totalTokenCountFilesOnly, 0)
        XCTAssertEqual(accountingA.resolvedEntries.map(\.file.standardizedRelativePath), ["A.swift"])
        XCTAssertEqual(accountingB.resolvedEntries.map(\.file.standardizedRelativePath), ["B.swift"])
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

private actor AccountingReadGate {
    private var startedCount = 0
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func enterAndWaitForRelease() async {
        startedCount += 1
        guard !released else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilStarted(atLeast target: Int) async -> Bool {
        for _ in 0 ..< 500 {
            if startedCount >= target { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return startedCount >= target
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor AccountingReadConcurrencyTracker {
    private var active = 0
    private var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() {
        active -= 1
    }

    func snapshot() -> (active: Int, maximum: Int) {
        (active, maximum)
    }
}

private actor AccountingReadCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
