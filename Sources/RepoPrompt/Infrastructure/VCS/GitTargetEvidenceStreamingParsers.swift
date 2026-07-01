import Foundation

struct GitTargetEvidencePathPolicy: Equatable {
    let maximumPathBytes: Int
    let maximumDepth: Int

    init(maximumPathBytes: Int = 16 * 1024, maximumDepth: Int = 512) {
        precondition(maximumPathBytes > 0)
        precondition(maximumDepth > 0)
        self.maximumPathBytes = maximumPathBytes
        self.maximumDepth = maximumDepth
    }
}

struct GitLoadedRootTreeInventoryRecord: Equatable {
    let modeBytes: Data
    let kind: GitTreeEntryKind
    let objectIDBytes: Data
    let repositoryRelativePathBytes: Data
}

struct GitLoadedRootTreeInventoryStreamingParser {
    typealias Emit = @Sendable (GitLoadedRootTreeInventoryRecord) async throws -> Void

    private let objectFormat: GitObjectFormat
    private let validator: GitTargetEvidencePathValidator
    private let emit: Emit
    private var framer: GitTargetEvidenceNULFramer

    init(
        objectFormat: GitObjectFormat,
        rootPrefix: GitRepositoryRelativeRootPrefix,
        pathPolicy: GitTargetEvidencePathPolicy = .init(),
        emit: @escaping Emit
    ) {
        self.objectFormat = objectFormat
        validator = GitTargetEvidencePathValidator(rootPrefix: rootPrefix, policy: pathPolicy)
        self.emit = emit
        framer = GitTargetEvidenceNULFramer(maximumFrameBytes: pathPolicy.maximumPathBytes + 4096)
    }

    mutating func consume(_ chunk: Data) async throws {
        var activeFramer = framer
        do {
            try await activeFramer.consume(chunk) { frame in
                try await consumeFrame(frame)
            }
            framer = activeFramer
        } catch {
            framer = activeFramer
            throw error
        }
    }

    mutating func finish() async throws {
        try Task.checkCancellation()
        try framer.finish()
    }

    private func consumeFrame(_ frame: Data) async throws {
        guard let tab = frame.firstIndex(of: UInt8(ascii: "\t")) else {
            throw GitWorktreeInitializationError.malformedOutput("ls-tree record has no path separator")
        }
        let header = frame[..<tab]
        try GitTargetEvidenceBytes.requireUTF8(header, context: "ls-tree header")
        let fields = GitTargetEvidenceBytes.splitFields(header, maximumSplits: 2)
        guard fields.count == 3,
              GitTargetEvidenceBytes.isMode(fields[0]),
              let kind = GitTreeEntryKind(rawValue: String(decoding: fields[1], as: UTF8.self))
        else {
            throw GitWorktreeInitializationError.malformedOutput("invalid ls-tree metadata")
        }
        try GitTargetEvidenceBytes.validateObjectID(fields[2], objectFormat: objectFormat)

        let rawPath = frame[frame.index(after: tab)...]
        try GitTargetEvidenceBytes.requireUTF8(rawPath, context: "path")
        let path = try validator.validate(rawPath)
        try await emit(GitLoadedRootTreeInventoryRecord(
            modeBytes: Data(fields[0]),
            kind: kind,
            objectIDBytes: Data(fields[2]),
            repositoryRelativePathBytes: path
        ))
    }
}

struct GitTargetTreeDeltaStreamingParser {
    typealias Emit = @Sendable (GitTargetTreeDeltaEvidenceRecord) async throws -> Void

    private enum State {
        case awaitingMetadata
        case firstPath(PendingMetadata)
        case secondPath(PendingMetadata, source: Data)
    }

    private struct PendingMetadata {
        let oldModeBytes: Data?
        let newModeBytes: Data?
        let oldObjectIDBytes: Data?
        let newObjectIDBytes: Data?
        let status: GitTargetTreeDeltaEvidenceStatus
        let similarityScore: UInt16?
    }

    private let objectFormat: GitObjectFormat
    private let validator: GitTargetEvidencePathValidator
    private let emit: Emit
    private var framer: GitTargetEvidenceNULFramer
    private var state: State = .awaitingMetadata

    init(
        objectFormat: GitObjectFormat,
        rootPrefix: GitRepositoryRelativeRootPrefix,
        pathPolicy: GitTargetEvidencePathPolicy = .init(),
        emit: @escaping Emit
    ) {
        self.objectFormat = objectFormat
        validator = GitTargetEvidencePathValidator(rootPrefix: rootPrefix, policy: pathPolicy)
        self.emit = emit
        framer = GitTargetEvidenceNULFramer(maximumFrameBytes: pathPolicy.maximumPathBytes + 4096)
    }

    mutating func consume(_ chunk: Data) async throws {
        var activeFramer = framer
        do {
            try await activeFramer.consume(chunk) { frame in
                try await consumeFrame(frame)
            }
            framer = activeFramer
        } catch {
            framer = activeFramer
            throw error
        }
    }

    mutating func finish() async throws {
        try Task.checkCancellation()
        try framer.finish()
        guard case .awaitingMetadata = state else {
            throw GitWorktreeInitializationError.malformedOutput("incomplete raw tree delta record")
        }
    }

    private mutating func consumeFrame(_ frame: Data) async throws {
        switch state {
        case .awaitingMetadata:
            state = try .firstPath(parseMetadata(frame))

        case let .firstPath(metadata):
            let firstPath = try validator.validate(frame)
            switch metadata.status {
            case .renamed, .copied:
                state = .secondPath(metadata, source: firstPath)
            default:
                state = .awaitingMetadata
                try await emit(record(metadata: metadata, source: nil, destination: firstPath))
            }

        case let .secondPath(metadata, source):
            let destination = try validator.validate(frame)
            state = .awaitingMetadata
            if metadata.status == .renamed {
                try await emit(GitTargetTreeDeltaEvidenceRecord(
                    oldModeBytes: metadata.oldModeBytes,
                    newModeBytes: nil,
                    oldObjectIDBytes: metadata.oldObjectIDBytes,
                    newObjectIDBytes: nil,
                    status: .renamedSource,
                    similarityScore: nil,
                    sourceRepositoryRelativePathBytes: nil,
                    repositoryRelativePathBytes: source
                ))
            }
            try await emit(record(metadata: metadata, source: source, destination: destination))
        }
    }

    private func parseMetadata(_ frame: Data) throws -> PendingMetadata {
        guard frame.first == UInt8(ascii: ":") else {
            throw GitWorktreeInitializationError.malformedOutput("raw delta metadata is missing ':'")
        }
        try GitTargetEvidenceBytes.requireUTF8(frame, context: "diff-tree metadata")
        let fields = GitTargetEvidenceBytes.splitFields(frame.dropFirst(), maximumSplits: 4)
        guard fields.count == 5,
              GitTargetEvidenceBytes.isModeOrZero(fields[0]),
              GitTargetEvidenceBytes.isModeOrZero(fields[1])
        else {
            throw GitWorktreeInitializationError.malformedOutput("invalid raw delta metadata")
        }
        let status = try parseStatus(fields[4])
        return try PendingMetadata(
            oldModeBytes: GitTargetEvidenceBytes.zeroModeToNil(fields[0]),
            newModeBytes: GitTargetEvidenceBytes.zeroModeToNil(fields[1]),
            oldObjectIDBytes: GitTargetEvidenceBytes.zeroObjectIDToNil(fields[2], objectFormat: objectFormat),
            newObjectIDBytes: GitTargetEvidenceBytes.zeroObjectIDToNil(fields[3], objectFormat: objectFormat),
            status: status.status,
            similarityScore: status.score
        )
    }

    private func parseStatus(_ bytes: Data.SubSequence) throws
        -> (status: GitTargetTreeDeltaEvidenceStatus, score: UInt16?)
    {
        guard let first = bytes.first else {
            throw GitWorktreeInitializationError.malformedOutput("missing delta status")
        }
        switch first {
        case UInt8(ascii: "A"): return (.added, nil)
        case UInt8(ascii: "D"): return (.deleted, nil)
        case UInt8(ascii: "M"): return (.modified, nil)
        case UInt8(ascii: "T"): return (.typeChanged, nil)
        case UInt8(ascii: "U"): return (.unmerged, nil)
        case UInt8(ascii: "R"): return try (.renamed, GitTargetEvidenceBytes.similarityScore(bytes))
        case UInt8(ascii: "C"): return try (.copied, GitTargetEvidenceBytes.similarityScore(bytes))
        default:
            throw GitWorktreeInitializationError.malformedOutput("unsupported delta status")
        }
    }

    private func record(
        metadata: PendingMetadata,
        source: Data?,
        destination: Data
    ) -> GitTargetTreeDeltaEvidenceRecord {
        GitTargetTreeDeltaEvidenceRecord(
            oldModeBytes: metadata.oldModeBytes,
            newModeBytes: metadata.newModeBytes,
            oldObjectIDBytes: metadata.oldObjectIDBytes,
            newObjectIDBytes: metadata.newObjectIDBytes,
            status: metadata.status,
            similarityScore: metadata.similarityScore,
            sourceRepositoryRelativePathBytes: source,
            repositoryRelativePathBytes: destination
        )
    }
}

struct GitTargetIndexStreamingParser {
    typealias Emit = @Sendable (GitTargetIndexEvidenceRecord) async throws -> Void

    private let objectFormat: GitObjectFormat
    private let validator: GitTargetEvidencePathValidator
    private let emit: Emit
    private var framer: GitTargetEvidenceNULFramer

    init(
        objectFormat: GitObjectFormat,
        rootPrefix: GitRepositoryRelativeRootPrefix,
        pathPolicy: GitTargetEvidencePathPolicy = .init(),
        emit: @escaping Emit
    ) {
        self.objectFormat = objectFormat
        validator = GitTargetEvidencePathValidator(rootPrefix: rootPrefix, policy: pathPolicy)
        self.emit = emit
        framer = GitTargetEvidenceNULFramer(maximumFrameBytes: pathPolicy.maximumPathBytes + 4096)
    }

    mutating func consume(_ chunk: Data) async throws {
        var activeFramer = framer
        do {
            try await activeFramer.consume(chunk) { frame in
                try await consumeFrame(frame)
            }
            framer = activeFramer
        } catch {
            framer = activeFramer
            throw error
        }
    }

    mutating func finish() async throws {
        try Task.checkCancellation()
        try framer.finish()
    }

    private func consumeFrame(_ frame: Data) async throws {
        guard frame.count >= 3,
              let tag = frame.first,
              frame[frame.index(after: frame.startIndex)] == UInt8(ascii: " "),
              let tab = frame.firstIndex(of: UInt8(ascii: "\t"))
        else {
            throw GitWorktreeInitializationError.malformedOutput("invalid ls-files record")
        }
        let metadataStart = frame.index(frame.startIndex, offsetBy: 2)
        let fields = GitTargetEvidenceBytes.splitFields(frame[metadataStart ..< tab], maximumSplits: 2)
        guard fields.count == 3,
              GitTargetEvidenceBytes.isMode(fields[0]),
              let stage = GitTargetEvidenceBytes.asciiInteger(fields[2]),
              (0 ... 3).contains(stage)
        else {
            throw GitWorktreeInitializationError.malformedOutput("invalid ls-files metadata")
        }
        try GitTargetEvidenceBytes.validateObjectID(fields[1], objectFormat: objectFormat)
        let path = try validator.validate(frame[frame.index(after: tab)...])
        try await emit(GitTargetIndexEvidenceRecord(
            modeBytes: Data(fields[0]),
            objectIDBytes: Data(fields[1]),
            stage: UInt8(stage),
            repositoryRelativePathBytes: path,
            assumeUnchanged: (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(tag),
            skipWorktree: tag == UInt8(ascii: "S") || tag == UInt8(ascii: "s")
        ))
    }
}

struct GitTargetStatusPorcelainV2StreamingParser {
    typealias Emit = @Sendable (GitTargetStatusEvidenceRecord) async throws -> Void

    private struct PendingType2 {
        let kind: GitTargetStatusEvidenceKind
        let destination: Data
        let similarityScore: UInt16
        let indexStatus: UInt8
        let workTreeStatus: UInt8
        let submoduleStateBytes: Data
        let headModeBytes: Data
        let indexModeBytes: Data
        let workTreeModeBytes: Data
        let headObjectIDBytes: Data
        let indexObjectIDBytes: Data
    }

    private let validator: GitTargetEvidencePathValidator
    private let emit: Emit
    private var framer: GitTargetEvidenceNULFramer
    private var pendingType2: PendingType2?

    init(
        rootPrefix: GitRepositoryRelativeRootPrefix,
        pathPolicy: GitTargetEvidencePathPolicy = .init(),
        emit: @escaping Emit
    ) {
        validator = GitTargetEvidencePathValidator(rootPrefix: rootPrefix, policy: pathPolicy)
        self.emit = emit
        framer = GitTargetEvidenceNULFramer(maximumFrameBytes: pathPolicy.maximumPathBytes + 4096)
    }

    mutating func consume(_ chunk: Data) async throws {
        var activeFramer = framer
        do {
            try await activeFramer.consume(chunk) { frame in
                try await consumeFrame(frame)
            }
            framer = activeFramer
        } catch {
            framer = activeFramer
            throw error
        }
    }

    mutating func finish() async throws {
        try Task.checkCancellation()
        try framer.finish()
        guard pendingType2 == nil else {
            throw GitWorktreeInitializationError.malformedOutput("missing porcelain-v2 rename source path")
        }
    }

    private mutating func consumeFrame(_ frame: Data) async throws {
        if let pending = pendingType2 {
            let source = try validator.validate(frame)
            pendingType2 = nil
            try await emit(trackedRecord(
                kind: pending.kind,
                path: pending.destination,
                source: source,
                similarityScore: pending.similarityScore,
                indexStatus: pending.indexStatus,
                workTreeStatus: pending.workTreeStatus,
                submoduleStateBytes: pending.submoduleStateBytes,
                headModeBytes: pending.headModeBytes,
                indexModeBytes: pending.indexModeBytes,
                workTreeModeBytes: pending.workTreeModeBytes,
                headObjectIDBytes: pending.headObjectIDBytes,
                indexObjectIDBytes: pending.indexObjectIDBytes
            ))
            return
        }

        guard !frame.isEmpty else { return }
        if frame.starts(with: [UInt8(ascii: "#"), UInt8(ascii: " ")]) {
            try GitTargetEvidenceBytes.requireUTF8(frame, context: "porcelain-v2 header")
            return
        }
        guard let kind = frame.first else { return }
        switch kind {
        case UInt8(ascii: "1"):
            try await consumeOrdinary(frame)
        case UInt8(ascii: "2"):
            try consumeType2(frame)
        case UInt8(ascii: "u"):
            try await consumeUnmerged(frame)
        case UInt8(ascii: "?"):
            try await consumeUntrackedOrIgnored(frame, kind: .untracked)
        case UInt8(ascii: "!"):
            try await consumeUntrackedOrIgnored(frame, kind: .ignored)
        default:
            throw GitWorktreeInitializationError.malformedOutput("unsupported porcelain-v2 record type")
        }
    }

    private func consumeOrdinary(_ frame: Data) async throws {
        let fields = GitTargetEvidenceBytes.splitFields(frame, maximumSplits: 8)
        guard fields.count == 9 else {
            throw GitWorktreeInitializationError.malformedOutput("invalid porcelain-v2 ordinary record")
        }
        let xy = try GitTargetEvidenceBytes.statusPair(fields[1], kind: .ordinary)
        let path = try validator.validate(fields[8])
        try await emit(trackedRecord(
            kind: .ordinary,
            path: path,
            source: nil,
            similarityScore: nil,
            indexStatus: xy.0,
            workTreeStatus: xy.1,
            submoduleStateBytes: Data(fields[2]),
            headModeBytes: Data(fields[3]),
            indexModeBytes: Data(fields[4]),
            workTreeModeBytes: Data(fields[5]),
            headObjectIDBytes: Data(fields[6]),
            indexObjectIDBytes: Data(fields[7])
        ))
    }

    private mutating func consumeType2(_ frame: Data) throws {
        let fields = GitTargetEvidenceBytes.splitFields(frame, maximumSplits: 9)
        guard fields.count == 10 else {
            throw GitWorktreeInitializationError.malformedOutput("invalid porcelain-v2 rename/copy record")
        }
        let xy = try GitTargetEvidenceBytes.statusPair(fields[1], kind: .renamed)
        let score = try GitTargetEvidenceBytes.porcelainSimilarityScore(fields[8], xy: xy)
        let destination = try validator.validate(fields[9])
        pendingType2 = PendingType2(
            kind: fields[8].first == UInt8(ascii: "R") ? .renamed : .copied,
            destination: destination,
            similarityScore: score,
            indexStatus: xy.0,
            workTreeStatus: xy.1,
            submoduleStateBytes: Data(fields[2]),
            headModeBytes: Data(fields[3]),
            indexModeBytes: Data(fields[4]),
            workTreeModeBytes: Data(fields[5]),
            headObjectIDBytes: Data(fields[6]),
            indexObjectIDBytes: Data(fields[7])
        )
    }

    private func consumeUnmerged(_ frame: Data) async throws {
        let fields = GitTargetEvidenceBytes.splitFields(frame, maximumSplits: 10)
        guard fields.count == 11 else {
            throw GitWorktreeInitializationError.malformedOutput("invalid porcelain-v2 unmerged record")
        }
        let xy = try GitTargetEvidenceBytes.statusPair(fields[1], kind: .unmerged)
        let path = try validator.validate(fields[10])
        try await emit(GitTargetStatusEvidenceRecord(
            kind: .unmerged,
            repositoryRelativePathBytes: path,
            sourceRepositoryRelativePathBytes: nil,
            similarityScore: nil,
            isDirectoryMarker: false,
            indexStatus: xy.0,
            workTreeStatus: xy.1,
            submoduleStateBytes: Data(fields[2]),
            headModeBytes: nil,
            indexModeBytes: nil,
            workTreeModeBytes: Data(fields[6]),
            headObjectIDBytes: nil,
            indexObjectIDBytes: nil,
            conflictStage1ModeBytes: Data(fields[3]),
            conflictStage2ModeBytes: Data(fields[4]),
            conflictStage3ModeBytes: Data(fields[5]),
            conflictStage1ObjectIDBytes: Data(fields[7]),
            conflictStage2ObjectIDBytes: Data(fields[8]),
            conflictStage3ObjectIDBytes: Data(fields[9])
        ))
    }

    private func consumeUntrackedOrIgnored(
        _ frame: Data,
        kind: GitTargetStatusEvidenceKind
    ) async throws {
        guard frame.count >= 3,
              frame[frame.index(after: frame.startIndex)] == UInt8(ascii: " ")
        else {
            throw GitWorktreeInitializationError.malformedOutput("invalid porcelain-v2 untracked/ignored record")
        }
        var rawPath = Data(frame.dropFirst(2))
        let isDirectoryMarker = rawPath.last == UInt8(ascii: "/")
        if isDirectoryMarker {
            rawPath.removeLast()
        }
        let path = try validator.validate(rawPath)
        try await emit(GitTargetStatusEvidenceRecord(
            kind: kind,
            repositoryRelativePathBytes: path,
            sourceRepositoryRelativePathBytes: nil,
            similarityScore: nil,
            isDirectoryMarker: isDirectoryMarker,
            indexStatus: nil,
            workTreeStatus: nil,
            submoduleStateBytes: nil,
            headModeBytes: nil,
            indexModeBytes: nil,
            workTreeModeBytes: nil,
            headObjectIDBytes: nil,
            indexObjectIDBytes: nil,
            conflictStage1ModeBytes: nil,
            conflictStage2ModeBytes: nil,
            conflictStage3ModeBytes: nil,
            conflictStage1ObjectIDBytes: nil,
            conflictStage2ObjectIDBytes: nil,
            conflictStage3ObjectIDBytes: nil
        ))
    }

    private func trackedRecord(
        kind: GitTargetStatusEvidenceKind,
        path: Data,
        source: Data?,
        similarityScore: UInt16?,
        indexStatus: UInt8,
        workTreeStatus: UInt8,
        submoduleStateBytes: Data,
        headModeBytes: Data,
        indexModeBytes: Data,
        workTreeModeBytes: Data,
        headObjectIDBytes: Data,
        indexObjectIDBytes: Data
    ) -> GitTargetStatusEvidenceRecord {
        GitTargetStatusEvidenceRecord(
            kind: kind,
            repositoryRelativePathBytes: path,
            sourceRepositoryRelativePathBytes: source,
            similarityScore: similarityScore,
            isDirectoryMarker: false,
            indexStatus: indexStatus,
            workTreeStatus: workTreeStatus,
            submoduleStateBytes: submoduleStateBytes,
            headModeBytes: headModeBytes,
            indexModeBytes: indexModeBytes,
            workTreeModeBytes: workTreeModeBytes,
            headObjectIDBytes: headObjectIDBytes,
            indexObjectIDBytes: indexObjectIDBytes,
            conflictStage1ModeBytes: nil,
            conflictStage2ModeBytes: nil,
            conflictStage3ModeBytes: nil,
            conflictStage1ObjectIDBytes: nil,
            conflictStage2ObjectIDBytes: nil,
            conflictStage3ObjectIDBytes: nil
        )
    }
}

private struct GitTargetEvidenceNULFramer {
    private let maximumFrameBytes: Int
    private var frame = Data()
    private var finished = false

    init(maximumFrameBytes: Int) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    mutating func consume(
        _ chunk: Data,
        handle: (Data) async throws -> Void
    ) async throws {
        guard !finished else {
            throw GitWorktreeInitializationError.malformedOutput("Git evidence parser consumed data after finish")
        }
        try Task.checkCancellation()
        var start = chunk.startIndex
        while start < chunk.endIndex {
            try Task.checkCancellation()
            if let terminator = chunk[start...].firstIndex(of: 0) {
                try append(chunk[start ..< terminator])
                let completeFrame = frame
                frame = Data()
                try await handle(completeFrame)
                start = chunk.index(after: terminator)
            } else {
                try append(chunk[start...])
                start = chunk.endIndex
            }
        }
    }

    mutating func finish() throws {
        guard !finished else { return }
        finished = true
        guard frame.isEmpty else {
            throw GitWorktreeInitializationError.malformedOutput("NUL-delimited output is not terminated")
        }
    }

    private mutating func append(_ bytes: Data.SubSequence) throws {
        guard bytes.count <= maximumFrameBytes - frame.count else {
            throw GitWorktreeInitializationError.pathLimitExceeded
        }
        frame.append(contentsOf: bytes)
    }
}

private struct GitTargetEvidencePathValidator {
    private let rootPrefixBytes: Data
    private let policy: GitTargetEvidencePathPolicy

    init(rootPrefix: GitRepositoryRelativeRootPrefix, policy: GitTargetEvidencePathPolicy) {
        rootPrefixBytes = Data(rootPrefix.value.utf8)
        self.policy = policy
    }

    func validate(_ rawBytes: some DataProtocol) throws -> Data {
        let bytes = Data(rawBytes)
        guard !bytes.isEmpty, bytes.first != UInt8(ascii: "/") else {
            throw GitWorktreeInitializationError.malformedOutput("invalid repository-relative path")
        }
        guard bytes.count <= policy.maximumPathBytes else {
            throw GitWorktreeInitializationError.pathLimitExceeded
        }

        var componentStart = bytes.startIndex
        var depth = 1
        for index in bytes.indices where bytes[index] == UInt8(ascii: "/") {
            try validateComponent(bytes[componentStart ..< index])
            depth += 1
            guard depth <= policy.maximumDepth else {
                throw GitWorktreeInitializationError.pathLimitExceeded
            }
            componentStart = bytes.index(after: index)
        }
        try validateComponent(bytes[componentStart...])

        guard rootPrefixBytes.isEmpty
            || bytes == rootPrefixBytes
            || (
                bytes.count > rootPrefixBytes.count
                    && bytes.prefix(rootPrefixBytes.count) == rootPrefixBytes
                    && bytes[bytes.index(bytes.startIndex, offsetBy: rootPrefixBytes.count)] == UInt8(ascii: "/")
            )
        else {
            throw GitWorktreeInitializationError.malformedOutput("path escapes the requested root prefix")
        }
        return bytes
    }

    private func validateComponent(_ component: Data.SubSequence) throws {
        guard !component.isEmpty,
              component != Data([UInt8(ascii: ".")]),
              component != Data([UInt8(ascii: "."), UInt8(ascii: ".")])
        else {
            throw GitWorktreeInitializationError.malformedOutput("path escapes the requested root prefix")
        }
    }
}

private enum GitTargetEvidenceBytes {
    static func splitFields(_ bytes: some DataProtocol, maximumSplits: Int) -> [Data.SubSequence] {
        Data(bytes).split(
            separator: UInt8(ascii: " "),
            maxSplits: maximumSplits,
            omittingEmptySubsequences: true
        )
    }

    static func requireUTF8(_ bytes: some DataProtocol, context: String) throws {
        guard String(data: Data(bytes), encoding: .utf8) != nil else {
            throw GitWorktreeInitializationError.malformedOutput("\(context) is not UTF-8")
        }
    }

    static func isMode(_ bytes: some DataProtocol) -> Bool {
        let data = Data(bytes)
        return data.count == 6
            && data.allSatisfy { (UInt8(ascii: "0") ... UInt8(ascii: "7")).contains($0) }
    }

    static func isModeOrZero(_ bytes: some DataProtocol) -> Bool {
        isMode(bytes)
    }

    static func zeroModeToNil(_ bytes: some DataProtocol) -> Data? {
        let data = Data(bytes)
        return data == Data("000000".utf8) ? nil : data
    }

    static func zeroObjectIDToNil(
        _ bytes: some DataProtocol,
        objectFormat: GitObjectFormat
    ) throws -> Data? {
        let data = Data(bytes)
        if data.count == objectFormat.oidHexCount, data.allSatisfy({ $0 == UInt8(ascii: "0") }) {
            return nil
        }
        try validateObjectID(data, objectFormat: objectFormat)
        return data
    }

    static func validateObjectID(_ bytes: some DataProtocol, objectFormat: GitObjectFormat) throws {
        let data = Data(bytes)
        guard data.count == objectFormat.oidHexCount,
              data.allSatisfy({ byte in
                  (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
              })
        else {
            throw GitWorktreeInitializationError.malformedOutput("invalid object ID")
        }
    }

    static func asciiInteger(_ bytes: some DataProtocol) -> Int? {
        let data = Data(bytes)
        guard !data.isEmpty,
              data.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return Int(String(decoding: data, as: UTF8.self))
    }

    static func similarityScore(_ bytes: some DataProtocol) throws -> UInt16 {
        let data = Data(bytes)
        guard data.count > 1,
              let value = asciiInteger(data.dropFirst()),
              (0 ... 100).contains(value)
        else {
            throw GitWorktreeInitializationError.malformedOutput("invalid rename/copy score")
        }
        return UInt16(value)
    }

    static func porcelainSimilarityScore(
        _ bytes: some DataProtocol,
        xy: (UInt8, UInt8)
    ) throws -> UInt16 {
        let data = Data(bytes)
        guard let prefix = data.first,
              prefix == UInt8(ascii: "R") || prefix == UInt8(ascii: "C"),
              xy.0 == prefix || xy.1 == prefix
        else {
            throw GitWorktreeInitializationError.malformedOutput("invalid porcelain-v2 rename/copy score")
        }
        return try similarityScore(data)
    }

    static func statusPair(
        _ bytes: some DataProtocol,
        kind: GitTargetStatusEvidenceKind
    ) throws -> (UInt8, UInt8) {
        let data = Data(bytes)
        guard data.count == 2 else {
            throw GitWorktreeInitializationError.malformedOutput("invalid porcelain-v2 XY length")
        }
        let first = data[data.startIndex]
        let second = data[data.index(after: data.startIndex)]
        let valid: Bool = switch kind {
        case .ordinary:
            Data(".MTADRC".utf8).contains(first) && Data(".MTDA".utf8).contains(second)
        case .renamed, .copied:
            Data(".MTADRC".utf8).contains(first)
                && Data(".MTDARC".utf8).contains(second)
                && (Data("RC".utf8).contains(first) || Data("RC".utf8).contains(second))
        case .unmerged:
            ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(String(decoding: data, as: UTF8.self))
        case .untracked, .ignored:
            false
        }
        guard valid else {
            throw GitWorktreeInitializationError.malformedOutput("invalid porcelain-v2 tracked XY value")
        }
        return (first, second)
    }
}
