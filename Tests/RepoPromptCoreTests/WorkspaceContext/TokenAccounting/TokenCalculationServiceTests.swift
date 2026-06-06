import Foundation
@testable import RepoPromptCore
import XCTest

final class TokenCalculationServiceTests: XCTestCase {
    func testEstimateTokensUsesUTF8BytesAndSafetyMultiplier() {
        XCTAssertEqual(TokenCalculationService.estimateTokens(for: ""), 0)
        XCTAssertEqual(TokenCalculationService.estimateTokens(for: "1234"), 1)
        XCTAssertEqual(TokenCalculationService.estimateTokens(for: "éé"), 1)
        XCTAssertEqual(TokenCalculationService.estimateTokens(for: String(repeating: "a", count: 40)), 10)
    }

    func testMiddleTruncateIsDeterministicIdempotentAndUnicodeSafe() {
        let text = String(repeating: "🙂abcdef", count: 100)
        let truncated = TokenCalculationService.middleTruncate(text: text, maxTokens: 30)

        XCTAssertTrue(truncated.contains("[content truncated]"))
        XCTAssertLessThan(truncated.utf8.count, text.utf8.count)
        XCTAssertEqual(TokenCalculationService.middleTruncate(text: truncated, maxTokens: 30), truncated)
        XCTAssertNotNil(truncated.data(using: .utf8))
    }

    func testComponentBreakdownPreservesDuplicatePromptAndNonFileTotals() {
        let breakdown = TokenCalculationService.calculateComponentBreakdown(
            promptText: "12345678",
            selectedInstructionsText: "1234",
            fileTreeText: "12345678",
            gitDiffText: "1234",
            metadataText: "1234",
            duplicateUserInstructionsAtTop: true
        )

        XCTAssertEqual(breakdown.prompt, 2)
        XCTAssertEqual(breakdown.duplicatePrompt, 2)
        XCTAssertEqual(breakdown.instructions, 1)
        XCTAssertEqual(breakdown.fileTree, 2)
        XCTAssertEqual(breakdown.gitDiff, 1)
        XCTAssertEqual(breakdown.metadata, 1)
        XCTAssertEqual(breakdown.promptDisplay, 4)
        XCTAssertEqual(breakdown.totalNonFile, 9)
    }

    func testPromptEntryEvaluationDistinguishesFullSliceAndCodemapModes() async {
        let service = TokenCalculationService()
        let fullID = UUID()
        let sliceID = UUID()
        let codemapID = UUID()
        let entries = [
            PromptFileEntrySnapshot(
                fileID: fullID,
                relativePath: "Full.swift",
                isCodemapRequested: false,
                ranges: nil,
                cachedFullTokenCount: nil,
                loadedContent: "one\ntwo\nthree\n",
                codeMapContent: nil,
                availableCodeMapTokenCount: 0
            ),
            PromptFileEntrySnapshot(
                fileID: sliceID,
                relativePath: "Slice.swift",
                isCodemapRequested: false,
                ranges: [LineRange(start: 2, end: 2)],
                cachedFullTokenCount: nil,
                loadedContent: "one\ntwo\nthree\n",
                codeMapContent: nil,
                availableCodeMapTokenCount: 0
            ),
            PromptFileEntrySnapshot(
                fileID: codemapID,
                relativePath: "Map.swift",
                isCodemapRequested: true,
                ranges: nil,
                cachedFullTokenCount: 20,
                loadedContent: nil,
                codeMapContent: "struct Map {}",
                availableCodeMapTokenCount: 4
            )
        ]

        let result = await service.evaluatePromptEntries(entries)

        XCTAssertEqual(result.entryResultsByFileID[fullID]?.renderMode, .full)
        XCTAssertEqual(result.entryResultsByFileID[sliceID]?.renderMode, .slice)
        XCTAssertEqual(result.entryResultsByFileID[codemapID]?.renderMode, .codemap)
        XCTAssertEqual(result.fullCount, 1)
        XCTAssertEqual(result.sliceCount, 1)
        XCTAssertEqual(result.codemapCount, 1)
        XCTAssertEqual(result.codeMapFileCount, 1)
        XCTAssertTrue(result.codeMapContent.contains("struct Map"))
    }

    func testOverlappingScopedCalculationsCompleteIndependently() async throws {
        let gate = TokenCalculationOperationGate()
        let service = TokenCalculationService { snapshot in
            try await gate.execute(snapshot: snapshot)
        }
        let firstSnapshot = makeSnapshot(promptText: "first")
        let secondSnapshot = makeSnapshot(promptText: "second")
        let firstExpected = makeResult(total: 11)
        let secondExpected = makeResult(total: 22)

        let firstTask = Task {
            try await service.calculatePromptStatsScoped(snapshot: firstSnapshot)
        }
        await gate.waitUntilStarted("first")
        let secondTask = Task {
            try await service.calculatePromptStatsScoped(snapshot: secondSnapshot)
        }
        await gate.waitUntilStarted("second")

        await gate.succeed("second", with: secondExpected)
        await gate.succeed("first", with: firstExpected)

        let firstResult = try await firstTask.value
        let secondResult = try await secondTask.value
        XCTAssertEqual(firstResult.totalTokenCount, 11)
        XCTAssertEqual(secondResult.totalTokenCount, 22)
    }

    func testScopedCancellationCancelsOnlyTheCancelledCall() async throws {
        let gate = TokenCalculationOperationGate()
        let service = TokenCalculationService { snapshot in
            try await gate.execute(snapshot: snapshot)
        }
        let cancelledSnapshot = makeSnapshot(promptText: "cancelled")
        let survivingSnapshot = makeSnapshot(promptText: "surviving")
        let survivingExpected = makeResult(total: 33)

        let cancelledTask = Task {
            try await service.calculatePromptStatsScoped(snapshot: cancelledSnapshot)
        }
        let survivingTask = Task {
            try await service.calculatePromptStatsScoped(snapshot: survivingSnapshot)
        }
        await gate.waitUntilStarted("cancelled")
        await gate.waitUntilStarted("surviving")

        cancelledTask.cancel()
        await gate.waitUntilCancelled("cancelled")
        await gate.succeed("surviving", with: survivingExpected)

        do {
            _ = try await cancelledTask.value
            XCTFail("Expected scoped cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let survivingResult = try await survivingTask.value
        XCTAssertEqual(survivingResult.totalTokenCount, 33)
    }

    func testScopedCancellationThrowsWhenOperationReturnsAfterCancellation() async {
        let expectedResult = makeResult(total: 66)
        let gate = TokenCalculationCancellationIgnoringGate(result: expectedResult)
        let service = TokenCalculationService { _ in
            await gate.execute()
        }
        let task = Task {
            try await service.calculatePromptStatsScoped(snapshot: makeSnapshot(promptText: "ignores-cancellation"))
        }
        await gate.waitUntilStarted()

        task.cancel()
        await gate.waitUntilCancellationObserved()

        do {
            _ = try await task.value
            XCTFail("Expected caller cancellation to win over a successful operation result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testAlreadyCancelledScopedCallerCancelsDetachedOperation() async {
        let entryGate = TokenCalculationEntryGate()
        let operationGate = TokenCalculationOperationGate()
        let service = TokenCalculationService { snapshot in
            try await operationGate.execute(snapshot: snapshot)
        }
        let snapshot = makeSnapshot(promptText: "already-cancelled")
        let task = Task {
            await entryGate.wait()
            return try await service.calculatePromptStatsScoped(snapshot: snapshot)
        }

        await entryGate.waitUntilWaiting()
        task.cancel()
        await entryGate.release()
        await operationGate.waitUntilStarted("already-cancelled")
        await operationGate.waitUntilCancelled("already-cancelled")

        do {
            _ = try await task.value
            XCTFail("Expected already-cancelled caller to propagate cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testScopedCalculationPropagatesExactOperationError() async {
        let gate = TokenCalculationOperationGate()
        let service = TokenCalculationService { snapshot in
            try await gate.execute(snapshot: snapshot)
        }
        let snapshot = makeSnapshot(promptText: "failure")
        let task = Task {
            try await service.calculatePromptStatsScoped(snapshot: snapshot)
        }
        await gate.waitUntilStarted("failure")
        await gate.fail("failure", with: TokenCalculationTestError.expected(47))

        do {
            _ = try await task.value
            XCTFail("Expected operation error to propagate")
        } catch let error as TokenCalculationTestError {
            XCTAssertEqual(error, .expected(47))
        } catch {
            XCTFail("Expected TokenCalculationTestError, got \(error)")
        }
    }

    func testLegacyCalculationRemainsLatestCallWinsAndNonthrowing() async {
        let gate = TokenCalculationOperationGate()
        let service = TokenCalculationService { snapshot in
            try await gate.execute(snapshot: snapshot)
        }
        let firstSnapshot = makeSnapshot(promptText: "legacy-first")
        let secondSnapshot = makeSnapshot(promptText: "legacy-second")
        let secondExpected = makeResult(total: 44)

        let firstTask = Task {
            await service.calculatePromptStats(snapshot: firstSnapshot)
        }
        await gate.waitUntilStarted("legacy-first")
        let secondTask = Task {
            await service.calculatePromptStats(snapshot: secondSnapshot)
        }
        await gate.waitUntilCancelled("legacy-first")
        await gate.waitUntilStarted("legacy-second")
        await gate.succeed("legacy-second", with: secondExpected)

        let firstResult = await firstTask.value
        let secondResult = await secondTask.value
        assertZeroResult(firstResult)
        XCTAssertEqual(secondResult.totalTokenCount, 44)
    }

    func testLegacyStaleCompletionCannotHideNewerTaskFromShutdown() async {
        let gate = TokenCalculationOperationGate()
        let service = TokenCalculationService { snapshot in
            try await gate.execute(snapshot: snapshot)
        }
        let firstSnapshot = makeSnapshot(promptText: "stale-first")
        let secondSnapshot = makeSnapshot(promptText: "stale-second")
        let secondExpected = makeResult(total: 55)

        let firstTask = Task {
            await service.calculatePromptStats(snapshot: firstSnapshot)
        }
        await gate.waitUntilStarted("stale-first")
        let secondTask = Task {
            await service.calculatePromptStats(snapshot: secondSnapshot)
        }
        await gate.waitUntilCancelled("stale-first")
        await gate.waitUntilStarted("stale-second")

        let firstResult = await firstTask.value
        assertZeroResult(firstResult)
        await service.shutdown()

        let secondWasCancelled = await gate.wasCancelled("stale-second")
        if !secondWasCancelled {
            await gate.succeed("stale-second", with: secondExpected)
        }
        let secondResult = await secondTask.value
        XCTAssertTrue(secondWasCancelled)
        assertZeroResult(secondResult)
    }

    func testScopedAndLegacyProductionCalculationsHaveFieldForFieldParityExcludingUUIDs() async throws {
        let service = TokenCalculationService()
        let fullID = UUID()
        let sliceID = UUID()
        let codemapID = UUID()
        let snapshot = TokenCalculationSnapshot(
            promptText: "User prompt",
            selectedInstructionsText: "Selected instructions",
            duplicateUserInstructionsAtTop: true,
            promptEntries: [
                PromptFileEntrySnapshot(
                    fileID: fullID,
                    relativePath: "Sources/Full.swift",
                    isCodemapRequested: false,
                    ranges: nil,
                    cachedFullTokenCount: nil,
                    loadedContent: "one\ntwo\nthree\n",
                    codeMapContent: nil,
                    availableCodeMapTokenCount: 0
                ),
                PromptFileEntrySnapshot(
                    fileID: sliceID,
                    relativePath: "Sources/Slice.swift",
                    isCodemapRequested: false,
                    ranges: [LineRange(start: 2, end: 2)],
                    cachedFullTokenCount: nil,
                    loadedContent: "alpha\nbeta\ngamma\n",
                    codeMapContent: nil,
                    availableCodeMapTokenCount: 0
                ),
                PromptFileEntrySnapshot(
                    fileID: codemapID,
                    relativePath: "Sources/Map.swift",
                    isCodemapRequested: true,
                    ranges: nil,
                    cachedFullTokenCount: 20,
                    loadedContent: nil,
                    codeMapContent: "struct Map {}",
                    availableCodeMapTokenCount: 4
                )
            ],
            fileTree: .rendered("Sources\n├── Full.swift\n├── Map.swift\n└── Slice.swift")
        )

        let legacy = await service.calculatePromptStats(snapshot: snapshot)
        let scoped = try await service.calculatePromptStatsScoped(snapshot: snapshot)

        assertEquivalentResults(legacy, scoped)
    }

    private func makeSnapshot(promptText: String) -> TokenCalculationSnapshot {
        TokenCalculationSnapshot(
            promptText: promptText,
            selectedInstructionsText: "",
            duplicateUserInstructionsAtTop: false,
            promptEntries: [],
            fileTree: .none
        )
    }

    private func makeResult(total: Int) -> TokenCalculationResult {
        TokenCalculationResult(
            totalTokenCount: total,
            totalTokenCountFilesOnly: total,
            fileTokenInfo: [:],
            folderTokenInfo: [:],
            tokenCountString: "\(total)",
            tokenCountFilesOnlyString: "\(total)",
            charCount: total,
            fileTreeContent: "tree-\(total)",
            fileTreeTokenCount: Double(total),
            fileTreeTokenCountRaw: total,
            codeMapContent: "map-\(total)",
            codeMapFileCount: total,
            codeMapTokenCount: total
        )
    }

    private func assertZeroResult(
        _ result: TokenCalculationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.totalTokenCount, 0, file: file, line: line)
        XCTAssertEqual(result.totalTokenCountFilesOnly, 0, file: file, line: line)
        XCTAssertTrue(result.fileTokenInfo.isEmpty, file: file, line: line)
        XCTAssertTrue(result.folderTokenInfo.isEmpty, file: file, line: line)
        XCTAssertEqual(result.tokenCountString, "0.00k", file: file, line: line)
        XCTAssertEqual(result.tokenCountFilesOnlyString, "0.00k", file: file, line: line)
        XCTAssertEqual(result.charCount, 0, file: file, line: line)
        XCTAssertEqual(result.fileTreeContent, "", file: file, line: line)
        XCTAssertEqual(result.fileTreeTokenCount, 0, file: file, line: line)
        XCTAssertEqual(result.fileTreeTokenCountRaw, 0, file: file, line: line)
        XCTAssertEqual(result.codeMapContent, "", file: file, line: line)
        XCTAssertEqual(result.codeMapFileCount, 0, file: file, line: line)
        XCTAssertEqual(result.codeMapTokenCount, 0, file: file, line: line)
    }

    private func assertEquivalentResults(
        _ lhs: TokenCalculationResult,
        _ rhs: TokenCalculationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.totalTokenCount, rhs.totalTokenCount, file: file, line: line)
        XCTAssertEqual(lhs.totalTokenCountFilesOnly, rhs.totalTokenCountFilesOnly, file: file, line: line)
        XCTAssertEqual(lhs.tokenCountString, rhs.tokenCountString, file: file, line: line)
        XCTAssertEqual(lhs.tokenCountFilesOnlyString, rhs.tokenCountFilesOnlyString, file: file, line: line)
        XCTAssertEqual(lhs.charCount, rhs.charCount, file: file, line: line)
        XCTAssertEqual(lhs.fileTreeContent, rhs.fileTreeContent, file: file, line: line)
        XCTAssertEqual(lhs.fileTreeTokenCount, rhs.fileTreeTokenCount, file: file, line: line)
        XCTAssertEqual(lhs.fileTreeTokenCountRaw, rhs.fileTreeTokenCountRaw, file: file, line: line)
        XCTAssertEqual(lhs.codeMapContent, rhs.codeMapContent, file: file, line: line)
        XCTAssertEqual(lhs.codeMapFileCount, rhs.codeMapFileCount, file: file, line: line)
        XCTAssertEqual(lhs.codeMapTokenCount, rhs.codeMapTokenCount, file: file, line: line)
        XCTAssertEqual(Set(lhs.fileTokenInfo.keys), Set(rhs.fileTokenInfo.keys), file: file, line: line)
        XCTAssertEqual(Set(lhs.folderTokenInfo.keys), Set(rhs.folderTokenInfo.keys), file: file, line: line)

        for key in lhs.fileTokenInfo.keys {
            assertEquivalentTokenInfo(lhs.fileTokenInfo[key], rhs.fileTokenInfo[key], file: file, line: line)
        }
        for key in lhs.folderTokenInfo.keys {
            assertEquivalentTokenInfo(lhs.folderTokenInfo[key], rhs.folderTokenInfo[key], file: file, line: line)
        }
    }

    private func assertEquivalentTokenInfo(
        _ lhs: TokenInfo?,
        _ rhs: TokenInfo?,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(lhs?.count, rhs?.count, file: file, line: line)
        XCTAssertEqual(lhs?.fullCount, rhs?.fullCount, file: file, line: line)
        XCTAssertEqual(lhs?.codemapCount, rhs?.codemapCount, file: file, line: line)
        XCTAssertEqual(lhs?.formatted, rhs?.formatted, file: file, line: line)
        XCTAssertEqual(lhs?.percentage, rhs?.percentage, file: file, line: line)
    }
}

private enum TokenCalculationTestError: Error, Equatable {
    case expected(Int)
}

private actor TokenCalculationCancellationIgnoringGate {
    private let result: TokenCalculationResult
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var isStarted = false
    private var didObserveCancellation = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var cancellationContinuations: [CheckedContinuation<Void, Never>] = []

    init(result: TokenCalculationResult) {
        self.result = result
    }

    func execute() async -> TokenCalculationResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                isStarted = true
                let continuations = startContinuations
                startContinuations.removeAll()
                continuations.forEach { $0.resume() }
                if didObserveCancellation {
                    continuation.resume()
                } else {
                    operationContinuation = continuation
                }
            }
        } onCancel: {
            Task {
                await self.observeCancellation()
            }
        }
        return result
    }

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !didObserveCancellation else { return }
        await withCheckedContinuation { continuation in
            cancellationContinuations.append(continuation)
        }
    }

    private func observeCancellation() {
        didObserveCancellation = true
        operationContinuation?.resume()
        operationContinuation = nil
        let continuations = cancellationContinuations
        cancellationContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor TokenCalculationEntryGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isWaiting = false
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isWaiting = true
        let continuations = waitingContinuations
        waitingContinuations.removeAll()
        continuations.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilWaiting() async {
        guard !isWaiting else { return }
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor TokenCalculationOperationGate {
    private var continuations: [String: CheckedContinuation<TokenCalculationResult, Error>] = [:]
    private var startedKeys: Set<String> = []
    private var cancelledKeys: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func execute(snapshot: TokenCalculationSnapshot) async throws -> TokenCalculationResult {
        let key = snapshot.promptText
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startedKeys.insert(key)
                if cancelledKeys.contains(key) {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[key] = continuation
                }
                resumeStartWaiters(for: key)
            }
        } onCancel: {
            Task {
                await self.cancel(key)
            }
        }
    }

    func waitUntilStarted(_ key: String) async {
        guard !startedKeys.contains(key) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[key, default: []].append(continuation)
        }
    }

    func waitUntilCancelled(_ key: String) async {
        guard !cancelledKeys.contains(key) else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters[key, default: []].append(continuation)
        }
    }

    func wasCancelled(_ key: String) -> Bool {
        cancelledKeys.contains(key)
    }

    func succeed(_ key: String, with result: TokenCalculationResult) {
        continuations.removeValue(forKey: key)?.resume(returning: result)
    }

    func fail(_ key: String, with error: Error) {
        continuations.removeValue(forKey: key)?.resume(throwing: error)
    }

    private func cancel(_ key: String) {
        cancelledKeys.insert(key)
        continuations.removeValue(forKey: key)?.resume(throwing: CancellationError())
        let waiters = cancellationWaiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0.resume() }
    }

    private func resumeStartWaiters(for key: String) {
        let waiters = startWaiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0.resume() }
    }
}
