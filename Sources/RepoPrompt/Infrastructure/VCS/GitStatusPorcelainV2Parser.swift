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
                appendPathStatus(String(fields[1]), path: String(fields[8]), staged: &staged, modified: &modified)
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
                guard fields.count == 10 else {
                    throw VCSError.parseError(message: "invalid porcelain-v2 rename/copy record")
                }
                appendPathStatus(String(fields[1]), path: String(fields[9]), staged: &staged, modified: &modified)
                // The following NUL record is the original path. Status output should display
                // the destination path, matching the legacy porcelain-v1 parser.
                if index + 1 < records.count {
                    index += 1
                }
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                guard fields.count == 11 else {
                    throw VCSError.parseError(message: "invalid porcelain-v2 unmerged record")
                }
                appendPathStatus(String(fields[1]), path: String(fields[10]), staged: &staged, modified: &modified)
            case "?":
                guard record.count >= 3 else {
                    throw VCSError.parseError(message: "invalid porcelain-v2 untracked record")
                }
                untracked.append(String(record.dropFirst(2)))
            case "!":
                break
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
            untracked: Array(Set(untracked)).sorted()
        )
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
        guard xy.count >= 2 else { return }
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
