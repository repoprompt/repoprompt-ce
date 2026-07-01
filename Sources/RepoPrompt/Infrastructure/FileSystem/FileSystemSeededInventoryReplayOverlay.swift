import Darwin
import Foundation

enum FileSystemSeededInventoryChange: UInt8, Equatable {
    case file = 1
    case directory = 2
    case removed = 3
}

struct FileSystemSeededInventoryChangeEntry: Equatable {
    let relativePath: String
    let change: FileSystemSeededInventoryChange
    let sequence: UInt64
}

struct FileSystemSeededInventoryReplayStorageStatistics: Equatable {
    let peakMutablePathBytes: Int
    let peakMergeResidentPathBytes: Int
    let peakOpenSegmentCount: Int
    let currentSegmentCount: Int
    let changedPathCount: Int
}

private struct FileSystemSeededInventorySpillIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
}

private final class FileSystemSeededInventoryChangeSpillStore: @unchecked Sendable {
    let directoryURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "repoprompt-seeded-replay-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard mkdir(directoryURL.path, 0o700) == 0 else {
            throw FileSystemSeedReplayError.inventoryNotInstalled
        }
    }

    deinit { try? FileManager.default.removeItem(at: directoryURL) }

    func createFileURL() -> URL {
        directoryURL.appendingPathComponent("segment-\(UUID().uuidString.lowercased()).delta")
    }

    func createDescriptor(at url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw FileSystemSeedReplayError.inventoryNotInstalled }
        return descriptor
    }

    func openDescriptor(at url: URL, identity: FileSystemSeededInventorySpillIdentity) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FileSystemSeedReplayError.inventoryNotInstalled }
        guard Self.identity(descriptor) == identity else {
            Darwin.close(descriptor)
            throw FileSystemSeedReplayError.inventoryNotInstalled
        }
        return descriptor
    }

    static func identity(_ descriptor: Int32) -> FileSystemSeededInventorySpillIdentity? {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == getuid(),
              status.st_mode & 0o7777 == 0o600,
              status.st_size >= 0
        else { return nil }
        return FileSystemSeededInventorySpillIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: UInt64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }
}

final class FileSystemSeededInventoryChangeSegment: @unchecked Sendable {
    struct Checkpoint {
        let relativePathBytes: Data
        let offset: UInt64
    }

    let recordCount: Int
    let byteCount: UInt64
    let checkpoints: [Checkpoint]

    private let store: FileSystemSeededInventoryChangeSpillStore
    private let fileURL: URL
    private let identity: FileSystemSeededInventorySpillIdentity

    fileprivate init(
        store: FileSystemSeededInventoryChangeSpillStore,
        fileURL: URL,
        identity: FileSystemSeededInventorySpillIdentity,
        recordCount: Int,
        checkpoints: [Checkpoint]
    ) {
        self.store = store
        self.fileURL = fileURL
        self.identity = identity
        self.recordCount = recordCount
        byteCount = identity.byteCount
        self.checkpoints = checkpoints
    }

    deinit { try? FileManager.default.removeItem(at: fileURL) }

    func makeReader(startingAt offset: UInt64 = 8) throws -> FileSystemSeededInventoryChangeSegmentReader {
        try FileSystemSeededInventoryChangeSegmentReader(
            descriptor: store.openDescriptor(at: fileURL, identity: identity),
            byteCount: byteCount,
            startingAt: offset
        )
    }

    func entry(relativePath: String) throws -> FileSystemSeededInventoryChangeEntry? {
        let target = Data(relativePath.utf8)
        var lowerBound = 0
        var upperBound = checkpoints.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            let candidate = checkpoints[middle].relativePathBytes
            if candidate.lexicographicallyPrecedes(target) || candidate == target {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        let offset = lowerBound > 0 ? checkpoints[lowerBound - 1].offset : 8
        let reader = try makeReader(startingAt: offset)
        while let entry = try reader.next() {
            let entryBytes = Data(entry.relativePath.utf8)
            if entryBytes == target { return entry }
            if !entryBytes.lexicographicallyPrecedes(target) { return nil }
        }
        return nil
    }
}

final class FileSystemSeededInventoryChangeSegmentReader {
    private let descriptor: Int32
    private let byteCount: UInt64
    private var offset: UInt64

    fileprivate init(descriptor: Int32, byteCount: UInt64, startingAt: UInt64) throws {
        self.descriptor = descriptor
        self.byteCount = byteCount
        offset = 0
        guard try read(count: 8) == Data("RPSDSEG1".utf8),
              startingAt >= 8,
              startingAt <= byteCount
        else {
            throw FileSystemSeedReplayError.inventoryNotInstalled
        }
        offset = startingAt
    }

    deinit { Darwin.close(descriptor) }

    func next() throws -> FileSystemSeededInventoryChangeEntry? {
        guard offset < byteCount else { return nil }
        let lengthBytes = try read(count: 4)
        let pathLength = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard pathLength > 0,
              pathLength <= UInt32(FileSystemSeededInventoryChangeOverlay.maximumRecordPathBytes)
        else { throw FileSystemSeedReplayError.inventoryNotInstalled }
        let sequenceBytes = try read(count: 8)
        let sequence = sequenceBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        let rawChange = try read(count: 1)[0]
        guard let change = FileSystemSeededInventoryChange(rawValue: rawChange) else {
            throw FileSystemSeedReplayError.inventoryNotInstalled
        }
        let relativePath = try fileSystemValidatedSeedPath(read(count: Int(pathLength)))
        return FileSystemSeededInventoryChangeEntry(
            relativePath: relativePath,
            change: change,
            sequence: sequence
        )
    }

    private func read(count: Int) throws -> Data {
        guard count >= 0,
              UInt64(count) <= byteCount,
              offset <= byteCount - UInt64(count)
        else { throw FileSystemSeedReplayError.inventoryNotInstalled }
        var result = Data(count: count)
        var completed = 0
        while completed < count {
            let amount = result.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return pread(
                    descriptor,
                    base.advanced(by: completed),
                    count - completed,
                    off_t(offset + UInt64(completed))
                )
            }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { throw FileSystemSeedReplayError.inventoryNotInstalled }
            completed += amount
        }
        offset += UInt64(count)
        return result
    }
}

private final class FileSystemSeededInventoryChangeSegmentWriter {
    private static let maximumCheckpointCount = 1024
    static let maximumCheckpointPathBytes = 256 * 1024

    private let store: FileSystemSeededInventoryChangeSpillStore
    private let fileURL: URL
    private let descriptor: Int32
    private let checkpointStride: Int
    private var offset: UInt64 = 0
    private var recordCount = 0
    private var checkpointPathBytes = 0
    private var checkpoints: [FileSystemSeededInventoryChangeSegment.Checkpoint] = []
    private var isClosed = false

    init(store: FileSystemSeededInventoryChangeSpillStore, estimatedRecordCount: Int) throws {
        self.store = store
        fileURL = store.createFileURL()
        descriptor = try store.createDescriptor(at: fileURL)
        checkpointStride = max(
            1,
            (estimatedRecordCount + Self.maximumCheckpointCount - 1) / Self.maximumCheckpointCount
        )
        try write(Data("RPSDSEG1".utf8))
    }

    deinit {
        if !isClosed {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func append(_ entry: FileSystemSeededInventoryChangeEntry) throws {
        let pathBytes = Data(entry.relativePath.utf8)
        guard !pathBytes.isEmpty,
              pathBytes.count <= FileSystemSeededInventoryChangeOverlay.maximumRecordPathBytes,
              let pathLength = UInt32(exactly: pathBytes.count)
        else { throw FileSystemSeedReplayError.inventoryNotInstalled }
        if recordCount.isMultiple(of: checkpointStride),
           checkpoints.count < Self.maximumCheckpointCount,
           checkpointPathBytes + pathBytes.count <= Self.maximumCheckpointPathBytes
        {
            checkpoints.append(.init(relativePathBytes: pathBytes, offset: offset))
            checkpointPathBytes += pathBytes.count
        }
        var header = Data()
        var littlePathLength = pathLength.littleEndian
        var littleSequence = entry.sequence.littleEndian
        withUnsafeBytes(of: &littlePathLength) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &littleSequence) { header.append(contentsOf: $0) }
        header.append(entry.change.rawValue)
        try write(header)
        try write(pathBytes)
        recordCount += 1
    }

    func finish() throws -> FileSystemSeededInventoryChangeSegment {
        guard !isClosed,
              let identity = FileSystemSeededInventoryChangeSpillStore.identity(descriptor),
              Darwin.close(descriptor) == 0
        else { throw FileSystemSeedReplayError.inventoryNotInstalled }
        isClosed = true
        return FileSystemSeededInventoryChangeSegment(
            store: store,
            fileURL: fileURL,
            identity: identity,
            recordCount: recordCount,
            checkpoints: checkpoints
        )
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let amount = Darwin.write(descriptor, base.advanced(by: written), raw.count - written)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw FileSystemSeedReplayError.inventoryNotInstalled }
                written += amount
            }
        }
        offset += UInt64(data.count)
    }
}

struct FileSystemSeededInventoryChangeOverlay {
    static let maximumMutablePathBytes = 256 * 1024
    static let maximumRecordPathBytes = 1024 * 1024
    static let maximumSegmentCount = 8

    private let spillStore: FileSystemSeededInventoryChangeSpillStore?
    private(set) var segments: [FileSystemSeededInventoryChangeSegment] = []
    private var mutableChanges: [Data: FileSystemSeededInventoryChangeEntry] = [:]
    private var mutablePathBytes = 0
    private var nextSequence: UInt64 = 1
    private var peakMutablePathBytes = 0
    private var peakMergeResidentPathBytes = 0
    private var peakOpenSegmentCount = 0

    init() {
        spillStore = try? FileSystemSeededInventoryChangeSpillStore()
    }

    mutating func set(_ change: FileSystemSeededInventoryChange, relativePath: String) throws {
        let pathData = Data(relativePath.utf8)
        guard !pathData.isEmpty,
              pathData.count <= Self.maximumRecordPathBytes,
              pathData.count <= (Int.max - 32) / 2,
              nextSequence != UInt64.max
        else { throw FileSystemSeedReplayError.inventoryNotInstalled }
        let retainedPathBytes = pathData.count * 2 + 32
        guard retainedPathBytes <= Self.maximumMutablePathBytes else {
            throw FileSystemSeedReplayError.inventoryNotInstalled
        }
        if mutableChanges[pathData] == nil,
           !mutableChanges.isEmpty,
           mutablePathBytes + retainedPathBytes > Self.maximumMutablePathBytes
        {
            try sealMutableSegment()
        }
        if mutableChanges[pathData] == nil { mutablePathBytes += retainedPathBytes }
        mutableChanges[pathData] = FileSystemSeededInventoryChangeEntry(
            relativePath: relativePath,
            change: change,
            sequence: nextSequence
        )
        nextSequence += 1
        peakMutablePathBytes = max(peakMutablePathBytes, mutablePathBytes)
        if mutablePathBytes >= Self.maximumMutablePathBytes { try sealMutableSegment() }
    }

    func change(relativePath: String) throws -> FileSystemSeededInventoryChange? {
        if let entry = mutableChanges[Data(relativePath.utf8)] { return entry.change }
        for segment in segments.reversed() {
            if let entry = try segment.entry(relativePath: relativePath) { return entry.change }
        }
        return nil
    }

    mutating func snapshot() throws -> FileSystemSeededInventoryChangeOverlaySnapshot {
        try sealMutableSegment()
        if segments.count > 1 { try compactSegments() }
        return FileSystemSeededInventoryChangeOverlaySnapshot(segments: segments)
    }

    var statistics: FileSystemSeededInventoryReplayStorageStatistics {
        FileSystemSeededInventoryReplayStorageStatistics(
            peakMutablePathBytes: peakMutablePathBytes,
            peakMergeResidentPathBytes: peakMergeResidentPathBytes,
            peakOpenSegmentCount: peakOpenSegmentCount,
            currentSegmentCount: segments.count,
            changedPathCount: segments.reduce(0) { $0 + $1.recordCount } + mutableChanges.count
        )
    }

    private mutating func sealMutableSegment() throws {
        guard !mutableChanges.isEmpty else { return }
        guard let spillStore else { throw FileSystemSeedReplayError.inventoryNotInstalled }
        let entries = mutableChanges.values.sorted {
            $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
        }
        let writer = try FileSystemSeededInventoryChangeSegmentWriter(
            store: spillStore,
            estimatedRecordCount: entries.count
        )
        for entry in entries {
            try writer.append(entry)
        }
        try segments.append(writer.finish())
        peakOpenSegmentCount = max(peakOpenSegmentCount, segments.count)
        mutableChanges.removeAll(keepingCapacity: true)
        mutablePathBytes = 0
        if segments.count > Self.maximumSegmentCount { try compactSegments() }
    }

    private mutating func compactSegments() throws {
        guard segments.count > 1, segments.count <= Self.maximumSegmentCount + 1 else {
            if segments.count > Self.maximumSegmentCount + 1 {
                throw FileSystemSeedReplayError.inventoryNotInstalled
            }
            return
        }
        guard let spillStore else { throw FileSystemSeedReplayError.inventoryNotInstalled }
        var estimatedRecordCount = 0
        for segment in segments {
            let addition = estimatedRecordCount.addingReportingOverflow(segment.recordCount)
            guard !addition.overflow else { throw FileSystemSeedReplayError.inventoryNotInstalled }
            estimatedRecordCount = addition.partialValue
        }
        let writer = try FileSystemSeededInventoryChangeSegmentWriter(
            store: spillStore,
            estimatedRecordCount: estimatedRecordCount
        )
        let readers = try segments.map { try $0.makeReader() }
        var lookahead = try readers.map { try $0.next() }
        let checkpointResidentPathBytes = segments.reduce(0) { partial, segment in
            partial + segment.checkpoints.reduce(0) { $0 + $1.relativePathBytes.count }
        }
        while true {
            var selectedPathBytes: Data?
            for entry in lookahead.compactMap(\.self) {
                let pathBytes = Data(entry.relativePath.utf8)
                if selectedPathBytes.map({ pathBytes.lexicographicallyPrecedes($0) }) ?? true {
                    selectedPathBytes = pathBytes
                }
            }
            guard let selectedPathBytes else { break }
            var winner: FileSystemSeededInventoryChangeEntry?
            var residentPathBytes = checkpointResidentPathBytes
            for index in readers.indices {
                guard let entry = lookahead[index] else { continue }
                residentPathBytes += entry.relativePath.utf8.count
                guard Data(entry.relativePath.utf8) == selectedPathBytes else { continue }
                if winner.map({ entry.sequence > $0.sequence }) ?? true { winner = entry }
                lookahead[index] = try readers[index].next()
            }
            guard let winner else { throw FileSystemSeedReplayError.inventoryNotInstalled }
            residentPathBytes += winner.relativePath.utf8.count
            peakMergeResidentPathBytes = max(peakMergeResidentPathBytes, residentPathBytes)
            try writer.append(winner)
        }
        segments = try [writer.finish()]
    }
}

struct FileSystemSeededInventoryChangeOverlaySnapshot: @unchecked Sendable {
    let segments: [FileSystemSeededInventoryChangeSegment]

    var count: Int {
        segments.reduce(0) { $0 + $1.recordCount }
    }

    func contains(_ relativePath: String) -> Bool {
        do {
            for segment in segments.reversed() where try segment.entry(relativePath: relativePath) != nil {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func makeIterator() throws -> FileSystemSeededInventoryChangeOverlayIterator {
        try FileSystemSeededInventoryChangeOverlayIterator(segments: segments)
    }
}

final class FileSystemSeededInventoryChangeOverlayIterator {
    private let readers: [FileSystemSeededInventoryChangeSegmentReader]
    private var lookahead: [FileSystemSeededInventoryChangeEntry?]

    init(segments: [FileSystemSeededInventoryChangeSegment]) throws {
        readers = try segments.map { try $0.makeReader() }
        lookahead = try readers.map { try $0.next() }
    }

    func next() throws -> FileSystemSeededInventoryChangeEntry? {
        var chosenPathBytes: Data?
        for entry in lookahead.compactMap(\.self) {
            let pathBytes = Data(entry.relativePath.utf8)
            if chosenPathBytes.map({ pathBytes.lexicographicallyPrecedes($0) }) ?? true {
                chosenPathBytes = pathBytes
            }
        }
        guard let chosenPathBytes else { return nil }
        var newestMatch: FileSystemSeededInventoryChangeEntry?
        for index in readers.indices {
            guard let entry = lookahead[index],
                  Data(entry.relativePath.utf8) == chosenPathBytes
            else { continue }
            if newestMatch.map({ entry.sequence > $0.sequence }) ?? true { newestMatch = entry }
            lookahead[index] = try readers[index].next()
        }
        return newestMatch
    }
}
