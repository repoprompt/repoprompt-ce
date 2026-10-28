import Foundation
import RepoPromptFileSystem

/// Utilities for parsing unified diff patches and managing truncation.
package enum GitDiffPatchParsing {
    // MARK: - Types

    /// A parsed hunk from a unified diff.
    package struct ParsedHunk: Equatable {
        package let header: String
        package let oldStart: Int
        package let oldLines: Int
        package let newStart: Int
        package let newLines: Int
        package let content: String

        package init(
            header: String,
            oldStart: Int,
            oldLines: Int,
            newStart: Int,
            newLines: Int,
            content: String
        ) {
            self.header = header
            self.oldStart = oldStart
            self.oldLines = oldLines
            self.newStart = newStart
            self.newLines = newLines
            self.content = content
        }
    }

    /// A file with its parsed hunks for inline diff responses.
    package struct ParsedFileHunks {
        package let path: String
        package let status: String
        package let insertions: Int
        package let deletions: Int
        package let hunks: [ParsedHunk]

        /// Total line count (header + content lines per hunk)
        package var lineCount: Int {
            hunks.reduce(0) { $0 + 1 + $1.content.components(separatedBy: "\n").count }
        }

        package init(
            path: String,
            status: String,
            insertions: Int,
            deletions: Int,
            hunks: [ParsedHunk]
        ) {
            self.path = path
            self.status = status
            self.insertions = insertions
            self.deletions = deletions
            self.hunks = hunks
        }
    }

    /// Result of truncation operation.
    package struct TruncationResult {
        package let files: [ParsedFileHunks]
        package let truncated: Bool
        package let note: String?

        package init(
            files: [ParsedFileHunks],
            truncated: Bool,
            note: String? = nil
        ) {
            self.files = files
            self.truncated = truncated
            self.note = note
        }
    }

    // MARK: - Hunk Parsing

    /// Regular expression for hunk headers: @@ -start,count +start,count @@
    private static let hunkHeaderRegex = try! NSRegularExpression(
        pattern: #"^@@\s*-(\d+)(?:,(\d+))?\s*\+(\d+)(?:,(\d+))?\s*@@"#,
        options: []
    )

    /// Parses hunks from a patch text (single file diff).
    package static func parseHunks(from patchText: String) -> [ParsedHunk] {
        let lines = patchText.components(separatedBy: "\n")
        var hunks: [ParsedHunk] = []
        var currentHunkHeader: String?
        var currentHunkContent: [String] = []
        var currentHunkMeta: (oldStart: Int, oldLines: Int, newStart: Int, newLines: Int)?

        for line in lines {
            if line.hasPrefix("@@") {
                // Finalize previous hunk if any
                if let header = currentHunkHeader, let meta = currentHunkMeta {
                    hunks.append(ParsedHunk(
                        header: header,
                        oldStart: meta.oldStart,
                        oldLines: meta.oldLines,
                        newStart: meta.newStart,
                        newLines: meta.newLines,
                        content: currentHunkContent.joined(separator: "\n")
                    ))
                }

                // Parse new hunk header
                currentHunkHeader = line
                currentHunkContent = []
                currentHunkMeta = parseHunkHeader(line)
            } else if currentHunkHeader != nil {
                // Inside a hunk, collect content lines
                currentHunkContent.append(line)
            }
            // Lines before first hunk (diff headers) are ignored
        }

        // Finalize last hunk
        if let header = currentHunkHeader, let meta = currentHunkMeta {
            hunks.append(ParsedHunk(
                header: header,
                oldStart: meta.oldStart,
                oldLines: meta.oldLines,
                newStart: meta.newStart,
                newLines: meta.newLines,
                content: currentHunkContent.joined(separator: "\n")
            ))
        }

        return hunks
    }

    /// Parses the numeric values from a hunk header line.
    package static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldLines: Int, newStart: Int, newLines: Int)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = hunkHeaderRegex.firstMatch(in: line, options: [], range: range) else {
            return nil
        }

        func intAt(_ index: Int) -> Int {
            guard let swiftRange = Range(match.range(at: index), in: line) else {
                return index == 2 || index == 4 ? 1 : 0 // Default count is 1 if not specified
            }
            return Int(line[swiftRange]) ?? (index == 2 || index == 4 ? 1 : 0)
        }

        let oldStart = intAt(1)
        let oldLines = match.range(at: 2).location != NSNotFound ? intAt(2) : 1
        let newStart = intAt(3)
        let newLines = match.range(at: 4).location != NSNotFound ? intAt(4) : 1

        return (oldStart, oldLines, newStart, newLines)
    }

    // MARK: - Truncation

    /// Truncates patches to fit within a line budget.
    ///
    /// Strategy:
    /// 1. Sort files by churn (insertions + deletions) descending
    /// 2. Include full patches until budget is exhausted
    /// 3. For remaining files, include only headers with truncation markers
    ///
    /// - Parameters:
    ///   - files: Files with their parsed hunks
    ///   - maxLines: Maximum total lines to include
    /// - Returns: Truncated files, whether truncation occurred, and a note about omitted content
    package static func truncatePatches(
        files: [ParsedFileHunks],
        maxLines: Int
    ) -> TruncationResult {
        guard maxLines > 0 else {
            return TruncationResult(files: [], truncated: true, note: "No lines available")
        }

        // Sort by churn (highest first) to prioritize important changes
        let sorted = files.sorted { ($0.insertions + $0.deletions) > ($1.insertions + $1.deletions) }

        var result: [ParsedFileHunks] = []
        var usedLines = 0
        var omittedFiles: [(path: String, lines: Int)] = []

        for file in sorted {
            let fileLines = file.lineCount
            if usedLines + fileLines <= maxLines {
                // Include full file
                result.append(file)
                usedLines += fileLines
            } else {
                // File doesn't fit, try to include truncated version
                let remainingBudget = maxLines - usedLines
                if remainingBudget > 0 {
                    // Try to include some hunks
                    let truncated = truncateFileHunks(file, maxLines: remainingBudget)
                    if truncated.lineCount > 0 {
                        result.append(truncated)
                        usedLines += truncated.lineCount
                    }
                }
                omittedFiles.append((file.path, fileLines))
            }
        }

        let truncated = !omittedFiles.isEmpty
        var note: String?
        if truncated {
            let omittedList = omittedFiles
                .prefix(5)
                .map { "\($0.path) (\($0.lines) lines)" }
                .joined(separator: ", ")
            let moreCount = max(0, omittedFiles.count - 5)
            let moreText = moreCount > 0 ? " and \(moreCount) more" : ""
            note = "Showing \(usedLines) of \(files.reduce(0) { $0 + $1.lineCount }) lines. Omitted: \(omittedList)\(moreText)"
        }

        return TruncationResult(files: result, truncated: truncated, note: note)
    }

    /// Truncates a single file's hunks to fit within a line budget.
    private static func truncateFileHunks(_ file: ParsedFileHunks, maxLines: Int) -> ParsedFileHunks {
        var truncatedHunks: [ParsedHunk] = []
        var usedLines = 0

        for hunk in file.hunks {
            let hunkLines = 1 + hunk.content.components(separatedBy: "\n").count
            if usedLines + hunkLines <= maxLines {
                truncatedHunks.append(hunk)
                usedLines += hunkLines
            } else {
                // Partial hunk inclusion
                let remainingBudget = maxLines - usedLines - 1 // -1 for header
                if remainingBudget > 0 {
                    let contentLines = hunk.content.components(separatedBy: "\n")
                    let includedContent = contentLines.prefix(remainingBudget).joined(separator: "\n")
                    let omittedCount = contentLines.count - remainingBudget
                    let truncatedContent = includedContent + "\n[+\(omittedCount) more lines]"
                    truncatedHunks.append(ParsedHunk(
                        header: hunk.header,
                        oldStart: hunk.oldStart,
                        oldLines: hunk.oldLines,
                        newStart: hunk.newStart,
                        newLines: hunk.newLines,
                        content: truncatedContent
                    ))
                }
                break
            }
        }

        return ParsedFileHunks(
            path: file.path,
            status: file.status,
            insertions: file.insertions,
            deletions: file.deletions,
            hunks: truncatedHunks
        )
    }

    // MARK: - Statistics

    /// Counts insertions and deletions from a patch text.
    package static func countChanges(in patchText: String) -> (insertions: Int, deletions: Int) {
        var insertions = 0
        var deletions = 0

        for line in patchText.components(separatedBy: "\n") {
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                insertions += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                deletions += 1
            }
        }

        return (insertions, deletions)
    }

    // MARK: - Changed Lines Extraction

    /// A single changed line from a diff.
    package struct ChangedLine: Equatable {
        package let path: String
        package let lineNumber: Int
        package let changeType: Character // "+" or "-"
        package let content: String

        package init(
            path: String,
            lineNumber: Int,
            changeType: Character,
            content: String
        ) {
            self.path = path
            self.lineNumber = lineNumber
            self.changeType = changeType
            self.content = content
        }
    }

    /// Extracts all changed lines from a per-file patch dictionary.
    /// - Parameter perFilePatches: Dictionary mapping git paths to their patch text
    /// - Returns: Array of changed lines with path, line number, change type, and content
    package static func extractChangedLines(from perFilePatches: [String: String]) -> [ChangedLine] {
        var result: [ChangedLine] = []

        for (gitPath, patchText) in perFilePatches.sorted(by: { $0.key < $1.key }) {
            result.append(contentsOf: extractChangedLines(from: patchText, path: gitPath))
        }

        return result
    }

    /// Extracts changed lines from a single file's patch text.
    private static func extractChangedLines(from patchText: String, path: String) -> [ChangedLine] {
        var result: [ChangedLine] = []
        var oldLine = 0
        var newLine = 0

        for line in patchText.components(separatedBy: "\n") {
            // Parse hunk header to reset line counters
            if line.hasPrefix("@@") {
                if let meta = parseHunkHeader(line) {
                    oldLine = meta.oldStart
                    newLine = meta.newStart
                }
                continue
            }

            // Skip diff headers
            if line.hasPrefix("+++") || line.hasPrefix("---") ||
                line.hasPrefix("diff --git") || line.hasPrefix("index ")
            {
                continue
            }

            // Addition: use new line number
            if line.hasPrefix("+") {
                let content = String(line.dropFirst())
                result.append(ChangedLine(path: path, lineNumber: newLine, changeType: "+", content: content))
                newLine += 1
                continue
            }

            // Deletion: use old line number
            if line.hasPrefix("-") {
                let content = String(line.dropFirst())
                result.append(ChangedLine(path: path, lineNumber: oldLine, changeType: "-", content: content))
                oldLine += 1
                continue
            }

            // Context line: advance both counters
            if line.hasPrefix(" ") {
                oldLine += 1
                newLine += 1
                continue
            }

            // "\ No newline at end of file" marker - skip
            if line.hasPrefix("\\") {
                continue
            }
        }

        return result
    }

    /// Builds a TSV string for changed lines.
    /// Format: path\tline_number\tchange_type\tcontent
    package static func buildChangedLinesTsv(from perFilePatches: [String: String]) -> String {
        let changedLines = extractChangedLines(from: perFilePatches)

        var lines: [String] = []
        lines.append("path\tline_number\tchange_type\tcontent")

        for cl in changedLines {
            let row = [cl.path, String(cl.lineNumber), String(cl.changeType), cl.content].joined(separator: "\t")
            lines.append(row)
        }

        return lines.joined(separator: "\n")
    }
}
