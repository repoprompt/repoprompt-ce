import Foundation

/// Failures at a Git machine-output boundary. Never substitute an empty successful record.
public enum GitDiffRecordError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformed(String)
    case invalidUTF8
    case unterminatedRecord
    case fieldLimitExceeded

    public var description: String {
        switch self {
        case let .malformed(reason): "malformed Git output: \(reason)"
        case .invalidUTF8: "Git pathname or metadata is not valid UTF-8"
        case .unterminatedRecord: "unterminated Git record"
        case .fieldLimitExceeded: "Git record exceeds the configured field byte limit"
        }
    }
}

/// Exact bytes from Git. Search folding, URL decoding and filesystem canonicalization are separate operations.
public struct GitDiffPath: Hashable, Sendable {
    public let bytes: Data

    public init(bytes: Data) throws {
        guard !bytes.isEmpty, !bytes.contains(0) else {
            throw GitDiffRecordError.malformed("missing a path or embedded NUL")
        }
        self.bytes = bytes
    }

    public func utf8String() throws -> String {
        try GitDiffMachineRecords.utf8(bytes)
    }
}

public struct GitNumstatRecord: Sendable, Equatable {
    public let path: GitDiffPath
    public let originalPath: GitDiffPath?
    public let additions: Int?
    public let deletions: Int?
}

public struct GitNameStatusRecord: Sendable, Equatable {
    public let path: GitDiffPath
    public let originalPath: GitDiffPath?
    public let status: String
}

/// NUL-framed ordinary Git diff records. Path bytes remain exact until explicit UTF-8 export.
public enum GitDiffMachineRecords {
    public static func utf8(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else { throw GitDiffRecordError.invalidUTF8 }
        return value
    }

    public static func paths(_ data: Data) throws -> [GitDiffPath] {
        var fields = GitDiffNULCursor(data)
        var result: [GitDiffPath] = []
        while !fields.isAtEnd {
            try Task.checkCancellation()
            try result.append(GitDiffPath(bytes: fields.next()))
        }
        return result
    }

    public static func numstat(_ data: Data) throws -> [GitNumstatRecord] {
        var fields = GitDiffNULCursor(data)
        var result: [GitNumstatRecord] = []
        while !fields.isAtEnd {
            try Task.checkCancellation()
            let field = try fields.next()
            let countsAndPath = field.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard countsAndPath.count == 3 else { throw GitDiffRecordError.malformed("numstat fields") }
            let additions = try count(Data(countsAndPath[0]))
            let deletions = try count(Data(countsAndPath[1]))
            let original: GitDiffPath?
            let path: GitDiffPath
            if countsAndPath[2].isEmpty {
                original = try GitDiffPath(bytes: fields.next())
                path = try GitDiffPath(bytes: fields.next())
            } else {
                original = nil
                path = try GitDiffPath(bytes: Data(countsAndPath[2]))
            }
            result.append(GitNumstatRecord(path: path, originalPath: original, additions: additions, deletions: deletions))
        }
        return result
    }

    public static func nameStatus(_ data: Data) throws -> [GitNameStatusRecord] {
        var fields = GitDiffNULCursor(data)
        var result: [GitNameStatusRecord] = []
        while !fields.isAtEnd {
            try Task.checkCancellation()
            let status = try utf8(fields.next())
            guard let first = status.utf8.first, Array("ACDMRTUXB".utf8).contains(first),
                  status.utf8.dropFirst().allSatisfy({ (48 ... 57).contains($0) })
            else { throw GitDiffRecordError.malformed("name-status code") }
            let renamed = first == 82 || first == 67
            let scoreBytes = Data(status.utf8.dropFirst())
            if renamed || !scoreBytes.isEmpty {
                guard renamed || first == 77,
                      !scoreBytes.isEmpty,
                      let score = try Int(utf8(scoreBytes)), (0 ... 100).contains(score)
                else { throw GitDiffRecordError.malformed("name-status score") }
            }
            let firstPath = try GitDiffPath(bytes: fields.next())
            let path = try renamed ? GitDiffPath(bytes: fields.next()) : firstPath
            result.append(GitNameStatusRecord(path: path, originalPath: renamed ? firstPath : nil, status: status))
        }
        return result
    }

    private static func count(_ data: Data) throws -> Int? {
        if data == Data([45]) { return nil }
        guard !data.isEmpty, data.allSatisfy({ (48 ... 57).contains($0) }), let value = try Int(utf8(data)) else {
            throw GitDiffRecordError.malformed("numstat count")
        }
        return value
    }
}

/// A bounded field cursor. Retains one output buffer and copies only fields that become records.
struct GitDiffNULCursor {
    let data: Data
    var position: Data.Index
    let maximumFieldBytes: Int

    init(_ data: Data, maximumFieldBytes: Int = 8 * 1024 * 1024) {
        self.data = data
        position = data.startIndex
        self.maximumFieldBytes = maximumFieldBytes
    }

    var isAtEnd: Bool {
        position == data.endIndex
    }

    mutating func next() throws -> Data {
        guard position < data.endIndex else { throw GitDiffRecordError.unterminatedRecord }
        var end = position
        while end < data.endIndex, data[end] != 0 {
            if end - position >= maximumFieldBytes { throw GitDiffRecordError.fieldLimitExceeded }
            end += 1
        }
        guard end < data.endIndex else { throw GitDiffRecordError.unterminatedRecord }
        let result = Data(data[position ..< end])
        position = end + 1
        return result
    }
}
