@testable import RepoPromptApp
import XCTest

final class AgentContextFileSizeEstimatorTests: XCTestCase {
    func testEstimateUsesCanonicalFormulaCachesWithinGenerationAndInvalidatesAcrossGeneration() async {
        let tracker = MetadataReadTracker(byteCount: 4096)
        let file = makeFile(path: "/workspace/Cached.swift")
        let estimator = AgentContextFileSizeEstimator { path in
            await tracker.read(path: path, isMainThread: false)
        }

        let first = await estimator.estimate(for: file, rootGeneration: 7)
        let cached = await estimator.estimate(for: file, rootGeneration: 7)
        let invalidated = await estimator.estimate(for: file, rootGeneration: 8)
        let snapshot = await tracker.snapshot()

        XCTAssertEqual(first.estimate, .known(TokenCalculationService.estimateTokens(utf8ByteCount: 4096)))
        XCTAssertEqual(cached.estimate, first.estimate)
        XCTAssertEqual(invalidated.estimate, first.estimate)
        XCTAssertEqual(snapshot.readCount, 2)
        XCTAssertEqual(snapshot.paths, [file.standardizedFullPath, file.standardizedFullPath])
    }

    func testOlderGenerationDoesNotCancelNewerReadOrRollBackAuthority() async {
        let reader = BlockingMetadataReader()
        let file = makeFile(path: "/workspace/Generation.swift")
        let estimator = AgentContextFileSizeEstimator { path in
            try await reader.read(path: path)
        }
        let currentTask = Task {
            await estimator.estimate(for: file, rootGeneration: 8)
        }
        while await reader.paths.isEmpty {
            await Task.yield()
        }

        let staleTask = Task {
            await estimator.estimate(for: file, rootGeneration: 7)
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await reader.release()
        let current = await currentTask.value
        let stale = await staleTask.value
        let paths = await reader.paths

        XCTAssertEqual(current.estimate, .known(TokenCalculationService.estimateTokens(utf8ByteCount: 100)))
        XCTAssertEqual(stale.estimate, .notRequested)
        XCTAssertEqual(paths, [file.standardizedFullPath])
    }

    func testMissingDirectoryNegativeAndMetadataErrorAreUnavailable() async throws {
        let directory = try makeTestDirectory(name: "ContextBrowseMetadataDirectory")
        let missing = makeFile(path: directory.appendingPathComponent("Missing.swift").path)
        let directoryFile = makeFile(path: directory.path)
        let defaultEstimator = AgentContextFileSizeEstimator()
        let negativeEstimator = AgentContextFileSizeEstimator { _ in
            AgentContextFileMetadataSnapshot(byteCount: -1, modificationDate: nil, isRegularFile: true)
        }
        let errorEstimator = AgentContextFileSizeEstimator { _ in
            throw MetadataError.unreadable
        }

        let missingResult = await defaultEstimator.estimate(for: missing, rootGeneration: 1)
        let directoryResult = await defaultEstimator.estimate(for: directoryFile, rootGeneration: 1)
        let negativeResult = await negativeEstimator.estimate(for: missing, rootGeneration: 1)
        let errorResult = await errorEstimator.estimate(for: missing, rootGeneration: 1)

        XCTAssertEqual(missingResult.estimate, .unavailable)
        XCTAssertEqual(directoryResult.estimate, .unavailable)
        XCTAssertEqual(negativeResult.estimate, .unavailable)
        XCTAssertEqual(errorResult.estimate, .unavailable)
    }

    @MainActor
    func testBatchPreservesIdentityAndRunsMetadataOffMainActorWithBoundedConcurrency() async {
        let tracker = MetadataReadTracker(byteCount: 100)
        let rootID = UUID()
        let files = (0 ..< 40).map {
            makeFile(path: "/workspace/File\($0).swift", rootID: rootID)
        }
        let mainQueueMarker = MainQueueMarker()
        let estimator = AgentContextFileSizeEstimator(maximumConcurrentReads: 4) { path in
            await tracker.beginRead(path: path, isMainThread: mainQueueMarker.isOnMainQueue())
            for _ in 0 ..< 10 {
                await Task.yield()
            }
            return await tracker.endRead()
        }
        let requests = files.reversed().map {
            AgentContextFileSizeEstimateRequest(file: $0, rootGeneration: 3)
        }

        let results = await estimator.estimates(for: requests)
        let snapshot = await tracker.snapshot()

        XCTAssertEqual(results.map(\.fileID), requests.map(\.file.id))
        XCTAssertEqual(Set(results.map(\.estimate)), [.known(TokenCalculationService.estimateTokens(utf8ByteCount: 100))])
        XCTAssertEqual(snapshot.readCount, files.count)
        XCTAssertLessThanOrEqual(snapshot.maximumConcurrentReads, 4)
        XCTAssertGreaterThan(snapshot.maximumConcurrentReads, 1)
        XCTAssertFalse(snapshot.observedMainThreadRead)
    }

    func testConcurrentSingleFileCallsShareGlobalReadBound() async {
        let tracker = MetadataReadTracker(byteCount: 100)
        let rootID = UUID()
        let files = (0 ..< 40).map {
            makeFile(path: "/workspace/Concurrent\($0).swift", rootID: rootID)
        }
        let estimator = AgentContextFileSizeEstimator(maximumConcurrentReads: 4) { path in
            await tracker.beginRead(path: path, isMainThread: false)
            for _ in 0 ..< 50 {
                await Task.yield()
            }
            return await tracker.endRead()
        }

        let results = await withTaskGroup(of: AgentContextFileSizeEstimateResult.self) { group in
            for file in files {
                group.addTask {
                    await estimator.estimate(for: file, rootGeneration: 3)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let snapshot = await tracker.snapshot()

        XCTAssertEqual(results.count, files.count)
        XCTAssertLessThanOrEqual(snapshot.maximumConcurrentReads, 4)
        XCTAssertGreaterThan(snapshot.maximumConcurrentReads, 1)
    }

    func testConcurrentDuplicateSingleFileCallsShareOneMetadataRead() async {
        let reader = BlockingMetadataReader()
        let file = makeFile(path: "/workspace/ConcurrentDuplicate.swift")
        let estimator = AgentContextFileSizeEstimator { path in
            try await reader.read(path: path)
        }
        let tasks = (0 ..< 20).map { _ in
            Task { await estimator.estimate(for: file, rootGeneration: 4) }
        }
        while await reader.paths.isEmpty {
            await Task.yield()
        }
        await reader.release()
        var results: [AgentContextFileSizeEstimateResult] = []
        for task in tasks {
            await results.append(task.value)
        }

        XCTAssertEqual(Set(results.map(\.estimate)), [.known(TokenCalculationService.estimateTokens(utf8ByteCount: 100))])
        let paths = await reader.paths
        XCTAssertEqual(paths, [file.standardizedFullPath])
    }

    func testCanceledQueuedSingleFileCallNeverStartsMetadataRead() async {
        let reader = BlockingMetadataReader()
        let first = makeFile(path: "/workspace/First.swift")
        let queued = makeFile(path: "/workspace/Queued.swift", rootID: first.rootID)
        let estimator = AgentContextFileSizeEstimator(maximumConcurrentReads: 1) { path in
            try await reader.read(path: path)
        }
        let firstTask = Task { await estimator.estimate(for: first, rootGeneration: 1) }
        while await reader.paths.isEmpty {
            await Task.yield()
        }
        let queuedTask = Task { await estimator.estimate(for: queued, rootGeneration: 1) }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        queuedTask.cancel()
        let canceled = await queuedTask.value
        await reader.release()
        _ = await firstTask.value

        XCTAssertEqual(canceled.estimate, .notRequested)
        let paths = await reader.paths
        XCTAssertEqual(paths, [first.standardizedFullPath])
    }

    func testPreCanceledReadLeavesNoPermitState() async {
        let estimator = AgentContextFileSizeEstimator(maximumConcurrentReads: 1) { _ in
            AgentContextFileMetadataSnapshot(byteCount: 100, modificationDate: nil, isRegularFile: true)
        }
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return await estimator.estimate(
                for: self.makeFile(path: "/workspace/PreCanceled.swift"),
                rootGeneration: 1
            )
        }

        task.cancel()
        _ = await task.value
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        let retainedPermitStateCount = await estimator.readPermitStateCountForTesting()
        XCTAssertEqual(retainedPermitStateCount, 0)
    }

    func testPruneCachesRetainsOnlyCurrentRoots() async {
        let tracker = MetadataReadTracker(byteCount: 100)
        let retained = makeFile(path: "/workspace/Retained.swift")
        let removed = makeFile(path: "/workspace/Removed.swift")
        let estimator = AgentContextFileSizeEstimator { path in
            await tracker.read(path: path, isMainThread: false)
        }
        _ = await estimator.estimate(for: retained, rootGeneration: 1)
        _ = await estimator.estimate(for: removed, rootGeneration: 1)

        await estimator.pruneCaches(retainingRootIDs: [retained.rootID])
        _ = await estimator.estimate(for: retained, rootGeneration: 1)
        _ = await estimator.estimate(for: removed, rootGeneration: 1)

        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.paths.count(where: { $0 == retained.standardizedFullPath }), 1)
        XCTAssertEqual(snapshot.paths.count(where: { $0 == removed.standardizedFullPath }), 2)
    }

    func testDuplicateBatchIdentityReadsMetadataOnceAndMapsEveryRequest() async {
        let tracker = MetadataReadTracker(byteCount: 200)
        let file = makeFile(path: "/workspace/Duplicate.swift")
        let estimator = AgentContextFileSizeEstimator { path in
            await tracker.read(path: path, isMainThread: false)
        }
        let request = AgentContextFileSizeEstimateRequest(file: file, rootGeneration: 4)

        let results = await estimator.estimates(for: [request, request])
        let snapshot = await tracker.snapshot()

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(snapshot.readCount, 1)
    }

    func testCanceledMetadataReadIsNotCachedAndRetriesSuccessfully() async {
        let file = makeFile(path: "/workspace/Cancelled.swift")
        let reader = CancellationRetryMetadataReader()
        let estimator = AgentContextFileSizeEstimator { _ in
            try await reader.read()
        }
        let task = Task {
            await estimator.estimate(for: file, rootGeneration: 1)
        }
        while await reader.readCount == 0 {
            await Task.yield()
        }
        task.cancel()

        let canceled = await task.value
        let retried = await estimator.estimate(for: file, rootGeneration: 1)
        let readCount = await reader.readCount

        XCTAssertEqual(canceled.estimate, .notRequested)
        XCTAssertEqual(retried.estimate, .known(TokenCalculationService.estimateTokens(utf8ByteCount: 100)))
        XCTAssertEqual(readCount, 2)
    }

    private func makeFile(
        path: String,
        id: UUID = UUID(),
        rootID: UUID = UUID()
    ) -> AgentContextFileBrowseFile {
        AgentContextFileBrowseFile(
            id: id,
            rootID: rootID,
            rootGeneration: 1,
            parentFolderID: nil,
            name: URL(fileURLWithPath: path).lastPathComponent,
            standardizedRelativePath: URL(fileURLWithPath: path).lastPathComponent,
            standardizedFullPath: StandardizedPath.absolute(path),
            projectedDisplayPath: URL(fileURLWithPath: path).lastPathComponent,
            projectedDirectoryPath: "",
            modificationDate: nil,
            supportsCodemap: true
        )
    }

    private enum MetadataError: Error {
        case unreadable
    }
}

private actor BlockingMetadataReader {
    private(set) var paths: [String] = []
    private var isReleased = false

    func read(path: String) async throws -> AgentContextFileMetadataSnapshot {
        paths.append(path)
        while !isReleased {
            try Task.checkCancellation()
            await Task.yield()
        }
        return AgentContextFileMetadataSnapshot(byteCount: 100, modificationDate: nil, isRegularFile: true)
    }

    func release() {
        isReleased = true
    }
}

private actor CancellationRetryMetadataReader {
    private(set) var readCount = 0

    func read() async throws -> AgentContextFileMetadataSnapshot {
        readCount += 1
        if readCount == 1 {
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }
        return AgentContextFileMetadataSnapshot(byteCount: 100, modificationDate: nil, isRegularFile: true)
    }
}

private final class MainQueueMarker: @unchecked Sendable {
    private let key = DispatchSpecificKey<Void>()

    init() {
        DispatchQueue.main.setSpecific(key: key, value: ())
    }

    func isOnMainQueue() -> Bool {
        DispatchQueue.getSpecific(key: key) != nil
    }
}

private actor MetadataReadTracker {
    struct Snapshot {
        let readCount: Int
        let maximumConcurrentReads: Int
        let observedMainThreadRead: Bool
        let paths: [String]
    }

    private let byteCount: Int64
    private var readCount = 0
    private var activeReads = 0
    private var maximumConcurrentReads = 0
    private var observedMainThreadRead = false
    private var paths: [String] = []

    init(byteCount: Int64) {
        self.byteCount = byteCount
    }

    func read(path: String, isMainThread: Bool) -> AgentContextFileMetadataSnapshot {
        recordStart(path: path, isMainThread: isMainThread)
        activeReads -= 1
        return metadataSnapshot()
    }

    func beginRead(path: String, isMainThread: Bool) {
        recordStart(path: path, isMainThread: isMainThread)
    }

    func endRead() -> AgentContextFileMetadataSnapshot {
        activeReads -= 1
        return metadataSnapshot()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            readCount: readCount,
            maximumConcurrentReads: maximumConcurrentReads,
            observedMainThreadRead: observedMainThreadRead,
            paths: paths
        )
    }

    private func recordStart(path: String, isMainThread: Bool) {
        readCount += 1
        activeReads += 1
        maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
        observedMainThreadRead = observedMainThreadRead || isMainThread
        paths.append(path)
    }

    private func metadataSnapshot() -> AgentContextFileMetadataSnapshot {
        AgentContextFileMetadataSnapshot(
            byteCount: byteCount,
            modificationDate: Date(timeIntervalSinceReferenceDate: 123),
            isRegularFile: true
        )
    }
}
