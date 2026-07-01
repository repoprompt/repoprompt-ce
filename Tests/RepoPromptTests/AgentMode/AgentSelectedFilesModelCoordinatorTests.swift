@testable import RepoPrompt
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
        let resolver = ProgressiveCodemapModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }
        let request = makeRequest(name: "A.swift", codeMapUsage: .auto, codemapAutoEnabled: true)

        XCTAssertEqual(coordinator.refreshIfNeeded(request), .started)
        let didDisplayFileRows = await waitUntilDisplayedModel(promptText: "A.swift", in: coordinator)
        let didStartFullCodemapModel = await resolver.waitUntilStartCount(.auto, count: 1)

        XCTAssertTrue(didDisplayFileRows)
        XCTAssertTrue(didStartFullCodemapModel)
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertEqual(coordinator.rowSplit.fileRows.count, 1)
        XCTAssertEqual(coordinator.rowSplit.codemapRows.count, 0)
        let startedUsages = await resolver.startedUsages()
        XCTAssertEqual(startedUsages, [.none, .auto])

        await resolver.releaseNext(.auto)
        let didLoadFullModel = await waitUntilModel(promptText: "A.swift", in: coordinator)

        XCTAssertTrue(didLoadFullModel)
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertEqual(coordinator.debugStats.resolverStarts, 1)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 1)
    }

    @MainActor
    func testIdentityChangeCancelsOldLoadAndAcceptsNewestResultOnly() async {
        let resolver = GatedModelResolver()
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
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

        await resolver.releaseNext("B.swift")
        let didLoadNewestModel = await waitUntilModel(promptText: "B.swift", in: coordinator)
        XCTAssertTrue(didLoadNewestModel)
        XCTAssertEqual(coordinator.model?.source.promptText, "B.swift")
        XCTAssertEqual(coordinator.debugStats.resolverStarts, 2)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 1)
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

        XCTAssertEqual(coordinator.refreshIfNeeded(requestB), .skippedLoaded)
        XCTAssertEqual(coordinator.model?.source.promptText, "B.swift")
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertEqual(coordinator.debugStats.cancellations, 1)

        await resolver.releaseNext("A.swift")
        await drainCancelledTask()

        XCTAssertEqual(coordinator.model?.source.promptText, "B.swift")
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 2)
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

    private func makeRequest(
        name: String,
        codeMapUsage: CodeMapUsage = .none,
        codemapAutoEnabled: Bool = false
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
            codeMapUsage: codeMapUsage
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

private actor ProgressiveCodemapModelResolver {
    private var usages: [CodeMapUsage] = []
    private var startedCounts: [String: Int] = [:]
    private var continuations: [String: [CheckedContinuation<Void, Never>]] = [:]

    func resolve(_ request: AgentSelectedFilesModelRequest) async -> AgentContextExportModel {
        usages.append(request.codeMapUsage)
        let key = request.codeMapUsage.rawValue
        startedCounts[key, default: 0] += 1
        if request.codeMapUsage == .auto || request.codeMapUsage == .complete {
            await withCheckedContinuation { continuation in
                continuations[key, default: []].append(continuation)
            }
        }
        return makeModel(for: request)
    }

    func waitUntilStartCount(_ usage: CodeMapUsage, count: Int) async -> Bool {
        let key = usage.rawValue
        for _ in 0 ..< 500 {
            if startedCounts[key, default: 0] >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return startedCounts[key, default: 0] >= count
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
}

private func makeModel(for request: AgentSelectedFilesModelRequest) -> AgentContextExportModel {
    let fileName = request.source.promptText
    let row = AgentContextExportRow(
        id: ResolvedPromptFileEntryID(fileID: UUID(), mode: .fullFile, lineRanges: nil),
        kind: .full,
        rootID: UUID(),
        relativePath: "Sources/\(fileName)",
        displayPath: "Sources/\(fileName)",
        displayName: fileName,
        directoryDisplay: "Sources",
        lineRanges: nil,
        canRemove: true,
        directContentPath: "/tmp/RepoPromptTests/Sources/\(fileName)"
    )
    return AgentContextExportModel(
        source: request.source,
        lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
        rows: [row],
        missingPaths: [],
        invalidPaths: [],
        codemapPresentation: .empty
    )
}
