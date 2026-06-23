// File: RepoPrompt/Utils/DiffEditCreator.swift

import Foundation

struct DiffEdit {
    enum EditType {
        case addition
        case deletion
        case equal
    }

    let type: EditType
    let lines: [String]
}

class DiffEditCreator {
    static func myersDiff(
        oldLines: [String],
        newLines: [String],
        maximumEditDistance: Int? = nil
    ) -> [DiffEdit] {
        // Step 1: Initialize variables
        let n = oldLines.count
        let m = newLines.count
        let max = n + m
        var v = [Int: Int]()
        v[1] = 0
        var trace = [[Int: Int]]()

        // Step 2: Loop over the edit distance
        for d in 0 ... max {
            if let maximumEditDistance, d > maximumEditDistance {
                return []
            }
            var newV = v
            for k in stride(from: -d, through: d, by: 2) {
                // Determine the direction to move
                var x: Int = if k == -d || (k != d && v[k - 1]! < v[k + 1]!) {
                    v[k + 1]!
                } else {
                    v[k - 1]! + 1
                }
                var y = x - k

                // Follow diagonals (equal lines)
                while x < n, y < m, oldLines[x] == newLines[y] {
                    x += 1
                    y += 1
                }
                newV[k] = x
                // Check for solution
                if x >= n, y >= m {
                    trace.append(newV)
                    return buildDiffEdits(trace: trace, oldLines: oldLines, newLines: newLines)
                }
            }
            trace.append(newV)
            v = newV
        }
        // Should not reach here if inputs are valid
        return []
    }

    private static func buildDiffEdits(trace: [[Int: Int]], oldLines: [String], newLines: [String]) -> [DiffEdit] {
        var edits = [DiffEdit]()
        var x = oldLines.count
        var y = newLines.count

        // Backtrack through the trace
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            var prevK: Int = if k == -d || (k != d && v[k - 1, default: -1] < v[k + 1, default: -1]) {
                k + 1
            } else {
                k - 1
            }
            let prevX = v[prevK, default: 0]
            let prevY = prevX - prevK

            while x > prevX, y > prevY {
                // Equal lines
                if x > 0, y > 0 {
                    edits.append(DiffEdit(type: .equal, lines: [oldLines[x - 1]]))
                }
                x -= 1
                y -= 1
            }
            if x == prevX {
                // Addition
                if y > 0 {
                    edits.append(DiffEdit(type: .addition, lines: [newLines[y - 1]]))
                }
                y -= 1
            } else {
                // Deletion
                if x > 0 {
                    edits.append(DiffEdit(type: .deletion, lines: [oldLines[x - 1]]))
                }
                x -= 1
            }
        }
        return Array(edits.reversed())
    }
}
