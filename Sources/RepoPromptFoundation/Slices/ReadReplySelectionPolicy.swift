import Foundation
import RepoPromptWorkspaceCore

/// Pure logical reply metadata and selection decisions. This performs no file lookup or root admission.
package enum ReadReplySelectionPolicy {
    package struct Metadata {
        package let totalLines: Int
        package let firstLine: Int
        package let lastLine: Int
        package let displayPath: String?

        package init(totalLines: Int, firstLine: Int, lastLine: Int, displayPath: String? = nil) {
            self.totalLines = totalLines
            self.firstLine = firstLine
            self.lastLine = lastLine
            self.displayPath = displayPath
        }
    }

    package struct SliceEntry: Equatable {
        package let path: String
        package let ranges: [LineRange]

        package init(path: String, ranges: [LineRange]) {
            self.path = path
            self.ranges = ranges
        }
    }

    package enum Selection: Equatable {
        case full(path: String)
        case slice(SliceEntry)
    }

    package static func selection(
        from reply: Metadata,
        fallbackPath: String? = nil
    ) -> Selection? {
        guard reply.totalLines > 0 else { return nil }
        guard reply.firstLine > 0 else { return nil }
        guard reply.lastLine >= reply.firstLine else { return nil }
        guard reply.firstLine <= reply.totalLines else { return nil }

        // This is a logical reply selector, not a physical address or access grant.
        // Only an absent/empty reply selector uses the fallback; filename whitespace
        // and controls are data, and a malformed chosen selector is not repaired.
        let replySelector = reply.displayPath ?? ""
        let fallback = fallbackPath ?? ""
        let resolvedPath = replySelector.isEmpty ? fallback : replySelector
        guard selectorBytes(resolvedPath) != nil else { return nil }
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

    package static func preserveExistingFullFileSelection(
        _ selection: Selection,
        existingFullPaths: [String]
    ) -> Selection {
        guard case let .slice(entry) = selection else { return selection }
        guard let entryKey = selectorBytes(entry.path) else {
            return selection
        }

        let existingFullSet = Set(existingFullPaths.compactMap(selectorBytes))
        guard existingFullSet.contains(entryKey) else { return selection }
        return .full(path: entry.path)
    }

    private static func isAgentsInstructionsFile(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.caseInsensitiveCompare("AGENTS.md") == .orderedSame
    }

    /// A selector's spelling is not a physical address or a grant. Its existing
    /// authority owner admits the selector later; names are never input decoration.
    private static func selectorBytes(_ path: String) -> Data? {
        guard !path.isEmpty, !StandardizedPath.containsNUL(path) else { return nil }
        return Data(path.utf8)
    }
}
