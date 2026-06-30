import Foundation

struct GitObjectID: Hashable {
    let objectFormat: GitObjectFormat
    let lowercaseHex: String

    init(objectFormat: GitObjectFormat, lowercaseHex: String) throws {
        guard lowercaseHex.count == objectFormat.oidHexCount,
              lowercaseHex.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
              })
        else {
            throw GitWorktreeInitializationError.malformedOutput("invalid object ID")
        }
        self.objectFormat = objectFormat
        self.lowercaseHex = lowercaseHex
    }
}

struct GitRepositoryRelativeRootPrefix: Hashable {
    let value: String

    init(_ value: String, maximumUTF8Bytes: Int = 16 * 1024, maximumDepth: Int = 512) throws {
        guard value.utf8.count <= maximumUTF8Bytes else {
            throw GitWorktreeInitializationError.pathLimitExceeded
        }
        if value.isEmpty {
            self.value = ""
            return
        }
        guard !value.hasPrefix("/"), !value.hasSuffix("/"), !value.utf8.contains(0) else {
            throw GitWorktreeInitializationError.invalidRootPrefix
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= maximumDepth,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw GitWorktreeInitializationError.invalidRootPrefix
        }
        self.value = value
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value.utf8.count)
        for byte in value.utf8 {
            hasher.combine(byte)
        }
    }

    func contains(_ repositoryRelativePath: String) -> Bool {
        let pathBytes = Array(repositoryRelativePath.utf8)
        let prefixBytes = Array(value.utf8)
        guard !prefixBytes.isEmpty else { return true }
        if pathBytes == prefixBytes { return true }
        return pathBytes.starts(with: prefixBytes + [UInt8(ascii: "/")])
    }
}

struct GitWorktreeInitializationLimits: Equatable {
    let maximumRecordCount: Int
    let maximumOutputBytes: Int
    let maximumPathUTF8Bytes: Int
    let maximumPathDepth: Int
    let commandTimeout: Duration

    init(
        maximumRecordCount: Int,
        maximumOutputBytes: Int,
        maximumPathUTF8Bytes: Int = 16 * 1024,
        maximumPathDepth: Int = 512,
        commandTimeout: Duration
    ) {
        precondition(maximumRecordCount > 0)
        precondition(maximumOutputBytes > 0)
        precondition(maximumPathUTF8Bytes > 0)
        precondition(maximumPathDepth > 0)
        self.maximumRecordCount = maximumRecordCount
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumPathUTF8Bytes = maximumPathUTF8Bytes
        self.maximumPathDepth = maximumPathDepth
        self.commandTimeout = commandTimeout
    }

    static let treeInventory = GitWorktreeInitializationLimits(
        maximumRecordCount: 1_000_000,
        maximumOutputBytes: 128 * 1024 * 1024,
        commandTimeout: .seconds(10)
    )
    static let delta = GitWorktreeInitializationLimits(
        maximumRecordCount: 10000,
        maximumOutputBytes: 32 * 1024 * 1024,
        commandTimeout: .seconds(5)
    )
    static let index = delta
    static let status = delta
}

enum GitWorktreeInitializationFailureReason: String, Equatable {
    case timeout
    case gitError
    case malformedOutput
    case cappedOutput
    case recordLimitExceeded
    case pathLimitExceeded
    case invalidRootPrefix
    case cancelled
}

enum GitWorktreeInitializationError: LocalizedError, Equatable {
    case timeout
    case gitFailure(exitCode: Int32)
    case malformedOutput(String)
    case outputLimitExceeded
    case recordLimitExceeded
    case pathLimitExceeded
    case invalidRootPrefix

    var reason: GitWorktreeInitializationFailureReason {
        switch self {
        case .timeout: .timeout
        case .gitFailure: .gitError
        case .malformedOutput: .malformedOutput
        case .outputLimitExceeded: .cappedOutput
        case .recordLimitExceeded: .recordLimitExceeded
        case .pathLimitExceeded: .pathLimitExceeded
        case .invalidRootPrefix: .invalidRootPrefix
        }
    }

    var errorDescription: String? {
        switch self {
        case .timeout:
            "The bounded Git authority command timed out."
        case let .gitFailure(exitCode):
            "The bounded Git authority command failed with exit code \(exitCode)."
        case let .malformedOutput(detail):
            "Git returned malformed authority data: \(detail)"
        case .outputLimitExceeded:
            "Git authority output exceeded its byte limit."
        case .recordLimitExceeded:
            "Git authority output exceeded its record limit."
        case .pathLimitExceeded:
            "A Git authority path exceeded its bounded path policy."
        case .invalidRootPrefix:
            "The Git authority root prefix is not a canonical repository-relative path."
        }
    }
}

enum GitTreeEntryKind: String, Equatable, Hashable {
    case blob
    case tree
    case commit
}

struct GitTreeInventoryEntry: Equatable {
    let mode: String
    let kind: GitTreeEntryKind
    let objectID: GitObjectID
    let repositoryRelativePath: String
}

struct GitTreeInventorySnapshot: Equatable {
    let treeOID: GitObjectID
    let rootPrefix: GitRepositoryRelativeRootPrefix
    let prefixEntry: GitTreeInventoryEntry?
    let entries: [GitTreeInventoryEntry]
    let outputByteCount: Int
}

enum GitTreeDeltaStatus: Equatable {
    case added
    case deleted
    case modified
    case typeChanged
    case renamed(score: Int)
    case copied(score: Int)
    case unmerged
}

struct GitTreeDeltaRecord: Equatable {
    let oldMode: String?
    let newMode: String?
    let oldObjectID: GitObjectID?
    let newObjectID: GitObjectID?
    let status: GitTreeDeltaStatus
    let sourceRepositoryRelativePath: String?
    let repositoryRelativePath: String
}

struct GitIndexManifestEntry: Equatable {
    let mode: String
    let objectID: GitObjectID
    let stage: Int
    let repositoryRelativePath: String
    let assumeUnchanged: Bool
    let skipWorktree: Bool
}

struct GitIndexManifest: Equatable {
    let rootPrefix: GitRepositoryRelativeRootPrefix
    let entries: [GitIndexManifestEntry]
    let outputByteCount: Int
    let sparseCheckoutEnabled: Bool

    init(
        rootPrefix: GitRepositoryRelativeRootPrefix,
        entries: [GitIndexManifestEntry],
        outputByteCount: Int,
        sparseCheckoutEnabled: Bool = false
    ) {
        self.rootPrefix = rootPrefix
        self.entries = entries
        self.outputByteCount = outputByteCount
        self.sparseCheckoutEnabled = sparseCheckoutEnabled
    }
}

enum GitTreeInventoryParser {
    static func parseTreeInventory(
        _ data: Data,
        treeOID: GitObjectID,
        rootPrefix: GitRepositoryRelativeRootPrefix,
        limits: GitWorktreeInitializationLimits
    ) throws -> GitTreeInventorySnapshot {
        try validateOutputSize(data, limits: limits)
        try validateNULTermination(data)
        var cursor = GitNULRecordCursor(data)
        var entries: [GitTreeInventoryEntry] = []
        var prefixEntry: GitTreeInventoryEntry?
        var paths: [String: GitTreeInventoryEntry] = [:]
        var count = 0
        while let record = cursor.next() {
            count += 1
            try validateRecordCount(count, limits: limits)
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")) else {
                throw GitWorktreeInitializationError.malformedOutput("ls-tree record has no path separator")
            }
            let header = try strictString(record[..<tab], context: "ls-tree header")
            let path = try validatedPath(
                record[record.index(after: tab)...],
                rootPrefix: rootPrefix,
                limits: limits
            )
            let fields = header.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3,
                  validMode(String(fields[0])),
                  let kind = GitTreeEntryKind(rawValue: String(fields[1]))
            else {
                throw GitWorktreeInitializationError.malformedOutput("invalid ls-tree metadata")
            }
            let entry = try GitTreeInventoryEntry(
                mode: String(fields[0]),
                kind: kind,
                objectID: GitObjectID(
                    objectFormat: treeOID.objectFormat,
                    lowercaseHex: String(fields[2])
                ),
                repositoryRelativePath: path
            )
            if path == rootPrefix.value, kind == .tree, !rootPrefix.value.isEmpty {
                if let prefixEntry, prefixEntry != entry {
                    throw GitWorktreeInitializationError.malformedOutput("incompatible duplicate prefix tree")
                }
                prefixEntry = entry
                continue
            }
            if let existing = paths[path] {
                guard existing == entry else {
                    throw GitWorktreeInitializationError.malformedOutput("incompatible duplicate tree path")
                }
                continue
            }
            paths[path] = entry
            entries.append(entry)
        }
        return GitTreeInventorySnapshot(
            treeOID: treeOID,
            rootPrefix: rootPrefix,
            prefixEntry: prefixEntry,
            entries: entries,
            outputByteCount: data.count
        )
    }

    static func parseTreeDelta(
        _ data: Data,
        objectFormat: GitObjectFormat,
        rootPrefix: GitRepositoryRelativeRootPrefix,
        limits: GitWorktreeInitializationLimits
    ) throws -> [GitTreeDeltaRecord] {
        try validateOutputSize(data, limits: limits)
        try validateNULTermination(data)
        var cursor = GitNULRecordCursor(data)
        var result: [GitTreeDeltaRecord] = []
        while let metadataData = cursor.next() {
            try validateRecordCount(result.count + 1, limits: limits)
            let metadata = try strictString(metadataData, context: "diff-tree metadata")
            guard metadata.first == ":" else {
                throw GitWorktreeInitializationError.malformedOutput("raw delta metadata is missing ':'")
            }
            let fields = metadata.dropFirst().split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 5,
                  validModeOrZero(String(fields[0])),
                  validModeOrZero(String(fields[1]))
            else {
                throw GitWorktreeInitializationError.malformedOutput("invalid raw delta metadata")
            }
            let rawStatus = String(fields[4])
            let status = try deltaStatus(rawStatus)
            let firstPathData = try requireRecord(cursor.next(), context: "missing delta path")
            let firstPath = try validatedPath(firstPathData, rootPrefix: rootPrefix, limits: limits)
            let sourcePath: String?
            let destinationPath: String
            switch status {
            case .renamed, .copied:
                sourcePath = firstPath
                destinationPath = try validatedPath(
                    requireRecord(cursor.next(), context: "missing rename/copy destination"),
                    rootPrefix: rootPrefix,
                    limits: limits
                )
            default:
                sourcePath = nil
                destinationPath = firstPath
            }
            try result.append(GitTreeDeltaRecord(
                oldMode: zeroModeToNil(String(fields[0])),
                newMode: zeroModeToNil(String(fields[1])),
                oldObjectID: zeroOIDToNil(String(fields[2]), objectFormat: objectFormat),
                newObjectID: zeroOIDToNil(String(fields[3]), objectFormat: objectFormat),
                status: status,
                sourceRepositoryRelativePath: sourcePath,
                repositoryRelativePath: destinationPath
            ))
        }
        return result
    }

    static func parseIndexManifest(
        _ data: Data,
        objectFormat: GitObjectFormat,
        rootPrefix: GitRepositoryRelativeRootPrefix,
        limits: GitWorktreeInitializationLimits,
        sparseCheckoutEnabled: Bool = false
    ) throws -> GitIndexManifest {
        try validateOutputSize(data, limits: limits)
        try validateNULTermination(data)
        var cursor = GitNULRecordCursor(data)
        var entries: [GitIndexManifestEntry] = []
        var seen: [String: GitIndexManifestEntry] = [:]
        while let record = cursor.next() {
            try validateRecordCount(entries.count + 1, limits: limits)
            guard record.count >= 3,
                  let tag = record.first,
                  record[record.index(after: record.startIndex)] == UInt8(ascii: " "),
                  let tab = record.firstIndex(of: UInt8(ascii: "\t"))
            else {
                throw GitWorktreeInitializationError.malformedOutput("invalid ls-files record")
            }
            let metadataStart = record.index(record.startIndex, offsetBy: 2)
            let metadata = try strictString(record[metadataStart ..< tab], context: "ls-files metadata")
            let fields = metadata.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3,
                  validMode(String(fields[0])),
                  let stage = Int(fields[2]),
                  (0 ... 3).contains(stage)
            else {
                throw GitWorktreeInitializationError.malformedOutput("invalid ls-files metadata")
            }
            let path = try validatedPath(
                record[record.index(after: tab)...],
                rootPrefix: rootPrefix,
                limits: limits
            )
            let entry = try GitIndexManifestEntry(
                mode: String(fields[0]),
                objectID: GitObjectID(objectFormat: objectFormat, lowercaseHex: String(fields[1])),
                stage: stage,
                repositoryRelativePath: path,
                assumeUnchanged: Character(UnicodeScalar(tag)).isLowercase,
                skipWorktree: tag == UInt8(ascii: "S") || tag == UInt8(ascii: "s")
            )
            let key = "\(path)\0\(stage)"
            if let existing = seen[key] {
                guard existing == entry else {
                    throw GitWorktreeInitializationError.malformedOutput("incompatible duplicate index entry")
                }
                continue
            }
            seen[key] = entry
            entries.append(entry)
        }
        return GitIndexManifest(
            rootPrefix: rootPrefix,
            entries: entries,
            outputByteCount: data.count,
            sparseCheckoutEnabled: sparseCheckoutEnabled
        )
    }

    static func validateStatusSnapshot(
        _ data: Data,
        rootPrefix: GitRepositoryRelativeRootPrefix,
        limits: GitWorktreeInitializationLimits
    ) throws -> GitStatusPorcelainV2Snapshot {
        try validateOutputSize(data, limits: limits)
        try validateNULTermination(data)
        guard let output = String(data: data, encoding: .utf8) else {
            throw GitWorktreeInitializationError.malformedOutput("status output is not UTF-8")
        }
        let snapshot: GitStatusPorcelainV2Snapshot
        do {
            snapshot = try GitStatusPorcelainV2Parser.parse(output)
        } catch {
            throw GitWorktreeInitializationError.malformedOutput("invalid porcelain-v2 status")
        }
        try validateRecordCount(snapshot.pathRecords.count, limits: limits)
        for record in snapshot.pathRecords {
            let validatedRecordPath: String = if record.kind == .untracked || record.kind == .ignored,
                                                 record.path.hasSuffix("/"),
                                                 !record.path.dropLast().isEmpty,
                                                 !record.path.dropLast().hasSuffix("/")
            {
                String(record.path.dropLast())
            } else {
                record.path
            }
            try validatePathString(validatedRecordPath, rootPrefix: rootPrefix, limits: limits)
            if case let .renamedOrCopied(originalPath, _) = record.kind {
                try validatePathString(originalPath, rootPrefix: rootPrefix, limits: limits)
            }
        }
        return snapshot
    }

    private static func validatedPath(
        _ data: Data.SubSequence,
        rootPrefix: GitRepositoryRelativeRootPrefix,
        limits: GitWorktreeInitializationLimits
    ) throws -> String {
        let path = try strictString(data, context: "path")
        try validatePathString(path, rootPrefix: rootPrefix, limits: limits)
        return path
    }

    private static func validatePathString(
        _ path: String,
        rootPrefix: GitRepositoryRelativeRootPrefix,
        limits: GitWorktreeInitializationLimits
    ) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw GitWorktreeInitializationError.malformedOutput("invalid repository-relative path")
        }
        guard path.utf8.count <= limits.maximumPathUTF8Bytes else {
            throw GitWorktreeInitializationError.pathLimitExceeded
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= limits.maximumPathDepth else {
            throw GitWorktreeInitializationError.pathLimitExceeded
        }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              rootPrefix.contains(path)
        else {
            throw GitWorktreeInitializationError.malformedOutput("path escapes the requested root prefix")
        }
    }

    private static func deltaStatus(_ raw: String) throws -> GitTreeDeltaStatus {
        guard let first = raw.first else {
            throw GitWorktreeInitializationError.malformedOutput("missing delta status")
        }
        switch first {
        case "A": return .added
        case "D": return .deleted
        case "M": return .modified
        case "T": return .typeChanged
        case "U": return .unmerged
        case "R": return try .renamed(score: deltaScore(raw))
        case "C": return try .copied(score: deltaScore(raw))
        default:
            throw GitWorktreeInitializationError.malformedOutput("unsupported delta status")
        }
    }

    private static func deltaScore(_ raw: String) throws -> Int {
        guard raw.count > 1, let score = Int(raw.dropFirst()), (0 ... 100).contains(score) else {
            throw GitWorktreeInitializationError.malformedOutput("invalid rename/copy score")
        }
        return score
    }

    private static func zeroModeToNil(_ value: String) -> String? {
        value == "000000" ? nil : value
    }

    private static func zeroOIDToNil(_ value: String, objectFormat: GitObjectFormat) throws -> GitObjectID? {
        if value.count == objectFormat.oidHexCount, value.allSatisfy({ $0 == "0" }) {
            return nil
        }
        return try GitObjectID(objectFormat: objectFormat, lowercaseHex: value)
    }

    private static func validMode(_ value: String) -> Bool {
        value.count == 6 && value.utf8.allSatisfy { (UInt8(ascii: "0") ... UInt8(ascii: "7")).contains($0) }
    }

    private static func validModeOrZero(_ value: String) -> Bool {
        value == "000000" || validMode(value)
    }

    private static func strictString(_ data: Data.SubSequence, context: String) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw GitWorktreeInitializationError.malformedOutput("\(context) is not UTF-8")
        }
        return value
    }

    private static func validateOutputSize(
        _ data: Data,
        limits: GitWorktreeInitializationLimits
    ) throws {
        guard data.count <= limits.maximumOutputBytes else {
            throw GitWorktreeInitializationError.outputLimitExceeded
        }
    }

    private static func validateNULTermination(_ data: Data) throws {
        guard data.isEmpty || data.last == 0 else {
            throw GitWorktreeInitializationError.malformedOutput("NUL-delimited output is not terminated")
        }
    }

    private static func validateRecordCount(
        _ count: Int,
        limits: GitWorktreeInitializationLimits
    ) throws {
        guard count <= limits.maximumRecordCount else {
            throw GitWorktreeInitializationError.recordLimitExceeded
        }
    }

    private static func requireRecord(
        _ record: Data.SubSequence?,
        context: String
    ) throws -> Data.SubSequence {
        guard let record else {
            throw GitWorktreeInitializationError.malformedOutput(context)
        }
        return record
    }
}

private struct GitNULRecordCursor {
    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func next() -> Data.SubSequence? {
        guard offset < data.count else { return nil }
        guard let terminator = data[offset...].firstIndex(of: 0) else {
            offset = data.count
            return data[offset...]
        }
        let record = data[offset ..< terminator]
        offset = terminator + 1
        return record
    }
}
