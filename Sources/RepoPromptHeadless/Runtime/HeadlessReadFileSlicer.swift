import Foundation

struct HeadlessReadFileSlice: Equatable {
    var content: String
    var totalLines: Int
    var firstLine: Int
    var lastLine: Int
    var message: String?
}

enum HeadlessReadFileSlicer {
    static func slice(text: String, startLine: Int?, limit: Int?) throws -> HeadlessReadFileSlice {
        if let startLine {
            if startLine < 0, limit != nil {
                throw HeadlessCommandError("limit parameter is not allowed with negative start_line. Use start_line=-N to read the last N lines.", exitCode: 2)
            }
            if startLine == 0 {
                throw HeadlessCommandError("start_line must be positive (1-based) or negative (tail-like behavior)", exitCode: 2)
            }
        }

        let lines = splitPreservingLineEndings(text)
        let total = lines.count
        let first: Int
        let lastExclusive: Int

        if let startLine, startLine < 0 {
            let linesToRead = startLine == Int.min ? Int.max : -startLine
            first = max(0, total - linesToRead)
            lastExclusive = total
        } else {
            let requestedStart = startLine ?? 1
            first = max(0, requestedStart - 1)
            if let limit, limit >= 0 {
                if first >= total || limit >= total - first {
                    lastExclusive = total
                } else {
                    lastExclusive = first + limit
                }
            } else {
                lastExclusive = total
            }
        }

        if !(first < total || total == 0) {
            return HeadlessReadFileSlice(
                content: "",
                totalLines: total,
                firstLine: max(1, first + 1),
                lastLine: total,
                message: "Requested start_line exceeds file length."
            )
        }

        let content: String = if total == 0 || first >= lastExclusive {
            ""
        } else {
            lines[first ..< lastExclusive].map { $0.line + $0.ending }.joined()
        }
        return HeadlessReadFileSlice(
            content: content,
            totalLines: total,
            firstLine: total == 0 ? 0 : first + 1,
            lastLine: total == 0 ? 0 : lastExclusive,
            message: nil
        )
    }

    private static func splitPreservingLineEndings(_ content: String) -> [(line: String, ending: String)] {
        guard !content.isEmpty else { return [] }

        var result: [(String, String)] = []
        let scalars = content.unicodeScalars
        var lineStart = scalars.startIndex
        var index = scalars.startIndex

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\r" {
                let line = String(scalars[lineStart ..< index])
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == "\n" {
                    result.append((line, "\r\n"))
                    index = scalars.index(after: next)
                } else {
                    result.append((line, "\r"))
                    index = next
                }
                lineStart = index
            } else if scalar == "\n" {
                result.append((String(scalars[lineStart ..< index]), "\n"))
                index = scalars.index(after: index)
                lineStart = index
            } else {
                index = scalars.index(after: index)
            }
        }

        if lineStart < scalars.endIndex {
            result.append((String(scalars[lineStart ..< scalars.endIndex]), ""))
        }
        return result
    }
}
