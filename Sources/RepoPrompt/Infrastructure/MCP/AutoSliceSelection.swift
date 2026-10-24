import Foundation
import RepoPromptFoundation

enum AutoSliceSelection {
    struct SliceEntry: Equatable {
        let path: String
        let ranges: [LineRange]
    }

    enum ReadFileSelection: Equatable {
        case full(path: String)
        case slice(SliceEntry)
    }

    static func shouldApply(purpose: MCPRunPurpose, hasVirtualContext: Bool) -> Bool {
        purpose == .agentModeRun && hasVirtualContext
    }

    static func readFileSelection(
        from reply: ToolResultDTOs.ReadFileReply,
        fallbackPath: String? = nil
    ) -> ReadFileSelection? {
        guard reply.totalLines > 0 else { return nil }
        guard reply.firstLine > 0 else { return nil }
        guard reply.lastLine >= reply.firstLine else { return nil }
        guard reply.firstLine <= reply.totalLines else { return nil }

        let displayPath = reply.displayPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = fallbackPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedPath = displayPath.isEmpty ? fallback : displayPath
        guard !resolvedPath.isEmpty else { return nil }
        guard !isAgentsInstructionsFile(resolvedPath) else { return nil }

        if reply.firstLine == 1, reply.lastLine == reply.totalLines {
            return .full(path: resolvedPath)
        }

        return .slice(
            SliceEntry(
                path: resolvedPath,
                ranges: [LineRange(start: reply.firstLine, end: reply.lastLine)]
            )
        )
    }

    static func preserveExistingFullFileSelection(
        _ selection: ReadFileSelection,
        existingFullPaths: [String]
    ) -> ReadFileSelection {
        guard case let .slice(entry) = selection else { return selection }
        guard let standardizedEntryPath = StoredSelectionPathNormalization.standardizedPath(entry.path) else {
            return selection
        }

        let existingFullSet = Set(existingFullPaths.compactMap(StoredSelectionPathNormalization.standardizedPath))
        guard existingFullSet.contains(standardizedEntryPath) else { return selection }
        return .full(path: entry.path)
    }

    static func shouldSliceFileSearch(mode: SearchMode, contextLines: Int) -> Bool {
        mode == .content && contextLines > 1
    }

    private static func isAgentsInstructionsFile(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.caseInsensitiveCompare("AGENTS.md") == .orderedSame
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
