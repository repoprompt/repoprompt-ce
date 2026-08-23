import Foundation

public enum DiffApplicationError: Error {
    case lineMismatch(expected: String, actual: String, line: Int)
    case outOfBounds(line: Int, contentSize: Int)
    case contextMismatch(expected: String, actual: String, line: Int)
    case incompleteApplication(expected: Int, actual: Int, operation: String)
    case invalidChange
    case changeNotApplied
}

public enum EditOperation {
    case keep(String)
    case insert(String)
    case delete(String)
}

public enum DiffApplicator {
    public static func apply(_ diffChunk: DiffChunk, to content: [String], startingAt startLine: Int) throws -> [String] {
        guard startLine >= 0, startLine <= content.count else {
            throw DiffApplicationError.outOfBounds(line: startLine, contentSize: content.count)
        }

        var result: [String] = []
        result.reserveCapacity(content.count)
        result.append(contentsOf: content[..<startLine])
        var contentIndex = startLine

        for diffLine in diffChunk.lines {
            switch diffLine.type {
            case .addition:
                result.append(diffLine.content)
            case .removal:
                guard contentIndex < content.count else {
                    return result
                }
                contentIndex += 1
            case .context:
                guard contentIndex < content.count else {
                    return result
                }
                result.append(content[contentIndex])
                contentIndex += 1
            }
        }

        result.append(contentsOf: content[contentIndex...])
        return result
    }

    public static func revert(_ diffChunk: DiffChunk, from content: [String], startingAt startLine: Int) throws -> [String] {
        // Handle the case of an empty file
        if content.isEmpty {
            return []
        }

        guard startLine >= 0, startLine <= content.count else {
            throw DiffApplicationError.outOfBounds(line: startLine, contentSize: content.count)
        }

        var result: [String] = []
        result.reserveCapacity(content.count)
        result.append(contentsOf: content[..<startLine])
        var contentIndex = startLine

        // Consume the post-apply content in diff order. Additions consume one
        // post-apply line; removals restore their original line without
        // consuming; context does both. This preserves mixed chunks and the
        // original ordering of adjacent removals without array shifts.
        for diffLine in diffChunk.lines {
            switch diffLine.type {
            case .addition:
                if contentIndex < content.count {
                    contentIndex += 1
                }
            case .removal:
                result.append(diffLine.content)
            case .context:
                if contentIndex < content.count {
                    result.append(content[contentIndex])
                }
                contentIndex += 1
            }
        }

        if contentIndex < content.count {
            result.append(contentsOf: content[contentIndex...])
        }
        return result
    }

    private static func applyEditOperations(_ operations: [EditOperation], to content: [String]) -> [String] {
        var result: [String] = []
        var contentIndex = 0

        for operation in operations {
            switch operation {
            case let .keep(line):
                result.append(line)
                contentIndex += 1
            case let .insert(line):
                result.append(line)
            case .delete:
                contentIndex += 1
            }
        }

        return result
    }

    public static func myersDiff(a: [String], b: [String]) throws -> [EditOperation] {
        let n = a.count
        let m = b.count
        let max = n + m

        var furthestReachingPaths = [Int: Int]()
        var editGraph = [[Int: Int]]()

        for d in 0 ... max {
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int = if k == -d || (k != d && furthestReachingPaths[k - 1, default: -1] < furthestReachingPaths[k + 1, default: -1]) {
                    furthestReachingPaths[k + 1, default: 0]
                } else {
                    furthestReachingPaths[k - 1, default: -1] + 1
                }

                var y = x - k

                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }

                furthestReachingPaths[k] = x

                if x >= n, y >= m {
                    editGraph.append(furthestReachingPaths)
                    return backtrack(trace: editGraph, a: a, b: b)
                }
            }
            editGraph.append(furthestReachingPaths)
        }

        throw DiffApplicationError.incompleteApplication(expected: b.count, actual: a.count, operation: "diff")
    }

    private static func backtrack(trace: [[Int: Int]], a: [String], b: [String]) -> [EditOperation] {
        var x = a.count
        var y = b.count
        var editOperations = [EditOperation]()

        for d in (0 ..< trace.count).reversed() {
            let v = trace[d]
            let k = x - y

            let prevK: Int = if k == -d || (k != d && v[k - 1, default: -1] < v[k + 1, default: -1]) {
                k + 1
            } else {
                k - 1
            }

            let prevX = v[prevK, default: 0]
            let prevY = prevX - prevK

            while x > prevX, y > prevY {
                editOperations.append(.keep(a[x - 1]))
                x -= 1
                y -= 1
            }

            if d > 0 {
                if x == prevX {
                    editOperations.append(.insert(b[y - 1]))
                    y -= 1
                } else {
                    editOperations.append(.delete(a[x - 1]))
                    x -= 1
                }
            }
        }

        return editOperations.reversed()
    }

    public static func ratio(_ a: [String], _ b: [String]) -> Double {
        let lcs = longestCommonSubsequence(a.joined(separator: "\n"), b.joined(separator: "\n"))
        return Double(2 * lcs.count) / Double(a.joined(separator: "\n").count + b.joined(separator: "\n").count)
    }

    private static func longestCommonSubsequence(_ str1: String, _ str2: String) -> String {
        let m = str1.count
        let n = str2.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1 ... m {
            for j in 1 ... n {
                if str1[str1.index(str1.startIndex, offsetBy: i - 1)] == str2[str2.index(str2.startIndex, offsetBy: j - 1)] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var lcs = ""
        var i = m, j = n
        while i > 0, j > 0 {
            if str1[str1.index(str1.startIndex, offsetBy: i - 1)] == str2[str2.index(str2.startIndex, offsetBy: j - 1)] {
                lcs = String(str1[str1.index(str1.startIndex, offsetBy: i - 1)]) + lcs
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return lcs
    }
}
