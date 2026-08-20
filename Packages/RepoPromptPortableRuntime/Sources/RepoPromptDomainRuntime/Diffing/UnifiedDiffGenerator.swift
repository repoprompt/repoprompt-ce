//
//  UnifiedDiffGenerator.swift
//  RepoPrompt
//
//  Created by RepoPrompt on 2025-07-03.
//

import Foundation

/// Generates standard unified diff format from file changes
public enum UnifiedDiffGenerator {
    // MARK: - Configuration Constants

    private static let gapToSplitMultiplier: Int = 2 // ≥ ctx*2 → split

    // MARK: - Diff Stats Helpers

    public static func diffChunks(oldLines: [String], newLines: [String], context: Int = 3) -> [DiffChunk] {
        guard oldLines != newLines else { return [] }
        return generateRewriteDiff(fileContent: oldLines, newContent: newLines, context: context)
    }

    public static func stats(from chunks: [DiffChunk]) -> (linesChanged: Int, chunks: Int) {
        let linesChanged = chunks.reduce(0) { sum, chunk in
            let adds = chunk.lines.count(where: { $0.type == .addition })
            let rems = chunk.lines.count(where: { $0.type == .removal })
            return sum + max(adds, rems)
        }
        return (linesChanged, chunks.count)
    }

    public static func build(filePath: String, chunks: [DiffChunk], context: Int = 3) -> String {
        _ = context
        guard !chunks.isEmpty else { return "" }
        let headerPath = filePath.hasPrefix("/") ? String(filePath.dropFirst()) : filePath
        let sorted = chunks.sorted { $0.startLine < $1.startLine }

        var result = ""
        result.reserveCapacity(estimatedUnifiedDiffCapacity(headerPath: headerPath, chunks: sorted))
        appendUnifiedDiffHeader(headerPath: headerPath, into: &result)

        var cumulativeDelta = 0

        for chunk in sorted {
            let oldStart = max(1, chunk.startLine)
            let newStart = max(1, oldStart + cumulativeDelta)
            appendHunk(chunk: chunk, oldStart: oldStart, newStart: newStart, into: &result)
            cumulativeDelta += chunk.lineCountDifference()
        }
        return result
    }

    // MARK: - Fast path: build unified diff from precomputed DiffChunks

    /// Diff chunks produced by DiffGenerationUtility (used by apply_edits) use 0-based startLine.
    public enum StartLineBase {
        case zeroBased
        case oneBased
    }

    /// Builds a unified diff directly from already-generated chunks (no Myers re-diff).
    /// This is the key optimization for verbose apply_edits.
    public static func buildFromEditChunks(
        filePath: String,
        chunks: [DiffChunk],
        startLineBase: StartLineBase = .zeroBased
    ) -> String {
        guard !chunks.isEmpty else { return "" }
        let headerPath = filePath.hasPrefix("/") ? String(filePath.dropFirst()) : filePath

        // Deterministic ordering + correct newStart via cumulative net line deltas.
        let sorted = chunks.sorted { $0.startLine < $1.startLine }
        var result = ""
        result.reserveCapacity(estimatedUnifiedDiffCapacity(headerPath: headerPath, chunks: sorted))
        appendUnifiedDiffHeader(headerPath: headerPath, into: &result)
        var cumulativeDelta = 0

        for chunk in sorted {
            let baseOldStart: Int = switch startLineBase {
            case .zeroBased: chunk.startLine + 1
            case .oneBased: chunk.startLine
            }

            // Clamp to 1 to match existing display behavior.
            let oldStart = max(1, baseOldStart)
            let newStart = max(1, oldStart + cumulativeDelta)

            appendHunk(chunk: chunk, oldStart: oldStart, newStart: newStart, into: &result)
            cumulativeDelta += chunk.lineCountDifference()
        }

        return result
    }

    /// Builds a complete unified diff for one file.
    /// - Parameters:
    ///   - oldLines: Original file content split into raw lines (no EOL)
    ///   - newLines: Final file content split into raw lines (no EOL)
    ///   - filePath: Path shown in the header (relative)
    ///   - context: Number of context lines to include around each hunk (default = 3)
    /// - Returns: A ready-to-display/export unified diff string
    public static func build(
        oldLines: [String]?,
        newLines: [String]?,
        filePath: String,
        context: Int = 3
    ) async throws -> String {
        // Normalize header path to avoid double slashes when absolute paths are provided
        // e.g., '/Users/…' becomes 'Users/…' so headers render as 'a/Users/…'
        let headerPath = filePath.hasPrefix("/") ? String(filePath.dropFirst()) : filePath

        // ➊ Determine action from the presence of old/new arrays
        let fileAction: FileAction
        if oldLines == nil, newLines != nil {
            fileAction = .create
        } else if oldLines != nil, newLines == nil {
            fileAction = .delete
        } else if oldLines != nil, newLines != nil {
            fileAction = .modify
        } else {
            return "" // nothing changed
        }

        // ➋ Compose minimal header
        var result = ""
        switch fileAction {
        case .create:
            result += "--- /dev/null\n"
            result += "+++ b/\(headerPath)\n"
            return result // ⟵ no huge body for new files

        case .delete:
            result += "--- a/\(headerPath)\n"
            result += "+++ /dev/null\n"
            return result // ⟵ no huge body for deletions

        case .modify, .rewrite:
            break
        }

        // ➌ Build hunks only for modifications
        let chunks = diffChunks(oldLines: oldLines!, newLines: newLines!, context: context)
        return build(filePath: filePath, chunks: chunks, context: context)
    }

    // MARK: - Whitespace-only change filtering

    /// Remove whitespace-only add/remove pairs from diff chunks.
    public static func removeWhitespaceOnlyChanges(from chunks: [DiffChunk]) -> [DiffChunk] {
        var output: [DiffChunk] = []
        for chunk in chunks {
            let lines = chunk.lines
            var filteredLines: [DiffLine] = []
            var removedLeadingOldLines = 0
            var index = 0
            while index < lines.count {
                let line = lines[index]
                if line.type == .removal,
                   index + 1 < lines.count,
                   lines[index + 1].type == .addition,
                   normalizedWhitespace(line.content) == normalizedWhitespace(lines[index + 1].content)
                {
                    if filteredLines.isEmpty {
                        removedLeadingOldLines += 1
                    }
                    index += 2
                    continue
                }
                filteredLines.append(line)
                index += 1
            }
            guard filteredLines.contains(where: { $0.type != .context }) else { continue }
            let startLine = chunk.startLine + removedLeadingOldLines
            output.append(DiffChunk(lines: filteredLines, startLine: startLine))
        }
        return output
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    @inline(__always)
    private static func hunkHasChange(_ lines: [DiffLine]) -> Bool {
        lines.contains { $0.type != .context }
    }

    // MARK: - Private Diff Generation Methods

    private static func generateCreateDiff(newContent: [String]) -> [DiffChunk] {
        var additions: [DiffLine] = []
        additions.reserveCapacity(newContent.count)
        for line in newContent {
            additions.append(DiffLine(content: "+\(line)"))
        }
        return [DiffChunk(lines: additions, startLine: 0)]
    }

    private static func generateDeleteDiff(fileContent: [String]) -> [DiffChunk] {
        var removals: [DiffLine] = []
        removals.reserveCapacity(fileContent.count)
        for line in fileContent {
            removals.append(DiffLine(content: "-\(line)"))
        }
        return [DiffChunk(lines: removals, startLine: 0)]
    }

    private static func generateRewriteDiff(
        fileContent: [String],
        newContent: [String],
        context: Int
    ) -> [DiffChunk] {
        let edits = DiffEditCreator.myersDiff(
            oldLines: fileContent,
            newLines: newContent
        )

        // Debug: print edits for small files
        if fileContent.count <= 20, false { // Disabled for now
            print("DEBUG: Edits for file with \(fileContent.count) lines:")
            for (i, edit) in edits.enumerated() {
                print("  Edit \(i): \(edit.type) - \(edit.lines.count) lines")
                if edit.lines.count <= 5 {
                    for line in edit.lines {
                        print("    '\(line)'")
                    }
                }
            }
        }

        var hunks: [DiffChunk] = []

        var currentLines: [DiffLine] = []
        var contextBuffer: [DiffLine] = []
        var currentStart = 1 // 1-based start in old file
        var oldIndex = 0 // pointer in original file

        @inline(__always)
        func flushHunk() {
            guard hunkHasChange(currentLines) else { // ← new guard
                currentLines.removeAll()
                return
            }
            hunks.append(DiffChunk(
                lines: currentLines,
                startLine: currentStart
            ))
            currentLines.removeAll()
        }

        for (idx, edit) in edits.enumerated() {
            switch edit.type {
            case .equal:
                // Collect unchanged lines into buffer
                for ln in edit.lines {
                    contextBuffer.append(DiffLine(content: " \(ln)"))
                }

                // If the unchanged run is now larger than context*2 …
                if contextBuffer.count > context * gapToSplitMultiplier {
                    let moreChangesAhead = edits[(idx + 1)...].contains { $0.type != .equal }

                    // Split only if we ALREADY recorded changes *and* there are more ahead.
                    if hunkHasChange(currentLines), moreChangesAhead {
                        // we already have changes → close current hunk
                        let leading = contextBuffer.prefix(context)
                        currentLines.append(contentsOf: leading)
                        contextBuffer.removeFirst(leading.count)
                        flushHunk()

                        // seed next hunk with trailing context
                        let trailing = contextBuffer.suffix(context)
                        currentLines = Array(trailing)
                        // The new hunk starts at the first line in the trailing context
                        // oldIndex is currently at the end of this equal block
                        // We need to go back to where the trailing context starts
                        currentStart = oldIndex - trailing.count + 1
                        contextBuffer.removeAll()
                    } else if !hunkHasChange(currentLines) {
                        // Before first change - keep only the last `context` lines
                        let toKeep = min(context, contextBuffer.count)
                        contextBuffer = Array(contextBuffer.suffix(toKeep))
                    }
                    // If we have changes but no more changes ahead, keep all context for trailing
                }

                oldIndex += edit.lines.count

            case .deletion:
                let leadingContext = Array(contextBuffer.suffix(context))
                if currentLines.isEmpty {
                    currentStart = max(1, oldIndex - leadingContext.count + 1)
                }
                if !contextBuffer.isEmpty {
                    currentLines += leadingContext
                    contextBuffer.removeAll()
                }
                currentLines += edit.lines.map { DiffLine(content: "-\($0)") }
                oldIndex += edit.lines.count

            case .addition:
                let leadingContext = Array(contextBuffer.suffix(context))
                if currentLines.isEmpty {
                    currentStart = max(1, oldIndex - leadingContext.count + 1)
                }
                if !contextBuffer.isEmpty {
                    currentLines += leadingContext
                    contextBuffer.removeAll()
                }
                currentLines += edit.lines.map { DiffLine(content: "+\($0)") }
                // additions do not advance oldIndex
            }
        }

        // Flush any trailing context (limited to `context` lines)
        if hunkHasChange(currentLines) {
            currentLines += Array(contextBuffer.prefix(context))
        }
        flushHunk()

        return hunks
    }

    // MARK: - Chunk Processing

    private static func appendUnifiedDiffHeader(headerPath: String, into output: inout String) {
        output += "--- a/\(headerPath)\n"
        output += "+++ b/\(headerPath)\n"
    }

    private static func estimatedUnifiedDiffCapacity(headerPath: String, chunks: [DiffChunk]) -> Int {
        let headerBytes = (headerPath.utf8.count * 2) + 16
        let bodyBytes = chunks.reduce(0) { total, chunk in
            let lineBytes = chunk.lines.reduce(0) { lineTotal, line in
                lineTotal + line.content.utf8.count + 2
            }
            return total + lineBytes + 48
        }
        return headerBytes + bodyBytes
    }

    /// Append a unified diff hunk with explicit old/new start positions.
    private static func appendHunk(chunk: DiffChunk, oldStart: Int, newStart: Int, into output: inout String) {
        var oldLineCount = 0
        var newLineCount = 0
        for line in chunk.lines {
            switch line.type {
            case .addition:
                newLineCount += 1
            case .removal:
                oldLineCount += 1
            case .context:
                oldLineCount += 1
                newLineCount += 1
            }
        }

        output += "@@ -\(oldStart),\(oldLineCount) +\(newStart),\(newLineCount) @@\n"
        for line in chunk.lines {
            output += line.prefix
            output += line.content
            output += "\n"
        }
    }
}
