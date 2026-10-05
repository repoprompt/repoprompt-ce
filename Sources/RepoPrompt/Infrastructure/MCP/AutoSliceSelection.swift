import Foundation
import RepoPromptFoundation

enum AutoSliceSelection {
    typealias SliceEntry = ReadReplySelectionPolicy.SliceEntry
    typealias ReadFileSelection = ReadReplySelectionPolicy.Selection

    static func shouldApply(purpose: MCPRunPurpose, hasVirtualContext: Bool) -> Bool {
        purpose == .agentModeRun && hasVirtualContext
    }

    static func readFileSelection(
        from reply: ToolResultDTOs.ReadFileReply,
        fallbackPath: String? = nil
    ) -> ReadFileSelection? {
        ReadReplySelectionPolicy.selection(
            from: .init(
                totalLines: reply.totalLines,
                firstLine: reply.firstLine,
                lastLine: reply.lastLine,
                displayPath: reply.displayPath
            ),
            fallbackPath: fallbackPath
        )
    }

    static func preserveExistingFullFileSelection(
        _ selection: ReadFileSelection,
        existingFullPaths: [String]
    ) -> ReadFileSelection {
        ReadReplySelectionPolicy.preserveExistingFullFileSelection(selection, existingFullPaths: existingFullPaths)
    }

    static func shouldSliceFileSearch(mode: SearchMode, contextLines: Int) -> Bool {
        mode == .content && contextLines > 1
    }

    static func searchEntries(
        from groups: [ToolResultDTOs.SearchResultDTO.ContentMatchGroup]
    ) -> [SliceEntry] {
        var seenPaths = Set<String>()
        var orderedPaths: [String] = []
        var rangesByPath: [String: [LineRange]] = [:]

        for group in groups {
            let trimmedPath = group.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else { continue }

            if seenPaths.insert(trimmedPath).inserted {
                orderedPaths.append(trimmedPath)
            }

            var groupRanges: [LineRange] = []
            groupRanges.reserveCapacity(group.lines.count)

            for line in group.lines {
                var minLine = line.lineNumber
                var maxLine = line.lineNumber

                for before in line.contextBefore ?? [] {
                    minLine = min(minLine, before.lineNumber)
                    maxLine = max(maxLine, before.lineNumber)
                }
                for after in line.contextAfter ?? [] {
                    minLine = min(minLine, after.lineNumber)
                    maxLine = max(maxLine, after.lineNumber)
                }

                groupRanges.append(LineRange(start: minLine, end: maxLine))
            }

            guard !groupRanges.isEmpty else { continue }
            let normalized = SliceRangeMath.normalize(groupRanges)
            guard !normalized.isEmpty else { continue }
            rangesByPath[trimmedPath, default: []].append(contentsOf: normalized)
        }

        return orderedPaths.compactMap { path in
            let normalized = SliceRangeMath.normalize(rangesByPath[path] ?? [])
            guard !normalized.isEmpty else { return nil }
            return SliceEntry(path: path, ranges: normalized)
        }
    }
}
