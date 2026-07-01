import Foundation

struct FileSystemSeededInventoryRecord: Equatable {
    let relativePath: String
    let isDirectory: Bool
}

struct FileSystemSeededInventoryPreparationStatistics: Equatable {
    let recordCount: UInt64
    let ordinaryFileCount: UInt64
    let ordinaryDirectoryCount: UInt64
    let peakResidentPathBytes: Int
}

/// Immutable, authenticated inventory storage for a seeded root.
///
/// The target plan remains the single owner of root-sized path bytes. Readers
/// decode one record at a time, so validating or installing the inventory does
/// not create a second target-sized collection of Swift strings.
final class FileSystemSeededInventoryManifest: @unchecked Sendable {
    private struct Checkpoint {
        let relativePathBytes: Data
        let recordOffset: Int64
    }

    private static let maximumCheckpointCount = 1024

    private let planManifest: WorkspaceRootTargetSeedPlanManifestLease?
    private let testingRecords: [FileSystemSeededInventoryRecord]?
    private let checkpoints: [Checkpoint]
    let statistics: FileSystemSeededInventoryPreparationStatistics

    convenience init(validating planHandle: WorkspaceRootTargetSeedPlanHandle) throws {
        try self.init(validating: planHandle.planManifest)
    }

    init(validating planManifest: WorkspaceRootTargetSeedPlanManifestLease) throws {
        let reader = try planManifest.makeReader()
        var recordCount: UInt64 = 0
        var ordinaryFileCount: UInt64 = 0
        var ordinaryDirectoryCount: UInt64 = 0
        var peakResidentPathBytes = 0
        var checkpointPathBytes = 0
        let expectedVisibleCount = planManifest.footer.ordinaryFileCount
            + planManifest.footer.ordinaryDirectoryCount
        let checkpointStride = max(
            UInt64(1),
            (expectedVisibleCount + UInt64(Self.maximumCheckpointCount) - 1)
                / UInt64(Self.maximumCheckpointCount)
        )
        var checkpoints: [Checkpoint] = []
        checkpoints.reserveCapacity(Int(min(UInt64(Self.maximumCheckpointCount), expectedVisibleCount)))

        while true {
            let recordOffset = try reader.nextRecordFileOffset()
            guard let record = try reader.next() else { break }
            try Task.checkCancellation()
            let path = try fileSystemValidatedSeedPath(record.relativePathBytes)
            let decodedPathBytes = record.relativePathBytes.count + path.utf8.count
            switch record.disposition {
            case .ordinaryFile:
                if recordCount.isMultiple(of: checkpointStride) {
                    checkpoints.append(Checkpoint(
                        relativePathBytes: record.relativePathBytes,
                        recordOffset: recordOffset
                    ))
                    checkpointPathBytes += record.relativePathBytes.count
                }
                ordinaryFileCount += 1
                recordCount += 1
            case .ordinaryDirectory:
                if recordCount.isMultiple(of: checkpointStride) {
                    checkpoints.append(Checkpoint(
                        relativePathBytes: record.relativePathBytes,
                        recordOffset: recordOffset
                    ))
                    checkpointPathBytes += record.relativePathBytes.count
                }
                ordinaryDirectoryCount += 1
                recordCount += 1
            case .policyIgnoredTrackedFile, .baseTombstone:
                break
            }
            peakResidentPathBytes = max(
                peakResidentPathBytes,
                checkpointPathBytes + decodedPathBytes
            )
        }
        guard reader.validationState == .verified,
              ordinaryFileCount == planManifest.footer.ordinaryFileCount,
              ordinaryDirectoryCount == planManifest.footer.ordinaryDirectoryCount
        else {
            throw FileSystemSeedReplayError.inventoryNotInstalled
        }
        self.planManifest = planManifest
        testingRecords = nil
        self.checkpoints = checkpoints
        statistics = FileSystemSeededInventoryPreparationStatistics(
            recordCount: recordCount,
            ordinaryFileCount: ordinaryFileCount,
            ordinaryDirectoryCount: ordinaryDirectoryCount,
            peakResidentPathBytes: peakResidentPathBytes
        )
    }

    func makeReader() throws -> FileSystemSeededInventoryManifestReader {
        if let planManifest {
            return try FileSystemSeededInventoryManifestReader(planReader: planManifest.makeReader())
        }
        return FileSystemSeededInventoryManifestReader(testingRecords: testingRecords ?? [])
    }

    /// Exact point lookup over the authenticated sorted artifact. This is used
    /// only by watcher mutations; complete inventory publication uses streaming.
    fileprivate func itemType(relativePath: String) throws -> Bool? {
        guard let planManifest else {
            let target = Data(relativePath.utf8)
            for record in testingRecords ?? [] {
                let bytes = Data(record.relativePath.utf8)
                if target.lexicographicallyPrecedes(bytes) { return nil }
                if bytes == target { return record.isDirectory }
            }
            return nil
        }
        let target = Data(relativePath.utf8)
        guard !checkpoints.isEmpty else { return nil }
        var lowerBound = 0
        var upperBound = checkpoints.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            let candidate = checkpoints[middle].relativePathBytes
            if candidate == target || candidate.lexicographicallyPrecedes(target) {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound > 0 else { return nil }
        let checkpoint = checkpoints[lowerBound - 1]
        let reader = try planManifest.makeLookupReader(
            startingAtValidatedRecordOffset: checkpoint.recordOffset
        )
        while let record = try reader.next() {
            if target.lexicographicallyPrecedes(record.relativePathBytes) { return nil }
            guard target == record.relativePathBytes else { continue }
            switch record.disposition {
            case .ordinaryFile: return false
            case .ordinaryDirectory: return true
            case .policyIgnoredTrackedFile, .baseTombstone: return nil
            }
        }
        return nil
    }

    #if DEBUG
        static func makeForTesting(records: [FileSystemSeededInventoryRecord]) throws -> Self {
            try Self(testingRecords: records)
        }

        private init(testingRecords: [FileSystemSeededInventoryRecord]) throws {
            let sorted = testingRecords.sorted {
                $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
            }
            var previous: String?
            var files: UInt64 = 0
            var folders: UInt64 = 0
            var peak = 0
            for record in sorted {
                let path = try fileSystemValidatedSeedPath(Data(record.relativePath.utf8))
                guard previous != path else {
                    throw FileSystemSeedReplayError.invalidSeedInventoryPath(path)
                }
                previous = path
                if record.isDirectory { folders += 1 } else { files += 1 }
                peak = max(peak, path.utf8.count * 2)
            }
            planManifest = nil
            self.testingRecords = sorted
            checkpoints = []
            statistics = FileSystemSeededInventoryPreparationStatistics(
                recordCount: files + folders,
                ordinaryFileCount: files,
                ordinaryDirectoryCount: folders,
                peakResidentPathBytes: peak
            )
        }
    #endif
}

final class FileSystemSeededInventoryManifestReader {
    private let planReader: WorkspaceRootTargetSeedPlanManifestReader?
    private var testingIterator: IndexingIterator<[FileSystemSeededInventoryRecord]>?

    fileprivate init(planReader: WorkspaceRootTargetSeedPlanManifestReader) throws {
        self.planReader = planReader
        testingIterator = nil
    }

    fileprivate init(testingRecords: [FileSystemSeededInventoryRecord]) {
        planReader = nil
        testingIterator = testingRecords.makeIterator()
    }

    func next() throws -> FileSystemSeededInventoryRecord? {
        if testingIterator != nil {
            return testingIterator?.next()
        }
        guard let planReader else { return nil }
        while let record = try planReader.next() {
            let path = try fileSystemValidatedSeedPath(record.relativePathBytes)
            switch record.disposition {
            case .ordinaryFile:
                return FileSystemSeededInventoryRecord(relativePath: path, isDirectory: false)
            case .ordinaryDirectory:
                return FileSystemSeededInventoryRecord(relativePath: path, isDirectory: true)
            case .policyIgnoredTrackedFile, .baseTombstone:
                continue
            }
        }
        guard planReader.validationState == .verified else {
            throw FileSystemSeedReplayError.inventoryNotInstalled
        }
        return nil
    }
}

/// Frozen view of a seeded inventory after watcher replay. Root-sized bytes
/// remain in the shared manifest; only paths changed during replay are copied.
struct FileSystemSeededInventorySnapshot: @unchecked Sendable {
    fileprivate let manifest: FileSystemSeededInventoryManifest
    fileprivate let changes: FileSystemSeededInventoryChangeOverlaySnapshot

    var statistics: FileSystemSeededInventoryPreparationStatistics {
        manifest.statistics
    }

    var changedRelativePaths: FileSystemSeededInventoryChangedPaths {
        FileSystemSeededInventoryChangedPaths(changes: changes)
    }

    func makeReader() throws -> FileSystemSeededInventorySnapshotReader {
        try FileSystemSeededInventorySnapshotReader(
            baseReader: manifest.makeReader(),
            changes: changes
        )
    }
}

/// Exact, spill-backed changed-path view for replay proof and projection.
/// It never materializes the replay namespace as a Swift collection.
struct FileSystemSeededInventoryChangedPaths: @unchecked Sendable {
    fileprivate let changes: FileSystemSeededInventoryChangeOverlaySnapshot

    static let empty = FileSystemSeededInventoryChangedPaths(
        changes: FileSystemSeededInventoryChangeOverlaySnapshot(segments: [])
    )

    var count: Int {
        changes.count
    }

    func contains(_ relativePath: String) throws -> Bool {
        for segment in changes.segments.reversed()
            where try segment.entry(relativePath: relativePath) != nil
        {
            return true
        }
        return false
    }

    func makeReader() throws -> FileSystemSeededInventoryChangedPathReader {
        try FileSystemSeededInventoryChangedPathReader(changes: changes)
    }
}

final class FileSystemSeededInventoryChangedPathReader {
    private let iterator: FileSystemSeededInventoryChangeOverlayIterator

    fileprivate init(changes: FileSystemSeededInventoryChangeOverlaySnapshot) throws {
        iterator = try changes.makeIterator()
    }

    func next() throws -> String? {
        try iterator.next()?.relativePath
    }
}

final class FileSystemSeededInventorySnapshotReader {
    private let baseReader: FileSystemSeededInventoryManifestReader
    private var changeIterator: FileSystemSeededInventoryChangeOverlayIterator
    private var baseLookahead: FileSystemSeededInventoryRecord?
    private var changeLookahead: FileSystemSeededInventoryChangeEntry?
    private var didPrime = false

    fileprivate init(
        baseReader: FileSystemSeededInventoryManifestReader,
        changes: FileSystemSeededInventoryChangeOverlaySnapshot
    ) throws {
        self.baseReader = baseReader
        changeIterator = try changes.makeIterator()
    }

    func next() throws -> FileSystemSeededInventoryRecord? {
        if !didPrime {
            baseLookahead = try baseReader.next()
            changeLookahead = try changeIterator.next()
            didPrime = true
        }
        while baseLookahead != nil || changeLookahead != nil {
            switch (baseLookahead, changeLookahead) {
            case let (base?, change?):
                let baseBytes = Data(base.relativePath.utf8)
                let changeBytes = Data(change.relativePath.utf8)
                if baseBytes.lexicographicallyPrecedes(changeBytes) {
                    baseLookahead = try baseReader.next()
                    return base
                }
                if changeBytes.lexicographicallyPrecedes(baseBytes) {
                    changeLookahead = try changeIterator.next()
                    if change.change != .removed {
                        return FileSystemSeededInventoryRecord(
                            relativePath: change.relativePath,
                            isDirectory: change.change == .directory
                        )
                    }
                    continue
                }
                baseLookahead = try baseReader.next()
                changeLookahead = try changeIterator.next()
                if change.change != .removed {
                    return FileSystemSeededInventoryRecord(
                        relativePath: change.relativePath,
                        isDirectory: change.change == .directory
                    )
                }
            case let (base?, nil):
                baseLookahead = try baseReader.next()
                return base
            case let (nil, change?):
                changeLookahead = try changeIterator.next()
                if change.change != .removed {
                    return FileSystemSeededInventoryRecord(
                        relativePath: change.relativePath,
                        isDirectory: change.change == .directory
                    )
                }
            case (nil, nil):
                return nil
            }
        }
        return nil
    }
}

/// Shared storage behind the legacy visited-path views. Ordinary roots retain
/// their existing Set/dictionary representation. Seeded roots retain only the
/// authenticated manifest plus an overlay of paths changed after its cut.
final class FileSystemVisitedInventory {
    struct State {
        fileprivate let ordinaryPaths: Set<String>
        fileprivate let ordinaryItems: [String: Bool]
        fileprivate let seededManifest: FileSystemSeededInventoryManifest?
        fileprivate let seededChanges: FileSystemSeededInventoryChangeOverlay
        fileprivate let integrityFailed: Bool
    }

    final class Paths: Sequence {
        typealias Element = String

        private unowned let storage: FileSystemVisitedInventory

        fileprivate init(storage: FileSystemVisitedInventory) {
            self.storage = storage
        }

        func makeIterator() -> AnyIterator<String> {
            storage.makePathIterator()
        }

        func contains(_ path: String) -> Bool {
            storage.itemType(relativePath: path) != nil
        }

        @discardableResult
        func insert(_ path: String) -> (inserted: Bool, memberAfterInsert: String) {
            let inserted = storage.itemType(relativePath: path) == nil
            storage.setItem(relativePath: path, isDirectory: storage.itemType(relativePath: path) ?? false)
            return (inserted, path)
        }

        @discardableResult
        func remove(_ path: String) -> String? {
            storage.removeItem(relativePath: path) == nil ? nil : path
        }
    }

    final class Items: Sequence {
        typealias Element = (key: String, value: Bool)

        private unowned let storage: FileSystemVisitedInventory

        fileprivate init(storage: FileSystemVisitedInventory) {
            self.storage = storage
        }

        func makeIterator() -> AnyIterator<Element> {
            storage.makeItemIterator()
        }

        subscript(path: String) -> Bool? {
            get { storage.itemType(relativePath: path) }
            set {
                if let newValue {
                    storage.setItem(relativePath: path, isDirectory: newValue)
                } else {
                    storage.removeItem(relativePath: path)
                }
            }
        }

        @discardableResult
        func removeValue(forKey path: String) -> Bool? {
            storage.removeItem(relativePath: path)
        }

        var keys: AnySequence<String> {
            AnySequence(storage.makePathIterator())
        }
    }

    lazy var paths = Paths(storage: self)
    lazy var items = Items(storage: self)

    private var ordinaryPaths = Set<String>()
    private var ordinaryItems = [String: Bool]()
    private var seededManifest: FileSystemSeededInventoryManifest?
    private var seededChanges = FileSystemSeededInventoryChangeOverlay()
    private var integrityFailed = false

    func installOrdinary(paths: Set<String>, items: [String: Bool]) {
        ordinaryPaths = paths
        ordinaryItems = items
        seededManifest = nil
        seededChanges = FileSystemSeededInventoryChangeOverlay()
        integrityFailed = false
    }

    func installSeeded(manifest: FileSystemSeededInventoryManifest) {
        ordinaryPaths.removeAll(keepingCapacity: false)
        ordinaryItems.removeAll(keepingCapacity: false)
        seededChanges = FileSystemSeededInventoryChangeOverlay()
        integrityFailed = false
        seededManifest = manifest
    }

    func captureState() -> State {
        State(
            ordinaryPaths: ordinaryPaths,
            ordinaryItems: ordinaryItems,
            seededManifest: seededManifest,
            seededChanges: seededChanges,
            integrityFailed: integrityFailed
        )
    }

    func restore(_ state: State) {
        ordinaryPaths = state.ordinaryPaths
        ordinaryItems = state.ordinaryItems
        seededManifest = state.seededManifest
        seededChanges = state.seededChanges
        integrityFailed = state.integrityFailed
    }

    func seededSnapshot() throws -> FileSystemSeededInventorySnapshot {
        guard let seededManifest, !integrityFailed else {
            throw FileSystemSeedReplayError.inventoryNotInstalled
        }
        return try FileSystemSeededInventorySnapshot(
            manifest: seededManifest,
            changes: seededChanges.snapshot()
        )
    }

    var seededReplayStorageStatistics: FileSystemSeededInventoryReplayStorageStatistics {
        seededChanges.statistics
    }

    func recordSeedReplayDelta(_ delta: FileSystemDelta) {
        guard seededManifest != nil else { return }
        let update: (String, FileSystemSeededInventoryChange) = switch delta {
        case let .fileAdded(path), let .fileModified(path, _):
            (StandardizedPath.relative(path), .file)
        case let .folderAdded(path), let .folderModified(path, _):
            (StandardizedPath.relative(path), .directory)
        case let .fileRemoved(path), let .folderRemoved(path):
            (StandardizedPath.relative(path), .removed)
        }
        do {
            try seededChanges.set(update.1, relativePath: update.0)
        } catch {
            integrityFailed = true
        }
    }

    #if DEBUG
        func materializedStateForTesting() -> (paths: Set<String>, items: [String: Bool]) {
            var paths = Set<String>()
            var items: [String: Bool] = [:]
            let iterator = makeItemIterator()
            while let item = iterator.next() {
                paths.insert(item.key)
                items[item.key] = item.value
            }
            return (paths, items)
        }
    #endif

    private func itemType(relativePath: String) -> Bool? {
        guard let seededManifest else {
            return ordinaryPaths.contains(relativePath) ? ordinaryItems[relativePath] : nil
        }
        do {
            if let change = try seededChanges.change(relativePath: relativePath) {
                switch change {
                case .file: return false
                case .directory: return true
                case .removed: return nil
                }
            }
        } catch {
            integrityFailed = true
            return nil
        }
        do {
            return try seededManifest.itemType(relativePath: relativePath)
        } catch {
            integrityFailed = true
            return nil
        }
    }

    private func setItem(relativePath: String, isDirectory: Bool) {
        guard seededManifest != nil else {
            ordinaryPaths.insert(relativePath)
            ordinaryItems[relativePath] = isDirectory
            return
        }
        do {
            try seededChanges.set(isDirectory ? .directory : .file, relativePath: relativePath)
        } catch {
            integrityFailed = true
        }
    }

    @discardableResult
    private func removeItem(relativePath: String) -> Bool? {
        let previous = itemType(relativePath: relativePath)
        guard seededManifest != nil else {
            ordinaryPaths.remove(relativePath)
            ordinaryItems.removeValue(forKey: relativePath)
            return previous
        }
        do {
            try seededChanges.set(.removed, relativePath: relativePath)
        } catch {
            integrityFailed = true
        }
        return previous
    }

    private func makePathIterator() -> AnyIterator<String> {
        guard seededManifest != nil else {
            var iterator = ordinaryPaths.makeIterator()
            return AnyIterator { iterator.next() }
        }
        let iterator = makeItemIterator()
        return AnyIterator { iterator.next()?.key }
    }

    private func makeItemIterator() -> AnyIterator<(key: String, value: Bool)> {
        guard let seededManifest else {
            var iterator = ordinaryItems.makeIterator()
            return AnyIterator { iterator.next() }
        }
        do {
            let snapshot = try FileSystemSeededInventorySnapshot(
                manifest: seededManifest,
                changes: seededChanges.snapshot()
            )
            let reader = try snapshot.makeReader()
            return AnyIterator { [weak self] in
                do {
                    guard let record = try reader.next() else { return nil }
                    return (record.relativePath, record.isDirectory)
                } catch {
                    self?.integrityFailed = true
                    return nil
                }
            }
        } catch {
            integrityFailed = true
            return AnyIterator { nil }
        }
    }

    #if DEBUG
        func applySeededChangeForTesting(relativePath: String, isDirectory: Bool?) {
            if let isDirectory {
                setItem(relativePath: relativePath, isDirectory: isDirectory)
            } else {
                _ = removeItem(relativePath: relativePath)
            }
        }

        var seededReplayStorageStatisticsForTesting: FileSystemSeededInventoryReplayStorageStatistics {
            seededChanges.statistics
        }
    #endif
}

func fileSystemValidatedSeedPath(_ bytes: Data) throws -> String {
    guard let path = String(data: bytes, encoding: .utf8),
          Data(path.utf8) == bytes
    else {
        throw FileSystemSeedReplayError.invalidSeedInventoryPath(
            String(decoding: bytes, as: UTF8.self)
        )
    }
    let standardized = StandardizedPath.relative(path)
    guard standardized == path,
          !standardized.isEmpty,
          standardized != ".",
          standardized != "..",
          !standardized.hasPrefix("../"),
          !standardized.hasPrefix("/")
    else {
        throw FileSystemSeedReplayError.invalidSeedInventoryPath(path)
    }
    return standardized
}
