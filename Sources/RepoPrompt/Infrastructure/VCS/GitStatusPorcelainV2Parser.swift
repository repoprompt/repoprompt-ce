import Foundation

struct GitStatusPorcelainV2Snapshot: Equatable {
    let branch: String?
    let headID: String?
    let upstream: String?
    let ahead: Int?
    let behind: Int?
    let staged: [String]
    let modified: [String]
    let untracked: [String]
    let pathRecords: [GitPorcelainV2PathRecord]
}

enum GitStatusPorcelainV2Parser {
    static func parse(_ output: String) throws -> GitStatusPorcelainV2Snapshot {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var branch: String?
        var headID: String?
        var upstream: String?
        var ahead: Int?
        var behind: Int?
        var staged: [String] = []
        var modified: [String] = []
        var untracked: [String] = []
        var pathRecords: [GitPorcelainV2PathRecord] = []

        var index = 0
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("# ") {
                parseHeader(
                    record,
                    branch: &branch,
                    headID: &headID,
                    upstream: &upstream,
                    ahead: &ahead,
                    behind: &behind
                )
                index += 1
                continue
            }

            guard let kind = record.first else {
                index += 1
                continue
            }
            switch kind {
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                guard fields.count == 9 else {
                    throw VCSError.parseError(message: "invalid porcelain-v2 ordinary record")
                }
                let path = String(fields[8])
                let xy = String(fields[1])
                try validateXY(xy, record: .ordinary)
                appendPathStatus(xy, path: path, staged: &staged, modified: &modified)
                pathRecords.append(
                    makeTrackedRecord(
                        kind: .ordinary,
                        xy: xy,
                        path: path,
                        submoduleState: String(fields[2]),
                        headMode: String(fields[3]),
                        indexMode: String(fields[4]),
                        workTreeMode: String(fields[5]),
                        headOID: String(fields[6]),
                        indexOID: String(fields[7])
                    )
                )
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
                guard fields.count == 10 else {
                    throw VCSError.parseError(message: "invalid porcelain-v2 rename/copy record")
                }
                let path = String(fields[9])
                let xy = String(fields[1])
                try validateXY(xy, record: .renamedOrCopied(originalPath: "", score: ""))
                let score = String(fields[8])
                try validateRenameOrCopyScore(score, xy: xy)
                appendPathStatus(xy, path: path, staged: &staged, modified: &modified)
                // The following NUL record is the original path. Status output should display
                // the destination path, matching the legacy porcelain-v1 parser.
                guard index + 1 < records.count else {
                    throw VCSError.parseError(message: "missing porcelain-v2 rename source path")
                }
                index += 1
                pathRecords.append(
                    makeTrackedRecord(
                        kind: .renamedOrCopied(
                            originalPath: records[index],
                            score: score
                        ),
                        xy: xy,
                        path: path,
                        submoduleState: String(fields[2]),
                        headMode: String(fields[3]),
                        indexMode: String(fields[4]),
                        workTreeMode: String(fields[5]),
                        headOID: String(fields[6]),
                        indexOID: String(fields[7])
                    )
                )
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                guard fields.count == 11 else {
                    throw VCSError.parseError(message: "invalid porcelain-v2 unmerged record")
                }
                let path = String(fields[10])
                let xy = String(fields[1])
                try validateXY(xy, record: .unmerged)
                appendPathStatus(xy, path: path, staged: &staged, modified: &modified)
                let statuses = statusCharacters(xy)
                pathRecords.append(
                    GitPorcelainV2PathRecord(
                        kind: .unmerged,
                        path: path,
                        indexStatus: statuses.0,
                        workTreeStatus: statuses.1,
                        submoduleState: String(fields[2]),
                        headMode: nil,
                        indexMode: nil,
                        workTreeMode: String(fields[6]),
                        headOID: nil,
                        indexOID: nil,
                        conflictStage1Mode: String(fields[3]),
                        conflictStage2Mode: String(fields[4]),
                        conflictStage3Mode: String(fields[5]),
                        conflictStage1OID: String(fields[7]),
                        conflictStage2OID: String(fields[8]),
                        conflictStage3OID: String(fields[9])
                    )
                )
            case "?":
                guard record.count >= 3 else {
                    throw VCSError.parseError(message: "invalid porcelain-v2 untracked record")
                }
                let path = String(record.dropFirst(2))
                untracked.append(path)
                pathRecords.append(makeUntrackedRecord(kind: .untracked, path: path))
            case "!":
                guard record.count >= 3 else {
                    throw VCSError.parseError(message: "invalid porcelain-v2 ignored record")
                }
                pathRecords.append(makeUntrackedRecord(kind: .ignored, path: String(record.dropFirst(2))))
            default:
                throw VCSError.parseError(message: "unsupported porcelain-v2 record type: \(kind)")
            }
            index += 1
        }

        return GitStatusPorcelainV2Snapshot(
            branch: branch,
            headID: headID,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            staged: Array(Set(staged)).sorted(),
            modified: Array(Set(modified)).sorted(),
            untracked: Array(Set(untracked)).sorted(),
            pathRecords: pathRecords
        )
    }

    private static func makeTrackedRecord(
        kind: GitPorcelainV2RecordKind,
        xy: String,
        path: String,
        submoduleState: String,
        headMode: String,
        indexMode: String,
        workTreeMode: String,
        headOID: String,
        indexOID: String
    ) -> GitPorcelainV2PathRecord {
        let statuses = statusCharacters(xy)
        return GitPorcelainV2PathRecord(
            kind: kind,
            path: path,
            indexStatus: statuses.0,
            workTreeStatus: statuses.1,
            submoduleState: submoduleState,
            headMode: headMode,
            indexMode: indexMode,
            workTreeMode: workTreeMode,
            headOID: headOID,
            indexOID: indexOID,
            conflictStage1Mode: nil,
            conflictStage2Mode: nil,
            conflictStage3Mode: nil,
            conflictStage1OID: nil,
            conflictStage2OID: nil,
            conflictStage3OID: nil
        )
    }

    private static func makeUntrackedRecord(
        kind: GitPorcelainV2RecordKind,
        path: String
    ) -> GitPorcelainV2PathRecord {
        GitPorcelainV2PathRecord(
            kind: kind,
            path: path,
            indexStatus: nil,
            workTreeStatus: nil,
            submoduleState: nil,
            headMode: nil,
            indexMode: nil,
            workTreeMode: nil,
            headOID: nil,
            indexOID: nil,
            conflictStage1Mode: nil,
            conflictStage2Mode: nil,
            conflictStage3Mode: nil,
            conflictStage1OID: nil,
            conflictStage2OID: nil,
            conflictStage3OID: nil
        )
    }

    private static func statusCharacters(_ xy: String) -> (Character, Character) {
        (xy[xy.startIndex], xy[xy.index(after: xy.startIndex)])
    }

    private static func validateXY(_ xy: String, record: GitPorcelainV2RecordKind) throws {
        guard xy.count == 2 else {
            throw VCSError.parseError(message: "invalid porcelain-v2 XY length")
        }
        let characters = statusCharacters(xy)
        switch record {
        case .ordinary:
            guard ".MTADRC".contains(characters.0), ".MTDA".contains(characters.1) else {
                throw VCSError.parseError(message: "invalid porcelain-v2 tracked XY value")
            }
        case .renamedOrCopied:
            guard ".MTADRC".contains(characters.0),
                  ".MTDARC".contains(characters.1),
                  "RC".contains(characters.0) || "RC".contains(characters.1)
            else {
                throw VCSError.parseError(message: "invalid porcelain-v2 tracked XY value")
            }
        case .unmerged:
            guard ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(xy) else {
                throw VCSError.parseError(message: "invalid porcelain-v2 unmerged XY value")
            }
        case .untracked, .ignored:
            throw VCSError.parseError(message: "unexpected porcelain-v2 XY value")
        }
    }

    private static func validateRenameOrCopyScore(_ score: String, xy: String) throws {
        guard let prefix = score.first,
              "RC".contains(prefix),
              xy.contains(prefix)
        else {
            throw VCSError.parseError(message: "invalid porcelain-v2 rename/copy score")
        }
    }

    private static func parseHeader(
        _ record: String,
        branch: inout String?,
        headID: inout String?,
        upstream: inout String?,
        ahead: inout Int?,
        behind: inout Int?
    ) {
        let payload = record.dropFirst(2)
        guard let separator = payload.firstIndex(of: " ") else { return }
        let key = payload[..<separator]
        let value = String(payload[payload.index(after: separator)...])
        switch key {
        case "branch.oid":
            headID = value == "(initial)" ? nil : value
        case "branch.head":
            branch = value == "(detached)" || value == "(unknown)" ? nil : value
        case "branch.upstream":
            upstream = value.isEmpty ? nil : value
        case "branch.ab":
            let counts = value.split(separator: " ")
            if counts.count == 2 {
                ahead = Int(counts[0].dropFirst())
                behind = Int(counts[1].dropFirst())
            }
        default:
            break
        }
    }

    private static func appendPathStatus(
        _ xy: String,
        path: String,
        staged: inout [String],
        modified: inout [String]
    ) {
        let indexStatus = xy[xy.startIndex]
        let workTreeStatus = xy[xy.index(after: xy.startIndex)]
        if indexStatus != ".", indexStatus != "?" {
            staged.append(path)
        }
        if workTreeStatus != ".", workTreeStatus != "?" {
            modified.append(path)
        }
    }
}
